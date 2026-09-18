#!/usr/bin/env python3
"""Measure the viewfinder's magnification through a screen recording, frame by frame.

A zoom bug that only shows in the live preview cannot be pulled off the phone
as a file, but a screen recording of the capture screen is a measurement: the
scale of each frame against a reference frame IS the zoom factor relative to
that reference. ORB features + RANSAC partial-affine per frame, restricted to
the viewfinder rows so the chip row and the shutter cluster do not vote.

Used on 2026-09-18 for the Photo-mode punch-in (a Find Shapes press after a
5x→1x lens change cut the framing to 2.50× = raw factor 5.0 on an iPhone 16
Pro) and to trace the lens ramps themselves: the ramp reached raw 4.0 of 10 in
0.37 s and was then snapped by the app's own +0.35 s zoom re-assert. Two
references make a ramp readable end to end — the frame matches the stop it is
leaving early on and the stop it is reaching late on; take whichever has more
inliers.

    tools/.venv/bin/python tools/zoom_curve.py <recording.mp4> --ref 37.0 --from 38.9 --to 40.1 --step 0.0167
    tools/.venv/bin/python tools/zoom_curve.py <recording.mp4> --ref 25.0 --ref2 37.0 --from 29.4 --to 31.0 --step 0.0167

Times are seconds into the recording. The ROI defaults to rows 250..1750 of a
1206×2622 portrait iPhone recording (the viewfinder above the controls);
`--roi top:bottom` overrides it. Needs tools/.venv (numpy + opencv).
"""
import argparse

import cv2
import numpy as np


def grab(cap, t, roi):
    cap.set(cv2.CAP_PROP_POS_MSEC, t * 1000)
    ok, frame = cap.read()
    if not ok:
        return None
    return cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)[roi[0]:roi[1], :]


def scale_between(orb, matcher, ref, tgt):
    (kpr, der), (kpt, det) = ref, tgt
    if der is None or det is None or len(kpr) < 8 or len(kpt) < 8:
        return None, 0
    matches = matcher.knnMatch(der, det, k=2)
    good = [m for m, n in (p for p in matches if len(p) == 2) if m.distance < 0.75 * n.distance]
    if len(good) < 8:
        return None, len(good)
    src = np.float32([kpr[m.queryIdx].pt for m in good])
    dst = np.float32([kpt[m.trainIdx].pt for m in good])
    matrix, inliers = cv2.estimateAffinePartial2D(src, dst, method=cv2.RANSAC, ransacReprojThreshold=4.0)
    if matrix is None:
        return None, 0
    return float(np.hypot(matrix[0, 0], matrix[0, 1])), int(inliers.sum())


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("video")
    ap.add_argument("--ref", type=float, required=True, help="reference frame time (s)")
    ap.add_argument("--ref2", type=float, help="second reference frame time (s)")
    ap.add_argument("--from", dest="t0", type=float, required=True)
    ap.add_argument("--to", dest="t1", type=float, required=True)
    ap.add_argument("--step", type=float, default=0.5)
    ap.add_argument("--roi", default="250:1750", help="rows top:bottom to measure in")
    args = ap.parse_args()

    roi = tuple(int(v) for v in args.roi.split(":"))
    orb = cv2.ORB_create(nfeatures=4000, scaleFactor=1.2, nlevels=12)
    matcher = cv2.BFMatcher(cv2.NORM_HAMMING)
    cap = cv2.VideoCapture(args.video)

    def features(t):
        gray = grab(cap, t, roi)
        return orb.detectAndCompute(gray, None) if gray is not None else (None, None)

    ref = features(args.ref)
    ref2 = features(args.ref2) if args.ref2 is not None else None
    print(f"# ref {args.ref:.2f}s ({len(ref[0] or [])} kp)"
          + (f", ref2 {args.ref2:.2f}s ({len(ref2[0] or [])} kp)" if ref2 else ""))
    t = args.t0
    while t <= args.t1 + 1e-9:
        f = features(t)
        if f[0] is None:
            break
        s1, n1 = scale_between(orb, matcher, ref, f)
        line = f"t={t:8.3f}  vs ref: " + (f"scale {s1:.3f} ({n1} inl)" if s1 else f"-- ({n1})")
        if ref2:
            s2, n2 = scale_between(orb, matcher, ref2, f)
            line += "   vs ref2: " + (f"scale {s2:.3f} ({n2} inl)" if s2 else f"-- ({n2})")
        print(line)
        t += args.step


if __name__ == "__main__":
    main()
