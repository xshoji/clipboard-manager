import AppKit
import Foundation

extension Notification.Name {
    static let clipboardRepositoryDidChange = Notification.Name("clipboardRepositoryDidChange")
}

/// ApplicationServices-side boundary for clipboard history persistence.
///
/// Architecture:
/// - Depends on `ClipboardPersistencePort` (an ApplicationServices port
///   protocol). The concrete adapter (`ClipboardPersistenceAdapter`,
///   Infrastructure) is injected by `AppContainer`, so this class no longer
///   references `PersistenceController` / `ClipboardDataActor` directly. The
///   ApplicationServices -> Infrastructure dependency is removed.
/// - Exposes `ClipboardRepositoryPort` to Presentation (`HistoryViewModel`,
///   `PasteCoordinator`) and to Infrastructure (`ClipboardMonitor`,
///   `PreviewImageEditor`) so both layers depend on an ApplicationServices
///   port, not a concrete class.
/// - DTOs (`ClipboardItem`, `ClipboardTextContent`, `NewClipboardItem`) live
///   in Domain, so neither ApplicationServices nor Infrastructure introduces a
///   reverse dependency by returning/accepting them.
@MainActor
final class ClipboardRepository: ClipboardRepositoryPort, ClipboardHistoryWriting {
    private let persistence: ClipboardPersistencePort

    init(persistence: ClipboardPersistencePort) {
        self.persistence = persistence
        persistence.onLimitsDidDelete = { [weak self] in self?.notifyChange() }
    }

    func start() { persistence.startObservingSettings() }
    func flushOnTerminate() { persistence.flushOnTerminate() }

    func fetchAll() async -> [ClipboardItem] { await persistence.fetchAll(limit: 500) }

    func fetch(id: UUID) async -> ClipboardItem? {
        await persistence.fetch(id: id)
    }

    func fetchTextContent(id: UUID, includeRich: Bool) async -> ClipboardTextContent? {
        await persistence.fetchTextContent(id: id, includeRich: includeRich)
    }

    func fetchImageData(id: UUID) async -> Data? {
        await persistence.fetchImageData(id: id)
    }

    func fetchFullText(id: UUID) async -> String? {
        await persistence.fetchFullText(id: id)
    }

    func fetchOcrResult(id: UUID) async -> ClipboardOcrResult? {
        await persistence.fetchOcrResult(id: id)
    }

    @discardableResult
    func insert(_ item: NewClipboardItem, removingDuplicates: Bool, purpose: String) -> Bool {
        guard persistence.insert(item, removingDuplicates: removingDuplicates, purpose: purpose) else {
            return false
        }
        notifyChange()
        return true
    }

    @discardableResult
    func updateOcrResult(id: UUID, text: String?) -> Bool {
        guard persistence.updateOcrResult(id: id, text: text) else { return false }
        notifyChange()
        return true
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        guard persistence.delete(id: id) else { return false }
        notifyChange()
        return true
    }

    @discardableResult
    func clearAll() -> Bool {
        guard persistence.clearAll() else { return false }
        notifyChange()
        return true
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .clipboardRepositoryDidChange, object: self)
    }
}
