# LetsLapse — notes for AI coding agents

Claude Code reads `CLAUDE.md`; other agents (Codex, Cursor, Copilot, Jules, …)
read this file. `CLAUDE.md` is the full contract — read it before any change.
The short version:

## Layout

- `main` — the original Raspberry Pi project (Python capture/blend scripts +
  web UI). Never modified from app work.
- `ios-app` — the native Swift app in `LetsLapse/`: one universal
  iOS/iPadOS/macOS target, a watchOS companion, and the `LetsLapseKit` package
  in `LetsLapse/Kit/`. Architecture: `LetsLapse/docs/letslapse-app-overview.md`.
  Open, scoped jobs: `LetsLapse/docs/TODO.md` — add a job there rather than
  leaving it in a conversation.

## Building

- Humans start at `LetsLapse/docs/building.md`. Everything the build needs is
  in the checkout; there is no install step, and no hook or script runs on
  clone — git and Xcode cannot do that, so the checkout has to be complete.
- Every dependency is a Swift package that Xcode resolves on open. Two are
  local: `LetsLapse/Kit`, and a committed, patched copy of
  `ml-explore/mlx-swift-lm` at
  `LetsLapse/tools/mlx-vlm-spike/vendor/mlx-swift-lm/`. Never gitignore,
  delete or hand-edit that tree; `vendor/refresh.sh` is the only way it
  changes. Without it Xcode fails the whole package graph and reports
  "Missing package product" for every product, `LetsLapseKit` included.
- Pins are exact on purpose (`mlx-swift` 0.31.4 — newer needs a Swift 6.3
  toolchain). Do not "update to latest package versions".
- Device builds are Release, and so is the scheme's Run action. Use Debug only
  when an `LL_*` launch hook is needed: a Debug Kit is 10–20× slower and
  misleads on performance and heat.
- Command line, device:
  `xcodebuild -project LetsLapse/LetsLapse.xcodeproj -scheme LetsLapse -destination 'generic/platform=iOS' -configuration Release -derivedDataPath <scratch> -allowProvisioningUpdates build`
  then `xcrun devicectl device install app --device <udid> <.app>`.
  Engine alone: `cd LetsLapse/Kit && swift build && swift test`.

## Rules that bite

- Every screen has an SVG design mirror in `LetsLapse/docs/design/`. A commit
  that touches SwiftUI layout, copy, colours or controls updates the matching
  SVG, or states why none applies (`LetsLapse/docs/design/README.md`).
- PicPlace sync is tested only on throwaway projects: a change made on a real
  one reaches every device.
- Never commit model weights, test images, `.build/`, DerivedData or
  `xcuserdata`.
