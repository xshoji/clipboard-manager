import AppKit

/// Platform-facing utility that converts a macOS virtual key code into a human-readable label
/// for display in hotkey recorders. Uses the active keyboard layout via `NSEvent`
/// `charactersByApplyingModifiers:` so that letter/number/symbol keys render as the actual
/// character the user pressed (e.g. pressing the physical "B" key on a US layout returns "B",
/// on a Dvorak layout returns "X").
///
/// This is shared by all hotkey recorders (global hotkey + per-Macro + action hotkeys) so the
/// key-to-symbol logic is defined in one place (DRY). UI layers must not reach into Carbon directly.
enum KeyLabelRenderer {
    /// Returns a display string for the given virtual key code.
    /// Special keys (Return, Space, arrows, function keys) have stable symbolic names independent of
    /// layout; printable keys are resolved through the current keyboard-layout input source.
    static func symbol(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case 0x24: return "Return"
        case 0x31: return "Space"
        case 0x33: return "Delete"
        case 0x35: return "Esc"
        case 0x30: return "Tab"
        case 0x7A: return "F1"
        case 0x78: return "F2"
        case 0x63: return "F3"
        case 0x76: return "F4"
        case 0x60: return "F5"
        case 0x61: return "F6"
        case 0x62: return "F7"
        case 0x64: return "F8"
        case 0x65: return "F9"
        case 0x6D: return "F10"
        case 0x67: return "F11"
        case 0x6F: return "F12"
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7D: return "↓"
        case 0x7E: return "↑"
        case 0x73: return "Home"
        case 0x77: return "End"
        case 0x74: return "PageUp"
        case 0x79: return "PageDown"
        case 0x47: return "NumLock"
        default:
            if let s = printableString(for: keyCode), !s.isEmpty {
                return s
            }
            return "Key(0x\(String(format: "%X", keyCode)))"
        }
    }

    /// Resolves a printable character for `keyCode` using the current keyboard layout.
    /// Returns `nil` for non-printable keys or when layout resolution fails. The result is
    /// upper-cased to match the conventional hotkey display (e.g. "⌘B" rather than "⌘b").
    ///
    /// Implementation note: Apple discourages directly calling `UCKeyTranslate` from app code and
    /// recommends `NSEvent.charactersByApplyingModifiers:` instead. We synthesize a minimal key-down
    /// event for the given virtual key code and ask it for the character produced under no modifiers.
    private static func printableString(for keyCode: UInt32) -> String? {
        // `charactersIgnoringModifiers` may be an empty string for some keys; we pass the keyCode
        // explicitly so AppKit consults the active `TISInputSource` keyboard layout for us.
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ) else {
            return nil
        }
        // `charactersByApplyingModifiers:` returns the character that would be produced under the
        // given modifier flags. Passing an empty mask yields the base (no-modifier) character.
        guard let chars = event.characters(byApplyingModifiers: []), !chars.isEmpty else {
            return event.characters?.isEmpty == false ? event.characters : nil
        }
        return chars.uppercased()
    }
}
