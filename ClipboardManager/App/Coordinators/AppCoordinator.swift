import Foundation

@MainActor
protocol AppCoordinating: AnyObject {
    func showMainWindow(focusSearch: Bool)
    func showSettings()
}

/// Owns the window coordinators and is the sole presentation entry point for
/// menu-bar and global-hotkey integrations.
@MainActor
final class AppCoordinator: AppCoordinating {
    let mainWindow: MainWindowCoordinator
    let settingsWindow: SettingsWindowCoordinator

    init(settings: AppSettings, historyViewModel: HistoryViewModel, settingsViewModel: SettingsViewModel) {
        settingsWindow = SettingsWindowCoordinator(settings: settings, viewModel: settingsViewModel)
        mainWindow = MainWindowCoordinator(settings: settings, viewModel: historyViewModel)
        mainWindow.onShowSettings = { [weak settingsWindow] in settingsWindow?.show() }
    }

    func showMainWindow(focusSearch: Bool = false) { mainWindow.show(focusSearch: focusSearch) }
    func showSettings() { settingsWindow.show() }
}
