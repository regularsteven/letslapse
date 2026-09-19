"""Scene composition: sky + ground + one subject through ONE affine matrix.

A scene is placed by (cx, cy, scalePx, tiltDeg, yawDeg): the subject group
carries a single SVG `matrix(...)` — translate · scale · foreshorten, where
foreshortening scales x by cos(yaw) and y by cos(tilt) with a small shear to
suggest the turned side — and `truth` is the subject's local outline through
THAT SAME matrix. So a quad truth is a parallelogram of the local rectangle,
and a circle's truth is the exact ellipse an affine makes of it (from the SVD
of the linear part, so tilt/yaw are exact for the clock too).

Coordinates (contract §1): everything here is the frame's pixels, y down,
origin top-left — SVG's own space, so nothing flips. Quad corners are
clockwise from top-left; an ellipse's rotation is the major axis's angle as
`atan2(dy, dx)` gives it in that frame, wrapped to (−π/2, π/2] like the Kit.
"""
from __future__ import annotations

import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from parts import GROUNDS, SKIES, SUBJECTS, Subject, parse_scene_name  # noqa: E402

# Viewpoint → (yawDeg, tiltDeg). Yaw turns the subject about its vertical
# axis (x foreshortens), tilt about its horizontal axis (y foreshortens).
#
# Why 22° and not 30° of yaw: the clock's dial under yaw θ with the shear is
# an ellipse of obliquity ≈ cos θ, and the Kit calls an ellipse a `circle`
# only at obliquity ≥ 0.85 (`DetectedShape.family`, `ShapeMatch.minRoundness`).
# 30° gave 0.854 — one degree from every left/right clock scene flipping to
# `oval`. 22° gives 0.915 (tilt 20° gives 0.928), the ≥ 0.05 margin the
# selftest pins for every subject × viewpoint; the tram's seen aspect at 22°
# is 1.43 against the 1.25 square boundary.
VIEWPOINTS = {
    "front": (0.0, 0.0),
    "left": (-22.0, 0.0),
    "right": (22.0, 0.0),
    "above": (0.0, 20.0),
    "below": (0.0, -20.0),
}
SHEAR = 0.12          # how much of sin(angle) leaks into the cross axis (the "side" hint)
FAMILY_MARGIN = 0.05  # how far a truth's seen aspect / obliquity must sit from the Kit's family boundary
TOP_MARGIN = 0.03     # fraction of H kept clear above the tallest subject
DEFAULT_FRAME = (4032, 3024)


# ---------------------------------------------------------------------------
# The matrix
# ---------------------------------------------------------------------------

def placement_matrix(cx: float, cy: float, scale_px: float, tilt_deg: float, yaw_deg: float) -> np.ndarray:
    """3×3 row-major, local units → frame pixels: T(cx, cy) · S(scalePx) · F(yaw, tilt)."""
    yaw, tilt = math.radians(yaw_deg), math.radians(tilt_deg)
    F = np.array([[math.cos(yaw), SHEAR * math.sin(tilt)],
                  [SHEAR * math.sin(yaw), math.cos(tilt)]], dtype=float)
    M = np.eye(3)
    M[:2, :2] = scale_px * F
    M[0, 2], M[1, 2] = cx, cy
    return M


def svg_matrix(M: np.ndarray) -> str:
    """SVG's matrix(a b c d e f) maps (x, y) → (a·x + c·y + e, b·x + d·y + f)."""
    a, c, e = M[0]
    b, d, f = M[1]
    return f"matrix({a:.6f} {b:.6f} {c:.6f} {d:.6f} {e:.4f} {f:.4f})"


def apply(M: np.ndarray, pts) -> list[list[float]]:
    P = np.asarray(pts, dtype=float).reshape(-1, 2)
    out = (M[:2, :2] @ P.T).T + M[:2, 2]
    return [[float(x), float(y)] for x, y in out]


def wrap_rotation(r: float) -> float:
    """(−π/2, π/2], the Kit's `wrapped`."""
    while r > math.pi / 2:
        r -= math.pi
    while r <= -math.pi / 2:
        r += math.pi
    return r


def truth_of(subject: Subject, M: np.ndarray, tilt_deg: float, yaw_deg: float) -> dict:
    kind, figure = subject.outline
    if kind == "quad":
        return {"kind": "quad", "cornersPx": apply(M, figure), "tiltDeg": tilt_deg, "yawDeg": yaw_deg}
    cx, cy, r = figure
    centre = apply(M, [(cx, cy)])[0]
    L = M[:2, :2]
    U, S, _ = np.linalg.svd(L)
    a, b = float(S[0] * r), float(S[1] * r)
    rot = 0.0 if (a - b) <= 1e-9 * a else wrap_rotation(math.atan2(float(U[1, 0]), float(U[0, 0])))
    return {"kind": "ellipse", "centrePx": centre, "semiAxesPx": [a, b], "rotation": rot,
            "tiltDeg": tilt_deg, "yawDeg": yaw_deg}


# ---------------------------------------------------------------------------
# The family the Kit will see (DetectedShape.family, ShapeRegister.swift)
# ---------------------------------------------------------------------------

def quad_sides(corners) -> tuple[float, float]:
    """(width, height): the mean top/bottom edge and the mean side — `quadMetrics` in the Kit."""
    c = np.asarray(corners, dtype=float)
    d = lambda i, j: float(np.hypot(*(c[i] - c[j])))  # noqa: E731
    return (d(0, 1) + d(3, 2)) / 2, (d(0, 3) + d(1, 2)) / 2


def family_and_margin(shape: dict) -> tuple[str, float]:
    """The Kit family a truth or perturbed shape lands in, and how far its
    deciding number sits from the boundary (positive = inside the family it
    reports). Quads: the seen aspect (longer mean side over shorter) against
    1.25 — `square` up to it, `rectangle` past it. Ellipses: obliquity (b/a)
    against 0.85 — `circle` at or above, `oval` below."""
    if shape["kind"] == "quad":
        w, h = quad_sides(shape["cornersPx"])
        aspect = max(w, h) / min(w, h) if min(w, h) > 0 else float("inf")
        return ("rectangle", aspect - 1.25) if aspect > 1.25 else ("square", 1.25 - aspect)
    a, b = shape["semiAxesPx"]
    obliquity = b / a if a > 0 else 0.0
    return ("circle", obliquity - 0.85) if obliquity >= 0.85 else ("oval", 0.85 - obliquity)


# ---------------------------------------------------------------------------
# Placement along a run
# ---------------------------------------------------------------------------

def stand_line(scene: str) -> float:
    """The fraction of H the subject's base sits on: the last ground token decides."""
    _, grounds = parse_scene_name(scene)
    return max(GROUNDS[g](100, 100).stand_y for g in grounds[-1:])


def subject_top(subject: Subject) -> float:
    """Local y of the subject's highest drawn point (decoration included)."""
    return {"tram_front": -0.565, "clock": -0.5}.get(subject.name, -0.5)


def scale_range(subject: Subject, W: int, H: int, stand_y: float) -> tuple[float, float]:
    """The pixel scale a run walks: from a tenth of the width up to what still fits above the stand line."""
    fit = (stand_y - TOP_MARGIN) * H / (subject.base_y - subject_top(subject))
    s_max = min(0.5 * W, fit)
    s_min = min(0.10 * W, s_max / 2)
    return s_min, s_max


def place(subject: Subject, W: int, H: int, scene: str, viewpoint: str, approach: float, rng: np.random.Generator) -> dict:
    """(cx, cy, scalePx, tilt, yaw) for one scene of a run: scale grows geometrically with
    `approach`, cx drifts left → right with a seeded wobble, cy puts the base on the stand line."""
    yaw, tilt = VIEWPOINTS[viewpoint]
    stand = stand_line(scene)
    s_min, s_max = scale_range(subject, W, H, stand)
    scale_px = s_min * (s_max / s_min) ** approach
    cx = W * (0.32 + 0.36 * approach) + float(rng.normal(0, 0.02 * W))
    cy = stand * H - scale_px * math.cos(math.radians(tilt)) * subject.base_y + float(rng.normal(0, 0.005 * H))
    return {"cx": cx, "cy": cy, "scalePx": scale_px, "tiltDeg": tilt, "yawDeg": yaw}


# ---------------------------------------------------------------------------
# The SVG document and the manifest
# ---------------------------------------------------------------------------

def scene_svg(W: int, H: int, scene: str, subject: Subject, M: np.ndarray) -> str:
    sky, grounds = parse_scene_name(scene)
    body = SKIES[sky](W, H) + "".join(GROUNDS[g](W, H).svg for g in grounds)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">'
            f'{body}<g transform="{svg_matrix(M)}">{subject.svg}</g></svg>')


def manifest(*, id: str, set_name: str, W: int, H: int, subject: Subject, viewpoint: str, scene: str,
             index: int, of: int, approach: float, truth: dict, perturbed: dict, sigmas: dict, seed: int,
             placement: dict, M: np.ndarray) -> dict:
    return {
        "schema": 1,
        "id": id,
        "set": set_name,
        "frame": {"width": W, "height": H},
        "subject": {"part": subject.name, "viewpoint": viewpoint, "scene": scene, "family": subject.family},
        "sequence": {"index": index, "of": of, "approach": approach},
        "truth": truth,
        "perturbed": perturbed,
        "perturbation": {"sigmaScale": sigmas["scale"], "sigmaCentre": sigmas["centre"],
                         "sigmaRotationDeg": sigmas["rotation"], "seed": seed},
        # beyond the contract: how the truth was made, for debugging a scene by eye
        "placement": {**placement, "matrix": [float(v) for v in M[:2].reshape(-1)]},
    }


def validate_manifest(m: dict) -> list[str]:
    """Every key of contract §2; returns the problems (empty = valid)."""
    bad: list[str] = []

    def need(d, key, typ, where):
        if not isinstance(d, dict) or key not in d:
            bad.append(f"{where}.{key} missing")
            return None
        v = d[key]
        if typ is float:
            ok = isinstance(v, (int, float)) and not isinstance(v, bool)
        elif typ is int:
            ok = isinstance(v, int) and not isinstance(v, bool)
        else:
            ok = isinstance(v, typ)
        if not ok:
            bad.append(f"{where}.{key} is {type(v).__name__}, want {typ.__name__}")
        return v

    if m.get("schema") != 1:
        bad.append("schema != 1")
    need(m, "id", str, "")
    need(m, "set", str, "")
    fr = need(m, "frame", dict, "")
    if fr is not None:
        for k in ("width", "height"):
            v = need(fr, k, int, "frame")
            if isinstance(v, int) and v <= 0:
                bad.append(f"frame.{k} <= 0")
    sub = need(m, "subject", dict, "")
    if sub is not None:
        p = need(sub, "part", str, "subject")
        if p is not None and p not in SUBJECTS:
            bad.append(f"subject.part '{p}' unknown")
        v = need(sub, "viewpoint", str, "subject")
        if v is not None and v not in VIEWPOINTS:
            bad.append(f"subject.viewpoint '{v}' unknown")
        s = need(sub, "scene", str, "subject")
        if s is not None:
            try:
                parse_scene_name(s)
            except ValueError as e:
                bad.append(str(e))
        f = need(sub, "family", str, "subject")
        if f is not None and f not in ("circle", "oval", "square", "rectangle"):
            bad.append(f"subject.family '{f}' is not circle|oval|square|rectangle")
    seq = need(m, "sequence", dict, "")
    if seq is not None:
        i, n = need(seq, "index", int, "sequence"), need(seq, "of", int, "sequence")
        a = need(seq, "approach", float, "sequence")
        if isinstance(a, (int, float)) and not 0 <= a <= 1:
            bad.append("sequence.approach outside [0, 1]")
        if isinstance(i, int) and isinstance(n, int) and not 0 <= i < n:
            bad.append("sequence.index outside [0, of)")

    def shape(d, where, with_pose):
        kind = need(d, "kind", str, where)
        if kind == "quad":
            c = need(d, "cornersPx", list, where)
            if isinstance(c, list) and not (len(c) == 4 and all(isinstance(p, list) and len(p) == 2
                                                                and all(isinstance(v, (int, float)) for v in p) for p in c)):
                bad.append(f"{where}.cornersPx is not 4 × [x, y]")
        elif kind == "ellipse":
            c = need(d, "centrePx", list, where)
            if isinstance(c, list) and len(c) != 2:
                bad.append(f"{where}.centrePx is not [x, y]")
            ax = need(d, "semiAxesPx", list, where)
            if isinstance(ax, list) and (len(ax) != 2 or ax[0] < ax[1]):
                bad.append(f"{where}.semiAxesPx must be [a, b] with a ≥ b")
            need(d, "rotation", float, where)
        elif kind is not None:
            bad.append(f"{where}.kind '{kind}' is not quad|ellipse")
        if with_pose:
            need(d, "tiltDeg", float, where)
            need(d, "yawDeg", float, where)
        return kind

    t = need(m, "truth", dict, "")
    p = need(m, "perturbed", dict, "")
    tk = shape(t, "truth", True) if t is not None else None
    pk = shape(p, "perturbed", False) if p is not None else None
    if tk and pk and tk != pk:
        bad.append("perturbed.kind differs from truth.kind")
    # the truth must land in the family the subject intends, with the margin
    # the selftest pins — a boundary sit would stage green and be dropped by --family
    if not bad and isinstance(sub, dict) and t is not None:
        fam, margin = family_and_margin(t)
        if fam != sub.get("family"):
            bad.append(f"truth lands in family '{fam}', the subject intends '{sub.get('family')}'")
        elif margin < FAMILY_MARGIN:
            bad.append(f"truth sits {margin:.3f} from the '{fam}' boundary (want ≥ {FAMILY_MARGIN})")
    pert = need(m, "perturbation", dict, "")
    if pert is not None:
        for k in ("sigmaScale", "sigmaCentre", "sigmaRotationDeg"):
            need(pert, k, float, "perturbation")
        need(pert, "seed", int, "perturbation")
    return bad


def is_clockwise_from_top_left(corners) -> bool:
    """Positive shoelace area in a y-down frame is clockwise on screen; corner 0 must be
    the top-left one (smallest x + y)."""
    c = np.asarray(corners, dtype=float)
    x, y = c[:, 0], c[:, 1]
    area2 = float(np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y))
    return area2 > 0 and int(np.argmin(x + y)) == 0
