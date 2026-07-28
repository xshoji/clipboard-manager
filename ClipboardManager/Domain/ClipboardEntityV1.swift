import Foundation
import SwiftData

/// Legacy V1 model kept for SwiftData versioned migration. Do not use in app code.
@Model
final class ClipboardEntityV1 {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var kind: String
    @Attribute(.externalStorage) var text: String?
    var textPreview: String?
    var isTextPreviewTruncated: Bool?
    var textCharacterCount: Int?
    var textPreviewLowercased: String?
    @Attribute(.externalStorage) var richText: Data?
    @Attribute(.externalStorage) var imageData: Data?
    @Attribute(.externalStorage) var thumbnail: Data?
    var sourceBundleID: String?
    var contentHash: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        kind: String,
        text: String? = nil,
        richText: Data? = nil,
        imageData: Data? = nil,
        thumbnail: Data? = nil,
        sourceBundleID: String? = nil,
        contentHash: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.text = text
        self.textPreview = nil
        self.isTextPreviewTruncated = nil
        self.textPreviewLowercased = nil
        self.textCharacterCount = nil
        self.richText = richText
        self.imageData = imageData
        self.thumbnail = thumbnail
        self.sourceBundleID = sourceBundleID
        self.contentHash = contentHash
    }
}
