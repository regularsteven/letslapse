#!/bin/zsh
# refresh.sh — regenerate, or verify, the vendored mlx-swift-lm tree beside this script.
#
#   tools/mlx-vlm-spike/vendor/refresh.sh             re-clone ml-explore/mlx-swift-lm at the tag, apply the patches, replace mlx-swift-lm/
#   tools/mlx-vlm-spike/vendor/refresh.sh --check     verify the committed tree carries both patches (exit 1 when it does not)
#   TAG=3.32.0 tools/mlx-vlm-spike/vendor/refresh.sh  try a newer upstream tag (build the app, then commit the tree)
#
# The tree is COMMITTED (since 2026-09-18) so a plain checkout builds with no
# extra step: LetsLapse.xcodeproj links MLXVLM and MLXLMCommon from it as a
# local package. This script is how the tree was produced and the only way it
# moves — nobody edits mlx-swift-lm/ by hand. README.md here has the why.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TREE="$HERE/mlx-swift-lm"
UPSTREAM="https://github.com/ml-explore/mlx-swift-lm"
TAG="${TAG:-3.31.4}"
GEMMA="Libraries/MLXVLM/Models/Gemma4.swift"
# One line each patch adds to Gemma4.swift; present ⇔ that patch is applied.
MARK_384='if !kvSharedOnly && !isKVSharedLayer {'
MARK_MULTI='imageFeatures = imageFeatures.reshaped(-1, imageFeatures.dim(-1))'
# Upstream's own repo housekeeping, not part of the package.
DROP=(.git .github .gitignore .pre-commit-config.yaml .spi.yml .swift-format)

check() {
  local bad=0
  if [ ! -f "$TREE/Package.swift" ]; then
    echo "refresh: $TREE is missing — run refresh.sh (no arguments) to recreate it" >&2
    return 1
  fi
  if ! grep -qF -- "$MARK_384" "$TREE/$GEMMA"; then
    echo "refresh: pr384.diff is not applied to $GEMMA" >&2; bad=1
  fi
  if ! grep -qF -- "$MARK_MULTI" "$TREE/$GEMMA"; then
    echo "refresh: multi-image-fix.diff is not applied to $GEMMA" >&2; bad=1
  fi
  if [ -f "$TREE/UPSTREAM" ]; then
    echo "refresh: $(head -1 "$TREE/UPSTREAM")"
  fi
  if [ $bad -eq 0 ]; then
    echo "refresh: vendored tree carries both patches ✓"
  fi
  return $bad
}

case "${1:-}" in
  --check) check; exit $? ;;
  "") ;;
  -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
  *) echo "refresh: unknown option $1" >&2; exit 2 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "refresh: cloning $UPSTREAM at $TAG"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" "$UPSTREAM" "$WORK/mlx-swift-lm"
REV="$(git -C "$WORK/mlx-swift-lm" rev-parse HEAD)"

# Order matters: multi-image-fix.diff is cut against the #384-patched file.
echo "refresh: applying pr384.diff (Gemma4.swift hunks only), then multi-image-fix.diff"
(cd "$WORK/mlx-swift-lm" \
  && git apply --include="$GEMMA" "$HERE/pr384.diff" \
  && git apply "$HERE/multi-image-fix.diff")

for f in "${DROP[@]}"; do rm -rf "$WORK/mlx-swift-lm/$f"; done
{
  printf 'ml-explore/mlx-swift-lm tag %s (%s)\n' "$TAG" "$REV"
  printf '+ pr384.diff (%s hunks only)\n+ multi-image-fix.diff\n' "$GEMMA"
  printf 'Upstream-only files dropped: %s\n' "${DROP[*]}"
  printf 'Regenerate with vendor/refresh.sh; never edit this tree by hand.\n'
} > "$WORK/mlx-swift-lm/UPSTREAM"

rm -rf "$TREE"
mv "$WORK/mlx-swift-lm" "$TREE"
TREE="$TREE" check
echo "refresh: replaced $TREE — build the app, then commit the tree with the tag in the message"
