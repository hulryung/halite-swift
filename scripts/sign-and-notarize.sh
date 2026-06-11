#!/usr/bin/env bash
# sign-and-notarize.sh — codesign dist/Damson.app with a Developer ID Application
# identity → submit to Apple for notarization via notarytool → staple the result
# into the bundle.
#
# Required environment variables:
#   APPLE_SIGNING_IDENTITY  — e.g. "Developer ID Application: Daekeun Kang (TEAMID)"
#                             (check with security find-identity -p codesigning -v)
#   APPLE_TEAM_ID           — e.g. "ABCDE12345"
#
#   One of the following two:
#   (a) APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD
#       Issue an app-specific password at https://appleid.apple.com
#   (b) NOTARY_KEYCHAIN_PROFILE
#       First store it in the keychain via `xcrun notarytool store-credentials <profile>`
#
# Usage:
#   ./scripts/build-app.sh
#   ./scripts/sign-and-notarize.sh
#
# Options:
#   SKIP_NOTARIZE=1  — only codesign, skip stapler/notarytool.
#                      (for local testing; distribution builds must be notarized)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_ROOT/dist/Damson.app"
ENTITLEMENTS="$REPO_ROOT/Resources/Damson.entitlements"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found. Run scripts/build-app.sh first." >&2
    exit 1
fi
if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "error: missing $ENTITLEMENTS" >&2
    exit 1
fi

if [[ -z "${APPLE_SIGNING_IDENTITY:-}" ]]; then
    echo "error: set APPLE_SIGNING_IDENTITY" >&2
    echo "       e.g. APPLE_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'" >&2
    echo "       (find with: security find-identity -p codesigning -v)" >&2
    exit 1
fi

echo "==> codesign nested executables + frameworks (inner → outer)"

# Sparkle.framework — sign all nested components in inner → outer order.
# Sparkle 2.x structure (Versions/Current/):
#   XPCServices/Downloader.xpc, Installer.xpc
#   Updater.app  (nested app — includes its MacOS/Updater binary)
#   Autoupdate   (helper binary)
#   Sparkle      (the framework proper)
# If any one is missing, notarization fails as Invalid with "not signed with valid
# Developer ID" / "no secure timestamp".
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
    SV="$SPARKLE_FW/Versions/Current"
    for xpc in "$SV/XPCServices/"*.xpc; do
        [[ -e "$xpc" ]] || continue
        echo "  + $xpc"
        codesign --force --options runtime --timestamp \
            --sign "$APPLE_SIGNING_IDENTITY" "$xpc"
    done
    if [[ -d "$SV/Updater.app" ]]; then
        echo "  + $SV/Updater.app"
        codesign --force --options runtime --timestamp \
            --sign "$APPLE_SIGNING_IDENTITY" "$SV/Updater.app"
    fi
    if [[ -f "$SV/Autoupdate" ]]; then
        echo "  + $SV/Autoupdate"
        codesign --force --options runtime --timestamp \
            --sign "$APPLE_SIGNING_IDENTITY" "$SV/Autoupdate"
    fi
    echo "  + $SPARKLE_FW"
    codesign --force --options runtime --timestamp \
        --sign "$APPLE_SIGNING_IDENTITY" "$SPARKLE_FW"
fi

# damson-cli — nested executable.
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$APPLE_SIGNING_IDENTITY" \
    "$APP/Contents/Resources/damson-cli"

echo "==> codesign main bundle"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$APPLE_SIGNING_IDENTITY" \
    "$APP"

echo "==> verify signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --verbose=4 "$APP" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Sealed|Timestamp" | head -10

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo ""
    echo "==> SKIP_NOTARIZE=1 — leaving unstapled"
    exit 0
fi

# Notarization accepts a .zip or .dmg. Here we submit a temporary .zip (fastest).
ZIP="$REPO_ROOT/dist/Damson-notarize.zip"
rm -f "$ZIP"
echo "==> ditto $APP -> $ZIP"
( cd "$REPO_ROOT/dist" && ditto -c -k --keepParent "Damson.app" "$ZIP" )

echo "==> xcrun notarytool submit --timeout 30m (this can take a few minutes)"
NOTARY_ARGS=()
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    NOTARY_ARGS=(
        --apple-id "$APPLE_ID"
        --password "$APPLE_APP_SPECIFIC_PASSWORD"
        --team-id "$APPLE_TEAM_ID"
    )
else
    echo "error: set NOTARY_KEYCHAIN_PROFILE, OR APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID" >&2
    exit 1
fi

xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait

echo "==> staple ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 | tail -3

rm -f "$ZIP"
echo ""
echo "==> signed + notarized: $APP"
