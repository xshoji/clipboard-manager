import SwiftUI
import SwiftData

@main
struct ClipboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(appDelegate.settings)
                .modelContext(appDelegate.persistence.container.mainContext)
        }
    }
}
