import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var retention: Int
    @State private var maxCount: Int
    @State private var maxItem: Int
    @State private var confirmRebindSheet: HookScript?
    @State private var confirmRebindIsNew: Bool = true
    @State private var hotkeyRebindSheet: HookScript?
    @State private var showHotkeyRegistrationError = false
    @State private var showActionHotkeyDuplicateError = false

    init() {
        let s = AppSettings.shared
        _retention = State(initialValue: s.retentionDays)
        _maxCount = State(initialValue: s.maxHistoryCount)
        _maxItem = State(initialValue: s.maxItemSizeMB)
    }

    var body: some View {
        Form {
            Section("History") {
                Picker("Retention", selection: $retention) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("365 days").tag(365)
                    Text("Unlimited").tag(0)
                }.onChange(of: retention) { _, v in commit(key: \.retentionDays, v); notify(.retentionChanged) }

                Picker("Max items", selection: $maxCount) {
                    Text("100").tag(100)
                    Text("500").tag(500)
                    Text("1,000").tag(1000)
                    Text("5,000").tag(5000)
                    Text("10,000").tag(10000)
                    Text("50,000").tag(50000)
                    Text("100,000").tag(100000)
                }.onChange(of: maxCount) { _, v in commit(key: \.maxHistoryCount, v); notify(.maxCountChanged) }

                Stepper(value: $maxItem, in: 1...100) {
                    Text("Max item size: \(maxItem) MB")
                }.onChange(of: maxItem) { _, v in commit(key: \.maxItemSizeMB, v) }
            }

            Section("Global Hotkey") {
                HotkeyRecorderView()
                    .environment(settings)
            }

            Section("Action Hotkeys") {
                Text("Effective only while the ClipboardManager history window is visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Edit")
                    Spacer()
                    HookHotkeyRecorderView(
                        keyCode: Binding(get: { settings.editHotkeyCode }, set: { settings.editHotkeyCode = $0 }),
                        modifiers: Binding(get: { settings.editHotkeyModifiers }, set: { settings.editHotkeyModifiers = $0 }),
                        onShortcutChange: { keyCode, mods in
                            saveActionHotkey(.edit, keyCode: keyCode, modifiers: mods)
                        }
                    )
                }
                HStack {
                    Text("Paste Plain")
                    Spacer()
                    HookHotkeyRecorderView(
                        keyCode: Binding(get: { settings.pastePlainHotkeyCode }, set: { settings.pastePlainHotkeyCode = $0 }),
                        modifiers: Binding(get: { settings.pastePlainHotkeyModifiers }, set: { settings.pastePlainHotkeyModifiers = $0 }),
                        onShortcutChange: { keyCode, mods in
                            saveActionHotkey(.pastePlain, keyCode: keyCode, modifiers: mods)
                        }
                    )
                }
                Text("Defaults: Edit ⌘E, Paste Plain ⌘P. Set modifiers clear to unset an action.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Hook Scripts") {
                ForEach(settings.hookScripts) { hook in
                    HookScriptRowView(hook: hook) { edited in
                        // When the executable content changes, validate and save via the confirmation sheet.
                        // Name/shortcut-only changes are saved immediately.
                        if edited.scriptPath != hook.scriptPath
                            || edited.inlineScript != hook.inlineScript {
                            hotkeyRebindSheet = edited
                        } else {
                            var arr = settings.hookScripts
                            if let idx = arr.firstIndex(where: { $0.id == edited.id }) {
                                arr[idx] = edited
                            }
                            settings.hookScripts = arr
                        }
                    }
                    .padding(.vertical, 8)
                    .listRowSeparator(.hidden)
                }
                if settings.hookScripts.isEmpty {
                    Text("No Hooks registered.").foregroundStyle(.secondary)
                }
                Button("Add Hook…") {
                    // Passes an editable draft to the confirmation sheet (remaining-features #5).
                    confirmRebindSheet = HookScript(name: "New Hook", scriptPath: "~/")
                    confirmRebindIsNew = true
                }
            }

            Section("Hook Behavior") {
                Picker("On hook failure", selection: Binding(
                    get: { settings.hookFailureBehavior },
                    set: { settings.hookFailureBehavior = $0 }
                )) {
                    Text("Restore original + notify").tag("restoreOriginalAndNotify")
                    Text("Notify only").tag("notifyOnly")
                    Text("Silent").tag("silentlySkip")
                }
                Toggle(
                    "Verify script fingerprint before run",
                    isOn: Binding(
                        get: { settings.hookSameDirectoryFingerprint },
                        set: { settings.hookSameDirectoryFingerprint = $0 }
                    )
                )
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
                    InputPermission().requestAccessibility()
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
        .frame(minWidth: 560, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: .mainHotkeyRegistrationResult)) { note in
            if note.userInfo?["succeeded"] as? Bool == false {
                showHotkeyRegistrationError = true
            }
        }
        .alert("Hotkey unavailable", isPresented: $showHotkeyRegistrationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That shortcut is already registered by another app or Hook. Choose a different shortcut.")
        }
        .alert("Action hotkey duplicate", isPresented: $showActionHotkeyDuplicateError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Edit and Paste Plain action hotkeys cannot share the same shortcut. Choose a different shortcut for one of them.")
        }
        .sheet(item: $confirmRebindSheet) { hook in
            HookConfirmSheet(hook: hook, isNew: confirmRebindIsNew) { stored in
                var arr = settings.hookScripts
                if let idx = arr.firstIndex(where: { $0.id == stored.id }) {
                    arr[idx] = stored
                } else {
                    arr.append(stored)
                }
                settings.hookScripts = arr
            }
        }
        .sheet(item: $hotkeyRebindSheet) { hook in
            // Confirmation sheet for an existing Hook invoked from the Update button (remaining-features #5).
            HookConfirmSheet(hook: hook, isNew: false) { stored in
                var arr = settings.hookScripts
                if let idx = arr.firstIndex(where: { $0.id == stored.id }) {
                    arr[idx] = stored
                }
                settings.hookScripts = arr
            }
        }
    }

    private func commit(key: ReferenceWritableKeyPath<AppSettings, Int>, _ value: Int) {
        settings[keyPath: key] = value
    }
    private func notify(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    /// Action keys that have user-configurable window-scoped hotkeys ( design: edit / paste plain / etc. ).
    private enum ActionHotkeyKind {
        case edit
        case pastePlain
    }

    /// Persists action-hotkey changes ( via `HookHotkeyRecorderView` Clear/Record ) and notifies AppDelegate to re-register immediately.
    private func saveActionHotkey(_ kind: ActionHotkeyKind, keyCode: Int, modifiers: Int) {
        // Duplicate guard (review #16): reject when the new binding collides with the
        // *other* action hotkey's current binding. Carbon's RegisterEventHotKey would
        // otherwise silently reject the second registration and one action would be a
        // no-op. `HookHotkeyRecorderView` writes the new value through the Binding's
        // `set` before invoking `onShortcutChange`, so we revert here on collision.
        if modifiers != 0 {
            let prevEditKC = settings.editHotkeyCode
            let prevEditMods = settings.editHotkeyModifiers
            let prevPlainKC = settings.pastePlainHotkeyCode
            let prevPlainMods = settings.pastePlainHotkeyModifiers
            let collides: Bool
            switch kind {
            case .edit:
                collides = (settings.pastePlainHotkeyModifiers != 0
                            && keyCode == settings.pastePlainHotkeyCode
                            && modifiers == settings.pastePlainHotkeyModifiers)
            case .pastePlain:
                collides = (settings.editHotkeyModifiers != 0
                            && keyCode == settings.editHotkeyCode
                            && modifiers == settings.editHotkeyModifiers)
            }
            if collides {
                // Revert the binding that was already written by the Binding's `set` so
                // the recorder display and the persisted value stay consistent.
                switch kind {
                case .edit:
                    settings.editHotkeyCode = prevEditKC
                    settings.editHotkeyModifiers = prevEditMods
                case .pastePlain:
                    settings.pastePlainHotkeyCode = prevPlainKC
                    settings.pastePlainHotkeyModifiers = prevPlainMods
                }
                showActionHotkeyDuplicateError = true
                return
            }
        }
        switch kind {
        case .edit:
            settings.editHotkeyCode = keyCode
            settings.editHotkeyModifiers = modifiers
        case .pastePlain:
            settings.pastePlainHotkeyCode = keyCode
            settings.pastePlainHotkeyModifiers = modifiers
        }
        NotificationCenter.default.post(name: .actionHotkeysChanged, object: nil)
    }
}
