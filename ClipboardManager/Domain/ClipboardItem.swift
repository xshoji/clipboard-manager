import Foundation

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

    var isImage: Bool { kind == "image" }
    var displayTextPreview: String {
        textPreview ?? (isImage ? "" : "Preview is unavailable for this existing item. Choose Edit to load the full text.")
    }
}

/// Minimal public settings surface used for dependency injection without splitting
/// the existing UserDefaults-backed store or changing any defaults.
typealias AppSettingsStore = AppSettings
