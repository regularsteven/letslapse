# PicPlace: a library's collections — the ask

**Raised:** 2026-09-25 (connected asset states, stage 5, D3 — Steven: *write the
ask; build only the app side, switched on when the server supports it*) ·
**App side:** built, dormant (`App/PicPlace/PicPlaceCollectionsSync.swift`) ·
**Read with:** [connected-asset-states-plan.md](connected-asset-states-plan.md)
§15, [picplace-sync-v2-handover.md](picplace-sync-v2-handover.md).

## Why

A LetsLapse **collection** is an edit built from blends — their order, in and
out points, crops, Ken Burns moves. The brief's rule 4: a collection can be
authored *and rendered* on any device that has the blends. Blends travel
already (each project's assets). Collections do not: they live in the
library's `Collections/collections.json` on the device that made them. The
library record on PicPlace (`PUT /libraries/{uuid}`) takes a name only.

## What the app needs

One JSON document per library, stored as given, behind a revision.

### Read

`GET /api/letslapse/v1/libraries/{uuid}/collections`

```json
{ "revision": 7, "document": { "formatVersion": 1, "collections": [ … ] }, "updated_at": "…", "updated_by": { "id": "…", "name": "Steve 18 Pro" } }
```

- A library with no document yet answers `{ "revision": 0, "document": null }`.
- `document` is returned **exactly as stored** — the app encodes and decodes
  it with its own document format (`CollectionsDocument`); the server never
  needs to understand a collection.
- 404 for a library that is not the caller's (as `GET /libraries/{uuid}`).

### Write

`PUT /api/letslapse/v1/libraries/{uuid}/collections`

```json
{ "base_revision": 7, "document": { "formatVersion": 1, "collections": [ … ] } }
```

- **200** `{ "revision": 8 }` when `base_revision` is the current revision —
  the document replaces the stored one and the revision moves by one.
- **409** `{ "error": "stale", "message": "…", "revision": 9 }` when it is
  not: another device wrote first. The app then reads, merges collection by
  collection (the later change wins; a deletion counts as a change) and
  writes again against the new revision. Returning the current document in
  the 409 body is welcome but not needed.
- **413** above a size cap (suggest 5 MB; a large collection is a few KB).
- The device header is recorded as `updated_by`, as for projects.

### Say so

`GET /status` → `"features": { …, "collections": true }` once both endpoints
are live. The app does nothing collection-related on a server without it.

## What the server can stay out of

- **Merging.** The app merges; the revision only has to refuse a stale write.
- **Tombstones.** Deleted collections stay *inside* the document
  (`deletedAt`), so a deletion reaches other devices; nothing to track
  server-side.
- **References.** A collection names blends by id (`entries[].blendID`); a
  missing blend is the app's to show (from its still) and fetch.

## Nice to have

- Keep the last few revisions (a day?) — a bad write can be rolled back by
  hand.
- Remove the document with its library (library delete / purge).
- A `collections_updated_at` on `GET /libraries` so the check can skip the
  read when nothing moved (the app reads it at every check today — one small
  GET).

## How the app uses it

- **At every check** (the 3-minute timer, a network change, the foreground):
  one GET; the merge; this library's `collections.json` rewritten if
  PicPlace had newer changes; a PUT if this device had.
- **A few seconds after a collection changes here** (a trim, a reorder, a
  Ken Burns edit): one PUT against the revision last seen.
- **Offline or failing:** nothing is lost — the file is the truth on the
  device, and the next check merges again.

## Testing it together

On picplace.test with two bench libraries linked to the same server library
(the two-device bench): a collection made on A appears on B at B's next
check; an edit on both before either syncs keeps the later one; a deletion on
A reaches B; a stale write from B (409) merges and lands. `LL_COLLECTIONS=seed`
makes a collection on a bench library.
