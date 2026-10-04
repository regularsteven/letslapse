# Picture tiers — tile · poster · proxy · originals

**Raised:** 2026-10-03, Steven, in the preview discussion that followed his
eight-issue list · **Working mode:** code first, SVG mirrors after sign-off
(his standing answer) · **Status:** the server's contract is written —
picplace `docs/letslapse-picture-tiers.md`, commit `c43f970` (answers asks
1–6 and §A–§D, round 2, Steven's three decisions; push 1 in progress) —
and **stages 0–4 are built (2026-10-03, uncommitted; §9–§13)** — stage 0
the gate for `features.tiles` and the backfill at picplace.co, stage 1 the
working copy rendered and pushed by the holder, stage 2 the grid drawn
from the server's tile, stage 3 the batched sync and lazy posters against
push 2, stage 4 the working copy in the editor (Steven's Masks and Text on
previews), each bench-verified against picplace.test; stages 0–3 are on
Steven's Mac and iPhone 18 Pro since the evening. Stage 5 status and
space next · **Size:** large, six stages · **Read
with:** [connected-asset-states-plan.md](connected-asset-states-plan.md)
(§3 the capability question, §4.1 the preview page, T2/T6, D2 — which this
supersedes), [picplace-sync-v2-handover.md](picplace-sync-v2-handover.md),
[picplace-sync-cost-server-asks.md](picplace-sync-cost-server-asks.md) §A.

## 1. Decisions (Steven, 2026-10-03)

- **D1 The master stops before crop and overlays.** The proxy is the grade
  applied to the source, levelled, at the source's own pixel size — and
  nothing more. Crop, text, masks, mask grades and shapes stay records,
  applied on display. That is what makes it a working file: editing a mask
  on it never double-applies, and the "show a friend" picture is proxy +
  records, computed in milliseconds on any device.
- **D2 Tiles are bundled per capture-month bucket**, designed with the
  sync-cost index ask so a month is one request for its rows and one page of
  mints for its pictures. (The first build fetches per project through the
  batch mint — asks §B's bundle object, now a server job, only if that
  measures too slow.)
- **D3 HEIC for the proxy; the poster stays JPEG** (the web view's picture).
  Every client is Apple; HEIC decodes in hardware everywhere; Display P3
  survives for raw sources. The tile's format is the server's choice (JPEG,
  WebP or AVIF — the app decodes all three natively and reads the content
  type), since the server makes it (D7).
- **D4 The proxy is rendered on a settled grade edit and by a background
  sweep** on the device that holds the originals — never as part of the
  migration's clock, never by the server.
- **D5 The device reports the `proxy` presence tier** the server already
  defines, and the holdings pill gains a *working copy here* state.
- **D6 No proxy for an unedited display-referred source** (Steven's point):
  a JPEG, HEIC, PNG or stack blend whose grade is the identity for the
  proxy's recipe has no proxy — the original *is* the working copy, fetched
  through the originals path. A raw source always needs one (the engine's
  base look is not a no-op). A proxy appears when such a project is first
  edited and is deleted when its grade returns to the identity.
- **D7 The client renders the proxy and the poster; the server cuts the
  tile from the poster.** (Steven's push-back on a first draft that had the
  client make tiles, whose argument assumed tiles derive from the proxy.)
  The proxy is the grading engine's output and cannot be made elsewhere. The
  poster stays the client's first picture: it rides the records push in the
  first cycle on any network, raw-correct, 300 KB. The tile is a resize of a
  JPEG the server already holds, so it exists seconds after the poster for
  every project; the holder uploads nothing for it; a spec change (size,
  format, a bundle per bucket) is a server job rather than a fleet re-upload;
  and the same job pointed at the proxy or original later is the platform's
  own rendition pipeline for promoting photos without a LetsLapse client.
  The server has a database queue and GD 2.3.3 (JPEG in; JPEG, WebP, AVIF
  out) today; GD is not colour-managed, which a grid tile tolerates. Every
  rendition lives in object storage as an asset of its project, never on the
  application server's disk. No device downloads a tier it does not need.

## 2. What the app does today (2026-10-03, `be9d092`)

The facts the stages build on, with where they live:

- **One rendition.** `PicPlacePoster.ensure` renders `poster.jpg` at 1280 px,
  JPEG 0.7, through `PhotoGrader.render` with `cropped` defaulting to true
  (`App/PicPlace/PicPlacePoster.swift:12-48`, `App/PhotoPreset.swift:286`):
  levelled, cropped, no overlays. Its token is
  `photoGrade.cacheToken + ProjectOrientation.keySuffix` (quarter turns baked;
  `PicPlaceController.swift:2219-2223`), stored as `PicPlaceSyncRecord.posterToken`
  (`PicPlaceSyncRun.swift:56`). It is rendered only inside a records push whose
  token differs (`PicPlaceController.swift:1913-1951`, from `thumbnailURL`,
  skipped when that "source" is the poster itself) — a settled edit
  (`PicPlaceAutoSync.pushDebounce` 20 s), the check's edited/new/retry rows, or
  the poster catch-up (`settlePosters`, `PicPlaceChangeSync.swift:588-636`,
  which lists `kinds: [preview]` 100 projects at a time and queues a push
  for any project PicPlace has no poster for).
- **The poster is classified by name.** `PicPlaceSyncPolicy.classify` turns
  `posterName` into `.object(kind: "preview")` (`:61, :92`); every file the
  registry marks `travels: false` is `.skipped("does not travel")` (`:91`).
  The registry entry is `ProjectFile(posterName, at: .root, class: .derived,
  travels: true)` (`Kit/Library/ProjectFileRegistry.swift:154`); nothing but the
  registry reads `.class`. The asset descriptor has no `heic` content type
  (`PicPlaceSyncRun.swift:836-848`).
- **The pull is eager and per project.** The first connection pulls every
  in-scope row (`PicPlaceLibrarySync.swift:242-252`); each check pulls new rows
  (`PicPlaceChangeSync.swift:349-353`). `pull(row)` is `GET projects/{uuid}`,
  one `POST …/assets/urls` for the bundle and the poster, the GETs, the poster
  written to the project root, presence `tier: "preview"`
  (`PicPlaceLibrarySync.swift:340-425`). 695 previews took 21.5 minutes on
  2026-09-18 under the 255/min budget.
- **A preview-only tile is cut from the poster.** `thumbnailURL` returns the
  poster when there is no media (`AppModel.swift:1613-1620`); the tile then takes
  `ProjectThumbnailCache.thumbnail(for:kind:)` → `imageThumbnail(…, maxPixelSize: 480)`
  (`ProjectMedia.swift:241`), disk-cached as JPEG 0.75 under `Thumbnails/`
  (1,284 tiles, median 55 KB, 66 MB on the Mac). The editor's preview page and
  the look-ahead read `previewPictureURL(for:)`, which is just `posterURL`
  (`ProjectAvailability.swift:213-215`; readers `EditorPreviewPage.swift:410`,
  `EditorLookAhead.swift:132`; `PreviewPictureCache` decodes it full-size).
- **One capability gates every editor page.** `.pixelEdit` → `holdings.pictureNeed`
  (`ProjectAvailability.swift:231-239`; Kit `ProjectHoldings.swift:178`); the
  preview page locks every tab but Editor and every group under it
  (`EditorPreviewPage.swift:449-456, 491-498, 524-534`). The plan's T6: the
  real editor is never mounted on a poster because its write paths assume a
  source — the 2 s persist (`PhotoViewerView.swift:1235-1241` →
  `setPhotoGrade`), the white migration, as-shot reads, the Lightroom
  sidecar (connected-asset-states-plan.md §4.1).
- **Overlays need no source pixels.** Masks, shapes and text are normalised
  over the levelled, uncropped frame (Kit `MaskShape.swift:41-53`,
  `ShapeRegister.swift:36-38`, `SceneOverlay.swift:16-24`); mask grades are
  display-referred on top of the finished grade
  (`SceneAwareCompositor.swift:393-409, 444-458`); their saves are JSON writes
  with no render (`PhotoViewerView.swift:4507-4531, 2542-2572`). What does read
  source pixels on those pages: Sky/Land segmentation (a 512 px render of the
  source, cached by the source's path + mtime, `SceneMaskStore.swift:28-35`),
  Find shapes (`ShapeFinder.representative`: newest blend image → blend clip
  mid frame → middle source frame, `ShapeFinder.swift:281-309`; decoded at
  1024/2048 px), the Lightroom sidecar, the detail loupe.
- **The identity grade exists.** `PhotoGrade.isIdentity = isColorIdentity && !hasRotation && !hasCrop`;
  `isColorIdentity = preset == .original && adjustments.isColorNeutral && timeline.isLookEmpty && !ownsWhite && !hasDeclaredWhiteBalance`
  (`App/PhotoAdjustments.swift:606-622`). `cacheToken` adds the engine version,
  keyframes, white and the render variant, and `adjustments.cacheToken`
  appends the crop (`:330-348, :790-798`). A flat JPEG carries its profile in
  the file, so an unedited one renders as its own pixels
  (`PhotoPreset.swift:1095-1096, :203`; Kit `GradeRecipe.swift:146-149`). A raw
  decode is `displayReferred: false` and goes through `baseCurve`
  (`LinearFrameDecoder.swift:242`, `ToneMath.swift:344`): a DNG's neutral is a
  look, not a no-op.
- **Presence is a boolean.** `tier = sourcesMissing ? "preview" : "original"`
  (`PicPlaceController.swift:1888`, `PicPlaceFetch.swift:182`,
  `PicPlaceLibrarySync.swift:419`, `PicPlaceFreeUp.swift:463`); `proxy` is read
  but never sent (`PicPlaceAPI.swift:115-141`). `ProjectHoldings.Tier` is
  `originals | blends | preview` (Kit `ProjectHoldings.swift:40-47`).
- **No generic evictable-derived-file notion.** `RemovalScope` is
  `originals | blends` (`PicPlaceFreeUp.swift:45-51`); the removal needs a
  poster and verifies each heavy file's hash against the server's confirmed
  list (`:300-317, :329-467`). The pill derives `originalsHere` from
  `holdings.tier == .originals` and draws `.here / .there / .nowhere`
  (`HoldingsPill.swift:32-43, 158-227`).

## 3. The model

### 3.1 The tiers

| Tier | Local file | Registry | Sync | Made by | When | Fresh when |
|---|---|---|---|---|---|---|
| tile | `Projects/<id>/tile.webp` (400 px long edge, WebP q75, `image/webp` — the contract; the registry's `tile.*` takes any extension the server chooses later) | `.derived`, does not travel | pulled only — never pushed (`role` → skipped "server-made") | **the server**, from the poster (asks §1; `origin: "server"`) | within a minute of a poster confirming, behind `features.tiles` | `renditions.tile.derived_from_sha256 == renditions.poster.sha256` (`PPRenditions.tileIsFresh`) |
| poster | `Projects/<id>/poster.jpg` (unchanged) | unchanged | unchanged | unchanged | unchanged | unchanged (SHA, `settleAssetCountMoves`) |
| proxy | `Projects/<id>/picture-<token>.heic` (the project root, beside the poster — the server stores names without a folder: `poster.jpg`, `tile.webp`, `picture-<token>.heic`) | `.derived`, does not travel | `.object(kind: "proxy")` — classified by name (`picture-*.heic`), not by the travels flag | the holder of the originals | on settle; the sweep, only at the server's revision | the token in its name equals `proxyToken` computed from the records here |
| originals | as today | as today | as today | — | — | — |

The 480 px local `Thumbnails/` cache stays for devices that hold the picture;
a device without it reads the tile. `previewPictureURL(for:)` keeps meaning
the poster; a new `workingPictureURL(for:)` means "full-size pixels I may
compose on": the originals' picture when here, else a fresh proxy, else nil.

### 3.2 The proxy's recipe

`PhotoGrade.proxyToken` is `cacheToken` with the crop removed: the same
string built from `adjustments.withoutCrop` (a copy with `crop = nil`), so
it still carries the engine version, preset, colour sliders, LUT, HSL,
dehaze, level (`rotationDegrees`), keyframes, white and the render variant.
The object name is `picture-<first 12 hex of SHA-256(proxyToken)>.heic`, kind
`proxy` (`PicPlaceSyncRun.proxyNameToken(for:)`, `ProjectFileRegistry.proxyPictureName(token:)`).

The render is the editor's own call with the crop off and no size cap:

```swift
PhotoGrader.render(url: picture, preset: grade.preset, adjustments: grade.adjustments.withoutCrop,
                   rotationDegrees: grade.rotationDegrees, whiteBalance: grade.whiteBalance,
                   maxDimension: nil, cropped: false)   // levelled, uncropped, source size
```

- **Picture** = `pictureNeed`'s file: a Photo capture's stack blend when it
  has one, else the photo; an interval shoot's poster frame (`thumbnailURL`);
  a video has no proxy yet (§6).
- **Encode** with ImageIO as `public.heic`, lossy quality 0.85, the bitmap's
  own colour space (Display P3 for raw, sRGB for sRGB sources — exactly what
  the grader hands back, `PhotoGrader.swift:366-371`). The DNG archive job's
  HEIC path (`ProjectDNGArchive.swift:28, :314`, `stillFormat.isAvailable`) is
  the availability check and the encoder pattern to copy.
- **Orientation** is baked after all (stage 1 found the render applies
  the project's quarter turns in the decode, as every surface does): the
  proxy is the upright, turned frame — the editor's own frame, which is
  also the frame overlays are stored in — and its token carries the turns
  suffix as the poster's does, so a Rotate 90° re-renders it (one small
  upload, a rare action). The asks doc's "never re-renders" line is
  superseded by this.
- **Memory.** A 48 MP RGBA bitmap is about 190 MB; the grader never caches
  full-size renders. One at a time on `MediaWorkQueue`, and both encodes
  (proxy, poster) from that one bitmap before it is released. The poster
  keeps its look by cropping the bitmap with `grade.crop` (the engine crops
  after level, so the result equals today's `cropped: true` render). The
  tile is never made here.

### 3.3 Who needs a proxy (D6)

`AppModel.needsProxy(for capture) -> Bool`:

| Source | Grade (proxy recipe) | Proxy? |
|---|---|---|
| raw (DNG, `ImportedStills.isRaw`) | anything | yes |
| JPEG / HEIC / PNG / stack blend | identity (`isColorIdentity`, no level, baseline variant) | **no** — the original is the working copy |
| JPEG / HEIC / PNG / stack blend | edited, levelled, keyframed, non-baseline variant | yes |
| flat JPEG (`captureFlat`) | identity | no — the profile is in the file |
| video | — | no (§6) |

`isIdentity` ignores the render variant and `cacheToken` includes it; the
rule uses the variant too, since a non-baseline variant changes pixels. Kit
tests pin the table.

On a device without the originals of an exempt project, `workingPictureURL`
is nil and the shortfall for `overlayEdit` is the originals' picture (one
file, its bytes) — today's originals download, nothing new. After that
download the device holds the originals (tier `original`), which is right.

### 3.4 Freshness, up and down

- **Up (the holder):** `PicPlaceSyncRecord` gains `proxyToken` beside
  `posterToken`. A records push renders whatever is stale and sends it as
  more items of the same negotiate: zero extra requests for a settled edit.
  The sweep (§4, stage 1) is for projects that have never had a proxy, and
  it pushes only when the sync record's `revision` equals the row's (the
  developer's race rule, Steven yes 2026-10-03): a settle push is at
  revision by construction, only the sweep can be behind, and a behind
  device's rendition negotiate on the batch path is refused per item with
  `stale_revision` + `current_revision` (the PUT's existing pair; `200` for
  the batch, the rest processed — the contract applies it to `preview`
  items on that path too, since a stale poster would overwrite the fresh
  one in place). The app pulls, re-renders and pushes again on that answer.
  Tiles are the server's; the holder never sends one.
- **Down (any device):** the index row's `renditions` (asks §2) say what
  PicPlace holds. The tile and poster compare SHAs as today. The proxy is
  fresh when the name's token equals `proxyToken` computed from the records
  the device holds — no server field, no sidecar. A stale proxy on disk is
  still shown on the preview page (with the status card saying *working copy
  from an earlier edit*) and the next fetch replaces it.
- **Deletion of a superseded proxy** rides ask 1's `replaces`; the local
  previous file is removed when the new one is written.

### 3.5 Capabilities and the prompt

`ProjectCapability` gains `overlayEdit`: `.nothing` when `workingPictureURL`
is non-nil, else `.needs(shortfall)` where the shortfall's kind is
`.workingCopy(bytes)` from the row's `renditions.proxy.bytes`, or `.originals`
for an exempt project. `FetchNoun` gains the words "the working copy". The
just-in-time prompt (`FetchPrompt.swift`) gains a third button when both are
possible: **Download working copy · 6 MB**, **Download originals · 62 MB**,
**Stay as is**. The `.notUploaded(device)` case keeps its sentence: a project
whose originals are only on another device has no proxy either until that
device renders one.

Pages and what they ask:

| Page / action | Capability |
|---|---|
| Text, Masks (draw, shapes, mask grades, Sky/Land), crop, Rotate 90° | `overlayEdit` |
| Find shapes | `overlayEdit` (the proxy is the representative) |
| the six tone groups, presets, white, level, keyframes, the Lightroom sidecar | `pixelEdit` (unchanged) |
| New blended clip, frames, archives, compress, `.lapse` | unchanged |
| a collection still from a photo | `overlayEdit` (the still is proxy + crop + overlays) |

### 3.6 The editor on a working copy

T6 stands: the real editor is never mounted on a *poster*. It **is** mounted
on a proxy, as `EditorAsset.workingCopy(url)` — the same page, rails, pads
and hooks, with the `pixelEdit` groups locked through the `locked` that
`EditorTabPill` / `EditorGroupBar` / `RailTabBar` already have — because a
second overlay host would be the Masks and Text pages rebuilt. The guard
list, each a one-line check on `asset.isWorkingCopy`:

- `persist()` writes the grade **only if** the only field that moved is
  `crop` (the proxy's token excludes it, so the proxy stays fresh); any other
  change is a programming error and logs an `ALARM`.
- the white migration, the as-shot reads and the Lightroom sidecar read do
  not run;
- Sky/Land renders its 512 px frame from the proxy, keyed by the proxy's
  path + mtime (`SceneMaskStore.frameIdentity`), so a fresh proxy re-runs it;
- `ShapeFinder.representative` gains `.workingCopy` after the blend sources
  and before the source frame; `ensureShapeRegister` names the representative
  from the record (`sourceWidth/Height`, the first source's relative path)
  rather than `mediaURL`, which is nil here;
- Rotate 90° turns records and the proxy's orientation suffix, renders no
  poster (the poster re-renders on the holder's next push);
- the detail loupe reads the proxy (full size, so it works).

The preview page mounts this editor in place when a proxy arrives, exactly
as it mounts the real editor when originals arrive today
(`EditorPreviewPage`'s hand-over).

### 3.7 Holdings, presence, pill, filters, space

- `ProjectHoldings` gains `hasWorkingCopy: Bool` (a fresh proxy on disk) and
  the presence tier becomes: `original` when the picture is here, `proxy`
  when a fresh proxy is here, else `preview`.
- The pill's originals glyph gains a place: *here* (green camera), **working
  copy here** (glyph: Steven's call — §7), *on PicPlace* (grey camera),
  *nowhere* (slashed). The Gallery's PicPlace filters gain *Working copy here*
  (`PicPlaceFilter`, `ProjectStatusStore` summary gains `hasProxy`).
- The PICPLACE card says *Working copy here · 6 MB* with a *Remove* that needs
  no server check (a proxy is re-fetchable), and Settings ▸ PicPlace ▸ free up
  space gains *Remove working copies not opened in 30 days* with the figure.
  `RemovalScope` gains `.renditions`. Tiles are never removed by a person;
  they go with the preview on eviction.
- The project's last-opened date for that rule lives in the sync record
  (`workingCopyUsedAt`), bumped when the editor mounts on the proxy.

## 4. Stages

### Stage 0 — foundations (small) — BUILT 2026-10-03, see §9

`PhotoAdjustments.withoutCrop`, `PhotoGrade.proxyToken`, `AppModel.needsProxy(for:)`,
the `heic` content type in `PicPlaceSyncRun.contentType`, the registry
entries (`tileName`, `picture-*.heic`) and `PicPlaceSyncPolicy.classify`
cases, `PicPlaceSyncRecord.proxyToken/workingCopyUsedAt`, and the
asset-count check that re-fetches a preview's records
(`PicPlaceChangeSync.swift:413`, `settleAssetCountMoves`) subtracting
server-made assets (`origin: "server"` in listings, `assets.server` or the
`renditions.tile` pointer on the row) — the build that must ship before the
server's tile backfill runs on picplace.co (Steven, 2026-10-03). Kit
tests: the D6 table, token excludes crop, classification. No behaviour
change. *Done when* the tests pass and a records push still sends exactly
what it sends today.

### Stage 1 — renditions on the holder (medium) — BUILT 2026-10-03, see §10

`RenditionRenderer.make(for:)` — one full-size render, two encodes, the
sizes and milliseconds logged (`renditions: <id> proxy 6.1 MB 1.8 s · poster
312 KB`). Hooked where the poster renders inside a records push
(`PicPlaceController.swift:1913-1951`): render what is stale by token, send
it as more negotiate items. The sweep: `PicPlaceAutoSync.runProxyQueue`
beside the blends queue — bound library, originals here, `needsProxy`, no
fresh proxy on the server, the record at the row's revision, newest first,
Wi-Fi, and on iOS charging (a
full-size render per project is GPU and heat; the Mac on mains runs any
time). Per-project pushes until asks §2 lands (the existing cycle; correct,
slow). Hooks: `LL_RENDITIONS=render:<latest|uuid>` (write the proxy and the
poster locally, no server), `LL_RENDITIONS=sweep` (one pass). *Done when* a
settled DNG edit on the Mac bench pushes poster + proxy in one cycle (the
trace shows one negotiate with two new items) and an unedited JPEG project
pushes the poster and no proxy.

### Stage 2 — tiles in the app (small) — BUILT 2026-10-03, see §11

The pull writes the server's tile beside the poster when the row has one
(`tile.<ext>` from the content type); `ProjectThumbnailCache` reads the tile
for a project without a picture here (else cuts from the poster, as today);
`AppModel.tileURL(for:)`. Measure the tile's bytes over the Mac library once
the server's backfill has run. *Done when* a preview-only Simulator grid is
drawn from tiles and the `Thumbnails/` cache stops growing with posters.

### Stage 3 — batched sync (medium; asks 1–3, with fallback) — BUILT 2026-10-03, see §12

Push 2's shapes to write against (the contract, plus the developer's two
details): every batch negotiate item carries `project` and `name` on errors
as well as successes; a confirm that retired an old proxy answers with
`replaced: { id, name }`; `stale_revision` + `current_revision` per item,
`200` for the batch; `storage.renditions` and `libraries[].renditions` in
`/status`; `bucket` on the PUT and `GET /projects?bucket=`. Deploys to
picplace.co on Steven's word.

Behind `features.rendition_batches`: the sweep negotiates and confirms 100
proxies per request; the first connection runs a **tiles pass** — rows
(bucketed when sync-cost §A lands) → `POST /assets/urls` in pages of 100 →
GETs, eight-wide — and pulls posters **lazily**: on open, with the pager's
look-ahead of both neighbours, through `fetchPoster`'s gate. `settlePosters`
retires when `renditions` pointers exist. Without the asks: today's eager
poster pull and per-project cycles stay, and tiles are cut from posters on
arrival. *Done when* the sync-cost bench shows a 101-project first
connection at about 1 + 2 + 101 GETs for tiles instead of 303 API requests,
and `LL_PICPLACE_TRACE=1` counts match the asks doc's arithmetic.

### Stage 4 — the working copy in the editor (large; stage 1) — BUILT 2026-10-03, see §13

`overlayEdit`, the shortfall, the third button, `PicPlaceFetch.fetch` with
kind `.proxy`, `EditorAsset.workingCopy`, the §3.6 guards, Sky/Land and Find
shapes on the proxy, crop as a record on a working copy, collection stills
from it, Shape-mation's representative. **This is where Steven's issues 2
and 5 of 2026-10-03 (Masks and Text on a preview) land — on the proxy, not
the poster, so the crop mapping the poster would have needed never exists.**
Hooks: `LL_DROP_SOURCES=<uuid>:originals:keep-proxy` stages a working-copy
project with no server; `LL_PREVIEW_PROMPT=masks:working` presses *Download
working copy*. *Done when* the two-device bench round-trips: the Mac (DNG)
grades and settles → the Simulator pulls, opens Masks, downloads the working
copy, draws a mask and a text box → the Mac pulls the records and exports →
the text box's corner lands on the same normalised point in both (a pixel
check from `LL_DUMP_ORDER`'s sibling, `LL_DUMP_OVERLAYS=1`).

### Stage 5 — status and space (medium; stages 1–2) — BUILT 2026-10-03, see §15

`hasWorkingCopy`, the `proxy` presence tier, the pill state, the filter, the
card line, free-up-space's `.workingCopy` scope with the 30-day rule,
`/status`'s renditions figure on the Settings card. *Done when*
`LL_PILL_SHEET=1` draws the new state and `LL_PICPLACE_REMOVE=<uuid>:workingcopy`
removes a proxy and the card falls back to *Preview only* with the download
offer.

### Stage 6 — later

Video proxies (H.264 ≤ 720p, `proxy/clip-<token>.mp4`, the ProRes → H.264
code exists); reading tile bundles per bucket if the server builds them
(asks §B, only if the tiles pass measures too slow).

## 5. Hooks and testing

New: `LL_RENDITIONS=render:<latest|uuid>|sweep`, `LL_DROP_SOURCES=…:keep-proxy`,
`LL_PREVIEW_PROMPT=<page>:working`, `LL_DUMP_OVERLAYS=1`,
`LL_PICPLACE_REMOVE=<uuid>:workingcopy` (`renditions` still answers),
`LL_PICPLACE_FREEUP=copies`, `LL_PICPLACE_FILTER=workingCopyHere` (stage 5).
Existing that carry the work:
`LL_PICPLACE_TRACE=1` (request counts), `LL_PICPLACE_DRYRUN` (lists the
renditions it would send), `LL_PILL_SHEET=1`, `LL_PICPLACE_FILTER`,
`LL_DUMP_PILLS=1`. Benches: `tools/sync-cost-bench/` gains a tiles-pass count
and a renditions column in its data pack; the two-device bench recipe in
connected-asset-states-plan.md §9 with `LL_PICPLACE_TOKENS` always. Rules
that stay: test sync only on throwaway projects; a bench root bound to an
account always launches with `LL_PICPLACE_TOKENS`.

Kit tests: `proxyToken` ignores crop and tracks level; the D6 table;
`classify` for `tile.heic` and `proxy/`; the bucket key from a local date.

## 6. Mirrors owed after sign-off

The fetch prompt's three-button state (components), the holdings pill's new
state (`components/holdings-pill.make.py`), the Gallery sidebar's filter row,
the PICPLACE card's *Working copy here* line and its Remove, the free-up-space
sheet's third scope, the preview page's status card wording. Per-platform
INDEX rows as the design README requires.

## 7. Decisions for Steven (open)

1. **The pill glyph for "working copy here".** The camera is the originals'
   glyph; a working copy is a picture, not a camera. Suggested: `photo.fill`
   in green, with the camera grey beside it, so "here" and "originals
   elsewhere" read in one glance.
2. **Proxy quality** 0.85 (about 6–10 MB at 48 MP) or 0.9. The mask grades
   compose on it display-referred, so banding in deep shadows is the risk at
   lower quality. Suggested 0.85, measured in stage 1.
3. **The iOS sweep policy**: charging + Wi-Fi (suggested), or Wi-Fi alone.
4. **Posters lazy on open** (stage 3): a tile-upscaled moment before the
   poster lands on first open. Suggested yes; the look-ahead hides it for
   neighbours.
5. **The tile size to ask the server for**: the phone's 3-column grid at 3×
   is about 390 px; the Mac at two columns wants the poster anyway. The asks
   say 400 px; a second, larger tile later is a server job, not an app one.

## 8. Numbers (2026-10-03)

| | Today | With the tiers, 100,000 projects |
|---|---|---|
| bytes to hold a gallery of previews | 317 KB median per poster → 37 GB | ~15–25 KB per server-made tile → ~1.5–2.5 GB; posters on open only |
| API requests for a first pull | 3 per project → 300,000 | ~2,000 (tiles pass with asks 2–3) + storage GETs |
| storage GETs for a first pull | 2 per project | 1 per project, eight-wide; ~30 min at 150 ms |
| working copy of a raw photo | the 60 MB DNG | a 6–10 MB HEIC |
| working copy of an unedited JPEG | the JPEG | the JPEG (D6) |
| render cost on the holder | one 1280 px poster | one full-size render, two encodes, raw or edited projects only; the sweep spreads old projects over days |
| tiles | cut on each device from posters | cut once on the server from posters; a few hours of one core at 100,000 |

## 9. Stage 0 — what landed (2026-10-03, uncommitted)

Built the same day the server's contract was written, against its names.
Mac Debug build and iOS Simulator build clean; Kit tests green (the two new
ones below). Not yet on a device: **this is the build the production tile
backfill waits for** — Steven installs it and tells the developer.

- **The gate.** Every count the app compares with what it last saw is of
  what devices pushed: `PPProject.Assets.server` and `clientConfirmed`,
  `PPAsset.origin` / `isServerMade` / `derivedFromSha256` / `contentType`,
  `[PPAsset].clientMade`; the check's count-move test
  (`PicPlaceChangeSync.swift` ~:413), `settleAssetCountMoves`, `pullUpdate`,
  `fetchPoster`, the library pull and free-up's listing all read the
  client-made set, so a tile the server cuts never reads as "something to
  fetch" and no preview-only project re-fetches its records when the
  backfill runs.
- **The row and the flags.** `PPRenditions` / `PPRendition` on the index row
  (`tileIsFresh`), `PPStatus.Limits.renditionKinds`;
  `PicPlaceController.serverHasRenditions / serverHasTiles /
  serverHasRenditionBatches / serverRenditionKinds` read from `/status`.
  Nothing acts on them yet (stages 2–3); every path keeps today's behaviour.
- **The names.** `ProjectFileRegistry.tilePattern` (`tile.*`) and
  `proxyPicturePattern` (`picture-*.heic`) at the root, `.derived`, never
  travelling; `isTile(fileName:)`, `isProxyPicture(fileName:)`,
  `proxyPictureName(token:)`. `PicPlaceSyncInventory.role` decides both
  before the travels guard: a tile is skipped ("server-made"), a proxy is
  `.object(kind: "proxy")` (`proxyKind`). `contentType` knows `heic`/`heif`,
  `webp`, `avif`.
- **The recipe and the rule.** `PhotoAdjustments.withoutCrop`,
  `PhotoGrade.proxyToken` (the cache token with the crop left out),
  `PicPlaceSyncRun.proxyNameToken(for:)` (SHA-256, twelve hex); Kit
  `ProxyRule.needsProxy(sourceIsRaw:colourIdentity:hasLevel:baselineVariant:)`
  and `AppModel.needsProxy(for:)` on top of `pictureBlend` /
  `sourceFrameURLs` / `photoGrade` (a video never; a Photo capture's stack
  is display-referred). `PicPlaceSyncRecord.proxyToken` and
  `workingCopyUsedAt` (optional; old sync-state files decode unchanged).
- **Tests.** `ProjectFileRegistryTests.testPictureTiersAreRegisteredAndNeverTravel`,
  `ProjectHoldingsTests.testProxyRuleFollowsTheTable`.
- **Not done, by design:** nothing renders, pushes or pulls a tier yet;
  `bucket` on the PUT waits for push 2 (stage 3); the Kit file list trap —
  no new Kit file was added (`ProxyRule` lives in `ProjectHoldings.swift`),
  `Kit/Package.swift` touched anyway.

## 10. Stage 1 — what landed (2026-10-03, uncommitted)

Built the same afternoon as stage 0 and run end to end against
picplace.test on a throwaway library of the `synth` account (two of Steven's
projects copied into a scratch root, tombstoned after; token revoked).

- **The render.** `PicPlaceProxy` (in `App/PicPlace/PicPlacePoster.swift`):
  `ensure(sourceURL:grade:nameToken:in:)` renders the picture through
  `PhotoGrader.render` with `adjustments.withoutCrop`, no size cap and
  `cropped: false`, encodes HEIC at 0.85 with ImageIO in the grader's own
  colour space, writes `picture-<token>.heic` at the project root and removes
  any other copy; `removeAll(in:except:)`; `existing(in:)`. Measured on the
  M4 Max: a 48 MP DNG → 6048×8064 Display P3, 5.2 MB, 1.4 s; a 4K LUT-graded
  JPEG → 2160×3840 sRGB, 1.2 MB, 0.1 s.
- **The token.** `PicPlaceController.currentProxyToken(for:)` =
  `photoGrade.proxyToken` + the orientation suffix (§3.2, corrected); nil when
  `needsProxy` is false or the picture is not here. Stored as
  `PicPlaceSyncRecord.proxyToken` with the poster's bookkeeping (set after a
  run, kept across a `.blends` run).
- **The push.** Inside the records push, beside the poster: a project that
  needs a copy gets one rendered when the file for this token is not there;
  an exempt project's stale copy is removed. The walk then classifies the
  file as `.object(kind: "proxy")` and the ordinary cycle carries it — the
  bench trace of the DNG project's first push: one `PUT projects/…`, one
  negotiate with three items, three storage PUTs (`records.aar`,
  `poster.jpg`, `picture-13297a07774b.heic` 5,247,020 bytes), one confirm.
  The server's rows afterwards: `proxy picture-13297a07774b.heic image/heic
  5247020 confirmed`. The exempt JPEG pushed `poster.jpg` + `records.aar`
  and nothing else.
- **The sweep.** `scheduleProxyQueue(force:)` / `runProxyQueue()` in
  `PicPlaceAutoSync.swift`, kicked after every check beside the blends queue
  and after a send run: newest first, originals here, `needsProxy`, the
  record in step by revision, `record.proxyToken != token`; a copy another
  device sent is read off `serverRenditions[origin]?.proxy?.name` (push 1)
  and noted without a render; otherwise `syncAndWait(capture, policy:
  .minimal)` one project at a time under `proxyRendersAllowed`
  (`heavyChecksAllowed`, and on iOS the charger). Bench: with the record's
  `proxyToken` wiped, the launch check's sweep sent the project in one cycle
  of five requests — claim, PUT, negotiate (the copy came back held by hash,
  no transfer), presence, unclaim — and the token was back on the record.
- **Rows at every check.** `serverRenditions[origin] = row.renditions`
  in the scoped merge loop.
- **Hooks.** `LL_RENDITIONS=render:<latest|uuid>` (the poster and the
  working copy into the folder, no server; the log line has size and time,
  or "is its own working copy (D6) — no proxy" with the stale copy removed),
  `LL_RENDITIONS=sweep` (one forced sweep; ignores the charger rule, for the
  Simulator, which reports no battery).
- **Seen on the way.** picplace.test already cuts `tile.webp` (22 KB) for
  Steven's test-account projects: the server's push 1 is live there (and
  on picplace.co from the evening, `features.tiles` off). Its
  `renditions.proxy` pointer stays `null` for a confirmed `proxy` asset
  (reported to the developer); the sweep then re-negotiates a held copy by
  hash — cheap, not wrong — until it is filled. The app logs the tier flags
  and a pointer tally once per change (`picplace: picture tiers on …`,
  `picplace: renditions on PicPlace for N row(s) — …`). A
  project whose uuid belongs to another account answers the PUT with `409`
  and the app re-keys it (the existing conflict path) — a bench artefact of
  copying real projects onto the `synth` account, not a stage 1 matter.
- **Not done, by design:** the proxy is a second render beside the poster's
  (the plan's one-bitmap pass can follow if it measures; today the poster
  path is untouched). A stale copy on the server of a project that became
  exempt is left for stage 3's `replaces`. No device run yet: the settle push
  on a phone renders a full-size copy on battery by design (one edit, one
  render); only the sweep waits for the charger.

## 11. Stage 2 — what landed (2026-10-03, uncommitted)

The server's tile beside the poster, on every path that brings a poster, and
the grid drawn from it. Bench: device A pushed the DNG project to a fresh
library, the server's `RenderTileJob` cut `tile.webp` (22,008 bytes, 300×400,
`derived_from_sha256` = the poster's) and the row then carried all three
pointers; device B linked the library, pulled the preview in one
`GET projects/{uuid}` + one mint of three URLs + three GETs, drew its grid
"from tile.webp (300×400)" with `Thumbnails/` at zero entries, and after
its tile and the record's SHA were removed the next launch check fetched it
back with one mint ("1 tile(s) fetched, 22008 bytes"). Tombstoned after;
token revoked; library row removed.

- **Fetched with the poster.** `PicPlaceController.freshTile(in:poster:)`
  picks the confirmed, server-made `tile.*` whose `derived_from_sha256`
  equals the poster's `sha256` (the contract's rule; a tile of an earlier
  poster is ignored and the grid cuts the poster until the job catches up).
  The library pull, `pullUpdate` and `fetchPoster` mint its URL with the
  poster's and write it under the server's name (`writeTile`, which removes
  any other `tile.*`; `removeTiles` when the row has no fresh one).
  `PicPlaceSyncRecord.tileSHA256` remembers what was written.
- **Caught up by the check.** A preview whose row's `renditions.tile` is
  fresh and differs from `tileSHA256` is queued (up to 100 per check) and
  fetched after the pass by `settleTiles` — one `POST …/assets/urls` and one
  GET each, the poster's cut dropped from the thumbnail cache so the next
  draw takes the tile. This is the per-project fallback; stage 3's
  cross-project mint (asks §2) turns a 100,000-library's tiles pass into
  1,000 requests.
- **Drawn from.** `ProjectThumbnailCache.thumbnail(for:kind:)` substitutes
  the tile for a request that names the poster (`tileSubstitute(for:)` →
  `ProjectFileRegistry.tileURL(in:)`, which looks for `tile.webp`, `tile.jpg`,
  `tile.avif` in that order), keys the memory tier by the tile's own path
  and date, and never writes it to the disk tier. Every grid, list and
  picker that asks for a preview's poster at 480 px gets the tile; the hero
  and the pager still read the poster through `displayImage` /
  `previewPictureURL`. `AppModel.tileURL(for:)` for the readers to come.
- **Log.** `LL_TILES_LOG=1` (DEBUG) prints one `thumbnail: <id> drawn from
  tile.webp (W×H)` per tile served in the process.
- **Not done, by design:** tiles are never pushed (`role` skips them); a
  project whose picture is here keeps its local 480 px cache; the
  originals-holding device fetches no tile. The server's `renditions.proxy`
  pointer, null in the stage 1 bench, was a server bug (the newest-proxy
  lookup's kind filter sat on the outer query, so a records or poster
  confirm after the proxy hid it); fixed in picplace.test's working tree
  before the stage 2 retest, on picplace.co with push 2. The pointer is
  computed at read time and is right the moment the proxy confirms — the
  sweep's "another device sent it" check can trust it.

## 12. Stage 3 — what landed (2026-10-03, uncommitted)

Against push 2 on picplace.test (live on picplace.co the same evening,
`96cc072`). Bench: a throwaway library of the synth account with ten
imported JPEGs given presets (every settle push carried its working copy:
10 × one negotiate with records + poster + proxy, 20 storage PUTs), the
server's tile job run, then a second device. Tombstoned after; token
revoked; library row removed.

| Check | Requests |
|---|---|
| sweep, ten stale copies PicPlace already held (`LL_RENDITIONS_SALT`) | **1** `POST assets` — every item confirmed at once, `replaces` retired the old copy at negotiate (one proxy per project afterwards, the row's pointer on the new name) |
| sweep, ten copies PicPlace lacked (its proxy rows deleted) | **3** API requests: `POST assets`, 10 storage PUTs, `POST assets/confirm` — the contract's "done when" |
| device B's first connection, ten previews | 10 `GET projects/{uuid}` (the manifests), **1** `POST assets/urls`, 20 storage GETs (bundle + tile; no poster), 10 presence — was 3 API requests and 2 GETs per project |
| device B's grid | drawn from ten tiles, no poster on disk, `Thumbnails/` empty |
| a project opened on device B (`LL_ITEM`) | its poster alone fetched on open: 1 `GET projects/{uuid}`, 1 mint, 2 GETs; the other nine stay poster-less |
| ten tiles removed on device B | caught up at the next check: **1** mint, 10 GETs |

- **The batch primitives.** `App/PicPlace/PicPlaceRenditionBatch.swift`:
  `PicPlaceRenditionItem`, `sendRenditions(_:)` (negotiate → PUT → confirm in
  pages of 100, per-item `RenditionOutcome`: `held` · `uploaded` ·
  `staleRevision(current:)` · `failed`), `putRendition` (the presigned PUT
  with `PicPlaceTransfer`'s retries), `mintRenditionURLs(_:)` (`POST
  assets/urls`, any kind, any projects), `bucket(for:)` (`YYYY-MM` in the
  person's calendar). Wire shapes: `PPNegotiation.project/name/currentRevision`,
  `PPConfirmResult.project/replaced`, `PPRenditionsFigure` on
  `PPStatus.Storage` and `PPLibrary`, `PPProject.bucket`.
- **The sweep on the batch path** (`runProxyQueue`, behind
  `features.rendition_batches` and `limits.rendition_kinds` ∋ `proxy`):
  render one at a time as before, then a hundred per `POST assets` with
  `replaces` = the row's current proxy id when its name differs; `held` and
  `uploaded` set the record's token; `stale_revision` is logged and left
  for the next check's pull. A batch whose rules moved while rendering is
  dropped unsent — the files stay by name, so no render is repeated.
- **Tiles in pages.** `settleTiles` mints a hundred URLs per request and
  takes up to 1,000 tiles per check (100 per project-minted before).
- **The pull in two halves.** `planPull` (the row's detail and manifest,
  which assets) · `completePull` (the bytes) · `pullPage` (a hundred plans,
  ONE mint, the bytes) — the first connection pulls in pages; the check's
  new rows still one at a time. **Lazy posters:** a plan with a fresh tile
  leaves the poster for the day the project is opened
  (`fetchPosterOnOpen`, called by the preview page once its tile is on
  screen and by the pager's look-ahead for a neighbour; the check's own
  poster fetch skips a project that has a tile). `thumbnailURL` falls back
  to the tile when the poster is absent, so grids, lists, the hero and the
  preview page have a picture; `ProjectFileRegistry.isFinishedPicture` makes
  a tile an already-graded picture everywhere the poster was one
  (`ProjectThumbnailView`, the pager's poster, the push's render source,
  `currentProxyToken`) — the second-device run showed a preset's project
  grading its tile a second time until it did.
- **Posters without the listing pass.** With `features.renditions` the
  check reads `renditions.poster` off the row to note or queue a poster;
  `settlePosters` stays for a server before pointers.
- **`bucket` on every PUT** from push 2 (`PicPlaceSyncRun.Project.bucket`,
  sent when `features.rendition_batches`). `storage.renditions` is read into
  `serverRenditionsFigure` for stage 5's card.
- **Hooks.** `LL_RENDITIONS_SALT=<s>` (DEBUG) makes every working copy
  stale under a new name — the bench for a re-render and `replaces` (what an
  engine-version bump does for real). The bench recipe is in
  `picplace-picture-tiers-server-asks.md`'s night entry.
- **First run on real devices (2026-10-03, 20:30).** The Mac and the
  iPhone 18 Pro, both on Steven's production library: the two log lines
  read `rendition pointers on, tiles off, rendition batches on (preview,
  proxy)` and `renditions on PicPlace for 1654 row(s) — posters 1596 ·
  tiles 0 · working copies 0`; the Mac's sweep sent two copies (the two
  projects the bench had used), the phone's check queued 116 pushes and
  rendered 12 MP copies at about 1.5 MB and 0.2 s each, one every 1.5 s.
  Added on seeing it: `proxyRendersAllowed` stands down at thermal
  `serious` or `critical` (a phone on a charger rendering back to back).
- **Not done, by design:** the tiles pass is not yet bucketed
  (`GET /projects?bucket=` waits for sync-cost §A's feed); storage GETs run
  one after another (eight-wide can follow if measured); a project opened
  before the handshake waits up to ten seconds for the session before
  fetching its poster.

## 13. Stage 4 — what landed (2026-10-03, uncommitted)

The real editor on a working copy. Bench, the scratch library on the Mac:
the DNG project (a LUT grade) with its working copy and its originals
dropped (`LL_RENDITIONS=render` then `LL_DROP_SOURCES=…:originals`) opens
the editor on `picture-13297a07774b.heic` straight from the Gallery
(`LL_ITEM=<id>:masks`): the Masks page over the graded picture, Sky and
Land segmented from the copy, Find shapes offered; the write probe
(`LL_WC_PROBE=1`) put a radial mask in `overlays.json` through the real
path and a square crop on the grade with every other field — LUT, sliders,
preset state, level — byte for byte as before, `modifiedAt` bumped so the
edit syncs. Two devices on picplace.test: A pushed the project with its
copy; B pulled the preview, opened its Masks page, took **Download Working
Copy** on the prompt (`LL_PREVIEW_PROMPT=masks:working`) — one project
read, one mint, one 5.2 MB GET — and the editor mounted on it in place.

- **The asset.** `EditorAsset.workingCopy(URL)`; `stageEditor` opens the
  editor on it when the originals are not here and a fresh copy is
  (`AppModel.workingCopyAsset`), every switch over the asset knows it (the
  iOS cover, the Mac window, the item view, the pager's trace, the project
  screen's Edit pill and hero, the look-ahead: nothing ahead for now).
- **The model.** `proxyRecipeToken(for:)` (one place for the holder's token
  and the device's expectation, the DEBUG salt inside), `expectedProxyName`,
  `workingCopyURL` (the copy here only when its name is the records'),
  `workingPictureURL` (the originals' picture, else the copy), `ProjectCapability.overlayEdit`
  (available with a working picture; otherwise the originals' shortfall,
  which the prompt offers beside the copy), `ProjectHoldings.hasPreview`
  counts a tile.
- **The editor** (`PhotoViewerView.isWorkingCopy`, by the file's name):
  the picture is the copy decoded at the preview size and composited with
  the overlays, the compositor told the level is in it; the frames window
  is one picture; no white migration, no as-shot reads, no Lightroom
  sidecar, no detail patch; Sky/Land read the copy as it is; Find shapes
  and a new register name the project's first frame and decode the copy;
  `persist()` writes the stored grade back with only the crop moved; the
  group bar greys every group but Crop (`EditorGroupBar.lockedGroups`) and
  a tap on one asks for the originals (`.fetchPrompt`), after which the
  editor on the originals replaces this one in place; the crop group hides
  the Angle slider (`PhotoAdjustmentsPanel.hidesLevel`). The seed logs
  `editor: working copy … — grade groups locked, overlays live`.
- **The door.** The preview page asks `overlayEdit` for Text, Masks and
  Crop (`Tapped.capability`), carries `workingCopyOffer` (the row's proxy
  pointer when its name is the expected one) and shows **Download Working
  Copy (N MB)** above the usual buttons, with a line in the message;
  `PicPlaceController.fetchWorkingCopy` reads the row again when the pointer
  in hand is not the expected one, mints, writes, removes other copies, and
  `checkArrival` mounts `.workingCopy` as it mounts `.still`.
- **Hooks.** `LL_PREVIEW_PROMPT=<page>:working`, `LL_WC_PROBE=1`; the
  Gallery's `LL_ITEM` hook now waits for the grid's rows and logs what it
  opens (`LL_ITEM: opening … on …` / `… is not in the grid`).
- **Seen once, not reproduced:** device B's grid tile of the pulled project
  showed a black vertical bar after its first pull; the server's tile
  decodes clean (ImageIO and GD alike) and draws clean when planted in the
  scratch library, and the poster A pushed is byte-identical to a clean one.
  Watch the 18 Pro's gallery for it; a truncated download is the one cause
  left that fits.
- **Not done, by design:** Rotate 90° stays on `pixelEdit` (a turn renames
  the copy, which the holder re-renders); the Frames page needs the
  originals; a stale copy on disk is not shown (the name must match);
  `request(.overlayEdit…)` from the Gallery panel's Text/Shapes buttons still
  offers the originals only (the page is the door); no device run yet
  (Mac and Simulator builds clean); the on-screen drawing could not be
  driven by `LL_DRAG` on the item view even with originals (a pre-existing
  limit of the hook, noted), hence the probe.

## 14. The first production night, and the proxy-count fix (2026-10-03, late)

Production took 518 working copies from the 18 Pro and 2 from the Mac in
six minutes (the developer's ledger: all verified, no duplicates,
`replaces` clean). Two things it showed:

- **130 manifest writes beside the sweep.** 116 were the day's new projects
  — the 18 Pro's launch check queued them and each first push carried
  records, poster and working copy in one negotiate (`uploading 3 of 3
  file(s)`), a manifest create each; the sweep itself went through the
  batch path (100, then 145 copies, no manifests). The rest are grades that
  moved or rows the pointers showed without a poster.
- **A working copy is a confirmed asset, so it moved every other device's
  count.** The check's "asset count moved" test re-fetched records AND
  poster for a project whenever a proxy landed on it — old builds and this
  one alike (the Mac: 600 `records fetched again` this evening; the other
  devices' old builds minted 887 poster URLs). Stage 0 had excluded only
  the server's tile. **Fixed:** `[PPAsset].accounted` (client-made and not a
  working copy) is what every `serverConfirmedSeen` counts and what the
  settle pass compares; `PPProject.accountedConfirmed` is the row's side
  (`clientConfirmed` less the proxy the pointers name); and the poster is
  kept by hash — `PicPlaceSyncRecord.posterSHA256` is recorded whenever a
  poster is taken, the settle pass compares it to the listing's without
  hashing, and `pullUpdate` leaves a held poster out of its mint and
  download (the developer's ask). Bench: device B pulled a project (seen
  2), device A's sweep added its copy (row: confirmed 4, server 1, proxy
  pointer set), B's next check read nothing for it — no listing, no
  project read, no poster GET.

Costs this fix stops: every proxy upload cost each other online device a
project read, a mint, the records and ~300 KB of poster; at the 18 Pro's
~1,700 projects that is about half a gigabyte per device, on Hetzner
egress. The fix is in the tree, Mac and Simulator builds clean; it reaches
the Mac with Steven's next Xcode run and the 18 Pro with the next install.

## 15. Stage 5 — what landed (2026-10-03, night, uncommitted)

Status and space, on the Mac build and the Simulator build; bench-verified
on picplace.test against a throwaway JPEG project in the `tiers-scratch`
root (library *tiers-s5* on the synth account).

- **Holdings.** `ProjectHoldings.hasWorkingCopy` and `workingCopyBytes`
  (Kit): the copy the records expect when the caller names it
  (`HoldingsInputs.workingCopyName`, the main actor's `expectedProxyName`),
  else any `picture-*.heic` in the folder — the status sweep's rule, which
  reads the document alone and cannot run the grade off the main actor (the
  white-balance track and custom presets are main-actor state). A device
  keeps one copy at most, so the two agree except in the moment after a
  remote re-grade. `presenceTier` on the holdings and `presenceTier(for:)`
  on the model: `original` · `proxy` · `preview` (D5); every presence post
  (push, download, removal, pull) reads it, and `fetchWorkingCopy` posts
  `proxy` after a fetch.
- **The pill.** `StatusGlyph.Asset.workingCopy` draws `photo.fill`, green
  when here, after the originals' camera and before the blends' layers;
  `HoldingsPillState.workingCopy`, set when the originals are not here and a
  copy is. VoiceOver: *Working copy here*. `LL_PILL_SHEET=1` draws three
  new rows — *Working copy here* (grey camera, green picture, tick cloud),
  *originals gone* (slashed camera, green picture), *downloading*. Steven to
  overrule the glyph on the sheet (§7.1).
- **The filter.** `PicPlaceFilter.workingCopyHere` after *On this device*;
  `ProjectLocalStatus.hasWorkingCopy` in the sweep's summary, whose
  signature now stamps the folder's own date too (a copy, poster or tile
  arriving moves it); the remembered file is version 2, so a version-1 file
  is walked afresh once. `LL_PICPLACE_FILTER=workingCopyHere` kept the
  project; `onDevice` left it out.
- **The card.** A preview-only project with a copy titles *Working copy
  here* with the green picture, keeps *The originals are on PicPlace · 1
  file · 2,9 MB* and *Download originals*, and gains a line — *Working copy
  — Here · 1,3 MB · text, masks, shapes and crop work on it* — with
  **Remove…** (`HeavyLine.Action.removeWorkingCopy`), its confirm *Remove
  Working Copy* and the note *The working copy comes back from PicPlace when
  you open the project to edit it.* `RemovalScope.workingCopy` has no
  heavy kind: `performRemoval` routes it to `removeWorkingCopy`, which
  deletes every `picture-*.heic` with no server check or claim (PicPlace
  holds the copy), refuses while the originals are here (the holder's own
  render), and posts the presence tier after. After it the card falls back
  to *Preview only* with *Download originals*.
- **Settings.** The *On PicPlace* row's subtitle adds *N MB of working
  copies and tiles* — the bound library's figure from `/status`'s
  `libraries[].renditions` when listed, else the account's. *Remove working
  copies not opened in 30 days* (`workingCopyIdleDays`) appears under the
  originals row with *N projects · about N MB* and its own confirm; the
  estimate (`refreshFreeUpEstimate`) lists each candidate folder's copies
  beside its heavy files and judges one stale when no source file is here
  and the record's `workingCopyUsedAt` is older than 30 days or missing.
  The clock is set by a fetch, by the editor mounting on a copy
  (`noteWorkingCopyUsed`, once an hour), and by an originals removal that
  leaves a copy behind (so a holder that frees its originals is not offered
  the copy's removal the same day). `removeStaleWorkingCopies` runs the
  copies through `removeWorkingCopy` as a free-up run (`Run.scope`,
  `Result.scope` word the rows).
- **The exempt copy on the server.** When a push finds the project its own
  working copy (D6) it removes any local copy and, with
  `features.rendition_delete`, retires the server's through `POST
  assets/delete` (`{"assets":[{"id":…}]}`, the developer's `0a33ec9`):
  `deleted` clears the pointer and the record's `proxyToken`;
  `stale_revision` is logged and tried again after the next pull.
- **Hooks.** `LL_PICPLACE_REMOVE=<uuid>:workingcopy` (`renditions` still
  answers), `LL_PICPLACE_FREEUP=copies` (waits for the estimate),
  `LL_PICPLACE_FILTER=workingCopyHere`; `LL_DUMP_PILLS=1` logs *Working
  copy here*. Kit test `testAWorkingCopyHereStandsInForTheOriginals`.

**The bench (picplace.test, 2026-10-03 22:51–23:05).** Vivid on the JPEG →
the push rendered `picture-674a27a7786c.heic` (2160×3840, 1,28 MB) and sent
it with the poster (*uploading 2 of 3, 1 already on PicPlace*); Upload sent
the 2,9 MB original; Remove originals left the copy, posted presence
`proxy` (read back from the server's table) and set the clock; the pill
logged *Download available · Working copy here · Backed up*; the card and
Settings photographed as above; the Settings removal freed 1,28 MB, posted
`preview`, and the card fell back to *Preview only* with *Download
originals*; the originals came back (presence `original`) and *Original*
made the project exempt — the push removed the local copy and `POST
assets/delete` answered `200`, *retired the working copy … the project is
its own now*, the server's `proxy` row gone. The fixture stays: the
`tiers-scratch` root bound to the synth account's *tiers-s5* library
(`b848a419`) with the JPEG fork `2C0ECD5B`; mint a fresh token per bench.

**Traps met.** (1) The first connection of a root to a *new* library evicts
a local preview the server has no row for — a `LL_DROP_SOURCES` project
made for a bench vanishes (folders and index rows only); bind a bench root
with `link:<uuid>` to the library its projects live in, or make the preview
after binding. (2) A project whose origin belongs to another account is
re-minted as a fork on first push (`409` → new id): the bench project's id
is the fork's, not the folder's old name. (3) `generic/platform=iOS
Simulator` builds x86_64 too and the codecs static library is arm64-only —
pass `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`, or name a Simulator device.

## 16. The second look at production (2026-10-03, late night) — three faults, fixed in code

Steven's Mac drew 21 preview-only projects with no picture and sat in
*Checking PicPlace…* for twenty minutes after launch; his 18 Pro's card for
one of them read *1 uploaded*, and the PicPlace web page had no picture.

1. **Records alone on PicPlace.** The 21 (shot on the 18 Pro 27–30.9,
   JPEG and HEIC photos, two DNG stacks from 23.8) went up as `records.aar`
   only; no poster, so no tile, and since stage 3 a pull takes the tile
   alone. The record on the phone said the push was done (`posterToken`
   stamped), so nothing ever sent the poster. Fixed: the check of a device
   that holds the originals clears the note when the row's
   `renditions.poster` is null and queues a poster push (once per 6 h per
   project, `posterResentAt`); a push whose poster render fails no longer
   stamps the token and logs `ALARM poster:`. Whether the 30.9 pushes
   negotiated a poster and lost the PUT, or never had one to send, is a
   question for the developer's ledger — the heal covers both.
2. **968 updated, 20 minutes.** A one-time migration: records written by
   the pre-count-fix build counted working copies in `serverConfirmedSeen`,
   the new accounting does not, so every project with a copy read as moved
   once. The next checks did 3.
3. **Three projects re-fetched every check.** A re-grade through the
   records push left the old working copy on the server — the per-project
   negotiate sent no `replaces` — and the row subtracts one copy by its
   pointer while a listing leaves every copy out, so the row's count and
   the listing's never agreed. Fixed: the push names the old copy
   (`Project.replacesProxy`, a plain retry on `replaces_not_found`) — and
   because the server's per-project negotiate drops `replaces` (probed with
   a direct call; asks doc, ask 7), the run then reads the project's detail
   and retires every other confirmed copy with `DELETE /assets/{id}` under
   its claim — and the move test compares the row with its own last count
   (`serverRowAccounted`), never the listing's.

Device install owed: the 18 Pro holds the 21 originals; its first check on
the new build should log *holds no poster … sending one again* 21 times,
then the Mac's check fetches their tiles once the server cuts them.

## 17. The level on display, and the finished picture (2026-10-04, morning)

Steven's two observations on the 18 Pro after freeing a photo's originals
(§16's night): the Angle slider had gone from the working copy, and an
overlay edit synced as a record while every picture that stands for the
project — the Gallery tile, the hero, PicPlace's page — went on showing the
photo without it.

- **The level is a record on display, like the crop.** D1 had the copy
  levelled; now `PhotoGrade.proxyToken` leaves the geometry out
  (`withoutGeometry`), `PicPlaceProxy.ensure` renders unlevelled, and
  `ProxyRule.needsProxy` no longer counts a level. A project with no level
  keeps the token it had, so nothing re-renders for the 1,362 copies on
  PicPlace; a levelled project's holder renders a new copy and retires the
  old. The editor draws a copy through `PhotoGrader.render` with
  `geometryOnly` adjustments (Original colour, the level, no crop cut) and
  hands the compositor the rotation as it does for originals; `persist()`
  writes the level beside the crop; the hero draws the copy through the
  level and the crop; `hidesLevel` is no longer set.
- **The finished picture** (`App/Overlay/FinishedPicture.swift`): the
  grade, the masked grades, the text and shape layers, the level, then the
  crop — the editor's order, through `SceneAwareCompositor.bakeStill` —
  from the originals' picture on a holder, or from the working copy through
  the geometry alone. The sky mask is taken from the cache or computed when
  a layer or a masked grade sits in the sky or the land and a segmenter is
  installed; custom masks and shapes resolve as the editor's preview set
  does. Three readers: the **poster** (`PicPlacePoster.ensure(finished:)`;
  the push gathers the inputs on the main actor, and `currentPosterToken`
  carries the overlay document's fingerprint, `overlaysSignature`, so an
  overlay edit re-renders the poster as a preset does), the **poster from
  the copy** (a device without the originals and with a working copy
  renders the poster from it on its records push — so an overlay or crop
  edit made there reaches every Gallery and PicPlace's page, which cuts the
  tile from it), and **the export** (`gradedExportCopy` renders the
  finished picture whenever the project draws anything or the source is a
  working copy, written through `PhotoGrader.writeJPEG` with the source's
  metadata; `saveGradedPhoto` falls back to the copy when the hero file is
  not here). Until now the poster and the export carried the grade and the
  geometry alone — on every device, not only the one without originals.
- **An overlay edit is an edit.** `setOverlayDocument` wrote the file and
  nothing else moved: a text layer or a mask reached PicPlace only with the
  next unrelated push, and the poster never. It now marks the project
  edited when the file's bytes changed (`markEdited`), so the records push
  and the finished poster follow it as they follow a preset.
- **Hooks.** `LL_TEXT=crafted` now stages its line on a single photo too.

**The bench (picplace.test, 2026-10-04 07:49–07:55, the JPEG fixture).**
Crafted text on the photo; the originals removed (presence `proxy`); a 3°
level written on the records; the editor on the copy opened on its Crop
group with the Angle slider back; the push rendered the poster FROM THE
COPY with the text and the level (302 KB) and sent it with the records —
the server's poster row renewed, the tile cut from it; a text edit alone
then marked the project edited and pushed (the poster unchanged, since
the overlay bytes were the same). Pictures: the scratchpad's M3-poster
and M3-level captures of the night.
