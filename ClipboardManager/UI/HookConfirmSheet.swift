import SwiftUI

/// Sheet for registering a new Hook script or confirming changes to an existing one (design-app.md §2.2.2 safeguard, design-implementation.md §5.1).
///
/// Accepts an editable draft, validates the file path or inline body, and saves it.
struct HookConfirmSheet: View {
    /// Editing draft. The same sheet is used for both new and existing Hooks.
    @State var draft: HookScript
    /// Value before the path was changed. If unchanged, path-change confirmation is skipped.
    let originalPath: String
    let isNew: Bool
    let onSave: (HookScript) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var validation: HookScriptValidation?
    @State private var didBrowse: Bool = false
    @State private var selectedSource: String
    @State private var inlineDraft: String
    @State private var interpreterPreset: String

    // Shell interpreter presets offered in inline mode. Inline scripts are written to a
    // .sh temp file and invoked as `interpreter path`, so only shell interpreters work.
    private static let shellPresets: [String] = [
        "/bin/sh",
        "/bin/bash",
        "/bin/zsh",
        "/opt/homebrew/bin/bash",
        "/opt/homebrew/bin/zsh",
        "/usr/local/bin/bash",
        "/usr/local/bin/zsh",
    ]

    init(hook: HookScript, isNew: Bool, onSave: @escaping (HookScript) -> Void) {
        _draft = State(initialValue: hook)
        _selectedSource = State(initialValue: hook.inlineScript == nil ? "file" : "inline")
        _inlineDraft = State(initialValue: hook.inlineScript ?? "")
        _interpreterPreset = State(
            initialValue: Self.shellPresets.contains(hook.interpreter) ? hook.interpreter : "custom"
        )
        self.originalPath = hook.scriptPath
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Register Hook script" : "Confirm Hook script change")
                .font(.headline)
            Text("This script will be able to read clipboard contents. Only register trusted scripts.")
                .foregroundStyle(.secondary)

            TextField("Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
            Picker("Source", selection: $selectedSource) {
                Text("Script file").tag("file")
                Text("Inline shell").tag("inline")
            }
            .pickerStyle(.segmented)
            if isInline {
                Text("Shell script")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ShellScriptEditor(text: $inlineDraft)
                    .frame(minHeight: 180)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.25))
                    }
                if ShellScriptEditor.containsSmartQuotes(in: inlineDraft) {
                    Label(
                        "Smart quotes detected. Replace “ ” with straight quotes (\").",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Text("Read $CB_INPUT_FILE and write the result to $CB_OUTPUT_FILE.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("$CB_ITEM_KIND is \"text\" or \"image\". $CB_ITEM_SOURCE is the source app bundle id ( may be empty ).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                HStack {
                    TextField("Script path", text: $draft.scriptPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse") { browse() }
                }
            }
            if isInline {
                HStack {
                    Text("Interpreter")
                    Picker("", selection: $interpreterPreset) {
                        ForEach(Self.shellPresets, id: \.self) { Text($0).tag($0) }
                        Text("Custom").tag("custom")
                    }
                    .labelsHidden()
                    .onChange(of: interpreterPreset) { _, v in
                        if v != "custom" { draft.interpreter = v }
                    }
                    if interpreterPreset == "custom" {
                        TextField("", text: $draft.interpreter).textFieldStyle(.roundedBorder)
                    }
                }
            } else {
                TextField("Interpreter", text: $draft.interpreter)
                    .textFieldStyle(.roundedBorder)
            }

            validationView

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding()
        .frame(minWidth: 460)
        .onAppear { revalidate() }
        .onChange(of: draft.scriptPath) { _, _ in revalidate() }
        .onChange(of: selectedSource) { _, _ in revalidate() }
    }

    // MARK: - Validation

    private var canSave: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
              !draft.interpreter.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        if isInline {
            return !inlineDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return validation?.isValid == true
    }

    private var validationView: some View {
        Group {
            if isInline {
                if inlineDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("Shell script is empty.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red).font(.caption)
                } else {
                    Label(
                        "Inline script fingerprint captured.",
                        systemImage: "checkmark.seal.fill"
                    )
                    .foregroundStyle(.green)
                    .font(.caption)
                }
            } else if let v = validation {
                if v.isValid {
                    Label(
                        "Verified: file inside $HOME, fingerprint captured.",
                        systemImage: "checkmark.seal.fill"
                    )
                    .foregroundStyle(.green)
                    .font(.caption)
                } else {
                    switch v.failure {
                    case .pathEmpty:
                        Label("Path is empty.", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red).font(.caption)
                    case .fileNotFound:
                        Label("File not found at the path.", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red).font(.caption)
                    case .outsideHome:
                        Label("Script must be inside your home directory.", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red).font(.caption)
                    case .fingerprintUnavailable:
                        Label("Could not compute script fingerprint.", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red).font(.caption)
                    case .none:
                        EmptyView()
                    }
                }
            } else {
                Label("Validating…", systemImage: "hourglass")
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    private var isInline: Bool { selectedSource == "inline" }

    private func revalidate() {
        validation = isInline ? nil : HookScriptPathValidator.validate(path: draft.scriptPath)
    }

    // MARK: - Actions

    private func browse() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            draft.scriptPath = url.path
            didBrowse = true
        }
    }

    private func save() {
        var stored = draft
        if isInline {
            let body = inlineDraft
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            stored.scriptPath = ""
            stored.inlineScript = body
            stored.lastFingerprint = HashUtil.sha256Hex(of: Data(body.utf8))
            stored.lastModified = nil
        } else {
            guard let v = validation, v.isValid else { return }
            stored.scriptPath = v.resolvedPath
            stored.inlineScript = nil
            stored.lastFingerprint = v.fingerprint
            stored.lastModified = v.lastModified
        }
        onSave(stored)
        dismiss()
    }
}
