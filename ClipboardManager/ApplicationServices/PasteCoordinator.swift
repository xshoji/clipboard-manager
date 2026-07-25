import AppKit
import Foundation

@MainActor
final class PasteCoordinator {
    private let repository: ClipboardRepository
    private let settings: AppSettingsStore
    private let monitor: ClipboardMonitor

    init(repository: ClipboardRepository, settings: AppSettingsStore, monitor: ClipboardMonitor) {
        self.repository = repository
        self.settings = settings
        self.monitor = monitor
    }

    @discardableResult
    func pasteStandard(item: ClipboardItem, rich: Bool, activate: Bool = true) -> Bool {
        let wrote: Bool
        if item.isImage {
            guard let data = repository.fetchImageData(id: item.id) else { return false }
            suppressedWrite { pasteboard in
                pasteboard.clearContents()
                pasteboard.setData(data, forType: .png)
            }
            wrote = true
        } else {
            guard let content = repository.fetchTextContent(id: item.id, includeRichText: rich) else { return false }
            writeText(content, rich: rich)
            wrote = true
        }
        if activate { activatePreviousApp() }
        return wrote
    }

    func runOcr(item: ClipboardItem) async {
        guard let data = repository.fetchImageData(id: item.id), !data.isEmpty else {
            AppNotifier.notify(title: "OCR", body: "No image data is available for this history item."); return
        }
        NotificationCenter.default.post(name: .ocrProgressDidChange, object: nil, userInfo: ["inProgress": true])
        defer { NotificationCenter.default.post(name: .ocrProgressDidChange, object: nil, userInfo: ["inProgress": false]) }
        let text = await OcrRecognizer.recognizeText(in: data, languages: settings.ocrLanguages)
        guard !(text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty else {
            AppNotifier.notify(title: "OCR", body: "No text was recognized in the image."); return
        }
        suppressedWrite { pb in pb.clearContents(); pb.setString(text ?? "", forType: .string) }
        activatePreviousApp()
    }

    @discardableResult
    func runMacro(macro: MacroScript, item: ClipboardItem) async -> Bool {
        let input: MacroRunner.MacroInput
        if item.isImage {
            guard let imageData = repository.fetchImageData(id: item.id) else { return false }
            input = .init(isImage: true, imageData: imageData, text: nil, sourceBundleID: item.sourceBundleID)
        } else {
            guard let text = repository.fetchFullText(id: item.id) else { return false }
            input = .init(isImage: false, imageData: nil, text: text, sourceBundleID: item.sourceBundleID)
        }
        do {
            let output = try await MacroRunner.runAsync(script: macro, input: input,
                verifyFingerprint: settings.macroSameDirectoryFingerprint)
            if !output.isImage, String(data: output.data, encoding: .utf8) == nil, !output.data.isEmpty {
                throw MacroError.invalidOutputEncoding
            }
            suppressedWrite { pb in
                pb.clearContents()
                if output.isImage { pb.setData(output.data, forType: .png) }
                else { pb.setString(String(data: output.data, encoding: .utf8) ?? "", forType: .string) }
            }
            activatePreviousApp(); return true
        } catch {
            let message = (error as? MacroError)?.description ?? error.localizedDescription
            switch settings.macroFailureBehavior {
            case "restoreOriginalAndNotify":
                if pasteOriginal(item) { activatePreviousApp() }
                AppNotifier.notify(title: "Macro failed", body: message)
            case "notifyOnly": AppNotifier.notify(title: "Macro failed", body: message)
            case "silentlySkip": break
            default: AppNotifier.notify(title: "Macro failed", body: message)
            }
            return false
        }
    }

    private func writeText(_ content: ClipboardRepository.TextContent, rich: Bool) {
        suppressedWrite { pb in
            pb.clearContents()
            if rich, let data = content.richText, let type = Self.richTextType(data) {
                pb.setData(data, forType: type); pb.setString(content.text ?? "", forType: .string)
            } else { pb.setString(content.text ?? "", forType: .string) }
        }
    }

    private func pasteOriginal(_ item: ClipboardItem) -> Bool {
        if item.isImage {
            guard let data = repository.fetchImageData(id: item.id) else { return false }
            suppressedWrite { pasteboard in
                pasteboard.clearContents()
                pasteboard.setData(data, forType: .png)
            }
        } else {
            guard let content = repository.fetchTextContent(id: item.id, includeRichText: true) else { return false }
            writeText(content, rich: true)
        }
        return true
    }

    private func suppressedWrite(_ body: (NSPasteboard) -> Void) {
        monitor.performSuppressedPasteboardWrite(body)
    }

    private func activatePreviousApp() {
        AppActivator.shared.activatePreviousAppAndPasteSynthetically(needsSynthetic: settings.needsAccessibilityForSyntheticPaste)
    }

    private static func richTextType(_ data: Data) -> NSPasteboard.PasteboardType? {
        if (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)) != nil { return .rtf }
        if (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)) != nil { return .rtfd }
        return nil
    }
}
