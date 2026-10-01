# PicPlace sync on devices against picplace.co: first check of the 2026-10-01 changes

**Date:** 2026-10-01, 17:40–19:00 CEST · **Devices:** iPhone 16 Pro, iPad Air 13-inch (M3), iPhone 18 Pro, all on Wi-Fi and USB, signed in as `regularsteven` on picplace.co (Hetzner) · **Build:** Release optimisation with `DEBUG` compilation conditions, so `LL_PICPLACE_TRACE=1` answers (`dd-device-hooks`), launched with `devicectl … -e '{"LL_PICPLACE_TRACE":"1"}'`.

Data points from the devices' own console logs, pulled over `devicectl`. The library holds 1,565–1,595 projects.

## What was measured

| Measure | Value |
|---|---|
| A launch, nothing to do | 6 requests: `POST /device` ×2, `GET /status` ×2, `GET /projects`, `GET /projects?include_deleted=1`; one check (the launch check logs "not repeated") |
| The index on production | 2.43–2.48 MB per read, uncompressed, 0.7–1.2 s; read twice at a launch (the handshake's usage line and the check) |
| `GET /status` on production | 410–625 ms |
| Catch-up after sign-in (16 Pro) | 28 projects pulled in about 20 s, no conflicts, nothing from another library |
| An originals upload of one photo (2–4 MB HEIC/JPEG) | claim, PUT, negotiate, storage PUT, confirm, presence, release: 6 API requests, about 1.5 s in all |
| A long DNG timelapse (1,503 frames, 17.33 GB, 16 Pro) | 18:05 → 18:55, about 6.1 MB/s with four frames at a time; the uplink measured 46 Mbps (`networkQuality`), so it ran at the line's speed; confirm every 4 frames (988 B up, 4.2 KB down) |
| Verification on Hetzner | the timelapse was reported verified 64 s after its last confirm; the single photos within a minute or two; the look after an upload was one batched `POST /projects/assets` for every waiting project |
| No `429`, no pacing waits, no failed pushes | across about 1,630 files and 18.2 GB from the 16 Pro |

## What it found, and what was changed the same evening

1. **Another device's originals made every preview re-fetch its records and poster.** While the 16 Pro uploaded, the iPad logged "records fetched again (the server holds 3 confirmed asset(s), this device had seen 2)" for each project: `GET /projects/{u}`, the URLs, `records.aar`, the unchanged poster (about 400 KB), presence — one project every three seconds. `settleAssetCountMoves` now reads those projects' asset lists a hundred per request and, where the objects that are not heavy are as many as before and the poster here hashes to the server's, only moves the record's figures. Tested on picplace.test (3 projects: 1 request, no downloads) and seen on the iPad ("PicPlace gained heavy files for them; noted, nothing fetched").
2. **The read-ahead over-asked on devices that are mostly previews or have originals off.** The 16 Pro fetched 574 KB of lists, the 18 Pro 780 KB, to look at one project. The read-ahead now leaves out previews whose originals were never brought to the device, and the blends queue's read-ahead only the sets it will look at.
3. **Turning on *Upload originals automatically* uploads the device's whole backlog**, not only new photos: 104 single photos and then the 17 GB timelapse followed the switch on the 16 Pro. Expected behaviour, worth saying where the switch is.

## Seen, not changed

- The index is downloaded twice at a launch (`GET /projects` for the usage line, then the check's `?include_deleted=1`): 4.9 MB per launch here until the server compresses JSON, and one read too many either way.
- A large project waiting to be verified is polled with its whole asset list: 742 KB per look for the 1,503-frame project (it was the same size through `GET /projects/{u}` before).
- All three devices had been signed out by PicPlace (`invalid_grant` on refresh) before the check began: the iPad at 06:48 that morning, the 18 Pro at its 16:36 launch. Nothing on the app side explains it; a question for the PicPlace developer.
- The iPad's pulls ran at one project every 3.3 s where the 16 Pro did two a second. Most likely the re-fetches of finding 1; not yet confirmed with a trace of fresh pulls.

## Not covered

An edit travelling between devices, a second library on a real device, the kill-inside-the-window case of the coalesced sync-state write, and the 18 Pro's own originals (its switch is off; its 34 newest projects were copied to the Mac before the install as a precaution).
