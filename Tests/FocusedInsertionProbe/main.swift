import AppCore
import ApplicationServices
import AppKit
import AVFoundation
import Foundation

@main
struct FocusedInsertionProbe {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.contains("--help") {
            print("usage=swift run FocusedInsertionProbe [--check-permissions] [--request-accessibility] [--restore-clipboard] [--empty-text] [--verify-delay seconds] [probe text]")
            print("note=--check-permissions reports Accessibility trust and probe-process microphone authorization without inserting text.")
            print("note=--request-accessibility asks macOS to show the Accessibility permission prompt without inserting text.")
            print("note=--restore-clipboard restores the pre-probe pasteboard after printing clipboard recovery evidence.")
            print("note=--empty-text probes the guard path for empty transcripts instead of using default sample text.")
            print("note=normal probe runs print clipboardMatchesProbe=true when the transcript remains available for manual paste recovery.")
            print("note=normal probe waits briefly and prints delayedVisibility=true/false/unknown/unavailable when the focused field exposes enough text.")
            return
        }

        print("microphoneAuthorization=\(microphoneAuthorizationDescription())")
        print("note=Microphone authorization is for this probe process; final QA must confirm the MyOwnVoiceApp bundle after relaunch.")

        if arguments.contains("--request-accessibility") {
            let trusted = requestAccessibilityTrust()
            print("accessibilityPromptRequested=true")
            print("accessibilityTrusted=\(trusted)")
            if !trusted {
                print("note=Grant Accessibility permission in System Settings, then rerun the readiness check.")
            }
            return
        }

        if !AXIsProcessTrusted() {
            print("accessibilityTrusted=false")
            print("note=FocusedInsertionProbe is not trusted for Accessibility; insertion will fall back to clipboard recovery.")
        } else {
            print("accessibilityTrusted=true")
        }

        if arguments.contains("--check-permissions") {
            return
        }

        let verifyDelay = verifyDelaySeconds(from: arguments)
        let shouldRestoreClipboard = arguments.contains("--restore-clipboard")
        let shouldUseEmptyText = arguments.contains("--empty-text")
        let pasteboardSnapshot = shouldRestoreClipboard ? PasteboardSnapshot.capture() : nil
        let text = probeTextArguments(from: arguments)
            .joined(separator: " ")
        let probeText = shouldUseEmptyText ? "" : (text.isEmpty
            ? "my own voice insertion probe"
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

    private static func microphoneAuthorizationDescription() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "authorized"
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }

    private static func requestAccessibilityTrust() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": true,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
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
            case "--check-permissions", "--request-accessibility", "--restore-clipboard", "--empty-text":
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
