# dng-probe — investigation scripts behind the lossy-DNG work (2026-09-05)

Small, standalone tools used to diagnose why Adobe lossy DNGs render green in
Apple's decoder and to measure the repack that fixed it (`LossyLinearDNG`).
They are the starting kit for `docs/dng-archive-spike-brief.md`. None of them
modify their inputs; the patcher writes a new file.

Python ones run with `tools/.venv/bin/python` (numpy + OpenCV present):

| script | what |
|---|---|
| `dngtags.py <dng…>` | dumps every IFD (IFD0, SubIFDs, Exif) with named DNG tags |
| `mappoly.py one <dng…>` / `all <dir> [step]` | per-plane `MapPolynomial` coefficients + black levels, one file or a whole set |
| `opcodes.py <dng…>` | decodes OpcodeList1/2/3 (WarpRectilinear, FixVignetteRadial, GainMap, MapPolynomial) and prints the XMP packet |
| `patch.py <in> <out> <variant>` | writes a tag-patched copy: `black0`, `uni:<n>`, `noops`, `polyident`, `polyall0`, `fold`, `foldped[:r,g,b]`, `blackswapRB`, … — the experiments that isolated Apple's black-level bug |

Swift ones compile with `swiftc -O -o <name> <name>.swift` (macOS) or, for the
`_ios` ones, `-sdk $(xcrun --sdk iphonesimulator --show-sdk-path) -target
arm64-apple-ios17.0-simulator` and run with `xcrun simctl spawn <udid>`:

| script | what |
|---|---|
| `rawstat.swift ciraw\|imageio <file> <out.png\|-> [scale] [boost]` | renders through `CIRAWFilter` (app settings: boost 0, EDR 2) or ImageIO and prints whole-frame / darkest-10% / brightest-10% channel means in linear P3 |
| `parity.swift <file…>` | `CIRAWFilter(imageURL:)` vs `CIRAWFilter(imageData:)` — identical for DNG, the data path fails for ARW |
| `tiles.swift <dng>` | tile geometry, edge-tile dimensions, serial vs parallel JPEG XL tile decode timing through ImageIO |
| `jxl.swift <tile.jxl>` | decodes one bare JPEG XL codestream and prints raw sample ranges straight off the data provider |
| `enc_ios.swift` | `CGImageDestination` / `CGImageSource` type identifiers (is there a JPEG XL encoder?) |
| `vt_ios.swift` | `VTCopyVideoEncoderList` with hardware flags (is there a `jxlc` encoder?) |

Findings these produced are recorded in `docs/TODO.md` ("Lossy DNG stage 2")
and the spike brief.
