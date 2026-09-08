#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
configuration=debug
optimization=()
if [[ "${1:-}" == "--release" ]]; then
  configuration=release
  optimization=(-O)
fi
swift build -c "$configuration" --disable-sandbox
mkdir -p scratch/crop-qa/roll
python3 - <<'PY'
from pathlib import Path
import shutil
source = Path('TEST/DSC07079.tiff')
roll = Path('scratch/crop-qa/roll')
for name in ['01-original.tiff', '02-sync.tiff']:
    target = roll / name
    if not target.exists():
        shutil.copy2(source, target)
(roll / '.printroom.json').unlink(missing_ok=True)
PY
app_sources=()
for source_file in Sources/PrintroomApp/*.swift; do
  [[ "$source_file" == "Sources/PrintroomApp/PrintroomApp.swift" ]] || app_sources+=("$source_file")
done
xcrun swiftc -parse-as-library -module-name CropWindowQA "${optimization[@]}" -I ".build/$configuration/Modules" \
  "${app_sources[@]}" scripts/CropWindowQA.swift \
  .build/"$configuration"/PrintroomCore.build/*.swift.o -o scratch/crop-qa/window-qa
cp -R .build/"$configuration"/Printroom_PrintroomCore.bundle scratch/crop-qa/
scratch/crop-qa/window-qa "$@"
