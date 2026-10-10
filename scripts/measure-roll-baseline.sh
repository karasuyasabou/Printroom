#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
base="$PWD/scratch/performance"
mkdir -p "$base"
export CLANG_MODULE_CACHE_PATH="$base/build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$base/build/ModuleCache"
flags=(--scratch-path "$base/build" --build-system native -c release --disable-sandbox --no-parallel -Xswiftc -DPRINTROOM_PERFORMANCE_TRACE)
if [[ "${1:-}" == "--build" ]]; then
  swift test "${flags[@]}" --filter RollPerformanceMeasurements
  exit
fi
if [[ $# -lt 4 || $# -gt 6 ]]; then
  echo 'Usage: measure-roll-baseline.sh --build | MODE COPIED_ROLL ISOLATED_CACHE NEW_REPORT [CONCURRENCY=4] [COUNT=36]' >&2
  exit 64
fi
case "$1" in import|sync|derive-tiff|export-none|export-deflate|export-jpeg) ;; *) exit 64 ;; esac
# The model persists settings; refuse original/user folders and default application caches.
for path in "$2" "$3" "$4"; do
  [[ "$path" == "$base/"* && "$path" != *'/../'* ]] || { echo 'Paths must be absolute, under scratch/performance.' >&2; exit 64; }
done
[[ ! -e "$4" ]] || { echo 'Report already exists; use a new name.' >&2; exit 64; }
mkdir -p "$3" "$(dirname "$4")"
export PRINTROOM_TRACE="${PRINTROOM_TRACE:-1}" PRINTROOM_TRACE_CACHE_ROOT="$3"
export PRINTROOM_BENCH_MODE="$1" PRINTROOM_BENCH_ROLL="$2" PRINTROOM_BENCH_REPORT="$4"
export PRINTROOM_BENCH_CONCURRENCY="${5:-4}" PRINTROOM_BENCH_COUNT="${6:-36}"
/usr/bin/time -l swift test "${flags[@]}" --skip-build --filter RollPerformanceMeasurements.measureRoll
