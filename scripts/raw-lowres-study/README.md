# Direct LibRaw low-resolution experiment

Run from the repository root. This uses existing release LibRaw objects and never changes the production decoder. The fixed source is the user-authorized 2026-07-06-2/RAW roll; only scratch outputs are written.

```sh
mkdir -p scratch/raw-lowres-study
bash scripts/raw-lowres-study/build.sh
PYTHONPATH=scratch/raw-adobe-study/pylibs /Users/bao/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 scripts/raw-lowres-study/measure.py
PYTHONPATH=scratch/raw-adobe-study/pylibs /Users/bao/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 scripts/raw-lowres-study/visualize.py
```

Requires NumPy, Pillow and tifffile from the existing study environment. Comparison requires the unchanged source revisions and the Adobe proxies prepared by the previous diagnostic under scratch/raw-open-measure/cache. Missing prerequisites fail rather than silently changing the baseline. build.sh requires a completed release SwiftPM build.

Both variants directly decode ARW using LibRaw 0.22.1, unit white balance, camera RGB, linear output, no automatic brightness; half_size is the experimental variable. Full uses AHD. Decode output is reduced with nearest-neighbour sampling to 1600×1066 and written as packed UInt16 RGB. Each variant runs 37 frames with four subprocess workers; elapsed time includes process startup and packed output, but excludes source hashing, TIFF compression, production cache management, and UI rendering. OS file caches are not flushed. Neither timing is an application launch benchmark.

visualize.py is an independent NumPy illustration of the documented density-v5 pipeline, using the saved calibration and frame adjustments, then converting P3 to sRGB for display. It applies saved orientation but not crop, and is not a production-renderer equivalence test. All three illustrated frames use Kodak 2383. Linear comparisons use every sample of the 1600 proxy; visual metrics use every second row/column before rendering. No fitting, exposure compensation, or recalibration is performed.
