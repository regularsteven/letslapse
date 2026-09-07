#!/usr/bin/env python3
"""Measure how close a LetsLapse render lands to Lightroom's own export.

    python3 tools/lightroom_compare.py <lightroom.jpg> <ours.jpg> [--out DIR]

Both files must be the same pixel size and BOTH must already be in sRGB —
convert first if they are not (`sips --matchTo "/System/Library/ColorSync/
Profiles/sRGB Profile.icc"`), because every number below is meaningless
across two different colour spaces.

WHAT IT REPORTS, and why each one is here:

  Exposure offset   The mean-luminance ratio in LINEAR light, said in stops.
                    The single most useful number: it separates "we are
                    rendering the same picture slightly brighter" from "we
                    are rendering a different picture".
  ΔE2000            Perceptual colour difference, per pixel. ~1 is the
                    just-noticeable threshold for adjacent patches, 2-3 is
                    "a careful eye sees it in a comparison", >5 is obvious.
                    Reported as a distribution because a mean hides the tail
                    that people actually notice.
  Tone curve        Mean output level in eleven input bands. This is the
                    shape of the disagreement — a renderer that is close in
                    the mids and far in the shadows is a different problem
                    from one that is uniformly off.
  Region grid       Where on the picture the difference lives, so a local
                    mask's contribution can be told apart from a global one.

Nothing here decides whether a difference matters. It measures.
"""

import argparse
import os
import sys

import numpy as np

try:
    import cv2
except ImportError:
    sys.exit("needs opencv — run inside tools/.venv")


def load_srgb(path):
    """An image as float RGB 0..1, sRGB-encoded."""
    image = cv2.imread(path, cv2.IMREAD_COLOR)
    if image is None:
        sys.exit(f"could not read {path}")
    return cv2.cvtColor(image, cv2.COLOR_BGR2RGB).astype(np.float64) / 255.0


def linearise(srgb):
    """sRGB EOTF. Light adds up in linear; encoded values do not."""
    return np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)


def luminance(linear_rgb):
    return (0.2126 * linear_rgb[..., 0]
            + 0.7152 * linear_rgb[..., 1]
            + 0.0722 * linear_rgb[..., 2])


def to_lab(srgb):
    """sRGB 0..1 → CIE L*a*b* (D65), the space ΔE is defined in."""
    linear = linearise(srgb)
    matrix = np.array([[0.4124564, 0.3575761, 0.1804375],
                       [0.2126729, 0.7151522, 0.0721750],
                       [0.0193339, 0.1191920, 0.9503041]])
    xyz = linear @ matrix.T
    white = np.array([0.95047, 1.00000, 1.08883])
    xyz = xyz / white
    epsilon, kappa = 216 / 24389, 24389 / 27
    f = np.where(xyz > epsilon, np.cbrt(xyz), (kappa * xyz + 16) / 116)
    return np.stack([116 * f[..., 1] - 16,
                     500 * (f[..., 0] - f[..., 1]),
                     200 * (f[..., 1] - f[..., 2])], axis=-1)


def delta_e_2000(lab1, lab2):
    """CIEDE2000. The standard perceptual difference, worth the arithmetic:
    ΔE76 overstates differences in saturated blues, and a sunset is mostly
    saturated blues and oranges."""
    L1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    L2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]
    C1, C2 = np.hypot(a1, b1), np.hypot(a2, b2)
    C_bar = (C1 + C2) / 2
    G = 0.5 * (1 - np.sqrt(C_bar ** 7 / (C_bar ** 7 + 25.0 ** 7 + 1e-12)))
    a1p, a2p = (1 + G) * a1, (1 + G) * a2
    C1p, C2p = np.hypot(a1p, b1), np.hypot(a2p, b2)
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360
    h2p = np.degrees(np.arctan2(b2, a2p)) % 360
    dLp = L2 - L1
    dCp = C2p - C1p
    dhp = h2p - h1p
    dhp = np.where(dhp > 180, dhp - 360, np.where(dhp < -180, dhp + 360, dhp))
    dhp = np.where(C1p * C2p == 0, 0, dhp)
    dHp = 2 * np.sqrt(C1p * C2p) * np.sin(np.radians(dhp / 2))
    Lp_bar = (L1 + L2) / 2
    Cp_bar = (C1p + C2p) / 2
    hsum = h1p + h2p
    hdiff = np.abs(h1p - h2p)
    hp_bar = np.where(C1p * C2p == 0, hsum,
                      np.where(hdiff <= 180, hsum / 2,
                               np.where(hsum < 360, (hsum + 360) / 2, (hsum - 360) / 2)))
    T = (1 - 0.17 * np.cos(np.radians(hp_bar - 30))
         + 0.24 * np.cos(np.radians(2 * hp_bar))
         + 0.32 * np.cos(np.radians(3 * hp_bar + 6))
         - 0.20 * np.cos(np.radians(4 * hp_bar - 63)))
    d_theta = 30 * np.exp(-(((hp_bar - 275) / 25) ** 2))
    R_C = 2 * np.sqrt(Cp_bar ** 7 / (Cp_bar ** 7 + 25.0 ** 7 + 1e-12))
    S_L = 1 + (0.015 * (Lp_bar - 50) ** 2) / np.sqrt(20 + (Lp_bar - 50) ** 2)
    S_C = 1 + 0.045 * Cp_bar
    S_H = 1 + 0.015 * Cp_bar * T
    R_T = -np.sin(np.radians(2 * d_theta)) * R_C
    return np.sqrt((dLp / S_L) ** 2 + (dCp / S_C) ** 2 + (dHp / S_H) ** 2
                   + R_T * (dCp / S_C) * (dHp / S_H))


def band_table(reference_luma, ours_luma, bands=11):
    """Mean output level in bands of the REFERENCE's own tone, so the rows
    read as 'where Lightroom put this much light, we put that much'."""
    rows = []
    edges = np.linspace(0, 1, bands + 1)
    for lo, hi in zip(edges[:-1], edges[1:]):
        mask = (reference_luma >= lo) & (reference_luma < hi)
        count = int(mask.sum())
        if count < 1000:
            continue
        rows.append((lo, hi, count,
                     float(reference_luma[mask].mean()),
                     float(ours_luma[mask].mean())))
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", help="Lightroom's export (sRGB)")
    parser.add_argument("ours", help="our render (sRGB, same pixel size)")
    parser.add_argument("--out", default=None, help="directory for the difference maps")
    parser.add_argument("--grid", type=int, default=8, help="region grid columns")
    args = parser.parse_args()

    reference = load_srgb(args.reference)
    ours = load_srgb(args.ours)
    if reference.shape != ours.shape:
        sys.exit(f"size mismatch: {reference.shape[:2]} vs {ours.shape[:2]}")
    height, width = reference.shape[:2]
    print(f"comparing {width}×{height}")
    print(f"  reference  {os.path.basename(args.reference)}")
    print(f"  ours       {os.path.basename(args.ours)}\n")

    ref_lin, our_lin = linearise(reference), linearise(ours)
    ref_lum, our_lum = luminance(ref_lin), luminance(our_lin)

    stops = np.log2(max(our_lum.mean(), 1e-9) / max(ref_lum.mean(), 1e-9))
    print("EXPOSURE")
    print(f"  mean luminance   reference {ref_lum.mean():.4f}   ours {our_lum.mean():.4f}")
    print(f"  offset           {stops:+.3f} stops")

    print("\nPER CHANNEL (sRGB 0-255)")
    for index, name in enumerate("RGB"):
        r, o = reference[..., index] * 255, ours[..., index] * 255
        print(f"  {name}   reference {r.mean():6.2f}   ours {o.mean():6.2f}   Δ {o.mean() - r.mean():+6.2f}")

    lab_ref, lab_our = to_lab(reference), to_lab(ours)
    de = delta_e_2000(lab_ref, lab_our)
    print("\nΔE2000  (1 = just noticeable, 2-3 = visible side by side, >5 = obvious)")
    for label, value in [("mean", de.mean()), ("median", np.median(de)),
                         ("p90", np.percentile(de, 90)), ("p99", np.percentile(de, 99)),
                         ("max", de.max())]:
        print(f"  {label:6s} {value:6.2f}")
    for threshold in (1, 2, 3, 5):
        share = float((de < threshold).mean()) * 100
        print(f"  under {threshold}: {share:5.1f}% of pixels")

    print("\nTONE  (mean output where the reference sits in each band, 0-1)")
    print("   reference band      px%     reference    ours       Δ")
    for lo, hi, count, ref_mean, our_mean in band_table(ref_lum, our_lum):
        share = count / ref_lum.size * 100
        print(f"   {lo:.2f}–{hi:.2f}        {share:5.1f}%    {ref_mean:.4f}    {our_mean:.4f}   {our_mean - ref_mean:+.4f}")

    columns = args.grid
    rows = max(1, round(columns * height / width))
    print(f"\nREGIONS  ΔE2000 mean, {columns}×{rows}")
    for row in range(rows):
        cells = []
        for column in range(columns):
            y0, y1 = row * height // rows, (row + 1) * height // rows
            x0, x1 = column * width // columns, (column + 1) * width // columns
            cells.append(f"{de[y0:y1, x0:x1].mean():5.2f}")
        print("   " + " ".join(cells))

    if args.out:
        os.makedirs(args.out, exist_ok=True)
        # ΔE as a heat map, clipped at 6 so the everyday range fills the ramp.
        heat = np.clip(de / 6.0, 0, 1)
        heat = cv2.applyColorMap((heat * 255).astype(np.uint8), cv2.COLORMAP_INFERNO)
        cv2.imwrite(os.path.join(args.out, "delta-e.jpg"), heat,
                    [cv2.IMWRITE_JPEG_QUALITY, 92])
        # Signed luminance difference: blue where we are darker, red brighter.
        delta = np.clip((our_lum - ref_lum) * 4 + 0.5, 0, 1)
        cv2.imwrite(os.path.join(args.out, "delta-luma.jpg"),
                    cv2.applyColorMap((delta * 255).astype(np.uint8), cv2.COLORMAP_COOL),
                    [cv2.IMWRITE_JPEG_QUALITY, 92])
        print(f"\nwrote delta-e.jpg and delta-luma.jpg to {args.out}")


if __name__ == "__main__":
    main()
