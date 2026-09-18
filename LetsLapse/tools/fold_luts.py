#!/usr/bin/env python3
"""Fold a LetsLapse library's per-project LUT copies into its store — once.

Until 2026-09-18 a grade that carried a `.cube` copied it into the project's
own ``luts/<hash>.cube`` (spike §4.4). A LUT is now a library asset identified
by its content hash (docs/lut-library-assets.md): the project names the hash,
``<root>/luts/<hash>.cube`` + ``<root>/luts.json`` hold the bytes once, and
nothing sits in a project folder. This script moves an existing library to
that shape:

  1. lists ``luts.json`` and ``luts/*.cube``; walks ``Projects/*/luts/*.cube``
     and ``Projects/.trash/*/luts/*.cube``, checking each file's SHA-256
     against its name (a mismatch is reported and left alone);
  2. copies one file per distinct hash the store lacks into ``luts/`` and
     adds a ``luts.json`` record — file name from the first project document
     whose preset snapshot names that cube ("Terra 4.1.cube"), else the hash;
     title and size from the cube; ``isLikelyLogInput`` by the Kit's rule;
  3. adds a LUT preset to ``custom_presets.json`` for every cube no preset
     names, from the first document whose state is a named preset over it,
     under that state's preset id (so those projects resolve as *named*);
  4. deletes every project copy and the emptied ``luts/`` folders;
  5. reports the hashes documents name that exist nowhere.

Dry run by default; ``--apply`` makes the changes. QUIT LetsLapse on that
library first: the app holds ``luts.json`` and ``custom_presets.json`` in
memory and would write them back over this. The index needs nothing — the
``project_luts`` rows come from the documents, which are not touched.

  python3 tools/fold_luts.py "/Volumes/letslapse/picplace.test/regularsteven"
  python3 tools/fold_luts.py <root> --apply
"""

import argparse
import datetime as dt
import hashlib
import json
import shutil
import sys
import uuid
from pathlib import Path

CUBE = ".cube"


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(4 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_cube(data: bytes) -> dict:
    """The Kit's parser, as far as the record needs: title, size, domain, rgba."""
    title, size = "", 0
    domain_min, domain_max = [0.0, 0.0, 0.0], [1.0, 1.0, 1.0]
    rgba: list[float] = []
    for raw in data.decode("utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        upper = line.upper()
        if upper.startswith("TITLE"):
            title = line[5:].strip().strip('"')
            continue
        if upper.startswith("LUT_3D_SIZE"):
            size = int(line.split()[1])
            continue
        if upper.startswith("LUT_1D_SIZE"):
            raise ValueError("1D LUT")
        if upper.startswith("DOMAIN_MIN"):
            domain_min = [float(v) for v in line.split()[1:4]]
            continue
        if upper.startswith("DOMAIN_MAX"):
            domain_max = [float(v) for v in line.split()[1:4]]
            continue
        parts = line.split()
        if len(parts) != 3:
            continue
        try:
            r, g, b = (float(p) for p in parts)
        except ValueError:
            continue
        rgba.extend((r, g, b, 1.0))
    if size <= 0 or len(rgba) != size ** 3 * 4:
        raise ValueError(f"bad cube: size {size}, {len(rgba) // 4} entries")
    return {"title": title, "size": size, "min": domain_min, "max": domain_max, "rgba": rgba}


def luma_of_grey(cube: dict, grey: float = 0.5) -> float:
    """Trilinear sample of neutral grey, Rec.709 luma — `CubeLUT.luma(ofGrey:)`."""
    n, rgba = cube["size"], cube["rgba"]

    def axis(v, lo, hi):
        rng = hi - lo
        unit = (v - lo) / rng if rng > 0 else v
        s = min(max(unit, 0.0), 1.0) * (n - 1)
        i = min(int(s), n - 2)
        return i, s - i

    (ri, rf), (gi, gf), (bi, bf) = (axis(grey, cube["min"][k], cube["max"][k]) for k in range(3))

    def at(dr, dg, db):
        i = (((bi + db) * n + (gi + dg)) * n + (ri + dr)) * 4
        return rgba[i:i + 3]

    def mix(a, b, t):
        return [x * (1 - t) + y * t for x, y in zip(a, b)]

    c00 = mix(at(0, 0, 0), at(1, 0, 0), rf)
    c10 = mix(at(0, 1, 0), at(1, 1, 0), rf)
    c01 = mix(at(0, 0, 1), at(1, 0, 1), rf)
    c11 = mix(at(0, 1, 1), at(1, 1, 1), rf)
    out = mix(mix(c00, c10, gf), mix(c01, c11, gf), bf)
    return 0.2126 * out[0] + 0.7152 * out[1] + 0.0722 * out[2]


def lut_ids_in(capture: dict) -> list[str]:
    """`LibraryIndex.referencedLUTIDs(inCapture:)` — the same three places."""
    ids: list[str] = []

    def take(adjustments):
        lut = (adjustments or {}).get("lut") if isinstance(adjustments, dict) else None
        if isinstance(lut, dict) and lut.get("id") and lut["id"] not in ids:
            ids.append(lut["id"])

    take(capture.get("adjustments"))
    for keyframe in (capture.get("gradeTimeline") or {}).get("k", []) or []:
        take(keyframe.get("adjustments"))
    take(((capture.get("presetState") or {}).get("snapshot") or {}).get("adjustments"))
    return ids


def unique_name(name: str, taken: set[str]) -> str:
    """`CustomPresetStore.uniqueName(for:)`: "Terra 4.1", then "Terra 4.1 2", …"""
    if name not in taken:
        return name
    n = 2
    while f"{name} {n}" in taken:
        n += 1
    return f"{name} {n}"


def human(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GB"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root", help="the library root (holds Projects/, luts/, luts.json, custom_presets.json)")
    ap.add_argument("--apply", action="store_true", help="make the changes (default: report only)")
    ap.add_argument("--no-presets", action="store_true", help="do not add LUT presets from the snapshots")
    ap.add_argument("--force", action="store_true", help="proceed although Projects/.lock is held")
    args = ap.parse_args()

    root = Path(args.root).expanduser()
    projects = root / "Projects"
    store_dir = root / "luts"
    index_path = root / "luts.json"
    presets_path = root / "custom_presets.json"
    if not projects.is_dir():
        print(f"not a library root: {root} (no Projects/ — is the volume mounted?)", file=sys.stderr)
        return 2
    if (projects / ".lock").exists() and not args.force:
        print(f"{projects / '.lock'} is held — quit LetsLapse on this library first (or --force)", file=sys.stderr)
        return 2

    # 1. What the store and the documents hold.
    records = json.loads(index_path.read_text()) if index_path.exists() else []
    record_ids = {r["id"] for r in records}
    store_files = {p.stem for p in store_dir.glob(f"*{CUBE}")} if store_dir.is_dir() else set()

    referenced: dict[str, int] = {}          # hash → documents naming it
    snapshots: dict[str, dict] = {}          # hash → first named snapshot over that cube
    documents = 0
    for folder in sorted(list(projects.glob("*")) + list((projects / ".trash").glob("*"))):
        doc = folder / "project.json"
        if not doc.is_file():
            continue
        try:
            capture = json.loads(doc.read_text()).get("capture") or {}
        except (ValueError, OSError) as e:
            print(f"  ! {doc}: {e}")
            continue
        documents += 1
        for lut_id in lut_ids_in(capture):
            referenced[lut_id] = referenced.get(lut_id, 0) + 1
        state = capture.get("presetState") or {}
        snap = state.get("snapshot") or {}
        lut = (snap.get("adjustments") or {}).get("lut") or {}
        if state.get("kind") == "named" and lut.get("id") and lut["id"] not in snapshots:
            snapshots[lut["id"]] = {"presetID": state.get("id"), "name": snap.get("name") or "",
                                    "basePreset": snap.get("basePreset") or "Original",
                                    "adjustments": snap.get("adjustments")}

    # 2. The copies.
    copies: dict[str, list[Path]] = {}
    strays: list[Path] = []               # index.json etc. left by a crashed export
    mismatched: list[tuple[Path, str]] = []
    for luts in sorted(list(projects.glob("*/luts")) + list((projects / ".trash").glob("*/luts"))):
        for item in sorted(luts.iterdir()):
            if item.name.startswith("."):
                continue
            if item.suffix != CUBE:
                strays.append(item)
                continue
            digest = sha256_of(item)
            if digest != item.stem:
                mismatched.append((item, digest))
                continue
            copies.setdefault(item.stem, []).append(item)
    copy_count = sum(len(v) for v in copies.values())
    copy_bytes = sum(p.stat().st_size for v in copies.values() for p in v)

    # 3. The plan.
    to_store = {h: paths[0] for h, paths in copies.items() if h not in store_files}
    new_records = []
    for h in sorted(set(copies) | store_files):
        if h in record_ids:
            continue
        source = to_store.get(h) or (store_dir / f"{h}{CUBE}")
        data = source.read_bytes()
        try:
            cube = parse_cube(data)
        except ValueError as e:
            print(f"  ! {source}: {e} — no record")
            continue
        snap = snapshots.get(h)
        file_name = f"{snap['name']}{CUBE}" if snap and snap["name"] else f"{h[:12]}{CUBE}"
        new_records.append({
            "byteCount": len(data), "fileName": file_name, "id": h,
            "importedAt": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "isLikelyLogInput": luma_of_grey(cube) < 0.25, "size": cube["size"], "title": cube["title"],
        })

    presets = json.loads(presets_path.read_text()) if presets_path.exists() else []
    preset_lut_ids = {((p.get("adjustments") or {}).get("lut") or {}).get("id") for p in presets}
    preset_ids = {str(p.get("id", "")).upper() for p in presets}
    taken_names = {p.get("name", "") for p in presets}
    new_presets = []
    if not args.no_presets:
        for h in sorted(set(copies) | store_files):
            snap = snapshots.get(h)
            if h in preset_lut_ids or not snap or not snap.get("adjustments"):
                continue
            preset_id = str(snap["presetID"] or "").upper()
            if not preset_id or preset_id in preset_ids:
                preset_id = str(uuid.uuid4()).upper()
            name = unique_name(snap["name"] or h[:12], taken_names)
            taken_names.add(name)
            preset_ids.add(preset_id)
            new_presets.append({"adjustments": snap["adjustments"], "basePreset": snap["basePreset"],
                                "id": preset_id, "name": name})

    everywhere = set(copies) | store_files | set(to_store)
    unresolvable = sorted(h for h in referenced if h not in everywhere)

    verb = "will" if args.apply else "would"
    print(f"library: {root}")
    print(f"  documents: {documents} · naming a LUT: {sum(referenced.values())} references to {len(referenced)} cube(s)")
    print(f"  store: {len(store_files)} cube(s), {len(records)} record(s), {len(presets)} preset(s) ({len(preset_lut_ids - {None})} LUT)")
    print(f"  project copies: {copy_count} file(s), {len(copies)} distinct cube(s), {human(copy_bytes)}")
    for h, paths in sorted(copies.items()):
        print(f"    {h[:12]}  × {len(paths):3d}  {human(paths[0].stat().st_size):>9}  {'in store' if h in store_files else verb + ' enter the store'}"
              f"  {'— ' + snapshots[h]['name'] if h in snapshots else ''}")
    print(f"  {verb} copy into the store: {len(to_store)} · add luts.json record(s): {len(new_records)} · add preset(s): {len(new_presets)}")
    for r in new_records:
        print(f"    record {r['id'][:12]}  {r['fileName']}  {r['size']}³  title={r['title']!r}  log={r['isLikelyLogInput']}")
    for p in new_presets:
        print(f"    preset {p['id']}  {p['name']!r}")
    print(f"  {verb} delete {copy_count} copy file(s) ({human(copy_bytes)}) and {len(strays)} stray file(s)")
    if mismatched:
        print(f"  left alone — name is not the content hash: {len(mismatched)}")
        for path, digest in mismatched:
            print(f"    {path}  (bytes hash to {digest[:12]})")
    if unresolvable:
        print(f"  ! referenced by documents but held nowhere (renders without the LUT until imported): {len(unresolvable)}")
        for h in unresolvable:
            print(f"    {h}  ({referenced[h]} document(s))")

    if not args.apply:
        print("dry run — nothing changed; add --apply")
        return 0

    # 4. Apply, store first so nothing is deleted before its bytes are safe.
    store_dir.mkdir(exist_ok=True)
    for h, source in sorted(to_store.items()):
        target = store_dir / f"{h}{CUBE}"
        shutil.copy2(source, target)
        if sha256_of(target) != h:
            print(f"copy of {h[:12]} into the store did not verify — stopping before any delete", file=sys.stderr)
            return 1
    if new_records:
        records.extend(new_records)
        index_path.write_text(json.dumps(records, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    if new_presets:
        presets.extend(new_presets)
        presets_path.write_text(json.dumps(presets, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    removed = 0
    for paths in copies.values():
        for p in paths:
            p.unlink()
            removed += 1
    for p in strays:
        p.unlink()
    emptied = 0
    for luts in list(projects.glob("*/luts")) + list((projects / ".trash").glob("*/luts")):
        if all(item.name.startswith(".") for item in luts.iterdir()):
            shutil.rmtree(luts)
            emptied += 1
    print(f"applied: {len(to_store)} cube(s) into the store, {len(new_records)} record(s), {len(new_presets)} preset(s), "
          f"{removed} copies removed ({human(copy_bytes)} freed), {emptied} luts/ folder(s) gone")
    return 0


if __name__ == "__main__":
    sys.exit(main())
