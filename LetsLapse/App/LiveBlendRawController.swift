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

    // workQueue-confined output state.
    private var log: LiveBlendSessionLog
    private var frameURLs: [URL] = []
    private var outputIndex = 0
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
            outputFormat: "dng"))
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

            // RAW capture cadence tops out around 1/s on most devices; the
            // tick just requests shots and the in-flight guard records what
            // the hardware couldn't keep up with.
            let spacing = max(0.35, self.configuration.intervalSeconds / Double(self.configuration.framesPerBlend))
            let timer = DispatchSource.makeTimerSource(queue: self.workQueue)
            timer.schedule(deadline: .now() + 0.05, repeating: spacing)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func requestStop(discard: Bool, keepPartial: Bool = true) {
        workQueue.async {
            guard !self.finishRequested else { return }
            self.finishRequested = true
            self.selecting = false
            self.timer?.cancel()
            self.timer = nil
            if !discard, keepPartial, !self.windowFrameDNGs.isEmpty {
                self.windowPartial = true
                self.closeWindow()
            } else {
                self.windowFrameDNGs.removeAll()
            }
            self.finishRun(discard: discard)
        }
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
        // Strictly one RAW capture at a time. Overlapping RAW captures
        // starved the session on iPhone 16 Pro (a hung second capture never
        // completes, the in-flight budget never frees, and every later
        // window closes empty), so serialization plus honest miss-counting
        // beats theoretical extra cadence.
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
    }

    // MARK: Window close + DNG output (workQueue)

    private func closeWindow() {
        let closeStart = ProcessInfo.processInfo.systemUptime
        let times = windowFrameTimes
        let spacings = zip(times.dropFirst(), times).map(-)
        var entry = LiveBlendSessionLog.OutputEntry(
            index: windowIndex,
            windowStartSeconds: windowStartUptime - startUptime,
            windowEndSeconds: windowStartUptime - startUptime + configuration.intervalSeconds,
            requestedIntervalSeconds: configuration.intervalSeconds,
            requestedFrames: configuration.framesPerBlend,
            capturedFrames: windowFrameDNGs.count,
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

        if windowFrameDNGs.isEmpty {
            entry.failed = true
            failedOutputs += 1
        } else {
            writeWindowOutput(&entry)
        }

        let done = ProcessInfo.processInfo.systemUptime
        entry.totalMillis = (done - closeStart) * 1000
        entry.actualIntervalSeconds = lastCompletionUptime.map { done - $0 }
        lastCompletionUptime = done
        peakProcessingSeconds = max(peakProcessingSeconds, done - closeStart)
        entry.memoryFootprintBytes = LiveBlendController.memoryFootprintBytes()
        if let footprint = entry.memoryFootprintBytes {
            peakMemoryFootprint = max(peakMemoryFootprint ?? 0, footprint)
        }
        log.outputs.append(entry)
        rewriteLog()

        let status = status(after: entry)
        pushDiagnostics {
            $0.lastCapturedFrames = entry.capturedFrames
            $0.lastBlendMillis = entry.blendMillis
            $0.lastOutputIntervalSeconds = entry.actualIntervalSeconds
            $0.outputCount = self.completedOutputs
            $0.currentWindowSelectedFrames = 0
            $0.status = status
        }
        LLog("liveblend-dng: window \(entry.index) captured=\(entry.capturedFrames)/\(entry.requestedFrames) format=\(entry.outputFormat ?? "-") total=\(Int(entry.totalMillis))ms \(status.rawValue)")

        windowIndex += 1
        windowStartUptime += configuration.intervalSeconds
        shotsRequestedThisWindow = 0
        windowFrameTimes = []
        windowMissed = 0
        windowFailures = 0
        windowPartial = false
        windowFrameDNGs = []

        if consecutiveProcessingFailures >= 3 {
            LLog("liveblend-dng: three consecutive output failures, stopping")
            requestStop(discard: false)
        }
    }

    /// Blend + author, entirely through Apple's calibrated RAW decode:
    /// every frame's DNG is taken to scene-linear working space, averaged,
    /// and written as a 16-bit LinearRaw DNG with two stops of highlight
    /// headroom. Fallback rule (deterministic, always logged): if the linear
    /// blend cannot be produced, the window's first frame is saved as
    /// Apple's own unblended DNG; with nothing decodable the window fails.
    private func writeWindowOutput(_ entry: inout LiveBlendSessionLog.OutputEntry) {
        let frames = windowFrameDNGs
        let referenceData = frames.first

        // "1 · Untouched": one RAW per interval, saved as Apple's original
        // DNG byte-for-byte — the ground-truth capture mode for comparing
        // against blended output (and a legitimate holy-grail baseline).
        if configuration.framesPerBlend == 1, let referenceData {
            let url = configuration.outputDirectory
                .appendingPathComponent(String(format: "frame-%05d.dng", outputIndex))
            do {
                try referenceData.write(to: url, options: .atomic)
                entry.outputFormat = "dng"
                entry.fileBytes = referenceData.count
                frameURLs.append(url)
                outputIndex += 1
                completedOutputs += 1
                consecutiveProcessingFailures = 0
            } catch {
                LLog("liveblend-dng: untouched write failed: \(error)")
                entry.failed = true
                failedOutputs += 1
                consecutiveProcessingFailures += 1
            }
            return
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
            let scale = (1.0 / CGFloat(decodedCount)) / CGFloat(1 << LiveBlendRawController.headroomStops)
            let averaged = summed.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            let width = Int(averaged.extent.width)
            let height = Int(averaged.extent.height)
            // Render straight to 16-bit (the GPU scales and clamps), then a
            // single vImage pass drops alpha — a per-pixel Swift loop here
            // cost ~6s in Debug builds and blew capture intervals.
            var rgba = [UInt16](repeating: 0, count: width * height * 4)
            rgba.withUnsafeMutableBytes { buffer in
                ciContext.render(
                    averaged,
                    toBitmap: buffer.baseAddress!,
                    rowBytes: width * 8,
                    bounds: averaged.extent,
                    format: .RGBA16,
                    colorSpace: LiveBlendRawController.linearColorSpace)
            }
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
            entry.blendMillis = (ProcessInfo.processInfo.systemUptime - blendStart) * 1000

            let url = configuration.outputDirectory
                .appendingPathComponent(String(format: "frame-%05d.dng", outputIndex))
            let encodeStart = ProcessInfo.processInfo.systemUptime
            let preview = blendedPreview(from: averaged)
            try DNGAuthor.writeLinearDNG(
                rgb16: rgb, width: width, height: height,
                headroomStops: LiveBlendRawController.headroomStops,
                preview: preview,
                to: url)
            entry.encodeMillis = (ProcessInfo.processInfo.systemUptime - encodeStart) * 1000
            entry.outputFormat = "dng"
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            entry.fileBytes = (attributes?[.size] as? NSNumber)?.intValue
            frameURLs.append(url)
            outputIndex += 1
            completedOutputs += 1
            if decodedCount == 1 {
                entry.fallbackSingleFrame = true
                fallbackOutputs += 1
            }
            consecutiveProcessingFailures = 0
        } catch {
            LLog("liveblend-dng: output \(entry.index) failed: \(error)")
            if let referenceData {
                let url = configuration.outputDirectory
                    .appendingPathComponent(String(format: "frame-%05d.dng", outputIndex))
                if (try? referenceData.write(to: url, options: .atomic)) != nil {
                    entry.outputFormat = "dng"
                    entry.fallbackSingleFrame = true
                    entry.fileBytes = referenceData.count
                    frameURLs.append(url)
                    outputIndex += 1
                    completedOutputs += 1
                    fallbackOutputs += 1
                    consecutiveProcessingFailures = 0
                    return
                }
            }
            entry.failed = true
            failedOutputs += 1
            consecutiveProcessingFailures += 1
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
