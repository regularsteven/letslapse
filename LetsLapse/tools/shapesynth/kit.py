"""The scene kit (docs/design/kit) read as a corpus: one composition = one scene.

The kit is the generator. `build.js` composes `recipes.json` into
`compositions/<id>.svg` + `compositions/manifest.json`; each composition's
root carries the tram FACE polygon (`<polygon data-role="shape">`, the last
one in the file — the first sits inside the inlined object at object-local
coordinates), its axis-aligned bounds (`data-shape-bbox`), per-side margins,
the 3×3 cell overlaps and the cell. This module reads that and turns it into
the scene manifests of docs/shapemation/synthetic-corpus.md §2:

- the register knows `ellipse | quad` only, so `truth` is a quad — the face's
  bbox corners, clockwise from top-left, rotation 0 — and the seven-point
  face rides along as `truthPolygon` for the brief's §2 outline inventory;
- `set` is the sequence: the id minus its trailing `.<nn>` (`city.clear.approach`
  for `city.clear.approach.07`); a composition with no number is a sequence
  of one (`single.city.night.front`, approach 0);
- `subject.family` is the Kit's own rule on the bbox (`DetectedShape.family`:
  width ÷ height within 0.8…1.25 is `square`, past it `rectangle`), with the
  margin to the nearer boundary reported in the Kit's units — the `high`
  view's face is the front face squashed by 0.88, aspect 0.792, a rectangle
  by 0.008, so a margin under WARN_MARGIN is a warning and only one under
  HARD_MARGIN a refusal.

Everything here is in the kit's own pixels until `scene_manifest` multiplies
by the raster scale; the frame is the raster's size.
"""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field

import numpy as np

SUBJECT_PART = "tram-face"                     # the kit's data-shape-name
FAMILY_BOUNDARY = (0.8, 1.25)                  # DetectedShape.family on a quad's width ÷ height
WARN_MARGIN = 0.05                             # closer than this to the boundary: say so
HARD_MARGIN = 0.002                            # closer than this: refuse (float noise could flip it)
POLYGON_RE = re.compile(r'<polygon\s+data-role="shape"\s+points="([^"]+)"')
ATTR_RE = r'\sdata-{name}="([^"]*)"'


@dataclass
class Composition:
    id: str
    file: str                                  # absolute path of the SVG
    width: int                                 # kit px
    height: int
    meta: dict                                 # the manifest entry, as build.js wrote it
    polygon: list[list[float]]                 # the root-level face polygon, frame px (kit units)
    bbox: dict                                 # {x, y, w, h} from data-shape-bbox
    sequence: str = ""                         # the id minus its trailing .<nn>
    number: int | None = None                  # the <nn>, None for a single
    index: int = 0                             # position in the sequence
    of: int = 1

    @property
    def approach(self) -> float:
        return self.index / (self.of - 1) if self.of > 1 else 0.0

    @property
    def family(self) -> tuple[str, float]:
        return family_and_margin(self.bbox["w"], self.bbox["h"])


@dataclass
class Sequence:
    name: str
    compositions: list[Composition] = field(default_factory=list)

    @property
    def family(self) -> str:
        """The family every member lands in; a mixed sequence raises — score takes one --family."""
        fams = sorted({c.family[0] for c in self.compositions})
        if len(fams) != 1:
            raise ValueError(f"sequence {self.name} mixes families {fams}")
        return fams[0]

    @property
    def uniform_frame(self) -> bool:
        """Every composition the same kit size — an approach sequence; a mixed batch is not."""
        return len({(c.width, c.height) for c in self.compositions}) <= 1

    @property
    def sizes_monotonic(self) -> bool:
        """The recipes' `size` (tram height as a fraction of frame height) grows strictly along the sequence."""
        sizes = [c.meta["size"] for c in self.compositions]
        return all(b > a for a, b in zip(sizes, sizes[1:]))

    @property
    def shares_monotonic(self) -> bool:
        """The face's share of the frame (`share`, the Kit's sort key) grows strictly along the
        sequence — the order a mixed-frame batch (`mixed.random`) is numbered in, where `size`
        (a fraction of the frame HEIGHT) would rank a portrait face under a landscape one."""
        shares = [share(c) for c in self.compositions]
        return all(b > a for a, b in zip(shares, shares[1:]))

    @property
    def ordered(self) -> bool:
        """Numbered the way its approach reads: by `size` on one frame, by share across frames."""
        return self.sizes_monotonic if self.uniform_frame else self.shares_monotonic


# ---------------------------------------------------------------------------
# Reading the kit
# ---------------------------------------------------------------------------

def split_id(cid: str) -> tuple[str, int | None]:
    """'city.clear.approach.07' → ('city.clear.approach', 7); 'single.hills.sun.high' → (itself, None)."""
    m = re.fullmatch(r"(.+)\.(\d+)", cid)
    return (m.group(1), int(m.group(2))) if m else (cid, None)


def parse_points(text: str) -> list[list[float]]:
    nums = [float(v) for v in re.split(r"[\s,]+", text.strip()) if v]
    if len(nums) % 2:
        raise ValueError(f"odd number of coordinates in points={text!r}")
    return [[nums[i], nums[i + 1]] for i in range(0, len(nums), 2)]


def read_composition(kit_dir: str, entry: dict) -> Composition:
    """One manifest entry + its SVG: the root polygon (the LAST data-role="shape") and the bbox attribute."""
    rel = entry["file"]
    rel = rel[len("kit/"):] if rel.startswith("kit/") else rel
    path = os.path.join(kit_dir, rel)
    with open(path, "r", encoding="utf-8") as f:
        svg = f.read()
    polygons = POLYGON_RE.findall(svg)
    if not polygons:
        raise ValueError(f"{entry['id']}: no <polygon data-role=\"shape\"> in {path}")
    polygon = parse_points(polygons[-1])
    m = re.search(ATTR_RE.format(name="shape-bbox"), svg)
    if not m:
        raise ValueError(f"{entry['id']}: no data-shape-bbox on the root of {path}")
    x, y, w, h = (float(v) for v in m.group(1).split())
    root = re.search(r'<svg[^>]*\swidth="(\d+)"\s+height="(\d+)"', svg)
    width, height = (int(root.group(1)), int(root.group(2))) if root else (int(entry["width"]), int(entry["height"]))
    return Composition(id=entry["id"], file=path, width=width, height=height, meta=entry, polygon=polygon,
                       bbox={"x": x, "y": y, "w": w, "h": h})


def load_kit(kit_dir: str) -> list[Sequence]:
    """Every composition of the kit, grouped into sequences (the manifest's order within each)."""
    kit_dir = os.path.abspath(kit_dir)
    manifest_path = os.path.join(kit_dir, "compositions", "manifest.json")
    if not os.path.exists(manifest_path):
        raise FileNotFoundError(f"no compositions/manifest.json under {kit_dir} — `node {os.path.join(kit_dir, 'build.js')}` writes it")
    with open(manifest_path, "r", encoding="utf-8") as f:
        entries = json.load(f)
    groups: dict[str, list[Composition]] = {}
    for entry in entries:
        c = read_composition(kit_dir, entry)
        c.sequence, c.number = split_id(c.id)
        groups.setdefault(c.sequence, []).append(c)
    sequences = []
    for name, comps in groups.items():
        comps.sort(key=lambda c: (c.number if c.number is not None else 0, c.id))
        for i, c in enumerate(comps):
            c.index, c.of = i, len(comps)
        sequences.append(Sequence(name=name, compositions=comps))
    return sequences


def select(sequences: list[Sequence], wanted: str) -> list[Sequence]:
    """`all`, an exact sequence name, or a dotted prefix of several (`single` → every single)."""
    if wanted == "all":
        return list(sequences)
    hits = [s for s in sequences if s.name == wanted or s.name.startswith(wanted + ".")]
    if not hits:
        names = ", ".join(s.name for s in sequences)
        raise ValueError(f"no sequence '{wanted}' in the kit (have: {names})")
    return hits


def share(c: Composition) -> float:
    """The Kit's own sort key (`ShapemationSort.share`): the shape's major — for the face
    bbox its longer side — as a share of the frame's short edge. A share, not pixels, so
    the frame's aspect and the raster scale drop out."""
    return max(c.bbox["w"], c.bbox["h"]) / min(c.width, c.height)


def pool(sequences: list[Sequence], name: str) -> Sequence:
    """Every composition of `sequences` as ONE sequence named `name`, ranked by `share`
    ascending — index 0 is the smallest face, `of` the count, approach = rank ÷ (count − 1)
    — so a mixed pool reads like an approach: the object the constant, the scene, sky,
    angle, size and position changing around it (Steven, 2026-09-19). The compositions
    keep their ids; a tie in share breaks on the id."""
    comps = sorted((c for s in sequences for c in s.compositions), key=lambda c: (share(c), c.id))
    if not comps:
        raise ValueError("nothing to pool")
    out = []
    for i, c in enumerate(comps):
        c = Composition(**{**c.__dict__})
        c.index, c.of = i, len(comps)
        out.append(c)
    return Sequence(name=name, compositions=out)


# ---------------------------------------------------------------------------
# The family the Kit will see, and the truth quad
# ---------------------------------------------------------------------------

def family_and_margin(w: float, h: float) -> tuple[str, float]:
    """`DetectedShape.family` on an axis-aligned quad: width ÷ height within 0.8…1.25 is
    `square`, past it `rectangle` (`aspect` in the Kit is width over height, so a tall face
    is judged against 0.8, a wide one against 1.25); the margin is the distance to the nearer
    boundary in those units (positive = inside the family reported)."""
    lo, hi = FAMILY_BOUNDARY
    aspect = w / h if h > 0 else float("inf")
    if lo <= aspect <= hi:
        return "square", min(aspect - lo, hi - aspect)
    return "rectangle", (aspect - hi) if aspect > hi else (lo - aspect)


def quad_family_and_margin(corners) -> tuple[str, float]:
    """The same rule on a quad's mean sides (`quadMetrics` in the Kit) — for perturbed shapes."""
    c = np.asarray(corners, dtype=float)
    d = lambda i, j: float(np.hypot(*(c[i] - c[j])))  # noqa: E731
    return family_and_margin((d(0, 1) + d(3, 2)) / 2, (d(0, 3) + d(1, 2)) / 2)


def bbox_corners(bbox: dict, scale: float) -> list[list[float]]:
    """Clockwise from top-left, in raster px."""
    x, y, w, h = bbox["x"] * scale, bbox["y"] * scale, bbox["w"] * scale, bbox["h"] * scale
    return [[x, y], [x + w, y], [x + w, y + h], [x, y + h]]


def is_clockwise_from_top_left(corners) -> bool:
    """Positive shoelace area in a y-down frame is clockwise on screen; corner 0 must be
    the top-left one (smallest x + y)."""
    c = np.asarray(corners, dtype=float)
    x, y = c[:, 0], c[:, 1]
    area2 = float(np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y))
    return area2 > 0 and int(np.argmin(x + y)) == 0


def polygon_bbox(polygon) -> dict:
    p = np.asarray(polygon, dtype=float)
    x, y = p[:, 0].min(), p[:, 1].min()
    return {"x": float(x), "y": float(y), "w": float(p[:, 0].max() - x), "h": float(p[:, 1].max() - y)}


# ---------------------------------------------------------------------------
# The scene manifest (contract §2, plus truthPolygon and kit)
# ---------------------------------------------------------------------------

def scene_manifest(c: Composition, *, set_name: str, scale: float, perturbed: dict, sigmas: dict, seed: int) -> dict:
    W, H = round(c.width * scale), round(c.height * scale)
    family, _ = c.family
    truth = {"kind": "quad", "cornersPx": bbox_corners(c.bbox, scale), "tiltDeg": 0.0, "yawDeg": 0.0}
    m = c.meta
    return {
        "schema": 1,
        "id": c.id,
        "set": set_name,
        "frame": {"width": W, "height": H},
        "subject": {"part": SUBJECT_PART, "viewpoint": m["tram"], "scene": m["scene"], "sky": m["sky"], "family": family},
        "sequence": {"index": c.index, "of": c.of, "approach": c.approach},
        "truth": truth,
        "perturbed": perturbed,
        "perturbation": {"sigmaScale": sigmas["scale"], "sigmaCentre": sigmas["centre"],
                         "sigmaRotationDeg": sigmas["rotation"], "seed": seed},
        # beyond the contract (the Kit ignores both): the seven-point face for the §2
        # outline inventory, and the kit's own numbers so §5/§6 can be checked against them
        "truthPolygon": [[x * scale, y * scale] for x, y in c.polygon],
        "kit": {"id": c.id, "file": os.path.relpath(c.file, os.path.dirname(os.path.dirname(c.file))),
                "width": c.width, "height": c.height, "scale": scale, "aspect": m.get("aspect"),
                "margins": m["margins"], "cells": m["cells"], "cell": m["cell"],
                "distance": m["distance"], "size": m["size"], "cx": m["cx"],
                "camera": m["camera"], "camH": m.get("camH"), "track": m["track"], "vp": m["vp"]},
    }


def validate_manifest(m: dict) -> list[str]:
    """Every key of contract §2 (plus the two additions); returns the problems (empty = valid).
    A truth within HARD_MARGIN of the family boundary is a problem; within WARN_MARGIN is
    the caller's warning (`family_warning`)."""
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
        if p is not None and p != SUBJECT_PART:
            bad.append(f"subject.part '{p}' is not {SUBJECT_PART}")
        v = need(sub, "viewpoint", str, "subject")
        if v is not None and v not in ("front", "left", "right", "high", "low"):
            bad.append(f"subject.viewpoint '{v}' is not one of the kit's tram views")
        need(sub, "scene", str, "subject")
        need(sub, "sky", str, "subject")
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

    def quad(d, where, with_pose):
        kind = need(d, "kind", str, where)
        if kind != "quad":
            bad.append(f"{where}.kind '{kind}' is not quad (the kit's truth is the face bbox)")
            return
        c = need(d, "cornersPx", list, where)
        if isinstance(c, list) and not (len(c) == 4 and all(isinstance(p, list) and len(p) == 2
                                                            and all(isinstance(v, (int, float)) for v in p) for p in c)):
            bad.append(f"{where}.cornersPx is not 4 × [x, y]")
        elif isinstance(c, list) and not is_clockwise_from_top_left(c):
            bad.append(f"{where}.cornersPx not clockwise from top-left")
        if with_pose:
            need(d, "tiltDeg", float, where)
            need(d, "yawDeg", float, where)

    t = need(m, "truth", dict, "")
    p = need(m, "perturbed", dict, "")
    if t is not None:
        quad(t, "truth", True)
    if p is not None:
        quad(p, "perturbed", False)
    if not bad and isinstance(sub, dict) and t is not None:
        fam, margin = quad_family_and_margin(t["cornersPx"])
        if fam != sub.get("family"):
            bad.append(f"truth lands in family '{fam}', subject.family says '{sub.get('family')}'")
        elif margin < HARD_MARGIN:
            bad.append(f"truth sits {margin:.4f} from the '{fam}' boundary (refused under {HARD_MARGIN})")
    pert = need(m, "perturbation", dict, "")
    if pert is not None:
        for k in ("sigmaScale", "sigmaCentre", "sigmaRotationDeg"):
            need(pert, k, float, "perturbation")
        need(pert, "seed", int, "perturbation")
    poly = need(m, "truthPolygon", list, "")
    if isinstance(poly, list) and (len(poly) < 3 or not all(isinstance(q, list) and len(q) == 2 for q in poly)):
        bad.append("truthPolygon is not ≥ 3 × [x, y]")
    k = need(m, "kit", dict, "")
    if k is not None:
        for key in ("id", "margins", "cells", "cell", "distance", "size", "cx", "camera", "track", "vp"):
            if key not in k:
                bad.append(f"kit.{key} missing")
    return bad


def family_warning(c: Composition) -> str | None:
    fam, margin = c.family
    if margin < WARN_MARGIN:
        return f"{c.id} ({c.meta['tram']} view): '{fam}' by only {margin:.3f} (aspect {max(c.bbox['w'], c.bbox['h']) / min(c.bbox['w'], c.bbox['h']):.3f} against {FAMILY_BOUNDARY[1]})"
    return None
