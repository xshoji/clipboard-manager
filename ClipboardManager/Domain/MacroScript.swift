import Foundation

enum MacroSource: Hashable, Sendable {
    case inlineShell(code: String, interpreter: String)
    case javaScriptJXA(code: String)
    case file(path: String, interpreter: String)

    var kindLabel: String { switch self { case .inlineShell: return "Inline shell"; case .javaScriptJXA: return "JavaScript (JXA)"; case .file: return "Script file" } }
    var supportsImageInput: Bool { if case .javaScriptJXA = self { return false }; return true }
    var userCode: String? { switch self { case let .inlineShell(code, _), let .javaScriptJXA(code): return code; case .file: return nil } }
    var interpreter: String? { switch self { case let .inlineShell(_, interpreter), let .file(_, interpreter): return interpreter; case .javaScriptJXA: return nil } }
    var path: String? { if case let .file(path, _) = self { return path }; return nil }
}

struct MacroScript: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// Stable display order used by the canonical JSON configuration. Gaps are allowed.
    var order: Int?
    var name: String
    var source: MacroSource
    /// Reusable text fixture for Test Run. Optional for backward compatibility with existing settings data.
    var testInput: String?
    var hotkeyCode: Int
    var hotkeyModifiers: Int
    var lastFingerprint: String?
    var lastModified: Date?

    init(
        id: UUID = UUID(),
        order: Int? = nil,
        name: String,
        scriptPath: String,
        inlineScript: String? = nil,
        testInput: String? = nil,
        interpreter: String = "/bin/sh",
        hotkeyCode: Int = 0,
        hotkeyModifiers: Int = 0,
        lastFingerprint: String? = nil,
        lastModified: Date? = nil
    ) {
        self.id = id
        self.order = order
        self.name = name
        self.source = inlineScript.map { .inlineShell(code: $0, interpreter: interpreter) }
            ?? .file(path: scriptPath, interpreter: interpreter)
        self.testInput = testInput
        self.hotkeyCode = hotkeyCode
        self.hotkeyModifiers = hotkeyModifiers
        self.lastFingerprint = lastFingerprint
        self.lastModified = lastModified
    }

    init(id: UUID = UUID(), order: Int? = nil, name: String, source: MacroSource, testInput: String? = nil, hotkeyCode: Int = 0, hotkeyModifiers: Int = 0, lastFingerprint: String? = nil, lastModified: Date? = nil) {
        self.id = id; self.order = order; self.name = name; self.source = source; self.testInput = testInput; self.hotkeyCode = hotkeyCode; self.hotkeyModifiers = hotkeyModifiers; self.lastFingerprint = lastFingerprint; self.lastModified = lastModified
    }

    var supportsImageInput: Bool { source.supportsImageInput }
    var inlineScript: String? { source.userCode }
    var scriptPath: String { source.path ?? "" }
    var interpreter: String { source.interpreter ?? MacroRunner.javaScriptJXAExecutable }

    private enum CodingKeys: String, CodingKey { case id, order, name, source, testInput, hotkeyCode, hotkeyModifiers, lastFingerprint, lastModified, scriptPath, inlineScript, interpreter }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); order = try c.decodeIfPresent(Int.self, forKey: .order); name = try c.decode(String.self, forKey: .name)
        testInput = try c.decodeIfPresent(String.self, forKey: .testInput); hotkeyCode = try c.decodeIfPresent(Int.self, forKey: .hotkeyCode) ?? 0; hotkeyModifiers = try c.decodeIfPresent(Int.self, forKey: .hotkeyModifiers) ?? 0; lastFingerprint = try c.decodeIfPresent(String.self, forKey: .lastFingerprint); lastModified = try c.decodeIfPresent(Date.self, forKey: .lastModified)
        if let persisted = try c.decodeIfPresent(PersistedSource.self, forKey: .source) { source = persisted.value } else {
            let interpreter = try c.decodeIfPresent(String.self, forKey: .interpreter) ?? "/bin/sh"
            source = try c.decodeIfPresent(String.self, forKey: .inlineScript).map { .inlineShell(code: $0, interpreter: interpreter) } ?? .file(path: try c.decode(String.self, forKey: .scriptPath), interpreter: interpreter)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encodeIfPresent(order, forKey: .order); try c.encode(name, forKey: .name); try c.encode(PersistedSource(source), forKey: .source); try c.encodeIfPresent(testInput, forKey: .testInput); try c.encode(hotkeyCode, forKey: .hotkeyCode); try c.encode(hotkeyModifiers, forKey: .hotkeyModifiers); try c.encodeIfPresent(lastFingerprint, forKey: .lastFingerprint); try c.encodeIfPresent(lastModified, forKey: .lastModified)
    }
}

private struct PersistedSource: Codable {
    let value: MacroSource
    init(_ value: MacroSource) { self.value = value }
    private enum Keys: String, CodingKey { case type, code, path, interpreter }
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: Keys.self); switch try c.decode(String.self, forKey: .type) { case "inlineShell": value = .inlineShell(code: try c.decode(String.self, forKey: .code), interpreter: try c.decode(String.self, forKey: .interpreter)); case "javaScriptJXA": value = .javaScriptJXA(code: try c.decode(String.self, forKey: .code)); case "file": value = .file(path: try c.decode(String.self, forKey: .path), interpreter: try c.decode(String.self, forKey: .interpreter)); default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown Macro source type.") } }
    func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: Keys.self); switch value { case let .inlineShell(code, interpreter): try c.encode("inlineShell", forKey: .type); try c.encode(code, forKey: .code); try c.encode(interpreter, forKey: .interpreter); case let .javaScriptJXA(code): try c.encode("javaScriptJXA", forKey: .type); try c.encode(code, forKey: .code); case let .file(path, interpreter): try c.encode("file", forKey: .type); try c.encode(path, forKey: .path); try c.encode(interpreter, forKey: .interpreter) } }
}
