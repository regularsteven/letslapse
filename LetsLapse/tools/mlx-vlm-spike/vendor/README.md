# Vendored mlx-swift-lm (spike only)

`mlx-swift-lm/` is a local copy of https://github.com/ml-explore/mlx-swift-lm at tag **3.31.4**
with two patches applied to `Libraries/MLXVLM/Models/Gemma4.swift`:

1. **PR #384** — Gemma 4 E-series `num_kv_shared_layers` loader fix (merged upstream 2026-07-15,
   unreleased as of 2026-08-04). `pr384.diff` is the verbatim upstream PR diff.
2. **`multi-image-fix.diff`** (ours) — multi-image vision-token accounting. `Gemma4`'s
   `getInputEmbeddings` compared the prompt's image-placeholder count against
   `imageFeatures.dim(1)`, i.e. the soft-token count of a *single* image (280 for gemma-4-e2b),
   while the processor stacks all N images on the batch axis. Every N>1 prompt therefore died with
   `imageTokenCountMismatch(expectedVisionTokens: 280, actualPromptTokens: 280 × N)`. The fix
   reshapes the features to `(N × 280, hiddenSize)` before the comparison, matching what
   `Gemma4Unified.scatterFeatures` already does. Not reported upstream — check whether a later
   release fixes it before carrying this forward.

Why: release 3.31.4 cannot load current `gemma-4-e2b/e4b` checkpoints (KV-shared tail layers ship
no k/v weights), and every upstream revision containing the fix requires mlx-swift 0.31.5+, which
needs a Swift 6.3 toolchain — newer than Xcode 26.1.1. Drop this vendor dir and return to a normal
`.package(url:…)` pin at the first tagged release that includes #384, or once Xcode ships Swift 6.3.

The clone is not committed (see `.gitignore`). Recreate with:

```
git clone --depth 1 --branch 3.31.4 https://github.com/ml-explore/mlx-swift-lm vendor/mlx-swift-lm
cd vendor/mlx-swift-lm
git apply --include='Libraries/MLXVLM/Models/Gemma4.swift' ../pr384.diff
git apply ../multi-image-fix.diff
```

Apply them in that order — `multi-image-fix.diff` is cut against the #384-patched file.
`pr384.diff` (committed) is the verbatim `https://github.com/ml-explore/mlx-swift-lm/pull/384.diff`.
