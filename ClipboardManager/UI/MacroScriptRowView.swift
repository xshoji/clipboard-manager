import SwiftUI
import AppKit

struct MacroScriptRowView: View {
    let macro: MacroScript
    @Binding var isExpanded: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onReorder: (CGPoint) -> Void
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
    @GestureState private var isDragging = false
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
    /// Pending edit awaiting the registration/change confirmation dialog (design-implementation.md §5.1-1).
    @State private var pendingConfirm: MacroScript?
    @State private var pendingFileValidation: MacroScriptValidation?
    @State private var isPresentingConfirm: Bool = false
    @State private var isPresentingRemoveConfirm: Bool = false
    @State private var shouldTestAfterSave: Bool = false
    @State private var testInput: String = ""
    @State private var debugReport: MacroDebugReport?
    @State private var testTask: Task<Void, Never>?
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

    private static let javaScriptJXATemplate = """
    function main(clipboardContentString) {
        return clipboardContentString;
    }
    """

    init(macro: MacroScript,
         accessibilityIDPrefix: String = "macro",
         isExpanded: Binding<Bool>,
         canMoveUp: Bool = false,
         canMoveDown: Bool = false,
         onMoveUp: @escaping () -> Void = {},
         onMoveDown: @escaping () -> Void = {},
         onReorder: @escaping (CGPoint) -> Void,
         onUpdate: @escaping (MacroScript) -> Void,
         onDirtyChange: ((UUID, Bool) -> Void)? = nil) {
        self.macro = macro
        self.accessibilityIDPrefix = accessibilityIDPrefix
        self._isExpanded = isExpanded
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        self.onReorder = onReorder
        self.onUpdate = onUpdate
        self.onDirtyChange = onDirtyChange
        _name = State(initialValue: macro.name)
        _sourceType = State(initialValue: Self.sourceType(for: macro.source))
        _path = State(initialValue: macro.scriptPath)
        _inlineScript = State(initialValue: macro.inlineScript ?? "")
        _testInput = State(initialValue: macro.testInput ?? "")
        _interpreter = State(initialValue: macro.interpreter)
        _interpreterPreset = State(
            initialValue: Self.shellPresets.contains(macro.interpreter) ? macro.interpreter : "custom"
        )
        _hotkeyCode = State(initialValue: macro.hotkeyCode)
        _hotkeyModifiers = State(initialValue: macro.hotkeyModifiers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded {
                Divider()
                settingsRow("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("\(accessibilityIDPrefix).name")
                }
                if sourceType != "jxa" { settingsRow("Interpreter") {
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
                } }
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
                        Text("JavaScript (JXA)").tag("jxa")
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
                    PlainTextEditor(text: $inlineScript)
                        .accessibilityIdentifier("\(accessibilityIDPrefix).inlineScript")
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.25))
                                .allowsHitTesting(false)
                        }
                    if PlainTextEditor.containsSmartQuotes(in: inlineScript) {
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
                            Text(sourceType == "jxa" ? "Implement main(clipboardContentString) and return a string." : "Read $CB_INPUT_FILE and write the result to $CB_OUTPUT_FILE.")
                                .font(.caption)
                            Text(sourceType == "jxa" ? "Runs with macOS JavaScript for Automation (JXA) via /usr/bin/osascript. Node.js APIs are not available. Macros run as you and accept text input only." : "$CB_ITEM_KIND is \"text\" or \"image\". $CB_ITEM_SOURCE is the source app bundle id ( may be empty ).")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    }
                }
                settingsRow("Test Input") {
                    VStack(alignment: .leading, spacing: 4) {
                        PlainTextEditor(text: $testInput)
                            .frame(height: testInput.isEmpty ? 28 : 72)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.secondary.opacity(0.25))
                                    .allowsHitTesting(false)
                            }
                            .accessibilityIdentifier("\(accessibilityIDPrefix).testInput")
                        Text("Saved automatically with this Macro and used only by Test Run.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                            .disabled(isTestRunning)
                            .accessibilityIdentifier("\(accessibilityIDPrefix).remove")
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .padding(.vertical, 2)
        .background(dragHighlight)
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
        .sheet(item: $debugReport) { report in
            MacroDebugConsoleView(
                macroName: macro.name,
                report: report,
                onCopy: historyViewModel.copyMacroDebugReport
            )
        }
        .onAppear {
            checkDirty()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveAllUnsavedMacros)) { _ in
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
        .onDisappear {
            testTask?.cancel()
            testTask = nil
            isTestRunning = false
        }
        .onChange(of: macro) { previous, updated in
            syncState(from: previous, to: updated)
        }
        .onChange(of: name) { _, _ in
            showFingerprintCaptured = false
            checkDirty()
        }
        .onChange(of: sourceType) { previous, updated in
            if updated == "jxa", previous != "jxa" {
                inlineScript = Self.javaScriptJXATemplate
            }
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
        .onChange(of: testInput) { _, _ in saveTestInput() }
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

    private var dragHighlight: some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        return shape
            .fill(Color.accentColor.opacity(isDragging ? 0.12 : 0))
            .overlay {
                shape.strokeBorder(Color.accentColor.opacity(isDragging ? 1 : 0), lineWidth: 2)
            }
            .padding(-6)
            .allowsHitTesting(false)
    }

    /// Collapsed summary: name, source, and shortcut only. Script bodies stay
    /// in the expanded editor so the list remains scannable.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(0..<3) { _ in
                    GridRow {
                        Circle().frame(width: 3, height: 3)
                        Circle().frame(width: 3, height: 3)
                    }
                }
            }
            .foregroundStyle(isDragging ? Color.accentColor : Color.secondary)
            .frame(width: 20, height: 32)
            .contentShape(Rectangle())
            .help("Drag to reorder Macro")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isDragging ? "Dragging \(displayName)" : "Reorder \(displayName)")
            .accessibilityIdentifier("\(accessibilityIDPrefix).dragHandle")
            .accessibilityActions {
                if canMoveUp { Button("Move up", action: onMoveUp) }
                if canMoveDown { Button("Move down", action: onMoveDown) }
            }
            // Keep reordering local so editors never receive a pasteboard drop.
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($isDragging) { _, dragging, _ in dragging = true }
                .onChanged { onReorder($0.location) })

            Button(action: toggleExpanded) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16, height: 16)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(displayName)
                                .font(.headline)
                                .lineLimit(1)
                            if hasContentChanges {
                                Text("Unsaved")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text(sourceSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse Macro" : "Expand Macro")
            .accessibilityLabel(hasContentChanges ? "\(displayName), \(sourceSummary), Unsaved" : "\(displayName), \(sourceSummary)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("\(accessibilityIDPrefix).toggle")

            shortcutSummary
        }
        .padding(.bottom, 2)
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Macro" : trimmed
    }

    private var sourceSummary: String {
        switch sourceType {
        case "jxa":
            return "JavaScript (JXA)"
        case "file":
            let fileName = (path as NSString).lastPathComponent
            return fileName.isEmpty ? "Script file" : "Script file · \(fileName)"
        default:
            return interpreter.isEmpty ? "Inline shell" : "Inline shell · \(interpreter)"
        }
    }

    private var hasShortcut: Bool {
        hotkeyCode != 0 || hotkeyModifiers != 0
    }

    private var shortcutLabel: String {
        KeyLabelRenderer.displayString(keyCode: UInt32(hotkeyCode), modifiers: hotkeyModifiers)
    }

    @ViewBuilder
    private var shortcutSummary: some View {
        Group {
            if hasShortcut {
                Text(shortcutLabel)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.separatorLine))
            } else {
                Text("No shortcut")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasShortcut ? shortcutLabel : "No shortcut")
        .accessibilityIdentifier("\(accessibilityIDPrefix).summaryShortcut")
    }

    private func toggleExpanded() {
        isExpanded = !isExpanded
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
        && (sourceType == "jxa" || !interpreter.trimmingCharacters(in: .whitespaces).isEmpty)
        && (sourceType != "file"
            ? !inlineScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : !path.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var hasContentChanges: Bool {
        name != macro.name
        || sourceType != Self.sourceType(for: macro.source)
        || path != macro.scriptPath
        || inlineScript != (macro.inlineScript ?? "")
        || (sourceType != "jxa" && interpreter != macro.interpreter)
        || hotkeyCode != macro.hotkeyCode
        || hotkeyModifiers != macro.hotkeyModifiers
    }

    private var canTestRun: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && (sourceType == "jxa" || !interpreter.trimmingCharacters(in: .whitespaces).isEmpty)
        && (sourceType != "file"
            ? !inlineScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : !path.trimmingCharacters(in: .whitespaces).isEmpty)
        && !isTestRunning
        && !isPresentingConfirm
    }

    private var testRunHelp: String {
        if hasContentChanges || macro.lastFingerprint == nil {
            return "Save and confirm this Macro, then debug it with the Test Input."
        }
        return "Run with the Test Input and inspect the result without changing the pasteboard."
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
        edited.hotkeyCode = hotkeyCode
        edited.hotkeyModifiers = hotkeyModifiers

        if sourceType != "file" {
            let body = inlineScript
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                validationError = "Shell script is empty."
                shouldTestAfterSave = false
                reportSaveSettlementIfNeeded()
                return
            }
            edited.source = sourceType == "jxa" ? .javaScriptJXA(code: body) : .inlineShell(code: body, interpreter: interpreter)
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
            edited.source = .file(path: v.resolvedPath, interpreter: interpreter)
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
        if let body = edited.source.userCode {
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

    private func saveTestInput() {
        let storedInput = testInput.isEmpty ? nil : testInput
        guard storedInput != macro.testInput else { return }
        var edited = macro
        edited.testInput = storedInput
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
        let inputText = testInput
        testTask?.cancel()
        isTestRunning = true
        testTask = Task { @MainActor in
            defer {
                isTestRunning = false
                testTask = nil
            }
            do {
                let report = try await historyViewModel.debugMacro(macro: savedMacro, inputText: inputText)
                guard !Task.isCancelled else { return }
                debugReport = report
            } catch is CancellationError {
                // Closing the view or removing the Macro intentionally stops the debug run.
            } catch {
                guard !Task.isCancelled else { return }
                debugReport = .notLaunched(
                    command: "\(savedMacro.interpreter) \(savedMacro.inlineScript == nil ? savedMacro.scriptPath : "<inline-script>")",
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    private func remove() {
        testTask?.cancel()
        testTask = nil
        onDirtyChange?(macro.id, false)
        var arr = settings.macroScripts
        arr.removeAll { $0.id == macro.id }
        settings.macroScripts = arr
    }

    private func syncState(from previous: MacroScript, to updated: MacroScript) {
        if name == previous.name { name = updated.name }
        if sourceType == Self.sourceType(for: previous.source) {
            sourceType = Self.sourceType(for: updated.source)
        }
        if path == previous.scriptPath { path = updated.scriptPath }
        if inlineScript == (previous.inlineScript ?? "") { inlineScript = updated.inlineScript ?? "" }
        if testInput == (previous.testInput ?? "") { testInput = updated.testInput ?? "" }
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

    private static func sourceType(for source: MacroSource) -> String {
        switch source { case .inlineShell: return "inline"; case .javaScriptJXA: return "jxa"; case .file: return "file" }
    }

    private func checkDirty() {
        let dirty = hasContentChanges
        if dirty != lastNotifiedDirty {
            lastNotifiedDirty = dirty
            onDirtyChange?(macro.id, dirty)
        }
    }
}

private struct MacroDebugConsoleView: View {
    @Environment(\.dismiss) private var dismiss
    let macroName: String
    let report: MacroDebugReport
    let onCopy: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Macro Debug Console")
                        .font(.title2.weight(.semibold))
                        .accessibilityIdentifier("macroDebug.console")
                    Text(macroName)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(statusText, systemImage: statusImage)
                    .foregroundStyle(report.succeeded ? .green : .red)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("The Macro ran with the normal execution environment. ClipboardManager did not write its result to the pasteboard or switch applications. The script itself still runs with your user permissions.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    GroupBox("Execution") {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                            debugRow("Command", report.command)
                            debugRow("Total Duration", String(format: "%.3f s", report.duration))
                            debugRow("Exit", exitDescription)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let errorMessage = report.errorMessage {
                        consoleSection("Error", text: errorMessage, color: .red, accessibilityID: "macroDebug.error")
                    }
                    consoleSection(
                        "Standard Output (stdout)",
                        text: streamText(report.standardOutput, truncated: report.standardOutputTruncated),
                        accessibilityID: "macroDebug.stdout"
                    )
                    consoleSection(
                        "Standard Error (stderr)",
                        text: streamText(report.standardError, truncated: report.standardErrorTruncated),
                        accessibilityID: "macroDebug.stderr"
                    )
                    consoleSection(
                        report.usedInputFallback ? "Macro Output (input fallback)" : "Macro Output",
                        text: outputDescription,
                        accessibilityID: "macroDebug.output"
                    )

                    GroupBox("Macro Environment") {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                            ForEach(report.environment.keys.sorted(), id: \.self) { key in
                                debugRow(key, report.environment[key] ?? "")
                            }
                            if report.environment.isEmpty {
                                Text("Process was not launched.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Temporary input, output, and inline-script files are removed after execution.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()

            HStack {
                Button("Copy Report") { copyReport() }
                    .accessibilityIdentifier("macroDebug.copy")
                Spacer()
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("macroDebug.done")
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 720, minHeight: 620)
    }

    private var statusText: String {
        if report.succeeded { return "Succeeded" }
        if report.timedOut { return "Timed Out" }
        if report.terminationStatus == nil { return "Not Launched" }
        return "Failed"
    }

    private var statusImage: String {
        report.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill"
    }

    private var exitDescription: String {
        if report.timedOut { return "Timed out after 5 seconds (status \(report.terminationStatus ?? -1))" }
        if let status = report.terminationStatus { return "Status \(status)" }
        return "Not launched"
    }

    private var outputDescription: String {
        guard let output = report.output else { return "(no readable output)" }
        let size = "\(output.totalByteCount) bytes"
        switch output.kind {
        case .image:
            return "Image output (\(size))"
        case .binary:
            return "Binary output (\(size))"
        case .text:
            let text = output.previewText ?? ""
            return output.truncated
                ? "\(text)\n\n[truncated after \(output.previewByteCount) bytes; total \(size)]"
                : text
        }
    }

    private func streamText(_ text: String, truncated: Bool) -> String {
        let value = text.isEmpty ? "(no output)" : text
        return truncated ? "\(value)\n\n[truncated after 256 KiB]" : value
    }

    @ViewBuilder
    private func debugRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func consoleSection(
        _ title: String,
        text: String,
        color: Color = .primary,
        accessibilityID: String
    ) -> some View {
        GroupBox(title) {
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(color)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(accessibilityID)
    }

    private var reportText: String {
        let environment = report.environment.keys.sorted().map { "\($0)=\(report.environment[$0] ?? "")" }.joined(separator: "\n")
        return """
        Macro: \(macroName)
        Status: \(statusText)
        Command: \(report.command)
        Exit: \(exitDescription)
        Total Duration: \(String(format: "%.3f s", report.duration))

        Error
        \(report.errorMessage ?? "(none)")

        stdout
        \(streamText(report.standardOutput, truncated: report.standardOutputTruncated))

        stderr
        \(streamText(report.standardError, truncated: report.standardErrorTruncated))

        Macro Output
        \(outputDescription)

        Environment
        \(environment)
        """
    }

    private func copyReport() {
        onCopy(reportText)
    }
}

/// Plain-text editor that preserves input verbatim by disabling macOS text substitutions.
struct PlainTextEditor: NSViewRepresentable {
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
        var parent: PlainTextEditor
        /// `true` while the parent is programmatically setting `textView.string`,
        /// so `textDidChange` is ignored and the binding is not overwritten.
        var isUpdatingFromParent = false

        init(parent: PlainTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromParent else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
