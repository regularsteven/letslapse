# LetsLapse — Collections UX Brief

Prepared 2026-08-01 for a product/UI designer. This brief covers **one new feature — Collections** — for the current LetsLapse iPhone app.

Companion documents:

- `LetsLapse/docs/letslapse-app-overview.md` — the app-wide handover: what the app is, every screen, the architecture, and the vocabulary system.
- `LetsLapse/docs/design/README.md` — the design-spec contract: SVG mirrors of every screen, canvas conventions, design tokens.
- `docs/letslapse-ios-ux-brief.md` — the previous app-wide brief. It led to the 2026-07 redesign that shipped; it is retained for history and should not be used as a description of the current app.

## Vocabulary (canonical, as of 2026-08)

| Term | Meaning |
|---|---|
| **Project** | One original capture (or import) plus everything derived from it. Created in one of three capture modes: Photo, Interval, or Video. |
| **Source clip** | Raw recorded media inside an Interval or Video project (a video project can hold several segments and codec encodings). |
| **Blended clip** | A generated output of a project — the result of a blend run. Formerly called a "version" in-app; renamed 2026-08. A project can hold many, and every one is reproducible from the original. |
| **Collection** | **New.** An ordered set of blended clips gathered from across projects, arranged on a timeline with optional in/out points, exported as a single video. |
| **Speed N×** | The blend-window vocabulary ("100×" = 100 real frames averaged into one output frame). See overview §2.2. |

## The assignment

Design the Collections experience end to end for iPhone:

- **A. Create a collection** — creation, naming, and how the Collections tab presents zero, one, and many collections.
- **B. Select blended clips from projects** — the building blocks of a collection: a browsing/nomination experience over the user's projects and their blended clips.
- **C. Timeline builder** — arrange the selected blended clips in order, with optional in and out points per clip.
- **D. Export** — render the collection as a single video saved to the device, respecting the arranged order and the in/out points.

## Scope

In scope:

- Blended clips from **Interval** and **Video** projects.

Out of scope:

- **Photo-mode captures** — a Photo project is one asset and has no blended clips.
- **Source clips** inside Interval/Video projects — collections are built from blended clips only, not raw footage.
- Transitions, titles, music/audio beds — not asked for in v1. Flag anything here you believe is essential rather than designing it in silently.

## Current state in the app

- The **Collections tab already exists as a placeholder** in the fifth tab slot (Create · Gallery · Projects · Collections · Settings): large title, amber "Coming soon" subtitle, one empty-state card. Spec: `LetsLapse/docs/design/iOS/collections.portrait.svg`.
- Blended clips live in **project detail** (a "Blended clips" section with rows like "Blended clip 3 · 100× · 8s") and as thumbnail strips on **Projects** cards. Specs: `project-detail.video.portrait.svg`, `project-detail.interval.portrait.svg`, `projects.portrait.svg`.
- Every blended clip is a finished, graded file on disk. Video blended clips are H.264 `.mp4`; an Interval project blended at full depth produces a long-exposure **image** (`.png`) instead — decide whether stills are placeable in a collection (e.g. held for N seconds) or whether collections are video-only.

## Questions the design should answer

- **Entry points.** Does nomination start from inside a collection ("add clips"), from a blended clip's own row/context menu ("add to collection"), or both?
- **The picker.** Browse by project, or one flat reel of every blended clip? How do the existing capture filter (All · Photos · Interval · Video) and thumbnail language carry over?
- **Timeline.** The reorder interaction; how in/out points are set, shown, and cleared; what a clip with no in/out set looks like next to a trimmed one.
- **Mixed media.** Blended clips differ in resolution, frame rate, orientation, and duration. How does the design communicate and resolve mismatches at export (letterbox, crop, an export preset)?
- **Reuse.** Can one blended clip appear twice in a collection? In several collections at once?
- **Broken references.** Deleting a blended clip (or its whole project) that a collection uses — what does the collection show afterwards?
- **Export.** Destination (Photos, share sheet, both); progress and cancel — the app has an established one-bar progress + phase-checklist pattern worth reusing (overview §4.9); and the post-export result state.
- **Empty and edge states.** Empty Collections tab (today's placeholder), an empty collection, a single-clip collection, a library that has projects but no blended clips yet.

## Deliverables

Per the design contract in `LetsLapse/docs/design/README.md`:

- SVG screens, one file per screen per orientation, 393×852 pt canvas, drawn with the LL tokens (accent `#C36A00`, amber `#FFB340`, ink `#1C1C1E`; full table in the README).
- Each meaningfully different state as its own variant file, tracked in `LetsLapse/docs/design/iOS/INDEX.md`.
- Interaction notes where a static SVG can't carry them (reorder gesture, trim handles).

Screenshots of the current app can be produced without tap automation via the DEBUG launch hooks (`LL_TAB=collections`, `LL_TAB=projects`, `LL_DETAIL=latest` — overview §9).
