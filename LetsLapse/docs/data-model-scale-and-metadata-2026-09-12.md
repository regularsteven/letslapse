# LetsLapse — Data Model Audit, Part 2: Scale, metadata, and the Lightroom catalogue

**Date:** 2026-09-12 · **Builds on:** [data-model-audit-2026-09-06.md](data-model-audit-2026-09-06.md) (Part 1) · **Type:** investigation report, no implementation · **Branch:** `ios-app` at 408737d

Steven's additions to the brief (2026-09-12): the library is ~220 projects today, some holding thousands of assets; it should be sustainable at 100,000 to a million projects; the Lightroom catalogue is to migrate into it; the Gallery's right-hand panel needs user-editable metadata in a standard structure (title, caption, copyright, creator, rating, copyright status and URLs, address, city, state, postcode, country, phone, email, website); imported files that carry any of that must bring it in, and camera and GPS data must be preserved; four example files on the Desktop should import and present their metadata.

Nothing was modified. The Lightroom catalogue was opened read-only (`?immutable=1`), never written.

**Part 3** — the server as the source of truth and what one edit syncs — is in [data-model-server-portability-2026-09-12.md](data-model-server-portability-2026-09-12.md). It amends §4.4 here: the per-asset records split into `metadata.json` (project level) and `assets.ndjson` (one line per asset, compacted at idle) so a burst of synced changes never rewrites a 10 MB file per change.

---

## 0. Summary

1. **Scale.** Part 1's model — JSON truth per project, a rebuildable index — holds, but its *index* has a ceiling. Measured on this Mac, a JSON index decodes in 0.04 s at 10k projects, 0.43 s and 367 MB resident at 100k, 4.4 s and 2 GB at a million. A phone is 5–10× slower with a 2–3 GB ceiling, so the whole-library-in-memory design ends somewhere between 10k and 30k projects on iPhone and at 100k on the Mac. A SQLite index over the same data answers every list, filter, search and lookup in under 5 ms at a million rows. **Recommendation:** keep JSON as the truth per project, make the index a SQLite cache rebuilt from those files, and make the UI page and query instead of holding an array. That is the "split" option from the original brief, now with the evidence that decides it (§5).
2. **Metadata.** The requested field list is, almost word for word, IPTC Core as carried in XMP: Dublin Core for title, caption, creator and rights; `xmpRights` for status and the two URLs; `Iptc4xmpCore:CreatorContactInfo` for address through website. Adopt that standard as the schema, per asset with project-level inheritance, JSON-shaped with a fixed mapping table for import and export (§2, §4). One ambiguity to settle: "address, city, state, postcode, country" is the **creator's contact address** in IPTC; the example DNG carries the **image's location** (State Prague, Country Czech Republic, Location Mala Strana) in different fields. Both belong in the model.
3. **Import today.** The app already preserves everything on disk — the original file untouched, and since 2026-09-07 the `.xmp` sidecar copied beside a raw (`App/AppModel.swift:7150-7153`) — and reads camera, lens, exposure, capture time and GPS through ImageIO. It reads **none** of the descriptive fields: no title, caption, creator, rights, rating, keywords or contact info reaches any store or any screen (`grep` over every source: the only XMP reader is `LightroomSidecar`, which takes `crs:` develop settings and `tiff:Orientation`). The Gallery panel shows title, date, size, tags, "In frame", storage, field notes and blended clips; nothing from the file. What each example file carries is in §2.
4. **Lightroom.** The catalogue on this Mac holds **13,532 images**, not 100k: 6,792 DNG, 4,959 JPEG, 1,695 ARW, 86 MP4, across 13 root folders — **eight of which are LetsLapse `Projects/<id>/source/` folders on the library volume (9,701 images, 72 %)**. The migration is therefore mostly "attach Lightroom's per-frame ratings, captions and keywords to frames of projects that already exist", plus ~3,800 standalone photos that become Photo projects. That makes **per-asset metadata a requirement**, not a nicety: today every descriptive field the app has (`name`, `sceneTags`, `sceneElements`, grade) is per project, and a 5,030-frame project cannot carry one frame's five-star rating.
5. **Since Part 1** the codebase added six stores (`shapes.json` per project, `Shapemations/` + `shapemations.json`, `luts/` + `luts.json`, LUT presets inside `custom_presets.json`, a `conditions` block in `capture_log.json`, the copied `.xmp` sidecar) and a third manifest migration (`addedAt`). All are listed in §1 so the inventory stays complete.

---

## 1. What changed since Part 1 (delta inventory)

| Store | Scope | Written by | Format | Notes | Cited |
|---|---|---|---|---|---|
| `Projects/<id>/shapes.json` | per-project | Find shapes, the Masks tab, live shape pass at capture | JSON atomic, `version: 1`, `detectorVersion` | `ShapeRegister {version, detectorVersion, representative{relativePath, source, horizontalFieldOfView?, frameFraction?, width, height}, shapes[DetectedShape{id, kind, centre, majorAxis, minorAxis, rotation, corners?}], …}`. In `transferableFiles` (travels). 200 of 224 Mac project folders have one. | `Kit/…/Shapes/ShapeRegister.swift:233-348`, `App/ProjectArchive.swift:56` |
| `Shapemations/<file>.mp4` + `Shapemations/shapemations.json` | global | Shape-mation export | JSON index atomic | `Record {id, title, createdAt, family, mode, itemCount, width, height, seconds, fileName, posterFileName?, match?, sort?, timing?}`. In `libraryItemNames`. | `App/Shapemation/ShapemationStore.swift:8-86`, `App/StorageLocation.swift:38-42` |
| `luts/<contentHash>.cube` + `luts.json` | global | LUT import | binary cube + JSON index atomic | `LUTFile {id (content hash), fileName, title, size}`; dedup by bytes. In `libraryItemNames`. | `App/LUTStore.swift:60-179` |
| `custom_presets.json` | global | Presets sheet | as before + `adjustments.lut: LUTLayer?` | a LUT preset = Original plus a cube at a strength; `isLUT` | `App/CustomPreset.swift` (+30 lines since 6c3a997) |
| `source/capture_log.json` → `conditions` | per-project | Photo captures, live shape pass | JSON | `Conditions {stop, stopKind, lens, lensType, zoomFactor, lensCrop, horizontalFieldOfView, focalLength35mm, format, thermalState, thermalStateAtEnd, systemPressure, batteryLevel, lowPowerMode, focusMode, focusPinnedByTap, lensPosition, exposureMode, exposureLocked, stabilization, orientation, appVersion, osVersion, shapeSearch}` | `Kit/…/CaptureExposureLog.swift:321-390` |
| `source/<raw>.xmp` | per-project | stills import, when a sidecar sits beside the raw | XMP (RDF/XML) | copied verbatim; read on demand by the viewer's "Lightroom settings found" card and `LightroomImport`; **the only descriptive metadata the app keeps beside a raw** | `App/AppModel.swift:7150-7153`, `App/PhotoViewerView.swift:2615-2640` |
| `library.json` `captures[].addedAt` | manifest | every registration; v3 migration backfills from the folder's creation date | seconds-since-2001 | `gradingSchemaVersion` 3 | `App/AppModel.swift:231, 7707-7712` |

The Mac library today: 224 project folders, 221 captures, 140 blends, `library.json` 2.39 MB, schema 3; 122 projects are `Photo` (one asset), 99 are interval sets.

---

## 2. The requested fields, the standard they already are, and what the example files carry

Read from the files themselves with ImageIO (`CGImageSourceCopyPropertiesAtIndex` + `CGImageSourceCopyMetadataAtIndex`) and from the sidecar text. ✓ = present; — = absent.

| Requested field | XMP property (standard) | IPTC-IIM legacy (ImageIO `{IPTC}` key) | `demo.jpg` | `_WEX3518-Rendered.dng` | `_WEX3518.ARW` (in-file) | `_WEX3518.xmp` (sidecar) | Read by the app today |
|---|---|---|---|---|---|---|---|
| Title | `dc:title` (lang-alt) | ObjectName | ✓ "White Corner, black Corner" | ✓ "Charles Bridge at night" | — | ✓ | no |
| Caption | `dc:description` | Caption/Abstract | ✓ | ✓ | — | ✓ | no |
| Copyright | `dc:rights` | CopyrightNotice | ✓ "© 2026 Steven Wright" | ✓ "Steven Wight 2026" | — | ✓ | no |
| Creator | `dc:creator` (seq) | Byline | ✓ | ✓ | — | ✓ | no |
| Rating 1–5 | `xmp:Rating` | (ImageIO surfaces it as StarRating) | ✓ 4 | ✓ 5 | ✓ **0** | ✓ **5** | no |
| Copyright status | `xmpRights:Marked` (True / False / absent → Copyrighted / Public domain / Unknown) | — | ✓ True | — | — | — | no |
| Copyright URL | `xmpRights:WebStatement` | — | ✓ | — | — | — | no |
| Rights usage terms | `xmpRights:UsageTerms` (lang-alt) | — | ✓ | — | — | — | no |
| Address | `Iptc4xmpCore:CreatorContactInfo/CiAdrExtadr` | — | ✓ "23 Main Street" | — | — | — | no |
| City | `…/CiAdrCity` | — | ✓ Melbourne | — | — | — | no |
| State | `…/CiAdrRegion` | — | ✓ Victoria | — | — | — | no |
| Postcode | `…/CiAdrPcode` | — | ✓ 3000 | — | — | — | no |
| Country | `…/CiAdrCtry` | — | ✓ Australia | — | — | — | no |
| Phone | `…/CiTelWork` | — | ✓ | — | — | — | no |
| Email | `…/CiEmailWork` | — | ✓ | — | — | — | no |
| Website | `…/CiUrlWork` | — | ✓ | — | — | — | no |
| *Keywords* (not in the list, but in every file) | `dc:subject` (bag); `lr:hierarchicalSubject` | Keywords | ✓ 3 | ✓ 7 | — | ✓ 7 | no |
| *Image location* (not in the list; the DNG has it) | `photoshop:City / State / Country`, `Iptc4xmpCore:Location`, `Iptc4xmpCore:CountryCode` | Province/State, Country/PrimaryLocationName, Country/PrimaryLocationCode, SubLocation | — | ✓ State Prague, Country Czech Republic, CZ, Mala Strana | — | ✓ | no |
| Camera make / model | `tiff:Make`, `tiff:Model` | — | — (Photoshop export) | ✓ SONY ILCE-7M4 | ✓ | ✓ | **yes** → `capture_log.json.cameraName`, format line |
| Lens | `aux:Lens`, `exifEX:LensModel` | — | — | ✓ Viltrox 28mm F4.5 FE | ✓ (Exif) "Viltrox", (Aux) "Sony FE 28mm F4.5" | ✓ | **yes** (Exif wins over Aux) |
| Exposure, ISO, aperture, focal length | `exif:*` | — | — | ✓ 3.2 s f/4.5 ISO 100 28 mm | ✓ | ✓ | **yes** → `frames.exposure`, `frames.timestamps`, `capture_log.json` |
| Capture time | `exif:DateTimeOriginal` + `SubsecTimeOriginal` (+ `OffsetTime` when present) | — | — | ✓ 2026-08-31 20:29:30.836 | ✓ | ✓ | **yes** → `createdAt`, `frames.timestamps` |
| GPS | `exif:GPS*` | — | — | ✓ 50.0897 N 14.4116 E, alt 2 m, direction 90° | — (not in the ARW) | ✓ | **partly**: read into `ImportedStills.Frame.location`, used only when saving to Photos; not stored, not shown |
| Develop settings | `crs:*` | — | ✓ crop only | ✓ full | — | ✓ full | **yes**: `LightroomSidecar` → `LightroomImport` → grade (Photo projects) |
| Orientation, dimensions, software | `tiff:` | — | ✓ | ✓ | ✓ | ✓ | dimensions yes |

Three things the table settles:

- **The files disagree with each other, by design.** The ARW says rating 0; its sidecar says 5. Lightroom never rewrites a proprietary raw, so the sidecar is the newer record; `LightroomSidecar.read(forRawFile:)` already applies "sidecar first" for develop settings and the same rule must apply to every descriptive field.
- **Two "address" groups exist.** The creator's contact address (demo.jpg) and the image's location (DNG) are different IPTC fields with different meanings. The requested list reads as the contact block; a Lightroom user also expects the location block. Model both; label them distinctly in the panel.
- **The descriptive facts already survive an import**, in the untouched original and, for raws, the copied sidecar. Nothing reads them. So the work is extraction, a place for user edits, an index, and a panel — not preservation.

Lightroom's own catalogue carries only part of this: `AgLibraryIPTC` has caption and copyright; `AgHarvestedIptcMetadata` interns creator, city, country, location, state and a `copyrightState` integer (13,531 null = unknown, 1 = copyrighted); `xmp:Rating` and keywords are first-class tables. Title, the rights URLs and the contact block are not in the catalogue tables at all — they are only in the XMP the catalogue writes out. A migration must read both.

---

## 3. What happens to the four files if imported today

| File | Becomes | Kept on disk | Extracted | Shown in the panel |
|---|---|---|---|---|
| `demo.jpg` | a Photo project (single pick → `isPhotoCapture`, `App/AppModel.swift:7043-7058`) | the JPEG, untouched, with its embedded XMP and IIM | dimensions; no camera fields exist in it | title = file name, date, size |
| `_WEX3518.ARW` + `_WEX3518.xmp` | a Photo project; the sidecar is copied beside the raw | both files | camera, lens, exposure, time; `crs:` develop settings on demand | as above; "Lightroom settings found" card in the viewer |
| `_WEX3518-Rendered.dng` | a Photo project | the DNG with embedded XMP + IIM | camera, lens, exposure, time, GPS (transient) | as above |
| all three together | **one** interval project of three frames | as above | the sequence's camera name; per-frame exposure lines | one title, no per-frame anything |

The last row is the model gap in one line: a multi-select import is a sequence, and every descriptive field is per project.

---

## 4. Metadata model — recommendation

### 4.1 Schema: IPTC Core, JSON-shaped, one mapping table

Adopt the XMP/IPTC fields as the schema and keep the JSON keys plain. The mapping lives once, in the Kit, and is used by the importer (XMP/IIM/Exif → record), the exporter (record → XMP packet written into JPEG/HEIC/TIFF/DNG exports with `CGImageDestinationCopyImageSource` + `kCGImageDestinationMetadata`, and a `.xmp` sidecar beside raws), the Lightroom catalogue reader, and the index. Round-tripping a record through an export and back through ImageIO is the standards test.

```
AssetMetadata (edit-time, per asset; every field optional)
  title, caption, creator[], rights, rating (0…5)
  rightsStatus ("copyrighted" | "publicDomain" | "unknown"), rightsURL, usageTerms
  creatorContact { address, city, state, postcode, country, phone, email, website }
  location       { sublocation, city, state, country, countryCode }
  keywords[]                       ← dc:subject; this is where today's sceneTags go
  captured (ISO-8601 with offset)  ← exif:DateTimeOriginal + OffsetTimeOriginal
  camera { make, model, lens, serial? }, exposure { seconds, iso, aperture, focalLength, focalLength35 }
  gps { lat, lon, altitude, direction }
  dimensions { width, height }, orientation, software
```

| JSON key | XMP path | IIM dataset | Lightroom catalogue |
|---|---|---|---|
| `title` | `dc:title[x-default]` | 2:05 ObjectName | (XMP only) |
| `caption` | `dc:description[x-default]` | 2:120 | `AgLibraryIPTC.caption` |
| `creator` | `dc:creator` seq | 2:80 | `AgHarvestedIptcMetadata.creatorRef` |
| `rights` | `dc:rights[x-default]` | 2:116 | `AgLibraryIPTC.copyright` |
| `rating` | `xmp:Rating` | — | `Adobe_images.rating` |
| `rightsStatus` | `xmpRights:Marked` | — | `AgHarvestedIptcMetadata.copyrightState` |
| `rightsURL` | `xmpRights:WebStatement` | — | (XMP only) |
| `usageTerms` | `xmpRights:UsageTerms[x-default]` | — | (XMP only) |
| `creatorContact.*` | `Iptc4xmpCore:CreatorContactInfo/Ci*` | — | (XMP only) |
| `location.*` | `photoshop:City/State/Country`, `Iptc4xmpCore:Location/CountryCode` | 2:90/95/101/100/92 | interned refs |
| `keywords` | `dc:subject` bag (+ `lr:hierarchicalSubject` on export) | 2:25 | `AgLibraryKeywordImage` → `AgLibraryKeyword.lc_name` |
| `captured`, `camera`, `exposure`, `gps`, `dimensions` | `exif:`, `tiff:`, `aux:` | — | `AgHarvestedExifMetadata` |

Rules: lang-alt fields store `x-default` only (flag: multilingual titles are out of scope); `creator` is an array because the standard is a sequence; `rightsStatus` absent ≠ `unknown` only at the storage level — the panel shows Unknown for both.

### 4.2 Two layers: imported facts and edits

Every record has an `imported` block (what the file, sidecar or catalogue said, with `source: file | sidecar | catalogue`, re-derivable by re-reading) and a sparse `edited` block (what a person changed here). Display and export use `edited ?? imported`. This keeps the nondestructive constraint honest (the file's own statement is never overwritten in the record), makes "revert to file" free, and lets the panel say where a value came from.

### 4.3 Per asset, with project inheritance

`project` holds the project-level record; `assets["<relative file name>"]` holds per-asset records. Resolution: asset `edited` → project `edited` → asset `imported` → project `imported`. For a Photo project the asset and the project are the same thing and the panel edits the project record. For an interval project the panel edits the project record by default and offers "this frame only" — a five-star frame in a 5,030-frame set is exactly the Lightroom case in §6.

Assets are keyed by **file name**, the same key `framing.json` and `frames.whitebalance` use and the one that survives transfer; not by index (which differs by writer, Part 1 §3.3) and not by a new id.

### 4.4 Where it lives

A per-project **`metadata.json`** at the project root (an edit-time record, so the root by Part 1 §6.3's rule), `{schemaVersion: 1, project: AssetMetadata, assets: {name: AssetMetadata}}`, written atomically like the other sidecars, listed in the file registry, added to `transferableFiles`, and copied by the DNG-archive clone. Not inside `project.json`: a 5,030-frame set with Lightroom metadata on every frame is 5–10 MB of records, and the grade and file list must stay cheap to rewrite. The raw XMP packet is **not** embedded in the JSON — a Lightroom sidecar with AI masks is 242 KB of base64 (`_WEX3825.xmp`); the packet stays as the `.xmp` file that is already copied, and an embedded packet stays in its DNG or JPEG.

The index (§5) carries the searchable subset per asset and per project: title, caption, rating, creator, keywords, location city and country, captured, camera, lens, GPS.

### 4.5 Tags become keywords

`sceneTags` is a per-project list of free strings plus a closed taxonomy; `dc:subject` is a per-asset bag of free strings. Unify: tags **are** keywords. The taxonomy stays as curated chips (the AI tagger keeps emitting those values); the tag editor edits `keywords`; export writes `dc:subject`; the Lightroom import brings its keywords in as the same list. `sceneElements` stays what it is (a model's free description) and can be folded into `caption` suggestions later.

---

## 5. Scale — what was measured

Synthetic index entries of the shape §4.1's index would need (~390 B each: ids, kind, three dates, name, mode, frames, dimensions, rating, title, creator, city, country, blend list), on this Mac (M4 Max, internal SSD). The 2.3 MB manifest that exists today has 221 entries, so "10k" is 45× the current library.

| Projects | JSON index | Swift `JSONDecoder` | `JSONEncoder` (sorted keys) | filter + sort in memory | resident memory |
|---|---|---|---|---|---|
| 10,000 | 3.9 MB | 0.04 s | 0.05 s | 1 ms | 49 MB |
| 100,000 | 38.8 MB | 0.43 s | 0.53 s | 13 ms | 367 MB |
| 1,000,000 | 389 MB | 4.4 s | 5.3 s | 118 ms | **1,974 MB** |

| SQLite (WAL, indexes on `addedAt`, `(rating, city)`, `originID`, FTS5 over title/name/caption/keywords) | 100k | 1M |
|---|---|---|
| build from scratch | 0.8 s, 66 MB | 10.8 s, 661 MB |
| first page of 60 by date added | 0.05 ms | 0.06 ms |
| page at offset 300,000 | — | 4.7 ms |
| `rating ≥ 4 AND city = ?`, first 60 | 0.24 ms | 0.29 ms |
| lookup by origin id | 0.01 ms | 0.02 ms |
| FTS "bridge dusk", first 60 | 0.14 ms | 0.17 ms |
| update one rating | 0.03 ms | 0.04 ms |

| 100,000 project folders under `Projects/` | flat | sharded `Projects/<2 hex>/<uuid>` |
|---|---|---|
| `scandir` of the top level | 40 ms (100k entries) | 0 ms (256 entries) |
| full walk with a `stat` per project (the Part 1 reconciliation) | 0.51 s | 0.18 s |
| `ls -la` (sorted, every entry stat'ed, Finder-like) | 0.85 s | — |

What breaks first, by order of magnitude, with a phone at 5–10× these times and a 2–3 GB memory limit:

- **10k projects:** nothing new. Fix Part 1's R4 (the whole-manifest rewrite per grade tick) and R1/R2 first; those hurt at 221.
- **100k:** the whole-library-in-memory design fails on iPhone (seconds to launch, 367 MB before a single thumbnail); SwiftUI grids over a 100k-element array stutter; the launch reconciliation is still fine (0.5 s); `Thumbnails/` at 100k files is fine.
- **1M:** fails on the Mac too (4.4 s decode, 2 GB resident, 5 s to encode on every save); `Thumbnails/` and `SceneMasks/` need digest-prefix sharding; a full folder walk is ~5 s; Finder and Spotlight on the volume struggle; the transfer picker and any "list everything" screen must page.

A SQLite index has none of these cliffs at either size, and is faster than the JSON path even at 221. Part 1 argued against a database because reads were array scans and the truth would have needed a second representation; the truth still stays in per-project JSON — the database is the **index only**, a cache rebuilt from `project.json` + `metadata.json` files, which is exactly the reconciliation Part 1 §6.2 item 3 asked for. What changes: `AppModel.captures` stops being the library and becomes a window over queries; lists take pages; search is FTS5; filters are `WHERE` clauses. Part 1's "keep JSON, no database" stands for the truth layer and falls for the index layer, on these numbers.

Directory layout: leave `Projects/` flat. 100k is measured fine and 1M is a design horizon; sharding is a folder move that would also break Lightroom's own root-folder paths (§6), and the index can record a relative path per project so both layouts can coexist if it is ever needed.

---

## 6. The Lightroom catalogue — facts and a migration shape

`~/Pictures/Lightroom/Lightroom Catalog.lrcat`, 180 MB SQLite, read with `?immutable=1`:

| | |
|---|---|
| Images | 13,532 (6,792 DNG · 4,959 JPEG · 1,695 ARW · 86 MP4) |
| Capture span | 2026-05-26 → 2026-09-11; 12 camera bodies |
| Root folders | 13. **8 are `/Volumes/letslapse/Projects/<id>/source/` (9,701 images)**; `Source_SONY/…` 1,273; Desktop 1,567; `Pictures/2026` 991 |
| Rated > 0 | 1,258 |
| With caption / copyright | 793 / 1,081 |
| Keyworded | 728 images, 27 keywords in one hierarchy level (a conference: "day 0", "speakers dinner", …) |
| With GPS | 9,703 |
| Develop-edited | 5,743 |
| Collections | 9 |
| `copyrightState` | null on 13,531, `1` on one |

The largest Lightroom root folders are the `E33ED216` (5,030 frames) and `385DC396` (2,753 frames) LetsLapse projects. Lightroom is already being used as the per-frame metadata editor **over LetsLapse's own project folders**. Two consequences:

- **Per-asset metadata is the migration**, not an option: ratings, captions and keywords on individual frames inside interval projects are the bulk of what exists.
- **The truth files must not move.** Lightroom's root folders are absolute paths into `Projects/<id>/source/`. Any relayout of `Projects/` (sharding, renaming) breaks the catalogue's folder links until Lightroom is told; the index (§5) and the origin ids (Part 1 §6.4) must be introduced without moving a file.

**Migration shape** (a `lapse import-lightroom <catalog> --library <root>` tool, read-only on the catalogue):

1. **Attach.** For every catalogue root folder that is a LetsLapse `source/` folder, match images to frames by file name and write the per-asset `imported` records from the catalogue tables (rating, `captureTime`, pick flag, caption, copyright, interned creator/city/country/location/state, keywords, harvested camera/lens/GPS) **and** from the XMP beside or inside each file (title, rights URLs, contact block, the fields the catalogue does not table). Sidecar over embedded, catalogue over neither when they disagree on a field the catalogue owns (rating, keywords, pick).
2. **Create.** For standalone folders, one Photo project per image (3,800; the app's unit for a single asset), one video project per MP4 (86; QuickTime metadata keys differ from XMP — noted in §9). `originID` minted here; `importedFromID` nil.
3. **Grades.** Develop settings via the existing `LightroomImport` for Photo projects (already honest about what is lost). Per-frame develop edits inside an interval project have nowhere to go in the current model (grade is per project plus keyframes over time) — recorded as unsupported per frame, not silently dropped.
4. **Collections** (9) do not map onto LetsLapse collections (those are blended-clip timelines); import them as a keyword each, or as a saved search once the index exists.
5. **Never write the catalogue.** A later re-run of the tool is an idempotent re-attach keyed by `originID` + file name.
6. **Pin, verify, retire** (decided 2026-09-12, Part 3 §10.5). While the migration runs and until its counts are verified, the eight `Projects/<id>/source/` folders Lightroom references are pinned: no eviction, no rename. After verification Lightroom is retired and the pin removed; Lightroom is a one-time source, not a continuing editor.

Verification: per root folder, the catalogue's image count equals the attached-or-created count; every rated, captioned and keyworded image has a matching record; the four example files import with every §2 field present; an exported JPEG and DNG read back through ImageIO with the same values; Lightroom reads the exported DNG's XMP (the Adobe validation path from the DNG-archive work).

---

## 7. The Gallery panel — requirements, not a design

`GalleryPreviewPanel` today: title + date + size, Tags, "In frame" / Storage / Field notes rows, blended clips (`App/GalleryPreviewPanel.swift:62-89, 265-337`). Required additions, per the brief and §2:

- an **Info** group, read-only, from the record's `imported` layer: camera, lens, exposure line, captured (with offset), GPS (coordinates, a map link), dimensions and format, software;
- a **Metadata** group, editable, in this order: Title, Caption, Keywords (the existing tag editor), Rating, Creator, Copyright, Copyright status (Copyrighted / Public domain / Unknown), Copyright URL, Rights usage terms; **Creator contact** (address, city, state, postcode, country, phone, email, website); **Location** (sublocation, city, state, country, country code);
- a per-field indicator of "from the file" vs "edited here", with revert;
- for interval projects, a scope switch: this frame / whole project;
- a "Copy contact block from…" convenience, since creator contact is the same on every photo a person takes (Lightroom solves this with metadata presets).

Per `CLAUDE.md`, the SVG design specs come first and are not drawn here; this section is the content list for that design pass.

---

## 8. Amendments to Part 1's migration plan

Part 1 §7 stands. Additions, in the same phases:

- **Phase 1 (additive):** extract descriptive metadata at import into `metadata.json` (`imported` layer only); a one-time backfill over existing projects (ImageIO properties per source file — cheap, no pixel decode; the 5,660-frame project is a few seconds); unify tags into `keywords` (the `sceneTags` field stays readable, written as keywords from then on); add `metadata.json` to the file registry, `transferableFiles` and the DNG-clone copy list.
- **Phase 2 (dual-write `project.json`):** unchanged; `metadata.json` is a sibling, not a member.
- **Phase 3 (the index):** build it as **SQLite from the start**, behind one `LibraryIndex` type, rather than the JSON index Part 1 described — one implementation for every size, faster at 221, and the Lightroom migration needs the per-asset queries anyway. The truth stays in the per-project files; deleting the database must lose nothing, and rebuilding it is the reconciliation.
- **Phase 4:** unchanged, plus the Lightroom tool (§6) once Phase 1's records exist.
- **Design-sync:** the panel (§7) is a UI job with its own SVG-first pass; it depends on Phase 1's records, not on Phase 3.

Verification adds the four example files as fixtures (§6) and the export round-trip.

---

## 9. Gaps

1. **On-device timing** at 10k and 100k was not measured; the ratios above are estimates from the Part 1 iPad profile.
2. **Videos.** 86 MP4s in the catalogue; QuickTime metadata (`com.apple.quicktime.*`, XMP in a `uuid` box) needs its own reader and was not inspected.
3. **Multilingual lang-alt** values (`dc:title` in several languages): `x-default` only is proposed.
4. **Hierarchical keywords** (`lr:hierarchicalSubject`): the catalogue has one level; the model proposes a flat bag, with the hierarchy string preserved on export.
5. **Faces, people, pick/reject flags, colour labels** (`xmpDM:pick`, `xmp:Label`): present in the files, not in the requested list; the `imported` layer can carry them without a UI.
6. **Lightroom collections → LetsLapse:** no mapping exists; keywords or saved searches proposed.
7. **Writing metadata back into originals** is out of scope by the nondestructive constraint; only exports carry it.
8. **DNG-archive clones** must carry the source frame's XMP packet through the converter — not verified in this pass.
9. **Whether `sceneElements` and the AI title belong in the standard record** (they are model output, not statements by the photographer) — proposed as suggestions, not values.
