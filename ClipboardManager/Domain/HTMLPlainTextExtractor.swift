import Foundation

/// Extracts a bounded plain-text representation from clipboard HTML without
/// building a DOM, evaluating CSS, using regular expressions, or invoking the
/// system HTML importer. Every input byte is visited at most a constant number
/// of times and output never exceeds the input byte count.
enum HTMLPlainTextExtractor {
    static func extract(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var output: [UInt8] = []
            output.reserveCapacity(min(bytes.count, TextPreviewBuilder.characterLimit))
            var index = 0
            var suppressedTag: String?

            while index < bytes.count {
                if let suppressedName = suppressedTag {
                    guard isClosingTag(
                        named: suppressedName,
                        in: bytes,
                        at: index
                    ) else {
                        index += 1
                        continue
                    }
                    switch parseTag(in: bytes, at: index) {
                    case .tag(let tag):
                        index = tag.endIndex
                        if tag.isClosing, tag.name == suppressedName {
                            appendBreak(to: &output, limit: bytes.count)
                            suppressedTag = nil
                        }
                    case .literal:
                        index += 1
                    case .unterminated:
                        index = bytes.count
                    }
                    continue
                }

                switch bytes[index] {
                case asciiLessThan:
                    if startsWith(bytes, at: index, sequence: commentStart) {
                        if let end = firstIndex(
                            of: commentEnd,
                            in: bytes,
                            startingAt: index + commentStart.count
                        ) {
                            index = end + commentEnd.count
                        } else {
                            index = bytes.count
                        }
                        continue
                    }
                    switch parseTag(in: bytes, at: index) {
                    case .tag(let tag):
                        index = tag.endIndex
                        if !tag.isClosing, (tag.name == "script" || tag.name == "style") {
                            suppressedTag = tag.name
                        } else if tag.name.map(structuralTags.contains) == true {
                            appendBreak(to: &output, limit: bytes.count)
                        } else if tag.name == "td" || tag.name == "th" {
                            appendSpace(to: &output, limit: bytes.count)
                        }
                    case .literal:
                        append(asciiLessThan, to: &output, limit: bytes.count)
                        index += 1
                    case .unterminated:
                        appendLiteralRemainder(
                            in: bytes,
                            startingAt: index,
                            to: &output,
                            limit: bytes.count
                        )
                        index = bytes.count
                    }

                case asciiAmpersand:
                    if let entity = decodeEntity(in: bytes, at: index) {
                        for byte in entity.bytes {
                            append(byte, to: &output, limit: bytes.count)
                        }
                        index = entity.endIndex
                    } else {
                        append(asciiAmpersand, to: &output, limit: bytes.count)
                        index += 1
                    }

                case asciiSpace, asciiTab, asciiLineFeed, asciiCarriageReturn, asciiFormFeed:
                    appendSpace(to: &output, limit: bytes.count)
                    index += 1

                default:
                    index += appendUTF8Sequence(
                        in: bytes,
                        at: index,
                        to: &output,
                        limit: bytes.count
                    )
                }
            }

            let text = String(decoding: output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    private struct Tag {
        let name: String?
        let isClosing: Bool
        let endIndex: Int
    }

    private enum TagParseResult {
        case tag(Tag)
        case literal
        case unterminated
    }

    private struct DecodedEntity {
        let bytes: [UInt8]
        let endIndex: Int
    }

    private static let asciiAmpersand: UInt8 = 0x26
    private static let asciiCarriageReturn: UInt8 = 0x0D
    private static let asciiFormFeed: UInt8 = 0x0C
    private static let asciiGreaterThan: UInt8 = 0x3E
    private static let asciiLessThan: UInt8 = 0x3C
    private static let asciiLineFeed: UInt8 = 0x0A
    private static let asciiSemicolon: UInt8 = 0x3B
    private static let asciiSlash: UInt8 = 0x2F
    private static let asciiSpace: UInt8 = 0x20
    private static let asciiTab: UInt8 = 0x09
    private static let commentStart = Array("<!--".utf8)
    private static let commentEnd = Array("-->".utf8)
    private static let structuralTags: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt",
        "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "tr", "ul"
    ]

    private static func parseTag(
        in bytes: UnsafeBufferPointer<UInt8>,
        at start: Int
    ) -> TagParseResult {
        var cursor = start + 1
        guard cursor < bytes.count else { return .unterminated }

        if bytes[cursor] == UInt8(ascii: "!") || bytes[cursor] == UInt8(ascii: "?") {
            guard let end = tagEnd(in: bytes, startingAt: cursor + 1) else { return .unterminated }
            return .tag(Tag(name: nil, isClosing: false, endIndex: end + 1))
        }

        let isClosing = bytes[cursor] == asciiSlash
        if isClosing { cursor += 1 }
        while cursor < bytes.count, isASCIIWhitespace(bytes[cursor]) { cursor += 1 }
        guard cursor < bytes.count, isASCIILetter(bytes[cursor]) else { return .literal }

        let nameStart = cursor
        while cursor < bytes.count, isTagNameByte(bytes[cursor]) { cursor += 1 }
        let name = normalizedTagName(in: bytes, range: nameStart..<cursor)
        guard let end = tagEnd(in: bytes, startingAt: cursor) else { return .unterminated }
        return .tag(Tag(name: name, isClosing: isClosing, endIndex: end + 1))
    }

    private static func tagEnd(
        in bytes: UnsafeBufferPointer<UInt8>,
        startingAt start: Int
    ) -> Int? {
        var cursor = start
        var quote: UInt8?
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if let activeQuote = quote {
                if byte == activeQuote { quote = nil }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == asciiGreaterThan {
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private static func isClosingTag(
        named name: String,
        in bytes: UnsafeBufferPointer<UInt8>,
        at start: Int
    ) -> Bool {
        guard start + 2 < bytes.count,
              bytes[start] == asciiLessThan,
              bytes[start + 1] == asciiSlash else { return false }
        var cursor = start + 2
        while cursor < bytes.count, isASCIIWhitespace(bytes[cursor]) { cursor += 1 }
        for expected in name.utf8 {
            guard cursor < bytes.count,
                  asciiLowercased(bytes[cursor]) == expected else { return false }
            cursor += 1
        }
        guard cursor < bytes.count else { return false }
        return isASCIIWhitespace(bytes[cursor])
            || bytes[cursor] == asciiGreaterThan
            || bytes[cursor] == asciiSlash
    }

    private static func normalizedTagName(
        in bytes: UnsafeBufferPointer<UInt8>,
        range: Range<Int>
    ) -> String? {
        guard range.count <= 16 else { return nil }
        return String(decoding: range.map { asciiLowercased(bytes[$0]) }, as: UTF8.self)
    }

    private static func decodeEntity(
        in bytes: UnsafeBufferPointer<UInt8>,
        at start: Int
    ) -> DecodedEntity? {
        let maximumLength = 12
        var end = start + 1
        while end < bytes.count,
              end - start <= maximumLength,
              bytes[end] != asciiSemicolon {
            end += 1
        }
        guard end < bytes.count, bytes[end] == asciiSemicolon else { return nil }
        let body = (start + 1)..<end
        guard !body.isEmpty else { return nil }

        if bytes[body.lowerBound] == UInt8(ascii: "#") {
            return decodeNumericEntity(in: bytes, body: body, endIndex: end + 1)
        }

        let name = String(decoding: body.map { asciiLowercased(bytes[$0]) }, as: UTF8.self)
        let decoded: UInt8? = switch name {
        case "amp": asciiAmpersand
        case "apos": UInt8(ascii: "'")
        case "gt": asciiGreaterThan
        case "lt": asciiLessThan
        case "nbsp": asciiSpace
        case "quot": UInt8(ascii: "\"")
        default: nil
        }
        return decoded.map { DecodedEntity(bytes: [$0], endIndex: end + 1) }
    }

    private static func decodeNumericEntity(
        in bytes: UnsafeBufferPointer<UInt8>,
        body: Range<Int>,
        endIndex: Int
    ) -> DecodedEntity? {
        var cursor = body.lowerBound + 1
        var radix: UInt32 = 10
        if cursor < body.upperBound,
           (bytes[cursor] == UInt8(ascii: "x") || bytes[cursor] == UInt8(ascii: "X")) {
            radix = 16
            cursor += 1
        }
        guard cursor < body.upperBound else { return nil }

        var value: UInt32 = 0
        var digitCount = 0
        while cursor < body.upperBound {
            guard let digit = digitValue(bytes[cursor]), digit < radix else { return nil }
            guard value <= (0x10FFFF - digit) / radix else { return nil }
            value = value * radix + digit
            digitCount += 1
            guard digitCount <= 8 else { return nil }
            cursor += 1
        }
        guard let scalar = UnicodeScalar(value), !(0xD800...0xDFFF).contains(value) else { return nil }
        return DecodedEntity(bytes: Array(String(scalar).utf8), endIndex: endIndex)
    }

    private static func append(_ byte: UInt8, to output: inout [UInt8], limit: Int) {
        guard output.count < limit else { return }
        output.append(byte)
    }

    private static func appendSpace(to output: inout [UInt8], limit: Int) {
        guard let last = output.last else { return }
        guard last != asciiSpace, last != asciiLineFeed else { return }
        append(asciiSpace, to: &output, limit: limit)
    }

    private static func appendBreak(to output: inout [UInt8], limit: Int) {
        while output.last == asciiSpace { output.removeLast() }
        guard !output.isEmpty, output.last != asciiLineFeed else { return }
        append(asciiLineFeed, to: &output, limit: limit)
    }

    private static func appendLiteralRemainder(
        in bytes: UnsafeBufferPointer<UInt8>,
        startingAt start: Int,
        to output: inout [UInt8],
        limit: Int
    ) {
        var cursor = start
        while cursor < bytes.count {
            if isASCIIWhitespace(bytes[cursor]) {
                appendSpace(to: &output, limit: limit)
                cursor += 1
            } else {
                cursor += appendUTF8Sequence(
                    in: bytes,
                    at: cursor,
                    to: &output,
                    limit: limit
                )
            }
        }
    }

    /// Copies one valid UTF-8 sequence. Invalid bytes become one ASCII question
    /// mark so malformed clipboard data cannot expand beyond the input byte budget.
    private static func appendUTF8Sequence(
        in bytes: UnsafeBufferPointer<UInt8>,
        at start: Int,
        to output: inout [UInt8],
        limit: Int
    ) -> Int {
        let first = bytes[start]
        guard first >= 0x80 else {
            append(first, to: &output, limit: limit)
            return 1
        }

        let length: Int
        switch first {
        case 0xC2...0xDF: length = 2
        case 0xE0...0xEF: length = 3
        case 0xF0...0xF4: length = 4
        default:
            append(UInt8(ascii: "?"), to: &output, limit: limit)
            return 1
        }
        guard start + length <= bytes.count else {
            append(UInt8(ascii: "?"), to: &output, limit: limit)
            return 1
        }
        let second = bytes[start + 1]
        guard (0x80...0xBF).contains(second),
              first != 0xE0 || second >= 0xA0,
              first != 0xED || second <= 0x9F,
              first != 0xF0 || second >= 0x90,
              first != 0xF4 || second <= 0x8F else {
            append(UInt8(ascii: "?"), to: &output, limit: limit)
            return 1
        }
        if length > 2 {
            for offset in 2..<length where !(0x80...0xBF).contains(bytes[start + offset]) {
                append(UInt8(ascii: "?"), to: &output, limit: limit)
                return 1
            }
        }
        for offset in 0..<length {
            append(bytes[start + offset], to: &output, limit: limit)
        }
        return length
    }

    private static func startsWith(
        _ bytes: UnsafeBufferPointer<UInt8>,
        at start: Int,
        sequence: [UInt8]
    ) -> Bool {
        guard start + sequence.count <= bytes.count else { return false }
        for offset in sequence.indices where bytes[start + offset] != sequence[offset] {
            return false
        }
        return true
    }

    private static func firstIndex(
        of sequence: [UInt8],
        in bytes: UnsafeBufferPointer<UInt8>,
        startingAt start: Int
    ) -> Int? {
        guard !sequence.isEmpty, start < bytes.count else { return nil }
        var cursor = start
        while cursor + sequence.count <= bytes.count {
            if startsWith(bytes, at: cursor, sequence: sequence) { return cursor }
            cursor += 1
        }
        return nil
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == asciiSpace || byte == asciiTab || byte == asciiLineFeed
            || byte == asciiCarriageReturn || byte == asciiFormFeed
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    private static func isTagNameByte(_ byte: UInt8) -> Bool {
        isASCIILetter(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: ":")
            || byte == UInt8(ascii: "-")
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }

    private static func digitValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt32(byte - UInt8(ascii: "A") + 10)
        case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(byte - UInt8(ascii: "a") + 10)
        default: nil
        }
    }

}
