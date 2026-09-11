"""Image loading that provably matches what `lapse shapes --json` reports.

JPEG/HEIC/PNG: Pillow + ImageOps.exif_transpose (the upright picture; cv2's
IMREAD_COLOR is pixel-identical but IMREAD_UNCHANGED drops orientation, and cv2
cannot decode DNG — so one path for everything that is not raw).
DNG: rawpy.postprocess with the file's own flip (user_flip default). The phone's
Bayer DNGs carry flip=6, so the render comes out 3024×4032 upright exactly as
the app and `lapse` see it. Never `user_flip=0`, never `half_size`, and never
Pillow (it returns only the embedded preview of a DNG).
"""
from __future__ import annotations

import os

import cv2
import numpy as np
from PIL import Image, ImageOps

RAW_EXTENSIONS = {".dng"}


class DimsMismatch(RuntimeError):
    pass


def is_raw(path: str) -> bool:
    return os.path.splitext(path)[1].lower() in RAW_EXTENSIONS


def load_bgr(path: str) -> np.ndarray:
    """Upright BGR uint8 array (H, W, 3)."""
    if is_raw(path):
        import rawpy  # lazy: only the export step touches DNGs
        with rawpy.imread(path) as raw:
            rgb = raw.postprocess(use_camera_wb=True, no_auto_bright=True, output_bps=8)
        return np.ascontiguousarray(rgb[:, :, ::-1])
    with Image.open(path) as im:
        im = ImageOps.exif_transpose(im)
        rgb = np.asarray(im.convert("RGB"))
    return np.ascontiguousarray(rgb[:, :, ::-1])


def load_gray(path: str) -> np.ndarray:
    return cv2.cvtColor(load_bgr(path), cv2.COLOR_BGR2GRAY)


def dims_of(arr: np.ndarray) -> tuple[int, int]:
    """(width, height) of an array."""
    h, w = arr.shape[:2]
    return int(w), int(h)


def check_dims(arr: np.ndarray, width: int, height: int, label: str) -> None:
    w, h = dims_of(arr)
    if (w, h) != (int(width), int(height)):
        raise DimsMismatch(f"{label}: decoded {w}x{h} != expected {width}x{height} — orientation/crop mismatch")


def resized_long_edge(bgr: np.ndarray, long_edge: int) -> tuple[np.ndarray, float]:
    """Downscale so max(W, H) == long_edge (never upscales). Returns (image, scale)."""
    w, h = dims_of(bgr)
    s = min(1.0, long_edge / max(w, h))
    if s >= 1.0:
        return bgr, 1.0
    out = cv2.resize(bgr, (max(1, round(w * s)), max(1, round(h * s))), interpolation=cv2.INTER_AREA)
    return out, s
