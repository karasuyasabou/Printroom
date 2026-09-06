#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
mkdir -p scratch/performance
# Each comparison uses a fresh test process; OS file cache is not forcibly
# purged, so these are warm-filesystem local workflow measurements.
if [[ "${1:-}" == "--export" ]]; then
    swift test -c release --disable-sandbox --filter ImagePerformanceMeasurements.measureBatchExport > scratch/performance/export-build.log 2>&1
    for profile in p3 proPhoto; do
        PRINTROOM_EXPORT_PERFORMANCE="$profile" \
          swift test -c release --disable-sandbox --skip-build --filter ImagePerformanceMeasurements.measureBatchExport \
          2>&1 | tee "scratch/performance/export-$profile.log"
    done
elif [[ -z "${1:-}" ]]; then
    swift test -c release --disable-sandbox --filter ImagePerformanceMeasurements.measureReferenceWorkflow > scratch/performance/build.log 2>&1
    for mode in legacy optimized; do
        PRINTROOM_PERFORMANCE=1 PRINTROOM_PERFORMANCE_MODE="$mode" \
          swift test -c release --disable-sandbox --skip-build --filter ImagePerformanceMeasurements.measureReferenceWorkflow \
          2>&1 | tee "scratch/performance/$mode.log"
    done
else
    echo "Usage: scripts/measure-performance.sh [--export]" >&2
    exit 64
fi
