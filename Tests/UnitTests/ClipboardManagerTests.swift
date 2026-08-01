import AppKit
import XCTest
@testable import ClipboardManager

@MainActor
final class PasteCoordinatorTests: XCTestCase {
    func testCompletedOcrUsesCachedTextWithoutRecognitionOrProgress() async {
        let harness = TestHarness()
        let item = makeClipboardItem(kind: "image")
        harness.repository.ocrResults[item.id] = .init(status: "completed", text: "cached text")
        let progressEvents = BoolRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .ocrProgressDidChange,
            object: nil,
            queue: nil
        ) { note in
            if let inProgress = note.userInfo?["inProgress"] as? Bool {
                progressEvents.append(inProgress)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await harness.coordinator.runOcr(item: item)

        XCTAssertEqual(harness.pasteboard.string, "cached text")
        let ocrCallCount = await harness.ocr.callCount
        XCTAssertEqual(ocrCallCount, 0)
        XCTAssertTrue(harness.repository.ocrUpdates.isEmpty)
        XCTAssertEqual(harness.activator.callCount, 1)
        XCTAssertTrue(harness.notifier.notifications.isEmpty)
        XCTAssertTrue(progressEvents.values.isEmpty)
    }

    func testPendingOcrNotifiesWithoutWritingOrRecognition() async {
        let harness = TestHarness()
        let item = makeClipboardItem(kind: "image")
        harness.repository.ocrResults[item.id] = .init(status: "pending", text: nil)

        await harness.coordinator.runOcr(item: item)

        XCTAssertNil(harness.pasteboard.string)
        let ocrCallCount = await harness.ocr.callCount
        XCTAssertEqual(ocrCallCount, 0)
        XCTAssertEqual(harness.activator.callCount, 0)
        XCTAssertEqual(harness.notifier.notifications.map(\.deduplicationKey), ["ocr-still-running"])
    }

    func testFreshOcrRecognizesUpdatesRepositoryAndPublishesProgress() async {
        let harness = TestHarness()
        let item = makeClipboardItem(kind: "image")
        harness.repository.imageData[item.id] = Data([1, 2, 3])
        await harness.ocr.setResult("recognized text")
        let progressEvents = BoolRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .ocrProgressDidChange,
            object: nil,
            queue: nil
        ) { note in
            if let inProgress = note.userInfo?["inProgress"] as? Bool {
                progressEvents.append(inProgress)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await harness.coordinator.runOcr(item: item)

        let calls = await harness.ocr.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.imageData, Data([1, 2, 3]))
        XCTAssertEqual(calls.first?.languages, ["en-US"])
        XCTAssertEqual(harness.repository.ocrUpdates.count, 1)
        XCTAssertEqual(harness.repository.ocrUpdates.first?.id, item.id)
        XCTAssertEqual(harness.repository.ocrUpdates.first?.text, "recognized text")
        XCTAssertEqual(harness.pasteboard.string, "recognized text")
        XCTAssertEqual(progressEvents.values, [true, false])
    }

    func testTextMacroSuccessBuildsInputWritesOutputAndActivates() async {
        let harness = TestHarness()
        let item = makeClipboardItem(kind: "text", sourceBundleID: "com.example.source")
        harness.repository.fullText[item.id] = "source text"
        await harness.macroRunner.setResponse(.success(.init(data: Data("transformed".utf8), isImage: false)))

        let succeeded = await harness.coordinator.runMacro(macro: makeMacro(), item: item)

        XCTAssertTrue(succeeded)
        let calls = await harness.macroRunner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.input.text, "source text")
        XCTAssertNil(calls.first?.input.imageData)
        XCTAssertEqual(calls.first?.input.sourceBundleID, "com.example.source")
        XCTAssertEqual(calls.first?.verifyFingerprint, true)
        XCTAssertEqual(harness.pasteboard.string, "transformed")
        XCTAssertEqual(harness.activator.callCount, 1)
        XCTAssertTrue(harness.notifier.notifications.isEmpty)
    }

    func testMacroFailureRestoresOriginalAndNotifies() async {
        let harness = TestHarness()
        let item = makeClipboardItem(kind: "text")
        harness.repository.fullText[item.id] = "source text"
        harness.repository.textContent[item.id] = .init(text: "original text", richText: nil, html: nil)
        await harness.macroRunner.setResponse(.failure(.timeout))

        let succeeded = await harness.coordinator.runMacro(macro: makeMacro(), item: item)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(harness.pasteboard.string, "original text")
        XCTAssertEqual(harness.activator.callCount, 1)
        XCTAssertEqual(harness.notifier.notifications.count, 1)
        XCTAssertEqual(harness.notifier.notifications.first?.title, "Macro failed")
        XCTAssertEqual(harness.notifier.notifications.first?.body, "Macro script timed out (>5s).")
    }

    func testMacroDebugUsesProductionInputWithoutPasteSideEffects() async throws {
        let harness = TestHarness()
        let item = makeClipboardItem(kind: "text", sourceBundleID: "com.example.source")
        harness.repository.fullText[item.id] = "source text"
        let expected = MacroDebugReport(
            command: "/bin/sh /tmp/macro.sh",
            environment: ["CB_ITEM_KIND": "text"],
            terminationStatus: 0,
            timedOut: false,
            duration: 0.1,
            standardOutput: "debug output",
            standardError: "",
            standardOutputTruncated: false,
            standardErrorTruncated: false,
            output: .init(
                kind: .text,
                totalByteCount: 11,
                previewText: "transformed",
                previewByteCount: 11,
                truncated: false
            ),
            usedInputFallback: false,
            errorMessage: nil
        )
        await harness.macroRunner.setDebugResponse(expected)

        let report = try await harness.coordinator.debugMacro(macro: makeMacro(), item: item)

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.standardOutput, "debug output")
        let calls = await harness.macroRunner.debugCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.input.text, "source text")
        XCTAssertEqual(calls.first?.input.sourceBundleID, "com.example.source")
        XCTAssertEqual(calls.first?.verifyFingerprint, true)
        XCTAssertNil(harness.pasteboard.string)
        XCTAssertEqual(harness.activator.callCount, 0)
        XCTAssertTrue(harness.notifier.notifications.isEmpty)
    }

    func testCopyMacroDebugReportUsesInjectedSuppressedPasteboardWithoutOtherSideEffects() {
        let harness = TestHarness()

        harness.coordinator.copyMacroDebugReport("debug report")

        XCTAssertEqual(harness.pasteboard.string, "debug report")
        XCTAssertEqual(harness.pasteboard.suppressedWriteCount, 1)
        XCTAssertEqual(harness.activator.callCount, 0)
        XCTAssertTrue(harness.notifier.notifications.isEmpty)
    }
}

final class MacroRunnerDebugTests: XCTestCase {
    func testDebugRunCapturesTerminalStreamsAndMacroOutput() async throws {
        let script = MacroScript(
            name: "Debug",
            scriptPath: "",
            inlineScript: """
            printf 'stdout line'
            printf 'stderr line' >&2
            cat "$CB_INPUT_FILE" > "$CB_OUTPUT_FILE"
            """
        )

        let report = try await MacroRunner.debugRunAsync(
            script: script,
            input: .init(isImage: false, imageData: nil, text: "transformed text", sourceBundleID: "com.example.source"),
            verifyFingerprint: false
        )

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.terminationStatus, 0)
        XCTAssertEqual(report.standardOutput, "stdout line")
        XCTAssertEqual(report.standardError, "stderr line")
        XCTAssertEqual(report.output?.kind, .text)
        XCTAssertEqual(report.output?.previewText, "transformed text")
        XCTAssertEqual(report.output?.totalByteCount, 16)
        XCTAssertEqual(report.environment["CB_ITEM_KIND"], "text")
        XCTAssertEqual(report.environment["CB_ITEM_SOURCE"], "com.example.source")
        XCTAssertFalse(report.usedInputFallback)
    }

    func testDebugRunDrainsAndTruncatesVerboseTerminalStreams() async throws {
        let script = MacroScript(
            name: "Verbose Debug",
            scriptPath: "",
            inlineScript: """
            head -c 300000 /dev/zero | tr '\\0' x
            head -c 300000 /dev/zero | tr '\\0' y >&2
            printf 'done' > "$CB_OUTPUT_FILE"
            """
        )

        let report = try await MacroRunner.debugRunAsync(
            script: script,
            input: .init(isImage: false, imageData: nil, text: "input", sourceBundleID: nil),
            verifyFingerprint: false
        )

        XCTAssertTrue(report.succeeded)
        XCTAssertTrue(report.standardOutputTruncated)
        XCTAssertTrue(report.standardErrorTruncated)
        XCTAssertEqual(report.standardOutput.utf8.count, 256 * 1024)
        XCTAssertEqual(report.standardError.utf8.count, 256 * 1024)
    }

    func testDebugRunPreservesFailureStreamsWithoutInputFallback() async throws {
        let script = MacroScript(
            name: "Failing Debug",
            scriptPath: "",
            inlineScript: """
            printf 'failure detail' >&2
            printf 'partial output' > "$CB_OUTPUT_FILE"
            exit 7
            """
        )

        let report = try await MacroRunner.debugRunAsync(
            script: script,
            input: .init(isImage: false, imageData: nil, text: "original input", sourceBundleID: nil),
            verifyFingerprint: false
        )

        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(report.terminationStatus, 7)
        XCTAssertEqual(report.standardError, "failure detail")
        XCTAssertEqual(report.output?.previewText, "partial output")
        XCTAssertFalse(report.usedInputFallback)
        XCTAssertEqual(report.errorMessage, "Macro script exited with status 7.")
    }

    func testDebugRunDoesNotWaitForBackgroundChildHoldingPipes() async throws {
        let script = MacroScript(
            name: "Background Child",
            scriptPath: "",
            inlineScript: """
            sleep 2 &
            printf 'done' > "$CB_OUTPUT_FILE"
            """
        )

        let startedAt = Date()
        let report = try await MacroRunner.debugRunAsync(
            script: script,
            input: .init(isImage: false, imageData: nil, text: "input", sourceBundleID: nil),
            verifyFingerprint: false
        )

        XCTAssertTrue(report.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testDebugRunDoesNotDrainForeverFromBackgroundWriter() async throws {
        let script = MacroScript(
            name: "Background Writer",
            scriptPath: "",
            inlineScript: """
            (while :; do printf x; done) &
            writer=$!
            (sleep 2; kill "$writer") >/dev/null 2>&1 &
            """
        )

        let startedAt = ContinuousClock.now
        let report = try await MacroRunner.debugRunAsync(
            script: script,
            input: .init(isImage: false, imageData: nil, text: "input", sourceBundleID: nil),
            verifyFingerprint: false
        )

        XCTAssertTrue(report.succeeded)
        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(1))
    }

    func testDebugRunCapturesTerminalSuffixesAtProcessExit() async throws {
        let suffix = "END-OF-STREAM"
        let script = MacroScript(
            name: "Suffix Debug",
            scriptPath: "",
            inlineScript: """
            i=0
            while [ "$i" -lt 100 ]; do printf 'stdout-%s\\n' "$i"; printf 'stderr-%s\\n' "$i" >&2; i=$((i + 1)); done
            printf '\(suffix)'
            printf '\(suffix)' >&2
            """
        )

        for _ in 0..<10 {
            let report = try await MacroRunner.debugRunAsync(
                script: script,
                input: .init(isImage: false, imageData: nil, text: "input", sourceBundleID: nil),
                verifyFingerprint: false
            )
            XCTAssertTrue(report.standardOutput.hasSuffix(suffix))
            XCTAssertTrue(report.standardError.hasSuffix(suffix))
        }
    }

    func testDebugRunBoundsLargeSuccessfulAndFailedOutputPreviews() async throws {
        for exitStatus in [0, 9] {
            let script = MacroScript(
                name: "Large Output",
                scriptPath: "",
                inlineScript: "head -c 300000 /dev/zero | tr '\\0' x > \"$CB_OUTPUT_FILE\"; exit \(exitStatus)"
            )

            let report = try await MacroRunner.debugRunAsync(
                script: script,
                input: .init(isImage: false, imageData: nil, text: "input", sourceBundleID: nil),
                verifyFingerprint: false
            )

            XCTAssertEqual(report.output?.totalByteCount, 300_000)
            XCTAssertEqual(report.output?.previewByteCount, 256 * 1024)
            XCTAssertEqual(report.output?.previewText?.utf8.count, 256 * 1024)
            XCTAssertEqual(report.output?.truncated, true)
        }
    }

    func testDebugRunBoundsLargeOutputPreviewAfterTimeout() async throws {
        let script = MacroScript(
            name: "Large Timed Out Output",
            scriptPath: "",
            inlineScript: """
            head -c 300000 /dev/zero | tr '\\0' x > "$CB_OUTPUT_FILE"
            trap '' INT TERM
            sleep 10
            """
        )

        let report = try await MacroRunner.debugRunAsync(
            script: script,
            input: .init(isImage: false, imageData: nil, text: "input", sourceBundleID: nil),
            verifyFingerprint: false
        )

        XCTAssertTrue(report.timedOut)
        XCTAssertEqual(report.output?.totalByteCount, 300_000)
        XCTAssertEqual(report.output?.previewByteCount, 256 * 1024)
        XCTAssertEqual(report.output?.truncated, true)
    }

    func testProductionRunDiscardsVerboseTerminalStreams() async throws {
        let script = MacroScript(
            name: "Verbose Production",
            scriptPath: "",
            inlineScript: """
            head -c 300000 /dev/zero
            head -c 300000 /dev/zero >&2
            printf 'done' > "$CB_OUTPUT_FILE"
            """
        )

        let output = try await MacroRunner.runAsync(
            script: script,
            input: .init(isImage: false, imageData: nil, text: "input", sourceBundleID: nil),
            verifyFingerprint: false
        )

        XCTAssertEqual(String(data: output.data, encoding: .utf8), "done")
    }

    func testDebugRunCancellationStopsProcessPromptly() async {
        let script = MacroScript(
            name: "Cancelled Debug",
            scriptPath: "",
            inlineScript: "trap '' INT TERM; while :; do :; done"
        )
        let task = Task {
            try await MacroRunner.debugRunAsync(
                script: script,
                input: .init(isImage: false, imageData: nil, text: "input", sourceBundleID: nil),
                verifyFingerprint: false
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        let startedAt = ContinuousClock.now

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(2))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

@MainActor
final class HistoryViewModelTests: XCTestCase {
    func testReloadSelectsFirstItemWhenThereIsNoSelection() async {
        let harness = TestHarness()
        let first = makeClipboardItem(kind: "text")
        let second = makeClipboardItem(kind: "text")
        harness.repository.items = [first, second]
        let viewModel = HistoryViewModel(
            repository: harness.repository,
            pasteCoordinator: harness.coordinator
        )

        await viewModel.reload()

        XCTAssertEqual(viewModel.items, [first, second])
        XCTAssertEqual(viewModel.selectedItem, first)
    }

    func testReloadPreservesSelectionByIDAndFallsBackWhenItDisappears() async {
        let harness = TestHarness()
        let first = makeClipboardItem(kind: "text")
        let selected = makeClipboardItem(kind: "text")
        harness.repository.items = [first, selected]
        let viewModel = HistoryViewModel(
            repository: harness.repository,
            pasteCoordinator: harness.coordinator
        )
        await viewModel.reload()
        viewModel.select(selected)

        harness.repository.items = [selected, first]
        await viewModel.reload()
        XCTAssertEqual(viewModel.selectedItem, selected)

        harness.repository.items = [first]
        await viewModel.reload()
        XCTAssertEqual(viewModel.selectedItem, first)
    }
}

final class HistoryFilterTests: XCTestCase {
    func testTextSearchIsCaseInsensitiveAndPreservesOrder() {
        let first = makeClipboardItem(kind: "text", textPreview: "Alpha")
        let second = makeClipboardItem(kind: "text", textPreview: "BRAVO")
        let third = makeClipboardItem(kind: "text", textPreview: "Bravo again")

        let result = HistoryFilter.filter(
            [first, second, third],
            query: "bravo",
            imagesOnly: false
        )

        XCTAssertEqual(result, [second, third])
    }

    func testSearchMatchesOcrBundleIdentifierAndContentHash() {
        let ocr = makeClipboardItem(kind: "image", ocrTextLowercased: "invoice total")
        let bundle = makeClipboardItem(kind: "text", sourceBundleID: "com.Example.Editor")
        let hash = makeClipboardItem(kind: "text", contentHash: "ABCDEF1234")

        XCTAssertEqual(HistoryFilter.filter([ocr, bundle, hash], query: "total", imagesOnly: false), [ocr])
        XCTAssertEqual(HistoryFilter.filter([ocr, bundle, hash], query: "example", imagesOnly: false), [bundle])
        XCTAssertEqual(HistoryFilter.filter([ocr, bundle, hash], query: "cdef", imagesOnly: false), [hash])
    }

    func testImagesOnlyCombinesWithSearchPredicate() {
        let matchingText = makeClipboardItem(kind: "text", textPreview: "Needle")
        let matchingImage = makeClipboardItem(kind: "image", ocrTextLowercased: "needle")
        let otherImage = makeClipboardItem(kind: "image", ocrTextLowercased: "other")

        XCTAssertEqual(
            HistoryFilter.filter(
                [matchingText, matchingImage, otherImage],
                query: "needle",
                imagesOnly: true
            ),
            [matchingImage]
        )
        XCTAssertEqual(
            HistoryFilter.filter(
                [matchingText, matchingImage, otherImage],
                query: "",
                imagesOnly: true
            ),
            [matchingImage, otherImage]
        )
    }
}

final class MacroScriptPathValidatorTests: XCTestCase {
    func testResolveRejectsBlankPaths() {
        XCTAssertNil(MacroScriptPathValidator.resolve(path: ""))
        XCTAssertNil(MacroScriptPathValidator.resolve(path: "  \n"))
    }

    func testDirectoryBoundaryDoesNotAcceptSiblingWithCommonPrefix() {
        let base = URL(fileURLWithPath: "/Users/example")

        XCTAssertTrue(MacroScriptPathValidator.isPath(
            url: URL(fileURLWithPath: "/Users/example/scripts/run.sh"),
            inside: base
        ))
        XCTAssertFalse(MacroScriptPathValidator.isPath(
            url: URL(fileURLWithPath: "/Users/example-other/run.sh"),
            inside: base
        ))
    }

    func testMissingPathReportsFileNotFound() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path

        let result = MacroScriptPathValidator.validate(path: path)

        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .fileNotFound)
        XCTAssertFalse(result.fileExists)
    }
}

final class KeyLabelRendererTests: XCTestCase {
    func testSpecialKeySymbolsAreStable() {
        XCTAssertEqual(KeyLabelRenderer.symbol(for: 0x24), "Return")
        XCTAssertEqual(KeyLabelRenderer.symbol(for: 0x35), "Esc")
        XCTAssertEqual(KeyLabelRenderer.symbol(for: 0x7E), "↑")
    }

    func testModifierSymbolsUseConventionalOrder() {
        let modifiers = Int(
            NSEvent.ModifierFlags.command.rawValue
                | NSEvent.ModifierFlags.shift.rawValue
                | NSEvent.ModifierFlags.option.rawValue
                | NSEvent.ModifierFlags.control.rawValue
        )

        XCTAssertEqual(
            KeyLabelRenderer.displayString(keyCode: 0x7A, modifiers: modifiers),
            "⌃⌥⇧⌘F1"
        )
    }
}

@MainActor
private final class TestHarness {
    let repository = RepositoryFake()
    let settings = SettingsFake()
    let pasteboard = PasteboardSpy()
    let ocr = OcrFake()
    let macroRunner = MacroRunnerFake()
    let activator = ActivatorSpy()
    let notifier = NotifierSpy()
    let coordinator: PasteCoordinator

    init() {
        coordinator = PasteCoordinator(
            repository: repository,
            settings: settings,
            pasteboard: pasteboard,
            ocr: ocr,
            macroRunner: macroRunner,
            activator: activator,
            notifier: notifier
        )
    }
}

private final class SettingsFake: PasteCoordinatorSettings {
    var macroSameDirectoryFingerprint = true
    var needsAccessibilityForSyntheticPaste = false
    var macroFailureBehavior = "restoreOriginalAndNotify"
    var ocrLanguages = ["en-US"]
}

@MainActor
private final class RepositoryFake: ClipboardRepositoryPort {
    var items: [ClipboardItem] = []
    var textContent: [UUID: ClipboardTextContent] = [:]
    var imageData: [UUID: Data] = [:]
    var fullText: [UUID: String] = [:]
    var ocrResults: [UUID: ClipboardOcrResult] = [:]
    var ocrUpdates: [(id: UUID, text: String?)] = []

    func fetchAll() async -> [ClipboardItem] { items }
    func fetch(id: UUID) async -> ClipboardItem? { items.first { $0.id == id } }
    func fetchTextContent(id: UUID, includeRich: Bool) async -> ClipboardTextContent? { textContent[id] }
    func fetchImageData(id: UUID) async -> Data? { imageData[id] }
    func fetchFullText(id: UUID) async -> String? { fullText[id] }
    func fetchHtmlContent(id: UUID) async -> Data? { textContent[id]?.html }
    func fetchOcrResult(id: UUID) async -> ClipboardOcrResult? { ocrResults[id] }
    func insert(_ item: NewClipboardItem, removingDuplicates: Bool, purpose: String) -> Bool { true }
    func updateOcrResult(id: UUID, text: String?) -> Bool {
        ocrUpdates.append((id, text))
        return true
    }
    func delete(id: UUID) -> Bool { true }
    func clearAll() -> Bool { true }
}

private final class PasteboardSpy: PasteboardSuppressing {
    private let pasteboard = NSPasteboard(name: .init("ClipboardManagerTests.\(UUID().uuidString)"))

    var string: String? { pasteboard.string(forType: .string) }
    private(set) var suppressedWriteCount = 0

    func performSuppressedPasteboardWrite(_ write: (NSPasteboard) -> Void) -> Int {
        suppressedWriteCount += 1
        write(pasteboard)
        return pasteboard.changeCount
    }

    deinit {
        pasteboard.releaseGlobally()
    }
}

private actor OcrFake: OcrRecognizing {
    struct Call: Sendable {
        let imageData: Data
        let languages: [String]
    }

    private(set) var calls: [Call] = []
    var callCount: Int { calls.count }
    private var result: String?

    func setResult(_ result: String?) {
        self.result = result
    }

    func recognizeText(in imageData: Data, languages: [String]) async -> String? {
        calls.append(.init(imageData: imageData, languages: languages))
        return result
    }
}

private actor MacroRunnerFake: MacroRunning {
    struct Call: Sendable {
        let script: MacroScript
        let input: MacroInput
        let verifyFingerprint: Bool
    }

    private(set) var calls: [Call] = []
    private(set) var debugCalls: [Call] = []
    private var response: Result<MacroOutput, MacroRunningError> = .failure(.missingScript)
    private var debugResponse = MacroDebugReport.notLaunched(
        command: "/bin/sh <test>",
        errorMessage: "No debug response configured."
    )

    func setResponse(_ response: Result<MacroOutput, MacroRunningError>) {
        self.response = response
    }

    func setDebugResponse(_ response: MacroDebugReport) {
        debugResponse = response
    }

    func runAsync(
        script: MacroScript,
        input: MacroInput,
        verifyFingerprint: Bool
    ) async throws -> MacroOutput {
        calls.append(.init(script: script, input: input, verifyFingerprint: verifyFingerprint))
        return try response.get()
    }

    func debugRunAsync(
        script: MacroScript,
        input: MacroInput,
        verifyFingerprint: Bool
    ) async throws -> MacroDebugReport {
        debugCalls.append(.init(script: script, input: input, verifyFingerprint: verifyFingerprint))
        return debugResponse
    }
}

private final class BoolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    var values: [Bool] {
        lock.withLock { storage }
    }

    func append(_ value: Bool) {
        lock.withLock { storage.append(value) }
    }
}

@MainActor
private final class ActivatorSpy: AppActivating {
    private(set) var callCount = 0

    func activatePreviousAppAndPasteSynthetically(needsSynthetic: Bool) {
        callCount += 1
    }
}

@MainActor
private final class NotifierSpy: AppNotifying {
    struct Notification {
        let title: String
        let body: String
        let deduplicationKey: String?
    }

    private(set) var notifications: [Notification] = []

    func notify(title: String, body: String, deduplicationKey: String?) {
        notifications.append(.init(
            title: title,
            body: body,
            deduplicationKey: deduplicationKey
        ))
    }
}

private func makeClipboardItem(
    kind: String,
    textPreview: String? = nil,
    sourceBundleID: String? = nil,
    contentHash: String? = nil,
    ocrTextLowercased: String? = nil
) -> ClipboardItem {
    ClipboardItem(
        id: UUID(),
        createdAt: Date(),
        kind: kind,
        textPreview: textPreview,
        textPreviewLowercased: textPreview?.lowercased(),
        isTextPreviewTruncated: false,
        textCharacterCount: nil,
        thumbnail: nil,
        isHtml: false,
        sourceBundleID: sourceBundleID,
        contentHash: contentHash,
        ocrTextLowercased: ocrTextLowercased
    )
}

private func makeMacro() -> MacroScript {
    MacroScript(name: "Test Macro", scriptPath: "", inlineScript: "cat")
}
