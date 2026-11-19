#!/bin/zsh
set -euo pipefail

PAYLOAD="${0:A:h}"
SOURCE_PACKS="$PAYLOAD/Localizations"
APP="/Applications/Explorer.app"
PACKS="$HOME/Library/Application Support/Explorer/Localizations"
APP_STAGE=""
PACK_STAGE=""

status() {
  if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
    printf '\033[%sm%s\033[0m\n' "$1" "$2"
  else
    print -r -- "$2"
  fi
}

cleanup() {
  local result=$?
  trap - EXIT
  if [[ -n "$APP_STAGE" ]]; then
    if [[ ( -e "$APP_STAGE/Previous.app" || -L "$APP_STAGE/Previous.app" ) && ! -e "$APP" && ! -L "$APP" ]] &&
       ! /bin/mv "$APP_STAGE/Previous.app" "$APP"; then
      print -u2 "Previous Explorer is available at $APP_STAGE/Previous.app"
      APP_STAGE=""
    fi
    [[ -z "$APP_STAGE" ]] || /bin/rm -rf -- "$APP_STAGE"
  fi
  [[ -z "$PACK_STAGE" ]] || /bin/rm -rf -- "$PACK_STAGE"
  if (( result != 0 )); then
    status 31 'Explorer installation failed.' >&2
    if [[ -t 0 ]]; then read -r '?Press Return to close.' || true; fi
  fi
  exit "$result"
}
trap cleanup EXIT

[[ -d "$PAYLOAD/Explorer.app" && -d "$SOURCE_PACKS" ]]
/usr/bin/codesign --verify --deep --strict "$PAYLOAD/Explorer.app"
APP_STAGE=$(/usr/bin/mktemp -d "/Applications/.explorer-install.XXXXXX")
/bin/mkdir -p "$PACKS"
PACK_STAGE=$(/usr/bin/mktemp -d "$PACKS/.explorer-install.XXXXXX")
/usr/bin/ditto "$PAYLOAD/Explorer.app" "$APP_STAGE/Explorer.app"

for pack in "$SOURCE_PACKS"/*.lproj; do
  [[ -e "$PACKS/${pack:t}" ]] && continue
  /usr/bin/ditto "$pack" "$PACK_STAGE/${pack:t}"
done

while /usr/bin/pgrep -u "$(/usr/bin/id -u)" -x Explorer >/dev/null; do
  print 'Quit Explorer (⌘Q) before continuing.'
  [[ -t 0 ]] || exit 1
  read -r '?Press Return to continue.'
done

for pack in "$PACK_STAGE"/*.lproj(N); do
  /bin/mv -n "$pack" "$PACKS/${pack:t}"
done
if [[ -e "$APP" || -L "$APP" ]]; then /bin/mv "$APP" "$APP_STAGE/Previous.app"; fi
/bin/mv "$APP_STAGE/Explorer.app" "$APP"

status 32 'Explorer and its language packs are installed.'
