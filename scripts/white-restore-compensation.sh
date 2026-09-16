#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Build with scripts/test.sh first. Only the explicitly supplied roll folders are processed.
work="$PWD/scratch/white-restore"
mkdir -p "$work"
native_build_root="$PWD/.build/debug"
source scripts/native-raw-link.sh
printroom_native_link_args "$native_build_root" "$work"
core_objects=()
while IFS= read -r source_file; do
  core_objects+=("$native_build_root/PrintroomCore.build/$(basename "$source_file").o")
done < "$native_build_root/PrintroomCore.build/sources"
xcrun swiftc -parse-as-library -swift-version 6 -O "${native_raw_flags[@]}" \
  -module-cache-path "$work/ModuleCache" -I "$native_build_root/Modules" \
  scripts/WhiteRestoreCompensation.swift "${core_objects[@]}" -o "$work/compensate"
cp -R "$native_build_root/Printroom_PrintroomCore.bundle" "$work/"
"$work/compensate" "$@"
