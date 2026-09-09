import Foundation

enum ClipboardRepresentationFormat: String, Sendable, Hashable {
    case plainText
    case html
    case richText
    case rtf
    case rtfd
    case png
    case tiff
}

enum ClipboardRepresentationOrigin: String, Sendable, Hashable {
    case source
    case derived
    case normalized
    case stored
}

struct ClipboardRepresentationInspection: Sendable, Hashable {
    let format: ClipboardRepresentationFormat
    let typeIdentifier: String?
    let byteCount: Int
    let origin: ClipboardRepresentationOrigin
}

struct ClipboardTextMetrics: Sendable, Hashable {
    let characterCount: Int
    let lineCount: Int
    let utf8ByteCount: Int
    let utf16CodeUnitCount: Int

    init(text: String) {
        characterCount = text.count
        lineCount = text.isEmpty ? 0 : 1 + text.lazy.filter(\.isNewline).count
        utf8ByteCount = text.utf8.count
        utf16CodeUnitCount = text.utf16.count
    }
}

struct ClipboardImageMetrics: Sendable, Hashable {
    let pixelWidth: Int
    let pixelHeight: Int
    let typeIdentifier: String?
}

struct ClipboardInspection: Sendable, Hashable {
    let id: UUID
    let isCurrent: Bool
    let createdAt: Date
    let kind: String
    let sourceBundleID: String?
    let contentHash: String?
    let representations: [ClipboardRepresentationInspection]
    let declaredTypeIdentifiers: [String]?
    let textMetrics: ClipboardTextMetrics?
    let imageMetrics: ClipboardImageMetrics?
    let ocrStatus: String?
    let ocrCharacterCount: Int?
}
