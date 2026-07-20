import SwiftUI
import AppKit

struct HookScriptRowView: View {
    let hook: HookScript
    let onUpdate: (HookScript) -> Void
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

    init(hook: HookScript, onUpdate: @escaping (HookScript) -> Void) {
        self.hook = hook
        self.onUpdate = onUpdate
        _name = State(initialValue: hook.name)
        _sourceType = State(initialValue: hook.inlineScript == nil ? "file" : "inline")
        _path = State(initialValue: hook.scriptPath)
        _inlineScript = State(initialValue: hook.inlineScript ?? "")
        _interpreter = State(initialValue: hook.interpreter)
        _interpreterPreset = State(
            initialValue: Self.shellPresets.contains(hook.interpreter) ? hook.interpreter : "custom"
        )
        _hotkeyCode = State(initialValue: hook.hotkeyCode)
        _hotkeyModifiers = State(initialValue: hook.hotkeyModifiers)
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
                HookHotkeyRecorderView(
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
        .onChange(of: hook) { previous, updated in
            syncState(from: previous, to: updated)
        }
    }

    private var canApply: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && !interpreter.trimmingCharacters(in: .whitespaces).isEmpty
        && (sourceType == "inline"
            ? !inlineScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : !path.trimmingCharacters(in: .whitespaces).isEmpty)
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
        var edited = hook
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
        guard keyCode != hook.hotkeyCode || modifiers != hook.hotkeyModifiers else { return }
        var edited = hook
        edited.hotkeyCode = keyCode
        edited.hotkeyModifiers = modifiers
        onUpdate(edited)
    }

    private func remove() {
        var arr = settings.hookScripts
        arr.removeAll { $0.id == hook.id }
        settings.hookScripts = arr
    }

    private func syncState(from previous: HookScript, to updated: HookScript) {
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
        textView.delegate = context.coordinator
        textView.string = text
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
        textView.string = text
    }

    static func containsSmartQuotes(in text: String) -> Bool {
        text.contains("“") || text.contains("”") || text.contains("‘") || text.contains("’")
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ShellScriptEditor

        init(parent: ShellScriptEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
