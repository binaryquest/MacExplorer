#!/bin/zsh
set -euo pipefail
APP_PATH="${1:?App bundle required}"
SIGNING_IDENTITY="${2:--}"
SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != '-' ]]; then
  [[ "$SIGNING_IDENTITY" == 'Developer ID Application:'* ]] || { print -u2 'A Developer ID Application identity is required'; exit 1; }
  SIGN_ARGS+=(--options runtime --timestamp)
fi
FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
# Sign nested code inside out. Preserve Sparkle helper entitlements.
for nested in "$FRAMEWORK"/Versions/B/XPCServices/*.xpc(N) "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK"; do
  codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$nested"
done
codesign "${SIGN_ARGS[@]}" --entitlements "${0:A:h:h}/Support/Explorer.entitlements" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
if [[ "$SIGNING_IDENTITY" != '-' ]]; then
  SIGNATURE_INFO=$(codesign -dv "$APP_PATH" 2>&1)
  [[ "$SIGNATURE_INFO" == *'TeamIdentifier=B5M99337GK'* ]] || { print -u2 'Unexpected signing team'; exit 1; }
fi
