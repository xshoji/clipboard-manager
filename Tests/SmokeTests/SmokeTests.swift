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

    // MARK: - Setup / Teardown

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        Self.terminateRunningApps()
    }

    // MARK: - Tests

    func testAppLaunchesWithoutCrash() throws {
        let app = makeApp()
        app.launch()
        Thread.sleep(forTimeInterval: startupSeconds)
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground,
                      "App crashed within \(startupSeconds)s (state=\(app.state.rawValue))")
        app.terminate()
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
        app.terminate()
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
        app.terminate()
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
        app.terminate()
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
        app.terminate()
    }

    // MARK: - App Launcher

    /// Builds an XCUIApplication preconfigured with the E2E bundle id and the
    /// `CM_E2E_OPEN_WINDOW=1` launch environment so AppDelegate forces the
    /// action hotkey defaults, prompts for Accessibility, and opens the main
    /// window and the Settings window immediately on launch.
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Self.e2eBundleID)
        app.launchEnvironment["CM_E2E_OPEN_WINDOW"] = "1"
        return app
    }

    // MARK: - Shell Helpers

    private static func terminateRunningApps() {
        for bid in [productionBundleID, e2eBundleID] {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            guard !apps.isEmpty else { continue }
            Self.log("Terminating \(apps.count) running app instance(s) for \(bid)")
            for app in apps { app.terminate() }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    // MARK: - Logging

    private static func log(_ msg: String) {
        FileHandle.standardError.write("[SmokeUITests] \(msg)\n".data(using: .utf8)!)
    }
}
