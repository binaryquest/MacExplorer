#!/bin/zsh
set -euo pipefail
set +x
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a validated notarytool Keychain profile}"
: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION}"
python3 -c 'import sys; sys.path.insert(0,"scripts/release"); from config import app_info; app_info()'
RELEASE_VERSION=$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)
[[ -f "docs/releases/$RELEASE_VERSION.md" ]] || { print -u2 "Add docs/releases/$RELEASE_VERSION.md first"; exit 1; }
if [[ -n "${GITHUB_REF_NAME:-}" && "$GITHUB_REF_NAME" != "v$RELEASE_VERSION" ]]; then
  print -u2 'Git tag and application version must match'; exit 1
fi
NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN"); fi
# Validate access before building; does not submit anything.
xcrun notarytool history "${NOTARY_ARGS[@]}" --output-format json > /dev/null
zsh scripts/build.sh --release --universal
APP_PATH="$PROJECT_ROOT/build/release/Explorer.app"
WORK=$(mktemp -d "$PROJECT_ROOT/.build/release-work.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
OUTPUT="$PROJECT_ROOT/build/releases/$RELEASE_VERSION"
mkdir -p "$OUTPUT" "$WORK/disk"
function notarize() {
  xcrun notarytool submit "$1" "${NOTARY_ARGS[@]}" --wait --timeout 30m --output-format json > "$WORK/notary-result.json"
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r.get("status")=="Accepted", r' "$WORK/notary-result.json"
}
ditto -c -k --keepParent "$APP_PATH" "$WORK/Explorer.zip"
notarize "$WORK/Explorer.zip"
python3 scripts/release/stapler.py staple "$APP_PATH"
python3 scripts/release/stapler.py validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
ditto "$APP_PATH" "$WORK/disk/Explorer.app"
ln -s /Applications "$WORK/disk/Applications"
DMG="$OUTPUT/MacExplorer-$RELEASE_VERSION.dmg"
hdiutil create -volname Explorer -srcfolder "$WORK/disk" -format UDZO -ov "$DMG"
codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG"
notarize "$DMG"
python3 scripts/release/stapler.py staple "$DMG"
python3 scripts/release/stapler.py validate "$DMG"
codesign --verify --strict "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
cp "docs/releases/$RELEASE_VERSION.md" "$OUTPUT/MacExplorer-$RELEASE_VERSION.md"
if [[ -n "${PREVIOUS_APPCAST:-}" && -f "$PREVIOUS_APPCAST" ]]; then cp "$PREVIOUS_APPCAST" "$OUTPUT/appcast.xml"; fi
APPCAST_ARGS=(--maximum-deltas 0 --maximum-versions 0 --link https://explorer.bquick.io
  --download-url-prefix "https://downloads.bquick.io/explorer/releases/$RELEASE_VERSION/"
  --release-notes-url-prefix "https://downloads.bquick.io/explorer/releases/$RELEASE_VERSION/")
APPCAST_TOOL="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$APPCAST_TOOL" --ed-key-file - "${APPCAST_ARGS[@]}" "$OUTPUT"
else
  "$APPCAST_TOOL" --account io.bquick.explorer "${APPCAST_ARGS[@]}" "$OUTPUT"
fi
swift -module-cache-path "$PROJECT_ROOT/.build/module-cache" scripts/verify-update.swift "$OUTPUT" "$APP_PATH/Contents/Info.plist"
python3 scripts/release/manifest.py "$OUTPUT"
python3 scripts/release/publish.py validate "$OUTPUT"
printf 'Verified release candidate: %s\nNo files have been published.\n' "$OUTPUT"
