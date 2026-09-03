import CoreGraphics
import CoreVideo
import Foundation
import Metal

/// The poster fast path — `docs/time-slicing-poster-fast-path.md`.
///
/// A time-slice poster needs one master frame per band (or grid cell), not
/// the whole blended clip. When the run keeps nothing but the poster, the
/// frames it needs can be rendered on their own — still blended at the chosen
/// depth, through the same window primitive the sequence render uses — and
/// everything else (the encode, the verify, the count, the re-decode) is
/// skipped. This file holds the indexed provider the pass reads from and the
/// pass itself; the band geometry is the tail pass's, reused verbatim.

/// A random-access source of master frames, where `OrderedFrameProvider` is
/// sequential: the poster ladder names its frames up front, so the pass asks
/// for exactly those, in ascending order, and nothing else.
public protocol IndexedFrameProvider: AnyObject {
    /// M — the master's frame count, known from the schedule before any
    /// pixel is touched.
    var frameCount: Int { get }
    /// The master's pixel size — every frame is exactly this.
    var width: Int { get }
    var height: Int { get }
    /// The master's display transform (identity for stills, whose decode
    /// bakes orientation in).
    var transform: CGAffineTransform { get }
    /// Master frame `index`, rendered. 32BGRA.
    func frame(at index: Int) throws -> TimeSliceFrame
}

/// Master frames of a stills blend, one window at a time: window `m` of the
/// schedule accumulated, graded and finished exactly as `stackSequenceLinear`
/// (or the gamma-domain `stackSequence`) would have written frame `m` — minus
/// the codec. Sized from still 0 always, as the stacker sizes every stack
/// from its first still, even when still 0 is in no window the poster needs
/// (plan §10): otherwise a shoot whose first frames differ in size from the
/// rest would size the poster differently from the master it represents.
public final class StillsWindowProvider: IndexedFrameProvider {

    /// How stills reach the accumulator — the two paths the app's blend has.
    public enum Decode {
        /// The tone-engine path: scene-linear half-float textures in, the
        /// grade applied once per output frame at its source position.
        case linear(
            decode: (URL) throws -> MTLTexture,
            grade: ((MTLTexture, MTLCommandBuffer, Double) throws -> MTLTexture)?)
        /// The legacy 8-bit path: graded CGImages in (`linearLight` marks
        /// them sRGB so the average is true-light), no output grade.
        case gamma(load: (URL) throws -> CGImage, linearLight: Bool)
    }

    public let frameCount: Int
    public let width: Int
    public let height: Int
    public let transform: CGAffineTransform = .identity
    /// Every still decoded so far — the number progress is reported in,
    /// because decodes are the cost.
    public private(set) var stillsDecoded = 0

    private let core: BlendCore
    private let stacker: ImageStacker
    private let urls: [URL]
    private let windows: [Int]
    /// Prefix sums: master index → first still of its window.
    private let windowStarts: [Int]
    private let decode: Decode
    private let overlayComposite: ((CVPixelBuffer, Double, CVPixelBufferPool) throws -> CVPixelBuffer?)?
    private let renderer: BlendWindowRenderer
    private let pool: CVPixelBufferPool
    private let onStillDecoded: ((Int) -> Void)?
    private let isCancelled: () -> Bool
    /// Still 0, decoded for the size and kept only until the first window
    /// is served — if that window starts at 0 it is reused, not re-decoded.
    private var firstTexture: MTLTexture?

    /// `windows` must sum to `urls.count` — the identical schedule the full
    /// render would run, from the identical inputs (plan §3.1). Decodes
    /// still 0 here, so construct it where the render runs.
    public init(
        core: BlendCore,
        urls: [URL],
        windows: [Int],
        decode: Decode,
        overlayComposite: ((CVPixelBuffer, Double, CVPixelBufferPool) throws -> CVPixelBuffer?)? = nil,
        onStillDecoded: ((Int) -> Void)? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) throws {
        guard !urls.isEmpty, !windows.isEmpty else { throw LapseError.noInputFrames }
        guard windows.allSatisfy({ $0 >= 1 }), windows.reduce(0, +) == urls.count else {
            throw LapseError.writerFailed("window schedule doesn't match the input frames")
        }
        self.core = core
        stacker = ImageStacker(core: core)
        self.urls = urls
        self.windows = windows
        var starts: [Int] = []
        starts.reserveCapacity(windows.count)
        var cursor = 0
        for window in windows {
            starts.append(cursor)
            cursor += window
        }
        windowStarts = starts
        frameCount = windows.count
        self.decode = decode
        self.overlayComposite = overlayComposite
        self.onStillDecoded = onStillDecoded
        self.isCancelled = isCancelled

        let first = try Self.decodeTexture(urls[0], decode: decode, stacker: stacker)
        width = first.width
        height = first.height
        firstTexture = first
        stillsDecoded = 1
        onStillDecoded?(1)

        // Always the 8-bit BGRA policy: the poster is an 8-bit PNG composed
        // from 32BGRA bands, and the tail pass's poster came out of a BGRA
        // decode too. The gamut conversion to 709 (= sRGB, the PNG's tag) is
        // the correct one for a still; a 10-bit run's poster gains nothing
        // from a half-float buffer it would be quantised out of anyway.
        let policy = VideoEncodePolicy(
            profile: .h264High8Bit, width: width, height: height, fps: 30)
        switch decode {
        case .linear:
            renderer = try BlendWindowRenderer.linear(
                core: core, width: width, height: height, policy: policy)
        case .gamma(_, let linearLight):
            renderer = try BlendWindowRenderer.gamma(
                core: core, width: width, height: height, policy: policy, linearLight: linearLight)
        }
        pool = try renderer.makePixelBufferPool()
    }

    private static func decodeTexture(
        _ url: URL, decode: Decode, stacker: ImageStacker
    ) throws -> MTLTexture {
        switch decode {
        case .linear(let decodeLinear, _):
            return try decodeLinear(url)
        case .gamma(let load, let linearLight):
            return try stacker.makeInputTexture(try load(url), srgb: linearLight)
        }
    }

    /// The source stills master frame `index` averages: `[start, start + window)`.
    public func sourceRange(of index: Int) -> Range<Int> {
        let start = windowStarts[index]
        return start..<(start + windows[index])
    }

    public func frame(at index: Int) throws -> TimeSliceFrame {
        guard windows.indices.contains(index) else {
            throw LapseError.readerFailed("master frame \(index) is outside the schedule (\(frameCount) frames)")
        }
        if isCancelled() || Task.isCancelled { throw LapseError.cancelled }
        let start = windowStarts[index]
        let window = windows[index]
        let cached = start == 0 ? firstTexture : nil
        // Whatever happens below, still 0's texture is dropped after the
        // first window: the walk is ascending, so if window 0 wasn't the
        // first request it is never requested.
        firstTexture = nil
        let outputGrade: ((MTLTexture, MTLCommandBuffer, Double) throws -> MTLTexture)?
        if case .linear(_, let grade) = decode { outputGrade = grade } else { outputGrade = nil }
        let buffer = try renderer.render(
            frameCount: window,
            texture: { offset in
                if offset == 0, let cached { return cached }
                if self.isCancelled() { throw LapseError.cancelled }
                let texture = try Self.decodeTexture(
                    self.urls[start + offset], decode: self.decode, stacker: self.stacker)
                self.stillsDecoded += 1
                self.onStillDecoded?(self.stillsDecoded)
                return texture
            },
            // The position the full render's hooks would have seen for this
            // window — the keyframed grade ladder is quantised from it.
            sourcePosition: ImageStacker.sourcePosition(
                windowStart: start, window: window, totalFrames: urls.count),
            frameIndex: index,
            pool: pool,
            outputGrade: outputGrade,
            overlayComposite: overlayComposite)
        core.flushTextureCache()
        return TimeSliceFrame(pixelBuffer: buffer, seconds: 0)
    }
}

extension TimeSliceRenderer {

    /// The master frames a set of poster recipes needs, ascending and
    /// deduplicated — the union of every recipe's ladder. What the fast path
    /// walks, and what the Adjust card quotes as the cost
    /// ("renders 24 of 350 frames"). Throws the recipe's own refusal when a
    /// recipe can't lay its bands on this frame.
    public static func posterFrameIndices(
        recipes: [TimeSliceSettings], masterFrames: Int,
        width: Int, height: Int, transform: CGAffineTransform = .identity
    ) throws -> [Int] {
        var union = Set<Int>()
        for recipe in recipes {
            let plan = try makePlan(
                settings: recipe, width: width, height: height,
                transform: transform, masterFrames: masterFrames, wantsPoster: true)
            union.formUnion(plan.posterCells.keys)
        }
        return union.sorted()
    }

    /// Renders one poster per recipe from an indexed master, decoding each
    /// master frame the recipes share exactly once: the union of their
    /// ladders is walked in ascending order and every frame's bands are
    /// copied into each recipe's own composite. Geometry is `makePlan`'s —
    /// byte-identical to the tail pass's poster layout — and the finished
    /// image goes through the same orientation and export.
    ///
    /// One poster buffer per recipe is live for the whole walk
    /// (`width × height × 4` bytes each — ~49 MB at 12 MP), which is why a
    /// caller with a memory budget passes the batch in chunks rather than
    /// asking for eight at once. Decoded frames are never cached across
    /// recipes; the walk IS the cache.
    public func renderPosters(
        provider: IndexedFrameProvider,
        recipes: [TimeSliceSettings],
        posterURLs: [URL],
        posterMetadata: [CFString: Any]? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws -> [TimeSliceRenderResult] {
        let masterFrames = provider.frameCount
        guard masterFrames >= 1 else { throw LapseError.noInputFrames }
        guard !recipes.isEmpty, recipes.count == posterURLs.count else {
            throw LapseError.timeSliceInvalid("each poster recipe needs an output path")
        }
        let width = provider.width
        let height = provider.height
        guard width >= 1, height >= 1 else { throw LapseError.noInputFrames }

        let plans = try recipes.map { recipe in
            try Self.makePlan(
                settings: recipe, width: width, height: height,
                transform: provider.transform, masterFrames: masterFrames, wantsPoster: true)
        }
        var union = Set<Int>()
        for plan in plans { union.formUnion(plan.posterCells.keys) }
        let order = union.sorted()
        guard !order.isEmpty else {
            throw LapseError.timeSliceInvalid("the poster ladder names no frames")
        }

        var posters = plans.map { _ in [UInt8](repeating: 0, count: width * height * 4) }

        for (step, master) in order.enumerated() {
            if isCancelled || Task.isCancelled { throw LapseError.cancelled }
            // Load-bearing, not hygiene: the rendered frame and every
            // temporary behind it are autoreleased, and a poster walk over a
            // 12 MP shoot is dozens of them.
            try autoreleasepool {
                let frame = try provider.frame(at: master)
                let buffer = frame.pixelBuffer
                let actualWidth = CVPixelBufferGetWidth(buffer)
                let actualHeight = CVPixelBufferGetHeight(buffer)
                guard actualWidth == width, actualHeight == height else {
                    throw LapseError.sizeMismatch(
                        expectedWidth: width, expectedHeight: height,
                        actualWidth: actualWidth, actualHeight: actualHeight)
                }
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                    throw LapseError.readerFailed("master frame \(master) has no base address")
                }
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                for (recipeIndex, plan) in plans.enumerated() {
                    guard let cells = plan.posterCells[master] else { continue }
                    posters[recipeIndex].withUnsafeMutableBytes { poster in
                        for cell in cells {
                            Self.copyBandDirect(
                                from: base, sourceBytesPerRow: bytesPerRow,
                                to: poster.baseAddress!, destBytesPerRow: width * 4,
                                rect: plan.cellRects[cell])
                        }
                    }
                }
            }
            progress?(Double(step + 1) / Double(order.count))
        }

        var results: [TimeSliceRenderResult] = []
        results.reserveCapacity(recipes.count)
        for (recipeIndex, plan) in plans.enumerated() {
            let image = try Self.makeImage(fromBGRA: posters[recipeIndex], width: width, height: height)
            let oriented = try Self.displayOriented(image, transform: provider.transform)
            let url = posterURLs[recipeIndex]
            let format = ImageFormat.infer(from: url) ?? .png
            try ImageExporter.write(oriented, to: url, format: format, metadata: posterMetadata)
            results.append(TimeSliceRenderResult(
                masterFrames: masterFrames, outputFrames: 0,
                width: width, height: height, wrotePoster: true,
                grid: plan.gridLayout, maxLagFrames: plan.maxLag))
        }
        return results
    }
}
