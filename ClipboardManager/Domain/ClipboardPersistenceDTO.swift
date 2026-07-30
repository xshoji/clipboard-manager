import Foundation

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
    let kind: String
    var text: String? = nil
    var richText: Data? = nil
    var html: Data? = nil
    var imageData: Data? = nil
    var thumbnail: Data? = nil
    var sourceBundleID: String? = nil
    var contentHash: String? = nil
}
