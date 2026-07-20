import AppKit
import Carbon.HIToolbox
import os

@MainActor
final class HotkeyManager {
    private static let logger = Logger(subsystem: "com.xshoji.ClipboardManager", category: "HotkeyManager")

    private let settings: AppSettings
    private var hotkeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var mainCallback: (@MainActor () -> Void)?
    private let mainRegistryID = UInt32(0xABCD_0001)
    private var registeredMainKeyCode: Int?
    private var registeredMainModifiers: Int?

    /// Registration table for per-Hook shortcuts.
    /// The key is EventHotKeyID.id (a unique internal sequence number).
    private struct HookRegistration {
        let hookID: UInt32      // The original HookScript.id.hashValue converted to UInt32
        let hotkeyRef: EventHotKeyRef
        let callback: @MainActor () -> Void
    }
    private var hookRegistrations: [UInt32: HookRegistration] = [:]     // [eventID: registration]
    private var hookIDToEventID: [UInt32: UInt32] = [:]               // [hookID: eventID]
    private var eventIDCounter: UInt32 = 0xABCD_1000

    /// Registration table for per-action shortcuts (edit / paste plain / etc.).
    /// Effective only while the history window is visible ( design: window-scoped action hotkeys ).
    private struct ActionRegistration {
        let actionID: UInt32
        let hotkeyRef: EventHotKeyRef
        let callback: @MainActor () -> Void
    }
    private var actionRegistrations: [UInt32: ActionRegistration] = [:]   // [actionID: registration]

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Main UI hotkey

    @discardableResult
    func register(callback: @escaping @MainActor () -> Void) -> Bool {
        self.mainCallback = callback
        return reinstall()
    }

    @discardableResult
    func reinstall() -> Bool {
        ensureEventHandlerInstalled()
        let cocoaModifiers = settings.hotkeyModifiers
        let cocoaKeyCode = settings.hotkeyKeyCode
        let mods = UInt32(settings.hotkeyModifiersCarbon)
        let keyCode = UInt32(cocoaKeyCode)

        if registeredMainKeyCode == cocoaKeyCode,
           registeredMainModifiers == cocoaModifiers,
           hotkeyRef != nil {
            return true
        }
        guard mods != 0 || keyCode != 0 else {
            unregisterMain()
            return true
        }

        var newHotkeyRef: EventHotKeyRef?
        let reg = RegisterEventHotKey(
            keyCode, mods,
            EventHotKeyID(signature: OSType(0x4342_4D47), id: mainRegistryID),
            GetApplicationEventTarget(), 0, &newHotkeyRef
        )
        guard reg == noErr, let newHotkeyRef else {
            Self.logger.error("RegisterEventHotKey (main) failed: \(reg)")
            if let registeredMainKeyCode, let registeredMainModifiers {
                settings.hotkeyKeyCode = registeredMainKeyCode
                settings.hotkeyModifiers = registeredMainModifiers
            }
            return false
        }

        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
        }
        hotkeyRef = newHotkeyRef
        registeredMainKeyCode = cocoaKeyCode
        registeredMainModifiers = cocoaModifiers
        return true
    }

    func unregisterMain() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        registeredMainKeyCode = nil
        registeredMainModifiers = nil
    }

    func unregister() {
        unregisterMain()
        unregisterAllHookHotkeys()
        unregisterAllActionHotkeys()
        if let h = eventHandler {
            RemoveEventHandler(h)
            eventHandler = nil
        }
    }

    // MARK: - Per-Hook shortcuts (design-app.md §2.2.2)

    /// Registers the hotkey for a given HookScript with Carbon.
    /// - Parameters:
    ///   - hookID: Stable ID converted from HookScript.id to UInt32
    ///   - keyCode: Physical key code
    ///   - modifiers: Raw Cocoa modifier flags (OR of cmd/ctrl/option/shift)
    ///   - callback: MainActor callback invoked on firing
    /// - Returns: Whether registration succeeded. Returns `false` if modifiers are 0 or Carbon registration fails.
    @discardableResult
    func registerHookHotkey(hookID: UInt32, keyCode: Int, modifiers: Int, callback: @escaping @MainActor () -> Void) -> Bool {
        unregisterHookHotkey(hookID: hookID)
        // macOS physical key code 0 corresponds to the A key, so it cannot be used to mean "unset".
        guard modifiers != 0 else { return false }
        ensureEventHandlerInstalled()

        let mods = carbonModifiers(for: modifiers)
        let eventID = nextHookEventID(for: hookID)
        var ref: EventHotKeyRef?
        let reg = RegisterEventHotKey(
            UInt32(keyCode), mods,
            EventHotKeyID(signature: OSType(0x4342_4D47), id: eventID),
            GetApplicationEventTarget(), 0, &ref
        )
        guard reg == noErr, let ref else {
            Self.logger.error("Hook hotkey RegisterEventHotKey failed: \(reg)")
            return false
        }
        hookRegistrations[eventID] = HookRegistration(hookID: hookID, hotkeyRef: ref, callback: callback)
        return true
    }

    func unregisterHookHotkey(hookID: UInt32) {
        guard let eventID = hookIDToEventID[hookID], let reg = hookRegistrations[eventID] else { return }
        UnregisterEventHotKey(reg.hotkeyRef)
        hookRegistrations.removeValue(forKey: eventID)
        hookIDToEventID.removeValue(forKey: hookID)
    }

    func unregisterAllHookHotkeys() {
        for (_, reg) in hookRegistrations {
            UnregisterEventHotKey(reg.hotkeyRef)
        }
        hookRegistrations.removeAll()
        hookIDToEventID.removeAll()
    }

    // MARK: - Per-action shortcuts (window-scoped; design: edit / paste plain / etc.)

    /// Registers a window-scoped action hotkey. The actionID namespace is independent from hookIDs.
    /// - Parameters:
    ///   - actionID: Stable identifier per action ( e.g. 0x0001 = edit, 0x0002 = paste plain ). Must be non-zero and unique within the app.
    ///   - keyCode: Physical key code
    ///   - modifiers: Raw Cocoa modifier flags ( OR of cmd / ctrl / option / shift ). 0 means "unset" and is rejected.
    ///   - callback: MainActor callback invoked on firing
    /// - Returns: Whether registration succeeded.
    @discardableResult
    func registerActionHotkey(actionID: UInt32, keyCode: Int, modifiers: Int, callback: @escaping @MainActor () -> Void) -> Bool {
        unregisterActionHotkey(actionID: actionID)
        guard modifiers != 0 else { return false }
        ensureEventHandlerInstalled()

        let mods = carbonModifiers(for: modifiers)
        var ref: EventHotKeyRef?
        let reg = RegisterEventHotKey(
            UInt32(keyCode), mods,
            EventHotKeyID(signature: OSType(0x4342_4D47), id: actionID),
            GetApplicationEventTarget(), 0, &ref
        )
        guard reg == noErr, let ref else {
            Self.logger.error("Action hotkey RegisterEventHotKey failed (actionID=\(actionID)): \(reg)")
            return false
        }
        actionRegistrations[actionID] = ActionRegistration(actionID: actionID, hotkeyRef: ref, callback: callback)
        return true
    }

    func unregisterActionHotkey(actionID: UInt32) {
        guard let reg = actionRegistrations.removeValue(forKey: actionID) else { return }
        UnregisterEventHotKey(reg.hotkeyRef)
    }

    func unregisterAllActionHotkeys() {
        for (_, reg) in actionRegistrations {
            UnregisterEventHotKey(reg.hotkeyRef)
        }
        actionRegistrations.removeAll()
    }

    // MARK: - Private

    private func ensureEventHandlerInstalled() {
        guard eventHandler == nil else { return }
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, refCon) -> OSStatus in
                guard let refCon else { return noErr }
                // Retrieves the fired EventHotKeyID and dispatches it.
                var hotKeyID = EventHotKeyID(signature: 0, id: 0)
                let size = MemoryLayout<EventHotKeyID>.size
                var actualSize = size
                let getStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    size, &actualSize, &hotKeyID
                )
                let address = UInt(bitPattern: refCon)
                let eventID = (getStatus == noErr) ? hotKeyID.id : 0
                Task { @MainActor in
                    guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(pointer).takeUnretainedValue()
                    manager.dispatchHotkey(eventID: eventID)
                }
                return noErr
            },
            1, &eventSpec, selfPtr, &eventHandler
        )
        if status != noErr {
            Self.logger.error("InstallEventHandler failed: \(status)")
        }
    }

    private func dispatchHotkey(eventID: UInt32) {
        if eventID == mainRegistryID {
            mainCallback?()
            return
        }
        if let reg = actionRegistrations[eventID] {
            reg.callback()
            return
        }
        if let reg = hookRegistrations[eventID] {
            reg.callback()
            return
        }
        // Fallback when an old registration remains: do nothing.
    }

    private func carbonModifiers(for cocoaMod: Int) -> UInt32 {
        var mods: UInt32 = 0
        let flags = UInt(cocoaMod)
        if flags & NSEvent.ModifierFlags.shift.rawValue != 0 { mods |= UInt32(shiftKey) }
        if flags & NSEvent.ModifierFlags.control.rawValue != 0 { mods |= UInt32(controlKey) }
        if flags & NSEvent.ModifierFlags.option.rawValue != 0 { mods |= UInt32(optionKey) }
        if flags & NSEvent.ModifierFlags.command.rawValue != 0 { mods |= UInt32(cmdKey) }
        return mods
    }

    private func nextHookEventID(for hookID: UInt32) -> UInt32 {
        if let existing = hookIDToEventID[hookID] { return existing }
        let id = eventIDCounter
        eventIDCounter &+= 1
        hookIDToEventID[hookID] = id
        return id
    }
}
