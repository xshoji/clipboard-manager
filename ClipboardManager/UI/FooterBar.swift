import SwiftUI
import AppKit

struct FooterBar: View {
    @Environment(AppSettings.self) private var settings
    let selected: Binding<ClipboardItem?>
    let viewModel: HistoryViewModel
    let onEdit: (ClipboardItem) -> Void
    let onClearAll: () -> Void
    @State private var showInfo: String?

    var body: some View {
        HStack(spacing: 8) {
            actionButton("Paste", system: "doc.on.clipboard.fill") { paste(rich: true) }
            actionButton("Plain Text", system: "textformat") { paste(rich: false) }
            actionButton("Copy", system: "doc.on.doc") { justCopy() }
            actionButton("Edit", system: "square.and.pencil") { editSelected() }
            macroMenuButton
            Spacer()
            moreMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.appBackground.opacity(0.95))
        .overlay(alignment: .top) { Divider().opacity(0.2) }
    }

    private func actionButton(_ title: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: system)
                Text(title)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.footerButtonBg))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private var macroMenuButton: some View {
        Menu {
            ForEach(settings.macroScripts) { macro in
                Button(macro.name) { runMacro(macro) }
            }
            if settings.macroScripts.isEmpty {
                Text("No macros registered").foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.2.squarepath")
                Text("Run Macro")
                Image(systemName: "chevron.down").font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.footerButtonBg))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .help("Run paste macro")
        .accessibilityIdentifier("runMacroMenu")
    }

    private var moreMenu: some View {
        Menu {
            Button("Delete") { deleteSelected() }
                .disabled(selected.wrappedValue?.isCurrent != false)
            Divider()
            Button("Clear All History") { onClearAll() }
            Divider()
            Button("Item Info") {
                guard let entity = selected.wrappedValue else { return }
                Task { showInfo = await describe(entity) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .help("More")
        .accessibilityIdentifier("moreMenu")
        .alert("Item info", isPresented: .init(get: { showInfo != nil }, set: { _ in showInfo = nil })) {
            Button("OK") { showInfo = nil }
        } message: { Text(showInfo ?? "") }
    }

    private func paste(rich: Bool) {
        guard let entity = selected.wrappedValue else { return }
        // "Paste Plain" on an image entry runs OCR and pastes the recognized text.
        // Falls back to a user notification when no text is recognized (decided
        // behavior: (b)). The standard (rich) path still pastes the image as PNG.
        if !rich && entity.isImage {
            Task { @MainActor in
                await viewModel.runOcr(item: entity)
            }
            return
        }
        // PasteCoordinator records the exact output format through the race-safe monitor path.
        Task { await viewModel.pasteStandard(item: entity, rich: rich) }
    }

    private func justCopy() {
        guard let entity = selected.wrappedValue else { return }
        // Copy records the exact output like Paste without activating another app.
        Task { await viewModel.pasteStandard(item: entity, rich: true, activate: false) }
    }

    private func runMacro(_ macro: MacroScript) {
        guard let entity = selected.wrappedValue else { return }
        // On failure PasteCoordinator restores the original content according to settings.
        // MacroRunner runs on a background queue, so the main thread is not blocked (review #4).
        Task { @MainActor in
            _ = await viewModel.runMacro(macro: macro, item: entity)
        }
    }

    private func editSelected() {
        guard let entity = selected.wrappedValue else {
            return
        }
        // Routing (image → Preview.app launch, text → TextEditView sheet) is owned
        // by the injected `onEdit` closure (supplied by `MainView.edit(_:)`), so
        // this view does not reference `PreviewImageEditor` (Infrastructure)
        // directly (review #4).
        onEdit(entity)
    }

    private func deleteSelected() {
        // Defer to `HistoryListPane.deleteSelected()` via notification so the actual
        // delete + post-delete selection logic (move to the adjacent entry) lives in a
        // single place shared with the Delete key handler.
        NotificationCenter.default.post(name: .deleteSelectedRequested, object: nil)
    }

    private func describe(_ entity: ClipboardItem) async -> String {
        var s = "Kind: \(entity.kind)\n"
        if entity.isCurrent { s = "Item: Current Clipboard\n" + s }
        s += "Created: \(entity.createdAt)\n"
        if let b = entity.sourceBundleID { s += "Source: \(b)\n" }
        if let h = entity.contentHash { s += "Hash: \(h)\n" }
        if let count = entity.textCharacterCount { s += "Length: \(count) chars\n" }
        if entity.isHtml { s += "Format: HTML\n" }
        if let count = await viewModel.itemByteCount(id: entity.id) { s += "Size: \(count) bytes\n" }
        return s
    }
}
