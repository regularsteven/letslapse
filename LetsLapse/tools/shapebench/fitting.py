"""The shared measurement pass (brief §5, Stage 2).

Every candidate region — an OpenCV contour, an Apple-Vision primitive from
`lapse shapes --json`, a v1 register shape, or a person's clicks — comes through
`fit_candidate` (detectors) or `shape_from_label` (ground truth), so detectors
are compared on their ability to FIND regions, not on their own ideas of how to
describe them.

Conventions (see schema.py): native pixels, upright, origin top-left, y down.
orientationDeg in [0, 180) is the angle of the major/long axis from +x toward
+y — the same frame as OpenCV and as the Kit's `rotation` (no flip).

OpenCV facts this file is written around (checked on cv2 5.0.0):
  * cv2.fitEllipse / fitEllipseDirect return ((cx, cy), (w, h), angle) with
    FULL axes and `angle` belonging to axis w, which is usually the minor.
  * cv2.ellipse draws SEMI-axes with the same angle convention.
  * cv2.minAreaRect's angle range differs between OpenCV versions — never read
    it; orientation comes from cv2.boxPoints.
  * The Kit's majorAxis/minorAxis are full axes as fractions of frame WIDTH,
    while its centre and corners are per-axis — convert to px before geometry.
"""
from __future__ import annotations

import math
import uuid
from dataclasses import dataclass, field

import cv2
import numpy as np

# Acceptance rules (brief §3). Hashed into every run's params.
RULES = {
    "rect": {"angleTolDeg": 8.0, "sideTol": 0.10, "minFill": 0.85, "squareTol": 0.05,
             "approxEpsFrac": 0.02},
    "ellipse": {"minIoU": 0.90, "minAxisRatio": 0.40, "circleRatio": 0.95},
    "size": {"floor": 0.10, "small": 0.35, "medium": 0.65},
    "preFloor": 0.05,     # contour bbox extent below this: skip fitting, log only
    "borderPx": 2,        # a traced contour this close to the frame edge is clipped
    "tieMargin": 0.02,    # rect wins a near-tie when its four sides are straight
}

# Consensus rule (brief §5, Stage 3) — used for detector dedupe and metrics.
MATCH = {"centrePctDiag": 2.0, "iou": 0.70, "aspectTol": 0.10, "workingLongEdge": 1024}

SHIFT = 4
SCALE = 1 << SHIFT


@dataclass
class Region:
    pts: np.ndarray                 # (N, 2) float32 closed boundary, native px
    source: str                     # 'cv-<map>@<edge>' | 'v1-ellipse' | 'v1-quad' | 'label'
    from_contour: bool = True       # traced by findContours → the border rule applies
    refined: bool = False           # re-traced at full resolution
    scale: float = 1.0              # proposal scale the outline was traced at
    prior: dict = field(default_factory=dict)


# --- small geometry -------------------------------------------------------

def as_cv(pts) -> np.ndarray:
    return np.ascontiguousarray(np.asarray(pts, dtype=np.float32)).reshape(-1, 1, 2)


def ellipse_outline(cx, cy, a, b, theta_deg, n=360) -> np.ndarray:
    t = np.linspace(0.0, 2.0 * np.pi, n, endpoint=False)
    th = math.radians(theta_deg)
    ct, st = np.cos(t), np.sin(t)
    x = cx + a * ct * math.cos(th) - b * st * math.sin(th)
    y = cy + a * ct * math.sin(th) + b * st * math.cos(th)
    return np.stack([x, y], axis=1).astype(np.float32)


def densify_polygon(pts, spacing=2.0) -> np.ndarray:
    P = np.asarray(pts, dtype=np.float64).reshape(-1, 2)
    out = []
    n = len(P)
    for i in range(n):
        p, q = P[i], P[(i + 1) % n]
        seg = float(np.hypot(*(q - p)))
        k = max(1, int(math.ceil(seg / spacing)))
        for j in range(k):
            out.append(p + (q - p) * (j / k))
    return np.asarray(out, dtype=np.float32)


def polygon_bbox(pts) -> tuple[float, float, float, float]:
    P = np.asarray(pts, dtype=np.float64).reshape(-1, 2)
    x0, y0 = P.min(axis=0)
    x1, y1 = P.max(axis=0)
    return float(x0), float(y0), float(x1), float(y1)


def ellipse_bbox(cx, cy, a, b, theta_deg) -> tuple[float, float, float, float]:
    th = math.radians(theta_deg)
    hw = math.sqrt((a * math.cos(th)) ** 2 + (b * math.sin(th)) ** 2)
    hh = math.sqrt((a * math.sin(th)) ** 2 + (b * math.cos(th)) ** 2)
    return cx - hw, cy - hh, cx + hw, cy + hh


def bbox_iou(a, b) -> float:
    ix0, iy0 = max(a[0], b[0]), max(a[1], b[1])
    ix1, iy1 = min(a[2], b[2]), min(a[3], b[3])
    iw, ih = max(0.0, ix1 - ix0), max(0.0, iy1 - iy0)
    inter = iw * ih
    ua = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / ua if ua > 0 else 0.0


def extent_ratio(bbox, W, H) -> float:
    return max((bbox[2] - bbox[0]) / W, (bbox[3] - bbox[1]) / H)


def size_band(extent: float, rules=RULES) -> str:
    s = rules["size"]
    if extent < s["floor"]:
        return "discard"
    if extent < s["small"]:
        return "small"
    if extent < s["medium"]:
        return "medium"
    return "large"


def interior_angles(P) -> list[float]:
    P = np.asarray(P, dtype=np.float64).reshape(-1, 2)
    n = len(P)
    out = []
    for i in range(n):
        u = P[i - 1] - P[i]
        v = P[(i + 1) % n] - P[i]
        cross = u[0] * v[1] - u[1] * v[0]
        dot = u[0] * v[0] + u[1] * v[1]
        out.append(math.degrees(math.atan2(abs(cross), dot)))
    return out


def order_clockwise_from_topleft(P) -> np.ndarray:
    """Sort 4 (or more) vertices clockwise on screen (y down), starting at the
    one nearest the top-left — the v1 register's corner order."""
    P = np.asarray(P, dtype=np.float64).reshape(-1, 2)
    c = P.mean(axis=0)
    ang = np.arctan2(P[:, 1] - c[1], P[:, 0] - c[0])
    Q = P[np.argsort(ang)]          # ascending atan2 in a y-down frame = clockwise
    start = int(np.argmin(Q[:, 0] + Q[:, 1]))
    return np.roll(Q, -start, axis=0)


def angle_diff_deg(a: float, b: float, modulus: float = 180.0) -> float:
    d = abs(a - b) % modulus
    return min(d, modulus - d)


# --- rasterisation --------------------------------------------------------

def roi_of(bbox, W=None, H=None, pad_frac=0.10, min_pad=4) -> tuple[int, int, int, int]:
    x0, y0, x1, y1 = bbox
    pad = max(min_pad, pad_frac * max(x1 - x0, y1 - y0))
    X0 = int(math.floor(x0 - pad))
    Y0 = int(math.floor(y0 - pad))
    X1 = int(math.ceil(x1 + pad)) + 1
    Y1 = int(math.ceil(y1 + pad)) + 1
    if W is not None:
        X0, X1 = max(0, X0), min(int(W), X1)
    if H is not None:
        Y0, Y1 = max(0, Y0), min(int(H), Y1)
    if X1 <= X0:
        X1 = X0 + 1
    if Y1 <= Y0:
        Y1 = Y0 + 1
    return X0, Y0, X1, Y1


def raster_polygon(pts, roi) -> np.ndarray:
    X0, Y0, X1, Y1 = roi
    m = np.zeros((Y1 - Y0, X1 - X0), np.uint8)
    q = np.round((np.asarray(pts, np.float64).reshape(-1, 2) - (X0, Y0)) * SCALE).astype(np.int32)
    cv2.fillPoly(m, [q.reshape(-1, 1, 2)], 255, cv2.LINE_8, SHIFT)
    return m


def raster_ellipse(cx, cy, a, b, theta_deg, roi) -> np.ndarray:
    X0, Y0, X1, Y1 = roi
    m = np.zeros((Y1 - Y0, X1 - X0), np.uint8)
    cv2.ellipse(m, (int(round((cx - X0) * SCALE)), int(round((cy - Y0) * SCALE))),
                (int(round(a * SCALE)), int(round(b * SCALE))),
                float(theta_deg), 0, 360, 255, -1, cv2.LINE_8, SHIFT)
    return m


def mask_iou(a: np.ndarray, b: np.ndarray) -> float:
    inter = int(np.count_nonzero(a & b))
    union = int(np.count_nonzero(a | b))
    return inter / union if union else 0.0


# --- edge / region maps (shared by the proposer and full-res refinement) --

def auto_canny(gray: np.ndarray, params: dict) -> np.ndarray:
    """Canny with thresholds from the picture itself. 'otsu' (default): hi = the
    Otsu split of the blurred gray, lo = loFrac·hi — robust on bright walls
    and dark facades alike. 'median': lo/hi = (1∓σ)·median (Rosebrock's
    heuristic) — kept as an option; it goes blind on a bright flat picture
    (median 165 → hi 220, and the plate border is gone)."""
    mode = params.get("mode", "otsu")
    if mode == "median":
        v = float(np.median(gray))
        sigma = float(params.get("sigma", 0.33))
        lo, hi = int(max(0.0, (1.0 - sigma) * v)), int(min(255.0, (1.0 + sigma) * v))
    else:
        hi, _ = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        hi = float(max(float(params.get("minHi", 40)), hi))
        lo = float(params.get("loFrac", 0.5)) * hi
    return cv2.Canny(gray, int(lo), int(hi), apertureSize=int(params.get("aperture", 3)), L2gradient=True)


def fill_enclosed(edges: np.ndarray) -> np.ndarray:
    """Everything the edge map encloses, as solid 255 regions: pad by one
    background pixel, flood the background from the corner, invert."""
    h, w = edges.shape[:2]
    padded = np.zeros((h + 2, w + 2), np.uint8)
    padded[1:-1, 1:-1] = edges
    inv = cv2.bitwise_not(padded)                    # background 255, edges 0
    mask = np.zeros((h + 4, w + 4), np.uint8)
    cv2.floodFill(inv, mask, (0, 0), 0)              # background reachable from outside → 0
    return inv[1:-1, 1:-1]                           # what is left: enclosed interiors


def binary_maps(gray: np.ndarray, params: dict) -> list[tuple[str, np.ndarray]]:
    """The region maps a picture is traced on, at every closing size in
    params["close"]: the closed edge map (a ring gives its outer boundary), the
    edge map's enclosed interiors (a broken ring that closing can seal becomes
    a solid blob), and the adaptive threshold in both polarities, each with
    its own enclosed-fill. Small closings keep neighbours apart; large ones
    seal the gaps at a plate's rounded corners."""
    k = int(params.get("blur", 5))
    g = cv2.GaussianBlur(gray, (k, k), 0) if k > 1 else gray
    blk = int(params["adaptive"]["block"])
    blk = max(3, blk | 1)
    C = float(params["adaptive"]["C"])
    closes = params.get("close", [5])
    if not isinstance(closes, (list, tuple)):
        closes = [closes]
    fill = bool(params.get("fillEnclosed", True))
    raw = [("canny", auto_canny(g, params["canny"])),
           ("adaptive", cv2.adaptiveThreshold(g, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, blk, C)),
           ("adaptive-inv", cv2.adaptiveThreshold(g, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY_INV, blk, C))]
    maps = []
    for ck in closes:
        ck = int(ck)
        kern = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (ck, ck)) if ck > 1 else None
        for name, m0 in raw:
            m = cv2.morphologyEx(m0, cv2.MORPH_CLOSE, kern) if kern is not None else m0
            maps.append((f"{name}~c{ck}", m))
            if fill:
                maps.append((f"{name}-filled~c{ck}", fill_enclosed(m)))
    return maps


def refine_region(gray: np.ndarray, region: Region, params: dict) -> Region:
    """Re-trace a proposal at full resolution inside its own ROI. The contour
    with the highest mask IoU against the prior outline (≥ refine.priorIoU)
    replaces it; otherwise the prior stands, flagged refined=False."""
    H, W = gray.shape[:2]
    bb = polygon_bbox(region.pts)
    roi = roi_of(bb, W, H, pad_frac=float(params["refine"]["pad"]))
    X0, Y0, X1, Y1 = roi
    crop = gray[Y0:Y1, X0:X1]
    if crop.size == 0:
        return region
    prior = raster_polygon(region.pts, roi)
    pb = (bb[0] - X0, bb[1] - Y0, bb[2] - X0, bb[3] - Y0)
    min_pts = int(params["contours"]["minPoints"])
    best_iou, best_c, best_map = 0.0, None, None
    for name, m in binary_maps(crop, params):
        contours, _ = cv2.findContours(m, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
        for c in contours:
            if len(c) < min_pts:
                continue
            x, y, w, h = cv2.boundingRect(c)
            if bbox_iou((x, y, x + w, y + h), pb) < 0.5:
                continue
            mask = np.zeros_like(prior)
            cv2.drawContours(mask, [c], -1, 255, -1)
            iou = mask_iou(mask, prior)
            if iou > best_iou:
                best_iou, best_c, best_map = iou, c, name
    prov = dict(region.prior)
    prov["refineIoU"] = round(best_iou, 3)
    if best_c is not None and best_iou >= float(params["refine"]["priorIoU"]):
        pts = best_c.reshape(-1, 2).astype(np.float32) + np.array([X0, Y0], np.float32)
        prov["refineMap"] = best_map
        return Region(pts=pts, source=region.source, from_contour=True, refined=True, scale=1.0, prior=prov)
    return Region(pts=region.pts, source=region.source, from_contour=region.from_contour,
                  refined=False, scale=region.scale, prior=prov)


# --- fitting --------------------------------------------------------------

def fit_rect(pts, rules=RULES) -> dict:
    R = rules["rect"]
    cvp = as_cv(pts)
    res: dict = {"ok": False, "reasons": [], "nVerticesAt": {}}
    per = float(cv2.arcLength(cvp, True))
    eps_main = float(R["approxEpsFrac"])
    polys = {}
    for eps in sorted({0.01, eps_main, 0.03}):
        polys[eps] = cv2.approxPolyDP(cvp, eps * per, True).reshape(-1, 2)
        res["nVerticesAt"][f"{eps:.3f}"] = int(len(polys[eps]))
    poly = polys[eps_main]
    rr = cv2.minAreaRect(cvp)
    box = cv2.boxPoints(rr).astype(np.float64)
    w, h = float(rr[1][0]), float(rr[1][1])
    long_, short = max(w, h), min(w, h)
    area = abs(float(cv2.contourArea(cvp)))
    fitted = long_ * short
    fill = area / fitted if fitted > 0 else 0.0
    e0, e1 = box[1] - box[0], box[2] - box[1]
    e = e0 if np.hypot(*e0) >= np.hypot(*e1) else e1
    theta = math.degrees(math.atan2(e[1], e[0])) % 180.0
    res.update(centre=(float(rr[0][0]), float(rr[0][1])), long=long_, short=short,
               aspect=(long_ / short) if short > 0 else float("inf"), orientationDeg=theta,
               fillRatio=float(fill), box=box, nVertices=int(len(poly)), vertices=None,
               angles=None, maxAngularDeviationDeg=None, sideMismatch=None, convex=None)
    if len(poly) != 4:
        res["reasons"].append(f"{len(poly)} vertices, not 4")
        return res
    convex = bool(cv2.isContourConvex(poly.reshape(-1, 1, 2).astype(np.float32)))
    res["convex"] = convex
    if not convex:
        res["reasons"].append("not convex")
    Q = order_clockwise_from_topleft(poly)
    angles = interior_angles(Q)
    dev = max(abs(a - 90.0) for a in angles)
    sides = [float(np.hypot(*(Q[(i + 1) % 4] - Q[i]))) for i in range(4)]
    mism = max(abs(sides[0] - sides[2]) / (max(sides[0], sides[2]) or 1.0),
               abs(sides[1] - sides[3]) / (max(sides[1], sides[3]) or 1.0))
    res.update(vertices=Q, angles=angles, maxAngularDeviationDeg=float(dev), sideMismatch=float(mism))
    if dev > R["angleTolDeg"]:
        res["reasons"].append(f"angle deviation {dev:.1f}° > {R['angleTolDeg']:.0f}°")
    if mism > R["sideTol"]:
        res["reasons"].append(f"opposite sides differ {mism * 100:.1f}% > {R['sideTol'] * 100:.0f}%")
    if fill < R["minFill"]:
        res["reasons"].append(f"fill {fill:.3f} < {R['minFill']}")
    res["ok"] = not res["reasons"]
    return res


def _ellipse_from_cv(e) -> tuple[float, float, float, float, float]:
    (cx, cy), (w, h), ang = e
    if w >= h:
        a, b, th = w / 2.0, h / 2.0, ang
    else:
        a, b, th = h / 2.0, w / 2.0, ang + 90.0
    return float(cx), float(cy), float(a), float(b), float(th % 180.0)


def fit_ellipse_params(pts, bbox=None):
    """((cx, cy), a, b, thetaDeg) from a direct least-squares conic fit, or None."""
    P = np.asarray(pts, np.float32).reshape(-1, 2)
    if len(P) < 5:
        return None
    bb = bbox or polygon_bbox(P)
    bw, bh = bb[2] - bb[0], bb[3] - bb[1]
    cvp = as_cv(P)
    for fn in (cv2.fitEllipseDirect, cv2.fitEllipse):
        try:
            e = fn(cvp)
        except cv2.error:
            continue
        cx, cy, a, b, th = _ellipse_from_cv(e)
        if all(math.isfinite(v) for v in (cx, cy, a, b, th)) and 0 < b <= a and a <= 2.0 * max(bw, bh, 1.0):
            return cx, cy, a, b, th
    return None


def fit_ellipse(pts, rules=RULES, W=None, H=None) -> dict:
    E = rules["ellipse"]
    res: dict = {"ok": False, "reasons": []}
    P = np.asarray(pts, np.float32).reshape(-1, 2)
    if len(P) < 5:
        res["reasons"].append("fewer than 5 points")
        return res
    bb = polygon_bbox(P)
    fit = fit_ellipse_params(P, bb)
    if fit is None:
        res["reasons"].append("ellipse fit failed")
        return res
    cx, cy, a, b, th = fit
    ebb = ellipse_bbox(cx, cy, a, b, th)
    union = (min(bb[0], ebb[0]), min(bb[1], ebb[1]), max(bb[2], ebb[2]), max(bb[3], ebb[3]))
    roi = roi_of(union, W, H, pad_frac=0.10)
    iou = mask_iou(raster_polygon(P, roi), raster_ellipse(cx, cy, a, b, th, roi))
    ratio = b / a
    res.update(centre=(cx, cy), a=a, b=b, orientationDeg=th, iou=float(iou),
               axisRatio=float(ratio), aspect=float(a / b))
    if iou < E["minIoU"]:
        res["reasons"].append(f"ellipse IoU {iou:.3f} < {E['minIoU']}")
    if ratio < E["minAxisRatio"]:
        res["reasons"].append(f"axis ratio {ratio:.2f} < {E['minAxisRatio']}")
    res["ok"] = not res["reasons"]
    return res


def _rect_structural(r: dict, rules=RULES) -> bool:
    R = rules["rect"]
    return (r.get("nVertices") == 4 and bool(r.get("convex"))
            and r.get("maxAngularDeviationDeg") is not None
            and r["maxAngularDeviationDeg"] <= R["angleTolDeg"]
            and r["sideMismatch"] <= R["sideTol"])


def jsonable(d):
    """Strip numpy from a fit dict for the candidate log."""
    if d is None:
        return None
    out = {}
    for k, v in d.items():
        if k in ("box", "angles"):
            continue
        if isinstance(v, np.ndarray):
            out[k] = np.round(v, 2).tolist()
        elif isinstance(v, (np.floating, np.integer)):
            out[k] = float(v)
        elif isinstance(v, float):
            out[k] = round(v, 4)
        elif isinstance(v, tuple):
            out[k] = [round(float(x), 2) for x in v]
        else:
            out[k] = v
    return out


def serialise_shape(primitive: str, fit: dict, W: int, H: int, extent: float, band: str,
                    rules=RULES, confidence=None, provenance=None) -> dict:
    d: dict = {"shapeId": str(uuid.uuid4()).upper(), "primitive": primitive}
    if primitive == "rectangle":
        aspect = float(fit["aspect"])
        d["subclass"] = "square" if aspect <= 1.0 + rules["rect"]["squareTol"] else "rectangle"
        cx, cy = fit["centre"]
        d["centre"] = {"x": round(cx / W, 5), "y": round(cy / H, 5)}
        d["extentRatio"] = round(float(extent), 4)
        d["sizeBand"] = band
        d["aspectRatio"] = round(aspect, 4)
        d["orientationDeg"] = round(float(fit["orientationDeg"]) % 180.0, 2)
        d["vertices"] = [{"x": round(float(x) / W, 5), "y": round(float(y) / H, 5)} for x, y in fit["vertices"]]
        d["axes"] = None
        d["sizePx"] = {"major": round(float(fit["long"]), 1), "minor": round(float(fit["short"]), 1)}
        d["confidence"] = round(float(fit["fillRatio"]) if confidence is None else float(confidence), 4)
        d["maxAngularDeviationDeg"] = round(float(fit["maxAngularDeviationDeg"]), 2)
        d["fillRatio"] = round(float(fit["fillRatio"]), 4)
        d["sideMismatch"] = round(float(fit["sideMismatch"]), 4)
        d["ellipseIoU"] = None
    else:
        a, b = float(fit["a"]), float(fit["b"])
        ratio = b / a
        d["subclass"] = "circle" if ratio >= rules["ellipse"]["circleRatio"] else "ellipse"
        cx, cy = fit["centre"]
        d["centre"] = {"x": round(cx / W, 5), "y": round(cy / H, 5)}
        d["extentRatio"] = round(float(extent), 4)
        d["sizeBand"] = band
        d["aspectRatio"] = round(a / b, 4)
        d["orientationDeg"] = round(float(fit["orientationDeg"]) % 180.0, 2)
        d["vertices"] = None
        d["axes"] = {"major": round(2 * a / W, 5), "minor": round(2 * b / W, 5)}
        d["sizePx"] = {"major": round(2 * a, 1), "minor": round(2 * b, 1)}
        iou = fit.get("iou")
        d["confidence"] = round(float(iou) if confidence is None else float(confidence), 4)
        d["maxAngularDeviationDeg"] = None
        d["fillRatio"] = None
        d["sideMismatch"] = None
        d["ellipseIoU"] = round(float(iou), 4) if iou is not None else None
    if provenance:
        d["provenance"] = provenance
    return d


def fit_candidate(region: Region, W: int, H: int, rules=RULES) -> dict:
    """One region → a verdict: {accepted, primitive, subclass, shape, reasons,
    rectScore, ellipseScore, extentRatio, sizeBand, rect, ellipse, ...}."""
    pts = np.asarray(region.pts, np.float32).reshape(-1, 2)
    v: dict = {"accepted": False, "reasons": [], "source": region.source, "refined": region.refined,
               "winner": None, "primitive": None, "subclass": None, "shape": None,
               "rectScore": None, "ellipseScore": None, "extentRatio": None, "sizeBand": None,
               "contourExtent": None, "rect": None, "ellipse": None, "nPoints": int(len(pts)),
               "prior": dict(region.prior)}
    if len(pts) < 5:
        v["reasons"].append("too few points")
        return v
    bb = polygon_bbox(pts)
    v["contourExtent"] = round(extent_ratio(bb, W, H), 4)
    if rules.get("borderPx") is not None:
        bp = float(rules["borderPx"])
        if bb[0] <= bp or bb[1] <= bp or bb[2] >= W - 1 - bp or bb[3] >= H - 1 - bp:
            v["reasons"].append("touches the frame border")
            return v
    if v["contourExtent"] < rules["preFloor"]:
        v["reasons"].append(f"pre-floor: contour extent {v['contourExtent']:.3f} < {rules['preFloor']}")
        v["extentRatio"], v["sizeBand"] = v["contourExtent"], "discard"
        return v
    r = fit_rect(pts, rules)
    e = fit_ellipse(pts, rules, W, H)
    v["rect"], v["ellipse"] = jsonable(r), jsonable(e)
    rs, es = r.get("fillRatio"), e.get("iou")
    v["rectScore"] = None if rs is None else round(float(rs), 4)
    v["ellipseScore"] = None if es is None else round(float(es), 4)
    cands = []
    if rs is not None:
        cands.append(("rectangle", float(rs)))
    if es is not None:
        cands.append(("ellipse", float(es)))
    cands.sort(key=lambda t: -t[1])
    if len(cands) == 2 and abs(cands[0][1] - cands[1][1]) <= rules["tieMargin"] and _rect_structural(r, rules):
        cands.sort(key=lambda t: 0 if t[0] == "rectangle" else 1)
    v["winner"] = cands[0][0] if cands else None
    chosen = None
    for prim, _score in cands:
        if prim == "rectangle" and r["ok"]:
            chosen = ("rectangle", r)
            break
        if prim == "ellipse" and e["ok"]:
            chosen = ("ellipse", e)
            break
    if chosen is None:
        v["reasons"].append("rect: " + ("; ".join(r["reasons"]) or "ok"))
        v["reasons"].append("ellipse: " + ("; ".join(e["reasons"]) or "ok"))
        # extent of the better-scoring fit, for the size-floor sweep
        if v["winner"] == "ellipse" and e.get("a"):
            fb = ellipse_bbox(*e["centre"], e["a"], e["b"], e["orientationDeg"])
        else:
            fb = polygon_bbox(r["box"])
        v["extentRatio"] = round(extent_ratio(fb, W, H), 4)
        v["sizeBand"] = size_band(v["extentRatio"], rules)
        return v
    prim, fit = chosen
    if prim == "rectangle":
        fb = polygon_bbox(fit["box"])
    else:
        fb = ellipse_bbox(*fit["centre"], fit["a"], fit["b"], fit["orientationDeg"])
    ext = extent_ratio(fb, W, H)
    band = size_band(ext, rules)
    v["extentRatio"], v["sizeBand"], v["primitive"] = round(ext, 4), band, prim
    if band == "discard":
        v["reasons"].append(f"size floor: extent {ext:.3f} < {rules['size']['floor']}")
        return v
    prov = {"source": region.source, "refined": bool(region.refined)}
    prov.update({k: val for k, val in region.prior.items()})
    shape = serialise_shape(prim, fit, W, H, ext, band, rules, provenance=prov)
    v["shape"], v["subclass"], v["accepted"] = shape, shape["subclass"], True
    return v


def _shape_for_identity(v: dict, W: int, H: int, rules=RULES):
    """The shape a verdict describes, accepted or not: the accepted shape, else
    one built from the winning fit's geometry (a rectangle needs its four
    vertices), else None."""
    if v.get("shape"):
        return v["shape"]
    r, e = v.get("rect"), v.get("ellipse")
    order = [v.get("winner")] + [p for p in ("rectangle", "ellipse") if p != v.get("winner")]
    for prim in order:
        try:
            if prim == "rectangle" and r and r.get("vertices") is not None and r.get("nVertices") == 4:
                return serialise_shape("rectangle", r, W, H, 0.0, "small", rules)
            if prim == "ellipse" and e and e.get("a"):
                return serialise_shape("ellipse", e, W, H, 0.0, "small", rules)
        except (KeyError, TypeError, ValueError):
            continue
    return None


def measure(gray: np.ndarray, region: Region, params: dict, W: int, H: int, rules=RULES):
    """One region → (region measured, verdict). Refinement adds precision and
    never identity: the full-resolution contour's verdict stands only if the
    shape it describes matches the proposal's own fit under the consensus
    rule (same primitive, centre within 2 % of the diagonal, IoU ≥ 0.7, aspect
    within 10 %). Otherwise the proposal is measured as traced or proposed
    (refined=False, provenance.refineRejected). Found 2026-09-12: a Kit quad
    on an enamel plate, right to 1.5 % in aspect, was replaced by a 0.93-IoU
    contour of plate-plus-frame and scored as a miss."""
    refined = refine_region(gray, region, params)
    if not refined.refined:
        return refined, fit_candidate(refined, W, H, rules)
    v_ref = fit_candidate(refined, W, H, rules)
    v_prior = fit_candidate(region, W, H, rules)
    sa, sb = _shape_for_identity(v_prior, W, H, rules), _shape_for_identity(v_ref, W, H, rules)
    if sa is None or sb is None:
        return refined, v_ref
    m = match_details(sa, sb, W, H)
    if m["ok"]:
        return refined, v_ref
    kept = Region(pts=region.pts, source=region.source, from_contour=region.from_contour, refined=False,
                  scale=region.scale, prior=dict(region.prior))
    kept.prior["refineIoU"] = refined.prior.get("refineIoU")
    kept.prior["refineMap"] = refined.prior.get("refineMap")
    kept.prior["refineRejected"] = ("different primitive" if not m["samePrimitive"] else
                                    f"aspect {m['aspectError'] * 100:.0f}%" if m["aspectError"] > MATCH["aspectTol"] else
                                    f"centre {m['offsetPctDiag']:.1f}% diag" if m["offsetPctDiag"] > MATCH["centrePctDiag"] else
                                    f"IoU {m['iou']:.2f}")
    v = fit_candidate(kept, W, H, rules)
    return kept, v


# --- converters -----------------------------------------------------------

def _xy(p):
    if isinstance(p, dict):
        return float(p["x"]), float(p["y"])
    return float(p[0]), float(p[1])


def region_from_v1(shape: dict, W: int, H: int) -> Region:
    """A Kit `DetectedShape` (JSON) → a candidate region in native px."""
    kind = shape.get("kind")
    cx_n, cy_n = _xy(shape.get("centre") or [0.5, 0.5])
    prov = {"v1Id": shape.get("id"), "v1Kind": kind, "v1Source": shape.get("source") or "detected",
            "v1Confidence": shape.get("confidence")}
    if kind == "ellipse":
        cx, cy = cx_n * W, cy_n * H
        a = float(shape["majorAxis"]) * W / 2.0
        b = float(shape["minorAxis"]) * W / 2.0
        th = math.degrees(float(shape.get("rotation") or 0.0)) % 180.0
        return Region(pts=ellipse_outline(cx, cy, a, b, th, 360), source="v1-ellipse",
                      from_contour=False, refined=False, scale=1.0, prior=prov)
    if kind == "quad" and shape.get("corners"):
        P = np.array([[x * W, y * H] for x, y in map(_xy, shape["corners"])], np.float64)
        return Region(pts=densify_polygon(P, 2.0), source="v1-quad",
                      from_contour=False, refined=False, scale=1.0, prior=prov)
    raise ValueError(f"unsupported v1 shape: kind={kind!r}")


def shape_from_label(points, primitive: str, W: int, H: int, rules=RULES, labeller=None) -> dict:
    """A person's clicks → a ground-truth shape. Rectangle: exactly 4 corners,
    taken as vertices; the §3.4 checks are RECORDED (gt.passesRules), never used
    to reject. Ellipse: ≥ 5 rim points, direct least-squares fit; the RMS
    radial residual must be ≤ 1 % of the axis or the labeller is asked to
    re-click. Shapes below the size floor are kept, banded 'discard'."""
    P = np.asarray(points, np.float64).reshape(-1, 2)
    out: dict = {"accepted": False, "reason": None, "warnings": [], "shape": None, "outline": None}
    if primitive == "rectangle":
        if len(P) != 4:
            out["reason"] = f"a rectangle needs exactly 4 corners ({len(P)} given)"
            return out
        Q = order_clockwise_from_topleft(P)
        cvq = Q.astype(np.float32).reshape(-1, 1, 2)
        area = abs(float(cv2.contourArea(cvq)))
        if area <= 1.0:
            out["reason"] = "the corners have no area"
            return out
        if not cv2.isContourConvex(cvq):
            out["reason"] = "the corners are not convex"
            return out
        angles = interior_angles(Q)
        dev = max(abs(a - 90.0) for a in angles)
        sides = [float(np.hypot(*(Q[(i + 1) % 4] - Q[i]))) for i in range(4)]
        mism = max(abs(sides[0] - sides[2]) / (max(sides[0], sides[2]) or 1.0),
                   abs(sides[1] - sides[3]) / (max(sides[1], sides[3]) or 1.0))
        rr = cv2.minAreaRect(cvq)
        box = cv2.boxPoints(rr).astype(np.float64)
        w, h = float(rr[1][0]), float(rr[1][1])
        long_, short = max(w, h), min(w, h)
        fill = area / (long_ * short) if long_ * short > 0 else 0.0
        e0, e1 = box[1] - box[0], box[2] - box[1]
        e = e0 if np.hypot(*e0) >= np.hypot(*e1) else e1
        theta = math.degrees(math.atan2(e[1], e[0])) % 180.0
        fit = {"centre": (float(rr[0][0]), float(rr[0][1])), "long": long_, "short": short,
               "aspect": long_ / short if short > 0 else float("inf"), "orientationDeg": theta,
               "fillRatio": fill, "vertices": Q, "maxAngularDeviationDeg": dev, "sideMismatch": mism}
        ext = extent_ratio(polygon_bbox(box), W, H)
        band = size_band(ext, rules)
        R = rules["rect"]
        shape = serialise_shape("rectangle", fit, W, H, ext, band, rules, confidence=1.0,
                                provenance={"source": "label", "labeller": labeller})
        shape["gt"] = {"maxAngularDeviationDeg": round(dev, 2), "sideMismatch": round(mism, 4),
                       "fillRatio": round(fill, 4), "nPoints": 4,
                       "passesRules": bool(dev <= R["angleTolDeg"] and mism <= R["sideTol"] and fill >= R["minFill"])}
        out["outline"] = np.round(Q, 1).tolist()
    elif primitive == "ellipse":
        if len(P) < 5:
            out["reason"] = f"an ellipse needs at least 5 rim points, 8–12 is better ({len(P)} given)"
            return out
        fit_p = fit_ellipse_params(P)
        if fit_p is None:
            out["reason"] = "the points do not fit an ellipse — re-click the rim"
            return out
        cx, cy, a, b, th = fit_p
        # RMS radial residual in the unit frame (fraction of the axis)
        thr = math.radians(th)
        dx, dy = P[:, 0] - cx, P[:, 1] - cy
        xr = dx * math.cos(thr) + dy * math.sin(thr)
        yr = -dx * math.sin(thr) + dy * math.cos(thr)
        rho = np.sqrt((xr / a) ** 2 + (yr / b) ** 2)
        resid = float(np.sqrt(np.mean((rho - 1.0) ** 2)))
        out["outline"] = np.round(ellipse_outline(cx, cy, a, b, th, 180), 1).tolist()
        if resid > 0.03:
            out["reason"] = f"fit residual {resid * 100:.1f}% of the axis (> 3%) — these points are not on one ellipse; drag them onto the rim"
            return out
        if resid > 0.01:
            out["warnings"].append(f"fit residual {resid * 100:.1f}% of the axis — drag points onto the rim to tighten (≤ 1% is clean)")
        fit = {"centre": (cx, cy), "a": a, "b": b, "orientationDeg": th, "iou": None}
        ext = extent_ratio(ellipse_bbox(cx, cy, a, b, th), W, H)
        band = size_band(ext, rules)
        shape = serialise_shape("ellipse", fit, W, H, ext, band, rules, confidence=1.0,
                                provenance={"source": "label", "labeller": labeller})
        shape["gt"] = {"residual": round(resid, 5), "nPoints": int(len(P)), "passesRules": True}
    else:
        out["reason"] = f"unknown primitive {primitive!r}"
        return out
    if band == "discard":
        out["warnings"].append(f"extent {ext:.3f} is below the {rules['size']['floor']} size floor — kept as "
                               "ground truth, excluded by the metrics floor")
    out["shape"], out["accepted"] = shape, True
    return out


# --- comparing serialised shapes (dedupe + metrics) -----------------------

def shape_outline_px(shape: dict, W: int, H: int, n=360) -> np.ndarray:
    if shape["primitive"] == "rectangle":
        return np.array([[v["x"] * W, v["y"] * H] for v in shape["vertices"]], np.float64)
    a = shape["axes"]["major"] * W / 2.0
    b = shape["axes"]["minor"] * W / 2.0
    return ellipse_outline(shape["centre"]["x"] * W, shape["centre"]["y"] * H, a, b,
                           shape["orientationDeg"], n).astype(np.float64)


def centre_px(shape: dict, W: int, H: int) -> tuple[float, float]:
    return shape["centre"]["x"] * W, shape["centre"]["y"] * H


def primitive_iou(sa: dict, sb: dict, W: int, H: int, long_edge=None) -> float:
    """Mask IoU of two fitted primitives rasterised at the working scale
    (long edge 1024 by default). For matching only — never for the 0.90
    acceptance IoU, which is native-resolution and local."""
    L = long_edge or MATCH["workingLongEdge"]
    s = L / max(W, H)
    A = shape_outline_px(sa, W, H) * s
    B = shape_outline_px(sb, W, H) * s
    ba, bb = polygon_bbox(A), polygon_bbox(B)
    union = (min(ba[0], bb[0]), min(ba[1], bb[1]), max(ba[2], bb[2]), max(ba[3], bb[3]))
    roi = roi_of(union, None, None, pad_frac=0.05)
    return mask_iou(raster_polygon(A, roi), raster_polygon(B, roi))


def match_details(sa: dict, sb: dict, W: int, H: int, match=MATCH) -> dict:
    """The four consensus tests between two serialised shapes."""
    same = sa["primitive"] == sb["primitive"]
    ca, cb = centre_px(sa, W, H), centre_px(sb, W, H)
    off_px = float(np.hypot(ca[0] - cb[0], ca[1] - cb[1]))
    diag = float(np.hypot(W, H))
    off_pct = 100.0 * off_px / diag
    ra, rb = float(sa["aspectRatio"]), float(sb["aspectRatio"])
    aspect_err = abs(ra - rb) / max(rb, 1e-9)
    iou = primitive_iou(sa, sb, W, H, match["workingLongEdge"]) if same else 0.0
    ok = (same and off_pct <= match["centrePctDiag"] and iou >= match["iou"] and aspect_err <= match["aspectTol"])
    return {"ok": ok, "samePrimitive": same, "offsetPx": off_px, "offsetPctDiag": off_pct,
            "iou": iou, "aspectError": aspect_err}


def shapes_match(sa: dict, sb: dict, W: int, H: int, match=MATCH) -> bool:
    return match_details(sa, sb, W, H, match)["ok"]


def dedupe_shapes(shapes: list, W: int, H: int, match=MATCH) -> list:
    """Consensus-rule dedupe within one detector's output: keep the higher
    confidence of any two shapes that would match each other."""
    kept: list = []
    for s in sorted(shapes, key=lambda s: -float(s["confidence"])):
        if any(shapes_match(s, k, W, H, match) for k in kept):
            continue
        kept.append(s)
    return kept
