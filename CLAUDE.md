# LetsLapse — agent instructions

## Repository layout

- `main` branch: the original Raspberry Pi LetsLapse project (Python capture/blend scripts + web UI). **Untouchable** — never modify it from Swift-app work.
- `ios-app` branch: the native Swift app in `LetsLapse/` (universal iOS/iPadOS/macOS target + watchOS companion + `LetsLapseKit` package). Architecture handover doc: `LetsLapse/docs/letslapse-app-overview.md`.
- Open, scoped-but-unstarted work lives in `LetsLapse/docs/TODO.md` — one entry per job, long jobs in their own document alongside it. Add a job there rather than leaving it in a conversation.

## Design-sync requirement (ALL iOS / iPadOS / macOS / watchOS UI work)

The app's screens are mirrored as SVG design specs in `LetsLapse/docs/design/` (per-platform folders, one file per screen per orientation). The full contract lives in `LetsLapse/docs/design/README.md` — read it before any UI work. The short version:

1. **At the start of any UI task**, if the human hasn't said where to work, ask:
   *"Should we work on the design files first, the app code first, or something else?"*
   (A third standard path: the human has already edited the design files themselves — then the edited SVG **is** the spec; implement it.)
2. **After sign-off on one side, mirror the other side in the same unit of work.** A UI change is not done while its SVG (or its code) is stale.
3. Any commit touching SwiftUI layout/copy/colors/controls must update the matching SVG(s) — or state why no SVG applies. Track per-screen status in each platform folder's `INDEX.md`.
4. Verify mirrors against the running app using the DEBUG launch hooks (`LL_TAB`, `LL_OPEN`, `LL_SEED`, `LL_DETAIL`, `LL_PUSH`, `LL_CAPTURE`, `LL_BURST`, `LL_SPEED`, `LL_AUTO`, `LL_VIEWER`, `LL_COLLECTIONS`, `LL_IMPORT`) via `simctl launch`.

Design tokens (`LL` in `App/DesignSystem.swift`): accent `#C36A00`, amber `#FFB340`, ink `#1C1C1E` — the README has the full table. If `DesignSystem.swift` changes, the SVGs are stale by definition.

## Capture test rig (monitor test card)

Repeatable ground truth for on-device capture timing. Full spec:
`LetsLapse/tools/testcard/README.md`.

- **Card**: `LetsLapse/tools/testcard/index.html` fullscreen on a monitor
  (portrait). Renders a session QR `LLTC1;<script>` (grammar
  `i25x100,b100x5,i25x100` — segments of one video ramp run: `i` = base rate,
  `b` = timed burst), a 500 ms time QR, a Gray-coded 60 Hz tick strip, sweep
  dial, AE patches and a constant-velocity ball. Every captured frame carries
  display-side time.
- **App side**: `App/TestCardRig.swift` + a sparse preview tap in
  `CameraController`. With the capture screen idle in **Video** mode, the rig
  locks when it decodes the session QR *and* sees the card's clock advance,
  shows a 3 s countdown chip (tap cancels), runs the script through the real
  ramp engine (`startRecording(.ramp)` + timed bursts), and stops itself.
  `LL_TESTRIG=chip` freezes a demo chip for design screenshots.
- **Analyzer**: `LetsLapse/tools/testcard_report.py report <clip>` → per-frame
  card timestamps, per-segment fps, ramp-switch gap events, AE stability.
  Needs the `tools/.venv` (numpy + opencv-python-headless) and
  `cv2.QRCodeDetectorAruco` — the plain OpenCV detector fails ~25% of mask-7
  QRs; Apple Vision on the phone is unaffected.
- **This ships in the normal build BY DECISION** (Steven: testing must be easy
  and no-fuss — do not move it behind a DEBUG gate). The guard rails are
  behavioural: arming requires the live card (advancing clock, so a photo of
  a card never arms), the countdown is visible and cancellable, and finished
  runs cool down 20 s before re-arming.

## Strategy field-testing & the remote bench (holy grail)

The blend-strategy work (Zone / Latitude / Lumen behind BLEND=Auto) is
validated on real devices via a hands-free bench. Reports in
`LetsLapse/docs/fieldtests/`; program history in the "Holy Grail Field
Program" artifact. The loop:

1. **Build & deploy** (signed Debug, isolated DerivedData — the shared one
   can be broken by Xcode/MLX state):
   `xcodebuild -project LetsLapse/LetsLapse.xcodeproj -scheme LetsLapse
   -destination 'generic/platform=iOS' -configuration Debug
   -derivedDataPath <scratch>/dd-device -allowProvisioningUpdates build`,
   then `xcrun devicectl device install app --device <udid> <.app>`.
2. **Launch + pairing code**: `xcrun devicectl device process launch
   --device <udid> --console --terminate-existing
   com.regularsteven.letslapse` — the capture screen opens itself and the
   remote listener prints `code=NNNNNN` on the console. Do NOT pass
   `LL_TAB`/hook env vars: any hook key suppresses the automatic
   camera-open (screenshot mode) and the listener never starts.
3. **Drive**: compile `LetsLapse/tools/remote_probe.swift` (with the four
   Shared sources it lists) and script runs:
   `./remote_probe <code>
   "setIntervalMode:holyGrail,setAutoInterval#1,setFramesPerBlend:auto,
   setBlendStrategy:zone,startRecording,poll@30xN,stopRecording"`.
   `setCaptureMode:interval` is refused (wrong token) — the interval-mode
   command already switches the tab.
4. **Pull evidence** (no export/import needed): `xcrun devicectl device
   copy from --device <udid> --domain-type appDataContainer
   --domain-identifier com.regularsteven.letslapse --source
   "Library/Application Support/LetsLapse/Logs" --destination <dir>` —
   the experiment logs record EVERY window including failed/starved tails
   that `capture_log.json` structurally omits. Analyze with
   `tools/blend_compare.py` and `tools/shoot_audit.py`.

**Hard rules learned on the bench:**

- **One control link at a time.** The listener holds a single peer and
  "replaces existing peer" on any new connection — concurrent probes (or a
  running LetsLapse **Mac app** holding a stale stored pairing) tear links
  down. Close the Mac app before bench sessions.
- Locked iPhones refuse `devicectl` launches — Auto-Lock → Never for the
  session. A device that advertises locally but never reaches the Mac's
  browse = Local Network permission or wrong Wi-Fi.
- LLog console timestamps re-anchor around 1000 s — it looks like an app
  restart and is not; verify with the probe link + file mtimes before
  believing a crash.
- Bench thermals are brutal by design (back-to-back runs → `serious`);
  a field run's cool start behaves far better. Let devices cool before a
  real shoot.

**Planned next bench (Steven):** a ~2-hour constrained daylight→sunset→
darkness run driven from this monitor setup, reviewed live as it happens —
consoles + monitors on the ramp/governor lines, periodic USB pulls mid-run.
The monitor test card (above) is the candidate controlled light source: it
can script a brightness ramp, which would make the light curve itself
repeatable. Design the observation plan before the run, not during.

**Bench addenda (2026-08-22):**
- Pairing codes ROTATE whenever a link dies mid-session (the listener
  re-advertises with a fresh code). Harvest `code=` from the attached
  console immediately before every connect; never reuse a code across a
  killed session.
- `remote_probe` scripted mode exits after its script (fixed); interactive
  modes still hold the link. For simultaneous multi-camera starts use
  `scheduleStart#<epoch>` — each device fires its own shutter on its own
  clock (measured 124 ms apart across two iPhones); stops are per-device
  `stopRecording` scripts afterwards.
- The listener stands down during project registration after a stop — an
  empty browse right after a run is saving, not a crash.
- Flicker quality gate: export the project's blend clip at NO depth, pull
  its `capture_log.json`, run `tools/flicker_report.py <clip> <log>` —
  attributes every visible luma step to what the engine changed at that
  frame; greppable FLICKER PASS/FAIL verdict.
