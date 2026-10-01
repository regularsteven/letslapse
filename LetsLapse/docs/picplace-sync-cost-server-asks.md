# PicPlace × LetsLapse — server asks for sync cost

**From:** the LetsLapse app (`ios-app` branch) · **Date:** 2026-10-01 ·
**For:** the PicPlace developer · **Answer, when there is one:** beside the
others in the picplace repo's `docs/` (e.g. `letslapse-sync-cost.md`).

The server work in this document is the PicPlace developer's to scope, build
and deploy. The app side is listed only so each ask says what the app will do
with it.

## Why these asks

Steven plans to move hundreds of thousands of photos, several terabytes, to
Hetzner through PicPlace. Sync is correct today. What it costs was measured
over two days on `picplace.test` with Garage, and several costs that are
invisible at one photo become the migration's clock at that size. Nothing
here changes what a person sees.

The evidence, all in the letslapse repo under `LetsLapse/docs/fieldtests/`:

- `2026-09-30-synth-photo-sync.md` — one photo traced end to end.
- `2026-10-01-sync-cost-bench/` — 14 photos and 101 archives, Mac → Simulator → Mac.
- `2026-10-01-two-library-bench/` and `…-after-fix/` — two libraries on one account.
- `2026-10-01-sync-cost-bench-after-jobs/` — the same after the app's own fixes.

Every request in those reports is named by the app's own trace
(`LL_PICPLACE_TRACE=1`), and the bench that produced them is
`LetsLapse/tools/sync-cost-bench/` (its README says how to run it against
`picplace.test`). It is the before/after for every ask below.

### What was measured (account `regularsteven` on picplace.test, 1,405 projects, read-only)

| Measure | Today | At 300,000 projects (linear) |
|---|---|---|
| `GET /projects` (whole account), response | 1,443,833 B JSON; 102,796 B gzipped | about 310 MB; about 22 MB gzipped |
| …time to build | 167 ms, 5 queries | about 36 s |
| …PHP memory | about 15 KB per project over a ~37 MB baseline | fails at 128 MB near 6,000 projects, at 512 MB near 30,000 |
| `GET /status` | 12 queries, 72 ms; its sums run over every asset row | grows with the account |
| One index row | about 1 KB, most of it `presence[]` (one entry per device) | — |
| `manifest_written` ledger rows | 239 for 115 new projects (bench) | two storage writes per project |

### What the app has already done (committed 2026-10-01)

So the asks are read against the current client, not the one in the first
report:

- An idle check is **2 requests** (`GET /status`, `GET /projects?include_deleted=1`), was 5.
- A pull is **3 API requests** per project (`GET /projects/{u}`, one
  `POST …/assets/urls` for both objects, `POST …/presence`), was 4.
- An iOS launch runs one check, not two.
- A device on one library no longer reads the other libraries' rows as its
  own (a launch race in the app; the server's filing was right throughout).

A new project still costs about **14 API requests** (two push cycles: records
and poster, then originals), and the app paces itself at 255 requests a
minute under the 300 limit. On localhost, 101 small projects took 7 minutes
for 87 MB: the request budget was the clock, not the bytes.

---

## Ask 1: gzip `application/json` on picplace.co

**Today.** picplace.co compresses HTML but not API responses; picplace.test
(Valet) compresses both, so the local bench hides it. Probe, no auth needed
(nginx never gzips a 401, so ask for a 404):

    curl -s -o /dev/null -D- -H 'Accept-Encoding: gzip' -H 'Accept: application/json' \
      https://picplace.co/api/letslapse/v1/zzz-not-a-route | grep -i content-encoding

**Ask.** Add `application/json` to nginx's `gzip_types` (with `gzip_vary on`
and a sensible `gzip_min_length`). The index compresses 14×. HTTP/2 on the
same server block is welcome but optional.

**Done when** the probe above prints `content-encoding: gzip`. No app change:
`URLSession` already asks for it.

## Ask 2: a storage failure is `503`, not `500`

**Today.** When the object store does not answer (Garage down on
2026-09-30), `PUT /projects/{uuid}` fails with a `500` whose body is 18 KB of
debug output including the internal storage URL (`APP_DEBUG=true` locally,
but the status is the same anywhere). The app retries each request four
times and then backs off **per project**: 100 queued projects are 100
separate failures on 100 schedules.

**Ask.** Wherever a request needs the object store (upsert's manifest write,
negotiate's copy, confirm's HEAD, URL minting if it touches storage) and the
store fails, answer:

    HTTP 503
    Retry-After: <seconds>
    {"error": "storage_unavailable", "message": "…"}

with nothing half-written (that part already holds: no project row was kept).

**The app will** treat that code like its existing "PicPlace can't be
reached" gate: hold the whole queue once, show one next-try time, and ask
again after `Retry-After`. That client change is not built yet and waits on
the error code's name — say if you prefer another.

## Ask 3: `/status` totals without summing the account each time

**Today.** `StatusController` runs about 12 queries per call; `used_bytes`,
`deleted_bytes` and the library totals sum over every confirmed asset of the
account. Every check of every device calls it once (it was four times until
today), and the app's Settings card calls it when it appears.

**Ask.** Your choice of mechanism: a short per-user cache (30 to 60 s,
dropped on confirm, PUT and delete), or counters kept as assets confirm and
projects are deleted. Also worth a look on the same pass:
`throttle:letslapse` reads and writes the `cache` table on every request when
`CACHE_STORE=database`.

**Done when** an unchanged account's second `/status` within the window runs
no asset aggregate. The app needs nothing: a figure up to a minute stale is
fine for the card.

## Ask 4: no manifest write when the manifest has not changed

**Today.** `ProjectController::upsert` writes the manifest object to storage,
adds a `manifest_written` ledger row and re-runs the indexer on every PUT,
changed or not. A new project's second push cycle (originals) PUTs the same
document at the same revision: 239 writes for 115 projects in the bench, and
`delta 0` rows in the ledger.

**Ask.** Keep a hash of the stored manifest bytes on the project row; on a
PUT whose encoded manifest hashes the same at the same revision, skip the
storage write, the ledger row and the re-index, and answer as now.

**The app** intends to send a new project in one cycle later, which removes
the duplicate PUT at its source, but that change touches its free-up-space
bookkeeping and is not scheduled. This ask is worth having either way: a
replayed PUT is by contract safe to repeat, and should also be cheap.

## Ask 5: the request limit during a migration

**Today.** 300 requests a minute per device, 1,000 per account
(`config/letslapse.php`). At 14 requests per new photo that is about 18
photos a minute per device: 300,000 photos is 11 days of API time before a
byte of bandwidth is counted.

**Ask.** Your judgement on what the server can take. The suggestion is a
higher per-device figure for the migrating device **after** asks 3 and 4 and
the index work below, since `/status` and the whole-account index are the
only requests whose cost grows with the account; what is left is single-row
work plus storage HEADs. The app reads the limit from `/status` and honours
`429` with `Retry-After`, so the limiter stays the safety valve and nothing
needs coordinating: raise it, watch php-fpm and MySQL, lower it afterwards.
Steven's condition is no timeouts and no overload.

---

## To design together before the migration (not jobs yet)

These decide the shape of the API, so they are questions for you, with the
app's evidence and a proposal. Nothing should be built from this section
without an answer in your doc.

### A. The index read does not survive scale

`GET /projects?include_deleted=1` returns every row of the account, built in
memory, to every device on every check (every 3 minutes in front). It is the
request that fails first: see the memory row in the table above. Paging
alone stops the crash but not the cost, because each device would still
download and merge the whole account every check.

The app reads the whole account on purpose today: a row filed in another
library is how a device learns a project it holds has moved. So "ask for
only my library" is a change to the app's merge, not a free switch — but the
two-library runs showed the stronger rule we want anyway: **a device should
not be able to read rows outside its library by default.**

Proposal, in two steps:

1. **A change token per library in `/status`**: a cheap value that moves
   whenever that library's index answer would differ (count including
   tombstones, newest `updated_at`, newest `library_changed_at`, confirmed
   asset count and bytes, newest presence). A device whose token matches and
   has nothing queued skips the index. The merge is untouched.
2. **A scoped, paged pass**: rows by library, bucketed by capture month with
   a count and token per bucket, cursor pages within a bucket; a row that
   left the library since the device's watermark is reported as a departure
   (the scoped `updated_since` pass already does this). A device then fetches
   only the months that moved, and a full pass never holds the account in one
   response.

`features.change_feed` is `false` today and was agreed "to scope together"
(sync v2, item 17). A per-library sequence number and `GET /changes?since=`
would replace both steps. If you would rather build that than the token and
buckets, say so: the app's only requirement is that the cost of "nothing
changed" is one small request, and that scope is per library.

Also: `presence[]` is most of each row. The check needs this device's entry
and which devices hold originals; a slimmer row helps every option.

### B. Records as rows, not as two small objects per project

Each project keeps a manifest object and a `records.aar` object in storage.
Both are a few hundred bytes to a few kilobytes. Consequences measured:

- `GET /projects/{uuid}` reads the manifest from storage on every call, and
  the app calls it for every pull and every "are the originals there?" check.
- The server cannot read `records.aar`, so the index has no name, caption,
  camera or GPS (`records_indexed_at` is NULL on every row; the web shows
  none of them).
- One changed field re-sends the bundle and the other device re-fetches it.
- Hetzner bills each object at a 64 KB minimum.

Proposal for discussion: project records in the database, read and written
through the API in batches, with object storage for the bytes that are
actually large (originals, blends, posters). This is a change of contract on
both sides and wants a design round, not an ask.

### C. Verification by read-back on Hetzner

Hetzner signs but does not check `x-amz-checksum-sha256`, so
`letslapse:verify-assets` reads every object back, single process. For
several terabytes that is every byte through the app server once, and until
it catches up the app polls each uploaded project (`GET /projects/{uuid}`, up
to 43 times over 30 minutes — the app will batch that through
`POST /projects/assets`, its job). Worth a ten-minute probe: does Hetzner
refuse a PUT whose `Content-MD5` is wrong? If it does, signing `Content-MD5`
into the upload URL would let confirm verify from the ETag, and the read-back
becomes a backstop. Untested; it may not hold.

### D. Known, parked

- **Multipart uploads** (`features.multipart: false`, 5 GB per object, a
  failed upload restarts from zero). Not blocking photos; needed before
  ProRes shoots.
- **Confirm's one storage HEAD per file, in sequence**, inside one request.
  The largest project today has 522 files.
- **Bulk create and negotiate** (many projects per request): the real fix for
  14 requests per photo, and it depends on B.
- **Web**: a new signed poster URL on every view with `no-store`, so the
  browser never caches; `bytes_out` counted when a URL is issued rather than
  when bytes move; the overview's uncached aggregates. Worth doing, unrelated
  to the migration.

---

## Two things seen on the way, for your judgement

- **A tombstone and a re-import disagree by timing.** A `.lapse` archive
  carrying the id of a project deleted that morning was imported on two
  devices. Where the check ran first the import went to the trash ("deleted
  on PicPlace"); where the push ran first the PUT resurrected the tombstone
  (`project_restored`). Both are the documented behaviour of their own
  request. Which outcome is wanted is Steven's decision; it is listed here
  because the server's resurrection rule is half of it.
- **Local environment.** No queue worker and no scheduler run on
  picplace.test, so `verify-assets`, `reap-uploads` and `purge-tombstones`
  never fire there (172 stale upload rows, 7 pending purge jobs on
  2026-09-30). The bench's numbers do not depend on them, but anything about
  verification or reaping cannot be seen locally. Garage's health is only
  visible to an HTTP request (`curl` → `403`); a TCP probe passes while
  Docker's forwarder breaks the pipe.

## What the app needs back

1. Asks 1 to 4: done, declined, or changed — and the error code's final name
   for ask 2.
2. Ask 5: the figure you are comfortable with, and when.
3. Section A: token and buckets, or the change feed — and the shape, so the
   app's side can be written against it.
4. Sections B and C: whether you want to take them up, and in what order.
