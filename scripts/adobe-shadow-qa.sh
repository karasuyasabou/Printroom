#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Uses already-built production Core objects; avoids other agents' build locks.
# Build current production objects first: scripts/build-app.sh
# An isolated SwiftPM configuration directory can be supplied for agent work.
native_build_root="${PRINTROOM_NATIVE_BUILD_ROOT:-$PWD/.build/release}"
if [[ ! -f "$native_build_root/Modules/PrintroomCore.swiftmodule" ]]; then
  echo 'Missing release objects. Run scripts/build-app.sh first.' >&2
  exit 1
fi
qa_root="$PWD/scratch/adobe-shadow-qa"
mkdir -p "$qa_root"
source scripts/native-raw-link.sh
printroom_native_link_args "$native_build_root" "$qa_root"
xcrun swiftc -parse-as-library -swift-version 6 -O "${native_raw_flags[@]}" \
  -module-cache-path "$qa_root/ModuleCache" -I "$native_build_root/Modules" \
  Sources/PrintroomCore/AdobeShadowBundle.swift scripts/AdobeShadowQA.swift \
  "$native_build_root"/PrintroomCore.build/*.swift.o -o "$qa_root/probe"
"$qa_root/probe" "$@"
