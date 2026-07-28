import Foundation
import SwiftData

@ModelActor
actor ClipboardDataActor {
    /// Fetches lightweight history DTOs newest first, bounded to avoid loading the entire store.
    func fetchAll(limit: Int) -> [ClipboardItem] {
        var descriptor = FetchDescriptor<ClipboardEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        do {
            return try modelContext.fetch(descriptor).map { entity in
                ClipboardItem(
                    id: entity.id,
                    createdAt: entity.createdAt,
                    kind: entity.kind,
                    textPreview: entity.textPreview,
                    textPreviewLowercased: entity.textPreviewLowercased,
                    isTextPreviewTruncated: entity.isTextPreviewTruncated ?? false,
                    textCharacterCount: entity.textCharacterCount,
                    thumbnail: entity.thumbnail,
                    isHtml: entity.html != nil,
                    sourceBundleID: entity.sourceBundleID,
                    contentHash: entity.contentHash
                )
            }
        } catch {
            return []
        }
    }

    func fetchImageData(id: UUID) -> Data? { entity(id: id)?.imageData }
    func fetchFullText(id: UUID) -> String? { entity(id: id)?.text }

    /// Fetches the text payload for paste. When `includeRich` is true, both `richText`
    /// (RTFD) and `html` are included; when false, only plain `text` is returned.
    /// The name `includeRich` (not `includeRichText`) reflects that it gates both rich
    /// text and HTML (review #4).
    func fetchTextContent(id: UUID, includeRich: Bool) -> ClipboardRepository.TextContent? {
        guard let entity = entity(id: id) else { return nil }
        return ClipboardRepository.TextContent(
            text: entity.text,
            richText: includeRich ? entity.richText : nil,
            html: includeRich ? entity.html : nil
        )
    }

    func fetchHtmlContent(id: UUID) -> Data? { entity(id: id)?.html }

    private func entity(id: UUID) -> ClipboardEntity? {
        let descriptor = FetchDescriptor<ClipboardEntity>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }
}
