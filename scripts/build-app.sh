#!/usr/bin/env bash
# build-app.sh — swift build -c release, 그 결과 binary 두 개(halite, halite-cli)를
# 정상 .app 번들 구조로 묶음.
#
# 출력: $REPO/dist/Halite.app
#
# 환경변수:
#   MARKETING_VERSION   — Info.plist CFBundleShortVersionString (default: 0.1.0)
#   BUILD_NUMBER        — Info.plist CFBundleVersion (default: epoch seconds)
#   CLEAN=1             — 매번 dist/ 통째로 비우고 시작
#
# 사용:
#   ./scripts/build-app.sh
#   MARKETING_VERSION=0.2.0 ./scripts/build-app.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%s)}"

DIST_DIR="$REPO_ROOT/dist"
APP_DIR="$DIST_DIR/Halite.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

if [[ "${CLEAN:-0}" == "1" ]]; then
    rm -rf "$DIST_DIR"
fi

echo "==> swift build -c release"
swift build -c release --product halite
swift build -c release --product halite-cli

# arm64 + x86_64 universal binary 만들고 싶으면 --arch arm64 --arch x86_64 추가
# (지금은 빌드 머신 아키텍처만; CI에서 universal 처리).

BIN_DIR="$(swift build -c release --show-bin-path)"
HALITE_BIN="$BIN_DIR/halite"
CLI_BIN="$BIN_DIR/halite-cli"

if [[ ! -x "$HALITE_BIN" || ! -x "$CLI_BIN" ]]; then
    echo "error: built binaries missing under $BIN_DIR" >&2
    exit 1
fi

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# 실행 가능 본체.
cp "$HALITE_BIN" "$MACOS_DIR/halite"
chmod 0755 "$MACOS_DIR/halite"

# halite-cli — Resources에 두고 사용자가 /usr/local/bin에 symlink 거는 방식.
# (Hardened Runtime + nested code signing 규칙상 MacOS/와 Resources/ 둘 다
#  나란히 실행파일을 둬도 sign이 통과되므로 Resources/가 깔끔.)
cp "$CLI_BIN" "$RESOURCES_DIR/halite-cli"
chmod 0755 "$RESOURCES_DIR/halite-cli"

# Sparkle.framework — SwiftPM이 .app으로 자동 번들 안 하므로 직접 복사.
# release dir에 SwiftPM이 link 시점에 복사해 둠 (RPATH가 @executable_path/../Frameworks).
SPARKLE_FW="$BIN_DIR/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
    FRAMEWORKS_DIR="$CONTENTS/Frameworks"
    mkdir -p "$FRAMEWORKS_DIR"
    # -R로 심볼릭 링크(Versions/Current → A, Sparkle → Versions/Current/Sparkle 등) 보존.
    cp -R "$SPARKLE_FW" "$FRAMEWORKS_DIR/Sparkle.framework"
    # XPC services (autoupdate + installer-launcher) — 이미 .framework 안에 있음.
    # 추가 작업 필요 없음.
else
    echo "warning: $SPARKLE_FW 없음 — 자동업데이트 동작 안 함. swift build 결과 확인" >&2
fi

# Info.plist — 토큰 치환.
TEMPLATE="$REPO_ROOT/Resources/Info.plist.template"
if [[ ! -f "$TEMPLATE" ]]; then
    echo "error: missing $TEMPLATE" >&2
    exit 1
fi
# Sparkle 공개키 — 1회성으로 생성한 EdDSA public key를 env로 받음.
# 없으면 placeholder 토큰을 그대로 둬서 자동업데이트는 동작 안 함 (dev 빌드 OK).
SPARKLE_KEY="${SPARKLE_PUBLIC_KEY:-__SPARKLE_PUBLIC_KEY__}"
sed -e "s|__MARKETING_VERSION__|$MARKETING_VERSION|g" \
    -e "s|__BUILD_NUMBER__|$BUILD_NUMBER|g" \
    -e "s|__SPARKLE_PUBLIC_KEY__|$SPARKLE_KEY|g" \
    "$TEMPLATE" > "$CONTENTS/Info.plist"

# 향후 아이콘: $REPO/Resources/Halite.icns가 있으면 복사.
if [[ -f "$REPO_ROOT/Resources/Halite.icns" ]]; then
    cp "$REPO_ROOT/Resources/Halite.icns" "$RESOURCES_DIR/Halite.icns"
    # Info.plist에 CFBundleIconFile 추가 필요 (template에서 처리하거나 plutil로).
    plutil -insert CFBundleIconFile -string "Halite" "$CONTENTS/Info.plist"
fi

# Entitlements는 sign 단계에서 codesign --entitlements로 적용 — 번들에는 안 들어감.

echo "==> verifying bundle"
plutil -lint "$CONTENTS/Info.plist" > /dev/null
file "$MACOS_DIR/halite" | head -1
file "$RESOURCES_DIR/halite-cli" | head -1

# Trampoline 자체 정합성 — 빌드한 binary가 .app 안에 있으면 trampoline은
# isInsideAppBundle()로 spotting하고 skip하므로 추가 wrap 없음. OK.

echo ""
echo "==> done"
echo "App path: $APP_DIR"
echo "Version: $MARKETING_VERSION ($BUILD_NUMBER)"
