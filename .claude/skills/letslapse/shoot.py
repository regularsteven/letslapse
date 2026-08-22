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
import shutil
import subprocess
import sys
import threading
import time
import uuid
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
BLEND_FIXED = [1, 3, 5, 10, 20]          # 1 == "Off"
# Psycho (unthrottled) and Safe (throttled) became remotable 2026-08-22:
# Psycho is the mode that actually delivers motion blur, so it has to be
# reachable from a scripted comparison and a fleet shoot.
BLEND_ADAPTIVE = {"psycho": "unthrottled", "unthrottled": "unthrottled",
                  "safe": "throttled", "throttled": "throttled"}
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


def blend_token(value):
    """`--blend psycho` → the wire's `unthrottled`; everything else passes through."""
    return BLEND_ADAPTIVE.get(str(value).lower(), str(value))


def build_settings(args, body):
    """The setter script, in the order the phone's own guards require."""
    steps = []
    if args.mode == "photo":
        steps.append("setCaptureMode:Photo")
        steps.append(f"setFramesPerBlend:{blend_token(args.blend)}")

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
        steps.append(f"setFramesPerBlend:{blend_token(args.blend)}")
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


# ---------------------------------------------------------------- fleet

# Several cameras, one sky, one command. The whole point is that a strategy
# comparison needs arms that ran the SAME light at the SAME time: two field
# tests were voided by device confounds, and every arm that died early took
# its evidence with it.
#
# The choreography is built around two facts about the wire protocol:
#
#   - the listener holds ONE peer, so devices are visited strictly one at a
#     time (a second connect to the same camera tears the first link down);
#   - `scheduleStop` is anchored to the device's own `captureRunStartedAt`,
#     so `scheduleStop:minutes#60` sent at ANY point during a run stops it
#     exactly 60 minutes after that device started. That is what makes a
#     multi-hour shoot hands-free without holding four links open.
#
# So: arm everyone with a shared `scheduleStart` epoch, let them fire on
# their own clocks, then walk the fleet once more to hand each device its
# own deadline. The stop pass doubles as the start check — `scheduleStop`
# requires `isCapturing`, so a device that failed to fire refuses here,
# loudly, one minute in rather than at the end.

FLEET_DIR = STATE_DIR / "fleet"
REGISTRY = HERE / "devices.json"

# Budgeted per device for the arming pass: a launch that waits on the code,
# then two short scripted connections. Measured runs sit well inside this;
# the cost of being wrong is a rejected scheduleStart, not a bad shoot.
ARM_BUDGET_SECONDS = 45.0
# How long after the start epoch to walk the fleet arming stops. Long enough
# that a device is unambiguously recording, short enough to catch a failure
# while the shoot is still worth restarting.
CONFIRM_DELAY_SECONDS = 60.0


def load_registry():
    if not REGISTRY.exists():
        die(f"no device registry at {REGISTRY}")
    return json.loads(REGISTRY.read_text())


def registry_entry(alias):
    wanted = (alias or "").strip().lower()
    for row in load_registry()["devices"]:
        if wanted in (n.lower() for n in
                      [row["alias"], row["marketingName"], *row.get("aka", [])]):
            return row
    known = ", ".join(r["alias"] for r in load_registry()["devices"])
    die(f"unknown device {alias!r}", f"the registry knows: {known}")


def resolve_identifier(alias):
    """Registry alias → the identifier `devicectl --device` wants.

    Matches on `marketingName`: display names carry a U+2019 apostrophe and a
    U+00A0 space, so they look ASCII and never compare equal, and the user can
    rename them. Returns the top-level `identifier`, NOT
    `hardwareProperties.udid` — a different, ECID-style value `--device` does
    not accept.
    """
    row = registry_entry(alias)
    out = FLEET_DIR / "devicectl-devices.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["xcrun", "devicectl", "list", "devices",
                    "--json-output", str(out)],
                   capture_output=True, text=True, timeout=90)
    devices = json.loads(out.read_text())["result"]["devices"]
    matches = [d for d in devices
               if d.get("hardwareProperties", {}).get("marketingName")
               == row["marketingName"]]
    if len(matches) != 1:
        die(f"{row['marketingName']!r} matched {len(matches)} devices",
            "connect it over USB and unlock it (Auto-Lock → Never for the session)")
    return matches[0]["identifier"]


# --- time ----------------------------------------------------------------

def parse_duration(text):
    """'60m' · '4h' · '90s' · '1h30m' · bare number = minutes."""
    text = str(text).strip().lower()
    if re.fullmatch(r"[\d.]+", text):
        return float(text) * 60
    total, found = 0.0, False
    for value, unit in re.findall(r"([\d.]+)\s*([hms])", text):
        total += float(value) * {"h": 3600, "m": 60, "s": 1}[unit]
        found = True
    if not found:
        die(f"could not read a duration from {text!r}",
            "use forms like 60m, 4h, 90s, 1h30m")
    return total


def sunset_epoch(latitude, longitude, when):
    """NOAA sunset for a date, as epoch seconds. Pure arithmetic, no deps.

    `longitude` is east-positive (as stored in the registry); the algorithm
    wants west-positive, hence the negation.
    """
    import math
    # `when` is a time.struct_time. Anchor on LOCAL noon of that date and let
    # mktime resolve the offset (isdst=-1), so the result is right on both
    # sides of a DST change without any timezone arithmetic here.
    noon = time.mktime((when.tm_year, when.tm_mon, when.tm_mday,
                        12, 0, 0, 0, 0, -1))
    julian = noon / 86400.0 + 2440587.5
    # n is a WHOLE day count since J2000, not a fractional Julian date —
    # leaving the fraction in shifts sunset by the local UTC offset.
    n = math.ceil(julian - 2451545.0 + 0.0008)
    mean = n + (-longitude) / 360.0
    anomaly = math.radians((357.5291 + 0.98560028 * mean) % 360)
    center = (1.9148 * math.sin(anomaly) + 0.0200 * math.sin(2 * anomaly)
              + 0.0003 * math.sin(3 * anomaly))
    lam = math.radians((math.degrees(anomaly) + center + 180 + 102.9372) % 360)
    transit = 2451545.0 + mean + 0.0053 * math.sin(anomaly) - 0.0069 * math.sin(2 * lam)
    declination = math.asin(math.sin(lam) * math.sin(math.radians(23.44)))
    phi = math.radians(latitude)
    cos_hour = ((math.sin(math.radians(-0.833)) - math.sin(phi) * math.sin(declination))
                / (math.cos(phi) * math.cos(declination)))
    if not -1 <= cos_hour <= 1:
        die("the sun does not set at this latitude on this date",
            "give an absolute --at time instead")
    hour_angle = math.degrees(math.acos(cos_hour))
    return ((transit + hour_angle / 360.0) - 2440587.5) * 86400.0


def parse_at(text, site):
    """'now' · '+10m' · '17:00' · '2026-08-22T17:00' · 'sunset-30m'."""
    text = (text or "now").strip().lower()
    now = time.time()
    if text == "now":
        return now
    if text.startswith("+"):
        return now + parse_duration(text[1:])
    if text.startswith("sunset"):
        base = sunset_epoch(site["latitude"], site["longitude"],
                            time.localtime(now))
        offset = text[len("sunset"):].strip()
        if offset:
            sign = -1 if offset[0] == "-" else 1
            base += sign * parse_duration(offset[1:])
        return base
    for fmt in ("%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M", "%H:%M"):
        try:
            parsed = time.strptime(text.upper(), fmt)
        except ValueError:
            continue
        if fmt == "%H:%M":
            today = time.localtime(now)
            stamp = time.mktime((today.tm_year, today.tm_mon, today.tm_mday,
                                 parsed.tm_hour, parsed.tm_min, 0, 0, 0, -1))
            # A bare clock time that has already gone by today means tomorrow.
            return stamp if stamp > now else stamp + 86400
        return time.mktime(parsed)
    die(f"could not read a start time from {text!r}",
        "use now, +10m, 17:00, 2026-08-22T17:00, or sunset-30m")


def clock(epoch):
    return time.strftime("%H:%M:%S", time.localtime(epoch))


def wait_until(epoch, why):
    remaining = epoch - time.time()
    if remaining <= 0:
        return
    print(f"… {why} — {remaining / 60:.1f} min (until {clock(epoch)})",
          file=sys.stderr)
    while True:
        remaining = epoch - time.time()
        if remaining <= 0:
            return
        time.sleep(min(remaining, 30.0))


# --- arms ----------------------------------------------------------------

def parse_arm(text):
    """'ipad-m1:lumen' → (row, strategy)."""
    alias, _, strategy = text.partition(":")
    row = registry_entry(alias)
    strategy = (strategy or "").strip().lower()
    if strategy not in STRATEGIES:
        die(f"arm {text!r} needs a strategy",
            f"write <device>:<strategy>, one of {', '.join(STRATEGIES)}")
    return row, strategy


def fleet_launch(alias, identifier, wait):
    """Launch over USB and scrape the pairing code, per device.

    `devicectl … --console` OWNS the app's lifetime — detach and the app dies
    on the device, taking the listener with it — so each arm keeps its own
    console running for the whole shoot and `--release` ends them.
    """
    directory = FLEET_DIR / alias
    directory.mkdir(parents=True, exist_ok=True)
    log = directory / "console.log"
    handle = open(log, "w")
    process = subprocess.Popen(
        ["xcrun", "devicectl", "device", "process", "launch", "--device",
         identifier, "--console", "--terminate-existing", BUNDLE_ID],
        stdout=handle, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    (directory / "console.pid").write_text(str(process.pid))
    deadline = time.time() + wait
    while time.time() < deadline:
        time.sleep(1.0)
        # Harvest the code from THIS launch every time. A code from an earlier
        # session is stale: a new one is minted whenever the capture screen
        # comes back, which is exactly what a relaunch does.
        found = re.findall(r"remote-listener advertising on \d+ code=(\d{6})",
                           log.read_text(errors="replace"))
        if found:
            (directory / "code").write_text(found[-1])
            return found[-1]
        if process.poll() is not None:
            print(log.read_text(errors="replace")[-1200:], file=sys.stderr)
            die(f"{alias}: the launch exited before the listener started",
                "a locked device refuses devicectl launches — unlock it and set "
                "Auto-Lock → Never for the session")
    # Distinguish the three ways this fails. The camera starting but the
    # listener never advertising is the opt-in toggle being off, and nothing
    # about "no code appeared" points at that — it cost this rig one run.
    transcript = log.read_text(errors="replace")
    if "DidStartRunning" in transcript and "remote-listener" not in transcript:
        die(f"{alias}: the camera opened but the remote listener never started",
            "Allow remote access is OFF on this device. It is opt-in and off by "
            "default (remote.allowRemoteAccess). On the device: LetsLapse ▸ "
            "Settings ▸ Allow remote access. Then re-run.")
    if "remote-listener" in transcript and "advertising" not in transcript:
        die(f"{alias}: the listener started but never advertised",
            "Local Network permission is denied for LetsLapse on this device — "
            "Settings ▸ Privacy & Security ▸ Local Network ▸ LetsLapse")
    die(f"{alias}: no pairing code appeared",
        "the capture screen never opened. Is the device on this Wi-Fi and unlocked?")


def fleet_release():
    if not FLEET_DIR.exists():
        return
    for pidfile in sorted(FLEET_DIR.glob("*/console.pid")):
        try:
            os.kill(int(pidfile.read_text()), signal.SIGTERM)
            print(f"  {pidfile.parent.name}: console detached")
        except (ProcessLookupError, ValueError):
            print(f"  {pidfile.parent.name}: console already gone")
        pidfile.unlink()


def send_script(alias, code, script, timeout=120, echo=False):
    """One scripted connection. Returns (replies, latest state)."""
    frames, _ = probe(code, script, echo=echo, timeout=timeout)
    return replies(frames), latest_state(frames)


def refusals(pairs):
    return [(label, frame["body"].get("message", ""))
            for label, frame in pairs
            if frame["body"].get("status") not in ACCEPTED]


def fleet_settings(strategy, every):
    """Holy Grail, Auto blend depth, one strategy — the comparison preset.

    Auto blend DEPTH is the thing under test and stays on. Auto INTERVAL is
    off by default and is a flag, because it makes Zone and Latitude
    non-comparable: Zone smooths over 3 SAMPLES and Latitude over a 20-SECOND
    EMA, so a repaced interval stretches one strategy's memory and not the
    other's.
    """
    steps = ["setIntervalMode:holyGrail"]
    if str(every).lower() == "auto":
        steps.append("setAutoInterval#1")
    else:
        steps.append("setAutoInterval#0")
        steps.append(f"setIntervalSeconds#{float(every)}")
    steps.append("setFramesPerBlend:auto")
    steps.append(f"setBlendStrategy:{strategy}")
    return steps


def collect_arm(alias, identifier, outdir):
    """Pull the small evidence: the experiment logs, and this run's capture log.

    Deliberately NOT the frames. A 90-minute 8 s run is ~12 GB of DNGs per
    arm; the decision record, the delivery record and the validity gate all
    live in these two files. `--pull-frames` is the opt-in for the rest.
    """
    directory = outdir / alias
    directory.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["xcrun", "devicectl", "device", "copy", "from", "--device", identifier,
         "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
         "--source", "Library/Application Support/LetsLapse/Logs",
         "--destination", str(directory), "--user", "mobile"],
        capture_output=True, text=True, timeout=600)

    listing = directory / "projects.json"
    result = subprocess.run(
        ["xcrun", "devicectl", "device", "info", "files", "--device", identifier,
         "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
         "--username", "mobile", "--subdirectory",
         "Library/Application Support/LetsLapse/Projects",
         "--filter", "name ENDSWITH 'capture_log.json'",
         "--json-output", str(listing)],
        capture_output=True, text=True, timeout=300)
    if result.returncode != 0 or not listing.exists():
        print(f"  {alias}: could not list projects — no capture log pulled")
        return None
    files = json.loads(listing.read_text())["result"]["files"]
    if not files:
        print(f"  {alias}: no capture_log.json on the device")
        return None
    newest = max(files, key=lambda f: f["metadata"]["lastModDate"])
    # --destination must be a FILE path here. Handed a directory, devicectl
    # reports success and writes nothing.
    target = directory / "capture_log.json"
    subprocess.run(
        ["xcrun", "devicectl", "device", "copy", "from", "--device", identifier,
         "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
         "--user", "mobile", "--source",
         f"Library/Application Support/LetsLapse/Projects/{newest['relativePath']}",
         "--destination", str(target)],
        capture_output=True, text=True, timeout=300)
    if not target.exists():
        print(f"  {alias}: capture log did not land")
        return None
    print(f"  {alias}: capture log → {target} "
          f"({target.stat().st_size / 1024:.0f} KB)")

    # The ramp's OWN record of what it commanded, and the per-capture record of
    # what was delivered. Both are tens of KB and both are needed to tell "the
    # engine chose badly" from "the engine chose right and the sensor ignored
    # it" — the distinction that decided the 2026-08-22 iPad actuation finding.
    stem = newest["relativePath"].rsplit("/", 1)[0]
    for sidecar in ("frames.timestamps", "frames.exposure"):
        subprocess.run(
            ["xcrun", "devicectl", "device", "copy", "from", "--device", identifier,
             "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
             "--user", "mobile", "--source",
             f"Library/Application Support/LetsLapse/Projects/{stem}/{sidecar}",
             "--destination", str(directory / sidecar)],
            capture_output=True, text=True, timeout=300)
        if (directory / sidecar).exists():
            print(f"  {alias}: {sidecar} → "
                  f"{(directory / sidecar).stat().st_size / 1024:.0f} KB")
    return target


def cmd_fleet(args):
    if args.release:
        fleet_release()
        return

    registry = load_registry()
    site = registry.get("site", {})
    arms = [parse_arm(text) for text in args.arm]
    seen = [row["alias"] for row, _ in arms]
    if len(set(seen)) != len(seen):
        die("the same device appears twice", "one strategy per device per session")
    # The phone refuses anything outside this ladder outright, so catch it
    # here rather than after four launches.
    if str(args.every).lower() != "auto" and float(args.every) not in INTERVAL_EVERY:
        die(f"--every must be auto or one of {INTERVAL_EVERY}",
            "the phone refuses anything else outright. For a mixed fleet 10 s is "
            "the safe floor — the 12 Pro's blend+author median ran 3.35-9.05 s, and "
            "a window that overruns its interval makes the ceiling clamp the count, "
            "which voids the run as strategy evidence (gate V2).")
    duration = parse_duration(args.duration)
    requested = parse_at(args.at, site)

    print(f"fleet: {len(arms)} arm(s), {duration / 60:.0f} min each, "
          f"every {args.every}s")
    for row, strategy in arms:
        print(f"  {row['alias']:<12} {row['marketingName']:<28} {strategy}")
    strategies = {s for _, s in arms}
    if len(strategies) == 1:
        print(f"  → control session: all arms on {strategies.pop()}, which "
              f"measures device-to-device variance with strategy held constant")

    # Everything from here until the fleet is recording can abort — a locked
    # device, a refused setting. Release whatever was already launched rather
    # than leaving half the fleet with consoles attached and settings changed.
    try:
        # ---- resolve + launch. Done first because it is the slow part and does
        # not depend on the start time; the epoch is fixed once we know the cost.
        print("\n① launching")
        ready = []
        for row, strategy in arms:
            identifier = resolve_identifier(row["alias"])
            code = fleet_launch(row["alias"], identifier, args.wait)
            print(f"  {row['alias']:<12} {identifier}  code {code}")
            ready.append((row, strategy, identifier, code))

        floor = time.time() + 20 + ARM_BUDGET_SECONDS * len(ready)
        start = max(requested, floor)
        if start > requested + 1:
            print(f"\n  start moved to {clock(start)} — arming {len(ready)} devices "
                  f"needs about {ARM_BUDGET_SECONDS * len(ready) / 60:.0f} min")

        # ---- arm each device, one at a time: the listener holds one peer.
        print(f"\n② arming for {clock(start)}")
        armed = []
        for row, strategy, identifier, code in ready:
            alias = row["alias"]
            pairs, body = send_script(alias, code, "state", timeout=60, echo=args.echo)
            if not body:
                die(f"{alias}: no state came back",
                    "capture screen open? is the LetsLapse Mac app holding the link?")
            preflight(body)
            script = fleet_settings(strategy, args.every) + ["wait@2", "state"]
            pairs, applied = send_script(alias, code, ",".join(script),
                                         timeout=150, echo=args.echo)
            refused = refusals(pairs)
            if refused:
                die(f"{alias} refused: " + ", ".join(f"{l} ({m})" for l, m in refused),
                    "a value outside what the phone allows is rejected, not coerced. "
                    "Nothing was started.")
            if applied.get("blendStrategy") != strategy:
                die(f"{alias}: strategy reads {applied.get('blendStrategy')!r}, "
                    f"asked for {strategy!r}", "nothing was started")
            check_format(applied, args)
            if args.dry_run:
                print(f"  {alias:<12} settings verified (--dry-run, no shutter)")
                armed.append((row, strategy, identifier, code))
                continue
            pairs, _ = send_script(alias, code, f"scheduleStart#{start:.0f}",
                                   timeout=60, echo=args.echo)
            refused = refusals(pairs)
            if refused:
                die(f"{alias}: scheduleStart was refused ({refused[0][1]})",
                    "the epoch has already passed — arming took longer than budgeted. "
                    "Nothing is recording; re-run.")
            print(f"  {alias:<12} armed for {clock(start)}  [{strategy}]")
            armed.append((row, strategy, identifier, code))

    except BaseException:
        print("\n  aborting — releasing the consoles already opened so no "
              "device is left half-armed", file=sys.stderr)
        fleet_release()
        raise

    if args.dry_run:
        print("\n--dry-run: every arm verified, no shutter pressed")
        fleet_release()
        return

    # ---- confirm the start and hand each device its own deadline.
    wait_until(start + CONFIRM_DELAY_SECONDS, "waiting for the fleet to fire")
    print(f"\n③ confirming and arming stops (+{duration / 60:.0f} min per device)")
    live, dead = [], []
    for row, strategy, identifier, code in armed:
        alias = row["alias"]
        script = f"state,scheduleStop:minutes#{duration / 60:.4f}"
        pairs, body = send_script(alias, code, script, timeout=90, echo=args.echo)
        recording = body.get("recordingState") not in (None, "idle")
        refused = refusals(pairs)
        if recording and not refused:
            print(f"  ✓ {alias:<12} recording, stops at "
                  f"{clock(start + duration)}")
            live.append((row, strategy, identifier, code))
        else:
            # scheduleStop requires isCapturing, so a refusal here IS the
            # start check — this arm never fired.
            print(f"  ✗ {alias:<12} not recording "
                  f"({body.get('recordingState')}) — this arm did not start")
            dead.append(alias)
    if not live:
        die("no arm is recording", "nothing to wait for — check the devices")
    if dead:
        print(f"\n  ⚠ {len(dead)} arm(s) down: {', '.join(dead)} — the session "
              f"continues with {len(live)}")

    # ---- watch, then collect.
    finish = start + duration
    if args.watch:
        while time.time() < finish:
            wait_until(min(finish, time.time() + args.watch), "next health check")
            if time.time() >= finish:
                break
            print(f"\n  health at {clock(time.time())}")
            for row, _, _, code in live:
                _, body = send_script(row["alias"], code, "state", timeout=60)
                print(f"    {row['alias']:<12} rec={body.get('recordingState')} "
                      f"count={body.get('captureCount')} "
                      f"every={body.get('intervalSeconds')} "
                      f"blend={body.get('blendDepth')}")
    else:
        wait_until(finish, "shooting")

    # Registration after a stop takes a moment, and the listener stands down
    # while it happens — an empty browse here is saving, not a crash.
    wait_until(time.time() + 90, "letting the devices register their projects")

    stamp = time.strftime("%Y%m%d-%H%M%S")
    outdir = Path(args.out) if args.out else STATE_DIR / f"fleet-{stamp}"
    outdir.mkdir(parents=True, exist_ok=True)
    print(f"\n④ collecting → {outdir}")
    session = {
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(start)),
        "durationMinutes": duration / 60,
        "intervalSeconds": args.every,
        "site": site.get("name"),
        "arms": [],
    }
    for row, strategy, identifier, code in live:
        log = collect_arm(row["alias"], identifier, outdir)
        session["arms"].append({
            "alias": row["alias"],
            "marketingName": row["marketingName"],
            "strategy": strategy,
            "captureLog": str(log) if log else None,
        })
    (outdir / "session.json").write_text(json.dumps(session, indent=2))

    print("\n⑤ releasing")
    fleet_release()

    logs = [a["captureLog"] for a in session["arms"] if a["captureLog"]]
    print(f"\ndone — {len(logs)} capture log(s) collected")
    if logs:
        print("\nNext, for the verdict and the baseline:")
        print(f"  python3 LetsLapse/tools/blend_compare.py report {' '.join(logs)}")
        print(f"  python3 LetsLapse/tools/fleet_report.py {outdir}")


# ---------------------------------------------------------------- import

# Pull shoots off a device straight into this Mac's LetsLapse library, so a
# run can be inspected here without the share-sheet-then-open-each-.lapse
# dance.
#
# Why this works without building a `.lapse`: a project on disk is just
# `Projects/<id>/{source,blends}`, and the library index beside it
# (`Projects/library.json`) holds the app's own serialised model. Every path
# inside a capture entry is RELATIVE (`source/frame-00001.dng`), so an entry
# copied from the device's index describes the same project equally well
# here. We give the copy a fresh `id` and record the device's id in
# `importedFromID` — the same convention the app's own archive import uses,
# which is what makes a second import of the same shoot detectable.

LIBRARY = Path.home() / "Library/Application Support/LetsLapse"
DEVICE_LIBRARY = "Library/Application Support/LetsLapse"
# Core Data's reference date: `createdAt` is seconds since 2001-01-01 UTC.
APPLE_EPOCH = 978307200


def mac_app_running():
    """Is the MAC app running — as opposed to a Simulator copy of it?

    Both have the process name "LetsLapse", so `pgrep -x` cannot tell them
    apart and reports a closed Mac app as open. Only the Mac app can write
    this library; a Simulator instance lives in its own container and is
    irrelevant here. Match on the executable path instead.
    """
    result = subprocess.run(["pgrep", "-lf", "LetsLapse"],
                            capture_output=True, text=True)
    for line in result.stdout.splitlines():
        _, _, command = line.partition(" ")
        if "CoreSimulator" in command:
            continue
        if command.endswith("LetsLapse.app/Contents/MacOS/LetsLapse"):
            return True
    return False


def pull_device_library(identifier, alias):
    """The device's project index. Also the list of what is importable."""
    directory = STATE_DIR / "import" / alias
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / "library.json"
    result = subprocess.run(
        ["xcrun", "devicectl", "device", "copy", "from", "--device", identifier,
         "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
         "--user", "mobile", "--source", f"{DEVICE_LIBRARY}/Projects/library.json",
         "--destination", str(target)],
        capture_output=True, text=True, timeout=300)
    if not target.exists():
        die(f"{alias}: could not read the device's project library",
            result.stderr.strip()[-300:] or "is LetsLapse installed and unlocked?")
    return json.loads(target.read_text())


def parse_since(text):
    """'today' · 'tonight' · '20:00' · '3h' · '2026-08-22T19:00' → epoch."""
    text = (text or "").strip().lower()
    now = time.time()
    today = time.localtime(now)
    midnight = time.mktime((today.tm_year, today.tm_mon, today.tm_mday, 0, 0, 0, 0, 0, -1))
    if text in ("today", "all today"):
        return midnight
    if text == "tonight":
        # Everything from late afternoon on — the shooting half of the day.
        return midnight + 17 * 3600
    if re.fullmatch(r"[\d.]+h", text):
        return now - float(text[:-1]) * 3600
    for fmt in ("%Y-%m-%dt%H:%M", "%Y-%m-%d %H:%M", "%Y-%m-%d", "%H:%M"):
        try:
            parsed = time.strptime(text, fmt)
        except ValueError:
            continue
        if fmt == "%H:%M":
            return time.mktime((today.tm_year, today.tm_mon, today.tm_mday,
                                parsed.tm_hour, parsed.tm_min, 0, 0, 0, -1))
        return time.mktime(parsed)
    die(f"could not read a time from {text!r}",
        "use today, tonight, 20:00, 3h, or 2026-08-22T19:00")


def device_captures(library, since=None, name=None, max_files=None):
    """Capture entries, newest first, filtered by when, name and size."""
    out = []
    for capture in library.get("captures", []):
        stamp = (capture.get("createdAt") or 0) + APPLE_EPOCH
        if since and stamp < since:
            continue
        # Size guard: one long DNG shoot can outweigh every other run of the
        # night put together, and it is usually the one worth deferring so the
        # quick ones land first.
        if max_files and len(capture.get("sourceFileNames") or []) > max_files:
            continue
        haystack = " ".join(str(capture.get(k, "")) for k in
                            ("originalName", "mode", "selectedPreset"))
        if name and name.lower() not in haystack.lower():
            continue
        out.append((stamp, capture))
    return sorted(out, key=lambda row: row[0], reverse=True)


def describe(stamp, capture):
    return (f"{time.strftime('%H:%M', time.localtime(stamp))}  "
            f"{str(capture.get('originalName', '?')):<16} "
            f"{str(capture.get('mode', '')):<34} "
            f"{len(capture.get('sourceFileNames') or []):>5} files")


def import_capture(identifier, alias, capture, logs_only):
    """Copy one project's folder over and register it in this Mac's library."""
    device_id = capture["id"]
    local_id = str(uuid.uuid4()).upper()
    destination = LIBRARY / "Projects" / local_id
    destination.mkdir(parents=True, exist_ok=True)

    if logs_only:
        # The sidecars are what analysis needs; the frames are the gigabytes.
        (destination / "source").mkdir(exist_ok=True)
        for sidecar in ("capture_log.json", "frames.timestamps", "frames.exposure"):
            subprocess.run(
                ["xcrun", "devicectl", "device", "copy", "from", "--device", identifier,
                 "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
                 "--user", "mobile",
                 "--source", f"{DEVICE_LIBRARY}/Projects/{device_id}/source/{sidecar}",
                 "--destination", str(destination / "source" / sidecar)],
                capture_output=True, text=True, timeout=600)
    else:
        # devicectl writes the folder INTO the destination, so pull into a
        # staging dir and lift the contents out.
        staging = destination.parent / f"{local_id}-staging"
        staging.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["xcrun", "devicectl", "device", "copy", "from", "--device", identifier,
             "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
             "--user", "mobile", "--source", f"{DEVICE_LIBRARY}/Projects/{device_id}",
             "--destination", str(staging)],
            capture_output=True, text=True, timeout=7200)
        inner = staging / device_id
        root = inner if inner.exists() else staging
        for item in root.iterdir():
            shutil.move(str(item), str(destination / item.name))
        shutil.rmtree(staging, ignore_errors=True)

    entry = dict(capture)
    entry["id"] = local_id
    # The app's own convention for "this came from somewhere else", and what
    # makes a repeat import recognisable rather than silently duplicated.
    entry["importedFromID"] = device_id
    if logs_only:
        # Do not claim frames that were not copied.
        entry["sourceFileNames"] = [
            n for n in (capture.get("sourceFileNames") or [])
            if (destination / n).exists()]
    return entry, destination


def cmd_import(args):
    row = registry_entry(args.device)
    identifier = resolve_identifier(row["alias"])
    library = pull_device_library(identifier, row["alias"])
    since = parse_since(args.since) if args.since else None
    found = device_captures(library, since=since, name=args.name,
                            max_files=args.max_files)
    if not found:
        die("nothing on that device matches",
            "try `--list` with no filters to see what is there")

    print(f"{len(found)} shoot(s) on {row['alias']}"
          + (f" since {time.strftime('%Y-%m-%d %H:%M', time.localtime(since))}" if since else ""))
    for stamp, capture in found:
        print("  " + describe(stamp, capture))
    if args.list:
        return

    existing = json.loads((LIBRARY / "Projects" / "library.json").read_text())
    already = {c.get("importedFromID") for c in existing.get("captures", [])}
    fresh = [(s, c) for s, c in found if c["id"] not in already]
    if len(fresh) != len(found):
        print(f"\n  {len(found) - len(fresh)} already imported — skipping those")
    if not fresh:
        print("nothing new to import")
        return
    if args.dry_run:
        print(f"\n--dry-run: would import {len(fresh)} shoot(s)")
        return

    # Checked here rather than up front: listing and dry runs write nothing,
    # and the app being open is only a problem for the index write below.
    if mac_app_running():
        die("the LetsLapse Mac app is running",
            "it owns Projects/library.json and would overwrite anything written "
            "underneath it. Quit LetsLapse, re-run, then open it to see the imports.")

    print(f"\nimporting {len(fresh)} shoot(s)"
          + (" (logs only)" if args.logs_only else " — frames included, this is the slow part"))
    imported = []
    for stamp, capture in fresh:
        print(f"  {describe(stamp, capture)}")
        entry, destination = import_capture(identifier, row["alias"], capture, args.logs_only)
        size = sum(f.stat().st_size for f in destination.rglob("*") if f.is_file())
        print(f"    → {destination.name}  ({size / 1e9:.2f} GB)")
        imported.append(entry)

    # Write the index LAST: a half-written library.json is the one failure
    # that would cost projects that are already on disk here.
    existing.setdefault("captures", []).extend(imported)
    backup = LIBRARY / "Projects" / "library.json.bak"
    shutil.copy2(LIBRARY / "Projects" / "library.json", backup)
    (LIBRARY / "Projects" / "library.json").write_text(json.dumps(existing, indent=2))
    print(f"\nregistered {len(imported)} shoot(s) — previous index saved as {backup.name}")
    print("open LetsLapse on this Mac to see them")


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

    p = sub.add_parser("fleet", help="one scripted shoot across several devices")
    p.add_argument("--arm", action="append", metavar="DEVICE:STRATEGY", default=[],
                   help="repeatable, e.g. --arm ipad-m1:lumen --arm iphone-16:latitude")
    p.add_argument("--duration", default="60m", help="60m · 4h · 90s · 1h30m")
    p.add_argument("--at", default="now",
                   help="now · +10m · 17:00 · 2026-08-22T17:00 · sunset-30m")
    p.add_argument("--every", default="10",
                   help=f"fixed spacing, one of {INTERVAL_EVERY}, or 'auto' "
                        f"(see the caveat in SKILL.md). 10 s is the mixed-fleet "
                        f"default: the 12 Pro's blend+author median ran 3.35-9.05 s.")
    p.add_argument("--watch", type=float, metavar="SECONDS",
                   help="poll every arm this often during the run")
    p.add_argument("--expect-format", action="append", metavar="TOKEN",
                   default=["DNG"],
                   help="substring that must appear in formatLine (default DNG)")
    p.add_argument("--out", help="collection directory (default: a stamped one)")
    p.add_argument("--wait", type=float, default=60, help="seconds to wait for each code")
    p.add_argument("--dry-run", action="store_true",
                   help="verify every arm's settings, press no shutter")
    p.add_argument("--release", action="store_true",
                   help="just end any consoles a previous fleet run left open")
    p.add_argument("--echo", action="store_true")
    p.set_defaults(func=cmd_fleet)

    p = sub.add_parser("import", help="pull shoots off a device into this Mac's library")
    p.add_argument("--device", required=True, help="registry alias (iphone-16, ipad-m1, …)")
    p.add_argument("--since", help="today · tonight · 20:00 · 3h · 2026-08-22T19:00")
    p.add_argument("--name", help="substring of the shoot's name or mode")
    p.add_argument("--max-files", type=int, metavar="N",
                   help="skip shoots with more than N frames (defer the big one)")
    p.add_argument("--list", action="store_true", help="show what is there, import nothing")
    p.add_argument("--logs-only", action="store_true",
                   help="sidecars only, no frames — seconds instead of minutes")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_import)

    p = sub.add_parser("logs", help="pull experiment logs off a USB device")
    p.add_argument("--device")
    p.add_argument("--out")
    p.set_defaults(func=cmd_logs)

    args = parser.parse_args()
    if args.command == "run":
        validate(args)
    args.func(args)


def validate(args):
    blend = str(args.blend).lower()
    if blend != "auto" and blend not in BLEND_ADAPTIVE:
        try:
            fixed = int(blend)
        except ValueError:
            fixed = None
        if fixed not in BLEND_FIXED:
            die(f"--blend must be auto, one of {BLEND_FIXED} (1 = Off), "
                f"or {sorted(set(BLEND_ADAPTIVE))}",
                "anything else comes back rejected rather than coerced")
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
