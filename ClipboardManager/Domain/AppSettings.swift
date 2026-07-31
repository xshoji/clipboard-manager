import Foundation
import AppKit

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

    // MARK: - Default hotkey values
    //
    // Single source of truth for all hotkey default values. Both the
    // production UI (Reset buttons in HotkeyRecorderView / SettingsView)
    // and the E2E smoke-test harness (AppDelegate.forceE2EDefaultSettings)
    // MUST reference these constants so the two paths cannot drift.
    //
    // Key codes are Carbon virtual-key codes (exposed via NSEvent.keyCode).

    /// Global hotkey default: Cmd+Ctrl+X (keycode 7 = X).
    static let defaultHotkeyKeyCode = 7   // X
    static let defaultHotkeyModifiers = Int(
        NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.control.rawValue
    )

    /// Second global hotkey default: unset (optional shortcut that opens the
    /// history window and immediately shows the Macro Picker overlay).
    static let defaultGlobalMacroPickerHotkeyKeyCode = 0
    static let defaultGlobalMacroPickerHotkeyModifiers = 0

    /// Edit action hotkey default: Cmd+E (keycode 14 = E).
    static let defaultEditHotkeyCode = 14
    /// Paste Plain action hotkey default: Cmd+P (keycode 35 = P).
    static let defaultPastePlainHotkeyCode = 35
    /// Macro Picker overlay hotkey default: Cmd+M (keycode 46 = M).
    static let defaultMacroPickerHotkeyCode = 46
    /// All three action hotkeys default to Cmd-only modifiers.
    static let defaultActionHotkeyModifiers = Int(NSEvent.ModifierFlags.command.rawValue)

    /// Test-only hotkey modifiers: Cmd+Ctrl+Opt+Shift (4 modifiers).
    /// Guaranteed not to collide with the production default of Cmd+Ctrl.
    /// Used by the E2E smoke test harness via `AppDelegate.forceE2EDefaultSettings`.
    static let testHotkeyModifiers = Int(
        NSEvent.ModifierFlags.command.rawValue
        | NSEvent.ModifierFlags.control.rawValue
        | NSEvent.ModifierFlags.option.rawValue
        | NSEvent.ModifierFlags.shift.rawValue
    )

    @ObservationIgnored @Setting("hotkeyKeyCode", default: AppSettings.defaultHotkeyKeyCode)        var hotkeyKeyCode: Int
    @ObservationIgnored @Setting("hotkeyModifiers", default: AppSettings.defaultHotkeyModifiers)    var hotkeyModifiers: Int

    /// Optional second global hotkey that opens the history window and immediately
    /// shows the Macro Picker overlay. Defaults to unset (0,0).
    @ObservationIgnored @Setting("globalMacroPickerHotkeyKeyCode", default: AppSettings.defaultGlobalMacroPickerHotkeyKeyCode) var globalMacroPickerHotkeyKeyCode: Int
    @ObservationIgnored @Setting("globalMacroPickerHotkeyModifiers", default: AppSettings.defaultGlobalMacroPickerHotkeyModifiers) var globalMacroPickerHotkeyModifiers: Int

    /// Per-action hotkeys. Effective only while the history window is visible ( AppDelegate.installActionHotkeys / uninstallActionHotkeys ).
    /// Defaults: Edit = Cmd+E ( keycode 14 ), Paste Plain = Cmd+P ( keycode 35 ).
    @ObservationIgnored @Setting("editHotkeyCode", default: AppSettings.defaultEditHotkeyCode)        var editHotkeyCode: Int
    @ObservationIgnored @Setting("editHotkeyModifiers", default: AppSettings.defaultActionHotkeyModifiers) var editHotkeyModifiers: Int
    @ObservationIgnored @Setting("pastePlainHotkeyCode", default: AppSettings.defaultPastePlainHotkeyCode)  var pastePlainHotkeyCode: Int
    @ObservationIgnored @Setting("pastePlainHotkeyModifiers", default: AppSettings.defaultActionHotkeyModifiers) var pastePlainHotkeyModifiers: Int
   /// Macro Picker overlay hotkey. Default: Cmd+M (keycode 46 = M).
   /// Effective only while the history window is visible (same scope as edit / paste plain).
   @ObservationIgnored @Setting("macroPickerHotkeyCode", default: AppSettings.defaultMacroPickerHotkeyCode)  var macroPickerHotkeyCode: Int
   @ObservationIgnored @Setting("macroPickerHotkeyModifiers", default: AppSettings.defaultActionHotkeyModifiers) var macroPickerHotkeyModifiers: Int
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
    /// Enable synthetic Cmd+V paste (requires Accessibility permission).
    /// Stored with `didSet` (not `@ObservationIgnored @Setting`) so `@Observable`
    /// tracks changes and the Settings toggle updates reliably even after
    /// `requestAccessibility()` causes window focus changes.
    var needsAccessibilityForSyntheticPaste: Bool = false {
        didSet { UserDefaults.standard.set(needsAccessibilityForSyntheticPaste, forKey: "needsAccessibilityForSyntheticPaste") }
    }
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
    /// Stored as a plain stored property + `didSet` (like `previewWrapMode`,
    /// `isAlwaysOnTop`, etc.) so `@Observable` tracks changes and the Settings
    /// Picker updates. The previous `@Setting` wrapper was annotated
    /// `@ObservationIgnored`, which prevented SwiftUI from observing array changes,
    /// so selections in the Picker never reflected back. The initial value is
    /// restored in `init` alongside the other `didSet`-backed properties, so the
    /// restore timing is consistent with the rest of the class (the previous
    /// inline-initializer form read UserDefaults at first property access, which
    /// could theoretically drift if another thread wrote before evaluation).
    var ocrLanguages: [String] = ["en-US"] {
        didSet { UserDefaults.standard.set(ocrLanguages, forKey: "ocrLanguages") }
    }

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
        ocrLanguages      = UserDefaults.standard.object(forKey: "ocrLanguages")      as? [String] ?? ocrLanguages
        needsAccessibilityForSyntheticPaste = UserDefaults.standard.object(forKey: "needsAccessibilityForSyntheticPaste") as? Bool ?? needsAccessibilityForSyntheticPaste

        if !macroScriptsData.isEmpty,
           let decoded = try? JSONDecoder().decode([MacroScript].self, from: macroScriptsData) {
            macroScripts = decoded
        }
    }
}
