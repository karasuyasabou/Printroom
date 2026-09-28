#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
configuration=debug
if [[ "${1:-}" == "--release" ]]; then
  configuration=release
fi
if [[ " $* " != *" --skip-build "* ]]; then
  swift build --build-system native -c "$configuration" --disable-sandbox
fi
mkdir -p scratch/crop-qa/roll
python3 - <<'PY'
from pathlib import Path
import shutil, os
source = Path(os.environ.get('PRINTROOM_CROP_QA_SOURCE', 'TEST/TIFF/DSC07079.tiff'))
roll = Path('scratch/crop-qa/roll')
for name in ['01-original.tiff', '02-sync.tiff']:
    target = roll / name
    if not target.exists():
        shutil.copy2(source, target)
(roll / '.printroom.json').unlink(missing_ok=True)
PY
source scripts/build-window-qa.sh
printroom_build_window_qa "$configuration" "$PWD/scratch/crop-qa" CropWindowQA \
  scripts/CropWindowQA.swift "$PWD/scratch/crop-qa/window-qa"
scratch/crop-qa/window-qa "$@"
