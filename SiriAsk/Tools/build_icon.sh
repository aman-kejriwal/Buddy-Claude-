#!/bin/bash
# Regenerates Resources/AppIcon.icns from Tools/make_icon.swift.
# Only needed when the icon design changes; build.sh just copies the .icns.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift "$HERE/Tools/make_icon.swift" "$WORK/icon_1024.png"

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon_1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$WORK/icon_1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o "$HERE/Resources/AppIcon.icns"
echo "Wrote $HERE/Resources/AppIcon.icns"
