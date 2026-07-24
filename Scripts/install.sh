#!/bin/bash
#
# ClipboardManager install script
#
# Downloads the appropriate release archive for the running Mac's
# architecture, extracts the .app bundle, installs it into
# /Applications, and strips the macOS quarantine attribute.
#
# Usage:
#   Scripts/install.sh [version] [--app /path/to/dest]
#
#   version  GitHub release tag (e.g. 1.2.0). Defaults to "latest".
#   --app    Destination .app path. Defaults to /Applications/ClipboardManager.app.
#
set -euo pipefail

REPO="xshoji/clipboard-manager"
APP_NAME="ClipboardManager"
DEST_APP="/Applications/${APP_NAME}.app"

VERSION="latest"
while [ $# -gt 0 ]; do
    case "$1" in
        --app)
            DEST_APP="$2"
            shift 2
            ;;
        --app=*)
            DEST_APP="${1#--app=}"
            shift
            ;;
        -h|--help)
            sed -n '2,14p' "$0"
            exit 0
            ;;
        *)
            VERSION="$1"
            shift
            ;;
    esac
done

# --- architecture detection -------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
    arm64)      ARCH_TAG="arm64"   ;;
    x86_64)     ARCH_TAG="x86_64"  ;;
    *)
        echo "error: unsupported architecture: $ARCH" >&2
        exit 1
        ;;
esac
echo "detected architecture: ${ARCH} (${ARCH_TAG})"

# --- resolve release tag ----------------------------------------------------
if [ "$VERSION" = "latest" ]; then
    echo "resolving latest release..."
    VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep -m1 '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')"
    if [ -z "$VERSION" ]; then
        echo "error: could not resolve latest release tag" >&2
        exit 1
    fi
fi
echo "installing version: ${VERSION}"

# --- download ---------------------------------------------------------------
ASSET="ClipboardManager-${ARCH_TAG}.zip"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ZIP_FILE="${TMP_DIR}/${ASSET}"

echo "downloading ${DOWNLOAD_URL}"
if ! curl -fSL --progress-bar -o "$ZIP_FILE" "$DOWNLOAD_URL"; then
    echo "error: download failed for ${ASSET}" >&2
    echo "hint: confirm the asset exists for tag ${VERSION} and arch ${ARCH_TAG}" >&2
    exit 1
fi

# --- extract ----------------------------------------------------------------
echo "extracting..."
if ! unzip -q -o "$ZIP_FILE" -d "$TMP_DIR"; then
    echo "error: extraction failed" >&2
    exit 1
fi

EXTRACTED_APP="$(find "$TMP_DIR" -maxdepth 2 -name "${APP_NAME}.app" -type d | head -n1)"
if [ -z "$EXTRACTED_APP" ]; then
    echo "error: ${APP_NAME}.app not found in archive" >&2
    exit 1
fi

# --- install ----------------------------------------------------------------
echo "installing to ${DEST_APP}"
if [ -e "$DEST_APP" ]; then
    rm -rf "$DEST_APP"
fi
mkdir -p "$(dirname "$DEST_APP")"
cp -R "$EXTRACTED_APP" "$DEST_APP"

# --- strip quarantine -------------------------------------------------------
echo "removing quarantine attribute..."
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

echo "done: ${DEST_APP} (version ${VERSION}, ${ARCH_TAG})"
