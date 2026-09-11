"""Schema v2 for shape-benchmark results (docs/shape-benchmark/brief.md §4).

One file per project: { schemaVersion: 2, projectId, runs: [ run ] }. A run is
keyed by detectorId + detectorVersion + paramsHash; a key that already exists in
the file is never re-run and never flushed — a changed parameter set is a new
key, and the old block stays so the two can be diffed.

Coordinate conventions (shared with fitting.py):
  * image space, upright, origin top-left, y down
  * centre / vertices normalised per axis (x / frameWidth, y / frameHeight)
  * axes.major / axes.minor = FULL axis lengths as fractions of frameWidth
    (the v1 register's convention, so the day Kit adopts v2 it is a rename);
    sizePx carries the same lengths in pixels
  * aspectRatio >= 1; orientationDeg in [0, 180) = angle of the major / long
    axis from +x toward +y (visually clockwise)
  * confidence = fillRatio (rectangle) or mask IoU (ellipse) — a fit figure,
    never a salience figure; 1.0 for ground truth (n/a)
  * sizeBand "discard" appears only on ground truth below the size floor; a
    detector never emits it (the shape is rejected instead)
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
import tempfile

SCHEMA_VERSION = 2

DETECTOR_OPENCV = "opencv-reference"
DETECTOR_VISION = "apple-vision"
DETECTOR_REGISTER = "apple-vision-register"
DETECTOR_GT = "manual-groundtruth"

PRIMITIVES = ("rectangle", "ellipse")
SUBCLASSES = {"rectangle": ("rectangle", "square"), "ellipse": ("ellipse", "circle")}
BANDS = ("discard", "small", "medium", "large")


# --- keys -----------------------------------------------------------------

def canonical(obj) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def params_hash(params) -> str:
    return hashlib.sha256(canonical(params).encode("utf-8")).hexdigest()[:12]


def run_key(detector_id: str, detector_version, phash: str) -> str:
    return f"{detector_id}|{detector_version}|{phash}"


def key_of(run: dict) -> str:
    return run_key(run["detectorId"], run["detectorVersion"], run["paramsHash"])


def now_iso() -> str:
    return (datetime.datetime.now(datetime.timezone.utc)
            .replace(microsecond=0).isoformat().replace("+00:00", "Z"))


# --- constructors ---------------------------------------------------------

def new_run(detector_id: str, detector_version, params: dict, duration_ms=0, run_at=None) -> dict:
    return {
        "detectorId": detector_id,
        "detectorVersion": str(detector_version),
        "paramsHash": params_hash(params),
        "params": params,
        "runAt": run_at or now_iso(),
        "durationMs": int(round(duration_ms)),
        "assets": [],
    }


def new_asset(asset_id: str, width: int, height: int, shapes=None, stats=None) -> dict:
    d = {"assetId": asset_id, "frameWidth": int(width), "frameHeight": int(height),
         "shapes": list(shapes or [])}
    if stats:
        d["stats"] = stats
    return d


def empty_doc(project_id: str) -> dict:
    return {"schemaVersion": SCHEMA_VERSION, "projectId": project_id, "runs": []}


# --- files ----------------------------------------------------------------

def results_path(work: str, asset_id: str) -> str:
    return os.path.join(work, "results", f"{asset_id}.json")


def load_results(path: str, project_id: str | None = None) -> dict:
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            doc = json.load(f)
        if doc.get("schemaVersion") != SCHEMA_VERSION:
            raise ValueError(f"{path}: schemaVersion {doc.get('schemaVersion')} != {SCHEMA_VERSION}")
        return doc
    if project_id is None:
        raise FileNotFoundError(path)
    return empty_doc(project_id)


def save_results(path: str, doc: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=os.path.dirname(path))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


# --- run blocks -----------------------------------------------------------

def find_run(doc: dict, key: str) -> dict | None:
    for run in doc.get("runs", []):
        if key_of(run) == key:
            return run
    return None


def has_run(doc: dict, key: str) -> bool:
    return find_run(doc, key) is not None


def runs_for(doc: dict, detector_id: str) -> list:
    return [r for r in doc.get("runs", []) if r["detectorId"] == detector_id]


def upsert_run(doc: dict, run: dict, force: bool = False) -> str:
    """Add `run` to the document. Returns 'added', 'skipped' (key already
    present, nothing changed) or 'replaced' (force)."""
    key = key_of(run)
    for i, existing in enumerate(doc["runs"]):
        if key_of(existing) == key:
            if not force:
                return "skipped"
            doc["runs"][i] = run
            return "replaced"
    doc["runs"].append(run)
    return "added"


def upsert_asset(run: dict, asset: dict) -> None:
    for i, a in enumerate(run["assets"]):
        if a["assetId"] == asset["assetId"]:
            run["assets"][i] = asset
            break
    else:
        run["assets"].append(asset)
    run["assets"].sort(key=lambda a: a["assetId"])


def asset_in_run(run: dict, asset_id: str) -> dict | None:
    for a in run.get("assets", []):
        if a["assetId"] == asset_id:
            return a
    return None


# --- validation -----------------------------------------------------------

def _num(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def validate(doc: dict, path: str = "") -> list[str]:
    """Hand-written structural checks (no jsonschema in the venv).
    Returns a list of error strings; empty means valid."""
    errs: list[str] = []
    where = f"{path}: " if path else ""

    def err(msg):
        errs.append(where + msg)

    if doc.get("schemaVersion") != SCHEMA_VERSION:
        err(f"schemaVersion {doc.get('schemaVersion')!r} != {SCHEMA_VERSION}")
    if not isinstance(doc.get("projectId"), str) or not doc["projectId"]:
        err("projectId missing")
    runs = doc.get("runs")
    if not isinstance(runs, list):
        err("runs must be a list")
        return errs
    seen = set()
    for ri, run in enumerate(runs):
        tag = f"runs[{ri}]"
        for k in ("detectorId", "detectorVersion", "paramsHash", "params", "runAt", "durationMs", "assets"):
            if k not in run:
                err(f"{tag}: missing {k}")
        if errs:
            continue
        if run["paramsHash"] != params_hash(run["params"]):
            err(f"{tag}: paramsHash {run['paramsHash']} != hash of params {params_hash(run['params'])}")
        key = key_of(run)
        if key in seen:
            err(f"{tag}: duplicate run key {key}")
        seen.add(key)
        if not isinstance(run["assets"], list):
            err(f"{tag}: assets must be a list")
            continue
        for ai, asset in enumerate(run["assets"]):
            atag = f"{tag}.assets[{ai}]"
            for k in ("assetId", "frameWidth", "frameHeight", "shapes"):
                if k not in asset:
                    err(f"{atag}: missing {k}")
            if any(e.startswith(where + atag) for e in errs):
                continue
            if not (isinstance(asset["frameWidth"], int) and asset["frameWidth"] > 0
                    and isinstance(asset["frameHeight"], int) and asset["frameHeight"] > 0):
                err(f"{atag}: frame dimensions must be positive ints")
            for si, s in enumerate(asset["shapes"]):
                _validate_shape(s, f"{atag}.shapes[{si}]", err, run["detectorId"])
    return errs


def _validate_shape(s: dict, tag: str, err, detector_id: str) -> None:
    for k in ("shapeId", "primitive", "subclass", "centre", "extentRatio", "sizeBand",
              "aspectRatio", "orientationDeg", "vertices", "axes", "confidence",
              "maxAngularDeviationDeg", "fillRatio"):
        if k not in s:
            err(f"{tag}: missing {k}")
            return
    p = s["primitive"]
    if p not in PRIMITIVES:
        err(f"{tag}: primitive {p!r}")
        return
    if s["subclass"] not in SUBCLASSES[p]:
        err(f"{tag}: subclass {s['subclass']!r} not valid for {p}")
    c = s["centre"]
    if not (isinstance(c, dict) and _num(c.get("x")) and _num(c.get("y"))
            and -0.5 <= c["x"] <= 1.5 and -0.5 <= c["y"] <= 1.5):
        err(f"{tag}: centre {c!r}")
    if not (_num(s["extentRatio"]) and 0 < s["extentRatio"] <= 2.0):
        err(f"{tag}: extentRatio {s['extentRatio']!r}")
    if s["sizeBand"] not in BANDS:
        err(f"{tag}: sizeBand {s['sizeBand']!r}")
    elif s["sizeBand"] == "discard" and detector_id != DETECTOR_GT:
        err(f"{tag}: a detector run may not emit sizeBand 'discard'")
    if not (_num(s["aspectRatio"]) and s["aspectRatio"] >= 1.0 - 1e-6):
        err(f"{tag}: aspectRatio {s['aspectRatio']!r} < 1")
    if not (_num(s["orientationDeg"]) and 0.0 <= s["orientationDeg"] < 180.0):
        err(f"{tag}: orientationDeg {s['orientationDeg']!r} not in [0,180)")
    if not (_num(s["confidence"]) and 0.0 <= s["confidence"] <= 1.0 + 1e-6):
        err(f"{tag}: confidence {s['confidence']!r}")
    if p == "rectangle":
        v = s["vertices"]
        if not (isinstance(v, list) and len(v) == 4
                and all(isinstance(q, dict) and _num(q.get("x")) and _num(q.get("y")) for q in v)):
            err(f"{tag}: rectangle needs 4 vertices")
        if s["axes"] is not None:
            err(f"{tag}: rectangle must have axes null")
        if not _num(s["maxAngularDeviationDeg"]) or not _num(s["fillRatio"]):
            err(f"{tag}: rectangle needs maxAngularDeviationDeg and fillRatio")
    else:
        a = s["axes"]
        if not (isinstance(a, dict) and _num(a.get("major")) and _num(a.get("minor"))
                and a["major"] > 0 and 0 < a["minor"] <= a["major"] + 1e-9):
            err(f"{tag}: ellipse needs axes {{major >= minor > 0}}")
        if s["vertices"] is not None:
            err(f"{tag}: ellipse must have vertices null")
