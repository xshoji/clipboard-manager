import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var retention: Int
    @State private var maxCount: Int
    @State private var maxItem: Int
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
                    MacroHotkeyRecorderView(
                        keyCode: Binding(get: { settings.editHotkeyCode }, set: { settings.editHotkeyCode = $0 }),
                        modifiers: Binding(get: { settings.editHotkeyModifiers }, set: { settings.editHotkeyModifiers = $0 }),
                        onShortcutChange: { keyCode, mods in
                            saveActionHotkey(.edit, keyCode: keyCode, modifiers: mods)
                        }
                    )
                }
                HStack {
                    Text("Plain Text")
                    Spacer()
                    MacroHotkeyRecorderView(
                        keyCode: Binding(get: { settings.pastePlainHotkeyCode }, set: { settings.pastePlainHotkeyCode = $0 }),
                        modifiers: Binding(get: { settings.pastePlainHotkeyModifiers }, set: { settings.pastePlainHotkeyModifiers = $0 }),
                        onShortcutChange: { keyCode, mods in
                            saveActionHotkey(.pastePlain, keyCode: keyCode, modifiers: mods)
                        }
                    )
                }
               HStack {
                   Text("Macro Picker")
                   Spacer()
                   MacroHotkeyRecorderView(
                       keyCode: Binding(get: { settings.macroPickerHotkeyCode }, set: { settings.macroPickerHotkeyCode = $0 }),
                       modifiers: Binding(get: { settings.macroPickerHotkeyModifiers }, set: { settings.macroPickerHotkeyModifiers = $0 }),
                       onShortcutChange: { keyCode, mods in
                           saveActionHotkey(.macroPicker, keyCode: keyCode, modifiers: mods)
                       }
                   )
               }
                Text("Defaults: Edit ⌘E, Plain Text ⌘P. Set modifiers clear to unset an action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
               Text("Macro Picker opens a keyboard-driven list: ↑/↓ to navigate, Return to run, Esc to close.")
                   .font(.caption2)
                   .foregroundStyle(.secondary)
            }

            Section("Macro Scripts") {
                ForEach(settings.macroScripts) { macro in
                    MacroScriptRowView(
                        macro: macro,
                        onUpdate: { edited in
                            var arr = settings.macroScripts
                            if let idx = arr.firstIndex(where: { $0.id == edited.id }) {
                                arr[idx] = edited
                            }
                            settings.macroScripts = arr
                        },
                        onDirtyChange: { id, dirty in
                            if dirty {
                                AppState.shared.unsavedMacroIDs.insert(id)
                            } else {
                                AppState.shared.unsavedMacroIDs.remove(id)
                            }
                        }
                    )
                    .padding(.vertical, 8)
                    .listRowSeparator(.hidden)
                }
                if settings.macroScripts.isEmpty {
                    Text("No Macros registered.").foregroundStyle(.secondary)
                }
                Button("Add Macro…") {
                    // Adds an empty row that the user edits in place; the row's Save
                    // button presents the registration confirmation dialog (design-implementation.md §5.1-1).
                    settings.macroScripts.append(MacroScript(name: "New Macro", scriptPath: "~/"))
                }
            }

            Section("Macro Behavior") {
                Picker("On macro failure", selection: Binding(
                    get: { settings.macroFailureBehavior },
                    set: { settings.macroFailureBehavior = $0 }
                )) {
                    Text("Restore original + notify").tag("restoreOriginalAndNotify")
                    Text("Notify only").tag("notifyOnly")
                    Text("Silent").tag("silentlySkip")
                }
                Toggle(
                    "Verify script fingerprint before run",
                    isOn: Binding(
                        get: { settings.macroSameDirectoryFingerprint },
                        set: { settings.macroSameDirectoryFingerprint = $0 }
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
                Divider()
                Text("Plain Text on an image runs OCR and pastes the recognized text. Choose the recognition language set.")
                    .font(.caption)
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
        .frame(minWidth: 560, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: .mainHotkeyRegistrationResult)) { note in
            if note.userInfo?["succeeded"] as? Bool == false {
                showHotkeyRegistrationError = true
            }
        }
        .alert("Hotkey unavailable", isPresented: $showHotkeyRegistrationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That shortcut is already registered by another app or Macro. Choose a different shortcut.")
        }
        .alert("Action hotkey duplicate", isPresented: $showActionHotkeyDuplicateError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Edit and Plain Text action hotkeys cannot share the same shortcut. Choose a different shortcut for one of them.")
        }
    }

    private func commit(key: ReferenceWritableKeyPath<AppSettings, Int>, _ value: Int) {
        settings[keyPath: key] = value
    }
    private func notify(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    private enum ActionHotkeyKind {
        case edit
        case pastePlain
       case macroPicker
    }

    private func saveActionHotkey(_ kind: ActionHotkeyKind, keyCode: Int, modifiers: Int) {
        // Duplicate guard (review #16): reject when the new binding collides with the
        // *other* action hotkey's current binding. Carbon's RegisterEventHotKey would
        // otherwise silently reject the second registration and one action would be a
        // no-op. `MacroHotkeyRecorderView` writes the new value through the Binding's
        // `set` before invoking `onShortcutChange`, so we revert here on collision.
        if modifiers != 0 {
            // Snapshot all action hotkey bindings so we can revert the one that was
            // already written by the Binding's `set` if a collision is detected.
            let prev = snapshotActionHotkeys()
            // Build the candidate binding table with the new value applied.
            var candidate = prev
            switch kind {
            case .edit:        candidate.edit = (keyCode, modifiers)
            case .pastePlain:  candidate.pastePlain = (keyCode, modifiers)
            case .macroPicker: candidate.macroPicker = (keyCode, modifiers)
            }
            if collidingActionHotkey(for: kind, candidate: candidate) != nil {
                // Revert the binding that was already written by the Binding's `set` so
                // the recorder display and the persisted value stay consistent.
                revertActionHotkey(kind: kind, to: prev)
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
        case .macroPicker:
            settings.macroPickerHotkeyCode = keyCode
            settings.macroPickerHotkeyModifiers = modifiers
        }
        NotificationCenter.default.post(name: .actionHotkeysChanged, object: nil)
    }

    private struct ActionHotkeySnapshot {
        var edit: (Int, Int)
        var pastePlain: (Int, Int)
        var macroPicker: (Int, Int)
    }

    private func snapshotActionHotkeys() -> ActionHotkeySnapshot {
        ActionHotkeySnapshot(
            edit: (settings.editHotkeyCode, settings.editHotkeyModifiers),
            pastePlain: (settings.pastePlainHotkeyCode, settings.pastePlainHotkeyModifiers),
            macroPicker: (settings.macroPickerHotkeyCode, settings.macroPickerHotkeyModifiers)
        )
    }

    /// Returns the kind that the candidate for `kind` collides with, if any.
    /// A collision is an exact (keyCode, modifiers) match where both sides have non-zero modifiers.
    private func collidingActionHotkey(for kind: ActionHotkeyKind, candidate: ActionHotkeySnapshot) -> ActionHotkeyKind? {
        let pairs: [(ActionHotkeyKind, (Int, Int))] = [
            (.edit, candidate.edit),
            (.pastePlain, candidate.pastePlain),
            (.macroPicker, candidate.macroPicker),
        ]
        let target: (Int, Int) = {
            switch kind {
            case .edit: return candidate.edit
            case .pastePlain: return candidate.pastePlain
            case .macroPicker: return candidate.macroPicker
            }
        }()
        guard target.1 != 0 else { return nil }
        for (otherKind, other) in pairs where otherKind != kind {
            guard other.1 != 0 else { continue }
            if other.0 == target.0 && other.1 == target.1 { return otherKind }
        }
        return nil
    }

    private func revertActionHotkey(kind: ActionHotkeyKind, to snapshot: ActionHotkeySnapshot) {
        switch kind {
        case .edit:
            settings.editHotkeyCode = snapshot.edit.0
            settings.editHotkeyModifiers = snapshot.edit.1
        case .pastePlain:
            settings.pastePlainHotkeyCode = snapshot.pastePlain.0
            settings.pastePlainHotkeyModifiers = snapshot.pastePlain.1
        case .macroPicker:
            settings.macroPickerHotkeyCode = snapshot.macroPicker.0
            settings.macroPickerHotkeyModifiers = snapshot.macroPicker.1
        }
    }
}
