import AppKit
import Foundation
import XCTest
@testable import ClipboardManager

final class HTMLPreviewRendererTests: XCTestCase {
    func testReturnsBoundedHelperOutput() async throws {
        let fixture = try makeHelper(
            body: "printf '%s' '{\\rtf1\\ansi Rendered}' > \"$2\""
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let renderer = HTMLPreviewRenderer(executableURL: fixture.executable)

        let result = await renderer.render(html: Data("<b>Rendered</b>".utf8))

        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(result?.count ?? .max, HTMLPreviewLimits.maximumOutputBytes)
    }

    func testTerminatesHungHelperWithinBoundedTime() async throws {
        let fixture = try makeHelper(body: "trap '' TERM; while :; do :; done")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let renderer = HTMLPreviewRenderer(executableURL: fixture.executable)
        let startedAt = ContinuousClock.now

        let result = await renderer.render(html: Data("<b>Blocked</b>".utf8))

        XCTAssertNil(result)
        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(2))
    }

    func testTerminatesHelperExceedingPhysicalFootprintBeforeTimeout() async throws {
        let fixture = try makeHelper(body: "trap '' TERM; while :; do :; done")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let renderer = HTMLPreviewRenderer(
            executableURL: fixture.executable,
            timeout: .seconds(5),
            maximumPhysicalFootprintBytes: 1
        )
        let startedAt = ContinuousClock.now

        let result = await renderer.render(html: Data("<b>Large process</b>".utf8))

        XCTAssertNil(result)
        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(2))
    }

    func testWaitsForCancelledHelperBeforeLaunchingReplacement() async throws {
        let coordinationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLPreviewRendererCoordination-\(UUID().uuidString)")
        let lockDirectory = coordinationDirectory.appendingPathComponent("active")
        let overlapMarker = coordinationDirectory.appendingPathComponent("overlap")
        try FileManager.default.createDirectory(
            at: coordinationDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: coordinationDirectory) }
        let fixture = try makeHelper(
            body: """
            if ! mkdir '\(lockDirectory.path)'; then
                touch '\(overlapMarker.path)'
                exit 1
            fi
            trap 'rmdir "\(lockDirectory.path)"; exit 143' TERM INT
            if grep -q First "$1"; then
                while :; do :; done
            fi
            printf '%s' '{\\rtf1\\ansi Second}' > "$2"
            rmdir '\(lockDirectory.path)'
            trap - TERM INT
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let renderer = HTMLPreviewRenderer(executableURL: fixture.executable)
        let first = Task {
            await renderer.render(html: Data("<b>First</b>".utf8))
        }
        try await waitForItem(at: lockDirectory)

        let second = await renderer.render(html: Data("<b>Second</b>".utf8))
        let firstResult = await first.value

        XCTAssertNil(firstResult)
        XCTAssertNotNil(second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlapMarker.path))
    }

    func testRejectsOversizedHelperOutput() async throws {
        let fixture = try makeHelper(
            body: "dd if=/dev/zero of=\"$2\" bs=1024 count=513 2>/dev/null"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let renderer = HTMLPreviewRenderer(executableURL: fixture.executable)

        let result = await renderer.render(html: Data("<b>Large</b>".utf8))

        XCTAssertNil(result)
    }

    private func makeHelper(body: String) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLPreviewRendererTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("helper")
        try Data("#!/bin/sh\nset -eu\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )
        return (directory, executable)
    }

    private func waitForItem(at url: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for helper startup")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
final class BoundedHTMLPreviewTests: XCTestCase {
    func testAcceptsSmallRTF() throws {
        let attributed = NSAttributedString(
            string: "Preview",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]
        )
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )

        XCTAssertEqual(PreviewPane.decodeBoundedRTF(rtf)?.string, "Preview")
    }

    func testRejectsRTFOverCharacterLimit() throws {
        let attributed = NSAttributedString(
            string: String(
                repeating: "x",
                count: HTMLPreviewLimits.maximumUTF16Length + 1
            )
        )
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )

        XCTAssertNil(PreviewPane.decodeBoundedRTF(rtf))
    }

    func testRejectsRTFOverStyleRunLimit() throws {
        let attributed = NSMutableAttributedString(string: String(repeating: "x", count: 257))
        for index in 0..<257 {
            attributed.addAttribute(
                .font,
                value: NSFont.systemFont(ofSize: index.isMultiple(of: 2) ? 10 : 11),
                range: NSRange(location: index, length: 1)
            )
        }
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )

        XCTAssertNil(PreviewPane.decodeBoundedRTF(rtf))
    }
}
