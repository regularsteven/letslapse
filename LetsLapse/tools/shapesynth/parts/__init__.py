"""SVG parts for the synthetic scenes (docs/shapemation/synthetic-corpus.md §2).

Three registries, each a name → factory:

  SKIES     'day' 'dusk' 'night' 'overcast'   — a full-frame gradient (+ sun / moon)
  GROUNDS   'hills' 'city' 'field' 'road'     — polygons/paths below the horizon,
                                                each with the y (fraction of the
                                                frame height) a subject stands on
  SUBJECTS  'tram_front' 'clock'              — drawn frontal in LOCAL units with
                                                a KNOWN outline in those units

A scene name is `<sky>-<ground>[-<ground>…]` (`day-hills-road`): the sky, then
the grounds painted in order, the last one's stand line deciding where the
subject's feet go. Fidelity does not matter; the outline geometry does — a
subject's outline is the exact figure `compose.py` pushes through the placement
matrix to write `truth`, so every subject must draw its outline figure exactly
where it says it does (the selftest samples the raster at the corners).

Local units: the outline's long side is 1.0 and the origin is the outline's
centre, y down like the frame. Anything outside the outline (the tram's
pantograph, the clock's post) is decoration and is deliberately NOT truth.
"""
from __future__ import annotations

from .grounds import GROUNDS, Ground
from .skies import SKIES
from .subjects import SUBJECTS, Subject

__all__ = ["SKIES", "GROUNDS", "SUBJECTS", "Ground", "Subject", "parse_scene_name"]


def parse_scene_name(name: str) -> tuple[str, list[str]]:
    """'day-hills-road' → ('day', ['hills', 'road']); raises on an unknown token."""
    tokens = [t for t in name.strip().lower().split("-") if t]
    if not tokens or tokens[0] not in SKIES:
        raise ValueError(f"scene '{name}': first token must be a sky ({', '.join(SKIES)})")
    grounds = tokens[1:] or ["field"]
    for g in grounds:
        if g not in GROUNDS:
            raise ValueError(f"scene '{name}': unknown ground '{g}' ({', '.join(GROUNDS)})")
    return tokens[0], grounds
