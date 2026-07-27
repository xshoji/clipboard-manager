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
///   production build so UserDefaults.standard resolves to the same defaults
///   domain ("ClipboardManager"); its bundle id is
///   "com.xshoji.ClipboardManager.E2E" so TCC entries are isolated.
final class SmokeUITests: XCTestCase {
    private static let e2eBundleID = "com.xshoji.ClipboardManager.E2E"
    private static let productionBundleID = "com.xshoji.ClipboardManager"

    private let startupSeconds: TimeInterval = 3

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
        Thread.sleep(forTimeInterval: startupSeconds)
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground,
                      "App crashed within \(startupSeconds)s (state=\(app.state.rawValue))")
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
        //
        // SwiftUI on macOS exposes the rendered Text content as the
        // staticText's *value* (not its `label`) when the Text is standalone,
        // while Text used as the label of a Label/Picker shows up under
        // `label`. The Stepper here renders "Max item size: 10 MB" as a plain
        // Text, so the string is in `value` and `label` is empty. Query both
        // attributes so the match is reliable regardless of which slot
        // SwiftUI populates.
        //
        // We wait for the staticText to exist (failing the test if it never
        // shows up) instead of silently skipping the assertion — a missing
        // label means the Stepper is gone or renamed, which is a regression
        // we want to catch.
        let maxItemText = app.staticTexts.matching(
            NSPredicate(
                format: "(label CONTAINS 'Max item size' OR label CONTAINS '10 MB' OR value CONTAINS 'Max item size' OR value CONTAINS '10 MB')"
            )
        ).firstMatch
        XCTAssertTrue(
            maxItemText.waitForExistence(timeout: 5),
            "Max item size staticText not found; dumping app tree:\n\(app.debugDescription)"
        )
        // The content string ("Max item size: 10 MB") may be stored in either
        // `label` or `value` depending on the SwiftUI rendering path, so
        // inspect whichever is non-empty.
        let maxItemContent = maxItemText.label.isEmpty ? (maxItemText.value as? String ?? "") : maxItemText.label
        XCTAssertTrue(
            maxItemContent.contains("10"),
            "Max item size did not show '10 MB', got '\(maxItemContent)'"
        )
    }

    /// Verifies that clicking "Clear" on the Edit Action Hotkey makes its
    /// display label become "(none)".
    func testActionHotkeyClear() throws {
        let app = makeApp()
        app.launch()
        let settingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window did not appear on launch")

        // Edit hotkey starts at default ⌘E so Clear button is visible.
        let clearButton = app.buttons["action.edit.clear"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 10), "Edit Clear button not found")
        clearButton.click()
        Thread.sleep(forTimeInterval: 1.0)

        let display = app.staticTexts["action.edit.display"]
        if !display.exists {
            Self.log("Display label not found (clear); dumping app tree:\n\(app.debugDescription)")
        }
        XCTAssertTrue(display.exists, "Action edit display label not found")
        // SwiftUI exposes the Text content as the element's `value` (not `label`).
        let displayValue = display.value as? String ?? ""
        XCTAssertEqual(displayValue, "(none)",
                       "Edit hotkey display should be '(none)' after Clear, got '\(displayValue)'")
    }

    /// Verifies that clicking "Reset" on the Edit Action Hotkey restores
    /// its display label to "⌘E" (= default ⌘E).
    /// This test first changes the Edit hotkey to a non-default value via
    /// Record, then clicks Reset.
    func testActionHotkeyReset() throws {
        let app = makeApp()
        app.launch()
        let settingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window did not appear on launch")

        // Step 1: clear the Edit hotkey so Reset has something to restore.
        let clearButton = app.buttons["action.edit.clear"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 10), "Edit Clear button not found (pre-reset)")
        clearButton.click()
        Thread.sleep(forTimeInterval: 0.5)
        // After Clear, the Clear button is conditionally hidden (keyCode/mof==0).
        // The Reset button remains visible.
        let resetButton = app.buttons["action.edit.reset"]
        XCTAssertTrue(resetButton.waitForExistence(timeout: 5), "Edit Reset button not found")
        resetButton.click()
        Thread.sleep(forTimeInterval: 1.0)

        let display = app.staticTexts["action.edit.display"]
        if !display.exists {
            Self.log("Display label not found (reset); dumping app tree:\n\(app.debugDescription)")
        }
        XCTAssertTrue(display.exists, "Action edit display label not found")
        let displayValue = display.value as? String ?? ""
        XCTAssertEqual(displayValue, "⌘E",
                       "Edit hotkey display should be '⌘E' after Reset, got '\(displayValue)'")
    }

    /// Verifies that clicking "Record" on the EditAction Hotkey and then
    /// synthesizing a Cmd+Shift+A key event via XCUIElement captures the
    /// new shortcut, shown as "⇧⌘A".
    func testActionHotkeyRecord() throws {
        let app = makeApp()
        app.launch()
        let settingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window did not appear on launch")

        let recordButton = app.buttons["action.edit.record"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 5), "Edit Record button not found")
        recordButton.click()
        // Wait for CaptureKeyView to become first responder.
        Thread.sleep(forTimeInterval: 1.0)
        // Synthesize Cmd+Shift+A via XCUIElement. macOS XCUItest exposes
        // `typeKey(_:modifierFlags:)` which sends a real key event with the
        // specified modifiers, sidestepping the System Events / AppleScript
        // path that the sandboxed UI test runner cannot use.
        app.typeKey("a", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1.0)

        let display = app.staticTexts["action.edit.display"]
        XCTAssertTrue(display.exists, "Action edit display label not found")
        let displayValue = display.value as? String ?? ""
        XCTAssertEqual(displayValue, "⇧⌘A",
                       "Edit hotkey display should be '⇧⌘A' after Record, got '\(displayValue)'")
    }

    // MARK: - Macro Script CRUD

    /// Verifies that clicking "Add Macro…" inserts a single editable row,
    /// that the row's name field is focusable and the Save button is
    /// initially disabled (no content change yet), and that filling in a
    /// name + Save on the registration confirmation dialog persists the
    /// macro (the fingerprint-captured badge appears and the empty-state
    /// text is gone).
    ///
    /// Notes:
    /// - AppDelegate.forceE2EDefaultSettings resets `macroScripts` to []
    ///   on launch so this test always starts from zero macros.
    /// - The Macro row's inline example already satisfies `canApply`
    ///   (name="New Macro", interpreter="/bin/sh", inline body non-empty),
    ///   so we only need to touch the name to flip the dirty flag and
    ///   then click Save.
    func testAddMacroScript() throws {
        let app = makeApp()
        app.launch()
        let settingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window did not appear on launch")

        // Sanity: no macros on launch (forceE2EDefaultSettings clears them).
        let emptyLabel = app.staticTexts["macro.empty"]
        XCTAssertTrue(emptyLabel.waitForExistence(timeout: 5), "Macro empty-state label not found")

        let addButton = app.buttons["macro.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Add Macro button not found")
        addButton.click()
        Thread.sleep(forTimeInterval: 1.0)

        // The first row's controls live under the "macro.0" prefix.
        let nameField = app.textFields["macro.0.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Macro row name field not found after Add")
        nameField.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Touch the name to mark the row dirty (otherwise Save stays disabled
        // even though canApply is technically true, because `hasContentChanges`
        // compares against the macro model and the seed values are identical
        // until the user types). We append a character so the text binding
        // fires `onChange`.
        nameField.typeText("X")
        Thread.sleep(forTimeInterval: 0.5)

        let saveButton = app.buttons["macro.0.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3), "Macro Save button not found")
        XCTAssertTrue(saveButton.isEnabled, "Macro Save should be enabled after editing the name")
        saveButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Registration confirmation dialog (per design-implementation.md §5.1-1).
        let confirmSave = app.buttons["macro.0.confirm.save"]
        XCTAssertTrue(confirmSave.waitForExistence(timeout: 5), "Confirm-Save button not found")
        confirmSave.click()
        Thread.sleep(forTimeInterval: 1.0)

        // The fingerprint-captured badge shows only on inline-script macros
        // once the user confirms the registration dialog (see MacroScriptRowView.confirmSave).
        let badge = app.staticTexts["macro.0.fingerprintCaptured"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "Fingerprint-captured badge not shown after Save")
        XCTAssertFalse(app.staticTexts["macro.empty"].exists,
                       "Empty-state label should disappear once a macro is registered")
    }

    /// Verifies that an existing macro's name can be edited and the change
    /// is persisted through the Save → confirm dialog. After Save the row
    /// model snapshot is updated, so re-opening the name field shows the new
    /// value (proving the edit was committed, not just buffered in @State).
    func testEditMacroScript() throws {
        let app = makeApp()
        app.launch()
        let settingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window did not appear on launch")

        // Seed: add one macro and register it (same flow as testAddMacroScript).
        let addButton = app.buttons["macro.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Add Macro button not found (seed)")
        addButton.click()
        Thread.sleep(forTimeInterval: 0.5)
        let nameField = app.textFields["macro.0.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Macro row name field not found")
        nameField.click()
        Thread.sleep(forTimeInterval: 0.3)
        nameField.typeText("X")
        let saveButton = app.buttons["macro.0.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3), "Macro Save button not found (seed)")
        saveButton.click()
        let confirmSave = app.buttons["macro.0.confirm.save"]
        XCTAssertTrue(confirmSave.waitForExistence(timeout: 5), "Confirm-Save button not found (seed)")
        confirmSave.click()
        Thread.sleep(forTimeInterval: 1.0)

        // After registration, the row model is republished and the name field
        // reflects the persisted value (name should end with "X" since the
        // seed input was "New Macro" + "X").
        let nameAfterSeed = try XCTUnwrap(nameField.value as? String)
        XCTAssertTrue(nameAfterSeed.hasSuffix("X"),
                      "Name should reflect seeded edit after registration, got '\(nameAfterSeed)'")

        // Edit: select-all the name field and replace with a new name.
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText("Edited Macro")
        Thread.sleep(forTimeInterval: 0.5)

        // Save the edit; the confirmation dialog appears because the
        // inline-script fingerprint is re-captured on every confirm-save.
        let saveButtonEdit = app.buttons["macro.0.save"]
        XCTAssertTrue(saveButtonEdit.isEnabled, "Macro Save should be enabled after editing the name")
        saveButtonEdit.click()
        let confirmSaveEdit = app.buttons["macro.0.confirm.save"]
        XCTAssertTrue(confirmSaveEdit.waitForExistence(timeout: 5), "Confirm-Save button not found (edit)")
        confirmSaveEdit.click()
        Thread.sleep(forTimeInterval: 1.0)

        // Assert the persisted name is the new one.
        let finalName = try XCTUnwrap(nameField.value as? String)
        XCTAssertEqual(finalName, "Edited Macro",
                       "Macro name should be 'Edited Macro' after editing, got '\(finalName)'")
    }

    /// Verifies that closing the Settings window while a macro row is dirty
    /// (edits not yet saved) raises the "Unsaved Macro Changes" NSAlert, and
    /// that choosing "Cancel" on that alert keeps the Settings window open
    /// and leaves the in-progress edit intact. Re-focusing the name field
    /// should still show the unsaved value (proving the edit was not
    /// silently committed/dropped).
    func testUnsavedMacroChangesModalOnClose() throws {
        let app = makeApp()
        app.launch()
        let settingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window did not appear on launch")

        // Add a macro and immediately edit its name WITHOUT clicking Save so
        // the row stays dirty (`viewModel.unsavedMacroIDs` contains the row).
        let addButton = app.buttons["macro.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Add Macro button not found")
        addButton.click()
        Thread.sleep(forTimeInterval: 0.5)
        let nameField = app.textFields["macro.0.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Macro row name field not found")
        nameField.click()
        Thread.sleep(forTimeInterval: 0.3)
        nameField.typeText("UnsavedEdit")
        Thread.sleep(forTimeInterval: 0.5)

        // Sanity: the dirty edit is buffered in the name field's value.
        let bufferedName = try XCTUnwrap(nameField.value as? String)
        XCTAssertTrue(bufferedName.hasSuffix("UnsavedEdit"),
                      "Name field should show unsaved edit, got '\(bufferedName)'")

        // Trigger the close. SettingsWindowController.windowShouldClose runs
        // the NSAlert. XCUITest exposes it as `app.dialogs`. The Settings
        // window's traffic-light buttons (close / miniaturize / zoom) appear
        // in `settingsWindow.buttons`; the close button is the leftmost one
        // (boundBy: 0).
        let closeButton = settingsWindow.buttons.element(boundBy: 0)
        XCTAssertTrue(closeButton.exists, "Settings window close button not found")
        closeButton.click()
        Thread.sleep(forTimeInterval: 1.0)

        // The unsaved-changes alert is an NSAlert; XCUI exposes it via
        // `app.dialogs`.
        let unsavedAlert = app.dialogs.element(boundBy: 0)
        XCTAssertTrue(unsavedAlert.waitForExistence(timeout: 5),
                      "Unsaved-changes alert did not appear on close; dumping tree:\n\(app.debugDescription)")
        // The alert's message text is "Unsaved Macro Changes". Either read it
        // from the static text or just rely on the Cancel button being present.
        let cancelButton = unsavedAlert.buttons["Cancel"]
        XCTAssertTrue(cancelButton.exists, "Cancel button not found on unsaved-changes alert")
        cancelButton.click()
        Thread.sleep(forTimeInterval: 1.0)

        // After Cancel, the Settings window must still exist (the close was
        // vetoed by windowShouldClose returning false).
        XCTAssertTrue(settingsWindow.exists,
                      "Settings window should still be open after Canceling the unsaved-changes alert")
        XCTAssertFalse(app.dialogs.element(boundBy: 0).exists,
                       "Unsaved-changes alert should be dismissed after Cancel")

        // The unsaved edit must still be intact in the name field — i.e., the
        // Cancel path did NOT commit the change.
        let nameAfterCancel = try XCTUnwrap(app.textFields["macro.0.name"].value as? String)
        XCTAssertTrue(nameAfterCancel.hasSuffix("UnsavedEdit"),
                      "Unsaved edit should be preserved after Canceling the alert, got '\(nameAfterCancel)'")

        // Re-focus the name field by clicking it and confirm the edit is still
        // there (defensive: ensures the field is still interactive and the
        // dirty state survives the alert cycle).
        nameField.click()
        Thread.sleep(forTimeInterval: 0.3)
        let nameRefocused = try XCTUnwrap(nameField.value as? String)
        XCTAssertTrue(nameRefocused.hasSuffix("UnsavedEdit"),
                      "Unsaved edit should still be in the name field after re-focusing, got '\(nameRefocused)'")
    }

    /// Verifies that switching the inline-script interpreter preset from
    /// `/bin/sh` (default for the Add Macro… seed) to `/bin/bash` is persisted
    /// through the Save → confirm dialog. After Save the row model is
    /// republished and the preset popUp's selected value shows `/bin/bash`.
    ///
    /// Note: in inline mode the interpreter TextField is only rendered when
    /// the preset is "Custom"; for the seeded "/bin/sh" → "/bin/bash" path we
    /// observe the preset popUp's `value` instead of the TextField. The macro
    /// model's `interpreter` field mirrors the preset (see
    /// `onChange(of: interpreterPreset)`), so the popUp's selected label is a
    /// faithful proxy for the persisted interpreter.
    func testChangeMacroInterpreterPreset() throws {
        let app = makeApp()
        app.launch()
        let settingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window did not appear on launch")

        // Seed: add one macro and register it (same flow as testAddMacroScript).
        let addButton = app.buttons["macro.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Add Macro button not found (seed)")
        addButton.click()
        Thread.sleep(forTimeInterval: 0.5)
        let nameField = app.textFields["macro.0.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Macro row name field not found")
        nameField.click()
        nameField.typeText("X")
        let saveButton = app.buttons["macro.0.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3), "Macro Save button not found (seed)")
        saveButton.click()
        let confirmSave = app.buttons["macro.0.confirm.save"]
        XCTAssertTrue(confirmSave.waitForExistence(timeout: 5), "Confirm-Save button not found (seed)")
        confirmSave.click()
        Thread.sleep(forTimeInterval: 1.0)

        // Sanity: the interpreter preset is "/bin/sh" (MacroScript default).
        // In inline mode the preset is shown via a popUpButton; the selected
        // item's label is the popUp's `value` (SwiftUI Picker → NSPopUpButton).
        let presetPopUp = app.popUpButtons["macro.0.interpreterPreset"]
        XCTAssertTrue(presetPopUp.waitForExistence(timeout: 5), "Interpreter preset popUp not found (seed)")
        let seedPreset = try XCTUnwrap(presetPopUp.value as? String)
        XCTAssertEqual(seedPreset, "/bin/sh",
                       "Seeded interpreter preset should be '/bin/sh', got '\(seedPreset)'")

        // Switch the preset to /bin/bash by opening the popUp and tapping
        // the matching menu item.
        presetPopUp.click()
        Thread.sleep(forTimeInterval: 0.5)
        let bashMenuItem = app.menuItems["/bin/bash"]
        XCTAssertTrue(bashMenuItem.waitForExistence(timeout: 3), "/bin/bash menu item not found")
        bashMenuItem.click()
        Thread.sleep(forTimeInterval: 0.5)

        // The preset change immediately writes `interpreter = "/bin/bash"`
        // (`onChange(of: interpreterPreset)`), and the row's dirty flag flips
        // because interpreter now differs from the macro model. Save → confirm.
        let saveButtonEdit = app.buttons["macro.0.save"]
        XCTAssertTrue(saveButtonEdit.isEnabled, "Macro Save should be enabled after changing interpreter preset")
        saveButtonEdit.click()
        let confirmSaveEdit = app.buttons["macro.0.confirm.save"]
        XCTAssertTrue(confirmSaveEdit.waitForExistence(timeout: 5), "Confirm-Save button not found (edit)")
        confirmSaveEdit.click()
        Thread.sleep(forTimeInterval: 1.0)

        // Assert the persisted preset (and therefore the interpreter) is the
        // new one.
        let finalPreset = try XCTUnwrap(app.popUpButtons["macro.0.interpreterPreset"].value as? String)
        XCTAssertEqual(finalPreset, "/bin/bash",
                       "Interpreter preset should be '/bin/bash' after preset change, got '\(finalPreset)'")
    }

    /// Verifies that switching the source type to "Script file" and entering
    /// a real script path (a file created under the user's home directory by
    /// the test runner) validates and saves successfully. After Save the row
    /// model is republished; the path field shows the resolved path and the
    /// fingerprint-captured badge must NOT appear (file-mode macros show no
    /// badge; only inline-mode ones do — see MacroScriptRowView.confirmSave).
    func testMacroScriptFileSource() throws {
        let app = makeApp()
        app.launch()
        let settingsWindow = app.windows["ClipboardManager Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window did not appear on launch")

        // Create a real, executable shell script file in the user's home
        // directory. MacroScriptPathValidator rejects paths outside $HOME
        // (`.outsideHome`) and non-existent files (`.fileNotFound`), so we
        // need an in-home, in-disk file. The temporary directory provided by
        // `NSTemporaryDirectory()` is usually outside $HOME on macOS
        // (`/var/folders/...`), so we write directly to `~/` instead.
        let home = NSHomeDirectory()
        let scriptPath = (home as NSString).appendingPathComponent("ClipboardManagerE2ETestMacro.sh")
        let scriptBody = "#!/bin/sh\necho hi > \"$CB_OUTPUT_FILE\"\n"
        do {
            try scriptBody.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            // Best-effort chmod; non-executable file still passes path
            // validation (only `fileExists`, not `isExecutable`) but we set
            // the bit anyway so the test exercises a realistic file.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: scriptPath)
        }
        defer {
            try? FileManager.default.removeItem(atPath: scriptPath)
        }

        // Seed: add one macro and register it (same flow as testAddMacroScript).
        let addButton = app.buttons["macro.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Add Macro button not found (seed)")
        addButton.click()
        Thread.sleep(forTimeInterval: 0.5)
        let nameField = app.textFields["macro.0.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Macro row name field not found")
        nameField.click()
        nameField.typeText("X")
        let saveButton = app.buttons["macro.0.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3), "Macro Save button not found (seed)")
        saveButton.click()
        let confirmSave = app.buttons["macro.0.confirm.save"]
        XCTAssertTrue(confirmSave.waitForExistence(timeout: 5), "Confirm-Save button not found (seed)")
        confirmSave.click()
        Thread.sleep(forTimeInterval: 1.0)

        // Switch the source type from "Inline shell" to "Script file".
        // SwiftUI `.pickerStyle(.segmented)` inside a macOS Form renders as
        // an NSMatrix-style RadioGroup (not NSSegmentedControl); each option
        // is exposed to AX as a RadioButton with the option's label. The
        // `accessibilityIdentifier("macro.0.sourceType")` we put on the
        // Picker surfaces on the RadioGroup element. We tap the
        // "Script file" RadioButton to flip the source type.
        let sourceTypeGroup = app.radioGroups["macro.0.sourceType"]
        XCTAssertTrue(sourceTypeGroup.waitForExistence(timeout: 5),
                      "Source type radio group not found; dumping tree:\n\(app.debugDescription)")
        let scriptFileRadio = sourceTypeGroup.radioButtons["Script file"]
        XCTAssertTrue(scriptFileRadio.waitForExistence(timeout: 3), "'Script file' radio button not found")
        scriptFileRadio.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Now the inline editor is hidden and the path TextField + Browse
        // button are shown. Enter the absolute path to the home script.
        let pathField = app.textFields["macro.0.path"]
        XCTAssertTrue(pathField.waitForExistence(timeout: 5), "Path TextField not found after switching to Script file")
        pathField.click()
        Thread.sleep(forTimeInterval: 0.3)
        pathField.typeText(scriptPath)
        Thread.sleep(forTimeInterval: 0.5)

        // Save the edit; the confirmation dialog appears because the
        // file-mode fingerprint is captured at confirm-save time too.
        let saveButtonEdit = app.buttons["macro.0.save"]
        XCTAssertTrue(saveButtonEdit.waitForExistence(timeout: 3), "Macro Save button not found (file)")
        XCTAssertTrue(saveButtonEdit.isEnabled, "Macro Save should be enabled after entering the path")
        saveButtonEdit.click()
        let confirmSaveEdit = app.buttons["macro.0.confirm.save"]
        XCTAssertTrue(confirmSaveEdit.waitForExistence(timeout: 5), "Confirm-Save button not found (file)")
        confirmSaveEdit.click()
        Thread.sleep(forTimeInterval: 1.0)

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
