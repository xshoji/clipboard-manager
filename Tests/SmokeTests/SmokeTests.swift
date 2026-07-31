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
        XCTAssertTrue(exists(settingsWindow, timeout: 10), "Settings window did not appear on launch")

        // SwiftUI Form Pickers render as NSPopUpButton on macOS; the selected
        // item's label is exposed via the popUpButton's `value`.
        let retentionPopUp = app.popUpButtons.element(boundBy: 0)
        XCTAssertTrue(exists(retentionPopUp, timeout: 5), "Retention picker not found")
        XCTAssertEqual(try XCTUnwrap(retentionPopUp.value as? String), "30 days",
                       "Retention picker did not show '30 days'")

        let maxItemsPopUp = app.popUpButtons.element(boundBy: 1)
        XCTAssertTrue(exists(maxItemsPopUp, timeout: 5), "Max items picker not found")
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
            exists(maxItemText, timeout: 5),
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
        XCTAssertTrue(exists(settingsWindow, timeout: 10), "Settings window did not appear on launch")

        let display = app.staticTexts["action.edit.display"]

        // Step 1: Clear the Edit hotkey (default ⌘E) → "(none)".
        let clearButton = app.buttons["action.edit.clear"]
        XCTAssertTrue(exists(clearButton, timeout: 10), "Edit Clear button not found")
        clearButton.click()
        Thread.sleep(forTimeInterval: Self.uiPump)
        XCTAssertTrue(exists(display, timeout: 5), "Display label not found after Clear")
        XCTAssertEqual(display.value as? String ?? "", "(none)",
                       "Edit hotkey display should be '(none)' after Clear, got '\(display.value as? String ?? "")'")

        // Step 2: Reset the Edit hotkey → "⌘E".
        // After Clear, the Clear button is conditionally hidden (keyCode/mof==0);
        // the Reset button remains visible.
        let resetButton = app.buttons["action.edit.reset"]
        XCTAssertTrue(exists(resetButton, timeout: 5), "Edit Reset button not found")
        resetButton.click()
        Thread.sleep(forTimeInterval: Self.uiPump)
        XCTAssertEqual(display.value as? String ?? "", "⌘E",
                       "Edit hotkey display should be '⌘E' after Reset, got '\(display.value as? String ?? "")'")

        // Step 3: Record ⇧⌘A via XCUIElement's `typeKey(_:modifierFlags:)`,
        // which sends a real key event with the specified modifiers,
        // sidestepping the System Events / AppleScript path that the sandboxed
        // UI test runner cannot use.
        let recordButton = app.buttons["action.edit.record"]
        XCTAssertTrue(exists(recordButton, timeout: 5), "Edit Record button not found")
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

    /// Exercises the second global hotkey recorder (Record → Clear) and verifies
    /// the default state is "(none)" because the shortcut is optional.
    func testGlobalMacroPickerHotkeyRecorder() throws {
        let app = makeApp()
        app.launch()
        let settingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(exists(settingsWindow, timeout: 10), "Settings window did not appear on launch")

        let display = app.staticTexts["globalMacroPickerHotkey.display"]
        XCTAssertTrue(exists(display, timeout: 5), "Global macro picker hotkey display not found")
        XCTAssertEqual(display.value as? String ?? "", "(none)",
                       "Global macro picker hotkey should default to '(none)', got '\(display.value as? String ?? "")'")

        // Escape cancels recording without changing the current shortcut.
        let recordButton = app.buttons["globalMacroPickerHotkey.record"]
        XCTAssertTrue(exists(recordButton, timeout: 5), "Record button not found")
        recordButton.click()
        Thread.sleep(forTimeInterval: Self.uiPump)
        XCTAssertEqual(app.buttons["globalMacroPickerHotkey.record"].label, "Cancel",
                       "Record button should become Cancel while recording")
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: Self.uiPump)
        XCTAssertEqual(app.buttons["globalMacroPickerHotkey.record"].label, "Record",
                       "Escape should cancel hotkey recording")
        XCTAssertEqual(app.staticTexts["globalMacroPickerHotkey.display"].value as? String ?? "", "(none)",
                       "Cancelling should preserve the current hotkey")

        // Record ⇧⌘A; unlikely to collide with the E2E main-hotkey defaults.
        app.buttons["globalMacroPickerHotkey.record"].click()
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("a", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: Self.uiPump)
        XCTAssertEqual(display.value as? String ?? "", "⇧⌘A",
                       "Display should be '⇧⌘A' after Record, got '\(display.value as? String ?? "")'")

        // Clear → back to "(none)".
        let clearButton = app.buttons["globalMacroPickerHotkey.clear"]
        XCTAssertTrue(exists(clearButton, timeout: 5), "Clear button not found")
        clearButton.click()
        Thread.sleep(forTimeInterval: Self.uiPump)
        XCTAssertEqual(display.value as? String ?? "", "(none)",
                       "Display should be '(none)' after Clear, got '\(display.value as? String ?? "")'")
    }

    /// Verifies that the Carbon duplicate guard rejects setting the second
    /// global hotkey to the same shortcut as the main global hotkey.
    /// The main hotkey is first changed to a single-modifier shortcut (⌘B)
    /// so XCUITest can reliably synthesize the collision without depending on
    /// the four-modifier E2E default or on window-scoped action hotkeys.
    func testGlobalMacroPickerHotkeyCollidesWithMainHotkey() throws {
        let app = makeApp()
        app.launch()
        let settingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(exists(settingsWindow, timeout: 10), "Settings window did not appear on launch")

        // Step 1: Change the main global hotkey to ⌘B.
        // ⌘B does not collide with any E2E default action hotkey (Edit ⌘E,
        // Paste Plain ⌘P, Macro Picker ⌘M).
        let mainRecord = app.buttons["globalHotkey.record"]
        XCTAssertTrue(exists(mainRecord, timeout: 5), "Main hotkey Record button not found")
        mainRecord.click()
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("b", modifierFlags: .command)
        Thread.sleep(forTimeInterval: Self.uiPump)

        let mainDisplay = app.staticTexts["globalHotkey.display"]
        XCTAssertTrue(exists(mainDisplay, timeout: 5), "Main hotkey display not found")
        XCTAssertEqual(mainDisplay.value as? String ?? "", "⌘B",
                       "Main hotkey should be '⌘B', got '\(mainDisplay.value as? String ?? "")'")

        // Step 2: Record the same ⌘B on the second global hotkey.
        // Carbon should reject it because the main hotkey already owns it.
        let display = app.staticTexts["globalMacroPickerHotkey.display"]
        XCTAssertTrue(exists(display, timeout: 5), "Global macro picker hotkey display not found")
        XCTAssertEqual(display.value as? String ?? "", "(none)",
                       "Global macro picker hotkey should default to '(none)', got '\(display.value as? String ?? "")'")

        let recordButton = app.buttons["globalMacroPickerHotkey.record"]
        XCTAssertTrue(exists(recordButton, timeout: 5), "Record button not found")
        recordButton.click()
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("b", modifierFlags: .command)
        Thread.sleep(forTimeInterval: Self.uiPump)

        // SwiftUI exposes a macOS Alert as a Sheet whose title is a child
        // StaticText value, not as a titled XCUIElementTypeAlert. Match the
        // title value exactly so the unrelated action-duplicate alert cannot pass.
        let alertTitle = app.staticTexts.matching(
            NSPredicate(format: "value == %@", "Hotkey unavailable")
        ).firstMatch
        XCTAssertTrue(exists(alertTitle, timeout: 5), "Hotkey-unavailable alert did not appear")
        let okButton = app.sheets.firstMatch.buttons["OK"]
        XCTAssertTrue(exists(okButton, timeout: 5), "OK button not found in alert")
        okButton.click()
        Thread.sleep(forTimeInterval: Self.uiPump)

        let revertedDisplay = app.staticTexts["globalMacroPickerHotkey.display"]
        XCTAssertEqual(revertedDisplay.value as? String ?? "", "(none)",
                       "Display should revert to '(none)' after failed registration, got '\(revertedDisplay.value as? String ?? "")'")
    }

    /// Exercises the macro script CRUD pipeline end-to-end in a single session:
    /// Add → Edit name → Discard-close guard (reopen and verify discard) →
    /// Change interpreter preset → Script-file source. The app is launched
    /// once for the whole workflow instead of once per sub-case, drastically
    /// cutting total runtime (previously 5 launches × setUp/tearDown taxed the
    /// E2E harness).
    func testMacroScriptWorkflow() throws {
        let app = makeApp()
        app.launch()
        let settingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(exists(settingsWindow, timeout: 10), "Settings window did not appear on launch")

        // Sanity: no macros on launch (forceE2EDefaultSettings clears them).
        let emptyLabel = app.staticTexts["macro.empty"]
        XCTAssertTrue(exists(emptyLabel, timeout: 5), "Macro empty-state label not found")

        // --- Step 1: Add Macro ---
        let addButton = app.buttons["macro.add"]
        XCTAssertTrue(exists(addButton, timeout: 5), "Add Macro button not found")
        addButton.click()
        Thread.sleep(forTimeInterval: Self.uiPump)

        // The first row's controls live under the "macro.0" prefix.
        let nameField = app.textFields["macro.0.name"]
        XCTAssertTrue(exists(nameField, timeout: 5), "Macro row name field not found after Add")
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
        XCTAssertTrue(exists(saveButton, timeout: 3), "Macro Save button not found")
        XCTAssertTrue(saveButton.isEnabled, "Macro Save should be enabled after editing the name")
        saveButton.click()
        Thread.sleep(forTimeInterval: Self.uiPump)

        // Registration confirmation dialog (per design-implementation.md §5.1-1).
        let confirmSave = app.buttons["macro.0.confirm.save"]
        XCTAssertTrue(exists(confirmSave, timeout: 5), "Confirm-Save button not found")
        confirmSave.click()
        Thread.sleep(forTimeInterval: 0.3)

        // The fingerprint-captured badge shows only on inline-script macros
        // once the user confirms the registration dialog (see MacroScriptRowView.confirmSave).
        let badge = app.staticTexts["macro.0.fingerprintCaptured"]
        XCTAssertTrue(exists(badge, timeout: 5), "Fingerprint-captured badge not shown after Save")
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
        XCTAssertTrue(exists(confirmSaveEdit, timeout: 5), "Confirm-Save button not found (edit)")
        confirmSaveEdit.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Assert the persisted name is the new one.
        let finalName = try XCTUnwrap(nameField.value as? String)
        XCTAssertEqual(finalName, "Edited Macro",
                       "Macro name should be 'Edited Macro' after editing, got '\(finalName)'")

        // --- Step 3: Switch the interpreter preset /bin/sh → /bin/bash ---
        let presetPopUp = app.popUpButtons["macro.0.interpreterPreset"]
        XCTAssertTrue(exists(presetPopUp, timeout: 5), "Interpreter preset popUp not found")
        let seedPreset = try XCTUnwrap(presetPopUp.value as? String)
        XCTAssertEqual(seedPreset, "/bin/sh",
                       "Seeded interpreter preset should be '/bin/sh', got '\(seedPreset)'")
        presetPopUp.click()
        Thread.sleep(forTimeInterval: Self.uiPump)
        let bashMenuItem = app.menuItems["/bin/bash"]
        XCTAssertTrue(exists(bashMenuItem, timeout: 3), "/bin/bash menu item not found")
        bashMenuItem.click()
        Thread.sleep(forTimeInterval: Self.uiPump)

        // The preset change immediately writes `interpreter = "/bin/bash"`
        // (`onChange(of: interpreterPreset)`), and the row's dirty flag flips
        // because interpreter now differs from the macro model. Save → confirm.
        XCTAssertTrue(saveButtonEdit.isEnabled, "Macro Save should be enabled after changing interpreter preset")
        saveButtonEdit.click()
        XCTAssertTrue(exists(confirmSaveEdit, timeout: 5), "Confirm-Save button not found (preset)")
        confirmSaveEdit.click()
        Thread.sleep(forTimeInterval: 0.3)

        let finalPreset = try XCTUnwrap(app.popUpButtons["macro.0.interpreterPreset"].value as? String)
        XCTAssertEqual(finalPreset, "/bin/bash",
                       "Interpreter preset should be '/bin/bash' after preset change, got '\(finalPreset)'")

        // --- Step 4: Discard unsaved changes on close ---
        // Edit the name WITHOUT clicking Save so the row stays dirty, then
        // close the Settings window and choose "Discard" in the alert. The
        // unsaved edit must be thrown away, so reopening Settings must show
        // the last committed name ("Edited Macro") instead of the edited text.
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
        XCTAssertTrue(exists(unsavedAlert, timeout: 5),
                      "Unsaved-changes alert did not appear on close; dumping tree:\n\(app.debugDescription)")
        let discardButton = unsavedAlert.buttons["Discard"]
        XCTAssertTrue(discardButton.exists, "Discard button not found on unsaved-changes alert")
        discardButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertFalse(settingsWindow.exists,
                       "Settings window should be closed after Discard")
        XCTAssertFalse(app.dialogs.element(boundBy: 0).exists,
                       "Unsaved-changes alert should be dismissed after Discard")

        // Reopen Settings from the main window's HeaderBar gear button.
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(exists(mainWindow, timeout: 5),
                      "Main window should remain open after Settings closes")
        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(exists(settingsButton, timeout: 5),
                      "Settings button not found on main window")
        settingsButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        let reopenedSettingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(exists(reopenedSettingsWindow, timeout: 10),
                      "Settings window should reopen after clicking the settings button")

        // The macro row should still exist and show the last-saved name, not
        // the discarded "UnsavedEdit" suffix.
        let nameFieldAfterReopen = app.textFields["macro.0.name"]
        XCTAssertTrue(exists(nameFieldAfterReopen, timeout: 5),
                      "Macro row name field not found after reopening Settings")
        let nameAfterDiscard = try XCTUnwrap(nameFieldAfterReopen.value as? String)
        XCTAssertEqual(nameAfterDiscard, "Edited Macro",
                       "Discarded macro name edit should not persist; expected 'Edited Macro', got '\(nameAfterDiscard)'")

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
        // Keep the path short because XCUITest types it one character at a
        // time. A 12-hex suffix is ample for a local test, and the explicit
        // collision check below still prevents overwriting an existing file.
        let scriptName = "m-\(UUID().uuidString.prefix(12)).sh"
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
        XCTAssertTrue(exists(sourceTypeGroup, timeout: 5),
                      "Source type radio group not found; dumping tree:\n\(app.debugDescription)")
        let scriptFileRadio = sourceTypeGroup.radioButtons["Script file"]
        XCTAssertTrue(exists(scriptFileRadio, timeout: 3), "'Script file' radio button not found")
        scriptFileRadio.click()
        Thread.sleep(forTimeInterval: Self.uiPump)

        // Now the inline editor is hidden and the path TextField + Browse
        // button are shown. Enter the absolute path to the home script.
        let pathField = app.textFields["macro.0.path"]
        XCTAssertTrue(exists(pathField, timeout: 5), "Path TextField not found after switching to Script file")
        pathField.click()
        Thread.sleep(forTimeInterval: Self.uiPump)
        pathField.typeText(scriptPath)
        Thread.sleep(forTimeInterval: Self.uiPump)

        // Save the edit; the confirmation dialog appears because the
        // file-mode fingerprint is captured at confirm-save time too.
        XCTAssertTrue(exists(saveButtonEdit, timeout: 3), "Macro Save button not found (file)")
        XCTAssertTrue(saveButtonEdit.isEnabled, "Macro Save should be enabled after entering the path")
        saveButtonEdit.click()
        XCTAssertTrue(exists(confirmSaveEdit, timeout: 5), "Confirm-Save button not found (file)")
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

    /// Avoids XCTest's one-second initial polling delay when the element is
    /// already present, while preserving the original timeout on cold runs.
    private func exists(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        element.exists || element.waitForExistence(timeout: timeout)
    }

    // MARK: - Clipboard Seeding Helper

    /// Writes a string to the system pasteboard (`NSPasteboard.general`) from
    /// the test runner process. The host app's `ClipboardMonitor` polls the
    /// same system-wide pasteboard on a utility queue, so a write from the UI
    /// test process is observable by the app under test. We then poll the main
    /// window's history list until the exact seeded text appears.
    ///
    /// Strings are unique-ified with a UUID suffix so successive seeds do not
    /// deduplicate into a single history row.
    private func seedClipboardHistory(app: XCUIApplication,
                                      text: String,
                                      timeout: TimeInterval = 15) throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        let unique = "\(text)-\(UUID().uuidString.prefix(8))"
        pb.setString(unique, forType: .string)
        // Wait for the host app's poller to pick the write up and render a row.
        // Counting staticTexts is not equivalent to counting rows because each
        // row exposes both its preview and timestamp as separate text elements.
        let list = app.scrollViews["historyList"]
        XCTAssertTrue(exists(list, timeout: 5), "historyList not found")
        let predicate = NSPredicate(format: "label == %@ OR value == %@", unique, unique)
        let seededText = list.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(exists(seededText, timeout: timeout),
                      "Seeded clipboard text did not appear within \(timeout)s; dumping tree:\n\(app.debugDescription)")
    }

    /// Writes a unique 4x4 PNG to the system pasteboard and waits until the
    /// host app renders the corresponding image history row. UUID bytes are
    /// encoded into the pixels so repeated test runs cannot be deduplicated.
    private func seedImageClipboardHistory(app: XCUIApplication,
                                           timeout: TimeInterval = 15) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 16,
            bitsPerPixel: 32
        ))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        var uuid = UUID().uuid
        let uniqueBytes = withUnsafeBytes(of: &uuid) { Array($0) }
        for pixel in 0..<16 {
            let offset = pixel * 4
            pixels[offset] = uniqueBytes[pixel]
            pixels[offset + 1] = uniqueBytes[(pixel + 5) % uniqueBytes.count]
            pixels[offset + 2] = uniqueBytes[(pixel + 11) % uniqueBytes.count]
            pixels[offset + 3] = 255
        }
        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png), "Failed to seed PNG on pasteboard")

        let list = app.scrollViews["historyList"]
        XCTAssertTrue(exists(list, timeout: 5), "historyList not found")
        let predicate = NSPredicate(format: "label == 'Image' OR value == 'Image'")
        let imageRowText = list.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(exists(imageRowText, timeout: timeout),
                      "Seeded clipboard image did not appear within \(timeout)s; dumping tree:\n\(app.debugDescription)")
    }

    /// Generates a high-contrast PNG containing a short OCR marker, writes it
    /// to the system pasteboard, and waits for the image history row. Keeping
    /// the rendered payload short and large makes Vision recognition reliable
    /// without lengthening the test with a complex fixture.
    private func seedOcrImageClipboardHistory(app: XCUIApplication,
                                              marker: String,
                                              timeout: TimeInterval = 15) throws {
        let size = NSSize(width: 720, height: 180)
        let uniqueSuffix = Int.random(in: 1000...9999)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        ("\(marker) \(uniqueSuffix)" as NSString).draw(
            in: NSRect(x: 28, y: 42, width: 664, height: 100),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 72, weight: .bold),
                .foregroundColor: NSColor.black
            ]
        )
        image.unlockFocus()

        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png),
                      "Failed to seed OCR PNG on pasteboard")

        let list = app.scrollViews["historyList"]
        XCTAssertTrue(exists(list, timeout: 5), "historyList not found")
        XCTAssertTrue(exists(imageHistoryRow(in: app), timeout: timeout),
                      "Seeded OCR image did not appear within \(timeout)s; dumping tree:\n\(app.debugDescription)")
    }

    // MARK: - Tests: Keyboard Navigation & Macro Execution

    /// Opens the history window, seeds one entry via the system pasteboard,
    /// then verifies two keyboard-navigation behaviors:
    ///   1. With list focus, pressing ↑ at the top of the list moves focus
    ///      back to the search field (HistoryListPane.moveSelection(.up) with
    ///      currentIndex == 0 flips `searchFocused = true`).
    ///   2. With the search field focused, pressing ↓ moves focus to the list
    ///      and advances selection (HistoryListPane.onKeyPress(.downArrow)).
    ///
    /// Both assertions are focus-state surrogates: XCTest cannot directly read
    /// SwiftUI `@FocusState`, so we send keys through the application to the
    /// current first responder and observe whether the search value changes.
    func testKeyboardNavigationBetweenSearchAndList() throws {
        let app = makeApp()
        app.launch()

        // Close Settings (opened by AppDelegate on E2E launch) so the main
        // window is the key window driving keyboard focus.
        let settingsWindow = app.windows["ClipboardManager Settings"]
        if settingsWindow.exists {
            settingsWindow.buttons.element(boundBy: 0).click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(exists(mainWindow, timeout: 10), "Main window did not appear")

        // Seed a single clipboard entry so the history list is non-empty and
        // the moveSelection(.up) "already at top" branch is reachable.
        try seedClipboardHistory(app: app, text: "E2EFocusSeed")

        let searchField = app.textFields["searchField"]
        XCTAssertTrue(exists(searchField, timeout: 5), "searchField not found")
        let historyList = app.scrollViews["historyList"]
        XCTAssertTrue(exists(historyList, timeout: 5), "historyList not found")

        // --- Step 1: ↑ at the top of the list → search field focus ---
        // Click the first row to anchor selection at the top and establish
        // list focus, then press ↑. The list opens with the topmost item
        // selected (resetSelectionToTop) so one ↑ moves focus to search.
        let firstRow = historyList.staticTexts.firstMatch
        XCTAssertTrue(exists(firstRow, timeout: 5), "first history row not found")
        firstRow.click()
        Thread.sleep(forTimeInterval: Self.uiPump)

        // Press ↑ on the list; expected to flip focus to the search field.
        app.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: Self.uiPump)

        // After ↑, searchField should hold keyboard focus — verify by typing
        // through the app to its current first responder. Using the app rather
        // than targeting the TextField avoids asking XCUITest to act on a stale
        // AX element while SwiftUI refreshes the filtered history tree.
        app.typeKey("e", modifierFlags: [])
        Thread.sleep(forTimeInterval: Self.uiPump)
        let searchValueAfterUp = app.textFields["searchField"].value as? String ?? ""
        XCTAssertEqual(searchValueAfterUp, "e",
                       "Search field did not receive focus after ↑ from list (value='\(searchValueAfterUp)')")

        // Clear the typed query so subsequent ↓ navigation starts from empty.
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        Thread.sleep(forTimeInterval: Self.uiPump)

        // --- Step 2: ↓ from the search field → list focus + selection move ---
        // Press ↓ while the search field is focused. The HistoryListPane
        // onKeyPress(.downArrow) handler flips listFocused = true and advances
        // selection. XCUIElement does not expose SwiftUI selection directly,
        // so verify indirectly that the search field gave up focus: typing
        // after ↓ must not echo into the search field.
        app.typeKey(.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: Self.uiPump)

        // Now type into the (now non-focused) search field path. With the list
        // focused, typing a character should not modify the search field value.
        // We use the keyboard via the app-level typeKey (no modifier) — if the
        // search field still had focus it would echo 'b'; if the list has focus
        // (the expected outcome) the search value stays empty.
        app.typeKey("b", modifierFlags: [])
        Thread.sleep(forTimeInterval: Self.uiPump)
        let searchValueAfterDown = app.textFields["searchField"].value as? String ?? ""
        XCTAssertEqual(searchValueAfterDown, "",
                       "Search field should have given up focus after ↓ (value='\(searchValueAfterDown)'); expected empty")

        // And the list should now accept arrow keys: pressing ↓ again should
        // not crash the app. Verify that the list and its window remain open.
        // (Selection index bump is not directly observable through XCUIElement.)
        app.typeKey(.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: Self.uiPump)
        XCTAssertTrue(historyList.exists, "historyList should still exist after ↓ navigation")
        XCTAssertTrue(mainWindow.exists, "Main window should remain open after list navigation")
    }

    /// Verifies incremental search filters the history list to only matching
    /// entries. Flow:
    ///   1. Close Settings so the main window is key.
    ///   2. Clear any leftover history from previous test runs via More >
    ///      Clear All History.
    ///   3. Seed three distinct text entries on the system pasteboard.
    ///   4. Select the search field and type a query matching only the second
    ///      seed.
    ///   5. Poll until only the matching marker remains visible and the other
    ///      two markers disappear from the history list.
    ///   6. Clear the query and verify all three markers reappear.
    ///
    /// This is a purely UI-state assertion because the sandboxed test runner
    /// cannot read the host view model directly (SmokeTests philosophy).
    func testSearchFiltersHistoryList() throws {
        let app = makeApp()
        app.launch()

        // Close Settings so the main window is key.
        let settingsWindow = app.windows["ClipboardManager Settings"]
        if settingsWindow.exists {
            settingsWindow.buttons.element(boundBy: 0).click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(exists(mainWindow, timeout: 10), "Main window did not appear")

        // E2E launches reuse the same SwiftData store, so stale history from
        // earlier runs can accumulate. Clear it once at the start of this test
        // so the assertions below depend only on the seeds we control.
        try clearHistory(app: app)

        // Seed three unique entries so we can verify filtering reduces the list
        // to exactly the matching one. Use hard-coded prefixes that cannot match
        // each other or the UUID suffixes.
        let alphaMarker = "E2ESearchAlpha-"
        let bravoMarker = "E2ESearchBravo-"
        let charlieMarker = "E2ESearchCharlie-"
        try seedClipboardHistory(app: app, text: alphaMarker)
        try seedClipboardHistory(app: app, text: bravoMarker)
        try seedClipboardHistory(app: app, text: charlieMarker)

        let searchField = app.textFields["searchField"]
        XCTAssertTrue(exists(searchField, timeout: 5), "searchField not found")
        let historyList = app.scrollViews["historyList"]
        XCTAssertTrue(exists(historyList, timeout: 5), "historyList not found")

        // Wait until all three seeded rows have materialised in the UI.
        let seededDeadline = Date().addingTimeInterval(10)
        while Date() < seededDeadline {
            if countRows(in: app, containing: alphaMarker) == 1,
               countRows(in: app, containing: bravoMarker) == 1,
               countRows(in: app, containing: charlieMarker) == 1 {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        // Focus the search field and type a query that only matches the bravo entry.
        searchField.click()
        Thread.sleep(forTimeInterval: Self.uiPump)
        searchField.typeText("Bravo")
        Thread.sleep(forTimeInterval: Self.uiPump)

        // Diagnostic: fail fast if the synthetic typing did not reach the field.
        let typedQuery = searchField.value as? String ?? ""
        XCTAssertEqual(typedQuery, "Bravo",
                       "Search field value should be 'Bravo', got '\(typedQuery)'")

        // Wait for the debounced filter to drop alpha/charlie rows.
        let filterDeadline = Date().addingTimeInterval(10)
        var bravoVisible = 0
        var alphaVisible = 1
        var charlieVisible = 1
        while Date() < filterDeadline {
            bravoVisible = countRows(in: app, containing: bravoMarker)
            alphaVisible = countRows(in: app, containing: alphaMarker)
            charlieVisible = countRows(in: app, containing: charlieMarker)
            if bravoVisible == 1 && alphaVisible == 0 && charlieVisible == 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(bravoVisible, 1,
                       "Search should keep exactly 1 'Bravo' row, got \(bravoVisible); dumping history list tree:\n\(app.scrollViews["historyList"].debugDescription)")
        XCTAssertEqual(alphaVisible, 0,
                       "Search should filter out 'Alpha' rows, got \(alphaVisible)")
        XCTAssertEqual(charlieVisible, 0,
                       "Search should filter out 'Charlie' rows, got \(charlieVisible)")

        // Clearing the query should restore all three seeds.
        // Filtering can rebuild the SwiftUI field, so send keys through the app
        // to the current first responder rather than the pre-filter snapshot.
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])

        let clearDeadline = Date().addingTimeInterval(10)
        var alphaRestored = 0
        var bravoRestored = 0
        var charlieRestored = 0
        while Date() < clearDeadline {
            alphaRestored = countRows(in: app, containing: alphaMarker)
            bravoRestored = countRows(in: app, containing: bravoMarker)
            charlieRestored = countRows(in: app, containing: charlieMarker)
            if alphaRestored == 1 && bravoRestored == 1 && charlieRestored == 1 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(alphaRestored, 1,
                       "Clearing search should restore 'Alpha' row, got \(alphaRestored)")
        XCTAssertEqual(bravoRestored, 1,
                       "Clearing search should restore 'Bravo' row, got \(bravoRestored)")
        XCTAssertEqual(charlieRestored, 1,
                       "Clearing search should restore 'Charlie' row, got \(charlieRestored)")
    }

    /// Verifies the opt-in automatic image OCR workflow end-to-end:
    ///   1. Enable automatic OCR in Settings.
    ///   2. Copy a unique generated image containing an OCR-friendly marker.
    ///   3. Find the image by searching for text that exists only inside it.
    ///   4. Press Cmd+P and verify the persisted OCR text is pasted without
    ///      showing the interactive OCR progress overlay again.
    func testAutomaticImageOcrSearchAndCachedPaste() throws {
        let app = makeApp()
        app.launch()

        let settingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(exists(settingsWindow, timeout: 10), "Settings window did not appear on launch")

        let automaticOcrToggle = app.switches["automaticImageOcr"]
        let settingsScrollView = settingsWindow.scrollViews.firstMatch
        XCTAssertTrue(exists(settingsScrollView, timeout: 5), "Settings scroll view not found")
        for _ in 0..<6 where !automaticOcrToggle.exists || !automaticOcrToggle.isHittable {
            settingsScrollView.scroll(byDeltaX: 0, deltaY: -300)
        }
        XCTAssertTrue(exists(automaticOcrToggle, timeout: 5),
                      "Automatic OCR toggle not found; dumping Settings tree:\n\(settingsWindow.debugDescription)")
        XCTAssertTrue(automaticOcrToggle.isHittable, "Automatic OCR toggle is not hittable")
        automaticOcrToggle.click()
        Thread.sleep(forTimeInterval: Self.uiPump)
        XCTAssertEqual((automaticOcrToggle.value as? NSNumber)?.intValue, 1,
                       "Automatic OCR toggle should be enabled")

        settingsWindow.buttons.element(boundBy: 0).click()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(settingsWindow.exists, "Settings window should be closed")
        XCTAssertTrue(exists(app.windows.firstMatch, timeout: 5), "Main window did not appear")

        try clearHistory(app: app)
        let marker = "INDEXABLE"
        try seedOcrImageClipboardHistory(app: app, marker: marker)

        let searchField = app.textFields["searchField"]
        XCTAssertTrue(exists(searchField, timeout: 5), "searchField not found")
        searchField.click()
        Thread.sleep(forTimeInterval: Self.uiPump)
        searchField.typeText(marker)

        // The row initially disappears because its OCR result is still pending,
        // then reappears when the persisted result refreshes the search index.
        let ocrTimeout: TimeInterval = 60
        let searchDeadline = Date().addingTimeInterval(ocrTimeout)
        var imageFoundByOcr = false
        var visibleSince: Date?
        while Date() < searchDeadline {
            if imageHistoryRow(in: app).exists {
                visibleSince = visibleSince ?? Date()
                if Date().timeIntervalSince(visibleSince ?? Date()) >= 0.6 {
                    imageFoundByOcr = true
                    break
                }
            } else {
                visibleSince = nil
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(imageFoundByOcr,
                      "Image was not found by OCR marker '\(marker)' within \(Int(ocrTimeout))s; dumping history tree:\n\(app.scrollViews["historyList"].debugDescription)")

        // Filtering selects the sole matching row. Keep the search field focused
        // and invoke the window-scoped Carbon hotkey through the key application;
        // clicking a SwiftUI row snapshot here would race a list rebuild.
        app.typeKey("p", modifierFlags: .command)
        let pasteDeadline = Date().addingTimeInterval(5)
        var pastedCachedText = false
        var showedOcrProgress = false
        while Date() < pasteDeadline {
            if app.staticTexts["Running OCR…"].exists {
                showedOcrProgress = true
            }
            if NSPasteboard.general.string(forType: .string)?.contains(marker) == true {
                pastedCachedText = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(pastedCachedText,
                      "Cmd+P did not paste the cached OCR marker '\(marker)' within 5s")
        XCTAssertFalse(showedOcrProgress,
                       "Cmd+P should reuse persisted OCR text without showing the OCR progress overlay")
    }

    /// Verifies the image-only filter keeps image history visible while hiding
    /// text history, then restores the text row when toggled off.
    func testImageFilterShowsOnlyImages() throws {
        let app = makeApp()
        app.launch()

        let settingsWindow = app.windows["ClipboardManager Settings"]
        if settingsWindow.exists {
            settingsWindow.buttons.element(boundBy: 0).click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        XCTAssertTrue(exists(app.windows.firstMatch, timeout: 10), "Main window did not appear")
        try clearHistory(app: app)

        let textMarker = "E2EImageFilterText-"
        try seedClipboardHistory(app: app, text: textMarker)
        try seedImageClipboardHistory(app: app)

        XCTAssertEqual(countRows(in: app, containing: textMarker), 1,
                       "Seeded text row should be visible before filtering")
        XCTAssertTrue(imageHistoryRow(in: app).exists,
                      "Seeded image row should be visible before filtering")

        let imageFilterButton = app.buttons["imageFilterButton"]
        XCTAssertTrue(exists(imageFilterButton, timeout: 5), "Image filter button not found")
        XCTAssertEqual(imageFilterButton.value as? String, "Off",
                       "Image filter should initially be off")
        imageFilterButton.click()

        let filterDeadline = Date().addingTimeInterval(10)
        var textRows = 1
        var imageVisible = false
        while Date() < filterDeadline {
            textRows = countRows(in: app, containing: textMarker)
            imageVisible = imageHistoryRow(in: app).exists
            if textRows == 0 && imageVisible { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(textRows, 0, "Image filter should hide text history rows")
        XCTAssertTrue(imageVisible, "Image filter should keep the image history row visible")
        XCTAssertEqual(app.buttons["imageFilterButton"].value as? String, "On",
                       "Image filter should expose its active accessibility value")

        app.buttons["imageFilterButton"].click()
        let restoreDeadline = Date().addingTimeInterval(10)
        var restoredTextRows = 0
        while Date() < restoreDeadline {
            restoredTextRows = countRows(in: app, containing: textMarker)
            if restoredTextRows == 1 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(restoredTextRows, 1,
                       "Turning off the image filter should restore the text history row")
        XCTAssertEqual(app.buttons["imageFilterButton"].value as? String, "Off",
                       "Image filter should expose its inactive accessibility value")
    }

    /// Re-queries the image row because SwiftUI can rebuild the accessibility
    /// tree whenever filtering changes.
    private func imageHistoryRow(in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label == 'Image' OR value == 'Image'")
        return app.scrollViews["historyList"].staticTexts.matching(predicate).firstMatch
    }

    /// Drives the main-window More menu to clear all history. Used before
    /// seeding controlled clipboard entries so the test is isolated from
    /// history left over by earlier E2E runs.
    private func clearHistory(app: XCUIApplication) throws {
        let moreMenu = app.menuButtons["moreMenu"]
        XCTAssertTrue(exists(moreMenu, timeout: 5), "More menu button not found")
        moreMenu.click()
        Thread.sleep(forTimeInterval: Self.uiPump)

        let clearItem = app.menuItems["Clear All History"]
        XCTAssertTrue(exists(clearItem, timeout: 5), "Clear All History menu item not found")
        clearItem.click()
        Thread.sleep(forTimeInterval: Self.uiPump)

        // AppDelegate presents this confirmation with NSAlert.runModal(). XCUITest
        // exposes it as the only dialog, with the generic label "alert"; the
        // message text is only a child value and cannot identify the dialog.
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(exists(dialog, timeout: 5), "Clear-history confirmation dialog not found")
        let clearButton = dialog.buttons["Clear"]
        XCTAssertTrue(exists(clearButton, timeout: 5), "Clear button not found in clear-history dialog")
        clearButton.click()

        let historyList = app.scrollViews["historyList"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if historyList.staticTexts.count == 0, historyList.images.count == 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(historyList.staticTexts.count, 0,
                       "History list staticTexts should be empty after Clear All; dumping tree:\n\(historyList.debugDescription)")
        XCTAssertEqual(historyList.images.count, 0,
                       "History list images should be empty after Clear All; dumping tree:\n\(historyList.debugDescription)")
    }

    /// Counts descendant rows in the current history list whose contained static
    /// text matches `substring`. Counts container rows (cells/otherElements) rather than
    /// individual staticTexts so a row that exposes title + subtitle as two
    /// AX staticTexts is only counted once (AGENTS.md: avoid brittle per-text
    /// counting when one row can have multiple AX text elements).
    private func countRows(in app: XCUIApplication, containing substring: String) -> Int {
        // SwiftUI can replace the scroll view when filtering. Re-query it on each
        // poll instead of retaining a stale XCUIElement snapshot.
        let list = app.scrollViews["historyList"]
        let predicateFormat = "label CONTAINS[c] %@ OR value CONTAINS[c] %@"
        // `cells` covers SwiftUI List rows surfaced as AX cells. Fall back to
        // `otherElements.matching` for list containers that don't expose cells
        // but do expose row-like otherElements. We dedupe by identifier so the
        // same row is never counted twice across the two queries.
        var seen = Set<String>()
        let cellsPredicate = NSPredicate(format: predicateFormat, substring, substring)
        for element in list.cells.matching(cellsPredicate).allElementsBoundByAccessibilityElement {
            let id = element.identifier
            if !id.isEmpty { seen.insert(id) }
        }
        let otherElementsPredicate = NSPredicate(format: predicateFormat, substring, substring)
        for element in list.otherElements.matching(otherElementsPredicate).allElementsBoundByAccessibilityElement {
            let id = element.identifier
            if !id.isEmpty { seen.insert(id) }
        }
        // If neither cells nor otherElements yielded matches, fall back to
        // staticTexts so the test still surfaces a non-zero count when the AX
        // tree surfaces text only (some SwiftUI versions do this for List
        // rows that are not wrapped in a native cell).
        if seen.isEmpty {
            let staticTextsPredicate = NSPredicate(format: predicateFormat, substring, substring)
            return list.staticTexts.matching(staticTextsPredicate).count
        }
        return seen.count
    }

    /// Verifies the FooterBar "Run Macro" pull-down menu can launch a
    /// registered macro against the selected history entry and produce the
    /// expected output through `$CB_OUTPUT_FILE`. Flow:
    ///   1. Launch E2E app (Settings opens automatically).
    ///   2. Register a single inline-script macro via Settings whose inline
    ///      script writes the macro's invocation marker into `$CB_OUTPUT_FILE`.
    ///   3. Close Settings, focus the main window, seed a clipboard entry so
    ///      there is a selected history item for the macro to run against.
    ///   4. Open the "Run Macro" pull-down and click the macro's menu item.
    ///   5. Poll the output file until it contains the marker.
    ///
    /// The script body is identical in spirit to the one used by
    /// `testMacroScriptWorkflow` but writes a fixed marker string so the test
    /// can assert exact contents instead of just file existence.
    func testRunMacroFromFooterPullDown() throws {
        let app = makeApp()
        app.launch()
        let settingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(exists(settingsWindow, timeout: 10), "Settings window did not appear on launch")

        // Sanity: no macros on launch (forceE2EDefaultSettings clears them).
        let emptyLabel = app.staticTexts["macro.empty"]
        XCTAssertTrue(exists(emptyLabel, timeout: 5), "Macro empty-state label not found")

        // --- Step 1: Add an inline-script macro ---
        let addButton = app.buttons["macro.add"]
        XCTAssertTrue(exists(addButton, timeout: 5), "Add Macro button not found")
        addButton.click()
        Thread.sleep(forTimeInterval: Self.uiPump)

        let nameField = app.textFields["macro.0.name"]
        XCTAssertTrue(exists(nameField, timeout: 5), "Macro row name field not found after Add")
        nameField.click()
        Thread.sleep(forTimeInterval: Self.uiPump)
        // Replace the seed name "New Macro" with "EchoMacro".
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText("EchoMacro")
        Thread.sleep(forTimeInterval: Self.uiPump)

        // Edit the inline script body so the macro writes a unique marker to
        // its normal output file. PasteCoordinator then places that output on
        // the system pasteboard, which the test process can observe directly.
        // ShellScriptEditor is an NSViewRepresentable that wraps NSScrollView
        // + NSTextView. The accessibilityIdentifier("macro.0.inlineScript") is
        // applied to the SwiftUI view, which surfaces on the underlying
        // NSScrollView in the AX tree — so we resolve it as a ScrollView, then
        // drill into its documentView via the contained TextView.
        let inlineScroll = app.scrollViews["macro.0.inlineScript"]
        XCTAssertTrue(exists(inlineScroll, timeout: 5),
                      "Inline script scroll view not found; dumping tree:\n\(app.debugDescription)")
        let inlineEditor = inlineScroll.textViews.firstMatch
        XCTAssertTrue(exists(inlineEditor, timeout: 5),
                      "Inline script text view not found inside scroll view; dumping tree:\n\(app.debugDescription)")
        inlineEditor.click()
        Thread.sleep(forTimeInterval: Self.uiPump)
        // Select-all + delete to clear the seed, then type our script body.
        inlineEditor.typeKey("a", modifierFlags: .command)
        inlineEditor.typeKey(.delete, modifierFlags: [])
        Thread.sleep(forTimeInterval: Self.uiPump)
        let marker = "E2E_MACRO_FOOTER_RUN_\(UUID().uuidString.prefix(8))"
        let scriptBody = "printf \(marker) > \"$CB_OUTPUT_FILE\""
        inlineEditor.typeText(scriptBody)
        Thread.sleep(forTimeInterval: Self.uiPump)

        // Save + confirm registration.
        let saveButton = app.buttons["macro.0.save"]
        XCTAssertTrue(exists(saveButton, timeout: 3), "Macro Save button not found")
        XCTAssertTrue(saveButton.isEnabled, "Macro Save should be enabled after editing the inline script")
        saveButton.click()
        let confirmSave = app.buttons["macro.0.confirm.save"]
        XCTAssertTrue(exists(confirmSave, timeout: 5), "Confirm-Save button not found")
        confirmSave.click()
        Thread.sleep(forTimeInterval: 0.3)

        let badge = app.staticTexts["macro.0.fingerprintCaptured"]
        XCTAssertTrue(exists(badge, timeout: 5), "Fingerprint-captured badge not shown after Save")
        XCTAssertFalse(app.staticTexts["macro.empty"].exists,
                       "Empty-state label should disappear once a macro is registered")

        // --- Step 2: Close Settings so the main window is key ---
        let closeButton = settingsWindow.buttons.element(boundBy: 0)
        XCTAssertTrue(closeButton.exists, "Settings window close button not found")
        closeButton.click()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(settingsWindow.exists, "Settings window should be closed")

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(exists(mainWindow, timeout: 5), "Main window did not appear after Settings closed")

        // --- Step 3: Seed a clipboard entry so there is a selected item ---
        try seedClipboardHistory(app: app, text: "E2EMacroTarget")

        // --- Step 4: Open the "Run Macro" pull-down and click EchoMacro ---
        let runMacroMenu = app.menuButtons["runMacroMenu"]
        XCTAssertTrue(exists(runMacroMenu, timeout: 5),
                      "Run Macro menu button not found; dumping tree:\n\(app.debugDescription)")
        runMacroMenu.click()
        Thread.sleep(forTimeInterval: Self.uiPump)

        let macroMenuItem = app.menuItems["EchoMacro"]
        XCTAssertTrue(exists(macroMenuItem, timeout: 5),
                      "EchoMacro menu item not found in Run Macro pull-down; dumping tree:\n\(app.debugDescription)")
        macroMenuItem.click()

        // --- Step 5: Poll the pasteboard for the transformed output ---
        // PasteCoordinator writes the macro output to the system pasteboard.
        // MacroRunner runs on a background queue and Process.run() is async,
        // so the transformed value may take a moment to land.
        var found = false
        let pollDeadline = Date().addingTimeInterval(10)
        while Date() < pollDeadline {
            if NSPasteboard.general.string(forType: .string) == marker {
                found = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(found,
                      "Pasteboard did not contain macro output '\(marker)' within 10s; dumping app tree:\n\(app.debugDescription)")

        // Sanity: app should remain running and no error alert should appear
        // after the macro launched. Successful macro execution intentionally
        // activates the previously frontmost app, so the ClipboardManager
        // window is expected to stop being key/hittable.
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground,
                      "App should remain running after launching macro from Run Macro menu (state=\(app.state.rawValue))")
        XCTAssertFalse(app.dialogs.element(boundBy: 0).exists,
                       "No error dialog should appear after running macro from footer pull-down")
        XCTAssertTrue(mainWindow.exists, "Main window should remain open after macro run")
    }

    // MARK: - App Launcher (original location preserved below)

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
