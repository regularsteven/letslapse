"""Subjects: drawn frontal in local units with an exactly known outline.

Local units: the outline's long side is 1.0, the origin is the outline's
centre, x right and y DOWN (the same handedness as the frame, so the
placement matrix needs no flip). A `Subject` carries the SVG fragment in
those units and the outline figure `compose.py` maps to `truth`:

  outline = ("quad", [(x, y) × 4])   corners clockwise from top-left
  outline = ("ellipse", (cx, cy, r)) a circle in local units

Two probes support the selftest: `inside` are local points that must land on
`body_rgb` in the raster, `outside` are points just past the outline that must
not — the raster-vs-truth agreement check. Keep flat fills where the probes
sample; gradients are fine elsewhere.
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Subject:
    name: str
    svg: str
    outline: tuple                     # ("quad", corners) | ("ellipse", (cx, cy, r))
    family: str                        # the Kit family the outline intends: rectangle | circle
    body_rgb: tuple[int, int, int]     # flat colour at the `inside` probes
    inside: list[tuple[float, float]] = field(default_factory=list)
    outside: list[tuple[float, float]] = field(default_factory=list)
    base_y: float = 0.5                # local y of the feet (where the stand line goes)


# ---------------------------------------------------------------------------
# tram_front — a stylised tram face. Outline = the body rectangle 1.0 × 0.65,
# corners (±0.5, ±0.325). The pantograph rises above the roof to y = −0.55 and
# is NOT part of the outline; neither is the shadow below.
#
# Why 0.65 and not a squarer face: the Kit calls a quad `square` while its
# seen aspect is within 0.8…1.25 (`DetectedShape.family`), and a 1.0 × 0.8
# body sat exactly ON that boundary — float noise after normalisation decided
# the family per scene, and the `left`/`right` viewpoints (x · cos yaw) pushed
# it inside. 1.0 × 0.65 is 1.54 head-on and 1.43 at the 22° of yaw
# `compose.VIEWPOINTS` uses: a rectangle from every viewpoint the generator
# has, with a margin the dials cannot eat (scale is isotropic, the offset and
# the rotation keep the aspect). `family` is written into every manifest and
# the selftest pins ≥ 0.05 of margin per subject × viewpoint.
# ---------------------------------------------------------------------------

TRAM_BODY = "#C8322B"
TRAM_BODY_RGB = (0xC8, 0x32, 0x2B)


def subject_tram_front() -> Subject:
    board_bars = "".join(
        f'<rect x="{-0.30 + k * 0.075:.3f}" y="-0.200" width="0.04" height="0.045" fill="#3A2A10"/>' for k in range(8))
    svg = (
        # shadow on the ground (decoration, outside the outline)
        '<ellipse cx="0" cy="0.34" rx="0.55" ry="0.03" fill="#000" opacity="0.35"/>'
        # pantograph: two diagonal arms and the contact bar, above the roof
        '<path d="M-0.20,-0.325 L0.04,-0.525 M0.20,-0.325 L-0.04,-0.525" stroke="#2B2B2E" stroke-width="0.018" fill="none"/>'
        '<rect x="-0.16" y="-0.55" width="0.32" height="0.022" fill="#2B2B2E"/>'
        '<rect x="-0.26" y="-0.34" width="0.52" height="0.03" fill="#8E1F1A"/>'
        # the body — THE outline rectangle, a flat fill
        f'<rect x="-0.5" y="-0.325" width="1.0" height="0.65" rx="0.03" ry="0.03" fill="{TRAM_BODY}"/>'
        # windscreen with a destination board inside it
        '<rect x="-0.42" y="-0.24" width="0.84" height="0.26" rx="0.03" ry="0.03" fill="#25364D"/>'
        '<path d="M-0.40,-0.22 L0.10,-0.22 L-0.32,0.00 L-0.40,0.00 Z" fill="#5B7FA8" opacity="0.45"/>'
        '<rect x="-0.34" y="-0.215" width="0.68" height="0.07" fill="#F4C860"/>' + board_bars +
        # windscreen wiper
        '<path d="M0.05,0.00 L0.30,-0.18" stroke="#1B222D" stroke-width="0.012" fill="none"/>'
        # a lighter band and the bumper stripe
        '<rect x="-0.5" y="0.04" width="1.0" height="0.04" fill="#E6D8C8"/>'
        '<rect x="-0.5" y="0.20" width="1.0" height="0.045" fill="#8E1F1A"/>'
        # headlights
        '<circle cx="-0.34" cy="0.14" r="0.055" fill="#2B2B2E"/><circle cx="-0.34" cy="0.14" r="0.045" fill="#FFF2B8"/>'
        '<circle cx="0.34" cy="0.14" r="0.055" fill="#2B2B2E"/><circle cx="0.34" cy="0.14" r="0.045" fill="#FFF2B8"/>'
        # route number plate between the lights
        '<rect x="-0.09" y="0.10" width="0.18" height="0.08" rx="0.01" fill="#F6F1E4"/>'
        '<rect x="-0.05" y="0.115" width="0.03" height="0.05" fill="#1C1C1E"/><rect x="0.02" y="0.115" width="0.03" height="0.05" fill="#1C1C1E"/>'
        # coupler under the bumper (decoration, inside the outline's bottom edge)
        '<rect x="-0.06" y="0.27" width="0.12" height="0.03" fill="#2B2B2E"/>'
    )
    corners = [(-0.5, -0.325), (0.5, -0.325), (0.5, 0.325), (-0.5, 0.325)]
    # probes sit on flat body colour with ≥ 0.03 units of clearance from any
    # decoration (the bumper stripe ends at 0.245, the windscreen starts at −0.24)
    inset, outset = 0.05, 0.06
    inside = [(-0.5 + inset, -0.325 + inset), (0.5 - inset, -0.325 + inset), (0.5 - inset, 0.325 - inset), (-0.5 + inset, 0.325 - inset)]
    outside = [(-0.5 - outset, -0.325 - outset), (0.5 + outset, -0.325 - outset), (0.5 + outset, 0.325 + outset), (-0.5 - outset, 0.325 + outset)]
    return Subject("tram_front", svg, ("quad", corners), "rectangle", TRAM_BODY_RGB, inside, outside, base_y=0.325)


# ---------------------------------------------------------------------------
# clock — a station clock on a post. Outline = the dial disc, radius 0.5 at the
# origin (diameter 1.0). The bezel is a stroke INSIDE that radius, the post and
# bracket hang below it and are not part of the outline.
# ---------------------------------------------------------------------------

CLOCK_FACE = "#F7F3E8"
CLOCK_FACE_RGB = (0xF7, 0xF3, 0xE8)


def subject_clock() -> Subject:
    import math
    ticks = []
    for h in range(12):
        a = math.radians(h * 30)
        r0 = 0.36 if h % 3 else 0.33
        ticks.append(f'<line x1="{r0 * math.sin(a):.4f}" y1="{-r0 * math.cos(a):.4f}" x2="{0.42 * math.sin(a):.4f}" y2="{-0.42 * math.cos(a):.4f}" '
                     f'stroke="#1C1C1E" stroke-width="{0.03 if h % 3 == 0 else 0.016}"/>')
    svg = (
        # post and bracket (decoration, below the dial)
        '<rect x="-0.045" y="0.45" width="0.09" height="0.85" fill="#3E4147"/>'
        '<rect x="-0.20" y="1.28" width="0.40" height="0.06" fill="#2B2B2E"/>'
        # the dial disc — THE outline circle, a flat fill
        f'<circle cx="0" cy="0" r="0.5" fill="{CLOCK_FACE}"/>'
        '<circle cx="0" cy="0" r="0.478" fill="none" stroke="#1C1C1E" stroke-width="0.044"/>'
        + "".join(ticks) +
        # hands at ten past ten, and the centre boss
        '<path d="M0,0 L-0.19,-0.19" stroke="#1C1C1E" stroke-width="0.035" stroke-linecap="round"/>'
        '<path d="M0,0 L0.16,-0.28" stroke="#1C1C1E" stroke-width="0.025" stroke-linecap="round"/>'
        '<circle cx="0" cy="0" r="0.03" fill="#C36A00"/>'
    )
    d = 0.42 / math.sqrt(2)   # 45° between the 1 and 2 o'clock ticks, on the flat face
    inside = [(d, -d), (d, d), (-d, d)]                       # avoid the 10:10 hands' quadrant
    o = 0.56 / math.sqrt(2)
    outside = [(o, -o), (o, o), (-o, o), (-o, -o)]
    return Subject("clock", svg, ("ellipse", (0.0, 0.0, 0.5)), "circle", CLOCK_FACE_RGB, inside, outside, base_y=1.34)


SUBJECTS = {"tram_front": subject_tram_front, "clock": subject_clock}
