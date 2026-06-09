#!/usr/bin/env bash
# build-app.sh — runs swift build -c release, then packages the two resulting
# binaries (damson, damson-cli) into a proper .app bundle structure.
#
# Output: $REPO/dist/Damson.app
#
# Environment variables:
#   MARKETING_VERSION   — Info.plist CFBundleShortVersionString (default: 0.1.0)
#   BUILD_NUMBER        — Info.plist CFBundleVersion (default: epoch seconds)
#   CLEAN=1             — wipe dist/ entirely before each run
#
# Usage:
#   ./scripts/build-app.sh
#   MARKETING_VERSION=0.2.0 ./scripts/build-app.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%s)}"

DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist}"
APP_DIR="$DIST_DIR/Damson.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

if [[ "${CLEAN:-0}" == "1" ]]; then
    rm -rf "$DIST_DIR"
fi

echo "==> swift build -c release"
swift build -c release --product damson
swift build -c release --product damson-cli

# To build an arm64 + x86_64 universal binary, add --arch arm64 --arch x86_64
# (for now only the build machine's architecture; CI handles universal).

BIN_DIR="$(swift build -c release --show-bin-path)"
DAMSON_BIN="$BIN_DIR/damson"
CLI_BIN="$BIN_DIR/damson-cli"

if [[ ! -x "$DAMSON_BIN" || ! -x "$CLI_BIN" ]]; then
    echo "error: built binaries missing under $BIN_DIR" >&2
    exit 1
fi

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# The executable proper.
cp "$DAMSON_BIN" "$MACOS_DIR/damson"
chmod 0755 "$MACOS_DIR/damson"

# damson-cli — placed in Resources for the user to symlink into /usr/local/bin.
# (Under Hardened Runtime + nested code signing rules, placing executables in
#  both MacOS/ and Resources/ still signs fine, so Resources/ is cleaner.)
cp "$CLI_BIN" "$RESOURCES_DIR/damson-cli"
chmod 0755 "$RESOURCES_DIR/damson-cli"

# Sparkle.framework — SwiftPM does not auto-bundle it into the .app, so copy it directly.
# The RPATH of the SwiftPM-built binary is only @loader_path (= the MacOS directory,
# which works in dev builds when the framework is a sibling of the binary), so to
# place it in the standard .app layout (Frameworks/) we must add an
# @executable_path/../Frameworks RPATH to the binary for dyld to find it.
SPARKLE_FW="$BIN_DIR/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
    FRAMEWORKS_DIR="$CONTENTS/Frameworks"
    mkdir -p "$FRAMEWORKS_DIR"
    # -R preserves symlinks (Versions/Current → A, Sparkle → Versions/Current/Sparkle, etc.).
    cp -R "$SPARKLE_FW" "$FRAMEWORKS_DIR/Sparkle.framework"
    # Add an RPATH so the standard Frameworks/ location is found (ignored if already present).
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/damson" 2>/dev/null || true
else
    echo "warning: $SPARKLE_FW missing — auto-update won't work. Check the swift build output." >&2
fi

# Info.plist — token substitution.
TEMPLATE="$REPO_ROOT/Resources/Info.plist.template"
if [[ ! -f "$TEMPLATE" ]]; then
    echo "error: missing $TEMPLATE" >&2
    exit 1
fi
# Sparkle public key — receives the one-time-generated EdDSA public key via env.
# If absent, the placeholder token is left as-is so auto-update does not work (fine for dev builds).
SPARKLE_KEY="${SPARKLE_PUBLIC_KEY:-__SPARKLE_PUBLIC_KEY__}"
# git hash + build channel — dev builds show the hash in the window to distinguish from release.
GIT_HASH="${GIT_HASH:-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
BUILD_CHANNEL="${BUILD_CHANNEL:-release}"
# Build time — release builds show it in the top-right of the window (same spot as dev's git hash).
BUILD_DATE="${BUILD_DATE:-$(date '+%Y-%m-%d %H:%M')}"
sed -e "s|__MARKETING_VERSION__|$MARKETING_VERSION|g" \
    -e "s|__BUILD_NUMBER__|$BUILD_NUMBER|g" \
    -e "s|__SPARKLE_PUBLIC_KEY__|$SPARKLE_KEY|g" \
    -e "s|__GIT_HASH__|$GIT_HASH|g" \
    -e "s|__BUILD_CHANNEL__|$BUILD_CHANNEL|g" \
    -e "s|__BUILD_DATE__|$BUILD_DATE|g" \
    "$TEMPLATE" > "$CONTENTS/Info.plist"

# Icon — copy Damson.icns to satisfy the template's CFBundleIconFile=Damson.
if [[ -f "$REPO_ROOT/Resources/Damson.icns" ]]; then
    cp "$REPO_ROOT/Resources/Damson.icns" "$RESOURCES_DIR/Damson.icns"
fi

# Entitlements are applied at the sign step via codesign --entitlements — not embedded in the bundle.

echo "==> verifying bundle"
plutil -lint "$CONTENTS/Info.plist" > /dev/null
file "$MACOS_DIR/damson" | head -1
file "$RESOURCES_DIR/damson-cli" | head -1

# Trampoline self-consistency — when the built binary is inside the .app, the
# trampoline detects this via isInsideAppBundle() and skips, so there's no extra wrap. OK.

echo ""
echo "==> done"
echo "App path: $APP_DIR"
echo "Version: $MARKETING_VERSION ($BUILD_NUMBER)"
