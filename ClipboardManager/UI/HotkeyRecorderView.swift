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
            Button(recording ? "Press keys…" : "Record") {
                recording = true
            }
            .disabled(recording)
            Button("Reset") {
                settings.hotkeyKeyCode = 7
                settings.hotkeyModifiers = Int(NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.control.rawValue)
                refresh()
                NotificationCenter.default.post(name: .mainHotkeyChanged, object: nil)
            }
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
        let mods = NSEvent.ModifierFlags(rawValue: UInt(settings.hotkeyModifiers))
        let key = UInt32(settings.hotkeyKeyCode)
        let symbol = KeyLabelRenderer.symbol(for: key)
        var parts: [String] = []
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option) { parts.append("⌥") }
        if mods.contains(.shift) { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }
        parts.append(symbol)
        display = parts.joined()
    }
}

/// Recorder for editing arbitrary key bindings such as per-Macro rows. Independent of the global hotkey in settings.
struct MacroHotkeyRecorderView: View {
    let keyCode: Binding<Int>
    let modifiers: Binding<Int>
    let onShortcutChange: (Int, Int) -> Void
    @State private var recording = false
    @State private var display: String = ""

    init(
        keyCode: Binding<Int>,
        modifiers: Binding<Int>,
        onShortcutChange: @escaping (Int, Int) -> Void = { _, _ in }
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.onShortcutChange = onShortcutChange
    }

    var body: some View {
        HStack {
            Text(display)
                .frame(minWidth: 120)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.separatorLine))
            Button(recording ? "Press…" : "Record") { recording = true }
                .disabled(recording)
            if keyCode.wrappedValue != 0 || modifiers.wrappedValue != 0 {
                Button("Clear") {
                    keyCode.wrappedValue = 0
                    modifiers.wrappedValue = 0
                    refresh()
                    onShortcutChange(0, 0)
                }
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
                    keyCode.wrappedValue = kc
                    modifiers.wrappedValue = mods
                    refresh()
                    recording = false
                    onShortcutChange(kc, mods)
                }
            }
        }
    }

    private func refresh() {
        let kc = keyCode.wrappedValue
        let mods = NSEvent.ModifierFlags(rawValue: UInt(modifiers.wrappedValue))
        if kc == 0 && mods.rawValue == 0 {
            display = "(none)"
            return
        }
        var parts: [String] = []
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option) { parts.append("⌥") }
        if mods.contains(.shift) { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }
        parts.append(KeyLabelRenderer.symbol(for: UInt32(kc)))
        display = parts.joined()
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
}
