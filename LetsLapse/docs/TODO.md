# LetsLapse — open jobs

The queue of work that has been scoped but not done. One entry per job: what it
is, why it matters, and where the detail lives. A job leaves this list when it
ships, not when it is started.

Long jobs get their own document and are referenced from here. Short ones can
live inline.

---

## Open

### PicPlace sync v1 — sign in, push a nominated project, show its status

**Detail:** [picplace-sync-v1.md](picplace-sync-v1.md) · **Raised:** 2026-09-14
(Steven: "add the authentication to the LetsLapse app and sync of a nominated
photo — or video or interval — project to the picplace server, with some
indication of status inside the app") · **IMPLEMENTED AND LIVE 2026-09-14** — v1 (sign in + push one project) works
end to end; picplace.co is live (Hetzner storage, scheduler, APP_DEBUG=false).
The transport is done; the LetsLapse product flows (first-time connection,
accounts across libraries, auto-sync, restore, sign-out, presence/eviction) are
handed to the repo owner in [picplace-integration-handover.md](picplace-integration-handover.md).
Owed on this side: close the Mac inspector mirror (🟡). · medium · seams:
`App/SettingsView.swift` (a PICPLACE card between Storage and Advanced),
`App/ProjectDetailView.swift` + `App/GalleryPreviewPanel.swift` (the status
card / inspector group), `App/ProjectsView.swift` (a thumbnail pill),
`App/Info.plist` (the `letslapse` URL scheme), new `App/PicPlace/*` (PKCE
sign-in, Keychain tokens, the API client, the sync task, device-local state).

The server side is built and verified (the `picplace` repo, phases 0–4): PKCE
sign-in, a project registry keyed by the project's own UUID, single-device
write claims, presence, and presigned uploads negotiated in batches. The app's
half is a Settings sign-in, one Sync button per project that claims, PUTs
`project.json` as the manifest, negotiates every file under the project
folder (sha256 from `assets.ndjson` where it has one), PUTs them straight to
object storage, confirms, posts presence and releases — and a six-state card
(signed-out · not-synced · changes · syncing · synced with the other devices
that hold a copy · failed) drawn once as components and placed on the iPhone
detail and the Mac inspector, plus a media pill on the Projects thumbnail.
Nothing touches a record, a file format or the index; a device that never
signs in sees no difference. Out of v1: downloads, multi-project or automatic
sync, force-taking a claim, background transfers, production hosting.

### Post-crop vignette centring — the still and blend paths centre the vignette on the whole frame

**Raised:** 2026-09-12 (editor-controls redesign, stage D2) · known
limitation, by decision · **Size:** medium · seams: `PhotoGrader.engineRender`
(`App/PhotoPreset.swift`), `SceneAwareCompositor.bakeExportFrameBody`
(`App/Overlay/SceneAwareCompositor.swift`), `VideoGrader.composition`

The Crop panel (`PhotoAdjustments.crop`, a `FrameCrop`) is cut AFTER the
colour engine on the still path — `engineRenderFlat` → `rotated` → `FrameCrop
.apply` — and after the per-frame bake on the stills blend (a tail pass over
the finished clip, `VideoCanvasCropper.croppedCopy(of:crop:…)`). The vignette
is part of the engine, so on both paths it is centred on the FULL picture and
its falloff reaches the full picture's corners; a crop then takes an
off-centre slice of it. Lightroom's post-crop vignette centres on the crop.
The order was kept on purpose: the engine keys its spatial footprints (NR,
texture, sharpen) to the whole picture's long edge (`GradeEngine.encode`,
`reference.longEdge`) and grading a crop with the crop's own edge changes
their scale — the trap the engine's comment warns about. The video path
(`VideoGrader.composition`, `VideoCanvasCropper`) crops BEFORE it grades and
has the Lightroom behaviour already, so a cropped still and its blended clip
disagree on the vignette.

The fix is a vignette that knows the crop: pass the crop rect into
`GradeRecipe`/`GPUVignetteParams` (centre + half-diagonal of the crop in
texture space) and into `DisplayGrade` (`CIVignetteEffect` has a centre), and
put the same numbers on the masked-grade stage. Kit change with GradeEngine
parity tests; the `lapse` CLI recipe would need the rect too.

### Crop through the Adjust screen — a preview crop twin, and the punch-in reframe composed with the crop

**Raised:** 2026-09-12 (stage D2) · **Size:** medium · owner: `App/
AdjustPreviewLevel.swift`, `App/ReframeVideoCropper.swift`, the blend
orchestration in `App/AppModel.swift` (the reframe tail pass and
`SegmentNormalization`)

`AdjustPreviewLevel` levels the Adjust and Guided screens' source-frame
previews (`WarpPreviewLoader`, `ExactFrameLoader`, `GuidedFramingBox`) so a
punch or a canvas box is composed on the picture the render will crop. It has
no crop twin: with a project crop set, those previews still show the whole
levelled frame, so the canvas box and the punch-in keys are authored over a
picture the render then crops out from under them. Two consequences today:

- **The canvas** composes honestly but blind: the render cuts the project
  crop first and fits the canvas box inside what is left
  (`VideoCanvasCropper`, "crop first, then the canvas on the cropped clip"),
  while the Adjust preview drew the box over the uncropped frame.
- **The punch-in reframe is not composed with the crop at all.** When a
  `ReframeTrack` runs (the tail pass, or per segment in
  `SegmentNormalization`), the project crop is SET ASIDE: it cannot go before
  the punch without remapping every key (`ReframeMath.baseCrop` and the keys'
  `cx/cy` through `FrameCrop.mapPointIn`, `sourceSize` becoming the cropped
  size), nor after it without cutting a rect measured over a frame that no
  longer exists. The summary says " · crop not applied (punch-in reframe)" so
  nothing is dropped silently.

The job: an `AdjustPreviewLevel.crop` (provider + `apply` cutting after the
level) so the previews show the cropped picture; then either author the
reframe keys in the cropped frame and cut the crop first in
`ReframeVideoCropper.croppedCopy` (pass the crop, remap `rects` once), or
decide the reframe wins and keep today's set-aside. Design mirrors for the
Adjust and Guided screens follow whichever is chosen.

### Time-slice poster fast path ignores the project crop

**Raised:** 2026-09-12 (stage D2) · **Size:** small · owner:
`AppModel.renderPosterFastPath`, `StillsWindowProvider`

A run that keeps nothing but a time-slice poster (`sliceSettings.output ==
.image`, no regular clip) renders its master frames through
`StillsWindowProvider` + the stacker's frame hook, which write every frame at
the source's size — the crop cannot be cut per frame there, and this path
never reaches the tail pass that cuts it on the clip. The poster is therefore
built from UNCROPPED frames. The full render (clip + poster from the clip)
slices the cropped clip and is right. Fix: cut `grade.crop` on each master
frame as the provider hands it over (`FrameCrop.apply(_:to: CGImage)` after
the overlay bake — the same order `stackPhotos` uses), and let the ladder
sizes follow the cropped frame. Since 2026-09-13 the poster's summary says
" · crop not applied (poster fast path)" so the drop is not silent.

### Editor controls redesign — review leftovers (design fidelity, low)

**Raised:** 2026-09-13 (the six-lens review's fix stage; everything high /
medium and every correctness low was fixed; extended 2026-09-13 with what
the screenshot and mirror stages found) · **Size:** small each · owner:
`App/PhotoAdjustmentsPanel.swift`, `App/EditorControls/*`,
`App/PhotoViewerView.swift`, `App/Overlay/MasksCard.swift`,
`App/SettingsView.swift`

Taste items and design calls the review and the screenshot pass listed
that were not trivially safe to change, kept here rather than lost:

- **Sliders mode uses the native `Slider`** for every row but Temp / Tint
  (boards 6e / 3b draw a 4 pt track with an accent fill and a 26 / 20 pt
  knob for all of them). `GradientTrackSlider` wants a plain-track mode and
  every `sliderRow` routed through it — a11y (the native slider is what
  VoiceOver knows) decides whether the native one stays anywhere.
- **Touch chrome sits inside the safe area** (`.padding(.vertical, 12)`):
  the iPhone back disc / tab pill land at safe-top + 12 ≈ 71 pt against the
  board's 60; the iPad floating layout's at 36 against 16, and its foot row
  36 pt off the bottom against 16. Either let `floatingEditorBody` ignore
  the safe area (the board is edge-to-edge) or record the delta in the
  mirrors when they are redrawn.
- **Tool chip labels shrink** (`minimumScaleFactor(0.75)`) before they
  truncate; the board ellipsises at a fixed 11.5 / 11 pt.
- **Elements on no board:** the `PresetStatePill` in the panel title row,
  the "Save as Preset" footer + Lightroom card + save offer under the tiles,
  and the Crop hint's third string ("Original · the whole picture" where
  the board reads "Locked to Original · …"). Keep and add to the mirrors,
  or fold the save affordance into ✓ / long-press. The screenshot pass
  (stage G) added the **⤢ expand button** on the picture's edge — right,
  mid-height on the iPhone; bottom-right of the Mac pane — which no board
  shows either.
- **Presets ring while Edited.** `PresetState` is Original / named /
  Edited, so once a value moves NO tile carries the accent ring, while
  board 5a / 3b ring the named preset regardless of edits (and have no
  Edited pill). Decide which; the mirrors draw the app and their INDEX rows
  say ⚠️.
- **Readouts print an ASCII hyphen** (`%+.2f` / `%+.0f`) where the boards
  use a true minus (U+2212). A one-line format change, but it touches every
  readout, the pad readouts and the slider rows alike.
- **Mac panel header keeps a "Reset" text button** beside the state pill,
  Revert and Done (boards 3b / 6c draw Revert / Done only); at 330 pt that
  is what once wrapped the Presets title, since fixed by hiding it on the
  Presets card. The WB illuminant menu is the native macOS pop-up (white,
  black chevron) rather than the board's accent chevron square.
- **iPad Crop margins.** The floating layout centres the picture inside 48
  pt sides / 68 pt top / 144 pt foot while Crop is open (chrome- and
  foot-clear, deliberate, so every handle can be grabbed); board 5a says
  48 all round. The boards or the code move; the mirror draws the app.
- **Touch chrome offsets, restated from the screens:** the boards seat the
  back disc and tab pill at top 60 / 16; the app at 71 / 74 on the phone
  (12 pt under the safe area). Same job as the safe-area bullet above.
- **The iPhone-landscape rail's chips truncate** — "Exp ·…", "High ·…",
  "Shad ·…" — at the ~276–288 pt of card content a 16 Pro's rail offers
  (drawn as shipped, ⚠️ in the iOS INDEX). Drop the icon, drop the diamond,
  or shorten the labels on the phone rail. While there: the rail measured
  315 pt with 288 pt of content against `railWidth(in:)`'s
  `min(340, 0.42 × width)` and 16 pt padding — a 2–3 pt gap; check which
  safe width the function is handed.
- **Settings › Advanced › Layout vs board 6d.** The rows are separate
  `Form` sections with footers (the neighbouring rows' idiom, kept by the
  review's call) where 6d draws one grouped LAYOUT card with dividers on
  an "Advanced" page; the toggles are accent-tinted where 6d's are green;
  the row reads "Enable Scans menu", the board "Enable Scans Menu". Settle
  the idiom once, for the whole Advanced page.
- **The marquee badge reads "VIDEO · 13 s"** through
  `EditorMarqueeBadge.durationLabel` ("2 h 14 min" / "14 min 3 s" / "45 s")
  where the video brief wrote a literal m:ss; a parameter on the badge if
  m:ss is wanted.
- **The WB pad's Y axis is non-linear in Kelvin** (presented = −mired), so
  at the as-shot 6500 K the knob sits about 80 % of the way up and the
  crosshair is not where an untouched white rests. Per spec §2; worth a
  look once the pads have been used for real.
- **`presetStore.lastError` has a home only in the rail stack** (Mac,
  iPhone landscape); the phone sheet and the iPad floating card show a
  failed preset save nowhere (the old panel showed it under "Save as
  Preset").
- **The Mac Masks card's compact rows** deviate from the brief's literal
  "dim the group's other tools": every touched tool is lit and ONE lead
  tool per silent section dimmed (≤ 7 icons — dimming all seven reachable
  tools is 130 pt and does not fit beside the name at 330 pt); row spacing
  8 vs the board's 10; the shared `MaskTile` ring 2.5 pt vs the board's 2;
  no add tile in the compact list (a second grade is added from Manage ›).
- **The SVG mirrors** were drawn 2026-09-13 (stages F / G) for iPhone, iPad
  landscape and the Mac; what is still undrawn — iPad portrait's rail
  layout, the Mac video editor, the iPhone Masks page — is listed under
  *Design mirrors for the tabbed editor rail* below.

### Editor controls redesign — code fixes owed after the screenshot pass

**Raised:** 2026-09-13 (stage G's captures of the shipped build on the
iPhone 16 Pro / iPad Pro 11" simulators and the Mac, and the mirror stages
that drew them as shipped) · **Size:** small each, one medium · owner:
`App/PhotoViewerView.swift`, `App/VideoEditorView.swift`,
`App/PhotoAdjustmentsPanel.swift`, `App/EditorControls/*`,
`App/Overlay/MasksCard.swift`

Each of these is a screenshot with a wrong thing in it, not a taste call:

- **iPhone Crop: the top corner handles are unreachable.** Opening the
  panel fits the picture into the room above the foot (the 2026-09-13 fix
  for the BOTTOM handles), but that room starts at the safe-area top, so a
  tall picture's top handles land under the back disc and the tab pill,
  which take the touch. `phoneEditorBody`'s crop room should start under
  the chrome row (safe top + `touchChromeHeight`, 60), the way
  `floatingPictureFrame` already does on the iPad. The mirror
  (`iOS/project-photo.viewer.crop.portrait.svg`) draws the corrected fit —
  a 282×376 picture at (55.5, 119) — so re-verify `iphone-crop.png`
  against it after the fix.
- **Mac Crop card: the six aspect chips overflow the card.** At the 330 pt
  rail's 274 pt of content, Original · 1:1 · 4:5 · 16:9 · 9:16 · Custom do
  not fit: "Original" and "Custom" lose their side padding and Custom is
  flush with the card's edge (`mac-crop-rail-crop.png`). Board 3b sets the
  chips at 10.5 pt with 5 / 0 padding and a hairline border, inside the
  card; `photo-viewer.crop.svg` draws them there.
- **Mac Presets card shows two save affordances at once** — the "Save these
  edits as a preset?" prompt card (`saveOffer`) AND the "Save as Preset"
  row — and the same prompt card is also appended under "Reset
  adjustments" in every OTHER group's card while the state is Edited
  (`mac-presets.png`, `mac-light.png`; boards 3b / 6c have neither).
  `photo-viewer.presets.svg` draws one row. One affordance, in one place.
- **Detail › Noise pad: the knob is clipped at neutral.** Both of the Noise
  pad's fields are unsigned with neutral 0, so the crosshair sits in the
  bottom-left corner and the 30 pt knob is three-quarters outside the
  pad's clip, with no crosshair visible (`iphone-detail-noise.png`). Sharpen
  has the same geometry. Inset the knob's travel by its radius, or draw
  the knob above the clip — `XYPad` decides for every pad at once.
- **The Mac masked-grade editor still draws the old sections.** The
  compact rows are redesigned, but `MasksCard.expandedPanel` (the card a
  row opens into) is the pre-redesign White Balance / Light / Color /
  Effects slider stack (`mac-masks-row.png`; `photo-viewer.mask-grade.svg`
  draws it as shipped, row ⚠️). Regroup it into the groups / tools / pads
  — `MaskGrade.sections` already maps its fields onto `EditorTool`s for
  the row icons — or route it through `PhotoAdjustmentsPanel` with a
  masked-grade `EditorPresetsContext` of nil, which is what the panel's
  doc comment anticipates. Medium: a masked grade has no timeline, its
  White Balance is the legacy `temperature` / `tint` offset pair (not an
  owned white), its Exposure travels ±2 EV rather than ±5, and it holds
  nine fields where the panel's groups hold twenty-odd — the sections
  would be Light (Exp · Con, Highlights · Shadows), Color (WB, Saturation)
  and Effects (Clarity, Dehaze) with the rest absent, not dimmed.
- **Video editor: no crop frame over the player.** The Crop group's aspect
  chips and Angle slider work on a movie, but nothing draws the crop over
  the player — `VideoGrader.composition(cropped:)` defaults to FALSE for
  exactly that reason, the player shows the whole movie and the hint under
  the chips ends "· shown on export" (`cropNote`). The job is
  `CropFrameOverlay` over the player (the viewer's `cropBinding` +
  `cropEditing` arbitration, `imagePane`'s gesture masks), centring the
  player inside the iPad floating layout's 48 pt inset while Crop is open
  as the viewer does, and then dropping the note. Until then a cropped
  movie is only ever seen cropped in the motion preview and the export.
- **The Mac video editor auto-plays on open** — the transport showed the
  pause glyph as soon as `LL_EDITOR=video` landed (`mac-video-light.png`).
  Decide whether the editor should open playing; the photo editor's
  timeline opens parked.
- **Hook fidelity for the mirrors** (`PhotoViewerView.applyKeyframeHook`,
  `applySectionsHook`; the same two in `VideoEditorView`):
  `LL_KEYFRAMES=sunset` parks the playhead at 30 % unsnapped, while the
  iPad keyframed mirror is drawn in the boards' snapped state (52 %,
  1:09:41) — a value for the snapped state would make that screenshot match
  one-to-one; the hook also keyframes `shadows` and `vibrance`, so all
  three Light chips carry diamonds where the boards mark Exposure,
  Highlights and Temp only. `LL_EDITOR=latest` and `LL_VIEWER=1` may not
  resolve to the same "largest interval shoot" (the iPhone landscape
  capture opened a different project from the portrait runs). And
  `applySectionsHook`'s doc comment still says the band suffix is "parsed
  and dropped" — it has been honoured (`initialBand`) since the review's
  fix stage.
- **A preset tap still drops the owned white.** `applyPresetValues` now
  re-attaches the crop and the rotation (review fix, 2026-09-13) but not
  `whiteMired` / `whiteTint` — pre-existing, outside the review's
  findings, and worth the same treatment: a preset is a look, a white is a
  correction.
- **Smaller, from the stage reports.** The Mixer pad and its band slider
  fire no `onFieldEditing` (band values are not `PhotoAdjustmentField`s),
  so a mixer edit is persisted only by the editors' 2 s safety net and
  never floats the loupe — as the old mixer rows behaved; a band-level
  editing callback would close it. `gradeToken` keeps the crop, so at 1:1 a
  crop drag re-keys the detail patch and the loupe although both render
  uncropped — drop the crop from the token if the extra full-resolution
  renders show. `PhotoAdjustmentsPanel.isNeutral` is asked for every group
  on every body pass (`nonNeutralGroups`) — cheap today; memoise the group
  bar's dots first if the Presets tiles' re-render on scrub ever hurts.

Already listed above as their own jobs, and part of the same redesign:
*Post-crop vignette centring*, *Crop through the Adjust screen* (the
`AdjustPreviewLevel` crop twin and the reframe composed with the crop) and
*Time-slice poster fast path ignores the project crop*.

### Editor controls redesign — device verification owed

**Raised:** 2026-09-13 (stages B–D and the review's fix stage could only
compile, screenshot or drive by MCP taps, which are too slow to form a
double-tap) · **Size:** one session on an iPhone and an iPad, plus a Mac
run · owner: the `/run-letslapse` skill on a physical device

Everything here compiles and was seen on the simulators; none of it has
felt a finger:

- **Gestures.** `XYPad`, `GradientTrackSlider` and `CropFrameOverlay` attach
  their drags as `.highPriorityGesture` (so the `.page` `TabView` of a
  multi-frame project no longer steals a horizontal move) with the reset as
  a trailing `.simultaneousGesture(TapGesture(count: 2))`. Confirm on a
  device that the double-tap still resets both fields, that a crop
  corner / body drag and the crop pinch work with the pane's own pan and
  magnify standing down (`cropEditing`, and the magnify mask while Crop is
  open), and that paging between frames still works with a pad on screen.
- **A movie on the touch layouts.** The phone (2a / 6a) and iPad floating
  (5a / 6b) layouts of `VideoEditorView` were code-mirrored from the photo
  editor and never seen with a movie: `LL_EDITOR=video` stops at the
  project detail on iOS. Two things to look at: AVKit's bottom-anchored
  transport sits under the phone's foot stack (the strip's play / scrub is
  the transport there — if it reads wrong, inset the player by the foot
  height the way the viewer's `EditorFootHeightKey` does), and a portrait
  movie runs under the foot exactly as a tall photo does.
- **A cropped mixed-resolution ramp shoot through export.** The review's
  canvas-box change (`runsCanvasPass` / `cropCanvas` nil when a project
  crop exists and no canvas was chosen; `SegmentNormalization.canvas`
  optional) compiles and follows the cropper's existing nil-canvas body,
  but no cropped ramp shoot was rendered end to end.
- **The mirrors' own captures.** `iPadOS/project-photo.viewer.landscape.svg`
  is drawn from `floatingPictureFrame`'s rule, not a screenshot — the iPad
  session had no PHOTO capture (`LL_EDITOR=<uuid> LL_SECTIONS=light:expcon`
  on one); the iOS `project-photo.viewer.portrait.svg` /
  `.landscape.svg` are derived from interval captures minus the card and
  strip — a `LL_VIEWER=1` run over a photo project confirms them;
  `macOS/photo-viewer.mixer.svg` was drawn from the card idiom without a
  Mixer capture (`LL_EDITOR=latest LL_KEYFRAMES=sunset LL_MIXER=demo
  LL_SECTIONS=color:mixer:orange`). The Mac captures are 1× (the window sat
  on a non-retina display at 1440×1125 pt; light appearance forced per
  process with `-NSRequiresAquaSystemAppearance YES`) — re-capture on the
  retina display at the 1000×720 default if pixel-exact comparison is
  wanted. iPad simulator rotation: Cmd-L did nothing and the
  brightness-strip heuristic misdetects the dark editor; the recipe that
  worked is the Simulator's Device ▸ Rotate Left menu click, the window
  size as the check (1052×807 = landscape) and `sips -r 90` on the native
  buffer.

### Server as the source of truth — sync-ready records (Part 3 of the data-model audit)

**Detail:** [data-model-server-portability-2026-09-12.md](data-model-server-portability-2026-09-12.md) ·
**Raised:** 2026-09-12 (Steven: a Lightroom alternative with its own cloud;
records canonical on the server, originals moving between devices, previews
everywhere) · **AUDIT DONE 2026-09-12, no implementation** · large; the client
half (phases 1–5) precedes any server

Verdict: today's model cannot sync (no cross-device id, no revisions, delete =
folder removal, path-keyed thumbnails); the Parts 1–2 model can, with five
additions — revisions + tombstones on every edit-class record, a per-device
NDJSON change journal behind ONE `apply(change)` funnel (the 35 persist sites),
asset keys `(originID, fileName)` + SHA-256 content hash, presence tiers
original / proxy / preview per device, and a class for every store (capture
fact · edit · derived · cache · device state). One metadata edit moves a few
hundred bytes: journal line → server revision + feed → each client rewrites
one project's asset record and one index row; no media, renders or caches.
Two brief constraints change and are listed as Steven's decisions: per-field
last-writer-wins for metadata/grades with a server lease only for structural
edits; server canonical for records, client canonical for the bytes it holds.
Also: `metadata.json` + `assets.ndjson` per project, folder = `originID` for
synced projects, the LAN transfer kept as the originals transport, and a
journal-replay test that reproduces the materialised files byte for byte.

**Decisions taken 2026-09-12 (Part 3 §10):** conflicts = per-field LWW + lease
for structural edits; the server owns originals once a device is signed in,
devices hold storage-sized leases and evict to previews only after the server
confirms the bytes by hash; folder = originID for server-arrived projects only,
existing folders never renamed; previews made by the last device to edit
(needs an original or proxy); Lightroom retired after a verified one-time
migration with its folders pinned until then; accounts = Laravel auth (Sign in
with Apple + email), offline use allowed, one account per device, sign-out
refused until originals are confirmed, plain quota, sharing in v2. **Build
order (§12):** local phases 1–5 first, server-ready but standalone; the server
is milestone 6. **Phase 1 spec written 2026-09-12:**
[data-model-phase1-spec-2026-09-12.md](data-model-phase1-spec-2026-09-12.md)
— twelve work items (`lapse audit` first, then identity + manifest v4 as a
JSON-level migration in the Kit, one version-gated persister, the
undecodable-manifest guard, tombstones + `Projects/.trash/`, revision stamps,
whole-file SHA-256 into per-project `assets.ndjson`, project id minted at run
start so `capture_log.json.sessionID` = origin id, the experiment log as NDJSON),
with Kit tests and a before/after audit on both real libraries.

**Milestone 1 landed 2026-09-13** (W1 + W5 + the Part 2 §4 metadata import as a
vertical slice; commits from 7fd0a0a): `lapse audit <root> [--json] [--plist]`
reproduces Part 1 Appendix A on `/Volumes/letslapse` (3 orphan folders, 1 record
over an empty folder, 7 unlisted renders, 77 `.json` names; reports saved in
`docs/data-model-audit-reports/`); `ProjectFileRegistry` in the Kit is the one
table of per-project files and `ProjectArchive.transferableFiles/Subfolders`
derive from it; per-project `assets.ndjson` (bytes, whole-file SHA-256,
`imported` + `edited` metadata layers, per-field `editedAt`) written at
registration and by the idle-only, resumable launch backfill (`AssetRecordStore`
— pauses on thermal serious, low power or a busy library), plus `metadata.json`
for the project-level record; `MetadataFieldMap` (JSON key ↔ XMP path ↔ IIM ↔
ImageIO) read through `MetadataReader` (sidecar over embedded XMP over IIM/Exif);
tags are keywords (`sceneTags` stays as the searchable cache, seeded from the
files); the Gallery panel's INFO and METADATA groups with from-file / edited-here
markers, revert, and a Whole project / This frame scope for interval shoots;
`lapse metadata <image>` headless. Verified on the Mac app, the iPhone 16 Pro
and iPad Pro simulators with the four Part 2 §2 files. **Signed off and
mirrored 2026-09-13** (Steven: "Milestone 1 looks good", then design-sync the
same day): the panel is ONE set of shared components —
`docs/design/components/metadata-scope.*`, `metadata-info.*`, `metadata-fields.*`
and `tag-field.imported.*` (components/README.md "Metadata record") — placed by
macOS `gallery.svg` (interval, at rest), `gallery.metadata.svg` (the imported
photo), `gallery.tags.svg` (scrolled to Keywords, picker open) and iOS
`gallery.preview.portrait.svg` (the iPhone sheet); the iPad row leans on the Mac
files. Found while drawing: a project tagged before the records existed showed an
empty Keywords row (the manifest's `sceneTags` were never a layer) — fixed the
same day, they read as "edited here" until the first edit writes them into the
record. **Owed from M1:** metadata
EXPORT (record → XMP packet in JPEG/HEIC/TIFF/DNG exports and `.xmp` beside
raws, through the same table); the "Copy contact block from…" convenience
(Part 2 §7); QuickTime metadata for video imports (Part 2 §9.2); the
`lapse import-lightroom` tool.

**Milestone 2 landed 2026-09-13** (commits 71ae326 → d866dfc, one per work
item): W2 `DeviceIdentity` (`letslapse.deviceID`, Appendix B row 84); W3
`originID` / `originDeviceID` / `derivedFromOriginID` with duplicate detection
by origin (a crafted second-hop archive is caught) and `PTProjectInfo.originID`;
W4 `ManifestMigrations` step 4 on the JSON before decode (verified on a copy of
the Mac manifest: schema 4, `.json` names 77 → 0, originID 256/256, four clone
links; `registerSequenceCapture` no longer lists `sequence.json`, installs strip
`.json` names); W6 `LibraryPersister` + Kit `VersionGate` (one queue, older
snapshots dropped, flush on terminate/background); W7 the set-aside
`library.json.unreadable-<stamp>` + refused writes + banner; W9 tombstones,
`Projects/.trash/`, launch sweep, 30-day purge, Settings ▸ Storage Trash line +
Empty trash; W8 `revision`/`modifiedAt`/`modifiedBy` on all three record types
+ `editedBy` per field on the asset records; W10 the run's project id minted at
start (staging folder, `capture_start.projectID`, blend `sessionID`, experiment
header `originID`, registration keeps it); W11 `NDJSONWriter` + the `.ndjson`
experiment log with the document written once at finish, logs pruned to 50; W12
`.jobs/` scratch with relative paths and removal at completion, branded
`LetsLapse-Models`, `.gps-backup` sweep. DEBUG hooks added: `LL_IMPORT_ARCHIVE`,
`LL_EXPORT_ARCHIVE`, `LL_DELETE`. **On-device checks done 2026-09-13** on
Steven's iPhone 16 Pro (Release build he installed; driven over the remote
link with `shoot.py`, evidence pulled with `devicectl … copy from`): **W10 ✓** —
after a 60 s Basic interval run (2 s, 5-frame blend, 30 outputs) the project
`EB0F1B6A` has `capture_log.json.sessionID == capture.id == originID`, its
`originDeviceID` is the id the launch printed, no `.json` names, and its 30
assets were hashed + read at registration within 0.4 s; a run killed at
window 13 left an orphan `CaptureLogs/capture-C449EE1E….log` whose
`capture_start.projectID` (`F9A1AFA7…`) names both its staging folder
`tmp/liveblend-F9A1AFA7…` (13 frames) and its experiment log's `originID`.
**W11 ✓** — the finished run's `liveblend-…150123.ndjson` (header + 30 outputs
+ summary) rebuilds its `.json` document field-for-field; the killed run's
`liveblend-…150515.ndjson` is 14 parseable lines (header + 13 outputs), ends
on a newline, and has no `.json` — exactly the shape a crash leaves. **W5's
thermal pause was NOT exercised:** the phone's library is fully recorded, so
there is nothing left for a backfill to pause on, and heating the device on
purpose is a bench session of its own; the pause loop also fires on "library
busy", which the registration path (never paused) was verified around. Still
owed: the Mac → iPhone → Mac transfer round trip (the archive
path was verified; the transfer shares the installer); the ten
`.hasSuffix(".json")` filters come out one release after W4; the Phase 1 §5
after-audit on both real libraries once a build with the backfill has run
against them (the Mac volume was audited unchanged after M1 — no build ran
against it). The W7 banner and the Settings ▸ Storage Trash row were mirrored

**Phase 2 landed 2026-09-13** (commits 40fcbb1 → 864a637, one per work item):
W1 every persist also writes `Projects/<id>/project.json` (`ProjectDocument`,
format 2, ISO-8601 to the millisecond, slashes unescaped) — `ProjectDocumentWriter`
on the persister's queue rewrites only the documents that differ from the last
written, a tombstoned project's document follows its folder into `.trash`, the
one-time launch pass (`reconcileDocuments`) brought 258 documents up in 0.07 s and
confirms them in 0.03 s on the next launch; `project.json` is registered in
`ProjectFileRegistry` (kept out of `travellingRootFiles` because the installer
reads and re-keys it). W2 `lapse audit --rebuild-index` reconstructs the manifest
from the documents (live + `.trash`) and diffs it in canonical form; `lapse
project-diff` for two documents. W3 export and transfer send the on-disk document
after one `persistAndWait`; the `.lapse` round trip differs only in `id`,
`importedFromID`, `addedAt` and the blend re-keying. The `ProjectArchiveManifest`
type is gone; the installer accepts formats 1 and 2. Mac → iPhone → Mac transfer
round trip still owed (needs a device install — ask first).

**Phase 3 landed 2026-09-13** (c91f8c4, fb02c62): Kit `LibraryIndex` over the
system SQLite at `<root>/Index/library.sqlite` — a cache rebuilt from every
`project.json`, `assets.ndjson` and `metadata.json` (258 projects in 0.13 s;
`verify` proves deleting it loses nothing): one row per project / blend / asset,
FTS5 over names, titles, captions, keywords, tags, elements, creator, place and
camera; `projects(query)` pages by capture / added / edit / size / name with
kind, scanner, chip-tag and text filters; `search`, `tagCounts`. The app keeps it
current (document writes upsert, asset-record writes re-index once per job, a
fresh database is rebuilt at launch, a stale row re-indexed by file date) and
`lapse index <root>` reads or rebuilds it headless. **Still open from Phase 3 —
the read-side switch:** the grids and the Projects search still render from
`AppModel.captures` / `SceneQuery` (substring matching). Making `captures` a
window over `LibraryIndex.projects(query)` and the search FTS-backed is a UI
milestone of its own: the seams are `ProjectsView` (sort + `CaptureFilter` +
`SceneQuery` → one `ProjectQuery`), `GalleryView.sortedCaptures`, the transfer
picker, and every `captures.first { $0.id == … }` lookup that would become
`project(id:)` + a document read; FTS prefix matching changes what a typed word
finds, so it needs Steven's call and a design pass on the search field.

**Phase 4 landed 2026-09-13** (78becec, 7af6901, 70a4f6f): `Collections/
collections.json` (every collection, tombstoned included) so a manifest rebuilt
from the folders keeps them; the W7 dead end became a repair — an undecodable
`library.json` is set aside AND rebuilt from the documents, the library carries
on, the banner tells the story (a manifest with one capture's `kind` corrupted
came back with all 258 records, 140 blends and the collection); launch
reconciliation from folders — a UUID folder with no record is adopted from its
own document (live even when the document is tombstoned: a folder dragged out of
`.trash` is a folder someone wants back), a folder with media but no document is
registered as "Recovered · <id>", an empty folder and a record without a folder
are logged; `Projects/.lock` on macOS (pid, host, build, heartbeat) — a second
instance opens read-only with the banner, a dead holder is taken over — plus a
foreground check that `library.json` was not written by something else; `.lapse`
archives unpack under `Incoming/` so installs are renames on a custom root. The
`LibraryNoticeBanner` now has three stories — **SVG mirrors for the rebuilt and
read-only stories owed after sign-off**. **The first launch of this build against
`/Volumes/letslapse` will adopt the 3 orphan folders (44623568, 5968F261,
894519E4) as "Recovered" projects** — keep or trash them from the list.

**`lapse import-lightroom` landed 2026-09-13** (a16b242) — see the entry below.
**Handover brief for the switch (documents as the truth, SQLite as the index,
`library.json` retired) written 2026-09-13:**
[data-model-switch-brief-2026-09-13.md](data-model-switch-brief-2026-09-13.md)
— the evidence that the ground is ready, the reading order, the five
milestones (M1 truth flips → M2 read side over the index → M3 no arrays → M4
retire `library.json` → M5 the `apply(change)` funnel and journal) with their
acceptance tests, the rules, the recipes, the traps and the decisions to take.
Owed across the programme: the device checks from M2; the transfer round trip;
the `.hasSuffix(".json")` filters (one release after W4 — not yet); the iPhone
library's after-audit (the Mac volume's is in `docs/data-model-audit-reports/
mac-after-backfill-2026-09-13.txt`: hash coverage 100 %, `.json` names 0,
origins 258/258). One pre-existing Kit test fails unrelated to this work:
`ShapeDetectionModeTests.testExternalEnginesKnowTheirRigDetector` (a set-order
assertion in the shape-detection area).
2026-09-13 after sign-off: `components/library-banner.unreadable.*` placed by
iOS `create-home.library-unreadable.portrait.svg`, and iOS
`settings.storage.portrait.svg` (the Mac shares both — INDEX rows say how).
**2026-09-13, first launch over the real library:** the backfill's hash loop
kept every 1 MB chunk in an undrained autorelease pool (`FileHandle.read`), put
the Mac into swap in six seconds and died on a 2315-frame DNG project; fixed in
8a63c4c (POSIX reads, a pool per file, the backfill on its own queue so an
import's records land at once, the decide-walk off the main actor).

**M1 landed 2026-09-14 — the truth flips** (538dbb1 the Kit, 77116f1 the app;
report `data-model-audit-reports/scratch-m1-switch-2026-09-14.txt`): the app
loads every `Projects/<id>/project.json` (live and `.trash`, one strict decode
each — `App/LibraryDocumentLoader.swift`) plus `Collections/collections.json`
and no longer decodes `library.json`; the persister writes the documents first
and `library.json` after them as a generated compatibility export marked
`"generated": true` (Kit `LibraryExportFormat`; `lapse audit` reports it as
such and lists the kept copies; `--rebuild-index --out` marks its output too).
A missing, unreadable or pre-switch export — or one whose ids no longer match
the documents — is regenerated at the end of the launch; the first launch that
meets a manifest without the marker keeps it as
`library.json.pre-switch-<stamp>`. Rules: a document under `Projects/` is live
whatever its tombstone says, one under `.trash/` is deleted (stamped if
undated); an undecodable document is reported, left byte-for-byte alone and
kept out of the folder reconciliation; a live folder with no document takes
its record from the manifest once; a library with no documents at all
bootstraps from its manifest and flips on that launch; the loader seeds the
document writer so an adopting launch's persist writes one document (28 ms)
instead of everything (8 s). Verified on scratch roots built from the Mac
volume's manifest and 366 documents: the flip rewrites no document, reads 366
in 0.16 s, `--rebuild-index` IDENTICAL and `index --verify` CONSISTENT after
every launch, the pre-switch copy against the export differs only in a
half-millisecond `addedAt` (µs → ms) and the folder-order tie of two twins
with identical `createdAt`; a deleted export regenerates byte-identical with a
pixel-identical Projects list; a corrupt one is set aside, bannered (the
Phase 4 "rebuilt from N folders" story, unchanged copy — no SVG applies) and
regenerated; a manifest-only root bootstraps and reads IDENTICAL on launch two;
six edge faults at once behave. **Owed from M1:** the real Mac library's first
M1 launch and its read-only `lapse audit` after (this session could not point
`lapse` at the volume); the iPhone 16 Pro launch time at 518 projects (a device
install — ask first); the banner's "regenerated" wording for an unreadable
export (a copy change, with M4 when the story goes). **§9 decided 2026-09-14** (2fc20c0):
FTS prefix-per-word everywhere; the export stays one release and the Python
readers move to the index; no Recovered badge; collections stay the in-memory
document.

**M2 landed 2026-09-14 — the read side moves to the index** (spec
[data-model-m2-spec-2026-09-14.md](data-model-m2-spec-2026-09-14.md); f7eb131
the Kit's schema 2 — `category` by the app's own rules with the scanner sidecar
read once, `edited_at`, the SHAPES counts, tag labels in FTS, `Sort.edited`,
tie order turning with the sort, `projectIDs`/`categoryCounts`/`tagCounts
(excludingScans:)`; 298ff6c the list hooks `LL_FILTER` / `LL_QUERY` / `LL_CHIPS`
/ `LL_DUMP_ORDER`; 00a7513 the Projects list, Gallery and clip picker over
`ProjectListQuery` → `LibraryIndex` with `capture(id:)` per card and the arrays
kept as the fallback for a library with no index; 3fc7a85 the 56 by-id lookups
→ `capture(id:)`/`blend(id:)` and the single-project mutations through
`updateCapture(_:edited:persist:_:)`, plus `LL_APPLY_PRESET`). Report:
`data-model-audit-reports/scratch-m2-lists-2026-09-14.txt` — 36 launch-hook
cases per platform, 33 identical before and after on the Mac and the iPhone 16
Pro simulator (36/36 simulator = Mac), the three differences the search
decision's own ("idge" mid-word → 0, "13:49" a dated display title → 0,
"photo" +34 unnamed interval shoots via `originalName`); a grade settle rewrote
one document, the export and one index row. Mirrors: desc-only updates to the
three iOS `projects.*.svg` and `macOS/gallery.svg` + INDEX paragraphs (nothing
drawn changes) — **Steven's look owed**; if the field should say it searches
words, that is a design pass. **Owed from M2:** the transfer picker's "Hide
imported" still walks the arrays (M3, with `projectID(originID:)` ready in the
Kit); `refreshShapeSummaries` still runs on each Gallery visit (it now also
keeps the index's counts); the device checks. **M3 landed 2026-09-14 — no whole-library arrays** (spec
[data-model-m3-spec-2026-09-14.md](data-model-m3-spec-2026-09-14.md); d6b40e7
the Kit's whole-library queries; a5fdebc `App/ProjectStore.swift` — an LRU of
512 documents behind `capture(id:)` / `blends(for:)` / `blend(id:)`, every
write one document through `store.update` / `insert` / `remove`, the
persister per project with a `VersionGate` per id, `library.json` regenerated
from the documents at launch when stale and at quit / background rather than
per persist, `App/LibraryReconciler.swift` — the launch as one block per
folder on the persister's queue (a stat against the row, a read only when the
index does not know the document as it is on disk, M1's rules applied and
written back, an unreadable document dropped from the index, a fresh index
rebuilt whole first), the trash sweep / purge / Empty trash / `existingImport`
/ transfer catalogue / probes over the index; 283fd0a every screen off the
arrays, the pre-M2 array pipelines and `SceneQuery`'s substring matcher gone;
W4 the export's marker and record counts read from the file's last kilobyte
(`LibraryExportFormat.readTrailer`) and the lists driven by the index's rows
with one record per visible row or tile). Report:
`data-model-audit-reports/scratch-m3-arrays-2026-09-14.txt` — the walk: 366
in 0.25 s, 10,000 in 1.5 s; bootstrap, six faults, registration / grade /
delete each one document; 36/36 identical to M2 on the Mac and the simulator;
resident memory 117→140 MB (Create) and 123→183 MB (Gallery) from 366 to
10,000 projects. **Owed from M3:** the Projects tab's macOS `List` instantiates
every row eagerly (1 GB at 10k) — a paged ForEach ("lists take pages") is the
fix and a visible change past N rows, so a design call; a "Preparing the
library…" state for the one launch that rebuilds a fresh index (the lists show
the empty state for those seconds — pre-existing since M2, a design call); the
export's one-time regeneration on a big library builds a 73 MB JSON tree in
memory (M4 retires the export); `refreshShapeSummaries` still stats every
register on each Gallery visit; the real library's first launch (walk + the
schema-2 index rebuild, ~8 s on the queue) and audit; the device timing.
**M4 next** (one release after M1, by decision): stop writing the export,
retire `LibraryManifest` and the manifest-level migrations, per-document
`formatVersion` migrations, `lapse audit` over documents, the Python readers
to the index. **M5:** the `apply(change)` funnel and the journal —
`updateCapture` / `store.update` is its seed.

### Asset metadata (IPTC Core), the index at scale, and the Lightroom catalogue

**Detail:** [data-model-scale-and-metadata-2026-09-12.md](data-model-scale-and-metadata-2026-09-12.md)
(Part 2 of the data-model audit) · **Raised:** 2026-09-12 (Steven) · **AUDIT
DONE 2026-09-12, no implementation** · large (metadata + panel + index + import
tool), with a design-first pass owed for the Gallery panel

Steven's brief: user-editable metadata in the Gallery's right-hand panel
(title, caption, copyright, creator, rating, copyright status and URLs,
contact address through website), imported from files that carry it, camera
and GPS preserved; sustainability at 100k–1M projects; the Lightroom
catalogue migrated in. Findings: the field list IS IPTC Core in XMP, and every
example file's descriptive metadata already survives an import on disk but
nothing reads or shows it; the Lightroom catalogue holds 13,532 images of
which 72 % are frames of LetsLapse projects already on the volume, so
per-asset records are the migration itself; a JSON index is measured fine to
~10k projects and fails on a phone by 100k (367 MB resident) and on the Mac by
1M (4.4 s decode, 2 GB), while SQLite answers everything in < 5 ms at 1M.
Recommendation: per-asset `metadata.json` with an `imported` and an `edited`
layer and one XMP mapping table in the Kit; tags become keywords; the index
becomes SQLite (a rebuildable cache — the truth stays in per-project JSON);
`Projects/` stays flat because Lightroom's root folders point into it; a
read-only `lapse import-lightroom` tool that attaches per-frame metadata to
existing projects and creates Photo projects for the ~3,800 standalone images.
**2026-09-13:** the metadata half shipped as Milestone 1 of the Phase 1 work
(see the entry above) — per-asset lines in `assets.ndjson` + `metadata.json`,
the mapping table, the reader, the panel. **Later the same day:** the SQLite
index shipped as Phase 3 (Kit `LibraryIndex`, `lapse index`; the app's read-side
switch to paged queries is the open half — see the entry above) and the
Lightroom tool as `lapse import-lightroom <catalog> --library <root> [--dry-run]
[--limit N] [--force]` (commit a16b242): read-only and `immutable` on the
catalogue; frames inside `Projects/<id>/source/` get the catalogue's rating,
caption, copyright, creator, place, keywords, capture time, camera and exposure
as their `imported` layer over the file's own (a person's `edited` layer is never
touched); every other still or movie becomes a project folder holding a COPY of
the file plus its record, `metadata.json` and a `project.json` (develop settings
→ the whole-picture grade through `LightroomImport`, keywords → tags) that the
app adopts at its next launch; collections become a keyword each; the pinned
projects and every action go to `<root>/Lightroom/migration.ndjson`, which makes
a re-run idempotent; it refuses while the Mac app holds the library's lock. Four
Kit tests over a synthetic catalogue with Lightroom's own table names. **Not yet
run on the real catalogue** — by instruction it was not opened this session;
the run is Steven's: `--dry-run` first (it lists the root folders and which
LetsLapse projects they are), then `--limit 20` as a trial, then the whole
thing with the Mac app quit, then a launch to adopt the created projects and
`lapse audit --rebuild-index` / `lapse index --verify` after. Part 2 §6's
verification (per-root counts, the four example files, an export read back
through ImageIO and Lightroom) is owed with that run; metadata EXPORT (record →
XMP in exports) is still not built, so the last of those cannot pass yet.

### Shape-mation · Match, Sort and Timing — shipped 2026-09-11, owed follow-ups

**Raised:** 2026-09-11 · **Size:** small (what is left)

Designed in the morning (signed off), built in the afternoon — code from the
mirrors. Kit: `ShapeMatch` (per-family strictness, oval ratio/angle,
rectangle aspect class + orientation), `DetectedShape.rectifiedAspect` from
the register's new `Representative.horizontalFieldOfView` (Zhang–He via
`NormalizedQuad.rectifiedAspectRatio`; `family` now judges the effective
aspect), `ShapemationTiming` (fps 24/25/30/50/60, holds in seconds or frames,
ramp start → middle? → end interpolated on exact anchors, whole frames per
photo), `ShapemationSort` (share of the frame), the plan's per-family
transforms (circles un-tilted, ovals turned level, quads placed by homography
onto the class rectangle), per-item holds in the renderer; 8 tests. App: the
Match and Timing steps, Sort on the projects step, the estimate on Output,
the record carries match/sort/timing; the lens reaches the register from the
shutter (`CameraController.currentHorizontalFieldOfView`, zoom-aware) and from
EXIF `FocalLenIn35mmFilm` on import; the Masks-tab save re-rectifies. A
7-photo render came out at exactly the estimate (159 frames · 6.36 s at 25).

Owed:
- **A device run** for the lens: a fresh capture's register should carry
  `horizontalFieldOfView` and its quads a `rectifiedAspect`; the Rectangle
  Match footer then reads "N of M" instead of "0 of M". The zoom-aware FOV
  (constituent's format narrowed by the crop above its switch-over factor)
  is derived, not measured — check it against a known rectangle.
- The Mac reports no field of view (`videoFieldOfView` is iOS-only), so Mac
  captures are matched as seen; imports still get EXIF.
- The oval Custom chip seeds 0.65 and steps 0.30…0.85; the rectangle Custom
  steppers run 1…32 — both unstyled Steppers for now.
- The Sort's "Newest first" keeps the builder's capture order (oldest → newest
  as loaded); rename or reverse if that reads wrong in use.

### Auto shape mode — shapes found live on the Photo viewfinder, recorded at capture

**Raised:** 2026-09-11 · **Size:** medium · **Status:** in build (code first, by Steven's call)

Shooting for a Shape-mation deliberately: with the capture screen in **Photo**
mode, a toggle in the shutter cluster (slot 4, where the Hand was) arms a live
shape pass on the preview tap; found ellipses and quads are traced on the
viewfinder in amber; tapping one removes it; the shutter records what is still
on screen into the new project's `shapes.json`, and a background pass on the
captured file snaps each kept shape to its full-resolution fit. Decisions taken
2026-09-11 (Steven):

- **The Hand (capture when steady) is retired everywhere.** It only ever gated a
  blended Photo burst and Bulb (`firePhotoCapture` / `fireBulbCapture`); in
  Interval and Video it toggled a flag nothing read. Blended bursts and Bulb now
  fire at once. `SteadinessMonitor` stays for the Interval tail-frame log and the
  Scanner's veto.
- **Provenance, not exclusion.** Shapes left on screen are written with
  `source: .captured`; shapes the full detector finds in the file that were never
  on screen are written as `.detected`; a photo detection that overlaps a
  dismissed live shape is dropped. Find shapes keeps captured shapes the way it
  keeps drawn ones.
- **Reset is the toggle.** Turning the button off and on again forgets every
  dismissal and re-shows everything. An undo control can come later; this is a
  field-test build first ("before true engineering focus and UX").
- **Live profile.** One contour pass per sample (dark/light alternating), 384 px,
  plus the rectangle request; one sample in flight at a time; a shape is held
  ~1 s after it was last seen so the overlay does not blink between samples.
  The on-device rate is the open measurement (Mac estimate: a full eight-pass
  sweep is 1–2 s per frame, so the sweep itself is not live).

**First field test, 2026-09-11 (16 Pro, Steven):** 25–95 ms per contour pass —
ten times faster than the estimate, the 5 Hz cap is the limit. Three things the
test found and the same day fixed: `VNDetectRectangles` reads a round coaster
as a rounded square (a spinning "cage" per circle) → an **edge-support gate**
on quads (fraction of the perimeter with an edge under it; windows 0.55–1.0,
cages 0.00–0.20, gate 0.45) plus "an ellipse beats a quad over the same
bounds"; a matte disc on a pale table is lost at contour contrast 2.0 → the
live sweep is `[1.0, 2.0]`; a tap anywhere *inside* a traced shape was a
dismiss, so a facade's windows swallowed the focus taps and the misses pinned
the lens for the 5× that followed → **dismiss is a tap on the amber line**
(22 pt corridor), the picture inside still focuses. Also: the finder is
`@Observable` so its samples re-render the overlay and not the capture body
(the stutter Steven saw), and `lapse shapes <image> [--live] [--family …]
[--sensitivity …] [--size …] [--verbose]` runs the same machine on any file
(`LAPSE_SHAPES_DEBUG=1` prints each quad's support, `=<path>.png` dumps the
edge map).

**Field-test dials (Steven's brief, 2026-09-11):** with the toggle on, three
dials join BLEND — **SHAPES** All / Circular / Rectangular, **SENSITIVITY**
High / Medium / Low, **SIZE** All / Large / Mid / Small (`ShapeSearch` in Kit:
family skips the other half of the machine — Rectangular ~2.5× cheaper;
sensitivity is the contrast sweep and the gates — Low one pass; size is a
floor/ceiling on the short edge AND the live resolution — Large 256 px, Small
512 px; the file pass looks for the same family and size at its own gates).
Steven is torn on SIZE; it stays until the field says.

**Textured circles — the edge-point pass (built 2026-09-11 afternoon).**
`EdgeCircleDetector` in Kit: Sobel (vDSP) → percentile threshold + thinning →
gradient-direction Hough (both signs, every radius) → vImage max-filter peaks
→ per-centre radius histogram of *radial* edge points → support (share of
2πr), coverage (36 bins, filled from 40 % of the rim's own median bin) and
largest angular gap ≤ 6 bins (an arch has 18) → Halir–Flusser fit on the rim's
points. Accepted rims claim their edge points; the tracer's ellipses claim
theirs first (a marble coaster's veins + a third of its rim read as a circle
otherwise). Finds the facade medallion live (0.68 support at 384 px) and in
the file; 7 ms in release, ~50 ms in a Debug build after the hot loops went
through unsafe buffers. Synthetic sunburst + arch test pins it. Known: one
0.36 phantom on the marble coaster's bevel in the file pass (`.detected`).

**Performance regression found by Steven's 13:21 recording:** the viewfinder
ran at a steady 8.3 fps with the toggle on (30 fps in the 09:24 recording).
Cause: the tap only spaced sample *starts* 200 ms apart, so once a Debug-build
sample (4 contour passes + Hough at -Onone) outgrew that, the tap queue ran
back-to-back at `.userInitiated` and iOS throttled the camera. Fix: a
duty-cycle governor in `ShapeFrameTap` (rest ≥ 1.5× the sample's own time),
`.utility` QoS, and a log-only `systemPressureState` observer while the tap is
attached (`shapes: camera pressure …`). Also the SENSITIVITY menu pulsed while
open — the documented UIMenu-cross-fades-on-re-render trap — fixed by making
each dial its own `Equatable` view with `.equatable()` like BLEND.
**Verified on the phone the same afternoon — and the 8 fps had a different
cause than first thought.** The tap now logs the camera's own period from the
frames' presentation timestamps: the tele ran at exactly 10 fps because the
app remembers a per-lens frame rate (`captureSettings.…Telephoto…frameRate =
10`, an Interval acquisition rate) and applied it to Photo mode's viewfinder;
the wide ran at 25. Fix: `CameraController.setPhotoViewfinder` — Photo mode's
viewfinder asks for the format's own rate (≤ 30) and never persists it
(`photo viewfinder: 30.0 fps (stored 10)`); this also stops the ISP using
100 ms exposures that blurred every rim at 5×. Two more bugs the same run
found: tracks expired (0.8 s hold) faster than a slow sample cadence could
confirm them — hold and the sightings-to-show now follow the measured sample
period; and a shutter with nothing kept skipped the file pass entirely — every
shutter with the toggle on now runs it (the 15:01 photo: `0 kept, 1 found in
the file, register 0 captured + 1 detected`). A window pane with curtain folds
read as a circle (four tangent clusters, four ~40° holes) → at most two holes
wider than 30° around a rim. Tap-to-focus: a tap whose hunt never began is left
on continuous auto-focus instead of pinned where it was. **Field-test with a
Release build**: Debug samples were 200–1000 ms (`-Onone` Kit) and heated the
phone to `camera pressure serious`; Release samples are 35–50 ms at 5 Hz on the
same scene (`xcodebuild … -configuration Release -derivedDataPath <scratch>`).

**Field-test intelligence (2026-09-11, Steven from the street: "the more that
we log, the more that we can know has a good strike ratio").** Every capture
made with the toggle on now writes a `viewfinder` block into its
`shapes.json` — `ViewfinderTrail`: the dials, the lens, samples landed and
samples that found anything, kept/dismissed, and `ShapeDetector.Diagnostics`
for the live pass's last sample and for the file pass: counts (quads offered,
contours, fits, rim peaks, ms) plus the 24 nearest-miss refusals with the
gate each failed ("residual 0.093 > 0.080", "rim support 0.29 < 0.35", "4 wide
holes in the rim > 2"). Written even when nothing was found — a viewfinder
that was on and never sampled records that too. Read it back with
`lapse shapes <project>/source/frame-00001.jpg --trail` (and `--verbose` to
re-run any profile on the file with the same explanations). The console
logs the last sample's refusals when a sample finds nothing, and the file
pass's when it does. Owed: the clock-dial miss from the street (5×,
All/High/All) — pull the log and the photo, run `--trail`, tune from it.

**Review of the 37 "Shape testing" shots (2026-09-11 evening, Mac library, read
only).** Provenance: 20 registers with `captured` shapes (toggle on), 11
`detected`-only (Find shapes / the file pass), 6 empty; no `manual` shapes in
the Mac copies. Today's file pass finds the main round target in ~26 of the
30 pictures that have one (medallions ×3, rose windows, round signs, manholes,
the wheel, the doorbell, the oval window, the camera lens); of the 50 shapes
kept on the viewfinder only 17 (34 %) are confirmed by the file pass — the
live 384 px pass is generous and the 5 s hold keeps skewed quads (cobbles,
building corners) that a person did not tap away; the older Find-shapes
registers' extras confirm at 57 %. Explained misses (from `--verbose`): the
Bohemia sign's rim is broken by its bracket ("rim gap 70° > 60°"), the small
no-parking sign at 1/8 frame has 0.24–0.26 support (< 0.35; SIZE Small would
look at 512 px), the valve's ellipse residual is 0.056 (> Medium's 0.040,
< High's 0.06), the clock dial is found on the still by the live profile but
was never sampled at 5× in the street (the trail will say why next time).
False-positive classes: tram windscreens (an arc + roofline), building corner
+ sky, cobble rings, the yellow doorbell box read as circles. **A rim-polarity
gate was tried and rejected** (share of rim points whose gradient agrees on
which side is brighter): real rims score 0.50–0.79 (stone relief lit from one
side, a black lens with a bright ring, signs with a dark border) and the false
ones 0.52–0.72 — no threshold separates them; reverted.

**Photo captures now write `capture_log.json` (2026-09-11 evening, Steven:
"a lot more information is captured in interval shoots, but not in photo
shoots").** The plain still path (Photo one-shot/burst/Bulb and unblended
Interval) writes the same session document the blend pipelines always did,
with a new `conditions` block on every path: the stop ("5×") and whether it is
optical / sensor-crop / digital-2x, the physical lens, zoom and crop relative
to that lens (the wide at 2×, the tele at 10×), field of view and 35 mm
equivalent, format (jpeg / jpeg-flat / dng), thermal state at the shutter and
at the end, camera pressure, battery, low-power, focus mode + tap pin + lens
position, exposure mode/lock, stabilisation, pose, app/OS, and the shape dials
when the toggle was on; `frames[]` carry each still's own EXIF (ISO, shutter,
aperture, EV). **Capture Flat used to strip the camera EXIF** (the re-encode
wrote orientation + GPS only — every flat shot in the review has no lens,
focal length, ISO or shutter): EXIF/TIFF/ExifAux/MakerApple now ride through.
`lapse shapes --trail` prints the conditions; `tools/shape_field_report.py
<projects> [--tag "Shape testing"]` joins register + trail + conditions + a
fresh pass per shot and groups strike ratios by stop, lens kind, format,
thermal, pressure, dials and focus — the tool the next field shoot is read
with. Note iOS gives a thermal *state*, never a temperature.

Owed after the field test: design mirrors (the six `shutter-cluster.photo-*`
component states lose the Hand and gain the shapes glyph; `capture-photo.shapes`
mirrors in both orientations with the three dials; the idle Interval/Video
cluster states lose slot 4; INDEX rows ⏳), an undo for a dismissed shape, the
Mac's Photo mode (the tap is not iOS-gated and it compiles, but only the iPhone
is verified — the Mac takes the fitted fallback mapping since
`CameraController.previewLayer` is iOS-only), persisting dismissals into the
register so a later Find shapes run does not resurrect them, and a control run
for the 5× blur with the toggle off (focus-tap, then 5×) to confirm it is the
existing lens-pin-survives-a-lens-switch behaviour.

### Shape register schema v2 — adopt the benchmark's run blocks in the app

**Raised:** 2026-09-11 · **Size:** medium

The offline benchmark (`tools/shapebench`, brief and findings in
`docs/shape-benchmark/`) writes one file per project in schema v2: `{ schemaVersion: 2,
projectId, runs: [ { detectorId, detectorVersion, paramsHash, params, runAt, durationMs,
assets: [ { assetId, frameWidth, frameHeight, shapes: [ … ] } ] } ] }` — shapes carry
primitive/subclass (rectangle/square, ellipse/circle), centre, extentRatio + sizeBand,
aspectRatio ≥ 1, orientationDeg in [0,180), vertices or axes, confidence, and the §3
rule figures. Runs are keyed by detectorId + detectorVersion + paramsHash; "already
analysed" means that key already ran; nothing is ever flushed. The rig's
`work/results/<id>.json` files are shaped to drop into `<project>/shapes.json` the day
`ShapeRegister` learns v2: decode `runs[]`, migrate a v1 register into an
`apple-vision-register` block with per-shape provenance (captured/detected/manual), key
the Find shapes skip (`ShapeFinder.swift`, today `existing.isAnalysed`) on the run key,
map the SHAPES/SENSITIVITY/SIZE dials onto the §3 bands and thresholds, and keep the
Masks tab, Gallery SHAPES rows and the Shape-mation builder reading one chosen run
(a "which run" choice on Find shapes needs its two SVG mirrors updated). **The decision landed
2026-09-11 evening** (`docs/shape-benchmark/report.md`): no ranking layer — the §3 rules + size
floor accept a median of 2 shapes per picture; the gap is recall (57 % for the geometric
reference, 19 % for the shipped Find-shapes pass against 68 hand labels), on ornate rims and nested
shapes. **2026-09-12: the reference's proposal maps are ported into the still-photo pass**
(`Kit/…/Shapes/RegionProposals.swift`, on by default in the file profile, off live): with the
floor at 0.10 of the short edge and the **flat nest policy** (decided 2026-09-12: every member is
a shape, Shape-mation takes the biggest — merging is near-identical only, `sameShapeIoU` 0.9) the
Kit passes the reference: on the completed 37-picture / 153-label set 72 hits against the
reference's 66 (recall 47 % vs 43 %, precision 52 % vs 61 %). SIZE = All's file floor is 0.10
of the short edge (decided 2026-09-12). Run in the Mac app (Find shapes over the 37): 19 % → 46 % of the labels in the
registers themselves. Next: bump `currentDetectorVersion` (Find shapes re-analyses older
registers — 199 in the Mac library carry version 1), a phone run (time, heat), then this
adoption.


### Shape-mation — from spike to feature: timing, accuracy, design mirrors, collections

**Raised:** 2026-09-10 · **Size:** medium

The spike (`tools/shapeseq`, findings in `docs/shape-sequence-spike/report.md`)
became a product spike the same day: Create ▸ *Create Shape-mation* opens a
sheet with **Find shapes** (one representative picture per project through
`ShapeDetector` → `shapes.json`, only projects without a register), **Create
shape slideshow** (family → projects and the instance in each → mode → output
size from the picked pictures → render) and **List Shape-mations** (play, share,
delete; videos in `<root>/Shapemations/`). Kit: `Shapes/` (geometry, fit,
detector, register, `ShapemationPlan` + renderer, unit-tested). Verified on the
Mac and the iPhone simulator against a 13-project scratch library (registers
identical on both); 1 s per photo, hard cuts, no rotation for circles.

- **Design mirrors drawn 2026-09-11** (code first by Steven's call, mirrored the
  next morning from the iPhone 16 Pro simulator and the Mac Debug build): the
  Shape-mation screens (`docs/design/iOS/shapemation*.portrait.svg`, nine files,
  referenced from the macOS/iPadOS rows), the Masks tab's `photo-viewer.masks.svg`
  (macOS, refreshed: three rail tabs, **＋ Shape** in the toolbar, the **Shapes**
  card under the mask detail card) plus `photo-viewer.masks.shape.svg` (a register
  shape selected: amber handles, the shape detail card with name, caption, Use as
  Radial mask, Remove), the Gallery sidebar SHAPES section in all three Mac gallery
  mirrors and the new iPhone `gallery.library-sheet.portrait.svg`. Still undrawn,
  🟡 Planned in the INDEX files: the Find-shapes progress card and the builder's
  rendering card (both finish before a screenshot can land; a hook to freeze them
  would fix that), and the Masks tab on iOS (no iOS photo-viewer mirrors exist yet).
  `LL_SHAPETOOL=ellipse|rect|square` arms the shape tool; `LL_SHAPES=…` lights
  Gallery rows.
- **Small things the mirror pass saw in the shipped screens** (reported by the
  drawing agents, none fixed): tapping *All Collections* in the iPhone Library
  sheet switches the tab underneath but never dismisses the sheet; the builder's
  Mode summary says "Canvas 3949×4032" while Output and the record say
  "3948×4032" (two roundings of one width); the family card draws a hairline
  after its last row; the Find-shapes paragraph will re-wrap on a 393 pt phone
  (its first line is 335 pt wide against 329 available); Find shapes backs to
  "Shape-mation" while the list backs to "Back" (the long title leaves no room);
  `LibraryFilterRow` fixes the symbol's width but not its height, so rows with a
  tall symbol run 1–2 pt taller. Also the iPhone 16 Pro simulator is 402×874 pt,
  not the README's 393×852 canvas, and the app's tab-presented sheets land at
  safe-top + 10 (69 on the canvas) where the older design-first sheet mirrors draw
  56 — worth a README note and a sweep of those files.
- **Rectangle shapes as masks.** Only an ellipse can become a mask today (a Radial
  copy); a quad needs a polygon mask kind through `MaskShapeRenderer`, the
  thumbnails and the export bake.
- **Timing and logic** (Steven: "we will work on the timing and logic later"):
  per-item duration, transitions, ordering choices (chronological / by size),
  and asking for the output frame *first* so it filters which photos qualify.
- **Accuracy** (Steven: "we will optimise this"): circles that are not quite
  circles and rectangles that are not square. Known levers from the spike: the
  residual gate (0.04 here), an edge-point ellipse detector for textured dials,
  a texture gate on quad interiors (blank sky and night shadows still pass
  `VNDetectRectanglesRequest`), a `CVPixelBuffer` overload for a live viewfinder.
- **Collections** cannot hold a Shape-mation yet — they hold blended clips, not
  photo assets; adding photo-asset support is the route to putting one in a
  collection.
- **Mode 2 (crop) refuses an empty intersection** with a message rather than a
  fallback; a picker that shows the crop live would let people trim the outlier.
- **An iPad run and a device run are owed**; the Mac was verified on a Debug
  build pointed at a scratch root via `-storage.libraryRootPath`.
- **Gallery SHAPES rows (2026-09-11).** The Gallery sidebar / Library sheet lists
  Ellipse · Rectangle · Square · No Shapes under COLLECTIONS, read from each
  project's `shapes.json` (`AppModel.shapeSummaries`, `ShapeFilter`). Owed: the
  three gallery mirrors, an iPhone run of the sheet, and — if wanted — counts
  on the rows and a Circle / Oval split (the register already knows the family).

### Batch import / export between devices and the Mac library

**Raised:** 2026-09-10 · **Size:** medium

A one-off filesystem import proved the shape on 2026-09-10: 77 Photo-mode
projects shot on the iPhone 16 Pro since 2026-09-07 were pulled with
`xcrun devicectl device copy from` (whole project folders, ~909 MB) straight
into `/Volumes/letslapse/Projects/<newUUID>/` and registered by hand the way
`AppModel.installStagedProject` does — record copied verbatim, fresh `id`,
`importedFromID` = the phone's id, `addedAt` = now, `createdAt` kept — with
the Mac app quit for the `library.json` write and relaunched after. Every
file was checked against `devicectl device info files --json-output`
(recursive, with byte sizes).

**What the feature should do:** select many projects (a date range, a mode,
"everything since my last pull") on either side and move them in one job —
the network transfer (`ProjectTransferClient`) already installs a staged
tree per project, so the work is a multi-select picker over the catalogue,
a queue with per-project progress and resume, and the matching batch `.lapse`
export. The cabled fast path (USB via devicectl) is a Mac-side nicety, not
the product path.


### Presets — the photo × preset matrix's remaining doors

**Raised:** 2026-09-08 · **Detail:**
[presets-lut-spike.md](presets-lut-spike.md) · **Size:** medium (staged)

The spike, the design pass and the code landed the same day: a *Manage
presets* row under *Interval ladders* opens the **Presets** sheet
(`App/ManagePresetsView.swift`) — a preview frame every row is rendered on,
LetsLapse / Your presets / LUTs, import of `.cube` LUTs and Lightroom preset
`.xmp`s, a preset's screen with a draggable before/after, rename, what it
changes, duplicate and delete, a LUT's screen with strength and file facts.
The Kit renders a `.cube` as the last colour operation (`CubeLUT`,
`GradeRecipe.lut`, 11 tests); a LUT preset is a `CustomPreset` at Original so
it is a chip everywhere; a graded project carries its own copy of the cube.
Verified on the iOS simulator through `LL_PRESETS=list|preset|lut|import`.

**Open, in order:**

1. **The Edit screen's LUT row** — strength per project (the LUT detail's
   footer promises it). Design first: an Effects-section row with the
   preset's name and a strength slider; `PhotoAdjustments.lut.strength`
   already renders and keyframes as a value.
2. **Use case 1 across projects** — multi-select in Projects/Gallery and a
   batch *Apply as starting point* with a progressive before/after sheet
   (spike §3, product shape 3). The state model needs nothing new.
3. **A real `.cube` through the Files picker on a physical device**, and the
   Mac app against the real library (`/Volumes/letslapse`, seven saved
   presets). The picker path is verified on the simulator (Steven's
   Teal_and_Orange.cube through Files → On My iPhone, 2026-09-08); a device
   adds iCloud Drive and third-party providers, and the share sheet's
   "Open in LetsLapse" is a separate door not built yet (a document type for
   the cube plus an `onOpenURL` branch).
4. **A Lightroom preset `.xmp` fixture** for the import (none on this Mac;
   Lightroom CC exports one from a preset's context menu) — the parser is the
   sidecar's, the mapping drops masks and says so.
5. **Used on → the filtered Projects list**, and thumbnails in the preview
   picker; both are plain counts / plain rows today.
6. **Log-input LUTs**: the amber note is there; a Capture Flat clip as the
   preview frame would let such a LUT be judged honestly.

### Lightroom parity — second pass done, controls need their sliders

**Raised:** 2026-09-07 · **Detail:**
[lightroom-parity-handover.md](lightroom-parity-handover.md) · **Size:** medium

The handover's ranked list was worked through on the evening of 2026-09-07
(see the handover's "Second pass" section for the numbers). Done: the mask
inside/outside rule verified by render; the masked stage and the shape
renderer moved into the Kit so the bench scores whole renders; Dehaze and the
HSL panel built as real controls (model, import, every render path) and the
straighten angle carried on import; two silent bench bugs fixed (the straighten
sign was inverted, and Lightroom's mask geometry is in the sensor frame).

**Open, in order:**

1. ~~**Sliders for Dehaze and HSL.**~~ Built 2026-09-08, code first at
   Steven's call: Effects has a Dehaze slider, the panel has a **Color Mixer**
   section (Hue | Saturation | Luminance picker over eight swatched band
   rows), the masked-grade card has Dehaze too. macOS mirror drawn from the
   running app (`docs/design/macOS/photo-viewer.mixer.svg`), **awaiting
   Steven's macOS review**; the iOS stacked-card mirror is still owed (the
   iOS viewer files were already stale from the Rotation section).
2. **Sky masks in the bench.** Three files carry an AI sky mask the CLI
   cannot draw (no segmenter outside the app); they are marked † in the
   ledger. Either teach `lapse` to load the CoreML segmenter or let it take a
   mask PNG per file.
3. **The crop rect.** The straighten angle imports as the level; the rect
   still does not — the import says so ("the crop rect itself is not
   carried; the level's inscribed crop stands in"). Since 2026-09-12 there IS
   a crop control (`PhotoAdjustments.crop`, a `FrameCrop` in the levelled
   frame's unit square, the Edit screen's Crop group), so the mapping is now
   just `CropLeft` / `CropTop` / `CropRight` / `CropBottom` into that
   rectangle — with one thing to establish first on a straightened AND
   cropped sidecar from the corpus: whether Lightroom's rect is expressed in
   the frame before or after `CropAngle`, since ours lives in the levelled
   frame. Nine of twenty files are cropped.
4. **HSL is not keyframe-blended** (held from the earlier keyframe) and the
   post-engine passes skip the pixel-peep loupe (a patch-local airlight
   estimate would not match the frame's). Both are documented in the code.
5. ~~**Post-crop vignette (8/20)**~~ and **grain (2/20)**. The vignette is
   built (2026-09-12: signed intensity, a midpoint, `PostCropVignetteAmount`
   imported sign-flipped with `PostCropVignetteMidpoint`; feather, roundness
   and style are reported as unsupported) — but the still and blend paths
   centre it on the whole frame rather than the crop, which is the
   *Post-crop vignette centring* entry above. Grain remains the next unbuilt
   control by usage.

---

### Render variants — wire the app to the switch, and get masks into the bench

**Raised:** 2026-09-07 · **Size:** medium

The apparatus shipped 2026-09-07: `RenderVariant` / `RenderAxes` /
`RenderVariantRegistry` in the Kit, `lapse variants`, `lapse lightroom
--render --variant`, `tools/render_bench.py`, and a ledger in
`docs/render-variants/`. The contract — append-only registry, results in git,
one command to regenerate — is `docs/render-variants/README.md`. First run on
`batch1` took the baseline from ΔE 12.76 to 7.78.

**Open:**

- **The app does not honour the selected variant.** `RenderVariantRegistry.current`
  exists and round-trips through `UserDefaults`, but only the CLI reads it.
  `PhotoGrader` needs to consult it for decode path, exposure trim, slider
  scales and the tone curve, plus a Settings picker and an `LL_VARIANT` hook —
  the way `RawDecodePath` already does all four. Until then "test A against E
  inside one build" is true of the bench and not of the editor, which is the
  weaker half of what was asked for.
- ~~**The bench cannot see masked grades.**~~ Done 2026-09-07: the masked
  stage is the Kit's `MaskedGradeStage`; preview, export and bench share it.
  AI sky masks remain app-only (see the Lightroom parity entry).
- **The remaining ~7.8 ΔE is structural.** It varies with tone and position,
  which is a profile's tone-dependent hue map and is not reachable by any
  global axis now in `RenderAxes`. The next honest variant is a real profile
  application (hue/sat map included), not another scalar.
- **`exposureOffset −0.47 EV` is fitted to five files.** It is the single
  largest win so far and also the one most likely to be a property of this
  camera, this ISO range, or this corpus. It wants a second corpus before
  anything ships depending on it.

---

### Lightroom import — measure the gap, then decide what to close

**Raised:** 2026-09-07 · **Size:** the measurement is small; what it implies
may not be

Reading a Lightroom `.xmp` shipped 2026-09-07: `LightroomSidecar` parses it,
`LightroomImport` maps it, the editor offers it where a sidecar sits beside a
frame, and `lapse lightroom <file.xmp>` prints the whole report headless.
Verified end to end on `_WEX3825.ARW` (Sony A7 IV, Lightroom 17.5) — ten
settings and a radial mask carried, three things named as lost.

**MEASURED 2026-09-07** against Lightroom's own full-resolution sRGB export of
the same file, with `tools/lightroom_compare.py` (mean-luminance offset in
stops, CIEDE2000 distribution, an eleven-band tone table and a region grid).

The headline: **mean ΔE2000 9.1, median 7.8, and only 2.5% of pixels under
ΔE 1.** Visually the two are plainly the same photograph and the same edit,
but ours is flatter and cooler — Lightroom's sky keeps its drama and its
orange; ours washes out. Exposure is close (+0.14 stops); colour is not.

What the attribution runs showed, in the order they were tried — **none of
them is the answer**:

| tried | ΔE2000 |
|---|---|
| as imported | 9.13 |
| + Adobe Color's own look curve | 8.89 |
| decode path `ciraw` | 9.13 (identical — with no WB offset the two paths coincide) |
| decode path `dcp`, the real *Sony ILCE-7M4 Adobe Standard.dcp* | 9.27 (worse) |
| best-fit Highlights/Shadows calibration (shadows ×0.7) | 7.83 |
| + a perfect per-channel white-balance gain | 7.82 |

So the tone curve is worth ~0.25, the camera profile nothing, slider
calibration ~1.3, and a global colour correction ~0. **The residual is
structural** — it varies with tone and with position, which is what a
profile's tone-dependent hue map does and what no global scalar can imitate.
That is the same conclusion the DCP work reached from the other direction.

Two honest limits on the measurement:

- **It excludes the masks.** `lapse grade` renders the whole-picture grade
  only, and the radial covers the sky. The clean number is therefore the 57%
  of pixels OUTSIDE the mask: **mean ΔE 6.5**, and that one no omission can
  bias. Inside the mask reads 12.6 and is not attributable until an
  app-rendered export exists.
- **Getting one is now the first job.** The app applies masked grades in
  `SceneAwareCompositor`; the CLI cannot. Either give `lapse` the masked
  stage (it is pure Core Image and has no app dependencies) or add a headless
  full-resolution export, then re-run the comparison.

What this means for the feature: the importer carries the *intent* faithfully
and the numbers exactly. It does not, and on this evidence will not without
new machinery, reproduce Lightroom's render. That is worth saying in the
product rather than implying otherwise — the report sheet's footnote already
does.

**Open, in the order the measurement would rank them:**

- **The `Flipped` / `MaskInverted` composition is INFERRED, not documented.**
  `LightroomImport.appliesOutside` assumes a radial's grade lands inside when
  exactly one of the two flags says so. Get it backwards and the grade is on
  precisely the wrong pixels. One reference render settles it, and it is one
  line to correct.
- **A tone curve is still worth having, but it is not the gap.** Measured at
  ~0.25 ΔE on this file (see above), so build it because a curve is a control
  people want, not because it closes the distance to Lightroom.
- **AI masks: sky is SUBSTITUTED (done 2026-09-07), the rest are still lost.**
  A `Mask/Image` whose `MaskSubType` is 2 (or whose name starts "Sky") is now
  routed onto this app's own `MaskRef.sky`, so the correction transfers and
  only the boundary differs. Subject, background and object masks have no
  region here and are still reported as lost.

  **What the `crs:Table_<MaskDigest>` payload actually is, measured
  2026-09-07** — so nobody repeats the analysis:
  - 229,183 characters, exactly **85 distinct**, from an XML-safe alphabet:
    standard Ascii85 (`!`…`u`) with the 8 characters unsafe in an attribute
    (`"` `&` `,` `;` `<` `>` `\` `_`) replaced by `v`…`}`.
  - It is **NOT Ascii85-of-bytes.** Under every alphabet order, digit
    direction and offset tried, ~3.3% of 5-character groups exceed 2³²−1 —
    which is precisely the fraction expected of *uniformly random* base-85
    digits (85⁵ − 2³²)/85⁵ = 3.2%. A real Ascii85 encoder emits none.
  - Entropy is **6.408 bits/char against a 6.409 maximum**, flat across the
    whole payload. The underlying data is already compressed before encoding,
    so there is no structure to grab onto from the outside.
  - Conclusion: it is a whole-block or large-chunk base-85 radix conversion of
    a compressed stream, and cracking it means identifying Adobe's container
    as well as their base-85 variant. Open-ended, and brittle even if it
    lands — an undocumented format they are free to change. The payload is
    kept in `LightroomSidecar.maskTables` should anybody want to try.
  - **The substitution is arguably the better answer anyway for this app**: a
    bitmap is one frame's sky, and a timelapse re-segments per seam.
- **The camera profile is available and unused.** `Sony ILCE-7M4 Adobe
  Standard.dcp` is installed on the bench Mac, and `RawDecodePath.dcpProfile`
  can read it. An import that names a profile should probably select that
  decode path rather than leaving the user on Bradford.
- **Local coverage is 8 fields of Lightroom's ~20.** This file only used two
  (Clarity, Temperature) and both carried. Dehaze, Texture, Sharpness, Moire,
  Defringe and the toning pair have no local equivalent.
- **Design mirror owed.** The "Lightroom settings found" card and the report
  sheet are new UI in the Editor tab and are not in `docs/design/macOS/`.

---

### Masks as adjustment layers — iOS design pass, and a device check

**Raised:** 2026-09-07 · **Size:** small–medium (one design decision, then two
SVGs and a touch-sizing pass)

The feature shipped 2026-09-07 from the Claude Design handoff *"Masks as
Adjustment Layers"*: Linear and Radial parametric masks, and a `MaskGrade` that
applies any mask's own adjustments after the whole-picture grade and before the
text overlays. It is universal — same model, same rail, same card on iPhone and
iPad as on the Mac — and the macOS mirrors are drawn
(`docs/design/macOS/photo-viewer.masks.svg`, `photo-viewer.mask-grade.svg`).

**Open:**

- **Decide how a shape is drawn and nudged on a phone, then mirror iOS.** The
  handoff sketches only the *collapse* behaviour for a small ellipse ("small
  mask · handles collapsed — zoom in to edit") and says nothing about creating
  or dragging one where the picture is the smaller half of a stacked layout.
  Drag-to-adjust is already gated off there (`supportsDragToAdjust`) for the
  same reason, so a phone can add and grade a mask but cannot comfortably draw
  one. Two files are owed once that is settled — the Masks tab and the Editor
  tab's Masks card. iOS has never had a Masks mirror at all, so there is no
  stale file to fix, only new ones to draw. **Since the 2026-09-13 editor
  redesign the card's home on the touch layouts is a stopgap:** boards 2a /
  5a have no Masks card on the Editor page, but the Masks tab's "Grade this
  in Editor" still lands on the Editor tab with a grade expanded, so the
  viewer shows `touchMasksCard` in the panel's slot only while a grade is
  expanded and no group is open (a scrollable dark sheet ≤ 50 % of the
  height on the phone, 400 pt wide bottom-right on the iPad). The Mac rail
  keeps the card, now as compact rows carrying the tool icons of the fields
  each grade moves. The real touch home is part of the same decision.
- **Verify on a device.** Everything here was checked on the Mac. The handles
  are a pointer-sized target (14pt drawn, 22pt hit area) and want a real finger
  on them; the masked-grade composite adds one Core Image pass per enabled
  grade to every preview render, which wants measuring on a phone before
  anybody stacks four of them.
- **Keyframing a MaskGrade is deferred, by the design's own decision.** The
  fields are `PhotoAdjustments` and the geometry is numbers, so both can ride
  `GradeTimeline` later; nothing in the model prevents it.

**One thing to know if the render is ever revisited:** masked grades run
**display-referred**, through `PhotoGrader.adjust` (the Core Image chain the
video path uses), not through the Metal tone engine. That is deliberate and
documented in `SceneAwareCompositor.composited` — it is the only stage the
preview and a stills-blend export share, so it is what makes the two agree. The
cost is that a masked grade cannot recover a highlight the whole-picture grade
has already clipped. Moving it into linear light means giving the engine a
masked-recipe pass and moving both callers together.

---

### Gallery item view (macOS) — the editor as a mode of the Gallery, not a window

**Raised:** 2026-09-13 · **code shipped the same day, signed off by Steven
("feel great"), design mirrors DRAWN the same evening — uncommitted** ·
**Size:** what is left is decisions, seams:
`App/GalleryView.swift` (`wideLayout`, `itemHeader`, the item-view actions),
`App/GalleryItemView.swift` (`GalleryFocus`, `GalleryItemEditor`,
`GalleryFilmstrip`), `App/GalleryPreviewPanel.swift` (`.inspector` style,
`outputSection`), `App/EditorLaunch.swift` (`EditorExitRequest`),
`PhotoViewerView` / `VideoEditorView` (`exitRequest` / `onExit`)

Steven's brief: on the Mac, Edit / Text / Shapes opened a second window, which
felt like the wrong model. Built code-first so it could be felt before it was
drawn. What the code does now:

- **Open, ⏎, a double-click, Edit, Text, Shapes and the tile menu's Edit** all
  put the project in `GalleryFocus` (owned by ContentView beside
  `galleryPath`, so a tab round-trip lands back on it). The same three-column
  `HStack` changes mode: the left column swaps the Library for the project's
  **inspector** (the preview panel in its `.inspector` dress — title/date,
  TAGS, INFO, METADATA, the Rename/Finder/Delete footer, then an **OUTPUT**
  group: New clip, Share project, the blended-clips list; no thumbnail, no
  action grid, no PRESETS), the grid and its pane swap for the editor with
  its own 330pt rail, and a **filmstrip** of the grid's current result set
  runs under everything at full width.
- **Widths:** pane 300 → **330** so the right divider never moves; the left
  column animates 200 → 330 on the way in (`GalleryColumns` — set `sidebar`
  to 330 to try the version where nothing moves). ▤ collapses the inspector
  in the item view (shared `gallery.showSidebar`).
- **Keys:** grid — ⏎ opens the selected tile; item view — ← → walk the
  filmstrip, ⎋ leaves. Arrows are now read by key code and ignore the
  `.numericPad`/`.function` flags a real keyboard puts on them (the grid's
  arrows were checking `flags.isEmpty`, which a physical arrow key never
  satisfies).
- **Exit path:** the host never tears the editor down under it. Back sends
  `EditorExitRequest(offersPresetSave: true)` (the Back button's preset
  offer applies); a filmstrip move sends `offersPresetSave: false`; both run
  the editor's own `finishExit` (persist, overlays, library flush) and then
  `onExit` — where the Gallery goes back or on to the next project. The
  page carries over on a move (Masks → Editor for a video).
- Verified on the Debug build over a scratch library (`LL_TAB=gallery
  LL_ITEM=latest`, the run skill's `hid` keys and clicks): photo → interval
  (timeline strip, Frames tab) → video (AVKit player, Editor/Text) in one
  window; ▤; Projects-and-back; ⏎ / ← → / ⎋.

**Owed / open:**

- ~~**Design mirrors.**~~ DONE 2026-09-13 evening: `macOS/gallery.item.svg`,
  `.item.interval.svg` (inspector at OUTPUT), `.item.video.svg`,
  `.item.collapsed.svg`; `components/gallery-filmstrip.<focus>.svg` and
  `output-actions.<state>.narrow.svg`; the `narrow` component set widened
  272 → 302 in place (no 272 column exists any more) and the six
  `gallery.*.svg` re-based to the 330 pane at 1310×800. Two pre-existing
  mismatches the captures showed, noted in `macOS/INDEX.md` and not fixed:
  tag chips are ~31 pt in the app vs 33 drawn; the floating tab bar is 395 pt
  wide in the app vs 358 drawn everywhere.
- **Decide the left width.** 200 → 330 slides the divider on entry; making the
  Library 330 too keeps every divider still (one constant) at the cost of
  130pt of grid.
- **Decide what "Open" means now.** Open, ⏎ and double-click all enter the
  item view on the Editor page, the same as Edit — the panel's full-width
  Open button is redundant with Edit on the Mac. The project screen
  (`ProjectDetailView`: source clips, rotate, DNG archive, review photos,
  notes) is no longer reachable from the Gallery on the Mac, only from the
  Projects tab and `requestedProjectDetailID`.
- **Export.** Steven plans an Export entry in OUTPUT; there is no graded-still
  export on the Mac yet (see "Graded still export"), so none is drawn.
- **iPadOS.** Regular width takes the same `HStack`; the item view is gated to
  macOS (`gridEditHandler` / `paneEditHandler` return nil) because the iOS
  editors carry cover chrome (`preferredColorScheme(.dark)`, the disc back
  button) a column cannot host. Same argument applies there; design once.
- **Smaller:** the inspector keeps its scroll position across a filmstrip
  move (a Lightroom habit; may want a reset to top); the header repeats the
  project's name that the window title also carries; a tab round-trip
  rebuilds the editor (the video restarts) — the tab's view is rebuilt on
  every switch, as before; the `WindowGroup(for:)` editor scenes remain and
  still serve the Projects tab's hero Edit pill.

---

### Gallery redesign — SVG design files

**Raised:** 2026-09-06 · **macOS DONE 2026-09-07** · **Size:** small (what is
left), plus one design decision

`GalleryView.swift` was rebuilt in 394e48e with the 2a layout — sidebar, 4:3
grid, preview panel, timeline mode — and shipped with no design files.

**Done 2026-09-07:** `docs/design/macOS/gallery.svg` (grid mode, all three
panes) and `docs/design/macOS/gallery.timeline.svg` (timeline mode, no
selection, selected-tag sidebar), both authored from the source; `macOS/INDEX.md`
rows added; the stale `iOS` row marked ⚠️ with what changed. The panel did not
need a file of its own — it is a pane of the Gallery screen, not a screen, so it
is drawn in place rather than in the `gallery-preview-panel.svg` this entry
originally imagined.

**Open:**

- **Verify the two macOS mirrors against the running app.** Every measurement in
  them is computed from the SwiftUI layout, not read off a screenshot: a Release
  Mac app was running and holds `library.json`, which has no serialised writer,
  so a second instance could not be launched safely. Both files are ⚠️ until
  this happens. The header-overflow arithmetic below is the part that most wants
  a real window behind it.
- **Decide the compact `galleryHeader`, then mirror iOS.** `iOS/gallery.portrait.svg`
  is stale and cannot be truthfully redrawn yet: the compact branch reuses the
  Mac header verbatim, and it is ~691pt of content in an iPhone's 361pt. Design
  decision first, then `iOS/gallery.portrait.svg` plus the sidebar and preview
  sheets.
- **iPadOS** — regular width takes the same three-pane layout as the Mac; nothing
  records that today.

**Two code fixes the mirroring surfaced** (drawn as shipped, not silently
corrected):

- **The Mac's default window cannot draw its own header.** `galleryHeader` is one
  `HStack` of eight children with no compact form and nothing that collapses
  (~691pt intrinsic). The centre column is the window less 201pt of sidebar and
  301pt of preview, so it needs a ~1193pt window; at the 760×680 default it
  overflows by ~430pt with the preview open and ~130pt with only the sidebar —
  and `gallery.showSidebar` defaults to **true**, so that is the first-run state.
  The same header is what blocks the iPhone mirror.
- **Bottom clearance is double-counted, 140pt instead of 58.** `ContentView`
  already applies `.safeAreaInset(edge: .bottom) { Color.clear.frame(height: 58) }`
  to the tab `Group`, and all three of the Gallery's scroll views then append
  their own `Color.clear.frame(height: 82)`.

Smaller things noted while drawing: the Mac window title repeats the header's own
"Gallery" (`.navigationTitle` retitles `Window("LetsLapse")`); the zoom `Slider`
is never `.tint()`ed, so its fill is system blue — the one accent-coloured
control on the screen that is not `LL.accent`; and `TimelineGalleryGrid`
hard-codes 5 columns, so the zoom slider is live but inert while Timeline is on.

---

### Blended clips list + tick-chip filter — DONE, design + code, both parts

**Raised:** 2026-09-07 (Steven — "Smarter Components in LetsLapse design") ·
**Part 1 DONE** · **Part 2 DONE** (design, code, and live verification, all
2026-09-07) · small–medium

Two-part job, both parts shipped the same day. **Part 1:** the BLENDED CLIPS
list — one row per `AppModel.BlendProject`, which can be a rendered blend, a
stacked photo/interval image result, or a time-sliced image/video export —
was drawn inline by hand in three iOS `project-detail.*.portrait.svg`
mirrors (two of them byte-identical). It is now the shared
`docs/design/components/blended-clip-row.<state>.<width>.svg` design
component AND a matching `App/BlendedClipRow.swift` shared SwiftUI view, used
by both `ProjectDetailView` and a new section in `App/GalleryPreviewPanel.swift`
(replacing the old one-line "Variations · N blended clips" meta row with a
real list).

**Part 2:** a filter over that list —
`docs/design/components/blend-list-filter.<state>.<width>.svg` and
`App/BlendListFilter.swift` — **four independent tick chips**, Blends /
Slices / Image / Video, styled like the existing preset strip rather than a
segmented control (see components/README.md's "Blend list filter" section
for why, and for the segmented-control first draft this replaced same day,
prompted by Steven: ticking every chip already means "All", so no separate
All control is needed). `BlendListFilter.matches` filters on
`blend.timeSlice == nil/!= nil` and `blend.kind`; the section header shows
the FILTERED count, not the project's total; `BlendListEmptyState` (simpler
than the design note first proposed — a generic "try ticking another chip
back on" rather than naming the specific excluded facet, since several chips
can be off at once) replaces the card when a combination matches nothing.
Wide (iOS/iPadOS project-detail, 361pt+) fits all four chips in one row;
narrow (macOS Gallery preview, 272pt) wraps to two via `ViewThatFits` — one
shared view, no per-platform layout code. `ProjectDetailView`'s
`blendedClipsSection` is already used by both its narrow (phone) and wide
(Mac/iPad ≥860pt) bodies, so this one change covers all three platforms.

One new `blended-clip-row` state (`sliced`) was added along the way to give
the design demo (`project-detail.video.filtered.portrait.svg`) something real
to filter down to. That demo also surfaced a real bug in Part 1's row
component, fixed in passing: a title-column clip-width bug (the clip must
clear "Open"'s own left edge, not its `text-anchor="end"` anchor point — see
components/README.md's "Clip-width trap").

**Verified live, both platforms, 2026-09-07:** iOS Simulator — toggling a
chip live re-filters the list and updates the header count in both
directions, and the empty state renders correctly. macOS — built fresh and
tested against a REAL project with a mixed blend + time-slice list (not a
hypothetical): unticking Blends correctly dropped the regular blend and kept
the time-sliced result, header count 2 → 1, chips re-wrapped to two rows at
the panel's narrower width. Nothing left open on this job.

### Data model — split `library.json`, stable origin ids, append-only experiment log

**Detail:** [data-model-audit-2026-09-06.md](data-model-audit-2026-09-06.md) ·
**Raised:** 2026-09-06 (Steven, audit brief) · **AUDIT DONE 2026-09-06, no
implementation** · phases 1–4 in the report's §7 · medium (phase 1) to large
(phases 2–4)

The audit inventoried every persisted store (about 35 file kinds, 83 defaults
keys, no keychain or database) against the code and both real libraries (the
Mac volume and the iPhone container). The recommendation is to keep JSON and
fix five things: per-project `project.json` with `library.json` reduced to an
index (it is 2.3 MB today, 92 % frame-name strings, rewritten on every grade
tick); `originID` / `originDeviceID` / `derivedFromOriginID` so a project keeps
one identity across devices (today every import re-mints, one hop only); the
live-blend experiment log to NDJSON (it is a full rewrite after every output,
14–19 GB of writes on a 5,000-frame shoot); a launch-time folder ↔ index
reconciliation (three orphan folders and one empty-folder record exist now,
and an undecodable manifest is overwritten by the next save); and one
serialised manifest writer with persist-before-delete ordering. Migration is
additive first, dual-write second, index third, each phase verified by a
`lapse audit` tool that diffs a rebuilt index against the real one.

### DNG archive conversion — raw → lossy / resized DNG, in-app one day

**Detail:** [dng-archive-spike-brief.md](dng-archive-spike-brief.md) (the
brief) · [dng-archive-spike/README.md](dng-archive-spike/README.md) (the
report, with `matrix.csv` / `matrix.md`) · `tools/dng-spike` (the CLI) ·
**Raised:** 2026-09-05 (Steven) · **SPIKE DONE 2026-09-05** · next step
**medium** (fold into the app), large only if third-party raws on iOS matter

Long-term: convert third-party camera raws (ARW, CR2, …) and LetsLapse's own
captured DNGs to smaller DNGs — lossy JPEG XL and resize to N megapixels, the
way Adobe DNG Converter does — inside LetsLapse on iPhone, iPad and Mac, fast
enough that storage stops being the bottleneck on long shoots.

**What the spike found (2026-09-05, M4 Max + iPhone 16 Pro probe):** there is
no JPEG XL *encoder* in any Apple framework — not ImageIO, not VideoToolbox,
not on iOS 26.6 on an A18 Pro — so libjxl (BSD-3) is the encoder. With it,
the chosen direction (report §6.1) is **camera-native LinearRaw JPEG XL**:
Kit parse (or LibRaw) → Metal demosaic → Lanczos → gamma table / cubic →
libjxl d0.5–1.0 e5 in 512-px tiles → the new `DNGArchive` writer.
1.28 MB per 8 MP frame at d0.5 (49 dB against lossless, 0.4% from Apple's
render of the source, Adobe re-decodes within 0.3%), 0.46 s per frame and
6 fps with three in flight on the Mac (486 frames in 81 s) — Adobe's size
at Adobe's quality, reading correctly in Apple's decoder *directly*.
Lossless JPEG XL on the Bayer plane is a free 9% over the Kit's lossless
JPEG (15.6 vs 17.1 MB, 90 ms). Lossy on the mosaic drifts at night. The
8-bit JPEG route (no third-party code) is the proxy tier, not the archive.
Apple's decoder rules that decide the container shape are in the report's
§4 (per-sample levels on LinearRaw; table vs polynomial depends on the
codec; no whole-frame tiles; one crashing tile layout).

**Folded into the app (2026-09-05 evening):** the pipeline moved into the
Kit (`Kit/Sources/LetsLapseKit/Archive/`, `DNGArchive.Converter` /
`Strategy`, tests in `DNGArchiveConverterTests`), libjxl + LibRaw travel as
one static `CLetsLapseCodecs.xcframework` binary target (`Kit/Binaries/`,
19 MB, one module map for both — Xcode cannot take two static xcframeworks
each with a root module map), and an interval project's ⋯ menu gained
**Duplicate as DNG archive…** (`App/ProjectDNGArchive.swift` sheet — size
Keep/12/10/8/6 MP, quality standard d0.5 / compact d1.0 / lossless /
lossless mosaic — and `AppModel.duplicateAsDNGArchive`, which clones the
manifest, sidecars, notes, masks, fonts and overlays, converts the frames
two in flight, writes a `dng-archive.json` ledger and registers the new
project). `LL_DNGARCHIVE=<id>|latest` (+`_MP`, `_DISTANCE`, `_LIMIT`,
`_INFLIGHT`) runs it headless and prints per-frame timings. **iPhone 16 Pro
measured:** 0.50 s per 8 MP frame (libjxl 280 ms), 1.9–2.1 frames/s, 12 MP
at 1.6 frames/s — seven times faster than the 3.6 s shoot cadence. **iPad
Air M3:** 0.4 s per 8 MP frame (libjxl 185 ms), 2.5–3.2 frames/s on its own
night DNGs. **Mac clone of `E854D311` (483 ARWs → 10 MP standard):** 483
frames, 8.8 GB → 707 MB, registered as "Vltava_ARW · DNG hook", 2.8–7.5%
from Apple's ARW render (the Sony-profile gap), Apple opens every frame
directly. **Mac clone of `F6387DFA` (207 blended DNGs → 8 MP standard):**
3.6 GB → 287 MB as "nature · DNG hook", 0.4–0.7% from Apple's render of
the source, blocks within 8% (the demosaic difference at 8 MP). Design
SVGs for the sheet and the menu row are OWED after the Mac sign-off
(app-code-first by Steven's instruction).

**Validated against Adobe (2026-09-05 late, report §8):** the first in-app
clone of an iPhone 16 Pro project (105 frames in the unregistered folder
`5968F261-…`) was refused by Lightroom — the writer carried the single-IFD
Apple original's CFA and 4224-wide crop tags into a 4032-wide LinearRaw.
Fixed and fenced: raw-owned tags filtered, ActiveArea crop, 2-component
tiles, the OpcodeList3 GainMap baked (Metal) or carried, and
`DNGArchive.validate` on every write (`dngspike validate --adobe` for the
Adobe verdict). Measured with Adobe DNG Converter as the yardstick, in
camera space: the lossless mosaic is bit-exact, the demosaiced archive
within 1% of Adobe's own linear conversion, and the lossy carrier moved
from a gamma table over a 2048 pedestal (−4.6 counts of bias in the noise
below black) to a slope-matched toe table over a 12288 pedestal
(`Curve.toeLUT`, +0.0), now at or better than Adobe's own lossy JPEG XL.

**Still open:** Steven's own Mac / iPad pass over the sheet and the SVG
mirrors; Lightroom itself (Adobe DNG Converter accepts every shape now, the
application was not driven); the in-app viewer renders a lossy archive of a
*noisy night* frame ~8% differently from its uncompressed twin through
Apple's raw pipeline (noise texture; Adobe's decode does not) — decoding
our own JPEG XL for the viewer would remove that; deleting the orphan
`5968F261-…` folder (~300 MB of invalid frames, not in the library);
Float16/UInt16 intermediates for the iPhone memory budget (Float32 today);
the BaselineExposure source for third-party raws
(`DNGArchive.Strategy.knownBaselineExposures` holds the ILCE-7M4's 0.35 for
now); a "Delete originals" companion once an archive has been checked; the
iPhone 12 Pro / iPad Air 5 probes (`LL_DNGPROBE=1`); a flicker report over a
converted sequence.

### Settings ▸ Display: blackout, reduce brightness, and the scheduled peek

**Detail:** `docs/design/iOS/settings.display.portrait.svg`,
`capture-interval.running.blackout.portrait.svg`,
`capture-interval.running.peek.portrait.svg` ·
**Raised:** 2026-09-05 (Steven) · **SHIPPED 2026-09-05 (design first, then code, signed off between) — device sign-off owed** · medium

Design-first pass, signed off on the SVGs before any Swift. The problem
Steven put: a blacked-out shoot gives no sign it is going well, and the only
way to look is to touch a phone that is on a tripod — which is how a run gets
knocked out of frame.

**Settings.** "Dim screen during shoot" leaves ADVANCED for a new top-level
**DISPLAY** section between RECORDING and LOCATION, renamed **Blackout
viewfinder** — the row floors `UIScreen.brightness` *and* covers the
viewfinder, so "dim" was never what it did. Two levers, split because they are
opposite on the two panel types: on the OLED iPhones almost all the saving is
the **cover** (black pixels are off, so the slider is nearly free once the
panel is covered), and on the LCD iPads it is the **brightness**, because the
backlight burns whatever is drawn. New **Reduce brightness** (OFF) is that
second lever, and it is also the level a lifted curtain returns *to* — which
is why the two are independent rows rather than one three-way picker. Then
**Scheduled peek** (ON) / **Trigger** (Interval | Clock, default Clock, a
Clock peek inside the first 60 s of a run suppressed) / **Every** (5m default,
10m, 15m), shown only while the blackout is on.

**The peek shows a status card, not the viewfinder.** A restored preview
answers "is it going well?" badly at three metres, and costs the OLED exactly
what the blackout was turned on to save. The card is legible across a room and
~94 % black: latest frame + its age, frame count as hero, a cadence verdict
(On schedule / Falling behind), ELAPSED · THERMAL · SPACE chips, `runExposureLine`
verbatim, the short blend readout, and a footer saying when the screen goes
back and when the next peek is — a screen that blacks itself unannounced reads
as a crash. No controls on it: a tap anywhere is the existing
`ShootScreenDimmer.wake` (30 s of real screen), which is the only route to stop.

**Two fixes to the blackout itself, in the same unit of work.** (1) The
brightness floor comes off absolute zero to **0.05** — `UIScreen.brightness`
caps every pixel on the panel, so at 0 the alive-signal cannot be seen, and on
OLED the difference between 0.05 and 0 with a black cover up is noise.
(2) The heartbeat becomes a 6pt `LL.amber` dot resting at 0.12 and **pulsing
per captured frame**, replacing the 5pt red-at-30 % dot that is invisible in
the field. It says more than the system indicator can: green means the camera
is powered, a pulse means LetsLapse took a picture.

**Steven's green-light question, answered and recorded in the blackout
mirror's `desc`:** the app cannot brighten the system camera indicator.
`UIScreen.brightness` is a panel-wide hardware write with no per-element
exemption, so at the floor the dot is dimmed, not off. It reads clearly on
Dynamic Island phones (the dot sits on the island's black surround at maximum
contrast) and poorly on the 12 Pro's notch — the difference he saw between the
two devices. `CaptureView`'s `.statusBarHidden()` is not the cause: it applies
whether or not the blackout is engaged, and the dot is visible undimmed. The
app's answer is the heartbeat, not the system's dot. **Worth one dark-room
confirmation on both phones before the code lands.**

*Shipped: `ShootPeekSchedule` in the Kit (`interval` / `clock`, the 60 s
opening grace, 14 tests — 578 Kit tests green); `ShootDisplayPlan` +
`ShootPeekCard` beside a rewritten `ShootScreenDimmer` (one `apply(_:)` entry
point rather than four setters that can disagree; `runBeganAt` because
`captureRunStartedAt` is written on the session queue and is not published, so
the first plan of a run can arrive with it nil); `displayCard` +
`peekTriggerRow` in Settings; `CameraController.latestFrame`, published from
the stills write path and mirrored off the blend snapshot's new
`lastOutputURL`; `DurationFormatter.compactAge`; `LL_PEEK=card`. Four defaults
keys are new and `ShootScreenDimmer.defaultsKey` is NOT — nor are
`setDimDuringShoot`, the `dimDuringShoot` state-frame key or `shoot.py --dim`,
so no bench script breaks; only the Watch row's label moved (Dim Screen →
Blackout). Verified on the iPhone 16 simulator (393 pt) and both mirrors
re-measured against it.*

**Three SwiftUI traps the mirror only caught once the app drew it**, all worth
remembering: a settings `Toggle` needs `.labelsHidden()` or it claims half the
row and squeezes the subtitle column to ~117 pt against its neighbours' 207 pt
(every other row in `SettingsView` has it); every settings toggle here carries
`.tint(.green)`; and a SwiftUI `Menu` label renders in `LL.accent` whatever
`menuValueLabel` asks for, which also makes `settings.advanced.portrait.svg`
stale for its two field-test values (noted in the INDEX, not fixed).

**Owed:** device sign-off, and specifically the dark-room check of the green
indicator on both phones — the reasoning above is sound but unverified. Then
the peek's alert form (🟡 in the iOS INDEX), the collapsed Display card (🟡),
and three mirrors this pass found stale and deliberately did not fix:
`settings.portrait.svg` (missing the ON-DEVICE AI section entirely, and it now
needs DISPLAY too) and both watchOS controls mirrors (the Dim toggle has never
been drawn, and now carries the renamed label).

### Lossy DNG stage 2 — a camera-space decode that renders like Lightroom

**Raised:** 2026-09-05 (Steven — archival Sony ARW → Adobe DNG Converter
lossy JPEG XL at 10 MP, projects `E854D311` ARW / `93F772E0` lossless DNG /
`8E67730E` lossy full / `B91FD599` lossy 10 MP) · open · **medium**

Stage 1 shipped the same day: `LossyLinearDNG` (Kit, `Grading/`) repacks an
Adobe lossy DNG in memory — ImageIO decodes the JPEG XL tiles, the Kit runs
the DNG stage-2 arithmetic (per-plane black, white, `MapPolynomial`) itself
keeping sub-black noise negative, re-quantises onto a uniform 2048 pedestal
and hands an uncompressed LinearRaw DNG to `CIRAWFilter(imageData:)`. That
routes around Apple's decoder, which mishandles `BlackLevel` whenever
`MapPolynomial` opcodes are present (green wash; measured identical on macOS
15.6, iOS 18.6 and iOS 26.1 simulators). Every raw decode — editor, blend,
thumbnails, framing measurement, `lapse` — opens its converter through
`LossyLinearDNG.rawFilter(for:)`. `LossyLinearDNGTests` holds the lossy
containers to the ARW gold standard within a few points of what the lossless
DNG achieves.

Stage 1 renders a lossy frame the way Apple renders the lossless conversion
of it, which is what the app shows for every other DNG. It does not render
the way *Lightroom* does: Apple's profile handling, not Adobe's, and the
embedded Adobe Standard hue/sat map and look table go unused. The files are
already demosaiced and carry ForwardMatrix1/2, so a genuine camera-space
decode needs no demosaicer: tiles → stage 2 (as stage 1 does) → AsShotNeutral
white balance → ForwardMatrix (`ForwardMatrixDecoder` already interpolates
by illuminant) → XYZ D50 → linear P3, with the embedded profile tables
applied through `DCPProfileApplier.Tables.lookAndHueSat` — the "genuine
camera-space decode" the DCP path was scaffolded for. Also on iOS, where no
Adobe profile directory exists, because the tables are in the file.

Open questions for that job: where dng_sdk clips the noise floor (stage 1
keeps negatives through to Apple's matrix, which matches the ARW; Lightroom
may clip earlier), whether the legacy 8-bit lossy JPEG flavour (compression
34892) decodes right through stage 1 — it is accepted but only JPEG XL was
verified — and a Settings-level way to see which decode a frame took.
Related memory: `adobe-lossy-dng-apple-decoder-bug`.

### Ramp readout runaway on a non-driving ramp — measurement, readout honesty, Ladder EV, logging

**Detail:** [fieldtests/2026-09-04-ladder-readout-runaway.md](fieldtests/2026-09-04-ladder-readout-runaway.md) ·
**Raised:** 2026-09-05 (Steven — 12 Pro Ladder dusk shoot 2026-09-04, project
`8BC64DBE`) · open · **high** (a false alarm stopped a good shoot; the Ladder
re-paced the clip on a phantom EV)

The ramp never drove the 12 Pro's virtual camera (`ramp commanded nothing`
at window 0, refusal reason console-only), the run shot on AE — and the
engine then chased itself: the JPEG path measures
`EV(commanded pair) + log2(luma/0.18)`, which is scene-referred only while
the camera obeys, so every phantom step was read back as the scene moving.
Target 1/305 → 1/71429 s, "scene EV" 11.6 → 19.6, while the frames went
1/296 → 1/121 and EV 11.2 → 8.8. The amber line printed the target, the red
"past the sensor's limit" fired on it, and the Ladder stepped Fading →
Daylight at 17:37:53 (pacing 2 s × 5 → 3 s × 10, in the finished clip). All
three Ladder runs that evening ran on AE; the second project (`0F387359`)
walked the other way (1/45 → 1/26 while AE went 1/121 → 1/50) and opened on
Dusk then stepped to Fading at window 1 from two disagreeing EV scales. Dim
only hid it. Side finding:
`sceneExposureValue()` adds `log2(ISO/100)` where EV100 subtracts it (3.2
stops low at ISO 33, 10 stops high at ISO 3200) — the Ladder's arming EV and
the idle light panel read it, and the Scanner torch threshold is tuned to it.

*Shipped 2026-09-05 (uncommitted, Kit tests green, iOS build green):*
**(1)** the luma measurement reads through the DELIVERED pair — each
video-tap frame's own EXIF off the sample buffer (`BlendWindowScene`), never
the engine's target — with five regression tests including the runaway
itself; **(2)** `HolyGrailState.isDriving` + delivered pair + reason: the
amber line prints `1/121 · ISO 71 · EV 8.8 · ramp not driving`, never red,
the reason behind the Info toggle; mirror
`capture-interval.holygrail-running.refused.portrait.svg`,
`LL_HOLYGRAIL=refused`; **(3)** the Ladder resolves on the AE's scene EV and
`sceneExposureValue()`'s sign is fixed (the torch threshold was written on
the right scale — no re-tune); **(4)** `capture_log.json` gains per-window
`ramp` records, `divergenceReference`, `rampDriving`/`rampRefusals`,
refusal/recovery/rung-change issues on both pipelines (device facts on the
refusal line), `frames.timestamps` carries the delivered pair, the
experiment log keeps its `liveblend-` name, and `Logs/console-<launch>.log`
keeps every `LLog` line; `tools/ramp_audit.py` reads it all.

Owed: **(5)** the 12 Pro run — the refusal reason now lands in `issues[]`
with the device facts, so one Ladder run and `ramp_audit.py` on its project
answers what the 2026-08-27 hypothesis could not; the simulator check of the
amber line's fit; Steven's sign-off of the mirror; and the product call on
whether a run whose ramp is refused should say so in a toast at arm time
rather than only on the readout.

### Encode quality — ProRes master, constant-quality mode, and the encode-path secondaries

**Raised:** 2026-09-04 (Steven — Lightroom → Resolve vs LetsLapse comparison on
`E33ED216` / `76BEF654`) · open · medium · policy:
`Kit/Sources/LetsLapseKit/VideoEncodePolicy.swift` · tests:
`VideoEncodePolicyTests`

*Shipped 2026-09-04: the bitrate budget is per pixel per FRAME again — the
`min(fps, 30)` in the rate term had halved what every 50/60 fps frame got
(4032×3024 @ 60 measured 0.12 / 0.09 bits per pixel; an encoder-only test on a
clean reference kept 36 % (H.264 88 Mbps) / 21 % (HEVC 10-bit 66 Mbps) of the
finest-band detail, 56 % at 250 Mbps, 100 % for ProRes). Ceilings are now
200 / 160 Mbps.*

Still open, in order:

1. **ProRes 422 HQ master output for blends.** `OutputCodec.prores` exists in
   the Kit and the CLI (`VideoBlender.swift`), but the app offers only
   H.264 / 10-bit HEVC. A grade-elsewhere workflow (Resolve) wants a master;
   48 MP sources cannot be H.264 or HEVC at all (Level 6.2 caps at 8192×4320).
   `.mov` file type, `blends/<uuid>.mp4` naming, thumbnails and share paths
   all assume MP4 today.
2. **Constant-quality encode mode.** `kVTCompressionPropertyKey_Quality` is
   honoured only by some encoders and an unsupported key raises at
   `AVAssetWriterInput.init` — probe with `VTCopySupportedPropertyDictionary`
   first, then expose Standard / High / Maximum.
3. **Secondaries found in the audit:** `VideoBlender.swift` (~:338-343, :476)
   and `TimeSliceRenderer.swift` (~:281-286, :395) feed a `32BGRA` pool into
   a Main10 writer and tag 709 primaries on a P3 stream (8-bit pixels inside
   the "10-bit" path); `MacVideoJobRunner.swift` (~:696) hardcodes
   `.h264High8Bit` and ignores the user's HEVC choice; `CollectionExporter.swift`
   (~:91) still uses `AVAssetExportPresetHighestQuality`, which chooses its
   own bitrate, writes no colour tags and can bin frames.

### Graded still export — full-chroma JPEG or a lossless format choice

**Raised:** 2026-09-04 (Steven) · open · small–medium · writer:
`PhotoGrader.renderJPEG` (`App/PhotoPreset.swift`), `LinearFrameDecoder.cgImage`

A graded copy of a Lightroom JPEG (4:4:4, q≈95, 5.9 MB) leaves the app as
4:2:0 at quality 0.95 (5.1 MB): luma detail is fully kept, chroma resolution
halves (spectral power at 0.5–1.0 Nyquist keeps 13–26 %). ImageIO writes
4:4:4 only at quality 1.0, which is ~2.5× the size (11.6 MB) — Steven ruled
that out. Shipped 2026-09-04: the copy is tagged in the source's space (sRGB
for a display-referred source, Display P3 for raw). Owed: a 4:4:4 writer at
Lightroom's size (a non-ImageIO JPEG encoder), or an Export… format choice
(JPEG max / 16-bit PNG / TIFF) with its design SVGs.

### DNG neutral look — re-fit against Apple's render across the clip, and raw capture sharpening

**Raised:** 2026-09-04 (Steven — the Lightroom comparison) · open · medium ·
engine: `ToneMath.baseCurvePoints`, `LinearFrameDecoder` (`boostAmount 0`,
`extendedDynamicRangeAmount 2`)

The hidden base look was quantile-mapped from ONE calibration frame onto
ImageIO's default render of that DNG. Across `E33ED216` the untouched render
sits flat next to Lightroom's defaults: for frame 2401, ImageIO's own render
reads p50 181 / p95 229 against the app's 165 / 196 (that export carries
Steven's grade, so the gap is an upper bound). Two candidate moves, both
changing every existing DNG project's look: re-fit the curve across frames
(or promote the look to a visible preset and make neutral honest), and add a
Lightroom-style default capture sharpening for raw (amount 40 / radius 1 /
masking 25 has no counterpart — `sharpen` defaults to 0, and Apple's boost,
which carries its own sharpening, is off). Give the `lapse grade` rig a
stored expectation first so the re-fit is measurable.

### Framing lock — resample quality of the per-frame lock

**Raised:** 2026-09-04 (Steven; measured on `E33ED216`) · open · small ·
engine: `FrameRotation.levelled` · doc: [framing-lock.md](framing-lock.md)
("sub-pixel resample vs integer copy")

`levelled`'s bypass keys on `rotating || shifting || insetting`, and the
inset is a whole-shoot constant — so with a lock committed EVERY frame,
the reference frame included, takes a bilinear sub-pixel translate followed
by a ~0.7 % `CILanczosScaleTransform` upscale: a full-frame low-pass with no
magnification benefit. Measured drift inside one 8-still window is 1.2 px
(frames 2401 → 2408), so an unlocked blend smears by about a pixel anyway;
the question is how to lock without softening. Options: integer-pixel blit
(≤ 0.5 px residual, no resample, size unchanged) or one Lanczos pass that
translates and crops without scaling back (output at the cropped size,
~4004×2994 for a 0.7 % crop — needs design sign-off). Steven 2026-09-04:
follow-up, not part of the output-quality fix. A/B today: Adjust › Advanced ›
Apply stabilisation.

### Display-referred neutral — the accepted behaviour change

**Raised:** 2026-09-04 · **shipped 2026-09-04** (engine version 6) · note only

Every JPEG/HEIF/PNG project — imported and captured (Mac interval is always
JPEG, iOS JPEG mode) — now renders "Original" as its own pixels on every
surface; before, the engine's DNG base look lifted them (median gray 198 →
228 on a Lightroom export, blue clipped). Grades and presets saved on such
projects were authored against the lifted look and now sit on identity —
darker and flatter than the day they were made. Not migrated: there is no
correct slider translation of "lift by the base curve", and the old look was
a bug on these sources. DNG projects are pixel-identical (guarded by
`GradeEngineTests` and `DisplayReferredNeutralTests`).

### Framing lock — post-capture stabilisation of interval shoots

**Raised:** 2026-09-03 · **Engine, design files and app wiring shipped
2026-09-03 (uncommitted) — Steven testing on the Mac; screenshot
verification against the SVGs, the viewer/preview/motion-player lock and
an iOS timing check owed** · medium · design + engine notes:
[framing-lock.md](framing-lock.md) · tools: `lapse framing`, `lapse stack
--lock`, `tools/framing_lock_report.py`

*Decided by Steven 2026-09-03: engine first → design → UI; lock everything.
Product shape agreed: on the interval project detail's Originals card, a
**Review photos** row (progress, then a report of the knocks and the plan —
human copy and the numbers in one `source/framing.json`) and a **Stabilise
photos** row, disabled until a review exists, that commits the plan as
metadata — never a pixel on disk; in Adjust › Advanced an **Apply
stabilisation** switch, ON by default once stabilised, OFF and disabled
before. The Kit engine, the `lapse` commands and 14 tests are in; the E33
plan is committed and `lapse stack --lock` renders its 803–810 window crisp.
Owed: the SVGs, the app wiring in every stills consumer, the sidecar in the
export/import/transfer lists, an iOS timing check — itemised in the doc.*

A tripod on a bridge moves when a tram crosses. `E33ED216` (16 Pro
telephoto, DNG, 5030 frames, sunset → night) has **25** bounce events of
2–10 px — pure vertical translation, no rotation, no scale, zero issues in
the capture log, never thermal-critical — and at speed 8 every one of them
ghosts the edges inside its 8-still window and wobbles the framing between
windows. Locking the whole shoot to one reference framing costs a **0.76 %**
crop (4001×3001 of 4032×3024). Unlike the 12 Pro OIS park below, nothing at
capture can prevent this; it is post-capture by nature.

The job: a measurement pass (Vision translational registration or the Kit's
own `FrameAlignmentGate` correlation at stride 1–2, anchors chained every
~30 frames, reduced-scale raw decode) into a `frames.alignment` sidecar;
then a per-source-frame translate + fixed inset + scale-back applied through
the one decode closure of each stills path (`PhotoPreset.blendSupport`'s
`decode`, `stackSequence`'s `loadFrame`, and the poster fast path's texture
provider — same `BlendWindowRenderer`, so posters stay identical), composed
with `FrameRotation` so a levelled and locked shoot resamples once. UI: a
*Lock framing* switch in the Adjust (photos) ··· drawer with a cost line,
and a real "Measuring framing…" processing phase. Decisions owed first:
lock-everything vs bounce-only, sub-pixel vs integer, the crop cap — all
laid out in the doc with the measurements behind them.

### Light Ladder — a fourth Interval MODE (Basic · Dynamic · Scanner · Ladder)

**Raised:** 2026-09-03 (Steven — Claude Design handoff "Light Ladder
interval profile", Turn 2) · **Built 2026-09-03** (Kit model + 21 tests,
store, engine hook, capture screen, list/editor/rung, test-card ramp; two
16 Pro runs — the pressure-floor fix from the first is unproven until a run
reaches serious) · **Mirrored 2026-09-03** (the seven SVGs + the Create row,
`LL_LADDERS=list|editor|rung`, rung title inline). Owed: the §9 card bench,
one real dusk, device sign-off of the mirrors. Plan, model, decisions and the
bench: `docs/light-ladder.md`.

A shoot follows a user-authored table of **rungs** keyed on scene EV; each
rung fixes ISO, shutter, WB, interval and blend depth. The servo stays in
charge — a rung is a box of constraints handed to the Holy Grail engine, so
exposure never steps; interval and blend step at the boundary. Built-in
"Bright & Fast, Dark & Slow" (13 · 8 · 4 · darker), cloneable, never edited
in place; `light_ladders.json` beside `custom_presets.json`. Twelve
decisions taken 2026-09-03 by recommendation (Night shutter auto ≤ 1 s not
pinned; governor may lengthen a rung's interval, never shorten; WB auto =
tracked; ribbon editor; iPhone + iPad first). "Mac hidden" was taken by
recommendation too and **reversed the same evening** (Steven: never
intentional) — the Mac has Ladder **stepped by hand**: availability is per
mode, the rung's spacing and blend apply, exposure stays the camera's own,
the operator steps the rung from a RUNG dial in the row — armed, and under
the run's readout — and ladders are authored on the Mac (D13, §6.7;
`macOS/capture-interval.ladder*.svg`).
Acceptance bench = the monitor test card's brightness ramp, designed before
the engine hook. The seven SVGs and the Create-row edit are mirrored (iOS
INDEX ✅, sim screenshots); the device pass that signs them off is not, nor
is a real-camera Mac run that steps mid-run, nor the macOS SVG's sign-off.

---

### Time-slice poster fast path — what is still owed

**Raised:** 2026-09-02 (Steven) · **Implemented 2026-09-02** (Kit, CLI,
app, Adjust cost line; Mac-verified against the 1,480-frame library —
`docs/time-slicing-poster-fast-path.md` carries the numbers). Left open:

- The §7 stage-6 iPhone run at depth 1 with DNGs, for the RAW-decode-per-
  band number and the thermal picture.
- Sign-off on the four §9 decisions taken by recommendation (cost line
  only; iOS chunks of 4; the `lapse poster` CLI kept; fast posters not
  bit-identical to tail-pass posters), and on the code-first mirror
  `docs/design/iOS/adjust.timeslice-poster.portrait.svg`.
- Video sources (§8) — a second job with its own plan.

---

### Time-slice variation batches: run one in the app

**Raised:** 2026-09-01, out of the variations + grid-mode build

The whole feature is built and the engine is proven — grid geometry and
four-variation batches render end to end through `lapse slice`, and 22 new Kit
tests cover the layout, the ladders, the poster mapping and the batch
generator — but the **app-side orchestration has never actually run a batch**.
The Mac used for the build had its screen locked, which puts a Window Server
shield over everything and blocks synthetic input, and the headless routes
(`LL_ADJUST_CREATE=1`, `LL_AUTO=process`) failed to start a blend *even with
slicing switched off entirely*, so the harness — not the change — is what
stopped it.

What to check, on the Mac, against a real interval or video shoot: arm
`LL_TIMESLICE="segs:24,lag:2,vars:4,mode:mixed,seed:305419896"` inside
`LL_ADJUST` (it nests there — `openCapture` clears the recipe, so the hook does
nothing on its own), press Create, and confirm that one run registers four
sliced `BlendProject`s beside one regular clip; that each carries its own
recipe and `variation` stamp; that the grid members' summaries record the
derived row count and cell size; that the master temp is removed only after the
last variation has read it; and that the progress bar crosses the slice band
once rather than four times. Detail: `docs/time-slicing.md` §10.7.

---

### Out-of-app imports: follow-ups from the first build

**Raised:** 2026-09-01, out of the "Import a video" / "Import photos to stack" build

Both Create rows now build real projects rather than staging a blend.
`LetsLapseKit/ImportedStills.swift` reads every frame's EXIF and rebuilds the
sidecars a captured interval shoot writes for itself — `frames.timestamps`,
`frames.exposure`, `capture_log.json` — so an imported shoot lands on its own
capture clock with its own exposure trail. Files keep their names, the shoot's
own date becomes `createdAt`, and the raw gate (`ImportedStills.isRaw`) now
covers every camera family rather than the two extensions the app used to
write itself. Verified end to end on macOS against a 306-frame Sony ARW shoot
(18m26s span, 3.624s median interval, sub-second timing) and a 137 MB MP4.

Still open:

- **iOS/iPadOS verification.** Everything above was checked on the Mac only.
  Three things genuinely differ there and none has been run: the widened raw
  gate matters *most* on iOS (ImageIO hands back the embedded preview for a
  raw file — see the 2026-08-26 DNG finding, and the purple-frame-0
  signature), the Files picker over `[.image, .rawImage, .folder]` is
  UIDocumentPicker rather than NSOpenPanel, and the Photos-library path's
  `PHAssetResource.originalFilename` lookup needs a real library. Hooks:
  `LL_IMPORT_STILLS=<path>[:<path>…]`, `LL_IMPORT_VIDEO=<path>`.
  *Partly answered 2026-09-07*: single-file imports of an ARW, a DNG and a JPG
  ran end to end on the iOS 18.6 simulator through `LL_IMPORT_STILLS` and each
  registered, rendered its hero and read its EXIF date correctly. The two
  gestures either side of that code — the UIDocumentPicker itself and the
  Photos-library path — are still unrun on iOS, and so is a MULTI-frame raw
  set, which is where the embedded-preview question actually bites.
- **Dropping photos on the Mac's Create screen is still refused.**
  `CreateView.handleDroppedURLs` takes a `.lapse` archive or a movie and
  answers anything else with *"Drop an MP4, MOV, or M4V video, or a LetsLapse
  project (.lapse)."* — so the one gesture a Mac makes obvious for a folder of
  frames is the one that doesn't work, while the row beside it imports them
  happily. `AppModel.expandStillSelection` already resolves files, folders or
  both, so the fix is to route a drop that resolves to stills into
  `importStills(from:)` and widen the refusal copy. Wants the drop overlay's
  own design mirror (macOS Create is otherwise undrawn).
- **Nothing surfaces the session log.** `capture_log.json` now travels with
  every imported shoot carrying the camera, the lens, the pixel size, the
  measured interval and per-frame ISO/shutter/aperture/EV — and the app reads
  exactly one field out of it (`captureFlat`). The same is true of shoots
  captured here. A "how this was shot" panel on the project screen would pay
  for itself twice over the moment it exists.
- **The review step, deliberately deferred** (Steven, 2026-09-01: straight
  through first). What it would add: name the project, confirm the inferred
  interval, and drop outliers *before* several gigabytes are copied. Today
  the answer to a stray frame is Bad Frames after the fact, which works
  (nomination is by `lastPathComponent`, so it is name-agnostic) but only
  after the copy.
- **Imported video is thin by comparison** — creation date, size, fps and
  codec, which is most of what an MP4 container carries. Not yet lifted: the
  QuickTime location atom (a captured video writes a `.gpx` sidecar), and any
  per-segment structure — an imported clip has no `sequence.json`, so it warps
  as one stretch. Both are only worth doing against a real source that has
  them.
- **`ImportedStills.Sequence.issues()` is written and never read.** Out-of-order
  capture times, long gaps and mixed frame sizes are recorded into the session
  log's issue trail, where the same field is already used for thermal and
  framing events. Nothing shows any of them yet.

### Text overlays: export baking for VIDEO-source blends and tail passes

**Detail:** [text-overlay-spike.md](text-overlay-spike.md) · **Raised:** 2026-08-31, out of the spike · **Narrowed:** 2026-08-31 — stills paths shipped (864c5f5)

Stills projects now bake overlays into blended clips, timelapses and long
exposures (`ImageStacker.overlayComposite` + `OverlayExportBake`), verified
end-to-end. Still open: video-source blends — the `VideoGrader`-family
composition handlers plus the `willBakeGrade` / `hasTailPass` /
`grade.isKeyframed` map gates that all assume grade-is-the-only-reason —
which only matters once `VideoEditorView` can author overlays at all; the
graded single-still export (`PhotoPreset.engineRender` full-res /
`renderJPEG`); and the Ken Burns collection export (layer-instruction path,
no CI handler).

### Text overlays: productization follow-ups from the spike

**Detail:** [text-overlay-spike.md](text-overlay-spike.md) · **Raised:** 2026-08-31 · **Narrowed:** 2026-08-31 — the Text Features build closed the multi-layer, typography, box/auto-size and custom-mask items

Closed by the "Text Features" design build: multiple layers with reorder /
visibility / onion skin, type fundamentals (family, B/I/U, alignment,
colour, kerning, line height, paragraph), Free vs Box with auto-size, the
Masks tab with project-level custom masks, and archive travel (`masks/` is
in `ProjectArchive.transferableSubfolders`; `overlays.json` was already in
`transferableFiles`).

Closed by the "Photo viewer text transitions" build (2026-09-03,
[text-reveals.md](text-reveals.md)): **font upload** (Import font… in the
picker, `fonts/` travels), **draggable range-band handles** (the lanes under
the strip), and the iOS layout pass in the simulator (stacked lanes, the
keyboard accessory bar, the typing layout).

Still owed, roughly in value order: **VideoEditorView overlay rendering**
(its Text tab is still an honest placeholder — and the reveals, exits and
sequencing above only bake through the stills path); **device pass** — the
reveal panel, the lanes' finger-sized trim handles and the accessory bar
were exercised in the iPhone 16 Pro simulator, not on a phone; promote
`overlays.json` into a `CaptureProject` field; detail-patch/loupe render
without overlays; SceneMasks **and the per-project `masks/` and `fonts/`
folders** on the storage card's clear-cache path; SegFormer-B0 ADE20K
conversion for true sky probabilities (DETR is 0/1 argmax).

Follow-ups from the reveals build itself: the **Blur** style renders each
unit through a Core Image pass (a 4000 px character-unit blur on a long
line is the slow case — measure on an export before shipping a blur-heavy
title); per-word styling needs iOS 18 / macOS 15 for the caret read-back
(`TextSelection`) — on the 17/14 floors the bar acts on the whole layer;
`LL_EDITOR` on macOS opens the editor window **two or three times** over the
same project (each hook route opens one), which the persist guard tolerates
but a screenshot run has to trim; and playback runs at the newest blended
clip's output length only once one exists (14 s tour before).

### Sky mask quality: guided-filter refinement, then a better model

**Detail:** [sky-segmentation-quality.md](sky-segmentation-quality.md) · **Raised:** 2026-08-31, out of Steven's Prague skyline · **Narrowed:** 2026-08-31 — the misleading dials are fixed

Fixed already: Threshold no longer pretends to work on an argmax grid, edge
bias is bipolar and defaults to 0, the locked-off case is the assumption
rather than a coin flip, and the vote samples 25 frames so the dial has 26
levels instead of 10.

Open, in value order:

1. ~~Guided-filter refinement~~ — **shipped 2026-09-01.** The mask boundary
   now sits 4.9 px from a real image edge instead of 12.6. `CIGuidedFilter`
   is a registered no-op; the shipped version is box blurs + two
   `CIColorKernel`s, and the CIContext needs a float working format or the
   signed coefficients clip to nothing.
2. **Keep continuous alpha.** The chain still thresholds to binary BEFORE
   the refinement sees it, then feathers afterwards — it discards the soft
   boundary and fakes one. Now the biggest remaining structural item:
   threshold last, or not at all.
3. **Revisit the threshold default.** Measured on two scenes, the optimum is
   near the BOTTOM of the range (0.05–0.15), and 0.5 visibly pulls the sky
   back off the skyline. Two scenes may now be enough to move it.
4. **A better model.** 2.46 of the 2.69 IoU points of error are the model,
   not the grid — so this is the biggest single term, and also the biggest
   job. Candidates: ADE20K scene parsers with a real `sky` class (DNL,
   ISANet, FastFCN, SegFormer-B0 at 512²; ready-made Core ML conversions
   exist in the john-rocky zoo) or a sky-specific matting network. Wants a
   bake-off against the hand-drawn reference before committing.


**Do NOT** spend effort on tiled or higher-resolution inference: the ceiling
test says a perfect mask on today's 448 grid scores 0.9977, so ≤0.23 points
are available there.

### Manual mask correction — "Add to Sky" / "Remove from Sky"

**Detail:** [sky-segmentation-quality.md](sky-segmentation-quality.md) · **Raised:** 2026-09-01, Steven's proposal after the guided-filter work

Let the photographer fix the mask by pointing at what is wrong, instead of
drawing a whole custom mask by hand. Sky is the nominated region; "Add to
Sky" grows it from where you click, "Remove from Sky" takes buildings,
ground and trees back out. The stopping rule is local: keep going while the
neighbourhood looks the same, stop at a contrast line, because a contrast
line is an object.

**Most of the engine already exists.** The guided filter shipped 2026-09-01
is an edge-aware propagator — it already takes a coarse region and snaps it
to the photograph's own edges. Pointing it at a user's scribble instead of
the model's output is a step, not a subsystem.

**Design notes, in rough order of how much they matter:**

1. **Corrections must be stored as INTENT, not as pixels.** A stroke list
   ("sky at 0.4,0.2", "not-sky along this path") re-applies against whatever
   mask the engine produces next; a baked mask dies on the next re-vote,
   grade change or model swap — and a model swap is on the roadmap. Getting
   this wrong means asking people to redo their corrections to get a better
   model. The tempting shortcut — seed a custom mask from the current Sky
   mask and let people edit that — works next week and severs the model link
   permanently. Don't.

2. **Click-to-correct before paint.** Every measured error sits within 50 px
   of the boundary, and the boundary is now snapped by the guided filter.
   What is left is the model being confidently wrong about a REGION — a dark
   roof read as sky, a bright cloud missed. That is one click, not a stroke.
   Keep a brush for what a flood cannot express (a thin railing, the gap
   between two spires), but the click is the primary gesture.

3. **Grow locally, not from the seed.** Compare each candidate pixel to its
   already-accepted neighbours, not to the original seed colour. A sunset sky
   is a gradient from gold to deep purple: a fixed tolerance from one seed
   either stops a third of the way up or leaks through a sunlit wall. Local
   comparison follows the gradient and still stops dead at an edge.

4. **Key on luminance, but pick the frame.** Luminance separates sky from
   land almost perfectly in daylight (0.4% distribution overlap) and
   collapses at night (37%) — see the findings doc. Because the camera is
   locked off, the correction only has to work on ONE frame and then serves
   the whole shoot, so the tool should run on a bright frame. The app can
   choose it: the 25 vote samples are already decoded, so scoring
   separability across them is nearly free. Saturation is the only signal
   that does not collapse and belongs in the mix as a tiebreak.

5. **Use the vote's confidence to triage.** The 26-level vote already knows
   where it is unsure, and the uncertainty sits exactly where the errors are.
   Surfacing "here are the four places I am not confident" turns an
   open-ended painting task into a short confirm/flip pass — a much better
   fit for something done once per project.

**Cost ladder:** local flood fill + guided snap, click only (small,
self-contained, most of the value) → stroke-based corrections stored as
intent (the schema work; the part worth doing properly) → confidence triage
UI (small once the above exists) → graph cut / GrabCut (genuinely better on
hard cases, no Apple builtin, a real port).

**Wrinkle:** drag on the preview is already taken by text placement, so this
needs an explicit mode. Fine on the Mac, more intrusive on iPhone.

### Design mirrors for the tabbed editor rail — the remainder after the editor redesign

**Raised:** 2026-08-31, out of the text-overlay spike · **Narrowed:**
2026-08-31 — macOS drawn (30b5836), then rebuilt for Text Features ·
**Narrowed again:** 2026-09-13 — the Editor tab redrawn on every platform
with the editor-controls redesign

The macOS Edit window's specs are current: `macOS/photo-viewer.svg` /
`.text.svg` / `.frames.svg` / `.masks.svg`, all four carrying the four-tab
rail, verified against the running app and ✅ in the macOS INDEX
(centre-snap guides, the More… popover, model-missing and mask-file-missing
states desc-only — draw them if they matter for sign-off). The iOS
`project-photo.viewer.*.svg` family was redrawn 2026-09-13 from the
redesign's boards and the running app (portrait, buttons, keyframes,
keyframes-empty, pads-off, color.wb, crop, presets, landscape and
keyframes.landscape; `expanded` retired), and iPadOS gained its first four
Editor-tab files (`project-photo.viewer.{landscape,keyframes,presets,crop}
.landscape.svg`). Still owed, one file each:

- **iPad portrait** — the DARK RAIL layout (settled 2026-09-13 over spec
  decision 9, which said the phone sheet; the iPadOS INDEX row is 🟡
  Planned). A bespoke portrait file once the rail layout is signed off on a
  device; until then the iOS side-rail files are the nearest drawing.
- **The Mac video editor** — no file exists; the macOS INDEX's keyframes
  row says the video editor reuses the same rail and panel with the VIDEO
  badge top-left of the pane and no Auto button / no Masks card
  (`mac-video-light.png`). Draw it as its own file rather than a note.
- **The iPhone Masks page** — the Masks tab and the Editor tab's Masks
  card on iOS have never been drawn (🟡 in the iOS INDEX); see *Masks as
  adjustment layers — iOS design pass* for the design decision that has to
  come first, and note the touch layouts' Masks card is a STOPGAP
  (`touchMasksCard`, below the picture while a grade is expanded and no
  group is open) that the boards do not show at all.
- The stacked layout's **Frames** page, never drawn on iOS.

### iOS tab host still folds tabs 5+ into UIKit's invisible "More" controller

**Raised:** 2026-08-30, while fixing the Collections phantom back button

The six-tab `TabView` makes UITabBarController fold Collections and Settings
into its legacy `UIMoreNavigationController` on iPhone — the system tab bar is
hidden, but the fold still happens. Its glass bar floated a phantom back
button over both tabs and pushed their content down a bar's height;
`hiddenMoreNavigationBar()` (`App/LetsLapseApp.swift`) now hides that bar and
disables its pop gesture with public API. The fold itself remains: folded
tabs live inside a navigation controller nobody asked for, one UIKit
behavior change away from a new artifact. The durable shape is the macOS
pattern — a ZStack + `switch selectedTab` (only the selected tab mounted,
paths already hoisted to ContentView) — at the cost of unhoisted per-tab
@State (Projects' filter/search text) resetting on tab switches, which is
what to weigh before doing it.

### Collections wide layout: bottom Add/Export row collides with the floating tab bar on iPad

**Raised:** 2026-08-30 (pre-existing; seen while verifying the up-the-fold rework)

`CollectionDetailView.wideLayout` pins "+ Add clips | Export collection" to
the bottom of the right column with 10pt of clearance. On iPad the floating
tab bar pill is wide enough to sit on top of the Add button (Export, further
right, stays clear). Needs tab-bar clearance like the portrait layout's
140pt spacer — or the row moved above the pill's band.

### Tall clips still own the whole portrait fold in the collection builder

**Raised:** 2026-08-30, out of the up-the-fold rework

A 9:16 clip in portrait fills the screen width by design ("never letterboxed
by default"), which at ~630pt tall pushes the caption row and timeline below
the fold — the one case the 2026-08-30 rework doesn't rescue. The "Apply
letterbox" pill already shrinks it to 240pt on demand. Decide whether tall
clips should default to the letterboxed preview (or a ~340pt cap) inside the
collection builder specifically; that reverses a deliberate v1 choice, so it
is Steven's call, not a drive-by.

### Render progress publishing storm — UI staggers during any render

**Detail:** [perf-audit-2026-08-29.md](perf-audit-2026-08-29.md) (finding A +
ranked fixes P1) · **Raised:** 2026-08-29

Every render publishes per-frame progress through `@Published` state on
`AppModel` itself, so each engine tick re-evaluates the whole mounted view
tree — plus an app-root `.onChange(of: model.progress)` and, on macOS, a
whole-log-file re-read per emit. Fix at the sink (5–10 Hz gate), move run
progress off `AppModel` onto a processing-only observable, ring-buffer the Mac
job log tail, and throttle the `ImageStacker`/`TimeSliceRenderer` emitters.

### Editor sliders unusable on big interval shoots — O(frames) body work + per-settle library persist

**Detail:** [editor-performance-plan.md](editor-performance-plan.md) ·
**Raised:** 2026-08-29 · **Stages 0–3 landed same day — Mac bench 4.8 →
58.4 ticks/s; on-device A/B on the iPhone 16 Pro (real 260-capture library,
1,250-frame shoot): 0.2 → 57.7 ticks/s, ~290×. The sibling audit's 10 Hz
progress gate landed with it after the 16 Pro recording of a blend start
freezing transitions for ~a minute. Same evening, the processing-flow pass
landed off that recording (plan doc header): hero-once-per-run,
`ProcessingProgressModel` (sibling P1.2), `source(for:)` existence tickets,
blend orchestration off the main actor + `.utility` workers — Mac A/B: main
thread during a live blend 100% busy → 6%; 16 Pro A/B (2026-08-30, real
1,249-frame shoot): main-thread share 15% → 3.4%, biased against the fix
(the before window missed the launch wedge). Fixed build installed on the
16 Pro. Owed: Steven's feel-check of the recorded flow + Cancel, iPad/12
Pro installs, stages 4–6, uncommitted.**

Grading sliders miss touch-downs and catch up seconds late on every device
(iPad M3 included — the mechanisms scale with shoot length and library size,
not silicon; photo-mode stills are unaffected). Six ranked mechanisms, the
top two measured: the editor rebuilds the full frame-URL list ~a dozen times
per slider tick on the main thread (10.9 ms/call at 1,480 frames, measured),
and every 100 ms debounce settle JSON-encodes the whole library on the main
actor, clears every project's size cache, and invalidates the entire mounted
view tree — which also fires a second hidden 1400 px render of the same grade
behind the cover and a per-frame `fileExists` storm in list bodies (the same
hot stack the sibling audit's 12 Pro trace caught). Plus: ~60 MB of Metal
scratch allocated per preview render (`restage()` unused by previews),
zombie renders holding the shared 4-wide media queue, RAW-decode-per-step
scrubbing, and the video editor swapping a fresh `AVVideoComposition` per
settle. Fix is staged Mac-first in the plan doc (seeded 1,480-frame bench +
AX-driven drags + Time Profiler gates); everything is shared code, so iOS
gets each win for free. Sibling: the render-progress storm entry above —
stage 6 coordinates both on the structural `@Observable` question.

### Standalone phone↔iPad transfer — make the pairing work without a Mac

**Detail:** [perf-audit-2026-08-29.md](perf-audit-2026-08-29.md) (findings
B–D, both measured runs, the on-device profile) · **Raised:** 2026-08-29
after a 5.1 GB iPhone 12 Pro → iPad pull ran hot, thermally stalled, and died
at 4.6 GB with `NWError 60`, discarding the staged tree. The Mac relay is a
bench workaround only — the iPad exists to remove the Mac dependency, so the
radio path itself is the product surface.

Measured basis: same phone/project did 12.6 MB/s over USB (thermal ≤2) vs
7.4→1.3 MB/s over Wi-Fi (thermal critical in 3 min), ack window pinned full
both times — the radio path is the bottleneck and the heater. The data
connection is already infrastructure-only; the AWDL duty is the *three*
side-radios (client browser scanning + both idle listeners advertising).

- **Phase A (started 2026-08-29):** negotiated-interface logging on both
  ends, client browse pause during pulls, both idle listeners withdraw their
  Bonjour advert while a transfer is in flight
  (`llProjectTransferPullState`), keep-awake on both roles, per-file progress
  emit throttled. Acceptance test: the same 5.09 GB pull, instrumented.
- **Phase B — resume (plan §4):** `have` set on `requestTransfer`, keep
  partials on failure, auto-reconnect; turns a dropped hour-long pull into a
  30-second reconnect. Friendlier failure copy than raw `NWError 60`.
- **Phase D — direct peer-to-peer (started 2026-08-29):** the field case was
  broken by one missing flag — discovery was P2P-capable but `PTLink`'s data
  connection never set `includePeerToPeer`, so two devices with no shared
  network would find each other and hang at pairing forever. Flag added; the
  `via …` log names the winning path (`awdl0` = direct). Field validation
  pending (cross-SSID bench test = a no-router simulation). Later: consider a
  "direct connection" affordance if the framework prefers a bad AP over a
  good AWDL path in practice. Same gap likely exists in the camera remote's
  `LocalNetworkTransport.connect` — audit separately.
- **Learned on the bench (2026-08-29 evening):** thermal was the *casualty*,
  not the cause — a cool-pack run at thermal 0 crawled at the same 1 MB/s.
  The home network is 2.4 GHz ch11/20 MHz ("blanickaback"), and an
  infra transfer crosses that channel twice; single-digit-Mbit reality. The
  fast run was USB (wiredEthernet), never Wi-Fi.
- **Phase C:** serving-side UI churn (sharing chip out of ProjectsView's
  observation, catalogue-walk TTL), screen-dim during transfers (design
  pass: thermal/interface/rate readout in both transfer UIs), and the
  `cleanUpOnDisappear`-never-stops-the-camera backstop.

Open questions for the next instrumented run: infra band/RSSI vs yesterday,
charging-heat contribution (both measured runs were cabled = charging), and
whether advert-quiet alone recovers most of the rate.

### Time slicing — the time gradient that scrolls across the frame

**Detail:** [time-slicing.md](time-slicing.md) · **Raised:** 2026-08-28 ·
**Stages 1–4 landed 2026-08-28 (engine, orchestration, verifier, Adjust UI),
plus the same-day first-output review round (plan §7a) — UI sign-off + SVG
mirrors, the stage-5 processing loader, then feathered edges (promoted) open**

*Review round: reading order flipped to earliest-first (default
`newestEdge` .right/.bottom, UI control "Time starts"); the primary temporal
control became **Spread as % of the clip** (seeded ~25%, amber under 5%,
frames stay the stored recipe via exact two-way `TimeSliceGeometry`
mapping); the "1/10-resolution animation" and "units bug" findings dissolved
on probing — the registered files are full 12 MP and the sampler shifted
exactly the commanded 30 frames (the reviewed .mov was a transcode; the
sub-frame lag was luma-measurement degeneracy, which also forced an
overlap-floor + first-difference fix into `timeslice_report.py`).*

*Stage 3 E2E on the real Mac library: one headless Create
(`LL_ADJUST=stills LL_TIMESLICE="segs:8,lag:3,…" LL_ADJUST_CREATE=1`)
registered three blends on the newest dawn shoot — regular clip (no recipe),
329-frame sliced animation (350 − the 21-frame spread, exact) and poster,
both recipe-carrying and recipe-named. `slicing` phase + progress band,
`openBlend` rehydration, Cancel bridged to the renderer. Mirror debt for the
sliced rows' project-detail copy rides stage 4's design pass.*

*Landed: `TimeSlice.swift` + `TimeSliceRenderer.swift` in the Kit (25 tests,
all numeric — bands measured against the commanded master frames), `lapse
slice` in the CLI, `tools/timeslice_report.py` (independent ladder
measurement — `TIMESLICE PASS` at exact commanded slope on rendered slices,
INCONCLUSIVE by design on flat scenes). Real-footage E2E: the 1,587-frame
12 MP "Blended 10 long" blend sliced in 72.6 s at 265 MB peak — flat memory
measured true against a ~1.1 GB cycling spool. One real trap re-found:
`FileHandle.read`'s autoreleased Data made the spool loop's memory track
bytes read 1:1 — the transfer pump's exact bug — fixed with a per-frame
autoreleasepool. No iOS anything touched, per the sequencing decision.*

Partition the output frame into N bands, each sampling a different point on
the source timeline (per-band frame lags), so a sunrise travels across the
frame during playback; the single-frame variant is the whole-day-in-one-photo
poster. Interval and Video shoots, inside `+ New blended clip`. The plan doc
answers the brief's seven open questions from the code and overrides the brief
twice, both load-bearing: the §4.7 "bands not frames = one frame of memory"
claim is wrong for the animation (true only for the poster — the honest floor
is ~half the spread, so the design is a banded ring-file spool on disk with
flat RAM), and stage 1.5 moves from a pre-encoder tap to the **last tail pass
over the finished blended clip** — the only point where every engine converges
on uniform, final-geometry, grade-baked frames (mixed-resolution ramp shoots
are per-segment sized at the tap; the Mac runner blends out of order). That
placement also makes the parked "re-slice an existing blended clip" path the
same code minus UI, and dissolves the burst-resolution-straddling question.
Sliced outputs register as ordinary `BlendProject`s (animation `.video`,
poster `.image`), so archive/transfer/storage/delete are inherited with zero
allowlist changes. Sequencing decided 2026-08-28: **build first, macOS first**
— engine stages verified through Kit tests, a new `lapse slice` subcommand and
the Mac app, no iOS simulators downloaded for this job; UI later, code-first.
Display names carry the recipe (`timeslice-vert-left-segs_24-lag_2`; width
auto-calculated). All seven brief questions answered 2026-08-28 (offsets in
frames · trim · full-source PNG poster · master resolution, no upscaling ·
frame-space ramps), and the Adjust preview became the **§6a processing
loader**: every blend run's Processing hero builds up band by band — a real
full-source time slice of the shoot at the output's aspect, bands jumping in
with progress — with the checklist card moved above Cancel and the cancel
caption removed. Still open (plan §9): whether the throwaway master forces
`hevcMain10` when "Include regular timelapse" is off.

### Import a project from another device (local network)

**Detail:** [project-transfer-plan.md](project-transfer-plan.md) ·
**Raised:** 2026-08-27 · **Phases 1–3 landed, all uncommitted** ·
*revised 2026-08-27 — payload strategy, resume, AirDrop/USB*

**Phase 3 landed 2026-08-28 — every direction now works.** `ProjectTransferServer`
widened to `#if !os(watchOS)`, so a Mac offers its library through the same
listener, the same chip in the same Projects header, and the same Settings ▸
Advanced opt-in. Device identity is `Host.current().localizedName` on macOS
(`UIDevice` on iOS) and the model string picks the picker's glyph.

**The one genuinely different piece is the stand-down.** iOS gets one free —
the app backgrounds and the listener stops — but a Mac scene never backgrounds,
so an armed Mac would advertise its whole library until the app quit. The rule
is `ProjectTransferServer.idleTimeout`: 15 minutes with nobody connected and it
stops itself, the clock reset by anything meaning a human is still present
(arming, a peer connecting, a transfer finishing). It applies on iOS too — a
good second rule there, just not the only one.

**Verified 2026-08-28, iPad Air M3 ← this Mac:** "Blended 10 long" — 5.91 GB,
1,588 source files plus its blended clip — installed into the iPad's library.
Peak serving footprint 223 MB, ack window bounded at 33 MB.

**Serving throughput on a Mac is bounded by wherever the library lives**, and
this was demonstrated the hard way: on the old USB drive (**692 KB/s raw**) the
pump managed 0.7 MB/s with its window sitting at 1–6 MB of 32 — starved by disk,
not throttled by protocol. On the SSD that replaced it the window runs full
(27–33 MB) and the bottleneck moves to the receiving device's Wi-Fi. Worth
knowing before anyone reads a slow Mac→iOS transfer as a network problem: check
the window depth first — low means disk, full means wire.

**Phase 2 landed 2026-08-28.** The import client is now every platform that has
a library, not just the Mac: `ProjectTransferClient` widened to
`#if !os(watchOS)`, and the whole flow moved into one shared
`App/ProjectTransferImportView.swift` that macOS hosts in its `Window` and iOS
and iPadOS present as a sheet. Create's **"Import a LetsLapse project…"** row is
now the single door on both platforms — it asks *From a file…* or *From another
device…*, which keeps `.lapse` import where it has always been and gives the
network path a home that isn't a menu bar. Also in: a free-space refusal checked
before a byte moves (and flagged on the project row itself, which matters far
more on a 128 GB phone than on a Mac), and `LL_TRANSFER` as an iOS launch hook.

**Verified 2026-08-28, iPad Air M3 ← iPhone 12 Pro over Wi-Fi:** "Long psycho
i12", 7.33 GB across 2,869 files, installed into the iPad's library with
`Incoming/` swept clean afterwards; the serving phone's footprint peaked at
78 MB and the ack window never exceeded 28 MB against its 32 MB bound.
Throughput ranged 14 MB/s down to 1 MB/s and back as Wi-Fi and the 12 Pro's
thermals varied — flat memory throughout, so that is the wire, not the engine.

**Mac→iOS is Phase 3 above, and now works.**

**What Phase 1 shipped**, verified end to end (a project moved simulator→Mac
and every file matched the manifest byte for byte, and again through the real
Import window): `AppModel.LibraryActivity` and all its registration sites ·
`Shared/ProjectTransferProtocol.swift` (typed 1+4-byte framing, control /
data / cancel) · `ProjectTransferServer` (iOS) · `ProjectTransferClient` +
`Remote/ImportWindow.swift` (macOS) · `"Incoming"` in `libraryItemNames` ·
`ProjectArchive.transferableSubfolders` · the `importProject` split into
`installStagedProject` · `tools/transfer_probe.swift` · the SVG mirrors.

**Two deliberate departures from this plan, both narrowing:** the service is
`_letslapse-xfer._tcp` and the salt `…transfer.v1` (the plan says
`_letslapse-library._tcp` / `…library.v1`); and **`requestTransfer` carries no
`have` set, so there is no resume** — a dropped pull discards its partial tree
rather than stranding gigabytes nobody can spend. Resume is §4 and needs the
vocabulary to grow the `have` list; `Incoming/` already has the right shape,
the right home and the 24-hour launch sweep for it.

**Device-verified 2026-08-27 on the iPhone 16 Pro over USB:** an 11 GB project
(612 files) moved byte-for-byte in 267 s at 41 MB/s with the app's peak
footprint at **90 MB**; a client killed at 25% aborts the server in 0.7 s and
leaves it serving normally; 293 projects list in ~0.4 s; the real Mac Import
window completed a phone→Mac import end to end. The device run found three
bugs a simulator structurally cannot (§3's semaphore recipe doesn't bound
anything, `FileHandle.read`'s autorelease made memory track bytes read 1:1, and
a cabled device's two-interface race broke newest-wins) — all fixed, all
written up in the plan doc's header.

**macOS Local Network permission, learned the hard way 2026-08-27.** It is
granted per COPY of the app, keyed on the binary rather than the bundle id, so
every build from a new location becomes a new grantee and the Settings list
fills with identical LetsLapse rows — all switched on, none of them the one
running. Two consequences now handled in code: `NWBrowser` never recovers from
`.failed`, so the Import window rebuilds it every 2 s and picks up a
newly-granted permission on its own (it used to need a close and reopen); and
the refusal screen names the running copy's path, offers Show in Finder, and
opens Settings via the `privacy-localnetwork` anchor. **`tccutil reset
LocalNetwork` does nothing** — Local Network is not a TCC service on macOS
(`kTCCServiceLocalNetwork` is absent from `tccd`), so there is no CLI reset and
stale rows can only be left to age out. Running one copy from one fixed
location is what stops them accumulating.

**Thumbnail coverage — fixed 2026-08-28.** Tiles no longer ride with the list.
Each row asks for its own as it appears (`requestThumbnail` → `PTThumbnailReply`)
and the serving device GENERATES one when its cache has none, persisting it
under the same key the local grids read — so it costs one decode ever, and the
local Gallery gets it for free. That is the §2 design, and it fixes the real
problem: the old eager path was capped not by its 3 MB budget but by coverage,
because `DiskThumbnailStore` only holds a tile for an asset some grid has
actually drawn. Measured on this Mac: **79 of 79 rows drawn**, 1.5 MB of tiles,
10.3 s on the first pass and instant on the second; visually confirmed on the
Mac's picker against a serving iPad, including three projects that had arrived
by transfer minutes earlier and had never been drawn locally.

**Still owed:** iPad→Mac (every Mac-side run so far has been from an iPhone).
Settings ▸ Incomplete Transfers is not built: with no resume there is nothing
to resume, and the sweep reclaims the disk. Resume itself (the `have` set) is
the remaining §4 work.

Move a ~1–20 GB project device-to-device over the local network with no
intermediate file on either side: iPhone/iPad serve behind a six-digit code,
Mac/iPhone/iPad pull. A new `_letslapse-library._tcp` listener, deliberately
separate from `CaptureRemoteListener` (different lifetime, different grant —
serving the whole library is not the same act as driving the shutter), and a
typed length-prefixed frame format carrying JSON control beside raw payload.

**The payload is files, not an archive.** lzfse over DNG/ProRes saves close to
nothing, so the compression pass buys a rounding error and costs heat on a
thermally marginal phone — while file-by-file makes the transfer **resumable**
with the filesystem as its own ledger (stage into `Incoming/<projectID>/`,
`.part` until complete, reconnect with the set you already hold). A sequential
Apple Archive stream has no "start at entry N", so an interruption at 90% throws
away 90%; that is the trade this reverses. Phase 0 measures the real compression
ratio on Steven's own footage to confirm it before committing.

**Prerequisite for everything else:** the app has no central busy flag — capture
lives in `CameraController`, blending in `AppModel.stage`, and both archive
exports in view-local `@State` — so a `LibraryActivity` registry lands first.
Two smaller traps already identified: `"Incoming"` must join
`StorageLocation.libraryItemNames` or a storage move strands a half-finished
12 GB transfer, and the `["source","blends","notes"]` install allowlist must
become one shared constant or untransferable bytes get sent and then deleted.

**AirDrop already works** via the share sheet and needs no work — with the
caveat that it materialises the whole `.lapse` to temp first (peak disk ≈ 2×,
though `exportProject` refuses cleanly when there is no room). **USB is free**:
listening on all interfaces means a cabled iPhone is found by the Mac's browser
with no protocol change — the only work is a picker label, and what interface
type a tethered device reports is a hardware check, not an assumption.

Phased iOS-serve → Mac-import (**done**), iOS import (**done**), Mac serve
(**done**). Both phases' UI was built app-first at Steven's direction and mirrored
in the same unit of work: `iOS/projects.sharing.portrait.svg`,
`iOS/settings.advanced.portrait.svg`, `iOS/create-home.import-source.portrait.svg`,
`iOS/library-import.browse|progress.portrait.svg` and the five
`macOS/library-import.*.svg` files.

### Holy Grail ramp actuation: bench verification on both pipelines

**Detail:** [holygrail-ramp-actuation.md](holygrail-ramp-actuation.md) ·
**Raised:** 2026-08-27 · **Code landed 2026-08-27 — verification owed**

*Shipped on `ios-app`: the JPEG live-blend path now arms the ramp AFTER
`lockConstituentSwitchingForRun()` rather than ~1.3 s before it;
`applyHolyGrailExposure()` returns a named outcome instead of three unlogged
early returns, with one bounded retry folded into the existing settle hold;
and both blend controllers now report a ramped run whose commanded exposure is
nil (`RAMP NOT DRIVING`, plus `kind: "ramp"` in the `issues[]` trail on the
JPEG side).* The bug: three consecutive Dynamic runs on the 16 Pro logged a
ramp and drove nothing — engine target and delivered frames finished 4.3 stops
apart with `EXPOSURE DIVERGENCE` appearing zero times, because a nil commanded
target skipped the guard that was supposed to catch exactly this. Owed before
this leaves the list: **(a)** a bench run on each pipeline (JPEG, then DNG
output enabled) against the pass conditions in the brief — in particular
frame 0's ISO/shutter within a quarter stop of frames 1–3, which is the
regression test for the original purple frame; **(b)** confirm or kill the
hypothesis that a virtual device with constituent switching unlocked is what
refuses `.custom` — the fix does not depend on it, but the next person's
mental model does; **(c)** the product call on whether a run whose ramp cannot
actuate should refuse to start rather than only saying so in the log.

### Dim-screen-during-shoot: mirrors, Watch verification, and the composed A/B

**Detail:** [fieldtests/2026-08-25-thermal-bench.md](fieldtests/2026-08-25-thermal-bench.md) ·
**Raised:** 2026-08-25 · **Implemented 2026-08-25 (code-first per Steven) — mirrors + follow-ups owed**

*Shipped on `ios-app`: Settings ▸ Advanced ▸ "Dim screen during shoot" (ON by
default), `ShootScreenDimmer` (brightness floor + black cover + tap-to-peek +
restore on stop/exit/background; one `ShootDimming` modifier because
CaptureView's body sits at the type-checker's budget), Watch toggle in the
recording controls page, wire command `setDimDuringShoot` (the one setter
accepted mid-run, by design), `dimDuringShoot` in the state frame, and
`--dim on|off` in shoot.py run+fleet. Bench-verified: the A/B where dim-ON
completed a 20-min psycho arm the matched dim-OFF control could not
(12 Pro, veto at T+18.2).* **2026-09-05: (a) is superseded for iOS** — the row has been
redesigned into a Settings ▸ Display section and renamed *Blackout
viewfinder*; see the Display job at the head of this list, which carries the
mirrors (including the blacked-out screen itself, drawn for the first time)
and the answer to Steven's green-indicator question. Owed before this leaves
the list: **(a)** SVG mirrors after sign-off — the watch controls page, which
now waits on that rename;
**(b)** Watch-side verification on the real wrist (toggle round-trip,
pending states); **(c)** repeat the A/B under the monitor test card's
constant light (today's evening pair carries an ambient confound the
result survived but shouldn't have to); **(d)** the composed test: Safe +
dim vs psycho + dim on the 12 Pro — Safe attacks the floor load, dim the
OS margin, and the field default should be whichever pair holds a 2-hour
run.

### The 12 Pro locks whenever LetsLapse dies hot — and Never doesn't matter

**Raised:** 2026-08-25 · **Not started**

Observed ≥6× today (5 thermal vetoes + one post-collection console-detach
kill after a *clean* arm): whenever the app dies on a hot device the phone
ends up locked, despite Auto-Lock → Never, and a locked device refuses
`devicectl` launches — an unattended rig that dies stays dead AND
unreachable. Steven's correlation: it never locks otherwise; once woken it
stays awake. Mechanism unpinned. Discriminating test queued: hand-launched
short shoot + normal exit (cool, then hot) vs devicectl-launched ditto —
separates "dev-tools launch" from "app death" from "hot at death". Whatever
the mechanism, the suspension-lifecycle job (below) should treat
"post-outage device may be LOCKED" as a first-class state in its recovery
design, and the field checklist gains: physical access is the only cure.

### `collect_arm` can hand back the previous run's capture log

**Raised:** 2026-08-25 · **Not started** · small

`shoot.py`'s `collect_arm` pulls the newest `capture_log.json` on the
device; an arm that died mid-run registers no project, so the pull silently
returns the *previous* run's log as if it were this one — bit twice today
(Phase A returned the morning field log; the dim-OFF control returned the
dim-ON arm's log, nearly inverting the A/B verdict). Fix: parse the pulled
log's `startedAt` and require it inside the arm's window; otherwise report
"no capture log from THIS run — the arm died; see the liveblend experiment
log" (which the same collection already pulls and which is the honest death
record).

### Holy Grail ramp servo limit-cycles against the ISP's exposure quantization

**Detail:** [fieldtests/2026-08-25-dawn-scheduled.md](fieldtests/2026-08-25-dawn-scheduled.md) §2 ·
**Raised:** 2026-08-25 · **Implemented 2026-08-25 evening — bench validation owed**

*Shipped in `HolyGrailRampEngine`: deadband (0.12 stop) + 3-window dwell +
10-window reversal refractory + 1-stop emergency bypass, on for every
Dynamic run, zero-parameters = bit-identical legacy (33 legacy tests
untouched, 4 new gate tests). Worst case at the coarsest latch region is a
~40 s sub-visible breathing instead of per-window flicker. Owed: the
test-card scripted-ramp run through the short-shutter region, gated by
`source_flicker_report.py`, then a real dawn arm and one DNG confirmation
arm.*

The 2026-08-25 iPad dawn run carries 13 oscillation events (up-down-up
exposure pumping, ~0.09–0.16 stops per flip): at short shutters the ISP only
latches coarse discrete exposure states (0.18–0.37 stops apart at the ISO 18 /
sub-200 µs end), the wanted exposure sits between two of them, and
`HolyGrailRampEngine.advance` has no deadband, no hysteresis and a one-window
measurement delay — so the servo flips between the two latched states every
window. Fix in the Kit: commit a move only past a deadband (~1/6 stop) that
has persisted K≈3 consecutive windows in one direction (dwell), hysteresis
sized above the local actuation quantization, an emergency bypass for >~1-stop
errors. Unit tests: synthetic quantized actuator under a slow ramp → monotone
steps, zero steady-state toggles; constant scene stays a no-op. Verify on the
monitor test card's scripted brightness ramp, then a real dawn arm. Gate
before/after with `tools/source_flicker_report.py`. Policy-only change — no
bracket construction or device-write path touched, so DNG capture is
structurally unaffected; run one DNG arm to confirm.

### Dynamic (holy grail) runs must end where AE would meter the ending scene

**Detail:** [fieldtests/2026-08-25-dawn-scheduled.md](fieldtests/2026-08-25-dawn-scheduled.md) §1 ·
**Raised:** 2026-08-25 · **Implemented 2026-08-25 evening — bench validation owed**

*Shipped: the anchor drifts toward the device AE's own absolute opinion
(`exposureTargetOffset`-derived `aeSceneEV`, bias-inclusive) at a hard cap
of 1/20 stop per window with a 0.25-stop deadband and its own EMA — an
outer loop an order of magnitude slower than the servo, so the 2026-08-15
runaway class is excluded by construction; the absolute reference also
cancels the luma meter's ×1.75 crush amplification. Engine: shared, so DNG
and JPEG paths both fix at once; without an AE reading the anchor holds as
before (3 new Kit tests; `holygrail: anchor drifting` LLog when the gap
exceeds half a stop). Owed: the test-card dark→bright scripted ramp ending
within ~1/3 stop of a fresh-AE control, then a real dawn.*

The frozen-anchor dark run: `anchorsToSeedExposure` locks the seed frame's
rendering for the whole run, so a 2 h 17 m sunrise ended 6.1 stops darker than
the same scene's fresh-anchor exposure (control shoot 1b), amplified 1.75× by
the whole-frame mean-luma meter's non-invariance (residual loop gain 0.43).
Two-part fix: (a) let the anchor drift slowly (~1/20 stop/window cap) toward
consistency with the device's live AE opinion (`exposureTargetOffset`), so the
run converges on AE's rendering without frame-visible steps — designed against
the 2026-08-15 positive-feedback runaway (drift gain far below unity, Kit
regression `testAConstantSceneNeverMovesTheRamp` plus a drift-converges test;
(b) make the meter clip-aware (trimmed/percentile luma) to cut the residual
gain. Needs the test-card bench (scriptable light curve) for closed-loop
validation before a dawn. Diagnostic that found it: `measuredEV − appliedEV`
flat at −2.81 all run. Related: the scene-referred-meter note in the JPEG WB
brief.

### A suspended shoot must die honestly or resume deliberately — never zombie

**Detail:** [fieldtests/2026-08-25-dawn-scheduled.md](fieldtests/2026-08-25-dawn-scheduled.md) §3 ·
**Raised:** 2026-08-25 · **Not started**

iPhone 12 Pro, unthrottled 3 s: thermal critical at +16 min, iOS forced the
cool-down lock at ~+32 min, the app suspended for ~103 minutes (proven by
`procMs` 285 s across a 108-min wall gap), and the run neither ended nor
resumed — window advancement is frame-driven and the watchdog clock pauses in
sleep. On wake the backlog close-storm fed `consecutiveProcessingFailures`,
which killed the run one second after it had just delivered a good frame, and
the resumed camera was silently back in plain AE (frame 635). Work: detect
the outage (interruption notifications + wall-vs-monotonic gap at wake) →
`issues[]` entry with the real reason and gap; backlog catch-up windows never
count toward the kill guard; on wake either re-assert the ramp's custom
exposure or end as `endReason: systemPressure`; author EXIF DateTimeOriginal
from `capturedAt` so late-written windows carry capture time (rides the JPEG
EXIF job). Mirror in both blend controllers. Plus prevention: thermal input
to the AIMD ceiling (step down at serious, floor at critical) and the planned
starvation repace, so unthrottled degrades instead of summiting into the OS
veto; scheduled unattended shoots should warn on (or default away from)
unthrottled on OIS-class phones.

### 12 Pro OIS park at thermal critical — mitigation decision

**Raised:** 2026-09-02 · **Steps 1+2 implemented 2026-09-02 — bench envelope pending** · report:
[2026-09-02-framing-shift-pattern.md](fieldtests/2026-09-02-framing-shift-pattern.md) ·
decision + implementation notes:
[2026-09-02-framing-shift-decision-analysis.md](fieldtests/2026-09-02-framing-shift-decision-analysis.md)

*Shipped on `ios-app` (uncommitted): the blend tap streams at twice what the
depth needs instead of the pinned rate, and drops to the depth's need when
the camera's `systemPressureState` reaches serious (Apple's prescribed
mitigation); iPhones end any run at device-wide thermal critical with
`endReason: tooHot` and the last two outputs + sidecar lines dropped, and
refuse to start there; per-window camera pressure in both logs. Verified on
the 12 Pro: stream 10 → 1 fps at depth 1 @ 2 s, `simulateTooHot` (DEBUG
remote command) ended a 23-window run at 21. Owed: the 2 h × 3 warm-ambient
envelope arms, the design mirror for the idle thermal chip (never drawn),
and a decision on the open-ended depths' serious-pressure rate (3 fps).*

`tools/framing_shift_report.py` (new) swept every project with JPEG sources
(28 projects, ~17 k frames): all six persistent framing steps in the corpus
are on the iPhone 12 Pro, all land in a window at thermal **critical** (0 over
2653 serious frames), and in the three post-gate runs the step sits in the
`serious → critical` transition window itself. Each is a pure 44–64 px
gravity-axis translation with identical lens f-number and dimensions either
side, so it is the lens-shift OIS actuator dropping to its gravity stop — no
API controls it. The brief's four software suspects (geometry change, implicit
EIS, constituent hand-off, GDC toggle) are each ruled out in the report.

Decision owed (Steven), then build — no post-capture reframing by design:
keep the phone out of critical (thermal → AIMD ceiling, warn on Dynamic/
unthrottled for OIS-class phones in scheduled shoots), surface the gate's
`framingChanged` on the capture screen + Field Notes, optionally pause at
critical on OIS-class devices (the lens re-centres when the servo returns),
and a bench repro on the test card: 12 Pro virtual-triple vs physical-wide
pinned, and a 16 Pro driven to critical (never reached in any logged run —
its sensor-shift immunity is plausible, not proven).

### Pin digital stabilization off on tap connections, and log it

**Raised:** 2026-08-25 · **Not started** · small

The 2026-08-25 investigation re-confirmed the interval/blend frames can never
be digitally stabilized today (only `movieOutput` ever gets a stabilization
mode; data-output connections default off) — but that guarantee is implicit.
Set `preferredVideoStabilizationMode = .off` explicitly on the liveBlend /
test-card / framing tap connections where supported and record it once in the
session log, so the next tripod-jump investigation (they recur: Praha
2026-08-23, dawn 2026-08-25 — both were OIS hardware sag at thermal critical,
which has no API off-switch) starts from a logged fact instead of a code read.

**Raised:** 2026-08-24 · **Implemented 2026-08-24 — device verification pending**

*Shipped on `ios-app`: the frame-alignment gate (`FrameAlignmentGate` in the
Kit, wired into `LiveBlendController`; rejects confidently-displaced frames
before they ghost a stacked window — the Praha 2026-08-23 OIS-sag events,
measured at ~63 px vertical at thermal critical), honest per-window
`rejectedByAlignment` stats plus a machine `issues[]` trail in
`capture_log.json` (thermal, framing glitches, constituent hand-offs, end
reason), run-scoped constituent-switch locking, the idle thermal warning chip,
and the full Field Notes flow (audio/issue/text notes per project in `notes/`,
both entry points, on-device speech review). Kit tests + sim E2E pass.*

Still owed before this leaves the list: **(a)** bench repro on the 12 Pro —
heat to critical with back-to-back runs, tripod on a static scene, expect gate
rejections logged and clean output; and a nominal-thermal control run with
**zero** false rejections (the gate must never thin a healthy shoot);
**(b)** a `.lapse` export→import round trip carrying `notes/` (the import
allowlist fix); **(c)** the spoken-memo → transcript-prompt path on a real
device (sim lacks on-device recognition); **(d)** SVG mirrors after UI
sign-off — capture-screen thermal chip, project-detail notes rows, the
field-note flow screens (no iPadOS/macOS project-detail SVGs exist at all —
pre-existing gap).

### Interval shoots get the video "New blended clip" screen

**Detail:** [interval-adjust-unification.md](interval-adjust-unification.md) ·
**Raised:** 2026-08-24 · **Phases 1–2 implemented 2026-08-24 — phases 3–4 open, phase-2 sign-off pending**

*Phase 2 (2026-08-24, code-first per Steven): interval shoots now get the
real warp timeline — per-stretch **blend depths** ("5:1" chips, custom to the
frame count) absorbing the old slider, the capture-clock axis (frame-count
fallback), the "One long exposure" mode row, the unified estimate card, and
wide layouts. `IntervalWarp` compiles the schedule in the Kit (trivial
timeline ≡ the old constant schedule, per-stretch clock retiming);
`stackSequence`/`stackSequenceLinear` take `customWindows`. Verified: Kit
tests, three platform builds, headless Mac E2E on the real library (303
photos → 101 frames @ depth 3, timed from capture, warp in the recipe), Mac
wide + iPhone narrow screenshots via the new `LL_ADJUST=stills` /
`LL_ADJUST_CREATE=1` hooks. Owed: Steven's sign-off on the built UI, then
the SVG mirrors (`adjust.photos.portrait.svg` marked stale in the iOS INDEX;
iPadOS/macOS have no adjust SVGs — pre-existing gap), and a device pass.*

*Shipped on `ios-app`: every interval-style run now writes `frames.timestamps`
(plain photo-timer runs in `CameraController`; blend runs in both blend
controllers, off for Holy Grail where the ramp owns the file); stills projects
get probed `sourceWidth/Height` and a sidecar-derived `sourceDurationSeconds`
at registration, import, and a one-shot launch catch-up; and the shared stills
axis exists as `FrameAxis` in the Kit (photo editor lifted onto it,
`StillsPreviewLoader` staged beside `WarpPreviewLoader` for phase 2).
Deliberately invisible: badge/header lines are kind-gated so the new fields
change no screen. Side effect by design: fresh plain-interval blends now lay
out on the real capture clock (`ImageStacker` already honoured a covering
sidecar) — even pacing maps to the constant layout, so only genuinely uneven
shoots read differently, which is the sidecar's whole point.*

Verified 2026-08-24: Kit tests (13 new `FrameAxis` cases) and iOS-sim, macOS
and device builds all pass; the stills probe ran against the real Mac library
— 47/48 stills projects gained oriented dimensions (the 48th has its frames
missing on disk, correctly left nil), and exactly the 32 sidecar-backed
projects gained durations with none invented and all 14 video projects
untouched. Still owed for phase 1: one live interval run confirming
`frames.timestamps` lands in a fresh project's `source/` — the phase-1 build
is **already installed on the iPhone 12 Pro**; the phone was locked at bench
time, so unlock it and run
`./remote_probe <code> "setIntervalMode:basic,setFramesPerBlend:1,setIntervalSeconds#1,wait@1,startRecording,poll@2x6,stopRecording"`
(and once more at `setFramesPerBlend:3` for the blend pipeline).

Then phases 3–4 — spatial unification (reframe/canvas on stills renders,
codec chooser on both stills paths; grade maps turned out already unified:
the stacker's grade hook was source-anchored all along), then retiring the
`.photos` branch once Scanner is diverted to its own configure surface. Each
UI phase starts with the design-sync question.

### Field notes ↔ engine issue trail tie-in

**Raised:** 2026-08-24 · **Not started** · small

`capture_log.json` now records machine-detected issues (`framingGlitch`,
`thermal`, …) and Field Notes lets the user log the same vocabulary by hand
("Jumped frame(s)"). Two natural joints, deliberately not built yet: a
finished run whose log carries alignment/thermal issues could pre-tick the
matching Log Issue labels on the New-blended-clip screen, and the project's
notes list could surface the engine's own issue trail alongside the
hand-written notes. Design question first: whether machine entries live in the
same list or a separate "what the engine saw" section.

### JPEG Holy Grail locks white balance, and writes no EXIF

**Detail:** [jpeg-holygrail-wb-brief.md](jpeg-holygrail-wb-brief.md) ·
**Raised:** 2026-08-23 · **Implemented 2026-08-23 — device verification pending**

*Jobs A (slew-limited WB tracking for JPEG runs; DNG untouched via an explicit
`rawPipeline` flag) and B (EXIF authored on blended JPEGs) are implemented on
`ios-app`. Still owed before this leaves the list: a dawn/dusk JPEG arm on
device (WB tracks, EXIF present, flicker gate passes) and a DNG arm diffed
unchanged against a pre-change run. Job C (scene-referred meter) remains
record-only.*

`applyHolyGrailExposure()` sets `whiteBalanceMode = .locked` on every ramp write
and nothing restores AWB until the run ends, so the 2026-08-23 `jpeg sunrise`
shoot rendered two hours of sunrise through sodium-vapour gains: red ends at
**14 of 255 code values** — quantised away, unrecoverable in 8-bit. Acceptable
for DNG (grading latitude, and the stability is wanted); a show-stopper for
JPEG. Separately, the JPEG blend output is written with a GPS dictionary and
nothing else, so it carries no `DateTimeOriginal`, `ExposureTime`, `ISO` or
`FNumber` — the DNG author writes a real EXIF IFD, JPEG never has.

**The trap:** `applyHolyGrailExposure()` is shared by both pipelines, so a naive
edit changes DNG too — the fix has to be conditioned on the active pipeline.
The brief also records what is *not* wrong: the ramp did not run away (it held
to 0.12 stops over two hours), and the darkness is the seed anchor working as
designed.

### Capture Flat is dead on the blended JPEG path, and unlogged

**Detail:** [capture-flat-jpeg-brief.md](capture-flat-jpeg-brief.md) ·
**Raised:** 2026-08-23 · **Implemented 2026-08-23 — device verification pending**

*Jobs A (log truth: `captureFlat`, honest `captureMode: dynamic`) and B (flat
graded on the window's half-float mean, one 8-bit quantise, same curve as the
photo path) are implemented on `ios-app`; Kit tests cover the float finalize.
Still owed: re-run the §1 A/B on device — expect saturation ≈×0.80, contrast
≈×0.90, `captureFlat` in both logs — plus the shadow-push latitude check. Job
C (sensor-side probe) is open, and one product gap surfaced: the blend-strategy
picker only reaches the DNG pipeline; JPEG Auto always runs Zone.*

A measured A/B (projects `JPEG flat` / `JPEG non flat`, 2026-08-23, iPhone 16
Pro, Interval · JPEG · Psycho · Dynamic) came out pixel-identical: the blended
JPEG writer never reads the Capture Flat flag — the toggle only works for
photo-output stills and video. Where it does run it is a save-time re-grade of
the finished 8-bit JPEG (decode → grade → second lossy encode), which is the
post filter the setting exists to avoid. And no still shoot records the setting:
`capture_log.json` has no `captureFlat`, its `captureMode` is hardcoded
`"interval"` (Dynamic runs are indistinguishable), and `algorithm` says `zone`
for every Auto run. The fix that matters: apply the flat curve to the blend's
existing **float32 mean** at finalize — one quantisation, in flat space
(`finalizeMean` → `encodeGamma` already owns this) — which is metering-neutral,
unlike any tap-encoding change. Related, and downstream in value of, the WB
brief above.

### Storage accounting, and the Settings storage card

**Detail:** [storage-accounting-job.md](storage-accounting-job.md) ·
**Raised:** 2026-08-21 · **Not started**

Deleting every project on the bench iPhone freed 0.08 GB of a claimed 26.29 GB.
Capture staging is cloned into the project on adoption and never released, share
archives are never deleted, and the tmp filter matches neither — so the device is
sitting on **44.6 GB the app reports as `Cache Zero KB`**. Four defects, plus a
redesign of the storage card around reclaimable bytes rather than allocated ones.
Includes a one-time reclaim for installs already carrying orphans, and a
design-sync pass on the Settings SVGs.

### `swift test` fails on a dead scratch path

**Raised:** 2026-08-22 · **Not started** · small

`LinearDNGTests.testBlendsRealUntouchedSequence` writes its output to a
hard-coded absolute path from a long-finished Claude Code session
(`Kit/Tests/LetsLapseKitTests/LinearDNGTests.swift:156`), so `swift test` ends
`243 tests, 1 failure` with `writeFailed("The folder "untouched-blend-3.dng"
doesn't exist.")`. It only bites where there is real capture data — without an
untouched-DNG project in `~/Library/Application Support/LetsLapse/Projects` the
test `XCTSkip`s — which means it fails on the dev machine and passes anywhere
else. Point it at `FileManager.default.temporaryDirectory` (or a
`URL.temporaryDirectory` subfolder created by the test). Until it is fixed,
`.claude/skills/run-letslapse/SKILL.md` documents the failure as expected.

### A scheduled stop is logged as `endReason: user`

**Raised:** 2026-08-22 · **Not started** · small

The fleet smoke's three arms were stopped by `scheduleStop`, and all three
logs record `endReason: user` (they ran 9.99, 9.99 and 10.18 minutes against a
10-minute deadline, so the mechanism itself worked). `performScheduledStop()`
passes `source: .scheduled`, so the mapping to the log's `endReason` is
losing it. It matters because gate criterion V4 ("ran to plan") cannot
distinguish a planned end from someone tapping stop.

### `remote_probe` digest() shows almost nothing for a video run

**Raised:** 2026-08-22 · **Not started** · small

Add the video keys (`baseFPS`, `rampFPS`, `sequenceMode`, `segmentCount`,
`markerCount`) to `digest()` in `tools/remote_probe.swift` — a video run's
one-line digest currently shows almost nothing, because the digest was written
around the interval keys.

*(The other half of this entry is done: the script grammar now parses
`cmd:extra#value`, so `scheduleStop:minutes#60` is sendable and a shoot can own
its own deadline instead of being timed from the Mac. The header comment's
Shared-source list was corrected to three at the same time.)*

---

## Where the rest of the open work is recorded

Not everything known-broken has been turned into a job yet. Until it is, these
are the standing lists:

- **[letslapse-app-overview.md](letslapse-app-overview.md) §10 — "Current limits
  and sharp edges."** The honest known-issues list for the whole app: the ramp
  voiding the warp timeline, the reframe canvas framing an approximate frame,
  `ReframeTrack.clamp` never being called, the responsive-capture wedge, the
  test gaps. Several of these are jobs waiting to be written up.
- **[overview-audit-2026-08-10.md](overview-audit-2026-08-10.md) Part C.** The
  reframe UX triage table — problems, severity, and the use cases the feature
  should serve.
- **[design/](design/) — each platform folder's `INDEX.md`.** Per-screen mirror
  status; anything marked stale is outstanding UI work by definition.
- **Holy Grail Field Program** (artifact). The blend-strategy field programme:
  what has been run, what passed, what the next bench is for.

## Fine rotation (Edit screen · Rotation section) — follow-ups

Shipped 2026-09-02: a ±10° straighten slider on the Edit screen for stills
and video projects (`RotationSlider`, `FrameRotation` in the Kit), levelled
into every preview and baked into blended, guided and standalone-grade
outputs; keyframeable like every other control (rotation lives in
`PhotoAdjustments`, eased per frame by every bake); text layers ride the
levelled frame (existing layers turn with the picture, new ones start level,
and a travelling level carries them per moment). Owed:

- **Project cards and thumbnails are not levelled.** `ProjectThumbnailCache`
  decodes without the grade, so a levelled project's card still shows the
  raw tilt; the hero (`ProjectMedia`), grid and fullscreen sheet ARE levelled.
  Decide whether the card should pay for a grade render.
- ~~**iOS viewer SVGs** (`project-photo.viewer.*`) are marked ⚠️ Stale~~ —
  redrawn 2026-09-13 with the editor redesign, where the ±10° control is the
  **Angle** slider inside the Crop group (`iOS/project-photo.viewer.crop
  .portrait.svg`, `iPadOS/…crop.landscape.svg`, `macOS/photo-viewer.crop
  .svg`; `LL_SECTIONS=crop`, the old `rotation` still answers).
- **Ken Burns collection export / time slicing** consume finished blend
  clips, so they inherit the level for free — but a collection built from
  a clip rendered BEFORE the project was levelled keeps the old geometry.
  Same rule as the grade; worth a line in the collection UI one day.
- **Keyframed rotation in mixed-resolution ramp shoots** (segment
  normalisation) levels every segment at the OPENING angle — the per-segment
  croppers have no whole-clip frame map to ease against — and the standalone
  pass then bakes colour only. Every other path eases per frame.
- **Adjust/Guided source-frame previews** level at the opening angle
  (`AdjustPreviewLevel`), not the moment's: the loaders know a clip time but
  not a source position. The bake is right; the preview is approximate under
  a travelling level.
- **Text-layer Angle shares the ±10° range** with the project control on
  purpose (one instrument). If a wider range is wanted for type, widen it
  on the overlay's slider only (`RotationSlider.range`).
- **Loupe / 1:1 patch under a level** is levelled by turning a larger
  source patch about the window centre (`PhotoGrader.renderDetail`);
  verified on Mac only at fit scale — pixel-peep a levelled DNG on device.
