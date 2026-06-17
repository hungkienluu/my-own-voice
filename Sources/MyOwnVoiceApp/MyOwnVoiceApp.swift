import AppCore
import ApplicationServices
import AppKit
import AVFoundation
import Darwin
import SwiftUI

@main
struct MyOwnVoiceApp: App {
    private let recordingIndicatorController: RecordingIndicatorController
    @MainActor private static var previewHUDController: RecordingIndicatorController?
    @StateObject private var coordinator: DictationCoordinator

    init() {
        Self.exitAfterCommandIfRequested()

        let recordingIndicatorController = RecordingIndicatorController()
        self.recordingIndicatorController = recordingIndicatorController
        _coordinator = StateObject(
            wrappedValue: DictationCoordinator(recordingIndicatorPresenter: recordingIndicatorController)
        )
    }

    var body: some Scene {
        MenuBarExtra(
            "My Own Voice",
            systemImage: menuBarSystemImage
        ) {
            StatusMenuView(coordinator: coordinator)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(coordinator: coordinator)
                .frame(minWidth: 1040, idealWidth: 1120, minHeight: 680, idealHeight: 760)
        }
    }

    private var menuBarSystemImage: String {
        if coordinator.isRecording {
            return "waveform.badge.mic"
        }

        if coordinator.isProcessingCapture {
            return "waveform.and.magnifyingglass"
        }

        return "waveform.circle"
    }

    @MainActor
    private static func exitAfterCommandIfRequested() {
        let arguments = CommandLine.arguments

        if arguments.contains("--preview-hud") {
            runHUDPreview(arguments: Array(arguments.dropFirst()))
            exit(0)
        }

        guard arguments.contains("--check-permissions") ||
            arguments.contains("--request-accessibility") ||
            arguments.contains("--probe-insertion") else {
            return
        }

        print("myOwnVoiceAppMicrophoneAuthorization=\(microphoneAuthorizationStatus)")

        if arguments.contains("--request-accessibility") {
            let trusted = requestAccessibilityTrust()
            print("myOwnVoiceAppAccessibilityPromptRequested=true")
            print("myOwnVoiceAppAccessibilityTrusted=\(trusted)")
            openAccessibilitySettings()
            if !trusted {
                print("note=Grant the My Own Voice app entry in System Settings, then rerun the readiness check.")
            }
            exit(0)
        }

        print("myOwnVoiceAppAccessibilityTrusted=\(AXIsProcessTrusted())")
        print("myOwnVoiceAppFrontmostTarget=\(frontmostTargetDescription)")

        if arguments.contains("--probe-insertion") {
            runInsertionProbe(arguments: Array(arguments.dropFirst()))
        }

        exit(0)
    }

    @MainActor
    private static func runHUDPreview(arguments: [String]) {
        let controller = RecordingIndicatorController()
        previewHUDController = controller
        NSApp.setActivationPolicy(.accessory)
        controller.showDictationHUD(previewHUDSnapshot(from: arguments))
        DispatchQueue.main.asyncAfter(deadline: .now() + previewHUDDuration(from: arguments)) {
            previewHUDController?.hideRecordingIndicator()
            previewHUDController = nil
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    private static func previewHUDSnapshot(from arguments: [String]) -> DictationHUDSnapshot {
        let state = previewHUDStateName(from: arguments)

        switch state {
        case "recording":
            return DictationHUDSnapshot(
                phase: .recording,
                mode: .quickDictation,
                title: "Recording",
                detail: "Listening from the preview command. Release or stop to insert.",
                startedAt: Date().addingTimeInterval(-76)
            )
        case "long-text":
            return DictationHUDSnapshot(
                phase: .transcribing,
                mode: .longSession,
                title: "Transcribing",
                detail: "Local transcription is building as chunks finish.",
                progress: 0.58,
                progressLabel: "Chunk 7 of 12",
                previewText: """
                ...the second section should stay readable even when the transcript is much longer than the HUD can display at once.
                """
            )
        case "recovery":
            return DictationHUDSnapshot(
                phase: .recovery,
                mode: .quickDictation,
                title: "Recovery Ready",
                detail: "Saved for Slack.",
                previewText: "Can you send the draft before standup?",
                recoveryText: "Clipboard fallback did not appear in the focused field. The transcript remains on the clipboard and in History."
            )
        case "failure":
            return DictationHUDSnapshot(
                phase: .failed,
                mode: .longSession,
                title: "Needs Attention",
                detail: "Dictation could not finish.",
                recoveryText: "No retryable audio chunks were captured. Open the session folder to inspect local files, or record again."
            )
        default:
            return DictationHUDSnapshot(
                phase: .polishing,
                mode: .quickDictation,
                title: "Polishing",
                detail: "Applying local cleanup and your correction rules.",
                progressLabel: "Formatting locally",
                previewText: "Tomorrow morning, remind me to send the contract and thank Jen for the quick turnaround."
            )
        }
    }

    private static func previewHUDStateName(from arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: "--preview-hud"),
              arguments.indices.contains(arguments.index(after: index)) else {
            return "polishing"
        }

        return arguments[arguments.index(after: index)]
    }

    private static func previewHUDDuration(from arguments: [String]) -> TimeInterval {
        guard let index = arguments.firstIndex(of: "--preview-duration"),
              arguments.indices.contains(arguments.index(after: index)),
              let seconds = TimeInterval(arguments[arguments.index(after: index)]),
              seconds > 0 else {
            return 6
        }

        return seconds
    }

    @MainActor
    private static func runInsertionProbe(arguments: [String]) {
        let verifyDelay = verifyDelaySeconds(from: arguments)
        let shouldRestoreClipboard = arguments.contains("--restore-clipboard")
        let shouldUseEmptyText = arguments.contains("--empty-text")
        let pasteboardSnapshot = shouldRestoreClipboard ? PasteboardSnapshot.capture() : nil
        let text = probeTextArguments(from: arguments).joined(separator: " ")
        let probeText = shouldUseEmptyText ? "" : (text.isEmpty
            ? "my own voice app insertion probe"
            : text)

        let insertionService = FocusedTextInsertionService()
        let result = insertionService.insert(text: probeText)

        defer {
            if shouldRestoreClipboard {
                waitBeforeRestoringClipboardIfNeeded(result: result, verifyDelay: verifyDelay)
                pasteboardSnapshot?.restore()
                print("clipboardRestored=true")
            }
        }

        print("outcome=\(result.outcome.rawValue)")
        print("message=\(result.message)")
        print("clipboardMatchesProbe=\(NSPasteboard.general.string(forType: .string) == probeText)")
        if let pasteboardSnapshot {
            print("clipboardMatchesPreProbe=\(pasteboardSnapshot.matchesCurrent())")
        }
        print("canVerifyDelayedVisibility=\(result.canVerifyDelayedVisibility)")

        if let target = result.target {
            print("target=\(target.displayName)")
        } else {
            print("target=unknown")
        }

        if result.canVerifyDelayedVisibility {
            Thread.sleep(forTimeInterval: verifyDelay)
            switch insertionService.delayedVisibilityStatus(for: result) {
            case true:
                print("delayedVisibility=true")
            case false:
                print("delayedVisibility=false")
            case nil:
                print("delayedVisibility=unknown")
            }
        } else {
            print("delayedVisibility=unavailable")
        }
    }

    private static func waitBeforeRestoringClipboardIfNeeded(
        result: TextInsertionResult,
        verifyDelay: TimeInterval
    ) {
        guard let delay = FocusedTextInsertionService.clipboardRestoreDelayAfterFallbackPaste(
            for: result,
            verifyDelay: verifyDelay
        ) else {
            return
        }

        Thread.sleep(forTimeInterval: delay)
    }

    private static func requestAccessibilityTrust() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": true,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private static var frontmostTargetDescription: String {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return "unknown"
        }

        let name = application.localizedName ?? application.bundleIdentifier ?? "Unknown App"
        if let bundleIdentifier = application.bundleIdentifier,
           !bundleIdentifier.isEmpty {
            return "\(name) (\(bundleIdentifier))"
        }

        return name
    }

    private static func verifyDelaySeconds(from arguments: [String]) -> TimeInterval {
        guard let index = arguments.firstIndex(of: "--verify-delay"),
              arguments.indices.contains(arguments.index(after: index)),
              let seconds = TimeInterval(arguments[arguments.index(after: index)]),
              seconds >= 0 else {
            return 1
        }

        return seconds
    }

    private static func probeTextArguments(from arguments: [String]) -> [String] {
        var textArguments: [String] = []
        var skipNext = false

        for argument in arguments {
            if skipNext {
                skipNext = false
                continue
            }

            switch argument {
            case "--check-permissions", "--request-accessibility", "--probe-insertion", "--restore-clipboard", "--empty-text":
                continue
            case "--verify-delay":
                skipNext = true
                continue
            default:
                textArguments.append(argument)
            }
        }

        return textArguments
    }

    private static var microphoneAuthorizationStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            "authorized"
        case .denied:
            "denied"
        case .notDetermined:
            "notDetermined"
        case .restricted:
            "restricted"
        @unknown default:
            "unknown"
        }
    }
}

private struct PasteboardSnapshot {
    let changeCount: Int
    let items: [NSPasteboardItem]

    static func capture() -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        let items = pasteboard.pasteboardItems ?? []
        return PasteboardSnapshot(
            changeCount: pasteboard.changeCount,
            items: items.map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        copy.setData(data, forType: type)
                    }
                }
                return copy
            }
        )
    }

    func restore() {
        guard !matchesCurrent() else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    func matchesCurrent() -> Bool {
        NSPasteboard.general.changeCount == changeCount
    }
}
