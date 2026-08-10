# LetsLapse Design Specs

SVG mirrors of every screen of the Swift app, one file per screen per orientation, organised by platform. They exist so that anyone — human or agent — can see what any screen looks like without building the app or taking screenshots, and so that UI work can happen **on the design files first** and be implemented in code afterwards (or the reverse).

These files are a **contract**, not decoration: whenever the app's UI and these SVGs disagree, one of them is wrong and the mismatch must be resolved as part of the work that caused it.

Viewable directly in Finder (Quick Look), GitHub, VS Code, and any browser.

---

## The design-sync workflow (required for all UI work)

This applies to **all iOS, iPadOS, macOS and watchOS UI work** in this repository.

### 1. Start of any UI task: ask where the work happens

When a human asks for UI work and hasn't said which surface to start on, the agent's first question is:

> "Should we work on the **design files** first, the **app code** first, or something else?"

Three standard answers:

- **Design-first** — iterate on the SVG(s) until the human signs off, then implement the signed-off design in Swift. Cheap to iterate, nothing compiles.
- **App-first** — implement in Swift, verify on simulator/device, get sign-off, then update the SVG(s) to mirror what shipped.
- **"I've already edited the design files — implement this"** — the human changed SVGs themselves. Treat the edited SVG as the spec: diff it against the current code, implement the difference, then (only if needed) tidy the SVG so it matches the conventions below without changing its meaning.

### 2. Sign-off, then mirror

"Sign-off" is the human explicitly approving one side (a design file, or the running app). After sign-off:

- The **other side is updated to match, in the same unit of work** (same commit/PR). A UI change is not done while its mirror is stale.
- Mirroring is mechanical — decisions were made before sign-off and are not re-litigated while mirroring.

### 3. Never let them drift

- Any commit that changes SwiftUI layout, copy, colors, or controls must also update the matching SVG(s) — or say explicitly why no SVG applies (e.g. pure logic change).
- Any commit that changes an SVG as a *spec* (design-first work) should be followed by the implementing commit; the platform `INDEX.md` status column tracks anything intentionally left ahead/behind.
- When discovering an already-stale SVG during unrelated work: note it in the platform `INDEX.md` (status ⚠️ Stale) rather than silently fixing or ignoring it.

### 4. Verifying a mirror

The app has DEBUG launch hooks so simulator screenshots of any screen can be taken without tap automation, for comparing against an SVG:

`LL_LAUNCH=1` (plays the cold-launch build animation — **any other `LL_` hook suppresses it**, so a screenshot run never waits out the ~2.05s assembly; this one forces it back on to capture the launch screen itself) · `LL_TAB` (create|gallery|projects|collections|settings) · `LL_OPEN=latest` · `LL_SEED=<path>` · `LL_DETAIL=latest` · `LL_PUSH=<SettingsDestination>` · `LL_CAPTURE=1` · `LL_BURST=<taken>[/<total>]` (freezes the burst pill — capped fill with a total, zebra without; add `LL_BURST_MODE=interval` for the Interval row; pair with `LL_CAPTURE=1`) · `LL_SPEED=<n>` · `LL_AUTO=process` · `LL_VIEWER=1|expanded` (opens the grading viewer over `LL_DETAIL=latest` — photo capture or interval first frame — with the Customise panel shut or open) · `LL_CUSTOMISE=1` (drops a **video** project's Customise panel open inside its project-detail grading card) · `LL_COLLECTIONS=seed|list|detail` (brings the Collections tab front; seeds two demo collections from existing video blends — no-op if any collection exists or the library has no video blends; `detail` opens the first collection's timeline builder) · `LL_ADJUST=latest|demo` (opens the newest video capture on the Adjust screen's warp timeline; `demo` wraps it in a fabricated two-moment 8:16 sequence so the timeline shows structure without a real burst shoot — screenshots only, don't Create from it) · `LL_STRETCH="1=0.25,3=15"` (with `LL_ADJUST`: pins warp stretch speeds, ×-real-time, by stretch index for variant screenshots)

e.g. `SIMCTL_CHILD_LL_TAB=projects xcrun simctl launch --terminate-running-process <udid> com.regularsteven.letslapse`

The hooks are read from the environment, so pass them with `SIMCTL_CHILD_` prefixes (trailing `simctl launch` arguments become argv, which the app doesn't read).

---

## Folder map & naming

```
docs/design/
  README.md           ← this contract
  iOS/                ← iPhone. <screen>[.<variant>].<orientation>.svg
  iPadOS/             ← iPad. Same naming as iOS.
  macOS/              ← Mac. <screen>.svg (no orientation)
  watchOS/            ← Watch. <screen>[.<variant>].svg (no orientation)
```

- Orientation suffix is `portrait` or `landscape`. Landscape files exist **only where the layout is bespoke** (today: the iOS capture screen's side-rail layout). Screens that merely reflow don't get a landscape file.
- Variants (a screen's meaningfully different states) are part of the filename: `capture-interval.running.portrait.svg`, `project-detail.photo.portrait.svg`.
- Each platform folder has an `INDEX.md`: one row per screen with the file, the Swift view(s) it mirrors, and a sync status (✅ Synced · ⚠️ Stale · 🟡 Planned).

## Canvas & device conventions

| Platform | Canvas (pt) | Reference device | Notes |
|---|---|---|---|
| iOS | 393 × 852 | iPhone 16/17 class | Dynamic Island + home indicator drawn; safe areas 59 top / 34 bottom |
| iPadOS | 820 × 1180 | iPad (10th gen+) | Files pending — folder scaffolded |
| macOS | 760 × 680 window | default `WindowGroup` size | Flow lives inside the Create tab; capture is a ≥960×720 sheet |
| watchOS | 208 × 248 | Apple Watch 46 mm | No orientation |

Inside each SVG the screen's coordinate system is 1 SVG unit = 1 SwiftUI point, so measured positions in the SVG are the spec for the code (± a point or two — see fidelity contract).

Every SVG carries a `<desc>` naming the Swift view(s) it mirrors, and a caption strip under the device frame stating platform · screen · orientation · canvas.

## Design tokens

The palette below is the code's `DesignSystem.swift` (`LL`) rendered to hex. SVGs use these literal values; if `DesignSystem.swift` changes, these files are stale by definition.

| Token | Value | Used for |
|---|---|---|
| `LL.accent` | `#C36A00` | burnt-orange accent: primary buttons, links, selected tab |
| `LL.accentDeep` | `#8A4A00` | pressed/deep accent |
| `LL.amber` | `#FFB340` | highlights over dark: selected chips, dials, progress |
| `LL.ink` | `#1C1C1E` | dark cards (estimate/stack cards), selected speed chip |
| `LL.screenBackground` | `#F2F2F7` | iOS systemGroupedBackground (light) |
| `LL.cardBackground` | `#FFFFFF` | secondarySystemGroupedBackground (light) |
| camera chrome | `#2B2B2E` @ 90% | pills/circle buttons over the viewfinder |
| media pill | `#000000` @ 50% | badges over imagery |
| record red | `#FF3B30` | shutter, REC states |
| confirm green | `#34C759` | saved banners, steady state, toggles |
| secondary text | `#6D6D72` (light) / `#FFFFFF` @ 45–60% (dark) | subtitles, captions |

Type is SF Pro (system). SVGs approximate it with the system font stack; weights and sizes in the SVGs are the spec.

Icons: controls are drawn as simplified glyphs; the **authoritative icon is the SF Symbol named in that element's `data-symbol` attribute** in the SVG.

## Fidelity contract

What these SVGs promise:

- **Structure & hierarchy** — every control, label, card and their arrangement, at true canvas scale in points.
- **Real copy** — the actual strings the app shows (with representative sample data where the app shows data).
- **Real palette** — the token values above, light mode for grouped screens, dark for camera/Watch surfaces.
- **State coverage** — each meaningfully different state is its own variant file or is listed in `INDEX.md` as Planned.

What they deliberately don't promise:

- Pixel-perfect SF Symbol shapes, font rasterisation, blurs/materials (approximated flatly).
- Live data, animations, transitions, scroll positions.
- Dark-mode duplicates of grouped screens (tokens map 1:1; only bespoke dark surfaces are drawn dark).

## Adding a new screen (checklist)

1. Copy the nearest existing SVG in the platform folder as a template (device frame + caption strip).
2. Name it `<screen>[.<variant>].<orientation>.svg`; set `<title>`, `<desc>` (mirrored Swift views), caption text.
3. Draw at 1 unit = 1 pt using the tokens above; tag icon stand-ins with `data-symbol`.
4. Add a row to the platform `INDEX.md` with status.
5. If the screen exists in code already, verify against a simulator screenshot (launch hooks above).
