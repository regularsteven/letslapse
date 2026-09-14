# PicPlace sync, version two — the library binds to an account, the minimal dataset syncs, libraries merge

**Date:** 2026-09-14 · **Status:** plan agreed (Steven, 2026-09-14); nothing
implemented · **Working mode:** **code-first by decision** — "I want to test
the logic, and design can be a bit messy for now"; the SVG mirrors are
tidied once the sync logic is proven, per screen, in the same unit of work
that finalises the screen · **Environment:** `picplace.test` + Garage in
Docker until there is confidence, then `picplace.co` from this Mac and one
candidate iOS device · **Server:** PicPlace; its answers of 2026-09-14 are
condensed in §2, the asks that fall out of this plan are in
[picplace-sync-v2-server-asks.md](picplace-sync-v2-server-asks.md) ·
**Precedes:** [picplace-sync-v1.md](picplace-sync-v1.md) (what shipped) and
[picplace-integration-handover.md](picplace-integration-handover.md) (the
questions this plan answers) · **Programme:**
[data-model-server-portability-2026-09-12.md](data-model-server-portability-2026-09-12.md)
(Part 3 — the "server as the source of truth" model this is a slice of).

---

## 0. Steven's framing (2026-09-14)

Two storage modes. **Self storage** is always the starting point: the app
runs as is on an iPhone, iPad or Mac, captures, imports photos, videos and
LetsLapse projects, and owns the whole CRUD experience. **PicPlace
integration** is an additional centralisation on top — after it, the client
still owns the experience *until* a thing is synced.

- On macOS a person configures the storage path (Settings ▸ Storage ▸
  Library location) and the server (Settings ▸ PicPlace ▸ Server). **iOS and
  iPadOS have neither**: their storage never changes, and physical iOS
  devices only ever test against `picplace.co` (`.test` routing, local
  domains and certificates are not worth the headaches).
- On completing Sign in, every device checks whether the account has synced
  anything. **Clean** (server empty): ask whether to centralise the gallery on
  PicPlace (`picplace.test` or `picplace.co`), then sync the **minimal
  dataset** — records, metadata, adjustments/crops/keyframes, thumbnails,
  LUTs; everything except the assets, above all the source assets. **Fresh
  device** (no local gallery): retrieve the minimal dataset; any synced
  assets come down as previews, not originals. **Non-fresh device** with a
  synced account: merge (recommended), replace local with PicPlace, or replace
  PicPlace with local — the latter two behind consequence-stating
  confirmations.
- Heavy assets stay one-by-one for now; auto-sync of everything comes later.
  A thumbnail must go up so the second device sees the gallery; it cannot
  edit until the sources arrive.
- Object storage works best above ~1 MB, so PicPlace's S3 should hold source
  assets and rendered blends; the small stuff needs another home — care on
  both repos.
- Signing out before sync needs care; perhaps a reason to bring auto-sync
  forward.
- The Mac folder convention: `/Volumes/letslapse` unbound; after sign-in
  `/Volumes/letslapse/picplace.co/regularsteven` (or `picplace.test/…`).

## 1. Decisions

| # | Decision | Why |
|---|---|---|
| **D1** | The library binds to **`(server.id, user.uuid)`**. `username` and `name` are display only; the folder name uses the host and the username for humans. Until the server ships its `server` block, the binding records `url + user.uuid` and is upgraded in place. | `username` is editable and nullable on the server; `user.uuid` is minted once and is already the anchor of every object key. A host name is an alias, not an identity. |
| **D2** | **The binding is a file in the library** (`<root>/PicPlace/account.json`, §3.1), never the path and never `UserDefaults`. Sign-in alone only mints tokens; binding happens when the person answers the first-bind question (§4.1). | The binding must survive a moved folder, a renamed username, a second Mac adopting the volume; "sign in, look around, decline" must be harmless. |
| **D3** | **macOS nests by rename and relaunches**; **iOS binds in place** — no nest, no Server row, no library location. The Server row is macOS-only (and the Simulator in Debug). | Steven's convention on the Mac; on iOS the folder is invisible and the app cannot relaunch itself. |
| **D4** | Every piece of PicPlace state has one home (§3.2): binding and sync state in the library, tokens in the Keychain **per account**, the device id per install. | Two libraries on one Mac today share one server, one profile and one sync-record map keyed by bare capture UUID — they would lie to each other. |
| **D5** | The **minimal dataset** is defined by *kind*, derived from `ProjectFileRegistry` (§3.4): records + capture sidecars + posters + small authored inputs. `source/` frames and `blends/` are the heavy set. | "Projects folder, where suitable" resolves to kinds — the folder is not a unit. |
| **D6** | Per project the server holds: the manifest (`project.json`, inline), **one records bundle**, **one poster**, and hash-deduped LUT/ref objects; later the originals and blends as individual objects. Per account: one library bundle (needs a server surface). | Steven's small-object rule: S3 gets originals, blends and one poster; everything else is a bundle or a row. |
| **D7** | A project whose `assets.ndjson` lists source frames that are not on disk is **`previewOnly`** — derived from files, no new field, cacheable in the index. | The second device must show the gallery and refuse the editor without a new record to sync. |
| **D8** | **Merge is three-way per project on `originID`** with the sync record as the base (§4.4). Conflicts resolve by newest edit or by hand, with **Keep both**; the winner gets a fresh revision. | Without a base every difference is a conflict or a silent last-writer-wins. |
| **D9** | **Replace-local and replace-server are deferred** until presence tiers exist. | In the minimal era no original is on the server, so "replace local" always destroys originals that exist nowhere else; the truthful confirmation number needs tiers. |
| **D10** | **Sign-out drops the tokens and keeps the binding and every file.** "Disconnect this library" is the explicit unbind. The hard gate ("sign-out refused while originals are unconfirmed", Part 3 §10.6) arrives with eviction. | Nothing local is evicted in the minimal era, so nothing can be lost; the gate protects eviction, not sign-out. |
| **D11** | The server project key becomes **`originID`** (v1 sent `capture.id`). A server-arrived project is installed with `id == originID` and its folder named by it. | The handover's first open question; identity across devices is `originID`. |
| **D12** | Code-first for this whole unit of work; mirrors follow per screen once the logic holds. Test on `picplace.test` + Garage; `picplace.co` after confidence. | Steven, 2026-09-14. |

## 2. What the server answered (2026-09-14) — the facts this plan relies on

| Topic | Fact | Exists |
|---|---|---|
| Identity | `user.uuid` permanent per server instance (differs between `.test` and `.co`); `username` editable/nullable | ✅ |
| Instance | `/status` gains `server: { id, environment, url }` | to build |
| Devices | One `device_key` under two accounts = two rows, two token lineages; no "move device" | ✅ |
| Gate | `users.verified` stays manual (invite-only tier); admin toggle planned | ✅ |
| `uuid_taken` | global across accounts; receiver re-mints; `origin_uuid` index field offered | field to build |
| Revisions | client-supplied, monotonic per project; `=` is a replay; `updated_at` moves only on a manifest PUT | ✅ |
| Index | `?updated_since=`; `projects: { count, by_type }` in `/status` | to build |
| Tombstones | soft-delete, `?include_deleted=1`, 90 days; explicit push resurrects | to build |
| Assets | identity `(project, name)`; rename = full re-upload today; `PATCH /assets/{id}` rename and account-wide `(sha256, bytes)` dedupe via CopyObject offered | to build |
| Downloads | `POST /projects/{uuid}/assets/urls` (≤100) offered; URLs live 15 min → mint as you go | to build |
| Lifetimes | PUT 60 min, GET 15 min, from `/status`; single PUT ≤ 5 GB; multipart not built (a `422` at negotiate until it is) | partly |
| Presence | per `(project, device)`; nullable `tier` (`original`/`proxy`/`preview`) offered | to build |
| Manifest cap | **1 MB today** (nginx `client_max_body_size` default); plan 16M at nginx, 8 MB app cap reported as `manifest_max_bytes`, `413 manifest_too_large` | to build |
| Usage | `used_bytes` = manifest + confirmed assets; pending never counted; reaper 2 h–2 h 30 after negotiate; re-negotiating the same `name` before that refreshes the same upload | ✅ |
| Rate limit | 120/min per user; 300/device + 1,000/account offered | to build |
| Web | keyed by uuid (`/letslapse/p/{uuid}`), never username | policy |
| Bytes | PicPlace never processes LetsLapse bytes; the web view shows client-made `preview`/`proxy` objects; "import to Photos" is an explicit copy | policy |

Largest values on the real library today, for the caps: `project.json` 189 KB
(365 projects), `assets.ndjson` 4.0 MB, `source/capture_log.json` 3.5 MB, the
ramp log `source/frame-NNNNN.json` 8.0 MB, `frames.timestamps` 0.6 MB.

## 3. The model

### 3.1 Identity and the binding file

Three identities, unchanged from v1: **device** = `DeviceIdentity.id` (per
install), **account** = `user.uuid` on one server instance, **project** =
`originID`. The new fourth thing is the **library**, which binds to at most
one account.

`<root>/PicPlace/account.json` (format 1; `PicPlace` joins
`StorageRoot.libraryItemNames`):

```json
{
  "format": 1,
  "server":  { "url": "https://picplace.test", "id": null, "environment": null },
  "user":    { "uuid": "…", "username": "regularsteven", "name": "Steven Wright" },
  "boundAt": "2026-09-14T21:30:00.000Z",
  "boundByDevice": "<DeviceIdentity.id>",
  "initialSync": { "state": "pending", "case": "clean", "completedAt": null }
}
```

- A binding **matches** a session when `server.id` is equal (once known) or,
  before the server block exists, when the host and `user.uuid` are equal.
  `url` is what the app dialled; a mismatch between `url` and the server's
  own `server.url` is refused ("this address is not the server this library
  belongs to").
- `initialSync` is the flow's state machine (§4.1): the nest-and-relaunch on
  the Mac, a crash or a closed lid resume at launch from this record.
- The file is written first and read at launch by `PicPlaceController`,
  which resolves the session for the **open library**: bound + tokens for
  that account in the Keychain → signed in silently; bound + no tokens →
  "Sign in as *regularsteven*" (other accounts refused); unbound + a
  signed-in session → the first-bind question.

### 3.2 Where state lives

| State | v1 | v2 | Why |
|---|---|---|---|
| Server setting `letslapse.picplace.server` | `UserDefaults` | `UserDefaults` — but only the **default for the next sign-in on an unbound library**; a bound library's server is in its binding | the library knows its server; the setting seeds a new binding |
| Profile (`username`, `user.uuid`, `device.id`) | `UserDefaults` `letslapse.picplace.account` | `user` in the binding; `device.id` not stored — `POST /device` is idempotent at launch and its id is per `(account, device_key)` | |
| Tokens | Keychain, one item (`account = "tokens"`) | Keychain, **one item per `(host, user.uuid)`** (`kSecAttrAccount = "<host>|<uuid>"`); `letslapse.picplace.session` in `UserDefaults` names the last account signed in, for unbound libraries | switching libraries switches sessions without a new sign-in |
| Sync records (`syncedAt`, `revision`, files, bytes, `lastError`, `alsoOn`) | `UserDefaults` keyed by `capture.id` | `<root>/PicPlace/sync-state.json` keyed by **`originID`**; the `revision` is the merge **base** (§4.4). Rebuildable: this device's row in the server's `presence[]` carries the same revision | library-scoped; a base per library |
| Device id | `UserDefaults` `letslapse.deviceID` | unchanged | per install by design (Part 1 W2) |
| Poster | — | `Projects/<id>/poster.jpg` (§3.5), registered in `ProjectFileRegistry` as `derived`, travels | the receiver's tile |

### 3.3 The Mac library layout, and the nest

**Unbound**: the root is as today (`~/Library/Application Support/LetsLapse`
or the nominated folder, e.g. `/Volumes/letslapse`). **Bound**: the library
lives at `<root>/<host>/<username>/` — `/Volumes/letslapse/picplace.co/regularsteven`
— and `storage.libraryRootPath` points there. The old root keeps what was
never the library (`Source_SONY`, `Exports_testing`, `.Spotlight-V100`…),
which is exactly what `libraryItemNames` exists to guarantee.

The nest is a **rename, not a copy** (`StorageMover` copies and never deletes,
by design; the nest is a new, small operation beside it — same volume by
construction, so each item is an instant `moveItem`):

1. Create `<root>/<host>/<username>/PicPlace/` and write `account.json` there
   (`initialSync.state = pending`).
2. Write a marker at the old root, `<root>/.letslapse-nested` →
   `{ "to": "<nested path>" }`.
3. Release `Projects/.lock`; move every `libraryItemNames` item that exists.
4. `StorageRoot.commit(destination: nested)`; remove the marker; relaunch
   (`AppRelaunch` — the sheet-dismiss-then-terminate order in
   `relaunchNow()` stands).

Crash safety: at launch, a root that holds the marker and no `Projects/`
follows the marker if the nested folder holds a `Projects/`, commits, and
carries on — a half-done nest is never an empty gallery. The relaunch is
honest, not lazy: `StorageRoot.current` is a `static let`, and the
persister, the index and two singletons latch their URLs at first use.

**Thumbnails survive the nest** by a one-line change: `ProjectThumbnailCache.key(for:)`
keys by path relative to `StorageRoot.current` for files under the root
(today: relative to `$HOME`, else absolute — a nest under `/Volumes` would
invalidate all 1,229 tiles and re-decode every DNG on the next launch).

**iOS**: the sandbox library binds in place; `PicPlace/account.json` in the
sandbox root; one account per device (Part 3 §10.6). Debug defaults to
`picplace.test` **on the Simulator only** (`targetEnvironment(simulator)`);
a Debug build on a physical device defaults to `picplace.co` like Release.

### 3.4 The minimal dataset

Measured on `/Volumes/letslapse` (365 projects; frames per project p50 3,
p90 309, max 5,665):

| Set | Files | Per project | Sync | Server shape |
|---|---|---|---|---|
| **Records** (edit-class, mutable) | `project.json`, `metadata.json`, `assets.ndjson`, `shapes.json`, `overlays.json`, `masks/`, `fonts/`, `notes/`, `source/documents.json` | 10 KB – 5 MB | on every change | `project.json` inline as the manifest; the rest in the **records bundle** |
| **Capture sidecars** (capture-fact + derived, immutable after the run) | `source/frames.timestamps`, `frames.exposure`, `capture_log.json`, `sequence.json`, `framing.json`, `frames.whitebalance`, the ramp log `frame-NNNNN.json`, `liveblend-*.json` | 0 – 12 MB | in the bundle (or a separate immutable `capture` bundle if edit-churn on 12 MB matters — open) | bundle |
| **Poster** | `poster.jpg` (§3.5) | ~100 KB | when the grade token changes | one `preview` object |
| **Authored inputs** | `luts/*` (140 files / 125 MB across 101 projects, ~0.9 MB each, mostly copies), `ref/*` | ~1 MB each | once by hash — the server's account-wide dedupe makes the LUT copies free | `lut` / `ref` objects |
| **Library records** | `Collections/collections.json`, `custom_presets.json`, `light_ladders.json`, `blend-profiles.json`, `luts.json` + the library's cubes | a few MB | on every change | **one account bundle — the server has no account-level surface yet** (ask) |
| **Heavy** (later, one by one) | `source/` frames, `blends/` (147 files / 13.4 GB, none over 5 GB), Collection and Shape-mation renders | GBs | explicit, later automatic | `source` / `blend` objects |
| **Never** | `Index/`, `Thumbnails/`, `SceneMasks/`, `Logs/`, `CaptureLogs/`, `Incoming/`, `tmp/`, `library.json`, `dng-archive.json` (`travels: false`), `.DS_Store`, unregistered strays at a project root | | | derived or device state |

Rules:

- The inventory is **derived from `ProjectFileRegistry`**, not from a folder
  walk: `class == .edit` and the `source`-location sidecars go in the bundle;
  `source/` media and `blends/` are the heavy set; anything unregistered at a
  project root is skipped and logged (v1's walk uploaded a stray
  `frame-00001-graded.jpg` as a `note`). The ramp log (`frame-NNNNN.json`) and
  `liveblend-*.json` are not registered today — register them (pattern
  entries) so the bundle carries them.
- **`assets.ndjson` carries the hash and bytes of every source frame**, so
  the second device knows exactly what exists without holding a byte of it,
  and the later "upload originals" is a hash negotiate the server already
  answers with "no upload needed" for anything it holds.
- **The bundle is an Apple Archive** written by the Kit's `DirectoryArchive`
  (lzfse — what `.lapse` uses) over a staged directory of the members, named
  `records.aar`, uploaded as one `records`-kind asset (ask) with its own
  `sha256`; unchanged members do not help, the bundle's hash changes — that
  is the accepted cost of one object per project (a few MB per edit).
- The **manifest cap** is read from `/status` (`manifest_max_bytes`; assume
  1 MB until the server reports one). Over the cap, the manifest is uploaded
  as a `manifest`-kind asset and the PUT carries `{ "manifest_asset": "<id>" }`
  — the server's own overflow shape. No project today is within 5× of it.

### 3.5 The poster

`Projects/<id>/poster.jpg`: the project's graded poster frame, ~1280 px long
edge, JPEG q0.7 (~100 KB), rendered by the **pushing** device at sync time
through the existing graded-thumbnail path (`ProjectThumbnailCache` renders
graded tiles at 480 px; the poster is the same render at 1280) and
re-rendered when `grade.cacheToken` changes. The receiver's tile is
`poster.jpg` through the normal thumbnail cache (keyed by *its* path and
mtime — a real local file, so the cache works unchanged), preferred whenever
the project is `previewOnly`. One poster per project in v2; per-blend
posters are a follow-up.

### 3.6 Project states on a device

| State | Rule | UI |
|---|---|---|
| `full` | every source frame in `assets.ndjson` is on disk | as today |
| `previewOnly` | some listed source frame is missing | poster tile + badge; detail card "Not on this device · Download originals"; editor refuses; rename/tag/delete allowed |
| per blend | a blend listed in the record whose file is missing | row shows "on PicPlace"; play refuses |

Derived on demand from files (an existence pass per project — the
`validatedSourceFrames` tickets already exist), cached in the index as one
column refreshed by the reconciler's per-folder step.

## 4. The flows

### 4.1 Sign in → bind → the three cases

1. **Sign in** (Settings ▸ PicPlace) mints tokens for `(host, user.uuid)` and
   registers the device. Nothing else changes.
2. If the open library is **bound to this account** → done (signed in).
   Bound to **another** account or server → refused with the owner named.
3. **Unbound** → `GET /status` (`projects.count` once it exists; `GET
   /projects` until then) decides the case:
   - **clean** (server has 0 projects): *"Centralise this library on PicPlace
     as regularsteven? Every project's records and a preview go up now;
     originals stay here until you upload them."* Accept → bind (Mac: nest +
     relaunch) → push all (§4.2). Decline → nothing.
   - **fresh** (library has 0 live projects): bind → pull all (§4.3).
   - **merge** (both non-empty): bind → merge (§4.4).
4. `initialSync.state` goes `pending → done` when the case's last step
   completes; a launch that finds `pending` resumes the case.

### 4.2 Push (minimal) — one project

Replaces v1's "every file" walk with `SyncPolicy.minimal` in
`PicPlaceSyncRun`:

1. Render/refresh `poster.jpg` if the grade token moved.
2. Stage the bundle members (§3.4) and write `records.aar` under `tmp/`.
3. `PUT /projects/{originID}` — `name`, `type`, `revision`
   (`Int(capture.modifiedAt ms)`), `captured_at`, `origin_uuid` when the
   project derives from another, manifest inline (or the overflow shape).
   A first PUT creates and claims; otherwise claim first.
4. Negotiate `records.aar` (`records`), `poster.jpg` (`preview`), `luts/*`
   (`lut`), `ref/*` (`ref`) with `sha256` + `bytes`; PUT what comes back with
   an upload; confirm; presence with the revision; release.
5. Write the sync record (base = this revision).

`SyncPolicy.originals` is v1's walk restricted to `source/` and `blends/`
(§4.5); `.everything` is both. Nothing is deleted on the server by a push;
a locally removed member is deleted explicitly.

### 4.3 Pull — one project onto this device

1. `GET /projects/{uuid}` → the manifest and the asset list.
2. Create `Projects/<originID>/` (`id == originID`), write `project.json`
   from the manifest, fetch `records.aar` and extract its members into
   place, fetch `poster.jpg`.
3. `LibraryIndex.upsertProject` from the document bytes — the lists render
   it at once; the reconciler's next pass finds it current.
4. Write the sync record (base = the server revision). Presence with the
   revision (tier `preview` once tiers exist).

No `source/` folder is created; the project is `previewOnly` by rule. The
existing `.lapse` installer is *not* reused: it re-mints ids on purpose, and
a pull must not.

### 4.4 Merge — a non-fresh library meets a non-empty account

Per project, keyed by `originID`. **base** = the revision in this library's
sync record for that project (absent when this library never synced it).

| Local | Server | Action |
|---|---|---|
| live, unknown to the server | — | push |
| — | live | pull → `previewOnly` |
| revision == server revision | | nothing (record the base) |
| moved past base | at base | push |
| at base | moved past base | pull (records only; `source/` and `blends/` untouched) |
| moved past base | moved past base | **conflict** |
| tombstoned in `.trash` | live | push the delete (soft) — a conflict if the server moved past base |
| live | tombstoned | *"Deleted on PicPlace from iPad on 13 Sep"* → restore (push resurrects) or delete locally |
| no base, both live, revisions differ | | conflict (a LAN-transferred twin, or a `.lapse` installed on both) |

Conflicts are presented once, after the non-conflicting rows have run:

- **Auto merge (most recent edit)** — the conflict rows resolve by revision.
- **Check manually** — one row per project: poster, name, *"This Mac ·
  edited 14 Sep 10:12"* vs *"PicPlace · edited 13 Sep 21:40 · from iPad"*
  (the pusher is the presence row whose revision equals the server's; ask
  for `updated_by` to make it exact). Per row: keep this device's, keep
  PicPlace's, or **Keep both** — the loser is re-minted as a fork
  (`derivedFromOriginID` locally, `origin_uuid` on the server).
- **The winner gets a fresh revision** — `max(local, server) + 1` — so the
  server accepts it (a "keep local" on an older stamp is otherwise a `409
  stale_revision`) and the other device sees it move.

`409 uuid_taken` (the same `originID` under another account) → re-mint
locally as a fork and retry, exactly as `.lapse` does. Per-field
last-writer-wins (the phase-6 journal) later makes most conflict rows
disappear; nothing here is thrown away when it lands.

### 4.5 The heavy paths — per project, on demand

- **Upload originals** — `SyncPolicy.originals`: negotiate `source/` and
  `blends/` by hash (batches of 100), PUT four at a time, confirm, presence
  tier `original`. Objects over 5 GB wait for multipart (none exist today).
- **Download originals** — `GET /projects/{uuid}` lists the assets; mint
  URLs in pages of 100 *as you download* (they live 15 min); write into
  `source/`; the project leaves `previewOnly` when the last listed frame is
  on disk.

Both are the v1 machinery with a kind filter; neither is automatic in v2.

### 4.6 Sign-out and disconnect

- **Sign out**: revoke this device, drop the tokens for the account, keep the
  binding, the sync state and every file. The Settings card says *"This
  library belongs to regularsteven on picplace.co — Sign in"*; N projects
  with local changes not on PicPlace is shown as information, not a block.
- **Disconnect this library** (a separate, confirmed action): remove the
  binding and the sync state; projects stay; they keep their `originID`s, so
  pushing them under another account forks them (`uuid_taken`).
- The hard gate — sign-out refused while originals are unconfirmed — ships
  with eviction, where it is what makes eviction safe.

### 4.7 Deferred, and where it goes

Auto-sync policy (on capture / on edit / Wi-Fi only, background transfers);
proxies (the 6–8 MP lossy DNG tier — `LossyLinearDNG` exists in the Kit);
presence tiers and eviction ("free up space safely"); replace-local and
replace-server (D9); per-blend posters; the account-level library bundle
once the server has a surface; the `apply(change)` funnel and journal (data
model M5), which turns whole-record pushes into journal batches.

## 5. Stages

| Stage | Lands | Server needs | Proven by |
|---|---|---|---|
| **0** | This plan; the asks handed over | — | agreed shapes |
| **1** | `PicPlace/account.json`; sync state in the library keyed by `originID`; Keychain per account; the guards; Mac nest-by-rename + marker + relaunch; root-relative thumbnail keys; iOS Server row hidden, Simulator-only `.test` default; `LL_PICPLACE_NEST` hook | nothing | play-pen sign-in → `…/LetsLapse/picplace.test/regularsteven/` → relaunch → same project; the Release app unaffected; `lapse index --verify` |
| **2** | `SyncPolicy.minimal`: the registry-derived inventory, `records.aar`, `poster.jpg`, LUT/ref dedupe, `originID` as the key, the manifest cap | `records` kind (a `note`-kind bundle works meanwhile), `origin_uuid` | ≤ 3 objects per project in Garage; a second push transfers 0 |
| **3** | First-bind decision (clean / fresh / merge), the fresh pull, `previewOnly` (tile badge, detail card, editor refusal) | nothing (`GET /projects` exists; `projects.count` when it lands) | Mac scratch root A pushes, Simulator root B pulls; posters in the gallery; `lapse index --verify`; the reconciler adopts the pulled folders |
| **4** | Three-way merge with the base, the conflict list (auto / manual / Keep both), fresh revision for the winner, tombstones both ways, re-mint on `uuid_taken` | tombstones, `updated_since` (nice), `updated_by` (nice) | a scripted matrix over scratch roots (the M2 rig's `matrix-*.sh` style): every row of the §4.4 table |
| **5** | Upload originals / Download originals per project; `previewOnly` clears; background-safe cancellation | batch URLs, the negotiate `422` over 5 GB | Simulator both ways; then one physical iPhone against `picplace.co` — ask first |
| later | §4.7 | change feed, tier, multipart, `PUT /library` | — |

Stage 3 and 4 add screens; by D12 they are built in code first and their
mirrors drawn afterwards (the platform `INDEX.md` rows carry 🟡 until then).
Stage 1's only visible change is Settings-card copy.

## 6. The test rig

- **Play-pen** = the default location, `~/Library/Application Support/LetsLapse`
  (1 project today), which the Release app already runs on; `/Volumes/letslapse`
  stays mounted and is never a target of anything in this plan. The way back
  is Settings ▸ Library location ▸ Change… → `/Volumes/letslapse`, which must
  read **"Switch to This Library"** — if it ever reads "Move Library", cancel
  (that path copies 431 GB onto the internal disk).
- **Agent runs** use scratch roots through the argument domain
  (`-storage.libraryRootPath <scratch>`, Debug binary, private DerivedData)
  and a second device through `-letslapse.deviceID <uuid>` —
  `DeviceIdentity` reads `UserDefaults`, so the argument domain wins without
  persisting. **A scratch run never calls `StorageRoot.commit`**: in Debug,
  a root that came from the arguments makes `commit` log instead of write,
  and `AppRelaunch` re-passes the new root as an argument.
- **Until stage 1 lands, PicPlace state is per install**: a sign-in from a
  scratch run is visible to the Release app (same defaults domain and
  Keychain service). Every run is followed by a launch with
  `LL_PICPLACE_SIGNOUT=1`, which revokes the device and clears the tokens.
- **Device 2 is the iOS Simulator** against `picplace.test` (trusts the
  Valet CA after the one-time `xcrun simctl keychain <udid> add-root-cert`;
  its own sandbox, its own device id). Garage: `./dev/garage/setup.sh` in
  the PicPlace repo; the server's tests (`composer test`) are the executable
  spec of the endpoints.
- **Physical devices** only against `picplace.co`, only after confidence,
  and only after checking the device is idle.
- **Hooks to add**: `LL_PICPLACE_NEST=1` (run the nest on the current root
  without a server — stage 1), `LL_PICPLACE_BIND=clean|fresh|merge` (stage
  the first-bind screens without a server), `LL_PICPLACE_POLICY=minimal|originals`
  (which policy Sync runs), `LL_PICPLACE_CONFLICTS=<n>` (stage the conflict
  list); the existing `LL_PICPLACE=<state>`, `LL_PICPLACE_TOKENS`,
  `LL_PICPLACE_SERVER`, `LL_PICPLACE_SIGNIN`, `LL_PICPLACE_SIGNOUT` stay.

## 7. Traps recorded

- **M4 breaks the adopt check.** `StorageRoot.check(destination:)` recognises
  a library by `Projects/library.json`; when data-model M4 retires the export,
  the volume would be offered as a *move*. `check` must learn "a `Projects/`
  folder holding documents is a library" before `library.json` goes.
  (Recorded in TODO's data-model entry.)
- The manifest cap is **1 MB in production today**, not the documented 8 MB.
- Thumbnail keys embed the path (relative to `$HOME`, else absolute) and the
  mtime — a nest or a relocation invalidates every tile (fixed in stage 1).
- The unsandboxed Debug and Release builds share one defaults domain and one
  Keychain service; a sandboxed build would not (Part 1 R7).
- `NSApp.terminate` while a sheet is up is swallowed — `AppRelaunch` already
  dismisses first; keep that order for the nest.
- Two libraries can hold the same `originID` (LAN transfer, `.lapse`); the
  merge's "no base" row exists for them.
- A project's top level can hold strays (a 5 MB `frame-00001-graded.jpg`, a
  190 KB `.DS_Store`); v1's walk uploaded the former as a `note`.

## 8. Open points

1. **Bundle vs rows** for the records — the PicPlace developer's call
   (§3.4: one object per project, or a JSON column in the DB with S3 for
   posters only).
2. Split the immutable capture sidecars into their own bundle, or accept the
   re-upload of up to 12 MB per edit.
3. The account-level library bundle needs a server surface (`PUT /library`
   or a reserved pseudo-project) — not in stages 1–5.
4. Per-blend posters (66 projects have blends).
5. Whether the Simulator's `picplace.test` default should be a setting on the
   Simulator too, or stay a Debug constant.

---

## 9. Stage 1 — landed 2026-09-14 (uncommitted)

**What shipped**

- **Kit** `Library/PicPlaceBinding.swift`: `PicPlaceBindingRecord` (format 1;
  `server {url,id,environment}`, `user {uuid,username,name}`, `boundAt`,
  `boundByDevice`, `initialSync {state,case,completedAt}`), the account key
  `<host>|<uuid>`, `matches(host:userUUID:serverID:)` (the instance id wins
  once both sides know it), read/write/remove at `<root>/PicPlace/account.json`;
  4 tests (`PicPlaceBindingTests`).
- **Sync state in the library**: `App/PicPlace/PicPlaceSyncState.swift`
  writes `<root>/PicPlace/sync-state.json` keyed by `originID`; the
  controller's records moved there (v1's `UserDefaults` map is migrated once
  for the projects this library holds, then removed).
- **Keychain per account**: `PicPlaceKeychain.load/save/clear(account:)`;
  v1's single item is re-keyed under the stored profile's account once.
  `PicPlaceClient` derives the API base from its tokens' `server` (never the
  setting) and writes refreshed pairs back under the account.
- **The session follows the library** (`PicPlaceController`): bound + tokens
  → signed in; bound + no tokens → *Sign in as @user*, sign-in goes to the
  binding's server, another account's `/status` is refused before the device
  is registered (`LibraryMismatch`); unbound → the last sign-in
  (`letslapse.picplace.session`) and the connect question. `libraryLink`
  (unbound · bound · mismatch), `canSync`, `connectLibrary()`,
  `disconnectLibrary()`; sign-out keeps the binding and the records (D10).
  A binding made before the server reported an instance id takes it the
  first time `/status` carries one.
- **Mac nest by rename** (`StorageRoot.nest`): marker
  `<root>/.letslapse-nested` → the `libraryItemNames` renames → the binding
  written into the destination → `commit` → marker removed → `AppRelaunch`.
  `AppModel.prepareForLibraryNest` flushes, refuses writes and releases the
  lock first. The launch resolution follows a marker whose destination holds
  `Projects/`. `PicPlace` joined `libraryItemNames`.
- **Scratch-run safety**: `StorageRoot.rootCameFromArguments` — `commit`
  logs instead of writing and the relaunch re-passes
  `-storage.libraryRootPath <new> -ApplePersistenceIgnoreState YES`.
- **Thumbnails keyed root-relative** (`~lib/<path>` when under the root).
- **Configuration**: `defaultServer` is `picplace.test` only for Debug on the
  Mac or the Simulator; `showsServerSetting` hides the Server row on iOS.
- **Views** (copy-only, D12): the Settings card's LIBRARY rows (Connect this
  library / Library @user on host / Disconnect this library… / Sign in as
  @user) and the connect question (`PicPlaceConnectAlert`, also on the
  project card); the status card's `notConnected` state.
- **Hooks**: `LL_PICPLACE_NEST=<host>:<username>` (bind + nest with no
  server), `LL_SCROLL=picplace` (Settings lands on the card),
  `LL_PICPLACE=not-connected`.
- `PPStatus` decodes the server's new `server`, `projects` and `limits`
  blocks when present.

**Verified** (Mac Debug build, scratch roots, no server): the nest hook on a
seeded root moved `Projects/…` into `<root>/picplace.test/regularsteven/`,
wrote the binding, did not touch `storage.libraryRootPath`, relaunched on the
nested root (lock taken there, 1 document walked, 1 current); the bound
signed-out Settings card reads *Sign in as @regularsteven · This library
belongs to @regularsteven on picplace.test · Server picplace.test · Disconnect
this library…*; a staged half-finished nest (marker + moved folders, no
commit) was followed at launch and the marker removed. Kit tests 4/4.

**Awaiting Steven's hand** (the consent page is his step): sign in on the
play-pen from the Debug build (`~/Library/Developer/LetsLapseRun/dd-mac-picplace/
Build/Products/Debug/LetsLapse.app`, no arguments — the default location),
answer *Connect* to the question → the library nests into
`~/Library/Application Support/LetsLapse/picplace.test/regularsteven/`, the
app relaunches signed in with the LIBRARY row; then a per-project Sync on the
one project (v1's push, now allowed only on a connected library), Sign out
(binding kept) and Sign in as @regularsteven again. Way back: Settings ▸
Library location ▸ Change… → the volume, which must read *Switch to This
Library*.

**Known, by decision**: after a nest the thumbnails are re-rendered once
(the key changed shape for every file under the root); a burst of "can't
open …Thumbnails/….jpg" lines on the next launch is expected. A stray
`Thumbnails/` or `Logs/` can appear at the old root if a background render
lands during the ~1 s between the renames and the relaunch — caches, harmless.

## 10. Stage 2 — landed 2026-09-14 (uncommitted), awaiting the play-pen push

**What shipped**

- **`PicPlaceSyncPolicy`** (`minimal` · `originals` · `everything`;
  `App/PicPlace/PicPlaceSyncPolicy.swift`). A Sync runs `.minimal`;
  `LL_PICPLACE_POLICY` overrides it. The originals' button is stage 5.
- **Classification by the registry**: `ProjectFileRegistry.entry(forRelativePath:)`
  governs every file — root records and `source/` sidecars → the bundle;
  `poster.jpg` → a `preview` object; `luts/` → `lut` objects; `source/` media
  and `blends/` → the heavy set; `masks/ fonts/ notes/` → the bundle; a file
  the table does not know → skipped and logged. Pattern entries
  `source/frame-*.json` (the ramp log) and `source/liveblend-*.json` were
  registered; `poster.jpg` was registered as a derived root file that
  travels. `ref/` is **not** registered (it is not written by the app — one
  project holds hand-dropped reference pictures) and is skipped; register
  it if you want it carried (open point).
- **The records bundle** `records.aar`: members hard-linked into
  `tmp/picplace-records/`, archived with the Kit's `DirectoryArchive` in a
  new **content-only field set** (`TYP,PAT,DAT`) — the default set stored
  ctimes, which every hard link bumped, so the same members gave a different
  archive on every run and would have re-uploaded on every sync. Verified
  byte-identical across two runs (`07efff3c…`); members restore byte for
  byte (`aa extract`). Sent as one `records`-kind asset, replaced whole.
- **The poster** (`App/PicPlace/PicPlacePoster.swift`): the project's
  `thumbnailURL` rendered through `PhotoGrader.render` / `VideoGrader.gradedFrame`
  at 1280 px, JPEG 0.7, written to `Projects/<id>/poster.jpg` before the
  walk; the grade token is kept on the sync record (`posterToken`) and the
  file is reused while it matches.
- **`originID` is the server key** (D11): `PUT /projects/{originID}`,
  `GET` by it too; `origin_uuid` carries `derivedFromOriginID`.
- **The manifest cap**: `limits.manifest_max_bytes` from `/status` (1 MB
  until reported); over it the manifest goes up as a `manifest`-kind asset
  and the PUT carries `{ "manifest_asset": id }` — a stub PUT first, which
  creates and claims. `LL_PICPLACE_MANIFEST_CAP=<bytes>` forces the path.
- **Records and captions**: `PicPlaceSyncRecord` gained `policy`,
  `heavyFiles`, `heavyBytes`, `posterToken`; the card reads *Records +
  preview · 173 KB · 1,480 originals stay here (86 MB)*.
- **Dry run**: `LL_PICPLACE_DRYRUN=latest|<uuid>` classifies, bundles and
  renders with no server, logging the inventory.

**Verified** on the scratch copy of *Perf bench 1480* (1,480 frames): manifest
48.5 KB inline; bundle = `assets.ndjson` 423 KB + `source/frames.timestamps`
120 KB + `metadata.json` → `records.aar` 94.6 KB; heavy set 1,480 files /
86.0 MB left; poster 78 KB, 1280×960; no strays. A minimal sync of that
project is three objects where v1 sent 1,483.

**Awaiting Steven's hand**: *Sync again* on both play-pen projects — the
negotiate should send `records.aar` + `poster.jpg` (two uploads) and leave
the 1,481 source objects v1 uploaded untouched (a push never deletes); a
second *Sync again* should move nothing. Kit tests: 8/8 in the touched suites.

**Stage 2 follow-ups from the first play-pen run (2026-09-14 night):**

- **Signed out on every relaunch** — a Keychain asymmetry since v1: the Debug
  build has no keychain entitlement, so `save` fell back to the login
  keychain, but `load` only fell back on `errSecMissingEntitlement`/`errSecParam`
  and the data-protection query answered `errSecItemNotFound`. `load` and
  `save` now fall back on anything short of success. Verified: a scratch
  library bound to Steven's account signs in silently from the login
  keychain (Account · This device · On PicPlace · Library · Server ·
  Disconnect · Sign out).
- A refused refresh now **re-reads the Keychain before signing out**: refresh
  tokens rotate, and a second instance (a window, a test run) that refreshed
  first has stored the newer pair — adopt it rather than clear it.
- **Scratch roots never borrow the install's session** (Debug, macOS): an
  unbound root from the launch arguments starts signed out unless
  `LL_PICPLACE_TOKENS` says otherwise. The controller logs the session
  resolution at launch (`picplace: session <key> — tokens found …`).
- Copy: the Library row says *Connected on 14 Sep 2026 at 21:59* (it read
  "Connected 46 minutes ago" and was taken for the sign-in time); the synced
  caption ends with *· 2 uploaded* or *· nothing needed uploading*.
- **"Edited 4 minutes ago" without a human edit**: the record's `modifiedAt`
  moved at 22:50:00 and the poster re-rendered on the next push (the grade
  token changed), so a grade write happened — most likely the viewer
  persisting a normalised default on open. `updateCapture` now logs the
  changed top-level fields on every stamped edit (Debug) so the next one is
  attributable. For stage 4 this matters: a derived-field write that stamps
  `modifiedAt` would read as a conflict; the classification of what counts
  as an edit (`CaptureProject.modifiedAt`'s own rule) is the thing to hold
  to.
- The second push of *China Pics-1849* uploaded 1 object (the poster; the
  bundle hashed identical and was skipped) — the determinism fix holds on
  the real server.

## 11. Stage 3 — landed 2026-09-14 (uncommitted), the play-pen's merge owed

**What shipped**

- **The first connection** (`App/PicPlace/PicPlaceLibrarySync.swift`,
  §4.1): once the library is loaded (`AppModel.isLibraryLoaded`, set at the
  end of every launch path) and the session is up, a bound library whose
  `initialSync.state` is `pending` compares the account's index with its
  own by origin id and runs the rows that need no base — **pull** what the
  server has and it lacks, **push** (minimal) what it has and the server
  lacks, **note as in step** what both hold at the same revision (recording
  the base), and **count as deferred** what both hold at different revisions
  (stage 4). The case (`clean` · `fresh` · `merge`) is written to the
  binding; `state` becomes `done` when nothing failed and nothing was
  deferred, else it stays `pending` and re-runs at the next launch (the
  finished rows are idempotent). A Settings row shows it: *Bringing projects
  here… · 2 brought here · 2 in step*, then *Library in step with PicPlace*.
- **The connect question knows its case**: before it is raised, `/status`
  and the local count decide the line — *Nothing is on PicPlace yet…* /
  *PicPlace holds N projects and this library is empty…* / *PicPlace holds
  N, this library M…*. `LL_PICPLACE_BIND` stages it.
- **The pull** (§4.3): `GET /projects/{uuid}` twice (typed for the assets,
  raw for the manifest — `PicPlaceClient.getData`), the overflow stub
  followed, the document decoded with the Kit's decoder; `records.aar`
  extracted into `Projects/<originID>/` and `poster.jpg` written, each
  through a presigned GET from `POST /projects/{uuid}/assets/urls`; a
  project pushed before the bundle existed (v1) has its loose sidecars
  collected by their registry role instead. `AppModel.registerPulledProject`
  inserts the document with `id == originID` (D11), the blends re-keyed to
  it and their files absent, `addedAt` now — nothing re-minted. The sync
  record's base is the server's revision (`policy: pull`); presence is
  posted at tier `preview`. A failure removes the folder.
- **Preview-only** (§3.6, D7): `AppModel.sourcesMissing` (listed frames,
  none on disk) and the controller's `isPreviewOnly` (missing + a poster
  or a pull record — a project whose files simply vanished is not this).
  `thumbnailURL` falls back to `poster.jpg`; `ProjectThumbnailView` shows a
  poster as the finished image it is (image kind, no grade on top); the
  Projects pill (outline cloud), the card (*Preview only · The originals —
  3 files · 4,9 MB — are on PicPlace, not on this device*, a disabled
  *Download originals* until stage 5) and the detail's Play original
  (shows the poster) follow it. The editor already refused: `editorAsset`
  is nil without sources.
- The controller is created at the end of the launch (it was lazy, and an
  empty library's Projects tab never drew a card to create it — so a fresh
  library never synced).

**Verified on scratch roots bound to the account** (Debug, `picplace.test`):
the **merge** case on a records-only copy of the play-pen — *2 to pull, 0
to push, 2 in step, 0 deferred → done*, the two residue projects arriving
with their tags and grades, a second launch not re-running; the **fresh**
case on an empty library — *4 to pull → done*, China Pics with its poster
standing in, the others as placeholders (v1 pushes carry no poster). The
pulled card and the Settings row screenshotted. Mac + Simulator build.

**Awaiting**: the play-pen's own merge at Steven's next relaunch (2 pulled,
2 in step); the Simulator as a true second device — its own sign-in, an
empty library, the fresh case (the consent page is Steven's step).

**Noted for later**: v1-pushed projects have no poster, so they arrive as
placeholders until the pushing device re-syncs them under the minimal
policy; the disabled *Download originals* is drawn in the accent colour
(cosmetic, mirrors owed by D12); the deferred rows (both sides moved) are
stage 4's.

**Simulator sign-in (2026-09-15):** the first Simulator sign-in failed with
Keychain `-34018` (`errSecMissingEntitlement`): the project scoped its iOS
entitlements to `sdk=iphoneos*` and the run skill built the Simulator app
with `CODE_SIGNING_ALLOWED=NO`, so the app carried no entitlements and the
Simulator's keychain refused it (v1's Simulator run had injected tokens
behind a swallowed `try?`). Fixed by `App/LetsLapse-Simulator.entitlements`
(`application-identifier`, `keychain-access-groups`, `get-task-allow`) bound
to `sdk=iphonesimulator*` in the project, and the skill's simulator build
signing ad-hoc (`CODE_SIGN_IDENTITY=-`) instead of not at all. Verified: the
iPhone 16 Pro Simulator signed in, connected as the **fresh** case and pulled
all four projects — the second device the plan asked for.

## 12. Stage 4 — landed 2026-09-15 (the merge, continuously)

**What shipped** (`App/PicPlace/PicPlaceChangeSync.swift`,
`PicPlaceConflictsView.swift`):

- **A check** — at launch once the first connection is done, whenever the
  app comes to the front (rate-limited to one a minute), and from *Check
  PicPlace now* in Settings — reads the **whole** account index with
  tombstones and applies the §4.4 table by origin id with the sync record's
  revision as the base: new there → pull; new here → push (minimal); only
  this device moved → push; only the server moved → **pull-update** (the
  bundle's members and the poster refreshed on disk, the record replaced —
  `AppModel.applyPulledUpdate`, keeping `addedAt` and any blend only this
  device knows); deleted here and unchanged there → the delete pushed
  (claim, `DELETE`, a tombstone); everything else becomes a **conflict**.
  A shoot being written defers the check. `updated_since` is deliberately
  NOT used yet: an incremental index lists only what the server changed,
  and a project only this device edited sits beside an unchanged server
  row — the watermark is stored for a later, incremental pass at scale.
- **Conflicts** (`Conflict.Kind`): both edited · unrelated (no base) ·
  deleted on the server while held here · deleted here while changed
  there. Settings shows *N projects need your decision — Review*; the
  project card *Needs your decision · Review…*; the sheet lists each with
  *This device · edited … / PicPlace · edited … from <device>* and offers
  keep this device's / keep PicPlace's / **keep both** (the tombstone rows:
  restore to PicPlace / delete here too; delete on PicPlace / bring it back
  here), plus *Use the most recent edit for all*. Keep-local re-stamps the
  record (`markEdited`) so the push carries a fresh revision; keep-both
  forks this device's version (`AppModel.forkProjectForKeepBoth`: folder
  renamed, new id and origin, `derivedFromOriginID`) and pulls the server's
  into the original's place.
- **`409 uuid_taken`** on a push re-mints the project as a fork and pushes
  again; a tombstoned project answers the claim with `409 project_deleted`
  and the push resurrects it.
- **Revision rounding**: the document encoder rounds stamps to the
  millisecond while the revision truncated — a device read its own
  document back one millisecond off and re-pushed on every launch. One
  `revision(of:)`, rounded, everywhere.
- A failed handshake at launch no longer costs the launch its check.

**Verified between two scratch devices on `picplace.test`** (device B via
`-letslapse.deviceID`), each row logged: new here → pushed / new there →
pulled; a rename on A pushed, pulled as an update on B; both edited →
conflict on B, resolved by newest (B's, re-stamped) and pulled by A; both
edited → keep both on B (fork `34E1…` pushed, the original taken from the
server), the fork pulled by A; deleted on A → tombstone → B's
*deleted on PicPlace* resolved by deleting locally; deleted on B while
edited on A → *deleted here, changed there* resolved by bringing it back;
then two clean checks. The sheet and the Settings rows screenshotted.
Throwaway projects tombstoned afterwards.

**For the PicPlace developer** (found on the way): `status.projects.count`
counts tombstones (6 with 5 live); one `500 SQLSTATE[40001] Deadlock … insert
ignore into cache` from `/status` under concurrent requests of one device —
the rate limiter's cache store.

**Not exercised**: `uuid_taken` (needs a second account), the *unrelated*
kind (the same branch as both-edited).
