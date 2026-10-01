# PicPlace sync-cost bench: 2026-10-01

**Started** 2026-10-01T15:49:38 · **finished** 2026-10-01T15:59:25 · raw logs and `run.json` in [`raw/`](raw/).

A data pack, not an analysis. Every request comes from the app's own `picplace trace:` lines (`LL_PICPLACE_TRACE=1`): API bodies are JSON bytes without headers; storage bytes are the object's bytes. Ledger rows are the server's `letslapse_usage_events` for the account. Each step is one launch of the app with the hooks shown, settled until its log was quiet, then quit; a launch's own check (2 to 5 requests) is inside each step's figures.

## Inputs

- Photos: 11 file(s) — `/private/tmp/claude-501/-Users-stevenwright-Documents-dev-letslapse/0a9dabed-ddef-4abd-96c5-8b0e8ea1f097/scratchpad/unique-photos/unique-1549-1.jpg` …
- `.lapse` projects: 0 file(s)
- Mac library `/private/tmp/claude-501/-Users-stevenwright-Documents-dev-letslapse/0a9dabed-ddef-4abd-96c5-8b0e8ea1f097/scratchpad/synth-device-b`, Simulator `C8F8FCC2-5DBC-4B87-B7FE-06D1085C7996`, server `https://picplace.test`, account `synth`.
- Simulator edit mode: **download** (download = the originals come down first, as the editor's just-in-time prompt would; preview = the preset is written over the preview alone).

## Summary

| Step | Device | s | API req | API up | API down | PUTs | PUT bytes | GETs | GET bytes | New projects | API req / new project |
|---|---|---|---|---|---|---|---|---|---|---|---|
| mac-baseline | Mac | 116.3 | 9 | 396 B | 422.9 KB | 0 | 0 B | 0 | 0 B |  |  |
| mac-import-photos | Mac | 74.2 | 77 | 16.7 KB | 804.4 KB | 27 | 30.1 MB | 0 | 0 B | 11 | 7.0 |
| mac-edit-photos | Mac | 80.2 | 25 | 5.8 KB | 457.1 KB | 2 | 712.6 KB | 0 | 0 B |  |  |
| sim-pull | Simulator | 70.6 | 39 | 1.8 KB | 361.1 KB | 0 | 0 B | 22 | 3.6 MB | 11 | 3.5 |
| sim-download | Simulator | 68.5 | 14 | 486 B | 316.3 KB | 0 | 0 B | 3 | 12.1 MB |  |  |
| sim-edit | Simulator | 80.5 | 29 | 6.4 KB | 481.0 KB | 6 | 1.0 MB | 0 | 0 B |  |  |
| mac-after | Mac | 68.2 | 15 | 546 B | 322.4 KB | 0 | 0 B | 6 | 1.0 MB |  |  |

Sync-state files at the end: Mac 87.5 KB, Simulator 76.6 KB.

## Server, start → end

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| asset_replaced | 9 | 0 B | 0 B |
| copy_confirmed | 7 | 0 B | 0 B |
| download_url_issued | 31 | 0 B | 16.8 MB |
| manifest_written | 17 | 12.6 KB | 0 B |
| upload_confirmed | 35 | 31.8 MB | 0 B |

Account tables at the end:

| Table | Value |
|---|---|
| projects live / trashed | 151 / 2 |
| projects by type | {"interval": 1, "photo": 152} |
| manifest bytes | 87.7 KB |
| assets | preview confirmed: 153 (42.1 MB); records confirmed: 153 (620.3 KB); source confirmed: 153 (250.4 MB) |
| presences by tier | {"original": 154, "preview": 141} |
| index rows / name NULL / records indexed | 153 / 152 / 0 |
| pending uploads | 0 |

## 1. mac-baseline — Mac

_launch, one check, quit._ 15:49:45 → 15:51:41 (116.3 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 3 | 98 | 0 B | 9.1 KB |  |
| POST device | 2 | 44 | 396 B | 890 B |  |
| GET projects?include_deleted=1 | 2 | 77 | 0 B | 276.5 KB |  |
| GET nearby/key | 1 | 40 | 0 B | 135 B |  |
| GET projects | 1 | 202 | 0 B | 136.2 KB |  |
| **total** | 9 | 86 | 396 B | 422.9 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
15:49:47.884 picplace: pacing requests under 300/min (255/min for sync work)
15:49:48.374 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
15:50:54.935 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/01-mac-baseline.log`](raw/01-mac-baseline.log) · projects on the Mac 129 → 129, on the Simulator 128 → 128.

## 2. mac-import-photos — Mac

_import 11 photo(s) as separate projects; push, originals up._ 15:51:44 → 15:52:58 (74.2 s). Hooks: `LL_IMPORT_STILLS=/private/tmp/claude-501/-Users-stevenwright-Documents-dev-letslapse/0a9dabed-ddef-4abd-96c5-8b0e8ea1f097/scratchpad/unique-photos/unique-1549-1.jpg:/private/tmp/claude-501/-Users-stevenwright-Document…`, `LL_IMPORT_ANSWER=photos`

Edited (origin ids): `b07d0dee`, `f991ba5b`, `f7af9ad0`

Chosen for the Simulator's edits: `aac77dc9`, `c985fa55`, `2921be8a`

New projects on the Mac: 11, 32.0 MB on disk.

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| POST projects/{u}/claim | 11 | 34 | 220 B | 166.5 KB |  |
| PUT projects/{u} | 11 | 52 | 6.8 KB | 8.9 KB |  |
| POST projects/{u}/assets | 11 | 51 | 5.5 KB | 38.3 KB |  |
| POST projects/{u}/assets/confirm | 11 | 62 | 3.3 KB | 14.3 KB |  |
| POST projects/{u}/presence | 11 | 30 | 484 B | 2.3 KB |  |
| DELETE projects/{u}/claim | 11 | 27 | 0 B | 154 B |  |
| GET status | 4 | 66 | 0 B | 12.7 KB |  |
| GET projects | 3 | 68 | 0 B | 422.0 KB |  |
| POST device | 2 | 32 | 396 B | 890 B |  |
| GET nearby/key | 1 | 52 | 0 B | 135 B |  |
| GET projects?include_deleted=1 | 1 | 55 | 0 B | 138.3 KB |  |
| **total** | 77 | 45 | 16.7 KB | 804.4 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| PUT poster.jpg | 5 | 1.7 MB | 18 |
| PUT records.aar | 11 | 11.0 KB | 6 |
| PUT source/* | 11 | 28.3 MB | 31 |
| **total** | 27 | 30.1 MB | 18 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| copy_confirmed | 6 | 0 B | 0 B |
| manifest_written | 11 | 5.0 KB | 0 B |
| upload_confirmed | 27 | 30.1 MB | 0 B |

**Log highlights**

```
15:51:45.901 assets: B07D0DEE recorded 1 of 1 pending (1 assets)
15:51:46.036 assets: AAC77DC9 recorded 1 of 1 pending (1 assets)
15:51:46.088 picplace: pacing requests under 300/min (255/min for sync work)
15:51:46.155 assets: C985FA55 recorded 1 of 1 pending (1 assets)
15:51:46.272 assets: 2921BE8A recorded 1 of 1 pending (1 assets)
15:51:46.384 assets: 6A2E2843 recorded 1 of 1 pending (1 assets)
15:51:46.488 assets: C5EAFEF5 recorded 1 of 1 pending (1 assets)
15:51:46.591 picplace: check (launch) — 0 pulled, 0 updated, 6 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
15:51:46.592 assets: D5207961 recorded 1 of 1 pending (1 assets)
15:51:46.709 assets: 2821386C recorded 1 of 1 pending (1 assets)
15:51:46.833 assets: 3913B08C recorded 1 of 1 pending (1 assets)
15:51:46.951 assets: F991BA5B recorded 1 of 1 pending (1 assets)
15:51:47.071 assets: F7AF9AD0 recorded 1 of 1 pending (1 assets)
15:51:47.316 picplace: unique-1549-6 — uploading 2 of 3 file(s), 5 MB; 1 already on PicPlace
15:51:47.700 picplace: unique-1549-1 — uploading 3 of 3 file(s), 5 MB
15:51:48.151 picplace: unique-1549-5 — uploading 3 of 3 file(s), 5,2 MB
15:51:48.552 picplace: unique-1549-3 — uploading 3 of 3 file(s), 5,4 MB
15:51:49.024 picplace: unique-1549-2 — uploading 3 of 3 file(s), 5,3 MB
15:51:49.426 picplace: unique-1549-4 — uploading 3 of 3 file(s), 3 MB
15:51:49.586 picplace: push queue — 6 sent, 0 failed
15:52:07.568 picplace: unique-1549-7 — uploading 2 of 3 file(s), 435 KB; 1 already on PicPlace
15:52:07.876 picplace: unique-1549-8 — uploading 2 of 3 file(s), 471 KB; 1 already on PicPlace
15:52:08.155 picplace: unique-1549-9 — uploading 2 of 3 file(s), 535 KB; 1 already on PicPlace
15:52:08.454 picplace: unique-1549-10 — uploading 2 of 3 file(s), 436 KB; 1 already on PicPlace
15:52:08.761 picplace: unique-1549-11 — uploading 2 of 3 file(s), 719 KB; 1 already on PicPlace
15:52:08.887 picplace: push queue — 5 sent, 0 failed
```

Full log: [`raw/02-mac-import-photos.log`](raw/02-mac-import-photos.log) · projects on the Mac 129 → 140, on the Simulator 128 → 128.

## 3. mac-edit-photos — Mac

_preset on 3 of the new photos._ 15:53:01 → 15:54:22 (80.2 s). Hooks: `LL_APPLY_PRESET=b07d0dee-22cb-4705-b9fc-25d1cedb643b:Cinema@2;f991ba5b-c587-4388-a38c-3b94689846cc:Matte@4;f7af9ad0-a0d2-4cc7-b6c8-d7fa668ea6f9:Vivid@6`

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 3 | 63 | 0 B | 9.5 KB |  |
| POST projects/{u}/claim | 3 | 45 | 60 B | 693 B |  |
| PUT projects/{u} | 3 | 45 | 4.1 KB | 3.0 KB |  |
| POST projects/{u}/assets | 3 | 40 | 1.0 KB | 5.0 KB |  |
| POST projects/{u}/presence | 3 | 31 | 132 B | 642 B |  |
| DELETE projects/{u}/claim | 3 | 30 | 0 B | 42 B |  |
| GET projects | 2 | 70 | 0 B | 289.7 KB |  |
| POST projects/{u}/assets/confirm | 2 | 41 | 268 B | 1.0 KB |  |
| POST device | 1 | 29 | 198 B | 445 B |  |
| GET nearby/key | 1 | 47 | 0 B | 135 B |  |
| GET projects?include_deleted=1 | 1 | 63 | 0 B | 146.9 KB |  |
| **total** | 25 | 45 | 5.8 KB | 457.1 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| PUT poster.jpg | 2 | 712.6 KB | 12 |
| **total** | 2 | 712.6 KB | 12 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| asset_replaced | 3 | 0 B | 0 B |
| copy_confirmed | 1 | 0 B | 0 B |
| manifest_written | 3 | 3.8 KB | 0 B |
| upload_confirmed | 2 | 712.6 KB | 0 B |

**Log highlights**

```
15:53:03.231 picplace: pacing requests under 300/min (255/min for sync work)
15:53:03.651 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
15:53:04.754 LL_APPLY_PRESET applied Cinema to B07D0DEE
15:53:06.853 LL_APPLY_PRESET applied Matte to F991BA5B
15:53:08.954 LL_APPLY_PRESET applied Vivid to F7AF9AD0
15:53:25.683 picplace: push queue — 1 sent, 0 failed
15:53:27.166 picplace: unique-1549-10 — uploading 1 of 2 file(s), 258 KB; 1 already on PicPlace
15:53:27.296 picplace: push queue — 1 sent, 0 failed
15:53:29.290 picplace: unique-1549-11 — uploading 1 of 2 file(s), 472 KB; 1 already on PicPlace
15:53:29.406 picplace: push queue — 1 sent, 0 failed
```

Full log: [`raw/03-mac-edit-photos.log`](raw/03-mac-edit-photos.log) · projects on the Mac 140 → 140, on the Simulator 128 → 128.

## 4. sim-pull — Simulator

_launch, pull every new project's preview._ 15:54:25 → 15:55:36 (70.6 s). Hooks: none beyond the trace

New projects on the Simulator: 11, 3.6 MB on disk.

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET projects/{u} | 11 | 25 | 0 B | 32.0 KB |  |
| POST projects/{u}/assets/urls | 11 | 22 | 990 B | 25.7 KB |  |
| POST projects/{u}/presence | 11 | 21 | 473 B | 4.5 KB |  |
| POST device | 2 | 38 | 402 B | 896 B |  |
| GET status | 2 | 60 | 0 B | 6.4 KB |  |
| GET projects?include_deleted=1 | 1 | 47 | 0 B | 146.9 KB |  |
| GET projects | 1 | 58 | 0 B | 144.9 KB |  |
| **total** | 39 | 27 | 1.8 KB | 361.1 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| GET poster.jpg | 11 | 3.6 MB | 9 |
| GET records.aar | 11 | 11.0 KB | 3 |
| **total** | 22 | 3.6 MB | 6 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| download_url_issued | 22 | 0 B | 3.6 MB |

**Log highlights**

```
15:54:28.855 picplace: pacing requests under 300/min (255/min for sync work)
15:54:29.102 picplace: pulled unique-1549-11 (f7af9ad0) — 2 object(s), 472760 bytes; 1 heavy file(s) stay on PicPlace
15:54:29.225 picplace: pulled unique-1549-10 (f991ba5b) — 2 object(s), 258443 bytes; 1 heavy file(s) stay on PicPlace
15:54:29.304 picplace: pulled unique-1549-1 (b07d0dee) — 2 object(s), 384312 bytes; 1 heavy file(s) stay on PicPlace
15:54:29.384 picplace: pulled unique-1549-9 (3913b08c) — 2 object(s), 348069 bytes; 1 heavy file(s) stay on PicPlace
15:54:29.493 picplace: pulled unique-1549-7 (d5207961) — 2 object(s), 292271 bytes; 1 heavy file(s) stay on PicPlace
15:54:29.568 picplace: pulled unique-1549-8 (2821386c) — 2 object(s), 301025 bytes; 1 heavy file(s) stay on PicPlace
15:54:29.654 picplace: pulled unique-1549-4 (2921be8a) — 2 object(s), 273698 bytes; 1 heavy file(s) stay on PicPlace
15:54:29.743 picplace: pulled unique-1549-3 (c985fa55) — 2 object(s), 380365 bytes; 1 heavy file(s) stay on PicPlace
15:54:29.824 picplace: pulled unique-1549-2 (aac77dc9) — 2 object(s), 369407 bytes; 1 heavy file(s) stay on PicPlace
15:54:29.900 picplace: pulled unique-1549-5 (6a2e2843) — 2 object(s), 371537 bytes; 1 heavy file(s) stay on PicPlace
15:54:29.990 picplace: pulled unique-1549-6 (c5eafef5) — 2 object(s), 327527 bytes; 1 heavy file(s) stay on PicPlace
15:54:29.992 picplace: check (foreground) — 11 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/04-sim-pull.log`](raw/04-sim-pull.log) · projects on the Mac 140 → 140, on the Simulator 128 → 139.

## 5. sim-download — Simulator

_download the originals of 3 photos not edited on the Mac (the just-in-time prompt's answer)._ 15:55:39 → 15:56:47 (68.5 s). Hooks: `LL_PICPLACE_DOWNLOAD=aac77dc9-02ca-4835-b857-6659e6d3a65b,c985fa55-18bd-497f-90c3-17b72c6f7b60,2921be8a-4bc2-4d8e-ab87-78eca66e31d6`

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET projects/{u} | 3 | 56 | 0 B | 8.7 KB |  |
| POST projects/{u}/assets/urls | 3 | 30 | 153 B | 3.5 KB |  |
| POST projects/{u}/presence | 3 | 35 | 132 B | 1.2 KB |  |
| GET status | 2 | 122 | 0 B | 6.4 KB |  |
| POST device | 1 | 21 | 201 B | 448 B |  |
| GET projects?include_deleted=1 | 1 | 72 | 0 B | 149.1 KB |  |
| GET projects | 1 | 72 | 0 B | 147.0 KB |  |
| **total** | 14 | 55 | 486 B | 316.3 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| GET source/* | 3 | 12.1 MB | 61 |
| **total** | 3 | 12.1 MB | 61 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| download_url_issued | 3 | 0 B | 12.1 MB |

**Log highlights**

```
15:55:41.493 picplace: pacing requests under 300/min (255/min for sync work)
15:55:41.643 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
15:55:41.669 picplace: check (launch) — a check finished 0 s ago; not repeated
15:55:41.832 assets: 2921BE8A recorded 0 of 0 pending (1 assets)
15:55:41.850 assets: C985FA55 recorded 0 of 0 pending (1 assets)
15:55:41.852 assets: AAC77DC9 recorded 0 of 0 pending (1 assets)
```

Full log: [`raw/05-sim-download.log`](raw/05-sim-download.log) · projects on the Mac 140 → 140, on the Simulator 139 → 139.

## 6. sim-edit — Simulator

_preset on those 3 photos._ 15:56:50 → 15:58:11 (80.5 s). Hooks: `LL_APPLY_PRESET=aac77dc9-02ca-4835-b857-6659e6d3a65b:Cinema@2;c985fa55-18bd-497f-90c3-17b72c6f7b60:Matte@4;2921be8a-4bc2-4d8e-ab87-78eca66e31d6:Vivid@6`

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 3 | 104 | 0 B | 9.6 KB |  |
| GET projects/{u} | 3 | 25 | 0 B | 8.7 KB |  |
| POST projects/{u}/claim | 3 | 50 | 60 B | 702 B |  |
| PUT projects/{u} | 3 | 47 | 4.1 KB | 3.6 KB |  |
| POST projects/{u}/assets | 3 | 36 | 1.0 KB | 8.6 KB |  |
| POST projects/{u}/assets/confirm | 3 | 54 | 768 B | 3.1 KB |  |
| POST projects/{u}/presence | 3 | 27 | 132 B | 1.2 KB |  |
| DELETE projects/{u}/claim | 3 | 23 | 0 B | 42 B |  |
| GET projects | 2 | 60 | 0 B | 294.1 KB |  |
| POST device | 1 | 41 | 201 B | 448 B |  |
| GET projects?include_deleted=1 | 1 | 48 | 0 B | 149.1 KB |  |
| POST projects/assets | 1 | 16 | 148 B | 1.9 KB |  |
| **total** | 29 | 46 | 6.4 KB | 481.0 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| PUT poster.jpg | 3 | 1.0 MB | 15 |
| PUT records.aar | 3 | 3.7 KB | 8 |
| **total** | 6 | 1.0 MB | 11 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| asset_replaced | 6 | 0 B | 0 B |
| manifest_written | 3 | 3.8 KB | 0 B |
| upload_confirmed | 6 | 1.0 MB | 0 B |

**Log highlights**

```
15:56:53.195 picplace: pacing requests under 300/min (255/min for sync work)
15:56:53.345 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 3 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
15:56:53.392 picplace: unique-1549-4 — all 1 heavy file(s) here verified on PicPlace: backed up
15:56:53.424 picplace: unique-1549-2 — all 1 heavy file(s) here verified on PicPlace: backed up
15:56:53.449 picplace: unique-1549-3 — all 1 heavy file(s) here verified on PicPlace: backed up
15:56:54.811 LL_APPLY_PRESET applied Cinema to AAC77DC9
15:56:56.898 LL_APPLY_PRESET applied Matte to C985FA55
15:56:58.997 LL_APPLY_PRESET applied Vivid to 2921BE8A
15:57:16.581 picplace: unique-1549-2 — uploading 2 of 2 file(s), 388 KB
15:57:16.733 picplace: push queue — 1 sent, 0 failed
15:57:17.530 picplace: unique-1549-3 — uploading 2 of 2 file(s), 389 KB
15:57:17.665 picplace: push queue — 1 sent, 0 failed
15:57:19.507 picplace: unique-1549-4 — uploading 2 of 2 file(s), 303 KB
15:57:19.613 picplace: push queue — 1 sent, 0 failed
```

Full log: [`raw/06-sim-edit.log`](raw/06-sim-edit.log) · projects on the Mac 140 → 140, on the Simulator 139 → 139.

## 7. mac-after — Mac

_launch, one check: what the Simulator's edits cost the Mac._ 15:58:14 → 15:59:22 (68.2 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET projects/{u} | 3 | 32 | 0 B | 11.1 KB |  |
| POST projects/{u}/assets/urls | 3 | 27 | 270 B | 7.0 KB |  |
| POST projects/{u}/presence | 3 | 22 | 78 B | 1.2 KB |  |
| GET status | 2 | 55 | 0 B | 6.4 KB |  |
| POST device | 1 | 27 | 198 B | 445 B |  |
| GET nearby/key | 1 | 13 | 0 B | 135 B |  |
| GET projects | 1 | 58 | 0 B | 147.0 KB |  |
| GET projects?include_deleted=1 | 1 | 55 | 0 B | 149.1 KB |  |
| **total** | 15 | 34 | 546 B | 322.4 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| GET poster.jpg | 3 | 1.0 MB | 9 |
| GET records.aar | 3 | 3.7 KB | 2 |
| **total** | 6 | 1.0 MB | 6 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| download_url_issued | 6 | 0 B | 1.0 MB |

**Log highlights**

```
15:58:15.748 picplace: pacing requests under 300/min (255/min for sync work)
15:58:16.382 picplace: check (launch) — 0 pulled, 3 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 1 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/07-mac-after.log`](raw/07-mac-after.log) · projects on the Mac 140 → 140, on the Simulator 139 → 139.
