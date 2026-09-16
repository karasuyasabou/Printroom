#!/bin/bash
set -euo pipefail
find .build/release/LibRaw.build -name '*.o' ! -name '*_ph.cpp.o' > scratch/raw-lowres-study/objects.txt
clang++ -std=c++17 -O2 -I ThirdParty/LibRaw scripts/raw-lowres-study/decode.cpp -Wl,-filelist,scratch/raw-lowres-study/objects.txt -o scratch/raw-lowres-study/decode
