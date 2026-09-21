# 2026-09-21 — iOS 27 refuses a locked custom exposure on a virtual device (iPhone 18 Pro crash)

**Device:** iPhone 18 Pro (`iPhone19,2`), iOS 27.0 (24A427), app 0.1.0 (1) built with
Xcode 27.0 / iOS 27 SDK. **Not** reproducible on the iPhone 16 Pro, 12 Pro or the iPads
on iOS 26.6.

## Symptom

INTERVAL project, Output Format **JPEG**, MODE **Dynamic** or **Ladder** → the app aborts the
moment Record is pressed, no capture. JPEG + Basic (blend off or 10) and every DNG combination
run. Steven's matrix, 2026-09-21 morning.

## Evidence

Pulled from the phone without touching it (all read-only, originals kept on device):

```
idevicecrashreport -u 00008160-0008444E2280000A -k -f LetsLapse <dir>          # 13 .ips
xcrun devicectl device copy from --device <udid> --domain-type appDataContainer \
  --domain-identifier com.regularsteven.letslapse \
  --source "Library/Application Support/LetsLapse/Logs" --destination <dir>      # console-*.log
  --source "Library/Application Support/LetsLapse/Libraries/<id>/CaptureLogs"    # capture-*.log
```

Twelve of thirteen reports share one uncaught ObjC exception (SIGABRT, `lastExceptionBacktrace`):

```
CoreFoundation  __exceptionPreprocess
libobjc         objc_exception_throw
AVFCapture      -[AVCaptureFigVideoDevice _setExposureModeCustomWithLensAperture:duration:ISO:entryPoint:completionHandler:] + 1244
AVFCapture      -[AVCaptureFigVideoDevice setExposureModeCustomWithDuration:ISO:completionHandler:] + 64
LetsLapse       CameraController.applyHolyGrailExposure()
LetsLapse       CameraController.beginHolyGrailForBlendRun(interval:directory:autoInterval:rawPipeline:)
LetsLapse       CameraController.startLiveBlendStandard(every:depth:requestedOutputFormat:)
```

The console log of the 08:53 crash names the write:

```
liveblend: shutter ceiling raised 0.040s → 1.00s (video frame duration)
liveblend: interval — 1× optical · Back Camera · zoom 2.0 (native) · 73.3° · jpeg-flat
optics: constituent switching locked to WideAngleCamera for the run
holygrail: re-split the AE seed — metered 0.0163s ISO 142, seeding 0.0421s ISO 55
holygrail: WB tracking armed (seed R 1.63 G 1.00 B 2.67)
<abort>
```

i.e. `setExposureModeCustom(duration: 0.0421 s, iso: 55)` on the **virtual** back camera, format
`1920×1080@25`. The DNG run twenty seconds earlier in the same launch wrote `(0.1169 s, ISO 55)`
on the **physical** wide (photo preset) and ran all its windows. The exception reason is not in
the `.ips` (iOS 27 writes only `abort() called`); it came from the binary instead.

## Root cause — read from the iOS 27 AVFCapture

Xcode's device support has the OS binaries: `~/Library/Developer/Xcode/iOS DeviceSupport/iPhone19,2
27.0 (24A427)/arm64e.x1/Symbols/System/Library/PrivateFrameworks/AVFCapture.framework/AVFCapture`
(and the 26.6 one under `iPhone17,1 26.6 (23G71)`). `otool -tV` on the crashing method, the
`__cfstring` table decoded by hand, and the validator it calls:

1. iOS 27 adds a **variable-aperture exposure model**: `setExposureModeCustom(lensAperture:duration:iso:)`,
   the sentinels `AVCaptureDevice.currentLensAperture` (= `FLT_MAX`) / `.autoLensAperture` (= −2) /
   `.autoExposureDuration` / `.autoISO` (priority modes), `Format.minLensAperture` /
   `maxLensAperture` / `defaultLensAperture` / `recommendedLensApertureStops`, and a per-format
   predicate `Format.supportsExposureModeCustom(lensAperture:duration:iso:)`.
2. The legacy two-argument setter is now a wrapper that passes `currentLensAperture` — **all
   three parameters locked**.
3. Every custom write first runs
   `-[AVCaptureDeviceFormat _checkCustomExposureModeWithLensAperture:duration:ISO:entryPoint:]`,
   in this order: `.custom` supported at all → aperture (sentinel, or range on the format) →
   duration range → ISO range → **the auto/locked combination**. For the fully locked
   combination it reads the format's source device type and raises `NSInvalidArgumentException`
   *"Unsupported combination of auto/locked parameters (lensAperture locked, duration locked, ISO
   locked), use -[AVCaptureDeviceFormat supportsExposureModeCustomWithLensAperture:duration:ISO:]
   to check mode support"* for source types **4 = BuiltInDualCamera, 8 = BuiltInDualWideCamera,
   9 = BuiltInTripleCamera** — every virtual device. Physical types (2 wide, 3 tele, 7 ultra-wide)
   pass. (Types decoded from `_AVCaptureDeviceTypeFromSourceDeviceType`.) ISO-priority is refused
   everywhere; shutter-priority passes a further device check; aperture-priority and full auto pass.
   `supportsExposureModeCustom(…)` is exactly `_check…(entryPoint: nil) == nil` — a non-throwing
   predicate for the precise write.
4. The throw is gated by `_AVCaptureShouldThrowForAPIViolations` (a cached linked-on-or-after-SDK
   flag). Linked against the iOS 27 SDK the process aborts; an older-SDK binary logs
   *"** Suppressing exception throw for API contract violation - …"* and **returns without
   writing** — the ramp would shoot on AE with the readout claiming a ramp.
5. The iOS 26.6 binary has neither the validator nor any of these strings. And
   `device.isExposureModeSupported(.custom)` still answers **true** on the virtual device under
   iOS 27, so the app's guard passed.

Why JPEG only: the standard (JPEG) blend pipeline armed the ramp on the virtual optics device
(`captureOpticsDevice()` prefers triple / dual-wide; `lockConstituentSwitchingForRun` pinned it).
The DNG pipeline swaps the session input to a physical constituent first, and Photo's M mode does
the same (`armPhysicalDeviceForManualExposure`) — both "because the virtual one refuses `.custom`",
which `holygrail-ramp-actuation.md` had recorded as a hypothesis on 2026-08-27 and as silent
refusals on the 12 Pro on 2026-09-04. This is the measurement: the refusal is the virtual device's,
and iOS 27 made it fatal.

## The fix (`App/CameraController.swift`, `App/CaptureOptics.swift`)

- A ramped standard run (Dynamic / Ladder, JPEG) now takes the same lens pin a video sequence
  takes (`pinLensForSequence`): the stop's own physical constituent, framing preserved as a crop
  of that lens, focus carried across the swap; released at teardown like a video take's.
- One custom-exposure writer, `writeCustomExposure(on:duration:iso:)`, replaces the eight direct
  `setExposureModeCustom` calls: clamps through the active format, and on iOS 27 asks
  `supportsExposureModeCustom` for the exact triple before writing — a refusal comes back as a
  value with the device facts, never an exception. The ramp reports it through its refusal trail
  (`issues[]`, `rampDriving`); the AE/AF lock, the switch hold and the scanner fall back to
  `.locked`.
- Variable-aperture lenses are locked at **f/1.8** on every custom write (`CaptureAperturePolicy`;
  Steven's decision — the fixed f/1.78 of earlier Pro main lenses; fixed lenses keep their own
  aperture, a numeric value on one is itself a refusal). The ramp's seed scales AE's metered gain
  by `(locked / metered)²` so frame 0 keeps AE's brightness, and the engine's EV maths carries the
  locked aperture.
- Same class of uncatchable write, hardened while here: `relaxVideoFrameDurationForBlend` is
  clamped to the format's advertised frame-rate range; the tracked-WB write checks
  `isLockingWhiteBalanceWithCustomDeviceGainsSupported`.
- `LL_PROBE_FORMATS=1` (Debug) now prints each lens's aperture range and the predicate's answer
  for the five combinations, virtual device and constituents alike.

## Verification (2026-09-21, same day)

**iPhone 18 Pro, iOS 27.0, Release build over the Camera remote** (`shoot.py run`, the new
`--output-format` verb switching the still format — it was the one dial the remote could not reach):

| row | result |
|---|---|
| JPEG · Dynamic · blend 3 (0.5× and 1×) | 6 frames each, 100 % density, `0 refused exposure write(s)` |
| JPEG · Ladder (built-in) | 9 frames, ramp stepping 0.0568 → 0.0855 s |
| JPEG · Basic · blend off / blend 10 | 6 / 5 frames, on the virtual device as before (no pin) |
| DNG · Ladder | 9 windows, 3/3 each |
| DNG · Dynamic · blend 3 | 5 windows, 3/3 each |

The 1× runs pin the physical `Back Camera`; the console shows `holygrail: aperture locks f/1.80
(AE metered at f/1.64) — seed gain ×1.20`, and the JPEGs' EXIF reads f/1.80 · 0.05 s · ISO 50 with the
ramp moving the shutter by frame 6. The DNGs read f/1.8 too. The 0.5× run pinned the fixed-aperture
ultra-wide and, correctly, sent no aperture. No new `.ips` on the phone afterwards.

`LL_PROBE_FORMATS=1` (Debug) on the 18 Pro — the rule, from the device:

```
TripleCamera (virtual)  aperture f/1.48–f/4.00 default f/1.80 stops [1.48,1.80,2.80,4.00] policy f/1.80 · isExposureModeSupported(.custom)=true
   allLocked(current)=false allLocked(policy)=false shutterPriority=true isoPriority=false aperturePriority=true
WideAngleCamera (physical) aperture f/1.48–f/4.00 … allLocked(current)=true allLocked(policy)=true shutterPriority=true isoPriority=false aperturePriority=true
UltraWideCamera (physical) aperture f/2.20 fixed  … allLocked=true   TelephotoCamera (physical) f/2.80 fixed … allLocked=true
```

**iPhone 16 Pro, iOS 26.6, same build:** JPEG Dynamic (5 windows) and JPEG Ladder (7 windows) at
1×, pinned to `Back Camera at zoom 1.00 for 4032x3024@25`, 0 refusals, pin released after each; frames
at f/1.78 · 0.25 s · ISO 50 — unchanged. (Its "Allow remote access" was off; the run was launched
with `-remote.allowRemoteAccess YES` as a launch argument, nothing written.)

## Also in the pull — a different iOS 27 crash, owed

`LetsLapse-2026-09-20-111526.ips`: a **Video** ramp take at 0.5× on a `4224x3024@10` format,
right after a lens-pin input swap, aborted in `startNextSegment(resolution:frameRate:)` with an
exception from `-[AVCaptureOutput liveConnections]` (the movie output had no live video
connection when the segment started). One occurrence; in `docs/TODO.md`.
