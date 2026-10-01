# PicPlace sync-cost bench: 2026-10-01

**Started** 2026-10-01T14:31:44 · **finished** 2026-10-01T14:42:45 · raw logs and `run.json` in [`raw/`](raw/).

A data pack, not an analysis. Every request comes from the app's own `picplace trace:` lines (`LL_PICPLACE_TRACE=1`): API bodies are JSON bytes without headers; storage bytes are the object's bytes. Ledger rows are the server's `letslapse_usage_events` for the account. Each step is one launch of the app with the hooks shown, settled until its log was quiet, then quit; a launch's own check (2 to 5 requests) is inside each step's figures.

## Inputs

- Photos: 5 file(s) — `/Users/stevenwright/Documents/dev/letslapse-testing/camera-dngs/Photo of rocks.dng` …
- `.lapse` projects: 2 file(s) — `/Users/stevenwright/Documents/dev/letslapse-testing/synth-lapse/archives/broad-mix--buildings.03.lapse` …
- Mac library `/Users/stevenwright/Pictures/LetsLapse/synth`, Simulator `C8F8FCC2-5DBC-4B87-B7FE-06D1085C7996`, server `https://picplace.test`, account `synth`.
- Simulator edit mode: **download** (download = the originals come down first, as the editor's just-in-time prompt would; preview = the preset is written over the preview alone).

## Summary

| Step | Device | s | API req | API up | API down | PUTs | PUT bytes | GETs | GET bytes | New projects | API req / new project |
|---|---|---|---|---|---|---|---|---|---|---|---|
| sim-a-baseline | Simulator | 70.6 | 9 | 201 B | 254.9 KB | 0 | 0 B | 0 | 0 B |  |  |
| sim-new-library | Simulator | 72.7 | 24 | 446 B | 871.4 KB | 0 | 0 B | 0 | 0 B |  |  |
| sim-b-import | Simulator | 70.6 | 72 | 11.0 KB | 507.7 KB | 10 | 1.8 MB | 0 | 0 B | 7 | 10.3 |
| mac-a-check | Mac | 70.3 | 11 | 396 B | 266.2 KB | 0 | 0 B | 0 | 0 B |  |  |
| sim-b-check | Simulator | 70.6 | 14 | 201 B | 403.1 KB | 0 | 0 B | 0 | 0 B |  |  |
| mac-a-after-move | Mac | 68.3 | 10 | 198 B | 266.2 KB | 0 | 0 B | 0 | 0 B |  |  |
| sim-b-after-move | Simulator | 68.6 | 13 | 346 B | 272.6 KB | 0 | 0 B | 2 | 375.3 KB | 1 | 13.0 |
| sim-a-after-move | Simulator | 70.7 | 14 | 201 B | 403.1 KB | 0 | 0 B | 0 | 0 B |  |  |
| sim-b-idle | Simulator | 70.6 | 14 | 201 B | 403.1 KB | 0 | 0 B | 0 | 0 B |  |  |

Library A on the Simulator: `457D3FBD-E366-4669-BB5B-81419A24B657`. Library B (created by the run): `7D3A5393-EF80-49AE-ADAD-BDF2634DA92C`.
Moved on the server from A to B: {"origin": "89345046-965f-4821-aaae-c10546fbd60d", "title": "16c080c7-a9b0-426c-8a53-a6975815bda7.jpg", "result": {"moved": 1, "unchanged": 0, "unknown": []}}

Libraries on the account before:

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
  "uuid": "90836859-7f63-4355-98fd-1e758ad6518e",
  "name": "synth three",
  "projects": {
   "count": 6,
   "by_type": {
    "photo": 6,
    "interval": 0,
    "video": 0
   }
  },
  "used_bytes": 29658346,
  "originals": 6,
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
  "created_at": "2026-10-01T12:33:03+00:00",
  "updated_at": "2026-10-01T12:33:03+00:00",
  "deleted_at": null,
  "deleted_by": null
 },
 {
  "uuid": "4e593426-7411-47ef-88a6-ff9013ca3d1a",
  "name": "synth two",
  "projects": {
   "count": 6,
   "by_type": {
    "photo": 6,
    "interval": 0,
    "video": 0
   }
  },
  "used_bytes": 18093638,
  "originals": 6,
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

Sync-state files at the end: Mac 71.5 KB, Simulator 4.5 KB.

## Server, start → end

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| copy_confirmed | 5 | 0 B | 0 B |
| download_url_issued | 2 | 0 B | 375.3 KB |
| manifest_written | 10 | 4.8 KB | 0 B |
| upload_confirmed | 10 | 1.8 MB | 0 B |

Account tables at the end:

| Table | Value |
|---|---|
| projects live / trashed | 126 / 2 |
| projects by type | {"interval": 1, "photo": 127} |
| manifest bytes | 66.2 KB |
| assets | preview confirmed: 128 (33.8 MB); records confirmed: 128 (594.4 KB); source confirmed: 128 (160.6 MB) |
| presences by tier | {"original": 123, "preview": 122} |
| index rows / name NULL / records indexed | 128 / 127 / 0 |
| pending uploads | 0 |

## 1. sim-a-baseline — Simulator

_Simulator on library A: one launch, its checks._ 14:31:45 → 14:32:56 (70.6 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 6 | 76 | 0 B | 16.0 KB |  |
| POST device | 1 | 34 | 201 B | 448 B |  |
| GET projects | 1 | 57 | 0 B | 118.2 KB |  |
| GET projects?include_deleted=1 | 1 | 86 | 0 B | 120.3 KB |  |
| **total** | 9 | 70 | 201 B | 254.9 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
14:31:47.905 picplace: pacing requests under 300/min (255/min for sync work)
14:31:48.089 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/01-sim-a-baseline.log`](raw/01-sim-a-baseline.log) · projects on the Mac 115 → 115, on the Simulator 114 → 114.

## 2. sim-new-library — Simulator

_create library “synth three” on PicPlace from the phone's Libraries section (the real door), which switches to it._ 14:32:59 → 14:34:11 (72.7 s). Hooks: `LL_SCROLL=libraries`, `LL_LIBRARY=new:synth three`

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 14 | 64 | 0 B | 40.4 KB |  |
| GET projects | 6 | 51 | 0 B | 709.4 KB |  |
| POST device | 2 | 34 | 402 B | 896 B |  |
| GET projects?include_deleted=1 | 1 | 75 | 0 B | 120.3 KB |  |
| PUT libraries/{u} | 1 | 62 | 44 B | 545 B |  |
| **total** | 24 | 59 | 446 B | 871.4 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
14:33:01.485 picplace: pacing requests under 300/min (255/min for sync work)
14:33:01.740 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
14:33:03.214 picplace: library “synth three” 90836859-7f63-4355-98fd-1e758ad6518e created on picplace.test and placed in Libraries/7D3A5393-EF80-49AE-ADAD-BDF2634DA92C
14:33:03.253 luts: 0 imported LUT(s) at /Users/stevenwright/Library/Developer/CoreSimulator/Devices/C8F8FCC2-5DBC-4B87-B7FE-06D1085C7996/data/Containers/Data/Application/5C9621FA-4402-4F1C-B36E-3A231EE1A72F/Library/Application Support/LetsLapse/Libraries/7D3A5393-EF80-49AE-ADAD-BDF2634DA92C/luts
14:33:03.253 luts: 0 imported LUT(s) at /Users/stevenwright/Library/Developer/CoreSimulator/Devices/C8F8FCC2-5DBC-4B87-B7FE-06D1085C7996/data/Containers/Data/Application/5C9621FA-4402-4F1C-B36E-3A231EE1A72F/Library/Application Support/LetsLapse/Libraries/7D3A5393-EF80-49AE-ADAD-BDF2634DA92C/luts
14:33:03.506 picplace: pacing requests under 300/min (255/min for sync work)
14:33:03.705 picplace: initial sync (clean) — 0 to pull, 0 to push, 0 in step, 0 deferred
14:33:03.706 picplace: initial sync done (clean)
```

Full log: [`raw/02-sim-new-library.log`](raw/02-sim-new-library.log) · projects on the Mac 115 → 115, on the Simulator 114 → 114.

## 3. sim-b-import — Simulator

_library B: import 5 photo(s) whose bytes library A already holds, and 2 .lapse project(s) library A already holds (twins by origin); originals on._ 14:34:14 → 14:35:25 (70.6 s). Hooks: `LL_IMPORT_STILLS=/Users/stevenwright/Documents/dev/letslapse-testing/camera-dngs/Photo of rocks.dng:/Users/stevenwright/Documents/dev/letslapse-testing/flat-jpegs/8b672eb3-5221-4df3-beef-d69b6f1c292c.jpg:/Users/steven…`, `LL_IMPORT_ANSWER=photos`, `LL_IMPORT_ARCHIVE=/Users/stevenwright/Documents/dev/letslapse-testing/synth-lapse/archives/broad-mix--buildings.03.lapse:/Users/stevenwright/Documents/dev/letslapse-testing/synth-lapse/archives/broad-mix--buildings.04.…`

New projects on the Simulator: 7, 24.5 MB on disk.

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| POST projects/{u}/claim | 10 | 23 | 200 B | 76.8 KB |  |
| PUT projects/{u} | 10 | 35 | 6.3 KB | 9.3 KB |  |
| POST projects/{u}/assets | 10 | 33 | 2.6 KB | 16.2 KB |  |
| POST projects/{u}/presence | 10 | 19 | 440 B | 2.1 KB |  |
| DELETE projects/{u}/claim | 10 | 19 | 0 B | 140 B |  |
| GET status | 8 | 74 | 0 B | 25.4 KB |  |
| POST projects/{u}/assets/confirm | 5 | 39 | 1.2 KB | 5.2 KB |  |
| GET projects/{u} | 5 | 23 | 0 B | 11.3 KB |  |
| GET projects | 2 | 62 | 0 B | 240.5 KB |  |
| POST device | 1 | 32 | 201 B | 448 B |  |
| GET projects?include_deleted=1 | 1 | 92 | 0 B | 120.3 KB |  |
| **total** | 72 | 34 | 11.0 KB | 507.7 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| PUT poster.jpg | 5 | 1.8 MB | 14 |
| PUT records.aar | 5 | 5.2 KB | 7 |
| **total** | 10 | 1.8 MB | 11 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| copy_confirmed | 5 | 0 B | 0 B |
| manifest_written | 10 | 4.8 KB | 0 B |
| upload_confirmed | 10 | 1.8 MB | 0 B |

**Log highlights**

```
14:34:16.838 assets: 1A61EF9E recorded 1 of 1 pending (1 assets)
14:34:17.232 assets: EF95F9F3 recorded 1 of 1 pending (1 assets)
14:34:17.284 assets: 2D4080C7 recorded 1 of 1 pending (1 assets)
14:34:17.383 picplace: pacing requests under 300/min (255/min for sync work)
14:34:17.393 assets: 226F7B56 recorded 1 of 1 pending (1 assets)
14:34:17.426 assets: 68D0433F recorded 1 of 1 pending (1 assets)
14:34:17.453 assets: 7A060703 recorded 1 of 1 pending (1 assets)
14:34:17.469 assets: F721A8A8 recorded 1 of 1 pending (1 assets)
14:34:17.547 picplace: check (foreground) — 0 pulled, 0 updated, 5 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 2 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
14:34:17.780 picplace: broad-mix--arches.04 — uploading 2 of 2 file(s), 294 KB
14:34:18.169 picplace: 8b672eb3-5221-4df3-beef-d69b6f1c292c — uploading 2 of 2 file(s), 421 KB
14:34:18.501 picplace: ae1fa114-51a5-4f29-b101-94eaead64d00 — uploading 2 of 2 file(s), 386 KB
14:34:18.714 picplace: broad-mix--arches.03 — uploading 2 of 2 file(s), 348 KB
14:34:19.064 picplace: Photo of rocks — uploading 2 of 2 file(s), 412 KB
14:34:19.177 picplace: push queue — 5 sent, 0 failed
```

Full log: [`raw/03-sim-b-import.log`](raw/03-sim-b-import.log) · projects on the Mac 115 → 115, on the Simulator 0 → 7.

## 4. mac-a-check — Mac

_Mac on library A after library B gained projects: does anything of B arrive?._ 14:35:28 → 14:36:38 (70.3 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 6 | 43 | 0 B | 18.7 KB |  |
| POST device | 2 | 26 | 396 B | 890 B |  |
| GET nearby/key | 1 | 12 | 0 B | 135 B |  |
| GET projects | 1 | 51 | 0 B | 122.2 KB |  |
| GET projects?include_deleted=1 | 1 | 41 | 0 B | 124.3 KB |  |
| **total** | 11 | 37 | 396 B | 266.2 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
14:35:30.874 picplace: pacing requests under 300/min (255/min for sync work)
14:35:31.121 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/04-mac-a-check.log`](raw/04-mac-a-check.log) · projects on the Mac 115 → 115, on the Simulator 7 → 7.

## 5. sim-b-check — Simulator

_library B idle check: what a small library pays for the account's big one._ 14:36:41 → 14:37:52 (70.6 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 10 | 48 | 0 B | 31.8 KB |  |
| GET projects?include_deleted=1 | 2 | 36 | 0 B | 248.6 KB |  |
| POST device | 1 | 34 | 201 B | 448 B |  |
| GET projects | 1 | 48 | 0 B | 122.2 KB |  |
| **total** | 14 | 45 | 201 B | 403.1 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
14:36:43.933 picplace: pacing requests under 300/min (255/min for sync work)
14:36:44.023 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 2 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
14:36:44.192 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 2 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/05-sim-b-check.log`](raw/05-sim-b-check.log) · projects on the Mac 115 → 115, on the Simulator 7 → 7.

## 6. mac-a-after-move — Mac

_Mac on A after “16c080c7-a9b0-426c-8a53-a6975815bda7.jpg” (89345046) was filed under B on the server._ 14:37:55 → 14:39:03 (68.3 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 6 | 38 | 0 B | 19.1 KB |  |
| POST device | 1 | 30 | 198 B | 445 B |  |
| GET nearby/key | 1 | 23 | 0 B | 135 B |  |
| GET projects | 1 | 39 | 0 B | 122.2 KB |  |
| GET projects?include_deleted=1 | 1 | 35 | 0 B | 124.3 KB |  |
| **total** | 10 | 36 | 198 B | 266.2 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
14:37:56.391 picplace: pacing requests under 300/min (255/min for sync work)
14:37:56.620 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/06-mac-a-after-move.log`](raw/06-mac-a-after-move.log) · projects on the Mac 115 → 115, on the Simulator 7 → 7.

## 7. sim-b-after-move — Simulator

_library B after the move: the project arrives._ 14:39:06 → 14:40:15 (68.6 s). Hooks: none beyond the trace

New projects on the Simulator: 1, 378.4 KB on disk.

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 6 | 62 | 0 B | 19.1 KB |  |
| POST projects/{u}/assets/urls | 2 | 19 | 102 B | 2.3 KB |  |
| POST device | 1 | 21 | 201 B | 448 B |  |
| GET projects?include_deleted=1 | 1 | 44 | 0 B | 124.3 KB |  |
| GET projects | 1 | 48 | 0 B | 122.2 KB |  |
| GET projects/{u} | 1 | 21 | 0 B | 3.8 KB |  |
| POST projects/{u}/presence | 1 | 21 | 43 B | 416 B |  |
| **total** | 13 | 43 | 346 B | 272.6 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| GET poster.jpg | 1 | 374.1 KB | 7 |
| GET records.aar | 1 | 1.3 KB | 3 |
| **total** | 2 | 375.3 KB | 5 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| download_url_issued | 2 | 0 B | 375.3 KB |

**Log highlights**

```
14:39:08.995 picplace: pacing requests under 300/min (255/min for sync work)
14:39:09.220 picplace: pulled 16c080c7-a9b0-426c-8a53-a6975815bda7 (89345046) — 2 object(s), 384335 bytes; 1 heavy file(s) stay on PicPlace
14:39:09.222 picplace: check (foreground) — 1 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 2 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/07-sim-b-after-move.log`](raw/07-sim-b-after-move.log) · projects on the Mac 115 → 115, on the Simulator 7 → 8.

## 8. sim-a-after-move — Simulator

_the Simulator back on library A: its preview of the moved project._ 14:40:18 → 14:41:29 (70.7 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 10 | 54 | 0 B | 31.8 KB |  |
| GET projects?include_deleted=1 | 2 | 57 | 0 B | 248.6 KB |  |
| POST device | 1 | 37 | 201 B | 448 B |  |
| GET projects | 1 | 48 | 0 B | 122.2 KB |  |
| **total** | 14 | 53 | 201 B | 403.1 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
14:40:20.673 picplace: pacing requests under 300/min (255/min for sync work)
14:40:20.803 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
14:40:21.004 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/08-sim-a-after-move.log`](raw/08-sim-a-after-move.log) · projects on the Mac 115 → 115, on the Simulator 114 → 114.

## 9. sim-b-idle — Simulator

_library B once more with nothing changed: do the same conflicts or notices repeat?._ 14:41:31 → 14:42:42 (70.6 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 10 | 51 | 0 B | 31.8 KB |  |
| GET projects?include_deleted=1 | 2 | 41 | 0 B | 248.6 KB |  |
| POST device | 1 | 20 | 201 B | 448 B |  |
| GET projects | 1 | 40 | 0 B | 122.2 KB |  |
| **total** | 14 | 46 | 201 B | 403.1 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
14:41:34.238 picplace: pacing requests under 300/min (255/min for sync work)
14:41:34.327 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 2 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
14:41:34.522 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 2 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/09-sim-b-idle.log`](raw/09-sim-b-idle.log) · projects on the Mac 115 → 115, on the Simulator 8 → 8.
