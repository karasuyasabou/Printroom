#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
configuration=debug
optimization=()
skip_build=false
qa_arguments=()
for argument in "$@"; do
  case "$argument" in
    --release) configuration=release; optimization=(-O) ;;
    --skip-build) skip_build=true ;;
    --keyboard) qa_arguments+=(--keyboard) ;;
    *) printf 'Unknown argument: %s\n' "$argument" >&2; exit 2 ;;
  esac
done
if [[ "$skip_build" == false ]]; then
  swift build -c "$configuration" --disable-sandbox
fi
mkdir -p scratch/editor-ui-qa
app_sources=()
for source_file in Sources/PrintroomApp/*.swift; do
  [[ "$source_file" == "Sources/PrintroomApp/PrintroomApp.swift" ]] || app_sources+=("$source_file")
done
xcrun swiftc -parse-as-library -module-name EditorWindowQA "${optimization[@]}" -I ".build/$configuration/Modules" \
  "${app_sources[@]}" scripts/EditorWindowQA.swift \
  .build/"$configuration"/PrintroomCore.build/*.swift.o -o scratch/editor-ui-qa/window-qa
cp -R .build/"$configuration"/Printroom_PrintroomCore.bundle scratch/editor-ui-qa/
scratch/editor-ui-qa/window-qa "${qa_arguments[@]}"
