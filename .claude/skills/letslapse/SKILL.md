---
name: letslapse
description: Run a real-camera capture test on one iPhone/iPad, or a synchronised shoot across several at once, from this Mac over the LetsLapse Camera remote. Use when asked to test capture, shoot a test, run a photo/interval/video test, try a Holy Grail or Scanner run, test bursts or a speed ramp, check blend depth or a blend strategy on a real device, compare Zone/Latitude/Lumen, run a fleet or multi-device shoot, schedule a shoot for a time or for sunset, or drive paired cameras from the Mac. Interactive — ask what to shoot and how, then run it and report.
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

**Invoked bare — `/letslapse` with no detail — ask what they want to do first**,
with `AskUserQuestion`, offering exactly these:

| answer | goes to |
|---|---|
| **Shoot on one camera** | *What to shoot* below — mode, settings, duration |
| **Shoot across several cameras** | **Fleet shoots**: one sky, one strategy each, synchronised start |
| **Import shoots from a device** | **Import shoots off a device**: pull projects into this Mac's library |
| **Look at a camera** | `shoot.py state` — what it is set to right now |

Then ask only what that path actually needs, and translate their words into
flags rather than making them learn the flags.

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

## Import shoots off a device

Pulls whole projects from a phone or iPad straight into this Mac's LetsLapse
library — no share sheet, no opening `.lapse` files one at a time.

```bash
python3 .claude/skills/letslapse/shoot.py import --device iphone-16 --since tonight --list
python3 .claude/skills/letslapse/shoot.py import --device iphone-16 --since tonight
```

**Always `--list` first.** A long DNG shoot is ~17 MB per frame, so a
55-minute run at 3 s is over 10 GB, and the listing is the only warning you
get before a very slow USB pull.

| you want | flag |
|---|---|
| tonight's shoots | `--since tonight` (from 17:00 local) |
| everything today | `--since today` |
| after a time | `--since 20:00` |
| the last few hours | `--since 3h` |
| one shoot by name/mode | `--name "Psycho"` · `--name "603 photos"` |
| skip the huge one for now | `--max-files 200` |
| sidecars only, no frames | `--logs-only` (seconds, enough for every analyzer) |
| see the plan, copy nothing | `--list` or `--dry-run` |

### The interactive flow

When the operator says "import from device" without detail, ask in this order
and translate their words into the flags above:

1. **Which device?** — run `shoot.py import --device <alias> --list` for the
   one they name; the aliases are in `devices.json`.
2. **From when?** — "tonight", "after 8pm", "today", "the one called XYZ".
3. **Show them the listing and confirm**, with the size implication spelled
   out: frame counts are in the listing and DNG runs are ~17 MB a frame,
   JPEG ~1–3 MB. Offer `--logs-only` when they only want to analyse.

### What it actually does, and the two rules that follow

A project on disk is just `Projects/<id>/{source,blends}` plus an entry in
`Projects/library.json`, and every path inside that entry is **relative**
(`source/frame-00001.dng`). So an entry copied from the device's own index
describes the same project equally well here. The import gives the copy a
fresh `id` and records the device's id in `importedFromID` — the same
convention the app's archive import uses.

- **Quit the LetsLapse Mac app first.** It owns `library.json` and will
  overwrite anything written underneath it. `import` refuses to write while
  the app is running (listing and `--dry-run` are fine).
- **Re-importing is safe.** Anything whose `importedFromID` already appears in
  this Mac's library is skipped and reported, so running the same command
  twice does not duplicate shoots.

The previous index is copied to `library.json.bak` before every write, and the
index is written last — after the frames have landed.

**Every import is verified against the device's own file listing** (via
`devicectl device info files`), not the index's claim: files the folder copy
dropped are re-fetched one by one, and a shoot that stays short is NOT
registered — the command says so and exits non-zero. This exists because
devicectl's whole-folder copy over a **Wi-Fi pairing** dies mid-transfer
(socket closed, POSIX 60) nondeterministically — measured 46 and then 1,883
of 2,757 files on the same 2.7 GB project — and used to exit 0 anyway.
Devices resolve over Wi-Fi whenever no cable is plugged in (`devicectl list
devices` says `available (paired)`; USB says `connected`), so a cabled device
is 10× faster **and** its bulk copy actually finishes. One big transfer also
starves every other devicectl call on the same Wi-Fi — sequence imports, never
parallelise them.

---

## Fleet shoots — several cameras, one sky

`fleet` runs one scripted shoot across several devices at once, each on its
own strategy. Use it whenever the question is *which strategy*, because a
strategy comparison needs arms that ran the **same light at the same time**:
both previous field tests were voided by device confounds, and every arm that
died early took its evidence with it.

```bash
python3 .claude/skills/letslapse/shoot.py fleet \
  --arm ipad-m1:lumen --arm iphone-16:latitude --arm iphone-12:zone \
  --duration 60m --at sunset-30m --every 10
```

Devices are named by registry alias from `devices.json` — `iphone-16`,
`iphone-12`, `ipad-m1`, `ipad-m3` — or by any `aka` in it. Identifiers are
resolved at run time, never stored.

### Turning a sentence into a command

| The operator says | The command |
|---|---|
| "60 minute holy grail shoot with zone on the iPad M1 right now" | `fleet --arm ipad-m1:zone --duration 60m --at now` |
| "…with zone, lumen and latitude on the iPad M1 (lumen), iPhone 16 (latitude) and iPhone 12 (zone) at 5pm today" | `fleet --arm ipad-m1:lumen --arm iphone-16:latitude --arm iphone-12:zone --duration 60m --at 17:00` |
| "start half an hour before sunset and run till dark" | `fleet … --at sunset-30m --duration 90m` |
| "all four on zone for an hour" | `fleet --arm ipad-m1:zone --arm ipad-m3:zone --arm iphone-16:zone --arm iphone-12:zone --duration 60m` |

`--duration` takes `60m`, `4h`, `90s`, `1h30m`, or a bare number of minutes.
`--at` takes `now`, `+10m`, `17:00`, `2026-08-22T17:00`, or `sunset±Nm`
(computed for the site in `devices.json`). A bare clock time that has already
passed today means tomorrow.

**Auto is assumed for blend depth — that is the thing under test — and is
always on.** Auto *interval* is not, and `--every auto` should be a deliberate
choice: Zone smooths over **3 samples** and Latitude over a **20-second EMA**,
so a repaced interval stretches one strategy's memory and not the other's,
which makes the two non-comparable. Fixed spacing is the comparison preset;
`--every auto` is for reliability runs.

### How it runs, and why in that order

1. **Launch** every device over USB and scrape its pairing code. Slowest step,
   done first because it does not depend on the start time.
2. **Arm** each device in turn — settings, verify, `scheduleStart#<epoch>`.
   One at a time: the listener holds a single peer. The start epoch is pushed
   out automatically if arming needs longer than the requested time allows.
3. **Fire.** Every device starts on its own clock (~124 ms apart, measured).
4. **Confirm and set the deadline** a minute in: `scheduleStop:minutes#N`.
   Because `scheduleStop` is anchored to each device's own
   `captureRunStartedAt`, sending it mid-run still stops that arm exactly N
   minutes after *it* started — which is what makes a four-hour shoot
   hands-free without holding four links open. It also **doubles as the start
   check**: `scheduleStop` requires `isCapturing`, so an arm that never fired
   refuses here, loudly, one minute in rather than at the end.
5. **Collect** the experiment logs and this run's `capture_log.json` per
   device — small files, no frames — then release the consoles.

`--watch 300` polls every arm every five minutes so a long run can be reviewed
live. `--dry-run` verifies every arm's settings and presses no shutter.
`--release` just ends consoles a previous run left open.

### Choosing the interval

`--every` must be one of `0.5 1 2 3 5 10` or `auto` — the phone refuses
anything else outright. **10 s is the default for a mixed fleet**, and the
reason is gate criterion V2: the 12 Pro's blend+author median ran 3.35–9.05 s,
and a window that overruns its interval makes the processing ceiling clamp the
count. A clamped window is the *hardware* choosing the count, which voids the
run as strategy evidence however good the frames look.

### Reading the result

```bash
python3 LetsLapse/tools/fleet_report.py ~/Library/Developer/LetsLapseRun/shoots/fleet-<stamp> --label sunset-control
```

That prints the per-arm comparison, the validity gate's verdict per arm, and a
regression diff against the newest earlier baseline for the same device and
strategy — then writes this session into
`LetsLapse/docs/fieldtests/baselines/`. Only arms that PASS the gate belong in
a strategy comparison; the README there explains the six criteria.

### Designing a session

- **The first session of a programme should put every device on the SAME
  strategy.** That measures device-to-device variance with strategy held
  constant — the noise floor everything later is read against. Without it a
  small strategy difference cannot be told from a sensor difference.
- **Rotate strategies across sessions** so each device eventually runs each
  one.
- **Anchor the duration to sunset.** The strategies only differentiate across
  a real light traverse; sunset−30 min to sunset+60 min is the standing
  window.

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
- **`devicectl copy from --destination` must be a FILE path** when the source
  is a file. Handed a directory it reports "File received from Device" and
  writes nothing — a silent no-op that looks like success.
- **`--every` is a ladder, not a number.** `0.5 1 2 3 5 10` only; 8 is refused.
  For a mixed fleet 10 s is the floor that keeps the processing ceiling from
  clamping the blend count on the 12 Pro (which voids the run as strategy
  evidence — gate V2).
- **A fleet arm that will not start is caught at T+60 s, not at the end** —
  `scheduleStop` requires `isCapturing`, so the stop pass is also the start
  check. Trust that ✗ over anything the launch printed.
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

- `shoot.py` — the driver. `cameras`, `prep`, `release`, `state`, `run`,
  `fleet`, `logs`.
- `devices.json` — the fleet registry: alias → `marketingName`, plus the
  site's lat/long for sunset-relative start times. Shared with the
  `run-letslapse` skill.
- Built on `../../tools/remote_probe` (gitignored; `shoot.py` builds it on demand
  from `remote_probe.swift` + `Shared/CaptureRemoteFrame.swift` +
  `CaptureRemotePairing.swift` + `WatchMessageKey.swift` — **three** Shared
  sources, not the two its own header comment lists).
- Shoot logs and pulled device logs land in
  `~/Library/Developer/LetsLapseRun/shoots/`; fleet runs get their own
  `fleet-<stamp>/` there, and per-device consoles live under `fleet/<alias>/`.
- Analysis: `LetsLapse/tools/blend_compare.py` (per-log decisions, metrics
  and the validity gate), `tools/fleet_report.py` (session report, baseline,
  regression diff), `tools/flicker_report.py` (measured flicker, needs an
  exported clip).
- To build and run the app itself, see the sibling skill `run-letslapse`.
