import Foundation
import SwiftData

private enum TextPreviewBuilder {
    static let lineLimit = 100
    static let characterLimit = 16_000

    static func build(from text: String) -> (text: String, isTruncated: Bool) {
        var end = text.startIndex
        var lineCount = 0
        var characterCount = 0

        while end < text.endIndex,
              lineCount < lineLimit,
              characterCount < characterLimit {
            if text[end].isNewline {
                lineCount += 1
            }
            end = text.index(after: end)
            characterCount += 1
        }

        return (String(text[..<end]), end < text.endIndex)
    }
}

/// Current model namespace. Keeping the nested model's short name as
/// `ClipboardEntity` preserves the persisted entity identity across schema versions.
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
    /// Lowercased version of `textPreview` persisted at save time so the search
    /// filter does not re-lowercase every preview on every query (review #22).
    /// Nil for legacy rows until they are next saved; the filter falls back to
    /// on-the-fly lowercasing when nil.
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

    var isImage: Bool { kind == "image" }
    var isText: Bool { kind == "text" }

    var displayTextPreview: String {
        if let textPreview {
            return textPreview
        }
        return isText ? "Preview is unavailable for this existing item. Choose Edit to load the full text." : ""
    }
}
}

typealias ClipboardEntity = ClipboardEntitySchemaV3.ClipboardEntity
