# Job request: editor and project-page jobs (2026-10-04)

Eight jobs on the LetsLapse app (`ios-app` branch, `LetsLapse/`), in Steven's
priority order. Each has what to build, where it lives, the decisions already
taken, and what "done" is. Read `CLAUDE.md` first: the launch hooks, the
bench rules, and the design-sync requirement for any UI change.

**The pictures a project has** (background for jobs 2 and 5): a project on a
device may hold its originals, or only a *working copy* (`picture-<token>.heic`,
full size, the grade only, unlevelled and uncropped), or only its *poster*
(`poster.jpg`, 1280 px) and *tile* (`tile.webp`, ~400 px, cut by the server
from the poster). A project with no originals here is a *preview*. Text and
shape layers, mask shapes and custom masks are records (`overlays.json`,
`masks/`), normalised 0…1 over the levelled, uncropped frame; they need no
source pixels. Reference: `docs/picture-tiers-plan.md`.

## 1. Shape resizing — Edit ▸ Masks

**Now:** dragging a corner handle of a rectangle turns it into a polygon with
that anchor moved. Most of the time the person wants to stretch the rectangle
on one axis or resize it from a corner.

**Build:**
- Edge handles on each side of a rectangle (arrows on the lines) that resize
  along x or y: up, down, left, right.
- A *Preserve shape* toggle under the square lock, **on by default** (Steven
  reversed the spec's "off"): with it on, a corner drag resizes the rectangle
  from that corner; with it off, a corner drag moves the anchor as today.

**Where:** `App/Overlay/MaskShapeOverlay.swift` (the handles and drags; points
are normalised in `normalized(_:)`), `Kit/Sources/LetsLapseKit/MaskShape.swift`
(the shape model, coordinates documented at the top).

**Decided:** code first, no design pass (Steven). Mirror the handle drawing
in the Masks SVGs afterwards.

**Done when:** on the Mac (`LL_ITEM=latest:masks LL_RAIL=masks` with an
`LL_DRAG` on an edge handle, then on a corner with the toggle on and off)
the rectangle stretches on one axis, resizes from a corner with the toggle
on, and still becomes a polygon with it off; the saved shape round-trips
through `overlays.json`.

## 2. Masks and Text on a preview, on the poster — no download

**Now:** on a preview, the Masks and Text pages are gated by a sheet asking
for the working copy (1–4 MB). Shapes are the drivers of shape-mations and
are added fast, one by one; the person may not have the working copy or the
originals and should not need them for that.

**Build:**
1. **The poster carries the pixel work only** — grade, masked grades, level,
   crop. Text and shape layers leave the poster render: `FinishedPicture`
   (`App/Overlay/FinishedPicture.swift`) grows a *poster* flavour without
   layers; the *export* flavour keeps them at full quality. Every surface in
   the app draws the layers live from the records over whatever picture it
   has: the item view, the pager, the editor, the export composite. The grid
   tiles are an open sub-decision — default: not drawn there.
2. **The Masks and Text pages mount on the poster for a preview:** a new
   `EditorAsset.poster(url)` beside `.workingCopy` (`App/EditorPreviewPage.swift`,
   `App/PhotoViewerView.swift`), with the working copy's guards
   (`docs/picture-tiers-plan.md` §3.6: persist only overlay records, no white
   migration, no as-shot reads, no Lightroom sidecar) and one addition:
   touches map through the inverse of the records' crop rect and level angle
   into the uncropped frame, because the poster is levelled and cropped. A
   shape can only be placed inside the crop on a preview; that is accepted.
3. **Without a download on a preview:** add, move and resize shapes; draw
   custom masks; Sky/Land and Find shapes from the poster (both already run
   from 512–2048 px renders); add, move and edit text.
   **Behind the working-copy download:** crop (the poster is already
   cropped), the masked-grade sliders (an existing masked grade edited over
   pixels that already carry it shows twice), the loupe, Detail. The download
   affordance is an inline line on the control. The `FetchPrompt` sheet is
   removed from the Masks and Text doors (`App/FetchPrompt.swift`).
4. The web page shows the poster without layers until the PicPlace developer
   draws them from the records (ask filed in
   `docs/picplace-sync-cost-server-asks.md`, last section). Accepted.

**Decided:** no new asset of any kind (a "small working copy" was considered
and dropped). The Masks and Text pages need no design pass; the inline
download line is the one visible change — mirror it in the SVGs.

**Done when:** on the Simulator, a preview with no copy and no originals
(`LL_DROP_SOURCES=<uuid>:all` in one launch, `LL_TAB=gallery LL_ITEM=<uuid>:masks`
in the next) opens Masks with no prompt; a rectangle is added, resized and
moved, and a text box added; the Mac, holding the originals, pulls the
records and its export and poster show them in the same normalised place
(`LL_DUMP_OVERLAYS=1` on both); the poster the Mac re-uploads carries no layer
pixels; the Simulator's item view draws the layers live over its poster; the
masked-grade sliders on the preview show the inline download line and
nothing else blocks. Test sync only on throwaway projects.

## 3. Rename & Tags — one button, one drawer

**Now:** the project page offers *Auto rename & tag*, *Rename* and *Tags*.
The editor's (i) drawer repeats the title, and shows a date stamp and a
storage line that INFO and Storage already carry.

**Build:**
- Project page: the three become one *Rename & Tags* button. Pressing it
  opens the slide-up drawer with focus in the name field, and auto rename &
  tag runs at once without a prompt; it can be cancelled (a few seconds on
  slower phones).
- Editor (i) drawer: remove the second title (keep the top one, left of
  Done); tapping that title opens Rename & Tags with focus on the name
  field, with no hint that it is tappable; remove the date stamp and the
  storage line from the top; tags and *+ Add tag* stay as they are.

**Where:** `App/ProjectDetailView.swift` (the rows at ~444–449 and the
sheet at ~1240), `App/EditorPager.swift` (the (i) drawer), `App/TagEditor.swift`,
`App/AI/AutoRenameEngine.swift`.

**Decided:** nothing beyond the above. UI work: ask Steven design-first or
code-first before starting; both platforms.

**Done when:** on iOS and macOS the project page shows one button, the
drawer opens with the cursor in the name field while the auto result fills
in and can be cancelled, and the (i) drawer has one title, no date, no
storage line; SVGs updated.

## 4. The project card's copy on a device without the originals

**Now:** the 18 Pro took a photo, edited it, synced the records; its
originals are still only on the 18 Pro. On the 12 Pro the card's PICPLACE
section shows a greyed *Preview only* button and "The originals are on
PicPlace, not on this iPhone". Both are wrong: the originals are not on
PicPlace yet.

**Build:** the greyed *Preview only* button goes. The line says where the
originals are, from the records: on PicPlace when they are; otherwise "only
on <holder device>" (the holder's name is in the row's presence). Check the
state source as well as the copy — it is likely both.

**Where:** `App/PicPlace/PicPlaceViews.swift` (~559 the button title,
~602–604 the lines), `App/ProjectAvailability.swift` (~402–407 the tier
names), the holder's name from `ProjectHoldings` / the index row's presence.

**Done when:** on a second device, a project whose originals are only on
the holder says so and shows no greyed button; once the holder uploads, the
card says they are on PicPlace with the file count. Mirror the card SVGs
(`docs/design/iOS/project-detail.photo.picplace.*`).

## 5. Text on a preview

Covered by job 2: text is added, moved and edited on the poster without a
download.

## 6. Remove the *Save as preset?* offer on the editor's back button

**Now:** leaving an edited grade raises an offer to save it as a preset. It
is invasive, blocks the back button, and on macOS stops going back at all.

**Build:** remove the offer on iOS and macOS. The *Save as preset* action
stays where it is deliberately chosen (the presets screen); only the offer on
the way out goes.

**Where:** `App/VideoEditorView.swift` (~94, ~1076–1099, the inline offer in
the rail) and the photo editor's twin in `App/PhotoViewerView.swift` (search
"Save as preset").

**Done when:** backing out of an edited photo and an edited video on both
platforms returns at once with nothing raised; the presets screen still
saves a preset. Remove the offer from the SVGs that draw it.

## 7. *Clone and compress* becomes *Compress*, and reaches the Gallery

**Now:** the action lives only under the Projects tab ▸ project ▸ (…) ▸
*Clone and compress…*.

**Build:**
- Rename the action *Compress* everywhere; it still clones and compresses.
- Gallery tab, iOS and macOS: in the context menu under *Edit* and before
  *Delete*, add *Compress*; in the (i) drawer's *Storage* row, a *Compress*
  label on the right when the project supports it. Both open the same
  window as the Projects tab.

**Where:** `App/ProjectDetailView.swift` (~479–481), `App/ProjectDNGArchive.swift`
(~334, the window), `App/GalleryGridContent.swift` (~60, the multi-selection
path), `App/EditorPager.swift` (the (i) drawer).

**Decided:** TODO "Clone and compress — design mirrors, and a device run"
holds the window's existing mirrors. UI work on both platforms: design-sync
applies.

**Done when:** the three doors open the same window, the label reads
*Compress* in each, and the SVGs for the context menu and the (i) drawer are
updated.

## 8. Auto rename & tag — the second run's memory error

**Now:** with the Gemma 4B model, the first run works and the second shows
"LetsLapse is using too much memory right now — this model needs …". Apple
Vision never does. Toggling Settings ▸ AI ▸ *Use the installed model for
better results* off and on cures it, so the model is not unloaded after a
run, or is loaded a second time beside itself.

**Build:** find why the second run fails — the model instance kept after
the first run, or a second load — and make a run leave the model in the same
state the toggle leaves it in.

**Where:** `App/AI/ModelManager.swift` (~237 the message and the memory
gate), `App/AI/SceneAnalyser.swift` (`unload()` at ~104 and ~329),
`App/AI/AutoRenameEngine.swift`. Memory hub `ai-mlx-hub` has the model-host
history.

**Done when:** on a device with Gemma installed, auto rename & tag runs
three times in a row on different projects without the error and without the
toggle; the log shows one load and one unload per run, or one load kept
deliberately.

## Not in this request

PicPlace sync-cost work (bulk PUT on the client, the pull reading records
from the row, the bench re-run) is tracked in `docs/picplace-sync-v2-handover.md`
and `docs/TODO.md`; leave it unless Steven asks.

## Rules

- **UI changes follow the design-sync requirement** in `CLAUDE.md`: ask
  Steven design-first or code-first where this request does not already say,
  and mirror the other side in the same unit of work. Job 1 is code-first.
- **Test sync only on throwaway projects:** a change on a real one reaches
  every device. The bench root is `~/Library/Developer/LetsLapseRun/libraries/tiers-scratch`
  (bound to the synth library on picplace.test; mint a fresh token with
  `tools/sync-cost-bench/bench.py token --user synth`, revoke after, never
  print it). **Always launch a bound scratch root with `LL_PICPLACE_TOKENS`.**
- **The Mac bench is a Debug build.** Anything init-time or near a
  `#if DEBUG` region is checked on a device Release build; `strings -a` on
  the Release binary for a log literal is the quick proof.
- **Devices:** check for a capture or upload in flight before
  `devicectl install` (it terminates the app). A locked iPhone refuses a
  remote launch and runs the new build when opened. Steven runs the
  uncommitted tree on his devices from Xcode.
