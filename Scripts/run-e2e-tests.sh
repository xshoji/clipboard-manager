#!/bin/bash
# Run XCUITest-based smoke tests locally.
# Full prerequisites and isolation contract: docs/testing.md
#
# Prerequisites:
#   - `brew install xcodegen` (project.yml → .xcodeproj generation)
#   - The terminal / IDE running this script must have Accessibility permission
#     (System Settings → Privacy & Security → Accessibility).
#   - The first time the E2E app is launched, macOS will prompt for Accessibility
#     permission. Grant it once for "com.xshoji.ClipboardManager.E2E"; subsequent
#     runs reuse the same TCC entry as long as the Personal Team ID is stable.
#
# Usage:
#   Scripts/run-e2e-tests.sh                 # run all tests
#   Scripts/run-e2e-tests.sh SmokeUITests/testSettingsAndHotkeyWorkflows
#
# Optional environment variables:
#   DEVELOPMENT_TEAM   - Personal Team ID (e.g. "ABCD1234") forced on both the
#                        E2E app and the test bundle so TCC entries stay stable.
#                        Find it in Xcode → Settings → Accounts → your Apple ID.
#                        Personal (free) Apple IDs cannot issue "Mac Development"
#                        certificates, so we keep CODE_SIGN_IDENTITY="-" (ad-hoc)
#                        and only stamp the Team ID. TCC keys on
#                        (Team ID, bundle id) so ad-hoc + Team ID is sufficient.
#   XCODE_CONFIG        - "Debug" (default) or "Release". The E2E launch path
#                         in AppDelegate is guarded by the E2E bundle id AND
#                         the `CM_E2E_OPEN_WINDOW=1` launch environment (not
#                         by `#if DEBUG`), so Release builds of the E2E host
#                         also drive the Settings + main windows on launch.
#   XCODE_DESTINATION   - defaults to "platform=macOS".

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is not installed. Run 'brew install xcodegen' first." >&2
    exit 1
fi

# The production app owns global hotkeys and can receive focus while XCUITest
# drives the E2E bundle. Request a normal application termination before any
# build work, but never match or terminate the separately identified E2E host.
PRODUCTION_PIDS="$(/usr/bin/osascript -l JavaScript <<'JXA'
ObjC.import('AppKit')

const productionBundleID = 'com.xshoji.ClipboardManager'
const e2eBundleID = 'com.xshoji.ClipboardManager.E2E'
const terminatedPIDs = []

for (const app of $.NSWorkspace.sharedWorkspace.runningApplications.js) {
    const bundleID = ObjC.unwrap(app.bundleIdentifier)
    const executableURL = app.executableURL
    const executableName = executableURL ? ObjC.unwrap(executableURL.lastPathComponent) : ''
    const isProduction = bundleID === productionBundleID
        || (bundleID !== e2eBundleID && executableName === 'ClipboardManager')
    if (isProduction) {
        terminatedPIDs.push(String(app.processIdentifier))
        app.terminate
    }
}

terminatedPIDs.join(' ')
JXA
)"

if [ -n "$PRODUCTION_PIDS" ]; then
    echo "[run-e2e-tests] Stopping production ClipboardManager (PIDs: $PRODUCTION_PIDS)…"
    for _ in $(seq 1 50); do
        STILL_RUNNING=""
        for PID in $PRODUCTION_PIDS; do
            if kill -0 "$PID" 2>/dev/null; then
                STILL_RUNNING="$STILL_RUNNING $PID"
            fi
        done
        [ -z "$STILL_RUNNING" ] && break
        sleep 0.1
    done
    if [ -n "${STILL_RUNNING:-}" ]; then
        echo "error: Production ClipboardManager did not exit (PIDs:$STILL_RUNNING)." >&2
        echo "       Quit it manually, then rerun the E2E tests." >&2
        exit 1
    fi
fi

# Regenerate the .xcodeproj from project.yml so the repo stays free of generated
# project files. The project file is gitignored.
echo "[run-e2e-tests] Generating Xcode project…"
xcodegen generate >/dev/stderr

CONFIG="${XCODE_CONFIG:-Debug}"
DESTINATION="${XCODE_DESTINATION:-platform=macOS}"
TEST_TARGET="${1:-}"

XCODEBUILD_ARGS=(
    test
    -project ClipboardManager.xcodeproj
    -scheme SmokeUITests
    -configuration "$CONFIG"
    -destination "$DESTINATION"
    -parallel-testing-enabled NO
)

# Optional Personal Team ID. When set, both the host app and the test bundle are
# signed with the same dev team so TCC entries persist across rebuilds. Personal
# (free) Apple IDs cannot issue "Mac Development" certificates, so we keep
# CODE_SIGN_IDENTITY="-" (ad-hoc) and only stamp the Team ID — TCC keys on
# (Team ID, bundle id), so ad-hoc + Team ID is sufficient for stable permission.
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    XCODEBUILD_ARGS+=(
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
        CODE_SIGN_STYLE=Automatic
        CODE_SIGN_IDENTITY="-"
        CODE_SIGNING_REQUIRED=NO
        CODE_SIGNING_ALLOWED=YES
    )
fi

if [ -n "$TEST_TARGET" ]; then
    # The user passed a specific test method/class, e.g. "SmokeUITests/testFoo".
    XCODEBUILD_ARGS+=("-only-testing:SmokeUITests/$TEST_TARGET")
fi

echo "[run-e2e-tests] xcodebuild ${XCODEBUILD_ARGS[*]}"
xcodebuild "${XCODEBUILD_ARGS[@]}"
