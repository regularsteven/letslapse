# LetsLapse — agent instructions

## Repository layout

- `main` branch: the original Raspberry Pi LetsLapse project (Python capture/blend scripts + web UI). **Untouchable** — never modify it from Swift-app work.
- `ios-app` branch: the native Swift app in `LetsLapse/` (universal iOS/iPadOS/macOS target + watchOS companion + `LetsLapseKit` package). Architecture handover doc: `LetsLapse/docs/letslapse-app-overview.md`.
- Open, scoped-but-unstarted work lives in `LetsLapse/docs/TODO.md` — one entry per job, long jobs in their own document alongside it. Add a job there rather than leaving it in a conversation.
- Fresh Mac / newcomer build guide: `LetsLapse/docs/building.md` (Xcode components, package resolution, signing, every first-run error decoded). The app project links `MLXVLM`/`MLXLMCommon` from a **committed** patched copy of `mlx-swift-lm` at `LetsLapse/tools/mlx-vlm-spike/vendor/mlx-swift-lm/` — regenerate it with `vendor/refresh.sh`, never edit it by hand, and never gitignore it again: with it absent Xcode fails the whole package graph ("Missing package product" for every product, `LetsLapseKit` included).

## Design-sync requirement (ALL iOS / iPadOS / macOS / watchOS UI work)

The app's screens are mirrored as SVG design specs in `LetsLapse/docs/design/` (per-platform folders, one file per screen per orientation). The full contract lives in `LetsLapse/docs/design/README.md` — read it before any UI work. The short version:

1. **At the start of any UI task**, if the human hasn't said where to work, ask:
   *"Should we work on the design files first, the app code first, or something else?"*
   (A third standard path: the human has already edited the design files themselves — then the edited SVG **is** the spec; implement it.)
2. **After sign-off on one side, mirror the other side in the same unit of work.** A UI change is not done while its SVG (or its code) is stale.
3. Any commit touching SwiftUI layout/copy/colors/controls must update the matching SVG(s) — or state why no SVG applies. Track per-screen status in each platform folder's `INDEX.md`.
4. Verify mirrors against the running app using the DEBUG launch hooks (`LL_TAB`, `LL_OPEN`, `LL_SEED`, `LL_DETAIL`, `LL_PUSH`, `LL_CAPTURE`, `LL_BURST`, `LL_SPEED`, `LL_AUTO`, `LL_VIEWER`, `LL_SECTIONS=presets|light|color|effects|detail|crop[:<tool>[:<band>]]` (legacy `all|wb|mixer|rotation` still answer), `LL_PADS=off`, `LL_COLLECTIONS`, `LL_IMPORT_STILLS=<path>[:<path>…]` (+ `LL_IMPORT_ANSWER=shoot|photos|cancel`, else a multi-file import stops on its sheet), `LL_OPEN_FILES=<path>[:<path>…]` hands files to the app's open door (`AppModel.openURLs` — the share sheet's LetsLapse on iOS, each file copied into Documents/Inbox first as iOS does; Open With on the Mac) and, on iOS, `LL_SEED_PHOTOS_PAIR=<jpeg>:<raw>` saves a RAW+JPEG pair into the Simulator's photo library while `LL_IMPORT_LIBRARY=latest|<localIdentifier>[,…]` runs From Photos… without the picker (2026-10-13, `App/PhotoLibraryOriginals.swift`: a pair's RAW is reachable only through PhotoKit with read access — `simctl privacy <udid> grant photos com.regularsteven.letslapse` — the picker and the share sheet hand over its JPEG; the log's `photos:` lines say which file came in and why), `LL_SELECT=latest|<uuid>` + `LL_PANEL=presets` for the Gallery preview panel; `LL_ITEM=latest|<uuid>[:page]` opens the Gallery's item view on the Mac and, on iOS, the editor **pager** (2026-09-21: a tap on a tile opens the editor as a cover that swipes through the grid's result set; `LL_CLEAR=1` opens it in clear preview, `LL_PAGE=next|previous[@<seconds>][x<turns>]` turns pages without a finger — with `x12` a swipe bench whose every turn logs a `pager: turn → …` timing line, see the Connected asset states paragraph); `LL_AUTORENAME=1|demo` with `LL_SELECT=<uuid>,<uuid>[,…]` enters the Gallery's Auto rename & tag review list from launch (`demo` stages the three drawn row states without a model); `LL_KEY=cmd+z@16;cmd+shift+z@20` posts in-process key presses to the main window (the keyboard twin of `LL_DRAG` — never the HID stream); the list screens take `LL_FILTER=all|photos|interval|video|scans`, `LL_QUERY=<words>`, `LL_CHIPS=tag,tag` and `LL_DUMP_ORDER=1`, which logs the ids a list rendered in order — the exact before/after check for anything that touches how the Projects list or the Gallery sort, filter or search; sort keys are `@AppStorage`, so `-projects.sortKey capture -projects.sortAscending YES` as launch arguments, never a write to the shared defaults; `LL_APPLY_PRESET=<id|origin|latest>:<preset>[@<seconds>][;…]` applies built-in presets through the real grade path (several entries since 2026-09-30, each at its own delay, default 2 s; an id may be the project's own or its origin); `LL_IMPORT_ARCHIVE=<a.lapse>[:<b.lapse>…]` opens `.lapse` files through the double-click door, in order; `LL_PICPLACE_TRACE=1` writes one `picplace trace:` console line per API request (method, path, status, ms, bytes each way) and per storage PUT/GET — the sync-cost bench (`LetsLapse/tools/sync-cost-bench/`, import → edit → Simulator pull → edit → Mac re-pull, a data-pack report per run) is built on it; `LL_ROTATE=latest|<uuid>[:<turns>]` presses Rotate 90° that many times (a record since 2026-09-24 — hash the project folder before and after: only `project.json`, `overlays.json` and `shapes.json` may change); `LL_RENDITIONS=render:<latest|uuid>|sweep` (2026-10-03, picture tiers — `docs/picture-tiers-plan.md`) renders a project's poster and full-size working copy `picture-<token>.heic` into its folder with no server, or forces one working-copy sweep (the charger rule ignored, for the Simulator) — the scratch library `~/Library/Developer/LetsLapseRun/libraries/tiers-scratch` holds a DNG project and an unedited JPEG for it; `LL_RENDITIONS_SALT=<s>` makes every working copy stale under a new name (the bench for a re-render and `replaces` on the batch path); `LL_TILES_LOG=1` logs every grid tile drawn from the server's `tile.webp` (a preview's grid picture since stage 2, and since stage 3 a pulled preview's only picture until it is opened — posters come on open; on picplace.test the queue listener runs on both queues while `composer dev` is up, else `cd ~/Sites/picplace && php artisan letslapse:render-tiles --now` cuts the tiles inline); stage 5 (status and space): the pill's green `photo.fill` beside a grey camera is *Working copy here* (`StatusGlyph.Asset.workingCopy`, `HoldingsPillState.workingCopy`; `LL_PILL_SHEET=1` draws its three states), `LL_PICPLACE_FILTER=workingCopyHere` is the Gallery's filter, `LL_PICPLACE_REMOVE=<uuid>:workingcopy` presses the card's Remove on the copy (no server check — the file goes, presence drops to `preview`), `LL_PICPLACE_FREEUP=copies` presses Settings ▸ PicPlace ▸ *Remove working copies not opened in 30 days* once the estimate lands (the clock is the record's `workingCopyUsedAt`, set by a fetch, an editor mount and an originals removal that leaves a copy behind — edit it in `PicPlace/sync-state.json` with the app closed to stage the row), and a device posts presence tier `proxy` whenever a fresh copy stands in for the originals; since 2026-10-04 the level is a record on display like the crop (the Angle slider works on a copy; `PhotoAdjustments.geometryOnly`), a photo's poster is the finished picture — grade, masked grades, text and shapes, level, crop (`App/Overlay/FinishedPicture.swift`, `PicPlacePoster.ensure(finished:)`, the overlay document's fingerprint in `currentPosterToken`) — rendered from the working copy on a device without the originals, the export goes through the same renderer, and `LL_TEXT=crafted` stages its line on a single photo (the finished-picture bench: crafted text → the push's `poster for` line → open `poster.jpg`); `LL_AUTOAPPLY="<photo|interval|video|all>[:<filter>]:<preset name>[;…]"` stages auto-apply rules in memory, never written (the preset screens' AUTO APPLY rows, the conflict dialog's other side, the capture screen's preset chip; filters `all|jpegs|jpegStandard|jpegFlat|dng|flatOff|flatOn`, names the seeded presets' or a built-in's) and `LL_PRESETS=autoapply` opens Natural's screen with the section above the fold; `LL_REGISTER=<photo|interval|video>:<path>[,<path>…][:flat]` registers those files as if the camera had just made them — the finish closures' own `processPhotoBurst`/`setSource` with the auto-apply context, files copied to staging first — the registration path's one door on a machine without a camera (one launch = one project; since 2026-10-17 a path without a leading `/` is relative to the app's data container, so on a device `xcrun devicectl device copy to --device <udid> --domain-type appDataContainer --domain-identifier com.regularsteven.letslapse --source <file> --destination tmp/<name>` then `LL_REGISTER=photo:tmp/<name>` registers it — `LL_IMPORT_STILLS` takes the same relative form); PicPlace: `LL_PICPLACE=<state>` (incl. `not-connected`), `LL_PICPLACE_DRYRUN=latest|<uuid>` runs the file side of a sync — classification, `records.aar`, `poster.jpg` — with no server, `LL_PICPLACE_POLICY=minimal|originals|everything`, `LL_PICPLACE_MANIFEST_CAP=<bytes>` forces the manifest-as-asset path, `LL_PICPLACE_BIND=clean|fresh|merge` stages the v2 connect question's case line (a server without libraries), `LL_PICPLACE_LIBRARIES=<n>` stages the stage-C connect sheet with n demo libraries, `LL_PICPLACE_CONNECT=new:<name>|adopt:<name>|link:<uuid>` presses Connect with that target once signed in (the bench; pair with `LL_PICPLACE_TOKENS`), `LL_PICPLACE_OFFER=1|new|adopt|link:<uuid>` opens the real connect sheet with that target selected (photograph it, then press Connect by AX), `LL_PICPLACE=preview-only` stages the pulled-project card, `LL_PICPLACE_DELETE=<uuid>[,<uuid>…]` deletes projects before the launch check (`all-local` deletes every project whose sources are on the device — never a pulled preview — and only on a scratch root: how a bench run's throwaways are tombstoned), `LL_PICPLACE_RESOLVE=newest|local|server|both` decides the check's conflicts, `LL_PICPLACE_REVIEW=1` opens the conflicts sheet, `LL_PICPLACE_DOWNLOAD=<uuid>[,<uuid>…]` (ids or origins) moves those projects' originals down after the check (`LL_PICPLACE_UPLOAD=<uuid>` presses Upload at launch — see the upload jobs paragraph below), `LL_PICPLACE_RENAME=<uuid>:<name>[@<seconds>]` renames through the funnel 5 s after launch, or that many (auto-sync's cue; a later one lands inside `LL_PICPLACE_OUTAGE`), `LL_PICPLACE_CHECK_INTERVAL=<s>` shortens the auto-check timer, `LL_PICPLACE_FEED=off|reset` (2026-10-04, the change-feed client — `App/PicPlace/PicPlaceChangeFeed.swift`: the check keeps a virtual index, reads the whole one once, then `GET /changes` since the watermark in `PicPlace/sync-state.json`'s `meta.changeSeq`, and nothing at all when `/status`'s library head has not moved; `off` reads the whole index every check for an A/B, `reset` forgets the watermark at launch; the log's `picplace: feed —` lines say which path a check took; the full read takes `?shape=feed` with one `GET /devices` for the names), `LL_POSTER_FAULT=1` (DEBUG) makes every poster render fail — the bench for a poster the device cannot make (pair with `LL_PICPLACE_FEED=reset` after any server-side change made outside the API, which moves no sequence); `LL_PICPLACE_BACKGROUND=1|<start>:<seconds>` (DEBUG, 2026-10-16) makes the push's render gate read the app as in the background — for the run, or for that window after launch, at whose end the pushes it put off go again as a foreground does: iOS aborts GPU work from a backgrounded app, so the push renders nothing there — a new project is not sent at all and goes up whole in front (the log's `deferred: app in background`), an edit's records go without the poster and the record's `posterDeferredAt` queues the poster push at the next check in front, a poster catch-up waits; only a render that fails in front takes the 6-hour gate (its line says `render failed`); the decision is `PicPlacePushGate` in the Kit, `PicPlacePushGateTests` its proof; `LL_PICPLACE_RECORDS_CAP=<bytes>` (DEBUG, §B records inline — the push's PUT carries `metadata.json` and `assets.ndjson` as `records` when `/status` says `records_inline`; a low cap makes a small project log *over the inline cap; the bundle carries them* and PUT without them; a server's `413 records_too_large` does the same once), `LL_PICPLACE_NETWORK=cellular[:seconds]` pretends the path is mobile data (then Wi-Fi again; `cellular@<start>[:seconds]` leaves Wi-Fi mid-run), `LL_PICPLACE_RATE=<n>` pins the client's request budget per minute (set high, it reproduces the 2026-09-15 storm against the server's real limiter and exercises the `429`/`Retry-After` path), `LL_PICPLACE_OUTAGE=<start>:<seconds>` makes every request fail as offline for that window after launch (the failed-push records the check retries with backoff), `LL_PICPLACE_TRANSFER_OUTAGE=<start>:<seconds>` does the same to the presigned PUTs/GETs only (the transfers' own in-place retries, `PicPlaceTransfer`), `-letslapse.picplace.autoOriginals YES` as a launch argument switches the originals queue on for a run, `LL_SCROLL=picplace|libraries` lands Settings on the card, `LL_STORAGE=move|adopt|create|list|moving|done|failed` stages the Libraries sheet or list with no disk touched, `LL_CREATE_LIBRARY=<path>[:<name>]` / `LL_OPEN_LIBRARY=<path>` run the real create / open on a scratch path (a scratch run never persists the libraries list or the root), on iOS the libraries live at `<App Support>/LetsLapse/Libraries/<id>/` and `-storage.activeLibrary <id>` as a launch argument opens one for a run without writing the setting, and `LL_OPEN_LIBRARY=<id>[,<id>…]` there switches to each folder in turn four seconds apart (the other launch hooks run again in each library switched to), `LL_LIBRARY=switch:<id>|add:<server uuid>|new:<name>|remove:<id>|rename:<id>:<name>` works the phone's Libraries doors without a finger (waits for the session where PicPlace is needed), `LL_SHAPEMATION=home|find|build|family|projects|mode|board|frame|list|rerender[:<uuid>]` opens the Shape-mation sheet on that screen (`build` = Apply filters, which `LL_CHIPS`/`LL_QUERY` pre-fill; `projects|mode|board|frame` pick every project of the family with the most shapes and land on that step — `board` under Least crop on the Sequence board, `frame` under Output frame; `rerender` = the newest record with members, or the named one, on its board with the members locked) and `LL_BOARD=charts|cog|fixed` scrolls the board's side column to that card and opens the cog (`fixed` never switches the seat — press 'Fixed shape' by AX as an AXRadioButton); the Mac sheet grows to 900×720 on the board step, so capture the untitled window; `ax press '*' AXButton 'Create the Shape-mation'` is the sheet's button (the Create tab's row is 'Create Shape-mation'); `LL_SYNC_PANEL=1` opens the Projects/Gallery header's *Project Syncing* sheet as the header appears — on the Mac; on iOS a sheet raised that early is dropped, tap the pill instead; `LL_PROBE_FORMATS=1` (Debug) prints every back lens's exposure/ISO/aperture envelope and, on iOS 27, the per-format custom-exposure predicate's answers for the virtual device and its constituents — the question the setter asks before it aborts, see `docs/fieldtests/2026-09-21-ios27-virtual-device-custom-exposure.md`) via `simctl launch`. Mac buttons in a driver-launched instance are pressed through accessibility, never the pointer: `~/Library/Developer/LetsLapseRun/tools/ax press <pid> '*' AXButton '<label>'` (`*` searches every window of the pid — a SwiftUI sheet is its own untitled window). A fresh Simulator for PicPlace work — erase, signed Simulator build, boot, Valet CA trusted, install, launch — is `LetsLapse/tools/sim-fresh.sh` (`--new`, `--keep`, `--no-build`, `--device`). The PicPlace sync programme's state — complete / owed / next / traps / tested vs untested — is `LetsLapse/docs/picplace-sync-v2-handover.md`; the two-device bench is `LetsLapse/tools/picplace-bench/`. Test sync only on throwaway projects: a change made on a real one reaches every device. A drawing gesture on the Mac (mask, shape, crop handle) is exercised with `LL_DRAG=x1,y1,x2,y2[,delay]` — an in-process drag handed to the view under the point, never the HID stream, so it is safe beside Steven's own running copy; start the rail where the armed tool lives (`LL_RAIL=masks` with `LL_ITEM=latest:masks`), since a rail-tab change disarms `LL_SHAPETOOL`/`LL_MASKTOOL`. The Masks page is called **Regions** on screen since 2026-10-16 (it holds masks and shapes; `Regions*` once the project has a region of its own) — `RailTab.masks` and the hooks keep the old word, and `regions` answers wherever a page word is taken (`LL_RAIL`, `LL_ITEM=<id>:regions`, `LL_PREVIEW_PROMPT`); the phone's page is two sections, Masks | Shapes, the last one chosen remembered, and `LL_REGIONS=masks|shapes[@<seconds>]` presses the switcher through the real path. The touch editors draw one top row on every page (Back · ⓘ · the pill) and a swipe pages between projects from the Text and Regions pages too, landing on the same page.

Design tokens (`LL` in `App/DesignSystem.swift`): accent `#C36A00`, amber `#FFB340`, ink `#1C1C1E` — the README has the full table. If `DesignSystem.swift` changes, the SVGs are stale by definition.

PicPlace free up space hooks (2026-09-23, `App/PicPlace/PicPlaceFreeUp.swift`, TODO "PicPlace free up space"): `LL_PICPLACE_REMOVE=<uuid>[:originals|blends]` presses the project card's Remove (past its confirm) after the launch check; `LL_PICPLACE_FREEUP=1` presses Settings ▸ PicPlace ▸ *Remove originals already on PicPlace*; `LL_PICPLACE_UPLOAD_ALL=1` its *Upload* (the originals queue once — since 2026-09-24 it waits for Wi-Fi when *Only on Wi-Fi* is on); `LL_PICPLACE_ASK_REMOVE=originals|blends` opens the card's Remove confirm for a screenshot; `LL_SCROLL=picplace` also lands the project screen on its PICPLACE card. The Project Syncing drawer's sending block (2026-09-24: progress, **Pause**/**Resume** — press them by AX, `AXButton 'Pause'` / `'Resume'`) is staged with `LL_PICPLACE_NO_BATCH=1` (the check acts as if the server lacked the batched asset read, so unnoted posters go through the push queue) and a low `LL_PICPLACE_RATE` to slow it; wipe the `posterToken`s in a bound scratch root's `PicPlace/sync-state.json` to make the work. **A bench root bound to an account must always launch with `LL_PICPLACE_TOKENS`** — without it an unsigned Debug build reads the Keychain and raises a SecurityAgent password prompt on Steven's screen (it did, 2026-09-23). A Simulator that has to sign in needs the locally signed build (`CODE_SIGN_IDENTITY=-`, as `tools/sim-fresh.sh` builds) — the unsigned one fails with Keychain -34018.

PicPlace upload jobs (2026-09-24, `App/PicPlace/PicPlaceUploadJobs.swift`, TODO "PicPlace uploads as jobs"; background uploads planned in `LetsLapse/docs/picplace-background-uploads-plan.md`): `LL_PICPLACE_UPLOAD=<uuid>` presses the card's Upload **once per process, at launch** (before the launch check, which mobile data holds); `LL_PICPLACE_UPLOAD_PAUSE=<s>[:<s>]` pauses that upload s seconds after it starts and resumes it s seconds after the pause; `LL_PICPLACE_UPLOAD_MOBILE=<s>` presses *Use mobile data*; `LL_PICPLACE_PUT_DELAY=<ms>` sleeps before every PUT so a picplace.test upload is slow enough to pause; `LL_PICPLACE_NETWORK=cellular@<start>[:<seconds>]` starts on Wi-Fi and moves to mobile data `start` seconds in (the phone walking out of the house), back after `seconds`; `-letslapse.picplace.wifiOnly YES` as a launch argument turns *Only on Wi-Fi* on for a run without writing the setting. Jobs live in `meta.uploadJobs` of the root's `PicPlace/sync-state.json` — a held job for a screenshot is written there with the app closed. PicPlace dedupes by SHA-256 across the account, so a bench project made of photos already uploaded "finishes" at once with nothing sent: append a few random bytes to each JPEG for a real upload. Every upload now logs *uploading N of M file(s), size; K already on PicPlace* at its start — the line that shows how far a resume skipped. Continued processing (iOS 26+, `PicPlaceContinuedTransfer`): a person's press only (Upload, Resume, *Use mobile data*, a Download) asks iOS to keep the app running, and each request registers a handler for its own identifier first — a request without one **aborts the app** (it crash-looped Steven's iPad on 2026-09-25); `LL_CONTINUED_PROBE=<seconds>` (DEBUG) runs a continued task with no transfer behind it — the device check for any BackgroundTasks change.

Connected asset states (2026-09-25, plan `LetsLapse/docs/connected-asset-states-plan.md`, `App/EditorPreviewPage.swift`, `App/ProjectAvailability.swift`, `App/FetchPrompt.swift`): a project whose picture is not on the device opens on the editor's **preview page** (its chrome greyed in place over `poster.jpg`) wherever the editor opens. `LL_DROP_SOURCES=<latest|uuid>[:originals|blends|all]` makes a genuine preview-only project with no server — renders `poster.jpg` (and blend stills), deletes the heavy files, keeps the records — only on a Mac scratch root (`-storage.libraryRootPath`) or in the Simulator; run it in one launch, look in the next (`LL_TAB=gallery LL_ITEM=<uuid>` — the Mac item view, the iOS pager). `LL_PREVIEW_PROMPT=<group>|text|frames|masks|line[:download]` raises the just-in-time prompt on the first preview page; `:download` presses *Download and Continue* two seconds later (a Simulator no headless run can tap). The real round trip is the bench (a bound scratch root, `LL_PICPLACE_TOKENS` always): upload → `LL_PICPLACE_REMOVE=<uuid>:originals` → `LL_ITEM` + `LL_PREVIEW_PROMPT=light` → `ax press <pid> '*' AXButton 'Download and Continue'` on the Mac → the editor lands on Light; `LL_PICPLACE_TRANSFER_OUTAGE=0:20` holds the download long enough to see its progress line. Since stage 3 (D1) blends upload on their own — the blends queue (`PicPlaceAutoSync.runBlendsQueue`, policy `.blends`, Settings ▸ PicPlace ▸ *Upload blends automatically*, on by default) — and a still per blend rides every records push; a bench blend is a record appended to `project.json` (with `capture.modifiedAt` bumped) plus a file in `blends/` with random bytes appended (SHA dedupe), and `LL_DROP_SOURCES=<uuid>:blends` + `LL_COLLECTIONS=seed|detail` stages the collection builder's missing-clip states. Stage 4 (swipe speed on the capture device, plan §13): the pager renders its neighbours' opening pictures ahead (`App/EditorLookAhead.swift`) and logs every turn's phases; the device bench is a Release build with `SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG $(inherited)'` (optimised, hooks on) launched with `devicectl … -e '{"LL_TAB":"gallery","LL_ITEM":"<uuid>","LL_PAGE":"next@4x12","LL_PICPLACE_NETWORK":"cellular"}' com.regularsteven.letslapse -- -letslapse.picplace.wifiOnly YES` (PicPlace held, nothing written; app arguments after `--`; the phone unlocked), then pull `Logs/`. A display link left to itself slows when nothing animates and reads as a main-thread stall — the probe pins it to 60 Hz. The Gallery's PicPlace filters (plan §14, `App/ProjectStatus.swift`): `LL_PICPLACE_FILTER=<onDevice|downloadAvailable|notAvailable|needsUploading|hasBlends|attention>` presses one from launch (pair with `LL_DUMP_ORDER=1` to log the grid's ids), `LL_SIDEBAR=1` raises the phone's Library sheet; the status sweep logs `status: swept N project(s) in X s`. Stills in collections (plan §15, D4): `LL_COLLECTIONS=still|still-kb` makes a "Still test" collection from a video blend and a still made from the newest photo (with `still-kb` in Ken Burns mode) and opens it — press `AXButton 'Export collection'` and probe `Collections/<id>/render.mp4`. Collections sync with PicPlace only once its /status says `features["collections"]` (docs/picplace-collections-ask.md). Status glyphs (plan §16, signed off 2026-09-26 on the canvas "Holdings Pill States"): green means here, grey on PicPlace, slashed nowhere; one cloud, never green, says whether what is here is safe; every surface draws `StatusGlyph` from `App/HoldingsPill.swift`. `LL_PILL_SHEET=1` renders every pill state on the device into `Logs/pill-sheet.png` (pull it with devicectl — the real-size check); `LL_DUMP_PILLS=1` logs each drawn pill (`pill: <title> — …`).

Blend jobs (2026-09-30, `App/BlendJobs.swift`, Kit `BlendSegments.swift`): every blend is a job folder, `Projects/<id>/.jobs/blend-<job id>/` (`job.json` + finished pieces per pass), so Pause, a background (iOS runs no GPU work there — it pauses and resumes by itself), a quit or a kill costs the piece in flight (~10 s of work), never the run; the relaunch offers the interrupted job once (*Resume blending?*). Bench: `LL_OPEN=latest LL_AUTO=process LL_SPEED=20 LL_BLEND_SEGMENT_SECONDS=1` plus `LL_BLEND_PAUSE_AT=0.4` (Pause) or a `kill -9` once `.jobs/…/main/piece-*` exist, then relaunch with `LL_BLEND_RESUME=latest` (or `LL_TAB=projects` to see the offer); the log's `blend resumed (seek)` is the exact-resume line (`counted` means the seek missed and the source was decoded in from the start). Background on the Simulator = `simctl launch <udid> com.apple.Preferences`, back = `simctl launch <udid> com.regularsteven.letslapse`. On the Mac run a scratch root (`open -n -g --env … --args -storage.libraryRootPath <scratch>`) and quit that instance by pid only. `LL_BLEND_CANT_RESUME=1` stages the card's Start Again state. Blends keep the screen from auto-locking.

## Capture test rig (monitor test card)

Repeatable ground truth for on-device capture timing. Full spec:
`LetsLapse/tools/testcard/README.md`.

- **Card**: `LetsLapse/tools/testcard/index.html` fullscreen on a monitor
  (portrait). Renders a session QR `LLTC1;<script>` (grammar
  `i25x100,b100x5,i25x100` — segments of one video ramp run: `i` = base rate,
  `b` = timed burst), a 500 ms time QR, a Gray-coded 60 Hz tick strip, sweep
  dial, AE patches and a constant-velocity ball. Every captured frame carries
  display-side time.
- **App side**: `App/TestCardRig.swift` + a sparse preview tap in
  `CameraController`. With the capture screen idle in **Video** mode, the rig
  locks when it decodes the session QR *and* sees the card's clock advance,
  shows a 3 s countdown chip (tap cancels), runs the script through the real
  ramp engine (`startRecording(.ramp)` + timed bursts), and stops itself.
  `LL_TESTRIG=chip` freezes a demo chip for design screenshots.
- **Analyzer**: `LetsLapse/tools/testcard_report.py report <clip>` → per-frame
  card timestamps, per-segment fps, ramp-switch gap events, AE stability.
  Needs the `tools/.venv` (numpy + opencv-python-headless) and
  `cv2.QRCodeDetectorAruco` — the plain OpenCV detector fails ~25% of mask-7
  QRs; Apple Vision on the phone is unaffected.
- **This ships in the normal build BY DECISION** (Steven: testing must be easy
  and no-fuss — do not move it behind a DEBUG gate). The guard rails are
  behavioural: arming requires the live card (advancing clock, so a photo of
  a card never arms), the countdown is visible and cancellable, and finished
  runs cool down 20 s before re-arming.

## Capture alarms (logs and reports only — Steven, 2026-09-26)

After the 18 Pro shot Photo at 1920×1080 for a week under a 4224×3024 menu (a
format miss that returned without a word — `LetsLapse/docs/fieldtests/2026-09-26-18pro-crash-triage.md`):
every Photo/Interval still is measured against the chosen size
(`checkDeliveredStill`), stills formats are checked before the shot, and each
camera set-up writes `Logs/stills-selftest-<model>.json` (lens sizes vs what the
stills camera can deliver). Anything wrong is an `ALARM <kind>:` console line
plus a `capture_alarm` session event — nothing on screen, by decision. Read
them with `python3 .claude/skills/letslapse/shoot.py audit --device <alias>`
(PASS/WARN/FAIL; FAIL on any ALARM or crash report). Run it after field
sessions and on any new device, iOS build or resolution. The size rules are
pure and tested (`Kit/…/StillsSizing.swift`, `StillsSizingTests`). Rule for
camera-configuration code: **no silent `return false` or empty `catch`** — log
the reason. Proof that the alarm rings: a DEBUG-hooks build with
`LL_STILLS_FAULT=1080p`.

**One lens per shoot, capabilities per lens (Steven, 2026-09-27 — nothing per
model).** Menus describe the stop's own physical lens; every Photo, Interval,
blend and Video run pins that lens for the whole shoot (a low-light hand-off
may never reframe a timelapse — only ISO and shutter move). A format is offered
only if it feeds the mode's outputs (photo + blend tap for stills, movie for
Video) by its own word — **never a sensor-data format** (`isSensorDataFormat`:
`kCVPixelFormatContainsSenselArray`; the 18 Pro's 4224×3024 is ProRes RAW, which
crashed Video and left Photo's connection dark) and never against
`unsupportedCaptureOutputClasses` — and, for stills, only if it reaches the
stop's zoom on that lens. The connection itself is asked before a run's first
frame; a proven refusal is learned per model + OS build in `FormatOutputLedger`.
A substitution is shown, never saved over the stored choice. **Bench trap:**
settings passed as launch arguments get re-saved into the real preferences by
the app's own menus — copy `Library/Preferences/com.regularsteven.letslapse.plist`
off the device before and after a bench run, and restore anything that moved.

## Strategy field-testing & the remote bench (holy grail)

The blend-strategy work (Zone / Latitude / Lumen behind BLEND=Auto) is
validated on real devices via a hands-free bench. Reports in
`LetsLapse/docs/fieldtests/`; program history in the "Holy Grail Field
Program" artifact. The loop:

1. **Build & deploy** (isolated DerivedData — the shared one can be broken
   by Xcode/MLX state):
   `xcodebuild -project LetsLapse/LetsLapse.xcodeproj -scheme LetsLapse
   -destination 'generic/platform=iOS' -configuration Release
   -derivedDataPath <scratch>/dd-device-release -allowProvisioningUpdates build`,
   then `xcrun devicectl device install app --device <udid> <.app>`.
   **Release is the field-test build** — it is what the Xcode scheme's Run
   action builds too (`LetsLapse.xcscheme`, since edf0370). Use
   `-configuration Debug` ONLY when a `#if DEBUG` lever is needed (`LL_*`
   hooks, `LL_STOP`, the scanner tuning arguments): a Debug build compiles
   the Kit `-Onone`, which made the live shape pass 10–20× slower and drove
   the camera to `pressure serious` on 2026-09-11 — never judge performance
   or heat from one.
2. **Launch + pairing code**: `xcrun devicectl device process launch
   --device <udid> --console --terminate-existing
   com.regularsteven.letslapse` — the capture screen opens itself and the
   remote listener prints `code=NNNNNN` on the console. Do NOT pass
   `LL_TAB`/hook env vars: any hook key suppresses the automatic
   camera-open (screenshot mode) and the listener never starts.
3. **Drive**: compile `LetsLapse/tools/remote_probe.swift` (with the **three**
   Shared sources it needs — `CaptureRemoteFrame`, `CaptureRemotePairing`,
   `WatchMessageKey`; its own header comment used to list two) and script runs:
   `./remote_probe <code>
   "setIntervalMode:holyGrail,setAutoInterval#1,setFramesPerBlend:auto,
   setBlendStrategy:zone,startRecording,poll@30xN,stopRecording"`.
   `setCaptureMode:interval` is refused (wrong token) — the interval-mode
   command already switches the tab. `setOutputFormat:jpeg|dng` (2026-09-21)
   is the still modes' Output picker — Interval/Photo, idle-only, DNG refused
   without Bayer RAW — so a JPEG × DNG matrix needs no hand on the phone.
4. **Pull evidence** (no export/import needed): `xcrun devicectl device
   copy from --device <udid> --domain-type appDataContainer
   --domain-identifier com.regularsteven.letslapse --source
   "Library/Application Support/LetsLapse/Logs" --destination <dir>` —
   the experiment logs record EVERY window including failed/starved tails
   that `capture_log.json` structurally omits. Analyze with
   `tools/blend_compare.py` and `tools/shoot_audit.py`.

**Hard rules learned on the bench:**

- **One control link at a time.** The listener holds a single peer and
  "replaces existing peer" on any new connection — concurrent probes (or a
  running LetsLapse **Mac app** holding a stale stored pairing) tear links
  down. Close the Mac app before bench sessions.
- Locked iPhones refuse `devicectl` launches — Auto-Lock → Never for the
  session. A device that advertises locally but never reaches the Mac's
  browse = Local Network permission or wrong Wi-Fi.
- LLog console timestamps re-anchor around 1000 s — it looks like an app
  restart and is not; verify with the probe link + file mtimes before
  believing a crash.
- Bench thermals are brutal by design (back-to-back runs → `serious`);
  a field run's cool start behaves far better. Let devices cool before a
  real shoot.

**Planned next bench (Steven):** a ~2-hour constrained daylight→sunset→
darkness run driven from this monitor setup, reviewed live as it happens —
consoles + monitors on the ramp/governor lines, periodic USB pulls mid-run.
The monitor test card (above) is the candidate controlled light source: it
can script a brightness ramp, which would make the light curve itself
repeatable. Design the observation plan before the run, not during.

**Bench addenda (2026-08-22):**
- Pairing codes are minted in `CaptureRemoteListener.start()`, which is a
  no-op while a listener exists — so a code rotates when the CAPTURE SCREEN
  tears down and comes back, **not** when a link dies. `dropPeer` keeps the
  listener and the code (verified 2026-08-22; the earlier note here had the
  cause wrong). Practically: re-harvest `code=` after any relaunch or any
  screen exit, but one code stays good for many connections across a single
  shoot — which is what lets a fleet run re-visit each device mid-run.
- `remote_probe` scripted mode exits after its script (fixed); interactive
  modes still hold the link. For simultaneous multi-camera starts use
  `scheduleStart#<epoch>` — each device fires its own shutter on its own
  clock (measured 124 ms apart across two iPhones).
- Stops are now device-owned: the probe's script grammar parses
  `cmd:extra#value` (fixed 2026-08-22), so `scheduleStop:minutes#60` is
  sendable. It is anchored to the device's own `captureRunStartedAt`, so
  sending it mid-run still stops that arm exactly N minutes after IT started
  — no link needs to stay open for a multi-hour shoot. It also requires
  `isCapturing`, which makes the stop pass double as the start check.
- Fleet shoots: `shoot.py fleet --arm <alias>:<strategy> … --duration 60m
  --at sunset-30m` runs the whole choreography (launch, arm, fire, confirm,
  collect) across several devices. Registry in
  `.claude/skills/letslapse/devices.json`.
- **iPad bracket trap (fixed 2026-08-22, worth remembering):**
  `AVCaptureDevice.currentExposureDuration` / `currentISO` — the sentinels
  that are supposed to resolve on-device at capture time — do NOT resolve to
  the device's custom exposure inside an
  `AVCaptureManualExposureBracketedStillImageSettings` on iPad. Both iPads
  shot whole runs at the exposure the run opened with while the ramp
  commanded a full walk; both iPhones resolved them correctly, which is why
  the 2026-08-20 actuation fix verified clean and this survived under it.
  Ramped brackets now carry explicit values, re-clamped to the live
  `activeFormat` on every call (an out-of-range manual bracket raises an
  *uncatchable* NSException, so the clamp is not optional).
  **The isolation trick generalises:** run the same device at blend depth 1,
  which routes through `fireCapture` with plain `AVCapturePhotoSettings` and
  no bracket settings at all. If exposure tracks there and pins on `auto`,
  the bracket is the culprit and the device write is fine.
- The listener stands down during project registration after a stop — an
  empty browse right after a run is saving, not a crash.
- Flicker quality gate: export the project's blend clip at NO depth, pull
  its `capture_log.json`, run `tools/flicker_report.py <clip> <log>` —
  attributes every visible luma step to what the engine changed at that
  frame; greppable FLICKER PASS/FAIL verdict.
