import AppKit
import ApplicationServices
import os

@MainActor
struct InputPermission {
    private static let logger = Logger(subsystem: "com.xshoji.ClipboardManager", category: "InputPermission")

    /// Reference holder for a one-shot NotificationCenter observer so the
    /// observer closure can remove itself without capturing a mutable local.
    private final class ObserverToken: @unchecked Sendable {
        var observer: NSObjectProtocol?
    }

    func checkAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibility() {
        // The Settings window is kept at `.floating + 1` so it stays above the
        // always-on-top history panel. The system Accessibility confirmation
        // dialog shown by `AXIsProcessTrustedWithOptions` is displayed at a
        // normal window level, so it would be hidden behind the floating
        // Settings window. Temporarily lower the key window's level so the
        // system dialog is visible, and restore the original level once the
        // window becomes key again (i.e. the user dismissed the dialog and
        // returned to Settings).
        if let keyWindow = NSApp.keyWindow, keyWindow.level > .normal {
            let originalLevel = keyWindow.level
            keyWindow.level = .normal
            let token = ObserverToken()
            token.observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: keyWindow,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    keyWindow.level = originalLevel
                    if let observer = token.observer {
                        NotificationCenter.default.removeObserver(observer)
                        token.observer = nil
                    }
                }
            }
        }
        // Always open System Settings → Privacy & Security → Accessibility,
        // regardless of current permission state. AXIsProcessTrusted() caches
        // the trusted state and does not reflect revocation immediately, so we
        // cannot rely on it to decide whether to show the dialog. Opening the
        // pane unconditionally lets the user grant or re-grant permission.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettingsPane()
        Self.logger.info("Opened System Settings → Privacy & Security → Accessibility")
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    /// Works on macOS 13 (Ventura) and later (System Settings replaced System Preferences).
    private func openAccessibilitySettingsPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
