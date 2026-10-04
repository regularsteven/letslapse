# Brief: after the picture-tiers detour (2026-10-04)

For the next agent. Steven's spec of 2026-10-03 listed eight issues. Before
any of them was started, a pivot into picture tiers and PicPlace sync cost
took two days and reached across this repo and the PicPlace server. This
brief says what that work left standing, what it still owes, where the eight
issues stand now, and one design question the detour reopened — whether
masks, shapes and text on a preview really need the full-size working copy.

Read first: `CLAUDE.md` (hooks, bench rules, the design-sync requirement),
`docs/picture-tiers-plan.md` (the tiers, §9–§17), `docs/picplace-sync-v2-handover.md`
(the sync programme's state table), `docs/picplace-sync-cost-server-asks.md`
(the conversation with the PicPlace developer, answers and all), `docs/TODO.md`
(every owed job, one entry each).

## 1. What stands (shipped and on every device)

**Picture tiers.** Four pictures per project, each made where it is cheap:

| Tier | Size | Made by | Carries |
|---|---|---|---|
| tile `tile.webp` | ~400 px | the server, from the poster | the grid |
| poster `poster.jpg` | 1280 px | the holder device | the **finished picture**: grade, mask grades, text and shapes, level, crop |
| working copy `picture-<token>.heic` | full size | the holder device (the grading engine) | the grade only, **unlevelled and uncropped** — the editor's canvas on a device without the originals; none for an unedited JPEG/HEIC (D6) |
| originals | full size | the camera | everything |

Stages 0–5 are in (`e50aefc`, `3d0d976`, `81f32c5`, `b87f015`): pointers in
the index, server tiles (backfilled), batched rendition sync, lazy posters,
the editor mounted on the working copy with the pixel groups locked, the
level as a record on display like the crop, the poster rendered from the
copy on a device without originals, the export through the same renderer,
status glyphs and the free-up rows for copies. Design mirrors for stage 5
are drawn; the two new iOS screens still want a phone capture for the index.

**PicPlace sync cost.** Steps 1–3 and §B are live on both sides and
measured: one `/status` per check, batched verification, md5 at negotiate
(no read-back), the change feed with a virtual index cached on disk
(`PicPlace/index-cache.json`), records inline on the PUT. A launch now costs
no index read; an idle check is `/status` alone; a check after an edit
elsewhere is one small page. The developer shipped step 6 (bulk PUT) and
switched on the tombstone refusal on 2026-10-04 14:00.

**Faults found and fixed on production this morning** (all committed, all
installed): the poster re-send for rows the server held without one (the 21
blank previews), duplicate proxies subtracted by pointer, a one-time
migration that read as a 20-minute check, the feed watermark never written
with the state, a poster catch-up loop on DNG projects the iPad cannot decode
(`e57a723`), and the index cache never read in Release builds (`f336d06`,
the call sat inside the init's `#if DEBUG` hooks block — see the memory
`release-only-code-near-debug-hooks`).

## 2. What the detour still owes

- **Bulk PUT on the client** (sync cost step 6; handover row "step 6"). One
  body of several single-PUT documents, under `limits.request_max_bytes`
  (16 MB on picplace.co). Candidates: the first connection's run of records
  pushes, a library re-sync. Not urgent; the single PUT is correct.
- **The pull reading `records` from the row** (step 5's second half) once
  the server carries them for every project. Parked until the developer says.
- **The sync-cost bench re-run** (`tools/sync-cost-bench/`) over steps 2, 3
  and §B — the TODO rule is a bench after each job; none has run since
  step 2. About 30 minutes, Mac and Simulator, no devices disturbed.
- **Design index captures** of the two new iOS screens
  (`project-detail.photo.picplace.working-copy`, `settings.picplace.signed-in.free-up`)
  and Steven's look at the pill's green `photo.fill` on a device.
- **The copy pass** (TODO "Copy pass — where a file is when it is not on
  this device"): the Settings row *Remove originals already on PicPlace* was
  read as deleting on PicPlace; the project card's "Preview only" wording is
  issue 7 below.

## 3. The eight issues, where they stand

Steven's priority order, with the state after the detour:

| # | Issue | State | Notes |
|---|---|---|---|
| 1 | Shape resizing (edge handles; corner resize toggle) | **not started** | Code first, no design pass (Steven). The toggle is **Preserve shape, ON by default** — Steven reversed the spec's "off". Lives in `App/Overlay/MaskShapeOverlay.swift`; shapes are normalised 0…1 (`Kit MaskShape.swift`). |
| 2 | Edit ▸ Masks on a preview ("needs the full-size photo") | **landed on the working copy**, reopened by §4 | A preview opens Masks after *Download working copy* (`EditorPreviewPage`, `FetchPrompt`, `EditorAsset.workingCopy`). Works; the question is whether the download is the right price. |
| 3 | Auto rename & tag — simplification (one *Rename & Tags* button, the drawer, the (i) drawer slimmed) | **not started** | TODO "Auto rename & tag in the Gallery — owed follow-ups" holds the earlier notes. UI work: ask design-first or code-first. |
| 4 | Copy issues on the 12 Pro's card (greyed "Preview only", "originals are on PicPlace") | **not started** | Both a copy and a state bug: the card must say *only on iPhone 18 Pro* when the holder has not uploaded, and the greyed button goes. `App/PicPlace/PicPlaceViews.swift`, status from `ProjectAvailability`. |
| 5 | Text on a preview | **landed on the working copy**, reopened by §4 | Same mechanism as 2. |
| 6 | Save-as-preset offer on the editor's back button | **not started** | Remove the offer on iOS and macOS (it blocks the Mac's back). `PhotoViewerView.swift`, the preset-offer branch. |
| 7 | Clone and compress → *Compress*, in the Gallery too (context menu, (i) drawer) | **not started** | TODO "Clone and compress — design mirrors, and a device run" has the window's mirrors. UI work on both platforms: design-sync applies. |
| 8 | Auto rename & tag — Gemma memory on the second run | **not started** | "LetsLapse is using too much memory" on the second run only; the Settings toggle off/on cures it → the model is not unloaded or is loaded twice. `App/AI/` (the MLX host, eviction); see the memory hub `ai-mlx-hub`. |

Numbers are the spec's priority order, not its section numbers.

## 4. The reopened question: does editing a preview need the working copy?

**Facts.** Shapes, text and mask shapes are stored in normalised 0…1
coordinates over the levelled, uncropped frame; mask grades are
display-referred on top of the finished grade; their saves are JSON writes
with no render (`picture-tiers-plan.md` §3, "Overlays need no source
pixels"). What reads pixels on those pages is small: Sky/Land segmentation
(a 512 px render), Find shapes (1024/2048 px), the detail loupe, the
Lightroom sidecar. A custom mask is a file in `masks/` drawn by hand.

**Why the working copy was chosen anyway.** Two reasons, both engineering,
neither about the maths:

1. The editor's pages are one host built around a full picture whose write
   paths assume an unbaked, uncropped source (plan T6). Mounting them on
   the working copy reused the host as it is; a second host for Masks and
   Text on another picture meant rebuilding those pages.
2. The poster became the **finished picture** on 2026-10-04 — crop, level,
   text, shapes and mask grades baked in. It cannot be a canvas: an edited
   text box would show twice, and the frame is not the one the overlays
   are normalised over.

So "use the poster" is not available as it stands. The real cost Steven
objects to is the download prompt and its size: a working copy is 1–4 MB
(HEIC, full size), and the prompt stops the person before a job that needs
no pixels at all.

**Options.**

- **A. A small working copy.** The same recipe as the proxy (grade only,
  unlevelled, uncropped, same token) at ~2048 px long edge, HEIC, roughly
  300–600 KB. The holder device renders it in the same pass as the full copy
  (a second encode of the same render). The editor mounts it through the
  existing `EditorAsset.workingCopy` path, so Masks, Text, crop, Sky/Land and
  Find work unchanged (they already run at 512–2048 px). The full copy is
  fetched only for *Download full size*: the detail loupe, pixel peeping,
  export at full size from a device without originals. Needs a server kind
  (one ask: a second proxy variant in `renditions`, index pointer, presence
  tier), the batch paths, and the free-up rows to know two copies.
  About two to three days, plus the developer's part.
- **B. No new picture; no prompt on Wi-Fi.** Fetch the working copy silently
  when the path is Wi-Fi and the copy is under a few MB; prompt only on
  mobile data or for a large copy. One day. Removes the friction, not the
  bytes.
- **C. The poster as canvas.** Would need an *unbaked* poster, which undoes
  the finished picture in the grid and on the web — not recommended.

**Recommendation: B now, A as the next tiers stage.** B is a one-day change
that answers the complaint on a home Wi-Fi. A is the right shape of the
system — the pull-to-a-device rule Steven states ("the proxy and originals
come down for a specific reason") — and it makes every preview editable at
~0.5 MB. On "disable sky detection for the poster version": not needed;
Sky/Land already works from a 512 px render, so it runs on a small copy as
it does on the full one.

**Decision needed from Steven** before A starts: a second rendition kind
on PicPlace (yes/no), and whether the small copy replaces the full copy as
the *default* download on a preview (recommended: yes; the full copy behind
*Download full size*).

## 5. Rules for whoever picks this up

- Test sync only on throwaway projects: a change on a real one reaches
  every device. The bench root is `~/Library/Developer/LetsLapseRun/libraries/tiers-scratch`,
  bound to the synth library *tiers-s5* with the JPEG fork `2C0ECD5B…` as the
  fixture; mint a fresh synth token per bench (`tools/sync-cost-bench/bench.py token --user synth`),
  revoke after, never print it. **Always launch a bound scratch root with
  `LL_PICPLACE_TOKENS`.**
- A server-side change made outside the API (a dropped asset row in tinker)
  moves no sequence, so the virtual index never sees it: pair it with
  `LL_PICPLACE_FEED=reset`.
- The Mac bench is a Debug build. Anything init-time or near the `#if DEBUG`
  hooks region is checked on a device Release build (`strings -a` the binary
  for a log literal is the quick proof).
- Devices: check for in-flight capture or upload before `devicectl install`
  (it terminates the app). Locked iPhones refuse a remote launch; they run
  the new build when opened.
- UI work follows the design-sync requirement in `CLAUDE.md`: ask
  design-first or code-first, mirror the other side in the same unit of
  work. Issue 1 is code-first by Steven's word.
