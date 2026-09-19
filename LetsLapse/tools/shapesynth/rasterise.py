"""SVG → frame.jpg: rsvg-convert at the frame size, then Pillow writes the JPEG
at quality 92 with an explicit EXIF orientation of 1 (contract §2) — or, for
the oriented-frame variant, of 6: the same picture STORED a quarter-turn
anticlockwise (a W×H frame becomes an H×W file) so a reader that honours the
tag turns it a quarter-turn clockwise and sees the frame upright again, the
way every phone's portrait JPEG reads. The manifest is identical either way:
its geometry is in the oriented frame. No cairosvg — the venv takes no new
packages; rsvg-convert is Homebrew's.
"""
from __future__ import annotations

import os
import shutil
import subprocess

from PIL import Image

RSVG = "/opt/homebrew/bin/rsvg-convert"
ORIENTATION_TAG = 0x0112
JPEG_QUALITY = 92


def rsvg_path() -> str:
    if os.path.exists(RSVG):
        return RSVG
    found = shutil.which("rsvg-convert")
    if not found:
        raise RuntimeError(f"rsvg-convert not found at {RSVG} nor on PATH — `brew install librsvg`")
    return found


ORIENTATIONS = (1, 6)


def rasterise(svg_text: str, W: int, H: int, jpg_path: str, keep_svg: bool = True, orientation: int = 1) -> None:
    """Writes `jpg_path` (and scene.svg beside it when keep_svg); `orientation` 1 or 6."""
    if orientation not in ORIENTATIONS:
        raise ValueError(f"orientation must be one of {ORIENTATIONS}, got {orientation}")
    folder = os.path.dirname(os.path.abspath(jpg_path))
    os.makedirs(folder, exist_ok=True)
    svg_path = os.path.join(folder, "scene.svg")
    png_path = os.path.join(folder, ".frame.png")
    with open(svg_path, "w", encoding="utf-8") as f:
        f.write(svg_text)
    subprocess.run([rsvg_path(), "-w", str(W), "-h", str(H), svg_path, "-o", png_path],
                   check=True, capture_output=True)
    with Image.open(png_path) as im:
        rgb = im.convert("RGB")
        if rgb.size != (W, H):
            raise RuntimeError(f"rsvg-convert produced {rgb.size}, wanted {(W, H)}")
        if orientation == 6:
            # PIL's ROTATE_90 is a quarter-turn anticlockwise; exif_transpose
            # undoes tag 6 with ROTATE_270 (clockwise), so the two cancel.
            rgb = rgb.transpose(Image.Transpose.ROTATE_90)
        exif = Image.Exif()
        exif[ORIENTATION_TAG] = orientation
        rgb.save(jpg_path, "JPEG", quality=JPEG_QUALITY, exif=exif.tobytes())
    os.remove(png_path)
    if not keep_svg:
        os.remove(svg_path)


def jpeg_size_and_orientation(path: str) -> tuple[tuple[int, int], int]:
    """The STORED size and the EXIF orientation tag."""
    with Image.open(path) as im:
        return im.size, int(im.getexif().get(ORIENTATION_TAG, 1))


def oriented_size(path: str) -> tuple[int, int]:
    """The size as the picture reads: stored axes swapped under a quarter-turn tag (5–8)."""
    (w, h), orientation = jpeg_size_and_orientation(path)
    return (h, w) if orientation >= 5 else (w, h)
