#!/usr/bin/env python3
"""A contact sheet of a Shape-mation clip with every photo's target drawn.

    frame_sheet.py <clip.mp4> <plan.json> <sheet.png> [--cols 4] [--tile 480] [--max 24]

One tile per photo of the plan (`items` in order): the middle frame of that
photo's hold read from the clip (holds are assumed equal — `--hold Nf`; a
ramped clip needs `--frames a,b,c…` with the first frame of each hold), the
plan's `target` as a green crosshair, a green square of `targetSizePx` on a
side around it (the face's long side there), the register shape through the
placement (`placed.cornersPx` or the ellipse) in thin green, and the verdict
in the corner — red when flagged. Frames are read with OpenCV; the sheet is
written as PNG. docs/shapemation/output-frame.md §7.
"""
import argparse
import json
import math
import sys

import cv2
import numpy as np


def read_frames(clip, wanted):
    """The frames at the given indices, in index order, as BGR arrays."""
    cap = cv2.VideoCapture(clip)
    if not cap.isOpened():
        sys.exit(f"cannot open {clip}")
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    out = {}
    want = sorted(set(min(max(0, w), total - 1) for w in wanted))
    index = 0
    next_i = 0
    while next_i < len(want):
        ok, frame = cap.read()
        if not ok:
            break
        if index == want[next_i]:
            out[index] = frame
            next_i += 1
        index += 1
    cap.release()
    return out, total


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("clip")
    ap.add_argument("plan")
    ap.add_argument("sheet")
    ap.add_argument("--cols", type=int, default=4)
    ap.add_argument("--tile", type=int, default=480, help="tile width in px")
    ap.add_argument("--max", type=int, default=24, help="at most this many photos, spread evenly over the plan")
    ap.add_argument("--frames", help="comma-separated first frame of each hold (else equal holds)")
    args = ap.parse_args()

    plan = json.load(open(args.plan))
    items = plan["items"]
    n = len(items)
    if n == 0:
        sys.exit("the plan placed nothing")
    cap = cv2.VideoCapture(args.clip)
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    W, H = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap.release()
    if args.frames:
        starts = [int(x) for x in args.frames.split(",")]
        if len(starts) != n:
            sys.exit(f"--frames names {len(starts)} holds, the plan has {n} photos")
        ends = starts[1:] + [total]
        mids = [(a + b) // 2 for a, b in zip(starts, ends)]
    else:
        hold = total / n
        mids = [int((i + 0.5) * hold) for i in range(n)]

    # Which photos to show: all when they fit, else spread evenly, ends kept.
    if n <= args.max:
        picks = list(range(n))
    else:
        picks = sorted(set(round(i * (n - 1) / (args.max - 1)) for i in range(args.max)))
    frames, _ = read_frames(args.clip, [mids[i] for i in picks])

    scale = args.tile / W
    tw, th = args.tile, int(round(H * scale))
    label_h = 22
    cols = min(args.cols, len(picks))
    rows = math.ceil(len(picks) / cols)
    sheet = np.zeros((rows * (th + label_h), cols * tw, 3), dtype=np.uint8)
    green = (0, 220, 0)
    red = (40, 40, 255)
    for k, i in enumerate(picks):
        item = items[i]
        frame = frames.get(mids[i])
        if frame is None:
            continue
        tile = cv2.resize(frame, (tw, th), interpolation=cv2.INTER_AREA)
        tx, ty = item["target"]
        size = item["targetSizePx"]
        cx, cy = tx * scale, ty * scale
        half = size * scale / 2
        # The target: crosshair + the face's long-side square.
        cv2.line(tile, (int(cx - 14), int(cy)), (int(cx + 14), int(cy)), green, 1, cv2.LINE_AA)
        cv2.line(tile, (int(cx), int(cy - 14)), (int(cx), int(cy + 14)), green, 1, cv2.LINE_AA)
        cv2.rectangle(tile, (int(cx - half), int(cy - half)), (int(cx + half), int(cy + half)), green, 1, cv2.LINE_AA)
        # The register shape through the placement — where the plan says the face IS.
        placed = item.get("placed", {})
        if placed.get("cornersPx"):
            pts = np.array([[x * scale, y * scale] for x, y in placed["cornersPx"]], dtype=np.int32)
            cv2.polylines(tile, [pts], True, green, 1, cv2.LINE_AA)
        elif placed.get("centrePx") and placed.get("semiAxesPx"):
            c = tuple(int(v * scale) for v in placed["centrePx"])
            axes = tuple(int(v * scale) for v in placed["semiAxesPx"])
            cv2.ellipse(tile, c, axes, math.degrees(placed.get("rotation", 0)), 0, 360, green, 1, cv2.LINE_AA)
        verdict = item["feasibility"]["verdict"]
        flagged = verdict != "fits"
        cv2.putText(tile, verdict, (6, th - 8), cv2.FONT_HERSHEY_SIMPLEX, 0.5, red if flagged else green, 1, cv2.LINE_AA)
        r, c = divmod(k, cols)
        y0, x0 = r * (th + label_h), c * tw
        sheet[y0:y0 + th, x0:x0 + tw] = tile
        name = item["project"].split("/")[-1]
        text = f"{i + 1}/{n} {name}  frame {mids[i]}  s {item['scale']:.2f}"
        cv2.putText(sheet, text, (x0 + 6, y0 + th + 15), cv2.FONT_HERSHEY_SIMPLEX, 0.42, (230, 230, 230), 1, cv2.LINE_AA)
    cv2.imwrite(args.sheet, sheet, [cv2.IMWRITE_PNG_COMPRESSION, 9])
    tally = f"flagged: short {plan.get('flaggedShort', 0)} · upscaled {plan.get('flaggedUpscaled', 0)}"
    print(f"{args.sheet} · {len(picks)} of {n} photos · {W}×{H} clip, {total} frames · {tally}")


if __name__ == "__main__":
    main()
