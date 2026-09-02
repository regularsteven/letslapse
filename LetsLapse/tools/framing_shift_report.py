#!/usr/bin/env python3
"""Framing-shift audit straight off a project's source frames — and a
pattern finder across many projects at once.

The 2026-09-02 brief: on the iPhone 12 Pro the framing steps ~50 px vertically
under thermal load and every frame after that is misaligned with the ones
before. The engine's own records were spotless at the events, so only the
pixels can say what happened; this tool measures them and then joins each
event against everything the shoot *did* record, so the cause can be
attributed rather than guessed:

  * per-frame translation vs the previous frame (`cv2.phaseCorrelate`, on a
    1/4-scale JPEG draft decode — sub-pixel, ~15 ms/frame, whole frame so a
    static tripod scene dominates the peak);
  * the integrated offset from the run start, so a step is classified as
    **stayed** (new baseline) or **transient** (returned);
  * per-frame EXIF f-number and pixel dimensions — a constituent hand-off
    changes the aperture (12 Pro: wide f/1.6, ultra-wide f/2.4, tele f/2.0),
    and any format/crop change changes the dimensions; when both are constant
    across a step the frame buffer did not change — the scene moved inside
    it, which is the optical signature;
  * `capture_log.json` per window: thermal state at window open/close (so a
    transition inside the event window is visible), blend count, the
    alignment gate's own `rejectedByAlignment` / `peakAlignmentShiftPixels`,
    and the `issues[]` trail (thermal / framingGlitch / framingChanged /
    constituentSwitch) within ±2 windows.

  tools/.venv/bin/python tools/framing_shift_report.py <project-dir> [...]
  tools/.venv/bin/python tools/framing_shift_report.py --root /Volumes/letslapse/Projects --all
  tools/.venv/bin/python tools/framing_shift_report.py --root ... --all --device iPhone13,3 --min-frames 100

Per project: header, event table, greppable `FRAMING SHIFT PASS/FAIL`. With
several projects the run ends with a cross-project pattern table (device ×
camera × mode × blend × thermal state at the events) — that table is the
answer to "is it one lens, one shoot type, one thermal state?".

Axis note: shifts are reported in STORED-pixel space (dx along the stored
width, dy along the stored height). Portrait captures are stored 3024×4032,
so dy is the gravity axis there; landscape captures store 4032×3024 and the
gravity axis is still dy because the sensor's long side is horizontal. An
OIS sag is gravity-aligned: |dy| large, |dx| ≈ 0.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

FRAME_RE = re.compile(r"^frame-(\d{5})\.jpg$")
SCALE = 4
FNUMBER_TAG = 0x829D
EXIF_IFD_TAG = 0x8769
THERMAL_RANK = {"unknown": -1, "?": -1, "nominal": 0, "fair": 1, "serious": 2, "critical": 3}


# ---------------------------------------------------------------- frame IO

def discover_frames(source: Path) -> list[tuple[int, Path]]:
    out = []
    for name in os.listdir(source):
        m = FRAME_RE.match(name)
        if m:
            out.append((int(m.group(1)), source / name))
    out.sort()
    return out


def load_frame(path: Path):
    """1/4-scale luma (JPEG DCT draft decode — cheap) + f-number + full size."""
    im = Image.open(path)
    full = im.size
    fnumber = None
    try:
        exif = im.getexif()
        sub = exif.get_ifd(EXIF_IFD_TAG)
        if FNUMBER_TAG in sub:
            fnumber = float(sub[FNUMBER_TAG])
    except Exception:  # noqa: BLE001 — EXIF is optional
        pass
    im.draft("L", (full[0] // SCALE, full[1] // SCALE))
    luma = np.asarray(im.convert("L"), dtype=np.float32)
    return luma, fnumber, full


def measure_chunk(args):
    """Consecutive-pair shifts for frames[lo..hi], where lo-1 is the anchor."""
    paths, lo, hi = args
    results = []
    prev = load_frame(paths[lo - 1]) if lo > 0 else None
    window = None
    for i in range(lo, hi):
        cur = load_frame(paths[i])
        luma, fnumber, size = cur
        if prev is None or prev[0].shape != luma.shape:
            results.append((i, 0.0, 0.0, 1.0, fnumber, size, prev is not None))
        else:
            if window is None or window.shape != luma.shape:
                window = cv2.createHanningWindow((luma.shape[1], luma.shape[0]), cv2.CV_32F)
            (dx, dy), response = cv2.phaseCorrelate(prev[0], luma, window)
            results.append((i, dx * SCALE, dy * SCALE, float(response), fnumber, size, False))
        prev = cur
    return results


def measure_project(paths: list[Path], workers: int):
    n = len(paths)
    chunk = max(32, (n + workers - 1) // workers)
    jobs = [(paths, lo, min(n, lo + chunk)) for lo in range(0, n, chunk)]
    rows = []
    with ProcessPoolExecutor(max_workers=workers) as pool:
        for part in pool.map(measure_chunk, jobs):
            rows.extend(part)
    rows.sort()
    return rows


# ---------------------------------------------------------------- capture log

def load_log(source: Path) -> dict:
    path = source / "capture_log.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except Exception:  # noqa: BLE001
        return {}


def log_frame_map(log: dict) -> dict[int, dict]:
    return {f.get("frameIndex"): f for f in log.get("frames", []) if "frameIndex" in f}


def thermal_profile(log: dict) -> tuple[str, Counter]:
    counts = Counter()
    for f in log.get("frames", []):
        counts[f.get("window", {}).get("thermalStateAtClose", "?")] += 1
    peak = max(counts, key=lambda s: THERMAL_RANK.get(s, -1)) if counts else "?"
    return peak, counts


def has_gate(log: dict) -> bool:
    """The alignment gate shipped 2026-08-24; runs before it carry no
    framingGlitch/thermal issues by construction, not by cleanliness."""
    return any(i.get("kind") in ("thermal", "framingGlitch", "framingChanged") for i in log.get("issues", [])) \
        or any("rejectedByAlignment" in f.get("window", {}) for f in log.get("frames", []))


# ---------------------------------------------------------------- analysis

def analyse(project: Path, args) -> dict | None:
    source = project / "source"
    frames = discover_frames(source)
    if len(frames) < args.min_frames:
        return None
    log = load_log(source)
    device = log.get("deviceModel", "?")
    if args.device and device != args.device:
        return None
    paths = [p for _, p in frames]
    indices = [i for i, _ in frames]
    rows = measure_project(paths, args.workers)
    by_frame = log_frame_map(log)
    issues = log.get("issues", [])
    issues_by_window = defaultdict(list)
    for i in issues:
        issues_by_window[i.get("windowIndex", -99)].append(i)

    # Integrate consecutive shifts into an offset from the run start.
    cum_x = cum_y = 0.0
    offsets = []
    for (_, dx, dy, resp, _, _, _) in rows:
        # Sub-pixel jitter is measurement noise; integrating it over a
        # thousand frames walks the baseline. Only real steps move it.
        if resp >= args.min_response and max(abs(dx), abs(dy)) >= 1.0:
            cum_x += dx
            cum_y += dy
        offsets.append((cum_x, cum_y))

    events = []
    for k, (i, dx, dy, resp, fnumber, size, size_changed) in enumerate(rows):
        mag = max(abs(dx), abs(dy))
        if mag < args.threshold or resp < args.min_response:
            continue
        frame = indices[i]
        before = offsets[k - 1] if k > 0 else (0.0, 0.0)
        after = offsets[min(len(offsets) - 1, k + args.settle)]
        settled_dx = after[0] - before[0]
        settled_dy = after[1] - before[1]
        stayed = max(abs(settled_dx), abs(settled_dy)) >= args.threshold / 2
        # A step that lands back on the run-start framing is the lens
        # re-centring, not a new baseline — worth telling apart from a sag.
        back_home = stayed and max(abs(after[0]), abs(after[1])) < args.threshold / 2
        prev_row = rows[k - 1] if k > 0 else None
        lens_changed = prev_row is not None and prev_row[4] != fnumber
        entry = by_frame.get(frame, {})
        win = entry.get("window", {})
        near = []
        for w in range(frame - 3, frame + 2):  # windowIndex = frameIndex - 1
            for iss in issues_by_window.get(w, []):
                near.append(f"w{w}:{iss.get('kind')}({iss.get('detail','')[:40]})")
        single_axis = min(abs(dx), abs(dy)) <= 0.25 * mag
        events.append({
            "frame": frame, "dx": dx, "dy": dy, "response": resp,
            "stayed": stayed, "backHome": back_home, "settled": (settled_dx, settled_dy),
            "fnumber": fnumber, "lensChanged": lens_changed, "sizeChanged": size_changed,
            "size": size, "singleAxis": single_axis,
            "thermalStart": win.get("thermalStateAtStart"), "thermalClose": win.get("thermalStateAtClose"),
            "blend": entry.get("blendCount"), "gateRejected": win.get("rejectedByAlignment"),
            "gatePeak": win.get("peakAlignmentShiftPixels"), "capturedAt": entry.get("capturedAt"),
            "issuesNear": near,
        })

    # Ghost suspects: a stacked window where only SOME frames sagged does not
    # step — it doubles its edges, and the frame-to-frame correlation peak
    # collapses (E9D52934 windows 128–132: response 0.37–0.48 against ~0.73
    # either side, zero measured shift). Flag responses well below the local
    # median; scene changes dip too, so this is a WARN list, not a verdict.
    responses = np.array([r[3] for r in rows], dtype=np.float64)
    ghosts = []
    half = args.ghost_window // 2
    for k in range(1, len(rows)):
        lo, hi = max(0, k - half), min(len(rows), k + half + 1)
        local = np.median(np.concatenate([responses[lo:k], responses[k + 1:hi]])) if hi - lo > 2 else responses[k]
        if local > 0 and responses[k] < args.ghost_ratio * local and responses[k] < 0.9:
            entry = by_frame.get(indices[k], {})
            ghosts.append({"frame": indices[k], "response": float(responses[k]), "local": float(local),
                           "thermal": entry.get("window", {}).get("thermalStateAtClose"),
                           "blend": entry.get("blendCount")})

    fnumbers = Counter(r[4] for r in rows)
    sizes = Counter(r[5] for r in rows)
    peak, thermal_counts = thermal_profile(log)
    return {
        "project": project.name, "device": device, "camera": log.get("cameraName", "?"),
        "mode": log.get("captureMode", "?"), "blendMode": str(log.get("blendMode", "?")),
        "interval": log.get("intervalSeconds"), "startedAt": log.get("startedAt", "?"),
        "endReason": log.get("endReason"), "frames": len(rows), "gate": has_gate(log),
        "thermalPeak": peak, "thermalCounts": thermal_counts,
        "fnumbers": {str(k): v for k, v in fnumbers.items()},
        "sizes": {f"{w}x{h}": v for (w, h), v in sizes.items()}, "events": events, "ghosts": ghosts,
        "maxAbsOffset": max((max(abs(x), abs(y)) for x, y in offsets), default=0.0),
        "finalOffset": offsets[-1] if offsets else (0.0, 0.0),
    }


# ---------------------------------------------------------------- reporting

def fmt_thermal(counts: Counter) -> str:
    order = sorted(counts, key=lambda s: THERMAL_RANK.get(s, -1))
    return " ".join(f"{s}={counts[s]}" for s in order)


def report_project(r: dict, verbose: bool) -> None:
    print(f"=== {r['project']}")
    print(f"    {r['device']} · {r['camera']} · mode={r['mode']} blend={r['blendMode']} "
          f"interval={r['interval']}s · frames={r['frames']} · started {r['startedAt'][:16]} · "
          f"end={r['endReason']} · gate={'yes' if r['gate'] else 'pre-gate'}")
    print(f"    thermal: peak={r['thermalPeak']} [{fmt_thermal(r['thermalCounts'])}]")
    print(f"    lens f-numbers seen: {dict(r['fnumbers'])} · sizes: {dict(r['sizes'])}")
    print(f"    max offset from start: {r['maxAbsOffset']:.1f} px · final offset "
          f"dx={r['finalOffset'][0]:.1f} dy={r['finalOffset'][1]:.1f}")
    if r["events"]:
        print("    kind: STAYED = new baseline · RE-CENTRED = back on the run-start framing · transient = returned within --settle frames")
    if r["ghosts"]:
        shown = ", ".join(f"{g['frame']}({g['response']:.2f}/{g['local']:.2f},{g['thermal'] or 'n/a'})" for g in r["ghosts"][:20])
        more = f" … +{len(r['ghosts']) - 20}" if len(r["ghosts"]) > 20 else ""
        print(f"    GHOST SUSPECTS (response/local-median, thermal) — {len(r['ghosts'])}: {shown}{more}")
    if not r["events"]:
        print(f"FRAMING SHIFT PASS {r['project']} — no step ≥ threshold in {r['frames']} frames")
        return
    print(f"    {'frame':>6} {'dx':>7} {'dy':>7} {'resp':>5} {'kind':<9} {'thermal (win open→close)':<26} "
          f"{'blend':>5} {'gate':<10} lens/size  issues nearby")
    for e in r["events"]:
        kind = ("RE-CENTRED" if e.get("backHome") else "STAYED") if e["stayed"] else "transient"
        thermal = f"{e['thermalStart']}→{e['thermalClose']}" if e["thermalStart"] else "n/a"
        gate = (f"rej{e['gateRejected']}/{e['gatePeak']:.0f}px" if e.get("gatePeak") else
                ("kept" if e.get("gateRejected") else "-"))
        lens = ("LENS-CHANGED" if e["lensChanged"] else f"f/{e['fnumber']}") + \
               (" SIZE-CHANGED" if e["sizeChanged"] else "")
        axis = "" if e["singleAxis"] else " (2-axis)"
        near = "; ".join(e["issuesNear"]) if e["issuesNear"] else "-"
        print(f"    {e['frame']:>6} {e['dx']:>7.1f} {e['dy']:>7.1f} {e['response']:>5.2f} {kind:<9} "
              f"{thermal:<26} {str(e['blend'] or '-'):>5} {gate:<10} {lens}{axis}  {near}")
    stayed = sum(1 for e in r["events"] if e["stayed"])
    print(f"FRAMING SHIFT FAIL {r['project']} — {len(r['events'])} step(s), {stayed} stayed, "
          f"max {max(max(abs(e['dx']), abs(e['dy'])) for e in r['events']):.0f} px")


def report_pattern(results: list[dict]) -> None:
    print()
    print("=" * 100)
    print("PATTERN — one row per project (steps ≥ threshold; thermal = state of the window each step landed in)")
    print(f"{'project':<8} {'device':<11} {'camera':<22} {'mode':<8} {'blend':<11} {'int':>4} {'frames':>6} "
          f"{'gate':<8} {'peak':<8} {'steps':>5} {'stayed':>6} {'max px':>6} {'ghosts':>6}  thermal@steps            lens-change  axis")
    for r in sorted(results, key=lambda r: (r["device"], r["startedAt"])):
        ev = r["events"]
        thermal_at = Counter(e["thermalClose"] or "n/a" for e in ev)
        lens_changes = sum(1 for e in ev if e["lensChanged"] or e["sizeChanged"])
        mx = max((max(abs(e["dx"]), abs(e["dy"])) for e in ev), default=0.0)
        softness = "single-axis" if ev and all(e["singleAxis"] for e in ev) else ("mixed" if ev else "-")
        print(f"{r['project'][:8]:<8} {r['device']:<11} {r['camera'][:22]:<22} {r['mode']:<8} {r['blendMode']:<11} "
              f"{str(r['interval'] or ''):>4} {r['frames']:>6} {'yes' if r['gate'] else 'pre':<8} "
              f"{r['thermalPeak']:<8} {len(ev):>5} {sum(1 for e in ev if e['stayed']):>6} {mx:>6.0f} {len(r['ghosts']):>6}  "
              f"{fmt_thermal(thermal_at) or '-':<24} {lens_changes:<11} {softness}")

    # Group: which combination produces stayed steps?
    print()
    print("BY DEVICE × THERMAL STATE AT STEP (stayed steps only):")
    grouped = Counter()
    exposure = Counter()
    for r in results:
        for e in r["events"]:
            if e["stayed"]:
                grouped[(r["device"], e["thermalClose"] or "n/a")] += 1
        for f in r["thermalCounts"]:
            exposure[(r["device"], f)] += r["thermalCounts"][f]
    for (device, state) in sorted(exposure, key=lambda k: (k[0], THERMAL_RANK.get(k[1], -1))):
        n = grouped.get((device, state), 0)
        print(f"    {device:<11} {state:<9} stayed-steps={n:<3} over {exposure[(device, state)]} frames captured in that state")
    print()
    print("BY CAMERA (device, camera → projects with stayed steps / projects measured):")
    per_cam = defaultdict(lambda: [0, 0])
    for r in results:
        key = (r["device"], r["camera"])
        per_cam[key][1] += 1
        if any(e["stayed"] for e in r["events"]):
            per_cam[key][0] += 1
    for key in sorted(per_cam):
        print(f"    {key[0]:<11} {key[1]:<24} {per_cam[key][0]}/{per_cam[key][1]}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("projects", nargs="*", type=Path, help="project directories (each with source/frame-NNNNN.jpg)")
    ap.add_argument("--root", type=Path, help="projects root, used with --all")
    ap.add_argument("--all", action="store_true", help="scan every project under --root")
    ap.add_argument("--device", help="only projects whose capture_log deviceModel matches (e.g. iPhone13,3)")
    ap.add_argument("--min-frames", type=int, default=50)
    ap.add_argument("--threshold", type=float, default=8.0, help="step size in full-res px that counts as an event")
    ap.add_argument("--min-response", type=float, default=0.3, help="phaseCorrelate response floor for a trusted shift")
    ap.add_argument("--settle", type=int, default=5, help="frames after a step over which 'stayed' is judged")
    ap.add_argument("--ghost-window", type=int, default=15, help="frames of context for the ghost (response-dip) detector")
    ap.add_argument("--ghost-ratio", type=float, default=0.7, help="response below this × local median = ghost suspect")
    ap.add_argument("--workers", type=int, default=max(2, (os.cpu_count() or 4) - 2))
    ap.add_argument("--json", type=Path, help="also write the full per-project results here")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    projects = list(args.projects)
    if args.all:
        if not args.root:
            ap.error("--all needs --root")
        projects += sorted(p for p in args.root.iterdir() if (p / "source").is_dir())
    if not projects:
        ap.error("no projects given")

    results = []
    for project in projects:
        try:
            r = analyse(project, args)
        except Exception as exc:  # noqa: BLE001 — keep the sweep going
            print(f"=== {project.name}: FAILED {exc}", file=sys.stderr)
            continue
        if r is None:
            continue
        report_project(r, args.verbose)
        results.append(r)
        sys.stdout.flush()
    if len(results) > 1:
        report_pattern(results)
    if args.json:
        args.json.write_text(json.dumps(results, indent=1))
    return 1 if any(r["events"] for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
