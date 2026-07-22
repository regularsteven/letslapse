import Foundation
import AVFoundation
import CoreImage
import SwiftUI
import os
import LetsLapseKit

// The benchmark exercises the Bayer RAW photo pipeline, which the compiler
// marks unavailable on macOS — iOS-family only, like LiveBlendRawController.
#if os(iOS)
import UIKit

// MARK: - Result rows

/// One capture batch: N RAW frames requested flat-out, no interval pacing.
struct CaptureBenchmarkBatch {
    var mechanism: CaptureBenchmarkRunner.Mechanism
    var frames: Int
    var rep: Int
    /// First request to last delivery.
    var totalSeconds: Double
    /// First request to first delivery (pipeline latency).
    var firstLatencySeconds: Double
    var gapAverage: Double?
    var gapMin: Double?
    var gapMax: Double?
    var delivered: Int
    var thermal: String
    var note: String?
    /// The captured DNGs, handed on to the pipeline stage (not reported).
    var dngs: [Data] = []
}

/// One full production-pipeline run over a batch's frames.
struct CaptureBenchmarkPipeline {
    var mechanism: CaptureBenchmarkRunner.Mechanism
    var frames: Int
    var rep: Int
    var graphMillis: Double
    var renderMillis: Double
    /// The camera-native matrix pass over the rendered buffer (decode-free).
    var matrixMillis: Double
    var previewMillis: Double
    var mosaicMillis: Double
    var writeMillis: Double
    var totalMillis: Double
    var fileBytes: Int
    var note: String?
}

// MARK: - Runner

/// Fully automated capture + blend benchmark, self-contained (own camera
/// session, no CaptureView involvement). For each capture mechanism it
/// shoots 3-, 5- and 10-frame RAW batches as fast as the mechanism allows,
/// three reps each, then runs the exact production blend pipeline on the
/// captured frames with per-stage timing — so capture pace and processing
/// cost are measured in isolation and the pain point is unambiguous.
final class CaptureBenchmarkRunner: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    enum Mechanism: String, CaseIterable {
        /// One RAW at a time, next fired on delivery — the pre-experiment
        /// baseline.
        case sequential
        /// Responsive capture + zero shutter lag + fast prioritization,
        /// fired whenever the output reports ready.
        case responsive
        /// RAW brackets — consecutive sensor frames per request.
        case bracketed
    }

    static let blendCounts = [3, 5, 10]
    static let repetitions = 3

    @Published var isRunning = false
    @Published var statusLine = ""
    @Published var reportText: String?

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let benchQueue = DispatchQueue(label: "com.letslapse.benchmark", qos: .userInitiated)
    private var rawFormat: OSType = 0
    private var bracketMax = 0
    private var responsiveSupported = false
    private var captureDimensions = "unknown"
    private var cameraName = "unknown camera"

    // Mirrors the production controller's working space and headroom.
    private static let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let headroomStops = 2
    private lazy var ciContext = CIContext(options: [
        .workingColorSpace: CaptureBenchmarkRunner.linearColorSpace,
        .workingFormat: CIFormat.RGBAh.rawValue,
        .cacheIntermediates: false,
    ])

    // benchQueue-confined batch state.
    private var collecting = false
    private var batchGeneration = 0
    private var batchTarget = 0
    private var batchMechanism: Mechanism = .sequential
    private var batchDNGs: [Data] = []
    private var batchDeliveryUptimes: [Double] = []
    private var batchFireUptime: Double = 0
    private var batchNote: String?
    private var shotsFired = 0
    private var inFlight = 0
    private var batchContinuation: CheckedContinuation<Void, Never>?
    private var readinessObservation: NSKeyValueObservation?
    private var cancelRequested = false

    // MARK: Run control

    func run() {
        guard !isRunning else { return }
        isRunning = true
        reportText = nil
        statusLine = "Preparing camera…"
        UIApplication.shared.isIdleTimerDisabled = true
        Task { await self.runAll() }
    }

    func cancel() {
        benchQueue.async {
            self.cancelRequested = true
            self.finishBatch(note: "cancelled")
        }
    }

    private func runAll() async {
        defer {
            Task { @MainActor in
                self.isRunning = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        benchQueue.sync { self.cancelRequested = false }

        if let failure = await setUpSession() {
            await publishReport("LetsLapse capture benchmark\n\nCould not start: \(failure)\n")
            return
        }

        var batches: [CaptureBenchmarkBatch] = []
        var pipelines: [CaptureBenchmarkPipeline] = []
        var notes: [String] = []
        let startedAt = Date()
        let startThermal = LiveBlendController.thermalStateName()

        // Warm-up: the first RAW after a session start pays one-off setup
        // costs that would poison the first row. Excluded from the report.
        await publishStatus("Warming up…")
        _ = await captureBatch(mechanism: .sequential, frames: 1, rep: 0)

        var mechanisms: [Mechanism] = [.sequential]
        if responsiveSupported { mechanisms.append(.responsive) }
        if bracketMax >= 2 { mechanisms.append(.bracketed) }

        let totalBatches = mechanisms.count * Self.blendCounts.count * Self.repetitions
        var batchIndex = 0

        outer: for mechanism in mechanisms {
            // A hot phone throttles the later mechanisms into unfair numbers
            // (first run: bracketed 10:1 slowed 24% across reps at serious).
            if let coolNote = await coolDownIfNeeded(before: mechanism) {
                notes.append(coolNote)
            }
            await configureMechanism(mechanism)
            // Two consecutive zero-delivery batches mean the mechanism has
            // wedged the output — burning 25s timeouts on its remaining
            // batches just heats the phone and poisons what follows.
            var consecutiveEmpty = 0
            mechanismLoop: for frames in Self.blendCounts {
                for rep in 1...Self.repetitions {
                    if benchQueue.sync(execute: { self.cancelRequested }) { break outer }
                    if consecutiveEmpty >= 2 {
                        notes.append("\(mechanism.rawValue): remaining batches skipped after repeated zero-delivery wedge")
                        break mechanismLoop
                    }
                    batchIndex += 1
                    await publishStatus("Batch \(batchIndex)/\(totalBatches) · \(mechanism.rawValue) \(frames):1 rep \(rep) · capturing…")
                    var batch = await captureBatch(mechanism: mechanism, frames: frames, rep: rep)
                    consecutiveEmpty = batch.delivered == 0 ? consecutiveEmpty + 1 : 0
                    if batch.delivered >= 2 {
                        await publishStatus("Batch \(batchIndex)/\(totalBatches) · \(mechanism.rawValue) \(frames):1 rep \(rep) · blending…")
                        pipelines.append(runPipeline(on: batch))
                    }
                    batch.dngs = []
                    batches.append(batch)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }

        await configureMechanism(.sequential)
        benchQueue.sync {
            self.session.stopRunning()
        }

        let cancelled = benchQueue.sync(execute: { self.cancelRequested })
        let report = renderReport(
            batches: batches, pipelines: pipelines,
            startedAt: startedAt, startThermal: startThermal,
            cancelled: cancelled, notes: notes)
        await publishReport(report)
    }

    /// Waits (up to 90s) for thermal state to drop below serious before a
    /// mechanism's batches start. Returns a report note when it waited.
    private func coolDownIfNeeded(before mechanism: Mechanism) async -> String? {
        var waited = 0
        while ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
              waited < 90,
              !benchQueue.sync(execute: { self.cancelRequested }) {
            await publishStatus("Cooling down before \(mechanism.rawValue) (thermal \(LiveBlendController.thermalStateName()))…")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            waited += 5
        }
        guard waited > 0 else { return nil }
        let recovered = ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
        return "\(mechanism.rawValue): waited \(waited)s for cooling\(recovered ? "" : " — still \(LiveBlendController.thermalStateName())")"
    }

    // MARK: Session

    /// Returns a failure description, or nil when the session is live with
    /// a Bayer RAW format probed.
    private func setUpSession() async -> String? {
        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { return "camera access denied" }
        }
        return await withCheckedContinuation { continuation in
            benchQueue.async {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                    continuation.resume(returning: "no back camera")
                    return
                }
                self.cameraName = device.localizedName
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .photo
                    guard self.session.canAddInput(input), self.session.canAddOutput(self.photoOutput) else {
                        self.session.commitConfiguration()
                        continuation.resume(returning: "session refused input/output")
                        return
                    }
                    self.session.addInput(input)
                    self.session.addOutput(self.photoOutput)
                    self.session.commitConfiguration()
                } catch {
                    continuation.resume(returning: "input failed: \(error.localizedDescription)")
                    return
                }
                if let dimensions = device.activeFormat.supportedMaxPhotoDimensions.last {
                    self.photoOutput.maxPhotoDimensions = dimensions
                }
                self.session.startRunning()
                guard let format = self.photoOutput.availableRawPhotoPixelFormatTypes
                    .first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) else {
                    self.session.stopRunning()
                    continuation.resume(returning: "no Bayer RAW format on this camera")
                    return
                }
                self.rawFormat = format
                self.bracketMax = Int(self.photoOutput.maxBracketedCapturePhotoCount)
                if #available(iOS 17.0, *) {
                    self.responsiveSupported = self.photoOutput.isResponsiveCaptureSupported
                }
                // Let 3A settle before the warm-up shot.
                self.benchQueue.asyncAfter(deadline: .now() + 0.7) {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Flips the output's fast-capture state to suit the mechanism (enable
    /// order ZSL → responsive → fast; reverse to disable), mirroring
    /// CameraController's DNG-run configuration.
    private func configureMechanism(_ mechanism: Mechanism) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            benchQueue.async {
                if #available(iOS 17.0, *), self.responsiveSupported {
                    let enable = mechanism == .responsive
                    self.session.beginConfiguration()
                    if enable {
                        if self.photoOutput.isZeroShutterLagSupported {
                            self.photoOutput.isZeroShutterLagEnabled = true
                        }
                        self.photoOutput.isResponsiveCaptureEnabled = true
                        if self.photoOutput.isFastCapturePrioritizationSupported {
                            self.photoOutput.isFastCapturePrioritizationEnabled = true
                        }
                    } else {
                        if self.photoOutput.isFastCapturePrioritizationSupported {
                            self.photoOutput.isFastCapturePrioritizationEnabled = false
                        }
                        self.photoOutput.isResponsiveCaptureEnabled = false
                        if self.photoOutput.isZeroShutterLagSupported {
                            self.photoOutput.isZeroShutterLagEnabled = false
                        }
                    }
                    self.session.commitConfiguration()
                    self.readinessObservation?.invalidate()
                    self.readinessObservation = nil
                    if enable {
                        self.readinessObservation = self.photoOutput.observe(\.captureReadiness) { [weak self] _, _ in
                            self?.benchQueue.async { self?.pumpBatch() }
                        }
                    }
                }
                // The reconfiguration is described as lengthy; give it a beat.
                self.benchQueue.asyncAfter(deadline: .now() + 0.4) {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: Capture batches

    private func captureBatch(mechanism: Mechanism, frames: Int, rep: Int) async -> CaptureBenchmarkBatch {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            benchQueue.async {
                self.batchGeneration += 1
                let generation = self.batchGeneration
                self.batchMechanism = mechanism
                self.batchTarget = frames
                self.batchDNGs = []
                self.batchDeliveryUptimes = []
                self.batchNote = nil
                self.shotsFired = 0
                self.inFlight = 0
                self.collecting = true
                self.batchContinuation = continuation
                self.batchFireUptime = ProcessInfo.processInfo.systemUptime
                self.pumpBatch()
                // A wedged mechanism must not hang the whole benchmark.
                self.benchQueue.asyncAfter(deadline: .now() + 25) {
                    guard generation == self.batchGeneration, self.collecting else { return }
                    self.finishBatch(note: "timeout at \(self.batchDNGs.count)/\(self.batchTarget)")
                }
            }
        }
        return benchQueue.sync {
            let times = batchDeliveryUptimes
            let gaps = zip(times.dropFirst(), times).map(-)
            return CaptureBenchmarkBatch(
                mechanism: mechanism,
                frames: frames,
                rep: rep,
                totalSeconds: (times.last ?? batchFireUptime) - batchFireUptime,
                firstLatencySeconds: (times.first ?? batchFireUptime) - batchFireUptime,
                gapAverage: gaps.isEmpty ? nil : gaps.reduce(0, +) / Double(gaps.count),
                gapMin: gaps.min(),
                gapMax: gaps.max(),
                delivered: batchDNGs.count,
                thermal: LiveBlendController.thermalStateName(),
                note: batchNote,
                dngs: batchDNGs)
        }
    }

    /// benchQueue: fire whatever the current mechanism allows right now.
    private func pumpBatch() {
        guard collecting else { return }
        if cancelRequested {
            finishBatch(note: "cancelled")
            return
        }
        let shotBudget = batchTarget * 2
        while shotsFired < shotBudget {
            let wanted = batchTarget - batchDNGs.count - inFlight
            guard wanted > 0 else { return }
            switch batchMechanism {
            case .sequential:
                guard inFlight == 0 else { return }
                fireSingle()
            case .responsive:
                if #available(iOS 17.0, *) {
                    guard photoOutput.captureReadiness == .ready, inFlight < 3 else { return }
                    fireSingle()
                } else {
                    guard inFlight == 0 else { return }
                    fireSingle()
                }
            case .bracketed:
                guard inFlight == 0 else { return }
                let count = min(wanted, bracketMax)
                if count >= 2 {
                    fireBracket(count)
                } else {
                    fireSingle()
                }
            }
        }
    }

    private func fireSingle() {
        inFlight += 1
        shotsFired += 1
        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        settings.photoQualityPrioritization = .speed
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func fireBracket(_ count: Int) {
        inFlight += 1
        shotsFired += count
        let perFrame = (0..<count).map { _ in
            AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(
                exposureTargetBias: AVCaptureDevice.currentExposureTargetBias)
        }
        let settings = AVCapturePhotoBracketSettings(
            rawPixelFormatType: rawFormat,
            processedFormat: nil,
            bracketedSettings: perFrame)
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func finishBatch(note: String?) {
        guard collecting, let continuation = batchContinuation else { return }
        collecting = false
        batchContinuation = nil
        if let note {
            batchNote = batchNote.map { "\($0); \(note)" } ?? note
        }
        continuation.resume()
    }

    // MARK: Capture delegate (hops to benchQueue)

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        benchQueue.async {
            autoreleasepool {
                guard self.collecting else { return }
                if error != nil {
                    self.batchNote = self.batchNote ?? "capture errors"
                    return
                }
                guard photo.isRawPhoto, let data = photo.fileDataRepresentation() else { return }
                if self.captureDimensions == "unknown", let buffer = photo.pixelBuffer {
                    self.captureDimensions = "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))"
                }
                self.batchDNGs.append(data)
                self.batchDeliveryUptimes.append(ProcessInfo.processInfo.systemUptime)
                if self.batchDNGs.count >= self.batchTarget {
                    self.finishBatch(note: nil)
                } else {
                    self.pumpBatch()
                }
            }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        benchQueue.async {
            self.inFlight = max(0, self.inFlight - 1)
            if error != nil, self.collecting, self.batchMechanism == .bracketed {
                self.finishBatch(note: "bracket rejected")
                return
            }
            self.pumpBatch()
        }
    }

    // MARK: Pipeline stage

    /// The production blend pipeline (LiveBlendRawController.processWindow)
    /// with per-stage clocks: CIRAWFilter graph build → camera-native model
    /// → GPU render → preview → re-mosaic → tiled lossless-JPEG write.
    /// Parameters mirror production exactly so timings transfer.
    private func runPipeline(on batch: CaptureBenchmarkBatch) -> CaptureBenchmarkPipeline {
        // total is stamped by the caller-side wrapper: a `defer` cannot
        // mutate a struct after `return` has copied it (the first report's
        // all-zero total column).
        let start = ProcessInfo.processInfo.systemUptime
        var result = runPipelineBody(on: batch)
        result.totalMillis = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return result
    }

    private func runPipelineBody(on batch: CaptureBenchmarkBatch) -> CaptureBenchmarkPipeline {
        var result = CaptureBenchmarkPipeline(
            mechanism: batch.mechanism, frames: batch.frames, rep: batch.rep,
            graphMillis: 0, renderMillis: 0, matrixMillis: 0, previewMillis: 0,
            mosaicMillis: 0, writeMillis: 0, totalMillis: 0, fileBytes: 0)
        let start = ProcessInfo.processInfo.systemUptime

        var summed: CIImage?
        var decodedCount = 0
        for data in batch.dngs {
            autoreleasepool {
                guard let filter = CIRAWFilter(imageData: data, identifierHint: nil) else { return }
                filter.boostAmount = 0
                guard let image = filter.outputImage else { return }
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
        guard let summed, decodedCount > 0, let referenceData = batch.dngs.first else {
            result.note = "no decodable frames"
            return result
        }
        let cameraModel = try? CameraColorTransform.model(
            from: DNGDocument.parseReference(referenceData))
        result.graphMillis = (ProcessInfo.processInfo.systemUptime - start) * 1000
        guard let cameraModel else {
            result.note = "no camera model — production would fall back to LinearRaw"
            return result
        }

        let renderStart = ProcessInfo.processInfo.systemUptime
        let scale = (1.0 / CGFloat(decodedCount)) / CGFloat(1 << CaptureBenchmarkRunner.headroomStops)
        let scalarAveraged = summed.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let width = Int(scalarAveraged.extent.width)
        let height = Int(scalarAveraged.extent.height)
        var rgba = [UInt16](repeating: 0, count: width * height * 4)
        var wrappedData = Data()
        rgba.withUnsafeMutableBytes { buffer in
            ciContext.render(
                scalarAveraged,
                toBitmap: buffer.baseAddress!,
                rowBytes: width * 8,
                bounds: scalarAveraged.extent,
                format: .RGBA16,
                colorSpace: CaptureBenchmarkRunner.linearColorSpace)
            wrappedData = Data(bytes: buffer.baseAddress!, count: width * height * 8)
        }
        result.renderMillis = (ProcessInfo.processInfo.systemUptime - renderStart) * 1000

        let matrixStart = ProcessInfo.processInfo.systemUptime
        let workingImage = CIImage(
            bitmapData: wrappedData,
            bytesPerRow: width * 8,
            size: CGSize(width: width, height: height),
            format: .RGBA16,
            colorSpace: CaptureBenchmarkRunner.linearColorSpace)
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
                colorSpace: CaptureBenchmarkRunner.linearColorSpace)
        }
        result.matrixMillis = (ProcessInfo.processInfo.systemUptime - matrixStart) * 1000

        let previewStart = ProcessInfo.processInfo.systemUptime
        let preview = benchmarkPreview(from: workingImage)
        result.previewMillis = (ProcessInfo.processInfo.systemUptime - previewStart) * 1000

        let mosaicStart = ProcessInfo.processInfo.systemUptime
        let mosaic = DNGAuthor.mosaic(
            fromRGBA16: rgba, width: width, height: height,
            pattern: [0, 1, 1, 2])
        result.mosaicMillis = (ProcessInfo.processInfo.systemUptime - mosaicStart) * 1000

        let writeStart = ProcessInfo.processInfo.systemUptime
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("benchmark-\(UUID().uuidString).dng")
        do {
            try DNGAuthor.writeCompressedBayerDNG(
                mosaic: mosaic, width: width, height: height,
                cfaPattern: [0, 1, 1, 2],
                cameraColor: cameraModel.tags,
                headroomStops: CaptureBenchmarkRunner.headroomStops,
                preview: preview,
                to: url)
            result.writeMillis = (ProcessInfo.processInfo.systemUptime - writeStart) * 1000
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            result.fileBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            try? FileManager.default.removeItem(at: url)
        } catch {
            result.note = "write failed: \(error.localizedDescription)"
        }
        return result
    }

    /// Mirror of the production embedded-preview render (working-space
    /// average boosted back to display range, 512px).
    private func benchmarkPreview(from averaged: CIImage) -> DNGAuthor.Preview? {
        let boost = CGFloat(1 << CaptureBenchmarkRunner.headroomStops)
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

    // MARK: Report

    private func renderReport(
        batches: [CaptureBenchmarkBatch],
        pipelines: [CaptureBenchmarkPipeline],
        startedAt: Date,
        startThermal: String,
        cancelled: Bool,
        notes: [String]
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines: [String] = []
        lines.append("LetsLapse capture benchmark")
        lines.append("\(LiveBlendController.deviceModelIdentifier()) · \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("\(formatter.string(from: startedAt)) · \(cameraName)")
        lines.append("raw \(captureDimensions) · bracketMax=\(bracketMax) · responsive=\(responsiveSupported ? "yes" : "no")")
        lines.append("thermal start \(startThermal) → end \(LiveBlendController.thermalStateName())")
        lines.append("build \(LiveBlendController.appVersion()) · warm-up shot excluded")
        if cancelled { lines.append("** CANCELLED — partial results **") }
        if !notes.isEmpty {
            lines.append("NOTES")
            for note in notes { lines.append("- \(note)") }
        }
        lines.append("")

        lines.append("CAPTURE — N frames flat-out, no pacing (seconds)")
        lines.append("mech        N rep  total  first  gap-avg  gap-min  gap-max  got  thermal")
        for batch in batches {
            let gapA = batch.gapAverage.map { String(format: "%.2f", $0) } ?? "-"
            let gapN = batch.gapMin.map { String(format: "%.2f", $0) } ?? "-"
            let gapX = batch.gapMax.map { String(format: "%.2f", $0) } ?? "-"
            var line = pad(batch.mechanism.rawValue, 11)
            line += String(format: "%2d  %d  %5.2f  %5.2f  ", batch.frames, batch.rep, batch.totalSeconds, batch.firstLatencySeconds)
            line += pad(gapA, 9) + pad(gapN, 9) + pad(gapX, 9)
            line += pad("\(batch.delivered)/\(batch.frames)", 6) + batch.thermal
            if let note = batch.note { line += "  [\(note)]" }
            lines.append(line)
        }
        lines.append("")

        lines.append("PIPELINE — production blend on each batch (milliseconds)")
        lines.append("mech        N rep  graph  render  matrix  prevw  mosaic  write  total     MB")
        for run in pipelines {
            var line = pad(run.mechanism.rawValue, 11)
            line += String(
                format: "%2d  %d  %5.0f  %6.0f  %6.0f  %5.0f  %6.0f  %5.0f  %5.0f  %5.1f",
                run.frames, run.rep,
                run.graphMillis, run.renderMillis, run.matrixMillis, run.previewMillis,
                run.mosaicMillis, run.writeMillis, run.totalMillis,
                Double(run.fileBytes) / 1_048_576)
            if let note = run.note { line += "  [\(note)]" }
            lines.append(line)
        }
        lines.append("")

        lines.append("SUMMARY")
        for mechanism in Mechanism.allCases {
            let gaps = batches.filter { $0.mechanism == mechanism }.compactMap(\.gapAverage)
            guard !gaps.isEmpty else { continue }
            let gapMedian = median(of: gaps)
            lines.append("capture " + pad(mechanism.rawValue, 11) + String(
                format: "median gap %.2fs  (~%.1f fps)",
                gapMedian, gapMedian > 0 ? 1 / gapMedian : 0))
        }
        if !pipelines.isEmpty {
            let stages: [(String, [Double])] = [
                ("graph", pipelines.map(\.graphMillis)),
                ("render", pipelines.map(\.renderMillis)),
                ("matrix", pipelines.map(\.matrixMillis)),
                ("preview", pipelines.map(\.previewMillis)),
                ("mosaic", pipelines.map(\.mosaicMillis)),
                ("write", pipelines.map(\.writeMillis)),
            ]
            let medians = stages.map { ($0.0, median(of: $0.1)) }
            let total = median(of: pipelines.map(\.totalMillis))
            lines.append(String(format: "pipeline median total %.0fms per output", total))
            if let worst = medians.max(by: { $0.1 < $1.1 }), total > 0 {
                lines.append(String(
                    format: "pipeline pain point: %@ %.0fms (%.0f%% of total)",
                    worst.0 as NSString, worst.1, worst.1 / total * 100))
            }
            for count in Self.blendCounts {
                let totals = pipelines.filter { $0.frames == count }.map(\.totalMillis)
                guard !totals.isEmpty else { continue }
                lines.append(String(format: "pipeline %2d:1 median %.0fms", count, median(of: totals)))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    private func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    // MARK: Publishing

    @MainActor private func publishStatus(_ text: String) {
        statusLine = text
    }

    @MainActor private func publishReport(_ text: String) {
        reportText = text
        statusLine = ""
    }
}

// MARK: - View

/// Settings sheet: run the benchmark, watch progress, copy the report.
struct CaptureBenchmarkView: View {
    @StateObject private var runner = CaptureBenchmarkRunner()
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Captures 3-, 5- and 10-frame RAW batches flat-out under each capture mechanism (3 reps), then times every stage of the DNG blend pipeline on the captured frames. Takes a few minutes; keep the app open and point the camera at a lit scene.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if runner.isRunning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(runner.statusLine.isEmpty ? "Running…" : runner.statusLine)
                                .font(.footnote)
                        }
                        Button("Cancel", role: .destructive) { runner.cancel() }
                    } else {
                        Button {
                            runner.run()
                        } label: {
                            Text(runner.reportText == nil ? "Run benchmark" : "Run again")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let report = runner.reportText {
                        Text(report)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))

                        Button {
                            UIPasteboard.general.string = report
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        } label: {
                            Label(copied ? "Copied" : "Copy results", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationTitle("Capture benchmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .disabled(runner.isRunning)
                }
            }
        }
        .interactiveDismissDisabled(runner.isRunning)
        .onDisappear { runner.cancel() }
    }
}

#endif
