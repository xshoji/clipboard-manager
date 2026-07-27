import Foundation
import Vision

/// Infrastructure adapter that conforms `OcrRecognizer` to the
/// `OcrRecognizing` port defined in ApplicationServices.
///
/// The original `OcrRecognizer` enum keeps its static implementation; this
/// adapter wraps it so `PasteCoordinator` can depend on the protocol instead
/// of the concrete Infrastructure type.
final class OcrRecognizerAdapter: OcrRecognizing {
    func recognizeText(in imageData: Data, languages: [String]) async -> String? {
        await OcrRecognizer.recognizeText(in: imageData, languages: languages)
    }
}
