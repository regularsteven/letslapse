# LetsLapse — agent instructions

## Repository layout

- `main` branch: the original Raspberry Pi LetsLapse project (Python capture/blend scripts + web UI). **Untouchable** — never modify it from Swift-app work.
- `ios-app` branch: the native Swift app in `LetsLapse/` (universal iOS/iPadOS/macOS target + watchOS companion + `LetsLapseKit` package). Architecture handover doc: `LetsLapse/docs/letslapse-app-overview.md`.

## Design-sync requirement (ALL iOS / iPadOS / macOS / watchOS UI work)

The app's screens are mirrored as SVG design specs in `LetsLapse/docs/design/` (per-platform folders, one file per screen per orientation). The full contract lives in `LetsLapse/docs/design/README.md` — read it before any UI work. The short version:

1. **At the start of any UI task**, if the human hasn't said where to work, ask:
   *"Should we work on the design files first, the app code first, or something else?"*
   (A third standard path: the human has already edited the design files themselves — then the edited SVG **is** the spec; implement it.)
2. **After sign-off on one side, mirror the other side in the same unit of work.** A UI change is not done while its SVG (or its code) is stale.
3. Any commit touching SwiftUI layout/copy/colors/controls must update the matching SVG(s) — or state why no SVG applies. Track per-screen status in each platform folder's `INDEX.md`.
4. Verify mirrors against the running app using the DEBUG launch hooks (`LL_TAB`, `LL_OPEN`, `LL_SEED`, `LL_DETAIL`, `LL_PUSH`, `LL_CAPTURE`, `LL_BURST`, `LL_SPEED`, `LL_AUTO`, `LL_VIEWER`, `LL_COLLECTIONS`) via `simctl launch`.

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
