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
                                    Label(macro.name, systemImage: "terminal.fill")
                                        .font(.headline)
                                }
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
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
        settings.macroScripts.append(MacroScript(
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
