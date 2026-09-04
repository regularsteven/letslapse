#!/usr/bin/env python3
"""
driver.py — build, launch and drive LetsLapse (iOS Simulator, macOS app, `lapse` CLI).

Everything an agent needs to see this app actually running. Run it from
anywhere; paths are resolved relative to the LetsLapse/ unit root, which is
three levels up from this file.

    python3 .claude/skills/run-letslapse/driver.py <command> [options]

Commands
    cli                 build + smoke the `lapse` CLI (synth → info → blend → stack → grade)
    test                swift test in Kit/ (LetsLapseKit unit + GPU tests)
    build sim|mac       xcodebuild into an isolated DerivedData
    sim                 install + launch on a booted simulator with LL_* hooks, screenshot
    shot                screenshot a booted simulator
    mac                 launch the macOS app with LL_* hooks, screenshot its own window
    smoke text-field    real-input regression: type over a new text layer's copy (2026-09-04 crash)
    windows             list on-screen windows (CGWindowID / pid / frame) — see winlist.swift
    winshot             raise + capture one window by CGWindowID
    click               click inside a captured window, in that capture's pixel coords
    kill                terminate the app on a simulator and/or on the Mac

Why a script and not a list of shell commands: a foreground `sleep` is blocked
in this harness and a backgrounded shell script full of them produces no output
at all, so every launch/settle/capture sequence has to run inside one python3
process with time.sleep. That single fact is what this file exists for.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
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
REPO = UNIT.parent
BUNDLE_ID = "com.regularsteven.letslapse"
WATCH_BUNDLE_ID = "com.regularsteven.letslapse.watchkitapp"

# Out-of-repo, out-of-TMPDIR so it survives between sessions. The shared
# DerivedData is deliberately avoided: Xcode/MLX state has broken it before.
DD_ROOT = Path.home() / "Library/Developer/LetsLapseRun"
OUT_ROOT = DD_ROOT / "out"


# --------------------------------------------------------------------------- util

def run(cmd, check=True, capture=False, env=None, cwd=None, quiet=False,
        timeout=None):
    if not quiet:
        print("$ " + " ".join(str(c) for c in cmd), file=sys.stderr)
    try:
        proc = subprocess.run(
            [str(c) for c in cmd],
            check=False,
            text=True,
            env=env,
            cwd=str(cwd) if cwd else None,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.STDOUT if capture else None,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        # Without this every long call here could hang forever: xcodebuild
        # waiting on a lock, devicectl waiting on a device that went away.
        sys.exit(f"driver: `{cmd[0]}` timed out after {timeout}s")
    if check and proc.returncode != 0:
        if capture and proc.stdout:
            print(proc.stdout[-4000:], file=sys.stderr)
        sys.exit(f"driver: `{cmd[0]}` failed with exit {proc.returncode}")
    return proc


def hooks_to_env(pairs, prefix=""):
    """['LL_TAB=projects', 'LL_SPEED=20'] → {'<prefix>LL_TAB': 'projects', …}

    A bare name means "=1", which is what most of the app's presence-only hooks
    (LL_SCANS_EMPTY, LL_REFRAME_SEED…) actually test for.
    """
    env = {}
    for pair in pairs or []:
        key, _, value = pair.partition("=")
        if not key.startswith("LL_"):
            sys.exit(f"driver: hook {key!r} does not start with LL_ — refusing to set it")
        env[prefix + key] = value or "1"
    return env


def out_path(given, default_name):
    path = Path(given) if given else OUT_ROOT / default_name
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def sleep(seconds, why):
    print(f"… {why} ({seconds}s)", file=sys.stderr)
    time.sleep(seconds)


# --------------------------------------------------------------------------- CLI / tests

KIT = "Kit"


def cmd_cli(args):
    """Build the `lapse` executable and put every subcommand through a real render."""
    kit = UNIT / KIT
    run(["swift", "build", "-c", "release"], cwd=kit, capture=True)
    lapse = kit / ".build/release/lapse"
    work = out_path(args.workdir, "cli")
    work.mkdir(parents=True, exist_ok=True)
    shots = work / "shots"
    shots.mkdir(exist_ok=True)

    run([lapse, "synth", "-o", work / "test.mov", "--frames", "240", "--fps", "60", "--pattern", "box"])
    run([lapse, "info", work / "test.mov"])
    run([lapse, "blend", work / "test.mov", "-o", work / "ramped.mp4",
         "--ramp", "1:40", "--curve", "ease-in-out"])
    run([lapse, "blend", work / "test.mov", "-o", work / "timelapse.mp4", "--window", "20"])

    if shutil.which("ffmpeg"):
        run(["ffmpeg", "-y", "-v", "error", "-i", work / "test.mov",
             "-vf", "fps=10", shots / "f%03d.jpg"])
        stills = sorted(str(p) for p in shots.glob("*.jpg"))
        run([lapse, "stack", *stills, "-o", work / "stacked.png"])
        run([lapse, "grade", stills[0], "--recipe",
             '{"highlights":-100,"shadows":49,"vibrance":53}', "--out", work / "graded.jpg"])
    else:
        print("driver: ffmpeg not on PATH — skipping stack/grade (they need stills)", file=sys.stderr)

    for name in ("test.mov", "ramped.mp4", "timelapse.mp4", "stacked.png", "graded.jpg"):
        target = work / name
        state = f"{target.stat().st_size} bytes" if target.exists() else "MISSING"
        print(f"  {name:16} {state}")
    print(f"\ndriver: CLI smoke OK — outputs in {work}")


def cmd_test(args):
    """The Kit's own tests. These really do run Metal — they need a GPU, so they
    pass on this Mac and would not in a headless VM."""
    run(["swift", "test"], cwd=UNIT / KIT)


# --------------------------------------------------------------------------- build

def dd_path(platform):
    return DD_ROOT / f"dd-{platform}"


def cmd_build(args):
    dd = dd_path(args.platform)
    cmd = ["xcodebuild", "-project", UNIT / "LetsLapse.xcodeproj",
           "-scheme", "LetsLapse", "-configuration", args.configuration,
           "-derivedDataPath", dd]
    if args.platform == "sim":
        udid = args.device or booted_sim()
        cmd += ["-destination", f"platform=iOS Simulator,id={udid}",
                # Simulator builds never need a signature; skipping it keeps the
                # build off the keychain entirely.
                "CODE_SIGNING_ALLOWED=NO"]
    elif args.platform == "device":
        udid = resolve_device(args.device)
        # A device build must actually sign — no CODE_SIGNING_ALLOWED=NO here.
        # `generic/platform=iOS` builds for the family rather than for that one
        # device, which is what makes one build installable on the whole fleet.
        cmd += ["-destination", "generic/platform=iOS",
                "-allowProvisioningUpdates"]
        print(f"driver: device build (will install to {udid} on `deploy`)",
              file=sys.stderr)
    elif args.platform == "mac":
        # Deliberately NOT ad-hoc (CODE_SIGN_IDENTITY=-): an ad-hoc copy records
        # an automatic camera DENY against the bundle id that then blocks the
        # properly signed app too. Automatic signing with the cached
        # Apple Development identity works for com.regularsteven.* here.
        cmd += ["-destination", "platform=macOS"]
    cmd.append("build")
    # `| tail` on a foreground xcodebuild swallows the progress AND the error
    # line, so capture it and only print the tail on failure.
    proc = run(cmd, check=False, capture=True, cwd=UNIT)
    if proc.returncode != 0:
        print(proc.stdout[-6000:], file=sys.stderr)
        sys.exit(f"driver: build failed ({proc.returncode})")
    print(f"driver: built → {product_path(args.platform, args.configuration)}")


PRODUCT_SUFFIX = {"sim": "-iphonesimulator", "device": "-iphoneos", "mac": ""}


def product_path(platform, configuration="Debug"):
    subdir = f"{configuration}{PRODUCT_SUFFIX[platform]}"
    return dd_path(platform) / "Build/Products" / subdir / "LetsLapse.app"


def require_product(platform, configuration="Debug"):
    app = product_path(platform, configuration)
    if not app.exists():
        sys.exit(f"driver: {app} does not exist — run `driver.py build {platform}` first")
    return app


# --------------------------------------------------------------------------- devices

# The fleet registry is shared with the `letslapse` shoot skill: one list of
# aliases, one place to fix when a device is replaced.
REGISTRY = HERE.parent / "letslapse" / "devices.json"


def load_registry():
    if not REGISTRY.exists():
        sys.exit(f"driver: no device registry at {REGISTRY}")
    return json.loads(REGISTRY.read_text())


def registry_entry(alias):
    """Alias, aka, or marketingName → the registry row. Case-insensitive."""
    wanted = (alias or "").strip().lower()
    for row in load_registry()["devices"]:
        names = [row["alias"], row["marketingName"], *row.get("aka", [])]
        if wanted in (n.lower() for n in names):
            return row
    known = ", ".join(r["alias"] for r in load_registry()["devices"])
    sys.exit(f"driver: unknown device {alias!r} — the registry knows: {known}")


def devicectl_devices():
    out = OUT_ROOT / "devicectl-devices.json"
    run(["xcrun", "devicectl", "list", "devices", "--json-output", out],
        capture=True, quiet=True, timeout=90)
    return json.loads(out.read_text())["result"]["devices"]


def resolve_device(alias):
    """Registry alias → the identifier `devicectl --device` wants.

    Matches on `marketingName`, never on `name`: display names carry a U+2019
    apostrophe and a U+00A0 space, so they look ASCII in a terminal and never
    compare equal, and the user can rename them. Returns the top-level
    `identifier` — NOT `hardwareProperties.udid`, which is a different,
    ECID-style value that `--device` does not accept.
    """
    if not alias:
        sys.exit("driver: --device is required for a physical device "
                 "(an alias from devices.json, e.g. iphone-16)")
    # An identifier passed straight through stays usable.
    if re.fullmatch(r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}",
                    alias, re.I):
        return alias
    row = registry_entry(alias)
    matches = [d for d in devicectl_devices()
               if d.get("hardwareProperties", {}).get("marketingName")
               == row["marketingName"]]
    if len(matches) != 1:
        sys.exit(f"driver: {row['marketingName']!r} matched {len(matches)} devices — "
                 f"connect it over USB, or unlock and re-pair it")
    identifier = matches[0]["identifier"]
    print(f"driver: {row['alias']} → {row['marketingName']} ({identifier})",
          file=sys.stderr)
    return identifier


def cmd_devices(args):
    """What the registry knows, and which of those devicectl can see now."""
    seen = {}
    for d in devicectl_devices():
        hp, cp = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
        seen[hp.get("marketingName")] = (d.get("identifier"),
                                         cp.get("tunnelState", "?"))
    for row in load_registry()["devices"]:
        found = seen.get(row["marketingName"])
        if found:
            print(f"{row['alias']:<12} {row['marketingName']:<28} {found[0]}  {found[1]}")
        else:
            print(f"{row['alias']:<12} {row['marketingName']:<28} — not visible")


def cmd_deploy(args):
    """Install the current device build onto one device.

    Kept separate from `build` on purpose: `/run-letslapse`'s rule is that
    running never builds, and installing over the top can destroy a build that
    was deliberately put there. `--build` is the explicit opt-in.
    """
    if args.build:
        cmd_build(argparse.Namespace(platform="device", device=args.device,
                                     configuration=args.configuration))
    app = require_product("device", args.configuration)
    udid = resolve_device(args.device)
    run(["xcrun", "devicectl", "device", "install", "app",
         "--device", udid, app], capture=True, timeout=600)
    print(f"driver: installed {app.name} → {args.device}")


# --------------------------------------------------------------------------- simulator

def booted_sim():
    out = run(["xcrun", "simctl", "list", "devices", "booted"], capture=True, quiet=True).stdout
    matches = re.findall(r"^\s{4}(.+?) \(([0-9A-F-]{36})\) \(Booted\)", out, re.M)
    # iPhones first: most hooks are drawn for the phone layout.
    matches.sort(key=lambda m: (not m[0].startswith("iPhone"), m[0]))
    if not matches:
        sys.exit("driver: no booted simulator — `xcrun simctl boot <udid>` first "
                 "(iOS sims boot headless fine; a WATCH sim needs `open -a Simulator` first "
                 "or its system shell crash-loops)")
    name, udid = matches[0]
    print(f"driver: using booted simulator {name} ({udid})", file=sys.stderr)
    return udid


def cmd_sim(args):
    udid = args.device or booted_sim()
    app = require_product("sim", args.configuration)

    if args.fresh:
        # Needed whenever a hook seeds state the app has already written: once
        # the app owns a key, the container plist beats a user-domain seed.
        run(["xcrun", "simctl", "uninstall", udid, BUNDLE_ID], check=False)
    run(["xcrun", "simctl", "install", udid, app])
    run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], check=False, quiet=True)

    env = dict(os.environ)
    # The prefix has to be in the SHELL environment of simctl — passed as a
    # launch argument it does nothing at all.
    env.update(hooks_to_env(args.hook, prefix="SIMCTL_CHILD_"))
    log = out_path(args.log, "sim-launch.log")
    with open(log, "w") as handle:
        launch = subprocess.Popen(
            ["xcrun", "simctl", "launch", "--console-pty", udid, BUNDLE_ID],
            env=env, stdout=handle, stderr=subprocess.STDOUT, text=True)
    print(f"driver: launched with {sorted(k[13:] for k in env if k.startswith('SIMCTL_CHILD_LL_')) or 'no hooks'}",
          file=sys.stderr)

    sleep(args.wait, "letting the app settle")
    shot = out_path(args.shot, "sim.png")
    run(["xcrun", "simctl", "io", udid, "screenshot", shot], capture=True)
    print(f"driver: screenshot → {shot}")
    print(f"driver: console log → {log}")
    if not args.follow:
        launch.terminate()
    else:
        print("driver: following console; Ctrl-C to stop", file=sys.stderr)
        launch.wait()


def cmd_shot(args):
    udid = args.device or booted_sim()
    shot = out_path(args.out, "sim.png")
    run(["xcrun", "simctl", "io", udid, "screenshot", shot], capture=True)
    print(shot)


def ui_scale(udid):
    """`simctl io … enumerate` is the only place the simulator admits its point
    scale ("Preferred UI Scale: 3"), and it is what turns a screenshot pixel
    into the device point an MCP tap wants."""
    out = run(["xcrun", "simctl", "io", udid, "enumerate"], capture=True, quiet=True).stdout
    match = re.search(r"Preferred UI Scale: (\d+)", out)
    return int(match.group(1)) if match else 1


def cmd_devpoint(args):
    udid = args.device or booted_sim()
    scale = ui_scale(udid)
    print(f"scale {scale}× — screenshot px ({args.px},{args.py}) = device point "
          f"({round(args.px / scale)},{round(args.py / scale)})")


# --------------------------------------------------------------------------- macOS app

def cmd_mac(args):
    app = require_product("mac", args.configuration)
    binary = app / "Contents/MacOS/LetsLapse"

    env = dict(os.environ)
    env.update(hooks_to_env(args.hook))
    # Direct exec, not `open`: `open` cannot pass environment variables, so the
    # LL_* hooks never fire through it. The trade-off is that a shell-launched
    # Mac app prints nothing, so the console is not a diagnosis channel here.
    # -ApplePersistenceIgnoreState: no windows restored from the last run,
    # so what is on screen is what the hooks asked for (see launch_mac).
    proc = subprocess.Popen([str(binary), "-ApplePersistenceIgnoreState", "YES"], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"driver: launched {binary.name} pid={proc.pid} "
          f"hooks={sorted(k for k in env if k.startswith('LL_')) or 'none'}", file=sys.stderr)

    deadline = time.time() + args.wait
    window = None
    while time.time() < deadline:
        time.sleep(1.0)
        window = first_window(pid=proc.pid)
        if window:
            break
    if not window:
        proc.terminate()
        sys.exit("driver: no window appeared for that pid within "
                 f"{args.wait}s — check `driver.py windows LetsLapse`")

    # Settle after the window exists: the launch splash hands off to the real
    # UI a beat later, and capturing during the hand-off gets the splash.
    time.sleep(args.settle)
    shot = out_path(args.shot, "mac.png")
    capture_window(window["id"], shot)
    print(f"driver: window {window['id']} ({window['w']}×{window['h']} pt) → {shot}")
    print(f"driver: pid {proc.pid} left running — `driver.py kill --pid {proc.pid}` when done")


def first_window(pid=None, owner="LetsLapse"):
    for window in list_windows(owner=owner, pid=pid):
        return window
    return None


def list_windows(owner=None, pid=None):
    cmd = ["xcrun", "swift", str(HERE / "winlist.swift")]
    if owner:
        cmd.append(owner)
    if pid:
        cmd.append(str(pid))
    out = run(cmd, capture=True, quiet=True).stdout
    windows = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 8:
            continue
        windows.append({"id": int(parts[0]), "pid": int(parts[1]), "owner": parts[2],
                        "x": int(parts[3]), "y": int(parts[4]),
                        "w": int(parts[5]), "h": int(parts[6]), "title": parts[7]})
    return windows


def cmd_windows(args):
    windows = list_windows(owner=args.owner, pid=args.pid)
    if not windows:
        print("driver: no matching on-screen windows")
        return
    print(f"{'winID':>8}  {'pid':>6}  {'owner':<18} {'frame (pt)':<24} title")
    for w in windows:
        frame = f"{w['x']},{w['y']} {w['w']}×{w['h']}"
        print(f"{w['id']:>8}  {w['pid']:>6}  {w['owner']:<18} {frame:<24} {w['title']}")


def capture_window(window_id, path):
    # -l grabs the window's OWN buffer, so it is immune to occlusion and to the
    # second instance of the app that is usually sitting on top of it. -o drops
    # the drop shadow, which otherwise offsets every coordinate you measure.
    run(["screencapture", "-x", "-o", "-l", str(window_id), str(path)], capture=True)
    if not Path(path).exists() or Path(path).stat().st_size == 0:
        sys.exit(f"driver: screencapture wrote nothing for window {window_id}")
    return path


def cmd_winshot(args):
    if args.id:
        windows = [w for w in list_windows() if w["id"] == args.id]
    else:
        windows = list_windows(owner=args.owner, pid=args.pid)
    if not windows:
        sys.exit("driver: no matching window")
    window = windows[0]
    shot = out_path(args.out, f"window-{window['id']}.png")
    capture_window(window["id"], shot)
    px = image_size(shot)
    print(f"window {window['id']} owner={window['owner']!r} "
          f"frame={window['x']},{window['y']} {window['w']}×{window['h']}pt "
          f"image={px[0]}×{px[1]}px scale={px[0] / window['w']:.2f}")
    print(shot)


def image_size(path):
    out = run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
              capture=True, quiet=True).stdout
    w = int(re.search(r"pixelWidth: (\d+)", out).group(1))
    h = int(re.search(r"pixelHeight: (\d+)", out).group(1))
    return w, h


def cmd_click(args):
    """Click a point measured in a `winshot` image, in that image's pixels.

    Pixel-in-the-capture is the only coordinate system that survives here:
    iOS accessibility through System Events is near-useless (everything is a
    nested AXGroup and `entire contents` of a sheet times out), and the Mac
    app's AX tree can't be driven either because a fresh `swift`/`python3`
    binary is not in the Accessibility allowlist (-25205 kAXErrorAPIDisabled).
    So: capture the window, read coordinates off the image, click here.
    """
    windows = ([w for w in list_windows() if w["id"] == args.id] if args.id
               else list_windows(owner=args.owner, pid=args.pid))
    if not windows:
        sys.exit("driver: no matching window")
    window = windows[0]
    if window["owner"] == "Simulator" and not args.force:
        sys.exit(
            "driver: this is a Simulator window — window pixels do NOT map to device\n"
            "  points here (the device screen sits inset in a bezel below the title\n"
            "  bar, so a click computed from the window frame lands a row or two off;\n"
            "  measured that the hard way). Tap the simulator in DEVICE POINTS with the\n"
            "  iOS-Simulator MCP instead — `driver.py devpoint <px> <py>` converts a\n"
            "  `driver.py shot` pixel to the device point to pass it. Most screens need\n"
            "  no tap at all: reach them with LL_* hooks via `driver.py sim`.")
    shot = out_path(None, f"window-{window['id']}-click.png")
    capture_window(window["id"], shot)
    px_w, _ = image_size(shot)
    scale = window["w"] / px_w
    screen_x = window["x"] + args.x * scale
    screen_y = window["y"] + args.y * scale

    # AXRaise first: `System Events … click at` clicks whatever is visually on
    # top at those screen coordinates, not this window. Note the raise itself is
    # unreliable by construction — System Events' `whose unix id is <pid>`
    # silently resolves to the WRONG process when two share a name, which is the
    # normal state here (Steven's own copy of the Mac app is usually running,
    # and a second instance opens at the SAME frame). Hence the z-order check
    # below: the raise is best-effort, the check is what makes this safe.
    raise_window(window)

    if not args.force:
        topmost = topmost_window_at(screen_x, screen_y)
        if topmost is None:
            sys.exit(f"driver: no window at screen point ({int(screen_x)},{int(screen_y)})")
        if topmost["id"] != window["id"]:
            sys.exit(
                f"driver: refusing to click — the window on top at "
                f"({int(screen_x)},{int(screen_y)}) is {topmost['id']} "
                f"(owner {topmost['owner']!r}, pid {topmost['pid']}), not the target "
                f"{window['id']} (pid {window['pid']}). Two same-named processes at the "
                f"same frame is the normal case here; move or quit one, or pass --force.")

    run(["osascript", "-e",
         f'tell application "System Events" to click at {{{int(screen_x)}, {int(screen_y)}}}'],
        capture=True)
    print(f"driver: clicked image px ({args.x},{args.y}) → screen pt "
          f"({int(screen_x)},{int(screen_y)}) scale={scale:.3f}")


def raise_window(window):
    """Bring one specific window to the front.

    `window 1` is the wrong handle whenever the app owns several — Simulator
    normally has one per booted device, and raising "window 1" raises whichever
    of them happens to be frontmost, leaving the target still buried. Raise by
    TITLE where there is one (Simulator titles its windows "iPhone 17 Pro" etc.)
    and only fall back to index 1 for untitled windows.
    """
    owner = window["owner"]
    if window["title"]:
        target = f'(first window whose title is "{window["title"]}")'
    else:
        target = "window 1"
    scripts = [
        f'tell application "{owner}" to activate',
        f'tell application "System Events" to tell process "{owner}" to '
        f'perform action "AXRaise" of {target}',
    ]
    for script in scripts:
        run(["osascript", "-e", script], check=False, capture=True, quiet=True)
    time.sleep(0.6)


def topmost_window_at(x, y):
    """CGWindowListCopyWindowInfo returns on-screen windows in front-to-back
    z-order, so the first one whose frame contains the point is the one a click
    would actually land on."""
    for window in list_windows():
        if window["x"] <= x < window["x"] + window["w"] and \
           window["y"] <= y < window["y"] + window["h"]:
            return window
    return None


# --------------------------------------------------------------------------- teardown

def cmd_kill(args):
    if args.pid:
        run(["kill", str(args.pid)], check=False)
    if args.sim:
        udid = args.device or booted_sim()
        # capture=True keeps simctl's three-line "found nothing to terminate"
        # complaint out of the way: after a `driver.py sim` without --follow the
        # app is already gone (the console-pty child owns its lifetime), so
        # nothing to terminate is the NORMAL outcome, not an error.
        proc = run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID],
                   check=False, capture=True)
        print("driver: terminated on simulator" if proc.returncode == 0
              else "driver: nothing running on that simulator")


# --------------------------------------------------------------------------- smoke

def tool(name):
    """A compiled helper (hid, ax) — built from <name>.swift into DD_ROOT on
    first use and whenever the source is newer. Compiled, not `xcrun swift`:
    events posted from the interpreter never arrived (the posting process
    macOS attributes them to is the toolchain's, not this shell's), while
    the same code as a binary clicks and types (measured 2026-09-04)."""
    source = HERE / f"{name}.swift"
    binary = DD_ROOT / "tools" / name
    if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
        binary.parent.mkdir(parents=True, exist_ok=True)
        run(["xcrun", "swiftc", "-O", "-o", str(binary), str(source)], capture=True, quiet=True)
    return binary


def se_click(x, y):
    """A System Events click at a screen point — reaches buttons, rows and,
    once the window is key, text fields. Unlike a posted CGEvent it does
    not depend on this shell holding the Accessibility grant for event
    posting, which came and went mid-session on 2026-09-04."""
    run(["osascript", "-e", f'tell application "System Events" to click at {{{int(x)}, {int(y)}}}'],
        check=False, capture=True, quiet=True)


def se_keys(*steps):
    """Keystrokes through System Events into the frontmost app (the one a
    System Events click just activated). Each step is a text to type, or
    ("key", name, modifiers…) / ("cmd", "a")-style tuples."""
    codes = {"return": 36, "delete": 51, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126}
    lines = []
    for step in steps:
        if isinstance(step, str):
            escaped = step.replace("\\", "\\\\").replace('"', '\\"')
            lines.append(f'keystroke "{escaped}"')
        else:
            kind, name, *mods = step
            using = ""
            if mods:
                names = {"cmd": "command down", "shift": "shift down", "opt": "option down", "ctrl": "control down"}
                using = " using {" + ", ".join(names[m] for m in mods) + "}"
            if kind == "key":
                lines.append(f"key code {codes[name]}{using}")
            else:
                lines.append(f'keystroke "{name}"{using}')
        lines.append("delay 0.15")
    script = 'tell application "System Events"\n' + "\n".join(lines) + "\nend tell"
    run(["osascript", "-e", script], check=False, capture=True, quiet=True)


def hid(*words):
    """Real HID input through hid.swift — see that file for why AppleScript
    clicks and keystrokes are not enough for a SwiftUI text field."""
    return run([str(tool("hid")), *[str(w) for w in words]], capture=True, quiet=True).stdout.strip()


def ax_frame(pid, window_title, role, text):
    """Screen frame (x, y, w, h) of the first element of `role` in that window
    whose title, value or description is `text` — through ax.swift, which
    asks accessibility by PID. System Events cannot be used for this: its
    `process whose unix id is <pid>` resolves to the wrong LetsLapse when
    Steven's own copy is running (it walked his Settings window instead of
    the driver's editor, 2026-09-04)."""
    out = run([str(tool("ax")), str(pid), window_title, role, text],
              check=False, capture=True, quiet=True).stdout.strip()
    parts = out.split(",")
    if len(parts) != 4 or not all(p.strip().lstrip("-").isdigit() for p in parts):
        return None
    return tuple(int(v) for v in parts)


def launch_mac(hooks, wait=12):
    """Start the built Mac app with LL_* hooks; returns (proc, first window)."""
    app = require_product("mac", "Debug")
    binary = app / "Contents/MacOS/LetsLapse"
    env = dict(os.environ)
    env.update(hooks_to_env(hooks))
    # No restored windows: AppKit would otherwise reopen every editor the
    # app had open last time, and a smoke could type into one of THOSE —
    # someone else's project — instead of the one LL_EDITOR asked for.
    proc = subprocess.Popen([str(binary), "-ApplePersistenceIgnoreState", "YES"], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + wait
    window = None
    while time.time() < deadline:
        time.sleep(1.0)
        window = first_window(pid=proc.pid)
        if window:
            break
    if not window:
        proc.terminate()
        sys.exit(f"driver: no window appeared for pid {proc.pid} within {wait}s")
    return proc, window


def cmd_smoke(args):
    """UI smokes that a unit test cannot express — real input into the
    running Mac app, with the process alive AND the typed copy persisted as
    the verdict.

    text-field — after the 2026-09-04 crash: add a text layer in an interval
    project's editor, focus its copy field, select all and type over the
    placeholder, delete, retype, select a word and type over it. SwiftUI's
    TextField had re-applied a stale selection to the shorter text and
    trapped ("String index is out of bounds"); the fix re-seats the selection
    at the caret the edit leaves. KNOWN LIMIT: this smoke exercises typing into
    the field but does NOT reproduce that trap — an unfixed build passes it.
    The trap needs SwiftUI's own selection binding to hold the old range,
    which only a real mouse click into the field followed by ⌘A produces;
    accessibility focus and System Events keystrokes never fill it. Posted
    HID clicks would, and they stopped arriving from this shell mid-session
    (grant), so the crash itself stays a hands-on check. Run it against a
    layer-free interval project: the layer it adds is removed afterwards.
    """
    if args.which != "text-field":
        sys.exit(f"driver: unknown smoke {args.which!r} (have: text-field)")
    if not args.project:
        sys.exit("driver: smoke text-field needs --project <capture-uuid> — an interval "
                 "shoot you do not mind gaining a text layer")
    # The scratch project's sidecar: parked before the run so the layer list
    # is empty (the rail offsets below assume it), read afterwards as the
    # proof that the typing reached the field, and put back at the end.
    sidecar = smoke_sidecar(args)
    if sidecar.exists():
        # Someone's layers — and Steven's own copy of the app may hold them
        # open. The smoke never parks a real sidecar (2026-09-04: it parked
        # and restored his, and any edit made during the run would have
        # been rolled back). It also needs an empty layer list to start.
        sys.exit(f"driver: {sidecar} exists — that project already has text layers. "
                 "Point --project at an interval shoot with none.")
    proc, _ = launch_mac([f"LL_EDITOR={args.project}", "LL_RAIL=text"], wait=args.wait)
    time.sleep(3)
    # launch_mac suppresses restored windows, so every editor window of this
    # process is the requested project (LL_EDITOR may open it twice — each
    # hook route opens one); drive the topmost.
    editors = [w for w in list_windows(pid=proc.pid) if w["title"] != "Create"]
    if not editors:
        proc.terminate()
        sys.exit("driver: no editor window — is that uuid an interval project?")
    win = editors[0]
    # Onto the main display first: System Events clicks did not land on a
    # window sitting at negative x (the left display), and the editor comes
    # back wherever it was last closed.
    moved = run([str(tool("ax")), "move", str(proc.pid), win["title"], "60", "60"],
                check=False, capture=True, quiet=True).stdout.strip().split(",")
    if len(moved) == 4:
        win = dict(win, x=int(moved[0]), y=int(moved[1]), w=int(moved[2]), h=int(moved[3]))
        time.sleep(0.5)
    if win["w"] < 900 or win["h"] < 600:
        proc.terminate()
        sys.exit(f"driver: editor window is {win['w']}×{win['h']} — the smoke needs at "
                 "least 900×600 (its rail offsets are measured from the right edge)")
    title_bar = (win["x"] + win["w"] // 2, win["y"] + 12)
    print(f"driver: smoke text-field on window {win['id']} at {win['x']},{win['y']} "
          f"{win['w']}×{win['h']}", file=sys.stderr)

    def locate(role, text):
        # Asked for at the moment of the click: the editor comes back at
        # whatever size it was last used at, and fixed offsets missed a
        # 1708×1415 window's Add Text by 50pt (measured).
        frame = ax_frame(proc.pid, win["title"], role, text)
        if not frame:
            proc.terminate()
            sys.exit(f"driver: smoke text-field could not find the {role} {text!r} in the editor window")
        x, y, w, h = frame
        print(f"driver:   {role} {text!r} at {x},{y} {w}×{h}", file=sys.stderr)
        return (x + w // 2, y + h // 2)

    add_text = locate("AXButton", "Add Text")
    def trace(name):
        if args.trace:
            capture_window(win["id"], out_path(None, f"smoke-text-field-{name}.png"))
    # Activation click on the title bar first: a click on a non-key window
    # only makes it key and is not delivered to the field.
    print(f"driver:   activation click {title_bar}, then Add Text {add_text}", file=sys.stderr)
    se_click(*title_bar)
    time.sleep(0.6)
    se_click(*add_text)
    time.sleep(1.5)
    trace("1-added")
    layers = ax_frame(proc.pid, win["title"], "AXStaticText", "1 layer")
    print(f"driver:   layer count after Add Text: {'1 layer' if layers else 'not 1 layer'}", file=sys.stderr)
    # Focus through accessibility: a System Events click activates the
    # window but places no caret in a SwiftUI text field, and posted HID
    # clicks depend on a grant this shell does not reliably hold.
    focused = None
    for role in ("AXTextField", "AXTextArea"):
        out = run([str(tool("ax")), "focus", str(proc.pid), win["title"], role, "Your text"],
                  check=False, capture=True, quiet=True).stdout.strip()
        if len(out.split(",")) == 4:
            focused = (role, out)
            break
    if not focused:
        proc.terminate()
        sys.exit("driver: smoke text-field — Add Text did not produce a card with a 'Your text' field")
    role = focused[0]
    print(f"driver:   focused {role} at {focused[1]}", file=sys.stderr)
    time.sleep(0.8)
    trace("2-focused")

    def front_pid():
        out = run([str(tool("ax")), "frontpid"], check=False, capture=True, quiet=True).stdout.strip()
        return int(out) if out.isdigit() else None

    def guarded_keys(label, *steps):
        # Real keystrokes are the ONLY input that reproduces the trap: both
        # accessibility routes (whole value, selected text) passed on the
        # unfixed build. System Events types into whichever app is active,
        # so the app is activated right before, and the burst is refused
        # unless this instance owns keyboard focus at both ends — a run on
        # 2026-09-04 had typed into Steven's other windows.
        # NSRunningApplication.activate — a System Events click on the
        # title bar never brought the app forward (buttons accept first
        # mouse; the app itself stayed behind).
        run([str(tool("ax")), "activate", str(proc.pid)], check=False, capture=True, quiet=True)
        time.sleep(0.3)
        # Focus the field again now that the app is frontmost: focus set
        # while it was behind did not survive activation as the key
        # window's first responder. Only by a non-empty value — an empty
        # lookup lands on the ID field, which is also empty.
        if current_text[0]:
            run([str(tool("ax")), "focus", str(proc.pid), win["title"], role, current_text[0]],
                check=False, capture=True, quiet=True)
            time.sleep(0.3)
        if front_pid() != proc.pid:
            proc.terminate()
            sys.exit(f"driver: smoke text-field ABORTED before '{label}' — another app holds keyboard "
                     "focus; run it while nothing else is being used")
        se_keys(*steps)
        if proc.poll() is None and front_pid() != proc.pid:
            print(f"driver:   WARNING: keyboard focus left the app during '{label}' — "
                  "some keystrokes may have gone elsewhere", file=sys.stderr)

    current_text = ["Your text"]

    def typed(label, expected, *keys):
        guarded_keys(label, *keys)
        current_text[0] = expected

    steps = [
        ("select all + type", lambda: typed("select all + type", "H", ("cmd", "a", "cmd"), "H")),
        ("select all + delete", lambda: typed("select all + delete", "", ("cmd", "a", "cmd"), ("key", "delete"))),
        ("retype", lambda: typed("retype", "Prague is worth a visit", "Prague is worth a visit")),
        ("select a word + type over it", lambda: typed(
            "select a word + type over it", "Prague is worth a trip",
            ("key", "left", "opt"), ("key", "left", "opt", "shift"), "trip")),
    ]
    for n, (label, action) in enumerate(steps, start=3):
        action()
        time.sleep(0.6)
        trace(f"{n}-{label.replace(' ', '-').replace('+', 'and')}")
        if proc.poll() is not None:
            report = sorted((Path.home() / "Library/Logs/DiagnosticReports").glob("LetsLapse-*.ips"))
            sys.exit(f"driver: smoke text-field FAILED — the app died during '{label}'"
                     + (f"\n  crash report: {report[-1]}" if report else ""))
    # The editor persists 2 s after the last edit; the sidecar is the proof
    # the keystrokes reached the field rather than a window that had lost
    # focus — every earlier "pass" of this smoke was exactly that.
    time.sleep(3)
    shot = out_path(args.shot, "smoke-text-field.png")
    capture_window(win["id"], shot)
    typed = sidecar.read_text() if sidecar.exists() else ""
    if args.keep:
        print(f"driver: pid {proc.pid} left running", file=sys.stderr)
    else:
        proc.terminate()
        proc.wait(timeout=10)
        # Leave the scratch project as it was found: without a sidecar.
        if sidecar.exists():
            sidecar.unlink()
    if "Prague is worth a trip" not in typed:
        sys.exit("driver: smoke text-field FAILED — the app stayed alive but the typed copy never "
                 f"reached the layer (sidecar holds {typed[:120]!r}); the clicks did not focus the field. "
                 f"See {shot} and --trace.")
    print(f"driver: smoke text-field PASSED — app alive after every step and the layer reads the typed copy; {shot}")


def smoke_sidecar(args):
    """The scratch project's overlays.json. Projects live under the storage
    root's Projects/ — the default Application Support one, or wherever
    Settings ▸ Storage moved it (pass --projects-root for that)."""
    roots = []
    if args.projects_root:
        roots.append(Path(args.projects_root).expanduser())
    # Settings ▸ Storage's nominated root (StorageRoot.customPathKey), when
    # the library has been moved — the usual case on this Mac.
    nominated = run(["defaults", "read", BUNDLE_ID, "storage.libraryRootPath"],
                    check=False, capture=True, quiet=True)
    if nominated.returncode == 0 and nominated.stdout.strip():
        roots.append(Path(nominated.stdout.strip()) / "Projects")
    roots.append(Path.home() / "Library/Application Support/LetsLapse/Projects")
    for root in roots:
        folder = root / args.project
        if folder.is_dir():
            return folder / "overlays.json"
    sys.exit("driver: could not find the project folder for that uuid under "
             + ", ".join(str(r) for r in roots) + " — pass --projects-root <…/Projects>")


# --------------------------------------------------------------------------- args

def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("cli", help="build + smoke the lapse CLI")
    p.add_argument("--workdir")
    p.set_defaults(func=cmd_cli)

    p = sub.add_parser("test", help="swift test in Kit/")
    p.set_defaults(func=cmd_test)

    p = sub.add_parser("devices", help="list the fleet registry and what is visible")
    p.set_defaults(func=cmd_devices)

    p = sub.add_parser("deploy", help="install the device build onto one device")
    p.add_argument("--device", required=True,
                   help="registry alias (iphone-16, ipad-m1, …) or an identifier")
    p.add_argument("--configuration", default="Debug")
    p.add_argument("--build", action="store_true",
                   help="build first — off by default; running never builds")
    p.set_defaults(func=cmd_deploy)

    p = sub.add_parser("build", help="xcodebuild into an isolated DerivedData")
    p.add_argument("platform", choices=["sim", "mac", "device"])
    p.add_argument("--device", help="simulator UDID (sim only)")
    p.add_argument("--configuration", default="Debug",
                   help="Debug keeps the #if DEBUG LL_* hooks; Release strips them")
    p.set_defaults(func=cmd_build)

    p = sub.add_parser("sim", help="install + launch on a simulator with LL_* hooks")
    p.add_argument("--device")
    p.add_argument("--configuration", default="Debug")
    p.add_argument("--hook", action="append", metavar="LL_X=Y",
                   help="repeatable; bare LL_X means LL_X=1")
    p.add_argument("--wait", type=float, default=6.0)
    p.add_argument("--shot")
    p.add_argument("--log")
    p.add_argument("--fresh", action="store_true", help="uninstall first (fresh container)")
    p.add_argument("--follow", action="store_true", help="keep streaming the console")
    p.set_defaults(func=cmd_sim)

    p = sub.add_parser("shot", help="screenshot a booted simulator")
    p.add_argument("--device")
    p.add_argument("--out")
    p.set_defaults(func=cmd_shot)

    p = sub.add_parser("devpoint", help="screenshot pixel → device point (for an MCP tap)")
    p.add_argument("px", type=int)
    p.add_argument("py", type=int)
    p.add_argument("--device")
    p.set_defaults(func=cmd_devpoint)

    p = sub.add_parser("mac", help="launch the macOS app with LL_* hooks and capture its window")
    p.add_argument("--hook", action="append", metavar="LL_X=Y")
    p.add_argument("--configuration", default="Debug")
    p.add_argument("--wait", type=float, default=25.0, help="seconds to wait for a window")
    p.add_argument("--settle", type=float, default=3.0, help="seconds after the window appears")
    p.add_argument("--shot")
    p.set_defaults(func=cmd_mac)

    p = sub.add_parser("windows", help="list on-screen windows")
    p.add_argument("owner", nargs="?", help="owner-name substring, e.g. LetsLapse")
    p.add_argument("--pid", type=int)
    p.set_defaults(func=cmd_windows)

    p = sub.add_parser("winshot", help="capture one window by id/owner/pid")
    p.add_argument("--id", type=int)
    p.add_argument("--owner", default="LetsLapse")
    p.add_argument("--pid", type=int)
    p.add_argument("--out")
    p.set_defaults(func=cmd_winshot)

    p = sub.add_parser("click", help="click a point measured in a winshot image")
    p.add_argument("x", type=int)
    p.add_argument("y", type=int)
    p.add_argument("--id", type=int)
    p.add_argument("--owner", default="LetsLapse")
    p.add_argument("--pid", type=int)
    p.add_argument("--force", action="store_true",
                   help="click even if another window is on top at that point")
    p.set_defaults(func=cmd_click)

    p = sub.add_parser("smoke", help="UI regression smokes with real input (text-field)")
    p.add_argument("which", choices=["text-field"])
    p.add_argument("--project", help="capture uuid of a SCRATCH interval project")
    p.add_argument("--wait", type=int, default=12)
    p.add_argument("--shot")
    p.add_argument("--keep", action="store_true", help="leave the app running afterwards")
    p.add_argument("--trace", action="store_true", help="capture the window after every step")
    p.add_argument("--projects-root", help="the storage root's Projects folder when it is not the default")
    p.set_defaults(func=cmd_smoke)

    p = sub.add_parser("kill", help="terminate what the driver started")
    p.add_argument("--pid", type=int)
    p.add_argument("--sim", action="store_true")
    p.add_argument("--device")
    p.set_defaults(func=cmd_kill)

    args = parser.parse_args()
    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    args.func(args)


if __name__ == "__main__":
    main()
