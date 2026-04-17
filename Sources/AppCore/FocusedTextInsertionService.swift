import AppKit
import ApplicationServices
import Foundation

struct PostPasteObservationContext: Sendable {
    let processIdentifier: pid_t
    let prefix: String
    let suffix: String
    let insertedText: String
}

struct LearnedCorrection: Sendable {
    let wrong: String
    let right: String
}

public struct TextInsertionResult: Sendable {
    public let outcome: InsertionOutcome
    public let message: String
    let observationContext: PostPasteObservationContext?

    init(
        outcome: InsertionOutcome,
        message: String,
        observationContext: PostPasteObservationContext? = nil
    ) {
        self.outcome = outcome
        self.message = message
        self.observationContext = observationContext
    }
}

@MainActor
public final class FocusedTextInsertionService {
    public init() {}

    public func insert(text: String) -> TextInsertionResult {
        guard AXIsProcessTrusted() else {
            return TextInsertionResult(
                outcome: .failed,
                message: "Accessibility permission is required before we can paste into the focused field."
            )
        }

        let snapshot = captureFocusedTextSnapshot()
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return TextInsertionResult(
                outcome: .failed,
                message: "Could not create the paste keyboard event."
            )
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        restorePasteboard(previousString)
        let observationContext = snapshot.flatMap { makeObservationContext(from: $0, insertedText: text) }

        return TextInsertionResult(
            outcome: .pastedViaClipboardFallback,
            message: "Pasted into the currently focused field using the clipboard fallback.",
            observationContext: observationContext
        )
    }

    func detectLearnedCorrection(from context: PostPasteObservationContext) -> LearnedCorrection? {
        guard let snapshot = captureFocusedTextSnapshot(),
              snapshot.processIdentifier == context.processIdentifier,
              snapshot.fieldText.hasPrefix(context.prefix),
              snapshot.fieldText.hasSuffix(context.suffix) else {
            return nil
        }

        let nsFieldText = snapshot.fieldText as NSString
        let prefixLength = context.prefix.utf16.count
        let suffixLength = context.suffix.utf16.count
        let middleLength = nsFieldText.length - prefixLength - suffixLength

        guard middleLength >= 0 else { return nil }
        let currentSegment = nsFieldText.substring(
            with: NSRange(location: prefixLength, length: middleLength)
        )

        return inferLearnedCorrection(
            original: context.insertedText,
            revised: currentSegment
        )
    }

    private func restorePasteboard(_ string: String?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()

            if let string {
                pasteboard.setString(string, forType: .string)
            }
        }
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
            processIdentifier: processIdentifier,
            fieldText: fieldText,
            selectedRange: copySelectedRange(from: focusedElement)
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
        guard let selectedRange = snapshot.selectedRange else { return nil }

        let nsText = snapshot.fieldText as NSString
        guard selectedRange.location != NSNotFound,
              selectedRange.location >= 0,
              selectedRange.length >= 0,
              selectedRange.location + selectedRange.length <= nsText.length else {
            return nil
        }

        let prefix = nsText.substring(to: selectedRange.location)
        let suffix = nsText.substring(from: selectedRange.location + selectedRange.length)

        return PostPasteObservationContext(
            processIdentifier: snapshot.processIdentifier,
            prefix: prefix,
            suffix: suffix,
            insertedText: insertedText
        )
    }

    private func inferLearnedCorrection(
        original: String,
        revised: String
    ) -> LearnedCorrection? {
        guard original != revised else { return nil }

        let originalCharacters = Array(original)
        let revisedCharacters = Array(revised)
        var prefixLength = 0

        while prefixLength < originalCharacters.count,
              prefixLength < revisedCharacters.count,
              originalCharacters[prefixLength] == revisedCharacters[prefixLength] {
            prefixLength += 1
        }

        var suffixLength = 0
        while suffixLength < originalCharacters.count - prefixLength,
              suffixLength < revisedCharacters.count - prefixLength,
              originalCharacters[originalCharacters.count - 1 - suffixLength] == revisedCharacters[revisedCharacters.count - 1 - suffixLength] {
            suffixLength += 1
        }

        let originalStart = original.index(original.startIndex, offsetBy: prefixLength)
        let originalEnd = original.index(original.endIndex, offsetBy: -suffixLength)
        let revisedStart = revised.index(revised.startIndex, offsetBy: prefixLength)
        let revisedEnd = revised.index(revised.endIndex, offsetBy: -suffixLength)

        let wrong = String(original[originalStart..<originalEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(Self.edgePunctuation))
        let right = String(revised[revisedStart..<revisedEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(Self.edgePunctuation))

        guard !wrong.isEmpty,
              !right.isEmpty,
              wrong.count <= 48,
              right.count <= 48,
              wrong.split(whereSeparator: \.isWhitespace).count <= 4,
              right.split(whereSeparator: \.isWhitespace).count <= 4 else {
            return nil
        }

        return LearnedCorrection(wrong: wrong, right: right)
    }

    private struct FocusedTextSnapshot {
        let processIdentifier: pid_t
        let fieldText: String
        let selectedRange: NSRange?
    }

    private static let edgePunctuation = CharacterSet(charactersIn: "\"'“”‘’,.!?:;()[]{}")
}
