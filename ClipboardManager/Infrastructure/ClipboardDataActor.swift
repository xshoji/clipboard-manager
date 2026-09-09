import Foundation
import SwiftData

@ModelActor
actor ClipboardDataActor {
    /// Fetches every pinned DTO followed by newest-first unpinned DTOs bounded by `limit`.
    func fetchAll(limit: Int) -> [ClipboardItem] {
        let pinnedDescriptor = FetchDescriptor<ClipboardEntity>(
            predicate: #Predicate<ClipboardEntity> { $0.isPinned },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        var unpinnedDescriptor = FetchDescriptor<ClipboardEntity>(
            predicate: #Predicate<ClipboardEntity> { !$0.isPinned },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        unpinnedDescriptor.fetchLimit = limit
        do {
            let pinned = try modelContext.fetch(pinnedDescriptor).map(Self.item(from:))
            let unpinned = try modelContext.fetch(unpinnedDescriptor).map(Self.item(from:))
            return pinned + unpinned
        } catch {
            return []
        }
    }

    /// Single-row DTO lookup by id, mirroring `fetchAll`'s entity -> DTO mapping
    /// so the ApplicationServices layer never touches `ClipboardEntity`.
    func fetch(id: UUID) -> ClipboardItem? {
        entity(id: id).map(Self.item(from:))
    }

    func fetchImageData(id: UUID) -> Data? { entity(id: id)?.imageData }
    func fetchHTMLData(id: UUID) -> Data? { entity(id: id)?.html }
    func fetchFullText(id: UUID) -> String? { entity(id: id)?.text }

    func fetchInspection(id: UUID) -> ClipboardInspection? {
        guard let entity = entity(id: id) else { return nil }
        let text = entity.text
        let richText = entity.richText
        let html = entity.html
        let imageData = entity.imageData
        let ocrText = entity.ocrText
        var representations: [ClipboardRepresentationInspection] = []
        if let text {
            representations.append(.init(
                format: .plainText,
                typeIdentifier: "public.utf8-plain-text",
                byteCount: text.utf8.count,
                origin: .stored
            ))
        }
        if let richText {
            representations.append(.init(
                format: .richText,
                typeIdentifier: nil,
                byteCount: richText.count,
                origin: .stored
            ))
        }
        if let html {
            representations.append(.init(
                format: .html,
                typeIdentifier: "public.html",
                byteCount: html.count,
                origin: .stored
            ))
        }
        if let imageData {
            representations.append(.init(
                format: .png,
                typeIdentifier: "public.png",
                byteCount: imageData.count,
                origin: .stored
            ))
        }
        return ClipboardInspection(
            id: entity.id,
            isCurrent: false,
            createdAt: entity.createdAt,
            kind: entity.kind,
            sourceBundleID: entity.sourceBundleID,
            contentHash: entity.contentHash,
            representations: representations,
            declaredTypeIdentifiers: nil,
            textMetrics: text.map(ClipboardTextMetrics.init(text:)),
            imageMetrics: imageData.flatMap(ClipboardImageMetadataReader.metrics(from:)),
            ocrStatus: entity.ocrStatus,
            ocrCharacterCount: ocrText?.count
        )
    }

    /// Fetches the text payload for paste. When `includeRich` is true, both `richText`
    /// (RTFD) and `html` are included; when false, only plain `text` is returned.
    /// The name `includeRich` (not `includeRichText`) reflects that it gates both rich
    /// text and HTML (review #4).
    func fetchTextContent(id: UUID, includeRich: Bool) -> ClipboardTextContent? {
        guard let entity = entity(id: id) else { return nil }
        return ClipboardTextContent(
            text: entity.text,
            richText: includeRich ? entity.richText : nil,
            html: includeRich ? entity.html : nil,
            textAvailability: Self.textAvailability(for: entity)
        )
    }

    func fetchOcrResult(id: UUID) -> ClipboardOcrResult? {
        guard let entity = entity(id: id) else { return nil }
        return ClipboardOcrResult(status: entity.ocrStatus, text: entity.ocrText)
    }

    private static func textAvailability(for entity: ClipboardEntity) -> ClipboardTextAvailability {
        if let raw = entity.textAvailabilityRaw,
           let availability = ClipboardTextAvailability(rawValue: raw) {
            return availability
        }
        return .unknown
    }

    private static func item(from entity: ClipboardEntity) -> ClipboardItem {
        ClipboardItem(
            id: entity.id,
            createdAt: entity.createdAt,
            kind: entity.kind,
            textPreview: entity.textPreview,
            textPreviewLowercased: entity.textPreviewLowercased,
            isTextPreviewTruncated: entity.isTextPreviewTruncated ?? false,
            textCharacterCount: entity.textCharacterCount,
            thumbnail: entity.thumbnail,
            isHtml: entity.hasHTML ?? false,
            textAvailability: textAvailability(for: entity),
            payloadByteCount: entity.payloadByteCount,
            sourceBundleID: entity.sourceBundleID,
            contentHash: entity.contentHash,
            ocrTextLowercased: entity.ocrText?.lowercased(),
            isPinned: entity.isPinned
        )
    }

    private func entity(id: UUID) -> ClipboardEntity? {
        let descriptor = FetchDescriptor<ClipboardEntity>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }
}
