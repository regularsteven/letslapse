# Shape-mation — interaction prototype brief

*For an interaction / interactive-prototype designer who has never seen the
app. Written 2026-09-20, the day development paused; rewritten the same day
around Steven's stated goal (§1). Paths are relative to `LetsLapse/`; links
open from this folder.*

---

## 1. The goal

A person has a library of photographs of one recurring thing — for Steven, a
Prague tram — taken over months: the tram hard left, hard right, dead centre,
top middle; landscape and portrait; tiny in the distance and filling the
frame. They want **a sequence in which the tram starts small and far away,
surrounded by its scene, and comes closer and closer** (or the reverse). Two
things make that read as one motion rather than a slideshow: the tram's
**size progresses consistently**, and its **placement is consistent** — it
does not lurch from the left of the frame to the right between neighbours.
And they want **as little cropping as the photos allow**: a crop that pulls
every tram to one point destroys the scene around it, and the scene is what
sells the sense of scale. Placement only matters while the tram is small;
once it fills the frame it fills left and right anyway — that is simply what
coming closer looks like.

The prototype must prove that, from that real and messy library, a person
can **shortlist** (filters and shapes), **sort** (small → large by the
shape's size), **see every photo as it will render** before anything is
rendered, **reject the crop-risks** — by hand or automatically; one bad
apple, a small tram hard right among nine hard left, must not force a tight
crop on the nine — **set a few framing keys** (start, end, some middle ones)
that transition smoothly, and **know before rendering that the result will
hold**. "The shape" throughout is the drawn outline of the consistent element
— the tram's face — never the whole photo.

Build it as a **high-fidelity, disposable HTML/JS prototype**: every question
in §6 is answered by something people can click, scrub and argue over, and
the code is thrown away. Steven signs off the prototype plus its written
answers; a developer agent then implements the signed-off interactions in
the Swift app from the spec and the states, never from the prototype's code.
The original developer brief is [`brief.md`](brief.md); every feature in its
§2–§7 has a home below or is parked in §8. [`gap-map.md`](gap-map.md) is the
ledger of what exists in code.

## 2. What Shape-mation is, and what is already true

Shape-mation builds motion from stills: the user marks the subject in each
photo with a shape, and the app uses it as the anchor for sorting, placing
and cropping. It needs many photos; the photographs were composed by a
person; and a real set mixes sizes, positions and aspects — so most of the
design problem is *choosing and ordering the set* and *showing what will
land badly before the render*.

**Already true in the app** (mirrors `docs/design/iOS/shapemation*.svg` and
`docs/design/macOS/shapemation*.svg`, rows in
[`../design/iOS/INDEX.md`](../design/iOS/INDEX.md) and
[`../design/macOS/INDEX.md`](../design/macOS/INDEX.md); open two for the
house style):

- **The flow**, a 560 pt sheet: Apply filters (tag rows, search, live count)
  → Which shape holds still? (Circle · Oval · Square · Rectangle) → Match →
  Projects (Largest first · Smallest first · Capture order) → Mode (Stack ·
  Crop · Output frame) → Timing (fps; hold and ramp Start / Middle / End as
  selects, never sliders) → Output → done. Start from it; reorder or merge
  steps, and say so.
- **Output frame** ([`output-frame.md`](output-frame.md), shipped
  2026-09-19) — here the option **Fixed face** (§5f): an output rectangle
  (1:1 · 4:5 · 3:2 · 16:9 · 2:3 · 9:16, long edge 1080 · 1920 · 2160) and, at
  the first and last photo, where the face sits and how big it is (10–80 % of
  the height); every photo is scaled and placed to put its face there; each
  gets a verdict — `fits` · `short` (a black side) · `upscaled` (past ×2) ·
  `shortAndUpscaled` (both) — and nothing is dropped. A scrub shows photo *i* through the real evaluator.
  The model accepts ≥ 2 keys at any index; the builder exposes two.
- **Per-photo shapes** in a per-project register (`shapes.json`): kind,
  centre, corners, native size. There is no crop-risk, path, alignment sort,
  photo collection, board or shape inventory.

## 3. The assets: the scene kit

`docs/design/kit/` ([README](../design/kit/README.md)) generates synthetic
photos — a sky + a scene + a Prague T3 tram placed by a one-point-perspective
camera, always on its rails, every number exact — so the prototype has a
diverse, truthful set without a real capture and **never detects anything**.

`docs/design/kit/compositions/` holds **100 self-contained SVGs** (1.8 MB;
`<img src>` or inline) and [`manifest.json`](../design/kit/compositions/manifest.json),
one entry per file:

| Field | Meaning | Use it for |
|---|---|---|
| `id`, `file` | `city.clear.approach.01`; `file` is relative to `docs/design/` — from the prototype folder prefix `../../design/` | the sequence prefix is everything before the last `.NN` |
| `width`, `height`, `aspect` | frame pixels; `3:2` (46) · `2:3` (30) · `4:3` (10) · `1:1` (9) · `16:9` (5) | `a_i`, the photo's own frame |
| `scene`, `sky`, `tram` | city … depot · clear … night · front / left / right / high / low | mixing a set; the same-angle tie-break (§5b) |
| `size`, `cx` | recipe inputs: the WHOLE tram's height ÷ frame height; where it lands | nothing — the model uses `bbox`, never `size` |
| `bbox` `{x,y,w,h}` | the **tram face's** bounds in frame px — the drawn shape | `c_i` and `s_i` (§4) |
| `margins` `{left,top,right,bottom}` | negative space per side, fractions of the frame | the per-side room; show it on hover |
| `cells` (9), `cell` | overlap with each 3×3 cell, row-major; the cell holding ≥ 95 %, else `mixed` | the coarse position filter (§5a) — never the classifier |

The SVG root repeats these as `data-*` attributes; the last
`<polygon data-role="shape">` is the face outline. **Sequences**:
`city.clear.approach` ×12 (3:2, drifting right as it nears),
`oldtown.golden.approach` ×12 and `depot.night.approach` ×8 (2:3),
`hills.dusk.right` ×8, `mountains.clouds.mixed` ×8, twelve `single.*`, and
**`mixed.random.01…40`** — every aspect, scene, sky and angle, face share
0.06–0.49, centre x 0.16–0.87.

**The three sets the prototype must show**, and what §4 says about each:

1. **The clean case** — `city.clear.approach`: mean crop 2.7 %, nothing
   flagged.
2. **The mixed 40** — a library's chaos, not a sequence: straight onto the
   board in 3:2 (the 40 tie 3:2 and 4:3 at ten each; the kit's 46 of 100
   break it), 22 of 40 are red, which is the board saying *shortlist first*;
   the left column alone (12 photos, `cx < ⅓`) comes down to 9 kept at a
   mean crop risk of 14 % after one pass, 8 at 10 % to a fixpoint — and its
   five squares each lose a third of their picture to the aspect before any
   shift, which only the loss line shows.
3. **The bad-apple set** — nine small trams on the left,
   `mixed.random.01 · 02 · 07 · 10 · 11 · 13 · 21 · 26 · 27` (centre x
   0.18–0.32, share 0.06–0.25), plus **`mixed.random.05`** on the right
   (x 0.83, share 0.07 — sorted by rendered size its 4:3 frame lifts it to
   0.080 and it lands first). Alternatives:
   `single.city.sun.right-cell` (x 0.855), `mixed.random.22` (x 0.81).

A real library is not an approach. Steven's trams (164 projects, 84
registers, 85 rectangles, 83 on portrait 3024×4032) have faces 9–71 % of the
frame's short edge (median 28 %), centre x 0.39–0.86 (median 0.54), 77 of 85 in
the middle-centre cell, angles mixed. [`mixed-scenes-report.md`](mixed-scenes-report.md)
§5: size-sorted, the angle swings on three of four cuts (keep same-angle
runs together); faces near an edge cannot meet a fixed point without a black
side; a 14× size spread turns near photos into stamps under one working
scale. The kit's **30 portrait compositions** (2:3) stand in for the tram
library; their default rectangle is Q4.

## 4. The model: least crop

One computation feeds the board, the list, the charts and the render. Write
it once. Everything is a ratio of the photo's frame and the output rect, so
the SVG sizes are used as they are (the ×2 rasterisation rule of
`output-frame.md` matters only to Fixed face's `upscaled` verdict, §5f).

**Per photo *i***: face centre `c_i = (cx, cy)` in unit coordinates of its
own frame; face share `s_i` = the face's long side ÷ the frame's short edge
(the app's `ShapemationSort.share`); frame aspect `a_i = width ÷ height`.
**The output rect**: aspect `A` (the set's dominant aspect by default; a
tie goes to the library's dominant aspect, then the wider — the user may
choose), height `H`.

**Natural rendering** = cover fit: the photo scaled to exactly cover the
rect, centred, no shift — the least crop aspect alone forces, zero when
`a_i = A`. On the one axis the photo is longer, the overhang
`e = a_i ÷ A − 1` (wider) or `A ÷ a_i − 1` (taller) is free shifting room;
the other axis has `e = 0`. The face lands at `p_i = 0.5 + (c_i − 0.5) ×
(1 + e)` per axis — never upscaled beyond cover fit — at its **rendered
share** `σ_i = s_i × k_i`, its size against the rect's short edge: `k = 1`
when `a_i ≥ A` (the photo's short edge is the rect's), `A ÷ a_i` when
`1 ≤ a_i < A`, `A` when `a_i < 1` (a portrait photo's short edge spans the
rect's long one); mirrored for a portrait rect. `σ`, not `s`, is what the
eye sees: a 1:1 photo with `s = 0.062` into 3:2 shows a 9.2 % face beside a
16:9 photo's 9.3 % at `s = 0.093`. The size sort and the size chart run on
`σ`. The kit's aspect loss alone: `1 − 1 ÷ (1 + e)` — a third of every
square into 3:2, 62.5 % of every 2:3 into 16:9.

**The path** `P(t)`, the target face position over the sorted order,
`t_i = i ÷ (n − 1)`: by default a **running median** of the `p_i` over a
window of 5 in sorted order — one outlier does not bend it. Keys at the
start, the end and any middle index **pin** `P`; between keys `P` follows
the chosen ease; the automatic path is what keys override.

**The crop** a photo pays to bring its face from `p_i` onto `P(t_i)`: a
cover-fitted photo can only shift by zooming so the window can slide inside
it. Per axis, each side of the face needs as much room in the photo as the
window asks for:

```
z_axis = max( 1,  P ÷ (p + e/2),  (1 − P) ÷ (1 + e/2 − p) )
z_i    = max(z_x, z_y)
f_i    = 1 − 1 ÷ z_i²          crop risk: the share of the photo's pixels lost beyond the aspect crop
L_i    = 1 − 1 ÷ ((1 + e) z_i²) loss: everything gone from the source, aspect crop included
size   = σ_i × z_i             the face's rendered share — a distortion the sort did not ask for
```

(The shorthand `1 + 2·|P − p| − e` is this at `p = 0.5`; use the edge form —
it is what a hard-left face actually costs.) **Thresholds to tune**: flag
`f ≥ 15 %` (amber), auto-reject `f ≥ 30 %` (red); with auto-reject on the
path is re-smoothed without the rejected photos and every `f_i` recomputed.
`f` is the risk the *path* adds and drives the badge; `L` is what "as little
cropping on the source as possible" means and belongs on the hover and the
count line — a minority-orientation photo can read green on `f` while more
than half of it is gone.

**Placement coherence** between neighbours in the sorted order:
`J_i = |p_{i+1} − p_i| × (1 − σ_i)` — a placement jump, discounted as the
shape fills the frame. **Sort by alignment** orders the shortlist so `σ`
rises (or falls) while `Σ J` stays small — a greedy chain allowed any of the
next *K* = 3 by size is enough. A sequence's **two numbers**: `Σ J` and the
mean `f`, with the mean `L` beside them.

**Worked example** — two compositions into 3:2, the path from the nine-left
set. `mixed.random.07` (1800×1200, bbox 469.3 · 667.6 · 76.7 × 96.8):
`c = (0.282, 0.597)`, `s = 96.8 ÷ 1200 = 0.081`, `a = A` so `e = 0`,
`p = c`, `σ = s`. `P = (0.257, 0.685)`. x: left 0.257 of 0.282 → 0.91,
right 0.743 of 0.718 → **1.035**; y: top 0.685 of 0.597 → **1.147**, bottom
0.315 of 0.403 → 0.78. `z = 1.147`, `f = L = 1 − 1 ÷ 1.316 = 24 %`, face
8.1 → 9.3 %: amber. `mixed.random.10` (1200×1200, bbox 168.3 · 678.6 · 85.9
× 123.2): `c = (0.176, 0.617)`, `s = 0.103`, `a = 1 < 1.5` so `e_y = 0.5` (a
quarter overhangs top and bottom), `σ = 0.103 × 1.5 = 0.154`,
`p = (0.176, 0.675)`. `P = (0.240, 0.675)`. x: left 0.240 of 0.176 →
**1.364**; y: 0.675 of 0.925 and 0.325 of 0.575, both under 1. `z = 1.364`,
`f = 46 %`, `L = 1 − 1 ÷ (1.5 × 1.86) = 64 %`, face 15.4 → 21.0 %: red — a
face 18 % from the edge cannot come in to 24 % without losing nearly half of
what the aspect left.

**The bad apple in numbers** — the ten of §3, sorted by `σ` into 3:2:

| Photo | aspect | `s` | `σ` | `p` | `f`, median path | `f`, mean path | `f`, outlier as a key | `f`, median after reject |
|---|---|---|---|---|---|---|---|---|
| **mixed.random.05** | 4:3 | 0.071 | 0.080 | (0.833, 0.645) | **95 %** | 94 % | 0 % | — |
| mixed.random.07 | 3:2 | 0.081 | 0.081 | (0.282, 0.597) | 20 % | 18 % | 87 % | 24 % |
| mixed.random.01 | 1:1 | 0.062 | 0.092 | (0.240, 0.702) | 13 % | 36 % | 89 % | 7 % |
| mixed.random.02 | 1:1 | 0.062 | 0.092 | (0.257, 0.685) | 4 % | 27 % | 85 % | 4 % |
| mixed.random.13 | 3:2 | 0.135 | 0.135 | (0.240, 0.643) | 11 % | 36 % | 84 % | 11 % |
| mixed.random.10 | 1:1 | 0.103 | 0.154 | (0.176, 0.675) | 46 % | 66 % | 90 % | 46 % |
| mixed.random.11 | 1:1 | 0.111 | 0.166 | (0.215, 0.684) | 0 % | 49 % | 81 % | 0 % |
| mixed.random.21 | 3:2 | 0.198 | 0.198 | (0.254, 0.601) | 21 % | 28 % | 66 % | 21 % |
| mixed.random.26 | 4:3 | 0.245 | 0.276 | (0.186, 0.606) | 37 % | 62 % | 76 % | 37 % |
| mixed.random.27 | 4:3 | 0.247 | 0.278 | (0.321, 0.767) | 44 % | 24 % | 0 % | 44 % |
| **Σ J · mean f** | | | | | **1.06 · 29 %** | 1.06 · 44 % | 1.06 · 66 % | **0.55 · 22 %** |
| mean `L` | | | | | 42 % | 53 % | 70 % | 36 % |

The median path sits on the left where the nine are; the outlier alone pays
95 % and goes; the nine never felt it. A mean path drags everyone right
(18–66 %). The outlier kept as a key is worst: sorted first, it *is* the
start key, the path opens on the right and crosses to the left, and eight of
the nine pay 66–90 %. After the reject `Σ J` falls 1.06 → 0.55 — the jump
was the outlier's. Three of the nine still read red on their own account
(10, 26, 27: faces at x 0.18 or y 0.77 against a path at 0.24 / 0.61) —
whether 30 % is the line and whether a second pass takes them is Q1. The
four squares show why `L` must sit beside `f`: 11 reads 0 % and green, and a
third of it is gone to the aspect. And on the clean approach a plain running
median charges the first and last photo 8 % and 13 %, because the window
shortens at the ends and the drift stops: the default end key wants the
trend continued, not the median held (Q2).

## 5. The interactions to prototype

Each: goal · controls · what changes · expected output · must answer.
Desktop-first at the Mac sheet's size (560 × 680 pt — the board may need the
sheet to grow; say what it needs), a 393 pt phone pass after.

### a. Shortlist — tags, shape family, aspect, a coarse position filter

- **Goal**: narrow hundreds to the photos that could belong in one sequence.
- **Controls**: the shipped tag rows and search; the family rows (the kit is
  all rectangles; fake a circle family from `single.*` if wanted); an
  **aspect** filter (landscape · portrait · square · all — the minority
  orientation pays cover-fit crop on every photo); and the **3×3 grid as a
  filter for the eye only** — tap a column or cell to keep the photos whose
  face *centre* lies in it. The grid never classifies (the kit's ≥ 95 % rule
  calls 80 of 100 `mixed`); the model works from `c_i` and the margins.
- **What changes**: the count line and a contact sheet of the survivors,
  each with its face box and, faintly, its cover-fit window in the set's
  aspect.
- **Expected output**: the shortlist that feeds b.
- **Must answer**: whether the grid earns its place beside the board (Q5 —
  on the mixed 40 the columns take 12 · 21 · 7); its naming (Q7); the sheet
  when a filter empties the set.

### b. Sort — by the shape's size, by alignment, by hand

- **Goal**: the order the photos play in.
- **Controls**: Smallest first · Largest first (the shape's rendered share
  `σ` — §1's small → large; the shipped sort keys on the native `s`, which
  inverts ten neighbours on the mixed 40 — a departure for §7.5) · Capture
  order · **Alignment** (§4) · a **same-angle**
  tie-break (group by `tram`); drag to reorder; tap to exclude.
- **What changes**: rows re-order with the share line ("1 350 px · 45 % of
  the frame"), the natural position and the board's crop-risk badge, so list
  and board agree; excluded rows stay, greyed.
- **Expected output**: an ordered member list with excludes.
- **Must answer**: does Alignment beat Smallest-first on the mixed 40 (`Σ J`
  7.51 → 5.09 at *K* = 3, angle changes 29 → 28 — is the coherence worth the
  size wobble; Q6); drag or move up/down.

### c. The Sequence Board — the centre of the prototype

- **Goal**: see every photo as it will render, before anything renders.
- **Controls**: the rect's aspect and size; **Least crop / Fixed face**; the
  auto-reject toggle; the keys (e); thumbnail size.
- **What it shows**: every shortlisted photo in the sorted order, rendered
  **as it will render** — cover fit, shift, zoom — with the face box and a
  crop-risk badge (green · amber · red; rejected ones greyed, or removed when
  auto-reject is on). Hovering a thumbnail draws the **output window over the
  source photo**: what is lost, with `L` as the number. Beside it, two small
  charts over the index: **face share** (the size curve on `σ` — must be
  monotonic; a reorder that breaks it shows here) and **face position** with
  the path `P` over the `p_i` and the keys as handles. `Σ J`, mean crop risk
  and mean loss in the corner. All of it updates live with keys, rejects,
  sort and aspect.
- **Expected output**: a board the person trusts; the render follows it
  exactly.
- **Must answer**: the board at 100 photos (Q8); whether people read the
  position chart or only the badges; whether hover-over-source is the moment
  cropping is understood.

### d. Crop risk and auto-reject

- **Goal**: the high-risk photos out before rendering — the bad apple.
- **Controls**: the two thresholds (exposed in the prototype, probably not
  in the app); the auto-reject toggle; per-photo reject / keep anyway; undo.
- **What changes**: a reject recomputes the path and every `f`; board and
  charts re-flow; the count line says "3 rejected · mean crop 12 %". A
  rejected photo stays reachable (greyed in the list; "show rejected" on the
  board) and can be kept anyway — it then simply pays its crop.
- **Expected output**: the reject list, saved with the collection.
- **Must answer**: the thresholds, on `f` or on `z`, one pass or to a
  fixpoint (Q1); what the user sees when the reject takes a photo they
  wanted; whether "keep anyway" needs to exist.

### e. Keys — start, end, and any middle index

- **Goal**: set the framing at a few photos; have it transition nicely.
- **Controls**: start and end always; "add key here" on any thumbnail; at a
  key, the face's place `P` (a drag on the rendered thumbnail or on the
  chart's handle; the nine-point picker as the coarse alternative) and,
  optionally, a **zoom beyond cover fit** — a deliberate tighter crop that
  raises that photo's `f` knowingly; the ease (linear · in-out); remove key.
- **What changes**: the path chart bends through the handle; between keys
  the path interpolates instead of following the median; every `f` between
  the neighbouring keys recomputes and the badges follow.
- **Expected output**: the keys and the ease.
- **Must answer**: whether a middle key is reached for at all on the three
  sets, or the median path plus rejects is enough, and what the end keys
  default to (Q2); place and size as one drag or two, and whether
  zoom-at-key is wanted (Q3).

### f. Fixed face — the shipped option

- **Goal**: the special case where the face size is *imposed* — every face
  at a chosen size and place, the scene be damned: a square post with the
  tram dead centre at 40 %.
- **Controls**: the shipped Output-frame keys (place and size at first and
  last). Under this option the badges are the shipped verdicts (`fits` ·
  `short` · `upscaled` · `shortAndUpscaled`), and the ×2 rule applies —
  double the manifest's
  `width`, `height` and `bbox` before `output-frame.md` §2's math, or the
  upscale verdict fires at half the size it should.
- **Must answer**: where it lives (Q9); whether anyone chooses it once Least
  crop exists.

### g. Duration and speed ramps

- **Goal**: pace — an approach that accelerates, a hold on the best frame.
- **Controls**: the shipped Timing card; a **per-photo override** on a row or
  a thumbnail ("hold this one 2 s").
- **What changes**: the estimate line ("12 photos · 12.6 s · 314 frames"); if
  the board is a strip, a held photo is wider.
- **Must answer**: where the override lives; whether the ramp and an override
  compose or the override wins.

### h. The Collection — the durable asset

- **Goal**: keep the work; render it again differently later.
- **What is saved**: the members (a snapshot of each shape, so a later
  re-analysis cannot move it), the order and rejects, the keys and ease, the
  option and the rect, the holds and fps, the filters that made the
  shortlist.
- **Controls**: Save as collection; open; **Re-render** at another fps,
  ramp, aspect or framing without touching the members. Today a Shape-mation
  enters Collections only as its clip; the brief wants the stills as
  members.
- **Must answer**: a Collection with a shape badge, or its own list (the
  shipped `shapemation.list`); what a re-render keeps and asks again.

### i. Shape inventory with pose — STRETCH

A library-level outline ("tram face") added in one action and adjusted —
scale, tilt, yaw — so a shape records pose, not just bounds; the kit's
`data-shape` polygon and `tram.left/right/high/low` objects give truth for
the poses. Must answer: one gesture or two; can a person tell yaw from tilt
on a handle; is pose worth its handles when the angle-strobe is solved by
*grouping* (b). Last, and only if a–h are settled.

## 6. The questions the prototype must settle

| # | Question | Options | What settles it |
|---|---|---|---|
| 1 | Smoothing window and the two thresholds | window 3 · 5 · 7; flag/reject 15/30 % on `f` · on `z` (1.1/1.2); one pass · to a fixpoint | the bad-apple set (the outlier must go, the nine must stay), the mixed left column, the portrait 30: what each rule rejects and whether the survivors read as one sequence |
| 2 | Median path vs keys; the ends | median only, keys the exception · start/end keys always shown as handles · the ends continue the trend (a robust local line) rather than hold the median | the clean approach (ends at 8 / 13 % under a plain median must fall to ~0); whether anyone adds a middle key on the three sets unprompted |
| 3 | Setting a key: place, size, zoom-at-key | drag on the thumbnail · on the chart handle · the nine-point picker; a zoom beyond cover fit at a key: yes · no | speed and error on "start the tram lower-left, end it centred", desktop and phone; whether zoom-at-key is reached for or only breaks the least-crop promise |
| 4 | The aspect for a mixed library | the dominant aspect · the user's choice with the minority orientation flagged · one sequence per orientation | the portrait 30 into 2:3 (6 of 30 rejected, mean `f` 16 %, aspect loss 0 %, mean `L` 16 %) vs 16:9 (5, 14 % — and 62.5 % of every photo gone to the aspect first, mean `L` 68 %); Q10's trams; the default the prototype proposes |
| 5 | Does the 3×3 filter earn its place | a column/cell filter for the eye · nothing — the board and the position chart replace it · a position histogram | whether people reach for it before the board; whether the left-column shortlist (12 → 9 kept, 14 %) is found faster with it |
| 6 | Alignment sort | replaces Smallest-first · a tie-break under it · a separate option; *K* = 2 · 3 · 5 | `Σ J` and angle changes on the mixed 40 per option; whether the size wobble shows in the size chart |
| 7 | Naming | *crop risk* · *fit* · *cut*; the grid's word — *column* · *cell* · *position* | which words people use unprompted after the demo |
| 8 | The board at 100 photos | a grid of thumbnails · a strip with the charts as the scrub · the list *is* the board (rows beside a preview) | where people go to reject a photo; whether a flag is noticed without the board |
| 9 | Fixed face's place | a mode card beside Stack and Crop (shipped) · an option on the board · dropped | whether anyone picks it once Least crop exists, and for what |
| 10 | The default for a real library | Steven's trams: 85 rectangles, 83 portrait 3024×4032, share 0.094 / 0.284 / 0.709, centre x 0.39 / 0.54 / 0.86, 82 of 85 in the centre column — into 16:9 a portrait source loses both sides from a ~9 % face (the 16:9 trap) | the rectangle and thresholds the prototype proposes for a portrait library (4:5? 9:16? 16:9 with a smaller face?) and its rejected count |

## 7. Deliverables and sign-off

1. **The prototype**: one folder under `docs/shapemation/prototype/` that
   runs from the repo with no build step — `index.html` plus JS/CSS, reading
   `../../design/kit/compositions/manifest.json` and the SVGs by relative
   path (or a copied subset if a build is unavoidable; say so).
2. **A states list**: every screen and every state it can be in (empty,
   filtered-to-zero, all-green, some-flagged, rejected, a key being dragged,
   re-render), one line each, with how to reach it.
3. **A decisions log**: §6 answered in writing with the evidence the
   prototype produced — and, in every case, **the board's two numbers**,
   `Σ J` and mean crop risk, with the mean loss `L` beside them, on the mixed
   40 (and its left column), the bad-apple set and the portrait 30, **with
   and without auto-reject**.
4. **A short screen recording** (2–4 min): the bad-apple set from shortlist
   to a rejected outlier, two keys, and a clip.
5. **Where it departs** from §2's shipped semantics — one list.

Sign-off is Steven's, on the prototype and the log together. **Hand-off to
the developer agent**: the interaction spec (§5 as revised by the log), the
states list and the decisions — the developer reads those, then re-draws the
SVG mirrors (`docs/design/README.md`'s contract) and implements. The
prototype's code is not carried over.

## 8. Constraints

- **Disposable**: plain HTML/JS/CSS, any small library you like, no
  framework the developer must learn; nothing in it is reused.
- **No detection**: the kit's numbers are the truth — bbox, margins, cells
  from the manifest; the prototype never finds a shape in an image.
- **Truthful math** (§4): the formulas written once and used for the list,
  the board, the charts and the render; a badge the prototype shows is the
  one the app will show.
- **LetsLapse tokens** so it reads as the app (`docs/design/README.md`,
  "Design tokens"): accent `#C36A00`, deep accent `#8A4A00`, amber `#FFB340`
  for selected chips and flags over dark, ink `#1C1C1E`, screen `#F2F2F7`,
  card `#FFFFFF` radius 18, control track `#E9E9EB`, secondary text
  `#6D6D72`, confirm green `#34C759`, record red `#FF3B30`, system font.
  Light mode; black behind previews.
- **Desktop-first** at the Mac sheet's size (560 × 680 pt), then a
  393-pt-wide pass so the phone form is at least visible for Q3 and Q8.
- **Parked from the original brief** (not in the prototype): the synthetic
  generator and perturbation sweeps (`brief.md` §8 — done,
  `tools/shapesynth`); `.lapse` packaging (§8 Phase 1 — done); the build
  order (§9 — a code concern); subject-angle *matching* and the camera-mode
  overlay (§10); perspective correction (§10); the pose model's storage (§2's
  inventory format — a code concern, `gap-map.md` Q15); anchoring to a grid
  cell (§6, §11 — superseded by the path: the face's own centre is the
  anchor, the grid only shortlists).

Related, for reference: [`brief.md`](brief.md) · [`gap-map.md`](gap-map.md)
· [`output-frame.md`](output-frame.md) · [`output-frame-report.md`](output-frame-report.md)
· [`mixed-scenes-report.md`](mixed-scenes-report.md) · [`synthetic-corpus.md`](synthetic-corpus.md)
· [`../design/kit/README.md`](../design/kit/README.md) · [`../design/README.md`](../design/README.md)
· the mirrors `docs/design/iOS/shapemation*.svg` and `docs/design/macOS/shapemation*.svg`
and their rows in [`../design/iOS/INDEX.md`](../design/iOS/INDEX.md) and
[`../design/macOS/INDEX.md`](../design/macOS/INDEX.md).
