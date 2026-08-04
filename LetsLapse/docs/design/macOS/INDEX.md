# macOS design specs

Canvas: 760×680 pt default window (`LetsLapseApp.defaultSize`); capture presents as a ≥960×720 sheet.

🟡 **All files planned — none drawn yet.** macOS shares the SwiftUI screens with iOS but differs structurally: the floating pill tab bar replaces native tabs (reselect-to-pop), the blended-clip flow lives *inside* the Create tab rather than as a full-screen overlay, capture is a sheet, and Settings adds a Camera access card. When macOS UI work happens, files land here following [../README.md](../README.md).

| Screen | File | Mirrors | Status |
|---|---|---|---|
| Photo viewer / grading editor | `photo-viewer.svg` | `PhotoViewerView` — own **resizable window** (not a sheet; `PhotoEditorWindowRequest` scene in `LetsLapseApp`), default 1000×700, min 720×480, full-screen capable. Fixed 340pt control rail on the right; image pane takes all remaining space. No in-content Done bar — window chrome owns title & close (iOS sheet keeps its Done bar). | 🟡 |
| Adjust / warp timeline (in the Create tab) | — | `WarpTimelineView` — shares the iOS spec ([../iOS/adjust.portrait.svg](../iOS/adjust.portrait.svg) + [../iOS/adjust.zoomed.portrait.svg](../iOS/adjust.zoomed.portrait.svg), wide layout above 560pt). macOS-specific (2026-08-03): **right-click on a stretch tile opens the native context menu** (Remove stretch [disabled on the last one] · Split here · Reset speed — same actions as the inline card, which macOS reaches via the ⋯ button only; the 0.45s hold is iOS-only so a slow mouse press can't trip it); trackpad pinch zooms (anchored under the pointer on macOS 14+); **double-click** zooms in/out for mouse users; **Cmd-Z / Shift-Cmd-Z** drive the timeline undo history through the window's UndoManager. | 🟡 |
