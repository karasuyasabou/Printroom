#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
if [[ "${1:-}" != "--skip-build" ]]; then
  swift build -c release --disable-sandbox
fi
mkdir -p scratch/matrix-ui-qa
source scripts/build-window-qa.sh
printroom_build_window_qa "release" "$PWD/scratch/matrix-ui-qa" MatrixWindowQA \
  scripts/MatrixWindowQA.swift "$PWD/scratch/matrix-ui-qa/window-qa"
scratch/matrix-ui-qa/window-qa
