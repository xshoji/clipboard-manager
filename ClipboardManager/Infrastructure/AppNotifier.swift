import Foundation
import os
@preconcurrency import UserNotifications

@MainActor
enum AppNotifier {
    private static let logger = Logger(subsystem: "com.xshoji.ClipboardManager", category: "Notifications")
    private static var lastSentAtByKey: [String: Date] = [:]
    private nonisolated static var isNotificationAvailable: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    static func notify(title: String, body: String, deduplicationKey: String? = nil) {
        let key = deduplicationKey ?? body
        if let last = lastSentAtByKey[key], Date().timeIntervalSince(last) < 1 { return }
        lastSentAtByKey[key] = Date()
        guard isNotificationAvailable else { logger.info("\(title, privacy: .public): \(body, privacy: .public)"); return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "clipboard-manager-\(UUID())", content: content, trigger: nil))
    }

    static nonisolated func requestAuthorizationIfNeeded() {
        guard isNotificationAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }
}
