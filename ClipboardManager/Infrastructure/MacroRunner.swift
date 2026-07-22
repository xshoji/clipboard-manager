import Foundation
import AppKit

enum MacroError: Error, CustomStringConvertible {
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
        case .exitStatus(let s): return "Macro script exited with status \(s)."
        case .missingScript: return "Macro script file not found."
        case .emptyInlineScript: return "Inline Macro script is empty."
        case .invalidOutputEncoding: return "Macro output is not valid UTF-8 text."
        }
    }
}

enum MacroRunner {
    /// Sendable input for Macro execution. `ClipboardEntity` (@Model, non-Sendable) cannot be passed directly to `Task.detached`,
    /// so only the necessary information is extracted before execution (review #4).
    struct MacroInput: Sendable {
        let isImage: Bool
        let imageData: Data?
        let text: String?
        let sourceBundleID: String?
    }

    /// Sendable output containing the processed data and whether it decoded as an image.
    /// The image check is performed on the background task so the main actor never pays
    /// the decode cost (previously `NSImage(data:)` was called twice on the main actor).
    struct MacroOutput: Sendable {
        let data: Data
        let isImage: Bool
    }

    /// Process and temporary file paths, boxed as `@unchecked Sendable` so it can
    /// cross the `Task.detached` boundary. `Process` is reference-typed but is only
    /// accessed from a single logical flow after launch.
    private struct LaunchedProcess: @unchecked Sendable {
        let proc: Process
        let inputURL: URL
        let outputURL: URL
        let inlineScriptURL: URL?
    }

    /// Runs the Macro script asynchronously without blocking the cooperative thread pool.
    ///
    /// Previous implementation used `Task.detached` + `RunLoop.current.run` polling inside
    /// `Process.waitUntilTimeout`, which occupied a cooperative thread-pool worker for up
    /// to 5 s (+2 s on timeout). This version uses `terminationHandler` + `withTaskGroup`
    /// so no worker is held during the wait, and the `await` continuation returns to the
    /// main actor promptly after process exit.
    static func runAsync(
        script: MacroScript,
        input: MacroInput,
        verifyFingerprint: Bool
    ) async throws -> MacroOutput {
        // Prepare and launch on a background task (file I/O, fingerprint, etc.).
        let launched = try await Task.detached(priority: .userInitiated) {
            try prepareAndLaunch(script: script, input: input, verifyFingerprint: verifyFingerprint)
        }.value

        // Wait for process exit asynchronously (no thread-pool occupation).
        let timedOut = await waitForProcess(launched.proc, timeout: 5)

        if timedOut {
            cleanupFiles(launched)
            throw MacroError.timeout
        }
        if launched.proc.terminationStatus != 0 {
            cleanupFiles(launched)
            throw MacroError.exitStatus(launched.proc.terminationStatus)
        }

        // Read output and determine kind on a background task (image decode is heavy).
        return try await Task.detached(priority: .userInitiated) {
            defer { cleanupFiles(launched) }
            let fm = FileManager.default
            let outData: Data
            if let out = fm.contents(atPath: launched.outputURL.path), !out.isEmpty {
                outData = out
            } else {
                // If the output file was not created, there was no processing; paste the input as-is.
                outData = try Data(contentsOf: launched.inputURL)
            }
            let isImage = !outData.isEmpty && NSImage(data: outData)?.isValid == true
            return MacroOutput(data: outData, isImage: isImage)
        }.value
    }

    // MARK: - Preparation

    /// Creates temp files, validates the script, writes input, and launches the process.
    /// Runs inside `Task.detached` so all file I/O and fingerprint work stays off the main actor.
    private static func prepareAndLaunch(
        script: MacroScript,
        input: MacroInput,
        verifyFingerprint: Bool
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
                throw MacroError.emptyInlineScript
            }
            if verifyFingerprint {
                guard let stored = script.lastFingerprint else {
                    throw MacroError.fingerprintUnavailable
                }
                let actual = HashUtil.sha256Hex(of: Data(body.utf8))
                if actual != stored { throw MacroError.fingerprintMismatch }
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
            guard validation.fileExists else { throw MacroError.missingScript }
            guard validation.isInsideHome else { throw MacroError.scriptPathOutsideHome }
            if verifyFingerprint {
                // Fail-closed: refuse execution when neither stored nor actual file fingerprints are available (remaining-features #5).
                guard let stored = script.lastFingerprint else {
                    throw MacroError.fingerprintUnavailable
                }
                guard let actual = validation.fingerprint else {
                    throw MacroError.fingerprintUnavailable
                }
                if actual != stored { throw MacroError.fingerprintMismatch }
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

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        try proc.run()
        return LaunchedProcess(proc: proc, inputURL: inputURL, outputURL: outputURL, inlineScriptURL: inlineScriptURL)
    }

    // MARK: - Process waiting

    /// Waits for the process to exit or times out.
    ///
    /// Does NOT block the cooperative thread pool: uses `terminationHandler` +
    /// `withTaskGroup` instead of `RunLoop.current.run` polling. On timeout,
    /// sends SIGINT → SIGTERM and waits for actual exit so that
    /// `terminationStatus` / `terminationReason` are well-defined (review #3).
    /// - Returns: `true` if timed out, `false` if the process exited normally.
    private static func waitForProcess(_ proc: Process, timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            // Task 1: wait for process termination via terminationHandler.
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    proc.terminationHandler = { _ in
                        continuation.resume(returning: false)
                    }
                }
            }

            // Task 2: timeout.
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return true
            }

            let first = await group.next()!

            if first {
                // Timeout: SIGINT first, then SIGTERM.
                proc.interrupt()
                proc.terminate()
            }

            // Wait for the remaining task to complete.
            // On timeout: proc.terminate() triggers terminationHandler → Task 1 resumes.
            // On normal exit: group.cancelAll() cancels Task 2's sleep.
            group.cancelAll()
            _ = await group.next()

            return first
        }
    }

    // MARK: - Helpers

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
