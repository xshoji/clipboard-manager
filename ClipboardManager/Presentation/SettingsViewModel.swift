import Foundation

@MainActor @Observable
final class SettingsViewModel {
    let settings: AppSettingsStore
    var unsavedMacroIDs: Set<UUID> = []
    var shouldCloseAfterSave = false
    private var expected = 0
    private var completed = 0
    init(settings: AppSettingsStore) { self.settings = settings }
    func setDirty(_ id: UUID, _ dirty: Bool) {
        if dirty { unsavedMacroIDs.insert(id) } else { unsavedMacroIDs.remove(id) }
    }
    func startSaveCycle() { expected = unsavedMacroIDs.count; completed = 0 }
    func recordSaveSettlement() { completed += 1; if expected > 0 && completed >= expected { NotificationCenter.default.post(name: .macroSaveSettleComplete, object: nil) } }
}
