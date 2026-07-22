import Foundation
import AppKit
@preconcurrency import UserNotifications
import os

/// Service that orchestrates Macro execution, pasteboard write, previous-app restoration, and failure fallback (restoring original content to pasteboard, returning to previous app, and notification).
/// Design: design-implementation.md §4.2 / §5 (Macro failure behavior), remaining-features #6
/// Macro execution runs on a background queue and returns to the main thread upon completion (review #4).
@MainActor
enum MacroPasteService {
    /// Runs the Macro. On success, writes the processed content to the pasteboard and restores the previous app.
    /// On failure, follows `AppSettings.macroFailureBehavior`:
    /// `restoreOriginalAndNotify` restores the original entity content to the pasteboard, returns to the previous app, and posts a notification.
    /// `notifyOnly` posts a notification only. `silentlySkip` does nothing.
    /// - Returns: Whether it succeeded. `false` on failure.
    @discardableResult
    static func run(macro: MacroScript, entity: ClipboardEntity, settings: AppSettings) async -> Bool {
        // MacroRunner runs in a background Task so the main thread is not blocked (review #4).
        // Pasteboard restoration and app activation are order-dependent, so wait synchronously.
        // ClipboardEntity from SwiftData is non-Sendable, so convert to Sendable MacroInput before passing to the Task (review #4).
        let input = MacroRunner.MacroInput(
            isImage: entity.isImage,
            imageData: entity.imageData,
            text: entity.text,
            sourceBundleID: entity.sourceBundleID
        )
        let result: Result<Data, Error>
        do {
            let out = try await MacroRunner.runAsync(
                script: macro,
                input: input,
                verifyFingerprint: settings.macroSameDirectoryFingerprint
            )
            // review #6: Reject non-UTF8 text outputs only when the output is not an
            // image, so image -> image / image -> text macros are evaluated on their
            // own merits.
            if NSImage(data: out) == nil,
               String(data: out, encoding: .utf8) == nil,
               !out.isEmpty {
                throw MacroError.invalidOutputEncoding
            }
            result = .success(out)
        } catch {
            result = .failure(error)
        }
        switch result {
        case .success(let out):
            writePasteboard(data: out)
            AppActivator.shared.activatePreviousAppAndPasteSynthetically(
                needsSynthetic: settings.needsAccessibilityForSyntheticPaste
            )
            return true
        case .failure(let error):
            handleFailure(
                error: error,
                entity: entity,
                behavior: settings.macroFailureBehavior,
                needsSynthetic: settings.needsAccessibilityForSyntheticPaste
            )
            return false
        }
    }

    // MARK: - Pasteboard

    private static func writePasteboard(data: Data) {
        let pb = NSPasteboard.general
        // Do not add pasteboard writes made by this app itself to the clipboard history.
        // This write changes changeCount; suppress it so ClipboardMonitor does not mistake it for a user copy (design-implementation.md §4.2).
        //
        // Race note (review #6): the poll runs on a background utility queue and could fire
        // between `clearContents()` and `setData()`. To prevent it from saving the app's own
        // write as a history item, register a suppression range covering the pre-write
        // changeCount-plus-one up to (pre + 3) BEFORE the write. `clearContents()` bumps +1,
        // and the subsequent `setData`/`setString` may bump an additional +1, so a width of 2
        // covers both bumps. The range starts at `pre + 1` (not `pre`) so a user copy that
        // just landed at `pre` is not wrongly suppressed. After the write,
        // `finalizeSuppressionAfterWrite` removes any pre-registered entries above the actual
        // post-write changeCount so they cannot orphan-suppress a future user copy.
        let pre = pb.changeCount
        ClipboardMonitor.shared?.suppressChangeCountRange((pre + 1)..<(pre + 3))
        pb.clearContents()
        // Determine the output *content*, not the input entity kind: a macro may
        // transform an image into text (e.g. OCR) or text into an image. We treat
        // the data as an image only when it decodes as PNG; otherwise as text.
        if let img = NSImage(data: data), img.isValid {
            pb.setData(data, forType: .png)
        } else {
            // review #6: Non-UTF8 output is already rejected in run(), so this is safe.
            pb.setString(String(data: data, encoding: .utf8) ?? "", forType: .string)
        }
        // Finalize: ensure the actual post-write changeCount is suppressed and remove
        // orphaned pre-registered entries that could suppress a future user copy.
        ClipboardMonitor.shared?.finalizeSuppressionAfterWrite(preChangeCount: pre)
    }

    /// Failure fallback: restores the original entity content to the pasteboard.
    /// Because this write is also made by the app itself, exclude it from history
    /// by registering a suppression range before the write (review #6 race note above).
    private static func restoreOriginalToPasteboard(entity: ClipboardEntity) {
        let pb = NSPasteboard.general
        let pre = pb.changeCount
        ClipboardMonitor.shared?.suppressChangeCountRange((pre + 1)..<(pre + 3))
        entity.writeToPasteboard(.general)
        ClipboardMonitor.shared?.finalizeSuppressionAfterWrite(preChangeCount: pre)
    }

    private static func handleFailure(
        error: Error,
        entity: ClipboardEntity,
        behavior: String,
        needsSynthetic: Bool
    ) {
        let message = (error as? MacroError)?.description ?? error.localizedDescription
        switch behavior {
        case "restoreOriginalAndNotify":
            restoreOriginalToPasteboard(entity: entity)
            AppActivator.shared.activatePreviousAppAndPasteSynthetically(needsSynthetic: needsSynthetic)
            AppNotifier.notify(title: "Macro failed", body: message)
        case "notifyOnly":
            AppNotifier.notify(title: "Macro failed", body: message)
        case "silentlySkip":
            break
        default:
            // Unknown values fall back to the safe side: notify only.
            AppNotifier.notify(title: "Macro failed", body: message)
        }
    }
}

/// Posts user notifications via the macOS Notification Center (`UserNotifications`).
/// Throttles duplicate keys to at most one notification per second to prevent spam.
@MainActor
enum AppNotifier {
    private static let logger = Logger(subsystem: "com.xshoji.ClipboardManager", category: "Macro")
    private static var lastSentAtByKey: [String: Date] = [:]

    /// Disables notifications outside an app bundle (e.g., `swift run`) because `UNUserNotificationCenter` is unavailable there.
    private nonisolated static var isNotificationAvailable: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func notify(title: String, body: String, deduplicationKey: String? = nil) {
        let key = deduplicationKey ?? body
        if let last = lastSentAtByKey[key], Date().timeIntervalSince(last) < 1.0 {
            return
        }
        lastSentAtByKey[key] = Date()

        if !isNotificationAvailable {
            // Outside an app bundle, log to console only.
            logger.info("\(title, privacy: .public): \(body, privacy: .public)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "clipboard-manager-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { _ in }
        // Also print to the console for visibility.
        logger.info("\(title, privacy: .public): \(body, privacy: .public)")
    }

    /// Requests authorization from the notification center on first use. Expected to be called by AppDelegate at launch.
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
