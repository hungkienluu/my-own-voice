import AppKit
import SwiftUI

enum SettingsWindowController {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("MyOwnVoice.SettingsWindow")

    @MainActor
    static func revealSettingsWindow() {
        Task { @MainActor in
            for attempt in 0..<6 {
                if let window = existingSettingsWindow {
                    present(window)
                    return
                }

                if attempt == 0 {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }

                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    @MainActor
    static func configure(_ window: NSWindow) {
        window.identifier = windowIdentifier
        window.title = "My Own Voice Settings"
    }

    @MainActor
    private static var existingSettingsWindow: NSWindow? {
        NSApp.windows.first {
            $0.identifier == windowIdentifier || $0.title == "My Own Voice Settings"
        }
    }

    @MainActor
    private static func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }
}

final class SettingsWindowTrackingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let window {
            SettingsWindowController.configure(window)
        }
    }
}

struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowTrackingView {
        SettingsWindowTrackingView(frame: .zero)
    }

    func updateNSView(_ nsView: SettingsWindowTrackingView, context: Context) {
        if let window = nsView.window {
            SettingsWindowController.configure(window)
        }
    }
}
