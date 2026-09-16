#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Use an already-built release Core; never acquire a SwiftPM build lock.
qa_root="$PWD/scratch/export-panel-qa"
release_root="$PWD/.build/release"
qa_mode="${1:-}"
case "$qa_mode" in
  ""|--compile-only|--run-only) ;;
  *) echo "Usage: $0 [--compile-only|--run-only]" >&2; exit 2 ;;
esac
if [[ ! -f "$release_root/Modules/PrintroomCore.swiftmodule" ]]; then
  echo "Missing release objects. Run the normal release build before this QA." >&2
  exit 1
fi
mkdir -p "$qa_root"
export CLANG_MODULE_CACHE_PATH="$qa_root/ModuleCache"
if [[ "$qa_mode" != --run-only ]]; then
app_sources=()
for source_file in Sources/PrintroomApp/*.swift; do
  [[ "$source_file" == "Sources/PrintroomApp/PrintroomApp.swift" ]] || app_sources+=("$source_file")
done
source scripts/native-raw-link.sh
printroom_native_link_args "$release_root" "$qa_root"
xcrun swiftc "${native_raw_flags[@]}" -parse-as-library -swift-version 6 -O -module-name ExportPanelQA \
  -module-cache-path "$CLANG_MODULE_CACHE_PATH" -I "$release_root/Modules" \
  "${app_sources[@]}" scripts/ExportPanelQA.swift \
  "$release_root"/PrintroomCore.build/*.swift.o -o "$qa_root/export-panel-qa"
cp -R "$release_root/Printroom_PrintroomCore.bundle" "$qa_root/"
fi
if [[ "$qa_mode" != --compile-only ]]; then
"$qa_root/export-panel-qa" 2>&1 | tee "$qa_root/latest.log"
fi
