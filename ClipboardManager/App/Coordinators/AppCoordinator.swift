import Foundation

/// Owns the window coordinators and is the sole presentation entry point for
/// menu-bar and global-hotkey integrations.
@MainActor
final class AppCoordinator {
    let mainWindow: MainWindowCoordinator
    let settingsWindow: SettingsWindowCoordinator

    init(settings: AppSettings, historyViewModel: HistoryViewModel, settingsViewModel: SettingsViewModel) {
        settingsWindow = SettingsWindowCoordinator(
            settings: settings,
            viewModel: settingsViewModel,
            historyViewModel: historyViewModel
        )
        mainWindow = MainWindowCoordinator(settings: settings, viewModel: historyViewModel)
        mainWindow.onShowSettings = { [weak settingsWindow] in settingsWindow?.show() }
    }

    func showMainWindow(focusSearch: Bool = false) { mainWindow.show(focusSearch: focusSearch) }
    func showSettings() { settingsWindow.show() }
}
