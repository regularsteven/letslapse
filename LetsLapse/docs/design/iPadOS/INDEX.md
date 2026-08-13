# iPadOS design specs

Canvas 820×1180 pt (iPad 10th gen class), portrait + landscape where bespoke.

🟡 **Mostly shared-spec.** The app is a universal target; iPad renders the iOS layouts (floating pill tab bar, same screens) — with one exception since 2026-08-12: the **guided clip builder's steps rail** activates on any surface ≥ 700×500pt, which covers every iPad orientation, so iPad shows the macOS layouts for that flow. When further iPad-specific passes happen (split layouts, wider capture rails), files land here following the conventions in [../README.md](../README.md).

| Screen | File | Mirrors | Status |
|---|---|---|---|
| Guided clip (experimental) — all steps | — | `GuidedBuilderView` railLayout — shares the macOS specs ([../macOS/guided-builder.canvas.svg](../macOS/guided-builder.canvas.svg), [../macOS/guided-builder.canvas.wide.svg](../macOS/guided-builder.canvas.wide.svg), [../macOS/guided-builder.moment.svg](../macOS/guided-builder.moment.svg)): steps rail, one stage per step, overview strip, output-rate row. iPad-specific: touch drives the framing surface (pinch zooms the punch — no scroll-wheel or hover cursors), and the crop drag was verified with an injected touch path on the iPad Pro 13-inch sim. The scrub previews (strip + pane drags) run on touch — pane drags are axis-classified so vertical swipes still scroll; no hover-to-peek | 🟡 shared-spec row; verified on iPad Pro 11/13 sims 2026-08-12 (scrub verified via injected touch path, iPad Pro 13) |
| Everything else | — | Renders the iOS portrait specs in [../iOS/](../iOS/) | 🟡 |
