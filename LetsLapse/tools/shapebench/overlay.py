"""Review overlays: a 1024-px copy of the picture with fitted primitives drawn."""
from __future__ import annotations

import cv2
import numpy as np

from fitting import shape_outline_px, MATCH
from imaging import resized_long_edge

# BGR
COLOURS = {
    "accepted": (255, 200, 0),    # cyan-ish (BGR: blue+green)
    "gt": (80, 220, 80),          # green
    "matched": (255, 200, 0),     # cyan
    "fp": (0, 140, 255),          # orange
    "fn": (60, 60, 255),          # red
    "rejected": (110, 110, 110),  # grey
    "text": (255, 255, 255),
}


def _poly(img, pts, colour, thickness=2, closed=True):
    q = np.round(np.asarray(pts, np.float64)).astype(np.int32).reshape(-1, 1, 2)
    cv2.polylines(img, [q], closed, colour, thickness, cv2.LINE_AA)


def _label(img, xy, text, colour):
    x, y = int(xy[0]), int(xy[1])
    (tw, th), _ = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, 0.45, 1)
    cv2.rectangle(img, (x, y - th - 4), (x + tw + 4, y + 2), (0, 0, 0), -1)
    cv2.putText(img, text, (x + 2, y - 2), cv2.FONT_HERSHEY_SIMPLEX, 0.45, colour, 1, cv2.LINE_AA)


def render(bgr: np.ndarray, W: int, H: int, layers: list, title: str | None = None,
           long_edge: int | None = None) -> np.ndarray:
    """layers: [(kind, shapes, label_fn)] drawn in order; kind picks the colour.
    Rejected candidates may be given as raw outlines under kind 'rejected'
    with shapes=[{'outline': (N,2) px}]."""
    L = long_edge or MATCH["workingLongEdge"]
    small, s = resized_long_edge(bgr, L)
    img = small.copy()
    for kind, shapes, label_fn in layers:
        colour = COLOURS.get(kind, (255, 255, 255))
        for sh in shapes:
            if "outline" in sh:
                pts = np.asarray(sh["outline"], np.float64) * s
                step = max(1, len(pts) // 400)
                _poly(img, pts[::step], colour, 1)
                continue
            pts = shape_outline_px(sh, W, H) * s
            _poly(img, pts, colour, 2)
            if label_fn:
                x0, y0 = pts.min(axis=0)
                _label(img, (x0, max(12, y0 - 2)), label_fn(sh), colour)
    if title:
        _label(img, (4, 16), title, COLOURS["text"])
    return img


def short_label(sh: dict) -> str:
    return f"{sh['shapeId'][:8]} {sh['subclass'][:4]} c{sh['confidence']:.2f} e{sh['extentRatio']:.2f}"
