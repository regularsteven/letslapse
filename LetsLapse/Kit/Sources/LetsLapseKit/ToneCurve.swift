import CoreImage
import Foundation

/// A point tone curve — Lightroom's, and anyone else's: a handful of control
/// points that say what comes out for what goes in.
///
/// This app's engine has no curve of its own. It arrived because a Lightroom
/// sidecar carries two of them (the image's own, and the one baked into the
/// named profile look) and because a render variant has to be able to honour
/// them or ignore them and be MEASURED either way.
///
/// **Interpolated with a monotone cubic (Fritsch–Carlson), not a plain
/// spline.** A tone curve must never reverse: an ordinary cubic through
/// Lightroom's own seven points overshoots near the ends and produces a
/// segment where more light in gives less light out, which is visible as a
/// dark rim on a bright edge. Fritsch–Carlson clamps exactly that and costs a
/// few lines.
public struct ToneCurve: Equatable, Sendable {

    /// Control points, ordered by input. Both axes 0…1.
    public let points: [Point]

    public struct Point: Equatable, Sendable, Comparable {
        public var input: Double
        public var output: Double
        public init(input: Double, output: Double) {
            self.input = input
            self.output = output
        }
        public static func < (a: Point, b: Point) -> Bool { a.input < b.input }
    }

    /// The curve that changes nothing.
    public static let identity = ToneCurve(points: [])

    /// Sorted, de-duplicated on input, and dropped entirely when it says
    /// nothing — an identity curve should cost no work downstream, and a
    /// caller should not have to check for one.
    public init(points: [Point]) {
        var sorted = points.sorted()
        var unique: [Point] = []
        for point in sorted where unique.last?.input != point.input {
            unique.append(point)
        }
        sorted = unique
        self.points = sorted.count >= 2 && sorted.contains { abs($0.input - $0.output) > 1e-9 }
            ? sorted : []
    }

    /// From Lightroom's 0…255 pairs.
    public init(lightroomPoints: [(Double, Double)]) {
        self.init(points: lightroomPoints.map {
            Point(input: $0.0 / 255, output: $0.1 / 255)
        })
    }

    public var isIdentity: Bool { points.isEmpty }

    /// The curve's output for one input, 0…1, clamped at both ends.
    public func value(at x: Double) -> Double {
        guard !isIdentity else { return x }
        let clamped = min(max(x, 0), 1)
        if clamped <= points[0].input { return points[0].output }
        if clamped >= points[points.count - 1].input { return points[points.count - 1].output }
        var index = 0
        while index < points.count - 2, points[index + 1].input < clamped { index += 1 }
        let p0 = points[index], p1 = points[index + 1]
        let h = p1.input - p0.input
        guard h > 0 else { return p0.output }
        let t = (clamped - p0.input) / h
        let (m0, m1) = tangents(at: index)
        // Hermite basis.
        let t2 = t * t, t3 = t2 * t
        let result = (2 * t3 - 3 * t2 + 1) * p0.output
            + (t3 - 2 * t2 + t) * h * m0
            + (-2 * t3 + 3 * t2) * p1.output
            + (t3 - t2) * h * m1
        return min(max(result, 0), 1)
    }

    /// The Fritsch–Carlson tangents at the two ends of segment `index`.
    private func tangents(at index: Int) -> (Double, Double) {
        func slope(_ i: Int) -> Double {
            let a = points[i], b = points[i + 1]
            let run = b.input - a.input
            return run > 0 ? (b.output - a.output) / run : 0
        }
        func tangent(_ i: Int) -> Double {
            if i == 0 { return slope(0) }
            if i == points.count - 1 { return slope(points.count - 2) }
            let previous = slope(i - 1), next = slope(i)
            // A local extremum, or a sign change: flatten, which is what
            // stops the overshoot.
            if previous * next <= 0 { return 0 }
            let harmonic = 2 * previous * next / (previous + next)
            return harmonic
        }
        return (tangent(index), tangent(index + 1))
    }

    /// The curve as a lookup table of `size` entries over 0…1 — what an image
    /// pass actually consumes.
    public func lookupTable(size: Int = 256) -> [Double] {
        guard size > 1 else { return [] }
        guard !isIdentity else {
            return (0..<size).map { Double($0) / Double(size - 1) }
        }
        return (0..<size).map { value(at: Double($0) / Double(size - 1)) }
    }

    /// The same table as 8-bit bytes, for a `CIColorCube`-free byte LUT.
    public func byteTable() -> [UInt8] {
        lookupTable(size: 256).map { UInt8(min(max($0 * 255, 0), 255).rounded()) }
    }
}

extension ToneCurve {
    /// A 256-entry byte table applied to an image, equally to all three
    /// channels — a luminance-shaping point curve, which is what Lightroom's
    /// RGB master curve is.
    ///
    /// `CIColorCurves` rather than a hand-rolled kernel: it interpolates the
    /// table on the GPU and needs no `-fcikernel` build flags, which this
    /// project deliberately does not carry.
    public static func apply(_ table: [UInt8], to image: CIImage) -> CIImage? {
        guard table.count == 256 else { return nil }
        var values: [Float] = []
        values.reserveCapacity(table.count * 3)
        for entry in table {
            let v = Float(entry) / 255
            values.append(contentsOf: [v, v, v])
        }
        guard let filter = CIFilter(name: "CIColorCurves") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(
            Data(bytes: values, count: values.count * MemoryLayout<Float>.size),
            forKey: "inputCurvesData")
        filter.setValue(CIVector(x: 0, y: 1), forKey: "inputCurvesDomain")
        filter.setValue(
            CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
        return filter.outputImage?.cropped(to: image.extent)
    }
}
