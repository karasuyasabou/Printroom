#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
if [[ "${1:-}" != "--skip-build" ]]; then
  swift build -c release --disable-sandbox
fi
mkdir -p scratch/cache-ui-qa
source scripts/native-raw-link.sh
printroom_native_link_args "$PWD/.build/release" "$PWD/scratch/cache-ui-qa"
xcrun swiftc -O -parse-as-library -module-name CacheWindowQA -I .build/release/Modules \
  "${native_raw_flags[@]}" Sources/PrintroomApp/CacheManagerView.swift scripts/CacheWindowQA.swift \
  .build/release/PrintroomCore.build/*.swift.o -o scratch/cache-ui-qa/window-qa
cp -R .build/release/Printroom_PrintroomCore.bundle scratch/cache-ui-qa/
scratch/cache-ui-qa/window-qa
