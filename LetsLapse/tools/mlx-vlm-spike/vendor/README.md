# Vendored mlx-swift-lm

`mlx-swift-lm/` is https://github.com/ml-explore/mlx-swift-lm at tag **3.31.4**, committed
verbatim — minus upstream's own repo housekeeping (`.git`, `.github`, `.gitignore`,
`.pre-commit-config.yaml`, `.spi.yml`, `.swift-format`); `mlx-swift-lm/UPSTREAM` names the exact
commit — with two patches applied to `Libraries/MLXVLM/Models/Gemma4.swift`:

1. **PR #384** — Gemma 4 E-series `num_kv_shared_layers` loader fix (merged upstream 2026-07-15,
   unreleased as of 2026-08-04). `pr384.diff` is the verbatim upstream PR diff; only its
   `Gemma4.swift` hunks are applied.
2. **`multi-image-fix.diff`** (ours) — multi-image vision-token accounting. `Gemma4`'s
   `getInputEmbeddings` compared the prompt's image-placeholder count against
   `imageFeatures.dim(1)`, i.e. the soft-token count of a *single* image (280 for gemma-4-e2b),
   while the processor stacks all N images on the batch axis. Every N>1 prompt therefore died with
   `imageTokenCountMismatch(expectedVisionTokens: 280, actualPromptTokens: 280 × N)`. The fix
   reshapes the features to `(N × 280, hiddenSize)` before the comparison, matching what
   `Gemma4Unified.scatterFeatures` already does. Not reported upstream — check whether a later
   release fixes it before carrying this forward.

**Why a vendored copy at all:** release 3.31.4 cannot load current `gemma-4-e2b/e4b` checkpoints
(KV-shared tail layers ship no k/v weights), and every upstream revision containing the fix requires
mlx-swift 0.31.5+, which needs a Swift 6.3 toolchain — newer than Xcode 26.1.1, the toolchain this
was last built with.

**Why it is committed (since 2026-09-18):** the app project — `LetsLapse.xcodeproj`, not just this
spike — links `MLXVLM` and `MLXLMCommon` from this directory as a local package. While the tree was
gitignored, a fresh checkout could not resolve packages at all: Xcode reported every product
missing, `LetsLapseKit` included, and the only cure was a Terminal recipe nobody cloning with
GitHub Desktop would find. Four megabytes of MIT-licensed Swift source (no binaries) is the cheaper
price; the tree ships with its `LICENSE`.

Nobody edits `mlx-swift-lm/` by hand. `refresh.sh` is the only way it changes:

```
tools/mlx-vlm-spike/vendor/refresh.sh             re-clone 3.31.4, apply the patches, replace the tree
tools/mlx-vlm-spike/vendor/refresh.sh --check     verify the committed tree carries both patches
TAG=3.32.0 tools/mlx-vlm-spike/vendor/refresh.sh  try a newer upstream tag (build the app, then commit)
```

The patch order matters — `multi-image-fix.diff` is cut against the #384-patched file — and the
script keeps it. A refresh is reproducible: two runs at the same tag give byte-identical trees.

**Exit:** drop this directory and return to a normal `.package(url:…)` pin (in the app project and
in `../Package.swift`) at the first tagged mlx-swift-lm release that includes #384 — which needs
mlx-swift 0.31.5+, i.e. a Swift 6.3 toolchain on every Mac that builds the app — carrying
`multi-image-fix.diff` forward, or upstreaming it, if that release still has the bug. A fork holding
the same two patches, pinned by revision, is the quicker exit and needs no toolchain change. Both
are scoped in `docs/TODO.md` ("Un-vendor mlx-swift-lm").
