# Framing lock — post-capture stabilisation of interval shoots

**Status:** engine shipped 2026-09-03 (uncommitted) — see "Engine" at the
end; design files next, then the app UI. Decisions taken by Steven the same
day: engine first → design → UI; **lock everything** (one reference framing
for the whole shoot). Python audit tool: `tools/framing_lock_report.py`.

## The case

Project `E33ED216` — Charles Bridge from the bridge deck, iPhone 16 Pro
telephoto, DNG at 1 s, 5030 frames over 84 minutes, sunset into night,
speed 8 (each output frame averages 8 stills). Every time a tram crossed the
deck flexed under the tripod. No single frame looks wrong; end to end the
shot wobbles, and the clip that should be the hero reads as B-roll.

This is **not** the 12 Pro OIS park (`TODO.md` › "12 Pro OIS park at thermal
critical"): the capture log has zero issues, thermal peaked at *serious* and
never reached *critical*, the device is a 16 Pro, and the cause is the ground
moving under the tripod. Nothing at capture time can prevent it — so unlike
the OIS case, where the decision was to keep the phone out of critical rather
than reframe afterwards, this one can only be fixed after capture.

## What the pixels say (measured, whole shoot)

Method: half-size raw decode → log luma → Gaussian high-pass → Hanning-windowed
`cv2.phaseCorrelate`, each frame against the anchor of a 30-frame chunk,
chunks chained through the boundary pair. Cross-checked against direct
long-baseline measurements (≤ 0.7 px disagreement over 1000-frame baselines)
and, on the tram window, against ECC (Euclidean), ORB + RANSAC (partial
affine) and Vision's homographic registration.

| Finding | Value |
|---|---|
| Motion model | pure translation — rotation < 0.01°, scale 1.0000 ± 0.0003 (three independent estimators agree) |
| Bounce events > 2 px off the local baseline | **25**, 125 frames (2.5 % of the shoot) |
| Event peaks | median 3.1 px · p90 7.9 px · max 10.5 px (frames 864–910, 47 frames) |
| The tram Steven noticed (frames 802–820) | 803–807 sit 5.5–9.5 px BELOW the reference, 808 snaps back, ~1 px horizontal |
| Slow drift over the 84 min | 16 px vertical, 6 px horizontal (tripod settling / OIS wander) — separate from the bounces |
| Correlation confidence sunset → night | p5 0.83, median 0.88; the night section correlates *better* (0.91) |
| **Lock-everything crop** (one reference framing, drift removed) | x ±4.6 px, y ±11.4 px → **0.76 % of each edge**, keeps 4001×3001 of 4032×3024 |
| Bounce-only crop (drift left in) | x ±4.0 px, y ±8.2 px → 0.54 % |

Why it reads as compromised: at speed 8 a 7 px jump *inside* a window doubles
every edge in that output frame (the clock's hands and numerals ghost — the
simulated 803–810 stack shows it plainly, and the locked stack of the same
frames is crisp), and *between* windows the mean position steps by a few
pixels, which on a 120 mm-equivalent lens is a visible wobble. The
watch-as-motion viewer shows the raw bounce.

Night frames (from ~frame 3000, 0.7 s shutters): a bounce during the exposure
blurs rather than translates. Nothing to correct there; the measured path is
also quieter there (max 3.3 px after frame 2500).

## Where a correction slots in

The correction must move each **source** frame before it enters the
accumulator. A tail pass over the finished clip cannot un-ghost a window.
Both stills paths hand every frame in through one closure, so there is one
seam per path:

- **Linear path** (the default): `PhotoPreset.blendSupport` returns
  `decode: (URL) -> MTLTexture`; `ImageStacker.stackSequenceLinear` feeds it
  to `BlendWindowRenderer.render`'s texture provider → `FrameAccumulator`.
- **Gamma path**: `ImageStacker.stackSequence(loadFrame:)` takes a `CGImage`
  and uploads it.
- **Poster fast path**: `TimeSlicePoster` renders single windows through the
  same `BlendWindowRenderer`, so the same per-frame transform provider keeps a
  poster pixel-identical to the clip's frame — the invariant that path was
  extracted to protect.

The per-frame transform is the `FrameRotation` contract exactly: translate by
−(dx, dy) against the reference, crop to the fixed same-aspect inset, scale
back to the source size. Output geometry is unchanged, so overlays, masks,
canvas crops, reframe keys and the writer's buffer pool stay untouched, at
the price of one resample. Rotation and lock should compose into **one**
affine + crop so a levelled *and* locked shoot resamples once, not twice
(`FrameRotation.rotated` already builds a Core Image graph; the lock is a
translation folded into its `spin` transform plus a larger inset).

On the Metal path an integer-pixel lock is a blit with an offset source
origin (no kernel, no resample); sub-pixel needs a sampler kernel or the
Core Image Lanczos the rotation uses. An integer-only lock leaves ≤ 0.5 px of
residual — invisible at 4032 wide, and it keeps the raw pixels crisp. This is
a decision (below), not a given.

## Measuring on device

- **Vision.** `VNTranslationalImageRegistrationRequest` (iOS 11 / macOS
  10.13) returns an integer-pixel translation at the resolution it is given
  — verified on the Mac against OpenCV on the tram frames: identical shifts
  at 2 px granularity on half-size input, ~60 ms a pair. **Trap:**
  `regionOfInterest` is not honoured consistently on registration requests
  — with an ROI it returned garbage (frame 807 measured 0 where three other
  methods and the eye say 6.5 px); crop the `CIImage` instead.
  `VNHomographicImageRegistrationRequest` gives sub-pixel values (within 0.5
  px of phase correlation) and doubles as the no-rotation sanity check (its
  a/d terms sat within 3×10⁻⁴ of 1). `VNTrackTranslationalImageRegistrationRequest`
  (iOS 17 / macOS 14) is the stateful sequence form.
- **In the Kit already.** `FrameAlignmentGate` correlates row/column luma
  projections against a rolling anchor with parabolic sub-sample refinement
  — at stride 8 it is a coarse gate; at stride 1–2 it is a sub-pixel
  translation estimator for exactly this motion model, with no Vision
  dependency and the anchor-refresh / re-anchor logic already written.
- **Anchor chaining** every ~30 frames is what keeps the measurement
  confident from sunset to night; a single frame-0 anchor loses the scene
  once the light has changed (direct 1 → 5030 correlated at 0.22).
- **Cost.** One decode per frame — the same order as a blend pass.
  `CIRAWFilter.scaleFactor` (0.25–0.5, draft mode) makes the measurement pass
  cheap next to the blend. The minimum crop needs the *whole* path, so the
  measurement is its own pass, before the blend — and its result should be a
  sidecar next to `frames.timestamps` / `frames.exposure`:
  `frames.alignment`, one JSON line per frame (`frame`, `dx`, `dy`,
  `confidence`, plus the reference and the crop fraction in a header), so
  every re-blend, poster, time-slice, Ken Burns and watch-as-motion consumer
  reads it for free and a re-measure is never needed unless frames change.

## Product shape (proposal — for the design-first conversation)

- **Adjust (photos) › ··· drawer:** a *Lock framing* switch under "All
  frames → 1" and "Photos per frame". The estimate card carries the cost
  line: "Framing locked · crops 0.8 %", or "Measures framing first · ~2 min"
  before the first measurement. Off by default; the measurement runs on
  demand from this screen, never at capture (the thermal budget belongs to
  the shoot).
- **Processing:** a real "Measuring framing…" phase before "Blending", with
  its own checklist row (the tail passes' borrowed-`grading` gap in
  `letslapse-app-overview.md` §10 should not grow by one).
- **Project detail:** once measured, the sidecar is a fact about the shoot —
  worth a line in the interval project's meta ("25 framing bounces ·
  locked", or "framing steady") and a Field Notes issue when the peak
  exceeds a few pixels, the way the alignment gate reports `framingGlitch`.
- **Reference framing:** the centre of the excursion (minimum crop), not
  frame 0.
- **Cap:** refuse a lock that would crop more than a few percent and say so.
  A knocked tripod is a reframe, not a bounce — the gate's two-window
  re-anchor rule is the right instinct; the lock should hold the framing on
  either side of a real reframe rather than crop the whole shoot to bridge it.

## Decisions owed (Steven)

1. **Lock everything vs bounce-only.** Everything = one reference for the
   whole shoot, drift removed (0.76 % here). Bounce-only keeps the slow
   drift (0.54 %). Everything is what "100 % locked" means and the extra
   0.2 % is invisible; bounce-only exists in case a shoot's drift is large
   and *wanted* (a deliberate slow pan is not a case this feature serves).
2. **Sub-pixel resample vs integer copy.** Integer is cheaper, sharper and
   leaves ≤ 0.5 px; sub-pixel is what the rotation path already does.
3. **Where it is on by default** — never at capture; possibly remembered per
   project once switched on.
4. **Scope line:** translation only. Rotation/roll, zoom, rolling-shutter
   skew and motion blur inside long exposures are out, by the measurements
   above, until a shoot shows otherwise.

## Verification plan

- `lapse blend --lock-framing` (or the sidecar-driven default) over the
  `E33ED216` source at speed 8; compare output frame 100 (source 801–808)
  against the unlocked clip's frame 100 on the clock detail — ghosted vs
  crisp.
- Run `tools/framing_lock_report.py` on the frames of the **locked** clip
  (extract with ffmpeg, JPEG input is supported): residual path < 0.5 px,
  0 events.
- `tools/flicker_report.py` on the locked clip is unchanged from the
  unlocked one — the lock touches geometry only.
- The Kit test: a synthetic sequence with known integer and sub-pixel
  shifts, expect the measured path within 0.25 px and the crop fraction
  exact.

## Repro of the measurements

```bash
tools/.venv/bin/python tools/framing_lock_report.py \
  /Volumes/letslapse/Projects/E33ED216-900E-4C47-9426-84BC7961D15F \
  --band 0.12,0.75 --out /tmp/e33-framing.json --plot /tmp/e33-framing.png
```

(`--band` keeps the river and sky out of the correlation; the whole frame
agreed within 0.1 px on this scene, the band just correlated better.)

## Engine (shipped 2026-09-03, `ios-app` working tree)

Everything below lives in `LetsLapseKit` and the `lapse` CLI; nothing in the
app is wired yet.

| Piece | File | What it is |
|---|---|---|
| `PhaseCorrelator` | `Kit/…/PhaseCorrelation.swift` | vDSP 2-D FFT phase correlation on a `LumaPlane`: box high-pass, Hanning window, power-of-two zero padding; integer peak from the cross-power surface, sub-pixel by 2–5 Gauss–Newton steps of the translation-plus-gain least squares on the high-passed planes (a parabola or a 5×5 centroid through the phase-correlation delta locks toward whole pixels — measured 0.25 → 0.09 px and up to 0.75 px on smooth scenes; the spatial refinement tracks a synthetic path within 0.25 px). `response` is the 5×5 window sum, OpenCV's scale: identical 1, static scene a second apart ~0.85. |
| `FramingMeasurement` | `Kit/…/FramingMeasurement.swift` | 30-frame chunks in parallel workers (Mac: half the cores, max 8; iOS: 2), each frame against its chunk's anchor, anchors chained through the boundary pair. `FramingLumaDecoder`: `CIRAWFilter` at 0.5×, draft mode, luma → `log1p(4096·v)`; JPEG via ImageIO at the same scale. One Core Image context **per worker** — a shared one serialised eight workers to 191% CPU (8.7 min); pooled, 688% (7.0 min for 5030 DNGs on the M4 Max, ~0.08 s a frame). |
| `FramingReview` | `Kit/…/FramingReview.swift` | The record: per-photo offsets keyed by **bare file name**, events (> 2 px off a 121-photo running median, merged within 10), drift, verdict (`recommended` / `steady` / `inconclusive`), the headline copy, the `plan` (reference = centre of the excursion, insets, crop fraction, plan copy) and the committed `stabilisation` (copies the numbers + the review stamp, so a re-review reads as stale). `source/framing.json`, pretty, sorted keys, atomic write. |
| `FramingLock` | `Kit/…/FramingLock.swift` | The apply side: `offset(forName:)`, `cropRect(forName:in:)`, `levelled(_:name:degrees:)` and a `loader(base:)` wrapper for the CGImage stacking paths. Unmeasured photos get the shared crop and no shift. |
| `FrameRotation.levelled` | `Kit/…/FrameRotation.swift` | The general transform: content put back by the offset, spun by the angle, cropped by the rotation's inscribed rect shrunk by the lock inset (measured against the rotated crop so the margin survives the rotation's shrink), Lanczos back to the source size. `rotated(_:degrees:)` is now `levelled` with zero offset/inset — same graph, same pixels. |
| `lapse framing <dir> [--apply\|--withdraw\|--force\|--range A-B\|--json]` | `Kit/Sources/lapse/FramingCommand.swift` | Review, print, commit, withdraw. Greppable `FRAMING LOCK: N events · peak P px · crop C%`. |
| `lapse stack … --lock` | `main.swift` | Applies the committed lock to each still before averaging — the visual check. |
| Tests | `FramingLockTests` (14) | Sign convention, sub-pixel under gain + gradient, unrelated frames score low, a 70-photo synthetic shoot chained across chunks (path within 0.25 px, both knocks found, crop sized), JSON round trip + commit/stale/withdraw, crop rects inside every photo, `levelled` undoing a shift (mean |Δ| < 2.5/255 vs the reference), extents. Whole Kit suite: 456 tests, 0 failures. |

### Verified on E33ED216

| | Python audit (`framing_lock_report.py`) | Swift engine (`lapse framing`) |
|---|---|---|
| knocks | 25 | 24 |
| largest | 10.5 px at 864–910 | 10.2 px at 864–910 |
| the tram | 802–820 · 6.6 px | 802–820 · 6.7 px |
| lock-everything crop | 0.76 % | 0.70 % (4003×3002) |
| slow drift | 16.3 / 5.7 px | 13.0 / 6.0 px |
| confidence (median · p5) | 0.88 · 0.83 | 0.84 · 0.79 |

`lapse stack frame-00803…00810 --lock` renders the clock crisp where the
unlocked stack ghosts it (`cli_stack_compare.png` in the 2026-09-03 session).
The plan is **committed** on that project (`source/framing.json`,
stabilised 2026-09-03T14:19Z) — the app will pick it up as soon as it reads
the sidecar.

### Owed after the engine

- **Design files — drawn 2026-09-03, awaiting sign-off:**
  `iOS/project-detail.interval.portrait.svg` (Originals card: Review photos +
  Stabilise photos disabled) and `….interval.reviewed.portrait.svg` (the end
  state), `iOS/framing-review[.measuring].portrait.svg`,
  `macOS/framing-review[.measuring].svg` (560×640 window),
  `iOS/adjust.photos.advanced.portrait.svg`. Generated from one script
  (scratch `gen_framing_svgs.py`, 2026-09-03 session); both `INDEX.md`
  files carry the rows at 🟡 design-first.
- **App wiring — shipped 2026-09-03 (uncommitted), builds on macOS and
  iOS, not yet screenshot-verified against the SVGs:**
  `App/FramingReviewStore.swift` (per-project cache of the sidecar, the
  measurement run with whole-percent progress and a cancel flag, commit /
  withdraw), `App/FramingReviewView.swift` (the sheet on iOS, a fixed
  560×640 `WindowGroup(for: FramingReviewWindowRequest.self)` on macOS, the
  `FramingPathChart` Canvas), the two Originals rows in
  `ProjectDetailView.originalsSection` (`framingRows`), Adjust › Advanced's
  *Apply stabilisation* (`AppModel.applyStabilisation`, seeded from
  `AppModel.framingLock`, which `loadFramingLock` reads off the main actor
  when a stills project opens), and the lock applied in every stills render:
  `LinearFrameDecoder.decode(transform:)` (new Kit hook, the CI graph before
  the texture render) via `PhotoGrader.blendSupport(grade:lock:)`, and
  `PhotoGrader.stabilisedLoader` around `gradedFrameLoader` for the gamma
  path — in `blendPhotosSequence`, `stackPhotos` and the poster fast path.
  The blend summary gains "framing locked (0.7% crop)". One deviation from
  the SVG to mirror back: the Mac footer carries a **Review again** button.
- **Still owed downstream:** the photo viewer's single-frame render
  (`PhotoGrader.render` in `PhotoViewerView`), the Adjust/Guided source
  previews (`AdjustPreviewLevel.apply` takes only the image — it needs the
  frame name), and the watch-as-motion player; each is the same
  `FramingLock.levelled` call once the frame's name reaches it.
- **Files that travel:** `ProjectArchive.transferableSubfolders` moves the
  whole `source/` folder, so `framing.json` already rides `.lapse` exports
  and device transfers; the named-sidecar list at `AppModel` ~6486 is the
  *import-from-staging* path, where no review can exist yet — nothing to
  add.
- **iOS check:** `FramingLumaDecoder` on a phone (CIRAWFilter draft at 0.5×,
  two workers, memory) and the review's wall time for a 5000-photo shoot.
- **Copy:** a knock at photo 1 of a shoot reads as an event because the
  running median is edge-clamped; harmless, but the copy could skip a
  first-frame settle.
