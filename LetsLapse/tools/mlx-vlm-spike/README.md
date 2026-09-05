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

## craft-probe — text-only generation for Crafted Text

A second executable in this package, added 2026-09-04. `lapse craft` owns the
prompt, the parser and the layout and links no MLX (so CI runs anywhere);
this owns the weights. Together they drive the Crafted Text path end to end:

```
xcodebuild -scheme craft-probe -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build

lapse craft --prompt split --brief "Visit Prague this summer" \
  | .build/xcode/Build/Products/Release/craft-probe --stats --temperature 0 \
  | lapse craft --response - --json
```

Defaults to the Hugging Face cache snapshot for
`mlx-community/gemma-4-e2b-it-4bit` — the same directory `SceneAnalyser`
loads. `--framing auto` (the default) is what the app does: `ChatSession`
hands a `Chat.Message` to the processor, which applies the model's own
`chat_template.jinja`. `--framing manual` additionally wraps the prompt in
Gemma's `<start_of_turn>` framing, i.e. templates the turn TWICE — it exists
so that can be measured rather than assumed. Do not ship it.

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
