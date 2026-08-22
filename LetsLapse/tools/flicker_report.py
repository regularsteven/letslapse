#!/usr/bin/env python3
"""Flicker audit for a blend clip against its capture_log.json.

The at-home quality gate: export the project's blend clip at NO blend
depth (one video frame per output window), pull the project's
capture_log.json off the device, and run:

  tools/.venv/bin/python tools/flicker_report.py <clip.mp4> <capture_log.json>

For every adjacent frame pair the tool measures the approximate-linear
luminance step in stops, flags steps above the visibility threshold
(default 1/8 stop), and attributes each flagged step to what the capture
engine changed at that exact frame: blend count (and specifically the
1-frame pass-through boundary), exposure, Lumen boost, or pacing. The
2026-08-21 diagnosis — 39/39 flicker events on the count boundary, caused
by Apple-rendered pass-throughs alternating with authored linear blends —
came from exactly this analysis.

Frame alignment relies on the no-depth export: one video frame per
capture_log frame, in order. A mismatched count is reported, not guessed
around.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np


def frame_lumas(path: Path) -> np.ndarray:
    cap = cv2.VideoCapture(str(path))
    lumas = []
    while True:
        ok, img = cap.read()
        if not ok:
            break
        small = cv2.resize(img, (168, 126))
        gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY).astype(np.float64) / 255
        lumas.append(float((gray ** 2.2).mean()))
    cap.release()
    return np.array(lumas)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("clip", type=Path)
    parser.add_argument("capture_log", type=Path)
    parser.add_argument("--threshold", type=float, default=0.12,
                        help="visible-step threshold in stops (default 1/8)")
    parser.add_argument("--csv", type=Path, help="per-frame CSV output")
    args = parser.parse_args()

    log = json.loads(args.capture_log.read_text())
    frames = log.get("frames", [])
    lumas = frame_lumas(args.clip)
    if len(lumas) != len(frames):
        print(f"WARNING: {len(lumas)} video frames vs {len(frames)} log frames "
              f"— export must be a no-blend-depth clip of this exact project",
              file=sys.stderr)
    n = min(len(lumas), len(frames))
    if n < 2:
        print("not enough aligned frames to analyze", file=sys.stderr)
        return 1

    stops = np.abs(np.diff(np.log2(np.maximum(lumas[:n], 1e-6))))
    flagged = np.where(stops > args.threshold)[0]

    print(f"{args.clip.name}: {n} frames · mean |Δ| {stops.mean():.3f} stops · "
          f"flagged >{args.threshold:g}: {len(flagged)} "
          f"({100 * len(flagged) / len(stops):.1f}%) · "
          f">1/4 stop: {(stops > 0.25).sum()} · >1/2: {(stops > 0.5).sum()}")

    causes = {"blendCountChange": 0, "passThroughBoundary": 0,
              "exposureStep": 0, "lumenBoostChange": 0,
              "intervalChange": 0, "noLoggedChange": 0}
    for i in flagged:
        a, b = frames[i], frames[i + 1]
        sa, sb = a.get("strategy") or {}, b.get("strategy") or {}
        wa, wb = a.get("window") or {}, b.get("window") or {}
        tagged = False
        counts = (a.get("blendCount"), b.get("blendCount"))
        if counts[0] != counts[1]:
            causes["blendCountChange"] += 1
            tagged = True
            if 1 in counts:
                causes["passThroughBoundary"] += 1
        if (a.get("iso"), a.get("exposureDuration")) != \
           (b.get("iso"), b.get("exposureDuration")):
            causes["exposureStep"] += 1
            tagged = True
        if (sa.get("lumenBoost") or 0) != (sb.get("lumenBoost") or 0):
            causes["lumenBoostChange"] += 1
            tagged = True
        if wa.get("intervalSeconds") != wb.get("intervalSeconds"):
            causes["intervalChange"] += 1
            tagged = True
        if not tagged:
            causes["noLoggedChange"] += 1
    active = {k: v for k, v in causes.items() if v}
    print(f"  causes among flagged steps: {active or 'none flagged'}")
    for i in flagged[:8]:
        a, b = frames[i], frames[i + 1]
        print(f"    f{i}->{i + 1}: {stops[i]:.2f} stops · "
              f"blend {a.get('blendCount')}->{b.get('blendCount')} · "
              f"iso {a.get('iso')}->{b.get('iso')} · "
              f"sh {a.get('exposureDuration')}->{b.get('exposureDuration')}")

    if args.csv:
        import csv as csvmod
        with args.csv.open("w", newline="") as handle:
            w = csvmod.writer(handle)
            w.writerow(["frame", "luma", "deltaStops", "blendCount", "iso",
                        "exposureDuration", "flagged"])
            for i in range(n):
                w.writerow([
                    i, f"{lumas[i]:.6f}",
                    f"{stops[i - 1]:.4f}" if i else "",
                    frames[i].get("blendCount"), frames[i].get("iso"),
                    frames[i].get("exposureDuration"),
                    bool(i and stops[i - 1] > args.threshold)])
        print(f"  CSV: {args.csv}")

    # The verdict line a test suite can grep.
    ok = len(flagged) == 0
    print(f"FLICKER {'PASS' if ok else 'FAIL'}: {len(flagged)} visible steps")
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
