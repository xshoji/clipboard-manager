import Foundation

@MainActor @Observable
final class SettingsViewModel {
    let settings: AppSettingsStore
    let configurationFileURL: URL
    let configurationLocationDescription: String
    let allowsConfigurationLocationChanges: Bool
    private let configurationManager: SettingsConfigurationManaging
    var unsavedMacroIDs: Set<UUID> = []
    var shouldCloseAfterSave = false
    var isConfigurationOperationInProgress = false
    var configurationStatus: SettingsConfigurationStatus
    var configurationRevision = 0
    var hasPersistedCustomConfigurationLocation: Bool
    var pendingConfigurationFileURL: URL?
    var isConfigurationLocationResetPending = false
    var onRelaunchRequested: (() throws -> Void)?
    private var expected = 0
    private var completed = 0

    init(settings: AppSettingsStore, configurationManager: SettingsConfigurationManaging) {
        self.settings = settings
        self.configurationManager = configurationManager
        configurationFileURL = configurationManager.fileURL
        configurationLocationDescription = configurationManager.locationDescription
        allowsConfigurationLocationChanges = configurationManager.allowsLocationChanges
        hasPersistedCustomConfigurationLocation = configurationManager.hasPersistedCustomLocation
        configurationStatus = configurationManager.status
        configurationManager.onStatusChange = { [weak self] status in
            self?.configurationStatus = status
            self?.configurationRevision += 1
        }
    }

    func setDirty(_ id: UUID, _ dirty: Bool) {
        if dirty { unsavedMacroIDs.insert(id) } else { unsavedMacroIDs.remove(id) }
    }
    func startSaveCycle() { expected = unsavedMacroIDs.count; completed = 0 }
    func recordSaveSettlement() { completed += 1; if expected > 0 && completed >= expected { NotificationCenter.default.post(name: .macroSaveSettleComplete, object: nil) } }

    func moveMacro(id: UUID, to targetIndex: Int) {
        var macros = settings.macroScripts
        guard let sourceIndex = macros.firstIndex(where: { $0.id == id }),
              macros.indices.contains(targetIndex),
              sourceIndex != targetIndex else { return }

        let existingOrders = macros.compactMap(\.order)
        let hasStableOrders = existingOrders.count == macros.count
            && existingOrders.allSatisfy { $0 >= 0 && $0 <= Int.max - 10 }
            && zip(existingOrders, existingOrders.dropFirst()).allSatisfy { $0.0 < $0.1 }
        let positionOrders = hasStableOrders
            ? existingOrders
            : macros.indices.map { ($0 + 1) * 10 }

        let moved = macros.remove(at: sourceIndex)
        macros.insert(moved, at: targetIndex)
        for index in macros.indices {
            macros[index].order = positionOrders[index]
        }
        settings.macroScripts = macros
    }

    func reloadConfiguration() async throws {
        guard unsavedMacroIDs.isEmpty else {
            throw SettingsConfigurationError.invalidData(
                "Save or discard unsaved Macro edits before reloading the configuration."
            )
        }
        isConfigurationOperationInProgress = true
        defer { isConfigurationOperationInProgress = false }
        try await configurationManager.reloadFromDisk()
    }

    func prepareCustomConfigurationLocation(
        at fileURL: URL,
        useExistingFile: Bool
    ) async throws -> ConfigurationLocationPreparation {
        guard unsavedMacroIDs.isEmpty else {
            throw SettingsConfigurationError.invalidData(
                "Save or discard unsaved Macro edits before changing the configuration location."
            )
        }
        isConfigurationOperationInProgress = true
        defer { isConfigurationOperationInProgress = false }
        let result = try await configurationManager.prepareCustomLocation(
            at: fileURL,
            useExistingFile: useExistingFile
        )
        if case .readyForRestart = result {
            hasPersistedCustomConfigurationLocation = true
            pendingConfigurationFileURL = fileURL.standardizedFileURL
            isConfigurationLocationResetPending = false
        }
        return result
    }

    func resetCustomConfigurationLocation() throws {
        guard allowsConfigurationLocationChanges else {
            throw SettingsConfigurationError.invalidData(
                "The configuration location is controlled by the environment and cannot be changed here."
            )
        }
        guard unsavedMacroIDs.isEmpty else {
            throw SettingsConfigurationError.invalidData(
                "Save or discard unsaved Macro edits before changing the configuration location."
            )
        }
        configurationManager.resetCustomLocation()
        hasPersistedCustomConfigurationLocation = false
        pendingConfigurationFileURL = nil
        isConfigurationLocationResetPending = true
    }

    func requestRelaunch() throws {
        guard let onRelaunchRequested else {
            throw SettingsConfigurationError.invalidData(
                "ClipboardManager could not be restarted automatically. Quit and reopen the app to apply the new configuration location."
            )
        }
        try onRelaunchRequested()
    }
}
