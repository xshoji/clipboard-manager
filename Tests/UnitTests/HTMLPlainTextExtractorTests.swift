import Foundation
import XCTest
@testable import ClipboardManager

final class HTMLPlainTextExtractorTests: XCTestCase {
    func testExtractsStructuralTextAndBasicEntities() {
        let html = Data("""
        <h1>Hello&nbsp;world</h1><p>A &amp; B &#x1F600;</p>
        <table><tr><td>X</td><td>Y</td></tr></table>
        """.utf8)

        XCTAssertEqual(
            HTMLPlainTextExtractor.extract(from: html),
            "Hello world\nA & B 😀\nX Y"
        )
    }

    func testOmitsCommentsScriptAndStyleContents() {
        let html = Data("""
        Visible<!-- hidden --><script>if (a < b) { alert("hidden") }</script>
        Next<style>.hidden { display: none }</style>Done
        """.utf8)

        XCTAssertEqual(HTMLPlainTextExtractor.extract(from: html), "Visible\nNext\nDone")
    }

    func testGreaterThanInsideQuotedAttributeDoesNotEndTag() {
        let html = Data("<div title='1 > 0'>Value</div>".utf8)

        XCTAssertEqual(HTMLPlainTextExtractor.extract(from: html), "Value")
    }

    func testDoesNotDecodeEntitiesRecursively() {
        let html = Data("&amp;lt; &#60; &#x3E;".utf8)

        XCTAssertEqual(HTMLPlainTextExtractor.extract(from: html), "&lt; < >")
    }

    func testPreservesMalformedUnterminatedTagAsLiteralText() {
        let html = Data("Before <div title='unterminated>After".utf8)

        XCTAssertEqual(
            HTMLPlainTextExtractor.extract(from: html),
            "Before <div title='unterminated>After"
        )
    }

    func testReplacesInvalidUTF8WithoutGrowingBeyondInput() {
        let html = Data([0x48, 0x69, 0x20, 0xFF, 0xFE])

        let text = HTMLPlainTextExtractor.extract(from: html)

        XCTAssertEqual(text, "Hi ??")
        XCTAssertLessThanOrEqual(text?.utf8.count ?? 0, html.count)
    }

    func testRejectsInvalidNumericEntitiesWithoutRecursiveRescan() {
        let html = Data("&#xD800; &#1114112; &#not-a-number;".utf8)

        XCTAssertEqual(
            HTMLPlainTextExtractor.extract(from: html),
            "&#xD800; &#1114112; &#not-a-number;"
        )
    }

    func testAdversarialInputRemainsOutputBounded() {
        let source = String(repeating: "<&", count: 100_000)
        let html = Data(source.utf8)

        let text = HTMLPlainTextExtractor.extract(from: html)

        XCTAssertEqual(text, source)
        XCTAssertLessThanOrEqual(text?.utf8.count ?? 0, html.count)
    }
}
