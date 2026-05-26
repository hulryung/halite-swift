#!/usr/bin/env bash
# sign-and-notarize.sh — dist/Halite.app을 codesign으로 Developer ID
# Application 서명 → notarytool로 Apple에 노타라이즈 제출 → 결과를 stapler로
# 번들에 박음.
#
# 필요한 환경변수 (필수):
#   APPLE_SIGNING_IDENTITY  — 예: "Developer ID Application: Daekeun Kang (TEAMID)"
#                             (security find-identity -p codesigning -v 로 확인)
#   APPLE_TEAM_ID           — 예: "ABCDE12345"
#
#   다음 둘 중 하나:
#   (a) APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD
#       app-specific password는 https://appleid.apple.com 에서 발급
#   (b) NOTARY_KEYCHAIN_PROFILE
#       먼저 `xcrun notarytool store-credentials <profile>` 로 keychain에 저장
#
# 사용:
#   ./scripts/build-app.sh
#   ./scripts/sign-and-notarize.sh
#
# 옵션:
#   SKIP_NOTARIZE=1  — codesign만 하고 stapler/notarytool은 건너뜀.
#                      (로컬 테스트용; 배포본은 반드시 노타라이즈 필요)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_ROOT/dist/Halite.app"
ENTITLEMENTS="$REPO_ROOT/Resources/Halite.entitlements"

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

echo "==> codesign nested CLI"
# nested executable 먼저 (deep signing의 inner-to-outer 규칙).
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$APPLE_SIGNING_IDENTITY" \
    "$APP/Contents/Resources/halite-cli"

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

# 노타라이즈는 .zip 또는 .dmg를 받음. 여기선 임시 .zip으로 제출 (가장 빠름).
ZIP="$REPO_ROOT/dist/Halite-notarize.zip"
rm -f "$ZIP"
echo "==> ditto $APP -> $ZIP"
( cd "$REPO_ROOT/dist" && ditto -c -k --keepParent "Halite.app" "$ZIP" )

echo "==> xcrun notarytool submit (this can take a few minutes)"
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
