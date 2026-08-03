import AppKit
import SwiftUI

@MainActor
protocol MainWindowLifecycle: AnyObject {
    func mainWindowInstallHotkeys()
    func mainWindowUninstallHotkeys()
    func mainWindowDidClose()
    func confirmClearHistory()
}

/// Creates, positions and owns the history window and its visibility lifecycle.
@MainActor
final class MainWindowCoordinator: MainWindowLifecycle {
    let settings: AppSettings
    let viewModel: HistoryViewModel
    private(set) var windowController: MainWindowController?
    var onInstallHotkeys: () -> Void = {}
    var onUninstallHotkeys: () -> Void = {}
    var onClearHistory: () -> Void = {}
    var onShowSettings: () -> Void = {}
    var onEditImage: (ClipboardItem) -> Void = { item in
        PreviewImageEditor.shared.editImage(item: item)
    }
    var onEditCurrentImage: (CurrentClipboardSnapshot) -> Void = { snapshot in
        PreviewImageEditor.shared.editImage(snapshot: snapshot)
    }

    init(settings: AppSettings, viewModel: HistoryViewModel) {
        self.settings = settings
        self.viewModel = viewModel
    }

    func show(focusSearch: Bool) {
        AppActivator.shared.recordBeforeShowingMainWindow()
        if windowController == nil { makeWindow(focusSearch: focusSearch) }
        else if let panel = windowController?.window as? NSPanel {
            let staysAtLastUserOrigin = windowController?.lastUserFrame?.origin == panel.frame.origin
            if staysAtLastUserOrigin || windowController?.lastUserFrame == nil { position(panel) }
        }
        viewModel.start()
        viewModel.select(nil)
        Task {
            await viewModel.refreshAndSelectLatest()
            NotificationCenter.default.post(name: .resetSelectionToTop, object: nil)
        }
        windowController?.applyLevel()
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        onInstallHotkeys()
        if focusSearch { NotificationCenter.default.post(name: .focusSearchField, object: nil) }
    }

    private func makeWindow(focusSearch: Bool) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = settings.isAlwaysOnTop ? .floating : .normal
        position(panel)
        // The following closures keep Infrastructure side effects
        // (`AppActivator`, `PreviewImageEditor`) out of the UI layer. `MainView`
        // and `FooterBar` depend only on these callbacks, mirroring the
        // inward-only dependency direction enforced elsewhere via the
        // `AppActivating` / `ClipboardRepositoryPort` ports (review #4).
        let activatePreviousApp: () -> Void = {
            AppActivator.shared.activatePreviousApp()
        }
        let content = MainView(focusSearch: focusSearch, viewModel: viewModel,
            onClearHistory: { [weak self] in self?.confirmClearHistory() },
            onShowSettings: { [weak self] in self?.onShowSettings() },
            onActivatePreviousApp: activatePreviousApp,
            onEditImage: onEditImage,
            onEditCurrentImage: onEditCurrentImage).environment(settings)
        panel.contentView = NSHostingView(rootView: content)
        let controller = MainWindowController(window: panel, settings: settings)
        controller.lifecycle = self
        windowController = controller
    }

    private func position(_ window: NSWindow) {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(cursor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 640)
        let size = window.frame.size
        var origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        if settings.windowPositionMode == "nearCursor" {
            origin = CGPoint(x: cursor.x - size.width / 2, y: cursor.y - size.height / 2)
            origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        }
        window.setFrameOrigin(origin)
    }

    func mainWindowInstallHotkeys() { onInstallHotkeys() }
    func mainWindowUninstallHotkeys() { onUninstallHotkeys() }
    func mainWindowDidClose() {
        // Keep the view model's change observer active so clipboard history is
        // updated in the background even while the window is hidden. Stopping the
        // observer here caused copied items to only appear (with a visible delay)
        // when the window was reopened and the async reload completed.
        // viewModel.start() is called once at launch (AppDelegate) and stays active.
    }
    func confirmClearHistory() { onClearHistory() }
}
