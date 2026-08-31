# LetsLapse — open jobs

The queue of work that has been scoped but not done. One entry per job: what it
is, why it matters, and where the detail lives. A job leaves this list when it
ships, not when it is started.

Long jobs get their own document and are referenced from here. Short ones can
live inline.

---

## Open

### Text overlays: export baking (overlays render in the editor, vanish from every export)

**Detail:** [text-overlay-spike.md](text-overlay-spike.md) · **Raised:** 2026-08-31, out of the spike

The spike composites overlays only in `PhotoViewerView`'s preview. Baking
them into exports means the same `SceneAwareCompositor` call at
`PhotoPreset.engineRender` (stills/JPEG), `ImageStacker.stackSequenceLinear`
:523 (blended clips, resolving animation position through `GradeSourceMap`
like keyframed grades), and the `VideoGrader`-family composition handlers —
AND teaching `willBakeGrade` / `hasTailPass` / the `grade.isKeyframed` map
gate that overlays are a second reason to run a pass. Until then an overlay
on an ungraded project previews fine and exports without it.

### Text overlays: productization follow-ups from the spike

**Detail:** [text-overlay-spike.md](text-overlay-spike.md) · **Raised:** 2026-08-31

The recorded remainder, roughly in value order: VideoEditorView overlay
rendering (its Text tab is an honest placeholder); promote `overlays.json`
into a `CaptureProject` field (or add `"overlays"` to
`ProjectArchive.transferableSubfolders`) so text travels in `.lapse`
archives and device transfers; iOS pass (stacked-layout tab bar compiled but
unverified, touch drag ergonomics); detail-patch/loupe render without
overlays (pixel-peep shows no text; `PhotoDetailFocus` scans the composited
preview so the loupe can point at text); SceneMasks folder on the storage
card's clear-cache path; draggable range-band handles; SegFormer-B0 ADE20K
conversion for true sky probabilities (DETR is 0/1 argmax).

### Design mirrors for the tabbed editor rail

**Raised:** 2026-08-31, out of the text-overlay spike (code-first agreed, SVGs deferred)

The `[Editor | Text | Frames]` rail refactor stales the six iOS viewer SVGs
(`project-photo.viewer.*.svg` family) and the macOS Edit window still has no
spec at all (`macOS/photo-viewer.svg` remains an INDEX aspiration). Mirror
whatever survives productization; the Text tab's panel (placement segments,
mask dials, Set Start/End) needs drawing for the first time.

### iOS tab host still folds tabs 5+ into UIKit's invisible "More" controller

**Raised:** 2026-08-30, while fixing the Collections phantom back button

The six-tab `TabView` makes UITabBarController fold Collections and Settings
into its legacy `UIMoreNavigationController` on iPhone — the system tab bar is
hidden, but the fold still happens. Its glass bar floated a phantom back
button over both tabs and pushed their content down a bar's height;
`hiddenMoreNavigationBar()` (`App/LetsLapseApp.swift`) now hides that bar and
disables its pop gesture with public API. The fold itself remains: folded
tabs live inside a navigation controller nobody asked for, one UIKit
behavior change away from a new artifact. The durable shape is the macOS
pattern — a ZStack + `switch selectedTab` (only the selected tab mounted,
paths already hoisted to ContentView) — at the cost of unhoisted per-tab
@State (Projects' filter/search text) resetting on tab switches, which is
what to weigh before doing it.

### Collections wide layout: bottom Add/Export row collides with the floating tab bar on iPad

**Raised:** 2026-08-30 (pre-existing; seen while verifying the up-the-fold rework)

`CollectionDetailView.wideLayout` pins "+ Add clips | Export collection" to
the bottom of the right column with 10pt of clearance. On iPad the floating
tab bar pill is wide enough to sit on top of the Add button (Export, further
right, stays clear). Needs tab-bar clearance like the portrait layout's
140pt spacer — or the row moved above the pill's band.

### Tall clips still own the whole portrait fold in the collection builder

**Raised:** 2026-08-30, out of the up-the-fold rework

A 9:16 clip in portrait fills the screen width by design ("never letterboxed
by default"), which at ~630pt tall pushes the caption row and timeline below
the fold — the one case the 2026-08-30 rework doesn't rescue. The "Apply
letterbox" pill already shrinks it to 240pt on demand. Decide whether tall
clips should default to the letterboxed preview (or a ~340pt cap) inside the
collection builder specifically; that reverses a deliberate v1 choice, so it
is Steven's call, not a drive-by.

### Render progress publishing storm — UI staggers during any render

**Detail:** [perf-audit-2026-08-29.md](perf-audit-2026-08-29.md) (finding A +
ranked fixes P1) · **Raised:** 2026-08-29

Every render publishes per-frame progress through `@Published` state on
`AppModel` itself, so each engine tick re-evaluates the whole mounted view
tree — plus an app-root `.onChange(of: model.progress)` and, on macOS, a
whole-log-file re-read per emit. Fix at the sink (5–10 Hz gate), move run
progress off `AppModel` onto a processing-only observable, ring-buffer the Mac
job log tail, and throttle the `ImageStacker`/`TimeSliceRenderer` emitters.

### Editor sliders unusable on big interval shoots — O(frames) body work + per-settle library persist

**Detail:** [editor-performance-plan.md](editor-performance-plan.md) ·
**Raised:** 2026-08-29 · **Stages 0–3 landed same day — Mac bench 4.8 →
58.4 ticks/s; on-device A/B on the iPhone 16 Pro (real 260-capture library,
1,250-frame shoot): 0.2 → 57.7 ticks/s, ~290×. The sibling audit's 10 Hz
progress gate landed with it after the 16 Pro recording of a blend start
freezing transitions for ~a minute. Same evening, the processing-flow pass
landed off that recording (plan doc header): hero-once-per-run,
`ProcessingProgressModel` (sibling P1.2), `source(for:)` existence tickets,
blend orchestration off the main actor + `.utility` workers — Mac A/B: main
thread during a live blend 100% busy → 6%; 16 Pro A/B (2026-08-30, real
1,249-frame shoot): main-thread share 15% → 3.4%, biased against the fix
(the before window missed the launch wedge). Fixed build installed on the
16 Pro. Owed: Steven's feel-check of the recorded flow + Cancel, iPad/12
Pro installs, stages 4–6, uncommitted.**

Grading sliders miss touch-downs and catch up seconds late on every device
(iPad M3 included — the mechanisms scale with shoot length and library size,
not silicon; photo-mode stills are unaffected). Six ranked mechanisms, the
top two measured: the editor rebuilds the full frame-URL list ~a dozen times
per slider tick on the main thread (10.9 ms/call at 1,480 frames, measured),
and every 100 ms debounce settle JSON-encodes the whole library on the main
actor, clears every project's size cache, and invalidates the entire mounted
view tree — which also fires a second hidden 1400 px render of the same grade
behind the cover and a per-frame `fileExists` storm in list bodies (the same
hot stack the sibling audit's 12 Pro trace caught). Plus: ~60 MB of Metal
scratch allocated per preview render (`restage()` unused by previews),
zombie renders holding the shared 4-wide media queue, RAW-decode-per-step
scrubbing, and the video editor swapping a fresh `AVVideoComposition` per
settle. Fix is staged Mac-first in the plan doc (seeded 1,480-frame bench +
AX-driven drags + Time Profiler gates); everything is shared code, so iOS
gets each win for free. Sibling: the render-progress storm entry above —
stage 6 coordinates both on the structural `@Observable` question.

### Standalone phone↔iPad transfer — make the pairing work without a Mac

**Detail:** [perf-audit-2026-08-29.md](perf-audit-2026-08-29.md) (findings
B–D, both measured runs, the on-device profile) · **Raised:** 2026-08-29
after a 5.1 GB iPhone 12 Pro → iPad pull ran hot, thermally stalled, and died
at 4.6 GB with `NWError 60`, discarding the staged tree. The Mac relay is a
bench workaround only — the iPad exists to remove the Mac dependency, so the
radio path itself is the product surface.

Measured basis: same phone/project did 12.6 MB/s over USB (thermal ≤2) vs
7.4→1.3 MB/s over Wi-Fi (thermal critical in 3 min), ack window pinned full
both times — the radio path is the bottleneck and the heater. The data
connection is already infrastructure-only; the AWDL duty is the *three*
side-radios (client browser scanning + both idle listeners advertising).

- **Phase A (started 2026-08-29):** negotiated-interface logging on both
  ends, client browse pause during pulls, both idle listeners withdraw their
  Bonjour advert while a transfer is in flight
  (`llProjectTransferPullState`), keep-awake on both roles, per-file progress
  emit throttled. Acceptance test: the same 5.09 GB pull, instrumented.
- **Phase B — resume (plan §4):** `have` set on `requestTransfer`, keep
  partials on failure, auto-reconnect; turns a dropped hour-long pull into a
  30-second reconnect. Friendlier failure copy than raw `NWError 60`.
- **Phase D — direct peer-to-peer (started 2026-08-29):** the field case was
  broken by one missing flag — discovery was P2P-capable but `PTLink`'s data
  connection never set `includePeerToPeer`, so two devices with no shared
  network would find each other and hang at pairing forever. Flag added; the
  `via …` log names the winning path (`awdl0` = direct). Field validation
  pending (cross-SSID bench test = a no-router simulation). Later: consider a
  "direct connection" affordance if the framework prefers a bad AP over a
  good AWDL path in practice. Same gap likely exists in the camera remote's
  `LocalNetworkTransport.connect` — audit separately.
- **Learned on the bench (2026-08-29 evening):** thermal was the *casualty*,
  not the cause — a cool-pack run at thermal 0 crawled at the same 1 MB/s.
  The home network is 2.4 GHz ch11/20 MHz ("blanickaback"), and an
  infra transfer crosses that channel twice; single-digit-Mbit reality. The
  fast run was USB (wiredEthernet), never Wi-Fi.
- **Phase C:** serving-side UI churn (sharing chip out of ProjectsView's
  observation, catalogue-walk TTL), screen-dim during transfers (design
  pass: thermal/interface/rate readout in both transfer UIs), and the
  `cleanUpOnDisappear`-never-stops-the-camera backstop.

Open questions for the next instrumented run: infra band/RSSI vs yesterday,
charging-heat contribution (both measured runs were cabled = charging), and
whether advert-quiet alone recovers most of the rate.

### Time slicing — the time gradient that scrolls across the frame

**Detail:** [time-slicing.md](time-slicing.md) · **Raised:** 2026-08-28 ·
**Stages 1–4 landed 2026-08-28 (engine, orchestration, verifier, Adjust UI),
plus the same-day first-output review round (plan §7a) — UI sign-off + SVG
mirrors, the stage-5 processing loader, then feathered edges (promoted) open**

*Review round: reading order flipped to earliest-first (default
`newestEdge` .right/.bottom, UI control "Time starts"); the primary temporal
control became **Spread as % of the clip** (seeded ~25%, amber under 5%,
frames stay the stored recipe via exact two-way `TimeSliceGeometry`
mapping); the "1/10-resolution animation" and "units bug" findings dissolved
on probing — the registered files are full 12 MP and the sampler shifted
exactly the commanded 30 frames (the reviewed .mov was a transcode; the
sub-frame lag was luma-measurement degeneracy, which also forced an
overlap-floor + first-difference fix into `timeslice_report.py`).*

*Stage 3 E2E on the real Mac library: one headless Create
(`LL_ADJUST=stills LL_TIMESLICE="segs:8,lag:3,…" LL_ADJUST_CREATE=1`)
registered three blends on the newest dawn shoot — regular clip (no recipe),
329-frame sliced animation (350 − the 21-frame spread, exact) and poster,
both recipe-carrying and recipe-named. `slicing` phase + progress band,
`openBlend` rehydration, Cancel bridged to the renderer. Mirror debt for the
sliced rows' project-detail copy rides stage 4's design pass.*

*Landed: `TimeSlice.swift` + `TimeSliceRenderer.swift` in the Kit (25 tests,
all numeric — bands measured against the commanded master frames), `lapse
slice` in the CLI, `tools/timeslice_report.py` (independent ladder
measurement — `TIMESLICE PASS` at exact commanded slope on rendered slices,
INCONCLUSIVE by design on flat scenes). Real-footage E2E: the 1,587-frame
12 MP "Blended 10 long" blend sliced in 72.6 s at 265 MB peak — flat memory
measured true against a ~1.1 GB cycling spool. One real trap re-found:
`FileHandle.read`'s autoreleased Data made the spool loop's memory track
bytes read 1:1 — the transfer pump's exact bug — fixed with a per-frame
autoreleasepool. No iOS anything touched, per the sequencing decision.*

Partition the output frame into N bands, each sampling a different point on
the source timeline (per-band frame lags), so a sunrise travels across the
frame during playback; the single-frame variant is the whole-day-in-one-photo
poster. Interval and Video shoots, inside `+ New blended clip`. The plan doc
answers the brief's seven open questions from the code and overrides the brief
twice, both load-bearing: the §4.7 "bands not frames = one frame of memory"
claim is wrong for the animation (true only for the poster — the honest floor
is ~half the spread, so the design is a banded ring-file spool on disk with
flat RAM), and stage 1.5 moves from a pre-encoder tap to the **last tail pass
over the finished blended clip** — the only point where every engine converges
on uniform, final-geometry, grade-baked frames (mixed-resolution ramp shoots
are per-segment sized at the tap; the Mac runner blends out of order). That
placement also makes the parked "re-slice an existing blended clip" path the
same code minus UI, and dissolves the burst-resolution-straddling question.
Sliced outputs register as ordinary `BlendProject`s (animation `.video`,
poster `.image`), so archive/transfer/storage/delete are inherited with zero
allowlist changes. Sequencing decided 2026-08-28: **build first, macOS first**
— engine stages verified through Kit tests, a new `lapse slice` subcommand and
the Mac app, no iOS simulators downloaded for this job; UI later, code-first.
Display names carry the recipe (`timeslice-vert-left-segs_24-lag_2`; width
auto-calculated). All seven brief questions answered 2026-08-28 (offsets in
frames · trim · full-source PNG poster · master resolution, no upscaling ·
frame-space ramps), and the Adjust preview became the **§6a processing
loader**: every blend run's Processing hero builds up band by band — a real
full-source time slice of the shoot at the output's aspect, bands jumping in
with progress — with the checklist card moved above Cancel and the cancel
caption removed. Still open (plan §9): whether the throwaway master forces
`hevcMain10` when "Include regular timelapse" is off.

### Import a project from another device (local network)

**Detail:** [project-transfer-plan.md](project-transfer-plan.md) ·
**Raised:** 2026-08-27 · **Phases 1–3 landed, all uncommitted** ·
*revised 2026-08-27 — payload strategy, resume, AirDrop/USB*

**Phase 3 landed 2026-08-28 — every direction now works.** `ProjectTransferServer`
widened to `#if !os(watchOS)`, so a Mac offers its library through the same
listener, the same chip in the same Projects header, and the same Settings ▸
Advanced opt-in. Device identity is `Host.current().localizedName` on macOS
(`UIDevice` on iOS) and the model string picks the picker's glyph.

**The one genuinely different piece is the stand-down.** iOS gets one free —
the app backgrounds and the listener stops — but a Mac scene never backgrounds,
so an armed Mac would advertise its whole library until the app quit. The rule
is `ProjectTransferServer.idleTimeout`: 15 minutes with nobody connected and it
stops itself, the clock reset by anything meaning a human is still present
(arming, a peer connecting, a transfer finishing). It applies on iOS too — a
good second rule there, just not the only one.

**Verified 2026-08-28, iPad Air M3 ← this Mac:** "Blended 10 long" — 5.91 GB,
1,588 source files plus its blended clip — installed into the iPad's library.
Peak serving footprint 223 MB, ack window bounded at 33 MB.

**Serving throughput on a Mac is bounded by wherever the library lives**, and
this was demonstrated the hard way: on the old USB drive (**692 KB/s raw**) the
pump managed 0.7 MB/s with its window sitting at 1–6 MB of 32 — starved by disk,
not throttled by protocol. On the SSD that replaced it the window runs full
(27–33 MB) and the bottleneck moves to the receiving device's Wi-Fi. Worth
knowing before anyone reads a slow Mac→iOS transfer as a network problem: check
the window depth first — low means disk, full means wire.

**Phase 2 landed 2026-08-28.** The import client is now every platform that has
a library, not just the Mac: `ProjectTransferClient` widened to
`#if !os(watchOS)`, and the whole flow moved into one shared
`App/ProjectTransferImportView.swift` that macOS hosts in its `Window` and iOS
and iPadOS present as a sheet. Create's **"Import a LetsLapse project…"** row is
now the single door on both platforms — it asks *From a file…* or *From another
device…*, which keeps `.lapse` import where it has always been and gives the
network path a home that isn't a menu bar. Also in: a free-space refusal checked
before a byte moves (and flagged on the project row itself, which matters far
more on a 128 GB phone than on a Mac), and `LL_TRANSFER` as an iOS launch hook.

**Verified 2026-08-28, iPad Air M3 ← iPhone 12 Pro over Wi-Fi:** "Long psycho
i12", 7.33 GB across 2,869 files, installed into the iPad's library with
`Incoming/` swept clean afterwards; the serving phone's footprint peaked at
78 MB and the ack window never exceeded 28 MB against its 32 MB bound.
Throughput ranged 14 MB/s down to 1 MB/s and back as Wi-Fi and the 12 Pro's
thermals varied — flat memory throughout, so that is the wire, not the engine.

**Mac→iOS is Phase 3 above, and now works.**

**What Phase 1 shipped**, verified end to end (a project moved simulator→Mac
and every file matched the manifest byte for byte, and again through the real
Import window): `AppModel.LibraryActivity` and all its registration sites ·
`Shared/ProjectTransferProtocol.swift` (typed 1+4-byte framing, control /
data / cancel) · `ProjectTransferServer` (iOS) · `ProjectTransferClient` +
`Remote/ImportWindow.swift` (macOS) · `"Incoming"` in `libraryItemNames` ·
`ProjectArchive.transferableSubfolders` · the `importProject` split into
`installStagedProject` · `tools/transfer_probe.swift` · the SVG mirrors.

**Two deliberate departures from this plan, both narrowing:** the service is
`_letslapse-xfer._tcp` and the salt `…transfer.v1` (the plan says
`_letslapse-library._tcp` / `…library.v1`); and **`requestTransfer` carries no
`have` set, so there is no resume** — a dropped pull discards its partial tree
rather than stranding gigabytes nobody can spend. Resume is §4 and needs the
vocabulary to grow the `have` list; `Incoming/` already has the right shape,
the right home and the 24-hour launch sweep for it.

**Device-verified 2026-08-27 on the iPhone 16 Pro over USB:** an 11 GB project
(612 files) moved byte-for-byte in 267 s at 41 MB/s with the app's peak
footprint at **90 MB**; a client killed at 25% aborts the server in 0.7 s and
leaves it serving normally; 293 projects list in ~0.4 s; the real Mac Import
window completed a phone→Mac import end to end. The device run found three
bugs a simulator structurally cannot (§3's semaphore recipe doesn't bound
anything, `FileHandle.read`'s autorelease made memory track bytes read 1:1, and
a cabled device's two-interface race broke newest-wins) — all fixed, all
written up in the plan doc's header.

**macOS Local Network permission, learned the hard way 2026-08-27.** It is
granted per COPY of the app, keyed on the binary rather than the bundle id, so
every build from a new location becomes a new grantee and the Settings list
fills with identical LetsLapse rows — all switched on, none of them the one
running. Two consequences now handled in code: `NWBrowser` never recovers from
`.failed`, so the Import window rebuilds it every 2 s and picks up a
newly-granted permission on its own (it used to need a close and reopen); and
the refusal screen names the running copy's path, offers Show in Finder, and
opens Settings via the `privacy-localnetwork` anchor. **`tccutil reset
LocalNetwork` does nothing** — Local Network is not a TCC service on macOS
(`kTCCServiceLocalNetwork` is absent from `tccd`), so there is no CLI reset and
stale rows can only be left to age out. Running one copy from one fixed
location is what stops them accumulating.

**Thumbnail coverage — fixed 2026-08-28.** Tiles no longer ride with the list.
Each row asks for its own as it appears (`requestThumbnail` → `PTThumbnailReply`)
and the serving device GENERATES one when its cache has none, persisting it
under the same key the local grids read — so it costs one decode ever, and the
local Gallery gets it for free. That is the §2 design, and it fixes the real
problem: the old eager path was capped not by its 3 MB budget but by coverage,
because `DiskThumbnailStore` only holds a tile for an asset some grid has
actually drawn. Measured on this Mac: **79 of 79 rows drawn**, 1.5 MB of tiles,
10.3 s on the first pass and instant on the second; visually confirmed on the
Mac's picker against a serving iPad, including three projects that had arrived
by transfer minutes earlier and had never been drawn locally.

**Still owed:** iPad→Mac (every Mac-side run so far has been from an iPhone).
Settings ▸ Incomplete Transfers is not built: with no resume there is nothing
to resume, and the sweep reclaims the disk. Resume itself (the `have` set) is
the remaining §4 work.

Move a ~1–20 GB project device-to-device over the local network with no
intermediate file on either side: iPhone/iPad serve behind a six-digit code,
Mac/iPhone/iPad pull. A new `_letslapse-library._tcp` listener, deliberately
separate from `CaptureRemoteListener` (different lifetime, different grant —
serving the whole library is not the same act as driving the shutter), and a
typed length-prefixed frame format carrying JSON control beside raw payload.

**The payload is files, not an archive.** lzfse over DNG/ProRes saves close to
nothing, so the compression pass buys a rounding error and costs heat on a
thermally marginal phone — while file-by-file makes the transfer **resumable**
with the filesystem as its own ledger (stage into `Incoming/<projectID>/`,
`.part` until complete, reconnect with the set you already hold). A sequential
Apple Archive stream has no "start at entry N", so an interruption at 90% throws
away 90%; that is the trade this reverses. Phase 0 measures the real compression
ratio on Steven's own footage to confirm it before committing.

**Prerequisite for everything else:** the app has no central busy flag — capture
lives in `CameraController`, blending in `AppModel.stage`, and both archive
exports in view-local `@State` — so a `LibraryActivity` registry lands first.
Two smaller traps already identified: `"Incoming"` must join
`StorageLocation.libraryItemNames` or a storage move strands a half-finished
12 GB transfer, and the `["source","blends","notes"]` install allowlist must
become one shared constant or untransferable bytes get sent and then deleted.

**AirDrop already works** via the share sheet and needs no work — with the
caveat that it materialises the whole `.lapse` to temp first (peak disk ≈ 2×,
though `exportProject` refuses cleanly when there is no room). **USB is free**:
listening on all interfaces means a cabled iPhone is found by the Mac's browser
with no protocol change — the only work is a picker label, and what interface
type a tethered device reports is a hardware check, not an assumption.

Phased iOS-serve → Mac-import (**done**), iOS import (**done**), Mac serve
(**done**). Both phases' UI was built app-first at Steven's direction and mirrored
in the same unit of work: `iOS/projects.sharing.portrait.svg`,
`iOS/settings.advanced.portrait.svg`, `iOS/create-home.import-source.portrait.svg`,
`iOS/library-import.browse|progress.portrait.svg` and the five
`macOS/library-import.*.svg` files.

### Holy Grail ramp actuation: bench verification on both pipelines

**Detail:** [holygrail-ramp-actuation.md](holygrail-ramp-actuation.md) ·
**Raised:** 2026-08-27 · **Code landed 2026-08-27 — verification owed**

*Shipped on `ios-app`: the JPEG live-blend path now arms the ramp AFTER
`lockConstituentSwitchingForRun()` rather than ~1.3 s before it;
`applyHolyGrailExposure()` returns a named outcome instead of three unlogged
early returns, with one bounded retry folded into the existing settle hold;
and both blend controllers now report a ramped run whose commanded exposure is
nil (`RAMP NOT DRIVING`, plus `kind: "ramp"` in the `issues[]` trail on the
JPEG side).* The bug: three consecutive Dynamic runs on the 16 Pro logged a
ramp and drove nothing — engine target and delivered frames finished 4.3 stops
apart with `EXPOSURE DIVERGENCE` appearing zero times, because a nil commanded
target skipped the guard that was supposed to catch exactly this. Owed before
this leaves the list: **(a)** a bench run on each pipeline (JPEG, then DNG
output enabled) against the pass conditions in the brief — in particular
frame 0's ISO/shutter within a quarter stop of frames 1–3, which is the
regression test for the original purple frame; **(b)** confirm or kill the
hypothesis that a virtual device with constituent switching unlocked is what
refuses `.custom` — the fix does not depend on it, but the next person's
mental model does; **(c)** the product call on whether a run whose ramp cannot
actuate should refuse to start rather than only saying so in the log.

### Dim-screen-during-shoot: mirrors, Watch verification, and the composed A/B

**Detail:** [fieldtests/2026-08-25-thermal-bench.md](fieldtests/2026-08-25-thermal-bench.md) ·
**Raised:** 2026-08-25 · **Implemented 2026-08-25 (code-first per Steven) — mirrors + follow-ups owed**

*Shipped on `ios-app`: Settings ▸ Advanced ▸ "Dim screen during shoot" (ON by
default), `ShootScreenDimmer` (brightness floor + black cover + tap-to-peek +
restore on stop/exit/background; one `ShootDimming` modifier because
CaptureView's body sits at the type-checker's budget), Watch toggle in the
recording controls page, wire command `setDimDuringShoot` (the one setter
accepted mid-run, by design), `dimDuringShoot` in the state frame, and
`--dim on|off` in shoot.py run+fleet. Bench-verified: the A/B where dim-ON
completed a 20-min psycho arm the matched dim-OFF control could not
(12 Pro, veto at T+18.2).* Owed before this leaves the list: **(a)** SVG
mirrors after sign-off — settings.advanced + the watch controls page;
**(b)** Watch-side verification on the real wrist (toggle round-trip,
pending states); **(c)** repeat the A/B under the monitor test card's
constant light (today's evening pair carries an ambient confound the
result survived but shouldn't have to); **(d)** the composed test: Safe +
dim vs psycho + dim on the 12 Pro — Safe attacks the floor load, dim the
OS margin, and the field default should be whichever pair holds a 2-hour
run.

### The 12 Pro locks whenever LetsLapse dies hot — and Never doesn't matter

**Raised:** 2026-08-25 · **Not started**

Observed ≥6× today (5 thermal vetoes + one post-collection console-detach
kill after a *clean* arm): whenever the app dies on a hot device the phone
ends up locked, despite Auto-Lock → Never, and a locked device refuses
`devicectl` launches — an unattended rig that dies stays dead AND
unreachable. Steven's correlation: it never locks otherwise; once woken it
stays awake. Mechanism unpinned. Discriminating test queued: hand-launched
short shoot + normal exit (cool, then hot) vs devicectl-launched ditto —
separates "dev-tools launch" from "app death" from "hot at death". Whatever
the mechanism, the suspension-lifecycle job (below) should treat
"post-outage device may be LOCKED" as a first-class state in its recovery
design, and the field checklist gains: physical access is the only cure.

### `collect_arm` can hand back the previous run's capture log

**Raised:** 2026-08-25 · **Not started** · small

`shoot.py`'s `collect_arm` pulls the newest `capture_log.json` on the
device; an arm that died mid-run registers no project, so the pull silently
returns the *previous* run's log as if it were this one — bit twice today
(Phase A returned the morning field log; the dim-OFF control returned the
dim-ON arm's log, nearly inverting the A/B verdict). Fix: parse the pulled
log's `startedAt` and require it inside the arm's window; otherwise report
"no capture log from THIS run — the arm died; see the liveblend experiment
log" (which the same collection already pulls and which is the honest death
record).

### Holy Grail ramp servo limit-cycles against the ISP's exposure quantization

**Detail:** [fieldtests/2026-08-25-dawn-scheduled.md](fieldtests/2026-08-25-dawn-scheduled.md) §2 ·
**Raised:** 2026-08-25 · **Implemented 2026-08-25 evening — bench validation owed**

*Shipped in `HolyGrailRampEngine`: deadband (0.12 stop) + 3-window dwell +
10-window reversal refractory + 1-stop emergency bypass, on for every
Dynamic run, zero-parameters = bit-identical legacy (33 legacy tests
untouched, 4 new gate tests). Worst case at the coarsest latch region is a
~40 s sub-visible breathing instead of per-window flicker. Owed: the
test-card scripted-ramp run through the short-shutter region, gated by
`source_flicker_report.py`, then a real dawn arm and one DNG confirmation
arm.*

The 2026-08-25 iPad dawn run carries 13 oscillation events (up-down-up
exposure pumping, ~0.09–0.16 stops per flip): at short shutters the ISP only
latches coarse discrete exposure states (0.18–0.37 stops apart at the ISO 18 /
sub-200 µs end), the wanted exposure sits between two of them, and
`HolyGrailRampEngine.advance` has no deadband, no hysteresis and a one-window
measurement delay — so the servo flips between the two latched states every
window. Fix in the Kit: commit a move only past a deadband (~1/6 stop) that
has persisted K≈3 consecutive windows in one direction (dwell), hysteresis
sized above the local actuation quantization, an emergency bypass for >~1-stop
errors. Unit tests: synthetic quantized actuator under a slow ramp → monotone
steps, zero steady-state toggles; constant scene stays a no-op. Verify on the
monitor test card's scripted brightness ramp, then a real dawn arm. Gate
before/after with `tools/source_flicker_report.py`. Policy-only change — no
bracket construction or device-write path touched, so DNG capture is
structurally unaffected; run one DNG arm to confirm.

### Dynamic (holy grail) runs must end where AE would meter the ending scene

**Detail:** [fieldtests/2026-08-25-dawn-scheduled.md](fieldtests/2026-08-25-dawn-scheduled.md) §1 ·
**Raised:** 2026-08-25 · **Implemented 2026-08-25 evening — bench validation owed**

*Shipped: the anchor drifts toward the device AE's own absolute opinion
(`exposureTargetOffset`-derived `aeSceneEV`, bias-inclusive) at a hard cap
of 1/20 stop per window with a 0.25-stop deadband and its own EMA — an
outer loop an order of magnitude slower than the servo, so the 2026-08-15
runaway class is excluded by construction; the absolute reference also
cancels the luma meter's ×1.75 crush amplification. Engine: shared, so DNG
and JPEG paths both fix at once; without an AE reading the anchor holds as
before (3 new Kit tests; `holygrail: anchor drifting` LLog when the gap
exceeds half a stop). Owed: the test-card dark→bright scripted ramp ending
within ~1/3 stop of a fresh-AE control, then a real dawn.*

The frozen-anchor dark run: `anchorsToSeedExposure` locks the seed frame's
rendering for the whole run, so a 2 h 17 m sunrise ended 6.1 stops darker than
the same scene's fresh-anchor exposure (control shoot 1b), amplified 1.75× by
the whole-frame mean-luma meter's non-invariance (residual loop gain 0.43).
Two-part fix: (a) let the anchor drift slowly (~1/20 stop/window cap) toward
consistency with the device's live AE opinion (`exposureTargetOffset`), so the
run converges on AE's rendering without frame-visible steps — designed against
the 2026-08-15 positive-feedback runaway (drift gain far below unity, Kit
regression `testAConstantSceneNeverMovesTheRamp` plus a drift-converges test;
(b) make the meter clip-aware (trimmed/percentile luma) to cut the residual
gain. Needs the test-card bench (scriptable light curve) for closed-loop
validation before a dawn. Diagnostic that found it: `measuredEV − appliedEV`
flat at −2.81 all run. Related: the scene-referred-meter note in the JPEG WB
brief.

### A suspended shoot must die honestly or resume deliberately — never zombie

**Detail:** [fieldtests/2026-08-25-dawn-scheduled.md](fieldtests/2026-08-25-dawn-scheduled.md) §3 ·
**Raised:** 2026-08-25 · **Not started**

iPhone 12 Pro, unthrottled 3 s: thermal critical at +16 min, iOS forced the
cool-down lock at ~+32 min, the app suspended for ~103 minutes (proven by
`procMs` 285 s across a 108-min wall gap), and the run neither ended nor
resumed — window advancement is frame-driven and the watchdog clock pauses in
sleep. On wake the backlog close-storm fed `consecutiveProcessingFailures`,
which killed the run one second after it had just delivered a good frame, and
the resumed camera was silently back in plain AE (frame 635). Work: detect
the outage (interruption notifications + wall-vs-monotonic gap at wake) →
`issues[]` entry with the real reason and gap; backlog catch-up windows never
count toward the kill guard; on wake either re-assert the ramp's custom
exposure or end as `endReason: systemPressure`; author EXIF DateTimeOriginal
from `capturedAt` so late-written windows carry capture time (rides the JPEG
EXIF job). Mirror in both blend controllers. Plus prevention: thermal input
to the AIMD ceiling (step down at serious, floor at critical) and the planned
starvation repace, so unthrottled degrades instead of summiting into the OS
veto; scheduled unattended shoots should warn on (or default away from)
unthrottled on OIS-class phones.

### Pin digital stabilization off on tap connections, and log it

**Raised:** 2026-08-25 · **Not started** · small

The 2026-08-25 investigation re-confirmed the interval/blend frames can never
be digitally stabilized today (only `movieOutput` ever gets a stabilization
mode; data-output connections default off) — but that guarantee is implicit.
Set `preferredVideoStabilizationMode = .off` explicitly on the liveBlend /
test-card / framing tap connections where supported and record it once in the
session log, so the next tripod-jump investigation (they recur: Praha
2026-08-23, dawn 2026-08-25 — both were OIS hardware sag at thermal critical,
which has no API off-switch) starts from a logged fact instead of a code read.

**Raised:** 2026-08-24 · **Implemented 2026-08-24 — device verification pending**

*Shipped on `ios-app`: the frame-alignment gate (`FrameAlignmentGate` in the
Kit, wired into `LiveBlendController`; rejects confidently-displaced frames
before they ghost a stacked window — the Praha 2026-08-23 OIS-sag events,
measured at ~63 px vertical at thermal critical), honest per-window
`rejectedByAlignment` stats plus a machine `issues[]` trail in
`capture_log.json` (thermal, framing glitches, constituent hand-offs, end
reason), run-scoped constituent-switch locking, the idle thermal warning chip,
and the full Field Notes flow (audio/issue/text notes per project in `notes/`,
both entry points, on-device speech review). Kit tests + sim E2E pass.*

Still owed before this leaves the list: **(a)** bench repro on the 12 Pro —
heat to critical with back-to-back runs, tripod on a static scene, expect gate
rejections logged and clean output; and a nominal-thermal control run with
**zero** false rejections (the gate must never thin a healthy shoot);
**(b)** a `.lapse` export→import round trip carrying `notes/` (the import
allowlist fix); **(c)** the spoken-memo → transcript-prompt path on a real
device (sim lacks on-device recognition); **(d)** SVG mirrors after UI
sign-off — capture-screen thermal chip, project-detail notes rows, the
field-note flow screens (no iPadOS/macOS project-detail SVGs exist at all —
pre-existing gap).

### Interval shoots get the video "New blended clip" screen

**Detail:** [interval-adjust-unification.md](interval-adjust-unification.md) ·
**Raised:** 2026-08-24 · **Phases 1–2 implemented 2026-08-24 — phases 3–4 open, phase-2 sign-off pending**

*Phase 2 (2026-08-24, code-first per Steven): interval shoots now get the
real warp timeline — per-stretch **blend depths** ("5:1" chips, custom to the
frame count) absorbing the old slider, the capture-clock axis (frame-count
fallback), the "One long exposure" mode row, the unified estimate card, and
wide layouts. `IntervalWarp` compiles the schedule in the Kit (trivial
timeline ≡ the old constant schedule, per-stretch clock retiming);
`stackSequence`/`stackSequenceLinear` take `customWindows`. Verified: Kit
tests, three platform builds, headless Mac E2E on the real library (303
photos → 101 frames @ depth 3, timed from capture, warp in the recipe), Mac
wide + iPhone narrow screenshots via the new `LL_ADJUST=stills` /
`LL_ADJUST_CREATE=1` hooks. Owed: Steven's sign-off on the built UI, then
the SVG mirrors (`adjust.photos.portrait.svg` marked stale in the iOS INDEX;
iPadOS/macOS have no adjust SVGs — pre-existing gap), and a device pass.*

*Shipped on `ios-app`: every interval-style run now writes `frames.timestamps`
(plain photo-timer runs in `CameraController`; blend runs in both blend
controllers, off for Holy Grail where the ramp owns the file); stills projects
get probed `sourceWidth/Height` and a sidecar-derived `sourceDurationSeconds`
at registration, import, and a one-shot launch catch-up; and the shared stills
axis exists as `FrameAxis` in the Kit (photo editor lifted onto it,
`StillsPreviewLoader` staged beside `WarpPreviewLoader` for phase 2).
Deliberately invisible: badge/header lines are kind-gated so the new fields
change no screen. Side effect by design: fresh plain-interval blends now lay
out on the real capture clock (`ImageStacker` already honoured a covering
sidecar) — even pacing maps to the constant layout, so only genuinely uneven
shoots read differently, which is the sidecar's whole point.*

Verified 2026-08-24: Kit tests (13 new `FrameAxis` cases) and iOS-sim, macOS
and device builds all pass; the stills probe ran against the real Mac library
— 47/48 stills projects gained oriented dimensions (the 48th has its frames
missing on disk, correctly left nil), and exactly the 32 sidecar-backed
projects gained durations with none invented and all 14 video projects
untouched. Still owed for phase 1: one live interval run confirming
`frames.timestamps` lands in a fresh project's `source/` — the phase-1 build
is **already installed on the iPhone 12 Pro**; the phone was locked at bench
time, so unlock it and run
`./remote_probe <code> "setIntervalMode:basic,setFramesPerBlend:1,setIntervalSeconds#1,wait@1,startRecording,poll@2x6,stopRecording"`
(and once more at `setFramesPerBlend:3` for the blend pipeline).

Then phases 3–4 — spatial unification (reframe/canvas on stills renders,
codec chooser on both stills paths; grade maps turned out already unified:
the stacker's grade hook was source-anchored all along), then retiring the
`.photos` branch once Scanner is diverted to its own configure surface. Each
UI phase starts with the design-sync question.

### Field notes ↔ engine issue trail tie-in

**Raised:** 2026-08-24 · **Not started** · small

`capture_log.json` now records machine-detected issues (`framingGlitch`,
`thermal`, …) and Field Notes lets the user log the same vocabulary by hand
("Jumped frame(s)"). Two natural joints, deliberately not built yet: a
finished run whose log carries alignment/thermal issues could pre-tick the
matching Log Issue labels on the New-blended-clip screen, and the project's
notes list could surface the engine's own issue trail alongside the
hand-written notes. Design question first: whether machine entries live in the
same list or a separate "what the engine saw" section.

### JPEG Holy Grail locks white balance, and writes no EXIF

**Detail:** [jpeg-holygrail-wb-brief.md](jpeg-holygrail-wb-brief.md) ·
**Raised:** 2026-08-23 · **Implemented 2026-08-23 — device verification pending**

*Jobs A (slew-limited WB tracking for JPEG runs; DNG untouched via an explicit
`rawPipeline` flag) and B (EXIF authored on blended JPEGs) are implemented on
`ios-app`. Still owed before this leaves the list: a dawn/dusk JPEG arm on
device (WB tracks, EXIF present, flicker gate passes) and a DNG arm diffed
unchanged against a pre-change run. Job C (scene-referred meter) remains
record-only.*

`applyHolyGrailExposure()` sets `whiteBalanceMode = .locked` on every ramp write
and nothing restores AWB until the run ends, so the 2026-08-23 `jpeg sunrise`
shoot rendered two hours of sunrise through sodium-vapour gains: red ends at
**14 of 255 code values** — quantised away, unrecoverable in 8-bit. Acceptable
for DNG (grading latitude, and the stability is wanted); a show-stopper for
JPEG. Separately, the JPEG blend output is written with a GPS dictionary and
nothing else, so it carries no `DateTimeOriginal`, `ExposureTime`, `ISO` or
`FNumber` — the DNG author writes a real EXIF IFD, JPEG never has.

**The trap:** `applyHolyGrailExposure()` is shared by both pipelines, so a naive
edit changes DNG too — the fix has to be conditioned on the active pipeline.
The brief also records what is *not* wrong: the ramp did not run away (it held
to 0.12 stops over two hours), and the darkness is the seed anchor working as
designed.

### Capture Flat is dead on the blended JPEG path, and unlogged

**Detail:** [capture-flat-jpeg-brief.md](capture-flat-jpeg-brief.md) ·
**Raised:** 2026-08-23 · **Implemented 2026-08-23 — device verification pending**

*Jobs A (log truth: `captureFlat`, honest `captureMode: dynamic`) and B (flat
graded on the window's half-float mean, one 8-bit quantise, same curve as the
photo path) are implemented on `ios-app`; Kit tests cover the float finalize.
Still owed: re-run the §1 A/B on device — expect saturation ≈×0.80, contrast
≈×0.90, `captureFlat` in both logs — plus the shadow-push latitude check. Job
C (sensor-side probe) is open, and one product gap surfaced: the blend-strategy
picker only reaches the DNG pipeline; JPEG Auto always runs Zone.*

A measured A/B (projects `JPEG flat` / `JPEG non flat`, 2026-08-23, iPhone 16
Pro, Interval · JPEG · Psycho · Dynamic) came out pixel-identical: the blended
JPEG writer never reads the Capture Flat flag — the toggle only works for
photo-output stills and video. Where it does run it is a save-time re-grade of
the finished 8-bit JPEG (decode → grade → second lossy encode), which is the
post filter the setting exists to avoid. And no still shoot records the setting:
`capture_log.json` has no `captureFlat`, its `captureMode` is hardcoded
`"interval"` (Dynamic runs are indistinguishable), and `algorithm` says `zone`
for every Auto run. The fix that matters: apply the flat curve to the blend's
existing **float32 mean** at finalize — one quantisation, in flat space
(`finalizeMean` → `encodeGamma` already owns this) — which is metering-neutral,
unlike any tap-encoding change. Related, and downstream in value of, the WB
brief above.

### Storage accounting, and the Settings storage card

**Detail:** [storage-accounting-job.md](storage-accounting-job.md) ·
**Raised:** 2026-08-21 · **Not started**

Deleting every project on the bench iPhone freed 0.08 GB of a claimed 26.29 GB.
Capture staging is cloned into the project on adoption and never released, share
archives are never deleted, and the tmp filter matches neither — so the device is
sitting on **44.6 GB the app reports as `Cache Zero KB`**. Four defects, plus a
redesign of the storage card around reclaimable bytes rather than allocated ones.
Includes a one-time reclaim for installs already carrying orphans, and a
design-sync pass on the Settings SVGs.

### `swift test` fails on a dead scratch path

**Raised:** 2026-08-22 · **Not started** · small

`LinearDNGTests.testBlendsRealUntouchedSequence` writes its output to a
hard-coded absolute path from a long-finished Claude Code session
(`Kit/Tests/LetsLapseKitTests/LinearDNGTests.swift:156`), so `swift test` ends
`243 tests, 1 failure` with `writeFailed("The folder "untouched-blend-3.dng"
doesn't exist.")`. It only bites where there is real capture data — without an
untouched-DNG project in `~/Library/Application Support/LetsLapse/Projects` the
test `XCTSkip`s — which means it fails on the dev machine and passes anywhere
else. Point it at `FileManager.default.temporaryDirectory` (or a
`URL.temporaryDirectory` subfolder created by the test). Until it is fixed,
`.claude/skills/run-letslapse/SKILL.md` documents the failure as expected.

### A scheduled stop is logged as `endReason: user`

**Raised:** 2026-08-22 · **Not started** · small

The fleet smoke's three arms were stopped by `scheduleStop`, and all three
logs record `endReason: user` (they ran 9.99, 9.99 and 10.18 minutes against a
10-minute deadline, so the mechanism itself worked). `performScheduledStop()`
passes `source: .scheduled`, so the mapping to the log's `endReason` is
losing it. It matters because gate criterion V4 ("ran to plan") cannot
distinguish a planned end from someone tapping stop.

### `remote_probe` digest() shows almost nothing for a video run

**Raised:** 2026-08-22 · **Not started** · small

Add the video keys (`baseFPS`, `rampFPS`, `sequenceMode`, `segmentCount`,
`markerCount`) to `digest()` in `tools/remote_probe.swift` — a video run's
one-line digest currently shows almost nothing, because the digest was written
around the interval keys.

*(The other half of this entry is done: the script grammar now parses
`cmd:extra#value`, so `scheduleStop:minutes#60` is sendable and a shoot can own
its own deadline instead of being timed from the Mac. The header comment's
Shared-source list was corrected to three at the same time.)*

---

## Where the rest of the open work is recorded

Not everything known-broken has been turned into a job yet. Until it is, these
are the standing lists:

- **[letslapse-app-overview.md](letslapse-app-overview.md) §10 — "Current limits
  and sharp edges."** The honest known-issues list for the whole app: the ramp
  voiding the warp timeline, the reframe canvas framing an approximate frame,
  `ReframeTrack.clamp` never being called, the responsive-capture wedge, the
  test gaps. Several of these are jobs waiting to be written up.
- **[overview-audit-2026-08-10.md](overview-audit-2026-08-10.md) Part C.** The
  reframe UX triage table — problems, severity, and the use cases the feature
  should serve.
- **[design/](design/) — each platform folder's `INDEX.md`.** Per-screen mirror
  status; anything marked stale is outstanding UI work by definition.
- **Holy Grail Field Program** (artifact). The blend-strategy field programme:
  what has been run, what passed, what the next bench is for.
