import SwiftUI

/// Dedicated workspace for registering and maintaining clipboard transform scripts.
struct MacroManagementView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SettingsViewModel.self) private var viewModel

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
                                        onUpdate: updateMacro,
                                        onDirtyChange: viewModel.setDirty
                                    )
                                    .padding(8)
                                } label: {
                                    HStack {
                                        Label(macro.name, systemImage: "terminal.fill")
                                            .font(.headline)

                                        Spacer()

                                        ControlGroup {
                                            Button {
                                                viewModel.moveMacro(id: macro.id, to: index - 1)
                                            } label: {
                                                Image(systemName: "chevron.up")
                                            }
                                            .disabled(index == 0)
                                            .help("Move Macro up")
                                            .accessibilityLabel("Move \(macro.name) up")
                                            .accessibilityIdentifier("macro.\(index).moveUp")

                                            Button {
                                                viewModel.moveMacro(id: macro.id, to: index + 1)
                                            } label: {
                                                Image(systemName: "chevron.down")
                                            }
                                            .disabled(index == settings.macroScripts.count - 1)
                                            .help("Move Macro down")
                                            .accessibilityLabel("Move \(macro.name) down")
                                            .accessibilityIdentifier("macro.\(index).moveDown")
                                        }
                                        .controlSize(.small)
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
        }
        .navigationTitle("Macros")
        .background(Color(nsColor: .windowBackgroundColor))
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
                    Text("Restore original + notify").tag("restoreOriginalAndNotify")
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
                            in: 1...300
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

    private func addMacro() {
        // The row's Save action presents the required registration confirmation.
        let existingOrders = Set(settings.macroScripts.compactMap(\.order))
        let maximumOrder = existingOrders.max() ?? 0
        let (incrementedOrder, overflowed) = maximumOrder.addingReportingOverflow(10)
        let nextOrder = overflowed
            ? (0...settings.macroScripts.count).lazy.map { $0 * 10 }.first { !existingOrders.contains($0) } ?? 0
            : incrementedOrder
        settings.macroScripts.append(MacroScript(
            order: nextOrder,
            name: "New Macro",
            scriptPath: "",
            inlineScript: """
            #!/bin/sh
            # Example: replace "foo" with "bar" in copied text.
            sed 's/foo/bar/g' "$CB_INPUT_FILE" > "$CB_OUTPUT_FILE"
            """
        ))
    }

    private func updateMacro(_ edited: MacroScript) {
        var macros = settings.macroScripts
        guard let index = macros.firstIndex(where: { $0.id == edited.id }) else { return }
        macros[index] = edited
        settings.macroScripts = macros
    }
}
