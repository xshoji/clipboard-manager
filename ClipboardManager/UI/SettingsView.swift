import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var retention: Int
    @State private var maxCount: Int
    @State private var maxItem: Int
    @State private var hotkeyAlert: HotkeyAlert?
    @State private var selectedSection: SettingsSection = .application

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case application
        case macros

        var id: Self { self }

        var title: String {
            switch self {
            case .application: "App Settings"
            case .macros: "Macros"
            }
        }

        var systemImage: String {
            switch self {
            case .application: "gearshape"
            case .macros: "terminal"
            }
        }
    }

    private enum HotkeyAlert: Identifiable {
        case unavailable
        case actionDuplicate

        var id: Self { self }

        var title: String {
            switch self {
            case .unavailable: "Hotkey unavailable"
            case .actionDuplicate: "Action hotkey duplicate"
            }
        }

        var message: String {
            switch self {
            case .unavailable:
                "That shortcut is already registered by another app or Macro. Choose a different shortcut."
            case .actionDuplicate:
                "Action hotkeys cannot share the same shortcut. Choose a different shortcut for one of them."
            }
        }
    }

    init() {
        let s = AppSettings.shared
        _retention = State(initialValue: s.retentionDays)
        _maxCount = State(initialValue: s.maxHistoryCount)
        _maxItem = State(initialValue: s.maxItemSizeMB)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
                    .accessibilityIdentifier("settings.\(section.rawValue)")
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            switch selectedSection {
            case .application:
                applicationSettings
            case .macros:
                MacroManagementView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 640)
    }

    private var applicationSettings: some View {
        Form {
            Section("History") {
                Picker("Retention", selection: $retention) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("365 days").tag(365)
                    Text("Unlimited").tag(0)
                }
                .accessibilityIdentifier("history.retention")
                .onChange(of: retention) { _, v in commit(key: \.retentionDays, v); notify(.retentionChanged) }

                Picker("Max items", selection: $maxCount) {
                    Text("100").tag(100)
                    Text("500").tag(500)
                    Text("1,000").tag(1000)
                    Text("5,000").tag(5000)
                    Text("10,000").tag(10000)
                    Text("50,000").tag(50000)
                    Text("100,000").tag(100000)
                }
                .accessibilityIdentifier("history.maxItems")
                .onChange(of: maxCount) { _, v in commit(key: \.maxHistoryCount, v); notify(.maxCountChanged) }

                Stepper(value: $maxItem, in: 1...100) {
                    Text("Max item size: \(maxItem) MB")
                        .accessibilityIdentifier("history.maxItemSize")
                }.onChange(of: maxItem) { _, v in commit(key: \.maxItemSizeMB, v) }
            }

            Section("Global Hotkey") {
                HotkeyRecorderView()
            }

            Section("Global Macro Picker Hotkey") {
                HotkeyRecorderView(
                    keyCode: Binding(
                        get: { settings.globalMacroPickerHotkeyKeyCode },
                        set: { settings.globalMacroPickerHotkeyKeyCode = $0 }
                    ),
                    modifiers: Binding(
                        get: { settings.globalMacroPickerHotkeyModifiers },
                        set: { settings.globalMacroPickerHotkeyModifiers = $0 }
                    ),
                    onRecordingStart: {
                        NotificationCenter.default.post(name: .globalHotkeyRecordingStarted, object: nil)
                    },
                    onRecordingCancel: {
                        NotificationCenter.default.post(name: .globalHotkeyRecordingCancelled, object: nil)
                    },
                    onChange: { NotificationCenter.default.post(name: .globalMacroPickerHotkeyChanged, object: nil) },
                    title: "Direct macro picker",
                    systemImage: "command.square",
                    accessibilityIDPrefix: "globalMacroPickerHotkey",
                    defaultKeyCode: AppSettings.defaultGlobalMacroPickerHotkeyKeyCode,
                    defaultModifiers: AppSettings.defaultGlobalMacroPickerHotkeyModifiers,
                    showReset: false,
                    showClear: true
                )
                Text("Set an optional shortcut that opens ClipboardManager and immediately shows the Macro Picker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Action Hotkeys") {
                Text("Effective only while the ClipboardManager history window is visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(ActionHotkeyKind.allCases, id: \.self) { kind in
                    HStack {
                        Text(kind.label)
                            .accessibilityIdentifier("action.\(kind.idPrefix).label")
                        Spacer()
                        MacroHotkeyRecorderView(
                            keyCode: Binding(
                                get: { settings[keyPath: kind.keyCodePath] },
                                set: { _ in
                                    // No-op: `applyActionHotkey` is the single
                                    // writer for this kind's setting so the
                                    // duplicate guard always runs and the
                                    // pre-change value can be reverted. The
                                    // display refreshes via `onChange(of:)`
                                    // after the setter writes (review #2).
                                }
                            ),
                            modifiers: Binding(
                                get: { settings[keyPath: kind.modifiersPath] },
                                set: { _ in }
                            ),
                            onShortcutChange: { keyCode, mods in
                                applyActionHotkey(kind, keyCode: keyCode, modifiers: mods)
                            },
                            resetAction: {
                                applyActionHotkey(
                                    kind,
                                    keyCode: kind.defaultKeyCode,
                                    modifiers: kind.defaultModifiers
                                )
                            },
                            accessibilityIDPrefix: "action.\(kind.idPrefix)"
                        )
                    }
                }
                 Text("Defaults: Edit ⌘E, Plain Text ⌘P, Macro Picker ⌘M. Set modifiers clear to unset an action.")
                     .font(.caption)
                     .foregroundStyle(.secondary)
               Text("Macro Picker opens a keyboard-driven list: ↑/↓ to navigate, Return to run, Esc to close.")
                   .font(.caption2)
                   .foregroundStyle(.secondary)
            }

            Section("Paste Behavior") {
                Toggle(
                    "Allow synthetic Cmd+V (requires Accessibility)",
                    isOn: Binding(
                        get: { settings.needsAccessibilityForSyntheticPaste },
                        set: { enabled in
                            settings.needsAccessibilityForSyntheticPaste = enabled
                            if enabled {
                                InputPermission().requestAccessibility()
                            }
                        }
                    )
                )
                Button("Request Accessibility permission") {
                    InputPermission().openAccessibilitySettingsPane()
                }
                Divider()
                Text("Plain Text on an image runs OCR and pastes the recognized text. Choose the recognition language set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Automatically index text in new images",
                    isOn: Binding(
                        get: { settings.automaticImageOcrEnabled },
                        set: { settings.automaticImageOcrEnabled = $0 }
                    )
                )
                .accessibilityIdentifier("automaticImageOcr")
                Text("Runs on device in the background. Existing images are not analyzed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("OCR languages", selection: Binding(
                    get: { settings.ocrLanguages },
                    set: { settings.ocrLanguages = $0 }
                )) {
                    Text("English").tag(["en-US"])
                    Text("Japanese").tag(["ja-JP"])
                    Text("Japanese + English").tag(["ja-JP", "en-US"])
                    Text("Chinese (Simplified)").tag(["zh-Hans"])
                    Text("Korean").tag(["ko-KR"])
                }
            }

            Section("UI") {
                Picker("Preview wrap", selection: Binding(get: { settings.previewWrapMode }, set: { settings.previewWrapMode = $0 })) {
                    Text("Wrap").tag("wrap")
                    Text("No wrap").tag("nowrap")
                }
                Picker("Window position", selection: Binding(
                    get: { settings.windowPositionMode },
                    set: { settings.windowPositionMode = $0 }
                )) {
                    Text("Screen center").tag("center")
                    Text("Near cursor").tag("nearCursor")
                }
            }

            Section("Startup") {
                Toggle(
                    "Launch ClipboardManager at login",
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { enabled in
                            settings.launchAtLogin = enabled
                            LoginItemManager.shared.updateRegistration(enabled: enabled)
                        }
                    )
                )
                Text("Adds ClipboardManager to your Mac's login items so it starts automatically when you log in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .textSelection(.enabled)
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: .mainHotkeyRegistrationResult)) { note in
            if note.userInfo?["succeeded"] as? Bool == false {
                hotkeyAlert = .unavailable
            }
        }
        .alert(item: $hotkeyAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .cancel(Text("OK"))
            )
        }
    }

    private func commit(key: ReferenceWritableKeyPath<AppSettings, Int>, _ value: Int) {
        settings[keyPath: key] = value
    }
    private func notify(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    /// per-action hotkey definition. Adding a new action only requires a new case
    /// here; `saveActionHotkey`, `snapshotActionHotkeys`, `collidingActionHotkey`,
    /// and `revertActionHotkey` all derive their behavior from `allCases`, so no
    /// parallel `switch` needs to be updated.
    private enum ActionHotkeyKind: CaseIterable {
        case edit
        case pastePlain
        case macroPicker

        /// Display label in the Action Hotkeys section.
        var label: String {
            switch self {
            case .edit:        return "Edit"
            case .pastePlain:  return "Plain Text"
            case .macroPicker: return "Macro Picker"
            }
        }

        /// Stable identifier suffix used for accessibilityIdentifier on UI elements.
        var idPrefix: String {
            switch self {
            case .edit:        return "edit"
            case .pastePlain:  return "pastePlain"
            case .macroPicker: return "macroPicker"
            }
        }

        var keyCodePath: ReferenceWritableKeyPath<AppSettings, Int> {
            switch self {
            case .edit:        return \.editHotkeyCode
            case .pastePlain:  return \.pastePlainHotkeyCode
            case .macroPicker: return \.macroPickerHotkeyCode
            }
        }

        var modifiersPath: ReferenceWritableKeyPath<AppSettings, Int> {
            switch self {
            case .edit:        return \.editHotkeyModifiers
            case .pastePlain:  return \.pastePlainHotkeyModifiers
            case .macroPicker: return \.macroPickerHotkeyModifiers
            }
        }

        /// Default key code for this action. Defaults are owned by `AppSettings`
        /// (single source of truth) so the Reset button in this view and the
        /// E2E launch configuration cannot drift.
        var defaultKeyCode: Int {
            switch self {
            case .edit:        return AppSettings.defaultEditHotkeyCode
            case .pastePlain:  return AppSettings.defaultPastePlainHotkeyCode
            case .macroPicker: return AppSettings.defaultMacroPickerHotkeyCode
            }
        }

        /// Default modifier (Cmd only for all actions).
        var defaultModifiers: Int {
            AppSettings.defaultActionHotkeyModifiers
        }

        func get(in settings: AppSettings) -> (Int, Int) {
            (settings[keyPath: keyCodePath], settings[keyPath: modifiersPath])
        }

        func set(_ value: (Int, Int), in settings: AppSettings) {
            settings[keyPath: keyCodePath] = value.0
            settings[keyPath: modifiersPath] = value.1
        }
    }

    /// Applies an action hotkey change (Record / Reset / Clear) through a single
    /// path so the duplicate guard is always exercised (review #2). The view's
    /// Binding `set` is a no-op for action hotkeys; this method is the single
    /// writer of `kind`'s setting via `kind.set`, and the view's
    /// `onChange(of: keyCode/modifiers)` refreshes the display from the
    /// post-write value. On collision this method simply does not write, so the
    /// recorder display and the persisted value stay at the pre-change binding
    /// without needing a revert step (the previous implementation snapshotted
    /// *after* the Binding had already written the new value, so its revert
    /// restored the post-change value instead of the pre-change value).
    private func applyActionHotkey(_ kind: ActionHotkeyKind, keyCode: Int, modifiers: Int) {
        // Snapshot the *current* bindings so the candidate table reflects the
        // pre-change state for every kind other than `kind`.
        let prev = snapshotActionHotkeys()
        var candidate = prev
        candidate.values[kind] = (keyCode, modifiers)
        // Reject when the candidate collides with another action hotkey's
        // *current* binding. Carbon's RegisterEventHotKey would otherwise
        // silently reject the second registration and one action would be a
        // no-op. Zero-modifier bindings (Clear) are allowed through without
        // collision checking because an unset binding cannot conflict.
        if modifiers != 0, collidingActionHotkey(for: kind, candidate: candidate) != nil {
            // Do NOT write the new value; the Binding-derived display will not
            // move because we never wrote. Surface the duplicate alert so the
            // user knows the shortcut is already taken by another action.
            hotkeyAlert = .actionDuplicate
            return
        }
        kind.set((keyCode, modifiers), in: settings)
        NotificationCenter.default.post(name: .actionHotkeysChanged, object: nil)
    }

    private struct ActionHotkeySnapshot {
        var values: [ActionHotkeyKind: (Int, Int)] = [:]
    }

    private func snapshotActionHotkeys() -> ActionHotkeySnapshot {
        var snap = ActionHotkeySnapshot()
        for kind in ActionHotkeyKind.allCases {
            snap.values[kind] = kind.get(in: settings)
        }
        return snap
    }

    /// Returns the kind that the candidate for `kind` collides with, if any.
    /// A collision is an exact (keyCode, modifiers) match where both sides have non-zero modifiers.
    private func collidingActionHotkey(for kind: ActionHotkeyKind, candidate: ActionHotkeySnapshot) -> ActionHotkeyKind? {
        guard let target = candidate.values[kind], target.1 != 0 else { return nil }
        for otherKind in ActionHotkeyKind.allCases where otherKind != kind {
            guard let other = candidate.values[otherKind], other.1 != 0 else { continue }
            if other.0 == target.0 && other.1 == target.1 { return otherKind }
        }
        return nil
    }
}
