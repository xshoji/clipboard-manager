import AppKit
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.xshoji.ClipboardManager", category: "AppDelegate")

    let container: AppContainer
    var settings: AppSettings { container.settings }
    var monitor: ClipboardMonitor { container.monitor }
    var hotkeyManager: HotkeyManager { container.hotkeyManager }
    var menuBarController: MenuBarController { container.menuBarController }
    private var mainWindowController: MainWindowController? { container.coordinator.mainWindow.windowController }

    /// Window-scoped action hotkey IDs ( design: edit / paste plain / etc., effective only while the history window is visible ).
    /// Stable UInt32 ids passed straight to `RegisterEventHotKey`. Must not collide with `mainRegistryID` ( 0xABCD_0001 ) or macro eventIDs ( 0xABCD_1000+ ).
    enum ActionHotkeyID {
        static let edit: UInt32 = 0xABCD_0002
        static let pastePlain: UInt32 = 0xABCD_0003
       static let macroPicker: UInt32 = 0xABCD_0004
    }

    override init() {
        self.container = AppContainer()
        super.init()
        container.coordinator.mainWindow.onInstallHotkeys = { [weak self] in self?.installWindowScopedHotkeys() }
        container.coordinator.mainWindow.onUninstallHotkeys = { [weak self] in self?.uninstallWindowScopedHotkeys() }
        container.coordinator.mainWindow.onClearHistory = { [weak self] in self?.confirmClearHistory() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        AppActivator.shared.startObservingActivatedApplications()
        ClipboardMonitor.shared = monitor
        PreviewImageEditor.shared.configure(repository: container.repository)
        container.repository.start()
        monitor.start()
        // Start the history view model at launch so its change observer stays active
        // and clipboard history is updated in the background even while the history
        // window is hidden. This avoids the delay where copied items only appeared
        // after the window was reopened and the async reload completed.
        container.historyViewModel.start()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainHotkeyChanged),
            name: .mainHotkeyChanged,
            object: nil
        )
        hotkeyManager.register { [weak self] in
            self?.container.coordinator.showMainWindow(focusSearch: true)
        }
        // Per-Macro and per-action hotkeys are window-scoped: registered when the history window is shown,
        // and unregistered when it is hidden ( design: only effective while ClipboardManager's history UI is visible ).
        startObservingMacroScriptsChanges()
        startObservingActionHotkeysChanges()
        menuBarController.onShow = { [weak self] in self?.container.coordinator.showMainWindow(focusSearch: false) }
        menuBarController.onSearch = { [weak self] in self?.container.coordinator.showMainWindow(focusSearch: true) }
        menuBarController.onSettings = { [weak self] in self?.container.coordinator.showSettings() }
        menuBarController.onClearHistory = { [weak self] in self?.confirmClearHistory() }
        menuBarController.onQuit = { NSApp.terminate(nil) }
        menuBarController.install()

        // Requests notification-center authorization so the user can be notified on Macro failure (remaining-features #6).
        AppNotifier.requestAuthorizationIfNeeded()

        // Prevents the Dock icon from lingering when only the settings window was opened and closed (review #5).
        // Detects closure of any NSWindow other than the main window, and returns the app to .accessory if no other visible windows remain.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(anyWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        PreviewImageEditor.shared.cleanupOrphanedEditFiles()
        // Periodically sweep orphaned working files so crashed-session files do not sit in
        // Downloads between launches (review #7).
        PreviewImageEditor.shared.startOrphanCleanupTimer()

        // Design-app.md §3: menu bar resident app. At launch we stay in the menu bar only,
        // matching Maccy/Paste behavior. The main window is shown later via the global hotkey,
        // menu bar item, or selection-from-menu. Do NOT steal focus from the user's current app
        // at launch (review #8).

        // E2E smoke tests: when launched with the environment variable
        // CM_E2E_OPEN_WINDOW=1, force the history / action hotkey settings to
        // known default values (so each test starts from a clean state — the
        // sandboxed UI test runner cannot reach the host app's defaults
        // domain via `defaults write`), prompt for Accessibility permission
        // so the XCUITest harness can introspect the app, and open the main +
        // Settings windows immediately so the test can drive them via
        // XCUIElement.
        //
        // Guarded by BOTH the E2E bundle identifier AND the launch environment
        // variable (review #4). The previous `#if DEBUG` guard made Release
        // builds of the E2E host unusable even though `Scripts/run-e2e-tests.sh`
        // advertises `XCODE_CONFIG=Release`; gating on the bundle id keeps the
        // production app (which has a different bundle id) safe even if the
        // environment variable is ever set by mistake, while letting the E2E
        // host exercise the test launch path in any configuration.
        if ProcessInfo.processInfo.environment["CM_E2E_OPEN_WINDOW"] == "1",
           Bundle.main.bundleIdentifier == "com.xshoji.ClipboardManager.E2E" {
            forceE2EDefaultSettings()
            // Ask the system to prompt for Accessibility permission so the
            // XCUITest harness can introspect the app; no-op when the
            // permission is already granted. Uses the raw key literal to stay
            // Sendable on Swift 6.
            let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            container.coordinator.showMainWindow(focusSearch: false)
            container.coordinator.showSettings()
        }
    }

    /// Resets all action hotkeys and the history limit settings to their
    /// built-in defaults. Only invoked when the app is launched with
    /// `CM_E2E_OPEN_WINDOW=1` (E2E smoke test mode).
    ///
    /// Defaults are sourced from `AppSettings`'s single source of truth so
    /// the E2E harness and the production Reset buttons cannot drift.
    private func forceE2EDefaultSettings() {
        settings.hotkeyKeyCode = AppSettings.defaultHotkeyKeyCode
        settings.hotkeyModifiers = AppSettings.testHotkeyModifiers
        settings.editHotkeyCode = AppSettings.defaultEditHotkeyCode
        settings.editHotkeyModifiers = AppSettings.defaultActionHotkeyModifiers
        settings.pastePlainHotkeyCode = AppSettings.defaultPastePlainHotkeyCode
        settings.pastePlainHotkeyModifiers = AppSettings.defaultActionHotkeyModifiers
        settings.macroPickerHotkeyCode = AppSettings.defaultMacroPickerHotkeyCode
        settings.macroPickerHotkeyModifiers = AppSettings.defaultActionHotkeyModifiers
        settings.retentionDays = 30
        settings.maxHistoryCount = 1000
        settings.maxItemSizeMB = 10
        // Reset macro scripts to a clean state so the E2E tests do not depend
        // on macro scripts persisted by a prior production run in the same
        // UserDefaults domain ("ClipboardManager"). Without this, the host
        // app would inherit the user's existing macros and tests that count
        // rows / drive the Add button would be order-dependent on the host
        // machine's defaults. This mirrors how each other test assertion above
        // starts from the baked-in defaults instead of dumped-in state.
        settings.macroScripts = []
        NotificationCenter.default.post(name: .actionHotkeysChanged, object: nil)
        NotificationCenter.default.post(name: .mainHotkeyChanged, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // An accessory (menu-bar) app should not terminate when the last window closes.
        // Also do not terminate when the main window is hidden via NSApp.hide(nil).
        return false
    }

    /// Ordered resource cleanup at termination. Without this, Carbon event handlers,
    /// DispatchSource timers, DispatchSourceFileSystemObject file watchers, AX observers,
    /// and NSWorkspace notification observers would all leak until process exit and could
    /// fire during the tear-down window. Order:
    /// 1. Stop clipboard polling (no new saves while we are shutting down).
    /// 2. Tear down all Preview edit sessions (AX observers, file watchers, terminate observers).
    /// 3. Unregister all Carbon hotkeys and the keyboard event handler.
    /// 4. Stop observing app activation (NSWorkspace observer).
    /// 5. Flush any pending ModelContext changes to disk (logged, not user-notified).
    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        PreviewImageEditor.shared.teardownAllSessions()
        hotkeyManager.unregister()
        AppActivator.shared.stopObservingActivatedApplications()
        container.repository.flushOnTerminate()
    }

    @objc private func mainHotkeyChanged() {
        let succeeded = hotkeyManager.reinstall()
        NotificationCenter.default.post(
            name: .mainHotkeyRegistrationResult,
            object: nil,
            userInfo: ["succeeded": succeeded]
        )
    }

    /// Called when an NSWindow other than the main window (e.g., settings window) closes.
    /// Returns the app to `.accessory` if no other visible windows remain, so the Dock icon does not linger (review #5).
    @objc private func anyWindowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        if window === mainWindowController?.window { return }
        let hasOtherVisible = NSApp.windows.contains { other in
            other !== window
                && other !== mainWindowController?.window
                && other.isVisible
                && !other.isMiniaturized
        }
        if hasOtherVisible { return }
        if mainWindowController?.window?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Window-scoped hotkeys ( design: per-Macro + per-action shortcuts are effective only while the history window is visible )

    func installWindowScopedHotkeys() {
        installMacroHotkeys()
        installActionHotkeys()
    }

    func uninstallWindowScopedHotkeys() {
        hotkeyManager.unregisterAllMacroHotkeys()
        hotkeyManager.unregisterAllActionHotkeys()
    }

    private func installMacroHotkeys() {
        hotkeyManager.unregisterAllMacroHotkeys()
        for macro in settings.macroScripts {
            // macOS physical key code 0 corresponds to the A key, so it cannot be used to mean "unset".
            guard macro.hotkeyModifiers != 0 else { continue }
            let id = Self.stableMacroID(for: macro.id)
            let ok = hotkeyManager.registerMacroHotkey(
                macroID: id,
                keyCode: macro.hotkeyCode,
                modifiers: macro.hotkeyModifiers
            ) { [weak self] in
                self?.runMacroFromHotkey(macroID: id, original: macro)
            }
            if !ok {
                Self.logger.error("Macro hotkey registration failed for \(macro.name, privacy: .public)")
            }
        }
    }

    private func installActionHotkeys() {
        hotkeyManager.unregisterAllActionHotkeys()
        var anyFailed = false

        if settings.editHotkeyModifiers != 0 {
            let ok = hotkeyManager.registerActionHotkey(
                actionID: ActionHotkeyID.edit,
                keyCode: settings.editHotkeyCode,
                modifiers: settings.editHotkeyModifiers
            ) { [weak self] in
                self?.runEditAction()
            }
            if !ok {
                Self.logger.error("Edit action hotkey registration failed")
                anyFailed = true
            }
        }

        if settings.pastePlainHotkeyModifiers != 0 {
            let ok = hotkeyManager.registerActionHotkey(
                actionID: ActionHotkeyID.pastePlain,
                keyCode: settings.pastePlainHotkeyCode,
                modifiers: settings.pastePlainHotkeyModifiers
            ) { [weak self] in
                self?.runPastePlainAction()
            }
            if !ok {
                Self.logger.error("Paste Plain action hotkey registration failed")
                anyFailed = true
            }
        }
       if settings.macroPickerHotkeyModifiers != 0 {
           let ok = hotkeyManager.registerActionHotkey(
               actionID: ActionHotkeyID.macroPicker,
               keyCode: settings.macroPickerHotkeyCode,
               modifiers: settings.macroPickerHotkeyModifiers
           ) { [weak self] in
               self?.runMacroPickerAction()
           }
           if !ok {
               Self.logger.error("Macro Picker action hotkey registration failed")
               anyFailed = true
           }
       }

        // Surface Carbon registration failures (e.g., Edit and Paste Plain sharing the
        // same shortcut) to the user via the existing hotkey-unavailable alert so the
        // duplicate is not silently swallowed (review #16).
        if anyFailed {
            NotificationCenter.default.post(
                name: .mainHotkeyRegistrationResult,
                object: nil,
                userInfo: ["succeeded": false]
            )
        }
    }

    /// If no history item is selected, only beeps and does nothing.
    private func runMacroFromHotkey(macroID: UInt32, original: MacroScript) {
        // Refetch the latest Macro after settings changes (the captured `original` may be a stale snapshot).
        guard let macro = settings.macroScripts.first(where: { Self.stableMacroID(for: $0.id) == macroID }) else { return }
        guard let item = container.historyViewModel.selectedItem else {
            NSSound.beep()
            return
        }
        // PasteCoordinator handles both success and failure fallback.
        // MacroRunner runs on a background queue, so wrap it in a Task (review #4).
        let macroRef = macro
        let itemRef = item
        Task { @MainActor in
            _ = await self.container.historyViewModel.runMacro(macro: macroRef, item: itemRef)
        }
    }

    /// Fires the Edit action on the currently selected entity ( image → Preview.app, text → TextEditView sheet ).
    /// Issues a system beep if nothing is selected, mirroring `runMacroFromHotkey`.
    /// Action hotkeys are global Carbon registrations; silently ignore when the history
    /// window is not the key window so they only fire while ClipboardManager is focused.
    private func runEditAction() {
        guard mainWindowController?.window?.isKeyWindow == true else { return }
        guard let item = container.historyViewModel.selectedItem else {
            NSSound.beep()
            return
        }
        NotificationCenter.default.post(name: .editActionTriggered, object: item)
    }

    /// Fires the Paste Plain action on the currently selected entity ( writes plain-text only to pasteboard and returns to previous app ).
    /// Issues a system beep if nothing is selected, mirroring `runMacroFromHotkey`.
    /// Action hotkeys are global Carbon registrations; silently ignore when the history
    /// window is not the key window so they only fire while ClipboardManager is focused.
    private func runPastePlainAction() {
        guard mainWindowController?.window?.isKeyWindow == true else { return }
        guard let item = container.historyViewModel.selectedItem else {
            NSSound.beep()
            return
        }
        // Image entries go through the OCR → paste flow so the user gets the
        // recognized text instead of an image on the pasteboard. Mirrors
        // `FooterBar.paste(rich: false)` for the image case.
        if item.isImage {
            Task { @MainActor in
                await self.container.historyViewModel.runOcr(item: item)
            }
            return
        }
        // Register a suppression range BEFORE the write so the utility-queue poll cannot
        // race with the pasteboard write and save our own write as a history item (review #6).
        Task { @MainActor in
            await self.container.historyViewModel.pasteStandard(item: item, rich: false)
        }
    }

    /// Fires the Macro Picker overlay on the currently selected entity.
    /// The overlay lists all registered Macros and lets the user pick one with the
    /// keyboard; Enter runs it against the selected history entry (design: Cmd+M flow).
    /// Issues a system beep if nothing is selected, mirroring `runMacroFromHotkey`.
    ///  Action hotkeys are global Carbon registrations; silently ignore when the history
    /// window is not the key window so they only fire while ClipboardManager is focused.
    private func runMacroPickerAction() {
        guard mainWindowController?.window?.isKeyWindow == true else { return }
        guard container.historyViewModel.selectedItem != nil else {
            NSSound.beep()
            return
        }
       NotificationCenter.default.post(name: .macroPickerTriggered, object: nil)
   }

    private func startObservingMacroScriptsChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(macroScriptsDidChange),
            name: .macroScriptsChanged,
            object: nil
        )
    }

    @objc private func macroScriptsDidChange() {
        // Re-register only if the window is currently visible; otherwise the next `showMainWindow` will install them.
        guard mainWindowController?.window?.isVisible == true else { return }
        installMacroHotkeys()
    }

    private func startObservingActionHotkeysChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(actionHotkeysDidChange),
            name: .actionHotkeysChanged,
            object: nil
        )
    }

    @objc private func actionHotkeysDidChange() {
        guard mainWindowController?.window?.isVisible == true else { return }
        installActionHotkeys()
    }

    /// Converts a `MacroScript.id` (UUID) into a stable UInt32 for Carbon.
    /// Uses the upper 32 bits of the UUID, expected to be unique within the same process.
    static func stableMacroID(for uuid: UUID) -> UInt32 {
        let bytes = uuid.uuid
        return (UInt32(bytes.0) << 24) | (UInt32(bytes.1) << 16) | (UInt32(bytes.2) << 8) | UInt32(bytes.3)
    }

    func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "This action cannot be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            container.repository.clearAll()
        }
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    var settings: AppSettings
    weak var lifecycle: MainWindowLifecycle?
    /// Last window frame the user explicitly positioned (via drag). `nil` until the user moves the window.
    /// Used by `AppDelegate.showMainWindow` to decide whether to reposition near the cursor on re-show.
    private(set) var lastUserFrame: NSRect?
    private var didMoveInitialized = false

    init(window: NSWindow, settings: AppSettings) {
        self.settings = settings
        super.init(window: window)
        window.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(alwaysOnTopChanged),
            name: .alwaysOnTopChanged,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func alwaysOnTopChanged() {
        applyLevel()
    }

    func applyLevel() {
        window?.level = settings.isAlwaysOnTop ? .floating : .normal
    }

    // MARK: - Close on blur (design-ui.md §1: "disappears on blur or Esc")

    func windowDidResignKey(_ notification: Notification) {
        // Close the history panel when it loses key state (e.g., user clicks another app),
        // matching the "peep and dismiss" UX of standard clipboard managers (design-ui.md §1: "disappears on blur or Esc").
        // When the user has pinned the panel (always-on-top), keep it visible even without focus
        // so they can refer to it while working in other apps.
        // Action / Macro hotkeys are Carbon system-wide registrations: releasing the key
        // window means ClipboardManager is no longer frontmost, so unregister them here
        // so the user's own Cmd+E ( etc. ) works in other apps. They will be reinstalled
        // on the next showMainWindow.

        // Skip auto-close AND hotkey uninstall while an image edit session in Preview.app
        // is active. The user edits in another process; auto-closing the history window
        // or unregistering window-scoped hotkeys here would prevent them from confirming
        // that the saved image was appended and from using Cmd+E / other action hotkeys
        // immediately after Preview's window closes. The session is considered active
        // until Preview's window closes / it quits (PreviewImageEditor sets didFinish
        // and tears the session down).
        if PreviewImageEditor.shared.hasActiveSession {
            return
        }

        // Skip hotkey uninstall and auto-close when another window owned by this app
        // (e.g., Settings window, text-edit sheet) is still visible. Without this,
        // opening a text-edit sheet unregisters Cmd+E, and after closing the sheet
        // the hotkey is never re-registered, so Cmd+E stops working (beep only).
        let closingWindow = notification.object as? NSWindow
        let hasVisibleOwnedNonPanel = NSApp.windows.contains { other in
            other !== closingWindow
                && other.isVisible
                && !(other is NSPanel)
                && other.canBecomeKey
        }
        // Sheets presented on the history panel itself are NSPanels; treat any other visible NSPanel
        // owned by this app (e.g., edit sheet) as "do not uninstall / do not auto-close" too.
        let hasVisibleOwnedPanel = NSApp.windows.contains { other in
            other !== closingWindow
                && other.isVisible
                && (other is NSPanel)
                && other.canBecomeKey
        }
        if hasVisibleOwnedNonPanel || hasVisibleOwnedPanel {
            return
        }

        lifecycle?.mainWindowUninstallHotkeys()
        if settings.isAlwaysOnTop {
            return
        }
        // Use `close()` (not `orderOut`) so that `windowWillClose` fires and the same
        // teardown as the Esc path runs: `.historyWindowDidClose` is posted (so
        // `HistoryListPane` resets `listFocused = true` for the next reopen), window-
        // scoped hotkeys are uninstalled, and the activation policy returns to
        // `.accessory`. Without this, hiding via blur after the Macro Picker (Cmd+M)
        // stole focus left `listFocused = false`, so reopening showed no focused view
        // and arrow keys produced the system beep.
        closingWindow?.close()
    }

    func windowDidMove(_ notification: Notification) {
        // First move event is the initial positioning done by AppDelegate.showMainWindow;
        // ignore it so cursor-positioning isn't treated as a manual user move.
        if !didMoveInitialized {
            didMoveInitialized = true
            return
        }
        if let window = notification.object as? NSWindow {
            lastUserFrame = window.frame
        }
    }

    func windowWillClose(_ notification: Notification) {
        // If another normal visible window (e.g., settings) is still open, keep the Dock icon (.regular) (review #5).
        lifecycle?.mainWindowUninstallHotkeys()
        lifecycle?.mainWindowDidClose()
        let closingWindow = notification.object as? NSWindow
        let hasOtherVisible = NSApp.windows.contains { other in
            other !== closingWindow
                && other.isVisible
                && !other.isMiniaturized
        }
        if !hasOtherVisible {
            NSApp.setActivationPolicy(.accessory)
        }
        // Window-scoped hotkeys ( per-Macro + per-action ) become inactive when the history window closes ( design ).
        // Closing the window this controller owns is the authoritative "history UI hidden" signal.
        // Notify the history UI to reset its in-window state (search query, selection)
        // so the next appearance starts fresh and the stale search results do not
        // flash on screen while the window is re-shown.
        NotificationCenter.default.post(name: .historyWindowDidClose, object: nil)
    }

    // MARK: - Non-zoomable (design-ui.md §1)

    @objc func zoom(_ sender: Any?) {
        // Suppress zoom (green button) entirely. The standard zoom button is also hidden in
        // AppDelegate.showMainWindow; this is a defense-in-depth guard if invoked via Cmd+Ctrl+F
        // or accessibility actions.
    }
}

@MainActor
final class SettingsWindow: NSWindow {
    /// Esc closes the Settings window. The default NSWindow `cancelOperation`
    /// beeps when no responder handles it; overriding here suppresses the beep
    /// and routes through `performClose` so `windowShouldClose` (and its
    /// unsaved-Macro guard) still runs.
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: SettingsViewModel
    /// Observer for `.macroSaveSettleComplete` while a "Save all unsaved Macros"
    /// flow is in progress. Registered on Save and removed either when the
    /// settle completes or in `windowWillClose`. Stored on the main actor (no
    /// `nonisolated(unsafe)`) so `deinit` does not race with handler threads.
    private var saveSettleObserver: NSObjectProtocol?
    var onWindowWillClose: (() -> Void)?

    init(window: NSWindow?, viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        super.init(window: window)
        window?.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        removeSaveSettleObserver()
        onWindowWillClose?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !viewModel.unsavedMacroIDs.isEmpty else {
            viewModel.shouldCloseAfterSave = false
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Unsaved Macro Changes"
        alert.informativeText = "You have unsaved changes to one or more Macros. Save before closing?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            viewModel.shouldCloseAfterSave = true
            viewModel.startSaveCycle()
            // Observe a single settle-complete event to close the window once
            // every row has either saved or cancelled. Re-registering each
            // time the user picks "Save" avoids a long-lived observer.
            removeSaveSettleObserver()
            saveSettleObserver = NotificationCenter.default.addObserver(
                forName: .macroSaveSettleComplete,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.viewModel.shouldCloseAfterSave else { return }
                    // Final convenience close: every row has settled by this
                    // point, so no 50 ms polling is needed.
                    self.viewModel.shouldCloseAfterSave = false
                    self.removeSaveSettleObserver()
                    self.close()
                }
            }
            NotificationCenter.default.post(name: .saveAllUnsavedMacros, object: nil)
            return false
        case .alertSecondButtonReturn:
            viewModel.unsavedMacroIDs.removeAll()
            viewModel.shouldCloseAfterSave = false
            return true
        default:
            return false
        }
    }

    private func removeSaveSettleObserver() {
        if let token = saveSettleObserver {
            NotificationCenter.default.removeObserver(token)
            saveSettleObserver = nil
        }
    }
}

extension Notification.Name {
    static let focusSearchField = Notification.Name("focusSearchField")
    static let alwaysOnTopChanged = Notification.Name("alwaysOnTopChanged")
    static let retentionChanged = Notification.Name("retentionChanged")
    static let maxCountChanged = Notification.Name("maxCountChanged")
    static let pollingIntervalChanged = Notification.Name("pollingIntervalChanged")
    static let mainHotkeyChanged = Notification.Name("mainHotkeyChanged")
    static let mainHotkeyRegistrationResult = Notification.Name("mainHotkeyRegistrationResult")
    static let macroScriptsChanged = Notification.Name("macroScriptsChanged")
    static let actionHotkeysChanged = Notification.Name("actionHotkeysChanged")
    static let resetSelectionToTop = Notification.Name("resetSelectionToTop")
    /// Posted by `MainWindowController.windowWillClose` when the history window is
    /// closed. Observed by `MainView` to reset the in-window state (search query
    /// cleared, selection moved back to the latest entry) so the next time the
    /// window is shown the user starts from a fresh list — without flashing the
    /// previous search results on screen. Closing (not reopening) is the right
    /// timing because the state is gone by the time the window reappears.
    static let historyWindowDidClose = Notification.Name("historyWindowDidClose")
    /// Posted when the Edit action hotkey fires. Object is the selected history item.
    /// `MainView` observes this and opens the TextEditView sheet ( so preview-image editing also works via the existing `FooterBar.editSelected` path ).
    static let editActionTriggered = Notification.Name("editActionTriggered")
    /// Posted when the user requests deletion of the selected entry (e.g., FooterBar's More > Delete).
    /// `HistoryListPane` performs the actual deletion so the post-delete selection logic
    /// (move to the adjacent entry) stays in one place.
    static let deleteSelectedRequested = Notification.Name("deleteSelectedRequested")
   /// Posted by AppDelegate when the Macro Picker action hotkey ( default Cmd+M ) fires.
   /// `MainView` observes this and shows the `MacroPickerView` overlay so the user can
   /// pick a Macro with the keyboard and run it against the currently selected entity.
   static let macroPickerTriggered = Notification.Name("macroPickerTriggered")
    /// Posted by `SettingsWindowController` when the user chooses "Save" on an
    /// unsaved-changes alert so each `MacroScriptRowView` can persist its edits.
    static let saveAllUnsavedMacros = Notification.Name("saveAllUnsavedMacros")
    /// Posted once every expected Macro row has settled its save
    /// flow (saved or cancelled) after a `.saveAllUnsavedMacros` broadcast.
    /// Observed by `SettingsWindowController` to close the window only after
    /// every row has reported its outcome, instead of polling on a timer.
    static let macroSaveSettleComplete = Notification.Name("macroSaveSettleComplete")
    /// Posted by `PasteCoordinator` when an OCR-driven Paste Plain starts/ends so
    /// `FooterBar` can show/hide its progress indicator. `userInfo["inProgress"]` is Bool.
    static let ocrProgressDidChange = Notification.Name("ocrProgressDidChange")
}
