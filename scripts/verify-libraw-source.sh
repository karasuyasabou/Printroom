#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
libraw_tmp=$(mktemp -d "${TMPDIR:-/tmp}/printroom-libraw.XXXXXX")
trap 'rm -rf "$libraw_tmp"' EXIT
libraw_archive=${1:-}
if [[ -z "$libraw_archive" ]]; then
  libraw_archive="$libraw_tmp/LibRaw-0.22.1.tar.gz"
  curl --fail --location --proto '=https' --tlsv1.2 \
    https://www.libraw.org/data/LibRaw-0.22.1.tar.gz -o "$libraw_archive"
fi
libraw_hash=$(shasum -a 256 "$libraw_archive" | cut -d ' ' -f 1)
[[ "$libraw_hash" == a789dc4e2409e2901d93793a4e0b80c7b49d0d97cf6ad71c850eb7616acfd786 ]] || { echo 'LibRaw archive hash mismatch' >&2; exit 1; }
tar -xzf "$libraw_archive" -C "$libraw_tmp"
for libraw_item in src internal libraw COPYRIGHT LICENSE.CDDL LICENSE.LGPL; do
  diff -r "$libraw_tmp/LibRaw-0.22.1/$libraw_item" "ThirdParty/LibRaw/$libraw_item"
done
echo 'LibRaw 0.22.1 source and licenses match the pinned official archive.'
