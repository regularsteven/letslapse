#!/usr/bin/env python3
"""
testcard_report.py — decode LetsLapse test-card footage into per-frame
display-side timestamps and a timing report.

Companion to testcard/index.html: the card renders a machine-readable clock
(session QR, 500 ms time QR, 16-bit Gray-coded 60 Hz tick strip, 1 rev/sec
sweep dial, AE patches, constant-velocity ball). Shoot the card from a
tripod, run `report` on the clip, and every captured frame gets a card-side
timestamp — measured fps, segment-switch gaps, and AE stability all become
direct measurements instead of inferences.

Setup (same venv as capture_metrics.py):

    cd LetsLapse/tools
    python3 -m venv .venv
    .venv/bin/pip install numpy opencv-python-headless

Workflow:

    # Sanity-check the whole loop without a camera: renders frozen card
    # frames via headless Chrome and asserts they decode to the right times
    .venv/bin/python testcard_report.py selftest

    # Analyze a capture (video file or a directory of extracted frames)
    .venv/bin/python testcard_report.py report clip.mov
    .venv/bin/python testcard_report.py report frames_dir/ --out run.csv

Notes:
  - The card is assumed static in frame (tripod). The card->image homography
    comes from the QR corner quads and is cached between detections
    (--detect-every controls the refresh cadence).
  - The Gray strip is the robust time channel: one bit flips per 60 Hz tick,
    so exposure blending costs at most ±1 tick (16.7 ms). The sweep dial
    refines within a tick but smears under long exposure — treat card_ms_fine
    as advisory, card_ms as truth.
  - VFR sources: cv2's per-frame POS_MSEC can be backend-quirky; for exact
    container PTS use the capture_metrics.py extract recipe and point
    `report` at the frames directory.

LAYOUT constants below mirror testcard/index.html — KEEP THEM IN SYNC.
"""

import argparse
import csv
import math
import os
import pathlib
import subprocess
import sys
import tempfile

import cv2
import numpy as np

# ---------------------------------------------------------------------------
# Layout (logical 1000x1600 card units) — mirror of index.html LAYOUT
# ---------------------------------------------------------------------------
CARD_W, CARD_H = 1000.0, 1600.0

# QR symbol rects (module area, no quiet zone): x, y, size
SESSION_QR = (80.0, 240.0, 300.0)
TIME_QR = (620.0, 240.0, 300.0)

STRIP_X0, STRIP_Y, STRIP_BW, STRIP_BH, STRIP_BLOCKS = 104.0, 630.0, 44.0, 60.0, 18
DIAL_CX, DIAL_CY, DIAL_SAMPLE_R = 270.0, 940.0, 140.0
PATCH_X0, PATCH_Y, PATCH_W, PATCH_H = 104.0, 1170.0, 88.0, 100.0
PATCH_GRAYS = [0, 51, 102, 153, 204, 255]   # then R, G, B
PATCH_N = 9
BALL_XMIN, BALL_XMAX, BALL_YC, BALL_PERIOD = 150.0, 850.0, 1360.0, 4000.0
BALL_R = 36.0

TICK_HZ = 60.0
TICK_WRAP = 1 << 16

SWEEP_SAMPLES = 720
SWEEP_SMOOTH = 9          # ~4.5 deg box filter, matches the 12px hand width

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


def qr_corners(rect):
    x, y, s = rect
    return [(x, y), (x + s, y), (x + s, y + s), (x, y + s)]


# ---------------------------------------------------------------------------
# Card tracking: QR-anchored homography, cached across frames (tripod rig)
# ---------------------------------------------------------------------------
class CardTracker:
    def __init__(self):
        # The Aruco-based detector decodes every mask pattern the card can
        # emit (the plain QRCodeDetector fails on ~25% of mask-7 symbols).
        det_cls = getattr(cv2, "QRCodeDetectorAruco", cv2.QRCodeDetector)
        self.det = det_cls()
        self.H = None
        self.scale = None       # image px per logical unit
        self.script = None

    def detect(self, gray):
        """Try to refresh homography from QR corners. Returns time-QR ms or None."""
        qr_ms = None
        try:
            ok, infos, points, _ = self.det.detectAndDecodeMulti(gray)
        except cv2.error:
            return None
        if not ok or points is None:
            return None
        src, dst = [], []
        for info, quad in zip(infos, points):
            if info.startswith("LLTC1;"):
                self.script = info[6:]
                src += qr_corners(SESSION_QR)
                dst += [tuple(p) for p in quad]
            elif info.startswith("LLT;"):
                try:
                    qr_ms = int(info[4:])
                except ValueError:
                    qr_ms = None
                src += qr_corners(TIME_QR)
                dst += [tuple(p) for p in quad]
        if len(src) >= 4:
            H, _ = cv2.findHomography(np.array(src, np.float32), np.array(dst, np.float32))
            if H is not None:
                self.H = H
                a = self.map_points([(0, 0), (1000, 0)])
                self.scale = float(np.linalg.norm(a[1] - a[0]) / 1000.0)
        return qr_ms

    def map_points(self, pts):
        a = np.array(pts, np.float32).reshape(-1, 1, 2)
        return cv2.perspectiveTransform(a, self.H).reshape(-1, 2)


def sample_means(img, pts_img, rad):
    """Mean pixel value in a (2*rad+1)^2 window around each image point.
    Returns an array of means; last axis preserved for color images."""
    h, w = img.shape[:2]
    out = []
    for x, y in pts_img:
        xi, yi = int(round(x)), int(round(y))
        x0, x1 = max(0, xi - rad), min(w, xi + rad + 1)
        y0, y1 = max(0, yi - rad), min(h, yi + rad + 1)
        if x0 >= x1 or y0 >= y1:
            out.append(np.nan if img.ndim == 2 else np.full(img.shape[2], np.nan))
        else:
            out.append(img[y0:y1, x0:x1].mean(axis=(0, 1)))
    return np.array(out)


def gray_to_binary(bits):
    """MSB-first Gray-code bits -> integer."""
    b, out = 0, 0
    for g in bits:
        b ^= g
        out = (out << 1) | b
    return out


# ---------------------------------------------------------------------------
# Per-frame decode
# ---------------------------------------------------------------------------
def decode_frame(gray, color, tracker):
    """Decode one frame given a valid tracker.H. Returns a dict of channels."""
    scale = tracker.scale or 1.0
    row = {"tick": None, "sweep_ms": None, "strip_contrast": None,
           "patches": None, "patch_rgb": None, "ball_x": None}

    # --- Gray strip ---
    rad = max(1, min(12, int(STRIP_BW * scale * 0.25)))
    centers = [(STRIP_X0 + i * STRIP_BW + STRIP_BW / 2, STRIP_Y + STRIP_BH / 2)
               for i in range(STRIP_BLOCKS)]
    vals = sample_means(gray, tracker.map_points(centers), rad)
    black, white = vals[0], vals[1]
    contrast = float(white - black)
    row["strip_contrast"] = contrast
    if contrast > 30:
        thr = (black + white) / 2.0
        bits = [1 if v < thr else 0 for v in vals[2:]]
        row["tick"] = gray_to_binary(bits)

    # --- sweep dial ---
    rad_s = max(1, int(4 * scale))
    fs = np.arange(SWEEP_SAMPLES) / SWEEP_SAMPLES
    ang = 2 * np.pi * fs - np.pi / 2
    pts = np.stack([DIAL_CX + np.cos(ang) * DIAL_SAMPLE_R,
                    DIAL_CY + np.sin(ang) * DIAL_SAMPLE_R], axis=1)
    lum = sample_means(gray, tracker.map_points(pts), rad_s)
    if np.isfinite(lum).all() and (lum.max() - lum.min()) > 30:
        kernel = np.ones(SWEEP_SMOOTH) / SWEEP_SMOOTH
        smooth = np.convolve(np.concatenate([lum, lum[:SWEEP_SMOOTH]]), kernel, "valid")
        idx = int(np.argmin(smooth[:SWEEP_SAMPLES]))
        # box filter of width w centered at idx + (w-1)/2
        center = (idx + (SWEEP_SMOOTH - 1) / 2.0) % SWEEP_SAMPLES
        row["sweep_ms"] = float(center / SWEEP_SAMPLES * 1000.0)

    # --- AE patches ---
    rad_p = max(1, min(12, int(PATCH_W * scale * 0.25)))
    centers = [(PATCH_X0 + i * PATCH_W + PATCH_W / 2, PATCH_Y + PATCH_H / 2)
               for i in range(PATCH_N)]
    pts_img = tracker.map_points(centers)
    row["patches"] = [float(v) for v in sample_means(gray, pts_img, rad_p)]
    if color is not None:
        rgb = sample_means(color, pts_img[-3:], rad_p)   # BGR order from cv2
        row["patch_rgb"] = [[float(c) for c in v] for v in rgb]

    # --- ball ---
    # sample past the travel extremes so the full disc stays in the window
    # (centroid would otherwise bias inward at the turnaround points)
    xs = np.linspace(BALL_XMIN - BALL_R - 10, BALL_XMAX + BALL_R + 10, 397)
    pts = np.stack([xs, np.full_like(xs, BALL_YC)], axis=1)
    lum = sample_means(gray, tracker.map_points(pts), max(1, int(4 * scale)))
    if np.isfinite(lum).all() and (lum.max() - lum.min()) > 60:
        thr = (lum.max() + lum.min()) / 2.0
        w = np.clip(thr - lum, 0, None)
        if w.sum() > 0:
            row["ball_x"] = float((xs * w).sum() / w.sum())

    return row


# ---------------------------------------------------------------------------
# Frame sources
# ---------------------------------------------------------------------------
IMG_EXTS = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp"}


def iter_frames(path, every=1, max_n=None):
    """Yield (index, src_ms, bgr_image). src_ms is NaN for directories."""
    p = pathlib.Path(path)
    if p.is_dir():
        files = sorted(f for f in p.iterdir() if f.suffix.lower() in IMG_EXTS)
        n = 0
        for i, f in enumerate(files):
            if i % every:
                continue
            img = cv2.imread(str(f))
            if img is None:
                continue
            yield i, float("nan"), img
            n += 1
            if max_n and n >= max_n:
                return
    else:
        cap = cv2.VideoCapture(str(p))
        if not cap.isOpened():
            sys.exit(f"cannot open {p}")
        i, n = 0, 0
        while True:
            pos = cap.get(cv2.CAP_PROP_POS_MSEC)
            ok, img = cap.read()
            if not ok:
                break
            if i % every == 0:
                yield i, float(pos), img
                n += 1
                if max_n and n >= max_n:
                    break
            i += 1
        cap.release()


# ---------------------------------------------------------------------------
# Sequence analysis
# ---------------------------------------------------------------------------
def analyze(path, every=1, max_n=None, detect_every=15):
    tracker = CardTracker()
    rows = []
    tick_offset = 0
    prev_tick = None
    for idx, src_ms, img in iter_frames(path, every, max_n):
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        qr_ms = None
        if tracker.H is None or (len(rows) % detect_every) == 0:
            qr_ms = tracker.detect(gray)
        if tracker.H is None:
            rows.append({"frame": idx, "src_ms": src_ms, "qr_ms": qr_ms,
                         "tick": None, "card_ms": None, "card_ms_fine": None,
                         "sweep_ms": None, "strip_contrast": None,
                         "patches": None, "patch_rgb": None, "ball_x": None})
            continue
        row = decode_frame(gray, img, tracker)
        row.update({"frame": idx, "src_ms": src_ms, "qr_ms": qr_ms})

        card_ms = None
        fine = None
        if row["tick"] is not None:
            t = row["tick"]
            if prev_tick is not None and t + tick_offset < prev_tick - TICK_WRAP // 2:
                tick_offset += TICK_WRAP
            t += tick_offset
            prev_tick = t
            card_ms = t * 1000.0 / TICK_HZ
            if row["sweep_ms"] is not None:
                cand = round((card_ms - row["sweep_ms"]) / 1000.0) * 1000.0 + row["sweep_ms"]
                if abs(cand - card_ms) < 40:
                    fine = cand
        row["card_ms"] = card_ms
        row["card_ms_fine"] = fine
        rows.append(row)
    return tracker, rows


def write_csv(rows, out_path):
    cols = ["frame", "src_ms", "card_ms", "card_ms_fine", "tick", "sweep_ms",
            "qr_ms", "strip_contrast", "ball_x"]
    patch_cols = [f"p{i}" for i in range(PATCH_N)]
    with open(out_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols + patch_cols)
        for r in rows:
            patches = r["patches"] or [None] * PATCH_N
            w.writerow([r.get(c) for c in cols] +
                       [None if p is None else round(p, 1) for p in patches])


def fmt_ms(v):
    return "-" if v is None else f"{v:9.1f}"


def trimmed_mean(vals):
    """Mean with min and max dropped (when there are enough samples).
    Robust to both tick-grid alternation and single gap outliers."""
    v = np.sort(np.asarray(vals, dtype=float))
    if len(v) >= 4:
        v = v[1:-1]
    return float(v.mean())


def summarize(rows):
    ok = [r for r in rows if r["card_ms"] is not None]
    print(f"\nframes: {len(rows)} read, {len(ok)} with card time "
          f"({len(rows) - len(ok)} undecoded)")
    if len(ok) < 3:
        print("not enough decoded frames for timing analysis")
        return

    # Prefer sweep-refined times: strip-only times quantize to the 16.7 ms
    # tick grid, which makes off-grid intervals (e.g. 40 ms at 25 fps) read
    # as an alternation of neighboring tick multiples.
    times = np.array([r["card_ms_fine"] if r["card_ms_fine"] is not None
                      else r["card_ms"] for r in ok])
    fine_n = sum(1 for r in ok if r["card_ms_fine"] is not None)

    span = (times[-1] - times[0]) / 1000.0
    print(f"card time span: {times[0]/1000.0:.3f}s .. {times[-1]/1000.0:.3f}s "
          f"({span:.3f}s)  [{fine_n}/{len(ok)} sweep-refined]")

    deltas = np.diff(times)
    backwards = [(ok[i]["frame"], float(d)) for i, d in enumerate(deltas) if d < 0]
    if backwards:
        print(f"WARNING: {len(backwards)} backwards steps (decode errors?): "
              f"{backwards[:5]}")

    # --- segment boundaries: windowed change-point on trimmed means -------
    K = 5
    boundaries = []
    if len(deltas) >= 2 * K + 2:
        score = np.zeros(len(deltas))
        for i in range(K, len(deltas) - K + 1):
            left = trimmed_mean(deltas[i - K:i])
            right = trimmed_mean(deltas[i:i + K])
            hi = max(left, right)
            if hi > 0:
                score[i] = abs(left - right) / hi
        cand = [i for i in range(K, len(deltas) - K + 1) if score[i] > 0.35]
        # non-maximum suppression: keep local peaks at least K apart
        for i in sorted(cand, key=lambda i: -score[i]):
            if all(abs(i - b) >= K for b in boundaries):
                boundaries.append(i)
        boundaries.sort()

    # --- gap events first: raw deltas far above their segment's typical
    # interval; excluded from the segment rate so a hole at a ramp switch
    # doesn't drag the reported fps down
    edges = [0] + boundaries + [len(deltas)]
    events = []
    gap_idx = set()
    for i0, i1 in zip(edges, edges[1:]):
        ref = trimmed_mean(deltas[i0:i1])
        for i in range(i0, i1):
            d = deltas[i]
            if ref > 0 and d > max(2.0 * ref, ref + 40.0):
                events.append((i, float(d), ref))
                gap_idx.add(i)

    # --- per-segment rate from span/count (tick quantization averages out)
    print(f"\nsegments ({len(edges) - 1}):")
    for i0, i1 in zip(edges, edges[1:]):
        gaps = [i for i in gap_idx if i0 <= i < i1]
        seg_span = times[i1] - times[i0] - sum(deltas[i] for i in gaps)
        n = i1 - i0 - len(gaps)
        fps = n / (seg_span / 1000.0) if seg_span > 0 else float("inf")
        note = f"  ({len(gaps)} gap{'s' if len(gaps) != 1 else ''} excluded)" if gaps else ""
        print(f"  {times[i0]/1000.0:8.3f}s .. {times[i1]/1000.0:8.3f}s  "
              f"{n:5d} intervals  mean {seg_span/n:7.2f} ms  ({fps:.2f} fps){note}")
    if events:
        print(f"\ngap events ({len(events)}):")
        for i, d, ref in events[:20]:
            print(f"  frame {ok[i]['frame']:5d} -> {ok[i+1]['frame']:5d}  "
                  f"at card {times[i]/1000.0:8.3f}s  interval {d:8.2f} ms  "
                  f"({d/ref:5.2f}x segment interval)")
        if len(events) > 20:
            print(f"  ... {len(events) - 20} more")

    # AE stability
    plists = [r["patches"] for r in ok if r["patches"] is not None]
    if len(plists) >= 3:
        arr = np.array(plists)
        print("\nAE patches (luma over run):")
        names = [f"gray{g}" for g in PATCH_GRAYS] + ["R", "G", "B"]
        for i, name in enumerate(names):
            col = arr[:, i]
            step = float(np.abs(np.diff(col)).max()) if len(col) > 1 else 0.0
            print(f"  {name:>8}: mean {col.mean():6.1f}  std {col.std():5.2f}  "
                  f"max step {step:5.2f}")

    # source clock vs card clock
    src = np.array([r["src_ms"] for r in ok], dtype=float)
    card = np.array([r["card_ms"] for r in ok], dtype=float)
    good = np.isfinite(src)
    if good.sum() >= 3 and np.ptp(src[good]) > 0:
        slope, intercept = np.polyfit(src[good], card[good], 1)
        resid = card[good] - (slope * src[good] + intercept)
        print(f"\ncontainer clock vs card clock: slope {slope:.5f} "
              f"(1.0 = real time)  rms residual {resid.std():.2f} ms")


# ---------------------------------------------------------------------------
# Self-test: headless Chrome renders frozen frames, we assert the decode
# ---------------------------------------------------------------------------
def selftest(chrome, keep):
    card = pathlib.Path(__file__).parent / "testcard" / "index.html"
    if not card.exists():
        sys.exit(f"card not found: {card}")
    if not os.path.exists(chrome):
        sys.exit(f"Chrome not found at {chrome} (use --chrome)")

    outdir = pathlib.Path(tempfile.mkdtemp(prefix="testcard_selftest_"))
    times = [0, 1234, 12717, 59999, 61000, 305500]
    print(f"rendering {len(times)} frozen frames -> {outdir}")
    for t in times:
        png = outdir / f"t{t:08d}.png"
        subprocess.run(
            [chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars",
             "--force-device-scale-factor=1", "--window-size=1000,1600",
             "--virtual-time-budget=3000", f"--screenshot={png}",
             f"file://{card}?t={t}"],
            capture_output=True, check=False)
        if not png.exists():
            sys.exit(f"Chrome produced no screenshot for t={t}")

    failures = 0
    tracker = CardTracker()
    print(f"{'t (ms)':>8} {'tick':>6} {'exp':>6} {'sweep':>7} {'qr_ms':>8} "
          f"{'ball_x':>7} {'exp':>7}  result")
    for t in times:
        img = cv2.imread(str(outdir / f"t{t:08d}.png"))
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        qr_ms = tracker.detect(gray)
        problems = []
        if tracker.H is None:
            problems.append("no homography (QR not detected)")
            row = {"tick": None, "sweep_ms": None, "ball_x": None, "patches": None}
        else:
            row = decode_frame(gray, img, tracker)

        exp_tick = (t * 60) // 1000
        exp_qr = (t // 500) * 500
        phase = (t % BALL_PERIOD) / BALL_PERIOD
        tri = phase * 2 if phase < 0.5 else 2 - phase * 2
        exp_ball = BALL_XMIN + tri * (BALL_XMAX - BALL_XMIN)

        if row["tick"] != exp_tick % TICK_WRAP:
            problems.append(f"tick {row['tick']} != {exp_tick}")
        if qr_ms is not None and qr_ms != exp_qr:
            problems.append(f"qr {qr_ms} != {exp_qr}")
        if qr_ms is None:
            problems.append("time QR not decoded")
        if row["sweep_ms"] is None:
            problems.append("sweep not read")
        else:
            diff = abs(row["sweep_ms"] - (t % 1000))
            if min(diff, 1000 - diff) > 25:
                problems.append(f"sweep {row['sweep_ms']:.0f} != {t % 1000}")
        if row["ball_x"] is None or abs(row["ball_x"] - exp_ball) > 12:
            problems.append(f"ball {row['ball_x']} != {exp_ball:.0f}")
        if row["patches"] is not None:
            grays = row["patches"][:6]
            if any(b <= a for a, b in zip(grays, grays[1:])):
                problems.append(f"gray patches not monotone: {grays}")

        status = "PASS" if not problems else "FAIL: " + "; ".join(problems)
        if problems:
            failures += 1
        print(f"{t:>8} {str(row['tick']):>6} {exp_tick:>6} "
              f"{'-' if row['sweep_ms'] is None else format(row['sweep_ms'], '.1f'):>7} "
              f"{str(qr_ms):>8} "
              f"{'-' if row['ball_x'] is None else format(row['ball_x'], '.1f'):>7} "
              f"{exp_ball:>7.1f}  {status}")

    if tracker.script:
        print(f"session script decoded: {tracker.script}")
    if not keep:
        for f in outdir.iterdir():
            f.unlink()
        outdir.rmdir()
    else:
        print(f"kept frames in {outdir}")
    if failures:
        sys.exit(f"{failures}/{len(times)} cases FAILED")
    print(f"all {len(times)} cases passed")


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("report", help="decode a clip/frame-dir and print timing report")
    r.add_argument("input", help="video file or directory of extracted frames")
    r.add_argument("--out", help="per-frame CSV path (default <input>_testcard.csv)")
    r.add_argument("--every", type=int, default=1, help="analyze every Nth frame")
    r.add_argument("--max", type=int, default=None, help="stop after N analyzed frames")
    r.add_argument("--detect-every", type=int, default=15,
                   help="QR/homography refresh cadence in analyzed frames")

    s = sub.add_parser("selftest", help="render frozen frames via headless Chrome and verify decode")
    s.add_argument("--chrome", default=CHROME)
    s.add_argument("--keep", action="store_true", help="keep rendered frames")

    args = ap.parse_args()
    if args.cmd == "selftest":
        selftest(args.chrome, args.keep)
        return

    tracker, rows = analyze(args.input, args.every, args.max, args.detect_every)
    if tracker.script:
        print(f"session script: {tracker.script}")
    out = args.out or (str(pathlib.Path(args.input).with_suffix("")) + "_testcard.csv")
    write_csv(rows, out)
    print(f"per-frame CSV: {out}")
    summarize(rows)


if __name__ == "__main__":
    main()
