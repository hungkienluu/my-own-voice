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

    public var isModifierOnly: Bool {
        keyCode == 0 || modifierOnlyKeyCodes.contains(keyCode)
    }

    public var isSupportedGlobalShortcut: Bool {
        Self.normalizedGenericModifiers(from: modifiers) != 0
    }

    public func hasSameKeyEquivalent(as other: KeyboardShortcut) -> Bool {
        let lhs = normalized()
        let rhs = other.normalized()
        return lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    public static func canonicalKeyName(forKeyCode keyCode: UInt32, fallback: String? = nil) -> String? {
        keyNameMap[keyCode] ?? normalizedFallbackKeyName(fallback)
    }

    public func normalized() -> KeyboardShortcut {
        let normalizedKeyCode = Self.normalizedKeyCode(
            forKeyCode: keyCode,
            modifiers: modifiers
        )
        let normalizedModifiers: UInt32

        if normalizedKeyCode != 0,
           modifiers & UInt32(kEventKeyModifierFnMask) != 0,
           functionTransformedKeyCodes.contains(normalizedKeyCode) {
            normalizedModifiers = modifiers & ~UInt32(kEventKeyModifierFnMask)
        } else {
            normalizedModifiers = modifiers
        }

        return KeyboardShortcut(
            keyCode: normalizedKeyCode,
            modifiers: normalizedModifiers,
            displayName: Self.canonicalDisplayName(
                forKeyCode: normalizedKeyCode,
                modifiers: normalizedModifiers,
                existingDisplayName: displayName
            )
        )
    }

    private static func normalizedKeyCode(
        forKeyCode keyCode: UInt32,
        modifiers: UInt32
    ) -> UInt32 {
        guard modifierOnlyKeyCodes.contains(keyCode) else {
            return keyCode
        }

        let standaloneModifier = modifierBit(forStandaloneKeyCode: keyCode)
        guard standaloneModifier != 0,
              modifiers == standaloneModifier else {
            return 0
        }

        return keyCode
    }

    private static func canonicalDisplayName(
        forKeyCode keyCode: UInt32,
        modifiers: UInt32,
        existingDisplayName: String
    ) -> String {
        if let sidedModifierName = sidedModifierNameIfStandalone(forKeyCode: keyCode, modifiers: modifiers) {
            return sidedModifierName
        }

        let modifierNames = preferredModifierNames(
            from: existingDisplayName,
            modifiers: modifiers
        )
        let keyName = canonicalKeyName(
            forKeyCode: keyCode,
            fallback: fallbackKeyName(from: existingDisplayName)
        )

        var components = modifierNames

        if let keyName,
           !keyName.isEmpty,
           keyCode != 0,
           !modifierOnlyKeyCodes.contains(keyCode) {
            components.append(keyName)
        }

        if !components.isEmpty {
            return components.joined(separator: "-")
        }

        return normalizedFallbackKeyName(existingDisplayName) ?? existingDisplayName
    }

    private static func sidedModifierNameIfStandalone(forKeyCode keyCode: UInt32, modifiers: UInt32) -> String? {
        guard modifiers == modifierBit(forStandaloneKeyCode: keyCode) else {
            return nil
        }

        switch Int(keyCode) {
        case kVK_Command:
            return "Left Command"
        case kVK_RightCommand:
            return "Right Command"
        case kVK_Control:
            return "Left Control"
        case kVK_RightControl:
            return "Right Control"
        case kVK_Option:
            return "Left Option"
        case kVK_RightOption:
            return "Right Option"
        case kVK_Shift:
            return "Left Shift"
        case kVK_RightShift:
            return "Right Shift"
        case kVK_Function:
            return "Function"
        default:
            return nil
        }
    }

    private static func preferredModifierNames(from existingDisplayName: String, modifiers: UInt32) -> [String] {
        let defaultModifierNames = modifierNames(for: modifiers)
        let existingParts = existingDisplayName
            .split(separator: "-")
            .map(String.init)
        let prefix = existingParts.prefix { modifierBit(forName: $0) != 0 }

        guard !prefix.isEmpty else {
            return defaultModifierNames
        }

        let prefixModifiers = prefix.reduce(UInt32(0)) { partialResult, name in
            partialResult | modifierBit(forName: name)
        }

        guard prefixModifiers == normalizedGenericModifiers(from: modifiers) else {
            return defaultModifierNames
        }

        return Array(prefix)
    }

    private static func modifierNames(for modifiers: UInt32) -> [String] {
        var names: [String] = []

        if modifiers & UInt32(controlKey) != 0 {
            names.append("Control")
        }

        if modifiers & UInt32(optionKey) != 0 {
            names.append("Option")
        }

        if modifiers & UInt32(shiftKey) != 0 {
            names.append("Shift")
        }

        if modifiers & UInt32(cmdKey) != 0 {
            names.append("Command")
        }

        if modifiers & UInt32(kEventKeyModifierFnMask) != 0 {
            names.append("Function")
        }

        return names
    }

    private static func normalizedGenericModifiers(from modifiers: UInt32) -> UInt32 {
        var normalized: UInt32 = 0

        if modifiers & UInt32(controlKey) != 0 {
            normalized |= UInt32(controlKey)
        }

        if modifiers & UInt32(optionKey) != 0 {
            normalized |= UInt32(optionKey)
        }

        if modifiers & UInt32(shiftKey) != 0 {
            normalized |= UInt32(shiftKey)
        }

        if modifiers & UInt32(cmdKey) != 0 {
            normalized |= UInt32(cmdKey)
        }

        if modifiers & UInt32(kEventKeyModifierFnMask) != 0 {
            normalized |= UInt32(kEventKeyModifierFnMask)
        }

        return normalized
    }

    private static func modifierBit(forName name: String) -> UInt32 {
        switch name {
        case "Control":
            UInt32(controlKey)
        case "Option":
            UInt32(optionKey)
        case "Shift":
            UInt32(shiftKey)
        case "Command":
            UInt32(cmdKey)
        case "Function":
            UInt32(kEventKeyModifierFnMask)
        default:
            0
        }
    }

    private static func modifierBit(forStandaloneKeyCode keyCode: UInt32) -> UInt32 {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand:
            UInt32(cmdKey)
        case kVK_Control, kVK_RightControl:
            UInt32(controlKey)
        case kVK_Option, kVK_RightOption:
            UInt32(optionKey)
        case kVK_Shift, kVK_RightShift:
            UInt32(shiftKey)
        case kVK_Function:
            UInt32(kEventKeyModifierFnMask)
        default:
            0
        }
    }

    private static func fallbackKeyName(from displayName: String) -> String? {
        let parts = displayName
            .split(separator: "-")
            .map(String.init)
        let modifierPrefixCount = parts.prefix { modifierBit(forName: $0) != 0 }.count
        let keyParts = parts.dropFirst(modifierPrefixCount)
        guard !keyParts.isEmpty else { return nil }
        return keyParts.joined(separator: "-")
    }

    private static func normalizedFallbackKeyName(_ fallback: String?) -> String? {
        guard let fallback else { return nil }
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static let keyNameMap: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A",
        UInt32(kVK_ANSI_S): "S",
        UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_W): "W",
        UInt32(kVK_ANSI_E): "E",
        UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_Y): "Y",
        UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4",
        UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_Minus): "-",
        UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_0): "0",
        UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_LeftBracket): "[",
        UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_ANSI_KeypadDecimal): "Keypad .",
        UInt32(kVK_ANSI_KeypadMultiply): "Keypad *",
        UInt32(kVK_ANSI_KeypadPlus): "Keypad +",
        UInt32(kVK_ANSI_KeypadClear): "Keypad Clear",
        UInt32(kVK_ANSI_KeypadDivide): "Keypad /",
        UInt32(kVK_ANSI_KeypadEnter): "Keypad Enter",
        UInt32(kVK_ANSI_KeypadMinus): "Keypad -",
        UInt32(kVK_ANSI_KeypadEquals): "Keypad =",
        UInt32(kVK_ANSI_Keypad0): "Keypad 0",
        UInt32(kVK_ANSI_Keypad1): "Keypad 1",
        UInt32(kVK_ANSI_Keypad2): "Keypad 2",
        UInt32(kVK_ANSI_Keypad3): "Keypad 3",
        UInt32(kVK_ANSI_Keypad4): "Keypad 4",
        UInt32(kVK_ANSI_Keypad5): "Keypad 5",
        UInt32(kVK_ANSI_Keypad6): "Keypad 6",
        UInt32(kVK_ANSI_Keypad7): "Keypad 7",
        UInt32(kVK_ANSI_Keypad8): "Keypad 8",
        UInt32(kVK_ANSI_Keypad9): "Keypad 9",
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_Escape): "Escape",
        UInt32(kVK_Command): "Left Command",
        UInt32(kVK_Shift): "Left Shift",
        UInt32(kVK_CapsLock): "Caps Lock",
        UInt32(kVK_Option): "Left Option",
        UInt32(kVK_Control): "Left Control",
        UInt32(kVK_RightShift): "Right Shift",
        UInt32(kVK_RightOption): "Right Option",
        UInt32(kVK_RightControl): "Right Control",
        UInt32(kVK_Function): "Function",
        UInt32(kVK_F17): "F17",
        UInt32(kVK_VolumeUp): "Volume Up",
        UInt32(kVK_VolumeDown): "Volume Down",
        UInt32(kVK_Mute): "Mute",
        UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19",
        UInt32(kVK_F20): "F20",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F13): "F13",
        UInt32(kVK_F16): "F16",
        UInt32(kVK_F14): "F14",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F12): "F12",
        UInt32(kVK_F15): "F15",
        UInt32(kVK_Help): "Help",
        UInt32(kVK_Home): "Home",
        UInt32(kVK_PageUp): "Page Up",
        UInt32(kVK_ForwardDelete): "Forward Delete",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_End): "End",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_PageDown): "Page Down",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_LeftArrow): "Left Arrow",
        UInt32(kVK_RightArrow): "Right Arrow",
        UInt32(kVK_DownArrow): "Down Arrow",
        UInt32(kVK_UpArrow): "Up Arrow"
    ]
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

    public var managementDescription: String {
        switch self {
        case .holdToRecord:
            "Records while held. A quick double tap can lock recording on."
        case .toggleRecording:
            "Starts recording with one press and stops with the next."
        }
    }

    public var defaultShortcut: KeyboardShortcut {
        switch self {
        case .holdToRecord:
            .defaultHoldToRecord
        case .toggleRecording:
            .defaultToggleRecording
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
            "Unsupported hotkey identifier \(identifier). Global shortcuts need at least one modifier key."
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
    private var modifierOnlyGlobalMonitor: Any?
    private var modifierOnlyLocalMonitor: Any?
    private var activeRegularActions: Set<HotkeyAction> = []
    private var activeModifierOnlyActions: Set<HotkeyAction> = []

    public init() {}

    deinit {
        unregister()
    }

    public func register(shortcuts: [HotkeyAction: KeyboardShortcut]) throws {
        let normalizedShortcuts = shortcuts.mapValues { $0.normalized() }
        if let unsupportedShortcut = normalizedShortcuts.first(where: { !$0.value.isSupportedGlobalShortcut }) {
            throw HotkeyRegistrationError.unsupportedHotkey(unsupportedShortcut.key.rawValue)
        }

        let previousShortcuts = registeredShortcuts
        unregister()

        do {
            try registerNormalizedShortcuts(normalizedShortcuts)
        } catch {
            unregister()
            if !previousShortcuts.isEmpty {
                try? register(shortcuts: previousShortcuts)
            }
            throw error
        }

        registeredShortcuts = normalizedShortcuts
    }

    private func registerNormalizedShortcuts(_ normalizedShortcuts: [HotkeyAction: KeyboardShortcut]) throws {
        let regularShortcuts = normalizedShortcuts.filter { !$0.value.isModifierOnly }
        let modifierOnlyShortcuts = normalizedShortcuts.filter { $0.value.isModifierOnly }

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

        if let modifierOnlyGlobalMonitor {
            NSEvent.removeMonitor(modifierOnlyGlobalMonitor)
            self.modifierOnlyGlobalMonitor = nil
        }

        if let modifierOnlyLocalMonitor {
            NSEvent.removeMonitor(modifierOnlyLocalMonitor)
            self.modifierOnlyLocalMonitor = nil
        }

        activeRegularActions.removeAll()
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

    func handleEvent(identifier: UInt32, eventKind: UInt32) {
        guard let action = HotkeyAction(rawValue: identifier) else { return }

        switch eventKind {
        case UInt32(kEventHotKeyPressed):
            guard !activeRegularActions.contains(action) else { return }
            activeRegularActions.insert(action)
            onPress?(action)
        case UInt32(kEventHotKeyReleased):
            guard activeRegularActions.remove(action) != nil else { return }
            onRelease?(action)
        default:
            break
        }
    }

    private func installModifierOnlyMonitor() {
        if modifierOnlyGlobalMonitor == nil {
            modifierOnlyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleModifierOnlyFlagsChanged(event)
            }
        }

        if modifierOnlyLocalMonitor == nil {
            modifierOnlyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleModifierOnlyFlagsChanged(event)
                return event
            }
        }
    }

    private func handleModifierOnlyFlagsChanged(_ event: NSEvent) {
        let activeFlags = normalizedModifierFlags(from: event.modifierFlags)
        let activeDeviceModifierFlags = event.modifierFlags.rawValue & deviceSpecificModifierMask

        for (action, shortcut) in registeredShortcuts where shortcut.isModifierOnly {
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
