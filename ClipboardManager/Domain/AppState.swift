import Foundation

/// A lightweight shared UI-state holder for the entire app.
/// Used by Infrastructure-layer components (e.g., Macro hotkey triggers) to access the currently selected entity held by the UI.
@MainActor
final class AppState {
    static let shared = AppState()

    /// The ID of the currently selected `ClipboardEntity` in `MainView`. `nil` when nothing is selected.
    var selectedEntityID: UUID?
}
