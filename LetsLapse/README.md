# LetsLapse — GPU Frame Blending (iOS · iPadOS · macOS)

A proof-of-concept capture-and-blend app. It shoots video or interval photos
(or imports them), then performs Metal-accelerated frame blending to produce:

1. **Synthetic long exposures** — stacking N stills into one low-noise image
   (noise falls by ~√N).
2. **Variable time-compression ("speed ramp")** — each output frame averages a
   *moving window* of input frames, and the window size can ramp across the
   clip: start at 1 (dreamy slow-mo from high-fps source) and grow to 40+
   (a motion-blurred hyperlapse rush). Blur scales naturally with speed.

The blending technique comes from the original Raspberry Pi LetsLapse
project (the rest of this repository, on `main`); this is a fresh native
implementation of the same idea with the CPU pipeline replaced by a Metal
compute kernel. The Pi project is untouched and lives on.

## Layout

```
LetsLapse/
├── Kit/                    Swift package — the reusable core
│   ├── Sources/LetsLapseKit/
│   │   ├── Metal/BlendKernels.metal   the one shared GPU kernel (sum, divide)
│   │   ├── BlendCore.swift            device/pipelines/texture cache
│   │   ├── FrameAccumulator.swift     reset → accumulate×N → finalize
│   │   ├── BlendRamp.swift            ramp curves + window scheduling
│   │   ├── VideoBlender.swift         streaming video → blended video
│   │   ├── ImageStacker.swift         stills → one stacked image
│   │   └── VideoSynthesizer.swift     synthetic test clips
│   ├── Sources/lapse/                 macOS command-line front end
│   └── Tests/                         14 tests incl. GPU value checks
├── App/                    SwiftUI universal app (iOS/iPadOS/macOS)
└── LetsLapse.xcodeproj     one multiplatform target
```

The engine is UI-free: frames in → blend curve → frames out. The GUI, the CLI,
and any future caller (e.g. an Electron pipeline shelling out to `lapse`) all
drive the same `LetsLapseKit` library.

## macOS CLI

```sh
cd LetsLapse/Kit
swift build -c release
.build/release/lapse --help

# render a synthetic test clip, then blend it
.build/release/lapse synth -o test.mov --frames 240 --fps 60 --pattern box
.build/release/lapse blend test.mov -o ramped.mp4 --ramp 1:40 --curve ease-in-out
.build/release/lapse blend test.mov -o timelapse.mp4 --window 20

# stack stills into a synthetic long exposure
.build/release/lapse stack shots/*.jpg -o stacked.png

.build/release/lapse info test.mov
```

Blending averages in **linear light** by default (physically correct long
exposure); pass `--gamma` to average gamma-encoded values instead. `--codec`
supports `h264` (default), `hevc`, `prores`, `jpeg`.

Tests: `swift test` (inside `Kit/`).

## App (Xcode)

Open `LetsLapse/LetsLapse.xcodeproj`. One `LetsLapse` target builds for
iPhone, iPad, and Mac. To run on a device, select your development team under
Signing & Capabilities — no team is checked in.

- **iOS/iPadOS**: capture video (with a high-frame-rate toggle that picks the
  camera's fastest 1080p format) or interval photos; or import from the photo
  library. Blend options → GPU progress → result with share sheet (Instagram
  appears there when installed) and Save to Photos.
- **macOS**: import a video or an image folder via the file picker; same blend
  pipeline; share the result.

## How the ramp works

`WindowSchedule.make(totalInputFrames:ramp:)` walks the input timeline:
at each step the ramp (start window → end window through a linear/ease curve,
measured over input progress) decides how many of the next input frames merge
into one output frame. Windows are consecutive and non-overlapping, so every
input frame contributes exactly once and blur grows exactly as speed does.

Each output frame is independent of the others, so the pipeline streams:
decode → accumulate on GPU (float32) → divide → encode, with a small
in-flight window keeping memory flat on arbitrarily long clips.

## Notes / current limits (PoC)

- Audio is dropped (time compression makes it meaningless).
- Variable-frame-rate sources use the container's nominal fps as the frame
  count estimate; the blender adapts if the estimate is off.
- No keyframe/non-linear editing UI — the ramp is a simple function, by design.
- HDR input is tone-mapped to 8-bit SDR by the decoder before blending.
