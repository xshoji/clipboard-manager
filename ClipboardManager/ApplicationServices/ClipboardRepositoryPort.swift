import Foundation

/// Port protocol that defines the persistence boundary for clipboard history.
///
/// `ClipboardRepository` (ApplicationServices) is the concrete implementation.
/// Infrastructure modules that need to write to history (`ClipboardMonitor`,
/// `PreviewImageEditor`) depend on this protocol instead of the concrete class,
/// so the dependency direction stays inward (Infrastructure → ApplicationServices
/// port, not Infrastructure → ApplicationServices concrete type).
@MainActor
protocol ClipboardRepositoryPort: AnyObject {
    func fetchAll() async -> [ClipboardItem]
    func fetch(id: UUID) -> ClipboardItem?
    func fetchTextContent(id: UUID, includeRichText: Bool) async -> ClipboardRepository.TextContent?
    func fetchImageData(id: UUID) async -> Data?
    func fetchFullText(id: UUID) async -> String?
    @discardableResult
    func insert(_ item: ClipboardRepository.NewItem, removingDuplicates: Bool, purpose: String) -> Bool
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
    func insert(_ item: ClipboardRepository.NewItem, removingDuplicates: Bool, purpose: String) -> Bool
}
