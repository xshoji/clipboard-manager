import Foundation
import AppKit

/// Integrates `OcrRecognizer` with the paste pipeline used by "Paste Plain" for
/// image history entries. Both `FooterBar.paste(rich: false)` and the
/// window-scoped Paste Plain action hotkey (`AppDelegate.runPastePlainAction`)
/// delegate here so the OCR-then-paste flow has a single owner.
///
/// Flow:
/// 1. Post `.ocrProgressDidChange` (inProgress = true) so the UI can show an indicator.
/// 2. Run `OcrRecognizer.recognizeText` off the main actor.
/// 3. If no text is recognized, post a user notification (decided behavior: (b)) and stop.
/// 4. Otherwise write the recognized text to `NSPasteboard` with the same
///    suppression bookkeeping used by `ClipboardEntity.writeToPasteboard`, then
///    activate the previous app (and optionally send a synthetic Cmd+V).
/// 5. Post `.ocrProgressDidChange` (inProgress = false) in `defer`.
@MainActor
enum OcrPasteService {
    static func run(entity: ClipboardEntity, settings: AppSettings) async {
        guard let imageData = entity.imageData, !imageData.isEmpty else {
            AppNotifier.notify(
                title: "OCR",
                body: "No image data is available for this history item."
            )
            return
        }
        NotificationCenter.default.post(
            name: .ocrProgressDidChange,
            object: nil,
            userInfo: ["inProgress": true]
        )
        defer {
            NotificationCenter.default.post(
                name: .ocrProgressDidChange,
                object: nil,
                userInfo: ["inProgress": false]
            )
        }

        let languages = settings.ocrLanguages
        let text = await OcrRecognizer.recognizeText(in: imageData, languages: languages)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            AppNotifier.notify(
                title: "OCR",
                body: "No text was recognized in the image."
            )
            return
        }

        // Same suppression bookkeeping as `FooterBar.paste(rich:)` /
        // `AppDelegate.runPastePlainAction` so the utility-queue poll cannot
        // capture our own write as a new history item (review #6).
        let pre = NSPasteboard.general.changeCount
        ClipboardMonitor.shared?.suppressChangeCountRange((pre + 1)..<(pre + 3))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text ?? "", forType: .string)
        ClipboardMonitor.shared?.finalizeSuppressionAfterWrite(preChangeCount: pre)

        AppActivator.shared.activatePreviousAppAndPasteSynthetically(
            needsSynthetic: settings.needsAccessibilityForSyntheticPaste
        )
    }
}
