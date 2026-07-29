# watchOS design specs

Canvas 208×248 pt (Apple Watch 46 mm). No orientation. Status: ✅ Synced · ⚠️ Stale · 🟡 Planned.

Last full sync: 2026-07-29, working tree of `ios-app`.

The Watch app is a remote for the phone's capture screen, in three states: **Ready** (camera open on phone), **Recording** (no-look controls), **Unreachable** (explains the fix). Photo mode is phone-only and never offered here.

| Screen | File | Mirrors | Status |
|---|---|---|---|
| Ready (Interval selected) | [ready-interval.svg](ready-interval.svg) | `Watch/WatchControlView.swift` (`readyScreen`, `modeSelector`, `intervalRow`, `framesRow`, `exposureControl`) | ✅ |
| Recording · Video (ramp) | [recording-video.svg](recording-video.svg) | `Watch/WatchControlView.swift` (`recordingScreen`, `burstToggle`, `timedBurstRow`, `SlideToStop`, `intervalDots`) | ✅ |
| Recording · Interval | [recording-interval.svg](recording-interval.svg) | `Watch/WatchControlView.swift` (`captureCountBadge`, `runSettingsLine`) | ✅ |
| Stop at… (sheet) | [stop-at-sheet.svg](stop-at-sheet.svg) | `Watch/WatchControlView.swift` (`StopAtSheet`) | ✅ |
| Unreachable | [unreachable.svg](unreachable.svg) | `Watch/WatchControlView.swift` (`unreachableScreen`) | ✅ |
| Ready (Video selected) | — | `modeSelector` with Video ticked; no Every/Blend rows | 🟡 |
| Ready (Bulb armed) | — | amber "Bulb · start, then slide to stop" banner | 🟡 |
| Interval/frames pickers (sheets) | — | `intervalRow`/`framesRow` `.sheet` lists | 🟡 |
| Exposure locked (ready) | — | `exposureControl` locked branch | 🟡 |
