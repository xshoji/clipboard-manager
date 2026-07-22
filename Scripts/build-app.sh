#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
ARCH="${2:-}"
# Optional 3rd argument: codesign identity (Team ID or certificate name).
# When omitted, falls back to ad-hoc signing ("-").
SIGN_IDENTITY="${3:-}"

usage() {
    echo "Usage: $0 [debug|release] [arch] [sign-identity]" >&2
    echo "  sign-identity: codesign identity (e.g. Team ID \"9********3\"). Defaults to ad-hoc (\"-\")." >&2
}

case "$CONFIGURATION" in
    debug|release) ;;
    *)
        usage
        exit 2
        ;;
esac

cd "$ROOT_DIR"

BUILD_ARGS=(--configuration "$CONFIGURATION")
if [ -n "$ARCH" ]; then
    BUILD_ARGS+=(--arch "$ARCH")
fi

swift build "${BUILD_ARGS[@]}" >/dev/stderr
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path 2>/dev/null)"
APP_BUNDLE="$BIN_DIR/ClipboardManager.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS_DIR/MacOS" "$RESOURCES_DIR"

cp "$BIN_DIR/ClipboardManager" "$CONTENTS_DIR/MacOS/ClipboardManager"
cp "$ROOT_DIR/ClipboardManager/App/Info.plist" "$CONTENTS_DIR/Info.plist"

# Color("...") などが通常の .app の main bundle から参照できるよう Assets.car を生成する。
ASSET_LOG="$(mktemp)"
ASSET_PARTIAL_PLIST="$(mktemp)"
trap 'rm -f "$ASSET_LOG" "$ASSET_PARTIAL_PLIST"' EXIT
if ! xcrun actool \
    "$ROOT_DIR/ClipboardManager/Resources/Assets.xcassets" \
    --compile "$RESOURCES_DIR" \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ASSET_PARTIAL_PLIST" \
    --output-format human-readable-text \
    >"$ASSET_LOG" 2>&1; then
    cat "$ASSET_LOG" >&2
    exit 1
fi
/usr/libexec/PlistBuddy -c "Merge $ASSET_PARTIAL_PLIST" "$CONTENTS_DIR/Info.plist"

# Code signing: use the provided identity (Team ID / certificate name) if given,
# otherwise fall back to ad-hoc signing ("-").
CODESIGN_IDENTITY="${SIGN_IDENTITY:--}"
echo "Code signing with identity: $CODESIGN_IDENTITY"
codesign --force --deep --sign "$CODESIGN_IDENTITY" \
    --identifier com.xshoji.ClipboardManager \
    "$APP_BUNDLE"

echo "$APP_BUNDLE"
