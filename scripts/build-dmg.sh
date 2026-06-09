#!/usr/bin/env bash
# build-dmg.sh — dist/Damson.app을 drag-to-Applications 형태의 .dmg로 묶음.
#
# 산출물: dist/Damson-<version>.dmg
#
# hdiutil만 사용 (additional tool 의존 없음). 더 예쁜 결과 원하면 `create-dmg`로
# 교체 가능 (brew install create-dmg).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_ROOT/dist/Damson.app"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found. Run scripts/build-app.sh (and sign-and-notarize.sh) first." >&2
    exit 1
fi

# Info.plist에서 marketing version 읽기.
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"

DMG="$REPO_ROOT/dist/Damson-$VERSION.dmg"
STAGE_DIR="$(mktemp -d -t damson-dmg-stage)"
trap 'rm -rf "$STAGE_DIR"' EXIT

echo "==> staging at $STAGE_DIR"
cp -R "$APP" "$STAGE_DIR/Damson.app"
# /Applications 심볼릭 링크 — drag-to-install UX.
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG"
echo "==> hdiutil create"
hdiutil create -volname "Damson $VERSION" \
    -srcfolder "$STAGE_DIR" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG"

# 서명되어 있다면 .dmg도 codesign 추천. APPLE_SIGNING_IDENTITY set이면 진행.
if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
    echo "==> codesign dmg"
    codesign --force --sign "$APPLE_SIGNING_IDENTITY" --timestamp "$DMG"
    # .dmg는 notarytool 별도 제출 권장 (Gatekeeper online check)
    if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
        echo "==> notarize dmg"
        NOTARY_ARGS=()
        if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
            NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
        elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
            NOTARY_ARGS=(
                --apple-id "$APPLE_ID"
                --password "$APPLE_APP_SPECIFIC_PASSWORD"
                --team-id "$APPLE_TEAM_ID"
            )
        fi
        if [[ ${#NOTARY_ARGS[@]} -gt 0 ]]; then
            xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
            xcrun stapler staple "$DMG"
            xcrun stapler validate "$DMG"
        fi
    fi
fi

echo ""
echo "==> $DMG"
ls -lh "$DMG"
