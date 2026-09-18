# Libraries — several on a Mac, one on a phone until it connects, and the server learns what a library is

**Date:** 2026-09-16 · **Status:** plan agreed in conversation (Steven,
2026-09-16); nothing built yet · **Working mode:** **code-first by decision**
("Code-first, and yes include the server ask") — the SVG mirrors are drawn
per screen once each screen has settled, in the unit of work that finalises
it; until then the platform `INDEX.md` rows carry 🟡 · **Server:** the asks
that fall out of this plan are in
[libraries-server-asks.md](libraries-server-asks.md), handed to the PicPlace
side to build independently (Steven, 2026-09-16) · **Precedes:** [picplace-sync-v2-plan.md](picplace-sync-v2-plan.md) (the
binding, the minimal dataset, merge) and
[picplace-sync-v2-handover.md](picplace-sync-v2-handover.md) (what shipped,
what is owed) · **Programme:**
[data-model-server-portability-2026-09-12.md](data-model-server-portability-2026-09-12.md)
(Part 3 — presence tiers and eviction, which stage D is the first slice of).

---

## 0. Steven's framing (2026-09-16)

The immediate problem: Settings ▸ Storage ▸ **Library location** can only
*move* the library into a folder (a copy) or *adopt* a folder that already
holds one. There is no way to start a **new, empty library** in a folder —
which is exactly what testing needs — and "Move back to the default
location" now offers to copy the 431 GB volume onto the internal disk,
because the default location stopped being a library the day the play-pen
nested itself into `picplace.test/regularsteven/`.

The direction, agreed after three future scenarios were put on the table:

- **A client works 100 % before any server integration.** Self storage is
  always the starting point (v2 plan §0); everything in this plan that runs
  on a Mac without an account is local.
- **iPhone and iPad hold ONE library until they connect.** Nothing to
  configure, nothing to choose — the sandbox is the library (v2 D3).
- **A Mac can have several libraries** in several locations: create new
  ones, open existing ones, switch between them, move them. One library is
  open at a time; switching is a relaunch, as it is today for a location
  change.
- **Several libraries per account, all backed up.** A person may keep a
  *client X* library, a *personal* one and a *timelapse gallery*, and want
  all three on PicPlace. So the server learns what a library is: **account ⊃
  libraries ⊃ projects** — the Lightroom-Classic-catalogs-with-cloud model,
  not Apple Photos' one-cloud-library rule. This also removes a real
  collision (§2.5) instead of policing it.
- **Once connected, a phone can work in any of the account's libraries**:
  it shows one *active* library at a time, captures and imports land there,
  and it can pull another library's previews. On the phone a library is a
  **filter over one store**, never a second storage root (§2.4).
- **Moving a library without its originals.** A finished job on a big volume
  whose originals PicPlace already holds can move to a small disk carrying
  only its records, posters and outputs; the projects become preview-only
  there and the originals stay on PicPlace (and on the old volume until the
  person deletes it). This is eviction wearing a move's clothes (§3.6).
- **Sharing a library with a client** is a later feature request; the server
  model chosen here is what makes it possible (a library row can have
  members), so nothing today should close that door.

## 1. Decisions

| # | Decision | Why |
|---|---|---|
| **L1** | **A library has an identity file at its root**, `<root>/letslapse-library.json`: a client-minted uuid, a name, when and by which device it was created. Written on first launch for libraries that predate it. In the Kit (`LibraryIdentity`) so `lapse` and the audit read it. | Today a library is recognised by `Projects/library.json`, which data-model M4 retires (the trap in TODO). A folder name is not an identity: usernames change, folders move, drives get renamed. The uuid is also what the server will key the library by (L8). |
| **L2** | **`StorageRoot.check` recognises a library by the identity file, or by a `Projects/` folder holding documents, or (until M4) by `Projects/library.json`.** An empty folder is `.empty`, and *the door decides* what that means — a new library or a move — rather than `check` calling it a move. | Closes the M4 trap now; makes "Create New Library" possible at all. |
| **L3** | **The Mac keeps a registry of known libraries** (`storage.libraries` in UserDefaults: uuid, path, name, last opened), shown as Settings ▸ Storage ▸ **Libraries**, replacing the "Library location" + "Move back to the default location" rows. The identity file is the truth; the registry is the list. Removing from the list never touches disk. | The two rows assume exactly one library and one "default"; with nesting and testing there are already three roots on Steven's Mac (`/Volumes/letslapse`, the nested play-pen, the empty default container). |
| **L4** | **One library open per launch; switching is a relaunch.** `StorageRoot.current` stays a `static let`; every door out of the Libraries list ends on the Relaunch button that exists today. | The persister, the index and two singletons latch their URLs at first use (v2 plan §3.3); an in-session root swap is the riskiest change in the app and buys nothing a relaunch does not. |
| **L5** | **Creating a library copies nothing; switching copies nothing; nothing here deletes.** Create = folder + identity file + `Projects/` + registry + commit + relaunch (`loadLibrary()` bootstraps the rest). Move stays a copy that never deletes. `/Volumes/letslapse` is only ever a *switch* target. | The whole point of the request. |
| **L6** | **A library the person created and placed stays where they put it.** The connect-time nest (`<root>/<host>/<username>/`, v2 D3) stays for the *unnamed* library at a storage root — Steven's convention — and is not applied to a library that already carries an identity and a chosen folder. Libraries the app pulls for a fresh device are placed by the app, under a folder the person picks once (default: the default location). | `/Volumes/Work/ClientX` being renamed under `picplace.co/regularsteven/` on connect would surprise; the identity file already says whose the library is. **Open for Steven** (§8.1) — the convention was his. |
| **L7** | **Per-library PicPlace state that was per install moves into the library**: the session pointer for an unbound library (`PicPlace/session.json`) and the *Sync changes automatically* / *Upload originals automatically* switches (`PicPlace/settings.json`, **one entry per device** — a volume carried to another Mac never arrives with uploads on). **Upload originals is OFF by default everywhere, switched on only by the person for this device and this library, never by sign-in or connect, and never stored on the server** (Steven, 2026-09-16: the client owns the storage constraints). *Only on Wi-Fi* stays per install — it is a property of the device, not of the data. **A new library starts signed out** and offers "Sign in as @regularsteven" when tokens for an account already exist in the Keychain. | Today any unbound library borrows the install's last sign-in and inherits `autoOriginals` (ON on Steven's install): a test library would offer to connect to the real account and, on yes, start uploading its originals. |
| **L8** | **The server gets libraries as rows** — `letslapse_libraries` (client uuid, owner, name, tombstone) and a nullable `library_id` on projects, null meaning *the account's default library*. `/libraries` CRUD, `?library=` on the index, `library` on the project PUT and row, `status.libraries[]`, a `features.libraries` flag. **Object keys do not change**: `u/{user}/p/{project}/…` — the library is a relation, not a path segment; moving a project between libraries is a row update; account-wide dedupe keeps working; usage stays per account for billing with a per-library breakdown for display. | The scenarios in §0. Additive and backward compatible: a v2 client that never sends `library` keeps working against the default library. |
| **L9** | **The binding record gains `library: { uuid, name }`** from stage A, before the server knows libraries. A local library binds to exactly one server library `(server.id, user.uuid, library.uuid)`; the uuid is the identity file's. | So stage C is a migration of `matches()` and the request scope, not of the file format. |
| **L10** | **Replica rule.** Until stage B: on one install, an account may be bound from at most **one** library — connecting a second library to the same account is refused with the first named. From stage C: at most one local copy of a given *server library* per install; different server libraries under one account coexist freely. | Presence is unique per `(project, device)`, the device is resolved from the token, tokens are per account per install: two local libraries holding the *same* projects under one account would overwrite each other's presence and tier. Library scope makes their project sets disjoint, which is what dissolves the collision (§2.5). |
| **L11** | **On iOS a library is a filter, not a root.** Each project document carries an optional `library` (the server library uuid; nil = unassigned, the default library); the phone shows an *active library*, captures and imports land in it, previews of other libraries pull into the same `Projects/`. The Mac writes the same field from its root's binding at push time. | The one-root sandbox stays; switching is instant; no in-session root swap on the platform that cannot relaunch. A field that lived only in the index would be lost on rebuild; documents are the truth (M1). |
| **L12** | **Move-without-originals is gated per project by server truth**: `source/` media may be left behind only where every frame listed in `assets.ndjson` is confirmed on PicPlace; projects that fail the gate move whole and the sheet says how many. Blends move (they are what the person works with). The mover still copies and never deletes. | Truthful by construction; the same gate is per-project eviction ("Free up space") next, and the sign-out hard gate after that (v2 D10). |

## 2. The model

### 2.1 The identity file

`<root>/letslapse-library.json` (format 1; joins `StorageRoot.libraryItemNames`):

```json
{
  "format": 1,
  "id": "9C1F2A6E-…",
  "name": "letslapse",
  "createdAt": "2026-09-16T09:30:00.000Z",
  "createdByDevice": "<DeviceIdentity.id>",
  "createdWith": "0.1.0 (build)"
}
```

- `name` defaults to the folder name; editable in the Libraries list
  (renaming the file's `name` only — folders are never renamed by a rename).
- Written by the app on the first launch of a library that lacks it (the
  volume, the play-pen), the way the export is regenerated: self-healing,
  logged once.
- A library **moved** (copied) by the mover keeps its uuid: it is the same
  library at a new path, and the registry re-points. Two folders with one
  uuid (the leftover after a move) show in the list as the same library
  with the leftover flagged "copy at …".
- On iOS the file exists too (one library, uuid minted once) — it is what
  the phone sends as its library when it *creates* one on the server.

### 2.2 The registry (macOS)

`storage.libraries` in UserDefaults: `[{ id, path, name, lastOpenedAt }]`,
paths standardised, the current root always present. A scratch run
(`rootCameFromArguments`) never writes it — the same guard as `commit`.
Unreachable paths stay listed, greyed ("not mounted"). iOS has no registry.

### 2.3 The Mac: many libraries, one open

```
LIBRARIES
✓ letslapse        /Volumes/letslapse · 365 projects · not connected          (current)
  regularsteven    ~/Library/…/LetsLapse/picplace.test/regularsteven · @regularsteven on picplace.test   Switch…
  Field 2026       /Volumes/Field/Field 2026 — not mounted
  ─────
  Create New Library…      a Save panel (name + place) → identity + Projects/ → Relaunch
  Open Other Library…      a folder panel → must be a library (L2) → Relaunch
  Move This Library…       today's copy flow; stage D adds "without originals"
```

Each row's subtitle reads the binding from that root's `PicPlace/account.json`
and the count from its identity/index when reachable. The current row is
not switchable; every other reachable row's **Switch…** confirms and ends on
Relaunch. Rows are removable from the list (disk untouched). The launch
fallback alert (nominated root unreachable) names the reachable libraries
and offers to open one, instead of only "keep using the default location".

### 2.4 iOS: one store, an active library once connected

- Before connecting: the sandbox is the library; no picker exists.
- After connecting: the account's libraries come from `status.libraries[]`;
  one is **active** (`letslapse.picplace.activeLibrary`, per install —
  it *is* per device). The Projects list shows the active library's
  projects (`ProjectQuery.library`); the picker lives in the Projects
  toolbar menu and in Settings ▸ PicPlace. Captures and imports write
  `library = active`; the import sheet may offer a per-import choice later.
- **Adding** a library to the phone = the fresh pull scoped to it (records +
  posters; originals per project, as now). Choosing it as the capture
  target does not require pulling it.
- The phone's pre-connection projects get assigned at connect time: into
  an existing library or a new one made from them (§3.7).
- Per-library "free up space" on the phone is stage D's gate applied in
  place.

### 2.5 The server: account ⊃ libraries ⊃ projects

| Object | Key | Scope |
|---|---|---|
| account | `user.uuid` | tokens, devices, dedupe, usage, rate limits |
| **library** | client uuid (= the identity file's) | name, tombstone; later members |
| project | `originID` | `library_id` nullable → the default library |
| presence | `(project, device)` | unchanged — unambiguous once a device's libraries hold disjoint sets |

Why this dissolves the L10 collision: the collision only exists when two
local libraries on one install hold the *same* project under one account —
which is precisely "a second library merging into the account's one
namespace". With library rows, "client X" and "personal" on one Mac hold
disjoint projects; one token lineage per install serves both; presence,
claims, `updated_by` and the per-device rate budget stay truthful. The
remaining rule is the natural one: one local copy of a given server library
per install.

Sharing later: a `library_members` table (library, user, role); a member's
own tokens read and write that library's projects; presigned URLs still
serve the owner's objects; usage stays the owner's; the web view gains a
per-library page. Not in scope; the binding's `matches()` becomes
library-based then, which L9 has already prepared.

### 2.6 Tool libraries

Presets, LUTs, light ladders and blend profiles are per root on the Mac
(they live in the root) and per device on the phone (one root). On the
server they were planned as one *account* bundle (v2 plan §3.4, the
`PUT /library` ask, which this plan renames "account bundle" to keep the
word *library* for L8). Open point §8.3.

## 3. The flows

### 3.1 Create New Library (macOS)

1. **Create New Library…** → `NSSavePanel` (`canCreateDirectories`, name
   field "LetsLapse Library", default place: the default location). The
   chosen URL is the new root.
2. `check(destination:)` must be `.empty` (or the folder does not exist
   yet). `.adopt` → "That folder already holds *Field 2026* — open it
   instead?" (→ 3.2). Anything else → the existing refusals.
3. Create the folder, write the identity file (name = the panel's name),
   create `Projects/`, add to the registry, `StorageRoot.commit`, log.
4. The sheet ends on **Relaunch LetsLapse** / Not Yet, as every location
   change does; the new library starts signed out (L7).

### 3.2 Open Other Library (macOS)

Folder panel → `check` must be `.adopt` → registry + commit → Relaunch. An
`.empty` pick offers to create instead. A pick that *contains* the current
root or a registered library (a container) is refused: "That folder
contains a LetsLapse library (`picplace.co/regularsteven`). Choose the
library itself."

### 3.3 Switch (macOS)

Row action → confirm ("Switch to *letslapse*? LetsLapse relaunches on
/Volumes/letslapse.") → commit → Relaunch. Disabled while
`model.stage == .processing`, as Change… is today.

### 3.4 Move This Library (macOS)

Today's flow, on the current library only; the destination must be
`.empty`. The mover **always** carries `libraryItemNames` + the identity
file — never "everything visible" (trap §7.3). The registry re-points on
success; the old copy is the leftover the sheet already tells the person to
delete in Finder.

### 3.5 The launch fallback (macOS)

Nominated root unreachable → the session runs on the default location as
today, but the alert lists the reachable registered libraries with **Open…**
(commit + relaunch) beside **Keep using the default location** and the
existing explanation. The setting is kept either way, so reconnecting the
drive and relaunching still recovers.

### 3.6 Move without originals (stage D)

When the current library is connected, the move sheet's confirm screen
offers two rows:

> **Move everything** · 431 GB  
> **Move without originals that are on PicPlace** · 19 GB moves; 412 GB of
> originals in 340 projects stay on PicPlace — those projects show as
> previews at the new location. 25 projects aren't fully on PicPlace and
> move whole.

Planning: per project, the gate (L12) reads the sync record's server truth
(`serverHeavyFiles`, `originalsMovedAt`, and the manifest's per-frame
sha256 against the index row's confirmed assets when it holds them);
passing projects contribute everything **except `source/` media** (the
capture sidecars in `source/` are records and always move); failing
projects move whole. Copy as today. At the destination those projects are
`previewOnly` by rule (v2 D7) and the next check reports tier `preview`.
**Download originals** per project restores any of them; the old volume is
untouched until the person deletes it.

### 3.7 Connect, with libraries (stage C)

The connect question gains a target when the account has libraries:

> Connect this library to PicPlace as @regularsteven?  
> ◉ **New library on PicPlace — "Field 2026"** · this library's 12 projects go up  
> ○ **personal** · 300 projects on PicPlace, 12 here — merge  
> ○ **client X** · 40 projects on PicPlace — merge

The clean / fresh / merge line (v2 §4.1) is computed for the chosen target
and the flow is v2's, scoped by `?library=`. A **fresh device** signing in
sees a chooser of the account's libraries ("Which libraries do you want on
this Mac?"), picks a folder once, and each chosen library is pulled into
`<folder>/<library name>/` with its identity written from the server's
uuid and name. On the phone the chooser sets the active library and pulls
it (§2.4).

### 3.8 Sign-out and disconnect

Unchanged (v2 §4.6): sign-out drops tokens and keeps the binding; disconnect
removes the binding and the sync state; projects stay. With L7 a sign-out
in one library no longer signs another out — tokens are per account, but
the session pointer is the library's own.

## 4. What changes where

**App (macOS unless noted)**

- `App/StorageLocation.swift` — `LibraryIdentity` read/write/heal;
  `LibraryRegistry`; `check` outcomes `.empty` / `.containsLibrary`, the
  document-based adopt; `create(at:name:)`; the mover's carried set.
- `App/SettingsView.swift` (the Storage section, ~901–1030; the sheet,
  ~1963–2239) — the Libraries list, the three doors, a `create` sheet mode,
  the confirm-then-relaunch for Switch.
- `App/LetsLapseApp.swift` — the fallback alert's Open… rows.
- `App/PicPlace/PicPlaceController.swift`, `PicPlaceAutoSync.swift`,
  `PicPlaceSyncState.swift`, `PicPlaceViews.swift` — session pointer and
  the two switches per library; a new library starts signed out; "Sign in
  as @user" from Keychain tokens; "Sign in with another account…" (server
  choice allowed while *this* library is unbound and has no session); the
  replica rule; `library` in the binding record.
- Stage C: `PicPlaceLibrarySync.swift` / `PicPlaceChangeSync.swift` /
  `PicPlaceAPI.swift` — the target chooser, `?library=`, `library` on the
  PUT, `status.libraries[]`; iOS active library, `ProjectQuery.library`,
  capture/import writing the field, the picker (Projects toolbar menu +
  Settings ▸ PicPlace).

**Kit**

- `Library/LibraryIdentity.swift` + tests (read, write, heal, name rules).
- Stage C: `ProjectDocument` optional `library`; the reconciler indexes it;
  `ProjectQuery.library`; `lapse audit` reports the identity.

**Server** (the picplace repo, stage B) — see the asks: migration, model,
`/libraries` controller, the index filter, the PUT field, `/status`, the
roster and web filter, `features.libraries`, feature tests.

**Docs and mirrors (owed per screen, code-first)** — `docs/design/macOS/`:
`settings-libraries.svg` (new), `settings-library-location.svg` and
`.moving.svg` (retitled to the Libraries rows; a `.create.svg` and a
`.without-originals.svg`), the Settings PicPlace card; `docs/design/iOS/`:
Settings ▸ PicPlace with the active library, the Projects toolbar menu.
`INDEX.md` rows 🟡 until drawn. `letslapse-app-overview.md` §4.13 gains the
identity file and the registry; the persistence tree gains
`letslapse-library.json` and `PicPlace/session.json` / `settings.json`.

## 5. Stages

| Stage | Lands | Server needs | Proven by |
|---|---|---|---|
| **A** | Identity file + heal; `check` by documents (M4 fix); the registry; Settings ▸ Storage ▸ Libraries with Create / Open / Switch / Move; the fallback alert's Open…; per-library session + switches, new libraries signed out, the interim replica rule; `library` in `account.json`; `LL_STORAGE=create\|list` | nothing | Create New at a scratch path → relaunch → empty gallery, no bytes copied; the list shows the volume, the play-pen and the new one; Switch back to the volume is a commit, never a copy; `check` on a scratch copy of a library with `Projects/library.json` removed still says adopt; a new library shows Sign in, not the volume's session, and `autoOriginals` off; Kit tests; the Release app on the volume untouched throughout |
| **B** | `letslapse_libraries`, `library_id`, `/libraries`, `?library=`, `library` on PUT/row, `status.libraries[]`, `features.libraries`, roster + web filter | — (this is the server work) | feature tests; the unchanged v2 client against picplace.test behaves exactly as before the deploy; the play-pen's projects report `library: null` |
| **C** | Connect target chooser; fresh-device chooser; scoped checks; iOS active library, capture/import into it, previews of others; the replica rule narrows | B | two scratch libraries under one account on one Mac, bound to *test-1* and *test-2*, both pushing, presence rows distinct; the Simulator sets *test-1* active and captures land there, switches to *test-2* and captures land there; *test-1*'s previews pulled into the Simulator; `lapse index --verify` |
| **D** | Move without originals; then per-project "Free up space" on the same gate | nothing new (tiers exist) | a scratch library of 3 projects, 2 with originals confirmed on picplace.test → move → 2 preview-only at the destination, 1 whole, the source untouched; Download originals restores one; the FLICKER-style before/after audit of both folders |
| later | sharing (members), the account bundle per library, iOS background transfers (handover §2) | members table | — |

Order against the handover's list: the real-world `picplace.co` run stays
first for the *sync* programme; stage A is independent of it (local only)
and unblocks Steven's testing now; B and C follow the real-world run.

## 6. The test rig

- **Steven's Mac today:** the Release app (Xcode Run action) runs on
  `/Volumes/letslapse` (`storage.libraryRootPath`, as of 2026-09-16;
  unbound; 365 projects, 431 GB; 39 GB free on the internal disk). The
  play-pen is `~/Library/Application Support/LetsLapse/picplace.test/regularsteven/`
  (bound to picplace.test, 4.3 GB). The default root itself holds nothing
  but that nested folder. `letslapse.picplace.autoOriginals` is ON on this
  install; `letslapse.picplace.server` is picplace.test; no session key.
- **Agent runs** stay on scratch roots through the argument domain
  (`-storage.libraryRootPath <scratch>`, Debug binary, private DerivedData);
  the registry is not written from such a run (L3); `AppRelaunch` re-passes
  the root. A Create from a scratch run relaunches onto the created root the
  same way.
- **The volume is never a copy target and never a source of a move** in any
  test. The only thing ever done to it is a *switch*, which writes one
  UserDefaults key.
- **Hooks:** `LL_STORAGE=create` (the create sheet, demo values, disk
  untouched), `LL_STORAGE=list` (three staged rows incl. an unmounted one),
  the existing `move|adopt|moving|done|failed`; stage D adds
  `LL_STORAGE=without-originals`; stage C adds `LL_PICPLACE_LIBRARIES=<n>`
  (the chooser with staged libraries) and `LL_PICPLACE_ACTIVE=<uuid>` on
  iOS.
- **Server:** picplace.test + Garage for B and C; picplace.co only after
  the real-world run and only with throwaway libraries; physical iOS
  devices never against picplace.test (v2 rule).

## 7. Traps recorded

1. **M4 breaks the adopt check** (TODO, v2 §7): `check` keys adopt on
   `Projects/library.json`. Stage A keys it on the identity file or on
   documents.
2. **"Move back to the default location" offers a 431 GB copy** once the
   default root is a container of nested libraries: `check(defaultRootURL)`
   finds no `Projects/library.json` and no collision → `.move`. The row goes
   away with the list.
3. **The mover copies "everything visible" when the source is the default
   root** (`StorageMover.copyLibrary`) — with `picplace.test/…` nested
   inside it, a move *from* the default root would drag a whole other
   library along. Stage A: the carried set is always the known list + the
   identity file.
4. **The fallback session bootstraps an empty library at the default root**
   beside the nested play-pen (`loadLibrary()` creates `Projects/`, the
   index…), which later makes `check(default)` a collision. Stage A's alert
   offers the registered libraries instead; the leftovers are worth a
   one-time sweep note in the alert.
5. **Any unbound library borrows the install's session**, and
   **`autoOriginals` is per install** — a new library would offer the real
   account and, on yes, upload its originals. L7.
6. **Presence per `(project, device)` + tokens per account per install**:
   two libraries under one account on one install collide until stage B
   (L10's interim rule).
7. **`features.library` already exists** on the server for the account
   bundle; the scope flag is `features.libraries` (plural).
8. **`StorageRoot.current` is a `static let`** — the iOS active library must
   be a filter, never a root swap (L11).
9. **A scratch run must not persist the registry** — same guard as
   `commit` (`rootCameFromArguments`), else a test run lists scratch
   folders in Steven's Settings.
10. **A library uuid taken on the server** (`409 uuid_taken`, as for
    projects): re-mint locally — rewrite the identity file and the binding —
    and retry. Astronomically rare; the path must exist.
11. **Two folders, one uuid** after a move (the leftover): the registry
    keys by path and flags the duplicate; never auto-delete.

## 8. Open points

1. **The nest for placed libraries** (L6): keep Steven's
   `<root>/<host>/<username>/` rename for the unnamed root library only, or
   retire it once every library has an identity. His call.
2. **Blends in a move without originals**: move by default (decided), a
   second toggle ("also leave blends that are on PicPlace") later if wanted.
3. **Tool libraries** (§2.6): per root on the Mac, per device on the phone,
   one account bundle on the server — or one bundle per library. Decide when
   the bundle surface is built.
4. **Where pulled libraries land** on a fresh Mac: one folder picked once
   (default: the default location), `<folder>/<library name>/` each.
5. **The iOS picker's home**: the Projects toolbar menu ▤ (the compact iPhone
   header has no spare slot — see the Gallery header decision) plus Settings.
   Design when stage C's code settles.

## 9. Stage A — landed 2026-09-16

**What:** Kit `Library/LibraryIdentity.swift` (record, `ensure` heal with
`.existing / .created / .unreadable`, `detect(root:)` by identity →
documents → export → none; 11 tests) and `PicPlaceBindingRecord.library`
(optional in format 1; `sessionURL` / `settingsURL`). App:
`StorageRoot.healIdentity()` from `loadLibrary()` (skipped in a fallback
session); `LibraryRegistry` (`storage.libraries`, upsert by identity then
path, `move` on nest/copy, `discover()` over the default location and its
`<host>/<username>/` children — export-only folders deliberately not
listed); `check` → `.empty` / `.containsLibrary` / `.adopt(identity?)` /
`.collision` / `.notWritable` / `.alreadyCurrent` / `.insideCurrent`, a
not-yet-existing folder with a writable parent is `.empty`;
`StorageRoot.create(at:name:)`; `renameIdentity(to:)`; the mover always
carries `libraryItemNames` (§7.3 closed) and re-points the registry.
Settings ▸ Storage ▸ **Libraries** card (§2.3 as drawn: rows, Current /
Switch…, context menu Rename · Show in Finder · Remove from List, the three
doors as NSSavePanel / NSOpenPanel, `LL_SCROLL=libraries`), the sheet's
`create` mode and named switch copy, the launch alert's `Open “name”` rows.
PicPlace: `PicPlace/session.json` + `settings.json` (one entry per device;
`App/PicPlace/PicPlaceLibraryState.swift`), the install-wide session key
claimed once by the library in use and the install-wide switch keys
retired — only an explicit *auto-sync off* is carried, *upload originals*
never (it starts OFF on every device for every library; the bench's
`-letslapse.picplace.autoOriginals YES` still forces a run and writes
nothing), profiles cached per account (`letslapse.picplace.accounts`),
`knownAccounts` + `adoptSession` ("Sign in as @user" rows on the card, no
browser), the interim replica rule in `connectLibrary()`, `library`
written into the binding at connect. `armAutoSync` logs the three switches
at launch.

**Verified (Debug build, scratch roots through the argument domain; the
volume and the play-pen untouched):** a fresh root gets its identity
minted (`name` = folder); the list shows the current root, the nested
play-pen (`@regularsteven on picplace.test`) and not the default root's
empty export; `LL_CREATE_LIBRARY` made `Field 2026` (folder + identity +
`Projects/`, no bytes copied) and the AX-pressed Relaunch came back on it
with the identity read, not re-minted, signed out; `LL_OPEN_LIBRARY` on a
folder holding only `Projects/<uuid>/project.json` (no identity, no
export) offered **Switch to “lib-c”** — the M4 trap is closed; the
scratchpad itself (a container of the current root) was refused with the
library named; Switch → Relaunch landed on the other root; the demo list
stages. Kit suite green; Mac and iOS Simulator builds clean.

**Consequences to know:** *Upload originals automatically* starts OFF on
every library after this build, the play-pen included — the install-wide
ON is retired, not carried (Steven's rule, L7); switch it on per library
where wanted. The default root today holds `Index/`, `Logs/`
and an empty `Projects/library.json` from a run on 2026-09-16 14:17 (not
this work) — the §7.4 leftovers; harmless, not listed, deletable by hand.

**Traps met:** `Date()` has sub-millisecond precision and the file stores
milliseconds — `LibraryIdentity.init` rounds `createdAt` so a record equals
its read-back (the sync-revision rule again). `screencapture -l` of a
sheet's window id captures its parent window. The `LL_SCROLL` anchor moves
after the cards above it settle (the storage walk, the AI readiness line),
so the hook scrolls three times.

**Owed:** the mirrors (INDEX 🟡: `settings-libraries.svg`, `.create.svg`,
the retitled move sheet); "Sign in as @user" seen with a real cached
profile (none existed on this install yet); stages B–D.

## 10. What Steven's first test showed (2026-09-16 evening) — and what changes

**The run:** on the play-pen (bound, 879 projects) *Disconnect this library*
→ Switch to the volume (unbound, 398) → relaunch → sign in → *Connect this
library* ("PicPlace holds 879 projects, this library 398 … the rest are
exchanged") → Connect → nest to `/Volumes/letslapse/picplace.test/regularsteven`
→ relaunch → the merge ran: **879 preview shells pulled into the volume's
library, 398 pushed up**, the account at 1,276. Then Switch back to the
play-pen: it opened **signed out** and offered *Sign in as @regularsteven* /
*Sign in with another account*; *Sign in as* → the connect question
("PicPlace holds 1,276, this library 879 — merge") → Connect → refused by
the interim replica rule naming the volume as "letslapse".

**Mechanics, for the record:** the v2 merge did what it was built to do —
the account is one namespace on the server, and any library that connects
to it meets everything in it. Disconnecting the play-pen removed its local
binding only. The interim rule (L10) could not fire because the play-pen
was no longer bound. The dead preview, the dead Edit / Text / Shapes and
the Finder buttons that do nothing share one cause: `heroImageURL` resolves
the *source files*, a pulled shell has none, and every caller treats nil as
"do nothing". The "signed out after the switch" was stage A's per-library
session pointer (L7): the volume had a `session.json`, the play-pen did not.

**Decisions taken from it (Steven, 2026-09-16 evening):**

| # | Decision | Why |
|---|---|---|
| **L13** | **The session belongs to the Mac, not the library.** One sign-in per server per install; a library's binding decides whether it syncs with that account. The card shows **Sign In** or **Sign Out**, never two sign-in variants. L7's `session.json` and the "Sign in as @user" rows are reverted; tokens stay per account in the Keychain. | "It's one or the other with signing in and signing out." Switching libraries must never sign anyone out. |
| **L14** | **Switching never disconnects.** *Disconnect this library* leaves the main card for the library row's menu, as the rare act it is (giving a drive away, re-homing to another account); its copy says what it costs (the merge base). | The binding is the library's identity on the server; dropping it on every switch would re-merge on every return. Steven asked whether a switch should disconnect — pushed back, agreed. |
| **L15** | **Switch and create relaunch from the confirm** ("Switch and Relaunch", "Create and Relaunch"); the *Relaunch to finish* screen stays only after a **move**, where the copy took minutes. | A second screen that repeats the first is a wasted screen. |
| **L16** | **A library has a name the person gave it.** Create takes it from the Save panel; a healed library carries its folder name as a *placeholder* and is shown as unnamed (a pencil, "Name this library"); **connect asks for a name** when it is still the placeholder, because the server library needs one; Rename is a visible affordance, not only a context menu. | "Their folder path's last name should not be the library name." |
| **L17** | **Server libraries first.** Stage B is built by the PicPlace developer before stage C; the client's connect chooser, scoped sync and the iOS active library all sit on the rows. Until B lands, **connecting a library to an account that already holds projects is refused on this Mac** (not merged) — the merge is only offered when linking to a *named* server library. | The merge into a single namespace is what mixed the libraries; without scope there is no safe target. |
| **L18** | **Connect is never raised automatically** after a sign-in. The card shows *Not on PicPlace — Connect…*; the person chooses when, and the question states the numbers that will **arrive here** and **go up** for the chosen target, with *New library on PicPlace from this library* as the default for a library that never synced. | "The rest are exchanged" did not say that 879 previews were about to land. |
| **L19** | **The nest is retired** (recommended; Steven's convention 2026-09-14, his call): a library stays in the folder it is in; the identity file and the binding say whose it is. The recovery below un-nests the volume. | The rename on connect surprised on the real library; with a name and a binding the folder name carries no information. |
| **L20** | **Preview-only projects show their poster everywhere** — grid, item view, media pane — and Edit / Text / Shapes are *disabled with the reason* ("Download originals to edit"), never dead; Finder reveals the project folder. | Steven: "the preview should show in this window." |

**Stage A′ (client, after B ships or alongside it — no server dependency):**
L13 revert (session per Mac: `letslapse.picplace.session` back, per server host), the card's Sign In / Sign Out, `knownAccounts` / `adoptSession` removed; L14 Disconnect moved to the row menu with honest copy; L15 one-screen switch/create; L16 names (placeholder state, pencil, connect asks); L17 the refusal copy names the library by name; L18 no automatic connect question; L20 `heroImageURL` falls back to `poster.jpg`, editor buttons disabled with reason, Finder reveals the folder; L19 the nest removed from `connect(with:)` (nest code stays for the crash-recovery marker only). Mirrors per screen after.

**Stage B (server, the developer, first)** — [libraries-server-asks.md](libraries-server-asks.md), updated with this test: library rows, `library_id` on projects, `POST /libraries/{uuid}/projects` to assign a list (how an already-mixed account is sorted out), `status.libraries[]`, `features.libraries`, and a `letslapse:wipe-account` command for test accounts.

**Stage C (client, after B):** the connect target chooser (new / link existing) with the numbers; scoped checks and pushes; the fresh-device chooser; the iOS active library; the replica rule per server library; L17's refusal lifted. Agreed with the PicPlace developer 2026-09-16 evening (asks §6): the check stays a **full** scoped pass and detects a departure as *held here, absent from the scoped index, not tombstoned*; the manifest PUT carries `library` only when it may create (first push, resurrection) or deliberately moves — never on an ordinary update, which would revert a move made elsewhere; `422 library_unknown` on a create re-`PUT`s the library and retries once; `library_changed_at` is what a later incremental pass keys on. What a departed project becomes locally (moved into the other library's folder when that library is on this Mac, else an orphan the card names) is C's design point, not the server's.

## 11. Recovery of the mixed library — a one-off, with Steven's go

State on 2026-09-16 16:30: `/Volumes/letslapse/picplace.test/regularsteven/Projects`
holds 1,277 folders — **398 with source media** (the real library) and
**879 without** (the pulled shells; their uuids are exactly the play-pen's
879, which all have their sources at home). The account on picplace.test
holds 1,276. The play-pen is unbound with its 879 intact. Nothing is lost.

1. **Quit LetsLapse** (the Release app runs on the play-pen).
2. **Server:** wipe @regularsteven's LetsLapse projects and objects on
   **picplace.test** (a test instance; the developer's `letslapse:wipe-account`
   from the asks, or `tinker` — the 398 real projects re-push cleanly into a
   named library once C lands, the play-pen's 879 likewise).
3. **Local, app closed:** in the nested volume library, hard-delete the 879
   shell folders by the play-pen's uuid list (no tombstones, no journal —
   the reconciler drops their index rows on the next launch), remove
   `PicPlace/` (binding, sync state, session); then **un-nest**: move every
   `libraryItemNames` item from `/Volumes/letslapse/picplace.test/regularsteven/`
   back to `/Volumes/letslapse/` (same volume, renames) and remove the empty
   `picplace.test/` folder. The identity file moves with it, so the
   registry re-points on the next open.
4. Relaunch on the volume: 398 projects, unbound, named "letslapse"
   (placeholder — rename it). The play-pen stays as it is.

Step 3 is a script over a uuid list checked against "no source media"
twice; it is not run without Steven's explicit go, and never on a project
that has sources.

## 12. Stage A′ — landed 2026-09-16 evening (L13–L20)

**What:** L13 the session is the Mac's again, one per server host
(`letslapse.picplace.sessions`, v2's single key folded in; a day-old
`PicPlace/session.json` is removed where found); the card shows **Sign In**
or **Sign Out…**, the "Sign in as / another account" rows and
`adoptSession` / `knownAccounts` are gone. L14 *Disconnect…* is a
visible red button on the current library's row in Settings ▸ Libraries
(and in its menu; a menu alone was not found — Steven, the same evening);
iOS keeps it on the PicPlace card, having no list; the copy says what it
costs; switching never touches the binding. L15 **Switch and Relaunch** /
**Create and Relaunch** from the confirm; the *Relaunch to finish* screen
only after a move; `LL_CREATE_LIBRARY` relaunches straight away. L16
`LibraryIdentity.namedByPerson` (absent → false; a healed library carries
its folder's name as a placeholder; iOS heals with the device's name); the
row shows *Unnamed — the folder's name for now* with an accent pencil,
every reachable row has the pencil, and the connect question carries a
name field when the library is unnamed. L17 the connect question refuses
the **merge** case with the numbers until the server scopes libraries
(clean and fresh stay); L18 sign-in never raises the question — the card's
row reads *Not on PicPlace — Connect…* and the question states what
arrives and what goes up. L19 the nest is gone from `connect(with:)`
(`nest` / `nestedRoot` / `isNested` / `prepareForLibraryNest` /
`LL_PICPLACE_NEST` removed; the marker's launch half stays for a build of
those two days). L20 the detail hero shows `poster.jpg` when there is no
source (never as the editor's asset), the Gallery panel's Edit / Text /
Shapes / New clip are disabled with *Preview only — download the originals
to edit*, and both Finder actions reveal the project's folder when there
is no hero file.

**Verified on scratch roots:** one press on *Switch and Relaunch* relaunched
onto the other root; a healed library lists as unnamed with the pencil; the
staged connect question shows the name field prefilled with the folder
name; the PicPlace card shows the single *Sign In*; Kit 12 tests green;
Mac and iOS Simulator builds clean. Not exercised here (needs a session):
the merge refusal's copy on a live account, Disconnect from the row menu.

**Screenshot note:** `LL_SCROLL=libraries` lands past the card in a
window shorter than ~2,000 px (the anchor is right; the scroll overshoots
by a constant); the 2,535-px window of the first run landed it. Draw the
mirrors from a tall window.

## 13. The 2026-09-16 cleanup — done that evening, with Steven's go

Steven had renamed the two libraries ("Prague LetsLapse Shots" = the
nested volume library, "Holidays" = the play-pen) and asked for the mess to
be resolved without breaking the volume's structure. Done, app quit,
everything reversible: Prague's binding and sync records set aside in
`PicPlace/.disconnected-2026-09-16/` (a file-level Disconnect); the 878
pulled shells (every one a Holidays project with its sources at home; 348 MB
of records and posters) **moved**, not deleted, to `<library>/Removed shells
2026-09-16/` — the safety classifier refused an `rm`, and moving is the
better tool anyway; @regularsteven's LetsLapse data on picplace.test wiped
with the developer's `letslapse:wipe-account` (1,276 projects, 167
tombstones, 6,337 objects; devices and tokens kept); the Release app
relaunched on Prague: 400 documents, 878 rows dropped, unbound, signed in,
originals off. One old orphan (`C6F7D8CD…`, a `project.json` from 20 Aug
with no files) left as it was. Both libraries now read *Not on PicPlace —
Connect…*; **neither connects until stage C** (the second would be refused
as a merge under L17).

## 14. Stage C1 — landed 2026-09-16 night (the Mac and the shared flows)

Against the PicPlace developer's stage B (picplace `5786a9e`, migrated on
picplace.test; the answer `picplace/docs/letslapse-libraries.md`).

**What:** `PPLibrary`, `status.libraries[]`, `features.libraries`,
`library` + `library_changed_at` on the project row (`PicPlaceAPI.swift`).
The controller's **scope** = the binding's `library.uuid`; `serverLibraries`
from every `/status`. **Connect** is a sheet (`PicPlaceConnectSheet`): the
name on PicPlace, then *New library on PicPlace* (default) · *Take over
the N unfiled projects* (`adopt_default`, when the default library holds
any) · *Link to “X” · N projects* per existing library — each with what
goes up and what arrives in numbers; linking makes the local library a
copy of that one (`StorageRoot.adoptIdentity`: the identity takes the
server's uuid and name), a new library is `PUT /libraries/{identity.id}`
(`409 uuid_taken` re-mints once), the binding carries `library`, the first
sync runs the case (clean / fresh / merge) **within the scope**. The v2
one-line question and the merge refusal stay for a server without
libraries. **Every pass is scoped client-side over the account's full
index** (asks §6 Q1): a row filed in another library is a *departure
notice* for a project held here — its record says where
(`elsewhereLibrary` / `elsewhereName`), nothing is pushed or pulled for it,
the card reads *In “Bench C” on PicPlace*, the person's Sync refuses — and
nothing for one that is not. The manifest PUT carries `library` only when
the claim said the project is new or a tombstone (may create); `422
library_unknown` re-`PUT`s the library and retries once. A rename here
renames the server library. The replica rule is per server library on a
Mac. **Add Library from PicPlace…** in Settings ▸ Libraries lists the
account's libraries not on this Mac; one is placed at
`<place>/<host>/<username>/<name>/` (or `<place>/<name>/` when that is a
library), bound `fresh`, registered, and the relaunch pulls it. The
Settings card's *Library* row names the server library; *On PicPlace* is
the library's count and bytes.

**Verified on picplace.test** with the throwaway `letslapse-two` (a
Passport personal-access token minted in tinker; never Steven's tokens),
three scratch libraries: A connected as **new** "Bench A" (uuid = its
identity, the one project created with `library` set,
`library_changed_at` null — a create is not a move); B, empty, **linked**
to it (identity became Bench A's uuid and name; fresh pull of the preview);
C connected as **new** "Bench C"; `POST /libraries/{C}/projects` moved A's
project → A's next check: *is in Bench C on PicPlace, not in this one —
left alone here*, record marked, nothing pushed back; C's next check
pulled it. `letslapse:wipe-account letslapse-two` after. Mac and iOS
Simulator builds clean.

**Hooks:** `LL_PICPLACE_LIBRARIES=<n>` (the sheet, staged),
`LL_PICPLACE_CONNECT=new:<name>|adopt:<name>|link:<uuid>` (the bench).
Bench token: `php artisan passport:client --personal` once, then
`$user->createToken('bench', [the four scopes])->accessToken` in tinker;
`LL_PICPLACE_TOKENS=<token>:dummy` (personal tokens do not refresh; runs are
short).

**Owed — C2 (iOS active library):** the phone binds to ONE server library
at connect (the same chooser); working in several of the account's
libraries from one phone — an active library, captures and imports into
it, previews of the others in the same store, a picker in the Projects
menu and Settings — is C2 (L11). Also owed: a v2-era binding (no `library`)
on a server that now has libraries is treated as account-wide, as v2; the
card should offer "choose its library" (adopt or link) — a one-line
follow-up once such a binding exists (Steven's are both unbound). The
mirrors: the connect sheet, the Add sheet, the card's states (🟡).

**Steven's next step:** connect "Prague LetsLapse Shots" as a new library,
"Holidays" as a new library — each from its own Settings card; the merge
that mixed them cannot recur (a merge is only offered when *linking* to a
named library, and the sheet says the numbers).

## 15. The transition heal (2026-09-16, late) — a binding whose server library is missing

Steven connected "Prague LetsLapse Shots" at 18:56 on the A′ build (the one
relaunched for him after the cleanup): A′ wrote the identity's uuid into
the binding but created nothing on the server and sent no `library` on the
pushes, so the 398 went up **unfiled**. The C1 build then scoped every pass
to that uuid and read them all as "filed in another library" (0 on
PicPlace, 398 elsewhere) — and one push's `422 → re-create → retry` had
already created the library row with a single project in it.

**Fix:** `repairBindingLibraryIfMissing(status)` runs at the handshake and
before every check: a v2 binding without a library takes the identity's
uuid; a library missing on the server is created under the binding's uuid
and name; and the account's **unfiled** rows that this library holds are
assigned to it (`POST /libraries/{uuid}/projects` with exactly those uuids
— never the whole default, never another named library's), once per
change of the default library's count. Reproduced on the bench (Bench A's
library row force-deleted → its project unfiled → the relaunch created the
library and filed the project; the check clean) and wiped after.

**For Steven:** relaunch the Xcode build on Prague — the launch heals it
(the card: *On PicPlace · 398 projects*); then Holidays → Connect → *New
library on PicPlace*. Nothing on the server side.

## 16. The Simulator's claim (2026-09-17 morning) — two rules corrected

What Steven saw on `/letslapse`: *Holidays 878 · LetsLapse 398 · Prague
LetsLapse Shots 3*. The **iPhone 16 Pro Simulator**, bound to the account
in the v2 days (a binding with no library uuid), had been account-wide under
C1 and pulled the unfiled 398 as previews; at 09:22 it ran §15's heal,
which took its healed identity ("LetsLapse", the sandbox folder's name) as
its library, created it on the server, and filed "the unfiled rows it
holds" — its preview shells — into it. The Mac's 09:15 run was C1 without
the heal. The 3 in "Prague LetsLapse Shots" were last night's new projects,
pushed through the `422 → re-create → retry` path.

**Corrected:** (1) *held here* means the **originals** are here
(`!sourcesMissing`) — a preview pulled from the account is some other
library's project and is never filed by the heal; (2) **a binding without a
library is `.needsLibrary`**, not account-wide: `canSync` is false (no
pass, no pull), the card reads *Which library is this? — Choose…* and the
connect sheet fills the binding in (new · take over the unfiled · link);
choosing clears the account-wide-era sync records so the scoped first
sync rebuilds them. Verified on the bench: a scratch library with its
`library` removed from the binding ran the handshake and nothing else.

**Data fix on picplace.test (tinker, with Steven):** the 398 rows moved
back into `77c35103` "Prague LetsLapse Shots" (stamped `library_changed_at`
so other devices' passes see the move), the empty "LetsLapse" library
tombstoned. After: Prague 401 · Holidays 878 · nothing unfiled.

**The Simulator** still holds ~1,276 preview shells from its account-wide
days; on the new build its card asks which library it is. It is a
throwaway: erase it (`tools/sim-fresh.sh`) rather than choose.

## 17. What the phone showed (2026-09-17) — and what C2 is

### 17.1 Steven's walk

A fresh Simulator (`tools/sim-fresh.sh --new`), signed in as regularsteven,
"Holidays" chosen on the sheet: 877 previews arrived, the gallery showed
them, no originals — right. Then, looking for the way to "Prague LetsLapse
Shots": **Disconnect this library…** → confirm. The card read *Not on
PicPlace — Connect…* and the sheet offered: *New library* — "this library's
877 projects go up"; *Link to "Holidays"* — "holds 877, this library 877";
*Link to "Prague LetsLapse Shots"* — "holds 401, this library 877 …
everything here that isn't there goes up".

Three faults, none the server's:

1. **The counts.** `localCountNow()` and `describeConnectCase()` count
   every row of the index — the 877 pulled previews included. A preview
   has no originals; nothing of it can go up. (§16 made the heal count
   originals only; the sheet still counts shells.)
2. **Disconnect keeps the previews.** `disconnectLibrary()` removes the
   binding and the records and leaves the shells: 877 posters that can
   never be opened or downloaded (no binding) and that poison every later
   connect.
3. **The copy** of the merge line reads as a riddle.

What would actually have happened on *New library*: the initial sync reads
the account's whole index, finds all 877 origins filed in Holidays, marks
them `elsewhere`, pushes **0**. The server would have stayed clean; the
phone would have kept 877 shells reading as previews (poster present) with
nothing behind them. "877 go up" was the count lying, not the run. The
genuinely bad case is a library **purged** from the server (past
retention): its shells are then in nobody's scope, `toPush` takes them (it
filters `elsewhere`, not `sourcesMissing`), and the run creates poster-only
projects in the new library. That path exists today and closes in step 0.

### 17.2 Why C2 as recorded would not have fixed it

L11 made the phone's library a *filter*: one store, every document tagged
with its library, an account-scoped binding, passes over the account's
index scoped by tag. That is a second sync regime beside the Mac's (store =
library) — and it is the shape that produced §16: an account-wide pass over
rows whose library is a per-row attribute. The three faults above are
outside L11's scope altogether (they are the sheet's and the disconnect's),
and L11 makes "disconnect" on a phone harder to define, not easier (which
library, when the store holds several?).

### 17.3 Decisions

| # | Decision | Why |
|---|---|---|
| **L21** | **iOS gets the Mac's model: a library is a folder; the phone holds several, one open. Supersedes L11.** Libraries live at `<App Support>/LetsLapse/Libraries/<folder id>/` — identity file, `Projects/`, `PicPlace/`, caches, everything in `libraryItemNames`, per folder. The folder id is minted when the folder is made and never changes; the identity file inside carries the library's uuid and name (a link adopts the server's uuid there, not in the folder name). The open one is `storage.activeLibrary` = the folder id (never a path — sandbox paths change across reinstalls). The registry on iOS is the `Libraries/` folder itself, read by identity file; no `storage.libraries`. | One regime everywhere: binding, records, scope, departures, the per-(device, library) originals switch, disconnect — all already per folder, all proven on the Mac. The phone never runs an account-wide pass again. |
| **L22** | **A switch on iOS replaces the model, not the process.** `LetsLapseApp` holds a `ModelHost`; a switch flushes the open library (`flushLibraryPersistsAndExport`, `releaseLibraryLock`, PicPlace tasks cancelled, `persister.refuseWrites` set), points `StorageRoot.current` at the other folder, re-makes the shared persister and the singletons that cache the root at init (`CustomPresetStore`, `LightLadderStore`, `LUTStore`; the others read it at use), makes a new `AppModel()` and re-roots the view tree (`.id(generation)`). Refused while a capture, an export or a render runs; a pull in flight is cancelled and resumes when that library is next opened (its binding keeps `initialSync.pending`). The Mac keeps its relaunch — its editor windows are per library. | iOS cannot relaunch itself; a fresh model over another root *is* a launch. |
| **L23** | **Disconnect keeps everything; a connect that cannot account for a preview evicts it.** (Rewritten 2026-09-17 after Steven's question — the first cut evicted at disconnect.) Under L21 the everyday actions are *Switch* (nothing evicted, nothing on the server changes) and *Remove from this iPhone* (the folder goes — that is "take my phone out of this library"). *Disconnect* is the rare unlink of a folder from its account (wrong account or library, leaving PicPlace, undoing a connect): the binding and the records go, **the previews stay** — shown as "Preview — connect to download", counted as projects — and a later link to the **same** library finds them in step (origin id and revision match), so nothing downloads again. A connect to a **different** library or account evicts the previews that connection cannot account for (a preview belongs to the server library that holds its originals), and the sheet says so per option: "Link to Prague — 401 arrive as previews; 877 previews of Holidays are removed from this iPhone (they stay on PicPlace)". An eviction is **never a tombstone**: the check honours `libraryIndex.deletedProjects()`, and a tombstone would carry the deletion to the server. The disconnect confirm says the numbers: "The library stops syncing. 877 previews stay on this iPhone but can't download until you connect it again; 3 projects with originals here stay. Nothing changes on PicPlace." The sheet for a folder that was a server library before (its identity still carries that uuid) leads with "This library was “Holidays” on PicPlace — link to it". Same rule on the Mac. | A thousand previews take minutes to fetch; disconnect must not throw the cache away when a re-link would find it in step. What poisoned the sheet was the counting (L24) and the missing eviction at a connect elsewhere, not the previews' existence. |
| **L24** | **"Goes up" counts originals only — the library's count stays whole.** The library's project count (Settings, the Projects list, the card) includes previews: on a fresh phone linked to Holidays it reads 877, and a deleted project — preview or not — leaves the count at once and reaches the server on the next check (its tombstone → `deleteOnServer` when unchanged there since the base, a conflict card otherwise). Renaming, tagging and rating a preview push today too (the push queue takes a preview at tier `preview`; verified 2026-09-17) — managing a library never needs the originals here. Originals-only applies to exactly two numbers: the connect sheet's "N go up" and the first pass's push list, because going up means creating a project the server does not have, and a preview came *from* the server. `toPush` filters `sourcesMissing` (17.1's purged case closes). One gap found while checking: the check's retry of a *failed* push is originals-only (`PicPlaceChangeSync` ~248), so a failed metadata push of a preview is not retried until the next edit — step 0 lifts that guard for the manifest half. | A preview never goes up as a new project (§16's rule, applied wherever one is counted); everything else about a preview is an ordinary project's. |
| **L25** | **The phone's doors: Add Library from PicPlace…, New Library on PicPlace…, Remove from this iPhone….** No folder pickers; no second *local* library — an unconnected phone keeps one library, as agreed. Remove deletes the folder, allowed when every project with originals here has them on the server (its record's `serverHeavyFiles` covers them), else it names the N that exist only here and refuses. The phone's first library moves into `Libraries/<id>/` once, at the first C2 launch: a same-volume rename of each `libraryItemNames` item behind a marker, finished on the next launch if interrupted (precedent: `migrateLegacyApplicationSupportFolderIfNeeded`). One copy per server library per device (the Mac's rule, over the folder registry). | Uniform folders make Remove a folder delete; the migration is the one risky step and it is a rename, not a copy. |

### 17.4 The phone after C2

- Fresh phone → sign in → the card: *Which library should this iPhone
  show?* — the same sheet (new / take over the unfiled / link), binding
  the one library the phone has.
- Settings ▸ Libraries: name · count · size, Current / Switch, the doors of
  L25. A switch re-opens the model on the other folder — a second or two,
  no relaunch screen. Second step: the Projects header title as a menu with
  the same list.
- Captures and imports land in the open library — its folder, its binding,
  its push — exactly as on the Mac.
- Disconnect on any library: L23. Sign out: the device's session; every
  library keeps its binding (L13).
- Each library keeps its own *Upload originals automatically*, OFF by
  default (the rule).

### 17.5 Steps

| Step | What | Test |
|---|---|---|
| **0** ✅ 2026-09-17 | L23 + L24 + the copy — LANDED, both platforms; the disconnect confirm with the numbers; eviction at a connect elsewhere, with the numbers on the sheet; the check retries a preview's failed manifest push; the usage line hidden when unbound | Simulator linked to Holidays (877 previews): Disconnect → the confirm says 877 stay and cannot download, 0 with originals; the list still shows 877 as previews; Connect → the sheet leads with Holidays; link Holidays again: "877 in step, nothing arrives, nothing goes up" and no download happens (network log); Disconnect again → link Prague: the sheet says "401 arrive; 877 previews of Holidays removed" → after: 401 rows, `deletedProjects()` empty, the server's counts unchanged throughout. A Mac scratch library with 2 originals + 3 previews: disconnect keeps all 5; connect as a new library: 2 go up, the 3 evicted, no tombstones, `lapse index --verify` clean. Delete a preview on the phone → gone from the list at once → gone on the server after the check. |
| **C2a** ✅ 2026-09-17 | LANDED — `StorageRoot` on iOS: `Libraries/<id>/`, `storage.activeLibrary`, the folder registry, the one-time migration; `-storage.activeLibrary <id>` for scratch runs | a Simulator with projects launches, migrates, everything intact; a second launch does nothing; a launch killed mid-migration finishes on the next |
| **C2b** ✅ 2026-09-17 | LANDED — the switch (L22): `ModelHost`, persister re-make, singleton re-root, teardown, refusal while busy, DEBUG `deinit` proof; `LL_OPEN_LIBRARY=<id>` on iOS | two libraries on the Simulator: switch both ways ten times; capture in each — the capture lands in the open one; presets, LUTs, ladders read from the open library; no write reaches the other (watch its folder) |
| **C2c** ✅ 2026-09-17 | LANDED — Settings ▸ Libraries on iOS, the doors, Remove's guard, the sheet's phone title | Add Prague from PicPlace → 401 previews → switch → thumbs; Remove Holidays with a downloaded original not on the server → refused by name; upload it → Remove deletes the folder |
| **C2d** ✅ 2026-09-18 | LANDED — the Projects header menu; mirrors (iPhone/iPad Settings ▸ Libraries, the sheet, the card, the disconnect confirm) | design INDEX rows |

Stage D (move without originals, "Free up space") follows C2 and shares
L23's eviction.

### 17.6 Traps to carry

1. **Eviction ≠ deletion.** `PicPlaceChangeSync` honours
   `libraryIndex.deletedProjects()` (its line ~221); a preview evicted at
   a connect elsewhere (L23) or a Remove must leave no tombstone, or the
   next link deletes it on the server.
2. **Two models alive — and the retired one is NOT released.** Heap-traced
   2026-09-17: UIKit's tab-bar button labels cache the old tree's
   environment (`SwiftUIEnvironmentWrapper` in a `UITraitCollection`), and
   that environment holds the model. 12 `AppModel`s alive after 11
   switches. So a retired model is made inert and light at stand-down
   (PicPlace shut down, writes refused, documents dropped from its store);
   its index connection stays open (closing it under a task still winding
   down would be a use after free). ≈1 MB per switch on the fixture.
3. **`AppModel.sharedPersister` is a `private static let`** — re-made only
   between models, never under one.
4. **No paths in defaults on iOS** — the sandbox path changes on reinstall
   and restore. Folder ids only.
5. **Logs**: `LetsLapseApp` opens `<root>/Logs` at launch; on iOS they go to
   the container, or a switch splits the log.
6. **The card's usage line** ("On PicPlace: 877 projects") after a
   disconnect is the last binding's; hidden when unbound.
7. **`libraryItemNames` is the migration's manifest** — a store that writes
   a new file at the root and forgets the list leaves it behind (the Mac's
   `check` collides on the same list, so the Mac catches it first).
8. **A bench run on a bound scratch root read the Keychain** for the
   binding's account before `LL_PICPLACE_TOKENS` applied — an unsigned
   build asking for a stored session raises a SecurityAgent prompt on the
   person's screen and the launch blocks behind it (2026-09-17). Injected
   tokens now skip the stored session altogether.
9. **A 35 s outage does not fail a push**: the client's in-place request
   retries outlast it and the push lands late. To stage a *failed* push
   (`lastError`, the check's retry), the outage must outlast the request
   retries — see §17.7.

### 17.7 Step 0 as landed (2026-09-17 afternoon)

Commit: see the log. Bench (letslapse-two on picplace.test, scratch roots
`lib-s0a` "Step0 A" · `lib-s0b` the phone stand-in · `lib-s0c` "Step0 C";
the Simulator "Step0 Bench" for the phone's screens):

| Test | Result |
|---|---|
| T1 disconnect (2 previews + 1 original) | confirm: "2 previews pulled from PicPlace stay on this Mac but cannot download until you connect it again. 1 project with originals here stays as it is. Nothing changes on PicPlace." — binding gone, 3 folders kept, every index row live |
| T2 re-link the same library | the sheet leads with "This library was “Step0 A” on PicPlace", link preselected: "3 already here stay in step. Nothing arrives. Nothing goes up." — pass: `merge — 0 to pull, 0 to push, 3 in step`, no pull |
| T3 link elsewhere | the sheet: "1 arrives here as a preview … 1 here is filed in other libraries on PicPlace and stays as it is. 2 previews of “Step0 A” are removed from this Mac; they stay on PicPlace. Nothing goes up." — pass: `2 preview(s) removed … no tombstones`, `1 to pull … 1 filed in another library`; folders = the original + Step0 C's preview, `.trash` empty, rows live, server counts unchanged |
| T4 delete a preview | `1 deleted there`; Step0 C 1 → 0 on the server; the row tombstoned here (a real deletion) |
| iOS | bound card with *On PicPlace* and "3 brought here"; unbound card without it; a preview's detail after a disconnect: "Connect this library again to download the originals"; the sheet with the *was* line and the removal numbers ("3 previews of “Step0 A” are removed from this iPhone") |

New hook: `LL_PICPLACE_OFFER=1|new|adopt|link:<uuid>` opens the real
connect sheet once signed in, with that target selected — the numbers off
the server — so the sheet can be photographed before Connect is pressed
through accessibility (the card's row is not reachable by AX title).

### 17.8 C2a as landed (2026-09-17 evening)

- iOS `StorageRoot`: `containerURL` (the sandbox's LetsLapse folder),
  `librariesURL` = `<container>/Libraries/`, one folder per library named by
  the id it was made with; `current` resolved once at first touch; the
  registry is `libraryFolders()` — the folder listing with each identity
  file; `storage.activeLibrary` holds the open folder's id (never a path);
  `-storage.activeLibrary <id>` as a launch argument opens a folder for one
  run without writing the setting (`rootCameFromArguments`, as the Mac's
  root argument).
- The one-time move: a library found at the container is moved into
  `Libraries/<id>/` — `id` = the identity file's uuid when there is one,
  else fresh — item by item (`libraryItemNames` minus `Logs`), behind
  `<container>/.letslapse-migrating` holding the id; a launch that finds the
  marker finishes the move under that id. An item present on both sides is
  kept beside the library as `<name>.before-libraries-<stamp>`, never merged.
- `Logs/` stays at the container on the phone (`StorageRoot.logsURL`; the
  Mac keeps them with the library) — a later switch never splits the log.
- `libraryItemNames` is shared by both platforms now (it was macOS-only).
- Drill on a Simulator carrying a bound library with 2 originals, records,
  index and thumbnails in the old layout: first launch moved `Projects,
  Collections, Thumbnails, Index, PicPlace, letslapse-library.json`, the
  binding and records read (the check had nothing to do), every fixture
  file accounted for under `Libraries/<id>/`; the second launch moved
  nothing; two items put back at the container with the marker were moved
  again by the next launch. A Mac scratch library still opens and logs
  into its own `Logs/`.
- Trap for the bench: reinstalling a differently signed build re-homes the
  Simulator's data container — resolve the container by search after every
  install, not once.

Next: **C2b** — the switch (L22): `ModelHost`, the persister re-made, the
root-caching singletons re-rooted, teardown and refusal while busy,
`LL_OPEN_LIBRARY=<id>` on iOS.

### 17.9 C2b as landed (2026-09-17 night)

- `ModelHost` (iOS, `LetsLapseApp.swift`) owns the model; `switchLibrary(to:)`
  refuses while the capture flow is not home or a project is on its way to
  a nearby device, then: the old model stands down (`prepareForSwitch`:
  PicPlace `shutDown()` — timers, monitor, every task; the transfer server
  stopped if it was ever started; flush + export; `refuseWrites`; the
  documents dropped from its store), `StorageRoot.switchActiveLibrary` moves
  the root and the setting, `AppModel.resetSharedPersister()` makes the
  next persister over the new root, the five root-latching stores are
  re-made (`CustomPresetStore`, `LightLadderStore`, `LUTStore`,
  `BlendProfileStore`, `ShapemationStore` — each logs what it read and
  from where), a new `AppModel()` takes over and `.id(generation)` re-roots
  the tree. The host is in the environment for C2c's screen.
- `LL_OPEN_LIBRARY=<id>[,<id>…]` on a phone switches to each folder in
  turn, four seconds apart, once per process. The other launch hooks run
  again for each library switched to (a new model reads them at its own
  start) — `LL_IMPORT_STILLS` after a switch is how "a capture lands in
  the open library" is exercised on a Simulator.
- Drill (Simulator, two libraries): eleven switches, none refused, the
  document walk alternating between the two, presets/ladders/LUTs read
  from the open folder each time; nothing written into A while B was open
  (full-tree hash); an import at launch landed in B and the re-run import
  after the switch in A; a plain relaunch opened the last switched-to
  library; a Mac scratch library unaffected.
- Retention (trap 2): the retired model is held by UIKit's cached trait
  collections; made light instead. On the fixture (three documents) the
  process grows ≈2 MB per switch either way — that is the old view tree,
  not documents; dropping the documents matters for a real library's
  cache (hundreds of documents), which is what `forgetAll` is for. A
  person switches a few times a day; C2c/C2d may still look at whether a
  different re-rooting frees the old tree.

Next: **C2c** — Settings ▸ Libraries on iOS with the doors (Add from
PicPlace, New Library on PicPlace, Remove from this iPhone with its guard),
the sheet's phone title.

### 17.10 C2c as landed (2026-09-17 night)

- **Settings ▸ Libraries on the phone** (`librariesCardPhone`): a row per
  folder — name (the placeholder in grey until named), "N projects ·
  @user on host" or "not on PicPlace", *Current* or a *Switch* button —
  with a long-press menu: *Rename…* (or *Name this library…*) and, on
  every row but the open one, *Remove from this iPhone…*. The doors: *Add
  Library from PicPlace…* (the account's libraries no folder here is a
  copy of; the sheet lists them, *Add and Open* makes the folder, bound
  and pending its first pull, and switches to it — the pull runs at once)
  and *New Library on PicPlace…* (a name; the server library first, then
  its folder, bound and clean, and the switch). Signed out with one
  library, a quiet row says what signing in adds. A switch lands the new
  tree on Settings, not on Create.
- **Remove's guard** (`LibraryRemoval.check`) reads the folder without
  opening the library: every project folder's heavy files against its
  sync record (`serverHeavyFiles` ≥ local, or `originalsMovedAt`); a
  project whose originals exist only here names itself in the refusal
  ("Upload the originals first, or keep the library"). The confirm says
  the numbers: previews that go, originals that go (PicPlace holds them),
  and that the library stays on PicPlace and the other devices.
- The PicPlace card of a phone whose only library is unbound asks *Which
  library should this iPhone show? — Choose…* (§17.4); with other
  libraries present it is *Not on PicPlace — Connect…* as on the Mac.
- Shared with the Mac now: `librariesNotOnThisDevice`,
  `otherLibraryBound(toServerLibrary:)` (one copy per server library per
  device — the connect sheet's refusal reads "This iPhone already syncs…"),
  `bindingTemplate()`.
- Hook: `LL_LIBRARY=switch:<id>|add:<server uuid>|new:<name>|remove:<id>|rename:<id>:<name>`
  works the doors without a finger, waiting for the session where
  PicPlace is needed; once per process.
- Drill (Simulator, letslapse-two with "C2c Lib A" 2 · "C2c Lib B" 1 on
  the server): the card with its doors and both missing libraries named;
  *add* → folder made, switch, `fresh — 2 to pull`, two previews; *new*
  → "Phone Made" on the server, folder, switch, `clean`; an import into
  it pushed (records only); *remove* of it **refused** — "1 only here";
  after `LL_PICPLACE_UPLOAD` the same *remove* allowed and the folder
  gone with the server's copy intact; *remove* of the preview-only
  library allowed; *rename* took. Server counts unchanged by every
  removal.
- Mirrors owed (🟡, iOS INDEX): Settings ▸ Libraries, the Add sheet, the
  remove confirm and refusal, the New Library alert, the PicPlace card's
  phone question — C2d draws them with the Mac's.

Next: **C2d** — the Projects header title as a library menu, and the
mirrors (iPhone/iPad/Mac).

### 17.11 C2d as landed (2026-09-18) — and the programme closed

- **The Projects header's library menu** (iOS): with more than one library
  on the phone, the open library's name sits under the title as an accent
  capsule (books.vertical · name · chevron); its menu lists the others —
  a switch in place that lands back on Projects — and *Manage libraries…*,
  which opens the Settings card. One library, no chip.
- **Mirrors drawn** (the design contract, `docs/design/README.md`): iOS —
  `settings.libraries.portrait.svg`, `.add-from-picplace`, `.new`,
  `.remove`, `.remove.refused`, `settings.picplace.choose-library`,
  `settings.picplace.disconnect`, `picplace.connect.portrait.svg`,
  `projects.libraries.portrait.svg`; macOS — `settings-libraries.svg`,
  `.create`, `.move`, `.moving` (renamed from the retired
  `settings-library-location`), `.disconnect`, `picplace.connect.svg`,
  `settings-libraries.add-from-picplace.svg`; the iPad shares the phone's.
  INDEX rows ✅ on all three. Cards, the question, the connect sheet and
  the chip were mirrored from screenshots; sheets and alerts from the code.
- **The staging hook's demo values** (`LL_STORAGE=move|create|failed`)
  are now `/Volumes/Demo Drive/LetsLapse` and 12,4 GB: a staged sheet on a
  bench run had shown Steven's real volume and "148,2 GB" and alarmed him
  (2026-09-18) — a staged screen must never read as real.
- **What stays owed after C2:** stage D (move without originals, "Free up
  space"); trap 2's retained model (UIKit holds the old tree's environment
  — made light, not freed); the Simulator MCP tool's device-access
  approval, without which sheets on the phone are drawn from the code.

The libraries programme (L1–L25, stages A → C2) is closed with this entry.

### 17.12 The card's numbers, simplified (2026-09-18) — Steven's read of "518 of 879"

Steven's Mac read *On PicPlace · 518 projects* under a Libraries row
saying *879 projects*, and took 361 for originals not yet uploaded. The
records said otherwise: 518 were this library's on PicPlace (originals
held for 98 of them), 360 were **Holidays' previews** left in the Prague
folder by the 16th's mix — filed under Holidays on PicPlace, no originals,
never syncable from here — and 1 was not on PicPlace yet. Three different
truths behind one bare number.

Decisions (his: simple, and never another library's name):

- **One row, one line.** *On PicPlace — 518 of 879 projects · 854,2 MB*
  ("518 projects" when PicPlace has them all), and under it *originals for
  98 · 1 not on PicPlace yet* — the originals count from this library's own
  records (`serverHeavyFiles` / `originalsMovedAt`), the gap only when
  there is one. `PicPlaceController.LibraryTally`, computed after every
  usage refresh (which follows every check). The old *N not in this
  library yet* line — the account's other libraries' count — is gone.
- **Previews filed under another library are removed by the check** (the
  L23 rule at every pass, not only at a connect elsewhere): folder and
  index row, never a tombstone, unless a person edited the preview since
  it was pulled — that one is kept and counted. Projects with originals
  here that PicPlace files elsewhere stay, noted on their record, and the
  line says *N here are filed under other libraries on PicPlace* — a
  count, no names; a person decides those.
- Bench: a previews library whose one project was moved server-side into
  another library — `1 preview removed … no tombstones`, one folder left,
  the row *1 project*; an originals library in the same state — kept,
  `1 filed elsewhere`, the row *1 of 2 projects* with the line. Steven's
  Prague library will read *518 of 519 projects* after its next check.
- The `LL_STORAGE` demo values and the phone's *On PicPlace* row share the
  §17.11 rule: a staged or summarised number must never mislead.
