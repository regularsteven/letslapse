"""`edge-drawing` — EdgeDrawing (cv2.ximgproc, Topal & Akinlar) as a proposal
source for the shape benchmark rig (handover §7.2, measured 2026-09-12: on
its own 74 hits / 46 FP against the Kit's 74 / 69; in union with the Kit
97 hits — see docs/shape-benchmark/review-2026-09-12.md).

Needs `cv2.ximgproc`: `pip install opencv-contrib-python-headless` in place of
opencv-python-headless (the contrib wheel is a superset; uninstall the plain
one first so only one cv2 is installed). Edge chains are one-pixel, ordered and
connected; there is no closing size to choose, so a plate's outline is not
merged with the bracket under it. Proposals: (a) closed chains (the two ends
meet, or a loop inside the chain), at 1024 / 2048 / native; (b) EDCircles'
arc-grouped ellipse hypotheses, which are measured through the rig's
full-resolution refinement like any other synthetic outline. Every proposal
goes through the shared fitting pass (§3 rules) and the consensus-rule dedupe.
"""
from __future__ import annotations
import copy, json, os, statistics, sys, time, math
import cv2, numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import schema, overlay, metrics
import detect_opencv as ref
from fitting import (MATCH, RULES, Region, bbox_iou, polygon_bbox, fit_candidate, measure, dedupe_shapes, ellipse_outline)
from imaging import check_dims, dims_of, load_bgr

DETECTOR_ID = "edge-drawing"
DETECTOR_VERSION = "1"

DEFAULT_PARAMS = {
    "longEdges": [1024, 2048, 4096],                 # 4096 → native (never upscaled)
    "ed": {"pfMode": True, "minPathLength": 20, "gradientThreshold": 36, "anchorThreshold": 8,
           "scanInterval": 1, "sigma": 1.0, "nfa": True, "sumFlag": True},
    "chains": {"minPoints": 40, "endGapFrac": 0.15, "loopJoinPx": 3.0},
    # EDCircles hypotheses: requireRefined drops any that no full-resolution
    # contour confirms (a synthetic outline otherwise passes the IoU gate by
    # construction); minEdgeSupport gates them on the share of their outline
    # within edgeTolPx of ED's own native-scale edge map (0 = off).
    "ellipses": {"use": True, "requireRefined": False, "minEdgeSupport": 0.0, "edgeTolPx": 3},
    # Rectangle hypotheses from EDLines segments (handover §7.3): collinear
    # pieces merged, then every near-parallel facing pair spans a box whose two
    # closing sides must lie on edges. A hypothesis, so it is measured like an
    # ellipse hypothesis (refined against the maps, or gated on its own edge
    # support when nothing confirms it).
    "quads": {"use": False, "minLenFrac": 0.25, "angleTolDeg": 8.0, "mergeGapFrac": 0.3, "mergeOffsetPx": 2.5,
              "minOverlap": 0.6, "aspectMax": 4.0, "minClosingCover": 0.6, "minPairSupport": 0.8, "edgeTolPx": 3,
              "requireRefined": False, "maxPerScale": 400},
    "prefilter": {"minExtent": 0.08, "maxExtent": 0.98, "minSolidity": 0.60},
    "regionDedupe": {"bboxIoU": 0.80},
    "nativeChains": "asTraced",      # a chain traced at native scale is its own full-resolution measurement
    "lowScaleChains": "refine",      # "refine" (the rig's full-res re-trace, identity-checked) | "asTraced"
    # the reference's maps, for refine_region
    "blur": 5, "canny": {"mode": "otsu", "loFrac": 0.5, "minHi": 40, "aperture": 3}, "fillEnclosed": True,
    "adaptive": {"block": 51, "C": 5}, "close": [5, 9, 15],
    "contours": {"mode": "RETR_CCOMP", "method": "CHAIN_APPROX_NONE", "minPoints": 40},
    "refine": {"pad": 0.08, "priorIoU": 0.80, "identity": "consensus"},
    "shapeDedupe": {"iou": 0.90},
}


def merged_params(overrides):
    p = copy.deepcopy(DEFAULT_PARAMS)
    for k, v in (overrides or {}).items():
        if isinstance(v, dict) and isinstance(p.get(k), dict):
            p[k].update(v)
        else:
            p[k] = v
    return p


def make_ed(params):
    ed = cv2.ximgproc.createEdgeDrawing()
    q = cv2.ximgproc.EdgeDrawing.Params()
    e = params["ed"]
    q.PFmode = bool(e["pfMode"])
    q.MinPathLength = int(e["minPathLength"])
    q.GradientThresholdValue = int(e["gradientThreshold"])
    q.AnchorThresholdValue = int(e["anchorThreshold"])
    q.ScanInterval = int(e["scanInterval"])
    q.Sigma = float(e["sigma"])
    q.NFAValidation = bool(e["nfa"])
    q.SumFlag = bool(e["sumFlag"])
    ed.setParams(q)
    return ed


def closed_loops(P: np.ndarray, params) -> list[tuple[int, int]]:
    """Index ranges [i, j] of the chain that form a closed loop: the whole chain
    when its ends meet (within endGapFrac of its box), else any two points far
    apart along the chain that coincide within loopJoinPx (a loop with a tail,
    or a figure the chain went around and left)."""
    c = params["chains"]
    n = len(P); mp = int(c["minPoints"])
    if n < mp:
        return []
    x0, y0 = P.min(axis=0); x1, y1 = P.max(axis=0)
    box = max(x1 - x0, y1 - y0, 1)
    if np.hypot(*(P[0] - P[-1])) <= float(c["endGapFrac"]) * box:
        return [(0, n - 1)]
    join = float(c["loopJoinPx"])
    cell = max(1.0, join)
    grid: dict = {}
    keys = np.floor(P / cell).astype(np.int64)
    for i, (kx, ky) in enumerate(keys):
        grid.setdefault((int(kx), int(ky)), []).append(i)
    cands = []
    for i in range(n):
        kx, ky = int(keys[i][0]), int(keys[i][1])
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for j in grid.get((kx + dx, ky + dy), ()):
                    if j - i >= mp and np.hypot(*(P[i] - P[j])) <= join:
                        cands.append((j - i, i, j))
    cands.sort(reverse=True)
    loops: list[tuple[int, int]] = []
    for _len, i, j in cands:
        if any(min(j, b) - max(i, a) > 0.5 * min(j - i, b - a) for a, b in loops):
            continue
        loops.append((i, j))
    return loops


def merge_collinear(L: np.ndarray, params) -> np.ndarray:
    """Join segments that continue one another: same direction within 3°, both
    ends within mergeOffsetPx of the line, gap along it under mergeGapFrac of
    the shorter. Vectorised per anchor segment; repeated until stable."""
    q = params["quads"]
    P = np.asarray(L, np.float64).reshape(-1, 4)
    changed = True
    while changed and len(P) > 1:
        changed = False
        d = P[:, 2:] - P[:, :2]; ln = np.hypot(d[:, 0], d[:, 1]); ln[ln == 0] = 1e-9
        u = d / ln[:, None]; nrm = np.stack([-u[:, 1], u[:, 0]], axis=1)
        ang = np.degrees(np.arctan2(u[:, 1], u[:, 0])) % 180.0
        used = np.zeros(len(P), bool); out = []
        for i in range(len(P)):
            if used[i]:
                continue
            da = np.abs(ang - ang[i]); da = np.minimum(da, 180 - da)
            o1 = np.abs((P[:, 0] - P[i, 0]) * nrm[i, 0] + (P[:, 1] - P[i, 1]) * nrm[i, 1])
            o2 = np.abs((P[:, 2] - P[i, 0]) * nrm[i, 0] + (P[:, 3] - P[i, 1]) * nrm[i, 1])
            t1 = (P[:, 0] - P[i, 0]) * u[i, 0] + (P[:, 1] - P[i, 1]) * u[i, 1]
            t2 = (P[:, 2] - P[i, 0]) * u[i, 0] + (P[:, 3] - P[i, 1]) * u[i, 1]
            lo, hi = np.minimum(t1, t2), np.maximum(t1, t2)
            gap = np.maximum(lo - ln[i], 0 - hi)
            # only segments not yet visited this pass: an earlier one is already in `out`, and
            # merging it again duplicates it (the pass then never converges — found 2026-09-12)
            ok = (~used) & (np.arange(len(P)) > i) & (da <= 3.0) & (o1 <= q["mergeOffsetPx"]) & (o2 <= q["mergeOffsetPx"]) & (gap <= q["mergeGapFrac"] * np.minimum(ln[i], ln))
            js = np.where(ok)[0]
            if len(js) == 0:
                out.append(P[i]); continue
            used[js] = True
            t0 = min(0.0, lo[js].min()); tt = max(ln[i], hi[js].max())
            out.append(np.array([P[i, 0] + u[i, 0] * t0, P[i, 1] + u[i, 1] * t0, P[i, 0] + u[i, 0] * tt, P[i, 1] + u[i, 1] * tt]))
            changed = True
        P = np.array(out).reshape(-1, 4)
    return P


def quad_hypotheses(lines: np.ndarray, near: np.ndarray, sw: int, sh: int, params) -> list[np.ndarray]:
    """Rectangles spanned by facing near-parallel segment pairs, closed by two
    sides that lie on edges. Returns corner arrays (4, 2) in scaled px."""
    q = params["quads"]
    if lines is None or len(lines) == 0:
        return []
    floor_side = 0.10 * min(sw, sh)
    L = merge_collinear(np.asarray(lines, np.float64).reshape(-1, 4), params)
    d = L[:, 2:] - L[:, :2]; ln = np.hypot(d[:, 0], d[:, 1])
    keep = ln >= max(6.0, float(q["minLenFrac"]) * floor_side)
    L, d, ln = L[keep], d[keep], ln[keep]
    n = len(L)
    if n < 2:
        return []
    u = d / ln[:, None]; nrm = np.stack([-u[:, 1], u[:, 0]], axis=1); mid = (L[:, :2] + L[:, 2:]) / 2
    ang = np.degrees(np.arctan2(u[:, 1], u[:, 0])) % 180.0
    H, W = near.shape[:2]
    def support(p, qq, k=24):
        t = np.linspace(0, 1, k)[:, None]; pts = p + (qq - p) * t
        xy = np.round(pts).astype(int); ok = (xy[:, 0] >= 0) & (xy[:, 1] >= 0) & (xy[:, 0] < W) & (xy[:, 1] < H)
        if not ok.any():
            return 0.0
        return float(np.count_nonzero(near[xy[ok, 1], xy[ok, 0]])) / k
    out = []
    tol = float(q["angleTolDeg"])
    for i in range(n):
        da = np.abs(ang - ang[i]); da = np.minimum(da, 180 - da)
        # signed perpendicular distance of the other midpoints from i's line, and their projection overlap
        rel = mid - mid[i]
        dist = rel @ nrm[i]
        proj = rel @ u[i]
        cand = np.where((da <= tol) & (np.abs(dist) >= max(6.0, 0.5 * floor_side)) & (np.arange(n) > i))[0]
        for j in cand:
            dd = abs(dist[j])
            # overlap along i's direction
            a0, a1 = -ln[i] / 2, ln[i] / 2
            b0, b1 = proj[j] - ln[j] / 2, proj[j] + ln[j] / 2
            ov = min(a1, b1) - max(a0, b0)
            if ov < float(q["minOverlap"]) * min(ln[i], ln[j]):
                continue
            span0, span1 = min(a0, b0), max(a1, b1)
            span = span1 - span0
            if span < 6 or dd / span > float(q["aspectMax"]) or span / dd > float(q["aspectMax"]):
                continue
            # corners: on i's line at span0/span1 and on j's line (offset dist along the normal)
            c = mid[i]; ui = u[i]; ni = nrm[i]
            p0 = c + ui * span0; p1 = c + ui * span1
            p2 = c + ui * span1 + ni * dist[j]; p3 = c + ui * span0 + ni * dist[j]
            # the two generating sides must be well supported over the whole span
            if support(p0, p1) < float(q["minPairSupport"]) or support(p3, p2) < float(q["minPairSupport"]):
                continue
            # the closing sides must be covered by real segments: same direction
            # within the angle tolerance, both ends within 3 px of the side's
            # line, and their projections covering minClosingCover of the side.
            def covered(pa, pb):
                v = pb - pa; L2 = np.hypot(*v); vu = v / max(L2, 1e-9); vn = np.array([-vu[1], vu[0]])
                a_side = np.degrees(np.arctan2(vu[1], vu[0])) % 180.0
                dang = np.abs(ang - a_side); dang = np.minimum(dang, 180 - dang)
                o1 = np.abs((L[:, 0] - pa[0]) * vn[0] + (L[:, 1] - pa[1]) * vn[1]); o2 = np.abs((L[:, 2] - pa[0]) * vn[0] + (L[:, 3] - pa[1]) * vn[1])
                ok = (dang <= tol) & (o1 <= 3.0) & (o2 <= 3.0)
                if not ok.any():
                    return 0.0
                t1 = (L[ok, 0] - pa[0]) * vu[0] + (L[ok, 1] - pa[1]) * vu[1]; t2 = (L[ok, 2] - pa[0]) * vu[0] + (L[ok, 3] - pa[1]) * vu[1]
                lo = np.clip(np.minimum(t1, t2), 0, L2); hi = np.clip(np.maximum(t1, t2), 0, L2)
                iv = sorted(zip(lo, hi)); cov = 0.0; cur_lo, cur_hi = None, None
                for a, b in iv:
                    if b <= a: continue
                    if cur_hi is None or a > cur_hi:
                        if cur_hi is not None: cov += cur_hi - cur_lo
                        cur_lo, cur_hi = a, b
                    else:
                        cur_hi = max(cur_hi, b)
                if cur_hi is not None: cov += cur_hi - cur_lo
                return cov / max(L2, 1e-9)
            s_close = min(covered(p1, p2), covered(p3, p0))
            if s_close < float(q["minClosingCover"]):
                continue
            out.append((s_close, np.array([p0, p1, p2, p3])))
    out.sort(key=lambda t: -t[0])
    return [c for _s, c in out[: int(q["maxPerScale"])]]


def propose(gray: np.ndarray, params: dict) -> tuple[list[Region], dict]:
    H, W = gray.shape[:2]
    pf = params["prefilter"]
    regions: list[Region] = []
    stats = {"chains": 0, "loops": 0, "edEllipses": 0, "edMs": 0}
    for L in params["longEdges"]:
        s = min(1.0, float(L) / max(W, H))
        sw, sh = max(1, round(W * s)), max(1, round(H * s))
        small = cv2.resize(gray, (sw, sh), interpolation=cv2.INTER_AREA) if s < 1.0 else gray
        t0 = time.perf_counter()
        ed = make_ed(params)
        ed.detectEdges(small)
        segments = ed.getSegments()
        ells = ed.detectEllipses() if params["ellipses"]["use"] else None
        stats["edMs"] += int(round(1000 * (time.perf_counter() - t0)))
        stats["chains"] += len(segments)
        for seg in segments:
            P = np.asarray(seg, np.float64).reshape(-1, 2)
            for i, j in closed_loops(P, params):
                Q = P[i:j + 1]
                stats["loops"] += 1
                x0, y0 = Q.min(axis=0); x1, y1 = Q.max(axis=0)
                ext = max((x1 - x0 + 1) / sw, (y1 - y0 + 1) / sh)
                if ext < pf["minExtent"] or ext > pf["maxExtent"]:
                    continue
                cvq = Q.astype(np.float32).reshape(-1, 1, 2)
                area = abs(cv2.contourArea(cvq)); hull = abs(cv2.contourArea(cv2.convexHull(cvq)))
                if hull <= 0 or area / hull < pf["minSolidity"]:
                    continue
                pts = (Q.astype(np.float32) + 0.5) / s - 0.5
                regions.append(Region(pts=pts, source=f"ed-chain@{L}", from_contour=True, refined=(s >= 1.0), scale=s,
                                      prior={"proposalExtent": round(float(ext), 4), "solidity": round(float(area / hull), 3),
                                             "chainLen": int(len(P)), "loop": [int(i), int(j)]}))
        if params["quads"]["use"]:
            t0q = time.perf_counter()
            lines = ed.detectLines()
            edge_img = ed.getEdgeImage()
            tq = int(params["quads"].get("edgeTolPx", 3))
            nearq = cv2.dilate(edge_img, np.ones((2 * tq + 1, 2 * tq + 1), np.uint8)) if tq > 0 else edge_img
            quads = quad_hypotheses(lines, nearq, sw, sh, params)
            stats["quadHyp"] = stats.get("quadHyp", 0) + len(quads)
            stats["quadMs"] = stats.get("quadMs", 0) + int(round(1000 * (time.perf_counter() - t0q)))
            from fitting import densify_polygon
            for c in quads:
                x0, y0 = c.min(axis=0); x1, y1 = c.max(axis=0)
                ext = max((x1 - x0 + 1) / sw, (y1 - y0 + 1) / sh)
                if ext < pf["minExtent"] or ext > pf["maxExtent"]:
                    continue
                pts = densify_polygon((c + 0.5) / s - 0.5, 2.0)
                regions.append(Region(pts=pts, source=f"ed-quad@{L}", from_contour=False, refined=False, scale=s,
                                      prior={"proposalExtent": round(float(ext), 4)}))
        if ells is not None and len(ells):
            near = None
            if float(params["ellipses"].get("minEdgeSupport", 0)) > 0:
                if s >= 1.0:
                    edge_img = ed.getEdgeImage()
                else:
                    edn = make_ed(params); edn.detectEdges(gray); edge_img = edn.getEdgeImage()
                t = int(params["ellipses"].get("edgeTolPx", 3))
                near = cv2.dilate(edge_img, np.ones((2 * t + 1, 2 * t + 1), np.uint8)) if t > 0 else edge_img
            for e in np.asarray(ells).reshape(-1, 6):
                stats["edEllipses"] += 1
                cx, cy, r, ax, ay, ang = [float(v) for v in e]
                A, B = r + ax, r + ay
                if A <= 0 or B <= 0:
                    continue
                ext = max(2 * max(A, B) / sw, 2 * max(A, B) / sh)
                if ext < pf["minExtent"] or ext > pf["maxExtent"]:
                    continue
                pts = ellipse_outline(cx / s, cy / s, A / s, B / s, ang, 360)
                prior = {"proposalExtent": round(float(ext), 4), "edCircle": bool(ax == 0 and ay == 0)}
                if near is not None:
                    q = np.round(pts).astype(int)
                    ok = (q[:, 0] >= 0) & (q[:, 1] >= 0) & (q[:, 0] < W) & (q[:, 1] < H)
                    support = float(np.count_nonzero(near[q[ok, 1], q[ok, 0]])) / max(1, len(q))
                    prior["edgeSupport"] = round(support, 3)
                    stats["ellipsesOffered"] = stats.get("ellipsesOffered", 0) + 1
                    if support < float(params["ellipses"]["minEdgeSupport"]):
                        continue
                regions.append(Region(pts=pts, source=f"ed-ellipse@{L}", from_contour=False, refined=False, scale=s, prior=prior))
    # dedupe by bbox IoU: native scale first, then larger
    regions.sort(key=lambda r: (-r.scale, -(polygon_bbox(r.pts)[2] - polygon_bbox(r.pts)[0]) * (polygon_bbox(r.pts)[3] - polygon_bbox(r.pts)[1])))
    kept, boxes = [], []
    thr = float(params["regionDedupe"]["bboxIoU"])
    for r in regions:
        bb = polygon_bbox(r.pts)
        if any(bbox_iou(bb, kb) >= thr for kb in boxes):
            continue
        kept.append(r); boxes.append(bb)
    return kept, stats


def detect_image(bgr, params, rules=RULES):
    W, H = dims_of(bgr)
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    t0 = time.perf_counter()
    regions, pstats = propose(gray, params)
    t_prop = time.perf_counter()
    rows, accepted = [], []
    for r in regions:
        as_traced = (r.source.startswith("ed-chain") and
                     ((r.scale >= 1.0 and params["nativeChains"] == "asTraced") or
                      (r.scale < 1.0 and params["lowScaleChains"] == "asTraced")))
        if as_traced:
            r2, v = r, fit_candidate(r, W, H, rules)
        else:
            r2, v = measure(gray, r, params, W, H, rules)
        row = {k: v[k] for k in ("source", "refined", "nPoints", "contourExtent", "extentRatio", "sizeBand",
                                 "accepted", "primitive", "subclass", "winner", "rectScore", "ellipseScore", "reasons", "prior")}
        row["rect"] = ref._slim(v["rect"]); row["ellipse"] = ref._slim(v["ellipse"]); row["outline"] = ref._thin_outline(r2.pts)
        if v["accepted"] and params["quads"].get("requireRefined") and r.source.startswith("ed-quad") and not v["refined"]:
            v["accepted"] = False; v["reasons"] = ["hypothesis unconfirmed: no full-resolution contour matched it"]; row["accepted"] = False; row["reasons"] = v["reasons"]
        if v["accepted"] and params["ellipses"].get("requireRefined") and r.source.startswith("ed-ellipse") and not v["refined"]:
            v["accepted"] = False; v["reasons"] = ["hypothesis unconfirmed: no full-resolution contour matched it"]; row["accepted"] = False; row["reasons"] = v["reasons"]
        if v["accepted"]:
            row["shapeId"] = v["shape"]["shapeId"]; accepted.append(v["shape"])
        rows.append(row)
    dd = dict(MATCH); dd["iou"] = float(params["shapeDedupe"]["iou"])
    shapes = dedupe_shapes(accepted, W, H, dd)
    kept_ids = {s["shapeId"] for s in shapes}
    for row in rows:
        if row.get("shapeId") and row["shapeId"] not in kept_ids:
            row["dedupedAway"] = True
    t1 = time.perf_counter()
    stats = {"candidates": len(regions), "accepted": len(shapes), "acceptedBeforeDedupe": len(accepted),
             "proposalMs": int(round((t_prop - t0) * 1000)), "durationMs": int(round((t1 - t0) * 1000))}
    stats.update(pstats)
    return shapes, stats, rows


def gt_for(work, aid):
    doc = json.load(open(schema.results_path(work, aid)))
    gts = [r for r in doc["runs"] if r["detectorId"] == schema.DETECTOR_GT]
    if not gts:
        return None
    gt = max(gts, key=lambda r: r["runAt"])
    a = next((x for x in gt["assets"] if x["assetId"] == aid), None)
    return [s for s in a["shapes"] if s["extentRatio"] >= RULES["size"]["floor"]] if a else None


def run(args) -> int:
    if not hasattr(cv2, "ximgproc"):
        sys.exit("edge-drawing needs cv2.ximgproc — pip install opencv-contrib-python-headless (see the module docstring)")
    work = args.work
    manifest = json.load(open(os.path.join(work, "manifest.json")))
    overrides = json.load(open(args.params)) if args.params else None
    params = merged_params(overrides)
    run_params = {"detector": params, "rules": RULES}
    phash = schema.params_hash(run_params)
    key = schema.run_key(DETECTOR_ID, DETECTOR_VERSION, phash)
    print(f"{DETECTOR_ID} v{DETECTOR_VERSION} params {phash}  ({'defaults' if not overrides else args.params}){'  DRY' if args.dry else ''}")
    assets = ref.select_assets(manifest, args)
    ovl_dir = os.path.join(args.dry_dir if args.dry else work, "overlays", DETECTOR_ID + ("" if not overrides else "." + phash))
    os.makedirs(ovl_dir, exist_ok=True)
    TP = FP = FN = 0
    accepted_counts, durations = [], []
    for a in assets:
        aid = a["assetId"]
        rpath = schema.results_path(work, aid)
        doc = schema.load_results(rpath, a["projectId"])
        if schema.has_run(doc, key) and not args.force and not args.dry:
            print(f"  skip {aid[:8]}  (already ran {phash})"); continue
        bgr = load_bgr(os.path.join(work, a["image"]))
        check_dims(bgr, a["frameWidth"], a["frameHeight"], aid[:8])
        W, H = dims_of(bgr)
        t0 = time.perf_counter()
        shapes, stats, rows = detect_image(bgr, params)
        wall = (time.perf_counter() - t0) * 1000
        gt = gt_for(work, aid)
        score = ""
        if gt is not None:
            m = metrics.match_asset(gt, [s for s in shapes if s["extentRatio"] >= RULES["size"]["floor"]], W, H)
            TP += len(m["matched"]); FP += len(m["fp"]); FN += len(m["fn"])
            score = f"  TP {len(m['matched'])} FP {len(m['fp'])} FN {len(m['fn'])}"
        if not args.dry:
            run_block = schema.new_run(DETECTOR_ID, DETECTOR_VERSION, run_params, stats["durationMs"])
            run_block["assets"] = [schema.new_asset(aid, W, H, shapes, stats)]
            schema.upsert_run(doc, run_block, force=args.force)
            schema.save_results(rpath, doc)
            ref.write_rows(ref.log_path_for(work, DETECTOR_ID, key), aid, rows, key)
        cv2.imwrite(os.path.join(ovl_dir, f"{aid}.jpg"), ref.overlay_for(bgr, W, H, shapes, rows, f"{aid[:8]} {DETECTOR_ID} {phash}"),
                    [cv2.IMWRITE_JPEG_QUALITY, 85])
        accepted_counts.append(len(shapes)); durations.append(stats["durationMs"])
        print(f"  {aid[:8]}  chains {stats['chains']:5d} loops {stats['loops']:4d} edEll {stats['edEllipses']:3d} quadHyp {stats.get('quadHyp', 0):4d} cand {stats['candidates']:3d} acc {len(shapes):2d}  ed {stats['edMs']} ms quads {stats.get('quadMs', 0)} ms total {stats['durationMs']} ms{score}")
    if accepted_counts:
        print(f"done {len(accepted_counts)} · accepted/image median {statistics.median(accepted_counts):.1f} · ms/image median {statistics.median(durations):.0f}"
              + (f" · TP {TP} FP {FP} FN {FN} · recall {TP/(TP+FN):.2f} precision {TP/(TP+FP) if TP+FP else 0:.2f}" if TP + FN else ""))
    return 0


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", default=os.path.join(HERE, "work"))
    ap.add_argument("--params"); ap.add_argument("--only"); ap.add_argument("--limit", type=int)
    ap.add_argument("--force", action="store_true"); ap.add_argument("--dry", action="store_true")
    ap.add_argument("--dry-dir", default=os.path.join(HERE, "work", "overlays", "edge-drawing-dry"))
    sys.exit(run(ap.parse_args()))
