# 2026-09-26 — iPhone 18 Pro crash triage: 18 reports, three causes, and the 4224×3024 format

**Device:** Steve 18 Pro (`iPhone19,2`), iOS 27.0 — 24A427 until 09-25, 24A437 since. App 0.1.0 (1), Release
builds against the iOS 27 SDK. Pulled 2026-09-26 15:24 while the phone was uploading a 21.73 GB project (the upload
finished and PicPlace verified it at 15:19; same LetsLapse PID before and after the pull). Verified on the phone the
same evening over the Camera remote — see **On the device** at the end.

## Headline (found while verifying): Photo mode shot 1920×1080 for a week

**351 of the 18 Pro's 371 JPEG projects (685 stills, 2026-09-18 → 26) are 1920×1080** while the menu said
4224×3024. By file size across all of them, confirmed by pixel size on five (09-18, 09-20, 09-24, 09-26 ×2); the
18 full-size ones are a cluster on 09-20 afternoon and one right after a menu pick on 09-26. The 24 DNG projects are
full resolution (RAW comes from the sensor). The iPhone 16 Pro is unaffected (samples 3024×4032). **The lost
resolution cannot be recovered** — 1920×1080 is what the camera delivered.

**Cause, read off the phone with the fix build's new log line:** `applyCaptureFormat: no 4224×3024@25 for stills on
Back Triple Camera — no format at that size`. The resolution menu is built from the *physical lens's* formats
(`refreshCaptureOptions` → `effectiveRecordingDevice`) and the telephoto offers a 4224×3024 readout; the session's
camera for Photo is the *Triple Camera*, which has no format of that size. `applyCaptureFormat` returned `false`
**before its first log line** and nothing checked it, so the session stayed on the `.high` 1920×1080 preset that
`configureIfNeeded` sets — and Photo shot at that. The same silent miss in `releaseSequenceLensPin` after a pinned
Holy Grail/Ladder run left the session on another format with `selectedPhotoDimensions` still 4224×3024 from the
pinned telephoto: **that mismatch is the Photo abort** (below). A second, smaller gate would have bitten even with a
matching size: stills formats had to satisfy the video stabilization request, on by default.

## Never silent again — the alarms (2026-09-27)

Steven: *"ensure there's no silent fail, or at least put something in place that can raise the alarm … with some new
lens or firmware or resolution yet to be tested."* Alarms go to logs and reports only (his choice); `ALARM <kind>:`
console lines plus `capture_alarm` session events, read by `shoot.py audit`.

| Layer | What it catches | Where |
|---|---|---|
| Honest stills menu | Photo/Interval list what the stop's own lens can shoot as stills (since the afternoon of 09-27 — see *One lens per shoot* below; the morning's version listed the Triple Camera's); a stored size that lens cannot shoot is substituted by the nearest same shape, shown and shot, never saved over the stored choice | `refreshCaptureOptions`, `stillsFrameRatesByResolution` |
| Delivered-size check | **Any** still that comes out < 90 % of the chosen pixels — measured from the file, whatever the cause | `checkDeliveredStill` → `ALARM capture:` + a `resolution` issue in `capture_log.json` |
| Pre-shot canary | A stills format whose own photo sizes fall short of its size | `applyCaptureFormat` → `ALARM format:` |
| Self-test, every camera set-up | What each lens offers vs what the stills camera can deliver, the photo each size makes; alarms when stills fall short of the lenses or a size cannot make its own photo | `runStillsSelfTest` → `Logs/stills-selftest-<model>.json`, `ALARM selftest:` |
| No silent configuration failures | Format misses, fallbacks, lock failures, a lens that cannot be opened — all logged (11 empty `catch {}` gone) | `CameraController` |
| Tested rules | Shortfall, substitute, request size | `Kit/…/StillsSizing.swift`, 15 `StillsSizingTests` |
| The reader | PASS / WARN / FAIL (exit 1) over console logs, the self-test and crash reports; `--latest` for the running session | `shoot.py audit --device <alias>` |

**Proved on the 18 Pro, 2026-09-27 morning:** a DEBUG-hooks build with `LL_STILLS_FAULT=1080p` (the camera put on
1920×1080 behind the stills code's back) — one Photo logged `ALARM capture: a still came out 1920×1080 — the run
chose 4032×3024 (Back Triple Camera, format 1920×1080)` and the run's summary alarm; `audit` → **FAIL**, exit 1. The
Release build: the menu reads `4032×3024 · JPEG`, the self-test keeps `4224×3024` and `4224×2240` off it, Photos at
4× (telephoto 16.891 mm, daylight) / 1× / 0.5× are all 3024×4032 with no alarm; `audit --latest` → **PASS**, exit 0.

## One lens per shoot, and what 4224×3024 really is (2026-09-27, afternoon)

Steven, on the morning's menu (which offered only the Triple Camera's sizes): capabilities belong to lenses; offer
each lens's own, never lens X's on lens Y, and *"a shoot must never change lenses mid-shoot, even when switching to
low light"* — only ISO and shutter may move. Nothing per iPhone model.

**Built — the video structure, for stills.** The stills menus read the stop's own physical lens
(`effectiveRecordingDevice`); every Photo, Interval and blend run pins that lens for the whole shoot
(`pinLensForSequence(stills:)`, released at the run's end), so no low-light hand-off can reframe it; a lens that
declines the pin says so and the combined camera's switching is locked for the run instead. A size one lens has and
the next lacks is substituted on the second only, never saved over the stored choice — in Video too now, where a
fallback used to be saved and would have reached Photo. A stills format must also *reach the stop's zoom* on its
lens (`videoMaxZoomFactor`): the pinned lens arrives at zoom 1, and the morning's 2× and 8× would have shot 1× and 4×.

**What 4224×3024 is.** Found in the order it gave itself away, all on the 18 Pro:
1. With the pin, every still on it was refused — the photo output's connection inactive (`active false`) at 0.5×,
   1× and 4× — while 4032×3024 on the same lens and the same pin shot. The format lists only
   `AVCaptureBroadcastVideoOutput` and `AVCaptureDepthDataOutput` as unsupported.
2. Its zoom ceiling is 1.0 (4032×3024: 189), and its field of view is ~2.5 % wider (ultra-wide 106.2° vs 103.6°).
3. A Video take on it (stabilization off, which offers it) aborted: *"-[AVCaptureMovieFileOutput
   startRecordingToOutputFileURL:recordingDelegate:] Capturing ProRes Raw codec is supported only on external storage
   device."* The report symbolicates the throw as `-[AVCaptureOutput liveConnections]` — the same symbol as the
   09-20 Video abort on `4224x3024@10`, which was therefore this exception, not a lost connection.
4. Its pixel type is `btp2` — `kCVPixelFormatType_96VersatileBayerPacked12`, which CoreVideo describes as sensor
   data (`kCVPixelFormatContainsSenselArray`). **It is the lenses' ProRes RAW format** (4224×2240 too): no photo
   pipeline, no zoom, no Metal texture (the Holy Grail blends' `-6684`), and movies only to external storage.

**The rules now, none of them per model:** a format whose pixel type is sensor data is never offered or matched
(`CameraController.isSensorDataFormat`); a format's `unsupportedCaptureOutputClasses` is respected for the outputs a
mode uses (photo + blend tap for stills, movie for Video); the photo or movie connection itself is asked before a
run's first still or segment, and a dark one is stepped down a size — when another size on the same lens lights it,
the refusal is learned for this model and OS build (`FormatOutputLedger`, one `ALARM format:`), the menus drop it, and
an OS update tries again. The capability matrix cache moved to `.v4`. The self-test reports each size's pixel types,
zoom ceiling, refused outputs and the learned refusals; `shoot.py audit` prints them. `BlendCore` copies any buffer
Metal will not wrap into a Metal-compatible one rather than dropping the frame.

**On the devices (Release builds, over the Camera remote):**

| Device | Run | Result |
|---|---|---|
| 18 Pro | Photo 0.5× / 1× / 2× / 4× / 8× | each pinned to its lens (UW, main, main at 2.0, tele, tele at 2.0), 4032×3024, 103.6° / 70.7° / 39.1° / 19.0° / 9.6°, no refusal, no alarm; pin→photo 8 ms–1 s (the AE settle) |
| 18 Pro | Holy Grail, 3-frame blends every 2 s at 8× | pinned to the telephoto at zoom 2.0, 8 windows (7 × 3/3, last 2/3 at the stop), ~85 ms blends, 8 frames saved, no lens change in the run — the 09-26 zero-frame run's stop |
| 18 Pro | Video at 1× | records on the pinned main lens (4032×3024@25; with stabilization off, 1080p@25 — the stored 4224×3024 is no longer offered); the connection check adds no delay |
| 18 Pro | self-test, `audit --latest` | every lens "11 stills size(s) to 4032×3024, photos to 8064×6048; sensor data, never offered: 4224×3024, 4224×2240"; no alarm in the session |
| 16 Pro (iOS 26.6) | Photo 0.5× / 1× / 2× / 5× / 10× | each pinned to its lens, 4032×3024, 103.6° / 72.0° / 40.0° / 16.4° / 8.2°; no sensor-data formats; `audit --latest` → **PASS** |

Along the way, before the sensor-data rule existed: the learning build's first Photo per lens found the connection
dark, stepped to 4032×3024 and learned the refusal (three `ALARM format:` lines, still in the phone's ledger —
harmless now); and the Video test above crashed the app once (08:21:35) — a bench crash, nothing recording. The bench
also taught one trap: settings passed as launch arguments (`-letslapse.capture.resolutionWidth …`) are re-saved by the
app's own menus into the real preferences; the 18 Pro's resolution, burst resolution, Interval blend depth and mode
were put back afterwards (stabilization was left as found), and the 16 Pro was checked unchanged.

## Evidence, and how it was pulled without touching the app

```
xcrun devicectl device info files --device <udid> --domain-type systemCrashLogs              # inventory, sizes
xcrun devicectl device copy from  --device <udid> --domain-type systemCrashLogs \
  --source <file> --destination <dir>/<file>                                              # one named file per call
xcrun devicectl device copy from  --device <udid> --domain-type appDataContainer \
  --domain-identifier com.regularsteven.letslapse \
  --source "Library/Application Support/LetsLapse/Logs/<file>" --destination <dir>/<file>
```

Named files only (≈ 5 MB over the LAN); `copy from` leaves the originals on the phone. Nothing launched, installed or
attached. `log collect --device-udid …` needs root (`log: Must be root to collect logs from attached device`).

On the phone, 09-18 → 26: 18 LetsLapse crash reports, 6 JetsamEvent, 1 kernel panic (+ ResetCounter),
8 `cpu_resource`, 3 `diskwrites_resource`. Console logs older than 09-22 have been pruned; 09-22 → 26 were on the Mac
from earlier pulls.

## The crash reports: three signatures

| Signature | Reports | Build | Status |
|---|---|---|---|
| `setExposureModeCustom…` on the virtual device (JPEG Dynamic/Ladder Record) | 13 — 09-20 ×7, 09-21 ×6 (last 09:42) | 492888db | Fixed e29e19a (09-21), none since |
| `-[AVCaptureOutput liveConnections]` in `startNextSegment` (Video ramp, `4224x3024@10`) | 1 — 09-20 11:15 | 492888db | Owed: TODO *iOS 27 exposure follow-ups* #1 |
| `-[AVCapturePhotoOutput capturePhotoWithSettings:delegate:]` ← `CameraController.startInterval` tick (Photo mode) | 4 — 09-21 19:51, 09-24 09:35, 09-26 09:28, 09:29 | 72084e83, 65f1add6 | **Open** — below |

All `EXC_CRASH SIGABRT` with only `abort() called` in `asi`. iOS 27 `.ips` files never carry the exception's reason.

## The Photo abort

### What throws

Read from the 24A437 AVFCapture in Xcode DeviceSupport (`iPhone19,2 27.0 (24A437)/arm64e.x1/Symbols/…/AVFCapture`):
`-[AVCapturePhotoOutput capturePhotoWithSettings:delegate:]` (0x1ad005668) validates the request, builds an
NSException, then asks `_AVCaptureShouldThrowForAPIViolations` (0x1ad0058f4). For an app linked against the iOS 27 SDK
the answer is yes and `objc_exception_throw` runs at +904 — `imageOffset 1112560` in all four reports. Otherwise it
logs `** Suppressing exception throw for API contract violation - %@` and returns without capturing. Same mechanism as
the 09-21 exposure abort: an older SDK silently dropped the shot; iOS 27 aborts.

The reason is one of four inline checks — *Nil delegate*, *Captures are not supported while Personal Photographer is
enabled*, **No active and enabled video connection**, *autoSpatialOverCaptureEnabled is not supported through this
interface* — or one of ~90 strings `_po_photoSettingsAreValid` can return. The interval tick sends a fresh
`AVCapturePhotoSettings()` carrying only `maxPhotoDimensions = selectedPhotoDimensions` and shutter-sound suppression
(gated on `isShutterSoundSuppressionSupported`), which leaves three live candidates:

1. *No active and enabled video connection*
2. *If you specify a non-nil maxPhotoDimensions, it must not be larger than the maxPhotoDimensions set on the AVCapturePhotoOutput*
3. *If you specify a maxPhotoDimensions, it must match one of the supportedMaxPhotoDimensions of the video devices's active format*

### When it throws: the format, not the lens

Every run in the 09-22 → 26 console logs, with the format and lens pin in force at the time:

| Path | Format | Result |
|---|---|---|
| Photo capture | **4224×3024@25** | **3 of 3 aborted** (09-24 09:35, 09-26 09:28, 09-26 09:29) |
| Photo capture | the session's starting format, or 4032×3024@25 | none aborted — dozens at 4× telephoto (zoom 8.0), 8×, 1×, 0.5× |
| JPEG interval (Holy Grail), telephoto pinned | **4224×3024@25** | **5 of 5 runs saved 0 frames**, logging `CVPixelBuffer wrap failed (status -6684)` |
| JPEG interval, main camera pinned | 4032×3024@25 | fine (55 windows) |
| DNG interval | **4224×3024@25** | healthy — the 4,908-window shoot of 09-23 18:57 and a 924-window one (a short test run before them lost 15 of 117 windows) |

The cleanest pair is one launch on 09-26: Photo at 8× on 4032×3024 → saved at 09:28:32;
`applyCaptureFormat … → 4224×3024@25` at 09:28:44; the next Photo at 8× → abort at 09:29:02. The 09-20 Video abort
was on `4224x3024@10` too. **On iOS 27 the 18 Pro's 4224×3024 readout — which `CaptureResolution.aspectRatioLabel` files
under "4:3" — breaks the processed-stills and movie paths; RAW is unaffected.** No console log survives for 09-21 19:51;
a DNG run 40 s before it delivered no frame in any of its three windows.

`-6684` is `kCVReturnPixelBufferNotMetalCompatible`: the JPEG live blend receives its photos, in buffers Metal cannot
wrap, so the run saves nothing — a silent failed shoot rather than a crash.

### The reason, read on the device

Reproduced on the installed build by the crash-1 path over the remote, with the app under `devicectl … --console`:
*"-[AVCapturePhotoOutput capturePhotoWithSettings:delegate:] If you specify a maxPhotoDimensions, it must match one
of the supportedMaxPhotoDimensions of the video devices's active format"* — candidate 3. The fix build's first shot on
the same path logged the facts behind it: `4224×3024 would be refused — asking 1920×1080 (the output's maximum is
1920×1080; the active format lists 1920×1080, 4224×2376)`.

### The fix (branch `claude/photo-preflight`)

Two layers. **The format** (`CameraController`): `captureFormatMatch(stills:)` lets video stabilization and the frame
rate rank a stills format instead of ruling it out; `applyCaptureFormat` never misses silently — it logs the rule that
failed (`formatMissReason`) and, for stills, falls back to the largest smaller size of the same shape
(`stillsFallback`: 4224×3024 → 4032×3024); `setStillsCapture` (from `CaptureView`, beside `setPhotoViewfinder`)
tells the controller Photo or Interval is up; and `assertStillsFormat` puts every Photo/Interval run on the chosen
size before its first still, whatever the session was left on. **The request** (`App/PhotoRequestPreflight.swift`,
the `startInterval` tick), the net under it:

- **Size** — `maxPhotoDimensions` is asked of the live output and format, only by the two checks AVFoundation states
  (not above `photoOutput.maxPhotoDimensions`; one of the source device's `activeFormat.supportedMaxPhotoDimensions`).
  A size both take is sent exactly as before; otherwise the largest smaller size they take, or none (unset — the
  output's own maximum governs, as the Scanner has always done). Logged once a run: `capture: still size — …` with
  the output's maximum and the format's list.
- **Connection** — no active and enabled video connection → the still is not asked for:
  `capture: still refused — …`, a `capture_refused` event, an issue in the run's log. An Interval run skips the
  tick; a Photo finishes once what it did ask for has landed (the shutter never waits on a still that will not
  come).
- **The open theory, reported not acted on** — on a virtual device, if the active constituent's format does not list
  the size, the `still size` line says so. If an abort still comes, the line before it answers whether iOS 27 asks
  the telephoto's own format.

The request check's size logic was tested on the Mac against eleven cases; the iOS build and its dSYM are kept at
`~/Library/Developer/LetsLapseRun/dd-photo-preflight`.

### On the device (2026-09-26 evening, over the Camera remote, `shoot.py prep` + `tools/remote_probe`)

| Build | Run | Result |
|---|---|---|
| installed (the afternoon's) | Holy Grail JPEG · 4× (pinned, 4224×3024) | 6 windows `-6684`, 0 frames |
| installed | then Photo · 4× | **abort** — the reason above; `LetsLapse-2026-09-26-175101.ips` |
| request check only | the same two runs | 0 frames; Photo saved **at 1920×1080** (the check shrank the ask) — no abort |
| format + request | launch into Photo | `no 4224×3024@25 for stills on Back Triple Camera — no format at that size` → `fall back to 4032×3024` |
| format + request | Photo · 4× / 1× / 0.5× | **3024×4032** each (EXIF: main 6.93 mm + 2.15× digital / main / ultra-wide 2.22 mm) |
| format + request | Holy Grail JPEG · 4× pinned, then Photo · 4× | 0 frames (`-6684`, not in this fix); pin release re-applies 4032×3024; Photo **3024×4032**, no abort |

The 4× shots came from the main camera with digital zoom: in the evening light the Triple Camera chose it over the
f/2.8 telephoto — the same camera this morning's 4× shot on 4032×3024 came from the telephoto (16.89 mm). That is the
virtual device's own switching, not this fix; forcing the telephoto means pinning the physical lens for stills.

**Still open:** the menu offers 4224×3024 for Photo, which the Triple Camera cannot shoot (it now shoots 4032×3024
and says so only in the log); the JPEG live blend on the pinned telephoto at 4224×3024 (`-6684`, 0 frames); the
Video abort on `4224x3024@10`; the Scanner/DNG/probe `capturePhoto` sites without the request check.

## The other reports

- **Jetsam (6):** LetsLapse was never the process killed — every kill was a system daemon. Its footprint: 921 MB
  frontmost on 09-23 20:44 (lifetime max 1.7 GB), 530 MB frontmost at 14:15 on 09-26 mid-upload (max 1.4 GB), and a
  2.56 GB lifetime max on 09-25.
- **Kernel panic, 09-22 12:14:** `SEP Panic: [elfour panic] exception.c` — the Secure Enclave's firmware on 24A427.
  LetsLapse was suspended in the background (its log quiet since 08:06). Not the app; the phone has since moved to
  24A437. File it with Apple if it recurs.
- **cpu_resource ×8, diskwrites_resource ×3:** all `Action taken: none` — 50 % CPU over three minutes during
  capture/blend/upload work, and the daily write allowance (4.3 GB in 16 minutes on 09-25 16:26). Not symbolicated: no
  dSYM on the Mac matches their builds, because the shared DerivedData keeps only the latest.

## Side finding

By 09-24 morning every optics and lifecycle line was logged five times (09-26: twice) — `app didBecomeActive`,
`optics: constituent →`, `optics: ramp …`. `CameraController` adds NotificationCenter block observers whose tokens are
dropped, and each controller installs its own constituent KVO, so either five controllers were alive or the
registration ran five times. TODO entry filed.

## Recipe: an AVFoundation throw's reason, offline

The `.ips` names the frame (`AVFCapture` + `imageOffset`); the reason strings live in that binary. With the
DeviceSupport copy for the phone's exact build:

```
A=".../iOS DeviceSupport/iPhone19,2 27.0 (24A437)/arm64e.x1/Symbols/System/Library/PrivateFrameworks/AVFCapture.framework/AVFCapture"
otool -l "$A" | grep -A4 "segname __TEXT$"                      # __TEXT vmaddr; throw site = vmaddr + imageOffset
otool -tV -p '-[AVCapturePhotoOutput capturePhotoWithSettings:delegate:]' "$A"
```

otool prints the reasons as `@"bad cfstring ref"`: they sit in the image's `__AUTH_CONST,__cfstring`. Read each 32-byte
CFString (`isa, flags, ptr, length`), keep the low 36 bits of `ptr`, add `0x180000000`, and read `length` bytes from
`__TEXT` (map a vmaddr to a file offset with the segment table). Walk every `adrp`/`add … cfstring` pair of a function
to list all the reasons it can raise — this is how the ~90 strings of `_po_photoSettingsAreValid` above were read.
