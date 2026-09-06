#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
if [[ "${1:-}" == "--full" ]]; then
    export PRINTROOM_VALIDATE_ASSETS=1
    shift
fi
swift test --disable-sandbox "$@"
