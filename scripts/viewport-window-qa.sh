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
mkdir -p scratch/viewport-qa/roll
# Copy reference samples unchanged, appending only a replacement IFD with orientation.
# The immutable original is never opened for writing.
python3 - <<'PY'
import struct
from pathlib import Path
source = Path('TEST/DSC07079.tiff').read_bytes()
order = '<' if source[:2] == b'II' else '>'
offset = struct.unpack_from(order + 'I', source, 4)[0]
count = struct.unpack_from(order + 'H', source, offset)[0]
entries = [source[offset+2+i*12:offset+14+i*12] for i in range(count)]
entries = [entry for entry in entries if struct.unpack_from(order+'H', entry)[0] != 274]
for orientation, name in [(1, '01-original'), (6, '02-rotate90'), (2, '03-mirror')]:
    data = bytearray(source)
    updated = entries + [struct.pack(order+'HHI', 274, 3, 1) + struct.pack(order+'H', orientation) + b'\0\0']
    updated.sort(key=lambda entry: struct.unpack_from(order+'H', entry)[0])
    struct.pack_into(order+'I', data, 4, len(data))
    data += struct.pack(order+'H', len(updated)) + b''.join(updated) + b'\0'*4
    Path(f'scratch/viewport-qa/roll/{name}.tiff').write_bytes(data)
PY
app_sources=()
for source_file in Sources/PrintroomApp/*.swift; do
  [[ "$source_file" == "Sources/PrintroomApp/PrintroomApp.swift" ]] || app_sources+=("$source_file")
done
xcrun swiftc -parse-as-library -module-name ViewportWindowQA "${optimization[@]}" -I ".build/$configuration/Modules" \
  "${app_sources[@]}" scripts/ViewportWindowQA.swift \
  .build/"$configuration"/PrintroomCore.build/*.swift.o -o scratch/viewport-qa/window-qa
cp -R .build/"$configuration"/Printroom_PrintroomCore.bundle scratch/viewport-qa/
scratch/viewport-qa/window-qa
