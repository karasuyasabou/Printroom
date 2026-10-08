#!/bin/bash
# Sourced by window QA drivers. Build the app without its @main entry point,
# link the configured Core/native objects, and place its resources beside it.
# Arguments: configuration, scratch directory, module name, Swift driver, binary.
printroom_build_window_qa() {
  local qa_configuration="$1" qa_directory="$2" qa_module="$3" qa_driver="$4" qa_binary="$5"
  local qa_build_root="$PWD/.build/$qa_configuration"
  local qa_sources=() qa_core_objects=() qa_optimization=(-Onone) qa_source
  [[ "$qa_configuration" != release ]] || qa_optimization=(-O)
  mkdir -p "$qa_directory"
  for qa_source in Sources/PrintroomApp/*.swift; do
    [[ "$qa_source" == Sources/PrintroomApp/PrintroomApp.swift ]] || qa_sources+=("$qa_source")
  done
  # SwiftPM can leave removed/renamed source objects behind in an incremental build.
  while IFS= read -r qa_source; do
    qa_core_objects+=("$qa_build_root/PrintroomCore.build/$(basename "$qa_source").o")
  done < "$qa_build_root/PrintroomCore.build/sources"
  source scripts/native-raw-link.sh
  printroom_native_link_args "$qa_build_root" "$qa_directory"
  xcrun swiftc "${native_raw_flags[@]}" -parse-as-library -swift-version 6 \
    -module-name "$qa_module" "${qa_optimization[@]}" \
    -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$PWD/.build/ModuleCache}" \
    -I "$qa_build_root/Modules" "${qa_sources[@]}" "$qa_driver" \
    "${qa_core_objects[@]}" -o "$qa_binary"
  cp -R "$qa_build_root/Printroom_PrintroomCore.bundle" "$qa_directory/"
}
