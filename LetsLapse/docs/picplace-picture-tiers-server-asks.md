# PicPlace × LetsLapse — server asks for picture tiers (tile · poster · proxy)

**From:** the LetsLapse app (`ios-app` branch) · **Date:** 2026-10-03 ·
**For:** the PicPlace developer · **Answer, when there is one:** beside the
others in the picplace repo's `docs/` (e.g. `letslapse-picture-tiers.md`) ·
**Order:** these asks come first. The app's own plan is
[picture-tiers-plan.md](picture-tiers-plan.md); its local stages start now,
its sync stages wait on asks 1–3 and run slowly without them (see "Without
the ask" under each).

The server work in this document is the PicPlace developer's to scope, build
and deploy. The app side is listed only so each ask says what the app will do
with it.

## Why these asks

Steven's brief, 2026-10-03, in three parts:

1. **A working file without the originals.** A person grades a photo on the
   device that shot it. Another day, on another device, they want to add text,
   draw masks, mark shapes for a Shape-mation, or crop — and none of that
   needs the 60 MB DNG. Today the app's editor refuses every page but ⓘ on a
   device without the originals, because the only rendition PicPlace holds is
   a 1280 px poster. The fix is a full-size rendition of the graded picture,
   made by the device that holds the originals, kept on PicPlace: the
   **proxy**. PicPlace already defines the asset kind `proxy` and the presence
   tier `proxy` ("a reduced working copy"); the app has never used either.
   The proxy is also the picture the platform will lean on later, when a
   person promotes a photo for use across PicPlace without a LetsLapse client
   in the loop (§D).
2. **A gallery of 100,000 projects.** The poster is the right picture for
   "open this and show a friend" and the wrong one for a grid: a device that
   holds only previews cuts its grid tiles from 1280 px JPEGs it had to pull
   one by one. A **tile** tier (about 400 px, ~15–25 KB) is what a grid
   needs, it has to arrive in batches rather than one request per project,
   and — Steven's call, after a first draft of this document argued
   otherwise — **the server makes it**, from the poster it already holds.
3. **Everything else stays.** The poster stays as it is (`preview/poster.jpg`,
   JPEG, the web view's picture). Originals stay the only thing that can be
   regraded or blended.

The tiers:

| Tier | Pixels | Object | Made by | Pulled | For |
|---|---|---|---|---|---|
| tile | ~400 px long edge | `preview/tile.<ext>` | **the server**, from the poster | eagerly, in batches — it *is* the gallery | grids, lists, pickers |
| poster | 1280 px | `preview/poster.jpg` (unchanged) | the client, as today | on open, with look-ahead | hero, pager, the web view, the tile's source |
| proxy | the source's own pixel size | `proxy/picture-<token>.heic` | the client that holds the originals | on demand, when a page or job needs working pixels | text, masks, shapes, crop, Shape-mation, collection stills; later the platform's own renditions |
| originals | — | `source/…`, `blend/…` (unchanged) | — | on demand | regrading, new blends, frames, archives |

### Who makes which tier, and why

The sync v2 policy says *PicPlace never processes LetsLapse bytes*. It was
written when the integration was a registry with a poster; Steven is
loosening it, deliberately, for renditions. The split and the reasons:

- **The proxy is the client's and cannot be anything else.** It is the
  grading engine's output: a raw decode with the engine's base look, the
  preset, the sliders, keyframes, white, level. No server library reproduces
  that, and the policy that the server never *regrades* stands.
- **The poster stays the client's, for now.** It is the first picture: it
  rides the records push in the first sync cycle on any network, 300 KB,
  raw-correct, already built, and the web view's picture. The server could
  one day replace it with a larger "open" rendition cut from the proxy (the
  2048 px the iPad and Mac would like); that is the platform's call and
  nothing in the app depends on who made the poster.
- **The tile is the server's, cut from the poster.** This reversed the first
  draft, which had the client make tiles, on an argument that assumed tiles
  derive from the proxy (then an unedited JPEG, which has no proxy, had
  nothing to derive from). Cut from the poster, the gap is gone: the poster
  arrives with the records, so the tile exists seconds after, for every
  project, on every network. What the server gains by owning it:
  - **the holder uploads nothing extra** — the first draft's two small objects
    per project are gone, and so is the holder's render work for them;
  - **a spec change is a server job, not a fleet re-upload** — a different
    tile size, a second size, a new format, a bundle per bucket (§B) are
    re-derived from posters the server already holds, where client-made tiles
    would have needed every holder of originals, including phones that are
    rarely on a charger, to render and push 100,000 objects again;
  - **it seeds the platform's pipeline** — the same queue job, pointed at the
    proxy or the original with a HEIC-capable library (§D), is how PicPlace
    will make web renditions for blogging without a LetsLapse client;
  - **the tooling exists**: a database queue with jobs runs in production, and
    GD 2.3.3 on the server reads JPEG and writes JPEG, WebP and AVIF. GD is
    not colour-managed — it reads a Display P3 poster as sRGB, so a raw
    project's tile is a little less saturated than its poster — which is
    acceptable for a grid tile (Steven: a tile need not be a strict colour
    representation) and goes away when the pipeline moves to libvips or
    Imagick for §D.

What the server still does not do: decode a DNG, apply a grade, or make the
poster. And no device downloads a tier it does not need — the Mac and the
iPad pull tiles for the grid, a poster when a project is opened, a proxy
when a page needs working pixels, the originals when they regrade or blend.
Only the holder of the originals ever uploads.

**Where the renditions live:** in object storage, as assets of their project,
under the same keys as everything else
(`u/{user}/p/{project}/{kind}/{asset_uuid}.{ext}`): Garage on the bench,
Hetzner in production. Not on the application server's disk. The tile job
reads the poster from the bucket and writes the tile back to it; one
presigned path, one ledger (`used_bytes`), one verifier, one reaper, and
bytes pass through PHP only inside that job. The application server's disk
is a single machine, backed up on its own terms, and serving 100,000 small
files through it is exactly the traffic the architecture avoids; when single
GETs measure too slow the answer is a bundle per bucket (§B), not a web
server in front of a folder.

### What this costs on a shoot (Steven's example: 20 HEIC photos with a preset)

| | Per photo | 20 photos |
|---|---|---|
| the holder uploads: original (HEIC) + poster + proxy (the preset makes one) | ~4 MB + 0.3 MB + ~4–5 MB | ~180 MB, originals and proxy under the Wi-Fi rule, the poster at once |
| the holder uploads with **no** preset | ~4 MB + 0.3 MB; no proxy | ~86 MB |
| the server makes | one tile, ~20 KB | 20 tiles, a few seconds of queue |
| the Mac pulls for its gallery | one tile | ~0.4 MB |
| the Mac pulls to open one | the poster | 0.3 MB each opened |
| the Mac pulls to add text to one | the proxy | ~4–5 MB each worked on; the original never |
| the iPad | the same, by what it opens | — |

### What was measured

Steven's Mac library, 2026-10-03, 1,582 projects with a poster; pull figures
from the sync-cost report (`picplace-sync-cost-server-asks.md`):

| Measure | Today | At 100,000 projects (linear) |
|---|---|---|
| `poster.jpg` bytes | median 317 KB · p90 457 KB · max 4.0 MB · mean 372 KB | about 37 GB to hold a gallery |
| Pull of one project | 3 API requests (`GET /projects/{u}`, `POST …/assets/urls`, `POST …/presence`) + 2 storage GETs | 300,000 API requests |
| First pull, 695 previews (2026-09-18) | 21.5 min, paced at 255 requests/min | about 2 days |
| Local 480 px grid tile (JPEG, on a device with originals) | median 55 KB | — |
| Tile tier (server-made, to be measured) | ~400 px, JPEG about 20–25 KB, WebP about 12–15 KB | about 1.5–2.5 GB |
| Proxy (estimate, raw or edited sources only) | 48 MP HEIC at quality 0.85, about 6–10 MB; 12 MP about 2 MB | 0 for an unedited JPEG or HEIC |
| Tile job, from a 317 KB poster with GD | tens of milliseconds | a few hours of one core, once |

The request count, not the bytes, is the clock at 100,000 — the same finding
as the sync-cost report. Asks 2 and 3 are about requests per project.

## What the app will send

So the objects are recognisable when they appear:

| Object | `kind` | `content_type` | Size | Made | Replaced |
|---|---|---|---|---|---|
| `preview/poster.jpg` | `preview` | `image/jpeg` | 1280 px, JPEG 0.7 | as today, with every records push whose grade moved | as today |
| `proxy/picture-<token>.heic` | `proxy` | `image/heic` | source pixel size, HEIC q≈0.85, Display P3 (raw) or sRGB (sRGB sources) | on a settled grade edit (the 20 s debounce) and by a background sweep for projects without one | a new token is a new name; the previous object is deleted (ask 2 `replaces`) |

- **`<token>`** is 12 hex characters of SHA-256 over the grade recipe that
  decides the proxy's pixels — preset, colour adjustments, white, keyframes,
  level, render variant, engine version — **without the crop**. Crop stays a
  record applied on display, so a crop never re-renders a proxy. A device
  computes the expected token from the records it holds and compares it
  with the name it sees: equal is fresh, different is stale. No server field
  is needed for freshness; it rides in the name.
- **One proxy per project**, the project's representative picture (a Photo
  capture's stack blend when it has one; an interval shoot's poster frame;
  a video project has none yet — §C).
- **Orientation** is not baked. The proxy is stored as the source is stored
  and the quarter turns stay a record, as they are for sources since
  2026-09-24. Rotate 90° never re-renders a proxy.
- **Nothing drawn on it.** No text, masks, shapes or crop: those are records,
  composited on display by the client. That is what makes it a working file.
- **Exemption.** No proxy is uploaded for a display-referred source (JPEG,
  HEIC, PNG, a stack blend) whose grade is the identity for the proxy's
  recipe. A proxy appears when such a project is first edited and is deleted
  when the grade returns to the identity.

Two devices that both hold a project's originals may both render its
proxy. They render the same recipe from the same bytes; last write wins is
correct, and account-wide dedupe already makes an identical object free.

---

## Ask 1: the server makes the tile from the poster

**The architecture change.** Everything below refines it.

**Today.** The only rendition is the poster. A device without the originals
cuts a 480 px grid tile from the 1280 px poster it pulled — one request and
~320 KB per project to draw a grid.

**Ask.** When a `preview/poster.jpg` confirms (first upload or replacement),
a queued job reads it from the bucket, resizes it to **400 px on the long
edge**, writes `preview/tile.<ext>` back as a confirmed asset of the same
project (kind `preview`, `uploaded_by_device_id` null or a server marker),
and records it on the index row (ask 3). Format is yours: WebP at about 0.75
is the smallest GD writes (about 12–15 KB); JPEG at 0.7 is about 20–25 KB;
AVIF is smaller still but slow to encode. The app decodes all three natively
and reads the content type, so the choice can change later without an app
release. One tile per project; a replaced poster replaces the tile. A tile
whose poster is gone (a tombstone's purge) goes with it.

Backfill: one pass over every project that has a poster and no tile, paced
by the queue — 1,582 on Steven's Mac library today; a few hours of one core
at 100,000.

**Done when** every project with a confirmed poster has a tile within a
minute of the poster confirming, and the backfill has run on picplace.test.
`features.tiles: true` in `/status` tells the app to expect them.

**App side.** The pull writes the tile beside the poster; the Gallery grid of
a device without the picture draws from it; the poster is pulled only on
open (ask 3 makes that cheap). Nothing is pushed for tiles, ever. A device
without a tile yet (the minute after a push, or a server without the
feature) keeps cutting from the poster, as today.

**Without the ask.** The app keeps cutting tiles from posters and pulls
every poster eagerly — today's 37 GB and 2 days at 100,000.

## Ask 2: rendition batches across projects, without the claim

**Today.** Every write is per project and under the write claim:
`POST /projects/{uuid}/claim`, `POST /projects/{uuid}/assets`, a presigned
PUT, `POST /projects/{uuid}/assets/confirm`, `DELETE /projects/{uuid}/claim` —
five API requests for one proxy. Downloads mint per project too
(`POST /projects/{uuid}/assets/urls`, ≤100 ids of *one* project). The
background sweep that gives *existing* raw or edited projects a proxy is the
volume that hurts: 50,000 proxies is 250,000 requests up (about 16 hours at
255/min), and pulling 100,000 tiles is at least 100,000 mints down.

**Ask.** Three endpoints that take renditions of many projects at once, for
`kind` in `preview` and `proxy` only, with no claim:

- `POST /assets` — negotiate up to 100 renditions:
  `{ "assets": [ { "project": "<uuid>", "kind": "proxy", "name": "proxy/picture-3f9a1c0b7e2d.heic",
  "bytes": 6291456, "sha256": "…", "content_type": "image/heic",
  "replaces": "<asset id>|null" }, … ] }`. Same answer shape as the per-project
  negotiate, in request order, each item with its `project`; dedupe by hash as
  today. `replaces` names a confirmed asset of the same project and kind
  (the superseded proxy) to delete when this one confirms.
- `POST /assets/confirm` — confirm up to 100, any projects:
  `{ "assets": [ { "id": "…" }, … ] }`.
- `POST /assets/urls` — presigned GET URLs for up to 100 asset ids of any
  projects in the caller's scope (library when `features.libraries`),
  request order, same item shape as the per-project mint. This is how a
  tiles pass fetches 100 projects' tiles in one API request.

Announce them as `features.rendition_batches: true` in `/status`.

**Why no claim.** The claim protects records and originals from two writers.
A rendition is a pure function of the records and the originals: two devices
that write the same proxy write the same thing, and if an encoder differs by
a byte the later one is as right as the earlier. Records, originals and
blends keep the claim exactly as today; these three endpoints refuse any
other `kind` with `422`.

**Done when** the bench (`LetsLapse/tools/sync-cost-bench/`) pushes 100
proxies in 3 API requests plus 100 storage PUTs, and a device mints the tile
URLs of 100 projects in 1 request. `LL_PICPLACE_TRACE=1` counts them.

**App side.** Settled edits keep today's per-project cycle (the records push
carries the poster and the proxy as more items of the same negotiate — zero
extra requests). The sweep uses the batches; the first connection and every
check pull tiles through `POST /assets/urls` in pages of 100.

**Without the ask.** The sweep and the tiles pass fall back to per-project
cycles: correct, and about 100× the requests. The app ships the fallback so
nothing waits, but a 100,000-project library is not usable without this ask.

## Ask 3: rendition pointers on the index row

**Today.** To learn whether a project has a tile, a poster or a fresh proxy
on PicPlace, a device lists assets — `POST /projects/assets` with `kinds`,
100 projects per request — then mints URLs. Two passes over the account.

**Ask.** Each index row (in `GET /projects`, `GET /projects/{uuid}`, and in
the scoped and bucketed passes of sync-cost §A when they land) carries its
confirmed renditions:

```json
"renditions": {
  "tile":   { "id": "…", "sha256": "…", "bytes": 18211, "content_type": "image/webp" },
  "poster": { "id": "…", "sha256": "…", "bytes": 317518 },
  "proxy":  { "id": "…", "name": "proxy/picture-3f9a1c0b7e2d.heic", "sha256": "…", "bytes": 6291456 }
}
```

`null` for a tier the project does not have; only confirmed assets. The
proxy's `name` carries the token (above), so freshness is decided from the
row. The row grows by about 300 bytes; sync-cost §A's slimmer `presence[]`
pays for it several times.

**Done when** a tiles pass over a library needs no `POST /projects/assets`:
rows → `POST /assets/urls` → storage GETs.

**App side.** The holdings pill, the Gallery's PicPlace filters and the
editor's fetch prompt read the pointers (the prompt says "Download the
working copy · 6 MB" from `proxy.bytes`). The `settlePosters` listing pass
retires.

## Ask 4: formats and replaceability

Three confirmations, probably no code:

1. **`image/heic` is stored and served as given.** The API doc says objects
   are served with their stored `Content-Type`; please confirm nothing
   between negotiate and the presigned GET rewrites or refuses it. The web
   view does not need to render HEIC (§D).
2. **`preview` and `proxy` stay replaceable** whatever `immutable_originals`
   becomes. `immutable_kinds` is `['source', 'blend']` today; the renditions
   must never join it — a device replaces its poster and proxy by design,
   and the server replaces its own tiles.
3. **Deleting a superseded proxy needs no claim** — covered by `replaces` in
   ask 2; if `replaces` is not built, `DELETE /assets/{id}` without the claim
   for `proxy` and `preview` kinds does the same in one more request.

## Ask 5: the `proxy` presence tier

**Today.** The app sends `tier: original` or `tier: preview`. The server and
its docs define a third value, `proxy`, and the app's reader already treats
it as "does not hold the originals".

**Ask.** Confirm the server's own reading of `tier: proxy` — in the devices
list of the web view, in anything that computes "which devices hold the
originals" (free-up-space coverage is decided by confirmed assets, not
presence, so it should be untouched), and in the index row's `presence[]`.
The app will start sending `proxy` for a device that holds the records, the
preview set and a fresh proxy but not the originals. Nothing else should key
on it.

**Done when** you say so.

## Ask 6: renditions in `/status` and the usage report

**Today.** `/status` reports `assets.confirmed` and `bytes` as one figure, and
the usage report groups by kind only in the routes investigation's proposal.

**Ask.** Per library (and account), the rendition bytes apart from the
originals: `assets.renditions: { "objects": n, "bytes": n }` (kinds `preview`
+ `proxy`) beside the existing totals, and the same split in the usage report.
Steven's decision on whether rendition bytes count against the same quota as
originals is his to make; the app needs the number to show "working copies
on PicPlace · 4.2 GB" and to size the free-up-space offers.

**Done when** `/status` carries the field. Sync-cost ask 3 (`/status`
without summing the account) is the place to add it cheaply.

---

## To design together before the app's stage 3

### A. The bucket key

Sync-cost §A buckets the index by capture month. The tiles pass wants the
same buckets, so a device fetches the months that moved and nothing else.
Two ways to agree on the month:

- the server derives it from `captured_at` — but `captured_at` is a UTC
  instant and a photo taken at 23:30 local belongs, to the person, to the
  day they took it;
- **the app sends `bucket: "YYYY-MM"`** (the capture's local month) at create
  and push, and the server indexes on it. *Recommended:* one source of
  truth, no timezone arithmetic on the server, and the app already groups its
  timeline by local day.

Say which, and the app's stage 3 writes to it.

### B. Tile bundles per bucket (the natural follow-up to ask 1)

With asks 2 and 3 a 100,000-project library costs about 1,000 API requests
and 100,000 storage GETs for its tiles. Storage GETs do not count against the
rate limit, but each is a TLS round trip: eight in parallel at about 150 ms
is about 30 minutes for the first pull of a 100,000 library, then incremental.
Because the server now makes the tiles, it can also keep one object per
bucket — the bucket's tiles concatenated with a small index
(`tiles/{bucket}.tar`, or a sprite sheet) — rebuilt by the same queue some
minutes after the bucket last changed, stored as a library-level object (the
namespace the collections ask's `PUT /library` wants anyway). Then a month is
one GET. Not now: measure the per-project path first, with asks 2 and 3 in
place.

### C. Video proxies

A video project's working copy is a web-playable clip (H.264, ≤720p,
`proxy/clip-<token>.mp4`), as the routes investigation already proposed. The
app does not make one yet; when it does, ask 2's endpoints carry it, and the
tile job's source for a video project is its poster frame, as for stills.
Nothing to build now.

### D. The platform's own renditions, and the web view

Steven's direction: adding a photo to PicPlace is so that it can later be
promoted for use across the platform — blogging and the rest — without a
LetsLapse client doing anything. For that the server renders from the
**proxy when there is one, else the original** (never from a DNG: a raw
project always has a proxy): web sizes, sRGB, JPEG or WebP. That is ask 1's
job pointed at a different source with a HEIC-capable, colour-managed library
(libvips with libheif, or Imagick) in place of GD. Nothing in the app depends
on it; it is listed so that ask 1 is built as the first step of it rather
than as a one-off. Meanwhile `preview/poster.jpg` stays the web view's
picture, and the proxy is HEIC, which only Safari renders — whether the web
view shows the proxy to Safari visitors is your call.

---

## For your judgement

- **Dedupe of renditions.** Tiles of different projects never share bytes;
  a proxy of an unedited raw rendered on two devices may. Account-wide
  dedupe already handles the second; the first costs nothing. No ask.
- **Reaping.** A superseded proxy that `replaces` deletes is the only
  rendition garbage from the client; the tile job replaces in place. The
  reaper's pending-upload rule applies as today.
- **Colour.** GD reads a Display P3 poster as sRGB; a raw project's tile is
  slightly less saturated than its poster. Acceptable for a grid by Steven's
  word; it goes away with §D's library. If you would rather start with
  libvips, nothing in the ask changes.
- **Rate limit.** With ask 2 the proxies of 50,000 raw or edited projects are
  about 1,500 API requests up, and the tiles of 100,000 projects about 1,000
  down; the originals' own uploads remain the migration's cost, which
  sync-cost §D (bulk create and negotiate) addresses.

## What the app needs back

1. Ask 1: the tile's size, format and feature flag name; whether the
   backfill runs on picplace.test before picplace.co.
2. Ask 2: built or changed — the three endpoints' final paths, the `replaces`
   decision, and the feature flag's name.
3. Ask 3: the `renditions` field's final shape, and whether it is in the
   whole-account `GET /projects` from the start or only in the scoped
   passes of sync-cost §A.
4. Asks 4–6: confirmed, declined, or changed.
5. §A: who computes the bucket key.
6. Anything in §B–§D you want to take up now rather than later.


---

## Round 2 — the developer's review and the answers (2026-10-03)

The developer checked the document against the code and the production box
(everything verified stands: `proxy` kind and tier, HEIC pass-through,
immutable kinds, GD 2.3.3 + a database queue, ImageMagick with HEIC read on
the box; production holds 1,622 posters, 604 MB, and 39,718 sources, 288 GB)
and asked for two decisions. The reply, as sent:

> **Re: picture tiers — answers to your review (2026-10-03)**
>
> Thanks for checking it against the box. Everything you verified stands as
> written. The three decisions you asked for, then what we accept as you
> proposed, two small additions, and one question back.
>
> **Decisions (Steven, 2026-10-03)**
>
> 1. **The proxy race.** Yes to your rule, on both sides. App: the background
>    sweep pushes a proxy only when the records it holds are at the server's
>    revision (the sync record's revision against the row's; a settle push
>    carries records and proxy together, so it is at revision by
>    construction). Server: refuse a `proxy` negotiate from a device whose
>    presence revision is behind the project's current revision, with
>    `409 revision_stale` and the current `revision` in the body, for every
>    proxy item and not only one carrying `replaces`. A dropped `replaces`
>    would leave two proxies with the device believing it replaced one; a
>    refusal is something the app acts on (pull, re-render). With that in
>    place `renditions.proxy` is simply the latest confirmed proxy.
> 2. **The quota.** Count tiles and proxies in `used_bytes` as every other
>    asset; ask 6 reports `assets.renditions` apart.
> 3. **Backfill order.** picplace.test: any time, it is the bench. picplace.co:
>    after the app build that ignores server-made assets in its asset-count
>    comparison has shipped. Today a preview-only copy re-fetches its records
>    whenever `assets.confirmed` moves (`PicPlaceChangeSync.swift:413`), so a
>    backfill under the current build costs every device holding previews one
>    records fetch per project. We'll tell you when that build is on the
>    devices.
>
> **Accepted as you proposed**
>
> - Names: `poster.jpg` and `tile.webp` under `preview`, `picture-<token>.heic`
>   under `proxy`. The app's plan and local layout now match: all three at the
>   project root beside the poster.
> - `origin: "server"` on the asset shape, and please on the `renditions`
>   pointers too. The app will ignore server-made assets in listings and in
>   the count it compares with what it last saw.
> - WebP at 0.75 from GD; the app reads the content type.
> - Renditions on their own queue name with a paced backfill command; the job
>   takes a source key and a target spec (§D).
> - `bucket` sent by the app as the capture's local `YYYY-MM`, a new indexed
>   column, a changed bucket a departure in the feed, the UTC month as the
>   fallback for rows pushed before the field exists.
> - No HEIC proxy on the web; the poster stays the web picture until §D.
> - Build order: asks 1, 3, 4 and 5, then 2 and 6; ask 3 in the whole-account
>   list from the start.
>
> **Two small additions**
>
> - `derived_from_sha256` on the tile row: the poster's SHA the tile was cut
>   from. A retried confirm hook, a re-run of the backfill or a replaced
>   poster is then decided from the row without reading an object, and it is
>   the same freshness rule the app uses for the tile.
> - `assets.server` on the index row, the count of server-made confirmed
>   assets beside `assets.confirmed`, so the app's count comparison subtracts
>   it rather than inferring from the pointers. Optional: while the tile is
>   the only server-made asset the app can infer it from `renditions.tile`.
>
> **One question back**
>
> - In a batch of 100 at `POST /assets`, is `revision_stale` a per-item error
>   (`{ "project", "error": "revision_stale", "revision" }`) with the rest of
>   the batch processed, as `POST /projects/assets` answers per project? That
>   is what the app would like.
>
> **What the app needs back**
>
> - The feature flag names (`features.tiles`, `features.rendition_batches`),
>   the final `renditions` shape with `origin`, the error code's final name,
>   and the answer document.

**2026-10-03, later — the app's stage 1 ran against picplace.test** (the
contract `letslapse-picture-tiers.md`, `c43f970`): a DNG project's first
push carried `records.aar`, `poster.jpg` and `picture-<token>.heic` in one
negotiate and one confirm; an unedited JPEG pushed no proxy; the sweep
re-negotiated an existing copy by hash with no transfer. One correction to
"What the app will send": the proxy's **orientation is baked** after all —
the render applies the project's quarter turns, so a Rotate 90° re-renders
and re-uploads it (its token carries the turns, as the poster's does).
Nothing on the server side changes. Also seen: `tile.webp` already cut for
the test account's projects — push 1's tile job is live on picplace.test.

**2026-10-03, evening — push 1 is live on picplace.co** (`35c226c`, the
answer doc `1163a35`): `features.renditions` true, `features.tiles` false
until Steven says the stage 0 build is on the devices. The app now logs the
three flags once per change (`picplace: picture tiers on <host> — rendition
pointers on, tiles off, rendition batches off`) and a tally of the pointers
in scope once per change (`picplace: renditions on PicPlace for N row(s) —
posters · tiles · working copies`), so the production probe is one look at
the log. **One gap found on picplace.test (push 1 there): `renditions.proxy`
was `null` for a project whose confirmed `proxy` asset existed** —
`picture-bc5dc70eb66d.heic`, `origin: device`, confirmed, listed under the
project's assets, on a fresh project as on a resurrected one; the poster
pointer on the same row was filled. The developer's answer (below, the
night's entry): a server bug in the newest-proxy lookup, fixed; on
picplace.co with push 2.

**2026-10-03, night — stage 2 ran against picplace.test**, and the
developer confirmed it from the server's side and corrected the gap's
diagnosis. **`renditions.proxy` is computed from the confirmed assets each
time a row is read; it never waits for a worker.** The `null` was a server
bug: the newest-proxy lookup applied the kind filter to the outer query
only, so whenever another asset of the project confirmed after the proxy
(the records and poster of a settle push) the lookup picked that asset and
the filter then dropped it. The fix constrains the lookup itself, a test
covers a proxy pushed before a records file and a poster, and the pointer
is correct the moment the proxy confirms. It appeared filled on the stage 2
retest because the fix was already in picplace.test's working tree; the
queue run beside it was a coincidence. On picplace.co the fix arrives with
push 2. The tile's `derived_from_sha256` equalled the poster's `sha256` and
the app drew its grid from it. **Push 2 is built and tested**, deploying on
Steven's word, and picplace.test has it now for stage 3: `POST /assets`,
`POST /assets/confirm`, `POST /assets/urls`, `stale_revision` per item,
`replaces`, `storage.renditions` and `libraries[].renditions` in `/status`,
and `bucket` with `GET /projects?bucket=`. Two details for stage 3: every
batch negotiate item carries `project` and `name` on errors as well as
successes, and a confirm that retired an old proxy answers with
`replaced: { id, name }`. On picplace.test the queue listener runs on both
queues whenever `composer dev` is up; without it,
`php artisan letslapse:render-tiles --now` cuts tiles inline.

**2026-10-03, late — push 2 is live on picplace.co** (`96cc072`; the
answer doc `167e76e`; every row carries its fallback `bucket`; the proxy
pointer fix with it) **and the app's stage 3 ran against picplace.test**:
ten stale working copies PicPlace already held went through one `POST
assets` with `replaces` retiring the old copies; ten it lacked went up in
three API requests (negotiate, ten PUTs, confirm) — the contract's "done
when"; a second device's first connection of ten previews was ten project
reads, one `POST assets/urls` and twenty storage GETs with no poster
(posters now come on open); ten tiles caught up in one mint. The app sends
`bucket` on every PUT. Nothing further is asked of the server for stages
3–5; §B bundles stay parked until the per-project tiles pass is measured
on a real library.

**2026-10-03, late — the first production night, the developer's two
questions, answered.** (1) The 130 manifest writes beside the sweep: 116
were the day's new projects, each first push carrying records, poster and
working copy in one negotiate — a create each, not re-pushes; the sweep
used `POST assets` (100 and 145 copies, no manifests); the rest are grades
that moved. (2) Yes to the poster-by-hash idea, and the storm was wider
than old builds: a working copy is a confirmed asset, so every build's
count comparison fired and fetched records and poster again — the Mac 600
times this evening. The app now leaves working copies (and server-made
assets) out of the count it accounts for, reads the row's proxy pointer to
do the same from the row, and keeps a poster whose hash it recorded
(`renditions.poster.sha256` against the copy held, no download). A
confirmed-count move that is a proxy now costs nothing; one that is
originals arriving costs one listing per hundred projects and no poster.
Tiles stay held until every device has the build; "flip tiles" then.
Sync-cost step 2 (`md5` at negotiate, the no-op PUT) is welcome right after
the flip.
