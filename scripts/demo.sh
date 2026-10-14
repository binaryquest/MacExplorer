#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"
zsh scripts/build.sh
DEMO_ROOT=$(mktemp -d /tmp/MacExplorer-Demo.XXXXXX)
DEMO_APP="$PROJECT_ROOT/.build/Explorer Demo.app"
mkdir -p "$DEMO_APP/Contents/MacOS" "$DEMO_APP/Contents/Resources"
cp build/Explorer.app/Contents/MacOS/Explorer "$DEMO_APP/Contents/MacOS/Explorer"
cp build/Explorer.app/Contents/Resources/AppIcon.icns "$DEMO_APP/Contents/Resources/AppIcon.icns"
cp Support/Info.plist "$DEMO_APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string dev.local.explorer.demo "$DEMO_APP/Contents/Info.plist"
plutil -replace CFBundleName -string 'Explorer Demo' "$DEMO_APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string 'Explorer Demo' "$DEMO_APP/Contents/Info.plist"
plutil -insert ExplorerDemo -bool YES "$DEMO_APP/Contents/Info.plist"
plutil -insert ExplorerDemoRoot -string "$DEMO_ROOT" "$DEMO_APP/Contents/Info.plist"
plutil -insert ExplorerScreenshotDirectory -string "$PROJECT_ROOT/docs/images" "$DEMO_APP/Contents/Info.plist"
swift -module-cache-path "$PROJECT_ROOT/.build/module-cache" scripts/demo-fixtures.swift "$DEMO_ROOT"
codesign --force --sign - "$DEMO_APP"
printf 'Demo app: %s\nSample files: %s\nOpen the demo app, then use File > Export Demo Screenshot (Shift-Command-S).\n' "$DEMO_APP" "$DEMO_ROOT"
