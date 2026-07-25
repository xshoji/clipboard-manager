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
        windowController?.applyLevel()
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        onInstallHotkeys()
        if focusSearch { NotificationCenter.default.post(name: .focusSearchField, object: nil) }
        NotificationCenter.default.post(name: .resetSelectionToTop, object: nil)
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
        let content = MainView(focusSearch: focusSearch, viewModel: viewModel,
            onClearHistory: { [weak self] in self?.confirmClearHistory() },
            onShowSettings: { [weak self] in self?.onShowSettings() }).environment(settings)
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
    func mainWindowDidClose() { viewModel.stop() }
    func confirmClearHistory() { onClearHistory() }
}
