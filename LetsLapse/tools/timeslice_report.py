#!/usr/bin/env python3
"""Ladder audit for a time-sliced clip.

The quality gate for time slicing (docs/time-slicing.md §7): every band of a
sliced clip should show the source a fixed number of frames behind its
neighbour — the reference clip measured as a dead-straight 0, 2, 4 … 46
ladder. This tool re-runs that measurement on a rendered slice:

  tools/.venv/bin/python tools/timeslice_report.py <sliced.mp4> \
      --segments 24 --lag 2 --newest left

Per frame it takes each band's mean luma, cross-correlates every band's
series against the newest band's, and fits the measured lags to a line. The
verdict is greppable: TIMESLICE PASS when the fitted ladder matches the
commanded segments/lag/direction within a frame, TIMESLICE FAIL otherwise.

Band geometry mirrors TimeSliceGeometry.bandRanges (floor boundaries), scaled
to the analysis resolution; bands are wide enough that ±1 px of boundary
wobble does not move a mean.
"""

from __future__ import annotations

import argparse
import sys

import cv2
import numpy as np

EDGES = ("left", "right", "top", "bottom")


def band_slices(length: int, segments: int) -> list[slice]:
    bounds = [length * i // segments for i in range(segments + 1)]
    bounds[-1] = length
    return [slice(bounds[i], bounds[i + 1]) for i in range(segments)]


def band_means(path: str, segments: int, horizontal: bool, scale_width: int) -> np.ndarray:
    capture = cv2.VideoCapture(path)
    if not capture.isOpened():
        sys.exit(f"error: cannot open {path}")
    series: list[np.ndarray] = []
    slices = None
    while True:
        ok, frame = capture.read()
        if not ok:
            break
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        if gray.shape[1] > scale_width:
            new_h = max(1, round(gray.shape[0] * scale_width / gray.shape[1]))
            gray = cv2.resize(gray, (scale_width, new_h), interpolation=cv2.INTER_AREA)
        if slices is None:
            axis_len = gray.shape[0] if horizontal else gray.shape[1]
            slices = band_slices(axis_len, segments)
        if horizontal:
            means = [float(gray[s, :].mean()) for s in slices]
        else:
            means = [float(gray[:, s].mean()) for s in slices]
        series.append(np.array(means))
    capture.release()
    if not series:
        sys.exit("error: no frames decoded")
    return np.stack(series)  # (frames, segments)


def measured_lag(reference: np.ndarray, candidate: np.ndarray, max_shift: int) -> tuple[int, float]:
    """Signed shift (in frames) at which `candidate` best matches `reference` —
    positive means the band lags the reference band, negative that it leads
    (the reference is variance-ranked, so it can sit anywhere on the ladder).

    Correlates FIRST DIFFERENCES and requires the overlap to keep at least
    half the series: a smooth monotonic ramp (a plain sunset) otherwise
    correlates near 1.0 at absurd shifts over tiny overlaps, which is exactly
    how the first field audit went wrong."""
    reference = np.diff(reference)
    candidate = np.diff(candidate)
    minimum_overlap = max(16, len(reference) // 2)
    best_shift, best_score = 0, -2.0
    for shift in range(-max_shift, max_shift + 1):
        if shift >= 0:
            a = reference[: len(reference) - shift]
            b = candidate[shift:]
        else:
            a = reference[-shift:]
            b = candidate[: len(candidate) + shift]
        if len(a) < minimum_overlap:
            continue
        a = a - a.mean()
        b = b - b.mean()
        denominator = np.sqrt((a * a).sum() * (b * b).sum())
        score = float((a * b).sum() / denominator) if denominator > 0 else 0.0
        if score > best_score:
            best_shift, best_score = shift, score
    return best_shift, best_score


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("clip", help="the sliced clip to audit")
    parser.add_argument("--segments", type=int, default=24)
    parser.add_argument("--lag", type=int, default=2, help="commanded frames of lag per band")
    parser.add_argument("--newest", choices=EDGES, default="left", help="edge holding the newest band")
    parser.add_argument("--scale-width", type=int, default=480, help="analysis width (means only, speed)")
    args = parser.parse_args()

    horizontal = args.newest in ("top", "bottom")
    series = band_means(args.clip, args.segments, horizontal, args.scale_width)
    frames = series.shape[0]
    print(f"{args.clip}: {frames} frames, {args.segments} bands "
          f"({'horizontal' if horizontal else 'vertical'}, newest {args.newest})")

    # Bands enumerated newest → oldest. The reference is the band whose series
    # actually varies — anchoring on a flat band correlates with noise. The
    # fit handles the reference's own lag as the intercept.
    newest_leads = args.newest in ("left", "top")
    order = list(range(args.segments)) if newest_leads else list(range(args.segments - 1, -1, -1))
    variances = [float(series[:, band].var()) for band in order]
    reference_position = int(np.argmax(variances))
    reference = series[:, order[reference_position]]
    # Search to twice the commanded spread, never past half the series — the
    # overlap floor in measured_lag needs the other half to stay meaningful.
    max_shift = min(frames // 2, max(8, 2 * args.lag * (args.segments - 1)))

    lags, scores = [], []
    for band in order:
        shift, score = measured_lag(reference, series[:, band], max_shift)
        lags.append(shift)
        scores.append(score)

    print("measured lags vs reference band (newest → oldest): "
          + " ".join(str(l) for l in lags))

    # A lag is a measurement only where the correlation is strong. A slowly
    # varying static scene gives the mean-luma series nothing to grip — the
    # gate this tool exists for is a day-to-night shoot, where every band
    # carries the whole light curve.
    minimum_score = 0.85
    valid = [(position, lag) for position, (lag, score) in enumerate(zip(lags, scores))
             if score >= minimum_score]
    needed = max(4, args.segments // 3)
    if len(valid) < needed:
        print(f"only {len(valid)} of {args.segments} bands correlate ≥{minimum_score} — "
              "the scene is too flat for the luma-ladder measurement "
              "(use a day-to-night clip, or verify visually / with the Kit tests)")
        print("TIMESLICE INCONCLUSIVE")
        sys.exit(2)

    positions = np.array([p for p, _ in valid], dtype=float)
    measured = np.array([l for _, l in valid], dtype=float)
    fit = np.polyfit(positions, measured, 1)
    slope, intercept = float(fit[0]), float(fit[1])
    residuals = measured - (slope * positions + intercept)
    worst = float(np.abs(residuals).max())
    excluded = args.segments - len(valid)

    print(f"fitted over {len(valid)} measurable bands"
          + (f" ({excluded} excluded as weak)" if excluded else "")
          + f": slope {slope:.3f} frames/band (commanded {args.lag}), "
            f"worst residual {worst:.2f} frames")
    print(f"total spread: fitted {slope * (args.segments - 1):.1f} frames, "
          f"commanded {args.lag * (args.segments - 1)}")

    ordered = all(b >= a for a, b in zip(measured, measured[1:]))
    passes = abs(slope - args.lag) <= 0.25 and worst <= 1.0 and ordered
    print(f"TIMESLICE {'PASS' if passes else 'FAIL'}")
    sys.exit(0 if passes else 1)


if __name__ == "__main__":
    main()
