# 2026-08-25 — The thermal bench: interval matrix, the OS veto, and the screen-dim A/B

Same-day follow-up to [2026-08-25-dawn-scheduled.md](2026-08-25-dawn-scheduled.md).
Question under test: how does interval choice affect a psycho (unthrottled)
Dynamic JPEG shoot's thermal survival — and, by evening, whether flooring the
display changes the answer. All arms: Interval · Dynamic · JPEG 4032×3024 ·
Capture Flat · psycho · 20 min · indoor bench facing a window, devices plugged,
driven hands-free by `shoot.py fleet --blend psycho` (grown today).

## The matrix

| Arm | Time | 12 Pro | 16 Pro | iPad Air M1 |
|---|---|---|---|---|
| A · 3 s | 15:38 | **VETO T+10.5** (hot start) | 400/400, critical @10.5, rode it | 400/400, serious-max |
| B · 5 s | 16:18 | **VETO T+11.8** (warm) | 240/240, never critical | 240/240 |
| C · 1 s | 16:59 | — (locked out) | 1199/1200, blends → 3–4, 3 late windows | 1200/1200, flawless |
| C′ · 1 s solo | 17:26 | **VETO T+16.4** (cold start) | — | — |
| E · 3 s **dim ON** | 18:04 | **COMPLETED 398/400** — critical @5.9, rode it 14 min | (left bench) | 400/400, blends 90→63–72 |
| F · 3 s dim OFF (control) | 18:49 / 19:15 | **VETO T+18.2** (nominal, matched rest) | — | 400/400, blends 90→54–61 |

Every 12 Pro veto is the same signature, captured live on the attached
console: `⏸️ Interrupted reason=5 (systemPressure)` → `DidStopRunning` →
`notAvailableInBackground`. The app is *healthy at every kill* — zero failed
windows before the interruption, flat ~875 MB footprint. iOS executes the
run; the app never gets to fail.

## Findings

**1 · Apple runs the real thermal governor.** Within minutes of any psycho
run, iOS throttles the camera's frame delivery to a per-chassis budget:
~25–30 fps at window 1 collapses to **~6–7 fps on both iPhones, ~12–15 on
the iPad** (dim buys the iPad more, see §3). Psycho never sustains
video-rate stacking anywhere, and *delivered blend depth = throttled fps ×
interval* — 5 s ≈ 36–41 frames, 3 s ≈ 19–24, 1 s ≈ 3–12.

**2 · The interval is not a lever that matters.** Not for survival: the
12 Pro's veto times (10.5 / 11.8 / 16.4 / 18.2 min) track start temperature
and time of day, not interval — a cooler start is worth minutes; 40 % fewer
encodes (5 s vs 3 s) was worth ~1. Not for motion blur either: coverage is
fps × shutter, interval-independent. Short intervals buy encode load, IO,
per-window log rewrites (O(n²) — 1,200-window logs rewrite every 0.5–1 s),
cadence strain (the 16 Pro ran 3 late windows and 10 near-single blends at
1 s) and storage, for *thinner* blends. **Longer intervals strictly
dominate.** Phase D (0.5 s) was deliberately dropped as confirmed-by-
extrapolation: at ~450 ms processing per 500 ms window the phones can only
thrash.

**3 · The display is the marginal load that turns "throttle" into "kill" —
the screen-dim A/B.** Dim-ON (18:04, nominal start): the 12 Pro **completed
its first psycho arm in five attempts**, reaching critical at T+5.9 and
riding it for 14 minutes — the treatment only the A18 got before. Dim-OFF
control (18:49, matched ~23-min rest, also nominal, in the *cooler, darker*
evening slot that should have favored it): **veto at T+18.2**. One trial
per cell, and the evening cool-down is a real confound (it alone stretched
dim-OFF survival from the afternoon's 10.5 to 18.2) — but the residual bias
runs *against* the conclusion, and the conclusion still holds. The iPad's
version of the same result is quality, not survival: steady blends/window
~63–72 dimmed vs ~54–61 not (some of that gap may be scene light).

**4 · The lock family — the real unattended-shoot killer.** Three
observations, one operational truth:
- The thermal veto **locks the device**; Auto-Lock → Never does not survive
  it (5× today, plus this morning's field run).
- Steven's sharper correlation: the lock follows **LetsLapse dying on a hot
  device** — including the post-collection `devicectl` console-detach kill
  after the *clean* dim-ON arm. Once woken it stays awake. Mechanism
  unpinned; discriminating test queued (hand-launched short shoot + normal
  exit vs devicectl-launched, hot vs cool).
- A locked device **refuses remote launches** — one veto ends the shoot
  *and* strands the device until a human touches it.

**5 · Bench ↔ field reconciliation.** The morning's field 12 Pro survived
31 min where the afternoon bench got 10.5: cold 05:30 start + near-black
viewfinder (OLED ≈ free) + cool air. Same death, same mechanism; the field
just starts further from the cliff. Evening bench arms confirmed the
ambient term directly.

## What this changes

- **Tonight's two-iPhone Dynamic shoot:** dim build installed on both
  iPhones (16 Pro included before it left); *Dim screen during shoot* is ON
  by default; devices cold and charged; expect the 12 Pro to hold. Tap the
  black screen to peek — tap → capture screen = running; tap → Lock Screen
  = the veto hit.
- **Field guidance, durable:** longest interval the shot allows; dim ON;
  cold start; the interval dial is an artistic choice, not a thermal one.
- **The queued governor work** (thermal-aware ceiling, suspension-honest
  lifecycle) now has numbers: the ceiling should treat *display state* and
  *thermal state* as inputs, and Safe-vs-dim on the 12 Pro is the next
  meaningful A/B (Safe attacks the floor load, dim attacks the OS margin —
  they should compose).

## The feature built today

Settings ▸ Advanced ▸ **"Dim screen during shoot"** (on by default):
`UIScreen.brightness` floored + full-bleed black cover + tap-to-peek
(8 s), restore on stop/exit/background; `ShootScreenDimmer` +
`ShootDimming` modifier (CaptureView's type-checker budget forced the
one-modifier shape). Watch toggle (`RemoteToggleRow` in controlsTab), wire
command `setDimDuringShoot` (the one setter accepted mid-run, by design),
`dimDuringShoot` in the state frame, `--dim on|off` in shoot.py run+fleet.
Verified live: dry-run round-trip, on-device black + tap-peek + re-dim
(Steven, mid-arm), A/B toggling by script. **Owed:** SVG mirrors (Advanced
row, watch controls page) after sign-off, Watch-side device verification,
macOS no-op sanity.

## Harness notes (each cost a retake today)

- `collect_arm` pulls the *newest* capture_log on the device — a dead arm
  registers nothing, so the pull silently hands back the previous run's log
  (bit twice: Phase A returned the morning field log; the F control
  returned the E arm). Fix queued: verify `sessionStart` falls inside the
  arm's window, else say "no log from this run" and point at the liveblend
  experiment log, which is the honest death record either way.
- Background shells don't inherit the working directory you think —
  absolute paths only (one whole "build" ran against nothing).
- `--expect-format` appends to its list default (argparse), so the fleet's
  DNG default made `JPEG` mean *both*; defaults now applied in code.
- `fleet --blend psycho --dim on|off` + bare-alias arms are today's
  additions; sequential single-device fleets are the lock-resilient shape
  when one device may refuse to launch.
- The LLog console clock re-anchors (~1000 s) — window index × interval is
  the reliable time axis, not the console timestamp.
