#!/usr/bin/env python3
"""What a shape field shoot taught us — one table from a folder of projects.

Walks LetsLapse project folders (a library's ``Projects/`` or a set pulled off
a phone with ``devicectl device copy from``), and for each Photo capture joins:

  shapes.json          — the register (captured / detected / manual shapes) and
                         the viewfinder trail: the dials, samples landed, kept,
                         dismissed, what the live and file passes refused
  source/capture_log.json — the capture's conditions: stop ("5×"), whether it
                         is a lens or a digital crop, the physical lens, field of
                         view, format (jpeg / jpeg-flat / dng), thermal state at
                         the shutter and at the end, camera pressure, focus, ISO
                         and shutter, battery, and the shape dials
  a fresh pass         — ``lapse shapes <frame> --json`` (file profile), so
                         every shot is judged by the same detector today

and prints per-shot rows plus strike ratios grouped by stop, lens crop, format,
thermal state and the dials. A "strike" is a captured shape (kept on the
viewfinder) that the file pass confirms (bounds IoU ≥ 0.4, same kind — the
register's own reconcile rule). Shots with the toggle off contribute to the
"file found anything" column only.

Usage:
  python3 shape_field_report.py <projects-dir or project-dir ...>
      [--lapse Kit/.build/release/lapse] [--tag "Shape testing"]
      [--library Projects/library.json] [--no-rerun] [--csv out.csv]

Stdlib only. ``--tag`` needs ``--library`` (or a ``library.json`` in the
projects dir) and narrows the walk to projects carrying that tag.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import subprocess
import sys
from collections import defaultdict


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def bbox(shape):
    """The register's bounds rule (ShapeDetector.bbox): corners for quads,
    the rotated ellipse's extent otherwise. Fractions of frame width."""
    corners = shape.get("corners")
    if corners:
        xs = [c[0] for c in corners]
        ys = [c[1] for c in corners]
        return min(xs), min(ys), max(xs), max(ys)
    cx, cy = shape["centre"]
    a, b = shape["majorAxis"] / 2, shape["minorAxis"] / 2
    c, s = math.cos(shape.get("rotation", 0)), math.sin(shape.get("rotation", 0))
    hw = math.sqrt(a * a * c * c + b * b * s * s)
    hh = math.sqrt(a * a * s * s + b * b * c * c)
    return cx - hw, cy - hh, cx + hw, cy + hh


def iou(p, q):
    x0, y0, x1, y1 = max(p[0], q[0]), max(p[1], q[1]), min(p[2], q[2]), min(p[3], q[3])
    if x1 <= x0 or y1 <= y0:
        return 0.0
    inter = (x1 - x0) * (y1 - y0)
    union = (p[2] - p[0]) * (p[3] - p[1]) + (q[2] - q[0]) * (q[3] - q[1]) - inter
    return inter / union if union > 0 else 0.0


def confirmed(shape, candidates, threshold=0.4):
    box = bbox(shape)
    return any(c["kind"] == shape["kind"] and iou(box, bbox(c)) >= threshold for c in candidates)


def when(created):
    """library.json stamps Apple reference dates (seconds since 2001)."""
    if isinstance(created, (int, float)):
        import datetime
        return (datetime.datetime(2001, 1, 1) + datetime.timedelta(seconds=created)).strftime("%m-%d %H:%M")
    return str(created or "")[:16]


def frame_path(folder):
    source = os.path.join(folder, "source")
    if not os.path.isdir(source):
        return None
    names = sorted(n for n in os.listdir(source) if n.startswith("frame-") and n.rsplit(".", 1)[-1].lower() in ("jpg", "jpeg", "heic", "dng"))
    return os.path.join(source, names[0]) if names else None


def rerun(lapse, frame):
    try:
        out = subprocess.run([lapse, "shapes", frame, "--json"], capture_output=True, text=True, timeout=300)
        return json.loads(out.stdout) if out.returncode == 0 and out.stdout.strip() else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def fmt_exposure(entry):
    if not entry:
        return ""
    parts = []
    if entry.get("iso"):
        parts.append("ISO %.0f" % entry["iso"])
    t = entry.get("exposureDuration")
    if t:
        parts.append("%.1f s" % t if t >= 1 else "1/%.0f" % (1 / t))
    return " ".join(parts)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", help="project folders, or a folder of them")
    ap.add_argument("--lapse", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Kit", ".build", "release", "lapse"))
    ap.add_argument("--tag", help="only projects carrying this tag (needs library.json)")
    ap.add_argument("--library", help="library.json to read tags and names from")
    ap.add_argument("--no-rerun", action="store_true", help="skip today's detector pass")
    ap.add_argument("--csv", help="write the per-shot rows here")
    args = ap.parse_args()

    folders = []
    for p in args.paths:
        if os.path.isfile(os.path.join(p, "shapes.json")) or os.path.isdir(os.path.join(p, "source")):
            folders.append(p)
        elif os.path.isdir(p):
            folders += [os.path.join(p, n) for n in sorted(os.listdir(p)) if os.path.isdir(os.path.join(p, n, "source"))]
    library = None
    lib_path = args.library or next((os.path.join(p, "library.json") for p in args.paths if os.path.isfile(os.path.join(p, "library.json"))), None)
    if lib_path:
        library = load_json(lib_path)
    meta = {}
    if library:
        captures = library.get("captures", library) if isinstance(library, dict) else library
        for c in captures:
            meta[str(c.get("id", "")).upper()] = c
    if args.tag:
        def tags(c):
            return (c.get("sceneTags") or []) + (c.get("tags") or [])
        folders = [f for f in folders if args.tag in tags(meta.get(os.path.basename(f).upper(), {}))]

    rows = []
    for folder in folders:
        pid = os.path.basename(folder)
        register = load_json(os.path.join(folder, "shapes.json"))
        session = load_json(os.path.join(folder, "source", "capture_log.json"))
        frame = frame_path(folder)
        info = meta.get(pid.upper(), {})
        cond = (session or {}).get("conditions") or {}
        trail = (register or {}).get("viewfinder") or {}
        shapes = (register or {}).get("shapes") or []
        captured = [s for s in shapes if s.get("source") == "captured"]
        detected = [s for s in shapes if s.get("source") == "detected"]
        manual = [s for s in shapes if s.get("source") == "manual"]
        today = None
        if frame and not args.no_rerun and os.path.exists(args.lapse):
            today = rerun(args.lapse, frame)
        today_shapes = (today or {}).get("shapes") or []
        hits = sum(1 for s in captured if confirmed(s, today_shapes)) if today else None
        first = ((session or {}).get("frames") or [{}])[0]
        file_diag = trail.get("file") or {}
        row = {
            "id": pid[:8],
            "when": when(info.get("createdAt")),
            "name": info.get("name") or info.get("originalName") or "",
            "mode": (session or {}).get("captureMode") or "",
            "stop": cond.get("stop") or "",
            "stopKind": cond.get("stopKind") or "",
            "lens": cond.get("lens") or "",
            "lensCrop": cond.get("lensCrop"),
            "fov": cond.get("horizontalFieldOfView") or trail.get("horizontalFieldOfView"),
            "format": cond.get("format") or "",
            "thermal": cond.get("thermalState") or "",
            "thermalEnd": cond.get("thermalStateAtEnd") or "",
            "pressure": cond.get("systemPressure") or "",
            "focus": (cond.get("focusMode") or "") + (" pinned" if cond.get("focusPinnedByTap") else ""),
            "lensPosition": cond.get("lensPosition"),
            "exposure": fmt_exposure(first),
            "battery": cond.get("batteryLevel"),
            "dials": trail.get("search") and "%s/%s/%s" % (trail["search"].get("family"), trail["search"].get("sensitivity"), trail["search"].get("size")) or cond.get("shapeSearch") or "",
            "toggle": "on" if trail else "off",
            "samples": trail.get("samples"),
            "samplesWithShapes": trail.get("samplesWithShapes"),
            "kept": trail.get("kept"),
            "dismissed": trail.get("dismissed"),
            "captured": len(captured),
            "detected": len(detected),
            "manual": len(manual),
            "confirmed": hits,
            "fileToday": len(today_shapes) if today else None,
            "fileMs": (today or {}).get("diagnostics", {}).get("milliseconds"),
            "fileRefusals": "; ".join("%s %d%% %s" % (r["kind"], round(r["size"] * 100), r["reason"]) for r in (file_diag.get("refusals") or [])[:3]),
        }
        rows.append(row)

    if not rows:
        print("no projects found", file=sys.stderr)
        return 1

    cols = ["id", "when", "stop", "stopKind", "lensCrop", "format", "thermal", "thermalEnd", "pressure", "focus", "exposure",
            "dials", "toggle", "samples", "samplesWithShapes", "kept", "dismissed", "captured", "detected", "confirmed", "fileToday"]
    widths = {c: max(len(c), *(len(str(r.get(c, "") if r.get(c) is not None else "")) for r in rows)) for c in cols}
    print("  ".join(c.ljust(widths[c]) for c in cols))
    for r in rows:
        print("  ".join(str(r.get(c, "") if r.get(c) is not None else "").ljust(widths[c]) for c in cols))
    print()

    def group(key, label):
        buckets = defaultdict(lambda: {"shots": 0, "on": 0, "kept": 0, "confirmed": 0, "fileHit": 0, "rerun": 0})
        for r in rows:
            b = buckets[r.get(key) or "?"]
            b["shots"] += 1
            if r["toggle"] == "on":
                b["on"] += 1
            b["kept"] += r["captured"]
            if r["confirmed"] is not None:
                b["confirmed"] += r["confirmed"]
            if r["fileToday"] is not None:
                b["rerun"] += 1
                if r["fileToday"] > 0:
                    b["fileHit"] += 1
        print("by %s:" % label)
        print("  %-28s %5s %5s %5s %9s %s" % ("", "shots", "on", "kept", "confirmed", "file found ≥1"))
        for k, b in sorted(buckets.items(), key=lambda kv: -kv[1]["shots"]):
            conf = "%d (%d%%)" % (b["confirmed"], 100 * b["confirmed"] / b["kept"]) if b["kept"] else "—"
            hit = "%d/%d" % (b["fileHit"], b["rerun"]) if b["rerun"] else "—"
            print("  %-28s %5d %5d %5d %9s %s" % (str(k)[:28], b["shots"], b["on"], b["kept"], conf, hit))
        print()

    group("stop", "stop")
    group("stopKind", "lens kind (optical / sensor-crop / digital)")
    group("format", "format")
    group("thermal", "thermal state at the shutter")
    group("pressure", "camera pressure")
    group("dials", "dials")
    group("focus", "focus")

    if args.csv:
        with open(args.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
        print("wrote", args.csv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
