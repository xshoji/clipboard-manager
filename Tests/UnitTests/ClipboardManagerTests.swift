import AppKit
import SwiftData
import XCTest
@testable import ClipboardManager

@MainActor
final class StoreBackupTests: XCTestCase {
    func testPartialBackupFailureDoesNotReportSuccessOrRemoveOriginalFiles() throws {
        struct InjectedCopyError: Error {}

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreBackupTests-\(UUID().uuidString)", isDirectory: true)
        let storeURL = root.appendingPathComponent("Clipboard.store")
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        let backupDirectory = root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("store".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: walURL)
        try Data("shm".utf8).write(to: shmURL)

        let manifest = PersistenceController.backupStoreFiles(
            at: storeURL,
            into: backupDirectory
        ) { source, destination in
            if source == storeURL {
                throw InjectedCopyError()
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }

        XCTAssertNil(manifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shmURL.path))
        let backupNames = try FileManager.default.contentsOfDirectory(atPath: backupDirectory.path)
        XCTAssertTrue(backupNames.contains { $0.contains("-wal.backup") })
    }

    func testBackupRequiresMainStoreEvenWhenSidecarExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreBackupTests-\(UUID().uuidString)", isDirectory: true)
        let storeURL = root.appendingPathComponent("Clipboard.store")
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let backupDirectory = root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("wal".utf8).write(to: walURL)

        let manifest = PersistenceController.backupStoreFiles(
            at: storeURL,
            into: backupDirectory
        )

        XCTAssertNil(manifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))
    }
}

@MainActor
final class PersistenceMigrationTests: XCTestCase {
    func testV3StoreMigratesToV4WithoutDroppingHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Clipboard.store")
        let id = UUID()

        do {
            let schema = Schema(versionedSchema: SchemaV3.self)
            let configuration = ModelConfiguration(nil, schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: configuration)
            container.mainContext.insert(ClipboardEntitySchemaV3.ClipboardEntity(
                id: id,
                kind: "text",
                text: "legacy text",
                html: Data("<b>legacy text</b>".utf8),
                contentHash: "legacy-hash"
            ))
            try container.mainContext.save()
        }

        let controller = PersistenceController(settings: .shared, storeURL: storeURL)
        let migrated = try controller.container.mainContext.fetch(
            FetchDescriptor<ClipboardEntity>(predicate: #Predicate { $0.id == id })
        ).first

        XCTAssertEqual(migrated?.text, "legacy text")
        XCTAssertEqual(migrated?.html, Data("<b>legacy text</b>".utf8))
        XCTAssertNil(migrated?.textAvailabilityRaw)
        XCTAssertNil(migrated?.payloadByteCount)

        let dataActor = ClipboardDataActor(modelContainer: controller.container)
        let item = await dataActor.fetch(id: id)
        XCTAssertEqual(item?.textAvailability, .unknown)
        XCTAssertFalse(item?.isHtml ?? true)
    }
}

final class MacroScriptTests: XCTestCase {
    func testDecodesExistingSettingsWithoutTestInput() throws {
        let id = UUID()
        let data = Data("""
        {
          "id": "\(id.uuidString)",
          "name": "Existing Macro",
          "scriptPath": "",
          "inlineScript": "cat",
          "interpreter": "/bin/sh",
          "hotkeyCode": 0,
          "hotkeyModifiers": 0
        }
        """.utf8)

        let macro = try JSONDecoder().decode(MacroScript.self, from: data)

        XCTAssertNil(macro.order)
        XCTAssertNil(macro.testInput)
    }

    func testRoundTripsTestInputWithMacroSettings() throws {
        let macro = MacroScript(
            name: "Testable Macro",
            scriptPath: "",
            inlineScript: "cat",
            testInput: "reusable test case"
        )

        let decoded = try JSONDecoder().decode(
            MacroScript.self,
            from: JSONEncoder().encode(macro)
        )

        XCTAssertEqual(decoded.testInput, "reusable test case")
    }
}

@MainActor
final class SettingsConfigurationTests: XCTestCase {
    func testSettingsViewModelUsesInjectedRelaunchAction() throws {
        let adapter = SettingsConfigurationAdapter(
            settings: AppSettings.shared,
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("config.json")
        )
        let viewModel = SettingsViewModel(
            settings: AppSettings.shared,
            configurationManager: adapter
        )
        var wasRequested = false
        viewModel.onRelaunchRequested = {
            wasRequested = true
        }

        try viewModel.requestRelaunch()

        XCTAssertTrue(wasRequested)
    }

    func testSettingsViewModelMovesMacroAndPreservesStableOrderSlots() {
        let settings = AppSettings.shared
        let previous = settings.macroScripts
        defer { settings.macroScripts = previous }
        let first = MacroScript(order: 10, name: "First", scriptPath: "", inlineScript: "cat")
        let second = MacroScript(order: 30, name: "Second", scriptPath: "", inlineScript: "cat")
        let third = MacroScript(order: 50, name: "Third", scriptPath: "", inlineScript: "cat")
        settings.macroScripts = [first, second, third]
        let adapter = SettingsConfigurationAdapter(
            settings: settings,
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("config.json")
        )
        let viewModel = SettingsViewModel(settings: settings, configurationManager: adapter)

        viewModel.moveMacro(id: third.id, to: 1)

        XCTAssertEqual(settings.macroScripts.map(\.name), ["First", "Third", "Second"])
        XCTAssertEqual(settings.macroScripts.compactMap(\.order), [10, 30, 50])
        let document = SettingsConfigurationDocument(settings: settings)
        XCTAssertEqual(document.macros.map(\.name), ["First", "Third", "Second"])
        XCTAssertEqual(document.macros.map(\.order), [10, 30, 50])
    }

    func testExplicitConfigurationPathTakesPrecedenceOverXDGConfigHome() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let customFileURL = directory.appendingPathComponent("config.json")

        let location = AppLaunchConfiguration.resolveProductionConfigurationLocation(
            environment: [
                "CLIPBOARD_MANAGER_CONFIG_PATH": customFileURL.path,
                "XDG_CONFIG_HOME": "/tmp/ignored-xdg-config",
            ],
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        XCTAssertEqual(location.fileURL, customFileURL)
        XCTAssertEqual(location.sourceDescription, "CLIPBOARD_MANAGER_CONFIG_PATH")
        XCTAssertNil(location.errorMessage)
        XCTAssertFalse(location.allowsLocationChanges)
        XCTAssertFalse(location.createsParentDirectory)
    }

    func testPersistedCustomLocationTakesPrecedenceOverXDGConfigHome() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let customFileURL = directory.appendingPathComponent("config.json")

        let location = AppLaunchConfiguration.resolveProductionConfigurationLocation(
            environment: ["XDG_CONFIG_HOME": "/tmp/ignored-xdg-config"],
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            persistedCustomPath: customFileURL.path
        )

        XCTAssertEqual(location.fileURL, customFileURL)
        XCTAssertEqual(location.sourceDescription, "Custom location")
        XCTAssertTrue(location.allowsLocationChanges)
        XCTAssertNil(location.errorMessage)
        XCTAssertFalse(location.createsParentDirectory)
    }

    func testExplicitEnvironmentPathTakesPrecedenceOverPersistedCustomLocation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let environmentFileURL = directory.appendingPathComponent("config.json")

        let location = AppLaunchConfiguration.resolveProductionConfigurationLocation(
            environment: ["CLIPBOARD_MANAGER_CONFIG_PATH": environmentFileURL.path],
            homeDirectory: directory,
            persistedCustomPath: "/tmp/ignored-custom/config.json"
        )

        XCTAssertEqual(location.fileURL, environmentFileURL)
        XCTAssertEqual(location.sourceDescription, "CLIPBOARD_MANAGER_CONFIG_PATH")
    }

    func testInvalidPersistedCustomLocationDoesNotFallBackToXDG() {
        let missingFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("config.json")
        let location = AppLaunchConfiguration.resolveProductionConfigurationLocation(
            environment: ["XDG_CONFIG_HOME": "/tmp/ignored-xdg-config"],
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            persistedCustomPath: missingFileURL.path
        )

        XCTAssertEqual(location.sourceDescription, "Custom location")
        XCTAssertNotNil(location.errorMessage)
        XCTAssertEqual(location.fileURL, missingFileURL)
    }

    func testConfigurationUsesXDGConfigHomeWhenSpecified() {
        let location = AppLaunchConfiguration.resolveProductionConfigurationLocation(
            environment: ["XDG_CONFIG_HOME": "/tmp/custom-config"],
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        XCTAssertEqual(location.fileURL.path, "/tmp/custom-config/clipboard-manager/config.json")
        XCTAssertEqual(location.sourceDescription, "XDG_CONFIG_HOME")
        XCTAssertNil(location.errorMessage)
        XCTAssertTrue(location.createsParentDirectory)
    }

    func testConfigurationFallsBackToDotConfigForInvalidXDGConfigHome() {
        let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        for environment in [[:], ["XDG_CONFIG_HOME": ""], ["XDG_CONFIG_HOME": "relative/path"]] {
            let location = AppLaunchConfiguration.resolveProductionConfigurationLocation(
                environment: environment,
                homeDirectory: homeDirectory
            )
            XCTAssertEqual(location.fileURL.path, "/Users/example/.config/clipboard-manager/config.json")
            XCTAssertEqual(location.sourceDescription, "Default (~/.config)")
            XCTAssertNil(location.errorMessage)
            XCTAssertTrue(location.createsParentDirectory)
        }
    }

    func testInvalidExplicitConfigurationPathDoesNotFallBackToDefault() {
        let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let location = AppLaunchConfiguration.resolveProductionConfigurationLocation(
            environment: [
                "CLIPBOARD_MANAGER_CONFIG_PATH": "relative/config.json",
                "XDG_CONFIG_HOME": "/tmp/ignored-xdg-config",
            ],
            homeDirectory: homeDirectory
        )

        XCTAssertEqual(location.sourceDescription, "CLIPBOARD_MANAGER_CONFIG_PATH")
        XCTAssertNotNil(location.errorMessage)
        XCTAssertFalse(location.createsParentDirectory)
        XCTAssertNotEqual(
            location.fileURL.path,
            homeDirectory.appendingPathComponent(".config/clipboard-manager/config.json").path
        )
    }

    func testExplicitConfigurationPathRequiresExistingParentAndConfigFileName() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missingParentLocation = AppLaunchConfiguration.resolveProductionConfigurationLocation(
            environment: [
                "CLIPBOARD_MANAGER_CONFIG_PATH": directory.appendingPathComponent("config.json").path,
            ],
            homeDirectory: directory
        )
        XCTAssertNotNil(missingParentLocation.errorMessage)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wrongNameLocation = AppLaunchConfiguration.resolveProductionConfigurationLocation(
            environment: [
                "CLIPBOARD_MANAGER_CONFIG_PATH": directory.appendingPathComponent("settings.json").path,
            ],
            homeDirectory: directory
        )
        XCTAssertNotNil(wrongNameLocation.errorMessage)
    }

    func testExplicitConfigurationPathRejectsSymbolicLink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let targetURL = directory.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: targetURL)
        let linkURL = directory.appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let location = AppLaunchConfiguration.resolveProductionConfigurationLocation(
            environment: ["CLIPBOARD_MANAGER_CONFIG_PATH": linkURL.path],
            homeDirectory: directory
        )

        XCTAssertNotNil(location.errorMessage)
    }

    func testExplicitConfigurationPathRejectsDanglingSymbolicLink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let linkURL = directory.appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: directory.appendingPathComponent("missing.json")
        )

        let location = AppLaunchConfiguration.resolveProductionConfigurationLocation(
            environment: ["CLIPBOARD_MANAGER_CONFIG_PATH": linkURL.path],
            homeDirectory: directory
        )

        XCTAssertNotNil(location.errorMessage)
    }

    func testExplicitConfigurationPathCreatesFileWithoutCreatingParent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("config.json")
        let adapter = SettingsConfigurationAdapter(
            settings: AppSettings.shared,
            fileURL: fileURL,
            createsParentDirectory: false
        )

        adapter.loadInitialConfiguration()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(adapter.status.errorMessage)
    }

    func testPreparingNewCustomLocationWritesConfigurationThenPersistsPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultsName = "SettingsConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let currentFileURL = directory.appendingPathComponent("current.json")
        let candidateURL = directory.appendingPathComponent("config.json")
        let adapter = SettingsConfigurationAdapter(
            settings: AppSettings.shared,
            fileURL: currentFileURL,
            bootstrapDefaults: defaults
        )

        let result = try await adapter.prepareCustomLocation(
            at: candidateURL,
            useExistingFile: false
        )

        guard case .readyForRestart = result else {
            return XCTFail("Expected a new configuration file to be ready for restart")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))
        XCTAssertEqual(SettingsConfigurationBootstrap.customPath(defaults: defaults), candidateURL.path)
        XCTAssertTrue(adapter.hasPersistedCustomLocation)
    }

    func testExclusiveNewConfigurationWritePreservesExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidateURL = directory.appendingPathComponent("config.json")
        let existingData = Data("preserve me".utf8)
        try existingData.write(to: candidateURL)

        let hash = try SettingsConfigurationAdapter.writeNewConfiguration(
            SettingsConfigurationDocument(settings: AppSettings.shared),
            to: candidateURL
        )

        XCTAssertNil(hash)
        XCTAssertEqual(try Data(contentsOf: candidateURL), existingData)
    }

    func testPreparingExistingCustomLocationRequiresConfirmationWithoutOverwriting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultsName = "SettingsConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let candidateURL = directory.appendingPathComponent("config.json")
        let originalData = try JSONEncoder().encode(
            SettingsConfigurationDocument(settings: AppSettings.shared)
        )
        try originalData.write(to: candidateURL)
        let adapter = SettingsConfigurationAdapter(
            settings: AppSettings.shared,
            fileURL: directory.appendingPathComponent("current.json"),
            bootstrapDefaults: defaults
        )

        let initialResult = try await adapter.prepareCustomLocation(
            at: candidateURL,
            useExistingFile: false
        )

        guard case .requiresExistingFileConfirmation = initialResult else {
            return XCTFail("Expected an existing configuration file to require confirmation")
        }
        XCTAssertNil(SettingsConfigurationBootstrap.customPath(defaults: defaults))
        XCTAssertEqual(try Data(contentsOf: candidateURL), originalData)

        let confirmedResult = try await adapter.prepareCustomLocation(
            at: candidateURL,
            useExistingFile: true
        )
        guard case .readyForRestart = confirmedResult else {
            return XCTFail("Expected the confirmed configuration file to be ready for restart")
        }
        XCTAssertEqual(SettingsConfigurationBootstrap.customPath(defaults: defaults), candidateURL.path)
        XCTAssertEqual(try Data(contentsOf: candidateURL), originalData)
    }

    func testInvalidExistingCustomLocationIsNotPersistedOrOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultsName = "SettingsConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let candidateURL = directory.appendingPathComponent("config.json")
        let invalidData = Data("{ invalid json".utf8)
        try invalidData.write(to: candidateURL)
        let adapter = SettingsConfigurationAdapter(
            settings: AppSettings.shared,
            fileURL: directory.appendingPathComponent("current.json"),
            bootstrapDefaults: defaults
        )

        do {
            _ = try await adapter.prepareCustomLocation(
                at: candidateURL,
                useExistingFile: false
            )
            XCTFail("Expected an invalid existing configuration to be rejected")
        } catch {
            XCTAssertNil(SettingsConfigurationBootstrap.customPath(defaults: defaults))
            XCTAssertEqual(try Data(contentsOf: candidateURL), invalidData)
        }
    }

    func testEnvironmentManagedLocationRejectsGUIChange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultsName = "SettingsConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let candidateURL = directory.appendingPathComponent("config.json")
        let adapter = SettingsConfigurationAdapter(
            settings: AppSettings.shared,
            fileURL: directory.appendingPathComponent("current.json"),
            allowsLocationChanges: false,
            bootstrapDefaults: defaults
        )

        do {
            _ = try await adapter.prepareCustomLocation(
                at: candidateURL,
                useExistingFile: false
            )
            XCTFail("Expected an environment-managed location to reject GUI changes")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: candidateURL.path))
            XCTAssertNil(SettingsConfigurationBootstrap.customPath(defaults: defaults))
        }
    }

    func testResetCustomLocationOnlyRemovesBootstrapPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultsName = "SettingsConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let fileURL = directory.appendingPathComponent("config.json")
        try Data("preserved".utf8).write(to: fileURL)
        SettingsConfigurationBootstrap.setCustomPath(fileURL.path, defaults: defaults)
        let adapter = SettingsConfigurationAdapter(
            settings: AppSettings.shared,
            fileURL: fileURL,
            bootstrapDefaults: defaults
        )

        adapter.resetCustomLocation()

        XCTAssertNil(SettingsConfigurationBootstrap.customPath(defaults: defaults))
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("preserved".utf8))
    }

    func testStartupErrorDisablesConfigurationWithoutWritingFile() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("config.json")
        let adapter = SettingsConfigurationAdapter(
            settings: AppSettings.shared,
            fileURL: fileURL,
            startupError: "Invalid explicit configuration path",
            createsParentDirectory: false
        )

        adapter.loadInitialConfiguration()
        adapter.startMonitoring(canApplyExternalChanges: { true })

        XCTAssertEqual(adapter.status.errorMessage, "Invalid explicit configuration path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        do {
            try await adapter.reloadFromDisk()
            XCTFail("Expected an invalid explicit path to disable reload")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Invalid explicit configuration path")
        }
    }

    func testInlineMacroRoundTripIncludesCodeAndTestInputWithoutTrustData() throws {
        let code = """
        #!/bin/sh
        # Preserve comments and newlines.
        cat "$CB_INPUT_FILE" > "$CB_OUTPUT_FILE"
        """
        let original = MacroScript(
            order: 20,
            name: "Inline Backup",
            scriptPath: "",
            inlineScript: code,
            testInput: "first line\nsecond line",
            lastFingerprint: "untrusted-backup-fingerprint"
        )

        let encoded = try JSONEncoder().encode(MacroSnapshot(macro: original))
        let decoded = try JSONDecoder().decode(MacroSnapshot.self, from: encoded)
        let restored = try decoded.restoredMacro()

        XCTAssertEqual(restored.inlineScript, code)
        XCTAssertEqual(restored.testInput, "first line\nsecond line")
        XCTAssertEqual(restored.order, 20)
        XCTAssertNil(restored.lastFingerprint)
        XCTAssertNil(restored.lastModified)
    }

    func testFileMacroSnapshotContainsPathAndTestInputButNoCode() throws {
        let original = MacroScript(
            name: "External Backup",
            scriptPath: "/tmp/external-script-does-not-exist.sh",
            inlineScript: nil,
            testInput: "external test case",
            lastFingerprint: "untrusted-backup-fingerprint"
        )

        let snapshot = MacroSnapshot(macro: original)
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let source = try XCTUnwrap(object["source"] as? [String: Any])
        let restored = try snapshot.restoredMacro()

        XCTAssertEqual(source["type"] as? String, "file")
        XCTAssertEqual(source["path"] as? String, original.scriptPath)
        XCTAssertNil(source["code"])
        XCTAssertEqual(restored.scriptPath, original.scriptPath)
        XCTAssertNil(restored.inlineScript)
        XCTAssertEqual(restored.testInput, "external test case")
        XCTAssertNil(restored.lastFingerprint)
    }

    func testConfigurationSortsMacrosByOrderAndAllowsGaps() throws {
        let settings = AppSettings.shared
        let previous = settings.macroScripts
        defer { settings.macroScripts = previous }
        settings.macroScripts = [
            MacroScript(order: 0, name: "First", scriptPath: "", inlineScript: "cat"),
            MacroScript(order: 40, name: "Second", scriptPath: "", inlineScript: "cat"),
        ]
        let document = SettingsConfigurationDocument(settings: settings)
        XCTAssertEqual(document.macros.map(\.order), [0, 40])
        let encoded = try JSONEncoder().encode(document)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["macros"] = Array(try XCTUnwrap(object["macros"] as? [[String: Any]]).reversed())
        let reordered = try JSONSerialization.data(withJSONObject: object)

        let plan = try JSONDecoder()
            .decode(SettingsConfigurationDocument.self, from: reordered)
            .validatedPlan()

        XCTAssertEqual(plan.macros.map(\.name), ["First", "Second"])
        XCTAssertEqual(plan.macros.compactMap(\.order), [0, 40])
    }

    func testConfigurationRoundTripsMacroTimeoutAndDefaultsMissingValue() throws {
        let settings = AppSettings.shared
        let previousTimeout = settings.macroTimeoutSeconds
        defer { settings.macroTimeoutSeconds = previousTimeout }
        settings.macroTimeoutSeconds = 17

        let encoded = try JSONEncoder().encode(SettingsConfigurationDocument(settings: settings))
        let decoded = try JSONDecoder().decode(SettingsConfigurationDocument.self, from: encoded)
        XCTAssertEqual(try decoded.validatedPlan().settings.macroTimeoutSeconds, 17)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var settingsObject = try XCTUnwrap(object["settings"] as? [String: Any])
        settingsObject.removeValue(forKey: "macroTimeoutSeconds")
        object["settings"] = settingsObject
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacyDocument = try JSONDecoder().decode(SettingsConfigurationDocument.self, from: legacyData)
        let legacySettings = try legacyDocument.validatedPlan().settings

        XCTAssertNil(legacySettings.macroTimeoutSeconds)
        legacySettings.apply(to: settings)
        XCTAssertEqual(settings.macroTimeoutSeconds, AppSettings.defaultMacroTimeoutSeconds)
    }

    func testConfigurationRejectsMacroTimeoutOutsideSupportedRange() throws {
        let encoded = try JSONEncoder().encode(SettingsConfigurationDocument(settings: AppSettings.shared))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var settingsObject = try XCTUnwrap(object["settings"] as? [String: Any])
        settingsObject["macroTimeoutSeconds"] = 301
        object["settings"] = settingsObject
        let invalidData = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder()
                .decode(SettingsConfigurationDocument.self, from: invalidData)
                .validatedPlan()
        )
    }

    func testConfigurationRejectsDuplicateOrder() throws {
        let settings = AppSettings.shared
        let previous = settings.macroScripts
        defer { settings.macroScripts = previous }
        settings.macroScripts = [
            MacroScript(order: 10, name: "First", scriptPath: "", inlineScript: "cat"),
            MacroScript(order: 20, name: "Second", scriptPath: "", inlineScript: "cat"),
        ]
        let encoded = try JSONEncoder().encode(SettingsConfigurationDocument(settings: settings))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var macros = try XCTUnwrap(object["macros"] as? [[String: Any]])
        macros[1]["order"] = 10
        object["macros"] = macros
        let duplicateOrder = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder()
                .decode(SettingsConfigurationDocument.self, from: duplicateOrder)
                .validatedPlan()
        )
    }

    func testMissingConfigurationMigratesCurrentSettingsWithExplicitOrders() throws {
        let settings = AppSettings.shared
        let previous = settings.macroScripts
        defer { settings.macroScripts = previous }
        settings.macroScripts = [
            MacroScript(name: "First", scriptPath: "", inlineScript: "cat"),
            MacroScript(name: "Second", scriptPath: "", inlineScript: "cat"),
        ]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("config.json")
        let adapter = SettingsConfigurationAdapter(settings: settings, fileURL: fileURL)

        adapter.loadInitialConfiguration()

        let document = try JSONDecoder().decode(
            SettingsConfigurationDocument.self,
            from: Data(contentsOf: fileURL)
        )
        XCTAssertEqual(document.macros.map(\.order), [10, 20])
        XCTAssertEqual(settings.macroScripts.compactMap(\.order), [10, 20])
        XCTAssertNil(adapter.status.errorMessage)
    }

    func testInvalidExistingConfigurationIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("config.json")
        let malformed = Data("{ invalid json".utf8)
        try malformed.write(to: fileURL)
        let adapter = SettingsConfigurationAdapter(settings: AppSettings.shared, fileURL: fileURL)

        adapter.loadInitialConfiguration()

        XCTAssertEqual(try Data(contentsOf: fileURL), malformed)
        XCTAssertNotNil(adapter.status.errorMessage)
    }

    func testMonitoredSettingsChangeWritesWithoutActorIsolationCrash() async throws {
        let settings = AppSettings.shared
        let previousMaxItemSize = settings.maxItemSizeMB
        defer { settings.maxItemSizeMB = previousMaxItemSize }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("config.json")
        let adapter = SettingsConfigurationAdapter(settings: settings, fileURL: fileURL)
        adapter.loadInitialConfiguration()
        adapter.startMonitoring(canApplyExternalChanges: { true })

        let updatedMaxItemSize = previousMaxItemSize == 10 ? 11 : 10
        settings.maxItemSizeMB = updatedMaxItemSize
        try await Task.sleep(for: .seconds(1))
        adapter.stopMonitoring()

        let document = try JSONDecoder().decode(
            SettingsConfigurationDocument.self,
            from: Data(contentsOf: fileURL)
        )
        XCTAssertEqual(document.settings.maxItemSizeMB, updatedMaxItemSize)
    }
}

@MainActor
final class PasteCoordinatorTests: XCTestCase {
    func testStandardRichPasteRecordsActualRichOutput() async {
        let harness = TestHarness()
        let item = makeClipboardItem(kind: "text", contentHash: "history-hash")
        let html = Data("<b>history text</b>".utf8)
        harness.repository.textContent[item.id] = .init(text: "history text", richText: nil, html: html)

        let succeeded = await harness.coordinator.pasteStandard(item: item, rich: true)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(harness.pasteboard.string, "history text")
        XCTAssertEqual(harness.pasteboard.recordedItems.map(\.text), ["history text"])
        XCTAssertEqual(harness.pasteboard.recordedItems[0].html, html)
        XCTAssertEqual(harness.activator.callCount, 1)
    }

    func testPlainTextPasteRecordsOnlyTheActualPlainOutput() async {
        let harness = TestHarness()
        let item = makeClipboardItem(kind: "text", contentHash: "original-hash")
        harness.repository.textContent[item.id] = .init(
            text: "formatted text",
            richText: Data("rich payload".utf8),
            html: Data("<b>formatted text</b>".utf8)
        )

        let succeeded = await harness.coordinator.pasteStandard(item: item, rich: false)

        XCTAssertTrue(succeeded)
        let recorded = harness.pasteboard.recordedItems[0]
        XCTAssertEqual(recorded.text, "formatted text")
        XCTAssertNil(recorded.richText)
        XCTAssertNil(recorded.html)
        XCTAssertEqual(recorded.contentHash, HashUtil.sha256Hex(of: Data("formatted text".utf8)))
    }

    func testHtmlOnlyRichPastePreservesRawHtmlAndRecordsItWithoutPlainText() async {
        let harness = TestHarness()
        let html = Data("<table><tr><td>value</td></tr></table>".utf8)
        let hash = HashUtil.sha256HTMLOnly(html)
        let item = makeClipboardItem(
            kind: "text",
            contentHash: hash,
            isHtml: true,
            textAvailability: .unavailable
        )
        harness.repository.textContent[item.id] = .init(text: nil, richText: nil, html: html)

        let succeeded = await harness.coordinator.pasteStandard(item: item, rich: true, activate: false)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(harness.pasteboard.html, html)
        XCTAssertNil(harness.pasteboard.string)
        XCTAssertEqual(harness.pasteboard.recordedItems.first?.html, html)
        XCTAssertNil(harness.pasteboard.recordedItems.first?.text)
        XCTAssertEqual(harness.pasteboard.recordedItems.first?.contentHash, hash)
    }

    func testHtmlOnlyPlainPasteRejectsWithoutChangingPasteboard() async {
        let harness = TestHarness()
        let html = Data("<b>value</b>".utf8)
        let item = makeClipboardItem(
            kind: "text",
            isHtml: true,
            textAvailability: .unavailable
        )
        harness.repository.textContent[item.id] = .init(text: nil, richText: nil, html: html)

        let succeeded = await harness.coordinator.pasteStandard(item: item, rich: false)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(harness.pasteboard.suppressedWriteCount, 0)
        XCTAssertEqual(harness.activator.callCount, 0)
        XCTAssertEqual(harness.notifier.notifications.first?.deduplicationKey, "html-plain-text-unavailable")
    }

    func testCurrentHtmlOnlyRichPasteSucceedsWithoutAddingEmptyPlainText() {
        let harness = TestHarness()
        let html = Data("<div>live HTML</div>".utf8)
        let snapshot = CurrentClipboardSnapshot(
            changeCount: 7,
            kind: "text",
            html: html,
            contentHash: HashUtil.sha256HTMLOnly(html)
        )

        let succeeded = harness.coordinator.pasteStandard(snapshot: snapshot, rich: true, activate: false)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(harness.pasteboard.html, html)
        XCTAssertNil(harness.pasteboard.string)
        XCTAssertEqual(harness.pasteboard.recordedItems.first?.textAvailability, .unavailable)
    }

    func testCurrentHtmlOnlyMacroRejectsBeforeRunnerAndPasteboardWrite() async {
        let harness = TestHarness()
        let html = Data("<div>live HTML</div>".utf8)
        let snapshot = CurrentClipboardSnapshot(
            changeCount: 7,
            kind: "text",
            html: html,
            contentHash: HashUtil.sha256HTMLOnly(html)
        )

        let succeeded = await harness.coordinator.runMacro(macro: makeMacro(), snapshot: snapshot)

        XCTAssertFalse(succeeded)
        let calls = await harness.macroRunner.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(harness.pasteboard.suppressedWriteCount, 0)
        XCTAssertEqual(harness.notifier.notifications.first?.deduplicationKey, "html-plain-text-unavailable")
    }

    func testCompletedOcrUsesCachedTextWithoutRecognitionOrProgress() async {
        let harness = TestHarness()
        let item = makeClipboardItem(kind: "image")
        harness.repository.ocrResults[item.id] = .init(status: "completed", text: "cached text")
        let progressEvents = BoolRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .ocrProgressDidChange,
            object: nil,
            queue: nil
        ) { note in
            if let inProgress = note.userInfo?["inProgress"] as? Bool {
                progressEvents.append(inProgress)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await harness.coordinator.runOcr(item: item)

        XCTAssertEqual(harness.pasteboard.string, "cached text")
        let ocrCallCount = await harness.ocr.callCount
        XCTAssertEqual(ocrCallCount, 0)
        XCTAssertTrue(harness.repository.ocrUpdates.isEmpty)
        XCTAssertEqual(harness.pasteboard.recordedItems.map(\.text), ["cached text"])
        XCTAssertEqual(harness.activator.callCount, 1)
        XCTAssertTrue(harness.notifier.notifications.isEmpty)
        XCTAssertTrue(progressEvents.values.isEmpty)
    }

    func testPendingOcrNotifiesWithoutWritingOrRecognition() async {
        let harness = TestHarness()
        let item = makeClipboardItem(kind: "image")
        harness.repository.ocrResults[item.id] = .init(status: "pending", text: nil)

        await harness.coordinator.runOcr(item: item)

        XCTAssertNil(harness.pasteboard.string)
        let ocrCallCount = await harness.ocr.callCount
        XCTAssertEqual(ocrCallCount, 0)
        XCTAssertEqual(harness.activator.callCount, 0)
        XCTAssertEqual(harness.notifier.notifications.map(\.deduplicationKey), ["ocr-still-running"])
    }

    func testFreshOcrRecognizesUpdatesRepositoryAndPublishesProgress() async {
        let harness = TestHarness()
        let item = makeClipboardItem(kind: "image")
        harness.repository.imageData[item.id] = Data([1, 2, 3])
        await harness.ocr.setResult("recognized text")
        let progressEvents = BoolRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .ocrProgressDidChange,
            object: nil,
            queue: nil
        ) { note in
            if let inProgress = note.userInfo?["inProgress"] as? Bool {
                progressEvents.append(inProgress)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await harness.coordinator.runOcr(item: item)

        let calls = await harness.ocr.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.imageData, Data([1, 2, 3]))
        XCTAssertEqual(calls.first?.languages, ["en-US"])
        XCTAssertEqual(harness.repository.ocrUpdates.count, 1)
        XCTAssertEqual(harness.repository.ocrUpdates.first?.id, item.id)
        XCTAssertEqual(harness.repository.ocrUpdates.first?.text, "recognized text")
        XCTAssertEqual(harness.pasteboard.string, "recognized text")
        XCTAssertEqual(harness.pasteboard.recordedItems.map(\.text), ["recognized text"])
        XCTAssertEqual(progressEvents.values, [true, false])
    }

    func testTextMacroSuccessBuildsInputWritesOutputAndActivates() async {
        let harness = TestHarness()
        let item = makeClipboardItem(kind: "text", sourceBundleID: "com.example.source")
        harness.repository.fullText[item.id] = "source text"
        await harness.macroRunner.setResponse(.success(.init(data: Data("transformed".utf8), isImage: false)))

        let succeeded = await harness.coordinator.runMacro(macro: makeMacro(), item: item)

        XCTAssertTrue(succeeded)
        let calls = await harness.macroRunner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.input.text, "source text")
        XCTAssertNil(calls.first?.input.imageData)
        XCTAssertEqual(calls.first?.input.sourceBundleID, "com.example.source")
        XCTAssertEqual(calls.first?.verifyFingerprint, true)
        XCTAssertEqual(harness.pasteboard.string, "transformed")
        XCTAssertTrue(harness.pasteboard.recordedItems.isEmpty)
        XCTAssertEqual(harness.activator.callCount, 1)
        XCTAssertTrue(harness.notifier.notifications.isEmpty)
    }

    func testCurrentTextMacroUsesSnapshotPayloadWithoutRepositoryLookup() async {
        let harness = TestHarness()
        let snapshot = makeCurrentTextSnapshot(text: "live clipboard")
        await harness.macroRunner.setResponse(.success(.init(data: Data("transformed".utf8), isImage: false)))

        let succeeded = await harness.coordinator.runMacro(macro: makeMacro(), snapshot: snapshot)

        XCTAssertTrue(succeeded)
        let calls = await harness.macroRunner.calls
        XCTAssertEqual(calls.first?.input.text, "live clipboard")
        XCTAssertEqual(calls.first?.input.sourceBundleID, "com.example.current")
        XCTAssertEqual(harness.pasteboard.string, "transformed")
        XCTAssertTrue(harness.repository.fullText.isEmpty)
        XCTAssertTrue(harness.pasteboard.recordedItems.isEmpty)
    }

    func testCurrentMacroFailureRestoresSnapshotWithoutRecordingHistory() async {
        let harness = TestHarness()
        let snapshot = makeCurrentTextSnapshot(text: "live original")
        await harness.macroRunner.setResponse(.failure(.timeout))

        let succeeded = await harness.coordinator.runMacro(macro: makeMacro(), snapshot: snapshot)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(harness.pasteboard.string, "live original")
        XCTAssertTrue(harness.pasteboard.recordedItems.isEmpty)
        XCTAssertEqual(harness.activator.callCount, 1)
    }

    func testPastingCurrentTextRecordsExactSnapshotPayload() {
        let harness = TestHarness()
        let snapshot = makeCurrentTextSnapshot(text: "live clipboard")

        let succeeded = harness.coordinator.pasteStandard(snapshot: snapshot, rich: true, activate: false)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(harness.pasteboard.string, "live clipboard")
        XCTAssertEqual(harness.pasteboard.recordedItems.map(\.text), ["live clipboard"])
        XCTAssertEqual(harness.pasteboard.recordedItems.first?.contentHash, snapshot.contentHash)
    }

    func testMacroFailureRestoresOriginalAndNotifies() async {
        let harness = TestHarness()
        let item = makeClipboardItem(kind: "text")
        harness.repository.fullText[item.id] = "source text"
        harness.repository.textContent[item.id] = .init(text: "original text", richText: nil, html: nil)
        await harness.macroRunner.setResponse(.failure(.timeout))

        let succeeded = await harness.coordinator.runMacro(macro: makeMacro(), item: item)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(harness.pasteboard.string, "original text")
        XCTAssertTrue(harness.pasteboard.recordedItems.isEmpty)
        XCTAssertEqual(harness.activator.callCount, 1)
        XCTAssertEqual(harness.notifier.notifications.count, 1)
        XCTAssertEqual(harness.notifier.notifications.first?.title, "Macro failed")
        XCTAssertEqual(harness.notifier.notifications.first?.body, "Macro script timed out.")
    }

    func testImageMacroFailureFallbackDoesNotRecordHistory() async {
        let harness = TestHarness()
        let item = makeClipboardItem(kind: "image")
        harness.repository.imageData[item.id] = Data([1, 2, 3])
        await harness.macroRunner.setResponse(.failure(.timeout))

        let succeeded = await harness.coordinator.runMacro(macro: makeMacro(), item: item)

        XCTAssertFalse(succeeded)
        XCTAssertTrue(harness.pasteboard.recordedItems.isEmpty)
        XCTAssertEqual(harness.pasteboard.suppressedWriteCount, 1)
        XCTAssertEqual(harness.activator.callCount, 1)
    }

    func testMacroDebugUsesFixedTextInputWithoutPasteSideEffects() async throws {
        let harness = TestHarness()
        let expected = MacroDebugReport(
            command: "/bin/sh /tmp/macro.sh",
            environment: ["CB_ITEM_KIND": "text"],
            terminationStatus: 0,
            timedOut: false,
            duration: 0.1,
            standardOutput: "debug output",
            standardError: "",
            standardOutputTruncated: false,
            standardErrorTruncated: false,
            output: .init(
                kind: .text,
                totalByteCount: 11,
                previewText: "transformed",
                previewByteCount: 11,
                truncated: false
            ),
            usedInputFallback: false,
            errorMessage: nil
        )
        await harness.macroRunner.setDebugResponse(expected)

        let report = try await harness.coordinator.debugMacro(
            macro: makeMacro(),
            inputText: "fixed test input"
        )

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.standardOutput, "debug output")
        let calls = await harness.macroRunner.debugCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.input.text, "fixed test input")
        XCTAssertFalse(calls.first?.input.isImage ?? true)
        XCTAssertNil(calls.first?.input.imageData)
        XCTAssertNil(calls.first?.input.sourceBundleID)
        XCTAssertEqual(calls.first?.verifyFingerprint, true)
        XCTAssertNil(harness.pasteboard.string)
        XCTAssertEqual(harness.activator.callCount, 0)
        XCTAssertTrue(harness.notifier.notifications.isEmpty)
    }

    func testCopyMacroDebugReportUsesInjectedSuppressedPasteboardWithoutOtherSideEffects() {
        let harness = TestHarness()

        harness.coordinator.copyMacroDebugReport("debug report")

        XCTAssertEqual(harness.pasteboard.string, "debug report")
        XCTAssertEqual(harness.pasteboard.suppressedWriteCount, 1)
        XCTAssertEqual(harness.activator.callCount, 0)
        XCTAssertTrue(harness.notifier.notifications.isEmpty)
    }
}

final class MacroRunnerDebugTests: XCTestCase {
    func testDebugRunCapturesTerminalStreamsAndMacroOutput() async throws {
        let script = MacroScript(
            name: "Debug",
            scriptPath: "",
            inlineScript: """
            printf 'stdout line'
            printf 'stderr line' >&2
            cat "$CB_INPUT_FILE" > "$CB_OUTPUT_FILE"
            """
        )

        let report = try await MacroRunner.debugRunAsync(
            script: script,
            input: .init(isImage: false, imageData: nil, text: "transformed text", sourceBundleID: "com.example.source"),
            verifyFingerprint: false
        )

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.terminationStatus, 0)
        XCTAssertEqual(report.standardOutput, "stdout line")
        XCTAssertEqual(report.standardError, "stderr line")
        XCTAssertEqual(report.output?.kind, .text)
        XCTAssertEqual(report.output?.previewText, "transformed text")
        XCTAssertEqual(report.output?.totalByteCount, 16)
        XCTAssertEqual(report.environment["CB_ITEM_KIND"], "text")
        XCTAssertEqual(report.environment["CB_ITEM_SOURCE"], "com.example.source")
        XCTAssertFalse(report.usedInputFallback)
    }

    func testDebugRunDrainsAndTruncatesVerboseTerminalStreams() async throws {
        let script = MacroScript(
            name: "Verbose Debug",
            scriptPath: "",
            inlineScript: """
            head -c 300000 /dev/zero | tr '\\0' x
            head -c 300000 /dev/zero | tr '\\0' y >&2
            printf 'done' > "$CB_OUTPUT_FILE"
            """
        )

        let report = try await MacroRunner.debugRunAsync(
            script: script,
            input: .init(isImage: false, imageData: nil, text: "input", sourceBundleID: nil),
            verifyFingerprint: false
        )

        XCTAssertTrue(report.succeeded)
        XCTAssertTrue(report.standardOutputTruncated)
        XCTAssertTrue(report.standardErrorTruncated)
        XCTAssertEqual(report.standardOutput.utf8.count, 256 * 1024)
        XCTAssertEqual(report.standardError.utf8.count, 256 * 1024)
    }

    func testDebugRunPreservesFailureStreamsWithoutInputFallback() async throws {
        let script = MacroScript(
            name: "Failing Debug",
            scriptPath: "",
            inlineScript: """
            printf 'failure detail' >&2
            printf 'partial output' > "$CB_OUTPUT_FILE"
            exit 7
            """
        )

        let report = try await MacroRunner.debugRunAsync(
            script: script,
            input: .init(isImage: false, imageData: nil, text: "original input", sourceBundleID: nil),
            verifyFingerprint: false
        )

        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(report.terminationStatus, 7)
        XCTAssertEqual(report.standardError, "failure detail")
        XCTAssertEqual(report.output?.previewText, "partial output")
        XCTAssertFalse(report.usedInputFallback)
        XCTAssertEqual(report.errorMessage, "Macro script exited with status 7.")
    }

    func testDebugRunDoesNotWaitForBackgroundChildHoldingPipes() async throws {
        let script = MacroScript(
            name: "Background Child",
            scriptPath: "",
            inlineScript: """
            sleep 2 &
            printf 'done' > "$CB_OUTPUT_FILE"
            """
        )

        let startedAt = Date()
        let report = try await MacroRunner.debugRunAsync(
            script: script,
            input: .init(isImage: false, imageData: nil, text: "input", sourceBundleID: nil),
            verifyFingerprint: false
        )

        XCTAssertTrue(report.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testDebugRunDoesNotDrainForeverFromBackgroundWriter() async throws {
        let script = MacroScript(
            name: "Background Writer",
            scriptPath: "",
            inlineScript: """
            (while :; do printf x; done) &
            writer=$!
            (sleep 2; kill "$writer") >/dev/null 2>&1 &
            """
        )

        let startedAt = ContinuousClock.now
        let report = try await MacroRunner.debugRunAsync(
            script: script,
            input: .init(isImage: false, imageData: nil, text: "input", sourceBundleID: nil),
            verifyFingerprint: false
        )

        XCTAssertTrue(report.succeeded)
        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(1))
    }

    func testDebugRunCapturesTerminalSuffixesAtProcessExit() async throws {
        let suffix = "END-OF-STREAM"
        let script = MacroScript(
            name: "Suffix Debug",
            scriptPath: "",
            inlineScript: """
            i=0
            while [ "$i" -lt 100 ]; do printf 'stdout-%s\\n' "$i"; printf 'stderr-%s\\n' "$i" >&2; i=$((i + 1)); done
            printf '\(suffix)'
            printf '\(suffix)' >&2
            """
        )

        for _ in 0..<10 {
            let report = try await MacroRunner.debugRunAsync(
                script: script,
                input: .init(isImage: false, imageData: nil, text: "input", sourceBundleID: nil),
                verifyFingerprint: false
            )
            XCTAssertTrue(report.standardOutput.hasSuffix(suffix))
            XCTAssertTrue(report.standardError.hasSuffix(suffix))
        }
    }

    func testDebugRunBoundsLargeSuccessfulAndFailedOutputPreviews() async throws {
        for exitStatus in [0, 9] {
            let script = MacroScript(
                name: "Large Output",
                scriptPath: "",
                inlineScript: "head -c 300000 /dev/zero | tr '\\0' x > \"$CB_OUTPUT_FILE\"; exit \(exitStatus)"
            )

            let report = try await MacroRunner.debugRunAsync(
                script: script,
                input: .init(isImage: false, imageData: nil, text: "input", sourceBundleID: nil),
                verifyFingerprint: false
            )

            XCTAssertEqual(report.output?.totalByteCount, 300_000)
            XCTAssertEqual(report.output?.previewByteCount, 256 * 1024)
            XCTAssertEqual(report.output?.previewText?.utf8.count, 256 * 1024)
            XCTAssertEqual(report.output?.truncated, true)
        }
    }

    func testDebugRunBoundsLargeOutputPreviewAfterTimeout() async throws {
        let script = MacroScript(
            name: "Large Timed Out Output",
            scriptPath: "",
            inlineScript: """
            head -c 300000 /dev/zero | tr '\\0' x > "$CB_OUTPUT_FILE"
            trap '' INT TERM
            sleep 10
            """
        )

        let report = try await MacroRunner.debugRunAsync(
            script: script,
            input: .init(isImage: false, imageData: nil, text: "input", sourceBundleID: nil),
            verifyFingerprint: false,
            timeoutSeconds: 1
        )

        XCTAssertTrue(report.timedOut)
        XCTAssertLessThan(report.duration, 3)
        XCTAssertEqual(report.output?.totalByteCount, 300_000)
        XCTAssertEqual(report.output?.previewByteCount, 256 * 1024)
        XCTAssertEqual(report.output?.truncated, true)
    }

    func testProductionRunDiscardsVerboseTerminalStreams() async throws {
        let script = MacroScript(
            name: "Verbose Production",
            scriptPath: "",
            inlineScript: """
            head -c 300000 /dev/zero
            head -c 300000 /dev/zero >&2
            printf 'done' > "$CB_OUTPUT_FILE"
            """
        )

        let output = try await MacroRunner.runAsync(
            script: script,
            input: .init(isImage: false, imageData: nil, text: "input", sourceBundleID: nil),
            verifyFingerprint: false
        )

        XCTAssertEqual(String(data: output.data, encoding: .utf8), "done")
    }

    func testDebugRunCancellationStopsProcessPromptly() async {
        let script = MacroScript(
            name: "Cancelled Debug",
            scriptPath: "",
            inlineScript: "trap '' INT TERM; while :; do :; done"
        )
        let task = Task {
            try await MacroRunner.debugRunAsync(
                script: script,
                input: .init(isImage: false, imageData: nil, text: "input", sourceBundleID: nil),
                verifyFingerprint: false
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        let startedAt = ContinuousClock.now

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(2))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

@MainActor
final class HistoryViewModelTests: XCTestCase {
    func testReloadSelectsFirstItemWhenThereIsNoSelection() async {
        let harness = TestHarness()
        let first = makeClipboardItem(kind: "text")
        let second = makeClipboardItem(kind: "text")
        harness.repository.items = [first, second]
        let viewModel = HistoryViewModel(
            repository: harness.repository,
            pasteCoordinator: harness.coordinator
        )

        await viewModel.reload()

        XCTAssertEqual(viewModel.items, [first, second])
        XCTAssertEqual(viewModel.selectedItem, first)
    }

    func testReloadPreservesSelectionByIDAndFallsBackWhenItDisappears() async {
        let harness = TestHarness()
        let first = makeClipboardItem(kind: "text")
        let selected = makeClipboardItem(kind: "text")
        harness.repository.items = [first, selected]
        let viewModel = HistoryViewModel(
            repository: harness.repository,
            pasteCoordinator: harness.coordinator
        )
        await viewModel.reload()
        viewModel.select(selected)

        harness.repository.items = [selected, first]
        await viewModel.reload()
        XCTAssertEqual(viewModel.selectedItem, selected)

        harness.repository.items = [first]
        await viewModel.reload()
        XCTAssertEqual(viewModel.selectedItem, first)
    }

    func testCurrentClipboardIsFirstAndOnlyOneMatchingHistoryItemIsHidden() async {
        let harness = TestHarness()
        let reader = CurrentClipboardReaderFake(snapshot: makeCurrentTextSnapshot(text: "current"))
        let newestMatch = makeClipboardItem(kind: "text", textPreview: "current", contentHash: reader.snapshot?.contentHash)
        let olderMatch = makeClipboardItem(kind: "text", textPreview: "older duplicate", contentHash: reader.snapshot?.contentHash)
        let previous = makeClipboardItem(kind: "text", textPreview: "previous", contentHash: "previous")
        harness.repository.items = [newestMatch, previous, olderMatch]
        let viewModel = HistoryViewModel(
            repository: harness.repository,
            pasteCoordinator: harness.coordinator,
            currentReader: reader
        )

        await viewModel.reload()
        await viewModel.refreshCurrentClipboard()

        XCTAssertTrue(viewModel.items.first?.isCurrent == true)
        XCTAssertEqual(viewModel.items.dropFirst().map(\.id), [previous.id, olderMatch.id])
        XCTAssertEqual(viewModel.historyItems, [newestMatch, previous, olderMatch])
    }

    func testCurrentSelectionFollowsClipboardWhileHistorySelectionIsPreserved() async {
        let harness = TestHarness()
        let firstSnapshot = makeCurrentTextSnapshot(text: "first", changeCount: 1)
        let reader = CurrentClipboardReaderFake(snapshot: firstSnapshot)
        let history = makeClipboardItem(kind: "text", textPreview: "history", contentHash: "history")
        harness.repository.items = [history]
        let viewModel = HistoryViewModel(
            repository: harness.repository,
            pasteCoordinator: harness.coordinator,
            currentReader: reader
        )
        await viewModel.reload()
        await viewModel.refreshCurrentClipboard()
        viewModel.select(viewModel.items.first)

        reader.snapshot = makeCurrentTextSnapshot(text: "second", changeCount: 2)
        await viewModel.refreshCurrentClipboard()

        XCTAssertTrue(viewModel.selectedItem?.isCurrent == true)
        XCTAssertEqual(viewModel.selectedItem?.textPreview, "second")

        viewModel.select(history)
        reader.snapshot = makeCurrentTextSnapshot(text: "third", changeCount: 3)
        await viewModel.refreshCurrentClipboard()

        XCTAssertEqual(viewModel.selectedItem?.id, history.id)
    }

    func testMissingCurrentClipboardFallsBackToNewestHistory() async {
        let harness = TestHarness()
        let newest = makeClipboardItem(kind: "text", textPreview: "newest")
        harness.repository.items = [newest]
        let viewModel = HistoryViewModel(
            repository: harness.repository,
            pasteCoordinator: harness.coordinator,
            currentReader: CurrentClipboardReaderFake(snapshot: nil)
        )

        await viewModel.reload()
        await viewModel.refreshCurrentClipboard()

        XCTAssertEqual(viewModel.items, [newest])
        XCTAssertEqual(viewModel.selectedItem, newest)
    }

    func testOlderObservationCannotRestoreCurrentAfterNewerConcealedObservation() async {
        let harness = TestHarness()
        let reader = CurrentClipboardReaderFake(snapshot: makeCurrentTextSnapshot(text: "visible", changeCount: 100))
        let history = makeClipboardItem(kind: "text", textPreview: "history")
        harness.repository.items = [history]
        let viewModel = HistoryViewModel(
            repository: harness.repository,
            pasteCoordinator: harness.coordinator,
            currentReader: reader
        )
        await viewModel.reload()

        reader.publish(.init(changeCount: 100, snapshot: makeCurrentTextSnapshot(text: "visible", changeCount: 100)))
        reader.publish(.init(changeCount: 101, snapshot: nil))
        reader.publish(.init(changeCount: 100, snapshot: makeCurrentTextSnapshot(text: "stale", changeCount: 100)))
        await Task.yield()

        XCTAssertNil(viewModel.currentSnapshot)
        XCTAssertEqual(viewModel.items, [history])
    }

    func testActionResolverUsesFreshCurrentForStaleTopAndPreservesOlderHistorySelection() async {
        let harness = TestHarness()
        let reader = CurrentClipboardReaderFake(snapshot: makeCurrentTextSnapshot(text: "live", changeCount: 2))
        let staleTop = makeClipboardItem(kind: "text", textPreview: "stale top", contentHash: "stale")
        let older = makeClipboardItem(kind: "text", textPreview: "older", contentHash: "older")
        harness.repository.items = [staleTop, older]
        let viewModel = HistoryViewModel(
            repository: harness.repository,
            pasteCoordinator: harness.coordinator,
            currentReader: reader
        )
        await viewModel.reload()

        let topTarget = await viewModel.resolveActionTarget(for: staleTop)
        let olderTarget = await viewModel.resolveActionTarget(for: older)

        if case .current(let snapshot) = topTarget {
            XCTAssertEqual(snapshot.text, "live")
        } else {
            XCTFail("Expected stale top to resolve to Current Clipboard")
        }
        if case .history(let item) = olderTarget {
            XCTAssertEqual(item.id, older.id)
        } else {
            XCTFail("Expected an explicitly selected older row to remain history-backed")
        }
    }

    func testCurrentImageReusesOcrCacheFromMergedHistoryItem() async throws {
        let harness = TestHarness()
        let imageData = Data([1, 2, 3])
        let hash = HashUtil.sha256Hex(of: imageData)
        let history = makeClipboardItem(kind: "image", contentHash: hash, ocrTextLowercased: "cached text")
        let snapshot = CurrentClipboardSnapshot(
            changeCount: 2,
            kind: "image",
            imageData: imageData,
            contentHash: hash
        )
        harness.repository.items = [history]
        harness.repository.ocrResults[history.id] = .init(status: "completed", text: "cached text")
        let viewModel = HistoryViewModel(
            repository: harness.repository,
            pasteCoordinator: harness.coordinator,
            currentReader: CurrentClipboardReaderFake(snapshot: snapshot)
        )
        await viewModel.reload()
        await viewModel.refreshCurrentClipboard()

        await viewModel.runOcr(item: try XCTUnwrap(viewModel.items.first))

        XCTAssertEqual(harness.pasteboard.string, "cached text")
        let ocrCallCount = await harness.ocr.callCount
        XCTAssertEqual(ocrCallCount, 0)
        XCTAssertTrue(harness.repository.ocrUpdates.isEmpty)
    }
}

final class HistoryFilterTests: XCTestCase {
    func testTextSearchIsCaseInsensitiveAndPreservesOrder() {
        let first = makeClipboardItem(kind: "text", textPreview: "Alpha")
        let second = makeClipboardItem(kind: "text", textPreview: "BRAVO")
        let third = makeClipboardItem(kind: "text", textPreview: "Bravo again")

        let result = HistoryFilter.filter(
            [first, second, third],
            query: "bravo",
            imagesOnly: false
        )

        XCTAssertEqual(result, [second, third])
    }

    func testSearchMatchesOcrBundleIdentifierAndContentHash() {
        let ocr = makeClipboardItem(kind: "image", ocrTextLowercased: "invoice total")
        let bundle = makeClipboardItem(kind: "text", sourceBundleID: "com.Example.Editor")
        let hash = makeClipboardItem(kind: "text", contentHash: "ABCDEF1234")

        XCTAssertEqual(HistoryFilter.filter([ocr, bundle, hash], query: "total", imagesOnly: false), [ocr])
        XCTAssertEqual(HistoryFilter.filter([ocr, bundle, hash], query: "example", imagesOnly: false), [bundle])
        XCTAssertEqual(HistoryFilter.filter([ocr, bundle, hash], query: "cdef", imagesOnly: false), [hash])
    }

    func testImagesOnlyCombinesWithSearchPredicate() {
        let matchingText = makeClipboardItem(kind: "text", textPreview: "Needle")
        let matchingImage = makeClipboardItem(kind: "image", ocrTextLowercased: "needle")
        let otherImage = makeClipboardItem(kind: "image", ocrTextLowercased: "other")

        XCTAssertEqual(
            HistoryFilter.filter(
                [matchingText, matchingImage, otherImage],
                query: "needle",
                imagesOnly: true
            ),
            [matchingImage]
        )
        XCTAssertEqual(
            HistoryFilter.filter(
                [matchingText, matchingImage, otherImage],
                query: "",
                imagesOnly: true
            ),
            [matchingImage, otherImage]
        )
    }
}

final class MacroScriptPathValidatorTests: XCTestCase {
    func testResolveRejectsBlankPaths() {
        XCTAssertNil(MacroScriptPathValidator.resolve(path: ""))
        XCTAssertNil(MacroScriptPathValidator.resolve(path: "  \n"))
    }

    func testDirectoryBoundaryDoesNotAcceptSiblingWithCommonPrefix() {
        let base = URL(fileURLWithPath: "/Users/example")

        XCTAssertTrue(MacroScriptPathValidator.isPath(
            url: URL(fileURLWithPath: "/Users/example/scripts/run.sh"),
            inside: base
        ))
        XCTAssertFalse(MacroScriptPathValidator.isPath(
            url: URL(fileURLWithPath: "/Users/example-other/run.sh"),
            inside: base
        ))
    }

    func testMissingPathReportsFileNotFound() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path

        let result = MacroScriptPathValidator.validate(path: path)

        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failure, .fileNotFound)
        XCTAssertFalse(result.fileExists)
    }
}

final class KeyLabelRendererTests: XCTestCase {
    func testSpecialKeySymbolsAreStable() {
        XCTAssertEqual(KeyLabelRenderer.symbol(for: 0x24), "Return")
        XCTAssertEqual(KeyLabelRenderer.symbol(for: 0x35), "Esc")
        XCTAssertEqual(KeyLabelRenderer.symbol(for: 0x7E), "↑")
    }

    func testModifierSymbolsUseConventionalOrder() {
        let modifiers = Int(
            NSEvent.ModifierFlags.command.rawValue
                | NSEvent.ModifierFlags.shift.rawValue
                | NSEvent.ModifierFlags.option.rawValue
                | NSEvent.ModifierFlags.control.rawValue
        )

        XCTAssertEqual(
            KeyLabelRenderer.displayString(keyCode: 0x7A, modifiers: modifiers),
            "⌃⌥⇧⌘F1"
        )
    }
}

@MainActor
private final class TestHarness {
    let repository = RepositoryFake()
    let settings = SettingsFake()
    let pasteboard = PasteboardSpy()
    let ocr = OcrFake()
    let macroRunner = MacroRunnerFake()
    let activator = ActivatorSpy()
    let notifier = NotifierSpy()
    let coordinator: PasteCoordinator

    init() {
        coordinator = PasteCoordinator(
            repository: repository,
            settings: settings,
            pasteboard: pasteboard,
            ocr: ocr,
            macroRunner: macroRunner,
            activator: activator,
            notifier: notifier
        )
    }
}

private final class SettingsFake: PasteCoordinatorSettings {
    var macroSameDirectoryFingerprint = true
    var needsAccessibilityForSyntheticPaste = false
    var macroFailureBehavior = "restoreOriginalAndNotify"
    var ocrLanguages = ["en-US"]
}

@MainActor
private final class RepositoryFake: ClipboardRepositoryPort, ClipboardHistoryWriting {
    var items: [ClipboardItem] = []
    var textContent: [UUID: ClipboardTextContent] = [:]
    var imageData: [UUID: Data] = [:]
    var fullText: [UUID: String] = [:]
    var ocrResults: [UUID: ClipboardOcrResult] = [:]
    var ocrUpdates: [(id: UUID, text: String?)] = []

    func fetchAll() async -> [ClipboardItem] { items }
    func fetch(id: UUID) async -> ClipboardItem? { items.first { $0.id == id } }
    func fetchTextContent(id: UUID, includeRich: Bool) async -> ClipboardTextContent? { textContent[id] }
    func fetchImageData(id: UUID) async -> Data? { imageData[id] }
    func fetchFullText(id: UUID) async -> String? { fullText[id] }
    func fetchOcrResult(id: UUID) async -> ClipboardOcrResult? { ocrResults[id] }
    func insert(_ item: NewClipboardItem, removingDuplicates: Bool, purpose: String) -> Bool { true }
    func updateOcrResult(id: UUID, text: String?) -> Bool {
        ocrUpdates.append((id, text))
        return true
    }
    func delete(id: UUID) -> Bool { true }
    func clearAll() -> Bool { true }
}

private final class PasteboardSpy: PasteboardSuppressing {
    private let pasteboard = NSPasteboard(name: .init("ClipboardManagerTests.\(UUID().uuidString)"))

    var string: String? { pasteboard.string(forType: .string) }
    var html: Data? { pasteboard.data(forType: .init("public.html")) }
    private(set) var suppressedWriteCount = 0
    private(set) var recordedItems: [NewClipboardItem] = []

    @MainActor
    func performSuppressedPasteboardWrite(_ write: (NSPasteboard) -> Void) -> Int {
        suppressedWriteCount += 1
        write(pasteboard)
        return pasteboard.changeCount
    }

    @MainActor
    func performHistoryPasteboardWrite(
        recording item: NewClipboardItem,
        _ write: (NSPasteboard) -> Void
    ) -> Int {
        recordedItems.append(item)
        return performSuppressedPasteboardWrite(write)
    }

    deinit {
        pasteboard.releaseGlobally()
    }
}

private final class CurrentClipboardReaderFake: CurrentClipboardReading, @unchecked Sendable {
    private let lock: NSLock
    private var storedSnapshot: CurrentClipboardSnapshot?
    private var handler: (@Sendable (CurrentClipboardObservation) -> Void)?

    init(snapshot: CurrentClipboardSnapshot?) {
        lock = NSLock()
        storedSnapshot = snapshot
    }

    var snapshot: CurrentClipboardSnapshot? {
        get { lock.withLock { storedSnapshot } }
        set { lock.withLock { storedSnapshot = newValue } }
    }

    func currentClipboardObservation() async -> CurrentClipboardObservation? {
        let snapshot = snapshot
        return CurrentClipboardObservation(changeCount: snapshot?.changeCount ?? 0, snapshot: snapshot)
    }

    @MainActor
    func setCurrentClipboardHandler(_ handler: @escaping @Sendable (CurrentClipboardObservation) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func publish(_ observation: CurrentClipboardObservation) {
        lock.withLock { handler }?(observation)
    }
}

private actor OcrFake: OcrRecognizing {
    struct Call: Sendable {
        let imageData: Data
        let languages: [String]
    }

    private(set) var calls: [Call] = []
    var callCount: Int { calls.count }
    private var result: String?

    func setResult(_ result: String?) {
        self.result = result
    }

    func recognizeText(in imageData: Data, languages: [String]) async -> String? {
        calls.append(.init(imageData: imageData, languages: languages))
        return result
    }
}

private actor MacroRunnerFake: MacroRunning {
    struct Call: Sendable {
        let script: MacroScript
        let input: MacroInput
        let verifyFingerprint: Bool
    }

    private(set) var calls: [Call] = []
    private(set) var debugCalls: [Call] = []
    private var response: Result<MacroOutput, MacroRunningError> = .failure(.missingScript)
    private var debugResponse = MacroDebugReport.notLaunched(
        command: "/bin/sh <test>",
        errorMessage: "No debug response configured."
    )

    func setResponse(_ response: Result<MacroOutput, MacroRunningError>) {
        self.response = response
    }

    func setDebugResponse(_ response: MacroDebugReport) {
        debugResponse = response
    }

    func runAsync(
        script: MacroScript,
        input: MacroInput,
        verifyFingerprint: Bool
    ) async throws -> MacroOutput {
        calls.append(.init(script: script, input: input, verifyFingerprint: verifyFingerprint))
        return try response.get()
    }

    func debugRunAsync(
        script: MacroScript,
        input: MacroInput,
        verifyFingerprint: Bool
    ) async throws -> MacroDebugReport {
        debugCalls.append(.init(script: script, input: input, verifyFingerprint: verifyFingerprint))
        return debugResponse
    }
}

private final class BoolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    var values: [Bool] {
        lock.withLock { storage }
    }

    func append(_ value: Bool) {
        lock.withLock { storage.append(value) }
    }
}

@MainActor
private final class ActivatorSpy: AppActivating {
    private(set) var callCount = 0

    func activatePreviousAppAndPasteSynthetically(needsSynthetic: Bool) {
        callCount += 1
    }
}

@MainActor
private final class NotifierSpy: AppNotifying {
    struct Notification {
        let title: String
        let body: String
        let deduplicationKey: String?
    }

    private(set) var notifications: [Notification] = []

    func notify(title: String, body: String, deduplicationKey: String?) {
        notifications.append(.init(
            title: title,
            body: body,
            deduplicationKey: deduplicationKey
        ))
    }
}

private func makeClipboardItem(
    kind: String,
    textPreview: String? = nil,
    sourceBundleID: String? = nil,
    contentHash: String? = nil,
    ocrTextLowercased: String? = nil,
    isHtml: Bool = false,
    textAvailability: ClipboardTextAvailability = .available
) -> ClipboardItem {
    ClipboardItem(
        id: UUID(),
        createdAt: Date(),
        kind: kind,
        textPreview: textPreview,
        textPreviewLowercased: textPreview?.lowercased(),
        isTextPreviewTruncated: false,
        textCharacterCount: nil,
        thumbnail: nil,
        isHtml: isHtml,
        textAvailability: textAvailability,
        payloadByteCount: nil,
        sourceBundleID: sourceBundleID,
        contentHash: contentHash,
        ocrTextLowercased: ocrTextLowercased
    )
}

private func makeMacro() -> MacroScript {
    MacroScript(name: "Test Macro", scriptPath: "", inlineScript: "cat")
}

private func makeCurrentTextSnapshot(text: String, changeCount: Int = 1) -> CurrentClipboardSnapshot {
    CurrentClipboardSnapshot(
        changeCount: changeCount,
        kind: "text",
        text: text,
        sourceBundleID: "com.example.current",
        contentHash: HashUtil.sha256Hex(of: Data(text.utf8))
    )
}

final class CurrentClipboardSnapshotTests: XCTestCase {
    func testSnapshotUsesStableVirtualRowIDAndKeepsFullPayloadOutOfClipboardItem() {
        let html = Data("<b>Hello</b>".utf8)
        let snapshot = CurrentClipboardSnapshot(changeCount: 42, kind: "text", text: "Hello",
            html: html, sourceBundleID: "com.example.Source", contentHash: "hash")

        let item = snapshot.clipboardItem()

        XCTAssertEqual(snapshot.id, CurrentClipboardSnapshot.currentID)
        XCTAssertEqual(item.id, CurrentClipboardSnapshot.currentID)
        XCTAssertTrue(item.isCurrent)
        XCTAssertEqual(item.textPreview, "Hello")
        XCTAssertTrue(item.isHtml)
        XCTAssertEqual(snapshot.html, html)
    }
}

@MainActor
final class ClipboardMonitorSnapshotTests: XCTestCase {
    func testSnapshotPreservesSourcePlainTextAlongsideHtml() {
        let harness = TestHarness()
        let pasteboard = NSPasteboard(name: .init("ClipboardMonitorSnapshotTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data("<ul><li>First</li><li>Second</li></ul>".utf8), forType: .init("public.html"))
        pasteboard.setString("- First\n- Second", forType: .string)
        let monitor = ClipboardMonitor(
            repository: harness.repository,
            settings: AppSettings.shared,
            automaticOcr: AutomaticOcrProcessor(repository: harness.repository),
            pasteboard: pasteboard
        )

        let snapshot = monitor.makeSnapshot(from: pasteboard, changeCount: pasteboard.changeCount)

        XCTAssertEqual(snapshot?.kind, "text")
        XCTAssertEqual(snapshot?.text, "- First\n- Second")
        XCTAssertEqual(snapshot?.html, Data("<ul><li>First</li><li>Second</li></ul>".utf8))
        XCTAssertEqual(snapshot?.contentHash, HashUtil.sha256Hex(of: Data("- First\n- Second".utf8)))
    }

    func testSnapshotKeepsHtmlWithoutParsingWhenSourceDoesNotProvidePlainText() {
        let harness = TestHarness()
        let pasteboard = NSPasteboard(name: .init("ClipboardMonitorSnapshotTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data("<b>Hello</b>".utf8), forType: .init("public.html"))
        let monitor = ClipboardMonitor(
            repository: harness.repository,
            settings: AppSettings.shared,
            automaticOcr: AutomaticOcrProcessor(repository: harness.repository),
            pasteboard: pasteboard
        )

        let snapshot = monitor.makeSnapshot(from: pasteboard, changeCount: pasteboard.changeCount)

        XCTAssertNil(snapshot?.text)
        XCTAssertEqual(snapshot?.html, Data("<b>Hello</b>".utf8))
        XCTAssertEqual(snapshot?.textAvailability, .unavailable)
        XCTAssertEqual(snapshot?.contentHash, HashUtil.sha256HTMLOnly(Data("<b>Hello</b>".utf8)))
    }

    func testCurrentObservationReusesNormalizedSnapshotForSameChangeCount() async {
        let harness = TestHarness()
        let pasteboard = NSPasteboard(name: .init("ClipboardMonitorSnapshotTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data("<b>Hello</b>".utf8), forType: .init("public.html"))
        let monitor = ClipboardMonitor(
            repository: harness.repository,
            settings: AppSettings.shared,
            automaticOcr: AutomaticOcrProcessor(repository: harness.repository),
            pasteboard: pasteboard
        )

        let first = await monitor.currentClipboardObservation()
        let second = await monitor.currentClipboardObservation()

        XCTAssertEqual(first?.changeCount, second?.changeCount)
        XCTAssertEqual(first?.snapshot?.observedAt, second?.snapshot?.observedAt)
        XCTAssertEqual(first?.snapshot?.contentHash, second?.snapshot?.contentHash)
    }

    func testSnapshotRejectsConcealedClipboard() {
        let harness = TestHarness()
        let pasteboard = NSPasteboard(name: .init("ClipboardMonitorSnapshotTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("secret", forType: .string)
        pasteboard.setString("1", forType: .init("org.nspasteboard.ConcealedType"))
        let monitor = ClipboardMonitor(
            repository: harness.repository,
            settings: AppSettings.shared,
            automaticOcr: AutomaticOcrProcessor(repository: harness.repository),
            pasteboard: pasteboard
        )

        XCTAssertNil(monitor.makeSnapshot(from: pasteboard, changeCount: pasteboard.changeCount))
    }
}

final class HtmlOnlyPresentationTests: XCTestCase {
    func testHtmlOnlyItemUsesPresentationPlaceholderWithoutPlainTextCapability() {
        let item = makeClipboardItem(
            kind: "text",
            isHtml: true,
            textAvailability: .unavailable
        )

        XCTAssertEqual(item.displayTextPreview, "HTML content (plain-text preview unavailable)")
        XCTAssertFalse(item.canUsePlainText)
    }
}
