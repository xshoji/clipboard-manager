import AppKit
import Foundation

enum HistoryFilter {
    static func filter(
        _ items: [ClipboardItem],
        query: String,
        imagesOnly: Bool
    ) -> [ClipboardItem] {
        let needle = query.lowercased()
        return items.filter { item in
            guard !imagesOnly || item.isImage else { return false }
            guard !needle.isEmpty else { return true }
            if (item.textPreviewLowercased ?? item.textPreview?.lowercased() ?? "").contains(needle) {
                return true
            }
            if item.ocrTextLowercased?.contains(needle) == true { return true }
            if item.sourceBundleID?.lowercased().contains(needle) == true { return true }
            if item.contentHash?.lowercased().contains(needle) == true { return true }
            return false
        }
    }
}

@MainActor @Observable
final class HistoryViewModel {
    private let repository: ClipboardRepositoryPort
    private let pasteCoordinator: PasteCoordinator
    private var changeObserver: NSObjectProtocol?
    private var reloadTask: Task<Void, Never>?
    private var isActive = false
    var items: [ClipboardItem] = []
    var selectedItem: ClipboardItem?

    init(repository: ClipboardRepositoryPort, pasteCoordinator: PasteCoordinator) {
        self.repository = repository; self.pasteCoordinator = pasteCoordinator
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        requestReload()
        changeObserver = NotificationCenter.default.addObserver(forName: .clipboardRepositoryDidChange, object: repository, queue: .main) { [weak self] _ in
            self?.requestReload()
        }
    }

    func stop() {
        isActive = false
        reloadTask?.cancel()
        reloadTask = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
    }

    func reload() async {
        let selectedID = selectedItem?.id
        items = await repository.fetchAll()
        selectedItem = selectedID.flatMap { id in items.first { $0.id == id } } ?? items.first
    }

    private func requestReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            guard let self else { return }
            let selectedID = selectedItem?.id
            let fetchedItems = await repository.fetchAll()
            guard !Task.isCancelled else { return }
            items = fetchedItems
            selectedItem = selectedID.flatMap { id in fetchedItems.first { $0.id == id } } ?? fetchedItems.first
        }
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
    func debugMacro(macro: MacroScript, inputText: String) async throws -> MacroDebugReport { try await pasteCoordinator.debugMacro(macro: macro, inputText: inputText) }
    func copyMacroDebugReport(_ text: String) { pasteCoordinator.copyMacroDebugReport(text) }
}
