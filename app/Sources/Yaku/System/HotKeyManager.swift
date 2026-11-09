import AppKit
import Carbon.HIToolbox
import YakuCore

/// Which shortcuts the system refused to register, by binding id. Carbon
/// answers `eventHotKeyExistsErr` when another app already holds the key, in
/// which case the shortcut looks set in Settings but never fires; the
/// recorder reads this to say so.
@MainActor
@Observable
final class HotKeyStatus {
    static let shared = HotKeyStatus()
    private(set) var failedBindingIDs: Set<String> = []

    fileprivate func record(_ failed: Set<String>) {
        guard failed != failedBindingIDs else { return }
        failedBindingIDs = failed
    }
}

/// Global hotkeys through Carbon's `RegisterEventHotKey`, which needs no
/// accessibility permission and works while another app is frontmost.
///
/// The three shortcuts are the ones in SPEC 12 and are configurable in the
/// settings window, so the registrations can be replaced at any time.
@MainActor
final class HotKeyManager {
    /// ⌃⌥J — translate the selection (SPEC 12).
    static let selectionID: UInt32 = 1
    /// ⌃⌥K — open or close the panel.
    static let panelID: UInt32 = 2
    /// ⌃⌥O — translate the screen (M4).
    static let screenID: UInt32 = 3

    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var hotKeyRefs: [EventHotKeyRef] = []
    nonisolated(unsafe) private var actions: [UInt32: () -> Void] = [:]

    /// Replaces every registration. A shortcut without modifiers is skipped:
    /// it would swallow ordinary typing everywhere.
    func update(bindings: [ShortcutBinding], actions: [UInt32: () -> Void]) {
        unregisterAll()
        self.actions = actions
        var failed: Set<String> = []
        for binding in bindings {
            guard let shortcut = binding.shortcut, shortcut.isUsable else { continue }
            let id = Self.id(for: binding.id)
            let status = register(
                keyCode: UInt32(shortcut.keyCode),
                modifiers: Self.carbonModifiers(shortcut.modifiers),
                id: id
            )
            if status != noErr { failed.insert(binding.id) }
        }
        HotKeyStatus.shared.record(failed)
    }

    static func id(for bindingID: String) -> UInt32 {
        switch bindingID {
        case ShortcutDefaults.panelID: panelID
        case ShortcutDefaults.screenID: screenID
        default: selectionID
        }
    }

    @discardableResult
    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> OSStatus {
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5941_4B55), id: id) // 'YAKU'
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if let ref { hotKeyRefs.append(ref) }
        AppLog.write("hotkey register id=\(id) keyCode=\(keyCode) modifiers=\(modifiers) status=\(status)")
        return status
    }

    private func unregisterAll() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
    }

    func invoke(id: UInt32) {
        actions[id]?()
    }

    /// Carbon's modifier constants, which are not the AppKit flags.
    static func carbonModifiers(_ modifiers: ShortcutModifiers) -> UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
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
                guard status == noErr else { return noErr }
                Unmanaged<HotKeyManager>.fromOpaque(userData)
                    .takeUnretainedValue()
                    .invoke(id: hotKeyID.id)
                return noErr
            },
            1,
            &eventType,
            pointer,
            &eventHandler
        )
    }

    deinit {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

extension ShortcutModifiers {
    /// The AppKit flags a key event carries.
    init(_ flags: NSEvent.ModifierFlags) {
        var value: ShortcutModifiers = []
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.shift) { value.insert(.shift) }
        self = value
    }
}
