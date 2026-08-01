import AppKit
import SwiftUI

/// Creates and owns the settings window independently of application lifecycle.
@MainActor
final class SettingsWindowCoordinator {
    private let settings: AppSettings
    private let viewModel: SettingsViewModel
    private let historyViewModel: HistoryViewModel
    private(set) var windowController: NSWindowController?

    init(settings: AppSettings, viewModel: SettingsViewModel, historyViewModel: HistoryViewModel) {
        self.settings = settings
        self.viewModel = viewModel
        self.historyViewModel = historyViewModel
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if windowController == nil {
            let content = SettingsView()
                .environment(settings)
                .environment(viewModel)
                .environment(historyViewModel)
            let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "ClipboardManager Settings"
            window.identifier = NSUserInterfaceItemIdentifier("settingsWindow")
            window.isReleasedWhenClosed = false
            window.center()
            window.contentViewController = NSHostingController(rootView: content)
            window.level = .floating + 1
            let controller = SettingsWindowController(window: window, viewModel: viewModel)
            controller.onWindowWillClose = { [weak self] in self?.windowController = nil }
            windowController = controller
        }
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }
}
