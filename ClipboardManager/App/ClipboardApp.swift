import SwiftUI

@main
struct ClipboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // AppKit owns the status item and windows; do not register an empty Settings window.
        MenuBarExtra("ClipboardManager", isInserted: .constant(false)) {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.container.coordinator.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
