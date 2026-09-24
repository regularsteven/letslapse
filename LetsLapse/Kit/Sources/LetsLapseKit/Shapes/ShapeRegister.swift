import Foundation
import CoreGraphics

// The per-project shape register — `shapes.json` in the project folder,
// written by "Find shapes" and by hand in the Masks tab, read by the
// Shape-mation builder. One list for both: a shape drawn by hand shows up in
// the builder at once, and a found shape can be corrected or removed.
//
// The file travels byte-for-byte between devices (PicPlace, .lapse, device
// transfer), and the devices do not all run the same build. So every build
// that carries this reader keeps what it does not understand, and refuses
// to write what it cannot fully read. The rule for `ShapeRegister.
// formatVersion`: bump it ONLY for a change an older build would LOSE by
// re-encoding the file — a changed meaning of an existing key, a new key a
// reader must have. A new element kind in `shapes[]` or a new top-level key
// needs no bump: an older build decodes them as `JSONValue` into
// `foreignShapes` / `foreignFields` and writes them back out untouched. A
// build that meets a `version` above its own `formatVersion` answers
// `.tooNew` from `read` and must not write the file — the shape tools and
// Find shapes stand down for that project and say so; never edit-and-lose.
// (A new key INSIDE a known shape is not carried — `DetectedShape` keeps
// only what it names — so if losing one would matter, that is a bump.)
// Three more things the carry-through does NOT promise, for whoever adds the
// first new kind: a new VALUE of an existing enum is a bump too — a new
// `source` on a known kind makes the whole element foreign (kept, hidden,
// no longer seen by Find shapes' dedupe), and a new `representative.source`
// fails the full decode, so the file locks as `.unreadable`, not `.tooNew`;
// the order of `shapes[]` is not kept across known and foreign elements
// (the known ones come first on encode — refer to a shape by `id`, never
// by position); and every number passes through a Double, so an integer
// above 2^53 does not survive an older build's re-encode — no 64-bit
// integer fields. A file this build writes is stamped with its own
// `formatVersion`, whatever version it was read at: a newer build that
// re-saves an older file marks it as its own even when it added nothing.

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
        // Strict on purpose: a kind this build does not know throws here, and
        // that throw is what routes the element into `ShapeRegister.foreignShapes`.
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

    /// The shape's axis-aligned bounds in the pixels of a frame of `frame`:
    /// an ellipse from its rotated semi-axes, a quad from its corners. The
    /// axes are fractions of the frame's WIDTH and the centre is normalised
    /// per axis, so everything goes to pixels first — which is why this
    /// exists beside `ShapeDetector.bbox`: that one stays in the normalised
    /// frame, where a width-fraction axis lands on y as if it were a height
    /// fraction (a circle on a 4:3 frame comes back 4/3 too tall), and it
    /// stays as it is under the fifteen tuned IoU thresholds that lean on it.
    public func bounds(in frame: CGSize) -> CGRect {
        let W = Double(frame.width), H = Double(frame.height)
        let c = cos(rotation), s = sin(rotation)
        switch kind {
        case .quad:
            if let corners, corners.count == 4 {
                let xs = corners.map { Double($0.x) * W }, ys = corners.map { Double($0.y) * H }
                let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
                return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            // A quad known only by its sides: the rectangle they span, turned
            // by the top edge's angle. `wide` says which side lies along it.
            let w = (wide ? majorAxis : minorAxis) * W, h = (wide ? minorAxis : majorAxis) * W
            let hw = (w * abs(c) + h * abs(s)) / 2, hh = (w * abs(s) + h * abs(c)) / 2
            return CGRect(x: Double(centre.x) * W - hw, y: Double(centre.y) * H - hh, width: 2 * hw, height: 2 * hh)
        case .ellipse:
            let a = majorAxis * W / 2, b = minorAxis * W / 2
            let hw = sqrt(a * a * c * c + b * b * s * s)
            let hh = sqrt(a * a * s * s + b * b * c * c)
            return CGRect(x: Double(centre.x) * W - hw, y: Double(centre.y) * H - hh, width: 2 * hw, height: 2 * hh)
        }
    }

    /// How far the shape's bounds sit inside a frame of `frame` pixels, per
    /// side — signed, so a negative margin is the shape spilling past that edge.
    public func margins(in frame: CGSize) -> (left: Double, top: Double, right: Double, bottom: Double) {
        let b = bounds(in: frame)
        return (Double(b.minX), Double(b.minY), Double(frame.width) - Double(b.maxX), Double(frame.height) - Double(b.maxY))
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
    /// 1: the Vision passes. 2 (2026-09-12): the region-proposal pass, flat
    /// nests, the 0.10 file floor — a register from 1 is missing most of what
    /// 2 finds, and Find shapes offers it again.
    public static let currentDetectorVersion = 2

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

    /// What this build writes into `version`, and the highest it will read
    /// and write back. The rule for bumping it is in the header. 1: the
    /// format as it stands (unchanged this release — carrying foreign
    /// shapes and keys is what this reader does, not a format change).
    public static let formatVersion = 1

    /// The `version` the file was read at (`formatVersion` for a register
    /// minted here). `save` writes `formatVersion`, not this: a file this
    /// build wrote is this build's format.
    public var version: Int = ShapeRegister.formatVersion
    public var detectorVersion: Int
    /// When Find shapes last ran on this project — nil for a register that only
    /// holds hand-drawn shapes, which Find shapes will still visit.
    public var analysedAt: Date?
    public var representative: Representative
    public var shapes: [DetectedShape]
    /// Auto shape mode's account of the capture, when the register was
    /// written at the shutter — see `ViewfinderTrail`. Nil for Find shapes
    /// and hand-drawn registers.
    public var viewfinder: ViewfinderTrail?
    /// Why analysis produced nothing usable, when it did (kept so "Find shapes"
    /// does not retry a project whose picture cannot be read).
    public var failure: String?
    /// Elements of `shapes[]` this build could not read as a `DetectedShape`
    /// — a kind a newer build writes — kept as they were read and written
    /// back after the known shapes. Never shown, never counted, never
    /// re-measured; just not lost. Nothing here means the file is all ours.
    public var foreignShapes: [JSONValue] = []
    /// Top-level keys this build does not name, kept the same way and written
    /// back under their own names.
    public var foreignFields: [String: JSONValue] = [:]

    public init(detectorVersion: Int = ShapeRegister.currentDetectorVersion, analysedAt: Date? = Date(),
                representative: Representative, shapes: [DetectedShape], failure: String? = nil) {
        self.detectorVersion = detectorVersion; self.analysedAt = analysedAt
        self.representative = representative; self.shapes = shapes; self.failure = failure
    }

    /// The keys this build owns. Anything else in the file is a foreign field.
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, detectorVersion, analysedAt, representative, shapes, failure, viewfinder
    }

    /// The register as this build understands it, plus everything it does not
    /// (`foreignShapes`, `foreignFields`) so that `save` writes the whole file
    /// back. A `shapes[]` element that fails as a `DetectedShape` for ANY
    /// reason — an unknown kind, a missing centre — is kept as JSON rather than
    /// failing the register: the known shapes keep their order among
    /// themselves, the foreign ones follow them on encode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        detectorVersion = try c.decodeIfPresent(Int.self, forKey: .detectorVersion) ?? 0
        analysedAt = try c.decodeIfPresent(Date.self, forKey: .analysedAt)
        representative = try c.decode(Representative.self, forKey: .representative)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        viewfinder = try c.decodeIfPresent(ViewfinderTrail.self, forKey: .viewfinder)

        var known: [DetectedShape] = []
        var foreign: [JSONValue] = []
        if c.contains(.shapes), !(try c.decodeNil(forKey: .shapes)) {
            var elements = try c.nestedUnkeyedContainer(forKey: .shapes)
            while !elements.isAtEnd {
                // An unkeyed container only moves on when a decode succeeds, so a
                // failed `DetectedShape` leaves the cursor on the element and the
                // `JSONValue` decode takes it — which always succeeds on JSON.
                if let shape = try? elements.decode(DetectedShape.self) {
                    known.append(shape)
                } else {
                    foreign.append(try elements.decode(JSONValue.self))
                }
            }
        }
        shapes = known
        foreignShapes = foreign

        let owned = Set(CodingKeys.allCases.map(\.stringValue))
        let any = try decoder.container(keyedBy: AnyCodingKey.self)
        var fields: [String: JSONValue] = [:]
        for key in any.allKeys where !owned.contains(key.stringValue) {
            fields[key.stringValue] = try any.decode(JSONValue.self, forKey: key)
        }
        foreignFields = fields
    }

    /// The known keys as they have always been written — `version` as this
    /// build's `formatVersion`, whatever the file was read at; `shapes` as
    /// the known shapes followed by the foreign ones; then each foreign
    /// field under its own key. A register with nothing foreign writes
    /// exactly the keys it always has — `foreignShapes` and `foreignFields`
    /// never appear by name.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .version)
        try c.encode(detectorVersion, forKey: .detectorVersion)
        try c.encodeIfPresent(analysedAt, forKey: .analysedAt)
        try c.encode(representative, forKey: .representative)
        try c.encodeIfPresent(failure, forKey: .failure)
        try c.encodeIfPresent(viewfinder, forKey: .viewfinder)
        var elements = c.nestedUnkeyedContainer(forKey: .shapes)
        for shape in shapes { try elements.encode(shape) }
        for shape in foreignShapes { try elements.encode(shape) }
        if !foreignFields.isEmpty {
            var any = encoder.container(keyedBy: AnyCodingKey.self)
            for (key, value) in foreignFields { try any.encode(value, forKey: AnyCodingKey(key)) }
        }
    }

    /// A register that has never been through Find shapes — a home for shapes drawn by hand.
    public static func manual(representative: Representative) -> ShapeRegister {
        ShapeRegister(detectorVersion: 0, analysedAt: nil, representative: representative, shapes: [])
    }

    public var isAnalysed: Bool { analysedAt != nil }

    /// Analysed by the detector as it stands. An older register still counts
    /// as analysed everywhere it is shown; Find shapes is where it is redone.
    public var isCurrent: Bool { isAnalysed && detectorVersion >= Self.currentDetectorVersion }
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

    /// What a project folder's `shapes.json` turned out to be. A writer
    /// switches on this: only `.register` (and `.none`, minting a fresh one)
    /// may be followed by a `save`; `.tooNew` and `.unreadable` must leave
    /// the file alone and say so.
    public enum ReadOutcome: Sendable {
        /// No file — the project has never had shapes.
        case none
        /// Read in full: every shape this build knows, and everything it does not kept aside.
        case register(ShapeRegister)
        /// Written by a build with a `formatVersion` above ours; the full decode
        /// was never attempted. Refuse to write — see the header.
        case tooNew(version: Int)
        /// A file at our version (or none) that would not decode — the error's description.
        case unreadable(String)

        /// The register for readers, nil for anything that is not one.
        public var register: ShapeRegister? {
            if case .register(let r) = self { return r }
            return nil
        }
    }

    /// The register as `read` finds it. Readers may use this; a writer must
    /// use `read` and switch on the outcome — nil here is "nothing readable",
    /// which a writer must not mistake for "nothing there" (`.tooNew` and
    /// `.unreadable` both land here, and minting a fresh register over either
    /// loses the file).
    public static func load(inProjectFolder folder: URL) -> ShapeRegister? {
        read(inProjectFolder: folder).register
    }

    /// The `version` of a file's bytes, looked at alone: nil for a register
    /// written before `version` existed (version 1), a throw for bytes that
    /// are not a JSON object at all. What `read` and `save` both ask first.
    private static func probeVersion(_ data: Data) throws -> Int? {
        struct Probe: Decodable { var version: Int? }
        return try JSONDecoder().decode(Probe.self, from: data).version
    }

    /// The only door into a project's `shapes.json`. Looks at `version` alone
    /// first, so a file from a newer build is answered `.tooNew` without the
    /// full decode (whose failure would be expected and uninformative).
    public static func read(inProjectFolder folder: URL) -> ReadOutcome {
        let url = url(inProjectFolder: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { return .unreadable(String(describing: error)) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A register written before `version` existed is version 1.
        if let version = try? probeVersion(data), version > formatVersion {
            return .tooNew(version: version)
        }
        var register: ShapeRegister
        do { register = try decoder.decode(ShapeRegister.self, from: data) } catch { return .unreadable(String(describing: error)) }
        // Registers written before `wide` existed: re-measure quads from their
        // corners; and where the lens is known, quads written before
        // `rectifiedAspect` existed get theirs worked out now. Known shapes
        // only — a foreign element is never touched.
        if register.frameSize.width > 0 {
            register.shapes = register.shapes.map { shape in
                guard shape.kind == .quad else { return shape }
                var s = shape.remeasured(frame: register.frameSize)
                if s.rectifiedAspect == nil { s = s.rectified(horizontalFieldOfView: register.representative.horizontalFieldOfView, frame: register.frameSize) }
                return s
            }
        }
        return .register(register)
    }

    /// Every quad's `rectifiedAspect` worked out (or re-worked) against this
    /// register's lens and frame — for a register about to be written. Known
    /// shapes only; `foreignShapes` ride along as they are.
    public func rectifyingQuads() -> ShapeRegister {
        var r = self
        r.shapes = shapes.map { $0.kind == .quad ? $0.rectified(horizontalFieldOfView: representative.horizontalFieldOfView, frame: frameSize) : $0 }
        return r
    }

    /// Why `save` left the file alone: what was on disk AT THE WRITE was not
    /// this build's to overwrite. A writer that read `.register` may still
    /// meet this — the viewer reads once at open, Find shapes once per
    /// project, and a PicPlace pull can land a newer build's file in
    /// between — so it is the lock again, raised where the bytes go.
    public enum WriteRefused: Error, LocalizedError, Equatable, Sendable {
        /// The file on disk (or the register itself) is above `formatVersion`.
        case tooNew(version: Int)
        /// The file on disk is not a JSON object this build can look at.
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .tooNew(let version): return "shapes.json is version \(version); this build writes up to \(ShapeRegister.formatVersion)"
            case .unreadable(let why): return "shapes.json on disk could not be read: \(why)"
            }
        }
    }

    /// Writes the whole file — known and foreign alike — as this build's
    /// `formatVersion`. The rule in the header made unskippable, at the one
    /// place the bytes are written: the file on disk is probed NOW, not as
    /// it was read, and a version above ours (`WriteRefused.tooNew`) or bytes
    /// that are no JSON object (`.unreadable`) leave it exactly as it is. A
    /// register whose own `version` is above ours is refused the same way,
    /// so a struct built by hand cannot slip past either.
    public func save(inProjectFolder folder: URL) throws {
        guard version <= Self.formatVersion else { throw WriteRefused.tooNew(version: version) }
        let url = Self.url(inProjectFolder: folder)
        if FileManager.default.fileExists(atPath: url.path) {
            let onDisk: Int?
            do { onDisk = try Self.probeVersion(try Data(contentsOf: url)) } catch { throw WriteRefused.unreadable(String(describing: error)) }
            if let onDisk, onDisk > Self.formatVersion { throw WriteRefused.tooNew(version: onDisk) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - Rotate 90° (a record, 2026-09-24)

extension DetectedShape {
    /// This shape a quarter turn clockwise later: its project was turned with
    /// Rotate 90°, which is a record, so the representative picture is shown
    /// turned and the shape follows the scene on it. `frame` is the
    /// representative's size before the turn.
    ///
    /// The centre maps (x, y) → (1 − y, x); the axes are fractions of the
    /// frame's width, so they are re-expressed against the turned frame's
    /// width — the old height; the angle gains a quarter. A quad's corners
    /// turn and keep their clockwise-from-top-left order, and the quad is
    /// re-measured from them; the rectangle's aspect is top edge over side,
    /// and its top edge is now the old side.
    public func turnedQuarter(frame: CGSize) -> DetectedShape {
        let W = Double(frame.width), H = Double(frame.height)
        guard W > 0, H > 0 else { return self }
        func turned(_ p: CGPoint) -> CGPoint { CGPoint(x: 1 - p.y, y: p.x) }
        var s = self
        s.centre = turned(centre)
        s.majorAxis = majorAxis * W / H
        s.minorAxis = minorAxis * W / H
        s.rotation = Self.wrapped(rotation + .pi / 2)
        guard kind == .quad else { return s }
        s.wide = !wide
        s.rectifiedAspect = rectifiedAspect.map { $0 > 0 ? 1 / $0 : $0 }
        if let c = corners, c.count == 4 {
            s.corners = [turned(c[3]), turned(c[0]), turned(c[1]), turned(c[2])]
            s = s.remeasured(frame: CGSize(width: frame.height, height: frame.width))
        }
        return s
    }
}

extension ShapeRegister {
    /// The register a quarter turn clockwise later — Rotate 90° on its
    /// project. The representative is the same file shown turned, so the
    /// frame's sides swap and the lens's horizontal field of view becomes
    /// the old vertical one; every known shape turns with the picture.
    /// Foreign shapes a newer build wrote ride along untouched, as `read`
    /// leaves them.
    public func turnedQuarter() -> ShapeRegister {
        var r = self
        let frame = frameSize
        r.shapes = shapes.map { $0.turnedQuarter(frame: frame) }
        r.representative.width = representative.height
        r.representative.height = representative.width
        if let fov = representative.horizontalFieldOfView, fov > 0, frame.width > 0 {
            let half = tan(fov * .pi / 360) * Double(frame.height / frame.width)
            r.representative.horizontalFieldOfView = 2 * atan(half) * 180 / .pi
        }
        return r
    }
}
