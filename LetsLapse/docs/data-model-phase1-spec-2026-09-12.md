# Data model Phase 1 — implementation spec

**Date:** 2026-09-12 · **Status:** spec, agreed scope, not started · **Parts it implements:** [Part 1 §7 Phase 1](data-model-audit-2026-09-06.md), [Part 3 §12 row 1](data-model-server-portability-2026-09-12.md) · **Branch:** `ios-app` at 408737d; line numbers below are from that tree

Phase 1 is the additive, server-ready groundwork that changes no on-disk layout a current build cannot read: stable identity, content hashes, revision and tombstone fields, one persist path, a crash-safe experiment log, the manifest's fourth migration, and the audit tool that verifies all of it. No per-project `project.json` yet (Phase 2), no SQLite (Phase 3), no server.

---

## 1. Outcomes

After Phase 1, on every device:

1. Every project carries an `originID` that survives export, transfer and clone; every device has a `deviceID`; duplicate detection matches by origin.
2. Every source frame and blend output has a SHA-256 content hash, recorded per project in `assets.ndjson`.
3. Every edit-class record has `revision`, `modifiedAt`, `modifiedBy`; deletion writes a tombstone and moves files to `Projects/.trash/` instead of removing them.
4. `library.json` has exactly one writer path, version-gated, with errors surfaced; an undecodable manifest is set aside, never overwritten.
5. The live-blend experiment log is append-only during a run.
6. `capture_log.json.sessionID` equals the project's origin id.
7. `lapse audit <root>` reports every inconsistency Part 1 found by hand, and reports zero of them on both real libraries.

Nothing in Phase 1 renames a project folder, moves `Projects/`, or touches a media file.

---

## 2. Work items

Ordered as they should land. Each names its touch points, the on-disk change, and its acceptance test.

### W1 · `lapse audit` (the instrument, first)

New command in `Kit/Sources/lapse/main.swift` (`case "audit"`), implemented in `Kit/Sources/LetsLapseKit/Library/LibraryAudit.swift` over plain JSON (`JSONSerialization`), so it needs no App types and runs against any root, including a device copy pulled with `devicectl`.

Reports, per root: capture/blend/collection counts and `gradingSchemaVersion`; folders under `Projects/` with no record; records with no folder; listed `sourceFileNames` missing on disk; media in `source/` not listed; `.json` names inside `sourceFileNames`; blend files unlisted and blend records whose file is missing; sidecar presence per project (`frames.timestamps`, `frames.exposure`, `capture_log.json`, `sequence.json`, `framing.json`, `overlays.json`, `notes/`, `shapes.json`, `dng-archive.json`, `assets.ndjson`); origin-id coverage (present, distinct, `importedFromID` chains); tombstones and `.trash` contents; hash coverage (hashed / total, bytes). `--json` for machines; exit 0 when consistent, 1 otherwise.

Acceptance: run on `/Volumes/letslapse` reproduces Part 1 Appendix A's numbers (3 orphan folders, 1 record over an empty folder, 7 unlisted renders, 77 `.json` names) before any other work item; after W7 and the repairs it reports zero of the last two.

### W2 · Device identity

`Shared/DeviceIdentity.swift`: `static let id: UUID`, read from `UserDefaults` key `letslapse.deviceID`, minted and written on first access, never changed. Add the key to Appendix B of Part 1.

Known consequence: on the Mac the unsandboxed Debug build and a sandboxed build read different preference domains (Part 1 R7) and will hold different device ids. They are different installs; accept it.

Acceptance: two launches read the same id; `lapse audit` prints it from the device's plist copy.

### W3 · Project identity

`App/AppModel.swift`, `CaptureProject` (fields at 108–330): add

```swift
var originID: UUID?            // the shoot's identity on every device; nil only before the v4 migration
var originDeviceID: UUID?      // which install first registered it
var derivedFromOriginID: UUID? // DNG-archive clones: the parent's originID
```

Accessor `AppModel.originID(of:) -> UUID` = `originID ?? importedFromID ?? id` for the transition; every new site uses it, not the field.

Touch points:

| Site | Change |
|---|---|
| registration mints: 6714, 6871, 7043, 7323, 7467 (`let id = UUID()`) | pass `originID: id, originDeviceID: DeviceIdentity.id` to the `CaptureProject` init |
| DNG clone 7397–7401 (`clone.id = id`, `clone.importedFromID = nil`) | `clone.originID = id; clone.originDeviceID = DeviceIdentity.id; clone.derivedFromOriginID = originID(of: source)` |
| install 8752–8754 (`let newID = UUID()`, `capture.importedFromID = originID`) | keep `capture.originID = manifest.capture.originID ?? originID` (the archive's own capture id when the sender predates W3); keep `originDeviceID` as sent; `importedFromID` as today |
| `existingImport(of:)` 8569, `hasImported` 8582 | match `originID(of: $0) == originID` first, then the legacy `id ==` / `importedFromID ==` |
| `Shared/ProjectTransferProtocol.swift` `PTProjectInfo` (264–272) | add `var originID: UUID?`; server side (`ProjectTransferServer`) fills it; "Hide imported" uses it. Optional, so old and new builds interoperate |
| `App/ProjectArchive.swift` `ProjectArchiveManifest` | unchanged (`formatVersion` stays 1; the new optional fields ride inside `capture`; older readers ignore unknown keys) |

Folder naming is **not** changed in Phase 1: the folder stays the local `id` (Part 3 §10.3 applies to server-arrived projects, Phase 6).

Acceptance: export a project to `.lapse`, import it on the same device → the duplicate prompt fires by origin; transfer Mac → iPhone → Mac → `originID` identical on both ends and `lapse audit` shows one distinct origin per shoot.

### W4 · Manifest migration v4, applied to JSON before decoding

New `Kit/Sources/LetsLapseKit/Library/ManifestMigrations.swift`:

```swift
public enum ManifestMigrations {
    public static let current = 4
    /// Runs every step whose version is above the manifest's, on the raw JSON object,
    /// and returns the migrated bytes plus a human log. Never throws on missing fields.
    public static func apply(to data: Data, projectFolder: (String) -> URL?) throws -> (Data, log: [String])
}
```

`AppModel.loadLibrary()` (7620) calls it before `JSONDecoder`. The existing in-Swift migrations (`stampLegacyDefaultPresetsIfNeeded` 7664, `stampPresetStatesIfNeeded` 7681, `stampAddedDatesIfNeeded` 7706) stay as they are for v1–v3; v4 is the first JSON-level step and the pattern for every later one, because a migration that runs on JSON cannot be broken by a strict decoder.

Step 4, for every `captures[]` entry:

1. `originID` absent → `originID = importedFromID ?? id`.
2. `derivedFromOriginID` absent and `<folder>/dng-archive.json` exists with a `sourceProjectID` that is a capture in this manifest → `derivedFromOriginID = originID(of: that capture)`; otherwise leave absent.
3. remove every `sourceFileNames` entry ending in `.json` (the misregistered experiment logs; 77 on the Mac, 10 projects on the iPhone). The ten `.hasSuffix(".json")` filters in `AppModel.swift` stay for one release, then go.
4. set `gradingSchemaVersion = 4`. The key keeps its misleading name: renaming it would break every manifest on disk; it is documented as the general migration counter.

Persist once after a migration ran, as v1–v3 do (through W6).

Acceptance (Kit tests, `ManifestMigrationsTests`): a synthesised v3 fixture with the real key shapes (Part 1 §3.1) → the expected v4 bytes; a v4 fixture passes through unchanged; a manifest with a `.json` frame loses it; an entry with `importedFromID` gets it as `originID`; an entry with a matching `dng-archive.json` gets `derivedFromOriginID`; random removal of any optional key never throws; an unknown future version passes through untouched.

### W5 · Content hashes into `assets.ndjson`

`Kit/Sources/LetsLapseKit/Library/AssetHash.swift`: streaming SHA-256 with CryptoKit (already linked: `App/ProjectThumbnailCache.swift`, `Kit/…/Grading/CubeLUT.swift`), 1 MB chunks, result `"sha256:<64 hex>"`.

`Kit/Sources/LetsLapseKit/Library/AssetRecords.swift`: the per-project `Projects/<id>/assets.ndjson`, one line per asset, appended and compacted, the same reader tolerance as `frames.timestamps`. Phase 1 writes only what it knows:

```json
{"name":"source/frame-00042.dng","bytes":10618796,"hash":"sha256:…","hashedAt":"2026-09-12T08:31:02Z"}
{"name":"blends/2D3E4F50-….mp4","bytes":8123456,"hash":"sha256:…","hashedAt":"…"}
```

Phase 2 adds the metadata layers to the same lines. Latest line per `name` wins; `compact()` rewrites through a temp file and `replaceItemAt`, only at idle.

Where hashes are computed: at registration after the copy into `source/` (the five sites in W3), at `storeBlend` after the copy into `blends/`, and by `HashBackfill`, a launch-time background task (utility QoS, one file at a time, resumable, paused on thermal `serious` or low power) for projects whose `assets.ndjson` is incomplete. The 431 GB Mac volume backfills in hours; the phone in minutes.

Decision recorded: **whole-file SHA-256** in Phase 1. Our DNG writer does not emit `NewRawImageDigest`, Lightroom is being retired, and the whole-file hash is what an upload verifies. An image-data digest can be added as a second field later without a migration.

Add `assets.ndjson` to `ProjectArchive.transferableFiles` (`App/ProjectArchive.swift:56`), the registration copy list, and the DNG-clone copy list (the clone rewrites frame names, so it re-hashes rather than copies).

Acceptance: `AssetHashTests` with a known vector; `AssetRecordsTests` round trip, torn last line, compaction; `lapse audit` hash coverage reaches 100 % on the iPhone copy after one backfill.

### W6 · One persist path

Replace `persistLibrary()` (7717) and `persistLibraryOffMain()` (9272, queue at 9270) with one `LibraryPersister`:

- a serial queue (utility QoS); every call snapshots the manifest on the main actor with a monotonically increasing `localVersion` and enqueues;
- the queue drops any snapshot whose `localVersion` is lower than the last one written (this is the R3 fix);
- `persist(reason:)` where `reason ∈ {filesChanged, valuesChanged}` decides whether the size and existence caches are cleared (today `persistLibrary()` always clears them, `persistLibraryOffMain()` never does);
- `persistAndWait()` for callers that need durability before continuing (deletes, registration, install);
- every failure is logged through `LLog` **and** surfaced once per session in `errorMessage`; no `try?`;
- `flushLibraryPersists()` (9291) stays and is also called from `applicationWillTerminate` (macOS) and scene phase `.background` (iOS) in `App/LetsLapseApp.swift`.

Acceptance: `VersionGateTests` in the Kit on the pure gating type (older snapshot after newer is dropped; equal is dropped; newer is written); on device, a grade drag followed immediately by a blend delete leaves the manifest without the blend.

### W7 · The undecodable-manifest guard

In `loadLibrary()` (7620): on decode failure, set `libraryLoadFailed = true`, move the file to `library.json.unreadable-<stamp>`, keep the in-memory library empty, and make `LibraryPersister` refuse every write while the flag is set, logging why. Show the existing `errorMessage` plus a banner naming the set-aside file. This closes Part 1 R1 until Phase 4's rebuild-from-folders replaces the banner with a repair.

Acceptance: corrupt a manifest byte on the simulator, launch, capture a photo → the set-aside file is untouched and no new manifest is written.

### W8 · Revisions and modification stamps

On `CaptureProject`, `BlendProject`, `LapseCollection`:

```swift
var revision: Int?        // server-assigned later; absent means 0; never bumped locally in Phase 1
var modifiedAt: Date?     // exists on CaptureProject; add to the other two
var modifiedBy: UUID?     // DeviceIdentity.id, stamped wherever modifiedAt is
```

Stamp `modifiedBy` at every site that stamps `modifiedAt` (grep `modifiedAt =` in `AppModel.swift`; Part 1 §3.1 lists the human-edit sites) and add `modifiedAt`/`modifiedBy` stamps to blend and collection mutations (`mutateCollection`, `setDefaultCrop`, blend-level edits). Per-field `editedAt`/`editedBy` maps are **not** added in Phase 1; they arrive with the per-asset metadata records in Phase 2, where per-field ordering matters, and the journal (Phase 5) orders `project.json` fields.

Acceptance: every mutation path in the Part 1 §1 persist table leaves `modifiedBy == DeviceIdentity.id` on the record it changed (checked by a sim run plus `lapse audit --json`).

### W9 · Tombstones and `.trash`

On the same three types: `deletedAt: Date?`, `deletedBy: UUID?`.

| Path | Today | Phase 1 |
|---|---|---|
| `deleteCapture` 1764 | `removeItem(folder)` then persist | stamp tombstone → `persistAndWait()` → `moveItem` folder to `Projects/.trash/<id>/` → persist |
| `deleteBlend` 1786 | remove file then persist | stamp → `persistAndWait()` → move `blends/<id>.*` to `.trash/<captureID>/blends/` → persist |
| `deleteCollection` 1861 | remove render folder then persist | stamp → `persistAndWait()` → move render folder to `.trash/collections/<id>/` |
| `deleteEncoding` 8121 | remove file then persist | persist first, then remove (derived file; no tombstone) |
| `deleteScanPage` 1713 | rewrite sidecar, remove files | persist first; otherwise unchanged (structural; a lease-class op in Phase 5) |

`loadLibrary` splits tombstoned records into `deletedCaptures`, `deletedBlends`, `deletedCollections`; the live arrays are unchanged, so every view, export and transfer keeps excluding them for free. `persistLibrary` writes both sets. A launch sweep moves any folder whose record is tombstoned but which still sits under `Projects/` into `.trash` (the crash window). `sweepStaleArchiveStaging` (7271 in the audit tree) and the storage walk ignore `.trash`; the storage card reports it as its own line. Purge: Settings ▸ Storage gains an "Empty trash" row and a 30-day auto-purge at launch; both remove the tombstone records too.

Design-sync: the Settings row and the W7 banner are UI and need their SVG mirrors (see `docs/design/README.md`).

Known transition effect: a build older than Phase 1 reading a v4 manifest shows tombstoned projects as live, since it does not know `deletedAt`, and their folders are in `.trash`, so they render as missing. Acceptable for the transition; noted here so it is not mistaken for data loss.

Acceptance: delete a project, quit, relaunch → gone from the list, present in `.trash`, tombstone in the manifest; kill the app between the stamp and the move → the launch sweep finishes the move; Empty trash removes folder and record.

### W10 · Project id at run start; `sessionID` = origin id

Today the project id is minted at registration (W3's sites) after the run, and each blend controller's configuration defaults `sessionID = UUID().uuidString` (`App/LiveBlendController.swift:325`, `App/LiveBlendRawController.swift:72`).

Change: the capture screen mints `pendingProjectID = UUID()` when a run starts and threads it into the controller configurations (`CameraController.swift` sites building them, 8568/8837 in the audit tree) as `sessionID`, into the experiment-log header as `originID`, and into the capture session log's `capture_start` payload as `projectID`; registration uses the pending id as the project's `id` and `originID`. Imports already use the project id (`AppModel.swift` import path, `captureSession(sessionID:)`).

Acceptance: after an interval run, `capture_log.json.sessionID == capture.id.uuidString == originID`; an orphaned `CaptureLogs/*.log` carries the `projectID` that names its staging folder.

### W11 · Experiment log to NDJSON

`Logs/liveblend-<stamp>.ndjson`: a `{"kind":"header",…}` line at start, one `{"kind":"output",…}` line per window (append, no rewrite), a `{"kind":"summary",…}` line at finish. `rewriteLog()` (`LiveBlendController.swift:1360`, `LiveBlendRawController.swift:1557`) becomes `appendOutput()`; the per-output callers (1139, 1116) append; the finish callers (1260, 1465) append the summary **and** write the legacy document `liveblend-<stamp>.json` once, so `shoot.py` and `tools/blend_compare.py` keep reading what they read today; the in-project copy stays the document. A shared `NDJSONWriter` in the Kit (`Kit/…/Library/NDJSONWriter.swift`) replaces the three hand-rolled appenders (`FrameTimestampWriter`, `CaptureExposureWriter`, `CaptureSessionLogger`'s) over time; Phase 1 introduces it for this log only. Prune `Logs/liveblend-*` and `Logs/ladder-*` to the newest 50 at launch, as the console log already does.

Acceptance: `ExperimentLogTests` round trip document ↔ lines and a torn last line; on device, bytes written during a run are linear in outputs (check with `fs_usage` or the file's size against outputs); a run killed mid-way leaves a parseable `.ndjson` with every completed window.

### W12 · Housekeeping carried from Part 1 (separate, optional in Phase 1)

Mac job folders to a hidden `.jobs/` sibling with relative paths in the manifest (R17, R19); model weights under a branded path (R20); a launch sweep for `.gps-backup` leftovers (R21).

---

## 3. On-disk result

| Location | Before | After Phase 1 |
|---|---|---|
| `Projects/library.json` | schema 3 | schema 4; new optional keys `originID`, `originDeviceID`, `derivedFromOriginID`, `revision`, `modifiedBy`, `deletedAt`, `deletedBy` on captures/blends/collections; `modifiedAt` on blends/collections; no `.json` in `sourceFileNames`; tombstoned records kept |
| `Projects/<id>/assets.ndjson` | — | one line per source frame and blend output: name, bytes, hash, hashedAt |
| `Projects/.trash/<id>/` | — | deleted projects and blend files until purged |
| `library.json.unreadable-<stamp>` | — | only after a failed decode |
| `Logs/liveblend-<stamp>.ndjson` | — | the crash-safe run log; the `.json` document is written once at finish |
| `UserDefaults` `letslapse.deviceID` | — | the per-install id |

Every file above is readable by the current build (unknown keys are ignored by synthesized `Codable`; new files are simply unknown to it), with the tombstone caveat in W9.

---

## 4. Tests

Kit (`Kit/Tests/LetsLapseKitTests/`), all runnable with `swift test` and by the `run-letslapse` skill:

- `LibraryAuditTests` — a synthetic tree with every inconsistency class; expected report.
- `ManifestMigrationsTests` — the W4 cases; fixtures under `Tests/Fixtures/manifests/` synthesised from the real key shapes (Steven decides whether a redacted copy of a real manifest joins them).
- `AssetHashTests`, `AssetRecordsTests`, `NDJSONWriterTests`, `ExperimentLogTests`, `VersionGateTests` — as in the work items.

App: there is no app unit-test target today (Part 1 §1). Recommended: add `LetsLapseTests` (a unit-test bundle hosted by the app) for the tombstone flow, the W3 install path and the W10 id threading; until it exists, those are covered by the simulator recipe in `run-letslapse` plus `lapse audit` on the sim's container.

Device: one Release-build interval run on the iPhone 16 Pro (per `CLAUDE.md`, Release is the field-test build) checking W10, W11's linear write volume, and W5's backfill pause under thermal pressure.

---

## 5. Verification, before and after

1. `lapse audit /Volumes/letslapse --json > before.json` and the same on a `devicectl` copy of the iPhone container.
2. Land W1–W11.
3. `lapse audit` again: counts equal; `.json` names 0; every capture has a distinct `originID`; 75 Mac imports carry `originID == importedFromID`; hash coverage rising to 100 % after the backfill; no new orphans.
4. Round trips: `.lapse` export/import on one device (duplicate detected by origin); Mac → iPhone → Mac transfer (origin preserved).
5. A killed interval run leaves a readable `.ndjson`; a deleted project is in `.trash` and absent from every list, export and transfer.

---

## 6. Order and size

W1 (audit) → W2 + W3 + W4 (identity and migration, one change) → W6 + W7 (persist) → W9 (tombstones) → W8 (stamps) → W5 (hashes, background) → W10 → W11 → W12. Roughly: W1–W4 a few days; W6–W9 a few days; W5, W10, W11 a day or two each. Every step is shippable alone.

## 7. Risks

- **W10 touches the capture path.** Judge it from a Release build on a device, never from Debug (Kit at `-Onone` distorts the live pass).
- **W5's backfill on the Mac volume** reads 431 GB over USB; it must be idle-only and resumable or it will fight a shoot.
- **W9 and older builds** (see the W9 note).
- **W4's `.json` cleanup** changes `sourceMediaCount` on affected projects by one; that is the correction, not a regression.
- **The ten `.json` filters** must outlive W4 by one release, then be removed, or a downgraded build re-registers nothing wrong but a newer one keeps dead code.
