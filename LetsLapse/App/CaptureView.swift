import SwiftUI
import AVFoundation
import LetsLapseKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The redesigned camera. One rule: the viewfinder is never covered.
/// Portrait puts controls in the letterbox zones; landscape uses side rails.
struct CaptureView: View {
    var intent: CaptureIntent = CaptureIntent()

    @EnvironmentObject var model: AppModel
    @AppStorage("capture.gpsEnabled") private var gpsEnabled = true
    /// Opt-in remote control (Settings ▸ Advanced), off by default. Read here
    /// so toggling it takes effect on a capture screen that is already open.
    @AppStorage(CaptureRemoteListener.enabledKey) private var allowRemoteAccess = false
    /// "Capture Flat" — a flat/log capture profile. Drives Apple Log for video
    /// (via `camera.appleLogEnabled`) and a save-time grade for JPEG stills
    /// (read in `CameraController`'s write path). See the format sheet.
    ///
    /// Stored per capture scope, not once: Video's Flat switches the sensor
    /// into Log (a whole other format and file size) while the still modes'
    /// Flat is a save-time JPEG grade, and flat-stills/sharp-video is a normal
    /// setup. Both scopes are held here — `@AppStorage` binds one fixed key,
    /// so the mode-dependent answer is computed rather than keyed.
    @AppStorage(FlatCapture.storageKey(for: FlatCapture.Scope.stills))
    private var stillsFlat = false
    @AppStorage(FlatCapture.storageKey(for: FlatCapture.Scope.video))
    private var videoFlat = false
    /// Flat as it applies to the mode currently on screen. Which scope a mode
    /// belongs to is `FlatCapture`'s call, so Photo and Interval sharing one
    /// answer is stated in exactly one place.
    private var captureFlat: Bool {
        FlatCapture.scope(for: mode) == .video ? videoFlat : stillsFlat
    }
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @ObservedObject private var watchRemote = WatchRemoteControlReceiver.shared
    #endif
    @StateObject private var camera = CameraController()
    /// Device-motion primitive: the Interval tail-frame log and the Scanner's
    /// steadiness veto. (Its Photo-mode shutter gate — the Hand — was retired
    /// 2026-09-11; blended bursts and Bulb fire at once.)
    @StateObject private var steadiness = SteadinessMonitor()
    /// Auto shape mode's live pass (see LiveShapeFinder.swift): the shapes
    /// traced on the Photo viewfinder while `autoShapesEnabled`. `@State`
    /// holding an `@Observable`, so its samples re-render the overlay and
    /// not this body.
    @State private var liveShapes = LiveShapeFinder()
    /// Monitor test-rig watcher/executor (see TestCardRig.swift): watches the
    /// idle Video preview for the test card, then runs its script hands-free.
    @StateObject private var testRig = TestCardRigController()

    /// Settings ▸ Display. The blackout is display-only, so the Watch and the
    /// remote may flip it even mid-run (`setDimDuringShoot` — the key and the
    /// wire token survived the 2026-09-05 rename).
    @AppStorage(ShootScreenDimmer.defaultsKey) private var blackoutViewfinder = true
    @AppStorage(ShootScreenDimmer.reduceBrightnessKey) private var reduceBrightness = false
    @AppStorage(ShootScreenDimmer.peekEnabledKey) private var scheduledPeek = true
    @AppStorage(ShootScreenDimmer.peekTriggerKey)
    private var peekTrigger = ShootPeekTrigger.defaultTrigger.rawValue
    @AppStorage(ShootScreenDimmer.peekEveryMinutesKey)
    private var peekEveryMinutes = ShootPeekSchedule.defaultEveryMinutes
    @StateObject private var shootDimmer = ShootScreenDimmer()
    /// The last banked frame, decoded when a peek opens rather than kept warm:
    /// once every few minutes is not worth a live thumbnail pipeline.
    @State private var peekThumbnail: Image?
    @State private var peekThumbnailAge: TimeInterval?
    /// The cluster's run-time toggles (design 2026-09-04, third pass), both
    /// per run — see `seedRunToggles`. Dim starts from the Settings default:
    /// on floors the screen at once, a touch on the cover wakes it for 30 s
    /// and it re-dims by itself unless the toggle is turned off in that
    /// window. Info starts off and opens the one diagnostics panel.
    @State private var runDimEngaged = false
    @State private var showRunInfo = false

    @State private var mode: CaptureMode
    @State private var sequenceMode: LiveCaptureSequence.Mode
    @State private var interval: Double = 2
    /// Interval mode's blend dial: fixed source-frame counts plus the
    /// adaptive depths (Psycho/Safe). Default 10: the capture benchmark
    /// showed bracketed RAW delivers 10 frames in ~0.65s, and dense sampling
    /// is what reads as motion blur — 3-5 spread samples read as ghosts.
    @State private var blendDepth: BlendDepth = .fixed(10)
    /// A remote-armed shutter alarm (`scheduleStart`): fires `shutterAction`
    /// at an absolute time on this device's own clock, so a rig of cameras
    /// armed one by one starts the same wall-clock second.
    @State private var scheduledStartTimer: Timer?
    /// Cold standby: a `model.scheduledRecording` far enough away that the
    /// camera has no business being powered. True while the standby overlay
    /// owns the screen and the capture session is deliberately NOT running.
    @State private var standbyActive = false
    /// Whether the warm-up already ran (the session is up behind the overlay).
    /// Also the flag that says whether leaving standby still owes a
    /// `startCameraSession()` — see `exitStandby(startingCamera:)`.
    @State private var standbyWarmedUp = false
    /// Fires at T−`standbyWarmupLead`; brings the session up behind the
    /// overlay so the shutter at T=0 meets a camera that has already settled.
    @State private var standbyWarmupTimer: Timer?
    /// Fires at T=0: applies the armed dials and pulls the shutter.
    @State private var standbyFireTimer: Timer?
    /// A scheduled run's duration, held from the moment the shutter is pulled
    /// until the engine actually reports a run — `camera.scheduleStop` refuses
    /// to arm before `isCapturing`, and the start is a queue hop away.
    @State private var pendingScheduledStopMinutes: Int?
    @State private var showScheduleSheet = false
    /// Standby wakes the camera this far ahead of the start, and only bothers
    /// going cold at all when there is more than a wake-up plus a margin to
    /// wait for. Ten seconds of margin so the boundary case (a schedule armed
    /// 71 s out) doesn't sleep the session for one second and wake it again.
    private static let standbyWarmupLead: TimeInterval = 60
    private static let standbyMinimumLead: TimeInterval = 70
    /// Where Safe falls back when its profile basis disappears (interval or
    /// format change, learning reset) — the last deliberate fixed choice.
    @State private var lastFixedBlendFrames = 10
    /// Interval's MODE dial — which decision this shoot takes away from the
    /// timer. Basic is the plain timer shoot, Holy Grail takes exposure, Scanner
    /// takes the firing itself. Persisted on its own key rather than through
    /// `RecordingSettingsStore` — it is a shooting *intent* the user sets for
    /// a specific evening (or a specific object), not part of the remembered
    /// format snapshot. The key is the one the Bool it replaced used, and
    /// `IntervalCaptureMode(token:)` decodes the two values that Bool wrote.
    @AppStorage("letslapse.capture.holyGrail") private var intervalModeToken = IntervalCaptureMode.basic.rawValue
    private var intervalMode: IntervalCaptureMode {
        let decoded = IntervalCaptureMode(token: intervalModeToken)
        // A Mac that inherited an iCloud-synced Dynamic or Scanner shoots the
        // plain interval rather than silently shooting something the platform
        // can't do. Ladder it can run — by hand (`ladderStepsByHand`).
        return decoded.isAvailableOnThisPlatform ? decoded : .basic
    }
    /// EVERY is on Auto: the mode paces the shoot. Only meaningful with a MODE
    /// that can pace — see `IntervalCaptureMode.supportsAutoInterval`.
    @AppStorage("letslapse.capture.intervalAuto") private var intervalAutoEnabled = false
    /// Ladder MODE's object. The built-in is nil here (it needs no id); a
    /// user ladder's id is remembered through `RecordingSettingsStore` and
    /// falls back to the built-in whenever it no longer resolves.
    @State private var selectedLadderID: UUID? = RecordingSettingsStore.ladderID
    @ObservedObject private var ladders = LightLadderStore.shared
    @State private var showLadderPicker = false
    @State private var showLadderManager = false
    /// The light panel: COLLAPSED by default when Ladder is armed (design
    /// 2026-09-04 — the rung pill is the armed screen, top-leading in both
    /// orientations), opened by a tap on the pill or by itself on a rung
    /// change while armed (decision D10), which is the one moment it earns
    /// the space. While running the toast and readout carry it instead.
    @State private var ladderPanelOpen = false
    /// The armed panel's own selector — the same 3-window average and ±0.5
    /// switching band the run uses, so the rung it names is the rung the
    /// shoot would open on, not a flicker of the preview meter.
    @State private var ladderPreviewSelector: LightLadderSelector?
    @State private var showLadderToast = false
    @State private var ladderToastDown = true
    @State private var ladderToastTask: Task<Void, Never>?
    @State private var lastLadderRungIndex: Int?
    /// The rung, where the operator steps the ladder by hand (the Mac —
    /// `ladderStepsByHand`). Remembered for the launch, like the panel: the
    /// capture sheet comes and goes on a Mac, the light doesn't.
    @State private var ladderRungByHand = CaptureView.lastLadderRungByHand
    private static var lastLadderRungByHand = 0
    /// Scanner's PAPER dial — the stock the flat object is, for the perspective
    /// correction taken at export. Persisted like the MODE dial (a shooting
    /// intent, not part of the remembered format snapshot) and read back by the
    /// correction rather than by the capture, which it does not affect.
    @AppStorage("letslapse.capture.scannerAspect")
    private var scannerAspectToken = PerspectiveAspect.auto.rawValue
    private var scannerAspect: PerspectiveAspect {
        PerspectiveAspect(rawValue: scannerAspectToken) ?? .auto
    }
    /// The spacing to fall back to when Auto stops being available (MODE went
    /// back to Basic), so leaving a mode doesn't lose the number the user
    /// last chose.
    @State private var lastFixedInterval: Double = 2
    /// Poses banked as of the last time the count was observed — so the fire
    /// haptic can tell a capture from a "Delete last".
    @State private var lastScannerFrameCount = 0
    /// Scanner's grouping rule: every page its own document, or pages piling
    /// into one until the operator says otherwise.
    ///
    /// On by default because the sitting that motivated grouping is a pile of
    /// single-page things (receipts, letters, forms) — the multi-page document
    /// is the case worth a deliberate press, not the other way round. Persisted
    /// like the other Scanner dials: it is how someone scans, not part of a
    /// remembered format.
    @AppStorage("scanner.newScanIsNewDocument") private var newScanIsNewDocument = true
    /// The 1-based page numbers that opened a document during this run — the
    /// whole record the finished scan's `documents.json` is built from.
    @State private var scannerDocumentStarts: [Int] = []
    /// Whether the *next* page to land opens a new document. True at the start
    /// of a run (page 1 always opens document 1), set again after every capture
    /// while the toggle is on, and set by the New Document button while it
    /// isn't.
    @State private var scannerPendingNewDocument = true
    /// True for a moment after a pose lands, so the state line can confirm it.
    /// View-local rather than engine state: it is about what the operator was
    /// just told, not about what the camera is waiting for.
    @State private var scannerJustCaptured = false
    /// Cancels the previous flash, so two quick captures don't leave the
    /// confirmation on screen after the second one's window has passed.
    @State private var scannerFlashToken = 0
    /// True while Interval's MODE dial is on Holy Grail on a platform that
    /// can ramp — the state in which exposure belongs to the ramp and the
    /// lock button, the readout and the ±EV control all change meaning.
    private var holyGrailArmed: Bool {
        mode == .interval && intervalMode.usesRampEngine && Self.holyGrailAvailable
    }
    /// True while Interval's MODE dial is on Ladder — the ramp drives, inside
    /// the active rung's box, and EVERY and BLEND belong to the rung.
    private var ladderArmed: Bool {
        mode == .interval && intervalMode == .ladder
    }
    /// True while Interval's MODE dial is on Scanner.
    private var scannerArmed: Bool {
        mode == .interval && intervalMode == .scanner
    }
    /// Whether EVERY is effectively Auto right now — the dial's value only
    /// means Auto under a mode that can pace, and Scanner is always Auto.
    private var intervalIsAuto: Bool {
        guard mode == .interval else { return false }
        if intervalMode.requiresAutoInterval { return true }
        return intervalAutoEnabled && intervalMode.supportsAutoInterval
    }

    /// Whether the ramp engine exists here: manual exposure, a numeric
    /// ISO/shutter envelope and RAW — iOS/iPadOS only. Which MODE rows are
    /// drawn is each mode's own answer (`IntervalCaptureMode.isAvailableOnThisPlatform`);
    /// this is the narrower question of whether exposure can be driven at all.
    static let holyGrailAvailable: Bool = {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }()
    /// Ladder without the ramp: the Mac. The rung is the operator's — a chip
    /// in the dial row while armed, the rail's menu while running — and only
    /// its spacing and blend apply; exposure stays the camera's own. The
    /// preview meter, the EV-keyed selector and the light panel's "below EV"
    /// line have nothing to read, so they stand down here.
    static var ladderStepsByHand: Bool { !holyGrailAvailable }
    @State private var showPsychoNotice = false
    private static let psychoNoticeShownKey = "letslapse.capture.psychoNoticeShown"
    private let captureIntervalOptions: [Double] = [0.5, 1.0, 2.0, 3.0, 5.0, 10.0]
    @State private var orientation = currentCaptureOrientation()
    @State private var now = Date()
    @State private var framingStartedAt = Date()
    @State private var showFormatSheet = false
    @State private var showTargetSheet = false
    @State private var gridOverlay: GridOverlayState = .off
    /// Photo mode's manual exposure ("M" in cluster slot 3): whether the
    /// panel is open, the two wheels' detent indices (−1 = A), and the AE
    /// pair manual was entered against (the readout's EV reference — see
    /// `PhotoExposureWheels`).
    @State private var photoManualExposure = false
    @State private var photoShutterIndex = 21
    @State private var photoISOIndex = 8
    @State private var photoManualAEReference: (shutter: Double, iso: Float) = (1.0 / 60, 200)
    @State private var activeTarget: CaptureTargetPlan?
    @State private var targetReached = false
    /// Rolling reference scale for the lens pinch — each threshold crossing
    /// steps one lens and re-anchors here, so a long pinch walks the range.
    @State private var pinchBaseline: CGFloat = 1
    /// The last accepted tap-to-focus, in viewfinder coordinates. Set only when
    /// the camera took the tap, and cleared when the pin behind it is given up.
    @State private var focusReticle: FocusReticle?
    /// Names the stage ZStack, which the preview layer fills exactly — the one
    /// hop tap-to-focus needs between a touch and the layer's own space.
    private static let stageSpace = "captureStage"
    /// On-phone shutter delay: tapping record waits 2 s before starting.
    /// Watch remote starts are deliberately immediate — the wrist is already
    /// hands-off the phone.
    @State private var shutterDelayEnabled = false
    /// Deadline of a pending delayed start; nil when none. Tapping the
    /// shutter while pending cancels instead of stacking starts.
    @State private var delayedStartAt: Date?
    /// Photo mode's auto shape mode — the slot-4 toggle. Remembered across
    /// sessions like the grid; turning it off and on is also the reset that
    /// forgets every dismissed shape.
    @AppStorage("capture.autoShapes") private var autoShapesEnabled = false
    /// The three dials beside BLEND while auto shapes is on — what to look
    /// for, how hard, how big (see `ShapeSearch`). Remembered like the toggle.
    @AppStorage("capture.shapes.family") private var shapeFamilyToken = ShapeSearch.Family.all.rawValue
    @AppStorage("capture.shapes.sensitivity") private var shapeSensitivityToken = ShapeSearch.Sensitivity.medium.rawValue
    @AppStorage("capture.shapes.size") private var shapeSizeToken = ShapeSearch.Size.all.rawValue
    /// What the viewfinder had on screen when the shutter fired, carried to the
    /// finish handler that registers the photo (the capture itself is
    /// asynchronous through the interval or live-blend engine).
    @State private var pendingViewfinderShapes: ViewfinderShapes?
    /// Brightness offset, in stops, either side of the exposure the AE lock
    /// froze at. 0 is the centre of the slider — "as locked" — so the control
    /// can travel both ways; re-taking the lock re-centres it.
    @State private var exposureStops: Float = 0
    private static let exposureStopsRange: ClosedRange<Float> = -3...3
    /// Photo mode's blend depth: how many frames the burst captures and stacks
    /// into the final image. A capture-time setting (not a post-capture one),
    /// so it lives here rather than on the model. Default 10 — dense sampling
    /// reads as motion blur. The picker offers the same discrete presets as
    /// Interval (20 · 10 · 5 · 3 · Off), where Off (depth 1) is a single frame.
    @State private var photoBlendDepth = 10
    /// Bulb: hold the shutter open. The first press starts an uncapped burst,
    /// the second stops it and stacks everything captured into one long
    /// exposure (or, with blend Off, keeps just the last frame).
    @State private var photoBulbMode = false
    /// The burst pill's lifecycle. `.hidden` leaves the slot to the idle
    /// dials; `.running` mounts the pill (Photo: on the first shot; Interval:
    /// at run start); `.settling` plays the completion hold (900 ms) and fade
    /// (400 ms) after the run stops, then returns to `.hidden`. One machine
    /// serves every burst variant — the modes are exclusive, and
    /// `burstPillMode` keeps a stale pill from surviving a mode switch.
    private enum BurstPillPhase { case hidden, running, settling }
    @State private var burstPillPhase: BurstPillPhase = .hidden
    /// What the pill counts: Photo plain stills (`camera.photoCount`), Photo
    /// DNG RAW frames gathered in the window (`liveBlendDiagnostics`), or
    /// Interval outputs (`photoCount` / `liveBlendOutputCount`). Mirrored
    /// into local state so a finished run's number freezes through settle.
    @State private var burstPillCount = 0
    /// The run's cap, frozen at mount (nil = open-ended, the zebra), so a
    /// dial change mid-settle can't relabel a finished burst.
    @State private var burstPillTotal: Int?
    /// The mode that mounted the pill — its slot condition checks this, so
    /// switching modes mid-settle never shows the other mode's pill.
    @State private var burstPillMode: CaptureMode?
    /// Drives the pill's 400 ms fade-out; the pill unmounts once it lands.
    @State private var burstPillFadingOut = false
    /// Strands in-flight hold/fade sleeps when a newer run claims the pill.
    @State private var burstPillGeneration = 0
    /// A DNG Photo shot runs the live-blend RAW pipeline, which is open-ended;
    /// a capped shot arms this so the first finished output stops the run. Bulb
    /// leaves it false — the user's second tap stops it.
    @State private var photoDNGAutoStop = false
    /// Photo mode captures at a fixed fast burst rate — the blend (if any) is
    /// stacked in post, so the frames want dense sampling, not user spacing.
    private static let photoBurstInterval = 1.0 / 10.0
    /// A DNG Bulb run wants one open-ended output window that the user's stop
    /// closes, not a new blended DNG every few seconds — so its window interval
    /// is set effectively infinite (one day). Unthrottled capture fills that
    /// single window until the shutter is tapped again.
    private static let photoBulbDNGInterval = 86_400.0
    /// A capped Photo DNG shot runs the live-blend RAW pipeline for exactly one
    /// window, so that window must last long enough to gather its `frames` RAW
    /// captures — plus the first-frame latency after the session switches to
    /// the RAW photo configuration — before it closes and emits the blend.
    /// Captures fire back-to-back (burst), so the headroom is idle wait, not
    /// extra frames; the run auto-stops the instant the single DNG lands. Too
    /// short a window (the 0.1 s photo-burst spacing) closes empty before the
    /// first RAW even arrives, and three empty windows trip the engine's
    /// self-stop, ending the run with no output and no DNG saved.
    private static func photoDNGWindowSeconds(forFrames frames: Int) -> Double {
        max(1.0, 0.6 + Double(frames) * 0.25)
    }
    /// Lower-left recent-capture tile: the newest project's hero asset and the
    /// URL it was resolved from (also the "is there anything to show" flag).
    @State private var recentThumbnail: Image?
    @State private var recentHeroURL: URL?
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    /// How much shoot is left on the device in the armed configuration, and
    /// when it was last worked out. See `CaptureHeadroom.swift` for why the
    /// capture screen carries this at all.
    @State private var headroom: CaptureHeadroom.Reading?
    @State private var headroomSampledAt: Date?
    /// Device heat at Record time. A run opened at critical is where lens
    /// excursions were observed (Praha 2026-08-23) — the user gets told
    /// BEFORE the shoot is spent, not in the log after. Refreshed on the
    /// screen's own tick; never blocks anything (bench runs hot by design).
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    /// Free space when the run in progress started, and the shape it is
    /// shooting — the pair a finished run is measured from, and the only
    /// reason this screen knows what a frame of anything really weighs.
    @State private var runStartFreeBytes: Int64?
    @State private var runCostKey: CaptureCostKey?
    @State private var runStartedAt: Date?

    init(intent: CaptureIntent = CaptureIntent()) {
        self.intent = intent
        // An explicit intent (effect cards) wins; otherwise open in the
        // remembered mode with its remembered dials, so a habitual Interval
        // shooter never re-selects Interval and its spacing every shoot.
        let remembering = RecordingSettingsStore.isEnabled
        let mode = intent.mode
            ?? (remembering ? RecordingSettingsStore.captureMode : nil)
            ?? .video
        _mode = State(initialValue: mode)
        _sequenceMode = State(initialValue: intent.sequenceMode)
        if remembering {
            if let seconds = RecordingSettingsStore.intervalSeconds(for: mode) {
                _interval = State(initialValue: seconds)
            }
            if let depth = RecordingSettingsStore.blendDepth {
                // A remembered Safe depth is re-gated once the camera is up
                // (`revalidateSafeDepth`) — conditions may have changed.
                _blendDepth = State(initialValue: depth)
                if let fixed = depth.fixedFrames {
                    _lastFixedBlendFrames = State(initialValue: fixed)
                }
            }
            if let photoDepth = RecordingSettingsStore.photoBlendDepth {
                _photoBlendDepth = State(initialValue: photoDepth)
            }
            if let bulb = RecordingSettingsStore.photoBulbMode {
                _photoBulbMode = State(initialValue: bulb)
            }
        }
    }

    // `body` is assembled from four pieces rather than one chain. At the iOS 17 floor every
    // `.onChange(of:)` gains a second (two-parameter) overload, and ~45 of them in a single
    // expression blows the type-checker's budget. Order is unchanged; the split is purely so
    // each piece is solved on its own.

    private var stage: some View {
        GeometryReader { geometry in
            ZStack {
                // One persistent preview, filling the whole area. It lives
                // outside the portrait/landscape branch and is sized by normal
                // layout (never .position/.frame-to-a-rect), so it is neither
                // recreated on rotation (no delay) nor blanked in landscape.
                // `.resizeAspect` letterboxes it; the chrome sits over the bars.
                // The offset only slides the finished layer — it never resizes
                // it — so top-anchoring costs nothing at the capture layer.
                CameraPreview(
                    session: camera.session,
                    camera: camera,
                    orientation: orientation,
                    videoGravity: .resizeAspect
                )
                .allowsHitTesting(false)
                // Capture Flat, made visible: the saturation/contrast half of
                // the save-time grade, applied by the compositor to the live
                // preview — no second render pipeline, and nothing here can
                // touch the session, the tap, or the meter. The grade's
                // highlight/shadow half has no compositor equivalent, so this
                // is the look, not the pixels; the delivered file is the
                // reference. Animated so flipping the toggle in the format
                // sheet visibly answers behind it.
                .saturation(previewShowsFlat ? 0.80 : 1.0)
                .contrast(previewShowsFlat ? 0.90 : 1.0)
                .animation(.easeInOut(duration: 0.35), value: previewShowsFlat)
                .offset(y: previewTopAnchorOffset(in: geometry.size))

                Group {
                    if geometry.size.width > geometry.size.height {
                        landscapeLayout(in: geometry.size)
                    } else {
                        portraitLayout(in: geometry.size)
                    }
                }

                shutterClusterLayer(in: geometry)
            }
            // The preview layer fills this stack exactly (it is an unsized ZStack
            // child), so a point named here reaches the layer's own coordinates
            // by undoing only the top-anchor slide — which is what tap-to-focus
            // hands to `captureDevicePointConverted`.
            .coordinateSpace(name: Self.stageSpace)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden()
        #endif
    }

    /// Sheets, lifecycle and the clock.
    private var chrome: some View {
        // Two expressions, not one: with the ladder chrome inline the macOS
        // type-checker gave up on this chain ("unable to type-check this
        // expression in reasonable time", 2026-09-03).
        let sheets = stage
        .sheet(isPresented: $showFormatSheet) {
            FormatSheet(
                camera: camera,
                model: model,
                mode: $mode,
                sequenceMode: $sequenceMode
            )
        }
        .sheet(isPresented: $showTargetSheet) {
            CaptureTargetSheet(
                kind: scannerArmed ? .scannerPoses : .clip,
                captureFPS: camera.selectedFrameRate,
                outputFPS: model.outputFPS
            ) { plan in
                startTargetCapture(plan)
            }
        }
        // The ladder chrome wraps the lifecycle pair so the order is what it
        // was: `configureOnAppear` first, then the preview meter; the
        // preview meter off first, then `cleanUpOnDisappear`.
        return ladderChrome(
            sheets
            .onAppear(perform: configureOnAppear)
            .onDisappear(perform: cleanUpOnDisappear))
        // Keep the recent-capture tile current: a new project (any mode) takes
        // the slot, and a Photo shot's blend replaces its own hero moments after
        // the capture itself lands.
        .onChange(of: model.captures.first?.id) { _ in refreshRecentCapture() }
        .onChange(of: model.blends.count) { _ in refreshRecentCapture() }
        .onReceive(tick) { date in
            now = date
            thermalState = ProcessInfo.processInfo.thermalState
            checkTarget()
            // Cheap on every tick — it re-prices the space it already knows
            // about, and only goes to the disk every `headroomSampleSeconds`.
            refreshHeadroom()
            if let deadline = delayedStartAt, date >= deadline {
                delayedStartAt = nil
                shutterAction()
            }
            // A scheduled run's duration, armed as soon as the engine admits
            // to running. No-op on every other tick.
            applyPendingScheduledStop()
        }
        // A run's own consumption is the only honest source for what this
        // device's frames really weigh, so every run is weighed. See
        // `CaptureCostStore`.
        .onChange(of: isCapturing) { running in
            if running {
                beginHeadroomRunSample()
                // The cluster's run-time toggles start from here — on every
                // platform, which is why this seat and not the iOS-only
                // orientation block below.
                seedRunToggles()
            } else {
                endHeadroomRunSample(
                    frames: finishedRunFrameCount,
                    seconds: runStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
            }
            // Photo mode keeps the camera live after a shot, so the live shape
            // pass comes back as soon as the engine is done with the session.
            updateShapeWatch()
        }
        .onChange(of: autoShapesEnabled) { _ in
            // On or off, the slate is clean: off drops the tracks so nothing
            // is left traced, on starts from nothing — which is the reset.
            liveShapes.reset()
            updateShapeWatch()
        }
        .onChange(of: shapeFamilyToken) { _ in liveShapes.search = shapeSearch }
        .onChange(of: shapeSensitivityToken) { _ in liveShapes.search = shapeSearch }
        .onChange(of: shapeSizeToken) { _ in liveShapes.search = shapeSearch }
    }

    /// Ladder MODE's sheets and observers over `content`. On the Mac the
    /// preview meter is a no-op (`setLadderPreview` has nothing to read on a
    /// Mac camera) and `previewSceneEV` never lands, so the picker, the
    /// manager and the rung toast are what remains — and the toast reports
    /// the operator's own step there (`stepLadderByHand`).
    private func ladderChrome<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $showLadderPicker) {
            LadderPickerSheet(store: ladders, selectedID: $selectedLadderID) {
                showLadderPicker = false
                showLadderManager = true
            }
        }
        .sheet(isPresented: $showLadderManager) {
            LightLaddersView(store: ladders, selectedID: $selectedLadderID)
        }
        .onChange(of: selectedLadderID) { id in
            RecordingSettingsStore.save(ladderID: id)
            ladderPreviewSelector = nil
            advanceLadderPreview(ev: camera.previewSceneEV)
        }
        .onChange(of: ladderPreviewWanted) { wanted in
            camera.setLadderPreview(enabled: wanted)
            if !wanted { ladderPreviewSelector = nil }
        }
        .onChange(of: camera.previewSceneEV) { ev in advanceLadderPreview(ev: ev) }
        .onChange(of: camera.ladderState?.rungIndex) { index in
            // Down the ladder is darker (a higher index); the toast says which
            // way the step went. The first index of a run is the opening rung,
            // not a step.
            defer { lastLadderRungIndex = index }
            guard let index, let previous = lastLadderRungIndex, previous != index else { return }
            flashLadderToast(down: index > previous)
        }
        .onAppear { camera.setLadderPreview(enabled: ladderPreviewWanted) }
        .onDisappear { camera.setLadderPreview(enabled: false) }
    }

    /// Everything that persists or re-validates the capture setup as it changes.
    private var settingsObservers: some View {
        chrome
        // Persist the capture setup as it changes, from any entry path
        // (on-screen pickers, Watch commands). On a mode switch, swap in
        // that mode's remembered spacing, or adopt the carried-over one
        // as its first.
        .onChange(of: mode) { newMode in
            RecordingSettingsStore.save(captureMode: newMode)
            syncLoggedCaptureMode(mode: newMode)
            updateAspectPreview()
            syncAppleLog()
            // A pill left by another mode (running or settling) doesn't
            // follow the user across the switch.
            if burstPillMode != nil, burstPillMode != newMode { dismissBurstPill() }
            updateTestCardWatch()
            camera.setPhotoViewfinder(newMode == .photo)
            updateShapeWatch()
            // M is Photo-only chrome (`clusterSlot`, `exposurePanel` both
            // gate on `mode == .photo`), but the exposure it set is real
            // device state — leaving Photo must hand that back to AE even
            // though the panel itself just disappears. The wheels' own
            // on/off and indices stay put, so returning to Photo re-arms
            // exactly where it left off, per the handoff's own rule.
            if newMode == .photo, photoManualExposure {
                camera.setManualExposureDeviceNeeded(true)
                camera.setPhotoManualExposure(
                    shutterSeconds: photoShutterIndex >= 0 ? ManualExposureDetents.shutterSeconds[photoShutterIndex] : nil,
                    iso: photoISOIndex >= 0 ? ManualExposureDetents.iso[photoISOIndex] : nil)
            } else if newMode != .photo, photoManualExposure {
                camera.exitPhotoManualExposure()
                camera.setManualExposureDeviceNeeded(false)
            }
            guard RecordingSettingsStore.isEnabled else { return }
            if let seconds = RecordingSettingsStore.intervalSeconds(for: newMode) {
                interval = seconds
            } else {
                RecordingSettingsStore.save(intervalSeconds: interval, for: newMode)
            }
        }
        // The viewfinder must show what a DNG shoot will capture — the full
        // 4:3 sensor — so arming/disarming DNG re-configures the preview.
        // Format and DNG-support changes also switch the profile pool Safe
        // mode draws from, so its basis gets re-checked.
        .onChange(of: model.intervalOutputFormat) { _ in
            updateAspectPreview()
            revalidateSafeDepth()
        }
        // Capture Flat drives Apple Log for video; re-sync when it's toggled.
        // `captureFlat` is the mode's own scope, so this also fires on a mode
        // switch that changes the answer — which is exactly when Log has to be
        // re-derived, and why leaving Flat armed in Photo can no longer put a
        // Video run into Log behind the user's back.
        .onChange(of: captureFlat) { _ in
            syncAppleLog()
        }
        // …and when the device's Log capability lands. On appear the sync runs
        // before the session has configured, so `supportsAppleLog` is still
        // false and Log latched off for the whole session (2026-08-14) — this
        // re-runs the derivation the moment the probe publishes the truth.
        .onChange(of: camera.supportsAppleLog) { _ in
            syncAppleLog()
        }
        .onChange(of: camera.liveBlendDNGSupport) { _ in
            updateAspectPreview()
            revalidateSafeDepth()
        }
        // Arming Holy Grail or Scanner puts the session in the photo
        // configuration too (RAW lives nowhere else), so the viewfinder shows
        // the 4:3 sensor frame the run will actually capture. Scanner also
        // pins EVERY to Auto — the scene sets the spacing, so a fixed value
        // isn't a promise the mode could keep.
        .onChange(of: intervalModeToken) { _ in
            reconcileIntervalAuto()
            updateAspectPreview()
        }
        // A pose landed. Everything the operator gets from a Scanner run that
        // isn't the shutter's own click hangs off this one signal — which is
        // why it must only fire on the count going *up*. "Delete last" moves
        // it down, and answering that with the capture haptic would tell the
        // operator a frame had just been banked at the exact moment one was
        // thrown away.
        .onChange(of: camera.scannerState?.frames) { frames in
            let previous = lastScannerFrameCount
            lastScannerFrameCount = frames ?? 0
            // Grouping is filed on the way down as well as up: "Delete last"
            // can take back the page that opened a document, and a boundary
            // left standing on a page that no longer exists would split the
            // set at the wrong place.
            recordScannerDocuments(previous: previous, frames: frames)
            guard let frames, frames > previous else { return }
            announceScannerFrame()
            checkScannerTarget(frames: frames)
        }
        // The confirmation comes from the **state**, not from the file landing.
        //
        // Those are hundreds of milliseconds apart — the shutter is asked for
        // and the machine banks the page immediately, while `frames` only moves
        // once the photo has been processed and written — so driving the
        // "✓ Captured" flash off the count put it *after* the "Swap in the next
        // page" prompt that the same capture had already raised. The operator
        // saw Settling → Swap → Captured and reasonably read it as the machine
        // running its states out of order.
        .onChange(of: camera.scannerState?.phase) { phase in
            guard phase == ScannerEngine.State.captured.rawValue else { return }
            flashScannerCaptured()
        }
        // A pose taken by hand. Under the document trigger the phase change
        // above already covers it; under the motion trigger the machine stays
        // in `settled` and nothing would confirm the shot at all — so the
        // confirmation hangs off the request count, which only moves when a
        // frame really went out (a refused tap is silent, which is the honest
        // feedback for "that press did nothing").
        .onChange(of: camera.scannerManualCaptures) { _ in
            flashScannerCaptured()
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
        }
        .onChange(of: interval) { seconds in
            RecordingSettingsStore.save(intervalSeconds: seconds, for: mode)
            revalidateSafeDepth()
            revalidateFixedDepthAttainable()
        }
        .onChange(of: blendDepth) { depth in
            RecordingSettingsStore.save(blendDepth: depth)
        }
        // Photo mode's dials persist under the same "remember settings" gate,
        // so a Photo shooter reopens with their blend count and Bulb choice.
        .onChange(of: photoBlendDepth) { depth in
            RecordingSettingsStore.save(photoBlendDepth: depth)
        }
        .onChange(of: photoBulbMode) { isBulb in
            RecordingSettingsStore.save(photoBulbMode: isBulb)
            syncLoggedCaptureMode(bulb: isBulb)
        }
        // A capped DNG Photo shot ends itself: once its single blended DNG is
        // out, stop the open-ended live-blend run. Bulb leaves the flag off.
        // Interval blend runs count their outputs into the burst pill here.
        .onChange(of: camera.liveBlendOutputCount) { count in
            if mode == .interval, burstPillPhase == .running, camera.isLiveBlendRunning {
                burstPillCount = count
            }
            guard mode == .photo, photoDNGAutoStop, count >= 1 else { return }
            photoDNGAutoStop = false
            camera.stopLiveBlend()
        }
        // A DNG Photo shot has no still-counter, but the blend pipeline
        // publishes how many RAW frames the open window has gathered — that
        // is the pill's per-frame truth for both the capped fill and Bulb's
        // zebra. Single-window runs only, so the count never moves backwards.
        .onChange(of: camera.liveBlendDiagnostics) { diagnostics in
            guard mode == .photo, camera.isLiveBlendRunning,
                  let frames = diagnostics?.currentWindowSelectedFrames, frames >= 1 else { return }
            if burstPillPhase == .running {
                burstPillCount = max(burstPillCount, frames)
            } else {
                mountBurstPill(taken: frames, total: photoBulbMode ? nil : photoBlendDepth)
            }
        }
        // Tail-frame detection: tag each captured Interval frame with its
        // motion reading. Photo mode has its own steady gate and never needs a
        // tail log, so only plain-JPEG Interval sessions log here. (macOS is
        // inert — the monitor never moves, so the tail count stays 0.)
        .onChange(of: camera.photoCount) { count in
            // Plain-still engine tallies. A Photo burst mounts the pill on
            // its first shot (never at run start — a steady-gated burst can
            // idle before frame one); an Interval run's pill is already
            // mounted, so its ticks just feed it.
            if camera.isIntervalRunning {
                if mode == .photo, count >= 1 {
                    if burstPillPhase == .running {
                        burstPillCount = count
                    } else {
                        mountBurstPill(taken: count, total: photoBulbMode ? nil : photoBlendDepth)
                    }
                } else if mode == .interval, burstPillPhase == .running {
                    burstPillCount = count
                }
            }
            guard mode == .interval, count > 0 else { return }
            steadiness.logCapture(index: count - 1)
        }
        .alert("Psycho blending", isPresented: $showPsychoNotice) {
            Button("Got it") {}
        } message: {
            Text("Psycho captures as many frames as your device can manage each interval, ignoring thermal limits, for maximum motion blur. Your device may get warm during long sessions. This mode also teaches the app where your device throttles, which powers Safe mode.")
        }
    }

    /// Scheduled standby: the sheet that arms a shoot, and the black overlay
    /// that owns the screen while the camera is deliberately cold.
    private var scheduling: some View {
        settingsObservers
        .sheet(isPresented: $showScheduleSheet) {
            ScheduleShootSheet(
                intervalSeconds: interval,
                blendFrames: blendDepth.fixedFrames
            ) { armed in
                model.scheduledRecording = armed
            }
        }
        // Arming from the sheet takes the screen cold immediately — that is
        // the whole point of the feature, and waiting for the next visit would
        // leave the session burning through the very battery it exists to
        // save. Also covers the schedule being armed from anywhere else.
        .onChange(of: model.scheduledRecording) { armed in
            if armed == nil {
                if standbyActive { exitStandby() }
                cancelStandbyTimers()
            } else if !enterStandbyIfScheduled(stoppingCamera: true) {
                armImminentSchedule()
            }
        }
        .overlay {
            if standbyActive, let scheduled = model.scheduledRecording {
                StandbyOverlay(
                    scheduled: scheduled,
                    now: now,
                    isWarmingCamera: standbyWarmedUp,
                    onCancel: cancelScheduledShoot
                )
                .transition(.opacity)
            }
        }
    }

    /// Orientation and the Watch-link mirrors — iOS only, bar the one shared recording hook.
    var body: some View {
        scheduling
        .modifier(ShootDimming(
            dimmer: shootDimmer,
            plan: shootDisplayPlan,
            frameTick: camera.photoCount + camera.liveBlendOutputCount,
            peek: peekReadout,
            blackoutSetting: blackoutViewfinder,
            onPeekChanged: { open in
                if open { refreshPeekThumbnail() } else { peekThumbnail = nil }
            },
            syncRemote: { on in
                // A flip of the setting mid-run — Settings, the Watch, the
                // remote — moves the run's own Dim toggle with it.
                if isCapturing { runDimEngaged = on }
                // The Watch/remote mirror is iOS-only; the Mac has no panel
                // worth dimming and no watch link to tell.
                #if os(iOS)
                watchRemote.setDimDuringShoot(on)
                #else
                _ = on
                #endif
            }))
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // Refresh the orientation the grid overlay sizes against, and nudge
            // a re-render so the preview re-reads its window orientation.
            let device = UIDevice.current.orientation
            let next = currentCaptureOrientation()
            LLog("orientationNotif device=\(device.rawValue) computed=\(next.rawValue) (was \(orientation.rawValue))")
            orientation = next
            // Capture tagging follows the physical pose (system-camera
            // behavior, correct even under rotation lock). Cache-only — the
            // heavy connection/stabilization pass mid-session stalled the
            // source (a7bab45); capture runs re-assert connections at start.
            if let physical = effectiveCaptureOrientation(device: device) {
                camera.updateCaptureOrientation(physical)
            }
            // Auto shape mode measures in the pose the still will be tagged
            // with — this one, not the interface's, which stays put under
            // rotation lock while the tag turns. Same reason the Scanner's
            // quad is detected at the capture pose.
            liveShapes.setCaptureOrientation(camera.currentCaptureOrientation)
        }
        .onChange(of: camera.isRecording) { isRecording in
            if !isRecording {
                framingStartedAt = Date()
                activeTarget = nil
                targetReached = false
            }
            updateWatchRecordingState()
            updateIdleTimer()
            updateTestCardWatch()
        }
        .onChange(of: testRig.phase) { _ in updateTestCardWatch() }
        #if os(iOS)
        .onChange(of: allowRemoteAccess) { _ in watchRemote.syncLocalNetwork() }
        #endif
        .onChange(of: camera.recordingStartedAt) { _ in
            now = Date()
            updateWatchRecordingState()
        }
        .onChange(of: camera.activeSequenceMode) { _ in updateWatchRecordingState() }
        .onChange(of: camera.markerCount) { _ in updateWatchRecordingState() }
        .onChange(of: camera.rampIntervalCount) { _ in updateWatchRecordingState() }
        .onChange(of: camera.segmentCount) { _ in updateWatchRecordingState() }
        .onChange(of: camera.isRampActive) { _ in updateWatchRecordingState() }
        .onChange(of: camera.isRampHighRate) { _ in updateWatchRecordingState() }
        .onChange(of: camera.isMarkActive) { _ in updateWatchRecordingState() }
        .onChange(of: camera.markIntervalCount) { _ in updateWatchRecordingState() }
        .onChange(of: camera.isIntervalRunning) { running in
            updateIdleTimer()
            updateWatchRecordingState()
            // Interval's pill lives for the whole run, so it mounts with the
            // engine (count 0 draws the bare track); Photo waits for a shot.
            if running {
                if mode == .interval { mountBurstPill(taken: 0, total: nil) }
            } else {
                settleBurstPill()
            }
        }
        .onChange(of: camera.isLiveBlendRunning) { running in
            updateIdleTimer()
            updateWatchRecordingState()
            if running {
                if mode == .interval { mountBurstPill(taken: 0, total: nil) }
            } else {
                settleBurstPill()
            }
        }
        .onChange(of: mode) { _ in
            updateWatchModeContext()
            updateWatchContext()
        }
        .onChange(of: model.intervalOutputFormat) { _ in updateWatchContext() }
        .onChange(of: camera.liveBlendDNGSupport) { _ in updateWatchContext() }
        .onChange(of: interval) { _ in updateWatchModeContext() }
        .onChange(of: blendDepth) { _ in updateWatchModeContext() }
        .onChange(of: photoBulbMode) { _ in updateWatchModeContext() }
        .onChange(of: camera.photoCount) { _ in updateWatchModeContext() }
        .onChange(of: camera.liveBlendOutputCount) { _ in updateWatchModeContext() }
        // The MODE dial and its Auto flag travel with the rest of the dials, so
        // a remote that set them sees its own change confirmed.
        .onChange(of: intervalModeToken) { _ in updateWatchModeContext() }
        .onChange(of: intervalAutoEnabled) { _ in updateWatchModeContext() }
        .onChange(of: camera.activeIntervalSeconds) { _ in updateWatchModeContext() }
        // Each mode's live readout. Pushed on every change — for these two the
        // numbers ARE the interface (see `updateWatchIntervalReadout`).
        .onChange(of: camera.holyGrailState) { _ in updateWatchIntervalReadout() }
        .onChange(of: camera.scannerState) { _ in updateWatchIntervalReadout() }
        .onChange(of: camera.scheduledStop) { _ in updateWatchScheduledStop() }
        .onChange(of: camera.selectedResolution) { _ in updateWatchContext() }
        .onChange(of: camera.selectedFrameRate) { _ in updateWatchContext() }
        .onChange(of: camera.activeBaseFrameRate) { _ in updateWatchContext() }
        // The remote's rate ladder is drawn from both of these, and the rate
        // is now settable FROM the remote — without these pushes a rate picked
        // on the phone mid-shoot would leave the wrist showing the old rung.
        .onChange(of: camera.selectedRampFrameRate) { _ in updateWatchContext() }
        .onChange(of: camera.availableBurstFrameRates) { _ in updateWatchContext() }
        .onChange(of: camera.availableFrameRates) { _ in updateWatchContext() }
        // The remote can now pick the mode, so its own picker has to publish.
        .onChange(of: sequenceMode) { _ in updateWatchRecordingState() }
        .onChange(of: model.constantWindow) { _ in updateWatchContext() }
        .onChange(of: camera.isExposureLocked) { locked in
            // A fresh lock re-anchors the camera's exposure, so the brightness
            // slider returns to its centre with it.
            if locked { exposureStops = 0 }
            updateWatchExposure()
        }
        .onChange(of: camera.lockedISO) { _ in updateWatchExposure() }
        .onChange(of: camera.lockedLensPosition) { _ in updateWatchExposure() }
        #else
        .onChange(of: camera.isRecording) { isRecording in
            if !isRecording {
                framingStartedAt = Date()
                activeTarget = nil
                targetReached = false
            }
        }
        #endif
    }

    // MARK: - Lifecycle

    private func configureOnAppear() {
        // The capture bracket, and the same cross-object convention the watch
        // command handler uses below: `CameraController` holds no reference to
        // the model, and a shoot's real extent is exactly as long as this
        // screen is up. A project transfer refuses to start while this is
        // registered, and one already in flight aborts — a shoot always wins.
        model.beginActivity(.capture)
        // Count the mode the screen opened in as last-used: effect cards set
        // it explicitly, and the plain entry resolved to the remembered mode
        // anyway, so re-saving is a no-op there.
        RecordingSettingsStore.save(captureMode: mode)
        refreshRecentCapture()
        // Before the first tick: the headroom chip is a thing you read while
        // deciding whether to start, so it should not arrive half a second
        // after the screen it is on.
        refreshHeadroom(force: true)
        testRig.camera = camera
        if ProcessInfo.processInfo.environment["LL_TESTRIG"] == "chip" {
            testRig.seedDemoChip()
        }
        updateTestCardWatch()
        camera.setPhotoViewfinder(mode == .photo)
        updateShapeWatch()
        #if DEBUG
        applyModePreviewHook()
        applyAutoShapesPreviewHook()
        applyStandbyPreviewHook()
        applyHolyGrailPreviewHook()
        applyScannerPreviewHook()
        applyLadderPreviewHook()
        applyBurstPreviewHook()
        applyFocusPreviewHook()
        applyRecordingPreviewHook()
        applyManualExposurePreviewHook()
        applyGridPreviewHook()
        #if os(macOS)
        // LL_CAMERA=<name substring> — switch to that camera once the session
        // is up, driving the exact path the Camera menu drives. Exists because
        // that path is where an external camera's off-clock frame rates crash
        // the device configuration (see `frameDuration(forNominal:in:)`), and
        // a regression there is silent until someone plugs a webcam in.
        if let wanted = ProcessInfo.processInfo.environment["LL_CAMERA"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let devices = CameraDevices.shared.devices
                guard let match = devices.first(where: {
                    $0.localizedName.localizedCaseInsensitiveContains(wanted)
                }) else {
                    print("🎥LL LL_CAMERA=\(wanted) matched none of "
                          + "\(devices.map(\.localizedName))")
                    return
                }
                CameraDevices.shared.select(match)
            }
        }
        #endif
        // LL_FORMAT=1 — open the Capture format sheet on appear, so it can be
        // screenshot-verified against its SVG without driving the pointer.
        // Delayed past the session coming up: the sheet's lists are the
        // capability matrix's answers, and before `configureIfNeeded` lands it
        // would be drawn from the seed values rather than the camera.
        if ProcessInfo.processInfo.environment["LL_FORMAT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showFormatSheet = true }
        }
        // LL_RUN: the same idle/Video gate the card tap uses, plus a beat for
        // the session and capability matrix to come up — the rig validates the
        // script's rates against what this device actually offers, and asking
        // before `startRunning` lands would refuse a perfectly good script.
        if mode == .video, !isCapturing {
            let rig = testRig
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { rig.armFromLaunchHook() }
        }
        #endif
        #if os(iOS)
        // Geotagging: request permission if needed, start streaming fixes so a
        // location is ready to bake into stills, and arm the camera's tagger.
        camera.gpsTaggingEnabled = gpsEnabled
        if gpsEnabled {
            let location = LocationService.shared
            if location.authorizationStatus == .notDetermined {
                location.requestPermission()
            }
            location.startUpdates()
        }
        watchRemote.activate()
        watchRemote.setCommandHandler(handleWatchCommand)
        // The framing preview only exists while this screen does. The service
        // attaches its own session tap lazily, on the first request, and drops
        // it again a few seconds after the last one.
        FramingPreviewService.shared.attach(camera: camera)
        updateWatchRecordingState()
        updateWatchContext()
        updateWatchModeContext()
        updateWatchScheduledStop()
        updateWatchExposure()
        updateWatchIntervalReadout()
        updateIdleTimer()
        #endif
        camera.onFinishLiveCapture = { result in
            camera.stop()
            dismiss()
            model.setSequenceSource(result)
        }
        camera.onFinishVideo = { url in
            camera.stop()
            #if os(iOS)
            // Flush the GPX track collected during the take into a sidecar
            // next to the captured video (same base name, .gpx extension).
            if gpsEnabled {
                let points = LocationService.shared.stopGPXPolling()
                if !points.isEmpty {
                    let gpxURL = url.deletingPathExtension().appendingPathExtension("gpx")
                    try? GPXWriter.write(points: points, to: gpxURL)
                }
            }
            #endif
            dismiss()
            model.setSource(.video(url), mode: camera.activeFormatDescription)
        }
        camera.onFinishPhotos = { urls in
            steadiness.stop()
            // Photo mode never visits Adjust: its burst auto-blends into one
            // image immediately, with the depth already chosen on the capture
            // screen. It also never leaves the camera — the session stays live
            // (no `camera.stop()`, no `dismiss()`) so the next shot can start at
            // once, and the blend runs in the background into a saved project.
            if mode == .photo {
                let depth = photoBlendDepth
                // Blend Off keeps a single frame — the most recent. A capped
                // Photo snapshot already delivers exactly one; an open Bulb run
                // may have captured many, so trim to the last before it stacks.
                let framesToBlend = depth <= 1 ? Array(urls.suffix(1)) : urls
                let shapes = pendingViewfinderShapes
                pendingViewfinderShapes = nil
                Task {
                    await model.processPhotoBurst(
                        urls: framesToBlend, blendDepth: depth, linear: model.linearLight,
                        presentResult: false, viewfinderShapes: shapes)
                }
                return
            }
            camera.stop()
            // Interval tail-frame flag: if the final contiguous run of frames
            // read as shaky at capture time (typically a phone-grab to end the
            // shoot), flag them for a quiet, recoverable review on the Adjust
            // screen. Only Interval sessions log motion; Photo mode runs its own
            // steady gate and auto-stops, so its `captureLog` stays empty here.
            let tail = Self.trailingNoisyCount(
                from: steadiness.captureLog, threshold: steadiness.stillThreshold)
            dismiss()
            // A scan does not go to the blend flow. It is registered, opened in
            // the Scans tab and corrected on its own — see
            // `AppModel.finishScannerCapture`. Every other still shoot takes
            // the unchanged `setSource` path into Adjust.
            if scannerArmed {
                model.finishScannerCapture(
                    urls: urls,
                    mode: intervalSourceModeName,
                    documentStarts: scannerDocumentStarts)
                return
            }
            model.setSource(.photos(urls), mode: intervalSourceModeName)
            // A minimum run of 2 filters a lone bad frame (a passing cloud, a
            // single bump); the half-session ceiling keeps a shaky handheld
            // shoot from reading as a tail event.
            if tail >= 2 && tail < urls.count / 2 {
                model.flagTailFrames(count: tail, total: urls.count)
            }
        }
        camera.onFinishLiveBlend = { result in
            // Photo mode: the live-blend RAW pipeline already produced one
            // blended DNG (the last window if a stop raced an extra one). It IS
            // the photo — register it as a one-asset Photo capture, no further
            // stacking, and keep the camera live for the next shot (the JPEG
            // photo path's behaviour). Blend Off already emitted one untouched
            // DNG, so depth 1 here means "keep the frame as captured".
            if mode == .photo {
                let dngURLs = Array(result.frameURLs.suffix(1))
                guard !dngURLs.isEmpty else { return }
                let shapes = pendingViewfinderShapes
                pendingViewfinderShapes = nil
                Task {
                    await model.processPhotoBurst(
                        urls: dngURLs, blendDepth: 1, linear: model.linearLight,
                        presentResult: false, viewfinderShapes: shapes)
                }
                return
            }
            camera.stop()
            dismiss()
            // The experiment log rides along as a sidecar under its own
            // `liveblend-…json` name: parked beside the frames, where
            // registration picks named sidecars up. Appended to the frame
            // list instead (as it was until 2026-09-05) it was renumbered
            // into `frame-00501.json` — a session document nobody could find.
            if let staging = result.frameURLs.first?.deletingLastPathComponent() {
                let parked = staging.appendingPathComponent(result.logURL.lastPathComponent)
                try? FileManager.default.removeItem(at: parked)
                try? FileManager.default.copyItem(at: result.logURL, to: parked)
            }
            let format = result.outputFormat == "dng" ? "DNG" : "JPEG"
            let blend: String
            switch blendDepth {
            case .fixed(let frames):
                blend = frames > 1 ? " · \(frames)-frame blend" : ""
            case .unthrottled:
                blend = " · Psycho blend"
            case .throttled:
                blend = " · Safe blend"
            case .auto:
                blend = " · Auto blend"
            }
            model.setSource(
                .photos(result.frameURLs),
                mode: "Interval · \(format)\(blend)")
        }
        revalidateSafeDepth()
        orientation = currentCaptureOrientation()
        #if os(iOS)
        // Deliver orientation-change notifications so the grid overlay's aspect
        // stays correct, the preview gets nudged to re-read its window
        // orientation, and capture tagging can follow the physical pose.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        // Seed capture orientation from the physical pose when it's already
        // known (correct under rotation lock), else the interface. Safe to run
        // the full connection + stabilization pass here — capture hasn't
        // started; later rotations only refresh the cache.
        let captureSeed = effectiveCaptureOrientation(device: UIDevice.current.orientation) ?? orientation
        camera.setVideoOrientation(captureSeed)
        #endif
        // A scheduled shoot that is still a long way off gets a cold screen:
        // no session, no preview, no power. Everything above this line has
        // already run — the finish handlers, the Watch mirrors, the idle timer
        // (a standby phone must not lock: it has a shutter to pull) — so
        // leaving standby only owes the camera itself.
        if enterStandbyIfScheduled() { return }
        startCameraSession()
        // Not far enough out for a cold screen, but still a shoot someone
        // armed — the shutter alarm is owed either way.
        armImminentSchedule()
    }

    /// The tail of `configureOnAppear`: bring the capture session up and sync
    /// the things that are derived from it. Split out because cold standby
    /// runs it later — at warm-up, or the moment the schedule is cancelled —
    /// rather than on appear.
    private func startCameraSession() {
        // Before start(): the session log opens there and names the mode.
        syncLoggedCaptureMode()
        camera.start()
        updateAspectPreview()
        syncAppleLog()
        framingStartedAt = Date()
    }

    // MARK: - Scheduled standby

    /// Enter cold standby if there is a schedule far enough out to be worth
    /// powering the camera down for. Returns whether standby was entered.
    ///
    /// `stoppingCamera` is for the case where the schedule is armed on a
    /// screen that is already live — the session has to be told to stop, where
    /// on appear it was simply never started.
    @discardableResult
    private func enterStandbyIfScheduled(stoppingCamera: Bool = false) -> Bool {
        guard !standbyActive, !isCapturing else { return false }
        guard let scheduled = model.scheduledRecording else { return false }
        guard scheduled.secondsUntilStart > Self.standbyMinimumLead else { return false }
        if stoppingCamera {
            camera.endSessionLog()
            camera.stop()
        }
        standbyWarmedUp = false
        standbyActive = true
        armStandbyTimers(for: scheduled)
        LLog(String(format: "standby: armed, T-%.0fs", scheduled.secondsUntilStart))
        return true
    }

    /// A schedule too close for standby to be worth it — or one found on a
    /// screen that opened *inside* the warm-up window, which is the case a
    /// relaunch at T−30 s lands in. The camera is up already; only the
    /// shutter alarm is owed, and no overlay is shown.
    private func armImminentSchedule() {
        guard !standbyActive, !isCapturing, let scheduled = model.scheduledRecording else { return }
        let delay = scheduled.secondsUntilStart
        // A start that came and went while the app was closed is NOT fired
        // hours later. A timelapse is aimed at a particular light; firing a
        // dawn shoot at lunchtime is worse than not firing it, because it
        // also spends the storage and the battery the real one needed. Two
        // minutes of grace covers a relaunch that raced its own alarm.
        guard delay > -120 else {
            model.scheduledRecording = nil
            LLog("standby: dropped a scheduled shoot whose start had already passed")
            return
        }
        cancelStandbyTimers()
        // The session is live, so the fire path owes no bring-up.
        standbyWarmedUp = true
        guard delay > 0 else {
            fireScheduledShoot()
            return
        }
        let timer = Timer(fire: scheduled.startDate, interval: 0, repeats: false) { _ in
            fireScheduledShoot()
        }
        RunLoop.main.add(timer, forMode: .common)
        standbyFireTimer = timer
        LLog(String(format: "standby: shoot armed warm, T-%.0fs", delay))
    }

    /// The two alarms standby runs on. Absolute-time `Timer`s on the common
    /// run-loop mode, like the remote's `scheduleStart`: a finger dragging a
    /// control must not be able to delay the shutter, and a wall-clock fire
    /// date survives the run loop being busy in between.
    private func armStandbyTimers(for scheduled: ScheduledRecording) {
        cancelStandbyTimers()

        let warmAt = scheduled.startDate.addingTimeInterval(-Self.standbyWarmupLead)
        if warmAt.timeIntervalSinceNow > 0 {
            let warmTimer = Timer(fire: warmAt, interval: 0, repeats: false) { _ in
                standbyWarmUp()
            }
            RunLoop.main.add(warmTimer, forMode: .common)
            standbyWarmupTimer = warmTimer
        } else {
            // Inside the warm-up window already (a relaunch at T−30s): the
            // camera is owed immediately, not at a date in the past.
            standbyWarmUp()
        }

        let fireTimer = Timer(fire: scheduled.startDate, interval: 0, repeats: false) { _ in
            fireScheduledShoot()
        }
        RunLoop.main.add(fireTimer, forMode: .common)
        standbyFireTimer = fireTimer
    }

    private func cancelStandbyTimers() {
        standbyWarmupTimer?.invalidate()
        standbyWarmupTimer = nil
        standbyFireTimer?.invalidate()
        standbyFireTimer = nil
    }

    /// T−60 s: bring the session up behind the overlay. The screen stays black
    /// — the point is that the shutter at T=0 meets a camera that has already
    /// configured its format, settled its exposure and opened its session log.
    private func standbyWarmUp() {
        guard standbyActive, !standbyWarmedUp else { return }
        standbyWarmedUp = true
        startCameraSession()
        LLog("standby: warming camera")
    }

    /// T=0. Applies the armed dials, drops the overlay and pulls the shutter.
    private func fireScheduledShoot() {
        guard let scheduled = model.scheduledRecording else {
            exitStandby()
            return
        }
        cancelStandbyTimers()
        // A schedule can only be honoured as an Interval shoot; set the mode
        // first so the mode's own `onChange` (which swaps in that mode's
        // remembered spacing) lands BEFORE the armed spacing is written, and
        // not after it.
        let wasWarm = standbyWarmedUp
        mode = .interval
        model.scheduledRecording = nil
        pendingScheduledStopMinutes = scheduled.durationMinutes
        exitStandby()

        // Two hops on purpose. The first gives the mode switch — and, if this
        // is a device that never got its warm-up (app relaunched seconds
        // before the start), the whole session bring-up — time to land; the
        // second guarantees the dials written above are what the shutter
        // reads. Both are on the main queue, so the order is fixed.
        let settle: TimeInterval = wasWarm ? 0.4 : 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            interval = scheduled.intervalSeconds
            lastFixedInterval = scheduled.intervalSeconds
            if let frames = scheduled.blendDepth {
                blendDepth = .fixed(frames)
                lastFixedBlendFrames = frames
            }
            RecordingSettingsStore.save(intervalSeconds: scheduled.intervalSeconds, for: .interval)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard !isCapturing else { return }
                LLog(String(format: "standby: firing scheduled shoot, every %.1fs",
                            scheduled.intervalSeconds))
                shutterAction()
            }
        }
    }

    /// The user's out. Drops the schedule, the timers and the overlay, and
    /// hands the screen back to a normal, live capture session.
    private func cancelScheduledShoot() {
        cancelStandbyTimers()
        model.scheduledRecording = nil
        pendingScheduledStopMinutes = nil
        exitStandby()
        LLog("standby: cancelled")
    }

    /// Leave standby, starting the camera if the warm-up never got to it.
    /// Brightness is restored by the overlay's own `onDisappear`, so that it
    /// cannot be leaked by an exit path that forgot about it.
    private func exitStandby() {
        standbyActive = false
        if !standbyWarmedUp {
            startCameraSession()
        }
        standbyWarmedUp = false
    }

    /// A scheduled run's duration becomes an ordinary device-owned scheduled
    /// stop, anchored to the run's own start — the same mechanism the remote's
    /// `scheduleStop` uses. It can only be armed once the engine reports a
    /// run, which is a queue hop after the shutter, so it waits on the tick.
    private func applyPendingScheduledStop() {
        guard let minutes = pendingScheduledStopMinutes, isCapturing else { return }
        pendingScheduledStopMinutes = nil
        camera.scheduleStop(unit: .minutes, amount: Double(minutes))
    }

    /// Apple Log is video-only and requires a supporting device: enable it just
    /// for Video mode with Capture Flat on. Still modes get their flatness from
    /// a save-time JPEG grade instead, so Log stays off there.
    private func syncAppleLog() {
        camera.appleLogEnabled = (mode == .video && captureFlat && camera.supportsAppleLog)
    }

    /// True when the next still shoot will capture DNG — the session
    /// should be framing on the full 4:3 sensor, not the 16:9 video format.
    /// Photo and Interval share the gate: both run the same DNG pipeline.
    private var wantsPhotoAspectPreview: Bool {
        guard mode == .interval || mode == .photo else { return false }
        guard camera.liveBlendDNGSupport.isSupported else { return false }
        // Scanner shoots RAW by default whatever the format dial says — the
        // frames are for a solver — so it frames on the sensor too, and the
        // viewfinder shows what the run will really capture rather than the
        // 16:9 crop the video format would have given.
        return model.intervalOutputFormat == .dng || scannerArmed
    }

    /// A Photo shot should land as DNG when the format is selected and the
    /// source can deliver Bayer RAW — the same gate Interval uses.
    private var wantsPhotoDNG: Bool {
        model.intervalOutputFormat == .dng && camera.liveBlendDNGSupport.isSupported
    }

    /// The blend pipeline the current dials would run — the profile pool
    /// Safe mode draws from.
    private var activeBlendPipeline: String {
        model.intervalOutputFormat == .dng && camera.liveBlendDNGSupport.isSupported
            ? "dng" : "standard"
    }

    /// Safe mode needs a usable profile for this device, pipeline, interval
    /// and the thermal conditions right now — it refuses to guess without a
    /// basis, so the menu entry is disabled until Psycho has taught one.
    private var safeDepthAvailable: Bool {
        BlendProfileStore.shared.hasUsableProfile(
            pipeline: activeBlendPipeline,
            bucket: ThermalBucket(thermalState: ProcessInfo.processInfo.thermalState),
            intervalSeconds: interval)
    }

    /// Safe's basis can vanish while it is selected (interval change, format
    /// change, learning reset, a remembered setting from another day): fall
    /// back to the last deliberate fixed choice rather than guessing.
    /// The rate the blend engine's tap can stream at, bounding the fixed
    /// depths the dial offers; nil on the RAW photo path, which has no stream.
    private var blendStreamFPS: Double? {
        let dng = model.intervalOutputFormat == .dng && camera.liveBlendDNGSupport.isSupported
        return dng ? nil : Double(camera.selectedFrameRate)
    }

    /// An interval change can put the chosen fixed count out of the stream's
    /// reach (20 frames every second on a 10 fps stream). Falls to the deepest
    /// count the stream can deliver rather than starting a run that cannot
    /// fill its windows — and says so, since the dial changed under the user.
    private func revalidateFixedDepthAttainable() {
        guard case .fixed(let frames) = blendDepth, frames > 1,
              !StreamRatePlan.isAttainable(frames: frames, intervalSeconds: interval, streamFPS: blendStreamFPS)
        else { return }
        let fallback = BlendDepth.fixedOptions.map(\.frames)
            .filter { $0 < frames && StreamRatePlan.isAttainable(frames: $0, intervalSeconds: interval, streamFPS: blendStreamFPS) }
            .max() ?? 1
        LLog("blend: \(frames) frames every \(interval)s exceeds the \(blendStreamFPS.map { Int($0) } ?? 0) fps stream — depth set to \(fallback)")
        blendDepth = .fixed(fallback)
        lastFixedBlendFrames = fallback
    }

    private func revalidateSafeDepth() {
        if blendDepth == .throttled, !safeDepthAvailable {
            blendDepth = .fixed(lastFixedBlendFrames)
        }
    }

    private func updateAspectPreview() {
        camera.setPhotoAspectPreview(wantsPhotoAspectPreview)
    }

    /// The rig only gets preview frames while there is nothing else going on:
    /// Video mode, idle, and the rig itself still hunting. Everything else —
    /// any capture, other modes, an armed or running rig — detaches the tap so
    /// recordings never carry the extra output.
    private func updateTestCardWatch() {
        if mode == .video && !isCapturing && testRig.wantsFrames {
            camera.startTestCardTap(testRig.tap)
        } else {
            camera.stopTestCardTap()
        }
    }

    private func cleanUpOnDisappear() {
        model.endActivity(.capture)
        // Standby's alarms belong to this screen. The schedule itself is
        // deliberately left standing — closing the capture screen is not
        // cancelling the shoot, and re-opening it re-arms from the stored
        // `scheduledRecording`.
        cancelStandbyTimers()
        standbyActive = false
        standbyWarmedUp = false
        // Idempotent — the finish handlers already stop it, but a mid-session
        // close (or a Photo-mode exit) shouldn't leave motion updates running.
        steadiness.stop()
        camera.stopTestCardTap()
        camera.stopShapeTap()
        camera.setPhotoViewfinder(false)
        // Same reasoning as `steadiness.stop()` above: a mid-session close
        // shouldn't leave the manual-exposure servo timer running against a
        // screen nobody can see.
        if photoManualExposure {
            photoManualExposure = false
            camera.exitPhotoManualExposure()
            camera.setManualExposureDeviceNeeded(false)
        }
        #if os(iOS)
        // The framing tap is an extra session output; leaving it attached
        // past this screen would reconfigure a session the next recording is
        // about to use.
        FramingPreviewService.shared.attach(camera: nil)
        #endif
        // The screen is gone, so the capture session is over however it was
        // left — including the paths that don't stop the camera (Photo mode
        // keeps it live for the next shot). Idempotent with `camera.stop()`.
        camera.endSessionLog()
        #if os(iOS)
        LocationService.shared.stopUpdates()
        watchRemote.setCommandHandler(nil)
        UIApplication.shared.isIdleTimerDisabled = false
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        #endif
    }

    /// The final contiguous run of frames whose capture-time motion exceeded
    /// `threshold`, walking backwards from the last frame. Stops at the first
    /// steady frame, so a single bad frame mid-sequence never counts — only a
    /// genuine tail (the phone-grab that ends a shoot) does.
    static func trailingNoisyCount(
        from log: [(captureIndex: Int, magnitude: Double)],
        threshold: Double
    ) -> Int {
        var count = 0
        for entry in log.reversed() {
            if entry.magnitude > threshold { count += 1 } else { break }
        }
        return count
    }

    // MARK: - Portrait

    private func portraitLayout(in size: CGSize) -> some View {
        VStack(spacing: 0) {
            portraitTopBar
                .frame(height: Self.portraitTopBarHeight)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)

            viewfinder(in: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            portraitControls
                .padding(.top, 10)
                .padding(.bottom, 12)
        }
        .overlay {
            if camera.isAuthorized == false {
                authorizationMessage
            }
        }
    }

    /// The portrait chrome row above the viewfinder. Pinned to the close
    /// button's height so the preview, which is anchored directly under it,
    /// doesn't shift when the shorter recording pill takes that slot.
    private static let portraitTopBarHeight: CGFloat = 38
    /// Where the preview's top edge sits in portrait: the top bar plus its
    /// padding (10 above, 8 below).
    private static var portraitPreviewTopInset: CGFloat { 10 + portraitTopBarHeight + 8 }

    /// Portrait slides the letterboxed preview up so its top edge meets the
    /// top bar instead of sitting centered with a black band above it. All the
    /// slack then collects at the bottom, under the image, where the controls
    /// and the recent-capture tile live. Landscape already fills the height, so
    /// there is nothing to reclaim there.
    /// Whether the viewfinder wears the flat look — mirroring exactly the
    /// conditions under which the delivered file gets the grade, so the
    /// preview never claims a flatness the file won't have. Still modes
    /// (interval in all its dial positions, photo): the save-time grade
    /// applies to JPEG output only. Video: Apple Log previews are already
    /// flat at the sensor — the approximation would double-apply — so only
    /// the software-flatten selections (no Log at this resolution/rate, or
    /// no Log hardware) show it.
    private var previewShowsFlat: Bool {
        guard captureFlat else { return false }
        if mode == .video {
            return !camera.appleLogAvailableForSelection
        }
        return model.intervalOutputFormat == .jpeg
    }

    private func previewTopAnchorOffset(in size: CGSize) -> CGFloat {
        guard size.height > size.width else { return 0 }
        let fitted = aspectFitSize(
            aspectRatio: previewAspectRatio,
            maxWidth: size.width,
            maxHeight: size.height
        )
        let letterbox = (size.height - fitted.height) / 2
        // Never push it down: a preview taller than the screen already starts
        // above the top bar.
        return min(0, Self.portraitPreviewTopInset - letterbox)
    }

    private var portraitTopBar: some View {
        HStack {
            if camera.isRecording {
                recordingPill
            } else {
                CameraChromeButton(systemImage: "xmark") {
                    closeCapture()
                }
                .accessibilityLabel("Close capture")
                scheduleShootButton
            }

            Spacer(minLength: 8)

            // The two chips are sized as a pair so the headroom readout gives
            // ground rather than the format pill. A ramp shoot's pill can carry
            // four tokens ("1080p · 25 · ↑4K · Stab") and a Scanner shoot's
            // sensor frame is long too; with the close button and a full
            // headroom chip that is more than a 393 pt screen holds. The order
            // of surrender is deliberate — the free-space half first, since the
            // shot count is the part you act on, and the whole chip only if
            // even that doesn't fit. The pill never gives ground: it is a
            // control, and the thing beside it is a readout.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    headroomChip(compact: false)
                    formatPill
                }
                HStack(spacing: 8) {
                    headroomChip(compact: true)
                    formatPill
                }
                formatPill
            }
        }
    }

    /// Arms a shoot for a wall-clock time. Interval only — a schedule fires
    /// the interval engine — and idle only: a running shoot has nothing to
    /// schedule, and the button's slot belongs to the recording pill anyway.
    @ViewBuilder
    private var scheduleShootButton: some View {
        if mode == .interval && !isCapturing {
            CameraChromeButton(systemImage: "clock") {
                showScheduleSheet = true
            }
            .accessibilityLabel("Schedule shoot")
        }
    }

    /// The storage-headroom readout, immediately ahead of the format pill that
    /// governs it. Drawn during a run as well as before one — a long interval
    /// shoot is exactly the case where watching the number come down is worth
    /// more than knowing where it started.
    @ViewBuilder
    private func headroomChip(compact: Bool = false) -> some View {
        if let headroom {
            CaptureHeadroomChip(reading: headroom, showsFreeSpace: !compact)
                .equatable()
        }
    }

    private var portraitControls: some View {
        VStack(spacing: 13) {
            remoteLinkChip
            thermalWarningChip()
            if testRig.phase != .idle {
                testCardChip
            }
            if mode == .video {
                if camera.isRecording {
                    // The speed → playback-seconds row is behind the cluster's
                    // Info toggle (design 2026-09-04, third pass); the strip
                    // always shows.
                    if showRunInfo {
                        speedMarquee
                    }
                    segmentStrip
                        .padding(.horizontal, 16)
                } else {
                    speedChipsRow
                }
            } else if mode == .photo {
                if burstPillPhase != .hidden && burstPillMode == .photo {
                    burstStatusPill
                } else if !isCapturing {
                    photoControlsRow
                }
            } else {
                intervalStatusRow
            }

            if !isCapturing || (burstPillPhase != .hidden && burstPillMode == .photo) {
                modeRow
                    // The design keeps the mode row on screen under a running
                    // Photo burst, but inert — mid-run mode or lens switches
                    // are the shutter's call, not a tap's. (Interval runs
                    // keep hiding it, as before.)
                    .disabled(isCapturing)
            }

            #if os(iOS)
            exposurePanel
            #endif

            // Shutter row. The shutter cluster itself — ring plus its four
            // slots — is not laid out here: `shutterClusterLayer` pins it to
            // the device so rotation never moves it. This row only reserves
            // the cluster's height and keeps the recent-capture tile on the
            // ring's centreline, 16 pt in.
            HStack(spacing: 0) {
                recentCaptureButton
                    .frame(width: Self.recentTileSize)
                Spacer()
            }
            .frame(height: Self.shutterRowHeight)
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Landscape (side rails: thumbs on edges, image untouched)

    /// Which long edge the pinned shutter cluster sits on in landscape: the
    /// home-indicator edge, which is the LEADING edge when the interface is
    /// `.landscapeLeft` (phone turned clockwise, notch on the right). The two
    /// rails swap sides with it, the way the system camera's do, so the
    /// close/format/tile rail never lands under the cluster. Never on the
    /// Mac: no edge to pin to, the cluster keeps the trailing side.
    private var shutterClusterLeads: Bool {
        #if os(iOS)
        _ = orientation
        return currentInterfaceOrientation() == .landscapeLeft
        #else
        return false
        #endif
    }

    private func landscapeLayout(in size: CGSize) -> some View {
        let clusterLeads = shutterClusterLeads
        return HStack(spacing: 0) {
            if clusterLeads {
                landscapeModeRail
            } else {
                landscapeChromeRail(anchor: .leading)
            }

            // Viewfinder with the estimate/interval chips in the safe corner
            viewfinder(in: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) {
                    Group {
                        if mode == .video {
                            // Same swap portrait makes: the idle estimates give
                            // way to the run's own readout once recording.
                            if camera.isRecording {
                                landscapeRecordingReadout
                            } else {
                                landscapeEstimateChips
                            }
                        } else if mode == .photo {
                            if burstPillPhase != .hidden && burstPillMode == .photo {
                                burstStatusPill
                            } else if !isCapturing {
                                photoControlsRow
                            }
                        } else {
                            landscapeIntervalRow
                        }
                    }
                    .padding(10)
                }

            if clusterLeads {
                landscapeChromeRail(anchor: .trailing)
            } else {
                landscapeModeRail
            }
        }
        .overlay {
            if camera.isAuthorized == false {
                authorizationMessage
            }
        }
    }

    /// The chrome rail: close (or the recording pill) and schedule, the format
    /// pill and headroom chip, the lens chips, the remote and thermal chips,
    /// the recent-capture tile. Normally the leading rail; it moves to the
    /// trailing side when the cluster takes the leading edge.
    ///
    /// The pills and chips are ANCHORED to the rail's outer edge, not centred
    /// (design 2026-09-04): the rail is 108 pt and a format string is often
    /// wider, and a centred pill spilt off the screen — "3840×2160 · JPEG"
    /// lost its first digit on every phone, iPad and Mac. Anchored 16 pt in
    /// from the outer edge (the safe area's own inset sits outside this
    /// stack) and aligned with each other, a wide pill overhangs the
    /// viewfinder instead, which is allowed. The rail's other items keep
    /// their centred seats.
    private func landscapeChromeRail(anchor: HorizontalAlignment) -> some View {
        VStack(alignment: anchor) {
            // The centred seats are given the column's own width, not
            // `maxWidth: .infinity`: the stack is as wide as its widest
            // pill, and an infinite frame would centre them in THAT.
            if camera.isRecording {
                recordingPill
                    .frame(width: Self.chromeRailWidth)
            } else {
                CameraChromeButton(systemImage: "xmark") {
                    closeCapture()
                }
                .frame(width: Self.chromeRailWidth)
                scheduleShootButton
                    .padding(.top, 10)
                    .frame(width: Self.chromeRailWidth)
            }
            Spacer()
            VStack(alignment: anchor, spacing: 8) {
                formatPill
                headroomChip(compact: true)
            }
            .railAnchored(anchor)
            Spacer()
            if !isCapturing {
                zoomChips
                    .frame(width: Self.chromeRailWidth)
            }
            // Same edge, full size: the 0.85 scale it used to wear existed
            // only because the rail was too narrow for it.
            remoteLinkChip
                .railAnchored(anchor)
                .padding(.top, 10)
            // The compact form carries the heat word, the full sentence
            // lives in portrait.
            thermalWarningChip(compact: true)
                .railAnchored(anchor)
                .padding(.top, 6)
            // The rail's bottom corner, as portrait's lower-left.
            recentCaptureButton
                .padding(.top, 14)
                .frame(width: Self.chromeRailWidth)
        }
        .padding(.vertical, 16)
        // The stack is as wide as its widest pill; the column is 108 pt.
        // Aligned by the anchor edge, the stack's overflow all goes inward —
        // a plain `.frame(width:)` would centre it and push the pills (and
        // everything else) outward, off the screen, which is exactly the
        // clipping this rail is here to end.
        .frame(width: Self.chromeRailWidth, alignment: Alignment(horizontal: anchor, vertical: .center))
        // Over the viewfinder column, so an overhanging pill draws above the
        // chrome in that corner rather than under it.
        .zIndex(1)
    }

    /// The landscape chrome rail's column: what the viewfinder is laid out
    /// against, whatever a pill inside it measures.
    private static let chromeRailWidth: CGFloat = 108

    /// The mode rail: the stacked PHOTO / INTERVAL / VIDEO labels. The shutter
    /// cluster that used to hang under them is pinned to the device by
    /// `shutterClusterLayer` now (its ring lands mid-height on this edge), so
    /// the rail only keeps the column's width for the viewfinder's sake.
    private var landscapeModeRail: some View {
        VStack {
            landscapeModeToggle
            Spacer()
        }
        .padding(.vertical, 16)
        .frame(width: 118)
    }

    /// Stacked upright mode labels for the rail — the words must stay readable
    /// in landscape, so they stack vertically instead of rotating 90°.
    private var landscapeModeToggle: some View {
        VStack(spacing: 10) {
            Button {
                guard !isCapturing else { return }
                mode = .photo
            } label: {
                Text("PHOTO")
                    .foregroundStyle(mode == .photo ? LL.amber : .white.opacity(0.5))
            }
            .buttonStyle(.plain)

            Button {
                guard !isCapturing else { return }
                mode = .interval
            } label: {
                Text("INTERVAL")
                    .foregroundStyle(mode == .interval ? LL.amber : .white.opacity(0.5))
            }
            .buttonStyle(.plain)

            Button {
                guard !isCapturing else { return }
                mode = .video
            } label: {
                Text("VIDEO")
                    .foregroundStyle(mode == .video ? LL.amber : .white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11, weight: .bold))
        .kerning(0.6)
    }

    private var landscapeEstimateChips: some View {
        HStack(spacing: 6) {
            if let neighbor = neighborSpeeds.first {
                CameraPill(
                    text: "\(neighbor)× → \(estimateText(for: neighbor))",
                    tint: .white.opacity(0.7),
                    monospaced: true
                )
            }
            CameraPill(
                text: "\(model.constantWindow)× → \(estimateText(for: model.constantWindow))",
                tint: LL.amber,
                bold: true,
                monospaced: true
            )
        }
    }

    /// How wide the landscape readout is allowed to grow. The strip is a
    /// timeline, so width is resolution — but it rides over the live image
    /// here, and an unbounded panel would stretch the length of a Mac window.
    /// 560 pt is comfortably wider than portrait's 361 and still leaves clear
    /// frame beside it on a phone.
    private static let landscapeReadoutMaxWidth: CGFloat = 560

    /// Landscape and macOS twin of portrait's recording readout — the same
    /// `speedMarquee` over the same `segmentStrip`, in the same order. Portrait
    /// stacks them in the letterbox under the image; the side rails leave no
    /// letterbox here, so the pair rides the viewfinder's bottom-leading corner
    /// on the dark panel the rest of the landscape chrome uses to stay legible
    /// over live picture. Nothing is dropped for the smaller slot: the burst
    /// spans are what let you balance the end of a take, and the marquee still
    /// swaps to the elapsed/target line when a target is set.
    private var landscapeRecordingReadout: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showRunInfo {
                speedMarquee
            }
            segmentStrip
        }
        .frame(maxWidth: Self.landscapeReadoutMaxWidth, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Color.black.opacity(0.5),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    // MARK: - Viewfinder

    /// The viewfinder region. Transparent — the live preview shows through from
    /// the persistent layer behind `body`'s ZStack; only the grid draws here.
    /// It also hosts the framing gestures: swipe between modes, pinch through
    /// the lenses.
    private func viewfinder(in screenSize: CGSize) -> some View {
        GeometryReader { geometry in
            // The grid has to trace the live image, so it is measured the way
            // the preview is: in portrait against the whole screen, then pinned
            // to the top of this region — which begins exactly where the
            // top-anchored preview does. Landscape leaves both centered.
            let isPortrait = screenSize.height > screenSize.width
            let fitted = aspectFitSize(
                aspectRatio: previewAspectRatio,
                maxWidth: isPortrait ? screenSize.width : geometry.size.width,
                maxHeight: isPortrait ? screenSize.height : geometry.size.height
            )
            ZStack {
                Color.clear
                if gridOverlay != .off {
                    RuleOfThirdsGrid()
                        .frame(width: fitted.width, height: fitted.height)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: isPortrait ? .top : .center
                        )
                }
                if gridOverlay == .level {
                    LevelIndicatorOverlay()
                        .frame(width: fitted.width, height: fitted.height)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: isPortrait ? .top : .center
                        )
                }
                // Auto shape mode: the shapes the live pass is following,
                // traced over the picture and mapped point by point through
                // the preview layer exactly as the Scanner's quad is. Tapping
                // one dismisses it, so unlike the quad this layer takes hits.
                if mode == .photo && autoShapesEnabled && !isCapturing {
                    LiveShapesOverlay(finder: liveShapes) {
                        liveShapeOverlayPoint($0, region: geometry, screenSize: screenSize)
                    }
                    .transition(.opacity)
                }
                // A DNG lens change reconnects the physical camera — the one
                // transition the zoom ramp can't cover. Dip instead of
                // showing the old lens's live feed and a hard cut.
                if camera.isSwitchingLens {
                    Color.black.opacity(0.85)
                        .allowsHitTesting(false)
                }
                if let reticle = focusReticle {
                    FocusReticleView()
                        .position(reticle.point)
                        .id(reticle.id)
                        .allowsHitTesting(false)
                }
                #if os(iOS)
                // The Scanner's quad, traced over the live page — in this
                // region's own coordinates, mapped corner by corner through the
                // preview layer (see `scannerOverlayCorners`). It fills the
                // region rather than a hand-fitted rect because the letterbox
                // is no longer the view's to guess at.
                if let quad = scannerOverlayQuad {
                    ScannerRectangleOverlay(
                        corners: scannerOverlayCorners(
                            quad, region: geometry, screenSize: screenSize))
                        // Never in the way of a focus tap or the HUD: the
                        // overlay is picture, not chrome.
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                #endif
                // The armed light panel (or its pill) rides the viewfinder's
                // top-leading corner in both orientations — see
                // `ladderViewfinderOverlays` for the two insets.
                ladderViewfinderOverlays(portrait: screenSize.width <= screenSize.height)
            }
            .animation(.easeInOut(duration: 0.16), value: camera.isSwitchingLens)
            // Corner-to-corner interpolation, so a page being nudged reads as
            // the quad following it rather than as a new quad each frame.
            .animation(.easeOut(duration: 0.12), value: scannerOverlayQuad)
            .frame(width: geometry.size.width, height: geometry.size.height)
            // The whole region takes the tap, not just whatever is drawn in it.
            .contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    // A tap on a traced LINE dismisses that shape and is not a
                    // focus tap (see `LiveShapePlacement.hit`); a tap on the
                    // picture inside or beside it focuses, as it always did.
                    if let placements = liveShapePlacements(region: geometry, screenSize: screenSize),
                       let id = LiveShapePlacement.hit(at: value.location, in: placements) {
                        liveShapes.dismiss(id)
                        return
                    }
                    #if os(iOS)
                    focusTap(at: value.location, region: geometry, screenSize: screenSize)
                    #endif
                }
            )
        }
        .contentShape(Rectangle())
        .simultaneousGesture(modeSwipeGesture)
        .simultaneousGesture(lensPinchGesture)
        // A pin the user gave up on (either unlock button, the focus slider)
        // takes its reticle with it.
        .onChange(of: camera.isFocusPinnedByTap) { pinned in
            if !pinned { focusReticle = nil }
        }
    }

    /// The quad to draw over the live image, or nil. Only under Scanner: the
    /// detector doesn't run in any other mode, and a stale quad surviving a
    /// mode switch would be drawing something the camera is no longer watching.
    private var scannerOverlayQuad: NormalizedQuad? {
        scannerArmed ? camera.scannerRectangle : nil
    }

    #if os(iOS)
    /// Where the detected page's four corners land **in the viewfinder region's
    /// own coordinates**.
    ///
    /// The chain, and why each link is there:
    ///
    /// 1. Vision reported the corners in the *oriented* image it was handed —
    ///    the run's capture pose (`camera.scannerRectangleOrientation`), which
    ///    is the pose the still is written at and need not be the pose the
    ///    preview is drawn at. `sensorCorners(measuredIn:)` un-turns them into
    ///    the camera's own landscape space with a top-left origin, which is
    ///    exactly the "capture device point" AVFoundation speaks.
    /// 2. `layerPointConverted(fromCaptureDevicePoint:)` puts that on glass.
    ///    **This is the only thing that knows the letterbox** — the video
    ///    gravity (`.resizeAspect` here), the bars it leaves, the connection's
    ///    own rotation and any mirroring. It is the same conversion
    ///    tap-to-focus runs in reverse, so the overlay and a focus tap can no
    ///    longer disagree about where a point on the picture is.
    /// 3. The preview layer fills the whole capture stage and is then slid up
    ///    (`previewTopAnchorOffset`), so undoing that slide and this region's
    ///    own origin lands the point here. Exactly `focusTap`'s arithmetic,
    ///    read backwards.
    ///
    /// Without a live connection — the simulator, or before the session has
    /// configured — step 2 has nothing to convert against, so it falls back to
    /// fitting the image into this region by hand. That path is what the
    /// `LL_SCANNER_RECT` screenshot hook draws, and it still converts the
    /// orientation, because a staged quad is in capture space like a real one.
    private func scannerOverlayCorners(
        _ quad: NormalizedQuad, region: GeometryProxy, screenSize: CGSize
    ) -> ScannerQuadCorners {
        let sensor = quad.sensorCorners(measuredIn: camera.scannerRectangleOrientation)
        let frame = region.frame(in: .named(Self.stageSpace))

        if let layer = camera.previewLayer, layer.connection != nil,
           layer.bounds.width > 1, layer.bounds.height > 1 {
            let slide = previewTopAnchorOffset(in: screenSize)
            func map(_ point: NormalizedQuad.Point) -> CGPoint {
                let onLayer = layer.layerPointConverted(fromCaptureDevicePoint: point.cgPoint)
                return CGPoint(x: onLayer.x - frame.minX, y: onLayer.y + slide - frame.minY)
            }
            return ScannerQuadCorners(
                topLeft: map(sensor.topLeft), topRight: map(sensor.topRight),
                bottomRight: map(sensor.bottomRight), bottomLeft: map(sensor.bottomLeft))
        }

        // Fallback. The quad is restated in the *preview's* orientation and laid
        // on the image rect worked out the way the preview layer lays itself
        // out: `.resizeAspect` centres the image in the **stage** — which the
        // layer fills — and the top-anchor offset then slides the finished
        // layer up. Both are in stage coordinates, so this region's own origin
        // comes off last.
        //
        // Not the region's own rect, which is what this drew before and is
        // wrong twice over: in portrait the region starts below the top bar
        // while the picture starts at its letterbox (23 pt apart on an iPhone
        // 17 Pro), and in landscape the region sits between a 108 pt rail and a
        // 118 pt one, so its centre is 5 pt off the picture's.
        let preview = quad.converted(
            from: camera.scannerRectangleOrientation,
            to: QuadOrientation(captureOrientation: orientation))
        let fitted = aspectFitSize(
            aspectRatio: previewAspectRatio,
            maxWidth: screenSize.width, maxHeight: screenSize.height)
        let origin = CGPoint(
            x: (screenSize.width - fitted.width) / 2 - frame.minX,
            y: (screenSize.height - fitted.height) / 2
                + previewTopAnchorOffset(in: screenSize) - frame.minY)
        func map(_ point: NormalizedQuad.Point) -> CGPoint {
            CGPoint(
                x: origin.x + CGFloat(point.x) * fitted.width,
                // The one flip: the corners keep Vision's bottom-left origin
                // all the way to Core Image (see `NormalizedQuad`), and
                // SwiftUI's y runs the other way.
                y: origin.y + CGFloat(1 - point.y) * fitted.height)
        }
        return ScannerQuadCorners(
            topLeft: map(preview.topLeft), topRight: map(preview.topRight),
            bottomRight: map(preview.bottomRight), bottomLeft: map(preview.bottomLeft))
    }
    #endif

    #if os(iOS)
    /// Tap the viewfinder to focus there. The camera refuses this outright once
    /// a shoot is running — focus is locked for the whole of one — so the
    /// reticle is only drawn for a tap that was actually accepted.
    private func focusTap(at point: CGPoint, region: GeometryProxy, screenSize: CGSize) {
        // This region's origin gets the tap into stage space; undoing the
        // top-anchor slide gets it into the preview layer's, which is where the
        // layer's own conversion starts from.
        let frame = region.frame(in: .named(Self.stageSpace))
        let layerPoint = CGPoint(
            x: point.x + frame.minX,
            y: point.y + frame.minY - previewTopAnchorOffset(in: screenSize)
        )
        guard camera.focusPreview(atLayerPoint: layerPoint) else { return }
        focusReticle = FocusReticle(point: point)
    }
    #endif

    // MARK: - Auto shape mode

    /// Auto shape mode's tracks placed in this region, or nil while the layer
    /// is not showing: another mode, the toggle off, a capture in flight (the
    /// tap is detached for it and the last tracks would freeze on screen), or
    /// nothing confirmed yet.
    private func liveShapePlacements(region: GeometryProxy, screenSize: CGSize) -> [LiveShapePlacement]? {
        guard mode == .photo, autoShapesEnabled, !isCapturing else { return nil }
        let tracks = liveShapes.visible
        guard !tracks.isEmpty else { return nil }
        return LiveShapePlacement.place(
            tracks, orientation: liveShapes.orientation, frameSize: liveShapes.frameSize
        ) { liveShapeOverlayPoint($0, region: region, screenSize: screenSize) }
    }

    /// A point in the sensor's own space (its landscape read-out, top-left
    /// origin) on this region — `scannerOverlayCorners`' chain for one point:
    /// the preview layer converts it (the only thing that knows the letterbox,
    /// the gravity and the connection's rotation), then the top-anchor slide
    /// and this region's origin come off. Without a live connection (the
    /// simulator) the point is restated in the preview's orientation and laid
    /// on an aspect-fitted picture the way the layer would lay itself out.
    private func liveShapeOverlayPoint(_ sensor: CGPoint, region: GeometryProxy, screenSize: CGSize) -> CGPoint {
        let frame = region.frame(in: .named(Self.stageSpace))
        let slide = previewTopAnchorOffset(in: screenSize)
        #if os(iOS)
        if let layer = camera.previewLayer, layer.connection != nil,
           layer.bounds.width > 1, layer.bounds.height > 1 {
            let onLayer = layer.layerPointConverted(fromCaptureDevicePoint: sensor)
            return CGPoint(x: onLayer.x - frame.minX, y: onLayer.y + slide - frame.minY)
        }
        #endif
        // The Mac has no layer hand-over (`CameraController.previewLayer` is
        // iOS-only), so it always takes this fitted path; its pose is the
        // read-out itself, so nothing turns.
        let preview = QuadOrientation(pose: orientation).uprightPoint(fromSensor: sensor)
        let fitted = aspectFitSize(
            aspectRatio: previewAspectRatio, maxWidth: screenSize.width, maxHeight: screenSize.height)
        let origin = CGPoint(
            x: (screenSize.width - fitted.width) / 2 - frame.minX,
            y: (screenSize.height - fitted.height) / 2 + slide - frame.minY)
        return CGPoint(x: origin.x + preview.x * fitted.width, y: origin.y + preview.y * fitted.height)
    }

    /// The live pass runs only while there is nothing else going on: Photo
    /// mode, idle, toggle on. Everything else detaches the tap — the same rule
    /// as the test-card and framing taps, for the same reason (an output added
    /// or removed under a capture reconfigures the session).
    private func updateShapeWatch() {
        if mode == .photo && !isCapturing && autoShapesEnabled {
            liveShapes.search = shapeSearch
            liveShapes.setCaptureOrientation(livePassPose)
            camera.startShapeTap(liveShapes.tap)
        } else {
            camera.stopShapeTap()
        }
    }

    /// The pose a still captured now would be tagged with — the camera's own
    /// reading on iOS (kept current by the orientation handler above), the
    /// read-out itself on a Mac.
    private var livePassPose: AVCaptureVideoOrientation {
        #if os(iOS)
        camera.currentCaptureOrientation
        #else
        .landscapeRight
        #endif
    }

    /// The shutter's moment: what the viewfinder has on screen goes with the
    /// capture to `processPhotoBurst`, which registers the photo and writes
    /// the register. Taken here — after the self-timer, before the engine
    /// starts — because the capture start detaches the tap and the tracks
    /// would otherwise age out before the finish handler runs.
    private func takeViewfinderShapes() {
        guard mode == .photo, autoShapesEnabled else {
            pendingViewfinderShapes = nil
            camera.shapeSearchTokenForNextRun = nil
            return
        }
        pendingViewfinderShapes = liveShapes.snapshot()
        // The dials ride into the capture's `capture_log.json` too, so the
        // conditions record can be read on its own.
        camera.shapeSearchTokenForNextRun = liveShapes.search.token
        pendingViewfinderShapes?.horizontalFieldOfView = camera.currentHorizontalFieldOfView
        if let shapes = pendingViewfinderShapes {
            LLog(String(format: "shapes: shutter with %d kept, %d dismissed (%@), lens %.1f° wide, %d of %d samples found anything",
                        shapes.kept.count, shapes.dismissed.count, shapes.search.token, shapes.horizontalFieldOfView ?? 0,
                        shapes.samplesWithShapes, shapes.samples))
        }
    }

    /// Swipe across the viewfinder to change modes, matching the mode row's
    /// order (PHOTO · INTERVAL · VIDEO): swipe left steps right along the row,
    /// swipe right steps left. The 40 pt floor keeps taps and menu touches free.
    private var modeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                guard !isCapturing else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 60 else { return }
                stepMode(forward: dx < 0)
            }
    }

    /// The mode row's left-to-right order — swipes and the selector share it.
    private static let modeOrder: [CaptureMode] = [.photo, .interval, .video]

    private func stepMode(forward: Bool) {
        guard let index = Self.modeOrder.firstIndex(of: mode) else { return }
        let next = forward ? index + 1 : index - 1
        guard Self.modeOrder.indices.contains(next) else { return }
        mode = Self.modeOrder[next]
    }

    /// Pinch steps through the lens stops one per threshold crossed, in the
    /// direction native Camera uses: fingers moving **apart** step tighter
    /// (1× → 3×), fingers moving **together** step wider (1× → 0.5×), stopping
    /// at the ends. Stated as finger movement rather than "pinch in/out" on
    /// purpose — that wording is ambiguous enough to have hidden this being
    /// backwards through a whole field test. Each step is a zoom ramp, so a
    /// fast pinch reads as continuous.
    private var lensPinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard !isCapturing, camera.availableStops.count > 1 else { return }
                let threshold: CGFloat = 1.35
                while value / pinchBaseline > threshold {
                    pinchBaseline *= threshold
                    stepLens(tighter: true)
                }
                while value / pinchBaseline < 1 / threshold {
                    pinchBaseline /= threshold
                    stepLens(tighter: false)
                }
            }
            .onEnded { _ in
                pinchBaseline = 1
            }
    }

    private func stepLens(tighter: Bool) {
        let stops = camera.availableStops
        guard let selected = camera.selectedStop,
              let index = stops.firstIndex(of: selected) else { return }
        let next = tighter ? index + 1 : index - 1
        guard stops.indices.contains(next) else { return }
        camera.selectStop(stops[next])
    }

    private var previewAspectRatio: CGFloat {
        // The letterbox follows what the sensor is actually delivering
        // (4:3 while a DNG shoot is armed), not the video-format selection.
        let resolution = camera.previewDimensions ?? camera.selectedResolution
        let width = CGFloat(max(resolution.width, 1))
        let height = CGFloat(max(resolution.height, 1))
        return orientation == .portrait || orientation == .portraitUpsideDown
            ? height / width
            : width / height
    }

    private func aspectFitSize(aspectRatio: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        let widthFromHeight = maxHeight * aspectRatio
        if widthFromHeight <= maxWidth {
            return CGSize(width: widthFromHeight, height: maxHeight)
        }
        return CGSize(width: maxWidth, height: maxWidth / max(aspectRatio, 0.01))
    }

    // MARK: - Pills & chrome

    private var recordingPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Text(elapsedRecordingTime)
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.16), in: Capsule())
        .overlay(Capsule().stroke(Color.red.opacity(0.5), lineWidth: 1))
    }

    private var formatPill: some View {
        Button {
            guard !isCapturing else { return }
            showFormatSheet = true
        } label: {
            HStack(spacing: 4) {
                Text(formatSummary)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCapturing ? .white.opacity(0.55) : .white)
                // A run whose bursts change resolution has two formats, and a
                // pill that named only one would be wrong for part of every
                // clip. Shown while idle as a statement of intent; once
                // recording, `formatSummary` names the segment actually being
                // written, so repeating it here would only be noise. Amber like
                // the other tokens that change what lands on disk, and its own
                // atom so the landscape rail can't split it.
                if mode == .video, sequenceMode == .ramp,
                   camera.burstChangesResolution, !isCapturing {
                    Text("· ↑\(camera.selectedBurstResolution.label)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isCapturing ? LL.amber.opacity(0.6) : LL.amber)
                }
                if camera.supportsVideoStabilization && camera.isVideoStabilizationEnabled && mode == .video {
                    Text("· Stab")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isCapturing ? LL.amber.opacity(0.6) : LL.amber)
                }
                if mode == .interval || mode == .photo {
                    // The output format is part of the pill in the still modes —
                    // DNG in amber (it changes what lands on disk), JPEG in
                    // the ordinary weight. Photo mirrors Interval exactly.
                    // Scanner defaults to RAW regardless of the dial (see
                    // `scannerCapturesRAW`), so the pill names what will
                    // actually land rather than what the dial happens to say.
                    if scannerCapturesRAW
                        || (model.intervalOutputFormat == .dng && camera.liveBlendDNGSupport.isSupported) {
                        Text("· DNG")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isCapturing ? LL.amber.opacity(0.6) : LL.amber)
                    } else {
                        Text("· JPEG")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isCapturing ? .white.opacity(0.55) : .white)
                    }
                }
                Image(systemName: isCapturing ? "lock.fill" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            // The landscape rail is 108pt and the pill's natural width is more
            // than that, so without this SwiftUI compresses each Text in turn
            // and breaks them mid-word — the "108 / 0p · / 15" the pill has
            // been showing on the Mac and in landscape on iOS. These tokens
            // are atoms: they lay out at their ideal width or not at all.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Capture format")
    }

    /// Video reads "1080p · 30"; the still modes drop the frame rate —
    /// stills have no base rate, the pill's trailing token carries the
    /// format — and state pixels ("1920×1080"), not the video names.
    /// With DNG armed the shoot captures the full sensor, so the pill
    /// presents the sensor frame ("12MP 4:3"), not the video format.
    private var formatSummary: String {
        if mode == .video {
            // Mid-run this names the segment being written, not the base
            // selection — the same way the rate already flips to the burst's.
            // On a mixed-resolution run the pill therefore reads "1080p · 25"
            // and then "4K · 100" for the length of each burst.
            let resolution = camera.activeSegmentResolution ?? camera.selectedResolution
            return "\(resolution.label) · \(camera.selectedFrameRate)"
        }
        if scannerCapturesRAW || (model.intervalOutputFormat == .dng
                                  && camera.liveBlendDNGSupport.isSupported),
           let sensor = camera.liveBlendDNGSupport.sensorDimensions {
            return sensorSummaryLabel(sensor)
        }
        return camera.selectedResolution.stillLabel
    }

    // MARK: - Storage headroom

    /// How often free space is re-read while this screen is up. A `statfs` is
    /// cheap but not free, and the answer moves at the pace of a shoot rather
    /// than the pace of the 0.5 s tick that asks for it.
    private static let headroomSampleSeconds: TimeInterval = 5

    /// The armed configuration, reduced to what decides its weight on disk.
    ///
    /// Deliberately built from the same facts `formatSummary` puts on the pill
    /// beside it — the sensor frame under DNG, the video format otherwise —
    /// so the chip is always costing the frame the pill is naming. Two
    /// readouts in one corner disagreeing about which format is armed would be
    /// worse than either of them alone.
    private var headroomCostKey: CaptureCostKey {
        if mode == .video {
            let resolution = camera.activeSegmentResolution ?? camera.selectedResolution
            return CaptureCostKey(
                family: resolution.isProRes ? .proRes : .movie,
                width: Int(resolution.width),
                height: Int(resolution.height),
                frameRate: camera.selectedFrameRate)
        }
        if scannerCapturesRAW || (model.intervalOutputFormat == .dng
                                  && camera.liveBlendDNGSupport.isSupported) {
            let sensor = camera.liveBlendDNGSupport.sensorDimensions ?? camera.selectedResolution
            return CaptureCostKey(
                family: .raw,
                width: Int(sensor.width), height: Int(sensor.height), frameRate: 0)
        }
        return CaptureCostKey(
            family: .still,
            width: Int(camera.selectedResolution.width),
            height: Int(camera.selectedResolution.height),
            frameRate: 0)
    }

    /// Re-derives the headroom reading, re-reading free space at most every
    /// `headroomSampleSeconds`.
    ///
    /// The two halves are throttled separately on purpose. Free space is a
    /// disk call and moves slowly; the *cost* is pure arithmetic and moves the
    /// instant a dial does, so a format change re-prices the space we already
    /// know about without waiting for the next sample. Turning DNG on should
    /// change this number under your thumb.
    private func refreshHeadroom(force: Bool = false) {
        let key = headroomCostKey
        let encoderRate = mode == .video ? camera.movieBytesPerSecond : nil
        let cost = CaptureHeadroom.cost(for: key, encoderBytesPerSecond: encoderRate)
        let sampledAt = headroomSampledAt
        let due = force || sampledAt.map { Date().timeIntervalSince($0) >= Self.headroomSampleSeconds } ?? true
        guard due else {
            if let known = headroom?.freeBytes {
                headroom = CaptureHeadroom.Reading(freeBytes: known, cost: cost)
            }
            return
        }
        headroomSampledAt = Date()
        let root = model.projectsFolderURL
        Task {
            guard let free = await CaptureHeadroom.freeBytes(near: root) else { return }
            headroom = CaptureHeadroom.Reading(freeBytes: free, cost: cost)
        }
    }

    /// Notes what the disk looked like as a run began, so the run can be
    /// weighed when it ends. Both halves are snapshotted here rather than read
    /// back later: the format dials are live controls, and a run that ended in
    /// a different configuration from the one it started in would otherwise
    /// teach the store a cost under the wrong key.
    private func beginHeadroomRunSample() {
        runCostKey = headroomCostKey
        runStartFreeBytes = headroom?.freeBytes
        runStartedAt = Date()
        let root = model.projectsFolderURL
        Task {
            guard let free = await CaptureHeadroom.freeBytes(near: root) else { return }
            // Only if the run is still going: a very short shoot can finish
            // before this lands, and overwriting the start figure then would
            // measure the run against its own end.
            if isCapturing { runStartFreeBytes = free }
        }
    }

    /// Weighs the run that just ended and folds it into the cost store.
    ///
    /// Called with the output counters still holding their final values —
    /// `CameraController` clears them at the *start* of the next run, not the
    /// end of this one — so the count read here is the whole run's.
    private func endHeadroomRunSample(frames: Int, seconds: Double) {
        defer {
            runStartFreeBytes = nil
            runCostKey = nil
            runStartedAt = nil
            refreshHeadroom(force: true)
        }
        guard let key = runCostKey, let startFree = runStartFreeBytes else { return }
        let root = model.projectsFolderURL
        Task {
            guard let endFree = await CaptureHeadroom.freeBytes(near: root) else { return }
            let consumed = startFree - endFree
            let units: Double
            switch key.family {
            case .still, .raw: units = Double(frames)
            case .movie, .proRes: units = seconds
            }
            CaptureCostStore.shared.record(key: key, consumedBytes: consumed, units: units)
        }
    }

    /// What the run that just ended produced, in the units its shape is costed
    /// in. Read at the transition, from whichever counter was doing the
    /// counting.
    private var finishedRunFrameCount: Int {
        max(camera.liveBlendOutputCount, camera.photoCount)
    }

    /// Whether a Scanner run on this device will really write DNG: the format
    /// dial asks for it **and** the hardware backs it.
    ///
    /// RAW is what the dial defaults to, because Scanner's frames are destined
    /// for solvers and compositing pipelines — but it is the dial's answer, not
    /// the mode's. Scanner used to take RAW whatever the format sheet said,
    /// which made that control silently inoperative in this one mode (found on
    /// device, 2026-08-17: a shoot set to JPEG wrote a folder of DNGs). The
    /// claim is still only made where the hardware backs it — `startScanner`
    /// falls back to processed stills, and logs it, on a source that can't
    /// deliver Bayer RAW.
    private var scannerCapturesRAW: Bool {
        scannerArmed && model.intervalOutputFormat == .dng && camera.liveBlendDNGSupport.isSupported
    }

    // MARK: - Remote link chip

    /// The camera half of pairing: shows the code a Mac has to be told, and
    /// then who is holding the link.
    ///
    /// This has to be ON the capture screen rather than in Settings, because
    /// the code is regenerated every time the listener starts — which is every
    /// time this screen appears. A code read anywhere else would already be
    /// stale by the time it was typed.
    @ViewBuilder
    private var remoteLinkChip: some View {
        #if os(iOS)
        // The listener is observed by the chip itself, not here: this view
        // watches `watchRemote`, so the listener's own @Published changes
        // (code assigned, peer connected) would never redraw it from here.
        if let listener = watchRemote.remoteListener {
            RemoteLinkChip(listener: listener)
        }
        #endif
    }

    // MARK: - Thermal warning chip

    /// Pre-flight heat warning, shown while idle at serious or critical.
    /// Serious is warn-only (2026-08-24): Record works, the bench runs
    /// devices warm on purpose. Critical is a refusal since 2026-09-02 —
    /// on iPhones the camera layer declines to start and ends a run there,
    /// because that is the state in which the 12 Pro's lens stabiliser parks
    /// and the framing jumps (every logged event; none at serious). The chip
    /// says so, so a shutter press that does nothing is not a mystery.
    /// During a run the diagnostics readout already carries thermal pressure.
    @ViewBuilder
    private func thermalWarningChip(compact: Bool = false) -> some View {
        if !isCapturing, thermalState == .serious || thermalState == .critical {
            let critical = thermalState == .critical
            HStack(spacing: 6) {
                Image(systemName: "thermometer.high")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(critical ? Color.red : LL.amber)
                Text(compact
                    ? (critical ? "Too hot to shoot" : "Warm")
                    : (critical
                        ? "Too hot to shoot — let it cool first"
                        : "Device warm — long shoots may throttle"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Capsule())
            .accessibilityLabel(critical
                ? "Too hot to shoot. Let it cool first."
                : "Device warm. Long shoots may throttle.")
        }
    }

    // MARK: - Test-card rig chip

    /// The rig's whole UI: countdown (tap cancels), live run (tap stops and
    /// keeps the partial take), then the result line. Styled after the
    /// Target… pill so it reads as part of the letterbox controls.
    private var testCardChip: some View {
        Button { testRig.cancel() } label: {
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                HStack(spacing: 6) {
                    Circle().fill(LL.amber).frame(width: 7, height: 7)
                    Text(testCardChipText(at: timeline.date))
                        .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Capsule())
            }
        }
        .buttonStyle(.plain)
    }

    private func testCardChipText(at date: Date) -> String {
        switch testRig.phase {
        case .idle:
            return ""
        case .countdown(let script, let endsAt):
            // .distantFuture is the LL_TESTRIG=chip screenshot freeze.
            let remaining = endsAt == .distantFuture
                ? 3 : max(0, Int(endsAt.timeIntervalSince(date).rounded(.up)))
            return "Test card \(script.raw) — starts in \(remaining)s · tap to cancel"
        case .running(let script, let startedAt):
            let remaining = max(0, Int(script.totalSeconds - date.timeIntervalSince(startedAt)))
            return "Test run \(script.raw) — \(remaining)s left · tap to stop"
        case .finished(let message):
            return message
        }
    }

    // MARK: - Speed chips (idle)

    /// Video's idle row. The per-preset speed chips (10× · 25× · 50× · 100×)
    /// are gone — speed is set from the Target sheet, which picks it from the
    /// clip length you actually want — so only that entry point remains here.
    private var speedChipsRow: some View {
        Button {
            showTargetSheet = true
        } label: {
            Text("Target…")
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Live "what would this be" per speed. While recording it tracks the
    /// elapsed take; while framing it tracks how long you've been framing.
    private func estimateText(for speed: Int) -> String {
        let reference: TimeInterval
        if camera.isRecording, let startedAt = camera.recordingStartedAt {
            reference = now.timeIntervalSince(startedAt)
        } else {
            reference = now.timeIntervalSince(framingStartedAt)
        }
        let seconds = SpeedMath.outputSeconds(
            recordSeconds: max(1, reference),
            captureFPS: Double(camera.selectedFrameRate),
            speed: speed,
            outputFPS: model.outputFPS
        )
        return SpeedMath.clipLengthCompact(seconds)
    }

    // MARK: - Recording marquee + strip

    private var neighborSpeeds: [Int] {
        let current = model.constantWindow
        return [current / 2, current * 2]
            .filter { SpeedMath.range.contains($0) && $0 != current }
    }

    private var speedMarquee: some View {
        HStack(spacing: 14) {
            if let target = activeTarget {
                Text("\(elapsedRecordingTime) / \(DurationFormatter.recordingTime(from: target.recordSeconds))")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(targetReached ? Color.green : LL.amber)
                Text("target \(SpeedMath.clipLengthCompact(target.clipSeconds)) @ \(target.speed)×")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                if let lower = neighborSpeeds.first(where: { $0 < model.constantWindow }) {
                    marqueeEntry(speed: lower, emphasized: false)
                }
                marqueeEntry(speed: model.constantWindow, emphasized: true)
                if let higher = neighborSpeeds.first(where: { $0 > model.constantWindow }) {
                    marqueeEntry(speed: higher, emphasized: false)
                }
            }
        }
    }

    private func marqueeEntry(speed: Int, emphasized: Bool) -> some View {
        Text("\(speed)× → \(estimateText(for: speed))")
            .font(.system(size: 12.5, weight: emphasized ? .bold : .regular, design: .monospaced))
            .foregroundStyle(emphasized ? LL.amber : .white.opacity(0.45))
    }

    private var segmentStrip: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                let elapsed = max(1, elapsedSeconds)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(red: 0.23, green: 0.23, blue: 0.24))
                    ForEach(camera.rampSpans) { span in
                        let start = min(span.start, elapsed)
                        let end = min(span.end ?? elapsed, elapsed)
                        let width = max(0, (end - start) / elapsed) * geometry.size.width
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(LL.amber)
                            .frame(width: max(width, 3))
                            .offset(x: (start / elapsed) * geometry.size.width)
                    }
                }
            }
            .frame(height: 14)

            HStack {
                Text("\(baseFrameRateLabel) fps base")
                Spacer()
                Text(stripCaption)
                    .foregroundStyle(LL.amber)
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var elapsedSeconds: TimeInterval {
        guard let startedAt = camera.recordingStartedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    private var baseFrameRateLabel: String {
        "\(camera.selectedFrameRate)"
    }

    private var stripCaption: String {
        let count = camera.rampIntervalCount
        switch camera.activeSequenceMode ?? sequenceMode {
        case .ramp:
            let state = camera.isRampHighRate ? "burst live" : "bursts"
            return "▲ \(camera.selectedRampFrameRate) fps \(state) · \(count)"
        case .marker:
            return "⚑ \(count) marked interval\(count == 1 ? "" : "s")"
        }
    }

    // MARK: - Interval rows

    /// One of the interval engines is running — the plain photo timer or the
    /// blend pipeline; either way the row swaps to counters.
    private var isIntervalCapturing: Bool {
        camera.isIntervalRunning || camera.isLiveBlendRunning
    }

    /// The running row also covers the settle window after a stop, so the
    /// burst pill can play its hold-and-fade before the pickers return (the
    /// diagnostics readout guards on the engine itself and drops instantly).
    private var showsIntervalRunningRow: Bool {
        isIntervalCapturing || (burstPillPhase != .hidden && burstPillMode == .interval)
    }

    @ViewBuilder
    private var intervalStatusRow: some View {
        if showsIntervalRunningRow {
            VStack(spacing: 8) {
                // A Scanner run has no spacing to report and no blend windows,
                // so it replaces the pills outright rather than sitting under
                // counters that would mean nothing.
                if camera.scannerState != nil {
                    scannerReadout
                } else {
                    // Design 2026-09-04 (third pass): one amber exposure line
                    // over the bias slider (`exposurePanel` draws the slider,
                    // right under this row) and the diagnostics panel only
                    // behind the cluster's Info toggle. The pills row and the
                    // ramp readout panel that used to stack here are gone —
                    // the second duplicated the first.
                    if showRunInfo {
                        runInfoPanel
                    }
                    // How many frames are in the bag. The pill has always been
                    // mounted for an Interval run (at run start, count 0) and
                    // fed every tick — it was only ever drawn in Photo's slot,
                    // so the number existed and nobody could see it. It sits
                    // ABOVE the exposure line so the line stays next to the
                    // bias slider `exposurePanel` draws directly under it.
                    if burstPillPhase != .hidden, burstPillMode == .interval {
                        burstStatusPill
                    }
                    runExposureLine
                        .padding(.horizontal, 16)
                    ladderRunningRungDial
                }
            }
        } else {
            // The output format lives in the format pill and its sheet — no
            // duplicate copy line here, Scanner included. It used to carry two
            // extra lines (an AE/AF/WB lock warning and a "+ corrected HEIC"
            // note) and a caption under the dials; all three stated things the
            // run does for you anyway, above a viewfinder whose whole job is to
            // be looked at. The dials say what is settable; the HUD says what
            // the run is doing; nothing in between.
            VStack(spacing: 6) {
                intervalPickerRow
                scannerAspectRow
                scannerDocumentModeRow
            }
        }
    }

    /// Landscape twin of `intervalStatusRow`, shown in the viewfinder's safe
    /// corner: the controls sit over the live image (no letterbox there), so
    /// they get dark backdrops to stay legible.
    @ViewBuilder
    private var landscapeIntervalRow: some View {
        if showsIntervalRunningRow {
            VStack(alignment: .leading, spacing: 6) {
                if camera.scannerState != nil {
                    scannerReadout
                } else {
                    if showRunInfo {
                        runInfoPanel
                    }
                    // Portrait's frame count, in the corner stack (see
                    // `intervalStatusRow`).
                    if burstPillPhase != .hidden, burstPillMode == .interval {
                        burstStatusPill
                    }
                    runReadoutCapsule
                    ladderRunningRungDial
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // Ladder's light panel used to stack above the dials here;
                // since 2026-09-04 it rides the viewfinder's top-leading
                // corner in every orientation (`ladderViewfinderOverlays`).
                intervalPickerRow
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.5), in: Capsule())
                // Guarded here as well as inside the rows: a backdrop drawn
                // around an empty row is a capsule floating over the
                // viewfinder of every non-Scanner landscape shoot.
                if scannerArmed {
                    scannerAspectRow
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.5), in: Capsule())
                    scannerDocumentModeRow
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.5), in: Capsule())
                }
            }
        }
    }

    /// Scanner's PAPER dial, under the EVERY/MODE/BLEND row and only while
    /// Scanner is the armed mode — it means nothing to a timer shoot, and a
    /// dial that is always there but usually inert teaches the wrong model.
    @ViewBuilder
    private var scannerAspectRow: some View {
        if scannerArmed {
            ScannerAspectRow(aspect: scannerAspect) { scannerAspectToken = $0.rawValue }
                .equatable()
        }
    }

    /// Scanner's grouping dial, under PAPER: whether the next page starts its
    /// own document. Set before the run because it is a decision about the pile
    /// on the desk — a stack of receipts or a contract — and both answers stay
    /// changeable mid-run, which is what the HUD's New Document button is for
    /// when this is off.
    @ViewBuilder
    private var scannerDocumentModeRow: some View {
        if scannerArmed {
            ScannerDocumentModeRow(isOn: newScanIsNewDocument) {
                newScanIsNewDocument.toggle()
                // Turning it on mid-run means "the next page begins a
                // document"; turning it off means "keep filling this one".
                // Both are stated by the pending flag rather than left until
                // the next capture to work out.
                if newScanIsNewDocument { scannerPendingNewDocument = true }
            }
            .equatable()
        }
    }

    private var elapsedIntervalText: String {
        DurationFormatter.recordingTime(from: now.timeIntervalSince(framingStartedAt))
    }

    // MARK: - Burst pill

    /// The burst pill in the interval-pills slot: 249 pt wide, its fade-out
    /// driven by the settle phase.
    private var burstStatusPill: some View {
        BurstStatusIndicator(taken: burstPillCount, total: burstPillTotal)
            .frame(width: 249)
            .opacity(burstPillFadingOut ? 0 : 1)
    }

    /// A run claimed the pill: freeze its cap (nil = zebra), seed the count,
    /// and cancel whatever settle a previous run left in flight.
    private func mountBurstPill(taken: Int, total: Int?) {
        burstPillGeneration += 1
        burstPillCount = taken
        burstPillTotal = total
        burstPillMode = mode
        burstPillFadingOut = false
        burstPillPhase = .running
    }

    /// The run stopped — cap reached, Bulb's second tap, or Interval's stop.
    /// Hold the pill at its final state for 900 ms, fade it over 400 ms, then
    /// hand the slot back to the dials. No completion flourish, no lingering
    /// chrome. A new run starting mid-settle bumps the generation, stranding
    /// these sleeps.
    private func settleBurstPill() {
        guard burstPillPhase == .running else { return }
        burstPillPhase = .settling
        burstPillGeneration += 1
        let generation = burstPillGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard generation == burstPillGeneration, burstPillPhase == .settling else { return }
            withAnimation(BurstStatusIndicator.ease(0.4)) {
                burstPillFadingOut = true
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard generation == burstPillGeneration, burstPillPhase == .settling else { return }
            burstPillPhase = .hidden
            burstPillFadingOut = false
        }
    }

    /// Drop the pill immediately (mode switch, or a new run resetting the
    /// slot before it mounts again).
    private func dismissBurstPill() {
        burstPillGeneration += 1
        burstPillPhase = .hidden
        burstPillMode = nil
        burstPillFadingOut = false
    }

    #if DEBUG
    /// `LL_MODE=photo|interval|video` opens the capture screen in that mode,
    /// instead of whichever one was last used. Screenshot runs need a stated
    /// mode: the remembered one follows whoever shot last.
    private func applyModePreviewHook() {
        guard let raw = ProcessInfo.processInfo.environment["LL_MODE"],
              let wanted = CaptureMode(rawValue: raw.capitalized)
        else { return }
        mode = wanted
        syncLoggedCaptureMode(mode: wanted)
        updateAspectPreview()
    }

    /// `LL_SCANNER=<state>` arms the MODE dial on Scanner and freezes a running
    /// shoot in that state — the HUD the simulator can never reach for itself,
    /// having no camera to difference frames from, no scene to disturb and
    /// nothing flat to detect. Implies Interval mode. Pair with `LL_CAPTURE=1`.
    ///
    /// The **motion** trigger (PAPER = Auto): `settled` is the resting state
    /// ("Waiting for you to move"), `disturbed` is mid-settle.
    ///
    /// The **rectangle** trigger (PAPER = A4 here, since the stock is what
    /// selects it): `waitingpage` has nothing flat in view, `holding` is a page
    /// found and its hold window part-filled — the amber bar — `captured` is a
    /// page banked, waiting to be swapped, `shaperefused` is something flat in
    /// view that cannot be the named stock, and `stacking` is a 5-frame pose
    /// being averaged.
    ///
    /// All of them draw 12 of a 36-pose target, which is what makes the count
    /// and the shutter ring legible in a mirror screenshot.
    /// `LL_STANDBY=<seconds>|warming` arms a scheduled shoot that far out, so
    /// the standby screen can be screenshotted against its SVG. Implies
    /// Interval mode. Pair with `LL_CAPTURE=1`.
    ///
    /// `warming` stages 75 s: just past the threshold, so the screen still
    /// goes cold on appear and then crosses T−60 s about fifteen seconds
    /// later — screenshot then for the "Preparing camera…" chip. It cannot be
    /// staged any closer than the threshold, because a start inside the
    /// warm-up window is precisely the case standby declines to take.
    ///
    /// The alternative is seeding `scheduledRecording` into the simulator's
    /// defaults before launch, which works but has to be re-timed for every
    /// run — the start is an absolute date, so a seed goes stale the moment
    /// the screenshot pass takes longer than the countdown.
    private func applyStandbyPreviewHook() {
        guard let raw = ProcessInfo.processInfo.environment["LL_STANDBY"] else { return }
        let seconds = raw == "warming" ? 75.0 : (Double(raw) ?? 3600)
        mode = .interval
        model.scheduledRecording = ScheduledRecording(
            startDate: Date().addingTimeInterval(seconds),
            intervalSeconds: interval,
            durationMinutes: 60,
            blendDepth: blendDepth.fixedFrames,
            label: "Sunset over the harbour")
    }

    /// `LL_SHAPEFINDER=on` arms auto shape mode in Photo mode; `=shapes` also
    /// stages a circle and a keystoned quad over the viewfinder. Staged for
    /// the reason `LL_SCANNER_RECT` is: the simulator has no camera, so
    /// nothing is ever found in it, and the overlay is otherwise unreachable
    /// off-device.
    private func applyAutoShapesPreviewHook() {
        guard let raw = ProcessInfo.processInfo.environment["LL_SHAPEFINDER"] else { return }
        mode = .photo
        autoShapesEnabled = true
        if raw == "shapes" {
            // After the toggle's own `onChange` has run its reset — which
            // would otherwise wipe the staged tracks a beat after they land.
            // Staged on a frame of the preview's own proportions: on a device
            // the tap's frames and the preview share the format, and the
            // simulator's cameraless preview is 16:9 where a Photo shoot's
            // would be 4:3.
            let resolution = camera.previewDimensions ?? camera.selectedResolution
            let frame = CGSize(width: CGFloat(max(resolution.height, 1)), height: CGFloat(max(resolution.width, 1)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                liveShapes.stageDemoShapes(frameSize: frame)
            }
        }
    }

    private func applyScannerPreviewHook() {
        let environment = ProcessInfo.processInfo.environment
        let rectangleHook = environment["LL_SCANNER_RECT"]
        guard let raw = environment["LL_SCANNER"] ?? rectangleHook.map({ _ in "1" }) else { return }
        mode = .interval
        intervalModeToken = IntervalCaptureMode.scanner.rawValue
        reconcileIntervalAuto()
        updateAspectPreview()
        // `LL_SCANNER_RECT=detected` freezes a quad over the viewfinder;
        // `none` (or leaving it unset) draws no overlay. Same reason as every
        // other hook on this screen, one step further along: the simulator has
        // no camera, so there is nothing for Vision to find a rectangle in, and
        // the overlay is otherwise unreachable off-device. The corners are a
        // plausible keystoned page — narrower at the top, where the far edge is.
        if rectangleHook == "detected" {
            camera.scannerRectangle = NormalizedQuad(
                topLeft: .init(x: 0.185, y: 0.815),
                topRight: .init(x: 0.826, y: 0.833),
                bottomLeft: .init(x: 0.122, y: 0.196),
                bottomRight: .init(x: 0.884, y: 0.181),
                confidence: 0.94)
        }
        // The motion trigger's two states, and the rectangle trigger's three.
        // The second set needs staging for the same reason as the first, twice
        // over: those states are only reachable with a real page in front of a
        // real camera, and they are the ones a document shoot actually shows.
        let documentPhase: ScannerEngine.State?
        switch raw {
        case "waitingpage", "shaperefused": documentPhase = .waitingForPage
        case "holding", "stacking": documentPhase = .holding
        case "captured": documentPhase = .captured
        default: documentPhase = nil
        }
        guard raw == "settled" || raw == "disturbed" || documentPhase != nil else { return }
        let disturbed = raw == "disturbed"
        if documentPhase != nil {
            // A staged document run is on a stock, because that is what selects
            // the trigger — Auto could never produce these states.
            scannerAspectToken = PerspectiveAspect.a4.rawValue
        }
        activeTarget = CaptureTargetPlan(
            clipSeconds: 0, speed: 1, recordSeconds: 0, autoStop: true, poseTarget: 36)
        camera.scannerState = CameraController.ScannerState(
            phase: (documentPhase ?? (disturbed ? .disturbed : .settled)).rawValue,
            frames: 12,
            shutterSeconds: 1.0 / 120,
            iso: 200,
            isCapturingRAW: true,
            settleProgress: documentPhase == .holding ? 0.62 : (disturbed ? 0.55 : nil),
            waitingForDeviceSteady: false,
            hasRectangle: documentPhase == nil
                ? rectangleHook == "detected"
                : documentPhase != .waitingForPage,
            trigger: (documentPhase == nil
                ? ScannerEngine.Trigger.motion : .rectangle).rawValue,
            // Two states a simulator could never reach on its own, for the same
            // reason as the rest of this hook: `shaperefused` needs a real quad
            // that a real stock has refused, and `stacking` needs a pose's
            // frames to actually be averaging.
            refusingOnShape: raw == "shaperefused",
            framesPerPose: raw == "stacking" ? 5 : 1,
            isStacking: raw == "stacking")
        camera.isIntervalRunning = true
        framingStartedAt = Date().addingTimeInterval(-96)
        // `LL_SCANNER_DOCPRESS=1` presses New Document once the staged run's
        // pages have been filed. It goes through the button's own action, so
        // what it proves is the real thing: that a press mid-run closes the
        // open document and the HUD says so. The delay is because the pages
        // are filed by the `frames` observer, which cannot have run yet — this
        // hook is setting the state that observer reacts to.
        if ProcessInfo.processInfo.environment["LL_SCANNER_DOCPRESS"] != nil {
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                beginScannerDocument()
            }
        }
    }

    /// `LL_HOLYGRAIL=armed` arms the MODE dial on Holy Grail;
    /// `LL_HOLYGRAIL=running` also freezes a mid-ramp state on screen — the
    /// readout the simulator can never produce for itself, since it has no
    /// camera to ramp; `LL_HOLYGRAIL=refused` freezes the run whose ramp the
    /// camera is refusing — the 2026-09-04 12 Pro numbers: the engine at its
    /// 14 µs floor and "clipped", the sensor on AE at 1/121 · ISO 71 — which
    /// is what the amber line must print. Implies Interval mode. Pair with
    /// `LL_CAPTURE=1`.
    private func applyHolyGrailPreviewHook() {
        guard let raw = ProcessInfo.processInfo.environment["LL_HOLYGRAIL"] else { return }
        mode = .interval
        intervalModeToken = IntervalCaptureMode.holyGrail.rawValue
        updateAspectPreview()
        guard raw == "running" || raw == "refused" else { return }
        if raw == "refused" {
            camera.holyGrailState = CameraController.HolyGrailState(
                shutterSeconds: 1.0 / 71429,
                iso: 33,
                sceneEV: 8.8,
                frames: 443,
                isISORamping: false,
                isClipped: true,
                isCapturingRAW: false,
                isDriving: false,
                deliveredShutterSeconds: 1.0 / 121,
                deliveredISO: 71,
                notDrivingReason: "this camera does not accept a custom exposure right now")
        } else {
            camera.holyGrailState = CameraController.HolyGrailState(
                shutterSeconds: 1.0,
                iso: 1250,
                sceneEV: 1.4,
                frames: 24,
                isISORamping: true,
                isClipped: false,
                isCapturingRAW: true)
        }
        framingStartedAt = Date().addingTimeInterval(-602)
        mountBurstPill(taken: 24, total: nil)
        // Staged as a RUN, so the cluster and the rows read as one — stop
        // square, the run-time toggles, no mode row. Deferred past
        // `camera.start()`'s counter reset, as the recording hook is.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            camera.isIntervalRunning = true
        }
    }

    /// `LL_BURST=7/10` (capped fill) or `LL_BURST=47` (zebra) freezes the
    /// burst pill on screen for SVG-mirror screenshots — the simulator has
    /// no camera, so a live run can't reach this state. Add `LL_BURST_MODE=
    /// interval` to stage it in the Interval row instead of Photo's slot.
    /// Pair with `LL_CAPTURE=1`.
    private func applyBurstPreviewHook() {
        guard let raw = ProcessInfo.processInfo.environment["LL_BURST"] else { return }
        let parts = raw.split(separator: "/", maxSplits: 1)
        guard let taken = parts.first.flatMap({ Int($0) }), taken >= 0 else { return }
        mode = ProcessInfo.processInfo.environment["LL_BURST_MODE"] == "interval" ? .interval : .photo
        burstPillCount = taken
        burstPillTotal = parts.count > 1 ? Int(parts[1]) : nil
        burstPillMode = mode
        burstPillPhase = .running
    }

    /// `LL_FOCUS=1` freezes a tap-to-focus reticle in the middle of the
    /// viewfinder for SVG-mirror screenshots. Same reason as the burst hook: the
    /// simulator has no camera, so a real tap is refused before it ever draws
    /// one (`focusPreview` needs a device point inside the image). `LL_FOCUS=
    /// x,y` places it elsewhere, in viewfinder points. Pair with `LL_CAPTURE=1`.
    private func applyFocusPreviewHook() {
        guard let raw = ProcessInfo.processInfo.environment["LL_FOCUS"] else { return }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        let point = parts.count == 2
            ? CGPoint(x: parts[0], y: parts[1])
            : CGPoint(x: 196.5, y: 385)
        focusReticle = FocusReticle(point: point)
    }

    /// `LL_MANUAL=1` stages Photo's manual-exposure panel open at the
    /// wheels' own defaults (ISO 200 · 1/60), for SVG-mirror screenshots —
    /// same reason as the other hooks here: the simulator's camera never
    /// actually reports AE, so there is no real way to land on a clean,
    /// reviewable state by tapping M for real. Pair with `LL_CAPTURE=1
    /// LL_MODE=photo`.
    private func applyManualExposurePreviewHook() {
        guard ProcessInfo.processInfo.environment["LL_MANUAL"] != nil else { return }
        photoManualExposure = true
    }

    /// `LL_GRID=grid|level` stages Photo's grid/level cycle directly, and
    /// `LL_LEVEL=<degrees>` (paired with `LL_GRID=level`) freezes the
    /// horizon reading itself — the simulator has no accelerometer to
    /// physically tilt. Pair with `LL_CAPTURE=1 LL_MODE=photo`.
    private func applyGridPreviewHook() {
        switch ProcessInfo.processInfo.environment["LL_GRID"] {
        case "grid": gridOverlay = .grid
        case "level": gridOverlay = .level
        default: break
        }
        #if os(iOS)
        if let raw = ProcessInfo.processInfo.environment["LL_LEVEL"], let degrees = Double(raw) {
            LevelSensor.debugOverrideDegrees = degrees
        }
        #endif
    }

    /// `LL_RECORDING=1` freezes a Video shoot mid-take — the recording pill,
    /// the speed marquee and the segment strip with its burst spans — for
    /// SVG-mirror screenshots in either orientation. Same reason as the burst
    /// and focus hooks: the simulator has no camera, so `startRecording` never
    /// lands and this whole readout is otherwise unreachable off-device.
    ///
    /// `LL_RECORDING=<seconds>` sets the elapsed take (default 132), and
    /// `LL_RECORDING=<seconds>:<a>-<b>,<c>-` spells the burst spans out in
    /// seconds from the start, a trailing `-` meaning a burst still open. It
    /// stages published state only — no session, no writer, no file behind it.
    /// Pair with `LL_CAPTURE=1`.
    private func applyRecordingPreviewHook() {
        guard let raw = ProcessInfo.processInfo.environment["LL_RECORDING"] else { return }
        let halves = raw.split(separator: ":", maxSplits: 1)
        // `LL_RECORDING=1` is the plain on-switch the other hooks use; anything
        // longer than a second is read as the take's own length.
        let requested = halves.first.flatMap { Double($0) } ?? 0
        let elapsed = requested > 1 ? requested : 132
        let spans: [CameraController.RampSpan] = halves.count > 1
            ? halves[1].split(separator: ",").enumerated().compactMap { index, field in
                let bounds = field.split(separator: "-", omittingEmptySubsequences: false)
                guard let start = bounds.first.flatMap({ Double($0) }) else { return nil }
                // "12-" is a burst that hasn't closed yet; the strip runs it
                // to the playhead, which is what `end == nil` means.
                let end = bounds.count > 1 ? Double(bounds[1]) : start + 4
                return CameraController.RampSpan(id: index, start: start, end: end)
            }
            // Three bursts across the take, the last one still open — the
            // shape the field readout is actually judged on.
            : [
                CameraController.RampSpan(id: 0, start: elapsed * 0.10, end: elapsed * 0.13),
                CameraController.RampSpan(id: 1, start: elapsed * 0.42, end: elapsed * 0.48),
                CameraController.RampSpan(id: 2, start: elapsed * 0.89, end: nil),
            ]
        mode = .video
        sequenceMode = .ramp
        // Deferred past `camera.start()`, which resets the sequence counters on
        // the main queue — staged from here directly, that reset lands second
        // and wipes the whole take back to idle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            camera.activeSequenceMode = .ramp
            camera.recordingStartedAt = Date().addingTimeInterval(-elapsed)
            camera.isRecording = true
            camera.rampSpans = spans
            camera.rampIntervalCount = spans.count
            camera.isRampHighRate = spans.contains { $0.end == nil }
            camera.isRampActive = camera.isRampHighRate
        }
    }
    #endif

    /// The two interval dials — spacing and blend depth. Its own `Equatable`
    /// view (see CaptureDials.swift): an open `Menu` is a live `UIMenu` on iOS,
    /// so leaving it in this body made every unrelated re-render cross-fade the
    /// open dial. `.equatable()` holds it still unless a drawn value moves.
    private var intervalPickerRow: some View {
        IntervalDialsRow(
            intervalSeconds: interval,
            intervalOptions: captureIntervalOptions,
            intervalIsAuto: intervalIsAuto,
            blendDepth: blendDepth,
            safeDepthAvailable: safeDepthAvailable,
            captionText: blendCaptionText,
            streamFPS: blendStreamFPS,
            modeAvailable: IntervalCaptureMode.availableCases.count > 1,
            intervalMode: intervalMode,
            ladderName: ladderArmed ? ladderChipName : nil,
            ladderSwatch: LadderPalette.color(rung: previewRungIndex, of: selectedLadder.rungs.count),
            rungName: ladderArmed && Self.ladderStepsByHand ? ladderRungByHandName : nil,
            rungNames: selectedLadder.rungs.map(\.name),
            onSelectInterval: { seconds in
                intervalAutoEnabled = false
                lastFixedInterval = seconds
                interval = seconds
            },
            onSelectAutoInterval: { intervalAutoEnabled = true },
            onSelectFixedBlend: { frames in
                blendDepth = .fixed(frames)
                lastFixedBlendFrames = frames
            },
            onSelectPsycho: selectPsychoDepth,
            onSelectSafe: { blendDepth = .throttled },
            onSelectAuto: { blendDepth = .auto },
            onSelectMode: { intervalModeToken = $0.rawValue },
            onSelectLadder: { showLadderPicker = true },
            onSelectRung: { stepLadderByHand(to: $0) }
        )
        .equatable()
    }

    // MARK: - Light Ladder (armed)

    /// The armed ladder — the remembered selection, or the built-in.
    private var selectedLadder: LightLadder { ladders.resolve(id: selectedLadderID).normalized() }

    /// "Bright & Fast" for "Bright & Fast, Dark & Slow": the chip has one
    /// line, so the name is cut at its first comma.
    private var ladderChipName: String {
        let name = selectedLadder.name
        let short = name.split(separator: ",", maxSplits: 1).first.map(String.init) ?? name
        return short.trimmingCharacters(in: .whitespaces)
    }

    /// The rung the armed panel names: the preview selector's answer, or the
    /// plain lookup before it has one, or the top rung with no meter at all.
    private var previewRungIndex: Int {
        let ladder = selectedLadder
        if Self.ladderStepsByHand { return min(ladderRungByHand, max(ladder.rungs.count - 1, 0)) }
        if let index = ladderPreviewSelector?.currentIndex, index < ladder.rungs.count { return index }
        if let ev = camera.previewSceneEV { return LightLadderSelector.plainIndex(forEV: ev, in: ladder) }
        return 0
    }

    /// The hand-stepped rung's name, for the dial row's chip.
    private var ladderRungByHandName: String {
        let ladder = selectedLadder
        guard !ladder.rungs.isEmpty else { return "" }
        return ladder.rungs[previewRungIndex].name
    }

    /// The operator steps the ladder (`ladderStepsByHand`): armed, the next
    /// shoot opens on this rung; running, the rung's spacing and blend apply
    /// from the next window, exactly as a light-driven step would, and the
    /// rail and toast follow through `ladderState`.
    private func stepLadderByHand(to index: Int) {
        guard Self.ladderStepsByHand, selectedLadder.rungs.indices.contains(index) else { return }
        ladderRungByHand = index
        Self.lastLadderRungByHand = index
        #if os(macOS)
        if isCapturing { camera.setLadderRung(index) }
        #endif
    }

    /// Whether the 1 Hz preview metering should run: Ladder armed, idle.
    private var ladderPreviewWanted: Bool { ladderArmed && !isCapturing }

    /// What the light panel states at arm when the rung's blend cannot run as
    /// asked on this pipeline — the actuation clamp, visible rather than
    /// silent (decision D4). Modelled here; the run's governor has the last
    /// word and the HUD's third line reports it.
    private var ladderClampNote: String? {
        let ladder = selectedLadder
        let rung = ladder.rungs[min(previewRungIndex, ladder.rungs.count - 1)]
        guard rung.blendFrames > 1 else { return nil }
        let wantsDNG = model.intervalOutputFormat == .dng && camera.liveBlendDNGSupport.isSupported
        if wantsDNG {
            // A RAW capture costs about twice a stream frame's hand-off.
            let ceiling = LightLadderAdvice.blendCeiling(intervalSeconds: rung.intervalSeconds, perFrameSeconds: 0.45)
            return ceiling < rung.blendFrames ? "blend \(rung.blendFrames) → ≈\(ceiling) in RAW on this camera" : nil
        }
        if let fps = blendStreamFPS,
           !StreamRatePlan.isAttainable(frames: rung.blendFrames, intervalSeconds: rung.intervalSeconds, streamFPS: fps) {
            let most = max(1, Int((fps * rung.intervalSeconds).rounded(.down)))
            return "blend \(rung.blendFrames) → \(most) — the stream gives \(Int(fps.rounded())) fps"
        }
        return nil
    }

    /// Feeds the armed panel's selector from the preview meter. A rung change
    /// while armed re-opens a closed panel (D10): "you are about to shoot in
    /// Dusk, not Fading" is worth interrupting for.
    private func advanceLadderPreview(ev: Double?) {
        guard ladderArmed, !Self.ladderStepsByHand, let ev else { return }
        var selector = ladderPreviewSelector ?? LightLadderSelector(ladder: selectedLadder)
        let before = selector.currentIndex
        selector.resolve(ev: ev)
        ladderPreviewSelector = selector
        if before != nil, selector.changedOnLastResolve, !ladderPanelOpen {
            ladderPanelOpen = true
        }
    }

    /// The light panel, or its pill, while Ladder is armed and idle. Both
    /// orientations lay it over the viewfinder's top-leading corner
    /// (`ladderViewfinderOverlays`): under the close/schedule row in portrait,
    /// right of the rail's close/schedule buttons in landscape.
    @ViewBuilder
    private var ladderArmedPanel: some View {
        if ladderArmed, !isCapturing, camera.ladderState == nil, !selectedLadder.rungs.isEmpty {
            let ladder = selectedLadder
            let index = min(previewRungIndex, ladder.rungs.count - 1)
            Group {
                if ladderPanelOpen {
                    LadderLightPanel(
                        ladder: ladder, rungIndex: index, sceneEV: camera.previewSceneEV,
                        clampNote: ladderClampNote,
                        exposureIsAutomatic: Self.ladderStepsByHand,
                        onClose: { ladderPanelOpen = false })
                } else {
                    LadderRungPill(
                        name: ladder.rungs[index].name,
                        color: LadderPalette.color(rung: index, of: ladder.rungs.count),
                        onOpen: { ladderPanelOpen = true })
                }
            }
            .transition(.opacity)
        }
    }

    /// The viewfinder's ladder overlays: the light panel (or its pill) while
    /// armed, and the rail and the toast while running. The armed panel is
    /// top-leading in both orientations (design 2026-09-04): 16 pt in, and in
    /// portrait 4 pt under the top bar — 12 pt below its buttons — so the
    /// close and schedule buttons stay clear; landscape's region begins at
    /// the rail's edge, so 16 pt all round puts it right of those buttons.
    /// Width-capped like the recording readout, so a wide Mac window doesn't
    /// stretch the panel's lines across the viewfinder.
    @ViewBuilder
    private func ladderViewfinderOverlays(portrait: Bool) -> some View {
        ladderArmedPanel
            .frame(maxWidth: Self.landscapeReadoutMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 16)
            .padding(.top, portrait ? 4 : 16)
        if let state = camera.ladderState {
            LadderRail(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 14)
                .allowsHitTesting(false)
            if showLadderToast {
                LadderToast(state: state, steppedDown: ladderToastDown)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 28)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    /// The running rung dial, where the operator steps the ladder by hand:
    /// RUNG · Dusk under the run's readout, the same dial the armed row
    /// carries, so the step is made where the settings are and not on the
    /// rail — which is picture, and sits inside the viewfinder's swipe and
    /// pinch gestures where a menu's mouse-down is not reliably its own.
    @ViewBuilder
    private var ladderRunningRungDial: some View {
        if Self.ladderStepsByHand, let state = camera.ladderState {
            HStack(spacing: 8) {
                DialCaption(text: "RUNG")
                Menu {
                    ForEach(Array(state.rungNames.enumerated()), id: \.offset) { index, name in
                        Button {
                            stepLadderByHand(to: index)
                        } label: {
                            if index == state.rungIndex {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                } label: {
                    PickerMenuLabel(text: state.rungName)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Rung: \(state.rungName), step the ladder")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.5), in: Capsule())
        }
    }

    /// A rung change landed: show the toast for three seconds.
    private func flashLadderToast(down: Bool) {
        ladderToastTask?.cancel()
        ladderToastDown = down
        withAnimation(.easeOut(duration: 0.2)) { showLadderToast = true }
        ladderToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { showLadderToast = false }
        }
    }

    /// `LL_LADDER=armed|open|picker|running` arms the MODE dial on Ladder
    /// and stages the state the simulator cannot reach on its own — it has no
    /// camera to meter, so the panel's scene EV and the running rail are
    /// fabricated here from the design's own numbers (Dusk, EV 5.2, 41 min in,
    /// 823 frames, the governor at blend 3 → 2). Implies Interval mode; pair
    /// with `LL_CAPTURE=1`.
    private func applyLadderPreviewHook() {
        guard let raw = ProcessInfo.processInfo.environment["LL_LADDER"] else { return }
        mode = .interval
        intervalModeToken = IntervalCaptureMode.ladder.rawValue
        reconcileIntervalAuto()
        updateAspectPreview()
        selectedLadderID = nil
        // The Mac has no meter and no selector: the rung is the operator's,
        // so the hook stands on Dusk by hand and stages no scene EV — a
        // fabricated "scene EV 5.2" would draw a reading the Mac never has.
        if Self.ladderStepsByHand {
            ladderRungByHand = 2
        } else {
            camera.previewSceneEV = 5.2
            var selector = LightLadderSelector(ladder: .builtIn)
            selector.resolve(ev: 5.2)
            ladderPreviewSelector = selector
        }
        switch raw {
        case "open":
            ladderPanelOpen = true
        case "closed":
            // The pre-2026-09-04 name for what is now the default; kept so
            // older screenshot recipes still land on the pill.
            ladderPanelOpen = false
        case "picker":
            ladderPanelOpen = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                showLadderPicker = true
            }
        case "running":
            let ladder = LightLadder.builtIn
            // No ramp state on the Mac: its readout is the rung's line alone.
            if !Self.ladderStepsByHand {
                camera.holyGrailState = CameraController.HolyGrailState(
                    shutterSeconds: 1.0 / 8, iso: 1250, sceneEV: 5.2, frames: 823,
                    isISORamping: false, isClipped: false, isCapturingRAW: false)
            }
            // The phone's state carries the ramp's smoothed EV and a governor
            // note; the Mac's carries neither (no meter, no governor on the
            // JPEG path) — its readout is the rung as asked.
            let dusk = ladder.rungs[2]
            camera.ladderState = CameraController.LadderState(
                ladderName: ladder.name, rungIndex: 2, rungNames: ladder.rungs.map(\.name),
                spans: ladder.drawingSpans(), smoothedEV: Self.ladderStepsByHand ? nil : 5.2,
                intervalSeconds: dusk.intervalSeconds, blendFrames: Self.ladderStepsByHand ? dusk.blendFrames : 2,
                readoutLine: Self.ladderStepsByHand
                    ? LightLadderPacing(rung: dusk).readoutLine(rungName: dusk.name)
                    : "Dusk · every 2 s · blend 3 → 2, thermal",
                changeCount: 1,
                nextRungName: "Night", nextRungThresholdEV: 4, previousRungName: "Fading")
            mountBurstPill(taken: 823, total: nil)
            // Deferred past `startCameraSession()`, which re-anchors the run
            // clock on the main queue — set here directly, the reset lands
            // second and the elapsed pill reads 00:04. The toast rides the
            // same delay so a screenshot at ~4 s catches it (it lives 3 s).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                framingStartedAt = Date().addingTimeInterval(-(41 * 60 + 8))
                flashLadderToast(down: true)
                // Staged as a run, see the Holy Grail hook.
                camera.isIntervalRunning = true
            }
        default:
            // `armed`: the rung pill, collapsed — the default since 2026-09-04.
            ladderPanelOpen = false
        }
    }

    /// Keeps the EVERY/MODE pair valid after a MODE change.
    ///
    /// Two directions, and each is the least surprising answer available:
    /// Scanner turns Auto on (its spacing is the scene's, and the dial already
    /// says so), and a mode that can no longer pace turns Auto off, restoring
    /// the fixed spacing the user last picked rather than leaving the dial
    /// reading "Auto" for a shoot with nothing to do the pacing.
    private func reconcileIntervalAuto() {
        if intervalMode.requiresAutoInterval {
            intervalAutoEnabled = true
            return
        }
        if !intervalMode.supportsAutoInterval, intervalAutoEnabled {
            intervalAutoEnabled = false
            interval = lastFixedInterval
        }
    }

    /// What a shoot opens at when EVERY is on Auto. Holy Grail starts at the
    /// pacing policy's floor and widens from there as the light dies; Scanner
    /// has no timer at all, so the number only exists to satisfy the API and
    /// the floor is as good as any.
    private var autoIntervalSeed: Double { HolyGrailAutoInterval.floorSeconds }

    /// What the project's `mode` string says this shoot was. It is the label
    /// the rest of the app reads a capture's intent from — the Adjust screen
    /// turns "Scanner" into an Export-frames CTA rather than a timelapse one —
    /// so it names the MODE dial, not just the file format.
    private var intervalSourceModeName: String {
        switch intervalMode {
        case .scanner: return "Interval · Scanner"
        case .holyGrail: return "Interval · Holy Grail"
        case .ladder: return "Interval · Ladder"
        // Deliberately not renamed alongside the dial: this string is stamped
        // into projects on disk and read back by the rest of the app, so it is
        // data, not a label. The dial says "Basic"; the file keeps saying what
        // every shoot before it said.
        case .basic: return "Interval · JPEG"
        }
    }

    /// First selection shows the honest warmth-and-learning note, once.
    private func selectPsychoDepth() {
        blendDepth = .unthrottled
        if !UserDefaults.standard.bool(forKey: Self.psychoNoticeShownKey) {
            UserDefaults.standard.set(true, forKey: Self.psychoNoticeShownKey)
            showPsychoNotice = true
        }
    }

    /// The trailing caption, and it is now only drawn for the two depths whose
    /// chip cannot state their own count.
    ///
    /// **Everything it used to say for the other cases has gone, on purpose.**
    /// A fixed depth read "BLEND 5 · into one image", which is the dial saying
    /// what the dial says; the ramp read "ramping exposure · blended as it
    /// shoots", which is MODE saying what MODE says. Both were true, both were
    /// redundant, and between them they cost the row the width that pushed
    /// MODE, EVERY and BLEND onto two lines on a portrait iPhone. What is left
    /// is the one thing no chip on the row can tell you: how many frames
    /// Psycho and Safe are actually going to take.
    private var blendCaptionText: String? {
        // Scanner has no caption. It used to explain two greyed dials; EVERY
        // is now simply absent under it and BLEND does what it says, so there
        // is nothing left to apologise for.
        if scannerArmed || ladderArmed { return nil }
        switch blendDepth {
        case .fixed:
            return nil
        case .unthrottled:
            return "max frames"
        case .auto:
            // The count is the light's to choose, so the caption names what it
            // follows rather than a number that changes every interval.
            return "from the light"
        case .throttled:
            let learned = BlendProfileStore.shared.safeFrameCount(
                pipeline: activeBlendPipeline,
                bucket: ThermalBucket(thermalState: ProcessInfo.processInfo.thermalState),
                intervalSeconds: interval)
            return learned.map { "≈\($0) frames" } ?? "learned limit"
        }
    }

    /// Compact pipeline readout while the blend engine runs; the plain photo
    /// timer produces no diagnostics, so plain-JPEG shoots never see it.
    @ViewBuilder
    private var blendDiagnosticsReadout: some View {
        if camera.isLiveBlendRunning, let diagnostics = camera.liveBlendDiagnostics {
            // Unthrottled windows have no target — the readout drops the
            // "/N" rather than showing a made-up ceiling.
            VStack(alignment: .leading, spacing: 2) {
                Text("frames \(diagnostics.currentWindowSelectedFrames)\(diagnostics.requestedFramesPerBlend > 0 ? "/\(diagnostics.requestedFramesPerBlend)" : "") · last \(diagnostics.lastCapturedFrames.map(String.init) ?? "–")")
                Text("out \(diagnostics.lastOutputIntervalSeconds.map { String(format: "%.2f s", $0) } ?? "–") (req \(String(format: "%.1f s", diagnostics.requestedIntervalSeconds)))")
                Text("blend \(diagnostics.lastBlendMillis.map { String(format: "%.0f ms", $0) } ?? "–")\(diagnostics.outputFormatLabel.map { " · \($0)" } ?? "") · \(diagnostics.status.rawValue) · \(thermalWord)")
                    .foregroundStyle(blendStatusTint(diagnostics.status))
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: - Scanner HUD

    /// What a running Scanner shoot shows, and in what order of importance.
    ///
    /// The design constraint here is unusual for this app and drives
    /// everything: **the operator is not looking at the screen.** Their hands
    /// are on the object and their eyes are on the pose. So the count is set
    /// enormous — it is the one thing worth a glance — the state line is a
    /// short imperative rather than a status, and the real feedback channel is
    /// the shutter click plus a haptic, not any of these pixels (see
    /// `announceScannerFrame`).
    @ViewBuilder
    private var scannerReadout: some View {
        if let state = camera.scannerState {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(state.frames)")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    if let poses = activeTarget?.poseTarget {
                        Text("/ \(poses)")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Text(scannerStateText(state))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(scannerStateTint(state))
                    // Which of the two settle signals is deciding. The operator
                    // needs this the moment the shoot behaves differently from
                    // the last one: with a page in view the fire waits on four
                    // corners standing still, without one it waits on the whole
                    // frame going quiet, and they do not feel the same. The
                    // glyph is the overlay's own accent, so the mark on screen
                    // and the mark in the HUD are visibly the same fact.
                    if state.hasRectangle {
                        Image(systemName: "doc.viewfinder")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LL.accent)
                            .accessibilityLabel("Rectangle detected — settling on its corners")
                    }
                }
                scannerHoldBar(state)
                Text(scannerExposureText(state))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                scannerDocumentRow
                scannerDeleteLastButton(frames: state.frames)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// Imperative, not descriptive: the settled state's job is to tell the
    /// operator it is their turn, which "Waiting for you to move" does and
    /// "Idle" does not.
    /// The one line the operator reads without looking properly, so it says what
    /// the camera is waiting for in the vocabulary of the machine that is
    /// actually running.
    ///
    /// The two triggers ask for different things and must never borrow each
    /// other's words: "Waiting for you to move" is a *request* — the turntable
    /// loop cannot continue until the operator does something — while a document
    /// shoot asks for nothing but a page that stays put, and telling someone to
    /// move the page they just placed is the opposite of the instruction.
    private func scannerStateText(_ state: CameraController.ScannerState) -> String {
        if state.waitingForDeviceSteady { return "Hold the phone still" }
        // The shutter has just gone. Said for a moment over everything else,
        // because the click and the haptic are easy to miss with a hand still
        // over the page.
        if scannerJustCaptured { return "✓ Captured" }
        // A deep pose is seconds of averaging after the last frame lands, and
        // the pose count cannot move until it is written — so the wait says
        // what it is. Without this the screen goes quiet at exactly the moment
        // the operator is deciding whether it worked.
        if state.isStacking {
            return "Stacking \(state.framesPerPose) frames…"
        }
        guard state.trigger == ScannerEngine.Trigger.rectangle.rawValue else {
            return state.phase == ScannerEngine.State.disturbed.rawValue
                ? "Settling…" : "Waiting for you to move"
        }
        switch state.phase {
        case ScannerEngine.State.holding.rawValue:
            // The bar beneath it carries the rest of the sentence.
            return "Settling…"
        case ScannerEngine.State.captured.rawValue:
            // This page is banked and nothing more will be taken of it until it
            // is physically lifted — so the line asks for the lift rather than
            // announcing readiness. "Ready for the next page" was true and
            // useless: it doesn't say that leaving this one there is what keeps
            // the camera waiting.
            //
            // With every page its own document, the swap is also a document
            // boundary, and the operator is usually mid-pile: naming the
            // document the next sheet lands in is how they know the machine
            // agrees with the pile in their hand.
            if newScanIsNewDocument {
                return "Swap in next page — Doc \(scannerUpcomingDocument)"
            }
            return "Swap in the next page"
        default:
            // "Waiting for a page" over a desk with a page on it is the reading
            // that makes a working gate look like a broken detector. When the
            // stock is what is refusing, the line names the stock — the two
            // fixes it points at (reframe, or pick the right PAPER) are both
            // the operator's, and neither is "put a page down".
            if state.refusingOnShape {
                // Short enough to stay on the HUD's one line. The stock's name
                // is the whole message: it says which test is failing, and
                // anyone who meant a different stock knows where that dial is.
                return "Not \(scannerAspect.label)-shaped"
            }
            return "Waiting for a page"
        }
    }

    private func scannerStateTint(_ state: CameraController.ScannerState) -> Color {
        if state.waitingForDeviceSteady { return .red }
        if scannerJustCaptured { return Color(red: 0.2, green: 0.78, blue: 0.35) }
        guard state.trigger == ScannerEngine.Trigger.rectangle.rawValue else {
            return state.phase == ScannerEngine.State.disturbed.rawValue
                ? LL.amber : Color(red: 0.2, green: 0.78, blue: 0.35)
        }
        // Amber while the camera is working towards a shot (waiting for a page,
        // or holding on one); green once a page is banked and the operator is
        // free to swap it.
        return state.phase == ScannerEngine.State.captured.rawValue
            ? Color(red: 0.2, green: 0.78, blue: 0.35) : LL.amber
    }

    /// The hold window's progress bar — the rectangle trigger's own clock, drawn
    /// only while it is running.
    ///
    /// It exists because "Settling…" without it is the sentence that made a
    /// working shoot look broken: the operator has no way to tell a window that
    /// is filling from one that keeps restarting, and on a handheld phone the
    /// old engine restarted it on every single tick. A bar that visibly fills
    /// says "wait", and one that visibly resets says "you are moving".
    @ViewBuilder
    private func scannerHoldBar(_ state: CameraController.ScannerState) -> some View {
        if state.trigger == ScannerEngine.Trigger.rectangle.rawValue,
           let progress = state.settleProgress,
           state.phase == ScannerEngine.State.holding.rawValue {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                    Capsule()
                        .fill(LL.amber)
                        .frame(width: max(3, proxy.size.width * CGFloat(progress)))
                }
            }
            .frame(height: 3)
            .animation(.linear(duration: 0.1), value: progress)
            .accessibilityHidden(true)
        }
    }

    /// The locked pair every frame of the set was taken at — the number that
    /// makes a set trustable without inspecting it afterwards.
    private func scannerExposureText(_ state: CameraController.ScannerState) -> String {
        var text = "\(shutterText(state.shutterSeconds)) · ISO \(String(format: "%.0f", state.iso)) · locked"
        // What BLEND is doing to this run, in the line that already answers
        // "what is every frame of this set?" — a stacked pose is a different
        // file from an unstacked one and the set should say which it holds.
        if state.framesPerPose > 1 {
            text += " · ×\(state.framesPerPose) stack"
        }
        // Three answers, not two. "no RAW on this device" is a report of a
        // fallback, and printing it at someone who chose JPEG accuses the phone
        // of a limitation it doesn't have.
        if state.isCapturingRAW {
            text += " · RAW"
        } else {
            text += state.wantedRAW ? " · no RAW on this device" : " · JPEG"
        }
        return text
    }

    /// Where the pages are going, and — when the operator owns the boundary —
    /// the control that moves it on.
    ///
    /// **The line is shown in every state of every run**, including with a
    /// document per scan. It is the only confirmation that the grouping is
    /// working at all: a set is filed while it is being shot and read hours
    /// later, so a run that silently grouped the wrong way is discovered long
    /// after the paper has been put away.
    ///
    /// The button is 44 pt and carries its own name because of where it is
    /// used: one hand on the stack, the phone in the other, and a press due
    /// between two sheets. An icon at HUD scale is a thing you have to look at
    /// to be sure of, and looking at the phone is the one thing this screen is
    /// designed around not requiring.
    private var scannerDocumentRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(scannerDocumentLine, systemImage: "doc.on.doc")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .labelStyle(.titleAndIcon)
            if !newScanIsNewDocument {
                Button {
                    beginScannerDocument()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 16, weight: .semibold))
                        Text("New Document")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(LL.ink)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(LL.amber, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                // Never disabled, and never greyed. A second press with nothing
                // banked since the first is already a no-op inside
                // `beginScannerDocument`, and a control that dims itself at the
                // start of every run — when no page has landed yet — is a
                // control the operator reads as broken at exactly the moment
                // they are learning what it does.
                .accessibilityLabel("Start a new document")
                .accessibilityHint("Closes \(scannerDocumentLine) and starts the next document")
            }
        }
    }

    /// Discards the pose just taken without ending the shoot.
    ///
    /// This control earns its place here more than anywhere else in the app: a
    /// Scanner set is consumed whole by a solver, and one frame with a hand in
    /// it degrades the entire reconstruction rather than being a bad frame you
    /// scroll past. Catching it in the moment — while the object is still in
    /// the pose that needs re-shooting — costs one tap; catching it later costs
    /// the shoot.
    @ViewBuilder
    private func scannerDeleteLastButton(frames: Int) -> some View {
        Button {
            camera.deleteLastScannerFrame { _ in
                #if os(iOS)
                // Confirmation the operator can feel without looking up, which
                // is the same reason the fire itself is a click.
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                #endif
            }
        } label: {
            Label("Delete last", systemImage: "arrow.uturn.backward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(frames > 0 ? .white : .white.opacity(0.3))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(frames > 0 ? 0.14 : 0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(frames == 0)
        .accessibilityLabel("Delete the last captured angle")
    }

    /// A pose landed. The haptic is the point: paired with the system shutter
    /// sound the still capture makes for itself, it tells the operator the
    /// frame is banked and their hand can go back in — without their eyes
    /// leaving the object.
    private func announceScannerFrame() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    // MARK: - Scanner documents

    /// Files each page that lands into a document, and un-files one that is
    /// taken back.
    ///
    /// Boundaries are page *numbers*, not counts, because that is what the
    /// finished scan stores and what survives a page being deleted later. The
    /// rule itself is two lines: a page opens a document when one is pending,
    /// and the toggle decides whether the next page is pending again.
    ///
    /// `frames` is nil when the run has **ended**, and that case returns
    /// without touching anything. The camera clears `scannerState` and calls
    /// `onFinishPhotos` in one main-queue block, so a nil read as "every page
    /// was deleted" would wipe the grouping the finish is about to file —
    /// today only because SwiftUI happens to deliver this change after the
    /// finish handler, which is not a thing to depend on.
    private func recordScannerDocuments(previous: Int, frames: Int?) {
        guard scannerArmed, let frames else { return }
        if frames > previous {
            for page in (previous + 1)...frames {
                if scannerPendingNewDocument || scannerDocumentStarts.isEmpty {
                    scannerDocumentStarts.append(page)
                }
                scannerPendingNewDocument = newScanIsNewDocument
            }
        } else if frames < previous {
            let lostABoundary = scannerDocumentStarts.contains { $0 > frames }
            scannerDocumentStarts.removeAll { $0 > frames }
            // The deleted page had opened a document, so the document is gone
            // with it and the next page opens a fresh one. Under the toggle
            // that is true anyway.
            if lostABoundary || newScanIsNewDocument || scannerDocumentStarts.isEmpty {
                scannerPendingNewDocument = true
            }
        }
    }

    /// The New Document button: closes the current group and opens the next,
    /// with no capture in between. Only reachable while the toggle is off — with
    /// it on, every page does this by itself.
    private func beginScannerDocument() {
        guard !scannerPendingNewDocument else { return }
        scannerPendingNewDocument = true
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        #endif
    }

    /// How many documents this run has opened so far — 0 before the first page.
    private var scannerDocumentCount: Int { scannerDocumentStarts.count }

    /// The document the next page will land in, 1-based.
    private var scannerUpcomingDocument: Int {
        scannerPendingNewDocument || scannerDocumentStarts.isEmpty
            ? scannerDocumentCount + 1
            : scannerDocumentCount
    }

    /// Pages banked into the document currently open.
    private var scannerPagesInCurrentDocument: Int {
        guard let start = scannerDocumentStarts.last else { return 0 }
        return max(0, lastScannerFrameCount - start + 1)
    }

    /// The line the HUD carries about grouping, in every state of the run:
    /// which document the last page went into, and which page of *that
    /// document* it was.
    ///
    /// It describes the page just banked rather than the one coming, because
    /// that is the fact the operator is checking — "did that sheet land where I
    /// meant it to?". So with a document per scan it counts documents up and
    /// pages stay at 1 (Doc 1 · Page 1, Doc 2 · Page 1…), and with the toggle
    /// off the document holds still while the pages climb (Doc 1 · Page 3).
    /// Either way the line moving after a capture is the confirmation that the
    /// grouping is doing what the dial says.
    ///
    /// Page numbering restarts per document on purpose: that is the number the
    /// operator is holding in their head — sheet 3 of the contract, not frame
    /// 17 of the sitting.
    private var scannerDocumentLine: String {
        guard scannerDocumentCount > 0 else { return "Doc 1 · no pages yet" }
        // A New Document press with no capture behind it yet. Said in the
        // future tense because nothing has moved on disk — this is the one
        // state where the line has to confirm a *press* rather than a page,
        // and "Doc 1 · Page 3" after tapping New Document would read as the
        // tap having done nothing.
        if scannerPendingNewDocument && !newScanIsNewDocument {
            return "Doc \(scannerUpcomingDocument) · next page"
        }
        return "Doc \(scannerDocumentCount) · Page \(scannerPagesInCurrentDocument)"
    }

    /// Confirms a banked pose in the state line for a beat.
    ///
    /// The shutter's click and the haptic are the primary confirmation, and both
    /// are easy to miss with a hand still over the page and a room with any
    /// noise in it — so the line the operator is already watching says it too,
    /// then hands itself back to whatever the camera is waiting for next.
    private func flashScannerCaptured() {
        scannerFlashToken += 1
        let token = scannerFlashToken
        scannerJustCaptured = true
        Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard scannerFlashToken == token else { return }
            scannerJustCaptured = false
        }
    }

    private func blendStatusTint(_ status: LiveBlendStatus) -> Color {
        switch status {
        case .healthy: return .white.opacity(0.75)
        case .captureFailed, .tooHot: return .red
        default: return LL.amber
        }
    }

    private func intervalLabel(_ seconds: Double) -> String {
        seconds == floor(seconds) ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
    }

    // MARK: - Mode + zoom row

    private var modeRow: some View {
        #if os(iOS)
        let spacing: CGFloat = 14
        #else
        let spacing: CGFloat = 22
        #endif
        return HStack(spacing: spacing) {
            Button {
                mode = .photo
            } label: {
                Text("PHOTO")
                    .foregroundStyle(mode == .photo ? LL.amber : .white.opacity(0.5))
            }
            .buttonStyle(.plain)

            Button {
                mode = .interval
            } label: {
                Text("INTERVAL")
                    .foregroundStyle(mode == .interval ? LL.amber : .white.opacity(0.5))
            }
            .buttonStyle(.plain)

            Button {
                mode = .video
            } label: {
                Text("VIDEO")
                    .foregroundStyle(mode == .video ? LL.amber : .white.opacity(0.5))
            }
            .buttonStyle(.plain)

            if camera.availableStops.count > 1 {
                zoomChips
            }
        }
        .font(.system(size: 13, weight: .semibold))
    }

    private var zoomChips: some View {
        HStack(spacing: 8) {
            ForEach(camera.availableStops) { stop in
                let isSelected = camera.selectedStop == stop
                Button {
                    camera.selectStop(stop)
                } label: {
                    Text(stop.chipLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? LL.amber : .white.opacity(0.6))
                        .frame(minWidth: 30, minHeight: 30)
                        .background(
                            Circle().stroke(
                                isSelected ? LL.amber.opacity(0.8) : .white.opacity(0.25),
                                lineWidth: 1
                            )
                        )
                        // Enhanced (non-optical) stops carry a dot until the
                        // signed-off badge treatment lands with the SVGs.
                        .overlay(alignment: .topTrailing) {
                            if stop.kind != .optical {
                                Circle()
                                    .fill(LL.amber.opacity(isSelected ? 0.9 : 0.45))
                                    .frame(width: 4, height: 4)
                                    .offset(x: -1, y: 1)
                            }
                        }
                }
                .buttonStyle(ZoomChipButtonStyle())
            }
        }
    }

    // MARK: - Photo controls

    /// Photo mode's single dial: the blend depth, with Bulb folded in as the
    /// top option. The dropdown mirrors Interval's discrete presets
    /// (Bulb · 20 · 10 · 5 · 3 · Off), so the two modes read identically.
    /// Selecting Bulb arms hold-open capture; any numeric option (or Off)
    /// disarms it and sets the stack depth. Photo captures at a fixed fast
    /// burst, so there's no spacing picker. Its own `Equatable` view for the
    /// same reason as `intervalPickerRow` — see CaptureDials.swift: this row
    /// stays on screen while the live shape pass publishes a few times a
    /// second, and must not re-render with it.
    private var photoControlsRow: some View {
        let blend = PhotoBlendDial(
            isBulb: photoBulbMode,
            frames: photoBlendDepth,
            onSelectBulb: { photoBulbMode = true },
            onSelectFrames: { frames in
                photoBulbMode = false
                photoBlendDepth = frames
            }
        )
        .equatable()
        // Auto shapes on: its three dials join BLEND — one line where they
        // fit (landscape, the Mac), two on a portrait phone. Each dial is
        // `.equatable()` on its own selection, like BLEND: the open menu
        // must not see this body's re-renders (see `ShapeSearchDial`).
        let search = shapeSearch
        let family = ShapeSearchDial(caption: "SHAPES", options: ShapeSearch.Family.allCases, selected: search.family,
                                     title: \.title, onSelect: { shapeFamilyToken = $0.rawValue }).equatable()
        let sensitivity = ShapeSearchDial(caption: "SENSITIVITY", options: ShapeSearch.Sensitivity.allCases, selected: search.sensitivity,
                                          title: \.title, onSelect: { shapeSensitivityToken = $0.rawValue }).equatable()
        let size = ShapeSearchDial(caption: "SIZE", options: ShapeSearch.Size.allCases, selected: search.size,
                                   title: \.title, onSelect: { shapeSizeToken = $0.rawValue }).equatable()
        return Group {
            if autoShapesEnabled {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        blend
                        family
                        sensitivity
                        size
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            blend
                            family
                        }
                        HStack(spacing: 8) {
                            sensitivity
                            size
                        }
                    }
                }
            } else {
                blend
            }
        }
    }

    /// The dials as one value, from their remembered tokens.
    private var shapeSearch: ShapeSearch {
        ShapeSearch(
            family: ShapeSearch.Family(rawValue: shapeFamilyToken) ?? .all,
            sensitivity: ShapeSearch.Sensitivity(rawValue: shapeSensitivityToken) ?? .medium,
            size: ShapeSearch.Size(rawValue: shapeSizeToken) ?? .all)
    }

    // MARK: - Recent capture tile

    /// Side of the lower-left recent-capture tile.
    private static let recentTileSize: CGFloat = 60
    /// The portrait shutter row's reserved height: the cluster's box less its
    /// 2 pt margins, so the tile's centre and the pinned ring's agree (758 pt
    /// on a 393×852 screen, with the row's 12 pt bottom padding).
    private static let shutterRowHeight: CGFloat = 96

    /// The newest project, whatever its kind, as a tappable tile — the camera's
    /// way out to everything already shot, the way Apple's camera does it. It
    /// carries no state of its own: `refreshRecentCapture` keeps it in step with
    /// the library, and it's invisible until there is something to show.
    private var recentCaptureButton: some View {
        Button(action: openGallery) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .overlay {
                    if let recentThumbnail {
                        recentThumbnail
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: Self.recentTileSize, height: Self.recentTileSize)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.35), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .opacity(recentHeroURL == nil ? 0 : 1)
        .allowsHitTesting(recentHeroURL != nil)
        .accessibilityLabel("Open gallery")
        .accessibilityHidden(recentHeroURL == nil)
    }

    /// Resolve the newest project's hero asset and decode its thumbnail. Cheap
    /// to call repeatedly: an unchanged hero returns before touching the disk,
    /// and the decode itself goes through the shared cache the grids use.
    private func refreshRecentCapture() {
        let hero = model.captures.first.flatMap { model.heroAsset(for: $0) }
        guard hero?.url != recentHeroURL else { return }
        recentHeroURL = hero?.url
        recentThumbnail = nil
        guard let hero else { return }
        Task {
            let image = await ProjectThumbnailCache.shared.thumbnail(for: hero.url, kind: hero.kind)
            // A newer capture may have landed while this one decoded.
            guard recentHeroURL == hero.url else { return }
            recentThumbnail = image
        }
    }

    /// Leave the camera for the Gallery. The camera is presented over the tabs,
    /// so it has to dismiss itself as well as move the selection.
    private func openGallery() {
        closeCapture()
        model.requestedTab = .gallery
    }

    // MARK: - Shutter row

    private var shutterButton: some View {
        Button(action: shutterTapped) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 76, height: 76)

                if let progress = targetRingProgress {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(targetReached ? Color.green : LL.amber, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 76, height: 76)
                }

                if isCapturing {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red)
                        .frame(width: 32, height: 32)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 60, height: 60)
                    shutterBadge
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(camera.isAuthorized != true)
        .accessibilityLabel(isCapturing ? "Stop" : "Record")
    }

    /// How full the shutter's target ring is, or nil when no target is running.
    /// The two shapes of target fill it from different quantities — a clip
    /// target from elapsed time, a Scanner target from poses banked — which is
    /// the whole difference between them.
    private var targetRingProgress: Double? {
        guard let target = activeTarget else { return nil }
        if let poses = target.poseTarget {
            guard let state = camera.scannerState else { return nil }
            return min(1, Double(state.frames) / Double(max(1, poses)))
        }
        guard camera.isRecording else { return nil }
        return min(1, elapsedSeconds / max(1, target.recordSeconds))
    }

    /// "2s" while the delay is armed; the live countdown once tapped.
    private var shutterDelayLabel: String? {
        if let deadline = delayedStartAt {
            return "\(max(1, Int(deadline.timeIntervalSince(now).rounded(.up))))"
        }
        return shutterDelayEnabled ? "2s" : nil
    }

    /// Centered readout on the idle shutter: BULB when armed, and the
    /// self-timer countdown/"2s", sharing one slot and type treatment.
    @ViewBuilder
    private var shutterBadge: some View {
        HStack(spacing: 5) {
            if mode == .photo && photoBulbMode {
                Text("BULB")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white)
            }
            if let label = shutterDelayLabel {
                Text(label)
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
    }

    /// On-phone shutter taps honor the 2 s delay when armed (and a tap
    /// during the countdown cancels it). Stops are always immediate, and the
    /// Watch remote calls `shutterAction()` directly — no delay on the wrist.
    private func shutterTapped() {
        if delayedStartAt != nil {
            delayedStartAt = nil
            return
        }
        if !isCapturing && shutterDelayEnabled {
            delayedStartAt = Date().addingTimeInterval(2)
            return
        }
        shutterAction()
    }

    private var isCapturing: Bool {
        camera.isRecording || camera.isIntervalRunning || camera.isLiveBlendRunning
    }

    // MARK: - Settings ▸ Display

    /// Everything Settings ▸ Display asked for, as one value the dimmer takes
    /// whole. Recomputed with the body, compared by the modifier's `onChange`,
    /// so a flip of any row — Settings, the Watch, the remote, the cluster's
    /// own Dim toggle — lands the same way.
    private var shootDisplayPlan: ShootDisplayPlan {
        let running = isCapturing && mode != .photo
        return ShootDisplayPlan(
            runActive: running,
            // The run's own toggle, not the setting: the setting only seeds it.
            blackout: running && runDimEngaged,
            reduceBrightness: running && reduceBrightness,
            peekEnabled: scheduledPeek,
            trigger: ShootPeekTrigger(rawValue: peekTrigger) ?? .clock,
            everyMinutes: peekEveryMinutes,
            runStartedAt: running ? camera.captureRunStartedAt : nil)
    }

    /// What a scheduled peek shows. Built here rather than in the card because
    /// every judgement in it — is the cadence being met, is the thermal state
    /// worth colouring — is one this screen already makes for the live readout,
    /// and the two must never disagree.
    private var peekReadout: ShootPeekReadout {
        var readout = ShootPeekReadout()
        readout.title = peekTitle
        readout.frameCount = camera.isLiveBlendRunning
            ? camera.liveBlendOutputCount
            : camera.photoCount
        readout.thumbnail = peekThumbnail
        readout.thumbnailAge = peekThumbnailAge
        readout.elapsed = elapsedIntervalText
        readout.thermal = thermalWord
        switch thermalState {
        case .serious: readout.thermalLevel = .warn
        case .critical: readout.thermalLevel = .alert
        default: readout.thermalLevel = .normal
        }
        if let frames = headroom?.frames {
            readout.space = frames.formatted(.number)
            switch headroom?.level {
            case .critical: readout.spaceLevel = .alert
            case .low: readout.spaceLevel = .warn
            default: readout.spaceLevel = .normal
            }
        }
        readout.exposure = runExposureText?.text
        if let diagnostics = camera.liveBlendDiagnostics, camera.isLiveBlendRunning {
            // A blend run is the only one with a cadence it can miss: the
            // engine already grades every window, so the verdict is its word
            // rather than a second opinion computed here.
            readout.onSchedule = diagnostics.status == .healthy
            var parts = ["blend \(diagnostics.requestedFramesPerBlend)"]
            if let format = diagnostics.outputFormatLabel { parts.append(format) }
            parts.append(diagnostics.status.rawValue.lowercased())
            readout.blendLine = parts.joined(separator: " · ")
        }
        return readout
    }

    /// The shoot's own name when the schedule carried one — otherwise what
    /// kind of run this is, which is the next most useful thing to read at
    /// three metres.
    private var peekTitle: String? {
        if let label = model.scheduledRecording?.label, !label.isEmpty { return label }
        if camera.scannerState != nil { return "Scanner" }
        if camera.holyGrailState != nil { return "Holy Grail" }
        if camera.ladderState != nil { return "Light Ladder" }
        switch mode {
        case .interval: return "Interval"
        case .video: return "Video"
        case .photo: return nil
        }
    }

    /// Decode the newest banked frame for the card. Once every few minutes, so
    /// it goes through the same cache the grids use rather than earning a
    /// pipeline of its own — and a frame stamped before this run started is
    /// the PREVIOUS shoot's, which the card must never show.
    private func refreshPeekThumbnail() {
        peekThumbnail = nil
        peekThumbnailAge = nil
        guard let banked = camera.latestFrame else {
            #if DEBUG
            // `LL_PEEK` on a simulator: no camera, so no run ever banks a
            // frame. Borrow the newest project's hero so the mirror can be
            // drawn against the state the card is really in.
            if ProcessInfo.processInfo.environment["LL_PEEK"] != nil {
                peekThumbnail = recentThumbnail
                peekThumbnailAge = recentThumbnail == nil ? nil : 12
            }
            #endif
            return
        }
        if let runStart = camera.captureRunStartedAt, banked.at < runStart { return }
        peekThumbnailAge = Date().timeIntervalSince(banked.at)
        Task {
            let image = await ProjectThumbnailCache.shared.thumbnail(for: banked.url, kind: .image)
            // The peek may have closed, or a newer frame landed, while this
            // decoded.
            guard shootDimmer.peeking, camera.latestFrame?.url == banked.url else { return }
            peekThumbnail = image
        }
    }

    /// Mirror the mode onto the camera for the session log — "Bulb" is Photo
    /// with the open-ended dial armed, and reads as its own mode in a log.
    /// The arguments exist because SwiftUI's `onChange` hands over the new
    /// value before the `@State` behind it has been written.
    private func syncLoggedCaptureMode(mode newMode: CaptureMode? = nil, bulb: Bool? = nil) {
        let resolvedMode = newMode ?? mode
        let resolvedBulb = bulb ?? photoBulbMode
        camera.loggedCaptureMode = (resolvedMode == .photo && resolvedBulb)
            ? "Bulb" : resolvedMode.rawValue
    }

    private func shutterAction() {
        switch mode {
        case .video:
            if camera.isRecording {
                camera.stopRecording()
            } else {
                framingStartedAt = Date()
                #if os(iOS)
                // Begin logging a GPX track for the take; flushed to a sidecar
                // in the video-finish handler.
                if gpsEnabled { LocationService.shared.startGPXPolling() }
                #endif
                camera.startRecording(mode: sequenceMode)
            }
        case .interval:
            // Scanner runs through `isIntervalRunning` like the plain timer
            // shoot, so its stop has to be tested first — `stopInterval` would
            // reach a timer that was never started.
            if camera.isScannerActive {
                camera.stopScanner()
            } else if camera.isIntervalRunning {
                camera.stopInterval()
            } else if camera.isLiveBlendRunning {
                camera.stopLiveBlend()
            } else {
                framingStartedAt = Date()
                startIntervalCapture()
            }
        case .photo:
            if camera.isLiveBlendRunning {
                // A DNG shot is mid-flight — a capped stack (which also
                // auto-stops) or an open Bulb window. This press ends it; the
                // blended DNG lands in `onFinishLiveBlend`.
                photoDNGAutoStop = false
                camera.stopLiveBlend()
            } else if camera.isIntervalRunning {
                // A burst is mid-flight — a capped steadied stack or an open
                // Bulb exposure. Either way this press ends it; a Bulb run then
                // stacks everything captured in `onFinishPhotos`.
                camera.stopInterval()
            } else if photoBulbMode {
                startBulbCapture()
            } else {
                startPhotoCapture()
            }
        }
    }

    /// Bulb: an uncapped plain-still burst that runs until the user taps the
    /// shutter again.
    private func startBulbCapture() {
        framingStartedAt = Date()
        dismissBurstPill()  // re-appears on the first shot
        takeViewfinderShapes()
        // DNG Bulb: one open-ended live-blend RAW window that stacks every
        // captured frame into a single blended DNG when the user stops. No
        // auto-stop — the second shutter tap closes it (see `shutterAction`).
        if wantsPhotoDNG {
            photoDNGAutoStop = false
            camera.startLiveBlend(
                every: Self.photoBulbDNGInterval,
                depth: .unthrottled,
                preferDNG: true,
                options: liveBlendDNGOptions,
                captureModeName: "photo")
            return
        }
        // Uncapped plain-still burst on the photo-output timer: the engine
        // floors uncapped spacing to 0.5 s, so this samples at ~2 fps until
        // stopped, and the stills stack into one long exposure in post — the
        // same `onFinishPhotos` → `processPhotoBurst` path a capped Photo burst
        // uses.
        camera.startInterval(every: Self.photoBurstInterval, frameCap: nil)
    }

    /// The DNG capture experiments (bracketed RAW, tight burst, fast capture)
    /// apply to Photo-mode DNG shots exactly as they do to Interval.
    private var liveBlendDNGOptions: LiveBlendCaptureOptions {
        LiveBlendCaptureOptions(
            responsiveCapture: model.liveBlendResponsiveCapture,
            burstScheduling: model.liveBlendBurstCapture,
            bracketedRAW: model.liveBlendBracketedRAW)
    }

    /// Photo mode: a capped-frame still capture. A single snapshot (blend off)
    /// captures one frame; a burst captures `photoBlendDepth` frames that
    /// stack into one long exposure in post.
    private func startPhotoCapture() {
        framingStartedAt = Date()
        dismissBurstPill()  // re-appears on the first shot
        takeViewfinderShapes()
        // DNG: run the live-blend RAW pipeline for a single window — it blends
        // `photoBlendDepth` RAW frames into one DNG (or emits one untouched DNG
        // with blend Off, depth 1), exactly as Interval does. The first
        // finished output auto-stops the run (see the output-count change
        // handler) and it registers as a one-asset Photo, camera left live.
        //
        // A one-shot needs a window long enough to gather its frames and it
        // fires them back-to-back — burst is forced here regardless of the
        // Interval capture options so the single window fills fast and never
        // closes empty.
        if wantsPhotoDNG {
            let frames = max(1, photoBlendDepth)
            var options = liveBlendDNGOptions
            options.burstScheduling = true
            photoDNGAutoStop = true
            camera.startLiveBlend(
                every: Self.photoDNGWindowSeconds(forFrames: frames),
                depth: .fixed(frames),
                preferDNG: true,
                options: options,
                captureModeName: "photo")
            return
        }
        startIntervalCapture(photoModeFrameCap: max(1, photoBlendDepth))
    }

    /// Routes an Interval shoot to the engine its dials call for:
    /// plain JPEG stills come from the photo-output timer (Apple's full
    /// processed pipeline, not a video-tap grab), everything else — any
    /// blending, or DNG output — runs through the blend pipeline, which
    /// handles a 1-frame DNG window as untouched originals. DNG on an
    /// unsupported source degrades per dial: blends fall back to the JPEG
    /// video tap, unblended shoots to real JPEG stills.
    private func startIntervalCapture(photoModeFrameCap: Int? = nil) {
        // Photo mode captures plain stills at a fast fixed burst and auto-stops
        // after its frame cap; any blend happens in post from those stills, so
        // it never touches the live-blend pipeline or the DNG path.
        if let cap = photoModeFrameCap {
            camera.startInterval(every: Self.photoBurstInterval, frameCap: cap)
            return
        }
        // A remembered Safe depth can outlive its basis; never start a
        // shoot on a guess.
        revalidateSafeDepth()
        let wantsDNG = model.intervalOutputFormat == .dng && camera.liveBlendDNGSupport.isSupported
        // Holy Grail is an exposure layer, not an engine of its own: the
        // shoot is the ordinary Interval shoot the dials describe — the
        // format dial picks JPEG or DNG, the BLEND dial picks how many frames
        // are averaged into each image — and the ramp decides what exposure
        // each window is shot at. Deliberately one path: the JPEG route takes
        // its frames from the video stream, so it is **silent**, where a
        // per-frame still capture makes the system shutter sound on every
        // frame, which is intolerable in a timelapse.
        // Scanner takes the shutter away from the timer entirely, so it is the
        // one Interval variant that isn't a spacing at all. The steadiness
        // monitor is armed as a *gate* here rather than as a tail-frame log:
        // the camera asks it, per pose, whether the phone is still enough to
        // shoot (see `CameraController.scannerDeviceIsSteady`).
        if scannerArmed {
            steadiness.resetLog()
            steadiness.start()
            // A run's grouping starts empty with document 1 pending, whatever
            // the last run left behind — the camera screen isn't torn down
            // between two scans in the same sitting.
            lastScannerFrameCount = 0
            scannerDocumentStarts = []
            scannerPendingNewDocument = true
            camera.scannerDeviceIsSteady = { [weak steadiness] in
                guard let steadiness else { return true }
                return steadiness.magnitude < steadiness.stillThreshold
            }
            camera.startScanner(
                frameCap: activeTarget?.autoStop == true ? activeTarget?.poseTarget : nil,
                // The format dial governs Scanner like every other still mode.
                // It used to be ignored here, so a shoot set to JPEG wrote DNGs.
                preferRAW: model.intervalOutputFormat == .dng,
                // The stock itself, not a trigger derived from it: the run picks
                // its machine from this (Auto = the turntable's motion, a named
                // stock = "a page, holding still") *and* tests every candidate
                // rectangle against its proportions, so a quad that cannot be an
                // A4 never becomes one.
                aspect: scannerAspect,
                // BLEND, in the only form a pose can honour: frames averaged
                // into this pose. The adaptive depths are disabled under Scanner
                // (they size themselves against a timed window, and a pose has
                // none), so a non-fixed value here means a plain pose.
                framesPerPose: blendDepth.fixedFrames ?? 1)
            return
        }
        if ladderArmed {
            // The rung decides the spacing and depth; the values passed here
            // are placeholders the controller overrides from the opening rung
            // — the light's rung on the phone, the operator's on the Mac.
            steadiness.resetLog()
            steadiness.start()
            camera.startLiveBlend(
                every: interval,
                depth: .fixed(1),
                preferDNG: wantsDNG,
                options: liveBlendDNGOptions,
                holyGrail: true,
                autoInterval: false,
                ladder: selectedLadder,
                ladderRung: Self.ladderStepsByHand ? previewRungIndex : nil)
            return
        }
        if holyGrailArmed {
            steadiness.resetLog()
            steadiness.start()
            camera.startLiveBlend(
                every: intervalIsAuto ? autoIntervalSeed : interval,
                depth: blendDepth,
                preferDNG: wantsDNG,
                options: liveBlendDNGOptions,
                holyGrail: true,
                autoInterval: intervalIsAuto)
            return
        }
        if !wantsDNG && blendDepth == .fixed(1) {
            // Only the plain-JPEG interval path finishes through
            // `onFinishPhotos`, so arm the motion log here — each frame is
            // tagged in the `photoCount` handler, the tail analysed at finish.
            steadiness.resetLog()
            steadiness.start()
            camera.startInterval(every: interval)
            return
        }
        camera.startLiveBlend(
            every: interval,
            depth: blendDepth,
            preferDNG: wantsDNG,
            options: liveBlendDNGOptions)
    }

    /// A Scanner run is under way — the shutter row's accessories step aside
    /// for it (see `clusterSlot`).
    private var scannerRunInProgress: Bool { camera.scannerState != nil }

    // MARK: - Run-time toggles and the run readout

    /// A run's own toggles start here — Dim from Settings ▸ Display ▸ Blackout
    /// viewfinder, Info off — and the screenshot hooks stage them for the
    /// mirrors:
    /// `LL_RUNINFO=1` opens the info panel, `LL_RUNDIM=off` keeps the screen
    /// up with the toggle off, `LL_RUNDIM=wake` engages Dim and holds the
    /// wake window open — the amber-moon state every running mirror draws.
    private func seedRunToggles() {
        runDimEngaged = blackoutViewfinder
        showRunInfo = false
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["LL_RUNINFO"] != nil { showRunInfo = true }
        switch environment["LL_RUNDIM"] {
        case "off":
            runDimEngaged = false
        case "wake":
            runDimEngaged = true
            // The cover engages on the next body pass; wake once it has.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                shootDimmer.wake(for: 3600)
            }
        default:
            break
        }
        // `LL_PEEK=card` freezes a scheduled peek open. Same reason as the
        // hooks either side of it: the simulator has no camera, so no schedule
        // has frames to fire against and the card is unreachable off-device.
        if environment["LL_PEEK"] != nil {
            runDimEngaged = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                shootDimmer.freezePeekForDesign()
            }
        }
        #endif
    }

    /// Slot 1 of a running cluster: screen dim. On floors the screen at once
    /// (`ShootDimming` → `setEngaged`); a touch on the cover wakes it for
    /// 30 s and it re-dims by itself; turning this off inside that window
    /// cancels the re-dim. iOS only — the Mac has no panel to floor, so its
    /// slot stays empty.
    @ViewBuilder
    private var dimToggleCircle: some View {
        #if os(iOS)
        Button {
            runDimEngaged.toggle()
        } label: {
            Image(systemName: runDimEngaged ? "moon.fill" : "moon")
                .font(.system(size: 18))
                .foregroundStyle(runDimEngaged ? LL.amber : .white)
                .frame(width: 44, height: 44)
                .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(runDimEngaged ? "Stop dimming the screen" : "Dim the screen")
        #endif
    }

    /// Slot 2 of a running cluster: the info panel, off by default per run.
    private var runInfoToggleCircle: some View {
        Button {
            showRunInfo.toggle()
        } label: {
            Image(systemName: showRunInfo ? "info.circle.fill" : "info.circle")
                .font(.system(size: 18))
                .foregroundStyle(showRunInfo ? LL.amber : .white)
                .frame(width: 44, height: 44)
                .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showRunInfo ? "Hide run details" : "Show run details")
    }

    /// The one amber line over a running Interval shoot (design 2026-09-04,
    /// third pass): the exposure the run is at — shutter · ISO · scene EV —
    /// and, when the ramp has one, its status on the end: "ISO ramping"
    /// while the shutter sits at its ceiling, "past the sensor's limit" in
    /// red once frames stop tracking the light. Dynamic and Ladder read the
    /// ramp's state; a Basic run reads the pair its last frame was taken at
    /// (`liveExposure`); the Mac's hand-stepped ladder has no pair and shows
    /// the rung's line instead.
    @ViewBuilder
    private var runExposureLine: some View {
        if let line = runExposureText {
            HStack {
                Text(line.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(line.clipped ? Color.red : LL.amber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
        }
    }

    private var runExposureText: (text: String, clipped: Bool)? {
        if let state = camera.holyGrailState {
            // A ramp the camera is refusing: print what the sensor IS
            // delivering and say so. The target above it is a number the
            // camera is not on, and its limit flag describes nothing real —
            // on 2026-09-04 that pair read 1/71429 in red over a correctly
            // exposed dusk, and the shoot was stopped for it.
            guard state.isDriving else {
                var text: String
                if let shutter = state.deliveredShutterSeconds, let iso = state.deliveredISO {
                    text = "\(shutterText(shutter)) · ISO \(String(format: "%.0f", iso))"
                    text += String(format: " · EV %.1f", state.sceneEV)
                } else {
                    text = "on AE"
                }
                text += " · ramp not driving"
                return (text, false)
            }
            var text = "\(shutterText(state.shutterSeconds)) · ISO \(String(format: "%.0f", state.iso))"
            text += String(format: " · EV %.1f", state.sceneEV)
            if state.isClipped {
                text += " · past the sensor's limit"
            } else if state.isISORamping {
                text += " · ISO ramping"
            }
            return (text, state.isClipped)
        }
        if let ladder = camera.ladderState {
            return (ladder.readoutLine, false)
        }
        if let live = camera.liveExposure {
            var text = "\(shutterText(live.shutterSeconds)) · ISO \(String(format: "%.0f", live.iso))"
            if let sceneEV = live.sceneEV { text += String(format: " · EV %.1f", sceneEV) }
            return (text, false)
        }
        return nil
    }

    /// Behind the cluster's Info toggle: the ONE diagnostics panel — the
    /// blend engine's when it runs (frames in the window · last, cadence,
    /// cost · format · health · thermal), a plain run's count · cadence ·
    /// elapsed · thermal otherwise. Nothing else: the ramp readout that used
    /// to stack under it duplicated every line it had.
    @ViewBuilder
    private var runInfoPanel: some View {
        if camera.isLiveBlendRunning, camera.liveBlendDiagnostics != nil {
            VStack(alignment: .leading, spacing: 4) {
                blendDiagnosticsReadout
                rampRefusedNote
            }
        } else if camera.isIntervalRunning {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("frames \(camera.photoCount) · every \(intervalLabel(interval))")
                    Text("elapsed \(elapsedIntervalText)")
                    Text("thermal \(thermalWord)")
                }
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                // A ramped stills run (no blend engine) can be refused too.
                rampRefusedNote
            }
        }
    }

    /// The thermal state as the info panel's last word.
    private var thermalWord: String {
        switch thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Every iOS Interval run carries the ±EV bias slider mid-run — Scanner
    /// excepted, its exposure is locked for the set. The Mac has no exposure
    /// control to offer.
    private var runHasBiasSlider: Bool {
        #if os(iOS)
        return mode == .interval && isCapturing && camera.scannerState == nil
        #else
        return false
        #endif
    }

    /// Landscape's seat for the run readout: the amber line over the bias
    /// slider on one dark panel in the viewfinder's corner. Portrait draws
    /// the line in `intervalStatusRow` and the slider in `exposurePanel`.
    @ViewBuilder
    private var runReadoutCapsule: some View {
        if runExposureText != nil || runHasBiasSlider {
            VStack(alignment: .leading, spacing: 8) {
                runExposureLine
                #if os(iOS)
                if runHasBiasSlider {
                    exposureSlider(
                        icon: "plusminus.circle",
                        value: holyGrailBiasBinding,
                        range: Self.exposureStopsRange)
                }
                #endif
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Shutter cluster

    /// The slot offsets round the ring, per orientation — the numbers in
    /// docs/design/components/shutter-cluster.<state>.<orientation>.svg.
    /// Portrait keeps the four 44 pt circles ≈9 pt clear of the ring;
    /// landscape is 10 pt narrower and 10 pt taller (Steven, 2026-09-04),
    /// spending the rail's height instead of its width. The Mac takes the
    /// landscape set: its capture window is the landscape tree.
    private struct ShutterClusterGeometry {
        let dx: CGFloat
        let dy: CGFloat
        let isLandscape: Bool
        static let portrait = ShutterClusterGeometry(dx: 66, dy: 26, isLandscape: false)
        static let landscape = ShutterClusterGeometry(dx: 56, dy: 36, isLandscape: true)
        /// The cluster's box — the component's viewBox: 180×100 / 160×120.
        var box: CGSize { CGSize(width: 2 * (dx + 22) + 4, height: 2 * (dy + 22) + 4) }
    }

    /// Where the ring's centre sits, in the stage's coordinates, and which
    /// slot geometry goes with it. The ring is PINNED TO THE DEVICE: 94 pt in
    /// from the home-indicator edge on the screen's centreline, whichever
    /// way the interface is turned — a rotation moves every other piece of
    /// chrome and not this one. The stage is inset by the safe area, so the
    /// point is found on the full screen and slid back by the leading/top
    /// insets. The scene's own interface orientation says which edge the
    /// home indicator is on (rotation lock included); the stage's shape
    /// says whether the turn has actually happened yet. On the Mac there is
    /// no edge to pin to: a landscape-shaped window fits the cluster 8 pt
    /// inside its trailing edge at mid-height (the mirrors' 86 pt), a
    /// portrait-shaped one follows the phone's rule.
    private func shutterClusterPin(in geometry: GeometryProxy) -> (center: CGPoint, geometry: ShutterClusterGeometry) {
        let insets = geometry.safeAreaInsets
        let full = CGSize(
            width: geometry.size.width + insets.leading + insets.trailing,
            height: geometry.size.height + insets.top + insets.bottom)
        let landscape = full.width > full.height
        let physical: CGPoint
        #if os(iOS)
        // `orientation` is read so a rotation re-evaluates this.
        _ = orientation
        switch currentInterfaceOrientation() {
        case .landscapeLeft where landscape:
            physical = CGPoint(x: 94, y: full.height / 2)
        case .portraitUpsideDown where !landscape:
            physical = CGPoint(x: full.width / 2, y: 94)
        default:
            physical = landscape
                ? CGPoint(x: full.width - 94, y: full.height / 2)
                : CGPoint(x: full.width / 2, y: full.height - 94)
        }
        #else
        physical = landscape
            ? CGPoint(x: full.width - 86, y: full.height / 2)
            : CGPoint(x: full.width / 2, y: full.height - 94)
        #endif
        return (CGPoint(x: physical.x - insets.leading, y: physical.y - insets.top),
                landscape ? .landscape : .portrait)
    }

    /// The shutter cluster — ring plus its four slots — pinned to the device
    /// (`shutterClusterPin`) over both layouts' chrome, so the ring never
    /// moves on rotation and one view serves every mode and both
    /// orientations. Landscape hangs the exposure readout under it, where
    /// the rail's column used to carry it; portrait's lives in `exposurePanel`.
    private func shutterClusterLayer(in geometry: GeometryProxy) -> some View {
        let pin = shutterClusterPin(in: geometry)
        // The plain text readouts fit centred under the cluster's own narrow
        // box; the manual-exposure wheels need real drag room (240 pt) that
        // the box's ~94 pt clearance from the physical edge cannot centre
        // without running off-screen, so they anchor to whichever side of
        // the cluster already faces the viewfinder — the one direction with
        // room to grow — instead. Landscape's proposed home for a panel that
        // has no existing landscape placement to match (portrait's lives in
        // `exposurePanel`; this is `landscapeClusterReadout`'s own equivalent).
        let manualPanel = pin.geometry.isLandscape && mode == .photo && photoManualExposure
        let anchor: Alignment = manualPanel ? (shutterClusterLeads ? .topLeading : .topTrailing) : .top
        return shutterCluster(pin.geometry)
            .overlay(alignment: anchor) {
                if pin.geometry.isLandscape {
                    landscapeClusterReadout
                        .frame(width: manualPanel ? 240 : pin.geometry.box.width)
                        .offset(y: pin.geometry.box.height + 6)
                }
            }
            .position(pin.center)
    }

    /// Ring in the middle, four 44 pt circles on the diagonals. Slot 1 is
    /// top-leading, 2 top-trailing, 3 bottom-leading, 4 bottom-trailing —
    /// the viewer's frame, in both orientations.
    private func shutterCluster(_ g: ShutterClusterGeometry) -> some View {
        ZStack {
            shutterButton
            clusterSlot(1).offset(x: -g.dx, y: -g.dy)
            clusterSlot(2).offset(x: g.dx, y: -g.dy)
            clusterSlot(3).offset(x: -g.dx, y: g.dy)
            clusterSlot(4).offset(x: g.dx, y: g.dy)
        }
        .frame(width: g.box.width, height: g.box.height)
    }

    /// What a slot holds. Idle: 1 grid · 2 delay · 3 AE/AF lock (M in Photo)
    /// · 4 auto shapes in Photo, empty elsewhere (the Hand that used to sit
    /// there was retired 2026-09-11 — it only ever gated a blended Photo burst
    /// and Bulb, and toggled nothing in Interval or Video).
    /// Once a shoot is under way — any shoot, `isCapturing`, not only a movie
    /// — all four hide (design 2026-09-04): the slots stay reserved, so the
    /// cluster's footprint never changes, and the run-time controls take the
    /// bottom pair. A Video take: the speed-burst / marker trigger in 3, the
    /// burst count in 4. A Scanner run: the manual pose shutter in 4, and 3
    /// empty on purpose — every idle toggle answers a question `startScanner`
    /// has already settled (AE/AF/WB locked for the set, the steadiness gate
    /// wired into the fire path, a self-timer meaningless to a shutter the
    /// scene is pressing). Interval runs used to keep all four live — a
    /// mid-run lock tap toggled the exposure of a running shoot; since the
    /// 2026-09-04 third pass every Interval and Video run carries the two
    /// run-time toggles in the top pair instead: 1 screen Dim, 2 Info. A
    /// Photo burst lasts seconds and has nothing to dim or explain, so its
    /// slots stay empty.
    @ViewBuilder
    private func clusterSlot(_ slot: Int) -> some View {
        if scannerRunInProgress {
            if slot == 4 { scannerManualCaptureButton }
        } else if camera.isRecording {
            switch slot {
            case 1: dimToggleCircle
            case 2: runInfoToggleCircle
            case 3: liveMomentTrigger
            default: rampIntervalCountBadge
            }
        } else if isCapturing {
            if mode != .photo {
                if slot == 1 {
                    dimToggleCircle
                } else if slot == 2 {
                    runInfoToggleCircle
                }
            }
        } else {
            switch slot {
            case 1: gridToggleCircle
            case 2: shutterDelayCircle
            case 3:
                // `|| photoManualExposure`: once manual is actually engaged,
                // keep showing M even if `supportsManualExposure` later reads
                // false (a lens switched mid-session, or the DEBUG hook
                // forcing the panel open on the simulator's cameraless
                // device) — the alternative is a padlock glyph sitting next
                // to an open manual-exposure panel, which is worse than
                // showing M for a control that would no-op.
                if mode == .photo, camera.supportsManualExposure || photoManualExposure {
                    manualExposureCircle
                } else {
                    exposureLockCircle
                }
            default:
                if mode == .photo { autoShapesToggleCircle }
            }
        }
    }

    /// The speed-burst / marker trigger of a Video take: the ramp rate, black
    /// on amber while a burst is live, amber on graphite between.
    private var liveMomentTrigger: some View {
        Button {
            camera.triggerLiveMoment()
        } label: {
            Group {
                switch camera.activeSequenceMode ?? sequenceMode {
                case .ramp:
                    Text("\(camera.selectedRampFrameRate)")
                        .font(.system(size: 12, weight: .bold))
                case .marker:
                    Image(systemName: "flag.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .foregroundStyle(camera.isRampActive ? .black : LL.amber)
            .frame(width: 44, height: 44)
            .background(
                camera.isRampActive ? LL.amber : Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9),
                in: Circle()
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel((camera.activeSequenceMode ?? sequenceMode) == .ramp ? "Toggle speed burst" : "Toggle marker")
    }

    /// How many bursts / markers the take holds so far; amber once above zero.
    private var rampIntervalCountBadge: some View {
        let count = camera.rampIntervalCount
        return Text("\(count)")
            .font(.system(size: 14, weight: .bold).monospacedDigit())
            .foregroundStyle(count > 0 ? LL.amber : .white.opacity(0.4))
            .frame(width: 44, height: 44)
            .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Circle())
    }

    /// Slot 1's three states: off, rule-of-thirds, thirds-plus-horizon-level.
    /// Level needs CoreMotion, which doesn't exist on macOS at all (not a
    /// product choice — the framework isn't there to ask), so the Mac cycle
    /// simply skips straight back to `.off` instead of offering a dead state.
    private enum GridOverlayState {
        case off, grid, level

        static var levelAvailable: Bool {
            #if os(iOS)
            true
            #else
            false
            #endif
        }

        func next() -> GridOverlayState {
            switch self {
            case .off: return .grid
            case .grid: return Self.levelAvailable ? .level : .off
            case .level: return .off
            }
        }
    }

    /// Rule-of-thirds / horizon-level toggle — a left-side control matching
    /// the exposure lock's circular chrome. The button's own on/off tint
    /// stays binary amber (`.grid` and `.level` both read as "on"); the
    /// graduated level colour lives on the in-viewfinder bar
    /// (`LevelIndicatorOverlay`), not this 44 pt glyph.
    private var gridToggleCircle: some View {
        Button {
            gridOverlay = gridOverlay.next()
        } label: {
            Image(systemName: gridOverlay != .off ? "grid.circle.fill" : "grid.circle")
                .font(.system(size: 20))
                .foregroundStyle(gridOverlay != .off ? LL.amber : .white)
                .frame(width: 44, height: 44)
                .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(gridOverlay == .off ? "Show grid" : (gridOverlay == .grid ? "Show grid and level" : "Hide grid"))
    }

    /// Circular AE/AF lock, sized for the shutter-row slots and the
    /// landscape rail. The locked readout and fine ISO/focus sliders live in
    /// `exposurePanel` (portrait) once locked.
    private var exposureLockCircle: some View {
        // While the ramp owns exposure, this button locks FOCUS only —
        // locking exposure would stop the very thing the mode exists to do.
        // Over/under exposure lives on the ±EV slider instead.
        let ramping = holyGrailArmed
        let isLocked = ramping ? camera.isFocusLocked : camera.isExposureLocked
        return Button {
            if ramping {
                camera.toggleFocusLock()
            } else {
                toggleExposureLock()
            }
        } label: {
            // The padlock in every mode (design 2026-09-04): under the ramp it
            // means focus only — the accessibility label says so — but the
            // glyph no longer turns into a metering target.
            Image(systemName: isLocked ? "lock.fill" : "lock.open")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isLocked ? .black : .white)
                .frame(width: 44, height: 44)
                .background(
                    isLocked ? LL.amber : Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ramping
            ? (isLocked ? "Unlock focus" : "Lock focus")
            : (isLocked ? "Unlock exposure and focus" : "Lock exposure and focus"))
    }

    /// Photo mode's manual-exposure toggle — cluster slot 3, in place of the
    /// AE/AF padlock there in every other mode. No separate lock survives in
    /// Photo: tapping M on already seeds both wheels from whatever AE reads
    /// right now (`toggleManualExposure`), which is the padlock's entire
    /// value (freeze the current exposure) plus optional fine-tuning on top,
    /// so nothing the lock did is lost. Tap-to-focus is unaffected.
    private var manualExposureCircle: some View {
        Button {
            toggleManualExposure()
        } label: {
            Text("M")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(photoManualExposure ? .black : .white)
                .frame(width: 44, height: 44)
                .background(
                    photoManualExposure ? LL.amber : Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photoManualExposure ? "Turn off manual exposure" : "Turn on manual exposure")
    }

    /// 2 s self-timer toggle — its own control so the portrait shutter row and
    /// the landscape rail can both carry it (the rail was missing it).
    private var shutterDelayCircle: some View {
        Button {
            shutterDelayEnabled.toggle()
            if !shutterDelayEnabled {
                delayedStartAt = nil
            }
        } label: {
            Image(systemName: "timer")
                .font(.system(size: 18))
                .foregroundStyle(shutterDelayEnabled ? LL.amber : .white)
                .frame(width: 44, height: 44)
                .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(shutterDelayEnabled ? "Turn off 2 second delay" : "Turn on 2 second delay")
    }

    /// Auto shape mode's toggle — a circular icon button matching the 2 s
    /// delay button's shape and on/off treatment. Photo only. Turning it on
    /// (including off-and-on again) starts from nothing: every dismissed shape
    /// is forgotten and re-traced if it is still there.
    private var autoShapesToggleCircle: some View {
        Button {
            autoShapesEnabled.toggle()
        } label: {
            Image(systemName: autoShapesEnabled ? "square.fill.on.circle.fill" : "square.on.circle")
                .font(.system(size: 18))
                .foregroundStyle(autoShapesEnabled ? LL.amber : .white)
                .frame(width: 44, height: 44)
                .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(autoShapesEnabled ? "Turn off auto shapes" : "Turn on auto shapes")
    }

    /// The manual pose shutter, right of the stop button while a scan runs.
    ///
    /// It sits in the trailing accessory slot the timer and steadiness toggles
    /// vacate, at the same 44 pt as every other control on this row — one tap
    /// from the thumb already on the stop button, and unmistakably not the stop
    /// button, which is the confusion worth avoiding in the middle of a set.
    ///
    /// Amber rather than the row's usual white-on-graphite: this is the only
    /// control on screen that adds to the set, and a scan is exactly the shoot
    /// where the operator is looking at the page rather than at the phone.
    private var scannerManualCaptureButton: some View {
        Button {
            camera.captureScannerPoseNow()
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 44, height: 44)
                .background(LL.amber, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Capture this pose now")
    }

    // MARK: - Target capture

    private func startTargetCapture(_ plan: CaptureTargetPlan) {
        // A pose target belongs to a Scanner run and stays in Interval; only
        // the clip target moves the screen to Video.
        if plan.poseTarget != nil {
            activeTarget = plan
            targetReached = false
            framingStartedAt = Date()
            if !isIntervalCapturing {
                startIntervalCapture()
            }
            return
        }
        model.useRamp = false
        model.constantWindow = plan.speed
        activeTarget = plan
        targetReached = false
        mode = .video
        framingStartedAt = Date()
        if !camera.isRecording {
            camera.startRecording(mode: sequenceMode)
        }
    }

    /// The pose-count twin of `checkTarget`. `startScanner` already carries the
    /// cap and stops itself, so this is the *announcement* — the success
    /// haptic and the green ring — plus the honest no-auto-stop case, where
    /// the target is a marker rather than an ending.
    private func checkScannerTarget(frames: Int) {
        guard let target = activeTarget, let poses = target.poseTarget,
              !targetReached, frames >= poses else { return }
        targetReached = true
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        if target.autoStop, camera.isScannerActive {
            camera.stopScanner()
        }
    }

    private func checkTarget() {
        guard camera.isRecording,
              let target = activeTarget,
              !targetReached,
              elapsedSeconds >= target.recordSeconds else { return }
        targetReached = true
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        if target.autoStop {
            camera.stopRecording()
        }
    }

    // MARK: - Shared bits

    private func closeCapture() {
        camera.stop()
        dismiss()
    }

    private var authorizationMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.largeTitle)
            Text("Camera access is needed to capture. Enable it in Settings.")
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            #if os(macOS)
            Button {
                CameraPrivacySettings.open()
            } label: {
                Label("Open Camera Settings", systemImage: "gear")
            }
            Button {
                camera.start()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            #endif
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var elapsedRecordingTime: String {
        guard let startedAt = camera.recordingStartedAt else { return "00:00" }
        return DurationFormatter.recordingTime(from: max(0, now.timeIntervalSince(startedAt)))
    }

    /// The Info panel's one line about a refused ramp: why the last write
    /// was refused, in the camera's own words. The amber line above only
    /// says that it was.
    @ViewBuilder
    private var rampRefusedNote: some View {
        if let state = camera.holyGrailState, !state.isDriving {
            Text("ramp refused · \(state.notDrivingReason ?? "no exposure written") · frames are on the camera's AE")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(LL.amber)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: - Manual exposure

    /// Under the landscape cluster: whichever readout is true of this mode —
    /// the frozen pair under a lock, the ramp's live pair under Holy Grail.
    /// Fine brightness/focus tuning lives in portrait or on the Watch crown.
    @ViewBuilder
    private var landscapeClusterReadout: some View {
        // Photo manual exposure takes priority: unlike the other readouts
        // here it's a live control, not a frozen value, and it has no other
        // landscape home (`exposurePanel`, portrait's equivalent, is never
        // called from `landscapeLayout`).
        if mode == .photo, photoManualExposure {
            PhotoExposureWheels(
                shutterIndex: photoShutterIndex,
                isoIndex: photoISOIndex,
                shutterReachable: ManualExposureDetents.reachableShutterIndices(within: camera.manualExposureDurationRange),
                isoReachable: ManualExposureDetents.reachableISOIndices(within: camera.manualExposureISORange),
                aeShutterSeconds: photoManualAEReference.shutter,
                aeISO: photoManualAEReference.iso,
                onChangeShutter: updatePhotoManualShutter,
                onChangeISO: updatePhotoManualISO
            )
            .equatable()
        // Idle only: mid-run the amber run line in the viewfinder's corner
        // (`runReadoutCapsule`) carries the pair.
        } else if !isCapturing, holyGrailArmed, !holyGrailExposureReadout.isEmpty {
            Text(holyGrailExposureReadout)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(LL.amber)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
        } else if !isCapturing, camera.isExposureLocked {
            Text(exposureReadout)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(LL.amber)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private func toggleExposureLock() {
        if camera.isExposureLocked {
            camera.unlockExposureAndFocus()
        } else {
            camera.lockExposureAndFocus()
        }
    }

    /// M on: seed both wheels from whatever AE reads right now, snapped to
    /// their nearest detents, so the picture doesn't jump — the AE reference
    /// they're seeded from is also the readout's EV zero point for the rest
    /// of this manual session. M off: hand exposure back to continuous AE.
    private func toggleManualExposure() {
        if photoManualExposure {
            photoManualExposure = false
            camera.exitPhotoManualExposure()
            camera.setManualExposureDeviceNeeded(false)
        } else {
            let ae = camera.currentAutoExposure() ?? photoManualAEReference
            photoManualAEReference = ae
            photoShutterIndex = ManualExposureDetents.nearestShutterIndex(to: ae.shutter)
            photoISOIndex = ManualExposureDetents.nearestISOIndex(to: ae.iso)
            photoManualExposure = true
            // Ahead of the exposure write itself: on a JPEG shoot the
            // session is usually still on the virtual multi-cam device,
            // which refuses `.custom` outright — this swaps to the
            // physical constituent DNG already knows how to reach, without
            // DNG's other side effects (session preset, RAW requirement).
            // Both dispatch to the same serial sessionQueue, so the swap
            // is guaranteed to land before the write below runs.
            camera.setManualExposureDeviceNeeded(true)
            camera.setPhotoManualExposure(
                shutterSeconds: ManualExposureDetents.shutterSeconds[photoShutterIndex],
                iso: ManualExposureDetents.iso[photoISOIndex])
        }
    }

    private func updatePhotoManualShutter(_ index: Int) {
        photoShutterIndex = index
        camera.setPhotoManualExposure(
            shutterSeconds: index >= 0 ? ManualExposureDetents.shutterSeconds[index] : nil,
            iso: photoISOIndex >= 0 ? ManualExposureDetents.iso[photoISOIndex] : nil)
    }

    private func updatePhotoManualISO(_ index: Int) {
        photoISOIndex = index
        camera.setPhotoManualExposure(
            shutterSeconds: photoShutterIndex >= 0 ? ManualExposureDetents.shutterSeconds[photoShutterIndex] : nil,
            iso: index >= 0 ? ManualExposureDetents.iso[index] : nil)
    }

    private var exposureReadout: String {
        var text = "ISO \(Int(camera.lockedISO.rounded())) · \(shutterText(camera.lockedShutterSeconds))"
        // Only once the brightness slider has been moved off its centre — at
        // rest the readout is the locked exposure itself, and "+0.0 EV" would
        // be noise.
        if abs(exposureStops) >= 0.05 {
            text += String(format: " · %+.1f EV", exposureStops)
        }
        return text
    }

    private func shutterText(_ seconds: Double) -> String {
        ManualExposureDetents.shutterLabel(seconds)
    }

    /// What the ramp is doing right now — the pair it will take the next frame
    /// at. Deliberately not called a "lock": nothing here is frozen.
    ///
    /// **Empty before the ramp has a state to report**, which is the honest
    /// answer: there is no exposure yet. It used to fill the slot with
    /// "ramping · exposure follows the light", a sentence that never changed
    /// and told the operator only what the MODE chip beside it already said.
    /// The bias survives that emptiness — a ramp deliberately pushed ±EV is a
    /// setting the operator made and needs to see confirmed, even before there
    /// is a shutter and an ISO to attach it to.
    private var holyGrailExposureReadout: String {
        var parts: [String] = []
        if let state = camera.holyGrailState {
            parts.append("\(shutterText(state.shutterSeconds)) · ISO \(String(format: "%.0f", state.iso))")
        }
        if abs(camera.holyGrailBias) >= 0.05 {
            parts.append(String(format: "%+.1f EV", camera.holyGrailBias))
        }
        return parts.joined(separator: " · ")
    }

    /// Over/under exposure for the ramp. Unlike the locked-exposure slider
    /// this is not an offset from a frozen pair — it shifts the whole ramp,
    /// and the ramp walks there at its own rate limit, so it can be turned
    /// mid-shoot without stepping the sequence.
    private var holyGrailBiasBinding: Binding<Float> {
        Binding(
            get: { Float(camera.holyGrailBias) },
            set: { camera.holyGrailBias = Double($0) })
    }

    #if os(iOS)
    /// The locked-exposure readout and fine ISO/focus sliders, shown in any
    /// mode once AE/AF is locked. The lock toggle itself is the circular
    /// button beside the shutter (`exposureLockCircle`).
    @ViewBuilder
    private var exposurePanel: some View {
        if ladderArmed {
            // Idle, the band the ±EV slider occupies under Dynamic is simply
            // empty: a rung already states the exposure box (design 2a).
            // Mid-run the bias slider is the run readout's (2026-09-04, third
            // pass): the rung boxes the exposure, the bias nudges it. The
            // focus slider still applies once focus is held.
            if isCapturing || camera.isFocusLocked {
                VStack(spacing: 10) {
                    if isCapturing {
                        exposureSlider(
                            icon: "plusminus.circle",
                            value: holyGrailBiasBinding,
                            range: Self.exposureStopsRange)
                    }
                    if camera.isFocusLocked {
                        exposureSlider(icon: "camera.macro", value: focusBinding, range: 0...1)
                    }
                }
                .padding(.horizontal, 16)
            }
        } else if holyGrailArmed {
            // No locked exposure to report and none to offer: the ramp is
            // driving. What the operator gets instead is where the ramp sits
            // relative to the camera's own metering — over or under — plus
            // the focus slider once focus is held.
            VStack(spacing: 10) {
                // Mid-run the amber line above (`runExposureLine`) carries
                // the pair; idle, this readout does.
                if !isCapturing, !holyGrailExposureReadout.isEmpty {
                    HStack {
                        Text(holyGrailExposureReadout)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(LL.amber)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer()
                    }
                }
                exposureSlider(
                    icon: "plusminus.circle",
                    value: holyGrailBiasBinding,
                    range: Self.exposureStopsRange)
                if camera.isFocusLocked {
                    exposureSlider(icon: "camera.macro", value: focusBinding, range: 0...1)
                }
            }
            .padding(.horizontal, 16)
        } else if mode == .photo, photoManualExposure {
            PhotoExposureWheels(
                shutterIndex: photoShutterIndex,
                isoIndex: photoISOIndex,
                shutterReachable: ManualExposureDetents.reachableShutterIndices(within: camera.manualExposureDurationRange),
                isoReachable: ManualExposureDetents.reachableISOIndices(within: camera.manualExposureISORange),
                aeShutterSeconds: photoManualAEReference.shutter,
                aeISO: photoManualAEReference.iso,
                onChangeShutter: updatePhotoManualShutter,
                onChangeISO: updatePhotoManualISO
            )
            .equatable()
            .padding(.horizontal, 16)
        } else if camera.isExposureLocked {
            VStack(spacing: 10) {
                HStack {
                    Text(exposureReadout)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(LL.amber)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                }

                exposureSlider(
                    icon: "sun.max.fill",
                    value: exposureStopsBinding,
                    range: Self.exposureStopsRange)
                exposureSlider(icon: "camera.macro", value: focusBinding, range: 0...1)
            }
            .padding(.horizontal, 16)
        } else if runHasBiasSlider {
            // A Basic run: AE is free, so the bias slider is the run's one
            // exposure control (design 2026-09-04, third pass) — the same
            // device-side compensation the ramp's slider rides.
            VStack(spacing: 10) {
                exposureSlider(
                    icon: "plusminus.circle",
                    value: holyGrailBiasBinding,
                    range: Self.exposureStopsRange)
            }
            .padding(.horizontal, 16)
        }
    }

    private func exposureSlider(
        icon: String,
        value: Binding<Float>,
        range: ClosedRange<Float>
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 22)
            Slider(value: value, in: range)
                .tint(LL.amber)
        }
    }

    /// Brightness rides at the centre of its travel: the slider is an offset in
    /// stops around the exposure the lock froze at, not the absolute ISO. An
    /// absolute-ISO slider sat pinned at the far left in daylight — the lock
    /// lands on the sensor's minimum ISO there, so the whole control could only
    /// brighten. The camera spends the offset on ISO first and the shutter
    /// after (`setExposureOffset`), so both halves of the travel do something.
    private var exposureStopsBinding: Binding<Float> {
        Binding(
            get: { exposureStops },
            set: { stops in
                exposureStops = stops
                camera.setExposureOffset(stops: stops)
            })
    }

    private var focusBinding: Binding<Float> {
        Binding(get: { camera.lockedLensPosition }, set: { camera.setLensPosition($0) })
    }
    #endif

    // MARK: - Watch

    #if os(iOS)
    /// Returns whether the command actually ran — a guard-dropped command must
    /// reply "rejected", because the Watch applies optimistic state to
    /// "accepted" (a false accept leaves it showing a phantom recording).
    private func handleWatchCommand(_ command: WatchCaptureCommand, payload: [String: Any]) -> Bool {
        let value = payload[WatchMessageKey.value] as? Double
        switch command {
        case .startRecording:
            // Starts whatever mode the capture screen is in — the same
            // dispatch as the on-phone shutter, not a forced video recording.
            guard !isCapturing else { return false }
            shutterAction()
            return true
        case .scheduleStart:
            // Arm the shutter at an absolute time, on THIS device's clock —
            // a multi-camera rig armed one by one still starts the same
            // wall-clock second, and an overnight bench can arm a dawn
            // shoot and let the Mac sleep. value = epoch seconds; 0 cancels.
            guard !isCapturing, let value else { return false }
            scheduledStartTimer?.invalidate()
            scheduledStartTimer = nil
            if value <= 0 { return true }
            let fireAt = Date(timeIntervalSince1970: value)
            let delay = fireAt.timeIntervalSinceNow
            guard delay > 0, delay <= 24 * 3600 else { return false }
            let timer = Timer(fire: fireAt, interval: 0, repeats: false) { _ in
                // Re-checked at the hour: a manual start (or a mode change
                // into a run) before the alarm simply wins.
                if !isCapturing { shutterAction() }
                scheduledStartTimer = nil
            }
            // .common so a finger on a dial doesn't delay the shutter.
            RunLoop.main.add(timer, forMode: .common)
            scheduledStartTimer = timer
            LLog(String(format: "remote: start scheduled in %.1fs", delay))
            return true
        case .stopRecording:
            // Scanner is tested FIRST and must stay first. It reports through
            // `isIntervalRunning` like the plain timer shoot, but it owns no
            // interval timer — `stopInterval` reaches `finishIntervalOnQueue`,
            // whose `intervalActive` guard a Scanner run never sets, so the
            // stop would do nothing while this method returned `true`. A false
            // accept is the worst answer available here: the remote applies
            // optimistic state to an accept, so a tripod-mounted iPad would go
            // on shooting behind a remote showing a stopped camera.
            if camera.isScannerActive {
                camera.stopScanner(source: .watch)
            } else if camera.isRecording {
                camera.stopRecording(source: .watch)
            } else if camera.isIntervalRunning {
                camera.stopInterval(source: .watch)
            } else if camera.isLiveBlendRunning {
                camera.stopLiveBlend(source: .watch)
            } else {
                return false
            }
            return true
        case .triggerMoment:
            guard isCapturing else { return false }
            camera.triggerLiveMoment()
            return true
        case .timedBurst:
            // Watch "burst Ns": the phone owns the auto-revert timer so it
            // fires even if the Watch sleeps mid-burst.
            guard isCapturing, let value, value > 0 else { return false }
            camera.triggerTimedLiveMoment(duration: min(value, 30))
            return true
        case .lockExposure:
            camera.lockExposureAndFocus()
            return true
        case .unlockExposure:
            camera.unlockExposureAndFocus()
            return true
        case .setISO:
            guard let value else { return false }
            camera.setISO(Float(value))
            return true
        case .setLensPosition:
            guard let value else { return false }
            camera.setLensPosition(Float(value))
            return true
        case .setCaptureMode:
            // token-tolerant: a stale Watch build may still send the retired
            // "Live Blend" mode, which resolves to Interval.
            guard !isCapturing,
                  let token = payload[WatchMessageKey.captureMode] as? String,
                  let newMode = CaptureMode(token: token) else { return false }
            mode = newMode
            return true
        case .setIntervalSeconds:
            guard !isCapturing, let value, captureIntervalOptions.contains(value) else { return false }
            // Choosing a fixed spacing is also how the remote leaves Auto —
            // the same coupling the on-screen dial has, so the two surfaces
            // can't end up disagreeing about what EVERY means.
            guard !intervalMode.requiresAutoInterval else { return false }
            intervalAutoEnabled = false
            lastFixedInterval = value
            interval = value
            return true
        case .setIntervalMode:
            // Idle-only: both non-`off` modes reconfigure the session for RAW
            // at start, and Scanner adds a preview tap on top of that. Neither
            // can happen under a live run.
            guard !isCapturing,
                  let token = payload[WatchMessageKey.intervalMode] as? String,
                  let newMode = IntervalCaptureMode(rawValue: token),
                  newMode.isAvailableOnThisPlatform else { return false }
            // Interval is the only mode these belong to. Switching there as a
            // side effect is the honest thing to do — the alternative is
            // accepting a MODE the screen will not act on.
            mode = .interval
            intervalModeToken = newMode.rawValue
            reconcileIntervalAuto()
            updateAspectPreview()
            return true
        case .setLadder:
            // Ladder MODE's object, by id, by name, or "builtin". Arms Ladder
            // too: a ladder with the dial elsewhere would name nothing.
            guard !isCapturing, IntervalCaptureMode.ladder.isAvailableOnThisPlatform,
                  let token = payload[WatchMessageKey.ladder] as? String else { return false }
            let wanted = token.trimmingCharacters(in: .whitespaces)
            let match: LightLadder?
            if ["builtin", "built-in", "built in"].contains(wanted.lowercased()) {
                match = .builtIn
            } else if let id = UUID(uuidString: wanted) {
                match = ladders.ladder(id: id)
            } else {
                match = ladders.ladders.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
            }
            guard let match else { return false }
            mode = .interval
            intervalModeToken = IntervalCaptureMode.ladder.rawValue
            reconcileIntervalAuto()
            updateAspectPreview()
            selectedLadderID = match.isBuiltIn ? nil : match.id
            return true
        case .setAutoInterval:
            guard !isCapturing, let value else { return false }
            let wantsAuto = value != 0
            // The phone owns the validity rule, not the remote: Scanner cannot
            // leave Auto and Off cannot reach it. Both refusals are reported
            // rather than accepted and dropped.
            if wantsAuto {
                guard intervalMode.supportsAutoInterval else { return false }
                intervalAutoEnabled = true
            } else {
                guard !intervalMode.requiresAutoInterval else { return false }
                intervalAutoEnabled = false
                interval = lastFixedInterval
            }
            return true
        case .deleteLastFrame:
            guard camera.isScannerActive else { return false }
            camera.deleteLastScannerFrame()
            return true
        case .setFramesPerBlend:
            guard !isCapturing else { return false }
            // Token form first (the Mac remote's scripted tests use it, and
            // it is how Auto is reached at a distance): a `blendDepth` token
            // accepts auto, a fixed count, or Safe/Psycho.
            //
            // Psycho and Safe used to be refused here as "a deliberate
            // hands-on choice". That stopped being true the moment Psycho
            // turned out to be the mode that actually delivers motion blur
            // (2026-08-22 field testing: 25 fps of frames spanning 99% of the
            // interval, against ~4% on the fixed-depth DNG path). A mode that
            // has to be reached by hand cannot be in a scripted comparison or
            // a fleet shoot, which is precisely where it now needs to be.
            if let token = payload[WatchMessageKey.blendDepth] as? String {
                guard let depth = BlendDepth(token: token) else { return false }
                switch depth {
                case .auto:
                    blendDepth = .auto
                    return true
                case .fixed(let frames):
                    guard BlendDepth.fixedOptions.contains(where: { $0.frames == frames }),
                          StreamRatePlan.isAttainable(
                              frames: frames, intervalSeconds: interval, streamFPS: blendStreamFPS)
                    else { return false }
                    blendDepth = .fixed(frames)
                    lastFixedBlendFrames = frames
                    return true
                case .throttled, .unthrottled:
                    blendDepth = depth
                    return true
                }
            }
            // Numeric form: the Watch picker's fixed counts.
            guard let value,
                  BlendDepth.fixedOptions.contains(where: { $0.frames == Int(value) }),
                  StreamRatePlan.isAttainable(
                      frames: Int(value), intervalSeconds: interval, streamFPS: blendStreamFPS)
            else { return false }
            blendDepth = .fixed(Int(value))
            lastFixedBlendFrames = Int(value)
            return true
        case .setBlendStrategy:
            // Idle-only, like the depth: the strategy is read once at run
            // start. Persisted straight to the same defaults key the
            // Settings row writes, so the two surfaces cannot disagree.
            guard !isCapturing,
                  let token = payload[WatchMessageKey.blendStrategy] as? String,
                  let strategy = BlendStrategyID(rawValue: token) else { return false }
            UserDefaults.standard.set(strategy.rawValue, forKey: BlendStrategyID.defaultsKey)
            return true
        case .setDimDuringShoot:
            // Display-only, so unlike the capture setters this lands mid-run
            // too: the defaults write flows back through `@AppStorage`, which
            // re-evaluates the dimmer and republishes the Watch context —
            // flipping it live on a bench arm is the thermal A/B.
            guard let value else { return false }
            UserDefaults.standard.set(value >= 0.5, forKey: ShootScreenDimmer.defaultsKey)
            return true
        case .setBurstFPS:
            // Live mid-shoot, unlike the other setters: changing what the NEXT
            // burst does is the whole reason the remote has a controls tab.
            // Gated on the offered list rather than on `isCapturing` — a rate
            // outside the matrix would change optic or codec at the segment
            // switch, which is the one thing a ramp must never do. Also
            // refused while a burst is actually open, and that refusal is
            // reported honestly rather than accepted and dropped.
            guard mode == .video, let value,
                  camera.availableBurstFrameRates.contains(Int(value)),
                  camera.canSelectRampFrameRate else { return false }
            camera.selectRampFrameRate(Int(value))
            return true
        case .setBaseFPS:
            // Re-applies the capture format, so idle only.
            guard mode == .video, !isCapturing, let value,
                  camera.availableFrameRates.contains(Int(value)) else { return false }
            camera.selectFrameRate(Int(value))
            return true
        case .setSequenceMode:
            // The mode is baked into the sequence at start, so it can only be
            // chosen before one. The remote offers it on the armed screen.
            guard mode == .video, !isCapturing,
                  let token = payload[WatchMessageKey.sequenceMode] as? String,
                  let newMode = LiveCaptureSequence.Mode(rawValue: token) else { return false }
            sequenceMode = newMode
            return true
        case .scheduleStop:
            guard isCapturing, let value,
                  let token = payload[WatchMessageKey.stopAtUnit] as? String,
                  let unit = ScheduledStopUnit(rawValue: token) else { return false }
            camera.scheduleStop(unit: unit, amount: value)
            return true
        case .cancelScheduledStop:
            camera.cancelScheduledStop()
            return true
        case .state:
            // Never reached: the receiver answers `state` from its cache
            // before consulting this handler. Kept for exhaustiveness.
            return true
        case .simulateTooHot:
            // DEBUG bench hook: the thermal stop's plumbing, on demand.
            #if DEBUG
            guard isCapturing else { return false }
            camera.simulateTooHot()
            return true
            #else
            return false
            #endif
        case .armCamera, .cancelExport:
            // Also never reached, and for a sharper reason: these are the
            // commands for when the capture screen ISN'T up, so the receiver
            // routes them to the root view's flow handler before it ever
            // consults this one. Arriving here would mean the camera is
            // already open, which is the state `armCamera` exists to reach.
            return false
        case .toggleMark:
            // Available in ANY mode and at any moment: a mark opens no file
            // and touches no format, so none of the guards a burst needs apply
            // to it. This is the whole reason it belongs on the wrist — making
            // the same note on the phone means touching a framed camera.
            guard isCapturing else { return false }
            camera.toggleMarkInterval(seconds: value ?? 0)
            return true
        case .previewFrame:
            // Answered by the receiver straight from FramingPreviewService —
            // it is a read of the camera, not a command to it.
            return false
        }
    }

    private func updateWatchRecordingState() {
        watchRemote.setRecordingState(
            isCapturing ? .recording : .idle,
            // captureRunStartedAt is the "Stop at" anchor — publishing it
            // keeps the watch's dial floor and countdown on the same clock
            // as the phone's authoritative deadline.
            startedAt: camera.captureRunStartedAt ?? camera.recordingStartedAt
                ?? (isCapturing ? framingStartedAt : nil),
            sequenceMode: camera.activeSequenceMode ?? sequenceMode,
            markerCount: camera.markerCount,
            rampIntervalCount: camera.rampIntervalCount,
            segmentCount: camera.segmentCount,
            isRampActive: camera.isRampActive,
            isRampHighRate: camera.isRampHighRate,
            isMarkActive: camera.isMarkActive,
            markIntervalCount: camera.markIntervalCount
        )
    }

    private func updateWatchContext() {
        // Mirror the format pill: Video reads "4K · 30 fps", the still modes
        // read the still format ("12MP 4:3 · DNG" / "1920×1080 · JPEG").
        let formatLine: String
        if mode != .video {
            let dngActive = model.intervalOutputFormat == .dng && camera.liveBlendDNGSupport.isSupported
            formatLine = "\(formatSummary) · \(dngActive ? "DNG" : "JPEG")"
        } else {
            // The burst's resolution rides the same line when it differs, so
            // the wrist can see the shoot has two formats without a new screen.
            let burst = sequenceMode == .ramp && camera.burstChangesResolution
                ? " · ↑\(camera.selectedBurstResolution.label)" : ""
            formatLine = "\(camera.selectedResolution.label) · \(camera.selectedFrameRate) fps\(burst)"
        }
        watchRemote.setCaptureContext(
            formatLine: formatLine,
            captureFPS: camera.selectedFrameRate,
            baseFPS: camera.activeBaseFrameRate ?? camera.selectedFrameRate,
            // What ⚡ will do, as distinct from what the camera is doing now.
            // Only meaningful for Video's ramp; the still modes have no burst
            // rate, and 0 reads as "don't show one".
            rampFPS: mode == .video ? camera.selectedRampFrameRate : 0,
            // The rungs the remote's rate ladder may draw. Already filtered by
            // the capability matrix (it drops rates that would change optic or
            // codec between segments), so an empty list genuinely means this
            // camera has nowhere faster to go — the remote says exactly that
            // rather than offering a burst to the rate it's already at.
            availableBurstFPS: mode == .video ? camera.availableBurstFrameRates : [],
            availableBaseFPS: mode == .video ? camera.availableFrameRates : [],
            plannedSpeed: model.constantWindow,
            outputFPS: model.outputFPS
        )
    }

    private func updateWatchModeContext() {
        let count: Int
        if camera.isLiveBlendRunning {
            count = camera.liveBlendOutputCount
        } else if camera.isIntervalRunning {
            count = camera.photoCount
        } else {
            count = 0
        }
        watchRemote.setModeContext(
            mode: mode,
            // Under Auto the dial is not the truth — the run's own pacing is.
            // A remote quoting the dial there describes a setting nobody is
            // using (see `CameraController.activeIntervalSeconds`).
            intervalSeconds: camera.activeIntervalSeconds ?? interval,
            blendDepth: blendDepth,
            isBulbMode: mode == .photo && photoBulbMode,
            captureCount: count,
            intervalMode: intervalMode,
            intervalAuto: intervalIsAuto)
    }

    /// Mirrors whichever MODE readout is live to the remotes, so a Mac driving
    /// a mounted iPad sees the same numbers the iPad's own HUD is showing.
    ///
    /// Without this the remote can start a Holy Grail or Scanner run and then
    /// has nothing to say about it — and these are precisely the two modes
    /// where the numbers *are* the interface. A ramp's operator is deciding
    /// whether ISO has started carrying it; a scan's is deciding whether the
    /// last pose landed.
    private func updateWatchIntervalReadout() {
        let ramp = camera.holyGrailState.map {
            WatchRemoteControlReceiver.HolyGrailRemoteReadout(
                shutterSeconds: $0.shutterSeconds,
                iso: $0.iso,
                sceneEV: $0.sceneEV,
                isISORamping: $0.isISORamping,
                isClipped: $0.isClipped,
                isCapturingRAW: $0.isCapturingRAW)
        }
        let scan = camera.scannerState.map {
            WatchRemoteControlReceiver.ScannerRemoteReadout(
                phase: $0.phase,
                frames: $0.frames,
                shutterSeconds: $0.shutterSeconds,
                iso: $0.iso,
                isCapturingRAW: $0.isCapturingRAW,
                waitingForDeviceSteady: $0.waitingForDeviceSteady)
        }
        watchRemote.setIntervalRunReadout(holyGrail: ramp, scanner: scan)
    }

    private func updateWatchScheduledStop() {
        watchRemote.setScheduledStopContext(
            unit: camera.scheduledStop?.unit,
            deadline: camera.scheduledStop?.deadline,
            targetCount: camera.scheduledStop?.targetCount)
    }

    private func updateWatchExposure() {
        watchRemote.setExposureContext(
            isExposureLocked: camera.isExposureLocked,
            lockedISO: camera.lockedISO,
            lockedShutter: camera.lockedShutterSeconds,
            lockedLensPosition: camera.lockedLensPosition,
            isoMin: camera.isoRange.lowerBound,
            isoMax: camera.isoRange.upperBound
        )
    }

    private func updateIdleTimer() {
        // Held for the whole time the capture screen is up, not just while
        // capturing. A mounted iPad waiting for a remote to start a take is
        // idle by definition — letting it auto-lock backgrounds the app, and
        // iOS suspends network activity in the background, so the remote link
        // dies exactly in the state it exists to serve. This is also what
        // Apple's own Camera app does.
        UIApplication.shared.isIdleTimerDisabled = true
    }
    #endif
}

// MARK: - Small camera chrome

private struct CameraChromeButton: View {
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct CameraPill: View {
    var text: String
    var tint: Color = .white
    var bold = false
    var monospaced = false

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: bold ? .bold : .semibold, design: monospaced ? .monospaced : .default))
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.5), in: Capsule())
    }
}

/// One of auto shape mode's tracks on glass: an ellipse's centre and half-axis
/// vectors, or a quad's corners — in the viewfinder region's own coordinates.
/// Geometry arrives normalised to the upright preview frame and is put on
/// glass by a sensor-point map (see `liveShapeOverlayPoint`), the same
/// point-by-point chain the Scanner's quad takes; the preview map is a
/// similarity (scale, quarter turns, a slide), so mapping an ellipse's axis
/// end-points maps the ellipse exactly.
///
/// Built once per body for both the drawing layer and the tap: the layer is
/// `allowsHitTesting(false)` like every other viewfinder overlay, and the
/// region's own tap asks `hit(at:)` first, so a dismiss never doubles as a
/// focus tap.
private struct LiveShapePlacement: Identifiable {
    var id: UUID
    var centre: CGPoint
    var a: CGSize
    var b: CGSize
    var corners: [CGPoint]
    var area: CGFloat

    var isEllipse: Bool { corners.isEmpty }

    static func place(_ tracks: [LiveShapeFinder.Track], orientation: QuadOrientation,
                      frameSize: CGSize, map: (CGPoint) -> CGPoint) -> [LiveShapePlacement] {
        // Axes are fractions of the frame's WIDTH, so a y component is scaled
        // by the frame's aspect to stay a fraction of its height.
        let aspect = frameSize.width > 0 && frameSize.height > 0 ? frameSize.height / frameSize.width : 4.0 / 3.0
        func glass(_ p: CGPoint) -> CGPoint { map(orientation.sensorPoint(p)) }
        return tracks.map { track in
            let shape = track.shape
            if let corners = shape.corners, corners.count == 4 {
                let pts = corners.map(glass)
                let centre = CGPoint(x: pts.map(\.x).reduce(0, +) / 4, y: pts.map(\.y).reduce(0, +) / 4)
                var area = 0.0
                for i in 0..<4 { let p0 = pts[i], p1 = pts[(i + 1) % 4]; area += p0.x * p1.y - p1.x * p0.y }
                return LiveShapePlacement(id: track.id, centre: centre, a: .zero, b: .zero, corners: pts, area: abs(area) / 2)
            }
            let c = shape.centre
            let ax = shape.majorAxis / 2, bx = shape.minorAxis / 2
            let cosR = cos(shape.rotation), sinR = sin(shape.rotation)
            let aEnd = CGPoint(x: c.x + ax * cosR, y: c.y + ax * sinR / aspect)
            let bEnd = CGPoint(x: c.x - bx * sinR, y: c.y + bx * cosR / aspect)
            let gc = glass(c), ga = glass(aEnd), gb = glass(bEnd)
            let a = CGSize(width: ga.x - gc.x, height: ga.y - gc.y)
            let b = CGSize(width: gb.x - gc.x, height: gb.y - gc.y)
            return LiveShapePlacement(id: track.id, centre: gc, a: a, b: b, corners: [],
                                      area: .pi * hypot(a.width, a.height) * hypot(b.width, b.height))
        }
    }

    /// How far a tap may land from a traced line and still mean it. A finger
    /// is not a point; 22 pt either side is a 44 pt corridor along the line.
    static let outlineBand: CGFloat = 22

    /// The shape whose OUTLINE is nearest the tap, within `outlineBand`, or
    /// nil. The outline and not the interior, deliberately: a large rectangle
    /// — a window, a whole monitor — covers most of the picture, and a tap
    /// anywhere inside it would otherwise be a dismiss instead of the focus
    /// tap it was (2026-09-11: a facade's windows swallowed every focus tap,
    /// and the misses pinned the lens for the 5× that followed). Tapping the
    /// amber line is "tapping the shape"; tapping the picture is still tapping
    /// the picture.
    static func hit(at p: CGPoint, in placements: [LiveShapePlacement]) -> UUID? {
        var best: (UUID, CGFloat)?
        for shape in placements {
            let d = shape.distanceToOutline(p)
            if d <= outlineBand, d < (best?.1 ?? .greatestFiniteMagnitude) { best = (shape.id, d) }
        }
        return best?.0
    }

    /// Distance from the point to the traced line: along the radial line for
    /// an ellipse (exact on the axes, within a few points elsewhere), to the
    /// nearest edge for a quad.
    func distanceToOutline(_ p: CGPoint) -> CGFloat {
        if isEllipse {
            let d = CGPoint(x: p.x - centre.x, y: p.y - centre.y)
            let la = hypot(a.width, a.height), lb = hypot(b.width, b.height)
            guard la > 0, lb > 0 else { return .greatestFiniteMagnitude }
            let s = (d.x * a.width + d.y * a.height) / (la * la)
            let t = (d.x * b.width + d.y * b.height) / (lb * lb)
            let rho = hypot(s, t)
            guard rho > 0 else { return min(la, lb) }
            let q = CGPoint(x: centre.x + (s / rho) * a.width + (t / rho) * b.width,
                            y: centre.y + (s / rho) * a.height + (t / rho) * b.height)
            return hypot(p.x - q.x, p.y - q.y)
        }
        var nearest = CGFloat.greatestFiniteMagnitude
        for i in 0..<4 {
            let p0 = corners[i], p1 = corners[(i + 1) % 4]
            let vx = p1.x - p0.x, vy = p1.y - p0.y
            let len2 = vx * vx + vy * vy
            let u = len2 > 0 ? max(0, min(1, ((p.x - p0.x) * vx + (p.y - p0.y) * vy) / len2)) : 0
            nearest = min(nearest, hypot(p.x - (p0.x + u * vx), p.y - (p0.y + u * vy)))
        }
        return nearest
    }

    func path() -> Path {
        var path = Path()
        if isEllipse {
            let steps = 72
            for i in 0...steps {
                let t = Double(i) / Double(steps) * 2 * .pi
                let p = CGPoint(x: centre.x + a.width * cos(t) + b.width * sin(t),
                                y: centre.y + a.height * cos(t) + b.height * sin(t))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
        } else {
            path.move(to: corners[0])
            for c in corners.dropFirst() { path.addLine(to: c) }
            path.closeSubpath()
        }
        return path
    }
}

/// Auto shape mode's viewfinder layer: every confirmed track traced in amber
/// over a dark halo so it reads on any picture. One `Canvas` rather than a
/// view per shape: the tracks change a few times a second and diffing a
/// per-shape view tree is not worth its cost on a layer this simple. This
/// view, and not the capture screen, is what re-renders on a sample: it is
/// the one place the finder's tracks are read in a body.
private struct LiveShapesOverlay: View {
    let finder: LiveShapeFinder
    /// Sensor-space normalised point → this layer's coordinates.
    let map: (CGPoint) -> CGPoint

    var body: some View {
        let placements = LiveShapePlacement.place(
            finder.visible, orientation: finder.orientation, frameSize: finder.frameSize, map: map)
        Canvas { context, _ in
            for shape in placements {
                let path = shape.path()
                context.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 4)
                context.stroke(path, with: .color(LL.amber), lineWidth: 2)
            }
        }
        .animation(.easeOut(duration: 0.12), value: finder.tracks)
        .allowsHitTesting(false)
        .accessibilityLabel("\(placements.count) shapes found")
    }
}

private struct RuleOfThirdsGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    path.move(to: CGPoint(x: width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: width * fraction, y: height))
                    path.move(to: CGPoint(x: 0, y: height * fraction))
                    path.addLine(to: CGPoint(x: width, y: height * fraction))
                }
            }
            // Strong enough to read over bright scenes — the old 0.22
            // hairline vanished in daylight.
            .stroke(.white.opacity(0.9), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// Photo mode's Grid+Level: a horizon-level indicator drawn at the
/// viewfinder's centre, over the same fitted frame `RuleOfThirdsGrid` uses.
/// Reads `LevelSensor.shared.rollDegrees`, which is normalised against the
/// nearest square hold rather than portrait specifically — so this same bar
/// and the same colour logic are correct in both portrait and landscape
/// shooting with no orientation-specific code here at all. iOS/iPadOS only:
/// macOS has no CoreMotion, so `GridOverlayState.levelAvailable` keeps this
/// view from ever mounting there.
private struct LevelIndicatorOverlay: View {
    var body: some View {
        #if os(iOS)
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            GeometryReader { geometry in
                let roll = LevelSensor.shared.rollDegrees ?? 0
                let tint = Self.tint(forDegreesOffLevel: abs(roll))
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                ZStack {
                    Capsule().fill(tint).frame(width: 38, height: 2).position(x: center.x - 73, y: center.y)
                    Capsule().fill(tint).frame(width: 38, height: 2).position(x: center.x + 73, y: center.y)
                    // Rotates with the phone; reads level when it lines up
                    // with the two fixed reference ticks either side.
                    Capsule()
                        .fill(tint)
                        .frame(width: 88, height: 2)
                        .rotationEffect(.degrees(-roll))
                        .position(center)
                    Text(Self.rollLabel(roll))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tint)
                        .position(x: center.x, y: center.y + 20)
                }
                .animation(.linear(duration: 0.1), value: roll)
            }
        }
        .allowsHitTesting(false)
        #else
        EmptyView()
        #endif
    }

    #if os(iOS)
    /// Green within the handoff's own ±1° snap threshold, warming through
    /// amber and orange to red the further off level the phone is. A
    /// starting proposal (see `DesignSystem.swift`), not yet measured
    /// against a device — cheap to retune since they're four named colours.
    private static func tint(forDegreesOffLevel degrees: Double) -> Color {
        switch degrees {
        case ..<1: return LL.levelGood
        case ..<4: return LL.levelNear
        case ..<8: return LL.levelOff
        default: return LL.levelFar
        }
    }

    private static func rollLabel(_ degrees: Double) -> String {
        abs(degrees) < 0.05 ? "0°" : String(format: "%+.1f°", degrees)
    }
    #endif
}

/// Chip presses repaint instantly: the default plain style's animated
/// pressed fade left the amber selection under the measurement mask for
/// ~150 ms on every lens change (capture investigation §3.4) — the strip
/// must never read as "nothing selected".
private struct ZoomChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(nil, value: configuration.isPressed)
    }
}

// MARK: - Format sheet

/// "12MP 4:3" — a sensor frame the way photographers read one.
private func sensorSummaryLabel(_ sensor: CameraController.CaptureResolution) -> String {
    let megapixels = Int((Double(sensor.width) * Double(sensor.height) / 1_000_000).rounded())
    return "\(megapixels)MP \(sensorAspectLabel(sensor))"
}

private func sensorAspectLabel(_ sensor: CameraController.CaptureResolution) -> String {
    sensor.aspectRatioLabel
}

/// Advanced capture format, off the viewfinder entirely. Shows each mode
/// its own dials: Video gets frame rates, stabilization and speed bursts;
/// Interval gets the output format (JPEG or DNG) instead — stills have no
/// base frame rate.
private extension View {
    /// macOS centres `Form` section footers, which reads as a floating caption
    /// rather than help text belonging to the control above it. Every footer in
    /// the format sheet explains the row it sits under, so they hang left like
    /// the help text in System Settings. No-op on iOS, which already does this.
    func formFooterAligned() -> some View {
        #if os(macOS)
        return multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        #else
        return self
        #endif
    }
}

private struct FormatSheet: View {
    @ObservedObject var camera: CameraController
    @ObservedObject var model: AppModel
    @ObservedObject private var resolutionPrefs = ResolutionPreferences.shared
    @Binding var mode: CaptureMode
    @Binding var sequenceMode: LiveCaptureSequence.Mode
    /// Capture Flat, per scope — see `FlatCapture.Scope`. The sheet edits the
    /// scope its `mode` belongs to and leaves the other one alone.
    @AppStorage(FlatCapture.storageKey(for: FlatCapture.Scope.stills))
    private var stillsFlat = false
    @AppStorage(FlatCapture.storageKey(for: FlatCapture.Scope.video))
    private var videoFlat = false
    private var captureFlatBinding: Binding<Bool> {
        FlatCapture.scope(for: mode) == .video ? $videoFlat : $stillsFlat
    }
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @ObservedObject private var cameraDevices = CameraDevices.shared
    #endif

    /// Swapping camera or format mid-shoot would change the clip halfway
    /// through, and the controller refuses it — so the controls say so.
    private var isCapturing: Bool {
        camera.isRecording || camera.isIntervalRunning || camera.isLiveBlendRunning
    }

    #if os(macOS)
    private var cameraSelection: Binding<String> {
        Binding(
            get: { cameraDevices.selectedDevice?.uniqueID ?? "" },
            set: { id in
                guard let device = cameraDevices.devices.first(where: { $0.uniqueID == id })
                else { return }
                cameraDevices.select(device)
            }
        )
    }
    #endif

    /// Capture Flat is offered for JPEG stills (a save-time Core Image grade)
    /// and for all Video captures. Log-capable hardware (iPhone 15 Pro+) uses
    /// Apple Log at the sensor; every other device gets an equivalent flat grade
    /// baked into the movie at save time (`VideoFlatten`). It stays hidden only
    /// for DNG, which is already fully adjustable in post.
    private var showsCaptureFlat: Bool {
        if mode == .video { return true }
        return model.intervalOutputFormat == .jpeg
    }

    /// Explains what "Capture Flat" does for the active mode. Video wording
    /// depends on whether THIS selection will shoot Apple Log — per resolution
    /// and rate, the capability matrix's answer — or the movie gets the flat
    /// grade baked in on save instead. The old footer answered for the device
    /// ("can this phone do Log at all?") and so promised Log at selections
    /// that would never engage it.
    private var captureFlatFooter: String {
        guard mode == .video else {
            return "Applies a low-contrast, desaturated grade as the JPEG is saved, keeping more room to colour-grade later."
        }
        if camera.supportsAppleLog {
            return camera.appleLogAvailableForSelection
                ? "Records in Apple Log — a flat, low-contrast profile with maximum grading latitude. Best paired with a colour grade in post."
                : "Apple Log isn't available at this resolution and frame rate — the same flat grade is baked into the movie as it saves instead."
        }
        return "Bakes a low-contrast, desaturated grade into the movie as it saves, keeping more room to colour-grade later."
    }

    /// Video speaks its own vocabulary ("4K", the ProRes star); the still
    /// modes state the actual pixel frame their JPEGs will have. Display
    /// ratios (a Manage resolutions preference) rides along per vocabulary.
    private func resolutionPickerLabel(_ resolution: CameraController.CaptureResolution) -> String {
        var label: String
        if mode == .video {
            label = resolution.label
        } else {
            label = resolution.stillLabel
        }
        if resolutionPrefs.displaysRatios(in: ResolutionPreferences.domain(for: mode)) {
            label += " (\(resolution.aspectRatioLabel))"
        }
        if mode == .video, resolution.isProRes {
            label += " *"
        }
        return label
    }

    /// The device list trimmed to the user's Manage resolutions choices.
    /// The active selection always stays offered (hiding it elsewhere must
    /// not leave the picker pointing at a missing row), and the still modes
    /// drop ProRes entries — that's video-only vocabulary.
    private var pickerResolutions: [CameraController.CaptureResolution] {
        let domain = ResolutionPreferences.domain(for: mode)
        return camera.availableResolutions.filter { resolution in
            if resolution == camera.selectedResolution { return true }
            if mode != .video && resolution.isProRes { return false }
            return resolutionPrefs.isVisible(resolution, in: domain)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                #if os(macOS)
                // The Mac has a bag of unrelated cameras rather than one stack,
                // and every list below belongs to whichever one is chosen — so
                // it comes first. Mirrors the Camera menu; both write through
                // the same store.
                Section {
                    if cameraDevices.devices.isEmpty {
                        Text("No camera found.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Camera", selection: cameraSelection) {
                            ForEach(cameraDevices.devices, id: \.uniqueID) { device in
                                Text(CameraDevices.menuLabel(for: device, among: cameraDevices.devices))
                                    .tag(device.uniqueID)
                            }
                        }
                        .disabled(isCapturing)
                    }
                } header: {
                    Text("Camera")
                } footer: {
                    if isCapturing {
                        Text("The camera can't change while a capture is running.")
                            .formFooterAligned()
                    } else if let device = cameraDevices.selectedDevice {
                        Text("\(CameraDevices.connectionLabel(for: device)) — every resolution and frame rate below is probed from this camera.")
                            .formFooterAligned()
                    }
                }
                #endif

                // Choices with downstream consequences come first: the still
                // modes' output format decides whether resolution is even
                // selectable, and Video's stabilization filters the format list
                // below it. Photo mirrors Interval here — same output controls.
                if mode == .interval || mode == .photo {
                    Section {
                        Picker("Output", selection: $model.intervalOutputFormat) {
                            Text("JPEG").tag(IntervalOutputFormat.jpeg)
                            Text("DNG").tag(IntervalOutputFormat.dng)
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Output format")
                    } footer: {
                        if camera.liveBlendDNGSupport.isSupported {
                            let aspect = camera.liveBlendDNGSupport.sensorDimensions.map(sensorAspectLabel) ?? "4:3"
                            Text("DNG keeps the sensor's raw data — white balance and tone stay adjustable in post, for day-to-night and mixed-light work. Applies with or without blending, and captures the sensor's full \(aspect) frame — the viewfinder shows that framing. JPEG is smaller and ready to share.")
                        } else {
                            Text("DNG unavailable — \(camera.liveBlendDNGSupport.reason ?? "not supported on this camera source"). Shoots fall back to JPEG.")
                        }
                    }
                }

                Section {
                    // Only offered when the camera can actually do it. macOS
                    // never can (see `supportsVideoStabilization`), and neither
                    // can an external camera on any platform.
                    if mode == .video && camera.supportsVideoStabilization {
                        Toggle("Stabilization", isOn: Binding(
                            get: { camera.isVideoStabilizationEnabled },
                            set: { camera.setVideoStabilizationEnabled($0) }
                        ))
                    }

                    if (mode == .interval || mode == .photo) && model.intervalOutputFormat == .dng,
                       camera.liveBlendDNGSupport.isSupported,
                       let sensor = camera.liveBlendDNGSupport.sensorDimensions {
                        // DNG captures the sensor's full photo frame — the
                        // video-format list doesn't apply, so state the real
                        // resolution instead of offering a dead picker.
                        HStack {
                            Text("Resolution")
                            Spacer()
                            Text("\(sensor.width)×\(sensor.height) · \(sensorSummaryLabel(sensor))")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Resolution", selection: $camera.selectedResolution) {
                            ForEach(pickerResolutions) { resolution in
                                Text(resolutionPickerLabel(resolution)).tag(resolution)
                            }
                        }
                        .onChange(of: camera.selectedResolution) { resolution in
                            camera.selectResolution(resolution)
                        }
                    }

                    if mode == .video {
                        Picker(sequenceMode == .ramp ? "Base frame rate" : "Frame rate", selection: $camera.selectedFrameRate) {
                            ForEach(camera.availableFrameRates, id: \.self) { fps in
                                Text("\(fps) fps").tag(fps)
                            }
                        }
                        .onChange(of: camera.selectedFrameRate) { fps in
                            camera.selectFrameRate(fps)
                        }
                    }

                    NavigationLink {
                        ManageResolutionsView(initialDomain: ResolutionPreferences.domain(for: mode))
                    } label: {
                        Text("Manage resolutions")
                    }
                } header: {
                    Text("Format")
                } footer: {
                    if mode == .video && pickerResolutions.contains(where: { $0.isProRes }) {
                        Text("* ProRes — very large files")
                            .formFooterAligned()
                    }
                }

                if showsCaptureFlat {
                    Section {
                        Toggle(isOn: captureFlatBinding) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Capture Flat")
                                Text("Optimised for post-production editing")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text(captureFlatFooter)
                            .formFooterAligned()
                    }
                }

                if mode == .video {
                    Section {
                        Picker("Speed bursts", selection: $sequenceMode) {
                            Text("Switch frame rate").tag(LiveCaptureSequence.Mode.ramp)
                            Text("Mark intervals only").tag(LiveCaptureSequence.Mode.marker)
                        }

                        if sequenceMode == .ramp {
                            if hasBurstRates {
                                // One control for the whole burst format, not
                                // two. The hardware does not generally offer
                                // its top rate at its top resolution, so a
                                // separate resolution menu would let the user
                                // build a pair the camera can't shoot and find
                                // out when the burst fires. A list of pairs
                                // cannot express an illegal combination.
                                Picker("Burst", selection: burstSelection) {
                                    ForEach(burstOptions, id: \.self) { option in
                                        Text(burstOptionLabel(option)).tag(option)
                                    }
                                }
                            } else {
                                // Offering a burst rate here would be a lie:
                                // `rampRates` falls back to the last-chosen
                                // rate when the matrix has nothing faster, so
                                // this row read "30 fps" against a 30 fps base
                                // — a burst that switches to the speed it is
                                // already running at. Common on webcams, which
                                // often publish exactly one rate per size.
                                LabeledContent("Burst frame rate", value: "None available")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Speed bursts")
                    } footer: {
                        if sequenceMode == .ramp && !hasBurstRates {
                            Text("This camera offers no frame rate faster than \(camera.selectedFrameRate) fps at \(camera.selectedResolution.label), so there is nothing to switch to — bursts will mark intervals instead. Try a smaller resolution, or another camera.")
                                .formFooterAligned()
                        } else if sequenceMode == .ramp, camera.burstChangesResolution {
                            // Named as the punch-in headroom it is, because
                            // that is the only reason to spend the switch on
                            // it — the finished clip is still delivered at the
                            // base resolution either way.
                            Text("While recording, the burst button (and Apple Watch) switches to \(camera.selectedRampFrameRate) fps at \(camera.selectedBurstResolution.label) — the same framing, with more pixels to punch into. Those moments stay slow and sharp in the final clip. The lens never changes, and the clip is still delivered at \(camera.selectedResolution.label).")
                                .formFooterAligned()
                        } else {
                            Text(sequenceMode == .ramp
                                 ? "While recording, the burst button (and Apple Watch) switches to the burst frame rate — those moments stay slow and sharp in the final clip. The lens never changes."
                                 : "Marked intervals keep their real speed in the final clip; the frame rate never changes.")
                                .formFooterAligned()
                        }
                    }
                }
            }
            .navigationTitle("Capture format")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            // `.grouped` is what gives a Mac Form real section headers and a
            // wrapping footer column. Without it the headers render as stray
            // rows in the middle of the sheet and the footers run off the
            // right-hand edge — which is what "Bakes a low-contrast…" was
            // doing, and why "Base frame rate" appeared clipped to "ase frame
            // rate": the label column was being pushed out of the sheet.
            .formStyle(.grouped)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        // A Mac sheet is never user-resizable, so it has to open at a size
        // that fits its widest row — the same reasoning (and the same floor)
        // as Settings ▸ Incomplete Captures.
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    /// The burst formats on offer. Not every faster format qualifies: the
    /// capability matrix has already dropped the ones that would change optic,
    /// codec, field of view or aspect ratio between segments (see
    /// `CameraController.availableBurstOptions`).
    private var burstOptions: [BurstOption] {
        let offered = camera.availableBurstOptions
        return offered.isEmpty ? [camera.selectedBurstOption] : offered
    }

    /// The picker's own binding. Reads through to the camera's two published
    /// values so an option the controller refuses (or re-pins on a base change)
    /// snaps the row back rather than leaving it showing a lie; writes go
    /// through `selectBurstOption`, which validates the pair.
    private var burstSelection: Binding<BurstOption> {
        Binding(
            get: { camera.selectedBurstOption },
            set: { camera.selectBurstOption($0) })
    }

    /// "100 fps" at the base resolution; "120 fps · 4K" when the burst raises
    /// it. The resolution is named only when it is news — a row that repeated
    /// the base resolution on every entry would bury the one that doesn't.
    private func burstOptionLabel(_ option: BurstOption) -> String {
        let base = camera.selectedResolution
        guard option.pixelWidth != base.width || option.pixelHeight != base.height else {
            return "\(option.fps) fps"
        }
        let label = CameraController.CaptureResolution(
            width: option.pixelWidth, height: option.pixelHeight).label
        return "\(option.fps) fps · \(label)"
    }

    /// Whether a burst has anywhere to go. False on a camera whose fastest
    /// format at this resolution IS the base rate — then `burstOptions`'
    /// fallback is a placeholder, not an offer, and the section says so.
    private var hasBurstRates: Bool {
        !camera.availableBurstOptions.isEmpty
    }
}

// MARK: - Capture target

struct CaptureTargetPlan: Equatable {
    var clipSeconds: Double
    var speed: Int
    var recordSeconds: Double
    var autoStop: Bool
    /// Scanner's target is a **pose count**, not a duration — a scan finishes
    /// when the object has been photographed from enough angles, and how long
    /// that takes is entirely up to how fast the operator's hands move. Nil for
    /// the Video target, which is the duration the rest of this struct
    /// describes.
    var poseTarget: Int?
}

/// The target sheet, in one of its two shapes.
///
/// Video: "I want a 6 s clip at 100×" — pick the clip, we tell you how long to
/// record. Scanner: "I want 36 angles" — pick the count, and the shutter ring
/// fills as the poses land. They share the sheet because they are the same
/// promise from the user's side ("stop when you've got what I asked for"), and
/// the same auto-stop toggle honours it.
private struct CaptureTargetSheet: View {
    /// Which shape to draw. The capture screen's current mode decides.
    enum Kind { case clip, scannerPoses }

    var kind: Kind = .clip
    var captureFPS: Int
    var outputFPS: Int
    var onStart: (CaptureTargetPlan) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var clipSeconds: Double = 6
    @State private var speed = 100
    @State private var autoStop = true
    /// 36 is the canonical photogrammetry set — one frame every 10° around a
    /// turntable — so it is what the sheet opens on.
    @State private var poseTarget = 36

    private let speeds = [25, 50, 100, 200]
    /// Every 15°, every 10°, every 7.5°, every 5°. Named by their angle in the
    /// row's caption, because that is how the shoot is actually performed.
    private let poseTargets = [24, 36, 48, 72]

    var body: some View {
        if kind == .scannerPoses {
            scannerBody
        } else {
            clipBody
        }
    }

    private var scannerBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 18)

            Text("Scan for a target")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
            Text("Pick how many angles you want — the ring fills as they land.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 2)
                .padding(.bottom, 20)

            Text("Angles")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .padding(.bottom, 8)

            HStack(spacing: 8) {
                ForEach(poseTargets, id: \.self) { candidate in
                    let isSelected = poseTarget == candidate
                    Button {
                        poseTarget = candidate
                    } label: {
                        Text("\(candidate)")
                            .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                            .foregroundStyle(isSelected ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                isSelected ? LL.amber : Color.white.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 18)

            HStack(spacing: 14) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.system(size: 20))
                    .foregroundStyle(LL.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(poseTarget) angles · \(poseAngleText)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Move the object, take your hand out, wait for the click. Repeat.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LL.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(LL.amber.opacity(0.35), lineWidth: 1)
            )
            .padding(.bottom, 14)

            Toggle(isOn: $autoStop) {
                Text("Stop automatically at target")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
            }
            .tint(LL.amber)
            .padding(.bottom, 16)

            Button {
                dismiss()
                onStart(CaptureTargetPlan(
                    clipSeconds: 0,
                    speed: 1,
                    recordSeconds: 0,
                    autoStop: autoStop,
                    poseTarget: poseTarget
                ))
            } label: {
                Text("Start scan")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(LL.amber, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 20)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .preferredColorScheme(.dark)
        #if os(iOS)
        .presentationDetents([.height(400)])
        #endif
    }

    /// A full turn divided by the count — the instruction the operator's hands
    /// actually follow.
    private var poseAngleText: String {
        let degrees = 360.0 / Double(max(poseTarget, 1))
        return degrees == degrees.rounded()
            ? "one every \(Int(degrees))°"
            : String(format: "one every %.1f°", degrees)
    }

    private var clipBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 18)

            Text("Capture for a target")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
            Text("Pick the clip you want — we'll tell you how long to record.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 2)
                .padding(.bottom, 20)

            HStack {
                Text("Clip length")
                    .foregroundStyle(.white)
                Spacer()
                Text(SpeedMath.clipLength(clipSeconds))
                    .fontWeight(.bold)
                    .foregroundStyle(LL.amber)
            }
            .font(.system(size: 14))
            .padding(.bottom, 6)

            Slider(value: $clipSeconds, in: 1...30, step: 0.5)
                .tint(LL.amber)
                .padding(.bottom, 18)

            Text("Speed")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .padding(.bottom, 8)

            HStack(spacing: 8) {
                ForEach(speeds, id: \.self) { candidate in
                    let isSelected = speed == candidate
                    Button {
                        speed = candidate
                    } label: {
                        Text("\(candidate)×")
                            .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                            .foregroundStyle(isSelected ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                isSelected ? LL.amber : Color.white.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 18)

            HStack(spacing: 14) {
                Image(systemName: "timer")
                    .font(.system(size: 20))
                    .foregroundStyle(LL.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record for \(DurationFormatter.recordingTime(from: recordSeconds))")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text("\(SpeedMath.clipLength(clipSeconds)) · \(outputFPS) fps output · at \(captureFPS) fps capture · ring shows the countdown")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LL.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(LL.amber.opacity(0.35), lineWidth: 1)
            )
            .padding(.bottom, 14)

            Toggle(isOn: $autoStop) {
                Text("Stop automatically at target")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
            }
            .tint(LL.amber)
            .padding(.bottom, 16)

            Button {
                dismiss()
                onStart(CaptureTargetPlan(
                    clipSeconds: clipSeconds,
                    speed: speed,
                    recordSeconds: recordSeconds,
                    autoStop: autoStop,
                    poseTarget: nil
                ))
            } label: {
                Text("Start capture")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(LL.amber, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 20)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .preferredColorScheme(.dark)
        #if os(iOS)
        .presentationDetents([.height(470)])
        #endif
    }

    private var recordSeconds: Double {
        SpeedMath.recordSeconds(
            clipSeconds: clipSeconds,
            speed: speed,
            captureFPS: Double(max(1, captureFPS)),
            outputFPS: outputFPS
        )
    }
}

// MARK: - Focus reticle

/// One accepted tap's worth of reticle: where it landed in viewfinder
/// coordinates, plus an identity that changes per tap — so tapping the same
/// spot twice still replays the animation.
private struct FocusReticle: Identifiable, Equatable {
    let id = UUID()
    let point: CGPoint
}

/// The tap-to-focus target. Lands large, settles onto the subject, and then
/// stays — dimmed — for as long as the lens is pinned to it, so the viewfinder
/// always says where focus is being held. It goes bright again on the next tap
/// and disappears only when the pin is given up.
private struct FocusReticleView: View {
    @State private var scale: CGFloat = 1.32
    @State private var opacity: Double = 0

    private static let size: CGFloat = 74

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .stroke(LL.amber, lineWidth: 1.2)
                .frame(width: Self.size, height: Self.size)
            // A centre tick per edge: the native language for "focus target",
            // and it reads against a busy frame where a bare square doesn't.
            ForEach(0..<4, id: \.self) { edge in
                Capsule()
                    .fill(LL.amber)
                    .frame(width: 1.2, height: 7)
                    .offset(y: -Self.size / 2 + 3.5)
                    .rotationEffect(.degrees(Double(edge) * 90))
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 2, y: 0.5)
        .scaleEffect(scale)
        .opacity(opacity)
        .onAppear {
            scale = 1.32
            opacity = 0
            withAnimation(.spring(response: 0.28, dampingFraction: 0.62)) {
                scale = 1
                opacity = 1
            }
            // Then it recedes to a marker rather than leaving: the shot is
            // being composed through this frame, and a full-strength square
            // parked on the subject is in the way of that.
            withAnimation(.easeOut(duration: 0.35).delay(0.5)) {
                opacity = 0.5
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Scanner rectangle overlay

/// The detected page, traced over the live image.
///
/// Thin, accent-coloured and half-transparent by design: this is the one piece
/// of chrome that sits *on* the subject rather than beside it, and a Scanner
/// operator is judging framing and lighting through it. It says "I can see the
/// page and I am watching these four points" and then gets out of the way.
///
/// Corner markers as well as edges, because the corners are what the shoot
/// actually uses — the settle test measures their travel and the correction
/// rectifies from them — so a corner sitting a centimetre off the page is worth
/// seeing before the set is shot rather than after.
private struct ScannerRectangleOverlay: View {
    let corners: ScannerQuadCorners

    var body: some View {
        ScannerQuadShape(corners: corners)
            .stroke(
                LL.accent.opacity(0.6),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            // Over live picture the accent alone can vanish into a dark page;
            // the same trick the reticle uses keeps it readable without
            // brightening it.
            .shadow(color: .black.opacity(0.35), radius: 2)
            .accessibilityHidden(true)
    }
}

/// The detected page's four corners, already in the viewfinder region's own
/// coordinate space.
///
/// Points rather than a `NormalizedQuad` on purpose: mapping normalised corners
/// onto the live image needs the preview layer (its gravity, its letterbox, the
/// quarter turn between the capture's orientation and the interface's), and a
/// `Shape` handed only a `rect` cannot see any of that. Doing the conversion
/// where those things are known — `CaptureView.scannerOverlayCorners` — leaves
/// this side with nothing to get wrong.
struct ScannerQuadCorners: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint
}

/// The quad's outline plus a rounded marker at each corner, in one animatable
/// path — one shape rather than five views so the whole figure interpolates
/// together as the detection moves.
private struct ScannerQuadShape: Shape {
    var corners: ScannerQuadCorners

    private static let markerSize: CGFloat = 11
    private static let markerRadius: CGFloat = 3

    /// The eight numbers that describe the figure, so SwiftUI can walk a quad
    /// from where it was to where it is. Without this the shape would snap:
    /// `Path` is not animatable on its own, and the four corners move
    /// independently.
    var animatableData: AnimatablePair<
        AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>,
        AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>
    > {
        get {
            AnimatablePair(
                AnimatablePair(
                    AnimatablePair(corners.topLeft.x, corners.topLeft.y),
                    AnimatablePair(corners.topRight.x, corners.topRight.y)),
                AnimatablePair(
                    AnimatablePair(corners.bottomLeft.x, corners.bottomLeft.y),
                    AnimatablePair(corners.bottomRight.x, corners.bottomRight.y)))
        }
        set {
            corners.topLeft = CGPoint(x: newValue.first.first.first, y: newValue.first.first.second)
            corners.topRight = CGPoint(x: newValue.first.second.first, y: newValue.first.second.second)
            corners.bottomLeft = CGPoint(x: newValue.second.first.first, y: newValue.second.first.second)
            corners.bottomRight = CGPoint(x: newValue.second.second.first, y: newValue.second.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        // `rect` is deliberately unused: the corners are already points in this
        // view's space, converted where the letterbox and the orientation were
        // known.
        _ = rect
        let corners = [
            self.corners.topLeft, self.corners.topRight,
            self.corners.bottomRight, self.corners.bottomLeft,
        ]

        var path = Path()
        path.addLines(corners)
        path.closeSubpath()
        for corner in corners {
            path.addRoundedRect(
                in: CGRect(
                    x: corner.x - Self.markerSize / 2,
                    y: corner.y - Self.markerSize / 2,
                    width: Self.markerSize,
                    height: Self.markerSize),
                cornerSize: CGSize(width: Self.markerRadius, height: Self.markerRadius))
        }
        return path
    }
}

// MARK: - Preview layer

#if os(iOS)
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let camera: CameraController
    let orientation: AVCaptureVideoOrientation
    let videoGravity: AVLayerVideoGravity

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        /// Re-applies the connection orientation outside SwiftUI's update cycle.
        /// Needed because the preview connection does not exist at `makeUIView`
        /// time — the session is configured asynchronously on its queue — and
        /// a freshly formed connection defaults to portrait. Without this, a
        /// first open in landscape shows a sideways feed until a rotation
        /// happens to trigger `updateUIView`.
        var reapplyOrientation: (() -> Void)?
        private var sessionStartObserver: NSObjectProtocol?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                reapplyOrientation?()
            }
        }

        func observeSessionStart(of session: AVCaptureSession) {
            sessionStartObserver = NotificationCenter.default.addObserver(
                forName: .AVCaptureSessionDidStartRunning,
                object: session,
                queue: .main
            ) { [weak self] _ in
                self?.reapplyOrientation?()
            }
        }

        deinit {
            if let sessionStartObserver {
                NotificationCenter.default.removeObserver(sessionStartObserver)
            }
        }
    }

    // Temporary: count preview-view creations. Should stay at 1 for a whole
    // capture session — any increment on rotation means the preview is being
    // torn down and re-attached to the running session.
    private static var makeCount = 0

    func makeUIView(context: Context) -> PreviewView {
        Self.makeCount += 1
        LLog("CameraPreview.makeUIView #\(Self.makeCount) (preview view CREATED)")
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = videoGravity
        // Tap-to-focus converts through this layer — it is the only thing that
        // knows the letterbox, the mirroring and the rotation sitting between a
        // touch on glass and a point on the sensor.
        camera.previewLayer = view.previewLayer
        view.reapplyOrientation = { [weak view] in
            guard let view else { return }
            applyOrientation(to: view, from: "reapply")
        }
        view.observeSessionStart(of: session)
        applyOrientation(to: view, from: "makeUIView")
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.videoGravity != videoGravity {
            uiView.previewLayer.videoGravity = videoGravity
        }
        if camera.previewLayer !== uiView.previewLayer {
            camera.previewLayer = uiView.previewLayer
        }
        uiView.reapplyOrientation = { [weak uiView] in
            guard let uiView else { return }
            applyOrientation(to: uiView, from: "reapply")
        }
        applyOrientation(to: uiView, from: "updateUIView")
    }

    /// Rotate only the preview connection to match the current interface
    /// orientation. Because the whole UI rotates with the device, `updateUIView`
    /// runs in step with every rotation, so the preview turns with the layout —
    /// no `UIDevice` motion notifications, no lag. The view's window scene is
    /// authoritative once it's on screen; before then (`makeUIView`) we fall
    /// back to the orientation the view was created with, which is already
    /// correct on a direct landscape launch. `PreviewView.reapplyOrientation`
    /// re-runs this on window attach and on session start, because the
    /// connection this rotates does not exist until the session's async
    /// configuration finishes — without that, a first open in landscape kept
    /// the connection at its portrait default until the device was rotated.
    ///
    /// This deliberately does NOT touch the session's capture outputs or
    /// stabilization — reconfiguring those on the live session mid-rotation was
    /// stalling the capture source. Recording/photo orientation is set at
    /// capture start instead (see `startNextSegment` / `startInterval`).
    private func applyOrientation(to view: PreviewView, from caller: String) {
        let interface = view.window?.windowScene?.interfaceOrientation
        let target = interface.map(effectiveCaptureOrientation(interface:)) ?? orientation
        let connection = view.previewLayer.connection
        LLog("applyOrientation(\(caller)) inWindow=\(view.window != nil) interface=\(interface?.rawValue ?? -1) device=\(UIDevice.current.orientation.rawValue) target=\(target.rawValue) conn=\(connection != nil) supported=\(connection?.isVideoOrientationSupported == true) current=\(connection?.videoOrientation.rawValue ?? -1)")
        if let connection,
           connection.isVideoOrientationSupported,
           connection.videoOrientation != target {
            connection.videoOrientation = target
        }
    }
}
#else
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let camera: CameraController
    let orientation: AVCaptureVideoOrientation
    let videoGravity: AVLayerVideoGravity

    final class PreviewView: NSView {
        override func makeBackingLayer() -> CALayer {
            AVCaptureVideoPreviewLayer()
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.wantsLayer = true
        view.previewLayer.session = session
        view.previewLayer.videoGravity = videoGravity
        if view.previewLayer.connection?.isVideoOrientationSupported == true {
            view.previewLayer.connection?.videoOrientation = orientation
        }
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.previewLayer.frame = nsView.bounds
        nsView.previewLayer.videoGravity = videoGravity
        if nsView.previewLayer.connection?.isVideoOrientationSupported == true {
            nsView.previewLayer.connection?.videoOrientation = orientation
        }
    }
}
#endif

private extension View {
    /// Landscape chrome-rail items that hang off the rail's outer edge — 16 pt
    /// in from it — and may overhang the viewfinder on the other side. Never
    /// squeezed (`fixedSize`), never clipped at the screen edge: the rail's
    /// stack aligns them by that edge, so a pill wider than the 108 pt column
    /// simply runs past it inward. (A flexible frame with a leading alignment
    /// does NOT do this — it centres a child wider than itself.)
    func railAnchored(_ anchor: HorizontalAlignment) -> some View {
        fixedSize()
            .padding(anchor == .trailing ? .trailing : .leading, 16)
    }
}
