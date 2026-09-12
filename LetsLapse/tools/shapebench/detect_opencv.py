"""The `opencv-reference` detector (brief §5, Stage 1).

Proposal at reduced scale (multi-scale auto-Canny + adaptive threshold, both
polarities, closed, contours), then every surviving region is re-traced at
full resolution inside its own ROI and measured by the shared fitting pass.
The count of regions after dedupe is "candidates per image".
"""
from __future__ import annotations

import copy
import json
import os
import statistics
import time

import cv2
import numpy as np

import overlay
import schema
from fitting import (MATCH, RULES, Region, bbox_iou, binary_maps, dedupe_shapes, fit_candidate,
                     measure, polygon_bbox)
from imaging import check_dims, dims_of, load_bgr

DETECTOR_VERSION = "1"

DEFAULT_PARAMS = {
    "proposalLongEdges": [1024, 2048],
    "blur": 5,
    "canny": {"mode": "otsu", "loFrac": 0.5, "minHi": 40, "aperture": 3},   # hi = Otsu split, lo = ½ hi
    "fillEnclosed": True,                             # + a map of everything the edges enclose
    "adaptive": {"block": 51, "C": 5},                # GAUSSIAN_C, BINARY and BINARY_INV
    "close": [5, 9, 15],                              # MORPH_CLOSE ellipse kernels; maps at every size
    "contours": {"mode": "RETR_CCOMP", "method": "CHAIN_APPROX_NONE", "minPoints": 40},
    # a touch under the 0.10 size floor so a contour that fits to a primitive
    # just over the floor is not lost at the proposal stage
    "prefilter": {"minExtent": 0.08, "maxExtent": 0.98, "minSolidity": 0.60},
    "regionDedupe": {"bboxIoU": 0.80},
    # a full-res contour replaces the proposal only when it is clearly the same
    # region; below this the proposal is measured as traced (refined: false)
    # refinement adds precision, never identity (fitting.measure)
    "refine": {"pad": 0.08, "priorIoU": 0.80, "identity": "consensus"},
    # within-detector dedupe. The consensus rule's IoU (0.70) merges concentric
    # rings 8 % apart in radius; the policy is flat (every member of a nest is
    # a shape, 2026-09-12), so only near-identical shapes merge: 0.90.
    "shapeDedupe": {"iou": 0.90},
}


def merged_params(overrides: dict | None) -> dict:
    p = copy.deepcopy(DEFAULT_PARAMS)
    for k, v in (overrides or {}).items():
        if isinstance(v, dict) and isinstance(p.get(k), dict):
            p[k].update(v)
        else:
            p[k] = v
    return p


def propose(gray: np.ndarray, params: dict) -> list[Region]:
    H, W = gray.shape[:2]
    pf = params["prefilter"]
    min_pts = int(params["contours"]["minPoints"])
    regions: list[Region] = []
    for L in params["proposalLongEdges"]:
        s = min(1.0, float(L) / max(W, H))
        sw, sh = max(1, round(W * s)), max(1, round(H * s))
        small = cv2.resize(gray, (sw, sh), interpolation=cv2.INTER_AREA) if s < 1.0 else gray
        for name, m in binary_maps(small, params):
            contours, _ = cv2.findContours(m, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
            for c in contours:
                if len(c) < min_pts:
                    continue
                x, y, w, h = cv2.boundingRect(c)
                ext = max(w / sw, h / sh)
                if ext < pf["minExtent"] or ext > pf["maxExtent"]:
                    continue
                area = abs(cv2.contourArea(c))
                hull_area = abs(cv2.contourArea(cv2.convexHull(c)))
                if hull_area <= 0:
                    continue
                solidity = area / hull_area
                if solidity < pf["minSolidity"]:
                    continue
                pts = (c.reshape(-1, 2).astype(np.float32) + 0.5) / s - 0.5
                regions.append(Region(pts=pts, source=f"cv-{name}@{L}", from_contour=True,
                                      refined=False, scale=s,
                                      prior={"proposalExtent": round(float(ext), 4), "solidity": round(float(solidity), 3)}))
    # dedupe by bbox IoU, larger scale first, then larger area
    regions.sort(key=lambda r: (-r.scale, -(polygon_bbox(r.pts)[2] - polygon_bbox(r.pts)[0])
                                * (polygon_bbox(r.pts)[3] - polygon_bbox(r.pts)[1])))
    kept: list[Region] = []
    boxes: list[tuple] = []
    thr = float(params["regionDedupe"]["bboxIoU"])
    for r in regions:
        bb = polygon_bbox(r.pts)
        if any(bbox_iou(bb, kb) >= thr for kb in boxes):
            continue
        kept.append(r)
        boxes.append(bb)
    return kept


def detect_image(bgr: np.ndarray, params: dict, rules=RULES) -> tuple[list, dict, list]:
    """Returns (accepted shapes, stats, candidate rows)."""
    W, H = dims_of(bgr)
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    t0 = time.perf_counter()
    regions = propose(gray, params)
    t_prop = time.perf_counter()
    rows, accepted = [], []
    for r in regions:
        r2, v = measure(gray, r, params, W, H, rules)
        row = {k: v[k] for k in ("source", "refined", "nPoints", "contourExtent", "extentRatio", "sizeBand",
                                 "accepted", "primitive", "subclass", "winner", "rectScore", "ellipseScore",
                                 "reasons", "prior")}
        row["rect"] = _slim(v["rect"])
        row["ellipse"] = _slim(v["ellipse"])
        row["outline"] = _thin_outline(r2.pts)
        if v["accepted"]:
            row["shapeId"] = v["shape"]["shapeId"]
            accepted.append(v["shape"])
        rows.append(row)
    dd = dict(MATCH); dd["iou"] = float((params.get("shapeDedupe") or {}).get("iou", MATCH["iou"]))
    shapes = dedupe_shapes(accepted, W, H, dd)
    kept_ids = {s["shapeId"] for s in shapes}
    for row in rows:
        if row.get("shapeId") and row["shapeId"] not in kept_ids:
            row["dedupedAway"] = True
    t1 = time.perf_counter()
    stats = {"candidates": len(regions), "accepted": len(shapes), "acceptedBeforeDedupe": len(accepted),
             "proposalMs": int(round((t_prop - t0) * 1000)), "durationMs": int(round((t1 - t0) * 1000))}
    return shapes, stats, rows


def _slim(d):
    if not d:
        return None
    keep = ("ok", "reasons", "nVertices", "nVerticesAt", "convex", "aspect", "orientationDeg", "fillRatio",
            "maxAngularDeviationDeg", "sideMismatch", "iou", "axisRatio", "a", "b")
    return {k: d[k] for k in keep if k in d}


def _thin_outline(pts, n=64):
    P = np.asarray(pts, np.float64).reshape(-1, 2)
    step = max(1, len(P) // n)
    return np.round(P[::step], 1).tolist()


def write_rows(log_path: str, asset_id: str, rows: list, key: str) -> None:
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    existing = []
    if os.path.exists(log_path):
        with open(log_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                d = json.loads(line)
                if d.get("assetId") != asset_id:
                    existing.append(line)
    with open(log_path, "w", encoding="utf-8") as f:
        for line in existing:
            f.write(line + "\n")
        for r in rows:
            d = {"assetId": asset_id, "runKey": key}
            d.update(r)
            f.write(json.dumps(d, ensure_ascii=False, separators=(",", ":")) + "\n")


def log_path_for(work: str, detector_id: str, key: str) -> str:
    phash = key.split("|")[-1]
    return os.path.join(work, "logs", f"{detector_id}.{phash}.jsonl")


def overlay_for(bgr, W, H, shapes, rows, title):
    rejected = [{"outline": r["outline"]} for r in rows if not r["accepted"] and r.get("outline")]
    return overlay.render(bgr, W, H, [("rejected", rejected, None),
                                      ("accepted", shapes, overlay.short_label)], title)


def run(args) -> int:
    work = args.work
    with open(os.path.join(work, "manifest.json"), "r", encoding="utf-8") as f:
        manifest = json.load(f)
    overrides = None
    if getattr(args, "params", None):
        with open(args.params, "r", encoding="utf-8") as f:
            overrides = json.load(f)
    params = merged_params(overrides)
    run_params = {"detector": params, "rules": RULES}
    phash = schema.params_hash(run_params)
    key = schema.run_key(schema.DETECTOR_OPENCV, DETECTOR_VERSION, phash)
    print(f"opencv-reference v{DETECTOR_VERSION} params {phash}  ({'defaults' if not overrides else args.params})")
    assets = select_assets(manifest, args)
    done, skipped, failed = 0, 0, 0
    accepted_counts, durations = [], []
    ovl_dir = os.path.join(work, "overlays", schema.DETECTOR_OPENCV)
    os.makedirs(ovl_dir, exist_ok=True)
    for a in assets:
        aid = a["assetId"]
        rpath = schema.results_path(work, aid)
        doc = schema.load_results(rpath, a["projectId"])
        if schema.has_run(doc, key) and not args.force:
            skipped += 1
            print(f"  skip {aid[:8]}  (already ran {phash})")
            continue
        img_path = os.path.join(work, a["image"])
        try:
            bgr = load_bgr(img_path)
            check_dims(bgr, a["frameWidth"], a["frameHeight"], aid[:8])
        except Exception as ex:  # noqa: BLE001
            failed += 1
            print(f"  FAIL {aid[:8]}: {ex}")
            continue
        W, H = dims_of(bgr)
        t0 = time.perf_counter()
        shapes, stats, rows = detect_image(bgr, params)
        wall = (time.perf_counter() - t0) * 1000
        run = schema.new_run(schema.DETECTOR_OPENCV, DETECTOR_VERSION, run_params, stats["durationMs"])
        run["assets"] = [schema.new_asset(aid, W, H, shapes, stats)]
        status = schema.upsert_run(doc, run, force=args.force)
        schema.save_results(rpath, doc)
        write_rows(log_path_for(work, schema.DETECTOR_OPENCV, key), aid, rows, key)
        cv2.imwrite(os.path.join(ovl_dir, f"{aid}.jpg"),
                    overlay_for(bgr, W, H, shapes, rows, f"{aid[:8]} opencv-reference {phash}"),
                    [cv2.IMWRITE_JPEG_QUALITY, 85])
        done += 1
        accepted_counts.append(len(shapes))
        durations.append(stats["durationMs"])
        print(f"  {status:8s} {aid[:8]}  {W}x{H}  candidates {stats['candidates']:3d}  accepted {len(shapes):2d}"
              f"  {stats['durationMs']:5d} ms (wall {wall:.0f})")
    if accepted_counts:
        print(f"done {done}, skipped {skipped}, failed {failed} · accepted/image median "
              f"{statistics.median(accepted_counts):.1f} · ms/image median {statistics.median(durations):.0f}")
    else:
        print(f"done {done}, skipped {skipped}, failed {failed}")
    return 0 if failed == 0 else 1


def select_assets(manifest: dict, args) -> list:
    assets = list(manifest["assets"])
    only = getattr(args, "only", None)
    if only:
        wanted = [o.strip().upper() for o in only.split(",") if o.strip()]
        assets = [a for a in assets if any(a["assetId"].upper().startswith(w) for w in wanted)]
    limit = getattr(args, "limit", None)
    if limit:
        assets = assets[: int(limit)]
    return assets
