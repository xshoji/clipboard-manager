import Foundation

struct SettingsConfigurationDocument: Codable, Sendable {
    static let currentFormatVersion = 1

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
        guard formatVersion == Self.currentFormatVersion else {
            throw SettingsConfigurationError.unsupportedVersion(formatVersion)
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
              (50...60_000).contains(pollingIntervalMs) else {
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
            case file
        }

        let type: Kind
        let code: String?
        let path: String?
    }

    let id: UUID
    let order: Int
    let name: String
    let interpreter: String
    let hotkeyCode: Int
    let hotkeyModifiers: Int
    let source: Source
    let testInput: String?

    init(macro: MacroScript, order: Int? = nil) {
        id = macro.id
        self.order = order ?? macro.order ?? 10
        name = macro.name
        interpreter = macro.interpreter
        hotkeyCode = macro.hotkeyCode
        hotkeyModifiers = macro.hotkeyModifiers
        testInput = macro.testInput
        if let code = macro.inlineScript {
            source = Source(type: .inline, code: code, path: nil)
        } else {
            source = Source(type: .file, code: nil, path: Self.portablePath(macro.scriptPath))
        }
    }

    func restoredMacro() throws -> MacroScript {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !interpreter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (0...255).contains(hotkeyCode),
              hotkeyModifiers >= 0 else {
            throw SettingsConfigurationError.invalidData("The configuration contains an invalid Macro.")
        }

        switch source.type {
        case .inline:
            guard let code = source.code,
                  !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  source.path == nil else {
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
        case .file:
            guard let path = source.path,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  source.code == nil else {
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
