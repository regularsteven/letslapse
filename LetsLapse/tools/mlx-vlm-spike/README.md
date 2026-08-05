# mlx-vlm-spike — Phase 0 verification harness

Throwaway CLI proving MLX Swift VLM inference for LetsLapse's on-device AI plan.
**Findings & numbers: `LetsLapse/docs/ai/phase0-findings.md`** (the deliverable; this tool is
the evidence generator). Not part of the app target.

## Build — xcodebuild, NOT `swift build`

`swift build` produces a binary with **no Metal kernels** (SPM never compiles the `.metal`
sources; MLX dies at runtime with "Failed to load the default metallib"). Always:

```
xcodebuild -scheme mlx-vlm-spike -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
```

Binary: `.build/xcode/Build/Products/Release/vlm-spike` (keep its sibling
`mlx-swift_Cmlx.bundle` next to it).

First run `vendor/README.md`'s clone+patch recipe — the build depends on a vendored, patched
mlx-swift-lm (not committed).

## Run

```
.build/xcode/Build/Products/Release/vlm-spike \
  --model mlx-community/gemma-4-e2b-it-4bit \
  --image TestImages/IMG_0003.JPG [--image …] [--multi] \
  --place "Skógar" --light "golden hour" \
  --prompt-file Prompts/scene-prompt.txt \
  --report reports/run.json \
  [--local-dir path/to/snapshot]   # bypass hub download (patched/pushed snapshots)
```

Models download to `~/.cache/huggingface/hub/` on first use. `TestImages/` is staged locally
(Apple simulator sample photos + Sonoma wallpaper — not committed). `patched-2bit/` is the
TurboQuant snapshot with corrected quantization config + borrowed chat template (see findings).

## iOS twin

`../mlx-vlm-spike-ios/` — xcodegen app reusing `Sources/vlm-spike/SpikeCore.swift`. It
auto-runs the scenario suite at launch when a snapshot exists at
`Documents/models/<repo-slug>/` (push one with `devicectl device copy to`), and writes
`Documents/spike-<repo-slug>.json`.
