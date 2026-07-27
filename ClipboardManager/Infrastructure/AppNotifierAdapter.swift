import Foundation
import os
@preconcurrency import UserNotifications

/// Infrastructure adapter that conforms `AppNotifier` to the `AppNotifying` port
/// defined in ApplicationServices.
///
/// `AppNotifier` is an enum with static methods and cannot conform to an
/// `AnyObject` protocol directly, so this adapter delegates to the static
/// implementation.
@MainActor
final class AppNotifierAdapter: AppNotifying {
    func notify(title: String, body: String, deduplicationKey: String?) {
        AppNotifier.notify(title: title, body: body, deduplicationKey: deduplicationKey)
    }
}
