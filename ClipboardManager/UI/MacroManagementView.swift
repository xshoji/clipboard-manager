import SwiftUI

/// Dedicated workspace for registering and maintaining clipboard transform scripts.
struct MacroManagementView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SettingsViewModel.self) private var viewModel
    /// Rows start collapsed to keep the list scannable; newly added Macros expand
    /// so their editor is ready for the required registration step.
    @State private var expandedMacroIDs: Set<UUID> = []
    @State private var macroFrames: [UUID: CGRect] = [:]
    @State private var viewport: CGRect = .null

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.vertical, 18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    behaviorSettings

                    if settings.macroScripts.isEmpty {
                        ContentUnavailableView {
                            Label("No Macros", systemImage: "terminal")
                        } description: {
                            Text("Add a Macro to transform text or images before pasting.")
                                .accessibilityIdentifier("macro.empty")
                        } actions: {
                            Button("Add Macro", action: addMacro)
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("macro.empty.add")
                        }
                        .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(settings.macroScripts.enumerated()), id: \.element.id) { index, macro in
                                GroupBox {
                                    MacroScriptRowView(
                                        macro: macro,
                                        accessibilityIDPrefix: "macro.\(index)",
                                        isExpanded: expansion(for: macro.id),
                                        canMoveUp: index > 0,
                                        canMoveDown: index < settings.macroScripts.count - 1,
                                        onMoveUp: { viewModel.moveMacro(id: macro.id, to: index - 1) },
                                        onMoveDown: { viewModel.moveMacro(id: macro.id, to: index + 1) },
                                        onReorder: { reorder(macro.id, at: $0) },
                                        onUpdate: updateMacro,
                                        onDirtyChange: viewModel.setDirty
                                    )
                                    .padding(8)
                                }
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: MacroFramesKey.self,
                                            value: [macro.id: geometry.frame(in: .global)]
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .accessibilityIdentifier("macro.management.scroll")
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: MacroViewportKey.self, value: geometry.frame(in: .global))
                }
            }
        }
        .navigationTitle("Macros")
        .background(Color(nsColor: .windowBackgroundColor))
        .onPreferenceChange(MacroFramesKey.self) { macroFrames = $0 }
        .onPreferenceChange(MacroViewportKey.self) { viewport = $0 }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Macro Management")
                    .font(.title2.weight(.semibold))
                Text("Register, edit, test, and remove clipboard transformations.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: addMacro) {
                Label("Add Macro", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("macro.add")
        }
    }

    private var behaviorSettings: some View {
        GroupBox("Execution & Security") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("On macro failure", selection: Binding(
                    get: { settings.macroFailureBehavior },
                    set: { settings.macroFailureBehavior = $0 }
                )) {
                    Text("Paste error + notify").tag("restoreOriginalAndNotify")
                    Text("Notify only").tag("notifyOnly")
                    Text("Silent").tag("silentlySkip")
                }

                LabeledContent("Timeout") {
                    HStack(spacing: 8) {
                        Text("\(settings.macroTimeoutSeconds) sec")
                            .monospacedDigit()
                            .accessibilityIdentifier("macro.timeout.value")
                        Stepper(
                            "Macro timeout",
                            value: Binding(
                                get: { settings.macroTimeoutSeconds },
                                set: { settings.macroTimeoutSeconds = $0 }
                            ),
                            in: MacroScript.timeoutRange
                        )
                        .labelsHidden()
                        .accessibilityIdentifier("macro.timeout.stepper")
                    }
                }

                Toggle(
                    "Verify script fingerprint before run",
                    isOn: Binding(
                        get: { settings.macroSameDirectoryFingerprint },
                        set: { settings.macroSameDirectoryFingerprint = $0 }
                    )
                )

                Text("Macros run with your user permissions and can access clipboard contents. Only register scripts you trust.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private func expansion(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedMacroIDs.contains(id) },
            set: { expanded in
                if expanded { expandedMacroIDs.insert(id) } else { expandedMacroIDs.remove(id) }
            }
        )
    }

    private func addMacro() {
        // The row's Save action presents the required registration confirmation.
        let existingOrders = Set(settings.macroScripts.compactMap(\.order))
        let maximumOrder = existingOrders.max() ?? 0
        let (incrementedOrder, overflowed) = maximumOrder.addingReportingOverflow(10)
        let nextOrder = overflowed
            ? (0...settings.macroScripts.count).lazy.map { $0 * 10 }.first { !existingOrders.contains($0) } ?? 0
            : incrementedOrder
        let macro = MacroScript(
            order: nextOrder,
            name: "New Macro",
            scriptPath: "",
            inlineScript: """
            #!/bin/sh
            # Example: replace "foo" with "bar" in copied text.
            sed 's/foo/bar/g' "$CB_INPUT_FILE" > "$CB_OUTPUT_FILE"
            """
        )
        settings.macroScripts.append(macro)
        expandedMacroIDs.insert(macro.id)
    }

    private func reorder(_ id: UUID, at point: CGPoint) {
        guard viewport.contains(point),
              let sourceIndex = settings.macroScripts.firstIndex(where: { $0.id == id }),
              let index = settings.macroScripts.firstIndex(where: {
                  $0.id != id && macroFrames[$0.id]?.contains(point) == true
              }), let frame = macroFrames[settings.macroScripts[index].id] else { return }

        // Crossing the midpoint prevents taller rows from immediately swapping back.
        guard sourceIndex < index ? point.y > frame.midY : point.y < frame.midY else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            viewModel.moveMacro(id: id, to: index)
        }
    }

    private func updateMacro(_ edited: MacroScript) {
        var macros = settings.macroScripts
        guard let index = macros.firstIndex(where: { $0.id == edited.id }) else { return }
        macros[index] = edited
        settings.macroScripts = macros
    }
}

private struct MacroFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct MacroViewportKey: PreferenceKey {
    static let defaultValue: CGRect = .null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = value.union(nextValue())
    }
}
