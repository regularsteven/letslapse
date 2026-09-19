#!/usr/bin/env python3
"""Append a `mixed.random.<nn>` batch to the scene kit's recipes.json.

Steven, 2026-09-19: a single-scene approach clip is not a true test — real
captures put the same object into DIFFERENT scenes, and the object (and so
its recorded shape) is the one constant. This draws `--count` recipes that
pool every aspect, scene, sky, track, camera position, tram angle, face size
and frame position the kit's composer accepts, so a Shape-mation plan over
the batch holds the face still while everything around it changes.

The draw (numpy `default_rng(seed)`, in this order per candidate):
  aspect   uniform over 3:2 · 2:3 · 1:1 · 4:3 · 16:9
  scene    uniform over city · oldtown · hills · mountains · depot
  sky      uniform over clear · clouds · sun · golden · dusk · night
  track    left · right (the depot also -5.25 · 5.25, its outer pair)
  camera   left · centre · right
  size     log-uniform 0.08 … 0.75 (tram height as a fraction of frame height)
  cx       uniform 0.15 … 0.85 (where the tram lands across the frame)
  tram     explicit — the five angles cycle by slot, so each appears count ÷ 5 times.
           KNOWN: an explicit `tram` overrides build.js's angleFor(Z), the flank the
           camera/track geometry would show, so a ground view's drawn flank can sit on
           the wrong side for where the rails recede (17 of 24 in the seed-19 batch).
           `tram`/`viewpoint` is the DRAWN label, not the photographer's position. Kept
           as drawn (the ids are referenced by staged corpora); a next batch should
           cycle only high/low by slot and let angleFor label the ground views.

A candidate is composed through the kit's own `build.js` (`compose`, in a
node subprocess — the exact geometry, not a port of it) and refused when the
face's bbox is not inside the frame by MIN_MARGIN on every side (a `high`
camera drops a near tram's face below the frame; a portrait frame cannot hold
a 0.75 face at cx 0.15) or the frame is not at least MIN_FACE_PX tall over
the face (the plan's working scale is the SMALLEST face, so a face under
that would drag every photo down). Refused slots are redrawn from the same
stream, so a seed always gives the same batch. The batch is then numbered in
ascending face SHARE — the Kit's own sort key (`ShapemationSort.share`: the
face's longer side over the frame's short edge, `kit.share`), not the
recipe's `size`, which is a fraction of the frame HEIGHT and so ranks a
portrait frame's face under a landscape one's — so `mixed.random.01` is the
smallest face the plan will see and the numbering IS the pool's rank within
the batch (`kit.py` reads a mixed-frame sequence's approach by share; its
selftest checks that order).

Idempotent: a recipes.json that already holds a `mixed.random.` id is left
alone and the run exits 1. Rebuild the kit afterwards (`node build.js`, in a
COPY of the kit when the checked-in SVGs must stay byte-identical).

Usage (from LetsLapse/):
  tools/.venv/bin/python tools/shapesynth/recipes_mixed.py [--kit docs/design/kit] [--count 40] [--seed 19] [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_KIT = os.path.normpath(os.path.join(HERE, "..", "..", "docs", "design", "kit"))
PREFIX = "mixed.random"
ASPECTS = ["3:2", "2:3", "1:1", "4:3", "16:9"]
SCENES = ["city", "oldtown", "hills", "mountains", "depot"]
SKIES = ["clear", "clouds", "sun", "golden", "dusk", "night"]
CAMERAS = ["left", "centre", "right"]
TRACKS = ["left", "right"]
DEPOT_TRACKS = ["left", "right", -5.25, 5.25]
TRAMS = ["front", "left", "right", "high", "low"]
SIZE_RANGE = (0.08, 0.75)
CX_RANGE = (0.15, 0.85)
MIN_MARGIN = 0.02            # the face's bbox inside the frame by this fraction per side
MIN_FACE_PX = 40             # the face's bbox height in kit px (× the raster scale in the corpus)
KEY_ORDER = ["id", "aspect", "scene", "sky", "track", "camera", "tram", "size", "cx"]

COMPOSE_JS = r"""
const build = require(process.argv[1]);
const assets = { ...build.objects(), ...build.skies(), ...build.scenes() };
let src = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', d => src += d);
process.stdin.on('end', () => {
  const out = JSON.parse(src).map(r => build.compose(r, assets).meta);
  process.stdout.write(JSON.stringify(out));
});
"""


def draw_candidate(rng: np.random.Generator, slot: int) -> dict:
    """One recipe, every field from the stream in a fixed order; the tram angle by slot."""
    aspect = ASPECTS[int(rng.integers(len(ASPECTS)))]
    scene = SCENES[int(rng.integers(len(SCENES)))]
    sky = SKIES[int(rng.integers(len(SKIES)))]
    tracks = DEPOT_TRACKS if scene == "depot" else TRACKS
    track = tracks[int(rng.integers(len(tracks)))]
    camera = CAMERAS[int(rng.integers(len(CAMERAS)))]
    lo, hi = np.log(SIZE_RANGE[0]), np.log(SIZE_RANGE[1])
    size = round(float(np.exp(rng.uniform(lo, hi))), 3)
    cx = round(float(rng.uniform(*CX_RANGE)), 3)
    return {"aspect": aspect, "scene": scene, "sky": sky, "track": track, "camera": camera,
            "tram": TRAMS[slot % len(TRAMS)], "size": size, "cx": cx}


def compose_all(kit_dir: str, recipes: list[dict], node: str = "node") -> list[dict]:
    """The kit composer's manifest entry for each recipe (no files written)."""
    build_js = os.path.join(os.path.abspath(kit_dir), "build.js")
    if not os.path.exists(build_js):
        raise FileNotFoundError(f"no build.js under {kit_dir}")
    r = subprocess.run([node, "-e", COMPOSE_JS, build_js], input=json.dumps(recipes), capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"node compose failed: {r.stderr.strip()[-400:]}")
    return json.loads(r.stdout)


def refusal(meta: dict) -> str | None:
    """Why the composed candidate is not usable, or None."""
    m = meta["margins"]
    low = min(m.values())
    if low < MIN_MARGIN:
        side = min(m, key=m.get)
        return f"face {side} margin {low:.3f} < {MIN_MARGIN}"
    if meta["bbox"]["h"] < MIN_FACE_PX:
        return f"face {meta['bbox']['h']:.0f} px tall < {MIN_FACE_PX}"
    return None


def share(meta: dict) -> float:
    """`kit.share` on a composed candidate: face major ÷ frame short edge."""
    return max(meta["bbox"]["w"], meta["bbox"]["h"]) / min(meta["width"], meta["height"])


def draw_batch(kit_dir: str, count: int, seed: int, node: str = "node", log=print) -> tuple[list[dict], list[dict]]:
    """`count` accepted recipes (unnumbered, in draw order) and their composed metas."""
    rng = np.random.default_rng(seed)
    slots: list[dict | None] = [None] * count
    metas: list[dict | None] = [None] * count
    rounds, refused = 0, 0
    while any(s is None for s in slots):
        rounds += 1
        if rounds > 50:
            raise RuntimeError("50 rounds without filling every slot — the ranges are too wide for the composer")
        pending = [i for i, s in enumerate(slots) if s is None]
        cands = [draw_candidate(rng, i) for i in pending]
        for i, c, meta in zip(pending, cands, compose_all(kit_dir, cands, node)):
            why = refusal(meta)
            if why:
                refused += 1
                log(f"  refused slot {i + 1:02d} {c['tram']} {c['aspect']} {c['scene']} size {c['size']} cx {c['cx']}: {why}")
                continue
            slots[i], metas[i] = c, meta
        # two equal shares would break the sequence's strict order: redraw the later one
        seen: dict[float, int] = {}
        for i, (s, m) in enumerate(zip(slots, metas)):
            if s is None:
                continue
            key = round(share(m), 6)
            if key in seen:
                log(f"  refused slot {i + 1:02d}: share {key} duplicates slot {seen[key] + 1:02d}")
                slots[i], metas[i] = None, None
            else:
                seen[key] = i
    log(f"  {count} accepted after {rounds} round(s), {refused} refused")
    return [s for s in slots if s], [m for m in metas if m]


def numbered(recipes: list[dict], metas: list[dict], prefix: str = PREFIX) -> tuple[list[dict], list[dict]]:
    """Ascending face share, ids `<prefix>.<nn>`, keys in the file's order; the metas alongside."""
    order = sorted(range(len(recipes)), key=lambda i: (share(metas[i]), i))
    width = max(2, len(str(len(order))))
    rows, ms = [], []
    for n, i in enumerate(order, 1):
        row = {"id": f"{prefix}.{n:0{width}d}", **recipes[i]}
        rows.append({k: row[k] for k in KEY_ORDER if k in row})
        ms.append(metas[i])
    return rows, ms


def load_recipes(kit_dir: str) -> tuple[str, list[dict]]:
    path = os.path.join(os.path.abspath(kit_dir), "recipes.json")
    with open(path, "r", encoding="utf-8") as f:
        return path, json.load(f)


def append_recipes(kit_dir: str, new: list[dict]) -> str:
    """recipes.json + the new rows, written the way build.js's JSON.stringify(…, null, 1) lays it out."""
    path, existing = load_recipes(kit_dir)
    ids = {r["id"] for r in existing}
    clash = sorted(ids & {r["id"] for r in new})
    if clash:
        raise ValueError(f"{path} already has {clash[0]} … ({len(clash)} of the ids)")
    text = json.dumps(existing + new, indent=1, ensure_ascii=False)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    return path


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kit", default=DEFAULT_KIT)
    ap.add_argument("--count", type=int, default=40)
    ap.add_argument("--seed", type=int, default=19)
    ap.add_argument("--node", default="node")
    ap.add_argument("--dry-run", action="store_true", help="print the batch, write nothing")
    args = ap.parse_args(argv)
    path, existing = load_recipes(args.kit)
    have = [r["id"] for r in existing if r["id"].startswith(PREFIX + ".")]
    if have:
        print(f"{path} already holds {len(have)} `{PREFIX}.*` recipes ({have[0]} … {have[-1]}) — nothing appended")
        return 1
    recipes, metas = draw_batch(args.kit, args.count, args.seed, args.node)
    rows, metas = numbered(recipes, metas)
    for r, m in zip(rows, metas):
        print(f"  {r['id']} {r['aspect']:>4} {r['scene']:<9} {r['sky']:<6} track {str(r['track']):<5} cam {r['camera']:<6} "
              f"{r['tram']:<5} size {r['size']:.3f} share {share(m):.3f} cx {r['cx']:.3f} → {m['cell']:<13} vp {m['vp']:.2f}")
    if args.dry_run:
        print(f"dry run: {len(rows)} recipes not written")
        return 0
    append_recipes(args.kit, rows)
    print(f"appended {len(rows)} recipes {rows[0]['id']} … {rows[-1]['id']} to {path}; rebuild with `node {os.path.join(args.kit, 'build.js')}`")
    return 0


if __name__ == "__main__":
    sys.exit(main())
