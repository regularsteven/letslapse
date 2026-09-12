"""Stage 3 — consensus and metrics (brief §5).

Matches every detector run against the manual-groundtruth run with the four
consensus rules (same primitive, centre offset ≤ 2 % of the frame diagonal,
mask IoU ≥ 0.70 at a 1024-px working scale, aspect within 10 %), greedy
one-to-one by IoU. Writes work/metrics.json, work/report-generated.md and the
per-asset overlays; --docs copies the docs-worthy subset into the docs folder.
"""
from __future__ import annotations

import json
import math
import os
import shutil
import statistics
from collections import Counter, defaultdict

import cv2
import numpy as np

import overlay
import schema
from fitting import MATCH, RULES, match_details, polygon_bbox, shape_outline_px, size_band
from imaging import load_bgr

GATE = [(6, "≤ 6 → geometry alone is sufficient for photo mode; no AI ranking layer"),
        (15, "7–15 → borderline; tighten the size floor and re-measure before adding a model"),
        (10 ** 9, "> 15 → ranking is needed; proceed to §9 with a measurable baseline")]


# --- small stats helpers ---------------------------------------------------

def q(values, p):
    v = [float(x) for x in values if x is not None and not (isinstance(x, float) and math.isnan(x))]
    if not v:
        return None
    return float(np.percentile(v, p))


def med(values):
    return q(values, 50)


def fmt(x, nd=3, pct=False):
    if x is None:
        return "—"
    if pct:
        return f"{100 * x:.1f} %"
    return f"{x:.{nd}f}"


def wilson(k, n, z=1.96):
    if n == 0:
        return None
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return max(0.0, c - h), min(1.0, c + h)


def fmt_ci(k, n):
    if n == 0:
        return "—"
    lo, hi = wilson(k, n)
    return f"{100 * k / n:.0f} % [{100 * lo:.0f}–{100 * hi:.0f}] (n={n})"


# --- matching --------------------------------------------------------------

def match_asset(gt_shapes: list, det_shapes: list, W: int, H: int, match=MATCH) -> dict:
    pairs = []
    for gi, g in enumerate(gt_shapes):
        for di, d in enumerate(det_shapes):
            md = match_details(d, g, W, H, match)
            if md["ok"]:
                pairs.append((md["iou"], -md["offsetPx"], gi, di, md))
    pairs.sort(key=lambda t: (-t[0], -t[1]))
    used_g, used_d, matched = set(), set(), []
    for iou, _neg, gi, di, md in pairs:
        if gi in used_g or di in used_d:
            continue
        used_g.add(gi)
        used_d.add(di)
        matched.append({"gt": gi, "det": di, "iou": md["iou"], "offsetPx": md["offsetPx"],
                        "offsetPctDiag": md["offsetPctDiag"], "aspectError": md["aspectError"],
                        "subclassMismatch": gt_shapes[gi]["subclass"] != det_shapes[di]["subclass"],
                        "gtSubclass": gt_shapes[gi]["subclass"], "detSubclass": det_shapes[di]["subclass"],
                        "primitive": gt_shapes[gi]["primitive"], "gtBand": gt_shapes[gi]["sizeBand"]})
    # a second detection that would have matched an already-claimed GT is a duplicate FP
    dup = 0
    for iou, _neg, gi, di, md in pairs:
        if di not in used_d and gi in used_g:
            dup += 1
            used_d.add(di)   # count each duplicate once
    fn = [gi for gi in range(len(gt_shapes)) if gi not in used_g]
    fp = [di for di in range(len(det_shapes)) if di not in {m["det"] for m in matched}]
    return {"matched": matched, "fn": fn, "fp": fp, "duplicates": dup}


def evaluate_pairs(gt_shapes, det_shapes, W, H, match=MATCH):
    r = match_asset(gt_shapes, det_shapes, W, H, match)
    return {"tp": len(r["matched"]), "fp": len(r["fp"]), "fn": len(r["fn"]), "duplicates": r["duplicates"]}


# --- run selection ---------------------------------------------------------

def collect_runs(work: str, manifest: dict) -> dict:
    """{detectorId: {runKey: {'run': meta, 'assets': {assetId: asset}}}} across all result files."""
    out: dict = defaultdict(lambda: defaultdict(lambda: {"run": None, "assets": {}}))
    errors = []
    for a in manifest["assets"]:
        p = schema.results_path(work, a["assetId"])
        if not os.path.exists(p):
            continue
        doc = schema.load_results(p)
        errs = schema.validate(doc, os.path.basename(p))
        if errs:
            errors.extend(errs)
            continue
        for run in doc["runs"]:
            key = schema.key_of(run)
            slot = out[run["detectorId"]][key]
            meta = {k: run[k] for k in ("detectorId", "detectorVersion", "paramsHash", "params", "runAt")}
            if slot["run"] is None or run["runAt"] > slot["run"]["runAt"]:
                slot["run"] = meta
            for asset in run["assets"]:
                slot["assets"][asset["assetId"]] = asset
    if errors:
        raise SystemExit("results failed validation:\n  " + "\n  ".join(errors[:20]))
    return out


def pick_runs(all_runs: dict, pins: list[str]) -> dict:
    """One run per detector: the pinned paramsHash, else the most recent runAt."""
    pinned = {}
    for p in pins:
        if "=" in p:
            det, h = p.split("=", 1)
            pinned[det.strip()] = h.strip()
    chosen = {}
    for det, runs in all_runs.items():
        if det in pinned:
            keys = [k for k in runs if k.split("|")[-1].startswith(pinned[det])]
            if not keys:
                raise SystemExit(f"no run of {det} with paramsHash {pinned[det]}; have {[k.split('|')[-1] for k in runs]}")
            chosen[det] = keys[0]
        else:
            chosen[det] = max(runs, key=lambda k: runs[k]["run"]["runAt"])
    return chosen


# --- per-detector evaluation ------------------------------------------------

def apply_floor(shapes: list, floor: float) -> list:
    return [s for s in shapes if float(s["extentRatio"]) >= floor]


def evaluate_detector(det_id, run_slot, gt_slot, manifest, floor, match=MATCH):
    by_id = {a["assetId"]: a for a in manifest["assets"]}
    gt_assets = gt_slot["assets"] if gt_slot else {}
    labelled = {aid for aid, a in gt_assets.items() if (a.get("stats") or {}).get("done", True)}
    res = {"detectorId": det_id, "tp": 0, "fp": 0, "fn": 0, "fpNestedInLabel": 0, "duplicates": 0, "gtTotal": 0, "gtTotalAll": 0,
           "gtPassesRules": 0, "tpPassesRules": 0,
           "byPrimitive": defaultdict(lambda: {"tp": 0, "fp": 0, "fn": 0}),
           "byBand": defaultdict(lambda: {"tp": 0, "fn": 0}),
           "aspectErrors": [], "offsetsPct": [], "orientationErrors": [],
           "subclassConfusion": defaultdict(Counter), "subclassMismatches": 0,
           "candidates": [], "accepted": [], "durations": [], "walls": [], "acceptedUnrefined": 0, "acceptedAll": 0,
           "labelledAssets": 0, "evaluatedAssets": 0, "assetsAll": 0,
           "perAsset": {}, "matchesForOverlay": {}}
    if det_id == schema.DETECTOR_REGISTER:
        res["byProvenance"] = defaultdict(lambda: {"tp": 0, "fp": 0, "n": 0})
    for aid, asset in run_slot["assets"].items():
        a = by_id.get(aid)
        if not a:
            continue
        res["assetsAll"] += 1
        st = asset.get("stats") or {}
        det_all = asset["shapes"]
        det = apply_floor(det_all, floor)
        if det_id != schema.DETECTOR_GT:
            res["candidates"].append(st.get("candidates", len(det_all)))
            res["accepted"].append(len(det))
            res["acceptedAll"] += len(det)
            res["acceptedUnrefined"] += sum(1 for s in det if (s.get("provenance") or {}).get("refined") is False)
            if st.get("durationMs") is not None:
                res["durations"].append(st["durationMs"])
            if st.get("wallMs") is not None:
                res["walls"].append(st["wallMs"])
        if aid not in labelled:
            continue
        res["labelledAssets"] += 1
        W, H = a["frameWidth"], a["frameHeight"]
        gt_all = gt_assets[aid]["shapes"]
        gt = apply_floor(gt_all, floor)
        res["gtTotalAll"] += len(gt_all)
        res["gtTotal"] += len(gt)
        passes = [bool((g.get("gt") or {}).get("passesRules", True)) for g in gt]
        res["gtPassesRules"] += sum(passes)
        m = match_asset(gt, det, W, H, match)
        res["evaluatedAssets"] += 1
        res["tp"] += len(m["matched"])
        res["fp"] += len(m["fp"])
        res["fn"] += len(m["fn"])
        res["duplicates"] += m["duplicates"]
        # Flat policy (2026-09-12): every member of a nest is a target, so a
        # detection nested inside a labelled shape that nobody labelled is a
        # label omission, not a detector error. Counted apart so both readings
        # of precision are on the table.
        gt_boxes = [polygon_bbox(shape_outline_px(g, W, H)) for g in gt_all]
        for i in m["fp"]:
            b = polygon_bbox(shape_outline_px(det[i], W, H))
            for gb in gt_boxes:
                slack = 0.03 * max(gb[2] - gb[0], gb[3] - gb[1])
                if b[0] >= gb[0] - slack and b[1] >= gb[1] - slack and b[2] <= gb[2] + slack and b[3] <= gb[3] + slack \
                        and (b[2] - b[0]) * (b[3] - b[1]) < 0.95 * (gb[2] - gb[0]) * (gb[3] - gb[1]):
                    res["fpNestedInLabel"] += 1
                    break
        for mm in m["matched"]:
            g, d = gt[mm["gt"]], det[mm["det"]]
            res["byPrimitive"][g["primitive"]]["tp"] += 1
            res["byBand"][g["sizeBand"]]["tp"] += 1
            res["aspectErrors"].append(mm["aspectError"])
            res["offsetsPct"].append(mm["offsetPctDiag"])
            if g["subclass"] not in ("circle",):
                modulus = 90.0 if g["subclass"] == "square" else 180.0
                dd = abs(float(g["orientationDeg"]) - float(d["orientationDeg"])) % modulus
                res["orientationErrors"].append(min(dd, modulus - dd))
            res["subclassConfusion"][g["subclass"]][d["subclass"]] += 1
            if mm["subclassMismatch"]:
                res["subclassMismatches"] += 1
            if passes[mm["gt"]]:
                res["tpPassesRules"] += 1
            if det_id == schema.DETECTOR_REGISTER:
                src = ((d.get("provenance") or {}).get("v1Source")) or "detected"
                res["byProvenance"][src]["tp"] += 1
        for gi in m["fn"]:
            res["byPrimitive"][gt[gi]["primitive"]]["fn"] += 1
            res["byBand"][gt[gi]["sizeBand"]]["fn"] += 1
        for di in m["fp"]:
            res["byPrimitive"][det[di]["primitive"]]["fp"] += 1
            if det_id == schema.DETECTOR_REGISTER:
                src = ((det[di].get("provenance") or {}).get("v1Source")) or "detected"
                res["byProvenance"][src]["fp"] += 1
        if det_id == schema.DETECTOR_REGISTER:
            for d in det:
                src = ((d.get("provenance") or {}).get("v1Source")) or "detected"
                res["byProvenance"][src]["n"] += 1
        res["perAsset"][aid] = {"gt": len(gt), "tp": len(m["matched"]), "fp": len(m["fp"]), "fn": len(m["fn"]),
                                "candidates": st.get("candidates"), "accepted": len(det),
                                "durationMs": st.get("durationMs")}
        res["matchesForOverlay"][aid] = {"gt": gt, "det": det, "match": m}
    return res


def summarise(res: dict) -> dict:
    tp, fp, fn = res["tp"], res["fp"], res["fn"]
    prec = tp / (tp + fp) if tp + fp else None
    rec = tp / (tp + fn) if tp + fn else None
    f1 = (2 * prec * rec / (prec + rec)) if prec and rec else None
    out = {
        "detectorId": res["detectorId"], "labelledAssets": res["labelledAssets"], "assetsAll": res["assetsAll"],
        "tp": tp, "fp": fp, "fn": fn, "duplicates": res["duplicates"], "gtTotal": res["gtTotal"],
        "gtTotalAll": res["gtTotalAll"], "gtPassesRules": res["gtPassesRules"],
        "precision": prec, "recall": rec, "f1": f1,
        "precisionCI": wilson(tp, tp + fp), "recallCI": wilson(tp, tp + fn),
        "fpNestedInLabel": res["fpNestedInLabel"],
        "precisionExcludingNested": (tp / (tp + fp - res["fpNestedInLabel"])) if tp + fp - res["fpNestedInLabel"] else None,
        "recallOnRulePassingGT": (res["tpPassesRules"] / res["gtPassesRules"]) if res["gtPassesRules"] else None,
        "aspectError": {"median": med(res["aspectErrors"]), "p95": q(res["aspectErrors"], 95), "n": len(res["aspectErrors"])},
        "centreOffsetPctDiag": {"median": med(res["offsetsPct"]), "p95": q(res["offsetsPct"], 95),
                                "max": max(res["offsetsPct"]) if res["offsetsPct"] else None, "n": len(res["offsetsPct"]),
                                "histogram": histogram(res["offsetsPct"], 0.25, 2.0)},
        "orientationErrorDeg": {"median": med(res["orientationErrors"]), "p95": q(res["orientationErrors"], 95), "n": len(res["orientationErrors"])},
        "subclassMismatches": res["subclassMismatches"],
        "acceptedMeasuredAsProposed": {"n": res["acceptedUnrefined"], "of": res["acceptedAll"]},
        "subclassConfusion": {k: dict(v) for k, v in res["subclassConfusion"].items()},
        "byPrimitive": {k: dict(v) for k, v in res["byPrimitive"].items()},
        "byBand": {k: dict(v) for k, v in res["byBand"].items()},
        "acceptedPerImage": dist(res["accepted"]),
        "candidatesPerImage": dist(res["candidates"]),
        "durationMs": dist(res["durations"]),
        "wallMs": dist(res["walls"]) if res["walls"] else None,
    }
    if "byProvenance" in res:
        out["byProvenance"] = {k: dict(v) for k, v in res["byProvenance"].items()}
    return out


def dist(values):
    v = [float(x) for x in values if x is not None]
    if not v:
        return {"n": 0, "median": None, "p25": None, "p75": None, "max": None, "mean": None}
    return {"n": len(v), "median": float(np.median(v)), "p25": float(np.percentile(v, 25)),
            "p75": float(np.percentile(v, 75)), "max": max(v), "mean": float(np.mean(v))}


def histogram(values, step, top):
    edges = np.arange(0.0, top + step, step)
    counts = [0] * len(edges)
    for v in values:
        i = min(int(v // step), len(edges) - 1)
        counts[i] += 1
    return [{"from": round(float(e), 2), "count": c} for e, c in zip(edges, counts)]


# --- size-floor sweep from the candidate log ------------------------------

def floor_sweep(work: str, det_id: str, key: str, floors=(0.10, 0.15, 0.20, 0.25)) -> dict:
    """Accepted shapes per image at alternative size floors, recomputed from the
    candidate log's extentRatio column without re-running the detector. A row
    counts if it was accepted at the run's floor (or rejected ONLY by the size
    floor) and its fitted extent clears the candidate floor."""
    import detect_opencv
    path = detect_opencv.log_path_for(work, det_id, key)
    if not os.path.exists(path):
        return {}
    per_asset = defaultdict(list)
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            r = json.loads(line)
            only_floor = (not r.get("accepted")) and r.get("reasons") and all("size floor" in x for x in r["reasons"])
            if (r.get("accepted") or only_floor) and r.get("extentRatio") is not None and not r.get("dedupedAway"):
                per_asset[r["assetId"]].append(float(r["extentRatio"]))
    out = {}
    for fl in floors:
        counts = [sum(1 for e in exts if e >= fl) for exts in per_asset.values()]
        out[f"{fl:.2f}"] = dist(counts)
    return out


# --- report ----------------------------------------------------------------

def gate_line(det_id, key, median_accepted, validated: bool):
    if median_accepted is None:
        return f"{det_id} {key.split('|')[-1]}: no accepted-per-image figure yet"
    if not validated:
        return (f"NOT YET DECIDABLE — {det_id} {key.split('|')[-1]} has a median of {median_accepted:.1f} accepted "
                f"candidates/image, but the gate is read only once the reference agrees with ground truth (Phase 3)")
    for limit, text in GATE:
        if median_accepted <= limit:
            return f"{det_id} {key.split('|')[-1]}: median accepted candidates/image = {median_accepted:.1f} → {text}"
    return ""


def write_report(path, manifest, chosen, all_runs, summaries, sweeps, floor, gate):
    L = []
    L.append("# Shape benchmark — generated report")
    L.append("")
    L.append(f"Generated {schema.now_iso()} from `{manifest['root']}` (tag \"{manifest['tag']}\", "
             f"{len(manifest['assets'])} assets, label set {len(manifest['labelSet'])}). "
             f"Size floor applied to ground truth and detections: {floor:.2f}. "
             f"Consensus rule: same primitive, centre offset ≤ {MATCH['centrePctDiag']} % of the diagonal, "
             f"mask IoU ≥ {MATCH['iou']} at a {MATCH['workingLongEdge']}-px working scale, aspect within {int(MATCH['aspectTol'] * 100)} %; "
             "greedy one-to-one by IoU (no Hungarian — at most a dozen detections against a handful of labels per image).")
    L.append("")
    L.append("## Decision gate (brief §8)")
    L.append("")
    L.append(f"**{gate}**")
    L.append("")
    L.append("## Runs")
    L.append("")
    L.append("| detector | key | runAt | assets | pinned |")
    L.append("|---|---|---|---|---|")
    for det, runs in sorted(all_runs.items()):
        for key, slot in sorted(runs.items(), key=lambda kv: kv[1]["run"]["runAt"]):
            L.append(f"| {det} | `{key.split('|')[1]}/{key.split('|')[2]}` | {slot['run']['runAt']} | {len(slot['assets'])} | "
                     f"{'✓' if chosen.get(det) == key else ''} |")
    L.append("")
    L.append("## Detectors vs ground truth")
    L.append("")
    L.append("| detector | labelled | GT (≥ floor) | TP | FP | FN | precision | recall | F1 | recall on rule-passing GT | aspect err med / p95 | centre offset med / p95 (% diag) | orientation err med (°) | subclass mismatches | measured as proposed | FP nested in a label (precision without them) | accepted/img med (p25–p75, max) | candidates/img med | ms/img med |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for det, s in summaries.items():
        ae, co, oe = s["aspectError"], s["centreOffsetPctDiag"], s["orientationErrorDeg"]
        acc, cand, dur = s["acceptedPerImage"], s["candidatesPerImage"], s["durationMs"]
        p95_note = " (n<20)" if ae["n"] and ae["n"] < 20 else ""
        L.append(f"| {det} | {s['labelledAssets']} | {s['gtTotal']} | {s['tp']} | {s['fp']} | {s['fn']} | "
                 f"{fmt_ci(s['tp'], s['tp'] + s['fp'])} | {fmt_ci(s['tp'], s['tp'] + s['fn'])} | {fmt(s['f1'], 2)} | "
                 f"{fmt(s['recallOnRulePassingGT'], pct=True)} | {fmt(ae['median'], pct=True)} / {fmt(ae['p95'], pct=True)}{p95_note} | "
                 f"{fmt(co['median'], 2)} / {fmt(co['p95'], 2)} | {fmt(oe['median'], 1)} (n={oe['n']}) | {s['subclassMismatches']} | "
                 f"{s['acceptedMeasuredAsProposed']['n']} of {s['acceptedMeasuredAsProposed']['of']} | "
                 f"{s['fpNestedInLabel']} ({fmt(s['precisionExcludingNested'], pct=True)}) | "
                 f"{fmt(acc['median'], 1)} ({fmt(acc['p25'], 0)}–{fmt(acc['p75'], 0)}, {fmt(acc['max'], 0)}) | "
                 f"{fmt(cand['median'], 1)} | {fmt(dur['median'], 0)} |")
    L.append("")
    L.append("Precision and recall are over the labelled assets only; accepted / candidates / runtime are over every asset the run covers. "
             "Brackets are Wilson 95 % intervals. Duplicates (a second detection on an already-matched label) count as FP.")
    L.append("")
    for det, s in summaries.items():
        L.append(f"### {det}")
        L.append("")
        L.append("| primitive | TP | FP | FN | recall |")
        L.append("|---|---|---|---|---|")
        for prim in ("ellipse", "rectangle"):
            b = s["byPrimitive"].get(prim, {"tp": 0, "fp": 0, "fn": 0})
            L.append(f"| {prim} | {b['tp']} | {b['fp']} | {b['fn']} | {fmt_ci(b['tp'], b['tp'] + b['fn'])} |")
        L.append("")
        L.append("| GT size band | TP | FN | recall |")
        L.append("|---|---|---|---|")
        for band in ("small", "medium", "large"):
            b = s["byBand"].get(band, {"tp": 0, "fn": 0})
            L.append(f"| {band} | {b['tp']} | {b['fn']} | {fmt_ci(b['tp'], b['tp'] + b['fn'])} |")
        L.append("")
        if s["subclassConfusion"]:
            L.append("Subclass confusion on matched pairs (rows = ground truth, columns = detector):")
            L.append("")
            cols = ["circle", "ellipse", "square", "rectangle"]
            L.append("| GT \\ det | " + " | ".join(cols) + " |")
            L.append("|---|" + "---|" * len(cols))
            for row in cols:
                if row in s["subclassConfusion"]:
                    L.append(f"| {row} | " + " | ".join(str(s["subclassConfusion"][row].get(c, 0)) for c in cols) + " |")
            L.append("")
        if s.get("byProvenance"):
            L.append("By v1 provenance (`captured` = left standing by the shooter on the viewfinder, `detected` = the file pass / Find shapes):")
            L.append("")
            L.append("| source | shapes ≥ floor | TP | FP |")
            L.append("|---|---|---|---|")
            for src, b in sorted(s["byProvenance"].items()):
                L.append(f"| {src} | {b['n']} | {b['tp']} | {b['fp']} |")
            L.append("")
        h = s["centreOffsetPctDiag"]["histogram"]
        if s["centreOffsetPctDiag"]["n"]:
            L.append("Centre offset histogram (% of diagonal, 0.25 % bins): " +
                     ", ".join(f"{b['from']:.2f}+: {b['count']}" for b in h if b["count"]) )
            L.append("")
        if det in sweeps and sweeps[det]:
            L.append("Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):")
            L.append("")
            L.append("| floor | median | p25–p75 | max |")
            L.append("|---|---|---|---|")
            for fl, d in sweeps[det].items():
                L.append(f"| {fl} | {fmt(d['median'], 1)} | {fmt(d['p25'], 0)}–{fmt(d['p75'], 0)} | {fmt(d['max'], 0)} |")
            L.append("")
    L.append("## Per asset")
    L.append("")
    dets = list(summaries.keys())
    L.append("| asset | name | GT | " + " | ".join(f"{d} TP/FP/FN (acc, cand)" for d in dets) + " |")
    L.append("|---|---|---|" + "---|" * len(dets))
    by_id = {a["assetId"]: a for a in manifest["assets"]}
    labelled_ids = sorted({aid for s in summaries.values() for aid in s.get("_perAsset", {})})
    for aid in labelled_ids:
        a = by_id[aid]
        cells = []
        gt_n = None
        for d in dets:
            pa = summaries[d].get("_perAsset", {}).get(aid)
            if pa:
                gt_n = pa["gt"]
                cells.append(f"{pa['tp']}/{pa['fp']}/{pa['fn']} ({pa['accepted']}, {pa['candidates'] if pa['candidates'] is not None else '—'})")
            else:
                cells.append("—")
        L.append(f"| {aid[:8]} | {(a.get('name') or '')[:24]} | {gt_n if gt_n is not None else '—'} | " + " | ".join(cells) + " |")
    L.append("")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(L))


# --- overlays --------------------------------------------------------------

def label_fn(prefix):
    return lambda s: f"{prefix} {s['subclass'][:4]} e{s['extentRatio']:.2f}"


def write_overlays(work, manifest, results, docs_dir=None):
    by_id = {a["assetId"]: a for a in manifest["assets"]}
    comb_dir = os.path.join(work, "overlays", "combined")
    os.makedirs(comb_dir, exist_ok=True)
    per_det_dir = {}
    for det in results:
        safe = "".join(ch if (ch.isalnum() or ch in "-._") else ("plus" if ch == "+" else "-") for ch in det).strip("-")
        per_det_dir[det] = os.path.join(work, "overlays", f"{safe}.vs-gt")
        os.makedirs(per_det_dir[det], exist_ok=True)
    labelled = set()
    for det, res in results.items():
        labelled |= set(res["matchesForOverlay"].keys())
    for aid in sorted(labelled):
        a = by_id[aid]
        W, H = a["frameWidth"], a["frameHeight"]
        bgr = load_bgr(os.path.join(work, a["image"]))
        gt_layer = None
        combined_layers = []
        for det, res in results.items():
            mo = res["matchesForOverlay"].get(aid)
            if not mo:
                continue
            gt, det_s, m = mo["gt"], mo["det"], mo["match"]
            matched_d = {mm["det"] for mm in m["matched"]}
            matched_g = {mm["gt"] for mm in m["matched"]}
            layers = [("gt", gt, label_fn("GT")),
                      ("matched", [det_s[i] for i in sorted(matched_d)], label_fn("TP")),
                      ("fp", [det_s[i] for i in m["fp"]], label_fn("FP")),
                      ("fn", [gt[i] for i in m["fn"]], label_fn("FN"))]
            img = overlay.render(bgr, W, H, layers, f"{aid[:8]} {det} vs GT")
            cv2.imwrite(os.path.join(per_det_dir[det], f"{aid}.jpg"), img, [cv2.IMWRITE_JPEG_QUALITY, 85])
            if gt_layer is None:
                gt_layer = ("gt", gt, label_fn("GT"))
            combined_layers.append(("matched" if det.startswith(schema.DETECTOR_OPENCV) else "fp", det_s, label_fn(det[:6])))
        if gt_layer is not None:
            img = overlay.render(bgr, W, H, [gt_layer] + combined_layers, f"{aid[:8]} GT (green) + detectors")
            cv2.imwrite(os.path.join(comb_dir, f"{aid}.jpg"), img, [cv2.IMWRITE_JPEG_QUALITY, 85])
            if docs_dir:
                small = cv2.resize(img, None, fx=768 / max(img.shape[:2]), fy=768 / max(img.shape[:2]), interpolation=cv2.INTER_AREA)
                os.makedirs(os.path.join(docs_dir, "review"), exist_ok=True)
                cv2.imwrite(os.path.join(docs_dir, "review", f"{aid[:8]}.jpg"), small, [cv2.IMWRITE_JPEG_QUALITY, 80])


# --- entry -----------------------------------------------------------------

def run_label(det: str, key: str, runs: dict, all_runs_mode: bool) -> str:
    if not all_runs_mode:
        return det
    params = (runs[key]["run"].get("params") or {}).get("detector") or {}
    tag = params.get("profile") or params.get("generation") or ("dedupe " + str((params.get("shapeDedupe") or {}).get("iou")) if "shapeDedupe" in params else key.split("|")[-1])
    return f"{det} · {tag}"


def run(args) -> int:
    work = args.work
    with open(os.path.join(work, "manifest.json"), "r", encoding="utf-8") as f:
        manifest = json.load(f)
    all_runs = collect_runs(work, manifest)
    if not all_runs:
        raise SystemExit("no results yet — run detect / vision / label first")
    chosen = pick_runs(all_runs, args.run)
    floor = args.floor if args.floor is not None else RULES["size"]["floor"]
    gt_key = chosen.get(schema.DETECTOR_GT)
    gt_slot = all_runs[schema.DETECTOR_GT][gt_key] if gt_key else None
    if gt_slot is None:
        print("no manual-groundtruth run yet — reporting candidates/runtime only")
    results, summaries, sweeps = {}, {}, {}
    all_mode = bool(getattr(args, "all_runs", False))
    todo = []
    for det in all_runs:
        if det == schema.DETECTOR_GT:
            continue
        keys = sorted(all_runs[det], key=lambda k: all_runs[det][k]["run"]["runAt"]) if all_mode else [chosen[det]]
        for key in keys:
            todo.append((det, key))
    for det, key in todo:
        label = run_label(det, key, all_runs[det], all_mode)
        if label in summaries:   # the same profile from a different binary or parameter set
            label += " · " + key.split("|")[-1][:6]
        res = evaluate_detector(det, all_runs[det][key], gt_slot, manifest, floor)
        results[label] = res
        s = summarise(res)
        s["runKey"] = key
        s["_perAsset"] = res["perAsset"]
        summaries[label] = s
        sweeps[label] = floor_sweep(work, det, key)
    # the gate is judged on opencv-reference's pinned/latest run once it has been validated (Phase 3)
    gate_det = schema.DETECTOR_OPENCV if schema.DETECTOR_OPENCV in chosen else None
    gate_label = run_label(gate_det, chosen[gate_det], all_runs[gate_det], all_mode) if gate_det else None
    if gate_label and gate_label not in summaries:
        gate_label = next((l for l in summaries if summaries[l]["runKey"] == chosen[gate_det]), None)
    validated = bool(gate_label and summaries[gate_label]["labelledAssets"] > 0)
    gate = gate_line(gate_det, chosen.get(gate_det, "|||"), summaries[gate_label]["acceptedPerImage"]["median"], validated) if gate_label else "no detector run"
    print()
    print("== Decision gate ==")
    print(gate)
    print()
    print(f"{'detector':24s} {'lab':>3s} {'GT':>3s} {'TP':>3s} {'FP':>3s} {'FN':>3s}  {'prec':>6s} {'rec':>6s}  {'acc/img':>7s} {'cand/img':>8s} {'ms/img':>6s}")
    for det, s in summaries.items():
        print(f"{det:24s} {s['labelledAssets']:3d} {s['gtTotal']:3d} {s['tp']:3d} {s['fp']:3d} {s['fn']:3d}  "
              f"{fmt(s['precision'], 2):>6s} {fmt(s['recall'], 2):>6s}  {fmt(s['acceptedPerImage']['median'], 1):>7s} "
              f"{fmt(s['candidatesPerImage']['median'], 1):>8s} {fmt(s['durationMs']['median'], 0):>6s}")
    out = {"generatedAt": schema.now_iso(), "floor": floor, "match": MATCH, "rules": RULES, "chosen": chosen,
           "gate": gate, "detectors": {d: {k: v for k, v in s.items() if not k.startswith("_")} for d, s in summaries.items()},
           "floorSweeps": sweeps,
           "runs": {det: {k: {"runAt": v["run"]["runAt"], "assets": len(v["assets"]), "params": v["run"]["params"]}
                          for k, v in runs.items()} for det, runs in all_runs.items()}}
    with open(os.path.join(work, "metrics.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False, default=float)
    rep = os.path.join(work, "report-generated.md")
    write_report(rep, manifest, chosen, all_runs, summaries, sweeps, floor, gate)
    docs = os.path.abspath(args.docs) if args.docs else None
    if gt_slot is not None:
        write_overlays(work, manifest, results, docs)
    print(f"\nwrote {rep} and metrics.json")
    if docs:
        os.makedirs(docs, exist_ok=True)
        shutil.copyfile(rep, os.path.join(docs, "report-generated.md"))
        shutil.copyfile(os.path.join(work, "metrics.json"), os.path.join(docs, "metrics.json"))
        print(f"copied report-generated.md, metrics.json and review overlays into {docs}")
    return 0
