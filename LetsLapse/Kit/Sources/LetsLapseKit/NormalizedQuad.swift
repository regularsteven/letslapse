import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The four corners of a quadrilateral found in a frame — a page, a print, a
/// flat object — normalised to 0…1 of the frame, with the **origin at the
/// bottom-left**.
///
/// The origin is the whole reason this type exists rather than four `CGPoint`s
/// passed around loose. Vision reports rectangle corners bottom-left-origin and
/// Core Image's `CIPerspectiveCorrection` consumes them bottom-left-origin, so
/// a detection flows into a correction with no flip anywhere between them. The
/// one place that has to convert is the SwiftUI overlay, whose y runs the other
/// way — and having a single documented convention is what makes that one
/// conversion obviously the only one.
///
/// Normalised rather than in pixels because the two ends of the pipeline are
/// different sizes: the corners are detected on a preview buffer (a few hundred
/// pixels wide) and applied to a full-resolution still. A fraction of the frame
/// survives that; a pixel coordinate does not.
public struct NormalizedQuad: Codable, Equatable, Sendable {

    /// A corner, encoded as a two-element array (`[0.12, 0.87]`) rather than an
    /// object — the sidecar is read by eye during shoots and by scripts after
    /// them, and four `{"x":…,"y":…}` objects per line makes both harder.
    public struct Point: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }

        public init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            x = try container.decode(Double.self)
            y = try container.decode(Double.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(x)
            try container.encode(y)
        }

        public func distance(to other: Point) -> Double {
            let dx = x - other.x
            let dy = y - other.y
            return (dx * dx + dy * dy).squareRoot()
        }

        #if canImport(CoreGraphics)
        public var cgPoint: CGPoint { CGPoint(x: x, y: y) }

        public init(_ point: CGPoint) {
            self.init(x: Double(point.x), y: Double(point.y))
        }
        #endif
    }

    public var topLeft: Point
    public var topRight: Point
    public var bottomLeft: Point
    public var bottomRight: Point
    /// The detector's own confidence, 0…1. Carried into the sidecar so a
    /// correction taken later can be judged rather than merely applied.
    public var confidence: Double

    public init(
        topLeft: Point,
        topRight: Point,
        bottomLeft: Point,
        bottomRight: Point,
        confidence: Double
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
        self.confidence = confidence
    }

    /// The corners in a fixed order, so anything comparing two quads compares
    /// like with like.
    public var corners: [Point] { [topLeft, topRight, bottomLeft, bottomRight] }

    /// How far the furthest-travelled corner has moved between two quads, as a
    /// fraction of the frame — the number the Scanner's corner-stability settle
    /// test thresholds. Uses the *maximum* rather than the mean deliberately: a
    /// page pivoting about one corner barely moves the average and moves the
    /// far corner a long way, and the far corner is the one that ruins a
    /// rectification.
    public func maxCornerDistance(to other: NormalizedQuad) -> Double {
        zip(corners, other.corners).reduce(0) { max($0, $1.0.distance(to: $1.1)) }
    }

    /// Width ÷ height of the quad, taken from the mean of each pair of opposite
    /// edges. An estimate, not a measurement: a quad seen at an angle is
    /// foreshortened, so this is the *apparent* ratio, which is what `.auto`
    /// correction is asked to preserve.
    public var apparentAspectRatio: Double {
        let width = (topLeft.distance(to: topRight) + bottomLeft.distance(to: bottomRight)) / 2
        let height = (topLeft.distance(to: bottomLeft) + topRight.distance(to: bottomRight)) / 2
        guard height > 0 else { return 1 }
        return width / height
    }

    /// The area of the quad's bounding box, 0…1 — the selection rule's primary
    /// key when several rectangles qualify at once (see `RectangleDetector`).
    public var boundingArea: Double {
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return 0 }
        return (maxX - minX) * (maxY - minY)
    }
}

// MARK: - Orientation

/// Which way up the image a quad was measured in was, relative to the camera
/// sensor's own landscape read-out.
///
/// It exists because a Scanner quad has to be true in **two** coordinate
/// systems that need not agree. Vision reports corners in the space of the
/// image it was *given* — i.e. after the `CGImagePropertyOrientation` the
/// request handler was handed — and the app hands it the pose the **capture**
/// is tagged with, so the corners rectify the still they were measured for. The
/// preview, meanwhile, is drawn in the **interface** orientation. Those are the
/// same thing most of the time and deliberately not always: under the system
/// rotation lock, or with the device flat over a copy stand (`faceUp`/
/// `faceDown`, where the physical pose is unknowable and the last one stands),
/// they differ by a quarter turn and a quad drawn without converting lands
/// beside the page rather than on it.
///
/// The four cases are the non-mirrored `CGImagePropertyOrientation`s, named for
/// the same rotations: `up` is the sensor's own read-out (a landscape-right
/// capture), `right` is what a portrait capture asks for, and so on.
public enum QuadOrientation: String, Codable, Sendable, CaseIterable {
    case up
    case right
    case down
    case left

    /// How far the sensor image is turned **clockwise** to reach this
    /// orientation, in quarter turns. This is the whole definition — everything
    /// else here is arithmetic on it.
    public var clockwiseQuarterTurns: Int {
        switch self {
        case .up: return 0
        case .right: return 1
        case .down: return 2
        case .left: return 3
        }
    }
}

extension NormalizedQuad {

    /// The same quadrilateral seen in an image turned `quarterTurns` × 90°
    /// clockwise.
    ///
    /// Both the coordinates and the corner *labels* move: rotating a page 90°
    /// clockwise puts what was its top-left corner at the top right, and a
    /// quad whose `topLeft` is no longer the top left would quietly poison
    /// every consumer that trusts the names (the corrector's
    /// `CIPerspectiveCorrection` inputs above all).
    ///
    /// In this bottom-left-origin normalised space one clockwise quarter turn
    /// is `(x, y) → (y, 1 - x)`: the bottom-left corner of the frame lands top
    /// left, which is what turning a picture clockwise does.
    public func rotatedClockwise(quarterTurns: Int) -> NormalizedQuad {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return self }
        var result = self
        for _ in 0..<turns {
            result = NormalizedQuad(
                topLeft: Self.turnClockwise(result.bottomLeft),
                topRight: Self.turnClockwise(result.topLeft),
                bottomLeft: Self.turnClockwise(result.bottomRight),
                bottomRight: Self.turnClockwise(result.topRight),
                confidence: result.confidence)
        }
        return result
    }

    private static func turnClockwise(_ point: Point) -> Point {
        Point(x: point.y, y: 1 - point.x)
    }

    /// The same quadrilateral, restated in an image that was oriented
    /// differently — a quad measured in the capture's orientation, redrawn in
    /// the preview's.
    ///
    /// The aspect swap comes free: rotating the unit square onto itself is
    /// exactly right when the two images are the same pixels turned by a
    /// quarter turn, because the target frame's width and height have swapped
    /// too.
    public func converted(from source: QuadOrientation, to target: QuadOrientation) -> NormalizedQuad {
        rotatedClockwise(
            quarterTurns: target.clockwiseQuarterTurns - source.clockwiseQuarterTurns)
    }

    /// The corners in the camera's own space — normalised to the sensor's
    /// landscape read-out with a **top-left** origin, which is the convention
    /// `AVCaptureVideoPreviewLayer.layerPointConverted(fromCaptureDevicePoint:)`
    /// consumes (and `captureDevicePointConverted(fromLayerPoint:)` produces
    /// for tap-to-focus).
    ///
    /// Handing the preview layer these rather than mapping into a hand-computed
    /// letterbox is the point: the layer is the only thing that knows its own
    /// video gravity, its bars and its connection's rotation.
    public func sensorCorners(measuredIn orientation: QuadOrientation) -> (
        topLeft: Point, topRight: Point, bottomRight: Point, bottomLeft: Point
    ) {
        let sensor = converted(from: orientation, to: .up)
        func flip(_ point: Point) -> Point { Point(x: point.x, y: 1 - point.y) }
        return (
            flip(sensor.topLeft), flip(sensor.topRight),
            flip(sensor.bottomRight), flip(sensor.bottomLeft))
    }
}
