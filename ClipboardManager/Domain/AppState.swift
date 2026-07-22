import Foundation

/// A lightweight shared UI-state holder for the entire app.
/// Used by Infrastructure-layer components (e.g., Macro hotkey triggers) to access the currently selected entity held by the UI.
@MainActor
final class AppState {
    static let shared = AppState()

    /// The ID of the currently selected `ClipboardEntity` in `MainView`. `nil` when nothing is selected.
    var selectedEntityID: UUID?

    /// IDs of Macros that have unsaved changes in the Settings UI.
    var unsavedMacroIDs: Set<UUID> = []

    /// Set to `true` when the user chooses "Save" in the unsaved-changes alert on window close.
    /// The settings window will be closed automatically once `unsavedMacroIDs` becomes empty.
    var settingsWindowShouldCloseAfterSave: Bool = false

    /// Number of Macro rows expected to report a save outcome (completed or
    /// cancelled) after a `.saveAllUnsavedMacros` broadcast. Set when the
    /// broadcast is posted; consumed by `SettingsWindowController` to decide
    /// when every row has settled so the window can be closed.
    var pendingMacroSaveCount: Int = 0
    /// Number of rows that have completed their save flow (saved or cancelled)
    /// since the broadcast. Reset together with `pendingMacroSaveCount` when a
    /// new "Save" response starts.
    var completedMacroSaveCount: Int = 0

    /// Record that one Macro row has settled its save flow. When the completed
    /// count reaches `pendingMacroSaveCount`, posts `.macroSaveSettleComplete`
    /// so observers can react after every row has reported.
    func recordMacroSaveSettlement() {
        completedMacroSaveCount += 1
        if completedMacroSaveCount >= pendingMacroSaveCount && pendingMacroSaveCount > 0 {
            NotificationCenter.default.post(name: .macroSaveSettleComplete, object: nil)
        }
    }

    /// Begin a new "Save all unsaved Macros" cycle. Clears the settle counters
    /// and arms `pendingMacroSaveCount` with the number of rows that must settle.
    func startMacroSaveCycle(expected count: Int) {
        pendingMacroSaveCount = count
        completedMacroSaveCount = 0
    }
}

