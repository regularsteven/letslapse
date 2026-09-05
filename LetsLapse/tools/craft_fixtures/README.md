# Crafted Text fixtures

Model answers for `lapse craft --response <file>`, driven by
[`../craft_ci.sh`](../craft_ci.sh). The first set below is hand-written to
cover shapes a local model produces; the `real-gemma-*` set is verbatim
output from Gemma 4 E2B, and every one of those found a real defect.

| File | What it stands for |
| --- | --- |
| `good.json` | A clean answer: three parts, one of them priority 1. |
| `prose-wrapped.json` | The model explains itself either side of the JSON. Common enough that finding the object is part of the job. |
| `loose-types.json` | `emphasis` as a bare string, `priority` as `"2"` and as `1.0`. All three turn up. |
| `phantom-emphasis.json` | An emphasis the copy never says — dropped at parse time so the answer and the drawing cannot disagree. |
| `too-many.json` | Eight parts. The layout can place five, so five is what survives. |
| `no-copy.json` | Parts with no copy at all → refused, never invented. |
| `not-json.txt` | A refusal. No object, no layers. |
| `wrong-shape.json` | Valid JSON, wrong keys — the model answered a different question. |
| `candidates.json` | A "Needs work" answer: three directions. |
| `candidates-extra.json` | Five directions; the sheet shows three. |

## Real generations (2026-09-04)

Captured from `mlx-community/gemma-4-e2b-it-4bit` via `craft-probe`, verbatim
— markdown fence and all, because that is how they arrived. Each one found
something.

| File | What it found |
| --- | --- |
| `real-gemma-good.json` | A well-formed answer: two lines, one payoff, emphasis that is actually a highlight. The shape everything else is measured against. |
| `real-gemma-overemphasis.json` | "Visit Prague this summer" with three of four words emphasised — inverts the amber payoff line. |
| `real-gemma-every-word.json` | Every word of every line emphasised, 100% coverage. |
| `real-gemma-no-payoff.json` | Priorities 2, 3, 4, 5 — no payoff line at all, and a repeated line. |
| `real-gemma-stem-emphasis.json` | Emphasis `"pass"` against copy "Time passes." — a word split in half. |
| `real-gemma-fence-echo.txt` | The model answering in the prompt's own triple-quote style instead of JSON. The failure mode temperature 0 removes. |

## Capturing a real generation

The first table above is hand-written; the second is real. To add another
real one, capture the raw answer and drop it in beside these:

```sh
# The prompt the app would send, verbatim:
lapse craft --prompt split --brief "your brief here"
```

Put that prompt through the model with `craft-probe`, which loads the same
snapshot the app does:

```sh
lapse craft --prompt split --brief "your brief here" \
  | craft-probe --stats --temperature 0 > captured.json
```

(Build it with xcodebuild — see `../mlx-vlm-spike/README.md`. Temperature 0
is what the app asks for on this call; 0.7 measurably produces unparseable
answers.) Then run it through:

```sh
lapse craft --response captured.json --json
```

A generation that lays out cleanly is worth adding here as a regression
case. One that does not is worth adding *twice*: once as a fixture, and
once as a fix.
