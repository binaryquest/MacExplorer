#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/module-cache"
swift build -c release -debug-info-format none --disable-sandbox --cache-path "$PROJECT_ROOT/.build/cache" --config-path "$PROJECT_ROOT/.build/config" --security-path "$PROJECT_ROOT/.build/security"
APP_PATH="$PROJECT_ROOT/build/Explorer.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp .build/release/Explorer "$APP_PATH/Contents/MacOS/Explorer.new"
mv -f "$APP_PATH/Contents/MacOS/Explorer.new" "$APP_PATH/Contents/MacOS/Explorer"
cp Support/Info.plist "$APP_PATH/Contents/Info.plist"
if [[ ! -f .build/AppIcon.icns || scripts/generate-icon.swift -nt .build/AppIcon.icns ]]; then
  swift -module-cache-path "$PROJECT_ROOT/.build/module-cache" scripts/generate-icon.swift "$PROJECT_ROOT/.build/AppIcon.iconset"
fi
cp .build/AppIcon.icns "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_PATH"
printf 'Built: %s\n' "$APP_PATH"
