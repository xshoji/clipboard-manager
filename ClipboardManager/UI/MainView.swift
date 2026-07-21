import SwiftUI
import SwiftData

struct MainView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @State private var selectedEntity: ClipboardEntity? = nil
    @State private var query: String = ""
    let focusSearch: Bool
    let onClearHistory: () -> Void
    let onShowSettings: () -> Void
    @State private var editingEntity: ClipboardEntity?
    @State private var sidebarVisible: Bool
   @State private var macroPickerPresented: Bool = false

    init(
        focusSearch: Bool,
        onClearHistory: @escaping () -> Void,
        onShowSettings: @escaping () -> Void
    ) {
        self.focusSearch = focusSearch
        self.onClearHistory = onClearHistory
        self.onShowSettings = onShowSettings
        _sidebarVisible = State(initialValue: AppSettings.shared.isSidebarVisible)
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(sidebarVisible: $sidebarVisible, onShowSettings: onShowSettings)
            Divider().opacity(0.2)
            content
            Divider().opacity(0.2)
            FooterBar(
                selected: $selectedEntity,
                onEdit: { entity in editingEntity = entity },
                onClearAll: onClearHistory
            )
        }
        .background(Color.appBackground)
        .onExitCommand {
            // Esc dismisses the history window (design-ui.md §1: "disappears on blur or Esc").
            // Close the window first (triggers windowWillClose → .accessory policy and
            // window-scoped hotkey teardown), then hide this app and restore the
            // previously-frontmost app so focus naturally returns to the user's editor
            // instead of lingering on ClipboardManager.
            NSApp.keyWindow?.close()
            AppActivator.shared.activatePreviousApp()
        }
       .overlay {
           if macroPickerPresented {
               MacroPickerOverlay(
                   macros: settings.macroScripts,
                   onSelect: { macro in
                       macroPickerPresented = false
                       runMacro(macro)
                   },
                   onCancel: { macroPickerPresented = false }
               )
               .transition(.opacity)
           }
       }
       .animation(.easeOut(duration: 0.12), value: macroPickerPresented)
        .sheet(item: $editingEntity) { entity in
            TextEditView(original: entity)
        }
        .onChange(of: selectedEntity?.id) { _, id in
            AppState.shared.selectedEntityID = id
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyWindowDidClose)) { _ in
            // The history window is being closed. Reset the in-window state now so
            // the *next* time the window is shown the user starts from a fresh
            // list (no search query, no stale selection). Doing this on close
            // rather than on reopen avoids flashing the previous search results
            // for a frame and showing the detail of a filtered-list item.
            // The selection itself is moved back to the latest entry on reopen
            // via `.resetSelectionToTop` (posted by `AppDelegate.showMainWindow`).
            query = ""
            selectedEntity = nil
        }
        .onAppear {
            AppState.shared.selectedEntityID = selectedEntity?.id
        }
        .onReceive(NotificationCenter.default.publisher(for: .editActionTriggered)) { note in
            // Triggered by the Edit action hotkey ( window-scoped ). Mirrors `FooterBar.editSelected` behavior.
            guard let entity = note.object as? ClipboardEntity else { return }
            if entity.isImage {
                PreviewImageEditor.shared.editImage(entity: entity)
            } else {
                editingEntity = entity
            }
        }
       .onReceive(NotificationCenter.default.publisher(for: .macroPickerTriggered)) { _ in
           // Cmd+M (default) while the history window is visible. Toggle so Cmd+M both
           // opens and closes the overlay. Beep if no entity is selected (AppDelegate
           // already guards this, but double-check here for safety).
           guard selectedEntity != nil else {
               NSSound.beep()
               return
           }
           macroPickerPresented.toggle()
       }
    }

    /// Direct paste from the history list (double-click / Enter).
    /// Same as FooterBar.paste(rich:): writes to pasteboard, hides this app, and restores the previous app.
    /// If `needsAccessibilityForSyntheticPaste` is ON, also sends a synthetic Cmd+V to finish pasting.
    private func pasteStandard(entity: ClipboardEntity, rich: Bool) {
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

   /// Runs the given Macro against the currently selected entity (used by the
   /// Macro Picker overlay's Enter handler). Mirrors `FooterBar.runMacro` and
   /// `AppDelegate.runMacroFromHotkey`: Macro execution is offloaded to a
   /// background Task so the main thread is not blocked (review #4), and
   /// `MacroPasteService` handles success / failure fallback.
   private func runMacro(_ macro: MacroScript) {
       guard let entity = selectedEntity else { return }
       Task { @MainActor in
           _ = await MacroPasteService.run(macro: macro, entity: entity, settings: settings)
       }
   }

    @ViewBuilder
    private var content: some View {
        if settings.isSplitView {
            HStack(spacing: 0) {
                if sidebarVisible {
                    HistoryListPane(
                        query: $query,
                        selectedEntity: $selectedEntity,
                        onPaste: { entity in pasteStandard(entity: entity, rich: true) }
                    )
                    .frame(maxWidth: .infinity)
                    .background(Color.appBackground.opacity(0.6))
                }
                PreviewPane(entity: selectedEntity, wrapMode: settings.previewWrapMode)
                .frame(maxWidth: .infinity)
            }
        } else {
            PreviewPane(entity: selectedEntity, wrapMode: settings.previewWrapMode)
        }
    }
}
