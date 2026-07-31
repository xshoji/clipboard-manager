import Foundation
import AppKit
import Vision

/// Pure OCR helper backed by the Vision framework (`VNRecognizeTextRequest`).
/// Runs entirely on-device; no network access and no third-party dependencies.
/// `recognizeText(in:languages:)` is `async` and performs the request on a
/// detached `userInitiated` task so the main actor is never blocked
/// (AGENTS.md: "Avoid blocking the main actor with ... image work").
enum OcrRecognizer {
    /// Recognizes text in the supplied image data.
    /// - Returns: The recognized lines joined with newlines, or `nil` when the
    ///   image cannot be decoded or no text is recognized.
    static func recognizeText(in imageData: Data, languages: [String]) async -> String? {
        await Task.detached(priority: .userInitiated) {
            recognizeTextSynchronously(in: imageData, languages: languages)
        }.value
    }

    /// Synchronous core used by the serial utility-priority automatic OCR queue.
    /// Interactive OCR remains wrapped in a user-initiated detached task above.
    static func recognizeTextSynchronously(in imageData: Data, languages: [String]) -> String? {
        guard let nsImage = NSImage(data: imageData),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// Processes automatic OCR jobs one at a time at utility QoS so bursts of image
/// copies cannot run multiple Vision requests concurrently or block the UI.
final class AutomaticOcrProcessor: @unchecked Sendable {
    private let repository: ClipboardHistoryWriting
    private let queue = DispatchQueue(
        label: "com.xshoji.ClipboardManager.automaticOcr",
        qos: .utility
    )

    @MainActor
    init(repository: ClipboardHistoryWriting) {
        self.repository = repository
    }

    func enqueue(id: UUID, imageData: Data, languages: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            let text = autoreleasepool {
                OcrRecognizer.recognizeTextSynchronously(in: imageData, languages: languages)
            }
            Task { @MainActor [weak self] in
                self?.repository.updateOcrResult(id: id, text: text)
            }
        }
    }
}
