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

    /// Runs the Macro script on a background queue and returns the resulting Data.
    /// Does not block the main thread (review #4).
    /// On timeout, sends SIGINT → SIGTERM, then waits reliably with `waitUntilExit()` (review #3).
    static func runAsync(
        script: MacroScript,
        input: MacroInput,
        verifyFingerprint: Bool
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try run(script: script, input: input, verifyFingerprint: verifyFingerprint)
        }.value
    }

    /// Synchronous Macro execution. Intended to be called on a background Task.
    /// Calling directly from the main thread blocks the UI while spinning the RunLoop.
    static func run(
        script: MacroScript,
        input: MacroInput,
        verifyFingerprint: Bool
    ) throws -> Data {
        let fm = FileManager.default
        let ext = input.isImage ? "png" : "txt"
        let tmp = NSTemporaryDirectory()
        let inputURL = URL.fileTemporary("cb_input", ext: ext, base: tmp)
        let outputURL = URL.fileTemporary("cb_output", ext: ext, base: tmp)
        let inlineScriptURL = script.inlineScript.map { _ in
            URL.fileTemporary("cb_macro", ext: "sh", base: tmp)
        }
        defer {
            try? fm.removeItem(at: inputURL)
            try? fm.removeItem(at: outputURL)
            if let inlineScriptURL {
                try? fm.removeItem(at: inlineScriptURL)
            }
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
        proc.waitUntilTimeout(timeout: 5)

        switch proc.terminationReason {
        case .uncaughtSignal:
            throw MacroError.timeout
        default:
            break
        }
        if proc.terminationStatus != 0 {
            throw MacroError.exitStatus(proc.terminationStatus)
        }

        if let outData = fm.contents(atPath: outputURL.path), !outData.isEmpty {
            return outData
        }
        // If the output file was not created, there was no processing; paste the input as-is.
        return try Data(contentsOf: inputURL)
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
}

private extension URL {
    static func fileTemporary(_ name: String, ext: String, base: String) -> URL {
        URL(fileURLWithPath: base)
            .appendingPathComponent("\(name)_\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }
}

private extension Process {
    func waitUntilTimeout(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning, Date() < deadline {
            let _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if isRunning {
            // Send SIGINT first; if there is no response, force termination with SIGTERM.
            // In either case, wait for the process to actually exit with `waitUntilExit()` before reading
            // terminationStatus / terminationReason, otherwise the values are undefined (review #3).
            interrupt()
            terminate()
            // After forced termination the process should exit immediately, but wait a short bounded time to be sure.
            let forceDeadline = Date().addingTimeInterval(2.0)
            while isRunning, Date() < forceDeadline {
                let _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            // Last resort when RunLoop.spin did not catch the exit: synchronous wait.
            if isRunning {
                waitUntilExit()
            }
        }
    }
}
