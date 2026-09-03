#!/usr/bin/env python3
"""Framing-lock audit of an interval shoot's stills: how far every frame sits
from one locked reference framing, where the bounces are, and the minimum
crop that would hold the framing still for the whole shoot.

Why: a tripod on a bridge moves when a tram crosses. Each frame is fine on
its own; played back, the shot wobbles, and inside a stacked window the
displaced frames ghost every edge. Nothing in the capture log can see it —
only the pixels can (E33ED216, 2026-09-03: 25 bounces of 2–10 px on the 16
Pro telephoto, 0 issues logged). This tool measures it before anyone builds
the correction, and sizes the crop the correction would cost.

How: each DNG (or JPEG) is decoded at half size, luma, log, Gaussian
high-pass (so vignette and a sunset's sky gradient don't vote), then
`cv2.phaseCorrelate` under a Hanning window — sub-pixel, ~40 ms/frame on
top of the decode. Two measurements per frame: against the previous frame,
and against the anchor of its 30-frame chunk; chunks chain through the
boundary pair, so the whole-shoot path accumulates error once per chunk,
not once per frame (checked on E33ED216: ≤0.7 px over 1000-frame baselines
against a direct measurement). OpenCV's self-correlation bias (+0.5 px on
x for even widths in 5.0) is measured per chunk and subtracted.

The path is split into a slow drift (121-frame running median — tripod
settling, OIS wander) and the bounce residual; events are runs where the
residual exceeds --event-px, merged within 10 frames. Two crop budgets are
printed: LOCK-EVERYTHING (one reference framing for the whole shoot, drift
included) and BOUNCE-ONLY (drift left in). Both are the largest same-aspect
inset that keeps every frame's content inside the output, as a fraction of
each edge — the FrameRotation trade: same output geometry, one resample.

  tools/.venv/bin/python tools/framing_lock_report.py <project-dir> [--lo N --hi N]
      [--band 0.12,0.75] [--event-px 2] [--workers 10] [--out path.json] [--plot path.png]

`--band top,bottom` restricts the correlation to a horizontal band of the
frame (fractions of height) — put it over the architecture when a river or
sky fills the rest; on E33ED216 the band and the whole frame agreed within
0.1 px, the band just correlated better (0.88 vs 0.83).

Greppable verdict: `FRAMING LOCK: <events> events · peak <px> px · crop <pct>%`.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import cv2
import numpy as np

FRAME_RE = re.compile(r"^frame-(\d{5})\.(dng|jpg|jpeg)$", re.IGNORECASE)
SCALE = 2
CHUNK = 30
MEDIAN_WINDOW = 121


# ---------------------------------------------------------------- frame IO

def discover_frames(source: Path) -> list[tuple[int, Path]]:
    out = []
    for name in os.listdir(source):
        m = FRAME_RE.match(name)
        if m:
            out.append((int(m.group(1)), source / name))
    out.sort()
    return out


def decode_half_luma(path: Path) -> np.ndarray:
    """Half-size linear luma, float32, y-down. DNG via rawpy (no demosaic:
    half_size bins the Bayer quad), JPEG via PIL's DCT draft decode."""
    if path.suffix.lower() == ".dng":
        import rawpy
        with rawpy.imread(str(path)) as raw:
            rgb = raw.postprocess(
                half_size=True, use_camera_wb=True, no_auto_bright=True,
                output_bps=16, gamma=(1, 1), user_flip=0)
        return (0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]).astype(np.float32)
    from PIL import Image
    im = Image.open(path)
    im.draft("L", (im.size[0] // SCALE, im.size[1] // SCALE))
    return np.asarray(im.convert("L"), dtype=np.float32) ** 2.2


def prepared(path: Path, band: tuple[float, float] | None) -> np.ndarray:
    y = np.log1p(decode_half_luma(path))
    y = y - cv2.GaussianBlur(y, (0, 0), 12)
    if band:
        h = y.shape[0]
        y = y[int(h * band[0]):int(h * band[1]), :]
    return np.ascontiguousarray(y)


# ---------------------------------------------------------------- measurement

def measure_chunk(args):
    paths, lo, hi, band = args
    rows = []
    prev = prepared(paths[lo - 1], band) if lo > 0 else None
    anchor = window = bias = None
    for i in range(lo, hi):
        cur = prepared(paths[i], band)
        if window is None or window.shape != cur.shape:
            window = cv2.createHanningWindow((cur.shape[1], cur.shape[0]), cv2.CV_32F)
            (bx, by), _ = cv2.phaseCorrelate(cur, cur, window)
            bias = (bx, by)
        if anchor is None or anchor.shape != cur.shape:
            anchor = cur
        if prev is None or prev.shape != cur.shape:
            dxp = dyp = 0.0
            rp = 1.0
        else:
            (dx, dy), rp = cv2.phaseCorrelate(prev, cur, window)
            dxp, dyp = (dx - bias[0]) * SCALE, (dy - bias[1]) * SCALE
        (dx, dy), ra = cv2.phaseCorrelate(anchor, cur, window)
        rows.append(dict(
            i=i, dxp=dxp, dyp=dyp, rp=float(rp),
            dxa=(dx - bias[0]) * SCALE, dya=(dy - bias[1]) * SCALE, ra=float(ra)))
        prev = cur
    return rows


def measure(paths: list[Path], lo: int, hi: int, band, workers: int, quiet: bool) -> list[dict]:
    jobs = [(paths, start, min(hi, start + CHUNK), band) for start in range(lo, hi, CHUNK)]
    rows = []
    started = time.time()
    with ProcessPoolExecutor(max_workers=workers) as pool:
        for k, part in enumerate(pool.map(measure_chunk, jobs)):
            rows.extend(part)
            if not quiet and k % 20 == 0:
                print(f"  {len(rows)}/{hi - lo} frames  {time.time() - started:.0f}s", file=sys.stderr, flush=True)
    rows.sort(key=lambda r: r["i"])
    # Chain the chunks: a chunk's anchor sits at the previous chunk's last
    # frame plus the consecutive shift across the boundary.
    last_x = last_y = base_x = base_y = 0.0
    for r in rows:
        if (r["i"] - lo) % CHUNK == 0:
            base_x = last_x + (r["dxp"] if r["i"] > lo else 0.0)
            base_y = last_y + (r["dyp"] if r["i"] > lo else 0.0)
        r["gx"] = base_x + r["dxa"]
        r["gy"] = base_y + r["dya"]
        last_x, last_y = r["gx"], r["gy"]
    return rows


# ---------------------------------------------------------------- analysis

def running_median(values: np.ndarray, k: int) -> np.ndarray:
    k = min(k, len(values) if len(values) % 2 else len(values) - 1)
    if k < 3:
        return values.copy()
    pad = k // 2
    padded = np.pad(values, pad, mode="edge")
    return np.median(np.lib.stride_tricks.sliding_window_view(padded, k), axis=1)


def full_size(path: Path) -> tuple[int, int]:
    if path.suffix.lower() == ".dng":
        import rawpy
        with rawpy.imread(str(path)) as raw:
            return raw.sizes.width, raw.sizes.height
    from PIL import Image
    return Image.open(path).size


def analyse(frames, rows, event_px: float):
    indices = np.array([frames[r["i"]][0] for r in rows])
    gx = np.array([r["gx"] for r in rows])
    gy = np.array([r["gy"] for r in rows])
    ra = np.array([r["ra"] for r in rows])
    slow_x = running_median(gx, MEDIAN_WINDOW)
    slow_y = running_median(gy, MEDIAN_WINDOW)
    bx, by = gx - slow_x, gy - slow_y
    magnitude = np.hypot(bx, by)
    active = magnitude > event_px
    starts = np.flatnonzero(np.diff(np.r_[0, active.astype(int)]) == 1)
    ends = np.flatnonzero(np.diff(np.r_[active.astype(int), 0]) == -1)
    events = []
    for s, e in zip(starts, ends):
        peak = float(magnitude[s:e + 1].max())
        if events and s - events[-1][1] <= 10:
            events[-1] = (events[-1][0], e, max(events[-1][2], peak))
        else:
            events.append((s, e, peak))
    width, height = full_size(frames[rows[0]["i"]][1])

    def budget(px, py):
        inset_x = (px.max() - px.min()) / 2
        inset_y = (py.max() - py.min()) / 2
        return inset_x, inset_y, max(2 * inset_x / width, 2 * inset_y / height)

    return dict(
        indices=indices, gx=gx, gy=gy, ra=ra, slow_x=slow_x, slow_y=slow_y, bx=bx, by=by,
        events=events, active_frames=int(active.sum()), width=width, height=height,
        lock_all=budget(gx, gy), bounce_only=budget(bx, by))


def report(project: Path, a: dict, event_px: float):
    ix, iy, s = a["lock_all"]
    bx_, by_, sb = a["bounce_only"]
    n = len(a["gx"])
    print(f"\n{project.name}  ·  {n} frames  ·  {a['width']}×{a['height']}")
    print(f"  correlation response: median {np.median(a['ra']):.2f} · p5 {np.percentile(a['ra'], 5):.2f} · min {a['ra'].min():.2f}")
    print(f"  path vs locked reference: x {a['gx'].min():.1f}..{a['gx'].max():.1f} px · y {a['gy'].min():.1f}..{a['gy'].max():.1f} px")
    print(f"  slow drift span: x {a['slow_x'].max() - a['slow_x'].min():.1f} px · y {a['slow_y'].max() - a['slow_y'].min():.1f} px")
    print(f"  bounce residual: |x| p99 {np.percentile(abs(a['bx']), 99):.1f} max {abs(a['bx']).max():.1f} · |y| p99 {np.percentile(abs(a['by']), 99):.1f} max {abs(a['by']).max():.1f}")
    events = a["events"]
    print(f"  bounce events (> {event_px:g} px off the local baseline): {len(events)} · {a['active_frames']} frames affected")
    for s_, e_, peak in events:
        print(f"    {a['indices'][s_]:5d}-{a['indices'][e_]:5d}  {e_ - s_ + 1:3d} frames  peak {peak:4.1f} px")
    print(f"  LOCK-EVERYTHING crop: x ±{ix:.1f} px, y ±{iy:.1f} px → {s * 100:.2f}% of each edge, keeps {int(a['width'] * (1 - s))}×{int(a['height'] * (1 - s))}")
    print(f"  BOUNCE-ONLY crop    : x ±{bx_:.1f} px, y ±{by_:.1f} px → {sb * 100:.2f}% of each edge")
    peak = max((p for _, _, p in events), default=0.0)
    print(f"FRAMING LOCK: {len(events)} events · peak {peak:.1f} px · crop {s * 100:.2f}%")


def plot(a: dict, path: Path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(3, 1, figsize=(14, 9), sharex=True)
    ax[0].plot(a["indices"], a["gy"], lw=0.6, color="#C36A00", label="vertical")
    ax[0].plot(a["indices"], a["slow_y"], lw=1.2, color="#1C1C1E", label="slow drift")
    ax[1].plot(a["indices"], a["gx"], lw=0.6, color="#2A7FBF", label="horizontal")
    ax[1].plot(a["indices"], a["slow_x"], lw=1.2, color="#1C1C1E")
    ax[2].plot(a["indices"], a["ra"], lw=0.6, color="#777", label="correlation response")
    ax[0].set_title("frame position vs locked reference (full-res px)")
    for axis in ax:
        axis.grid(alpha=0.3)
        axis.legend(loc="upper left")
    ax[2].set_xlabel("frame")
    fig.tight_layout()
    fig.savefig(path, dpi=110)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("project", type=Path, help="project directory (contains source/) or the source directory itself")
    ap.add_argument("--lo", type=int, default=0, help="first frame position (0-based) to measure")
    ap.add_argument("--hi", type=int, default=None, help="one past the last frame position")
    ap.add_argument("--band", type=str, default=None, help="top,bottom fractions of height to correlate over, e.g. 0.12,0.75")
    ap.add_argument("--event-px", type=float, default=2.0)
    ap.add_argument("--workers", type=int, default=max(2, (os.cpu_count() or 4) - 2))
    ap.add_argument("--out", type=Path, default=None, help="write the per-frame path as JSON")
    ap.add_argument("--plot", type=Path, default=None, help="write a PNG of the path")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    source = args.project / "source" if (args.project / "source").is_dir() else args.project
    frames = discover_frames(source)
    if len(frames) < 2:
        sys.exit(f"no frame-NNNNN.dng/.jpg files in {source}")
    band = tuple(float(v) for v in args.band.split(",")) if args.band else None
    hi = args.hi if args.hi is not None else len(frames)
    paths = [p for _, p in frames]
    rows = measure(paths, args.lo, hi, band, args.workers, args.quiet)
    a = analyse(frames, rows, args.event_px)
    report(args.project, a, args.event_px)
    if args.out:
        payload = [dict(frame=int(frames[r["i"]][0]), **{k: (round(v, 3) if isinstance(v, float) else v) for k, v in r.items() if k != "i"}) for r in rows]
        args.out.write_text(json.dumps(dict(
            project=str(args.project), width=a["width"], height=a["height"], band=band,
            lockEverythingCropFraction=a["lock_all"][2], bounceOnlyCropFraction=a["bounce_only"][2],
            frames=payload), indent=0))
    if args.plot:
        plot(a, args.plot)


if __name__ == "__main__":
    main()
