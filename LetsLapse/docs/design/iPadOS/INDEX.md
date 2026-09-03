# iPadOS design specs

Canvas 820×1180 pt (iPad 10th gen class), portrait + landscape where bespoke.

⚠️ **2026-08-29, behaviour split from iPhone:** iPad no longer auto-opens the
camera — at launch or on the Create tab — by default
(`CreateCameraSetting`, Settings ▸ Recording toggle). Create lands on the
editing home, the Mac's posture. Affects any iPad spec that assumed the
capture screen as the launch surface; Settings ▸ Recording gains the toggle
row (shared iOS layout).

🟡 **Mostly shared-spec.** The app is a universal target; iPad renders the iOS layouts (floating pill tab bar, same screens) — with one exception since 2026-08-12: the **guided clip builder's steps rail** activates on any surface ≥ 700×500pt, which covers every iPad orientation, so iPad shows the macOS layouts for that flow. When further iPad-specific passes happen (split layouts, wider capture rails), files land here following the conventions in [../README.md](../README.md).

**2026-08-25 — the Scans tab is now conditional.** `LLTab.visible(scans:)` drops it from `FloatingTabBar` unless the library holds a scan and **Settings ▸ Advanced ▸ Layout ▸ Enable Scans menu** is on; with the switch off, scanner runs are listed in Projects behind a Scans filter instead. The bar's metrics are count-derived, so it falls back to five 66pt seats on its own. Same code on every platform — see `iOS/settings.layout.portrait.svg` and `iOS/projects.scans-filter.portrait.svg` for the drawn specs.

| Screen | File | Mirrors | Status |
|---|---|---|---|
| Guided clip (experimental) — all steps | — | `GuidedBuilderView` railLayout — shares the macOS specs ([../macOS/guided-builder.canvas.svg](../macOS/guided-builder.canvas.svg), [../macOS/guided-builder.canvas.wide.svg](../macOS/guided-builder.canvas.wide.svg), [../macOS/guided-builder.moment.svg](../macOS/guided-builder.moment.svg)): steps rail, one stage per step, overview strip, output-rate row. iPad-specific: touch drives the framing surface (pinch zooms the punch — no scroll-wheel or hover cursors), and the crop drag was verified with an injected touch path on the iPad Pro 13-inch sim. The scrub previews (strip + pane drags) run on touch — pane drags are axis-classified so vertical swipes still scroll; no hover-to-peek | 🟡 shared-spec row; verified on iPad Pro 11/13 sims 2026-08-12 (scrub verified via injected touch path, iPad Pro 13) |
| Scans (tab) | — | `App/ScansView.swift` and its detail/viewer/export siblings — renders the iOS specs; the only difference is the page grid's column count, which follows width (3 columns from 600pt, 4 from 1000pt) rather than device, so no bespoke file is owed | 🟡 |
| Interval · Ladder (capture, picker, ladders list, editor, rung) | — | `App/LightLadderViews.swift`, `App/LightLaddersView.swift`, `App/CaptureDials.swift` — renders the iOS specs (`../iOS/capture-interval.ladder*.portrait.svg`, `../iOS/interval-ladder*.portrait.svg`); plain lists and viewfinder overlays, one build for iPhone and iPad by decision (D8, `docs/light-ladder.md`). One presentation difference, recorded here as the handoff asked: the **ladder picker** is a medium-detent sheet on iPhone and the same content as a **form sheet** on iPad — not the handoff's popover, because the chip lives inside the `Equatable` dial row that a popover anchor would have to reach through | 🟡 shared-spec row, 2026-09-03 |
| Everything else | — | Renders the iOS portrait specs in [../iOS/](../iOS/) | 🟡 |
