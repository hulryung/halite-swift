#!/usr/bin/env bash
# release.sh — 한 번에 build → sign+notarize → dmg.
#
# 환경변수는 각 sub-script와 동일.
#   필수: MARKETING_VERSION, APPLE_SIGNING_IDENTITY
#   필수(노타라이즈): APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID
#                  (또는 NOTARY_KEYCHAIN_PROFILE)
#
# 사용:
#   MARKETING_VERSION=0.1.0 ./scripts/release.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "############ build ############"
CLEAN=1 ./scripts/build-app.sh

echo "############ sign + notarize ############"
./scripts/sign-and-notarize.sh

echo "############ dmg ############"
./scripts/build-dmg.sh

echo ""
echo "############ done ############"
ls -lh dist/
