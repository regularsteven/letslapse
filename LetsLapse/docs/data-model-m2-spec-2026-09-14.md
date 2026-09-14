# Data model M2 — the read side moves to the index

**Date:** 2026-09-14 · **Status:** spec, agreed scope (code first, mirrors after sign-off — Steven, 2026-09-14), in build · **Implements:** [the switch brief](data-model-switch-brief-2026-09-13.md) §4 M2 with its §9 decisions · **Branch:** `claude/ios-app-data-model-a4ffdd` on `ios-app` a7f9810, after M1 (538dbb1 → 2fc20c0)

M1 made the project documents what the app loads. M2 makes the SQLite index what the **lists** read: the Projects list, the Gallery grid and timeline, the collections clip picker and the transfer catalogue's lookups take their rows — order, filter, count, search — from `LibraryIndex`, and a screen that needs a whole record asks for one project by id. The three arrays stay loaded in M2 (M3 removes them); what M2 removes is every screen's habit of filtering and sorting the whole library in Swift on each render, and the substring search over it.

---

## 1. Outcomes

1. Every list screen renders **the same rows in the same order** as before, for every sort and direction, kind filter and tag chip, on the Mac and the simulator against one scratch root — with the two documented exceptions in §3.
2. The Projects search is **FTS5, prefix per word**, over names, titles, captions, keywords, scene tags *and their chip labels*, elements, creator, place and camera (the brief's §9.1 decision). A word that found a project before still finds it, except a mid-word substring (§3).
3. `AppModel.capture(id:)`, `blend(id:)` and `blends(for:)` are the one way a screen gets a record by id; no view walks `captures` with `first { $0.id == … }`.
4. Single-project mutations go through **one method** (`updateCapture(_:reason:_:)`), the seed of Phase 5's `apply(change)` funnel.
5. The index is **schema 2** and answers every question the screens ask: category (photo / interval / video / scan, the app's own rules, sidecar included), the Edit date, the shape rows, the tag chips, the filter counts.
6. The in-memory pipeline survives only as the fallback for a library whose index could not be opened.

Not in M2 (M3): memory at launch that does not scale with project count; the storage card, trash line, transfer catalogue bytes and export estimates over the index; the arrays' removal.

---

## 2. Work items

### W1 · Kit — the index answers what the screens ask (schema 2)

`Kit/…/Library/LibraryIndex.swift`, `+ ProjectCategory.swift`, `+ SceneTagLabel.swift`; tests in `LibraryIndexTests`.

| Change | Why |
|---|---|
| `ProjectModes` — the four mode strings the app classifies by (`"Photo"`, `"Photo · Imported"`, `"Import"`, `"Interval · Scanner"`) and `captureMode == "scanner"`, moved into the Kit; `AppModel`'s statics forward to them | the Kit classifies at index time and the CLI rebuilds the same index; one source for the strings |
| `ProjectCategory.classify(kind:mode:captureMode:scannerSidecar:)` → `photo · interval · video · scan`, exactly `CaptureFilter.matches` + `isPhotoCapture` + `isScannerProject` | the Photos/Interval split is a mode split, not a kind split |
| columns: `category TEXT NOT NULL`, `scanner_sidecar INTEGER` (0/1, NULL = not looked), `edited_at REAL`, `shape_ellipses/rectangles/squares INTEGER`, `shapes_indexed_at REAL`; indexes on `(deleted_at, category, …)` | the sorts and filters become index scans |
| `edited_at` = `modifiedAt ?? newest live blend's createdAt ?? createdAt`, computed at upsert (the blends arrive with the document) | the app's `lastEdited` rule, so the Edit sort orders identically |
| the scanner sidecar: for a `photos`-kind project that neither `captureMode` nor `mode` calls a scanner, `source/frames.timestamps` is read **once** for a rectangle entry (`FrameTimestamps`, already in the Kit) and the verdict kept in `scanner_sidecar` across upserts; needs the folder URL, so `upsertProject(documentData:folder:documentModifiedAt:projectFolderURL:)` and the rebuild pass it | `isScannerProject`'s third rule, for scanner runs older than the mode string |
| `reindexShapes(projectID:inProjectFolder:)` + `shapesIndexedAt(projectID:)` from `ShapeRegister` (Kit), counted the way `ShapeSummary` counts (ellipses; quads split square / rectangle) | the Gallery's SHAPES rows become a WHERE clause |
| FTS row gains each scene tag's chip label (`SceneTagLabel.label(for:)`, moved to the Kit; `SceneMetadata.label(for:)` forwards) | "weather" must find `skyWeather` the way it does today |
| `Sort.edited` (the app's Edit); `Sort.size` sorts unmeasured as −1; every sort breaks ties on `created_at` **in the sort's own direction**, then `id` | parity with `ProjectsView.sorted` / `GalleryView.sortedCaptures` |
| `ProjectQuery.category`, `.excludeScans`, `.shapes: Set<ShapeRow>`, `.withBlends` | the Projects/Gallery base sets, the SHAPES rows, the clip picker |
| `projectIDs(_ query) -> (ids: [UUID], total: Int)` (no limit — ids are 16 bytes), `tagCounts(excludingScans:)`, `categoryCounts(_ query)`, `hasProject(originID:)` | the lists, the chips, the filter bar's counts, "Hide imported" |
| `schemaVersion` 1 → 2: the existing migration drops a v1 database; the app's launch pass rebuilds it whole (8 s on the Mac's 57 k asset rows, on the persister's queue) | the cache's own rule |

On-disk change: `Index/library.sqlite` only (a cache). No document changes.

Acceptance: Kit tests for every rule above on a synthetic tree — one project per category including a sidecar-only scanner, Edit-sort order with a blend newer than `modifiedAt`, size sort with an unmeasured project, tie order in both directions, a tag label found by prefix, shape rows, `excludeScans`, `categoryCounts`. `lapse index <root> --rebuild` on the M1 scratch root reports the categories and the schema.

### W2 · App — the lists over the index

`App/AppModel.swift` (+ `AppModel+Lists.swift`), `App/ProjectsView.swift`, `App/GalleryView.swift`, `App/GalleryGridContent.swift`, `App/CollectionClipPicker.swift`, `App/ProjectTransferImportView.swift`, `App/LibraryPersister.swift`, `App/ProjectDocumentWriter.swift`, `App/Shapemation/ShapeSummaryIndex.swift`.

- `capture(id:)`, `blend(id:)`, `blends(for:)` backed by id maps kept in `didSet` of the arrays (M2) — the accessor the M3 document cache will sit behind.
- `@Published indexRevision`: bumped on the main actor after every index write (the persister's queue → `onIndexChanged`), after the launch pass, and on `assetStore.onChange`; the lists key their memoised page on it.
- `ProjectListQuery` (sort key + direction + `CaptureFilter` + `SceneQuery` + `listsScans` + shape rows) → `LibraryIndex.ProjectQuery`; `AppModel.projectIDs(for:)` memoised on (query, revision); `tagChips(listsScans:)` = `tagCounts` in `SceneMetadata.orderedTaxonomy` order then custom tags alphabetically (today's `presentSceneTags`); `filterCounts(for:)` = `categoryCounts`.
- `ProjectsView` / `GalleryView`: `ForEach(ids)` → `capture(id:)` → the same `ProjectCard` / `GalleryTile`; the empty states read the base query's total; the selection, keyboard order, timeline groups and `LL_*` hooks take the ordered ids.
- The persister and the writer keep `shapes` and the sidecar verdict current: `reindexShapesIfStale` beside `reindexAssetsIfStale`; `shapeRegisterDidChange` re-indexes the one project. `refreshShapeSummaries` goes; `shapeSummaries` stays only for the fallback.
- `CollectionClipPicker` sections from `projectIDs(category ≠ photo, withBlends)`; `ProjectTransferImportView`'s "Hide imported" through `hasProject(originID:)`.
- Fallback: `libraryIndex == nil` → the pre-M2 pipeline (`sorted(filtered(matching(…)))`), kept in one place.

On-disk change: none.

Acceptance: `LL_TAB=projects` and `LL_TAB=gallery` screenshots on the Mac and the iPhone 16 Pro simulator against the M1 scratch root, before (M1 build) and after, for Capture · Added · Edit · Size × ↑↓ × All · Photos · Interval · Video (`-projects.sortKey`, `-projects.sortAscending`, `-gallery.sortKey` as launch arguments so nothing is written to the shared defaults) — pixel-identical bar the §3 exceptions; the search token cases of §3 recorded before and after.

### W3 · App — one accessor, one mutation funnel

`App/AppModel*.swift` and every file that reads `captures.first { $0.id == … }` (77 sites) or `blends.first { $0.id == … }`.

- Every `captures.first { $0.id == X }` → `capture(id: X)`; every `blends.first { $0.id == Y }` → `blend(id: Y)`.
- `updateCapture(_ id: UUID, reason: LibraryPersister.Reason = .valuesChanged, edited: Bool = true, _ change: (inout CaptureProject) -> Void)`: mutate the record in place, stamp `modifiedAt`/`modifiedBy` when `edited`, persist with the reason. The single-project persist sites (rename, grade, preset state, white balance, rotation, nominations, tags, hide flag, encodings, scanner pages) go through it; registrations, deletes and installs keep their own paths (they are multi-record and file-moving).

On-disk change: none. The persister still writes only the documents that differ.

Acceptance: the build; a grade settle on a copied real project rewrites only its `project.json` and one index row (file dates); the persist count per edit is unchanged (one).

### W4 · The record and the mirrors

`docs/TODO.md`, the brief, `docs/data-model-audit-reports/`, and — after sign-off — `docs/design/{iOS,macOS}` INDEX rows for Projects and Gallery (search semantics are a behaviour, not a layout: if no glyph or copy moves, the rows get a note and no SVG changes; if Steven wants the field to say it searches words, that copy is drawn then).

---

## 3. What is allowed to differ, written down before the screenshots

1. **Twins.** Two projects with byte-identical `createdAt` (a DNG-archive clone and its source, a project imported twice) had an arbitrary relative order before (manifest order, then folder order after M1); the index breaks the tie on `id`. Two pairs on the Mac library.
2. **Search.** Prefix per word replaces substring: `brid` still finds *bridge*; `idge` no longer does. Everything else a word matched before — the name, a tag's raw value or its label, an element — it still matches, plus asset titles, captions, keywords, creator, place and camera. The cases to record before and after: `night water` · `Sky & weather` / `weather` · a hand-typed tag · `brid` · an element word · `idge` (the one that changes).
3. **Freshness.** A row's order or membership follows the index, which the persister updates right after the document (synchronously for a registration, delete or install; within the persist's own latency for a grade tick or a tag). The card's content comes from the record in memory, so a rename shows at once; only its position under the Name sort waits for the persist.

---

## 4. Rules carried

Per-project JSON stays the truth; the index is a cache (deleting `Index/` loses nothing — `verify` still proves it). No server code. No folder renamed or moved. One commit per work item. Design-sync: code first by decision; mirrors after sign-off. No device without asking. Verification on scratch roots.
