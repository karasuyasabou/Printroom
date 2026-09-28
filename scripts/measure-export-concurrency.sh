#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 5 ]]; then
  echo 'Usage: scripts/measure-export-concurrency.sh ROLL NEW_OUTPUT CONCURRENCY FIRST_FRAME COUNT' >&2
  exit 64
fi
# Build release first with scripts/build-app.sh. Each measurement runs in a fresh process.
work="$PWD/scratch/export-concurrency-driver"
native_build_root="$PWD/.build/arm64-apple-macosx/release"
source scripts/native-raw-link.sh
printroom_native_link_args "$native_build_root" "$work"
core_objects=()
while IFS= read -r source_file; do
  core_objects+=("$native_build_root/PrintroomCore.build/$(basename "$source_file").o")
done < "$native_build_root/PrintroomCore.build/sources"
xcrun swiftc -parse-as-library -swift-version 6 -O "${native_raw_flags[@]}" \
  -module-cache-path "$work/ModuleCache" -I "$native_build_root/Modules" \
  scripts/ExportConcurrencyMeasurement.swift "${core_objects[@]}" -o "$work/measure"
/usr/bin/time -l "$work/measure" "$@"
