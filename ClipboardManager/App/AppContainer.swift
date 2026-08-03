import AppKit
import Foundation

@MainActor
struct AppLaunchConfiguration {
    struct ConfigurationLocation {
        let fileURL: URL
        let sourceDescription: String
        let allowsLocationChanges: Bool
        let errorMessage: String?
        let createsParentDirectory: Bool
    }

    static let e2eBundleID = "com.xshoji.ClipboardManager.E2E"
    static let e2eDefaultsDomain = "com.xshoji.ClipboardManager.E2E"
    static let e2eTemporaryDirectoryName = "com.xshoji.ClipboardManager.E2E"
    static let e2ePasteboardNamePrefix = "com.xshoji.ClipboardManager.E2E."
    static let e2eTestRunnerBundleID = "com.xshoji.SmokeUITests.xctrunner"

    let isE2E: Bool
    let storeURL: URL
    let configurationLocation: ConfigurationLocation
    let pasteboard: NSPasteboard

    static func resolve() -> AppLaunchConfiguration {
        guard Bundle.main.bundleIdentifier == e2eBundleID else {
            let configurationLocation = resolveProductionConfigurationLocation(
                environment: ProcessInfo.processInfo.environment,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                persistedCustomPath: SettingsConfigurationBootstrap.customPath()
            )
            return AppLaunchConfiguration(
                isE2E: false,
                storeURL: PersistenceController.productionStoreURL,
                configurationLocation: configurationLocation,
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
            configurationLocation: ConfigurationLocation(
                fileURL: storeURL.deletingLastPathComponent().appendingPathComponent("config.json"),
                sourceDescription: "E2E isolated path",
                allowsLocationChanges: false,
                errorMessage: nil,
                createsParentDirectory: false
            ),
            pasteboard: NSPasteboard(name: NSPasteboard.Name(pasteboardName))
        )
    }

    static func resolveProductionConfigurationLocation(
        environment: [String: String],
        homeDirectory: URL,
        persistedCustomPath: String? = nil,
        fileManager: FileManager = .default
    ) -> ConfigurationLocation {
        if let path = environment["CLIPBOARD_MANAGER_CONFIG_PATH"] {
            let fileURL = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
            let error = validateExplicitConfigurationPath(
                path,
                fileURL: fileURL,
                fileManager: fileManager
            )
            return ConfigurationLocation(
                fileURL: fileURL,
                sourceDescription: "CLIPBOARD_MANAGER_CONFIG_PATH",
                allowsLocationChanges: false,
                errorMessage: error,
                createsParentDirectory: false
            )
        }

        if let path = persistedCustomPath {
            let fileURL = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
            let error = validateExplicitConfigurationPath(
                path,
                fileURL: fileURL,
                fileManager: fileManager,
                pathLabel: "The custom configuration path"
            )
            return ConfigurationLocation(
                fileURL: fileURL,
                sourceDescription: "Custom location",
                allowsLocationChanges: true,
                errorMessage: error,
                createsParentDirectory: false
            )
        }

        if let path = environment["XDG_CONFIG_HOME"],
           !path.isEmpty,
           (path as NSString).isAbsolutePath {
            return ConfigurationLocation(
                fileURL: URL(fileURLWithPath: path, isDirectory: true)
                    .appendingPathComponent("clipboard-manager", isDirectory: true)
                    .appendingPathComponent("config.json", isDirectory: false),
                sourceDescription: "XDG_CONFIG_HOME",
                allowsLocationChanges: true,
                errorMessage: nil,
                createsParentDirectory: true
            )
        }

        return ConfigurationLocation(
            fileURL: homeDirectory
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("clipboard-manager", isDirectory: true)
                .appendingPathComponent("config.json", isDirectory: false),
            sourceDescription: "Default (~/.config)",
            allowsLocationChanges: true,
            errorMessage: nil,
            createsParentDirectory: true
        )
    }

    private static func validateExplicitConfigurationPath(
        _ path: String,
        fileURL: URL,
        fileManager: FileManager,
        pathLabel: String = "CLIPBOARD_MANAGER_CONFIG_PATH"
    ) -> String? {
        guard !path.isEmpty, (path as NSString).isAbsolutePath else {
            return "\(pathLabel) must be a non-empty absolute path ending in config.json. Configuration synchronization is disabled."
        }
        guard fileURL.lastPathComponent == "config.json" else {
            return "\(pathLabel) must end in config.json. Configuration synchronization is disabled."
        }

        let parent = fileURL.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            return "The parent directory specified by \(pathLabel) does not exist. Configuration synchronization is disabled."
        }

        if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            return "\(pathLabel) must point directly to a regular file, not a symbolic link. Configuration synchronization is disabled."
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return nil
        }
        guard !isDirectory.boolValue else {
            return "\(pathLabel) must point to a regular file, not a directory. Configuration synchronization is disabled."
        }
        do {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                return "\(pathLabel) must point directly to a regular file. Configuration synchronization is disabled."
            }
        } catch {
            return "The file specified by \(pathLabel) could not be inspected. Configuration synchronization is disabled."
        }
        return nil
    }

    private static func validateE2EStorePath(_ rawPath: String) -> URL {
        guard (rawPath as NSString).isAbsolutePath else {
            fatalError("CM_E2E_STORE_PATH must be an absolute path")
        }

        let fileManager = FileManager.default
        // The XCUITest runner is containerized even though the E2E host is not.
        // Resolve its known container Caches path explicitly so host-side
        // validation does not depend on the two processes sharing TMPDIR.
        let allowedRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(e2eTestRunnerBundleID, isDirectory: true)
            .appendingPathComponent("Data/Library/Caches", isDirectory: true)
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
    let settingsConfiguration: SettingsConfigurationManaging
    let hotkeyManager: HotkeyManager
    let menuBarController: MenuBarController
    let coordinator: AppCoordinator

    init(configuration: AppLaunchConfiguration) {
        let settings = AppSettings.shared
        configuration.applyE2EDefaults(to: settings)
        self.settings = settings
        let settingsConfiguration = SettingsConfigurationAdapter(
            settings: settings,
            fileURL: configuration.configurationLocation.fileURL,
            locationDescription: configuration.configurationLocation.sourceDescription,
            allowsLocationChanges: configuration.configurationLocation.allowsLocationChanges,
            startupError: configuration.configurationLocation.errorMessage,
            createsParentDirectory: configuration.configurationLocation.createsParentDirectory
        )
        settingsConfiguration.loadInitialConfiguration()
        self.settingsConfiguration = settingsConfiguration
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
            macroRunner: MacroRunnerAdapter(settings: settings),
            activator: AppActivator.shared,
            notifier: AppNotifierAdapter()
        )
        historyViewModel = HistoryViewModel(repository: repository, pasteCoordinator: pasteCoordinator, currentReader: monitor)
        hotkeyManager = HotkeyManager(settings: settings)
        settingsViewModel = SettingsViewModel(
            settings: settings,
            configurationManager: settingsConfiguration
        )
        menuBarController = MenuBarController(settings: settings)
        coordinator = AppCoordinator(settings: settings, historyViewModel: historyViewModel, settingsViewModel: settingsViewModel)
    }
}
