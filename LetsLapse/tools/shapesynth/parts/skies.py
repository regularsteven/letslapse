"""Skies: one full-frame gradient each, with a sun or moon where it suits.

Every factory takes the frame size and returns an SVG fragment in frame
pixels. The horizon sits at HORIZON of the height — the grounds start there.
"""
from __future__ import annotations

HORIZON = 0.58   # fraction of the frame height where sky meets ground


def _gradient(gid: str, stops: list[tuple[float, str]]) -> str:
    inner = "".join(f'<stop offset="{o:.3f}" stop-color="{c}"/>' for o, c in stops)
    return f'<linearGradient id="{gid}" x1="0" y1="0" x2="0" y2="1">{inner}</linearGradient>'


def sky_day(W: int, H: int) -> str:
    return (
        f"<defs>{_gradient('sky', [(0, '#2F6FCF'), (0.55, '#7FB2EA'), (1, '#CFE6F8')])}</defs>"
        f'<rect x="0" y="0" width="{W}" height="{H}" fill="url(#sky)"/>'
        f'<circle cx="{0.82 * W:.1f}" cy="{0.16 * H:.1f}" r="{0.045 * W:.1f}" fill="#FFF3B0" opacity="0.9"/>'
        f'<ellipse cx="{0.25 * W:.1f}" cy="{0.22 * H:.1f}" rx="{0.11 * W:.1f}" ry="{0.035 * H:.1f}" fill="#FFFFFF" opacity="0.75"/>'
        f'<ellipse cx="{0.31 * W:.1f}" cy="{0.19 * H:.1f}" rx="{0.07 * W:.1f}" ry="{0.03 * H:.1f}" fill="#FFFFFF" opacity="0.8"/>'
    )


def sky_dusk(W: int, H: int) -> str:
    return (
        f"<defs>{_gradient('sky', [(0, '#22245A'), (0.45, '#8A4B7C'), (0.8, '#F0883E'), (1, '#FFD28C')])}</defs>"
        f'<rect x="0" y="0" width="{W}" height="{H}" fill="url(#sky)"/>'
        f'<circle cx="{0.62 * W:.1f}" cy="{0.52 * H:.1f}" r="{0.05 * W:.1f}" fill="#FFB340" opacity="0.95"/>'
    )


def sky_night(W: int, H: int) -> str:
    stars = "".join(
        f'<circle cx="{(37 * i * 7919) % W:.0f}" cy="{(53 * i * 104729) % int(H * 0.5):.0f}" r="{2 + (i % 3)}" fill="#C9D2E8"/>'
        for i in range(1, 40)
    )
    return (
        f"<defs>{_gradient('sky', [(0, '#03061A'), (0.7, '#101C3E'), (1, '#24365E')])}</defs>"
        f'<rect x="0" y="0" width="{W}" height="{H}" fill="url(#sky)"/>{stars}'
        f'<circle cx="{0.78 * W:.1f}" cy="{0.18 * H:.1f}" r="{0.035 * W:.1f}" fill="#F2F4E6"/>'
        f'<circle cx="{0.79 * W:.1f}" cy="{0.165 * H:.1f}" r="{0.03 * W:.1f}" fill="#101C3E"/>'
    )


def sky_overcast(W: int, H: int) -> str:
    return (
        f"<defs>{_gradient('sky', [(0, '#7C8590'), (0.6, '#AEB6BE'), (1, '#D6DADF')])}</defs>"
        f'<rect x="0" y="0" width="{W}" height="{H}" fill="url(#sky)"/>'
        f'<ellipse cx="{0.4 * W:.1f}" cy="{0.25 * H:.1f}" rx="{0.3 * W:.1f}" ry="{0.06 * H:.1f}" fill="#98A1AB" opacity="0.6"/>'
    )


SKIES = {"day": sky_day, "dusk": sky_dusk, "night": sky_night, "overcast": sky_overcast}
