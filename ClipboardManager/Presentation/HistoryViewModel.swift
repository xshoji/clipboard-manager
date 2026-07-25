import AppKit
import Foundation

@MainActor @Observable
final class HistoryViewModel {
    private let repository: ClipboardRepository
    private let pasteCoordinator: PasteCoordinator
    private var changeObserver: NSObjectProtocol?
    private var isActive = false
    var items: [ClipboardItem] = []
    var selectedItem: ClipboardItem?

    init(repository: ClipboardRepository, pasteCoordinator: PasteCoordinator) {
        self.repository = repository; self.pasteCoordinator = pasteCoordinator
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        reload()
        changeObserver = NotificationCenter.default.addObserver(forName: .clipboardRepositoryDidChange, object: repository, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func stop() {
        isActive = false
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
    }

    func reload() {
        let selectedID = selectedItem?.id
        items = repository.fetchAll()
        selectedItem = selectedID.flatMap { id in items.first { $0.id == id } } ?? items.first
    }
    func select(_ item: ClipboardItem?) { selectedItem = item }
    func delete(id: UUID) { repository.delete(id: id) }
    func fullText(id: UUID) -> String? { repository.fetchFullText(id: id) }
    func imageData(id: UUID) -> Data? { repository.fetchImageData(id: id) }
    func imageByteCount(id: UUID) -> Int? { repository.fetchImageData(id: id)?.count }
    @discardableResult func saveText(_ text: String) -> Bool { repository.insert(.init(kind: "text", text: text, contentHash: HashUtil.sha256Hex(of: Data(text.utf8))), purpose: "TextEditView.saveAsNew") }
    @discardableResult func pasteStandard(item: ClipboardItem, rich: Bool, activate: Bool = true) -> Bool { pasteCoordinator.pasteStandard(item: item, rich: rich, activate: activate) }
    func runOcr(item: ClipboardItem) async { await pasteCoordinator.runOcr(item: item) }
    @discardableResult func runMacro(macro: MacroScript, item: ClipboardItem) async -> Bool { await pasteCoordinator.runMacro(macro: macro, item: item) }
}
