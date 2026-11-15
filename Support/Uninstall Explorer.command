#!/bin/zsh
set -euo pipefail

APP="/Applications/Explorer.app"
PACKS="$HOME/Library/Application Support/Explorer/Localizations"

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
  if (( result != 0 )); then
    status 31 'Explorer removal could not finish.' >&2
    if [[ -t 0 ]]; then read -r '?Press Return to close.' || true; fi
  fi
  exit "$result"
}
trap cleanup EXIT

if [[ ! -e "$APP" && ! -L "$APP" && ! -e "$PACKS" && ! -L "$PACKS" ]]; then
  status 32 'Explorer is already removed.'
  exit 0
fi

print
status 34 'Move Explorer and all installed language packs, including custom translations, to Trash?'
print
while true; do
  if [[ -t 2 && "${TERM:-dumb}" != dumb ]]; then
    printf '\033[1mEnter y to continue: \033[0m' >&2
  else
    print -nu2 'Enter y to continue: '
  fi
  if ! read -r answer; then
    print 'Uninstallation cancelled.'
    exit 0
  fi
  [[ "$answer" == [yY] ]] && break
  status 31 'Invalid response. Enter y again, or close this window to cancel.' >&2
done

while /usr/bin/pgrep -u "$(/usr/bin/id -u)" -x Explorer >/dev/null; do
  print 'Quit Explorer (⌘Q) before continuing.'
  [[ -t 0 ]] || exit 1
  read -r '?Press Return to continue.'
done

move_to_trash() {
  local target="$1" trash_error="" finder_error=""
  [[ -e "$target" || -L "$target" ]] || return 0
  if [[ -x /usr/bin/trash ]]; then
    trash_error=$(/usr/bin/trash "$target" 2>&1) || true
    [[ -e "$target" || -L "$target" ]] || return 0
  fi

  # Finder can handle protected destinations and older macOS releases.
  print 'macOS may ask Terminal to control Finder.'
  if ! finder_error=$(/usr/bin/osascript - "$target" 2>&1 <<'APPLESCRIPT'
on run argv
    set itemToRemove to POSIX file (item 1 of argv)
    tell application id "com.apple.finder" to delete itemToRemove
end run
APPLESCRIPT
  ); then
    [[ -z "$trash_error" ]] || status 31 "$trash_error" >&2
    [[ -z "$finder_error" ]] || status 31 "$finder_error" >&2
  fi
  if [[ -e "$target" || -L "$target" ]]; then
    status 31 "Could not move to Trash: $target" >&2
    return 1
  fi
}

move_to_trash "$APP"
move_to_trash "$PACKS"
status 32 'Explorer and its language packs are in Trash.'
