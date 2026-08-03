import SwiftUI

struct HistoryListPane: View {
    @Binding var query: String
    @Binding var selectedItem: ClipboardItem?
    @Bindable var viewModel: HistoryViewModel
    /// Pastes the selected history item (rich by default). Fired by double-click or Enter.
    /// design-app.md §2.2.1: after writing to the pasteboard, hide this app and restore the previous app to the foreground.
    let onPaste: (ClipboardItem) async -> Bool
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    @State private var filteredItems: [ClipboardItem] = []
    @State private var indexByID: [ClipboardItem.ID: Int] = [:]
    @State private var showsImagesOnly = false
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
            if !viewModel.items.isEmpty {
                selectedItem = viewModel.items.first
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyWindowDidClose)) { _ in
            // Reset transient list presentation so reopening always starts with
            // the complete history. Drop search-field focus and move focus to the
            // list so arrow keys work immediately on the next appearance.
            // `MainView` clears `query` and `selectedItem` in parallel.
            showsImagesOnly = false
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
        .onChange(of: showsImagesOnly) { _, _ in
            debounceWorkItem?.cancel()
            recomputeIndex()
        }
        // Repository notifications reflect inserts/deletes, but item count alone misses
        // the case where `removeDuplicates` deletes an old entity and inserts a new
        // one with a different `id` (count unchanged, contents changed). Observing the
        // whole `items` array catches both count-only and id-only mutations, so the
        // list filter (`filteredItems`) is always rebuilt after a re-copy / retention
        // delete / insert. The DTO array is Hashable and
        // re-renders when any element identity changes, so this is the single source
        // of truth for "did the visible list change?".
        .onChange(of: viewModel.items) { _, _ in
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
                .accessibilityIdentifier("searchField")
                .onSubmit {
                    // The search field is incremental, so Enter does not need to
                    // commit a query. Instead, mirror the list's Return behavior:
                    // paste the currently selected item (if any).
                    //
                    // Edge case: if the user typed a query whose debounce timer
                    // (`scheduleRecompute`, 200 ms) has not yet fired, `filteredItems`
                    // and `selectedEntity` may still reflect the old query. In that
                    // case `selectedEntity` might no longer be in `filteredItems` (it
                    // was filtered out) and pasting it would silently paste a row the
                    // user cannot see. To avoid this, when the current selection is
                    // not in the (already-filtered) `filteredItems` we cancel the
                    // pending debounce, kick a synchronous-ish recompute, and skip the
                    // paste — the user can press Enter again once the list refreshes.
                    // `recomputeIndex` runs the heavy filter on `Task.detached`, so it
                    // cannot block here; it will update `filteredItems` and
                    // `selectedEntity` on the main actor shortly.
                    if let entity = selectedItem, indexByID[entity.id] != nil {
                        paste(entity: entity)
                    } else {
                        debounceWorkItem?.cancel()
                        recomputeIndex()
                    }
                }
            Button {
                showsImagesOnly.toggle()
            } label: {
                Image(systemName: showsImagesOnly ? "photo.fill" : "photo")
                    .frame(width: 20, height: 20)
                    .foregroundStyle(showsImagesOnly ? Color.accentColor : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(showsImagesOnly ? Color.accentColor.opacity(0.14) : .clear)
                    )
            }
            .buttonStyle(.borderless)
            .help(showsImagesOnly ? "Show all history" : "Show images only")
            .accessibilityLabel("Show images only")
            .accessibilityValue(showsImagesOnly ? "On" : "Off")
            .accessibilityIdentifier("imageFilterButton")
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
            .accessibilityIdentifier("historyList")
            .onMoveCommand { direction in
                moveSelection(direction)
            }
            .onKeyPress(.return) {
                guard let entity = selectedItem else { return .ignored }
                paste(entity: entity)
                return .handled
            }
            .onChange(of: selectedItem?.id) { _, id in
                guard listFocused, let id else { return }
                // When no anchor is specified, scrollTo does not scroll for already-visible rows;
                // it only scrolls just enough to bring off-screen rows into view.
                proxy.scrollTo(id)
            }
        }
    }

    @ViewBuilder
    private func row(for entity: ClipboardItem) -> some View {
        HistoryRowView(entity: entity, selected: selectedItem?.id == entity.id)
            .id(entity.id)
            .onTapGesture {
                selectedItem = entity
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
        // ClipboardItem is a Sendable DTO, so filtering can run off the main actor
        // without touching SwiftData models or blocking rendering for large histories.
        let items = viewModel.items
        let query = query
        let imagesOnly = showsImagesOnly
        filterTask?.cancel()
        filterTask = Task.detached(priority: .userInitiated) {
            let filteredIDs = HistoryFilter.filter(items, query: query, imagesOnly: imagesOnly).map(\.id)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                let idSet = Set(filteredIDs)
                let ordered = viewModel.items.filter { idSet.contains($0.id) }
                filteredItems = ordered
                indexByID = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
                if selectedItem.map({ indexByID[$0.id] == nil }) ?? true {
                    selectedItem = ordered.first
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

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !filteredItems.isEmpty else {
            selectedItem = nil
            return
        }

        let currentIndex: Int?
        if let currentID = selectedItem?.id {
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
        selectedItem = filteredItems[next]
    }

    /// Pastes the selected history on double-click / Enter.
    /// Same behavior as FooterBar.paste(rich:): writes to pasteboard, hides this app, and restores the previous app.
    /// Closes the main window after pasting (direct paste via click / Enter only).
    private func paste(entity: ClipboardItem) {
        selectedItem = entity
        Task {
            if await onPaste(entity) {
                NSApp.keyWindow?.close()
            }
        }
    }

    /// Deletes the currently selected entry after a confirmation dialog.
    /// After deletion, selection moves to the next entry (or the previous one if the
    /// deleted entry was last), so repeated Delete presses keep trimming the list.
    private func deleteSelected() {
        guard selectedItem?.isCurrent == false else { return }
        showDeleteConfirmation = true
    }

    /// Alert message including a preview of the entry to be deleted (first ~100 chars).
    /// Truncates with "…" when the content is longer than 100 characters so the user
    /// can see at a glance that the preview is abbreviated.
    private var deleteAlertMessage: String {
        var lines: [String] = ["This action cannot be undone.", "Contents:"]
        if let entity = selectedItem {
            if entity.isImage {
                lines.append("(image)")
            } else {
                let preview = entity.textPreview ?? ""
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
                guard selectedItem?.isCurrent == false else { return true }
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
        guard let entity = selectedItem, !entity.isCurrent else { return }
        let nextSelection: ClipboardItem? = {
            guard let idx = indexByID[entity.id] else { return nil }
            if idx + 1 < filteredItems.count {
                return filteredItems[idx + 1]
            }
            return idx > 0 ? filteredItems[idx - 1] : nil
        }()
        viewModel.delete(id: entity.id)
        selectedItem = nextSelection
    }

}
