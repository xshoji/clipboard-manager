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

`Package.swift` intentionally has no `testTarget`, so `swift test` is currently
a no-op. Unit and infrastructure integration test targets are planned but not
yet implemented; see `docs/remaining-features.md`.

`Scripts/build-app.sh` uses the same Swift package track for local app bundles
and GitHub Releases. Do not add Xcode-only production behavior to the E2E
project configuration.

### E2E UI smoke tests

The UI smoke suite is an XCUITest target defined by `project.yml` and generated
with XcodeGen. `Scripts/run-e2e-tests.sh` wraps project generation and
`xcodebuild test`.

```bash
# All UI smoke tests
Scripts/run-e2e-tests.sh

# One focused test
Scripts/run-e2e-tests.sh SmokeUITests/testActionHotkeyWorkflow
```

The generated `ClipboardManager.xcodeproj` and workspaces are disposable and
gitignored. `project.yml` is their source of truth.

## Local prerequisites

1. macOS 14 or later and Xcode 15 or later.
2. XcodeGen installed with `brew install xcodegen`.
3. Accessibility permission for the terminal or IDE that invokes the tests.
4. Accessibility permission for the E2E app bundle when macOS prompts for it.
5. Optionally, a Personal Team ID passed as `DEVELOPMENT_TEAM=...` to keep the
   E2E app's TCC identity stable across rebuilds.

Example:

```bash
DEVELOPMENT_TEAM=ABCD1234 \
  Scripts/run-e2e-tests.sh SmokeUITests/testSearchFiltersHistoryList
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
$TMPDIR/com.xshoji.ClipboardManager.E2E/<case-uuid>/
```

The E2E host receives `Clipboard.store` in that directory. Before opening
SwiftData, the host verifies that the path:

- is absolute;
- has an existing directory parent;
- resolves under the E2E temporary root after standardization and symlink
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

Before creating test resources, the runner checks for:

- the production bundle ID; and
- a directly launched executable named `ClipboardManager`, including
  `swift run` or `.build/.../ClipboardManager`.

If either is running, setup fails with a preflight error. The test harness must
never terminate a production process. It may terminate stale instances of the
E2E bundle only, and must confirm their death before continuing.

### Preview editing

The E2E host disables Preview image editing, startup orphan cleanup, and the
periodic orphan-cleanup timer. This prevents tests from opening, replacing, or
deleting production working files under Downloads.

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
- XCUITest is local-only until a dedicated runner can satisfy signing, TCC, and
  Accessibility requirements. It is not part of the current GitHub Actions
  pipeline.
- Never clear production clipboard history, user directories, or the system
  pasteboard as test setup.
- Seed values, macro names, and temporary filenames must be unique enough to
  avoid deduplication and collisions. Delete only resources created by the
  current case.

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
