import SwiftUI
import AppKit

struct HotkeyRecorderView: View {
    @Environment(AppSettings.self) private var settings
    @State private var recording = false
    @State private var display: String = ""

    var body: some View {
        HStack {
            Label("Hotkey", systemImage: "command")
            Spacer()
            Text(display)
                .frame(minWidth: 120)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.separatorLine))
                .accessibilityIdentifier("globalHotkey.display")
            Button(recording ? "Press keys…" : "Record") {
                recording = true
            }
            .disabled(recording)
            .accessibilityIdentifier("globalHotkey.record")
            Button("Reset") {
                settings.hotkeyKeyCode = AppSettings.defaultHotkeyKeyCode
                settings.hotkeyModifiers = AppSettings.defaultHotkeyModifiers
                refresh()
                NotificationCenter.default.post(name: .mainHotkeyChanged, object: nil)
            }
            .accessibilityIdentifier("globalHotkey.reset")
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .mainHotkeyRegistrationResult)) { _ in
            refresh()
        }
        .background(recording ? Color.red.opacity(0.05) : Color.clear)
        .overlay {
            if recording {
                ListenerView { keyCode, mods in
                    settings.hotkeyKeyCode = keyCode
                    settings.hotkeyModifiers = mods
                    refresh()
                    recording = false
                    NotificationCenter.default.post(name: .mainHotkeyChanged, object: nil)
                }
            }
        }
    }

    private func refresh() {
        display = KeyLabelRenderer.displayString(
            keyCode: UInt32(settings.hotkeyKeyCode),
            modifiers: settings.hotkeyModifiers
        )
    }
}

/// Recorder for editing arbitrary key bindings such as per-Macro rows. Independent of the global hotkey in settings.
struct MacroHotkeyRecorderView: View {
    let keyCode: Binding<Int>
    let modifiers: Binding<Int>
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
        onShortcutChange: @escaping (Int, Int) -> Void = { _, _ in },
        resetAction: (() -> Void)? = nil,
        accessibilityIDPrefix: String = "macro"
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
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
            Button(recording ? "Press…" : "Record") { recording = true }
                .disabled(recording)
                .accessibilityIdentifier("\(accessibilityIDPrefix).record")
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
                .accessibilityIdentifier("\(accessibilityIDPrefix).clear")
            }
            if let resetAction = resetAction {
                Button("Reset") {
                    resetAction()
                    refresh()
                }
                .accessibilityIdentifier("\(accessibilityIDPrefix).reset")
            }
        }
        .onAppear { refresh() }
        .background(recording ? Color.red.opacity(0.05) : Color.clear)
        .onChange(of: keyCode.wrappedValue) { _, _ in refresh() }
        .onChange(of: modifiers.wrappedValue) { _, _ in refresh() }
        .overlay {
            if recording {
                ListenerView { kc, mods in
                    guard mods != 0 else { return }
                    // Write the Binding for macro-row @State parity (dirty /
                    // onChange tracking fires from this write). For action
                    // hotkeys the Binding `set` is a no-op because
                    // `applyActionHotkey` is the single writer — the display
                    // is refreshed explicitly *after* `onShortcutChange` so
                    // the verified value is shown (or the pre-change value
                    // when the candidate was rejected by the duplicate guard).
                    keyCode.wrappedValue = kc
                    modifiers.wrappedValue = mods
                    recording = false
                    onShortcutChange(kc, mods)
                    refresh()
                }
            }
        }
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
