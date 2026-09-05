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
dngspike verify <in> <out> [--wb] [--adobe] quality + compatibility of one pair
dngspike bench [--set 1|2|both] [--only PATTERN] [--frames a,b] [--throughput N --inflight K]
               [--adobe] [--no-wb] [--out DIR] [--csv PATH] [--resume PATH]
```

`convert` options select a row of the matrix: `--decode apple|native|libraw|
libraw-demosaic`, `--output cfa|linear`, `--demosaic metal|bin2`, `--encode
lj92|jxl|jpeg8|hwjpeg|raw`, `--distance/--effort/--speed` (JPEG XL),
`--curve linear|lut|cubic`, `--megapixels N`, `--tile N` (0 = one tile),
`--pedestal N`, `--baseline-exposure EV`, `--headroom N` (Apple path).

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
| quality (means, PSNR/SSIM, white-balance pushes) and compatibility | `Verify.swift` |
| the matrix and the CSV | `Bench.swift` |
| the report tables from the CSV | `scripts/report-tables.py` |

Kit pieces the spike added and the app reuses: `LosslessJPEGDecoder`, the
interleaved-component `LosslessJPEG.encode`, `DNGArchive` (the DNG 1.4/1.7
tiled writer), `DNGCapabilityProbe`, public `DNGDocument.parseDirectories`
and the `DNGTagValue` value readers.
