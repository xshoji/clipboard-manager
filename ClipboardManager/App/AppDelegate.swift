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
    /// UserDefaults watcher so per-Hook shortcut changes are applied immediately.
    private var hookScriptsObserver: NSObjectProtocol?
    /// UserDefaults watcher so action-hotkey changes are applied immediately.
    private var actionHotkeysObserver: NSObjectProtocol?

    /// Window-scoped action hotkey IDs ( design: edit / paste plain / etc., effective only while the history window is visible ).
    /// Stable UInt32 ids passed straight to `RegisterEventHotKey`. Must not collide with `mainRegistryID` ( 0xABCD_0001 ) or hook eventIDs ( 0xABCD_1000+ ).
    enum ActionHotkeyID {
        static let edit: UInt32 = 0xABCD_0002
        static let pastePlain: UInt32 = 0xABCD_0003
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
            self?.showMainWindow()
        }
        // Per-Hook and per-action hotkeys are window-scoped: registered when the history window is shown,
        // and unregistered when it is hidden ( design: only effective while ClipboardManager's history UI is visible ).
        startObservingHookScriptsChanges()
        startObservingActionHotkeysChanges()
        menuBarController.onShow = { [weak self] in self?.showMainWindow() }
        menuBarController.onSearch = { [weak self] in self?.showMainWindow(focusSearch: true) }
        menuBarController.onSettings = { [weak self] in self?.showSettings() }
        menuBarController.onClearHistory = { [weak self] in self?.confirmClearHistory() }
        menuBarController.onQuit = { NSApp.terminate(nil) }
        menuBarController.install()

        // Requests notification-center authorization so the user can be notified on Hook failure (remaining-features #6).
        AppNotifier.requestAuthorizationIfNeeded()

        // Prevents the Dock icon from lingering when only the settings window was opened and closed (review #5).
        // Detects closure of any NSWindow other than the main window, and returns the app to .accessory if no other visible windows remain.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(anyWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        // Cleans up leftover image-editing working files from the previous session.
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
        // Main window close is already handled in MainWindowController.windowWillClose.
        if window === mainWindowController?.window { return }
        // If another normal visible window is still present (e.g., main and settings open together), do nothing.
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

    // MARK: - Window-scoped hotkeys ( design: per-Hook + per-action shortcuts are effective only while the history window is visible )

    /// Installs all window-scoped hotkeys: per-Hook shortcuts and per-action shortcuts ( edit / paste plain / etc. ).
    /// Called from `showMainWindow` so they are active only while the history window is on screen.
    func installWindowScopedHotkeys() {
        installHookHotkeys()
        installActionHotkeys()
    }

    /// Uninstalls all window-scoped hotkeys when the history window is hidden.
    func uninstallWindowScopedHotkeys() {
        hotkeyManager.unregisterAllHookHotkeys()
        hotkeyManager.unregisterAllActionHotkeys()
    }

    /// Re-registers all HookScript hotkeys with Carbon.
    /// Skips Hooks whose modifier keys are 0 and unregisters any existing registration.
    private func installHookHotkeys() {
        hotkeyManager.unregisterAllHookHotkeys()
        for hook in settings.hookScripts {
            // macOS physical key code 0 corresponds to the A key, so it cannot be used to mean "unset".
            guard hook.hotkeyModifiers != 0 else { continue }
            let id = Self.stableHookID(for: hook.id)
            let ok = hotkeyManager.registerHookHotkey(
                hookID: id,
                keyCode: hook.hotkeyCode,
                modifiers: hook.hotkeyModifiers
            ) { [weak self] in
                self?.runHookFromHotkey(hookID: id, original: hook)
            }
            if !ok {
                Self.logger.error("Hook hotkey registration failed for \(hook.name, privacy: .public)")
            }
        }
    }

    /// Registers the per-action hotkeys ( edit / paste plain / etc. ) with Carbon.
    /// Skips actions whose modifier keys are 0 ( unset ).
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

    /// Runs the Hook when its shortcut fires.
    /// If no ClipboardEntity is selected, only beeps and does nothing (requirement: behavior when nothing is selected).
    private func runHookFromHotkey(hookID: UInt32, original: HookScript) {
        // Refetch the latest Hook after settings changes (the captured `original` may be a stale snapshot).
        guard let hook = settings.hookScripts.first(where: { Self.stableHookID(for: $0.id) == hookID }) else { return }
        guard let entityID = AppState.shared.selectedEntityID,
              let entity = fetchEntity(id: entityID) else {
            NSSound.beep()
            return
        }
        // remaining-features #6: HookPasteService handles both success (pasteboard write / return to previous app) and failure fallback.
        // HookRunner runs on a background queue, so wrap it in a Task (review #4).
        let hookRef = hook
        let entityRef = entity
        Task { @MainActor in
            _ = await HookPasteService.run(hook: hookRef, entity: entityRef, settings: self.settings)
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
    /// Issues a system beep if nothing is selected, mirroring `runHookFromHotkey`.
    private func runEditAction() {
        guard let entityID = AppState.shared.selectedEntityID,
              let entity = fetchEntity(id: entityID) else {
            NSSound.beep()
            return
        }
        NotificationCenter.default.post(name: .editActionTriggered, object: entity)
    }

    /// Fires the Paste Plain action on the currently selected entity ( writes plain-text only to pasteboard and returns to previous app ).
    /// Issues a system beep if nothing is selected, mirroring `runHookFromHotkey`.
    private func runPastePlainAction() {
        guard let entityID = AppState.shared.selectedEntityID,
              let entity = fetchEntity(id: entityID) else {
            NSSound.beep()
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

    /// Observes `hookScriptsChanged` notifications and re-registers Hook hotkeys when they change.
    private func startObservingHookScriptsChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hookScriptsDidChange),
            name: .hookScriptsChanged,
            object: nil
        )
    }

    @objc private func hookScriptsDidChange() {
        // Re-register only if the window is currently visible; otherwise the next `showMainWindow` will install them.
        guard mainWindowController?.window?.isVisible == true else { return }
        installHookHotkeys()
    }

    /// Observes `actionHotkeysChanged` notifications and re-registers action hotkeys when they change.
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

    /// Converts a `HookScript.id` (UUID) into a stable UInt32 for Carbon.
    /// Uses the upper 32 bits of the UUID, expected to be unique within the same process.
    static func stableHookID(for uuid: UUID) -> UInt32 {
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
        // Window-scoped hotkeys ( per-Hook + per-action ) are active only while the history window is visible ( design ).
        installWindowScopedHotkeys()
        if focusSearch {
            NotificationCenter.default.post(name: .focusSearchField, object: nil)
        }
        // When the window is shown again (e.g., by hotkey), reset the selection to the top (latest history).
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

    /// Centers the window on the screen that contains the cursor.
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
        // Clamp the window rectangle to stay fully inside the visibleFrame of the screen.
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        window.setFrameOrigin(origin)
    }

    func showSettings() {
        // Stay `.accessory` so the Dock icon does not appear while the Settings
        // (or Hook Edit) window is open. The Settings window is raised to
        // `.floating+1` below so it stays above the always-on-top history panel.
        NSApp.activate(ignoringOtherApps: true)

        if settingsWindowController == nil {
            let contentView = SettingsView()
                .environment(settings)
                .modelContext(persistence.container.mainContext)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "ClipboardManager Settings"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentViewController = NSHostingController(rootView: contentView)
            // The history panel is an always-on-top NSPanel (.floating). Keep the Settings
            // window above it so it isn't hidden when the history list is visible.
            window.level = .floating+1
            settingsWindowController = NSWindowController(window: window)
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
        if settings.isAlwaysOnTop {
            return
        }
        // Skip auto-close while an image edit session in Preview.app is active.
        // The user edits in another process; auto-closing the history window here
        // would prevent them from confirming that the saved image was appended.
        // The session is considered active until Preview's window closes / it quits
        // (PreviewImageEditor sets didFinish and tears the session down).
        if PreviewImageEditor.shared.hasActiveSession {
            return
        }
        // Skip auto-close when another window owned by this app (e.g., Settings window or text-edit sheet) is still
        // visible, so opening Settings… from the header or editing a text entry does not dismiss the history underneath.
        let closingWindow = notification.object as? NSWindow
        let hasVisibleOwnedNonPanel = NSApp.windows.contains { other in
            other !== closingWindow
                && other.isVisible
                && !(other is NSPanel)
                && other.canBecomeKey
        }
        // Sheets presented on the history panel itself are NSPanels; treat any other visible NSPanel
        // owned by this app (e.g., edit sheet) as "do not auto-close" too.
        let hasVisibleOwnedPanel = NSApp.windows.contains { other in
            other !== closingWindow
                && other.isVisible
                && (other is NSPanel)
                && other.canBecomeKey
        }
        if hasVisibleOwnedNonPanel || hasVisibleOwnedPanel {
            return
        }
        closingWindow?.orderOut(nil)
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
        let closingWindow = notification.object as? NSWindow
        let hasOtherVisible = NSApp.windows.contains { other in
            other !== closingWindow
                && other.isVisible
                && !other.isMiniaturized
        }
        if !hasOtherVisible {
            NSApp.setActivationPolicy(.accessory)
        }
        // Window-scoped hotkeys ( per-Hook + per-action ) become inactive when the history window closes ( design ).
        // Closing the window this controller owns is the authoritative "history UI hidden" signal.
        let appDelegate = NSApp.delegate as? AppDelegate
        appDelegate?.uninstallWindowScopedHotkeys()
    }

    // MARK: - Non-zoomable (design-ui.md §1)

    @objc func zoom(_ sender: Any?) {
        // Suppress zoom (green button) entirely. The standard zoom button is also hidden in
        // AppDelegate.showMainWindow; this is a defense-in-depth guard if invoked via Cmd+Ctrl+F
        // or accessibility actions.
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
    static let hookScriptsChanged = Notification.Name("hookScriptsChanged")
    static let actionHotkeysChanged = Notification.Name("actionHotkeysChanged")
    static let resetSelectionToTop = Notification.Name("resetSelectionToTop")
    /// Posted by AppDelegate when the Edit action hotkey fires. Object is the selected `ClipboardEntity`.
    /// `MainView` observes this and opens the TextEditView sheet ( so preview-image editing also works via the existing `FooterBar.editSelected` path ).
    static let editActionTriggered = Notification.Name("editActionTriggered")
    /// Posted when the user requests deletion of the selected entry (e.g., FooterBar's More > Delete).
    /// `HistoryListPane` performs the actual deletion so the post-delete selection logic
    /// (move to the adjacent entry) stays in one place.
    static let deleteSelectedRequested = Notification.Name("deleteSelectedRequested")
}
