import Foundation

struct SettingsConfigurationDocument: Codable, Sendable {
    static let currentFormatVersion = 2

    let formatVersion: Int
    let settings: AppSettingsSnapshot
    let macros: [MacroSnapshot]

    init(settings: AppSettings) {
        formatVersion = Self.currentFormatVersion
        self.settings = AppSettingsSnapshot(settings: settings)

        var lastOrder: Int?
        macros = settings.macroScripts.map { macro in
            let order: Int
            if let existing = macro.order,
               existing >= 0,
               existing <= Int.max - 10,
               lastOrder.map({ existing > $0 }) ?? true {
                order = existing
            } else {
                order = (lastOrder ?? 0) + 10
            }
            lastOrder = order
            return MacroSnapshot(macro: macro, order: order)
        }
    }

    func validatedPlan() throws -> SettingsConfigurationPlan {
        guard formatVersion == 1 || formatVersion == Self.currentFormatVersion else {
            throw SettingsConfigurationError.unsupportedVersion(formatVersion)
        }
        if formatVersion == Self.currentFormatVersion,
           macros.contains(where: { $0.source.type == .inline }) {
            throw SettingsConfigurationError.invalidData("Version 2 configuration cannot use the legacy inline Macro source.")
        }
        try settings.validate()
        guard macros.count <= 1_000 else {
            throw SettingsConfigurationError.invalidData("The configuration contains too many Macros.")
        }

        var ids = Set<UUID>()
        var hotkeyIDs = Set<UInt32>()
        var orders = Set<Int>()
        var restored: [MacroScript] = []
        for macro in macros.sorted(by: { $0.order < $1.order }) {
            guard ids.insert(macro.id).inserted else {
                throw SettingsConfigurationError.invalidData("The configuration contains duplicate Macro IDs.")
            }
            guard hotkeyIDs.insert(Self.hotkeyID(for: macro.id)).inserted else {
                throw SettingsConfigurationError.invalidData("The configuration contains conflicting Macro IDs.")
            }
            guard macro.order >= 0,
                  macro.order <= Int.max - 10,
                  orders.insert(macro.order).inserted else {
                throw SettingsConfigurationError.invalidData("Each Macro must have a unique non-negative order.")
            }
            restored.append(try macro.restoredMacro())
        }

        return SettingsConfigurationPlan(settings: settings, macros: restored)
    }

    private static func hotkeyID(for id: UUID) -> UInt32 {
        let bytes = id.uuid
        return (UInt32(bytes.0) << 24)
            | (UInt32(bytes.1) << 16)
            | (UInt32(bytes.2) << 8)
            | UInt32(bytes.3)
    }
}

struct AppSettingsSnapshot: Codable, Sendable {
    let hotkeyKeyCode: Int
    let hotkeyModifiers: Int
    let globalMacroPickerHotkeyKeyCode: Int
    let globalMacroPickerHotkeyModifiers: Int
    let editHotkeyCode: Int
    let editHotkeyModifiers: Int
    let pastePlainHotkeyCode: Int
    let pastePlainHotkeyModifiers: Int
    let macroPickerHotkeyCode: Int
    let macroPickerHotkeyModifiers: Int
    let retentionDays: Int
    let maxHistoryCount: Int
    let maxItemSizeMB: Int
    let pollingIntervalMs: Int
    let macroSameDirectoryFingerprint: Bool
    let macroTimeoutSeconds: Int?
    let needsAccessibilityForSyntheticPaste: Bool
    let launchAtLogin: Bool
    let macroFailureBehavior: String
    let ocrLanguages: [String]
    let automaticImageOcrEnabled: Bool
    let isAlwaysOnTop: Bool
    let isSidebarVisible: Bool
    let isSplitView: Bool
    let previewWrapMode: String
    let windowPositionMode: String

    init(settings: AppSettings) {
        hotkeyKeyCode = settings.hotkeyKeyCode
        hotkeyModifiers = settings.hotkeyModifiers
        globalMacroPickerHotkeyKeyCode = settings.globalMacroPickerHotkeyKeyCode
        globalMacroPickerHotkeyModifiers = settings.globalMacroPickerHotkeyModifiers
        editHotkeyCode = settings.editHotkeyCode
        editHotkeyModifiers = settings.editHotkeyModifiers
        pastePlainHotkeyCode = settings.pastePlainHotkeyCode
        pastePlainHotkeyModifiers = settings.pastePlainHotkeyModifiers
        macroPickerHotkeyCode = settings.macroPickerHotkeyCode
        macroPickerHotkeyModifiers = settings.macroPickerHotkeyModifiers
        retentionDays = settings.retentionDays
        maxHistoryCount = settings.maxHistoryCount
        maxItemSizeMB = settings.maxItemSizeMB
        pollingIntervalMs = settings.pollingIntervalMs
        macroSameDirectoryFingerprint = settings.macroSameDirectoryFingerprint
        macroTimeoutSeconds = settings.macroTimeoutSeconds
        needsAccessibilityForSyntheticPaste = settings.needsAccessibilityForSyntheticPaste
        launchAtLogin = settings.launchAtLogin
        macroFailureBehavior = settings.macroFailureBehavior
        ocrLanguages = settings.ocrLanguages
        automaticImageOcrEnabled = settings.automaticImageOcrEnabled
        isAlwaysOnTop = settings.isAlwaysOnTop
        isSidebarVisible = settings.isSidebarVisible
        isSplitView = settings.isSplitView
        previewWrapMode = settings.previewWrapMode
        windowPositionMode = settings.windowPositionMode
    }

    func validate() throws {
        let hotkeyValues = [
            hotkeyKeyCode,
            globalMacroPickerHotkeyKeyCode,
            editHotkeyCode,
            pastePlainHotkeyCode,
            macroPickerHotkeyCode,
        ]
        guard hotkeyValues.allSatisfy({ (0...255).contains($0) }) else {
            throw SettingsConfigurationError.invalidData("The configuration contains an invalid hotkey key code.")
        }
        let modifierValues = [
            hotkeyModifiers,
            globalMacroPickerHotkeyModifiers,
            editHotkeyModifiers,
            pastePlainHotkeyModifiers,
            macroPickerHotkeyModifiers,
        ]
        guard modifierValues.allSatisfy({ $0 >= 0 }) else {
            throw SettingsConfigurationError.invalidData("The configuration contains invalid hotkey modifiers.")
        }
        guard (0...36_500).contains(retentionDays),
              (1...1_000_000).contains(maxHistoryCount),
              (1...10_000).contains(maxItemSizeMB),
              (50...60_000).contains(pollingIntervalMs),
              macroTimeoutSeconds.map({ (1...300).contains($0) }) ?? true else {
            throw SettingsConfigurationError.invalidData("The configuration contains settings outside the supported range.")
        }
        guard ["wrap", "nowrap"].contains(previewWrapMode),
              ["center", "nearCursor"].contains(windowPositionMode),
              ["restoreOriginalAndNotify", "notifyOnly", "silentlySkip", "ignore"].contains(macroFailureBehavior) else {
            throw SettingsConfigurationError.invalidData("The configuration contains an unsupported setting value.")
        }
        guard !ocrLanguages.isEmpty,
              ocrLanguages.count <= 20,
              ocrLanguages.allSatisfy({ !$0.isEmpty && $0.count <= 64 }) else {
            throw SettingsConfigurationError.invalidData("The configuration contains invalid OCR languages.")
        }
    }

    @MainActor
    func apply(to settings: AppSettings) {
        settings.hotkeyKeyCode = hotkeyKeyCode
        settings.hotkeyModifiers = hotkeyModifiers
        settings.globalMacroPickerHotkeyKeyCode = globalMacroPickerHotkeyKeyCode
        settings.globalMacroPickerHotkeyModifiers = globalMacroPickerHotkeyModifiers
        settings.editHotkeyCode = editHotkeyCode
        settings.editHotkeyModifiers = editHotkeyModifiers
        settings.pastePlainHotkeyCode = pastePlainHotkeyCode
        settings.pastePlainHotkeyModifiers = pastePlainHotkeyModifiers
        settings.macroPickerHotkeyCode = macroPickerHotkeyCode
        settings.macroPickerHotkeyModifiers = macroPickerHotkeyModifiers
        settings.retentionDays = retentionDays
        settings.maxHistoryCount = maxHistoryCount
        settings.maxItemSizeMB = maxItemSizeMB
        settings.pollingIntervalMs = pollingIntervalMs
        settings.macroSameDirectoryFingerprint = macroSameDirectoryFingerprint
        settings.macroTimeoutSeconds = macroTimeoutSeconds ?? AppSettings.defaultMacroTimeoutSeconds
        settings.needsAccessibilityForSyntheticPaste = needsAccessibilityForSyntheticPaste
        settings.launchAtLogin = launchAtLogin
        settings.macroFailureBehavior = macroFailureBehavior
        settings.ocrLanguages = ocrLanguages
        settings.automaticImageOcrEnabled = automaticImageOcrEnabled
        settings.isAlwaysOnTop = isAlwaysOnTop
        settings.isSidebarVisible = isSidebarVisible
        settings.isSplitView = isSplitView
        settings.previewWrapMode = previewWrapMode
        settings.windowPositionMode = windowPositionMode
    }
}

struct MacroSnapshot: Codable, Sendable {
    struct Source: Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case inline
            case inlineShell
            case javaScriptJXA
            case file
        }

        let type: Kind
        let code: String?
        let path: String?
        let interpreter: String?

        private enum Keys: String, CodingKey { case type, code, path, interpreter }
        init(type: Kind, code: String?, path: String?, interpreter: String?) { self.type = type; self.code = code; self.path = path; self.interpreter = interpreter }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            type = try c.decode(Kind.self, forKey: .type)
            code = try c.decodeIfPresent(String.self, forKey: .code)
            path = try c.decodeIfPresent(String.self, forKey: .path)
            interpreter = try c.decodeIfPresent(String.self, forKey: .interpreter)
            let expected: Set<Keys>
            switch type { case .inline: expected = [.type, .code, .path]; case .inlineShell: expected = [.type, .code, .interpreter]; case .javaScriptJXA: expected = [.type, .code]; case .file: expected = [.type, .path, .interpreter] }
            guard Set(c.allKeys).isSubset(of: expected) else { throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Macro source has fields not valid for its type.") }
        }
    }

    let id: UUID
    let order: Int
    let name: String
    /// Present only when reading legacy v1 configuration.
    let interpreter: String?
    let hotkeyCode: Int
    let hotkeyModifiers: Int
    let source: Source
    let testInput: String?

    init(macro: MacroScript, order: Int? = nil) {
        id = macro.id
        self.order = order ?? macro.order ?? 10
        name = macro.name
        interpreter = nil
        hotkeyCode = macro.hotkeyCode
        hotkeyModifiers = macro.hotkeyModifiers
        testInput = macro.testInput
        switch macro.source {
        case let .inlineShell(code, interpreter): source = Source(type: .inlineShell, code: code, path: nil, interpreter: interpreter)
        case let .javaScriptJXA(code): source = Source(type: .javaScriptJXA, code: code, path: nil, interpreter: nil)
        case let .file(path, interpreter): source = Source(type: .file, code: nil, path: Self.portablePath(path), interpreter: interpreter)
        }
    }

    func restoredMacro() throws -> MacroScript {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (0...255).contains(hotkeyCode),
              hotkeyModifiers >= 0 else {
            throw SettingsConfigurationError.invalidData("The configuration contains an invalid Macro.")
        }

        switch source.type {
        case .inline, .inlineShell:
            guard let code = source.code,
                  !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  source.path == nil,
                  let interpreter = source.interpreter ?? interpreter else {
                throw SettingsConfigurationError.invalidData("An inline Macro has invalid source data.")
            }
            return MacroScript(
                id: id,
                order: order,
                name: name,
                scriptPath: "",
                inlineScript: code,
                testInput: testInput,
                interpreter: interpreter,
                hotkeyCode: hotkeyCode,
                hotkeyModifiers: hotkeyModifiers
            )
        case .javaScriptJXA:
            guard let code = source.code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  source.path == nil, source.interpreter == nil else { throw SettingsConfigurationError.invalidData("A JavaScript (JXA) Macro has invalid source data.") }
            return MacroScript(id: id, order: order, name: name, source: .javaScriptJXA(code: code), testInput: testInput, hotkeyCode: hotkeyCode, hotkeyModifiers: hotkeyModifiers)
        case .file:
            guard let path = source.path,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  source.code == nil,
                  let interpreter = source.interpreter ?? interpreter else {
                throw SettingsConfigurationError.invalidData("A file-backed Macro has invalid source data.")
            }
            return MacroScript(
                id: id,
                order: order,
                name: name,
                scriptPath: path,
                inlineScript: nil,
                testInput: testInput,
                interpreter: interpreter,
                hotkeyCode: hotkeyCode,
                hotkeyModifiers: hotkeyModifiers
            )
        }
    }

    private static func portablePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + String(path.dropFirst(home.count))
    }
}

struct SettingsConfigurationPlan: Sendable {
    let settings: AppSettingsSnapshot
    let macros: [MacroScript]
}

struct SettingsConfigurationStatus: Equatable, Sendable {
    let lastLoadedAt: Date?
    let errorMessage: String?

    static let idle = SettingsConfigurationStatus(lastLoadedAt: nil, errorMessage: nil)
}

enum ConfigurationLocationPreparation: Sendable {
    case readyForRestart
    case requiresExistingFileConfirmation
}

enum SettingsConfigurationError: LocalizedError {
    case fileTooLarge
    case unsupportedVersion(Int)
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "The configuration file exceeds the 10 MB size limit."
        case .unsupportedVersion(let version):
            return "Configuration format version \(version) is not supported."
        case .invalidData(let message):
            return message
        }
    }
}

@MainActor
protocol ConfigurationRuntimeApplying: AnyObject {
    func reinstallConfigurationHotkeys() -> Bool
}

@MainActor
protocol SettingsConfigurationManaging: AnyObject {
    var fileURL: URL { get }
    var locationDescription: String { get }
    var allowsLocationChanges: Bool { get }
    var hasPersistedCustomLocation: Bool { get }
    var status: SettingsConfigurationStatus { get }
    var onStatusChange: ((SettingsConfigurationStatus) -> Void)? { get set }

    func loadInitialConfiguration()
    func attach(runtimeManager: ConfigurationRuntimeApplying)
    func startMonitoring(canApplyExternalChanges: @escaping () -> Bool)
    func stopMonitoring()
    func reloadFromDisk() async throws
    func prepareCustomLocation(
        at fileURL: URL,
        useExistingFile: Bool
    ) async throws -> ConfigurationLocationPreparation
    func resetCustomLocation()
}
