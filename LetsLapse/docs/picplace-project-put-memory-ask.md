# PicPlace: the project PUT runs out of memory on a big timelapse — the ask

**Raised:** 2026-10-10 (Steven) · **App side:** no change. The app sends what
`/status` says it may (`records_max_bytes`), and a 413 `records_too_large`
already makes it send the records in the bundle instead · **Read with:** in the
picplace repo, `ProjectController::upsert`/`upsertOne`, `ManifestStore`,
`ProjectIndexer::readRecords`/`syncAssets`. **Shareable copy:**
https://claude.ai/artifact/9rW2Be4bT7Yj6rLognrTNj (private until shared;
republish it whenever this file changes — this file is the source of truth).

**Answered 2026-10-10, the same day:** all six points built and live on
picplace.co (picplace `5807481`, deployed with `ad4d2ec`; the cap reads 8 MB
again). The server's write-up is `docs/letslapse-put-memory.md` in the picplace
repo: 15.9 MB above baseline for a 4,035-frame PUT, 46.3 MB at the 8 MB cap,
records over 1 MB folded into the index by a queued job. It also found a cause
the replay below could not see: the framework decoded every JSON body into an
input bag before the handler ran. Checked from here the same afternoon: no
error in `laravel.log` after 09:14:23 UTC. **Correction to §2:** the project's
index was not left stale. A later attempt folded its records at 09:14:57 UTC
(4,035 index rows).

**The ask in one line:** a `PUT /projects/{uuid}` carrying 2.7 MB of inline
records (a 4,035-frame timelapse) exhausts PHP's 128 MB on picplace.co. Please
make the handler use memory in proportion to what it receives rather than
raising the limit.

---

## 1. What we are trying to do

An upload from LetsLapse starts with one `PUT /projects/{uuid}`. It carries the
project document (`manifest`) and, since sync-cost §B, the project's records
inline: `records.metadata` and `records.assets`, one record per frame (camera,
exposure, GPS, SHA-256). The photo and video files then go **straight to object
storage** on presigned URLs. Their bytes never pass through PHP. That part
works: on 10 Oct a 953 MB video upload from the same phone went through without
trouble.

A project with thousands of frames is the normal case for LetsLapse, not an
edge case. Interval shoots are what the app is for.

## 2. What fails

Project **"Stack 21. 9. at 19:49"**, `ec94b80b-d5b3-49d4-9e18-3c9fca803333`,
account `regularsteven` (user 2). It has 4,035 DNG frames, about 43 GB.

- Every upload of its originals fails on the first request:
  `PUT projects/ec94b80b-…` → **500 "Server Error"**. The app retries 3 times
  per attempt and backs off (10 s, 30 s, 2 min, 10 min) between attempts.
- The body is 2.85 MB: a 135 KB manifest plus records of 2.7 MB (4,035 asset
  records). `/status` advertises `records_max_bytes` = 8 MB.
- `storage/logs/laravel.log` on picplace.co holds **38** of these, the first at
  2026-10-07 13:55:57 UTC and the latest at 2026-10-10 09:14:23 UTC:

  ```
  production.ERROR: Allowed memory size of 134217728 bytes exhausted (tried to allocate 2697448 bytes)
  … at vendor/laravel/framework/src/Illuminate/Database/Connection.php:409
  ```

  Two of them die later, at `app/Services/LetsLapse/ProjectIndexer.php:310`
  (2026-10-07 14:10:00 and 2026-10-10 09:14:23 UTC).
- Production: PHP 8.3.22, Laravel 12.18.0, `memory_limit = 128M`, an 8 GB box,
  `pm.max_children = 16`.

**A side effect that sticks.** At 09:14:23 UTC one attempt committed the
manifest and the records and then died inside `$this->indexer->index()`. The
next PUT carried the same bytes, took the "nothing changed" shortcut and
returned 200. As a result, the project's index rows are from before, and
nothing rebuilds them until the records change. When they do change, the PUT
runs out of memory again.

## 3. Steven's sniff test

> This to me feels like a simple transfer of data and I don't know what is
> eating the memory. For example (a dramatic example), if a user wants to
> upload a multiple gigabyte file, this should not require multiple gigabytes
> in RAM to manage this. Is updating 128 MB to 512 MB a sustainable fix? This
> just doesn't smell right.

He's right. The gigabytes never touch PHP. What does touch PHP is 2.7 MB of
text, and the handler needs about **40 times** that.

## 4. Where the memory goes (measured)

These figures come from a replay of the handler's steps on the real payload. It
ran on a Mac with PHP 8.4 and Laravel 12.18, against the picplace code at
`acae01a` (the version deployed), with no database. Each line is memory still
held after that step, above the framework's own baseline.

| Step in the PUT | Held | Added |
|---|---|---|
| Laravel decodes the body to arrays (`$request->validate()` reads `all()`) | 14.7 MB | +14.7 |
| `$request->validate($this->upsertRules(''))`: **peaks at +99 MB while it runs**, then keeps the validated copy | 29.0 MB | +14.4 |
| `decodedBody()` decodes the same body again, as objects | 33.3 MB | +15.6 |
| `encode()` / `encodeRecords()` re-encode the manifest and records | 36.0 MB | +2.7 |
| The stored records are read back (`recordsRaw()` for the no-op test, then the select inside `updateOrCreate()`) | 41.3 MB | +5.3 |
| The UPDATE binds the 2.7 MB value | 43.8 MB | +2.6 |
| The indexer reads the records back from the database and decodes them again | 60.9 MB | +17.1 |
| The indexer builds 4,035 index rows | 77.2 MB | +16.3 |
| **Peak** | **114 MB** above baseline, which puts the request over 128 MB | |

The validation step on its own, broken down (peak above the decoded data):

| Rules | Peak | Time |
|---|---|---|
| No wildcard rules (records only as one `array`) | +75 MB | 0.14 s |
| plus `records.assets.*` → `array` | +75 MB | 0.38 s |
| plus `records.assets.*.name` → `required,string,max:255` | +86 MB | 0.30 s |
| Both wildcard rules (what the PUT runs) | **+98 MB** | 0.80 s |

Most of the cost comes from passing 2.7 MB of records through Laravel's request
validator at all. The validator rebuilds the whole data tree more than once,
and the two per-record wildcard rules add about 23 MB and most of the time on
top. The fatal error then lands on the next large allocation, which is the
2.7 MB stored copy read back (`tried to allocate 2697448 bytes`).

## 5. Why 512 MB is not the fix

- **Memory grows with frame count.** At the advertised 8 MB cap (around 12,000
  frames, an ordinary night-long timelapse) the same handler would need about
  330 MB.
- **The limit applies to each PHP worker.** 16 workers at 512 MB is 8 GB,
  which is the whole box. Two or three devices pushing big projects at once
  could take the server down, where today one request fails.
- **Much more of this is coming.** Steven plans to migrate hundreds of
  thousands of photos (several TB) through PicPlace, and every big project goes
  through this request.

## 6. The ask

1. **Keep the records out of Laravel's request validation.** Validate the
   small fields (name, type, revision, captured_at, bucket, library, resurrect)
   with the validator. Check `records` in one plain loop over the objects
   `decodedBody()` already has (a list of objects, each with a string `name` of
   at most 255 characters), or store them as opaque bytes.
2. **Decode the body once.** Today it is decoded to arrays for `validate()` and
   then again to objects for `decodedBody()`.
3. **Compare by hash, not by reading the stored copy back.** For the no-op
   test, select only `records_sha256` and `manifest_sha256`. Write the manifest
   row without `updateOrCreate()` selecting the whole row (body plus 2.7 MB of
   records) first.
4. **Don't decode the records a second time to index them.** Index from what
   the request already holds, or in a queued job. Today the request reads them
   back from the database and decodes them again.
5. **Don't let a crash between the commit and the index stick.** The no-op
   shortcut should still re-index when the index row's records hash differs
   from `records_sha256`, or `letslapse:reindex` should catch it.
   `ec94b80b-d5b3-49d4-9e18-3c9fca803333` needs a reindex now.
6. **Make `records_max_bytes` a promise the server keeps.** Once the handler is
   lean, test a PUT at the cap. If it cannot pass under 128 MB, lower the cap.
   The app acts on a 413 `records_too_large` (it sends the records in the
   bundle instead). A 500 only gets retried.

**Done when:**

- This project's PUT peaks well under 32 MB above the framework's baseline.
  Leaner code should land at a small multiple of the 2.7 MB received.
- A synthetic PUT at the 8 MB cap passes with `memory_limit` still at 128M.
- `ec94b80b-…` is reindexed.
- Steven presses Resume on the phone and the DNGs start going up.

## 7. Reproducing it

Any `assets.ndjson` of about 4,000 lines reproduces it. Steven can share the
real one (it carries GPS). This measures the validation step alone, via
`php artisan tinker --execute="require 'validator.php';" < /dev/null`:

```php
<?php
$assets = array_map(fn ($l) => json_decode($l, true), explode("\n", trim(file_get_contents(getenv('NDJSON')))));
$data = ['name' => 'x', 'type' => 'interval', 'revision' => 1, 'manifest' => ['capture' => []],
    'records' => ['metadata' => [], 'assets' => $assets]];
$before = memory_get_usage(); memory_reset_peak_usage();
validator($data, ['name' => ['required', 'string', 'max:255'], 'manifest' => ['present', 'array'],
    'records' => ['sometimes', 'nullable', 'array'], 'records.assets' => ['sometimes', 'array'],
    'records.assets.*' => ['array'], 'records.assets.*.name' => ['required', 'string', 'max:255']])->validate();
printf("validate() peak: +%.1f MB\n", (memory_get_peak_usage() - $before) / 1048576);
```
