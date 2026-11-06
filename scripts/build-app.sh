#!/bin/bash
# Builds build/Brise.app (universal Intel + Apple Silicon unless ARCH is set).
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=(--arch arm64 --arch x86_64)
[[ -n "${ARCH:-}" ]] && ARCH_FLAGS=(--arch "$ARCH")

swift build -c release "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

APP=build/Brise.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Brise" "$BIN/brise-helper" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --sign - "$APP/Contents/MacOS/brise-helper"
codesign --force --sign - "$APP"

echo "✔︎ $APP"
