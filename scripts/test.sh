#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/module-cache"
swift test --disable-sandbox --cache-path "$PROJECT_ROOT/.build/cache" --config-path "$PROJECT_ROOT/.build/config" --security-path "$PROJECT_ROOT/.build/security"
