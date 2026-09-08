import SwiftUI
import AppKit
import Carbon.HIToolbox

struct HotkeyRecorderView: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    let canStartRecording: Bool
    let onRecordingStart: () -> Bool
    let onRecordingEnd: () -> Void
    let validateCandidate: (Int, Int) -> Bool
    let onChange: () -> Void
    let title: String
    let systemImage: String
    let accessibilityIDPrefix: String
    let defaultKeyCode: Int
    let defaultModifiers: Int
    let showReset: Bool
    let showClear: Bool
    @State private var recording = false
    @State private var display: String = ""

    init(
        keyCode: Binding<Int>,
        modifiers: Binding<Int>,
        canStartRecording: Bool = true,
        onRecordingStart: @escaping () -> Bool = { true },
        onRecordingEnd: @escaping () -> Void = {},
        validateCandidate: @escaping (Int, Int) -> Bool = { _, _ in true },
        onChange: @escaping () -> Void,
        title: String,
        systemImage: String,
        accessibilityIDPrefix: String,
        defaultKeyCode: Int,
        defaultModifiers: Int,
        showReset: Bool = true,
        showClear: Bool = false
    ) {
        self._keyCode = keyCode
        self._modifiers = modifiers
        self.canStartRecording = canStartRecording
        self.onRecordingStart = onRecordingStart
        self.onRecordingEnd = onRecordingEnd
        self.validateCandidate = validateCandidate
        self.onChange = onChange
        self.title = title
        self.systemImage = systemImage
        self.accessibilityIDPrefix = accessibilityIDPrefix
        self.defaultKeyCode = defaultKeyCode
        self.defaultModifiers = defaultModifiers
        self.showReset = showReset
        self.showClear = showClear
    }

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .accessibilityIdentifier("\(accessibilityIDPrefix).label")
            Spacer()
            Text(display)
                .frame(minWidth: 120)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.separatorLine))
                .accessibilityIdentifier("\(accessibilityIDPrefix).display")
            Button(recording ? "Cancel" : "Record") {
                if recording {
                    cancelRecording()
                } else {
                    guard canStartRecording else { return }
                    guard onRecordingStart() else { return }
                    recording = true
                }
            }
            .disabled(!recording && !canStartRecording)
            .accessibilityIdentifier("\(accessibilityIDPrefix).record")
            .accessibilityValue(recording ? "Recording" : "Idle")
            if showClear, keyCode != 0 || modifiers != 0 {
                Button("Clear") {
                    keyCode = 0
                    modifiers = 0
                    refresh()
                    onChange()
                }
                .disabled(recording || !canStartRecording)
                .accessibilityIdentifier("\(accessibilityIDPrefix).clear")
            }
            if showReset {
                Button("Reset") {
                    guard validateCandidate(defaultKeyCode, defaultModifiers) else { return }
                    keyCode = defaultKeyCode
                    modifiers = defaultModifiers
                    refresh()
                    onChange()
                }
                .disabled(recording || !canStartRecording)
                .accessibilityIdentifier("\(accessibilityIDPrefix).reset")
            }
        }
        .onAppear { refresh() }
        .onDisappear {
            if recording { finishRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mainHotkeyRegistrationResult)) { _ in
            refresh()
        }
        .background(recording ? Color.red.opacity(0.05) : Color.clear)
        .overlay {
            if recording {
                ListenerView { capturedKeyCode, capturedModifiers in
                    if capturedKeyCode == Int(kVK_Escape) {
                        finishRecording()
                        return
                    }
                    guard validateCandidate(capturedKeyCode, capturedModifiers) else {
                        finishRecording()
                        refresh()
                        return
                    }
                    keyCode = capturedKeyCode
                    modifiers = capturedModifiers
                    refresh()
                    finishRecording()
                    onChange()
                }
            }
        }
    }

    private func cancelRecording() {
        finishRecording()
    }

    private func finishRecording() {
        guard recording else { return }
        recording = false
        onRecordingEnd()
    }

    private func refresh() {
        if keyCode == 0 && modifiers == 0 {
            display = "(none)"
            return
        }
        display = KeyLabelRenderer.displayString(
            keyCode: UInt32(keyCode),
            modifiers: modifiers
        )
    }
}

/// Recorder for editing arbitrary key bindings such as per-Macro rows. Independent of the global hotkey in settings.
struct MacroHotkeyRecorderView: View {
    let keyCode: Binding<Int>
    let modifiers: Binding<Int>
    let canStartRecording: Bool
    let onRecordingStart: () -> Bool
    let onRecordingEnd: () -> Void
    let validateCandidate: (Int, Int) -> Bool
    let onShortcutChange: (Int, Int) -> Void
    /// Optional reset handler. When non-nil, a "Reset" button is shown.
    /// Clicking it invokes this closure; the view then refreshes its display.
    let resetAction: (() -> Void)?
    /// Stable identifier prefix appended to record/clear/reset/display accessibilityIdentifier
    /// so XCUITest can address a specific action hotkey row (e.g. "action.edit.record").
    let accessibilityIDPrefix: String
    @State private var recording = false
    @State private var display: String = ""

    init(
        keyCode: Binding<Int>,
        modifiers: Binding<Int>,
        canStartRecording: Bool = true,
        onRecordingStart: @escaping () -> Bool = { true },
        onRecordingEnd: @escaping () -> Void = {},
        validateCandidate: @escaping (Int, Int) -> Bool = { _, _ in true },
        onShortcutChange: @escaping (Int, Int) -> Void = { _, _ in },
        resetAction: (() -> Void)? = nil,
        accessibilityIDPrefix: String = "macro"
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.canStartRecording = canStartRecording
        self.onRecordingStart = onRecordingStart
        self.onRecordingEnd = onRecordingEnd
        self.validateCandidate = validateCandidate
        self.onShortcutChange = onShortcutChange
        self.resetAction = resetAction
        self.accessibilityIDPrefix = accessibilityIDPrefix
    }

    var body: some View {
        HStack {
            Text(display)
                .frame(minWidth: 120)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.separatorLine))
                .accessibilityIdentifier("\(accessibilityIDPrefix).display")
            Button(recording ? "Press…" : "Record") {
                guard canStartRecording else { return }
                guard onRecordingStart() else { return }
                recording = true
            }
                .disabled(recording || !canStartRecording)
                .accessibilityIdentifier("\(accessibilityIDPrefix).record")
                .accessibilityValue(recording ? "Recording" : "Idle")
            if keyCode.wrappedValue != 0 || modifiers.wrappedValue != 0 {
                Button("Clear") {
                    // `onShortcutChange` is the single writer path; the host
                    // decides whether to actually clear (e.g. action hotkeys
                    // go through `applyActionHotkey` so the duplicate guard
                    // runs). The display is refreshed *after* the host writes
                    // so the new value is reflected; we don't write the Binding
                    // here for action hotkeys because the host owns the value.
                    // Macro rows use @State-backed Bindings whose `set` is
                    // *not* a no-op, so for those we still update the binding
                    // so the dirty/onChange tracking fires — but we refresh
                    // after `onShortcutChange` regardless so the final value
                    // is what is shown.
                    onShortcutChange(0, 0)
                    refresh()
                }
                .disabled(recording || !canStartRecording)
                .accessibilityIdentifier("\(accessibilityIDPrefix).clear")
            }
            if let resetAction = resetAction {
                Button("Reset") {
                    resetAction()
                    refresh()
                }
                .disabled(recording || !canStartRecording)
                .accessibilityIdentifier("\(accessibilityIDPrefix).reset")
            }
        }
        .onAppear { refresh() }
        .onDisappear {
            if recording { finishRecording() }
        }
        .background(recording ? Color.red.opacity(0.05) : Color.clear)
        .onChange(of: keyCode.wrappedValue) { _, _ in refresh() }
        .onChange(of: modifiers.wrappedValue) { _, _ in refresh() }
        .overlay {
            if recording {
                ListenerView { kc, mods in
                    if kc == Int(kVK_Escape) {
                        finishRecording()
                        return
                    }
                    guard mods != 0 else { return }
                    guard validateCandidate(kc, mods) else {
                        finishRecording()
                        refresh()
                        return
                    }
                    // Write the Binding for macro-row @State parity (dirty /
                    // onChange tracking fires from this write). For action
                    // hotkeys the Binding `set` is a no-op because
                    // `applyActionHotkey` is the single writer — the display
                    // is refreshed explicitly *after* `onShortcutChange` so
                    // the verified value is shown (or the pre-change value
                    // when the candidate was rejected by the duplicate guard).
                    keyCode.wrappedValue = kc
                    modifiers.wrappedValue = mods
                    finishRecording()
                    onShortcutChange(kc, mods)
                    refresh()
                }
            }
        }
    }

    private func finishRecording() {
        guard recording else { return }
        recording = false
        onRecordingEnd()
    }

    private func refresh() {
        let kc = keyCode.wrappedValue
        let mods = modifiers.wrappedValue
        if kc == 0 && mods == 0 {
            display = "(none)"
            return
        }
        display = KeyLabelRenderer.displayString(keyCode: UInt32(kc), modifiers: mods)
    }
}

private struct ListenerView: NSViewRepresentable {
    let onCapture: (Int, Int) -> Void

    func makeNSView(context: Context) -> CaptureKeyView {
        let v = CaptureKeyView()
        v.onCapture = onCapture
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ nsView: CaptureKeyView, context: Context) {}
}

private final class CaptureKeyView: NSView {
    var onCapture: ((Int, Int) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue
        onCapture?(Int(event.keyCode), Int(mods))
    }

    /// `performKeyEquivalent` is called before `keyDown`, and menu shortcuts
    /// such as Cmd+M (minimize) are consumed by the system here.
    /// While recording, we intercept all key equivalents here and consume
    /// them so that Cmd+M etc. do not fire as system shortcuts.
    /// `CaptureKeyView` only exists in the view hierarchy while recording
    /// (inside the overlay), so returning `true` is always safe.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue
        onCapture?(Int(event.keyCode), Int(mods))
        return true
    }
}
