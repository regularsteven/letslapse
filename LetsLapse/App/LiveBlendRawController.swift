import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import CoreImage
import Accelerate
import ImageIO
import os
import LetsLapseKit

// RAW photo capture APIs (AVCapturePhotoSettings(rawPixelFormatType:),
// AVCapturePhoto.isRawPhoto) are marked unavailable on macOS, so this whole
// path is iOS-family only — the compiler, not policy, draws that line.
#if os(iOS)

/// Live Blend's DNG path. Instead of tapping the processed (white-balanced,
/// tone-mapped) video stream, it schedules Bayer RAW photo captures across
/// each interval, averages the sensor mosaics, and writes one blended DNG
/// per interval whose tags come from that window's own reference capture —
/// so white balance and colour stay decisions for post, not for capture.
///
/// RAW captures are slow (roughly one per second), which suits the long
/// intervals holy-grail work uses. Every shortfall is measured and logged,
/// never hidden. All state is confined to one serial `workQueue`; the actual
/// `capturePhoto` calls hop through `captureExecutor` onto the session queue.
final class LiveBlendRawController: NSObject, AVCapturePhotoCaptureDelegate {
    struct Configuration {
        var intervalSeconds: Double
        var blendDepth: BlendDepth
        var outputDirectory: URL
        var logURL: URL
        var cameraName: String
        var captureWidth: Int
        var captureHeight: Int
        var configuredFrameRate: Int
        var rawPixelFormat: OSType
        /// Capture experiments (Settings toggles; see LiveBlendCaptureOptions).
        var burstScheduling: Bool
        var bracketedRAW: Bool
        /// Whether CameraController actually enabled the responsive-capture
        /// pipeline on the output (support- and toggle-dependent).
        var responsiveCapture: Bool
        /// The output's bracket ceiling under the run's configuration.
        var maxBracketFrames: Int
        /// Safe mode's frame target, consulted once at each window open;
        /// nil for the other depths.
        var throttledFrameTarget: (() -> Int)? = nil
        /// Auto's device ceiling, re-read at each window open so a re-profile
        /// after a thermal change takes effect from the next window.
        var capabilityProfile: (() -> DeviceCapabilityProfile?)? = nil
        /// Auto's scene reading: what the camera's AE has settled on right
        /// now, from the live device rather than from a captured frame — the
        /// count has to be chosen *before* the window's first capture.
        var sceneExposure: (() -> DNGAuthor.DNGExposure?)? = nil
        /// Which field-test strategy actuates Auto's count. Whatever it is,
        /// every cycle resolves and logs all three (see `BlendStrategyBank`).
        var blendStrategy: BlendStrategyID = .zone
        /// Holy Grail only: the ramp's most recently APPLIED (clamped)
        /// exposure. Brackets must build per-shot manual settings from it —
        /// auto-exposure bracket settings override the device's custom
        /// exposure and resolve against an AE loop that `.custom` mode has
        /// frozen, which is how the 2026-08-20 field test shot two 50-minute
        /// runs at the pre-lock exposure while the ramp commanded a perfect
        /// sunset walk. Also the reference for the delivered-exposure
        /// honesty guard. nil on plain runs (brackets stay auto there — a
        /// live AE is exactly what they should follow).
        var rampExposure: (() -> (duration: CMTime, iso: Float)?)? = nil
        /// Identity and vocabulary for `capture_log.json`.
        var sessionID: String = UUID().uuidString
        var deviceModel: String = ""
        /// Geotag source: returns the current fix (or nil when GPS tagging is
        /// off / no fix). Read once per window on the processing queue and
        /// baked into every DNG that window writes. Primitives, not a
        /// CLLocation, so the value can cross into the Kit's DNG authoring.
        var gpsProvider: (() -> (latitude: Double, longitude: Double, altitude: Double, timestamp: Date)?)? = nil
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

    /// An unthrottled window buffers whole DNGs in memory until it closes,
    /// so "as many frames as the device can manage" includes what fits: the
    /// window stops capturing at this byte budget (48MP ProRAW runs
    /// ~50–75 MB a frame, 12MP ~15–25 MB) and the cap is logged, never
    /// hidden. The frame ceiling is a sanity bound for tiny formats.
    private static let unthrottledWindowByteBudget = 600 << 20
    private static let unthrottledFrameCeiling = 120

    /// `var`, not `let`, for exactly one reason: EVERY=Auto. A Holy Grail run
    /// on Auto re-paces itself as the light dies (see `HolyGrailAutoInterval`),
    /// and `intervalSeconds` is where that lands. Everything else in here is
    /// still fixed for the run — only `setIntervalSeconds` below writes it, and
    /// only on `workQueue`, where every reader already lives.
    private var configuration: Configuration
    private let photoOutput: AVCapturePhotoOutput
    private let captureExecutor: (@escaping () -> Void) -> Void
    private let workQueue = DispatchQueue(label: "com.letslapse.liveblend.raw", qos: .userInitiated)

    /// Blending happens in scene-linear working space through Apple's own
    /// RAW decoder — the Bayer pixel buffer's undocumented preprocessing
    /// (levels, per-channel gains, shading state) made sensor-mosaic
    /// averaging uncalibratable; see the DNG spec brief's Option A.
    private static let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var ciContext = CIContext(options: [
        .workingColorSpace: LiveBlendRawController.linearColorSpace,
        .workingFormat: CIFormat.RGBAh.rawValue,
        .cacheIntermediates: false,
    ])
    /// 2 stops of highlight headroom in the stored values, declared back to
    /// decoders via BaselineExposure.
    private static let headroomStops = 2

    /// Both fired on the main queue.
    var onDiagnostics: ((LiveBlendDiagnosticsSnapshot) -> Void)?

    /// Fired as each interval window opens, on this controller's own queue,
    /// with the window's index and the scene brightness the last window's
    /// frames reported (EXIF APEX `BrightnessValue`, nil if none carried it).
    /// See the twin in `LiveBlendController` for why the ramp must be fed
    /// something the ramp's own exposure choice cannot influence — here that
    /// is the metered scene brightness rather than sampled luma, since these
    /// frames are Bayer RAW and carry a meter reading of their own.
    var onWindowOpened: ((Int, Double?) -> Void)?

    /// Scene brightness reported by this window's frames. workQueue.
    private var windowBrightnessSum: Double = 0
    private var windowBrightnessCount = 0
    var onFinished: ((LiveBlendCaptureResult?) -> Void)?
    /// Fired on the work queue for each completed unthrottled window — what
    /// the learning profiles are built from.
    var onLearningSample: ((ThermalBucket, BlendLearningSample) -> Void)?

    private let active = OSAllocatedUnfairLock(initialState: true)
    private let diagnostics: OSAllocatedUnfairLock<LiveBlendDiagnosticsSnapshot>
    var isActive: Bool { active.withLock { $0 } }

    // workQueue-confined run state.
    private var selecting = false
    private var finishRequested = false
    private var timer: DispatchSourceTimer?
    private var startUptime: Double = 0
    private var windowIndex = 0
    private var windowStartUptime: Double = 0
    private var shotsRequestedThisWindow = 0
    private var inFlightCaptures = 0
    private var windowFrameTimes: [Double] = []
    private var windowMissed = 0
    private var windowFailures = 0
    private var windowPartial = false
    private var windowFrameDNGs: [Data] = []
    /// What each of this window's frames was exposed at, in capture order. The
    /// first one describes the blend: a window is one AE decision, and it is
    /// the only frame whose tags can honestly stand for the output.
    private var windowFrameExposures: [DNGAuthor.DNGExposure] = []
    /// Auto's three field-test strategies, resolved together every window;
    /// `configuration.blendStrategy` names the one that actuates.
    private var strategyBank = BlendStrategyBank()
    /// Damps the actuated count so boundary conditions can't alternate it
    /// window to window — the 2026-08-21 flicker source. workQueue.
    private var countDamper = BlendCountDamper()
    /// The newest committed luminance analysis — Lumen's input. At least
    /// one window old, often two: the count for window N+1 is resolved at
    /// N's close, before N's processing lands, so it sees N−1's stats. The
    /// stats' own iso/shutter/ev say which window they came from, and the
    /// strategies only act once per distinct measurement. workQueue.
    private var lastWindowStats: FrameLuminanceStats?
    /// The decision behind the currently open window, attached to its
    /// output's log entry when the window commits — and held verbatim
    /// through meter dropouts and catch-up closes. workQueue.
    private var windowDecision: BlendStrategyDecision?
    /// When the bank last genuinely resolved. Catch-up closes (tick() can
    /// close three stalled windows in one pass) reuse the standing decision
    /// instead of re-feeding one EV reading into every strategy's history.
    private var lastStrategyResolveUptime: Double = -.infinity
    /// Every capture this run has landed, for the per-capture sidecar.
    private var captureIndex = 0
    private var exposureWriter: CaptureExposureWriter?
    /// The `frames.timestamps` twin of the exposure sidecar — appended beside
    /// each written OUTPUT file (poses of the finished sequence, not raw
    /// captures), so the project's time axis lands live. workQueue.
    private var timestampWriter: FrameTimestampWriter?
    /// One entry per written output frame, for `capture_log.json`.
    private var sessionFrameLog: [CaptureExposureLog.Entry] = []
    private var runStartedAt = Date()
    /// Resolved at window open; nil = unthrottled (fire until the window
    /// closes or the byte budget fills).
    private var windowFrameTarget: Int?
    private var windowThermalAtStart = "unknown"
    private var windowFrameBytes = 0
    private var windowMemoryCapped = false
    private var readinessObservation: NSKeyValueObservation?
    /// Set after a bracket request fails so the run degrades to singles
    /// instead of sinking every window on a rejected settings shape.
    private var bracketDisabled = false
    /// Ramped runs: the window's worst commanded-vs-delivered exposure
    /// divergence in stops, and the last magnitude the loud log reported
    /// (so 700 diverging frames make a handful of lines, not a flood).
    /// workQueue.
    private var windowExposureDivergenceMax: Double = 0
    private var lastDivergenceLogged: Double = 0
    /// One "the ramp commanded nothing" report per session — the condition is a
    /// property of the run, not of a frame.
    private var issuedRampSilence = false
    /// Windows handed to `processingQueue` whose commit hasn't landed yet.
    /// Backpressure: ≥2 pauses new captures so frame Data can't pile up.
    private var pendingProcessingWindows = 0
    /// Whether the CURRENT window has had captures withheld by that gate.
    /// An empty window that closes with this set is the scheduler's own
    /// restraint, not a camera fault — the 2026-08-22 sunrise killed five
    /// 12 Pro runs by counting exactly those windows as "failures" until
    /// three in a row tripped the stop guard. workQueue.
    private var windowSawBackpressure = false
    /// Windows skipped to backpressure this run (no output, not failures).
    private var skippedStarvedWindows = 0
    /// AIMD governor over frames-per-window, fed by whole-window processing
    /// cost — the throughput signal the capability probe cannot measure (it
    /// times capture+write, never blend+author). A device that blends
    /// slower than the interval degrades to fewer frames instead of
    /// drowning; see `ProcessingCeiling` for why this is AIMD and not a
    /// per-frame model. workQueue.
    private var processingCeiling = ProcessingCeiling()
    /// The governor's pacing floor, published for `CameraController`'s
    /// EVERY=Auto repace (read on the session queue, hence the lock).
    private let paceFloor = OSAllocatedUnfairLock<Double?>(initialState: nil)
    /// Seconds the processing pipeline demonstrably needs per window; nil
    /// while frame-count reduction still covers it.
    var processingPaceFloorSeconds: Double? { paceFloor.withLock { $0 } }
    /// Why the run ended, for `capture_log.json` — "user" unless a guard
    /// says otherwise. The stop reason used to exist only in print-level
    /// logs, invisible on a field device. workQueue.
    private var endReason = "user"

    /// Blend/author work runs here so capture scheduling never stalls
    /// behind it — the next window's burst fires while the previous window
    /// renders. Serial, so outputs stay ordered.
    private let processingQueue = DispatchQueue(label: "com.letslapse.liveblend.raw.process", qos: .userInitiated)
    /// processingQueue-confined; names stay contiguous because only actual
    /// writes consume an index.
    private var processingFileIndex = 0
    private let discardRequested = OSAllocatedUnfairLock(initialState: false)

    // workQueue-confined output state.
    private var log: LiveBlendSessionLog
    private var frameURLs: [URL] = []
    private var completedOutputs = 0
    private var fallbackOutputs = 0
    private var failedOutputs = 0
    private var consecutiveProcessingFailures = 0
    private var lastCompletionUptime: Double?
    private var peakProcessingSeconds = 0.0
    private var peakMemoryFootprint: Int?
    private var loggedLogWriteFailure = false

    init(
        configuration: Configuration,
        photoOutput: AVCapturePhotoOutput,
        captureExecutor: @escaping (@escaping () -> Void) -> Void
    ) {
        self.configuration = configuration
        self.photoOutput = photoOutput
        self.captureExecutor = captureExecutor
        var initialSnapshot = LiveBlendDiagnosticsSnapshot(
            requestedIntervalSeconds: configuration.intervalSeconds,
            requestedFramesPerBlend: configuration.initialDisplayFrames)
        initialSnapshot.outputFormatLabel = "DNG"
        self.diagnostics = OSAllocatedUnfairLock(initialState: initialSnapshot)
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
            requestedOutputFormat: "dng",
            outputFormat: "dng",
            responsiveCapture: configuration.responsiveCapture,
            burstScheduling: configuration.burstScheduling,
            bracketedRAW: configuration.bracketedRAW,
            bracketMaxFrames: configuration.maxBracketFrames))
        super.init()
    }

    // MARK: Run control

    func start() {
        workQueue.async {
            self.selecting = true
            self.startUptime = ProcessInfo.processInfo.systemUptime
            self.windowStartUptime = self.startUptime
            self.runStartedAt = Date()
            self.exposureWriter = CaptureExposureWriter(
                directory: self.configuration.outputDirectory)
            self.timestampWriter = self.configuration.writesFrameTimestamps
                ? FrameTimestampWriter(directory: self.configuration.outputDirectory)
                : nil
            self.openWindowState()
            LLog("liveblend-dng: start interval=\(self.configuration.intervalSeconds)s depth=\(self.configuration.blendDepth.token) raw=\(self.configuration.rawPixelFormat) log=\(self.configuration.logURL.path)")
            self.rewriteLog()

            // Spread mode paces shots across the interval; burst mode fires
            // them back-to-back, so its timer only closes windows and
            // heartbeats the pump — a short fixed period keeps closes tight.
            let spacing: Double
            if self.usesBurst {
                spacing = 0.25
            } else {
                spacing = max(0.35, self.configuration.intervalSeconds / Double(self.configuration.blendDepth.fixedFrames ?? 1))
            }
            let timer = DispatchSource.makeTimerSource(queue: self.workQueue)
            timer.schedule(deadline: .now() + 0.05, repeating: spacing)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer

            // The output's readiness transitions are the burst pacing signal
            // (fastest shot-to-shot without over-queuing, per AVFoundation).
            if self.usesBurst, !self.configuration.bracketedRAW, #available(iOS 17.0, *) {
                self.readinessObservation = self.photoOutput.observe(\.captureReadiness) { [weak self] _, _ in
                    self?.workQueue.async { self?.pumpCaptures() }
                }
            }
        }
    }

    /// Re-paces a running shoot — the EVERY=Auto path, and nothing else calls
    /// it. Applied from the *next* window onward: `windowStartUptime` already
    /// anchors the window in flight, so the change never truncates a window
    /// that is mid-capture. The value is clamped to something a shoot can
    /// actually run at rather than trusted blindly.
    func setIntervalSeconds(_ seconds: Double) {
        workQueue.async {
            let next = min(max(seconds, 0.5), 600)
            guard self.configuration.intervalSeconds != next else { return }
            LLog("liveblend-dng: re-paced \(self.configuration.intervalSeconds)s → \(next)s")
            self.configuration.intervalSeconds = next
        }
    }

    func requestStop(discard: Bool, keepPartial: Bool = true) {
        workQueue.async {
            guard !self.finishRequested else { return }
            self.finishRequested = true
            self.selecting = false
            self.timer?.cancel()
            self.timer = nil
            self.readinessObservation?.invalidate()
            self.readinessObservation = nil
            if discard {
                self.discardRequested.withLock { $0 = true }
            }
            if !discard, keepPartial, !self.windowFrameDNGs.isEmpty {
                self.windowPartial = true
                self.closeWindow()
            } else {
                self.windowFrameDNGs.removeAll()
            }
            // Drain before finishing: hop through the processing queue so
            // every queued window's commit (processing → workQueue, FIFO)
            // lands ahead of finishRun.
            self.processingQueue.async {
                self.workQueue.async { self.finishRun(discard: discard) }
            }
        }
    }

    /// Burst variants (including bracketed) replace spread pacing. The
    /// adaptive depths always burst: unthrottled by definition, throttled
    /// because its per-window target can't drive a fixed spread grid.
    private var usesBurst: Bool {
        configuration.burstScheduling || configuration.bracketedRAW
            || configuration.blendDepth.fixedFrames == nil
    }

    /// Opens a window: resolves its frame target (Safe mode re-evaluates
    /// per interval, here) and stamps the thermal state the learning system
    /// keys on. workQueue.
    private func openWindowState() {
        switch configuration.blendDepth {
        case .fixed(let frames): windowFrameTarget = frames
        case .unthrottled: windowFrameTarget = nil
        case .throttled: windowFrameTarget = max(1, configuration.throttledFrameTarget?() ?? 2)
        case .auto: windowFrameTarget = resolveAutoFrameTarget()
        }
        windowThermalAtStart = LiveBlendController.thermalStateName()
        if onWindowOpened != nil {
            let mean = windowBrightnessCount > 0
                ? windowBrightnessSum / Double(windowBrightnessCount) : nil
            windowBrightnessSum = 0
            windowBrightnessCount = 0
            onWindowOpened?(windowIndex, mean)
        }
        windowFrameBytes = 0
        windowMemoryCapped = false
        let target = windowFrameTarget
        pushDiagnostics {
            $0.currentWindowSelectedFrames = 0
            $0.requestedFramesPerBlend = target ?? 0
        }
    }

    /// Auto's per-window count: all three field-test strategies resolved
    /// from the live AE's EV (and, for Lumen, the last closed window's pixel
    /// stats), the configured one actuated, everything logged. workQueue.
    ///
    /// The EV is read from the live AE rather than from the previous window's
    /// frames because the count has to exist before the first capture of the
    /// window it governs. When the meter says nothing usable, each strategy
    /// holds its last count — a scene doesn't get brighter because a read
    /// failed.
    ///
    /// The device ceiling is recomputed here from the profile's measured
    /// frames-per-second against the interval the run is pacing at *now* —
    /// not the profile's stored ceiling, which was computed against the
    /// run-start interval and goes stale the moment EVERY=Auto re-paces.
    private func resolveAutoFrameTarget() -> Int {
        let now = ProcessInfo.processInfo.systemUptime
        // Catch-up closes reuse the standing decision: three windows closed
        // in one stalled tick are one moment of light, not three readings.
        if let held = windowDecision,
           now - lastStrategyResolveUptime < configuration.intervalSeconds * 0.5 {
            LLog("liveblend-dng: auto window \(windowIndex) — catch-up close, keeping \(held.actuatedCount) frames")
            return held.actuatedCount
        }
        let profile = configuration.capabilityProfile?()
        let scene = configuration.sceneExposure?()
        let captureCeiling = profile.map {
            DeviceCapabilityProfile.ceiling(
                framesPerSecond: $0.framesPerSecond,
                intervalSeconds: configuration.intervalSeconds,
                currentShutterSeconds: scene?.exposureDuration)
        }
        // The probe measures capture speed; blend+author speed it cannot
        // know. The AIMD governor tracks it live from whole-window costs —
        // the 12 Pro's sunrise runs died because processing utilization was
        // allowed to sit above 100%.
        // The governor idles at the band maximum, so with no capture profile
        // this is simply "never more than the table can ask for".
        let ceiling: Int? = min(
            captureCeiling ?? ZoneBlendStrategy.bands[0].frames,
            processingCeiling.ceiling)
        guard let ev = scene?.exposureValue else {
            // A scene doesn't get brighter because a read failed: hold the
            // last actuated count verbatim — not the strategies' uncapped
            // wants, which a freshly grown ceiling could inflate.
            if let held = windowDecision {
                LLog("liveblend-dng: auto window \(windowIndex) — no EV reading, holding \(held.actuatedCount) frames")
                return held.actuatedCount
            }
            let fallback = max(1, min(ZoneBlendStrategy.band(forEV: 10).frames, ceiling ?? Int.max))
            LLog("liveblend-dng: auto window \(windowIndex) — no EV reading on the first cycle, starting at \(fallback) frames")
            windowDecision = BlendStrategyDecision(
                algorithm: configuration.blendStrategy.rawValue,
                sceneEV: nil,
                proposedZone: fallback, proposedLatitude: fallback, proposedLumen: fallback,
                deviceCeiling: ceiling,
                intervalSeconds: configuration.intervalSeconds,
                actuatedCount: fallback)
            lastStrategyResolveUptime = now
            return fallback
        }
        let proposals = strategyBank.resolveAll(ev: ev, at: now, stats: lastWindowStats)
        lastStrategyResolveUptime = now
        let wanted: Int
        switch configuration.blendStrategy {
        case .zone: wanted = proposals.zone
        case .latitude: wanted = proposals.latitude
        case .lumen: wanted = proposals.lumen
        }
        let count = countDamper.damp(max(1, min(wanted, ceiling ?? wanted)))
        windowDecision = BlendStrategyDecision(
            algorithm: configuration.blendStrategy.rawValue,
            sceneEV: ev,
            proposedZone: proposals.zone,
            proposedLatitude: proposals.latitude,
            proposedLumen: proposals.lumen,
            zoneSmoothedEV: proposals.zoneSmoothedEV,
            latitudeContinuous: proposals.latitudeContinuous,
            evVelocityStopsPerMinute: proposals.evVelocityStopsPerMinute,
            lumenScore: proposals.lumenScore,
            lumenBoost: proposals.lumenBoost,
            deviceCeiling: ceiling,
            intervalSeconds: configuration.intervalSeconds,
            actuatedCount: count,
            stats: lastWindowStats)
        LLog("""
            liveblend-dng: auto window \(windowIndex) \
            [\(configuration.blendStrategy.rawValue)] — \
            EV \(String(format: "%.2f", ev)) \
            (smoothed \(proposals.zoneSmoothedEV.map { String(format: "%.2f", $0) } ?? "—"), \
            \(ZoneBlendStrategy.band(forEV: proposals.zoneSmoothedEV ?? ev).name)) → \(count) frames \
            (zone \(proposals.zone), latitude \(proposals.latitude), \
            lumen \(proposals.lumen)\
            \(proposals.lumenScore.map { String(format: " score %.3f", $0) } ?? "")\
            \(ceiling.map { ", ceiling \($0)" } ?? ""))
            """)
        return count
    }

    /// Brackets stay in play only while the device honours them.
    private var usesBrackets: Bool {
        configuration.bracketedRAW && configuration.maxBracketFrames >= 2 && !bracketDisabled
    }

    // MARK: Scheduling (workQueue)

    private func tick() {
        guard selecting else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var closes = 0
        while now >= windowStartUptime + configuration.intervalSeconds, closes < 3 {
            closeWindow()
            closes += 1
        }
        if now >= windowStartUptime + configuration.intervalSeconds {
            // Far behind (captures stalled): re-anchor rather than flooding
            // the log with empty windows.
            let interval = configuration.intervalSeconds
            let jumped = Int((now - windowStartUptime) / interval)
            windowStartUptime += Double(jumped) * interval
        }
        if usesBurst {
            pumpCaptures()
            return
        }
        // Processing runs off-queue now; if it falls behind, pause shots
        // instead of piling captured frames into memory.
        guard pendingProcessingWindows < 2 else {
            windowMissed += 1
            windowSawBackpressure = true
            return
        }
        // Spread mode keeps strictly one RAW capture at a time. Overlapping
        // RAW captures starved the session on iPhone 16 Pro when the output
        // wasn't configured for overlap (a hung second capture never
        // completes, the in-flight budget never frees, and every later
        // window closes empty), so serialization plus honest miss-counting
        // beats theoretical extra cadence. The burst path gets overlap the
        // supported way, through responsive capture + readiness.
        if inFlightCaptures > 0 {
            // Stall recovery: a capture that never reported back must not
            // wedge the whole run.
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCaptureFiredUptime > 5 {
                LLog("liveblend-dng: capture stalled >5s — resetting in-flight guard")
                inFlightCaptures = 0
            } else {
                windowMissed += 1
                return
            }
        }
        guard shotsRequestedThisWindow < (windowFrameTarget ?? Int.max) else { return }
        fireCapture()
    }

    /// Burst scheduling: fire the window's remaining shots back-to-back,
    /// gated by the output's readiness rather than a spacing grid. Dense
    /// samples are what turn spread ghost copies into a streak — same frame
    /// count, a fraction of the inter-frame displacement.
    private func pumpCaptures() {
        guard selecting, usesBurst else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if inFlightCaptures > 0, now - lastCaptureFiredUptime > 8 {
            LLog("liveblend-dng: capture stalled >8s — resetting in-flight guard")
            inFlightCaptures = 0
        }
        guard pendingProcessingWindows < 2 else {
            windowSawBackpressure = true
            return
        }
        // Unthrottled fires until the window closes; its bound is memory,
        // not a count. Failed captures free their slots for a replacement
        // shot, but never an unbounded retry loop inside one window.
        let ceiling = windowFrameTarget ?? Self.unthrottledFrameCeiling
        let shotBudget = ceiling * 2
        while shotsRequestedThisWindow < shotBudget {
            if windowFrameTarget == nil, windowFrameBytes >= Self.unthrottledWindowByteBudget {
                if !windowMemoryCapped {
                    windowMemoryCapped = true
                    LLog("liveblend-dng: window \(windowIndex) hit the memory budget at \(windowFrameDNGs.count) frames — capped")
                }
                return
            }
            let wanted = ceiling - windowFrameDNGs.count - inFlightCaptures
            guard wanted > 0 else { return }
            if usesBrackets {
                // One bracket in flight at a time; its frames arrive at
                // sensor-consecutive spacing. Ramped runs bracket too —
                // fireBracket carries the device's custom exposure via the
                // `current` constants — and a device that refuses a bracket
                // shape at runtime degrades through bracketDisabled to
                // singles, which inherit the custom exposure as well.
                guard inFlightCaptures == 0 else { return }
                let count = min(wanted, configuration.maxBracketFrames)
                if count >= 2 {
                    fireBracket(count)
                } else {
                    fireCapture()
                }
            } else if #available(iOS 17.0, *), configuration.responsiveCapture {
                guard photoOutput.captureReadiness == .ready, inFlightCaptures < 3 else { return }
                fireCapture()
            } else {
                // Serialized singles. Also the landing path after
                // bracketDisabled trips on a bracketed run: that pipeline
                // never enabled responsive capture, so readiness can stay
                // un-ready forever — gating on it here starved the 16 Pro's
                // sunrise run to death after its brackets were refused.
                guard inFlightCaptures == 0 else { return }
                fireCapture()
            }
        }
    }

    private var lastCaptureFiredUptime: Double = 0

    private func fireCapture() {
        inFlightCaptures += 1
        lastCaptureFiredUptime = ProcessInfo.processInfo.systemUptime
        shotsRequestedThisWindow += 1
        let format = configuration.rawPixelFormat
        captureExecutor { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings(rawPixelFormatType: format)
            // Speed over per-shot polish: blending supplies the noise
            // reduction, and slow captures are what starve short windows.
            settings.photoQualityPrioritization = .speed
            settings.suppressShutterSound(for: self.photoOutput)
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    /// One bracket request for `count` RAW frames — consecutive sensor
    /// frames, the closest a third-party app gets to video-rate RAW. Counts
    /// as one in-flight request; each frame still arrives through
    /// `didFinishProcessingPhoto`.
    private func fireBracket(_ count: Int) {
        inFlightCaptures += 1
        lastCaptureFiredUptime = ProcessInfo.processInfo.systemUptime
        shotsRequestedThisWindow += count
        let format = configuration.rawPixelFormat
        // Snapshot on workQueue; the closure itself is lock-protected and
        // safe to call from the session queue below.
        let rampExposure = configuration.rampExposure
        captureExecutor { [weak self] in
            guard let self else { return }
            let perFrame: [AVCaptureBracketedStillImageSettings]
            if let target = rampExposure?() {
                // Ramped run: the bracket carries the ramp's OWN values.
                //
                // It used to pass `AVCaptureDevice.currentExposureDuration` /
                // `currentISO`, on the reasoning that the sentinels resolve on
                // the device at capture time and so cannot go stale. On iPad
                // they do not resolve to the device's custom exposure at all.
                // Measured 2026-08-22 on an iPad Air M3 and M1: every
                // bracketed frame came back at the run's SEED exposure for a
                // whole 15-minute shoot while the ramp commanded a 1.6-stop
                // walk, and the same device on the singles path (blend 1,
                // `fireCapture`, no bracket settings) tracked the ramp across
                // 13 delivered values. Both iPhones happened to mask it.
                //
                // Staleness — the reason the sentinels were chosen — is
                // handled at the source instead: `rampExposure` re-clamps to
                // the device's live `activeFormat` on every call, so what
                // arrives here is in range for the format that is actually
                // mounted. That matters because an out-of-range manual
                // bracket raises an uncatchable NSException.
                perFrame = (0..<count).map { _ in
                    AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                        exposureDuration: target.duration,
                        iso: target.iso)
                }
            } else {
                // Plain run: AE is live and the brackets should follow it.
                perFrame = (0..<count).map { _ in
                    AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(
                        exposureTargetBias: AVCaptureDevice.currentExposureTargetBias)
                }
            }
            // Quality prioritization is deliberately left default here —
            // bracket settings reject some per-shot options that plain
            // settings accept.
            let settings = AVCapturePhotoBracketSettings(
                rawPixelFormatType: format,
                processedFormat: nil,
                bracketedSettings: perFrame)
            settings.suppressShutterSound(for: self.photoOutput)
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: Capture delegate (hops to workQueue)

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        workQueue.async {
            autoreleasepool {
                if let error {
                    self.windowFailures += 1
                    LLog("liveblend-dng: capture error: \(error.localizedDescription)")
                    return
                }
                if photo.isRawPhoto {
                    // The camera's own account of this frame: ISO, shutter,
                    // f-number and metered brightness. It is read here, at the
                    // one moment it exists — an authored blend is built from
                    // decoded samples and carries nothing of the capture unless
                    // it is taken from the photo object first.
                    let exposure = DNGAuthor.DNGExposure(
                        photoMetadata: photo.metadata, capturedAt: Date())
                    // Scene brightness for the Holy Grail ramp, straight off
                    // the meter. Scene-referred by construction: it describes
                    // the light, not the exposure we chose to record it with.
                    if self.onWindowOpened != nil, let brightness = exposure.brightness {
                        self.windowBrightnessSum += brightness
                        self.windowBrightnessCount += 1
                    }
                    self.handleRawPhoto(photo, exposure: exposure)
                }
            }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        workQueue.async {
            self.inFlightCaptures = max(0, self.inFlightCaptures - 1)
            if error != nil, self.usesBrackets {
                // A rejected bracket request must not sink every window —
                // degrade to single captures for the rest of the run.
                self.bracketDisabled = true
                LLog("liveblend-dng: bracket capture failed — single captures from here on")
            }
            self.pumpCaptures()
        }
    }

    private var loggedBufferAttachments = false

    private func handleRawPhoto(_ photo: AVCapturePhoto, exposure: DNGAuthor.DNGExposure) {
        guard selecting else { return }
        guard let pixelBuffer = photo.pixelBuffer else {
            windowFailures += 1
            LLog("liveblend-dng: raw photo without pixel buffer")
            return
        }
        // Commanded-vs-delivered honesty guard: on a ramped run, every
        // frame's own EXIF is compared against what the ramp applied. A
        // divergence is the actuation chain failing — the class of bug that
        // silently cost the 2026-08-20 field test two sunset runs — so it is
        // logged loudly and stamped into the window's capture_log record.
        //
        // A nil target on a ramped run is the extreme of the same failure: the
        // ramp commanded nothing, the brackets fell back to AE, and until this
        // branch existed that case skipped the comparison entirely and read as
        // a clean run.
        let rampTarget = configuration.rampExposure?()
        if configuration.rampExposure != nil, rampTarget == nil, !issuedRampSilence {
            issuedRampSilence = true
            LLog("liveblend-dng: RAMP NOT DRIVING — no commanded exposure; this run is "
                 + "AE-exposed and bracketed off AE, and the ramp readout is advisory")
        }
        if let target = rampTarget,
           let iso = exposure.iso, let duration = exposure.exposureDuration,
           let divergence = CaptureExposureLog.WindowPerformance.exposureDivergenceStops(
               actualISO: iso, actualDuration: duration,
               targetISO: Double(target.iso), targetDuration: target.duration.seconds) {
            // Devices quantize the commanded ISO to a neighbouring supported
            // value and EXIF reports the quantized one (measured: commanded
            // 33 → EXIF 32, 54 → 50, 18 → 16), a constant ≤⅙-stop offset.
            // Below a ¼ stop nothing is wrong — don't stamp the log.
            if divergence > 0.25 {
                windowExposureDivergenceMax = max(windowExposureDivergenceMax, divergence)
            }
            if divergence <= 0.5 {
                // Recovered: re-arm the limiter so a recurrence at the same
                // magnitude logs loudly again instead of staying silent.
                lastDivergenceLogged = 0
            }
            if divergence > 0.5, abs(divergence - lastDivergenceLogged) > 0.5 {
                lastDivergenceLogged = divergence
                LLog(String(format: """
                    liveblend-dng: EXPOSURE DIVERGENCE %.1f stops — ramp \
                    commanded %.4fs ISO %.0f, sensor delivered %.4fs ISO %.0f
                    """, divergence, target.duration.seconds, Double(target.iso),
                    duration, iso))
            }
        }
        if !loggedBufferAttachments {
            loggedBufferAttachments = true
            let attachments = (CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) as? [String: Any]) ?? [:]
            // Phase-2 intel for the sensor-native Bayer path.
            LLog("liveblend-dng: buffer attachment keys: \(attachments.keys.sorted())")
            for (key, value) in attachments
            where key.localizedCaseInsensitiveContains("level") || key.localizedCaseInsensitiveContains("black") || key.localizedCaseInsensitiveContains("white") {
                LLog("liveblend-dng: attachment \(key) = \(value)")
            }
        }
        // For a RAW capture, fileDataRepresentation() yields Apple's DNG —
        // the input the linear blend decodes with Apple's own calibration.
        guard let dngData = photo.fileDataRepresentation() else {
            windowFailures += 1
            LLog("liveblend-dng: raw photo without DNG representation")
            return
        }
        windowFrameDNGs.append(dngData)
        windowFrameExposures.append(exposure)
        windowFrameBytes += dngData.count
        windowFrameTimes.append(ProcessInfo.processInfo.systemUptime - startUptime)
        // One NDJSON line per capture, flushed now: a shoot killed mid-run
        // keeps every finished line, and the file describes what the camera
        // did rather than what was eventually written out.
        exposureWriter?.append(CaptureExposureLog.Entry(
            frameIndex: captureIndex, exposure: exposure))
        captureIndex += 1
        let selected = windowFrameDNGs.count
        pushDiagnostics { $0.currentWindowSelectedFrames = selected }
        pumpCaptures()
    }

    // MARK: Window close + DNG output (workQueue)

    /// Snapshots the window's stats, resets window state so the next burst
    /// can fire immediately, and hands the heavy blend/author work to
    /// `processingQueue`; `commitOutput` lands the result back here.
    private func closeWindow() {
        let frames = windowFrameDNGs
        // The window's own AE decision — the first frame's, because the
        // remaining ones are the same exposure repeated (and on a ramping shoot
        // the first is the one the window was opened on).
        let exposure = windowFrameExposures.first ?? DNGAuthor.DNGExposure()
        // The strategy decision that opened THIS window, snapshotted before
        // openWindowState() below resolves the next one over it — and the
        // stats gate read here on workQueue, so the processing closure never
        // touches `configuration` fields the interval re-pace can rewrite.
        let decision = windowDecision
        let wantsStats = configuration.blendDepth == .auto
        // Snapshot before the reset below: whether this window's emptiness
        // (if it is empty) was the backpressure gate's own doing.
        let sawBackpressure = windowSawBackpressure
        let times = windowFrameTimes
        let spacings = zip(times.dropFirst(), times).map(-)
        var entry = LiveBlendSessionLog.OutputEntry(
            index: windowIndex,
            windowStartSeconds: windowStartUptime - startUptime,
            windowEndSeconds: windowStartUptime - startUptime + configuration.intervalSeconds,
            requestedIntervalSeconds: configuration.intervalSeconds,
            requestedFrames: windowFrameTarget ?? 0,
            capturedFrames: frames.count,
            missedRateLimited: windowMissed,
            droppedProcessingBehind: 0,
            droppedByCamera: 0,
            frameFailures: windowFailures,
            frameTimesSeconds: times,
            frameSpacingAvgSeconds: spacings.isEmpty ? nil : spacings.reduce(0, +) / Double(spacings.count),
            frameSpacingMinSeconds: spacings.min(),
            frameSpacingMaxSeconds: spacings.max(),
            thermalState: LiveBlendController.thermalStateName(),
            partial: windowPartial)
        entry.thermalStateAtStart = windowThermalAtStart
        if windowMemoryCapped {
            entry.memoryCapped = true
        }
        if windowExposureDivergenceMax > 0 {
            entry.exposureDivergenceStops = windowExposureDivergenceMax
        }

        windowIndex += 1
        windowStartUptime += configuration.intervalSeconds
        shotsRequestedThisWindow = 0
        windowFrameTimes = []
        windowMissed = 0
        windowFailures = 0
        windowPartial = false
        windowSawBackpressure = false
        windowExposureDivergenceMax = 0
        windowFrameDNGs = []
        windowFrameExposures = []
        openWindowState()

        pendingProcessingWindows += 1
        processingQueue.async {
            autoreleasepool {
                let processStart = ProcessInfo.processInfo.systemUptime
                var processed = entry
                var url: URL?
                var stats: FrameLuminanceStats?
                if frames.isEmpty || self.discardRequested.withLock({ $0 }) {
                    // Empty window, or a discard raced the queue: nothing to
                    // produce (a discarded run's log already says so). An
                    // emptiness the backpressure gate caused — captures
                    // withheld while processing caught up, with no camera
                    // error — is the scheduler's own restraint, recorded as
                    // starved rather than failed so it never feeds the
                    // consecutive-failure stop guard.
                    if frames.isEmpty, sawBackpressure, processed.frameFailures == 0,
                       !self.discardRequested.withLock({ $0 }) {
                        processed.starvedBackpressure = true
                    } else {
                        processed.failed = true
                    }
                } else {
                    url = self.processWindow(
                        frames: frames, exposure: exposure,
                        wantsStats: wantsStats, entry: &processed,
                        stats: &stats)
                }
                processed.totalMillis = (ProcessInfo.processInfo.systemUptime - processStart) * 1000
                self.workQueue.async {
                    self.commitOutput(
                        processed, url: url, exposure: exposure,
                        stats: stats, decision: decision)
                }
            }
        }
    }

    /// workQueue: fold a processed window back into run state and the log.
    private func commitOutput(
        _ processed: LiveBlendSessionLog.OutputEntry,
        url: URL?,
        exposure: DNGAuthor.DNGExposure,
        stats: FrameLuminanceStats?,
        decision: BlendStrategyDecision?
    ) {
        pendingProcessingWindows = max(0, pendingProcessingWindows - 1)
        var entry = processed
        let done = ProcessInfo.processInfo.systemUptime
        entry.actualIntervalSeconds = lastCompletionUptime.map { done - $0 }
        lastCompletionUptime = done
        peakProcessingSeconds = max(peakProcessingSeconds, entry.totalMillis / 1000)
        entry.memoryFootprintBytes = LiveBlendController.memoryFootprintBytes()
        if let footprint = entry.memoryFootprintBytes {
            peakMemoryFootprint = max(peakMemoryFootprint ?? 0, footprint)
        }
        // The stats feed the NEXT resolution whether or not this window's
        // write succeeded — the pixels were measured either way.
        if let stats { lastWindowStats = stats }
        if let url {
            frameURLs.append(url)
            // One session-log line per file that actually exists, numbered by
            // its place in the finished sequence, carrying the exposure the
            // blend was made at, how many captures went into it, and (on
            // Auto) the full strategy decision behind the count.
            sessionFrameLog.append(CaptureExposureLog.Entry(
                frameIndex: frameURLs.count,
                exposure: exposure,
                capturedAt: exposure.capturedAt ?? Date(),
                blendCount: entry.capturedFrames,
                strategy: decision,
                window: CaptureExposureLog.WindowPerformance(entry: entry)))
            timestampWriter?.append(FrameTimestamps.Entry(
                frame: frameURLs.count - 1,
                captureTime: exposure.capturedAt ?? Date(),
                shutter: exposure.exposureDuration ?? 0,
                iso: exposure.iso ?? 0))
        }
        if entry.starvedBackpressure {
            // Neither a failure (the camera did nothing wrong) nor a success
            // (nothing was produced): the streak counter holds where it is.
            skippedStarvedWindows += 1
        } else if entry.failed {
            failedOutputs += 1
            consecutiveProcessingFailures += 1
        } else {
            completedOutputs += 1
            consecutiveProcessingFailures = 0
            if entry.fallbackSingleFrame {
                fallbackOutputs += 1
            }
            // Feed the throughput governor: what this whole window actually
            // cost to process against the interval it had.
            let before = processingCeiling.ceiling
            processingCeiling.record(
                windowSeconds: entry.totalMillis / 1000,
                frames: entry.capturedFrames,
                intervalSeconds: configuration.intervalSeconds)
            if processingCeiling.ceiling != before {
                LLog("""
                    liveblend-dng: processing ceiling \(before) → \
                    \(processingCeiling.ceiling) \
                    (window \(entry.capturedFrames) frames took \
                    \(String(format: "%.2f", entry.totalMillis / 1000))s of a \
                    \(configuration.intervalSeconds)s interval)
                    """)
            }
            paceFloor.withLock { $0 = processingCeiling.sustainableIntervalSeconds }
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
                capped: entry.memoryCapped == true))
        }

        var status = status(after: entry)
        if !entry.failed, pendingProcessingWindows >= 2 {
            status = .processingBehind
        }
        pushDiagnostics {
            $0.lastCapturedFrames = entry.capturedFrames
            $0.lastBlendMillis = entry.blendMillis
            $0.lastOutputIntervalSeconds = entry.actualIntervalSeconds
            $0.outputCount = self.completedOutputs
            $0.status = status
        }
        LLog("liveblend-dng: window \(entry.index) captured=\(entry.capturedFrames)/\(entry.requestedFrames) format=\(entry.outputFormat ?? "-") total=\(Int(entry.totalMillis))ms \(status.rawValue)")

        if consecutiveProcessingFailures >= 3, !finishRequested {
            LLog("liveblend-dng: three consecutive output failures, stopping")
            endReason = "consecutiveFailures"
            requestStop(discard: false)
        }
        pumpCaptures()
    }

    /// Blend + author, entirely through Apple's calibrated RAW decode:
    /// every frame's DNG is taken to scene-linear working space, averaged,
    /// and written as a compressed Bayer DNG. Fallback rule (deterministic,
    /// always logged): if the linear blend cannot be produced, the window's
    /// first frame is saved as Apple's own unblended DNG; with nothing
    /// decodable the window fails. Runs on `processingQueue`; mutates only
    /// the entry and `processingFileIndex`, returning the written file.
    private func processWindow(
        frames: [Data],
        exposure: DNGAuthor.DNGExposure,
        wantsStats: Bool,
        entry: inout LiveBlendSessionLog.OutputEntry,
        stats: inout FrameLuminanceStats?
    ) -> URL? {
        let referenceData = frames.first
        // The exposure tags the authored output will carry. An authored DNG has
        // no EXIF IFD unless one is built for it, which is why every blended
        // interval frame used to land with no ISO, shutter, f-number or
        // brightness at all.
        let exifTags = exposure.isEmpty ? nil : DNGAuthor.exifTags(exposure)

        // One location fix for the whole window: baked into whichever DNG this
        // window writes (authored blend or pass-through original).
        let gpsFix = configuration.gpsProvider?() ?? nil
        let gpsTags = gpsFix.map {
            DNGAuthor.gpsTags(latitude: $0.latitude, longitude: $0.longitude,
                              altitude: $0.altitude, timestamp: $0.timestamp)
        }
        // Pass-through originals get GPS added by an append-only IFD injection
        // that leaves the sensor data byte-for-byte intact.
        func geotagged(_ original: Data) -> Data {
            guard let fix = gpsFix else { return original }
            return DNGAuthor.dngByInsertingGPS(
                into: original, latitude: fix.latitude, longitude: fix.longitude,
                altitude: fix.altitude, timestamp: fix.timestamp)
        }

        /// A pass-through original is Apple's file byte-for-byte, and Apple's
        /// file already carries the shot's EXIF — so this is a repair, not a
        /// step: it only rewrites the container when the exposure block is
        /// genuinely missing, and falls back to the untouched bytes if ImageIO
        /// declines. The untouched original is the ground truth the blend paths
        /// are compared against; a routine re-encode would cost that.
        func withExposure(_ original: Data) -> Data {
            guard !exposure.isEmpty,
                  !DNGAuthor.hasExposureMetadata(in: original) else { return original }
            guard let repaired = DNGAuthor.dngDataByInjectingEXIF(
                into: original, exposure: exposure) else {
                LLog("liveblend-dng: pass-through frame has no EXIF and ImageIO refused the repair")
                return original
            }
            return repaired
        }

        // Blending off: one RAW per interval, saved as Apple's original
        // DNG byte-for-byte — untouched originals, the ground truth for
        // comparing against blended output (and a legitimate holy-grail
        // baseline). GPS tagging, when on, appends a GPS IFD without touching
        // the raw image.
        //
        // Auto joins it when the light was bright enough to want a single
        // frame: one capture blended with nothing is the same picture, and
        // passing it through skips a decode/re-author round trip while keeping
        // Apple's own tags.
        // Auto used to pass single-frame windows through as Apple's own DNG
        // (skipping a decode round-trip). The 2026-08-21 night shoot showed
        // why that cannot stand: Apple's rendering and the authored linear
        // blend differ by ~1/8 stop, and with the count oscillating 1<->2
        // EVERY crossing was a visible luminance step — 39 of 39 flagged
        // flicker events in the two clips sat exactly on that boundary. On
        // Auto, a single frame now takes the same authored path as a blend
        // of one, so a count change never switches rendering pipelines.
        // fixed(1) keeps the pass-through: that run is uniform end to end.
        if configuration.blendDepth == .fixed(1), let referenceData {
            let output = withExposure(geotagged(referenceData))
            let url = configuration.outputDirectory
                .appendingPathComponent(String(format: "frame-%05d.dng", processingFileIndex))
            do {
                try output.write(to: url, options: .atomic)
                entry.outputFormat = "dng"
                entry.fileBytes = output.count
                processingFileIndex += 1
                return url
            } catch {
                LLog("liveblend-dng: untouched write failed: \(error)")
                entry.failed = true
                return nil
            }
        }

        do {
            let blendStart = ProcessInfo.processInfo.systemUptime
            var summed: CIImage?
            var decodedCount = 0
            for frameData in frames {
                autoreleasepool {
                    guard let filter = CIRAWFilter(imageData: frameData, identifierHint: nil) else {
                        entry.frameFailures += 1
                        return
                    }
                    filter.boostAmount = 0
                    guard let image = filter.outputImage else {
                        entry.frameFailures += 1
                        return
                    }
                    decodedCount += 1
                    if let current = summed {
                        summed = image.applyingFilter("CIAdditionCompositing", parameters: [
                            kCIInputBackgroundImageKey: current,
                        ])
                    } else {
                        summed = image
                    }
                }
            }
            guard let summed, decodedCount > 0 else {
                throw DNGError.malformedDNG("no decodable frames in this window")
            }
            // Per-window camera model from this window's own reference frame:
            // camera-native samples + the camera's real matrices/neutral give
            // raw developers their native dual-illuminant WB behaviour, and
            // the as-shot anchor tracks the changing light window by window.
            var cameraModel: CameraColorModel?
            if let referenceData {
                cameraModel = try? CameraColorTransform.model(
                    from: DNGDocument.parseReference(referenceData))
            }
            if cameraModel == nil {
                LLog("liveblend-dng: no camera color model — falling back to sRGB tags")
            }
            let scale = (1.0 / CGFloat(decodedCount)) / CGFloat(1 << LiveBlendRawController.headroomStops)
            let scalarAveraged = summed.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            let width = Int(scalarAveraged.extent.width)
            let height = Int(scalarAveraged.extent.height)
            // ONE pass through the RAW decoders: render the working-space
            // average to 16-bit (the GPU scales and clamps). The preview and
            // the camera-native transform both reuse this buffer — a second
            // trip through the RAW graph re-decoded every frame and scaled
            // with the blend count (benchmark: up to ~1.2s at 10:1).
            var rgba = [UInt16](repeating: 0, count: width * height * 4)
            var wrappedData = Data()
            rgba.withUnsafeMutableBytes { buffer in
                ciContext.render(
                    scalarAveraged,
                    toBitmap: buffer.baseAddress!,
                    rowBytes: width * 8,
                    bounds: scalarAveraged.extent,
                    format: .RGBA16,
                    colorSpace: LiveBlendRawController.linearColorSpace)
                wrappedData = Data(bytes: buffer.baseAddress!, count: width * height * 8)
            }
            let workingImage = CIImage(
                bitmapData: wrappedData,
                bytesPerRow: width * 8,
                size: CGSize(width: width, height: height),
                format: .RGBA16,
                colorSpace: LiveBlendRawController.linearColorSpace)
            entry.blendMillis = (ProcessInfo.processInfo.systemUptime - blendStart) * 1000

            if wantsStats {
                // Strided point sample of the buffer the blend just rendered
                // anyway — the strategies' pixel signal costs milliseconds
                // here, never a second decode. Stored values are scene/2^2
                // (the headroom), which `compute` undoes.
                stats = FrameLuminanceStats.compute(
                    rgba16: rgba, width: width, height: height,
                    headroomStops: LiveBlendRawController.headroomStops,
                    iso: exposure.iso,
                    exposureDuration: exposure.exposureDuration,
                    ev: exposure.exposureValue,
                    sourceScale: 1.0)
            }

            let url = configuration.outputDirectory
                .appendingPathComponent(String(format: "frame-%05d.dng", processingFileIndex))
            let encodeStart = ProcessInfo.processInfo.systemUptime
            // Preview renders from the WORKING-space average — camera-native
            // samples pushed through an sRGB conversion would look green.
            let preview = blendedPreview(from: workingImage)
            if let cameraModel {
                // Camera-native pass over the rendered buffer: decode-free,
                // so it costs milliseconds instead of another full decode.
                // Linear 3x3, so applying it after the scalar average (with
                // its 16-bit quantize) is the same math to within an LSB.
                let rows = cameraModel.transformRows
                let cameraImage = workingImage.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: rows[0][0], y: rows[0][1], z: rows[0][2], w: 0),
                    "inputGVector": CIVector(x: rows[1][0], y: rows[1][1], z: rows[1][2], w: 0),
                    "inputBVector": CIVector(x: rows[2][0], y: rows[2][1], z: rows[2][2], w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ])
                rgba.withUnsafeMutableBytes { buffer in
                    ciContext.render(
                        cameraImage,
                        toBitmap: buffer.baseAddress!,
                        rowBytes: width * 8,
                        bounds: cameraImage.extent,
                        format: .RGBA16,
                        colorSpace: LiveBlendRawController.linearColorSpace)
                }
                // Phase 2 output: camera-native samples re-mosaiced to Bayer
                // and lossless-JPEG tiled — one sample per pixel, ~4x smaller
                // than LinearRaw, bit-exact codec, full WB latitude intact.
                let mosaic = DNGAuthor.mosaic(
                    fromRGBA16: rgba, width: width, height: height,
                    pattern: [0, 1, 1, 2])
                try DNGAuthor.writeCompressedBayerDNG(
                    mosaic: mosaic, width: width, height: height,
                    cfaPattern: [0, 1, 1, 2],
                    cameraColor: cameraModel.tags,
                    headroomStops: LiveBlendRawController.headroomStops,
                    gps: gpsTags,
                    exif: exifTags,
                    preview: preview,
                    to: url)
            } else {
                var rgb = Data(count: width * height * 6)
                rgba.withUnsafeMutableBytes { source in
                    rgb.withUnsafeMutableBytes { destination in
                        var sourceBuffer = vImage_Buffer(
                            data: source.baseAddress, height: vImagePixelCount(height),
                            width: vImagePixelCount(width), rowBytes: width * 8)
                        var destinationBuffer = vImage_Buffer(
                            data: destination.baseAddress, height: vImagePixelCount(height),
                            width: vImagePixelCount(width), rowBytes: width * 6)
                        vImageConvert_RGBA16UtoRGB16U(&sourceBuffer, &destinationBuffer, vImage_Flags(kvImageNoFlags))
                    }
                }
                try DNGAuthor.writeLinearDNG(
                    rgb16: rgb, width: width, height: height,
                    headroomStops: LiveBlendRawController.headroomStops,
                    cameraColor: nil,
                    gps: gpsTags,
                    exif: exifTags,
                    preview: preview,
                    to: url)
            }
            entry.encodeMillis = (ProcessInfo.processInfo.systemUptime - encodeStart) * 1000
            entry.outputFormat = "dng"
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            entry.fileBytes = (attributes?[.size] as? NSNumber)?.intValue
            if decodedCount == 1 {
                entry.fallbackSingleFrame = true
            }
            processingFileIndex += 1
            return url
        } catch {
            LLog("liveblend-dng: output \(entry.index) failed: \(error)")
            if let referenceData {
                let output = withExposure(geotagged(referenceData))
                let url = configuration.outputDirectory
                    .appendingPathComponent(String(format: "frame-%05d.dng", processingFileIndex))
                if (try? output.write(to: url, options: .atomic)) != nil {
                    entry.outputFormat = "dng"
                    entry.fallbackSingleFrame = true
                    entry.fileBytes = output.count
                    processingFileIndex += 1
                    return url
                }
            }
            entry.failed = true
            return nil
        }
    }

    /// Display-referred small render of the blended linear image for the
    /// embedded preview (headroom scaling undone for a sensible brightness).
    private func blendedPreview(from averaged: CIImage) -> DNGAuthor.Preview? {
        let boost = CGFloat(1 << LiveBlendRawController.headroomStops)
        let display = averaged.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: boost, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: boost, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: boost, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let maxSide = max(display.extent.width, display.extent.height)
        guard maxSide > 0 else { return nil }
        let previewScale = 512 / maxSide
        let scaled = display.transformed(by: CGAffineTransform(scaleX: previewScale, y: previewScale))
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = ciContext.createCGImage(
                scaled, from: scaled.extent, format: .RGBA8, colorSpace: srgb) else {
            return nil
        }
        return LiveBlendRawController.makePreview(from: cgImage)
    }

    private func status(after entry: LiveBlendSessionLog.OutputEntry) -> LiveBlendStatus {
        if entry.failed { return .captureFailed }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return .thermalPressure
        default: break
        }
        if entry.missedRateLimited > 0 { return .cameraRateLimited }
        if entry.requestedFrames > 0, entry.capturedFrames < entry.requestedFrames { return .reducedFrameCount }
        return .healthy
    }

    private func finishRun(discard: Bool) {
        log.summary = LiveBlendSessionLog.Summary(
            endedAt: Date(),
            captureDurationSeconds: ProcessInfo.processInfo.systemUptime - startUptime,
            requestedOutputs: log.outputs.count,
            completedOutputs: completedOutputs,
            fallbackOutputs: fallbackOutputs,
            failedOutputs: failedOutputs,
            skippedWindows: skippedStarvedWindows,
            peakProcessingSeconds: peakProcessingSeconds,
            peakMemoryFootprintBytes: peakMemoryFootprint,
            finalThermalState: LiveBlendController.thermalStateName(),
            discarded: discard)
        rewriteLog()
        exposureWriter?.close()
        exposureWriter = nil
        // Released before the discard branch below can delete the directory
        // out from under it.
        timestampWriter?.close()
        timestampWriter = nil

        let result: LiveBlendCaptureResult?
        if discard || frameURLs.isEmpty {
            try? FileManager.default.removeItem(at: configuration.outputDirectory)
            result = nil
        } else {
            // The session's own exposure record, written into the directory the
            // frames live in so it travels with the project. Written once, at
            // the end, because it describes the finished sequence; the
            // crash-safe per-capture story is the NDJSON sidecar's job.
            let session = CaptureExposureLog.Session(
                sessionID: configuration.sessionID,
                deviceModel: configuration.deviceModel,
                // "dynamic" when the Holy Grail ramp drove the run — only a
                // ramped run is handed a commanded exposure. `captureFlat`
                // stays absent here: the setting is never offered for DNG.
                captureMode: configuration.rampExposure != nil ? "dynamic" : "interval",
                blendMode: configuration.blendDepth.token,
                algorithm: configuration.blendDepth == .auto
                    ? configuration.blendStrategy.rawValue : nil,
                algorithmVersion: configuration.blendDepth == .auto
                    ? BlendStrategyID.version : nil,
                cameraName: configuration.cameraName,
                captureWidth: configuration.captureWidth,
                captureHeight: configuration.captureHeight,
                intervalSeconds: log.header.requestedIntervalSeconds,
                endReason: endReason,
                failedWindows: failedOutputs > 0 ? failedOutputs : nil,
                starvedWindows: skippedStarvedWindows > 0 ? skippedStarvedWindows : nil,
                startedAt: runStartedAt,
                endedAt: Date(),
                frames: sessionFrameLog)
            // Written into the staging directory, which is where project
            // registration looks for named sidecars — so it lands in the
            // project's `source/` folder under its own name.
            if CaptureExposureLog.write(
                session, toDirectory: configuration.outputDirectory) == nil {
                LLog("liveblend-dng: could not write \(CaptureExposureLog.sessionFileName)")
            }
            result = LiveBlendCaptureResult(
                frameURLs: frameURLs,
                logURL: configuration.logURL,
                completedOutputs: completedOutputs,
                fallbackOutputs: fallbackOutputs,
                failedOutputs: failedOutputs,
                outputFormat: "dng")
        }
        if frameURLs.isEmpty, !discard {
            pushDiagnostics { $0.status = .captureFailed }
        }
        active.withLock { $0 = false }
        LLog("liveblend-dng: finished outputs=\(frameURLs.count) discarded=\(discard) log=\(configuration.logURL.path)")
        DispatchQueue.main.async { self.onFinished?(result) }
    }

    // MARK: Support

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
                LLog("liveblend-dng: could not write experiment log: \(error)")
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

    /// Downscaled tightly-packed RGB for the DNG's embedded preview IFD.
    static func makePreview(from image: CGImage, maxWidth: Int = 512) -> DNGAuthor.Preview? {
        let scale = min(1, Double(maxWidth) / Double(image.width))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        var rgb = Data(capacity: width * height * 3)
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for index in 0..<(width * height) {
            rgb.append(pixels[index * 4])
            rgb.append(pixels[index * 4 + 1])
            rgb.append(pixels[index * 4 + 2])
        }
        return DNGAuthor.Preview(width: width, height: height, rgb: rgb)
    }
}

#endif
