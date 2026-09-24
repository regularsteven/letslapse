# PicPlace × LetsLapse — server asks for "free up space"

**From:** the LetsLapse app (`ios-app` branch) · **Date:** 2026-09-23 ·
**For:** the PicPlace developer · **Answer, when there is one:** beside the
others in the picplace repo's `docs/` (e.g. `letslapse-free-up-space.md`).

## Why these asks

The app is gaining a way for a device to let go of its heavy files once
PicPlace holds them. A phone becomes a capture device: shoot, upload, free the
space for the next shoot.

- **The project card:** *Remove originals from this iPhone* (the `source/`
  media) and *Remove blends from this iPhone* (`blends/`).
- **Settings ▸ PicPlace:** *Remove originals already on PicPlace*, a button
  pressed now and then (never automatic). It works through every project and
  frees the space the ones fully on PicPlace take.

The records bundle, the poster and the manifest stay on the device, so each
project still shows as a preview. *Download originals* brings the files back.

The app deletes a file only after a fresh `GET /projects/{uuid}`, read just
before it deletes anything, shows an asset at the **same path, `confirmed`,
same `bytes`, same `sha256`**. Nothing here needs the server to change for
that. What changes is what the server is afterwards: **for those projects,
PicPlace may hold the only copy.** Two things the server does today were
fine while every device kept its originals, and matter now.

---

## Ask 1: storage checks each upload's content, not just its size

**Today.** `AssetController::confirmOne` HEADs the object and compares
`bytes`. The `sha256` it stores is the one the client declared at negotiate
and repeated at confirm; nothing reads the bytes. A body of the right length
with the wrong content is confirmed. RAW frames from one shoot can be the same
size to the byte, so size alone proves little.

**Ask.** Sign the declared SHA-256 into every presigned PUT, so object storage
itself refuses a body that doesn't hash to it:

- In `ObjectStore::uploadUrl`, pass `'ChecksumSHA256' => base64_encode(hex2bin($sha256))`
  in the options to `temporaryUploadUrl` (beside `ContentType`). The SDK then
  signs `x-amz-checksum-sha256` and returns it in `$signed['headers']`.
- It reaches the app in `upload.headers` on the negotiate response. **The app
  already sends every header the server returns** (it only drops `host`), so
  no app change is needed. A mismatching body gets `400 BadDigest` from
  storage, the app reports "Storage refused <file> (400)", and the asset never
  confirms.
- **Garage (picplace.test):** please check the running Garage version accepts
  `x-amz-checksum-sha256` on PutObject. If it doesn't, keep it behind a config
  switch for the dev stack; production S3 is the one that matters.
- **Assets confirmed before this ships:** a one-off
  `letslapse:verify-assets [--account=] [--dry-run]` that reads each confirmed
  object, hashes it and compares with the stored `sha256`. On a mismatch,
  **take the asset out of `confirmed`** (a new status such as `corrupt`, or
  back to pending with the object kept for inspection) and report it. The
  app's check already refuses anything not `confirmed`, and its upload path
  re-sends a file whose asset isn't confirmed, so a demoted asset heals on the
  device's next upload.
- Optional: `/status.features.verified_uploads: true` once the header is
  signed, so the app's copy can say "checked by PicPlace".

## Ask 2: a "Recently deleted" window for objects

**Today.** `DELETE /projects/{uuid}` purges every object under the project's
prefix at once (sync-v2 answer §9: "originals that existed only on the server
are gone"). The tombstone row lives 90 days, but the files don't.

**Why it matters now.** After a phone has removed its originals, a delete of
that project anywhere loses them for good: on the phone, on another device, or
a device carrying out a tombstone it received. Until now another device
nearly always still had them. The app will say so in its delete confirm
("its originals are only on PicPlace — deleting removes them for good"), but
a window would make this recoverable.

**Ask.**

- Keep a deleted project's objects for **N days** (30 suggested) before the
  purge. Advertise it as `/status.limits.deleted_object_days` (0 or absent
  means today's behaviour).
- Within the window, a **resurrection** (`PUT` from a device, as today)
  brings the retained objects back as confirmed assets instead of needing a
  re-upload. Dedupe may already get most of the way. Or add
  `POST /projects/{uuid}/restore`, which brings the tombstone back whole
  (manifest and assets); either shape works for the app.
- Your call, but please tell us: do retained bytes count towards
  `used_bytes` or the quota? The app's copy would mention it.
- The app will read `deleted_object_days` and change its delete confirm to
  "…can be restored from PicPlace for 30 days".
- Nice to have later: a web list of recently deleted projects.

## Ask 3 (optional, only if it's slow in practice): batched asset lists

The Settings run reads `GET /projects/{uuid}` once per project, paced under
the per-device budget (~255 requests a minute at the client's 85 %). That's
fine for hundreds of projects. For thousands, a batched read would help:
`POST /projects/assets` with `{"uuids": [≤100]}` returning
`{"projects": [{"uuid", "assets": [...]}]}` (the heavy assets alone would do).
Earlier ask 21 (a bulk manifest endpoint) overlaps; one endpoint could serve
both.

## Round 2: answers to the developer's questions (2026-09-24)

### 1. Stale hashes: agreed, and the app side is built

- The app uses a recorded hash only while the file is the same size and
  unmodified since it was hashed. Otherwise it hashes the file again before
  negotiating.
- After a storage `400` on a PUT, the app re-hashes the file once.
  - If the file changed since it was recorded, it's negotiated again under
    the fresh hash and uploaded as it is now. Its record is refreshed and the
    person is told: *"N files had changed since they were recorded — PicPlace
    has them as they are now."*
  - If it still matches, the `400` is reported as the failure. No loop.
- Downloads are checked against your `sha256` before they're kept (*"arrived
  damaged — try again"*).
- Once the checksum is signed, a stale hash can only reach a path you don't
  already hold as confirmed (see 2).

### 2. Overwrites: yes, refuse. The app makes originals write-once first

A code sweep found three places where the app rewrites originals in place
today. The first answer ("originals are written once") was wrong:

- **Rotate 90°** writes the orientation into every frame, clip and blend.
  The tag edits are lossless, but the bytes change; a DNG can differ by 2–4
  bytes at the same size.
- **Convert ProRes → H.264 (delete originals)** can re-encode an existing
  `-h264.mp4` at the same path.
- **Scan re-correction** rewrites `-corrected.heic`.

Steven's call (2026-09-24) is that all three change in the app:

- Rotate 90° becomes a project record: `capture.quarterTurns` in the
  manifest, 0–3 clockwise, applied when the picture is read. No file is
  touched.
- A conversion never overwrites an existing encoding.
- A scan correction writes a new file.

After that build, originals and blends are write-once, and your proposal
stands:

- **Refuse per item** inside the negotiate response: any change to a
  **confirmed** `source` or `blend` asset whose bytes or `sha256` differ,
  answered with `{"error": "asset_immutable", "message": …, "asset": <the
  confirmed row>}`. Not a whole-request `409`, which would fail the other 99
  files of a batch.
- **Check before `findDuplicate`.** Today a negotiation that finds the new
  hash elsewhere in the account copies it over the path on the spot. There's
  no upload or confirm for a later check to catch.
- **Keep these replaceable:** `records`, `preview` and `manifest` (they
  change by design), and any asset that isn't confirmed (pending, or demoted
  by Ask 1's check), so a good copy can heal a bad one.
- **Timing:** turn the refusal on once Steven's devices run the new build.
  Older builds still rewrite originals when rotating, and a refusal would
  stop those rotations from syncing. Steven will say when.
- **The app already handles `asset_immutable`.** It sets the file aside,
  names it on the project, and doesn't retry.

### Rotation: what PicPlace needs to know

Built and bench-checked in the app on 2026-09-24 (uncommitted until Steven
signs it off):

- **Originals stay exactly as captured.** A project's turn is
  `capture.quarterTurns` in `project.json` (the manifest you store): clockwise
  quarter turns, 1–3, absent for none. It applies after the file's own
  orientation (EXIF tag or video track transform) and before the fine
  rotation and crop, which are already records in the grade. So to show an
  original: EXIF orientation first, then 90° clockwise × `quarterTurns`.
- **A turn changes the manifest only.** No original or blend changes a byte,
  so a Rotate is a manifest `PUT` (a revision), never an asset upload. The
  small companions that hold drawn geometry — `overlays.json` (mask shapes),
  `shapes.json` — are rewritten with the picture, like any edit to them.
- **Blends carry the turn they were rendered at:** `blends[].renderedQuarterTurns`
  (absent for 0, and for every blend made before this build). A blend is
  shown turned by `quarterTurns − renderedQuarterTurns` (mod 4). A blend
  rendered after a turn has it in its pixels (stills) or its track transform
  (video), so it shows as it is.
- **`poster.jpg` is rendered with the turn applied**, as with every edit, and
  a turn re-renders it on the next sync.
- **Anything PicPlace renders from an original should apply the turn**, and
  from a blend the difference: a web viewer, a thumbnail made on the server.
  A download of the original is the file as captured, as in any
  non-destructive editor. (The app's own Save to Photos, Share and Export
  write the turn into the copy they hand over — the orientation tag for
  JPEG, HEIC, DNG and TIFF-built raws, the track transform for a movie —
  if PicPlace ever wants its downloads to match.)
- **Projects rotated by older builds** already carry the turn inside their
  files, on the devices and on PicPlace. Their `quarterTurns` starts at 0.
  Nothing to migrate.

### 3. Shapes: both fine

- **Batched asset lists:** ≤100 uuids per request, results in request order,
  `{"uuid": …, "error": "not_found"}` for an unknown one, and `next` (the
  uuids not reached) if you also cap by size.
- **Restorable until:** a UTC ISO-8601 `restorable_until` on the tombstone.
  - It appears in the index (`include_deleted`, `updated_since`), the detail,
    and the `409 project_deleted` payload, and is `null` once purged.
  - Also `/status.limits.deleted_object_days`.
  - The app's delete confirm will then say *"can be restored until …"*
    instead of *"for good"*.

## Round 3: the developer's answers (2026-09-24), and what the app did

The server's side is in the PicPlace repo, `docs/letslapse-free-up-space.md`.

- **`verified`, built in the app the same day.** A file is let go of only
  when its asset is confirmed, the same size and SHA-256, **and `verified`**
  (PicPlace has read its copy back; on picplace.co within a minute or two of
  the confirm, on picplace.test at the confirm). An unverified match refuses
  with *PicPlace is still checking N files it received — try again in a
  minute or two*. The heavy set's marker (`heavyDigest`, what a library's
  *Remove from this iPhone* trusts) is written only for a verified set. A
  server that does not send `verified` is not taken at its word. Checked
  against picplace.test: its rows read `verified: true`, and a removal and
  download round trip of a throwaway project passed.
- **The overwrite rule** is a per-server switch, off on both servers, on
  when Steven says his devices run this build. The app handles its per-item
  `asset_immutable` refusal already; it does not read
  `features.immutable_originals`, since nothing it does depends on it.
- **Rotation: nothing on the server.** A turn is a manifest `PUT`; the
  companions it changes travel as replaceable kinds.
- **Not used yet:** `POST /projects/{uuid}/restore` (the delete confirm could
  say *can be restored until …*). The batched `POST /projects/assets` is used
  since the afternoon — see below.

### The developer's report of the first day on picplace.co, and the answers

- **"Every project re-uploaded as a manifest, for a new size field."** Not a
  new field: `capture.sizeBytes` / `sizeMeasuredAt` have been in
  `project.json` for months (a cached measurement of the project folder, for
  the Projects list's size sort, written without moving the revision). What
  re-sent every manifest was the phones' filing into the "iPhone" library:
  filing wipes the sync records, and the check then re-pushed every in-step
  project to "send its poster" — each push replays the manifest, which by then
  carried a size the server's copy lacked. The build installed at 14:35 CEST
  notes the posters PicPlace already holds with one batched read
  (`POST /projects/assets`, kind `preview`) and pushes nothing; the stream
  stopped (the 16 Pro's checks since read 0 queued).
- **"If that size describes this device's copy, it doesn't belong in
  project.json."** Agreed — it does, so it no longer travels: the app strips
  both keys from what it sends, and a pull keeps each device's own
  measurement. No presence field is needed for now; it is the right place if
  the web ever shows a size per device.
- **"0.1.0 (1) doesn't tell me the build."** The app now reports the build
  time too — `0.1.0 (1) 2026-09-24 13:31 UTC` — and re-registers the device
  (the same upsert as sign-in) whenever that changes.
- **Downloads and the overwrite rule:** a Download no longer puts PicPlace's
  copy over a local file that differs from it (unless the person chose
  Replace) — with the rule on, a newer local file PicPlace refused is the
  expected state, and must not be reverted by a download.
- **Originals on one phone only:** expected — *Upload originals
  automatically* is off, so a new project's originals go up when Steven
  presses Upload (per project, or Settings ▸ PicPlace ▸ Upload).

## Already fine: no ask

- **Presence downgrade.** After removing originals the app posts
  `POST /projects/{uuid}/presence {"revision": n, "tier": "preview"}`.
  `PresenceController::store` is `updateOrCreate` per device, so the tier
  replaces `original`. Nothing to build.
- **Nothing else changes on the server.** No manifest `PUT`, no revision
  bump, no asset deletion, no tombstone. Removing files from a device is not
  deleting a project.
