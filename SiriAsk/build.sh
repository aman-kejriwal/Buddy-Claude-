#!/bin/bash
# Builds SiriAsk with swiftc and packages it as SiriAsk.app next to this script.
# (Uses swiftc directly, so full Xcode is not required.)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

BUILD_DIR="$HERE/.build"
APP="$HERE/SiriAsk.app"
mkdir -p "$BUILD_DIR"

swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework AppKit -framework SwiftUI -framework Carbon -framework Combine -framework Speech -framework AVFoundation \
  Sources/SiriAsk/*.swift \
  -o "$BUILD_DIR/SiriAsk"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD_DIR/SiriAsk" "$APP/Contents/MacOS/SiriAsk"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"

# App icon (regenerate with Tools/build_icon.sh if the design changes).
if [ ! -f "$HERE/Resources/AppIcon.icns" ]; then
  "$HERE/Tools/build_icon.sh"
fi
mkdir -p "$APP/Contents/Resources"
cp "$HERE/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS will launch it locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built: $APP"
echo "Open it with: open \"$APP\""
