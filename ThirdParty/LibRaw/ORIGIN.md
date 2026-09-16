# LibRaw 0.22.1

Official release: https://www.libraw.org/data/LibRaw-0.22.1.tar.gz

Archive SHA-256: `a789dc4e2409e2901d93793a4e0b80c7b49d0d97cf6ad71c850eb7616acfd786`.

The `src/`, `internal/`, `libraw/`, COPYRIGHT and license files are unmodified
files from that release. Printroom elects **CDDL 1.0** for LibRaw. Copyright and
additional source-level notices are retained, including embedded BSD/MIT notices.
The alternative upstream LGPL text is also preserved for completeness.

SwiftPM builds the source as a static C++17 target with the platform compiler;
no downloaded binary, Python, Go, rawpy, Siril, or separately installed runtime
is used. The 79 compiled C++ files match upstream Makefile.am; alternative
`*_ph.cpp` placeholders and the source Makefile are excluded from compilation. Optional Jasper, JPEG, LCMS, OpenMP, RawSpeed and DNG SDK integrations
are disabled/not enabled. The supported input is uncompressed UInt16 Linear DNG
from Adobe DNG Converter, checked by CRawBridge before LibRaw opens it.

`scripts/verify-libraw-source.sh` checks the vendored source against the official
archive (accepts a local archive path, otherwise downloads the public source).
The normal `scripts/build-app.sh` / `scripts/test.sh` compile LibRaw from source
without network access. The application includes these source and license files
under Resources/ThirdParty/LibRaw to make the CDDL-covered source available with
the executable. Adobe DNG Converter remains a separately installed application.
