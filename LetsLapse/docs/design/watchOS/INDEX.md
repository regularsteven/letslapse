# watchOS design specs

Canvas 208×248 pt (Apple Watch 46 mm). No orientation. Status: ✅ Synced · ⚠️ Stale · 🟡 Planned.

Last full sync: 2026-08-14, working tree of `ios-app` — **the watchOS redesign**. Signed off from the Claude Design
project `04877be7` (`LetsLapse watchOS Redesign.dc.html`, turn 1): option **1a** for the recording screen, **1d** for
the armed state and framing preview, **1e** for phone-state recovery, **1f** for reliability and lock. 1b and 1c were
rejected — 1b put slide-to-stop on the horizontal axis, where it collides with tab paging ("swipe, swipe, whoops").
Previous sync 2026-08-11 (timed-burst chips 1s/2s/4s → 1s/4s/8s).

**Two things to know before reading a coordinate off these files.**

1. **The source spec is drawn in pixels; these are points.** The design doc's canvas is a 45 mm watch at 396×484 px.
   Every number in it is exactly **double** what appears here — 27 px type is 13.5 pt, the 156 px burst pad is 78 pt.
2. **A `TabView` page is not 248 pt tall.** Once the status bar, the shared header, the page dots and the pager's own
   insets have taken theirs, a recording tab keeps about **134 pt**. The spec's literal pad-plus-chips-plus-row came to
   145 pt, and SwiftUI paid for the overflow by squeezing every flexible child until the burst pad's chevron was 0 pt
   tall. The shipped geometry (`Remote/RemoteTokens.swift`) is measured against the real budget, and the commit pads
   carry `layoutPriority` so the rows give way first.

## The design's one rule

**Every irreversible gesture goes vertical; horizontal stays navigation.** Burst commits up, stop commits down, and a
sideways swipe can only ever change which page you are looking at. That separation is what makes a three-tab recording
screen safe to wear.

## The app in five states

**Armed** (camera open, 2 pages) · **Recording** (3 tabs: burst · controls · stop) · **Phone state** (camera closed /
rendering / in setup) · **Unreachable** · **Locked**. Photo mode is phone-only and never offered here.

| Screen | File | Mirrors | Status |
|---|---|---|---|
| Armed | [armed.svg](armed.svg) | `Remote/WatchControlView.swift` (`armedScreen`, `RemoteSegmented`, `exposureLockRow`, `checkFramingRow`, `startButton`) | ✅ |
| Armed · Setup page | [armed-setup.svg](armed-setup.svg) | `armedControlsScreen` — `intervalRow`, `framesRow`, `lockedExposureRow` | ✅ |
| Recording · Burst (Video, ramp) | [recording-burst.svg](recording-burst.svg) | `burstTab`, `burstPad` (`SlideToCommit` `.up`), `timedBurstRow` chips 1s/4s/8s, `exposureLockRow` | ✅ |
| Recording · Burst (marks only) | [recording-burst.marks.svg](recording-burst.marks.svg) | `markPad` — same axis, drops a mark; no duration chips | ✅ |
| Recording · Burst (Interval) | [recording-burst.interval.svg](recording-burst.interval.svg) | `captureCountPanel`, `runSettingsLine` | ✅ |
| Recording · Controls (Video) | [recording-controls.svg](recording-controls.svg) | `controlsTab`, `burstRateLadder`, `crownOwner == .burstRate` | ✅ |
| Recording · Controls (Interval) | [recording-controls.interval.svg](recording-controls.interval.svg) | `controlsTab` interval branch — `intervalRow`, `framesRow` | ✅ |
| Recording · Stop | [recording-stop.svg](recording-stop.svg) | `stopTab`, `SlideToCommit` `.down`, `stopAtRow` | ✅ |
| Stop at… (sheet) | [stop-at-sheet.svg](stop-at-sheet.svg) | `StopAtSheet` — total-anchored from run START, dial floors at elapsed+1, Frames hidden for Video | ✅ |
| Framing · live | [framing-live.svg](framing-live.svg) | `Remote/FramingPreviewView.swift` (`framePicture`, `aids`, `horizonBar`, `statusChip`) | ✅ |
| Framing · stalled | [framing-stale.svg](framing-stale.svg) | `StaleTreatment`, `staleBanner`, `isStale` | ✅ |
| Framing · square lens | [framing-square.svg](framing-square.svg) | `AspectLens`, `fitted(ratio:in:)`, `lensChip` | ✅ |
| Phone · camera closed | [phone-camera-closed.svg](phone-camera-closed.svg) | `cameraClosedScreen`, `armCameraButton` | ✅ |
| Phone · rendering | [phone-busy.svg](phone-busy.svg) | `phoneBusyScreen`, `exportProgress` / `exportETASeconds` | ✅ |
| Phone · confirm cancel | [phone-busy.confirm.svg](phone-busy.confirm.svg) | `CancelExportConfirmation` | ✅ |
| Phone · in setup | [phone-in-setup.svg](phone-in-setup.svg) | `inSetupScreen`, `phoneFlow` / `flowTitle` / `flowStep` | ✅ |
| Reliability · sending | [pending.svg](pending.svg) | `RemoteToggleRow(isPending:)`, `linkChip`, `pendingCommand` | ✅ |
| Reliability · send failed | [send-failed.svg](send-failed.svg) | `failureCard`, `RemoteCommandFailure`, `unchangedDescription(isExposureLocked:)` | ✅ |
| Controls locked | [locked.svg](locked.svg) | `Remote/ControlsLockedView.swift`, `updateIdleLock(at:)` | ✅ |
| Controls locked · unlocking | [locked.unlocking.svg](locked.unlocking.svg) | `unlockRing`, `unlockTravel` | ✅ |
| Unreachable | [unreachable.svg](unreachable.svg) | `unreachableScreen`, `phoneAppState` | ✅ |
| Framing · tall / wide lens | — | `AspectLens.tall` / `.wide` — pillarbox and letterbox variants of framing-square | 🟡 |
| Armed (Bulb armed) | — | amber "Bulb · start, then slide to stop" banner | 🟡 |
| Interval/frames pickers (sheets) | — | `intervalRow` / `framesRow` `.sheet` lists | 🟡 |

Superseded by the redesign and deleted: `ready-interval.svg`, `recording-video.svg`, `recording-video.freeform.svg`,
`recording-interval.svg`.

## Deliberate departures from the source spec

Recorded here rather than silently absorbed, so a future reader can tell a decision from a drift.

- **No clock is drawn.** The design mock shows a cyan time of day in every header because a mock has no status bar. On
  a real watch the system draws it, and inside a `NavigationStack` it sits in the navigation bar. Drawing our own would
  be a second clock.
- **The shared header lives outside the pager.** watchOS vertically centres a page whose content does not fill it, so a
  header drawn inside each tab sat at a different height on each one and visibly jumped as you paged.
- **Interval dots sit beside the run info, not above the tab bar.** At the foot of the screen they read as a second page
  indicator — two rows of dots saying "which of N" about entirely different things.
- **No "Stay in setup" button** on the in-setup screen. On the watch, not tapping anything *is* staying in setup; the
  button would do nothing.
- **The framing preview gained a back affordance and aspect lenses** (Steven, 2026-08-14). Back is the navigation
  stack's own left-edge swipe and chevron — going back is navigation, and on this remote navigation is horizontal. The
  lenses (FULL / 1:1 / 9:16 / 16:9) are a **viewing lens only**: nothing is sent to the phone and no capture or canvas
  setting changes.
- **The horizon angle comes from the phone**, not the watch (Steven, same review). The watch's own attitude describes an
  arm, which says nothing about the horizon in the frame. `App/FramingPreviewService.swift`'s `LevelSensor` reads device
  motion on the phone and sends the angle with each frame; the bar turns green inside ±1°.

## Palette

These screens do **not** use `LL` from `App/DesignSystem.swift` — `App/` is not in the watch target, and a watch face is
one of the bespoke dark surfaces the [README](../README.md) carves out. The source of truth is
`Remote/RemoteTokens.swift`; if it changes, these files are stale by definition.

| Token | Hex | Used for |
|---|---|---|
| `record` | `#FF453A` | recording, and the stop commit |
| `burst` | `#FFD60A` | burst — the high-rate segment and the controls that reach it |
| `link` | `#40C8E0` | the link itself: connection, information, read-outs |
| `go` | `#30D158` | armed, and level |
| `warn` | `#FF9F0A` | a busy phone, a send that did not land |
| `surface` / `surfaceRaised` / `surfaceTrack` | `#1C1C1E` / `#2C2C2E` / `#39393D` | rows, chips, toggle tracks |

## Verifying against the app

DEBUG launch hook, one value per screen:

```bash
SIMCTL_CHILD_LL_UI_PREVIEW=recording xcrun simctl launch "LL Watch S11" com.regularsteven.letslapse.watchkitapp
```

`recording` · `controls` · `stop` · `marker` · `interval` · `no-burst` · `armed` · `armed-setup` · `framing` ·
`framing-stale` · `framing-square` · `framing-tall` · `framing-wide` · `camera-closed` · `busy` · `setup` · `sending` ·
`failed` · `locked` · `unlocking`.

Sign-off is the paired-sim rig (iPhone 17 Pro + "LL Watch S11"). Per `Remote/RemoteWindow.swift`, **no watchOS spec may
be marked ✅ from a Mac-mirror screenshot** — the Mac remote shares this view but not its input model.
