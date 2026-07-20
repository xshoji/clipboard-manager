import AppKit

/// Records the frontmost application right before showing the UI, then restores it after pasting.
/// Design: design-app.md §2.2.1 / design-implementation.md §4.2
@MainActor
final class AppActivator: NSObject {
    static let shared = AppActivator()

    /// Stack of recently-activated external apps (newest last), with timestamps.
    ///
    /// The previous single-slot `previousApp` was unsafe for rapid A→B paste sequences:
    /// after paste A, `NSApp.hide(nil)` + `app.activate()` is asynchronous, so the frontmost
    /// app can briefly be nil or ClipboardManager itself right when the user triggers paste B.
    /// A stack preserves the most recent valid paste target across that window so the second
    /// paste still lands in the original user app instead of being dropped or misdelivered.
    private struct PreviousAppEntry {
        let app: NSRunningApplication
        let recordedAt: Date
    }
    private var previousAppStack: [PreviousAppEntry] = []
    private let maxStackDepth = 8

    /// Backward-compatible view of the most recent entry (terminated entries pruned).
    /// Prefer `bestPasteTarget()` for activation decisions.
    private var previousApp: NSRunningApplication? { bestPasteTarget() }

    private var isObservingActivatedApplications = false

    private override init() {
        super.init()
    }

    /// Continuously observes app switching and holds the last frontmost external app as the paste target.
    func startObservingActivatedApplications() {
        guard !isObservingActivatedApplications else { return }
        isObservingActivatedApplications = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    /// Stops observing app-switch notifications. Called by AppDelegate on termination
    /// so the NSWorkspace observer is removed deterministically.
    func stopObservingActivatedApplications() {
        guard isObservingActivatedApplications else { return }
        isObservingActivatedApplications = false
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        previousAppStack.removeAll()
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        pushPreviousApp(app)
    }

    /// Called right before opening the main UI to record the frontmost app before showing.
    /// Does not update if this app itself is already frontmost (ignores second call).
    /// Importantly, when the frontmost app is nil (e.g., during the brief window after
    /// `NSApp.hide(nil)` while the previous target is still activating), the stack is NOT
    /// cleared — preserving the last valid target for rapid A→B paste sequences.
    func recordBeforeShowingMainWindow() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let app = frontmost, app.processIdentifier != myPID {
            pushPreviousApp(app)
        }
        // Deliberately do not clear the stack when frontmost is nil or self,
        // so a fast second paste still has a valid target.
    }

    /// Pushes (or refreshes) an entry on the stack. Consecutive duplicates only refresh
    /// the timestamp so the stack stays bounded and the newest entry reflects the latest activation.
    private func pushPreviousApp(_ app: NSRunningApplication) {
        if let last = previousAppStack.last,
           last.app.processIdentifier == app.processIdentifier {
            previousAppStack[previousAppStack.count - 1] =
                PreviousAppEntry(app: app, recordedAt: Date())
            return
        }
        previousAppStack.append(PreviousAppEntry(app: app, recordedAt: Date()))
        if previousAppStack.count > maxStackDepth {
            previousAppStack.removeFirst()
        }
    }

    /// Returns the most recent non-terminated external app, pruning dead entries from the top.
    /// Returns `nil` only when the stack is empty or every entry has terminated.
    private func bestPasteTarget() -> NSRunningApplication? {
        while let last = previousAppStack.last {
            if last.app.isTerminated {
                previousAppStack.removeLast()
                continue
            }
            return last.app
        }
        return nil
    }

    /// Called after pasting to restore the recorded app to the foreground.
    /// Falls back to NSApp.activate if it has already terminated (review #7).
    /// Previously, the first app with activationPolicy == .regular from runningApplications was unconditionally activated,
    /// but this risked bringing unexpected apps like Finder to the front, so unknown apps are no longer activated.
    func activatePreviousApp() {
        NSApp.hide(nil)

        if let app = bestPasteTarget() {
            app.activate(options: [.activateAllWindows])
            return
        }
        // If no valid target remains, do not activate another app arbitrarily;
        // just bring this app to the front (review #7).
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called after pasting to restore the recorded app to the foreground and enable sending a synthetic Cmd+V immediately.
    /// When `needsAccessibilityForSyntheticPaste` is ON, waits for the original app to become frontmost before sending the synthetic Cmd+V (design-implementation.md §4.2 / §5.2).
    /// If no valid target is available, the paste target is unknown, so do not send synthetic Cmd+V and stop at writing to the pasteboard.
    func activatePreviousAppAndPasteSynthetically(needsSynthetic: Bool) {
        guard let app = bestPasteTarget() else {
            // No valid paste target; do not activate another app arbitrarily;
            // just bring this app to the front (review #7).
            // The paste target is unknown, so do not send synthetic Cmd+V.
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.hide(nil)
        app.activate(options: [.activateAllWindows])
        if needsSynthetic {
            sendSyntheticPasteWhenActive(to: app, attemptsRemaining: 10)
        }
    }

    /// Waits for `activate` to complete and verifies the target app is frontmost before sending Cmd+V to prevent misdelivery.
    ///
    /// Safety design (review #5):
    /// - Tight retry window: 20ms × 10 attempts (≈200ms total). A wider window risks the user
    ///   Tab-switching to another app during the wait, which would misdeliver a synthetic Cmd+V.
    /// - At the moment of sending, re-checks both `AXIsProcessTrusted()` and that the target app
    ///   is still frontmost. Cmd+V is not undoable, so we prefer no-send over wrong-send.
    /// - If `app.activate` did not bring the app to front within the window, we do NOT send and
    ///   simply give up (the user can still press Cmd+V manually).
    private func sendSyntheticPasteWhenActive(
        to app: NSRunningApplication,
        attemptsRemaining: Int
    ) {
        guard !app.isTerminated else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            // Final guard at the instant of sending: require both Accessibility permission
            // and that the target app is still frontmost. If either check fails, abort without
            // sending to avoid firing Cmd+V into an unexpected app.
            guard AXIsProcessTrusted() else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
            SyntheticPasteSender.send()
            return
        }
        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.sendSyntheticPasteWhenActive(to: app, attemptsRemaining: attemptsRemaining - 1)
        }
    }
}
