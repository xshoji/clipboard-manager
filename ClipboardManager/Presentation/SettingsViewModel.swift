import Foundation

@MainActor @Observable
final class SettingsViewModel {
    let settings: AppSettingsStore
    let configurationFileURL: URL
    private let configurationManager: SettingsConfigurationManaging
    var unsavedMacroIDs: Set<UUID> = []
    var shouldCloseAfterSave = false
    var isConfigurationOperationInProgress = false
    var configurationStatus: SettingsConfigurationStatus
    var configurationRevision = 0
    private var expected = 0
    private var completed = 0

    init(settings: AppSettingsStore, configurationManager: SettingsConfigurationManaging) {
        self.settings = settings
        self.configurationManager = configurationManager
        configurationFileURL = configurationManager.fileURL
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
}
