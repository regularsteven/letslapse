#!/usr/bin/env python3
"""Flicker audit straight off a project's source frames.

The companion to flicker_report.py: that tool audits an exported no-depth
clip, this one reads the project's source JPEGs directly (device pull,
Wi-Fi import or external storage — anywhere `frame-NNNNN.jpg` and its
`capture_log.json` live), so a shoot can be judged without an export pass.

  tools/.venv/bin/python tools/source_flicker_report.py <source-dir>

Two failure classes, because they are seen differently:

1. **Single visible steps** — one adjacent pair more than `--threshold`
   (default 1/8 stop) apart. Same rule as flicker_report.py.
2. **Oscillation** — runs of sign-alternating steps (light, dark, light,
   dark…). The 2026-08-25 iPad dawn run flickered at ~0.09 stop per flip —
   *below* the single-step threshold — yet reads as unmistakable pumping,
   because the eye integrates the pattern. Any `--min-run` consecutive
   alternations at `--flip-threshold` or more each is an oscillation event.

Each event is attributed against capture_log.json when present: an applied
exposure gain (ISO × shutter) toggling between exactly two latched states
is the ramp-servo limit cycle; blend-count changes and alignment-gate
rejections are reported alongside. The verdict line is greppable:
`SOURCE FLICKER PASS` / `SOURCE FLICKER FAIL`.

JPEG sources only — a DNG project should be judged via its no-depth export
and flicker_report.py (cv2 does not honestly decode our authored DNGs).
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import cv2
import numpy as np

FRAME_RE = re.compile(r"frame-(\d+)\.(jpg|jpeg)$", re.IGNORECASE)


def measure_luma(path: str) -> float:
    """Mean linear luma of one frame, decode-reduced for speed.

    Same metric family as flicker_report.py (168×126, gray^2.2 mean) so
    thresholds carry over between the two tools.
    """
    img = cv2.imread(path, cv2.IMREAD_REDUCED_COLOR_8)
    if img is None:
        return float("nan")
    small = cv2.resize(img, (168, 126))
    gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY).astype(np.float64) / 255
    return float((gray ** 2.2).mean())


def discover_frames(source: Path) -> list[tuple[int, Path]]:
    frames = []
    for p in source.iterdir():
        m = FRAME_RE.match(p.name)
        if m:
            frames.append((int(m.group(1)), p))
    frames.sort()
    return frames


def gain_of(entry: dict) -> float | None:
    iso, shutter = entry.get("iso"), entry.get("exposureDuration")
    if iso is None or shutter is None:
        return None
    return iso * shutter


def describe_event(start: int, end: int, deltas: np.ndarray,
                   log_frames: list[dict], issues: list[dict]) -> list[str]:
    """Attribution lines for an oscillation event spanning frame numbers
    [start, end] (1-based, inclusive)."""
    lines = []
    span = deltas[start - 1:end - 1]
    lines.append(f"    amplitude median {np.median(np.abs(span)):.3f} stops, "
                 f"peak {np.abs(span).max():.3f}")
    if log_frames:
        entries = [f for f in log_frames if start <= f.get("frameIndex", 0) <= end]
        gains = [g for g in (gain_of(f) for f in entries) if g]
        if gains:
            distinct = sorted({round(g, 7) for g in gains})
            if len(distinct) == 2:
                stops = math.log2(distinct[1] / distinct[0])
                lines.append(
                    f"    applied exposure TOGGLES between two latched states "
                    f"{stops:.3f} stops apart — ramp-servo limit cycle "
                    f"(gains {distinct[0]:.3g} / {distinct[1]:.3g})")
            elif len(distinct) > 2:
                spread = math.log2(max(distinct) / min(distinct))
                lines.append(f"    applied exposure moved through "
                             f"{len(distinct)} states over {spread:.2f} stops")
            else:
                lines.append("    applied exposure constant — flicker is not "
                             "exposure-commanded (scene, ISP, or blend)")
        counts = sorted({f.get("blendCount") for f in entries if f.get("blendCount")})
        if len(counts) > 1:
            lines.append(f"    blend counts varied: {counts}")
        thermal = sorted({(f.get("window") or {}).get("thermalStateAtClose")
                          for f in entries} - {None})
        if thermal:
            lines.append(f"    thermal: {'/'.join(thermal)}")
    for issue in issues:
        idx = issue.get("windowIndex")
        if idx is not None and start - 2 <= idx <= end + 2:
            lines.append(f"    issue at window {idx}: [{issue.get('kind')}] "
                         f"{issue.get('detail')}")
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path,
                        help="project source dir (frame-NNNNN.jpg + capture_log.json)")
    parser.add_argument("--log", type=Path, default=None,
                        help="capture_log.json (default: <source>/capture_log.json)")
    parser.add_argument("--threshold", type=float, default=0.12,
                        help="single visible step threshold, stops (default 1/8)")
    parser.add_argument("--flip-threshold", type=float, default=0.05,
                        help="per-step floor for alternation detection (default 0.05)")
    parser.add_argument("--min-run", type=int, default=4,
                        help="consecutive alternations that make an event (default 4)")
    parser.add_argument("--range", dest="frame_range", default=None,
                        help="only analyze frames A:B (1-based filename numbers)")
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--csv", type=Path, help="per-frame CSV output")
    args = parser.parse_args()

    frames = discover_frames(args.source)
    if args.frame_range:
        lo, hi = (int(x) for x in args.frame_range.split(":"))
        frames = [(n, p) for n, p in frames if lo <= n <= hi]
    if len(frames) < 3:
        print("not enough frames to analyze", file=sys.stderr)
        return 1
    numbers = [n for n, _ in frames]
    if numbers != list(range(numbers[0], numbers[0] + len(numbers))):
        print(f"WARNING: frame numbering has gaps "
              f"({numbers[0]}..{numbers[-1]}, {len(numbers)} files) — "
              f"steps across a gap are reported at the gap", file=sys.stderr)

    log_path = args.log or (args.source / "capture_log.json")
    log_frames: list[dict] = []
    issues: list[dict] = []
    if log_path.exists():
        log = json.loads(log_path.read_text())
        log_frames = log.get("frames", [])
        issues = log.get("issues", [])
    else:
        print(f"note: no capture_log at {log_path} — steps reported unattributed")

    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        lumas = np.array(list(pool.map(
            measure_luma, [str(p) for _, p in frames], chunksize=32)))
    bad = np.isnan(lumas)
    if bad.any():
        print(f"WARNING: {bad.sum()} frames failed to decode", file=sys.stderr)
        lumas[bad] = np.nanmedian(lumas)

    # Signed steps in stops between adjacent frames; deltas[i] is the step
    # from frames[i] to frames[i+1].
    deltas = np.diff(np.log2(np.maximum(lumas, 1e-6)))

    # --- Class 1: single visible steps -----------------------------------
    flagged = np.where(np.abs(deltas) > args.threshold)[0]

    # --- Class 2: oscillation runs ---------------------------------------
    # A qualifying alternation at i: deltas i and i+1 in opposite directions,
    # both at or above the flip floor.
    qual = np.abs(deltas) >= args.flip_threshold
    alt = qual[:-1] & qual[1:] & (np.sign(deltas[:-1]) != np.sign(deltas[1:]))
    events: list[tuple[int, int, int]] = []  # (startFrame, endFrame, flips)
    i = 0
    while i < len(alt):
        if alt[i]:
            j = i
            while j + 1 < len(alt) and alt[j + 1]:
                j += 1
            flips = j - i + 1
            if flips >= args.min_run - 1:
                # deltas i..j+1 participate → frames i..j+2 (0-based)
                events.append((numbers[i], numbers[j + 2], flips + 1))
            i = j + 1
        else:
            i += 1

    n = len(lumas)
    osc_frames = sum(e - s + 1 for s, e, _ in events)
    print(f"{args.source}: {n} frames · mean |Δ| {np.abs(deltas).mean():.4f} stops "
          f"· p95 {np.percentile(np.abs(deltas), 95):.3f}")
    print(f"single steps >{args.threshold:g}: {len(flagged)} · "
          f">1/4 stop: {(np.abs(deltas) > 0.25).sum()} · "
          f">1/2: {(np.abs(deltas) > 0.5).sum()}")
    for i in flagged[:10]:
        a, b = numbers[i], numbers[i + 1]
        extra = ""
        if log_frames and b <= len(log_frames):
            fa = next((f for f in log_frames if f.get("frameIndex") == a), {})
            fb = next((f for f in log_frames if f.get("frameIndex") == b), {})
            extra = (f" · blend {fa.get('blendCount')}→{fb.get('blendCount')}"
                     f" · iso {fa.get('iso'):.0f}→{fb.get('iso'):.0f}"
                     if fa and fb else "")
        print(f"  step frame {a}→{b}: {deltas[i]:+.2f} stops{extra}")
    if len(flagged) > 10:
        print(f"  … and {len(flagged) - 10} more")

    print(f"oscillation events (≥{args.min_run} alternating steps "
          f"≥{args.flip_threshold:g}): {len(events)} · "
          f"{osc_frames} frames affected ({100 * osc_frames / n:.1f}%)")
    for start, end, flips in events:
        print(f"  OSCILLATION frames {start}–{end} ({flips} flips)")
        for line in describe_event(start, end, deltas, log_frames, issues):
            print(line)

    if args.csv:
        import csv as csvmod
        with args.csv.open("w", newline="") as handle:
            w = csvmod.writer(handle)
            w.writerow(["frame", "luma", "deltaStops", "iso",
                        "exposureDuration", "blendCount"])
            by_index = {f.get("frameIndex"): f for f in log_frames}
            for k in range(n):
                f = by_index.get(numbers[k], {})
                w.writerow([numbers[k], f"{lumas[k]:.6f}",
                            f"{deltas[k - 1]:+.4f}" if k else "",
                            f.get("iso"), f.get("exposureDuration"),
                            f.get("blendCount")])
        print(f"CSV: {args.csv}")

    ok = len(flagged) == 0 and not events
    print(f"SOURCE FLICKER {'PASS' if ok else 'FAIL'}: "
          f"{len(flagged)} visible steps, {len(events)} oscillation events")
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
