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
        // Compose the persistence stack explicitly so `ClipboardRepository`
        // (ApplicationServices) never references `PersistenceController` /
        // `ClipboardDataActor` (Infrastructure) directly. The adapter is the
        // single Infrastructure-side entry point that conforms to the
        // ApplicationServices port.
        let persistenceAdapter = ClipboardPersistenceAdapter(settings: settings)
        repository = ClipboardRepository(persistence: persistenceAdapter)
        monitor = ClipboardMonitor(
            repository: repository,
            settings: settings,
            automaticOcr: AutomaticOcrProcessor(repository: repository)
        )
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
