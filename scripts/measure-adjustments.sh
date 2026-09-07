#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
mkdir -p scratch/adjustment-performance
flags=(--disable-sandbox)
if [[ "${1:-}" == "--legacy-renderer" ]]; then
    flags+=(-Xswiftc -DPRINTROOM_LEGACY_ADJUSTMENT_RENDERER)
elif [[ -n "${1:-}" ]]; then
    echo "Usage: scripts/measure-adjustments.sh [--legacy-renderer]" >&2
    exit 64
fi
# Build without opt-in first; renderer and editor each run in a fresh process.
# --legacy-renderer exists for running this identical harness on the saved
# pre-optimization source tree, whose renderer lacks an input identity parameter.
swift test -c release "${flags[@]}" --filter AdjustmentPerformanceMeasurements \
    > scratch/adjustment-performance/build.log 2>&1
for mode in renderer editor; do
    PRINTROOM_ADJUSTMENT_PERFORMANCE="$mode" \
      swift test -c release --skip-build "${flags[@]}" \
        --filter AdjustmentPerformanceMeasurements \
        2>&1 | tee "scratch/adjustment-performance/$mode.log"
done
