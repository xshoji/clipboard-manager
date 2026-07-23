import AppKit
import SwiftUI
import SwiftData
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.xshoji.ClipboardManager", category: "AppDelegate")

    let settings: AppSettings
    let persistence: PersistenceController
    let monitor: ClipboardMonitor
    let hotkeyManager: HotkeyManager
    let menuBarController: MenuBarController
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: NSWindowController?
    private var macroScriptsObserver: NSObjectProtocol?
    private var actionHotkeysObserver: NSObjectProtocol?

    /// Window-scoped action hotkey IDs ( design: edit / paste plain / etc., effective only while the history window is visible ).
    /// Stable UInt32 ids passed straight to `RegisterEventHotKey`. Must not collide with `mainRegistryID` ( 0xABCD_0001 ) or macro eventIDs ( 0xABCD_1000+ ).
    enum ActionHotkeyID {
        static let edit: UInt32 = 0xABCD_0002
        static let pastePlain: UInt32 = 0xABCD_0003
       static let macroPicker: UInt32 = 0xABCD_0004
    }

    override init() {
        self.settings = AppSettings.shared
        self.persistence = PersistenceController(settings: settings)
        self.monitor = ClipboardMonitor(
            persistence: persistence,
            settings: settings
        )
        self.hotkeyManager = HotkeyManager(settings: settings)
        self.menuBarController = MenuBarController(settings: settings)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        AppActivator.shared.startObservingActivatedApplications()
        PersistenceController.shared = persistence
        ClipboardMonitor.shared = monitor
        persistence.startObservingSettings()
        monitor.start()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainHotkeyChanged),
            name: .mainHotkeyChanged,
            object: nil
        )
        hotkeyManager.register { [weak self] in
            self?.showMainWindow(focusSearch: true)
        }
        // Per-Macro and per-action hotkeys are window-scoped: registered when the history window is shown,
        // and unregistered when it is hidden ( design: only effective while ClipboardManager's history UI is visible ).
        startObservingMacroScriptsChanges()
        startObservingActionHotkeysChanges()
        menuBarController.onShow = { [weak self] in self?.showMainWindow() }
        menuBarController.onSearch = { [weak self] in self?.showMainWindow(focusSearch: true) }
        menuBarController.onSettings = { [weak self] in self?.showSettings() }
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
        persistence.flushOnTerminate()
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

    /// If no ClipboardEntity is selected, only beeps and does nothing (requirement: behavior when nothing is selected).
    private func runMacroFromHotkey(macroID: UInt32, original: MacroScript) {
        // Refetch the latest Macro after settings changes (the captured `original` may be a stale snapshot).
        guard let macro = settings.macroScripts.first(where: { Self.stableMacroID(for: $0.id) == macroID }) else { return }
        guard let entityID = AppState.shared.selectedEntityID,
              let entity = fetchEntity(id: entityID) else {
            NSSound.beep()
            return
        }
        // remaining-features #6: MacroPasteService handles both success (pasteboard write / return to previous app) and failure fallback.
        // MacroRunner runs on a background queue, so wrap it in a Task (review #4).
        let macroRef = macro
        let entityRef = entity
        Task { @MainActor in
            _ = await MacroPasteService.run(macro: macroRef, entity: entityRef, settings: self.settings)
        }
    }

    private func fetchEntity(id: UUID) -> ClipboardEntity? {
        let ctx = persistence.container.mainContext
        let fd = FetchDescriptor<ClipboardEntity>(
            predicate: #Predicate<ClipboardEntity> { $0.id == id }
        )
        return persistence.fetchEntities(fd, context: ctx, purpose: "fetchEntity")?.first
    }

    /// Fires the Edit action on the currently selected entity ( image → Preview.app, text → TextEditView sheet ).
    /// Issues a system beep if nothing is selected, mirroring `runMacroFromHotkey`.
    /// Action hotkeys are global Carbon registrations; silently ignore when the history
    /// window is not the key window so they only fire while ClipboardManager is focused.
    private func runEditAction() {
        guard mainWindowController?.window?.isKeyWindow == true else { return }
        guard let entityID = AppState.shared.selectedEntityID,
              let entity = fetchEntity(id: entityID) else {
            NSSound.beep()
            return
        }
        NotificationCenter.default.post(name: .editActionTriggered, object: entity)
    }

    /// Fires the Paste Plain action on the currently selected entity ( writes plain-text only to pasteboard and returns to previous app ).
    /// Issues a system beep if nothing is selected, mirroring `runMacroFromHotkey`.
    /// Action hotkeys are global Carbon registrations; silently ignore when the history
    /// window is not the key window so they only fire while ClipboardManager is focused.
    private func runPastePlainAction() {
        guard mainWindowController?.window?.isKeyWindow == true else { return }
        guard let entityID = AppState.shared.selectedEntityID,
              let entity = fetchEntity(id: entityID) else {
            NSSound.beep()
            return
        }
        // Image entries go through the OCR → paste flow so the user gets the
        // recognized text instead of an image on the pasteboard. Mirrors
        // `FooterBar.paste(rich: false)` for the image case.
        if entity.isImage {
            Task { @MainActor in
                await OcrPasteService.run(entity: entity, settings: self.settings)
            }
            return
        }
        // Register a suppression range BEFORE the write so the utility-queue poll cannot
        // race with the pasteboard write and save our own write as a history item (review #6).
        let pre = NSPasteboard.general.changeCount
        ClipboardMonitor.shared?.suppressChangeCountRange((pre + 1)..<(pre + 3))
        entity.writeToPasteboard(.general, rich: false)
        ClipboardMonitor.shared?.finalizeSuppressionAfterWrite(preChangeCount: pre)
        AppActivator.shared.activatePreviousAppAndPasteSynthetically(
            needsSynthetic: settings.needsAccessibilityForSyntheticPaste
        )
    }

    /// Fires the Macro Picker overlay on the currently selected entity.
    /// The overlay lists all registered Macros and lets the user pick one with the
    /// keyboard; Enter runs it against the selected history entry (design: Cmd+M flow).
    /// Issues a system beep if nothing is selected, mirroring `runMacroFromHotkey`.
    ///  Action hotkeys are global Carbon registrations; silently ignore when the history
    /// window is not the key window so they only fire while ClipboardManager is focused.
    private func runMacroPickerAction() {
        guard mainWindowController?.window?.isKeyWindow == true else { return }
        guard AppState.shared.selectedEntityID != nil else {
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

    func showMainWindow(focusSearch: Bool = false) {
        // Including first launch, record the app that was frontmost right before ClipboardManager becomes active,
        // so it can later be used as the paste target.
        AppActivator.shared.recordBeforeShowingMainWindow()
        if mainWindowController == nil {
            let ctx = persistence.container.mainContext
            // Utility-style panel (design-ui.md §1): non-fullscreen, non-zoomable, borderless-ish title bar,
            // closes on blur. Using NSPanel (without .nonactivatingPanel) keeps key-window behavior and
            // still receives windowDidResignKey when the user clicks elsewhere.
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isMovableByWindowBackground = true
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            // Non-zoomable: hide the zoom (green) button and disable the zoom action (design-ui.md §1).
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.level = settings.isAlwaysOnTop ? .floating : .normal
            // Place the window according to the user's `windowPositionMode` setting
            // (design-ui.md §1: near the cursor or at a fixed location by setting).
            positionWindow(panel)
            let contentView = MainView(
                focusSearch: focusSearch,
                onClearHistory: { [weak self] in self?.confirmClearHistory() },
                onShowSettings: { [weak self] in self?.showSettings() }
            )
                .environment(settings)
                .modelContext(ctx)
            panel.contentView = NSHostingView(rootView: contentView)
            let controller = MainWindowController(window: panel, settings: settings)
            controller.persistence = persistence
            controller.appDelegate = self
            mainWindowController = controller
        } else {
            // When re-showing, reposition the window only if the user has not moved it
            // manually since the last hide. We detect manual move by comparing the
            // current frame against the last notified frame captured in windowDidMove.
            // Applies to both `center` and `nearCursor` modes (design-ui.md §1).
            if let panel = mainWindowController?.window as? NSPanel {
                let staysAtLastUserOrigin = (mainWindowController?.lastUserFrame?.origin == panel.frame.origin)
                if staysAtLastUserOrigin || mainWindowController?.lastUserFrame == nil {
                    positionWindow(panel)
                }
            }
        }
        mainWindowController?.applyLevel()
        NSApp.activate(ignoringOtherApps: true)
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        // Window-scoped hotkeys ( per-Macro + per-action ) are active only while the history window is visible ( design ).
        installWindowScopedHotkeys()
        if focusSearch {
            NotificationCenter.default.post(name: .focusSearchField, object: nil)
        }
        NotificationCenter.default.post(name: .resetSelectionToTop, object: nil)
    }

    /// Positions the given window according to `settings.windowPositionMode`.
    /// - `"center"`: center of the screen containing the cursor.
    /// - `"nearCursor"`: near the current mouse location (design-ui.md §1).
    /// Falls back to centering when the mode is unknown.
    private func positionWindow(_ window: NSWindow) {
        if settings.windowPositionMode == "nearCursor" {
            positionWindowNearCursor(window)
        } else {
            positionWindowAtCenter(window)
        }
    }

    private func positionWindowAtCenter(_ window: NSWindow) {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(cursor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 640)
        let size = window.frame.size
        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrameOrigin(origin)
    }

    /// Positions the given window near the current mouse location, keeping it fully on the nearest screen.
    /// Used by `showMainWindow` to satisfy design-ui.md §1 ("Window appears near the cursor").
    private func positionWindowNearCursor(_ window: NSWindow) {
        let cursor = NSEvent.mouseLocation
        let size = window.frame.size
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(cursor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 640)

        var origin = CGPoint(
            x: cursor.x - size.width / 2,
            y: cursor.y - size.height / 2
        )
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        window.setFrameOrigin(origin)
    }

    func showSettings() {
        // Stay `.accessory` so the Dock icon does not appear while the Settings
        // (or Macro Edit) window is open. The Settings window is raised to
        // `.floating+1` below so it stays above the always-on-top history panel.
        NSApp.activate(ignoringOtherApps: true)

        if settingsWindowController == nil {
            let contentView = SettingsView()
                .environment(settings)
                .modelContext(persistence.container.mainContext)
            let window = SettingsWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "ClipboardManager Settings"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentViewController = NSHostingController(rootView: contentView)
            window.level = .floating+1
            let controller = SettingsWindowController(window: window)
            controller.onWindowWillClose = { [weak self] in
                self?.settingsWindowController = nil
            }
            settingsWindowController = controller
        }

        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "This action cannot be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            persistence.clearAll()
        }
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    var settings: AppSettings
    var persistence: PersistenceController?
    /// Weak reference to AppDelegate so NSApp.delegate ( which SwiftUI replaces ) is not needed.
    weak var appDelegate: AppDelegate?
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

        appDelegate?.uninstallWindowScopedHotkeys()
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
        appDelegate?.uninstallWindowScopedHotkeys()
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
    /// Observer for `.macroSaveSettleComplete` while a "Save all unsaved Macros"
    /// flow is in progress. Registered on Save and removed either when the
    /// settle completes or in `windowWillClose`. Stored on the main actor (no
    /// `nonisolated(unsafe)`) so `deinit` does not race with handler threads.
    private var saveSettleObserver: NSObjectProtocol?
    var onWindowWillClose: (() -> Void)?

    override init(window: NSWindow?) {
        super.init(window: window)
        window?.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        removeSaveSettleObserver()
        onWindowWillClose?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !AppState.shared.unsavedMacroIDs.isEmpty else {
            AppState.shared.settingsWindowShouldCloseAfterSave = false
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
            AppState.shared.settingsWindowShouldCloseAfterSave = true
            let pending = AppState.shared.unsavedMacroIDs.count
            AppState.shared.startMacroSaveCycle(expected: pending)
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
                    guard AppState.shared.settingsWindowShouldCloseAfterSave else { return }
                    // Final convenience close: every row has settled by this
                    // point, so no 50 ms polling is needed.
                    AppState.shared.settingsWindowShouldCloseAfterSave = false
                    self?.removeSaveSettleObserver()
                    self?.close()
                }
            }
            NotificationCenter.default.post(name: .saveAllUnsavedMacros, object: nil)
            return false
        case .alertSecondButtonReturn:
            AppState.shared.unsavedMacroIDs.removeAll()
            AppState.shared.settingsWindowShouldCloseAfterSave = false
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
    static let sidebarVisibilityChanged = Notification.Name("sidebarVisibilityChanged")
    static let splitViewChanged = Notification.Name("splitViewChanged")
    static let retentionChanged = Notification.Name("retentionChanged")
    static let maxCountChanged = Notification.Name("maxCountChanged")
    static let dedupCacheSizeChanged = Notification.Name("dedupCacheSizeChanged")
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
    /// Posted by AppDelegate when the Edit action hotkey fires. Object is the selected `ClipboardEntity`.
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
    /// Posted by `AppState` once every expected Macro row has settled its save
    /// flow (saved or cancelled) after a `.saveAllUnsavedMacros` broadcast.
    /// Observed by `SettingsWindowController` to close the window only after
    /// every row has reported its outcome, instead of polling on a timer.
    static let macroSaveSettleComplete = Notification.Name("macroSaveSettleComplete")
    /// Posted by `OcrPasteService` when an OCR-driven Paste Plain starts/ends so
    /// `FooterBar` can show/hide its progress indicator. `userInfo["inProgress"]` is Bool.
    static let ocrProgressDidChange = Notification.Name("ocrProgressDidChange")
}
