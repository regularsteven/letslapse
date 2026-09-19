# Shape-mation brief — gap map against the code

**Made:** 2026-09-19, from the developer brief filed verbatim at
[`brief.md`](brief.md), by an eight-reader map of the code (one reader per
brief section) → synthesis → completeness critic → three follow-up readers →
revision (14 agents, 588 tool uses, read-only). Paths are relative to
`LetsLapse/`. Line numbers are as of commit 9c27211.

**Checked by hand before filing** (the four claims the decisions rest on):
`DetectedShape.init(from:)` decodes `kind` strictly and `ShapeRegister.load`
collapses any error to `nil` with `try?`, and `ShapeFinder` then mints a
register over `existing?.keptShapes ?? []` — so a register an installed build
cannot decode is rewritten without its hand shapes; `Homography.apply` has no
`w ≤ 0` guard and `ShapemationPlan.make` maps the whole frame's corners
through the projective placement; `ShapeDetector.bbox` derives `hh` from
width-fraction axes and applies it as a y offset (axes are "a fraction of frame
width", centre is normalised per axis); `ShapemationRenderer` feeds each
written frame back as the next photo's background. All four are as described.

**How to read it.** The gap table is the inventory (EXISTS / PARTIAL /
MISSING per brief requirement, with the seam to build on). *Contradictions*
is where the brief and the shipped code or a recorded decision disagree — each
one needs a call before its work package starts. *Build sequence* honours the
brief's §9 (alignment + scoring first). *Open questions* carry a recommended
default each; the ones marked CONFIRMATION are already decided in `TODO.md`
and only need a nod.

**Headline.** The Kit already has the shape model, placement homography, size sorts and a stack renderer; what the brief adds is a library-level outline inventory with pose, stills in Collections with keyframed framing and a scrub, crop feasibility, 3×3 composition, alignment sort, and a synthetic corpus to score it all against.
**Three things the follow-ups overturned.** (1) An outline cannot be a new `Kind` in `shapes[]`: the strict enum decode (`ShapeRegister.swift:97` → nil at `:328`) makes every installed build strip hand shapes and sync the loss back, so a forward-tolerant register release (WP0b) precedes any outline and Q15 defaults to a separate `outlines` key. (2) WP0's "fix bbox" was not hygiene: `bbox` is the sole IoU primitive behind 15 gates at 5 thresholds and a fix is a detector-version-3 event — WP0 now adds a new correct `bounds(in:)` and leaves `bbox` alone. (3) The §4 scrub cannot ride a canvas-scale accumulator (measured 64 MB–8 GB per frame): photo collections render one photo per frame through a single-photo evaluator (decision b); Shape-mation keeps its stack bake and enters a collection as its mp4.
**Order stands (§9):** alignment + scoring first (WP0–WP3), then tween/feasibility (WP4b–WP7), UI last (WP8–WP10). Paths are relative to `LetsLapse/`.

## Gap table

### §2 Shape inventory + pose

| Requirement | Status | Build on | Work | Size |
|---|---|---|---|---|
| Baseline: what a shape is | EXISTS | `Kit/Sources/LetsLapseKit/Shapes/ShapeRegister.swift:12` DetectedShape (Kind :13, Source :27, init(from:) :94 — strict `kind` decode :97, decodeIfPresent defaults :96/:101-108 for MISSING keys only; fileName :234, load :323 — `try?` at :328 collapses any error to nil) | Nothing; extend DetectedShape. The tolerance idiom (also `MaskShape.swift:148-151`) covers missing keys, not unknown enum values. | S |
| **Forward-tolerant register decode + version gate, shipped BEFORE any outline (new, owed)** | EXISTS (WP0b, 2026-09-19) | `ShapeRegister.swift` header rule (:9-34), `formatVersion` :341, `foreignShapes`/`foreignFields` :356/:359, per-element `init(from:)` :378, `ReadOutcome` :466, `read` :504 (`version` probed first → `.tooNew`), `WriteRefused` :546 + `save` :567 (probes the DISK at the write, writes `formatVersion`); `App/Shapemation/ShapeRegisterLock.swift`; writers switch on it: `ShapeFinder.swift` inventory/`select`/`run`/`clearFoundShapes` + the capture-time registers, `PhotoViewerView.swift` (`shapeRegisterLock`, `ensureShapeRegister`, `persistShapeRegister` — a refused save becomes the lock), `LibraryIndex.upsertShapes` (a locked register counts zero, unstamped) | Shipped. Owed (docs/TODO.md 'Shape-mation WP0b'): the explanatory chip (design-first), the four SVG mirrors, a hook that stages a locked register, the Gallery's No Shapes row on a locked project, a runtime check of `ShapemationStore`'s foreign-record carry. | M |
| Forward-compat fixture tests | EXISTS (WP0b, 2026-09-19) | `Kit/Tests/LetsLapseKitTests/ShapeRegisterCompatTests.swift` (15: foreign element + keys through read → save → reload, too-new refused and untouched — at read AND at the write after the file changed underneath, unreadable, legacy no-`version`, re-save stamps `formatVersion`, `failure` round-trip, today's key set); `LibraryIndexTests.testLockedRegisterCountsZeroAndIsNotStamped` | Shipped. | S |
| Register save as an auto-sync cue | EXISTS (WP0b, 2026-09-19) | `App/AppModel.swift:1346-1349` onProjectWritten → noteProjectChanged (the only cue); `App/PicPlace/PicPlaceAutoSync.swift:182-190`, :275 revision gate; `App/PicPlace/PicPlaceController.swift:1426-1428`; `App/AppModel.swift:4598-4610` lastEdited/markEdited (no shape path calls it) | `markEdited` after every register save: `PhotoViewerView.persistShapeRegister`, `ShapeFinder.run` and `clearFoundShapes` (the capture-time registers ride registration's own stamp). | S |
| shapes.json transport (records bundle, .lapse, transfer) | EXISTS | `Kit/Sources/LetsLapseKit/Library/ProjectFileRegistry.swift:136` (travels), :174-176; `App/ProjectArchive.swift:64`; `App/AppModel.swift:10190-10195` installer; `App/PicPlace/PicPlaceSyncPolicy.swift:67-72`; `App/PicPlace/PicPlaceSyncRun.swift:427-441`; `App/PicPlace/PicPlaceChangeSync.swift:435-442` pull extract (overwrites, never deletes); `App/PicPlace/PicPlaceLibrarySync.swift:361-367` | Nothing; this is Q15's criterion: the representation must keep an ALREADY-INSTALLED build reading and not destroying the register. | S |
| Library-level store of kept shapes | MISSING | new — `App/LUTStore.swift:61` (folderName/indexName :84, importCube :118, reroot :65 wired at `App/LetsLapseApp.swift:110`), `App/StorageLocation.swift:38` libraryItemNames, `App/LUTLibraryAssets.swift:72/:122` | ShapeInventoryStore (<root>/shapes/ + index, UUID, reroot, libraryItemNames, materialise/adopt). | L |
| Vector outline geometry — representation by the installed-build criterion | MISSING | `ShapeRegister.swift:13` Kind (new case = strict failure on installed builds) vs :287-296 (unknown top-level keys ignored, :355 not round-tripped) vs `ProjectFileRegistry.swift:136/:174-176` (separate file); `ShapeGeometry.swift:86`; `ShapeDetector.swift:624`; 11 exhaustive Kind switches incl. `LibraryIndex.upsertShapes :465-468` | NOT `Kind.outline` in `shapes[]` without a two-release gap. Default (B) separate top-level `outlines` key (installed builds keep reading; their saves drop it — bounded, re-traceable); alt (C) `outlines.json` + registry entry (isolated, not carried by installed builds). Normalised point list + placement, bbox via bounds(in:), exemption in load's re-measure (:332-339), LibraryIndex/ShapeSummaryIndex row decision. | L |
| Inventory rows in the ＋ Shape menu | PARTIAL | `App/Overlay/OverlayMasksPanel.swift:142` shapeToolMenu (:61/:63); `App/PhotoViewerView.swift:302`, :2095, :2138, :2152, :2305 | Widen armed state to a template reference, rows/submenu, LL_SHAPETOOL + hint copy. UI, design question, Mac Masks mirrors. | M |
| Add = one action then position | PARTIAL | `App/PhotoViewerView.swift:3102` addFound + :2280 shapesBinding + `App/Overlay/RegisterShapeOverlay.swift:24` | Build from template at default centre/scale, append, select; existing handles position it. | S |
| Placed shape records POSE | PARTIAL | `ShapeRegister.swift:55-58`, :112 obliquity; `Kit/Sources/LetsLapseKit/NormalizedQuad.swift:184` n2/n3 discarded; `RegisterShapeOverlay.swift:24/:153` | Tilt/yaw fields (affine, decodeIfPresent fine for numerics), planeNormal for quads, tilt/yaw handles; ellipse pose ambiguous. | L |
| Foreshortening from the forward transform | PARTIAL | `ShapeGeometry.swift:11` Homography; `Shapemation.swift:130` un-tilt; `MaskShape.swift:49` | Compose the forward affine placement in pixel space; no projective constructor unless Steven picks projective. | S |
| Inventory shape as a mask | PARTIAL | `App/PhotoViewerView.swift:2360` useShapeAsMask (Radial only); `App/Overlay/SceneOverlay.swift:367` CustomMask; `MaskShape.swift:19` (linear\|radial); MaskShape is on the displayed frame (`MaskShape.swift:403-413`) — same frame as the register | Rasterise to masks/<uuid>.png or add an outline MaskShapeKind; `docs/TODO.md:1343` still owed. | M |
| Inventory management screen | MISSING | new — `App/ManagePresetsView.swift` + `docs/design/iOS/manage-presets.*.svg` (iOS/INDEX.md:409-413); host `App/Shapemation/ShapemationHomeView.swift`; `docs/design/components/shape_archive/tram_front.svg` | Fourth Shape-mation door or manage-shapes.*.svg set, drawn at 69. Design-first. | M |
| Shape-mation index has the same all-or-nothing decode (secondary) | PARTIAL | `App/Shapemation/ShapemationStore.swift:26` Record.family, :64-67 `try? … ?? []`, :20/:49-50 (library-level, does not travel) | A new FAMILY value empties the index on an older build and its next persist() rewrites it (files orphaned); shared-volume exposure. Per-element tolerant decode. | S |

### §3 Photo collections

| Requirement | Status | Build on | Work | Size |
|---|---|---|---|---|
| Collections hold STILLS | MISSING | `App/CollectionsModel.swift:52` Entry (blendID :74/:109, strict decode :100, :73-76); `App/AppModel.swift:2260`, :2693, :2541; `App/CollectionClipPicker.swift:111/:212/:281`; `App/CollectionExporter.swift:162` | Still member kind (captureID + shapeID + path + pixelSize), collectionsFormat 2 (`ProjectDocument.swift:63`), unlock picker, hold = duration, render ONE photo per frame over black through a single-photo evaluator (decision b). | L |
| A Shape-mation sits in a collection as its clip (new Entry kind) | PARTIAL | `ShapemationStore.swift:22` Record, :60-61 outputURL/posterURL; `CollectionsModel.swift:73-76`; `docs/TODO.md:1354-1356` | Entry kind referencing a Shapemation record (already clip-shaped); never re-accumulated; scrubs as video. | M |
| Durable shape-mation asset (members, shape, order, keys) | PARTIAL | `ShapemationStore.swift:22` Record (drops members at `ShapemationBuilderView.swift:191`); `Shapemation.swift:31` ShapemationItem; `CollectionsModel.swift:58/:68`; `App/ReframeTrack.swift:12` | Persist members (snapshot + id), order, holds, framing keys — route i (`docs/TODO.md:1354`) or ii; M3 persister/tombstones. | M |
| Re-render at another fps / ramp / framing | MISSING | `Shapemation.swift:111` make + :207 render (timing :199); `App/Shapemation/ShapemationListView.swift:64` | Re-render door; `App/AppModel.swift:2728` recipe / :2756 validCachedRender pattern. | M |
| Collections persistence infra | EXISTS | `App/ProjectDocumentWriter.swift:20`; `App/AppModel.swift:2782`, :2816; `App/LibraryPersister.swift:163` | Nothing; not in SQLite, not synced, not in .lapse. | S |
| Delete/evict cascade for stills | MISSING | `App/AppModel.swift:2082` from :1967/:1997/:2047; `ShapeFinder.swift:414/:448` | captureID cascade or tombstoned member; snapshot the DetectedShape. | S |
| Collections mirrors in clip vocabulary | PARTIAL | `docs/design/iOS/collections.portrait.svg`, collection-detail.*, collection-picker.* (iOS/INDEX.md:310-311, :362-368), collection-trim ⚠️ (:369), 🟡 (:372-375); no Mac row | Redraw for photo members after paying trim + 🟡; Mac INDEX row. UI. | L |

### §4 Output framing + tween + scrub

| Requirement | Status | Build on | Work | Size |
|---|---|---|---|---|
| Keyframed output rectangle; each frame its own placement — **DECIDED (b)** | MISSING | `Shapemation.swift:51` Plan (Placement :52-59, anchor :65, make :111, footprint :146) + :207 render (single `background` at OUTPUT size :212/:237-241, :270, advanced once per item :283-286, hold loop :276, outputOptions :81); stack semantics :7-12, working scale :48-50; `CollectionsModel.swift:58-62/:67-71`; `App/CollectionExporter.swift:425-436` canvasTransform, :438-456, :457-466 lerpTransform | Kit ShapemationFraming evaluated per frame by `framing(entry, t) → transform` composed with Placement.transform; fractional crop; outputOptions by rect aspect. "Canvas-scale accumulation + per-index cache" STRUCK: measured stack canvases 3397×4705 (45 circles, 64 MB/frame) → 13222×18975 (35 squares, 1.0 GB) → 49664×41323 (13 top squares, 8.2 GB). Accumulation stays in ShapemationRenderer. | L |
| Perceptual tween | PARTIAL | `App/ReframeTrack.swift:158`, :188 logLerp, :209 ease, :258; `BlendRamp.swift:4`; `CollectionExporter.swift:457-466` (history-free, two keys) | Lift the evaluator into the Kit; generalise start/end to a key list; index keys. | M |
| Scrubbable with exact framing | MISSING | `Shapemation.swift:250-270` (no single-frame API; :253-269 is the one Placement → CIImage block); `ShapemationTiming.swift:76` holds(count:) (prefix-sum → frame → (item, t)), :102-103; `App/Shapemation/ShapeFinder.swift:29` RepresentativeLoader (480 px at `ShapemationBuilderView.swift:129` vs 20000 at :183); `App/GuidedScrubPreview.swift:11/:119`; `App/WarpTimelineView.swift:21`; `App/ReframeCanvasView.swift:74` | `ShapemationPlacementRenderer.image(for:item:at:)`; one bounded decode (≤ 2048 px) through the same evaluator, '≈ preview' badge; Shape-mation entries scrub as AVPlayer. UI. | L |
| Live stack preview inside the builder (optional, not WP6) | MISSING | `ShapemationBuilderView.swift:518-528` planSummary (text), :415-448, :156-158, :548; nothing draws plan.placements | Only if wanted: preview-only accumulator ≤ 2048 px with every k-th last frame cached. | L |
| Bounded footprints under the perspective placement | MISSING | `ShapeGeometry.swift:34-40` Homography.apply (no w ≤ 0 guard); `Shapemation.swift:142`, :146-151 (no cap), :167-177; `ShapeMatch.swift:121-129`; `ShapeDetectorTests.swift:87-99` (level quads only) | Clamp corners w ≤ ε / cap at k× similarity footprint / fall back: real footprints 306663×328217 (w 0.004), 64013×55963 (w −1.9), union 509660×607248 on 169 rectangles; add a foreshortened-quad test. | M |
| Output size cap / encoder guard | MISSING | `Shapemation.swift:81-96` outputOptions ('Native' first), :216-234 no guard; `ShapemationBuilderView.swift:541`, :581 (Native default) | Cap Native (≤ 4096/8192) or warn + refuse naming the photo; today a big quad set is an AVAssetWriter error. | S |
| ShapemationRenderer tests | MISSING | `ShapeDetectorTests.swift:87-99`; none for the renderer | Frame count = holds sum, frame k = composite(k), foreshortened canvas, cap. | S |
| Keyframe editor + hook | MISSING | `docs/design/iOS/collection-detail.kenburns.portrait.svg` (`App/CollectionDetailView.swift:476/:594/:806`); `adjust.reframe.landscape.svg`; `App/LetsLapseApp.swift:1432` | Sequence-level Ken Burns variant + strip/scrubber; seed + park hooks in hookKeys (:789), README.md:44. Design question. | L |
| Coordinate conventions (incl. oriented frame) | EXISTS | `Shapemation.swift:239-256`; `App/ReframeVideoCropper.swift:226`; `FrameCrop.swift:162/:204`; register = ORIENTED, origin top-left, axes width fractions (`ShapeRegister.swift:9-11`), `Shapemation.swift:36`, `ShapeFinder.swift:27`, `ShapeDetector.swift:585-589`, `MaskShape.swift:403-413` | Register, MaskShape and plan all live in the displayed/oriented frame; tween in canvas px y-down, flip once; WP1 orientation-6 variant, WP2 OrientedDecode. | S |

### §5 Crop feasibility / negative space

| Requirement | Status | Build on | Work | Size |
|---|---|---|---|---|
| Inputs for margins | EXISTS | `ShapeRegister.swift:53-60`, :252, :311; `Shapemation.swift:36` | Nothing; axes are WIDTH fractions, centre.y a HEIGHT fraction. | S |
| Per-side margins — new correct API, bbox untouched | PARTIAL | `ShapeDetector.swift:619` bounds(of:) (PUBLIC, zero callers, mixed units) / :622 overlap / :624 bbox (:627-629 width fractions, :630 y height fraction — confirmed); `ShapeRegister.swift:202` remeasured(frame:) (precedent), :190; `Shapemation.swift:117-119`, :142-149 (per-item margins already exist as footprint vs anchor :157) | `DetectedShape.bounds(in:)` (pixels) + `margins(in:)` beside remeasured(frame:); retire bounds(of:); bbox/overlap untouched. | S |
| bbox ellipse unit fix — separate, MEASURED WP | PARTIAL | `ShapeDetector.swift:624-630` — sole IoU primitive behind 15 sites: :322/:326 (0.6, cross-kind), :422 (0.9, cross-kind, NO kind guard), :550, :612, :607 sameShapeIoU; `ViewfinderShapes.swift:84` (0.4), :116, :129-133 bestMatch, :141 (0.7), :104; `LiveShapeFinder.swift:230/:297/:301`; `ShapeFinder.swift:204` (0.8), :381, :425, :442; `PhotoViewerView.swift:3095`; `OverlayMasksPanel.swift:387`; `ShapeRegister.swift:235/:239/:307`; `tools/shapebench/shapebench.py:263`, :286-288, :336, :832; `docs/shape-benchmark/report.md:212`; `docs/TODO.md:1290-1300` | If done: kind guard at :422, currentDetectorVersion 3, overlap unit test (1.0 on 4:3/16:9; today 0.75/0.5625), shapebench before/after + --register-tag, re-tune 0.6/0.9. Landscape under-reads, portrait over-reads today. Stale comment `ViewfinderShapes.swift:81-82`. | M |
| Report margins per photo | MISSING | `ShapemationBuilderView.swift:398`, :356, :88 | Readout + amber flag on the row; projects SVG. | S |
| Exclude/flag infeasible photos | PARTIAL | `Shapemation.swift:150` all-or-nothing (Next disabled at `ShapemationBuilderView.swift:511`, `docs/TODO.md:1357`), :57; `tools/shapeseq/Sources/shapeseq/Geometry.swift:130`, `Transform.swift:67`, `Render.swift:7`, `Model.swift:179` | Port clip/coverage; per-item verdict vs f(i); flag-and-keep default. | M |
| Never draw negative space | EXISTS | `RegisterShapeOverlay.swift:4` | Nothing. | S |

### §6 Compositional filtering

| Requirement | Status | Build on | Work | Size |
|---|---|---|---|---|
| 3×3 classification | MISSING | new beside `ShapeGeometry.swift:86`; thirds drawers `App/CaptureView.swift:6395`, `App/EditorControls/CropFrameOverlay.swift:191`, `App/CollectionDetailView.swift:491` | CompositionCell + composition(in:) by area per cell on bounds(in:)/polygon clip, never bbox. | M |
| Filter by family | MISSING | `ShapeMatch.swift:132` → `ShapemationBuilderView.swift:88` | composition set on ShapeMatch + chip row. | S |
| Anchor-to-cell vs anchor-to-shape | PARTIAL | `Shapemation.swift:119`, :157 | One extra translate after §4. | S |
| Gallery SHAPES rows per cell | MISSING | `ShapeSummaryIndex.swift:48`; `LibraryIndex.swift:87/:465/:623` (:32); `ProjectCategory.swift:73`; `App/AppModel+Lists.swift:41` | Defer. | M |

### §7 Sequencing controls

| Requirement | Status | Build on | Work | Size |
|---|---|---|---|---|
| Per-image duration — scheduled under the 2026-09-11 sign-off | PARTIAL | `ShapemationTiming.swift:14` Hold (:18 options), :55, :76; `Shapemation.swift:276`; `ShapemationBuilderView.swift:835`; `docs/TODO.md:1347-1349`; `docs/design/iOS/INDEX.md:277` | Per-item override in frames over holds(count:); a per-row SELECT of Hold.options on the projects rows ('selects, not sliders' answers the form). Kit S + UI M. | M |
| Sort by size | EXISTS | `ShapemationTiming.swift:124` (:138, :144); `ShapemationBuilderView.swift:88/:99` duplicate | Collapse onto ShapemationSort.sorted. | S |
| Sort by ALIGNMENT — canvas-pixel metric | MISSING | `ShapemationTiming.swift:125`; `Shapemation.swift:52-53` Placement.transform, :126, :167-177 `dst`; NOT `ViewfinderShapes.swift:129` bestMatch (same-picture identity, scale-blind, mixed-unit bbox), NOT raw fields `ShapeRegister.swift:53-58/:112` | Residual after Placement.transform (corners vs dst / un-tilted ellipse vs circle) ÷ shapeSizePx; greedy chain from largest share; scored vs truth; SVG menu row. | M |
| 'Newest first' plays oldest → newest | EXISTS | `ShapemationBuilderView.swift:67` + :91; `ShapemationTiming.swift:146`; `ShapemationMatchTests.swift:145`; `docs/TODO.md:1094-1095` (invites rename/reverse) | Rename to 'Capture order' (default); enum, builder, test, projects SVG together. | S |

### §8 Prototype + synthetic data

| Requirement | Status | Build on | Work | Size |
|---|---|---|---|---|
| SVG scene generator | MISSING | `ShapeDetectorTests.swift:17/:326`; `tools/shapebench/shapebench.py:577`; `tools/shapeseq/Sources/shapeseq/ShapeSeq.swift:220`; `tools/design/svgkit.py:16`; rsvg-convert / Chrome (`tools/testcard_report.py:487`); `Kit/Sources/LetsLapseKit/OrientedDecode.swift` | Scene DSL, orientation-1 JPEGs + one orientation-6 variant, truth via factories. | L |
| Truth + perturbation, three dials, break point per axis | MISSING | `tools/shapebench/schema.py:1` (:27), `metrics.py:71/:101`, `fitting.py:43/:775`; `Shapemation.swift:114`, :122 (silent `continue`), :150 | (σ_scale, σ_centre, σ_rot) per-axis sweeps + one joint; quads via corners; one BREAK POINT line per axis; dropped counted separately. | M |
| One code path | EXISTS | `ShapeRegister.swift:27`, :166/:178, :255, :323 (:327); `ShapemationBuilderView.swift:60` | Document the contract (source .manual, FOV, whole seconds, oriented frame, 'dropped' ≠ 'misaligned'). | S |
| Shape in "the mask structure" | PARTIAL | `ProjectFileRegistry.swift:136`; `App/Overlay/OverlayStore.swift:19`, :121 | shapes.json only. | S |
| Self-contained .lapse | PARTIAL | `DirectoryArchive.swift:41`; `LightroomMigration.swift:319`; `App/AppModel.swift:9929/:10116` (:10190-10195); `App/LetsLapseApp.swift:1067`; /usr/bin/aa | createProject public / `lapse pack`; register any truth sidecar or it is dropped. | M |
| Minimal file set | EXISTS | `LightroomMigration.swift:359-382`; `App/AppModel.swift:110`; `ProjectDocument.swift:28` | project.json + source/ + shapes.json. | S |
| Headless plan scoring | PARTIAL | `Shapemation.swift:111` (:150, :127, :122); `ShapeGeometry.swift:11`; `Kit/Sources/lapse/ShapesCommand.swift:15/:25`, `FramingCommand.swift:54`; OrientedDecode; `ShapeDetectorTests.swift:77` | `lapse shapemation … --plan` via OrientedDecode, placed/dropped counts, multi-item test. | M |

### §9 Build order

| Requirement | Status | Build on | Work | Size |
|---|---|---|---|---|
| Step 1 scoreable | MISSING | `Shapemation.swift:111` + :52 (:167-177); `ShapemationMatchTests.swift:151`; `docs/shape-benchmark/report.md:212` | Scorer in canvas px ÷ shapeSizePx, pairwise overlap, sort score, dropped counts, residual vs σ per axis. | M |

### Design mirrors + hooks

| Requirement | Status | Build on | Work | Size |
|---|---|---|---|---|
| Mac Masks mirrors ⚠️; iOS Masks undrawn | PARTIAL | `docs/design/macOS/INDEX.md:216`, :171; `docs/design/iOS/INDEX.md:478` + `docs/TODO.md:1624`; `App/PhotoViewerView.swift:3365` | Redraw before the §2 pass; the too-new-register chip lands on the same card. | M |
| Other owed mirrors | PARTIAL | `docs/design/iOS/INDEX.md:286` vs `App/CreateView.swift:408`; `macOS/INDEX.md:172`; `iOS/INDEX.md:276-277`; `docs/TODO.md:1252` | Flag create-home stale, redraw find*, freeze hooks. | M |
| DEBUG hooks | PARTIAL | `App/LetsLapseApp.swift:789`, :1432; `App/CreateView.swift:312`; `App/PhotoViewerView.swift:304`; `docs/design/README.md:44` | Seed, park, inventory, too-new stage, freeze hooks; README catch-up. | S |

## Contradictions

1. **§10 vs projective quads** — `ShapeRegister.swift:141` / `NormalizedQuad.swift:139` / `Shapemation.swift:167` (`ShapemationMatchTests.swift:151` asserts !isAffine). Pick affine or projective for inventory placement; and the projective path is unbounded (`ShapeGeometry.swift:34-40` no w ≤ 0 guard).
2. **§2 "app-wide" vs per-library stores** — `App/LetsLapseApp.swift:110-115`, `App/StorageLocation.swift:38`.
3. **§2 "vector outlines" vs the shape model AND its transport** — Kind = ellipse|quad (`:13`); strict decode `:97` → nil `:328`; silent writers `ShapeFinder.swift:413-414/:448-450/:472-473` (+ default `.pending` scope `:236/:245`) and `PhotoViewerView.swift:2289-2301/:2343-2349`; byte-for-byte transport (`ProjectFileRegistry.swift:136`, `AppModel.swift:10190-10195`, `PicPlaceSyncPolicy.swift:67-72`, `PicPlaceChangeSync.swift:435-442`). The map's "decodeIfPresent-with-defaults" was the wrong instrument. A new Kind in shapes[] is not shippable to installed builds.
4. **§2 "rotation (yaw)" vs shipped copy** — `ShapeRegister.swift:58`, `RegisterShapeOverlay.swift:74`, `ShapeMatch.swift:18`.
5. **§3 route** — `docs/TODO.md:1354`, `ShapemationStore.swift:7` say route (i); the Record is already clip-shaped (`:22/:60-61`) so route (i) gets a Shape-mation into a collection as a clip Entry.
6. **§4 "own placement per frame" vs stack accumulation** — `Shapemation.swift:283-286`, `:7-12`. Resolved (b): one photo per frame in collections; accumulation stays Shape-mation's bake. Canvases measured 64 MB–8.2 GB per frame.
7. **"Native keeps every pixel" vs the encoder** — `Shapemation.swift:81-96`, default at `ShapemationBuilderView.swift:581`, no guard `:216-234`; 13222×18975 / 509660×607248 canvases.
8. **Map's WP0 "hygiene" vs bbox's blast radius** — 15 sites, 5 thresholds (0.4 `ViewfinderShapes.swift:84/:116`; 0.6 `ShapeDetector.swift:322/:326`; 0.7 `ViewfinderShapes.swift:141` → `ShapeFinder.swift:425/:442`; 0.8 `ShapeFinder.swift:204/:381`; 0.9 `ShapeDetector.swift:607/:422/:550/:612`, `PhotoViewerView.swift:3095`, `OverlayMasksPanel.swift:387`); `:422` lacks a kind guard; version-3 event (`ShapeRegister.swift:235/:239`); invalidates `report.md:212`, `TODO.md:1290-1300`. Resolved: WP0 adds bounds(in:), leaves bbox.
9. **Map's "bbox (internal)"** — `bounds(of:)` is public (`:619`), unused, and the buggy one.
10. **§7 metric seed** — bestMatch (`ViewfinderShapes.swift:129`) and raw fields are unfit; the plan canvas after Placement.transform (`Shapemation.swift:52-53`, `dst` `:167-177`) is the comparable space.
11. **"Newest first"** — shipped misnomer (`ShapemationBuilderView.swift:67/:91`, `ShapemationMatchTests.swift:145`), and `docs/TODO.md:1094-1095` explicitly invites the rename — a choice, not a conflict.
12. **DROPPED (old #6)** — per-image duration does not reopen the sign-off: `docs/TODO.md:1347-1349` schedules it under it; the rule fixes the control's form (select of Hold.options, `ShapemationTiming.swift:18`).
13. **§9 vs builder step order** — `docs/TODO.md:1348` already records output-frame-first; implement it; only Mode 2's fate stays open.
14. **§8 "mask structure"** — only shapes.json can be meant (`MaskShape.swift:19`, `docs/TODO.md:1343`).
15. **§8 one σ vs three dials; silent drops** — `Shapemation.swift:114/:122/:150`.
16. **§9 "scoreable" vs no alignment baseline** — `ShapemationMatchTests.swift:151`, no renderer test, `report.md` is detection; the rig's pixel-space MATCH (`fitting.py:43`) never saw the bbox bug.
17. **Reader disagreements, checked** — fileName `:234`; obliquity `:112`; load `:323` (`:299` is manual); make `:111`, render `:207`; bbox unit mix real (`:627-630`) but bounds(of:) public (`:619`); `docs/TODO.md:1301/:1354` both right.

## Build sequence

- **WP0 — Kit hygiene, scope A (S).** `bounds(in:)`/`margins(in:)` beside `ShapeRegister.swift:202`; retire `ShapeDetector.swift:619`; bbox/overlap untouched; collapse `ShapemationBuilderView.swift:88/:99` onto `ShapemationTiming.swift:144`; rename newestFirst (`:125`, builder `:91`, `ShapemationMatchTests.swift:145`, projects SVG). Accept: Kit tests + new bounds(in:) test on 4:3/16:9; shapebench run block identical to previous SHA; LL_SHAPEMATION=build order unchanged.
- **WP0b — Register forward-compat release (M+S+S; own release before any outline and before the v2 register).** Per-element decode + `foreignShapes` (`ShapeRegister.swift:287-296`, `:351-356`), `.tooNew` from `version` (`:262/:289`, `:323-341`), writers honour it (`ShapeFinder.swift:413-414/:448-450/:472-473`, `:234-236`; `PhotoViewerView.swift:2289-2301/:2343-2349`; set-aside after `AppModel.swift:8707-8719`), `markEdited` (`AppModel.swift:4607-4610`), same decode on `ShapemationStore.swift:64-67`, fixtures beside `ShapeDetectorTests.swift:149-161`, Masks/Find shapes copy + hook + SVGs. Accept: fixtures round-trip foreign entries byte-equivalent; too-new register left untouched and named; shapes-only edit pushes. **Built 2026-09-19:** everything but the chip, the hook and the SVGs, which are owed in `docs/TODO.md` ('Shape-mation WP0b'); `save` also probes the disk at the write, so a file that turned too-new under an open editor is refused there too.
- **WP0c — bbox fix, MEASURED, optional (M).** `:624-630` + kind guard `:422` + detectorVersion 3 + overlap test + `shapebench vision` before/after (`shapebench.py:263/:286-288/:336/:832`) + re-tune + re-quote. Accept: delta side by side; flat-nest preserved.
- **WP1 — Synthetic Phase 0 (L).** Scene DSL, orientation-1 + orientation-6 JPEGs, factories `:166/:178`, FOV `:255`, three dials, per-axis + joint sweeps, run blocks. Accept: every register loads with the intended family; o6 == o1; dropped-by-gate reported separately.
- **WP2 — Plan scoring CLI + multi-item test (M).** `lapse shapemation plan` / `score` after `FramingCommand.swift:54`/`ShapesCommand.swift:15`, OrientedDecode, canvas-px scorer vs `dst` (`Shapemation.swift:167-177`), placed/dropped counts, BREAK POINT per axis, test beside `ShapemationMatchTests.swift:151`. Accept: zero residual + dropped == 0 on truth; o6 residual == o1.
- **WP3 — Alignment sort (M Kit + S UI).** Case + canvas-px metric in `ShapemationTiming.swift:124/:144`; Sort row (`ShapemationBuilderView.swift:303`, projects + output SVGs). Accept: harness sort score; rows stay in share order.
- **WP4 — .lapse packaging (M).** `LightroomMigration.swift:319` public / `lapse pack`, `DirectoryArchive.swift:41` or aa, register sidecars (`ProjectFileRegistry.swift:136`). Accept: LL_IMPORT_ARCHIVE installs; app plan == CLI plan.
- **WP4b — Renderer hardening (M, before WP6).** Footprint bound (`ShapeGeometry.swift:34-40`, `Shapemation.swift:142-151`), Native cap / refuse (`:81-96`, `:216-234`), first renderer tests beside `ShapeDetectorTests.swift:87-99`. Accept: no plan on the 192-register sim library or 37 bench registers exceeds the cap.
- **WP5 — Durable member model (M).** Members + order + holds on LapseCollection (`CollectionsModel.swift:52`, `ProjectDocumentWriter.swift:20`, `ProjectDocument.swift:63`) or Record (`ShapemationStore.swift:22`); Shapemation-record Entry (`:60-61`); cascade `AppModel.swift:2082`; recipe `:2728`. Accept: byte-identical re-render; tombstoned member; record plays as a clip.
- **WP6 — Framing keys + single-photo evaluator (L, decision b).** ShapemationFraming; evaluator from `ReframeTrack.swift:158/:188/:209` + `CollectionExporter.swift:457-466/:425-436`; `image(for:item:at:)` from `Shapemation.swift:253-269`; frame → (entry, t) from `ShapemationTiming.swift:76`; renderer `:207` untouched. Accept: f(i) at first/last/mid; frame k == image(entry(k), t(k)) cropped by f(k).
- **WP7 — Feasibility + composition (M).** Clip/coverage from `Geometry.swift:130` into ShapePolygon; corners on Placement `:52`; verdict replaces `:150`; CompositionCell on bounds(in:); ShapeMatch set. Accept: flagged set == truth-margin set.
- **WP8 — Builder UI (XL, design question).** Keyframe editor + scrubber (kenburns/reframe SVG idioms, `GuidedScrubPreview.swift:11`), bounded scrub decode (`ShapeFinder.swift:29`, never `:183`), AVPlayer for Shape-mation entries, row margin/flag/cell/chips, per-row Hold select, output rect before projects (Mode 2 decision), hooks + README.md:44. Accept: INDEX rows + hook-verified.
- **WP9 — Photo Collections surfaces (L).** `CollectionClipPicker.swift:111/:212/:281`, `CollectionDetailView.swift:391`, `CollectionExporter.swift:162` → WP6 evaluator; trim ⚠️ + 🟡 paid; Mac row. Accept: appears, plays, exports, keeps recipe.
- **WP10 — Shape inventory (XL; outline-writing release only after WP0b + gap).** (a) redraw Mac Masks SVGs; (b) ShapeInventoryStore; (c) `outlines` key (B) or file (C), never a new Kind; (d) menu rows, one-action add, tilt/yaw; (e) management sheet at 69. Accept: tram_front.svg placed on a Mac photo, survives .lapse AND a round trip through a build without WP10, zero residual in WP2's scorer.

## Open questions (for Steven)

1. **Q15 by the installed-build criterion**: (A) `Kind.outline` in shapes[] — destroys hand shapes on installed builds; (B) `outlines` key in shapes.json — bounded, re-traceable loss (default); (C) `outlines.json` + registry — isolated, not carried by installed builds.
2. **WP0 scope**: A (new bounds(in:), retire bounds(of:), bbox untouched — default) or B (measured fix now: kind guard, version 3, tests, shapebench). If B: keep suppressing a circle's circumscribed square at IoU 1.0? Re-offer Find shapes on every v2 register now or after the v2 register?
3. **WP0b as its own release** ahead of outlines, and the update gap (default: every registered device confirmed updated, not a calendar length).
4. **Too-new register UX**: chip + tools disabled (default, SVG side) or edit-and-lose; and `markEdited` after register saves (default yes).
5. **§8 toolchain**: default Kit `lapse shapemation`/synth for plan/score/pack + Python for SVG drawing and reports. SVG hard requirement?
6. **Truth carrier**: v1 register + registered truth sidecar (default) vs schema-v2 run block.
7. **Score bar / break point**: default residual ÷ shapeSizePx in canvas px off Placement.transform, break = first σ per axis where the median exceeds 2 %; confirm quality score vs pass/fail.
8. **Native output**: silent clamp / warning + clamp (default) / refuse naming the photo.
9. **Perspective footprint bound**: default fall back to similarity when any corner has w < ε, clamp 3× otherwise.
10. **§3 route**: (i) default — photo-only collection kind, one photo per frame, Shape-mation clips as entries, no re-accumulation; a Shape-mation is always baked first.
11. **Member identity**: snapshot + id for refresh (default); one representative per project in v1.
12. **Sort persistence**: store the resolved list + rule (default).
13. **§4 tween axis**: keys per photo index, eases on the output clock via holds, Reframe semantics (default).
14. **Builder step order — CONFIRMATION** (`docs/TODO.md:1347-1349`): output rect first. Open: retire Mode 2 (default yes).
15. **§5 infeasible default**: flag-and-keep, exclude opt-in (default).
16. **§6 measure/home**: area per cell on bounds(in:), nine cells + power points, on ShapeMatch, no Gallery rows (default).
17. **Anchor-to-cell vs -shape**: shape in step 1, cell as a §4 option (default).
18. **§7 — CONFIRMATIONS**: per-row select of Hold.options in frames; 'Newest first' → 'Capture order' unless reverse preferred.
19. **Alignment chain**: canvas-space distance, largest share start, greedy + createdAt, rows in share order, playback follows (default).
20. **§2 inventory scope/identity/format**: per library, UUID, polyline from imported SVG, materialise/adopt (default).
21. **§2 pose model/vocabulary**: affine; 'Tilt'/'Yaw' new, 'Rotation' stays in-plane; outlines under the `outlines` key with their own family row once WP0b ships (default).
22. **§2 outline as mask**: rasterise in v1 (default).
23. **§2 on iPhone / inventory home**: Mac + iPad first; fourth Shape-mation door (default).
24. **Live stack preview in the builder**: default no for this brief.
25. **Work order per UI package** (WP0b copy, WP3-UI, WP8, WP9, WP10 d/e): design-first, code-first, or edited SVGs; stale mirrors redrawn before the §2 pass (default).
26. **`lapse shapemation` engine**: `--engine` onto Engine.rawValue (default).

## Minor

- **Coordinate frame stated**: register (`ShapeRegister.swift:9-11`), `ShapemationItem.pixelSize` (`Shapemation.swift:36`), `RepresentativeLoader` (`ShapeFinder.swift:27`), detector upright pass (`ShapeDetector.swift:585-589`) and MaskShape (`MaskShape.swift:403-413`, Lightroom sensor-frame converted once at import via `LightroomImport.swift:442-451`) all agree on the displayed/oriented frame — now written into the §4 Coordinate row; WP1 emits an orientation-6 variant, WP2 decodes through `OrientedDecode.swift`, acceptance: o6 residual == o1.
- **Contradiction 6 dropped; Q8/Q12 converted to confirmations** per `docs/TODO.md:1347-1349` (output frame first, per-item duration under the sign-off) and `:1094-1095` ('rename or reverse'); only Mode 2's retirement and the override's unit remain choices.
- **Three perturbation dials, not one σ**, with a BREAK POINT line per axis; the WP2 scorer counts placed / dropped-by-plan (`Shapemation.swift:114/:122/:150`) / dropped-by-register-gate separately and 'dropped == 0 on truth' is part of WP2's acceptance.