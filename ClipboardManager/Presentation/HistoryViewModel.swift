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
    private let currentReader: CurrentClipboardReading
    private var changeObserver: NSObjectProtocol?
    private var reloadTask: Task<Void, Never>?
    private var isActive = false
    private var lastCurrentChangeCount = Int.min
    var items: [ClipboardItem] = []
    private(set) var historyItems: [ClipboardItem] = []
    private(set) var currentSnapshot: CurrentClipboardSnapshot?
    var selectedItem: ClipboardItem?

    init(repository: ClipboardRepositoryPort, pasteCoordinator: PasteCoordinator, currentReader: CurrentClipboardReading) {
        self.repository = repository; self.pasteCoordinator = pasteCoordinator; self.currentReader = currentReader
        currentReader.setCurrentClipboardHandler { [weak self] observation in
            Task { @MainActor in self?.applyCurrent(observation) }
        }
    }

    convenience init(repository: ClipboardRepositoryPort, pasteCoordinator: PasteCoordinator) {
        self.init(repository: repository, pasteCoordinator: pasteCoordinator,
            currentReader: EmptyCurrentClipboardReader())
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
        historyItems = await repository.fetchAll()
        rebuildItems()
        selectedItem = selectedID.flatMap { id in items.first { $0.id == id } } ?? items.first
    }

    private func requestReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            guard let self else { return }
            let selectedID = selectedItem?.id
            let fetchedItems = await repository.fetchAll()
            guard !Task.isCancelled else { return }
            historyItems = fetchedItems
            rebuildItems()
            selectedItem = selectedID.flatMap { id in items.first { $0.id == id } } ?? items.first
        }
    }
    private func applyCurrent(_ observation: CurrentClipboardObservation) {
        guard observation.changeCount >= lastCurrentChangeCount else { return }
        lastCurrentChangeCount = observation.changeCount
        let followedCurrent = selectedItem?.isCurrent == true
        currentSnapshot = observation.snapshot
        rebuildItems()
        if followedCurrent { selectedItem = items.first }
        else if let id = selectedItem?.id { selectedItem = items.first { $0.id == id } ?? items.first }
        else { selectedItem = items.first }
    }
    private func rebuildItems() {
        guard let currentSnapshot else { items = historyItems; return }
        var removedMatchingCurrent = false
        var matchingHistory: ClipboardItem?
        let previousItems = historyItems.filter { item in
            guard !removedMatchingCurrent, item.contentHash == currentSnapshot.contentHash else { return true }
            removedMatchingCurrent = true
            matchingHistory = item
            return false
        }
        items = [currentSnapshot.clipboardItem(matchingHistory: matchingHistory)] + previousItems
    }
    @discardableResult func refreshCurrentClipboard() async -> CurrentClipboardSnapshot? {
        guard let observation = await currentReader.currentClipboardObservation() else { return nil }
        applyCurrent(observation)
        return observation.snapshot
    }

    /// Resolves every action through one freshness policy. A displayed top row is
    /// treated as Current Clipboard even when persistence or UI refresh has not yet
    /// replaced the previous top history row.
    func resolveActionTarget(
        for item: ClipboardItem? = nil,
        preferCurrent: Bool = false
    ) async -> ClipboardActionTarget? {
        let candidate = item ?? selectedItem
        let shouldResolveCurrent = preferCurrent
            || candidate?.isCurrent == true
            || candidate?.id == items.first?.id

        if shouldResolveCurrent, let snapshot = await refreshCurrentClipboard() {
            return .current(snapshot)
        }

        if let candidate,
           !candidate.isCurrent,
           items.contains(where: { $0.id == candidate.id }) {
            return .history(candidate)
        }
        guard let fallback = items.first, !fallback.isCurrent else { return nil }
        return .history(fallback)
    }

    func refreshAndSelectLatest() async {
        _ = await refreshCurrentClipboard()
        selectedItem = items.first
    }
    func select(_ item: ClipboardItem?) { selectedItem = item }
    func delete(id: UUID) { if id != CurrentClipboardSnapshot.currentID { repository.delete(id: id) } }
    func fullText(id: UUID) async -> String? { id == CurrentClipboardSnapshot.currentID ? currentSnapshot?.text : await repository.fetchFullText(id: id) }
    func imageData(id: UUID) async -> Data? { id == CurrentClipboardSnapshot.currentID ? currentSnapshot?.imageData : await repository.fetchImageData(id: id) }
    func imageByteCount(id: UUID) async -> Int? { id == CurrentClipboardSnapshot.currentID ? currentSnapshot?.imageData?.count : await repository.fetchImageData(id: id)?.count }
    func itemByteCount(id: UUID) async -> Int? {
        if id == CurrentClipboardSnapshot.currentID { return currentSnapshot?.byteCount }
        if let item = items.first(where: { $0.id == id }), let byteCount = item.payloadByteCount {
            return byteCount
        }
        if let image = await repository.fetchImageData(id: id) { return image.count }
        return await repository.fetchFullText(id: id)?.utf8.count
    }
    @discardableResult func saveText(_ text: String) -> Bool { repository.insert(.init(kind: "text", text: text, contentHash: HashUtil.sha256Hex(of: Data(text.utf8))), removingDuplicates: false, purpose: "TextEditView.saveAsNew") }
    @discardableResult func pasteStandard(item: ClipboardItem, rich: Bool, activate: Bool = true) async -> Bool {
        guard let target = await resolveActionTarget(for: item) else { return false }
        switch target {
        case .current(let snapshot):
            return pasteCoordinator.pasteStandard(snapshot: snapshot, rich: rich, activate: activate)
        case .history(let historyItem):
            return await pasteCoordinator.pasteStandard(item: historyItem, rich: rich, activate: activate)
        }
    }
    func runOcr(item: ClipboardItem) async {
        guard let target = await resolveActionTarget(for: item) else { return }
        switch target {
        case .current(let snapshot):
            let matchingHistory = historyItems.first { $0.contentHash == snapshot.contentHash }
            await pasteCoordinator.runOcr(snapshot: snapshot, matchingHistory: matchingHistory)
        case .history(let historyItem):
            await pasteCoordinator.runOcr(item: historyItem)
        }
    }
    @discardableResult func runMacro(macro: MacroScript, item: ClipboardItem) async -> Bool {
        guard let target = await resolveActionTarget(for: item) else { return false }
        return await runMacro(macro: macro, target: target)
    }
    @discardableResult func runMacro(macro: MacroScript, target: ClipboardActionTarget) async -> Bool {
        switch target {
        case .current(let snapshot):
            return await pasteCoordinator.runMacro(macro: macro, snapshot: snapshot)
        case .history(let historyItem):
            return await pasteCoordinator.runMacro(macro: macro, item: historyItem)
        }
    }
    func debugMacro(macro: MacroScript, inputText: String) async throws -> MacroDebugReport { try await pasteCoordinator.debugMacro(macro: macro, inputText: inputText) }
    func copyMacroDebugReport(_ text: String) { pasteCoordinator.copyMacroDebugReport(text) }
}
