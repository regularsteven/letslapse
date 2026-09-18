# LUTs as library assets — one cube per library, referenced by hash

**Raised:** 2026-09-18 (Steven: a per-project `luts/` copy of the same cube in
every graded project "is NOT best practice"; a LUT belongs to the library and
should be bundled only when a `.lapse` is produced; an imported archive's LUT
lands in the library; the server should hold fewer assets). **Decided the
same day:** a LUT is a library asset identified by its content hash; follow
the review's recommendation below; the existing copies are folded by a
one-off script; the poster's size is a separate matter and out of scope.
**Review:** the numbers in §1 were measured on 2026-09-18 on the volume
library (`/Volumes/letslapse/picplace.test/regularsteven`, 522 projects) and
the local `picplace.test` server. **Status:** stage A (client) built
2026-09-18 — see §3 for what is owed.

## 1. What was in place

A grade stores the cube's content hash as `adjustments.lut.id` in
`project.json`; the library keeps the bytes once at `<root>/luts/<hash>.cube`
with a `luts.json` index (`LUTStore`). That reference model was right. The
grade write then called `LUTStore.ensureCopy` (spike §4.4, 2026-09-08) to
copy the cube into the project's own `luts/` "so an archive or a device
transfer can still render". What that rule produced:

| Measure | Library | Server |
|---|---|---|
| Projects | 522 | 1395 |
| Projects naming a LUT in `project.json` | 219 | — |
| LUT copies (files / objects) | 172 in 128 projects | 265 |
| Distinct cubes | 8 | 8 |
| Bytes in copies | 160 MB | 252 MB (a fifth of everything on the server) |
| Bytes the distinct cubes need | under 8 MB | under 8 MB |
| Cubes in the library's own store | 1 | — |
| Projects carrying more than one cube | 10 (up to 8 each) | 12 (up to 8 each) |

- **Copies accumulated and never left**: every LUT a project ever tried
  stayed in its folder.
- **The store was not the truth in practice**: only one cube was in the
  library store; seven hashes lived solely inside project folders, so the
  resolver's fallback — list every project folder, stat a path in each —
  was load-bearing. Registry misses were not cached, so a cube nobody held
  re-scanned all 522 folders on every render.
- **The server never handed a LUT back**: the initial pull fetched the
  records bundle and poster; the originals download fetched `source/` and
  `blends/`; no client path requested a `lut` object. 252 MB was
  write-only. 94 pulled previews named a LUT with no cube on disk.
- **Server dedupe was CopyObject**: the upload was skipped, the bytes were
  written again under a per-project key.
- **Archives could lose the LUT silently**: an export archived the folder as
  it was; a project with no copy shipped without the cube and the receiver
  rendered without the LUT. An import moved `luts/` into the new project,
  never into the store, and the names in `luts.json` did not travel.
- **Delete had no guard**: the store's delete relied on project copies.

## 2. The model

1. **A LUT is a library asset identified by its content hash**
   (`CubeLUT.contentHash`, the SHA-256 of the file's bytes). `LUTLayer.id`
   in a grade, in a keyframe and in a preset snapshot *is* the reference.
   `project.json` does not change.
2. **Bytes live once per library**: `<root>/luts/<hash>.cube` and the
   `luts.json` index. A project folder holds no cube. A `luts/` folder in a
   project is either a legacy copy (before 2026-09-18, folded by the script
   in §5) or the export-time materialisation of §2.3, which is removed when
   the export ends.
3. **Materialise at the boundary, from the store.** A `.lapse` export and a
   device transfer collect every hash the document references — the live
   adjustments, every keyframe, the preset snapshot — and write
   `luts/<hash>.cube` plus `luts/index.json` (the `LUTFile` records: file
   name, title, size) into the tree for the trip. A referenced cube that is
   in neither the store nor the folder refuses the export with a sentence,
   instead of shipping a silent gap.
4. **Import lands in the library.** Every `luts/*.cube` in an arriving tree
   (archive or transfer, new or old) goes through `LUTStore.importCube`,
   which dedupes by hash; the file name comes from `index.json`, else from
   the document's preset snapshot. When the document's state is a named
   preset over that cube and no preset in this library names the cube, the
   snapshot becomes the LUT preset here, under the sender's preset id, so
   the project resolves as *named* rather than as a snapshot. The folder is
   not moved into the project.
5. **Resolution order**: the library store; then a legacy project copy
   while any remain; later PicPlace by hash (stage C); then *missing*. A
   miss is cached until the store changes, so a missing cube costs one
   lookup, not a folder scan per frame. The resolver reads the current
   storage root at resolve time, so a library switch on the phone re-points
   it (it used to latch the first root).
6. **References are counted in the index**: `project_luts(project_id,
   lut_id)` in `LibraryIndex`, filled by the document upsert and the
   rebuild. The store's file stays while any live project references the
   cube; deleting a LUT preset removes the preset and the file only when
   nothing references it.
7. **PicPlace sends no per-project LUT objects.** Stage C makes the cube an
   account-level, content-addressed object fetched on demand — see
   `lut-library-server-asks.md`.

The same model applies to `fonts/` (`OverlayFontStore`) when the first
per-project font appears; none exists in the library today.

## 3. The work

### Stage A — client (built 2026-09-18)

| # | What | Where |
|---|---|---|
| A1 | The grade write no longer copies the cube into the project | `AppModel.write` |
| A2 | Export and transfer materialise the referenced cubes from the store for the trip, then remove them; a missing cube refuses with a sentence | `AppModel.exportProject`, `ProjectTransferServer` (serve + `fileManifest`), `LUTStore.materialise` |
| A3 | Install folds an arriving `luts/` into the store and makes the LUT preset from the snapshot | `AppModel.installStagedProject` → `adoptLUTs` |
| A4 | Resolver order, miss caching, re-rooting on a library switch; the store adopts orphan cube files on load | `LUTResolver`, `LUTRegistry` (Kit), `LUTStore.load` |
| A5 | `project_luts` in the index (schema 3, rebuilt once at launch), reference counts, the delete guard | `LibraryIndex`, `ManagePresetsView.delete` |
| A6 | `luts/` is registered as derived and non-travelling; the sync classifies it as skipped | `ProjectFileRegistry`, `PicPlaceSyncPolicy` |
| A7 | The one-off fold: copies → the store, presets from snapshots, copies deleted | `tools/fold_luts.py` (§5) |
| A8 | Docs: this document, the spike's §4.4 note, the sync handover row, the server ask | `docs/` |

### Stage B — UI (owed; design-sync question first)

- **B1 — the editor's missing-LUT state.** A document naming a cube this
  library lacks renders without it today (as before). Owed: the LUT row /
  preset chip says "Terra 4.1 isn't in this library" with an Import door.
  Design first per the design-sync contract.
- **B2 — Manage Presets ▸ LUTs.** The row's subtitle already says "on N
  projects" by preset id; owed: the count by *cube* (`lutReferenceCounts`)
  and the delete copy ("the cube stays while 121 projects use it").

### Stage C — server (owed; the ask is written)

Account-level LUT objects keyed by hash, negotiate by hash, fetch on demand
when a document references a cube the library lacks, the cleanup of the 265
per-project objects. `docs/lut-library-server-asks.md`.

## 4. Formats

- **Archive / transfer tree**: `luts/<hash>.cube` for every referenced hash,
  `luts/index.json` = the `[LUTFile]` records (ISO-8601 dates) of those
  cubes. Old archives carry `luts/<hash>.cube` without the index; they
  import the same way, named from the snapshot.
- **Project document**: unchanged. The references are
  `capture.adjustments.lut.id`, `capture.gradeTimeline.k[].adjustments.lut.id`
  and `capture.presetState.snapshot.adjustments.lut.id`.
- **Index**: `project_luts(project_id TEXT, lut_id TEXT, PRIMARY KEY)` with
  an index on `lut_id`; rows follow the projects row on every upsert and
  are dropped with it. Schema version 3: an older database is dropped and
  rebuilt from the documents at the next launch (the launch walk already
  does this for an empty index).
- **Registry**: `luts/` at the root, class `derived`, `travels: false` — a
  legacy copy is classified, never sent by a sync, never moved by an
  installer; the archive carries the folder only as §2.3's materialisation
  and the transfer's `fileManifest` lists it explicitly.

## 5. Migration — `tools/fold_luts.py`

```bash
python3 LetsLapse/tools/fold_luts.py "/Volumes/letslapse/picplace.test/regularsteven"
```

A dry run by default; `--apply` makes the changes. **Quit LetsLapse on that
library first** — the app holds `luts.json` and `custom_presets.json` in
memory and would write them back. The script refuses while the library's
`Projects/.lock` is held unless `--force`.

1. Reads `luts.json` and lists `luts/*.cube`; walks
   `Projects/*/luts/*.cube` and `Projects/.trash/*/luts/*.cube`, verifying
   each file's SHA-256 against its name (a mismatch is reported and left).
2. For every distinct hash missing from the store: copies one file in and
   adds a `luts.json` record — file name from the first document whose
   snapshot names that cube (`Terra 4.1.cube`), else the hash; title and
   size from the cube; `isLikelyLogInput` by the Kit's rule (the trilinear
   sample of mid grey under 0.25 luma).
3. For every hash no preset in `custom_presets.json` names: adds the LUT
   preset from the first document whose state is a named preset over that
   cube, under that state's preset id (skipped with `--no-presets`).
4. Deletes every project copy and removes the emptied `luts/` folders.
5. Reports: distinct cubes, records and presets added, files and bytes
   freed, and the hashes referenced by documents that exist nowhere.

The index needs nothing: the `project_luts` rows come from the documents,
which the script does not touch. The server's cleanup is the server's
(ask C).

## 6. Verification

- Kit: `ProjectFileRegistryTests` (the travelling lists), `CubeLUTTests`
  (miss caching), `LibraryIndexTests` (`project_luts` on upsert, rebuild and
  remove; `lutReferenceCounts`).
- The round trip on a scratch root: a LUT-graded project exported through
  `LL_EXPORT_ARCHIVE` → the archive holds `luts/<hash>.cube` + `index.json`
  and the project folder holds no `luts/` afterwards → `LL_IMPORT_ARCHIVE`
  into a second scratch root with an empty store → the store has the cube
  and its record, `custom_presets.json` has the preset under the sender's
  id, the new project folder has no `luts/`. On the Mac the scratch root is
  `-storage.libraryRootPath <path>` as a launch argument (never a write to
  the setting).
- The fold's dry run against the volume library reports the §1 numbers.

**Verified 2026-09-18** (Debug Mac build in `dd-mac`, scratch roots under the
session scratchpad):

- Kit: the three suites pass (registry 3, cubes 12, index 16); the whole
  suite is 929 tests with one failure in `ShapeDetectionModeTests`, a file
  this work does not touch.
- Export from root A (the one-photo project graded with Terra 4.1, the cube
  in the store, no `luts/` in the project): the console says *2 file(s)
  materialised … for the trip* and the archive holds `luts/<hash>.cube`
  (bytes verified by hash) and `luts/index.json` with the store's record;
  the project folder has no `luts/` afterwards.
- Import into empty root B: *made the preset "Terra 4.1" from the arriving
  project's snapshot · 1 cube(s) … folded into the library store*; the store
  holds the cube and its record ("Terra_4.1.cube" from the index), the
  preset exists under the sender's id `9FB3F0C9…`, the new project has no
  `luts/` and its state is named by that id.
- An old-style archive (the cube without `index.json`) into empty root C:
  the same, the record named "Terra 4.1.cube" from the snapshot.
- A schema-2 index (528 rows, from the volume library) dropped into root A
  is dropped and rebuilt at launch: `user_version` 3, one `project_luts`
  row for the project.
- The iOS Simulator build (arm64, the booted iPhone 17 Pro) links; a
  `generic/platform=iOS Simulator` destination fails only at the x86_64
  link, as it always has.
- Not exercised at runtime: the device transfer's materialise → send →
  fold path (compiled; the sender lists `luts/` and the receiver installs
  through the same `installStagedProject`), and the Manage Presets delete
  guard (logic only).

The shell-launched Mac app prints nothing to stdout — the hooks' outcome is
in `<root>/Logs/console-<stamp>.log`.

## 7. Notes and traps

- `LUTResolver.install` used to latch `StorageRoot.current` at first
  install and was idempotent, so `LUTStore.reroot()` on a phone's library
  switch left the resolver on the previous root (found reading, not
  reproduced). The resolver now reads the root per lookup.
- `LUTRegistry` caches by content hash, so a cube read from one library
  serves another correctly by definition — only *misses* were the problem.
- A legacy `luts/` in a project folder is classified `skipped` by a sync
  and logged as left out; the fold removes them all.
- The clone (`Duplicate as DNG archive…`) copies the travelling subfolders;
  `luts/` no longer travels, so a clone carries no cube — it needs none.
