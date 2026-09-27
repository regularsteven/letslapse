#!/usr/bin/env python3
"""The performance baseline, hands-free, on a USB-connected iPhone or iPad.

Runs the scenarios of docs/performance-baseline-plan.md against one device
and reads the numbers back out of the trace and the console log, so the same
run can be repeated on the iPhone 18 Pro, the 16 Pro and the 12 Pro without
a finger on the phone:

  tools/perf_baseline.py --device "18 Pro" library            # counts + SHA of library.json
  tools/perf_baseline.py --device "18 Pro" install --app <LetsLapse.app>
  tools/perf_baseline.py --device "18 Pro" A --tag before     # cold launch: App Launch ×3 + Time Profiler ×1
  tools/perf_baseline.py --device "18 Pro" B --tag before     # Settings from launch (LL_TAB=settings, needs the hooks build)
  tools/perf_baseline.py --device "18 Pro" C --tag before --tele 4   # 10 photos over the Camera remote, Time Profiler
  tools/perf_baseline.py --device "18 Pro" logs --tag before  # pull Logs/ and print the photo phases
  tools/perf_baseline.py parse <trace> [<trace>…]             # the signposts and main-thread time of a trace

Every scenario terminates the app first (check the device is idle — a
terminate kills a running upload or import), records with `xcrun xctrace`
into docs/traces/ (git-ignored), pulls Logs/ afterwards and prints the key
metrics. The device must be unlocked (Auto-Lock → Never for the session).

C drives the shots over the Camera remote (tools/remote_probe, built from
the Shared sources — see the header of remote_probe.swift): the app is
launched under the profiler with no hooks, so the capture screen opens by
itself and prints a pairing code; the probe then takes 10 Photo-mode shots
in the plan's lens order (1× ×4, 0.5× ×3, tele ×3). Point the phone at a
fixed scene. B launches with LL_TAB=settings, which only a build with the
DEBUG hooks answers (`SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG $(inherited)'`
on a Release build); it measures Settings' own work, not a finger's scroll.
"""
import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
APP_ROOT = os.path.dirname(HERE)                     # LetsLapse/
TRACES = os.path.join(APP_ROOT, "docs", "traces")
BUNDLE = "com.regularsteven.letslapse"
LOGS_SUBDIR = "Library/Application Support/LetsLapse/Logs"
CONTAINER = ["--domain-type", "appDataContainer", "--domain-identifier", BUNDLE]

PHOTO_SCRIPT = ("setCaptureMode:Photo,wait@2,selectStop#1,wait@3,"
                "startRecording,wait@6,startRecording,wait@6,startRecording,wait@6,startRecording,wait@6,"
                "selectStop#0.5,wait@4,startRecording,wait@6,startRecording,wait@6,startRecording,wait@6,"
                "selectStop#{tele},wait@4,startRecording,wait@6,startRecording,wait@6,startRecording,wait@8,state")


def sh(cmd, check=True, capture=True, timeout=None):
    r = subprocess.run(cmd, text=True, capture_output=capture, timeout=timeout)
    if check and r.returncode != 0:
        sys.stderr.write((r.stdout or "") + (r.stderr or ""))
        raise SystemExit(f"failed ({r.returncode}): {' '.join(cmd)}")
    return r


def git_sha():
    return sh(["git", "-C", APP_ROOT, "rev-parse", "--short", "HEAD"]).stdout.strip()


# ---------------------------------------------------------------- devices

def resolve_device(query):
    """A UDID, or a substring of the marketing name ("18 Pro"), to a UDID."""
    if re.fullmatch(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}", query or ""):
        return query
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
        out = f.name
    sh(["xcrun", "devicectl", "list", "devices", "--json-output", out])
    data = json.load(open(out))
    os.unlink(out)
    hits = []
    for d in data.get("result", {}).get("devices", []):
        hw = d.get("hardwareProperties", {})
        name = hw.get("marketingName", "")
        if hw.get("reality") == "physical" and query.lower() in name.lower():
            hits.append((name, hw.get("udid"), d.get("connectionProperties", {}).get("tunnelState")))
    if len(hits) != 1:
        raise SystemExit(f"device {query!r}: {len(hits)} match(es): {hits}")
    name, udid, state = hits[0]
    print(f"device: {name} {udid} ({state})")
    return udid


def app_pid(udid):
    r = sh(["xcrun", "devicectl", "device", "info", "processes", "--device", udid], check=False)
    for line in (r.stdout or "").splitlines():
        if "LetsLapse.app/LetsLapse" in line:
            return line.split()[0]
    return None


def terminate(udid):
    pid = app_pid(udid)
    if pid:
        sh(["xcrun", "devicectl", "device", "process", "terminate", "--device", udid, "--pid", pid], check=False)
        print(f"terminated pid {pid}")
        time.sleep(1.5)
    else:
        print("app not running")


def pull_logs(udid, dest):
    os.makedirs(dest, exist_ok=True)
    sh(["xcrun", "devicectl", "device", "copy", "from", "--device", udid, *CONTAINER,
        "--source", LOGS_SUBDIR, "--destination", dest], check=False)
    return dest


def newest_console_log(udid):
    r = sh(["xcrun", "devicectl", "device", "info", "files", "--device", udid, *CONTAINER,
            "--subdirectory", LOGS_SUBDIR, "--username", "mobile"], check=False)
    names = re.findall(r"(console-\d{8}-\d{6}\.log)", r.stdout or "")
    return sorted(names)[-1] if names else None


def pairing_code(udid, deadline=40):
    """The remote listener's code from the newest console log, once it prints."""
    t0 = time.time()
    while time.time() - t0 < deadline:
        name = newest_console_log(udid)
        if name:
            with tempfile.TemporaryDirectory() as d:
                dest = os.path.join(d, name)
                sh(["xcrun", "devicectl", "device", "copy", "from", "--device", udid, *CONTAINER,
                    "--source", f"{LOGS_SUBDIR}/{name}", "--destination", dest], check=False)
                if os.path.exists(dest):
                    m = re.findall(r"code=(\d{6})", open(dest, errors="replace").read())
                    if m:
                        return m[-1], name
        time.sleep(2)
    return None, None


# ---------------------------------------------------------------- recording

def trace_path(scenario, tag, suffix):
    os.makedirs(TRACES, exist_ok=True)
    day = dt.date.today().isoformat()
    return os.path.join(TRACES, f"baseline-{scenario}-{day}-{git_sha()}-{tag}-{suffix}.trace")


def record(udid, template, output, seconds, env=None, extra_instruments=("os_signpost",)):
    if os.path.exists(output):
        shutil.rmtree(output)
    cmd = ["xcrun", "xctrace", "record", "--device", udid, "--template", template,
           "--output", output, "--time-limit", f"{seconds}s", "--no-prompt"]
    for name in extra_instruments:
        cmd += ["--instrument", name]
    for k, v in (env or {}).items():
        cmd += ["--env", f"{k}={v}"]
    cmd += ["--launch", "--", BUNDLE]
    print(f"▶ {template} {seconds}s → {os.path.basename(output)}")
    started = time.time()
    r = subprocess.run(cmd, text=True, capture_output=True, timeout=seconds + 120)
    tail = (r.stdout + r.stderr).strip().splitlines()[-3:]
    print("  " + " | ".join(t.strip() for t in tail), f"({time.time() - started:.0f}s)")
    if (r.returncode != 0 or not os.path.exists(output)) and extra_instruments:
        # A template that already carries the instrument refuses a second copy.
        print("  retrying without the extra instrument(s)")
        return record(udid, template, output, seconds, env=env, extra_instruments=())
    if r.returncode != 0 or not os.path.exists(output):
        raise SystemExit("xctrace failed")
    return output


# ---------------------------------------------------------------- the trace

def xctrace_export(trace, xpath):
    r = sh(["xcrun", "xctrace", "export", "--input", trace, "--xpath", xpath], check=False)
    return r.stdout if r.returncode == 0 else ""


def toc(trace):
    r = sh(["xcrun", "xctrace", "export", "--input", trace, "--toc"], check=False)
    return r.stdout or ""


class Rows:
    """One exported table, with xctrace's id/ref de-duplication resolved."""

    def __init__(self, xml_text):
        self.refs = {}
        self.rows = []
        if not xml_text.strip():
            return
        root = ET.fromstring(xml_text)
        for row in root.iter("row"):
            cells = []
            for cell in row:
                cells.append(self._resolve(cell))
            self.rows.append(cells)

    def _resolve(self, el):
        ref = el.get("ref")
        if ref is not None and ref in self.refs:
            return self.refs[ref]
        text = el.get("fmt") if el.get("fmt") is not None else (el.text or "").strip()
        value = (el.tag, text, el)
        if el.get("id") is not None:
            self.refs[el.get("id")] = value
        return value


def signposts(trace):
    """Intervals and events of the app's own signposter, seconds from trace start."""
    xml_text = xctrace_export(trace, '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]')
    out = []
    for cells in Rows(xml_text).rows:
        d = {}
        for tag, text, el in cells:
            d.setdefault(tag, text)
        name = d.get("name", "")
        if "com.regularsteven" not in d.get("subsystem", "") and "letslapse" not in d.get("subsystem", "").lower():
            continue
        start = _ns(cells, "start-time") if any(t == "start-time" for t, _, _ in cells) else _ns(cells, "event-time")
        dur = _ns(cells, "duration")
        out.append({"name": name, "kind": d.get("signpost-type", d.get("event-type", "")),
                    "t": start / 1e9 if start is not None else None,
                    "dur": dur / 1e9 if dur is not None else None,
                    "msg": d.get("message", "")})
    out.sort(key=lambda s: (s["t"] or 0))
    return out


def _ns(cells, tag):
    for t, text, el in cells:
        if t == tag:
            raw = el.text if el.text is not None else text
            try:
                return float(raw)
            except (TypeError, ValueError):
                m = re.match(r"([\d.]+)", text or "")
                return float(m.group(1)) * 1e9 if m else None
    return None


def main_thread_samples(trace):
    """(t seconds, weight ms) of every main-thread sample of the app."""
    xml_text = xctrace_export(trace, '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]')
    samples = []
    for cells in Rows(xml_text).rows:
        d = {t: text for t, text, _ in cells}
        if "LetsLapse" not in d.get("process", "") or "Main Thread" not in d.get("thread", ""):
            continue
        t = _ns(cells, "sample-time")
        w = _ns(cells, "weight")
        if t is not None:
            samples.append((t / 1e9, (w or 1e6) / 1e6))
    samples.sort()
    return samples


def busy(samples, t0, t1):
    return sum(w for t, w in samples if t0 <= t < t1) / 1000.0


def parse_trace(trace):
    print(f"\n== {os.path.basename(trace)}")
    posts = signposts(trace)
    samples = main_thread_samples(trace)
    first = samples[0][0] if samples else None
    by = {}
    for p in posts:
        by.setdefault(p["name"], []).append(p)
    for name in ("library walk", "library export", "picplace check", "free-up candidates",
                 "free-up listings", "free-up judge", "lens pin", "lens pin release",
                 "applyCaptureFormat", "AE settle", "focus settle"):
        for p in by.get(name, []):
            if p["dur"] is not None:
                print(f"  {name:22s} at {p['t']:7.2f}s  {p['dur']*1000:8.0f} ms")
    for name in ("thermal", "capture preview created", "settings appear", "focus tap"):
        for p in by.get(name, []):
            print(f"  {name:22s} at {p['t']:7.2f}s  {p['msg']}")
    # Photo phases: press → run start → fire → run flag off → recorded.
    presses = [p for p in by.get("shutter press", [])]
    for i, press in enumerate(presses, 1):
        nxt = presses[i]["t"] if i < len(presses) else float("inf")
        def after(name):
            xs = [p for p in by.get(name, []) if press["t"] <= p["t"] < nxt]
            return xs[0]["t"] if xs else None
        fire, flag_on, flag_off, rec = after("capture fire"), after("run flag on"), after("run flag off"), after("assets recorded")
        cells = [f"shot {i} {press['msg']:8s} press {press['t']:7.2f}s"]
        for label, t in (("→fire", fire), ("→flag on", flag_on), ("→flag off", flag_off), ("→recorded", rec)):
            cells.append(f"{label} {'%.2f' % (t - press['t']) if t else '   -'}")
        window_end = rec or flag_off or press["t"] + 3
        cells.append(f"main busy {busy(samples, press['t'], window_end)*1000:.0f} ms")
        print("  " + "  ".join(cells))
    if first is not None:
        print(f"  main thread: first sample {first:.2f}s; busy 0–5 s {busy(samples, first, first + 5)*1000:.0f} ms, "
              f"5–10 s {busy(samples, first + 5, first + 10)*1000:.0f} ms, samples {len(samples)}")
    for p in by.get("settings appear", []):
        print(f"  settings: main busy in the 3 s after appear {busy(samples, p['t'], p['t'] + 3)*1000:.0f} ms")
    if not posts:
        print("  (no app signposts in this trace — TOC follows)")
        print("  " + "\n  ".join(toc(trace).splitlines()[:40]))


# ---------------------------------------------------------------- the console log

def photo_phases(log_dir):
    """The plan's §7 snippet: press → fire → recorded per Photo shot, from console-*.log."""
    def t(s):
        h, m, x = s.split(":")
        return int(h) * 3600 + int(m) * 60 + float(x)
    rows = []
    for f in sorted(glob.glob(os.path.join(log_dir, "console-*.log"))):
        cur = None
        for line in open(f, errors="replace"):
            m = re.match(r"(\d\d:\d\d:\d\d\.\d+) \S+ +[\d.]+ (.*)", line)
            if not m:
                continue
            ts, msg = t(m.group(1)), m.group(2)
            if msg.startswith("optics: run pinned to") or msg.startswith("optics: run already on"):
                cur = {"press": ts, "file": os.path.basename(f), "at": m.group(1)}
            elif cur is not None:
                if msg.startswith("exposure: AE/AWB still settling") and "wait" not in cur:
                    cur["wait"] = ts
                elif msg.startswith("capture: photo") and "fire" not in cur:
                    cur["fire"] = ts
                    tm = re.search(r"thermal (\w+) · pressure (\w+)", msg)
                    cur["thermal"] = f"{tm.group(1)}/{tm.group(2)}" if tm else "?"
                    cur["lens"] = msg.split("—", 1)[1].split("·")[0].strip() if "—" in msg else ""
                elif msg.startswith("assets:") and "recorded" in msg and "fire" in cur:
                    cur["rec"] = ts
                    rows.append(cur)
                    cur = None
    return rows


def print_photo_phases(rows):
    if not rows:
        print("no Photo shots in these logs")
        return
    print(f"{'at':>12s} {'lens':12s} {'pin→fire':>9s} {'fire→rec':>9s} {'pin→rec':>8s}  thermal")
    for r in rows:
        print(f"{r['at']:>12s} {r['lens']:12s} {r['fire']-r['press']:9.2f} {r['rec']-r['fire']:9.2f} {r['rec']-r['press']:8.2f}  {r['thermal']}")
    for name, fn in (("pin→fire", lambda r: r["fire"] - r["press"]), ("fire→recorded", lambda r: r["rec"] - r["fire"]),
                     ("pin→recorded", lambda r: r["rec"] - r["press"])):
        v = [fn(r) for r in rows]
        print(f"{name}: n={len(v)} median={statistics.median(v):.2f}s min={min(v):.2f}s max={max(v):.2f}s")


def launch_lines(log_dir, newest_only=True):
    files = sorted(glob.glob(os.path.join(log_dir, "console-*.log")))
    if newest_only:
        files = files[-1:]
    for f in files:
        print(f"-- {os.path.basename(f)}")
        first = None
        for line in open(f, errors="replace"):
            m = re.match(r"(\d\d:\d\d:\d\d\.\d+) \S+ +[\d.]+ (.*)", line)
            if not m:
                continue
            if first is None:
                first = m.group(1)
            msg = m.group(2)
            if re.match(r"(thermal:|library: walked|library export:|picplace: check \(|picplace: free-up estimate|CameraPreview.makeUIView #1|✅ DidStartRunning|remote-listener advertising)", msg):
                print(f"   {m.group(1)}  {msg[:150]}")
        print(f"   (first line {first})")


# ---------------------------------------------------------------- scenarios

def scenario_A(udid, tag, repeat):
    outs = []
    for i in range(1, repeat + 1):
        terminate(udid)
        outs.append(record(udid, "App Launch", trace_path("A", tag, f"launch{i}"), 30))
        time.sleep(3)
    terminate(udid)
    outs.append(record(udid, "Time Profiler", trace_path("A", tag, "profile"), 30))
    logs = pull_logs(udid, f"/tmp/ll-logs-{tag}-A")
    launch_lines(logs, newest_only=False)
    for o in outs:
        parse_trace(o)


def scenario_B(udid, tag):
    outs = []
    for template, suffix in (("Time Profiler", "profile"), ("SwiftUI", "swiftui"), ("Animation Hitches", "hitches")):
        terminate(udid)
        outs.append(record(udid, template, trace_path("B-hook", tag, suffix), 25, env={"LL_TAB": "settings"}))
        time.sleep(3)
    logs = pull_logs(udid, f"/tmp/ll-logs-{tag}-B")
    launch_lines(logs)
    for o in outs:
        parse_trace(o)


def scenario_C(udid, tag, tele, template):
    probe = os.path.join(HERE, "remote_probe")
    if not os.access(probe, os.X_OK):
        raise SystemExit("build tools/remote_probe first (see the header of remote_probe.swift)")
    terminate(udid)
    out = trace_path("C", tag, template.lower().replace(" ", "-"))
    result = {}

    def drive():
        time.sleep(8)
        code, name = pairing_code(udid)
        if not code:
            result["error"] = "no pairing code in the console log — did the capture screen open?"
            return
        print(f"  pairing code {code} ({name}); driving {PHOTO_SCRIPT.format(tele=tele)}")
        r = subprocess.run([probe, code, PHOTO_SCRIPT.format(tele=tele)], text=True, capture_output=True, timeout=140)
        result["probe"] = (r.stdout + r.stderr)[-1500:]

    th = threading.Thread(target=drive, daemon=True)
    th.start()
    record(udid, template, out, 105)
    th.join(timeout=30)
    if "error" in result:
        print("  " + result["error"])
    elif "probe" in result:
        print("  probe: " + " | ".join(l for l in result["probe"].splitlines() if l.strip())[-600:])
    logs = pull_logs(udid, f"/tmp/ll-logs-{tag}-C")
    rows = photo_phases(logs)
    newest = sorted(glob.glob(os.path.join(logs, "console-*.log")))[-1:]
    print_photo_phases([r for r in rows if newest and r["file"] == os.path.basename(newest[0])])
    parse_trace(out)


def library_snapshot(udid):
    r = sh(["xcrun", "devicectl", "device", "info", "files", "--device", udid, *CONTAINER,
            "--subdirectory", "Library/Application Support/LetsLapse/Libraries", "--username", "mobile"], check=False)
    libs = re.findall(r"([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})", r.stdout or "")
    for lib in sorted(set(libs)):
        dest = f"/tmp/ll-perf-library-{lib[:8]}.json"
        sh(["xcrun", "devicectl", "device", "copy", "from", "--device", udid, *CONTAINER,
            "--source", f"Library/Application Support/LetsLapse/Libraries/{lib}/Projects/library.json",
            "--destination", dest], check=False)
        if os.path.exists(dest):
            data = open(dest, "rb").read()
            try:
                d = json.loads(data)
                counts = f"{d.get('generatedCaptures')} captures {d.get('generatedBlends')} blends"
            except Exception:
                counts = "(not a generated export)"
            print(f"library {lib}: {counts}, {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()[:16]}…")


def install(udid, app):
    terminate(udid)
    print(sh(["xcrun", "devicectl", "device", "install", "app", "--device", udid, app]).stdout.strip().splitlines()[-1])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", help="UDID or a part of the marketing name, e.g. '18 Pro'")
    ap.add_argument("--tag", default="run", help="label for the trace file names and the log folder")
    ap.add_argument("--repeat", type=int, default=3, help="A: App Launch recordings (default 3)")
    ap.add_argument("--tele", default="4", help="C: the tele stop's display factor (18 Pro 4, 16 Pro 5, 12 Pro 2)")
    ap.add_argument("--template", default="Time Profiler", help="C: the template (Time Profiler, Animation Hitches, SwiftUI)")
    ap.add_argument("--app", help="install: the .app to install")
    ap.add_argument("command", choices=["A", "B", "C", "logs", "library", "install", "parse"])
    ap.add_argument("paths", nargs="*", help="parse: trace files")
    args = ap.parse_args()
    if args.command == "parse":
        for p in args.paths:
            parse_trace(p)
        return
    udid = resolve_device(args.device or "")
    if args.command == "A":
        scenario_A(udid, args.tag, args.repeat)
    elif args.command == "B":
        scenario_B(udid, args.tag)
    elif args.command == "C":
        scenario_C(udid, args.tag, args.tele, args.template)
    elif args.command == "logs":
        logs = pull_logs(udid, f"/tmp/ll-logs-{args.tag}")
        launch_lines(logs)
        print_photo_phases(photo_phases(logs))
    elif args.command == "library":
        library_snapshot(udid)
    elif args.command == "install":
        install(udid, args.app)


if __name__ == "__main__":
    main()
