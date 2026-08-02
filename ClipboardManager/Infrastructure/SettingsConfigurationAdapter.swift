import Darwin
import Foundation

enum SettingsConfigurationBootstrap {
    static let customPathKey = "configurationFilePath"

    static func customPath(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: customPathKey)
    }

    static func setCustomPath(_ path: String, defaults: UserDefaults = .standard) {
        defaults.set(path, forKey: customPathKey)
    }

    static func resetCustomPath(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: customPathKey)
    }
}

@MainActor
final class SettingsConfigurationAdapter: SettingsConfigurationManaging {
    nonisolated private static let maximumFileSize = 10 * 1_024 * 1_024
    nonisolated private static let debounceNanoseconds: UInt64 = 400_000_000

    let fileURL: URL
    let locationDescription: String
    let allowsLocationChanges: Bool
    var hasPersistedCustomLocation: Bool {
        SettingsConfigurationBootstrap.customPath(defaults: bootstrapDefaults) != nil
    }
    private(set) var status: SettingsConfigurationStatus = .idle
    var onStatusChange: ((SettingsConfigurationStatus) -> Void)?

    private let settings: AppSettings
    private let bootstrapDefaults: UserDefaults
    private let startupError: String?
    private let createsParentDirectory: Bool
    private weak var runtimeManager: ConfigurationRuntimeApplying?
    private var settingsObserver: NSObjectProtocol?
    private var directorySource: DispatchSourceFileSystemObject?
    private var writeTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var canApplyExternalChanges: (() -> Bool)?
    private var isApplyingConfiguration = false
    private var hasPendingWrite = false
    private var allowsAutomaticWrites = false
    private var isPerformingWrite = false
    private var pendingDocument: SettingsConfigurationDocument?
    private var lastWrittenHash: String?

    init(
        settings: AppSettings,
        fileURL: URL,
        locationDescription: String = "Explicit path",
        allowsLocationChanges: Bool = true,
        bootstrapDefaults: UserDefaults = .standard,
        startupError: String? = nil,
        createsParentDirectory: Bool = true
    ) {
        self.settings = settings
        self.fileURL = fileURL
        self.locationDescription = locationDescription
        self.allowsLocationChanges = allowsLocationChanges
        self.bootstrapDefaults = bootstrapDefaults
        self.startupError = startupError
        self.createsParentDirectory = createsParentDirectory
    }

    func loadInitialConfiguration() {
        if let startupError {
            allowsAutomaticWrites = false
            updateStatus(error: startupError)
            return
        }
        do {
            try createConfigurationDirectory()
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let loaded = try Self.readConfiguration(from: fileURL)
                try apply(loaded.plan, updateRuntime: false)
                lastWrittenHash = loaded.hash
                allowsAutomaticWrites = true
                updateStatus(error: nil)
            } else {
                let document = SettingsConfigurationDocument(settings: settings)
                let hash = try Self.write(document, to: fileURL)
                lastWrittenHash = hash
                // Re-read our generated document so migrated Macros receive explicit order values.
                try apply(document.validatedPlan(), updateRuntime: false)
                allowsAutomaticWrites = true
                updateStatus(error: nil)
            }
        } catch {
            allowsAutomaticWrites = false
            updateStatus(error: error.localizedDescription)
        }
    }

    func attach(runtimeManager: ConfigurationRuntimeApplying) {
        self.runtimeManager = runtimeManager
    }

    func startMonitoring(canApplyExternalChanges: @escaping () -> Bool) {
        guard startupError == nil, settingsObserver == nil else { return }
        self.canApplyExternalChanges = canApplyExternalChanges
        installSettingsObserver()
        startDirectoryWatcher()
    }

    private func installSettingsObserver() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .appSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleWrite()
            }
        }
    }

    func stopMonitoring() {
        if !isPerformingWrite {
            writeTask?.cancel()
            writeTask = nil
        }
        if hasPendingWrite, allowsAutomaticWrites, !isPerformingWrite {
            do {
                lastWrittenHash = try Self.writeIfUnchanged(
                    pendingDocument ?? SettingsConfigurationDocument(settings: settings),
                    to: fileURL,
                    expectedHash: lastWrittenHash
                )
                hasPendingWrite = false
                pendingDocument = nil
            } catch {
                updateStatus(error: error.localizedDescription)
            }
        }
        reloadTask?.cancel()
        reloadTask = nil
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        settingsObserver = nil
        directorySource?.cancel()
        directorySource = nil
    }

    func reloadFromDisk() async throws {
        if let startupError {
            throw SettingsConfigurationError.invalidData(startupError)
        }
        guard canApplyExternalChanges?() != false else {
            throw SettingsConfigurationError.invalidData(
                "Save or discard unsaved Macro edits before reloading the configuration."
            )
        }
        if isPerformingWrite {
            await writeTask?.value
        } else {
            writeTask?.cancel()
            writeTask = nil
        }
        hasPendingWrite = false
        pendingDocument = nil
        do {
            let loaded = try await Task.detached {
                try Self.readConfiguration(from: self.fileURL)
            }.value
            try apply(loaded.plan, updateRuntime: true)
            lastWrittenHash = loaded.hash
            allowsAutomaticWrites = true
            updateStatus(error: nil)
        } catch {
            allowsAutomaticWrites = false
            updateStatus(error: error.localizedDescription)
            throw error
        }
    }

    func prepareCustomLocation(
        at requestedFileURL: URL,
        useExistingFile: Bool
    ) async throws -> ConfigurationLocationPreparation {
        guard allowsLocationChanges else {
            throw SettingsConfigurationError.invalidData(
                "The configuration location is controlled by the environment and cannot be changed here."
            )
        }

        let candidate = requestedFileURL.standardizedFileURL
        try Self.validateCustomLocation(candidate)
        if FileManager.default.fileExists(atPath: candidate.path) {
            _ = try await Task.detached {
                try Self.readConfiguration(from: candidate)
            }.value
            guard useExistingFile else {
                return .requiresExistingFileConfirmation
            }
        } else {
            let document = SettingsConfigurationDocument(settings: settings)
            let hash = try await Task.detached {
                try Self.writeNewConfiguration(document, to: candidate)
            }.value
            if hash == nil {
                _ = try await Task.detached {
                    try Self.readConfiguration(from: candidate)
                }.value
                guard useExistingFile else {
                    return .requiresExistingFileConfirmation
                }
            }
        }

        SettingsConfigurationBootstrap.setCustomPath(candidate.path, defaults: bootstrapDefaults)
        return .readyForRestart
    }

    func resetCustomLocation() {
        guard allowsLocationChanges else { return }
        SettingsConfigurationBootstrap.resetCustomPath(defaults: bootstrapDefaults)
    }

    private func scheduleWrite() {
        guard !isApplyingConfiguration, allowsAutomaticWrites else { return }
        hasPendingWrite = true
        pendingDocument = SettingsConfigurationDocument(settings: settings)
        guard writeTask == nil else { return }
        writeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.debounceNanoseconds)
                guard !Task.isCancelled, let self else { return }
                try await self.writePendingDocuments()
            } catch is CancellationError {
                self?.writeTask = nil
            } catch {
                self?.allowsAutomaticWrites = false
                self?.pendingDocument = nil
                self?.hasPendingWrite = false
                self?.writeTask = nil
                self?.updateStatus(error: error.localizedDescription)
                self?.scheduleExternalReload()
            }
        }
    }

    private func writePendingDocuments() async throws {
        while let document = pendingDocument {
            pendingDocument = nil
            isPerformingWrite = true
            let expectedHash = lastWrittenHash
            let result: String
            do {
                result = try await Task.detached {
                    try Self.writeIfUnchanged(
                        document,
                        to: self.fileURL,
                        expectedHash: expectedHash
                    )
                }.value
            } catch {
                isPerformingWrite = false
                throw error
            }
            isPerformingWrite = false
            lastWrittenHash = result
            updateStatus(error: nil)
        }
        hasPendingWrite = false
        writeTask = nil
    }

    private func startDirectoryWatcher() {
        let directoryURL = fileURL.deletingLastPathComponent()
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            updateStatus(error: "Could not monitor the configuration directory.")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleExternalReload()
            }
        }
        source.setCancelHandler { close(descriptor) }
        directorySource = source
        source.resume()
    }

    private func scheduleExternalReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.debounceNanoseconds)
                guard !Task.isCancelled, let self else { return }
                let loaded = try await Task.detached {
                    try Self.readConfiguration(from: self.fileURL)
                }.value
                guard !Task.isCancelled, loaded.hash != self.lastWrittenHash else { return }
                guard self.canApplyExternalChanges?() != false else {
                    self.updateStatus(
                        error: "Configuration changed externally. Save or discard Macro edits, then reload."
                    )
                    return
                }
                try self.apply(loaded.plan, updateRuntime: true)
                self.lastWrittenHash = loaded.hash
                self.allowsAutomaticWrites = true
                self.updateStatus(error: nil)
            } catch is CancellationError {
                return
            } catch {
                self?.allowsAutomaticWrites = false
                self?.pendingDocument = nil
                self?.hasPendingWrite = false
                self?.updateStatus(error: error.localizedDescription)
            }
        }
    }

    private func apply(_ plan: SettingsConfigurationPlan, updateRuntime: Bool) throws {
        let previousSettings = AppSettingsSnapshot(settings: settings)
        let previousMacros = settings.macroScripts
        let trustedMacros = mergeLocalTrust(into: plan.macros, from: previousMacros)
        let shouldResumeSettingsObserver = settingsObserver != nil
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }

        isApplyingConfiguration = true
        defer {
            isApplyingConfiguration = false
            if shouldResumeSettingsObserver {
                installSettingsObserver()
            }
        }
        plan.settings.apply(to: settings)
        settings.macroScripts = trustedMacros

        if updateRuntime, let runtimeManager {
            guard runtimeManager.reinstallConfigurationHotkeys() else {
                previousSettings.apply(to: settings)
                settings.macroScripts = previousMacros
                _ = runtimeManager.reinstallConfigurationHotkeys()
                throw SettingsConfigurationError.invalidData(
                    "The configuration could not be applied because a hotkey is unavailable."
                )
            }
        }

        guard updateRuntime else { return }
        LoginItemManager.shared.updateRegistration(enabled: settings.launchAtLogin)
        NotificationCenter.default.post(name: .retentionChanged, object: nil)
        NotificationCenter.default.post(name: .maxCountChanged, object: nil)
        NotificationCenter.default.post(name: .pollingIntervalChanged, object: nil)
        NotificationCenter.default.post(name: .alwaysOnTopChanged, object: nil)
        NotificationCenter.default.post(name: .actionHotkeysChanged, object: nil)
    }

    private func mergeLocalTrust(
        into incoming: [MacroScript],
        from current: [MacroScript]
    ) -> [MacroScript] {
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return incoming.map { macro in
            guard let existing = currentByID[macro.id] else { return macro }
            let sameSource: Bool
            if let code = macro.inlineScript {
                sameSource = existing.inlineScript == code
            } else {
                sameSource = existing.inlineScript == nil
                    && MacroScriptPathValidator.resolve(path: existing.scriptPath)
                        == MacroScriptPathValidator.resolve(path: macro.scriptPath)
            }
            guard sameSource else { return macro }
            var trusted = macro
            trusted.lastFingerprint = existing.lastFingerprint
            trusted.lastModified = existing.lastModified
            return trusted
        }
    }

    private func createConfigurationDirectory() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        if createsParentDirectory {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SettingsConfigurationError.invalidData(
                "The configuration parent directory does not exist."
            )
        }
    }

    nonisolated private static func validateCustomLocation(_ fileURL: URL) throws {
        guard fileURL.isFileURL,
              (fileURL.path as NSString).isAbsolutePath,
              fileURL.lastPathComponent == "config.json" else {
            throw SettingsConfigurationError.invalidData(
                "Choose an absolute file path ending in config.json."
            )
        }

        let fileManager = FileManager.default
        let parent = fileURL.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw SettingsConfigurationError.invalidData(
                "The selected configuration parent directory does not exist."
            )
        }

        if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw SettingsConfigurationError.invalidData(
                "The selected configuration file must not be a symbolic link."
            )
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw SettingsConfigurationError.invalidData(
                "The selected configuration path is a directory. Choose config.json instead."
            )
        }
    }

    private func updateStatus(error: String?) {
        status = SettingsConfigurationStatus(lastLoadedAt: error == nil ? Date() : status.lastLoadedAt, errorMessage: error)
        onStatusChange?(status)
    }

    nonisolated private static func readConfiguration(
        from url: URL
    ) throws -> (plan: SettingsConfigurationPlan, hash: String) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw SettingsConfigurationError.invalidData("The configuration path is not a regular file.")
        }
        guard let fileSize = values.fileSize, fileSize <= maximumFileSize else {
            throw SettingsConfigurationError.fileTooLarge
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumFileSize else { throw SettingsConfigurationError.fileTooLarge }
        let document: SettingsConfigurationDocument
        do {
            document = try JSONDecoder().decode(SettingsConfigurationDocument.self, from: data)
        } catch {
            throw SettingsConfigurationError.invalidData(
                "The configuration file is not valid ClipboardManager JSON."
            )
        }
        return (try document.validatedPlan(), HashUtil.sha256Hex(of: data))
    }

    nonisolated private static func write(
        _ document: SettingsConfigurationDocument,
        to url: URL
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= maximumFileSize else { throw SettingsConfigurationError.fileTooLarge }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return HashUtil.sha256Hex(of: data)
    }

    nonisolated static func writeNewConfiguration(
        _ document: SettingsConfigurationDocument,
        to url: URL
    ) throws -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= maximumFileSize else { throw SettingsConfigurationError.fileTooLarge }

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".config.json.\(UUID().uuidString).tmp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryURL.path
        )

        let result = temporaryURL.path.withCString { temporaryPath in
            url.path.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    temporaryPath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if result == 0 {
            return HashUtil.sha256Hex(of: data)
        }
        if errno == EEXIST {
            return nil
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    nonisolated private static func writeIfUnchanged(
        _ document: SettingsConfigurationDocument,
        to url: URL,
        expectedHash: String?
    ) throws -> String {
        guard let expectedHash else {
            throw SettingsConfigurationError.invalidData(
                "Automatic save is paused until the configuration file is reloaded."
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let newData = try encoder.encode(document)
        guard newData.count <= maximumFileSize else { throw SettingsConfigurationError.fileTooLarge }
        let currentData = try Data(contentsOf: url, options: .mappedIfSafe)
        guard currentData.count <= maximumFileSize else { throw SettingsConfigurationError.fileTooLarge }
        guard HashUtil.sha256Hex(of: currentData) == expectedHash else {
            throw SettingsConfigurationError.invalidData(
                "The configuration changed externally and was not overwritten. Reload it before saving more changes."
            )
        }
        try newData.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return HashUtil.sha256Hex(of: newData)
    }
}
