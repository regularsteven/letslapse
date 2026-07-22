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
        var framesPerBlend: Int
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
    }

    private let configuration: Configuration
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
    var onFinished: ((LiveBlendCaptureResult?) -> Void)?

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
    private var readinessObservation: NSKeyValueObservation?
    /// Set after a bracket request fails so the run degrades to singles
    /// instead of sinking every window on a rejected settings shape.
    private var bracketDisabled = false
    /// Windows handed to `processingQueue` whose commit hasn't landed yet.
    /// Backpressure: ≥2 pauses new captures so frame Data can't pile up.
    private var pendingProcessingWindows = 0

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
            requestedFramesPerBlend: configuration.framesPerBlend)
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
            requestedFramesPerBlend: configuration.framesPerBlend,
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
            LLog("liveblend-dng: start interval=\(self.configuration.intervalSeconds)s frames=\(self.configuration.framesPerBlend) raw=\(self.configuration.rawPixelFormat) log=\(self.configuration.logURL.path)")
            self.rewriteLog()

            // Spread mode paces shots across the interval; burst mode fires
            // them back-to-back, so its timer only closes windows and
            // heartbeats the pump — a short fixed period keeps closes tight.
            let spacing: Double
            if self.usesBurst {
                spacing = 0.25
            } else {
                spacing = max(0.35, self.configuration.intervalSeconds / Double(self.configuration.framesPerBlend))
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

    /// Burst variants (including bracketed) replace spread pacing.
    private var usesBurst: Bool {
        configuration.burstScheduling || configuration.bracketedRAW
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
        guard shotsRequestedThisWindow < configuration.framesPerBlend else { return }
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
        guard pendingProcessingWindows < 2 else { return }
        // Failed captures free their slots for a replacement shot, but never
        // an unbounded retry loop inside one window.
        let shotBudget = configuration.framesPerBlend * 2
        while shotsRequestedThisWindow < shotBudget {
            let wanted = configuration.framesPerBlend - windowFrameDNGs.count - inFlightCaptures
            guard wanted > 0 else { return }
            if usesBrackets {
                // One bracket in flight at a time; its frames arrive at
                // sensor-consecutive spacing.
                guard inFlightCaptures == 0 else { return }
                let count = min(wanted, configuration.maxBracketFrames)
                if count >= 2 {
                    fireBracket(count)
                } else {
                    fireCapture()
                }
            } else if #available(iOS 17.0, *) {
                guard photoOutput.captureReadiness == .ready, inFlightCaptures < 3 else { return }
                fireCapture()
            } else {
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
        captureExecutor { [weak self] in
            guard let self else { return }
            let perFrame = (0..<count).map { _ in
                AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(
                    exposureTargetBias: AVCaptureDevice.currentExposureTargetBias)
            }
            // Quality prioritization is deliberately left default here —
            // bracket settings reject some per-shot options that plain
            // settings accept.
            let settings = AVCapturePhotoBracketSettings(
                rawPixelFormatType: format,
                processedFormat: nil,
                bracketedSettings: perFrame)
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
                    self.handleRawPhoto(photo)
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

    private func handleRawPhoto(_ photo: AVCapturePhoto) {
        guard selecting else { return }
        guard let pixelBuffer = photo.pixelBuffer else {
            windowFailures += 1
            LLog("liveblend-dng: raw photo without pixel buffer")
            return
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
        windowFrameTimes.append(ProcessInfo.processInfo.systemUptime - startUptime)
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
        let times = windowFrameTimes
        let spacings = zip(times.dropFirst(), times).map(-)
        var entry = LiveBlendSessionLog.OutputEntry(
            index: windowIndex,
            windowStartSeconds: windowStartUptime - startUptime,
            windowEndSeconds: windowStartUptime - startUptime + configuration.intervalSeconds,
            requestedIntervalSeconds: configuration.intervalSeconds,
            requestedFrames: configuration.framesPerBlend,
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

        windowIndex += 1
        windowStartUptime += configuration.intervalSeconds
        shotsRequestedThisWindow = 0
        windowFrameTimes = []
        windowMissed = 0
        windowFailures = 0
        windowPartial = false
        windowFrameDNGs = []
        pushDiagnostics { $0.currentWindowSelectedFrames = 0 }

        pendingProcessingWindows += 1
        processingQueue.async {
            autoreleasepool {
                let processStart = ProcessInfo.processInfo.systemUptime
                var processed = entry
                var url: URL?
                if frames.isEmpty || self.discardRequested.withLock({ $0 }) {
                    // Empty window, or a discard raced the queue: nothing to
                    // produce (a discarded run's log already says so).
                    processed.failed = true
                } else {
                    url = self.processWindow(frames: frames, entry: &processed)
                }
                processed.totalMillis = (ProcessInfo.processInfo.systemUptime - processStart) * 1000
                self.workQueue.async { self.commitOutput(processed, url: url) }
            }
        }
    }

    /// workQueue: fold a processed window back into run state and the log.
    private func commitOutput(_ processed: LiveBlendSessionLog.OutputEntry, url: URL?) {
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
        if let url {
            frameURLs.append(url)
        }
        if entry.failed {
            failedOutputs += 1
            consecutiveProcessingFailures += 1
        } else {
            completedOutputs += 1
            consecutiveProcessingFailures = 0
            if entry.fallbackSingleFrame {
                fallbackOutputs += 1
            }
        }
        log.outputs.append(entry)
        rewriteLog()

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
    private func processWindow(frames: [Data], entry: inout LiveBlendSessionLog.OutputEntry) -> URL? {
        let referenceData = frames.first

        // "1 · Untouched": one RAW per interval, saved as Apple's original
        // DNG byte-for-byte — the ground-truth capture mode for comparing
        // against blended output (and a legitimate holy-grail baseline).
        if configuration.framesPerBlend == 1, let referenceData {
            let url = configuration.outputDirectory
                .appendingPathComponent(String(format: "frame-%05d.dng", processingFileIndex))
            do {
                try referenceData.write(to: url, options: .atomic)
                entry.outputFormat = "dng"
                entry.fileBytes = referenceData.count
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
                let url = configuration.outputDirectory
                    .appendingPathComponent(String(format: "frame-%05d.dng", processingFileIndex))
                if (try? referenceData.write(to: url, options: .atomic)) != nil {
                    entry.outputFormat = "dng"
                    entry.fallbackSingleFrame = true
                    entry.fileBytes = referenceData.count
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
        if entry.capturedFrames < entry.requestedFrames { return .reducedFrameCount }
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
            skippedWindows: 0,
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
