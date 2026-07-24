import SwiftUI
import SwiftData

struct HistoryListPane: View {
    @Binding var query: String
    @Binding var selectedEntity: ClipboardEntity?
    /// Pastes the selected history item (rich by default). Fired by double-click or Enter.
    /// design-app.md §2.2.1: after writing to the pasteboard, hide this app and restore the previous app to the foreground.
    let onPaste: (ClipboardEntity) -> Void
    @Query(sort: \ClipboardEntity.createdAt, order: .reverse) private var items: [ClipboardEntity]
    @Environment(\.modelContext) private var modelContext
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    @State private var filteredItems: [ClipboardEntity] = []
    @State private var indexByID: [ClipboardEntity.ID: Int] = [:]
    @State private var debounceWorkItem: DispatchWorkItem? = nil
    @State private var showDeleteConfirmation = false
    /// Background filtering task token. Cancelling the previous task when a new query
    /// arrives avoids stacking O(n) scans on the main actor (review #22).
    @State private var filterTask: Task<Void, Never>?
    /// Local key event monitor for Delete / Forward Delete. `.onKeyPress` requires
    /// focus on the ScrollView and silently beeps when unfocused (e.g., right after
    /// the window opens), so we use an app-level local monitor instead and skip
    /// handling when the search field is focused (to allow text editing).
    @State private var deleteKeyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.2)
            list
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetSelectionToTop)) { _ in
            // Reset selection to the latest (topmost) item when the window is reshown.
            if !filteredItems.isEmpty {
                selectedEntity = filteredItems.first
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyWindowDidClose)) { _ in
            // Drop search-field focus so the window does not reopen with the cursor
            // already in the search field (and so the Delete key monitor does not
            // depend on a stale `searchFocused` value). Move focus to the list so
            // the arrow keys select history entries on reopen; without this, no
            // view owns focus and arrow keys produce the system beep.
            // `MainView` clears `query` and `selectedEntity` in parallel.
            searchFocused = false
            listFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedRequested)) { _ in
            // Triggered by FooterBar's More > Delete. Routes through the same logic as
            // the Delete key so post-delete selection stays consistent across entry points.
            deleteSelected()
        }
        .onAppear {
            recomputeIndex()
            installDeleteKeyMonitor()
        }
        .onChange(of: query) { _, _ in
            debounceWorkItem?.cancel()
            scheduleRecompute()
        }
        .onChange(of: items.count) { _, _ in
            scheduleRecompute()
        }
        .onChange(of: items.first?.id) { _, _ in
            // `@Query` reflects SwiftData inserts/deletes, but when the same content is
            // re-copied `removeDuplicates` deletes the old entity and inserts a new one
            // with a different `id` while keeping `items.count` unchanged. Without this
            // observer the list filter (`filteredItems`) was never rebuilt, so the newly
            // copied item did not appear at the top even though it was persisted.
            scheduleRecompute()
        }
        .onChange(of: items.last?.id) { _, _ in
            // Tail changes catch inserts that did not become the new top (e.g. when a
            // future sort key differs) and deletions at the bottom (retention enforce).
            scheduleRecompute()
        }
        .onDisappear {
            debounceWorkItem?.cancel()
            removeDeleteKeyMonitor()
            filterTask?.cancel()
        }
        .alert("Delete this entry?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteAlertMessage)
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit {
                    // The search field is incremental, so Enter does not need to
                    // commit a query. Instead, mirror the list's Return behavior:
                    // paste the currently selected item (if any).
                    if let entity = selectedEntity {
                        paste(entity: entity)
                    }
                }
        }
        .padding(8)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.appBackground.opacity(0.8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.separatorLine, lineWidth: 1))
        )
        .padding(8)
        // Seamless arrow-key navigation from search to list (design-ui.md):
        // While the search field is focused (incremental search active), pressing
        // Up/Down moves focus to the history list and moves the selection so the
        // user does not have to click the list first. Returning .handled also
        // suppresses the system beep that would fire if the TextField received
        // arrow keys it does not consume.
        .onKeyPress(.upArrow) {
            searchFocused = false
            listFocused = true
            moveSelection(.up)
            return .handled
        }
        .onKeyPress(.downArrow) {
            searchFocused = false
            listFocused = true
            moveSelection(.down)
            return .handled
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredItems) { entity in
                        row(for: entity)
                        Divider().opacity(0.2)
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onMoveCommand { direction in
                moveSelection(direction)
            }
            .onKeyPress(.return) {
                guard let entity = selectedEntity else { return .ignored }
                paste(entity: entity)
                return .handled
            }
            .onChange(of: selectedEntity?.id) { _, id in
                guard listFocused, let id else { return }
                // When no anchor is specified, scrollTo does not scroll for already-visible rows;
                // it only scrolls just enough to bring off-screen rows into view.
                proxy.scrollTo(id)
            }
        }
    }

    @ViewBuilder
    private func row(for entity: ClipboardEntity) -> some View {
        HistoryRowView(entity: entity, selected: selectedEntity?.id == entity.id)
            .id(entity.id)
            .onTapGesture {
                selectedEntity = entity
                listFocused = true
            }
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        paste(entity: entity)
                    }
            )
    }

    private func recomputeIndex() {
        // Build a Sendable search index on the main actor (entities are @Model and
        // bound to the main actor's ModelContext), then run the O(n) filter on a
        // background task so the main actor is not blocked for 100k rows (review #22).
        let needle = query.lowercased()
        let index = items.map { entity in
            SearchRow(
                id: entity.id,
                textPreviewLower: entity.textPreviewLowercased ?? entity.textPreview?.lowercased() ?? "",
                sourceBundleIDLower: entity.sourceBundleID?.lowercased(),
                contentHashLower: entity.contentHash?.lowercased()
            )
        }
        filterTask?.cancel()
        filterTask = Task.detached(priority: .userInitiated) {
            let filteredIDs: [UUID]
            if needle.isEmpty {
                filteredIDs = index.map(\.id)
            } else {
                filteredIDs = index.compactMap { row in
                    if row.textPreviewLower.contains(needle) { return row.id }
                    if let b = row.sourceBundleIDLower, b.contains(needle) { return row.id }
                    if let h = row.contentHashLower, h.contains(needle) { return row.id }
                    return nil
                }
            }
            await MainActor.run {
                let idSet = Set(filteredIDs)
                let ordered = items.filter { idSet.contains($0.id) }
                filteredItems = ordered
                indexByID = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
                if selectedEntity.map({ indexByID[$0.id] == nil }) ?? true {
                    selectedEntity = ordered.first
                }
            }
        }
    }

    /// Schedules `recomputeIndex` after a short debounce so typing into the search
    /// field does not kick off a background scan on every keystroke.
    private func scheduleRecompute() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            recomputeIndex()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    /// Sendable search index row extracted from `ClipboardEntity` so the filter can
    /// run off the main actor without touching the `@Model` (review #22).
    private struct SearchRow: Sendable {
        let id: UUID
        let textPreviewLower: String
        let sourceBundleIDLower: String?
        let contentHashLower: String?
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !filteredItems.isEmpty else {
            selectedEntity = nil
            return
        }

        let currentIndex: Int?
        if let currentID = selectedEntity?.id {
            currentIndex = indexByID[currentID]
        } else {
            currentIndex = nil
        }
        let next: Int
        switch direction {
        case .up:
            // Already at the top: move focus back to the search field so the user
            // can keep typing / refine the query without reaching for the mouse.
            if currentIndex == 0 {
                searchFocused = true
                listFocused = false
                return
            }
            next = max((currentIndex ?? filteredItems.count) - 1, 0)
        case .down:
            next = min((currentIndex ?? -1) + 1, filteredItems.count - 1)
        default:
            return
        }
        selectedEntity = filteredItems[next]
    }

    /// Pastes the selected history on double-click / Enter.
    /// Same behavior as FooterBar.paste(rich:): writes to pasteboard, hides this app, and restores the previous app.
    /// Closes the main window after pasting (direct paste via click / Enter only).
    private func paste(entity: ClipboardEntity) {
        selectedEntity = entity
        onPaste(entity)
        NSApp.keyWindow?.close()
    }

    /// Deletes the currently selected entry after a confirmation dialog.
    /// After deletion, selection moves to the next entry (or the previous one if the
    /// deleted entry was last), so repeated Delete presses keep trimming the list.
    private func deleteSelected() {
        guard selectedEntity != nil else { return }
        showDeleteConfirmation = true
    }

    /// Alert message including a preview of the entry to be deleted (first ~100 chars).
    /// Truncates with "…" when the content is longer than 100 characters so the user
    /// can see at a glance that the preview is abbreviated.
    private var deleteAlertMessage: String {
        var lines: [String] = ["This action cannot be undone.", "Contents:"]
        if let entity = selectedEntity {
            if entity.isImage {
                lines.append("(image)")
            } else {
                let preview = entity.textPreview ?? entity.text ?? ""
                let isTruncated = preview.count > 100
                let head = String(preview.prefix(100))
                lines.append("\(head)\(isTruncated ? "…" : "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Installs an app-level local key monitor for Delete / Forward Delete.
    /// `.onKeyPress` on the ScrollView only fires while the list is focused and
    /// otherwise lets the event fall through, producing a system beep. The local
    /// monitor catches the key regardless of focus and suppresses it only when:
    ///   - the user is editing a text field (search field, Settings/Macro edit
    ///     TextFields, TextEdit sheet, etc.), OR
    ///   - no history entry is selected.
    /// The "editing a text field" guard uses the key window's `firstResponder`,
    /// not the local `searchFocused` flag, so it also releases Delete when the
    /// user is editing inside the Settings/Macro Edit window. Without this guard
    /// the monitor hijacked Delete from any other window's text field and the
    /// user could not delete characters there (history deletion fired instead).
    private func installDeleteKeyMonitor() {
        deleteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let shouldConsume: Bool = MainActor.assumeIsolated {
                // 51 = Delete (Backspace), 117 = Forward Delete (Fn+Delete)
                guard keyCode == 51 || keyCode == 117 else { return false }
                // Don't hijack Delete while a text field is being edited.
                // SwiftUI `TextField` / `TextEditor` use an `NSTextView` as the
                // first responder when focused, so this catches every text input
                // across the app (main search field, Settings, Macro Edit sheet,
                // TextEdit, etc.) regardless of which window owns it.
                if Self.isEditingText() { return false }
                guard selectedEntity != nil else { return false }
                deleteSelected()
                return true
            }
            return shouldConsume ? nil : event
        }
    }

    /// Returns `true` when the current key window's first responder is an AppKit
    /// text-editing view (`NSTextView` or any `NSText`). Used by the Delete key
    /// monitor to avoid stealing Delete while the user is editing text in any
    /// window (search field, Settings, Macro Edit, TextEdit, …).
    private static func isEditingText() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSText
    }

    private func removeDeleteKeyMonitor() {
        if let monitor = deleteKeyMonitor {
            NSEvent.removeMonitor(monitor)
            deleteKeyMonitor = nil
        }
    }

    private func confirmDelete() {
        guard let entity = selectedEntity else { return }
        let nextSelection: ClipboardEntity? = {
            guard let idx = indexByID[entity.id] else { return nil }
            if idx + 1 < filteredItems.count {
                return filteredItems[idx + 1]
            }
            return idx > 0 ? filteredItems[idx - 1] : nil
        }()
        modelContext.delete(entity)
        PersistenceController.shared?.saveContext(modelContext, purpose: "HistoryListPane.deleteSelected")
        selectedEntity = nextSelection
    }

}
