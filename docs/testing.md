# Testing

## Purpose

This document is the source of truth for ClipboardManager's test architecture,
E2E isolation contract, local prerequisites, and execution rules. Test code and
configuration must not weaken the production-resource boundaries defined here.

## Test tracks

### Production build

`Package.swift` defines the production executable and resource build:

```bash
swift build
```

`Package.swift` includes `ClipboardManagerTests` for deterministic unit and
contract coverage of view models, paste orchestration, validators, filtering,
and formatting. These tests do not launch the app or occupy the interactive
desktop:

```bash
swift test
```

Infrastructure integration coverage remains planned; see
`docs/remaining-features.md`.

`Scripts/build-app.sh` uses the same Swift package track for local app bundles
and GitHub Releases. It embeds `ClipboardHTMLRenderer` under `Contents/Helpers`;
the Xcode/E2E track builds and embeds the same helper from `project.yml`. Do not
add Xcode-only production behavior to the E2E project configuration.

### E2E UI smoke tests

The UI smoke suite is an XCUITest target defined by `project.yml` and generated
with XcodeGen. `Scripts/run-e2e-tests.sh` wraps project generation and
`xcodebuild test`.

```bash
# All UI smoke tests
Scripts/run-e2e-tests.sh

# One focused test
Scripts/run-e2e-tests.sh SmokeUITests/testSettingsAndHotkeyWorkflows
```

The generated `ClipboardManager.xcodeproj` and workspaces are disposable and
gitignored. `project.yml` is their source of truth.

## Local prerequisites

1. macOS 14 or later and Xcode 15 or later.
2. XcodeGen installed with `brew install xcodegen`.
3. UI Automation allowed without interactive authentication. Configure this
   machine once with:

   ```bash
   sudo automationmodetool enable-automationmode-without-authentication
   ```

   Without this setting, a non-interactive run cannot answer macOS's "Enable UI
   Automation" authentication request. XCTest then waits for 60 seconds and
   fails before any test starts with `Timed out while enabling automation mode`.
   `Scripts/run-e2e-tests.sh` detects that state and exits immediately with the
   setup command.
4. Accessibility permission for the terminal or IDE that invokes the tests.
5. Accessibility permission for the E2E app bundle when macOS prompts for it.
6. Optionally, a Personal Team ID passed as `DEVELOPMENT_TEAM=...` to keep the
   E2E app's TCC identity stable across rebuilds.

Example:

```bash
DEVELOPMENT_TEAM=ABCD1234 \
  Scripts/run-e2e-tests.sh SmokeUITests/testHistoryListWorkflows
```

The runner also accepts:

- `XCODE_CONFIG`: `Debug` by default; `Release` is supported.
- `XCODE_DESTINATION`: `platform=macOS` by default.

## E2E host identity

The E2E host reuses the production source tree but has dedicated packaging:

| Property | Production | E2E |
|---|---|---|
| Bundle ID | `com.xshoji.ClipboardManager` | `com.xshoji.ClipboardManager.E2E` |
| Info.plist | `ClipboardManager/App/Info.plist` | `ClipboardManager/App/Info.E2E.plist` |
| UserDefaults domain | Production bundle domain | E2E bundle domain, reset before each case |
| SwiftData | Application Support production store | Per-case temporary persistent store |
| Pasteboard | `NSPasteboard.general` | Per-case prefixed named pasteboard |
| Preview editing | Enabled | Disabled |

The E2E plist keeps production-relevant process behavior such as `LSUIElement`,
`NSPrincipalClass`, minimum OS, and termination settings. Only identity and
test-host-specific packaging should differ.

## Isolation contract

Every E2E case must be isolated from the user's production process and data.
This contract takes priority over test convenience or coverage.

### SwiftData

`SmokeUITests.setUpWithError()` creates a unique directory under:

```text
~/Library/Containers/com.xshoji.SmokeUITests.xctrunner/Data/Library/Caches/
  com.xshoji.ClipboardManager.E2E/<case-uuid>/
```

The XCUITest runner is containerized by macOS even though the E2E host target is
not sandboxed. Its container Caches directory is stable across the runner and
launched app, while their `TMPDIR` and ordinary Caches URLs are not. The E2E
host receives `Clipboard.store` in that directory. Before opening SwiftData,
the host verifies that the path:

- is absolute;
- has an existing directory parent;
- resolves under the E2E Caches root after standardization and symlink
  resolution;
- has the `.store` extension; and
- is not under the production Application Support directory.

Missing or invalid E2E storage configuration is a fatal startup error. The E2E
host must never fall back to the production store or an unrequested in-memory
store.

The temporary store is persistent for the lifetime of a test case, so a future
same-case relaunch can verify persistence. Different cases never share it.

### Pasteboard

Each case creates a named pasteboard whose name starts with:

```text
com.xshoji.ClipboardManager.E2E.
```

The test runner and E2E host use the same pasteboard instance for seeding,
monitoring, suppression, Copy, Plain Text, OCR, and Macro output. The E2E host
rejects empty names, the general pasteboard, and names without the required
prefix.

These smoke tests verify orchestration through an injected pasteboard. They do
not verify integration with another application's `NSPasteboard.general`.
System-clipboard integration tests, if added, must be opt-in and run only under
a dedicated macOS user or virtual machine.

### UserDefaults

The E2E bundle ID gives `UserDefaults.standard` a domain separate from
production. The host removes that entire persistent domain before
`AppSettings.shared` is initialized for each case. E2E-only hotkey values are
then applied before Carbon registration and window creation.

Do not replace the domain reset with a manually maintained list of settings
keys; new settings would otherwise leak state between test cases.

### Production and stale processes

Before generating or building the test project, `Scripts/run-e2e-tests.sh`
requests normal termination of:

- the production bundle ID; and
- a directly launched executable named `ClipboardManager`, including
  `swift run` or `.build/.../ClipboardManager`.

The runner waits up to five seconds for those processes to exit and fails
without force-terminating them if normal termination does not complete. This
prevents production hotkeys and windows from competing with UI automation while
allowing the normal local workflow to start with the menu-bar app running.

`SmokeUITests.setUpWithError()` retains the same process check as a fail-closed
safety net for direct `xcodebuild test` invocations that bypass the runner. The
test bundle never terminates a production process. It may terminate stale
instances of the E2E bundle only, and must confirm their death before
continuing.

### Preview editing

The E2E host disables Preview image editing. Production no longer performs
startup or periodic orphan cleanup because a preserved working file may be the
only recoverable copy after a failed save or interrupted shutdown. This prevents
tests from opening or replacing production working files under Downloads.

If Preview editing receives E2E coverage in the future, inject a test-specific
working directory instead of enabling the production integration.

### Teardown

Teardown follows this order:

1. Request E2E app termination.
2. Wait for process death with a bounded timeout.
3. Force-terminate E2E instances if graceful termination times out.
4. Confirm process death again.
5. Release the named pasteboard and remove the case UUID directory.

If process death cannot be confirmed, teardown reports a failure and preserves
the temporary resources rather than deleting files still in use.

## Internal launch environment

`SmokeUITests.makeApp()` supplies these values. They are internal test-harness
configuration and normally should not be set by developers manually.

| Variable | Contract |
|---|---|
| `CM_E2E_OPEN_WINDOW=1` | Enables the validated E2E launch path and opens the main and Settings windows. |
| `CM_E2E_STORE_PATH` | Absolute `.store` path under the per-case E2E temporary directory. |
| `CM_E2E_PASTEBOARD_NAME` | Per-case pasteboard name with the required E2E prefix. |

All three values are required for the E2E bundle in Debug and Release builds.
Production bundles ignore them and retain production storage and pasteboard
behavior.

## Execution policy

- `Scripts/run-e2e-tests.sh` passes `-parallel-testing-enabled NO`. The cases
  share an E2E bundle ID, Carbon registration namespace, and defaults domain,
  so they must not run in parallel.
- Run the smallest relevant case during iteration. Run the full suite only
  when combined workflow coverage is necessary.
- Settings/default/hotkey checks share one launch, as do keyboard/search/image
  filter checks. Keep workflows together when they can safely share isolated
  case state; keep expensive or side-effect-heavy OCR and Macro execution cases
  separate so failures remain diagnosable.
- XCUITest is local-only until a dedicated runner can satisfy signing, TCC, and
  Accessibility requirements. It is not part of the current GitHub Actions
  pipeline.
- Never clear production clipboard history, user directories, or the system
  pasteboard as test setup.
- Seed values, macro names, and temporary filenames must be unique enough to
  avoid deduplication and collisions. Delete only resources created by the
  current case.

## Test-layer selection criteria

Choose the lowest test layer that can observe the behavior under test without
reimplementing production behavior in the test. A behavior being unit-testable
does not by itself justify removing the representative E2E workflow that proves
the UI is wired to it.

### Use a unit test when

- The result is determined by explicit inputs, model state, or responses from
  injected ports.
- OS effects such as pasteboard writes, app activation, notifications, OCR, or
  Macro execution can be represented by fakes while preserving the behavior
  being asserted.
- The test does not need a rendered SwiftUI hierarchy, an AppKit window, the
  current first responder, Accessibility exposure, or real keyboard events.
- The behavior has multiple data or error combinations that would be slow and
  brittle to enumerate through the UI.

Typical unit-test subjects include:

- validators, search and image-filter predicates, selection calculations, and
  hotkey collision rules;
- view-model state transitions such as selection preservation and dirty-state
  tracking;
- `PasteCoordinator` branches using fake repository, OCR, Macro, activation,
  notification, and pasteboard ports;
- formatting and default-value rules.

Unit tests should cover branch combinations and failure policy exhaustively.
They must not assert SwiftUI implementation details or reproduce view event
routing in a test-only model merely to avoid an E2E test.

### Use an E2E UI test when

- Correctness depends on actual focus or first-responder behavior, including
  whether typed input reaches the intended control after a SwiftUI update.
- The behavior crosses a real window, sheet, alert, menu, or window lifecycle
  boundary.
- The assertion concerns the Accessibility hierarchy, identifiers, values, or
  element hittability exposed by the built app.
- The workflow requires real keyboard routing, `XCUIApplication`, Carbon
  hotkey registration or dispatch, or interaction between SwiftUI and AppKit.
- The primary risk is integration wiring or timing: each component can be
  correct independently while the user-visible workflow still fails.

Typical E2E subjects include:

- moving focus between the search field and history list and then proving that
  subsequent keystrokes reach the expected control;
- recording a real shortcut, handling Escape, and surfacing a Carbon
  registration failure;
- closing a Settings window with unsaved changes and operating the resulting
  native alert;
- registering a Macro through Settings and launching it from the Footer menu;
- proving that asynchronous OCR completion refreshes the rendered search
  result and that the action hotkey reaches the selected item.

E2E tests should cover a small number of representative user workflows, not
every input and failure combination. Assert externally observable outcomes and
state the platform or UI boundary that requires E2E coverage. If no such
boundary exists, prefer a lower layer.

### Use a non-UI integration test when

The behavior needs a real framework or process but not a user-driven GUI. Use
temporary stores and files, named pasteboards, and controlled processes for
SwiftData persistence, clipboard-monitor suppression, Vision recognition,
Macro process execution, fingerprints, timeouts, and UserDefaults round trips.
These tests complement unit tests without occupying the interactive desktop.

### Keep responsibilities distinct

When one workflow spans multiple layers, split assertions by responsibility:

| Question | Preferred layer |
|---|---|
| Does the search predicate match OCR text and exclude text rows in image-only mode? | Unit |
| Does typing in the search field rebuild the visible SwiftUI list? | E2E |
| Does cached OCR skip recognition and write the cached text? | Unit |
| Does the action hotkey reach the selected image and produce visible workflow output? | E2E |
| Does a Macro failure restore the original value for the configured policy? | Unit |
| Can a registered Macro be selected from the real Footer menu? | E2E |
| Does an actual script receive `CB_INPUT_FILE` and write `CB_OUTPUT_FILE`? | Non-UI integration |

Do not duplicate the same implementation-level assertion at every layer. Unit
tests establish rules and failure behavior; integration tests establish
framework adapters; E2E tests establish user-visible wiring, focus, and native
UI behavior.

## UI smoke-test rules

- Test observable user workflows rather than implementation details.
- Keep accessibility identifiers stable and semantic. Query by identifier,
  not element order, except for native controls without stable identities such
  as window traffic-light buttons.
- Re-query SwiftUI elements after actions that can rebuild a list or filtered
  view; accessibility elements are snapshots.
- Send keyboard events through `XCUIApplication` when focus can move during a
  SwiftUI update.
- Reuse `exists(_:timeout:)` to avoid XCTest's initial polling delay.
- Prefer bounded polling of observable state over fixed worst-case sleeps.
  Keep fixed sleeps limited to short SwiftUI propagation turns where no
  observable state is available.
- Keep typed payloads short because XCUITest enters text character by character
  and SwiftUI may recompute for every character.
- Verify externally observable results, such as Macro output on the case's
  named pasteboard, rather than adding test-only application side channels.

Successful paste and Macro operations intentionally activate the previously
frontmost app. Tests must not require the ClipboardManager window to remain key
after those operations.

## Non-interactive compile validation

The app and XCUITest source can be compiled without launching the UI suite:

```bash
swift build

xcodegen generate
xcodebuild build-for-testing \
  -project ClipboardManager.xcodeproj \
  -scheme SmokeUITests \
  -configuration Debug \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO
```

This validates compilation only. It does not verify Accessibility exposure,
Carbon event delivery, Vision OCR, focus behavior, or UI workflow assertions.

## Planned test layers

The desired long-term structure is:

1. Unit and contract tests for view models, paste orchestration, validators,
   and pure behavior using fake ports.
2. Infrastructure integration tests using temporary SwiftData stores, named
   pasteboards, and controlled processes for limits, migration, timeout, and
   failure handling.
3. A small XCUITest smoke layer for workflows that require real SwiftUI,
   accessibility, focus, Carbon hotkeys, or Vision integration.

The implementation backlog is tracked in `docs/remaining-features.md`.
