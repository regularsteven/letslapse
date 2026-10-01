# PicPlace sync-cost bench: 2026-10-01

**Started** 2026-10-01T14:50:26 · **finished** 2026-10-01T15:07:15 · raw logs and `run.json` in [`raw/`](raw/).

A data pack, not an analysis. Every request comes from the app's own `picplace trace:` lines (`LL_PICPLACE_TRACE=1`): API bodies are JSON bytes without headers; storage bytes are the object's bytes. Ledger rows are the server's `letslapse_usage_events` for the account. Each step is one launch of the app with the hooks shown, settled until its log was quiet, then quit; a launch's own check (2 to 5 requests) is inside each step's figures.

## Inputs

- Photos: 14 file(s) — `/Users/stevenwright/Documents/dev/letslapse-testing/camera-dngs/Photo 29. 7. at 1554.dng` …
- `.lapse` projects: 0 file(s)
- Mac library `/Users/stevenwright/Pictures/LetsLapse/synth`, Simulator `C8F8FCC2-5DBC-4B87-B7FE-06D1085C7996`, server `https://picplace.test`, account `synth`.
- Simulator edit mode: **download** (download = the originals come down first, as the editor's just-in-time prompt would; preview = the preset is written over the preview alone).

## Summary

| Step | Device | s | API req | API up | API down | PUTs | PUT bytes | GETs | GET bytes | New projects | API req / new project |
|---|---|---|---|---|---|---|---|---|---|---|---|
| mac-baseline | Mac | 70.2 | 7 | 396 B | 253.5 KB | 0 | 0 B | 0 | 0 B |  |  |
| mac-import-photos | Mac | 76.4 | 178 | 29.6 KB | 849.6 KB | 20 | 2.2 MB | 0 | 0 B | 14 | 12.7 |
| mac-edit-photos | Mac | 78.3 | 23 | 5.7 KB | 420.3 KB | 0 | 0 B | 0 | 0 B |  |  |
| sim-pull | Simulator | 70.6 | 7 | 201 B | 422.7 KB | 0 | 0 B | 0 | 0 B |  |  |
| sim-download | Simulator | 70.6 | 20 | 595 B | 446.6 KB | 0 | 0 B | 3 | 18.9 MB |  |  |
| sim-edit | Simulator | 80.7 | 26 | 6.1 KB | 434.7 KB | 3 | 3.8 KB | 0 | 0 B |  |  |
| mac-after | Mac | 68.3 | 15 | 546 B | 300.5 KB | 0 | 0 B | 6 | 1.1 MB |  |  |

Sync-state files at the end: Mac 80.4 KB, Simulator 70.2 KB.

## Server, start → end

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| asset_replaced | 9 | 0 B | 0 B |
| copy_confirmed | 28 | 0 B | 0 B |
| download_url_issued | 37 | 0 B | 24.6 MB |
| manifest_written | 34 | 21.3 KB | 0 B |
| upload_confirmed | 23 | 2.2 MB | 0 B |

Account tables at the end:

| Table | Value |
|---|---|
| projects live / trashed | 140 / 2 |
| projects by type | {"interval": 1, "photo": 141} |
| manifest bytes | 77.8 KB |
| assets | preview confirmed: 142 (38.5 MB); records confirmed: 142 (609.3 KB); source confirmed: 142 (222.0 MB) |
| presences by tier | {"original": 140, "preview": 133} |
| index rows / name NULL / records indexed | 142 / 141 / 0 |
| pending uploads | 0 |

## 1. mac-baseline — Mac

_launch, one check, quit._ 14:50:28 → 14:51:38 (70.2 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 2 | 49 | 0 B | 5.9 KB |  |
| POST device | 2 | 25 | 396 B | 890 B |  |
| GET nearby/key | 1 | 13 | 0 B | 135 B |  |
| GET projects | 1 | 50 | 0 B | 122.2 KB |  |
| GET projects?include_deleted=1 | 1 | 40 | 0 B | 124.3 KB |  |
| **total** | 7 | 36 | 396 B | 253.5 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
14:50:30.764 picplace: pacing requests under 300/min (255/min for sync work)
14:50:30.950 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/01-mac-baseline.log`](raw/01-mac-baseline.log) · projects on the Mac 115 → 115, on the Simulator 114 → 114.

## 2. mac-import-photos — Mac

_import 14 photo(s) as separate projects; push, originals up._ 14:51:41 → 14:52:57 (76.4 s). Hooks: `LL_IMPORT_STILLS=/Users/stevenwright/Documents/dev/letslapse-testing/camera-dngs/Photo 29. 7. at 1554.dng:/Users/stevenwright/Documents/dev/letslapse-testing/camera-dngs/Photo 29. 7. at 1614.dng:/Users/stevenwright/Do…`, `LL_IMPORT_ANSWER=photos`

Edited (origin ids): `75aad84d`, `fea07e71`, `6c2e2ffe`

Chosen for the Simulator's edits: `315e7935`, `c56a4f63`, `40550511`

New projects on the Mac: 14, 66.1 MB on disk.

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| POST projects/{u}/claim | 28 | 25 | 560 B | 215.1 KB |  |
| PUT projects/{u} | 28 | 38 | 17.7 KB | 25.8 KB |  |
| POST projects/{u}/assets | 28 | 42 | 7.4 KB | 40.1 KB |  |
| POST projects/{u}/presence | 28 | 25 | 1.2 KB | 5.9 KB |  |
| DELETE projects/{u}/claim | 28 | 22 | 0 B | 392 B |  |
| POST projects/{u}/assets/confirm | 14 | 41 | 2.5 KB | 10.6 KB |  |
| GET projects/{u} | 14 | 31 | 0 B | 31.5 KB |  |
| GET status | 4 | 68 | 0 B | 12.7 KB |  |
| GET projects | 3 | 71 | 0 B | 382.7 KB |  |
| POST device | 1 | 27 | 198 B | 445 B |  |
| GET nearby/key | 1 | 39 | 0 B | 135 B |  |
| GET projects?include_deleted=1 | 1 | 68 | 0 B | 124.3 KB |  |
| **total** | 178 | 33 | 29.6 KB | 849.6 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| PUT poster.jpg | 6 | 2.1 MB | 12 |
| PUT records.aar | 14 | 14.8 KB | 5 |
| **total** | 20 | 2.2 MB | 7 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| copy_confirmed | 22 | 0 B | 0 B |
| manifest_written | 28 | 13.5 KB | 0 B |
| upload_confirmed | 20 | 2.2 MB | 0 B |

**Log highlights**

```
14:51:42.529 assets: 40550511 recorded 1 of 1 pending (1 assets)
14:51:42.615 picplace: pacing requests under 300/min (255/min for sync work)
14:51:42.629 assets: CFD1A883 recorded 1 of 1 pending (1 assets)
14:51:42.730 assets: 33D01990 recorded 1 of 1 pending (1 assets)
14:51:42.819 assets: FEA07E71 recorded 1 of 1 pending (1 assets)
14:51:42.914 assets: 6C2E2FFE recorded 1 of 1 pending (1 assets)
14:51:43.006 assets: 315E7935 recorded 1 of 1 pending (1 assets)
14:51:43.093 picplace: check (launch) — 0 pulled, 0 updated, 6 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
14:51:43.099 assets: C56A4F63 recorded 1 of 1 pending (1 assets)
14:51:43.196 assets: 75AAD84D recorded 1 of 1 pending (1 assets)
14:51:43.295 assets: 18CA48F4 recorded 1 of 1 pending (1 assets)
14:51:43.388 assets: AC36EF87 recorded 1 of 1 pending (1 assets)
14:51:43.485 assets: B1EC6378 recorded 1 of 1 pending (1 assets)
14:51:43.584 assets: 33E4A6F7 recorded 1 of 1 pending (1 assets)
14:51:43.632 picplace: 6daeaac6-dcb8-4cac-b873-cd9bb4536bc9 — uploading 2 of 2 file(s), 274 KB
14:51:43.695 assets: F38ADED4 recorded 1 of 1 pending (1 assets)
14:51:43.790 assets: AC515FBC recorded 1 of 1 pending (1 assets)
14:51:44.084 picplace: 3db344e3-5a1b-4be4-816e-b5d3ffb97d11 — uploading 2 of 2 file(s), 369 KB
14:51:44.378 picplace: Photo of rocks — uploading 1 of 2 file(s), 1 KB; 1 already on PicPlace
14:51:44.737 picplace: Photo 29. 7. at 1614 — uploading 1 of 2 file(s), 1 KB; 1 already on PicPlace
14:51:45.087 picplace: 5b503e1f-30b9-4037-91ce-8d5a6e7fe856 — uploading 2 of 2 file(s), 380 KB
14:51:45.461 picplace: Photo 29. 7. at 1554 — uploading 2 of 2 file(s), 446 KB
14:51:45.596 picplace: push queue — 6 sent, 0 failed
14:52:03.446 picplace: 8b672eb3-5221-4df3-beef-d69b6f1c292c — uploading 2 of 2 file(s), 372 KB
14:52:03.752 picplace: 16c080c7-a9b0-426c-8a53-a6975815bda7 — uploading 2 of 2 file(s), 412 KB
14:52:04.055 picplace: ae1fa114-51a5-4f29-b101-94eaead64d00 — uploading 1 of 2 file(s), 1 KB; 1 already on PicPlace
14:52:04.326 picplace: broad-mix--arches.01 — uploading 1 of 2 file(s), 757 bytes; 1 already on PicPlace
14:52:04.583 picplace: broad-mix--arches.02 — uploading 1 of 2 file(s), 758 bytes; 1 already on PicPlace
14:52:04.785 picplace: broad-mix--arches.03 — uploading 1 of 2 file(s), 755 bytes; 1 already on PicPlace
14:52:04.935 picplace: broad-mix--arches.04 — uploading 1 of 2 file(s), 754 bytes; 1 already on PicPlace
14:52:05.137 picplace: broad-mix--arches.05 — uploading 1 of 2 file(s), 755 bytes; 1 already on PicPlace
14:52:05.237 picplace: push queue — 8 sent, 0 failed
```

Full log: [`raw/02-mac-import-photos.log`](raw/02-mac-import-photos.log) · projects on the Mac 115 → 129, on the Simulator 114 → 114.

## 3. mac-edit-photos — Mac

_preset on 3 of the new photos._ 14:53:00 → 14:54:19 (78.3 s). Hooks: `LL_APPLY_PRESET=75aad84d-4630-422a-917f-27a3c0ad2ce0:Cinema@2;fea07e71-a233-4d5e-8ac4-7c7e6bcf84cf:Matte@4;6c2e2ffe-bafb-433b-9d69-d9ceb6e121b6:Vivid@6`

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 3 | 65 | 0 B | 9.5 KB |  |
| POST projects/{u}/claim | 3 | 45 | 60 B | 693 B |  |
| PUT projects/{u} | 3 | 44 | 4.3 KB | 3.1 KB |  |
| POST projects/{u}/assets | 3 | 50 | 1.0 KB | 3.4 KB |  |
| POST projects/{u}/presence | 3 | 28 | 132 B | 642 B |  |
| DELETE projects/{u}/claim | 3 | 25 | 0 B | 42 B |  |
| GET projects | 2 | 64 | 0 B | 266.9 KB |  |
| POST device | 1 | 25 | 198 B | 445 B |  |
| GET nearby/key | 1 | 35 | 0 B | 135 B |  |
| GET projects?include_deleted=1 | 1 | 51 | 0 B | 135.5 KB |  |
| **total** | 23 | 44 | 5.7 KB | 420.3 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| asset_replaced | 3 | 0 B | 0 B |
| copy_confirmed | 3 | 0 B | 0 B |
| manifest_written | 3 | 3.9 KB | 0 B |

**Log highlights**

```
14:53:02.338 picplace: pacing requests under 300/min (255/min for sync work)
14:53:02.798 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
14:53:03.863 LL_APPLY_PRESET applied Cinema to 75AAD84D
14:53:05.963 LL_APPLY_PRESET applied Matte to FEA07E71
14:53:08.062 LL_APPLY_PRESET applied Vivid to 6C2E2FFE
14:53:24.726 picplace: push queue — 1 sent, 0 failed
14:53:26.370 picplace: push queue — 1 sent, 0 failed
14:53:28.534 picplace: push queue — 1 sent, 0 failed
```

Full log: [`raw/03-mac-edit-photos.log`](raw/03-mac-edit-photos.log) · projects on the Mac 129 → 129, on the Simulator 114 → 114.

## 4. sim-pull — Simulator

_launch, pull every new project's preview._ 15:02:13 → 15:03:24 (70.6 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 3 | 105 | 0 B | 9.6 KB |  |
| GET projects?include_deleted=1 | 2 | 48 | 0 B | 276.5 KB |  |
| POST device | 1 | 37 | 201 B | 448 B |  |
| GET projects | 1 | 58 | 0 B | 136.2 KB |  |
| **total** | 7 | 72 | 201 B | 422.7 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
15:02:16.054 picplace: pacing requests under 300/min (255/min for sync work)
15:02:16.167 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
15:02:16.308 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/04-sim-pull.log`](raw/04-sim-pull.log) · projects on the Mac 129 → 129, on the Simulator 128 → 128.

## 5. sim-download — Simulator

_download the originals of 3 photos not edited on the Mac (the just-in-time prompt's answer)._ 15:03:27 → 15:04:37 (70.6 s). Hooks: `LL_PICPLACE_DOWNLOAD=315e7935-aef1-40e6-926f-0a5d617961eb,c56a4f63-c775-4e58-97f4-3a5c33b1b311,40550511-27f9-4011-8b48-73664bf4cf9c`

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET projects/{u} | 6 | 33 | 0 B | 17.7 KB |  |
| GET status | 3 | 113 | 0 B | 9.6 KB |  |
| POST projects/{u}/assets/urls | 3 | 32 | 153 B | 3.7 KB |  |
| POST projects/{u}/presence | 3 | 31 | 132 B | 1.2 KB |  |
| GET projects?include_deleted=1 | 2 | 61 | 0 B | 276.5 KB |  |
| POST device | 1 | 32 | 201 B | 448 B |  |
| GET projects | 1 | 87 | 0 B | 136.2 KB |  |
| POST projects/assets | 1 | 18 | 109 B | 1.3 KB |  |
| **total** | 20 | 49 | 595 B | 446.6 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| GET source/* | 3 | 18.9 MB | 60 |
| **total** | 3 | 18.9 MB | 60 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| download_url_issued | 3 | 0 B | 18.9 MB |

**Log highlights**

```
15:03:29.676 picplace: pacing requests under 300/min (255/min for sync work)
15:03:29.792 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
15:03:29.935 assets: C56A4F63 recorded 0 of 0 pending (1 assets)
15:03:29.966 assets: 315E7935 recorded 0 of 0 pending (1 assets)
15:03:29.996 assets: 40550511 recorded 0 of 0 pending (1 assets)
15:03:30.048 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 2 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
15:03:30.092 picplace: 6daeaac6-dcb8-4cac-b873-cd9bb4536bc9 — all 1 heavy file(s) here verified on PicPlace: backed up
15:03:30.121 picplace: 8b672eb3-5221-4df3-beef-d69b6f1c292c — all 1 heavy file(s) here verified on PicPlace: backed up
15:03:30.148 picplace: Photo 29. 7. at 1554 — all 1 heavy file(s) here verified on PicPlace: backed up
```

Full log: [`raw/05-sim-download.log`](raw/05-sim-download.log) · projects on the Mac 129 → 129, on the Simulator 128 → 128.

## 6. sim-edit — Simulator

_preset on those 3 photos._ 15:04:40 → 15:06:01 (80.7 s). Hooks: `LL_APPLY_PRESET=315e7935-aef1-40e6-926f-0a5d617961eb:Cinema@2;c56a4f63-c775-4e58-97f4-3a5c33b1b311:Matte@4;40550511-27f9-4011-8b48-73664bf4cf9c:Vivid@6`

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 3 | 110 | 0 B | 9.6 KB |  |
| POST projects/{u}/claim | 3 | 44 | 60 B | 702 B |  |
| PUT projects/{u} | 3 | 47 | 4.3 KB | 3.7 KB |  |
| POST projects/{u}/assets | 3 | 56 | 1.0 KB | 6.2 KB |  |
| POST projects/{u}/assets/confirm | 3 | 43 | 402 B | 1.6 KB |  |
| POST projects/{u}/presence | 3 | 26 | 132 B | 1.2 KB |  |
| DELETE projects/{u}/claim | 3 | 24 | 0 B | 42 B |  |
| GET projects | 2 | 70 | 0 B | 272.4 KB |  |
| POST device | 1 | 22 | 201 B | 448 B |  |
| GET projects?include_deleted=1 | 1 | 61 | 0 B | 138.2 KB |  |
| POST projects/assets | 1 | 23 | 70 B | 664 B |  |
| **total** | 26 | 50 | 6.1 KB | 434.7 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| PUT records.aar | 3 | 3.8 KB | 5 |
| **total** | 3 | 3.8 KB | 5 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| asset_replaced | 6 | 0 B | 0 B |
| copy_confirmed | 3 | 0 B | 0 B |
| manifest_written | 3 | 3.9 KB | 0 B |
| upload_confirmed | 3 | 3.8 KB | 0 B |

**Log highlights**

```
15:04:43.252 picplace: pacing requests under 300/min (255/min for sync work)
15:04:43.418 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 1 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
15:04:44.893 LL_APPLY_PRESET applied Cinema to 315E7935
15:04:46.991 LL_APPLY_PRESET applied Matte to C56A4F63
15:04:49.092 LL_APPLY_PRESET applied Vivid to 40550511
15:05:07.169 picplace: 6daeaac6-dcb8-4cac-b873-cd9bb4536bc9 — uploading 1 of 2 file(s), 1 KB; 1 already on PicPlace
15:05:07.590 picplace: 8b672eb3-5221-4df3-beef-d69b6f1c292c — uploading 1 of 2 file(s), 1 KB; 1 already on PicPlace
15:05:07.651 picplace: push queue — 2 sent, 0 failed
15:05:09.672 picplace: Photo 29. 7. at 1554 — uploading 1 of 2 file(s), 1 KB; 1 already on PicPlace
15:05:09.797 picplace: push queue — 1 sent, 0 failed
```

Full log: [`raw/06-sim-edit.log`](raw/06-sim-edit.log) · projects on the Mac 129 → 129, on the Simulator 128 → 128.

## 7. mac-after — Mac

_launch, one check: what the Simulator's edits cost the Mac._ 15:06:04 → 15:07:12 (68.3 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET projects/{u} | 3 | 28 | 0 B | 11.3 KB |  |
| POST projects/{u}/assets/urls | 3 | 25 | 270 B | 7.0 KB |  |
| POST projects/{u}/presence | 3 | 19 | 78 B | 1.2 KB |  |
| GET status | 2 | 56 | 0 B | 5.9 KB |  |
| POST device | 1 | 28 | 198 B | 445 B |  |
| GET nearby/key | 1 | 13 | 0 B | 135 B |  |
| GET projects | 1 | 55 | 0 B | 136.2 KB |  |
| GET projects?include_deleted=1 | 1 | 42 | 0 B | 138.3 KB |  |
| **total** | 15 | 31 | 546 B | 300.5 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| GET poster.jpg | 3 | 1.1 MB | 8 |
| GET records.aar | 3 | 3.8 KB | 3 |
| **total** | 6 | 1.1 MB | 5 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| download_url_issued | 6 | 0 B | 1.1 MB |

**Log highlights**

```
15:06:05.761 picplace: pacing requests under 300/min (255/min for sync work)
15:06:06.332 picplace: check (launch) — 0 pulled, 3 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/07-mac-after.log`](raw/07-mac-after.log) · projects on the Mac 129 → 129, on the Simulator 128 → 128.
