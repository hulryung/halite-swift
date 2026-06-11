#!/usr/bin/env bash
# sparkle-appcast.sh — prints an appcast.xml entry for a single .dmg.
#
# Sparkle 2.x's sign_update signs the dmg with EdDSA and embeds the result in the
# sparkle:edSignature attribute. The private key must be in the macOS keychain
# (sparkle-keygen.sh generates it once).
#
# Usage:
#   ./scripts/sparkle-appcast.sh \
#       --dmg dist/Damson-0.1.0.dmg \
#       --version 0.1.0 \
#       --build 1 \
#       --url https://github.com/hulryung/damson/releases/download/v0.1.0/Damson-0.1.0.dmg \
#       > entry.xml
#
# Add the contents of entry.xml inside the <channel> of an existing appcast.xml, or
# use sparkle-full-appcast.sh to generate a full appcast from scratch.

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

# sign_update output: " sparkle:edSignature=\"...\" length=\"NNN\""
# Local: the private key is read automatically from the keychain.
# CI: no keychain, so pass SPARKLE_PRIVATE_KEY (base64 EdDSA private key) via -s.
SIGN_ARGS=("$DMG")
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    SIGN_ARGS+=(-s "$SPARKLE_PRIVATE_KEY")
fi
SIG_LINE="$("$SIGN" "${SIGN_ARGS[@]}")"
# sign_update already emits BOTH attributes: sparkle:edSignature="..." length="NNN".
# Use it verbatim and do NOT add our own length — a duplicate attribute is invalid XML
# (Sparkle's own appcast tooling treats sign_update's length as authoritative anyway).

PUBDATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"

cat <<EOF
        <item>
            <title>Damson $VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <enclosure
                url="$URL"
                type="application/octet-stream"
               $SIG_LINE />
        </item>
EOF
