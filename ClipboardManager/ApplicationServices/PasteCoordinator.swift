import AppKit
import Foundation

@MainActor
final class PasteCoordinator {
    private let repository: ClipboardRepositoryPort
    private let settings: PasteCoordinatorSettings
    private let pasteboard: PasteboardSuppressing
    private let ocr: OcrRecognizing
    private let macroRunner: MacroRunning
    private let activator: AppActivating
    private let notifier: AppNotifying

    init(
        repository: ClipboardRepositoryPort,
        settings: PasteCoordinatorSettings,
        pasteboard: PasteboardSuppressing,
        ocr: OcrRecognizing,
        macroRunner: MacroRunning,
        activator: AppActivating,
        notifier: AppNotifying
    ) {
        self.repository = repository
        self.settings = settings
        self.pasteboard = pasteboard
        self.ocr = ocr
        self.macroRunner = macroRunner
        self.activator = activator
        self.notifier = notifier
    }

    @discardableResult
    func pasteStandard(item: ClipboardItem, rich: Bool, activate: Bool = true) async -> Bool {
        let wrote: Bool
        if item.isImage {
            guard let data = await repository.fetchImageData(id: item.id) else { return false }
            suppressedWrite { pasteboard in
                pasteboard.clearContents()
                pasteboard.setData(data, forType: .png)
            }
            wrote = true
        } else {
            guard let content = await repository.fetchTextContent(id: item.id, includeRich: rich) else { return false }
            writeText(content, rich: rich)
            wrote = true
        }
        if activate { activatePreviousApp() }
        return wrote
    }

    func runOcr(item: ClipboardItem) async {
        if let cached = await repository.fetchOcrResult(id: item.id) {
            if cached.status == "completed" {
                pasteOcrTextOrNotify(cached.text)
                return
            }
            if cached.status == "pending" {
                notifier.notify(
                    title: "OCR",
                    body: "Text recognition is still running. Try again shortly.",
                    deduplicationKey: "ocr-still-running"
                )
                return
            }
        }
        guard let data = await repository.fetchImageData(id: item.id), !data.isEmpty else {
            notifier.notify(title: "OCR", body: "No image data is available for this history item.", deduplicationKey: nil); return
        }
        NotificationCenter.default.post(name: .ocrProgressDidChange, object: nil, userInfo: ["inProgress": true])
        defer { NotificationCenter.default.post(name: .ocrProgressDidChange, object: nil, userInfo: ["inProgress": false]) }
        let text = await ocr.recognizeText(in: data, languages: settings.ocrLanguages)
        repository.updateOcrResult(id: item.id, text: text)
        pasteOcrTextOrNotify(text)
    }

    private func pasteOcrTextOrNotify(_ text: String?) {
        let recognized = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !recognized.isEmpty else {
            notifier.notify(title: "OCR", body: "No text was recognized in the image.", deduplicationKey: nil)
            return
        }
        suppressedWrite { pb in pb.clearContents(); pb.setString(text ?? "", forType: .string) }
        activatePreviousApp()
    }

    @discardableResult
    func runMacro(macro: MacroScript, item: ClipboardItem) async -> Bool {
        guard let input = await macroInput(for: item) else { return false }
        do {
            let output = try await macroRunner.runAsync(script: macro, input: input,
                verifyFingerprint: settings.macroSameDirectoryFingerprint)
            suppressedWrite { pb in
                pb.clearContents()
                if output.isImage { pb.setData(output.data, forType: .png) }
                else { pb.setString(String(data: output.data, encoding: .utf8) ?? "", forType: .string) }
            }
            activatePreviousApp(); return true
        } catch is CancellationError {
            return false
        } catch {
            let message = (error as? MacroRunningError)?.description ?? error.localizedDescription
            switch settings.macroFailureBehavior {
            case "restoreOriginalAndNotify":
                if await pasteOriginal(item) { activatePreviousApp() }
                notifier.notify(title: "Macro failed", body: message, deduplicationKey: nil)
            case "notifyOnly": notifier.notify(title: "Macro failed", body: message, deduplicationKey: nil)
            case "silentlySkip": break
            default: notifier.notify(title: "Macro failed", body: message, deduplicationKey: nil)
            }
            return false
        }
    }

    func debugMacro(macro: MacroScript, item: ClipboardItem) async throws -> MacroDebugReport {
        guard let input = await macroInput(for: item) else {
            return .notLaunched(
                command: "\(macro.interpreter) \(macro.inlineScript == nil ? macro.scriptPath : "<inline-script>")",
                errorMessage: "The selected history item has no available input data."
            )
        }
        return try await macroRunner.debugRunAsync(
            script: macro,
            input: input,
            verifyFingerprint: settings.macroSameDirectoryFingerprint
        )
    }

    func copyMacroDebugReport(_ text: String) {
        suppressedWrite { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    private func macroInput(for item: ClipboardItem) async -> MacroInput? {
        if item.isImage {
            guard let imageData = await repository.fetchImageData(id: item.id) else { return nil }
            return .init(isImage: true, imageData: imageData, text: nil, sourceBundleID: item.sourceBundleID)
        }
        guard let text = await repository.fetchFullText(id: item.id) else { return nil }
        return .init(isImage: false, imageData: nil, text: text, sourceBundleID: item.sourceBundleID)
    }

    private func writeText(_ content: ClipboardTextContent, rich: Bool) {
        suppressedWrite { pb in
            pb.clearContents()
            if rich, let html = content.html, !html.isEmpty {
                pb.setData(html, forType: NSPasteboard.PasteboardType("public.html"))
                if let text = content.text, !text.isEmpty {
                    pb.setString(text, forType: .string)
                }
            } else if rich, let data = content.richText, let type = Self.richTextType(data) {
                pb.setData(data, forType: type); pb.setString(content.text ?? "", forType: .string)
            } else { pb.setString(content.text ?? "", forType: .string) }
        }
    }

    private func pasteOriginal(_ item: ClipboardItem) async -> Bool {
        if item.isImage {
            guard let data = await repository.fetchImageData(id: item.id) else { return false }
            suppressedWrite { pasteboard in
                pasteboard.clearContents()
                pasteboard.setData(data, forType: .png)
            }
        } else {
            guard let content = await repository.fetchTextContent(id: item.id, includeRich: true) else { return false }
            writeText(content, rich: true)
        }
        return true
    }

    private func suppressedWrite(_ body: (NSPasteboard) -> Void) {
        pasteboard.performSuppressedPasteboardWrite(body)
    }

    private func activatePreviousApp() {
        activator.activatePreviousAppAndPasteSynthetically(needsSynthetic: settings.needsAccessibilityForSyntheticPaste)
    }

    private static func richTextType(_ data: Data) -> NSPasteboard.PasteboardType? {
        if (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)) != nil { return .rtf }
        if (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)) != nil { return .rtfd }
        return nil
    }
}
