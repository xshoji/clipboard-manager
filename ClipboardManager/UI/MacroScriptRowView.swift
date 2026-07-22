import SwiftUI
import AppKit

struct MacroScriptRowView: View {
    let macro: MacroScript
    let onUpdate: (MacroScript) -> Void
    let onDirtyChange: ((UUID, Bool) -> Void)?
    @Environment(AppSettings.self) private var settings
    @State private var name: String
    @State private var sourceType: String
    @State private var path: String
    @State private var inlineScript: String
    @State private var interpreter: String
    @State private var interpreterPreset: String
    @State private var hotkeyCode: Int
    @State private var hotkeyModifiers: Int
    @State private var showFingerprintCaptured: Bool = false
    @State private var validationError: String?
    @State private var lastNotifiedDirty: Bool = false
    @State private var saveObserverToken: NSObjectProtocol?
    /// Pending edit awaiting the registration/change confirmation dialog (design-implementation.md §5.1-1).
    @State private var pendingConfirm: MacroScript?
    @State private var pendingFileValidation: MacroScriptValidation?
    @State private var isPresentingConfirm: Bool = false
    /// `true` when the in-flight `apply()` was triggered by a
    /// `.saveAllUnsavedMacros` broadcast (window-close "Save all"). Set before
    /// `apply()` runs and consumed by every settle path (saved, user-cancelled,
    /// validation error) to report completion back to AppState exactly once.
    @State private var saveBroadcastInFlight: Bool = false

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

    init(macro: MacroScript, onUpdate: @escaping (MacroScript) -> Void, onDirtyChange: ((UUID, Bool) -> Void)? = nil) {
        self.macro = macro
        self.onUpdate = onUpdate
        self.onDirtyChange = onDirtyChange
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
                        "Smart quotes detected. Replace \" \" with straight quotes (\").",
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
            if showFingerprintCaptured {
                Label(
                    "Inline script fingerprint captured.",
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)
                .font(.caption)
            }
            if let error = validationError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            HStack {
                Button("Save") { apply() }
                    .disabled(!canApply)
                Spacer()
                Button("Remove", role: .destructive) { remove() }
            }
            .padding(.bottom, 6)
        }
        .padding(.vertical, 2)
        .confirmationDialog(
            isPendingRegistrationNew ? "Register Macro script" : "Confirm Macro script change",
            isPresented: $isPresentingConfirm,
            titleVisibility: .visible
        ) {
            Button("Save", role: .none) { confirmSave() }
            Button("Cancel", role: .cancel) { cancelConfirm() }
        } message: {
            Text("This script can access your clipboard contents. Do not specify untrusted scripts.")
        }
        .onAppear {
            checkDirty()
            saveObserverToken = NotificationCenter.default.addObserver(
                forName: .saveAllUnsavedMacros,
                object: nil,
                queue: .main
            ) { [self] _ in
                Task { @MainActor in
                    if hasContentChanges {
                        // Mark this broadcast as the originator so that any
                        // settle path (saved, user-cancelled, validation-error)
                        // reports back to AppState exactly once.
                        saveBroadcastInFlight = true
                        apply()
                    }
                }
            }
        }
        .onDisappear {
            if let token = saveObserverToken {
                NotificationCenter.default.removeObserver(token)
            }
        }
        .onChange(of: macro) { previous, updated in
            syncState(from: previous, to: updated)
        }
        .onChange(of: name) { _, _ in
            showFingerprintCaptured = false
            checkDirty()
        }
        .onChange(of: sourceType) { _, _ in
            showFingerprintCaptured = false
            checkDirty()
        }
        .onChange(of: path) { _, _ in
            showFingerprintCaptured = false
            checkDirty()
        }
        .onChange(of: inlineScript) { _, _ in
            showFingerprintCaptured = false
            checkDirty()
        }
        .onChange(of: interpreter) { _, _ in
            showFingerprintCaptured = false
            checkDirty()
        }
        .onChange(of: interpreterPreset) { _, _ in
            showFingerprintCaptured = false
            checkDirty()
        }
        .onChange(of: hotkeyCode) { _, _ in checkDirty() }
        .onChange(of: hotkeyModifiers) { _, _ in checkDirty() }
    }

    private var canApply: Bool {
        hasContentChanges
        && !name.trimmingCharacters(in: .whitespaces).isEmpty
        && !interpreter.trimmingCharacters(in: .whitespaces).isEmpty
        && (sourceType == "inline"
            ? !inlineScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : !path.trimmingCharacters(in: .whitespaces).isEmpty)
    }

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
        edited.interpreter = interpreter
        edited.hotkeyCode = hotkeyCode
        edited.hotkeyModifiers = hotkeyModifiers

        if sourceType == "inline" {
            let body = inlineScript
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                validationError = "Shell script is empty."
                reportSaveSettlementIfNeeded()
                return
            }
            edited.scriptPath = ""
            edited.inlineScript = body
            // Per design-implementation.md §5.1-1 the fingerprint is captured *after*
            // the user confirms the registration/change dialog. Storing it here
            // would make any body pasted in "always clean" at the registration
            // moment, defeating tamper detection. `confirmSave()` captures it.
            edited.lastFingerprint = nil
            edited.lastModified = nil
            validationError = nil
        } else {
            let v = MacroScriptPathValidator.validate(path: path)
            guard v.isValid else {
                switch v.failure {
                case .pathEmpty:
                    validationError = "Path is empty."
                case .fileNotFound:
                    validationError = "File not found at the path."
                case .outsideHome:
                    validationError = "Script must be inside your home directory."
                case .fingerprintUnavailable:
                    validationError = "Could not compute script fingerprint."
                case .none:
                    validationError = "Validation failed."
                }
                reportSaveSettlementIfNeeded()
                return
            }
            edited.scriptPath = v.resolvedPath
            edited.inlineScript = nil
            // Fingerprint captured after confirmation (see inline branch comment).
            edited.lastFingerprint = nil
            edited.lastModified = nil
            pendingFileValidation = v
            validationError = nil
        }

        // require registration/change confirmation per design-implementation.md §5.1-1
        pendingConfirm = edited
        isPresentingConfirm = true
    }

    /// `true` when the pending confirmation is for a brand-new registration
    /// (no fingerprint previously stored). Used to vary the dialog title.
    private var isPendingRegistrationNew: Bool {
        macro.lastFingerprint == nil
    }

    private func confirmSave() {
        guard var edited = pendingConfirm else { return }
        // Capture the fingerprint *after* the user has confirmed, so the
        // confirmation is the trust anchor for tamper detection. This applies
        // to both file-path and inline macros (review #2 / §5.1-1).
        if let body = edited.inlineScript {
            edited.lastFingerprint = HashUtil.sha256Hex(of: Data(body.utf8))
            edited.lastModified = nil
            showFingerprintCaptured = true
        } else if let v = pendingFileValidation {
            edited.lastFingerprint = v.fingerprint
            edited.lastModified = v.lastModified
            showFingerprintCaptured = false
        }
        onUpdate(edited)
        pendingConfirm = nil
        pendingFileValidation = nil
        reportSaveSettlementIfNeeded()
        checkDirty()
    }

    /// Confirmation dialog "Cancel": clears pending state and, if this apply
    /// was triggered by a `.saveAllUnsavedMacros` broadcast, reports the
    /// settle so the window-close waiter does not stall.
    private func cancelConfirm() {
        pendingConfirm = nil
        pendingFileValidation = nil
        reportSaveSettlementIfNeeded()
    }

    /// Reports one settle to `AppState` when a `.saveAllUnsavedMacros`
    /// broadcast is in flight, then clears the flag so a subsequent manual
    /// Save does not double-count.
    private func reportSaveSettlementIfNeeded() {
        guard saveBroadcastInFlight else { return }
        saveBroadcastInFlight = false
        AppState.shared.recordMacroSaveSettlement()
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
        showFingerprintCaptured = false
        validationError = nil
        checkDirty()
    }

    private func checkDirty() {
        let dirty = hasContentChanges
        if dirty != lastNotifiedDirty {
            lastNotifiedDirty = dirty
            onDirtyChange?(macro.id, dirty)
        }
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
