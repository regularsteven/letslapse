# Data model — the switch: documents as the truth, SQLite as the index, `library.json` retired

**Date:** 2026-09-13 · **Status:** brief for the next agent, agreed scope, not started · **Branch:** `ios-app` at 6ca7c64 · **Builds on:** Phases 1–4 and the Lightroom tool, all landed today (commits 7fd0a0a → 6ca7c64, one per work item)

This is the handover for the milestone the audit programme has been building towards: the app stops treating `Projects/library.json` as the library and starts treating each project's own files as the truth and the SQLite index as the way it finds them. Everything below the fold is either done and verified, or named here as work with an acceptance test.

---

## 0. Are we in shape? Yes — here is the evidence

| Precondition for the switch | State on 2026-09-13 | Proof |
|---|---|---|
| Every project has a complete, current document on disk | `Projects/<id>/project.json` written on every persist, 366 of 366 on the Mac, 518 of 518 on the iPhone 16 Pro | `lapse audit /Volumes/letslapse --rebuild-index` → **REBUILD IDENTICAL**; the phone's first-launch console: `reconciled 519 written · 0 failed` |
| The manifest can be reproduced from the folders alone | `LibraryIndexRebuild.rebuiltManifest` + `Collections/collections.json`; the app already does this when `library.json` will not decode | corrupted-manifest test: all 258 records, 140 blends and the collection came back; `docs/data-model-audit-reports/mac-rebuild-index-2026-09-13.txt` |
| An index exists, is rebuildable, and is kept current | `Index/library.sqlite` (`LibraryIndex`), rows for 366 projects / 140 blends / 57,052 assets, FTS5 | `lapse index /Volumes/letslapse --verify` → **CONSISTENT**; delete-and-rebuild equality is a Kit test |
| One writer, version-gated, on one queue | `LibraryPersister` (W6) → documents → index rows | Phase 1 W6 + Phase 2 W1 |
| Two instances cannot write one library | `Projects/.lock` on macOS, read-only banner for the second | Phase 4 W7 |
| Identity survives a hop | `originID` on every record, duplicate detection by origin | Phase 1 W3; 105 projects imported from the phone today with their origins and hashes |
| The real libraries are on the new format | Mac: schema 4, hashes 100 %, `.json` names 0. iPhone 16 Pro: new build launched, documents + index built | `mac-after-phone-import-2026-09-13.txt`; the iPhone launch log in this session |

What is **not** in place, and is the work of this brief: the app still *loads* `library.json` into three arrays and every screen reads those arrays.

---

## 1. Read first, in this order

1. `docs/data-model-audit-2026-09-06.md` (Part 1) — §2–§5 the inventory and risks; **§6.2** the "split the manifest" recommendation; **§7 Phase 3** ("`library.json` is rewritten as the index … the app reads `project.json` on project open") and Phase 4.
2. `docs/data-model-scale-and-metadata-2026-09-12.md` (Part 2) — **§5** the measurements that decide SQLite ("`AppModel.captures` stops being the library and becomes a window over queries; lists take pages; search is FTS5; filters are WHERE clauses"); **§8** the amendment that the index is SQLite from the start.
3. `docs/data-model-server-portability-2026-09-12.md` (Part 3) — **§2** the class of every store (what syncs, what is cache); **§3.2** the `apply(change)` funnel (the shape every mutation must take); **§10** Steven's decisions (the truth stays per-project JSON — a server stores the documents verbatim); **§12** the build order (this brief is row 3's second half plus row 5).
4. `docs/data-model-phase1-spec-2026-09-12.md` — the work-item format that every commit since has followed (touch points, on-disk change, acceptance test).
5. `docs/TODO.md` — the two data-model entries ("Data model — split `library.json`…" and "Asset metadata…") carry the landing text for every phase and the owed list.
6. `docs/letslapse-app-overview.md` §4.13 — the storage tree as it is now and the launch sequence.
7. `docs/data-model-audit-reports/README.md` — the before/after reports and the three commands to re-run.
8. Repo-root `CLAUDE.md` — the design-sync requirement (any UI change) and the device rules.

---

## 2. What exists today (the ground this stands on)

| Piece | Where | Notes |
|---|---|---|
| The one writer | `App/LibraryPersister.swift` | serial queue, `VersionGate`, `refuseWrites` (W7 + lock), `reconcileDocuments` at launch, `onManifestWritten` |
| The document writer | `App/ProjectDocumentWriter.swift` | `ProjectDocument {formatVersion 2, capture, blends}`, `CollectionsDocument`; Equatable diff → rewrites only what changed; feeds the index; never creates a folder |
| Document format | `Kit/…/Library/ProjectDocument.swift` | name, format, `dateKeys`, ms-ISO-8601 coding (a format-1 archive still decodes) |
| Rebuild + diff | `Kit/…/Library/LibraryIndexRebuild.swift` | `run(root:)` (the acceptance instrument), `rebuiltManifest(root:)` (what the repair writes), `canonical`, `differences` |
| The index | `Kit/…/Library/LibraryIndex.swift`, `SQLiteDatabase.swift` | schema v1: `projects`, `blends`, `assets`, FTS5 `search`; `rebuild`, `upsertProject(documentData:)`, `reindexAssets`, `removeProject`, `projects(query)` (paged), `project(id:)`, `search`, `tagCounts`, `verify` |
| The app's index maintenance | `ProjectDocumentWriter` (documents → rows), `App/AssetRecordStore.swift` (`index`, `reindex(projectFolder:)` once per job) | `AppModel.libraryIndex` exposes it; **nothing on screen reads it yet** |
| Load / repair / adoption / lock | `App/AppModel.swift` `loadLibrary`, `repairManifestFromDocuments`, `reconcileFoldersAtLaunch`, `recoveredCapture`, `acquireLibraryLock`, `checkManifestUnchangedSinceLastSeen`; `App/LibraryLock.swift` over Kit `LibraryLockRecord` | launch order in `AppModel.init`: lock → load → adopt folders → sweep trash → documents/index pass → asset backfill |
| Per-asset records | `Kit/…/Library/AssetRecords.swift`, `App/AssetRecordStore.swift` | `assets.ndjson` (hash + imported/edited metadata), `metadata.json`; the panel reads the store, not the index |
| Identity, migrations, tombstones, stamps | Phase 1 (`Shared/DeviceIdentity.swift`, `Kit/…/ManifestMigrations.swift`, `.trash`, `revision/modifiedAt/modifiedBy`) | `ManifestMigrations` runs on the manifest JSON before decode — it will have to become a per-document migration (§4 M4) |
| Tools | `lapse audit [--rebuild-index --out]`, `lapse project-diff`, `lapse index [--rebuild --verify --list --search]`, `lapse import-lightroom` | all JSON-level; run on any root, including a `devicectl` copy |
| Verification rig | `.claude/skills/run-letslapse` (`driver.py build mac|sim|device`, `mac`, `deploy`); the Debug Mac app takes `-storage.libraryRootPath <scratch>`; DEBUG hooks `LL_IMPORT_ARCHIVE`, `LL_EXPORT_ARCHIVE`, `LL_DELETE`, `LL_IMPORT_STILLS` | scratch roots: copy `library.json` over `mkdir`'d folder skeletons for scale, or copy a few small real projects for media |

Scale of the read side to move (counted 2026-09-13): `captures` is referenced **327 times in 36 files**, `blends` 139, `collections` 74; `captures.first { $0.id == … }` lookups 77; persist call sites 47 in `AppModel.swift` (11,262 lines across `AppModel*.swift` + `CollectionsModel.swift`).

---

## 3. What "retire the JSON" means here — and what stays JSON by decision

Retire:
- **`Projects/library.json` as the thing the app loads and trusts.** After this brief it is at most a generated compatibility export, then gone.
- **The whole-library-in-memory model**: `AppModel.captures`, `blends`, `collections` (and their `deleted*` twins) as arrays every view filters and sorts.
- `LibraryManifest`, the manifest-level `ManifestMigrations` step, `gradingSchemaVersion` as a library-wide counter, the ten `.hasSuffix(".json")` filters (14 sites today, `grep -rn 'hasSuffix(".json")' App Shared`).

Keep — these were decided, not defaulted (Part 3 §10, §12; Part 1 §6.3):
- **Per-project JSON is the truth**: `project.json`, `assets.ndjson`, `metadata.json`, and every capture-time sidecar. A server stores these documents verbatim; a person can open a folder and read it. SQLite is the *index*: a cache, rebuilt from the files, deleted without loss. Do not move any record's truth into the database.
- `Collections/collections.json` as the collections' truth (collections span projects).
- The `.lapse` archive and the LAN transfer as they are (they carry the document).
- `Projects/` flat, folders never renamed or moved (Lightroom's root folders point into them; Part 2 §6).

---

## 4. The work — milestones in order, each shippable alone

### M1 · The truth flips (small, safe, first)

`loadLibrary()` reads the **documents** — `LibraryIndexRebuild.rebuiltManifest`-shaped, i.e. every `Projects/<id>/project.json` (live and `.trash`) plus `Collections/collections.json` — and no longer decodes `library.json`. The three arrays stay for now. `library.json` becomes a **generated compatibility export** written at the end of each persist exactly as today (so an older build, the transfer server's catalogue, and `lapse audit` keep working), marked in its root with `"generated": true`. A missing `library.json` is regenerated at launch; an undecodable one is ignored (the set-aside banner story becomes "regenerated").

Acceptance: `lapse audit --rebuild-index` stays IDENTICAL on the real Mac library; delete `library.json` on a scratch root → the next launch shows the same list and regenerates the file; the rebuild's per-record canonical diff between the pre-switch manifest and the post-switch export is empty; launch time on the iPhone 16 Pro at 518 projects is measured and logged (reading 518 small files should be well under a second; if it is not, the index's `projects` table is the faster source for the list — see M2).

### M2 · The read side moves to the index (the big one; UI work, design-sync applies)

`AppModel.captures` becomes a **window over queries**: the Projects list, the Gallery, the transfer picker and the collections clip picker take `LibraryIndex.projects(query)` pages (sort, direction, kind, scanner, chip tags, text → one `ProjectQuery`), the chip row from `tagCounts()`, "N of M" from `Page.total`, search through FTS5. Opening a project reads its document (`ProjectDocument` via a small per-project cache: `AppModel.capture(id:)`, `blends(for:)`), and every `captures.first { $0.id == … }` becomes that accessor. Mutations become **per-project**: change the document in memory → write it → upsert its index row → (until M4) regenerate the export. That per-project write is the seed of Phase 5's `apply(change)` funnel — shape it as one method now, not 47.

Design-sync (CLAUDE.md): the Projects search field's behaviour changes (FTS prefix matching per word versus today's substring match over name / tags / labels / elements — `App/SceneSearch.swift`); the empty state and the count are affected. Ask Steven design-first or code-first before touching `ProjectsView` / `GalleryView`; the existing `LL_TAB=projects|gallery` screenshots are the mirrors' checks.

Acceptance: every list screen renders the same rows in the same order as before for every sort (`LL_*` screenshots on the sim and the Mac against the same scratch root, before and after); a search that found a project before finds it after (write the token cases down — "night water", a tag label, a hand-typed tag); a grade settle on the 5,661-frame project rewrites only its document and one row (`fs_usage` or file dates); memory at launch on a 10k-project synthetic root does not scale with project count (Part 2 §5's cliff is what this removes).

### M3 · No whole-library arrays

Remove `captures` / `blends` / `collections` / `deleted*` as stored arrays; the storage card, the trash line, the tag chips, the transfer catalogue and the export estimates read the index (`size_bytes` / `sizeMeasuredAt` already exist as columns; `projectStorageBytes` and `validatedSourceFrames` caches go). Collections keep a small in-memory document since they are few.

Acceptance: `AppModel` holds no `[CaptureProject]`; the Settings storage card's numbers match `lapse audit`'s byte totals; the Kit index tests grow to cover every query the screens use.

### M4 · Retire `library.json`

Stop writing the compatibility export (one release after M1, so every device has run M1 once). Remove `LibraryManifest` and the manifest-level `ManifestMigrations`; migrations become per-document (`project.json` carries `formatVersion` — bump to 3 when the first document-level change lands) run on the JSON before decode, the same pattern. Drop the `.hasSuffix(".json")` filters (owed since W4). `lapse audit` stops reporting "records with no folder" against a manifest and reports documents against folders; `--rebuild-index --out` stays as the way to produce a v1 manifest for an old build or a tool.

Acceptance: a library with no `library.json` at all passes `lapse audit` CONSISTENT; the seven `tools/*.py` scripts that read `library.json` (grep `library.json` under `tools/` and `.claude/skills/`) read documents or the index instead; a `.lapse` from a pre-M1 build still installs.

### M5 · Phase 5: the `apply(change)` funnel and the journal (Part 3 §3.2, §12 row 5)

Every mutation produces a journal line in `Sync/journal.ndjson`; replaying a journal from an empty tree reproduces the documents byte for byte after canonical re-encoding (the test that falls out of the design, Part 3 §9). Presence tiers recorded locally; "free up space" as a local eviction policy over them. Only after M2's per-project write exists.

---

## 5. Rules (Steven's, carried forward)

- No server code. Never rename or move a project folder. Never modify an original file. Never open or write the Lightroom catalogue (the tool exists; running it on the real catalogue is Steven's).
- Every new persisted file goes into `ProjectFileRegistry` (per-project) or `StorageRoot.libraryItemNames` (top-level), or it does not travel / does not move with the library.
- One commit per work item, the attribution lines from the session's system reminder, `docs/TODO.md` updated when a milestone lands, the design INDEX rows updated for any UI change (mirror after sign-off).
- App code first for UI, ask design-first vs code-first at the start; mirror the SVGs after sign-off.
- Ask before installing on or terminating anything on a physical device; check the device is idle first (a terminating install once killed a 15 GB import at 96 %).
- Verification never against `/Volumes/letslapse` except read-only tools (`lapse audit`, `--rebuild-index`, `index --verify`); the Debug Mac app takes `-storage.libraryRootPath <scratch>`. Quit the running LetsLapse before launching a build on the real root — since Phase 4 the second one opens read-only anyway.
- Other sessions may be editing this tree concurrently (today: `App/AppModel+Metadata.swift`, `docs/design/components/*`): stage by explicit path, never `git add -A`.

---

## 6. Recipes

```bash
# the three checks, read-only, any root
LetsLapse/Kit/.build/release/lapse audit <root>
LetsLapse/Kit/.build/release/lapse audit <root> --rebuild-index        # must say REBUILD IDENTICAL
LetsLapse/Kit/.build/release/lapse index <root> --verify               # must say CONSISTENT

# a scratch root at scale (manifest over folder skeletons) — never touches the volume
mkdir -p <scratch>/lib-full/Projects && cp /Volumes/letslapse/Projects/library.json <scratch>/lib-full/Projects/
python3 -c "import json,os; d=json.load(open('<scratch>/lib-full/Projects/library.json')); [os.makedirs('<scratch>/lib-full/Projects/%s/source'%c['id'],exist_ok=True) for c in d['captures']]"

# the Debug Mac app on it (LL_* hooks work; the console log is <root>/Logs/console-*.log)
python3 .claude/skills/run-letslapse/driver.py build mac
~/Library/Developer/LetsLapseRun/dd-mac/Build/Products/Debug/LetsLapse.app/Contents/MacOS/LetsLapse -ApplePersistenceIgnoreState YES -storage.libraryRootPath <scratch>/lib-full

# Kit tests for everything under Library/
cd LetsLapse/Kit && swift test --filter "LibraryIndexTests|LibraryIndexRebuildTests|LibraryAuditTests|ManifestMigrationsTests|AssetRecordsTests|LightroomMigrationTests"
```

---

## 7. Traps met on the way (all in the commit messages; the short list)

- A `URL` caches its resource values; a modification date read through the URL an atomic write was given is the *previous* file's — read through `URL(fileURLWithPath:)`.
- `JSONSerialization` spells doubles with 17 digits and reads such literals back as `NSDecimalNumber` — the canonical diff compares fractions to a relative 1e-9; integers exactly. If M4 ever writes documents through `JSONSerialization`, expect this.
- `JSONEncoder` escapes `/`; every document/NDJSON encoder needs `.withoutEscapingSlashes`.
- `.iso8601` (whole seconds) versus the fractional formatter: documents are ms-precision; the manifest's µs are lost at the switch (Part 1 §7 set the bar at ms) — `addedAt` ties within one millisecond are theoretical.
- The app's launch order adopts folders and persists *before* the document pass, so on a real library the index fills incrementally (no `builtAt` stamp) — harmless; `lapse index` says "built incrementally by the app".
- `pkill`/SIGTERM skips `applicationWillTerminate`: the lock file stays and is taken over by liveness; a graceful quit releases it.
- The search table gains a row for every asset with words of its own, and a camera model counts — 52,691 rows for 57,052 assets on the Mac (37 MB). Fine at this size; if it matters, gate on title/caption/keywords/creator/place and leave the camera to the project row.
- Two Mac instances of the same name: `whose unix id is` targets the wrong one; drive by pid (`driver.py winshot --pid`).
- `FileHandle.read(upToCount:)` chunks are autoreleased — never walk a library inside one dispatch block without a pool per file (Phase 1 W5's crash).

---

## 8. Owed items inherited (not blockers for M1)

- SVG mirrors for `LibraryNoticeBanner`'s two new stories (rebuilt, read-only) after sign-off — INDEX rows marked ⚠️ in `docs/design/macOS/INDEX.md` and `iOS/INDEX.md`.
- The M2 device checks from the Phase 1 spec (W10 `sessionID == id == originID` after an interval run, W11 linear writes, W5 backfill pause) — a Release run on the iPhone 16 Pro, ask first.
- The iPhone library's after-audit (needs a `devicectl` copy of the container).
- `lapse import-lightroom` on the real catalogue (dry run → `--limit 20` → full, app quit), then Part 2 §6's verification; metadata EXPORT (record → XMP in exports) is not built.
- The pre-existing empty-folder record `C6F7D8CD` (749 frames missing) and 7 unlisted renders on the Mac volume — Steven's call whether to trash.
- One pre-existing failing Kit test unrelated to this work: `ShapeDetectionModeTests.testExternalEnginesKnowTheirRigDetector`.

---

## 9. Decisions to take with Steven before M2

1. Search semantics: FTS5 prefix-per-word (finds "brid" → bridge; loses mid-word substring hits) versus keeping the substring haystack for names and using FTS only for assets. Affects the search field's design.
2. How long the generated `library.json` stays after M1 (one release is proposed) and whether the transfer server's catalogue and the seven `tools/*.py` readers move to the index or the documents.
3. Whether "Recovered · <id>" projects (folder adoption) should carry a visible badge — today they are ordinary projects with a name.
4. Whether collections stay a document or get their own table as the index's truth-facing view (they stay a document by decision; the question is only the UI's in-memory shape).
