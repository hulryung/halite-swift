#!/usr/bin/env bash
# sparkle-keygen.sh — generates a Sparkle EdDSA key pair (one-time).
#
# Sparkle's generate_keys stores the private key in the macOS keychain and prints
# the public key to stdout. The public key is embedded in Info.plist's SUPublicEDKey
# and distributed, while the private key stays in the keychain for future sign_update use.
#
# If a key already exists, generate_keys -p prints only the public key.
#
# Output: one line of base64 public key on stdout.
# Usage: SPARKLE_PUBLIC_KEY=$(./scripts/sparkle-keygen.sh) ./scripts/build-app.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# generate_keys location: SwiftPM fetches it as a dist artifact.
GEN="$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
if [[ ! -x "$GEN" ]]; then
    # Run a build once to obtain the artifact.
    echo "==> fetching Sparkle artifacts via swift build" >&2
    ( cd "$REPO_ROOT" && swift build --product damson 2>&1 | tail -3 ) >&2
fi
if [[ ! -x "$GEN" ]]; then
    echo "error: generate_keys not found at $GEN" >&2
    exit 1
fi

# -p prints the existing public key; if none exists yet, run plain generate_keys
# once (creates the pair: private → keychain, public printed) then print again.
if ! "$GEN" -p 2>/dev/null; then
    "$GEN" >&2
    "$GEN" -p
fi
