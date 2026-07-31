import AppKit
import Foundation

@MainActor
struct AppLaunchConfiguration {
    static let e2eBundleID = "com.xshoji.ClipboardManager.E2E"
    static let e2eDefaultsDomain = "com.xshoji.ClipboardManager.E2E"
    static let e2eTemporaryDirectoryName = "com.xshoji.ClipboardManager.E2E"
    static let e2ePasteboardNamePrefix = "com.xshoji.ClipboardManager.E2E."

    let isE2E: Bool
    let storeURL: URL
    let pasteboard: NSPasteboard

    static func resolve() -> AppLaunchConfiguration {
        guard Bundle.main.bundleIdentifier == e2eBundleID else {
            return AppLaunchConfiguration(
                isE2E: false,
                storeURL: PersistenceController.productionStoreURL,
                pasteboard: .general
            )
        }

        let environment = ProcessInfo.processInfo.environment
        guard environment["CM_E2E_OPEN_WINDOW"] == "1",
              let rawStorePath = environment["CM_E2E_STORE_PATH"],
              let pasteboardName = environment["CM_E2E_PASTEBOARD_NAME"],
              pasteboardName.hasPrefix(e2ePasteboardNamePrefix) else {
            fatalError("The E2E app requires an isolated store path and pasteboard name")
        }

        let storeURL = validateE2EStorePath(rawStorePath)
        return AppLaunchConfiguration(
            isE2E: true,
            storeURL: storeURL,
            pasteboard: NSPasteboard(name: NSPasteboard.Name(pasteboardName))
        )
    }

    private static func validateE2EStorePath(_ rawPath: String) -> URL {
        guard (rawPath as NSString).isAbsolutePath else {
            fatalError("CM_E2E_STORE_PATH must be an absolute path")
        }

        let fileManager = FileManager.default
        let allowedRoot = fileManager.temporaryDirectory
            .appendingPathComponent(e2eTemporaryDirectoryName, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: rawPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let parent = candidate.deletingLastPathComponent()
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              candidate.pathComponents.starts(with: allowedRoot.pathComponents),
              candidate.pathComponents.count > allowedRoot.pathComponents.count,
              candidate.pathExtension == "store" else {
            fatalError("CM_E2E_STORE_PATH must point inside the E2E temporary directory")
        }

        let productionDirectory = PersistenceController.productionStoreURL
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard !candidate.pathComponents.starts(with: productionDirectory.pathComponents) else {
            fatalError("The E2E store must not use the production store directory")
        }
        return candidate
    }

    func prepareUserDefaults() {
        guard isE2E else { return }
        UserDefaults.standard.removePersistentDomain(forName: Self.e2eDefaultsDomain)
    }

    func applyE2EDefaults(to settings: AppSettings) {
        guard isE2E else { return }
        settings.hotkeyKeyCode = AppSettings.defaultHotkeyKeyCode
        settings.hotkeyModifiers = AppSettings.testHotkeyModifiers
        settings.globalMacroPickerHotkeyKeyCode = AppSettings.defaultGlobalMacroPickerHotkeyKeyCode
        settings.globalMacroPickerHotkeyModifiers = AppSettings.defaultGlobalMacroPickerHotkeyModifiers
        settings.editHotkeyCode = AppSettings.defaultEditHotkeyCode
        settings.editHotkeyModifiers = AppSettings.defaultActionHotkeyModifiers
        settings.pastePlainHotkeyCode = AppSettings.defaultPastePlainHotkeyCode
        settings.pastePlainHotkeyModifiers = AppSettings.defaultActionHotkeyModifiers
        settings.macroPickerHotkeyCode = AppSettings.defaultMacroPickerHotkeyCode
        settings.macroPickerHotkeyModifiers = AppSettings.defaultActionHotkeyModifiers
    }
}

@MainActor
final class AppContainer {
    let settings: AppSettings
    let repository: ClipboardRepository
    let monitor: ClipboardMonitor
    let pasteCoordinator: PasteCoordinator
    let historyViewModel: HistoryViewModel
    let settingsViewModel: SettingsViewModel
    let hotkeyManager: HotkeyManager
    let menuBarController: MenuBarController
    let coordinator: AppCoordinator

    init(configuration: AppLaunchConfiguration) {
        let settings = AppSettings.shared
        configuration.applyE2EDefaults(to: settings)
        self.settings = settings
        // Compose the persistence stack explicitly so `ClipboardRepository`
        // (ApplicationServices) never references `PersistenceController` /
        // `ClipboardDataActor` (Infrastructure) directly. The adapter is the
        // single Infrastructure-side entry point that conforms to the
        // ApplicationServices port.
        let persistence = PersistenceController(settings: settings, storeURL: configuration.storeURL)
        let persistenceAdapter = ClipboardPersistenceAdapter(persistence: persistence)
        repository = ClipboardRepository(persistence: persistenceAdapter)
        monitor = ClipboardMonitor(
            repository: repository,
            settings: settings,
            automaticOcr: AutomaticOcrProcessor(repository: repository),
            pasteboard: configuration.pasteboard
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
