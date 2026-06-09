#!/usr/bin/env bash
# build-icon.sh — Resources/icon-source.svg → 1024px PNG → multi-size .iconset
# → Resources/Damson.icns.
#
# 의존성: rsvg-convert (brew install librsvg), sips + iconutil (macOS 내장).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_SVG="$REPO_ROOT/Resources/icon-source.svg"
PNG_1024="$REPO_ROOT/Resources/Damson-1024.png"
DST_ICNS="$REPO_ROOT/Resources/Damson.icns"

if [[ ! -f "$SRC_SVG" ]]; then
    echo "error: $SRC_SVG 없음" >&2
    exit 1
fi
if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "error: rsvg-convert 필요. brew install librsvg" >&2
    exit 1
fi

echo "==> rsvg-convert 1024px PNG"
rsvg-convert -w 1024 -h 1024 "$SRC_SVG" -o "$PNG_1024"

echo "==> sips로 multi-size + iconutil"
ICONSET_DIR=$(mktemp -d -t halite-icns)
trap 'rm -rf "$ICONSET_DIR"' EXIT
ICONSET="$ICONSET_DIR/icon.iconset"
mkdir -p "$ICONSET"

declare -a SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)
for entry in "${SIZES[@]}"; do
    px="${entry%%:*}"
    name="${entry##*:}"
    sips -z "$px" "$px" "$PNG_1024" --out "$ICONSET/$name" >/dev/null
done

iconutil --convert icns "$ICONSET" --output "$DST_ICNS"

# SwiftPM 리소스 경로에도 복제.
cp "$DST_ICNS" "$REPO_ROOT/Sources/halite/Resources/Damson.icns"

echo "==> $DST_ICNS"
ls -lh "$DST_ICNS"
