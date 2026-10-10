#!/usr/bin/env python3
"""Independently verify classic little-endian TIFF exports, without color conversion.
Usage: verify-deflate-outputs.py BASELINE_DIRECTORY CANDIDATE_DIRECTORY [...]
Uses Python's system zlib and raw TIFF tags; never modifies inputs.
"""
import hashlib
import json
import pathlib
import struct
import sys
import zlib


def inspect(path):
    with path.open('rb') as f:
        header = f.read(8)
        assert header[:4] == b'II*\x00', path
        f.seek(struct.unpack_from('<I', header, 4)[0])
        entries = [f.read(12) for _ in range(struct.unpack('<H', f.read(2))[0])]
        assert f.read(4) == b'\x00' * 4, 'Expected single page'
        tags = {}
        for entry in entries:
            tag, kind, count, offset = struct.unpack('<HHII', entry)
            size = {3: 2, 4: 4, 7: 1}[kind] * count
            if size <= 4:
                data = entry[8:8 + size]
            else:
                f.seek(offset)
                data = f.read(size)
            assert len(data) == size
            tags[tag] = data
        def integers(tag, size=4):
            data = tags[tag]
            return struct.unpack('<' + ('I' if size == 4 else 'H') * (len(data) // size), data)
        width, height = integers(256)[0], integers(257)[0]
        assert integers(258, 2) == (16, 16, 16)
        assert integers(259, 2) == (8,)
        assert integers(262, 2) == (2,)
        assert integers(274, 2) == (1,)
        assert integers(277, 2) == (3,)
        assert integers(284, 2) == (1,)
        assert integers(339, 2) == (1, 1, 1)
        rows = integers(278)[0]
        offsets, counts = integers(273), integers(279)
        assert len(offsets) == len(counts) == (height + rows - 1) // rows
        pixel_hash = hashlib.sha256()
        file_size = path.stat().st_size
        for i, (offset, count) in enumerate(zip(offsets, counts)):
            assert 0 < count and offset + count <= file_size
            f.seek(offset)
            decoder = zlib.decompressobj()
            decoded = decoder.decompress(f.read(count)) + decoder.flush()
            assert decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail
            assert len(decoded) == width * 6 * min(rows, height - rows * i)
            pixel_hash.update(decoded)
        return dict(width=width, height=height, strips=len(offsets),
                    RGB_SHA256=pixel_hash.hexdigest(),
                    ICC_SHA256=hashlib.sha256(tags[34675]).hexdigest(), bytes=file_size)


def main():
    baseline = pathlib.Path(sys.argv[1])
    reference = {p.name: inspect(p) for p in sorted(baseline.glob('*.tiff'))}
    assert len(reference) == 4, 'Expected the four-photo fixture'
    report = {}
    for directory in map(pathlib.Path, sys.argv[2:]):
        files = {p.name: inspect(p) for p in sorted(directory.glob('*.tiff'))}
        assert files.keys() == reference.keys()
        for name, result in files.items():
            assert {k: v for k, v in result.items() if k != 'bytes'} == {
                k: v for k, v in reference[name].items() if k != 'bytes'}, name
        report[str(directory)] = files
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
