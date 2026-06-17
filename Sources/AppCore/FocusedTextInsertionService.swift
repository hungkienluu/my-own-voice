import AppKit
import ApplicationServices
import Foundation

struct PostPasteObservationContext: Sendable {
    let processIdentifier: pid_t
    let prefix: String
    let suffix: String
    let insertedText: String
    let hasSelectionAnchors: Bool

    init(
        processIdentifier: pid_t,
        prefix: String,
        suffix: String,
        insertedText: String,
        hasSelectionAnchors: Bool = true
    ) {
        self.processIdentifier = processIdentifier
        self.prefix = prefix
        self.suffix = suffix
        self.insertedText = insertedText
        self.hasSelectionAnchors = hasSelectionAnchors
    }
}

struct LearnedCorrection: Sendable {
    let wrong: String
    let right: String
}

public struct TextInsertionResult: Sendable {
    public let outcome: InsertionOutcome
    public let message: String
    public let target: InsertionTarget?
    let observationContext: PostPasteObservationContext?

    public var canVerifyDelayedVisibility: Bool {
        observationContext != nil
    }

    init(
        outcome: InsertionOutcome,
        message: String,
        target: InsertionTarget? = nil,
        observationContext: PostPasteObservationContext? = nil
    ) {
        self.outcome = outcome
        self.message = message
        self.target = target
        self.observationContext = observationContext
    }
}

@MainActor
public final class FocusedTextInsertionService {
    public init() {}

    public func insert(text: String) -> TextInsertionResult {
        let fallbackTarget = frontmostInsertionTarget()

        guard Self.hasPasteableText(text) else {
            return TextInsertionResult(
                outcome: .failed,
                message: "The transcript is empty, so nothing was inserted or copied.",
                target: fallbackTarget
            )
        }

        guard AXIsProcessTrusted() else {
            copyToPasteboard(text)
            return TextInsertionResult(
                outcome: .failed,
                message: "Accessibility permission is required for automatic insertion. Copied the transcript to the clipboard for manual paste.",
                target: fallbackTarget
            )
        }

        let snapshot = captureFocusedTextSnapshot()
        if let snapshot,
           insertDirectly(text, into: snapshot.focusedElement) {
            let observationContext = makeObservationContext(from: snapshot, insertedText: text)
            let insertionWasConfirmed = directInsertionWasConfirmed(
                in: snapshot.focusedElement,
                context: observationContext,
                insertedText: text
            )

            if !Self.shouldUseClipboardFallbackAfterDirectInsertion(confirmed: insertionWasConfirmed) {
                let message = insertionWasConfirmed == true
                    ? "Inserted into the currently focused field using Accessibility and confirmed the target text."
                    : "Inserted into the currently focused field using Accessibility. The target app did not expose enough text to verify the result."

                return TextInsertionResult(
                    outcome: .insertedDirectly,
                    message: message,
                    target: snapshot.insertionTarget,
                    observationContext: observationContext
                )
            }

            return pasteViaClipboardFallback(
                text,
                snapshot: snapshot,
                fallbackTarget: fallbackTarget,
                message: "Direct Accessibility insertion did not become visible, so My Own Voice pasted with the clipboard fallback and left the transcript on the clipboard for recovery."
            )
        }

        return pasteViaClipboardFallback(
            text,
            snapshot: snapshot,
            fallbackTarget: fallbackTarget,
            message: "Attempted clipboard fallback paste and left the transcript on the clipboard for recovery."
        )
    }

    private func pasteViaClipboardFallback(
        _ text: String,
        snapshot: FocusedTextSnapshot?,
        fallbackTarget: InsertionTarget?,
        message: String
    ) -> TextInsertionResult {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            copyToPasteboard(text)
            return TextInsertionResult(
                outcome: .failed,
                message: "Could not create the paste keyboard event. Copied the transcript to the clipboard for manual paste.",
                target: snapshot?.insertionTarget ?? fallbackTarget
            )
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return TextInsertionResult(
                outcome: .failed,
                message: "Could not write the transcript to the clipboard for fallback paste.",
                target: snapshot?.insertionTarget ?? fallbackTarget
            )
        }

        let target = snapshot?.insertionTarget ?? fallbackTarget
        activateInsertionTarget(target)
        source.localEventsSuppressionInterval = 0
        Thread.sleep(forTimeInterval: Self.fallbackPasteboardSettleDelay)
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: Self.fallbackPasteKeyHoldDelay)
        keyUp.post(tap: .cghidEventTap)

        let observationContext = snapshot.flatMap { makeObservationContext(from: $0, insertedText: text) }

        return TextInsertionResult(
            outcome: .pastedViaClipboardFallback,
            message: message,
            target: target,
            observationContext: observationContext
        )
    }

    public func delayedVisibilityStatus(for result: TextInsertionResult) -> Bool? {
        guard let context = result.observationContext else {
            return nil
        }

        return currentFocusedTextMatchesInsertion(from: context)
    }

    func detectLearnedCorrections(from context: PostPasteObservationContext) -> [LearnedCorrection] {
        guard let snapshot = captureFocusedTextSnapshot(),
              snapshot.processIdentifier == context.processIdentifier,
              snapshot.fieldText != context.insertedText else {
            return []
        }

        for revisedSegment in Self.revisedSegmentCandidates(from: context, fieldText: snapshot.fieldText) {
            let corrections = PostPasteCorrectionDetector.learnedCorrections(
                original: context.insertedText,
                revised: revisedSegment
            )

            if !corrections.isEmpty {
                return corrections
            }
        }

        return []
    }

    func detectLearnedCorrection(from context: PostPasteObservationContext) -> LearnedCorrection? {
        detectLearnedCorrections(from: context).first
    }

    func currentFocusedTextMatchesInsertion(from context: PostPasteObservationContext) -> Bool? {
        guard let snapshot = captureFocusedTextSnapshot(),
              snapshot.processIdentifier == context.processIdentifier else {
            return nil
        }

        return Self.insertedTextMatchesObservationContext(
            context.insertedText,
            context: context,
            fieldText: snapshot.fieldText
        )
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func activateInsertionTarget(_ target: InsertionTarget?) {
        guard let processIdentifier = target?.processIdentifier,
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated else {
            return
        }

        application.activate()
    }

    private func captureFocusedTextSnapshot() -> FocusedTextSnapshot? {
        let systemWideElement = AXUIElementCreateSystemWide()

        var focusedElementValue: CFTypeRef?
        let focusedElementResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )

        guard focusedElementResult == .success,
              let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            return nil
        }

        let focusedElement = unsafeDowncast(focusedElementValue as AnyObject, to: AXUIElement.self)
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(focusedElement, &processIdentifier)

        guard let fieldText = copyStringAttribute(
            kAXValueAttribute as CFString,
            from: focusedElement
        ) else {
            return nil
        }

        return FocusedTextSnapshot(
            focusedElement: focusedElement,
            processIdentifier: processIdentifier,
            insertionTarget: insertionTarget(for: processIdentifier),
            fieldText: fieldText,
            selectedRange: copySelectedRange(from: focusedElement)
        )
    }

    private func frontmostInsertionTarget() -> InsertionTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return InsertionTarget(
            applicationName: application.localizedName ?? application.bundleIdentifier ?? "Unknown App",
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier
        )
    }

    private func insertionTarget(for processIdentifier: pid_t) -> InsertionTarget? {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            return nil
        }

        return InsertionTarget(
            applicationName: application.localizedName ?? application.bundleIdentifier ?? "Unknown App",
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier
        )
    }

    private func copyStringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }

        if let string = value as? String {
            return string
        }

        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }

        return nil
    }

    private func insertDirectly(_ text: String, into element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success
    }

    private func directInsertionWasConfirmed(
        in element: AXUIElement,
        context: PostPasteObservationContext?,
        insertedText: String
    ) -> Bool? {
        guard let context,
              context.hasSelectionAnchors,
              let fieldText = copyStringAttribute(kAXValueAttribute as CFString, from: element) else {
            return nil
        }

        return Self.insertedTextMatchesObservationContext(
            insertedText,
            context: context,
            fieldText: fieldText
        )
    }

    private func copySelectedRange(from element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )

        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(value as AnyObject, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return NSRange(location: range.location, length: range.length)
    }

    private func makeObservationContext(
        from snapshot: FocusedTextSnapshot,
        insertedText: String
    ) -> PostPasteObservationContext? {
        guard let selectedRange = snapshot.selectedRange else {
            return PostPasteObservationContext(
                processIdentifier: snapshot.processIdentifier,
                prefix: "",
                suffix: "",
                insertedText: insertedText,
                hasSelectionAnchors: false
            )
        }

        let nsText = snapshot.fieldText as NSString
        guard selectedRange.location != NSNotFound,
              selectedRange.location >= 0,
              selectedRange.length >= 0,
              selectedRange.location + selectedRange.length <= nsText.length else {
            return nil
        }

        let prefix = Self.observationPrefixAnchor(
            from: nsText.substring(to: selectedRange.location)
        )
        let suffix = Self.observationSuffixAnchor(
            from: nsText.substring(from: selectedRange.location + selectedRange.length)
        )

        return PostPasteObservationContext(
            processIdentifier: snapshot.processIdentifier,
            prefix: prefix,
            suffix: suffix,
            insertedText: insertedText
        )
    }

    nonisolated static func insertedTextMatchesObservationContext(
        _ insertedText: String,
        context: PostPasteObservationContext,
        fieldText: String
    ) -> Bool {
        revisedSegmentCandidates(from: context, fieldText: fieldText)
            .contains(insertedText)
    }

    nonisolated static func directInsertionOutcome(confirmed: Bool?) -> InsertionOutcome {
        confirmed == false ? .failed : .insertedDirectly
    }

    nonisolated static func shouldUseClipboardFallbackAfterDirectInsertion(confirmed: Bool?) -> Bool {
        confirmed == false
    }

    public nonisolated static func clipboardRestoreDelayAfterFallbackPaste(
        for result: TextInsertionResult,
        verifyDelay: TimeInterval,
        minimumDelay: TimeInterval = 0.35
    ) -> TimeInterval? {
        guard result.outcome == .pastedViaClipboardFallback,
              !result.canVerifyDelayedVisibility else {
            return nil
        }

        return max(verifyDelay, minimumDelay)
    }

    nonisolated static func hasPasteableText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    nonisolated static let delayedInsertionVerificationAttemptCount = 6
    nonisolated static let delayedInsertionVerificationInitialDelay: TimeInterval = 0.45
    nonisolated static let delayedInsertionVerificationRetryDelay: TimeInterval = 0.65
    nonisolated static let fallbackPasteboardSettleDelay: TimeInterval = 0.08
    nonisolated static let fallbackPasteKeyHoldDelay: TimeInterval = 0.035

    private nonisolated static func revisedSegmentCandidates(
        from context: PostPasteObservationContext,
        fieldText: String
    ) -> [String] {
        var candidates: [String] = []

        func appendCandidate(_ candidate: String?) {
            guard let candidate,
                  !candidate.isEmpty,
                  !candidates.contains(candidate) else {
                return
            }

            candidates.append(candidate)
        }

        appendCandidate(exactAnchoredSegment(from: context, fieldText: fieldText))
        appendCandidate(relaxedAnchoredSegment(from: context, fieldText: fieldText))
        for candidate in localAnchoredSegments(from: context, fieldText: fieldText) {
            appendCandidate(candidate)
        }

        let insertedLength = (context.insertedText as NSString).length
        let fieldLength = (fieldText as NSString).length
        if context.prefix.isEmpty && context.suffix.isEmpty && fieldLength <= insertedLength + 500 {
            appendCandidate(fieldText)
        }

        return candidates
    }

    private nonisolated static func exactAnchoredSegment(
        from context: PostPasteObservationContext,
        fieldText: String
    ) -> String? {
        guard fieldText.hasPrefix(context.prefix),
              fieldText.hasSuffix(context.suffix) else {
            return nil
        }

        let nsFieldText = fieldText as NSString
        let prefixLength = (context.prefix as NSString).length
        let suffixLength = (context.suffix as NSString).length
        let middleLength = nsFieldText.length - prefixLength - suffixLength
        guard middleLength >= 0,
              Self.isObservationCandidateLengthAllowed(middleLength, context: context) else {
            return nil
        }

        return nsFieldText.substring(
            with: NSRange(location: prefixLength, length: middleLength)
        )
    }

    private nonisolated static func relaxedAnchoredSegment(
        from context: PostPasteObservationContext,
        fieldText: String
    ) -> String? {
        guard fieldText.hasPrefix(context.prefix) else {
            return nil
        }

        let nsFieldText = fieldText as NSString
        let prefixLength = (context.prefix as NSString).length
        guard prefixLength <= nsFieldText.length else { return nil }

        if context.suffix.isEmpty {
            let candidateLength = nsFieldText.length - prefixLength
            guard Self.isObservationCandidateLengthAllowed(candidateLength, context: context) else {
                return nil
            }
            return nsFieldText.substring(from: prefixLength)
        }

        let searchRange = NSRange(
            location: prefixLength,
            length: nsFieldText.length - prefixLength
        )
        let suffixRange = nsFieldText.range(of: context.suffix, options: [], range: searchRange)
        guard suffixRange.location != NSNotFound,
              suffixRange.location >= prefixLength else {
            return nil
        }

        let candidateLength = suffixRange.location - prefixLength
        guard Self.isObservationCandidateLengthAllowed(candidateLength, context: context) else {
            return nil
        }

        return nsFieldText.substring(
            with: NSRange(
                location: prefixLength,
                length: candidateLength
            )
        )
    }

    private nonisolated static func localAnchoredSegments(
        from context: PostPasteObservationContext,
        fieldText: String
    ) -> [String] {
        let nsFieldText = fieldText as NSString
        let fieldLength = nsFieldText.length
        let insertedLength = (context.insertedText as NSString).length
        var candidates: [String] = []

        func appendCandidate(location: Int, length: Int) {
            guard location >= 0,
                  length >= 0,
                  location + length <= fieldLength,
                  Self.isObservationCandidateLengthAllowed(length, insertedLength: insertedLength) else {
                return
            }

            let candidate = nsFieldText.substring(with: NSRange(location: location, length: length))
            if !candidate.isEmpty, !candidates.contains(candidate) {
                candidates.append(candidate)
            }
        }

        if context.prefix.isEmpty {
            guard !context.suffix.isEmpty else { return [] }

            let suffixRange = nsFieldText.range(
                of: context.suffix,
                options: [],
                range: NSRange(location: 0, length: fieldLength)
            )
            guard suffixRange.location != NSNotFound else { return [] }
            appendCandidate(location: 0, length: suffixRange.location)
            return candidates
        }

        var searchLocation = 0
        var matchCount = 0
        while searchLocation < fieldLength, matchCount < 20 {
            let prefixRange = nsFieldText.range(
                of: context.prefix,
                options: [],
                range: NSRange(location: searchLocation, length: fieldLength - searchLocation)
            )
            guard prefixRange.location != NSNotFound else {
                break
            }

            let segmentStart = prefixRange.location + prefixRange.length
            if context.suffix.isEmpty {
                appendCandidate(location: segmentStart, length: fieldLength - segmentStart)
            } else if segmentStart <= fieldLength {
                let suffixRange = nsFieldText.range(
                    of: context.suffix,
                    options: [],
                    range: NSRange(location: segmentStart, length: fieldLength - segmentStart)
                )
                if suffixRange.location != NSNotFound {
                    appendCandidate(location: segmentStart, length: suffixRange.location - segmentStart)
                }
            }

            searchLocation = prefixRange.location + max(prefixRange.length, 1)
            matchCount += 1
        }

        return candidates
    }

    private nonisolated static func isObservationCandidateLengthAllowed(
        _ length: Int,
        context: PostPasteObservationContext
    ) -> Bool {
        isObservationCandidateLengthAllowed(
            length,
            insertedLength: (context.insertedText as NSString).length
        )
    }

    private nonisolated static func isObservationCandidateLengthAllowed(
        _ length: Int,
        insertedLength: Int
    ) -> Bool {
        length <= insertedLength + 500
    }

    private nonisolated static func observationPrefixAnchor(from text: String) -> String {
        String(text.suffix(observationAnchorCharacterLimit))
    }

    private nonisolated static func observationSuffixAnchor(from text: String) -> String {
        String(text.prefix(observationAnchorCharacterLimit))
    }

    nonisolated private static let observationAnchorCharacterLimit = 512

    private struct FocusedTextSnapshot {
        let focusedElement: AXUIElement
        let processIdentifier: pid_t
        let insertionTarget: InsertionTarget?
        let fieldText: String
        let selectedRange: NSRange?
    }
}
