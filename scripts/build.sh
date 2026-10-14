#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/module-cache"
RELEASE_BUILD=0
UNIVERSAL_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --release) RELEASE_BUILD=1 ;;
    --universal) UNIVERSAL_BUILD=1 ;;
    *) print -u2 "Unknown option: $arg"; exit 2 ;;
  esac
done
if (( RELEASE_BUILD )); then
  : "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your Developer ID Application identity}"
fi
BUILD_ARGS=(-c release -debug-info-format none --disable-sandbox --cache-path "$PROJECT_ROOT/.build/cache" --config-path "$PROJECT_ROOT/.build/config" --security-path "$PROJECT_ROOT/.build/security")
if (( UNIVERSAL_BUILD )); then BUILD_ARGS+=(--arch arm64 --arch x86_64); fi
swift build "${BUILD_ARGS[@]}"
BIN_PATH=$(swift build "${BUILD_ARGS[@]}" --show-bin-path)
SPARKLE_ROOT="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle"
FRAMEWORK="$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$FRAMEWORK" ]] || { print -u2 'Sparkle framework is missing'; exit 1; }
STAGING_ROOT=$(mktemp -d "$PROJECT_ROOT/.build/app-staging.XXXXXX")
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP_STAGE="$STAGING_ROOT/Explorer.app"
mkdir -p "$APP_STAGE/Contents/MacOS" "$APP_STAGE/Contents/Resources" "$APP_STAGE/Contents/Frameworks"
cp "$BIN_PATH/Explorer" "$APP_STAGE/Contents/MacOS/Explorer"
cp Support/Info.plist "$APP_STAGE/Contents/Info.plist"
ditto "$FRAMEWORK" "$APP_STAGE/Contents/Frameworks/Sparkle.framework"
if [[ ! -f .build/AppIcon.icns || scripts/generate-icon.swift -nt .build/AppIcon.icns ]]; then
  swift -module-cache-path "$PROJECT_ROOT/.build/module-cache" scripts/generate-icon.swift "$PROJECT_ROOT/.build/AppIcon.iconset"
fi
cp .build/AppIcon.icns "$APP_STAGE/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP_STAGE/Contents/Resources/LICENSE.txt"
ditto Support/Licenses "$APP_STAGE/Contents/Resources/Licenses"
if (( RELEASE_BUILD )); then
  plutil -replace ExplorerUpdatesEnabled -bool YES "$APP_STAGE/Contents/Info.plist"
  zsh scripts/sign-app.sh "$APP_STAGE" "$DEVELOPER_ID_APPLICATION"
  APP_PATH="$PROJECT_ROOT/build/release/Explorer.app"
else
  zsh scripts/sign-app.sh "$APP_STAGE" -
  APP_PATH="$PROJECT_ROOT/build/Explorer.app"
fi
if (( UNIVERSAL_BUILD )); then
  ARCHS=" $(lipo -archs "$APP_STAGE/Contents/MacOS/Explorer") "
  [[ "$ARCHS" == *' arm64 '* && "$ARCHS" == *' x86_64 '* ]] || { print -u2 'Universal build is missing an architecture'; exit 1; }
fi
mkdir -p "${APP_PATH:h}"
if [[ -e "$APP_PATH" ]]; then mv "$APP_PATH" "$STAGING_ROOT/previous.app"; fi
mv "$APP_STAGE" "$APP_PATH"
printf 'Built: %s\n' "$APP_PATH"
