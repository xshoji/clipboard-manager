import AppKit
import ApplicationServices

/// Sends a synthetic `Cmd+V` to finish pasting into the frontmost application.
/// Design: design-app.md §2.2.1 / design-implementation.md §4.2, §5.2
/// Requires Accessibility permission. Used only when `AppSettings.needsAccessibilityForSyntheticPaste` is ON.
@MainActor
enum SyntheticPasteSender {
    /// Sends a synthetic `Cmd+V` only when Accessibility permission is granted.
    /// Returns `false` without sending if permission is missing (caller falls back to normal frontmost-app restoration).
    @discardableResult
    static func send() -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let source = CGEventSource(stateID: .hidSystemState)
        guard let source else { return false }

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
        cmdDown?.flags = .maskCommand

        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand

        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

        guard let cmdDown, let vDown, let vUp, let cmdUp else { return false }

        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
        return true
    }
}
