# LetsLapse — Data Model Audit & Recommendation

**Date:** 2026-09-06 · **Branch:** `ios-app` at 6c3a997 plus the uncommitted working tree · **Type:** investigation report, no implementation · **Brief:** "Data Model Audit & Recommendation Brief" (2026-09-06)

Nothing was created, modified or deleted in any store. File references are relative to `LetsLapse/`; `file:line` numbers are from the working tree on the audit date.

**Part 2** (2026-09-12) — scale to 100k–1M projects, the IPTC/XMP metadata model, and the Lightroom catalogue migration — is in [data-model-scale-and-metadata-2026-09-12.md](data-model-scale-and-metadata-2026-09-12.md). It revises §6.2: the truth stays in per-project JSON, but the **index** becomes SQLite once the measurements there are taken into account. **Part 3** (2026-09-12) — the server as the source of truth, revisions, the change journal, asset hashes, presence tiers and the sync flows — is in [data-model-server-portability-2026-09-12.md](data-model-server-portability-2026-09-12.md); it changes two of §5.1's fixed constraints and says so.

---

## 0. Summary

The app persists **about 35 distinct kinds of file** (34 under the storage root or in project folders, plus the model stores outside it), **83 `UserDefaults` keys** (a few of them minted per lens), the system-held WatchConnectivity context, and nothing else: no keychain, no iCloud key-value store, no app group, no database. The brief's starting list of seven files was short by more than twenty. The ones that matter most and were missing from it: `source/frames.exposure` (a per-capture NDJSON sidecar written on every DNG run and read by nothing), `source/frames.whitebalance`, `source/sequence.json`, `CaptureLogs/capture-<uuid>.log` (the crash log), the global `Logs/` experiment logs, the Mac job-runner scratch folders that live **inside** project folders and travel with them, `overlays.json` with its `masks/` and `fonts/`, and the caches (`Thumbnails/`, `SceneMasks/`, `Collections/<id>/render.mp4`).

Findings that change the recommendation:

1. **Identity is already a UUID minted at registration, and it is stable on one device.** Project folder = `Projects/<CaptureProject.id>`. It is **not** stable across devices: every `.lapse` import and every network transfer mints a fresh id and records the origin in `importedFromID`, one hop only. A DNG-archive clone deliberately drops the link. On the Mac library, 75 of 103 projects are imports; none of their origin ids exist locally. A presence registry needs a device-independent id that survives transfer, and today there is none.
2. **`library.json` is one document that scales with total frame count.** On the Mac library (103 captures, 140 blends) it is 2.30 MB, and **92 % of that is `sourceFileNames`** (57,016 file-name strings). The largest single entry is 150 KB for a 5,661-frame shoot. The file is read once per launch and fully rewritten on every one of 35 mutation sites, including every grade-slider settle. Measured round trip on an M4 Max: 12 ms decode, 12 ms encode, 1–3 ms atomic write. It is not slow today; it is the shape that is wrong, not the engine.
3. **The hot path is already append-only where it counts, with two exceptions.** `frames.timestamps`, `frames.exposure` and the capture session log are NDJSON appended line by line. `capture_log.json` is written once at run end. The exceptions are the live-blend experiment log, a full atomic rewrite **after every output frame** (measured 276 KB for 239 outputs; at 5,000 outputs that is a 6–7 MB document rewritten 5,000 times, 14–19 GB of writes over one shoot on the blend queue itself), and `blend-profiles.json`, rewritten per Psycho window but bounded in size. And nothing recovers a crashed shoot: its frames and sidecar sit in `tmp/` where "Clear cache" deletes them.
4. **The manifest and the disk already disagree in the real library.** Three project folders are not in the manifest; one manifest entry lists 750 frames for an **empty** folder; seven blend renders on disk are unlisted; 77 `sourceFileNames` entries are `.json` sidecars misregistered as frames (a bug fixed on 2026-09-05 for new shoots, not for existing entries). There is no repair path: `loadLibrary()` has no folder scan, and a manifest that fails to decode is replaced by the next save with a manifest containing only the new entries.
5. **Two writers race on `library.json`.** `persistLibrary()` writes synchronously on the main actor; `persistLibraryOffMain()` writes later on a utility queue. There is no ordering between them, so a stale snapshot can land after a newer one. Each write is atomic; the last write is not guaranteed to be the newest.
6. **Every deletion removes files before it updates the manifest.** `deleteCapture`, `deleteBlend`, `deleteEncoding` all `removeItem` first and persist second.

**Recommendation in one line:** keep JSON files, do not add a database, and fix five specific things: split `library.json` into a small index plus per-project `project.json`, give every project an origin id that survives transfer, make the experiment log append-only, add a folder-scan reconciliation at launch, and serialise the manifest writers. Details in §5.

---

## 1. Method and evidence base

Three sources, cross-checked against each other:

1. **Code.** Every file-write API call site (`write(to:)`, `FileHandle`, `createFile`, `replaceItemAt`, `moveItem`), every `UserDefaults` / `@AppStorage` key, every `Codable` type reachable from a writer, across `App/`, `Shared/`, `Kit/Sources/`, `Watch/`, `Remote/`, and the Python analyzers in `tools/`.
2. **The Mac library on `/Volumes/letslapse`**, the nominated `StorageRoot` of the Debug build on this machine: 106 project folders, 431 GB, `library.json` 2,304,132 bytes holding 103 captures, 140 blends and 1 collection. Inspected read-only.
3. **The iPhone 16 Pro's app container**, copied read-only with `devicectl`: `library.json` (424 KB; 234 captures, 74 blends, 1 collection), the full 2,982-entry file listing, the `tmp/` listing, two orphaned capture logs and the preferences plist.

Where the disk and the code disagree, the disk is reported and the code cited. Where a claim could not be verified it is listed in §7.

Six read-only audit agents each covered one area (manifest lifecycle, manifest schema, capture hot path, per-project sidecars, global stores and defaults, transfer and concurrency). Their `file:line` citations were spot-checked; the two that were wrong (the frame-index origin of `frames.timestamps`, and whether the experiment log reaches the project folder) are corrected here from the disk evidence.

---

## 2. Inventory

Every store found. "Scope" is global (one per library), per-project (`Projects/<uuid>/`), or temp (`tmp/`, survives the process but not a cache clear). Sizes are measured where a real instance existed; "@5,660" means the 5,660-frame Holy Grail DNG shoot `BB6CBBE2` on the Mac library.

### 2.1 Library root (`StorageRoot.current`)

`~/Library/Application Support/LetsLapse` by default; on macOS relocatable via the `storage.libraryRootPath` default (`App/StorageLocation.swift:19`). A new top-level item must be added to `StorageRoot.libraryItemNames` (`StorageLocation.swift:35-39`) or a macOS library move leaves it behind.

| # | Path | Scope | Produced by | Format | Size / scaling | When | Write pattern | Readers |
|---|---|---|---|---|---|---|---|---|
| 1 | `Projects/library.json` | global | every project, blend and collection mutation (35 sites) | strict JSON, pretty-printed, sorted keys, dates as seconds-since-2001 | 2.30 MB Mac (103 captures), 424 KB iPhone (234). Scales with **total frames**: ~26 B per source file name; 92 % of the Mac file | finalise / user action / launch migrations | full rewrite, `.atomic`; main actor (`AppModel.swift:7541-7555`) or off-main serial queue for grade edits (`:9077-9093`) | `loadLibrary()` once per launch (`:7467`); `StorageRoot.check` probes existence |
| 2 | `Projects/<captureUUID>/` | per-project | registration | folder | 431 GB / 106 folders on the Mac | finalise | `createDirectory` + copy | everything below |
| 3 | `Projects/.dng-archive-<uuid>/` | temp sibling | Duplicate as DNG archive | folder | one project's worth | user action | built then `moveItem` to `Projects/<uuid>` (`:7246`) | none; swept only at the start of the next archive run (`:7271`), not at launch |
| 4 | `blend-profiles.json` | global | **every completed Psycho (unthrottled) window**, both blend pipelines (`App/LiveBlendController.swift:1134-1141`, `LiveBlendRawController.swift:1113-1120`) | JSON (`BlendLearningTable`; a struct-keyed dictionary, so it encodes as a flat alternating `[key, value, …]` array), ISO-8601 | 5 KB Mac, 50 KB iPhone; ≤ 40 samples per device × pipeline × thermal bucket × interval | **hot path** | full rewrite `.atomic` **per window** from the blend queue (`App/BlendProfileStore.swift:45-62, 135-153`); corrupt file → empty table, silently, left in place | `throttledFrameTarget` at every Safe window open, Settings |
| 5 | `custom_presets.json` | global | saving a named grade | JSON array of `CustomPreset` | ~5 KB | user action | full rewrite `.atomic` (`App/CustomPreset.swift:112`); corrupt file → empty, `lastError` surfaced | preset strip, `stampPresetStatesIfNeeded` |
| 6 | `light_ladders.json` | global | Light Ladder editor (user ladders only; built-ins are code) | JSON array of `LightLadder` | 1.3 KB | user action | full rewrite `.atomic` (`App/LightLadderStore.swift:153`) | ladder picker, capture |
| 7 | `Thumbnails/<sha256>.jpg` | global cache | first display of any asset | JPEG q0.75 | 55 MB / 943 files Mac; 14 MB / 243 iPhone; one per asset ever shown | on demand | best-effort, **not atomic** (`App/ProjectThumbnailCache.swift:278-289`) | tile grids, transfer picker |
| 8 | `SceneMasks/<sha256>.png` | global cache | AI sky/land segmentation | PNG | 1 MB / 247 files | on demand | `CGImageDestination`, not atomic | overlay placement |
| 9 | `Collections/<collectionUUID>/render.mp4` | global | collection export | media | 135 MB Mac | user action | written by `AVAssetExportSession`, recipe recorded in `library.json` | `CollectionDetailView`, re-export gate |
| 10 | `CaptureLogs/capture-<uuid>.log` | global | **every** camera session, all modes | NDJSON, one event per line (not per frame) | 331 B – 2 KB each; 12 orphans Mac, 32 iPhone | **hot path** | `FileHandle` append per event on a serial queue (`App/CaptureSessionLogger.swift:229-244`); deleted on normal end | Settings ▸ Incomplete Captures only |
| 11 | `Logs/console-<launch>.log` | global | every launch | text | ≤ 8 MB each, last 12 kept (`App/CameraController.swift:42-43`) | continuous | append on a serial queue | humans, `tools/` |
| 12 | `Logs/liveblend-<stamp>.json` | global | every Interval run with a blend engine (JPEG and DNG paths) | JSON (`LiveBlendSessionLog`) | 0.7 KB – 418 KB; **277 files / 39 MB on the iPhone, never pruned** | **hot path** | **full `.atomic` rewrite after every output** (`App/LiveBlendController.swift:1132`, `LiveBlendRawController.swift:1111`) | `tools/blend_compare.py`, humans |
| 13 | `Logs/ladder-<stamp>.jsonl` | global | Light Ladder runs | JSONL | small | hot path | append (`App/LightLadderRun.swift:58-111`) | `tools/ramp_audit.py` |
| 14 | `Incoming/<sourceProjectUUID>/…` + `<file>.part` | global staging | network transfer pull | tree | one project | during transfer | file-by-file, `.part` renamed on completion; installed by **rename** into `Projects/` (`AppModel.swift:8724-8760`) | `commitIncoming`; swept after 24 h at launch (`:8774`) |
| 15 | `<Application Support>/Models/<catalogID>/models--<org>--<repo>/{snapshots,blobs}` | **outside the library root** | model download (`App/AI/ModelManager.swift:347-373`) | Hub layout: `config.json`, `.safetensors` or `.mlpackage` | GB (3.3 GB download in the iPhone's `tmp/` today) | user action | file by file, resumable, `isExcludedFromBackup` | `ModelManager`, `SceneAnalyser` |
| 15a | `<Caches>/SegmentationModels/<identity>.mlmodelc` | outside the root | Core ML compile | compiled model | MB | first use | staged through `tmp/SegModelStaging-<uuid>` | `CoreMLSceneSegmenter` |

### 2.2 Per-project files (`Projects/<uuid>/`)

Frequency = how many of the 106 Mac folders / 234 iPhone folders hold one.

| # | Path | Produced by (condition) | Format | Size / scaling | When | Write pattern | Readers | Mac / iPhone freq |
|---|---|---|---|---|---|---|---|---|
| 16 | `source/<media>` | all | media | — | finalise | copy from `tmp/` staging | via `sourceFileNames` | 106 / 234 |
| 17 | `source/sequence.json` | video **ramp** and **marker** shoots only | JSON, ISO-8601 dates, atomic | ~1.7 KB, per segment | finalise (`CameraController.swift:5494-5500`) | written once, never edited; also **listed in `sourceFileNames`** | `source(for:)` strict decode (`AppModel.swift:7448`), summaries, FLAT pill, `refreshVideoMetadata` | 15 / 44 |
| 18 | `source/frames.timestamps` | Interval (plain, Holy Grail, Ladder, Scanner), both live-blend engines, stills import | NDJSON, ISO-8601 fractional | ~112 B/line; 634 KB @5,660 | **hot path**, per frame | `FileHandle` append, no fsync, session-queue confined (`Kit/…/FrameTimestamps.swift:241-265`); edits via temp dir + `replaceItemAt` | `ImageStacker`, stills axis, viewer strip, scanner, framing span, WB seconds, `tools/ramp_audit.py`, `fleet_report.py` | 72 / 6 |
| 19 | `source/frames.exposure` | **DNG live-blend path only** (`LiveBlendRawController.swift:354`) and stills import | NDJSON | ~180 B/line; 1.03 MB @5,660 | hot path, per capture | append | **none in the app or tools** — one Kit test reads it | 37 / 2 |
| 20 | `source/capture_log.json` | both live-blend engines at run end; stills import | JSON, pretty, atomic | ~630 B/frame; **3.57 MB @5,660**, single document | **finalise only** (`LiveBlendController.swift:1329`, `Raw:1525`) | one atomic write; failure returns nil silently | app: FLAT pill only (`AppModel.swift:3939`); `tools/`: 7 scripts | 73 / 6 |
| 21 | `source/frames.whitebalance` | user "measure white balance" on raw projects; `lapse whitebalance` CLI | NDJSON | ~100 B/line; 48 KB @483 | user action | whole file, `atomically: true` | `whiteBalanceSeries(for:)` for `.smoothed` WB | 2 / 0 |
| 22 | `source/framing.json` | "Review photos"; commit/withdraw of the lock; `lapse framing` CLI | JSON, ISO-8601, atomic, `version: 1` | ~150 B/frame; **865 KB @5,660** | user action, background task | `.atomic` (`Kit/…/FramingReview.swift:371`) | `loadFramingLock`, Adjust toggle, detail rows | 6 / 2 |
| 23 | `source/liveblend-<stamp>.json` | copy of #12 parked beside the frames at run end since 2026-09-05 (`CaptureView.swift:1080-1088`) | JSON | 160–276 KB | finalise | copy | none (provenance) | 3 / 5 |
| 24 | `source/frame-NNNNN.json` | **the same log, misregistered as a frame** before the 2026-09-05 fix; still listed in `sourceFileNames` | JSON | 60–150 KB | — | — | filtered out by `.hasSuffix(".json")` at 13 sites | 49 / 10 |
| 25 | `source/documents.json` | Scanner runs with ≥ 2 documents | JSON atomic | small | user action | rewritten; **deleted** when ≤ 1 document | `scanDocuments(for:)` | 0 / 0 |
| 26 | `source/frame-NNNNN-corrected.heic` | Scanner perspective correction | HEIC | per page | user action | `writeHEIFRepresentation`, not atomic, overwritten on re-correct | scanner viewer | — |
| 27 | `source/<base>-<codec>.mp4` | per-clip encodings | media | per clip | user action | AVAssetWriter | via `clipEncodings` | iPhone: 1 project |
| 28 | `source/<clip>.letslapse/{manifest.json, logs/job.log, frames/, passes/, output/}` | **macOS constant-window blends** — the job folder is created beside the input (`App/MacVideoJobRunner.swift:281`), which is inside the project | JSON + text + PNG scratch | job manifest ~800 B with **absolute paths**; `passes/*.png` and `output/*.mp4` persist; `frames/` can be GB during a run | during blend | manifest atomic at each status change, log appended per line | `MacVideoJobRunner` resume. **Never deleted** (no `removeItem` on a `.letslapse` folder anywhere), and because it sits in `source/` it is **sent over the network and kept by every `.lapse` install** | 7 folders / 0 |
| 29 | `blends/<blendUUID>.mp4\|png` | every blend | media | — | finalise | remove-then-copy, **not atomic** (`AppModel.swift:7655-7660`) | `blendOutputURL` | 64 iPhone |
| 30 | `notes/notes.json` + `notes/<uuid>.m4a` | Field Notes | JSON array, ISO-8601, atomic; AAC audio | small | user action | rewrite; torn manifest reads as empty and the next add **overwrites it with one note** | `ProjectDetailView` | 5 / 0 |
| 31 | `overlays.json` + `masks/<uuid>.png` + `fonts/*` | text overlays | JSON with one-letter keys, atomic; PNG; font files | 2–3 KB | user action | rewrite; **file deleted** at zero layers | viewer, export bake | 13 / 1 |
| 32 | `dng-archive.json` | Duplicate as DNG archive | JSON via `JSONSerialization`, **not atomic** (`AppModel.swift:7243`) | 85–299 KB, per frame | finalise | one write inside staging | only the `LL_DNGARCHIVE` hook | 4 / 6 |
| 33 | `project.json` | **transient**: written into the live project folder during `.lapse` export, deleted by `defer` (`AppModel.swift:8342-8344`) | JSON, ISO-8601 | 2–150 KB | user action | atomic | the installer, from staging | 0 / 0 |
| 34 | `.<movie>.gps-backup` | `MovieLocation.inject` header rewrite | clone | — | finalise | APFS clone, restored on failure | — | 0 |

**Documented but not real:** the overview's tree (`docs/letslapse-app-overview.md` §4.13) shows `source/<clip>.gpx`. The GPX track is written beside the **staging** movie (`CaptureView.swift:1000-1008`) and is never copied into the project; `AppModel` has no reference to `.gpx`. Zero `.gpx` files exist in either library. The single-pin location survives in the movie header; the track does not.

### 2.3 Temporary directory (`tmp/`) — survives the process, invisible to the storage card

Not stores in the brief's sense, but they hold shoot data between capture and registration and are the cause of the open storage-accounting job (`docs/storage-accounting-job.md`). On the iPhone today: **9.7 GB** — a 3.3 GB `CFNetworkDownload_*` model download, share archives named after projects (~2.2 GB), sixteen `LetsLapse-<uuid>.mp4` render temps (~1.2 GB). Prefixes the app itself creates and `clearCache()` recognises (`AppModel.swift:4147-4162`): `live-capture-`, `interval-`, `scanner-`, `liveblend-`, `liveblend-dng-`, `import-`, `lapse-import-`, `picked-`, `LetsLapse-`, `.letslapse`. Not recognised: `CFNetworkDownload_*`, `scene-analysis/`, share archives, `fieldnote-*.m4a`, `timeslice-spool-*.bin`, `benchmark-*.dng`, `probe-*.dng`.

### 2.4 Other stores

| Store | What | Evidence |
|---|---|---|
| `UserDefaults.standard` | 83 keys (a few minted per lens) across `letslapse.*`, `letslapse.capture.*`, `captureSettings.*` (lens-scoped, dynamic key names), `capture.*`, `layout.*`, `scanner.*`, `transfer.*`, `remote.*`, `storage.*`, `projects.*`, `gallery.*`, `ai.*`, `rawDecodePath`, `scheduledRecording`. Full table in Appendix B. | plists read from both machines |
| Large blobs inside `UserDefaults` | `letslapse.deviceCapabilityMatrix.v2` (JSON `Data`, **411 KB on the iPhone**, 32 KB on the Mac); `scheduledRecording` (JSON `Data`); `letslapse.capture.costBytes` (dictionary); `transfer.rememberedCodes` (dictionary of device id → six-digit pairing code, **plain text**) | `App/DeviceCapabilityMatrix.swift:205-230`, `App/ScheduledRecording.swift:40`, `App/CaptureHeadroom.swift:129`, `Shared/ProjectTransferClient.swift:831` |
| Two preference domains on the Mac | The Debug build is not sandboxed (`App/LetsLapse.entitlements`: `app-sandbox` = false) and reads `~/Library/Preferences/com.regularsteven.letslapse.plist`; a sandboxed build reads the container plist, which today holds only two keys. The custom `storage.libraryRootPath` set by one is invisible to the other. | both plists inspected |
| Keychain, `NSUbiquitousKeyValueStore`, app groups, Core Data, SwiftData, SQLite | **none** | grep of all sources; `PrivacyInfo.xcprivacy` declares only `UserDefaults` (CA92.1) |
| `WCSession` application context | The phone pushes the capture state dictionary (`App/WatchRemoteControlReceiver.swift:658`); watchOS persists the last received context on disk and hands it back on launch (`Shared/WatchConnectivityTransport.swift:34,81`). Implicit store, system-owned. | code |
| watchOS `UserDefaults` | one key: `letslapse.watch.burstDefaultSeconds` (`Remote/WatchControlView.swift:48`) | code |
| AI models | Weights at `<Application Support>/Models/…` — **not under `StorageRoot`**, so on the unsandboxed Mac build that is the unbranded `~/Library/Application Support/Models`, which any other app could also pick (`App/AI/ModelManager.swift:347-357`); compiled Core ML at `<Caches>/SegmentationModels/`; `~/.cache/huggingface` is a **read-only** fallback lookup (`App/AI/SceneAnalyser.swift:214-229`). `isExcludedFromBackup` re-applied on every access. A macOS library move leaves ~3.5 GB of weights on the boot volume by design (re-downloadable). Active model id in `ai.activeModelID`. | code; the Mac volume root has none of these folders, which is consistent |
| Photos library | exports only (`PHPhotoLibrary`, 12 sites in `AppModel`); not a store the app reads back | code |

---

## 3. Schema appendix

The on-disk keys as current code writes them, not the Swift names. Legacy shapes that are still decoded are listed with each store.

### 3.1 `Projects/library.json`

Encoder: `JSONEncoder` with `.prettyPrinted, .sortedKeys`; **no** date strategy (dates are `Double` seconds since 2001-01-01, e.g. `810405132` = 2026-09-06T16:32Z); UUIDs as uppercase strings; `null` is never written (optionals are omitted). Decoder: bare `JSONDecoder`. The only version marker is `gradingSchemaVersion`, which versions two one-shot migrations, not the format. Any decode error anywhere in the tree fails the **whole** library (`AppModel.swift:7472-7501`).

Root (`LibraryManifest`, `AppModel.swift:538-546`):

| Key | Type | Required | Notes |
|---|---|---|---|
| `captures` | array of CaptureProject | yes | Swift default `= []` does not relax the requirement |
| `blends` | array of BlendProject | yes | |
| `collections` | array of LapseCollection | no (pre-Collections files) | always written now |
| `gradingSchemaVersion` | int | no → 0 | 1 = "Natural" stamp, 2 = presetState stamp; written as `max(v,1)` |

**`captures[]` — `CaptureProject`** (`AppModel.swift:108-279`, synthesized). Frequency columns are how many entries carry the key in the Mac (103) and iPhone (234) manifests.

| Key | Type | Req. | Written by / condition | Mac | iPhone |
|---|---|---|---|---|---|
| `id` | UUID string | yes | `UUID()` at registration (`:6607`, `:6764`, `:6928`, `:7174`, `:7314`, `:8576`) | 103 | 234 |
| `kind` | `"video"` \| `"photos"` | yes | strict enum | 103 | 234 |
| `createdAt` | seconds-since-2001 | yes | `Date()` or the shoot's own start | 103 | 234 |
| `originalName` | string | yes | file name, `"<n> photos"`, `"Ramp capture"` | 103 | 234 |
| `mode` | free string | yes | display + routing (`"Interval · DNG"`, `"Photo"`, `"Ramp capture · 2 ramp intervals …"`, live format description) | 103 | 234 |
| `sourceFileNames` | array of `"source/…"` strings | yes | frames, or clip(s) **plus `source/sequence.json`** for ramp shoots; pre-2026-09-05 also the renamed experiment log | 103 | 234 |
| `presetState` | object `{kind, id?, snapshot?}` | no, but stamped on every persist | `kind` ∈ original/named/edited; `snapshot` = `{name, basePreset, adjustments, isBuiltIn}` | 103 | 234 |
| `sourceWidth`, `sourceHeight` | int | no | probes, import, clone; swapped by Rotate 90° | 102 | 234 |
| `sourceDurationSeconds` | double | no | video probe; stills span when a clock exists | 85 | 53 |
| `selectedPreset` | preset raw string | no | grade write; migration v1 stamps `"Natural"` | 82 | 230 |
| `importedFromID` | UUID string | no | `.lapse` / transfer install only; **cleared** on DNG clone | 75 | 1 |
| `sceneTags`, `sceneElements` | array of string | no | AI tagging (Vision at capture, Gemma on request) | 72 | 8 |
| `sceneTaggedAutomatically` | bool | no | silent capture-time pass; never written `false` | 70 | 3 |
| `adjustments` | PhotoAdjustments (below) | no | grade write | 60 | 29 |
| `name` | string | no | rename / AI rename | 48 | 22 |
| `sourceFPS` | double | no | video probe | 15 | 47 |
| `sourceSegmentSeconds`, `sourceSegmentFPS` | `{ "<segment file>": number }` | no | video probe, merged never replaced | 15 | 47 |
| `sourceSegmentSize` | `{ "<segment file>": "WxH" }` | no | video probe — **written but never read** | 2 | 1 |
| `gradeTimeline` | `{ "k": [keyframes], "a"?: double }` | no | only when non-empty; keyframe = `{id, position, adjustments}` | 14 | 1 |
| `nominatedBadFrameNames` | array of bare file names | no | bad-frame nomination | 4 | 0 |
| `burstRampDuration` | double | no | ramp-shoot editor; 0 = hard cuts | 2 | 7 |
| `clipEncodings` | `{ "<clip rel path>": [{codec, fileName}] }` | no | codec conversion | 0 | 1 |
| `whiteBalanceSource` | `{"fixed":{kelvin,tint}}` \| `{"smoothed":{anchorPosition}}` | no | `.asShot` is stored as absent; strict enum | 0 | 0 |
| `modifiedAt` | seconds | no | human edits only | — | — |
| `sizeBytes`, `sizeMeasuredAt` | int64, seconds | no | size sort | — | — |
| `captureMode` | `"scanner"` | no | Scanner registrations since 2026-08-16 only; older scanner projects rely on the mode string and the sidecar heuristic | 0 | 0 |
| `scannerPaper` | aspect raw | no | Scanner | 0 | 0 |
| `hideBadFrames` | bool | no | | 0 | 0 |

**`adjustments` — `PhotoAdjustments`** (`App/PhotoAdjustments.swift`, custom Codable, `v: 2`): 20 `Float` fields always written (`exposure contrast highlights shadows whites blacks temperature tint vibrance saturation clarity texture sharpen sharpenMasking noiseReduction noiseDetail colorNoiseReduction colorNoise vignetteIntensity` + `v`); `rotation` only when non-zero; `whiteMired`/`whiteTint` only when the white is owned (added 2026-09-06, uncommitted). Decode is tolerant field by field. **Legacy v1** (no `v`): `whiteBalance` string (`"As Shot"`, `"Sunny"`, …) is mapped to a mired offset on read and never written.

**`blends[]` — `BlendProject`** (`AppModel.swift:401-455`).

| Key | Type | Req. | Notes | Mac | iPhone |
|---|---|---|---|---|---|
| `id`, `captureID` | UUID strings | yes | blend ids are re-minted on import | 140 | 74 |
| `kind` | `"video"` \| `"image"` | yes | | 140 | 74 |
| `createdAt` | seconds | yes | | 140 | 74 |
| `outputFileName` | `"blends/<uuid>.mp4\|png"` | yes | relative to the project folder | 140 | 74 |
| `summary` | string | yes | renderer text | 140 | 74 |
| `linearLight`, `useRamp` | bool | yes | | 140 | 74 |
| `rampStart`, `rampEnd` | int | yes | written even when `useRamp` is false | 140 | 74 |
| `curve` | string | yes | tolerant on read | 140 | 74 |
| `compressionRatio`, `outputFPS`, `width`, `height`, `inputFrames`, `outputFrames` | int | no | result stats, never re-probed | 140 | 74 |
| `warp` | `{bounds:[], speeds:[], seams:[{ramp}]}` | no | strict `ramp` enum; legacy `side` key ignored | 107 | 12 |
| `timeSlice` | `{newestEdge, segments, offsetFrames, featherPixels, distribution, output, includeRegularClip, grid?, variation?}` | no | tolerant decode; `variation.seed` is a **UInt64** | 37 | 0 |
| `canvasRatio`, `canvasOffset` | string, double | no | | 11 / 10 | 4 / 3 |
| `reframe` | `{keys:[{id,t,z,cx,cy}], moves:[{span,curve}]}` | no | all keys required, strict enums | 5 | 4 |
| `defaultCrops` | `{ "<ratio>": double }` | no | | 0 | 7 |
| `trimHeadTailSeconds`, `sourceCodec` | double, string | no | | — | — |
| `stretchWindows` | array of int | no | **decode-only legacy** (2026-08-03 ruler); converted to `warp` on re-edit, never written | 0 | 0 |

**`collections[]` — `LapseCollection`** (`App/CollectionsModel.swift:49-242`): `id`, `name`, `createdAt`, `entries[]` required; `ratioRaw`, `lastExport {fileName, exportedAt, recipe}`, `kenBurns {enabled, consistentDurations, clipSeconds, autoAdjustSpeed, fadeTransition, custom?, lastCustom?}` optional. `entries[]` = `{blendID, inPoint, outPoint, crops{ratio: offset}, kenBurns?{start{zoom,centerX,centerY}, end{…}, isCustom}}`; a malformed `kenBurns` is dropped rather than failing the file.

**Strict decode points that fail the whole library:** any missing required key above; unknown raw values in `kind`, `presetState.kind`, `presetState.snapshot.basePreset`, `warp.seams[].ramp`, `reframe.moves[].span|curve`, the `whiteBalanceSource` case key; the five core `kenBurns` fields; a non-numeric date. Lenient: `adjustments`, `timeSlice`, `entries[].kenBurns`, `kenBurns.custom/lastCustom`.

**Field history** (first commit): `library.json` 2026-07-19 · `clipEncodings` 07-21 · `rotation` 07-29 · `burstRampDuration` 07-31 · `defaultCrops` 08-01 · `stretchWindows` 08-03 · `sceneTags` 08-05 · `canvasOffset` 08-12 · `importedFromID`, `sourceSegmentFPS` 08-13 · `gradingSchemaVersion`, `LegacyWhiteBalance` 08-15 · `captureMode` 08-16 · `presetState`, `gradeTimeline` 08-18 · `nominatedBadFrameNames` 08-27 · `timeSlice`, `kenBurns` 08-28 · `framingLock` 09-03 · `whiteMired` 09-06 (uncommitted). Seven weeks, nineteen additive changes, one format-version field that does not version the format.

### 3.2 `source/sequence.json` (`App/LiveCaptureSequence.swift:3-116`)

ISO-8601 dates, atomic, written once. `mode` (`"ramp"` \| `"marker"`), `createdAt`, `lockedResolution{width,height}`, `baseFrameRate`, `rampFrameRate?`, `segments[{index, fileName, frameRate, relativeStart, relativeEnd, recordedStart?, recordedDuration?, measuredFrameRate?, steadyFrameRate?, settleSeconds?, resolution?{width,height}}]`, `markers[]`, `rampIntervals[{index, relativeStart, relativeEnd}]`, `markIntervals[]`, `captureFlat?`, `appleLog?`. Segments are identified by `fileName`; `library.json`'s `sourceSegment*` maps are keyed by the same names and win on conflict.

### 3.3 `source/frames.timestamps` (`Kit/Sources/LetsLapseKit/FrameTimestamps.swift`)

One object per line, sorted keys, ISO-8601 with fractional seconds: `{"captureTime", "ev"?, "frame", "iso", "rectangle"?, "shutter"}`. `rectangle` (Scanner) is `NormalizedQuad` and is **absent, not null**, for frames with nothing in view; its presence on any line is the legacy signal that a project is a scanner set. Position in the file is the authoritative order; `frame` is for humans. **The origin of `frame` depends on the writer**: the plain-interval, both live-blend and the import writers use `count − 1` (0-based); the Holy Grail writer passes its own counter and the Scanner writer passes the pose index. On disk, the 5,660-line Holy Grail sidecar starts at `frame: 1` while the same shoot's `frames.exposure` starts at `frameIndex: 0` and its `capture_log.json` at `frameIndex: 1`. Since 2026-09-05 `shutter`/`iso` are the **delivered** pair; before that, ramped runs recorded the commanded pair. Decode skips blank and torn lines. Edits (`deleteEntry`, `dropTrailingEntries`) rewrite through a `frames.timestamps.rewrite/` directory and `replaceItemAt`, keeping frame numbers (gaps are deliberate).

### 3.4 `source/frames.exposure` (`Kit/…/CaptureExposureLog.swift:247-267`, writer `:493-524`)

One `Entry` per line: `{"aperture"?, "capturedAt", "ev"?, "exposureDuration"?, "frameIndex", "iso"?}`; at blend depth > 1 there are more lines than frames on disk. Written by the DNG live-blend path and the stills importer. **No reader** in the app, the CLI or `tools/`; one Kit test decodes it.

### 3.5 `source/capture_log.json` (`Kit/…/CaptureExposureLog.swift:318-361`)

Pretty-printed, sorted keys, ISO-8601, no version field. Root: `sessionID` (a fresh UUID per run — **not** the project id; on import it is the project id), `deviceModel`, `captureMode` (`"interval"` \| `"dynamic"` \| import), `blendMode`, `algorithm?`, `algorithmVersion?`, `captureFlat?`, `cameraName?`, `captureWidth?`, `captureHeight?`, `intervalSeconds?`, `endReason?`, `failedWindows?`, `starvedWindows?`, `rampDriving?`, `rampRefusals?`, `startedAt?`, `endedAt?`, `frames: [Entry]`, `issues: [{kind, …}]?`. Each frame `Entry` adds `blendCount`, `strategy?` (`BlendStrategyDecision`), `window` (`WindowPerformance`: `fileBytes, intervalSeconds, processingMillis, requestedFrames, systemPressureAtClose, thermalStateAtClose, thermalStateAtStart, …`), `ramp?` (`RampState`). On disk the first frame entry is ~330 bytes; with `ramp` and `strategy` ~630 bytes. The `frames` array is the whole run: 5,660 entries, 3.57 MB.

Details that matter for a merge: `sessionID` is `UUID()` defaulted in each controller's configuration (`LiveBlendController.swift:325`, `LiveBlendRawController.swift:72`) — a fresh id per run, never surfaced elsewhere. `frameIndex` is 1-based on both blend paths (`LBC:1084`, `LBR:1065`). The JPEG path hard-codes `algorithm: "zone"` regardless of the Settings strategy (`LBC:1308-1311`); the DNG path never sets `captureFlat` (`LBR:1499`). `issues[].kind` values actually written: `thermal`, `framingGlitch`, `framingChanged`, `tooHot` (JPEG path only), `ramp`, `ladder`, `constituentSwitch`, `systemPressure`. Fields written that no reader (app, CLI or `tools/`) touches: `captureFlat` beyond the FLAT pill, `aperture`, entry-level `ev`, `divergenceReference`, `window.systemPressureAtClose`, `window.intervalSeconds`, `ramp.aimEV`, `ramp.aeGapEV`, `ramp.applyOutcome`, `ramp.rung`.

### 3.6 `Logs/liveblend-<stamp>.json` and its in-project copy (`App/LiveBlendController.swift:104-200`)

`{header, outputs[], summary}`. `header`: `appVersion, blendDepth, bracketMaxFrames?, bracketedRAW?, burstScheduling?, cameraName, captureHeight, captureWidth, configuredFrameRate, deviceModel, osVersion, outputFormat, requestedFramesPerBlend, requestedIntervalSeconds, requestedOutputFormat, responsiveCapture?, startedAt`. Each output: `index, windowStartSeconds, windowEndSeconds, requestedFrames, capturedFrames, frameTimesSeconds[], frameSpacing{Avg,Min,Max}Seconds?, actualIntervalSeconds?, blendMillis?, encodeMillis?, totalMillis, fileBytes, memoryFootprintBytes, thermalState, thermalStateAtStart, systemPressureAtClose, droppedByCamera, droppedProcessingBehind, missedRateLimited, frameFailures, failed, partial, fallbackSingleFrame, starvedBackpressure`. `summary`: `requestedOutputs, completedOutputs, failedOutputs, fallbackOutputs, skippedWindows, captureDurationSeconds, peakProcessingSeconds, peakMemoryFootprintBytes, finalThermalState, endedAt, discarded`. Rewritten whole after every output.

### 3.7 `source/framing.json` (`Kit/…/FramingReview.swift:98-117`)

`version: 1` (never checked), `reviewedAt`, `width`, `height`, `measurementScale`, `captureSpanSeconds?`, `frames[{name, dx, dy, confidence}]` (identified by **file name**), `events[{firstIndex, lastIndex, firstName, lastName, peakPixels, summary}]`, `driftX`, `driftY`, `verdict` (`recommended` \| `steady` \| `inconclusive`), `summary` (human sentence, stored), `plan{mode, referenceX, referenceY, insetX, insetY, cropFraction, summary}`, `stabilisation?{appliedAt, reviewedAt, mode, referenceX, referenceY, insetX, insetY, cropFraction}`. The measurement is rebuildable (minutes); the `stabilisation` block is **user intent** and is not.

### 3.8 `source/frames.whitebalance` (`Kit/…/WhiteBalance.swift:36-76`)

NDJSON: `{"file", "frame", "kelvin", "seconds", "tint"}`, one line per **usable raw** frame (non-raw frames are omitted). Identified by file name. Rebuildable from the raw frames.

### 3.9 `dng-archive.json` (`AppModel.swift:7224-7243`)

`{sourceProjectID, strategy, convertedAt, frames, inputBytes, outputBytes, elapsedSeconds, framesPerSecond, perFrame[{file, width, height, totalMs, outBytes, decode, stages{curve, decode, demosaic, encode, write}}]}`. Holds the **only** cross-project provenance link for clones, since the manifest's `importedFromID` is nil'd for them. Dropped at `.lapse` install and never sent over the network (not in `transferableFiles`).

### 3.10 `notes/notes.json` (`App/FieldNotes/FieldNoteStore.swift:7-29`)

Array of `{id, kind ("audio"|"issue"|"text"), createdAt, text?, issueLabels?, audioFileName?, durationSeconds?, transcript?, linkedNoteID?}`, ISO-8601. Custom issue labels are a global default, not per project.

### 3.11 `overlays.json` (`App/Overlay/OverlayStore.swift:19-29`, `SceneOverlay.swift:77-114`)

`{o: [SceneOverlay], m: SegmentationSettings{edgeBias, featherRadius, maskMode, threshold}, cm: [CustomMask{id, n, in, r, f}]}`. `SceneOverlay` keys: `id, c{t:"text", v:TextOverlayContent}, x, y, s, p, an{in,out,f…}, v, on, md, bw, bh, as, mn, mx, r, l`; placement strings `none | sky | land | m:<uuid> | mi:<uuid>`. Legacy bare-array form still decoded. An unknown content type `t` makes the whole document read as empty.

### 3.12 `source/documents.json` (`App/ScanDocuments.swift`)

Array of `{id, name, pageIndices[1-based], createdAt}`; removed when ≤ 1 document; absence means one implicit document with a fixed id.

### 3.13 Global small stores

- `blend-profiles.json`: `{profiles: [[BlendProfileKey{deviceModel, intervalSeconds, pipeline, thermalBucket}, BlendLearningProfile{bestFrames, samples[{blendMillis, capped, date, framesCaptured, throttleDetected}]}], …]}` — a keyed array of pairs, ISO-8601.
- `custom_presets.json`: array of `{id, name, basePreset, adjustments}`.
- `light_ladders.json`: array of `{id, name, clonedFromID?, rungs[{id, name, lowerBoundEV, intervalSeconds, blendFrames, iso ("min"|"auto"|number), shutter ("auto"|{cap}|number), whiteBalance}]}` with custom enum encodings.
- `CaptureLogs/capture-<uuid>.log`: one `{"t", "event", "offset"?, "data"?}` per line, sorted keys, doubles coerced to 6 dp decimals (`App/CaptureSessionLogger.swift:253-274`). One file per **camera session** (screen open → close), not per run, so a Photo session spans many shots. Event vocabulary from the call sites: `session_start` {device, app{version, build}, system, mode, format{…}}, `format_change` (deduplicated), `burst_set`, `capture_start` {kind: video \| interval \| scanner \| liveBlend \| holyGrailBlend, …}, `capture_refused` {reason: tooHot}, `capture_end` {kind, frameCount, endReason}, `stop_requested` {source: phone \| watch \| scheduled \| rig \| thermal, …}, `burst_start`, `burst_end`, `mark_in`, `mark_out`, `exposure_lock`, `exposure_unlock`, `focus_tap`, `focus_carry`, `focus_run_lock`, `focus_switch_repair`, `scanner_manual_capture`, `scanner_delete_last`, `watch_command`, `session_end` {reason, elapsedSeconds, frameCount?} (written only on the path that then deletes the file). **No event carries the staging directory path**, so an orphan cannot be joined to its frames.
- `Logs/ladder-<stamp>.jsonl`: a header line `{kind: "ladder", ladderID, ladderName, rungs[], openingRung, sceneEV?, pipeline, startedAt}` then one line per window `{window, at, sceneEV?, rung, name, everyAsked, everyApplied, blendAsked, blendApplied, yieldedBy?, changed}` (`App/LightLadderRun.swift:62-85`). **Dates here are raw seconds-since-2001 doubles** — the encoder sets no date strategy (`:46-50`) — unlike every other sidecar; `scheduledRecording` in `UserDefaults` has the same quirk. No reader exists.
- Mac job manifest `<input>.letslapse/manifest.json`: `{sourcePath, sourceName, outputPath, status (created→…→completed), inputFrames, blendedFrames, blendWindow, outputFPS, linearLight, extractFormat, keepExtractedFrames, maxBlendBatches, maxCPUWorkers, trimHeadTailSeconds, updatedAt}` — note it stores **absolute paths**, which is why a library move breaks resume.

### 3.14 `project.json` inside a `.lapse` archive and on the wire

`ProjectArchiveManifest {formatVersion: 1, capture: CaptureProject, blends: [BlendProject]}` (`App/ProjectArchive.swift:7-11`) — the **same structs as `library.json` but with ISO-8601 dates** (`AppModel.swift:8339-8341`, `:8701-8703`). A migration tool must not confuse the two encodings.

---

## 4. Relationship map

### 4.1 How a project is identified

| Level | Identifier | Origin | Stable on one device | Stable across devices |
|---|---|---|---|---|
| Project | `CaptureProject.id` = folder name | `UUID()` at registration (`AppModel.swift:6607`, `:6764`, `:6928`, `:7174`, `:7314`, `:8576`) | yes | **no** — re-minted on every `.lapse` import and network transfer (`:8576-8578`) and on DNG clone (`:7248`) |
| Origin link | `importedFromID` | set to the **immediate sender's** `capture.id` at install (`:8578`); overwritten, so one hop only; **nil'd** on DNG clone (`:7252`) | — | partial: A→B→C loses A |
| Clone link | `dng-archive.json.sourceProjectID` | the source's local id (`:7226`) | yes | dropped at every import (not in `transferableFiles`) |
| Blend | `BlendProject.id` = file name in `blends/` | `UUID()`; re-minted on import (`:8605`) | yes | no |
| Collection | `LapseCollection.id` = `Collections/<id>/` | `UUID()` | yes | never travels |
| Frame | position in `sourceFileNames`; file name `frame-%05d` for captures, the original name for imports (`_WEX3879.ARW`) | registration | yes | yes (names travel) |
| Frame in sidecars | `frames.timestamps.frame` (writer-dependent origin), `frames.exposure.frameIndex` (0-based), `capture_log.frames[].frameIndex` (1-based), `framing.json.frames[].name` and `frames.whitebalance.file` (by **name**) | each writer | — | name-keyed sidecars survive renumbering; index-keyed ones do not |
| Capture session | `capture_log.json.sessionID` — a fresh UUID on the capture path, the project id only on import; `CaptureLogs/capture-<uuid>.log` — its own UUID; `Logs/liveblend-<stamp>` — a wall-clock stamp | run | — | nothing links a session log to its project except the in-project copy's location |
| Device | **none** on any project. Device name/model/pid live only in the Bonjour TXT record and in `transfer.rememberedCodes` | — | — | — |
| Thumbnail / mask cache | `sha256("v3|<path minus $HOME>|<mtime>")` | path | **no** — a storage-root move or a transfer changes the path; all thumbnails regenerate | no |

**Blocker for a presence registry:** there is no identifier that the same shoot carries on two devices. `importedFromID` gets close for one hop. The DNG-archive clone, the second hop, and pre-2026-08-13 imports have no thread at all.

### 4.2 What `library.json` duplicates, and who wins

| Fact | Manifest copy | Per-project copy | Reader behaviour when they disagree |
|---|---|---|---|
| Which files are the frames | `sourceFileNames` | the `source/` listing | **Manifest wins.** URLs are built from the list without a `stat` (`AppModel.swift:1255-1265`); `source(for:)` throws on the first missing name (`:7422-7427`). Files in `source/` that are not listed are invisible. Verified on disk: one entry lists 750 frames over an empty folder; every ramped project lists a `.json` as a frame. |
| Video fps / duration / dimensions | `sourceFPS`, `sourceDurationSeconds`, `sourceWidth/Height`, `sourceSegment*` | the movie container, `sequence.json` | Media wins, but only when a probe runs (`refreshVideoMetadata`, merged never replaced, `:7736-7748`). Every card reads the manifest. Rotate 90° swaps the stored pair without re-probing. |
| Segment spans and rates | `sourceSegmentSeconds/FPS` keyed by file name | `sequence.json.segments[]` | **Manifest wins** (`:178-203`). |
| Capture-time flag FLAT | none | `capture_log.json.captureFlat` and `sequence.json.captureFlat` | sidecar only (`:3939-3953`). |
| Capture dimensions | `sourceWidth/Height` | `capture_log.json.captureWidth/Height`, `framing.json.width/height` | three copies, never reconciled. |
| Blend result stats | `width, height, inputFrames, outputFrames, summary` | the `blends/<id>.mp4` | manifest copy written once by `storeBlend` (`:6587-6595`), never re-probed. |
| Scanner-ness | `captureMode: "scanner"` (since 08-16) | mode string `"Interval · Scanner"`, then any `rectangle` line in `frames.timestamps` | manifest first, string second, sidecar third (`:271-279`, `:1411-1418`). |
| Collection export | `lastExport {fileName, exportedAt, recipe}` | `Collections/<id>/render.mp4` | recipe string gates re-use; file existence checked (`:2311-2320`). |
| Grade, preset, keyframes, WB source, reframe, warp, crops, AI tags | manifest **only** | — | no per-project copy exists; a lost manifest loses every edit. |
| Provenance | `importedFromID` | `dng-archive.json.sourceProjectID` | disjoint: the manifest nils the link the ledger keeps. |
| Shoot span | `sourceDurationSeconds` | `framing.json.captureSpanSeconds`, `frames.timestamps` | three derivations. |
| Delivered exposure per frame | — | `frames.timestamps` (shutter/iso/ev), `frames.exposure` (iso/exposureDuration/aperture/ev), `capture_log.json.frames[]` (iso/exposureDuration/aperture/ev + window + ramp) | three copies; `ev` means "engine smoothed EV" in the first and "metered EV" in the others. |

### 4.3 Which file lists are the contract (five of them)

A new per-project file has to be added to every one of these or it is silently lost somewhere:

1. `ProjectArchive.transferableSubfolders` / `transferableFiles` — what a transfer sends and what **any** import keeps (`App/ProjectArchive.swift:41,53`).
2. The registration copy list (`AppModel.swift:6660-6680`) — which staging sidecars reach `source/`.
3. The DNG-clone copy list (`:7207-7222`).
4. `StorageRoot.libraryItemNames` — what a macOS library move carries (`StorageLocation.swift:35-39`).
5. `AppModel.isCacheItem` — which `tmp/` prefixes the storage card counts and "Clear cache" removes (`:4147-4162`).

`dng-archive.json` is in none of 1–3 and is lost on every import. The Mac job folder `<clip>.letslapse/` is in 1 by accident (it lives under `source/`) and so travels. Everything written directly under the root is in 4; the model stores are not under the root at all.

### 4.4 What travels

| Item | `.lapse` archive | Network transfer | Kept at install |
|---|---|---|---|
| `source/*` incl. `sequence.json`, `frames.*`, `capture_log.json`, `framing.json`, `documents.json`, `liveblend-*.json`, encodings, corrected HEICs | yes (whole folder) | yes | yes |
| `blends/*` | yes | yes | only files named in the manifest; others become unregistered orphans |
| `notes/`, `masks/`, `fonts/`, `overlays.json` | yes | yes | yes |
| `dng-archive.json` | yes (bytes) | **no** | **no** |
| `project.json` | written by the sender | first wire entry | consumed, never kept |
| Hidden files | yes | no (`.skipsHiddenFiles`) | — |
| `Logs/`, `CaptureLogs/`, `Thumbnails/`, `SceneMasks/`, Collections | no | no (one 320-px tile per row on request) | no |
| `.gpx` | never exists in a project | — | — |

---

## 5. Risk list

Ordered by likelihood × severity. "Seen" means the condition exists in one of the two real libraries today.

| # | Risk | Likelihood | Severity | Seen | Evidence |
|---|---|---|---|---|---|
| R1 | **Manifest overwritten after a failed load.** `loadLibrary()` leaves the arrays empty and sets `errorMessage`; there is no load-failed flag, so the next persist (a new capture, silent AI tagging, a migration) writes a manifest containing only the new entries. Every folder survives, every grade, tag, blend record and collection is gone. Triggers: any strict decode point in §3.1 — an unknown enum raw value from a newer build, a required key missing after a hand edit, a newer schema on a shared external root. | medium (nineteen additive schema changes in seven weeks; two Mac builds share one root) | catastrophic | no | `AppModel.swift:7467-7502`, `:7541` |
| R2 | **Manifest ↔ folder drift with no reconciliation.** Every registration writes files first and persists last; every delete removes files first and persists last; installs on a macOS custom root are cross-volume copies, not renames. A kill in any window leaves an orphan folder or a dangling record, and nothing at launch compares `Projects/*` with the index. | high | medium per event, cumulative | **yes**: 3 orphan folders, 1 record over an empty folder, 7 unlisted renders | `:1726-1735`, `:1752-1759`, `:6618→6701`, `:8585→8621`, `App/ProjectImport.swift:157` |
| R3 | **Two uncoordinated manifest writers in one process.** Main-actor `persistLibrary()` and the queued `persistLibraryOffMain()` have no ordering; a queued older snapshot can land after a newer main-actor write (grade tick → delete blend → queue drains → the deleted blend is back on disk). All off-main errors are `try?`-swallowed. | medium | medium (disk lags memory; lost on kill) | plausible cause of the 7 unlisted renders | `:7541-7555`, `:9077-9093` |
| R4 | **Full manifest rewrite on every grade-slider settle, scaling with total frames.** 2.3 MB today; 30 B per frame across the whole library. The iPad measurement already showed the persist as the top app symbol at 276 KB. | certain | UX (hitches) now; launch time later | yes | `docs/editor-performance-plan.md §2`; measurements §1 |
| R5 | **Experiment log rewritten after every output.** O(n²) bytes over a run: at 1.15–1.5 KB per output entry, a 5,000-output shoot rewrites a 6–7 MB document 5,000 times, 14–19 GB of writes and O(n²) JSON encoding on the same serial queue that blends the windows, on a phone already thermally throttled by the shoot. Also written to `Logs/` for every run and never pruned (277 files on the iPhone). `blend-profiles.json` is likewise rewritten per Psycho window, but it is bounded to ~40 samples per profile. | certain on every blend run | performance, storage, flash wear | yes | `App/LiveBlendController.swift:1132,1349-1356`; `LiveBlendRawController.swift:1111,1548-1556`; `App/BlendProfileStore.swift:56-60` |
| R6 | **Two macOS instances on one root** (Debug beside Release is "the normal state of this project", `App/ProjectImport.swift:177-182`). No lock, no reload, no file watcher: each instance loads once and overwrites the other's additions and deletions with its own memory. | medium on this Mac, low elsewhere | high (silent) | not observed | `StorageLocation.swift:56-67`, `:1155`, no `flock`/`NSFileCoordinator`/`LSMultipleInstancesProhibited` |
| R7 | **Two preference domains on the Mac.** Unsandboxed Debug reads `~/Library/Preferences`; a sandboxed build reads the container. `storage.libraryRootPath` set in one is invisible in the other, so a sandboxed build silently opens the empty default library. | certain once a sandboxed build ships | confusing, not lossy | yes (container plist has 2 keys) | `App/LetsLapse.entitlements`; both plists |
| R8 | **`tmp/` is a second, uncounted library.** Capture staging, share archives, render temps and model downloads accumulate; the storage card and headroom chip do not see them. 9.7 GB on the iPhone today; 44 GB in the 2026-08-21 incident. | high | storage exhaustion during a shoot | yes | `docs/storage-accounting-job.md`; `AppModel.swift:4147-4162` |
| R9 | **Provenance lost on transfer.** `importedFromID` is one hop; `dng-archive.json` is dropped at install; there is no device id. A presence registry cannot be built on the current identifiers. | certain | blocks the planned feature | yes (75 imports, 0 resolvable origins) | §4.1 |
| R10 | **Sidecars misregistered as frames.** 77 `sourceFileNames` entries on the Mac and 10 projects on the iPhone list `frame-NNNNN.json`; frame counts, thumbnails and "N photos" labels are off by one; 13 read sites carry a `.hasSuffix(".json")` filter. Fixed for new shoots on 2026-09-05; existing entries are never repaired. | certain for older projects | low-medium | yes | `:294`, `:1327`, `:6657-6668` |
| R11 | **Unbracketed background writers during a serve or export.** Transcode, scan correction and rotation are not `LibraryActivity`-bracketed; the transfer server snapshots sizes then streams to EOF, so a file that grows or is replaced mid-serve fails the transfer, and non-atomic media writes (`storeBlend` remove-then-copy, transcode into `source/`) can ship truncated. | low-medium | medium | not observed | `Shared/ProjectTransferServer.swift:629-666, 813-877`; `AppModel.swift:7655-7660` |
| R12 | **`StorageMover` copies a live library.** It plans, then copies file by file while the app keeps writing to the old root; files created after planning are skipped, non-atomic logs copy truncated, and the manifest is copied at whatever version it has when reached. | low (rare operation) | medium | not observed | `StorageLocation.swift:171-358` |
| R13 | **Field-notes manifest self-heals into data loss.** A torn or unreadable `notes/notes.json` reads as empty; the next note overwrites it with one entry. Audio files survive unreferenced. | low | low | no | `App/FieldNotes/FieldNoteStore.swift:69-76, 113-122` |
| R14 | **Strict sidecar decode blocks a project.** `sequence.json` is decoded with a plain `try` in `source(for:)`; a corrupt one makes a ramp project unopenable. An unknown overlay content type makes the whole `overlays.json` read as empty. | low | medium | no | `AppModel.swift:7448-7460`; `OverlayStore.swift:108-115` |
| R15 | **No `fsync` on the hot-path appenders.** `FileHandle.write` hands data to the kernel; an app crash loses nothing, a power loss or kernel panic can lose the page-cache tail (seconds of frames). Torn-line-tolerant readers make this safe to recover from, but the last frames' timing is gone. | low | low | no | `Kit/…/FrameTimestamps.swift:256-265` |
| R16 | **Orphaned capture logs are mostly noise.** 32 on the iPhone; most are two lines (camera opened, format changed) with no `session_end` — the process ended with the camera screen open, not with a shoot lost. Incomplete Captures will not distinguish the two. | certain | low (dilutes a real diagnostic) | yes | pulled logs |
| R17 | **Absolute paths in the Mac job manifest.** `<segment>.letslapse/manifest.json` stores `/Users/…/Application Support/…` source and output paths; the seven on the external volume point at a root that no longer exists, so resume is impossible after a library move. | certain after a move | low | yes | disk sample §3.13 |
| R18 | **`transfer.rememberedCodes` stores pairing codes in plain text** in `UserDefaults`, keyed by device id. Not a persistence-integrity risk; noted for the registry footnote. | — | low | yes | `Shared/ProjectTransferClient.swift:831` |
| R19 | **Mac blend scratch lives inside `source/` and travels.** `<clip>.letslapse/` (manifest with absolute paths, `passes/*.png`, `output/*.mp4`, `logs/job.log`) is never deleted, is counted in the project's size, is sent over the wire on a Mac→device transfer and is kept by every `.lapse` install. | certain for every Mac constant-window blend | storage, transfer time | yes (7 folders) | `App/MacVideoJobRunner.swift:281-299`; `App/ProjectArchive.swift:41`; `Shared/ProjectTransferServer.swift:633-651` |
| R20 | **Model weights sit in an unbranded folder outside the root.** On the unsandboxed Mac build that is `~/Library/Application Support/Models`, shared with any other app that picks the same name; it never moves with the library. | certain on macOS | low (re-downloadable) | by code | `App/AI/ModelManager.swift:347-357` |
| R21 | **Leftover `.<movie>.gps-backup` clones.** A kill between the APFS clone and the header write leaves a hidden backup beside the segment; nothing sweeps it. | low | low | not observed | `App/MovieLocation.swift:150-190` |

### 5.1 Crash mid-write of `library.json`

Both writers use `Data.write(options: .atomic)` (temp file + rename), so a kill never leaves a torn manifest. What a kill loses is the queued off-main write (last grade gesture) unless an editor flushed it, and — separately — the ordering race in R3. The dangerous case is not corruption; it is R1 (a manifest the current build cannot decode) and R2 (a manifest that no longer matches the folders).

### 5.2 Crash mid-capture — what survives and what recovers

| File | Survives a kill | Recovered by |
|---|---|---|
| `tmp/<staging>/frame-*.dng\|jpg` | yes, until "Clear cache" | nothing — an unregistered shoot stays in `tmp/` (the 2026-08-21 incident: 25 GB of such folders) |
| `tmp/<staging>/frames.timestamps`, `frames.exposure` | yes, every completed line | nothing automatic |
| `capture_log.json` | **no** — written only at run end | — (the DNG controller holds the frame log in memory) |
| `Logs/liveblend-<stamp>.json` | yes, as of the last completed output | nothing automatic; readable by `tools/` |
| `CaptureLogs/capture-<uuid>.log` | yes, every event | Settings ▸ Incomplete Captures shows it; it is a diagnostic, not a recovery path — it carries no frame list |
| `sequence.json` | **no** — written at `completeLiveCapture` | recorded `segment-NNN.mov` files remain in staging with no sidecar |

There is **no finalise-on-next-launch path**: `LetsLapseApp.init` scans `CaptureLogs/` into the Settings list, sweeps `tmp/lapse-import-*` after 15 minutes and `Incoming/` after 24 hours, and nothing else (`App/LetsLapseApp.swift:26-37`). The only code that enumerates `tmp/interval-*`, `liveblend-*`, `liveblend-dng-*` or `scanner-*` is `isCacheItem`, whose callers are the storage figure and "Clear cache" — a crashed shoot's frames are **charged as cache and deleted by the button meant to free space** (`AppModel.swift:4130, 4154-4162`). The comment in `CameraController.swift:1434-1437` ("the frames and their sidecar are Incomplete Captures' material now") does not match the behaviour: Incomplete Captures shows the `.log`, which carries no path to the staging folder. The capture log is the diagnostic asset the brief hoped for; the timestamps sidecar plus the frames in staging are the recovery asset, and together they are enough to register a truncated shoot — that path does not exist yet.

### 5.3 Defensive parsing and silent failure (where past failures live)

- `FrameTimestamps.decode` skips torn lines ("a run killed mid-write can leave a torn final line") — `Kit/…/FrameTimestamps.swift:74-96`.
- `CaptureExposureLog.loadSidecar` same — `:475-484`.
- `CaptureSessionLogger.events` keeps unparseable lines as raw text — `App/CaptureSessionLogger.swift:376-395`.
- `CustomPresetStore`: corrupt file → empty, error surfaced — `App/CustomPreset.swift`.
- `FieldNoteStore`: torn manifest → empty (R13).
- `LapseCollection.Entry`: malformed `kenBurns` dropped rather than failing the file — `App/CollectionsModel.swift:100-107`.
- `PresetState`: half-written `named` → `.edited` — `App/PresetState.swift:202-222`.
- `OverlayStore`: legacy bare-array form accepted — `App/Overlay/OverlayStore.swift:111-114`.
- The comment trail around the renamed experiment log — `AppModel.swift:6655-6668`, `CaptureView.swift:1080-1084`.
- 20 `try? persistLibrary()` sites and every line of `persistLibraryOffMain()`.
- The whole-folder `.lapse` archive was made "whole" after `overlays.json` was found to be dropped at install until 2026-08-31 (`App/ProjectArchive.swift:44-52`).

### 5.4 Concurrency summary

| Store | Writers | Coordination | Multi-instance |
|---|---|---|---|
| `library.json` | main actor sync + static serial utility queue | none between the two | last writer wins, whole file, no reload |
| per-project sidecars | main (notes, overlays, documents, WB), detached tasks (framing review, scan correction, rotation), `conversionQueue` (transcode), the `lapse` CLI | per-file atomic writes; no cross-writer exclusion; the app caches framing/WB in memory and will overwrite a CLI write | last writer wins |
| hot-path NDJSON | one writer each, caller-confined to the session/blend queue | by construction | n/a (in `tmp/`) |
| `Incoming/<id>` | transfer client serial queue | confined | two pulls of the same project delete each other's staging |
| caches | detached tasks, an actor | none needed | benign |
| `UserDefaults` | main | `cfprefsd` | shared across instances by bundle id |
| macOS external root | two instances expected by the code; the `lapse` CLI writes into `source/` | **no lock file, no `NSFileCoordinator`, no file watcher** | R6 |

Remote control (Bonjour listener, Watch receiver) hops to the main actor before touching the model, so it cannot race a local write.

---

## 6. Recommendation

Argued from §2–§5. Constraints from the brief are taken as given: nondestructive, single-writer per project, clients are the source of truth, JSON stays, no structured writer on the hot path.

### 6.1 Hot-path format — hypothesis confirmed, with one change and one merge

**Confirmed.** The app already does what the hypothesis describes for the records that matter: `frames.timestamps`, `frames.exposure` and the capture session log are one JSON object per line, appended and flushed per event, with readers that skip torn lines. `capture_log.json` is not a hot-path file at all; it is written once at finalise from an in-memory frame log. NDJSON over plain text is worth the strictness here because the readers already exist on both sides (Kit decoders, seven Python tools, the fleet report), `sortedKeys` keeps lines greppable, and one-object-per-line gives truncation safety with no parsing ambiguity. Do not switch to plain text.

**The one violator** is the live-blend experiment log (`Logs/liveblend-<stamp>.json`), rewritten whole after every output (R5). Make it the same shape as the others: `liveblend-<stamp>.ndjson` with a header line, one output line per window, a summary line at close; convert to the existing `{header, outputs, summary}` document at finalise for `tools/` (or teach `blend_compare.py` to read the line form — a ten-line change). This removes the O(n²) writes and the 14 GB-per-shoot flash cost on the biggest runs.

**The one merge.** Three files carry per-frame exposure. `frames.exposure` has no reader in the app, the CLI or `tools/`. Add its two missing fields (`aperture`, and `capturedAt` is already `captureTime`) to the `frames.timestamps` line, keep `capture_log.json` as the finalise document derived from the same in-memory log, and stop writing `frames.exposure` for new shoots once the merge has shipped. Existing files stay readable through the existing decoder. Normalise the frame index while doing it: **0-based, matching `sourceFileNames` position**, in every writer.

**Cost to make uniform:** small. Two writer classes exist (`FrameTimestampWriter`, `CaptureExposureWriter`) and the session logger hand-rolls a third; one `NDJSONWriter` in the Kit with an explicit flush policy replaces all three. Add an optional `fsync` at run milestones (every N seconds, at every window close) — cheap, and it turns R15 from "seconds" to "one line".

### 6.2 Storage engine — keep JSON files, split the manifest; no database

**What the app actually needs from its store.** `loadLibrary()` reads the whole manifest once into three arrays; every list, filter, sort, scene search and collection lookup runs over those arrays in Swift. There is no query that a database index would serve. Memory is not a concern (2.3 MB for the largest library). Launch decode is 12 ms on the Mac and will stay under a second on an A14 up to a manifest of roughly 10 MB.

**What breaks first** is the write side, and it is already the top symbol in a profile: every one of 35 mutation sites re-encodes and rewrites the whole document, and the document scales with the total number of frames in the library because `sourceFileNames` lives in it. A 200-project stills library at 1,500 frames each is ~9 MB rewritten on every slider settle, several times a second on the off-main queue. The second thing that breaks is R1: a document that decodes as one unit fails as one unit.

**A database would fix the rewrite cost and the partial-failure blast radius**, and SQLite in WAL mode would also give cross-process locking for free (R6). It would cost: a second representation of every project alongside `project.json` (which already exists as the archive and wire format), a new dependency in the Kit and the `lapse` CLI, a rewrite of seven analysis tools, loss of the "open the folder and read it" property the brief values, and a migration of exactly the same data. It buys nothing for reads. **Do not add one.**

**Do this instead — three changes to the same JSON:**

1. **Per-project `project.json`, authoritative for everything about one project.** It already exists as `ProjectArchiveManifest {formatVersion, capture, blends}` (§3.14); make it persistent instead of transient, written atomically into `Projects/<id>/project.json` on every mutation of that project. A grade settle then rewrites a few KB, not the library. This is also the file that travels, so export and transfer stop needing to synthesise a manifest.
2. **`library.json` becomes an index**, not a copy: per project the id, origin id, kind, `createdAt`, `modifiedAt`, `name`, `mode`, frame count, dimensions, hero hint, and per blend the id, kind, `createdAt`, summary — what the Projects and Gallery lists render without opening a folder. Collections stay in it (they span projects). Roughly 300 B per project: the Mac library becomes ~50 KB, and a 1,000-project library ~300 KB. `sourceFileNames`, `gradeTimeline`, `clipEncodings`, `nominatedBadFrameNames`, `sceneElements`, `warp`, `reframe`, `timeSlice` move out.
3. **The index is rebuildable from the folders.** Because every project folder carries its own `project.json`, a launch-time reconciliation can (a) list folders without an index entry and register them, (b) list index entries without a folder and mark them missing, and (c) on an undecodable index, rename it aside and rebuild rather than overwrite. This is the missing recovery path for R1 and R2, and it is what makes the change worth doing even before the write-cost argument.

Two smaller fixes that stand on their own and should not wait for the split:

- **One persist path.** Route `persistLibrary()` through the same serial queue as the off-main path, carry a monotonically increasing version in memory, and drop a queued snapshot whose version is older than the last written. Keep `flushLibraryPersists()` at editor exit and add it to `applicationWillTerminate`/scene-phase background. Log failures instead of `try?`.
- **Persist before you delete.** Deletions should mark the record (or remove it and persist) **before** removing files, then remove files, then persist again if a folder listing changed. A `Projects/.trash/<id>` move instead of `removeItem` makes deletion reversible and keeps the nondestructive constraint honest.

### 6.3 Sidecar model — stay per-concern

The evidence favours the current shape:

- **Absence is meaning** at nine read sites (§5.3 and the sidecar report): no `frames.timestamps` means even spacing, no `framing.json` means unreviewed, no `documents.json` means one document, no `overlays.json` means no text. A consolidated sidecar would have to encode all of that as explicit nulls and lose the self-documenting folder.
- **Damage containment is real**: a torn `overlays.json` cannot cost a shoot its timing; the one place consolidation exists today — `library.json` — is the one place a single bad byte costs everything.
- **Writers differ in thread and lifetime**: notes on the main actor, framing review from a detached task, `frames.whitebalance` from the CLI, `frames.timestamps` from the session queue during capture. One file would need one lock.
- **They travel individually** through the transfer list, and the list is the mechanism that decides what a project is on another device.

Two things to fix without consolidating:

1. **One registry of project files.** Five lists (§4.3) each have to know every sidecar; `dng-archive.json` is already missing from three. Replace them with a single table in the Kit — name, location (root or `source/`), authoritative or cache, travels or not, hot-path or finalise — and derive the archive, transfer, clone, registration and storage-card lists from it.
2. **Put every authoritative sidecar in one place.** Today `overlays.json`, `notes/`, `dng-archive.json` sit at the project root and `frames.*`, `capture_log.json`, `framing.json`, `sequence.json`, `documents.json` sit in `source/` beside the media. Either is fine; mixed is what makes the five lists diverge. The less disruptive rule is "capture-time records in `source/`, edit-time records at the root", stated once in the registry.
3. **Keep scratch out of `source/`.** The Mac job folder should be created under a `.jobs/` sibling (hidden, so the transfer walker skips it) or under `tmp/`, and deleted when the job completes; its manifest should store paths relative to the project so a library move does not break resume.

### 6.4 Identity — the highest-value change

Add three fields, all optional on decode, all written on every persist:

| Field | Meaning | Assigned | Preserved through |
|---|---|---|---|
| `originID` | the shoot's identity, the same on every device that holds a copy | once, at first registration (= the local `id` of the registering device) | every `.lapse` export, network transfer, and second-hop re-export, verbatim |
| `originDeviceID` | which install first registered it | a per-install UUID minted once into `UserDefaults` (there is none today) | verbatim |
| `derivedFromOriginID` | for DNG-archive clones (and any future derivative): the parent's `originID` | at clone time from the parent's record | verbatim |

`id` stays the local instance id and the folder name — it is what every path, cache key and blend `captureID` already uses, and changing it would touch every store. `importedFromID` stays as the one-hop transport history it already is. The installer's duplicate check moves from `id == originID || importedFromID == originID` to `originID == originID`, which also fixes the second-hop gap.

Write the same `originID` into `capture_log.json.sessionID` (today a random UUID on the capture path) and into the in-project experiment log header, so the per-shoot records can be joined to the project without the folder path.

**Migration for existing projects** (both libraries): `originID = importedFromID ?? id`. For a DNG clone whose `dng-archive.json` is still present and whose `sourceProjectID` is in the same library, `derivedFromOriginID = that project's originID`; otherwise leave it absent. This recovers the correct origin for every one-hop import in the Mac library (75 of 103) and can never assign a wrong one, because the only inputs are ids the project already carries. Nothing on disk is renamed.

### 6.5 What this recommendation does not do

It does not change any media file, any hot-path record format except the experiment log, the `.lapse` container, the wire protocol (which already sends `project.json` first), or the `tools/` inputs beyond the one experiment-log reader. It does not move the app off JSON anywhere.

---

## 7. Migration plan

Every phase leaves the previous phase's files readable by the previous build; every phase is verified by the same tool before and after; original files are kept until verification passes.

### Phase 0 — the audit tool (before any change)

`lapse audit <root> [--json]`: enumerate `Projects/*` against `library.json`; for every capture check every `sourceFileNames` entry exists and every `blends/` file is listed; report orphan folders, dangling records, unlisted renders, `.json` entries in `sourceFileNames`, sidecar presence per project, index-origin mismatches between `frames.timestamps` / `frames.exposure` / `capture_log.json`, and byte totals. Run it on this Mac's `/Volumes/letslapse` and on both iOS devices (via the transfer server or `devicectl`) and keep the reports as the baseline. This is the verification instrument for every later phase; today the numbers in §0 item 4 were produced by an ad-hoc script and should be reproducible.

### Phase 1 — additive fixes, no format change (safe to ship independently)

1. `originID`, `originDeviceID`, `derivedFromOriginID` on `CaptureProject` (optional; derived on load when absent; written on every persist). Synthesized `Codable` on the current build ignores unknown keys, so a downgrade still reads the file.
2. Preserve `originID` through export, transfer and clone; switch duplicate detection to it.
3. `sessionID` = `originID` in `capture_log.json`; the experiment log gains an `originID` header field.
4. One persist queue with version gating; failures logged; flush on background/terminate.
5. Persist-before-delete ordering, or a `.trash/` move.
6. Experiment log to NDJSON; prune `Logs/liveblend-*` and `Logs/ladder-*` to the last N or to a byte budget like the console log.
7. Repair pass for R10: strip `.json` names out of `sourceFileNames` on load (the reader already filters them), persist once, bump `gradingSchemaVersion` to 3 so it runs once.
8. Mac job folders: create under a hidden `.jobs/` sibling or `tmp/`, delete on completion, relative paths in the manifest (R19, R17).
9. Model weights under a branded path (`Application Support/LetsLapse/Models` on iOS is already inside the container; on macOS `~/Library/Application Support/LetsLapse-Models` or similar), still outside the relocatable root (R20).
10. Prune the leftover `.gps-backup` clones at launch (R21).

**Verification:** Phase 0 report before and after shows identical capture/blend/collection counts, identical per-entry content except the added fields, `originID` = `importedFromID ?? id` for every pre-existing entry, zero `.json` names left in `sourceFileNames`, and the experiment log for a test run parses line by line and converts to the old document shape byte-for-byte.

### Phase 2 — dual-write `project.json`

Every persist that touches a project also writes `Projects/<id>/project.json` (`formatVersion: 2`, ISO-8601 dates, the full `CaptureProject` + its `BlendProject`s). `library.json` is unchanged and still authoritative. A one-time pass at launch writes `project.json` for every existing project (103 + 234 small atomic writes, seconds).

**Verification:** `lapse audit --rebuild-index` reconstructs a `library.json` from the `project.json` files and diffs it against the real one after canonical re-encoding (sorted keys; dates compared as seconds to the millisecond, since the two encodings differ). Must be empty. Export and transfer are switched to send the on-disk `project.json`; a round trip Mac→iPhone→Mac must produce an identical `project.json` (bar `id`, `importedFromID`, and blend re-keying).

### Phase 3 — the index

`library.json` is rewritten as the index (§6.2 item 2) with `formatVersion: 2` at its root; the app reads `project.json` on project open and on the few list paths that need frame names. The previous full manifest is kept as `library.json.v1-<date>` until Phase 4 verification passes. Reversible: `lapse audit --emit-v1` regenerates a v1 manifest from the index plus the `project.json` files.

**Verification:** the regenerated v1 manifest equals the kept backup under the Phase 2 diff; every list screen renders the same rows in the same order (the existing `LL_*` screenshot hooks cover Projects, Gallery, Collections, Scans); a grade settle on the 5,661-frame project rewrites only its `project.json` (check with `fs_usage` or the size cache).

### Phase 4 — reconciliation and multi-instance

Launch-time reconciliation from folders (§6.2 item 3); an advisory lock file `Projects/.lock` (pid, host, bundle build) that a second instance respects by opening read-only with a banner; a `modificationDate` check on the index when the app returns to the foreground. Then the `.lapse` staging moves under `<root>/Incoming` so installs are renames on a custom root too.

**Verification:** kill the app between registration and persist on a test shoot and confirm the shoot appears after relaunch; run two Mac instances on one root and confirm the second cannot write; corrupt the index deliberately and confirm it is renamed aside and rebuilt with every project present.

### What is deliberately not migrated

Media, the hot-path sidecars already on disk (their decoders stay), `Thumbnails/` and `SceneMasks/` (caches; they regenerate), `Logs/` history, `UserDefaults`.

---

## 8. Explicit gaps

What could not be determined in this pass, and what would settle it:

1. **Codable encode cost on device.** Timings are JSONSerialization on an M4 Max; the iPad number is from a 2026-08-29 profile at 276 KB. A direct measurement of `persistLibrary()` on the 12 Pro with the 2.3 MB manifest would pin the R4 curve.
2. **Whether Settings ▸ Incomplete Captures can delete the *other* instance's live log** on macOS (a live log is indistinguishable from an orphan at scan time).
3. **The 44623568 orphan folder's cause.** Its `source/` mtime is 2026-08-27, the folder's is 2026-09-05 08:53: consistent with an import or transfer killed between the folder move and the persist. The capture log for that session was not found.
4. **Durability under power loss.** No `fsync` anywhere on the hot path; not tested on a device.
5. **The iPad libraries.** Only the iPhone container was pulled; both iPads are paired and available but were not touched.
6. **The `.gpx` track.** It is lost at registration by design; whether that is still the intent after the transfer work (the overview still documents it under `source/`) is Steven's call.
7. **User folders on the library volume.** `Exports_testing`, `Source_SONY`, `Source_VIDEOS` sit beside the library on `/Volumes/letslapse`; they are outside the app and outside this audit, but a "move everything under the root" migration must not touch them (which is why `libraryItemNames` exists).
8. **Whether any third-party tool depends on `frames.exposure`** before its writer is retired (§6.1) — nothing in this repository does.
9. **`shoot.py` reads the experiment log as one document** (`.claude/skills/letslapse/shoot.py:722-757`); the NDJSON change in §6.1 needs its finalise conversion or a reader update — a small change, listed so it is not forgotten.
10. **The Watch's `PrivacyInfo.xcprivacy` comment** says `CaptureRemoteListener` reads the remote flag in the watch build; that file is `#if !os(watchOS)`. Documentation drift, not a store.

---

## 9. Footnote — what a presence registry needs from these stores

Per store, only the items that would make a "which devices hold a copy" registry impossible or expensive:

- **`library.json` / `project.json`**: no device-independent project id (§4.1) — the one blocker, fixed by `originID` (§6.4). No device id on any record — fixed by `originDeviceID`. No `modifiedAt` on many entries (probes and migrations do not stamp it), so "last confirmed" would have to come from the registry client, not the file.
- **`importedFromID`**: usable as a one-hop history but not as identity; keep it, do not build on it.
- **`dng-archive.json`**: the clone link is dropped at every import; move it into the manifest (`derivedFromOriginID`).
- **`transfer.rememberedCodes`**: the only per-device identity the app holds today is the Bonjour pid in this dictionary; it is a pairing artefact, not a device id, and it is stored in plain text.
- **Everything else** (sidecars, caches, logs, defaults) is irrelevant to presence and needs nothing.

Nothing about the server is designed here.

---

## Appendix A — Where the two real libraries stand today

| | Mac (`/Volumes/letslapse`) | iPhone 16 Pro (container) |
|---|---|---|
| `library.json` | 2,304,132 B; 103 captures, 140 blends, 1 collection; `gradingSchemaVersion` 2 | 424,090 B; 234 captures, 74 blends, 1 collection; v2 |
| Share of manifest that is `sourceFileNames` | 92 % (57,016 names) | 18 % (1,734 names; 171 of 234 projects are single Photos) |
| Largest capture entry | 150 KB (5,661 names) | — |
| Project folders / manifest entries | 106 / 103 (3 orphans) | 234 / 234 |
| Manifest entries over an empty folder | 1 (`C6F7D8CD`, "750 photos", imported from `F727637E`) | 0 |
| Blend files on disk not in the manifest | 7 | not checked |
| `.json` entries inside `sourceFileNames` | 77 | 10 projects carry `frame-NNNNN.json` |
| Captures with `importedFromID` / origins present locally | 75 / 0 | 1 / 0 |
| `presetState.kind` | — | named 213, original 11, edited 10 |
| `captureMode` present | 0 | 0 |
| Sidecars: `capture_log` / `timestamps` / `exposure` / `sequence` / `overlays` / `framing` / `notes` / `dng-archive` / `whitebalance` | 73 / 72 / 37 / 15 / 13 / 6 / 5 / 4 / 2 | 6 / 6 / 2 / 44 / 1 / 2 / 0 / 6 / 0 |
| Mac job folders inside `source/` | 7 | 0 |
| `Logs/` | 11 console, 9 liveblend (Jul–Aug), 1.0 MB | 12 console, 277 liveblend (38.8 MB), 5 ladder |
| `CaptureLogs/` orphans | 12 × 331 B (`session_start` only; driver-killed Mac sessions) | 32, mostly 568 B (`session_start` + `format_change`) |
| `Thumbnails/` | 943 files, 55 MB | 243 files, 14 MB |
| `SceneMasks/` | 247 files, 1 MB | 28 files |
| `Collections/` | 1 render, 135 MB | 1 render, 40 MB |
| `Incoming/` | empty | empty |
| `tmp/` | not inspected | **9.7 GB**: 3.3 GB model download, ~2.2 GB share archives, 16 render temps ~1.2 GB, two empty `live-capture-*` |
| Preferences | `~/Library/Preferences/com.regularsteven.letslapse.plist`, 40 KB, 48 app keys incl. `storage.libraryRootPath = /Volumes/letslapse`; the sandbox container plist holds 2 keys | 60 app keys; `letslapse.deviceCapabilityMatrix.v2` = 411 KB blob; legacy `liveBlendIntervalSeconds`/`liveBlendFramesPerBlend` still present |

Frame-index origins on the same 5,660-frame shoot (`BB6CBBE2`): `frames.timestamps` line 1 = `frame: 1` at 17:28:54.379Z; `frames.exposure` line 1 = `frameIndex: 0` at 17:28:53.498Z, line 2 = `frameIndex: 1` at 17:28:54.425Z; `capture_log.json.frames[0]` = `frameIndex: 1` at 17:28:53.498Z. The `ev` values also differ (11.746 vs 11.282) because the sidecars record different quantities under the same key.

---

## Appendix B — `UserDefaults` inventory (complete)

All keys are in `UserDefaults.standard` of the app process; there is no suite, no `register(defaults:)`. **AS** = `@AppStorage` (SwiftUI-observed), **UD** = direct `UserDefaults.standard`, **HOT** = read on the capture path (session queue, per run, per window or per frame). `CC` = `App/CameraController.swift`, `CV` = `App/CaptureView.swift`, `AM` = `App/AppModel.swift`, `SV` = `App/SettingsView.swift`. The `lapse` CLI writes `rawDecodePath` into its **own** process's defaults (`Kit/Sources/lapse/main.swift:404-414`), not the app's.

| # | Key | Defined | Type · default | Writers | Readers | Notes |
|---|---|---|---|---|---|---|
| 1 | `letslapse.rememberRecordingSettings` | CC:9360 | Bool · true (absent → true, :9400) | AM:966 (`false` also calls `clear()` :968) | CC:9400 → :1321; every `save` guard; CV:359, 566 | UD. Gate for 2–17, 20–21. |
| 2 | `letslapse.capture.mode` | CC:9362 | String `Photo\|Interval\|Video` | CC:9433 ← CV:558, 910 | CC:9427 ← CV:361 | UD. Legacy `"Live Blend"` → `.interval` (`Shared/CaptureMode.swift:20-25`). Cleared by `clear()`. |
| 3 | `letslapse.capture.lens` | CC:9363 | String legacy | **never written** | CC:9529-9534 (fallback for 4) | UD. Migration read; cleared. |
| 4 | `letslapse.capture.stopDisplayFactor` | CC:9364 | Double > 0 | CC:9539 | CC:9525 | UD. DEBUG `LL_STOP` overrides. |
| 5 | `letslapse.capture.resolutionWidth` / `…Height` | CC:9365-9366 | Int, Int | CC:9654-9655 ← :2663 (every `refreshCaptureOptions`) | CC:9543-9544 | UD. **HOT** (written on the session queue). |
| 6 | `letslapse.capture.resolutionProRes` | CC:9376 | Bool · false | CC:9656 | CC:9552, 9566 | UD. |
| 7 | `letslapse.capture.frameRate` | CC:9367 | Int | CC:9658 | CC:9575; fallback for 21 | UD. |
| 8 | `letslapse.capture.rampFrameRate` | CC:9368 | Int | CC:9659 | CC:9636 | UD. |
| 9 | `letslapse.capture.rampResolutionWidth` / `…Height` | CC:9369-9370 | Int, Int | CC:9661-9662 | CC:9559-9560 | UD. Absent = follow base. |
| 10 | `letslapse.capture.stabilization` | CC:9377 | Bool | CC:9664 | CC:9640 | UD. |
| 11 | `letslapse.capture.intervalSeconds` | CC:9378 | Double 0.1…3600 | CC:9449 ← CV:570, 653, 1275 | CC:9441 ← CV:366, 567 | UD. |
| 12 | `letslapse.capture.liveBlendIntervalSeconds` | CC:9382 | Double legacy | **never written** | CC:9442 (fallback for 11) | UD. Still present on the iPhone. |
| 13 | `letslapse.capture.liveBlendFramesPerBlend` | CC:9383 | Int legacy | **never written** | CC:9468 (fallback → `.fixed(n)`) | UD. Still present on the iPhone. |
| 14 | `letslapse.capture.blendDepth` | CC:9384 | String token `auto\|throttled\|unthrottled\|<1…60>` | CC:9474 ← CV:658 | CC:9464 ← CV:369 | UD. |
| 15 | `letslapse.capture.photoBlendDepth` | CC:9388 | Int 1…240 | CC:9487 | CC:9481 | UD. |
| 16 | `letslapse.capture.photoBulbMode` | CC:9389 | Bool | CC:9496 | CC:9491 | UD. |
| 17 | `letslapse.capture.ladderID` | CC:9392 | String UUID | CC:9506/9508 ← CV:529, `App/CreateView.swift:367` | CC:9500 ← CV:134, CreateView:72 | UD. Unresolvable → built-in ladder. |
| 18 | `letslapse.capture.customFrameRate` | CC:9396 | Int 1…240 · nil | CC:9410/9412 ← AM:981 | CC:9404 ← CC:212, 1886, 1904, 2745; `App/DeviceCapabilityMatrix.swift:292`; SV:64 | UD. Survives `clear()`. **HOT**. |
| 19 | `letslapse.capture.recordAudio` | CC:9397 | Bool · false | CC:9421 ← AM:976 | CC:9417 ← CC:1921; AM:975 | UD. Survives `clear()`. **HOT**. |
| 20 | `captureSettings.lensScopes` | CC:9597 | [String] registry of 21 | CC:9630-9632 | CC:9630, 9678 | UD. |
| 21 | `captureSettings.<deviceKey>~<stopID\|default>.frameRate` (dynamic) | CC:9589-9601 | Int | CC:9627 ← :2670 | CC:9614 ← :2627 | UD. **HOT**. Four such keys on the iPhone, one on the Mac. |
| 22 | `capture.gpsEnabled` | CV:16, SV:29 | Bool · true | AS | CV:1002 (GPX flush) | AS. |
| 23 | `remote.allowRemoteAccess` | `Shared/CaptureRemoteListener.swift:22` | Bool · false | AS SV:36, CV:19 | UD CaptureRemoteListener:31 (DEBUG `LL_REMOTE=1` overrides) | Not compiled into watchOS. |
| 24 | `captureSettings.stills.flatEnabled`, `captureSettings.video.flatEnabled` | `App/PhotoPreset.swift:1148-1150` | Bool · seeded from 25 | AS CV:29-31, 5870-5872; migration PhotoPreset:1167-1174 | UD `FlatCapture.isEnabled` :1156-1159 ← CC:8596, 9128, 9150, **9248 (per JPEG)** | **HOT** per still. |
| 25 | `capture.captureFlat` | PhotoPreset:1124 | Bool legacy | **never written** | PhotoPreset:1158, 1169 | UD. |
| 26 | `captureSettings.flatEnabled.migrated` | PhotoPreset:1161 | Bool · false | PhotoPreset:1173 | PhotoPreset:1168 | One-shot migration flag. |
| 27 | `letslapse.capture.dimDuringShoot` | `App/ShootScreenDimmer.swift:61` | Bool · true | AS SV:47, CV:54; UD CV:5521 (remote command) | AS; mirrored to the Watch as `dimDuringShoot` | Key kept through the "Blackout viewfinder" rename. |
| 28 | `letslapse.capture.reduceBrightness` | ShootScreenDimmer:62 | Bool · false | AS SV:48 | AS CV:55 | AS. |
| 29 | `letslapse.capture.peekEnabled` | :63 | Bool · true | AS SV:49 | AS CV:56 | AS. |
| 30 | `letslapse.capture.peekTrigger` | :64 | String `clock`(default) \| `interval` | AS SV:50-51 | AS CV:57-58 | AS. |
| 31 | `letslapse.capture.peekEveryMinutes` | :65 | Int · 5 | AS SV:52-53 | AS CV:59-60 | AS. |
| 32 | `letslapse.capture.holyGrail` | CV:120 | String · `off`; `off\|holyGrail\|scanner\|ladder` | AS | AS via `IntervalCaptureMode(token:)` | **Was a Bool**: `"true"/"1"` → holyGrail, `"false"/"0"` → basic (`Shared/CaptureMode.swift:73-82`). |
| 33 | `letslapse.capture.intervalAuto` | CV:130 | Bool · false | AS | AS | AS. |
| 34 | `letslapse.capture.scannerAspect` | CV:161; `App/ScannerProjectView.swift:31` | String aspect raw · `auto` | AS | AS + UD AM:1488 (`storedScannerPaper`), stamped into the manifest at registration :6696 | Mixed AS/UD. |
| 35 | `scanner.newScanIsNewDocument` | CV:181 | Bool · true | AS | AS | AS. |
| 36 | `letslapse.capture.psychoNoticeShown` | CV:238 | Bool · false | UD CV:3412 | UD :3411 | One-shot notice. |
| 37 | `capture.blendStrategy` | `App/DynamicBlendPolicy.swift:18` | String `BlendStrategyID` raw · `zone` | AS SV:43; UD CV:5513 (remote command) | UD DynamicBlendPolicy:20-23 ← CC:8850 (DNG run start); `App/WatchRemoteControlReceiver.swift:569` | **HOT**. Stamped into `capture_log.json`. |
| 38 | `capture.streamRate` | `App/CaptureStreamRate.swift:35` | String `auto\|reduced\|full` · auto | AS SV:1347 | UD :38 ← CC:7936 (run start) | **HOT**. |
| 39 | `capture.streamRate.autoEngagedRuns` | CaptureStreamRate:54 | Int · 0 | UD :62 ← CC:7884 (run end); reset SV:1359 | AS SV:1349; UD :61 | Learning counter. |
| 40 | `capture.streamRate.learnedReduced` | CaptureStreamRate:55 | Bool · false | UD :67 | AS SV:1348; UD :66 ← CC:7945, 7948 | **HOT**. |
| 41 | `letslapse.resolutions.hiddenStills` / `…hiddenVideo` | `App/ResolutionPreferences.swift:38-39` | [String] · [] | UD :54 | UD :47-48; CV:5865; `App/ManageResolutionsView.swift:8` | UD. |
| 42 | `letslapse.resolutions.displayRatiosStills` / `…Video` | :40-41 | Bool · false | UD :32, :35 | UD :49-50 | UD. |
| 43 | `letslapse.capture.costBytes` | `App/CaptureHeadroom.swift:129` | **Dictionary** `[ "<still\|raw\|movie\|proRes>/<w>x<h>@<fps>": Double ]` | UD :172 ← CV:2358 (run end); reset :176 | UD :140 ← :244 (headroom chip) | Half-and-half averaged. 8 entries on the iPhone. |
| 44 | `letslapse.burstResolutionEnabled` | `App/DeviceCapabilityMatrix.swift:63` (= `AM.DefaultsKey.burstResolution` :34) | Bool · false | UD AM:948 | UD DeviceCapabilityMatrix:69 ← CC:1887, 1905, 2794 | **HOT**. |
| 45 | `letslapse.deviceCapabilityMatrix.v2` | DeviceCapabilityMatrix:205 | **Data (JSON)** `{deviceModel, systemVersion, generatedAt (Double), validBurstOptions (struct-keyed → flat array), probedDeviceKeys}` | UD :230 (probe on miss) ← CC:1625, 2521; `invalidateCache` :241-243 (DEBUG `LL_RESET_CAPS`) | UD :216 | **HOT** (session configure). **411 KB on the iPhone, 32 KB on the Mac.** Valid only for the same model + OS + probed cameras. |
| 46 | `letslapse.deviceCapabilityMatrix` | DeviceCapabilityMatrix:206 | legacy v1 blob | removed at :235, :243 | **never read** | Shed on first v2 write. |
| 47 | `scheduledRecording` | `App/ScheduledRecording.swift:40` | **Data (JSON)** `{startDate (Double, seconds since 2001), intervalSeconds, durationMinutes?, blendDepth?, label?}` | UD :47-53 ← AM:960 (nil → remove) | UD :42-45 ← AM:959 | Singleton schedule; bare key by design. |
| 48 | `letslapse.camera.selectedDeviceID` | `App/CameraDevices.swift:55` (macOS) | String camera `uniqueID` | UD :51 | UD :85, :149 ← CC:209, 1958 | macOS only. **HOT**. |
| 49 | `letslapse.captureOptics.enhancedLenses` | `App/CaptureOptics.swift:120` | Bool · true | AS SV:68 (iOS) | UD :123 ← CC:316, 1894, 2114 | **HOT**. |
| 50 | `layout.scansMenuEnabled` | `App/LayoutSettings.swift:15` | Bool · true | AS SV:1309; UD `App/LetsLapseApp.swift:659` (DEBUG `LL_LAYOUT`) | AS LetsLapseApp:243, `App/ProjectsView.swift:56` | — |
| 51 | `layout.showsProjectCounts` | LayoutSettings:21 | Bool · false | AS SV:1310; UD LetsLapseApp:661 (DEBUG) | AS ProjectsView:57 | — |
| 52 | `letslapse.create.opensCamera` | LetsLapseApp:1482 | Bool · **per idiom** (iPhone true; iPad/Mac false, :1484-1490) | AS SV:55 | UD :1493 ← :471 | `object(forKey:)` so the idiom default holds until touched. |
| 53 | `projects.sortKey` | ProjectsView:67 | String `capture\|edit\|size` · `capture` | AS | AS | AS. |
| 54 | `projects.sortAscending` | ProjectsView:68 | Bool · false | AS | AS | AS. |
| 55 | `gallery.columnCount` | `App/CapturePhotoGrid.swift:18` | Int · 3 | AS | AS | Shared by every grid. |
| 56 | `scanner.motionThreshold`, `scanner.settleDelay`, `scanner.cornerThreshold`, `scanner.documentThreshold` | `App/ScannerEngine.swift:304-333` | Double · unset | **never written by the app** (launch arguments `-scanner.x v`) | UD, `#if DEBUG` only | Field-tuning levers. |
| 57 | `scanner.aspectTolerance` | `App/RectangleDetector.swift:190-193` | Double · unset | never written | UD, `#if DEBUG` only | — |
| 58 | `letslapse.ladder.evAlwaysVisible` | `App/LightLaddersView.swift:153` | Bool · false | AS | AS | AS. |
| 59 | `letslapse.fieldnotes.customIssueLabels` | `App/FieldNotes/FieldNoteFlowView.swift:18` | [String] · [] | UD :34 | UD :23 | Append-only, case-insensitive dedup. |
| 60 | `ai.activeModelID` | `App/AI/ModelManager.swift:154` | String? · nil | UD :145 (didSet unloads the analyser) | UD :159; :309, :339, :498; `App/AI/AIModelsView.swift:94, 126` | — |
| 61 | `rawDecodePath` | `Kit/…/Grading/RawDecodePath.swift:71`; `App/RawDecodePath.swift:16` | String `bradford\|forwardmatrix\|ciraw\|dcp` · `bradford` | UD Kit:88 (via App:23, 58); AS SV:56-57; CLI main.swift:414 (own domain) | UD Kit:80-87 ← `App/PhotoPreset.swift:628, 646, 984, 1110` (every raw decode, editor path); `lapse` PosterCommand:28, GradeCommand:73, 109 | Unavailable stored value → default. |
| 62 | `blend.outputFormat` | AM:4331 | String `h264`(default) \| `hevc10` | AS SV:32 | UD AM:4334 ← :4490, 4627, 5414, 6141 | — |
| 63 | `letslapse.constantWindow` | AM:16 | Int · falls back to 64, then 100 | UD :859 | UD :856 | — |
| 64 | `letslapse.defaultSpeed` | AM:23 | Int · 100 | UD :862 | UD :861, :857 | — |
| 65 | `letslapse.outputFPS` | AM:17 | Int · 25 | UD :913 | UD :912 | — |
| 66 | `letslapse.linearLight` | AM:18 | Bool · true | UD :916 | UD :915 | — |
| 67 | `letslapse.trimVideoEnds` | AM:19 | Bool · false | UD :919 | UD :918 | — |
| 68 | `letslapse.trimHeadTailSeconds` | AM:20 | Double · 1 | UD :922 | UD :921 | — |
| 69 | `letslapse.burstRampDefault` | AM:32 | Double? · nil (≤ 0 → removed) | UD :932/:934 | UD :929 | — |
| 70 | `letslapse.burstRampRememberLast` | AM:33 | Bool · false | UD :942 | UD :941 | — |
| 71 | `letslapse.maxCPUWorkers` | AM:21 | Int · `max(1, cores − 2)` | UD :986 | UD :985 | Mac runner. |
| 72 | `letslapse.maxBlendBatches` | AM:22 | Int · 2 | UD :989 | UD :988 | — |
| 73 | `letslapse.scratchFrameFormat` | AM:24 | String `png\|jpeg\|heic` · png | UD :998 | UD :995-997 | — |
| 74 | `letslapse.liveBlendOutputFormat` | AM:28 | String `standard`(= jpeg, default) \| `dng` | UD :1008 | UD :1005-1007 | Pre-merge key name kept. |
| 75 | `letslapse.liveBlendResponsiveCapture` | AM:29 | Bool · false | UD :1018 | UD :1017 | DNG A/B toggle. |
| 76 | `letslapse.liveBlendBurstCapture` | AM:30 | Bool · true | UD :1021 | UD :1020 | — |
| 77 | `letslapse.liveBlendBracketedRAW` | AM:31 | Bool · true | UD :1024 | UD :1023 | — |
| 78 | `letslapse.keepExtractedFrames` | AM:25 | Bool · false | UD :1031 | UD :1030 | Mac runner. |
| 79 | `storage.libraryRootPath` | `App/StorageLocation.swift:19` (macOS) | String absolute path · nil (= default root) | UD :76 / remove :74 (`commit` ← StorageMover:201), remove :85 (`forgetCustomPath`); `synchronize()` :385 before relaunch | UD :48 → `current`, latched once :56-67 | macOS only. Unreachable → default root for the session, setting kept. **Domain-split** between sandboxed and unsandboxed builds (R7). |
| 80 | `letslapse.pairingqr.cameraID` | `App/PairingQR.swift:135` | String camera `uniqueID` | UD :210 | UD :297 | QR-scanner camera choice. |
| 81 | `transfer.sharingEnabled` | `Shared/ProjectTransferServer.swift:36` | Bool · false | AS SV:40 | AS ProjectsView:77; UD :39 | — |
| 82 | `transfer.rememberedCodes` | `Shared/ProjectTransferClient.swift:831` | **Dictionary** `[ pairingID (12-hex of SHA-256(code)) : "<6 digits>" ]`, cap 8 | UD :850 (`remember`), :856 (`forget`) | UD :860 | The only persisted pairing material; plain text; inert once the camera's code rotates. 8 entries on the Mac, 2 on the iPhone. |
| 83 | `letslapse.watch.burstDefaultSeconds` | `Remote/WatchControlView.swift:48` | Int · 1 (0 = none) | AS | AS | **watchOS** target's only key. |

Confirmed absent: Keychain / `SecItem*`, `NSUbiquitousKeyValueStore`, `UserDefaults(suiteName:)`, app groups, `@SceneStorage`, `register(defaults:)`. `CameraPrivacySettings.swift` and `CaptureRemotePairing.swift` persist nothing (the PSK is re-derived from the code; `generateCode` is `UInt32.random`). The `DeviceCapabilityProfile` from the Auto-interval probe is in-memory only (`App/DynamicBlendPolicy.swift:145-167`); `"com.letslapse.capability.profile"` is a queue label, not a file.

---

## Appendix C — watchOS persistence

| Store | What |
|---|---|
| `UserDefaults` | one key, #83 above |
| `WCSession.receivedApplicationContext` | The phone pushes its full state snapshot on every `publishState()` (`App/WatchRemoteControlReceiver.swift:636-662`, off-main). Both OSes persist the latest context on disk; the watch reads it at activation as `storedState` and seeds the UI from it (`Shared/WatchConnectivityTransport.swift:30-36, 79-89`; `Remote/WatchCaptureRemote.swift:1323-1338`). Keys (from `Shared/WatchMessageKey.swift`): `recordingState, markerCount, rampIntervalCount, segmentCount, isRampActive, isRampHighRate, isMarkActive, markIntervalCount, cameraActive, phoneAppState, dimDuringShoot, captureFPS, baseFPS, rampFPS, availableBurstFPS, availableBaseFPS, plannedSpeed, outputFPS, captureMode, intervalSeconds, framesPerBlend, blendDepth, blendStrategy, isBulbMode, captureCount, intervalMode, intervalAuto, phoneFlow, isExposureLocked, lockedISO, lockedShutter, lockedLensPosition, isoMin, isoMax`; conditionally `recordingStartedAt, sequenceMode, formatLine, holyGrail*, scanner*, stopAtUnit, stopAtDeadline, stopAtTargetCount, flowTitle, flowStep, flowStepCount, export*, lastCaptureAt`. The preview image travels only in messages and is not persisted. |
| Files | none (no `FileManager`, `transferFile`, `transferUserInfo`, keychain in `Remote/` or `Watch/`) |

Lost on a watch-app kill: every mirrored `@Published` value (re-seeded from the last context, then refreshed live), any in-flight command's outcome, the controls-lock and crown-unlock state, un-committed picker selections, the keep-awake runtime session. Not lost: the burst default, and everything that lives on the phone (the schedule, the shoot, `stopAt*`).
