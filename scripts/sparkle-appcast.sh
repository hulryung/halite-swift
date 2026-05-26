#!/usr/bin/env bash
# sparkle-appcast.sh — 한 개의 .dmg에 대해 appcast.xml entry를 출력.
#
# Sparkle 2.x의 sign_update가 dmg를 EdDSA로 서명하고 그 결과를 sparkle:edSignature
# 어트리뷰트로 박는다. private key는 macOS keychain에 있어야 함 (sparkle-keygen.sh가
# 1회 생성).
#
# 사용:
#   ./scripts/sparkle-appcast.sh \
#       --dmg dist/Halite-0.1.0.dmg \
#       --version 0.1.0 \
#       --build 1 \
#       --url https://github.com/hulryung/halite-swift/releases/download/v0.1.0/Halite-0.1.0.dmg \
#       > entry.xml
#
# entry.xml 내용을 기존 appcast.xml의 <channel> 안에 추가하거나, full appcast를
# 새로 생성하려면 sparkle-full-appcast.sh 사용.

set -euo pipefail

DMG=""
VERSION=""
BUILD=""
URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg) DMG="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --build) BUILD="$2"; shift 2 ;;
        --url) URL="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$DMG" || -z "$VERSION" || -z "$BUILD" || -z "$URL" ]]; then
    echo "usage: $0 --dmg PATH --version V --build N --url URL" >&2
    exit 1
fi
if [[ ! -f "$DMG" ]]; then
    echo "error: $DMG not found" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGN="$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ ! -x "$SIGN" ]]; then
    echo "error: sign_update not found at $SIGN (run swift build first)" >&2
    exit 1
fi

# sign_update 출력: " sparkle:edSignature=\"...\" length=\"NNN\""
SIG_LINE="$("$SIGN" "$DMG")"
# 그대로 attribute 형태로 사용 가능 (앞 공백 포함).

SIZE="$(stat -f%z "$DMG")"
PUBDATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"

cat <<EOF
        <item>
            <title>halite $VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <enclosure
                url="$URL"
                length="$SIZE"
                type="application/octet-stream"
               $SIG_LINE />
        </item>
EOF
