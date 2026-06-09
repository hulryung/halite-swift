#!/usr/bin/env bash
# run-dev.sh — 개발 빌드를 .app으로 묶어 GUI 환경(LaunchServices PATH 미상속 등
# 실제 배포와 동일)에서 실행. dev 빌드는 윈도우에 git hash를 표시해 /Applications의
# 정식 빌드와 구분된다. 서명/노타라이즈는 안 함 (로컬 dev 전용).
#
# 사용: ./scripts/run-dev.sh
#
# 정식 빌드(/Applications/Damson.app)는 그대로 두고 dogfood 계속하면 됨.
# 이 dev .app은 dist/Damson.app에 생성되고 `open -n`으로 별도 인스턴스 실행.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

HASH="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "==> dev build @ $HASH"

# 이전 dev .app 인스턴스만 종료 (정식 /Applications 인스턴스는 건드리지 않으려
# 노력하지만 bundle ID가 같아 둘 다 잡힐 수 있음 — dev 작업 중엔 정식도 재시작 감수).
pkill -f "dist/Damson.app/Contents/MacOS/damson" 2>/dev/null || true

GIT_HASH="$HASH" BUILD_CHANNEL=dev \
    MARKETING_VERSION="0.0.0-dev" BUILD_NUMBER="dev" \
    ./scripts/build-app.sh >/dev/null

echo "==> launching dist/Damson.app"
open -n "$REPO_ROOT/dist/Damson.app"
echo "    (윈도우에 'dev $HASH' 표시됨)"
