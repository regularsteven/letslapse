# dngspike — the DNG archive-conversion spike

The command-line half of `docs/dng-archive-spike-brief.md`: raw → lossy /
resized DNG on Apple Silicon, using only frameworks and techniques that also
exist on iOS, measured. The report it produced lives in
`docs/dng-archive-spike/`.

## Build

```bash
cd LetsLapse/tools/dng-spike
swift build -c release        # links the Kit, which carries libjxl and LibRaw as static binary targets
swift test                    # package tests (real-file tests skip without the volume)
```

The conversion pipeline itself lives in the Kit (`Kit/Sources/LetsLapseKit/Archive/`),
with libjxl (BSD-3) and LibRaw (CDDL-1.0) as `binaryTarget` XCFrameworks under
`Kit/Binaries/`, built from their release sources by
`scripts/build-xcframeworks.sh`; this package is the measuring instrument
around it. The app's "Duplicate as DNG archive…" (project menu) and the
`LL_DNGARCHIVE` launch hook run the same `DNGArchive.Converter`.

## Commands

```
dngspike probe [--json]                    capability table (ImageIO / VideoToolbox / Metal / jxlc)
dngspike convert <in> <out> [options]      one frame, one strategy; prints stage timings
dngspike verify <in> <out> [--wb] [--adobe] [--bands N]  quality + compatibility of one pair
                                           (--bands: green means per vertical band, for ramps)
dngspike validate <dng…> [--adobe]         structural checks (DNGArchive.validate) + DNG Converter's verdict
dngspike synth flat-gain|noise|gradient|flat <out.dng> [--level L] [--mean V] [--sigma S]
               [--map-from DNG] [--black N] [--white N]   known-content CFA DNGs for decoder tests
dngspike bench [--set 1|2|both] [--only PATTERN] [--frames a,b] [--throughput N --inflight K]
               [--adobe] [--no-wb] [--out DIR] [--csv PATH] [--resume PATH]
```

`convert` options select a row of the matrix: `--decode apple|native|libraw|
libraw-demosaic`, `--output cfa|linear`, `--demosaic metal|bin2`, `--encode
lj92|jxl|jpeg8|hwjpeg|raw`, `--distance/--effort/--speed` (JPEG XL),
`--curve linear|lut|toe|cubic` (`--toe T` for the toe's knee, default
0.0033; the app's lossy default is `toe` over `--pedestal 12288`), `--rgb`
(JPEG XL without XYB), `--megapixels N`, `--tile N` (0 = one tile),
`--pedestal N`, `--baseline-exposure EV`, `--headroom N` (Apple path).

Validation against Adobe (report §8) used DNG Converter's own linear
conversion as the yardstick: `"…/Adobe DNG Converter" -l -u -p0 -d DIR -o
NAME.dng IN.dng` on the original and on our archive, then a sample-for-sample
camera-space comparison of the two uncompressed LinearRaws (a 60-line numpy
script; block-mean grids, not value bins — see the trap in §7).

The same capability probe runs on a device behind the app's `LL_DNGPROBE=1`
launch hook (`xcrun devicectl device process launch --console -e
'{"LL_DNGPROBE":"1"}' com.regularsteven.letslapse`).

## What lives where

| piece | file |
|---|---|
| decoders — Apple (`CIRAWFilter`), native Kit parse + lossless JPEG, LibRaw | Kit `Archive/DNGArchiveDecoders.swift` |
| Metal demosaic (Malvar-He-Cutler), 2×2 superpixel, MPS Lanczos resize | Kit `Archive/DNGArchiveDemosaic.swift` |
| stored-value curves and the DNG levels that undo them | Kit `Archive/DNGArchiveCurves.swift` |
| tile codecs — Kit lossless JPEG, libjxl, ImageIO JPEG, VideoToolbox JPEG | Kit `Archive/DNGArchiveEncoders.swift`, `DNGArchiveJXL.swift` |
| the pipeline (`DNGArchive.Strategy` / `Converter`), sequence conversion | Kit `Archive/DNGArchiveConverter.swift` |
| quality (means, PSNR/SSIM, white-balance pushes, per-channel/region means, bands) and compatibility | `Verify.swift` |
| synthetic flat / gain-map / noise / gradient CFA DNGs | `Synth.swift` |
| DNG opcode lists (GainMap parse, the Metal bake) | Kit `Archive/DNGArchiveOpcodes.swift`, `DNGArchiveDemosaic.swift` |
| structural validation of a written DNG | Kit `DNGArchive.validate` |
| the matrix and the CSV | `Bench.swift` |
| the report tables from the CSV | `scripts/report-tables.py` |

Kit pieces the spike added and the app reuses: `LosslessJPEGDecoder`, the
interleaved-component `LosslessJPEG.encode`, `DNGArchive` (the DNG 1.4/1.7
tiled writer), `DNGCapabilityProbe`, public `DNGDocument.parseDirectories`
and the `DNGTagValue` value readers.
