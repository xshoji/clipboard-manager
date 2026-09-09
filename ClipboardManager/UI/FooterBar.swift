import SwiftUI
import AppKit

struct FooterBar: View {
    @Environment(AppSettings.self) private var settings
    let selected: Binding<ClipboardItem?>
    let viewModel: HistoryViewModel
    let onEdit: (ClipboardItem) -> Void
    let onClearAll: () -> Void
    @State private var inspectorRequest: ClipboardInspectorRequest?

    var body: some View {
        HStack(spacing: 8) {
            actionButton("Paste", system: "doc.on.clipboard.fill") { paste(rich: true) }
            actionButton(
                "Plain Text",
                system: "textformat",
                disabled: selected.wrappedValue.map { !$0.isImage && !$0.canUsePlainText } ?? false,
                help: unavailablePlainTextHelp
            ) { paste(rich: false) }
            actionButton("Copy", system: "doc.on.doc") { justCopy() }
            actionButton(
                "Edit",
                system: "square.and.pencil",
                disabled: selected.wrappedValue.map { !$0.isImage && !$0.canUsePlainText } ?? false,
                help: unavailablePlainTextHelp
            ) { editSelected() }
            macroMenuButton
            Spacer()
            moreMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.appBackground.opacity(0.95))
        .overlay(alignment: .top) { Divider().opacity(0.2) }
        .sheet(item: $inspectorRequest) { request in
            ClipboardInspectorView(request: request, viewModel: viewModel)
        }
    }

    private func actionButton(
        _ title: String,
        system: String,
        disabled: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
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
        .disabled(disabled)
        .help(help ?? title)
    }

    private var macroMenuButton: some View {
        Menu {
            ForEach(settings.macroScripts) { macro in
                Button(macro.name) { runMacro(macro) }
                    .disabled(selected.wrappedValue?.isImage == true && !macro.supportsImageInput)
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
        .disabled(selected.wrappedValue.map { !$0.isImage && !$0.canUsePlainText } ?? false)
        .help(unavailablePlainTextHelp ?? "Run paste macro")
        .accessibilityIdentifier("runMacroMenu")
    }

    private var unavailablePlainTextHelp: String? {
        guard let item = selected.wrappedValue,
              !item.isImage,
              !item.canUsePlainText else { return nil }
        return "Unavailable because this HTML item has no plain-text representation."
    }

    private var moreMenu: some View {
        Menu {
            Button(selected.wrappedValue?.isPinned == true ? "Unpin" : "Pin") {
                guard let item = selected.wrappedValue else { return }
                Task { await viewModel.togglePin(item) }
            }
                .disabled(selected.wrappedValue == nil)
            Divider()
            Button("Delete") { deleteSelected() }
                .disabled(selected.wrappedValue?.isCurrent != false)
            Divider()
            Button("Clear All History") { onClearAll() }
            Divider()
            Button("Clipboard Inspector…") {
                guard let item = selected.wrappedValue else { return }
                inspectorRequest = ClipboardInspectorRequest(
                    item: item,
                    frozenCurrentInspection: viewModel.currentInspectionSnapshot(for: item)
                )
            }
                .disabled(selected.wrappedValue == nil)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .help("More")
        .accessibilityIdentifier("moreMenu")
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

}
