# dngspike — the DNG archive-conversion spike

The command-line half of `docs/dng-archive-spike-brief.md`: raw → lossy /
resized DNG on Apple Silicon, using only frameworks and techniques that also
exist on iOS, measured. The report it produced lives in
`docs/dng-archive-spike/`.

## Build

```bash
cd LetsLapse/tools/dng-spike
swift build -c release                          # the iOS-ready core, no third-party code
swift build -c release --traits JXL,LibRaw      # + libjxl and LibRaw from Homebrew
swift test --traits JXL,LibRaw                  # package tests (real-file tests skip without the volume)
```

The two codecs are SwiftPM package traits so the core stays visible: without
them `--encode jxl` and `--decode libraw` fail with a message and everything
else runs. Homebrew (`brew install jpeg-xl libraw`) supplies the Mac builds;
`scripts/build-xcframeworks.sh` builds both as static XCFrameworks for iOS,
the simulator and macOS from their release sources.

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
| decoders — Apple (`CIRAWFilter`), native Kit parse + lossless JPEG, LibRaw | `AppleDecoder.swift`, `NativeDecoder.swift`, `LibRawDecoder.swift` |
| Metal demosaic (Malvar-He-Cutler), 2×2 superpixel, MPS Lanczos resize | `Demosaic.swift` |
| stored-value curves and the DNG levels that undo them | `StoredEncoding.swift` |
| tile codecs — Kit lossless JPEG, libjxl, ImageIO JPEG, VideoToolbox JPEG | `Encoders.swift`, `JXLEncoder.swift` |
| the pipeline and the strategy vocabulary | `Pipeline.swift` |
| quality (means, PSNR/SSIM, white-balance pushes) and compatibility | `Verify.swift` |
| the matrix and the CSV | `Bench.swift` |

Kit pieces this spike added (reused by the app): `LosslessJPEGDecoder`, the
interleaved-component `LosslessJPEG.encode`, `DNGArchive` (the DNG 1.4/1.7
tiled writer), `DNGCapabilityProbe`, public `DNGDocument.parseDirectories`
and the `DNGTagValue` value readers.
