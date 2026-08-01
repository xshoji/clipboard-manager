import AppKit
import ApplicationServices
import os

@MainActor
struct InputPermission {
    private static let logger = Logger(subsystem: "com.xshoji.ClipboardManager", category: "InputPermission")

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

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
        // Defer until the Toggle's SwiftUI update transaction has completed. Calling
        // AXIsProcessTrustedWithOptions synchronously from the binding setter can fail
        // to present/register the app when Settings is hosted in our coordinator-owned
        // NSWindow rather than SwiftUI's Settings scene.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            // Use the documented key value directly. Swift 6 treats the imported
            // ApplicationServices global as mutable shared state and rejects access
            // from a @Sendable dispatch closure.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            Self.logger.info("Requested Accessibility permission via system dialog")
        }
    }

    /// Opens System Settings → Privacy & Security → Accessibility directly,
    /// without showing the system permission dialog. Used by the Accessibility
    /// Settings button when the user wants to re-open the pane (e.g. to re-grant
    /// a revoked permission).
    func openAccessibilitySettingsPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        Self.logger.info("Opened System Settings → Privacy & Security → Accessibility")
    }
}
