#!/usr/bin/env bash
# install-local.sh — 로컬 dogfooding용 원샷 설치.
# release .app 빌드 → 코드서명 → /Applications에 설치 → 실행.
#
# 기본은 ad-hoc 서명(이 Mac 전용, 본인 머신에서 바로 실행 가능). Developer ID
# 정식 서명/노타라이즈/배포는 scripts/sign-and-notarize.sh를 쓴다 — 이 스크립트는
# "내 Mac에 깔아서 써보기" 전용이라 Sparkle 자동업데이트/타 Mac 배포는 안 된다.
#
# 환경변수:
#   SIGN_IDENTITY   — codesign -s 값. 기본 "-"(ad-hoc).
#                     Developer ID로 서명하려면 예:
#                     SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)"
#                     (security find-identity -p codesigning -v 로 확인)
#   INSTALL_DIR     — 설치 위치. 기본 /Applications
#   MARKETING_VERSION — Info.plist 버전. 기본 0.1.0
#   NO_LAUNCH=1     — 설치 후 실행하지 않음
#
# 사용:
#   ./scripts/install-local.sh
#   SIGN_IDENTITY="Developer ID Application: Daekeun Kang (TEAMID)" ./scripts/install-local.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
APP="$REPO_ROOT/dist/Damson.app"
ENTITLEMENTS="$REPO_ROOT/Resources/Damson.entitlements"
HASH="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
DEST="$INSTALL_DIR/Damson.app"

[[ -f "$ENTITLEMENTS" ]] || { echo "error: missing $ENTITLEMENTS" >&2; exit 1; }

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> sign: ad-hoc (this Mac only — no auto-update, no distribution)"
else
    echo "==> sign: $SIGN_IDENTITY"
fi

# 1) release .app 빌드 (CLEAN으로 stale 잔재 제거, BUILD_NUMBER에 git hash).
echo "==> build release .app @ $HASH"
CLEAN=1 MARKETING_VERSION="$MARKETING_VERSION" BUILD_NUMBER="$HASH" \
    ./scripts/build-app.sh >/dev/null
[[ -d "$APP" ]] || { echo "error: build produced no $APP" >&2; exit 1; }

# 2) 코드서명 — 중첩 프레임워크(Sparkle 등)를 먼저, 그다음 앱 번들.
#    Hardened Runtime(--options runtime)으로 정식 서명 구성과 동일하게 서명한다.
echo "==> codesign frameworks + app"
if [[ -d "$APP/Contents/Frameworks" ]]; then
    find "$APP/Contents/Frameworks" -maxdepth 1 -name "*.framework" -print0 \
        | while IFS= read -r -d '' fw; do
            codesign --force --options runtime --sign "$SIGN_IDENTITY" "$fw"
        done
fi
codesign --force --deep --options runtime \
    --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"

echo "==> verify signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -1

# 3) 설치 — 실행 중 인스턴스를 종료하고 교체. quarantine 비트 제거(로컬 빌드라
#    보통 없지만, 있으면 첫 실행 Gatekeeper 프롬프트가 뜸).
echo "==> install to $DEST"
pkill -f "Damson.app/Contents/MacOS/damson" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> installed: $DEST  (0.1.0 / $HASH)"

# 4) 실행 (NO_LAUNCH로 생략 가능).
if [[ "${NO_LAUNCH:-0}" != "1" ]]; then
    echo "==> launching"
    open -a "$DEST"
fi
