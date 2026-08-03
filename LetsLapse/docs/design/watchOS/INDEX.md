# watchOS design specs

Canvas 208×248 pt (Apple Watch 46 mm). No orientation. Status: ✅ Synced · ⚠️ Stale · 🟡 Planned.

Last full sync: 2026-08-02, working tree of `ios-app` (arm-then-fire burst + total-anchored Stop At: specs signed off, implemented, and verified on the paired-sim rig the same day).

The Watch app is a remote for the phone's capture screen, in three states: **Ready** (camera open on phone), **Recording** (no-look controls), **Unreachable** (explains the fix). Photo mode is phone-only and never offered here.

| Screen | File | Mirrors | Status |
|---|---|---|---|
| Ready (Interval selected) | [ready-interval.svg](ready-interval.svg) | `Watch/WatchControlView.swift` (`readyScreen`, `modeSelector`, `intervalRow`, `framesRow`, `exposureControl`) | ✅ |
| Recording · Video (ramp) | [recording-video.svg](recording-video.svg) | `Watch/WatchControlView.swift` (`recordingScreen`; `burstToggle` — segmented, sides select states; `timedBurstRow` — armed chips, tick = persisted default; `SlideToStop`, `intervalDots`) | ✅ |
| Recording · Video (ramp, freeform burst) | [recording-video.freeform.svg](recording-video.freeform.svg) | `burstToggle` reads "⚡ burst", no chip ticked (duration deselected) | ✅ |
| Recording · Interval | [recording-interval.svg](recording-interval.svg) | `Watch/WatchControlView.swift` (`captureCountBadge`, `runSettingsLine`) | ✅ |
| Stop at… (sheet) | [stop-at-sheet.svg](stop-at-sheet.svg) | `Watch/WatchControlView.swift` (`StopAtSheet` — total-anchored from run START, dial floors at elapsed+1, live "stops in" caption, Frames hidden for Video) | ✅ |
| Unreachable | [unreachable.svg](unreachable.svg) | `Watch/WatchControlView.swift` (`unreachableScreen`) | ✅ |
| Ready (Video selected) | — | `modeSelector` with Video ticked; no Every/Blend rows | 🟡 |
| Ready (Bulb armed) | — | amber "Bulb · start, then slide to stop" banner | 🟡 |
| Interval/frames pickers (sheets) | — | `intervalRow`/`framesRow` `.sheet` lists | 🟡 |
| Exposure locked (ready) | — | `exposureControl` locked branch | 🟡 |
