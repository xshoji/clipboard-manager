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

    /// Designated initializer. Both dependencies are injected so the adapter
    /// is testable without spinning up a real SwiftData container on every
    /// path, and so callers (e.g. `AppContainer`) can swap the `ClipboardDataActor`
    /// for a test double when one becomes available.
    init(persistence: PersistenceController, dataActor: ClipboardDataActor) {
        self.persistence = persistence
        self.dataActor = dataActor
    }

    /// Convenience entry point used by `AppContainer` to build the persistence
    /// stack from settings without exposing `PersistenceController` to
    /// ApplicationServices. Constructs the default `ClipboardDataActor` bound
    /// to the provided container.
    convenience init(persistence: PersistenceController) {
        self.init(
            persistence: persistence,
            dataActor: ClipboardDataActor(modelContainer: persistence.container)
        )
    }

    /// Convenience entry point that builds the whole persistence stack from
    /// settings. Kept for symmetry with the previous `AppContainer` wiring.
    convenience init(settings: AppSettingsStore) {
        let persistence = PersistenceController(settings: settings)
        self.init(
            persistence: persistence,
            dataActor: ClipboardDataActor(modelContainer: persistence.container)
        )
    }

    // MARK: - Reads (off-main via @ModelActor)

    func fetchAll(limit: Int) async -> [ClipboardItem] {
        await dataActor.fetchAll(limit: limit)
    }

    func fetch(id: UUID) async -> ClipboardItem? {
        await dataActor.fetch(id: id)
    }

    func fetchTextContent(id: UUID, includeRich: Bool) async -> ClipboardTextContent? {
        await dataActor.fetchTextContent(id: id, includeRich: includeRich)
    }

    func fetchImageData(id: UUID) async -> Data? {
        await dataActor.fetchImageData(id: id)
    }

    func fetchFullText(id: UUID) async -> String? {
        await dataActor.fetchFullText(id: id)
    }

    func fetchHtmlContent(id: UUID) async -> Data? {
        await dataActor.fetchHtmlContent(id: id)
    }

    // MARK: - Writes (main actor via ModelContext)

    @discardableResult
    func insert(_ item: NewClipboardItem, removingDuplicates: Bool, purpose: String) -> Bool {
        let context = persistence.container.mainContext
        if removingDuplicates, let hash = item.contentHash {
            let descriptor = FetchDescriptor<ClipboardEntity>(
                predicate: #Predicate { $0.contentHash == hash }
            )
            for duplicate in persistence.fetchEntities(
                descriptor, context: context, purpose: "repository.deduplicate"
            ) ?? [] {
                context.delete(duplicate)
            }
        }
        context.insert(ClipboardEntity(
            kind: item.kind,
            text: item.text,
            richText: item.richText,
            html: item.html,
            imageData: item.imageData,
            thumbnail: item.thumbnail,
            sourceBundleID: item.sourceBundleID,
            contentHash: item.contentHash
        ))
        guard persistence.saveContext(context, purpose: purpose) else {
            context.rollback()
            return false
        }
        persistence.scheduleEnforceWithDebounce()
        return true
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
