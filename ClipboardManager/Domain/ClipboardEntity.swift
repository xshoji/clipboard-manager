import Foundation
import SwiftData
import AppKit

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
        self.imageData = imageData
        self.thumbnail = thumbnail
        self.sourceBundleID = sourceBundleID
        self.contentHash = contentHash
    }

    var isImage: Bool { kind == "image" }
    var isText: Bool { kind == "text" }

    var displayTextPreview: String {
        if let textPreview {
            return textPreview
        }
        return isText ? "Preview is unavailable for this existing item. Choose Edit to load the full text." : ""
    }

    /// Writes the entity content to the pasteboard.
    /// Restores only formats decodable by AppKit as RTF / RTFD, including legacy data.
    func writeToPasteboard(_ pasteboard: NSPasteboard, rich: Bool = true) {
        pasteboard.clearContents()
        if isImage, let imageData {
            pasteboard.setData(imageData, forType: .png)
        } else if rich, let richText, let type = richTextPasteboardType(for: richText) {
            pasteboard.setData(richText, forType: type)
            pasteboard.setString(text ?? "", forType: .string)
        } else {
            pasteboard.setString(text ?? "", forType: .string)
        }
    }

    private func richTextPasteboardType(for data: Data) -> NSPasteboard.PasteboardType? {
        if (try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )) != nil {
            return .rtf
        }
        if (try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )) != nil {
            return .rtfd
        }
        return nil
    }
}
