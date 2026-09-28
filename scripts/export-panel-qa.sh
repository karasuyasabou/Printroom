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
source scripts/build-window-qa.sh
printroom_build_window_qa "release" "$PWD/scratch/export-panel-qa" ExportPanelQA \
  scripts/ExportPanelQA.swift "$PWD/scratch/export-panel-qa/export-panel-qa"
fi
if [[ "$qa_mode" != --compile-only ]]; then
"$qa_root/export-panel-qa" 2>&1 | tee "$qa_root/latest.log"
fi
