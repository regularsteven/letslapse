"""Grounds: what lies below the horizon, and where a subject stands on it.

Each factory returns a `Ground`: the SVG fragment in frame pixels plus the
stand line — the y (as a fraction of the frame height) a subject's base is
placed on. Grounds paint in the order the scene name lists them, so
`hills-road` puts the road over the hills and the road's stand line wins.
"""
from __future__ import annotations

from dataclasses import dataclass

from .skies import HORIZON


@dataclass(frozen=True)
class Ground:
    svg: str
    stand_y: float   # fraction of H


def ground_hills(W: int, H: int) -> Ground:
    hy = HORIZON * H
    far = (f"M0,{hy + 0.06 * H:.1f} C{0.15 * W:.1f},{hy - 0.10 * H:.1f} {0.35 * W:.1f},{hy - 0.02 * H:.1f} {0.5 * W:.1f},{hy + 0.02 * H:.1f} "
           f"S{0.8 * W:.1f},{hy - 0.12 * H:.1f} {W},{hy + 0.03 * H:.1f} L{W},{H} L0,{H} Z")
    near = (f"M0,{hy + 0.12 * H:.1f} C{0.2 * W:.1f},{hy + 0.02 * H:.1f} {0.45 * W:.1f},{hy + 0.16 * H:.1f} {0.65 * W:.1f},{hy + 0.08 * H:.1f} "
            f"S{0.9 * W:.1f},{hy + 0.14 * H:.1f} {W},{hy + 0.10 * H:.1f} L{W},{H} L0,{H} Z")
    svg = (f'<path d="{far}" fill="#5F8F4E"/>'
           f'<path d="{near}" fill="#4A7A3C"/>'
           f'<rect x="0" y="{0.80 * H:.1f}" width="{W}" height="{0.2 * H:.1f}" fill="#3E6A33"/>')
    return Ground(svg, stand_y=0.80)


def ground_city(W: int, H: int) -> Ground:
    hy = HORIZON * H
    blocks, windows = [], []
    x = 0.0
    i = 0
    while x < W:
        bw = W * (0.05 + 0.035 * ((i * 7) % 3))
        bh = H * (0.10 + 0.05 * ((i * 5) % 4))
        shade = ["#3B4658", "#4A5668", "#2F3948"][i % 3]
        blocks.append(f'<rect x="{x:.1f}" y="{hy - bh:.1f}" width="{bw:.1f}" height="{bh + 0.02 * H:.1f}" fill="{shade}"/>')
        for r in range(int(bh / (0.025 * H))):
            for c in range(max(1, int(bw / (0.02 * W)))):
                if (r * 3 + c * 5 + i) % 5 == 0:
                    windows.append(f'<rect x="{x + 0.004 * W + c * 0.02 * W:.1f}" y="{hy - bh + 0.006 * H + r * 0.025 * H:.1f}" '
                                   f'width="{0.009 * W:.1f}" height="{0.012 * H:.1f}" fill="#EBDDA4"/>')
        x += bw + 0.006 * W
        i += 1
    svg = ("".join(blocks) + "".join(windows)
           + f'<rect x="0" y="{hy + 0.02 * H:.1f}" width="{W}" height="{H - hy:.1f}" fill="#6E6E72"/>'
           + f'<rect x="0" y="{0.80 * H:.1f}" width="{W}" height="{0.2 * H:.1f}" fill="#5C5C60"/>')
    return Ground(svg, stand_y=0.80)


def ground_field(W: int, H: int) -> Ground:
    hy = HORIZON * H
    furrows = "".join(
        f'<line x1="0" y1="{hy + k * (H - hy) / 9:.1f}" x2="{W}" y2="{hy + (k + 0.15) * (H - hy) / 9:.1f}" '
        f'stroke="#77993F" stroke-width="{0.004 * H:.1f}"/>' for k in range(1, 9))
    svg = (f'<rect x="0" y="{hy:.1f}" width="{W}" height="{H - hy:.1f}" fill="#85A845"/>' + furrows
           + f'<rect x="0" y="{hy - 0.012 * H:.1f}" width="{W}" height="{0.012 * H:.1f}" fill="#3E5A2A"/>')
    return Ground(svg, stand_y=0.78)


def ground_road(W: int, H: int) -> Ground:
    """A road across the frame; the near kerb is the stand line."""
    top, bottom = 0.66 * H, 0.86 * H
    dashes = "".join(
        f'<rect x="{k * 0.10 * W:.1f}" y="{(top + bottom) / 2 - 0.006 * H:.1f}" width="{0.05 * W:.1f}" height="{0.012 * H:.1f}" fill="#F3E3A0"/>'
        for k in range(10))
    rails = (f'<rect x="0" y="{top + 0.30 * (bottom - top):.1f}" width="{W}" height="{0.004 * H:.1f}" fill="#B9B9BC"/>'
             f'<rect x="0" y="{top + 0.70 * (bottom - top):.1f}" width="{W}" height="{0.004 * H:.1f}" fill="#B9B9BC"/>')
    svg = (f'<rect x="0" y="{top - 0.015 * H:.1f}" width="{W}" height="{0.015 * H:.1f}" fill="#A9A6A0"/>'
           f'<rect x="0" y="{top:.1f}" width="{W}" height="{bottom - top:.1f}" fill="#4F5258"/>'
           + rails + dashes
           + f'<rect x="0" y="{bottom:.1f}" width="{W}" height="{0.015 * H:.1f}" fill="#A9A6A0"/>')
    return Ground(svg, stand_y=0.84)


GROUNDS = {"hills": ground_hills, "city": ground_city, "field": ground_field, "road": ground_road}
