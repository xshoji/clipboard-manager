import Foundation
import SwiftData

/// Concrete `ClipboardPersistencePort` adapter that bundles `PersistenceController`
/// (main-context IO, limits enforcement, backup/restore-on-corruption) and
/// `ClipboardDataActor` (off-main reads via `@ModelActor`).
///
/// Lives in Infrastructure and conforms to the ApplicationServices port, so the
/// dependency direction stays Infrastructure -> ApplicationServices (inward).
/// `ClipboardRepository` no longer references `PersistenceController` or
/// `ClipboardDataActor` directly.
@MainActor
final class ClipboardPersistenceAdapter: ClipboardPersistencePort {
    private let persistence: PersistenceController
    private let dataActor: ClipboardDataActor

    init(persistence: PersistenceController) {
        self.persistence = persistence
        self.dataActor = ClipboardDataActor(modelContainer: persistence.container)
    }

    // MARK: - Reads (off-main via @ModelActor)

    func fetchAll(limit: Int) async -> [ClipboardItem] {
        await dataActor.fetchAll(limit: limit)
    }

    func fetch(id: UUID) async -> ClipboardItem? {
        await dataActor.fetch(id: id)
    }

    func fetchInspection(id: UUID) async -> ClipboardInspection? {
        await dataActor.fetchInspection(id: id)
    }

    func fetchTextContent(id: UUID, includeRich: Bool) async -> ClipboardTextContent? {
        await dataActor.fetchTextContent(id: id, includeRich: includeRich)
    }

    func fetchHTMLData(id: UUID) async -> Data? {
        await dataActor.fetchHTMLData(id: id)
    }

    func fetchImageData(id: UUID) async -> Data? {
        await dataActor.fetchImageData(id: id)
    }

    func fetchFullText(id: UUID) async -> String? {
        await dataActor.fetchFullText(id: id)
    }

    func fetchOcrResult(id: UUID) async -> ClipboardOcrResult? {
        await dataActor.fetchOcrResult(id: id)
    }

    // MARK: - Writes (main actor via ModelContext)

    @discardableResult
    func insert(_ item: NewClipboardItem, removingDuplicates: Bool, purpose: String) -> Bool {
        let context = persistence.container.mainContext
        var isPinned = item.isPinned
        if removingDuplicates, let hash = item.contentHash {
            let descriptor = FetchDescriptor<ClipboardEntity>(
                predicate: #Predicate { $0.contentHash == hash }
            )
            for duplicate in persistence.fetchEntities(
                descriptor, context: context, purpose: "repository.deduplicate"
            ) ?? [] {
                isPinned = isPinned || duplicate.isPinned
                context.delete(duplicate)
            }
        }
        context.insert(ClipboardEntity(
            id: item.id,
            kind: item.kind,
            text: item.text,
            richText: item.richText,
            html: item.html,
            imageData: item.imageData,
            thumbnail: item.thumbnail,
            sourceBundleID: item.sourceBundleID,
            contentHash: item.contentHash,
            ocrStatus: item.ocrStatus,
            textAvailability: item.textAvailability,
            isPinned: isPinned
        ))
        guard persistence.saveContext(context, purpose: purpose) else {
            context.rollback()
            return false
        }
        persistence.scheduleEnforceWithDebounce()
        return true
    }

    @discardableResult
    func updateOcrResult(id: UUID, text: String?) -> Bool {
        let context = persistence.container.mainContext
        let descriptor = FetchDescriptor<ClipboardEntity>(predicate: #Predicate { $0.id == id })
        guard let entity = persistence.fetchEntities(
            descriptor, context: context, purpose: "repository.fetchForOcrUpdate"
        )?.first else {
            return false
        }
        entity.ocrText = text
        entity.ocrStatus = "completed"
        guard persistence.saveContext(context, purpose: "repository.updateOcrResult") else {
            context.rollback()
            return false
        }
        return true
    }

    @discardableResult
    func setPinned(id: UUID, isPinned: Bool) -> Bool {
        let context = persistence.container.mainContext
        let descriptor = FetchDescriptor<ClipboardEntity>(predicate: #Predicate { $0.id == id })
        guard let entity = persistence.fetchEntities(
            descriptor, context: context, purpose: "repository.fetchForPinUpdate"
        )?.first else { return false }
        entity.isPinned = isPinned
        guard persistence.saveContext(context, purpose: "repository.setPinned") else {
            context.rollback()
            return false
        }
        return true
    }

    @discardableResult
    func pinCurrent(_ item: NewClipboardItem) -> Bool {
        let context = persistence.container.mainContext
        if let hash = item.contentHash {
            let descriptor = FetchDescriptor<ClipboardEntity>(
                predicate: #Predicate { $0.contentHash == hash }
            )
            if let matching = persistence.fetchEntities(
                descriptor, context: context, purpose: "repository.fetchForCurrentPin"
            )?.first {
                matching.isPinned = true
                guard persistence.saveContext(context, purpose: "repository.pinCurrent") else {
                    context.rollback()
                    return false
                }
                return true
            }
        }
        var pinnedItem = item
        pinnedItem.isPinned = true
        return insert(pinnedItem, removingDuplicates: true, purpose: "repository.pinCurrent")
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        let descriptor = FetchDescriptor<ClipboardEntity>(predicate: #Predicate { $0.id == id })
        guard let value = persistence.fetchEntities(
            descriptor, context: persistence.container.mainContext, purpose: "repository.fetch"
        )?.first else {
            return false
        }
        let context = persistence.container.mainContext
        context.delete(value)
        guard persistence.saveContext(context, purpose: "repository.delete") else {
            context.rollback()
            return false
        }
        return true
    }

    @discardableResult
    func clearAll() -> Bool {
        persistence.clearAll()
    }

    // MARK: - Lifecycle wiring

    func startObservingSettings() {
        persistence.startObservingSettings()
    }

    func flushOnTerminate() {
        persistence.flushOnTerminate()
    }

    var onLimitsDidDelete: (() -> Void)? {
        get { persistence.onLimitsDidDelete }
        set { persistence.onLimitsDidDelete = newValue }
    }
}
