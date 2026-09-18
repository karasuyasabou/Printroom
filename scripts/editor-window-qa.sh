#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
configuration=debug
optimization=(-Onone)
skip_build=false
qa_arguments=()
for argument in "$@"; do
  case "$argument" in
    --release) configuration=release; optimization=(-O) ;;
    --skip-build) skip_build=true ;;
    --keyboard) qa_arguments+=(--keyboard) ;;
    --timing) qa_arguments+=(--timing) ;;
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
app_sources=()
for source_file in Sources/PrintroomApp/*.swift; do
  [[ "$source_file" == "Sources/PrintroomApp/PrintroomApp.swift" ]] || app_sources+=("$source_file")
done
source scripts/native-raw-link.sh
printroom_native_link_args "$PWD/.build/$configuration" "$PWD/scratch/editor-ui-qa"
xcrun swiftc "${native_raw_flags[@]}" -parse-as-library -module-name EditorWindowQA "${optimization[@]}" -I ".build/$configuration/Modules" \
  "${app_sources[@]}" scripts/EditorWindowQA.swift \
  .build/"$configuration"/PrintroomCore.build/*.swift.o -o scratch/editor-ui-qa/window-qa
cp -R .build/"$configuration"/Printroom_PrintroomCore.bundle scratch/editor-ui-qa/
if (( ${#qa_arguments[@]} )); then
  scratch/editor-ui-qa/window-qa "${qa_arguments[@]}"
else
  scratch/editor-ui-qa/window-qa
fi
