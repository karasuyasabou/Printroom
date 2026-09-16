# DiVERE paper curve sources

MIT, Copyright (c) 2025 V7; full license in LICENSE.
Read-only source: /Users/bao/Desktop/DiVERE, Git HEAD 95203876abd16efd787d81840a48ae86ab3155b5, copied 2026-09-13.

- curves/: the five requested original JSON files from config/curves/.
- KodakEnduraPremier.json: original config/colorspace/ working space definition (D60).
- KodakEnduraPremier_Linear.icc: original config/colorspace/icc/ linear profile; colorants already adapted to D50 PCS.
- math_ops.py: original divere/core/math_ops.py, retained for reproducible isolated reference-method validation. Not imported by the application.

The derived LUTs are authored by Printroom using these sources; they are not Kodak-supplied or officially certified LUTs. Conversion policy and limitations: docs/pipeline.md §8 in the Printroom source. No DiVERE scan files were copied or modified.
