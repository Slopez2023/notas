#!/bin/zsh
# Builds Notas.app into ./build. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
# The default CLT SDK (27) needs Xcode-only SwiftUI macro plugins; pin the macOS 26 SDK.
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
[[ -d "$SDK" ]] && export SDKROOT="$SDK"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Notas"

APP="build/Notas.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/Notas"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true

python3 scripts/build-extensions.py --app "$APP" --configuration "$CONFIG"
echo "Built $APP"
