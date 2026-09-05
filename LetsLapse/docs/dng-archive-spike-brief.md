# DNG archive conversion — spike brief

**For:** a fresh agent, working on the `ios-app` branch of this repository.
**Written:** 2026-09-05 (Steven Wright with Claude), after the lossy-DNG
investigation recorded in `docs/TODO.md` ("Lossy DNG stage 2") and the memory
note `adobe-lossy-dng-apple-decoder-bug`.
**Status:** not started. This document is the whole hand-over; nothing in it
assumes the conversation it came from.

---

## 1. Goal

LetsLapse shoots and imports raw timelapse sequences that are far too large to
keep: a Sony ARW frame is 18.7 MB, a LetsLapse-captured blended Bayer DNG is
17.3 MB, and a sequence is hundreds of frames. Adobe DNG Converter turns the
same ARW into a **1.3 MB lossy JPEG XL DNG at 10 megapixels** that still edits
like raw — white balance and tint stay metadata, the data stays scene-linear —
and LetsLapse now decodes those files correctly (`LossyLinearDNG`, committed
`ffe61ca`). Steven does that conversion by hand today. The long-term goal is
to do it **inside LetsLapse, on iPhone, iPad and Mac**, for two kinds of input:

1. third-party camera raw files (Sony ARW, Canon CR2/CR3, Nikon NEF, …) → DNG;
2. LetsLapse's own captured DNGs → smaller DNG;

with **lossy compression** and **resize to N megapixels** as the two levers,
and with **speed** taken seriously: if conversion can approach real time, the
storage bottleneck that shapes every long shoot goes away.

This spike is the first step: a **standalone command-line tool on Apple Silicon
macOS**, written in Swift, using only frameworks and techniques that are also
available on iOS, that converts the two test sets below and **reports** which
strategies are viable, how long they take, how big and how good the output is,
and what the hardware can do. The decision on which direction to pursue is made
from those reports, not in this brief.

**Explicit non-goals:** JPEG, HEIC or any display-referred output (they bake
white balance and tone in; they are not what this is for); any UI; any
dependency on Adobe DNG Converter at run time (it is a *reference*, see §5);
Windows/Linux.

## 2. What is already established (do not re-derive)

Measured on this Mac (M4 Max, macOS 15.6.1, Xcode 26.1) and the iOS 18.6 and
26.1 simulators on 2026-09-05 unless stated:

- **DNG is an open, royalty-free specification and, since January 2026, an ISO
  standard: ISO 12234-4:2026.** It covers the JPEG XL fields (`JXLDistance`,
  `JXLEffort`, `JXLDecodeSpeed`, compression 52546), the `MapPolynomial`
  opcode, floating-point and 64-bit data. Anyone may write lossy JPEG XL DNGs.
- **Apple's frameworks decode JPEG XL but do not encode it.**
  `CGImageDestinationCopyTypeIdentifiers()` lists no `public.jpeg-xl` on
  macOS 15.6.1, iOS 18.6 sim or iOS 26.1 sim; `CGImageSourceCopyTypeIdentifiers()`
  lists it everywhere. AVFoundation declares `AVVideoCodecTypeJPEGXL` (`'jxlc'`,
  `kCMVideoCodecType_JPEG_XL`) as available since macOS 15.0 / iOS 18.0, but
  `VTCopyVideoEncoderList` registers **no `jxlc` encoder** on this Mac or the
  simulators. iPhone 16 Pro (A18) writes JPEG XL ProRAW through its camera
  pipeline, so a `jxlc` VideoToolbox encoder may exist on real devices. **The
  spike must probe real hardware** (§6.1). Hardware encoders that *are*
  registered on this Mac: `JPEG (HW)`, `Apple HEVC (HW)`, `Apple H.264 (HW)`,
  `AppleProResHW 422/4444`.
- **Apple's DNG decoder mis-renders Adobe's lossy DNGs** (green wash): it
  mishandles `BlackLevel` whenever `MapPolynomial` opcodes are present, and it
  wraps negative polynomial output to bright instead of clamping. Identical on
  macOS 15.6, iOS 18.6 and iOS 26.1 sims. LetsLapse works around it by
  repacking such files in memory (`Kit/Sources/LetsLapseKit/Grading/LossyLinearDNG.swift`).
  **Consequence for a writer:** a DNG this spike produces must render correctly
  in Apple's decoder *without* the repack — use a uniform `BlackLevel` (or 0)
  and **no** `MapPolynomial`. Adobe's linear-lossless output (uniform black
  2048, no opcodes) is the proven-good shape.
- **ImageIO exposes no colour calibration for an ARW** (no `{DNG}` dictionary,
  only Exif/TIFF/ExifAux) and no API returns an ARW's Bayer mosaic. Apple's
  `CIRAWFilter` hands back *demosaiced, white-balanced, camera-profiled* linear
  pixels (in the app: `boostAmount 0`, `extendedDynamicRangeAmount 2`,
  working space extended linear Display P3). A DNG written from that is
  scene-linear with headroom and edits well (white balance as a relative
  shift), but it is **not camera-native raw**. Camera-native output from an
  ARW needs a raw decoder of our own (§4, strategy A2).
- **LetsLapse's captured DNGs (Set 2) are already Bayer DNGs the Kit wrote
  itself**, so their mosaic is fully accessible without Apple's decoder — once
  the spike has a lossless-JPEG *decoder*, which the Kit lacks (it has only the
  encoder).
- **Adobe DNG Converter 18.6 is installed** at
  `/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter`
  and scriptable: `-lossy`, `-side <px>`, `-count <pixels>`, `-jxl_distance <d>`,
  `-c` (lossless), `-l` (linear/demosaiced), `-p0` (no preview), `-cr7.1` /
  `-dng1.4` (legacy 8-bit lossy JPEG), `-d <dir>`, `-o <name>`. It is the
  quality and size **reference**, not a dependency.
- Reference numbers, same 486-frame ILCE-7M4 dusk→night sequence:

  | container | per frame | Apple decoder |
  |---|---|---|
  | Sony ARW (camera) | 18.7 MB | correct |
  | Adobe lossless CFA DNG | 12.2 MB | correct |
  | Adobe linear lossless (`-l -c`) | 40 MB | correct |
  | Adobe lossy JPEG XL, full size, distance 0.5 | 1.9 MB | wrong without repack |
  | Adobe lossy JPEG XL, 10 MP, distance 0.5 | 1.3 MB | wrong without repack |
  | Adobe lossy JPEG XL, 10 MP, distance 1.0 | 0.7 MB | wrong without repack |
  | Adobe legacy lossy JPEG (8-bit), 10 MP | 2.6 MB | wrong, differently |

- Apple's full-scale `CIRAWFilter` decode of one frame takes ~1.0–1.4 s on
  the M4 Max for every container above. ImageIO decodes the 60 JPEG XL tiles
  of a 10 MP Adobe file in ~140 ms; `LossyLinearDNG.repack` (tiles → vDSP
  stage-2 arithmetic → uncompressed DNG in memory) takes ~200 ms in a Debug
  build.
- Quality yardstick already in the tree:
  `Kit/Tests/LetsLapseKitTests/LossyLinearDNGTests.swift` decodes candidates
  and references through the same Apple pipeline at quarter scale and compares
  whole-frame and 8×6-block channel means in linear P3, flooring blocks below
  ~0.02 linear (the noise floor, where Adobe's and Apple's demosaics disagree
  by design). The repacked Adobe lossy frame sits within 1% of Adobe's own
  lossless linear conversion on whole-frame means and within 3% per block.

## 3. The test inputs

Both live on the external volume `/Volumes/letslapse` (tests must skip, not
fail, when it is not mounted). **Never write into these folders.**

**Set 1 — Sony ARW, straight from the camera.**
`/Volumes/letslapse/Projects/E854D311-96E3-49EC-8179-146DBC896E18/source/`
486 files `_WEX3879.ARW … _WEX4364.ARW`, 8.2 GB, 4608×3072, Sony ILCE-7M4,
FE 16-35mm F4, 2 s exposures at ISO 250 rising through dusk into night
(black levels and white balance drift through the sequence — 3879 is dusk,
4159 dark, 4319 night; use those three for spot checks). Sister projects of
the *same* frames, converted by Adobe DNG Converter, are the references:
`93F772E0-973C-45B2-B362-095E4D017BA1` (lossless CFA),
`8E67730E-51DF-427D-AA31-B6EDEC5BDE74` (lossy JXL full size),
`B91FD599-3931-490D-A3A0-61D4E2563E8E` (lossy JXL 10 MP, 3872×2581).

**Set 2 — captured in LetsLapse, interval mode with live blend.**
`/Volumes/letslapse/Projects/F6387DFA-216D-4EFE-8398-FF18F243E454/source/`
208 files `frame-00001.dng … frame-00208.dng`, 3.3 GB, 17.3 MB each. Written by
the Kit's `DNGAuthor.writeCompressedBayerDNG`: DNG 1.4, IFD0 holds a 512×384
8-bit preview, SubIFD 0 is the image — 4032×3024, **CFA Bayer 16-bit, lossless
JPEG (compression 7), 256×256 tiles, BlackLevel 0, WhiteLevel 65535**,
`BaselineExposure 2.0` (two stops of blend headroom pre-divided out),
`ColorMatrix1` + `AsShotNeutral` in camera-native space
(`UniqueCameraModel "iPhone17,1 back ultra wide camera"`), one `NoiseProfile`.
No opcode lists, no `ColorMatrix2`, no Exif IFD. These are the app's own files:
a converter can parse them with `DNGDocument.parseReference` and reach the
mosaic directly.

## 4. Strategies to build and measure

The spike is a **matrix**, not a single pipeline. Implement enough of each row
to measure it honestly; where a row is infeasible, the report says why with
evidence (an API that is absent, a probe that failed), not an opinion.

### A. Decode (getting pixels out of the input)

| | Strategy | Applies to | Notes |
|---|---|---|---|
| A1 | `CIRAWFilter` (Apple) | Set 1, Set 2 | iOS-available, GPU, ~1 s/frame full size; output is demosaiced, white-balanced, profiled linear P3. `scaleFactor` resamples *inside* the converter (cheap resize). Not camera-native. Open it through `LossyLinearDNG.rawFilter(for:)` so Adobe lossy inputs also work. |
| A2 | LibRaw (open source, C++) | Set 1 (and Set 2) | Camera-native mosaic + black/white levels + Adobe colour matrices for every camera family (`ImportedStills.rawExtensions` lists 23). Dual LGPL-2.1 / CDDL-1.0 — **check App Store compatibility before depending on it**. Build as an xcframework for macOS arm64 + iOS arm64 + simulator. |
| A3 | Native Kit parse + lossless-JPEG decoder | Set 2 | `DNGDocument.parseReference` gives tags and tile table; write a lossless JPEG (ITU-T T.81 process 14, predictor 1, 16-bit) **decoder** — the Kit has only `LosslessJPEG.encode`. Fast path with no colour work at all: the mosaic is already camera-native. |

### B. Demosaic, resize, colour (only where the strategy needs them)

- Demosaic is needed for a resized output or a LinearRaw (3-sample) lossy
  output from Bayer input; not for lossless CFA → CFA. Candidates: Apple's
  (via A1, free), LibRaw's (A2), or a Metal kernel of our own (bilinear/AHD;
  the Kit already has Metal infrastructure in `Kit/Sources/LetsLapseKit/Metal/`).
- Resize: `CIRAWFilter.scaleFactor` (A1), `CILanczosScaleTransform`, Metal
  MPS, vImage. Target sizes: keep, 18, 12, 8 megapixels (Set 1 is 14.2 MP,
  Set 2 12.2 MP).
- Colour: keep camera-native where the decode is camera-native (write
  `ColorMatrix1/2`, `CalibrationIlluminant1/2`, `AsShotNeutral`); for A1 output
  either declare sRGB-primaries linear as `DNGAuthor.writeLinearDNG` does, or
  invert Apple's rendering into camera space with `CameraColorTransform` when a
  reference tag set exists (Set 2 has one in the file).
- Measure CPU (vDSP / vImage, `concurrentPerform` across cores) against GPU
  (Metal / Core Image) for each step, per frame and pipelined.

### C. Payload encoding (the compression itself)

| | Strategy | Precision | Notes |
|---|---|---|---|
| C1 | Lossless JPEG (compression 7) | 16-bit, lossless | Kit encoder exists for 1 component (Bayer). Extend to 3 components for LinearRaw. CPU; tiles encode in parallel. Expect ~Adobe lossless sizes. |
| C2 | JPEG XL via **libjxl** (open source, BSD-3; deps highway, brotli) | 16-bit, lossy (distance) or lossless | The format Adobe writes. Sweep distance 0.5 / 1.0 / 2.0 and effort 3 / 5 / 7; measure threads. Build as xcframework. |
| C3 | JPEG XL via **VideoToolbox `'jxlc'`** | as C2 | Probe `VTCopyVideoEncoderList` on the Mac and on each real device; if an encoder is registered, try a `VTCompressionSession` on one 16-bit frame and check the output is a bare codestream (`FF 0A`) ImageIO decodes. Report `IsHardwareAccelerated`. Absent everywhere measured so far except possibly real devices. |
| C4 | 8-bit lossy JPEG tiles (compression 34892, DNG 1.4) via hardware JPEG (`JPEG (HW)` in VideoToolbox, or ImageIO) with a `LinearizationTable` | 8-bit gamma-encoded | Fastest possible lossy path; JPEG-grade shadow precision. Must verify Apple's decoder renders our variant (Adobe's legacy variant does not decode right in Apple, but that one carries `MapPolynomial`); if not, LetsLapse could read it through the repack. Report whether the precision is acceptable for white-balance pushes of ±2000 K on the night frames. |
| C5 | Lossy on the **Bayer mosaic** (single 16-bit plane, no demosaic) vs on demosaiced LinearRaw (3 planes) | 16-bit | One third the samples; check the ISO 12234-4 / DNG 1.7 text on whether JPEG XL is permitted on CFA data, then measure size and quality both ways. |
| C6 | Deflate (compression 8) | — | **Ruled out**: ImageIO refuses Deflate on integer LinearRaw (`DeflateProbeTests`), and the Kit's `deflateWithPredictor` quantises to 12 bits. Do not spend time here. |

### D. Container writing

Extend `Kit/Sources/LetsLapseKit/DNGAuthor.swift` (or add beside it) a DNG 1.7
writer for tiled JPEG XL / lossy JPEG payloads: tile geometry, `JXLDistance`
/ `JXLEffort` / `JXLDecodeSpeed`, `DefaultCropOrigin/Size`, uniform
`BlackLevel`, `WhiteLevel`, the colour tag set, `BaselineExposure`,
`NoiseProfile`, Exif with **sub-second `DateTimeOriginal`** (the Kit's
`exifTags` drops it; interval pacing depends on it — see
`ImportedStills.captureDate`). `LossyLinearDNG.Plan` shows every tag Adobe's
files carry and `reference(for:)` the surgery that makes Apple happy.

### E. Pipelining and real time

Per-frame stage timings first, then the whole pipeline: frames in flight
across performance cores, GPU decode overlapping CPU encode, bounded memory
(assume an iPhone budget of ~150 MB per frame in flight), thermal behaviour
over a 100-frame run. State the per-frame budget a real-time claim would need
(Set 1 was shot at one frame every ~3.6 s; a Mac batch of 486 frames should
take minutes, not an hour).

## 5. What to report

A markdown report under `docs/dng-archive-spike/` (create it), plus the CSV
the tables were made from and the commands that regenerate them. Required
sections:

1. **Capability table** — for this Mac and for every real device the probe
   ran on (§6.1): OS version, chip, `CGImageDestination` types,
   `VTCopyVideoEncoderList` (codec, name, hardware flag), `jxlc` present or
   not, hardware JPEG present or not, Metal family.
2. **Strategy matrix** — one row per decode × encode × resize combination
   attempted, on the three Set 1 spot frames and three Set 2 frames:
   per-stage time, total time per frame, frames/s single and parallel, peak
   memory, output bytes, and quality (below).
3. **Quality** — for each output: (a) the `LossyLinearDNGTests` comparison
   against the Apple decode of the *input* (whole-frame and block means in
   linear P3); (b) PSNR and SSIM in linear light against the lossless output
   of the same strategy, so lossy cost is measured against the right baseline;
   (c) a white-balance-push test: decode the lossy and lossless outputs at
   ±2000 K / ±40 tint through `LinearFrameDecoder` and compare — this is what
   "reasonable quality for edits" means here.
4. **Compatibility** — every output type opened in: Apple's decoder direct
   (`CIRAWFilter(imageURL:)`, no repack), LetsLapse (`LinearFrameDecoder`),
   Preview.app, and re-read by Adobe DNG Converter (`-c` round trip succeeds
   and its own decode of our file matches its decode of the input). Report
   Lightroom if available.
5. **Licensing** — for every third-party library considered: licence, App
   Store compatibility, binary size added, build recipe.
6. **Recommendation** — at most three candidate directions with the numbers
   that separate them, and the questions still open for each.

## 6. Deliverable shape

- A SwiftPM package at `LetsLapse/tools/dng-spike/` with an executable
  `dngspike` that depends on `LetsLapseKit` by path (`../../Kit`) so the
  authors, parsers and `LossyLinearDNG` are reused rather than copied.
  Third-party libraries as `binaryTarget` xcframeworks with a build script.
  Everything that does not need a third-party library must build and run
  without one, so the iOS-ready core stays visible.
- Subcommands: `probe` (§5.1 capability table, machine-readable + human),
  `convert <in> <out> --strategy … --lossy --distance … --megapixels …`,
  `bench` (runs the matrix on the spot frames, writes CSV), `verify <in> <out>`
  (§5.3 quality + §5.4 compatibility for one pair).
- Unit tests in the package for the pure parts (lossless-JPEG decoder round
  trip against the Kit encoder; tag writer against `LossyLinearDNG.inspect`;
  fold-free rendering in Apple's decoder). Real-file tests skip without the
  volume, as `LossyLinearDNGTests` does.

### 6.1 Real-device probe

The `probe` subcommand's logic must also run on the physical devices, because
the simulators are software-only and the Mac lacks `jxlc`. Devices on the
bench: iPhone 16 Pro (`iPhone17,1`), iPhone 12 Pro, iPad Air 13-inch (M3),
iPad Air (5th gen). Rules from `CLAUDE.md` apply: check a device is idle
before installing anything on it (a terminating install once killed a 15 GB
import at 96%), and use an isolated DerivedData for signed Debug builds.
A minimal probe app or a test bundle that prints the table is enough.

## 7. Reusable pieces already in the tree

| What | Where |
|---|---|
| DNG writers (uncompressed LinearRaw, Bayer lossless-JPEG tiled, generic in-memory `makeDNGData`) | `Kit/Sources/LetsLapseKit/DNGAuthor.swift` |
| Lossless JPEG **encoder** (1 component) | `Kit/Sources/LetsLapseKit/LosslessJPEG.swift` |
| Adobe lossy DNG parser + repack (tile table, per-plane black/white, `MapPolynomial`, JXL tile decode via ImageIO — read the **data provider**, never a CGContext draw, which colour-manages the tile) | `Kit/Sources/LetsLapseKit/Grading/LossyLinearDNG.swift` |
| Apple-rendered linear → camera-native inversion (needs a reference tag set) | `Kit/Sources/LetsLapseKit/CameraColorTransform.swift` |
| Raw decode to linear P3 texture / CIImage | `Kit/Sources/LetsLapseKit/Grading/LinearFrameDecoder.swift`, `App/CIRAWDecoder.swift` |
| 16-bit readback → RGB16 → DNG, and per-stage timing harness | `App/LiveBlendRawController.swift:1288–1385`, `App/CaptureBenchmark.swift:538–600` |
| EXIF probe (DateTimeOriginal + SubSec, exposure), raw extension list | `Kit/Sources/LetsLapseKit/ImportedStills.swift` |
| Quality comparison method and the four reference projects | `Kit/Tests/LetsLapseKitTests/LossyLinearDNGTests.swift` |
| Python + Swift probe scripts from the investigation (tag dump, MapPolynomial scan, tag patcher, CIRAWFilter/ImageIO render stats, JXL tile extraction, data-vs-URL parity) | `tools/dng-probe/` (see its README) |
| Python venv with numpy + OpenCV for analysis | `tools/.venv` |

## 8. Traps recorded so far (each cost hours; read before starting)

- Reading `isLensCorrectionEnabled`, `baselineExposure` or `exposure` on a
  `CIRAWFilter` **before** `outputImage` makes `outputImage` return nil.
- `CGImageSourceCreateThumbnailAtIndex` on iOS returns a raw file's embedded
  preview, not a decode. Never use ImageIO's index-0 path for raw input.
- ImageIO tags a decoded JPEG XL tile Rec. 2020; drawing it into a
  `CGContext` colour-manages the samples. Read `dataProvider.data` directly.
- Apple wraps negative `MapPolynomial` output to bright, and mishandles
  non-zero `BlackLevel` in the presence of opcodes (§2). Our files must avoid
  both.
- DNG `BlackLevel` is often RATIONAL (`100864/256` = 394): divide.
- Opcode lists are big-endian regardless of the file's byte order; edge tiles
  are stored padded to the full tile size.
- `CIContext.render(..., commandBuffer: nil, ...)` returns before the GPU
  finishes; a texture read straight after can be zeros. Render on your own
  command buffer and wait (`LinearFrameDecoder.render` now does).
- A per-sample Swift loop over 30 M samples took 20 s in a Debug build; the
  same arithmetic through vDSP takes ~60 ms. Write the hot loops with
  Accelerate or Metal from the start, and report Release timings.
- The Kit's `LosslessJPEG.encode` is single-component; `writeLinearDNG`'s
  `compress: true` path is Deflate and lossy (12-bit) — do not use it.
- `swift test` in `Kit/` takes ~80 s for the full suite; the real-file tests
  need the volume mounted.

## 9. Working agreements

- Branch `ios-app`; `main` is the Raspberry Pi project and untouchable.
- Outputs go to `~/Library/Developer/LetsLapseRun/out/dng-spike/` or the
  session scratchpad, never into `/Volumes/letslapse/Projects/*`.
- No UI work, so the design-sync contract in `docs/design/README.md` does not
  apply to this spike; say so in commits touching the Kit.
- Add a row to `docs/TODO.md` when the spike is done, stating the chosen
  direction and what folding it into the app would take.
- Commit the report and the CSVs with the code; the numbers are the
  deliverable.
