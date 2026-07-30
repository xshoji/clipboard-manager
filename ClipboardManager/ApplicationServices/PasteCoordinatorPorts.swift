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

struct MacroInput: Sendable {
    let isImage: Bool
    let imageData: Data?
    let text: String?
    let sourceBundleID: String?
}

struct MacroOutput: Sendable {
    let data: Data
    let isImage: Bool
}

enum MacroRunningError: Error, CustomStringConvertible {
    case scriptPathOutsideHome
    case fingerprintMismatch
    case fingerprintUnavailable
    case timeout
    case exitStatus(Int32)
    case missingScript
    case emptyInlineScript
    case invalidOutputEncoding

    var description: String {
        switch self {
        case .scriptPathOutsideHome: return "Script path must be inside $HOME."
        case .fingerprintMismatch: return "Script fingerprint mismatch. Re-register in Settings."
        case .fingerprintUnavailable: return "Script fingerprint not available. Re-register in Settings."
        case .timeout: return "Macro script timed out (>5s)."
        case .exitStatus(let status): return "Macro script exited with status \(status)."
        case .missingScript: return "Macro script file not found."
        case .emptyInlineScript: return "Inline Macro script is empty."
        case .invalidOutputEncoding: return "Macro output is not valid UTF-8 text."
        }
    }
}

/// Port protocol for macro script execution.
///
/// Infrastructure's `MacroRunner` provides a concrete adapter; `PasteCoordinator`
/// depends on this protocol so ApplicationServices does not reference the
/// Infrastructure enum directly.
protocol MacroRunning: Sendable {
    func runAsync(
        script: MacroScript,
        input: MacroInput,
        verifyFingerprint: Bool
    ) async throws -> MacroOutput
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
