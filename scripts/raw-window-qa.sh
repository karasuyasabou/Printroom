#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
if [[ "${1:-}" != --skip-build ]]; then swift build -c release --disable-sandbox; fi
mkdir -p scratch/raw-window-qa
source scripts/native-raw-link.sh
printroom_native_link_args "$PWD/.build/release" "$PWD/scratch/raw-window-qa"
app_sources=()
for source_file in Sources/PrintroomApp/*.swift; do
  [[ "$source_file" == "Sources/PrintroomApp/PrintroomApp.swift" ]] || app_sources+=("$source_file")
done
xcrun swiftc -parse-as-library -O -module-name RAWWindowQA -I .build/release/Modules \
  "${native_raw_flags[@]}" "${app_sources[@]}" scripts/RAWWindowQA.swift \
  .build/release/PrintroomCore.build/*.swift.o -o scratch/raw-window-qa/window-qa
cp -R .build/release/Printroom_PrintroomCore.bundle scratch/raw-window-qa/
scratch/raw-window-qa/window-qa
