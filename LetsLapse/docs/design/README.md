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

`LL_LAUNCH=1` (plays the cold-launch build animation — **any other `LL_` hook suppresses it**, so a screenshot run never waits out the ~2.05s assembly; this one forces it back on to capture the launch screen itself) · `LL_TAB` (create|gallery|scans|projects|collections|settings) · `LL_SCANS[=seed]` (brings the **Scans** tab front; `seed` stages the three sessions its list design is drawn from — a finished A4 document, a part-corrected 4×6 set, and a Letter set the detector never found a rectangle in, so all three correction states are real rather than described) · `LL_SCANS_EMPTY=1` (the same tab with nothing in it) · `LL_SCANS_DETAIL=1` (seeds one session — eight A4 pages, rectangles on seven, six corrected — and opens it, which is the mixed state the detail screen's ring, prompt strip and per-tile badges all describe) · `LL_SCANS_CORRECTED=1` (the same set fully corrected, where the prompt strip retires for good). Same reason as the Scanner capture hooks: no simulator can shoot a scan, so the whole tab is unreachable off-device · `LL_OPEN=latest` · `LL_SEED=<path>` · `LL_DETAIL=latest` · `LL_PUSH=<SettingsDestination>` · `LL_CAPTURE=1` · `LL_MODE=photo|interval|video` (opens the capture screen in that mode instead of the last-used one; pair with `LL_CAPTURE=1`) · `LL_HOLYGRAIL=armed|running` (arms Interval's MODE dial on Holy Grail; `running` also freezes a mid-ramp readout — 1.0s · ISO 1250 · RAW, scene EV 1.4, shutter-at-max — which the simulator cannot produce for itself, having no camera to ramp. Implies Interval mode; pair with `LL_CAPTURE=1`) · `LL_SCANNER=settled|disturbed|waitingpage|holding|captured` (arms Interval's MODE dial on **Scanner** — motion-triggered capture, where the camera fires when the scene stops moving — and freezes a running shoot in that state: 12 poses of a 36-angle target, the locked exposure line, the "Delete last" control and the shutter ring filled by *poses banked* rather than elapsed time. The first two are the **motion** trigger, which PAPER = Auto selects: `settled` is its resting state ("Waiting for you to move", green) and `disturbed` is mid-settle ("Settling…", amber). The last three are the **rectangle** trigger, which a named stock selects and which asks a different question entirely — is there a page, and is it holding still? — so it has its own vocabulary: `waitingpage` ("Waiting for a page", amber, nothing flat in view), `holding` ("Settling…" over the amber hold bar, a page found and its window part-filled) and `captured` ("Ready for the next page", green, this page banked until it is swapped). The hook stages A4 for those three, since the stock is what chooses the trigger. Same reason as the hooks either side of it, twice over — the simulator has no camera to difference frames from and no scene to disturb, so neither state is reachable off-device. Any other value (e.g. `LL_SCANNER=1`) arms the dial without staging a run, which is how the idle Scanner row is screenshotted. Implies Interval mode; pair with `LL_CAPTURE=1`) · `LL_SCANNER_RECT=detected|none` (freezes Scanner's **rectangle overlay** — the quad the detector found, traced over the live image, with the matching `doc.viewfinder` glyph in the HUD. `detected` stages a plausible keystoned page; `none` (or leaving it unset) draws nothing, which is the fallback state the other two Scanner variants show. Arms Scanner on its own, so it can be used with or without `LL_SCANNER`; the corners it stages are the ones the SVG is drawn from. The reason is the same one twice over: the simulator has no camera, so Vision has nothing to find a rectangle in and the overlay is unreachable off-device. Pair with `LL_CAPTURE=1`) · `LL_FORMAT=1` (opens the Capture format sheet on appear, two seconds in so its lists are the capability matrix's answers rather than the seed values; pair with `LL_CAPTURE=1`) · `LL_CAMERA=<name substring>` (**macOS**: switches to that camera three seconds in, driving the same path the Camera menu drives — logs the roster if nothing matches; pair with `LL_CAPTURE=1`) · `LL_BURST=<taken>[/<total>]` (freezes the burst pill — capped fill with a total, zebra without; add `LL_BURST_MODE=interval` for the Interval row; pair with `LL_CAPTURE=1`) · `LL_FOCUS=1` (freezes a tap-to-focus reticle at the viewfinder's own (196.5, 385); `LL_FOCUS=x,y` places it elsewhere in viewfinder points. Same reason as the burst hook — the simulator has no camera, so a real tap is refused before it can draw one. Pair with `LL_CAPTURE=1`) · `LL_RECORDING=1` (freezes a Video shoot mid-take — recording pill, speed marquee and segment strip with its burst spans — in either orientation; `LL_RECORDING=<seconds>` sets the elapsed take, and `LL_RECORDING=<seconds>:<a>-<b>,<c>-` spells the burst spans out in seconds from the start, a trailing `-` meaning a burst still open. Same reason again — `startRecording` never lands without a camera, so the whole recording readout is otherwise unreachable off-device. Staged two seconds in, past the sequence-counter reset `camera.start()` posts. Pair with `LL_CAPTURE=1`) · `LL_SPEED=<n>` · `LL_AUTO=process` · `LL_KEYFRAMES=sunset|empty` (stages the **grade timeline** — the keyframed-editing strip between the media and the controls — inside whichever editor `LL_VIEWER` opened. `sunset` writes the design pass's own scenario: three graded moments at 10%, 52% and 86% of the source with the playhead between the first two, which is what `project-photo.viewer.keyframes.*.svg` draw. `empty` is the first-run state, the strip with nothing on it. Neither is reachable by automation — making them for real means scrubbing a two-hour shoot and dragging sliders at three separate moments — and the `sunset` values are the ones the SVGs are measured from. Works in the video editor too, over the movie's own clock; pair with `LL_VIEWER=1`) · `LL_VIEWER=1|expanded` (opens the grading viewer over `LL_DETAIL=latest` — photo capture or interval first frame — with the Customise panel shut or open) · `LL_CUSTOMISE=1` (drops a **video** project's Customise panel open inside its project-detail grading card) · `LL_COLLECTIONS=seed|list|detail` (brings the Collections tab front; seeds two demo collections from existing video blends — no-op if any collection exists or the library has no video blends; `detail` opens the first collection's timeline builder) · `LL_ADJUST=latest|demo` (opens the newest video capture on the Adjust screen's warp timeline; `demo` wraps it in a fabricated two-moment 8:16 sequence so the timeline shows structure without a real burst shoot — screenshots only, don't Create from it) · `LL_SCANS_AUTOCORRECT[=<pages>]` (stages the state a finished scan actually opens in: a fresh, uncorrected session pushed through the **real** post-capture route — `AppModel.requestedScanDetailID` → the Scans tab → the session — with the automatic perspective pass running over it, so the header counts "Correcting 26 of 40 pages…" and the tiles rectify one at a time. Defaults to 8 pages, which finish almost instantly; pass a larger count to catch the progress in a screenshot) · `LL_SCANS_DELETED[=<page>]` (a corrected eight-page set with one page thrown away — the state the numbering rule exists for, since the pages that remain **keep their numbers**: a set missing its third reads 1, 2, 4…8 rather than closing up. Reachable in the app only through a long-press and a confirmation) · `LL_PROJECT_SCANNER[=<poses>|corrected]` (fabricates a finished **Scanner** shoot — numbered stills plus the `frames.timestamps` a real run writes, in through the real registration path — and opens its project on the Scanner result screen (`App/ScannerProjectView.swift`). Same reason as the Scanner capture hooks, one step further downstream: no simulator can shoot a Scanner set, so the screen that presents a finished one is otherwise unreachable. Defaults to 12 poses; `corrected` stages 12 with their rectified pages already written, which is the screen's other state — the Correct-perspective button retires and every tile with corners carries its badge) · `LL_IMPORT=checking|extracting|installing|duplicate|failed` (freezes the project-import sheet in one phase — a real 2.4 GB import finishes in about two seconds on an M-series Mac, far too quick to screenshot) · `LL_STRETCH="1=0.25,3=15"` (with `LL_ADJUST`: pins warp stretch speeds, ×-real-time, by stretch index for variant screenshots)

e.g. `SIMCTL_CHILD_LL_TAB=projects xcrun simctl launch --terminate-running-process <udid> com.regularsteven.letslapse`

The **Camera Remote** has its own hook, `LL_UI_PREVIEW=<screen>` (screens listed in `watchOS/INDEX.md`), which stages a shoot so the remote's screens can be captured without a paired camera actually shooting one. It runs on macOS as well as watchOS now, and on the Mac the preview hook also opens the remote window — it is otherwise behind ⌘⇧R, which no headless run can press:

`LL_UI_PREVIEW=scanner /path/to/LetsLapse.app/Contents/MacOS/LetsLapse`

`LL_REMOTE_CONNECT=<6-digit code>` instead dials a **real** camera and opens the window on it — the code still has to be the one on the camera's screen, so it types rather than bypasses. Use it to check the Mac against a live iPad rather than against staged state.

The iPad side has three DEBUG tuning hooks for Scanner, read from `UserDefaults` so they can arrive as launch arguments (`devicectl … launch … -- -scanner.motionThreshold 0.008 -scanner.settleDelay 0.6 -scanner.cornerThreshold 0.01`). With them, `CameraController` logs `scanner: mag=… rect=…` at 1 Hz — which is how the noise floor quoted in `ScannerEngine.defaultMotionThreshold` was measured. `tools/remote_probe <code> "<script>"` drives the whole wire contract headlessly and prints the same payload the Mac remote renders.

Note the Mac needs the binary invoked directly; `open -n` does not forward the environment. Per `Remote/RemoteWindow.swift` a Mac screenshot verifies the **wiring** only — no watchOS spec may be marked ✅ from one.

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

**The remote is the one exception, and it is deliberate.** The watchOS specs (and the macOS remote window, which
shares their view) draw from `Remote/RemoteTokens.swift`, not from `LL`. Two reasons: `App/DesignSystem.swift` is not
in the watch target at all, and a watch face is exactly the "bespoke dark surface" the fidelity contract below carves
out — its job is legibility at arm's length on a tripod, not consistency with a grouped light screen. If
`RemoteTokens.swift` changes, every file in `watchOS/` is stale by definition, the same way `DesignSystem.swift`
governs the rest.

| `RemoteTint` | Value | Used for |
|---|---|---|
| `record` | `#FF453A` | recording, and the stop commit |
| `burst` | `#FFD60A` | burst — the high-rate segment and the controls that reach it |
| `link` | `#40C8E0` | the link itself: connection, information, read-outs |
| `go` | `#30D158` | armed, and level |
| `warn` | `#FF9F0A` | a busy phone, a send that did not land |
| `surface` / `surfaceRaised` / `surfaceTrack` | `#1C1C1E` / `#2C2C2E` / `#39393D` | rows, chips, toggle tracks |

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
