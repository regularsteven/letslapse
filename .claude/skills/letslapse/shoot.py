#!/usr/bin/env python3
"""
shoot.py — run a real-camera capture test from this Mac over the LetsLapse
Camera remote.

The camera is a real iPhone or iPad on the same Wi-Fi with the LetsLapse
capture screen open. This drives it through `tools/remote_probe`, which
compiles the app's own `Shared/` wire sources — so it is the same Camera
remote the Mac app speaks, not a re-implementation of it.

    python3 .claude/skills/letslapse/shoot.py <command> [options]

    cameras   list USB-connected devices and browse the LAN for armed cameras
    prep      launch the app over USB and print its pairing code
    release   end a `prep` session (the app dies with its console — by design)
    state     connect and print what the camera is currently set to
    run       pre-flight, apply settings, verify, shoot, report
    logs      pull the app's experiment logs off a USB device

A shoot runs as three short connections — read, apply+verify, shoot — rather
than one long one. The listener holds a SINGLE peer and replaces it on any new
connection, so nothing else may be connected while this runs (close the
LetsLapse Mac app first). Splitting the phases means a rejected setting stops
the run before the shutter, and each phase is separately reportable.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
def find_unit(start):
    """Locate the LetsLapse/ unit from wherever this skill happens to live.

    The skill directory moved from `LetsLapse/.claude/skills/` to the repo
    root's `.claude/skills/` — only a repo-ROOT skill registers as a typed
    slash command; a nested one is visible to the model but `/letslapse`
    answers "Unknown command". Resolving the unit by looking for the Xcode
    project rather than by counting `..` means the script works from either
    location, and from any cwd.
    """
    for base in [start, *start.parents]:
        if (base / "LetsLapse.xcodeproj").exists():
            return base
        if (base / "LetsLapse" / "LetsLapse.xcodeproj").exists():
            return base / "LetsLapse"
    sys.exit("could not find LetsLapse.xcodeproj above " + str(start))


UNIT = find_unit(HERE)
BUNDLE_ID = "com.regularsteven.letslapse"
PROBE = UNIT / "tools" / "remote_probe"
PROBE_SOURCES = [
    UNIT / "tools/remote_probe.swift",
    UNIT / "Shared/CaptureRemoteFrame.swift",
    UNIT / "Shared/CaptureRemotePairing.swift",
    # NOT in the file's own header comment, which lists two — this is the third
    # and without it the compile fails with "cannot find 'WatchMessageKey'".
    UNIT / "Shared/WatchMessageKey.swift",
]

STATE_DIR = Path.home() / "Library/Developer/LetsLapseRun/shoots"

# --- the wire grammar, as the phone actually enforces it -------------------
# Every one of these is a guard in CaptureView.handleWatchCommand; a value
# outside them comes back `status=rejected`, not silently coerced.
CAPTURE_MODES = {"photo": "Photo", "interval": "Interval", "video": "Video"}
INTERVAL_MODES = {"basic": "off", "holygrail": "holyGrail", "scanner": "scanner"}
INTERVAL_EVERY = [0.5, 1.0, 2.0, 3.0, 5.0, 10.0]
BLEND_FIXED = [1, 3, 5, 10, 20]          # 1 == "Off"; Psycho/Safe are phone-only
STRATEGIES = ["zone", "latitude", "lumen"]
SEQUENCE_MODES = ["ramp", "marker"]
ACCEPTED = {"ok", "accepted"}


# ---------------------------------------------------------------- plumbing

def die(message, hint=None):
    print(f"\n✗ {message}", file=sys.stderr)
    if hint:
        print(f"  → {hint}", file=sys.stderr)
    sys.exit(1)


def ensure_probe():
    """Build `remote_probe` if it is missing or older than the wire sources.

    It is gitignored and built on demand, and it must be rebuilt whenever the
    protocol changes — that coupling is the point of compiling the real
    Shared/ files rather than copying the keys.
    """
    newest = max(source.stat().st_mtime for source in PROBE_SOURCES)
    if PROBE.exists() and PROBE.stat().st_mtime >= newest:
        return
    print("building remote_probe…", file=sys.stderr)
    result = subprocess.run(
        ["swiftc", "-O", "-o", str(PROBE)] + [str(s) for s in PROBE_SOURCES],
        cwd=str(UNIT / "tools"), text=True, capture_output=True)
    if result.returncode != 0:
        print(result.stderr[-3000:], file=sys.stderr)
        die("could not build remote_probe")


def parse_frames(stamped):
    """Turn stamped remote_probe --verbose lines into frames.

    Takes `(arrival_seconds, line)` pairs rather than bare lines because
    verbose mode prints the whole 40-key payload per reply but NO timestamp —
    only the one-line digest mode stamps its output. Stamping on arrival in
    `probe()` and parsing here keeps both: full payloads AND a timeline.

    Shape:
        → setCaptureMode:Video (id 2)
        ← reply (id 2)
          baseFPS = 25
          availableBaseFPS = (
            25,
            30
        )

    The device also sends UNSOLICITED pushes — a setter's own reply still
    carries the old payload and the new value arrives in the push behind it —
    so a push is parsed exactly like a reply and only `latest_state` cares
    which was which.
    """
    frames, current, array_key, array_values = [], None, None, None
    for at, line in stamped:
        line = line.rstrip("\n")
        if array_key is not None:
            if line.strip() == ")":
                current["body"][array_key] = array_values
                array_key, array_values = None, None
            else:
                token = line.strip().rstrip(",")
                if token:
                    array_values.append(coerce(token))
            continue
        sent = re.match(r"→ (.*) \(id (\d+)\)$", line)
        if sent:
            frames.append({"dir": "sent", "label": sent.group(1),
                           "id": int(sent.group(2)), "at": at, "body": {}})
            current = None
            continue
        recv = re.match(r"← (\S+) \(id (\d+)\)$", line)
        if recv:
            current = {"dir": "recv", "kind": recv.group(1), "id": int(recv.group(2)),
                       "at": at, "body": {}}
            frames.append(current)
            continue
        field = re.match(r"^  (\w+) = (.*)$", line)
        if field and current is not None:
            key, raw = field.group(1), field.group(2)
            if raw == "(":
                array_key, array_values = key, []
            else:
                current["body"][key] = coerce(raw)
            continue
        if line and not line.startswith(" "):
            current = None          # "script complete", "link closed", "FOUND: …"
    return frames


def coerce(raw):
    try:
        return int(raw)
    except ValueError:
        pass
    try:
        return float(raw)
    except ValueError:
        return raw


# The listener drops a connection that arrives too soon after the previous one
# closed — the phases here reconnect in well under a second otherwise, and the
# TLS handshake is accepted before the link is dropped with no reply to the
# first poll, which looks exactly like a wrong pairing code. Measured: a ~3 s
# gap is reliable, back-to-back is not.
RECONNECT_SETTLE = 3.0
_last_disconnect = [0.0]


def probe(code, script, echo=False, timeout=None, retries=1):
    """Run one scripted connection, streaming and stamping its frames."""
    for attempt in range(retries + 1):
        gap = RECONNECT_SETTLE - (time.time() - _last_disconnect[0])
        if gap > 0:
            time.sleep(gap)
        frames, raw = _probe_once(code, script, echo=echo, timeout=timeout)
        _last_disconnect[0] = time.time()
        if any(f["dir"] == "recv" for f in frames) or attempt == retries:
            return frames, raw
        print("   (link dropped before any reply — retrying)", file=sys.stderr)
    return frames, raw


def _probe_once(code, script, echo=False, timeout=None):
    ensure_probe()
    command = [str(PROBE), code, script, "--verbose"]
    process = subprocess.Popen(command, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, bufsize=1)
    # A watchdog THREAD, not a deadline check inside the read loop: when no
    # camera is advertising, remote_probe browses forever and prints nothing,
    # so `for line in process.stdout` blocks and an in-loop deadline never gets
    # a turn. This hung a whole run before it was a timer.
    watchdog = threading.Timer(timeout or 3600, process.kill)
    watchdog.daemon = True
    watchdog.start()

    started = time.time()
    stamped, found = [], False
    try:
        for line in process.stdout:
            stamped.append((time.time() - started, line))
            if line.startswith("FOUND"):
                found = True
            if echo and (line.startswith("→") or line.startswith("←")
                         or line.startswith("FOUND") or line.startswith("link")):
                print("   " + line.rstrip(), file=sys.stderr, flush=True)
    finally:
        watchdog.cancel()
    process.wait()

    if not found:
        die("no camera is advertising on this network",
            "the capture screen must be OPEN on the device and the device UNLOCKED — "
            "iOS suspends network activity in the background, so a phone that slept has "
            "no listener. Set Auto-Lock → Never for the session, then "
            "`shoot.py prep` again (or re-open the app by hand and pass the new --code; "
            "the code is regenerated every time the capture screen appears).")
    return parse_frames(stamped), "".join(line for _, line in stamped)


def replies(frames):
    """Replies paired to the command that caused them, in order."""
    sent = {f["id"]: f["label"] for f in frames if f["dir"] == "sent"}
    out = []
    for frame in frames:
        if frame["dir"] == "recv" and frame["id"] in sent:
            out.append((sent[frame["id"]], frame))
    return out


def latest_state(frames):
    """The most recent full payload — pushes included, which is what carries a
    setting's effect: the reply to a setter still shows the OLD value, and the
    new one arrives in the push a beat later."""
    for frame in reversed(frames):
        if frame["dir"] == "recv" and frame["body"].get("recordingState") is not None:
            return frame["body"]
    return {}


# ---------------------------------------------------------------- cameras

def usb_devices():
    result = subprocess.run(["xcrun", "devicectl", "list", "devices"],
                            text=True, capture_output=True, timeout=90)
    devices = []
    for line in result.stdout.splitlines():
        match = re.match(r"^(.{1,22}\S)\s+\S+\s+([0-9A-F-]{36})\s+(connected|available.*?)\s{2,}(.+?)\s*$",
                         line)
        if match and match.group(3).startswith("connected"):
            devices.append({"name": match.group(1).strip(), "id": match.group(2),
                            "model": match.group(4).strip()})
    return devices


def cmd_cameras(args):
    print("USB-connected devices (can be launched hands-free):")
    found = usb_devices()
    for device in found:
        print(f"  {device['name']:<22} {device['id']}  {device['model']}")
    if not found:
        print("  (none)")

    print("\nCameras advertising on this network (capture screen open):")
    ensure_probe()
    # Browse-only mode never exits — it listens until ^C, which is right for a
    # human watching a rig come up and wrong for a script. Kill it on the
    # timeout and read what it printed before it died.
    try:
        output = subprocess.run([str(PROBE)], text=True, capture_output=True,
                                timeout=args.wait).stdout
    except subprocess.TimeoutExpired as expired:
        output = (expired.stdout or b"").decode() if isinstance(expired.stdout, bytes) \
            else (expired.stdout or "")
    hits = [l for l in output.splitlines() if l.startswith("FOUND")]
    for hit in hits or ["  (none — open LetsLapse on the device and leave the capture screen up)"]:
        print("  " + hit if hit.startswith("FOUND") else hit)


def cmd_prep(args):
    """Launch the app over USB and scrape its pairing code.

    Held open deliberately: `devicectl … --console` OWNS the app's lifetime —
    detach the console and the app dies on the device, taking the listener with
    it (measured). So this leaves the console running in its own session and
    records the pid for `release`.
    """
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    device = args.device
    if not device:
        found = usb_devices()
        if not found:
            die("no USB-connected device",
                "open LetsLapse on the device by hand, leave the capture screen up, "
                "and read the 6-digit code off the Remote chip — then pass it with --code")
        if len(found) > 1 and not args.device:
            print("More than one device is connected:", file=sys.stderr)
            for d in found:
                print(f"  --device {d['id']}   {d['name']} ({d['model']})", file=sys.stderr)
            die("pick one with --device")
        device = found[0]["id"]

    log = STATE_DIR / "console.log"
    handle = open(log, "w")
    process = subprocess.Popen(
        ["xcrun", "devicectl", "device", "process", "launch", "--device", device,
         "--console", "--terminate-existing", BUNDLE_ID],
        stdout=handle, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    (STATE_DIR / "console.pid").write_text(str(process.pid))

    print(f"launching on {device} …", file=sys.stderr)
    deadline = time.time() + args.wait
    while time.time() < deadline:
        time.sleep(1.0)
        match = re.search(r"remote-listener advertising on \d+ code=(\d{6})",
                          log.read_text(errors="replace"))
        if match:
            code = match.group(1)
            (STATE_DIR / "code").write_text(code)
            print(f"\ncode {code}")
            print(f"console pid {process.pid} → {log}")
            print("the app dies when this console detaches — `shoot.py release` when done")
            return
        if process.poll() is not None:
            print(log.read_text(errors="replace")[-1500:], file=sys.stderr)
            die("the launch exited before the listener started",
                "a locked device refuses devicectl launches — unlock it (Auto-Lock → Never "
                "for the session) and try again")
    die("no pairing code appeared", "check the device is unlocked and on this Wi-Fi")


def cmd_release(args):
    pidfile = STATE_DIR / "console.pid"
    if not pidfile.exists():
        print("nothing to release")
        return
    try:
        os.kill(int(pidfile.read_text()), signal.SIGTERM)
        print("console detached — the app has quit on the device")
    except ProcessLookupError:
        print("console was already gone")
    pidfile.unlink()


def resolve_code(args):
    if args.code:
        return args.code
    stored = STATE_DIR / "code"
    if stored.exists():
        return stored.read_text().strip()
    die("no pairing code",
        "run `shoot.py prep` for a USB device, or read the 6 digits off the Remote "
        "chip on the capture screen and pass --code NNNNNN")


# ---------------------------------------------------------------- state

INTERESTING = [
    ("captureMode", "mode"), ("formatLine", "format"), ("intervalMode", "MODE"),
    ("intervalAuto", "auto"), ("intervalSeconds", "every"), ("blendDepth", "blend"),
    ("blendStrategy", "strategy"), ("baseFPS", "base fps"), ("rampFPS", "burst fps"),
    ("sequenceMode", "sequence"), ("captureCount", "count"),
    ("recordingState", "recording"), ("cameraActive", "camera"),
    ("phoneAppState", "app"), ("phoneFlow", "flow"),
]


def show_state(body):
    for key, label in INTERESTING:
        if key in body:
            print(f"  {label:<10} {body[key]}")
    for key in ("availableBaseFPS", "availableBurstFPS"):
        if body.get(key):
            print(f"  {key:<10} {body[key]}")
        elif key in body:
            print(f"  {key:<10} (empty — only populated in Video mode)")


def cmd_state(args):
    code = resolve_code(args)
    frames, _ = probe(code, "state", echo=args.echo, timeout=60)
    body = latest_state(frames)
    if not body:
        die("no state came back",
            "is the capture screen still open, and is anything else connected? "
            "the listener holds one peer only")
    if args.json:
        print(json.dumps(body, indent=2, sort_keys=True))
    else:
        show_state(body)


# ---------------------------------------------------------------- the shoot

def preflight(body):
    """Is this camera in a state that can be driven at all?"""
    problems = []
    if body.get("cameraActive") != 1:
        problems.append(f"the capture screen is not up (phoneFlow={body.get('phoneFlow')})")
    if body.get("recordingState") != "idle":
        problems.append(f"the camera is already recording ({body.get('recordingState')})")
    if body.get("phoneAppState") != "active":
        problems.append(f"the app is in the background ({body.get('phoneAppState')})")
    if problems:
        die("pre-flight failed:\n    - " + "\n    - ".join(problems),
            "fix it on the device, then re-run — nothing was started")
    print("✓ camera is armed and idle")


def check_format(body, args):
    """Refuse to shoot at the wrong format.

    The whole reason this exists: stabilisation, ProRes / Apple Log / Capture
    Flat, resolution and DNG-vs-JPEG have NO remote command — they are set on
    the device — so reading `formatLine` back is the only protection against
    recording a shoot at settings nobody asked for.

    Checked AFTER the mode is applied, not before: `formatLine` is written per
    mode ("12MP 4:3 · DNG" in the still modes, "4K · 25 fps" in Video), so a
    check against the camera's incoming mode would fail on a format that is
    about to become correct.
    """
    format_line = str(body.get("formatLine", ""))
    missing = [t for t in (args.expect_format or []) if t.lower() not in format_line.lower()]
    if missing:
        die(f"format is {format_line!r}, missing " + ", ".join(repr(m) for m in missing),
            "stabilisation, codec (ProRes / Apple Log / Capture Flat), resolution and "
            "DNG-vs-JPEG have no remote command — set them on the device, then re-run. "
            "Nothing was started.")
    if args.expect_format:
        print(f"✓ format ok — {format_line}")


def build_settings(args, body):
    """The setter script, in the order the phone's own guards require."""
    steps = []
    if args.mode == "photo":
        steps.append("setCaptureMode:Photo")
        steps.append(f"setFramesPerBlend:{args.blend}")

    elif args.mode == "interval":
        token = INTERVAL_MODES[args.interval_mode]
        # setIntervalMode switches to Interval as a side effect — sending
        # setCaptureMode:Interval as well is redundant, and CLAUDE.md's note
        # that "setCaptureMode:interval is refused" is really about the TOKEN:
        # the raw values are capitalised ("Photo"/"Interval"/"Video").
        steps.append(f"setIntervalMode:{token}")
        if args.interval_mode == "scanner":
            pass                                  # Scanner owns the spacing entirely
        elif args.every == "auto":
            steps.append("setAutoInterval#1")     # refused on basic — it cannot pace
        else:
            if args.interval_mode == "holygrail":
                steps.append("setAutoInterval#0")
            steps.append(f"setIntervalSeconds#{float(args.every)}")
        steps.append(f"setFramesPerBlend:{args.blend}")
        if args.strategy:
            steps.append(f"setBlendStrategy:{args.strategy}")

    elif args.mode == "video":
        steps.append("setCaptureMode:Video")
        if args.sequence:
            steps.append(f"setSequenceMode:{args.sequence}")
        if args.base_fps:
            steps.append(f"setBaseFPS#{args.base_fps}")
        if args.burst_fps:
            steps.append(f"setBurstFPS#{args.burst_fps}")
    return steps


def build_run(args):
    """startRecording → poll, with timed bursts dropped in at their offsets."""
    poll = args.poll
    steps = ["startRecording"]
    elapsed = 0.0
    for offset, length in sorted(args.burst or []):
        gap = max(0.0, offset - elapsed)
        count = max(1, round(gap / poll))
        steps.append(f"poll@{poll}x{count}")
        elapsed += (count - 1) * poll
        steps.append(f"timedBurst#{length}")
        elapsed += length
    remaining = max(0.0, args.duration - elapsed)
    steps.append(f"poll@{poll}x{max(1, round(remaining / poll) + 1)}")
    steps.append("stopRecording")
    # The reply to `stopRecording` is `accepted`, not `stopped` — the payload it
    # carries still says `recording`, and the device settles to idle a beat
    # later. Without this the report always ended "recording" and cried wolf.
    steps.append("wait@3")
    steps.append("state")
    return steps


def cmd_run(args):
    code = resolve_code(args)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    log_path = STATE_DIR / f"shoot-{stamp}.log"

    # ---- phase 1: read
    print("① reading the camera")
    frames, text = probe(code, "state", echo=args.echo, timeout=60)
    body = latest_state(frames)
    if not body:
        die("no state came back",
            "capture screen open? anything else connected? the listener holds one peer")
    show_state(body)
    preflight(body)

    if args.mode == "video":
        ladder = body.get("availableBaseFPS") or []
        if args.base_fps and ladder and args.base_fps not in ladder:
            die(f"base fps {args.base_fps} is not offered at this format: {ladder}",
                "pick one of those, or change resolution/codec on the device")
        if not ladder:
            print("  note: the fps ladder is empty until the camera is in Video mode — "
                  "it will be re-checked after the mode switch")

    # ---- phase 2: apply, then verify
    settings = build_settings(args, body)
    print(f"\n② applying {len(settings)} setting(s)")
    frames, text2 = probe(code, ",".join(settings + ["wait@2", "state"]),
                          echo=args.echo, timeout=120)
    refused = [(label, frame["body"].get("message", ""))
               for label, frame in replies(frames)
               if frame["body"].get("status") not in ACCEPTED]
    for label, frame in replies(frames):
        status = frame["body"].get("status")
        mark = "✓" if status in ACCEPTED else "✗"
        print(f"  {mark} {label:<32} {status}")
    if refused:
        die("the camera refused: " + ", ".join(f"{l} ({m})" for l, m in refused),
            "a value outside what the phone allows is rejected, not coerced — "
            "see the grammar in SKILL.md. Nothing was started.")

    applied = latest_state(frames)
    print("\n  camera now reads:")
    show_state(applied)
    mismatches = verify(args, applied)
    if mismatches:
        die("settings did not take:\n    - " + "\n    - ".join(mismatches),
            "nothing was started")
    check_format(applied, args)

    if args.mode == "video" and args.base_fps:
        ladder = applied.get("availableBaseFPS") or []
        if ladder and args.base_fps not in ladder:
            die(f"base fps {args.base_fps} is not in {ladder}", "nothing was started")

    if args.dry_run:
        print("\n--dry-run: settings verified, shutter not pressed")
        return

    # ---- phase 3: shoot
    run_steps = build_run(args)
    print(f"\n③ shooting — {args.duration}s, polling every {args.poll}s"
          + (f", {len(args.burst)} burst(s)" if args.burst else ""))
    started = time.time()
    frames, text3 = probe(code, ",".join(run_steps), echo=args.echo,
                          timeout=args.duration + 180)
    wall = time.time() - started

    log_path.write_text(text + "\n" + text2 + "\n" + text3)
    report(args, frames, wall, applied, log_path)


def verify(args, body):
    """Did each setting actually land? The reply to a setter still carries the
    OLD payload — the new value arrives in the push behind it — so this reads
    the LAST state seen, after a deliberate wait."""
    out = []
    want_mode = CAPTURE_MODES[args.mode]
    if body.get("captureMode") != want_mode:
        out.append(f"mode is {body.get('captureMode')}, asked for {want_mode}")
    if args.mode == "interval":
        want = INTERVAL_MODES[args.interval_mode]
        if body.get("intervalMode") != want:
            out.append(f"MODE is {body.get('intervalMode')}, asked for {want}")
        if args.interval_mode != "scanner":
            if args.every == "auto" and body.get("intervalAuto") != 1:
                out.append("EVERY did not go to Auto")
            elif args.every != "auto" and float(body.get("intervalSeconds", -1)) != float(args.every):
                out.append(f"EVERY is {body.get('intervalSeconds')}, asked for {args.every}")
    if args.mode in ("photo", "interval") and args.blend:
        if str(body.get("blendDepth")) != str(args.blend):
            out.append(f"BLEND is {body.get('blendDepth')}, asked for {args.blend}")
    if args.mode == "interval" and args.strategy:
        if body.get("blendStrategy") != args.strategy:
            out.append(f"strategy is {body.get('blendStrategy')}, asked for {args.strategy}")
    if args.mode == "video":
        if args.base_fps and body.get("baseFPS") != args.base_fps:
            out.append(f"base fps is {body.get('baseFPS')}, asked for {args.base_fps}")
        if args.burst_fps and body.get("rampFPS") != args.burst_fps:
            out.append(f"burst fps is {body.get('rampFPS')}, asked for {args.burst_fps}")
        # sequenceMode is published by `updateWatchRecordingState`, so it is
        # ABSENT from an idle payload — it only appears once a run starts.
        # Absent therefore means "not yet observable", not "wrong": the
        # accepted status is the only evidence available before the shutter,
        # and the report checks the value again from the running state.
        if args.sequence and body.get("sequenceMode") not in (None, args.sequence):
            out.append(f"sequence is {body.get('sequenceMode')}, asked for {args.sequence}")
    return out


def report(args, frames, wall, requested, log_path):
    states = [f for f in frames if f["dir"] == "recv" and f["body"].get("recordingState")]
    final = states[-1]["body"] if states else {}
    counts = [(f["at"], f["body"].get("captureCount", 0)) for f in states]
    delivered = max((c for _, c in counts), default=0)

    print("\n" + "─" * 62)
    print(f"  shoot report — {args.mode}")
    print("─" * 62)
    print(f"  wall clock          {wall:.1f}s (asked for {args.duration}s)")
    # captureCount counts STILLS. A video run never increments it, so printing
    # it there reads as "the shoot captured nothing" when the clip is fine —
    # segments and ramp intervals are video's evidence.
    if args.mode != "video":
        print(f"  frames captured     {delivered}")
    if args.mode == "interval" and args.every != "auto" and delivered > 1:
        expected = args.duration / float(args.every)
        print(f"  expected ≈          {expected:.0f} at every {args.every}s")
        print(f"  delivered density   {delivered / expected * 100:.0f}%")
    running = next((f["body"] for f in reversed(states)
                    if f["body"].get("recordingState") == "recording"), {})
    if args.mode == "video":
        # Only observable now: the idle payload does not carry it.
        print(f"  sequence            {running.get('sequenceMode', '?')}"
              + (f" (asked for {args.sequence})" if args.sequence else ""))
    for key, label in (("segmentCount", "segments"), ("markerCount", "marks"),
                       ("rampIntervalCount", "ramp intervals")):
        value = final.get(key) or running.get(key)
        if value:
            print(f"  {label:<19} {value}")
    if final.get("holyGrailShutter") is not None:
        first = next((s["body"] for s in states if s["body"].get("holyGrailShutter")), {})
        print(f"  Holy Grail shutter  {first.get('holyGrailShutter')} → {final.get('holyGrailShutter')}")
        print(f"  Holy Grail ISO      {first.get('holyGrailISO')} → {final.get('holyGrailISO')}")
        if final.get("holyGrailClipped"):
            print("  ⚠ scene outran the hardware (clipped)")
    print(f"  last state seen    {final.get('recordingState')}")
    print(f"  format             {requested.get('formatLine')}")
    for note in args.attest or []:
        print(f"  attested           {note}  (operator-set, NOT verified by the link)")
    print(f"\n  full frame log     {log_path}")

    if args.mode in ("interval", "video") and final.get("recordingState") != "idle":
        # Not a fault. `onFinishLiveCapture` / `onFinishVideo` call `camera.stop()`
        # and `dismiss()`, and the capture screen OWNS the link — so an Interval
        # or Video run ends by taking the remote down with it, before the last
        # poll can see idle. Photo is the deliberate exception: it never leaves
        # the camera, so its link survives and it can shoot again immediately.
        print("\n  note: the link ended with the shoot. Interval and Video leave the")
        print("        capture screen when a run finishes, and the capture screen is")
        print("        where the link lives — so re-run `prep` before the next shoot.")
        print("        (Photo keeps the camera up and can shoot again straight away.)")
    print("\n  The link only sees what it polled. The authoritative per-window record")
    print("  — including the windows that captured nothing — is on the device:")
    print("      python3 .claude/skills/letslapse/shoot.py logs")


# ---------------------------------------------------------------- logs

def cmd_logs(args):
    device = args.device
    if not device:
        found = usb_devices()
        if not found:
            die("no USB-connected device", "log pulls need the cable; the report above "
                "is what the link itself saw")
        device = found[0]["id"]
    out = Path(args.out or (STATE_DIR / f"logs-{time.strftime('%Y%m%d-%H%M%S')}"))
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["xcrun", "devicectl", "device", "copy", "from", "--device", device,
         "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
         "--source", "Library/Application Support/LetsLapse/Logs",
         "--destination", str(out), "--user", "mobile"],
        check=False, timeout=300)
    files = [f for f in sorted(out.rglob("*")) if f.is_file()]
    print(f"pulled {len(files)} file(s) → {out}")

    # The newest liveblend log is the authoritative record of the shoot that
    # just ran: it records EVERY window, including the ones that captured
    # nothing, which the link's captureCount cannot show and which
    # capture_log.json structurally omits.
    blends = sorted((f for f in files if f.name.startswith("liveblend-")),
                    key=lambda f: f.name)
    if not blends:
        print("  (no liveblend logs — a Video shoot records elsewhere)")
        return
    newest = blends[-1]
    try:
        data = json.loads(newest.read_text())
    except (ValueError, OSError):
        print(f"  {newest.name}: unreadable")
        return
    header, summary = data.get("header", {}), data.get("summary", {})
    print(f"\n  {newest.name}")
    for key in ("deviceModel", "osVersion", "outputFormat", "requestedFramesPerBlend",
                "requestedIntervalSeconds", "captureWidth", "captureHeight"):
        if key in header:
            print(f"    {key:<26} {header[key]}")
    for key in ("requestedOutputs", "completedOutputs", "skippedWindows", "failedOutputs",
                "fallbackOutputs", "captureDurationSeconds", "peakProcessingSeconds",
                "finalThermalState"):
        if key in summary:
            value = summary[key]
            print(f"    {key:<26} {value:.2f}" if isinstance(value, float)
                  else f"    {key:<26} {value}")
    requested = summary.get("requestedOutputs") or 0
    completed = summary.get("completedOutputs") or 0
    if requested:
        print(f"    delivered density          {completed / requested * 100:.0f}%")
    outputs = data.get("outputs") or []
    encodes = [o.get("encodeMillis", 0) for o in outputs if not o.get("failed")]
    if encodes and max(encodes) > 1000:
        print(f"\n    ⚠ encode peaked at {max(encodes) / 1000:.1f}s per window — at this "
              f"format the\n      shoot is encode-bound, not capture-bound.")


# ---------------------------------------------------------------- args

def burst_spec(text):
    try:
        offset, length = text.split(":")
        return (float(offset), float(length))
    except ValueError:
        raise argparse.ArgumentTypeError("a burst is OFFSET:SECONDS, e.g. 10:2")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("cameras", help="list USB devices and browse for armed cameras")
    p.add_argument("--wait", type=float, default=12)
    p.set_defaults(func=cmd_cameras)

    p = sub.add_parser("prep", help="launch over USB, print the pairing code")
    p.add_argument("--device")
    p.add_argument("--wait", type=float, default=60)
    p.set_defaults(func=cmd_prep)

    p = sub.add_parser("release", help="end a prep session (quits the app on the device)")
    p.set_defaults(func=cmd_release)

    p = sub.add_parser("state", help="print what the camera is set to")
    p.add_argument("--code")
    p.add_argument("--json", action="store_true")
    p.add_argument("--echo", action="store_true")
    p.set_defaults(func=cmd_state)

    p = sub.add_parser("run", help="pre-flight, apply, verify, shoot, report")
    p.add_argument("--code")
    p.add_argument("--mode", required=True, choices=["photo", "interval", "video"])
    p.add_argument("--duration", type=float, default=30, help="seconds to shoot")
    p.add_argument("--poll", type=float, default=5, help="seconds between state polls")
    p.add_argument("--blend", default="auto",
                   help=f"auto, or one of {BLEND_FIXED} (1 = Off). Photo and Interval.")
    p.add_argument("--interval-mode", default="basic",
                   choices=list(INTERVAL_MODES), help="Interval's MODE dial")
    p.add_argument("--every", default="2",
                   help=f"Interval spacing: auto, or one of {INTERVAL_EVERY}")
    p.add_argument("--strategy", choices=STRATEGIES, help="Auto-blend decision logic")
    p.add_argument("--base-fps", type=int, help="Video base rate (must be in availableBaseFPS)")
    p.add_argument("--burst-fps", type=int, help="Video burst rate (must be in availableBurstFPS)")
    p.add_argument("--sequence", choices=SEQUENCE_MODES, help="bursts ramp the rate, or mark")
    p.add_argument("--burst", type=burst_spec, action="append", metavar="OFFSET:SECONDS",
                   help="repeatable, Video only, e.g. --burst 10:2 --burst 25:4")
    p.add_argument("--expect-format", action="append", metavar="TOKEN",
                   help="repeatable substring of formatLine that MUST match, e.g. 4K, DNG, ProRes")
    p.add_argument("--attest", action="append", metavar="NOTE",
                   help="repeatable operator-set fact to record, e.g. 'stabilisation=standard'")
    p.add_argument("--dry-run", action="store_true", help="verify settings, don't shoot")
    p.add_argument("--echo", action="store_true", help="stream the raw frames")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("logs", help="pull experiment logs off a USB device")
    p.add_argument("--device")
    p.add_argument("--out")
    p.set_defaults(func=cmd_logs)

    args = parser.parse_args()
    if args.command == "run":
        validate(args)
    args.func(args)


def validate(args):
    if args.blend != "auto" and int(args.blend) not in BLEND_FIXED:
        die(f"--blend must be auto or one of {BLEND_FIXED} (1 = Off)",
            "Psycho and Safe are deliberately phone-only — the remote cannot reach them")
    if args.mode == "interval":
        if args.interval_mode == "basic" and args.every == "auto":
            die("Basic cannot pace itself — Auto needs Holy Grail or Scanner",
                "use --every with one of " + str(INTERVAL_EVERY))
        if args.every != "auto" and float(args.every) not in INTERVAL_EVERY:
            die(f"--every must be auto or one of {INTERVAL_EVERY}",
                "the phone refuses anything else outright")
    if args.burst and args.mode != "video":
        die("--burst is Video only")


if __name__ == "__main__":
    # Line-buffered even when stdout is a pipe: a shoot prints its
    # progress over minutes, and block buffering would hold all of it
    # back until the process exited.
    sys.stdout.reconfigure(line_buffering=True)
    main()
