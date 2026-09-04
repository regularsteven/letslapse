# Text reveals, sequencing and rich copy — build report

2026-09-03 · macOS / iPadOS / iPhone editor · built from the Claude Design
handoff **Photo viewer text transitions** (`Text Workflow.dc.html`,
`Text Workflow iOS.dc.html`; direction **1a**, timing lives in the rail).
The Text Features build ([text-features.md](text-features.md)) had left a
layer with one reveal — a character fade or slide over a band — and no way
out, no way to follow another layer, and one style per layer. This build
adds what a titled time-lapse needs, and keeps **Intelligent Placement**
and the reveal **animation** exactly where they were: both are mandatory,
and the design assumed them.

## What the design asked for, and what shipped

| Design | Shipped |
| --- | --- |
| Reveal in and reveal out, each with a unit and a style | `OverlayAnimation` = `reveal` + `exit?` + `follows?`; `OverlayReveal` carries unit (Element · Word · Character), style (Fade · Slide · Bounce · Pop · Blur · Wipe, or nil = hard cut), direction, band and stagger. Exit styles exclude Bounce. |
| Sequencing: a layer starts after another with an offset | `OverlayFollow` (parent id + gap); `OverlayDocument.resolveFollows()` runs after every edit, as many passes as layers, drops dangling and cyclic links, and the After-layer picker refuses a layer's own descendants. |
| Lanes under the strip | `OverlayLanesView`: one band per layer with reveal heads, trim handles, body drag, link discs and dotted connectors; aligned to `GradeTimelineView.leadInset` and the frame-step trail. Mac 18pt lanes, iPhone 15pt. |
| Rich copy | `TextOverlayContent.runs: [TextRun]`; typed text inherits the run it lands at the end of, runs merge when they match; `applyStyle(in:)` splits at any character range. Mac: an ink toolbar under the copy field for the caret's word or the selection. iOS: the keyboard accessory bar. |
| Font import | `OverlayFontStore` + `fonts/` (in `ProjectArchive.transferableSubfolders`); registered per process at editor open and before every export bake; IMPORTED tag in the picker. |
| Live playback | `togglePlayback` loops and runs at the newest blended clip's output length (14 s tour before one exists). |
| Layer ID | `SceneOverlay.label`; `displayName` feeds the row, the picker, the gutter and toasts. |

## Traps worth keeping

- **`TextSelection` is the only caret read-back SwiftUI has, and it is
  iOS 18 / macOS 15.** `OverlayCopyField` uses it under `#available` and
  falls back to a plain field on the 17/14 floors, where the toolbar's
  controls act on the whole layer. A caret placed by the click that gives
  the field focus arrives *before* the focus state does — the target must
  be kept regardless of focus, keyed by the layer that reported it, or the
  toolbar never opens.
- **A synthetic System Events click does not focus a SwiftUI text field**
  when another window of the same app is key — and `LL_EDITOR` on macOS
  opens the editor window two or three times (each hook route opens one).
  Real HID events (`CGEvent` mouse down/up, `scratchpad/harness/hidclick`)
  into a window raised by `AXRaise` do; the driver's clicks stay fine for
  buttons and chevrons.
- **`.toolbar(placement: .keyboard)` never appeared inside the editor's
  full-screen cover**, including the Done bar shipped 2026-08-31. The bar is
  now drawn by the editor itself over the whole cover; the cover's safe
  area already rises with the keyboard, so adding a measured keyboard
  height on top doubled it (measured: the bar sat 674pt up). And because
  the stacked layout gives the media every point it asks for, the keyboard
  used to leave the scroll view with no height at all — the field being
  typed into was the part that vanished. While a copy field is focused the
  media collapses to its floor, the lanes and grabber step aside, and the
  card scrolls to the top of what is left.
- **AppKit drops a SwiftUI `Menu` label's chrome** (known from the Light
  Ladder work) — the font and parent pickers are popover lists, which is
  also what the mock draws.
- **Overlapping character ranges must be checked before `Range` is
  built.** The run editor's first version constructed
  `max(a,c)..<min(b,d)` for every run and trapped on the empty case; the
  standalone harness caught it on the second test.
- **The still bake must ignore exits.** A whole-shoot stack composites at
  position 1, where a layer with a reveal out has already left;
  `SceneAwareCompositor.composited(settled:)` draws every layer at rest for
  `bakeStill`.
- **Blur is a Core Image pass per unit.** A word or element is one pass;
  a 30-character line mid-reveal is thirty small blurs per frame. Fine for
  the preview and short exit bands; measure before a blur-heavy title on a
  4000 px export.
- **`LL_TEXT=story` stages only onto an empty project.** The 2 s persist
  safety net writes the staging into the sidecar; on a project with real
  layers it would overwrite them.

## Verification

macOS, against the running app (dark appearance on the bench; the design
and its SVG are the light window): the four-layer staging with lanes;
expanding a card through TEXT / TYPE / REVEAL IN / REVEAL OUT / ID; a real
HID click into the copy field on "you", the toolbar naming “youZZ” after
typing, **B** off and **Amber** applied to that run alone (the composite
showed "youZZ" amber and regular inside a bold white line); the font
popover with faces in their own type and the Import row; Prague's card
reading *Starts: After layer · ⤷ Intro top · +0s*; a HID drag of Prague's
band moving it, breaking its link (*At time*, no capsule) and re-seating
its two children behind it; live looping playback sweeping the story past
the playhead. iPhone 16 Pro simulator on a 60-frame import: the stacked
layout with lanes, the expanded card, the typing layout and the accessory
bar above the keyboard. Standalone model harness (`swiftc` over
`SceneOverlay.swift` with a two-type shim): 52 checks, all passing — run
editing, units, phases, moments, legacy and round-trip decoding, follow
resolution incl. chains in the wrong list order, cycles, dangling links and
parent removal. Not done: a physical device, an export with reveals (the
bake shares the compositor and rasterizer with the preview, so the gap is
the CI blur's cost at full resolution), and a light-appearance Mac capture.

## The first-run crash, and the tests that came out of it (2026-09-04)

Steven's first Mac test run trapped on the first keystrokes into a new
layer: *Fatal error: String index is out of bounds*. Reproduced with real
input; the crash report puts the trap in SwiftUI itself —
`PlatformTextFieldCoordinator.update()` → `NSTextView.setTextSelection` →
`NSRange(_:in:)` — re-applying the selection the field still held for the
old, longer text ("Your text", all selected) to the one-character text that
had replaced it. Our side never touched a stale index; our binding did.

**Fix:** the copy field's text setter re-seats the selection at the caret
the edit leaves behind (`TextOverlayContent.caretAfterEdit`, an offset into
the *new* text) before the text changes, so whatever SwiftUI pushes back is
valid — and the run toolbar keeps tracking the word being typed. The
field's caret-to-offset mapping moved into the Kit as well and clamps both
ends before measuring (`characterRange(of:in:)`, `styleTarget(for:in:)`).

**Tests, two layers:**

- The whole text model now lives in the Kit
  (`Kit/Sources/LetsLapseKit/TextOverlayModel.swift`) and is covered by
  `TextOverlayModelTests` under `swift test` / `driver.py test` — runs and
  their editing (including select-all-and-type over the placeholder,
  emptying, emoji and combining marks, out-of-range replaces), the caret
  helpers with indices taken from an older longer string, units, phases,
  moments, legacy and round-trip decoding, and sequencing
  (`OverlaySequencing`, which `OverlayDocument` now delegates to). Moving
  it caught a second bug: leading whitespace was a reveal unit of its own,
  so a line starting with a space would reveal a blank first.
- `driver.py smoke text-field --project <uuid>` types the gesture into the
  running Mac app (accessibility focus, NSWorkspace activation, System
  Events keystrokes behind a keyboard-focus guard) and reads the persisted
  sidecar back — the app being alive is not enough. **It does not
  reproduce the trap**: an unfixed build passes it, because SwiftUI's own
  selection binding only holds the old range after a real mouse click into
  the field, and that click could not be delivered from the bench once
  CGEvent posting stopped arriving mid-session. The crash gesture itself is
  a ten-second hands-on check (add a layer, click the field, ⌘A, type); an
  XCUITest target would be its proper home and the project has none today.
  The fix is verified by the crash report's frame and by real typing into
  the fixed field surviving every replacement.

## Design mirrors

`docs/design/macOS/photo-viewer.text.svg` rebuilt for the new tab;
`docs/design/iOS/project-photo.viewer.text.portrait.svg` new (the first iOS
viewer file drawn in the shipped dark idiom); INDEX rows in both folders
and a note in iPadOS. `README.md`'s hook list gained `LL_TEXT`.
