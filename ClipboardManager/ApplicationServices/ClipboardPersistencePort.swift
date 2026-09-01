import Foundation

/// Port protocol that abstracts the persistence layer (SwiftData container,
/// model context IO, limits enforcement, and background reads) used by
/// `ClipboardRepository`.
///
/// Architecture intent:
/// - `ClipboardRepository` (ApplicationServices) depends on this port and is
///   injected with a concrete adapter at composition time. It no longer owns or
///   directly constructs `PersistenceController` / `ClipboardDataActor`
///   (Infrastructure), eliminating the ApplicationServices -> Infrastructure
///   dependency.
/// - The concrete adapter (`ClipboardPersistenceAdapter`) lives in
///   Infrastructure and conforms to this protocol, so the dependency direction
///   stays Infrastructure -> ApplicationServices port (inward).
/// - DTOs returned by the port (`ClipboardItem`, `ClipboardTextContent`,
///   `NewClipboardItem`) live in Domain, so neither layer introduces a reverse
///   dependency.
@MainActor
protocol ClipboardPersistencePort: AnyObject {
    /// Light-weight history DTOs newest-first, bounded by `limit`.
    func fetchAll(limit: Int) async -> [ClipboardItem]

    /// Single-row DTO lookup by id. `async` for consistency with the other
    /// read APIs (off-main via `@ModelActor`).
    func fetch(id: UUID) async -> ClipboardItem?

    /// Full text payload for paste. `includeRich` gates rich-text and HTML.
    func fetchTextContent(id: UUID, includeRich: Bool) async -> ClipboardTextContent?

    /// Raw HTML bytes for isolated formatted-preview rendering.
    func fetchHTMLData(id: UUID) async -> Data?

    /// Raw image bytes for paste / OCR / macro / edit.
    func fetchImageData(id: UUID) async -> Data?

    /// Full plain text for macro input.
    func fetchFullText(id: UUID) async -> String?

    /// Persisted OCR text and processing status for cache-aware image text paste.
    func fetchOcrResult(id: UUID) async -> ClipboardOcrResult?

    /// Inserts a new entity and deletes older entities sharing the same
    /// `contentHash` when `removingDuplicates` is true. Persists immediately.
    /// Returns `true` on successful save.
    @discardableResult
    func insert(_ item: NewClipboardItem, removingDuplicates: Bool, purpose: String) -> Bool

    /// Stores the terminal automatic-OCR result for an existing image row.
    /// A nil text value records that recognition completed without searchable text.
    @discardableResult
    func updateOcrResult(id: UUID, text: String?) -> Bool

    /// Deletes the entity with the given id. Returns `true` on success.
    @discardableResult
    func delete(id: UUID) -> Bool

    /// Deletes every entity. Returns `true` on success.
    @discardableResult
    func clearAll() -> Bool

    /// Starts observing settings changes affecting limits. Called by
    /// `ClipboardRepository.start()`.
    func startObservingSettings()

    /// Flushes pending changes to disk at termination.
    func flushOnTerminate()

    /// Registers a callback invoked when limits enforcement deletes rows.
    /// `ClipboardRepository` wires this to its change-notification so history
    /// observers refresh when enforcement trims rows.
    var onLimitsDidDelete: (() -> Void)? { get set }
}
