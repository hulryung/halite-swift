#!/usr/bin/env bash
# build-app.sh — swift build -c release, 그 결과 binary 두 개(halite, damson-cli)를
# 정상 .app 번들 구조로 묶음.
#
# 출력: $REPO/dist/Damson.app
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

# arm64 + x86_64 universal binary 만들고 싶으면 --arch arm64 --arch x86_64 추가
# (지금은 빌드 머신 아키텍처만; CI에서 universal 처리).

BIN_DIR="$(swift build -c release --show-bin-path)"
HALITE_BIN="$BIN_DIR/damson"
CLI_BIN="$BIN_DIR/damson-cli"

if [[ ! -x "$HALITE_BIN" || ! -x "$CLI_BIN" ]]; then
    echo "error: built binaries missing under $BIN_DIR" >&2
    exit 1
fi

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# 실행 가능 본체.
cp "$HALITE_BIN" "$MACOS_DIR/damson"
chmod 0755 "$MACOS_DIR/damson"

# damson-cli — Resources에 두고 사용자가 /usr/local/bin에 symlink 거는 방식.
# (Hardened Runtime + nested code signing 규칙상 MacOS/와 Resources/ 둘 다
#  나란히 실행파일을 둬도 sign이 통과되므로 Resources/가 깔끔.)
cp "$CLI_BIN" "$RESOURCES_DIR/damson-cli"
chmod 0755 "$RESOURCES_DIR/damson-cli"

# Sparkle.framework — SwiftPM이 .app으로 자동 번들 안 하므로 직접 복사.
# SwiftPM이 빌드한 binary의 RPATH는 @loader_path(= MacOS 디렉토리, dev 빌드에서
# framework가 binary와 sibling일 때 동작) 뿐이라, 표준 .app layout(Frameworks/)에
# 두려면 binary에 @executable_path/../Frameworks RPATH를 추가해야 dyld가 찾음.
SPARKLE_FW="$BIN_DIR/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
    FRAMEWORKS_DIR="$CONTENTS/Frameworks"
    mkdir -p "$FRAMEWORKS_DIR"
    # -R로 심볼릭 링크(Versions/Current → A, Sparkle → Versions/Current/Sparkle 등) 보존.
    cp -R "$SPARKLE_FW" "$FRAMEWORKS_DIR/Sparkle.framework"
    # 표준 Frameworks/ 위치를 찾도록 RPATH 추가 (이미 있으면 무시).
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/damson" 2>/dev/null || true
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
# git hash + 빌드 채널 — dev 빌드는 윈도우에 hash를 표시해 정식과 구분.
GIT_HASH="${GIT_HASH:-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
BUILD_CHANNEL="${BUILD_CHANNEL:-release}"
# 빌드 시각 — 정식 빌드는 윈도우 우상단에 표시(dev의 git hash와 동일한 자리).
BUILD_DATE="${BUILD_DATE:-$(date '+%Y-%m-%d %H:%M')}"
sed -e "s|__MARKETING_VERSION__|$MARKETING_VERSION|g" \
    -e "s|__BUILD_NUMBER__|$BUILD_NUMBER|g" \
    -e "s|__SPARKLE_PUBLIC_KEY__|$SPARKLE_KEY|g" \
    -e "s|__GIT_HASH__|$GIT_HASH|g" \
    -e "s|__BUILD_CHANNEL__|$BUILD_CHANNEL|g" \
    -e "s|__BUILD_DATE__|$BUILD_DATE|g" \
    "$TEMPLATE" > "$CONTENTS/Info.plist"

# 아이콘 — template의 CFBundleIconFile=Damson를 만족시키도록 Damson.icns 복사.
if [[ -f "$REPO_ROOT/Resources/Damson.icns" ]]; then
    cp "$REPO_ROOT/Resources/Damson.icns" "$RESOURCES_DIR/Damson.icns"
fi

# Entitlements는 sign 단계에서 codesign --entitlements로 적용 — 번들에는 안 들어감.

echo "==> verifying bundle"
plutil -lint "$CONTENTS/Info.plist" > /dev/null
file "$MACOS_DIR/damson" | head -1
file "$RESOURCES_DIR/damson-cli" | head -1

# Trampoline 자체 정합성 — 빌드한 binary가 .app 안에 있으면 trampoline은
# isInsideAppBundle()로 spotting하고 skip하므로 추가 wrap 없음. OK.

echo ""
echo "==> done"
echo "App path: $APP_DIR"
echo "Version: $MARKETING_VERSION ($BUILD_NUMBER)"
