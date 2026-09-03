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
            historyWrite(recording: imageHistoryItem(data: data, source: item)) { pasteboard in
                pasteboard.clearContents()
                pasteboard.setData(data, forType: .png)
            }
            wrote = true
        } else {
            guard let content = await repository.fetchTextContent(id: item.id, includeRich: rich) else { return false }
            guard rich ? content.canRichPaste : content.canUsePlainText else {
                notifyPlainTextUnavailable()
                return false
            }
            wrote = writeText(content, rich: rich, source: item)
        }
        if wrote, activate { activatePreviousApp() }
        return wrote
    }

    @discardableResult
    func pasteStandard(snapshot: CurrentClipboardSnapshot, rich: Bool, activate: Bool = true) -> Bool {
        let wrote: Bool
        if snapshot.isImage, let data = snapshot.imageData {
            historyWrite(recording: snapshot.newClipboardItem()) {
                $0.clearContents()
                $0.setData(data, forType: .png)
            }
            wrote = true
        } else {
            guard rich || snapshot.canUsePlainText else {
                notifyPlainTextUnavailable()
                return false
            }
            wrote = writeSnapshotText(snapshot, rich: rich, recordOutput: true)
        }
        if wrote, activate { activatePreviousApp() }
        return wrote
    }

    @discardableResult
    func saveEditedText(_ text: String) -> Bool {
        let item = NewClipboardItem(
            kind: "text",
            text: text,
            contentHash: HashUtil.sha256Hex(of: Data(text.utf8))
        )
        guard repository.insert(
            item,
            removingDuplicates: false,
            purpose: "TextEditView.saveAsNew"
        ) else { return false }
        suppressedWrite { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        return true
    }

    func runOcr(item: ClipboardItem) async {
        if let cached = await repository.fetchOcrResult(id: item.id) {
            if cached.status == "completed" {
                pasteOcrTextOrNotify(cached.text, source: item)
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
        pasteOcrTextOrNotify(text, source: item)
    }

    func runOcr(
        snapshot: CurrentClipboardSnapshot,
        matchingHistory: ClipboardItem? = nil
    ) async {
        if let matchingHistory,
           let cached = await repository.fetchOcrResult(id: matchingHistory.id) {
            if cached.status == "completed" {
                pasteOcrTextOrNotify(cached.text, source: matchingHistory)
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
        guard let data = snapshot.imageData else { return }
        NotificationCenter.default.post(name: .ocrProgressDidChange, object: nil, userInfo: ["inProgress": true])
        defer { NotificationCenter.default.post(name: .ocrProgressDidChange, object: nil, userInfo: ["inProgress": false]) }
        let text = await ocr.recognizeText(in: data, languages: settings.ocrLanguages)
        if let matchingHistory {
            repository.updateOcrResult(id: matchingHistory.id, text: text)
            pasteOcrTextOrNotify(text, source: matchingHistory)
            return
        }
        let recognized = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !recognized.isEmpty else {
            notifier.notify(title: "OCR", body: "No text was recognized in the image.", deduplicationKey: nil); return
        }
        let output = text ?? ""
        historyWrite(recording: NewClipboardItem(
            kind: "text",
            text: output,
            sourceBundleID: snapshot.sourceBundleID,
            contentHash: HashUtil.sha256Hex(of: Data(output.utf8))
        )) {
            $0.clearContents()
            $0.setString(output, forType: .string)
        }
        activatePreviousApp()
    }

    private func pasteOcrTextOrNotify(_ text: String?, source: ClipboardItem) {
        let recognized = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !recognized.isEmpty else {
            notifier.notify(title: "OCR", body: "No text was recognized in the image.", deduplicationKey: nil)
            return
        }
        let output = text ?? ""
        historyWrite(recording: textHistoryItem(text: output, source: source)) { pb in
            pb.clearContents()
            pb.setString(output, forType: .string)
        }
        activatePreviousApp()
    }

    @discardableResult
    func runMacro(macro: MacroScript, item: ClipboardItem) async -> Bool {
        guard !item.isImage || macro.supportsImageInput else {
            return macroFailureForUnsupportedImage(item: item)
        }
        guard item.isImage || item.canUsePlainText else {
            notifyPlainTextUnavailable()
            return false
        }
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

    @discardableResult
    func runMacro(macro: MacroScript, snapshot: CurrentClipboardSnapshot) async -> Bool {
        guard !snapshot.isImage || macro.supportsImageInput else {
            return macroFailureForUnsupportedImage(snapshot: snapshot)
        }
        guard snapshot.isImage || snapshot.canUsePlainText else {
            notifyPlainTextUnavailable()
            return false
        }
        let input = MacroInput(isImage: snapshot.isImage, imageData: snapshot.imageData,
            text: snapshot.text, sourceBundleID: snapshot.sourceBundleID)
        do {
            let output = try await macroRunner.runAsync(script: macro, input: input,
                verifyFingerprint: settings.macroSameDirectoryFingerprint)
            suppressedWrite { pb in
                pb.clearContents()
                if output.isImage { pb.setData(output.data, forType: .png) }
                else { pb.setString(String(data: output.data, encoding: .utf8) ?? "", forType: .string) }
            }
            activatePreviousApp(); return true
        } catch is CancellationError { return false }
        catch {
            let message = (error as? MacroRunningError)?.description ?? error.localizedDescription
            if settings.macroFailureBehavior == "restoreOriginalAndNotify" {
                pasteOriginal(snapshot)
                activatePreviousApp()
            }
            if settings.macroFailureBehavior != "silentlySkip" {
                notifier.notify(title: "Macro failed", body: message, deduplicationKey: nil)
            }
            return false
        }
    }

    private func macroFailureForUnsupportedImage(item: ClipboardItem) -> Bool {
        let message = "JavaScript (JXA) Macros are unavailable for image input."
        if settings.macroFailureBehavior == "restoreOriginalAndNotify" { Task { if await pasteOriginal(item) { activatePreviousApp() } } }
        if settings.macroFailureBehavior != "silentlySkip" { notifier.notify(title: "Macro failed", body: message, deduplicationKey: nil) }
        return false
    }

    private func macroFailureForUnsupportedImage(snapshot: CurrentClipboardSnapshot) -> Bool {
        let message = "JavaScript (JXA) Macros are unavailable for image input."
        if settings.macroFailureBehavior == "restoreOriginalAndNotify" { pasteOriginal(snapshot); activatePreviousApp() }
        if settings.macroFailureBehavior != "silentlySkip" { notifier.notify(title: "Macro failed", body: message, deduplicationKey: nil) }
        return false
    }

    private func writeSnapshotText(
        _ snapshot: CurrentClipboardSnapshot,
        rich: Bool,
        recordOutput: Bool
    ) -> Bool {
        guard rich ? (snapshot.html?.isEmpty == false || snapshot.richText?.isEmpty == false || snapshot.text?.isEmpty == false)
                : snapshot.text?.isEmpty == false else { return false }
        let write: (NSPasteboard) -> Void = { pb in
            pb.clearContents()
            if rich, let html = snapshot.html {
                pb.setData(html, forType: .init("public.html"))
                if let text = snapshot.text, !text.isEmpty { pb.setString(text, forType: .string) }
            } else if rich, let data = snapshot.richText, let type = Self.richTextType(data) {
                pb.setData(data, forType: type)
                if let text = snapshot.text, !text.isEmpty { pb.setString(text, forType: .string) }
            } else if let text = snapshot.text {
                pb.setString(text, forType: .string)
            }
        }
        guard recordOutput else {
            suppressedWrite(write)
            return true
        }
        historyWrite(recording: NewClipboardItem(
            kind: "text",
            text: snapshot.text,
            richText: rich ? snapshot.richText : nil,
            html: rich ? snapshot.html : nil,
            sourceBundleID: snapshot.sourceBundleID,
            contentHash: rich
                ? snapshot.contentHash
                : snapshot.text.map { HashUtil.sha256Hex(of: Data($0.utf8)) },
            textAvailability: rich ? snapshot.textAvailability : .available
        ), write)
        return true
    }

    private func pasteOriginal(_ snapshot: CurrentClipboardSnapshot) {
        if snapshot.isImage, let data = snapshot.imageData {
            suppressedWrite {
                $0.clearContents()
                $0.setData(data, forType: .png)
            }
        } else {
            _ = writeSnapshotText(snapshot, rich: true, recordOutput: false)
        }
    }

    func debugMacro(macro: MacroScript, inputText: String) async throws -> MacroDebugReport {
        let input = MacroInput(
            isImage: false,
            imageData: nil,
            text: inputText,
            sourceBundleID: nil
        )
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

    private func writeText(
        _ content: ClipboardTextContent,
        rich: Bool,
        source: ClipboardItem,
        recordOutput: Bool = true
    ) -> Bool {
        guard rich ? content.canRichPaste : content.canUsePlainText else { return false }
        let write: (NSPasteboard) -> Void = { pb in
            pb.clearContents()
            if rich, let html = content.html, !html.isEmpty {
                pb.setData(html, forType: NSPasteboard.PasteboardType("public.html"))
                if let text = content.text, !text.isEmpty {
                    pb.setString(text, forType: .string)
                }
            } else if rich, let data = content.richText, let type = Self.richTextType(data) {
                pb.setData(data, forType: type); pb.setString(content.text ?? "", forType: .string)
            } else if let text = content.text { pb.setString(text, forType: .string) }
        }
        guard recordOutput else {
            suppressedWrite(write)
            return true
        }
        let contentHash: String? = if rich {
            source.contentHash
                ?? content.text.map { HashUtil.sha256Hex(of: Data($0.utf8)) }
                ?? content.html.map(HashUtil.sha256HTMLOnly)
        } else {
            content.text.map { HashUtil.sha256Hex(of: Data($0.utf8)) }
        }
        let historyItem = NewClipboardItem(
            kind: "text",
            text: content.text,
            richText: rich ? content.richText : nil,
            html: rich ? content.html : nil,
            sourceBundleID: source.sourceBundleID,
            contentHash: contentHash,
            textAvailability: rich
                ? content.textAvailability
                : (content.canUsePlainText ? .available : .unavailable)
        )
        historyWrite(recording: historyItem, write)
        return true
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
            guard writeText(content, rich: true, source: item, recordOutput: false) else { return false }
        }
        return true
    }

    private func textHistoryItem(text: String, source: ClipboardItem) -> NewClipboardItem {
        NewClipboardItem(
            kind: "text",
            text: text,
            sourceBundleID: source.sourceBundleID,
            contentHash: HashUtil.sha256Hex(of: Data(text.utf8))
        )
    }

    private func imageHistoryItem(data: Data, source: ClipboardItem) -> NewClipboardItem {
        NewClipboardItem(
            kind: "image",
            imageData: data,
            thumbnail: source.isImage ? source.thumbnail : nil,
            sourceBundleID: source.sourceBundleID,
            contentHash: HashUtil.sha256Hex(of: data)
        )
    }

    private func historyWrite(recording item: NewClipboardItem, _ body: (NSPasteboard) -> Void) {
        if item.kind == "text",
           item.text?.isEmpty != false,
           item.richText?.isEmpty != false,
           item.html?.isEmpty != false {
            suppressedWrite(body)
            return
        }
        if item.kind == "image", item.imageData?.isEmpty != false {
            suppressedWrite(body)
            return
        }
        pasteboard.performHistoryPasteboardWrite(recording: item, body)
    }

    private func suppressedWrite(_ body: (NSPasteboard) -> Void) {
        pasteboard.performSuppressedPasteboardWrite(body)
    }

    private func activatePreviousApp() {
        activator.activatePreviousAppAndPasteSynthetically(needsSynthetic: settings.needsAccessibilityForSyntheticPaste)
    }

    private func notifyPlainTextUnavailable() {
        notifier.notify(
            title: "Plain text unavailable",
            body: "This HTML item can be copied or pasted with formatting, but no usable text could be extracted.",
            deduplicationKey: "html-plain-text-unavailable"
        )
    }

    private static func richTextType(_ data: Data) -> NSPasteboard.PasteboardType? {
        if (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)) != nil { return .rtf }
        if (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)) != nil { return .rtfd }
        return nil
    }
}
