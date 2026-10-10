# libdeflate 1.24

Source: https://github.com/ebiggers/libdeflate/releases/tag/v1.24
Archive: https://github.com/ebiggers/libdeflate/archive/refs/tags/v1.24.tar.gz
Archive SHA-256: ad8d3723d0065c4723ab738be9723f2ff1cb0f1571e8bfcf0301ff9661f475e8

Upstream lib/, libdeflate.h, common_defs.h, README.md and COPYING are unchanged.
include/CLibDeflate.h is a Printroom SwiftPM module entry point. Package.swift
builds the upstream C sources statically for the selected architecture, including
ARM/x86 runtime CPU feature detection; no Homebrew, system libdeflate, native CPU
compiler flags or downloaded binary dependency is required. MIT license: COPYING.
TIFF encoding uses libdeflate_zlib_compress, not raw DEFLATE or gzip.
