# PicPlace — server asks for LetsLapse libraries (hand-over to the PicPlace developer)

**From:** the LetsLapse app (client repo, `ios-app`) · **Date:** 2026-09-16 ·
**Owner on the server side:** the PicPlace developer, independently — this
is stage B of [libraries-plan.md](libraries-plan.md); the client's stage C
waits for it, so **the server goes first** (Steven, 2026-09-16) · **Answer
expected as** `picplace/docs/letslapse-libraries.md`, in the shape of
`letslapse-sync-v2.md` (what is built, the exact wire shapes, where an
answer differs) · **Governing rules unchanged:** LetsLapse produces,
PicPlace hosts, bytes never pass through PicPlace — and **nothing here
touches object keys**.

## 0. Why now — what happened on 2026-09-16

A LetsLapse account on PicPlace is one namespace of projects. Steven had two
libraries on one Mac — a 431 GB real one and an 879-project test one — and
connected both to the same account, one after the other. The v2 merge did
exactly what it was built to do: the real library received 879 preview
shells, the test library's namespace received 398 real projects, and the
account ended at 1,276 with no way, on the server, to tell which project
belongs to which library. The client can add rules against this, but the
truthful fix is that **the server knows what a library is**: a person keeps
a *client X* library, a *personal* one, a *timelapse gallery*, and backs
all three up under one account without them ever meeting. Later, a library
is the natural unit to share with a client.

## 1. The model the client will use

**Account ⊃ libraries ⊃ projects.**

- A **library** is a row: a client-minted uuid (the identity file
  `letslapse-library.json` every local library already carries), a name
  the person gave it, a tombstone. Its key on the server is that uuid,
  exactly as a project's key is its `originID`.
- A **project** belongs to at most one library. **`null` means the
  account's default library** — every project that exists today, and every
  project a client that never sends `library` will ever create. The v2
  client keeps working unchanged after the deploy.
- A local library binds to exactly one server library
  (`server.id, user.uuid, library.uuid`). A Mac may hold several libraries
  of one account at once; a phone shows one *active* library and captures
  into it.
- **Unchanged:** devices, tokens, presence `(project, device)`, claims,
  `updated_by`, rate limits, assets, negotiate, dedupe, the reaper, the
  purge, object keys `u/{user}/p/{project}/…`. With library scope two
  libraries on one device hold disjoint projects, which is what keeps
  `(project, device)` presence unambiguous — no per-library device rows.
- **Not asked now:** sharing (a `library_members` table later — reader /
  editor; a member's own tokens; usage stays the owner's). The shape below
  is chosen so that is additive.

## 2. Asks, in build order

### 2.1 Library rows

`letslapse_libraries`: `id` uuid primary (client-assigned, stored
lowercase), `user_id`, `name` (string ≤ 255, required), `created_by_device_id`
/ `updated_by_device_id` (nullable FKs, as projects), timestamps,
`deleted_at` (soft delete, purged with the project policy, 90 days). Index
`(user_id, updated_at)`.

`letslapse_projects.library_id`: nullable FK → `letslapse_libraries`, index
`(user_id, library_id)`. No cascade: a library cannot be deleted while it
holds live projects (2.3).

### 2.2 `PUT /libraries/{uuid}` — create or rename

```json
{ "name": "Field 2026", "adopt_default": false }
```

- First PUT for a uuid creates (`201`); a later PUT renames (`200`).
  Registered device required (`letslapse.device`), scope `projects:write`,
  no claim (libraries have none).
- A uuid registered under another account, live or tombstoned, is
  `409 uuid_taken`; the client re-mints, as for projects.
- **`adopt_default: true`** moves every project of the account whose
  `library_id` is null into this library in the same request — how an
  existing account's projects become a named library in one call. Returns
  the count moved.
- A PUT against the account's own tombstone brings the library back
  (`201`), as for projects.

Response: `{ "library": { …2.3 shape… }, "adopted": 0 }`.

### 2.3 `GET /libraries`, `GET /libraries/{uuid}`, `DELETE /libraries/{uuid}`

```json
{ "libraries": [ {
    "uuid": "…", "name": "Field 2026",
    "projects": { "count": 12, "by_type": { "photo": 3, "interval": 8, "video": 1 } },
    "used_bytes": 1234567,
    "created_by": {"id","name","platform"}, "updated_by": {"id","name","platform"},
    "created_at": "…", "updated_at": "…", "deleted_at": null
  } ],
  "server_time": "…" }
```

- `include_deleted=1` adds tombstones. No paging (a person has a handful).
- `DELETE` requires **no live project** in it — else `409 library_not_empty`
  with the count; tombstoned projects do not block. Response
  `{ "deleted": true, "uuid", "deleted_at" }`. Nothing is purged from
  storage by a library delete (it holds no objects).
- `used_bytes` = the manifests + confirmed assets of its projects, the
  arithmetic of `status.storage.used_bytes`, per library.

### 2.4 `POST /libraries/{uuid}/projects` — assign a list

```json
{ "projects": ["<uuid>", "…"] }          →   { "moved": 398, "unknown": [] }
```

Moves the named projects of the caller's account into the library (from
the default library or from another library); unknown or foreign uuids are
reported, not refused. Needs `projects:write` and a device; **no claims** —
this is a library operation, not an edit. It is how a client sorts out an
account that was already mixed (the 2026-09-16 case: the volume's 398 into
*letslapse*, the play-pen's 879 into *play-pen*), and later how "Move to
library…" works. `updated_at` on the projects moves (other devices' scoped
`updated_since` passes must see them leave one library and enter another).

### 2.5 `library` on the project

- Every project shape gains `"library": "<uuid>" | null`.
- `PUT /projects/{uuid}` accepts `library` (uuid or `null`; **omit to leave
  it unchanged**). A uuid that is not one of the caller's live libraries is
  `422 library_unknown` — never auto-created; the client creates the
  library first (one request, 2.2). Moving one project this way needs the
  claim like any update; the client bumps the revision as for a rename.
- Object keys unchanged; a move is a row update — no CopyObject, no purge.

### 2.6 The index filter

`GET /projects?library=<uuid>` narrows to one library; `?library=null` is
the default library; no parameter is the whole account, as today. Composes
with `type`, `updated_since`, `include_deleted`. Tombstones keep their
`library`, so a scoped `updated_since` pass sees its own deletes.

### 2.7 `GET /status`

- `libraries: [ … ]` — the 2.3 shape for every live library **plus one
  entry for the default library when it holds any project**:
  `{ "uuid": null, "name": null, "projects": {…}, "used_bytes": … }`. The
  connect chooser and the phone's picker list these.
- `projects.count` stays account-wide (the v2 client reads it).
- `features.libraries: true` — **plural**; `features.library` already
  names the account-bundle surface and stays what it is.

### 2.8 Test tooling — `letslapse:wipe-account {user}` (artisan)

Deletes every LetsLapse project, asset row, presence, claim, library and
object of one account on the instance — **test instances only**, guarded
(`APP_ENV=local`, or an explicit `--force` with the username typed back).
Needed today to clean @regularsteven on picplace.test after the mixed
merge (§0), and by the client's two-device bench between runs.

### 2.9 Web and admin (not blocking the client)

- `/letslapse` (usage + read-only browser): a library filter, each
  library's count and bytes.
- `/admin/letslapse` roster: libraries per account beside devices.

## 3. What the client will do once this exists (so the shapes are checked against use)

1. **Connect** (Mac or phone): the card shows *Not on PicPlace — Connect…*;
   the question offers **New library on PicPlace — "Field 2026"** (this
   library's N projects go up) or **link to** an existing library from
   `status.libraries[]` (M there, N here — merge), with what arrives and
   what goes up stated in numbers. Never automatic after a sign-in.
2. **Every push, pull, check and tombstone is scoped** by the library's
   uuid: `?library=` on the index, `library` on the PUT.
3. **A fresh Mac** signing in chooses which libraries to bring down; each
   becomes a local library named from the row.
4. **A phone** keeps one store; projects carry their library; an active
   library is where captures land; other libraries' previews pull on
   demand.
5. **Rule per install:** at most one local copy of a given server library.
   Different server libraries under one account coexist.

## 4. Facts the client will rely on unless you say otherwise

- `null` is the default library; no row is ever created for it; nothing
  existing is migrated by the deploy.
- A project PUT with an unknown `library` is `422`, never auto-created.
- Library uuids are `uuid_taken` across accounts, live or tombstoned.
- Library tombstones live 90 days (`limits.tombstone_days`).
- `POST /libraries/{uuid}/projects` needs no claims.
- Presence, claims, assets, negotiate, dedupe, reaper, purge: unchanged.
- `used_bytes` per library is display arithmetic; billing stays per account.

## 5. Test environment and the executable spec

picplace.test + Garage first (the v2 rig). The play-pen at
`~/Library/Application Support/LetsLapse/picplace.test/regularsteven/` is the
**unchanged v2 client** that must behave identically after the deploy (its
projects report `library: null`; its checks and pushes never send the
field). Feature tests in `tests/Feature/LetsLapse` are the spec: create /
rename / resurrect / `uuid_taken` / `adopt_default` / assign-a-list incl.
unknown uuids / delete-refused / delete-empty / the index filter incl.
`null` / `422 library_unknown` / `status.libraries[]` incl. the default
entry / the wipe command's guard / the v2 shapes unchanged. picplace.co
only after that, with throwaway libraries.

## 6. Answers to the PicPlace developer's review (2026-09-16 evening)

Read against the client as it stands (`App/PicPlace/PicPlaceChangeSync.swift`
runs the check as a **full** index pass today — `updated_since` is
deliberately unused because it misses local-only edits — and
`PicPlaceSyncRun` sends the manifest PUT). Go with every default listed;
the specific answers:

**Q1 — departures on a scoped incremental pass. Yes, build `library_changed_at`
exactly as proposed**, and the client accepts the rule verbatim: in a
scoped pass, a returned row whose `library` ≠ the scope is a *departure
notice* — acted on only if the device holds the project, never treated
as an arrival; rows moving between two other libraries are ignored by
that rule. Two things so the shape is checked against use:

- The client's first scoped check will be a **full** scoped pass
  (`?library=<uuid>&include_deleted=1`, no `updated_since`), which you say
  stays exact — the client then detects a departure as *held here, absent
  from the scoped index, and not tombstoned there*. So nothing in stage C
  waits on the incremental mechanism; it is what makes the later
  incremental pass (phones, the change feed) possible without a full
  diff. Both, in other words.
- `library_changed_at` on the project shape is welcome regardless: it is
  also the honest "moved on <date>" for the card.

**Q2 — `library` on the PUT. Confirmed: the client sends `library` only on a
PUT that may create** (first push, resurrection) **and on a deliberate
move; ordinary updates omit it.** §3.2's "every push" was wrong and is
withdrawn. The client will also handle `422 library_unknown` on a create
(the library was deleted or purged meanwhile) by re-`PUT`ting the library
and retrying the push once.

**Q3 — tombstones travel with the live rows; `adopted` / `moved` count live
projects; `unchanged` for rows already in the target; replay idempotent.
Fine.** The client reads `moved + unchanged` as "in the target now".

**Q4 — resurrection into a dead library lands in the default library;
no live project ever references a tombstoned library. OK.** The client
names a live `library` on every resurrection PUT anyway (Q2), so the
fallback is a safety net, not a path it plans to use.

**Q5 — `letslapse:wipe-account`: devices and tokens survive — confirmed,
that is what the bench needs.** Dropping the usage ledger and the
reconciliation rows and hard-deleting tombstones is right; `--dry-run`
welcome.

**Q6 — no uniqueness on names, rename last-writer-wins. Fine.** The
client's chooser lists uuid and name and shows a local "you already have
a library called this" line when naming; no `409 name_taken`.

**Defaults — all accepted:** the scopes, `deleted_by` on the library,
`library` + `library_changed_at` on the project, the full-shape default
entry in `status.libraries[]` only while it holds a live project,
tombstoned libraries only via `include_deleted=1`, `?library=null` /
empty-is-absent / unknown-uuid-is-empty-list, `422 library_unknown`
before claim and revision, `409 library_deleted` on assign, no cap on the
list, a library's `updated_at` moving on rename and resurrection only,
`nullOnDelete` on the FK, the purge in the daily command, `uuid_taken`
checked against libraries only.

**Notes acknowledged:** the play-pen (unchanged v2 client) keeps writing
into the default library, so `uuid: null` reappears on picplace.test —
expected; after a wipe everything comes back as plain creates.

Stage C on the client side starts on your answer doc
(`docs/letslapse-libraries.md`); end-to-end on picplace.test + Garage
with two scratch libraries under one account, then the unchanged
play-pen beside them.
