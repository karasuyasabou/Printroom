#!/bin/bash
# Sourced by standalone Swift QA drivers after a normal SwiftPM build.
# $1: SwiftPM configuration directory; $2: scratch directory for the object list.
printroom_native_link_args() {
  local native_build_root="$1" native_scratch_root="$2"
  local native_filelist="$native_scratch_root/native-raw-objects.txt"
  mkdir -p "$native_scratch_root"
  find "$native_build_root/LibRaw.build" "$native_build_root/CRawBridge.build" \
    -type f -name '*.o' ! -name '*_ph.cpp.o' > "$native_filelist"
  if [[ ! -s "$native_filelist" ]]; then
    echo 'Missing native RAW objects; rebuild with SwiftPM first.' >&2
    return 1
  fi
  native_raw_flags=(-I "$PWD/Sources/CRawBridge/include" \
    -Xcc "-fmodule-map-file=$native_build_root/CRawBridge.build/module.modulemap" \
    -Xlinker -filelist -Xlinker "$native_filelist" -lc++)
}
