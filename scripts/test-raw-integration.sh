#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
export PRINTROOM_RAW_NATIVE=1
export PRINTROOM_RAW_INTEGRATION=1
export PRINTROOM_RAW_FULL_ROLL=1
# Requires local Adobe DNG Converter, TEST/RAW, and retained independent reference
# TIFFs in scratch/raw-adobe-study/reference. Copies RAW into a new scratch roll.
# SourceImageIO intentionally uses its real application cache for this test.
/usr/bin/time -l swift test -c release --disable-sandbox \
  --filter 'RawDecoderTests|RawIntegrationTests.testRealAdobeSourceProxyPrecisionAndExports'
/usr/bin/time -l swift test -c release --disable-sandbox --skip-build \
  --filter RawIntegrationTests.testRealFullRollExportPerformance
