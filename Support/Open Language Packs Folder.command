#!/bin/zsh
set -euo pipefail

PACKS="$HOME/Library/Application Support/Explorer/Localizations"
/bin/mkdir -p "$PACKS"
/usr/bin/open "$PACKS"
