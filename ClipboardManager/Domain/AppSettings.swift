import Foundation
import AppKit
import Carbon.HIToolbox

@propertyWrapper
struct Setting<T> {
    let key: String
    let defaultValue: T
    let storedIn: UserDefaults

    init(_ key: String, default defaultValue: T, storedIn: UserDefaults = .standard) {
        self.key = key
        self.defaultValue = defaultValue
        self.storedIn = storedIn
    }

    var wrappedValue: T {
        get {
            if let val = storedIn.object(forKey: key) as? T {
                return val
            }
            return defaultValue
        }
        nonmutating set {
            storedIn.set(newValue, forKey: key)
        }
    }
}

@Observable
final class AppSettings: @unchecked Sendable {
    static let shared = AppSettings()

    @ObservationIgnored @Setting("hotkeyKeyCode", default: 7)        var hotkeyKeyCode: Int        // 7 = X
    @ObservationIgnored @Setting("hotkeyModifiers", default: 196608) var hotkeyModifiers: Int       // cmd+ctrl

    /// Per-action hotkeys. Effective only while the history window is visible ( AppDelegate.installActionHotkeys / uninstallActionHotkeys ).
    /// Defaults: Edit = Cmd+E ( keycode 14 ), Paste Plain = Cmd+P ( keycode 35 ).
    @ObservationIgnored @Setting("editHotkeyCode", default: 14)        var editHotkeyCode: Int
    @ObservationIgnored @Setting("editHotkeyModifiers", default: Int(NSEvent.ModifierFlags.command.rawValue)) var editHotkeyModifiers: Int
    @ObservationIgnored @Setting("pastePlainHotkeyCode", default: 35)  var pastePlainHotkeyCode: Int
    @ObservationIgnored @Setting("pastePlainHotkeyModifiers", default: Int(NSEvent.ModifierFlags.command.rawValue)) var pastePlainHotkeyModifiers: Int
   /// Macro Picker overlay hotkey. Default: Cmd+M (keycode 46 = M).
   /// Effective only while the history window is visible (same scope as edit / paste plain).
   @ObservationIgnored @Setting("macroPickerHotkeyCode", default: 46)  var macroPickerHotkeyCode: Int
   @ObservationIgnored @Setting("macroPickerHotkeyModifiers", default: Int(NSEvent.ModifierFlags.command.rawValue)) var macroPickerHotkeyModifiers: Int
    @ObservationIgnored @Setting("retentionDays", default: 30)        var retentionDays: Int
    @ObservationIgnored @Setting("maxHistoryCount", default: 1000)    var maxHistoryCount: Int
    @ObservationIgnored @Setting("maxItemSizeMB", default: 10)         var maxItemSizeMB: Int
    /// Pasteboard polling interval in milliseconds.
    /// `NSPasteboard.changeCount` does not publish KVO notifications, so polling is the
    /// only option (review #15). 250 ms balances responsiveness with CPU/energy cost;
    /// shorter than Maccy (<100 ms) but far less busy than 500 ms while still feeling
    /// near-instant for typical copy operations. Tunable via Settings in the future.
    @ObservationIgnored @Setting("pollingIntervalMs", default: 250)   var pollingIntervalMs: Int
    @ObservationIgnored @Setting("macroSameDirectoryFingerprint", default: true) var macroSameDirectoryFingerprint: Bool
    @ObservationIgnored @Setting("needsAccessibilityForSyntheticPaste", default: false) var needsAccessibilityForSyntheticPaste: Bool
    @ObservationIgnored @Setting("launchAtLogin", default: false) var launchAtLogin: Bool
    /// Behavior when a Macro fails (design-implementation.md §5: timeout / non-zero exit).
    /// - `restoreOriginalAndNotify` (default): restores the original content to the pasteboard, returns to the previous app, and posts a notification.
    /// - `notifyOnly`: posts a notification only; does not restore the pasteboard or the previous app.
    /// - `ignore`: does nothing (legacy no-alert behavior).
    @ObservationIgnored @Setting("macroFailureBehavior", default: "restoreOriginalAndNotify") var macroFailureBehavior: String
    /// Recognition languages for the "Paste Plain" → image OCR flow.
    /// Default is English-only (`["en-US"]`) per the user's decision. The user can
    /// switch the language set in Settings. Vision accepts BCP-47 identifiers; an
    /// empty array falls back to Vision's defaults, so we keep the default non-empty.
    @ObservationIgnored @Setting("ocrLanguages", default: ["en-US"]) var ocrLanguages: [String]

    var isAlwaysOnTop: Bool = false {
        didSet { UserDefaults.standard.set(isAlwaysOnTop, forKey: "isAlwaysOnTop") }
    }
    var isSidebarVisible: Bool = true {
        didSet { UserDefaults.standard.set(isSidebarVisible, forKey: "isSidebarVisible") }
    }
    var isSplitView: Bool = true {
        didSet { UserDefaults.standard.set(isSplitView, forKey: "isSplitView") }
    }
    var previewWrapMode: String = "wrap" {
        didSet { UserDefaults.standard.set(previewWrapMode, forKey: "previewWrapMode") }
    }
    /// History window placement when invoked by the global hotkey / menu bar.
    /// - `"center"` (default): center of the screen containing the cursor.
    /// - `"nearCursor"`: position the window near the cursor (design-ui.md §1).
    var windowPositionMode: String = "center" {
        didSet { UserDefaults.standard.set(windowPositionMode, forKey: "windowPositionMode") }
    }

    @ObservationIgnored @Setting("macroScriptsData", default: Data()) var macroScriptsData: Data

    /// Macro script registrations.
    /// Threading invariant (review #12): this property is mutated only on the main actor
    /// (SwiftUI views and `@MainActor` AppDelegate). `AppSettings` is `@unchecked Sendable`
    /// because of the `shared` singleton; the `macroScripts` mutation path is safe as long
    /// as callers keep main-actor access. Mutation is done by whole-array reassignment
    /// (`settings.macroScripts = arr`), so `didSet` reliably fires and re-encodes to
    /// `macroScriptsData` + posts `.macroScriptsChanged`. A full `@Observable`+`Sendable`
    /// migration would make this enforced by the type system; deferred until that refactor.
    var macroScripts: [MacroScript] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(macroScripts) {
                macroScriptsData = data
            }
            NotificationCenter.default.post(name: .macroScriptsChanged, object: nil)
        }
    }

    private init() {
        isAlwaysOnTop     = UserDefaults.standard.object(forKey: "isAlwaysOnTop")     as? Bool ?? isAlwaysOnTop
        isSidebarVisible  = UserDefaults.standard.object(forKey: "isSidebarVisible")  as? Bool ?? isSidebarVisible
        isSplitView       = UserDefaults.standard.object(forKey: "isSplitView")       as? Bool ?? isSplitView
        previewWrapMode   = UserDefaults.standard.object(forKey: "previewWrapMode")   as? String ?? previewWrapMode
        windowPositionMode = UserDefaults.standard.object(forKey: "windowPositionMode") as? String ?? windowPositionMode

        if !macroScriptsData.isEmpty,
           let decoded = try? JSONDecoder().decode([MacroScript].self, from: macroScriptsData) {
            macroScripts = decoded
        }
    }

    var hotkeyModifiersCarbon: UInt32 {
        UInt32(carbonModifiers(for: hotkeyModifiers))
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
}
