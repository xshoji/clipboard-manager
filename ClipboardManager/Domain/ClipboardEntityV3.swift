import Foundation
import SwiftData

/// Legacy V3 model namespace kept for SwiftData versioned migration.
/// The nested model's persisted entity name remains `ClipboardEntity`, matching
/// the released V3 store. Do not use it in app code.
enum ClipboardEntitySchemaV3 {
@Model
final class ClipboardEntity {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var kind: String
    @Attribute(.externalStorage) var text: String?
    var textPreview: String?
    var isTextPreviewTruncated: Bool?
    var textCharacterCount: Int?
    var textPreviewLowercased: String?
    @Attribute(.externalStorage) var richText: Data?
    @Attribute(.externalStorage) var html: Data?
    @Attribute(.externalStorage) var imageData: Data?
    @Attribute(.externalStorage) var thumbnail: Data?
    var sourceBundleID: String?
    var contentHash: String?
    @Attribute(.externalStorage) var ocrText: String?
    var ocrStatus: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        kind: String,
        text: String? = nil,
        richText: Data? = nil,
        html: Data? = nil,
        imageData: Data? = nil,
        thumbnail: Data? = nil,
        sourceBundleID: String? = nil,
        contentHash: String? = nil,
        ocrText: String? = nil,
        ocrStatus: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.text = text
        if let text {
            let preview = TextPreviewBuilder.build(from: text)
            self.textPreview = preview.text
            self.textPreviewLowercased = preview.text.lowercased()
            self.isTextPreviewTruncated = preview.isTruncated
            self.textCharacterCount = text.count
        } else {
            self.textPreview = nil
            self.textPreviewLowercased = nil
            self.isTextPreviewTruncated = nil
            self.textCharacterCount = nil
        }
        self.richText = richText
        self.html = html
        self.imageData = imageData
        self.thumbnail = thumbnail
        self.sourceBundleID = sourceBundleID
        self.contentHash = contentHash
        self.ocrText = ocrText
        self.ocrStatus = ocrStatus
    }
}
}
