# LetsLapse — Scans Tab: Designer Brief

**Date:** 2026-08-16  
**Status:** Design-first (no code yet — implement designs before wiring)  
**Scope:** New first-class tab + Scanner project card variant in Projects

---

## Context

LetsLapse has a Scanner mode inside Capture that detects documents and motion-triggers a shot when the scene settles, optionally rectifying each frame via perspective correction. Currently, scanner captures land in the Projects tab as timelapse sequences — the wrong mental model. The fix: give Scanner its own tab.

### Current navigation
Create · Gallery · Projects · Collections

### Proposed navigation
Create · Gallery · **Scans** · Projects · Collections

Scanner sessions are *excluded* from Projects and Gallery entirely. Projects remains for video-destined timelapse/interval/holy-grail sequences.

---

## Design tokens

These are non-negotiable — the app's design system is `App/DesignSystem.swift`:

| Token | Value | Usage |
|---|---|---|
| `LLAccent` | `#C36A00` | Primary interactive elements, active states |
| `LLAmber` | `#FFB340` | Highlight, warm accents |
| `LLInk` | `#1C1C1E` | Text, dark backgrounds |
| `LLSurface` | `#2C2C2E` | Card backgrounds |
| `LLMuted` | `#636366` | Secondary text |

Existing screens use `resizable(.bar)` tab bar, system SF Symbols, `.ultraThinMaterial` sheet backgrounds. Match those.

---

## Screens to design

### 1. Tab bar — updated

Show the five-tab layout. Scans tab icon: `doc.viewfinder` (SF Symbol). Active accent: `LLAccent`.

### 2. Scans — session list (portrait + landscape)

The root of the Scans tab. Lists scanner sessions grouped by date (today, yesterday, by month). Each session card shows:

- **Thumbnail strip** — first 3–4 corrected frames (or HEIC siblings if no correction), small horizontal row, aspect ratio reflecting the paper preset used (A4, Letter, 4×6, Square, or free)
- **Session title** — date + time, e.g. "12 Aug · 14:32"
- **Frame count** — "8 pages" (use "pages" not "frames" for Scanner)
- **Paper preset badge** — small pill: A4 / Letter / 4×6 / Square / Auto
- **Correction indicator** — a small amber tick if all frames have been perspective-corrected; a partial-fill circle if some are corrected; nothing if none
- **Duration** — time between first and last capture, e.g. "3 min 12 s"

No blend/timelapse anything on this screen.

Primary empty state: `doc.viewfinder` glyph, "No scans yet", "Start a scan from the Create tab".

### 3. Scan session detail (portrait + landscape)

Opens when a session card is tapped. Full-bleed header, then content below.

**Header:**
- Back button ("Scans")
- Title: date + time (e.g. "12 Aug, 14:32")
- Subtitle: "8 pages · A4 · 3 min 12 s"
- Correction status line: "Rectangle detected on 7 of 8 pages · corrected" *or* "Not yet corrected" *or* "No rectangle data"

**Primary action (top right or prominent bottom bar):** "Export" — SF Symbol `square.and.arrow.up`. This is the headline CTA.

**Secondary action:** "Correct perspective" — only shown when there are uncorrected frames that had a rectangle detected. Runs correction in-place. SF Symbol `perspective`.

**Frame grid:**
- 2-up grid in portrait, 3-up in landscape
- Each cell: corrected HEIC (or HEIC sibling), frame number badge bottom-left (small, `LLMuted`)
- Corrected frames: small amber `perspective` badge top-right
- Tap a cell → full-screen viewer (see screen 4)
- No blend-related controls anywhere

**No** "New Blended Clip" button. That's a Projects concept.

### 4. Full-screen frame viewer

Tap a frame in the grid. Swipe left/right between frames. Shows:

- Frame number (1 of 8)
- Capture timestamp
- Exposure metadata: shutter / ISO / EV (from sidecar)
- Whether rectangle was detected at capture time
- Share button for this single frame

Pinch-to-zoom. Double-tap to fit.

### 5. Export sheet

Tapping "Export" presents an action sheet / share sheet flow:

- **"Export all pages"** — exports a flat folder of sequentially-named HEICs (corrected where available, sibling where not): `page-001.heic`, `page-002.heic`, …
- **"Export selected pages"** — enter selection mode first (or prompt to select)
- **"View as timelapse"** — escape hatch, opens the existing timelapse project view (buried, not primary)

### 6. Projects — scanner session card variant

In the Projects tab, Scanner sessions no longer appear at all. Add a design note / annotation showing the old card being suppressed. (No new Projects card design needed — exclusion is the design.)

---

## Behaviour notes for the designer

- **Session grouping, not flat feed.** Each scanner run is a discrete capture session (like a "document"). Flat feeds mix pages from different documents.
- **"Pages" language throughout**, not "frames" or "photos". Scanner is a document metaphor.
- **Paper aspect ratio is the natural display ratio.** A4 session thumbnails should be portrait-tall; 4×6 should be landscape-wide. Don't crop everything square.
- **Correction is non-destructive.** Original HEICs are kept. Corrected variants sit beside them. The UI should never imply the original is gone.
- **No playback.** Scanner output doesn't play back as video (unless the user explicitly escapes to timelapse view). No play buttons on cards.
- **The amber colour signals "scanner-mode activity"** throughout the capture screen (overlay, settle dot, burst indicator). Use `LLAmber` as the Scans tab's signature highlight to create visual continuity.

---

## Debug hooks (for seeding test data)

The engineer will wire these after the design is agreed:

| Hook | Effect |
|---|---|
| `LL_SCANS` | Opens Scans tab directly |
| `LL_SCANS_DETAIL` | Opens a seeded session (8 pages, A4, mix of corrected + uncorrected) |
| `LL_SCANS_EMPTY` | Opens Scans tab in empty state |
| `LL_SCANS_CORRECTED` | Seeds a fully-corrected session |

---

## SVG deliverables

One file per screen per orientation, named per the design sync convention in `docs/design/README.md`:

- `scans-list.portrait.svg`
- `scans-list.landscape.svg`
- `scans-detail.portrait.svg`
- `scans-detail.landscape.svg`
- `scans-viewer.portrait.svg`
- `scans-viewer.landscape.svg`
- `tab-bar-updated.portrait.svg` (all 5 tabs)

Update `docs/design/iOS/INDEX.md` with a row per file once delivered.

---

## Out of scope (later phases)

- OCR / page naming (Scanner Phase 3)
- Multi-document grouping / named document sets
- iCloud sync for scans
- PDF export (just HEIC export for now)
