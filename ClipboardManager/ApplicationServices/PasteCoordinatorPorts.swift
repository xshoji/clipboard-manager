import AppKit
import Foundation

/// Port protocol for pasteboard writes that suppress the clipboard-monitor's
/// change detection so app-owned writes do not echo back into history.
///
/// Infrastructure's `ClipboardMonitor` conforms; `PasteCoordinator` depends on
/// this protocol so it does not reference the Infrastructure concrete type
/// directly.
protocol PasteboardSuppressing: AnyObject {
    @discardableResult
    func performSuppressedPasteboardWrite(_ write: (NSPasteboard) -> Void) -> Int
}

/// Port protocol for on-device OCR recognition.
///
/// Infrastructure's `OcrRecognizer` provides a concrete adapter; `PasteCoordinator`
/// depends on this protocol so ApplicationServices does not import Vision or
/// reference the Infrastructure enum directly.
protocol OcrRecognizing: Sendable {
    func recognizeText(in imageData: Data, languages: [String]) async -> String?
}

/// Port protocol for macro script execution.
///
/// Infrastructure's `MacroRunner` provides a concrete adapter; `PasteCoordinator`
/// depends on this protocol so ApplicationServices does not reference the
/// Infrastructure enum directly.
protocol MacroRunning: Sendable {
    func runAsync(
        script: MacroScript,
        input: MacroRunner.MacroInput,
        verifyFingerprint: Bool
    ) async throws -> MacroRunner.MacroOutput
}

/// Port protocol for restoring the previous foreground application after a paste.
///
/// Infrastructure's `AppActivator` conforms; `PasteCoordinator` depends on this
/// protocol so ApplicationServices does not reference the Infrastructure singleton
/// directly.
@MainActor
protocol AppActivating: AnyObject {
    func activatePreviousAppAndPasteSynthetically(needsSynthetic: Bool)
}

/// Port protocol for user-facing notifications.
///
/// Infrastructure's `AppNotifier` conforms; `PasteCoordinator` depends on this
/// protocol so ApplicationServices does not reference the Infrastructure enum
/// directly.
@MainActor
protocol AppNotifying: AnyObject {
    func notify(title: String, body: String, deduplicationKey: String?)
}
