# Light Ladder — a fourth Interval MODE

**Raised:** 2026-09-03 (Steven — Claude Design handoff *"Light Ladder interval
profile"*, Turn 2, iOS-first designer concept at 393×852 pt) ·
**Status: built 2026-09-03 through §10 step 7 (Kit model + 21 tests, store,
card ramp, engine hook, capture screen, list/editor/rung screens, hooks);
uncommitted. Owed: the §7 SVGs and INDEX rows, the `remote_probe` verbs, the
§9 bench run, one real dusk, sign-off. Every decision in §11 was taken
2026-09-03 by recommendation and approved by Steven ("go with all of it").**

> **Found while building (2026-09-03), and now in the model:** a rung's
> stated shutter cap is not what the servo can get once blend depth is above
> 1. Frames are captured in sequence on both pipelines (a bracket's
> exposures back to back; the video tap streaming at depth ÷ interval), so
> five frames cannot each take a second inside a two-second window whatever
> the cap says. `Rung.effectiveShutterCeiling(within:)` = min(cap, hardware,
> (interval − 0.3 s) ÷ blend) is the box the servo is handed, the rung
> screen's Shutter subtitle states it ("0.57 s at this pacing"), and a grey
> *note* at the foot says why. On the built-in this changes nothing the
> servo would actually do — at every boundary EV the settled exposure is far
> below the share — which is exactly what the Kit test
> `testBuiltInBoundariesCarryTheExposureStraightThrough` pins.

> **Sources.** The handoff bundle carries the Turn 2 design, the Turn 1
> design it supersedes (kept as *v1 (pre-brief)* — its numbers are wrong and
> it is not a spec) and the canvas runtime. The *written* brief the design
> cites (its §5.4 live scene-EV marker, its §6 naming question, the
> 2026-09-02 night-pacing decision) was **not** in the bundle and is not in
> this repo or in Downloads. Where this document states something the brief
> decided, it is **reconstructed from the design** and marked *(recon.)*.
> If the brief turns up, it goes beside this file and the reconstructed
> items get checked against it.

---

## 1. What it is

A fourth Interval **MODE** — Basic · Dynamic · Scanner · **Ladder** — in
which the shoot follows a user-authored table of **rungs** keyed on scene
brightness. Each rung fixes five levers: ISO, shutter, white balance,
interval, blend depth.

Vocabulary, used everywhere (code, copy, files):

| Word | Meaning |
|---|---|
| **Ladder** | the object — one table of rungs, read top-down. Dusk descends it, dawn climbs it; there is never a second table for the other direction. (The handoff's working name *Profile* is retired: it collides with `BlendProfileStore` / `blend-profiles.json`.) |
| **Rung** | one threshold plus five levers. Stores a **lower bound** only — the ladder is gap-free by construction and the last rung is "and darker". Ranges are shown, never stored. |
| **Scene EV** | the measured EV at ISO 100 — the same `smoothedEV` the Holy Grail engine already tracks. |

The thesis, and the one sentence that decides most of the design:

> The servo stays in charge. A rung is a **box of constraints** handed to
> the existing Holy Grail engine, so every exposure change is still walked
> at ≤ ⅓ stop per window with the field-tested deadband. **Interval and
> blend may step at a rung boundary; exposure never does.**

Users think in light states, not exposure maths — so rungs are **named**
(Daylight / Fading / Dusk / Night) and the EV threshold appears in a reveal
(tap a rung), with an "Always visible" setting for the EV-forward reading
*(recon. — the design's §6 answer)*.

## 2. The built-in ladder — "Bright & Fast, Dark & Slow"

Always present, cloneable, never editable in place, fixed UUID, never
written to file (precedent: `App/PresetState.swift`'s built-in presets).

| Rung | Scene EV ≥ | ISO | Shutter | WB | Every | Blend |
|---|---|---|---|---|---|---|
| Daylight | 13 | min | auto | auto | 3 s | 10 |
| Fading | 8 | min | auto ≤ 1 s | auto | 2 s | 5 |
| Dusk | 4 | auto | auto ≤ 1 s | auto | 2 s | 3 |
| Night | and darker | auto | **auto ≤ 1 s** | auto | 2 s | off |

Each boundary moves one exposure lever and no more: 13 → 8 changes only
pacing, 8 → 4 releases ISO, 4 → night drops blend. Night is honest about
its look — 1 s exposures at 50 % duty with no stacking, motion trails, a
visibly different texture from stacked daylight.

**One change from the handoff (decision D1).** The design pinned Night's
shutter at exactly 1 s. On the wide camera (f/1.78, ISO floor 54 in the
design's own example) a 1 s exposure is *correct* at about EV 2.5; at the
rung's EV 4 threshold it needs ISO 20, so the frames would run ~1.4 stops
over until the scene lost another stop and a half. The engine's
shutter-first policy (`HolyGrailRampEngine.split`) already spends everything
on the shutter and lands on 1 s as soon as it is dark enough, so the pin
bought nothing and broke the "one lever per boundary" claim at that
boundary. Night is therefore **auto ≤ 1 s**, and its real change is "blend
off". The editor's feasibility line flags any pin that needs ISO below the
lens floor at the rung's threshold (§3.3).

Night pacing is 2 s *(recon. — the 2026-09-02 decision the design cites)*;
the "Bright & Fast (copy)" row drawn in the list is a user clone with 3 s
night pacing, not a change to the built-in.

## 3. The model — `LetsLapseKit`

Pure value types, validation and rung selection live in the Kit with their
tests (`Kit/Tests/LetsLapseKitTests/LightLadderTests.swift`); the app owns
the store, the engine hook and the UI.

### 3.1 Types

```swift
public struct LightLadder: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var rungs: [Rung]            // brightest first; sorted by lowerBoundEV desc
    public var isBuiltIn: Bool          // never persisted true; the built-in is a static
    public var clonedFromID: UUID?      // "cloned from the built-in" subtitle
}

public struct Rung: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String             // user-editable; HUD truncates at ~90 pt
    public var lowerBoundEV: Double?    // nil = the last rung, "and darker"
    public var iso: ISOChoice           // .min | .max | .auto | .value(Float)
    public var shutter: ShutterChoice   // .auto | .autoCapped(seconds) | .value(seconds)
    public var whiteBalance: WBChoice   // .auto | .locked   (Kelvin deliberately absent in v1)
    public var intervalSeconds: Double  // never Auto — EVERY = Auto is unavailable in Ladder mode
    public var blendFrames: Int         // 1 = "off"
}
```

**Symbolic ISO** is what makes a ladder portable: stored as min / max /
auto / value and resolved at arm time from the active lens's format
(`activeFormat.minISO … maxISO`). The rung screen's subtitle names the
device and lens it resolved on ("Auto · 54–3072 on Wide"). Pinning both ISO
and shutter is allowed and means a manual lock; anything left unpinned
belongs to the servo.

### 3.2 Invariants (validated in Kit, corrected **visibly**, never silently)

1. **Shutter ≤ interval − 0.3 s** — the same `holyGrailSettleSeconds` the
   engine's per-window limits already subtract.
2. **Blend ≤ what the interval can hold.** The rung stores the *ask*; the
   device ceiling is applied once, at actuation, exactly as the three blend
   strategies already do (they return uncapped counts; `ProcessingCeiling`
   and the capability ceiling clamp at the actuator). The light panel states
   the clamp at arm — "blend 10 → 6 in RAW on this camera" — so a JPEG-shaped
   built-in is never silently wrong on the DNG path (decision D4).
3. **EVERY = Auto unavailable.** A rung's interval is a number.
4. **Thresholds strictly descending**, last rung unbounded. The editor keeps
   this by construction (a moved threshold resizes its neighbour); the Kit
   normaliser sorts and de-duplicates on load so a hand-edited file can't
   break selection.

### 3.3 Feasibility and adjacency messages (the foot of the rung screen)

Computed by the Kit from the rung, its neighbours and the resolved limits.
Three kinds, in this order; each is a sentence, never a lock:

- **Fits** (green): "Shutter 1 s and blend 3 both fit a 2 s interval —
  0.3 s settle margin kept, ceiling 7 frames."
- **Pin below the floor** (amber, *new — D1*): "A 1 s shutter at EV 4 needs
  ISO 20, below this lens's 54 — frames run 1.4 stops over until EV 2.5."
- **Adjacency** (amber): "Night pins the shutter 2.3 stops below where Dusk
  leaves it. The servo will walk that over about 7 windows — the frames in
  between are neither look." The boundary card in the editor prints what a
  *clean* boundary does ("changes pacing only") and escalates to this only
  when the one-lever rule is actually broken.

### 3.4 Rung selection

Follows the Zone band pattern in `BlendStrategies.swift` (`ZoneBlendStrategy.
band(forEV:)`, first band whose lower bound the EV clears wins) with two
additions:

- **Smoothing:** the 3-window rolling average Zone already uses
  (`smoothingWindow = 3`), fed from the engine's smoothed scene EV.
- **Switching band:** a rung holds until the smoothed EV passes its threshold
  by **±0.5 EV** (D5 — a Kit constant `LightLadderSelector.switchingBandEV`
  in v1, drawn as a read-only Boundaries row; no field evidence yet for the
  number, so it is tuned on the bench, not per ladder). Zone has no
  hysteresis today; the servo's own deadband is 0.12 stops and is a
  different loop.
- **Never mid-window:** a change lands between frames. **No reading → the
  last rung holds.** First window with no history → the rung the live
  preview's EV selects (the engine already seeds from the preview's AE).

`LightLadderSelector` is a `struct` with `mutating func resolve(ev: Double?)
-> Rung` plus `lastRung`, `lastSmoothedEV`, mirroring `ZoneBlendStrategy`
so the field-test log layer can record it the same way.

## 4. The engine hook — `CameraController`

Per window, in `advanceHolyGrailRamp`'s neighbourhood (sessionQueue):

1. `selector.resolve(ev: engine.smoothedEV)` → the rung for the next window.
2. **Exposure box:** `holyGrailHardwareLimits(for:interval:)` takes the rung's
   box — ISO min/max from `ISOChoice` (a `.value` is min == max), shutter
   ceiling from `ShutterChoice` (`.autoCapped(s)` lowers `maxShutter`;
   `.value(s)` sets min == max), all re-clamped to the live `activeFormat`
   (the iPad bracket trap: an out-of-range manual bracket raises an
   uncatchable NSException, so the clamp is not optional). `split(gain:
   limits:)` solves inside the box; it already clamps both axes, so pins
   need no engine change. **Verified 2026-09-03 by reading, not assumed.**
3. **Pacing steps at the boundary:** on a rung change, the interval goes
   through the same path EVERY=Auto re-pacing uses
   (`repaceHolyGrailAutoInterval` → `setIntervalSeconds` on the live blend
   controllers) and the depth through the per-window depth resolution the
   Auto strategies use. Both land between frames.
4. **Governor precedence (D2):** a rung is a ceiling for pacing as well as
   depth. Order of yield is the shipped AIMD order — depth down to the
   2-frame floor first, then `ProcessingCeiling.sustainableIntervalSeconds`
   stretches the interval. **A rung's EVERY can only ever be lengthened by
   the governor, never shortened.** The HUD names whichever yielded:
   `blend 3 → 2, thermal` or `every 2 s → 4 s, processing` — "thermal"
   when the device is at serious/critical as the window opens, "processing"
   otherwise. *As built:* `ProcessingCeiling.maximum` became a `var` — the
   rung's ask sets it each window (`LiveBlendRawController.
   setProcessingCeilingMaximum`); raised, it is trusted until a window
   overruns, exactly as at start; lowered, it clamps. `LightLadderPacing.
   apply(rung:ceiling:)` is the pure helper, tested. The JPEG path has no
   governor and runs the rung as asked; both controllers gained
   `setFrameTarget(_:)` beside `setIntervalSeconds(_:)`.
5. **White balance (D3):** `.auto` = the existing *tracked* behaviour
   (JPEG path: slew-limited EMA gains via `applyHolyGrailTrackedWhiteBalance`;
   DNG path: locked at arm). `.locked` = frozen at arm on both paths.
   Neither is continuous AWB — no Holy Grail run has ever used it, and a
   rung must not reintroduce WB flicker.
6. **The ±EV bias** (`holyGrailBias`) is 0 and its slider absent in Ladder
   mode: a rung states the exposure box, so the ramp variant of
   `exposurePanel` does not apply (design 2a).
7. **Logging (as built):** one NDJSON file per run, `Logs/ladder-<ISO
   start>.jsonl` beside the experiment logs the bench already pulls —
   a header line (ladder, rungs, opening rung, pipeline) then one line per
   window: `window, at, sceneEV, rung, name, everyAsked, everyApplied,
   blendAsked, blendApplied, yieldedBy, changed` (`LadderWindowWriter`,
   `App/LightLadderRun.swift`). Plus `LLog` lines on arm, every rung change
   and every governor yield. `capture_log.json` is untouched in v1.

### 4.1 First device run, 2026-09-03 (16 Pro, 4K JPEG at a 25 fps stream)

Steven's dusk-and-back test (bright sky → dark room → bright sky, 8 min
13 s, 210 windows) — the ladder itself behaved: every rung delivered its
full ask on the way down (10/10 · 5/5 · 3/3 · 1/1), the rungs switched at
EV 12.3 · 7.3 · 3.3 down and 4.5 · 8.5 · 13.7 up, the governor never
yielded, and processing stayed at ~100 ms a window throughout. **The climb
starved anyway**: Dusk got 1 of 3, Fading 2 of 5, Daylight 3 of 10, frames
arriving exactly 1.00 s apart. Cause: the camera went to *serious* pressure
a minute into Night, and the existing serious-pressure floor
(`applyPressureFloorToStream`, need × 1.5, clamped to the format's 1 fps
minimum) was derived from Night's need of 0.5 fps. The floor lifts only at
nominal by design (fair flaps), and the ladder's rung-change re-throttle
updated the *need* but — under the Auto stream policy, which sets no rate
until it has learned to — never re-applied the floor. A plain Dynamic run
at 3 s/10 would have had a 5 fps floor and kept 10/10.

**Fixed 2026-09-03:** `advanceLadder` re-applies the floor from the new
rung's need whenever the pressure level is serious or critical, logged as
`ladder: pressure floor re-derived for <rung> — N fps`. Under serious the
built-in now streams at Dusk 2.25 · Fading 3.75 · Daylight 5 fps, all above
their grids. Retest owed.

Also seen: the 4K/25 fps stream is what heated the phone (serious at 3.6
min; the Sep 1 run at 12 MP/10 fps stayed at *fair* for 15 min), and under
Auto the stream ran unthrottled at 25 fps through Night, whose need is
0.5 fps — a rung states its depth outright, so a ladder run could throttle
to the rung's need (× the 2× start headroom) at every change instead of
waiting for Auto to learn. Not done; a decision for Steven (§12).

## 5. The store — `App/LightLadderStore.swift`

`light_ladders.json` beside `custom_presets.json` under `StorageRoot.current`
— atomic write, decode-tolerant load, the `CustomPresetStore` shape. The
built-in has a fixed UUID and is never written. **Add the file name to
`StorageLocation.libraryItemNames`** (`App/StorageLocation.swift:38`) or the
Mac storage relocation will leave ladders behind — the same trap the
2026-08 storage-location work documented.

`RecordingSettingsStore` remembers the selected ladder id (falls back to
the built-in when the id no longer resolves). Scheduled shoots need no
extra work: standby arms whatever is selected.

## 6. The UI

All screens are plain SwiftUI lists and overlays — that is what makes
iPhone + iPad one build (D8). macOS hides Ladder from the MODE menu in v1
(the model and store are universal; the screens follow once drawn).

### 6.1 Capture — Interval, Ladder armed (design 2a)

- **The row is two dials:** MODE, then the ladder chip immediately to its
  right, *unlabelled* — it reads as MODE's object, not a dial of its own (the
  one exception to `DialCaption`). `IntervalCaptureMode.ladder` gets
  `ownsInterval == true` (hides EVERY, as Scanner does) and a new
  `ownsBlend` that hides BLEND. The ±EV band is simply empty.
- **The light panel** (new, an overlay on the viewfinder, not part of the
  control stack): rung swatch + name, "scene EV 5.2", the rung's levers in a
  mono line, what it costs ("≈1,800 frames an hour · motion softened by
  3-frame stacking"), and which rung comes next ("Night is next, below EV 4
  — 1 s exposures, no stacking"). Closable; collapses to a **rung pill** that
  taps back open, so the shoot never stops naming its state. Any
  actuation clamp (§3.2) is stated here at arm.
- **Persistence (D10):** open by default when Ladder is armed; once closed,
  remembered for the app launch; re-opens on a rung change *while armed*.
  While running the toast and readout carry it, not the panel.
- **The picker** (design 2a, right): a sheet — title "Ladder", "Manage"
  trailing; built-in first with ✓ on the selected; each row = swatch, name,
  "Built in · 4 rungs · EV 13 · 8 · 4 · darker". Picking arms; managing is
  the deliberate second tap. The sheet never edits. *As built:* a medium-
  detent sheet on both iPhone and iPad (the chip lives inside the
  `Equatable` dial row, which a popover anchor would have to reach through;
  the form sheet iPad presents is the same content). Not a deviation worth
  a screen; noted so the iPad INDEX row says so.

### 6.2 Capture — running (design 2f)

The Holy Grail readout keeps its geometry (63 pt); the ladder adds:

- **The rail** — over the viewfinder like the Scanner overlay, right edge:
  four bars, heights proportional to EV span, the active one widened to
  22 pt and ringed in `LL.amber`, its name in an amber chip beside it.
- **A toast** on the change — "Stepped down to Dusk" — with a four-line
  glyph, the active line amber.
- **The third readout line** reuses the slot that holds "shutter at max ·
  ISO ramping": `Dusk · every 2 s · blend 3 → 2, thermal`. When both apply
  the amber warning wins — a pinned shutter is the more urgent fact.

### 6.3 Interval ladders (design 2b) — `App/LightLaddersView.swift`

Reached from the ladder chip's "Manage" and from a new row in
`CreateView.sourceRows`. Sections: BUILT IN (one pinned card, BUILT IN
badge, open to read or duplicate — Duplicate-only), YOUR LADDERS (rows with
✓ on the selected), "+ New ladder", and the footer "Ladders are portable…".
The **swatch** is generated from the ladder's own rungs, brightest first,
from four `LL` tokens: amber, accent, accentDeep, ink — so Sunrise reads as
Sunset inverted with no extra copy.

### 6.4 The editor (design 2c-ii, **ribbon + list** — D6)

Header: name (editable), "cloned from the built-in", Done. Then the
**ribbon** — the whole ladder in 60 pt, one band per rung at its EV span,
the selected band ringed, EV ticks beneath (16 · 13 · 8 · 4 · −2); drag a
divider to move a threshold, tap a band to open its rung. Then RUNGS ·
BRIGHTEST FIRST (name-forward rows; the threshold `≥ 13` appears on tap, or
always with the EV setting), "+ Add a rung", and BOUNDARIES: *Switching
band ±0.5* (read-only in v1) and *Never mid-window* (FIXED). The EV-axis
variant (2c-i) is not built: its drag-to-resize cards are a custom gesture
the ribbon's divider drag already covers.

### 6.5 The rung (design 2c, third frame) — `App/LightRungView.swift`

Three sections whose headers carry the thesis: **APPLIES AT** (Scene EV and
brighter, stepper, "Shown as EV 4 to 8 because Fading sits above it");
**EXPOSURE — HANDED TO THE SERVO** (ISO, Shutter, White balance rows with
their resolved subtitles); **PACING — STEPS AT THE BOUNDARY** (Every,
Blend steppers). The §3.3 messages at the foot.

### 6.6 Watch and remote (follow-up, not v1)

Read-only: ladder name plus active rung. `WatchMessageKey` gains a ladder id
and rung name; `IntervalCaptureMode.ladder`'s raw value `ladder` travels on
the existing `intervalMode` key (an older Watch decodes it to Basic via
`IntervalCaptureMode(token:)`, which is the safe fallback). Not drawn —
`Remote/RemoteTokens.swift` governs that surface. `remote_probe` gets
`setIntervalMode:ladder` and `setLadder:<id|name>` so the bench can arm it.

## 7. Design mirrors owed (design-sync contract)

Code-first from the handoff (the handoff **is** the spec), mirrored after
device sign-off. Files, all `docs/design/iOS/`:

| File | State |
|---|---|
| `capture-interval.ladder.portrait.svg` | armed, light panel open |
| `capture-interval.ladder-panel-closed.portrait.svg` | the rung pill |
| `capture-interval.ladder-picker.portrait.svg` | the sheet |
| `capture-interval.ladder-running.portrait.svg` | rail + toast + readout |
| `interval-ladders.portrait.svg` | the list |
| `interval-ladder.editor.portrait.svg` | ribbon + list |
| `interval-ladder.rung.portrait.svg` | the five levers |
| `create-home.portrait.svg` | gains the "Interval ladders" row (existing file) |

Plus INDEX rows, and `iPadOS/` rows only where the layout differs. Hooks,
in `README.md`'s hook list: `LL_LADDER=armed|closed|picker|running`
(implies Interval + Ladder; pair with `LL_CAPTURE=1`; stages the built-in
on Dusk at scene EV 5.2 — the simulator has no camera to meter — and
`running` freezes the 2f state: 41:08, 823 frames, blend 3 → 2, the toast
just fired). **Built.** The list, editor and rung screens are reached by
hand from the Create tab's row (`Interval ladders`) — an `LL_LADDERS` hook
is still owed for their screenshots.

### 7.1 Simulator verification, 2026-09-03

All four `LL_LADDER` states and the list, editor and rung screens were
screenshotted on the iPhone 16 Pro simulator (iOS 18.6) against the handoff:
the dial row (MODE · ladder chip), the light panel and its pill, the picker,
the running rail, toast and third readout line, the list, the ribbon editor
and the Dusk rung all read as drawn. Two things the phone taught the design:

- **The BUILT IN pill truncated the built-in's own name** ("Bright & Fast,
  Dar…") once it shared the trailing slot with the check and the chevron.
  The badge is now the subtitle's first word — "Built in · 4 rungs · …" —
  the form the picker sheet already used.
- **The editor's large title truncates** at 26 characters; the editor uses
  an inline title, and the name row under it carries the full text.

And one SwiftUI trap for the ribbon: a `ZStack` of offset bands has the
*natural width of its widest band*, and a centred `.frame(width:)` around it
shifts every band by half the difference (Daylight opened at EV 11, Night
fell off the right edge). The frame is `.topLeading`.

## 8. Kit tests (written with the model, before the engine hook)

- Codable round-trip; decode-tolerant load of an older/hand-edited file;
  normaliser sorts, de-duplicates, keeps exactly one unbounded last rung.
- `ISOChoice`/`ShutterChoice` → `HardwareLimits` for two formats (Wide
  54–3072, Tele 34–1600 say), pins as min == max, caps re-clamped.
- Selection: descends and climbs the built-in over a synthetic dusk/dawn EV
  trace; holds through ±0.49 EV noise at a boundary; switches past ±0.5
  after 3 windows; holds the last rung on nil readings; first window seeds
  from the preview EV.
- Invariants and messages: settle margin; the pin-below-floor number for
  the Night-pinned case (ISO 20 at EV 4, 1.4 stops); the adjacency stops and
  window count; the "changes pacing only" clean-boundary text.
- Governor precedence: a rung's interval is never shortened; depth yields
  before pacing; the HUD string for each.

## 9. Verification — the monitor test card is the ladder's bench

Design the run **before** writing the engine hook, so the acceptance test
exists first.

1. **Card script (built 2026-09-03 — the card had no ramp before this):**
   `tools/testcard/index.html?light=<script>` dims the whole card in stops
   below full on a script — `h<stops>x<s>` holds, `r<stops>x<s>` ramps, a
   trailing `loop` repeats — with the display gamma folded in so a stop is
   a stop, and contrast kept so the QRs and strip decode through the first
   few stops. `testcard_report.py report --light <script>` puts each
   frame's scripted level in the CSV as `light_stops`. The bench ramp:

   ```
   ?light=h0x90,r-3x180,h-3x120,r-6x180,h-6x120,r-9x180,h-9x120,r-6x180,h-6x120,r-3x180,h-3x120,r0x180,h0x90
   ```

   — 32 minutes, a 2-minute hold either side of each 3-stop step so the
   ±0.5 band and the 3-window smoothing are both exercised on the way down
   and the way up. **Two display limits decide the ladder under test:** a
   300-nit panel at full white meters around EV 11, so the built-in's
   Daylight threshold (13) is out of reach on an SDR monitor, and the
   panel's own dynamic range caps the walk at ~9 stops. So the first run
   reads the full-white scene EV off `ladder-*.jsonl`, and the bench ladder
   is a clone of the built-in with thresholds at (white − 1, white − 4,
   white − 7) — the selector logic is identical, only the numbers move.
2. **Arm** the 16 Pro over the remote bench (CLAUDE.md § remote bench):
   `setIntervalMode:ladder, setLadder:builtin, startRecording, …`. First at
   **blend depth 1 on every rung** (a cloned ladder with blend off
   throughout) — the isolation trick: depth 1 routes through `fireCapture`
   with plain settings, so if exposure tracks there and not at depth > 1 the
   bracket is the culprit. Then the real built-in.
3. **Pull** the experiment logs and `capture_log.json`
   (`devicectl device copy from …Logs`), and check:
   - rung changes land at the scripted thresholds, once each, between
     frames — no chatter (the 12 Pro limit-cycle report is the pattern to
     rule out);
   - exposure walks ≤ ⅓ stop per window across every boundary
     (`measuredEV − appliedEV` stays inside the deadband);
   - the interval and depth applied per window match the rung, or the log
     names the governor as the reason they don't;
   - `tools/flicker_report.py` on the exported clip: FLICKER PASS.
4. **Then one real dusk** on the 16 Pro before sign-off, JPEG path, WB
   tracked — and a DNG arm so the §3.2 clamp line is seen once for real.

## 10. Build order

1. Kit: types, normaliser, resolution, selector, messages — with §8 tests.
2. Store + `StorageLocation` allowlist + `RecordingSettingsStore` selection.
3. §9.1 card script, and the `remote_probe` verbs (§6.6).
4. Engine hook (§4) + logging; `IntervalCaptureMode.ladder`, `ownsBlend`,
   bias = 0 in Ladder mode.
5. Capture screen: dial row, picker, light panel + pill, running rail /
   toast / readout line.
6. Interval ladders list (+ Create row), editor, rung screen.
7. Hooks, simulator screenshots, the §7 SVGs and INDEX rows.
8. §9 bench run at depth 1, then the built-in; one real dusk; sign-off.

**Out of v1, deliberately:** WB as Kelvin (auto/locked only); the live
scene-EV marker in the editor *(recon. — held out on Steven's call, the
axis has room for it at the left of the rail)*; the Watch and Mac remote
screens; macOS list + editor (Ladder hidden from the Mac MODE menu); a
scheduled shoot carrying an explicit ladder id (not needed — §5).

## 11. Decisions log — 2026-09-03

Taken by recommendation after the review, approved together.

| # | Decision |
|---|---|
| D1 | Night's shutter is **auto ≤ 1 s**, not pinned; "blend off" is Night's change. The editor flags any pin that needs ISO below the lens floor at the rung's threshold. |
| D2 | A rung is a ceiling for pacing as well as depth. Shipped AIMD order of yield: depth to the 2-frame floor, then the interval stretches. EVERY is only ever lengthened. HUD names what yielded. |
| D3 | WB `auto` = the existing tracked behaviour (slew-limited gains on JPEG, locked at arm on DNG); `locked` = frozen at arm on both. No continuous AWB. Kelvin out of v1. |
| D4 | Blend stores the ask; the device ceiling applies at actuation as the strategies already do; the light panel states the clamp at arm. One built-in, not one per pipeline. |
| D5 | Switching band is a Kit constant, 0.5 EV, read-only row in v1. |
| D6 | Editor = ribbon header + list (2c-ii). The EV-axis variant is not built. |
| D7 | The name is **Ladder**; *Profile* retired (collides with blend profiles). |
| D8 | iPhone + iPad in v1, same list screens, picker as a popover on iPad. Ladder hidden from the Mac MODE menu until drawn. |
| D9 | This file is the job document; the brief's decisions are reconstructed and marked. |
| D10 | Light panel: open by default when armed, remembered per launch once closed, re-opens on a rung change while armed. Running uses the toast + readout line. |
| D11 | The monitor test card's brightness ramp is the acceptance bench; the run is designed before the engine hook is written. |
| D12 | Build order as §10; Kit model and tests first; card run at depth 1 before any depth above it. |

## 12. Still open

- **Throttle to the rung's need on the JPEG path regardless of Auto's
  learning?** Night at 0.5 fps need ran a 25 fps stream for a minute
  before pressure went serious (§4.1). The rung's depth is explicit, so the
  ladder could set need × 2 at every change, the way the Reduced policy
  does, and keep the phone cooler through the dark rungs.
- **The climb's EV overshoot** (smoothed EV reached 18.8 at the end of the
  2026-09-03 run against an opening 13.5): check against the exposure
  sidecar once its on-device path is confirmed (`capture_log.json` and
  `frames.timestamps` were not at `Projects/<id>/` or `…/source/`).

- The written brief itself (see the note at the top).
- Whether the panel's "re-opens on a rung change while armed" is right
  once seen on a device waiting for sunset — a judgement call, cheap to
  flip.
- The per-lens ISO floor used by the pin-below-floor message: the resolved
  `activeFormat.minISO` at edit time on the editing device, named in the
  subtitle; a ladder edited on an iPad and armed on an iPhone re-resolves at
  arm and the light panel says so.
