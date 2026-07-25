import AppKit
import Foundation
import SwiftData

extension Notification.Name {
    static let clipboardRepositoryDidChange = Notification.Name("clipboardRepositoryDidChange")
}

@MainActor
final class ClipboardRepository {
    struct TextContent {
        let text: String?
        let richText: Data?
    }

    struct NewItem: Sendable {
        let kind: String
        var text: String? = nil
        var richText: Data? = nil
        var imageData: Data? = nil
        var thumbnail: Data? = nil
        var sourceBundleID: String? = nil
        var contentHash: String? = nil
    }

    private let persistence: PersistenceController

    init(persistence: PersistenceController) {
        self.persistence = persistence
        persistence.onLimitsDidDelete = { [weak self] in self?.notifyChange() }
    }
    convenience init(settings: AppSettingsStore) {
        self.init(persistence: PersistenceController(settings: settings))
    }

    func start() { persistence.startObservingSettings() }
    func flushOnTerminate() { persistence.flushOnTerminate() }

    func fetchAll() -> [ClipboardItem] {
        let descriptor = FetchDescriptor<ClipboardEntity>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (persistence.fetchEntities(descriptor, context: persistence.container.mainContext, purpose: "repository.fetchAll") ?? []).map(Self.item)
    }

    func fetch(id: UUID) -> ClipboardItem? {
        entity(id: id).map(Self.item)
    }

    func fetchTextContent(id: UUID, includeRichText: Bool) -> TextContent? {
        guard let entity = entity(id: id) else { return nil }
        return TextContent(text: entity.text, richText: includeRichText ? entity.richText : nil)
    }

    func fetchImageData(id: UUID) -> Data? { entity(id: id)?.imageData }
    func fetchFullText(id: UUID) -> String? { entity(id: id)?.text }

    @discardableResult
    func insert(_ item: NewItem, removingDuplicates: Bool = false, purpose: String) -> Bool {
        let context = persistence.container.mainContext
        if removingDuplicates, let hash = item.contentHash {
            let descriptor = FetchDescriptor<ClipboardEntity>(predicate: #Predicate { $0.contentHash == hash })
            for duplicate in persistence.fetchEntities(descriptor, context: context, purpose: "repository.deduplicate") ?? [] {
                context.delete(duplicate)
            }
        }
        context.insert(ClipboardEntity(kind: item.kind, text: item.text, richText: item.richText,
            imageData: item.imageData, thumbnail: item.thumbnail, sourceBundleID: item.sourceBundleID,
            contentHash: item.contentHash))
        guard persistence.saveContext(context, purpose: purpose) else {
            context.rollback()
            return false
        }
        persistence.scheduleEnforceWithDebounce()
        notifyChange()
        return true
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        guard let value = entity(id: id) else { return false }
        let context = persistence.container.mainContext
        context.delete(value)
        guard persistence.saveContext(context, purpose: "repository.delete") else {
            context.rollback()
            return false
        }
        notifyChange()
        return true
    }

    @discardableResult
    func clearAll() -> Bool {
        guard persistence.clearAll() else { return false }
        notifyChange()
        return true
    }

    private func entity(id: UUID) -> ClipboardEntity? {
        let descriptor = FetchDescriptor<ClipboardEntity>(predicate: #Predicate { $0.id == id })
        return persistence.fetchEntities(descriptor, context: persistence.container.mainContext, purpose: "repository.fetch")?.first
    }

    private static func item(_ entity: ClipboardEntity) -> ClipboardItem {
        ClipboardItem(id: entity.id, createdAt: entity.createdAt, kind: entity.kind,
            textPreview: entity.textPreview, textPreviewLowercased: entity.textPreviewLowercased,
            isTextPreviewTruncated: entity.isTextPreviewTruncated ?? false,
            textCharacterCount: entity.textCharacterCount, thumbnail: entity.thumbnail,
            sourceBundleID: entity.sourceBundleID, contentHash: entity.contentHash)
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .clipboardRepositoryDidChange, object: self)
    }
}
