import Foundation

@MainActor
final class AppContainer {
    let settings = AppSettings.shared
    let repository: ClipboardRepository
    let monitor: ClipboardMonitor
    let pasteCoordinator: PasteCoordinator
    let historyViewModel: HistoryViewModel
    let settingsViewModel: SettingsViewModel
    let hotkeyManager: HotkeyManager
    let menuBarController: MenuBarController
    let coordinator: AppCoordinator

    init() {
        repository = ClipboardRepository(settings: settings)
        monitor = ClipboardMonitor(repository: repository, settings: settings)
        pasteCoordinator = PasteCoordinator(
            repository: repository,
            settings: settings,
            pasteboard: monitor,
            ocr: OcrRecognizerAdapter(),
            macroRunner: MacroRunnerAdapter(),
            activator: AppActivator.shared,
            notifier: AppNotifierAdapter()
        )
        historyViewModel = HistoryViewModel(repository: repository, pasteCoordinator: pasteCoordinator)
        settingsViewModel = SettingsViewModel(settings: settings)
        hotkeyManager = HotkeyManager(settings: settings)
        menuBarController = MenuBarController(settings: settings)
        coordinator = AppCoordinator(settings: settings, historyViewModel: historyViewModel, settingsViewModel: settingsViewModel)
    }
}
