# PicPlace sync trace: one photo from Mac to server to web to Simulator

**Date:** 2026-09-30, 17:30–18:34 CEST · **Branch:** `ios-app` at `af52a94` · **Raw data:** [`2026-09-30-synth-photo-sync/`](2026-09-30-synth-photo-sync/)

This report is written to be handed to another model. It is mostly **data points**. Interpretation is kept to a minimum and labelled wherever it appears.

**How to read it**
- Times are CEST (UTC+2) unless marked UTC. Server rows are stored in UTC.
- *Measured* means it came from this run (logs, network traces, database, disk).
- *Code-derived* means it came from reading the source (file:line given). It was not observed.
- Byte counts in the request tables are on the wire and include headers.

---

## 1. Goals and what we were looking for

### Goals (from Steven's brief)

| # | Goal |
|---|---|
| G1 | Make an isolated **test library** for synthetic photos: a separate account and library that never mix with personal libraries (timelapses, holidays, family). Library `synth` on the Mac, account `synth@picplace.test` on the local `picplace.test` server, and a PicPlace library also named `synth`. |
| G2 | Record **what sync and server traffic takes place** when a person (1) imports ONE photo on the Mac, (2) applies a preset, (3) refreshes the PicPlace website, and (4) opens the iPhone Simulator that is bound to the same library. |
| G3 | Judge **how optimised or unoptimised** that traffic is, end to end. |
| G4 | Find **performance and UX wins**, including a UX question raised before the run: should signing in lead straight into a "Connect this library" choice? (§9) |

### Hypotheses stated before the run, with outcomes

| # | Hypothesis (from the code traces) | Outcome |
|---|---|---|
| H1 | A new photo gets two full push cycles, minimal then originals: about 20 API calls and 3 uploads, with the manifest written twice. | **Confirmed.** 16 API calls plus 3 storage PUTs for the two cycles; 21 requests with the 5-request check that carried them; 24 with the follow-up usage refresh. `manifest_written` ×2 in the same second. |
| H2 | A preset tap makes its own 8-call push that re-sends the poster and `records.aar` but not the original. | **Not measured.** The preset was applied 11 s after import, inside the 20 s debounce, so both went up in one push. |
| H3 | The web page mints a fresh signed poster URL on every view (no-store) and shows no title, camera or location. | **Confirmed.** See §5.6. The index row's `name` is NULL. |
| H4 | The Simulator pulls a preview (records + poster) and never the original on its own. | **Confirmed.** The original arrived only after a person pressed Download (§5.7). |
| H5 | The Mac's later originals upload makes the Simulator re-download records and poster. | **Not observable.** The Simulator pulled after both pushes had landed. |
| H6 | An idle, foregrounded Simulator costs 5 requests every 3 minutes. | **Confirmed**, and now mapped: 4× `GET /status` plus 1× `GET /projects` (§5.8). |

**Unplanned event.** The local storage (Garage in Docker) was down when the photo was imported. That produced 17 minutes of real failure-and-recovery data (§5.3).

---

## 2. Environment

| Item | Value |
|---|---|
| Mac | Device `macbookpro`, arm64, macOS 27 (Darwin 27.0.0). LetsLapse **Release** 0.1.0 (1), built 2026-09-29 14:18 UTC, pid 90535. Device key `03533ce8-339d-4689-896f-d1dc75fcf25e`. |
| Mac library | `~/Pictures/LetsLapse/synth`. Identity `8F3AA852-AFE5-43C9-80A5-CAAAF9F40C19`, created 16:33:11. Bound 17:31:08 to `@synth` on picplace.test, where a server library "synth" was created with the **same uuid**. Initial sync case `clean`. |
| Mac switches (this device + library) | `autoSync` on, `autoOriginals` on (switched on by Steven at about 17:32), `autoBlends` on, Wi-Fi only on. |
| Simulator | "LetsLapse Fresh", iOS 27.0, UDID `C8F8FCC2-…`. App built 2026-09-30 15:37 UTC, pid 8279. Device key `d71224c0-…`. |
| Simulator library | Folder `Libraries/457D3FBD-…`. At bind (17:50:26) it was renamed "synth" and took the identity `8F3AA852…`. The log says "— fresh"; the initial sync reports `(clean)`. `autoOriginals` is **off** (the default; there is no `settings.json`). |
| Server | picplace.test: Laravel on Valet (nginx + php-fpm), MySQL 8.4, `APP_DEBUG=true`. Storage is **Garage v2.4.1 in Docker** at `127.0.0.1:3900`, bucket `picplace-dev`. |
| Server background work | `QUEUE_CONNECTION=database` with **no worker running**. **No scheduler.** `CACHE_STORE=database`. |
| Server limits (code-derived) | 300 requests/min per access token, 1,000/min per account (`config/letslapse.php:49-52`). The client paces itself at 255/min. |
| Tokens (code-derived) | Access tokens last 60 min; refresh tokens last 180 days and rotate. The Mac's token was issued 17:30:26 and expired 18:30:26; no request was made after that before the report was written. |
| Other accounts on the same server (for scale) | `regularsteven` 1,405 projects (10 tombstones), `letslapse-two` 45, `synth` 1, `letslapse-nearby` 1. The usage ledger holds 13,659 rows. |
| Test asset | `letslapse-generator/out/broad-mix/photos/buildings/buildings.01/frame.jpg`: 408,461 B, 1728×1152 JPEG, SHA-256 `e30c949f61c47c8a…`. |

---

## 3. Method

| Source | What it gave | Limits |
|---|---|---|
| MySQL (read-only `SELECT`s) | Snapshots of `letslapse_projects`, `_assets`, `_presences`, `_project_index`, `_asset_index`, `_uploads`, `_devices`, `oauth_access_tokens`, `jobs`. The **usage ledger** `letslapse_usage_events` from id 18659 onward. | The ledger records transfers and manifest writes only. Claims, negotiates, presence, `/status` and `/device` write nothing to it. |
| App console logs | `Logs/console-*.log` in the Mac library and in the Simulator app container. | The app logs failures and outcomes, not individual successful requests. |
| CFNetwork per-task summaries | `log stream` on the Mac (pid 90535) and `simctl spawn … log stream` on the Simulator. For each task: start time, whether a body was sent and its size, status, duration, and request/response bytes on the wire. | **URLs are redacted** by the OS. Each request was mapped to its endpoint by order, body size, response size and status, checked against the code (§7). |
| Disk | Both libraries' `Projects/<id>/` folders (sizes and times) and `PicPlace/sync-state.json`. | — |
| Web | `curl` signed in as synth at 18:33: login, page time-to-first-byte (TTFB), the poster redirect's headers, and two back-to-back poster requests. | **These probes added 4 ledger rows (18670–18673).** Server query counts are code-derived; the Valet access log is off. |

---

## 4. Timeline (CEST)

| Time | Where | Event |
|---|---|---|
| 16:33:13 | Mac | Library `synth` created. The app relaunched on it. No PicPlace session. |
| 16:35:06 – 17:30:21 | Mac | The sign-in browser opened **6 times**. Callbacks were received at 16:35:09, 16:35:41 and 17:30:26. Only 17:30:26 completed: it logged pacing and the nearby key. The 16:35 callbacks were followed by **no success line and no failure line**. A relaunch at 16:36:10 came back with "session none". |
| 17:31:08 | Mac | Library bound to `@synth` as "synth" (`clean`), 40 s after sign-in (time spent on the Connect sheet). Nearby started and failed at once with `-65555 NoAuth`. |
| 17:31:08 → | Mac | `nearby: browser failed — NoAuth; rebuilding…` about every 63 s, for the rest of the run: **124 of 244 log lines**. |
| ≈17:32 | Mac | Steven switched on *Upload originals automatically* (`settings.json` time). |
| 17:50:20 – 17:50:26 | Sim | Signed in as synth, then bound ("fresh"/"clean"). |
| 17:56:02 | — | Observers started. Baseline: server empty for synth; ledger at id 18659. |
| 17:56 → | Sim | A timer check every 3 min (…:09 past each 3-minute mark), 5 requests each. |
| 18:08:47 | Mac | Foreground check (Mac app brought forward), 5 requests. |
| **18:09:22** | Mac | **Step 1: import of ONE JPEG** → Photo project "frame", `648A0A63-…`. |
| **18:09:33.671** | Mac | **Step 2: preset "Cinema" applied.** `project.json` `modifiedAt`. |
| 18:09:54.704 | Mac | Push fired, 21.0 s after the last write. Poster rendered (245,448 B); records bundle made (5 members → 736 B). |
| 18:09:54.785 – 18:10:08.6 | Mac → server | `PUT /projects/{uuid}` → **500 ×4**. The server's write of the manifest to Garage failed (`cURL error 55: Broken pipe`). The push was marked failed (1). |
| 18:10:11 | Mac | Foreground check: "1 waiting to retry". |
| 18:11:16 – 18:11:30 | Mac | Steven pressed Try again: the same 4× 500. Failures = 2, so the next automatic try was due **18:17:30**. |
| ≈18:17:30 | Mac | **No check ran.** The Mac app was not frontmost, and background checks need ≥14 min 55 s since the last check (code-derived, §7). |
| ≈18:26–18:27:08 | host | Docker Desktop was wedged. Its leftover processes were stopped and Docker was relaunched; Garage was healthy by about 18:27:08. |
| **18:27:11.143 – 18:27:12.170** | Mac → server | Timer check → minimal push → originals push: **21 requests in 1.03 s** (§5.4). |
| 18:27:15 | Mac | Usage refresh: 3 requests. |
| 18:28:11 | Mac | Foreground check: 5 requests. |
| **18:28:21** | Web | **Step 3: page view #1.** Ledger: poster URL issued via web. |
| 18:28:50.9 | Sim | Usage refresh from the UI: 3 requests. Log: "1 of the library's 1 project(s) on PicPlace are not here". |
| **18:28:52.534 – .946** | Sim | **Step 4: manual check → preview pulled** (2 objects, 246,184 B), 1 min 41 s after the Mac's push landed. |
| 18:29:00.25 – .376 | Sim | Download of the original after a person's press (408,461 B). iOS "continued task" was refused on the Simulator. |
| 18:29:09 | Sim | Timer check: poster noted as already on PicPlace; "all 1 heavy file(s) here verified on PicPlace: backed up". |
| 18:29:20 | Web | Page view #2. |
| 18:32:09 → | Sim | Back to idle checks: 5 requests / 3 min. |
| 18:33:11 – 18:33:24 | Web (curl) | Measurement probes (4 ledger rows). |

**End-to-end latencies (measured)**

| Interval | Duration |
|---|---|
| Last write (preset) → push start | 21.0 s |
| Push start → everything confirmed on the server (minimal + originals), successful run | 1.03 s |
| Import → on the server, this run (outage) | 17 min 50 s |
| Import → on the server, expected without the outage (interpretation) | ≈ 33 s: 11 s of editing + 21 s debounce + 1 s push |
| Server has it → Simulator has the preview (manual check) | 1 min 41 s. The Simulator's next timer check would have been at +1 min 58 s. |
| Simulator: manual-check start → "pulled" log line | 0.41 s |
| Simulator: original download press → done | 0.12 s |

---

## 5. Step-by-step data

### 5.1 Import on the Mac (step 1)

Files written in `Projects/648A0A63-…/`:

| File | Bytes | Time | Note |
|---|---|---|---|
| `source/frame.jpg` | 408,461 | 12:30:25 (source file's own mtime kept) | The original. |
| `source/capture_log.json` | 414 | 18:09:22 | |
| `source/frames.timestamps` | 73 | 18:09:22 | |
| `source/frames.exposure` | 57 | 18:09:22 | |
| `assets.ndjson` | 281 | 18:09:22 | One line: bytes, sha256, dimensions. |
| `metadata.json` | 192 | 18:09:22 | |
| `project.json` | 2,045 | 18:09:33 | Rewritten by the preset. `mode: "Photo · Imported"`, `kind: photos`, `createdAt` = the file's time (10:30:25Z), `originalName: frame.jpg`. There is **no `name` field**. |
| `poster.jpg` | 245,448 | 18:09:54, re-written 18:27:11 | Made at push time, not at import. 1280×854, JPEG q0.7. **60% of the original's bytes** for this 1.99 MP synthetic JPEG. |

Other measured points:
- The log shows `assets: 648A0A63 recorded 1 of 1 pending` and `project sizes: measuring 1` at 18:09:22. `sizeBytes: 434176` was recorded in `project.json`.
- **Code-derived:** a 1-file pick never shows the shoot-or-photos question (`AppModel.swift:8227`, which needs ≥2 files). Imports carry no auto-apply context, so the project starts as Original (`AppModel.swift:8046–8049`).

### 5.2 Preset (step 2)

- On disk: only `project.json` changed (`selectedPreset: "Cinema"`, `presetState` named/built-in, `modifiedAt` 16:09:33.671Z).
- Server `revision` = `1790784573671`, which is `modifiedAt` in epoch milliseconds.
- `posterToken` in the sync record = `"e6|Cinema|n"`.
- The push began 21.0 s after this write (debounce 20 s, reset by every write; code-derived `PicPlaceAutoSync.swift:32, 424–431`).
- **The import and the preset shared one push.** An edit-only push (H2) was not measured.

### 5.3 The failed pushes (storage outage)

Mac requests, first attempt:

| Start | Status | Duration | Body | Req B | Resp B | Endpoint (mapped) |
|---|---|---|---|---|---|---|
| 18:09:54.705 | 404 | 61 ms | 20 | 1,107 | 1,472 | `POST /projects/{u}/claim` (404 = new project, may create) |
| 18:09:54.785 | **500** | 357 ms | 1,439 | 2,419 | **18,463** | `PUT /projects/{u}` (manifest inline) |
| 18:09:57.314 | 500 | 136 ms | 1,439 | 2,415 | 18,463 | same, in-place retry +2.5 s |
| 18:10:01.608 | 500 | 234 ms | 1,439 | 2,415 | 18,517 | same, retry +4.3 s |
| 18:10:08.358 | 500 | 222 ms | 1,439 | 2,415 | 18,463 | same, retry +6.8 s |
| 18:10:08.582 | 404 | 14 ms | – | 975 | 1,472 | `DELETE /projects/{u}/claim` (nothing to release) |

The second attempt (18:11:17–18:11:30) was identical: claim 404, 4× 500, release 404. Each attempt's check and usage refresh added 3–8 more GETs.

**Server side**
- `laravel.log` has 8 entries: `UnableToWriteFile … Error executing "PutObject" on "http://127.0.0.1:3900/…/manifest/{u}.json"; AWS HTTP error: cURL error 55: Send failure: Broken pipe`. Sample in `server-error-sample.txt`.
- **No project row was created**, and no asset or ledger rows. The PUT failed before the row was kept.
- Each 500 response was about 18.4 KB: the debug body with the raw storage URL, because `APP_DEBUG=true`.

**Environment root cause.** Docker Desktop (up 10 days 21 h) was wedged: `docker version` gave no answer in 8 s, and its VM process was at 200–300% CPU. Its backend log was silent from 27 Sep 13:52 UTC, and qdrant's last log line was 28 Sep 08:27 UTC. Docker's host port forwarder **still accepted TCP on :3900** and then broke the pipe.
- A pre-run `nc -z` probe said "up". `curl` answering `403` in about 7 ms is the reliable check.
- The recovery killed the leftover backend, VM and virtualization processes (the root `vmnetd` helper was left), then ran `open -a Docker`. The engine answered in about 4 s. Garage (`restart: unless-stopped`) came back healthy with the bucket intact. qdrant (`restart: no`) stayed exited.

**Client behaviour (measured, with code-derived rules)**

| Aspect | Value |
|---|---|
| In-place retries per request | 3, at about +2.5 s, +4.3 s, +6.8 s after the first attempt |
| Failure record | `failures: 2`, `lastError: "PicPlace had a problem (500); try again later"`, `policy: minimal`, `revision: 0` |
| Automatic retry schedule (code) | 3 min × 2^(n−1), capped at 60 min, after the latest failure (`PicPlaceSyncRun.swift:144–149`). A person's press ignores it. |
| Due vs actual | Due at 18:17:30. It actually ran at **18:27:11**, at the next check the Mac allowed: not frontmost means ≥14 min 55 s between checks (`PicPlaceAutoSync.swift:50, 84–85`). |
| UI copy reported by Steven | "Sync Failed – PicPlace had a problem (500); try again later", then "Sending the manifest" → failed again after Try again |
| UI copy in code | The card can append "· tries again at HH:MM" (`PicPlaceViews.swift:619–621`, `PicPlaceAutoSync.swift:644–652`). The HH:MM is the backoff time, not when the next check will actually run. |
| "Can't reach" gate | Not engaged. It is for no-answer failures, and a 500 is an answer (code-derived, `PicPlaceAutoSync.swift:238–255`). |

### 5.4 The successful sync on the Mac (18:27:11)

Every request, in order. Mappings are checked against code order (`PicPlaceSyncRun.swift:168–560`, `PicPlaceChangeSync.swift:203–211`, `PicPlaceController.swift:908–995`, `PicPlaceAutoSync.swift:1089`).

| # | Start | Status | ms | Body B | Req B | Resp B | Endpoint (mapped) | Phase |
|---|---|---|---|---|---|---|---|---|
| 1 | 11.143 | 200 | 92 | – | 1,029 | 1,098 | `GET /status` (ChangeSync:203) | timer check |
| 2 | 11.265 | 200 | 67 | – | 933 | 1,098 | `GET /status` (Controller:947, inside `repairBindingLibraryIfMissing`, unconditional) | timer check |
| 3 | 11.350 | 200 | 45 | – | 947 | 283 | `GET /projects?include_deleted=1` (whole index; empty) | timer check |
| 4 | 11.410 | 200 | 44 | – | 933 | 1,098 | `GET /status` (Controller:962, `refreshUsage`) | timer check |
| 5 | 11.471 | 200 | 34 | – | 933 | 1,098 | `GET /status` (Controller:947 again, via `refreshUsage`) | timer check |
| 6 | 11.479 | 404 | 19 | 20 | 1,011 | 1,472 | `POST /projects/{u}/claim` → new | minimal push |
| 7 | 11.523 | **201** | 78 | 1,439 | 2,419 | 1,001 | `PUT /projects/{u}` (manifest + `library`) → created | minimal push |
| 8 | 11.605 | 200 | 52 | 342 | 1,323 | 1,176 | `POST /projects/{u}/assets` (negotiate 2 files) | minimal push |
| 9 | 11.663 | 200 | 17 | 736 | 1,668 | 270 | storage PUT `records.aar` (presigned, Garage) | minimal push |
| 10 | 11.663 | 200 | 27 | 245,448 | 246,387 | 270 | storage PUT `poster.jpg` (concurrent with #9) | minimal push |
| 11 | 11.695 | 200 | 61 | 256 | 1,242 | 641 | `POST /projects/{u}/assets/confirm` | minimal push |
| 12 | 11.758 | 200 | 34 | 44 | 1,025 | 387 | `POST /projects/{u}/presence` | minimal push |
| 13 | 11.794 | 200 | 29 | – | 975 | 239 | `DELETE /projects/{u}/claim` | minimal push |
| 14 | 11.861 | 200 | 43 | – | 960 | 1,391 | `GET /projects/{u}` (does PicPlace hold the heavy files already?) | originals push |
| 15 | 11.922 | 200 | 27 | 20 | 999 | 380 | `POST /projects/{u}/claim` | originals push |
| 16 | 11.954 | 200 | 32 | 1,390 | 2,366 | 636 | `PUT /projects/{u}` (**manifest again**, unchanged revision) | originals push |
| 17 | 11.988 | 200 | 35 | 177 | 1,158 | 924 | `POST /projects/{u}/assets` (negotiate the JPEG) | originals push |
| 18 | 12.026 | 200 | 18 | 408,461 | 409,393 | 270 | storage PUT `source/frame.jpg` | originals push |
| 19 | 12.055 | 200 | 46 | 134 | 1,120 | 506 | `POST /projects/{u}/assets/confirm` | originals push |
| 20 | 12.104 | 200 | 32 | 44 | 1,025 | 388 | `POST /projects/{u}/presence` (tier original) | originals push |
| 21 | 12.139 | 200 | 31 | – | 968 | 240 | `DELETE /projects/{u}/claim` | originals push |
| 22 | 15.361 | 200 | 52 | – | 933 | 1,108 | `GET /status` (usage refresh, +3 s debounce) | usage |
| 23 | 15.431 | 200 | 33 | – | 933 | 1,108 | `GET /status` (repair, unconditional) | usage |
| 24 | 15.480 | 200 | 32 | – | 934 | 626 | `GET /projects` (whole index, 1 row) | usage |

**Totals**

| Measure | Value |
|---|---|
| Requests | 24: 21 API + 3 storage PUTs |
| Payload up | 654,645 B (736 + 245,448 + 408,461), plus 2× manifest (1,439 + 1,390 B) |
| Wall time #1–#21 | 1.03 s. No pacing waits. |
| API requests that are pure overhead for one project (interpretation) | Checks and usage: 8 GETs, 6 of them `/status`. Second cycle: claim, manifest PUT, presence, release. `GET /projects/{u}` before a first-ever upload. |

### 5.5 Server state after the push (from `server-state-18-31.txt`)

| Table | Row(s) |
|---|---|
| `letslapse_projects` | `648a0a63…` · name `frame` · type `photo` · revision `1790784573671` · `manifest_bytes` 1,284 · updated by `macbookpro` · created and updated 16:27:11 UTC |
| `letslapse_assets` | `poster.jpg` preview 245,448 B · `records.aar` records 736 B · `source/frame.jpg` source 408,461 B. All `confirmed` 16:27:11–12 UTC, uploaded by macbookpro. |
| `letslapse_presences` | macbookpro rev 1790784573671 tier **original** (16:27:12) · LetsLapse Fresh same rev, tier **original** (16:29:00, after the manual download) |
| `letslapse_project_index` | category `photo`, kind `photos`, **name NULL**, **capture_mode NULL**, **client_revision NULL**, selected_preset `Cinema`, preset_kind `named`, frame_count 1, 1728×1152, indexed_at 16:27:11, **`records_indexed_at` NULL** |
| `letslapse_asset_index` | `source/frame.jpg` role source, **bytes NULL, width NULL, height NULL**, edited 0 |
| `letslapse_uploads` (synth) | 0 rows (clean) |
| Ledger rows 18660–18664 | `manifest_written` 1,284 (delta +1,284) · `upload_confirmed` records.aar 736 · `upload_confirmed` poster.jpg 245,448 · **`manifest_written` 1,284 (delta 0)** · `upload_confirmed` source/frame.jpg 408,461 |
| Server-wide context | 2,234 `manifest_written` rows for 1,452 projects · 1,421 web poster-URL rows · 172 stale `letslapse_uploads` (oldest expired 2026-09-18) · 7 `PurgeProjectObjectsJob` pending since 17–21 Sep |

`records.aar` is 5 members (`project.json`, `metadata.json`, `assets.ndjson` and source sidecars). **Code-derived:** the server never opens it (`ProjectIndexer.php:31`). The fields that would come from `metadata.json`/`assets.ndjson` stay NULL, because the app does not upload those files separately (`PicPlaceSyncPolicy.swift:58-59`). Account-wide, 0 of 1,451 index rows have `records_indexed_at`.

### 5.6 The web (step 3)

| Measure | Value |
|---|---|
| Page views by Steven | 18:28:21 and 18:29:20 (one ledger row each: `download_url_issued`, via `web`, poster.jpg, bytes_out 245,448) |
| `GET /letslapse` (synth, 1 project) | 200, TTFB 42 ms, 18,479 B HTML |
| `GET /letslapse/p/648a0a63…` | 200, TTFB 34 ms, 17,149 B HTML |
| Asset links on the detail page | Poster link ×2 (same asset id), `records.aar` ×1, `source/frame.jpg` ×1 (download links; presigned only when clicked) |
| `GET /letslapse/a/{poster id}` | `HTTP/2 302`, `cache-control: no-store, private`. Location is a presigned Garage URL: `http://127.0.0.1:3900/…/preview/57cd2c1c….jpg?response-content-type=image%…&X-Amz-…`. The page is https and the image URL is http (local setup only). |
| Two requests 1 s apart | Different `X-Amz-Date` (16:33:22Z vs 16:33:23Z) and different signatures, so the browser cache can never hit |
| Storage response for the poster | 200, `etag`, `last-modified`, `content-length: 245448`, **no Cache-Control** |
| Ledger accounting | My 4 probes (18670–18673) were recorded as 4 × 245,448 = **981,792 B `bytes_out`**. Only 245,448 B were actually downloaded (one redirect followed). |
| What the card shows (code-derived) | Poster, category, frame count, W×H, source formats, captured date, stored bytes. Title, caption, camera, GPS, keywords and rating are always NULL (no `metadata.json` asset). |
| Server work per overview view (code-derived) | About 25 uncached queries: `UsageReport` about 20 aggregates, including three passes over the user's whole ledger; `ProjectBrowser::chips` loads every index row; 48 cards per page with 3 subqueries per row. Each poster request adds an ownership query, a presign and a ledger insert. |

### 5.7 The Simulator (step 4)

Requests from 18:26:09. Mappings are checked against code order (`PicPlaceChangeSync.swift:203–449`, `PicPlaceLibrarySync.swift:330–414`, `PicPlaceController.swift:908–995`).

| Start | Status | ms | Body B | Resp B | Endpoint (mapped) | Phase |
|---|---|---|---|---|---|---|
| 18:26:09.217 / .290 / .323 / .350 / .377 | 200 ×5 | 20–67 | – | 1,136 / 1,136 / **283** / 1,136 / 1,136 | status, status (repair), index (empty), status (usage), status (repair) | idle timer check |
| 18:26:39.572 / .616 / .644 | 200 ×3 | 14–41 | – | 1,138 / 1,138 / 282 | status, status (repair), index | usage refresh (UI) |
| 18:28:50.893 / .946 / .969 | 200 ×3 | 15–50 | – | 1,143 / 1,143 / **627** | status, status (repair), index (1 row) | usage refresh (UI) → "1 … not here" |
| 18:28:52.534 | 200 | 35 | – | 1,146 | `GET /status` | **manual check** |
| 18:28:52.572 | 200 | 29 | – | 1,146 | `GET /status` (repair) | manual check |
| 18:28:52.603 | 200 | 20 | – | 627 | `GET /projects?include_deleted=1` | manual check |
| 18:28:52.625 | 200 | 24 | – | 1,510 | `GET /projects/{u}` (row + every asset + manifest) | pull |
| 18:28:52.664 | 200 | 21 | 51 | 911 | `POST /projects/{u}/assets/urls` (records.aar) | pull |
| 18:28:52.702 | 200 | 4 | – | 1,020 | storage GET `records.aar` | pull |
| 18:28:52.722 | 200 | 30 | 51 | 909 | `POST /projects/{u}/assets/urls` (poster) | pull |
| 18:28:52.753 | 200 | 6 | – | 245,720 | storage GET `poster.jpg` | pull |
| 18:28:52.781 | 200 | 26 | 43 | 451 | `POST /projects/{u}/presence` (tier preview) | pull |
| 18:28:52.959 / 53.005 | 200 ×2 | 26–36 | – | 1,146 ×2 | status (usage), status (repair) | manual check end |
| 18:28:56.793 | 200 | 46 | – | 1,566 | `GET /projects/{u}` | UI (project opened; interpretation) |
| 18:29:00.252 | 200 | 43 | – | 1,566 | `GET /projects/{u}` | original download (a person's press) |
| 18:29:00.297 | 200 | 17 | 51 | 908 | `POST /projects/{u}/assets/urls` (source/frame.jpg) | original download |
| 18:29:00.317 | 200 | 8 | – | 408,732 | storage GET `source/frame.jpg` | original download |
| 18:29:00.338 | 200 | 23 | 44 | 445 | `POST /projects/{u}/presence` (tier original) | original download |
| 18:29:09.219 → .351 | 200 ×7 | 13–35 | 70 on #4 | 1,148 / 1,147 / 676 / 584 / 1,148 / 1,563 / 1,148 | status, status (repair), index, **`POST /projects/assets`** (batched poster check), status (usage), `GET /projects/{u}` (heavy-file verify), status (repair) | timer check |
| 18:32:09 → | 200 ×5 | | | | idle pattern again | idle |

**Simulator log lines**
- 18:28:52.946 `pulled frame (648a0a63) — 2 object(s), 246184 bytes; 1 heavy file(s) stay on PicPlace`
- 18:29:00.252 `continued task asked for — Downloading "frame"` → `refused … BGTaskScheduler is not available on this platform` (Simulator)
- 18:29:00.376 `downloaded the originals of frame: 1 file(s), 408461 bytes`
- 18:29:09 `poster check — 1 of 1 already on PicPlace, noted without sending`
- 18:29:09 `frame — all 1 heavy file(s) here verified on PicPlace: backed up`

**Simulator copy vs Mac copy** (`diff` of the two project folders)

| File | Result |
|---|---|
| `poster.jpg`, `source/frame.jpg` | byte-identical |
| `project.json` | 1,968 B vs 2,045 B. Differences: `addedAt` is the pull time on the Sim (16:28:52.761Z vs 16:09:22.363Z); `sizeBytes`/`sizeMeasuredAt` are absent on the Sim. |
| `metadata.json` | `importedAt` is the download time on the Sim (16:29:00.339Z vs 16:09:22.375Z) |
| `assets.ndjson` | Sim has **2 lines** (562 B): the pulled line plus a line appended at the download (`hashedAt` 16:29:00.334Z). Mac has 1 line (281 B). |
| Sim sync record | `policy: pull`, `uploaded: 0`, `serverConfirmedSeen: 3`, `alsoOn`/`originalsOn: [macbookpro]`, `posterToken "e6|Cinema|n"`. No push from the Sim was observed up to 18:34. |

### 5.8 Idle cost

**Composition of one idle check** (measured every time, both devices; call sites code-derived):

| # | Request | Call site |
|---|---|---|
| 1 | `GET /status` | `PicPlaceChangeSync.swift:203` |
| 2 | `GET /status` | `PicPlaceController.swift:947`: end of `repairBindingLibraryIfMissing`, runs **unconditionally**, even when nothing was repaired |
| 3 | `GET /projects?include_deleted=1` (whole account index, no `library=`, no `updated_since`, no ETag) | `PicPlaceChangeSync.swift:211` |
| 4 | `GET /status` | `PicPlaceController.swift:962`: `refreshUsage(rows:)` |
| 5 | `GET /status` | `PicPlaceController.swift:947` again (`refreshUsage` calls the repair too) |

**Cadence and volume**

| Device state | Cadence | Requests/hour |
|---|---|---|
| Simulator, app active | every 3 min (measured :09 past each 3-minute mark) | 100 (20 checks × 5) |
| Mac, not frontmost | ≥14 min 55 s between checks (measured 17:32:14 → 17:48:11, 18:11:16 → 18:27:11) | ≈20 |
| Mac, frontmost | 3 min (code) | 100 |

**Size and server cost**
- Wire cost of one idle check on an empty library: about 4.8 KB up and 4.8 KB down.
- The index grew from 283 B (0 projects) to 626–627 B (1 project), **+343 B per project on the wire**. Extrapolated to `regularsteven`'s 1,405 projects: ≈ 480 KB per index read. Compression is unknown and this was not measured.
- **Server cost (code-derived):** `/status` runs about 12 uncached aggregate queries (`StatusController.php:20-113`), so an idle check costs about 48 aggregates plus the index query. The index eager-loads 4 relations per row and runs 3 correlated subqueries per row (`LetsLapseProject.php:127-141`). With `CACHE_STORE=database`, each API call also reads and writes the throttle rows in the `cache` table.

### 5.9 Noise and environment findings

| Finding | Data |
|---|---|
| Nearby retry loop (Mac) | `nearby: browser failed — -65555: NoAuth` / `listener failed` about every 63 s from 17:31:08, **forever**. 124 of 244 lines in the Mac log. `DNSServiceBrowse failed: NoAuth(-65555)` in the unified log: Local Network permission is refused for this build. The code rebuilds after 5, 10, 20, 40 s, then every 60 s, while signed in with a fresh key and the scene active (`NearbyService.swift:342–352`). |
| Nearby on the Simulator | No failures logged. |
| `laravel.log` | 25.6 MB. 8 new entries this run, each with a full stack trace. |
| Queue and scheduler | No worker and no `schedule:work`. Nothing in this scenario needed the queue (indexing is synchronous). `verify-assets` (every minute), `reap-uploads` (every 30 min), `purge-tombstones` and `passport:purge` (daily) are not running, which is why the 172 stale uploads remain. |
| Docker | See §5.3. Wedged for about 3 days before the run; a plain TCP probe hid it. |
| Sign-in | 6 browser openings for 1 completed sign-in; 2 callbacks at 16:35 with no outcome line (see §4). The sign-in code logs `sign-in failed: …` in its `catch` (`PicPlaceController.swift:725`), so a hang in the token exchange or profile step is one explanation (unconfirmed). |

---

## 6. Code-derived facts (for context; not observed in this run)

**Client** (paths under `LetsLapse/App/PicPlace/` unless noted)
1. An auto-push is debounced 20 s after the last `project.json` write, and each write resets it (`PicPlaceAutoSync.swift:32, 424–431`).
2. The originals queue starts after a push-queue run that sent something (`PicPlaceAutoSync.swift:595`) and after every check (`PicPlaceChangeSync.swift:449`). It needs `recordsReachedServer` and skips a project whose `heavyDigest` matches (`:761, :777`).
3. After an originals upload, if the server has not verified the file at confirm, the app polls `GET /projects/{u}` every 10 s for 2 min, then every 30 s up to 5 min, then every 60 s up to 30 min (`PicPlaceAutoSync.swift:1005`). There is also a forced blends walk at +90 s (`:851`). Not triggered here: Garage verified at confirm.
4. The blends queue never uploads for a Photo project (`sendsBlends = !isPhotoCapture`, `PicPlaceAutoSync.swift:911`).
5. `records.aar` is rebuilt and hashed on every push (`PicPlaceSyncRun.swift:739`). It is deterministic (`DirectoryArchive.swift:23`), so an unchanged bundle is skipped by the server's negotiate. A preset changes `project.json`, which is inside the bundle, so it would be re-sent (expected; H2 not measured).
6. The poster is re-rendered when the grade token changes (1280 px, q0.7; `PicPlacePoster.swift:14–15, 20–44`).
7. A foreground event within 60 s of the last check is **dropped, not deferred** (`PicPlaceChangeSync.swift:127`). Clicking the Simulator window does not make the iOS app active; only a real iOS background/foreground does.
8. `pullUpdate` always re-downloads `records.aar`, even for a grade-only change (`PicPlaceChangeSync.swift:617–625`). A later heavy-file upload changes the confirmed-asset count, which triggers a re-pull (`:376–377`).
9. The pull mints URLs one file per call (`PicPlaceLibrarySync.swift:414`), although the endpoint takes an array.
10. `POST /device` ("told PicPlace this device runs…") is sent only when the version string changes, and that string includes the build time. It can be sent twice after a new build, because launch registration does not set the key the first check reads (`PicPlaceController.swift:831, 2267–2282`).
11. Risk: an originals push stamps the current `posterToken` without rendering or sending the poster (`PicPlaceController.swift:1873, 1890`). A preset tapped just before an originals sync can leave the web on the old poster.
12. Risk: a preset tapped while an originals upload runs gets `.nothing` from the edit push and waits for the next check (`PicPlaceAutoSync.swift:614`). On a Mac in the background that is up to about 15 min.
13. `updated_since` is stored (`sync-state.json → meta.serverTime`) but deliberately unused. The design note says an incremental index misses a project only this device edited (`PicPlaceChangeSync.swift:207–210`).
14. Tokens refresh lazily when less than 60 s remains, with one retry on a 401 (`PicPlaceKeychain.swift:13`, `PicPlaceAPI.swift:582, 728`).

**Server** (paths under `~/Sites/picplace/`)
1. Every API route runs `throttle:letslapse` (DB-cache-backed here), `auth:api` and `letslapse.access`, which writes `last_seen_at` at most once a minute (`bootstrap/app.php:18`, `EnsureLetsLapseAccess.php:22-45`).
2. `PUT /projects/{u}` writes the manifest to S3 **on every PUT, even when unchanged**, writes a `manifest_written` ledger row, and runs `ProjectIndexer::index` **synchronously** (`ProjectController.php:109-209`, `ManifestStore.php:34`).
3. The indexer loads every confirmed asset on every PUT. On a fingerprint change it deletes and re-inserts all asset and blend index rows (`ProjectIndexer.php:89, 238-272, 282-347`).
4. Negotiate: `firstOrNew` by name per item, and an account-wide SHA-256 dedupe query per item. A hit is a CopyObject + HEAD, confirmed at once (`AssetController.php:318-402`, `ObjectStore.php:152-157`).
5. Confirm: per asset, in sequence, an S3 HEAD with checksum, a transaction, 2 UPDATEs, and a synchronous delete of the replaced object (`AssetController.php:467-540`). There are no orphans on replace unless the delete fails, which is only logged (`:572-573`).
6. `GET /projects` is `->get()` with no paging and no ETag. `library=` and `updated_since` are supported but the app does not send them (`ProjectController.php:43-79`).
7. `/status` has no caching and runs about 12 aggregates (`StatusController.php:20-113`).
8. There is a batched asset read, `POST /projects/assets` (up to 100 uuids, `kinds` filter, 3 queries), which the app uses for the poster check (`AssetController.php:193-248`).
9. `bytes_out` is recorded when a download URL is issued, not when bytes move (`UsageLedger.php:43-49`).
10. The web poster route presigns a new 15-minute URL per request with `no-store`, and no `ResponseCacheControl` is set on the object URL (`Web/AssetController.php:23-35`, `ObjectStore.php:51-58`).
11. `records.aar` is opaque to the server, so the index fields from `metadata.json`/`assets.ndjson` stay NULL (`ProjectIndexer.php:31, 356-385`).
12. The only queued job in these paths is `PurgeProjectObjectsJob`, dispatched only when `deleted_object_days=0` (default 30) and by `letslapse:purge-tombstones`.

---

## 7. Candidate opportunities (inventory)

Each row names its evidence. The "effect" column is measured where it says so, otherwise estimated. The list is deliberately unranked.

### Requests and server load
| ID | Candidate | Evidence | Effect |
|---|---|---|---|
| R1 | Drop the unconditional `GET /status` at the end of `repairBindingLibraryIfMissing` when nothing was created or filed | §5.8 #2, #5; `PicPlaceController.swift:947` | −2 of 5 requests per idle check (measured pattern) |
| R2 | Pass the check's `/status` into `refreshUsage` instead of re-reading it | §5.8 #4; `Controller:962` | −1 more; an idle check becomes 2 requests (`/status` + index) |
| R3 | Scope and shrink the index read: `?library=<uuid>`, ETag/304, or `updated_since` plus a periodic full pass | §5.8; server supports `library`/`updated_since` (§6 server #6) | ≈ 480 KB → ~0 per idle check at 1,405 projects (extrapolated) |
| R4 | Cache `/status` for 30–60 s on the server | §6 server #7 | about 48 aggregates per idle check → ~0 on cache hits |
| R5 | One push cycle for a new project when originals are allowed (`.everything`), not minimal and then originals | §5.4 #14–#21 | −6 API calls per new project (measured cycle); manifest written once |
| R6 | Skip the manifest PUT in heavy-only pushes when revision = base, and skip the server's S3 manifest rewrite when the bytes hash equal | §5.4 #16; ledger `manifest_written` delta 0; 2,234 writes for 1,452 projects | −1 PUT, −1 S3 write, −1 ledger row per originals push |
| R7 | Skip `GET /projects/{u}` before a first-ever originals upload (`originalsMovedAt == nil`); negotiate already dedupes | §5.4 #14; `PicPlaceAutoSync.swift:1089` | −1 per new project |
| R8 | Mint several download URLs in one `assets/urls` call | §5.7 (two calls 58 ms apart); `PicPlaceLibrarySync.swift:414` | −1 per pull |
| R9 | Update the usage line from the push result instead of `/status` + whole index 3 s later | §5.4 #22–24 | −3 per push run |
| R10 | Use a non-DB store (redis/file) for the throttle | §5.8 server cost | 2 fewer DB round trips per API call (code-derived) |
| R11 | Negotiate/confirm in batches (`whereIn`), with concurrent HEADs | §6 server #4–5 | Scales with files per push (timelapses) |

### Latency
| ID | Candidate | Evidence |
|---|---|---|
| L1 | Push notice from the server to other devices (silent APNs, SSE or long-poll) instead of polling | Server→Sim took 1 min 41 s (manual); worst case about 3 min (active) or about 15 min (Mac in background) |
| L2 | Defer, don't drop, a foreground check that lands within 60 s of the last | §6 client #7 |
| L3 | Let a due retry run at its due time, not at the next allowed check | §5.3: due 18:17:30, ran 18:27:11 |
| L4 | Consider a shorter debounce for the first push of a brand-new project (nothing to coalesce with yet) | §5.2: 21 s of the ≈33 s expected end-to-end |

### Web and serving
| ID | Candidate | Evidence |
|---|---|---|
| W1 | Stable, cacheable poster URLs: sign against a fixed time bucket, add `ResponseCacheControl`, and allow a private cache on the 302. Keys change on re-upload, so long caching is safe. | §5.6: new signature every second, `no-store` |
| W2 | Record `bytes_out` on actual transfer, or once per asset per window; don't count URL issues as bytes | §5.6: 981,792 B recorded vs 245,448 B moved; 1,421 web rows account-wide |
| W3 | Cache the overview's aggregates per user, keyed on the newest project change and the newest ledger id | §5.6: about 25 uncached queries per view (code) |

### Data completeness
| ID | Candidate | Evidence |
|---|---|---|
| D1 | Upload `metadata.json` and `assets.ndjson` beside `records.aar` (or have the server read the archive), so the web and index get name, title, camera, GPS and sizes | §5.5: name NULL, asset bytes/width NULL, `records_indexed_at` NULL on 0 of 1,451 rows |
| D2 | Poster size policy for small originals: the poster is 60% of the original here (1280 px q0.7 vs a 1,728 px original) | §5.1 |
| D3 | Keep device-local fields (`addedAt`, `importedAt`, the appended `assets.ndjson` line) out of the synced records, or make them deterministic, so copies converge byte-for-byte | §5.7 diff |

### Failure handling and UX
| ID | Candidate | Evidence |
|---|---|---|
| F1 | Server: storage failure → `503` + a code (e.g. `storage_unavailable`) + `Retry-After`, not a `500` with an 18 KB debug body and the internal URL | §5.3 |
| F2 | Client: treat server-storage-down like the "can't reach" gate: one hold for the whole queue with one visible next-try time, not per-project backoff (100 imports = 100 separate 4-try failures) | §5.3, §6 client |
| F3 | Copy: "PicPlace's storage isn't answering — trying again at HH:MM", and make HH:MM the time the retry will really run (it can be a later check) | §5.3 UI copy |
| F4 | Sign-in: log an outcome for every callback (hung exchange/profile), and collapse repeated browser openings | §4 16:35 callbacks |
| F5 | Nearby: stop retrying after a NoAuth until the network or app state changes, and say once why nearby is off | §5.9 (51% of Mac log lines) |
| F6 | Close the stale-poster risk: an originals-only push must not stamp a `posterToken` it did not send | §6 client #11 |
| F7 | Run a pending edit push after an originals upload finishes, not at the next check | §6 client #12 |

### Local environment (dev only)
| ID | Candidate | Evidence |
|---|---|---|
| E1 | Health-check storage with an HTTP request (`curl` → 403), not a TCP probe | §5.3 |
| E2 | Run `php artisan schedule:work` (and a queue worker) locally, so verify, reap and purge match production | §5.9 |
| E3 | Maybe expose storage health in `/status` so the app can hold before sending | §5.3 |

---

## 8. Robustness summary (interpretation, short)

- **Correctness held.** Nothing was half-written on the server during the outage. The push recovered with no person's help once storage was back. Both copies ended byte-identical for the poster and the original. Presence tiers are right on both devices.
- **Cost is dominated by bookkeeping, not payload.** For one photo, 3 of 24 Mac requests carried content; the rest were checks, usage reads and a second full push cycle. Idle devices poll `/status` 4× per check.
- **Latency is dominated by the debounce and polling**, not by transfer: 1 s to push everything, versus 21 s debounce plus 0–3 min (or about 15 min) for the other device.

---

## 9. UX question raised before the run: sign-in → connect

**Steven's proposal.** After *Sign In* from a library that isn't connected, show the Connect sheet at once ("Connect ‹library› to PicPlace": create a new PicPlace library / link to an existing one / Not now). The only point of signing in there is to connect.

**Context**
- Decision **L18** (2026-09-16, `docs/libraries-plan.md:502`) says the connect question is never raised automatically after a sign-in. Its reason was that the old question hid its consequences ("the rest are exchanged" did not say 879 previews were about to land). The sheet now states its numbers (step 0, 2026-09-17), which removes that reason.
- The code comment is at `PicPlaceController.swift:718–721`.

**Counter-points raised**
1. Sign-in is **per Mac per server** (L13), not per library. A second library on an already signed-in Mac has no sign-in moment, so "prompt after sign-in" would never fire there. Suggestion: make the unconnected card's primary action **Connect to PicPlace…**, with sign-in as its first step only when needed.
2. Keep L18's safety: the sheet asks, it never answers. Nothing moves until a target is chosen and Connect is pressed.
3. Pre-select **New library on PicPlace (named after this one)** only when the local library is empty or has never synced. Word "Not now" as **Keep on this Mac only**, since an offline test library is a legitimate choice.
4. Move the server choice (picplace.co / .test) into that sheet. Today it can only change while signed out and unbound (`PicPlaceController.swift:782`).

**Data from this run.** 6 browser openings and 40 s on the connect sheet before the binding; 2 callbacks with no outcome line (§4).

---

## 10. Not measured / open

- An edit-only push (H2). The preset landed inside the import's debounce.
- The Simulator re-pull caused by the Mac's originals upload (H5), because the pull happened after both pushes.
- A large account's index size and the web overview's timing at 1,405 projects. The synth account had 1 project, and `regularsteven` was not probed.
- Real device behaviour (iOS background, `BGContinuedProcessingTask`), picplace.co (Hetzner, real TLS, rate limits), and mobile data.
- Server query counts are code-derived; no per-request server log exists locally (Valet `access_log off`).
- The Mac access token expired at 18:30:26 with no request afterwards, so the refresh round trip was not captured.
- What happened at the 16:35 sign-in callbacks.

## 11. Raw data (`2026-09-30-synth-photo-sync/`)

| File | Content |
|---|---|
| `mac-requests.txt` | Every Mac HTTP task, 17:56–18:33 (start, status, ms, body, bytes) |
| `sim-requests.txt` | Every Simulator HTTP task, 17:56–18:33 |
| `server-state-18-31.txt` | The synth account's rows in every LetsLapse table + ledger rows 18660–18669 + devices + token and job counts |
| `server-error-sample.txt` | One of the 8 server errors (first lines) |
| `mac-console.log`, `sim-console.log` | App logs (nearby spam and camera lines removed; OAuth query strings trimmed) |
| `mac-sync-state.json`, `sim-sync-state.json` | Each device's sync record for the project after the run |
| `mac-project.json` | The project record on the Mac |
