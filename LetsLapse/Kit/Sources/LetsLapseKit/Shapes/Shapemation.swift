import Foundation
import CoreGraphics
import CoreImage
import AVFoundation
import CoreVideo

// The Shape-mation composer: every picked photo is placed so its nominated
// shape lands on one fixed spot at one fixed size, and the photos stack one
// second after another. Mode 1 (`stack`) keeps a canvas big enough for every
// photo — the black table gets covered as photos land; Mode 2 (`crop`) is
// the same stack cropped to the region every photo covers, so no black is
// ever visible.

public enum ShapemationMode: String, Codable, CaseIterable, Sendable {
    case stack, crop

    public var title: String {
        switch self {
        case .stack: return "Stack, fit in frame"
        case .crop: return "Stack, crop to fill"
        }
    }
    public var summary: String {
        switch self {
        case .stack: return "The canvas holds every photo. Each lands on top of the last, the shape locked in place; the black table shows until it is covered."
        case .crop: return "The same stack, cropped to what every photo covers. No black — but one off-centre shape crops everyone."
        }
    }
}

/// One photo in the sequence: where its picture is and which shape holds still.
public struct ShapemationItem: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var imageURL: URL
    /// The frame's oriented pixel size (the register's representative size).
    public var pixelSize: CGSize
    public var shape: DetectedShape
    /// Clips: the fraction of duration the frame comes from.
    public var frameFraction: Double?

    public init(id: UUID = UUID(), title: String, imageURL: URL, pixelSize: CGSize, shape: DetectedShape, frameFraction: Double? = nil) {
        self.id = id; self.title = title; self.imageURL = imageURL; self.pixelSize = pixelSize
        self.shape = shape; self.frameFraction = frameFraction
    }
}

/// The geometry of a Shape-mation before any pixel is touched: canvas size,
/// where the shape sits, and each photo's placement — all in canvas pixels at
/// the working scale (the smallest photo's shape at 1:1, so nothing upscales).
public struct ShapemationPlan: Equatable, Sendable {
    public struct Placement: Equatable, Sendable {
        public var itemID: UUID
        /// Source-pixel (y-down) → canvas-pixel (y-down).
        public var transform: Homography
        /// The photo's footprint on the canvas (axis-aligned bounds of its corners).
        public var footprint: CGRect
        public var scale: Double
    }

    public var mode: ShapemationMode
    /// The shape's size on the canvas, in canvas pixels.
    public var shapeSizePx: Double
    /// Where the shape's centre sits on the canvas.
    public var anchor: CGPoint
    public var canvas: CGRect
    public var placements: [Placement]
    /// Mode 2 only: what the crop would have been under mode 1, for the summary.
    public var unionCanvas: CGRect

    public var canvasSize: CGSize { canvas.size }

    /// Output sizes worth offering: the canvas at working scale, then standard
    /// long edges below it, each keeping the canvas aspect and even dimensions.
    public struct OutputOption: Identifiable, Equatable, Sendable {
        public var id: String { label }
        public var label: String
        public var size: CGSize
    }

    public func outputOptions() -> [OutputOption] {
        var options: [OutputOption] = []
        let native = Self.even(canvas.size)
        options.append(OutputOption(label: "Native \(Int(native.width))×\(Int(native.height))", size: native))
        let long = max(native.width, native.height)
        for edge in [3840.0, 2160.0, 1920.0, 1080.0] where edge < long {
            let s = edge / long
            let size = Self.even(CGSize(width: native.width * s, height: native.height * s))
            options.append(OutputOption(label: "Fit \(Int(edge)) · \(Int(size.width))×\(Int(size.height))", size: size))
        }
        return options
    }

    static func even(_ s: CGSize) -> CGSize {
        CGSize(width: max(2, floor(s.width / 2) * 2), height: max(2, floor(s.height / 2) * 2))
    }

    /// Lays the items out. Every shape is scaled to the smallest native shape
    /// among the items (so no photo is ever upscaled). Without a `match` —
    /// the builder before the Match step — ellipses keep their orientation
    /// (a circle's axis direction is noise) and quads level their top edge.
    /// With one, the family decides how each shape is made to coincide with
    /// the others: circles are un-tilted (the minor axis stretched to the
    /// major, so a rim seen from the side lands round); ovals are turned
    /// level when the match asks and scaled by their major axis; squares and
    /// rectangles are placed by the homography that puts the quad's four
    /// corners on one target rectangle — the match's class, else the quad's
    /// own effective aspect — so every rectangle lands on the same shape,
    /// perspective corrected. The canvas is the union (stack) or intersection
    /// (crop) of the footprints, translated so it starts at the origin.
    public static func make(items: [ShapemationItem], mode: ShapemationMode, match: ShapeMatch? = nil) -> ShapemationPlan? {
        guard !items.isEmpty else { return nil }
        let target = items.map { $0.shape.nativeDiameterPx }.min() ?? 0
        guard target > 0 else { return nil }
        var raw: [(UUID, Homography, [CGPoint], Double)] = []
        for item in items {
            let W = Double(item.pixelSize.width), H = Double(item.pixelSize.height)
            let shape = item.shape
            let cx = Double(shape.centre.x) * W, cy = Double(shape.centre.y) * H
            let majorPx = shape.majorAxis * W
            guard majorPx > 0 else { continue }
            let s = target / majorPx
            let centred = Homography.translate(-cx, -cy)
            var h: Homography
            switch (shape.kind, match?.family) {
            case (.quad, .square?), (.quad, .rectangle?):
                h = Self.rectanglePlacement(shape, W: W, H: H, target: target, match: match!)
                    ?? Homography.scale(s, s) * .rotate(-shape.rotation) * centred
            case (.ellipse, .circle?):
                // Un-tilt about the centre: into the ellipse's own frame,
                // stretch the minor axis up to the major, back out.
                let stretch = shape.obliquity > 0 ? 1 / shape.obliquity : 1
                let untilt = Homography.rotate(shape.rotation) * Homography.scale(1, stretch) * Homography.rotate(-shape.rotation)
                h = Homography.scale(s, s) * untilt * centred
            case (.ellipse, .oval?):
                let turn: Homography = match?.angle == .level ? .rotate(-shape.rotation) : .identity
                h = Homography.scale(s, s) * turn * centred
            default:
                let rot: Homography = shape.kind == .quad ? .rotate(-shape.rotation) : .identity
                h = Homography.scale(s, s) * rot * centred
            }
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: W, y: 0), CGPoint(x: W, y: H), CGPoint(x: 0, y: H)].map { h.apply($0) }
            raw.append((item.id, h, corners, s))
        }
        guard !raw.isEmpty else { return nil }
        let footprints = raw.map { ShapePolygon.bounds($0.2) }
        var union = footprints[0]
        var inter = footprints[0]
        for f in footprints.dropFirst() { union = union.union(f); inter = inter.intersection(f) }
        if mode == .crop, inter.isNull || inter.width < 16 || inter.height < 16 { return nil }
        let canvas = mode == .stack ? union : inter
        // Shift so the canvas origin is (0,0); the shape centre was at the origin.
        let shift = Homography.translate(-Double(canvas.minX), -Double(canvas.minY))
        let placements = raw.enumerated().map { i, r in
            Placement(itemID: r.0, transform: shift * r.1, footprint: footprints[i].offsetBy(dx: -canvas.minX, dy: -canvas.minY), scale: r.3)
        }
        return ShapemationPlan(mode: mode, shapeSizePx: target, anchor: CGPoint(x: -canvas.minX, y: -canvas.minY),
                               canvas: CGRect(origin: .zero, size: canvas.size), placements: placements,
                               unionCanvas: CGRect(origin: .zero, size: union.size))
    }

    /// The homography that puts a quad's four corners (source pixels) on a
    /// rectangle of `target` long side, centred at the origin: the match's
    /// class ratio where one is chosen, the quad's own effective aspect
    /// otherwise; landscape or portrait as the quad lies. Nil for a
    /// degenerate quad, which the caller places by similarity instead.
    static func rectanglePlacement(_ shape: DetectedShape, W: Double, H: Double, target: Double, match: ShapeMatch) -> Homography? {
        guard let c = shape.corners, c.count == 4 else { return nil }
        let src = c.map { CGPoint(x: Double($0.x) * W, y: Double($0.y) * H) }
        let own = shape.effectiveAspect
        let landscape = match.targetAspect ?? max(own, 1 / own)
        guard landscape.isFinite, landscape > 0 else { return nil }
        let long = target, short = target / landscape
        let (w, h) = shape.wide ? (long, short) : (short, long)
        let dst = [CGPoint(x: -w / 2, y: -h / 2), CGPoint(x: w / 2, y: -h / 2), CGPoint(x: w / 2, y: h / 2), CGPoint(x: -w / 2, y: h / 2)]
        return Homography.from(src, to: dst)
    }
}

/// Writes the video: each item held for `secondsPerItem`, hard cuts, composited
/// over everything that came before. Frames are produced at the output size
/// (the plan's canvas scaled down) and the previous frame is the next one's
/// background, so the stack costs one composite per item.
public final class ShapemationRenderer {
    public struct Progress: Sendable {
        public var done: Int
        public var total: Int
        public var title: String
        public init(done: Int, total: Int, title: String) { self.done = done; self.total = total; self.title = title }
    }
    public typealias ImageLoader = @Sendable (ShapemationItem) throws -> CGImage

    public var secondsPerItem = 1.0
    public var fps: Int32 = 30
    public var bitsPerSecond = 16_000_000
    /// The Timing step's answer. When set it decides the frame rate and
    /// every item's own hold (`ShapemationTiming.holds(count:)`); when nil the
    /// constant `secondsPerItem` at `fps` applies, as before it existed.
    public var timing: ShapemationTiming?

    private let context: CIContext
    public init() {
        context = CIContext(options: [.cacheIntermediates: false])
    }

    /// Renders `items` in order to `url` (an .mp4), returning the poster (the last frame).
    public func render(plan: ShapemationPlan, items: [ShapemationItem], outputSize: CGSize, to url: URL,
                       load: ImageLoader, progress: (@Sendable (Progress) -> Void)? = nil,
                       isCancelled: (@Sendable () -> Bool)? = nil) throws -> CGImage? {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let width = Int(outputSize.width), height = Int(outputSize.height)
        let fps: Int32 = timing.map { Int32($0.fps) } ?? self.fps
        let holds = timing?.holds(count: items.count)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitsPerSecond,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? LapseError.writerFailed("could not start the video writer") }
        writer.startSession(atSourceTime: .zero)

        let outputScale = Double(width) / Double(plan.canvas.width)
        let frameRect = CGRect(x: 0, y: 0, width: width, height: height)
        let flipS: (Double) -> Homography = { h in Homography(m: [1, 0, 0, 0, -1, h, 0, 0, 1]) }
        let flipO = Homography(m: [1, 0, 0, 0, -1, Double(height), 0, 0, 1])
        var background = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: frameRect)
        var lastBuffer: CVPixelBuffer?
        let framesPerItem = max(1, Int((secondsPerItem * Double(fps)).rounded()))
        var frameIndex: Int64 = 0

        for (n, item) in items.enumerated() {
            if isCancelled?() == true { break }
            progress?(Progress(done: n, total: items.count, title: item.title))
            guard let placement = plan.placements.first(where: { $0.itemID == item.id }) else { continue }
            let cg = try load(item)
            let W = Double(cg.width), H = Double(cg.height)
            // The register measured the shape on `pixelSize`; the decode may be another size.
            let decodeScale = W / Double(item.pixelSize.width)
            let toCanvas = placement.transform * Homography.scale(1 / decodeScale, 1 / decodeScale)
            let toOutput = Homography.scale(outputScale, outputScale) * toCanvas
            let hci = flipO * toOutput * flipS(H)
            var photo = CIImage(cgImage: cg)
            if hci.isAffine {
                photo = photo.transformed(by: hci.affine)
            } else {
                guard let f = CIFilter(name: "CIPerspectiveTransform") else { continue }
                f.setValue(photo, forKey: kCIInputImageKey)
                f.setValue(CIVector(cgPoint: hci.apply(CGPoint(x: 0, y: H))), forKey: "inputTopLeft")
                f.setValue(CIVector(cgPoint: hci.apply(CGPoint(x: W, y: H))), forKey: "inputTopRight")
                f.setValue(CIVector(cgPoint: hci.apply(CGPoint(x: 0, y: 0))), forKey: "inputBottomLeft")
                f.setValue(CIVector(cgPoint: hci.apply(CGPoint(x: W, y: 0))), forKey: "inputBottomRight")
                guard let out = f.outputImage else { continue }
                photo = out
            }
            let frame = photo.cropped(to: frameRect).composited(over: background)
            guard let pool = adaptor.pixelBufferPool else { throw LapseError.writerFailed("no pixel buffer pool") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { throw LapseError.writerFailed("no pixel buffer") }
            context.render(frame, to: buffer, bounds: frameRect, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            let hold = holds.map { n < $0.count ? $0[n] : framesPerItem } ?? framesPerItem
            for _ in 0..<hold {
                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
                if !adaptor.append(buffer, withPresentationTime: CMTime(value: frameIndex, timescale: fps)) {
                    throw writer.error ?? LapseError.writerFailed("could not append a frame")
                }
                frameIndex += 1
            }
            // The frame just written is the next photo's table.
            background = CIImage(cvPixelBuffer: buffer)
            lastBuffer = buffer
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if let e = writer.error { throw e }
        progress?(Progress(done: items.count, total: items.count, title: ""))
        guard let last = lastBuffer else { return nil }
        let poster = CIImage(cvPixelBuffer: last)
        return context.createCGImage(poster, from: poster.extent)
    }
}
