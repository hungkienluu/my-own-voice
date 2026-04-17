import AppCore
import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorderField: NSViewRepresentable {
    let shortcut: AppCore.KeyboardShortcut
    let onShortcutChange: (AppCore.KeyboardShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderTextField {
        let textField = ShortcutRecorderTextField()
        textField.isBezeled = true
        textField.isBordered = true
        textField.isEditable = false
        textField.focusRingType = .default
        textField.alignment = .center
        textField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize + 3, weight: .medium)
        textField.onShortcutChange = onShortcutChange
        textField.currentShortcut = shortcut
        return textField
    }

    func updateNSView(_ nsView: ShortcutRecorderTextField, context: Context) {
        nsView.onShortcutChange = onShortcutChange
        nsView.currentShortcut = shortcut
    }
}

final class ShortcutRecorderTextField: NSTextField {
    var onShortcutChange: ((AppCore.KeyboardShortcut) -> Void)?
    var currentShortcut: AppCore.KeyboardShortcut? {
        didSet {
            guard !isRecording else { return }
            stringValue = currentShortcut?.displayName ?? "Click to Record"
        }
    }

    private var isRecording = false
    private var liveModifierFlags: NSEvent.ModifierFlags = []
    private var liveModifierKeyCode: UInt32?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        beginRecording()
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()

        if didResign, isRecording {
            endRecording()
        }

        return didResign
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if Int(event.keyCode) == kVK_Escape {
            endRecording()
            return
        }

        guard let shortcut = makeShortcut(from: event) else {
            NSSound.beep()
            return
        }

        liveModifierFlags = []
        liveModifierKeyCode = nil
        currentShortcut = shortcut
        onShortcutChange?(shortcut)
        endRecording()
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }

        let flags = normalizedModifierFlags(from: event.modifierFlags)

        if flags.isEmpty {
            guard !liveModifierFlags.isEmpty else {
                endRecording()
                return
            }

            commitModifierOnlyShortcut(from: liveModifierFlags, keyCode: liveModifierKeyCode)
            return
        }

        if flags.modifierCount < liveModifierFlags.modifierCount, !liveModifierFlags.isEmpty {
            commitModifierOnlyShortcut(from: liveModifierFlags, keyCode: liveModifierKeyCode)
            return
        }

        liveModifierFlags = flags
        liveModifierKeyCode = flags.modifierCount == 1 ? UInt32(event.keyCode) : nil
        stringValue = displayName(for: flags, keyName: nil, modifierKeyCode: liveModifierKeyCode)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }

        keyDown(with: event)
        return true
    }

    private func makeShortcut(from event: NSEvent) -> AppCore.KeyboardShortcut? {
        let keyName: String

        switch Int(event.keyCode) {
        case kVK_Space:
            keyName = "Space"
        case kVK_Return:
            keyName = "Return"
        case kVK_Tab:
            keyName = "Tab"
        case kVK_Delete:
            keyName = "Delete"
        case kVK_ForwardDelete:
            keyName = "Forward Delete"
        case kVK_Escape:
            keyName = "Escape"
        default:
            guard let characters = event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !characters.isEmpty else {
                return nil
            }
            keyName = characters.uppercased()
        }

        let modifierFlags = normalizedModifierFlags(from: event.modifierFlags)
        let displayName = displayName(for: modifierFlags, keyName: keyName)
        let carbonModifiers = carbonModifiers(for: modifierFlags)

        return AppCore.KeyboardShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers,
            displayName: displayName
        ).normalized()
    }

    private func beginRecording() {
        isRecording = true
        liveModifierFlags = []
        liveModifierKeyCode = nil
        stringValue = "Type Shortcut"
        window?.makeFirstResponder(self)
    }

    private func endRecording() {
        isRecording = false
        liveModifierFlags = []
        liveModifierKeyCode = nil
        stringValue = currentShortcut?.displayName ?? "Click to Record"
    }

    private func commitModifierOnlyShortcut(from flags: NSEvent.ModifierFlags, keyCode: UInt32?) {
        let resolvedKeyCode = flags.modifierCount == 1 ? (keyCode ?? 0) : 0
        let shortcut = AppCore.KeyboardShortcut(
            keyCode: resolvedKeyCode,
            modifiers: carbonModifiers(for: flags),
            displayName: displayName(for: flags, keyName: nil, modifierKeyCode: resolvedKeyCode)
        ).normalized()

        currentShortcut = shortcut
        onShortcutChange?(shortcut)
        endRecording()
    }

    private func normalizedModifierFlags(from flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.control, .option, .shift, .command, .function])
    }

    private func carbonModifiers(for flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0

        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }

        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }

        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }

        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }

        if flags.contains(.function) {
            modifiers |= UInt32(kEventKeyModifierFnMask)
        }

        return modifiers
    }

    private func displayName(
        for flags: NSEvent.ModifierFlags,
        keyName: String?,
        modifierKeyCode: UInt32? = nil
    ) -> String {
        var components: [String] = []

        if flags.modifierCount == 1,
           let modifierKeyCode,
           let sidedModifierName = sidedModifierName(for: modifierKeyCode) {
            components.append(sidedModifierName)
        } else {
            if flags.contains(.control) {
                components.append("Control")
            }

            if flags.contains(.option) {
                components.append("Option")
            }

            if flags.contains(.shift) {
                components.append("Shift")
            }

            if flags.contains(.command) {
                components.append("Command")
            }

            if flags.contains(.function) {
                components.append("Function")
            }
        }

        if let keyName {
            components.append(keyName)
        }

        return components.joined(separator: "-")
    }

    private func sidedModifierName(for keyCode: UInt32) -> String? {
        switch Int(keyCode) {
        case kVK_Command:
            "Left Command"
        case kVK_RightCommand:
            "Right Command"
        case kVK_Control:
            "Left Control"
        case kVK_RightControl:
            "Right Control"
        case kVK_Option:
            "Left Option"
        case kVK_RightOption:
            "Right Option"
        case kVK_Shift:
            "Left Shift"
        case kVK_RightShift:
            "Right Shift"
        case kVK_Function:
            "Function"
        default:
            nil
        }
    }
}

private extension NSEvent.ModifierFlags {
    var modifierCount: Int {
        var count = 0

        if contains(.control) { count += 1 }
        if contains(.option) { count += 1 }
        if contains(.shift) { count += 1 }
        if contains(.command) { count += 1 }
        if contains(.function) { count += 1 }

        return count
    }
}
