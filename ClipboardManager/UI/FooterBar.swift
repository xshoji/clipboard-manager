import SwiftUI
import AppKit

struct FooterBar: View {
    @Environment(AppSettings.self) private var settings
    let selected: Binding<ClipboardEntity?>
    let onEdit: (ClipboardEntity) -> Void
    let onClearAll: () -> Void
    @State private var showMacroMenu: Bool = false
    @State private var showMoreMenu: Bool = false
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
    }

    private var moreMenu: some View {
        Menu {
            Button("Delete") { deleteSelected() }
            Divider()
            Button("Clear All History") { onClearAll() }
            Divider()
            Button("Item Info") { showInfo = selected.wrappedValue.map { describe($0) } }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .help("More")
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
                await OcrPasteService.run(entity: entity, settings: settings)
            }
            return
        }
        // Register a suppression range BEFORE the write so the utility-queue poll cannot
        // race with the pasteboard write and save our own write as a history item (review #6).
        let pre = NSPasteboard.general.changeCount
        ClipboardMonitor.shared?.suppressChangeCountRange((pre + 1)..<(pre + 3))
        entity.writeToPasteboard(.general, rich: rich)
        // Do not add pasteboard writes made by this app itself to the clipboard history
        // (prevents ClipboardMonitor from mistaking a changeCount change as a new copy).
        ClipboardMonitor.shared?.finalizeSuppressionAfterWrite(preChangeCount: pre)
        AppActivator.shared.activatePreviousAppAndPasteSynthetically(
            needsSynthetic: settings.needsAccessibilityForSyntheticPaste
        )
    }

    private func justCopy() {
        guard let entity = selected.wrappedValue else { return }
        // Register a suppression range BEFORE the write (review #6 race note).
        let pre = NSPasteboard.general.changeCount
        ClipboardMonitor.shared?.suppressChangeCountRange((pre + 1)..<(pre + 3))
        entity.writeToPasteboard(.general)
        // Do not add pasteboard writes made by this app itself to the clipboard history
        // (prevents ClipboardMonitor from mistaking a changeCount change as a new copy).
        ClipboardMonitor.shared?.finalizeSuppressionAfterWrite(preChangeCount: pre)
    }

    private func runMacro(_ macro: MacroScript) {
        guard let entity = selected.wrappedValue else { return }
        // remaining-features #6: on failure MacroPasteService restores the original content to the pasteboard and returns to the previous app.
        // MacroRunner runs on a background queue, so the main thread is not blocked (review #4).
        Task { @MainActor in
            _ = await MacroPasteService.run(macro: macro, entity: entity, settings: settings)
        }
    }

    private func editSelected() {
        guard let entity = selected.wrappedValue else {
            return
        }
        if entity.isImage {
            PreviewImageEditor.shared.editImage(entity: entity)
        } else {
            onEdit(entity)
        }
    }

    private func deleteSelected() {
        // Defer to `HistoryListPane.deleteSelected()` via notification so the actual
        // delete + post-delete selection logic (move to the adjacent entry) lives in a
        // single place shared with the Delete key handler.
        NotificationCenter.default.post(name: .deleteSelectedRequested, object: nil)
    }

    private func describe(_ entity: ClipboardEntity) -> String {
        var s = "Kind: \(entity.kind)\n"
        s += "Created: \(entity.createdAt)\n"
        if let b = entity.sourceBundleID { s += "Source: \(b)\n" }
        if let h = entity.contentHash { s += "Hash: \(h)\n" }
        if let count = entity.textCharacterCount { s += "Length: \(count) chars\n" }
        if let d = entity.imageData { s += "Image size: \(d.count) bytes\n" }
        return s
    }
}
