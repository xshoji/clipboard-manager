import Foundation
import AppKit
import Darwin

/// Macro execution infrastructure.
///
/// Dependency direction note (layers review M2/M3): `MacroRunner` lives in
/// Infrastructure but reuses the ApplicationServices-side `MacroInput` /
/// `MacroOutput` / `MacroRunningError` types defined in
/// `PasteCoordinatorPorts.swift`. The Infrastructure -> ApplicationServices port
/// dependency is legal (inward), and reusing the port types removes the previous
/// duplicated `MacroRunner.MacroInput` / `MacroRunner.MacroOutput` / `MacroError`
/// definitions plus the 1:1 `portError(from:)` mapping in `MacroRunnerAdapter`.
///
/// `invalidOutputEncoding` is now thrown here (Infrastructure) right after the
/// output bytes are read and the image check completes, instead of in
/// `PasteCoordinator` (ApplicationServices), so byte-level encoding validation
/// stays in the layer that owns the bytes.
enum MacroRunner {
    private static let capturedStreamLimit = 256 * 1024

    /// Process and temporary file paths, boxed as `@unchecked Sendable` so it can
    /// cross the `Task.detached` boundary. `Process` is reference-typed but is only
    /// accessed from a single logical flow after launch.
    private struct LaunchedProcess: @unchecked Sendable {
        let proc: Process
        let inputURL: URL
        let outputURL: URL
        let inlineScriptURL: URL?
        let standardOutput: Pipe?
        let standardError: Pipe?
        let command: String
        let debugEnvironment: [String: String]
    }

    private struct CapturedStream: Sendable {
        let text: String
        let truncated: Bool
    }

    private final class StreamCollector: @unchecked Sendable {
        private let queue: DispatchQueue
        private let handle: FileHandle
        private let source: DispatchSourceRead
        private var captured = Data()
        private var totalBytes = 0
        private var finished = false

        init(pipe: Pipe, label: String) {
            handle = pipe.fileHandleForReading
            queue = DispatchQueue(label: label)
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            if flags >= 0 {
                _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
            }
            source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readOnce() }
            source.setCancelHandler { [handle] in try? handle.close() }
            source.resume()
        }

        func finish() -> CapturedStream {
            queue.sync {
                finished = true
                source.cancel()
                finalDrain()
                return CapturedStream(
                    text: String(decoding: captured, as: UTF8.self),
                    truncated: totalBytes > captured.count
                )
            }
        }

        private func readOnce() {
            guard !finished else { return }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if count > 0 { append(buffer, count: count) }
        }

        private func finalDrain() {
            // Once the direct process exits, descendants may keep writing forever.
            // Read only enough buffered data to fill the preview and detect truncation.
            var bytesRemaining = max(0, MacroRunner.capturedStreamLimit + 1 - totalBytes)
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while bytesRemaining > 0 {
                let requested = min(buffer.count, bytesRemaining)
                let count = Darwin.read(handle.fileDescriptor, &buffer, requested)
                if count > 0 {
                    append(buffer, count: count)
                    bytesRemaining -= count
                } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                } else if errno != EINTR {
                    return
                }
            }
        }

        private func append(_ buffer: [UInt8], count: Int) {
            totalBytes += count
            let remaining = max(0, MacroRunner.capturedStreamLimit - captured.count)
            if remaining > 0 {
                captured.append(contentsOf: buffer.prefix(min(count, remaining)))
            }
        }
    }

    private struct Execution: @unchecked Sendable {
        let launched: LaunchedProcess
        let timedOut: Bool
        let terminationStatus: Int32?
        let duration: TimeInterval
        let standardOutput: CapturedStream
        let standardError: CapturedStream
    }

    /// Runs the Macro script asynchronously without blocking the cooperative thread pool.
    /// Process status is polled with cancellable sleeps; stdout and stderr are discarded
    /// because the production paste path does not display terminal output.
    static func runAsync(
        script: MacroScript,
        input: MacroInput,
        verifyFingerprint: Bool
    ) async throws -> MacroOutput {
        let execution = try await execute(
            script: script,
            input: input,
            verifyFingerprint: verifyFingerprint,
            captureStreams: false
        )
        defer { cleanupFiles(execution.launched) }
        if execution.timedOut { throw MacroRunningError.timeout }
        guard let status = execution.terminationStatus else { throw MacroRunningError.timeout }
        if status != 0 {
            throw MacroRunningError.exitStatus(status)
        }
        return try resolveOutput(execution.launched).output
    }

    static func debugRunAsync(
        script: MacroScript,
        input: MacroInput,
        verifyFingerprint: Bool
    ) async throws -> MacroDebugReport {
        let fallbackCommand = "\(script.interpreter) \(script.inlineScript == nil ? script.scriptPath : "<inline-script>")"
        do {
            let execution = try await execute(
                script: script,
                input: input,
                verifyFingerprint: verifyFingerprint,
                captureStreams: true
            )
            defer { cleanupFiles(execution.launched) }
            let status = execution.terminationStatus
            var output: MacroOutputPreview?
            var usedInputFallback = false
            var errorMessage: String?
            if execution.timedOut {
                errorMessage = MacroRunningError.timeout.description
                output = try? readOutputPreview(execution.launched, useInputFallback: false)
            } else if let status, status != 0 {
                errorMessage = MacroRunningError.exitStatus(status).description
                output = try? readOutputPreview(execution.launched, useInputFallback: false)
            } else {
                do {
                    usedInputFallback = try outputFileIsEmpty(execution.launched)
                    output = try readOutputPreview(execution.launched, useInputFallback: usedInputFallback)
                } catch {
                    output = try? readOutputPreview(execution.launched, useInputFallback: false)
                    errorMessage = (error as? MacroRunningError)?.description ?? error.localizedDescription
                }
            }
            return MacroDebugReport(
                command: execution.launched.command,
                environment: execution.launched.debugEnvironment,
                terminationStatus: status,
                timedOut: execution.timedOut,
                duration: execution.duration,
                standardOutput: execution.standardOutput.text,
                standardError: execution.standardError.text,
                standardOutputTruncated: execution.standardOutput.truncated,
                standardErrorTruncated: execution.standardError.truncated,
                output: output,
                usedInputFallback: usedInputFallback,
                errorMessage: errorMessage
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let message = (error as? MacroRunningError)?.description ?? error.localizedDescription
            return .notLaunched(command: fallbackCommand, errorMessage: message)
        }
    }

    private static func execute(
        script: MacroScript,
        input: MacroInput,
        verifyFingerprint: Bool,
        captureStreams: Bool
    ) async throws -> Execution {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let launched = try await Task.detached(priority: .userInitiated) {
            try prepareAndLaunch(
                script: script,
                input: input,
                verifyFingerprint: verifyFingerprint,
                captureStreams: captureStreams
            )
        }.value
        let stdoutCollector = launched.standardOutput.map {
            StreamCollector(pipe: $0, label: "ClipboardManager.MacroRunner.stdout")
        }
        let stderrCollector = launched.standardError.map {
            StreamCollector(pipe: $0, label: "ClipboardManager.MacroRunner.stderr")
        }
        do {
            let timedOut = try await waitForProcess(launched.proc, timeout: .seconds(5))
            let standardOutput = stdoutCollector?.finish() ?? .init(text: "", truncated: false)
            let standardError = stderrCollector?.finish() ?? .init(text: "", truncated: false)
            return Execution(
                launched: launched,
                timedOut: timedOut,
                terminationStatus: launched.proc.isRunning ? nil : launched.proc.terminationStatus,
                duration: timeInterval(clock.now - startedAt),
                standardOutput: standardOutput,
                standardError: standardError
            )
        } catch {
            await stopProcess(launched.proc)
            _ = stdoutCollector?.finish()
            _ = stderrCollector?.finish()
            cleanupFiles(launched)
            throw error
        }
    }

    // MARK: - Preparation

    /// Creates temp files, validates the script, writes input, and launches the process.
    /// Runs inside `Task.detached` so all file I/O and fingerprint work stays off the main actor.
    private static func prepareAndLaunch(
        script: MacroScript,
        input: MacroInput,
        verifyFingerprint: Bool,
        captureStreams: Bool
    ) throws -> LaunchedProcess {
        let fm = FileManager.default
        let ext = input.isImage ? "png" : "txt"
        let tmp = NSTemporaryDirectory()
        let inputURL = URL.fileTemporary("cb_input", ext: ext, base: tmp)
        let outputURL = URL.fileTemporary("cb_output", ext: ext, base: tmp)
        let inlineScriptURL = script.inlineScript.map { _ in
            URL.fileTemporary("cb_macro", ext: "sh", base: tmp)
        }

        let executableScriptPath: String
        if let body = script.inlineScript, let inlineScriptURL {
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MacroRunningError.emptyInlineScript
            }
            if verifyFingerprint {
                guard let stored = script.lastFingerprint else {
                    throw MacroRunningError.fingerprintUnavailable
                }
                let actual = HashUtil.sha256Hex(of: Data(body.utf8))
                if actual != stored { throw MacroRunningError.fingerprintMismatch }
            }
            guard fm.createFile(
                atPath: inlineScriptURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let scriptFile = try FileHandle(forWritingTo: inlineScriptURL)
            try scriptFile.write(contentsOf: Data(body.utf8))
            try scriptFile.close()
            executableScriptPath = inlineScriptURL.path
        } else {
            // remaining-features #5, #14: validate using the normalized real path.
            let validation = MacroScriptPathValidator.validate(path: script.scriptPath)
            guard validation.fileExists else { throw MacroRunningError.missingScript }
            guard validation.isInsideHome else { throw MacroRunningError.scriptPathOutsideHome }
            if verifyFingerprint {
                // Fail-closed: refuse execution when neither stored nor actual file fingerprints are available (remaining-features #5).
                guard let stored = script.lastFingerprint else {
                    throw MacroRunningError.fingerprintUnavailable
                }
                guard let actual = validation.fingerprint else {
                    throw MacroRunningError.fingerprintUnavailable
                }
                if actual != stored { throw MacroRunningError.fingerprintMismatch }
            }
            executableScriptPath = validation.resolvedPath
        }

        try writeInput(to: inputURL, input: input)
        if !fm.fileExists(atPath: outputURL.path) {
            fm.createFile(atPath: outputURL.path, contents: nil)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: script.interpreter)
        proc.arguments = [executableScriptPath]
        var env = ProcessInfo.processInfo.environment
        env["CB_INPUT_FILE"] = inputURL.path
        env["CB_OUTPUT_FILE"] = outputURL.path
        env["CB_ITEM_KIND"] = input.isImage ? "image" : "text"
        env["CB_ITEM_SOURCE"] = input.sourceBundleID ?? ""
        proc.environment = env

        let standardOutput = captureStreams ? Pipe() : nil
        let standardError = captureStreams ? Pipe() : nil
        proc.standardOutput = standardOutput ?? FileHandle.nullDevice
        proc.standardError = standardError ?? FileHandle.nullDevice

        try proc.run()
        try? standardOutput?.fileHandleForWriting.close()
        try? standardError?.fileHandleForWriting.close()
        return LaunchedProcess(
            proc: proc,
            inputURL: inputURL,
            outputURL: outputURL,
            inlineScriptURL: inlineScriptURL,
            standardOutput: standardOutput,
            standardError: standardError,
            command: "\(shellQuoted(script.interpreter)) \(shellQuoted(executableScriptPath))",
            debugEnvironment: [
                "CB_INPUT_FILE": inputURL.path,
                "CB_OUTPUT_FILE": outputURL.path,
                "CB_ITEM_KIND": input.isImage ? "image" : "text",
                "CB_ITEM_SOURCE": input.sourceBundleID ?? "",
            ]
        )
    }

    // MARK: - Process waiting

    /// Waits for the process to exit or times out.
    ///
    /// Does NOT block the cooperative thread pool. On timeout, sends SIGINT and
    /// SIGTERM, then escalates to SIGKILL after a short grace period so an
    /// uncooperative script cannot stall Macro execution indefinitely.
    /// - Returns: `true` if timed out, `false` if the process exited normally.
    private static func waitForProcess(_ proc: Process, timeout: Duration) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while proc.isRunning, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard proc.isRunning else { return false }
        await stopProcess(proc)
        return true
    }

    private static func stopProcess(_ proc: Process) async {
        await Task.detached(priority: .userInitiated) {
            guard proc.isRunning else { return }
            proc.interrupt()
            proc.terminate()
            let graceDeadline = ContinuousClock.now.advanced(by: .milliseconds(250))
            while proc.isRunning, ContinuousClock.now < graceDeadline { usleep(20_000) }
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            let killDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while proc.isRunning, ContinuousClock.now < killDeadline { usleep(20_000) }
        }.value
    }

    // MARK: - Helpers

    private static func resolveOutput(_ launched: LaunchedProcess) throws -> (output: MacroOutput, usedInputFallback: Bool) {
        let fm = FileManager.default
        let produced = fm.contents(atPath: launched.outputURL.path)
        let usedInputFallback = produced?.isEmpty != false
        let outData = usedInputFallback ? try Data(contentsOf: launched.inputURL) : produced ?? Data()
        let isImage = !outData.isEmpty && NSImage(data: outData)?.isValid == true
        if !isImage, !outData.isEmpty, String(data: outData, encoding: .utf8) == nil {
            throw MacroRunningError.invalidOutputEncoding
        }
        return (MacroOutput(data: outData, isImage: isImage), usedInputFallback)
    }

    private static func outputFileIsEmpty(_ launched: LaunchedProcess) throws -> Bool {
        try fileByteCount(at: launched.outputURL) == 0
    }

    private static func readOutputPreview(
        _ launched: LaunchedProcess,
        useInputFallback: Bool
    ) throws -> MacroOutputPreview? {
        let url = useInputFallback ? launched.inputURL : launched.outputURL
        let totalByteCount = try fileByteCount(at: url)
        guard totalByteCount > 0 else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: capturedStreamLimit) ?? Data()
        let truncated = totalByteCount > Int64(data.count)
        let kind: MacroOutputPreview.Kind
        let previewText: String?
        if !truncated, NSImage(data: data)?.isValid == true {
            kind = .image
            previewText = nil
        } else if let text = utf8Preview(data, truncated: truncated) {
            kind = .text
            previewText = text
        } else {
            kind = .binary
            previewText = nil
        }
        return MacroOutputPreview(
            kind: kind,
            totalByteCount: totalByteCount,
            previewText: previewText,
            previewByteCount: data.count,
            truncated: truncated
        )
    }

    private static func fileByteCount(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func utf8Preview(_ data: Data, truncated: Bool) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        guard truncated else { return nil }
        for removedBytes in 1...min(3, data.count) {
            if let text = String(data: data.dropLast(removedBytes), encoding: .utf8) { return text }
        }
        return nil
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func writeInput(to url: URL, input: MacroInput) throws {
        if input.isImage, let png = input.imageData {
            try png.write(to: url)
        } else if let t = input.text {
            try Data(t.utf8).write(to: url)
        } else {
            try Data().write(to: url)
        }
    }

    private static func cleanupFiles(_ launched: LaunchedProcess) {
        let fm = FileManager.default
        try? fm.removeItem(at: launched.inputURL)
        try? fm.removeItem(at: launched.outputURL)
        if let inlineScriptURL = launched.inlineScriptURL {
            try? fm.removeItem(at: inlineScriptURL)
        }
    }
}

private extension URL {
    static func fileTemporary(_ name: String, ext: String, base: String) -> URL {
        URL(fileURLWithPath: base)
            .appendingPathComponent("\(name)_\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }
}
