import Foundation

struct MacroScript: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// Stable display order used by the canonical JSON configuration. Gaps are allowed.
    var order: Int?
    var name: String
    var scriptPath: String
    /// `nil` means a file path is used; a value means the script was entered directly in the settings UI.
    /// Because it is `Optional`, existing JSON without `inlineScript` can still be decoded for backward compatibility.
    var inlineScript: String?
    /// Reusable text fixture for Test Run. Optional for backward compatibility with existing settings data.
    var testInput: String?
    var interpreter: String
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
        self.scriptPath = scriptPath
        self.inlineScript = inlineScript
        self.testInput = testInput
        self.interpreter = interpreter
        self.hotkeyCode = hotkeyCode
        self.hotkeyModifiers = hotkeyModifiers
        self.lastFingerprint = lastFingerprint
        self.lastModified = lastModified
    }
}
