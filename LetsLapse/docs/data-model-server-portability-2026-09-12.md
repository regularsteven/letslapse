# LetsLapse — Data Model Audit, Part 3: Server as the source of truth

**Date:** 2026-09-12 · **Builds on:** [Part 1](data-model-audit-2026-09-06.md) (inventory, identity, index) and [Part 2](data-model-scale-and-metadata-2026-09-12.md) (scale, IPTC metadata, Lightroom) · **Type:** investigation report, no implementation

Steven's framing (2026-09-12): long term, a server is the source of truth, the mobile and macOS clients share one data model, not every DNG lives on every device but assets move between them from time to time, every device needs previews for browsing, and the whole thing is a Lightroom alternative with its own cloud integration. The question: does the data model under discussion support that, and when one project gets one metadata edit, what moves from the editing device to the server and on to the other clients?

---

## 0. Summary

- **Today's model: no.** No identifier survives a device hop, nothing carries a revision, deletion is a folder removal, the library is one document, thumbnails are keyed by local path, and every descriptive field is per project (Part 1 §4.1, §5; Part 2 §3).
- **The Parts 1–2 proposal: yes, with five additions.** Stable origin ids, per-asset records, recipes as data, and an index separated from the truth are exactly the properties sync needs and exactly what those parts already propose. What has to be added: revisions and tombstones on records, a per-device change journal behind one mutation funnel, asset keys with content hashes, presence tiers (original / proxy / preview), and a classification of every store into capture fact, edit, or cache (§3).
- **The shape that results** is the Lightroom CC shape — canonical records in the cloud, a local materialisation on every client, a smart-preview tier, originals on demand — with one deliberate difference: each client's materialisation is the same inspectable JSON in the project folders, so the app keeps working offline and the files stay readable without the app.
- **One edit, end to end:** a few hundred bytes leave the phone, the server assigns a revision and appends to a feed, and the Mac and iPad each rewrite one project's metadata file and one index row. No media, no renders, no caches move (§4).
- **Two constraints of the original brief change.** "Clients are the source of truth" becomes "the server is canonical for records and, once a device is signed in, for originals too; a device holds leases"; "single writer" becomes per-field last-writer-wins for metadata and a server lease for structural edits (§5). Both were decided by Steven on 2026-09-12 together with folder naming, preview generation, Lightroom's retirement and the account model; all six decisions are recorded in §10, and the build order that ships the local store before any server is in §12.

---

## 1. What "server as truth" changes, and what it does not

| Concern | Brief (2026-09-06) | Now | Consequence for the model |
|---|---|---|---|
| Authority over records | client | **server** | records need revisions the server assigns; clients apply, never decide |
| Authority over presence | client | client (unchanged) | a client reports what it holds; the server records claims with a confirmed time |
| Concurrent editing | one device at a time, no merges | still no CRDTs; but three devices will edit the same project on different days and sometimes the same day | per-field last-writer-wins by server order; a lease only for structural edits |
| Consumption format | JSON files | JSON files on every client, JSON documents on the server | one schema; the server also keeps a relational index of the same fields |
| Hot path | append-only, no database | unchanged | the change journal is itself NDJSON append-only |
| Media | not synced | originals move on request; previews everywhere; proxies optional | three tiers, addressed by asset key, with presence per device |

Nothing in the JSON schema of Parts 1–2 changes. What changes is bookkeeping around it.

---

## 2. Every store, classified for sync

The class decides everything: whether a store syncs, when, and whether it needs change tracking.

| Class | Meaning | Stores | Sync behaviour |
|---|---|---|---|
| **Capture fact** | written once by the run; immutable afterwards | `frames.timestamps`, `frames.exposure`, `capture_log.json`, `sequence.json`, `documents.json` (scanner), `dng-archive.json`, the in-project experiment log, the copied `.xmp` sidecar | uploaded once with the project, addressed by content hash; never diffed |
| **Edit** | a person's decisions | `project.json` (name, grade, preset state, keyframes, WB source, bad-frame nominations, hide flag), `metadata.json` + per-asset records, `overlays.json` + `masks/` + `fonts/`, `notes/`, `shapes.json` (the drawn part), `framing.json` `stabilisation` block, blend recipes, collections | revisioned; every change goes through the journal |
| **Derived** | rebuildable from an edit plus the originals | blend outputs, collection renders, corrected scanner pages, `framing.json` measurements, `frames.whitebalance`, shape detections, scene masks | not synced as records; optionally shared as a derived asset with a hash |
| **Cache** | device-local by nature | `Thumbnails/` (today), `SceneMasks/`, `Logs/`, `CaptureLogs/`, `Incoming/`, `tmp/` | never |
| **Device state** | one device's own | `UserDefaults`, `blend-profiles.json` (per device model), `light_ladders.json`, `custom_presets.json`, `luts/` | not synced in v1; presets, ladders and LUTs are candidates for a later "account settings" sync |

Two stores move class: thumbnails become a **shared preview tier** once they are keyed by asset rather than by local path, and `frames.whitebalance` stays derived but is cheap to share for devices without the raws.

---

## 3. The five additions

### 3.1 Revisions and tombstones

Every syncable record — project, per-asset metadata record, blend, collection — gains:

```
revision      Int        server-assigned, monotonic per record; 0 = never synced
editedAt      {field: ISO-8601}      per field, client clock, for the UI and as a tiebreak
editedBy      {field: deviceID}
deletedAt     ISO-8601?  tombstone; the record stays until every device has seen it
```

Deletion splits into two operations that the original brief's presence idea already implied: **delete** (a tombstone that reaches every device; local bytes are then purged by policy) and **evict** (this device drops its copy of the originals; only its presence row changes). Today `deleteCapture` removes the folder and persists afterwards (Part 1 §5); with a server both become records first.

### 3.2 The change journal, behind one mutation funnel

`Sync/journal.ndjson` per device, one line per change, appended and flushed like the capture sidecars (Part 1 §6.1):

```json
{"seq":1234,"at":"2026-09-12T08:31:02.117Z","device":"D-…","op":"set",
 "entity":"asset","project":"O-…","asset":"frame-00042.dng","field":"title",
 "value":"Charles Bridge at night","base":17}
```

`op` ∈ `create` (carries the whole document), `set`, `unset`, `delete`, `restore`, `evict`; `base` is the project revision the client had. `Sync/state.json` holds `{deviceID, lastAckedSeq, serverCursor}`. The journal is also the local undo/audit trail and the test oracle (§9).

This requires that **every mutation goes through one `apply(change)` API** that updates the in-memory model, rewrites the affected project file, updates the index row, and appends the journal line. Part 1 counted 35 persist sites; the single-persist-queue fix already wants them funnelled. This is the largest code change in the whole programme and the one on which everything else rests.

### 3.3 Asset keys and content hashes

An asset is `(project originID, relative file name)` — the key `framing.json` and `frames.whitebalance` already use and the one that survives a transfer — plus `contentHash` (SHA-256 of the file, computed at capture or import, backfilled once). The hash is what lets two devices agree they hold the same DNG, what names previews and proxies on the server, and what makes an upload idempotent. Cost: about ten milliseconds per 10 MB frame on a phone; the 431 GB Mac volume backfills in hours, once, in the background.

Blends and collection renders are derived assets with the same key shape and a hash. Blend ids and collection ids stay UUIDs.

### 3.4 Presence and tiers

Per asset, per device: `original`, `proxy`, `preview`, or absent, with `confirmedAt`. Clients report after a scan; the server never infers.

| Tier | What | Size (this library) | Who makes it |
|---|---|---|---|
| preview | ~2048 px JPEG/HEIC for browsing and the panel | ~58 KB each; 13,532 assets ≈ 0.8 GB | the holding client at import/capture (the existing `Thumbnails/` generator, re-keyed by hash), uploaded once |
| proxy | an editable stand-in without the original: the lossy 6–8 MP DNG the archive work already produces | ~1.3 MB each; ≈ 18 GB | the holding client, on request or by policy |
| original | the DNG/ARW/MOV | 431 GB | stays where it was captured unless requested; the server stores it only if that policy is chosen |

The existing LAN project transfer (Part 1 §4.4) becomes the fast transport for originals between two devices that are on the same network, driven by the server's presence map and keyed by origin id instead of re-minting a project id.

### 3.5 Origin id as the folder name for synced projects

Part 1 §6.4 keeps the local `id` as the folder name and adds `originID`. For a project that arrives from the server, name the folder by `originID` so paths agree across devices and Lightroom's folder links (Part 2 §6) hold. New captures mint `id == originID`. The `.lapse` archive path keeps re-minting, because an archive can cross between users.

---

## 4. Flows

### 4.1 One metadata edit (the question asked)

1. **iPhone.** The user sets a title on frame 42 of project P. `apply(change)` updates the in-memory record, rewrites P's per-asset record (edited layer, `editedAt.title`, `editedBy.title`), updates the index row, appends one journal line of a few hundred bytes with `base: 17`.
2. **Push.** When online, the journal since `lastAckedSeq` is posted as a batch. The server applies each line to P's canonical document under per-field last-writer-wins, assigns revision 18, appends to the change feed, and returns acks and the new revision. Retries are idempotent on `(device, seq)`.
3. **Mac and iPad.** Each holds a feed cursor and receives the change by push or by polling `changes since cursor`. A device that holds P's records rewrites P's per-asset record and index row, refreshes the panel. A device that has never seen P receives P's index summary and can show its preview immediately; it fetches P's full records only when P is opened.
4. **What does not move.** No DNG, no render, no cache, no capture facts (already there or fetched with the project).

Bytes on the wire: one change and its feed entry. Bytes on disk per client: one project file rewrite and one index row.

### 4.2 Other operations

| Operation | Journal | Server | Other devices |
|---|---|---|---|
| New capture on iPhone | `create project` with the documents (project, metadata imported layer, capture facts by hash) | stores documents, revision 1, presence iPhone:original | index row + preview appear; originals not fetched |
| Grade edit on the Mac | `set project.adjustments` (the whole adjustments struct is one field) | LWW on that field | rewrite `project.json`, re-render previews lazily |
| Blend rendered on the Mac | `create blend` (recipe + stats + output hash) | blend record; presence Mac:original for the output | blend entry appears; output fetched on demand, or re-rendered from the recipe by any device holding the originals |
| iPad asks for P's originals | none (a presence query) | presence says iPhone and Mac hold them | LAN transfer from whichever is reachable, or from the server if it stores originals |
| Delete on the iPad | `delete project` | tombstone, revision bump | each device shows it gone; local purge by policy; the presence rows explain what is being lost — the original brief's "deleting with visibility" |
| Evict on the iPhone | `evict` | presence iPhone:preview only | nothing changes for them |
| Lightroom migration on the Mac | `create` / `set` per asset, thousands of lines | ordinary batches | ordinary feed |

### 4.3 Materialisation rule on every client

Apply a feed batch in memory, rewrite each affected project file **once**, update the index, then refresh the UI. Never rewrite a file per change: an interval project with per-frame Lightroom metadata is 5–10 MB of records (Part 2 §4.4), and a burst of a thousand changes must not mean a thousand atomic rewrites on a phone. Part 2's single `metadata.json` should therefore split into `metadata.json` (project-level) and `assets.ndjson` (one line per asset, latest line wins on read, compacted at idle) — the same append-then-compact pattern as `frames.timestamps`.

---

## 5. Conflicts

- **Metadata and grade fields:** per-field last-writer-wins, ordered by server receipt, with the client's `editedAt` as tiebreak and for display. This handles "title on the iPhone, rating on the iPad" with no lock and no merge logic, which is what the brief's "no CRDTs" asks for in spirit.
- **Structural edits** — deleting or re-keying frames, removing a project, rewriting `sourceFileNames`, replacing the grade timeline wholesale — take a **server lease** on the project with a short TTL. Without the lease the client is refused and shows which device holds it. This keeps the single-writer rule where last-writer-wins would corrupt.
- **Offline:** the journal accumulates; on reconnect it is pushed; a stale `base` does not reject field edits (LWW still applies), only structural ones, which the client rebases or drops with a message.
- **Two Mac instances on one root** (Part 1 R6) are unchanged by this and still need the lock file; the journal makes the damage visible but does not prevent it.

---

## 6. The server, to the extent it is now in scope

Only the shape the client model needs; nothing more is designed here.

| Server-side | Holds |
|---|---|
| `projects` | `originID`, owner, `revision`, the canonical `project.json` document, `deletedAt` |
| `assets` | `(originID, fileName)`, `contentHash`, the canonical per-asset record, `revision` |
| `blends`, `collections` | canonical documents |
| `changes` | the feed: `seq`, project, entity, key, field, value, device, server time |
| `devices`, `presence` | device registry; `(asset, device, tier, confirmedAt)` |
| index tables | the same searchable subset the client index carries (Part 2 §4.4), for a web view and for cross-device search |
| object store | `previews/<hash>`, `proxies/<hash>`, optionally `originals/<hash>` |

Endpoints the flows need: post a change batch (returns acks and revisions), get changes since a cursor, get a project's documents at its current revision, put presence, get a preview or proxy by hash, take and release a lease. A headless Laravel instance with JSON columns and an object store covers all of it; the XMP mapping table (Part 2 §4.1) can be ported to PHP for server-side export, or exports stay client-side.

---

## 7. Sizing for the current library

| | Count | Per item | Total |
|---|---|---|---|
| canonical records | 13,532 assets + 221 projects | ~1 KB | ~14 MB |
| change feed | one line per edit | ~300 B | a year of heavy editing is tens of MB |
| previews | 13,532 | ~58 KB | ~0.8 GB |
| proxies | 13,532 | ~1.3 MB | ~18 GB |
| originals | 13,532 | 3–47 MB | 431 GB |

Records and previews are cheap to hold on any server. Proxies and originals are a per-project policy, and the presence map is what makes leaving originals on one device a visible decision instead of a guess.

---

## 8. What stays exactly as it is

The JSON schema of every record (Parts 1–2), the capture-time sidecars and their NDJSON writers, blend and collection recipes as data, the `.lapse` archive for handing a project to another person, the LAN transfer as a transport, the storage root layout with `Projects/` flat, and the rule that a client's files are readable without the app or the server.

---

## 9. Amendments to the migration plan

Additions to Part 1 §7 and Part 2 §8, in the same numbering:

- **Phase 1 (additive):** `originDeviceID` (already proposed) and a per-install `deviceID`; `contentHash` on every asset at capture and import, with a background backfill; `revision: 0`, `editedAt`, `editedBy` on the edit-class records; tombstones instead of folder removal.
- **Phase 2:** `metadata.json` + `assets.ndjson` per project (§4.3), both in the file registry and in `transferableFiles`.
- **Phase 3:** the SQLite index (Part 2 §8), now also holding the feed cursor and presence rows.
- **Phase 5 (new, still without a server):** the `apply(change)` funnel and the local journal. This ships value on its own: undo history, an audit trail, and the test in the next line.
- **Phase 6:** the server and the sync layer, outside this repository.

**Verification that falls out of the design:** replaying a device's journal from an empty tree must reproduce its materialised project files byte for byte after canonical re-encoding; and applying the server's feed from cursor 0 on a second device must reproduce the same files. Those two replays are the whole correctness test for sync, and they are cheap.

---

## 10. Decisions taken (Steven, 2026-09-12)

1. **Conflicts: option A.** Any device edits any field at any time; the last change wins per field, ordered by server receipt. Only structural edits (deleting or re-keying frames, deleting a project, rewriting the file list, replacing a grade timeline wholesale) take a short server lease (§5).
2. **The server owns the originals.** A device owns an asset only until it is signed in and the server has it; from then on a device holds a **lease**: a cached copy of the DNG or other heavy asset for a period that varies with the device's storage, after which it evicts down to the small preview. Two rules follow and are binding:
   - **Ownership transfers per asset, by hash.** A device may evict an original only after the server has confirmed it holds bytes with the same content hash. Sign-in does not transfer anything by itself.
   - **Eviction is a local policy over the presence tiers**: a storage budget, pinned projects, and last-touched order. It needs no new record type; it changes presence rows.
3. **Folder name = `originID`, for projects that arrive from the server.** Existing folders are never renamed (their `originID` may differ from the folder name for the 75 imported projects); the index maps origin id to folder. New captures mint `id == originID`.
4. **Previews are made by the most recent device to touch or edit the asset.** A preview reflects the current grade, so the editing device must hold the original or a proxy to render one; a device holding only a preview asks the server for a proxy first (or the server re-renders, once it holds originals). Uploaded once per edit, replacing the previous preview by hash.
5. **Lightroom is retired after a verified one-time migration.** The migration plan is Part 2 §6, plus: Lightroom's root folders under `Projects/<id>/source/` are **pinned** (no evict, no rename) until the migration is verified against the catalogue's counts; the catalogue is then closed and the pin removed. Lightroom's in-place XMP writes change whole-file hashes of DNG and JPEG, so the asset hash should be taken over the image data where the format offers a digest (DNG carries `NewRawImageDigest`) and over the whole file otherwise.
6. **Accounts.** Three identities: device (minted at install), account (attached at sign-in, owns projects on the server, carries the quota), project (`originID`, minted locally, independent of the account). Rules:
   - The app works fully with **no account**; the journal simply waits.
   - Sign-in on a device with a library **claims** every local project into the account; nothing is renamed or re-keyed; records and previews upload first, originals in the background under the hash rule. A project the server already holds under the same origin id (from another of the user's devices) merges per field by decision 1.
   - Authentication lives in the **Laravel instance**: Sign in with Apple plus email; the WordPress site only links to it.
   - **One account per device** in version one.
   - **Sign-out is refused** while any original is unconfirmed by the server; after that the user chooses between keeping records and previews as a read-only view or wiping.
   - A **plain per-account quota**, no per-project "originals only on my Mac" override in version one.
   - **Sharing with another person** is version two, as a permission on the project record; version one keeps the `.lapse` archive.

---

## 12. Build order: the local store first, the server later

Steven's intent (2026-09-12): implement the local data-store changes now so that they are server-ready, with the server itself several milestones away. Everything below runs and pays for itself without a server.

| Phase | What ships | Value without a server | Server-readiness it buys |
|---|---|---|---|
| 1 | `originID`, `originDeviceID`, a per-install `deviceID`; `contentHash` at capture and import with a background backfill; `revision: 0`, `editedAt`, `editedBy` on edit-class records; tombstones instead of folder removal; one persist queue; persist-before-delete; experiment log to NDJSON (Part 1 §7) | fixes R1–R6 of Part 1; duplicate detection by origin; deletion becomes reversible | identity, hashes and revision fields are exactly the sync keys |
| 2 | per-project `project.json`; `metadata.json` + `assets.ndjson` with the `imported` and `edited` layers; descriptive metadata extracted at import; tags become keywords; the file registry (Part 1 §6.3, Part 2 §4) | the metadata panel and the four example files; a grade tick no longer rewrites the library | the per-project documents are the canonical documents the server will store verbatim |
| 3 | the SQLite index, rebuilt from the per-project files; paged lists; FTS search (Part 2 §5) | scale beyond 10k; search; the Gallery at Lightroom size | the index also holds the feed cursor and presence rows later |
| 4 | launch reconciliation from folders; the macOS lock file; `Incoming` for `.lapse` staging (Part 1 §7) | recovers orphans; two Mac instances become safe | reconciliation is the same routine as "rebuild from the server's feed" |
| 5 | the `apply(change)` funnel and the per-device journal (§3.2); presence tiers recorded locally; a local eviction policy that shrinks projects to previews when the user asks (§10.2) | undo and audit history; the journal-replay test; "free up space" on a phone | the journal is the upload unit; presence rows are the claims the server will record |
| — | the `lapse import-lightroom` tool (Part 2 §6), after phases 1–2 | the migration itself, with the pin from §10.5 | its output is ordinary journal lines |
| 6 | the server and the sync layer (§6), Sign in with Apple and email, quota, leases | — | — |

Two things to hold to while building phases 1–5 without a server: every record that will be canonical must already be a whole JSON document a server could store as-is, and every mutation must already produce a journal line. If both are true at phase 5, phase 6 is transport and authority, not a data-model change.

---

## 11. Gaps

0. The decisions in §10 were taken in conversation; the eviction policy's actual budget rules and the lease durations are not specified.
1. No server or sync code was prototyped; the flows are argued from the record shapes, not measured.
2. The push transport (APNs, long-poll, or periodic poll) is not chosen; it changes latency, not the model.
3. Authentication, transport security and encryption at rest are not designed.
4. Cellular budgets for previews (0.8 GB for this library) need a policy.
5. Hash backfill time on the 431 GB volume over USB was estimated, not measured.
6. Videos' preview tier (poster frames, scrubbing proxies) is not specified.
7. The watch and WatchConnectivity are unaffected and were not considered.
