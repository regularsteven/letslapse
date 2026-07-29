# LetsLapse — agent instructions

## Repository layout

- `main` branch: the original Raspberry Pi LetsLapse project (Python capture/blend scripts + web UI). **Untouchable** — never modify it from Swift-app work.
- `ios-app` branch: the native Swift app in `LetsLapse/` (universal iOS/iPadOS/macOS target + watchOS companion + `LetsLapseKit` package). Architecture handover doc: `LetsLapse/docs/letslapse-app-overview.md`.

## Design-sync requirement (ALL iOS / iPadOS / macOS / watchOS UI work)

The app's screens are mirrored as SVG design specs in `LetsLapse/docs/design/` (per-platform folders, one file per screen per orientation). The full contract lives in `LetsLapse/docs/design/README.md` — read it before any UI work. The short version:

1. **At the start of any UI task**, if the human hasn't said where to work, ask:
   *"Should we work on the design files first, the app code first, or something else?"*
   (A third standard path: the human has already edited the design files themselves — then the edited SVG **is** the spec; implement it.)
2. **After sign-off on one side, mirror the other side in the same unit of work.** A UI change is not done while its SVG (or its code) is stale.
3. Any commit touching SwiftUI layout/copy/colors/controls must update the matching SVG(s) — or state why no SVG applies. Track per-screen status in each platform folder's `INDEX.md`.
4. Verify mirrors against the running app using the DEBUG launch hooks (`LL_TAB`, `LL_OPEN`, `LL_SEED`, `LL_DETAIL`, `LL_PUSH`, `LL_CAPTURE`, `LL_SPEED`, `LL_AUTO`) via `simctl launch`.

Design tokens (`LL` in `App/DesignSystem.swift`): accent `#C36A00`, amber `#FFB340`, ink `#1C1C1E` — the README has the full table. If `DesignSystem.swift` changes, the SVGs are stale by definition.
