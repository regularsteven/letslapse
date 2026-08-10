#!/usr/bin/env python3
"""Report the lens each segment of a shoot was recorded on.

A multi-segment run must record every segment on one physical lens. When it
does not, the joins reframe (the lenses' optical axes differ) and the segments
that ran on a wider lens are digital crops — the 2026-08-06 report, project
10DD1859: tele, then a 5x crop of the wide, then a ~9x crop of the ultra-wide.

Reads `com.apple.quicktime.camera.lens_model` and `.focal_length.35mm_equivalent`
straight out of each .mov's movie-level `mdta` metadata, so it needs nothing but
the files. With `--detail` it also runs a sharpness metric per segment (ffmpeg):
the PSNR of each frame against its own gaussian blur, where a HIGHER number
means LESS real detail — an upscaled segment stands out immediately.

    ./check_lens_continuity.py ~/Library/Application\\ Support/LetsLapse/Projects/<id>
    ./check_lens_continuity.py <dir-of-segments> --detail

Exits non-zero when the segments disagree about the lens.
"""

import argparse
import pathlib
import struct
import subprocess
import sys

WANTED = {
    "com.apple.quicktime.camera.lens_model": "lens",
    "com.apple.quicktime.camera.focal_length.35mm_equivalent": "equiv",
}


def read_mdta(path):
    """Movie-level mdta metadata as {key: value}. Empty when there is none."""
    # moov sits at the end of an unfaststarted iOS capture; the tail is plenty.
    with open(path, "rb") as handle:
        handle.seek(max(0, path.stat().st_size - 400_000))
        blob = handle.read()

    keys_at = blob.find(b"keys")
    ilst_at = blob.find(b"ilst", keys_at if keys_at >= 0 else 0)
    if keys_at < 4 or ilst_at < 4:
        return {}

    size = struct.unpack(">I", blob[keys_at - 4:keys_at])[0]
    body = blob[keys_at + 4:keys_at - 4 + size]
    count = struct.unpack(">I", body[4:8])[0]
    keys, cursor = [], 8
    for _ in range(count):
        entry = struct.unpack(">I", body[cursor:cursor + 4])[0]
        if entry < 8:
            break
        keys.append(body[cursor + 8:cursor + entry].decode("utf-8", "replace"))
        cursor += entry

    size = struct.unpack(">I", blob[ilst_at - 4:ilst_at])[0]
    body = blob[ilst_at + 4:ilst_at - 4 + size]
    out, cursor = {}, 0
    while cursor + 8 <= len(body):
        entry = struct.unpack(">I", body[cursor:cursor + 4])[0]
        if entry < 8:
            break
        index = struct.unpack(">I", body[cursor + 4:cursor + 8])[0]
        inner = body[cursor + 8:cursor + entry]
        cursor += entry
        if len(inner) < 16 or inner[4:8] != b"data":
            continue
        kind = struct.unpack(">I", inner[8:12])[0] & 0xFFFFFF
        payload = inner[16:struct.unpack(">I", inner[0:4])[0]]
        name = keys[index - 1] if 1 <= index <= len(keys) else f"?{index}"
        if kind == 1:
            out[name] = payload.decode("utf-8", "replace")
        elif kind == 21:
            out[name] = str(int.from_bytes(payload, "big", signed=True))
    return out


def detail_db(path):
    """Mean PSNR of each sampled frame against its own blur. Higher = softer."""
    proc = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path),
         "-vf", "fps=1,split[a][b];[b]gblur=sigma=1.2[bb];[a][bb]psnr",
         "-f", "null", "-"],
        capture_output=True, text=True)
    values = [float(chunk.split()[0])
              for line in proc.stderr.splitlines() if "psnr_avg:" in line
              for chunk in [line.split("psnr_avg:")[1]]]
    return sum(values) / len(values) if values else None


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("path", type=pathlib.Path,
                        help="a project directory, its source/ folder, or any folder of segments")
    parser.add_argument("--detail", action="store_true",
                        help="also measure per-segment sharpness (needs ffmpeg; slow)")
    args = parser.parse_args()

    root = args.path / "source" if (args.path / "source").is_dir() else args.path
    segments = sorted(root.glob("segment-*.mov")) or sorted(root.glob("*.mov"))
    if not segments:
        sys.exit(f"no .mov segments under {root}")

    lenses = set()
    for segment in segments:
        meta = read_mdta(segment)
        fields = {label: meta.get(key, "?") for key, label in WANTED.items()}
        lenses.add(fields["lens"])
        line = f"{segment.name}  {fields['lens']}  ({fields['equiv']}mm equiv)"
        if args.detail:
            measured = detail_db(segment)
            line += f"  detail {measured:.1f} dB" if measured else "  detail n/a"
        print(line)

    print()
    if len(lenses) == 1:
        print(f"OK — one lens across {len(segments)} segment(s).")
        return 0
    print(f"LENS CHANGED MID-SHOOT — {len(lenses)} lenses across {len(segments)} segments:")
    for lens in sorted(lenses):
        print(f"  {lens}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
