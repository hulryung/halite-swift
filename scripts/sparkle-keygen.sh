#!/usr/bin/env bash
# sparkle-keygen.sh — Sparkle EdDSA 키페어 생성 (1회성).
#
# Sparkle의 generate_keys는 private key를 macOS keychain에 저장하고
# public key를 stdout으로 출력한다. public key는 Info.plist의 SUPublicEDKey에
# 박혀서 배포되고, private key는 keychain에 머물면서 향후 sign_update가 사용.
#
# 이미 키가 있으면 generate_keys -p로 public key만 출력.
#
# 출력: stdout에 base64 public key 한 줄.
# 사용: SPARKLE_PUBLIC_KEY=$(./scripts/sparkle-keygen.sh) ./scripts/build-app.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# generate_keys 위치: SwiftPM이 dist artifact로 가져옴.
GEN="$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
if [[ ! -x "$GEN" ]]; then
    # 빌드 한 번 돌려서 artifact 받음.
    echo "==> fetching Sparkle artifacts via swift build" >&2
    ( cd "$REPO_ROOT" && swift build --product damson 2>&1 | tail -3 ) >&2
fi
if [[ ! -x "$GEN" ]]; then
    echo "error: generate_keys not found at $GEN" >&2
    exit 1
fi

# -p: print public key. 이미 생성되어 있으면 그것을, 없으면 새로 생성.
"$GEN" -p
