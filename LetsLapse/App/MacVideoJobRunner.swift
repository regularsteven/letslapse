#if os(macOS)
import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import LetsLapseKit

struct MacVideoJobOptions: Sendable {
    var blendWindow: Int
    var outputFPS: Double
    var linearLight: Bool
    var trimHeadTailSeconds: Double
    var maxCPUWorkers: Int
    var maxBlendBatches: Int
}

struct MacVideoJobProgress: Sendable {
    var fraction: Double
    var message: String
    var jobFolderURL: URL
    var recentLogLines: [String]
}

struct MacVideoJobResult: Sendable {
    var outputURL: URL
    var jobFolderURL: URL
    var inputFrames: Int
    var outputFrames: Int
    var width: Int
    var height: Int
}

enum MacVideoJobRunner {
    private struct Manifest: Codable {
        var sourcePath: String
        var sourceName: String
        var blendWindow: Int
        var outputFPS: Double
        var linearLight: Bool
        var trimHeadTailSeconds: Double?
        var maxCPUWorkers: Int
        var maxBlendBatches: Int
        var status: String
        var inputFrames: Int
        var blendedFrames: Int
        var outputPath: String?
        var updatedAt: String
    }

    private struct JobPaths {
        var root: URL
        var manifest: URL
        var log: URL
        var extractedFrames: URL
        var passFrames: URL
        var output: URL
    }

    private static let logLock = NSLock()

    static func run(
        inputURL: URL,
        options: MacVideoJobOptions,
        progress: @escaping @Sendable (MacVideoJobProgress) -> Void
    ) async throws -> MacVideoJobResult {
        let didAccess = inputURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                inputURL.stopAccessingSecurityScopedResource()
            }
        }

        let asset = AVURLAsset(url: inputURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw LapseError.noVideoTrack(inputURL)
        }
        let fps = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        let transform = try await track.load(.preferredTransform)
        let sourceFPS = fps > 0 ? Double(fps) : options.outputFPS
        let trim = max(0, options.trimHeadTailSeconds)
        let sourceDuration = duration.seconds
        guard sourceDuration.isFinite, trim * 2 < sourceDuration else {
            throw LapseError.readerFailed("trim would remove the entire clip")
        }
        let workingDuration = max(0, sourceDuration - (trim * 2))
        let estimatedFrames = max(1, Int((workingDuration * sourceFPS).rounded()))
        let timeRange: CMTimeRange? = trim > 0
            ? CMTimeRange(
                start: CMTime(seconds: trim, preferredTimescale: 600),
                duration: CMTime(seconds: workingDuration, preferredTimescale: 600)
            )
            : nil

        return try await Task.detached(priority: .userInitiated) {
            try runSynchronously(
                inputURL: inputURL,
                asset: asset,
                track: track,
                transform: transform,
                timeRange: timeRange,
                estimatedFrames: estimatedFrames,
                options: options,
                progress: progress
            )
        }.value
    }

    private static func runSynchronously(
        inputURL: URL,
        asset: AVURLAsset,
        track: AVAssetTrack,
        transform: CGAffineTransform,
        timeRange: CMTimeRange?,
        estimatedFrames: Int,
        options: MacVideoJobOptions,
        progress: @escaping @Sendable (MacVideoJobProgress) -> Void
    ) throws -> MacVideoJobResult {
        let paths = try prepareJobFolder(
            for: inputURL,
            blendWindow: options.blendWindow,
            trimHeadTailSeconds: options.trimHeadTailSeconds
        )
        let previousManifest = try? readManifest(from: paths.manifest)
        var manifest = previousManifest ?? Manifest(
            sourcePath: inputURL.path,
            sourceName: inputURL.lastPathComponent,
            blendWindow: options.blendWindow,
            outputFPS: options.outputFPS,
            linearLight: options.linearLight,
            trimHeadTailSeconds: options.trimHeadTailSeconds,
            maxCPUWorkers: options.maxCPUWorkers,
            maxBlendBatches: options.maxBlendBatches,
            status: "created",
            inputFrames: 0,
            blendedFrames: 0,
            outputPath: nil,
            updatedAt: timestamp()
        )

        try appendLog("Created job folder \(paths.root.path)", to: paths.log)
        sendProgress(0, "Created job folder", paths: paths, progress: progress)

        let extractedFrames: [URL]
        let blendedFrames: [URL]
        let canReuseExtraction = ["extracted", "blending", "encoding", "completed"].contains(manifest.status)
        if canReuseExtraction, let existing = try existingExtractedFrames(in: paths.extractedFrames), !existing.isEmpty {
            extractedFrames = existing
            manifest.status = "extracted"
            manifest.inputFrames = existing.count
            manifest.updatedAt = timestamp()
            try writeManifest(manifest, to: paths.manifest)
            try appendLog("Using \(existing.count) previously extracted frames", to: paths.log)
            sendProgress(0.25, "Using \(existing.count) extracted frames", paths: paths, progress: progress)

            manifest.status = "blending"
            manifest.updatedAt = timestamp()
            try writeManifest(manifest, to: paths.manifest)
            blendedFrames = try blendFrames(
                extractedFrames,
                to: paths.passFrames,
                window: max(1, options.blendWindow),
                linearLight: options.linearLight,
                maxBlendBatches: options.maxBlendBatches,
                paths: paths,
                progress: progress
            )
        } else {
            manifest.sourcePath = inputURL.path
            manifest.sourceName = inputURL.lastPathComponent
            manifest.blendWindow = options.blendWindow
            manifest.outputFPS = options.outputFPS
            manifest.linearLight = options.linearLight
            manifest.trimHeadTailSeconds = options.trimHeadTailSeconds
            manifest.maxCPUWorkers = options.maxCPUWorkers
            manifest.maxBlendBatches = options.maxBlendBatches
            manifest.status = "extracting"
            manifest.inputFrames = 0
            manifest.blendedFrames = 0
            manifest.outputPath = nil
            manifest.updatedAt = timestamp()
            try writeManifest(manifest, to: paths.manifest)
            let pipelineResult = try extractAndBlendFrames(
                asset: asset,
                track: track,
                timeRange: timeRange,
                to: paths.extractedFrames,
                blendOutputFolder: paths.passFrames,
                estimatedFrames: estimatedFrames,
                options: options,
                paths: paths,
                progress: progress
            )
            extractedFrames = pipelineResult.extracted
            blendedFrames = pipelineResult.blended
            manifest.status = "extracted"
            manifest.inputFrames = extractedFrames.count
            manifest.blendedFrames = blendedFrames.count
            manifest.updatedAt = timestamp()
            try writeManifest(manifest, to: paths.manifest)
            try appendLog("Pipeline produced \(extractedFrames.count) extracted frames and \(blendedFrames.count) blended frames", to: paths.log)
        }

        guard !extractedFrames.isEmpty else {
            throw LapseError.noInputFrames
        }

        guard !blendedFrames.isEmpty else {
            throw LapseError.noInputFrames
        }

        manifest.status = "encoding"
        manifest.blendedFrames = blendedFrames.count
        manifest.updatedAt = timestamp()
        try writeManifest(manifest, to: paths.manifest)
        let dimensions = try encodeVideo(
            frames: blendedFrames,
            to: paths.output,
            fps: options.outputFPS,
            transform: transform,
            paths: paths,
            progress: progress
        )

        manifest.status = "completed"
        manifest.outputPath = paths.output.path
        manifest.updatedAt = timestamp()
        try writeManifest(manifest, to: paths.manifest)
        try appendLog("Completed output \(paths.output.path)", to: paths.log)
        sendProgress(1, "Completed \(paths.output.lastPathComponent)", paths: paths, progress: progress)

        return MacVideoJobResult(
            outputURL: paths.output,
            jobFolderURL: paths.root,
            inputFrames: extractedFrames.count,
            outputFrames: blendedFrames.count,
            width: dimensions.width,
            height: dimensions.height
        )
    }

    private static func prepareJobFolder(
        for inputURL: URL,
        blendWindow: Int,
        trimHeadTailSeconds: Double
    ) throws -> JobPaths {
        let root = inputURL.deletingPathExtension().appendingPathExtension("letslapse")
        let trim = max(0, trimHeadTailSeconds)
        let trimSuffix = trim > 0 ? String(format: "-trim-%0.1fs-each-end", trim) : ""
        let passName = String(format: "blend-%03d-to-001%@", max(1, blendWindow), trimSuffix)
        let extractionName = trim > 0 ? "extracted\(trimSuffix)" : "extracted"
        let paths = JobPaths(
            root: root,
            manifest: root.appendingPathComponent("manifest.json"),
            log: root.appendingPathComponent("logs/job.log"),
            extractedFrames: root.appendingPathComponent("frames/\(extractionName)"),
            passFrames: root.appendingPathComponent("passes/\(passName)"),
            output: root.appendingPathComponent("output/\(inputURL.deletingPathExtension().lastPathComponent)-\(passName).mp4")
        )

        let folders = [
            paths.root,
            paths.log.deletingLastPathComponent(),
            paths.extractedFrames,
            paths.passFrames,
            paths.output.deletingLastPathComponent(),
        ]
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return paths
    }

    private static func extractFrames(
        asset: AVURLAsset,
        track: AVAssetTrack,
        to folder: URL,
        estimatedFrames: Int,
        paths: JobPaths,
        progress: @escaping @Sendable (MacVideoJobProgress) -> Void
    ) throws -> [URL] {
        try appendLog("Extracting frames", to: paths.log)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw LapseError.readerFailed("cannot attach track output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw LapseError.readerFailed(reader.error?.localizedDescription ?? "could not start decoding")
        }

        let context = CIContext()
        var frameURLs: [URL] = []
        var frameIndex = 0
        let started = Date()

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            frameIndex += 1
            let url = folder.appendingPathComponent(String(format: "frame-%06d.png", frameIndex))
            if !FileManager.default.fileExists(atPath: url.path) {
                let image = CIImage(cvPixelBuffer: pixelBuffer)
                let rect = CGRect(
                    x: 0,
                    y: 0,
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer)
                )
                guard let cgImage = context.createCGImage(image, from: rect) else {
                    throw LapseError.imageEncodeFailed("could not render extracted frame \(frameIndex)")
                }
                try ImageExporter.write(cgImage, to: url, format: .png)
            }
            frameURLs.append(url)

            if frameIndex == 1 || frameIndex % 10 == 0 {
                let fraction = Double(frameIndex) / Double(max(estimatedFrames, frameIndex))
                let message = "Extracting frames \(frameIndex) / \(max(estimatedFrames, frameIndex)) \(etaText(started: started, completed: frameIndex, total: max(estimatedFrames, frameIndex)))"
                sendProgress(0.05 + min(0.35, fraction * 0.35), message, paths: paths, progress: progress)
            }
        }

        if reader.status == .failed {
            throw LapseError.readerFailed(reader.error?.localizedDescription ?? "decode error")
        }
        return frameURLs
    }

    private static func extractAndBlendFrames(
        asset: AVURLAsset,
        track: AVAssetTrack,
        timeRange: CMTimeRange?,
        to extractionFolder: URL,
        blendOutputFolder: URL,
        estimatedFrames: Int,
        options: MacVideoJobOptions,
        paths: JobPaths,
        progress: @escaping @Sendable (MacVideoJobProgress) -> Void
    ) throws -> (extracted: [URL], blended: [URL]) {
        let jobStarted = Date()
        let window = max(1, options.blendWindow)
        let estimatedOutputFrames = max(1, Int(ceil(Double(estimatedFrames) / Double(window))))
        try appendLog(
            "Starting pipelined extraction + \(window)-to-1 blend; CPU workers \(max(1, options.maxCPUWorkers)), blend batches \(max(1, options.maxBlendBatches))",
            to: paths.log
        )

        let reader = try AVAssetReader(asset: asset)
        if let timeRange {
            reader.timeRange = timeRange
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw LapseError.readerFailed("cannot attach track output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw LapseError.readerFailed(reader.error?.localizedDescription ?? "could not start decoding")
        }

        let context = CIContext()
        let blendSemaphore = DispatchSemaphore(value: max(1, options.maxBlendBatches))
        let blendGroup = DispatchGroup()
        let stateLock = NSLock()
        var extractedFrames: [URL] = []
        var blendedFrames: [URL] = []
        var firstError: Error?
        var frameIndex = 0
        var outputIndex = 0
        var currentWindow: [URL] = []
        var completedBlendFrames = 0

        func setError(_ error: Error) {
            stateLock.lock()
            if firstError == nil {
                firstError = error
            }
            stateLock.unlock()
        }

        func currentError() -> Error? {
            stateLock.lock()
            defer { stateLock.unlock() }
            return firstError
        }

        func scheduleBlend(_ frameURLs: [URL], outputNumber: Int) {
            let outputURL = blendOutputFolder.appendingPathComponent(String(format: "frame-%06d.png", outputNumber))

            if FileManager.default.fileExists(atPath: outputURL.path) {
                stateLock.lock()
                blendedFrames.append(outputURL)
                completedBlendFrames += 1
                let completed = completedBlendFrames
                stateLock.unlock()
                if completed == 1 || completed % 5 == 0 {
                    sendProgress(
                        0.25 + min(0.60, Double(completed) / Double(estimatedOutputFrames) * 0.60),
                        "Reusing blended frames \(completed) / \(estimatedOutputFrames)",
                        paths: paths,
                        progress: progress
                    )
                }
                return
            }

            blendSemaphore.wait()
            blendGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    blendSemaphore.signal()
                    blendGroup.leave()
                }
                do {
                    try Task.checkCancellation()
                    let core = try BlendCore()
                    let stacker = ImageStacker(core: core)
                    let image = try stacker.stack(imageURLs: frameURLs, linearLight: options.linearLight)
                    try ImageExporter.write(image, to: outputURL, format: .png)

                    stateLock.lock()
                    blendedFrames.append(outputURL)
                    completedBlendFrames += 1
                    let completed = completedBlendFrames
                    stateLock.unlock()

                    if completed == 1 || completed % 5 == 0 || completed == estimatedOutputFrames {
                        let message = "Blending \(window)-to-1 \(completed) / \(estimatedOutputFrames) \(etaText(started: jobStarted, completed: completed, total: estimatedOutputFrames))"
                        sendProgress(
                            0.25 + min(0.60, Double(completed) / Double(estimatedOutputFrames) * 0.60),
                            message,
                            paths: paths,
                            progress: progress
                        )
                    }
                } catch {
                    setError(error)
                }
            }
        }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if let error = currentError() {
                throw error
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            frameIndex += 1
            let url = extractionFolder.appendingPathComponent(String(format: "frame-%06d.png", frameIndex))
            if !FileManager.default.fileExists(atPath: url.path) {
                let image = CIImage(cvPixelBuffer: pixelBuffer)
                let rect = CGRect(
                    x: 0,
                    y: 0,
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer)
                )
                guard let cgImage = context.createCGImage(image, from: rect) else {
                    throw LapseError.imageEncodeFailed("could not render extracted frame \(frameIndex)")
                }
                try ImageExporter.write(cgImage, to: url, format: .png)
            }
            extractedFrames.append(url)
            currentWindow.append(url)

            if currentWindow.count == window {
                outputIndex += 1
                scheduleBlend(currentWindow, outputNumber: outputIndex)
                currentWindow.removeAll(keepingCapacity: true)
            }

            if frameIndex == 1 || frameIndex % 10 == 0 {
                let fraction = Double(frameIndex) / Double(max(estimatedFrames, frameIndex))
                let message = "Extracting frames \(frameIndex) / \(max(estimatedFrames, frameIndex)) \(etaText(started: jobStarted, completed: frameIndex, total: max(estimatedFrames, frameIndex)))"
                sendProgress(0.05 + min(0.35, fraction * 0.35), message, paths: paths, progress: progress)
            }
        }

        if !currentWindow.isEmpty {
            outputIndex += 1
            scheduleBlend(currentWindow, outputNumber: outputIndex)
        }

        if reader.status == .failed {
            throw LapseError.readerFailed(reader.error?.localizedDescription ?? "decode error")
        }

        blendGroup.wait()
        if let error = currentError() {
            throw error
        }

        let elapsed = Date().timeIntervalSince(jobStarted)
        try appendLog(
            "Pipeline finished: \(frameIndex) extracted, \(blendedFrames.count) blended in \(formatDuration(elapsed)) (\(String(format: "%.2f", Double(max(frameIndex, 1)) / max(elapsed, 0.001))) source fps processed)",
            to: paths.log
        )
        return (
            extractedFrames.sorted { $0.lastPathComponent < $1.lastPathComponent },
            blendedFrames.sorted { $0.lastPathComponent < $1.lastPathComponent }
        )
    }

    private static func blendFrames(
        _ frameURLs: [URL],
        to folder: URL,
        window: Int,
        linearLight: Bool,
        maxBlendBatches: Int,
        paths: JobPaths,
        progress: @escaping @Sendable (MacVideoJobProgress) -> Void
    ) throws -> [URL] {
        try appendLog("Blending \(window) frames to 1 with \(max(1, maxBlendBatches)) concurrent batches", to: paths.log)
        let outputCount = Int(ceil(Double(frameURLs.count) / Double(window)))
        let started = Date()
        let semaphore = DispatchSemaphore(value: max(1, maxBlendBatches))
        let group = DispatchGroup()
        let lock = NSLock()
        var outputs: [URL] = []
        var completed = 0
        var firstError: Error?

        for outputIndex in 0..<outputCount {
            try Task.checkCancellation()
            let outputURL = folder.appendingPathComponent(String(format: "frame-%06d.png", outputIndex + 1))
            if !FileManager.default.fileExists(atPath: outputURL.path) {
                let start = outputIndex * window
                let end = min(frameURLs.count, start + window)
                let windowURLs = Array(frameURLs[start..<end])
                semaphore.wait()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer {
                        semaphore.signal()
                        group.leave()
                    }
                    do {
                        let core = try BlendCore()
                        let stacker = ImageStacker(core: core)
                        let image = try stacker.stack(imageURLs: windowURLs, linearLight: linearLight)
                        try ImageExporter.write(image, to: outputURL, format: .png)
                        lock.lock()
                        outputs.append(outputURL)
                        completed += 1
                        let done = completed
                        lock.unlock()
                        if done == 1 || done % 5 == 0 || done == outputCount {
                            let message = "Blending \(window)-to-1 \(done) / \(outputCount) \(etaText(started: started, completed: done, total: outputCount))"
                            sendProgress(0.40 + Double(done) / Double(outputCount) * 0.45, message, paths: paths, progress: progress)
                        }
                    } catch {
                        lock.lock()
                        if firstError == nil {
                            firstError = error
                        }
                        lock.unlock()
                    }
                }
            } else {
                lock.lock()
                outputs.append(outputURL)
                completed += 1
                lock.unlock()
            }
        }
        group.wait()
        if let firstError {
            throw firstError
        }

        let elapsed = Date().timeIntervalSince(started)
        try appendLog("Blended \(outputs.count) output frames in \(formatDuration(elapsed))", to: paths.log)
        return outputs.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func encodeVideo(
        frames: [URL],
        to outputURL: URL,
        fps: Double,
        transform: CGAffineTransform,
        paths: JobPaths,
        progress: @escaping @Sendable (MacVideoJobProgress) -> Void
    ) throws -> (width: Int, height: Int) {
        guard let first = try loadImage(at: frames[0]) else {
            throw LapseError.imageLoadFailed(frames[0])
        }
        try? FileManager.default.removeItem(at: outputURL)
        try appendLog("Encoding \(frames.count) frames to \(outputURL.lastPathComponent)", to: paths.log)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: first.width,
            AVVideoHeightKey: first.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: first.width,
                kCVPixelBufferHeightKey as String: first.height,
            ]
        )
        guard writer.canAdd(input) else {
            throw LapseError.writerFailed("cannot attach video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw LapseError.writerFailed(writer.error?.localizedDescription ?? "could not start encoding")
        }
        writer.startSession(atSourceTime: .zero)

        let started = Date()
        for (index, frameURL) in frames.enumerated() {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                usleep(2000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw LapseError.writerFailed("no pixel buffer pool")
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw LapseError.writerFailed("output buffer allocation failed (\(status))")
            }
            guard let image = try loadImage(at: frameURL) else {
                throw LapseError.imageLoadFailed(frameURL)
            }
            try draw(image, into: pixelBuffer)
            let time = CMTime(value: Int64((Double(index) / fps * 60000).rounded()), timescale: 60000)
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw LapseError.writerFailed(writer.error?.localizedDescription ?? "frame append failed")
            }

            if index == 0 || (index + 1) % 10 == 0 || index + 1 == frames.count {
                let completed = index + 1
                let message = "Encoding video \(completed) / \(frames.count) \(etaText(started: started, completed: completed, total: frames.count))"
                sendProgress(0.85 + Double(completed) / Double(frames.count) * 0.14, message, paths: paths, progress: progress)
            }
        }

        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw LapseError.writerFailed(writer.error?.localizedDescription ?? "could not finalize file")
        }
        return (first.width, first.height)
    }

    private static func draw(_ image: CGImage, into pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw LapseError.writerFailed("could not draw output frame")
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw LapseError.writerFailed("could not create frame drawing context")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func loadImage(at url: URL) throws -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func existingExtractedFrames(in folder: URL) throws -> [URL]? {
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "png" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return urls
    }

    private static func writeManifest(_ manifest: Manifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private static func readManifest(from url: URL) throws -> Manifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private static func appendLog(_ line: String, to url: URL) throws {
        let text = "[\(timestamp())] \(line)\n"
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private static func recentLogLines(from url: URL, limit: Int = 8) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(limit)).map(String.init)
    }

    private static func sendProgress(
        _ fraction: Double,
        _ message: String,
        paths: JobPaths,
        progress: @escaping @Sendable (MacVideoJobProgress) -> Void
    ) {
        try? appendLog(message, to: paths.log)
        progress(MacVideoJobProgress(
            fraction: min(max(fraction, 0), 1),
            message: message,
            jobFolderURL: paths.root,
            recentLogLines: recentLogLines(from: paths.log)
        ))
    }

    private static func etaText(started: Date, completed: Int, total: Int) -> String {
        guard completed > 0, total > completed else { return "" }
        let elapsed = Date().timeIntervalSince(started)
        let secondsPerUnit = elapsed / Double(completed)
        let remaining = secondsPerUnit * Double(total - completed)
        return "ETA \(formatDuration(remaining))"
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        let minutes = rounded / 60
        let seconds = rounded % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
#endif
