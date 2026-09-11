import Foundation
import CoreGraphics

// The per-project shape register — `shapes.json` in the project folder,
// written by "Find shapes" and by hand in the Masks tab, read by the
// Shape-mation builder. One list for both: a shape drawn by hand shows up in
// the builder at once, and a found shape can be corrected or removed.

/// One shape in a project's representative frame. Geometry is normalised to
/// that frame (origin top-left; axes as fractions of its width) so it maps to
/// any decode size without loss.
public struct DetectedShape: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case ellipse, quad

        public var displayName: String {
            switch self {
            case .ellipse: return "Ellipse"
            case .quad: return "Rectangle"
            }
        }
    }

    /// Where a shape came from: the detector, a hand on the picture, or the
    /// viewfinder — found live before the shutter and left on screen by the
    /// person shooting (`captured`), which is a detection a human confirmed.
    public enum Source: String, Codable, Sendable { case detected, manual, captured }

    /// What the picker offers: the detected kind narrowed by how it sits.
    public enum Family: String, Codable, CaseIterable, Sendable {
        case circle, oval, square, rectangle

        public var title: String {
            switch self {
            case .circle: return "Circle"
            case .oval: return "Oval"
            case .square: return "Square"
            case .rectangle: return "Rectangle"
            }
        }
        public var symbolName: String {
            switch self {
            case .circle: return "circle"
            case .oval: return "oval"
            case .square: return "square"
            case .rectangle: return "rectangle"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var centre: CGPoint
    /// Full major axis (ellipses) or the longer mean side (quads), as a fraction of frame width.
    public var majorAxis: Double
    public var minorAxis: Double
    /// Radians from horizontal: the ellipse's major axis, or the quad's top edge.
    public var rotation: Double
    /// Quads only: clockwise from top-left, normalised.
    public var corners: [CGPoint]?
    public var confidence: Float
    /// The shape's size in the representative frame's own pixels.
    public var nativeDiameterPx: Double
    /// The user's own name, or nil for the family's.
    public var name: String?
    public var source: Source
    /// Quads: whether the top edge is the longer pair (width ≥ height in pixels).
    /// Needed because the axes are fractions of the frame's width and the
    /// corners are normalised per axis — neither can say which way a rectangle lies.
    public var wide: Bool
    /// Quads: width ÷ height of the physical rectangle this quad is a
    /// photograph of — top edge over side, like `aspect` — recovered from the
    /// perspective it was seen under (Zhang–He, `NormalizedQuad.
    /// rectifiedAspectRatio`, the Scanner's PAPER gate). Needs the lens's
    /// field of view, which the register's representative carries; nil when
    /// the lens is unknown or the quad is degenerate. `aspect` is what the
    /// quad looks like on screen; this is what the rectangle is.
    public var rectifiedAspect: Double?

    public init(id: UUID = UUID(), kind: Kind, centre: CGPoint, majorAxis: Double, minorAxis: Double,
                rotation: Double, corners: [CGPoint]?, confidence: Float, nativeDiameterPx: Double,
                name: String? = nil, source: Source = .detected, wide: Bool = true, rectifiedAspect: Double? = nil) {
        self.id = id; self.kind = kind; self.centre = centre; self.majorAxis = majorAxis
        self.minorAxis = minorAxis; self.rotation = rotation; self.corners = corners
        self.confidence = confidence; self.nativeDiameterPx = nativeDiameterPx
        self.name = name; self.source = source; self.wide = wide; self.rectifiedAspect = rectifiedAspect
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, centre, majorAxis, minorAxis, rotation, corners, confidence, nativeDiameterPx, name, source, wide, rectifiedAspect
    }

    /// Registers written before names and sources existed decode as detected, unnamed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        centre = try c.decode(CGPoint.self, forKey: .centre)
        majorAxis = try c.decode(Double.self, forKey: .majorAxis)
        minorAxis = try c.decode(Double.self, forKey: .minorAxis)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        corners = try c.decodeIfPresent([CGPoint].self, forKey: .corners)
        confidence = try c.decodeIfPresent(Float.self, forKey: .confidence) ?? 1
        nativeDiameterPx = try c.decodeIfPresent(Double.self, forKey: .nativeDiameterPx) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name)
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .detected
        wide = try c.decodeIfPresent(Bool.self, forKey: .wide) ?? true
        rectifiedAspect = try c.decodeIfPresent(Double.self, forKey: .rectifiedAspect)
    }

    /// minor/major — 1 is head-on.
    public var obliquity: Double { majorAxis > 0 ? minorAxis / majorAxis : 0 }

    /// Quads: width over height in pixels (top-edge mean over side mean), as seen.
    public var aspect: Double {
        guard kind == .quad, majorAxis > 0, minorAxis > 0 else { return 1 }
        return wide ? majorAxis / minorAxis : minorAxis / majorAxis
    }

    /// Quads: the rectangle's own proportions where the lens was known, its
    /// proportions on screen otherwise. What `family` and the Match step judge.
    public var effectiveAspect: Double { rectifiedAspect ?? aspect }

    /// Whether the rectangle's aspect is the physical one (see `rectifiedAspect`).
    public var isRectified: Bool { rectifiedAspect != nil }

    public var family: Family {
        switch kind {
        case .ellipse: return obliquity >= 0.85 ? .circle : .oval
        case .quad:
            let a = effectiveAspect
            return (a >= 0.8 && a <= 1.25) ? .square : .rectangle
        }
    }

    /// The same quad with `rectifiedAspect` worked out from the lens's
    /// horizontal field of view (degrees) and the frame it was measured on.
    /// The corners are in the register's top-left space; `NormalizedQuad`
    /// speaks Vision's bottom-left one, so y flips on the way in. Degenerate
    /// quads (no area) come back untouched.
    public func rectified(horizontalFieldOfView: Double?, frame: CGSize) -> DetectedShape {
        guard kind == .quad, let c = corners, c.count == 4, let fov = horizontalFieldOfView, fov > 0,
              frame.width > 0, frame.height > 0 else { return self }
        let quad = NormalizedQuad(
            topLeft: .init(x: Double(c[0].x), y: 1 - Double(c[0].y)),
            topRight: .init(x: Double(c[1].x), y: 1 - Double(c[1].y)),
            bottomLeft: .init(x: Double(c[3].x), y: 1 - Double(c[3].y)),
            bottomRight: .init(x: Double(c[2].x), y: 1 - Double(c[2].y)),
            confidence: Double(confidence))
        let focal = 0.5 / tan(fov * .pi / 360)
        guard let ratio = quad.rectifiedAspectRatio(frameAspect: Double(frame.width / frame.height), focalInFrameWidths: focal),
              ratio.isFinite, ratio > 0 else { return self }
        var s = self
        s.rectifiedAspect = ratio
        return s
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return family.title
    }

    // MARK: - Making and editing shapes by hand

    /// An ellipse from its centre and semi-axes, all in the frame's pixels.
    public static func ellipse(centre: CGPoint, semiAxisX: Double, semiAxisY: Double, rotation: Double,
                               frame: CGSize, source: Source = .manual) -> DetectedShape {
        let W = Double(frame.width), H = Double(frame.height)
        var a = max(semiAxisX, 1), b = max(semiAxisY, 1), rot = rotation
        if b > a { swap(&a, &b); rot += .pi / 2 }
        rot = Self.wrapped(rot)
        return DetectedShape(kind: .ellipse, centre: CGPoint(x: centre.x / W, y: centre.y / H),
                             majorAxis: 2 * a / W, minorAxis: 2 * b / W, rotation: rot, corners: nil,
                             confidence: 1, nativeDiameterPx: 2 * a, source: source)
    }

    /// A quad from four corners in the frame's pixels, clockwise from top-left.
    public static func quad(corners px: [CGPoint], frame: CGSize, source: Source = .manual) -> DetectedShape {
        let W = Double(frame.width), H = Double(frame.height)
        let m = quadMetrics(cornersPx: px)
        let normalised = px.map { CGPoint(x: $0.x / W, y: $0.y / H) }
        let centre = CGPoint(x: normalised.map(\.x).reduce(0, +) / 4, y: normalised.map(\.y).reduce(0, +) / 4)
        return DetectedShape(kind: .quad, centre: centre, majorAxis: m.major / W, minorAxis: m.minor / W,
                             rotation: m.rotation, corners: normalised, confidence: 1,
                             nativeDiameterPx: m.major, source: source, wide: m.wide)
    }

    /// Longer and shorter mean side, the top edge's angle, and whether the top
    /// edge is the longer pair — in the pixels the corners are in.
    public static func quadMetrics(cornersPx px: [CGPoint]) -> (major: Double, minor: Double, rotation: Double, wide: Bool) {
        guard px.count == 4 else { return (0, 0, 0, true) }
        func d(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }
        let width = (d(px[0], px[1]) + d(px[3], px[2])) / 2
        let height = (d(px[0], px[3]) + d(px[1], px[2])) / 2
        let dx = Double(px[1].x - px[0].x + px[2].x - px[3].x)
        let dy = Double(px[1].y - px[0].y + px[2].y - px[3].y)
        return (max(width, height), min(width, height), atan2(dy, dx), width >= height)
    }

    /// The same shape re-measured after its geometry was edited on a frame of `frame` pixels:
    /// a quad from its corners, an ellipse from its axes (swapped so the major stays major).
    public func remeasured(frame: CGSize) -> DetectedShape {
        var s = self
        let W = Double(frame.width), H = Double(frame.height)
        switch kind {
        case .quad:
            guard let c = corners, c.count == 4 else { return s }
            let px = c.map { CGPoint(x: $0.x * W, y: $0.y * H) }
            let m = Self.quadMetrics(cornersPx: px)
            s.majorAxis = m.major / W; s.minorAxis = m.minor / W; s.rotation = m.rotation; s.wide = m.wide
            s.centre = CGPoint(x: c.map(\.x).reduce(0, +) / 4, y: c.map(\.y).reduce(0, +) / 4)
            s.nativeDiameterPx = m.major
        case .ellipse:
            if s.minorAxis > s.majorAxis {
                swap(&s.majorAxis, &s.minorAxis)
                s.rotation = Self.wrapped(s.rotation + .pi / 2)
            }
            s.nativeDiameterPx = s.majorAxis * W
        }
        return s
    }

    static func wrapped(_ r: Double) -> Double {
        var rot = r
        while rot > .pi / 2 { rot -= .pi }
        while rot <= -.pi / 2 { rot += .pi }
        return rot
    }
}

/// The sidecar. `representative` names the frame the shapes are measured on,
/// relative to the project folder, so the builder renders the same picture.
public struct ShapeRegister: Codable, Equatable, Sendable {
    public static let fileName = "shapes.json"
    /// Bump when the detector changes enough that old registers should be redone.
    public static let currentDetectorVersion = 1

    public struct Representative: Codable, Equatable, Sendable {
        public enum Source: String, Codable, Sendable { case blendImage, blendVideo, sourceFrame }
        public var relativePath: String
        public var source: Source
        /// The lens's horizontal field of view in degrees when the picture
        /// was taken — read from the active format at the shutter, from EXIF
        /// on import, nil when unknown. What lets a quad's `rectifiedAspect`
        /// be worked out, now or on any later re-measure.
        public var horizontalFieldOfView: Double?
        /// For a clip, the fraction of its duration the frame was pulled from.
        public var frameFraction: Double?
        public var width: Int
        public var height: Int

        public init(relativePath: String, source: Source, frameFraction: Double? = nil, width: Int, height: Int,
                    horizontalFieldOfView: Double? = nil) {
            self.relativePath = relativePath; self.source = source; self.frameFraction = frameFraction
            self.width = width; self.height = height; self.horizontalFieldOfView = horizontalFieldOfView
        }
    }

    public var version: Int = 1
    public var detectorVersion: Int
    /// When Find shapes last ran on this project — nil for a register that only
    /// holds hand-drawn shapes, which Find shapes will still visit.
    public var analysedAt: Date?
    public var representative: Representative
    public var shapes: [DetectedShape]
    /// Why analysis produced nothing usable, when it did (kept so "Find shapes"
    /// does not retry a project whose picture cannot be read).
    public var failure: String?

    public init(detectorVersion: Int = ShapeRegister.currentDetectorVersion, analysedAt: Date? = Date(),
                representative: Representative, shapes: [DetectedShape], failure: String? = nil) {
        self.detectorVersion = detectorVersion; self.analysedAt = analysedAt
        self.representative = representative; self.shapes = shapes; self.failure = failure
    }

    private enum CodingKeys: String, CodingKey {
        case version, detectorVersion, analysedAt, representative, shapes, failure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        detectorVersion = try c.decodeIfPresent(Int.self, forKey: .detectorVersion) ?? 0
        analysedAt = try c.decodeIfPresent(Date.self, forKey: .analysedAt)
        representative = try c.decode(Representative.self, forKey: .representative)
        shapes = try c.decodeIfPresent([DetectedShape].self, forKey: .shapes) ?? []
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
    }

    /// A register that has never been through Find shapes — a home for shapes drawn by hand.
    public static func manual(representative: Representative) -> ShapeRegister {
        ShapeRegister(detectorVersion: 0, analysedAt: nil, representative: representative, shapes: [])
    }

    public var isAnalysed: Bool { analysedAt != nil }
    public var manualShapes: [DetectedShape] { shapes.filter { $0.source == .manual } }
    /// The shapes a person put there or confirmed — what a detector re-run keeps.
    public var keptShapes: [DetectedShape] { shapes.filter { $0.source != .detected } }
    public var frameSize: CGSize { CGSize(width: representative.width, height: representative.height) }

    public func families() -> [DetectedShape.Family: Int] {
        var out: [DetectedShape.Family: Int] = [:]
        for s in shapes { out[s.family, default: 0] += 1 }
        return out
    }

    public static func url(inProjectFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName, isDirectory: false)
    }

    public static func load(inProjectFolder folder: URL) -> ShapeRegister? {
        let url = url(inProjectFolder: folder)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var register = try? decoder.decode(ShapeRegister.self, from: data) else { return nil }
        // Registers written before `wide` existed: re-measure quads from their
        // corners; and where the lens is known, quads written before
        // `rectifiedAspect` existed get theirs worked out now.
        if register.frameSize.width > 0 {
            register.shapes = register.shapes.map { shape in
                guard shape.kind == .quad else { return shape }
                var s = shape.remeasured(frame: register.frameSize)
                if s.rectifiedAspect == nil { s = s.rectified(horizontalFieldOfView: register.representative.horizontalFieldOfView, frame: register.frameSize) }
                return s
            }
        }
        return register
    }

    /// Every quad's `rectifiedAspect` worked out (or re-worked) against this
    /// register's lens and frame — for a register about to be written.
    public func rectifyingQuads() -> ShapeRegister {
        var r = self
        r.shapes = shapes.map { $0.kind == .quad ? $0.rectified(horizontalFieldOfView: representative.horizontalFieldOfView, frame: frameSize) : $0 }
        return r
    }

    public func save(inProjectFolder folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.url(inProjectFolder: folder), options: .atomic)
    }
}
