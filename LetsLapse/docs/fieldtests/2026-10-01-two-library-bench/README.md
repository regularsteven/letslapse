# PicPlace sync-cost bench: 2026-10-01

**Started** 2026-10-01T13:50:43 · **finished** 2026-10-01T14:11:17 · raw logs and `run.json` in [`raw/`](raw/).

A data pack, not an analysis. Every request comes from the app's own `picplace trace:` lines (`LL_PICPLACE_TRACE=1`): API bodies are JSON bytes without headers; storage bytes are the object's bytes. Ledger rows are the server's `letslapse_usage_events` for the account. Each step is one launch of the app with the hooks shown, settled until its log was quiet, then quit; a launch's own check (2 to 5 requests) is inside each step's figures.

## Inputs

- Photos: none
- `.lapse` projects: 0 file(s)
- Mac library `/Users/stevenwright/Pictures/LetsLapse/synth`, Simulator `C8F8FCC2-5DBC-4B87-B7FE-06D1085C7996`, server `https://picplace.test`, account `synth`.
- Simulator edit mode: **download** (download = the originals come down first, as the editor's just-in-time prompt would; preview = the preset is written over the preview alone).

## Summary

| Step | Device | s | API req | API up | API down | PUTs | PUT bytes | GETs | GET bytes | New projects | API req / new project |
|---|---|---|---|---|---|---|---|---|---|---|---|
| sim-a-baseline | Simulator | 70.5 | 13 | 402 B | 363.5 KB | 0 | 0 B | 0 | 0 B |  |  |
| sim-new-library | Simulator | 72.5 | 27 | 444 B | 950.2 KB | 0 | 0 B | 0 | 0 B |  |  |
| sim-b-import | Simulator | 70.6 | 82 | 12.4 KB | 621.4 KB | 12 | 2.1 MB | 0 | 0 B | 7 | 11.7 |
| mac-a-check | Mac | 70.2 | 12 | 544 B | 256.9 KB | 0 | 0 B | 0 | 0 B |  |  |
| sim-b-check | Simulator | 116.9 | 463 | 16.3 KB | 897.5 KB | 0 | 0 B | 228 | 29.7 MB | 114 | 4.1 |
| mac-a-launch-2 | Mac | 68.3 | 10 | 198 B | 254.6 KB | 0 | 0 B | 0 | 0 B |  |  |
| sim-b-launch-2 | Simulator | 70.7 | 12 | 201 B | 380.5 KB | 0 | 0 B | 0 | 0 B |  |  |
| sim-a-launch-2 | Simulator | 70.6 | 12 | 201 B | 380.5 KB | 0 | 0 B | 0 | 0 B |  |  |
| sim-b-launch-3 | Simulator | 116.9 | 463 | 16.3 KB | 897.5 KB | 0 | 0 B | 228 | 29.7 MB | 114 | 4.1 |
| mac-a-after-move | Mac | 68.3 | 10 | 198 B | 255.0 KB | 0 | 0 B | 0 | 0 B |  |  |
| sim-b-after-move | Simulator | 70.7 | 12 | 201 B | 380.6 KB | 0 | 0 B | 0 | 0 B |  |  |
| sim-a-after-move | Simulator | 68.6 | 31 | 1.0 KB | 281.8 KB | 0 | 0 B | 12 | 2.1 MB | 6 | 5.2 |
| sim-b-idle | Simulator | 116.9 | 459 | 16.2 KB | 891.0 KB | 0 | 0 B | 226 | 29.3 MB | 113 | 4.1 |

Library A on the Simulator: `457D3FBD-E366-4669-BB5B-81419A24B657`. Library B (created by the run): `D890C309-EC0B-4E71-813F-9F1CB4BB74D6`.
Moved on the server from A to B: {"origin": "89345046-965f-4821-aaae-c10546fbd60d", "title": "16c080c7-a9b0-426c-8a53-a6975815bda7.jpg", "result": {"moved": 1, "unchanged": 0, "unknown": []}}

Libraries on the account before:

```
[
 {
  "uuid": "8f3aa852-afe5-43c9-80a5-caaaf9f40c19",
  "name": "synth",
  "projects": {
   "count": 115,
   "by_type": {
    "photo": 115,
    "interval": 0,
    "video": 0
   }
  },
  "used_bytes": 160449432,
  "originals": 115,
  "created_by": {
   "id": "01a0f2f0-4276-71c9-a524-44f07fd10869",
   "name": "macbookpro",
   "platform": "macos",
   "revoked_at": null
  },
  "updated_by": {
   "id": "01a0f2f0-4276-71c9-a524-44f07fd10869",
   "name": "macbookpro",
   "platform": "macos",
   "revoked_at": null
  },
  "created_at": "2026-09-30T15:31:08+00:00",
  "updated_at": "2026-09-30T15:31:08+00:00",
  "deleted_at": null,
  "deleted_by": null
 }
]
```
after:

```
[
 {
  "uuid": "8f3aa852-afe5-43c9-80a5-caaaf9f40c19",
  "name": "synth",
  "projects": {
   "count": 114,
   "by_type": {
    "photo": 114,
    "interval": 0,
    "video": 0
   }
  },
  "used_bytes": 155443892,
  "originals": 114,
  "created_by": {
   "id": "01a0f2f0-4276-71c9-a524-44f07fd10869",
   "name": "macbookpro",
   "platform": "macos",
   "revoked_at": null
  },
  "updated_by": {
   "id": "01a0f2f0-4276-71c9-a524-44f07fd10869",
   "name": "macbookpro",
   "platform": "macos",
   "revoked_at": null
  },
  "created_at": "2026-09-30T15:31:08+00:00",
  "updated_at": "2026-09-30T15:31:08+00:00",
  "deleted_at": null,
  "deleted_by": null
 },
 {
  "uuid": "4e593426-7411-47ef-88a6-ff9013ca3d1a",
  "name": "synth two",
  "projects": {
   "count": 7,
   "by_type": {
    "photo": 7,
    "interval": 0,
    "video": 0
   }
  },
  "used_bytes": 23099178,
  "originals": 7,
  "created_by": {
   "id": "01a0f302-793c-7229-978a-9b6e33985a8a",
   "name": "LetsLapse Fresh",
   "platform": "ios",
   "revoked_at": null
  },
  "updated_by": {
   "id": "01a0f302-793c-7229-978a-9b6e33985a8a",
   "name": "LetsLapse Fresh",
   "platform": "ios",
   "revoked_at": null
  },
  "created_at": "2026-10-01T11:52:03+00:00",
  "updated_at": "2026-10-01T11:52:03+00:00",
  "deleted_at": null,
  "deleted_by": null
 }
]
```

Sync-state files at the end: Mac 71.5 KB, Simulator 65.1 KB.

## Server, start → end

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| asset_replaced | 2 | 0 B | 0 B |
| copy_confirmed | 5 | 0 B | 0 B |
| download_url_issued | 694 | 0 B | 90.8 MB |
| manifest_written | 11 | 5.3 KB | 0 B |
| project_restored | 1 | 0 B | 0 B |
| upload_confirmed | 12 | 2.1 MB | 0 B |

Account tables at the end:

| Table | Value |
|---|---|
| projects live / trashed | 121 / 2 |
| projects by type | {"interval": 1, "photo": 122} |
| manifest bytes | 63.8 KB |
| assets | preview confirmed: 123 (32.0 MB); records confirmed: 123 (589.3 KB); source confirmed: 123 (138.9 MB) |
| presences by tier | {"original": 118, "preview": 122} |
| index rows / name NULL / records indexed | 123 / 122 / 0 |
| pending uploads | 0 |

## 1. sim-a-baseline — Simulator

_Simulator on library A: one launch, its checks._ 13:50:45 → 13:51:55 (70.5 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 8 | 38 | 0 B | 17.2 KB |  |
| POST device | 2 | 42 | 402 B | 896 B |  |
| GET projects?include_deleted=1 | 2 | 42 | 0 B | 232.3 KB |  |
| GET projects | 1 | 34 | 0 B | 113.2 KB |  |
| **total** | 13 | 39 | 402 B | 363.5 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
13:50:49.098 picplace: pacing requests under 300/min (255/min for sync work)
13:50:49.110 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
13:50:49.342 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/01-sim-a-baseline.log`](raw/01-sim-a-baseline.log) · projects on the Mac 115 → 115, on the Simulator 115 → 115.

## 2. sim-new-library — Simulator

_create library “synth two” on PicPlace from the phone's Libraries section (the real door), which switches to it._ 13:51:58 → 13:53:11 (72.5 s). Hooks: `LL_SCROLL=libraries`, `LL_LIBRARY=new:synth two`

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 16 | 63 | 0 B | 37.5 KB |  |
| GET projects | 6 | 48 | 0 B | 679.0 KB |  |
| GET projects?include_deleted=1 | 2 | 68 | 0 B | 232.3 KB |  |
| POST device | 2 | 30 | 402 B | 896 B |  |
| PUT libraries/{u} | 1 | 60 | 42 B | 543 B |  |
| **total** | 27 | 58 | 444 B | 950.2 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
13:52:01.512 picplace: pacing requests under 300/min (255/min for sync work)
13:52:01.589 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
13:52:01.947 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
13:52:03.280 picplace: library “synth two” 4e593426-7411-47ef-88a6-ff9013ca3d1a created on picplace.test and placed in Libraries/D890C309-EC0B-4E71-813F-9F1CB4BB74D6
13:52:03.337 luts: 0 imported LUT(s) at /Users/stevenwright/Library/Developer/CoreSimulator/Devices/C8F8FCC2-5DBC-4B87-B7FE-06D1085C7996/data/Containers/Data/Application/FC3F00DF-A287-4A2E-8EF7-C5BA12F4DBEF/Library/Application Support/LetsLapse/Libraries/D890C309-EC0B-4E71-813F-9F1CB4BB74D6/luts
13:52:03.337 luts: 0 imported LUT(s) at /Users/stevenwright/Library/Developer/CoreSimulator/Devices/C8F8FCC2-5DBC-4B87-B7FE-06D1085C7996/data/Containers/Data/Application/FC3F00DF-A287-4A2E-8EF7-C5BA12F4DBEF/Library/Application Support/LetsLapse/Libraries/D890C309-EC0B-4E71-813F-9F1CB4BB74D6/luts
13:52:03.609 picplace: pacing requests under 300/min (255/min for sync work)
13:52:03.792 picplace: initial sync (clean) — 0 to pull, 0 to push, 0 in step, 0 deferred
13:52:03.792 picplace: initial sync done (clean)
```

Full log: [`raw/02-sim-new-library.log`](raw/02-sim-new-library.log) · projects on the Mac 115 → 115, on the Simulator 115 → 115.

## 3. sim-b-import — Simulator

_library B: import 5 photo(s) whose bytes library A already holds, and 2 .lapse project(s) library A already holds (twins by origin); originals on._ 13:53:14 → 13:54:24 (70.6 s). Hooks: `LL_IMPORT_STILLS=/Users/stevenwright/Documents/dev/letslapse-testing/flat-jpegs/16c080c7-a9b0-426c-8a53-a6975815bda7.jpg:/Users/stevenwright/Documents/dev/letslapse-testing/flat-jpegs/3db344e3-5a1b-4be4-816e-b5d3ffb97…`, `LL_IMPORT_ANSWER=photos`, `LL_IMPORT_ARCHIVE=/Users/stevenwright/Documents/dev/letslapse-testing/synth-lapse/archives/broad-mix--buildings.01.lapse:/Users/stevenwright/Documents/dev/letslapse-testing/synth-lapse/archives/broad-mix--buildings.02.…`

New projects on the Simulator: 7, 17.9 MB on disk.

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| POST projects/{u}/claim | 11 | 27 | 220 B | 78.0 KB | 1 |
| PUT projects/{u} | 11 | 41 | 7.0 KB | 10.4 KB |  |
| POST projects/{u}/assets | 11 | 40 | 3.0 KB | 19.1 KB |  |
| POST projects/{u}/presence | 11 | 24 | 484 B | 2.5 KB |  |
| DELETE projects/{u}/claim | 11 | 22 | 0 B | 154 B |  |
| GET status | 10 | 56 | 0 B | 26.6 KB |  |
| POST projects/{u}/assets/confirm | 6 | 40 | 1.5 KB | 6.3 KB |  |
| GET projects/{u} | 6 | 30 | 0 B | 14.2 KB |  |
| GET projects?include_deleted=1 | 2 | 58 | 0 B | 232.4 KB |  |
| GET projects | 2 | 62 | 0 B | 231.4 KB |  |
| POST device | 1 | 60 | 201 B | 448 B |  |
| **total** | 82 | 36 | 12.4 KB | 621.4 KB | 1 |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| PUT poster.jpg | 6 | 2.1 MB | 13 |
| PUT records.aar | 6 | 15.0 KB | 7 |
| **total** | 12 | 2.1 MB | 10 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| asset_replaced | 2 | 0 B | 0 B |
| copy_confirmed | 5 | 0 B | 0 B |
| manifest_written | 11 | 5.3 KB | 0 B |
| project_restored | 1 | 0 B | 0 B |
| upload_confirmed | 12 | 2.1 MB | 0 B |

**Log highlights**

```
13:53:16.500 assets: 6A1A8A57 recorded 1 of 1 pending (1 assets)
13:53:17.065 assets: 40A4CE4B recorded 1 of 1 pending (1 assets)
13:53:17.068 assets: 231294E0 recorded 1 of 1 pending (1 assets)
13:53:17.150 assets: 7857711B recorded 1 of 1 pending (1 assets)
13:53:17.180 picplace: check (foreground) — 0 pulled, 0 updated, 3 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
13:53:17.181 picplace: pacing requests under 300/min (255/min for sync work)
13:53:17.232 assets: DB154262 recorded 1 of 1 pending (1 assets)
13:53:17.255 assets: 7AE80F75 recorded 1 of 1 pending (1 assets)
13:53:17.283 assets: B6554157 recorded 1 of 1 pending (1 assets)
13:53:17.449 picplace: check (launch) — 0 pulled, 0 updated, 5 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
13:53:17.453 picplace: buildings.01 — uploading 2 of 2 file(s), 271 KB
13:53:17.969 picplace: 5b503e1f-30b9-4037-91ce-8d5a6e7fe856 — uploading 2 of 2 file(s), 430 KB
13:53:18.270 picplace: 3db344e3-5a1b-4be4-816e-b5d3ffb97d11 — uploading 2 of 2 file(s), 419 KB
13:53:18.508 picplace: broad-mix--arches.01 — uploading 2 of 2 file(s), 292 KB
13:53:18.905 picplace: 16c080c7-a9b0-426c-8a53-a6975815bda7 — uploading 2 of 2 file(s), 459 KB
13:53:19.202 picplace: broad-mix--arches.02 — uploading 2 of 2 file(s), 301 KB
13:53:19.303 picplace: push queue — 6 sent, 0 failed
```

Full log: [`raw/03-sim-b-import.log`](raw/03-sim-b-import.log) · projects on the Mac 115 → 115, on the Simulator 0 → 7.

## 4. mac-a-check — Mac

_Mac on library A after library B gained projects: does anything of B arrive?._ 13:54:27 → 13:55:38 (70.2 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 6 | 41 | 0 B | 15.6 KB |  |
| POST device | 2 | 26 | 396 B | 890 B |  |
| GET nearby/key | 1 | 20 | 0 B | 135 B |  |
| GET projects | 1 | 67 | 0 B | 118.2 KB |  |
| GET projects?include_deleted=1 | 1 | 43 | 0 B | 120.3 KB |  |
| POST projects/assets | 1 | 26 | 148 B | 1.9 KB |  |
| **total** | 12 | 38 | 544 B | 256.9 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
13:54:30.098 picplace: pacing requests under 300/min (255/min for sync work)
13:54:30.388 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 3 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/04-mac-a-check.log`](raw/04-mac-a-check.log) · projects on the Mac 115 → 115, on the Simulator 7 → 7.

## 5. sim-b-check — Simulator

_library B idle check: what a small library pays for the account's big one._ 13:55:41 → 13:57:37 (116.9 s). Hooks: none beyond the trace

New projects on the Simulator: 114, 31.7 MB on disk.

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| POST projects/{u}/assets/urls | 228 | 20 | 11.4 KB | 267.4 KB |  |
| GET projects/{u} | 114 | 22 | 0 B | 334.2 KB |  |
| POST projects/{u}/presence | 114 | 19 | 4.8 KB | 46.3 KB |  |
| GET status | 4 | 59 | 0 B | 10.7 KB |  |
| GET projects?include_deleted=1 | 1 | 77 | 0 B | 120.3 KB |  |
| POST device | 1 | 55 | 201 B | 448 B |  |
| GET projects | 1 | 58 | 0 B | 118.2 KB |  |
| **total** | 463 | 21 | 16.3 KB | 897.5 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| GET poster.jpg | 114 | 29.2 MB | 8 |
| GET records.aar | 114 | 554.3 KB | 4 |
| **total** | 228 | 29.7 MB | 6 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| download_url_issued | 228 | 0 B | 29.7 MB |

**Log highlights**

```
13:55:43.269 picplace: pacing requests under 300/min (255/min for sync work)
13:55:43.455 picplace: pulled Photo 29. 7. at 1554 (c58eda80) — 2 object(s), 459972 bytes; 1 heavy file(s) stay on PicPlace
13:55:43.554 picplace: pulled 8b672eb3-5221-4df3-beef-d69b6f1c292c (5bddd7f8) — 2 object(s), 380696 bytes; 1 heavy file(s) stay on PicPlace
13:55:43.654 picplace: pulled 6daeaac6-dcb8-4cac-b873-cd9bb4536bc9 (0e6ff819) — 2 object(s), 270993 bytes; 1 heavy file(s) stay on PicPlace
13:55:43.756 picplace: pulled building.01 (2eca2cb8) — 2 object(s), 234421 bytes; 1 heavy file(s) stay on PicPlace
13:55:43.881 picplace: pulled arch.01 (84a1e3ef) — 2 object(s), 340887 bytes; 1 heavy file(s) stay on PicPlace
13:55:43.967 picplace: pulled single.oldtown.dusk.near (b1a2848f) — 2 object(s), 215906 bytes; 1 heavy file(s) stay on PicPlace
13:55:44.068 picplace: pulled windows.05 (678416d9) — 2 object(s), 278467 bytes; 1 heavy file(s) stay on PicPlace
13:55:44.174 picplace: pulled windows.06 (33e92519) — 2 object(s), 278623 bytes; 1 heavy file(s) stay on PicPlace
13:55:44.277 picplace: pulled windows.02 (b9d0931f) — 2 object(s), 347679 bytes; 1 heavy file(s) stay on PicPlace
13:55:44.415 picplace: pulled windows.03 (ae73cffc) — 2 object(s), 312399 bytes; 1 heavy file(s) stay on PicPlace
13:55:44.541 picplace: pulled windows.04 (3a74d0ec) — 2 object(s), 280593 bytes; 1 heavy file(s) stay on PicPlace
13:55:44.648 picplace: pulled tram.01 (a3341acd) — 2 object(s), 313176 bytes; 1 heavy file(s) stay on PicPlace
13:55:44.729 picplace: pulled windows.01 (75186093) — 2 object(s), 235769 bytes; 1 heavy file(s) stay on PicPlace
13:55:44.820 picplace: pulled trams-nature.04 (7374b86d) — 2 object(s), 298335 bytes; 1 heavy file(s) stay on PicPlace
13:55:44.939 picplace: pulled trams-nature.01 (f7d6b37d) — 2 object(s), 328502 bytes; 1 heavy file(s) stay on PicPlace
13:55:45.063 picplace: pulled trams-nature.02 (a0ac51bc) — 2 object(s), 369071 bytes; 1 heavy file(s) stay on PicPlace
13:55:45.189 picplace: pulled trams-nature.03 (5e187e7b) — 2 object(s), 327344 bytes; 1 heavy file(s) stay on PicPlace
13:55:45.306 picplace: pulled trams-city.09 (7bf05aa4) — 2 object(s), 349066 bytes; 1 heavy file(s) stay on PicPlace
13:55:45.422 picplace: pulled trams-city.08 (3ff9b459) — 2 object(s), 301246 bytes; 1 heavy file(s) stay on PicPlace
13:55:45.529 picplace: pulled trams-city.07 (05ef54ce) — 2 object(s), 282227 bytes; 1 heavy file(s) stay on PicPlace
13:55:45.637 picplace: pulled trams-city.06 (6130b2d3) — 2 object(s), 253158 bytes; 1 heavy file(s) stay on PicPlace
13:55:45.759 picplace: pulled trams-city.05 (fe2f247a) — 2 object(s), 280768 bytes; 1 heavy file(s) stay on PicPlace
13:55:45.887 picplace: pulled trams-city.04 (87b3e188) — 2 object(s), 255047 bytes; 1 heavy file(s) stay on PicPlace
13:55:46.014 picplace: pulled trams-city.03 (eb7840a9) — 2 object(s), 282025 bytes; 1 heavy file(s) stay on PicPlace
13:55:46.147 picplace: pulled trams-city.02 (f59b627a) — 2 object(s), 287513 bytes; 1 heavy file(s) stay on PicPlace
13:55:46.269 picplace: pulled trams-city.01 (ecf04312) — 2 object(s), 331038 bytes; 1 heavy file(s) stay on PicPlace
13:55:46.391 picplace: pulled flower.12 (29f7b6a2) — 2 object(s), 280431 bytes; 1 heavy file(s) stay on PicPlace
13:55:46.502 picplace: pulled flower.11 (95a0fd62) — 2 object(s), 253686 bytes; 1 heavy file(s) stay on PicPlace
13:55:46.619 picplace: pulled flower.10 (ad09dd9a) — 2 object(s), 282673 bytes; 1 heavy file(s) stay on PicPlace
… 57 line(s) left out …
13:56:46.365 picplace: pulled doors-16x9.09 (058d5860) — 2 object(s), 197490 bytes; 1 heavy file(s) stay on PicPlace
13:56:46.438 picplace: pulled doors-16x9.08 (dfd602f0) — 2 object(s), 178055 bytes; 1 heavy file(s) stay on PicPlace
13:56:46.517 picplace: pulled doors-16x9.07 (95447be9) — 2 object(s), 127490 bytes; 1 heavy file(s) stay on PicPlace
13:56:46.595 picplace: pulled doors-16x9.06 (1aa8115a) — 2 object(s), 224333 bytes; 1 heavy file(s) stay on PicPlace
13:56:46.690 picplace: pulled doors-16x9.05 (cd68ba59) — 2 object(s), 223673 bytes; 1 heavy file(s) stay on PicPlace
13:56:46.768 picplace: pulled doors-16x9.04 (c7895a1b) — 2 object(s), 252262 bytes; 1 heavy file(s) stay on PicPlace
13:56:46.842 picplace: pulled doors-16x9.03 (c77a835d) — 2 object(s), 150479 bytes; 1 heavy file(s) stay on PicPlace
13:56:46.924 picplace: pulled doors-16x9.02 (4e3b0c8b) — 2 object(s), 220442 bytes; 1 heavy file(s) stay on PicPlace
13:56:47.007 picplace: pulled doors.07 (af51f042) — 2 object(s), 305809 bytes; 1 heavy file(s) stay on PicPlace
13:56:47.092 picplace: pulled doors.08 (a7021357) — 2 object(s), 274965 bytes; 1 heavy file(s) stay on PicPlace
13:56:47.178 picplace: pulled doors-16x9.01 (94b80fca) — 2 object(s), 169505 bytes; 1 heavy file(s) stay on PicPlace
13:56:47.264 picplace: pulled doors.05 (8573257b) — 2 object(s), 317061 bytes; 1 heavy file(s) stay on PicPlace
13:56:47.345 picplace: pulled doors.03 (667cc77b) — 2 object(s), 324812 bytes; 1 heavy file(s) stay on PicPlace
13:56:47.436 picplace: pulled doors.06 (566cde9a) — 2 object(s), 344398 bytes; 1 heavy file(s) stay on PicPlace
13:56:47.520 picplace: pulled doors.04 (3cfc2584) — 2 object(s), 302713 bytes; 1 heavy file(s) stay on PicPlace
13:56:47.680 picplace: pulled doors.01 (e78a74d0) — 2 object(s), 293935 bytes; 1 heavy file(s) stay on PicPlace
13:56:47.779 picplace: pulled doors.02 (8d891d8f) — 2 object(s), 313894 bytes; 1 heavy file(s) stay on PicPlace
13:56:47.955 picplace: pulled 5b503e1f-30b9-4037-91ce-8d5a6e7fe856 (49a122c5) — 2 object(s), 390101 bytes; 1 heavy file(s) stay on PicPlace
13:56:48.063 picplace: pulled 16c080c7-a9b0-426c-8a53-a6975815bda7 (89345046) — 2 object(s), 384335 bytes; 1 heavy file(s) stay on PicPlace
13:56:48.161 picplace: pulled 3db344e3-5a1b-4be4-816e-b5d3ffb97d11 (482031c0) — 2 object(s), 336252 bytes; 1 heavy file(s) stay on PicPlace
13:56:48.255 picplace: pulled broad-mix--arches.05 (ffe59492) — 2 object(s), 461628 bytes; 1 heavy file(s) stay on PicPlace
13:56:48.352 picplace: pulled broad-mix--arches.03 (fc972c8f) — 2 object(s), 348076 bytes; 1 heavy file(s) stay on PicPlace
13:56:48.521 picplace: pulled broad-mix--arches.01 (cccb017c) — 2 object(s), 292279 bytes; 1 heavy file(s) stay on PicPlace
13:56:48.626 picplace: pulled broad-mix--arches.04 (9d7e7143) — 2 object(s), 293481 bytes; 1 heavy file(s) stay on PicPlace
13:56:48.728 picplace: pulled ae1fa114-51a5-4f29-b101-94eaead64d00 (37ebdfb2) — 2 object(s), 327550 bytes; 1 heavy file(s) stay on PicPlace
13:56:48.827 picplace: pulled broad-mix--arches.02 (1b3132ae) — 2 object(s), 301031 bytes; 1 heavy file(s) stay on PicPlace
13:56:48.920 picplace: pulled Photo 29. 7. at 1614 (a2b269d5) — 2 object(s), 272606 bytes; 1 heavy file(s) stay on PicPlace
13:56:49.013 picplace: pulled Photo of rocks (92d074da) — 2 object(s), 412310 bytes; 1 heavy file(s) stay on PicPlace
13:56:49.014 picplace: check (foreground) — 114 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 1 conflict(s)
13:56:49.018 picplace: conflict — buildings.02 (8206C7F5) unrelated: local 1551564060000 vs server 1790834715164 from macbookpro
```

Full log: [`raw/05-sim-b-check.log`](raw/05-sim-b-check.log) · projects on the Mac 115 → 115, on the Simulator 7 → 121.

## 6. mac-a-launch-2 — Mac

_Mac on A again, nothing changed (the move was refused: the bench's token had no device)._ 13:59:20 → 14:00:28 (68.3 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 6 | 33 | 0 B | 15.6 KB |  |
| POST device | 1 | 25 | 198 B | 445 B |  |
| GET nearby/key | 1 | 12 | 0 B | 135 B |  |
| GET projects | 1 | 39 | 0 B | 118.2 KB |  |
| GET projects?include_deleted=1 | 1 | 37 | 0 B | 120.3 KB |  |
| **total** | 10 | 31 | 198 B | 254.6 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
13:59:21.579 picplace: pacing requests under 300/min (255/min for sync work)
13:59:21.783 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/06-mac-a-after-move.log`](raw/06-mac-a-after-move.log) · projects on the Mac 115 → 115, on the Simulator 121 → 121.

## 7. sim-b-launch-2 — Simulator

_library B launched again, nothing changed on the server._ 14:00:32 → 14:01:42 (70.7 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 8 | 51 | 0 B | 21.3 KB |  |
| GET projects?include_deleted=1 | 2 | 52 | 0 B | 240.5 KB |  |
| POST device | 1 | 29 | 201 B | 448 B |  |
| GET projects | 1 | 41 | 0 B | 118.2 KB |  |
| **total** | 12 | 48 | 201 B | 380.5 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
14:00:34.557 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 1 conflict(s)
14:00:34.559 picplace: conflict — buildings.02 (8206C7F5) unrelated: local 1551564060000 vs server 1790834715164 from macbookpro
14:00:34.566 picplace: pacing requests under 300/min (255/min for sync work)
14:00:35.000 picplace: check — 114 preview(s) of other libraries' projects removed from this library (folders and index rows only; no tombstones)
14:00:35.003 picplace: check (launch) — 0 pulled, 0 updated, 114 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 114 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/07-sim-b-after-move.log`](raw/07-sim-b-after-move.log) · projects on the Mac 115 → 115, on the Simulator 121 → 7.

## 8. sim-a-launch-2 — Simulator

_library A launched again, nothing changed on the server._ 14:01:45 → 14:02:56 (70.6 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 8 | 60 | 0 B | 21.3 KB |  |
| GET projects?include_deleted=1 | 2 | 62 | 0 B | 240.5 KB |  |
| POST device | 1 | 46 | 201 B | 448 B |  |
| GET projects | 1 | 35 | 0 B | 118.2 KB |  |
| **total** | 12 | 57 | 201 B | 380.5 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
14:01:49.270 picplace: pacing requests under 300/min (255/min for sync work)
14:01:49.299 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
14:01:49.543 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/08-sim-a-after-move.log`](raw/08-sim-a-after-move.log) · projects on the Mac 115 → 115, on the Simulator 115 → 115.

## 9. sim-b-launch-3 — Simulator

_library B launched a third time, nothing changed on the server._ 14:02:59 → 14:04:56 (116.9 s). Hooks: none beyond the trace

New projects on the Simulator: 114, 31.7 MB on disk.

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| POST projects/{u}/assets/urls | 228 | 22 | 11.4 KB | 267.4 KB |  |
| GET projects/{u} | 114 | 24 | 0 B | 334.2 KB |  |
| POST projects/{u}/presence | 114 | 20 | 4.8 KB | 46.3 KB |  |
| GET status | 4 | 64 | 0 B | 10.7 KB |  |
| GET projects?include_deleted=1 | 1 | 51 | 0 B | 120.3 KB |  |
| POST device | 1 | 33 | 201 B | 448 B |  |
| GET projects | 1 | 57 | 0 B | 118.2 KB |  |
| **total** | 463 | 22 | 16.3 KB | 897.5 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| GET poster.jpg | 114 | 29.2 MB | 9 |
| GET records.aar | 114 | 554.3 KB | 4 |
| **total** | 228 | 29.7 MB | 6 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| download_url_issued | 228 | 0 B | 29.7 MB |

**Log highlights**

```
14:03:01.709 picplace: pacing requests under 300/min (255/min for sync work)
14:03:01.862 picplace: pulled Photo 29. 7. at 1554 (c58eda80) — 2 object(s), 459972 bytes; 1 heavy file(s) stay on PicPlace
14:03:01.976 picplace: pulled 8b672eb3-5221-4df3-beef-d69b6f1c292c (5bddd7f8) — 2 object(s), 380696 bytes; 1 heavy file(s) stay on PicPlace
14:03:02.069 picplace: pulled 6daeaac6-dcb8-4cac-b873-cd9bb4536bc9 (0e6ff819) — 2 object(s), 270993 bytes; 1 heavy file(s) stay on PicPlace
14:03:02.168 picplace: pulled building.01 (2eca2cb8) — 2 object(s), 234421 bytes; 1 heavy file(s) stay on PicPlace
14:03:02.280 picplace: pulled arch.01 (84a1e3ef) — 2 object(s), 340887 bytes; 1 heavy file(s) stay on PicPlace
14:03:02.388 picplace: pulled single.oldtown.dusk.near (b1a2848f) — 2 object(s), 215906 bytes; 1 heavy file(s) stay on PicPlace
14:03:02.504 picplace: pulled windows.05 (678416d9) — 2 object(s), 278467 bytes; 1 heavy file(s) stay on PicPlace
14:03:02.622 picplace: pulled windows.06 (33e92519) — 2 object(s), 278623 bytes; 1 heavy file(s) stay on PicPlace
14:03:02.732 picplace: pulled windows.02 (b9d0931f) — 2 object(s), 347679 bytes; 1 heavy file(s) stay on PicPlace
14:03:02.851 picplace: pulled windows.03 (ae73cffc) — 2 object(s), 312399 bytes; 1 heavy file(s) stay on PicPlace
14:03:02.972 picplace: pulled windows.04 (3a74d0ec) — 2 object(s), 280593 bytes; 1 heavy file(s) stay on PicPlace
14:03:03.087 picplace: pulled tram.01 (a3341acd) — 2 object(s), 313176 bytes; 1 heavy file(s) stay on PicPlace
14:03:03.195 picplace: pulled windows.01 (75186093) — 2 object(s), 235769 bytes; 1 heavy file(s) stay on PicPlace
14:03:03.301 picplace: pulled trams-nature.04 (7374b86d) — 2 object(s), 298335 bytes; 1 heavy file(s) stay on PicPlace
14:03:03.410 picplace: pulled trams-nature.01 (f7d6b37d) — 2 object(s), 328502 bytes; 1 heavy file(s) stay on PicPlace
14:03:03.522 picplace: pulled trams-nature.02 (a0ac51bc) — 2 object(s), 369071 bytes; 1 heavy file(s) stay on PicPlace
14:03:03.628 picplace: pulled trams-nature.03 (5e187e7b) — 2 object(s), 327344 bytes; 1 heavy file(s) stay on PicPlace
14:03:03.734 picplace: pulled trams-city.09 (7bf05aa4) — 2 object(s), 349066 bytes; 1 heavy file(s) stay on PicPlace
14:03:03.840 picplace: pulled trams-city.08 (3ff9b459) — 2 object(s), 301246 bytes; 1 heavy file(s) stay on PicPlace
14:03:03.956 picplace: pulled trams-city.07 (05ef54ce) — 2 object(s), 282227 bytes; 1 heavy file(s) stay on PicPlace
14:03:04.080 picplace: pulled trams-city.06 (6130b2d3) — 2 object(s), 253158 bytes; 1 heavy file(s) stay on PicPlace
14:03:04.169 picplace: pulled trams-city.05 (fe2f247a) — 2 object(s), 280768 bytes; 1 heavy file(s) stay on PicPlace
14:03:04.253 picplace: pulled trams-city.04 (87b3e188) — 2 object(s), 255047 bytes; 1 heavy file(s) stay on PicPlace
14:03:04.353 picplace: pulled trams-city.03 (eb7840a9) — 2 object(s), 282025 bytes; 1 heavy file(s) stay on PicPlace
14:03:04.471 picplace: pulled trams-city.02 (f59b627a) — 2 object(s), 287513 bytes; 1 heavy file(s) stay on PicPlace
14:03:04.588 picplace: pulled trams-city.01 (ecf04312) — 2 object(s), 331038 bytes; 1 heavy file(s) stay on PicPlace
14:03:04.715 picplace: pulled flower.12 (29f7b6a2) — 2 object(s), 280431 bytes; 1 heavy file(s) stay on PicPlace
14:03:04.851 picplace: pulled flower.11 (95a0fd62) — 2 object(s), 253686 bytes; 1 heavy file(s) stay on PicPlace
14:03:04.991 picplace: pulled flower.10 (ad09dd9a) — 2 object(s), 282673 bytes; 1 heavy file(s) stay on PicPlace
… 57 line(s) left out …
14:04:05.569 picplace: pulled doors-16x9.09 (058d5860) — 2 object(s), 197490 bytes; 1 heavy file(s) stay on PicPlace
14:04:05.648 picplace: pulled doors-16x9.08 (dfd602f0) — 2 object(s), 178055 bytes; 1 heavy file(s) stay on PicPlace
14:04:05.738 picplace: pulled doors-16x9.07 (95447be9) — 2 object(s), 127490 bytes; 1 heavy file(s) stay on PicPlace
14:04:05.824 picplace: pulled doors-16x9.06 (1aa8115a) — 2 object(s), 224333 bytes; 1 heavy file(s) stay on PicPlace
14:04:05.913 picplace: pulled doors-16x9.05 (cd68ba59) — 2 object(s), 223673 bytes; 1 heavy file(s) stay on PicPlace
14:04:06.004 picplace: pulled doors-16x9.04 (c7895a1b) — 2 object(s), 252262 bytes; 1 heavy file(s) stay on PicPlace
14:04:06.098 picplace: pulled doors-16x9.03 (c77a835d) — 2 object(s), 150479 bytes; 1 heavy file(s) stay on PicPlace
14:04:06.187 picplace: pulled doors-16x9.02 (4e3b0c8b) — 2 object(s), 220442 bytes; 1 heavy file(s) stay on PicPlace
14:04:06.274 picplace: pulled doors.07 (af51f042) — 2 object(s), 305809 bytes; 1 heavy file(s) stay on PicPlace
14:04:06.373 picplace: pulled doors.08 (a7021357) — 2 object(s), 274965 bytes; 1 heavy file(s) stay on PicPlace
14:04:06.468 picplace: pulled doors-16x9.01 (94b80fca) — 2 object(s), 169505 bytes; 1 heavy file(s) stay on PicPlace
14:04:06.566 picplace: pulled doors.05 (8573257b) — 2 object(s), 317061 bytes; 1 heavy file(s) stay on PicPlace
14:04:06.661 picplace: pulled doors.03 (667cc77b) — 2 object(s), 324812 bytes; 1 heavy file(s) stay on PicPlace
14:04:06.763 picplace: pulled doors.06 (566cde9a) — 2 object(s), 344398 bytes; 1 heavy file(s) stay on PicPlace
14:04:06.868 picplace: pulled doors.04 (3cfc2584) — 2 object(s), 302713 bytes; 1 heavy file(s) stay on PicPlace
14:04:06.982 picplace: pulled doors.01 (e78a74d0) — 2 object(s), 293935 bytes; 1 heavy file(s) stay on PicPlace
14:04:07.080 picplace: pulled doors.02 (8d891d8f) — 2 object(s), 313894 bytes; 1 heavy file(s) stay on PicPlace
14:04:07.172 picplace: pulled 5b503e1f-30b9-4037-91ce-8d5a6e7fe856 (49a122c5) — 2 object(s), 390101 bytes; 1 heavy file(s) stay on PicPlace
14:04:07.273 picplace: pulled 16c080c7-a9b0-426c-8a53-a6975815bda7 (89345046) — 2 object(s), 384335 bytes; 1 heavy file(s) stay on PicPlace
14:04:07.383 picplace: pulled 3db344e3-5a1b-4be4-816e-b5d3ffb97d11 (482031c0) — 2 object(s), 336252 bytes; 1 heavy file(s) stay on PicPlace
14:04:07.471 picplace: pulled broad-mix--arches.05 (ffe59492) — 2 object(s), 461628 bytes; 1 heavy file(s) stay on PicPlace
14:04:07.554 picplace: pulled broad-mix--arches.03 (fc972c8f) — 2 object(s), 348076 bytes; 1 heavy file(s) stay on PicPlace
14:04:07.643 picplace: pulled broad-mix--arches.01 (cccb017c) — 2 object(s), 292279 bytes; 1 heavy file(s) stay on PicPlace
14:04:07.729 picplace: pulled broad-mix--arches.04 (9d7e7143) — 2 object(s), 293481 bytes; 1 heavy file(s) stay on PicPlace
14:04:07.829 picplace: pulled ae1fa114-51a5-4f29-b101-94eaead64d00 (37ebdfb2) — 2 object(s), 327550 bytes; 1 heavy file(s) stay on PicPlace
14:04:07.933 picplace: pulled broad-mix--arches.02 (1b3132ae) — 2 object(s), 301031 bytes; 1 heavy file(s) stay on PicPlace
14:04:08.040 picplace: pulled Photo 29. 7. at 1614 (a2b269d5) — 2 object(s), 272606 bytes; 1 heavy file(s) stay on PicPlace
14:04:08.155 picplace: pulled Photo of rocks (92d074da) — 2 object(s), 412310 bytes; 1 heavy file(s) stay on PicPlace
14:04:08.158 picplace: check (foreground) — 114 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 1 conflict(s)
14:04:08.161 picplace: conflict — buildings.02 (8206C7F5) unrelated: local 1551564060000 vs server 1790834715164 from macbookpro
```

Full log: [`raw/09-sim-b-idle.log`](raw/09-sim-b-idle.log) · projects on the Mac 115 → 115, on the Simulator 7 → 121.

## 10. mac-a-after-move — Mac

_Mac on A after “16c080c7-a9b0-426c-8a53-a6975815bda7.jpg” (89345046) was filed under B on the server._ 14:05:40 → 14:06:49 (68.3 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 6 | 42 | 0 B | 15.9 KB |  |
| POST device | 1 | 28 | 198 B | 445 B |  |
| GET nearby/key | 1 | 15 | 0 B | 135 B |  |
| GET projects | 1 | 39 | 0 B | 118.2 KB |  |
| GET projects?include_deleted=1 | 1 | 51 | 0 B | 120.3 KB |  |
| **total** | 10 | 38 | 198 B | 255.0 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
14:05:41.812 picplace: pacing requests under 300/min (255/min for sync work)
14:05:42.053 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/10-mac-a-after-move.log`](raw/10-mac-a-after-move.log) · projects on the Mac 115 → 115, on the Simulator 121 → 121.

## 11. sim-b-after-move — Simulator

_library B after the move: the project arrives._ 14:06:52 → 14:08:02 (70.7 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 8 | 62 | 0 B | 21.3 KB |  |
| GET projects?include_deleted=1 | 2 | 66 | 0 B | 240.6 KB |  |
| POST device | 1 | 60 | 201 B | 448 B |  |
| GET projects | 1 | 62 | 0 B | 118.2 KB |  |
| **total** | 12 | 62 | 201 B | 380.6 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
14:06:54.524 picplace: pacing requests under 300/min (255/min for sync work)
14:06:54.677 picplace: check — 113 preview(s) of other libraries' projects removed from this library (folders and index rows only; no tombstones)
14:06:54.682 picplace: check (foreground) — 0 pulled, 0 updated, 113 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 113 other libraries' previews removed, 0 conflict(s)
14:06:54.975 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/11-sim-b-after-move.log`](raw/11-sim-b-after-move.log) · projects on the Mac 115 → 115, on the Simulator 121 → 8.

## 12. sim-a-after-move — Simulator

_the Simulator back on library A: its preview of the moved project._ 14:08:05 → 14:09:14 (68.6 s). Hooks: none beyond the trace

New projects on the Simulator: 6, 2.2 MB on disk.

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| POST projects/{u}/assets/urls | 12 | 22 | 612 B | 14.1 KB |  |
| GET projects/{u} | 6 | 28 | 0 B | 16.7 KB |  |
| POST projects/{u}/presence | 6 | 18 | 258 B | 1.5 KB |  |
| GET status | 4 | 72 | 0 B | 10.7 KB |  |
| GET projects?include_deleted=1 | 1 | 59 | 0 B | 120.3 KB |  |
| POST device | 1 | 36 | 201 B | 448 B |  |
| GET projects | 1 | 43 | 0 B | 118.2 KB |  |
| **total** | 31 | 31 | 1.0 KB | 281.8 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| GET poster.jpg | 6 | 2.1 MB | 9 |
| GET records.aar | 6 | 15.0 KB | 3 |
| **total** | 12 | 2.1 MB | 6 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| download_url_issued | 12 | 0 B | 2.1 MB |

**Log highlights**

```
14:08:08.174 picplace: pacing requests under 300/min (255/min for sync work)
14:08:08.317 picplace: pulled broad-mix--arches.02 (b6554157) — 2 object(s), 300983 bytes; 1 heavy file(s) stay on PicPlace
14:08:08.426 picplace: pulled broad-mix--arches.01 (7ae80f75) — 2 object(s), 292195 bytes; 1 heavy file(s) stay on PicPlace
14:08:08.521 picplace: pulled 16c080c7-a9b0-426c-8a53-a6975815bda7 (db154262) — 2 object(s), 458613 bytes; 1 heavy file(s) stay on PicPlace
14:08:08.637 picplace: pulled 5b503e1f-30b9-4037-91ce-8d5a6e7fe856 (7857711b) — 2 object(s), 430307 bytes; 1 heavy file(s) stay on PicPlace
14:08:08.749 picplace: pulled 3db344e3-5a1b-4be4-816e-b5d3ffb97d11 (40a4ce4b) — 2 object(s), 419007 bytes; 1 heavy file(s) stay on PicPlace
14:08:08.865 picplace: pulled buildings.01 (e81848a7) — 2 object(s), 270684 bytes; 1 heavy file(s) stay on PicPlace
14:08:08.867 picplace: check (foreground) — 6 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/12-sim-a-after-move.log`](raw/12-sim-a-after-move.log) · projects on the Mac 115 → 115, on the Simulator 115 → 121.

## 13. sim-b-idle — Simulator

_library B once more with nothing changed: do the same conflicts or notices repeat?._ 14:09:17 → 14:11:14 (116.9 s). Hooks: none beyond the trace

New projects on the Simulator: 113, 31.3 MB on disk.

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| POST projects/{u}/assets/urls | 226 | 22 | 11.3 KB | 265.1 KB |  |
| GET projects/{u} | 113 | 25 | 0 B | 330.4 KB |  |
| POST projects/{u}/presence | 113 | 20 | 4.7 KB | 45.9 KB |  |
| GET status | 4 | 67 | 0 B | 10.7 KB |  |
| GET projects?include_deleted=1 | 1 | 48 | 0 B | 120.3 KB |  |
| POST device | 1 | 44 | 201 B | 448 B |  |
| GET projects | 1 | 49 | 0 B | 118.2 KB |  |
| **total** | 459 | 23 | 16.2 KB | 891.0 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| GET poster.jpg | 113 | 28.8 MB | 9 |
| GET records.aar | 113 | 553.0 KB | 5 |
| **total** | 226 | 29.3 MB | 7 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| download_url_issued | 226 | 0 B | 29.3 MB |

**Log highlights**

```
14:09:19.723 picplace: pacing requests under 300/min (255/min for sync work)
14:09:19.884 picplace: pulled Photo 29. 7. at 1554 (c58eda80) — 2 object(s), 459972 bytes; 1 heavy file(s) stay on PicPlace
14:09:19.993 picplace: pulled 8b672eb3-5221-4df3-beef-d69b6f1c292c (5bddd7f8) — 2 object(s), 380696 bytes; 1 heavy file(s) stay on PicPlace
14:09:20.084 picplace: pulled 6daeaac6-dcb8-4cac-b873-cd9bb4536bc9 (0e6ff819) — 2 object(s), 270993 bytes; 1 heavy file(s) stay on PicPlace
14:09:20.179 picplace: pulled building.01 (2eca2cb8) — 2 object(s), 234421 bytes; 1 heavy file(s) stay on PicPlace
14:09:20.305 picplace: pulled arch.01 (84a1e3ef) — 2 object(s), 340887 bytes; 1 heavy file(s) stay on PicPlace
14:09:20.419 picplace: pulled single.oldtown.dusk.near (b1a2848f) — 2 object(s), 215906 bytes; 1 heavy file(s) stay on PicPlace
14:09:20.535 picplace: pulled windows.05 (678416d9) — 2 object(s), 278467 bytes; 1 heavy file(s) stay on PicPlace
14:09:20.664 picplace: pulled windows.06 (33e92519) — 2 object(s), 278623 bytes; 1 heavy file(s) stay on PicPlace
14:09:20.796 picplace: pulled windows.02 (b9d0931f) — 2 object(s), 347679 bytes; 1 heavy file(s) stay on PicPlace
14:09:20.911 picplace: pulled windows.03 (ae73cffc) — 2 object(s), 312399 bytes; 1 heavy file(s) stay on PicPlace
14:09:21.023 picplace: pulled windows.04 (3a74d0ec) — 2 object(s), 280593 bytes; 1 heavy file(s) stay on PicPlace
14:09:21.137 picplace: pulled tram.01 (a3341acd) — 2 object(s), 313176 bytes; 1 heavy file(s) stay on PicPlace
14:09:21.240 picplace: pulled windows.01 (75186093) — 2 object(s), 235769 bytes; 1 heavy file(s) stay on PicPlace
14:09:21.347 picplace: pulled trams-nature.04 (7374b86d) — 2 object(s), 298335 bytes; 1 heavy file(s) stay on PicPlace
14:09:21.452 picplace: pulled trams-nature.01 (f7d6b37d) — 2 object(s), 328502 bytes; 1 heavy file(s) stay on PicPlace
14:09:21.556 picplace: pulled trams-nature.02 (a0ac51bc) — 2 object(s), 369071 bytes; 1 heavy file(s) stay on PicPlace
14:09:21.661 picplace: pulled trams-nature.03 (5e187e7b) — 2 object(s), 327344 bytes; 1 heavy file(s) stay on PicPlace
14:09:21.770 picplace: pulled trams-city.09 (7bf05aa4) — 2 object(s), 349066 bytes; 1 heavy file(s) stay on PicPlace
14:09:21.880 picplace: pulled trams-city.08 (3ff9b459) — 2 object(s), 301246 bytes; 1 heavy file(s) stay on PicPlace
14:09:21.993 picplace: pulled trams-city.07 (05ef54ce) — 2 object(s), 282227 bytes; 1 heavy file(s) stay on PicPlace
14:09:22.110 picplace: pulled trams-city.06 (6130b2d3) — 2 object(s), 253158 bytes; 1 heavy file(s) stay on PicPlace
14:09:22.233 picplace: pulled trams-city.05 (fe2f247a) — 2 object(s), 280768 bytes; 1 heavy file(s) stay on PicPlace
14:09:22.355 picplace: pulled trams-city.04 (87b3e188) — 2 object(s), 255047 bytes; 1 heavy file(s) stay on PicPlace
14:09:22.469 picplace: pulled trams-city.03 (eb7840a9) — 2 object(s), 282025 bytes; 1 heavy file(s) stay on PicPlace
14:09:22.561 picplace: pulled trams-city.02 (f59b627a) — 2 object(s), 287513 bytes; 1 heavy file(s) stay on PicPlace
14:09:22.644 picplace: pulled trams-city.01 (ecf04312) — 2 object(s), 331038 bytes; 1 heavy file(s) stay on PicPlace
14:09:22.737 picplace: pulled flower.12 (29f7b6a2) — 2 object(s), 280431 bytes; 1 heavy file(s) stay on PicPlace
14:09:22.842 picplace: pulled flower.11 (95a0fd62) — 2 object(s), 253686 bytes; 1 heavy file(s) stay on PicPlace
14:09:22.968 picplace: pulled flower.10 (ad09dd9a) — 2 object(s), 282673 bytes; 1 heavy file(s) stay on PicPlace
… 56 line(s) left out …
14:10:23.217 picplace: pulled doors-16x9.10 (d01deaee) — 2 object(s), 208002 bytes; 1 heavy file(s) stay on PicPlace
14:10:23.319 picplace: pulled doors-16x9.09 (058d5860) — 2 object(s), 197490 bytes; 1 heavy file(s) stay on PicPlace
14:10:23.441 picplace: pulled doors-16x9.08 (dfd602f0) — 2 object(s), 178055 bytes; 1 heavy file(s) stay on PicPlace
14:10:23.546 picplace: pulled doors-16x9.07 (95447be9) — 2 object(s), 127490 bytes; 1 heavy file(s) stay on PicPlace
14:10:23.660 picplace: pulled doors-16x9.06 (1aa8115a) — 2 object(s), 224333 bytes; 1 heavy file(s) stay on PicPlace
14:10:23.773 picplace: pulled doors-16x9.05 (cd68ba59) — 2 object(s), 223673 bytes; 1 heavy file(s) stay on PicPlace
14:10:23.870 picplace: pulled doors-16x9.04 (c7895a1b) — 2 object(s), 252262 bytes; 1 heavy file(s) stay on PicPlace
14:10:23.949 picplace: pulled doors-16x9.03 (c77a835d) — 2 object(s), 150479 bytes; 1 heavy file(s) stay on PicPlace
14:10:24.032 picplace: pulled doors-16x9.02 (4e3b0c8b) — 2 object(s), 220442 bytes; 1 heavy file(s) stay on PicPlace
14:10:24.134 picplace: pulled doors.07 (af51f042) — 2 object(s), 305809 bytes; 1 heavy file(s) stay on PicPlace
14:10:24.219 picplace: pulled doors.08 (a7021357) — 2 object(s), 274965 bytes; 1 heavy file(s) stay on PicPlace
14:10:24.324 picplace: pulled doors-16x9.01 (94b80fca) — 2 object(s), 169505 bytes; 1 heavy file(s) stay on PicPlace
14:10:24.443 picplace: pulled doors.05 (8573257b) — 2 object(s), 317061 bytes; 1 heavy file(s) stay on PicPlace
14:10:24.563 picplace: pulled doors.03 (667cc77b) — 2 object(s), 324812 bytes; 1 heavy file(s) stay on PicPlace
14:10:24.689 picplace: pulled doors.06 (566cde9a) — 2 object(s), 344398 bytes; 1 heavy file(s) stay on PicPlace
14:10:24.818 picplace: pulled doors.04 (3cfc2584) — 2 object(s), 302713 bytes; 1 heavy file(s) stay on PicPlace
14:10:24.938 picplace: pulled doors.01 (e78a74d0) — 2 object(s), 293935 bytes; 1 heavy file(s) stay on PicPlace
14:10:25.048 picplace: pulled doors.02 (8d891d8f) — 2 object(s), 313894 bytes; 1 heavy file(s) stay on PicPlace
14:10:25.177 picplace: pulled 5b503e1f-30b9-4037-91ce-8d5a6e7fe856 (49a122c5) — 2 object(s), 390101 bytes; 1 heavy file(s) stay on PicPlace
14:10:25.288 picplace: pulled 3db344e3-5a1b-4be4-816e-b5d3ffb97d11 (482031c0) — 2 object(s), 336252 bytes; 1 heavy file(s) stay on PicPlace
14:10:25.396 picplace: pulled broad-mix--arches.05 (ffe59492) — 2 object(s), 461628 bytes; 1 heavy file(s) stay on PicPlace
14:10:25.502 picplace: pulled broad-mix--arches.03 (fc972c8f) — 2 object(s), 348076 bytes; 1 heavy file(s) stay on PicPlace
14:10:25.617 picplace: pulled broad-mix--arches.01 (cccb017c) — 2 object(s), 292279 bytes; 1 heavy file(s) stay on PicPlace
14:10:25.726 picplace: pulled broad-mix--arches.04 (9d7e7143) — 2 object(s), 293481 bytes; 1 heavy file(s) stay on PicPlace
14:10:25.832 picplace: pulled ae1fa114-51a5-4f29-b101-94eaead64d00 (37ebdfb2) — 2 object(s), 327550 bytes; 1 heavy file(s) stay on PicPlace
14:10:25.949 picplace: pulled broad-mix--arches.02 (1b3132ae) — 2 object(s), 301031 bytes; 1 heavy file(s) stay on PicPlace
14:10:26.061 picplace: pulled Photo 29. 7. at 1614 (a2b269d5) — 2 object(s), 272606 bytes; 1 heavy file(s) stay on PicPlace
14:10:26.177 picplace: pulled Photo of rocks (92d074da) — 2 object(s), 412310 bytes; 1 heavy file(s) stay on PicPlace
14:10:26.179 picplace: check (foreground) — 113 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 1 conflict(s)
14:10:26.182 picplace: conflict — buildings.02 (8206C7F5) unrelated: local 1551564060000 vs server 1790834715164 from macbookpro
```

Full log: [`raw/13-sim-b-idle.log`](raw/13-sim-b-idle.log) · projects on the Mac 115 → 115, on the Simulator 8 → 121.
