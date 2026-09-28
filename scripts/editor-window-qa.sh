#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
configuration=debug
skip_build=false
qa_arguments=()
for argument in "$@"; do
  case "$argument" in
    --release) configuration=release ;;
    --skip-build) skip_build=true ;;
    --keyboard) qa_arguments+=(--keyboard) ;;
    --timing) qa_arguments+=(--timing) ;;
    --themes) qa_arguments+=(--themes --appearance) ;;
    --window-chrome) qa_arguments+=(--themes --appearance --window-chrome) ;;
    --loading) qa_arguments+=(--loading --appearance) ;;
    --export-layout) qa_arguments+=(--export-layout) ;;
    --crop-preview) qa_arguments+=(--crop-preview --appearance) ;;
    --roll-name) qa_arguments+=(--roll-name --appearance) ;;
    --roll-timing) qa_arguments+=(--roll-timing) ;;
    --appearance) qa_arguments+=(--appearance) ;;
    --histogram) qa_arguments+=(--histogram) ;;
    --scrollbars) qa_arguments+=(--scrollbars -AppleShowScrollBars Always) ;;
    *) printf 'Unknown argument: %s\n' "$argument" >&2; exit 2 ;;
  esac
done
if [[ "$skip_build" == false ]]; then
  swift build --build-system native -c "$configuration" --disable-sandbox
fi
mkdir -p scratch/editor-ui-qa
source scripts/build-window-qa.sh
printroom_build_window_qa "$configuration" "$PWD/scratch/editor-ui-qa" EditorWindowQA \
  scripts/EditorWindowQA.swift "$PWD/scratch/editor-ui-qa/window-qa"
if (( ${#qa_arguments[@]} )); then
  scratch/editor-ui-qa/window-qa "${qa_arguments[@]}"
else
  scratch/editor-ui-qa/window-qa
fi
