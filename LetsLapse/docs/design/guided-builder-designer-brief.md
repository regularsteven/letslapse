# Guided Clip Builder — designer brief for a UX review

2026-08-12 · Audience: product/UX designer · Prepared from the shipped implementation on `ios-app`
(uncommitted work of 2026-08-11). Priority: **macOS first, iPadOS second, iOS polish third.**

---

## 1. What this feature is

**"Guided clip (experimental)"** is a survey-style flow that builds a finished blended clip —
speed warp plus punch-in reframe — without asking the user to operate a timeline. It sits as a
side-step next to the existing editor: a secondary button on a video project's detail page,
directly under "+ New blended clip". The existing editor ("Adjust", the warp timeline) is
untouched; the builder writes the **same underlying data** (a `WarpTimeline` of stretches and
seams, a `ReframeTrack` of crop keyframes), so anything authored here re-opens in the full
editor intact, and the render pipeline is unchanged.

### Vocabulary the app already speaks (keep it)

| Term | Meaning |
|---|---|
| **Stretch** | A run of footage playing at one speed (×-real-time). A shoot with one slow-motion burst seeds three stretches: fast · slow · fast. |
| **Moment** | A stretch recorded as a high-frame-rate burst — the slow-motion candidate. |
| **Seam** | The joint between two stretches. Owns the speed ramp (step, or an 0.5 s / 1 s / 2 s ease). |
| **Punch** | A crop tighter than full frame (1×–6×), optionally panning from one framing to another across a stretch (Ken Burns). |
| **Canvas** | The clip's output shape: 16:9 · 9:16 · 1:1 · 4:3 · 3:4. |

### The design thesis

Users don't think in keyframes; they think in **states**: "wide and fast → punched-in and slow →
wide and fast again." So framing is a property of a *stretch* (one framing, or a pair for a pan),
and the transition between framings rides the *seam*, welded to the speed ramp that already
lives there. **One duration control governs both** the speed change and the framing move —
there is deliberately no way to time them separately, and no free-floating keyframe anywhere
in this flow. This designs out the entire class of problems catalogued in
`docs/overview-audit-2026-08-10.md` Part C (keys placed in fast stretches rendering as hard
cuts, silent move clamping, near-duplicate keys).

### Non-negotiable product rules (any redesign must keep these)

1. **Exact frames under the framing tool.** The picture a crop is composed on is the frame that
   renders — decoded with zero tolerance — never the ≈-keyframe scrub thumbnail. This was the
   single most damaging defect of the original reframe tool; the builder must not reintroduce it.
2. **One clock on screen.** Durations shown to the user are output (viewer) seconds of the
   finished clip. Source seconds never appear.
3. **The number on screen is the number that renders.** Compiled truth everywhere: per-stretch
   clip shares, "Capped to 0.4 s" when an ease doesn't fit, punch-sharpness at the chosen export
   size. No aspirational figures.
4. **No advanced-keyframe escape hatch inside the survey.** Graduation is "Open in the full
   editor" — same data, the real editor.
5. **Both input worlds are first-class.** Every framing action must be achievable with a mouse
   alone (macOS) and with touch alone (iOS/iPadOS), each in under a minute per framing.
6. Canvas is asked **first** — every framing is composed against that shape.
7. Architect the framing step so an AI-suggested starting box can slot in later (explicitly out
   of scope now, but do not design a layout that has no room for a "suggested framing" seed).

---

## 2. The flow as shipped (iOS reference)

Five kinds of step, in a paged survey with step-dots and a pinned Next CTA. Header: back chevron
(pops one step; exits on the first), title "Guided clip", an EXPERIMENTAL capsule.

1. **Canvas** — "What shape should the clip be?" Ratio chips; consequence caption
   ("9:16 — as shot" / "1:1 — crops to 2160×2160").
2. **Opening stretch** — "How does your clip start?" Speed chips (see below) + framing modes
   (Wide · Punch in · Punch + pan) with a de-emphasis hint: "Usually this stays wide — the
   punch belongs to the moment."
3. **One step per further stretch** — for a moment: "What happens at Moment 1?" Three sections,
   top to bottom:
   - **HOW IT ARRIVES** — seam chips `Step (hard cut) · 0.5s · 1s · 2s ease`, with the weld
     caption and, when the compiled ease is clamped, an honesty note ("Capped to 0.4 s — only
     that much of the 1 s ease fits between these stretches.").
   - **SPEED** — chips gated by what the footage can honour (a 100 fps burst offers ¼×/½×; base
     footage offers the fast end), plus "··· custom". Below: the honest share line
     "Moment 1 becomes ~11 s of the clip." — it moves live as eases eat into the burst.
   - **FRAMING** — mode chips; a pan gets Start framing / End framing switches; then the
     **framing box**: the exact frame, dimmed outside an aspect-locked crop box with eight
     handles, badge "2.0× · 1 080 px", soft warning past a 2× upscale. Input: drag inside to
     position, handles to resize, pinch to zoom (iOS/trackpad), **scroll wheel to zoom on
     macOS** (box-centred), and pan-curve chips (Drift thru · Eased).
4. **Closing stretch** — "How does it end?" The transition chips are always asked; below them a
   default card: "Ends like it starts — Wide · 50× smooth — tap Next to keep it." with a
   "Change…" override revealing the full controls. (Reads "Ends wide" if the opening was
   punched; a shoot that *ends* on a burst gets the moment question instead.)
5. **Review** — "Ready to create". A state list (one row per stretch: kind glyph, speed + word,
   framing summary, ~share) with seam connectors between rows ("1s ease", "step", "plays as
   ~0.4s"). Then the dark estimate card: exact length ("19 s · 3 stretches"), an **export
   resolution menu** (Full — 2160×3840 · 1080 — 1080×1920 · 720 — 720×1280; classes are
   short-edge, oriented to the clip) beside the fps menu, and the sharpness note
   ("Your 2.0× punch keeps ~1080 px — pixel-sharp at 1080×1920."). Below: a quiet
   "Open in the full editor" link, then "Create 19 s clip".

Multi-burst shoots simply get more stretch steps; the step list is seeded from the recording's
own structure, so the survey opens with the right skeleton and only asks speeds, framings,
transitions.

---

## 3. Where the UX critique should aim

### macOS — the priority, and currently the weakest

The hard truth: **the Mac build renders the iPhone layout in a desktop window.** The flow lives
inside the Create tab of a resizable window (760×680 default) and the builder has **no wide
layout at all** — unlike Adjust, which splits into timeline-left / preview-right above 560 pt.
Concretely:

- A single centred column stretches to the window: six speed chips become ~115 pt-wide slabs,
  the Next CTA becomes a ~700 pt orange bar, the question headline floats over acres of grey.
- The **framing box** — the heart of the feature — is a ~180 pt-wide postage stamp for a
  portrait source (fixed 320 pt height), centred in the empty column, below the fold behind a
  scroll. On a desktop this should almost certainly be the dominant pane, not an inline widget.
- **Pointer grammar is minimal.** Scroll-wheel zoom, click-drag and handle-resize work, but
  there are no hover states, no cursor changes over handles/interior (resize vs move), no
  keyboard support (no arrow-key nudge, no numeric punch entry, no Return-for-Next /
  Esc-for-back), no default-button treatment on Next.
- A **wizard is an odd desktop pattern** as a full-tab page. Desktop conventions suggest either
  a steps rail (numbered checklist left, content right — which would also replace the tiny step
  dots), or a two-pane layout where the survey column sits beside a persistent preview/summary,
  or a compact fixed-width sheet-like panel. Note one hard constraint: on macOS this flow lives
  *inside the Create tab* (not a sheet — and mac sheets in this app are never user-resizable by
  decision), so the design should assume a resizable content area from ~700 pt up.
- The **review step** could plausibly be a persistent rail on desktop (always-visible running
  summary + estimate while answering steps), collapsing the "walk to the end to see the
  numbers" pattern that makes sense on a phone.

### iPadOS

Same single column, stretched wider. Adjust already has a proven >560 pt split (timeline left,
320 pt preview/estimate right — see `adjust.reframe.landscape.svg` for the shipped precedent);
the builder should probably follow the same breakpoint rhythm so the two flows feel like one
product. Touch stays primary here, but Pencil hover and keyboard shortcuts are worth specifying.

### iOS — real but smaller scope

- The framing box regularly sits **below the fold** (transition + speed + framing chips push it
  down); there's no auto-scroll or visual cue that the box exists. Composing happens after a
  manual scroll.
- Step dots are small and unlabeled; there's no sense of "step 3 of 5 · Moment 1".
- The EXPERIMENTAL capsule pushes the header title off-centre.
- The de-emphasised "punch on the opening stretch" option and the closing "Change…" pattern
  both deserve a critical look — they work, but the visual hierarchy is improvised.
- No motion preview of the punch path exists anywhere (deliberately out of scope — a separate,
  known effort — but the layout should leave a home for it).

### Honest sub-states worth designing properly (currently plain captions)

- Clamped ease: "Capped to 0.4 s…" (accent-coloured caption under the chips).
- Ease squeezed to nothing: "…it plays as a step."
- Softness warning on the box: "Keeps 823 px of 2 160 — this deep a punch renders soft."
- Export sharpness note on review (positive framing when the punch covers the target).

---

## 4. How to use the SVG specs as reference

The design contract lives in `docs/design/README.md`; per-screen status in
`docs/design/iOS/INDEX.md` (section "Projects & flow") and `docs/design/macOS/INDEX.md`.

Four files mirror the builder **as it ships today** — they are the *baseline to critique*, not
the target:

| File | Shows |
|---|---|
| `iOS/guided-builder.canvas.portrait.svg` | Canvas step + the chrome every step shares (header, EXPERIMENTAL capsule, step dots, Next). |
| `iOS/guided-builder.portrait.svg` | The moment step — seam chips, gated speed chips + honest share line, framing modes, and the framing box with dim/handles/badge. The richest screen. |
| `iOS/guided-builder.closing.portrait.svg` | Transition question + "Ends like it starts" default card with Change…. |
| `iOS/guided-builder.review.portrait.svg` | State list with seam connectors, estimate card with the resolution + fps menus and the sharpness note, Create CTA. |

How to read them:

- Canvas is 393×852 pt (iPhone 16/17 class) inside a drawn device frame; inner coordinates are
  raw screen points. Every region is a named `<g id="…">` matching the Swift member it mirrors.
- **The `<desc>` tag is the behavioural contract** — it names the mirrored Swift members and
  specifies the states deliberately *not* drawn (clamped-ease notes, the softness warning, open
  menu contents, "Ends wide" variant). Read the descs; they are the fastest complete tour of the
  feature's behaviour.
- Design tokens: accent `#C36A00`, amber `#FFB340`, ink `#1C1C1E` (full table in the README).
  Chips, cards and the CTA reuse Adjust's existing components — visual consistency with
  `adjust.portrait.svg` / `adjust.reframe.portrait.svg` is intentional and worth preserving.

**Delivering the redesign:** per the project's design-sync workflow, an edited SVG *is* a spec —
the standard path is design-first: new/edited SVGs, sign-off, then implementation mirrors them.
For a Mac/iPad layout, add a wide-canvas file (precedent: `adjust.reframe.landscape.svg`, one
landscape file standing for iPhone landscape + iPad + Mac) or, if the Mac genuinely diverges,
files under `docs/design/macOS/` — the macOS INDEX currently points the builder at the iOS specs
with mac interaction notes, and that row is explicitly awaiting a real mac design pass.

---

## 5. Reference material

- **Live flow**: `LL_GUIDED=latest` via `simctl launch` opens the newest video project straight
  into the builder (Debug builds). The real entry button is on any video project's detail page.
- **Reference asset**: `~/Library/Application Support/LetsLapse/Projects/E197EC62-…37` — a real
  ~6:40 ramp shoot (25 fps wides, one 100 fps burst of a train arriving) that exercises every
  step; the acceptance test in the original feature brief is built on it.
- **Source**: `App/GuidedBuilderView.swift` (flow), `App/GuidedFramingBox.swift` (framing box +
  exact-frame loader + mac scroll-zoom), `App/GuidedBuilder.swift` (the answers→data planner).
- **Background reading**: `docs/overview-audit-2026-08-10.md` Part C — the catalogue of UX
  failures in the original keyframe editor that this flow exists to design out. Any redesign
  should be checked against that list: if a proposal reintroduces free keyframes, split
  speed/framing timing, or approximate previews under a framing tool, it has gone wrong.

### Ultimate goal, in one paragraph

A person who has never seen a timeline opens their shoot, answers five plain questions, frames
two shots by direct manipulation on exact frames, and gets a clip where the punch-in lands *on*
the slow-motion ramp, the pan drifts across the moment, the punch-out lands on the ramp back
up — with every number they saw (length, shares, ease durations, export sharpness) true of the
file that renders. On a Mac this should feel like a native, professional desktop tool — pointer
and keyboard first, the framing surface generous, the summary always in sight — not a phone
form in a big window. Graduating to the full editor should feel like removing training wheels
from the *same* bicycle.
