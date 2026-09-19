"""The three dials of contract §2, applied to a truth shape in frame pixels.

  sigmaScale        σ of a log-normal factor on the size (0.05 = ±5 %)
  sigmaCentre       σ of a normal offset, per axis, AS A FRACTION OF THE
                    TRUTH'S MAJOR SIZE (scale-invariant)
  sigmaRotationDeg  σ of a normal in-plane rotation, degrees

Applied in that order — scale about the centre, then the offset, then the
rotation about the (moved) centre — to a quad's CORNERS, so the result is a
similar parallelogram and its `wide` flag survives. An ellipse perturbs its
centre, both semi-axes by the same factor, and its rotation.

Three draws are always made per shape (factor, offset x/y, rotation) and each
is multiplied by its σ: a dial at 0 applies exactly nothing (exp(0) = 1,
cos(0) = 1, sin(0) = 0 — no rounding), and one seed gives the same offsets
whichever dials are open. `numpy.random.default_rng(seed)` per set.
"""
from __future__ import annotations

import math

import numpy as np


def quad_major(corners) -> float:
    """The longer mean side — `quadMetrics.major` in the Kit."""
    c = np.asarray(corners, dtype=float)
    d = lambda i, j: float(np.hypot(*(c[i] - c[j])))  # noqa: E731
    width = (d(0, 1) + d(3, 2)) / 2
    height = (d(0, 3) + d(1, 2)) / 2
    return max(width, height)


def draw(rng: np.random.Generator, sigma_scale: float, sigma_centre: float, sigma_rotation_deg: float) -> dict:
    """One shape's three draws, already scaled by the dials."""
    factor = math.exp(sigma_scale * float(rng.standard_normal()))
    offset = sigma_centre * rng.standard_normal(2)
    rotation_deg = sigma_rotation_deg * float(rng.standard_normal())
    return {"factor": factor, "offsetFrac": [float(offset[0]), float(offset[1])], "rotationDeg": rotation_deg}


def perturb(truth: dict, rng: np.random.Generator, sigma_scale: float, sigma_centre: float,
            sigma_rotation_deg: float) -> dict:
    d = draw(rng, sigma_scale, sigma_centre, sigma_rotation_deg)
    theta = math.radians(d["rotationDeg"])
    R = np.array([[math.cos(theta), -math.sin(theta)], [math.sin(theta), math.cos(theta)]])
    if truth["kind"] == "quad":
        c = np.asarray(truth["cornersPx"], dtype=float)
        major = quad_major(c)
        centre = c.mean(axis=0)
        c = centre + (c - centre) * d["factor"]                       # 1. scale about the centre
        centre = centre + np.asarray(d["offsetFrac"]) * major          # 2. the offset, a fraction of the major
        c = c + np.asarray(d["offsetFrac"]) * major
        c = centre + (R @ (c - centre).T).T                            # 3. rotate about the moved centre
        return {"kind": "quad", "cornersPx": [[float(x), float(y)] for x, y in c]}
    if truth["kind"] == "ellipse":
        a, b = truth["semiAxesPx"]
        major = 2 * a
        centre = np.asarray(truth["centrePx"], dtype=float) + np.asarray(d["offsetFrac"]) * major
        rot = truth["rotation"] + theta
        while rot > math.pi / 2:
            rot -= math.pi
        while rot <= -math.pi / 2:
            rot += math.pi
        return {"kind": "ellipse", "centrePx": [float(centre[0]), float(centre[1])],
                "semiAxesPx": [a * d["factor"], b * d["factor"]], "rotation": float(rot)}
    raise ValueError(f"unknown truth kind {truth['kind']!r}")


def size_ratio(perturbed: dict, truth: dict) -> float:
    """perturbed size ÷ truth size — the log of this over many draws has std σ_scale."""
    if truth["kind"] == "quad":
        return quad_major(perturbed["cornersPx"]) / quad_major(truth["cornersPx"])
    return perturbed["semiAxesPx"][0] / truth["semiAxesPx"][0]
