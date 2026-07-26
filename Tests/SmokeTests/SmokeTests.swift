import XCTest
import AppKit

/// 薄い起動スモークテスト（実アプリの設定を汚さないフロー付き）。
///
/// テスト実行フロー:
/// 1. 稼働中の本番アプリを終了（ホットキー二重登録・ペーストボード二重監視を防ぐ）
/// 2. `defaults export` で UserDefaults を退避
///    - `com.xshoji.ClipboardManager`（.app バンドル = 本番アプリのドメイン）
///    - `ClipboardManager`（SPM bare 実行ファイル = テストバイナリのドメイン）
/// 3. `defaults write` でテストバイナリのホットキー修飾キーを cmd+ctrl+opt+shift に上書き
///    — 本番デフォルトの cmd+ctrl と絶対衝突しない
/// 4. `swift build` でビルドした実行ファイルを起動し、数秒間クラッシュせず生存することを確認
/// 5. テスト用プロセスを SIGTERM → タイムアウトで SIGKILL で確実に終了
/// 6. `defaults import` で退避した設定を復元
///
/// 注意:
/// - SPM bare 実行ファイルは Bundle Identifier を持たないため、UserDefaults ドメインとして
///   実行ファイル名 `ClipboardManager` を使う（本番 .app の `com.xshoji.ClipboardManager` とは別）。
/// - アプリは実際の `~/Library/Application Support` 配下の SwiftData ストアを開く。
///   起動中のクリップボード監視で実際の pasteboard 内容が履歴に保存される副作用がある
///   （クリップボード履歴の汚染は許容する）。
/// - 設定（UserDefaults）はテスト前後で確実に復元される。
/// - 本番アプリが起動中の場合はテスト開始時に強制終了する。
@MainActor
final class SmokeTests: XCTestCase {
    /// 本番アプリ（.app バンドル）の Bundle Identifier。
    private static let bundleID = "com.xshoji.ClipboardManager"

    /// SPM bare 実行ファイルの UserDefaults ドメイン（実行ファイル名）。
    private static let spmDefaultsDomain = "ClipboardManager"

    /// UserDefaults 退避先の一時 plist パス。
    private static let backupPathBundle = NSTemporaryDirectory() + "cm-e2e-settings-bundle.plist"
    private static let backupPathSPM = NSTemporaryDirectory() + "cm-e2e-settings-spm.plist"

    /// テスト用ホットキー修飾キー: cmd+ctrl+opt+shift（4修飾キー）。
    /// 本番デフォルトの cmd+ctrl と絶対衝突しない組み合わせ。
    private static let testHotkeyModifiers = Int(
        NSEvent.ModifierFlags.command.rawValue
        | NSEvent.ModifierFlags.control.rawValue
        | NSEvent.ModifierFlags.option.rawValue
        | NSEvent.ModifierFlags.shift.rawValue
    )

    /// 設定退避が成功したか（restore を1回だけ行うためのフラグ）。
    private static var backupTaken = false

    /// 起動後、この秒数クラッシュせず生存すれば成功とみなす。
    private let survivalSeconds: TimeInterval = 5

    /// SIGTERM 送信後、この秒数以内に終了しなければ SIGKILL を送る。
    private let terminateTimeoutSeconds: TimeInterval = 3

    // MARK: - Setup / Teardown

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 1. 本番アプリが起動中なら終了させる。
        Self.terminateRunningApp()
        // 2. 設定を1回だけ退避する（複数テストケースでも2回目以降は上書きしない）。
        if !Self.backupTaken {
            try Self.exportSettings()
            Self.backupTaken = true
        }
        // 3. テスト用ホットキーを上書き（テストバイナリが読む SPM ドメイン側）。
        try Self.setTestHotkeys()
    }

    override class func tearDown() {
        // 6. 退避した設定を復元（export が成功した場合のみ）。
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
        // 子プロセスの stdout/stderr を /dev/null に逃がし、
        // パイプの EOF 待ちやログノイズを避ける。
        let devnull = FileHandle(forWritingAtPath: "/dev/null")!
        app.standardOutput = devnull
        app.standardError = devnull

        log("Process.run: begin")
        try app.run()
        log("Process.run: done pid=\(app.processIdentifier)")

        // 確実に終了させるため、成功・失敗問わず terminate する。
        defer {
            Self.forceTerminate(app, timeout: terminateTimeoutSeconds)
        }

        // 起動後しばらく待ち、プロセスが生存していることを確認。
        log("sleep \(survivalSeconds)s start")
        Thread.sleep(forTimeInterval: survivalSeconds)
        log("sleep done, isRunning=\(app.isRunning)")

        XCTAssertTrue(
            app.isRunning,
            "アプリが起動から \(survivalSeconds) 秒以内に終了（クラッシュの可能性）しました。exitCode=\(app.terminationStatus)"
        )
        log("testAppLaunchesWithoutCrash: assertion passed ✓")
    }

    /// stderr に無バッファでログを出力する（XCTest は stdout をバッファするため）。
    private static func log(_ msg: String) {
        let line = "[SmokeTests] \(msg)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
    private func log(_ msg: String) {
        Self.log(msg)
    }

    // MARK: - Helpers

    /// 稼働中の本番アプリを終了させる。既に終了していれば何もしない。
    private static func terminateRunningApp() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !apps.isEmpty else { return }
        Self.log("Terminating \(apps.count) running app instance(s)")
        for app in apps {
            app.terminate()
        }
        // terminate は非同期なので、確実に終了するまで待つ。
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// `defaults export` で現在の UserDefaults を一時 plist に退避する。
    /// 本番ドメイン（.app）と SPM ドメイン（bare 実行ファイル）の両方を退避する。
    private static func exportSettings() throws {
        try runShell("defaults export \(bundleID) '\(backupPathBundle)'")
        // SPM ドメインは plist が存在しない可能性がある（export は空 plist で成功する）。
        try runShell("defaults export \(spmDefaultsDomain) '\(backupPathSPM)'")
        Self.log("Settings exported to temporary plists")
    }

    /// `defaults import` で退避した設定を復元する。
    private static func restoreSettings() throws {
        try runShell("defaults import \(bundleID) '\(backupPathBundle)'")
        try runShell("defaults import \(spmDefaultsDomain) '\(backupPathSPM)'")
        Self.log("Settings restored from temporary plists")
    }

    /// テストバイナリが読む SPM ドメインの全ホットキー修飾キーを
    /// テスト用（cmd+ctrl+opt+shift）に上書きする。
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

    /// プロセスを SIGTERM で終了させ、タイムアウト後に SIGKILL でフォールバックする。
    /// `waitUntilExit()` のみだと NSApplication の terminate 処理が完了しない場合にハングする。
    private static func forceTerminate(_ proc: Process, timeout: TimeInterval) {
        guard proc.isRunning else {
            proc.waitUntilExit()
            return
        }
        let pid = proc.processIdentifier
        Self.log("Terminating pid=\(pid) (SIGTERM)")

        // SIGTERM を送る（Process.terminate と同等）。
        kill(pid, SIGTERM)

        // タイムアウトまで100ms単位でポーリング。
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !proc.isRunning {
                proc.waitUntilExit()
                Self.log("pid=\(pid) exited after SIGTERM (code=\(proc.terminationStatus))")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        // SIGTERM で終了しない場合は SIGKILL で強制終了。
        Self.log("pid=\(pid) did not exit after \(timeout)s, sending SIGKILL")
        kill(pid, SIGKILL)
        proc.waitUntilExit()
        Self.log("pid=\(pid) killed (code=\(proc.terminationStatus))")
    }

    /// シェルコマンドを実行し、非0終了時はエラーを投げる。
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

    /// `swift build --show-bin-path` でビルド出力ディレクトリを取得し、
    /// そこにある `ClipboardManager` 実行ファイルの絶対パスを返す。
    /// `swift test` が既にバイナリをビルド済みなので、ここではビルドしない
    /// （`swift build` を呼ぶと `.build` ロック待ちでデッドロックする）。
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
        XCTAssertFalse(binDir.isEmpty, "swift build --show-bin-path の出力が空です")

        let binaryPath = "\(binDir)/ClipboardManager"
        XCTAssertTrue(
            FileManager.default.isReadableFile(atPath: binaryPath),
            "実行ファイルが見つかりません: \(binaryPath)"
        )
        return binaryPath
    }
}
