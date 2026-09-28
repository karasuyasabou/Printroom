#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
configuration=debug
if [[ "${1:-}" == "--release" ]]; then
  configuration=release
fi
swift build -c "$configuration" --disable-sandbox
mkdir -p scratch/viewport-qa/roll
# Copy reference samples unchanged, appending only a replacement IFD with orientation.
# The immutable original is never opened for writing.
python3 - <<'PY'
import struct
from pathlib import Path
source = Path('TEST/TIFF/DSC07079.tiff').read_bytes()
Path('scratch/viewport-qa/roll/.printroom.json').unlink(missing_ok=True)
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
source scripts/build-window-qa.sh
printroom_build_window_qa "$configuration" "$PWD/scratch/viewport-qa" ViewportWindowQA \
  scripts/ViewportWindowQA.swift "$PWD/scratch/viewport-qa/window-qa"
scratch/viewport-qa/window-qa "$@"
