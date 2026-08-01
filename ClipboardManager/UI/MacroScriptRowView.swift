import SwiftUI
import AppKit

struct MacroScriptRowView: View {
    let macro: MacroScript
    let onUpdate: (MacroScript) -> Void
    let onDirtyChange: ((UUID, Bool) -> Void)?
    /// Stable identifier prefix used for every accessibilityIdentifier on this
    /// row's child elements (name field, save button, remove button, …). The
    /// MacroManagementView supplies a positional prefix ("macro.0", "macro.1", …) so
    /// XCUITest can address a specific row without depending on the macro's
    /// UUID. Defaults to "macro" when unspecified so non-E2E callers keep
    /// working.
    let accessibilityIDPrefix: String
    @Environment(AppSettings.self) private var settings
    @Environment(SettingsViewModel.self) private var viewModel
    @Environment(HistoryViewModel.self) private var historyViewModel
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
    @State private var isTestRunning: Bool = false
    @State private var lastNotifiedDirty: Bool = false
    @State private var saveObserverToken: NSObjectProtocol?
    /// Pending edit awaiting the registration/change confirmation dialog (design-implementation.md §5.1-1).
    @State private var pendingConfirm: MacroScript?
    @State private var pendingFileValidation: MacroScriptValidation?
    @State private var isPresentingConfirm: Bool = false
    @State private var isPresentingRemoveConfirm: Bool = false
    @State private var shouldTestAfterSave: Bool = false
    /// `true` when the in-flight `apply()` was triggered by a
    /// `.saveAllUnsavedMacros` broadcast (window-close "Save all"). Set before
    /// `apply()` runs and consumed by every settle path (saved, user-cancelled,
    /// validation error) to report completion back to the settings view model exactly once.
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

    init(macro: MacroScript,
         accessibilityIDPrefix: String = "macro",
         onUpdate: @escaping (MacroScript) -> Void,
         onDirtyChange: ((UUID, Bool) -> Void)? = nil) {
        self.macro = macro
        self.accessibilityIDPrefix = accessibilityIDPrefix
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
        VStack(alignment: .leading, spacing: 8) {
            settingsRow("Name") {
                TextField("", text: $name).textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier("\(accessibilityIDPrefix).name")
            }
            settingsRow("Interpreter") {
                if sourceType == "inline" {
                    HStack {
                        if interpreterPreset == "custom" {
                            TextField("", text: $interpreter).textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .accessibilityIdentifier("\(accessibilityIDPrefix).interpreter")
                        }
                        Picker("", selection: $interpreterPreset) {
                            ForEach(Self.shellPresets, id: \.self) { Text($0).tag($0) }
                            Text("Custom").tag("custom")
                        }
                        .labelsHidden()
                        .onChange(of: interpreterPreset) { _, v in
                            if v != "custom" { interpreter = v }
                        }
                        .accessibilityIdentifier("\(accessibilityIDPrefix).interpreterPreset")
                    }
                } else {
                    TextField("", text: $interpreter).textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("\(accessibilityIDPrefix).interpreter")
                }
            }
            settingsRow("Shortcut") {
                MacroHotkeyRecorderView(
                    keyCode: $hotkeyCode,
                    modifiers: $hotkeyModifiers,
                    onShortcutChange: saveShortcut,
                    accessibilityIDPrefix: "\(accessibilityIDPrefix).hotkey"
                )
            }
            settingsRow("") {
                Text("Shortcut changes are saved automatically.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            settingsRow("Source") {
                Picker("", selection: $sourceType) {
                    Text("Inline shell").tag("inline")
                    Text("Script file").tag("file")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityIdentifier("\(accessibilityIDPrefix).sourceType")
            }
            if sourceType == "file" {
                settingsRow("Script path") {
                    HStack {
                        TextField("Path", text: $path).textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .accessibilityIdentifier("\(accessibilityIDPrefix).path")
                        Button("Browse") { browse() }
                            .accessibilityIdentifier("\(accessibilityIDPrefix).browse")
                    }
                }
            } else {
                Text("Script")
                ShellScriptEditor(text: $inlineScript)
                    .accessibilityIdentifier("\(accessibilityIDPrefix).inlineScript")
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.25))
                    }
                if ShellScriptEditor.containsSmartQuotes(in: inlineScript) {
                    settingsRow("") {
                        Label(
                            "Smart quotes detected. Replace \" \" with straight quotes (\").",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                settingsRow("") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Read $CB_INPUT_FILE and write the result to $CB_OUTPUT_FILE.")
                            .font(.caption)
                        Text("$CB_ITEM_KIND is \"text\" or \"image\". $CB_ITEM_SOURCE is the source app bundle id ( may be empty ).")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }
            if showFingerprintCaptured {
                settingsRow("") {
                    Label(
                        "Inline script fingerprint captured.",
                        systemImage: "checkmark.seal.fill"
                    )
                    .foregroundStyle(.green)
                    .font(.caption)
                    .accessibilityIdentifier("\(accessibilityIDPrefix).fingerprintCaptured")
                }
            }
            if let error = validationError {
                settingsRow("") {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .accessibilityIdentifier("\(accessibilityIDPrefix).validationError")
                }
            }
            settingsRow("") {
                HStack {
                    Button("Save") { apply() }
                        .disabled(!canApply)
                        .accessibilityIdentifier("\(accessibilityIDPrefix).save")
                    Button {
                        testRun()
                    } label: {
                        if isTestRunning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Test Run")
                        }
                    }
                    .disabled(!canTestRun)
                    .help(testRunHelp)
                    .accessibilityIdentifier("\(accessibilityIDPrefix).testRun")
                    Spacer()
                    Button("Remove", role: .destructive) { isPresentingRemoveConfirm = true }
                        .accessibilityIdentifier("\(accessibilityIDPrefix).remove")
                }
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
                .accessibilityIdentifier("\(accessibilityIDPrefix).confirm.save")
            Button("Cancel", role: .cancel) { cancelConfirm() }
                .accessibilityIdentifier("\(accessibilityIDPrefix).confirm.cancel")
        } message: {
            Text("This script can access your clipboard contents. Do not specify untrusted scripts.")
        }
        .alert("Remove Macro?", isPresented: $isPresentingRemoveConfirm) {
            Button("Remove", role: .destructive) { remove() }
                .accessibilityIdentifier("\(accessibilityIDPrefix).remove.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Macro “\(macro.name)” will be removed. This cannot be undone.")
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
                        // reports back to the settings view model exactly once.
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

    private func settingsRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            content()
                .frame(minWidth: 320, idealWidth: 400, maxWidth: 440, alignment: .leading)
        }
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

    private var canTestRun: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && !interpreter.trimmingCharacters(in: .whitespaces).isEmpty
        && (sourceType == "inline"
            ? !inlineScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : !path.trimmingCharacters(in: .whitespaces).isEmpty)
        && historyViewModel.selectedItem != nil
        && !isTestRunning
        && !isPresentingConfirm
    }

    private var testRunHelp: String {
        if historyViewModel.selectedItem == nil { return "Select a clipboard history item before testing this Macro." }
        if hasContentChanges || macro.lastFingerprint == nil {
            return "Save and confirm this Macro, then run it against the selected history item."
        }
        return "Run this Macro against the selected history item using the normal paste flow."
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
                shouldTestAfterSave = false
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
                shouldTestAfterSave = false
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
        let runAfterSave = shouldTestAfterSave
        shouldTestAfterSave = false
        reportSaveSettlementIfNeeded()
        checkDirty()
        if runAfterSave {
            runTest(savedMacro: edited)
        }
    }

    /// Confirmation dialog "Cancel": clears pending state and, if this apply
    /// was triggered by a `.saveAllUnsavedMacros` broadcast, reports the
    /// settle so the window-close waiter does not stall.
    private func cancelConfirm() {
        pendingConfirm = nil
        pendingFileValidation = nil
        shouldTestAfterSave = false
        reportSaveSettlementIfNeeded()
    }

    /// Reports one settle to the settings view model when a `.saveAllUnsavedMacros`
    /// broadcast is in flight, then clears the flag so a subsequent manual
    /// Save does not double-count.
    private func reportSaveSettlementIfNeeded() {
        guard saveBroadcastInFlight else { return }
        saveBroadcastInFlight = false
        viewModel.recordSaveSettlement()
    }

    private func saveShortcut(keyCode: Int, modifiers: Int) {
        guard keyCode != macro.hotkeyCode || modifiers != macro.hotkeyModifiers else { return }
        var edited = macro
        edited.hotkeyCode = keyCode
        edited.hotkeyModifiers = modifiers
        onUpdate(edited)
    }

    private func testRun() {
        guard canTestRun else { return }
        if hasContentChanges || macro.lastFingerprint == nil {
            shouldTestAfterSave = true
            apply()
            return
        }
        runTest(savedMacro: macro)
    }

    private func runTest(savedMacro: MacroScript) {
        guard let item = historyViewModel.selectedItem else { return }
        isTestRunning = true
        Task {
            _ = await historyViewModel.runMacro(macro: savedMacro, item: item)
            isTestRunning = false
        }
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
        // Preserve the "fingerprint captured" badge when the just-saved model
        // actually carries a new fingerprint. `confirmSave()` sets this flag
        // to `true` and then calls `onUpdate`, which republishes the macro and
        // triggers this `syncState` via `.onChange(of: macro)`. Without this
        // guard the unconditional reset would clear the badge immediately
        // after the user confirmed the registration dialog (regression seen in
        // SmokeUITests.testAddMacroScript). We only keep it true when the
        // fingerprint really transitioned from nil to a value; for any other
        // external update (e.g. Reset / shortcut save) the badge is cleared.
        if updated.lastFingerprint != nil, previous.lastFingerprint == nil {
            showFingerprintCaptured = true
        } else {
            showFingerprintCaptured = false
        }
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
