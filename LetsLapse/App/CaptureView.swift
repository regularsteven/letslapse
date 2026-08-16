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
    @AppStorage(FlatCapture.storageKey) private var captureFlat = false
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @ObservedObject private var watchRemote = WatchRemoteControlReceiver.shared
    #endif
    @StateObject private var camera = CameraController()
    /// Device-motion primitive for Photo mode's capture-when-steady gate (and
    /// the live "waiting for steady" indicator).
    @StateObject private var steadiness = SteadinessMonitor()
    /// Monitor test-rig watcher/executor (see TestCardRig.swift): watches the
    /// idle Video preview for the test card, then runs its script hands-free.
    @StateObject private var testRig = TestCardRigController()

    @State private var mode: CaptureMode
    @State private var sequenceMode: LiveCaptureSequence.Mode
    @State private var interval: Double = 2
    /// Interval mode's blend dial: fixed source-frame counts plus the
    /// adaptive depths (Psycho/Safe). Default 10: the capture benchmark
    /// showed bracketed RAW delivers 10 frames in ~0.65s, and dense sampling
    /// is what reads as motion blur — 3-5 spread samples read as ghosts.
    @State private var blendDepth: BlendDepth = .fixed(10)
    /// Where Safe falls back when its profile basis disappears (interval or
    /// format change, learning reset) — the last deliberate fixed choice.
    @State private var lastFixedBlendFrames = 10
    /// Interval's RAMP dial: with Holy Grail armed, shutter and ISO are ramped
    /// automatically through a lighting transition so one shoot can run from
    /// daylight into night. Persisted on its own key rather than through
    /// `RecordingSettingsStore` — it is a shooting *intent* the user sets for
    /// a specific evening, not part of the remembered format snapshot.
    @AppStorage("letslapse.capture.holyGrail") private var holyGrailEnabled = false
    /// True while Interval's RAMP dial is on Holy Grail on a platform that
    /// can ramp — the state in which exposure belongs to the ramp and the
    /// lock button, the readout and the ±EV control all change meaning.
    private var holyGrailArmed: Bool {
        mode == .interval && holyGrailEnabled && Self.holyGrailAvailable
    }

    /// The ramp needs manual exposure, a numeric ISO/shutter envelope and RAW
    /// — iOS/iPadOS only. On the Mac the dial isn't offered and a remembered
    /// "on" is ignored rather than silently shooting something else.
    static let holyGrailAvailable: Bool = {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }()
    @State private var showPsychoNotice = false
    private static let psychoNoticeShownKey = "letslapse.capture.psychoNoticeShown"
    private let captureIntervalOptions: [Double] = [0.5, 1.0, 2.0, 3.0, 5.0, 10.0]
    @State private var orientation = currentCaptureOrientation()
    @State private var now = Date()
    @State private var framingStartedAt = Date()
    @State private var showFormatSheet = false
    @State private var showTargetSheet = false
    @State private var showGrid = false
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
    /// Photo mode: whether the shutter waits for the device to settle before
    /// firing, and whether it is currently waiting (drives the viewfinder
    /// steady indicator).
    @State private var photoCaptureWhenSteady = false
    @State private var isWaitingForSteady = false
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
                .offset(y: previewTopAnchorOffset(in: geometry.size))

                Group {
                    if geometry.size.width > geometry.size.height {
                        landscapeLayout(in: geometry.size)
                    } else {
                        portraitLayout(in: geometry.size)
                    }
                }
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
        stage
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
                captureFPS: camera.selectedFrameRate,
                outputFPS: model.outputFPS
            ) { plan in
                startTargetCapture(plan)
            }
        }
        .onAppear(perform: configureOnAppear)
        .onDisappear(perform: cleanUpOnDisappear)
        // Keep the recent-capture tile current: a new project (any mode) takes
        // the slot, and a Photo shot's blend replaces its own hero moments after
        // the capture itself lands.
        .onChange(of: model.captures.first?.id) { _ in refreshRecentCapture() }
        .onChange(of: model.blends.count) { _ in refreshRecentCapture() }
        .onReceive(tick) { date in
            now = date
            checkTarget()
            if let deadline = delayedStartAt, date >= deadline {
                delayedStartAt = nil
                shutterAction()
            }
        }
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
        // Arming the Holy Grail ramp puts the session in the photo
        // configuration too (RAW lives nowhere else), so the viewfinder shows
        // the 4:3 sensor frame the run will actually capture.
        .onChange(of: holyGrailEnabled) { _ in
            updateAspectPreview()
        }
        .onChange(of: interval) { seconds in
            RecordingSettingsStore.save(intervalSeconds: seconds, for: mode)
            revalidateSafeDepth()
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

    /// Orientation and the Watch-link mirrors — iOS only, bar the one shared recording hook.
    var body: some View {
        settingsObservers
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
        // Count the mode the screen opened in as last-used: effect cards set
        // it explicitly, and the plain entry resolved to the remembered mode
        // anyway, so re-saving is a no-op there.
        RecordingSettingsStore.save(captureMode: mode)
        refreshRecentCapture()
        testRig.camera = camera
        if ProcessInfo.processInfo.environment["LL_TESTRIG"] == "chip" {
            testRig.seedDemoChip()
        }
        updateTestCardWatch()
        #if DEBUG
        applyModePreviewHook()
        applyHolyGrailPreviewHook()
        applyBurstPreviewHook()
        applyFocusPreviewHook()
        applyRecordingPreviewHook()
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
                Task {
                    await model.processPhotoBurst(
                        urls: framesToBlend, blendDepth: depth, linear: model.linearLight,
                        presentResult: false)
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
            model.setSource(
                .photos(urls),
                mode: holyGrailEnabled && Self.holyGrailAvailable
                    ? "Interval · Holy Grail" : "Interval · JPEG")
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
                Task {
                    await model.processPhotoBurst(
                        urls: dngURLs, blendDepth: 1, linear: model.linearLight,
                        presentResult: false)
                }
                return
            }
            camera.stop()
            dismiss()
            // The experiment log rides along as a JSON sidecar (the project
            // model filters .json from media), so shared/imported projects
            // carry their own capture diagnostics.
            let format = result.outputFormat == "dng" ? "DNG" : "JPEG"
            let blend: String
            switch blendDepth {
            case .fixed(let frames):
                blend = frames > 1 ? " · \(frames)-frame blend" : ""
            case .unthrottled:
                blend = " · Psycho blend"
            case .throttled:
                blend = " · Safe blend"
            }
            model.setSource(
                .photos(result.frameURLs + [result.logURL]),
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
        // Before start(): the session log opens there and names the mode.
        syncLoggedCaptureMode()
        camera.start()
        updateAspectPreview()
        syncAppleLog()
        framingStartedAt = Date()
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
        (mode == .interval || mode == .photo)
            && model.intervalOutputFormat == .dng
            && camera.liveBlendDNGSupport.isSupported
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
        // Idempotent — the finish handlers already stop it, but a mid-session
        // close (or a Photo-mode exit) shouldn't leave motion updates running.
        steadiness.stop()
        camera.stopTestCardTap()
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
            }

            Spacer()

            formatPill
        }
    }

    private var portraitControls: some View {
        VStack(spacing: 13) {
            remoteLinkChip
            if testRig.phase != .idle {
                testCardChip
            }
            if mode == .video {
                if camera.isRecording {
                    speedMarquee
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

            // Shutter row, Apple-camera order: recent capture · accessories ·
            // shutter · accessories. A 60 pt tile plus two 44 pt circles a side
            // doesn't fit either side of a centered shutter on a 393 pt screen,
            // so the accessory pairs stack into single columns here (they are
            // already single buttons in the landscape rail). The trailing clear
            // block mirrors the tile so the shutter stays centered.
            HStack(spacing: 0) {
                recentCaptureButton
                    .frame(width: Self.recentTileSize)
                Spacer(minLength: 10)
                leadingControl
                    .frame(width: 44)
                Spacer()
                shutterButton
                Spacer()
                trailingControl
                    .frame(width: 44)
                Spacer(minLength: 10)
                Color.clear
                    .frame(width: Self.recentTileSize, height: 1)
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Landscape (side rails: thumbs on edges, image untouched)

    private func landscapeLayout(in size: CGSize) -> some View {
        HStack(spacing: 0) {
            // Left rail: status + format
            VStack {
                if camera.isRecording {
                    recordingPill
                } else {
                    CameraChromeButton(systemImage: "xmark") {
                        closeCapture()
                    }
                }
                Spacer()
                formatPill
                Spacer()
                if !isCapturing {
                    zoomChips
                }
                // The rail is 108pt wide, far too narrow for the chip's
                // horizontal form, so landscape gets it stacked instead of
                // squeezed. Same content, same tokens.
                remoteLinkChip
                    .fixedSize()
                    .scaleEffect(0.85)
                    .padding(.top, 10)
                // Lower-left corner, same as portrait.
                recentCaptureButton
                    .padding(.top, 14)
            }
            .padding(.vertical, 16)
            .frame(width: 108)

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

            // Right rail: mode + shutter, exposure lock below (the burst/
            // marker trigger takes that slot while recording).
            VStack {
                landscapeModeToggle

                Spacer()
                shutterButton
                Spacer()

                if camera.isRecording {
                    leadingControl
                } else {
                    landscapeExposureControl
                }
            }
            .padding(.vertical, 16)
            .frame(width: 118)
        }
        .overlay {
            if camera.isAuthorized == false {
                authorizationMessage
            }
        }
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
            speedMarquee
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
                if showGrid {
                    RuleOfThirdsGrid()
                        .frame(width: fitted.width, height: fitted.height)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: isPortrait ? .top : .center
                        )
                }
                if mode == .photo && isWaitingForSteady {
                    SteadyGateOverlay(isStill: steadiness.isStill, magnitude: steadiness.magnitude)
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
            }
            .animation(.easeInOut(duration: 0.16), value: camera.isSwitchingLens)
            .frame(width: geometry.size.width, height: geometry.size.height)
            #if os(iOS)
            // The whole region takes the tap, not just whatever is drawn in it.
            .contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    focusTap(at: value.location, region: geometry, screenSize: screenSize)
                }
            )
            #endif
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
                    if model.intervalOutputFormat == .dng && camera.liveBlendDNGSupport.isSupported {
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
        if model.intervalOutputFormat == .dng,
           camera.liveBlendDNGSupport.isSupported,
           let sensor = camera.liveBlendDNGSupport.sensorDimensions {
            return sensorSummaryLabel(sensor)
        }
        return camera.selectedResolution.stillLabel
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
                intervalRunningPills
                blendDiagnosticsReadout
                holyGrailReadout
            }
        } else {
            // The output format lives in the format pill and its sheet — no
            // duplicate copy line here.
            intervalPickerRow
        }
    }

    /// Landscape twin of `intervalStatusRow`, shown in the viewfinder's safe
    /// corner: the controls sit over the live image (no letterbox there), so
    /// they get dark backdrops to stay legible.
    @ViewBuilder
    private var landscapeIntervalRow: some View {
        if showsIntervalRunningRow {
            VStack(alignment: .leading, spacing: 6) {
                intervalRunningPills
                blendDiagnosticsReadout
                holyGrailReadout
            }
        } else {
            intervalPickerRow
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.5), in: Capsule())
        }
    }

    /// Interval's run counter is the burst pill's zebra — open-ended, so no
    /// total; the count is outputs so far (stills or blends). The elapsed
    /// pill keeps the run clock beside it; both fade together on settle.
    private var intervalRunningPills: some View {
        HStack(spacing: 12) {
            burstStatusPill
            CameraPill(text: elapsedIntervalText, tint: .white.opacity(0.7), monospaced: true)
                .opacity(burstPillFadingOut ? 0 : 1)
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

    /// `LL_HOLYGRAIL=armed` arms the ramp dial; `LL_HOLYGRAIL=running` also
    /// freezes a mid-ramp state on screen — the readout the simulator can
    /// never produce for itself, since it has no camera to ramp. Implies
    /// Interval mode. Pair with `LL_CAPTURE=1`.
    private func applyHolyGrailPreviewHook() {
        guard let raw = ProcessInfo.processInfo.environment["LL_HOLYGRAIL"] else { return }
        mode = .interval
        holyGrailEnabled = true
        updateAspectPreview()
        guard raw == "running" else { return }
        camera.holyGrailState = CameraController.HolyGrailState(
            shutterSeconds: 1.0,
            iso: 1250,
            sceneEV: 1.4,
            frames: 24,
            isISORamping: true,
            isClipped: false,
            isCapturingRAW: true)
        framingStartedAt = Date().addingTimeInterval(-602)
        mountBurstPill(taken: 24, total: nil)
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
            blendDepth: blendDepth,
            safeDepthAvailable: safeDepthAvailable,
            captionText: blendCaptionText,
            rampAvailable: Self.holyGrailAvailable,
            holyGrail: holyGrailEnabled && Self.holyGrailAvailable,
            onSelectInterval: { interval = $0 },
            onSelectFixedBlend: { frames in
                blendDepth = .fixed(frames)
                lastFixedBlendFrames = frames
            },
            onSelectPsycho: selectPsychoDepth,
            onSelectSafe: { blendDepth = .throttled },
            onSelectHolyGrail: { holyGrailEnabled = $0 }
        )
        .equatable()
    }

    /// First selection shows the honest warmth-and-learning note, once.
    private func selectPsychoDepth() {
        blendDepth = .unthrottled
        if !UserDefaults.standard.bool(forKey: Self.psychoNoticeShownKey) {
            UserDefaults.standard.set(true, forKey: Self.psychoNoticeShownKey)
            showPsychoNotice = true
        }
    }

    /// The trailing caption only makes sense while blending; the adaptive
    /// depths say what drives their count instead. A Holy Grail shoot has no
    /// live blend at all — its caption says what the ramp will do.
    private var blendCaptionText: String? {
        if holyGrailEnabled, Self.holyGrailAvailable {
            // The ramp's caption has to name what BLEND is doing to it: with
            // a depth the frames are averaged as the shoot runs, without one
            // they are single sharp stills kept as a RAW pair.
            switch blendDepth {
            case .fixed(1): return "ramping exposure"
            case .fixed: return "ramping exposure · blended as it shoots"
            case .unthrottled, .throttled: return "ramping exposure · max frames per image"
            }
        }
        switch blendDepth {
        case .fixed(let frames):
            return frames > 1 ? "into one image" : nil
        case .unthrottled:
            return "max frames into one image"
        case .throttled:
            let learned = BlendProfileStore.shared.safeFrameCount(
                pipeline: activeBlendPipeline,
                bucket: ThermalBucket(thermalState: ProcessInfo.processInfo.thermalState),
                intervalSeconds: interval)
            return learned.map { "≈\($0) frames into one image" } ?? "learned limit"
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
                Text("blend \(diagnostics.lastBlendMillis.map { String(format: "%.0f ms", $0) } ?? "–")\(diagnostics.outputFormatLabel.map { " · \($0)" } ?? "") · \(diagnostics.status.rawValue)")
                    .foregroundStyle(blendStatusTint(diagnostics.status))
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// The Holy Grail ramp's live readout: the exposure the next frame will be
    /// taken at, the scene EV it is tracking, and — the part that decides
    /// whether to keep shooting — whether ISO has started carrying the ramp,
    /// or the scene has run past what the hardware can hold.
    @ViewBuilder
    private var holyGrailReadout: some View {
        if let state = camera.holyGrailState {
            VStack(alignment: .leading, spacing: 2) {
                // %.0f, not an Int interpolation: `Text` group-separates an
                // interpolated number by locale ("ISO 1 250"), which reads as
                // two values in a monospaced technical line.
                Text("\(shutterText(state.shutterSeconds)) · ISO \(String(format: "%.0f", state.iso))\(state.isCapturingRAW ? " · RAW" : "")")
                Text(String(format: "scene EV %.1f · %d frames", state.sceneEV, state.frames))
                if state.isClipped {
                    Text("past the sensor's limit — frames no longer track")
                        .foregroundStyle(Color.red)
                } else if state.isISORamping {
                    Text("shutter at max · ISO ramping")
                        .foregroundStyle(LL.amber)
                }
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func blendStatusTint(_ status: LiveBlendStatus) -> Color {
        switch status {
        case .healthy: return .white.opacity(0.75)
        case .captureFailed: return .red
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
    /// burst, so there's no spacing picker. The capture-when-steady toggle
    /// lives in the shutter-row controls (`steadyToggleCircle`) unchanged.
    /// Its own `Equatable` view for the same reason as `intervalPickerRow` —
    /// see CaptureDials.swift. Photo needs it most: `isWaitingForSteady` is not
    /// `isCapturing`, so this row stays on screen through the steady-gate wait
    /// while `SteadinessMonitor` publishes at 50 Hz.
    private var photoControlsRow: some View {
        PhotoBlendDial(
            isBulb: photoBulbMode,
            frames: photoBlendDepth,
            onSelectBulb: { photoBulbMode = true },
            onSelectFrames: { frames in
                photoBulbMode = false
                photoBlendDepth = frames
            }
        )
        .equatable()
    }

    // MARK: - Recent capture tile

    /// Side of the lower-left recent-capture tile.
    private static let recentTileSize: CGFloat = 60

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

                if let target = activeTarget, camera.isRecording {
                    Circle()
                        .trim(from: 0, to: min(1, elapsedSeconds / max(1, target.recordSeconds)))
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

    /// "2s" while the delay is armed; the live countdown once tapped.
    private var shutterDelayLabel: String? {
        if let deadline = delayedStartAt {
            return "\(max(1, Int(deadline.timeIntervalSince(now).rounded(.up))))"
        }
        return shutterDelayEnabled ? "2s" : nil
    }

    /// Centered readout on the idle shutter: the armed capture-when-steady hand
    /// and the self-timer countdown/"2s", sharing the same slot and type
    /// treatment. The hand icon stands in for text at the same placement.
    @ViewBuilder
    private var shutterBadge: some View {
        HStack(spacing: 5) {
            if mode == .photo && photoBulbMode {
                Text("BULB")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white)
            }
            if photoCaptureWhenSteady {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 16, weight: .bold))
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
            if camera.isIntervalRunning {
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
            } else if isWaitingForSteady {
                // Still arming the steady gate — cancel the wait; the gate
                // resolves as "not settled" and the capture aborts.
                steadiness.stop()
            } else if photoBulbMode {
                Task { await fireBulbCapture() }
            } else {
                Task { await firePhotoCapture() }
            }
        }
    }

    /// Bulb: optionally hold for the device to settle, then start an uncapped
    /// plain-still burst that runs until the user taps the shutter again.
    private func fireBulbCapture() async {
        steadiness.start()
        defer { steadiness.stop() }

        if photoCaptureWhenSteady {
            isWaitingForSteady = true
            let didSettle = await steadiness.waitUntilSteady(timeout: 15)
            isWaitingForSteady = false
            if !didSettle { return }  // timed out or cancelled — don't start
        }

        startBulbCapture()
    }

    private func startBulbCapture() {
        framingStartedAt = Date()
        dismissBurstPill()  // re-appears on the first shot
        // DNG Bulb: one open-ended live-blend RAW window that stacks every
        // captured frame into a single blended DNG when the user stops. No
        // auto-stop — the second shutter tap closes it (see `shutterAction`).
        if wantsPhotoDNG {
            photoDNGAutoStop = false
            camera.startLiveBlend(
                every: Self.photoBulbDNGInterval,
                depth: .unthrottled,
                preferDNG: true,
                options: liveBlendDNGOptions)
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

    /// Photo mode: optionally hold for the device to settle, then fire a
    /// capped-frame still capture. A single snapshot (blend off) captures one
    /// frame; a steadied burst captures `photoBlendDepth` frames that stack
    /// into one long exposure in post.
    private func firePhotoCapture() async {
        steadiness.start()
        defer { steadiness.stop() }

        // Only a blended capture benefits from the steady hold — a single
        // snapshot fires straight away.
        if photoCaptureWhenSteady && photoBlendDepth > 1 {
            isWaitingForSteady = true
            let didSettle = await steadiness.waitUntilSteady(timeout: 15)
            isWaitingForSteady = false
            if !didSettle { return }  // timed out or cancelled — don't fire
        }

        startPhotoCapture()
    }

    private func startPhotoCapture() {
        framingStartedAt = Date()
        dismissBurstPill()  // re-appears on the first shot
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
                options: options)
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
        if holyGrailEnabled, Self.holyGrailAvailable {
            steadiness.resetLog()
            steadiness.start()
            camera.startLiveBlend(
                every: interval,
                depth: blendDepth,
                preferDNG: wantsDNG,
                options: liveBlendDNGOptions,
                holyGrail: true)
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

    /// Left of the shutter: the burst/marker trigger while recording,
    /// the exposure lock otherwise.
    @ViewBuilder
    private var leadingControl: some View {
        if camera.isRecording {
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
        } else {
            // The grid toggle lives here now (moved from the shutter row's
            // trailing slot), beside the AE/AF lock — the left-side controls.
            // Stacked, not side by side: the recent-capture tile took the
            // outer half of this slot.
            VStack(spacing: 8) {
                gridToggleCircle
                exposureLockCircle
            }
        }
    }

    /// Rule-of-thirds grid toggle — a left-side control matching the exposure
    /// lock's circular chrome.
    private var gridToggleCircle: some View {
        Button {
            showGrid.toggle()
        } label: {
            Image(systemName: showGrid ? "grid.circle.fill" : "grid.circle")
                .font(.system(size: 20))
                .foregroundStyle(showGrid ? LL.amber : .white)
                .frame(width: 44, height: 44)
                .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Toggle grid")
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
            Image(systemName: ramping
                  ? (isLocked ? "camera.metering.spot" : "camera.metering.center.weighted")
                  : (isLocked ? "lock.fill" : "lock.open"))
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

    /// Right of the shutter: delay + capture-when-steady toggles idle, the
    /// interval/marker count while recording.
    @ViewBuilder
    private var trailingControl: some View {
        if camera.isRecording {
            let count = camera.rampIntervalCount
            Text("\(count)")
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundStyle(count > 0 ? LL.amber : .white.opacity(0.4))
                .frame(width: 44, height: 44)
                .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Circle())
        } else {
            // Stacked to match the leading column (see `leadingControl`).
            VStack(spacing: 8) {
                shutterDelayCircle
                // Capture-when-steady toggle, in the grid button's old slot.
                steadyToggleCircle
            }
        }
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

    /// Capture-when-steady toggle — a circular icon button matching the 2 s
    /// delay button's shape and on/off treatment. Present in every mode; the
    /// gate itself still only fires in Photo (see `firePhotoCapture`).
    private var steadyToggleCircle: some View {
        Button {
            photoCaptureWhenSteady.toggle()
        } label: {
            Image(systemName: photoCaptureWhenSteady ? "hand.raised.fill" : "hand.raised")
                .font(.system(size: 18))
                .foregroundStyle(photoCaptureWhenSteady ? LL.amber : .white)
                .frame(width: 44, height: 44)
                .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photoCaptureWhenSteady ? "Turn off capture when steady" : "Turn on capture when steady")
    }

    // MARK: - Target capture

    private func startTargetCapture(_ plan: CaptureTargetPlan) {
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

    // MARK: - Manual exposure

    /// Landscape-rail variant: all four framing toggles — grid, AE/AF lock,
    /// 2 s delay and capture-when-steady — plus the frozen readout, matching
    /// portrait's shutter-row pair of columns. Fine brightness/focus tuning
    /// lives in portrait or on the Watch crown.
    private var landscapeExposureControl: some View {
        VStack(spacing: 6) {
            steadyToggleCircle
            shutterDelayCircle
            gridToggleCircle
            exposureLockCircle

            // The rail carries whichever readout is true of this mode: the
            // frozen pair under a lock, the ramp's live pair under Holy Grail.
            if holyGrailArmed {
                Text(holyGrailExposureReadout)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LL.amber)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 96)
            } else if camera.isExposureLocked {
                Text(exposureReadout)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LL.amber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 96)
            }
        }
    }

    private func toggleExposureLock() {
        if camera.isExposureLocked {
            camera.unlockExposureAndFocus()
        } else {
            camera.lockExposureAndFocus()
        }
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
        guard seconds > 0 else { return "—" }
        if seconds >= 1 { return String(format: "%.1fs", seconds) }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    /// What the ramp is doing right now, or — before it starts — what it is
    /// set to do. Deliberately not called a "lock": nothing here is frozen.
    private var holyGrailExposureReadout: String {
        var text: String
        if let state = camera.holyGrailState {
            text = "\(shutterText(state.shutterSeconds)) · ISO \(String(format: "%.0f", state.iso))"
        } else {
            text = "ramping · exposure follows the light"
        }
        if abs(camera.holyGrailBias) >= 0.05 {
            text += String(format: " · %+.1f EV", camera.holyGrailBias)
        }
        return text
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
        if holyGrailArmed {
            // No locked exposure to report and none to offer: the ramp is
            // driving. What the operator gets instead is where the ramp sits
            // relative to the camera's own metering — over or under — plus
            // the focus slider once focus is held.
            VStack(spacing: 10) {
                HStack {
                    Text(holyGrailExposureReadout)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(LL.amber)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
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
        case .stopRecording:
            if camera.isRecording {
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
            interval = value
            return true
        case .setFramesPerBlend:
            // The Watch picker only offers the fixed counts; the adaptive
            // depths are set on the phone, where Safe's gating lives.
            guard !isCapturing, let value,
                  BlendDepth.fixedOptions.contains(where: { $0.frames == Int(value) }) else { return false }
            blendDepth = .fixed(Int(value))
            lastFixedBlendFrames = Int(value)
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
            intervalSeconds: interval,
            blendDepth: blendDepth,
            isBulbMode: mode == .photo && photoBulbMode,
            captureCount: count)
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

/// Photo mode's "waiting for steady" indicator — a pulsing centered badge that
/// reads amber while the device is moving and flips to green the instant it
/// settles, just before the shutter fires. The countdown text's steadiness twin.
private struct SteadyGateOverlay: View {
    var isStill: Bool
    var magnitude: Double
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke((isStill ? Color.green : LL.amber).opacity(0.6), lineWidth: 2)
                    .frame(width: 64, height: 64)
                    .scaleEffect(pulse ? 1.12 : 0.9)
                    .opacity(pulse ? 0.2 : 0.85)
                Image(systemName: isStill ? "checkmark" : "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isStill ? Color.green : LL.amber)
            }
            Text(isStill ? "Steady" : "Waiting for steady")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(18)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityLabel(isStill ? "Steady" : "Waiting for steady")
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
    @AppStorage(FlatCapture.storageKey) private var captureFlat = false
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
                        Toggle(isOn: $captureFlat) {
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
}

/// "I want a 6 s clip at 100×" — pick the clip, we tell you how long to record.
private struct CaptureTargetSheet: View {
    var captureFPS: Int
    var outputFPS: Int
    var onStart: (CaptureTargetPlan) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var clipSeconds: Double = 6
    @State private var speed = 100
    @State private var autoStop = true

    private let speeds = [25, 50, 100, 200]

    var body: some View {
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
                    autoStop: autoStop
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
