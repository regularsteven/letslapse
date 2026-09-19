#!/usr/bin/env python3
"""Kit compositions → synthetic scenes + dial sweeps for Shape-mation (docs/shapemation/synthetic-corpus.md).

The scene kit at docs/design/kit IS the generator (`node docs/design/kit/build.js`
composes recipes.json into compositions/*.svg + manifest.json). This tool
rasterises those compositions, writes the scene manifests of contract §2 with
the kit's face bbox as the truth quad, perturbs them with the three dials and
runs the sweeps.

Usage (from LetsLapse/):
  tools/.venv/bin/python tools/shapesynth/shapesynth.py generate --kit docs/design/kit --out <dir> \
        [--sequence city.clear.approach|single|all] [--scale 2] [--seed S] \
        [--sigma-scale σ] [--sigma-centre σ] [--sigma-rotation σ] [--orientation 1|6] [--set-suffix <s>] [--pool <set>]
  tools/.venv/bin/python tools/shapesynth/shapesynth.py select <scenes-or-projects-dir> [--where tram=front] [--where cell=centre] …
  tools/.venv/bin/python tools/shapesynth/shapesynth.py recipes --mixed 40 --seed 19 [--kit docs/design/kit] [--dry-run]
  tools/.venv/bin/python tools/shapesynth/shapesynth.py sweep --kit docs/design/kit --axis scale|centre|rotation|joint \
        --values 0,0.02,0.05,0.1,0.2 [--sequence city.clear.approach] --seed 1 --lapse Kit/.build/release/lapse [--out work/<name>]
  tools/.venv/bin/python tools/shapesynth/shapesynth.py selftest --kit docs/design/kit    # generator only, no lapse needed

`generate` writes <out>/<set>/<id>/frame.jpg + scene.json (+ scene.svg, the
composition) per contract §2; <set> is the kit sequence (the id minus its
trailing .<nn>, plus --set-suffix) — or, under --pool, ONE set of every
selected composition ranked by face share, smallest first (the mixed-scene
corpus: the object constant, everything else changing). `select` prints the
folders under a scenes or projects dir whose scene.json matches --where
clauses (tram, scene, sky, cell, aspect, set, id), in set + rank order, so a
variant of a pool is a shell substitution. `recipes` appends the seeded
`mixed.random.*` batch to the kit (recipes_mixed.py). `sweep` generates one set per value,
stages and scores them with the Kit's `lapse shapemation` (with the
sequence's family unless --score-flags names one) and writes results.json +
report.md with the per-value table and the BREAK POINT lines of §6. Its
σ = 0 set is the acceptance of §5 — every scene placed, nothing dropped,
every residual within 0.5 px — and is staged a second time as orientation-6
JPEGs, whose residuals must equal the orientation-1 ones; either failing
exits 1. Outputs default to tools/shapesynth/work/ (git-ignored). Nothing
here touches a library or writes under the kit.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import kit  # noqa: E402
import perturb  # noqa: E402
import rasterise  # noqa: E402

DEFAULT_WORK = os.path.join(HERE, "work")
DEFAULT_KIT = os.path.normpath(os.path.join(HERE, "..", "..", "docs", "design", "kit"))
DEFAULT_LAPSE = os.path.normpath(os.path.join(HERE, "..", "..", "Kit", ".build", "release", "lapse"))
DEFAULT_SEQUENCE = "city.clear.approach"
DEFAULT_SCALE = 2.0          # kit px → raster px: 1800×1200 → 3600×2400, 1200×1800 → 2400×3600
BREAK_CENTRE = 0.02          # §6: the first σ whose median centre residual exceeds this
ZERO_TOLERANCE_PX = 0.5      # §5: on a σ = 0 set every residual is 0 within this
O6_TOLERANCE = 1e-9          # the orientation-6 set's residuals against orientation 1's
AXES = ("scale", "centre", "rotation", "joint")
RASTER_JOBS = max(2, (os.cpu_count() or 4) // 2)


def csv(text: str) -> list[str]:
    return [t.strip() for t in text.split(",") if t.strip()]


# ---------------------------------------------------------------------------
# generate
# ---------------------------------------------------------------------------

def build_sets(out: str, sequences: list[kit.Sequence], seed: int, sigmas: dict, scale: float, set_suffix: str = "",
               render: bool = True, quiet: bool = False, jobs: int | None = None, orientation: int = 1,
               warn=print) -> list[dict]:
    """Writes <out>/<set>/<id>/{frame.jpg, scene.json, scene.svg} for every composition of the
    sequences; returns the manifests. One `default_rng([seed, 2])` stream per set, drawn in
    sequence order, so one seed gives the same offsets whichever dials are open. `orientation`
    6 stores every frame.jpg a quarter-turn anticlockwise under EXIF tag 6 (the manifest is the
    same: its geometry is in the oriented frame). A truth near the family boundary is reported
    through `warn`; one within kit.HARD_MARGIN stops the run."""
    if orientation not in rasterise.ORIENTATIONS:
        sys.exit(f"--orientation must be one of {', '.join(map(str, rasterise.ORIENTATIONS))}")
    if scale <= 0:
        sys.exit("--scale must be positive")
    manifests, renders = [], []
    t0 = time.time()
    for seq in sequences:
        set_name = seq.name + set_suffix
        set_dir = os.path.join(out, set_name)
        os.makedirs(set_dir, exist_ok=True)
        rng_perturb = np.random.default_rng([seed, 2])
        for c in seq.compositions:
            w = kit.family_warning(c)
            if w:
                warn(f"  note: {w}")
            truth = {"kind": "quad", "cornersPx": kit.bbox_corners(c.bbox, scale)}
            perturbed = perturb.perturb(truth, rng_perturb, sigmas["scale"], sigmas["centre"], sigmas["rotation"])
            m = kit.scene_manifest(c, set_name=set_name, scale=scale, perturbed=perturbed, sigmas=sigmas, seed=seed)
            problems = kit.validate_manifest(m)
            if problems:
                sys.exit(f"{c.id}: manifest invalid: {problems}")
            folder = os.path.join(set_dir, c.id)
            os.makedirs(folder, exist_ok=True)
            with open(os.path.join(folder, "scene.json"), "w", encoding="utf-8") as f:
                json.dump(m, f, indent=2)
            manifests.append(m)
            if render:
                with open(c.file, "r", encoding="utf-8") as f:
                    renders.append((f.read(), m["frame"]["width"], m["frame"]["height"], os.path.join(folder, "frame.jpg")))
    if renders:
        # rsvg-convert + cairo's PNG encode is most of a second per 8 MP frame and lives in a
        # subprocess, so frames rasterise in parallel; the manifests above were made in
        # sequence because the perturbation stream must be drawn in scene order.
        from concurrent.futures import ThreadPoolExecutor
        done = 0
        with ThreadPoolExecutor(max_workers=jobs or RASTER_JOBS) as pool:
            for _ in pool.map(lambda r: rasterise.rasterise(r[0], r[1], r[2], r[3], orientation=orientation), renders):
                done += 1
                if not quiet and (done % 10 == 0 or done == len(renders)):
                    print(f"  {done}/{len(renders)} frames ({time.time() - t0:.1f} s)")
    return manifests


def sigmas_from(args) -> dict:
    return {"scale": float(args.sigma_scale), "centre": float(args.sigma_centre), "rotation": float(args.sigma_rotation)}


def load_sequences(kit_dir: str, wanted: str) -> list[kit.Sequence]:
    try:
        return kit.select(kit.load_kit(kit_dir), wanted)
    except (FileNotFoundError, ValueError) as e:
        sys.exit(str(e))


def cmd_generate(args) -> int:
    sequences = load_sequences(args.kit, args.sequence)
    if args.pool:
        # every selected composition in ONE set, ranked by the Kit's share (smallest face
        # first): the pooled corpus, where the object is the constant and the scene is not
        sequences = [kit.pool(sequences, args.pool)]
    out = os.path.abspath(args.out)
    manifests = build_sets(out, sequences, args.seed, sigmas_from(args), args.scale, args.set_suffix,
                           render=not args.no_render, jobs=args.jobs, orientation=args.orientation)
    sets = sorted({m["set"] for m in manifests})
    print(f"wrote {len(manifests)} scenes in {len(sets)} set(s) to {out}: {', '.join(sets)}")
    return 0


# ---------------------------------------------------------------------------
# select — scene / project folders by what their scene.json says
# ---------------------------------------------------------------------------

SELECT_KEYS = {
    "tram": ("subject", "viewpoint"), "viewpoint": ("subject", "viewpoint"),
    "scene": ("subject", "scene"), "sky": ("subject", "sky"), "family": ("subject", "family"),
    "cell": ("kit", "cell"), "aspect": ("kit", "aspect"), "set": ("set",), "id": ("id",),
}


def manifest_value(m: dict, key: str):
    path = SELECT_KEYS.get(key)
    if path is None:
        raise KeyError(key)
    cur = m
    for k in path:
        cur = cur.get(k) if isinstance(cur, dict) else None
    return cur


def parse_where(clauses: list[str]) -> list[tuple[str, set[str]]]:
    """`key=value[,value]` → (key, {values}); an unknown key is an error naming the known ones."""
    out = []
    for w in clauses or []:
        if "=" not in w:
            sys.exit(f"--where wants key=value, got {w!r}")
        key, value = (t.strip() for t in w.split("=", 1))
        if key not in SELECT_KEYS:
            sys.exit(f"--where key {key!r} is not one of {', '.join(SELECT_KEYS)}")
        out.append((key, set(csv(value))))
    return out


def select_folders(root: str, where: list[tuple[str, set[str]]]) -> list[tuple[str, dict]]:
    """Every folder under `root` holding a scene.json whose values match every clause
    (a clause's values are alternatives), ordered by set, then sequence index, then id —
    so a pooled set comes out in its size rank."""
    hits = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        if "scene.json" not in filenames:
            continue
        try:
            with open(os.path.join(dirpath, "scene.json"), "r", encoding="utf-8") as f:
                m = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        if all(str(manifest_value(m, k)) in v for k, v in where):
            hits.append((dirpath, m))
    hits.sort(key=lambda h: (h[1].get("set", ""), (h[1].get("sequence") or {}).get("index", 0), h[1].get("id", "")))
    return hits


def cmd_select(args) -> int:
    where = parse_where(args.where)
    hits = select_folders(os.path.abspath(args.root), where)
    for path, _ in hits:
        print(path)
    if not hits:
        print(f"select: nothing under {args.root} matches {' '.join(args.where or [])}", file=sys.stderr)
        return 1
    return 0


def cmd_recipes(args) -> int:
    import recipes_mixed
    argv = ["--kit", args.kit, "--count", str(args.mixed), "--seed", str(args.seed)]
    if args.dry_run:
        argv.append("--dry-run")
    return recipes_mixed.main(argv)


# ---------------------------------------------------------------------------
# sweep
# ---------------------------------------------------------------------------

NUM = r"[-\d.eE+]+|n/a|-"      # a residual, or the Kit's n/a when nothing was placed
SCORE_RE = re.compile(
    r"SHAPEMATION SCORE:\s*placed\s+(?P<placed>\d+)\s*·\s*dropped\s+(?P<dropped>\d+)"
    rf"\s*·\s*centre median\s+(?P<c_med>{NUM})\s+p90\s+(?P<c_p90>{NUM})\s+max\s+(?P<c_max>{NUM})"
    rf"\s*·\s*scale median\s+(?P<s_med>{NUM})"
    rf"\s*·\s*rotation median\s+(?P<r_med>{NUM})°?"
    rf"\s*·\s*corners rms\s+(?P<k_rms>{NUM})")


def parse_score_line(text: str) -> dict | None:
    for line in reversed(text.splitlines()):
        m = SCORE_RE.search(line)
        if m:
            g = m.groupdict()
            num = lambda k: (None if g[k] in ("n/a", "-") else float(g[k]))  # noqa: E731
            return {"placed": int(g["placed"]), "dropped": int(g["dropped"]),
                    "centreMedian": num("c_med"), "centreP90": num("c_p90"), "centreMax": num("c_max"),
                    "scaleMedian": num("s_med"), "rotationMedianDeg": num("r_med"), "cornerRmsMedianPx": num("k_rms")}
    return None


def dig(d, *paths):
    """First present value along any of the dotted key paths — the score JSON's exact key
    names are the Swift side's; the SCORE line is the contract, the JSON is a bonus."""
    for path in paths:
        cur = d
        ok = True
        for k in path.split("."):
            if isinstance(cur, dict) and k in cur:
                cur = cur[k]
            else:
                ok = False
                break
        if ok and isinstance(cur, (int, float)) and not isinstance(cur, bool):
            return float(cur)
    return None


def summary_from_json(j: dict) -> dict:
    return {
        "placed": dig(j, "placed", "counts.placed", "summary.placed"),
        "dropped": dig(j, "dropped", "counts.dropped", "summary.dropped", "droppedCount"),
        "centreMedian": dig(j, "centre.median", "centreMedian", "summary.centre.median"),
        "centreP90": dig(j, "centre.p90", "centreP90", "summary.centre.p90"),
        "centreMax": dig(j, "centre.max", "centreMax", "summary.centre.max"),
        "scaleMedian": dig(j, "scale.median", "scaleMedian", "summary.scale.median"),
        "rotationMedianDeg": dig(j, "rotationDeg.median", "rotation.median", "rotationMedianDeg"),
        "cornerRmsMedianPx": dig(j, "cornerRmsPx.median", "cornerRms.median", "cornerRmsMedianPx"),
        "pairwiseOverlapMedian": dig(j, "pairwiseOverlap.median", "pairwiseOverlapMedian"),
    }


def lapse_ready(lapse: str) -> str | None:
    """None when `lapse shapemation` answers; else the reason, for the report."""
    if not os.path.exists(lapse):
        return (f"lapse binary not found at {lapse} — build it with "
                f"`cd Kit && swift build -c release --product lapse`, then re-run with --reuse")
    try:
        r = subprocess.run([lapse, "shapemation"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"could not run {lapse}: {e}"
    if "unknown command" in (r.stdout + r.stderr).lower():
        return (f"{lapse} has no `shapemation` subcommand yet (the Kit CLI of contract §3–§5) — "
                f"rebuild from a checkout that has Kit/Sources/lapse/ShapemationCommand.swift, then re-run with --reuse")
    return None


def run(cmd: list[str], log_path: str) -> subprocess.CompletedProcess:
    r = subprocess.run(cmd, capture_output=True, text=True)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write("$ " + " ".join(cmd) + "\n" + r.stdout + r.stderr + f"\n[exit {r.returncode}]\n\n")
    return r


def fmt(v, digits=3, suffix="") -> str:
    if v is None:
        return "—"
    if isinstance(v, float) and not v.is_integer():
        return f"{v:.{digits}f}{suffix}"
    return f"{int(v)}{suffix}"


def break_point_line(axis: str, rows: list[dict]) -> str:
    """§6: the first value whose median centre residual exceeds BREAK_CENTRE.
    `not scored` is the failure form — no set produced a median at all."""
    prev = None
    for r in rows:
        med = r.get("centreMedian")
        if med is None:
            continue
        if med > BREAK_CENTRE:
            before = f"; {prev['value']:g} gave {prev['centreMedian']:.3f}" if prev else "; nothing below it"
            return f"BREAK POINT {axis}: σ {r['value']:g} (median centre {med:.3f}{before})"
        prev = r
    scored = [r for r in rows if r.get("centreMedian") is not None]
    if not scored:
        return f"BREAK POINT {axis}: not scored"
    return f"BREAK POINT {axis}: none up to σ {scored[-1]['value']:g}"


def zero_set_problems(summary: dict | None, raw: dict | None, scenes: int) -> list[str]:
    """§5's acceptance on a σ = 0 set: every scene placed, nothing dropped, every
    residual 0 within ZERO_TOLERANCE_PX. The score JSON carries each residual's
    max and `shapeSizePx`; with only the SCORE line the medians (and the centre
    max) stand in. Returns the problems (empty = accepted)."""
    if not summary:
        return ["no score"]
    bad = []
    placed, dropped = summary.get("placed"), summary.get("dropped")
    if placed != scenes:
        bad.append(f"placed {fmt(placed)} of {scenes}")
    if dropped:
        bad.append(f"dropped {fmt(dropped)}")
    size = dig(raw or {}, "shapeSizePx")
    if not size:
        bad.append("no shapeSizePx in the score JSON")
        return bad
    tol = ZERO_TOLERANCE_PX / size
    tol_deg = np.degrees(np.arctan(tol))
    checks = [("centre", dig(raw, "centre.max"), summary.get("centreMax"), tol, "×shapeSizePx"),
              ("scale", dig(raw, "scale.max"), summary.get("scaleMedian"), tol, "×shapeSizePx"),
              ("rotation", dig(raw, "rotationDeg.max"), summary.get("rotationMedianDeg"), tol_deg, "°"),
              ("corners rms", dig(raw, "cornerRmsPx.max"), summary.get("cornerRmsMedianPx"), ZERO_TOLERANCE_PX, " px")]
    for name, worst, median, limit, unit in checks:
        value = worst if worst is not None else median
        if value is None:
            continue                       # a circle set has no corners; an ellipse set no cornerRms
        if abs(value) > limit:
            bad.append(f"{name} {'max' if worst is not None else 'median'} {value:.4g}{unit} > {limit:.4g}{unit}")
    return bad


def per_item_residuals(raw: dict | None) -> dict[str, tuple]:
    """scene id → (centre, scale, rotationDeg, cornerRmsPx) from a score JSON."""
    out = {}
    for it in (raw or {}).get("items", []) or []:
        sid = str(it.get("project", "")).rsplit("/", 1)[-1]
        out[sid] = tuple(it.get(k) for k in ("centre", "scale", "rotationDeg", "cornerRmsPx"))
    return out


def orientation6_problems(o1: dict | None, o6: dict | None) -> list[str]:
    """The oriented-frame acceptance: the same scenes staged as orientation-6
    JPEGs score the same residuals, item by item, within O6_TOLERANCE."""
    a, b = per_item_residuals(o1), per_item_residuals(o6)
    if not a or not b:
        return ["no per-item residuals to compare"]
    if set(a) != set(b):
        return [f"orientation 6 placed {len(b)} scene(s), orientation 1 placed {len(a)}"]
    bad = []
    for sid in sorted(a):
        for name, x, y in zip(("centre", "scale", "rotationDeg", "cornerRmsPx"), a[sid], b[sid]):
            if (x is None) != (y is None) or (x is not None and abs(x - y) > O6_TOLERANCE):
                bad.append(f"{sid} {name}: o1 {x} vs o6 {y}")
    return bad


def write_report(out: str, results: dict) -> str:
    axis = results["axis"]
    rows = results["values"]
    lines = [f"# shapesynth sweep — axis `{axis}`", "",
             f"Generated {results['generatedAt']} · {results['scenes']} scenes per set · seed {results['seed']} · "
             f"kit `{results['kit']}` · sequence `{results['sequence']}` ({results['sequences']}) · "
             f"scale {results['scale']:g} · family `{results['family']}`", ""]
    if results.get("lapse"):
        lines += [f"Scored with `{results['lapse']}`" + (f" (`{results['scoreFlags']}`)" if results.get("scoreFlags") else ""), ""]
    if results.get("error"):
        lines += [f"**Failed:** {results['error']}", ""]
    if results.get("acceptance"):
        lines += [f"σ = 0 acceptance (§5): {results['acceptance']}", ""]
    if results.get("orientation6"):
        lines += [f"Orientation 6: {results['orientation6']}", ""]
    lines += ["| σ | set | placed | dropped | centre median | centre p90 | centre max | scale median | rotation median | corners rms px | overlap median |",
              "|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        s = r.get("summary") or {}
        lines.append(f"| {r['value']:g} | `{r['suffix']}` | {fmt(s.get('placed'))} | {fmt(s.get('dropped'))} | "
                     f"{fmt(s.get('centreMedian'))} | {fmt(s.get('centreP90'))} | {fmt(s.get('centreMax'))} | "
                     f"{fmt(s.get('scaleMedian'))} | {fmt(s.get('rotationMedianDeg'), 1, '°')} | "
                     f"{fmt(s.get('cornerRmsMedianPx'), 1)} | {fmt(s.get('pairwiseOverlapMedian'))} |")
    flat = [{"value": r["value"], "centreMedian": (r.get("summary") or {}).get("centreMedian")} for r in rows]
    bp = break_point_line(axis, flat)
    lines += ["", "`set` is the suffix every kit sequence in the sweep carries (`<sequence><suffix>` under `scenes/`). "
              "`dropped` is the Kit's own count (`majorPx <= 0`, `no admissible shape`, `register unreadable`, "
              "`plan returned nil`, `plan skipped it`, `scene.json unreadable`) and is never folded into the residuals.",
              "", "```", bp, "```", ""]
    path = os.path.join(out, "report.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return bp


def cmd_sweep(args) -> int:
    values = [float(v) for v in csv(args.values)]
    if args.axis not in AXES:
        sys.exit(f"--axis must be one of {', '.join(AXES)}")
    sequences = load_sequences(args.kit, args.sequence)
    scenes = sum(len(s.compositions) for s in sequences)
    try:
        families = sorted({s.family for s in sequences})
    except ValueError as e:
        sys.exit(str(e))
    if len(families) != 1:
        sys.exit(f"--sequence {args.sequence} spans families {families}; score takes one --family — sweep one family at a time")
    family = families[0]
    name = args.name or f"{args.axis}-sweep"
    out = os.path.abspath(args.out or os.path.join(DEFAULT_WORK, name))
    scenes_dir, projects_dir = os.path.join(out, "scenes"), os.path.join(out, "projects")
    log_path = os.path.join(out, "lapse.log")
    os.makedirs(out, exist_ok=True)
    if os.path.exists(log_path):
        os.remove(log_path)
    lapse = os.path.abspath(args.lapse)
    # The plan path the builder takes needs a family (quads go through
    # rectanglePlacement only under one): the sequence's, unless the flags name one.
    score_flags = args.score_flags or ""
    if "--family" not in csv_args(score_flags):
        score_flags = (score_flags + f" --family {family}").strip()

    def set_dirs(suffix: str) -> list[str]:
        return [os.path.join(scenes_dir, s.name + suffix) for s in sequences]

    def build(suffix: str, sig: dict, orientation: int = 1) -> None:
        if args.reuse and all(os.path.isdir(d) for d in set_dirs(suffix)):
            print(f"  reusing {suffix}")
            return
        for d in set_dirs(suffix):
            if os.path.isdir(d):
                shutil.rmtree(d)
        build_sets(scenes_dir, sequences, args.seed, sig, args.scale, suffix, jobs=args.jobs, orientation=orientation)

    # 1. one set per value ---------------------------------------------------
    rows = []
    o6_suffix = None
    for v in values:
        sig = {"scale": 0.0, "centre": 0.0, "rotation": 0.0}
        if args.axis == "joint":
            sig = {"scale": v, "centre": v, "rotation": v * args.joint_rotation_scale}
        else:
            sig[args.axis] = v
        suffix = f"-{args.axis}-{v:g}"
        build(suffix, sig)
        rows.append({"value": v, "suffix": suffix, "sets": [s.name + suffix for s in sequences], "sigmas": sig, "summary": None})
        if v == 0 and o6_suffix is None:
            # The same scenes once more as orientation-6 JPEGs: the register
            # is written on the oriented frame, so the residuals must not move.
            o6_suffix = f"{suffix}-o6"
            build(o6_suffix, sig, orientation=6)

    results = {
        "axis": args.axis, "values": rows, "scenes": scenes, "seed": args.seed, "scale": args.scale,
        "kit": os.path.abspath(args.kit), "sequence": args.sequence, "sequences": ", ".join(s.name for s in sequences),
        "family": family,
        "generatedAt": datetime.datetime.now().replace(microsecond=0).isoformat(), "lapse": lapse,
        "scoreFlags": score_flags, "breakCentre": BREAK_CENTRE, "zeroTolerancePx": ZERO_TOLERANCE_PX,
        "error": None, "breakPoint": None, "acceptance": None, "orientation6": None,
    }

    def finish(code: int) -> int:
        bp = write_report(out, results)
        results["breakPoint"] = bp
        with open(os.path.join(out, "results.json"), "w", encoding="utf-8") as f:
            json.dump(results, f, indent=2)
        print(bp)
        print(f"report: {os.path.join(out, 'report.md')}")
        return code

    # 2. stage everything, score per value -----------------------------------
    reason = lapse_ready(lapse)
    if reason:
        results["error"] = reason
        print(f"SWEEP NOT SCORED: {reason}\n  sets are generated under {scenes_dir}")
        return finish(2)
    if os.path.isdir(projects_dir):
        shutil.rmtree(projects_dir)
    r = run([lapse, "shapemation", "stage", scenes_dir, "--out", projects_dir], log_path)
    if r.returncode != 0:
        results["error"] = f"stage failed (exit {r.returncode}): {(r.stderr or r.stdout).strip()[-400:]}"
        print(f"SWEEP NOT SCORED: {results['error']}\n  see {log_path}")
        return finish(1)
    print(f"  staged → {projects_dir}")

    def score_sets(suffix: str) -> tuple[dict | None, dict | None, str | None]:
        """(summary, score JSON, error) for the staged sets of one value."""
        projects = []
        for s in sequences:
            set_projects = os.path.join(projects_dir, s.name + suffix)
            if os.path.isdir(set_projects):
                projects += sorted(os.path.join(set_projects, d) for d in os.listdir(set_projects)
                                   if os.path.isdir(os.path.join(set_projects, d)))
        if not projects:
            return None, None, f"no staged projects under {projects_dir}/*{suffix}"
        json_path = os.path.join(out, f"score{suffix}.json")
        cmd = [lapse, "shapemation", "score", *projects, *csv_args(score_flags), "--json", json_path]
        r = run(cmd, log_path)
        summary = parse_score_line(r.stdout + r.stderr)
        raw = None
        if os.path.exists(json_path):
            try:
                with open(json_path, "r", encoding="utf-8") as f:
                    raw = json.load(f)
            except json.JSONDecodeError:
                raw = None
        if summary is None and isinstance(raw, dict):
            summary = summary_from_json(raw)
        if isinstance(raw, dict) and summary is not None:
            j = summary_from_json(raw)
            for k, v in j.items():
                if summary.get(k) is None and v is not None:
                    summary[k] = v
        error = None
        if r.returncode != 0 or summary is None:
            error = f"score exit {r.returncode}, no SCORE line" if summary is None else f"score exit {r.returncode}"
        elif not summary.get("placed"):
            error = "nothing placed"
        return summary, raw, error

    failures, problems = 0, []
    zero_raw = None
    for row in rows:
        summary, raw, error = score_sets(row["suffix"])
        if error:
            row["error"] = error
            failures += 1
            problems.append(f"{row['suffix']}: {error}")
        row["summary"] = summary
        row["scoreJson"] = f"score{row['suffix']}.json" if raw is not None else None
        s = summary or {}
        print(f"  {row['suffix']}: placed {fmt(s.get('placed'))} dropped {fmt(s.get('dropped'))} "
              f"centre median {fmt(s.get('centreMedian'))} p90 {fmt(s.get('centreP90'))}")
        if row["value"] == 0:
            # §5: the σ = 0 set is the acceptance, not a table row to read by eye.
            bad = zero_set_problems(summary, raw, scenes)
            row["acceptance"] = "accepted" if not bad else "; ".join(bad)
            if bad:
                failures += 1
                problems.append(f"{row['suffix']} failed the σ = 0 acceptance: {'; '.join(bad)}")
                print(f"  {row['suffix']}: σ = 0 ACCEPTANCE FAILED — {'; '.join(bad)}")
            else:
                print(f"  {row['suffix']}: σ = 0 accepted (every residual within {ZERO_TOLERANCE_PX} px, nothing dropped)")
            results["acceptance"] = f"`{row['suffix']}` {row['acceptance']}"
            zero_raw = zero_raw or raw
    if o6_suffix:
        summary, raw, error = score_sets(o6_suffix)
        bad = [error] if error else orientation6_problems(zero_raw, raw)
        if bad:
            failures += 1
            problems.append(f"{o6_suffix}: orientation 6 residuals differ from orientation 1: {'; '.join(bad[:5])}")
            print(f"  {o6_suffix}: ORIENTATION 6 FAILED — {'; '.join(bad[:5])}")
            results["orientation6"] = f"`{o6_suffix}` FAILED — {'; '.join(bad[:5])}"
        else:
            n = len(per_item_residuals(raw))
            print(f"  {o6_suffix}: orientation 6 == orientation 1 on {n} scene(s) (within {O6_TOLERANCE:g})")
            results["orientation6"] = f"`{o6_suffix}` == orientation 1 on {n} scene(s) (per-item residuals within {O6_TOLERANCE:g})"
        results["orientation6Set"] = {"suffix": o6_suffix, "summary": summary,
                                      "scoreJson": f"score{o6_suffix}.json" if raw else None}
    if failures:
        results["error"] = "; ".join(problems) + f" — see {log_path}"
    return finish(1 if failures else 0)


def csv_args(text: str) -> list[str]:
    import shlex
    return shlex.split(text) if text else []


# ---------------------------------------------------------------------------
# selftest — kit reader + generator only
# ---------------------------------------------------------------------------

class Check:
    def __init__(self):
        self.fails, self.passes = [], 0

    def __call__(self, cond, msg):
        if cond:
            self.passes += 1
        else:
            self.fails.append(msg)
            print(f"  FAIL {msg}")


def cmd_selftest(args) -> int:
    import tempfile
    from PIL import Image, ImageOps
    ck = Check()
    zero = {"scale": 0.0, "centre": 0.0, "rotation": 0.0}
    tmp = tempfile.mkdtemp(prefix="shapesynth-selftest-", dir=args.work if os.path.isdir(args.work) else None)
    sequences = load_sequences(args.kit, "all")
    comps = [c for s in sequences for c in s.compositions]
    print(f"  kit {os.path.abspath(args.kit)}: {len(comps)} compositions in {len(sequences)} sequences")
    ck(len(comps) > 0, "the kit has compositions")

    # 1. the parsed root polygon's bbox is data-shape-bbox (to 0.1 px — the kit rounds both to
    #    one decimal separately); every composition's family, with the near ones listed;
    #    sequences are numbered contiguously and their `size` grows monotonically ----------
    near = []
    for c in comps:
        pb = kit.polygon_bbox(c.polygon)
        err = max(abs(pb[k] - c.bbox[k]) for k in "xywh")
        ck(err <= 0.1 + 1e-6, f"{c.id}: polygon bbox differs from data-shape-bbox by {err:.3f} px")
        mb = c.meta["bbox"]
        ck(all(abs(mb[k] - c.bbox[k]) < 1e-9 for k in "xywh"), f"{c.id}: root data-shape-bbox differs from the manifest's bbox")
        ck(len(c.polygon) == 7, f"{c.id}: face polygon has {len(c.polygon)} points, want 7")
        fam, margin = c.family
        ck(fam == "rectangle", f"{c.id}: face family '{fam}' (margin {margin:.3f}) — the kit's trams are rectangles")
        ck(margin >= kit.HARD_MARGIN, f"{c.id}: face within {kit.HARD_MARGIN} of the family boundary ({margin:.4f})")
        if margin < kit.WARN_MARGIN:
            near.append((c.id, c.meta["tram"], fam, margin))
    ck(all(t == "high" for _, t, _, _ in near), f"a non-high view sits near the family boundary: {near}")
    ck(any(t == "high" for _, t, _, _ in near) or not any(c.meta["tram"] == "high" for c in comps),
       "no high view listed as near the boundary although the kit has one")
    print(f"  families: {sum(1 for c in comps if c.family[0] == 'rectangle')} rectangle, "
          f"{sum(1 for c in comps if c.family[0] == 'square')} square; near a family boundary (under {kit.WARN_MARGIN}, width ÷ height):")
    for cid, tram, fam, margin in near:
        print(f"    {cid} ({tram}): {fam} by {margin:.3f}")
    for s in sequences:
        nums = [c.number for c in s.compositions]
        if len(s.compositions) > 1:
            ck(nums == list(range(1, len(nums) + 1)), f"{s.name}: numbering {nums} is not 1…{len(nums)}")
            if s.uniform_frame:
                ck(s.sizes_monotonic, f"{s.name}: recipe `size` is not monotonic {[c.meta['size'] for c in s.compositions]}")
            else:
                ck(s.shares_monotonic, f"{s.name} (mixed frames): face share is not monotonic {[round(kit.share(c), 3) for c in s.compositions]}")
            ck(s.compositions[0].approach == 0 and s.compositions[-1].approach == 1, f"{s.name}: approach span")
            appr = [c.approach for c in s.compositions]
            ck(all(b > a for a, b in zip(appr, appr[1:])), f"{s.name}: approach not increasing")
        else:
            ck(s.compositions[0].number is None and s.compositions[0].approach == 0, f"{s.name}: a single with a number or a non-zero approach")
    print(f"  ordered within every numbered sequence (`size` on one frame, face share across frames): {all(s.ordered for s in sequences)}; "
          f"mixed-frame sequences: {[s.name for s in sequences if not s.uniform_frame] or 'none'}")
    singles = sorted(s.name for s in kit.select(sequences, "single"))
    ck(singles == sorted(s.name for s in sequences if len(s.compositions) == 1) and len(singles) == 12 and
       all(s.compositions[0].number is None for s in kit.select(sequences, "single")),
       f"`single` selects the 12 singles and no numbered sequence: {singles}")
    ck([s.name for s in kit.select(sequences, "city")] == ["city.clear.approach"], "`city` selects city.clear.approach alone")

    # 2. σ = 0 → perturbed == truth to 1e-9 for every composition; corners clockwise from
    #    top-left; truth == bbox × scale; scene.json validates; the Kit's keys plus ours ----
    scale = args.scale
    ms = build_sets(tmp, sequences, 7, zero, scale, render=False, quiet=True, warn=lambda s: None)
    ck(len(ms) == len(comps), f"{len(ms)} manifests for {len(comps)} compositions")
    by_id = {c.id: c for c in comps}
    for m in ms:
        t, p = m["truth"], m["perturbed"]
        err = float(np.abs(np.asarray(t["cornersPx"]) - np.asarray(p["cornersPx"])).max())
        ck(err <= 1e-9, f"{m['id']}: σ=0 perturbed ≠ truth by {err:g}")
        ck(kit.is_clockwise_from_top_left(t["cornersPx"]), f"{m['id']}: truth corners not clockwise from top-left")
        problems = kit.validate_manifest(m)
        ck(not problems, f"{m['id']}: manifest problems {problems}")
        c = by_id[m["id"]]
        ck(m["set"] == c.sequence and m["sequence"] == {"index": c.index, "of": c.of, "approach": c.approach}, f"{m['id']}: set/sequence")
        ck(m["frame"] == {"width": round(c.width * scale), "height": round(c.height * scale)}, f"{m['id']}: frame {m['frame']}")
        want = [[c.bbox["x"] * scale, c.bbox["y"] * scale], [(c.bbox["x"] + c.bbox["w"]) * scale, c.bbox["y"] * scale],
                [(c.bbox["x"] + c.bbox["w"]) * scale, (c.bbox["y"] + c.bbox["h"]) * scale], [c.bbox["x"] * scale, (c.bbox["y"] + c.bbox["h"]) * scale]]
        ck(np.allclose(t["cornersPx"], want), f"{m['id']}: truth is not the bbox × {scale}")
        ck(np.allclose(m["truthPolygon"], np.asarray(c.polygon) * scale) and len(m["truthPolygon"]) == 7, f"{m['id']}: truthPolygon")
        ck(m["subject"] == {"part": kit.SUBJECT_PART, "viewpoint": c.meta["tram"], "scene": c.meta["scene"], "sky": c.meta["sky"], "family": c.family[0]},
           f"{m['id']}: subject {m['subject']}")
        ck(m["kit"]["cells"] == c.meta["cells"] and m["kit"]["cell"] == c.meta["cell"] and m["kit"]["margins"] == c.meta["margins"],
           f"{m['id']}: kit block does not copy the manifest")
    # the run's truth grows with approach, sequence by sequence (in px on one frame size; as a
    # share of the frame's short edge across mixed frames — the Kit's own sort key)
    for s in sequences:
        if len(s.compositions) > 1:
            majors = []
            for c in s.compositions:
                m = next(m for m in ms if m["id"] == c.id)
                majors.append(perturb.quad_major(m["truth"]["cornersPx"]) / (1 if s.uniform_frame else min(m["frame"]["width"], m["frame"]["height"])))
            ck(all(b > a for a, b in zip(majors, majors[1:])), f"{s.name}: truth major not monotonic over the run {majors}")
    # a pool: every composition in one set, ranked by share, indices 0…n−1, the ids kept
    pooled = kit.pool(sequences, "pool-test")
    ck(len(pooled.compositions) == len(comps) and pooled.name == "pool-test", "pool holds every composition")
    ck([c.index for c in pooled.compositions] == list(range(len(comps))) and all(c.of == len(comps) for c in pooled.compositions), "pool indices 0…n−1")
    ck(pooled.shares_monotonic or len({round(kit.share(c), 9) for c in comps}) < len(comps), "pool ranked by share ascending")
    ck(sorted(c.id for c in pooled.compositions) == sorted(c.id for c in comps), "pool keeps the ids")
    pm = build_sets(tmp, [pooled], 7, zero, scale, render=False, quiet=True, warn=lambda s: None)
    ck(all(m["set"] == "pool-test" for m in pm) and [m["sequence"]["index"] for m in pm] == list(range(len(comps))), "pooled manifests: one set, index = rank")
    ck(abs(pm[-1]["sequence"]["approach"] - 1) < 1e-12 and pm[0]["sequence"]["approach"] == 0, "pooled approach spans 0…1")
    # select: --where clauses over the written scene.json files, in rank order
    hits = select_folders(os.path.join(tmp, "pool-test"), parse_where(["tram=high", "cell=centre,mixed"]))
    want = [c.id for c in pooled.compositions if c.meta["tram"] == "high" and c.meta["cell"] in ("centre", "mixed")]
    ck([os.path.basename(p) for p, _ in hits] == want, f"select tram=high cell=centre,mixed → {len(hits)} of {len(want)}")
    ck(select_folders(os.path.join(tmp, "pool-test"), parse_where(["scene=depot", "sky=night"])) == [
        (p, m) for p, m in select_folders(os.path.join(tmp, "pool-test"), []) if m["subject"]["scene"] == "depot" and m["subject"]["sky"] == "night"],
       "select scene=depot sky=night")

    # 2b. the same seed reproduces a set; a different seed does not; a perturbed quad is
    #     still a parallelogram, clockwise from top-left ------------------------------------
    one = kit.select(sequences, DEFAULT_SEQUENCE)
    sig = {"scale": 0.1, "centre": 0.05, "rotation": 3}
    a = build_sets(tmp, one, 11, sig, scale, "-a", render=False, quiet=True, warn=lambda s: None)
    b = build_sets(tmp, one, 11, sig, scale, "-b", render=False, quiet=True, warn=lambda s: None)
    c3 = build_sets(tmp, one, 12, sig, scale, "-c", render=False, quiet=True, warn=lambda s: None)
    ck(all(x["perturbed"] == y["perturbed"] for x, y in zip(a, b)), "same seed → same perturbed corners")
    ck(any(x["perturbed"] != y["perturbed"] for x, y in zip(a, c3)), "different seed → different perturbed corners")
    q = np.asarray(a[0]["perturbed"]["cornersPx"])
    ck(float(np.abs((q[1] - q[0]) - (q[2] - q[3])).max()) < 1e-6, "perturbed quad is a parallelogram")
    ck(kit.is_clockwise_from_top_left(q), "perturbed quad at σ>0 still clockwise from top-left")

    # 3. the dials over 200 draws: σ_scale 0.1 → log std within 20 %; σ_centre a fraction of
    #    the major; σ_rotation turns the top edge ----------------------------------------------
    rng = np.random.default_rng(2024)
    truth = a[0]["truth"]
    logs = [np.log(perturb.size_ratio(perturb.perturb(truth, rng, 0.1, 0, 0), truth)) for _ in range(200)]
    sd = float(np.std(logs))
    ck(abs(sd - 0.1) <= 0.02, f"σ_scale 0.1: log std of 200 size ratios is {sd:.4f} (want 0.1 ± 20 %)")
    major = perturb.quad_major(truth["cornersPx"])
    offs = []
    for _ in range(200):
        p = perturb.perturb(truth, rng, 0, 0.05, 0)
        offs.append((np.asarray(p["cornersPx"]).mean(axis=0) - np.asarray(truth["cornersPx"]).mean(axis=0)) / major)
    sd = float(np.std(np.asarray(offs).ravel()))
    ck(abs(sd - 0.05) <= 0.01, f"σ_centre 0.05: offset std as a fraction of the major is {sd:.4f}")
    rots = []
    for _ in range(200):
        p = np.asarray(perturb.perturb(truth, rng, 0, 0, 2.0)["cornersPx"])
        rots.append(np.degrees(np.arctan2(p[1, 1] - p[0, 1], p[1, 0] - p[0, 0])))
    sd = float(np.std(rots))
    ck(abs(sd - 2.0) <= 0.4, f"σ_rotation 2°: top-edge angle std is {sd:.3f}°")

    # 4. rasters: a landscape (1800×1200) and a portrait (1200×1800) composition come out at
    #    kit size × scale with orientation 1; the raster agrees with the truth — a probe on the
    #    face's red band is the tram's red, probes just outside the bbox at that height are not
    landscape = next((s for s in sequences if s.compositions[0].width > s.compositions[0].height
                      and s.compositions[0].meta["sky"] == "clear" and s.compositions[0].meta["tram"] == "front"), None)
    portrait = next((s for s in sequences if s.compositions[0].width < s.compositions[0].height), None)
    ck(landscape is not None and portrait is not None, "the kit has a clear-sky front landscape and a portrait composition")
    RED = (0xC8, 0x33, 0x2B)
    for seq in (landscape, portrait):
        if seq is None:
            continue
        c = seq.compositions[0]
        t0 = time.time()
        m = build_sets(tmp, [kit.Sequence(seq.name, [c])], 5, zero, scale, "-raster", quiet=True, warn=lambda s: None)[0]
        dt = time.time() - t0
        W, H = m["frame"]["width"], m["frame"]["height"]
        ck((W, H) == (round(c.width * scale), round(c.height * scale)), f"{c.id}: frame {W}×{H}")
        jpg = os.path.join(tmp, seq.name + "-raster", c.id, "frame.jpg")
        size, orientation = rasterise.jpeg_size_and_orientation(jpg)
        ck(size == (W, H), f"{c.id}: frame.jpg is {size}, want {(W, H)}")
        ck(orientation == 1, f"{c.id}: EXIF orientation {orientation}")
        if c.meta["sky"] == "clear":
            bx, by, bw, bh = (c.bbox[k] * scale for k in "xywh")
            yr = int(round(by + 0.62 * bh))                     # the red band of the face, no light tint under a clear sky
            with Image.open(jpg) as im:
                px = im.convert("RGB").load()
                inside = px[int(round(bx + bw / 2)), yr]
                ck(max(abs(inside[i] - RED[i]) for i in range(3)) <= 12, f"{c.id}: face centre at y {yr} is {inside}, want the tram red {RED}")
                for x in (int(round(bx)) - 4, int(round(bx + bw)) + 4):
                    outside = px[x, yr]
                    ck(max(abs(outside[i] - RED[i]) for i in range(3)) > 12, f"{c.id}: just outside the bbox at ({x},{yr}) is still red {outside}")
        print(f"  rasterised {c.id} {W}×{H} in {dt:.2f} s")

    # 4b. the orientation-6 variant: the same manifest, the file stored a quarter-turn
    #     anticlockwise under tag 6, so it reads as the frame once the tag is honoured -------
    c = landscape.compositions[0] if landscape else comps[0]
    seq1 = [kit.Sequence(c.sequence, [c])]
    ms1 = build_sets(tmp, seq1, 5, zero, scale, "-o1", quiet=True, warn=lambda s: None)
    ms6 = build_sets(tmp, seq1, 5, zero, scale, "-o6", quiet=True, warn=lambda s: None, orientation=6)
    W, H = ms1[0]["frame"]["width"], ms1[0]["frame"]["height"]
    ck(ms1[0]["truth"] == ms6[0]["truth"] and ms1[0]["perturbed"] == ms6[0]["perturbed"] and ms1[0]["frame"] == ms6[0]["frame"],
       "o6 manifest geometry == o1")
    jpg1 = os.path.join(tmp, c.sequence + "-o1", c.id, "frame.jpg")
    jpg6 = os.path.join(tmp, c.sequence + "-o6", c.id, "frame.jpg")
    size6, orientation6 = rasterise.jpeg_size_and_orientation(jpg6)
    ck(size6 == (H, W), f"o6 frame.jpg stores {size6}, want {(H, W)}")
    ck(orientation6 == 6, f"o6 EXIF orientation {orientation6}")
    ck(rasterise.oriented_size(jpg6) == (W, H), f"o6 reads as {rasterise.oriented_size(jpg6)}, want {(W, H)}")
    with Image.open(jpg1) as im1, Image.open(jpg6) as im6:
        up1 = np.asarray(im1.convert("RGB"), dtype=np.int16)
        up6 = np.asarray(ImageOps.exif_transpose(im6).convert("RGB"), dtype=np.int16)
        ck(up6.shape == up1.shape, f"o6 transposed shape {up6.shape} vs o1 {up1.shape}")
        if up6.shape == up1.shape:
            diff = float(np.abs(up6 - up1).mean())
            ck(diff < 1.5, f"o6 honoured reads like o1: mean |Δ| {diff:.2f} (JPEG noise only)")

    # 5. the SCORE line parser and the break-point rule ---------------------------
    s = parse_score_line("noise\nSHAPEMATION SCORE: placed 98 · dropped 2 · centre median 0.004 p90 0.019 max 0.071 · "
                         "scale median 0.006 · rotation median 0.3° · corners rms 2.1 px\n")
    ck(s == {"placed": 98, "dropped": 2, "centreMedian": 0.004, "centreP90": 0.019, "centreMax": 0.071,
             "scaleMedian": 0.006, "rotationMedianDeg": 0.3, "cornerRmsMedianPx": 2.1}, f"SCORE line parse {s}")
    s = parse_score_line("SHAPEMATION SCORE: placed 0 · dropped 3 · centre median n/a p90 n/a max n/a · "
                         "scale median n/a · rotation median n/a° · corners rms n/a\n")
    ck(s is not None and s["placed"] == 0 and s["dropped"] == 3 and s["centreMedian"] is None, f"SCORE line with n/a parses {s}")
    rows = [{"value": 0, "centreMedian": 0.0}, {"value": 0.05, "centreMedian": 0.011}, {"value": 0.1, "centreMedian": 0.024}]
    ck(break_point_line("scale", rows) == "BREAK POINT scale: σ 0.1 (median centre 0.024; 0.05 gave 0.011)", "break point line")
    ck(break_point_line("centre", rows[:2]) == "BREAK POINT centre: none up to σ 0.05", "no break point line")
    ck(break_point_line("centre", [{"value": 0.015, "centreMedian": 0.018}, {"value": 0.025, "centreMedian": 0.029}])
       == "BREAK POINT centre: σ 0.025 (median centre 0.029; 0.015 gave 0.018)", "break point keeps three decimals")
    raw = {"shapeSizePx": 400.0, "centre": {"max": 0.0}, "scale": {"max": 0.0}, "rotationDeg": {"max": 0.0}, "cornerRmsPx": {"max": 0.0}}
    ck(zero_set_problems({"placed": 3, "dropped": 0, "centreMax": 0.0}, raw, 3) == [], "σ = 0 acceptance passes a clean set")
    ck(zero_set_problems({"placed": 0, "dropped": 3, "centreMax": None}, None, 3) != [], "σ = 0 acceptance refuses an empty set")
    ck(zero_set_problems({"placed": 3, "dropped": 0, "centreMax": 0.01}, {**raw, "centre": {"max": 0.01}}, 3) != [],
       "σ = 0 acceptance refuses a 4 px centre residual")
    ck(orientation6_problems({"items": [{"project": "a/x", "centre": 0.1, "scale": 0, "rotationDeg": 0, "cornerRmsPx": 1}]},
                             {"items": [{"project": "b/x", "centre": 0.1, "scale": 0, "rotationDeg": 0, "cornerRmsPx": 1}]}) == [],
       "o6 == o1 on equal residuals")
    ck(orientation6_problems({"items": [{"project": "a/x", "centre": 0.1, "scale": 0, "rotationDeg": 0, "cornerRmsPx": 1}]},
                             {"items": [{"project": "b/x", "centre": 0.2, "scale": 0, "rotationDeg": 0, "cornerRmsPx": 1}]}) != [],
       "o6 ≠ o1 is caught")

    if not args.keep:
        shutil.rmtree(tmp, ignore_errors=True)
    else:
        print(f"  kept {tmp}")
    print(f"selftest: {ck.passes} passed, {len(ck.fails)} failed")
    return 1 if ck.fails else 0


# ---------------------------------------------------------------------------

def add_kit_args(p, sequence_default: str):
    p.add_argument("--kit", default=DEFAULT_KIT, help=f"the scene kit folder (default {DEFAULT_KIT})")
    p.add_argument("--sequence", default=sequence_default, help="a kit sequence (`city.clear.approach`), a prefix (`single`), or `all`")
    p.add_argument("--scale", type=float, default=DEFAULT_SCALE, help=f"raster px per kit px (default {DEFAULT_SCALE:g}: 1800×1200 → 3600×2400)")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--jobs", type=int, default=None, help=f"parallel rsvg-convert processes (default {RASTER_JOBS})")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--work", default=DEFAULT_WORK, help="working directory (default tools/shapesynth/work)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("generate", help="the kit's compositions as scenes: <out>/<sequence><suffix>/<id>/frame.jpg + scene.json")
    p.add_argument("--out", required=True)
    add_kit_args(p, "all")
    p.add_argument("--set-suffix", default="", help="appended to every set name (the sequence prefix)")
    p.add_argument("--pool", metavar="SET", help="every selected composition in ONE set of this name, ranked by face share "
                   "(sequence.index 0 = smallest, approach = rank ÷ (count − 1)); ids stay the compositions'")
    p.add_argument("--sigma-scale", type=float, default=0.0)
    p.add_argument("--sigma-centre", type=float, default=0.0)
    p.add_argument("--sigma-rotation", type=float, default=0.0, help="degrees")
    p.add_argument("--no-render", action="store_true", help="manifests only (no frame.jpg) — for quick geometry checks")
    p.add_argument("--orientation", type=int, default=1, choices=rasterise.ORIENTATIONS,
                   help="EXIF orientation of frame.jpg: 1 upright, 6 stored a quarter-turn anticlockwise (the manifest is the same)")
    p.set_defaults(fn=cmd_generate)

    p = sub.add_parser("sweep", help="one set per dial value → lapse shapemation stage + score → results.json + report.md")
    p.add_argument("--axis", required=True, help="scale | centre | rotation | joint")
    p.add_argument("--values", required=True, help="comma list of σ (joint: the same value on all three, rotation in degrees × --joint-rotation-scale)")
    add_kit_args(p, DEFAULT_SEQUENCE)
    p.add_argument("--lapse", default=DEFAULT_LAPSE)
    p.add_argument("--out", help="sweep folder (default tools/shapesynth/work/<name>)")
    p.add_argument("--name", help="sweep name under --work (default <axis>-sweep)")
    p.add_argument("--score-flags", default="", help='plan options handed to `lapse shapemation score`, e.g. "--family rectangle --sort largest" '
                   "(the sequence's family is added unless one is named)")
    p.add_argument("--joint-rotation-scale", type=float, default=100.0, help="joint axis: σ_rotation (deg) = value × this (0.05 → 5°)")
    p.add_argument("--reuse", action="store_true", help="keep sets already generated under the sweep folder (re-score only)")
    p.set_defaults(fn=cmd_sweep)

    p = sub.add_parser("select", help="scene or project folders whose scene.json matches — one path per line, in set + rank order")
    p.add_argument("root", help="a scenes folder (`generate --out`) or a staged projects folder")
    p.add_argument("--where", action="append", metavar="KEY=VALUE[,VALUE]",
                   help=f"a filter, repeatable (all must hold; comma = any of); keys: {', '.join(SELECT_KEYS)}")
    p.set_defaults(fn=cmd_select)

    p = sub.add_parser("recipes", help="append a seeded `mixed.random.<nn>` batch to the kit's recipes.json (recipes_mixed.py)")
    p.add_argument("--kit", default=DEFAULT_KIT)
    p.add_argument("--mixed", type=int, default=40, metavar="N", help="how many recipes (default 40)")
    p.add_argument("--seed", type=int, default=19)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(fn=cmd_recipes)

    p = sub.add_parser("selftest", help="kit reader + generator checks (no lapse needed)")
    p.add_argument("--kit", default=DEFAULT_KIT)
    p.add_argument("--scale", type=float, default=DEFAULT_SCALE)
    p.add_argument("--keep", action="store_true", help="keep the selftest's scratch folder")
    p.set_defaults(fn=cmd_selftest)

    args = ap.parse_args(argv)
    os.makedirs(args.work, exist_ok=True)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
