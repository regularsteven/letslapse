# Scene kit

Flat SVG parts that compose into "photos" of a tram for shape-mation prototyping. Nothing is drawn twice: every composition is a sky + a scene + a tram object, positioned by a recipe.

```
kit/
  build.js            the generator — draws the parts, composes the recipes, writes the manifest
  recipes.json        one entry per composition; add a line and rebuild
  objects/            tram.front | left | right | high | low   (Prague T3-style)
  skies/              sky.clear | clouds | sun | golden | dusk | night   (golden/dusk/night also tint the frame)
  scenes/             scene.city | oldtown | hills | mountains | depot   (backdrop + ground colour; `data-road` says lane width, tracks, surface)
  compositions/       generated — one SVG per recipe + manifest.json
```

Rebuild: `node kit/build.js` (or ask for a rebuild). Parts are inlined into each composition, so the outputs open anywhere (Quick Look, GitHub, `<img>`) with no external references.

## Recipe fields

```json
{ "id": "city.clear.approach.01", "aspect": "3:2", "scene": "city", "sky": "clear",
  "track": "right", "camera": "left", "size": 0.16, "cx": 0.42 }
```

The composer is a small one-point-perspective camera standing on a two-lane road (metres; lane 3.5 m, tracks at ±1.75 m, tram 2.5 m wide). It draws the road, kerbs, centre line and every track itself, so the tram is always on its rails.

- `aspect` — `3:2`, `2:3`, `1:1`, `4:3`, `16:9`. Skies and scenes are 1800×1200 and slice-crop to the frame.
- `track` — `left` / `right` (the two lanes), or metres from the road centre (the depot has four tracks at ±1.75 and ±5.25).
- `camera` — where the photographer stands: `left` / `centre` / `right` (pavements at ±4.5 m) or metres.
- `size` — tram height as a fraction of frame height; sets the distance.
- `cx` — where the tram lands across the frame (0–1). The camera pans to put it there; the vanishing point moves with it.
- `tram` — `front`, `left`, `right`, `high`, `low`. Omit it and the angle follows the geometry (a tram on the far track seen from the near pavement shows its flank once it is close). `high`/`low` raise or drop the camera (`camH` in metres overrides).

Sequences are just recipes sharing an id prefix (`<seq>.<nn>`); the contact sheet groups on it.

`mixed.random.01…40` is a seeded batch (`tools/shapesynth/recipes_mixed.py`, seed 19) that pools every aspect, scene, sky, track, camera and tram angle with `size` log-uniform 0.08–0.75 and `cx` 0.15–0.85, numbered by the face's share of the frame — the mixed-scene corpus for shape-mation, where the tram is the one constant. Add to it with a new seed and prefix rather than re-drawing it: the ids are referenced from staged corpora. Known and kept as drawn: the batch sets `tram` explicitly by slot, and an explicit `tram` overrides `angleFor(Z)` (the flank the camera/track geometry would show), so in 17 of its 24 ground-level compositions (02, 04, 09, 15, 16, 19, 20, 25, 26, 29, 31, 32, 35, 36, 37, 39, 40) the drawn flank is on the wrong side for where the rails recede — `tram` (and the corpus's `viewpoint`) is the drawn label, not the photographer's position. A next batch should cycle only `high`/`low` by slot and let the camera/track draw label the ground views.

## Metadata (brief §5–6)

Each object carries `data-shape` — the tram-face polygon, the registration anchor — plus `data-width-m` and `data-ground-y`, which is all the composer needs to place any future object (a car, a person) the same way. Each composition root carries:

- `data-shape-bbox="x y w h"` — the face's bounds in frame px
- `data-margins="left top right bottom"` — negative space per side, as fractions of frame width/height
- `data-cells="…9 values…"` — overlap of the bbox with each 3×3 cell, row-major
- `data-cell` — the cell holding ≥95 % of the shape, else `mixed`

and a `<polygon data-role="shape">` (invisible) with the transformed face outline. `compositions/manifest.json` repeats all of it per file for tooling.
