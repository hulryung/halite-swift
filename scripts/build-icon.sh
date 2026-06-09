#!/usr/bin/env bash
# build-icon.sh — Resources/icon-source.svg → 1024px PNG → multi-size .iconset
# → Resources/Damson.icns.
#
# Dependencies: rsvg-convert (brew install librsvg) preferred, else falls back to
#         qlmanage (built into macOS). sips + iconutil (built into macOS).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_SVG="$REPO_ROOT/Resources/icon-source.svg"
PNG_1024="$REPO_ROOT/Resources/Damson-1024.png"
DST_ICNS="$REPO_ROOT/Resources/Damson.icns"

if [[ ! -f "$SRC_SVG" ]]; then
    echo "error: $SRC_SVG not found" >&2
    exit 1
fi
if command -v rsvg-convert >/dev/null 2>&1; then
    echo "==> rsvg-convert 1024px PNG"
    rsvg-convert -w 1024 -h 1024 "$SRC_SVG" -o "$PNG_1024"
elif command -v qlmanage >/dev/null 2>&1; then
    echo "==> qlmanage 1024px PNG (rsvg-convert missing → fallback)"
    QL_DIR=$(mktemp -d -t damson-ql)
    trap 'rm -rf "$QL_DIR"' EXIT
    qlmanage -t -s 1024 -o "$QL_DIR" "$SRC_SVG" >/dev/null 2>&1
    mv "$QL_DIR/$(basename "$SRC_SVG").png" "$PNG_1024"
else
    echo "error: rsvg-convert or qlmanage required. brew install librsvg" >&2
    exit 1
fi

echo "==> sips multi-size + iconutil"
ICONSET_DIR=$(mktemp -d -t damson-icns)
trap 'rm -rf "$ICONSET_DIR" "${QL_DIR:-}"' EXIT
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

# Also copy into the SwiftPM resources path.
cp "$DST_ICNS" "$REPO_ROOT/Sources/damson/Resources/Damson.icns"

echo "==> $DST_ICNS"
ls -lh "$DST_ICNS"
