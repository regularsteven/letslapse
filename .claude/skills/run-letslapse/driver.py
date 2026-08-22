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

def run(cmd, check=True, capture=False, env=None, cwd=None, quiet=False):
    if not quiet:
        print("$ " + " ".join(str(c) for c in cmd), file=sys.stderr)
    proc = subprocess.run(
        [str(c) for c in cmd],
        check=False,
        text=True,
        env=env,
        cwd=str(cwd) if cwd else None,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )
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


def product_path(platform, configuration="Debug"):
    subdir = "Debug-iphonesimulator" if platform == "sim" else "Debug"
    subdir = subdir.replace("Debug", configuration)
    return dd_path(platform) / "Build/Products" / subdir / "LetsLapse.app"


def require_product(platform, configuration="Debug"):
    app = product_path(platform, configuration)
    if not app.exists():
        sys.exit(f"driver: {app} does not exist — run `driver.py build {platform}` first")
    return app


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
    proc = subprocess.Popen([str(binary)], env=env,
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

    p = sub.add_parser("build", help="xcodebuild into an isolated DerivedData")
    p.add_argument("platform", choices=["sim", "mac"])
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
