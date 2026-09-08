import CoreGraphics
import Foundation

// The parametric half of the mask system: a shape drawn on the picture,
// stored as numbers rather than pixels.
//
// Everything here is resolution-independent — points are fractions of the
// frame, so one shape resolves identically at the 1100 px scrub render, the
// 2000 px settled preview and a full-resolution export, exactly the way
// `SceneOverlay.size` does. It also means the parameters are plain numbers,
// which is what will let them ride the grade timeline later.
//
// Kept in the Kit so `swift test` covers the projection and ellipse
// arithmetic: the handles, the mask raster and the export all read coverage
// from the same functions, and a sign error in any of them would show up as
// a mask drawn one place and applied another.

/// The two shapes a mask can be drawn as.
public enum MaskShapeKind: String, Codable, Sendable, CaseIterable {
    /// A gradient perpendicular to a line: fully selected at the `start`
    /// side, falling to nothing past the `end` side.
    case linear
    /// A feathered ellipse: fully selected in the middle, falling to nothing
    /// at the edge.
    case radial

    public var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .radial: return "Radial"
        }
    }
}

/// One parametric mask shape.
///
/// A single struct with a `kind` discriminator rather than an enum with
/// associated values: the editor binds sliders straight into `feather` and
/// `rotationDegrees` without unwrapping a case first, and the JSON stays flat
/// enough to read by eye in a sidecar.
///
/// **Coordinates.** `start`, `end` and `center` are normalized 0…1 over the
/// displayed frame with a top-left origin — the same space
/// `SceneOverlay.centerX/centerY` and `PhotoGrader.DetailPatch.region` live
/// in. `radiusX` is a fraction of the frame's WIDTH and `radiusY` a fraction
/// of its HEIGHT, so the pair survives a resize as a pure per-axis scale (the
/// same contract `MaskGeometry.stretch` gives the segmentation grid).
///
/// **The rotation is applied in PIXEL space**, not in the unit square. An
/// ellipse turned in normalized coordinates and then stretched to a 3:2 frame
/// comes out sheared, and the handles the user dragged would no longer sit on
/// it. Every function below that needs the angle therefore asks for the frame
/// size and works in points.
public struct MaskShape: Codable, Equatable, Sendable {
    public var kind: MaskShapeKind

    // MARK: Linear

    /// The fully-selected end of the gradient, normalized.
    public var start: CGPoint
    /// The fully-unselected end, normalized. The 50% line is the midpoint of
    /// `start`→`end`.
    public var end: CGPoint

    // MARK: Radial

    /// The ellipse's centre, normalized.
    public var center: CGPoint
    /// Semi-axis as a fraction of frame width.
    public var radiusX: Double
    /// Semi-axis as a fraction of frame height.
    public var radiusY: Double
    /// The ellipse's turn in degrees, positive clockwise on screen, about its
    /// own centre and in the frame's pixel space.
    public var rotationDegrees: Double

    // MARK: Both

    /// How much of the shape's own span the transition takes, 0…1.
    ///
    /// **Linear** — the 50% line sits at the midpoint of `start`→`end` and the
    /// transition spans `feather × distance` centred on it, so 1.0 ramps the
    /// whole way from `start` to `end` and 0 is a hard edge at the midpoint.
    /// **Radial** — everything inside `1 − feather` of the radius is fully
    /// selected, falling to 0 at the ellipse itself.
    ///
    /// A fraction of the shape rather than a distance: drag the handles wider
    /// and the softness grows with them, which is what "feather" means to
    /// anyone who has used it elsewhere.
    public var feather: Double

    public static let featherRange: ClosedRange<Double> = 0...1
    public static let rotationRange: ClosedRange<Double> = -90...90

    /// The default softness a freshly drawn shape carries. Half its span: a
    /// hard-edged local adjustment reads as a mistake, and one that ramps the
    /// whole way is too vague to aim.
    public static let defaultFeather: Double = 0.5

    public init(
        kind: MaskShapeKind,
        start: CGPoint = CGPoint(x: 0.5, y: 0.7),
        end: CGPoint = CGPoint(x: 0.5, y: 0.3),
        center: CGPoint = CGPoint(x: 0.5, y: 0.5),
        radiusX: Double = 0.2,
        radiusY: Double = 0.2,
        rotationDegrees: Double = 0,
        feather: Double = MaskShape.defaultFeather
    ) {
        self.kind = kind
        self.start = start
        self.end = end
        self.center = center
        self.radiusX = radiusX
        self.radiusY = radiusY
        self.rotationDegrees = rotationDegrees
        self.feather = feather
    }

    /// A linear mask from one point to another, both normalized.
    public static func linear(from start: CGPoint, to end: CGPoint,
                              feather: Double = MaskShape.defaultFeather) -> MaskShape {
        MaskShape(kind: .linear, start: start, end: end, feather: feather)
    }

    /// A radial mask as a **true circle** on screen: `radius` is given in
    /// points against `frameSize`, and split across the two axes so the shape
    /// is round wherever it is drawn. This is what a create-drag commits —
    /// the prototype's "centre to radius, a true circle".
    public static func radial(
        center: CGPoint, radiusPoints radius: Double, in frameSize: CGSize,
        feather: Double = MaskShape.defaultFeather
    ) -> MaskShape {
        MaskShape(
            kind: .radial, center: center,
            radiusX: frameSize.width > 0 ? radius / Double(frameSize.width) : 0.2,
            radiusY: frameSize.height > 0 ? radius / Double(frameSize.height) : 0.2,
            feather: feather)
    }

    private enum CodingKeys: String, CodingKey {
        case kind = "k", start = "s", end = "e", center = "c",
             radiusX = "rx", radiusY = "ry", rotationDegrees = "rot", feather = "f"
    }

    /// Every field past `kind` decodes with the initializer's default, the
    /// same tolerance `SceneOverlay` applies: a sidecar written by an older
    /// build must keep its masks rather than throw the document away.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(MaskShapeKind.self, forKey: .kind) ?? .radial
        start = try c.decodeIfPresent(CGPoint.self, forKey: .start) ?? CGPoint(x: 0.5, y: 0.7)
        end = try c.decodeIfPresent(CGPoint.self, forKey: .end) ?? CGPoint(x: 0.5, y: 0.3)
        center = try c.decodeIfPresent(CGPoint.self, forKey: .center) ?? CGPoint(x: 0.5, y: 0.5)
        radiusX = try c.decodeIfPresent(Double.self, forKey: .radiusX) ?? 0.2
        radiusY = try c.decodeIfPresent(Double.self, forKey: .radiusY) ?? 0.2
        rotationDegrees = try c.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? MaskShape.defaultFeather
    }

    // MARK: - Geometry in points

    /// The shape's points resolved against a frame, so callers draw and
    /// evaluate in the same space the user dragged in.
    public func startPoint(in size: CGSize) -> CGPoint { Self.scaled(start, in: size) }
    public func endPoint(in size: CGSize) -> CGPoint { Self.scaled(end, in: size) }
    public func centerPoint(in size: CGSize) -> CGPoint { Self.scaled(center, in: size) }
    public func radiusXPoints(in size: CGSize) -> Double { radiusX * Double(size.width) }
    public func radiusYPoints(in size: CGSize) -> Double { radiusY * Double(size.height) }

    private static func scaled(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    /// The linear shape's length in points — what the create HUD reports and
    /// what the feather band is measured against.
    public func length(in size: CGSize) -> Double {
        let a = startPoint(in: size), b = endPoint(in: size)
        return Double(hypot(b.x - a.x, b.y - a.y))
    }

    /// True when the shape is too small to have been meant: a create-drag
    /// under this is discarded rather than committed as an invisible mask.
    public static let minimumDragPoints: Double = 8

    public func isDegenerate(in size: CGSize) -> Bool {
        switch kind {
        case .linear: return length(in: size) < Self.minimumDragPoints
        case .radial:
            return min(radiusXPoints(in: size), radiusYPoints(in: size)) < Self.minimumDragPoints
        }
    }

    // MARK: - Coverage

    /// How much of `point` (in points, against `size`) this shape selects:
    /// 1 fully inside, 0 fully outside, feathered between.
    ///
    /// The renderer draws the same function as a Core Image gradient rather
    /// than calling this per pixel; this is the definition both it and the
    /// tests are checked against.
    public func coverage(at point: CGPoint, in size: CGSize) -> Double {
        switch kind {
        case .linear:
            return Self.ramp(normalizedDistance(of: point, in: size),
                             from: 0.5 - featherHalf, to: 0.5 + featherHalf)
        case .radial:
            return Self.ramp(ellipseRadius(of: point, in: size),
                             from: max(0, 1 - clampedFeather), to: 1)
        }
    }

    private var clampedFeather: Double { min(max(feather, 0), 1) }
    private var featherHalf: Double { clampedFeather / 2 }

    /// Where `point` falls along `start`→`end`: 0 at the start, 1 at the end,
    /// and beyond either on the outside. Perpendicular distance from the line
    /// is irrelevant to a linear gradient, which is why this projects.
    public func normalizedDistance(of point: CGPoint, in size: CGSize) -> Double {
        let a = startPoint(in: size), b = endPoint(in: size)
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let lengthSquared = dx * dx + dy * dy
        // A zero-length linear mask selects everything rather than dividing by
        // zero — the same answer as a hard edge at the point itself.
        guard lengthSquared > 0 else { return 0 }
        return ((Double(point.x - a.x) * dx) + (Double(point.y - a.y) * dy)) / lengthSquared
    }

    /// `point` expressed as a multiple of the ellipse's own radius: 0 at the
    /// centre, 1 on the outline, more outside it. The point is un-rotated
    /// into the ellipse's local frame first, which is what makes a turned
    /// ellipse evaluate as the shape that was drawn.
    public func ellipseRadius(of point: CGPoint, in size: CGSize) -> Double {
        let c = centerPoint(in: size)
        let radians = rotationDegrees * .pi / 180
        let cosine = cos(radians), sine = sin(radians)
        let dx = Double(point.x - c.x), dy = Double(point.y - c.y)
        // Un-rotate: the inverse of the clockwise turn the ellipse is drawn at.
        let localX = dx * cosine + dy * sine
        let localY = -dx * sine + dy * cosine
        let rx = max(radiusXPoints(in: size), .ulpOfOne)
        let ry = max(radiusYPoints(in: size), .ulpOfOne)
        return hypot(localX / rx, localY / ry)
    }

    /// 1 below `from`, 0 above `to`, linear between — the shape of both
    /// gradients, written once.
    static func ramp(_ value: Double, from: Double, to: Double) -> Double {
        guard to > from else { return value < to ? 1 : 0 }
        if value <= from { return 1 }
        if value >= to { return 0 }
        return 1 - (value - from) / (to - from)
    }

    // MARK: - Handle geometry
    //
    // The editor's chrome, defined here rather than in the view so the drawn
    // handles and the evaluated mask can never disagree about where the shape
    // is. All in points against a frame size.

    /// The two dashed lines that mark the feather band of a linear mask, as
    /// the points on the axis they pass through. Empty at feather 0, where
    /// the band collapses onto the 50% line.
    public func linearFeatherPoints(in size: CGSize) -> (near: CGPoint, far: CGPoint)? {
        guard kind == .linear, clampedFeather > 0 else { return nil }
        let a = startPoint(in: size), b = endPoint(in: size)
        let dx = b.x - a.x, dy = b.y - a.y
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let offset = CGFloat(featherHalf)
        return (CGPoint(x: mid.x - dx * offset, y: mid.y - dy * offset),
                CGPoint(x: mid.x + dx * offset, y: mid.y + dy * offset))
    }

    /// The midpoint of `start`→`end` — where the 50% line crosses the axis.
    public func linearMidpoint(in size: CGSize) -> CGPoint {
        let a = startPoint(in: size), b = endPoint(in: size)
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// The unit vector perpendicular to a linear mask's axis — the direction
    /// the 50% and feather lines run in.
    public func linearNormal(in size: CGSize) -> CGVector {
        let a = startPoint(in: size), b = endPoint(in: size)
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(hypot(dx, dy), .ulpOfOne)
        return CGVector(dx: -dy / length, dy: dx / length)
    }

    /// Which way round the ellipse's four cardinal handles sit. `east` and
    /// `west` set `radiusX`; `north` and `south` set `radiusY`.
    public enum Cardinal: CaseIterable, Sendable { case east, west, north, south }

    /// A point in the ellipse's local frame mapped back into the picture.
    public func point(localX: Double, localY: Double, in size: CGSize) -> CGPoint {
        let c = centerPoint(in: size)
        let radians = rotationDegrees * .pi / 180
        let cosine = cos(radians), sine = sin(radians)
        return CGPoint(x: c.x + CGFloat(localX * cosine - localY * sine),
                       y: c.y + CGFloat(localX * sine + localY * cosine))
    }

    public func cardinalPoint(_ cardinal: Cardinal, in size: CGSize) -> CGPoint {
        let rx = radiusXPoints(in: size), ry = radiusYPoints(in: size)
        switch cardinal {
        case .east: return point(localX: rx, localY: 0, in: size)
        case .west: return point(localX: -rx, localY: 0, in: size)
        case .north: return point(localX: 0, localY: -ry, in: size)
        case .south: return point(localX: 0, localY: ry, in: size)
        }
    }

    /// How far past the +x cardinal the rotation handle sits, in points.
    public static let rotationStalkPoints: Double = 26

    public func rotationHandlePoint(in size: CGSize) -> CGPoint {
        point(localX: radiusXPoints(in: size) + Self.rotationStalkPoints, localY: 0, in: size)
    }

    /// Below this the four cardinal handles would overlap each other and the
    /// rotation stalk, so they collapse and the caption asks for a zoom.
    public static let collapsedHandleRadiusPoints: Double = 26

    /// True when the ellipse is too small on screen to carry its handles.
    public func handlesCollapse(in size: CGSize) -> Bool {
        kind == .radial
            && min(radiusXPoints(in: size), radiusYPoints(in: size))
                < Self.collapsedHandleRadiusPoints
    }

    // MARK: - Editing

    /// The shape with one cardinal handle dragged to `point`. Only the axis
    /// that handle owns moves; the ellipse keeps its centre and its turn.
    public func resized(_ cardinal: Cardinal, to point: CGPoint, in size: CGSize) -> MaskShape {
        var copy = self
        let c = centerPoint(in: size)
        let radians = rotationDegrees * .pi / 180
        let dx = Double(point.x - c.x), dy = Double(point.y - c.y)
        let localX = dx * cos(radians) + dy * sin(radians)
        let localY = -dx * sin(radians) + dy * cos(radians)
        // A floor rather than a clamp to zero: an ellipse with no area cannot
        // be grabbed again, and the handle that made it is the only way back.
        let minimum = 6.0
        switch cardinal {
        case .east, .west:
            copy.radiusX = size.width > 0 ? max(minimum, abs(localX)) / Double(size.width) : copy.radiusX
        case .north, .south:
            copy.radiusY = size.height > 0 ? max(minimum, abs(localY)) / Double(size.height) : copy.radiusY
        }
        return copy
    }

    /// The shape turned so its +x axis points at `point`. The stored angle is
    /// wrapped into ±180 and then folded into the ±90 the slider shows: an
    /// ellipse is symmetric, so 100° and −80° are the same shape.
    public func rotated(toward point: CGPoint, in size: CGSize) -> MaskShape {
        var copy = self
        let c = centerPoint(in: size)
        let degrees = atan2(Double(point.y - c.y), Double(point.x - c.x)) * 180 / .pi
        copy.rotationDegrees = Self.foldedAngle(degrees)
        return copy
    }

    /// Folds any angle into −90…90. Ellipses are symmetric about both axes,
    /// so this loses nothing and keeps the Rotation slider's travel honest.
    public static func foldedAngle(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 180)
        if value > 90 { value -= 180 }
        if value < -90 { value += 180 }
        return value
    }

    /// The shape moved by a translation in points, clamped so the centre
    /// stays on the picture — a mask dragged off the frame cannot be grabbed
    /// back.
    public func moved(by translation: CGSize, in size: CGSize) -> MaskShape {
        var copy = self
        let dx = size.width > 0 ? Double(translation.width / size.width) : 0
        let dy = size.height > 0 ? Double(translation.height / size.height) : 0
        switch kind {
        case .linear:
            copy.start = Self.offset(start, dx: dx, dy: dy)
            copy.end = Self.offset(end, dx: dx, dy: dy)
        case .radial:
            copy.center = Self.clamped(Self.offset(center, dx: dx, dy: dy))
        }
        return copy
    }

    private static func offset(_ point: CGPoint, dx: Double, dy: Double) -> CGPoint {
        CGPoint(x: point.x + CGFloat(dx), y: point.y + CGFloat(dy))
    }

    /// Normalized points are clamped to the frame everywhere a gesture writes
    /// one. Linear ends are deliberately NOT clamped — a gradient's far point
    /// is often meant to sit off the picture — but the centre of a radial is.
    public static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    // MARK: - Frames

    /// This shape, authored on the SENSOR frame, re-expressed on the frame
    /// the picture is displayed in. `exifOrientation` is the EXIF value the
    /// display applies: 1 as recorded, 3 turned 180°, 6 turned 90° clockwise,
    /// 8 turned 90° anticlockwise. Anything else is treated as 1.
    ///
    /// Points map by the turn. For a quarter turn the two radii SWAP and the
    /// rotation stays: `radiusX` is a fraction of the frame's width and after
    /// the turn that same axis is a fraction of the new frame's height, and
    /// an ellipse with its radii exchanged is the same ellipse turned a
    /// quarter, so the stored angle already describes it.
    public func fromSensorFrame(exifOrientation: Int) -> MaskShape {
        func turned(_ p: CGPoint) -> CGPoint {
            switch exifOrientation {
            case 3: return CGPoint(x: 1 - p.x, y: 1 - p.y)
            case 6: return CGPoint(x: 1 - p.y, y: p.x)
            case 8: return CGPoint(x: p.y, y: 1 - p.x)
            default: return p
            }
        }
        var copy = self
        copy.start = turned(start)
        copy.end = turned(end)
        copy.center = turned(center)
        if exifOrientation == 6 || exifOrientation == 8 {
            copy.radiusX = radiusY
            copy.radiusY = radiusX
        }
        return copy
    }

    /// A one-line description of the shape's size, for the create HUD and the
    /// detail card's footnote.
    public func sizeCaption(in size: CGSize) -> String {
        switch kind {
        case .linear:
            return String(format: "%.0f pt across, %.0f°", length(in: size), axisDegrees(in: size))
        case .radial:
            return String(format: "%.0f × %.0f pt",
                          radiusXPoints(in: size) * 2, radiusYPoints(in: size) * 2)
        }
    }

    /// The linear axis's angle on screen, degrees clockwise from +x.
    public func axisDegrees(in size: CGSize) -> Double {
        let a = startPoint(in: size), b = endPoint(in: size)
        return atan2(Double(b.y - a.y), Double(b.x - a.x)) * 180 / .pi
    }
}
