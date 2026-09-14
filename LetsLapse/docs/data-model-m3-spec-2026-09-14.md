# Data model M3 — no whole-library arrays

**Date:** 2026-09-14 · **Status:** spec, agreed scope (Steven: "go on to M3 now, same rules"), in build · **Implements:** [the switch brief](data-model-switch-brief-2026-09-13.md) §4 M3 · **After:** M1 (538dbb1 → 6cd07b3), M2 ([spec](data-model-m2-spec-2026-09-14.md), f7eb131 → 76e503e) · **Branch:** `claude/ios-app-data-model-a4ffdd`

M2 made the index what the lists read; the records still came from three arrays the launch filled from every document. M3 removes the arrays: `AppModel` holds no `[CaptureProject]` and no `[BlendProject]`. A record is read from its document when a screen asks for it, through a bounded cache; a change writes that one document and its index row; everything that used to walk the library — the storage card, the trash line, the transfer catalogue, the export estimates, the size sweep, the metadata probes, the launch hooks — asks the index. Memory at launch stops scaling with project count, which is the cliff Part 2 §5 measured.

---

## 1. Outcomes

1. `AppModel` holds no `[CaptureProject]` and no `[BlendProject]`; collections stay a small in-memory document (§9.4).
2. `capture(id:)`, `blends(for:)` and `blend(id:)` read documents through `ProjectStore` — an LRU cache over `Projects/<id>/project.json` (and `.trash/<id>/`) bounded at 512 documents.
3. Every mutation writes **one project's document** and its index row (`updateCapture`, `insertProject`, `removeProject`, the blend paths) or the collections document; `persistLibrary()` / `persistLibraryOffMain()` / `persist(reason:)` are gone.
4. The launch is a **walk, not a load**: one `stat` per project folder against the index's `document_modified_at`; only a changed or unknown document is read (and the M1 rules applied to it); the index loses rows for folders that have gone. A fresh or discarded index is rebuilt whole. A manifest-only library still bootstraps once.
5. The compatibility export is regenerated **at launch when stale and at quit / background** from the documents (`LibraryIndexRebuild.rebuiltManifest`), not after every persist — with nothing in memory to write it from, per-persist would mean reading every document on every grade tick. `lapse audit --rebuild-index` reads IDENTICAL after a clean quit; after a crash it reads DIFFERS until the next launch, which regenerates it. M4 retires it.
6. The storage card's bytes, the trash line, the transfer catalogue, the export estimates, the size sweep, the metadata catch-ups and the `LL_*` hooks read the index.
7. Memory at launch on a 10k-project synthetic root is flat against project count (measured).

---

## 2. Work items

### W1 · Kit — the index answers the whole-library questions

`Kit/…/Library/LibraryIndex.swift`; tests in `LibraryIndexTests`.

| Query | For |
|---|---|
| `projectID(forBlend:)` | `blend(id:)` — a blend lives in its project's document |
| `folder(of:)` → `<id>` or `.trash/<id>` | where to read a document from |
| `storageTotals()` → live bytes (sum of `size_bytes`), unmeasured count, live/deleted project counts, deleted blend count | the storage card and the trash line |
| `deletedProjects()` → id, folder, deleted_at; `liveProjectsWithDeletedBlends()` → project id + blend ids + output names | the trash sweep, the purge, Empty trash |
| `projectsNeedingProbe()` → video rows lacking fps / duration / width, photo rows lacking width | the launch's metadata catch-ups (the segment maps are checked on the few video documents) |
| `projectIDs(includeDeleted:)`, `rows(ids:)` | the size sweep, the transfer catalogue, the export estimates, the batch panel |
| `documentModifiedAt(projectID:)` already exists; `setFolder`/`upsert` keep `folder` current when a folder moves to `.trash` | the reconcile walk |

On-disk change: none (schema stays 2; the new questions are queries over existing columns).

Acceptance: a Kit test per query on the synthetic tree.

### W2 · App — `ProjectStore`, the per-project persister, the launch walk (the model)

`App/ProjectStore.swift` (new), `App/LibraryPersister.swift`, `App/ProjectDocumentWriter.swift` (retired into the persister), `App/LibraryDocumentLoader.swift` (becomes the reconcile walk), `App/AppModel.swift`, `App/AppModel+Lists.swift`, `App/AppModel+Metadata.swift`, `App/CollectionsModel.swift`.

- **`ProjectStore`**: `document(id:) -> ProjectDocument?` (cache → disk, folder from the index, both folders tried when the index does not know); `capture(id:)`, `blends(for:)`, `blend(id:)` (owner from a session map, else the index); `update(id, change) -> ProjectDocument?`; `insert(_ document, folder:)`; `remove(id)`; `evict(id)`; an LRU of 512. Every write goes to the persister first and the cache second, so a failed write leaves the cache honest.
- **The persister goes per project**: `persist(document, at folder, waiting:)` — the document atomic, then `upsertProject(documentData:…)`, the asset and shape re-index when stale — under a per-project `VersionGate`; `removeProject(id)`; `persistCollections(_:)`; `regenerateExport()` (documents → manifest bytes → `library.json`, marked generated) at launch when stale and from `flushLibraryPersists(andExport:)` at background / terminate. `refuseWrites` and the failure surfacing stay.
- **The launch walk** (`LibraryReconciler`, from `LibraryDocumentLoader`): per UUID folder, live and trash — `stat` the document; current in the index (same modification date, same folder) → next; else read, decode, apply the M1 rules (live folder = live, trash = deleted and stamped, `.json` names out, an origin), write back if a rule changed it, index it, re-index assets and shapes if stale. A folder with no document: the manifest's record if the manifest is readable and has one (written as its document), else a Recovered project from its media, else logged. An undecodable document: reported, left alone, excluded. Rows whose folder has gone: removed. A fresh index: `rebuild` first, then the walk finds everything current. The manifest-only bootstrap: decode the manifest, apply the Swift stamps to that array, write every document, then walk.
- **`AppModel`**: `captures`, `blends`, `deletedCaptures`, `deletedBlends` and `captureIndexByID` removed; `currentCapture`/`currentBlend` through the store; `libraryCaptures`, `hasScans`, `libraryTags`, `existingImport`, `hasImported`, `projectTransferCatalogue`, `measureProjectSizes`, `storageBytes` totals, `sweepTrashAtLaunch`, `purgeExpiredTrash`, `emptyTrash`, the metadata catch-ups, `debugSeedSceneTags`, `reconcileFoldersAtLaunch` (folded into the walk), the stamps — over the store and the index. Registrations `insert`; deletes tombstone-then-move through the store; blends are written into their project's document (`storeBlend`, `deleteBlend`, encodings, rotation). `updateCapture` keeps its shape. The M2 list layer is unchanged (`projects(for:)` maps ids through the store).
- **Transitional helper** for the screens not yet converted in this commit: `allLiveCaptures()` — an explicit, named full read (index ids → documents) that W3 removes.

On-disk change: none. The document format, the export's shape and the index schema are M2's.

Acceptance: the M1 rig (scratch `lib-full`: flip, delete, corrupt, bootstrap, edge cases) and the M2 rig (36 cases, Mac + simulator) read the same; `--rebuild-index` IDENTICAL and `index --verify` CONSISTENT after a clean quit; a registration, a delete, a grade settle and a blend each touch one document.

### W3 · App — the screens and the hooks off the arrays

`App/LetsLapseApp.swift`, `App/GalleryBatchPanel.swift`, `App/GalleryGridContent.swift`, `App/SettingsView.swift`, `App/ProjectsView.swift`, `App/GalleryView.swift`, `App/ManagePresetsView.swift`, `App/CaptureView.swift`, `App/Shapemation/*`, `App/GalleryItemView.swift`, `App/CollectionClipPicker.swift`, `App/ScansView.swift`, `App/LiveBlendRawController.swift`, `App/AI/*`, `App/MacVideoJobRunner.swift`, `App/GalleryPreviewPanel.swift`, `App/PhotoViewerView.swift`, `App/AdjustView.swift`, `Shared/BlendDepth.swift`, `Shared/ProjectTransferServer.swift`.

Every remaining `model.captures` / `model.blends` reads `capture(id:)`, `blends(for:)`, `projectIDs(for:)` or an index query; the fallback pipelines of M2 go (a library with no index shows the empty state and the notice); `allLiveCaptures()` is deleted.

Acceptance: the build with no `captures`/`blends` stored anywhere; the M2 rig; the storage card's bytes against `lapse audit`'s byte total on the scratch root with measured sizes.

### W4 · The measure and the record

A 10k-project synthetic root (`lapse`-free: the M1 scratch documents cloned under fresh ids, no media): launch time and resident memory of the Debug Mac app at 366 and at 10,000 — the memory must not scale; the launch walk's time may (10k stats). The record in `docs/data-model-audit-reports/`, TODO, the brief, the overview.

---

## 3. What is allowed to differ

1. **The export's freshness** (§1.5): per launch and per quit rather than per persist.
2. **Reads on the main thread**: a card's record comes from the cache or a 5 KB file; scrolling a 10k list reads 10k small files over time and keeps at most 512 in memory.
3. **A live folder with a tombstoned document** is restored at the launch walk exactly as M1 restored it in memory — but now the document on disk is rewritten undeleted at that moment, not at the next persist.

---

## 4. Rules carried

Per-project JSON stays the truth; the index is a cache. No server code. No folder renamed or moved. One commit per work item. No UI changes (no SVG applies). No device without asking. Verification on scratch roots.
