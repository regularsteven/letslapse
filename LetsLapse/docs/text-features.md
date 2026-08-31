# Text Features — build report

2026-08-31 · macOS Edit window · built from the Claude Design project
**Text Features** (`Text Features.dc.html`, handoff bundle). The spike
([text-overlay-spike.md](text-overlay-spike.md)) had shipped one text layer
with no typography and no bounding box, and said so on purpose. This build
implements the design that lifts all three limits, and adds the Masks tab
the design introduces.

## What the design asked for, and what shipped

| Design | Shipped |
| --- | --- |
| A list of text layers, front-to-back | `OverlayDocument.overlays` is ordered; **row 1 is the frontmost layer** and the compositor walks the array in reverse. Grip-drag reorder, per-layer visibility, onion skin, rename-by-editing-the-text. |
| Type fundamentals | Family (6 system faces), bold / italic / underline, alignment, five swatches, and a More… popover with kerning, line height and paragraph spacing. |
| Free vs Box, with auto-size | `OverlayLayoutMode`; a box wraps the type and can auto-fit it, solving **both axes** between Min and Max. |
| Bounding boxes on the preview | The selected layer draws a badge and an outline — solid accent for FREE, dashed amber for BOX with eight resize handles and an AUTO chip. |
| A Masks tab | `OverlayMasksPanel` — the project's regions, the semantic-mask tint, the analysis mode, the three dials, and hand-supplied custom masks. |
| Custom masks | Black-and-white PNG/JPEG copied into the project's `masks/` folder, with a name, an optional inverted name, and a once-per-project "Replace Sky & Land". |

Not shipped, and why: the design's font list includes a `Caacupe One
(uploaded)` face. There is no font-import path in the app, so the picker
offers six system families and the uploaded row is left out rather than
faked. Recorded in TODO.md.

## Traps worth keeping

- **A grown Codable schema silently eats the user's work.** Swift's
  synthesized `init(from:)` does *not* fall back to a property's default
  value for a missing key — it throws. `OverlayStore` treats a decode failure
  as "no overlays", so every field added past the spike's original five had
  to be `decodeIfPresent` or the first launch after the update would have
  read every existing sidecar as empty and then, on the next commit, deleted
  it. Both `SceneOverlay` and `TextOverlayContent` now hand-roll their
  decoders for exactly this reason.

- **A `CGBitmapContext`'s backing store is already top-left row-major.**
  `CustomMaskLoader` originally flipped its rows on the theory that CG's
  bottom-left origin meant the buffer came back upside down. It does not:
  CG maps y=height to row 0, so the memory is in the same order
  `SceneMask.pixels` documents. The flip inverted every custom mask — sky
  occlusion applied to the ground. Caught by drawing a mask with a
  deliberately asymmetric skyline, tinting it, and watching the magenta land
  on the wrong half; the notch profile in the tint is what confirmed the fix.
  **The tint is the test**: a symmetric mask would have hidden this.

- **Auto-size must not be solved against the render.** The preview is capped
  at 2000 px, and 1100 px mid-scrub. Fitting type against the actual render
  size would let the two pick different steps, and the type would visibly
  jump when a scrub landed. `resolvedSize(for:aspect:)` bisects against a
  fixed reference long edge, so the chosen size is a property of the layer.

- **A px readout has to name the delivered file.** The size label started out
  measuring against the preview render and therefore changed as you scrubbed.
  It now resolves against the capture's own `sourceWidth`/`sourceHeight`.

- **SF Symbol alignment names are lowercase.** `text.alignleft`, not
  `text.alignLeft`. The capitalized form does not resolve and renders as an
  empty button — which looks exactly like a layout bug.

- Onion skin and hidden layers are **editor-only and export-only**
  respectively: `composited(…, editorPreview:)` gates the first, and
  `makeOverlayExportBake` filters the second. An export carries neither.

- Deleting a mask, or a mask claiming "Replace Sky & Land", leaves layers
  pointing at a region that no longer exists. `pruneDanglingPlacements` drops
  those to None — rendering unoccluded in silence reads as a segmentation
  bug rather than a missing mask. `OverlayPlacement`'s decoder does the same
  for an unknown key rather than throwing the whole document away.

- A new project subfolder must be added to
  `ProjectArchive.transferableSubfolders` or it is sent over the wire and
  then deleted on arrival. `masks` is in the list.

## Verification

macOS, against the running app (`LL_EDITOR=latest LL_RAIL=text|masks`, a
1000×700 editor window, four seeded layers and one hand-drawn custom mask):
layer list and ordering, visibility, onion skin, per-layer disclosure, the
type row, the More… popover, placement pills including custom-mask names,
box chrome with handles and the AUTO chip, the Masks tab, and the mask tint
(which is what caught the orientation bug). iOS builds green; **none of it
has been exercised on a device** — the rail is 339 pt of macOS width and the
box handles are pointer-sized. Kit: 356 tests, 0 failures.

`LL_RAIL=text|masks|frames` was added with this build: the rail's pages are
otherwise reachable only by a tap, which a screenshot or a design-mirror
check has no way to make.

## Design mirrors

`docs/design/macOS/photo-viewer.text.svg` rebuilt, `photo-viewer.masks.svg`
new, and the four-tab rail regenerated across all four macOS editor specs.
The six iOS viewer SVGs remain stale — they were already owed, and the iOS
pass has to happen first.
