#!/bin/bash
# craft_ci.sh — integration tests for the Crafted Text path, headless.
#
# Drives `lapse craft` over the fixtures in craft_fixtures/: the model path
# (a canned generation parsed into layers), the no-model fallback, and the
# answers a local model actually gets wrong. Nothing here needs a device, a
# simulator, MLX or a window, so it runs anywhere the package builds.
#
#   tools/craft_ci.sh                 # builds the CLI, runs every case
#   tools/craft_ci.sh path/to/lapse   # uses a CLI you already built
#
# Exit 0 = every case passed. Any failure prints the case and exits 1.
#
# Note on measurement: every case runs `--measure estimate`, the CLI's
# default — font-free, so the fitted sizes are identical on every machine.
# `--measure coretext` is for looking at a true fit by hand, never for an
# assertion, because font metrics move between OS versions.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$HERE/../Kit"
FIXTURES="$HERE/craft_fixtures"

LAPSE="${1:-}"
if [ -z "$LAPSE" ]; then
  echo "building lapse…"
  ( cd "$KIT" && swift build -c release --product lapse ) || exit 1
  LAPSE="$KIT/.build/release/lapse"
fi
if [ ! -x "$LAPSE" ]; then
  echo "craft_ci: no lapse binary at $LAPSE" >&2
  exit 1
fi

PASS=0
FAIL=0

# ok <name> <expected-exit> -- <lapse args...>
# Runs the case and checks the exit code. Stdout is kept in $OUT for the
# field checks that follow.
ok() {
  local name="$1" want="$2"; shift 3
  OUT="$("$LAPSE" "$@" 2>/tmp/craft_ci_err)"
  local got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL  $name — exit $got, wanted $want"
    sed 's/^/      /' /tmp/craft_ci_err
    FAIL=$((FAIL + 1))
    return 1
  fi
  echo "ok    $name"
  PASS=$((PASS + 1))
  return 0
}

# field <name> <jq-ish path> <expected> — checks one value in $OUT (JSON).
field() {
  local name="$1" path="$2" want="$3"
  local got
  got=$(printf '%s' "$OUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for key in '$path'.split('.'):
    d = d[int(key)] if key.isdigit() else d[key]
print(d)
" 2>/dev/null)
  if [ "$got" != "$want" ]; then
    echo "FAIL  $name — $path was '$got', wanted '$want'"
    FAIL=$((FAIL + 1))
    return 1
  fi
  echo "ok    $name"
  PASS=$((PASS + 1))
  return 0
}

echo "== the prompt the model is given =="
ok "split prompt mentions the 5-line cap" 0 -- \
  craft --prompt split --brief "hello"
case "$OUT" in
  *"AT MOST 5 short lines"*) echo "ok    prompt caps the line count"; PASS=$((PASS + 1)) ;;
  *) echo "FAIL  prompt caps the line count"; FAIL=$((FAIL + 1)) ;;
esac
case "$OUT" in
  *"do not rewrite it"*) echo "ok    prompt forbids rewriting the brief"; PASS=$((PASS + 1)) ;;
  *) echo "FAIL  prompt forbids rewriting the brief"; FAIL=$((FAIL + 1)) ;;
esac
case "$OUT" in
  *'"""hello"""'*) echo "ok    prompt quotes the brief"; PASS=$((PASS + 1)) ;;
  *) echo "FAIL  prompt quotes the brief"; FAIL=$((FAIL + 1)) ;;
esac

echo
echo "== the model path: a generation parsed into layers =="
ok "a clean answer lays out" 0 -- \
  craft --response "$FIXTURES/good.json" --json --expect-lines 3
field "  three lines"        lineCount            3
field "  payoff is amber"    lines.2.colorHex     "#FFB340"
field "  payoff is Prague"   lines.2.copy         "Prague"
field "  payoff pops in"     lines.2.style        pop
field "  line 2 follows 1"   lines.1.followsIndex 0
field "  line 3 follows 2"   lines.2.followsIndex 1
field "  the label is the ID" lines.0.label       "Crafted · line 1"

ok "the payoff assertion passes on the right line" 0 -- \
  craft --response "$FIXTURES/good.json" --expect-payoff "Prague"
ok "the payoff assertion fails on a quiet line" 65 -- \
  craft --response "$FIXTURES/good.json" --expect-payoff "Don't you think"

ok "prose around the JSON is survivable" 0 -- \
  craft --response "$FIXTURES/prose-wrapped.json" --json --expect-lines 2
field "  the payoff came through" lines.1.copy "nothing owed"

ok "a bare-string emphasis and a stringy priority are coerced" 0 -- \
  craft --response "$FIXTURES/loose-types.json" --json --expect-lines 2
field "  priority 1 resolved to amber" lines.1.colorHex "#FFB340"
field "  the string emphasis became a run" lines.0.runs.1.text "tide"

ok "emphasis the copy never says is dropped" 0 -- \
  craft --response "$FIXTURES/phantom-emphasis.json" --json --expect-lines 1
field "  one run, no phantom" lines.0.runs.0.text "Barefoot is a state of mind"

ok "more than five parts are capped" 0 -- \
  craft --response "$FIXTURES/too-many.json" --json --expect-lines 5

echo
echo "== real Gemma 4 E2B generations, replayed =="
# Captured 2026-09-04 from mlx-community/gemma-4-e2b-it-4bit via craft-probe.
# Every one is a raw reply, markdown fence and all, kept verbatim: these are
# the answers that found the defects, so they are the ones that must not
# regress. See craft_fixtures/README.md for how to capture more.
ok "a good generation lays out" 0 -- \
  craft --response "$FIXTURES/real-gemma-good.json" --json --expect-lines 2
field "  two lines"              lineCount        2
field "  the payoff is amber"    lines.1.colorHex "#FFB340"
field "  emphasis survived"      lines.0.runs.0.text "Sand"

ok "an answer with NO payoff line gets one" 0 -- \
  craft --response "$FIXTURES/real-gemma-no-payoff.json" --json
field "  exactly one amber line" lines.2.colorHex "#FFB340"
field "  the repeat was dropped" lineCount 3

ok "enumerated emphasis is dropped, not drawn" 0 -- \
  craft --response "$FIXTURES/real-gemma-overemphasis.json" --json --expect-lines 1
field "  one run, no inverted scheme" lines.0.runs.0.text "Visit Prague this summer"

ok "every-word emphasis is dropped" 0 -- \
  craft --response "$FIXTURES/real-gemma-every-word.json" --json --expect-lines 5
field "  the first line is plain" lines.0.runs.0.text "Grand opening"

ok "a stem emphasis snaps to the whole word" 0 -- \
  craft --response "$FIXTURES/real-gemma-stem-emphasis.json" --json
field "  passes, not pass+es" lines.0.runs.1.text "passes"

ok "the fence-echo failure mode is refused, not half-drawn" 65 -- \
  craft --response "$FIXTURES/real-gemma-fence-echo.txt"
# ^ Gemma sometimes answers by echoing the prompt's own triple-quote style
#   instead of writing JSON. At temperature 0.7 one brief did this 3 times in
#   5; at 0.0, never (22/22 briefs parsed). The app now asks for this answer
#   at temperature 0 — but the shape still has to be survivable, because a
#   local model is a local model.

echo
echo "== the answers a local model actually gets wrong =="
ok "parts with no copy are refused" 65 -- craft --response "$FIXTURES/no-copy.json"
ok "prose with no JSON is refused"  65 -- craft --response "$FIXTURES/not-json.txt"
ok "the wrong JSON shape is refused" 65 -- craft --response "$FIXTURES/wrong-shape.json"
ok "a refusal still fails the build even with a brief to fall back to" 65 -- \
  craft --response "$FIXTURES/not-json.txt" --brief "a little sand between your toes"

echo
echo "== the no-model fallback: what ships when nothing is installed =="
ok "a brief alone lays out" 0 -- \
  craft --brief "A little sand between your toes helps wash away the woes" \
        --json --expect-lines 2
field "  split on the word count" lines.0.copy "A little sand between your toes"
field "  the last line is the payoff" lines.1.colorHex "#FFB340"
field "  and it follows the first" lines.1.followsIndex 0
field "  the source is named" source "splitter (no model)"

ok "punctuation splits into three" 0 -- \
  craft --brief "Salt air, slow steps, nothing owed" --json --expect-lines 3
field "  the last is still the payoff" lines.2.copy "nothing owed"

ok "one short line stays one line" 0 -- craft --brief "Prague" --json --expect-lines 1
ok "an empty brief is an error"    1 -- craft --brief "   "

echo
echo "== the chain, resolved the way the document resolves it =="
ok "each line opens where the one above ends" 0 -- \
  craft --brief "Salt air, slow steps, nothing owed" --json --playhead 0.5
LINE0_END=$(printf '%s' "$OUT" | python3 -c "import json,sys;print(round(json.load(sys.stdin)['lines'][0]['revealEnd'],6))")
LINE1_START=$(printf '%s' "$OUT" | python3 -c "import json,sys;print(round(json.load(sys.stdin)['lines'][1]['revealStart'],6))")
if [ "$LINE0_END" = "$LINE1_START" ]; then
  echo "ok    line 2 starts at line 1's reveal end ($LINE0_END)"
  PASS=$((PASS + 1))
else
  echo "FAIL  line 2 starts at $LINE1_START, line 1 ends at $LINE0_END"
  FAIL=$((FAIL + 1))
fi
field "  line 1 keeps the seeded band" lines.0.revealStart 0.44

echo
echo "== the frame the lines are fitted to =="
ok "a portrait frame shrinks the type" 0 -- \
  craft --brief "A reasonably long line of copy to fit" --aspect 3:4 --json
PORTRAIT=$(printf '%s' "$OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)['lines'][0]['size'])")
ok "a landscape frame does not" 0 -- \
  craft --brief "A reasonably long line of copy to fit" --aspect 4:3 --json
LANDSCAPE=$(printf '%s' "$OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)['lines'][0]['size'])")
if python3 -c "import sys;sys.exit(0 if $PORTRAIT < $LANDSCAPE else 1)"; then
  echo "ok    portrait type is smaller ($PORTRAIT < $LANDSCAPE)"
  PASS=$((PASS + 1))
else
  echo "FAIL  portrait $PORTRAIT is not smaller than landscape $LANDSCAPE"
  FAIL=$((FAIL + 1))
fi

echo
echo "== \"Needs work\": three directions =="
ok "a candidates answer parses" 0 -- \
  craft --options --response "$FIXTURES/candidates.json" --json --expect-lines 3
field "  the first direction" options.0 "A little sand between your toes"
ok "more than three are capped" 0 -- \
  craft --options --response "$FIXTURES/candidates-extra.json" --json --expect-lines 3
ok "a parts answer read as options is empty" 0 -- \
  craft --options --response "$FIXTURES/good.json" --json --expect-lines 0

echo
echo "-----------------------------------------"
echo "craft_ci: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
