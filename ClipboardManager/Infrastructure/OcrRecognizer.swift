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
            guard let nsImage = NSImage(data: imageData),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Vision accepts an empty array as "use defaults", but we only set the
            // property when the user has explicitly chosen languages to avoid
            // overriding Vision's default selection with an empty list.
            if !languages.isEmpty {
                request.recognitionLanguages = languages
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return nil
            }
            let observations = request.results ?? []
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }.value
    }
}
