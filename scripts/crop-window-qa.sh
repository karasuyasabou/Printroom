#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
configuration=debug
optimization=(-Onone)
if [[ "${1:-}" == "--release" ]]; then
  configuration=release
  optimization=(-O)
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
app_sources=()
for source_file in Sources/PrintroomApp/*.swift; do
  [[ "$source_file" == "Sources/PrintroomApp/PrintroomApp.swift" ]] || app_sources+=("$source_file")
done
source scripts/native-raw-link.sh
printroom_native_link_args "$PWD/.build/$configuration" "$PWD/scratch/crop-qa"
xcrun swiftc "${native_raw_flags[@]}" -parse-as-library -g -module-name CropWindowQA "${optimization[@]}" -I ".build/$configuration/Modules" \
  "${app_sources[@]}" scripts/CropWindowQA.swift \
  .build/"$configuration"/PrintroomCore.build/*.swift.o -o scratch/crop-qa/window-qa
cp -R .build/"$configuration"/Printroom_PrintroomCore.bundle scratch/crop-qa/
scratch/crop-qa/window-qa "$@"
