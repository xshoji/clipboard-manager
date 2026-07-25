import SwiftUI
import SwiftData

@main
struct ClipboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
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
