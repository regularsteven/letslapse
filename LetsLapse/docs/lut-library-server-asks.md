# Server asks — LUTs as account-level objects (stage C of `lut-library-assets.md`)

**Written:** 2026-09-18 · **For:** the PicPlace server (`~/Sites/picplace`) ·
**Priority:** low-risk cleanup first (ask 3), the surface when convenient.

## What changed on the client (2026-09-18)

A LUT (`.cube`) is a **library asset identified by its content hash**, kept
once per library; a project's `project.json` names the hash (as it always
did) and the project folder holds no copy any more. The client **no longer
negotiates `lut`-kind assets per project**. Nothing on the client ever
downloaded them: the initial pull takes the records bundle and the poster,
the originals download takes `source/` and `blends/`. The 265 confirmed
`lut` objects on `picplace.test` (8 distinct sha256, 252 MB, one object per
project and name under `u/{user}/p/{project}/lut/{uuid}.cube`) are
write-only.

## Asks

1. **An account-level LUT surface, content-addressed.**
   - `POST /luts` — negotiate `{ sha256, bytes, name, title, size }` for one
     or many; a cube the account already holds comes back `confirmed` with
     `upload: null`; a new one gets a presigned PUT and a confirm, exactly
     like a project asset. **Dedupe is identity, not CopyObject**: the
     object key is `u/{user}/lut/{sha256}.cube`, one object per distinct
     cube per account.
   - `GET /luts` — the account's cubes: `sha256, bytes, name, title, size,
     created_at, uploaded_by_device`. `name` and `title` are the cube's
     properties (the file name it was imported under, the file's `TITLE`),
     so a fresh device can rebuild its `luts.json` from the rows.
   - `POST /luts/urls` — presigned GETs for a list of sha256, the same
     shape as `projects/{uuid}/assets/urls`.
   - Scope: **per account, not per library** — a cube is the same bytes
     whichever library references it, and the libraries programme keeps
     object keys account-scoped (`libraries-plan.md` L8). No `library_id`.
   - Usage: LUT bytes count once per account in the ledger.
   - Lifetime: for the account's life. A `DELETE /luts/{sha256}` is not
     needed now; a later ask will scope it with reference counting from the
     manifests if it ever matters.
2. **`features.library_luts: true` in `GET /status`** once ask 1 is live;
   the client pushes a cube on import (and at the check for any cube the
   store holds that the account does not) and fetches by hash when a
   document names a cube the library lacks. Until the flag is there the
   client does neither, and a `.lapse` still carries the cube for offline
   portability.
3. **Cleanup — delete every existing `lut`-kind asset row and object.** No
   client reads them, and the new client never sends them. A
   `letslapse:luts-cleanup` artisan command per account (or all) is enough;
   this is not a production system yet. The negotiate endpoint may refuse
   `kind: lut` on a project afterwards, or keep accepting it as a harmless
   no-op — your call; the client will not send it.
4. **The general point, for later**: CopyObject dedupe duplicates bytes for
   every kind (a forked project's identical source frames included). A
   shared object per `(account, sha256)` with rows pointing at it and a
   ref-counting reaper would collapse those too. LUTs are the first and
   cleanest case; nothing else is asked now.

## What the client will do once ask 1 exists (for the record)

- Push: after `LUTStore.importCube` and after the fold, and at each check
  for store cubes the account lacks (a `GET /luts` diff).
- Pull: at the editor open, the export, and the originals download, any
  hash the document names and the store lacks is fetched into
  `<root>/luts/<hash>.cube` and recorded in `luts.json` from the row's
  `name`/`title`.
- Resolution order stays store → legacy copy → PicPlace → missing.
