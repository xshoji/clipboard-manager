import AppKit
import Foundation

@MainActor @Observable
final class HistoryViewModel {
    private let repository: ClipboardRepositoryPort
    private let pasteCoordinator: PasteCoordinator
    private var changeObserver: NSObjectProtocol?
    private var isActive = false
    var items: [ClipboardItem] = []
    var selectedItem: ClipboardItem?

    init(repository: ClipboardRepositoryPort, pasteCoordinator: PasteCoordinator) {
        self.repository = repository; self.pasteCoordinator = pasteCoordinator
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        Task { await reload() }
        changeObserver = NotificationCenter.default.addObserver(forName: .clipboardRepositoryDidChange, object: repository, queue: .main) { [weak self] _ in
            Task { await self?.reload() }
        }
    }

    func stop() {
        isActive = false
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
    }

    func reload() async {
        let selectedID = selectedItem?.id
        items = await repository.fetchAll()
        selectedItem = selectedID.flatMap { id in items.first { $0.id == id } } ?? items.first
    }
    func select(_ item: ClipboardItem?) { selectedItem = item }
    func delete(id: UUID) { repository.delete(id: id) }
    func fullText(id: UUID) async -> String? { await repository.fetchFullText(id: id) }
    func imageData(id: UUID) async -> Data? { await repository.fetchImageData(id: id) }
    func htmlContent(id: UUID) async -> Data? { await repository.fetchHtmlContent(id: id) }
    func imageByteCount(id: UUID) async -> Int? { await repository.fetchImageData(id: id)?.count }
    @discardableResult func saveText(_ text: String) -> Bool { repository.insert(.init(kind: "text", text: text, contentHash: HashUtil.sha256Hex(of: Data(text.utf8))), removingDuplicates: false, purpose: "TextEditView.saveAsNew") }
    @discardableResult func pasteStandard(item: ClipboardItem, rich: Bool, activate: Bool = true) async -> Bool { await pasteCoordinator.pasteStandard(item: item, rich: rich, activate: activate) }
    func runOcr(item: ClipboardItem) async { await pasteCoordinator.runOcr(item: item) }
    @discardableResult func runMacro(macro: MacroScript, item: ClipboardItem) async -> Bool { await pasteCoordinator.runMacro(macro: macro, item: item) }
}
