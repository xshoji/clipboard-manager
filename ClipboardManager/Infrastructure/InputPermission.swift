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
        // AXIsProcessTrustedWithOptions with prompt=true shows the system
        // accessibility dialog. This dialog also auto-registers the app in
        // the Accessibility list (unchecked) and has an "Open System Settings"
        // button so the user can grant permission. We must NOT call
        // openAccessibilitySettingsPane() here because opening System Settings
        // immediately after dismisses/covers the system dialog, preventing
        // auto-registration.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        Self.logger.info("Requested Accessibility permission via system dialog")
    }

    /// Opens System Settings → Privacy & Security → Accessibility directly,
    /// without showing the system permission dialog. Used by the "Request
    /// Accessibility permission" button when the user wants to re-open the
    /// pane (e.g. to re-grant a revoked permission).
    func openAccessibilitySettingsPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        Self.logger.info("Opened System Settings → Privacy & Security → Accessibility")
    }
}
