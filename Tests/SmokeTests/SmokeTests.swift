import XCTest
import AppKit

/// XCUITest-based smoke tests for ClipboardManager.
///
/// Verification philosophy:
///   The sandboxed UI test runner cannot reach the host app's UserDefaults
///   domain via `defaults read/write`, so all assertions are made against the
///   app's GUI state (XCUIElement labels / staticTexts / popUpButton values)
///   instead of reading `defaults`. The host app is launched with
///   `CM_E2E_OPEN_WINDOW=1` so AppDelegate forces action hotkeys to known
///   defaults and opens the main + Settings windows immediately.
///
/// Test flow per case:
///   1. setUpWithError terminates any stale instances and (re)launches the
///      E2E app. AppDelegate writes the action hotkey defaults before any
///      window appears, so each test starts from a clean state.
///   2. Interact with UI elements via XCUIElement (click Clear/Reset/Record,
///      or call `typeKey(_:modifierFlags:)` to synthesize a key event).
///   3. Verify the resulting UI state (e.g. the Edit hotkey display label
///      becomes "(none)" after Clear, "⌘E" after Reset, "⇧⌘A" after Record).
///   4. Terminate the app.
///
/// Requirements:
/// - The terminal running `xcodebuild test` must have Accessibility permission
///   (System Settings → Privacy & Security → Accessibility). The first time
///   the E2E app is launched it will prompt for Accessibility permission via
///   `AXIsProcessTrustedWithOptions`; grant it once for
///   "com.xshoji.ClipboardManager.E2E". Personal Team signing keeps the team
///   id stable so subsequent runs do not need re-granting.
/// - The E2E host app shares the executable name "ClipboardManager" with the
///   production build, but its bundle id is
///   "com.xshoji.ClipboardManager.E2E". Because `UserDefaults.standard` keys
///   on the bundle identifier (not the executable name), the E2E app's
///   defaults domain is isolated from the production app. SmokeTests rely on
///   AppDelegate's `forceE2EDefaultSettings` (triggered by the
///   `CM_E2E_OPEN_WINDOW=1` launch environment) to seed a known state at
///   launch — they never read `defaults` directly. SwiftData uses a separate
///   store path guarded by the launch environment so clipboard history does
///   not collide with the production app either.
///
/// Performance notes (review follow-up):
///   Related cases were folded into single workflow tests so the app is
///   launched once per workflow instead of once per micro-assertion. Fixed
///   `Thread.sleep`s were replaced by `waitForExistence(timeout:)` wherever
///   the assertion target is an XCUIElement; the few remaining sleeps are
///   short (0.2–0.3s) SwiftUI runloop pumps that fire after a button click
///   before the next `waitForExistence` polls.
final class SmokeUITests: XCTestCase {
    private static let e2eBundleID = "com.xshoji.ClipboardManager.E2E"
    private static let productionBundleID = "com.xshoji.ClipboardManager"

    /// Short SwiftUI runloop pump used after a click before a
    /// `waitForExistence` poll. Kept small on purpose — XCUIElement's own
    /// polling handles most of the wait.
    private static let uiPump: TimeInterval = 0.2

    /// The app launched by the current test case. Held as an instance property
    /// so `tearDownWithError` can terminate it even when a test fails mid-assertion
    /// (review #6: "launched app as test case property, tearDownWithError to always
    /// terminate, wait for PID death with timeout, force terminate fallback").
    private var launchedApp: XCUIApplication?

    // MARK: - Setup / Teardown

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        Self.terminateRunningApps()
    }

    override func tearDownWithError() throws {
        // Always terminate the launched app, even when a test failed mid-assertion
        // and never reached the end-of-test `app.terminate()` call.
        if let app = launchedApp, app.state != .notRunning {
            app.terminate()
            Self.waitForProcessDeath(app: app, timeout: 5)
        }
        launchedApp = nil
        try super.tearDownWithError()
    }

    // MARK: - Tests

    func testAppLaunchesWithoutCrash() throws {
        let app = makeApp()
        app.launch()
        // Replaced the fixed 3s sleep with a fast state poll: the app is up
        // as soon as XCUIElement reports it running. Cap at 3s as a guard.
        let deadline = Date().addingTimeInterval(3)
        var running = false
        while Date() < deadline {
            if app.state == .runningForeground || app.state == .runningBackground {
                running = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(running,
                      "App did not reach running state within 3s (state=\(app.state.rawValue))")
    }

    /// Verifies the Settings form reflects the history limit defaults baked in
    /// by AppDelegate on E2E launch (retention=30 days, maxCount=1,000,
    /// maxItemSizeMB=10). Persistence across relaunch cannot be exercised
    /// because the sandboxed test runner cannot read the host app's defaults
    /// domain; this test is the GUI-state surrogate.
    func testHistorySettingsReflectInUI() throws {
        let app = makeApp()
        app.launch()
        let settingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window did not appear on launch")

        // SwiftUI Form Pickers render as NSPopUpButton on macOS; the selected
        // item's label is exposed via the popUpButton's `value`.
        let retentionPopUp = app.popUpButtons.element(boundBy: 0)
        XCTAssertTrue(retentionPopUp.waitForExistence(timeout: 5), "Retention picker not found")
        XCTAssertEqual(try XCTUnwrap(retentionPopUp.value as? String), "30 days",
                       "Retention picker did not show '30 days'")

        let maxItemsPopUp = app.popUpButtons.element(boundBy: 1)
        XCTAssertTrue(maxItemsPopUp.waitForExistence(timeout: 5), "Max items picker not found")
        XCTAssertEqual(try XCTUnwrap(maxItemsPopUp.value as? String), "1,000",
                       "Max items picker did not show '1,000'")

        // Max item size is a Stepper with label text "Max item size: 10 MB".
        // SwiftUI on macOS exposes the rendered Text content as the
        // staticText's *value* (not its `label`) when the Text is standalone,
        // while Text used as the label of a Label/Picker shows up under
        // `label`. The Stepper here renders "Max item size: 10 MB" as a plain
        // Text, so the string is in `value` and `label` is empty. Query both
        // attributes so the match is reliable regardless of which slot
        // SwiftUI populates. We wait for the staticText to exist (failing the
        // test if it never shows up) instead of silently skipping — a missing
        // label means the Stepper is gone or renamed, which is a regression.
        let maxItemText = app.staticTexts.matching(
            NSPredicate(
                format: "(label CONTAINS 'Max item size' OR label CONTAINS '10 MB' OR value CONTAINS 'Max item size' OR value CONTAINS '10 MB')"
            )
        ).firstMatch
        XCTAssertTrue(
            maxItemText.waitForExistence(timeout: 5),
            "Max item size staticText not found; dumping app tree:\n\(app.debugDescription)"
        )
        let maxItemContent = maxItemText.label.isEmpty ? (maxItemText.value as? String ?? "") : maxItemText.label
        XCTAssertTrue(
            maxItemContent.contains("10"),
            "Max item size did not show '10 MB', got '\(maxItemContent)'"
        )
    }

    /// Exercises the action hotkey recorder end-to-end in a single session
    /// (Clear → Reset → Record). Folding the three former micro-tests into
    /// one avoids two extra app launches and two extra setUp/tearDown cycles.
    /// Each step asserts the resulting display label so the order is strict.
    func testActionHotkeyWorkflow() throws {
        let app = makeApp()
        app.launch()
        let settingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window did not appear on launch")

        let display = app.staticTexts["action.edit.display"]

        // Step 1: Clear the Edit hotkey (default ⌘E) → "(none)".
        let clearButton = app.buttons["action.edit.clear"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 10), "Edit Clear button not found")
        clearButton.click()
        Thread.sleep(forTimeInterval: Self.uiPump)
        XCTAssertTrue(display.waitForExistence(timeout: 5), "Display label not found after Clear")
        XCTAssertEqual(display.value as? String ?? "", "(none)",
                       "Edit hotkey display should be '(none)' after Clear, got '\(display.value as? String ?? "")'")

        // Step 2: Reset the Edit hotkey → "⌘E".
        // After Clear, the Clear button is conditionally hidden (keyCode/mof==0);
        // the Reset button remains visible.
        let resetButton = app.buttons["action.edit.reset"]
        XCTAssertTrue(resetButton.waitForExistence(timeout: 5), "Edit Reset button not found")
        resetButton.click()
        Thread.sleep(forTimeInterval: Self.uiPump)
        XCTAssertEqual(display.value as? String ?? "", "⌘E",
                       "Edit hotkey display should be '⌘E' after Reset, got '\(display.value as? String ?? "")'")

        // Step 3: Record ⇧⌘A via XCUIElement's `typeKey(_:modifierFlags:)`,
        // which sends a real key event with the specified modifiers,
        // sidestepping the System Events / AppleScript path that the sandboxed
        // UI test runner cannot use.
        let recordButton = app.buttons["action.edit.record"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 5), "Edit Record button not found")
        recordButton.click()
        // CaptureKeyView needs to become first responder before the synthetic
        // key event lands. 0.3s is enough on local runners; the previous 1.0s
        // was overcautious. If Record intermittently fails on a slow machine
        // this is the knob to bump first.
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("a", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: Self.uiPump)
        XCTAssertEqual(display.value as? String ?? "", "⇧⌘A",
                       "Edit hotkey display should be '⇧⌘A' after Record, got '\(display.value as? String ?? "")'")
    }

    /// Exercises the macro script CRUD pipeline end-to-end in a single session:
    /// Add → Edit name → Clear-close guard → Change interpreter preset →
    /// Script-file source. The app is launched once for the whole workflow
    /// instead of once per sub-case, drastically cutting total runtime
    /// (previously 5 launches × setUp/tearDown taxed the E2E harness).
    func testMacroScriptWorkflow() throws {
        let app = makeApp()
        app.launch()
        let settingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window did not appear on launch")

        // Sanity: no macros on launch (forceE2EDefaultSettings clears them).
        let emptyLabel = app.staticTexts["macro.empty"]
        XCTAssertTrue(emptyLabel.waitForExistence(timeout: 5), "Macro empty-state label not found")

        // --- Step 1: Add Macro ---
        let addButton = app.buttons["macro.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Add Macro button not found")
        addButton.click()
        Thread.sleep(forTimeInterval: Self.uiPump)

        // The first row's controls live under the "macro.0" prefix.
        let nameField = app.textFields["macro.0.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Macro row name field not found after Add")
        nameField.click()
        Thread.sleep(forTimeInterval: Self.uiPump)

        // Touch the name to mark the row dirty (otherwise Save stays disabled
        // even though canApply is technically true, because `hasContentChanges`
        // compares against the macro model and the seed values are identical
        // until the user types). We append a character so the text binding
        // fires `onChange`.
        nameField.typeText("X")
        Thread.sleep(forTimeInterval: Self.uiPump)

        let saveButton = app.buttons["macro.0.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3), "Macro Save button not found")
        XCTAssertTrue(saveButton.isEnabled, "Macro Save should be enabled after editing the name")
        saveButton.click()
        Thread.sleep(forTimeInterval: Self.uiPump)

        // Registration confirmation dialog (per design-implementation.md §5.1-1).
        let confirmSave = app.buttons["macro.0.confirm.save"]
        XCTAssertTrue(confirmSave.waitForExistence(timeout: 5), "Confirm-Save button not found")
        confirmSave.click()
        Thread.sleep(forTimeInterval: 0.3)

        // The fingerprint-captured badge shows only on inline-script macros
        // once the user confirms the registration dialog (see MacroScriptRowView.confirmSave).
        let badge = app.staticTexts["macro.0.fingerprintCaptured"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "Fingerprint-captured badge not shown after Save")
        XCTAssertFalse(app.staticTexts["macro.empty"].exists,
                       "Empty-state label should disappear once a macro is registered")

        // After registration, the row model is republished and the name field
        // reflects the persisted value (name should end with "X" since the
        // seed input was "New Macro" + "X").
        let nameAfterSeed = try XCTUnwrap(nameField.value as? String)
        XCTAssertTrue(nameAfterSeed.hasSuffix("X"),
                      "Name should reflect seeded edit after registration, got '\(nameAfterSeed)'")

        // --- Step 2: Edit the macro name in place ---
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText("Edited Macro")
        Thread.sleep(forTimeInterval: Self.uiPump)

        let saveButtonEdit = app.buttons["macro.0.save"]
        XCTAssertTrue(saveButtonEdit.isEnabled, "Macro Save should be enabled after editing the name")
        saveButtonEdit.click()
        let confirmSaveEdit = app.buttons["macro.0.confirm.save"]
        XCTAssertTrue(confirmSaveEdit.waitForExistence(timeout: 5), "Confirm-Save button not found (edit)")
        confirmSaveEdit.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Assert the persisted name is the new one.
        let finalName = try XCTUnwrap(nameField.value as? String)
        XCTAssertEqual(finalName, "Edited Macro",
                       "Macro name should be 'Edited Macro' after editing, got '\(finalName)'")

        // --- Step 3: Switch the interpreter preset /bin/sh → /bin/bash ---
        let presetPopUp = app.popUpButtons["macro.0.interpreterPreset"]
        XCTAssertTrue(presetPopUp.waitForExistence(timeout: 5), "Interpreter preset popUp not found")
        let seedPreset = try XCTUnwrap(presetPopUp.value as? String)
        XCTAssertEqual(seedPreset, "/bin/sh",
                       "Seeded interpreter preset should be '/bin/sh', got '\(seedPreset)'")
        presetPopUp.click()
        Thread.sleep(forTimeInterval: Self.uiPump)
        let bashMenuItem = app.menuItems["/bin/bash"]
        XCTAssertTrue(bashMenuItem.waitForExistence(timeout: 3), "/bin/bash menu item not found")
        bashMenuItem.click()
        Thread.sleep(forTimeInterval: Self.uiPump)

        // The preset change immediately writes `interpreter = "/bin/bash"`
        // (`onChange(of: interpreterPreset)`), and the row's dirty flag flips
        // because interpreter now differs from the macro model. Save → confirm.
        XCTAssertTrue(saveButtonEdit.isEnabled, "Macro Save should be enabled after changing interpreter preset")
        saveButtonEdit.click()
        XCTAssertTrue(confirmSaveEdit.waitForExistence(timeout: 5), "Confirm-Save button not found (preset)")
        confirmSaveEdit.click()
        Thread.sleep(forTimeInterval: 0.3)

        let finalPreset = try XCTUnwrap(app.popUpButtons["macro.0.interpreterPreset"].value as? String)
        XCTAssertEqual(finalPreset, "/bin/bash",
                       "Interpreter preset should be '/bin/bash' after preset change, got '\(finalPreset)'")

        // --- Step 4: Unsaved-changes guard on close ---
        // Edit the name WITHOUT clicking Save so the row stays dirty, then
        // attempt to close the Settings window; the "Unsaved Macro Changes"
        // NSAlert must appear, and Cancel must keep the window open with the
        // unsaved edit intact.
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText("UnsavedEdit")
        Thread.sleep(forTimeInterval: Self.uiPump)
        let bufferedName = try XCTUnwrap(nameField.value as? String)
        XCTAssertTrue(bufferedName.hasSuffix("UnsavedEdit"),
                      "Name field should show unsaved edit, got '\(bufferedName)'")

        // Trigger the close. SettingsWindowController.windowShouldClose runs
        // the NSAlert. The Settings window's traffic-light close button is
        // the leftmost (boundBy: 0).
        let closeButton = settingsWindow.buttons.element(boundBy: 0)
        XCTAssertTrue(closeButton.exists, "Settings window close button not found")
        closeButton.click()
        Thread.sleep(forTimeInterval: 0.3)

        let unsavedAlert = app.dialogs.element(boundBy: 0)
        XCTAssertTrue(unsavedAlert.waitForExistence(timeout: 5),
                      "Unsaved-changes alert did not appear on close; dumping tree:\n\(app.debugDescription)")
        let cancelButton = unsavedAlert.buttons["Cancel"]
        XCTAssertTrue(cancelButton.exists, "Cancel button not found on unsaved-changes alert")
        cancelButton.click()
        Thread.sleep(forTimeInterval: Self.uiPump)

        XCTAssertTrue(settingsWindow.exists,
                      "Settings window should still be open after Canceling the unsaved-changes alert")
        XCTAssertFalse(app.dialogs.element(boundBy: 0).exists,
                       "Unsaved-changes alert should be dismissed after Cancel")

        // The unsaved edit must still be intact in the name field — the
        // Cancel path did NOT commit the change.
        let nameAfterCancel = try XCTUnwrap(app.textFields["macro.0.name"].value as? String)
        XCTAssertTrue(nameAfterCancel.hasSuffix("UnsavedEdit"),
                      "Unsaved edit should be preserved after Canceling the alert, got '\(nameAfterCancel)'")

        // --- Step 5: Switch to Script-file source with a real script ---
        // Create a real, executable shell script file under a dedicated
        // E2E directory in the user's home. MacroScriptPathValidator rejects
        // paths outside $HOME (`.outsideHome`) and non-existent files
        // (`.fileNotFound`), so we need an in-home, on-disk file. The
        // temporary directory provided by `NSTemporaryDirectory()` is
        // usually outside $HOME on macOS (`/var/folders/...`), so we use
        // `~/.ClipboardManagerE2E/` instead.
        //
        // To avoid clobbering a pre-existing user file (review #2): the
        // directory and script use a UUID-derived unique name, we abort the
        // test if the target path already exists before writing, and the
        // `defer` only removes the exact URL this test created (it does not
        // touch anything the user may have placed under that directory).
        let home = NSHomeDirectory()
        let e2eDir = (home as NSString)
            .appendingPathComponent(".ClipboardManagerE2E")
        let scriptName = "macro-\(UUID().uuidString).sh"
        let scriptURL = URL(fileURLWithPath: e2eDir, isDirectory: true)
            .appendingPathComponent(scriptName, isDirectory: false)
        let scriptPath = scriptURL.path
        let scriptBody = "#!/bin/sh\necho hi > \"$CB_OUTPUT_FILE\"\n"
        do {
            // Refuse to overwrite an existing file: a fresh UUID collision is
            // astronomically unlikely, so an existing file means something else
            // owns that path and we must not destroy it.
            if FileManager.default.fileExists(atPath: scriptPath) {
                throw NSError(
                    domain: "SmokeUITests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Refusing to overwrite existing file at \(scriptPath)"]
                )
            }
            try FileManager.default.createDirectory(
                atPath: e2eDir,
                withIntermediateDirectories: true
            )
            try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
            // Best-effort chmod; non-executable file still passes path
            // validation (only `fileExists`, not `isExecutable`) but we set
            // the bit anyway so the test exercises a realistic file.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: scriptPath)
        }
        defer {
            // Remove only the file this test created. We intentionally do NOT
            // remove the `~/.ClipboardManagerE2E/` directory itself or any
            // other paths under it — those may belong to the user or to other
            // test runs.
            try? FileManager.default.removeItem(at: scriptURL)
        }

        // Switch the source type from "Inline shell" to "Script file".
        let sourceTypeGroup = app.radioGroups["macro.0.sourceType"]
        XCTAssertTrue(sourceTypeGroup.waitForExistence(timeout: 5),
                      "Source type radio group not found; dumping tree:\n\(app.debugDescription)")
        let scriptFileRadio = sourceTypeGroup.radioButtons["Script file"]
        XCTAssertTrue(scriptFileRadio.waitForExistence(timeout: 3), "'Script file' radio button not found")
        scriptFileRadio.click()
        Thread.sleep(forTimeInterval: Self.uiPump)

        // Now the inline editor is hidden and the path TextField + Browse
        // button are shown. Enter the absolute path to the home script.
        let pathField = app.textFields["macro.0.path"]
        XCTAssertTrue(pathField.waitForExistence(timeout: 5), "Path TextField not found after switching to Script file")
        pathField.click()
        Thread.sleep(forTimeInterval: Self.uiPump)
        pathField.typeText(scriptPath)
        Thread.sleep(forTimeInterval: Self.uiPump)

        // Save the edit; the confirmation dialog appears because the
        // file-mode fingerprint is captured at confirm-save time too.
        XCTAssertTrue(saveButtonEdit.waitForExistence(timeout: 3), "Macro Save button not found (file)")
        XCTAssertTrue(saveButtonEdit.isEnabled, "Macro Save should be enabled after entering the path")
        saveButtonEdit.click()
        XCTAssertTrue(confirmSaveEdit.waitForExistence(timeout: 5), "Confirm-Save button not found (file)")
        confirmSaveEdit.click()
        Thread.sleep(forTimeInterval: 0.3)

        // The path field should reflect the persisted (resolved) path. The
        // validator resolves symlinks but the absolute path under $HOME
        // should be a prefix-equal match (no symlinks involved on a normal
        // home dir).
        let persistedPath = try XCTUnwrap(app.textFields["macro.0.path"].value as? String)
        XCTAssertEqual(persistedPath, scriptPath,
                       "Persisted path should match what we typed, got '\(persistedPath)'")

        // File-mode macros don't show the fingerprint-captured badge — only
        // inline-mode ones do. Assert the badge is absent to lock this
        // behavior (regression guard against accidentally re-routing file
        // mode through the inline badge path).
        XCTAssertFalse(app.staticTexts["macro.0.fingerprintCaptured"].exists,
                       "Fingerprint-captured badge should NOT appear for file-mode macros")
        XCTAssertFalse(app.staticTexts["macro.0.validationError"].exists,
                       "Validation error label should NOT appear after successful file-mode save")
    }

    // MARK: - App Launcher

    /// Builds an XCUIApplication preconfigured with the E2E bundle id and the
    /// `CM_E2E_OPEN_WINDOW=1` launch environment so AppDelegate forces the
    /// action hotkey defaults, prompts for Accessibility, and opens the main
    /// window and the Settings window immediately on launch.
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Self.e2eBundleID)
        app.launchEnvironment["CM_E2E_OPEN_WINDOW"] = "1"
        launchedApp = app
        return app
    }

    // MARK: - Shell Helpers

    private static func terminateRunningApps() {
        for bid in [productionBundleID, e2eBundleID] {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            guard !apps.isEmpty else { continue }
            Self.log("Terminating \(apps.count) running app instance(s) for \(bid)")
            for app in apps {
                app.terminate()
                waitForProcessDeath(runningApp: app, timeout: 5)
            }
        }
    }

    /// Waits for the launched XCUIApplication to reach `.notRunning` state, with
    /// a timeout. If the app does not exit gracefully within the timeout, forces
    /// termination via `NSRunningApplication.forceTerminate()` (SIGKILL equivalent).
    private static func waitForProcessDeath(app: XCUIApplication, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.state == .notRunning { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        // Graceful terminate did not work; force-kill all running instances of
        // the E2E bundle id. XCUIApplication does not expose processID, so we
        // match via NSRunningApplication instead.
        Self.log("App did not exit within \(timeout)s, force-terminating E2E instances")
        for runningApp in NSRunningApplication.runningApplications(withBundleIdentifier: e2eBundleID) {
            runningApp.forceTerminate()
        }
    }

    /// Waits for an NSRunningApplication to terminate, with timeout and SIGKILL
    /// fallback. Used by `terminateRunningApps()` in `setUpWithError` to ensure
    /// stale instances from a previous failed test run are dead before launching
    /// a new instance.
    private static func waitForProcessDeath(runningApp: NSRunningApplication, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runningApp.isTerminated { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        Self.log("Running app did not terminate within \(timeout)s, force-terminating (pid=\(runningApp.processIdentifier))")
        runningApp.forceTerminate()
    }

    // MARK: - Logging

    private static func log(_ msg: String) {
        FileHandle.standardError.write("[SmokeUITests] \(msg)\n".data(using: .utf8)!)
    }
}
