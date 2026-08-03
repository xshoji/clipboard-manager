import Foundation

enum TextPreviewBuilder {
    static let lineLimit = 100
    static let characterLimit = 16_000

    static func build(from text: String) -> (text: String, isTruncated: Bool) {
        var end = text.startIndex
        var lineCount = 0
        var characterCount = 0

        while end < text.endIndex,
              lineCount < lineLimit,
              characterCount < characterLimit {
            if text[end].isNewline { lineCount += 1 }
            end = text.index(after: end)
            characterCount += 1
        }

        return (String(text[..<end]), end < text.endIndex)
    }
}

/// Presentation-safe clipboard history value. Large image and rich-text payloads are
/// deliberately loaded through `ClipboardRepository` only when an action needs them.
struct ClipboardItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let kind: String
    let textPreview: String?
    let textPreviewLowercased: String?
    let isTextPreviewTruncated: Bool
    let textCharacterCount: Int?
    let thumbnail: Data?
    let isHtml: Bool
    let sourceBundleID: String?
    let contentHash: String?
    let ocrTextLowercased: String?

    var isImage: Bool { kind == "image" }
    var isCurrent: Bool { id == CurrentClipboardSnapshot.currentID }
    var displayTextPreview: String {
        textPreview ?? (isImage ? "" : "Preview is unavailable for this existing item. Choose Edit to load the full text.")
    }
}

/// Minimal public settings surface used for dependency injection without splitting
/// the existing UserDefaults-backed store or changing any defaults.
typealias AppSettingsStore = AppSettings
