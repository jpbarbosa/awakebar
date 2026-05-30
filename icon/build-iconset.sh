#!/bin/bash
# build-iconset.sh — render the app icon at every iconset size with make-icon.swift
# and assemble icon/AppIcon.icns. Each size is rendered natively (not downscaled
# from one master) so small sizes stay crisp. Re-run to regenerate after editing
# make-icon.swift; the committed AppIcon.icns is what build.sh copies into the app.
#
# Usage: ./build-iconset.sh [style]   (style: espresso | aqua | graphite)
set -euo pipefail
cd "$(dirname "$0")"

STYLE="${1:-espresso}"
SET="AppIcon.iconset"
rm -rf "$SET"; mkdir "$SET"

render() { swift make-icon.swift "$STYLE" "$1" "$SET/$2" >/dev/null; }

render 16   icon_16x16.png
render 32   icon_16x16@2x.png
cp "$SET/icon_16x16@2x.png" "$SET/icon_32x32.png"          # 32 == 32
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
cp "$SET/icon_128x128@2x.png" "$SET/icon_256x256.png"      # 256 == 256
render 512  icon_256x256@2x.png
cp "$SET/icon_256x256@2x.png" "$SET/icon_512x512.png"      # 512 == 512
render 1024 icon_512x512@2x.png

iconutil -c icns "$SET" -o AppIcon.icns
echo "Built icon/AppIcon.icns ($STYLE)"
