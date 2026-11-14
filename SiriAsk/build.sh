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
  -target arm64-apple-macos26.0 \
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

# Sign with a stable local certificate when there is one, so macOS keeps the Accessibility
# and Input Monitoring permissions across rebuilds. (An ad-hoc signature changes with every
# build, and macOS then treats the new build as a different app and asks again.)
SIGN_ID="SiriAsk Local Signing"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  codesign --force --sign "$SIGN_ID" "$APP"
else
  echo "Note: no \"$SIGN_ID\" certificate; using an ad-hoc signature (permissions reset each build)."
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "Built: $APP"
echo "Open it with: open \"$APP\""
