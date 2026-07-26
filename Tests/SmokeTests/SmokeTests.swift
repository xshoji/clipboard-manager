import XCTest
import AppKit

/// Lightweight launch smoke test with settings backup/restore.
///
/// Test flow:
/// 1. Terminate any running production app (prevents hotkey double-registration
///    and pasteboard double-monitoring).
/// 2. Export UserDefaults to temporary plists via `defaults export`:
///    - `com.xshoji.ClipboardManager` (.app bundle = production app domain)
///    - `ClipboardManager` (SPM bare executable = test binary domain)
/// 3. Overwrite the test binary's hotkey modifiers to cmd+ctrl+opt+shift
///    via `defaults write` — guaranteed not to collide with the production
///    default of cmd+ctrl.
/// 4. Launch the `swift build` binary and verify it survives for several
///    seconds without crashing.
/// 5. Terminate the test process via SIGTERM, falling back to SIGKILL on
///    timeout.
/// 6. Restore the backed-up settings via `defaults import`.
///
/// Notes:
/// - SPM bare executables have no Bundle Identifier, so UserDefaults uses
///   the executable name `ClipboardManager` as its domain (distinct from the
///   production .app's `com.xshoji.ClipboardManager`).
/// - The app opens the real SwiftData store under
///   `~/Library/Application Support`. Clipboard monitoring during the test
///   will save real pasteboard contents into history (clipboard history
///   pollution is accepted).
/// - Settings (UserDefaults) are reliably restored before and after the test.
/// - If the production app is running, it is force-terminated at test start.
@MainActor
final class SmokeTests: XCTestCase {
    /// Bundle Identifier of the production app (.app bundle).
    private static let bundleID = "com.xshoji.ClipboardManager"

    /// UserDefaults domain for the SPM bare executable (executable name).
    private static let spmDefaultsDomain = "ClipboardManager"

    /// Temporary plist paths for UserDefaults backup.
    private static let backupPathBundle = NSTemporaryDirectory() + "cm-e2e-settings-bundle.plist"
    private static let backupPathSPM = NSTemporaryDirectory() + "cm-e2e-settings-spm.plist"

    /// Test hotkey modifiers: cmd+ctrl+opt+shift (4 modifiers).
    /// Guaranteed not to collide with the production default of cmd+ctrl.
    private static let testHotkeyModifiers = Int(
        NSEvent.ModifierFlags.command.rawValue
        | NSEvent.ModifierFlags.control.rawValue
        | NSEvent.ModifierFlags.option.rawValue
        | NSEvent.ModifierFlags.shift.rawValue
    )

    /// Whether settings backup succeeded (ensures restore runs only once).
    private static var backupTaken = false

    /// Seconds the app must survive after launch without crashing to pass.
    private let survivalSeconds: TimeInterval = 5

    /// Seconds to wait after SIGTERM before sending SIGKILL.
    private let terminateTimeoutSeconds: TimeInterval = 3

    // MARK: - Setup / Teardown

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 1. Terminate the production app if it is running.
        Self.terminateRunningApp()
        // 2. Back up settings only once (subsequent test cases do not overwrite).
        if !Self.backupTaken {
            try Self.exportSettings()
            Self.backupTaken = true
        }
        // 3. Overwrite test hotkeys (on the SPM domain the test binary reads).
        try Self.setTestHotkeys()
    }

    override class func tearDown() {
        // 6. Restore backed-up settings (only if export succeeded).
        if Self.backupTaken {
            try? Self.restoreSettings()
        }
        super.tearDown()
    }

    // MARK: - Tests

    func testAppLaunchesWithoutCrash() throws {
        log("testAppLaunchesWithoutCrash: start")

        log("buildAndLocateBinary: begin")
        let binaryPath = try buildAndLocateBinary()
        log("buildAndLocateBinary: done path=\(binaryPath)")

        let app = Process()
        app.executableURL = URL(fileURLWithPath: binaryPath)
        // Redirect child process stdout/stderr to /dev/null to avoid
        // pipe EOF waits and log noise.
        let devnull = FileHandle(forWritingAtPath: "/dev/null")!
        app.standardOutput = devnull
        app.standardError = devnull

        log("Process.run: begin")
        try app.run()
        log("Process.run: done pid=\(app.processIdentifier)")

        // Always terminate, regardless of success or failure.
        defer {
            Self.forceTerminate(app, timeout: terminateTimeoutSeconds)
        }

        // Wait for the survival period and check the process is still alive.
        log("sleep \(survivalSeconds)s start")
        Thread.sleep(forTimeInterval: survivalSeconds)
        log("sleep done, isRunning=\(app.isRunning)")

        XCTAssertTrue(
            app.isRunning,
            "App exited within \(survivalSeconds) seconds (possible crash). exitCode=\(app.terminationStatus)"
        )
        log("testAppLaunchesWithoutCrash: assertion passed ✓")
    }

    /// Writes unbuffered log output to stderr (XCTest buffers stdout).
    private static func log(_ msg: String) {
        let line = "[SmokeTests] \(msg)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
    private func log(_ msg: String) {
        Self.log(msg)
    }

    // MARK: - Helpers

    /// Terminates any running production app. No-op if none is running.
    private static func terminateRunningApp() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !apps.isEmpty else { return }
        Self.log("Terminating \(apps.count) running app instance(s)")
        for app in apps {
            app.terminate()
        }
        // terminate() is asynchronous; wait briefly to ensure exit.
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// Exports current UserDefaults to temporary plists via `defaults export`.
    /// Backs up both the production domain (.app) and the SPM domain (bare executable).
    private static func exportSettings() throws {
        try runShell("defaults export \(bundleID) '\(backupPathBundle)'")
        // The SPM domain plist may not exist yet (export succeeds with an empty plist).
        try runShell("defaults export \(spmDefaultsDomain) '\(backupPathSPM)'")
        Self.log("Settings exported to temporary plists")
    }

    /// Restores backed-up settings via `defaults import`.
    private static func restoreSettings() throws {
        try runShell("defaults import \(bundleID) '\(backupPathBundle)'")
        try runShell("defaults import \(spmDefaultsDomain) '\(backupPathSPM)'")
        Self.log("Settings restored from temporary plists")
    }

    /// Overwrites all hotkey modifier keys in the SPM domain (read by the test
    /// binary) to the test value (cmd+ctrl+opt+shift).
    private static func setTestHotkeys() throws {
        let mods = testHotkeyModifiers
        let modifierKeys = [
            "hotkeyModifiers",
            "editHotkeyModifiers",
            "pastePlainHotkeyModifiers",
            "macroPickerHotkeyModifiers",
        ]
        for key in modifierKeys {
            try runShell("defaults write \(spmDefaultsDomain) \(key) -int \(mods)")
        }
        Self.log("Test hotkeys written to SPM domain (\(spmDefaultsDomain))")
    }

    /// Terminates the process via SIGTERM, falling back to SIGKILL on timeout.
    /// Using only `waitUntilExit()` can hang if NSApplication's terminate
    /// handler does not complete.
    private static func forceTerminate(_ proc: Process, timeout: TimeInterval) {
        guard proc.isRunning else {
            proc.waitUntilExit()
            return
        }
        let pid = proc.processIdentifier
        Self.log("Terminating pid=\(pid) (SIGTERM)")

        // Send SIGTERM (equivalent to Process.terminate).
        kill(pid, SIGTERM)

        // Poll every 100ms until the timeout.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !proc.isRunning {
                proc.waitUntilExit()
                Self.log("pid=\(pid) exited after SIGTERM (code=\(proc.terminationStatus))")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        // If SIGTERM did not work, force-kill with SIGKILL.
        Self.log("pid=\(pid) did not exit after \(timeout)s, sending SIGKILL")
        kill(pid, SIGKILL)
        proc.waitUntilExit()
        Self.log("pid=\(pid) killed (code=\(proc.terminationStatus))")
    }

    /// Runs a shell command; throws on non-zero exit.
    @discardableResult
    private static func runShell(_ command: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", command]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            throw NSError(
                domain: "SmokeTests",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Shell command failed: \(command)\n\(output)"]
            )
        }
        return output
    }

    /// Returns the absolute path of the `ClipboardManager` executable by
    /// querying `swift build --show-bin-path`.
    /// Does NOT run `swift build` here because `swift test` has already
    /// built the binary (calling `swift build` would deadlock on the
    /// `.build` directory lock).
    private func buildAndLocateBinary() throws -> String {
        let pathProc = Process()
        pathProc.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        pathProc.arguments = ["build", "--show-bin-path"]
        let pathPipe = Pipe()
        pathProc.standardOutput = pathPipe
        try pathProc.run()
        let pathData = pathPipe.fileHandleForReading.readDataToEndOfFile()
        pathProc.waitUntilExit()

        let binDir = String(data: pathData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertFalse(binDir.isEmpty, "swift build --show-bin-path output is empty")

        let binaryPath = "\(binDir)/ClipboardManager"
        XCTAssertTrue(
            FileManager.default.isReadableFile(atPath: binaryPath),
            "Executable not found: \(binaryPath)"
        )
        return binaryPath
    }
}
