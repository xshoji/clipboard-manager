import Foundation
import ServiceManagement

/// Registers / unregisters the app as a macOS login item via the modern `SMAppService` API ( macOS 13+ ).
/// The app's main bundle is registered, so the OS launches ClipboardManager at login.
@MainActor
final class LoginItemManager {
    static let shared = LoginItemManager()

    private init() {}

    @discardableResult
    func enable() -> Bool {
        do {
            try SMAppService.mainApp.register()
            return SMAppService.mainApp.status == .enabled
        } catch {
            return false
        }
    }

    @discardableResult
    func disable() -> Bool {
        do {
            try SMAppService.mainApp.unregister()
            return SMAppService.mainApp.status != .enabled
        } catch {
            return false
        }
    }

    func updateRegistration(enabled: Bool) {
        if enabled {
            enable()
        } else {
            disable()
        }
    }
}
