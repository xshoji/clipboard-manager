import XCTest

/// 薄い起動スモークテスト。
///
/// `swift build` でビルドした実行ファイルを実際に起動し、起動後数秒間クラッシュせず
/// 生存していることを確認する。UI 要素の操作や履歴データの検証は行わない。
/// アプリはメニューバー常駐型で終了しないため、テスト側で `terminate()` する。
///
/// 注意:
/// - アプリは実際の `~/Library/Application Support` 配下の SwiftData ストアを開く。
///   テスト結果は履歴内容に依存しない（クラッシュ有無のみ判定）が、
///   起動中のクリップボード監視で実際の pasteboard 内容が履歴に保存される副作用がある。
/// - ホットキー登録（Carbon API）は既存インスタンスがいると失敗するが、クラッシュはしない。
final class SmokeTests: XCTestCase {
    /// 起動後、この秒数クラッシュせず生存すれば成功とみなす。
    private let survivalSeconds: TimeInterval = 5

    func testAppLaunchesWithoutCrash() throws {
        let binaryPath = try buildAndLocateBinary()

        let app = Process()
        app.executableURL = URL(fileURLWithPath: binaryPath)

        try app.run()

        // 確実に終了させるため、成功・失敗問わず terminate する。
        defer {
            if app.isRunning {
                app.terminate()
            }
            app.waitUntilExit()
        }

        // 起動後しばらく待ち、プロセスが生存していることを確認。
        Thread.sleep(forTimeInterval: survivalSeconds)

        XCTAssertTrue(
            app.isRunning,
            "アプリが起動から \(survivalSeconds) 秒以内に終了（クラッシュの可能性）しました。exitCode=\(app.terminationStatus)"
        )
    }

    /// `swift build` を実行し、生成された `ClipboardManager` 実行ファイルの絶対パスを返す。
    private func buildAndLocateBinary() throws -> String {
        // 1) ビルド（既にビルド済みなら高速に完了）
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        build.arguments = ["build"]
        try build.run()
        build.waitUntilExit()
        if build.terminationStatus != 0 {
            XCTFail("swift build が失敗しました（exitCode=\(build.terminationStatus)）")
        }

        // 2) バイナリ出力ディレクトリを取得
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
