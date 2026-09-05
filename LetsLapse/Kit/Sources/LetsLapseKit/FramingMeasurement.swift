import Foundation
import Accelerate
import ImageIO
#if canImport(CoreImage)
import CoreImage
#endif

/// Measures where every photo of an interval shoot sits against one
/// reference framing — the "Review photos" pass behind `FramingReview`.
///
/// The photos are correlated in chunks of `chunk` frames: each frame against
/// its chunk's first frame (the anchor), and each anchor against the last
/// frame of the chunk before it, so the whole-shoot path accumulates
/// measurement error once per chunk rather than once per photo, and a
/// sunset-to-night shoot stays confident because no anchor is ever far from
/// the frames it judges (frame 1 against frame 5030 correlated at 0.22 on
/// E33ED216; thirty frames apart, 0.88). Checked against direct long-baseline
/// measurements: ≤ 0.7 px disagreement over 1000-frame spans.
///
/// Chunks run in parallel across `workers` threads; the luma provider is
/// therefore called concurrently and must be thread-safe (`FramingLumaDecoder`
/// is). Progress and cancellation callbacks arrive on worker threads.
public enum FramingMeasurement {

    /// Full-resolution pixel size of the frames the offsets describe.
    public struct FrameSize: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public typealias LumaProvider = @Sendable (URL) throws -> LumaPlane

    /// How many frames share an anchor.
    public static let defaultChunk = 30

    /// Measures `urls` in order. `scale` is the ratio of the provider's planes
    /// to the full frame (0.5 = half size); offsets come back in FULL-size
    /// pixels. Frames whose plane is a different size from their chunk's
    /// anchor are reported at the anchor's offset with zero confidence — a
    /// mixed-size shoot is not this pass's problem to solve.
    public static func measure(
        urls: [URL],
        scale: Double,
        luma: @escaping LumaProvider,
        chunk: Int = defaultChunk,
        workers: Int = defaultWorkers,
        progress: (@Sendable (Double) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> [FramingReview.Offset] {
        let n = urls.count
        guard n > 0 else { return [] }
        let chunkLength = max(2, chunk)
        let jobs = stride(from: 0, to: n, by: chunkLength).map { lo in (lo: lo, hi: min(n, lo + chunkLength)) }

        struct ChunkResult {
            var lo: Int
            /// The anchor's shift from the previous chunk's last frame (zero for the first chunk).
            var boundary: PhaseCorrelator.Shift
            /// Per frame in the chunk: shift from the anchor.
            var shifts: [PhaseCorrelator.Shift]
        }

        final class Shared: @unchecked Sendable {
            let lock = NSLock()
            var nextJob = 0
            var done = 0
            var results: [ChunkResult?]
            var failure: Error?
            init(count: Int) { results = Array(repeating: nil, count: count) }
        }
        let shared = Shared(count: jobs.count)
        let workerCount = max(1, min(workers, jobs.count))
        let group = DispatchGroup()

        for _ in 0..<workerCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                var correlator: PhaseCorrelator?
                while true {
                    shared.lock.lock()
                    let jobIndex = shared.nextJob
                    let failed = shared.failure != nil
                    if jobIndex < jobs.count { shared.nextJob += 1 }
                    shared.lock.unlock()
                    guard jobIndex < jobs.count, !failed else { return }
                    let job = jobs[jobIndex]
                    do {
                        let result = try measureChunk(
                            urls: urls, lo: job.lo, hi: job.hi, luma: luma,
                            correlator: &correlator, isCancelled: isCancelled,
                            frameDone: {
                                shared.lock.lock()
                                shared.done += 1
                                let done = shared.done
                                shared.lock.unlock()
                                progress?(Double(done) / Double(n))
                            })
                        shared.lock.lock()
                        shared.results[jobIndex] = ChunkResult(
                            lo: result.lo, boundary: result.boundary, shifts: result.shifts)
                        shared.lock.unlock()
                    } catch {
                        shared.lock.lock()
                        if shared.failure == nil { shared.failure = error }
                        shared.lock.unlock()
                        return
                    }
                }
            }
        }
        group.wait()
        if let failure = shared.failure { throw failure }

        // Chain: a chunk's anchor sits at the previous chunk's last frame
        // plus the boundary shift; every frame in it sits at anchor + shift.
        var offsets: [FramingReview.Offset] = []
        offsets.reserveCapacity(n)
        var lastX = 0.0, lastY = 0.0
        let toFull = 1 / max(scale, 1e-6)
        for result in shared.results.compactMap({ $0 }) {
            let baseX = lastX + result.boundary.dx * toFull
            let baseY = lastY + result.boundary.dy * toFull
            for (offset, shift) in result.shifts.enumerated() {
                let index = result.lo + offset
                let x = baseX + shift.dx * toFull
                let y = baseY + shift.dy * toFull
                offsets.append(FramingReview.Offset(
                    name: urls[index].lastPathComponent, dx: x, dy: y,
                    confidence: min(max(shift.response, 0), 1)))
                lastX = x
                lastY = y
            }
        }
        return offsets
    }

    private static func measureChunk(
        urls: [URL], lo: Int, hi: Int, luma: LumaProvider,
        correlator: inout PhaseCorrelator?,
        isCancelled: (@Sendable () -> Bool)?,
        frameDone: () -> Void
    ) throws -> (lo: Int, boundary: PhaseCorrelator.Shift, shifts: [PhaseCorrelator.Shift]) {
        func correlatorFor(_ plane: LumaPlane) -> PhaseCorrelator {
            if let existing = correlator, existing.width == plane.width, existing.height == plane.height {
                return existing
            }
            let made = PhaseCorrelator(width: plane.width, height: plane.height)
            correlator = made
            return made
        }
        var previous: PhaseCorrelator.Spectrum?
        var previousSize: (Int, Int)?
        if lo > 0 {
            if isCancelled?() == true { throw CancellationError() }
            let plane = try luma(urls[lo - 1])
            previous = correlatorFor(plane).spectrum(of: plane)
            previousSize = (plane.width, plane.height)
        }
        var anchor: PhaseCorrelator.Spectrum?
        var anchorSize: (Int, Int)?
        var boundary = PhaseCorrelator.Shift(dx: 0, dy: 0, response: 1)
        var shifts: [PhaseCorrelator.Shift] = []
        shifts.reserveCapacity(hi - lo)
        for index in lo..<hi {
            if isCancelled?() == true { throw CancellationError() }
            let plane = try luma(urls[index])
            let size = (plane.width, plane.height)
            if index == lo {
                let engine = correlatorFor(plane)
                let spectrum = engine.spectrum(of: plane)
                if let previous, let previousSize, previousSize == size {
                    boundary = engine.shift(from: previous, to: spectrum)
                }
                anchor = spectrum
                anchorSize = size
                shifts.append(PhaseCorrelator.Shift(dx: 0, dy: 0, response: 1))
            } else if let anchor, let anchorSize, anchorSize == size {
                let engine = correlatorFor(plane)
                shifts.append(engine.shift(from: anchor, to: engine.spectrum(of: plane)))
            } else {
                shifts.append(PhaseCorrelator.Shift(dx: 0, dy: 0, response: 0))
            }
            frameDone()
        }
        return (lo, boundary, shifts)
    }

    /// Enough workers to keep a Mac busy without a phone running out of
    /// memory: each holds ~130 MB of spectra at half size plus its decode.
    /// The raw decode dominates (~0.3 s a frame for a 12 MP lossless-JPEG
    /// DNG at half size, CPU-bound), so the Mac scales with cores.
    public static var defaultWorkers: Int {
        #if os(macOS)
        return max(1, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
        #else
        return 2
        #endif
    }

    /// The full pixel size of the image at `url`, from its header — no decode.
    public static func fullSize(of url: URL) -> FrameSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // Orientation 5–8 swap the stored axes; the offsets live in the
        // displayed frame, the same space the decoders hand back.
        if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 {
            return FrameSize(width: height, height: width)
        }
        return FrameSize(width: width, height: height)
    }

    /// Log-compresses a linear plane in place: `log1p(v × gain)`, negatives
    /// clamped first. Exposure-robust — a stop of change becomes a constant
    /// offset the high-pass removes.
    public static func logCompress(_ plane: inout LumaPlane, gain: Float = 4096) {
        var count = Int32(plane.pixels.count)
        var floor: Float = 0
        var g = gain
        plane.pixels.withUnsafeMutableBufferPointer { buffer in
            vDSP_vthr(buffer.baseAddress!, 1, &floor, buffer.baseAddress!, 1, vDSP_Length(buffer.count))
            vDSP_vsmul(buffer.baseAddress!, 1, &g, buffer.baseAddress!, 1, vDSP_Length(buffer.count))
            vvlog1pf(buffer.baseAddress!, buffer.baseAddress!, &count)
        }
    }
}

#if canImport(CoreImage)
/// Decodes a still to a reduced-size, log-compressed luma plane for the
/// measurement. Raw files go through `CIRAWFilter` at `scale` (draft mode —
/// the converter's fast path; the correlation only needs shapes), everything
/// else through ImageIO's thumbnail path at the same scale. Thread-safe,
/// and parallel: a Core Image context serialises its renders, so callers
/// on different threads each get their own from a small pool (one shared
/// context held eight workers to 191% CPU on E33ED216).
public final class FramingLumaDecoder: @unchecked Sendable {
    public let scale: Double
    private let colorSpace: CGColorSpace
    private let lock = NSLock()
    private var idleContexts: [CIContext] = []

    public init(scale: Double = 0.5) {
        self.scale = scale
        colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? CGColorSpaceCreateDeviceRGB()
    }

    private func acquireContext() -> CIContext {
        lock.lock()
        defer { lock.unlock() }
        if let context = idleContexts.popLast() { return context }
        return CIContext(options: [
            .workingColorSpace: colorSpace,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ])
    }

    private func release(_ context: CIContext) {
        lock.lock()
        idleContexts.append(context)
        lock.unlock()
    }

    public func luma(at url: URL) throws -> LumaPlane {
        let image = try decode(url)
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width >= 16, height >= 16 else { throw LapseError.imageLoadFailed(url) }
        var rgba = [Float](repeating: 0, count: width * height * 4)
        let context = acquireContext()
        rgba.withUnsafeMutableBytes { buffer in
            context.render(
                image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                bounds: extent, format: .RGBAf, colorSpace: colorSpace)
        }
        release(context)
        var pixels = [Float](repeating: 0, count: width * height)
        // Rec. 709 luma over the linear channels.
        var weights: [Float] = [0.2126, 0.7152, 0.0722]
        rgba.withUnsafeBufferPointer { source in
            pixels.withUnsafeMutableBufferPointer { destination in
                for (index, weight) in weights.enumerated() {
                    var w = weight
                    vDSP_vsma(source.baseAddress! + index, 4, &w, destination.baseAddress!, 1, destination.baseAddress!, 1, vDSP_Length(width * height))
                }
            }
        }
        weights.removeAll()
        var plane = LumaPlane(width: width, height: height, pixels: pixels)
        FramingMeasurement.logCompress(&plane)
        return plane
    }

    private func decode(_ url: URL) throws -> CIImage {
        if ImportedStills.isRaw(url), let raw = LossyLinearDNG.rawFilter(for: url) {
            raw.scaleFactor = Float(scale)
            raw.isDraftModeEnabled = true
            raw.boostAmount = 0
            guard let image = raw.outputImage else { throw LapseError.imageLoadFailed(url) }
            return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw LapseError.imageLoadFailed(url)
        }
        var longSide = 20000
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            longSide = Int((Double(max(width, height)) * scale).rounded())
        }
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, longSide),
        ] as CFDictionary) else {
            throw LapseError.imageLoadFailed(url)
        }
        return CIImage(cgImage: decoded)
    }
}
#endif
