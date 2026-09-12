#!/usr/bin/env python3
"""Shape-detection benchmark rig (docs/shape-benchmark/brief.md).

Usage (from LetsLapse/):
  tools/.venv/bin/python tools/shapebench/shapebench.py export  --root /Volumes/letslapse/Projects
  tools/.venv/bin/python tools/shapebench/shapebench.py detect            # opencv-reference over the corpus
  tools/.venv/bin/python tools/shapebench/shapebench.py label             # opens the labelling page
  tools/.venv/bin/python tools/shapebench/shapebench.py vision            # lapse shapes --json → schema v2
  tools/.venv/bin/python tools/shapebench/shapebench.py metrics [--docs docs/shape-benchmark]
  tools/.venv/bin/python tools/shapebench/shapebench.py selftest [--lapse PATH]

Everything lands under --work (default tools/shapebench/work/, git-ignored).
The library under --root is only ever read.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import http.server
import json
import math
import os
import random
import shlex
import shutil
import subprocess
import sys
import threading
import time
import webbrowser

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import detect_opencv  # noqa: E402
import overlay  # noqa: E402
import schema  # noqa: E402
from fitting import (RULES, Region, densify_polygon, ellipse_outline, fit_candidate, match_details,  # noqa: E402
                     measure, region_from_v1, shape_from_label, dedupe_shapes)
from imaging import DimsMismatch, check_dims, dims_of, is_raw, load_bgr, load_gray  # noqa: E402

DEFAULT_WORK = os.path.join(HERE, "work")
DEFAULT_LAPSE = os.path.normpath(os.path.join(HERE, "..", "..", "Kit", ".build", "release", "lapse"))
APPLE_EPOCH = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
IMAGE_EXTS = (".jpg", ".jpeg", ".heic", ".png", ".dng")


def load_manifest(work: str) -> dict:
    p = os.path.join(work, "manifest.json")
    if not os.path.exists(p):
        sys.exit(f"no manifest at {p} — run `export` first")
    with open(p, "r", encoding="utf-8") as f:
        return json.load(f)


def apple_date(seconds) -> str | None:
    if seconds is None:
        return None
    return (APPLE_EPOCH + datetime.timedelta(seconds=float(seconds))).replace(microsecond=0) \
        .isoformat().replace("+00:00", "Z")


# ---------------------------------------------------------------------------
# export
# ---------------------------------------------------------------------------

def cmd_export(args) -> int:
    root = os.path.abspath(args.root)
    lib_path = os.path.join(root, "library.json")
    if not os.path.exists(lib_path):
        sys.exit(f"{lib_path} not found — --root must be the Projects/ folder")
    with open(lib_path, "r", encoding="utf-8") as f:
        library = json.load(f)
    captures = library.get("captures", [])
    tagged = [c for c in captures if args.tag in (c.get("sceneTags") or [])]
    not_photo = [c for c in tagged if c.get("mode") != "Photo"]
    chosen = [c for c in tagged if c.get("mode") == "Photo"]
    chosen.sort(key=lambda c: (c.get("createdAt") or 0, c["id"]))
    work = args.work
    for sub in ("images", "register", "results", "vision-raw", "labels", "logs", "overlays"):
        os.makedirs(os.path.join(work, sub), exist_ok=True)
    assets, n_jpg, n_raw, n_reg, n_log = [], 0, 0, 0, 0
    for c in chosen:
        aid = str(c["id"]).upper()
        folder = os.path.join(root, aid)
        rel = None
        reg_path = os.path.join(folder, "shapes.json")
        if os.path.exists(reg_path):
            try:
                with open(reg_path, "r", encoding="utf-8") as f:
                    rel = (json.load(f).get("representative") or {}).get("relativePath")
            except Exception:  # noqa: BLE001
                rel = None
        if not rel:
            names = c.get("sourceFileNames") or []
            rel = names[0] if names else None
        if not rel:
            src_dir = os.path.join(folder, "source")
            frames = sorted(n for n in os.listdir(src_dir) if n.startswith("frame-")
                            and os.path.splitext(n)[1].lower() in IMAGE_EXTS) if os.path.isdir(src_dir) else []
            rel = os.path.join("source", frames[0]) if frames else None
        if not rel or not os.path.exists(os.path.join(folder, rel)):
            print(f"  WARN {aid[:8]}: no source picture ({rel}) — skipped")
            continue
        src = os.path.join(folder, rel)
        ext = os.path.splitext(src)[1].lower()
        if is_raw(src):
            out_name = f"{aid}.png"
            fmt = "dng"
        else:
            out_name = f"{aid}{ext}"
            fmt = ext.lstrip(".")
        dst = os.path.join(work, "images", out_name)
        if is_raw(src):
            if not os.path.exists(dst) or args.force:
                t0 = time.perf_counter()
                bgr = load_bgr(src)
                cv2.imwrite(dst, bgr, [cv2.IMWRITE_PNG_COMPRESSION, 3])
                print(f"  {aid[:8]}: DNG → PNG {dims_of(bgr)[0]}x{dims_of(bgr)[1]} in {time.perf_counter() - t0:.1f} s")
            n_raw += 1
        else:
            if not (os.path.exists(dst) and os.path.getsize(dst) == os.path.getsize(src)) or args.force:
                shutil.copyfile(src, dst)
            n_jpg += 1
        bgr = load_bgr(dst)
        W, H = dims_of(bgr)
        sw, sh = c.get("sourceWidth"), c.get("sourceHeight")
        if sw and sh and (int(sw), int(sh)) != (W, H):
            sys.exit(f"{aid}: exported {W}x{H} but library says {sw}x{sh} — orientation mismatch, aborting")
        reg_dir = os.path.join(work, "register", aid)
        has_reg = os.path.exists(reg_path)
        has_log = os.path.exists(os.path.join(folder, "source", "capture_log.json"))
        if has_reg or has_log:
            os.makedirs(reg_dir, exist_ok=True)
        if has_reg:
            shutil.copyfile(reg_path, os.path.join(reg_dir, "shapes.json"))
            n_reg += 1
        if has_log:
            shutil.copyfile(os.path.join(folder, "source", "capture_log.json"), os.path.join(reg_dir, "capture_log.json"))
            n_log += 1
        assets.append({
            "assetId": aid, "projectId": aid, "name": c.get("name") or c.get("originalName"),
            "createdAt": apple_date(c.get("createdAt")), "sourceRelativePath": rel, "sourceFormat": fmt,
            "image": f"images/{out_name}", "frameWidth": W, "frameHeight": H,
            "bytes": os.path.getsize(src), "hasRegister": has_reg, "hasCaptureLog": has_log,
            "tags": c.get("sceneTags") or [],
        })
    ids = sorted(a["assetId"] for a in assets)
    if args.label_all or args.label_set >= len(ids):
        label_set = ids
    else:
        label_set = sorted(random.Random(args.seed).sample(ids, args.label_set))
    for a in assets:
        a["inLabelSet"] = a["assetId"] in label_set
    manifest = {"exportedAt": schema.now_iso(), "root": root, "tag": args.tag, "seed": args.seed,
                "labelSet": label_set, "assets": assets}
    with open(os.path.join(work, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    print(f"{len(assets)} assets exported ({n_jpg} jpg, {n_raw} dng→png) · {n_reg} registers · "
          f"{n_log} capture logs · label set {len(label_set)}"
          + (f" · {len(not_photo)} tagged non-Photo projects excluded" if not_photo else ""))
    print(f"manifest: {os.path.join(work, 'manifest.json')}")
    return 0


# ---------------------------------------------------------------------------
# vision (apple-vision + apple-vision-register)
# ---------------------------------------------------------------------------

VISION_VERSION = "1"


def dedupe_rule(params: dict) -> dict:
    from fitting import MATCH
    dd = dict(MATCH); dd["iou"] = float((params.get("shapeDedupe") or {}).get("iou", MATCH["iou"]))
    return dd


def _sha_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:12]


def _v1_rows_and_shapes(gray, v1_shapes, W, H, params, extra_prov):
    rows, accepted = [], []
    for s in v1_shapes:
        try:
            region = region_from_v1(s, W, H)
        except (ValueError, KeyError) as ex:
            rows.append({"source": "v1-?", "accepted": False, "reasons": [f"unconvertible: {ex}"]})
            continue
        region.prior.update(extra_prov)
        region, v = measure(gray, region, params, W, H, RULES)
        row = {k: v[k] for k in ("source", "refined", "nPoints", "contourExtent", "extentRatio", "sizeBand",
                                 "accepted", "primitive", "subclass", "winner", "rectScore", "ellipseScore",
                                 "reasons", "prior")}
        row["rect"], row["ellipse"] = detect_opencv._slim(v["rect"]), detect_opencv._slim(v["ellipse"])
        row["outline"] = detect_opencv._thin_outline(region.pts)
        row["v1"] = {"kind": s.get("kind"), "source": s.get("source") or "detected",
                     "confidence": s.get("confidence"), "id": s.get("id")}
        if v["accepted"]:
            row["shapeId"] = v["shape"]["shapeId"]
            accepted.append(v["shape"])
        rows.append(row)
    return rows, accepted


def cmd_vision(args) -> int:
    work = args.work
    manifest = load_manifest(work)
    lapse = os.path.abspath(args.lapse)
    if not os.path.exists(lapse):
        sys.exit(f"lapse not found at {lapse} — build with `cd Kit && swift build -c release`")
    overrides = None
    if getattr(args, "params", None):
        with open(args.params, "r", encoding="utf-8") as f:
            overrides = json.load(f)
    params = detect_opencv.merged_params(overrides)
    refine_params = {k: params[k] for k in ("blur", "canny", "adaptive", "close", "contours", "refine", "shapeDedupe")}
    lapse_sha = _sha_of(lapse)
    flags = shlex.split(args.flags or "")
    slug = "default" if not flags else "".join(ch if ch.isalnum() else "-" for ch in " ".join(flags)).strip("-")
    assets = detect_opencv.select_assets(manifest, args)
    os.makedirs(os.path.join(work, "vision-raw"), exist_ok=True)
    ovl_v = os.path.join(work, "overlays", schema.DETECTOR_VISION + ("" if slug == "default" else "." + slug))
    ovl_r = os.path.join(work, "overlays", schema.DETECTOR_REGISTER)
    os.makedirs(ovl_v, exist_ok=True)
    os.makedirs(ovl_r, exist_ok=True)
    done = skipped = failed = reg_done = 0
    for a in assets:
        aid = a["assetId"]
        img_path = os.path.join(work, a["image"])
        rpath = schema.results_path(work, aid)
        doc = schema.load_results(rpath, a["projectId"])
        gray = None
        # --- apple-vision: run lapse ---
        raw_path = os.path.join(work, "vision-raw", f"{aid}.{slug}.{lapse_sha[:8]}.json")
        need_run = True
        if os.path.exists(raw_path) and not args.force:
            with open(raw_path, "r", encoding="utf-8") as f:
                d = json.load(f)
            if d.get("_lapseSha256") == lapse_sha:
                need_run = False
        wall_ms = None
        if need_run:
            t0 = time.perf_counter()
            proc = subprocess.run([lapse, "shapes", img_path, "--json", *flags], capture_output=True, text=True, timeout=600)
            wall_ms = int(round((time.perf_counter() - t0) * 1000))
            if proc.returncode != 0 or not proc.stdout.strip():
                failed += 1
                print(f"  FAIL {aid[:8]}: lapse rc={proc.returncode} {proc.stderr.strip()[:200]}")
                continue
            d = json.loads(proc.stdout)
            d["_lapseSha256"] = lapse_sha
            d["_wallMs"] = wall_ms
            with open(raw_path, "w", encoding="utf-8") as f:
                json.dump(d, f, indent=1, sort_keys=True)
        else:
            wall_ms = d.get("_wallMs")
        W, H = a["frameWidth"], a["frameHeight"]
        if (int(d.get("width", 0)), int(d.get("height", 0))) != (W, H):
            failed += 1
            print(f"  FAIL {aid[:8]}: lapse reports {d.get('width')}x{d.get('height')} but the export is {W}x{H}")
            continue
        run_params = {"detector": {"profile": d.get("profile"), "flags": flags, "lapseSha256": lapse_sha,
                                   "kitDetectorVersion": 1, "refine": refine_params}, "rules": RULES}
        key = schema.run_key(schema.DETECTOR_VISION, VISION_VERSION, schema.params_hash(run_params))
        diag = d.get("diagnostics") or {}
        if schema.has_run(doc, key) and not args.force:
            skipped += 1
            print(f"  skip {aid[:8]}  (already ran apple-vision {slug} {key.split('|')[-1]})")
        else:
            gray = load_gray(img_path)
            try:
                check_dims(gray, W, H, aid[:8])
            except DimsMismatch as ex:
                failed += 1
                print(f"  FAIL {ex}")
                continue
            v1_shapes = d.get("shapes") or []
            rows, accepted = _v1_rows_and_shapes(gray, v1_shapes, W, H, params, {})
            shapes = dedupe_shapes(accepted, W, H, dedupe_rule(params))
            kept = {s["shapeId"] for s in shapes}
            for r in rows:
                if r.get("shapeId") and r["shapeId"] not in kept:
                    r["dedupedAway"] = True
            refusals = diag.get("refusals") or []
            offered = [diag.get(k) for k in ("quadsOffered", "ellipseFits", "rimPeaks")]
            # everything the Kit's passes put forward before its own gates; the
            # refusal list is trimmed to 24 by the Kit, so it is not a count
            candidates = sum(int(x) for x in offered if x is not None) if any(x is not None for x in offered) \
                else len(v1_shapes) + len(refusals)
            stats = {"candidates": candidates, "v1Shapes": len(v1_shapes),
                     "refusals": len(refusals), "accepted": len(shapes),
                     "durationMs": int(diag.get("milliseconds") or 0), "wallMs": wall_ms,
                     "quadsOffered": diag.get("quadsOffered"), "quadsKept": diag.get("quadsKept"),
                     "ellipsesKept": diag.get("ellipsesKept"), "rimsKept": diag.get("rimsKept")}
            run = schema.new_run(schema.DETECTOR_VISION, VISION_VERSION, run_params, stats["durationMs"])
            run["assets"] = [schema.new_asset(aid, W, H, shapes, stats)]
            status = schema.upsert_run(doc, run, force=args.force)
            schema.save_results(rpath, doc)
            detect_opencv.write_rows(detect_opencv.log_path_for(work, schema.DETECTOR_VISION, key), aid, rows, key)
            bgr = load_bgr(img_path)
            cv2.imwrite(os.path.join(ovl_v, f"{aid}.jpg"),
                        detect_opencv.overlay_for(bgr, W, H, shapes, rows, f"{aid[:8]} apple-vision {slug}"),
                        [cv2.IMWRITE_JPEG_QUALITY, 85])
            done += 1
            print(f"  {status:8s} {aid[:8]}  v1 shapes {len(v1_shapes):2d} + refusals {len(refusals):2d}"
                  f"  → accepted {len(shapes):2d}  {stats['durationMs']:5d} ms (wall {wall_ms or 0})")
        # --- apple-vision-register: the library's own shapes.json ---
        if args.skip_register:
            continue
        reg_path = os.path.join(work, "register", aid, "shapes.json")
        if not os.path.exists(reg_path):
            continue
        with open(reg_path, "r", encoding="utf-8") as f:
            reg = json.load(f)
        reg_params = {"detector": {"source": "library shapes.json", "refine": refine_params}, "rules": RULES}
        reg_version = str(reg.get("detectorVersion", 0))
        rkey = schema.run_key(schema.DETECTOR_REGISTER, reg_version, schema.params_hash(reg_params))
        if schema.has_run(doc, rkey) and not args.force:
            continue
        if gray is None:
            gray = load_gray(img_path)
        v1_shapes = reg.get("shapes") or []
        rows, accepted = _v1_rows_and_shapes(gray, v1_shapes, W, H, params,
                                             {"registerAnalysedAt": reg.get("analysedAt")})
        shapes = dedupe_shapes(accepted, W, H, dedupe_rule(params))
        kept = {s["shapeId"] for s in shapes}
        for r in rows:
            if r.get("shapeId") and r["shapeId"] not in kept:
                r["dedupedAway"] = True
        srcs = {}
        for s in v1_shapes:
            srcs[s.get("source") or "detected"] = srcs.get(s.get("source") or "detected", 0) + 1
        stats = {"candidates": len(v1_shapes), "accepted": len(shapes), "durationMs": 0,
                 "v1Sources": srcs, "registerAnalysedAt": reg.get("analysedAt"),
                 "registerFov": (reg.get("representative") or {}).get("horizontalFieldOfView")}
        run = schema.new_run(schema.DETECTOR_REGISTER, reg_version, reg_params, 0)
        run["assets"] = [schema.new_asset(aid, W, H, shapes, stats)]
        schema.upsert_run(doc, run, force=args.force)
        schema.save_results(rpath, doc)
        detect_opencv.write_rows(detect_opencv.log_path_for(work, schema.DETECTOR_REGISTER, rkey), aid, rows, rkey)
        bgr = load_bgr(img_path)
        cv2.imwrite(os.path.join(ovl_r, f"{aid}.jpg"),
                    detect_opencv.overlay_for(bgr, W, H, shapes, rows, f"{aid[:8]} apple-vision-register"),
                    [cv2.IMWRITE_JPEG_QUALITY, 85])
        reg_done += 1
        print(f"           {aid[:8]}  register {len(v1_shapes):2d} shapes {srcs} → accepted {len(shapes)}")
    print(f"apple-vision [{slug}]: done {done}, skipped {skipped}, failed {failed} · register blocks written {reg_done}")
    return 0 if failed == 0 else 1


# ---------------------------------------------------------------------------
# label (manual-groundtruth)
# ---------------------------------------------------------------------------

GT_VERSION = "1"


def gt_params(labeller: str) -> dict:
    return {"labeller": labeller, "tool": "label.html/1", "rules": RULES}


def write_gt(work: str, manifest_asset: dict, labels: dict, labeller: str) -> str:
    aid = manifest_asset["assetId"]
    os.makedirs(os.path.join(work, "labels"), exist_ok=True)
    with open(os.path.join(work, "labels", f"{aid}.json"), "w", encoding="utf-8") as f:
        json.dump(labels, f, indent=2, ensure_ascii=False)
    rpath = schema.results_path(work, aid)
    doc = schema.load_results(rpath, manifest_asset["projectId"])
    params = gt_params(labeller)
    key = schema.run_key(schema.DETECTOR_GT, GT_VERSION, schema.params_hash(params))
    run = schema.find_run(doc, key)
    if run is None:
        run = schema.new_run(schema.DETECTOR_GT, GT_VERSION, params, 0)
        doc["runs"].append(run)
    run["runAt"] = schema.now_iso()
    shapes = [s for s in labels.get("shapes", []) if isinstance(s, dict) and s.get("primitive")]
    stats = {"candidates": len(shapes), "accepted": len(shapes), "durationMs": 0,
             "done": bool(labels.get("done")), "notes": labels.get("notes") or ""}
    run["assets"] = [schema.new_asset(aid, manifest_asset["frameWidth"], manifest_asset["frameHeight"], shapes, stats)]
    schema.save_results(rpath, doc)
    return key


def make_label_handler(work: str, manifest: dict, labeller: str):
    by_id = {a["assetId"]: a for a in manifest["assets"]}
    html_path = os.path.join(HERE, "label.html")

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):  # quiet
            pass

        def _send(self, code, body, ctype="application/json"):
            if isinstance(body, (dict, list)):
                body = json.dumps(body, ensure_ascii=False).encode("utf-8")
            elif isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path in ("/", "/index.html"):
                with open(html_path, "rb") as f:
                    return self._send(200, f.read(), "text/html; charset=utf-8")
            if path == "/api/assets":
                out = []
                for a in manifest["assets"]:
                    lp = os.path.join(work, "labels", f"{a['assetId']}.json")
                    done, n = False, 0
                    if os.path.exists(lp):
                        with open(lp, "r", encoding="utf-8") as f:
                            lab = json.load(f)
                        done, n = bool(lab.get("done")), len(lab.get("shapes", []))
                    out.append({"assetId": a["assetId"], "name": a["name"], "image": a["image"],
                                "frameWidth": a["frameWidth"], "frameHeight": a["frameHeight"],
                                "inLabelSet": a["inLabelSet"], "done": done, "nShapes": n,
                                "createdAt": a.get("createdAt")})
                return self._send(200, {"labeller": labeller, "labelSet": manifest["labelSet"], "assets": out})
            if path.startswith("/api/labels/"):
                aid = path.rsplit("/", 1)[1].upper()
                lp = os.path.join(work, "labels", f"{aid}.json")
                if os.path.exists(lp):
                    with open(lp, "r", encoding="utf-8") as f:
                        return self._send(200, json.load(f))
                return self._send(200, {"assetId": aid, "shapes": [], "done": False, "notes": ""})
            if path.startswith("/images/"):
                name = path.rsplit("/", 1)[1]
                fp = os.path.join(work, "images", name)
                if not os.path.exists(fp):
                    return self._send(404, {"error": "no such image"})
                ext = os.path.splitext(name)[1].lower()
                ctype = {"jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png"}.get(ext, "application/octet-stream")
                if ext in (".jpg", ".jpeg"):
                    ctype = "image/jpeg"
                with open(fp, "rb") as f:
                    return self._send(200, f.read(), ctype)
            return self._send(404, {"error": "not found"})

        def do_POST(self):
            path = self.path.split("?", 1)[0]
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            if path == "/api/fit":
                aid = str(body.get("assetId", "")).upper()
                a = by_id.get(aid)
                if not a:
                    return self._send(400, {"error": "unknown asset"})
                res = shape_from_label(body.get("points") or [], body.get("primitive"),
                                       a["frameWidth"], a["frameHeight"], RULES, labeller=labeller)
                return self._send(200, res)
            if path.startswith("/api/labels/"):
                aid = path.rsplit("/", 1)[1].upper()
                a = by_id.get(aid)
                if not a:
                    return self._send(400, {"error": "unknown asset"})
                labels = {"assetId": aid, "labeller": labeller, "savedAt": schema.now_iso(),
                          "shapes": body.get("shapes") or [], "rejected": body.get("rejected") or [],
                          "done": bool(body.get("done")), "notes": body.get("notes") or ""}
                key = write_gt(work, a, labels, labeller)
                return self._send(200, {"ok": True, "runKey": key, "nShapes": len(labels["shapes"])})
            return self._send(404, {"error": "not found"})

    return Handler


def cmd_label(args) -> int:
    work = args.work
    manifest = load_manifest(work)
    if not os.path.exists(os.path.join(HERE, "label.html")):
        sys.exit("label.html is missing beside shapebench.py")
    handler = make_label_handler(work, manifest, args.labeller)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    url = f"http://127.0.0.1:{args.port}/"
    n_done = sum(1 for a in manifest["assets"] if os.path.exists(os.path.join(work, "labels", f"{a['assetId']}.json")))
    print(f"labelling {len(manifest['labelSet'])} assets (labeller {args.labeller}); {n_done} label files present")
    print(f"open {url}  — Ctrl-C to stop")
    if not args.no_browser:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
    return 0


# ---------------------------------------------------------------------------
# selftest
# ---------------------------------------------------------------------------

CARD_W, CARD_H = 3000, 2000
CARD_ELLIPSE = ((1000, 800), (500, 300), 25.0)
CARD_RECT = ((200, 1300), (1400, 1900))
CARD_TRAP = [(1900, 400), (2600, 520), (2600, 1500), (1900, 1650)]
CARD_CIRCLE = ((2750, 1850), 90)


def make_card() -> np.ndarray:
    img = np.full((CARD_H, CARD_W), 235, np.uint8)
    (cx, cy), (a, b), th = CARD_ELLIPSE
    cv2.ellipse(img, (cx, cy), (a, b), th, 0, 360, 30, -1, cv2.LINE_AA)
    cv2.rectangle(img, CARD_RECT[0], CARD_RECT[1], 30, -1)
    cv2.fillPoly(img, [np.array(CARD_TRAP, np.int32)], 30, cv2.LINE_AA)
    cv2.circle(img, CARD_CIRCLE[0], CARD_CIRCLE[1], 30, -1, cv2.LINE_AA)
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 85])
    img = cv2.imdecode(buf, cv2.IMREAD_GRAYSCALE)
    return cv2.cvtColor(img, cv2.COLOR_GRAY2BGR)


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
    ck = Check()
    W, H = CARD_W, CARD_H
    (ecx, ecy), (ea, eb), eth = CARD_ELLIPSE
    bgr = make_card()

    # 1. exact regions through the shared pass ------------------------------
    r = fit_candidate(Region(ellipse_outline(ecx, ecy, ea, eb, eth), "synthetic", from_contour=False), W, H)
    ck(r["accepted"] and r["primitive"] == "ellipse" and r["subclass"] == "ellipse", f"exact ellipse accepted: {r['reasons']}")
    if r["accepted"]:
        s = r["shape"]
        ck(abs(s["orientationDeg"] - eth) <= 0.05, f"exact ellipse orientation {s['orientationDeg']}")
        ck(abs(s["centre"]["x"] * W - ecx) <= 0.5 and abs(s["centre"]["y"] * H - ecy) <= 0.5, "exact ellipse centre")
        ck(abs(s["sizePx"]["major"] - 2 * ea) <= 1 and abs(s["sizePx"]["minor"] - 2 * eb) <= 1, f"exact ellipse axes {s['sizePx']}")
        ck(abs(s["extentRatio"] - 0.344) <= 0.003 and s["sizeBand"] == "small", f"exact ellipse extent {s['extentRatio']} {s['sizeBand']}")
    rect_pts = densify_polygon([CARD_RECT[0], (CARD_RECT[1][0], CARD_RECT[0][1]), CARD_RECT[1], (CARD_RECT[0][0], CARD_RECT[1][1])])
    r = fit_candidate(Region(rect_pts, "synthetic", from_contour=False), W, H)
    ck(r["accepted"] and r["primitive"] == "rectangle" and r["subclass"] == "rectangle", f"exact rectangle accepted: {r['reasons']}")
    if r["accepted"]:
        s = r["shape"]
        ck(s["fillRatio"] >= 0.995 and s["maxAngularDeviationDeg"] <= 0.1, f"exact rectangle fill/angles {s['fillRatio']} {s['maxAngularDeviationDeg']}")
        ck(abs(s["aspectRatio"] - 2.0) <= 0.01 and min(s["orientationDeg"], 180 - s["orientationDeg"]) <= 0.1, f"exact rectangle aspect/orientation {s['aspectRatio']} {s['orientationDeg']}")
        ck(abs(s["extentRatio"] - 0.40) <= 0.002 and s["sizeBand"] == "medium", f"exact rectangle extent {s['extentRatio']}")
    r = fit_candidate(Region(densify_polygon(CARD_TRAP), "synthetic", from_contour=False), W, H)
    ck(not r["accepted"], "trapezoid rejected")
    rr = r["rect"] or {}
    ck(rr.get("nVertices") == 4 and abs((rr.get("maxAngularDeviationDeg") or 0) - 12.09) <= 0.3, f"trapezoid angle deviation {rr.get('maxAngularDeviationDeg')}")
    ck(abs((rr.get("sideMismatch") or 0) - 0.216) <= 0.01, f"trapezoid side mismatch {rr.get('sideMismatch')}")
    ck(abs((rr.get("fillRatio") or 0) - 0.892) <= 0.01, f"trapezoid fill {rr.get('fillRatio')} (must PASS 0.85 — the angle rule rejects)")
    ck((r["ellipse"] or {}).get("iou", 1) < 0.9, f"trapezoid ellipse IoU {r['ellipse'].get('iou')}")
    ck(any("angle" in x for x in r["reasons"]) and any("sides" in x for x in r["reasons"]), f"trapezoid reasons {r['reasons']}")
    (ccx, ccy), cr = CARD_CIRCLE
    r = fit_candidate(Region(ellipse_outline(ccx, ccy, cr, cr, 0), "synthetic", from_contour=False), W, H)
    ck(not r["accepted"] and any("size floor" in x for x in r["reasons"]) and abs((r["extentRatio"] or 0) - 0.09) <= 0.002,
       f"small circle → size floor: {r['reasons']} extent {r['extentRatio']}")
    ck(r["primitive"] == "ellipse" and (r["ellipse"] or {}).get("axisRatio", 0) >= 0.98, "small circle passes the shape rules")

    # 2. the detector over the rendered card --------------------------------
    shapes, stats, rows = detect_opencv.detect_image(bgr, detect_opencv.DEFAULT_PARAMS)
    prims = sorted(s["primitive"] for s in shapes)
    ck(prims == ["ellipse", "rectangle"], f"detector accepted {prims} (candidates {stats['candidates']})")
    for s in shapes:
        if s["primitive"] == "ellipse":
            ck(abs(s["centre"]["x"] * W - ecx) <= 3 and abs(s["centre"]["y"] * H - ecy) <= 3, "detected ellipse centre")
            ck(abs(s["aspectRatio"] - 1.667) <= 0.02, f"detected ellipse aspect {s['aspectRatio']}")
            ck(abs(s["orientationDeg"] - eth) <= 1.0, f"detected ellipse orientation {s['orientationDeg']}")
            ck(abs(s["sizePx"]["major"] - 1000) <= 6 and abs(s["sizePx"]["minor"] - 600) <= 6, f"detected ellipse axes {s['sizePx']}")
            ck(s["subclass"] == "ellipse" and s["sizeBand"] == "small", f"detected ellipse subclass/band {s['subclass']} {s['sizeBand']}")
        else:
            ck(abs(s["centre"]["x"] * W - 800) <= 3 and abs(s["centre"]["y"] * H - 1600) <= 3, "detected rectangle centre")
            ck(abs(s["aspectRatio"] - 2.0) <= 0.02 and min(s["orientationDeg"], 180 - s["orientationDeg"]) <= 0.5, f"detected rectangle aspect/orientation {s['aspectRatio']} {s['orientationDeg']}")
            ck(s["fillRatio"] >= 0.98 and s["maxAngularDeviationDeg"] <= 1.0, f"detected rectangle fill/angles {s['fillRatio']} {s['maxAngularDeviationDeg']}")
            ck(s["sizeBand"] == "medium" and abs(s["extentRatio"] - 0.40) <= 0.005, f"detected rectangle extent {s['extentRatio']}")
            corners = np.array([[v["x"] * W, v["y"] * H] for v in s["vertices"]])
            want = np.array([CARD_RECT[0], (CARD_RECT[1][0], CARD_RECT[0][1]), CARD_RECT[1], (CARD_RECT[0][0], CARD_RECT[1][1])], float)
            ck(np.abs(corners - want).max() <= 3, f"detected rectangle corners within 3 px (max {np.abs(corners - want).max():.1f})")
    trap_rows = [x for x in rows if x.get("rect") and x["rect"].get("nVertices") == 4 and (x["rect"].get("maxAngularDeviationDeg") or 0) > 10]
    ck(any(not x["accepted"] for x in trap_rows), "detector rejected the trapezoid with an angle deviation > 10°")
    small_rows = [x for x in rows if x.get("extentRatio") and abs(x["extentRatio"] - 0.09) <= 0.01]
    ck(bool(small_rows) and not any(x["accepted"] for x in small_rows), f"detector logged the small circle as rejected ({len(small_rows)} rows)")

    # 3. v1 (Kit) conversion ---------------------------------------------------
    v1 = {"id": "T", "kind": "ellipse", "centre": [ecx / W, ecy / H], "majorAxis": 2 * ea / W, "minorAxis": 2 * eb / W,
          "rotation": math.radians(eth), "confidence": 0.9, "source": "detected"}
    r = fit_candidate(region_from_v1(v1, W, H), W, H)
    ck(r["accepted"] and abs(r["shape"]["orientationDeg"] - eth) <= 0.05, f"v1 ellipse round trip orientation {r.get('shape', {}) and r['shape']['orientationDeg']}")
    v1b = dict(v1, rotation=-0.436)
    r = fit_candidate(region_from_v1(v1b, W, H), W, H)
    ck(r["accepted"] and abs(r["shape"]["orientationDeg"] - 155.02) <= 0.1, f"v1 rotation -0.436 rad → {r.get('shape', {}) and r['shape']['orientationDeg']} (want 155.0)")
    v1q = {"id": "Q", "kind": "quad", "centre": [0.5, 0.5], "majorAxis": 0.1, "minorAxis": 0.1, "rotation": 0,
           "corners": [[200 / W, 1300 / H], [1400 / W, 1300 / H], [1400 / W, 1900 / H], [200 / W, 1900 / H]], "confidence": 0.9}
    r = fit_candidate(region_from_v1(v1q, W, H), W, H)
    ck(r["accepted"] and r["primitive"] == "rectangle" and abs(r["shape"]["aspectRatio"] - 2.0) <= 0.01, f"v1 quad round trip {r['reasons']}")
    v1t = dict(v1q, corners=[[x / W, y / H] for x, y in CARD_TRAP])
    r = fit_candidate(region_from_v1(v1t, W, H), W, H)
    ck(not r["accepted"] and any("angle" in x for x in r["reasons"]), "v1 trapezoid quad rejected by the angle rule")

    # 4. labels --------------------------------------------------------------
    lab = shape_from_label([CARD_RECT[0], (CARD_RECT[1][0], CARD_RECT[0][1]), CARD_RECT[1], (CARD_RECT[0][0], CARD_RECT[1][1])], "rectangle", W, H)
    ck(lab["accepted"] and lab["shape"]["gt"]["passesRules"] and abs(lab["shape"]["aspectRatio"] - 2.0) <= 0.01, f"label rectangle {lab['reason']}")
    lab = shape_from_label(CARD_TRAP, "rectangle", W, H)
    ck(lab["accepted"] and not lab["shape"]["gt"]["passesRules"] and abs(lab["shape"]["gt"]["maxAngularDeviationDeg"] - 12.09) <= 0.3,
       f"label trapezoid kept with passesRules=False {lab['shape'] and lab['shape']['gt']}")
    rim = ellipse_outline(ecx, ecy, ea, eb, eth, 8)
    rng = np.random.default_rng(1)
    rim_j = rim + rng.uniform(-1.5, 1.5, rim.shape)
    lab = shape_from_label(rim_j.tolist(), "ellipse", W, H)
    ck(lab["accepted"] and abs(lab["shape"]["orientationDeg"] - eth) <= 0.5 and lab["shape"]["gt"]["residual"] <= 0.01,
       f"label ellipse from 8 jittered rim points {lab['reason']} {lab['shape'] and lab['shape']['gt']}")
    lab = shape_from_label(rim[:4].tolist(), "ellipse", W, H)
    ck(not lab["accepted"] and "5" in (lab["reason"] or ""), "label ellipse refuses 4 points")
    lab = shape_from_label(ellipse_outline(ccx, ccy, cr, cr, 0, 8).tolist(), "ellipse", W, H)
    ck(lab["accepted"] and lab["shape"]["sizeBand"] == "discard" and lab["warnings"], "label below the floor kept as 'discard' with a warning")

    # 5. schema ledger semantics ---------------------------------------------
    doc = schema.empty_doc("SELFTEST")
    p1 = {"detector": detect_opencv.DEFAULT_PARAMS, "rules": RULES}
    run1 = schema.new_run(schema.DETECTOR_OPENCV, "1", p1, 10)
    run1["assets"] = [schema.new_asset("SELFTEST", W, H, shapes, stats)]
    ck(schema.upsert_run(doc, run1) == "added", "upsert adds")
    run1b = schema.new_run(schema.DETECTOR_OPENCV, "1", p1, 11)
    run1b["assets"] = [schema.new_asset("SELFTEST", W, H, shapes, stats)]
    ck(schema.upsert_run(doc, run1b) == "skipped" and len(doc["runs"]) == 1, "same key is skipped, never flushed")
    p2 = {"detector": detect_opencv.merged_params({"prefilter": {"minExtent": 0.15}}), "rules": RULES}
    run2 = schema.new_run(schema.DETECTOR_OPENCV, "1", p2, 12)
    run2["assets"] = [schema.new_asset("SELFTEST", W, H, [], {"candidates": 0, "accepted": 0})]
    ck(schema.upsert_run(doc, run2) == "added" and len(doc["runs"]) == 2, "a changed parameter is a new block beside the old")
    ck(schema.upsert_run(doc, run1b, force=True) == "replaced" and len(doc["runs"]) == 2, "--force replaces one block only")
    gt = schema.new_run(schema.DETECTOR_GT, GT_VERSION, gt_params("selftest"), 0)
    gt_shapes = []
    for s in shapes:
        g = json.loads(json.dumps(s))
        g["shapeId"] = "GT-" + g["shapeId"][:8]
        g["confidence"] = 1.0
        gt_shapes.append(g)
    gt["assets"] = [schema.new_asset("SELFTEST", W, H, gt_shapes)]
    schema.upsert_run(doc, gt)
    errs = schema.validate(doc, "selftest")
    ck(not errs, f"schema validates: {errs[:3]}")
    bad = json.loads(json.dumps(doc))
    bad["runs"][0]["assets"][0]["shapes"][0]["orientationDeg"] = 190
    ck(bool(schema.validate(bad)), "validate catches orientationDeg 190")

    # 6. matching ------------------------------------------------------------
    det_e = next(s for s in shapes if s["primitive"] == "ellipse")
    det_r = next(s for s in shapes if s["primitive"] == "rectangle")
    gt_e = next(s for s in gt_shapes if s["primitive"] == "ellipse")
    md = match_details(det_e, gt_e, W, H)
    ck(md["ok"] and md["iou"] >= 0.98, f"ellipse matches itself (iou {md['iou']:.3f})")
    ck(not match_details(det_r, gt_e, W, H)["ok"], "rectangle does not match the ellipse")
    shifted = json.loads(json.dumps(gt_e))
    shifted["centre"]["x"] += 1.0 / W * (W / 1024.0) * 1.0  # one working-scale px
    md = match_details(shifted, gt_e, W, H)
    ck(0.97 <= md["iou"] < 0.9995 and md["ok"], f"one working-px shift on a 34%-extent ellipse → iou {md['iou']:.3f}, still a match")
    shifted["centre"]["x"] = gt_e["centre"]["x"] + 0.03 * math.hypot(W, H) / W   # 3% of the diagonal
    md = match_details(shifted, gt_e, W, H)
    ck(not md["ok"] and md["offsetPctDiag"] > 2.0, f"3%-of-diagonal offset is not a match ({md['offsetPctDiag']:.2f}%)")
    try:
        import metrics as metrics_mod
        rep = metrics_mod.evaluate_pairs(gt_shapes, shapes, W, H)
        ck(rep["tp"] == 2 and rep["fp"] == 0 and rep["fn"] == 0, f"metrics on truth vs detected: {rep}")
    except ImportError:
        print("  (metrics.py not present yet — skipping the P/R check)")

    # 7. optional: the real lapse on the card ---------------------------------
    if args.lapse:
        lapse = os.path.abspath(args.lapse)
        if os.path.exists(lapse):
            os.makedirs(os.path.join(args.work, "selftest"), exist_ok=True)
            card = os.path.join(args.work, "selftest", "card.png")
            cv2.imwrite(card, bgr)
            proc = subprocess.run([lapse, "shapes", card, "--json"], capture_output=True, text=True, timeout=300)
            ck(proc.returncode == 0, f"lapse ran on the card: {proc.stderr[:200]}")
            if proc.returncode == 0:
                d = json.loads(proc.stdout)
                ck((d["width"], d["height"]) == (W, H), f"lapse dims {d['width']}x{d['height']}")
                ells = [s for s in d["shapes"] if s["kind"] == "ellipse"]
                ck(bool(ells), f"lapse found an ellipse (shapes: {[s['kind'] for s in d['shapes']]})")
                if ells:
                    e = max(ells, key=lambda s: s["majorAxis"])
                    r = fit_candidate(region_from_v1(e, W, H), W, H)
                    ck(r["accepted"] and abs(r["shape"]["orientationDeg"] - eth) <= 1.5,
                       f"lapse ellipse converts to {r.get('shape') and r['shape']['orientationDeg']}° (want 25 — pins the v1 rotation sign)")
                    ck(abs(r["shape"]["centre"]["x"] * W - ecx) <= 5 and abs(r["shape"]["centre"]["y"] * H - ecy) <= 5, "lapse ellipse centre within 5 px")
        else:
            print(f"  (lapse not found at {lapse} — skipping)")

    print(f"selftest: {ck.passes} passed, {len(ck.fails)} failed")
    return 0 if not ck.fails else 1


# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--work", default=DEFAULT_WORK, help="working directory (default tools/shapebench/work)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("export", help="copy the tagged corpus into the working dir")
    p.add_argument("--root", required=True, help="the library's Projects/ folder (holds library.json)")
    p.add_argument("--tag", default="Shape testing")
    p.add_argument("--label-set", type=int, default=25)
    p.add_argument("--label-all", action="store_true")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--force", action="store_true", help="re-copy / re-render even if present")
    p.set_defaults(fn=cmd_export)

    p = sub.add_parser("detect", help="run opencv-reference over the corpus")
    p.add_argument("--params", help="JSON file of overrides merged over DEFAULT_PARAMS (new paramsHash)")
    p.add_argument("--only", help="comma-separated asset id prefixes")
    p.add_argument("--limit", type=int)
    p.add_argument("--force", action="store_true", help="replace this key's block (never touches other keys)")
    p.set_defaults(fn=detect_opencv.run)

    p = sub.add_parser("vision", help="lapse shapes --json and the library register → schema v2")
    p.add_argument("--lapse", default=DEFAULT_LAPSE)
    p.add_argument("--params", help="JSON overrides for the refinement / dedupe knobs (same file as detect)")
    p.add_argument("--flags", default="", help='extra lapse arguments, e.g. "--sensitivity high --size all" (a new run block per distinct set)')
    p.add_argument("--only")
    p.add_argument("--limit", type=int)
    p.add_argument("--force", action="store_true")
    p.add_argument("--skip-register", action="store_true")
    p.set_defaults(fn=cmd_vision)

    p = sub.add_parser("label", help="serve the labelling page")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--labeller", default="steven")
    p.add_argument("--no-browser", action="store_true")
    p.set_defaults(fn=cmd_label)

    p = sub.add_parser("metrics", help="match every run against ground truth; report + overlays")
    p.add_argument("--run", action="append", default=[], help="detectorId=paramsHash to pin a run (default: latest)")
    p.add_argument("--docs", help="copy the report, metrics.json and review overlays into this docs folder")
    p.add_argument("--floor", type=float, default=None, help="override the size floor applied to GT and detections")
    p.add_argument("--all-runs", action="store_true", help="evaluate every run block of every detector, not just the latest/pinned one")
    p.set_defaults(fn=lambda a: __import__("metrics").run(a))

    p = sub.add_parser("selftest", help="synthetic card through every stage")
    p.add_argument("--lapse", default=None, help="also run this lapse binary on the card")
    p.set_defaults(fn=cmd_selftest)

    args = ap.parse_args(argv)
    args.work = os.path.abspath(args.work)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
