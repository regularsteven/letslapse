import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import os
import LetsLapseKit

// MARK: - Shared data types

/// Health of a running Live Blend session, worst condition wins.
enum LiveBlendStatus: String, Codable {
    case healthy = "Healthy"
    case reducedFrameCount = "Reduced frame count"
    case cameraRateLimited = "Camera frame rate limited"
    case processingBehind = "Processing behind"
    case thermalPressure = "Thermal pressure"
    case captureFailed = "Capture failed"
}

/// Compact readout for the capture screen, pushed on the main queue.
struct LiveBlendDiagnosticsSnapshot: Equatable {
    var requestedIntervalSeconds: Double
    var requestedFramesPerBlend: Int
    var currentWindowSelectedFrames = 0
    var lastCapturedFrames: Int?
    var lastBlendMillis: Double?
    var lastOutputIntervalSeconds: Double?
    var outputCount = 0
    var status: LiveBlendStatus = .healthy
    /// Shown in the running readout so the active output format is visible
    /// during capture, not just before it ("DNG" on the RAW path).
    var outputFormatLabel: String? = nil
}

/// Capture-experiment toggles for the DNG path. Each is a Settings switch
/// so device runs can A/B one combination against another; the session log
/// header records what was in force.
struct LiveBlendCaptureOptions: Equatable {
    /// Configure the photo output's responsive-capture pipeline (iOS 17):
    /// zero shutter lag plus overlapped capture and processing, the same
    /// machinery behind the system camera's rapid shot-to-shot pace.
    var responsiveCapture = true
    /// Fire each window's frames back-to-back from the window open instead
    /// of spreading them across the interval — same frame count, a fraction
    /// of the inter-frame displacement, so motion streaks instead of
    /// ghosting.
    var burstScheduling = true
    /// Ask for consecutive-sensor-frame RAW brackets where the device
    /// allows them (video-rate spacing inside each bracket). Experimental;
    /// replaces the responsive pipeline for the run.
    var bracketedRAW = false
}

/// Everything a finished session hands back to the capture screen.
struct LiveBlendCaptureResult {
    var frameURLs: [URL]
    var logURL: URL
    var completedOutputs: Int
    var fallbackOutputs: Int
    var failedOutputs: Int
    /// "dng" when the RAW path produced the frames; drives the project's
    /// provenance label at registration.
    var outputFormat: String = "standard"
}

/// The experiment log written to Application Support/LetsLapse/Logs/.
/// Rewritten atomically after every output so a crash loses nothing.
struct LiveBlendSessionLog: Codable {
    struct Header: Codable {
        var startedAt: Date
        var deviceModel: String
        var osVersion: String
        var appVersion: String
        var cameraName: String
        var captureWidth: Int
        var captureHeight: Int
        var configuredFrameRate: Int
        var requestedIntervalSeconds: Double
        /// The fixed frames-per-blend, or 0 for the adaptive depths (see
        /// `blendDepth`).
        var requestedFramesPerBlend: Int
        /// "fixed" / "unthrottled" / "throttled"; nil in logs from before
        /// the adaptive depths existed.
        var blendDepth: String? = nil
        /// What the user asked for ("standard"/"dng") vs what this session
        /// actually produces — a visible record of any fallback.
        var requestedOutputFormat: String = "standard"
        var outputFormat: String = "standard"
        // DNG capture-experiment toggles in force for this run (nil on the
        // standard path and in logs from before the experiments existed).
        var responsiveCapture: Bool? = nil
        var burstScheduling: Bool? = nil
        var bracketedRAW: Bool? = nil
        /// The output's bracket ceiling for the active format (0 = none).
        var bracketMaxFrames: Int? = nil
    }

    struct OutputEntry: Codable {
        var index: Int
        var windowStartSeconds: Double
        var windowEndSeconds: Double
        var requestedIntervalSeconds: Double
        /// Completion-to-completion spacing; nil for the first output.
        var actualIntervalSeconds: Double? = nil
        /// This window's resolved frame target; 0 = unlimited (unthrottled).
        var requestedFrames: Int
        var capturedFrames: Int
        var missedRateLimited: Int
        var droppedProcessingBehind: Int
        var droppedByCamera: Int
        var frameFailures: Int
        /// Selected-frame timestamps relative to the first frame of the run.
        var frameTimesSeconds: [Double]
        var frameSpacingAvgSeconds: Double?
        var frameSpacingMinSeconds: Double?
        var frameSpacingMaxSeconds: Double?
        var blendMillis: Double? = nil
        var encodeMillis: Double? = nil
        var totalMillis: Double = 0
        var fileBytes: Int? = nil
        var memoryFootprintBytes: Int? = nil
        var thermalState: String
        /// Thermal state when the window opened — the learning system's
        /// primary predictor; `thermalState` above is read at close.
        var thermalStateAtStart: String? = nil
        /// An unthrottled window stopped capturing at the app's memory
        /// budget rather than the device's rate.
        var memoryCapped: Bool? = nil
        var partial: Bool
        var fallbackSingleFrame: Bool = false
        var failed: Bool = false
        /// Empty because the backpressure gate withheld captures while
        /// processing caught up — the scheduler's restraint, not a failure;
        /// excluded from the consecutive-failure stop guard.
        var starvedBackpressure: Bool = false
        /// Per-output format ("dng"/"standard"); records mid-session
        /// fallbacks individually.
        var outputFormat: String? = nil
        /// Ramped runs (DNG path): worst commanded-vs-delivered exposure
        /// divergence among this window's frames, in stops.
        var exposureDivergenceStops: Double? = nil
        /// Alignment-gate readings for this window (video path) — frames
        /// refused for confidently-displaced framing, the largest measured
        /// shift, and whether the gate adopted a persistent new framing.
        var rejectedByAlignment: Int? = nil
        var peakAlignmentShiftPixels: Double? = nil
        var alignmentReanchored: Bool? = nil
    }

    struct Summary: Codable {
        var endedAt: Date
        var captureDurationSeconds: Double
        var requestedOutputs: Int
        var completedOutputs: Int
        var fallbackOutputs: Int
        var failedOutputs: Int
        var skippedWindows: Int
        var peakProcessingSeconds: Double
        var peakMemoryFootprintBytes: Int?
        var finalThermalState: String
        var discarded: Bool
    }

    var header: Header
    var outputs: [OutputEntry] = []
    var summary: Summary?
}

extension CaptureExposureLog.WindowPerformance {
    /// The travelling-log view of one experiment-log window: the delivery
    /// facts an analyst needs, with flags stamped only when true so the
    /// per-project document stays small. Both blend controllers feed their
    /// windows through here, so `capture_log.json` reads the same whichever
    /// pipeline produced it.
    init(entry: LiveBlendSessionLog.OutputEntry) {
        self.init(
            requestedFrames: entry.requestedFrames > 0 ? entry.requestedFrames : nil,
            missed: entry.missedRateLimited > 0 ? entry.missedRateLimited : nil,
            droppedProcessingBehind: entry.droppedProcessingBehind > 0
                ? entry.droppedProcessingBehind : nil,
            droppedByCamera: entry.droppedByCamera > 0 ? entry.droppedByCamera : nil,
            failures: entry.frameFailures > 0 ? entry.frameFailures : nil,
            partial: entry.partial ? true : nil,
            memoryCapped: entry.memoryCapped == true ? true : nil,
            fallbackSingleFrame: entry.fallbackSingleFrame ? true : nil,
            thermalStateAtStart: entry.thermalStateAtStart,
            thermalStateAtClose: entry.thermalState,
            frameSpacingAvgSeconds: entry.frameSpacingAvgSeconds,
            frameSpacingMaxSeconds: entry.frameSpacingMaxSeconds,
            processingMillis: entry.totalMillis > 0 ? entry.totalMillis : nil,
            actualIntervalSeconds: entry.actualIntervalSeconds,
            intervalSeconds: entry.requestedIntervalSeconds,
            fileBytes: entry.fileBytes,
            exposureDivergenceStops: entry.exposureDivergenceStops,
            rejectedByAlignment: entry.rejectedByAlignment,
            peakAlignmentShiftPixels: entry.peakAlignmentShiftPixels)
    }
}

extension LiveBlendSessionLog.OutputEntry {
    /// The thermal bucket this window opened in, when the entry recorded it.
    var startBucket: ThermalBucket? {
        thermalStateAtStart.flatMap(ThermalBucket.init(thermalStateName:))
    }

    /// The learning sample a completed unthrottled window contributes.
    /// Distress = the thermal state rose from the window's start, sits at
    /// serious+, or the output cadence drifted well past the interval.
    func learningSample(intervalSeconds: Double, capped: Bool) -> BlendLearningSample {
        let stateNow = ProcessInfo.processInfo.thermalState
        let rose = startBucket.map { ThermalBucket(thermalState: stateNow) > $0 } ?? false
        let drifted = (actualIntervalSeconds ?? 0) > intervalSeconds * 1.3
        return BlendLearningSample(
            date: Date(),
            framesCaptured: capturedFrames,
            throttleDetected: rose || stateNow == .serious || stateNow == .critical || drifted,
            capped: capped,
            blendMillis: blendMillis)
    }
}

// MARK: - Live Blend controller (experimental spike)

/// Drives one Live Blend capture run: selects frames from the camera stream on
/// a schedule, streams them into a `PixelBufferBlender`, writes one JPEG per
/// interval, and keeps the experiment log. Owned by `CameraController`, which
/// does all AVCaptureSession surgery; this class only consumes sample buffers.
///
/// Threading: `videoQueue` owns selection state and the watchdog; `blendQueue`
/// owns the blender, output files, and the log. Frames flow videoQueue →
/// blendQueue; both queues are serial so each window's accumulates land before
/// its finalize, and window k+1 queues behind window k's write — processing
/// can lag but never interleave or run unbounded.
final class LiveBlendController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Configuration {
        var intervalSeconds: Double
        var blendDepth: BlendDepth
        var outputDirectory: URL
        var logURL: URL
        var cameraName: String
        var captureWidth: Int
        var captureHeight: Int
        var configuredFrameRate: Int
        /// "dng" when the user asked for DNG but this (standard) path ran as
        /// the fallback — recorded in the log header.
        var requestedOutputFormat: String = "standard"
        /// Safe mode's frame target, consulted once at each window open;
        /// nil for the other depths.
        var throttledFrameTarget: (() -> Int)? = nil
        /// Auto's device ceiling and scene reading — see the twins in
        /// `LiveBlendRawController.Configuration`. The video-tap path is a
        /// cheaper way to spend an interval than RAW stills, so the profiled
        /// ceiling is rarely what binds here; the EV band still is.
        var capabilityProfile: (() -> DeviceCapabilityProfile?)? = nil
        /// Doubles as this pipeline's only exposure record: frames tapped off
        /// the preview stream carry no EXIF, so the device's own reading is
        /// what `capture_log.json` is written from.
        var sceneExposure: (() -> DNGAuthor.DNGExposure?)? = nil
        /// Holy Grail only: the exposure the ramp last COMMANDED, for the
        /// commanded-vs-delivered guard. The DNG path has had this since the
        /// 2026-08-20 sunset; this path did not, which is how a 4.7-stop
        /// divergence ran a whole shoot unremarked (2026-08-22: ramp asked
        /// 1.0 s / ISO 97, sensor delivered 1/25 s / ISO 2534, because a
        /// video frame cannot expose for longer than its frame duration).
        var rampExposure: (() -> (duration: CMTime, iso: Float)?)? = nil
        /// Identity and vocabulary for `capture_log.json`.
        var sessionID: String = UUID().uuidString
        var deviceModel: String = ""
        /// Geotag source: the EXIF GPS dictionary for the current fix, or nil
        /// when tagging is off or no fix exists yet. Called on the blend queue
        /// as each output is written, so every blended frame carries the fix
        /// from its own moment — matching the plain-still capture path.
        var gpsMetadata: (() -> [String: Any]?)? = nil
        /// Capture Flat: grade each output at the window's full float
        /// precision before its one 8-bit quantization. Snapshotted at run
        /// start (the toggle must not change a run midway) and recorded in
        /// `capture_log.json` — the 2026-08-23 flat/non-flat A/B was
        /// undiagnosable because the old path neither applied nor logged it.
        var captureFlat: Bool = false
        /// Whether this run writes the `frames.timestamps` sidecar — one line
        /// per output file as it lands, flushed immediately, so the finished
        /// project's time axis survives a crash exactly as its frames do.
        /// False on Holy Grail runs: the ramp already owns that file and
        /// appends richer entries (scene EV) per window from CameraController.
        var writesFrameTimestamps: Bool = true

        /// What readouts show before the first window resolves: the fixed
        /// count, or 0 (unlimited/unresolved) for the adaptive depths.
        var initialDisplayFrames: Int { blendDepth.fixedFrames ?? 0 }
    }

    /// Unthrottled windows have no target grid, so backpressure alone bounds
    /// enqueued-but-unblended frames.
    private static let unthrottledPendingCap = 8

    /// One compiled kernel set for the app lifetime; nil only when Metal is
    /// unavailable, which `init` turns into a thrown error.
    private static let sharedCore: BlendCore? = try? BlendCore()

    let videoQueue = DispatchQueue(label: "com.letslapse.liveblend.video")
    private let blendQueue = DispatchQueue(label: "com.letslapse.liveblend.blend", qos: .userInitiated)
    /// `var`, not `let`, for exactly one reason: EVERY=Auto. A Holy Grail run
    /// on Auto re-paces itself as the light dies (see `HolyGrailAutoInterval`).
    /// Only `setIntervalSeconds` writes it, and only on `videoQueue`, where
    /// every reader already lives.
    private var configuration: Configuration
    private let blender: PixelBufferBlender

    /// Both fired on the main queue.
    var onDiagnostics: ((LiveBlendDiagnosticsSnapshot) -> Void)?

    /// Fired as each interval window opens, on this controller's own queue,
    /// with the window's index and the **mean linear luma of the window that
    /// just ended** (nil if it saw no frames). The Holy Grail ramp hangs off
    /// it: one exposure is chosen per window and held for every frame that
    /// window averages, because a window whose frames were shot at different
    /// exposures blends its own flicker into the output image.
    ///
    /// The luma is why this reports rather than just notifies. A ramp must be
    /// told what the scene is doing by something that does **not** depend on
    /// the exposure the ramp itself chose — measure through your own exposure
    /// and darkening the frame "proves" the scene got brighter, which is a
    /// positive feedback loop (it walked a real shoot 9.7 stops into its
    /// shutter floor on 2026-08-15). The delivered image's own brightness is
    /// the honest signal: darker frame, more light needed.
    var onWindowOpened: ((Int, Double?) -> Void)?

    /// Running mean of the current window's sampled luma. videoQueue.
    private var windowLumaSum: Double = 0
    private var windowLumaCount = 0
    /// The completed window's mean, handed to `onWindowOpened` for the next.
    private var lastWindowLuma: Double?
    /// Auto's Zone decision state — the same Kit strategy the DNG path's
    /// control arm runs, so the two Auto pipelines cannot drift. videoQueue.
    private var zoneBlend = ZoneBlendStrategy()
    /// The last actuated Auto count, held verbatim through meter dropouts.
    private var lastAutoCount: Int?
    /// nil result = nothing to register (zero outputs, or a discarded run).
    var onFinished: ((LiveBlendCaptureResult?) -> Void)?
    /// Fired on the blend queue for each completed unthrottled window — what
    /// the learning profiles are built from.
    var onLearningSample: ((ThermalBucket, BlendLearningSample) -> Void)?

    // Cross-queue state. `generation` invalidates queued blend work on
    // discard; `pending` counts enqueued-but-unprocessed frames for
    // backpressure; `active` is false once the run has finished (checked by
    // CameraController's setter guards and teardown).
    private let active = OSAllocatedUnfairLock(initialState: true)
    private let pending = OSAllocatedUnfairLock(initialState: 0)
    private let generation = OSAllocatedUnfairLock(initialState: 0)
    private let diagnostics: OSAllocatedUnfairLock<LiveBlendDiagnosticsSnapshot>

    var isActive: Bool { active.withLock { $0 } }

    // videoQueue-confined selection state.
    private struct WindowRecord {
        var index: Int
        var startSeconds: Double
        /// The interval the window was paced by, snapshotted at open on
        /// videoQueue — `configuration.intervalSeconds` is videoQueue-owned
        /// and can be re-paced (EVERY=Auto) before this window's close is
        /// processed on blendQueue.
        var intervalSeconds: Double
        /// Resolved at window open; nil = unthrottled (take every frame).
        var frameTarget: Int? = nil
        var thermalStateAtStart = "unknown"
        var frameTimes: [Double] = []
        var missedRateLimited = 0
        var droppedProcessingBehind = 0
        var droppedByCamera = 0
        var bufferFailures = 0
        var partial = false
        /// What the camera reported it was exposing at when this window
        /// opened. The video tap's frames carry no EXIF of their own, so this
        /// is the whole exposure record for the output the window produces.
        var exposure: DNGAuthor.DNGExposure? = nil
        /// Alignment-gate tallies. `rejectedByAlignment` counts reject
        /// verdicts; on a single-frame window the flagged frame is still
        /// used (never starve a depth-1 window), which the log's blend
        /// depth makes legible.
        var rejectedByAlignment = 0
        var peakAlignmentShiftPixels: Double? = nil
        var alignmentReanchored = false
    }

    /// Refuses confidently-displaced frames before they ghost the stack
    /// (2026-08-23: OIS sag at thermal critical shifted frames ~63 px
    /// mid-window; the engine's own records were spotless). videoQueue.
    private let alignmentGate = FrameAlignmentGate()
    private var selecting = false
    private var finishRequested = false
    private var sessionStartPTS: Double?
    private var windowIndex = 0
    private var windowStartSeconds = 0.0
    private var nextTargetIndex = 0
    private var window: WindowRecord
    private var startedAtHost = DispatchTime.now()
    private var lastFrameAtHost = DispatchTime.now()
    private var preAnchorFailedWindows = 0
    private var watchdog: DispatchSourceTimer?

    // blendQueue-confined output state.
    private var log: LiveBlendSessionLog
    private var frameURLs: [URL] = []
    /// One entry per written output frame, for `capture_log.json`. blendQueue.
    private var sessionFrameLog: [CaptureExposureLog.Entry] = []
    /// The `frames.timestamps` twin of the entry above — appended beside each
    /// written file, live, where the exposure log lands only at close. nil
    /// when the configuration hands the sidecar to somebody else. blendQueue.
    private let timestampWriter: FrameTimestampWriter?
    /// The shoot's recorded issue trail for `capture_log.json`. blendQueue.
    private var sessionIssues: [CaptureExposureLog.Issue] = []
    /// Last thermal state an issue was recorded against, so transitions are
    /// recorded once each. blendQueue.
    private var issuedThermalState: String?
    /// Why the run ended, for the travelling log — parity with the DNG path
    /// (the 2026-08-22 sunrise stops were undiagnosable without it).
    /// Written on videoQueue before the finish hops queues.
    private var endReason: String?
    /// Windows that closed with nothing usable arrived (camera went quiet) —
    /// the travelling log's `starvedWindows`. blendQueue.
    private var emptyWindows = 0
    private let runStartedAt = Date()
    private var outputIndex = 0
    private var completedOutputs = 0
    private var fallbackOutputs = 0
    private var failedOutputs = 0
    private var skippedWindows = 0
    private var accumulateFailuresThisWindow = 0
    /// Rate-limits the divergence log to one line per half-stop of change.
    private var lastDivergenceLogged: Double = 0
    /// One "the ramp commanded nothing" report per session — the condition is
    /// a property of the run, not of a window, so repeating it every window
    /// would bury the log it is meant to make readable.
    private var issuedRampSilence = false
    private var consecutiveProcessingFailures = 0
    private var lastCompletionUptime: Double?
    private var peakProcessingSeconds = 0.0
    private var peakMemoryFootprint: Int?
    private var loggedLogWriteFailure = false
    private let startUptime = ProcessInfo.processInfo.systemUptime

    init(configuration: Configuration) throws {
        guard let core = LiveBlendController.sharedCore else {
            throw LapseError.metalUnavailable
        }
        self.configuration = configuration
        self.blender = PixelBufferBlender(core: core, linearLight: true)
        self.timestampWriter = configuration.writesFrameTimestamps
            ? FrameTimestampWriter(directory: configuration.outputDirectory)
            : nil
        self.window = WindowRecord(
            index: 0, startSeconds: 0,
            intervalSeconds: configuration.intervalSeconds)
        self.diagnostics = OSAllocatedUnfairLock(initialState: LiveBlendDiagnosticsSnapshot(
            requestedIntervalSeconds: configuration.intervalSeconds,
            requestedFramesPerBlend: configuration.initialDisplayFrames))
        self.log = LiveBlendSessionLog(header: LiveBlendSessionLog.Header(
            startedAt: Date(),
            deviceModel: LiveBlendController.deviceModelIdentifier(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: LiveBlendController.appVersion(),
            cameraName: configuration.cameraName,
            captureWidth: configuration.captureWidth,
            captureHeight: configuration.captureHeight,
            configuredFrameRate: configuration.configuredFrameRate,
            requestedIntervalSeconds: configuration.intervalSeconds,
            requestedFramesPerBlend: configuration.initialDisplayFrames,
            blendDepth: configuration.blendDepth.familyName,
            requestedOutputFormat: configuration.requestedOutputFormat,
            outputFormat: "standard"))
        super.init()
    }

    // MARK: Run control

    func start() {
        videoQueue.async {
            self.selecting = true
            self.startedAtHost = .now()
            self.lastFrameAtHost = .now()
            self.armWatchdog()
            LLog("liveblend: start interval=\(self.configuration.intervalSeconds)s depth=\(self.configuration.blendDepth.token) log=\(self.configuration.logURL.path)")
            self.blendQueue.async { self.rewriteLog() }
        }
    }

    /// Re-paces a running shoot — the EVERY=Auto path, and nothing else calls
    /// it. Applied from the next window boundary onward, so the window in
    /// flight is never truncated mid-capture.
    func setIntervalSeconds(_ seconds: Double) {
        videoQueue.async {
            let next = min(max(seconds, 0.5), 600)
            guard self.configuration.intervalSeconds != next else { return }
            LLog("liveblend: re-paced \(self.configuration.intervalSeconds)s → \(next)s")
            self.configuration.intervalSeconds = next
        }
    }

    /// Graceful stop keeps a ≥1-frame partial window (unless `keepPartial`
    /// is false — a scheduled "stop at N" wants exactly N) and hands the run
    /// over; discard drops queued work, deletes the temp frames, and never
    /// fires the result. All are safe to call more than once.
    func requestStop(discard: Bool, keepPartial: Bool = true, reason: String = "user") {
        videoQueue.async {
            guard !self.finishRequested else { return }
            self.finishRequested = true
            self.endReason = reason
            self.selecting = false
            self.watchdog?.cancel()
            self.watchdog = nil
            if discard {
                self.generation.withLock { $0 += 1 }
            } else if keepPartial, self.sessionStartPTS != nil, !self.window.frameTimes.isEmpty {
                self.window.partial = true
                self.closeCurrentWindow()
            }
            self.blendQueue.async { self.finishOnBlendQueue(discard: discard) }
        }
    }

    // MARK: Frame selection (videoQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        autoreleasepool {
            guard selecting else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            guard pts.isFinite else { return }
            lastFrameAtHost = .now()

            if sessionStartPTS == nil {
                sessionStartPTS = pts
                windowStartSeconds = 0
                nextTargetIndex = 0
                window = openWindow(index: windowIndex, startSeconds: 0)
            }
            guard let start = sessionStartPTS else { return }
            let t = pts - start
            let interval = configuration.intervalSeconds

            // Close every window this frame has passed. If processing stalled
            // long enough to fall many windows behind, re-anchor the grid
            // instead of flooding the log with empty entries.
            var closed = 0
            while t >= windowStartSeconds + interval, closed < 3 {
                closeCurrentWindow()
                closed += 1
            }
            if t >= windowStartSeconds + interval {
                let jumped = Int((t - windowStartSeconds) / interval)
                windowStartSeconds += Double(jumped) * interval
                window = openWindow(index: windowIndex, startSeconds: windowStartSeconds)
                nextTargetIndex = 0
                blendQueue.async { self.skippedWindows += jumped }
            }

            // Selection. A fixed/Safe window spreads its target count across
            // the interval on a grid — the first pending target this frame
            // crosses selects it; further targets crossed by the same frame
            // were missed (camera slower than the requested sampling rate).
            // An unthrottled window has no grid: every frame the camera
            // delivers is a candidate, bounded only by backpressure.
            if let target = window.frameTarget {
                guard nextTargetIndex < target, t >= targetSeconds(nextTargetIndex, of: target) else { return }
                nextTargetIndex += 1
                while nextTargetIndex < target, t >= targetSeconds(nextTargetIndex, of: target) {
                    window.missedRateLimited += 1
                    nextTargetIndex += 1
                }
            }

            // Backpressure: one window's worth of frames plus slack may wait
            // for the blender; beyond that the writer has fallen behind and
            // new selections are dropped, never queued.
            if pending.withLock({ $0 }) >= (window.frameTarget.map { $0 + 3 } ?? Self.unthrottledPendingCap) {
                window.droppedProcessingBehind += 1
                return
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                window.bufferFailures += 1
                return
            }
            // Framing integrity. A frame whose framing has confidently moved
            // (lens excursion, knocked rig) must not be averaged into the
            // stack, where it doubles every edge. Costs well under a
            // millisecond per selected frame; low-confidence readings always
            // pass. A single-frame window keeps its flagged frame — a
            // displaced output beats no output — and the log says so.
            let alignment = alignmentGate.evaluate(pixelBuffer)
            if alignment.measured {
                window.peakAlignmentShiftPixels = max(
                    window.peakAlignmentShiftPixels ?? 0, alignment.shiftMagnitudePixels)
            }
            if !alignment.accepted {
                window.rejectedByAlignment += 1
                if window.rejectedByAlignment == 1 {
                    LLog(String(format: "liveblend: alignment gate — frame displaced (%+.0f, %+.0f)px conf %.2f%@",
                                alignment.dxPixels, alignment.dyPixels, alignment.confidence,
                                window.frameTarget == 1 ? ", kept (single-frame window)" : ", rejected"))
                }
                if window.frameTarget != 1 { return }
            }
            window.frameTimes.append(t)
            // Cheap scene measurement for the ramp, taken from the frame the
            // window is about to average — a strided sample, not a full pass.
            if onWindowOpened != nil,
               let luma = LiveBlendController.meanLinearLuma(of: pixelBuffer) {
                windowLumaSum += luma
                windowLumaCount += 1
            }
            pending.withLock { $0 += 1 }
            let expectedGeneration = generation.withLock { $0 }
            blendQueue.async {
                autoreleasepool {
                    self.pending.withLock { $0 -= 1 }
                    guard self.generation.withLock({ $0 }) == expectedGeneration else { return }
                    do {
                        try self.blender.accumulate(pixelBuffer)
                    } catch {
                        self.accumulateFailuresThisWindow += 1
                        LLog("liveblend: accumulate failed: \(error)")
                    }
                }
            }
            let selectedCount = window.frameTimes.count
            pushDiagnostics { $0.currentWindowSelectedFrames = selectedCount }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard selecting else { return }
        window.droppedByCamera += 1
    }

    /// Mean linear-light luma of a BGRA buffer, from a strided sample.
    ///
    /// ~1,000 pixels regardless of resolution, sRGB-decoded (the 2.2 power is
    /// close enough to the piecewise curve for a relative measure) and
    /// Rec.709-weighted. Linear light is the point: the ramp reasons in stops,
    /// and stops are ratios of linear luminance.
    static func meanLinearLuma(of buffer: CVPixelBuffer, targetSamples: Int = 1024) -> Double? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else { return nil }
        let step = max(1, Int((Double(width * height) / Double(targetSamples)).squareRoot()))
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        var count = 0
        var y = 0
        while y < height {
            let row = pixels + y * bytesPerRow
            var x = 0
            while x < width {
                let p = row + x * 4
                let b = Double(p[0]) / 255, g = Double(p[1]) / 255, r = Double(p[2]) / 255
                sum += 0.2126 * pow(r, 2.2) + 0.7152 * pow(g, 2.2) + 0.0722 * pow(b, 2.2)
                count += 1
                x += step
            }
            y += step
        }
        guard count > 0 else { return nil }
        return sum / Double(count)
    }

    private func targetSeconds(_ index: Int, of target: Int) -> Double {
        let spacing = configuration.intervalSeconds / Double(target)
        return windowStartSeconds + (Double(index) + 0.5) * spacing
    }

    /// Auto's per-window count: the scene's EV, smoothed over three windows,
    /// mapped through `ZoneBlendStrategy` and capped by a ceiling derived
    /// from the profile's measured rate against the interval the run is
    /// pacing at *now* — not the ceiling frozen at probe time, which goes
    /// stale when EVERY=Auto re-paces. videoQueue.
    private func resolveAutoFrameTarget(windowIndex index: Int) -> Int {
        let profile = configuration.capabilityProfile?()
        let scene = configuration.sceneExposure?()
        let ceiling = profile.map {
            DeviceCapabilityProfile.ceiling(
                framesPerSecond: $0.framesPerSecond,
                intervalSeconds: configuration.intervalSeconds,
                currentShutterSeconds: scene?.exposureDuration)
        }
        guard let ev = scene?.exposureValue else {
            // Hold the last actuated count — a scene doesn't get brighter
            // because a read failed.
            if let held = lastAutoCount { return held }
            let fallback = max(1, min(ZoneBlendStrategy.band(forEV: 10).frames, ceiling ?? Int.max))
            lastAutoCount = fallback
            return fallback
        }
        let wanted = zoneBlend.resolve(ev: ev)
        let count = max(1, min(wanted, ceiling ?? wanted))
        lastAutoCount = count
        let smoothed = zoneBlend.lastSmoothedEV ?? ev
        LLog("""
            liveblend: auto window \(index) — EV \(String(format: "%.2f", ev)) \
            (smoothed \(String(format: "%.2f", smoothed)), \
            \(ZoneBlendStrategy.band(forEV: smoothed).name)) → \(count) frames\
            \(ceiling.map { ", ceiling \($0)" } ?? "")
            """)
        return count
    }

    /// Opens a window: resolves its frame target (Safe mode re-evaluates
    /// per interval, here) and stamps the thermal state the learning system
    /// keys on. videoQueue.
    private func openWindow(index: Int, startSeconds: Double) -> WindowRecord {
        let target: Int?
        switch configuration.blendDepth {
        case .fixed(let frames): target = frames
        case .unthrottled: target = nil
        case .throttled: target = max(1, configuration.throttledFrameTarget?() ?? 2)
        case .auto: target = resolveAutoFrameTarget(windowIndex: index)
        }
        pushDiagnostics { $0.requestedFramesPerBlend = target ?? 0 }
        if onWindowOpened != nil {
            lastWindowLuma = windowLumaCount > 0 ? windowLumaSum / Double(windowLumaCount) : nil
            windowLumaSum = 0
            windowLumaCount = 0
            onWindowOpened?(index, lastWindowLuma)
        }
        return WindowRecord(
            index: index,
            startSeconds: startSeconds,
            intervalSeconds: configuration.intervalSeconds,
            frameTarget: target,
            thermalStateAtStart: LiveBlendController.thermalStateName(),
            exposure: configuration.sceneExposure?())
    }

    /// Hands the current window to the blend queue and opens the next one.
    /// Pre-anchor (no frame ever seen) windows report dead time without
    /// advancing the PTS grid, which only exists once a frame arrives.
    private func closeCurrentWindow() {
        var record = window
        let alignmentSummary = alignmentGate.windowClosed()
        record.alignmentReanchored = alignmentSummary.reanchored
        if alignmentSummary.reanchored {
            LLog("liveblend: alignment gate re-anchored — framing moved and stayed")
        }
        let enqueuedUptime = ProcessInfo.processInfo.systemUptime
        let expectedGeneration = generation.withLock { $0 }
        blendQueue.async {
            autoreleasepool {
                self.processWindowClose(record, expectedGeneration: expectedGeneration, enqueuedUptime: enqueuedUptime)
            }
        }
        windowIndex += 1
        if sessionStartPTS != nil {
            windowStartSeconds += configuration.intervalSeconds
        }
        nextTargetIndex = 0
        window = openWindow(index: windowIndex, startSeconds: windowStartSeconds)
    }

    // MARK: Watchdog (videoQueue)

    private func armWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        let period = max(0.25, configuration.intervalSeconds / 2)
        timer.schedule(deadline: .now() + period, repeating: period)
        timer.setEventHandler { [weak self] in self?.watchdogFired() }
        timer.resume()
        watchdog = timer
    }

    /// Frames normally close windows; the watchdog only steps in when the
    /// camera goes quiet (unplugged, covered, or never delivered at all) so
    /// failed intervals keep ticking instead of the session hanging.
    private func watchdogFired() {
        guard selecting else { return }
        let interval = configuration.intervalSeconds
        let grace = max(1.0, interval * 0.5)
        if sessionStartPTS == nil {
            let elapsed = seconds(since: startedAtHost)
            if elapsed > Double(preAnchorFailedWindows + 1) * interval + grace {
                preAnchorFailedWindows += 1
                closeCurrentWindow()
            }
        } else if seconds(since: lastFrameAtHost) > interval + grace {
            window.partial = !window.frameTimes.isEmpty
            closeCurrentWindow()
            lastFrameAtHost = .now()
        }
    }

    private func seconds(since time: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- time.uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: Blend + output (blendQueue)

    private func processWindowClose(_ record: WindowRecord, expectedGeneration: Int, enqueuedUptime: Double) {
        guard generation.withLock({ $0 }) == expectedGeneration else { return }

        let spacings = zip(record.frameTimes.dropFirst(), record.frameTimes).map(-)
        var entry = LiveBlendSessionLog.OutputEntry(
            index: record.index,
            windowStartSeconds: record.startSeconds,
            windowEndSeconds: record.startSeconds + record.intervalSeconds,
            requestedIntervalSeconds: record.intervalSeconds,
            requestedFrames: record.frameTarget ?? 0,
            capturedFrames: blender.frameCount,
            missedRateLimited: record.missedRateLimited,
            droppedProcessingBehind: record.droppedProcessingBehind,
            droppedByCamera: record.droppedByCamera,
            frameFailures: record.bufferFailures + accumulateFailuresThisWindow,
            frameTimesSeconds: record.frameTimes,
            frameSpacingAvgSeconds: spacings.isEmpty ? nil : spacings.reduce(0, +) / Double(spacings.count),
            frameSpacingMinSeconds: spacings.min(),
            frameSpacingMaxSeconds: spacings.max(),
            thermalState: LiveBlendController.thermalStateName(),
            partial: record.partial)
        entry.thermalStateAtStart = record.thermalStateAtStart
        accumulateFailuresThisWindow = 0
        if record.rejectedByAlignment > 0 {
            entry.rejectedByAlignment = record.rejectedByAlignment
        }
        // Sub-4 px is ordinary OIS wander — stamping it on every window would
        // just bloat the document (the schema's flags-only-when-true rule).
        if let peak = record.peakAlignmentShiftPixels, peak > 4 || record.rejectedByAlignment > 0 {
            entry.peakAlignmentShiftPixels = peak
        }
        if record.alignmentReanchored { entry.alignmentReanchored = true }
        recordIssues(for: entry, record: record)

        // Commanded-vs-delivered honesty guard, matching the DNG path. This
        // pipeline holds one exposure per window, so the comparison is per
        // window rather than per frame — but the failure it catches is the
        // same one, and on this path it is silent by construction: the AE
        // makes up a clamped shutter with ISO, so the picture looks right
        // while the ramp's model is stops away from the sensor.
        //
        // A ramped run whose provider hands back nil is the same failure at its
        // most extreme — the ramp commanded *nothing*, so the sensor is on AE —
        // and it used to be the one case this guard could not see, because a
        // nil target skipped the whole comparison. Silence now costs an issue.
        let rampTarget = configuration.rampExposure?()
        if configuration.rampExposure != nil, rampTarget == nil, !issuedRampSilence {
            issuedRampSilence = true
            sessionIssues.append(.init(
                at: Date(), windowIndex: entry.index,
                kind: "ramp", severity: "problem",
                detail: "ramp commanded nothing — exposure is AE-driven"))
            LLog("liveblend: RAMP NOT DRIVING — no commanded exposure at window "
                 + "\(entry.index); this run is AE-exposed and the ramp readout is advisory")
        }
        if let target = rampTarget,
           let delivered = record.exposure,
           let deliveredISO = delivered.iso,
           let deliveredDuration = delivered.exposureDuration,
           let divergence = CaptureExposureLog.WindowPerformance.exposureDivergenceStops(
               actualISO: deliveredISO, actualDuration: deliveredDuration,
               targetISO: Double(target.iso), targetDuration: target.duration.seconds) {
            // Under a quarter stop is ISO quantization, not a fault.
            if divergence > 0.25 {
                entry.exposureDivergenceStops = divergence
            }
            if divergence <= 0.5 { lastDivergenceLogged = 0 }
            if divergence > 0.5, abs(divergence - lastDivergenceLogged) > 0.5 {
                lastDivergenceLogged = divergence
                LLog(String(format: """
                    liveblend: EXPOSURE DIVERGENCE %.1f stops — ramp commanded \
                    %.4fs ISO %.0f, sensor delivered %.4fs ISO %.0f
                    """, divergence, target.duration.seconds, Double(target.iso),
                    deliveredDuration, deliveredISO))
            }
        }

        if entry.capturedFrames == 0 {
            // Nothing usable arrived; keep the session going. Not counted as
            // a processing failure — a covered camera shouldn't auto-stop.
            blender.discardWindow()
            entry.failed = true
            failedOutputs += 1
            emptyWindows += 1
        } else {
            do {
                let blendStart = ProcessInfo.processInfo.systemUptime
                let image: CGImage
                if configuration.captureFlat {
                    // Capture Flat: grade the window's half-float mean, so
                    // the single 8-bit quantization happens in flat space.
                    // A CoreImage failure must not cost the frame — the
                    // ungraded mean encodes to exactly what the plain path
                    // would have delivered (ImageIO honours its colorspace).
                    let mean = try blender.finalizeFloatImage()
                    image = FlatCapture.flatten(mean) ?? mean
                } else {
                    image = try blender.finalizeImage()
                }
                entry.blendMillis = (ProcessInfo.processInfo.systemUptime - blendStart) * 1000
                let url = configuration.outputDirectory
                    .appendingPathComponent(String(format: "frame-%05d.jpg", outputIndex))
                let encodeStart = ProcessInfo.processInfo.systemUptime
                // The tapped frames carry no EXIF of their own, so author the
                // record the photo path gets from the camera: the exposure
                // this window opened at, the device, and the fix. (Finding 4
                // of docs/jpeg-holygrail-wb-brief.md — nothing stripped EXIF;
                // it was never written.)
                var metadata = Self.captureMetadata(
                    exposure: record.exposure, deviceModel: configuration.deviceModel)
                if let gps = configuration.gpsMetadata?() {
                    metadata[kCGImagePropertyGPSDictionary] = gps
                }
                try ImageExporter.write(
                    image, to: url, format: .jpeg,
                    metadata: metadata.isEmpty ? nil : metadata)
                entry.encodeMillis = (ProcessInfo.processInfo.systemUptime - encodeStart) * 1000
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                entry.fileBytes = (attributes?[.size] as? NSNumber)?.intValue
                frameURLs.append(url)
                // One line per file that exists, carrying the exposure the
                // window opened at, how many tapped frames went into it, and
                // how the window delivered. totalMillis/actualInterval are
                // finalized below, after this append — patched in there.
                sessionFrameLog.append(CaptureExposureLog.Entry(
                    frameIndex: frameURLs.count,
                    exposure: record.exposure ?? DNGAuthor.DNGExposure(),
                    capturedAt: record.exposure?.capturedAt ?? Date(),
                    blendCount: entry.capturedFrames,
                    window: CaptureExposureLog.WindowPerformance(entry: entry)))
                timestampWriter?.append(FrameTimestamps.Entry(
                    frame: frameURLs.count - 1,
                    captureTime: record.exposure?.capturedAt ?? Date(),
                    shutter: record.exposure?.exposureDuration ?? 0,
                    iso: record.exposure?.iso ?? 0))
                outputIndex += 1
                completedOutputs += 1
                if entry.capturedFrames == 1 {
                    entry.fallbackSingleFrame = true
                    fallbackOutputs += 1
                }
                consecutiveProcessingFailures = 0
            } catch {
                blender.discardWindow()
                entry.failed = true
                failedOutputs += 1
                consecutiveProcessingFailures += 1
                LLog("liveblend: output \(record.index) failed: \(error)")
            }
        }

        let done = ProcessInfo.processInfo.systemUptime
        entry.totalMillis = (done - enqueuedUptime) * 1000
        entry.actualIntervalSeconds = lastCompletionUptime.map { done - $0 }
        lastCompletionUptime = done
        peakProcessingSeconds = max(peakProcessingSeconds, done - enqueuedUptime)
        entry.memoryFootprintBytes = LiveBlendController.memoryFootprintBytes()
        if let footprint = entry.memoryFootprintBytes {
            peakMemoryFootprint = max(peakMemoryFootprint ?? 0, footprint)
        }
        // The session-log line for this window was appended before these
        // figures existed (timings finalize here; the single-frame flag is
        // set just after the append) — complete it now.
        if !entry.failed, let last = sessionFrameLog.indices.last,
           sessionFrameLog[last].window != nil {
            sessionFrameLog[last].window?.processingMillis =
                entry.totalMillis > 0 ? entry.totalMillis : nil
            sessionFrameLog[last].window?.actualIntervalSeconds = entry.actualIntervalSeconds
            sessionFrameLog[last].window?.fallbackSingleFrame =
                entry.fallbackSingleFrame ? true : nil
        }
        log.outputs.append(entry)
        rewriteLog()

        // Every completed unthrottled window is a lesson: what this device
        // managed under these conditions feeds the Safe-mode profiles.
        if configuration.blendDepth == .unthrottled,
           !entry.failed, !entry.partial, entry.capturedFrames > 0,
           let bucket = entry.startBucket {
            onLearningSample?(bucket, entry.learningSample(
                intervalSeconds: configuration.intervalSeconds,
                capped: entry.droppedProcessingBehind > 0))
        }

        let status = status(after: entry)
        pushDiagnostics {
            $0.lastCapturedFrames = entry.capturedFrames
            $0.lastBlendMillis = entry.blendMillis
            $0.lastOutputIntervalSeconds = entry.actualIntervalSeconds
            $0.outputCount = self.completedOutputs
            $0.currentWindowSelectedFrames = 0
            $0.status = status
        }
        LLog("liveblend: window \(entry.index) captured=\(entry.capturedFrames)/\(entry.requestedFrames) blend=\(Int(entry.blendMillis ?? 0))ms total=\(Int(entry.totalMillis))ms \(status.rawValue)")

        if consecutiveProcessingFailures >= 3 {
            LLog("liveblend: three consecutive processing failures, stopping")
            requestStop(discard: false, reason: "consecutiveProcessingFailures")
        }
    }

    /// Appends this window's contribution to the shoot's issue trail —
    /// thermal state changes (recorded once per transition), gate rejections,
    /// and gate re-anchors. blendQueue.
    private func recordIssues(for entry: LiveBlendSessionLog.OutputEntry, record: WindowRecord) {
        func thermalSeverity(_ name: String) -> String {
            switch name {
            case "critical": return "problem"
            case "serious": return "warning"
            default: return "info"
            }
        }
        let thermalNow = entry.thermalStateAtStart ?? entry.thermalState
        if issuedThermalState == nil {
            // Starting hot is itself the finding — the Praha run opened at
            // critical, which is when lens excursions were observed.
            if thermalNow == "serious" || thermalNow == "critical" {
                sessionIssues.append(.init(
                    at: Date(), windowIndex: entry.index,
                    kind: "thermal", severity: thermalSeverity(thermalNow),
                    detail: "run started at \(thermalNow)"))
            }
            issuedThermalState = thermalNow
        } else if let previous = issuedThermalState, previous != thermalNow {
            sessionIssues.append(.init(
                at: Date(), windowIndex: entry.index,
                kind: "thermal", severity: thermalSeverity(thermalNow),
                detail: "\(previous) → \(thermalNow)"))
            issuedThermalState = thermalNow
        }

        if record.rejectedByAlignment > 0 {
            let peak = record.peakAlignmentShiftPixels ?? 0
            let kept = record.frameTarget == 1
            sessionIssues.append(.init(
                at: Date(), windowIndex: entry.index,
                kind: "framingGlitch", severity: "warning",
                detail: kept
                    ? String(format: "displaced frame kept (single-frame window), shift %.0f px", peak)
                    : String(format: "rejected %d of %d frames, peak shift %.0f px",
                             record.rejectedByAlignment,
                             record.rejectedByAlignment + record.frameTimes.count, peak)))
        }
        if record.alignmentReanchored {
            sessionIssues.append(.init(
                at: Date(), windowIndex: entry.index,
                kind: "framingChanged", severity: "warning",
                detail: "framing moved and stayed — new baseline adopted"))
        }
    }

    /// Records an issue observed outside this controller (the camera layer:
    /// a constituent hand-off, a session interruption). Safe from any queue.
    func noteExternalIssue(kind: String, severity: String, detail: String? = nil) {
        blendQueue.async {
            self.sessionIssues.append(.init(
                at: Date(), windowIndex: self.outputIndex,
                kind: kind, severity: severity, detail: detail))
        }
    }

    private func status(after entry: LiveBlendSessionLog.OutputEntry) -> LiveBlendStatus {
        if entry.failed { return .captureFailed }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return .thermalPressure
        default: break
        }
        if entry.droppedProcessingBehind > 0 { return .processingBehind }
        if entry.missedRateLimited > 0 { return .cameraRateLimited }
        if entry.requestedFrames > 0, entry.capturedFrames < entry.requestedFrames { return .reducedFrameCount }
        return .healthy
    }

    /// Final block of every run. Marks the controller inactive *before* the
    /// callback: the capture screen's finish handler calls `camera.stop()`,
    /// whose teardown must see an already-finished run and leave the temp
    /// frames alone until `setSource` has copied them.
    private func finishOnBlendQueue(discard: Bool) {
        blender.discardWindow()
        log.summary = LiveBlendSessionLog.Summary(
            endedAt: Date(),
            captureDurationSeconds: ProcessInfo.processInfo.systemUptime - startUptime,
            requestedOutputs: log.outputs.count,
            completedOutputs: completedOutputs,
            fallbackOutputs: fallbackOutputs,
            failedOutputs: failedOutputs,
            skippedWindows: skippedWindows,
            peakProcessingSeconds: peakProcessingSeconds,
            peakMemoryFootprintBytes: peakMemoryFootprint,
            finalThermalState: LiveBlendController.thermalStateName(),
            discarded: discard)
        rewriteLog()
        // Release the sidecar's handle before the discard branch below can
        // delete the directory out from under it.
        timestampWriter?.close()

        let result: LiveBlendCaptureResult?
        if discard || frameURLs.isEmpty {
            try? FileManager.default.removeItem(at: configuration.outputDirectory)
            result = nil
        } else {
            // The session's exposure record, written into the staging
            // directory so project registration carries it into `source/`
            // under its own name. No per-capture sidecar on this path: its
            // frames are samples off the preview stream, and a sampled frame
            // has no exposure of its own to record.
            let session = CaptureExposureLog.Session(
                sessionID: configuration.sessionID,
                deviceModel: configuration.deviceModel,
                // "dynamic" when the Holy Grail ramp drove the run — only a
                // ramped run is handed a commanded exposure. The old
                // hardcoded "interval" made the 2026-08-23 A/B pair
                // indistinguishable from unramped shoots in their own logs.
                captureMode: configuration.rampExposure != nil ? "dynamic" : "interval",
                blendMode: configuration.blendDepth.token,
                // Zone genuinely is what this path's Auto runs (`zoneBlend`);
                // the strategy picker only reaches the DNG pipeline today.
                algorithm: configuration.blendDepth == .auto
                    ? BlendStrategyID.zone.rawValue : nil,
                algorithmVersion: configuration.blendDepth == .auto
                    ? BlendStrategyID.version : nil,
                captureFlat: configuration.captureFlat,
                cameraName: configuration.cameraName,
                captureWidth: configuration.captureWidth,
                captureHeight: configuration.captureHeight,
                intervalSeconds: log.header.requestedIntervalSeconds,
                // End-of-run accounting the DNG path has always carried and
                // this path silently omitted — failed and starved windows
                // write no frame entries, so without these the travelling
                // log cannot show a shortfall at all.
                endReason: endReason ?? "user",
                failedWindows: failedOutputs > 0 ? failedOutputs : nil,
                starvedWindows: emptyWindows > 0 ? emptyWindows : nil,
                startedAt: runStartedAt,
                endedAt: Date(),
                frames: sessionFrameLog,
                issues: sessionIssues.isEmpty ? nil : sessionIssues)
            if CaptureExposureLog.write(
                session, toDirectory: configuration.outputDirectory) == nil {
                LLog("liveblend: could not write \(CaptureExposureLog.sessionFileName)")
            }
            result = LiveBlendCaptureResult(
                frameURLs: frameURLs,
                logURL: configuration.logURL,
                completedOutputs: completedOutputs,
                fallbackOutputs: fallbackOutputs,
                failedOutputs: failedOutputs)
        }
        if frameURLs.isEmpty, !discard {
            pushDiagnostics { $0.status = .captureFailed }
        }
        active.withLock { $0 = false }
        LLog("liveblend: finished outputs=\(frameURLs.count) discarded=\(discard) log=\(configuration.logURL.path)")
        DispatchQueue.main.async { self.onFinished?(result) }
    }

    private func rewriteLog() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(log)
            try data.write(to: configuration.logURL, options: .atomic)
        } catch {
            if !loggedLogWriteFailure {
                loggedLogWriteFailure = true
                LLog("liveblend: could not write experiment log: \(error)")
            }
        }
    }

    private func pushDiagnostics(_ mutate: @escaping (inout LiveBlendDiagnosticsSnapshot) -> Void) {
        let snapshot = diagnostics.withLock { value in
            mutate(&value)
            return value
        }
        DispatchQueue.main.async { self.onDiagnostics?(snapshot) }
    }

    // MARK: Machine info helpers

    /// "Mac16,6" on macOS, "iPhone17,1"-style on iOS (hw.model on iOS is the
    /// internal board name, so each platform reads its meaningful key).
    static func deviceModelIdentifier() -> String {
        #if os(macOS)
        let key = "hw.model"
        #else
        let key = "hw.machine"
        #endif
        var size = 0
        sysctlbyname(key, nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname(key, &value, &size, nil, 0)
        return String(cString: value)
    }

    static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static func thermalStateName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// EXIF + TIFF for one blended output — the record a camera-written file
    /// carries and a tapped-frame blend otherwise never gets. Exposure fields
    /// come from the window-open reading (`WindowRecord.exposure`); during a
    /// Holy Grail run those are the ramp's commanded values, which is the
    /// honest answer to "what was this frame shot at".
    static func captureMetadata(
        exposure: DNGAuthor.DNGExposure?, deviceModel: String
    ) -> [CFString: Any] {
        var metadata: [CFString: Any] = [:]
        var exif: [CFString: Any] = [:]
        if let exposure {
            if let iso = exposure.iso, iso > 0 {
                exif[kCGImagePropertyExifISOSpeedRatings] = [Int(iso.rounded())]
            }
            if let duration = exposure.exposureDuration, duration > 0 {
                exif[kCGImagePropertyExifExposureTime] = duration
            }
            if let aperture = exposure.aperture, aperture > 0 {
                exif[kCGImagePropertyExifFNumber] = aperture
            }
            if let brightness = exposure.brightness {
                exif[kCGImagePropertyExifBrightnessValue] = brightness
            }
            if let capturedAt = exposure.capturedAt {
                exif[kCGImagePropertyExifDateTimeOriginal] =
                    Self.exifDateFormatter.string(from: capturedAt)
                let subseconds = Int(
                    capturedAt.timeIntervalSince1970
                        .truncatingRemainder(dividingBy: 1) * 1000)
                exif[kCGImagePropertyExifSubsecTimeOriginal] = String(format: "%03d", subseconds)
                exif[kCGImagePropertyExifOffsetTimeOriginal] = Self.exifOffset(for: capturedAt)
            }
        }
        if !exif.isEmpty { metadata[kCGImagePropertyExifDictionary] = exif }
        if !deviceModel.isEmpty {
            // The TIFF camera identity `ImageExporter.carryoverMetadata`
            // preserves on derived images elsewhere in the app.
            metadata[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake: "Apple",
                kCGImagePropertyTIFFModel: deviceModel,
            ]
        }
        return metadata
    }

    /// EXIF datetimes are local time with no zone of their own —
    /// `OffsetTimeOriginal` carries the zone. blendQueue-confined
    /// (DateFormatter is not thread-safe).
    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static func exifOffset(for date: Date) -> String {
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        return String(format: "%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
    }

    /// Resident footprint (the number Activity Monitor's "Memory" shows),
    /// nil when the kernel call fails.
    static func memoryFootprintBytes() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint)
    }
}
