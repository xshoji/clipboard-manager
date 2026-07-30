import Foundation

/// Port protocol that defines the persistence boundary for clipboard history.
///
/// `ClipboardRepository` (ApplicationServices) is the concrete implementation.
/// Infrastructure modules that need to write to history (`ClipboardMonitor`,
/// `PreviewImageEditor`) depend on this protocol instead of the concrete class,
/// so the dependency direction stays inward (Infrastructure -> ApplicationServices
/// port, not Infrastructure -> ApplicationServices concrete type).
///
/// DTOs (`ClipboardItem`, `ClipboardTextContent`, `NewClipboardItem`) live in
/// Domain so both ApplicationServices and Infrastructure can reference them
/// without creating a reverse Infrastructure -> ApplicationServices dependency.
@MainActor
protocol ClipboardRepositoryPort: AnyObject {
    func fetchAll() async -> [ClipboardItem]
    func fetch(id: UUID) async -> ClipboardItem?
    func fetchTextContent(id: UUID, includeRich: Bool) async -> ClipboardTextContent?
    func fetchImageData(id: UUID) async -> Data?
    func fetchFullText(id: UUID) async -> String?
    func fetchHtmlContent(id: UUID) async -> Data?
    @discardableResult
    func insert(_ item: NewClipboardItem, removingDuplicates: Bool, purpose: String) -> Bool
    @discardableResult
    func delete(id: UUID) -> Bool
    @discardableResult
    func clearAll() -> Bool
}

/// Write-only subset of `ClipboardRepositoryPort` used by Infrastructure modules
/// (`ClipboardMonitor`, `PreviewImageEditor`) that only need to insert history.
/// Splitting the read surface from the write surface keeps the Infrastructure
/// dependency narrow and intentional.
@MainActor
protocol ClipboardHistoryWriting: AnyObject {
    @discardableResult
    func insert(_ item: NewClipboardItem, removingDuplicates: Bool, purpose: String) -> Bool
}
