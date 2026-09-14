# PicPlace — server asks for LetsLapse sync v2

**From:** the LetsLapse app (client repo, `ios-app`) · **Date:** 2026-09-14 ·
**Context:** your answers of 2026-09-14 to the 16 questions; the client plan
they feed is `LetsLapse/docs/picplace-sync-v2-plan.md`. This is one message:
what we say yes to, in what order we need it, and what the app will assume
meanwhile. Nothing here changes the governing rules — LetsLapse produces,
PicPlace hosts, bytes never pass through PicPlace.

## What the app is going to do (so the asks make sense)

- A **library** (the folder a device works in) binds to one account on one
  server instance, keyed by `(server.id, user.uuid)`. `username` and `name`
  are display only.
- The server project key becomes the project's **`originID`** (v1 sent the
  local `capture.id`; for a new capture they are equal).
- **Minimal sync first**: per project the app pushes the manifest
  (`project.json`, inline), **one records bundle** (an Apple Archive of the
  sidecars, masks, notes, capture logs — 10 KB to ~12 MB), **one poster**
  (`preview`, ~100 KB JPEG) and hash-deduped LUT/ref objects. **Originals and
  blends are not uploaded** in this phase; they follow per project on
  demand, and later automatically. This is our answer to your small-object
  point: S3 gets originals, blends and one poster per project; everything
  else is one bundle.
- A fresh device pulls records + posters and shows the gallery as
  "preview-only" until it downloads originals.
- Libraries that meet an already-synced account **merge** three-way per
  project (base = the revision this device last agreed on); conflicts are
  resolved by newest edit or by hand, with "keep both" forking the loser.

## Asks, in the order the client stages need them

### Stage 1–2 (binding + minimal push)

1. **`server` block in `GET /status`** — as you proposed:
   `server: { id, environment, url }`, `id` a uuid minted once per install.
   The app binds libraries to `(server.id, user.uuid)`; until it exists we
   bind to `(host, user.uuid)` and upgrade in place. **Highest priority** —
   everything else keys off it.
2. **A `records` asset kind** (or confirm we may use `note` for the bundle
   until then). One object per project, replaced whole on change, content
   type `application/octet-stream` (Apple Archive, lzfse), sha256 + bytes
   declared like any asset. Object key stays yours (`{kind}/{asset_uuid}`).
3. **`origin_uuid`** on `PUT /projects/{uuid}` — yes please; the merge's
   "keep both" and `uuid_taken` re-mints set it.
4. **The manifest cap**: raise nginx to 16M, cap the app at 8 MB, report
   `manifest_max_bytes` in `/status`, answer `413 manifest_too_large` as JSON,
   correct the doc. The app reads the value and assumes **1 MB** until it is
   reported. Overflow shape as you described (`manifest`-kind asset +
   `{ "manifest_asset": "<id>" }` stub) — we will implement it but no
   project is within 5× of the cap today (largest `project.json` 189 KB).
5. **Account-wide dedupe on negotiate** — `(sha256, bytes)` match → CopyObject
   → returned `confirmed` with `upload: null` and `copied_from`. Our real
   library has 140 per-project LUT copies (~0.9 MB each, mostly the same few
   cubes); this makes them free. Your caveat (client-declared sha256, scoped
   to the account) is accepted.
6. **`PATCH /assets/{id}` with `name`** — yes; a rename is a row update.

### Stage 3–4 (fresh pull, merge)

7. **`projects: { count, by_type }` in `/status`** — the "has this account
   synced anything?" check without an index pull.
8. **`?updated_since=<ISO8601>` on `GET /projects`** — the merge and every
   later "what changed" pass. Paging can wait until accounts pass a few
   thousand projects, but say if you would rather add a cursor now.
9. **Soft-delete tombstones** exactly as you proposed: `deleted_at`, hidden
   by default, `?include_deleted=1` (and via `updated_since`), 90 days, then
   purge; **an explicit PUT from a device that still holds the copy
   resurrects** (agreed — the tombstone exists so the other device can say
   "deleted from PicPlace on <date>" first). `uuid_taken` continues to apply
   to other accounts' tombstoned uuids.
10. **`updated_by` (device) on the project row** — new, small: the merge's
    conflict screen wants to say "edited on iPad, 13 Sep 21:40". Today we
    would infer it from the presence row whose revision equals the
    project's, which is a guess.

### Stage 5 (originals per project)

11. **`POST /projects/{uuid}/assets/urls`** with `assets: [ids]` (≤100) —
    yes; the app mints pages as it downloads (15-minute URLs).
12. **`422` at negotiate for `bytes > 5 GB`** until multipart exists —
    yes; no blend on our library exceeds 5 GB today (147 blends, 13.4 GB).
    Multipart as you sketched when a real blend crosses ~1 GB is fine to
    defer.
13. **Presence `tier`** (`original` | `proxy` | `preview`, nullable) — yes,
    `tier` rather than `kinds`; it is what "is it safe to delete the
    original here?" needs. The app will report `preview` after a pull and
    `original` after an originals upload.
14. **`409 upload_missing` when a confirm's `sha256` disagrees with the
    confirmed one** — yes, make the reaped-then-confirmed case explicit.
15. **Rate limit per device with an account backstop** — 300/min per device,
    1,000/min per account is fine for us; with batched negotiate/confirm/URLs
    a full minimal sync of 365 projects is ~1,500 calls.

### Later (not needed for stages 1–5, flagged so the model stays merge-ready)

16. **An account-level record surface** — the library's own records
    (presets, imported-LUT index, blend profiles, light ladders, collections)
    are a few MB per account with no project to hang them on. Either
    `PUT /library` (one bundle + revision, same claim/presence shape as a
    project) or a reserved pseudo-project — your preference. Not in v2.
17. Server-assigned revisions and a per-account change sequence
    (`?since=<seq>` over projects, assets, presence, tombstones) — the
    change journal from the larger programme. Agreed to scope together
    before building; the client's M5 (`apply(change)` funnel) is the
    matching half.
18. Multipart uploads — when needed (12).

## Facts we will rely on unless you say otherwise

- One `device_key` under two accounts = two rows, two token lineages; no
  "move device". The app keys tokens per `(server, user.uuid)`.
- `users.verified` stays a manual gate; the app shows the "not enabled"
  state and never retries a `403 account_not_enabled`.
- `updated_at` moves only on a manifest PUT; asset confirms, claims and
  presence do not bump it.
- `used_bytes` = manifest + confirmed asset bytes; pending never counts;
  the reaper runs 2 h–2 h 30 after negotiate; re-negotiating the same
  `name` before that refreshes the same upload. The app re-negotiates on
  any 403 from storage.
- Presigned lifetimes come from `/status` (`storage.upload_url_ttl_seconds`,
  `download_url_ttl_seconds`); the app never hard-codes them.
- The web view is keyed by uuid (`/letslapse/p/{uuid}`), never username;
  PicPlace never processes LetsLapse bytes; "import to Photos" is an explicit
  copy. The app will upload one poster per project so `/letslapse/` has
  something to show.

## Test environment

Stages 1–5 are verified against `picplace.test` + Garage from this Mac and
the iOS Simulator (the Simulator trusts the Valet CA after
`xcrun simctl keychain <udid> add-root-cert …`). Physical iOS devices only
ever test against `picplace.co`, once the flows hold locally. Steven's
account is `verified` on both; a second throwaway `verified` account on
`picplace.test` would help the two-account cases (`uuid_taken`, disconnect
and re-bind) — could you create one?
