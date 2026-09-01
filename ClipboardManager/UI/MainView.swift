import AppKit
import SwiftUI

struct MainView: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var viewModel: HistoryViewModel
    @State private var query: String = ""
    let focusSearch: Bool
    let onClearHistory: () -> Void
    let onShowSettings: () -> Void
    /// Restores the previously-frontmost application after the history window
    /// closes (Esc path). Injected by `MainWindowCoordinator` so this view does
    /// not reference `AppActivator` (Infrastructure) directly — the same
    /// "UI must not know side-effecting Infrastructure" rule applied to
    /// `PasteCoordinator`'s `AppActivating` port (review #4).
    let onActivatePreviousApp: () -> Void
    /// Launches Preview.app to edit the given image history item. Injected by
    /// `MainWindowCoordinator` so this view (and `FooterBar`) do not reference
    /// `PreviewImageEditor` (Infrastructure) directly. The text-edit path stays
    /// in this view via the `editingItem` sheet — only the image-edit side
    /// effect is hoisted out (review #4).
    let onEditImage: (ClipboardItem) -> Void
    let onEditCurrentImage: (CurrentClipboardSnapshot) -> Void
    @State private var editingItem: ClipboardItem?
    @State private var editingCurrentText: String?
    @State private var sidebarVisible: Bool
    @State private var macroPickerPresented: Bool = false
    @State private var fixedMacroTarget: ClipboardActionTarget?
    @State private var macroPreparationID: UUID?
    @State private var isOcrInProgress: Bool = false
    /// Responder that owned keyboard focus before the Macro Picker overlay was
    /// shown. Restored on dismiss so focus does not get "lost" after Esc (the
    /// overlay's `@FocusState` release leaves no responder owning the key loop).
    @State private var responderBeforePicker: NSResponder? = nil

    init(
        focusSearch: Bool,
        viewModel: HistoryViewModel,
        onClearHistory: @escaping () -> Void,
        onShowSettings: @escaping () -> Void,
        onActivatePreviousApp: @escaping () -> Void,
        onEditImage: @escaping (ClipboardItem) -> Void,
        onEditCurrentImage: @escaping (CurrentClipboardSnapshot) -> Void
    ) {
        self.focusSearch = focusSearch
        self.viewModel = viewModel
        self.onClearHistory = onClearHistory
        self.onShowSettings = onShowSettings
        self.onActivatePreviousApp = onActivatePreviousApp
        self.onEditImage = onEditImage
        self.onEditCurrentImage = onEditCurrentImage
        _sidebarVisible = State(initialValue: AppSettings.shared.isSidebarVisible)
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(sidebarVisible: $sidebarVisible, onShowSettings: onShowSettings)
            Divider().opacity(0.2)
            content
            Divider().opacity(0.2)
            FooterBar(
                selected: $viewModel.selectedItem,
                viewModel: viewModel,
                onEdit: { item in edit(item) },
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
            onActivatePreviousApp()
        }
       .overlay {
           if macroPickerPresented {
                MacroPickerOverlay(
                    macros: settings.macroScripts,
                    isImageInput: fixedMacroTarget?.isImage == true,
                    onSelect: { macro in
                        guard fixedMacroTarget?.isImage != true || macro.supportsImageInput else { return }
                        macroPickerPresented = false
                        runMacro(macro)
                    },
                    onCancel: {
                        macroPickerPresented = false
                        clearFixedMacroTarget()
                    }
                )
                .transition(.opacity)
           }
       }
        .animation(.easeOut(duration: 0.12), value: macroPickerPresented)
        .onChange(of: settings.isSidebarVisible) { _, visible in
            sidebarVisible = visible
        }
        .onChange(of: macroPickerPresented) { _, presented in
            // When the Macro Picker is dismissed (Esc, Cmd+M toggle, Enter, or
            // background click), the overlay's `@FocusState` releases and no
            // responder owns the key loop, so arrow-key navigation breaks.
            // Restore the responder that owned focus before the picker opened.
            // When opening, snapshot the current responder so we can restore it.
            if presented {
                responderBeforePicker = NSApp.keyWindow?.firstResponder
            } else {
                restoreFocusAfterPicker()
            }
        }
        .overlay {
            if isOcrInProgress {
                OcrProgressOverlay()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isOcrInProgress)
        .sheet(item: $editingItem) { item in
            TextEditView(original: item, viewModel: viewModel, initialText: editingCurrentText)
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyWindowDidClose)) { _ in
            // The history window is being closed. Reset the in-window state now so
            // the *next* time the window is shown the user starts from a fresh
            // list (no transient overlay, search query, or stale selection). Doing
            // this on close rather than on reopen avoids flashing the previous
            // Macro Picker or search results for a frame.
            // The selection itself is moved back to the latest entry on reopen
            // via `.resetSelectionToTop` (posted by `AppDelegate.showMainWindow`).
            macroPickerPresented = false
            macroPreparationID = nil
            clearFixedMacroTarget()
            editingCurrentText = nil
            query = ""
            viewModel.select(nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .editActionTriggered)) { note in
            // Triggered by the Edit action hotkey ( window-scoped ). Mirrors `FooterBar.editSelected` behavior.
            guard let item = note.object as? ClipboardItem else { return }
            edit(item)
        }
        .onReceive(NotificationCenter.default.publisher(for: .macroPickerTriggered)) { _ in
            // Cmd+M (default) while the history window is visible. Toggle so Cmd+M both
            // opens and closes the overlay. Beep if no entity is selected (AppDelegate
            // already guards this, but double-check here for safety).
            guard viewModel.selectedItem != nil else {
                NSSound.beep()
                return
            }
            if macroPickerPresented || macroPreparationID != nil {
                macroPreparationID = nil
                macroPickerPresented = false
                clearFixedMacroTarget()
            } else {
                prepareMacroPicker()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macroPickerRequested)) { _ in
            // Fired by the *global* Macro Picker hotkey ( optional second global
            // hotkey registered as `macroModalRegistryID` ). This is an
            // *open-only* request: assign `true` directly ( NOT `toggle()` ) so
            // reopening an already-visible window never closes the overlay.
            // See AppDelegate for why a dedicated notification is used instead of
            // `.macroPickerTriggered`.
            guard !macroPickerPresented else { return }
            prepareMacroPicker(preferCurrent: true)
        }
       .onReceive(NotificationCenter.default.publisher(for: .ocrProgressDidChange)) { note in
           if let v = note.userInfo?["inProgress"] as? Bool {
               isOcrInProgress = v
           }
       }
    }

    private func pasteStandard(item: ClipboardItem, rich: Bool) async -> Bool {
        await viewModel.pasteStandard(item: item, rich: rich)
    }

    /// Centralized Edit action used by both the `FooterBar.editSelected()` path
    /// and the `editActionTriggered` window-scoped hotkey. Routes image items to
    /// the injected `onEditImage` (Preview.app launch, an Infrastructure side
    /// effect) and text items to the local `TextEditView` sheet. Keeping the
    /// branch here means `FooterBar` only needs a single `onEdit` callback and
    /// neither view references `PreviewImageEditor` directly (review #4).
    private func edit(_ item: ClipboardItem) {
        Task { @MainActor in
            guard let target = await viewModel.resolveActionTarget(for: item) else { return }
            switch target {
            case .current(let snapshot) where snapshot.isImage:
                onEditCurrentImage(snapshot)
            case .current(let snapshot):
                guard snapshot.canUsePlainText else { NSSound.beep(); return }
                editingCurrentText = snapshot.text
                editingItem = snapshot.clipboardItem()
            case .history(let historyItem) where historyItem.isImage:
                onEditImage(historyItem)
            case .history(let historyItem):
                guard historyItem.canUsePlainText else { NSSound.beep(); return }
                editingCurrentText = nil
                editingItem = historyItem
            }
        }
    }

    /// Runs the given Macro against the currently selected entity (used by the
    /// Macro Picker overlay's Enter handler). Mirrors `FooterBar.runMacro` and
    /// `AppDelegate.runMacroFromHotkey`: Macro execution is offloaded to a
    /// background Task so the main thread is not blocked (review #4), and
    /// `PasteCoordinator` handles success / failure fallback.
    private func runMacro(_ macro: MacroScript) {
        Task { @MainActor in
            if let target = fixedMacroTarget {
                _ = await viewModel.runMacro(macro: macro, target: target)
            }
            clearFixedMacroTarget()
        }
    }

    private func prepareMacroPicker(preferCurrent: Bool = false) {
        let selected = viewModel.selectedItem
        guard preferCurrent || selected != nil else { NSSound.beep(); return }
        let preparationID = UUID()
        macroPreparationID = preparationID
        Task { @MainActor in
            let target = await viewModel.resolveActionTarget(for: selected, preferCurrent: preferCurrent)
            guard macroPreparationID == preparationID else { return }
            guard let target else {
                macroPreparationID = nil
                NSSound.beep()
                return
            }
            guard target.canRunMacro else {
                macroPreparationID = nil
                NSSound.beep()
                return
            }
            fixedMacroTarget = target
            macroPreparationID = nil
            macroPickerPresented = true
        }
    }

    private func clearFixedMacroTarget() {
        fixedMacroTarget = nil
    }

    /// Restores keyboard focus to the responder that owned it before the Macro
    /// Picker overlay opened. Falls back to making the key window the key responder
    /// if the snapshot is stale (e.g., the view was removed while the picker was up).
    private func restoreFocusAfterPicker() {
        guard let responder = responderBeforePicker else { return }
        responderBeforePicker = nil
        guard let window = NSApp.keyWindow else { return }
        guard window.makeFirstResponder(responder) else {
            window.makeFirstResponder(nil)
            return
        }
    }

    @ViewBuilder
    private var content: some View {
        if settings.isSplitView {
            HStack(spacing: 0) {
                if sidebarVisible {
                    HistoryListPane(
                        query: $query,
                        selectedItem: $viewModel.selectedItem,
                        viewModel: viewModel,
                        onPaste: { item in await pasteStandard(item: item, rich: true) }
                    )
                    .frame(maxWidth: .infinity)
                    .background(Color.appBackground.opacity(0.6))
                }
                PreviewPane(item: viewModel.selectedItem, viewModel: viewModel, wrapMode: settings.previewWrapMode)
                .frame(maxWidth: .infinity)
            }
        } else {
            PreviewPane(item: viewModel.selectedItem, viewModel: viewModel, wrapMode: settings.previewWrapMode)
        }
    }
}
