import Foundation

enum ClipboardTextAvailability: String, Sendable, Hashable {
    case available
    case extracted
    case unavailable
    case unknown

    var canUsePlainText: Bool { self != .unavailable }
}

/// Text payload returned by the persistence boundary when an action needs full
/// (non-preview) clipboard text. The fields are nullable so the same DTO covers
/// both the plain-text-only path and the rich-text+HTML path.
///
/// Lives in Domain so both ApplicationServices (`PasteCoordinator`) and
/// Infrastructure (`ClipboardDataActor`) can depend on it without creating an
/// Infrastructure -> ApplicationServices dependency.
struct ClipboardTextContent: Sendable {
    let text: String?
    let richText: Data?
    let html: Data?
    let textAvailability: ClipboardTextAvailability

    init(
        text: String?,
        richText: Data?,
        html: Data?,
        textAvailability: ClipboardTextAvailability? = nil
    ) {
        self.text = text
        self.richText = richText
        self.html = html
        self.textAvailability = textAvailability
            ?? (text?.isEmpty == false ? .available : .unavailable)
    }

    var canUsePlainText: Bool {
        text?.isEmpty == false && textAvailability.canUsePlainText
    }
    var canRichPaste: Bool {
        canUsePlainText || richText?.isEmpty == false || html?.isEmpty == false
    }
}

/// Persisted OCR state fetched independently from the lightweight history DTO.
/// The original text casing is retained for paste, while list search uses its
/// separately mapped lowercase value.
struct ClipboardOcrResult: Sendable {
    let status: String?
    let text: String?
}

/// Write payload used to insert a new clipboard history entry. Image and text
/// payloads share one DTO; nullable fields carry only the relevant subset per
/// `kind`.
///
/// Lives in Domain for the same reason as `ClipboardTextContent`: both
/// ApplicationServices (`ClipboardRepository`) and Infrastructure
/// (`ClipboardMonitor`, `PreviewImageEditor`) reference it without creating a
/// reverse dependency on ApplicationServices.
struct NewClipboardItem: Sendable {
    var id: UUID = UUID()
    let kind: String
    var text: String? = nil
    var richText: Data? = nil
    var html: Data? = nil
    var imageData: Data? = nil
    var thumbnail: Data? = nil
    var sourceBundleID: String? = nil
    var contentHash: String? = nil
    var ocrStatus: String? = nil
    var textAvailability: ClipboardTextAvailability? = nil
}

/// Complete, non-persisted representation of the pasteboard at one change count.
/// The fixed ID represents the virtual "Current Clipboard" row across updates.
struct CurrentClipboardSnapshot: Identifiable, Sendable {
    static let currentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    let id: UUID
    let changeCount: Int
    let observedAt: Date
    let kind: String
    let text: String?
    let richText: Data?
    let html: Data?
    let imageData: Data?
    let thumbnail: Data?
    let sourceBundleID: String?
    let contentHash: String
    let textAvailability: ClipboardTextAvailability

    init(changeCount: Int, observedAt: Date = Date(), kind: String, text: String? = nil,
         richText: Data? = nil, html: Data? = nil, imageData: Data? = nil,
         thumbnail: Data? = nil, sourceBundleID: String? = nil, contentHash: String,
         textAvailability: ClipboardTextAvailability? = nil) {
        id = Self.currentID
        self.changeCount = changeCount
        self.observedAt = observedAt
        self.kind = kind
        self.text = text
        self.richText = richText
        self.html = html
        self.imageData = imageData
        self.thumbnail = thumbnail
        self.sourceBundleID = sourceBundleID
        self.contentHash = contentHash
        self.textAvailability = textAvailability
            ?? (kind == "image" ? .unknown : (text?.isEmpty == false ? .available : .unavailable))
    }

    var isImage: Bool { kind == "image" }
    var canUsePlainText: Bool { isImage || textAvailability.canUsePlainText }
    var byteCount: Int { imageData?.count ?? html?.count ?? richText?.count ?? text?.utf8.count ?? 0 }

    func clipboardItem(matchingHistory: ClipboardItem? = nil) -> ClipboardItem {
        let builtPreview = text.map(TextPreviewBuilder.build(from:))
        let preview = builtPreview?.text
        return ClipboardItem(id: id, createdAt: observedAt, kind: kind,
            textPreview: preview, textPreviewLowercased: preview?.lowercased(),
            isTextPreviewTruncated: builtPreview?.isTruncated ?? false,
            textCharacterCount: text?.count, thumbnail: thumbnail, isHtml: html != nil,
            textAvailability: textAvailability,
            payloadByteCount: byteCount,
            sourceBundleID: sourceBundleID, contentHash: contentHash,
            ocrTextLowercased: matchingHistory?.ocrTextLowercased)
    }

    func newClipboardItem() -> NewClipboardItem {
        NewClipboardItem(kind: kind, text: text, richText: richText, html: html,
            imageData: imageData, thumbnail: thumbnail, sourceBundleID: sourceBundleID,
            contentHash: contentHash, textAvailability: textAvailability)
    }
}

/// One stable observation of the pasteboard. A nil snapshot with a newer change
/// count explicitly clears Current Clipboard for concealed or unsupported content.
struct CurrentClipboardObservation: Sendable {
    let changeCount: Int
    let snapshot: CurrentClipboardSnapshot?
}

/// Fully resolved input for an action. Current Clipboard carries its immutable
/// payload, while persisted history retains the lightweight repository-backed DTO.
enum ClipboardActionTarget: Sendable {
    case current(CurrentClipboardSnapshot)
    case history(ClipboardItem)

    var canRunMacro: Bool {
        switch self {
        case .current(let snapshot): snapshot.isImage || snapshot.canUsePlainText
        case .history(let item): item.isImage || item.canUsePlainText
        }
    }
}
