# Shape-mation — review of the interaction prototype hand-off

*2026-09-20, evening. Reviewed: the Claude Design bundle `Shape-mation interaction
prototype-handoff.zip` (Steven's Downloads) — `Shape-mation Prototype.dc.html`,
`ShapemationSteps.dc.html`, `model.js`, `support.js`, the kit's 100 compositions
(manifest identical to `../design/kit/compositions/`). Built from
[`prototype-brief.md`](prototype-brief.md). Nothing was implemented; the prototype
was read, not run in a browser. This document adds what the hand-off marks OPEN
"for the developer": `model.js`, unchanged, run over the real tram library
(`~/Library/Developer/LetsLapseRun/libraries/tram-root`), with contact sheets.
Scripts, raw run output and sheets are in [`prototype-review/`](prototype-review/).*

## 1. Verdict

The concept holds and is worth building: one computation (cover fit → median
path → per-photo zoom → crop badge) feeds the list, a **Sequence board**, the
scrub and the render; rejects, keys, per-photo holds and a Shape-mation record
that keeps its stills. On Steven's 83 portrait trams the model's survivors read
as one approach (sheet 1) — the goal of brief §1 is reachable from a real,
messy library.

`model.js` is a faithful port of brief §4: σ-sorted, it reproduces the brief's
bad-apple table to the percent. But the prototype as built has six spec-level
faults that should be fixed in the spec **before** anything is ported (§4
below), three of its written decisions rest on evidence its own model
contradicts, and the real library asks for two things the model does not have:
the source's own aspect as a rect, and a size term ("placement only matters
while the tram is small", §1 of the brief — not in §4, not in the code).
Steven's rule for what follows (2026-09-20 evening): the rect and the inputs
are for **any** subject — a tram today, a door frame, an archway, a building,
a dinner plate or a manhole tomorrow — so §6 restates every decision as a rule
for any shortlist, with the trams as one data point, never as the case.

## 2. What the prototype gets right

- **The board.** Preview + strip locked, a self-scrolling side column with the
  source-and-window card, the two charts, the cog. The strip (Q8) is the right
  form at 83 photos; held photos wider in the strip is a good idiom.
- **Rejects that stay reachable**, Keep anyway, keys stored by photo id (a
  reject cannot move a key to another photo), per-photo hold overriding the
  ramp, Collections with the stills as members and Re-render with members
  locked. All of it is scoped in the hand-off's Required bucket, sensibly.
- **Fixed shape as an option seat on the board** (Q9; the prototype's label is
  "Fixed face") with the mode card as the entry — right, and it reuses the
  shipped evaluator.
- **Exposed thresholds behind a cog** until Q1 is answered on real data — the
  right instinct; §3 is that answer's first half.
- The states list and the Shipped / Required / Open / Enhancement table are
  usable as they are for planning.

## 3. The model on Steven's trams

**The library.** 84 registers with a rectangle (83 portrait 3024×4032, one
landscape); one afternoon's walk, 2026-09-13 12:41–14:15 — capture order is
that walk, and the "months" of §1 is not yet true of this set. Shape share `s`
(long side ÷ short edge) 13–95 %, median 38 %; centre x 0.39 / 0.54 / 0.86;
81 of 84 in the centre column, 76 in the centre cell. (The brief's "share
0.094 / 0.284 / 0.709" was measured against the long edge — same photos × 0.75.)
The biggest quad is used where a register has several, as the app does.

### 3.1 Q10 — the rect for a portrait library

Portrait 83, the prototype's defaults (window 5 · median ends · f 15 / 30 % ·
one pass · smallest first):

| rect | rejected | amber | red kept | mean f | aspect loss | mean L | Σ J |
|---|---|---|---|---|---|---|---|
| **3:4 (the source's own)** | 28 | 25 | 5 | 16.8 % | 0 % | **16.8 %** | 2.34 |
| 4:5 | 22 | 26 | 2 | 13.2 % | 6.3 % | 18.6 % | 3.13 |
| 2:3 | 17 | 24 | 1 | 12.6 % | 11.1 % | 22.3 % | 3.65 |
| 9:16 | 13 | 24 | 1 | 11.0 % | 25.0 % | 33.2 % | 5.05 |
| 1:1 | 20 | 20 | 1 | 9.8 % | 25.0 % | 32.3 % | 4.06 |
| 16:9 | 20 | 20 | 1 | 9.8 % | 57.8 % | 61.9 % | 6.54 |

Reading: a rect further from the source's aspect gives every photo free
shifting room (the overhang), so `f` and the reject count fall — while `L`,
what is actually gone from the picture, rises. **Judged on `L`, the native 3:4
is the least-loss rect for this library, and it is the one rect the prototype
does not offer.** 4:5 is a fair second (one tap from 3:4 for posting). 9:16
looks best on the board's numbers and throws a quarter of every photo away
before the path asks for anything — the 16:9 trap of Q10 in a milder form. The
one landscape photo, kept in, reads amber at 4:5 (f 18 %) while losing 51 % of
itself — the aspect filter on step 1 is right to take it out.

Sheets: [4:5 as it would render](prototype-review/trams-4x5-rendered.jpg) ·
[4:5, the window over each source](prototype-review/trams-4x5-sources.jpg) ·
[3:4 as it would render](prototype-review/trams-3x4-rendered.jpg).

### 3.2 Q1 — window, ends, thresholds, passes

Portrait 83 → 4:5:

| rule | rejected | amber | red kept | mean f | f at first / last photo |
|---|---|---|---|---|---|
| w3 · median · one pass | 22 | 18 | 1 | 10.3 % | 11.9 / 3.9 % |
| **w5 · median · one pass (default)** | 22 | 26 | 2 | 13.2 % | 3.7 / 15.8 % |
| w7 · median · one pass | 25 | 20 | 5 | 13.9 % | 2.8 / 3.5 % |
| w5 · **trend** · one pass | 22 | 25 | 2 | 13.2 % | 11.8 / 12.1 % |
| w5 · median · **fixpoint** | 25 | 24 | 0 | 12.1 % | 3.7 / 15.8 % |
| w5 · median · thresholds on z 1.10 / 1.20 | 22 | 19 | 2 | 13.2 % | 3.7 / 15.8 % |
| w5 · median · auto-reject off | 0 | 28 | 22 | 21.9 % | 3.7 / 15.8 % |

The same at 3:4 and 9:16 is in [`model-run.md`](prototype-review/model-run.md).

- **Window.** The board's `Σ J` is 3.08 / 3.13 / 3.00 for windows 3 / 5 / 7 —
  it cannot tell them apart. The **rendered** path's jump, `Σ |P(i+1) − P(i)|`,
  is 2.23 / 1.05 / 0.92: window 3 follows the noise and the sequence lurches
  twice as much on screen. Window 5 is the right default; 7 costs three more
  photos for a small gain.
- **Ends.** Trend-continued ends (the proposed Q2 answer) make the first photo
  *worse* on the trams (3.7 → 11.8 %). They only help the kit's clean approach
  because its drift is a perfect line (8.0 / 13.1 → 0.2 / 0.3 % — confirmed).
  On a real set the end fit extrapolates noise. Keep the median ends.
- **Thresholds on z** reject the same photos (z 1.2 ≡ f 30.6 %); f is the
  legible number. Agree with the prototype.
- **Passes.** One pass leaves red photos *in* the sequence: at 4:5 two, at 3:4
  five — photos 2, 3 and 4 of the 3:4 sequence render at 31–41 % crop with a
  red badge nobody acted on (sheet 3). The fixpoint takes three more at 4:5
  and converges in two passes. See §4, fault 5.
- **The line itself.** For a same-aspect library the reject threshold is a
  tolerance on position: a 3:4 photo into 4:5 has no horizontal room, so
  f ≥ 30 % means "the shape is more than ~0.08 of the frame width off the
  path". The 22 rejects sit 0.05–0.33 off it. Whether that is the line is
  Steven's call from the sheets; the numbers say 30 % is strict but not wrong
  for the *small* trams, and wrong for the large ones (next).

### 3.3 What the model lacks for a real library

**A size term.** Brief §1: placement only matters while the tram is small;
once it fills the frame it fills left and right anyway. Neither §4 nor
`model.js` has this — the thresholds are constant along the sequence and
`Σ J` alone is discounted by size. At 4:5, **6 of the 22 rejects have shapes
of 50 % or more**. A path that lets go as the shape grows,
`target = p + (P − p)·(1 − σ)^γ`:

| rect | γ | rejected | of which s ≥ 50 % | mean f | mean L | rendered Σ ΔP | largest step |
|---|---|---|---|---|---|---|---|
| 4:5 | 0 (as built) | 22 | 6 | 13.2 % | 18.6 % | 1.05 | 0.088 |
| 4:5 | 0.5 | 13 | 1 | 11.5 % | 17.0 % | 2.36 | 0.117 |
| 4:5 | 1 | 7 | 1 | 9.9 % | 15.5 % | 3.72 | 0.180 |
| 3:4 | 1 | 11 | 1 | 12.7 % | 12.7 % | 3.33 | 0.172 |

γ = 1 keeps fifteen photos the prototype rejects and rejects nothing new; the
price is a rendered jump three times larger, all of it at the large end where
the brief says it does not matter. [Sheet 4](prototype-review/trams-4x5-sizeaware-rendered.jpg)
is that variant for viewing — the decision is a viewing, not a number.

**Sorts (4:5, defaults).** Smallest first rejects 22; capture order 18;
**alignment (K = 3) 13**, with no red left and mean f 11.3 % — on the real set
the alignment chain keeps nine more photos than the size sort (Q6, a stronger
result than on the kit), at 25 breaks in the size curve against 23.

**The size stutter.** The size chart's "must be monotonic" line will be red on
every real set: 23 breaks in 61 on a *pure* size sort, because the per-photo
zoom `z` (1.00–1.22) magnifies the shape by more than neighbours differ in
`s`. The message blames the sort; the cause is least crop itself. Re-sorting
on the rendered size does not converge (24 then 20 breaks; the dips grow from
6 to 10 % of the short edge) because the order moves the path, which moves
`z`. The candidate fix is a smoothed zoom — a floor on `z` from the running
median of the neighbours' `z`, paying a little more crop for a steady size —
untested.

**Angles.** The strobe the brief describes is plainly visible in every sheet:
front-on T3s, three-quarter views, Škoda 15Ts and the historic car alternate
by size alone. The same-angle tie-break needs a `tram` field the registers do
not have (pose is the STRETCH item). A cheap proxy worth testing: the shape's
own aspect (`bbox.w / bbox.h`) — a front view is near 1.4, a three-quarter view
narrower — as the grouping key.

### 3.4 Checks against the brief on the kit

- Bad-apple 10 → 3:2, σ-sorted, no auto-reject: model.js gives 95 / 20 / 13 /
  4 / 11 / 46 / 0 / 21 / 37 / 44 %, Σ J 1.08 · mean f 29 % — the brief's table.
- The same set **as the prototype actually orders it** (native `s`): Σ J 1.53,
  #11 at 20 % not 0 %, #13 6 not 11, #21 12 not 21, #26 43 not 37. Ten
  neighbour inversions on the mixed 40; none on the trams (one aspect).
- Auto-reject, one pass: rejects **#05, #10, #26, #27** (six kept); the
  fixpoint rejects the same four.
- Mixed 40 → 3:2: 23 of 40 rejected; the left column 4 of 12 (8 kept, 12 %).
- Portrait 30: 2:3 rejects 6 (f 8.6 %), 4:5 6 (7.9 %, L 23 %), 9:16 3 (1.5 %,
  L 17 %), 16:9 5 (9.0 %, L 66 %).

## 4. Faults in the prototype — fix in the spec before porting

1. **The sort keys on the native share, not the rendered one.** `sortPhotos`
   orders by `s`; brief §5b names exactly this as the shipped departure to fix
   (§7.5). The board therefore shows different numbers for the brief's own
   example (§3.4). Sort and the share line on σ = `s` × the cover-fit
   magnification. Harmless on a one-aspect library, wrong on the mixed case
   the prototype demos.
2. **`Σ J` on the board measures the shortlist, not the render.** It is summed
   over the natural positions `p`; every kept photo renders *on* the path, so
   what the viewer sees is `Σ |ΔP|`. The board's number is blind to the window
   (§3.2). Keep `Σ J` for the alignment sort; put the rendered jump on the
   board.
3. **Q1's evidence contradicts the model.** The Decisions tab says the fixpoint's
   second pass takes the three left-edge shapes (10, 26, 27) too; the live line
   above it, and this run, show one pass already taking 05, 10, 26 and 27 —
   both settings reject the same four. "One pass" as built rejects every red at
   once, not the bad apple alone. The recommendation for one pass was argued
   from a claim the prototype's own numbers refute.
4. **Q2's proposal is not the prototype's default.** Decisions propose
   trend-continued ends; the state (`ends: 'median'`) and Reset keep the
   median. On real data the median is the better one (§3.2) — the default is
   right, the decision text is wrong.
5. **One pass leaves reds in the sequence** (§3.2). Either run to a fixpoint
   with a floor (never below N kept, then stop and show), or label a kept red
   "would go on the next pass" with a one-tap Reject.
6. **`L` is missing.** Brief §4 wants the loss beside the crop risk on hover and
   on the count line, precisely so that a wider rect cannot look better by
   throwing pixels to the aspect crop (§3.1). The prototype shows `f` only.
7. **No native-aspect rect.** Add "Source" (the set's dominant aspect, brief
   §4's stated default) as the first chip; on this library that is 3:4.
8. **The ×2 rule is baked into the fixed-shape function** (`fixedFace`,
   `ph.width * 2`). It is the kit's
   SVG rasterisation rule, not a property of photos; "port formula for formula"
   would carry it into the app. The shipped `ShapemationFraming` evaluator is
   the reference for Fixed shape, not this function.
9. **The size chart's message** blames the sort for breaks that least crop
   causes (§3.3); reword, and treat the smoothed zoom as the fix to test.
10. **No size term** (§3.3) — the one thing in brief §1 that §4 forgot.
11. **The share can exceed 1.** Brief §4 defines `s` as the shape's long side
    ÷ the frame's short edge, and the shipped `ShapemationSort.share` is the
    same number (`nativeDiameterPx ÷ short edge`). For a shape whose long side
    runs along the frame's *long* edge — a door frame or an archway in a
    portrait photo, a facade in a landscape one — it passes 1: a door filling
    the frame's height reads "120 % of the frame" on the Projects row, and
    `(1 − s)` goes negative in `Σ J` and in the alignment sort's cost, which
    then *prefers* the biggest jumps. The tram never hits it because its shape
    is wider than tall in a portrait frame. Define the share on each axis as a
    fraction of the frame's own extent, `s = max(w ÷ W, h ÷ H)`: bounded by 1
    for any shape inside its frame, and identical to today's number for the
    tram. §6, Q2.
12. Small: `support.js` loads React and Babel from unpkg, so the "runs from
    the repo with no build" prototype needs a network; `github.md` names branch
    `main` — the design docs live on `ios-app`, `main` is the Pi project; the
    Circle family and the "Bad apple" tag are staged, as the notes say.

## 5. On the hand-off table

- **Required** — agree with every row. Two additions from §4: the rendered
  jump on the board (2) and `L` (6). One correction: "model.js as Swift,
  formula for formula" minus the fixed-shape function (8) and with the σ sort (1).
- **Collections with stills as members** is a new document that travels
  (PicPlace, `.lapse`, transfer) — the WP0b lesson applies: forward-tolerant
  reader and version gate shipped before the writer; the record stores each
  member's shape as a snapshot (the hand-off says so) and must also store the
  rect, path settings, rejects and keys by photo id, so a later Find shapes
  cannot move anything.
- **Open** — Q1 and Q10 now have their first real-library answer (§3). The
  decisions they leave are restated in §6 as rules for any subject, with this
  library as one data point. Owed: Steven's viewing of the four sheets and the
  answers to §6.
- **Enhancement** — the 3×3 column filter earns nothing on this library
  (81 of 84 in the centre column); keep it, expect it idle. Per-photo hold and
  zoom-at-key are fine. The phone pass is unreviewed here.
- **The sheet growing to 900 × 720 on the board step** is feasible on macOS
  (a per-step frame on the sheet; sheets are not user-resizable, programmatic
  sizes are fine) and moot on iPhone, where the board stacks.
- **Implementation is UI work** — the design-sync question applies before the
  first Swift line: design files first, code first, or the hand-off's HTML as
  the spec with the mirrors redrawn after. The seven macOS builder mirrors the
  prototype was recreated from are untracked in the working tree today.

## 6. The questions, reframed for any subject

The model's inputs are already generic — a shape's bounds and centre in its
own frame, the frame's aspect, the rect — and the register carries every
family (circle, oval, square, rectangle; rotated or not) through
`DetectedShape.bounds(in:)`. What was tram-shaped in this review was the
*decisions*. Restated as rules the app applies to any shortlist. The
principle behind them: anything that depends on what the subject *is*, or on
what the sequence is *for*, is a per-sequence control with a default, never a
constant in code — the app cannot know whether the scene around the shape is
the picture (a tram in its street, an archway, a building) or the shape is
(a plate, a manhole). The brief and the prototype say "face" for the tram's
front; this document and the spec say "the shape".

**Q1 · The rect.** Rule: the first chip is *Source* — the shortlist's dominant
aspect, computed per set — and it is the default; the standard rects follow,
each with its mean loss `L` for *this* shortlist under it, so the trade is
visible per library. Decide: Source by default, or the least-loss standard
rect? Data point: trams → Source is 3:4 at L 17 %, 4:5 19 %, 9:16 33 %; a
square-shot manhole set would have Source 1:1.

**Q2 · A bounded share.** A fix to confirm, not a choice (§4, fault 11):
`s = max(w ÷ W, h ÷ H)`. It changes the Projects row's "% of the frame" for
tall shapes in portrait frames and wide shapes in landscape ones, nothing for
the trams.

**Q3 · The crop line is a tolerance.** Rule: flag and reject are a
per-sequence setting with named levels, the way Match has strictness —
*strict* (the scene is the picture), *normal* (15 / 30 %), *loose*, *none*
(nothing rejected, every shape pulled to the path whatever it costs) — kept
with the record. Decide: the levels' numbers, the default level, and whether
*none* is where Fixed shape lives, so that one dial runs from "the scene is the
picture" to "the shape is the picture" instead of two option seats. Data
point: at normal, 22 of 83 trams go at 4:5; a plate or manhole set would run
loose or none.

**Q4 · Placement against size.** Rule: the path's pull weakens as the shape's
rendered share grows — `target = p + (P − p)·(1 − σ)^γ` — and the rate follows
the same tolerance: strict lets go early (the scene must survive), loose holds
the place and pays the crop (the shape is what matters). Decide: adopt the
coupling, or give the rate its own control. Data point: γ = 1 keeps 15 more of
83 with the whole extra jump at the large end (sheet 4). A set of large,
constant-size shapes (plates) wants loose + hold; an approach through a scene
wants strict + let go.

**Q5 · The anchor.** Rule: the point of the shape the path places is the
centre of its bounds, for every family. Decide: is it ever another point of
the bounds, chosen per sequence with the nine-point picker the design already
has — a door's threshold, a building's base line, the crown of an arch —
default centre.

**Q6 · The sort and the size chart.** Rule: when the shortlist's share range
is narrow (largest ÷ smallest below about 1.5) a size sort is a shuffle, the
default is capture order or alignment and the "monotonic size" check is off;
when it is wide, smallest first (or largest first) with the check on. Decide:
the ratio, or an explicit choice on the Mode step — *an approach* or *a set*.
Data point: trams 13 → 95 %, an approach; plates might span 60–90 %.

**Q7 · Passes.** Rule: run the rejects to a fixpoint with a floor — never
below the larger of eight and half the shortlist — because a kept red is a
badge nobody can act on. Decide: the floor.

**How to answer them on more than one subject.** `prototype-review/run.mjs`
takes any folder of projects with registers; a clone of a second tagged set
(doors, plates, whatever exists) is made the way `tram-root` was, and the same
tables and sheets come out in minutes. Defaults should be fixed in code only
after a second subject has been through it.

## 7. Files

- `prototype-review/run.mjs` — the run over the registers (the hand-off's
  `model.js` copied unchanged as `model.mjs` beside it when run; it is not in
  the repo); `extra.mjs` (rendered jump, size-aware path), `extra2.mjs`
  (re-sort on rendered size); `sheet.py` (the contact sheets from the
  projects' posters; the geometry is the register's, resolution-independent).
- `prototype-review/model-run.md`, `model-run-extra.md`, `model-run-extra2.md`
  — the raw output, every table above and the per-photo table for 4:5.
- `prototype-review/trams-4x5-rendered.jpg`, `trams-4x5-sources.jpg`,
  `trams-3x4-rendered.jpg`, `trams-4x5-sizeaware-rendered.jpg` — the sheets.
- The hand-off itself is in Steven's Downloads; it was not copied into the
  repo (the brief's §7.1 asked for `docs/shapemation/prototype/`; add it there
  with `model.js` if it is to be kept beside this review).
