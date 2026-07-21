import SwiftUI
import AppKit

struct MacroScriptRowView: View {
    let macro: MacroScript
    let onUpdate: (MacroScript) -> Void
    @Environment(AppSettings.self) private var settings
    @State private var name: String
    @State private var sourceType: String
    @State private var path: String
    @State private var inlineScript: String
    @State private var interpreter: String
    @State private var interpreterPreset: String
    @State private var hotkeyCode: Int
    @State private var hotkeyModifiers: Int

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

    init(macro: MacroScript, onUpdate: @escaping (MacroScript) -> Void) {
        self.macro = macro
        self.onUpdate = onUpdate
        _name = State(initialValue: macro.name)
        _sourceType = State(initialValue: macro.inlineScript == nil ? "file" : "inline")
        _path = State(initialValue: macro.scriptPath)
        _inlineScript = State(initialValue: macro.inlineScript ?? "")
        _interpreter = State(initialValue: macro.interpreter)
        _interpreterPreset = State(
            initialValue: Self.shellPresets.contains(macro.interpreter) ? macro.interpreter : "custom"
        )
        _hotkeyCode = State(initialValue: macro.hotkeyCode)
        _hotkeyModifiers = State(initialValue: macro.hotkeyModifiers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Name") {
                TextField("", text: $name).textFieldStyle(.roundedBorder)
                   .multilineTextAlignment(.leading)
            }
            LabeledContent("Interpreter") {
                if sourceType == "inline" {
                    HStack {
                        if interpreterPreset == "custom" {
                            TextField("", text: $interpreter).textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                        }
                        Picker("", selection: $interpreterPreset) {
                            ForEach(Self.shellPresets, id: \.self) { Text($0).tag($0) }
                            Text("Custom").tag("custom")
                        }
                        .labelsHidden()
                        .onChange(of: interpreterPreset) { _, v in
                            if v != "custom" { interpreter = v }
                        }
                    }
                } else {
                    TextField("", text: $interpreter).textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                }
            }
            LabeledContent("Shortcut") {
                MacroHotkeyRecorderView(
                    keyCode: $hotkeyCode,
                    modifiers: $hotkeyModifiers,
                    onShortcutChange: saveShortcut
                )
            }
            Text("Shortcut changes are saved automatically.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            LabeledContent("Source") {
                Picker("", selection: $sourceType) {
                    Text("Script file").tag("file")
                    Text("Inline shell").tag("inline")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            if sourceType == "file" {
                HStack {
                    TextField("Path", text: $path).textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                    Button("Browse") { browse() }
                }
            } else {
                ShellScriptEditor(text: $inlineScript)
                    .frame(minHeight: 120)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.25))
                    }
                if ShellScriptEditor.containsSmartQuotes(in: inlineScript) {
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
            }
            HStack {
                // Content changes are handled via the confirmation sheet (onUpdate); meta-only updates are applied immediately.
                Button("Update") { apply() }
                .disabled(!canApply)
                Spacer()
                Button("Remove", role: .destructive) { remove() }
            }
            .padding(.bottom, 6)
        }
        .padding(.vertical, 2)
        .onChange(of: macro) { previous, updated in
            syncState(from: previous, to: updated)
        }
    }

    private var canApply: Bool {
        // The fields must be valid AND at least one must differ from the saved macro.
        // When nothing has changed, "Update" is disabled so the user can see there
        // is nothing to save (and the confirmation sheet is not shown unnecessarily).
        hasContentChanges
        && !name.trimmingCharacters(in: .whitespaces).isEmpty
        && !interpreter.trimmingCharacters(in: .whitespaces).isEmpty
        && (sourceType == "inline"
            ? !inlineScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : !path.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// `true` when any editable field ( name / source type / path / inline script /
    /// interpreter / hotkey ) differs from the saved `macro`. Hotkey changes are
    /// saved immediately via `saveShortcut`, so they are not expected to stay dirty,
    /// but are included here for correctness.
    private var hasContentChanges: Bool {
        name != macro.name
        || sourceType != (macro.inlineScript == nil ? "file" : "inline")
        || path != macro.scriptPath
        || inlineScript != (macro.inlineScript ?? "")
        || interpreter != macro.interpreter
        || hotkeyCode != macro.hotkeyCode
        || hotkeyModifiers != macro.hotkeyModifiers
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    private func apply() {
        var edited = macro
        edited.name = name
        edited.scriptPath = path
        edited.inlineScript = sourceType == "inline" ? inlineScript : nil
        edited.interpreter = interpreter
        edited.hotkeyCode = hotkeyCode
        edited.hotkeyModifiers = hotkeyModifiers
        // Content changes go to the confirmation sheet; otherwise save directly (remaining-features #5).
        // Fingerprints and validation are handled by the sheet, so do not overwrite them here.
        onUpdate(edited)
    }

    private func saveShortcut(keyCode: Int, modifiers: Int) {
        guard keyCode != macro.hotkeyCode || modifiers != macro.hotkeyModifiers else { return }
        var edited = macro
        edited.hotkeyCode = keyCode
        edited.hotkeyModifiers = modifiers
        onUpdate(edited)
    }

    private func remove() {
        var arr = settings.macroScripts
        arr.removeAll { $0.id == macro.id }
        settings.macroScripts = arr
    }

    private func syncState(from previous: MacroScript, to updated: MacroScript) {
        // Keep other unsaved inputs even when the parent value is updated by shortcut auto-saving.
        if name == previous.name { name = updated.name }
        if sourceType == (previous.inlineScript == nil ? "file" : "inline") {
            sourceType = updated.inlineScript == nil ? "file" : "inline"
        }
        if path == previous.scriptPath { path = updated.scriptPath }
        if inlineScript == (previous.inlineScript ?? "") { inlineScript = updated.inlineScript ?? "" }
        if interpreter == previous.interpreter {
            interpreter = updated.interpreter
            interpreterPreset = Self.shellPresets.contains(updated.interpreter) ? updated.interpreter : "custom"
        }
        hotkeyCode = updated.hotkeyCode
        hotkeyModifiers = updated.hotkeyModifiers
    }
}

/// Plain-text editor for shell code.
/// Disables macOS smart quotes, dashes, and auto-substitution to preserve typed ASCII symbols.
struct ShellScriptEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        // Set the string BEFORE assigning the delegate so the initial content
        // does not fire `textDidChange` and overwrite the binding with a
        // normalized copy (e.g. newline normalization), which would make the
        // row appear "dirty" and keep the Update button enabled on open.
        textView.string = text
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        // Suppress `textDidChange` while we programmatically sync the text view
        // from the binding so the coordinator does not write a normalized copy
        // back into the binding and create a spurious "dirty" state.
        context.coordinator.isUpdatingFromParent = true
        textView.string = text
        context.coordinator.isUpdatingFromParent = false
    }

    static func containsSmartQuotes(in text: String) -> Bool {
        text.contains("“") || text.contains("”") || text.contains("‘") || text.contains("’")
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ShellScriptEditor
        /// `true` while the parent is programmatically setting `textView.string`,
        /// so `textDidChange` is ignored and the binding is not overwritten.
        var isUpdatingFromParent = false

        init(parent: ShellScriptEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromParent else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
