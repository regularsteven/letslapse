#!/usr/bin/env python3
"""Score render variants against Lightroom's own exports, and write the ledger.

    python3 tools/render_bench.py --corpus <dir> [--variants A,B,D1] [--scale 0.5]

A corpus is a folder of triples: `<name>.ARW`, `<name>.xmp` (Lightroom's
sidecar) and `<name>.jpg` (Lightroom's own export of that edit). The raws stay
out of git; the LEDGER goes in.

WHY THIS EXISTS, in one paragraph, because the mechanism is the point:
a rendering idea is only worth something if you can say what it bought, and
you can only say that if the previous idea is still runnable. `RenderVariant`
keeps every methodology alive in one build; this scores them all in one pass;
and `docs/render-variants/ledger.md` keeps the answers in git next to the
definitions. Change a variant and its old numbers become a lie — which is why
the registry is append-only and `RenderVariantTests` enforces it.

CROP. Lightroom applies the sidecar's crop and straighten before it exports,
so its JPEG is SMALLER than the raw whenever the photographer straightened
anything — three of the first corpus's five. Our render is full-frame, so the
harness applies the same crop rect and angle before comparing. Without that
those files cannot be scored at all, and quietly resizing to fit would score
a misalignment as a colour error.

WHAT IT DOES NOT MEASURE. The masked grades: the CLI renders the whole-picture
grade only, because the masked stage lives in the app's compositor. Every row
is therefore the whole-picture pipeline, which is where the structural gap
sits anyway (measured 2026-09-07: ΔE 6.5 outside any mask). Stated in the
ledger's own header too.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import datetime

import numpy as np

try:
    import cv2
except ImportError:
    sys.exit("needs opencv — run inside tools/.venv")

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
LAPSE = os.path.join(REPO, "Kit", ".build", "debug", "lapse")
SRGB = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"

sys.path.insert(0, HERE)
import importlib.util
_spec = importlib.util.spec_from_file_location(
    "lrcmp", os.path.join(HERE, "lightroom_compare.py"))
lrcmp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lrcmp)


def sidecar_crop(path):
    """The crop rect and straighten angle Lightroom applied, or None.

    Reads a `.xmp` directly, or finds the XMP packet inside a raw — the same
    two places `LightroomSidecar` looks, because the harness has to crop
    exactly what the renderer rendered.
    """
    if path.lower().endswith(".xmp"):
        text = open(path, encoding="utf-8", errors="replace").read()
    else:
        blob = open(path, "rb").read()
        start, end = blob.find(b"<x:xmpmeta"), blob.find(b"</x:xmpmeta>")
        if start < 0 or end < 0:
            return None
        text = blob[start:end + 12].decode("utf-8", "replace")

    def attr(name, default=None):
        match = re.search(rf'crs:{name}="([^"]*)"', text)
        return match.group(1) if match else default

    # The EXIF orientation is carried even with no crop: a portrait frame off
    # a landscape sensor has orientation 8 and nothing else. Missing it made
    # _WEB5765 score 17.0 against a reference it did not even share a shape
    # with — a squashed comparison scored as colour error, which is precisely
    # how a ledger fills up with numbers that mean nothing.
    orientation = int(re.search(r'tiff:Orientation="(\d+)"', text).group(1)
                      if re.search(r'tiff:Orientation="(\d+)"', text) else 1)
    cropped = (attr("HasCrop", "False") or "False").lower() == "true"
    if not cropped and orientation == 1:
        return None
    return {
        "top": float(attr("CropTop", 0)) if cropped else 0.0,
        "left": float(attr("CropLeft", 0)) if cropped else 0.0,
        "bottom": float(attr("CropBottom", 1)) if cropped else 1.0,
        "right": float(attr("CropRight", 1)) if cropped else 1.0,
        "angle": float(attr("CropAngle", 0)) if cropped else 0.0,
        "orientation": orientation,
    }


def sensor_rect_for(crop, image_is_portrait):
    """The crop rect in the frame our render actually arrives in.

    Lightroom writes Top/Left/Bottom/Right in the SENSOR's frame, but our
    decoder applies the file's EXIF orientation — so a portrait crop off a
    landscape sensor reaches us already upright, and applying the rect as
    written trims the wrong two edges. Here it is small (1.2% on _WEB5765);
    on a real portrait crop out of a landscape frame it would be badly wrong.

    Orientation 8 turns the sensor 90° CCW, so sensor (x, y) lands at
    (y, 1 − x); orientation 6 turns it CW, so (x, y) lands at (1 − y, x).
    """
    t, l, b, r = crop["top"], crop["left"], crop["bottom"], crop["right"]
    orientation = crop.get("orientation", 1)
    if not image_is_portrait or orientation not in (6, 8):
        return t, l, b, r
    if orientation == 8:
        return 1 - r, t, 1 - l, b
    return l, 1 - b, r, 1 - t


def apply_crop(image, crop):
    """Straighten then crop, the way Lightroom orders it.

    The angle is a rotation of the PICTURE, so the crop rect is expressed in
    the straightened frame — rotate first, then take the rect out of it.
    """
    if crop is None:
        return image
    h, w = image.shape[:2]
    if abs(crop["angle"]) > 1e-6:
        centre = (w / 2, h / 2)
        matrix = cv2.getRotationMatrix2D(centre, -crop["angle"], 1.0)
        image = cv2.warpAffine(image, matrix, (w, h),
                               flags=cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REPLICATE)
    t, l, b, r = sensor_rect_for(crop, image_is_portrait=h > w)
    x0, x1 = int(round(l * w)), int(round(r * w))
    y0, y1 = int(round(t * h)), int(round(b * h))
    return image[max(y0, 0):min(y1, h), max(x0, 0):min(x1, w)]


def oriented_to_match(image, reference_shape):
    """`image` turned to the reference's orientation, or None if it cannot be.

    The decoder already applies a file's EXIF orientation, so a portrait crop
    off a landscape sensor may arrive either way round depending on the path —
    and ASSUMING one was worse than not handling it at all: the first attempt
    rotated already-upright frames into landscape. So this does not assume. It
    tries the four right-angle turns and keeps the one whose shape matches the
    reference, which is unambiguous, self-checking, and fails loudly when the
    two genuinely do not correspond.
    """
    target = reference_shape[:2]

    def close(shape):
        return (abs(shape[0] - target[0]) <= max(target) * 0.02
                and abs(shape[1] - target[1]) <= max(target) * 0.02)

    if close(image.shape[:2]):
        return image
    for rotation in (cv2.ROTATE_90_CLOCKWISE, cv2.ROTATE_90_COUNTERCLOCKWISE, cv2.ROTATE_180):
        turned = cv2.rotate(image, rotation)
        if close(turned.shape[:2]):
            return turned
    # Aspect matches but the size does not: a resize is legitimate (a scale
    # rounding), a reshape is not.
    ours, theirs = image.shape[1] / image.shape[0], target[1] / target[0]
    if abs(ours - theirs) < 0.02:
        return image
    for rotation in (cv2.ROTATE_90_CLOCKWISE, cv2.ROTATE_90_COUNTERCLOCKWISE):
        turned = cv2.rotate(image, rotation)
        if abs(turned.shape[1] / turned.shape[0] - theirs) < 0.02:
            return turned
    return None


def score(reference_path, ours_path, crop):
    """One (file, variant) pair: mean/median ΔE2000 and the exposure offset."""
    reference = cv2.imread(reference_path, cv2.IMREAD_COLOR)
    ours = cv2.imread(ours_path, cv2.IMREAD_COLOR)
    if reference is None or ours is None:
        return None
    ours = apply_crop(ours, crop)
    ours = oriented_to_match(ours, reference.shape)
    if ours is None:
        return {"error": "no right-angle turn makes our render match the reference's shape"}
    if ours.shape[:2] != reference.shape[:2]:
        # After the crop the two should agree to a pixel or two; resize the
        # remainder rather than failing, and say so if it is more than that.
        dh = abs(ours.shape[0] - reference.shape[0])
        dw = abs(ours.shape[1] - reference.shape[1])
        if max(dh, dw) > max(reference.shape[:2]) * 0.02:
            return {"error": f"geometry mismatch {ours.shape[:2]} vs {reference.shape[:2]}"}
        ours = cv2.resize(ours, (reference.shape[1], reference.shape[0]),
                          interpolation=cv2.INTER_AREA)
    a = cv2.cvtColor(reference, cv2.COLOR_BGR2RGB).astype(np.float64) / 255
    b = cv2.cvtColor(ours, cv2.COLOR_BGR2RGB).astype(np.float64) / 255
    de = lrcmp.delta_e_2000(lrcmp.to_lab(a), lrcmp.to_lab(b))
    lum_a = lrcmp.luminance(lrcmp.linearise(a)).mean()
    lum_b = lrcmp.luminance(lrcmp.linearise(b)).mean()
    return {
        "mean": float(de.mean()),
        "median": float(np.median(de)),
        "p90": float(np.percentile(de, 90)),
        "under2": float((de < 2).mean()) * 100,
        "stops": float(np.log2(max(lum_b, 1e-9) / max(lum_a, 1e-9))),
    }


def variants_available():
    """(id, available, title) for every variant this build defines.

    Read as JSON rather than scraped from the human listing: the listing
    prints each variant's axes on a second line, and a regex over it happily
    mistook `decode=bradford` for a variant id.
    """
    out = subprocess.run([LAPSE, "variants", "--json"],
                         capture_output=True, text=True).stdout
    try:
        return [(v["id"], v["available"], v["title"]) for v in json.loads(out)]
    except (json.JSONDecodeError, KeyError, TypeError):
        sys.exit("could not read `lapse variants --json` — is the CLI up to date?")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--variants", default=None, help="comma-separated ids; default all available")
    parser.add_argument("--scale", default="0.5", help="render scale; 0.5 is plenty for scoring")
    parser.add_argument("--out", default=os.path.join(REPO, "docs", "render-variants"))
    parser.add_argument("--work", default="/tmp/render_bench")
    args = parser.parse_args()

    if not os.path.exists(LAPSE):
        sys.exit(f"build the CLI first: (cd Kit && swift build --product lapse)\nmissing {LAPSE}")
    os.makedirs(args.work, exist_ok=True)

    # Discovery walks the RAWS, not the sidecars. A DNG that has been through
    # Enhance or Denoise comes back with its settings inside the file and no
    # `.xmp` at all — two of batch3's five — and a corpus keyed on sidecars
    # skips those without saying so.
    RAW_EXT = (".arw", ".dng", ".nef", ".cr3", ".cr2", ".raf", ".rw2", ".orf")
    triples = []
    for entry in sorted(os.listdir(args.corpus)):
        stem, ext = os.path.splitext(entry)
        if ext.lower() not in RAW_EXT:
            continue
        reference = next((os.path.join(args.corpus, stem + e)
                          for e in (".jpg", ".jpeg", ".JPG")
                          if os.path.exists(os.path.join(args.corpus, stem + e))), None)
        if not reference:
            continue
        sidecar = next((os.path.join(args.corpus, stem + e)
                        for e in (".xmp", ".XMP")
                        if os.path.exists(os.path.join(args.corpus, stem + e))), None)
        # `lapse lightroom` takes either; handing it the raw when there is no
        # sidecar is what reaches the embedded XMP.
        triples.append((stem, sidecar or os.path.join(args.corpus, entry), reference))
    if not triples:
        sys.exit(f"no raw + .jpg pairs in {args.corpus}")
    embedded = sum(1 for _, s, _ in triples if not s.lower().endswith((".xmp",)))
    if embedded:
        print(f"  ({embedded} of {len(triples)} carry their settings inside the raw)")

    catalogue = variants_available()
    wanted = ([v.strip() for v in args.variants.split(",")] if args.variants
              else [v for v, ok, _ in catalogue if ok])
    print(f"corpus {os.path.basename(args.corpus)}: {len(triples)} files")
    print(f"variants: {', '.join(wanted)}\n")

    results = {}
    for variant in wanted:
        rows = []
        for name, sidecar, reference in triples:
            out_jpg = os.path.join(args.work, f"{name}-{variant}.jpg")
            run = subprocess.run(
                [LAPSE, "lightroom", sidecar, "--render", out_jpg,
                 "--variant", variant, "--scale", args.scale],
                capture_output=True, text=True)
            if run.returncode != 0:
                print(f"  {variant} {name}: render failed — {run.stderr.strip()[:120]}")
                continue
            srgb = out_jpg.replace(".jpg", "-srgb.jpg")
            subprocess.run(["sips", "--matchTo", SRGB, out_jpg, "--out", srgb],
                           capture_output=True)
            # The reference is scored at our render's scale, not the other way
            # round: downsampling the 42MP reference once is cheaper and does
            # not resample OUR pixels, which are the thing under test.
            ref_small = os.path.join(args.work, f"{name}-ref-{args.scale}.jpg")
            if not os.path.exists(ref_small):
                ref = cv2.imread(reference, cv2.IMREAD_COLOR)
                factor = float(args.scale)
                ref = cv2.resize(ref, (int(ref.shape[1] * factor), int(ref.shape[0] * factor)),
                                 interpolation=cv2.INTER_AREA)
                cv2.imwrite(ref_small, ref, [cv2.IMWRITE_JPEG_QUALITY, 98])
            got = score(ref_small, srgb, sidecar_crop(sidecar))
            if got is None or "error" in got:
                print(f"  {variant} {name}: {got.get('error') if got else 'unreadable'}")
                continue
            rows.append((name, got))
            print(f"  {variant:5s} {name:12s} ΔE {got['mean']:6.2f}  "
                  f"median {got['median']:6.2f}  {got['stops']:+.2f} stops")
        if rows:
            results[variant] = rows
            mean = sum(r[1]["mean"] for r in rows) / len(rows)
            print(f"  {variant:5s} {'CORPUS MEAN':12s} ΔE {mean:6.2f}\n")

    write_ledger(args.out, os.path.basename(args.corpus.rstrip("/")),
                 triples, catalogue, results, args.scale)


def write_ledger(out_dir, corpus, triples, catalogue, results, scale):
    os.makedirs(out_dir, exist_ok=True)
    commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                            capture_output=True, text=True, cwd=REPO).stdout.strip()
    today = datetime.date.today().isoformat()
    titles = {v: t for v, _, t in catalogue}

    payload = {
        "corpus": corpus, "files": [t[0] for t in triples], "scale": scale,
        "commit": commit, "date": today,
        "results": {v: {n: r for n, r in rows} for v, rows in results.items()},
    }
    with open(os.path.join(out_dir, "ledger.json"), "w") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)

    ranked = sorted(results.items(),
                    key=lambda kv: sum(r[1]["mean"] for r in kv[1]) / len(kv[1]))
    lines = [
        "# Render variant ledger",
        "",
        "**Generated by `tools/render_bench.py` — do not hand-edit the tables.**",
        "Regenerate with:",
        "",
        "```bash",
        f"./tools/.venv/bin/python tools/render_bench.py --corpus <dir> --scale {scale}",
        "```",
        "",
        f"Corpus `{corpus}` · {len(triples)} files · render scale {scale} · "
        f"commit `{commit}` · {today}",
        "",
        "Scores are mean CIEDE2000 against Lightroom's own export of the same edit —",
        "**lower is better**. ~1 is just noticeable, 2–3 visible side by side, >5 obvious.",
        "Lightroom's crop and straighten are applied to our render before scoring.",
        "",
        "**These rows measure the WHOLE-PICTURE pipeline only.** The masked grades live in",
        "the app's compositor, which the CLI cannot reach; see `docs/TODO.md`.",
        "",
        "## Scoreboard",
        "",
        "| variant | mean ΔE | median | best file | worst file | what it is |",
        "|---|---|---|---|---|---|",
    ]
    for variant, rows in ranked:
        mean = sum(r[1]["mean"] for r in rows) / len(rows)
        median = sum(r[1]["median"] for r in rows) / len(rows)
        best = min(rows, key=lambda r: r[1]["mean"])
        worst = max(rows, key=lambda r: r[1]["mean"])
        lines.append(
            f"| **{variant}** | {mean:.2f} | {median:.2f} | "
            f"{best[0]} {best[1]['mean']:.2f} | {worst[0]} {worst[1]['mean']:.2f} | "
            f"{titles.get(variant, '')} |")

    if ranked:
        baseline = dict(ranked).get("A")
        if baseline:
            base_mean = sum(r[1]["mean"] for r in baseline) / len(baseline)
            lines += ["", "## Against the baseline", "",
                      "| variant | mean ΔE | vs A |", "|---|---|---|"]
            for variant, rows in ranked:
                mean = sum(r[1]["mean"] for r in rows) / len(rows)
                delta = mean - base_mean
                verdict = "—" if variant == "A" else (
                    f"**{delta:+.2f}** better" if delta < -0.05 else
                    (f"{delta:+.2f} worse" if delta > 0.05 else f"{delta:+.2f} no change"))
                lines.append(f"| {variant} | {mean:.2f} | {verdict} |")

    lines += ["", "## Per file", "",
              "| file | " + " | ".join(v for v, _ in ranked) + " |",
              "|---" * (len(ranked) + 1) + "|"]
    for name, _, _ in triples:
        cells = []
        for variant, rows in ranked:
            row = next((r for r in rows if r[0] == name), None)
            cells.append(f"{row[1]['mean']:.2f}" if row else "—")
        lines.append(f"| {name} | " + " | ".join(cells) + " |")

    lines += ["", "---", "",
              "Variant definitions and their hypotheses live in",
              "`Kit/Sources/LetsLapseKit/RenderVariant.swift`. The registry is",
              "**append-only**: a variant named here is never redefined, because these",
              "numbers were measured against the axes it had on the date above.",
              ""]
    path = os.path.join(out_dir, "ledger.md")
    with open(path, "w") as handle:
        handle.write("\n".join(lines))
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
