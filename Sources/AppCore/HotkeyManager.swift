import AppKit
import Carbon
import Foundation

public struct KeyboardShortcut: Hashable, Codable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let displayName: String

    public init(keyCode: UInt32, modifiers: UInt32, displayName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayName = displayName
    }

    public static let defaultHoldToRecord = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(cmdKey) | UInt32(optionKey),
        displayName: "Command-Option-R"
    )

    public static let defaultToggleRecording = KeyboardShortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey) | UInt32(shiftKey),
        displayName: "Option-Shift-Space"
    )

    public func normalized() -> KeyboardShortcut {
        guard keyCode != 0,
              modifiers & UInt32(kEventKeyModifierFnMask) != 0,
              functionTransformedKeyCodes.contains(keyCode) else {
            return self
        }

        return KeyboardShortcut(
            keyCode: keyCode,
            modifiers: modifiers & ~UInt32(kEventKeyModifierFnMask),
            displayName: displayName.replacingOccurrences(of: "Function-", with: "")
        )
    }
}

public enum HotkeyAction: UInt32, CaseIterable, Codable, Hashable, Sendable {
    case holdToRecord = 1
    case toggleRecording = 2

    public var displayName: String {
        switch self {
        case .holdToRecord:
            "Hold to Record"
        case .toggleRecording:
            "Toggle Recording"
        }
    }
}

public enum HotkeyRegistrationError: Error, LocalizedError {
    case registrationFailed(OSStatus)
    case unsupportedHotkey(UInt32)

    public var errorDescription: String? {
        switch self {
        case let .registrationFailed(status):
            "RegisterEventHotKey failed with status \(status)."
        case let .unsupportedHotkey(identifier):
            "Unsupported hotkey identifier \(identifier)."
        }
    }
}

private let hotKeySignature: OSType = 0x4D4F5643

private func hotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr else {
        return status
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handleEvent(identifier: hotKeyID.id, eventKind: GetEventKind(event))
    return noErr
}

public final class HotkeyManager {
    public var onPress: ((HotkeyAction) -> Void)?
    public var onRelease: ((HotkeyAction) -> Void)?
    public private(set) var registeredShortcuts: [HotkeyAction: KeyboardShortcut] = [:]

    private var hotKeyRefs: [HotkeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var modifierOnlyMonitor: Any?
    private var activeModifierOnlyActions: Set<HotkeyAction> = []

    public init() {}

    deinit {
        unregister()
    }

    public func register(shortcuts: [HotkeyAction: KeyboardShortcut]) throws {
        unregister()
        let normalizedShortcuts = shortcuts.mapValues { $0.normalized() }
        registeredShortcuts = normalizedShortcuts

        let regularShortcuts = normalizedShortcuts.filter { !isModifierOnly($0.value) }
        let modifierOnlyShortcuts = normalizedShortcuts.filter { isModifierOnly($0.value) }

        if !regularShortcuts.isEmpty {
            try installHandlerIfNeeded()

            for (action, shortcut) in regularShortcuts {
                let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: action.rawValue)
                var hotKeyRef: EventHotKeyRef?
                let status = RegisterEventHotKey(
                    shortcut.keyCode,
                    shortcut.modifiers,
                    hotKeyID,
                    GetEventDispatcherTarget(),
                    0,
                    &hotKeyRef
                )

                guard status == noErr, let hotKeyRef else {
                    unregister()
                    throw HotkeyRegistrationError.registrationFailed(status)
                }

                hotKeyRefs[action] = hotKeyRef
            }
        }

        if !modifierOnlyShortcuts.isEmpty {
            installModifierOnlyMonitor()
        }
    }

    public func shortcut(for action: HotkeyAction) -> KeyboardShortcut? {
        registeredShortcuts[action]
    }

    public func unregister() {
        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }

        hotKeyRefs.removeAll()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }

        if let modifierOnlyMonitor {
            NSEvent.removeMonitor(modifierOnlyMonitor)
            self.modifierOnlyMonitor = nil
        }

        activeModifierOnlyActions.removeAll()
        registeredShortcuts.removeAll()
    }

    private func installHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyEventHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        guard status == noErr else {
            throw HotkeyRegistrationError.registrationFailed(status)
        }
    }

    fileprivate func handleEvent(identifier: UInt32, eventKind: UInt32) {
        guard let action = HotkeyAction(rawValue: identifier) else { return }

        switch eventKind {
        case UInt32(kEventHotKeyPressed):
            onPress?(action)
        case UInt32(kEventHotKeyReleased):
            onRelease?(action)
        default:
            break
        }
    }

    private func installModifierOnlyMonitor() {
        modifierOnlyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierOnlyFlagsChanged(event)
        }
    }

    private func handleModifierOnlyFlagsChanged(_ event: NSEvent) {
        let activeFlags = normalizedModifierFlags(from: event.modifierFlags)
        let activeDeviceModifierFlags = event.modifierFlags.rawValue & deviceSpecificModifierMask

        for (action, shortcut) in registeredShortcuts where isModifierOnly(shortcut) {
            let shortcutFlags = modifierFlags(for: shortcut)
            let isActive = activeModifierOnlyActions.contains(action)
            let matches = activeFlags == shortcutFlags
                && modifierSideMatches(shortcut, activeDeviceModifierFlags: activeDeviceModifierFlags)

            if matches && !isActive {
                activeModifierOnlyActions.insert(action)
                onPress?(action)
            } else if !matches && isActive {
                activeModifierOnlyActions.remove(action)
                onRelease?(action)
            }
        }
    }

    private func isModifierOnly(_ shortcut: KeyboardShortcut) -> Bool {
        shortcut.keyCode == 0 || modifierOnlyKeyCodes.contains(shortcut.keyCode)
    }

    private func modifierFlags(for shortcut: KeyboardShortcut) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []

        if shortcut.modifiers & UInt32(controlKey) != 0 {
            flags.insert(.control)
        }

        if shortcut.modifiers & UInt32(optionKey) != 0 {
            flags.insert(.option)
        }

        if shortcut.modifiers & UInt32(shiftKey) != 0 {
            flags.insert(.shift)
        }

        if shortcut.modifiers & UInt32(cmdKey) != 0 {
            flags.insert(.command)
        }

        if shortcut.modifiers & UInt32(kEventKeyModifierFnMask) != 0 {
            flags.insert(.function)
        }

        return flags
    }

    private func normalizedModifierFlags(from flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.control, .option, .shift, .command, .function])
    }

    private func modifierSideMatches(
        _ shortcut: KeyboardShortcut,
        activeDeviceModifierFlags: NSEvent.ModifierFlags.RawValue
    ) -> Bool {
        let requiredMask = requiredDeviceModifierMask(for: shortcut)
        guard requiredMask != 0 else { return true }
        return activeDeviceModifierFlags & requiredMask != 0
    }

    private func requiredDeviceModifierMask(for shortcut: KeyboardShortcut) -> NSEvent.ModifierFlags.RawValue {
        switch shortcut.keyCode {
        case UInt32(kVK_Command):
            return UInt(NX_DEVICELCMDKEYMASK)
        case UInt32(kVK_RightCommand):
            return UInt(NX_DEVICERCMDKEYMASK)
        case UInt32(kVK_Control):
            return UInt(NX_DEVICELCTLKEYMASK)
        case UInt32(kVK_RightControl):
            return UInt(NX_DEVICERCTLKEYMASK)
        case UInt32(kVK_Option):
            return UInt(NX_DEVICELALTKEYMASK)
        case UInt32(kVK_RightOption):
            return UInt(NX_DEVICERALTKEYMASK)
        case UInt32(kVK_Shift):
            return UInt(NX_DEVICELSHIFTKEYMASK)
        case UInt32(kVK_RightShift):
            return UInt(NX_DEVICERSHIFTKEYMASK)
        default:
            return 0
        }
    }
}

private let deviceSpecificModifierMask: NSEvent.ModifierFlags.RawValue =
    UInt(NX_DEVICELCTLKEYMASK)
    | UInt(NX_DEVICERCTLKEYMASK)
    | UInt(NX_DEVICELSHIFTKEYMASK)
    | UInt(NX_DEVICERSHIFTKEYMASK)
    | UInt(NX_DEVICELCMDKEYMASK)
    | UInt(NX_DEVICERCMDKEYMASK)
    | UInt(NX_DEVICELALTKEYMASK)
    | UInt(NX_DEVICERALTKEYMASK)

private let modifierOnlyKeyCodes: Set<UInt32> = [
    UInt32(kVK_Command),
    UInt32(kVK_RightCommand),
    UInt32(kVK_Control),
    UInt32(kVK_RightControl),
    UInt32(kVK_Option),
    UInt32(kVK_RightOption),
    UInt32(kVK_Shift),
    UInt32(kVK_RightShift),
    UInt32(kVK_Function)
]

private let functionTransformedKeyCodes: Set<UInt32> = [
    UInt32(kVK_Help),
    UInt32(kVK_Home),
    UInt32(kVK_PageUp),
    UInt32(kVK_ForwardDelete),
    UInt32(kVK_End),
    UInt32(kVK_PageDown)
]
