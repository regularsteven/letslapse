# Phase 0 findings — MLX Swift VLM verification spike

Status: **in progress** (macOS leg running)
Date: 2026-08-04 · Hardware: MacBook Pro M4 Max (macOS 15.6.1), iPhone 16 Pro (device leg)
Harness: `LetsLapse/tools/mlx-vlm-spike/` (throwaway SwiftPM CLI, not part of the app target)

## Versions pinned

| Package | Version | Note |
|---|---|---|
| `ml-explore/mlx-swift` | **0.31.4** (exact) | 0.31.5+ requires a Swift 6.3 toolchain; Xcode 26.1.1 ships Swift 6.2, so 0.31.4 is the ceiling until Xcode updates. Latest upstream is 0.31.6 (2026-07-02). |
| `ml-explore/mlx-swift-lm` | **revision `18edd228`** (2026-07-23) | Release 3.31.4 **cannot load current gemma-4 E-series checkpoints** — see "Loader bug" below. The pin carries the #384 KV-sharing fix and the #405 multi-image fix, and predates the 2026-08-03 `ChatConventionsProviding` refactor at HEAD. Move to the next tagged release once one ships with #384. |
| `huggingface/swift-huggingface` | 0.9.0 (resolved) | Provides `HubClient`. Downloads to `~/.cache/huggingface/hub/` (Python-compatible layout). |
| `huggingface/swift-transformers` | 1.3.3 (resolved) | Provides `Tokenizers` (AutoTokenizer). |

## Loader bug found (and why the catalog needs engine-aware pins)

Release 3.31.4 fails to load `mlx-community/gemma-4-e2b-it-4bit` with
`keyNotFound … layers.15.self_attn.k_norm.weight`. Root cause: Gemma 4 **E-series models share KV
across the top `num_kv_shared_layers` layers** (E2B: 20 of 35 — layers 15–34 have *no* k/v
projections in the checkpoint, plus 3n-style per-layer embeddings). The Swift module machinery for
this exists (`kvSharedOnly:` on `Gemma4TextAttention`, shared-KV forward state, cache mapping), but
in 3.31.4 `Gemma4TextBackbone` constructs every layer without passing `kvSharedOnly`, so the loader
demands weights the (correctly) stripped checkpoint doesn't have. Fixed upstream in PR #384
(2026-07-15), unreleased as of 2026-08-04.

Consequences for Phase 1:

- **The engine version is part of the compatibility contract.** A catalog entry is only valid for
  the mlx-swift-lm version the app ships; a Hub repo re-converted with a newer mlx-vlm can break an
  older engine (that is precisely what happened here — the model card says "converted with
  mlx-vlm 0.4.3", which postdates the 3.31.4 registry). The catalog schema should carry a
  `minEngineRevision`-style note per entry, and download failures at load-time (not just
  fetch-time) must surface as row-level errors with the model marked incompatible.
- **`revision: "main"` in the catalog sketch is the wrong default.** Pin immutable commit SHAs per
  model at catalog-publish time so a silent Hub re-conversion can't break users mid-flight; ship
  revision bumps through catalog updates after testing them against the shipped engine.

Toolchain: Xcode 26.1.1 (Swift 6.2), Metal toolchain 17.2.54 installed.

## Corrections to the brief (§0 dependency list)

1. **`MLXVLM`/`MLXLMCommon` no longer live in `ml-explore/mlx-swift-examples`.** That repo is now the "mlx-libraries" package (MNIST + StableDiffusion only). The LM/VLM libraries moved to **`ml-explore/mlx-swift-lm`** (products: `MLXLLM`, `MLXVLM`, `MLXLMCommon`, `MLXEmbedders`, `MLXHuggingFace`, `MLXFoundationModels`, `MLXGuidedGeneration`). Phase 1+ must depend on `mlx-swift-lm`.
2. **`swift-transformers` is no longer a transitive dependency.** mlx-swift-lm 3.x uses a "bring your own hub" design: the consumer supplies a `Downloader` and a `TokenizerLoader`. The `MLXHuggingFace` product provides macros (`#hubDownloader()`, `#huggingFaceTokenizerLoader()`) that bridge `HubClient` (from `swift-huggingface`) and `AutoTokenizer` (from `swift-transformers`). The spike hand-inlines equivalent bridges (see `Sources/vlm-spike/main.swift`) to log snapshot paths and skip the macro/swift-syntax build; the app can use the macros or the same hand-written bridges.
3. **Brief §1.2's "use `HubApi` from swift-transformers"** → becomes "use `HubClient` from swift-huggingface" (or a custom `Downloader` conformance, which is a small, clean protocol: `download(id:revision:matching:useLatest:progressHandler:) -> URL`). `HubClient` downloads into the Python-compatible cache layout `~/.cache/huggingface/hub/models--{org}--{name}/` — on iOS the app should pass an explicit location under Application Support per §1.2 (constructor accepts a custom base; verify exact init in Phase 1).
4. **Platform floors of mlx-swift-lm 3.31.4 are macOS 14 / iOS 17** (tvOS 17, visionOS 1). The app targets iOS 16/macOS 13, so the AI feature must be capability-gated at *link/compile* level, not just runtime — i.e. the MLX-facing code needs `@available(iOS 17, macOS 14, *)` boundaries, and minimum-deploy conflicts need checking when the package is added to the app target (SPM refuses to link a package whose floor exceeds the target's). Options: raise app min-OS (iOS 17 adoption is near-universal in 2026), or isolate MLX behind a separate SPM package target with higher floors. Decide in Phase 1.
5. **A `MLXGuidedGeneration` product exists** (grammar-constrained generation). Directly relevant to §3.3/§5.3: the JSON contract could be enforced at the sampler level instead of parse-and-retry. Not used in the spike; flagged as a Phase 3 option.

## Registry verdict (the gate question)

**`gemma4` is a first-class architecture in MLXVLM 3.31.4.** From `VLMModelFactory.swift`:

- Type registry: `"gemma4"` → `Gemma4Configuration`/`Gemma4.init`, plus `"gemma4_unified"` (audio-unified variant).
- Processor registry: `"Gemma4Processor"`, `"Gemma4UnifiedProcessor"`.
- Predefined configuration `gemma4_E2B_it_4bit` pointing at **exactly our primary model** `mlx-community/gemma-4-e2b-it-4bit` (plus E4B, 31B, 26B-A4B siblings).

Both candidate repos resolve publicly (no gating):

| Repo | model_type | Quant (config) | Actual size (Hub tree) |
|---|---|---|---|
| `mlx-community/gemma-4-e2b-it-4bit` | `gemma4` (text `gemma4_text`, vision `gemma4_vision`, audio `gemma4_audio`) | 4-bit, group 64 | **3.58 GB** (3,583,082,661 B) |
| `majentik/gemma-4-E2B-TurboQuant-MLX-2bit` | `gemma4` (same towers) | config block says **bits 4**, group 64, mode affine — "2-bit" branding is per-layer mixed quant at best | **2.45 GB** (2,454,283,252 B) — *not* the ~0.7 GB the brief's catalog sketch assumed |

Catalog corrections: `approxDownloadMB` for the TurboQuant entry must be ~2455, not 700. The TurboQuant repo also ships **no `chat_template.jinja`** (the mlx-community repo has one); template must come from `tokenizer_config.json` — watched in the run below.

## Test images

No urban-dusk or interior photo exists locally (coverage gap — close on the device leg with real captures). Set used (Apple simulator sample photos + macOS wallpaper, staged in `TestImages/`, not committed):

| Image | Content | Scenario |
|---|---|---|
| IMG_0003.JPG | Large waterfall, golden hour, mist | water/landscape + light slot "golden hour", place "Skógar" |
| IMG_0005.JPG | Waterfall under heavy overcast | water + light slot "dusk", place "Skógar" |
| IMG_0002.JPG | Citrus foliage close-up | nature + **empty place** (fallback-ladder test), light "day" |
| IMG_0003+0004+0005 | 3 water scenes as pseudo first/middle/last | multi-image probe, light "day to dusk" (transition phrasing) |

## macOS results (M4 Max, macOS 15.6.1)

### `mlx-community/gemma-4-e2b-it-4bit` — PASS

Loads and runs through `VLMModelFactory` with the #384 fix applied. Numbers per scenario
(fresh process each; raw JSON in `tools/mlx-vlm-spike/reports/`):

| Scenario | Title produced | Tags | JSON valid | TTFT | Gen tok/s | Wall | Peak mem |
|---|---|---|---|---|---|---|---|
| Waterfall, golden hour, place "Skógar" | "Golden hour in Skógar with waterfall" | nature, water | ✓ | 3.45 s¹ | 133 | 3.8 s¹ | 4048 MB |
| Waterfall, dusk | "Dusk in Skógar with waterfall" | nature, landmark | ✓ | 0.48 s | 145 | 0.84 s | 4048 MB |
| Foliage close-up, **no place** | "day in outdoor with leaves" | nature | ✓ | 0.59 s | 144 | 0.89 s | 4012 MB |
| 3-frame transition "day to dusk" (per-frame) | "Day to dusk in Skógar with waterfall" / "…with mossy rocks"² / "…with waterfall" | union: nature, water, landmark | 2 of 3² | ~0.43 s | ~139 | ~0.8 s | 4050 MB |
| 3-frame **single multi-image call** | — | — | — | **fails**³ | — | — | — |

¹ First-ever inference pays ~3 s of Metal shader warm-up (per machine, cached by the OS
afterwards); subsequent cold process launches see TTFT ~0.5 s. Model load from disk: 1.7–2.3 s;
~2.8 GB active after load. Prompt phase ~1,100 tok/s warm (445-token prompt ≈ 0.4 s, of which
280 tokens are the image).
² "Day to dusk in Skógar with mossy rocks" is 8 words → the ≤7-word validator flagged it;
the parser/retry layer (§3.3) is the right home for this, exactly as designed.
³ `imageTokenCountMismatch(expectedVisionTokens: 280, actualPromptTokens: 840)` — 3.31.4's
`Gemma4.getInputEmbeddings` counts one image's soft tokens (`dim(1)`) while the processor stacks
N images on the batch axis. **Fixed in the vendored engine** by `vendor/multi-image-fix.diff`
(reshape to `(-1, hiddenSize)` before counting, mirroring `Gemma4Unified.scatterFeatures`;
upstream #405 fixes the newer line only, which Xcode 26.1.1 can't build). With the patch, the
3-frame single-call probe **passes**: coherent merged result ("Day to dusk in Skógar with
waterfall", union-quality tags/elements), clean-run wall **4.0 s**, TTFT 3.1 s, prompt 1163 tok
(3 × 280 vision + text), **peak 5.2 GB** vs 4.2 GB single-frame — ~0.5 GB per additional
1024-px frame. Catalog: `maxImagesPerPrompt` ≥ 3 on the patched engine (Mac); on 8 GB iPhones
the per-frame fallback stays the default until the device leg proves multi-frame headroom
(5-frame Video sampling projects to ~6+ GB — likely over the iOS per-app ceiling even with the
Increased Memory Limit entitlement).

⁴ Prompt v3 (array-shape examples) restored proper tag arrays but the model now invents a
`light` tag (out-of-taxonomy, deterministic at temperature 0, 3 of 4 calls) — presumably primed
by the prompt's light-context vocabulary. The §3.1 parser rule (drop unknown tags, keep going)
handles it; the harness records it as a violation for visibility. Net: title-cap ✓, arrays ✓,
one benign invented tag dropped by the parser.

Quality notes: place and light slots used verbatim in every titled case, including the
timelapse-native "Day to dusk" transition phrasing. Tags stayed inside the closed taxonomy in
all runs (`landmark` for the big waterfall is defensible; `water` was dropped once — tag-union
across frames compensates). The no-place fallback produced grammatically clunky "day in outdoor
with leaves" — confirms §3.2's decision that the *app-side grammar*, not the model, owns
placeless titles.

### `majentik/gemma-4-E2B-TurboQuant-MLX-2bit` — config.json is wrong; loadable only when patched

Out-of-the-box load fails:
`mismatchedSize(embed_vision.embedding_projection, expected [1536, 96], actual [1536, 48])`.
Diagnosis from the safetensors header (all shapes): **every one of the 319 affine-quantized
tensors is packed at 2 bits**, but the repo's `config.json` declares global `bits: 4` and no
per-layer overrides. Python tooling that re-derives per-tensor bits shrugs this off; the Swift
engine (correctly) builds modules from config and fails. The engine *does* support per-layer
quantization dicts in config — there just aren't any.

Spike workaround: a patched local snapshot (`patched-2bit/`, weights symlinked, config's
`quantization.bits` corrected to 2) loaded via the harness's `--local-dir`. A second repo defect
surfaced immediately: **no chat template anywhere** (no `chat_template.jinja`, none in
`tokenizer_config.json`) → `missingChatTemplate` on every generate. Borrowing the sibling
mlx-community repo's Gemma 4 template fixed that too.

**Result with both defects patched: unusable.** The model loads (1.5 s, 1.72 GB active — the
memory savings are real: 3.25 GB peak vs 4.2 GB for 4-bit) and decodes fast (~160 tok/s), but
every scenario produces multilingual token salad to the 256-token cap ("education framework
equiv 秋冬 ▬▬ …"), zero JSON, zero English sentences. Either uniform 2-bit affine quantization
simply destroys this model, or "TurboQuant" packs weights in a custom scheme that Python-side
code dequantizes specially and the standard engine cannot express. Raw outputs preserved in
`reports/g4-2bit-*.json`.

**Gate verdict for this repo: NO-GO** — three independent defects (config declares 4-bit over
2-bit weights; no chat template; catastrophic output quality even when loadable). File in the
catalog notes as "pending upstream repo fix", do not ship. It remains useful as the Test-harness
stress case (§1.4): the row-level failure UX ("Test failed") and the §3.3 parse-retry-reject
ladder both get exercised honestly by it.

## Prompt v2 (7-word cap enforcement) — and what it traded away

The prompt was tightened mid-spike (word-counted examples; "the 7-word cap outranks the
pattern") after the 8-word title above. Under v2 (`Prompts/scene-prompt.txt`), all 4-bit
scenarios re-ran:

- **The cap now holds.** The offending frame yields "Day to dusk in Skógar" (5 words) — the
  model applied the drop-the-element strategy verbatim. 6 of 6 calls valid JSON, all titles
  ≤ 7 words.
- **New regression:** every v2 run emits `"subjectTags": "nature"` — a bare **string instead of
  an array** (v1 always produced arrays), and tag richness dropped (water/landmark no longer
  co-reported; some of that moved into `elements`). The harness parser initially coerced this to
  an empty list and still said "valid" — fixed to coerce-and-flag. Longer instruction text
  visibly displaces schema-shape attention in a 4-bit E2B.

Phase 3 consequences: the app parser must coerce string↔array defensively (now proven, not
theoretical); prompt changes need the golden-file matrix re-run (§3.5) because single-frame wins
can regress schema shape; and sampler-level JSON enforcement (`MLXGuidedGeneration`) is worth a
Phase 3 experiment precisely to end this class of whack-a-mole.

## iPhone 16 Pro results — staged, blocked on device unlock

Everything is in place; the run itself needs the phone unlocked (a physical action):

- Harness app **installed**: `com.regularsteven.letslapse.vlmspike` (tools/mlx-vlm-spike-ios,
  xcodegen project, signed with the team's wildcard dev profile).
- 4-bit snapshot **pushed over USB** into the app's `Documents/models/gemma-4-e2b-it-4bit/`
  (3.31 GB verified — the first `devicectl copy` silently truncated `model.safetensors` at
  1.15 GB after a file-service socket drop; a retry completed it. **Lesson for §1.2: per-file
  size verification after transfer/download is mandatory — a truncated copy reported exit 0.**)
- The app **auto-runs the full scenario suite on launch** when it finds the snapshot (devicectl
  cannot tap buttons), writes `Documents/spike-gemma-4-e2b-it-4bit.json`, and keeps the screen
  awake during the run.
- Launch attempts return `FBSOpenApplicationErrorDomain error 7 — "device was not, or could not
  be, unlocked"`. A watcher retries while the session is open; manually, the recipe is:

```
xcrun devicectl device process launch --device DD61F99C-309F-506E-9A40-16ED1712ECF8 com.regularsteven.letslapse.vlmspike
# …wait ~2–3 min (screen stays on), then:
xcrun devicectl device copy from --device DD61F99C-309F-506E-9A40-16ED1712ECF8 \
  --source Documents/spike-gemma-4-e2b-it-4bit.json --destination /tmp/device-report.json \
  --domain-type appDataContainer --domain-identifier com.regularsteven.letslapse.vlmspike
```

(Or simply unlock the phone and tap **VLMSpikeiOS** — same thing.)

**Device verdict (measured, twice): the Increased Memory Limit entitlement is a hard
requirement on 8 GB iPhones.** With the phone unlocked, the console-attached run shows:

```
device model memory: 7643 MB physical
[load] 2.0s · active 2803 MB · peak 2803 MB      ← weights load fine, fast, from NAND
App terminated due to signal 9.                  ← killed at first inference
```

Identical outcome at 1024 px and at 512 px + a 32 MB MLX cache cap: **the model loads
(2.8 GB active, 1.9–2.0 s) and iOS kills the app the moment inference begins.** The default
per-app ceiling (~3.0–3.4 GB on this class) leaves no room above the weights floor — resolution
tuning cannot save it, which settles brief §9's question with data. Consequences:

- Phase 1 ships with `com.apple.developer.kernel.increased-memory-limit` from day one on iOS.
  To finish the device leg: open `VLMSpikeiOS.xcodeproj` in Xcode once while signed in (mints a
  profile with the capability), restore `CODE_SIGN_ENTITLEMENTS: VLMSpikeiOS.entitlements` in
  `project.yml`, `xcodegen generate`, rebuild, and relaunch — the USB-pushed model and auto-run
  pipeline stay in place, so the numbers flow with zero further setup.
- A18 Pro TTFT / tok-s / multi-frame headroom remain to be measured post-entitlement. The
  Mac→phone constants so far: load 2.0 s (vs 1.7 s), identical 2.8 GB weight footprint.
- `minUnifiedMemoryGB: 8` stays right for the catalog, but the row should also gate on the
  entitlement being present at runtime (`os_proc_available_memory` sanity check before load).
  **Superseded 2026-08-05:** the floor is now `6.5` and the field is a `Double`. `8` was written
  against the spec sheet, but the check reads `ProcessInfo.physicalMemory`, which on an 8 GB
  iPhone 16 Pro returns ~7.1 GB — iOS keeps the rest — so an integer floor of 8 refused the exact
  device the model was measured on. 6.5 clears the measured 4,048 MB inference peak with room to
  spare and still excludes 6 GB hardware.

## Gate outcome (macOS leg)

**GO — with the primary model, on a patched engine.**

- `mlx-community/gemma-4-e2b-it-4bit`: **ships as the catalog's `recommended` entry.**
  Loads, runs fast (sub-second warm single-frame on M4 Max; 4 s for 3-frame), holds the JSON
  contract with known, parser-manageable failure modes (7-word overruns fixed by prompt v3;
  occasional out-of-taxonomy tag dropped by the parser; string/array shape coerced defensively).
- `majentik/gemma-4-E2B-TurboQuant-MLX-2bit`: **NO-GO** (three independent defects; output is
  noise even when force-loaded). Keep in the catalog *notes* as pending-upstream, not as an
  installable entry.
- **Engine policy is now a first-class catalog concern:** ship pinned engine + pinned model
  revisions, treat load-time key/shape mismatches as row-level incompatibilities, record
  `maxImagesPerPrompt` per engine+model pair, and carry the vendored patches
  (`vendor/pr384.diff`, `vendor/multi-image-fix.diff`) until a tagged mlx-swift-lm release
  buildable on the shipping Xcode contains both fixes.
- Follow-ups filed: upstream the multi-image fix (session task chip); E4B siblings
  (`gemma-4-e4b-it-4bit`, predefined in the registry) are natural future catalog entries for
  ≥16 GB Macs.
