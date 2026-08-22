---
name: letslapse
description: Run a real-camera capture test on an iPhone or iPad from this Mac, over the LetsLapse Camera remote. Use when asked to test capture, shoot a test, run a photo/interval/video test, try a Holy Grail or Scanner run, test bursts or a speed ramp, check blend depth or a blend strategy on a real device, or drive a paired camera from the Mac. Interactive — ask what to shoot and how, then run it and report.
---

Drives a **real iPhone or iPad** — real lens, real light — from this Mac. The
camera is any device on the same Wi-Fi with the LetsLapse capture screen open.

Everything runs through
**`.claude/skills/letslapse/shoot.py`**, which drives `tools/remote_probe`.
That probe compiles the app's own `Shared/` wire sources, so this **is** the
Camera remote — the same protocol the LetsLapse Mac app speaks, scripted
instead of clicked. Run every command below from the **repo root**
(`/Users/stevenwright/Documents/dev/letslapse`), which is where the shell's cwd
resets to between calls anyway. `shoot.py` finds the `LetsLapse/` unit itself,
so it does not care what the cwd is.

> **Close the LetsLapse Mac app before starting.** The camera's listener holds
> **one peer** and replaces it on any new connection, so a Mac app holding a
> stored pairing will tear this link down mid-shoot.

---

## How to run this skill

**Ask, then shoot.** Do not guess a test the operator did not ask for — a shoot
costs real time on a real device, and the parameters below change what is being
measured. Ask with `AskUserQuestion`, one round, and only about things that are
genuinely open.

### 1. Which camera

```bash
python3 .claude/skills/letslapse/shoot.py cameras
```

Prints USB-connected devices and any camera already advertising. Then:

- **USB-connected and unlocked** → `prep` launches the app and reads the code
  off the console. Hands-free.
- **Otherwise** → ask the operator to open LetsLapse on the device, leave the
  capture screen up, and read the six digits off the **Remote** chip. Pass them
  with `--code NNNNNN`.

```bash
python3 .claude/skills/letslapse/shoot.py prep --device <UDID>
```

`prep` prints the code and stores it, so later commands need no `--code`.

**Tell the operator to set Auto-Lock → Never.** iOS suspends network activity in
the background: a phone that sleeps has no listener, and the shoot dies with it.
This bit us twice while building this skill.

### 2. What to shoot — ask these

**Capture mode** — Photo · Interval · Video. Then, only what that mode uses:

| Mode | Ask about | Flag |
|---|---|---|
| **Photo** | how many frames blend into the one image | `--blend auto\|1\|3\|5\|10\|20` |
| **Interval** | MODE dial: Basic · Holy Grail · Scanner | `--interval-mode basic\|holygrail\|scanner` |
| | spacing, or Auto pacing (Holy Grail/Scanner only) | `--every 0.5\|1\|2\|3\|5\|10\|auto` |
| | frames blended per captured frame | `--blend auto\|1\|3\|5\|10\|20` |
| | Auto-blend decision logic, if `--blend auto` | `--strategy zone\|latitude\|lumen` |
| | how long to shoot | `--duration <seconds>` |
| **Video** | base frame rate (must be one the camera offers) | `--base-fps <n>` |
| | bursts ramp the rate, or just mark the moment | `--sequence ramp\|marker` |
| | what rate a burst switches to | `--burst-fps <n>` |
| | when bursts fire and for how long | `--burst 6:2 --burst 20:4` |
| | how long to shoot | `--duration <seconds>` |

**Then ask about the settings the remote cannot reach** (next section) and pass
them as `--expect-format` / `--attest`.

### 3. Run it

```bash
python3 .claude/skills/letslapse/shoot.py run --mode interval --interval-mode basic --every 2 --blend 5 --duration 24 --poll 4 --expect-format DNG
```

Add `--dry-run` to apply and verify the settings without pressing the shutter —
worth doing first for a long or expensive shoot.

### 4. Report

The run prints its own report. Then pull the device's own record, which is the
authoritative one:

```bash
python3 .claude/skills/letslapse/shoot.py logs --device <UDID>
```

### 5. Finish

```bash
python3 .claude/skills/letslapse/shoot.py release
```

---

## What the remote can and cannot set

This is the whole design constraint, so check it before promising a test.

**Settable over the link** — mode, Interval MODE dial, spacing / Auto, blend
depth, blend strategy, base fps, burst fps, ramp-vs-marker, timed bursts, marks,
AE/AF lock, ISO, lens position, scheduled start, start/stop.

**NOT settable — no command exists:**

| Setting | Why it matters |
|---|---|
| **Stabilisation** | no command *and no readout* — cannot be verified either |
| **ProRes / Apple Log / Capture Flat** | codec is chosen on the device |
| **Resolution** | 4K vs 1080p is chosen on the device |
| **DNG vs JPEG** (Interval) | chosen on the device |

For everything except stabilisation the device *reports* the result in
`formatLine` (`"12MP 4:3 · DNG"`, `"4K · 30 fps"`), so:

- `--expect-format DNG` / `--expect-format "30 fps"` / `--expect-format ProRes`
  (repeatable) — a substring that **must** appear, or the run stops before the
  shutter. This is the only protection against recording a shoot at settings
  nobody asked for.
- `--attest "stabilisation=standard"` (repeatable) — recorded in the report and
  clearly marked **operator-set, not verified**. Stabilisation can only ever be
  attested; do not claim the link checked it.

`--expect-format` is checked **after** the mode switch, because `formatLine` is
written per mode — a still-mode format string cannot be checked against a camera
still sitting in Video.

## Values the phone enforces

A value outside these comes back `status=rejected` — refused, never silently
coerced — and `shoot.py` stops rather than shooting something else:

- `--every` ∈ `0.5 1 2 3 5 10` (or `auto`)
- `--blend` ∈ `auto 1 3 5 10 20` (`1` = Off). **Psycho and Safe are phone-only**
  by design and cannot be reached remotely.
- `--base-fps` must be in `availableBaseFPS`, `--burst-fps` in
  `availableBurstFPS` — both reported by the camera, and both **empty until the
  camera is in Video mode**.
- Basic cannot use `--every auto` (it cannot pace itself); Scanner takes the
  spacing over entirely and ignores `--every`.

## Worked examples — all run against a real iPhone 16 Pro

Interval, plain timer, 5-frame DNG blends every 2 s:

```bash
python3 .claude/skills/letslapse/shoot.py run --mode interval --interval-mode basic --every 2 --blend 5 --duration 24 --poll 4 --expect-format DNG --attest "stabilisation=standard"
```

Photo, five frames stacked into one image:

```bash
python3 .claude/skills/letslapse/shoot.py run --mode photo --blend 5 --duration 10 --poll 3
```

Video at 30 fps with a 2-second burst to 60 fps at t=6 s:

```bash
python3 .claude/skills/letslapse/shoot.py run --mode video --base-fps 30 --sequence ramp --burst-fps 60 --burst 6:2 --duration 18 --poll 4 --expect-format "30 fps"
```

Just look at the camera:

```bash
python3 .claude/skills/letslapse/shoot.py state
```

## Reading the result

A run reports what the **link** saw; the device log reports what the **camera**
did. They differ, and the difference is usually the finding. From the interval
example above:

```
  wall clock          30.8s (asked for 24.0s)
  frames captured     4
  delivered density   33%
```

…while `shoot.py logs` gave the real account:

```
    requestedOutputs           12
    completedOutputs           6
    skippedWindows             6
    peakProcessingSeconds      4.89
    ⚠ encode peaked at 4.3s per window — at this format the
      shoot is encode-bound, not capture-bound.
```

The link polls; it cannot see a window that captured nothing. **Always pull the
logs before drawing a conclusion about delivered density.**

## Gotchas

- **A shoot ends the link — except in Photo.** `onFinishLiveCapture` and
  `onFinishVideo` call `camera.stop()` and `dismiss()`, and the capture screen
  is where the link lives. So **Interval and Video need a fresh `prep` between
  shoots**; Photo deliberately never leaves the camera and can shoot again
  straight away.
- **The pairing code changes every time the capture screen appears.** A code
  from ten minutes ago is stale. `prep` re-reads it; a manual operator must
  re-read the chip.
- **`--console` owns the app's life.** `devicectl … --console` kills the app on
  the device when it detaches — measured. `prep` keeps the console running in
  its own session and `release` ends it. A launch *without* `--console` leaves
  the app up but gives you no code to read.
- **Reconnecting too fast is refused.** The listener drops a connection that
  arrives immediately after the previous one closed: the TLS handshake is
  accepted, then the link dies with no reply — which looks exactly like a wrong
  code. `shoot.py` leaves a 3 s gap and retries once.
- **Mode tokens are capitalised.** `setCaptureMode:video` → `rejected`;
  `setCaptureMode:Video` → `accepted`. The raw values are `Photo`, `Interval`,
  `Video`. (`CLAUDE.md` records this as "setCaptureMode:interval is refused" —
  the token case is the actual reason.)
- **A setter's own reply carries the OLD state.** The new value arrives in an
  unsolicited push a beat behind it, which is why `shoot.py` waits before
  verifying. Never read a setting back from its own reply.
- **`sequenceMode` is absent while idle** — it is published with the recording
  state, so it can only be confirmed once the run is going. Accepted-status is
  the only evidence before the shutter.
- **`captureCount` counts stills only.** A Video run leaves it at 0; segments
  and ramp intervals are video's evidence.
- **The burst ladder depends on the base rate.** `availableBurstFPS` was
  `[30,50,60,100,120]` at 25 fps base and `[50,60,100,120]` at 30 — so base fps
  must be set *before* burst fps. `shoot.py` orders them that way.
- **`remote_probe` browses forever when nothing is advertising**, printing
  nothing, so a naive read loop hangs rather than timing out. `shoot.py` kills
  it with a watchdog thread and says the camera is not there.
- **Bench thermals are not field thermals.** Back-to-back runs push the device
  to `serious`; the log's `finalThermalState` is in every report. Let it cool
  before drawing conclusions about a real shoot.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `no camera is advertising on this network` | Capture screen closed, phone asleep/locked, or a previous shoot ended the link. `prep` again; set Auto-Lock → Never. |
| `pre-flight failed: the capture screen is not up` | The app is on another screen. Re-`prep`, or open the camera on the device. |
| `the camera refused: <command> (rejected)` | The value is outside what the phone allows — see **Values the phone enforces**. Nothing was started. |
| `format is '…', missing 'ProRes'` | The codec/resolution/DNG setting is device-side. Set it on the phone and re-run. |
| Link dies mid-shoot | Something else connected — the listener holds one peer. Close the LetsLapse Mac app and any other probe. |
| `the launch exited before the listener started` | Locked device. `devicectl` refuses those. Unlock and retry. |
| `no pairing code appeared` | Device not on this Wi-Fi, or Local Network permission denied for LetsLapse on the device. |

## Files

- `shoot.py` — the driver. `cameras`, `prep`, `release`, `state`, `run`, `logs`.
- Built on `../../tools/remote_probe` (gitignored; `shoot.py` builds it on demand
  from `remote_probe.swift` + `Shared/CaptureRemoteFrame.swift` +
  `CaptureRemotePairing.swift` + `WatchMessageKey.swift` — **three** Shared
  sources, not the two its own header comment lists).
- Shoot logs and pulled device logs land in
  `~/Library/Developer/LetsLapseRun/shoots/`.
- To build and run the app itself, see the sibling skill `run-letslapse`.
