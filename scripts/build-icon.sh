#!/bin/zsh
set -eu
cd "${0:A:h}/.."
if [[ -f Assets/AppIcon.icns && Assets/AppIcon.icns -nt Assets/AppIcon.png ]]; then
    exit 0
fi
ICONSET="$PWD/build/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    DOUBLE=$((SIZE * 2))
    sips -z "$SIZE" "$SIZE" Assets/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z "$DOUBLE" "$DOUBLE" Assets/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Assets/AppIcon.icns
