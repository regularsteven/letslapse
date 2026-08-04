#!/usr/bin/env python3
"""
capture_metrics.py — the measurement harness from the Camera Capture
Experience brief (§2). Reproduces the baseline numbers from an iOS screen
recording and re-measures after each landed change.

The core principle: iOS screen recordings are VFR and only store a frame
when the screen changes, so gaps between presentation timestamps (PTS) ARE
the periods where the screen did not update. Nothing here re-encodes to
constant frame rate — that would destroy the signal.

Setup (one-time; needs ffmpeg/ffprobe on PATH, both present via Homebrew):

    cd LetsLapse/tools
    python3 -m venv .venv
    .venv/bin/pip install numpy opencv-python-headless
    source .venv/bin/activate

Workflow:

    # 1. Decode frames + PTS (full resolution; crops are taken at analysis time)
    python3 capture_metrics.py extract recording.mp4 --out work/

    # 2. Frame-interval statistics for a segment (e.g. the LetsLapse window)
    python3 capture_metrics.py intervals work/ --segment 22.0:33.0

    # 3. Live-preview change signal over a fixed central crop
    python3 capture_metrics.py preview-delta work/ --crop 300,600,600,900 --segment 22.0:33.0

    # 4. Lens-chip selection indicator (HSV amber mask): count, centroid,
    #    state changes, and no-selection limbo windows
    python3 capture_metrics.py chips work/ --crop 120,2050,900,120 --segment 22.0:33.0

    # 5. Exposure/focus settle time after a switch
    python3 capture_metrics.py settle work/ --crop 300,600,600,900 --tap 26.438

Crops are x,y,w,h in source pixels. Validate the harness against the
reference recording (the 35.7 s three-app cycle from the brief) and confirm
it reproduces §3 before trusting it on new captures.
"""

import argparse
import csv
import json
import math
import os
import subprocess
import sys

# ---------------------------------------------------------------------------
# Lazy imports with a clear bootstrap message


def _load_np_cv2():
    try:
        import numpy as np  # noqa
        import cv2  # noqa
        return np, cv2
    except ImportError as exc:
        sys.exit(
            f"Missing dependency: {exc.name}.\n"
            "Bootstrap:  python3 -m venv .venv && "
            ".venv/bin/pip install numpy opencv-python-headless\n"
            "then run via .venv/bin/python3 (or activate the venv)."
        )


# ---------------------------------------------------------------------------
# Extraction


def cmd_extract(args):
    out = args.out
    os.makedirs(os.path.join(out, "frames"), exist_ok=True)

    # PTS first — the timing signal.
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v",
         "-show_entries", "frame=pts_time", "-of", "csv=p=0", args.recording],
        capture_output=True, text=True, check=True)
    pts = [float(line.split(",")[0])
           for line in probe.stdout.strip().splitlines() if line.strip().rstrip(",")]
    with open(os.path.join(out, "pts.csv"), "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["frame", "pts_time"])
        for i, t in enumerate(pts, start=1):
            writer.writerow([i, f"{t:.6f}"])

    # Frames second — full resolution, one JPEG per *stored* frame (-vsync 0).
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", args.recording,
         "-vsync", "0", "-q:v", "2",
         os.path.join(out, "frames", "%05d.jpg")],
        check=True)

    n_frames = len(os.listdir(os.path.join(out, "frames")))
    if n_frames != len(pts):
        print(f"WARNING: {n_frames} frames but {len(pts)} PTS entries — "
              "frame N maps to pts row N; investigate before trusting results.")
    with open(os.path.join(out, "meta.json"), "w") as fh:
        json.dump({"recording": os.path.abspath(args.recording),
                   "frames": n_frames, "pts_entries": len(pts)}, fh, indent=2)
    print(f"Extracted {n_frames} frames, {len(pts)} PTS entries → {out}")


# ---------------------------------------------------------------------------
# Shared helpers


def load_pts(workdir):
    path = os.path.join(workdir, "pts.csv")
    rows = []
    with open(path) as fh:
        reader = csv.reader(fh)
        next(reader)
        for frame, t in reader:
            rows.append((int(frame), float(t)))
    return rows


def frames_in_segment(pts, segment):
    if segment is None:
        return pts
    start, end = segment
    return [(f, t) for (f, t) in pts if start <= t <= end]


def parse_segment(text):
    if not text:
        return None
    start, end = text.split(":")
    return float(start), float(end)


def parse_crop(text):
    x, y, w, h = (int(v) for v in text.split(","))
    return x, y, w, h


def frame_path(workdir, frame):
    return os.path.join(workdir, "frames", f"{frame:05d}.jpg")


def load_crop(cv2, workdir, frame, crop):
    img = cv2.imread(frame_path(workdir, frame))
    if img is None:
        return None
    if crop:
        x, y, w, h = crop
        img = img[y:y + h, x:x + w]
    return img


def percentile(sorted_values, p):
    if not sorted_values:
        return float("nan")
    k = (len(sorted_values) - 1) * p / 100.0
    lo, hi = math.floor(k), math.ceil(k)
    if lo == hi:
        return sorted_values[lo]
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * (k - lo)


# ---------------------------------------------------------------------------
# intervals — screen-update cadence from PTS gaps


def cmd_intervals(args):
    pts = frames_in_segment(load_pts(args.workdir), parse_segment(args.segment))
    if len(pts) < 2:
        sys.exit("Segment holds fewer than 2 frames.")
    gaps = [(pts[i][1] - pts[i - 1][1]) * 1000 for i in range(1, len(pts))]
    ordered = sorted(gaps)
    duration = pts[-1][1] - pts[0][1]
    print(f"frames {len(pts)}  span {duration:.2f}s  updates/s {len(pts) / duration:.1f}")
    print(f"interval ms  p50 {percentile(ordered, 50):.1f}  "
          f"p95 {percentile(ordered, 95):.1f}  max {max(gaps):.1f}")
    for threshold in (33, 50, 100):
        count = sum(1 for g in gaps if g > threshold)
        print(f"  > {threshold} ms: {count}")
    worst = sorted(range(len(gaps)), key=lambda i: -gaps[i])[:10]
    print("worst stalls (end-time s → ms):")
    for i in worst:
        if gaps[i] > 33:
            print(f"  {pts[i + 1][1]:8.3f}  {gaps[i]:6.1f}")


# ---------------------------------------------------------------------------
# preview-delta — mean abs frame-to-frame change over a fixed crop


def cmd_preview_delta(args):
    np, cv2 = _load_np_cv2()
    pts = frames_in_segment(load_pts(args.workdir), parse_segment(args.segment))
    crop = parse_crop(args.crop) if args.crop else None
    prev = None
    rows = []
    for frame, t in pts:
        img = load_crop(cv2, args.workdir, frame, crop)
        if img is None:
            continue
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32)
        if prev is not None:
            rows.append((t, float(np.abs(gray - prev).mean())))
        prev = gray
    if args.csv:
        with open(args.csv, "w", newline="") as fh:
            writer = csv.writer(fh)
            writer.writerow(["pts_time", "mean_abs_delta"])
            writer.writerows((f"{t:.3f}", f"{d:.2f}") for t, d in rows)
        print(f"wrote {args.csv}")
    deltas = sorted(d for _, d in rows)
    print(f"delta  p50 {percentile(deltas, 50):.1f}  p95 {percentile(deltas, 95):.1f}  "
          f"max {max(deltas):.1f}")
    print("peaks (time s → delta), threshold 40 = jump cut territory:")
    for t, d in rows:
        if d > 40:
            print(f"  {t:8.3f}  {d:6.1f}")


# ---------------------------------------------------------------------------
# chips — the amber selection-indicator mask


def chip_mask_stats(np, cv2, img):
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    # Orange/yellow of the accent + amber (#C36A00 / #FFB340): OpenCV
    # H 8–35 (16–70°), S > 90, V > 90 — the exact mask from the brief.
    mask = cv2.inRange(hsv, (8, 91, 91), (35, 255, 255))
    count = int(np.count_nonzero(mask))
    if count:
        ys, xs = np.nonzero(mask)
        centroid = (float(xs.mean()), float(ys.mean()))
    else:
        centroid = (float("nan"), float("nan"))
    return count, centroid


def cmd_chips(args):
    np, cv2 = _load_np_cv2()
    pts = frames_in_segment(load_pts(args.workdir), parse_segment(args.segment))
    crop = parse_crop(args.crop)
    rows = []
    for frame, t in pts:
        img = load_crop(cv2, args.workdir, frame, crop)
        if img is None:
            continue
        count, centroid = chip_mask_stats(np, cv2, img)
        rows.append((t, count, centroid))
    if args.csv:
        with open(args.csv, "w", newline="") as fh:
            writer = csv.writer(fh)
            writer.writerow(["pts_time", "mask_px", "cx", "cy"])
            writer.writerows(
                (f"{t:.3f}", c, f"{cen[0]:.1f}", f"{cen[1]:.1f}") for t, c, cen in rows)
        print(f"wrote {args.csv}")

    # A selection exists when the mask holds a meaningful blob. The floor is
    # relative to the segment's own selected-state levels.
    counts = sorted(c for _, c, _ in rows if c > 0)
    floor = max(20, percentile(counts, 50) * 0.25 if counts else 20)
    print(f"selection floor: {floor:.0f} px")

    # State machine: report every transition and every no-selection window.
    selected = None
    limbo_start = None
    for t, count, centroid in rows:
        has = count >= floor
        if has and selected is None:
            if limbo_start is not None:
                print(f"  {limbo_start:8.3f} → {t:8.3f}  NO SELECTION "
                      f"({(t - limbo_start) * 1000:.0f} ms)")
                limbo_start = None
            selected = centroid
        elif has and selected is not None:
            if abs(centroid[0] - selected[0]) > args.move_px:
                print(f"  {t:8.3f}  selection moved  "
                      f"cx {selected[0]:.0f} → {centroid[0]:.0f}")
                selected = centroid
        elif not has and selected is not None:
            selected = None
            limbo_start = t
    if limbo_start is not None:
        print(f"  {limbo_start:8.3f} → end  NO SELECTION (unresolved)")


# ---------------------------------------------------------------------------
# settle — exposure/focus stabilisation after a tap


def cmd_settle(args):
    np, cv2 = _load_np_cv2()
    pts = load_pts(args.workdir)
    crop = parse_crop(args.crop) if args.crop else None
    tap = args.tap
    window = [(f, t) for (f, t) in pts if tap <= t <= tap + args.horizon]
    series = []
    for frame, t in window:
        img = load_crop(cv2, args.workdir, frame, crop)
        if img is None:
            continue
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        luma = float(gray.mean())
        sharp = float(cv2.Laplacian(gray, cv2.CV_64F).var())
        series.append((t, luma, sharp))
    if len(series) < 8:
        sys.exit("Not enough frames after the tap.")

    # Stable band = the last 25% of the horizon; settled = first time both
    # luma and sharpness enter (and stay within) tolerance of that band.
    tail = series[int(len(series) * 0.75):]
    luma_ref = sum(v for _, v, _ in tail) / len(tail)
    sharp_ref = sum(v for _, _, v in tail) / len(tail)
    settled_at = None
    for i, (t, luma, sharp) in enumerate(series):
        luma_ok = abs(luma - luma_ref) <= args.luma_tol
        sharp_ok = sharp_ref == 0 or abs(sharp - sharp_ref) / sharp_ref <= args.sharp_tol
        if luma_ok and sharp_ok:
            rest = series[i:]
            if all(abs(l - luma_ref) <= args.luma_tol * 1.5 for _, l, _ in rest[:8]):
                settled_at = t
                break
    print(f"tap {tap:.3f}s  luma_ref {luma_ref:.1f}  sharp_ref {sharp_ref:.1f}")
    if settled_at is None:
        print("  did not settle within the horizon")
    else:
        print(f"  settled at {settled_at:.3f}s  →  {(settled_at - tap) * 1000:.0f} ms after tap")


# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("extract", help="decode frames + PTS from a recording")
    p.add_argument("recording")
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_extract)

    p = sub.add_parser("intervals", help="screen-update interval statistics")
    p.add_argument("workdir")
    p.add_argument("--segment", help="start:end seconds")
    p.set_defaults(func=cmd_intervals)

    p = sub.add_parser("preview-delta", help="frame-to-frame change over a crop")
    p.add_argument("workdir")
    p.add_argument("--crop", help="x,y,w,h in source pixels")
    p.add_argument("--segment", help="start:end seconds")
    p.add_argument("--csv", help="write the full series here")
    p.set_defaults(func=cmd_preview_delta)

    p = sub.add_parser("chips", help="selection-indicator mask over the chip strip")
    p.add_argument("workdir")
    p.add_argument("--crop", required=True, help="x,y,w,h in source pixels")
    p.add_argument("--segment", help="start:end seconds")
    p.add_argument("--move-px", type=float, default=25.0,
                   help="centroid shift that counts as the selection moving")
    p.add_argument("--csv", help="write the full series here")
    p.set_defaults(func=cmd_chips)

    p = sub.add_parser("settle", help="AE/AF settle time after a tap")
    p.add_argument("workdir")
    p.add_argument("--crop", help="x,y,w,h in source pixels")
    p.add_argument("--tap", type=float, required=True, help="tap time in seconds")
    p.add_argument("--horizon", type=float, default=2.5)
    p.add_argument("--luma-tol", type=float, default=3.0)
    p.add_argument("--sharp-tol", type=float, default=0.25)
    p.set_defaults(func=cmd_settle)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
