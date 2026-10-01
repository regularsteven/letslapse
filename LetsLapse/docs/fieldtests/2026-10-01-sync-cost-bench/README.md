# PicPlace sync-cost bench: 2026-10-01

**Started** 2026-10-01T07:53:54 · **finished** 2026-10-01T08:21:24 · raw logs and `run.json` in [`raw/`](raw/).

A data pack, not an analysis. Every request comes from the app's own `picplace trace:` lines (`LL_PICPLACE_TRACE=1`): API bodies are JSON bytes without headers; storage bytes are the object's bytes. Ledger rows are the server's `letslapse_usage_events` for the account. Each step is one launch of the app with the hooks shown, settled until its log was quiet, then quit; a launch's own check (2 to 5 requests) is inside each step's figures.

## Inputs

- Photos: 14 file(s) — `/Users/stevenwright/Documents/dev/letslapse-testing/camera-dngs/Photo 29. 7. at 1554.dng` …
- `.lapse` projects: 102 file(s) — `/Users/stevenwright/Documents/dev/letslapse-testing/synth-lapse/archives/broad-mix--buildings.01.lapse` …
- Mac library `/Users/stevenwright/Pictures/LetsLapse/synth`, Simulator `C8F8FCC2-5DBC-4B87-B7FE-06D1085C7996`, server `https://picplace.test`, account `synth`.
- Simulator edit mode: **download** (download = the originals come down first, as the editor's just-in-time prompt would; preview = the preset is written over the preview alone).

## Summary

| Step | Device | s | API req | API up | API down | PUTs | PUT bytes | GETs | GET bytes | New projects | API req / new project |
|---|---|---|---|---|---|---|---|---|---|---|---|
| mac-baseline | Mac | 70.1 | 11 | 396 B | 16.4 KB | 0 | 0 B | 0 | 0 B |  |  |
| mac-import-photos | Mac | 78.2 | 198 | 32.4 KB | 393.8 KB | 42 | 66.1 MB | 0 | 0 B | 14 | 14.1 |
| mac-edit-photos | Mac | 78.2 | 31 | 6.1 KB | 66.2 KB | 3 | 1.1 MB | 0 | 0 B |  |  |
| mac-import-lapse | Mac | 425.8 | 1503 | 220.0 KB | 6.6 MB | 303 | 86.9 MB | 0 | 0 B | 101 | 14.9 |
| mac-edit-lapse | Mac | 78.3 | 31 | 6.1 KB | 306.8 KB | 5 | 874.9 KB | 0 | 0 B |  |  |
| sim-pull | Simulator | 119.4 | 467 | 16.5 KB | 822.2 KB | 0 | 0 B | 230 | 30.0 MB | 115 | 4.1 |
| sim-download | Simulator | 70.7 | 25 | 634 B | 387.6 KB | 0 | 0 B | 3 | 18.9 MB |  |  |
| sim-edit | Simulator | 80.5 | 33 | 6.4 KB | 497.9 KB | 6 | 1.1 MB | 0 | 0 B |  |  |
| mac-after | Mac | 611.5 | 22 | 582 B | 262.3 KB | 0 | 0 B | 6 | 1.1 MB |  |  |

Sync-state files at the end: Mac 71.3 KB, Simulator 62.6 KB.

## Server, start → end

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| asset_replaced | 14 | 0 B | 0 B |
| download_url_issued | 239 | 0 B | 49.9 MB |
| manifest_written | 239 | 115.4 KB | 0 B |
| upload_confirmed | 359 | 156.0 MB | 0 B |

Account tables at the end:

| Table | Value |
|---|---|
| projects live / trashed | 115 / 3 |
| projects by type | {"interval": 1, "photo": 117} |
| manifest bytes | 61.4 KB |
| assets | preview confirmed: 118 (30.2 MB); records confirmed: 118 (584.1 KB); source confirmed: 118 (124.1 MB) |
| presences by tier | {"original": 121, "preview": 113} |
| index rows / name NULL / records indexed | 118 / 117 / 0 |
| pending uploads | 0 |

## 1. mac-baseline — Mac

_launch, one check, quit._ 07:54:03 → 07:55:13 (70.1 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 6 | 36 | 0 B | 12.3 KB |  |
| POST device | 2 | 24 | 396 B | 890 B |  |
| GET nearby/key | 1 | 16 | 0 B | 135 B |  |
| GET projects | 1 | 18 | 0 B | 57 B |  |
| GET projects?include_deleted=1 | 1 | 38 | 0 B | 3.0 KB |  |
| **total** | 11 | 31 | 396 B | 16.4 KB |  |

**Storage transfers**

_none_

**Ledger rows written during the step**

_no ledger rows_

**Log highlights**

```
07:54:04.424 picplace: pacing requests under 300/min (255/min for sync work)
07:54:04.603 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/01-mac-baseline.log`](raw/01-mac-baseline.log) · projects on the Mac 0 → 0, on the Simulator 1 → 1.

## 2. mac-import-photos — Mac

_import 14 photo(s) as separate projects; push, originals up._ 07:55:16 → 07:56:34 (78.2 s). Hooks: `LL_IMPORT_STILLS=/Users/stevenwright/Documents/dev/letslapse-testing/camera-dngs/Photo 29. 7. at 1554.dng:/Users/stevenwright/Documents/dev/letslapse-testing/camera-dngs/Photo 29. 7. at 1614.dng:/Users/stevenwright/Do…`, `LL_IMPORT_ANSWER=photos`

Edited (origin ids): `89345046`, `482031c0`, `49a122c5`

Chosen for the Simulator's edits: `0e6ff819`, `5bddd7f8`, `c58eda80`

New projects on the Mac: 14, 66.1 MB on disk.

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| POST projects/{u}/claim | 28 | 28 | 560 B | 215.1 KB |  |
| PUT projects/{u} | 28 | 38 | 17.7 KB | 25.8 KB |  |
| POST projects/{u}/assets | 28 | 29 | 7.4 KB | 54.1 KB |  |
| POST projects/{u}/assets/confirm | 28 | 37 | 5.3 KB | 22.4 KB |  |
| POST projects/{u}/presence | 28 | 23 | 1.2 KB | 5.9 KB |  |
| DELETE projects/{u}/claim | 28 | 20 | 0 B | 392 B |  |
| GET projects/{u} | 14 | 24 | 0 B | 31.5 KB |  |
| GET status | 10 | 55 | 0 B | 21.3 KB |  |
| GET projects | 3 | 26 | 0 B | 13.7 KB |  |
| POST device | 1 | 25 | 198 B | 445 B |  |
| GET nearby/key | 1 | 15 | 0 B | 135 B |  |
| GET projects?include_deleted=1 | 1 | 45 | 0 B | 3.0 KB |  |
| **total** | 198 | 30 | 32.4 KB | 393.8 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| PUT poster.jpg | 14 | 4.7 MB | 9 |
| PUT records.aar | 14 | 14.8 KB | 4 |
| PUT source/* | 14 | 61.4 MB | 41 |
| **total** | 42 | 66.1 MB | 18 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| manifest_written | 28 | 13.5 KB | 0 B |
| upload_confirmed | 42 | 66.1 MB | 0 B |

**Log highlights**

```
07:55:17.468 picplace: pacing requests under 300/min (255/min for sync work)
07:55:17.586 assets: C58EDA80 recorded 1 of 1 pending (1 assets)
07:55:17.648 assets: A2B269D5 recorded 1 of 1 pending (1 assets)
07:55:17.688 assets: 92D074DA recorded 1 of 1 pending (1 assets)
07:55:17.705 picplace: check (launch) — 0 pulled, 0 updated, 3 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
07:55:17.714 assets: 482031C0 recorded 1 of 1 pending (1 assets)
07:55:17.750 assets: 49A122C5 recorded 1 of 1 pending (1 assets)
07:55:17.796 assets: 0E6FF819 recorded 1 of 1 pending (1 assets)
07:55:17.882 assets: 5BDDD7F8 recorded 1 of 1 pending (1 assets)
07:55:17.893 assets: 89345046 recorded 1 of 1 pending (1 assets)
07:55:17.932 assets: 37EBDFB2 recorded 1 of 1 pending (1 assets)
07:55:17.974 assets: CCCB017C recorded 1 of 1 pending (1 assets)
07:55:18.018 assets: 1B3132AE recorded 1 of 1 pending (1 assets)
07:55:18.061 assets: FC972C8F recorded 1 of 1 pending (1 assets)
07:55:18.109 assets: 9D7E7143 recorded 1 of 1 pending (1 assets)
07:55:18.153 assets: FFE59492 recorded 1 of 1 pending (1 assets)
07:55:18.277 picplace: Photo 29. 7. at 1554 — uploading 2 of 2 file(s), 446 KB
07:55:18.716 picplace: Photo of rocks — uploading 2 of 2 file(s), 412 KB
07:55:19.014 picplace: Photo 29. 7. at 1614 — uploading 2 of 2 file(s), 273 KB
07:55:19.111 picplace: push queue — 3 sent, 0 failed
07:55:19.232 picplace: Photo of rocks — uploading 1 of 1 file(s), 12 MB
07:55:19.550 picplace: Photo 29. 7. at 1554 — uploading 1 of 1 file(s), 12,2 MB
07:55:19.859 picplace: Photo 29. 7. at 1614 — uploading 1 of 1 file(s), 10,4 MB
07:55:38.492 picplace: 3db344e3-5a1b-4be4-816e-b5d3ffb97d11 — uploading 2 of 2 file(s), 369 KB
07:55:38.793 picplace: 5b503e1f-30b9-4037-91ce-8d5a6e7fe856 — uploading 2 of 2 file(s), 380 KB
07:55:39.088 picplace: 6daeaac6-dcb8-4cac-b873-cd9bb4536bc9 — uploading 2 of 2 file(s), 274 KB
07:55:39.417 picplace: 8b672eb3-5221-4df3-beef-d69b6f1c292c — uploading 2 of 2 file(s), 372 KB
07:55:39.681 picplace: 16c080c7-a9b0-426c-8a53-a6975815bda7 — uploading 2 of 2 file(s), 412 KB
07:55:39.876 picplace: broad-mix--arches.01 — uploading 2 of 2 file(s), 292 KB
07:55:40.085 picplace: broad-mix--arches.02 — uploading 2 of 2 file(s), 301 KB
07:55:40.364 picplace: ae1fa114-51a5-4f29-b101-94eaead64d00 — uploading 2 of 2 file(s), 328 KB
07:55:40.644 picplace: broad-mix--arches.04 — uploading 2 of 2 file(s), 293 KB
07:55:40.855 picplace: broad-mix--arches.05 — uploading 2 of 2 file(s), 462 KB
07:55:41.052 picplace: broad-mix--arches.03 — uploading 2 of 2 file(s), 348 KB
07:55:41.248 picplace: push queue — 11 sent, 0 failed
07:55:41.362 picplace: 8b672eb3-5221-4df3-beef-d69b6f1c292c — uploading 1 of 1 file(s), 4,8 MB
07:55:41.584 picplace: 5b503e1f-30b9-4037-91ce-8d5a6e7fe856 — uploading 1 of 1 file(s), 5 MB
07:55:41.818 picplace: 3db344e3-5a1b-4be4-816e-b5d3ffb97d11 — uploading 1 of 1 file(s), 5 MB
07:55:42.070 picplace: 16c080c7-a9b0-426c-8a53-a6975815bda7 — uploading 1 of 1 file(s), 4,6 MB
07:55:42.301 picplace: ae1fa114-51a5-4f29-b101-94eaead64d00 — uploading 1 of 1 file(s), 5 MB
07:55:42.550 picplace: 6daeaac6-dcb8-4cac-b873-cd9bb4536bc9 — uploading 1 of 1 file(s), 2,7 MB
07:55:42.780 picplace: broad-mix--arches.02 — uploading 1 of 1 file(s), 471 KB
07:55:42.953 picplace: broad-mix--arches.04 — uploading 1 of 1 file(s), 435 KB
07:55:43.104 picplace: broad-mix--arches.01 — uploading 1 of 1 file(s), 434 KB
07:55:43.268 picplace: broad-mix--arches.03 — uploading 1 of 1 file(s), 535 KB
07:55:43.435 picplace: broad-mix--arches.05 — uploading 1 of 1 file(s), 718 KB
```

Full log: [`raw/02-mac-import-photos.log`](raw/02-mac-import-photos.log) · projects on the Mac 0 → 14, on the Simulator 1 → 1.

## 3. mac-edit-photos — Mac

_preset on 3 of the new photos._ 07:56:37 → 07:57:56 (78.2 s). Hooks: `LL_APPLY_PRESET=89345046-965f-4821-aaae-c10546fbd60d:Cinema@2;482031c0-fbd8-418d-b4d0-986c9091fe68:Matte@4;49a122c5-6351-45e3-bb07-43d43929bbbe:Vivid@6`

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 8 | 35 | 0 B | 17.1 KB |  |
| POST projects/{u}/claim | 3 | 38 | 60 B | 693 B |  |
| PUT projects/{u} | 3 | 36 | 4.3 KB | 3.1 KB |  |
| POST projects/{u}/assets | 3 | 21 | 1.0 KB | 5.8 KB |  |
| POST projects/{u}/assets/confirm | 3 | 31 | 402 B | 1.6 KB |  |
| POST projects/{u}/presence | 3 | 19 | 132 B | 642 B |  |
| DELETE projects/{u}/claim | 3 | 15 | 0 B | 42 B |  |
| GET projects | 2 | 28 | 0 B | 22.5 KB |  |
| POST device | 1 | 58 | 198 B | 445 B |  |
| GET nearby/key | 1 | 20 | 0 B | 135 B |  |
| GET projects?include_deleted=1 | 1 | 18 | 0 B | 14.2 KB |  |
| **total** | 31 | 29 | 6.1 KB | 66.2 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| PUT poster.jpg | 3 | 1.1 MB | 10 |
| **total** | 3 | 1.1 MB | 10 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| asset_replaced | 3 | 0 B | 0 B |
| manifest_written | 3 | 3.9 KB | 0 B |
| upload_confirmed | 3 | 1.1 MB | 0 B |

**Log highlights**

```
07:56:38.776 picplace: pacing requests under 300/min (255/min for sync work)
07:56:38.980 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
07:56:40.523 LL_APPLY_PRESET applied Cinema to 89345046
07:56:42.623 LL_APPLY_PRESET applied Matte to 482031C0
07:56:44.697 LL_APPLY_PRESET applied Vivid to 49A122C5
07:57:02.461 picplace: 16c080c7-a9b0-426c-8a53-a6975815bda7 — uploading 1 of 2 file(s), 383 KB; 1 already on PicPlace
07:57:02.559 picplace: push queue — 1 sent, 0 failed
07:57:02.858 picplace: 3db344e3-5a1b-4be4-816e-b5d3ffb97d11 — uploading 1 of 2 file(s), 335 KB; 1 already on PicPlace
07:57:02.929 picplace: push queue — 1 sent, 0 failed
07:57:05.599 picplace: 5b503e1f-30b9-4037-91ce-8d5a6e7fe856 — uploading 1 of 2 file(s), 389 KB; 1 already on PicPlace
07:57:05.676 picplace: push queue — 1 sent, 0 failed
```

Full log: [`raw/03-mac-edit-photos.log`](raw/03-mac-edit-photos.log) · projects on the Mac 14 → 14, on the Simulator 1 → 1.

## 4. mac-import-lapse — Mac

_import 102 .lapse project(s); push, originals up._ 07:57:59 → 08:05:05 (425.8 s). Hooks: `LL_IMPORT_ARCHIVE=/Users/stevenwright/Documents/dev/letslapse-testing/synth-lapse/archives/broad-mix--buildings.01.lapse:/Users/stevenwright/Documents/dev/letslapse-testing/synth-lapse/archives/broad-mix--buildings.02.…`

Edited (origin ids): `84a1e3ef`, `2eca2cb8`, `8206c7f5`

New projects on the Mac: 101, 89.0 MB on disk.

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| POST projects/{u}/claim | 202 | 31 | 3.9 KB | 1.5 MB |  |
| PUT projects/{u} | 202 | 49 | 117.4 KB | 183.2 KB |  |
| POST projects/{u}/assets | 202 | 40 | 51.3 KB | 388.2 KB |  |
| POST projects/{u}/assets/confirm | 202 | 47 | 38.5 KB | 159.6 KB |  |
| POST projects/{u}/presence | 202 | 32 | 8.7 KB | 42.2 KB |  |
| DELETE projects/{u}/claim | 202 | 27 | 0 B | 2.8 KB |  |
| GET status | 126 | 61 | 0 B | 270.3 KB |  |
| GET projects/{u} | 101 | 39 | 0 B | 222.4 KB |  |
| GET projects | 61 | 56 | 0 B | 3.8 MB |  |
| POST device | 1 | 113 | 198 B | 445 B |  |
| GET nearby/key | 1 | 79 | 0 B | 135 B |  |
| GET projects?include_deleted=1 | 1 | 42 | 0 B | 14.2 KB |  |
| **total** | 1503 | 41 | 220.0 KB | 6.6 MB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| PUT poster.jpg | 101 | 24.8 MB | 13 |
| PUT records.aar | 101 | 549.0 KB | 11 |
| PUT source/* | 101 | 61.6 MB | 17 |
| **total** | 303 | 86.9 MB | 13 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| manifest_written | 202 | 90.3 KB | 0 B |
| upload_confirmed | 303 | 86.9 MB | 0 B |

**Log highlights**

```
07:58:00.104 assets: 5F58F964 recorded 1 of 1 pending (1 assets)
07:58:00.664 assets: 4843E4BB recorded 1 of 1 pending (1 assets)
07:58:01.327 assets: AE4A998B recorded 1 of 1 pending (1 assets)
07:58:01.671 picplace: pacing requests under 300/min (255/min for sync work)
07:58:02.011 assets: 1FD663AE recorded 1 of 1 pending (1 assets)
07:58:02.688 assets: BC685BE4 recorded 1 of 1 pending (1 assets)
07:58:03.361 assets: A9135376 recorded 1 of 1 pending (1 assets)
07:58:04.031 assets: BAD7C36C recorded 1 of 1 pending (1 assets)
07:58:04.370 picplace: check (launch) — 0 pulled, 0 updated, 6 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 1 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
07:58:04.704 assets: 2F261379 recorded 1 of 1 pending (1 assets)
07:58:05.389 assets: 5DBF2B8B recorded 1 of 1 pending (1 assets)
07:58:06.066 assets: EAADEAB9 recorded 1 of 1 pending (1 assets)
07:58:06.755 assets: 362C641E recorded 1 of 1 pending (1 assets)
07:58:07.432 picplace: buildings.07 — uploading 2 of 2 file(s), 228 KB
07:58:07.433 assets: 1110B8C2 recorded 1 of 1 pending (1 assets)
07:58:08.103 assets: 5A339AEE recorded 1 of 1 pending (1 assets)
07:58:08.773 assets: 83FE4E09 recorded 1 of 1 pending (1 assets)
07:58:09.468 assets: ABB5E101 recorded 1 of 1 pending (1 assets)
07:58:10.143 assets: 96874F67 recorded 1 of 1 pending (1 assets)
07:58:10.833 assets: AB1A967C recorded 1 of 1 pending (1 assets)
07:58:11.519 assets: 864A0747 recorded 1 of 1 pending (1 assets)
07:58:12.187 picplace: buildings.04 — uploading 2 of 2 file(s), 243 KB
07:58:12.188 assets: F251FC07 recorded 1 of 1 pending (1 assets)
07:58:12.884 assets: DDDFFC1C recorded 1 of 1 pending (1 assets)
07:58:13.567 assets: 57F24AEA recorded 1 of 1 pending (1 assets)
07:58:14.231 assets: 7481A31E recorded 1 of 1 pending (1 assets)
07:58:14.920 assets: D66A4C81 recorded 1 of 1 pending (1 assets)
07:58:15.605 assets: 2510B45E recorded 1 of 1 pending (1 assets)
07:58:16.288 assets: 99AE9C58 recorded 1 of 1 pending (1 assets)
07:58:16.973 picplace: buildings.03 — uploading 2 of 2 file(s), 309 KB
… 247 line(s) left out …
08:03:15.211 picplace: flower.07 — uploading 1 of 1 file(s), 1,1 MB
08:03:15.489 picplace: flower.08 — uploading 1 of 1 file(s), 779 KB
08:03:15.760 picplace: flower.09 — uploading 1 of 1 file(s), 430 KB
08:03:16.143 picplace: flower.09 — uploading 1 of 1 file(s), 864 KB
08:03:16.426 picplace: flower.10 — uploading 1 of 1 file(s), 901 KB
08:03:18.355 picplace: flower.10 — uploading 1 of 1 file(s), 414 KB
08:03:21.817 picplace: flower.11 — uploading 1 of 1 file(s), 997 KB
08:03:27.923 picplace: flower.12 — uploading 1 of 1 file(s), 1,2 MB
08:03:32.943 picplace: trams-city.01 — uploading 1 of 1 file(s), 501 KB
08:03:37.754 picplace: trams-city.02 — uploading 1 of 1 file(s), 433 KB
08:03:42.618 picplace: trams-city.03 — uploading 1 of 1 file(s), 388 KB
08:03:47.580 picplace: trams-city.04 — uploading 1 of 1 file(s), 367 KB
08:03:51.783 picplace: trams-city.05 — uploading 1 of 1 file(s), 420 KB
08:03:56.610 picplace: trams-city.06 — uploading 1 of 1 file(s), 372 KB
08:04:01.445 picplace: trams-city.07 — uploading 1 of 1 file(s), 422 KB
08:04:06.428 picplace: trams-city.08 — uploading 1 of 1 file(s), 449 KB
08:04:10.001 picplace: trams-city.09 — uploading 1 of 1 file(s), 532 KB
08:04:10.318 picplace: trams-nature.01 — uploading 1 of 1 file(s), 495 KB
08:04:10.675 picplace: trams-nature.02 — uploading 1 of 1 file(s), 558 KB
08:04:10.953 picplace: trams-nature.03 — uploading 1 of 1 file(s), 491 KB
08:04:11.186 picplace: trams-nature.04 — uploading 1 of 1 file(s), 447 KB
08:04:11.576 picplace: tram.01 — uploading 1 of 1 file(s), 471 KB
08:04:11.915 picplace: windows.01 — uploading 1 of 1 file(s), 357 KB
08:04:12.179 picplace: windows.02 — uploading 1 of 1 file(s), 537 KB
08:04:12.519 picplace: windows.03 — uploading 1 of 1 file(s), 474 KB
08:04:12.805 picplace: windows.04 — uploading 1 of 1 file(s), 434 KB
08:04:13.272 picplace: windows.05 — uploading 1 of 1 file(s), 422 KB
08:04:13.562 picplace: windows.06 — uploading 1 of 1 file(s), 428 KB
08:04:13.801 picplace: building.01 — uploading 1 of 1 file(s), 386 KB
08:04:13.989 picplace: single.oldtown.dusk.near — uploading 1 of 1 file(s), 305 KB
```

Full log: [`raw/04-mac-import-lapse.log`](raw/04-mac-import-lapse.log) · projects on the Mac 14 → 115, on the Simulator 1 → 1.

## 5. mac-edit-lapse — Mac

_preset on 3 of the imported .lapse projects._ 08:05:08 → 08:06:26 (78.3 s). Hooks: `LL_APPLY_PRESET=84a1e3ef-3185-4068-a500-25a8e6fe9f3e:Cinema@2;2eca2cb8-0b44-4a9f-b58c-779d5fc6b0db:Matte@4;8206c7f5-309a-46df-ba38-7efb78dfda79:Vivid@6`

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 8 | 51 | 0 B | 17.2 KB |  |
| POST projects/{u}/claim | 3 | 41 | 60 B | 693 B |  |
| PUT projects/{u} | 3 | 42 | 4.1 KB | 3.0 KB |  |
| POST projects/{u}/assets | 3 | 37 | 1.0 KB | 7.6 KB |  |
| POST projects/{u}/assets/confirm | 3 | 56 | 646 B | 2.6 KB |  |
| POST projects/{u}/presence | 3 | 26 | 132 B | 642 B |  |
| DELETE projects/{u}/claim | 3 | 24 | 0 B | 42 B |  |
| GET projects | 2 | 43 | 0 B | 180.9 KB |  |
| POST device | 1 | 32 | 198 B | 445 B |  |
| GET nearby/key | 1 | 17 | 0 B | 135 B |  |
| GET projects?include_deleted=1 | 1 | 50 | 0 B | 93.4 KB |  |
| **total** | 31 | 41 | 6.1 KB | 306.8 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| PUT poster.jpg | 3 | 864.2 KB | 14 |
| PUT records.aar | 2 | 10.7 KB | 13 |
| **total** | 5 | 874.9 KB | 13 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| asset_replaced | 5 | 0 B | 0 B |
| manifest_written | 3 | 3.8 KB | 0 B |
| upload_confirmed | 5 | 874.9 KB | 0 B |

**Log highlights**

```
08:05:09.273 picplace: pacing requests under 300/min (255/min for sync work)
08:05:09.791 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
08:05:10.908 LL_APPLY_PRESET applied Cinema to 9D5B874A
08:05:12.896 LL_APPLY_PRESET applied Matte to 5BFA40CB
08:05:15.165 LL_APPLY_PRESET applied Vivid to 4843E4BB
08:05:31.720 picplace: arch.01 — uploading 2 of 2 file(s), 341 KB
08:05:31.874 picplace: push queue — 1 sent, 0 failed
08:05:33.361 picplace: building.01 — uploading 2 of 2 file(s), 234 KB
08:05:33.508 picplace: push queue — 1 sent, 0 failed
08:05:35.450 picplace: buildings.02 — uploading 1 of 2 file(s), 321 KB; 1 already on PicPlace
08:05:35.554 picplace: push queue — 1 sent, 0 failed
```

Full log: [`raw/05-mac-edit-lapse.log`](raw/05-mac-edit-lapse.log) · projects on the Mac 115 → 115, on the Simulator 1 → 1.

## 6. sim-pull — Simulator

_launch, pull every new project's preview._ 08:06:29 → 08:08:29 (119.4 s). Hooks: none beyond the trace

New projects on the Simulator: 115, 32.1 MB on disk.

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| POST projects/{u}/assets/urls | 230 | 21 | 11.5 KB | 269.8 KB |  |
| GET projects/{u} | 115 | 23 | 0 B | 312.7 KB |  |
| POST projects/{u}/presence | 115 | 19 | 4.8 KB | 46.7 KB |  |
| GET status | 4 | 47 | 0 B | 8.6 KB |  |
| GET projects?include_deleted=1 | 1 | 88 | 0 B | 93.4 KB |  |
| POST device | 1 | 17 | 201 B | 448 B |  |
| GET projects | 1 | 43 | 0 B | 90.5 KB |  |
| **total** | 467 | 22 | 16.5 KB | 822.2 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| GET 01a0f608-0e7b-73e4-af3a-619c65b290ae | 1 | 434.0 KB | 9 |
| GET 01a0f608-0e80-7064-a80d-6e1f159e92d5 | 1 | 1.2 KB | 2 |
| GET 01a0f608-1031-73ad-86e3-f03b569e3424 | 1 | 401.4 KB | 7 |
| GET 01a0f608-1037-733d-9a06-814273f1e15e | 1 | 1.2 KB | 2 |
| GET 01a0f608-115a-7155-9316-33b50b04ad72 | 1 | 265.0 KB | 7 |
| GET 01a0f608-1161-7047-a86a-73b3d35f284c | 1 | 1.2 KB | 3 |
| GET 01a0f608-5d6f-7012-b32e-6faae5eb9747 | 1 | 327.1 KB | 15 |
| GET 01a0f608-5d77-72d7-84b5-5dde563dc12d | 1 | 1.2 KB | 3 |
| GET 01a0f608-5e9e-7207-9bdb-2dc98d72e009 | 1 | 379.7 KB | 10 |
| GET 01a0f608-5ea4-7074-9e2e-6fca16651d4f | 1 | 1.2 KB | 3 |
| GET 01a0f608-5fba-7053-af59-fe8ffdc33cd5 | 1 | 266.0 KB | 5 |
| GET 01a0f608-5fca-7161-a302-3a1373271339 | 1 | 1.3 KB | 2 |
| GET 01a0f608-6112-7146-bab0-ad699e618d8a | 1 | 361.6 KB | 11 |
| GET 01a0f608-6116-7294-b781-6b30530a252d | 1 | 1.2 KB | 2 |
| GET 01a0f608-6213-72b6-a908-215fce5d0917 | 1 | 374.1 KB | 8 |
| GET 01a0f608-621b-7311-b741-e576b2d18f69 | 1 | 1.3 KB | 2 |
| GET 01a0f608-62d9-7389-93fe-9ecaeeb69b04 | 1 | 284.7 KB | 6 |
| GET 01a0f608-62df-7177-9d22-b38a61562b1e | 1 | 752 B | 7 |
| GET 01a0f608-63a8-73db-b42e-164b106a697f | 1 | 293.2 KB | 8 |
| GET 01a0f608-63ae-715a-a56a-0ca485c6d23c | 1 | 754 B | 3 |
| GET 01a0f608-64be-72fc-a70f-677e812c11a1 | 1 | 318.6 KB | 8 |
| GET 01a0f608-64c8-72e4-9226-b7652d08b67d | 1 | 1.2 KB | 2 |
| GET 01a0f608-65d8-703f-bdb2-5f2cc9e53733 | 1 | 285.9 KB | 7 |
| GET 01a0f608-65df-738a-a2db-92df345a74f2 | 1 | 749 B | 3 |
| GET 01a0f608-66ac-7152-9b0c-dd778766952a | 1 | 450.1 KB | 9 |
| GET 01a0f608-66b1-71e1-9778-3d36fd5194a7 | 1 | 752 B | 3 |
| GET 01a0f608-676e-7115-92dc-01c9ff8f2050 | 1 | 339.2 KB | 8 |
| GET 01a0f608-6776-7338-86a9-e64384b9a016 | 1 | 752 B | 3 |
| GET 01a0f60a-a21a-7349-9502-f75eb830c2db | 1 | 213.5 KB | 7 |
| GET 01a0f60a-a223-7167-951b-df7df0efc9d1 | 1 | 9.4 KB | 5 |
| GET 01a0f60a-b4b3-734b-9742-ac555acc072c | 1 | 224.1 KB | 5 |
| GET 01a0f60a-b4ba-7000-99e7-e53e6a4cea94 | 1 | 12.7 KB | 3 |
| GET 01a0f60a-c761-72ae-8e79-5ec6bc3db79c | 1 | 288.1 KB | 9 |
| GET 01a0f60a-c76a-7221-89b8-b05d0ec817a3 | 1 | 13.7 KB | 8 |
| GET 01a0f60a-da22-72d5-aef0-44c56fb489fb | 1 | 313.1 KB | 7 |
| GET 01a0f60a-da28-71ed-8383-e4fe9d3f05c3 | 1 | 9.6 KB | 11 |
| GET 01a0f60a-ed03-72ee-ada3-15ed44ec7176 | 1 | 168.4 KB | 7 |
| GET 01a0f60a-ed08-70c5-bd38-81888ec64fb8 | 1 | 9.5 KB | 6 |
| GET 01a0f60a-ffec-72cd-b282-fe839008bdb5 | 1 | 238.1 KB | 5 |
| GET 01a0f60a-fff4-701d-8c23-470bc6eb3bf4 | 1 | 12.1 KB | 5 |
| GET 01a0f60b-12f8-7249-b33b-9bd926713578 | 1 | 175.0 KB | 13 |
| GET 01a0f60b-1300-72e2-807a-83342dc48947 | 1 | 8.2 KB | 4 |
| GET 01a0f60b-25dc-710c-a99f-234525970e67 | 1 | 281.9 KB | 13 |
| GET 01a0f60b-25e7-72a1-ab2c-2ef4fb42b41d | 1 | 5.1 KB | 4 |
| GET 01a0f60b-394b-70ad-807c-ae9ab25492d3 | 1 | 302.8 KB | 8 |
| GET 01a0f60b-3951-7157-879a-2f16c18b3613 | 1 | 3.7 KB | 4 |
| GET 01a0f60b-499f-727b-aa15-8c4c3cfa6fc5 | 1 | 313.4 KB | 8 |
| GET 01a0f60b-49a8-738b-b4eb-7d0f8b9aeb86 | 1 | 3.8 KB | 3 |
| GET 01a0f60b-5c98-7356-8063-166a67f85bc5 | 1 | 291.3 KB | 5 |
| GET 01a0f60b-5c9e-727e-a3e5-f7fe3bd50923 | 1 | 4.3 KB | 5 |
| GET 01a0f60b-6fa6-7195-92f7-7c6d0afd265b | 1 | 304.6 KB | 13 |
| GET 01a0f60b-6fae-72e7-8796-9c6f23edf4b3 | 1 | 5.1 KB | 4 |
| GET 01a0f60b-82aa-73d3-814b-66cce7cb6c70 | 1 | 332.1 KB | 7 |
| GET 01a0f60b-82b3-7009-bf40-254ec7b2c1c2 | 1 | 4.3 KB | 4 |
| GET 01a0f60b-95bb-7377-a8ae-46bce47098ca | 1 | 293.5 KB | 10 |
| GET 01a0f60b-95c2-70d6-a5a1-7ab0294332ba | 1 | 5.1 KB | 5 |
| GET 01a0f60b-96a9-720c-9f28-729a7c410162 | 1 | 263.7 KB | 8 |
| GET 01a0f60b-96b0-701c-9722-428e04e76722 | 1 | 4.8 KB | 3 |
| GET 01a0f60b-979c-724b-8bcd-6d6622f978d3 | 1 | 288.4 KB | 8 |
| GET 01a0f60b-97a3-7258-aeef-16f059816dc4 | 1 | 4.3 KB | 4 |
| GET 01a0f60b-9847-73d2-90e4-bdd31bd071c8 | 1 | 276.2 KB | 10 |
| GET 01a0f60b-984b-719d-8e2a-aa30c8feb912 | 1 | 4.3 KB | 4 |
| GET 01a0f60b-98ef-700c-9b5f-de85bec93e42 | 1 | 371.2 KB | 9 |
| GET 01a0f60b-98f4-724f-a8d2-41e5d52754af | 1 | 4.0 KB | 4 |
| GET 01a0f60b-99c2-735e-935e-3405e312bfd8 | 1 | 364.1 KB | 8 |
| GET 01a0f60b-99c6-72fa-9d93-6c147f42c4da | 1 | 4.1 KB | 4 |
| GET 01a0f60b-9aab-731e-8dcf-8d2eb48e7c9d | 1 | 322.0 KB | 13 |
| GET 01a0f60b-9ab4-73f5-b2ad-e1007d1ee90d | 1 | 4.1 KB | 4 |
| GET 01a0f60b-9bd9-72bf-aabd-5b983d9e26d2 | 1 | 325.5 KB | 6 |
| GET 01a0f60b-9be1-7114-bac2-973436dd491d | 1 | 4.1 KB | 4 |
| GET 01a0f60b-9ce0-712d-a088-0ec6eb296a8e | 1 | 286.5 KB | 14 |
| GET 01a0f60b-9ce9-7206-90d6-194d3112df16 | 1 | 4.2 KB | 4 |
| GET 01a0f60b-9e02-72a0-a1ae-adbe8737e7cb | 1 | 285.4 KB | 7 |
| GET 01a0f60b-9e08-73db-bfde-2e3170ca39bf | 1 | 4.0 KB | 4 |
| GET 01a0f60b-9eef-71a1-a29f-c455aeeada7e | 1 | 301.7 KB | 11 |
| GET 01a0f60b-9ef5-7165-a6e1-c41fbd8c491b | 1 | 4.2 KB | 6 |
| GET 01a0f60b-9fd9-722c-9ac2-564e83f66ab7 | 1 | 367.1 KB | 8 |
| GET 01a0f60b-9fdf-70c4-a1ce-a128db076a7a | 1 | 4.2 KB | 4 |
| GET 01a0f60b-a08e-73ce-be2b-f54ee36c0d29 | 1 | 317.0 KB | 7 |
| GET 01a0f60b-a093-70d1-95d3-849436e92639 | 1 | 6.3 KB | 3 |
| GET 01a0f60b-a181-70b7-8868-4c33daf04f55 | 1 | 274.8 KB | 6 |
| GET 01a0f60b-a188-70a9-9a35-21839fa04d3d | 1 | 6.0 KB | 3 |
| GET 01a0f60b-a27c-728c-8731-d80c0bfcbe02 | 1 | 270.2 KB | 6 |
| GET 01a0f60b-a281-7156-a775-dd95fe410567 | 1 | 5.2 KB | 4 |
| GET 01a0f60b-a31a-7084-ba7a-e26c14305b01 | 1 | 243.4 KB | 4 |
| GET 01a0f60b-a31f-72a5-8bad-bcd4a74966b7 | 1 | 5.7 KB | 2 |
| GET 01a0f60b-a3c6-72d0-87f3-5bc6b338f966 | 1 | 268.5 KB | 4 |
| GET 01a0f60b-a3cd-7201-9408-c468b34b8adc | 1 | 5.7 KB | 2 |
| GET 01a0f60b-a46e-7066-98c9-b5e07b4bf6e1 | 1 | 241.2 KB | 7 |
| GET 01a0f60b-a473-703b-8396-8db5d591cc2d | 1 | 6.0 KB | 4 |
| GET 01a0f60b-a512-7315-8a34-89b53cb5859b | 1 | 270.0 KB | 8 |
| GET 01a0f60b-a517-725b-959f-5cfc18f20d71 | 1 | 5.6 KB | 3 |
| GET 01a0f60b-a5c1-7248-8f68-57e909682b5b | 1 | 288.5 KB | 12 |
| GET 01a0f60b-a5c6-7290-b513-26a309327743 | 1 | 5.7 KB | 3 |
| GET 01a0f60b-a665-7312-a672-a773510b64e4 | 1 | 335.2 KB | 5 |
| GET 01a0f60b-a66a-7344-b188-bea56a8bf51d | 1 | 5.7 KB | 3 |
| GET 01a0f60b-a725-72c5-8e66-5224266c223d | 1 | 315.3 KB | 13 |
| GET 01a0f60b-a72a-71e5-a596-0cec74980f78 | 1 | 5.5 KB | 3 |
| GET 01a0f60b-a7c9-7384-9508-b026b8907aca | 1 | 354.9 KB | 10 |
| GET 01a0f60b-a7cd-73cf-89c3-7eb6d9767ef6 | 1 | 5.5 KB | 4 |
| GET 01a0f60b-a87a-7036-ac5e-458f1026df5c | 1 | 314.2 KB | 8 |
| GET 01a0f60b-a880-729d-b7a0-73d7c057c601 | 1 | 5.5 KB | 4 |
| GET 01a0f60b-a941-7120-a650-835faa17a333 | 1 | 285.7 KB | 7 |
| GET 01a0f60b-a945-73aa-9c5f-aae4164ede80 | 1 | 5.7 KB | 3 |
| GET 01a0f60b-a9f3-71f7-a3a6-889569039d83 | 1 | 225.4 KB | 7 |
| GET 01a0f60b-a9f8-71a1-a389-69b1a27cc970 | 1 | 4.8 KB | 4 |
| GET 01a0f60b-b211-72ea-9c85-8474c5506f6a | 1 | 335.1 KB | 10 |
| GET 01a0f60b-b223-70c8-8c24-4767f0c100fd | 1 | 4.5 KB | 3 |
| GET 01a0f60b-ca1d-7328-b7be-0262c821b368 | 1 | 300.3 KB | 11 |
| GET 01a0f60b-ca29-7334-8342-c0d54c5fe244 | 1 | 4.8 KB | 6 |
| GET 01a0f60b-d7ad-7291-b38b-5b473c41bb2f | 1 | 269.3 KB | 6 |
| GET 01a0f60b-d7b6-7212-b689-244f5310093c | 1 | 4.7 KB | 4 |
| GET 01a0f60b-efea-70b0-a478-5eb78a3c0cb2 | 1 | 266.4 KB | 8 |
| GET 01a0f60b-eff0-73ce-8fe2-0ede77ec761a | 1 | 5.5 KB | 4 |
| GET 01a0f60b-fda5-70a7-9aaa-bac394b82ccb | 1 | 267.7 KB | 8 |
| GET 01a0f60b-fdaf-733c-9a33-0278a48f038e | 1 | 4.4 KB | 4 |
| GET 01a0f60c-1084-70d0-a3dd-9db90820c598 | 1 | 159.6 KB | 6 |
| GET 01a0f60c-108c-728a-9cbb-2b218717037c | 1 | 5.9 KB | 4 |
| GET 01a0f60c-2844-72a0-9951-70ada1379b97 | 1 | 210.6 KB | 6 |
| GET 01a0f60c-284c-72d9-98de-ec066be90bd0 | 1 | 4.7 KB | 4 |
| GET 01a0f60c-344a-72a5-90ee-4150711d8c2d | 1 | 143.2 KB | 10 |
| GET 01a0f60c-344f-7203-9432-cb38a957d6f9 | 1 | 3.7 KB | 4 |
| GET 01a0f60c-4753-72c7-879e-7b0c07c15f93 | 1 | 240.1 KB | 7 |
| GET 01a0f60c-475e-70f6-9ba0-74948105b4c4 | 1 | 6.3 KB | 3 |
| GET 01a0f60c-5a55-7362-aad2-6d2de50989ab | 1 | 211.0 KB | 7 |
| GET 01a0f60c-5a5e-71e3-861d-403597de54b4 | 1 | 7.4 KB | 2 |
| GET 01a0f60c-72be-708a-97c1-17a0218ed2ee | 1 | 213.5 KB | 5 |
| GET 01a0f60c-72c3-7108-894e-593805225f24 | 1 | 5.6 KB | 3 |
| GET 01a0f60c-8061-730f-a569-8b109ae6613d | 1 | 117.3 KB | 3 |
| GET 01a0f60c-806a-72d4-ad63-983a55c972b7 | 1 | 7.2 KB | 2 |
| GET 01a0f60c-81a8-7174-b2a5-136d8d9261b1 | 1 | 166.5 KB | 3 |
| GET 01a0f60c-81af-70ec-a938-fb0f0f123fdf | 1 | 7.3 KB | 2 |
| GET 01a0f60c-82d0-7054-8815-8c970362b9a2 | 1 | 185.9 KB | 7 |
| GET 01a0f60c-82de-712e-91b9-9badd0793359 | 1 | 6.9 KB | 7 |
| GET 01a0f60c-8403-7177-bc83-f3593ab89ea0 | 1 | 197.2 KB | 5 |
| GET 01a0f60c-8408-7044-b663-043701c2fd0c | 1 | 5.9 KB | 8 |
| GET 01a0f60c-84ce-708f-9052-5b7f4852b339 | 1 | 208.3 KB | 7 |
| GET 01a0f60c-84d7-7341-9dba-dff17a4bb909 | 1 | 5.1 KB | 3 |
| GET 01a0f60c-861b-70c0-a991-635fe1514886 | 1 | 227.9 KB | 5 |
| GET 01a0f60c-8622-73de-ab27-4fb8a3ddbe9f | 1 | 4.8 KB | 3 |
| GET 01a0f60c-871e-7327-870f-2378b87f84a4 | 1 | 153.2 KB | 4 |
| GET 01a0f60c-8726-70a3-9678-826f0b3e9376 | 1 | 5.2 KB | 6 |
| GET 01a0f60c-885f-7216-8e00-5d153e101b9d | 1 | 193.1 KB | 6 |
| GET 01a0f60c-8867-70f6-95a3-12e50495481e | 1 | 5.7 KB | 4 |
| GET 01a0f60c-8917-7330-a04a-eaa6bf691b06 | 1 | 193.5 KB | 7 |
| GET 01a0f60c-891b-706b-a0fc-0178ef14f9ed | 1 | 6.4 KB | 4 |
| GET 01a0f60c-8a13-700d-9479-99e725b8a7a3 | 1 | 135.9 KB | 6 |
| GET 01a0f60c-8a1c-71fe-ba97-560ffcef3009 | 1 | 7.3 KB | 4 |
| GET 01a0f60c-8b43-72ac-8b0c-560399d23530 | 1 | 140.4 KB | 12 |
| GET 01a0f60c-8b4a-72f2-8cbb-833b6f45929c | 1 | 5.2 KB | 3 |
| GET 01a0f60c-8c4e-700a-9070-cd06884b33a9 | 1 | 226.0 KB | 8 |
| GET 01a0f60c-8c57-7264-a83b-3bad45a40255 | 1 | 6.2 KB | 4 |
| GET 01a0f60c-8d58-7235-ac61-56735d136f4e | 1 | 156.1 KB | 13 |
| GET 01a0f60c-8d61-71bb-950f-b70659f13cac | 1 | 3.8 KB | 4 |
| GET 01a0f60c-8e62-7235-8e96-9d0788612383 | 1 | 159.8 KB | 4 |
| GET 01a0f60c-8e6a-7003-b01f-16400df45747 | 1 | 4.4 KB | 2 |
| GET 01a0f60c-8f2b-71b7-96df-1963d116ff80 | 1 | 131.8 KB | 5 |
| GET 01a0f60c-8f32-728e-88cb-93c2d66f9117 | 1 | 7.0 KB | 4 |
| GET 01a0f60c-903f-7296-adcf-8dd0bf063c87 | 1 | 220.7 KB | 6 |
| GET 01a0f60c-9048-73a3-adf1-93177165785f | 1 | 6.5 KB | 4 |
| GET 01a0f60c-9170-7270-a6fa-7e327a37673d | 1 | 173.9 KB | 7 |
| GET 01a0f60c-9178-7211-a790-362bfd9fe8cb | 1 | 6.4 KB | 4 |
| GET 01a0f60c-9273-7255-b7f4-bbb7132a3393 | 1 | 195.7 KB | 7 |
| GET 01a0f60c-927d-7241-84f7-f28da65b0c30 | 1 | 6.1 KB | 3 |
| GET 01a0f60c-938b-70c0-8501-ebd8417215cd | 1 | 221.7 KB | 5 |
| GET 01a0f60c-9393-73a5-ae28-bbe15d0d1bdf | 1 | 6.6 KB | 4 |
| GET 01a0f60c-9487-7002-b579-86feb6bd70c6 | 1 | 182.2 KB | 5 |
| GET 01a0f60c-948f-712a-99c1-83d06cf9ca54 | 1 | 7.0 KB | 4 |
| GET 01a0f60c-9574-70f2-b330-3da65a631f1e | 1 | 187.2 KB | 6 |
| GET 01a0f60c-957a-7239-9643-da399fb72a9e | 1 | 8.2 KB | 4 |
| GET 01a0f60c-966c-707b-8d0d-2c9b4b2d92f6 | 1 | 211.6 KB | 6 |
| GET 01a0f60c-9673-7109-99d5-2e8709091080 | 1 | 8.9 KB | 4 |
| GET 01a0f60c-9799-7072-92c5-d9c9e5e576f0 | 1 | 212.7 KB | 5 |
| GET 01a0f60c-97a1-72de-9b63-78ab77deaa07 | 1 | 4.1 KB | 4 |
| GET 01a0f60c-98b8-7369-9be6-7c65941b1985 | 1 | 230.5 KB | 7 |
| GET 01a0f60c-98c0-70be-953e-8c850c891c33 | 1 | 4.2 KB | 4 |
| GET 01a0f60c-99c1-722f-8c48-7ed44ec9d9ae | 1 | 243.3 KB | 9 |
| GET 01a0f60c-99c9-71b2-8b31-02f959ab223d | 1 | 4.0 KB | 3 |
| GET 01a0f60c-9adc-734c-b4f9-9d381d30bc87 | 1 | 229.3 KB | 6 |
| GET 01a0f60c-9ae3-707f-98a9-f6c384790db3 | 1 | 4.1 KB | 4 |
| GET 01a0f60c-a234-72e0-a188-5621859ed8f4 | 1 | 175.3 KB | 13 |
| GET 01a0f60c-a23e-721a-a8fa-e6355318ed84 | 1 | 4.0 KB | 6 |
| GET 01a0f60c-af5d-726a-a635-1af109793c5c | 1 | 189.6 KB | 5 |
| GET 01a0f60c-af65-70d8-baf3-94002bfb37c9 | 1 | 4.1 KB | 6 |
| GET 01a0f60c-c250-70e4-a17f-1cbde0d4d0fb | 1 | 252.2 KB | 5 |
| GET 01a0f60c-c25a-7155-bb25-a672651788d9 | 1 | 4.2 KB | 2 |
| GET 01a0f60c-d50d-73d2-9759-76b0343f3289 | 1 | 192.8 KB | 44 |
| GET 01a0f60c-d515-7092-9e25-d86bc894f715 | 1 | 4.0 KB | 2 |
| GET 01a0f60c-ecad-731a-beb4-cf59ff4dad1b | 1 | 214.6 KB | 6 |
| GET 01a0f60c-ecb6-71e2-9599-b4fc0e374f19 | 1 | 4.1 KB | 4 |
| GET 01a0f60c-fb27-715e-82be-0dd189af3188 | 1 | 218.6 KB | 7 |
| GET 01a0f60c-fb35-70e2-b713-63f51d8b31fb | 1 | 4.2 KB | 3 |
| GET 01a0f60d-0e7e-720c-a5eb-bd0a5a89b9ab | 1 | 243.6 KB | 9 |
| GET 01a0f60d-0e89-7318-9d50-2d5ea1f865fb | 1 | 4.1 KB | 4 |
| GET 01a0f60d-1eda-7197-b60f-6f85b4ccc62b | 1 | 269.7 KB | 6 |
| GET 01a0f60d-1ee2-7126-a0fa-f82a25b40a23 | 1 | 4.2 KB | 6 |
| GET 01a0f60d-31f7-725b-b9f0-e34005366dea | 1 | 254.2 KB | 5 |
| GET 01a0f60d-3201-7207-a945-32baedb7e7e0 | 1 | 4.0 KB | 4 |
| GET 01a0f60d-456e-7072-8a2a-47d09a80fb86 | 1 | 279.5 KB | 8 |
| GET 01a0f60d-457c-710f-b61d-5da77646dc94 | 1 | 4.0 KB | 4 |
| GET 01a0f60d-577c-73bf-8ca4-a1511cc09664 | 1 | 341.7 KB | 8 |
| GET 01a0f60d-5786-703a-94c8-d61873b95524 | 1 | 4.2 KB | 2 |
| GET 01a0f60d-6b71-7179-aaa7-41ee7fc2a9bd | 1 | 287.8 KB | 7 |
| GET 01a0f60d-6b7e-735e-8bc7-3d1490562c07 | 1 | 4.2 KB | 4 |
| GET 01a0f60d-6c70-7257-b3f8-857db100590b | 1 | 297.5 KB | 14 |
| GET 01a0f60d-6c79-717a-b824-9d0c67eb9bfc | 1 | 4.1 KB | 3 |
| GET 01a0f60d-6d76-7093-aaa1-4a06b632236c | 1 | 281.5 KB | 5 |
| GET 01a0f60d-6d7c-7354-9e48-d8669da14e51 | 1 | 4.1 KB | 3 |
| GET 01a0f60d-6e6b-722c-855f-a7ae9631c9c8 | 1 | 271.8 KB | 7 |
| GET 01a0f60d-6e72-7297-90a3-f8a74b1dff5c | 1 | 4.2 KB | 3 |
| GET 01a0f60d-6f58-71ac-96a2-28f6457ea66d | 1 | 328.8 KB | 6 |
| GET 01a0f60d-6f62-7162-a238-10ab3cf3e2ec | 1 | 4.1 KB | 3 |
| GET 01a0f60d-709a-7130-be9c-668ecec64ac9 | 1 | 222.3 KB | 5 |
| GET 01a0f60d-70a1-71f4-b12c-42746ca71eeb | 1 | 6.6 KB | 3 |
| GET 01a0f60d-71b5-70fa-9189-ed2b0b96c2fc | 1 | 306.0 KB | 8 |
| GET 01a0f60d-71bd-732e-ab76-4c082db798ee | 1 | 3.9 KB | 3 |
| GET 01a0f60d-72da-723f-b74a-4a712565fd84 | 1 | 278.4 KB | 8 |
| GET 01a0f60d-72e1-7004-a0dd-fef7d1040b25 | 1 | 4.3 KB | 3 |
| GET 01a0f60d-7398-70a9-b70a-f0bb91fe3de6 | 1 | 354.9 KB | 8 |
| GET 01a0f60d-739d-719b-8886-09ac68a19878 | 1 | 3.4 KB | 4 |
| GET 01a0f60d-74f3-7302-b2fd-a2a2698ba949 | 1 | 306.2 KB | 5 |
| GET 01a0f60d-7504-72d4-a1bb-3412bad27c65 | 1 | 3.4 KB | 3 |
| GET 01a0f60d-762a-7348-90e5-9e79e0c28dfb | 1 | 288.3 KB | 7 |
| GET 01a0f60d-7633-7293-85f2-fd230cad840f | 1 | 3.4 KB | 5 |
| GET 01a0f60d-7761-70db-872c-ede86d2ca4b4 | 1 | 207.4 KB | 13 |
| GET 01a0f60d-7768-72a0-92d3-cf82e145c6e3 | 1 | 3.4 KB | 3 |
| GET 01a0f60d-7858-737a-8ac1-d380ead208b5 | 1 | 300.2 KB | 10 |
| GET 01a0f60d-785e-722f-b675-a4afbb9e1fa6 | 1 | 5.6 KB | 3 |
| GET 01a0f60d-792a-7325-ac8a-a995f085f13b | 1 | 292.9 KB | 11 |
| GET 01a0f60d-792f-7074-ad70-e97a7ce13678 | 1 | 4.6 KB | 3 |
| **total** | 230 | 30.0 MB | 6 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| download_url_issued | 230 | 0 B | 30.0 MB |

**Log highlights**

```
08:06:34.590 picplace: pacing requests under 300/min (255/min for sync work)
08:06:34.833 picplace: pulled buildings.02 (8206c7f5) — 2 object(s), 330409 bytes; 1 heavy file(s) stay on PicPlace
08:06:34.945 picplace: pulled building.01 (2eca2cb8) — 2 object(s), 234421 bytes; 1 heavy file(s) stay on PicPlace
08:06:35.047 picplace: pulled arch.01 (84a1e3ef) — 2 object(s), 340887 bytes; 1 heavy file(s) stay on PicPlace
08:06:35.168 picplace: pulled single.oldtown.dusk.near (b1a2848f) — 2 object(s), 215906 bytes; 1 heavy file(s) stay on PicPlace
08:06:35.282 picplace: pulled windows.05 (678416d9) — 2 object(s), 278467 bytes; 1 heavy file(s) stay on PicPlace
08:06:35.395 picplace: pulled windows.06 (33e92519) — 2 object(s), 278623 bytes; 1 heavy file(s) stay on PicPlace
08:06:35.507 picplace: pulled windows.02 (b9d0931f) — 2 object(s), 347679 bytes; 1 heavy file(s) stay on PicPlace
08:06:35.623 picplace: pulled windows.03 (ae73cffc) — 2 object(s), 312399 bytes; 1 heavy file(s) stay on PicPlace
08:06:35.736 picplace: pulled windows.04 (3a74d0ec) — 2 object(s), 280593 bytes; 1 heavy file(s) stay on PicPlace
08:06:35.843 picplace: pulled tram.01 (a3341acd) — 2 object(s), 313176 bytes; 1 heavy file(s) stay on PicPlace
08:06:35.949 picplace: pulled windows.01 (75186093) — 2 object(s), 235769 bytes; 1 heavy file(s) stay on PicPlace
08:06:36.049 picplace: pulled trams-nature.04 (7374b86d) — 2 object(s), 298335 bytes; 1 heavy file(s) stay on PicPlace
08:06:36.152 picplace: pulled trams-nature.01 (f7d6b37d) — 2 object(s), 328502 bytes; 1 heavy file(s) stay on PicPlace
08:06:36.254 picplace: pulled trams-nature.02 (a0ac51bc) — 2 object(s), 369071 bytes; 1 heavy file(s) stay on PicPlace
08:06:36.349 picplace: pulled trams-nature.03 (5e187e7b) — 2 object(s), 327344 bytes; 1 heavy file(s) stay on PicPlace
08:06:36.441 picplace: pulled trams-city.09 (7bf05aa4) — 2 object(s), 349066 bytes; 1 heavy file(s) stay on PicPlace
08:06:36.531 picplace: pulled trams-city.08 (3ff9b459) — 2 object(s), 301246 bytes; 1 heavy file(s) stay on PicPlace
08:06:36.621 picplace: pulled trams-city.07 (05ef54ce) — 2 object(s), 282227 bytes; 1 heavy file(s) stay on PicPlace
08:06:36.724 picplace: pulled trams-city.06 (6130b2d3) — 2 object(s), 253158 bytes; 1 heavy file(s) stay on PicPlace
08:06:36.821 picplace: pulled trams-city.05 (fe2f247a) — 2 object(s), 280768 bytes; 1 heavy file(s) stay on PicPlace
08:06:36.922 picplace: pulled trams-city.04 (87b3e188) — 2 object(s), 255047 bytes; 1 heavy file(s) stay on PicPlace
08:06:37.041 picplace: pulled trams-city.03 (eb7840a9) — 2 object(s), 282025 bytes; 1 heavy file(s) stay on PicPlace
08:06:37.143 picplace: pulled trams-city.02 (f59b627a) — 2 object(s), 287513 bytes; 1 heavy file(s) stay on PicPlace
08:06:37.240 picplace: pulled trams-city.01 (ecf04312) — 2 object(s), 331038 bytes; 1 heavy file(s) stay on PicPlace
08:06:37.345 picplace: pulled flower.12 (29f7b6a2) — 2 object(s), 280431 bytes; 1 heavy file(s) stay on PicPlace
08:06:37.448 picplace: pulled flower.11 (95a0fd62) — 2 object(s), 253686 bytes; 1 heavy file(s) stay on PicPlace
08:06:37.550 picplace: pulled flower.10 (ad09dd9a) — 2 object(s), 282673 bytes; 1 heavy file(s) stay on PicPlace
08:06:37.646 picplace: pulled flower.10 (ef9dfe4b) — 2 object(s), 228103 bytes; 1 heavy file(s) stay on PicPlace
08:06:37.743 picplace: pulled flower.09 (ecc80a3f) — 2 object(s), 223926 bytes; 1 heavy file(s) stay on PicPlace
… 57 line(s) left out …
08:07:38.092 picplace: pulled doors-16x9.07 (95447be9) — 2 object(s), 127490 bytes; 1 heavy file(s) stay on PicPlace
08:07:38.182 picplace: pulled doors-16x9.06 (1aa8115a) — 2 object(s), 224333 bytes; 1 heavy file(s) stay on PicPlace
08:07:38.284 picplace: pulled doors-16x9.05 (cd68ba59) — 2 object(s), 223673 bytes; 1 heavy file(s) stay on PicPlace
08:07:38.388 picplace: pulled doors-16x9.04 (c7895a1b) — 2 object(s), 252262 bytes; 1 heavy file(s) stay on PicPlace
08:07:38.506 picplace: pulled doors-16x9.03 (c77a835d) — 2 object(s), 150479 bytes; 1 heavy file(s) stay on PicPlace
08:07:38.647 picplace: pulled doors-16x9.02 (4e3b0c8b) — 2 object(s), 220442 bytes; 1 heavy file(s) stay on PicPlace
08:07:38.779 picplace: pulled doors.07 (af51f042) — 2 object(s), 305809 bytes; 1 heavy file(s) stay on PicPlace
08:07:38.907 picplace: pulled doors.08 (a7021357) — 2 object(s), 274965 bytes; 1 heavy file(s) stay on PicPlace
08:07:39.025 picplace: pulled doors-16x9.01 (94b80fca) — 2 object(s), 169505 bytes; 1 heavy file(s) stay on PicPlace
08:07:39.141 picplace: pulled doors.05 (8573257b) — 2 object(s), 317061 bytes; 1 heavy file(s) stay on PicPlace
08:07:39.244 picplace: pulled doors.03 (667cc77b) — 2 object(s), 324812 bytes; 1 heavy file(s) stay on PicPlace
08:07:39.343 picplace: pulled doors.06 (566cde9a) — 2 object(s), 344398 bytes; 1 heavy file(s) stay on PicPlace
08:07:39.443 picplace: pulled doors.04 (3cfc2584) — 2 object(s), 302713 bytes; 1 heavy file(s) stay on PicPlace
08:07:39.559 picplace: pulled doors.01 (e78a74d0) — 2 object(s), 293935 bytes; 1 heavy file(s) stay on PicPlace
08:07:39.673 picplace: pulled doors.02 (8d891d8f) — 2 object(s), 313894 bytes; 1 heavy file(s) stay on PicPlace
08:07:39.786 picplace: pulled 5b503e1f-30b9-4037-91ce-8d5a6e7fe856 (49a122c5) — 2 object(s), 390101 bytes; 1 heavy file(s) stay on PicPlace
08:07:39.915 picplace: pulled 16c080c7-a9b0-426c-8a53-a6975815bda7 (89345046) — 2 object(s), 384335 bytes; 1 heavy file(s) stay on PicPlace
08:07:40.031 picplace: pulled 3db344e3-5a1b-4be4-816e-b5d3ffb97d11 (482031c0) — 2 object(s), 336252 bytes; 1 heavy file(s) stay on PicPlace
08:07:40.143 picplace: pulled broad-mix--arches.05 (ffe59492) — 2 object(s), 461628 bytes; 1 heavy file(s) stay on PicPlace
08:07:40.251 picplace: pulled broad-mix--arches.03 (fc972c8f) — 2 object(s), 348076 bytes; 1 heavy file(s) stay on PicPlace
08:07:40.366 picplace: pulled broad-mix--arches.01 (cccb017c) — 2 object(s), 292279 bytes; 1 heavy file(s) stay on PicPlace
08:07:40.481 picplace: pulled broad-mix--arches.04 (9d7e7143) — 2 object(s), 293481 bytes; 1 heavy file(s) stay on PicPlace
08:07:40.586 picplace: pulled ae1fa114-51a5-4f29-b101-94eaead64d00 (37ebdfb2) — 2 object(s), 327550 bytes; 1 heavy file(s) stay on PicPlace
08:07:40.692 picplace: pulled broad-mix--arches.02 (1b3132ae) — 2 object(s), 301031 bytes; 1 heavy file(s) stay on PicPlace
08:07:40.778 picplace: pulled 6daeaac6-dcb8-4cac-b873-cd9bb4536bc9 (0e6ff819) — 2 object(s), 273723 bytes; 1 heavy file(s) stay on PicPlace
08:07:40.869 picplace: pulled 8b672eb3-5221-4df3-beef-d69b6f1c292c (5bddd7f8) — 2 object(s), 371558 bytes; 1 heavy file(s) stay on PicPlace
08:07:40.961 picplace: pulled Photo 29. 7. at 1554 (c58eda80) — 2 object(s), 445685 bytes; 1 heavy file(s) stay on PicPlace
08:07:41.069 picplace: pulled Photo 29. 7. at 1614 (a2b269d5) — 2 object(s), 272606 bytes; 1 heavy file(s) stay on PicPlace
08:07:41.169 picplace: pulled Photo of rocks (92d074da) — 2 object(s), 412310 bytes; 1 heavy file(s) stay on PicPlace
08:07:41.174 picplace: check (foreground) — 115 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 1 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/06-sim-pull.log`](raw/06-sim-pull.log) · projects on the Mac 115 → 115, on the Simulator 1 → 115.

## 7. sim-download — Simulator

_download the originals of 3 photos not edited on the Mac (the just-in-time prompt's answer)._ 08:08:32 → 08:09:43 (70.7 s). Hooks: `LL_PICPLACE_DOWNLOAD=0e6ff819-0ca8-46d2-9421-ac9e151ad389,5bddd7f8-2332-44c6-a76b-dfbb7e53ee5c,c58eda80-8d2f-4942-bb81-0bc310add03d`

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 8 | 64 | 0 B | 17.2 KB |  |
| GET projects/{u} | 6 | 40 | 0 B | 17.7 KB |  |
| POST projects/{u}/assets/urls | 3 | 42 | 153 B | 3.7 KB |  |
| POST projects/{u}/presence | 3 | 33 | 132 B | 1.2 KB |  |
| GET projects?include_deleted=1 | 2 | 62 | 0 B | 232.2 KB |  |
| POST device | 1 | 28 | 201 B | 448 B |  |
| GET projects | 1 | 68 | 0 B | 113.2 KB |  |
| POST projects/assets | 1 | 20 | 148 B | 1.9 KB |  |
| **total** | 25 | 49 | 634 B | 387.6 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| GET source/* | 3 | 18.9 MB | 39 |
| **total** | 3 | 18.9 MB | 39 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| download_url_issued | 3 | 0 B | 18.9 MB |

**Log highlights**

```
08:08:34.913 picplace: pacing requests under 300/min (255/min for sync work)
08:08:34.989 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
08:08:35.130 assets: 0E6FF819 recorded 0 of 0 pending (1 assets)
08:08:35.181 assets: 5BDDD7F8 recorded 0 of 0 pending (1 assets)
08:08:35.221 assets: C58EDA80 recorded 0 of 0 pending (1 assets)
08:08:35.345 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 3 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
08:08:35.374 picplace: 6daeaac6-dcb8-4cac-b873-cd9bb4536bc9 — all 1 heavy file(s) here verified on PicPlace: backed up
08:08:35.409 picplace: 8b672eb3-5221-4df3-beef-d69b6f1c292c — all 1 heavy file(s) here verified on PicPlace: backed up
08:08:35.441 picplace: Photo 29. 7. at 1554 — all 1 heavy file(s) here verified on PicPlace: backed up
```

Full log: [`raw/07-sim-download.log`](raw/07-sim-download.log) · projects on the Mac 115 → 115, on the Simulator 115 → 115.

## 8. sim-edit — Simulator

_preset on those 3 photos._ 08:09:46 → 08:11:06 (80.5 s). Hooks: `LL_APPLY_PRESET=0e6ff819-0ca8-46d2-9421-ac9e151ad389:Cinema@2;5bddd7f8-2332-44c6-a76b-dfbb7e53ee5c:Matte@4;c58eda80-8d2f-4942-bb81-0bc310add03d:Vivid@6`

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 10 | 54 | 0 B | 21.5 KB |  |
| POST projects/{u}/claim | 3 | 40 | 60 B | 702 B |  |
| PUT projects/{u} | 3 | 47 | 4.3 KB | 3.7 KB |  |
| POST projects/{u}/assets | 3 | 40 | 1.0 KB | 8.6 KB |  |
| POST projects/{u}/assets/confirm | 3 | 56 | 768 B | 3.1 KB |  |
| POST projects/{u}/presence | 3 | 25 | 132 B | 1.2 KB |  |
| DELETE projects/{u}/claim | 3 | 24 | 0 B | 42 B |  |
| GET projects?include_deleted=1 | 2 | 50 | 0 B | 232.2 KB |  |
| GET projects | 2 | 57 | 0 B | 226.3 KB |  |
| POST device | 1 | 38 | 201 B | 448 B |  |
| **total** | 33 | 45 | 6.4 KB | 497.9 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| PUT poster.jpg | 3 | 1.1 MB | 16 |
| PUT records.aar | 3 | 3.8 KB | 10 |
| **total** | 6 | 1.1 MB | 13 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| asset_replaced | 6 | 0 B | 0 B |
| manifest_written | 3 | 3.9 KB | 0 B |
| upload_confirmed | 6 | 1.1 MB | 0 B |

**Log highlights**

```
08:09:48.634 picplace: pacing requests under 300/min (255/min for sync work)
08:09:48.657 picplace: check (foreground) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
08:09:48.946 picplace: check (launch) — 0 pulled, 0 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
08:09:50.271 LL_APPLY_PRESET applied Cinema to 0E6FF819
08:09:52.391 LL_APPLY_PRESET applied Matte to 5BDDD7F8
08:09:54.490 LL_APPLY_PRESET applied Vivid to C58EDA80
08:10:12.573 picplace: 6daeaac6-dcb8-4cac-b873-cd9bb4536bc9 — uploading 2 of 2 file(s), 271 KB
08:10:13.012 picplace: 8b672eb3-5221-4df3-beef-d69b6f1c292c — uploading 2 of 2 file(s), 381 KB
08:10:13.162 picplace: push queue — 2 sent, 0 failed
08:10:15.028 picplace: Photo 29. 7. at 1554 — uploading 2 of 2 file(s), 460 KB
08:10:15.127 picplace: push queue — 1 sent, 0 failed
```

Full log: [`raw/08-sim-edit.log`](raw/08-sim-edit.log) · projects on the Mac 115 → 115, on the Simulator 115 → 115.

## 9. mac-after — Mac

_launch, one check: what the Simulator's edits cost the Mac._ 08:11:09 → 08:21:21 (611.5 s). Hooks: none beyond the trace

**API requests**

| Endpoint | Requests | avg ms | Body up | Body down | Failed |
|---|---|---|---|---|---|
| GET status | 6 | 48 | 0 B | 12.9 KB |  |
| POST projects/{u}/assets/urls | 6 | 19 | 306 B | 7.0 KB |  |
| GET projects/{u} | 3 | 27 | 0 B | 11.3 KB |  |
| POST projects/{u}/presence | 3 | 17 | 78 B | 1.2 KB |  |
| POST device | 1 | 27 | 198 B | 445 B |  |
| GET nearby/key | 1 | 21 | 0 B | 135 B |  |
| GET projects | 1 | 49 | 0 B | 113.2 KB |  |
| GET projects?include_deleted=1 | 1 | 52 | 0 B | 116.1 KB |  |
| **total** | 22 | 31 | 582 B | 262.3 KB |  |

**Storage transfers**

| Storage transfer | Objects | Bytes | avg ms |
|---|---|---|---|
| GET 01a0f608-0e7b-73e4-af3a-619c65b290ae | 1 | 448.0 KB | 6 |
| GET 01a0f608-0e80-7064-a80d-6e1f159e92d5 | 1 | 1.2 KB | 3 |
| GET 01a0f608-5fba-7053-af59-fe8ffdc33cd5 | 1 | 263.4 KB | 9 |
| GET 01a0f608-5fca-7161-a302-3a1373271339 | 1 | 1.3 KB | 3 |
| GET 01a0f608-6112-7146-bab0-ad699e618d8a | 1 | 370.5 KB | 6 |
| GET 01a0f608-6116-7294-b781-6b30530a252d | 1 | 1.3 KB | 2 |
| **total** | 6 | 1.1 MB | 5 |

**Ledger rows written during the step**

| Ledger event | Rows | bytes_in | bytes_out |
|---|---|---|---|
| download_url_issued | 6 | 0 B | 1.1 MB |

**Log highlights**

```
08:11:11.075 picplace: pacing requests under 300/min (255/min for sync work)
08:11:11.762 picplace: check (launch) — 0 pulled, 3 updated, 0 queued to send, 0 poster(s) already on PicPlace noted, 0 retried, 0 waiting to retry, 0 deleted there, 0 removed here, 0 filed elsewhere, 0 other libraries' previews removed, 0 conflict(s)
```

Full log: [`raw/09-mac-after.log`](raw/09-mac-after.log) · projects on the Mac 115 → 115, on the Simulator 115 → 115.
