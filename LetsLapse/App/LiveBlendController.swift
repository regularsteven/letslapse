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
        /// Per-output format ("dng"/"standard"); records mid-session
        /// fallbacks individually.
        var outputFormat: String? = nil
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
        /// Geotag source: the EXIF GPS dictionary for the current fix, or nil
        /// when tagging is off or no fix exists yet. Called on the blend queue
        /// as each output is written, so every blended frame carries the fix
        /// from its own moment — matching the plain-still capture path.
        var gpsMetadata: (() -> [String: Any]?)? = nil

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
    private let configuration: Configuration
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
        /// Resolved at window open; nil = unthrottled (take every frame).
        var frameTarget: Int? = nil
        var thermalStateAtStart = "unknown"
        var frameTimes: [Double] = []
        var missedRateLimited = 0
        var droppedProcessingBehind = 0
        var droppedByCamera = 0
        var bufferFailures = 0
        var partial = false
    }

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
    private var outputIndex = 0
    private var completedOutputs = 0
    private var fallbackOutputs = 0
    private var failedOutputs = 0
    private var skippedWindows = 0
    private var accumulateFailuresThisWindow = 0
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
        self.window = WindowRecord(index: 0, startSeconds: 0)
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

    /// Graceful stop keeps a ≥1-frame partial window (unless `keepPartial`
    /// is false — a scheduled "stop at N" wants exactly N) and hands the run
    /// over; discard drops queued work, deletes the temp frames, and never
    /// fires the result. All are safe to call more than once.
    func requestStop(discard: Bool, keepPartial: Bool = true) {
        videoQueue.async {
            guard !self.finishRequested else { return }
            self.finishRequested = true
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

    /// Opens a window: resolves its frame target (Safe mode re-evaluates
    /// per interval, here) and stamps the thermal state the learning system
    /// keys on. videoQueue.
    private func openWindow(index: Int, startSeconds: Double) -> WindowRecord {
        let target: Int?
        switch configuration.blendDepth {
        case .fixed(let frames): target = frames
        case .unthrottled: target = nil
        case .throttled: target = max(1, configuration.throttledFrameTarget?() ?? 2)
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
            frameTarget: target,
            thermalStateAtStart: LiveBlendController.thermalStateName())
    }

    /// Hands the current window to the blend queue and opens the next one.
    /// Pre-anchor (no frame ever seen) windows report dead time without
    /// advancing the PTS grid, which only exists once a frame arrives.
    private func closeCurrentWindow() {
        let record = window
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
            windowEndSeconds: record.startSeconds + configuration.intervalSeconds,
            requestedIntervalSeconds: configuration.intervalSeconds,
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

        if entry.capturedFrames == 0 {
            // Nothing usable arrived; keep the session going. Not counted as
            // a processing failure — a covered camera shouldn't auto-stop.
            blender.discardWindow()
            entry.failed = true
            failedOutputs += 1
        } else {
            do {
                let blendStart = ProcessInfo.processInfo.systemUptime
                let image = try blender.finalizeImage()
                entry.blendMillis = (ProcessInfo.processInfo.systemUptime - blendStart) * 1000
                let url = configuration.outputDirectory
                    .appendingPathComponent(String(format: "frame-%05d.jpg", outputIndex))
                let encodeStart = ProcessInfo.processInfo.systemUptime
                let metadata = configuration.gpsMetadata?().map {
                    [kCGImagePropertyGPSDictionary: $0 as Any]
                }
                try ImageExporter.write(image, to: url, format: .jpeg, metadata: metadata)
                entry.encodeMillis = (ProcessInfo.processInfo.systemUptime - encodeStart) * 1000
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                entry.fileBytes = (attributes?[.size] as? NSNumber)?.intValue
                frameURLs.append(url)
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
            requestStop(discard: false)
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

        let result: LiveBlendCaptureResult?
        if discard || frameURLs.isEmpty {
            try? FileManager.default.removeItem(at: configuration.outputDirectory)
            result = nil
        } else {
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
