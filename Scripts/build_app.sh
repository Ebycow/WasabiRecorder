#!/bin/zsh
# Builds Wasabi Recorder.app into ./build. Usage: Scripts/build_app.sh [--install]
set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="Wasabi Recorder"
APP="$ROOT/build/$APP_NAME.app"
IDENTITY="${SIGN_IDENTITY:--}"

cd "$ROOT"
swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --show-bin-path)/WasabiRecorder" "$APP/Contents/MacOS/WasabiRecorder"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

ICONSET="$ROOT/build/AppIcon.iconset"
if [[ ! -f "$ROOT/build/AppIcon.icns" || "$ROOT/Scripts/make_icon.swift" -nt "$ROOT/build/AppIcon.icns" ]]; then
    rm -rf "$ICONSET"
    swift "$ROOT/Scripts/make_icon.swift" "$ICONSET"
    iconutil -c icns "$ICONSET" -o "$ROOT/build/AppIcon.icns"
fi
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/$APP_NAME.app"
fi
