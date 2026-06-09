#!/usr/bin/env bash
# run-dev.sh — packages the development build into a .app and runs it in the GUI
# environment (no inherited LaunchServices PATH, etc. — same as a real deployment).
# Dev builds show the git hash in the window to distinguish them from the release
# build in /Applications. No signing/notarization (local dev only).
#
# Usage: ./scripts/run-dev.sh
#
# Leave the release build (/Applications/Damson.app) in place and keep dogfooding.
# This dev .app is created at dist/Damson.app and run as a separate instance via `open -n`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

HASH="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "==> dev build @ $HASH"

# Kill only the previous dev .app instance (we try not to touch the release
# /Applications instance, but since the bundle ID is the same both may match —
# accept that the release one may also restart during dev work).
pkill -f "dist/Damson.app/Contents/MacOS/damson" 2>/dev/null || true

GIT_HASH="$HASH" BUILD_CHANNEL=dev \
    MARKETING_VERSION="0.0.0-dev" BUILD_NUMBER="dev" \
    ./scripts/build-app.sh >/dev/null

echo "==> launching dist/Damson.app"
open -n "$REPO_ROOT/dist/Damson.app"
echo "    (window shows 'dev $HASH')"
