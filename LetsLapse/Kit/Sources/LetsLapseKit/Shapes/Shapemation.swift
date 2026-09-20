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
// ever visible. Mode 3 (`frame`, docs/shapemation/output-frame.md) is the
// model for a real set: the user picks the output rectangle and where the
// face sits in it, every photo is scaled and placed to put its face there,
// one photo per frame over black, and what does not fill the frame is
// flagged — never dropped.

public enum ShapemationMode: String, Codable, CaseIterable, Sendable {
    case stack, crop, frame

    public var title: String {
        switch self {
        case .stack: return "Stack, fit in frame"
        case .crop: return "Stack, crop to fill"
        case .frame: return "Output frame"
        }
    }
    public var summary: String {
        switch self {
        case .stack: return "The canvas holds every photo. Each lands on top of the last, the shape locked in place; the black table shows until it is covered."
        case .crop: return "The same stack, cropped to what every photo covers. No black — but one off-centre shape crops everyone."
        case .frame: return "Pick the frame; the face is put at a chosen size and place in every photo; what won't fill it is flagged."
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
        /// Whether the photo fills the output frame through its placement,
        /// and by how much it was scaled to get there. Under `.stack` and
        /// `.crop` every photo fits by construction (the canvas is made from
        /// the footprints) and nothing is upscaled; under `.frame` the frame
        /// is fixed and the photo may fall short of its edges or be blown up.
        public struct Feasibility: Equatable, Sendable {
            /// Output pixels the photo FAILS to cover on each side, 0 when
            /// covered: the gap between the frame's edge and the photo's
            /// bounds, or — for a rotated or projected photo whose bounds
            /// reach the edge while a frame corner still lies outside it —
            /// that corner's distance to the nearest photo edge, on both of
            /// the corner's sides.
            public var shortfall: (left: Double, top: Double, right: Double, bottom: Double)
            /// The similarity scale applied, `targetSizePx / majorPx` (> 1 =
            /// upscaled). A rectangle's homography magnifies its far edge more
            /// than its near one, so one edge of a steep quad can be blown up
            /// past this.
            public var upscale: Double
            public enum Verdict: String, Codable, Sendable {
                case fits, short, upscaled, shortAndUpscaled
                public var isFlagged: Bool { self != .fits }
                public var isShort: Bool { self == .short || self == .shortAndUpscaled }
                public var isUpscaled: Bool { self == .upscaled || self == .shortAndUpscaled }
            }
            /// `short` when any shortfall > 0.5 px; `upscaled` when upscale > the framing's cap.
            public var verdict: Verdict

            public init(shortfall: (left: Double, top: Double, right: Double, bottom: Double), upscale: Double, verdict: Verdict) {
                self.shortfall = shortfall; self.upscale = upscale; self.verdict = verdict
            }

            /// Covered on every side, scaled by `scale` — the stack modes' answer.
            public static func fits(scale: Double) -> Feasibility {
                Feasibility(shortfall: (0, 0, 0, 0), upscale: scale, verdict: .fits)
            }

            /// The verdict from `shortfall` and `upscale` against `upscaleCap`.
            public static func judge(shortfall: (left: Double, top: Double, right: Double, bottom: Double), upscale: Double,
                                     upscaleCap: Double) -> Feasibility {
                let short = max(shortfall.left, shortfall.top, shortfall.right, shortfall.bottom) > 0.5
                let up = upscale > upscaleCap
                let verdict: Verdict = short ? (up ? .shortAndUpscaled : .short) : (up ? .upscaled : .fits)
                return Feasibility(shortfall: shortfall, upscale: upscale, verdict: verdict)
            }

            public static func == (a: Feasibility, b: Feasibility) -> Bool {
                a.shortfall == b.shortfall && a.upscale == b.upscale && a.verdict == b.verdict
            }
        }

        public var itemID: UUID
        /// Source-pixel (y-down) → canvas-pixel (y-down).
        public var transform: Homography
        /// The photo's footprint on the canvas (axis-aligned bounds of its corners).
        public var footprint: CGRect
        public var scale: Double
        /// Where this photo's shape centre was put, canvas pixels — the plan's
        /// `anchor` under the stack modes, this photo's own framing under `.frame`.
        public var target: CGPoint
        /// The shape's long side there.
        public var targetSizePx: Double
        public var feasibility: Feasibility

        public init(itemID: UUID, transform: Homography, footprint: CGRect, scale: Double,
                    target: CGPoint, targetSizePx: Double, feasibility: Feasibility) {
            self.itemID = itemID; self.transform = transform; self.footprint = footprint; self.scale = scale
            self.target = target; self.targetSizePx = targetSizePx; self.feasibility = feasibility
        }
    }

    public var mode: ShapemationMode
    /// The shape's size on the canvas, in canvas pixels (`.frame`: the first placement's).
    public var shapeSizePx: Double
    /// Where the shape's centre sits on the canvas (`.frame`: the first placement's).
    public var anchor: CGPoint
    public var canvas: CGRect
    public var placements: [Placement]
    /// Mode 2 only: what the crop would have been under mode 1, for the summary.
    public var unionCanvas: CGRect
    /// `.frame` only: the framing the plan was made from.
    public var framing: ShapemationFraming?

    public var canvasSize: CGSize { canvas.size }

    /// The placements that do not fit the frame — short of its edges, upscaled
    /// past the cap, or both. Empty under the stack modes.
    public var flagged: [Placement] { placements.filter { $0.feasibility.verdict.isFlagged } }

    /// How many placements fall short of the frame and how many are upscaled
    /// past the cap; a placement that is both counts in each.
    public var feasibilitySummary: (short: Int, upscaled: Int) {
        (placements.filter { $0.feasibility.verdict.isShort }.count, placements.filter { $0.feasibility.verdict.isUpscaled }.count)
    }

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
    ///
    /// Under `.frame` (`framing` required, ignored otherwise) the canvas IS
    /// the framing's output rect and each photo gets its own size and place:
    /// item *i* of *n* reads the framing at `t = i / (n − 1)` (0 for a single
    /// item), its shape's long side becomes `size × outputHeight` and its
    /// centre lands on `face × outputSize` — the same family placement as the
    /// stack modes, scaled to that size and translated there. Nothing is
    /// excluded: a photo that leaves output pixels uncovered or is scaled up
    /// past the framing's cap is flagged in its `feasibility` and kept.
    public static func make(items: [ShapemationItem], mode: ShapemationMode, match: ShapeMatch? = nil,
                            framing: ShapemationFraming? = nil) -> ShapemationPlan? {
        guard !items.isEmpty else { return nil }
        if mode == .frame {
            guard let framing else { return nil }
            return makeFrame(items: items, match: match, framing: framing)
        }
        let target = items.map { $0.shape.nativeDiameterPx }.min() ?? 0
        guard target > 0 else { return nil }
        var raw: [(UUID, Homography, [CGPoint], Double)] = []
        for item in items {
            let W = Double(item.pixelSize.width), H = Double(item.pixelSize.height)
            let majorPx = item.shape.majorAxis * W
            guard majorPx > 0 else { continue }
            let (h, s) = familyPlacement(item.shape, W: W, H: H, target: target, match: match)
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
        let anchor = CGPoint(x: -canvas.minX, y: -canvas.minY)
        let placements = raw.enumerated().map { i, r in
            Placement(itemID: r.0, transform: shift * r.1, footprint: footprints[i].offsetBy(dx: -canvas.minX, dy: -canvas.minY), scale: r.3,
                      target: anchor, targetSizePx: target, feasibility: .fits(scale: r.3))
        }
        return ShapemationPlan(mode: mode, shapeSizePx: target, anchor: anchor,
                               canvas: CGRect(origin: .zero, size: canvas.size), placements: placements,
                               unionCanvas: CGRect(origin: .zero, size: union.size), framing: nil)
    }

    /// The `.frame` plan: see `make`.
    static func makeFrame(items: [ShapemationItem], match: ShapeMatch?, framing: ShapemationFraming) -> ShapemationPlan? {
        let outW = Double(framing.outputSize.width), outH = Double(framing.outputSize.height)
        guard outW > 0, outH > 0 else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: outW, height: outH)
        // Only the photos that can be placed count towards `t`, so the last
        // one placed reads the framing at 1 whatever was skipped.
        let placeable = items.filter { $0.shape.majorAxis * Double($0.pixelSize.width) > 0 }
        let count = placeable.count
        var placements: [Placement] = []
        var union: CGRect?
        for (i, item) in placeable.enumerated() {
            let W = Double(item.pixelSize.width), H = Double(item.pixelSize.height)
            let t = count > 1 ? Double(i) / Double(count - 1) : 0
            let (face, size) = framing.framing(at: t)
            let targetPx = size * outH
            guard targetPx > 0 else { continue }
            let target = CGPoint(x: Double(face.x) * outW, y: Double(face.y) * outH)
            let (placed, s) = familyPlacement(item.shape, W: W, H: H, target: targetPx, match: match)
            let h = Homography.translate(Double(target.x), Double(target.y)) * placed
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: W, y: 0), CGPoint(x: W, y: H), CGPoint(x: 0, y: H)].map { h.apply($0) }
            // The per-side gaps come from the axis-aligned bounds of the
            // transformed corners, but the verdict is decided exactly: the
            // frame is covered iff each of its four corners lies inside the
            // convex quad of the photo's corners (straight edges stay straight
            // under any affine or projective placement). The box around a
            // rotated or projected quad strictly contains it — a levelled
            // oval's tilt, a circle's un-tilt shear or a rectangle's
            // homography all leave a black corner the bounds alone call
            // covered — so a frame corner outside the quad while the bounds
            // reach the edge reports its distance to the nearest photo edge on
            // both of its sides.
            let footprint = ShapePolygon.bounds(corners)
            var shortfall = (left: max(0, Double(footprint.minX)), top: max(0, Double(footprint.minY)),
                             right: max(0, outW - Double(footprint.maxX)), bottom: max(0, outH - Double(footprint.maxY)))
            let frameCorners = [(CGPoint(x: 0, y: 0), true, true), (CGPoint(x: outW, y: 0), false, true),
                                (CGPoint(x: outW, y: outH), false, false), (CGPoint(x: 0, y: outH), true, false)]
            for (corner, isLeft, isTop) in frameCorners {
                let across = isLeft ? shortfall.left : shortfall.right, down = isTop ? shortfall.top : shortfall.bottom
                guard across == 0, down == 0 else { continue }   // the bounds already say short here
                let outside = ShapePolygon.distanceOutside(corners, corner)
                guard outside > 0 else { continue }
                if isLeft { shortfall.left = outside } else { shortfall.right = outside }
                if isTop { shortfall.top = outside } else { shortfall.bottom = outside }
            }
            let feasibility = Placement.Feasibility.judge(shortfall: shortfall, upscale: s, upscaleCap: framing.upscaleCap)
            placements.append(Placement(itemID: item.id, transform: h, footprint: footprint, scale: s,
                                        target: target, targetSizePx: targetPx, feasibility: feasibility))
            union = union.map { $0.union(footprint) } ?? footprint
        }
        guard let first = placements.first, let union else { return nil }
        return ShapemationPlan(mode: .frame, shapeSizePx: first.targetSizePx, anchor: first.target, canvas: canvas,
                               placements: placements, unionCanvas: CGRect(origin: .zero, size: union.size), framing: framing)
    }

    /// One photo's placement by its family, with the shape's centre at the
    /// origin and its long side `target` pixels: circles un-tilted, ovals
    /// turned level when the match asks, squares and rectangles by the
    /// homography onto the class rectangle, anything else by similarity.
    /// Returns the transform and the similarity scale `target / majorPx`.
    static func familyPlacement(_ shape: DetectedShape, W: Double, H: Double, target: Double, match: ShapeMatch?) -> (Homography, Double) {
        let cx = Double(shape.centre.x) * W, cy = Double(shape.centre.y) * H
        let majorPx = shape.majorAxis * W
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
        return (h, s)
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

/// One photo through its placement at the output size — the step the
/// renderer's loop and the builder's scrubber share, so what the scrub shows
/// is what the clip gets. The plan's canvas is scaled to `outputSize`; the
/// decode may be another size than the register measured on, which the
/// decode scale absorbs; Core Image is y-up, so the y-down transform is
/// wrapped in a flip either side.
public enum ShapemationFrameEvaluator {
    /// The photo placed and cropped to the output rect, transparent where
    /// it does not reach — the renderer lays this over its own table. Nil
    /// only when Core Image has no perspective filter.
    public static func placed(decoded cg: CGImage, item: ShapemationItem, placement: ShapemationPlan.Placement,
                              outputSize: CGSize, canvas: CGRect) -> CIImage? {
        let width = Double(outputSize.width), height = Double(outputSize.height)
        let frameRect = CGRect(x: 0, y: 0, width: width, height: height)
        let outputScale = width / Double(canvas.width)
        let W = Double(cg.width), H = Double(cg.height)
        let flipS = Homography(m: [1, 0, 0, 0, -1, H, 0, 0, 1])
        let flipO = Homography(m: [1, 0, 0, 0, -1, height, 0, 0, 1])
        // The register measured the shape on `pixelSize`; the decode may be another size.
        let decodeScale = W / Double(item.pixelSize.width)
        let toCanvas = placement.transform * Homography.scale(1 / decodeScale, 1 / decodeScale)
        let toOutput = Homography.scale(outputScale, outputScale) * toCanvas
        let hci = flipO * toOutput * flipS
        var photo = CIImage(cgImage: cg)
        if hci.isAffine {
            photo = photo.transformed(by: hci.affine)
        } else {
            guard let f = CIFilter(name: "CIPerspectiveTransform") else { return nil }
            f.setValue(photo, forKey: kCIInputImageKey)
            f.setValue(CIVector(cgPoint: hci.apply(CGPoint(x: 0, y: H))), forKey: "inputTopLeft")
            f.setValue(CIVector(cgPoint: hci.apply(CGPoint(x: W, y: H))), forKey: "inputTopRight")
            f.setValue(CIVector(cgPoint: hci.apply(CGPoint(x: 0, y: 0))), forKey: "inputBottomLeft")
            f.setValue(CIVector(cgPoint: hci.apply(CGPoint(x: W, y: 0))), forKey: "inputBottomRight")
            guard let out = f.outputImage else { return nil }
            photo = out
        }
        return photo.cropped(to: frameRect)
    }

    /// The photo placed, cropped to the output rect, over black — a `.frame`
    /// frame, and what the scrubber shows for any mode. The graph is lazy and
    /// needs no context to build. `canvas` is the plan's — the framing's
    /// output rect under `.frame`, the stack's own size otherwise — and is
    /// what `outputSize` scales from, so a scrubber's reduced preview and the
    /// full-size render go through the one transform.
    public static func image(item: ShapemationItem, decoded cg: CGImage, placement: ShapemationPlan.Placement,
                             outputSize: CGSize, canvas: CGRect) -> CIImage {
        let frameRect = CGRect(origin: .zero, size: outputSize)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: frameRect)
        guard let photo = placed(decoded: cg, item: item, placement: placement, outputSize: outputSize, canvas: canvas) else { return black }
        return photo.composited(over: black)
    }
}

/// Writes the video: each item held for `secondsPerItem`, hard cuts, composited
/// over everything that came before. Frames are produced at the output size
/// (the plan's canvas scaled down) and the previous frame is the next one's
/// background, so the stack costs one composite per item. Under `.frame` the
/// table stays black: one photo per hold, nothing accumulates.
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

        let frameRect = CGRect(x: 0, y: 0, width: width, height: height)
        let size = CGSize(width: width, height: height)
        var background = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: frameRect)
        var lastBuffer: CVPixelBuffer?
        let framesPerItem = max(1, Int((secondsPerItem * Double(fps)).rounded()))
        var frameIndex: Int64 = 0

        for (n, item) in items.enumerated() {
            if isCancelled?() == true { break }
            progress?(Progress(done: n, total: items.count, title: item.title))
            guard let placement = plan.placements.first(where: { $0.itemID == item.id }) else { continue }
            let cg = try load(item)
            guard let photo = ShapemationFrameEvaluator.placed(decoded: cg, item: item, placement: placement,
                                                              outputSize: size, canvas: plan.canvas) else { continue }
            let frame = photo.composited(over: background)
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
            // The frame just written is the next photo's table — under the
            // stack modes; the output frame keeps its black one.
            if plan.mode != .frame { background = CIImage(cvPixelBuffer: buffer) }
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
