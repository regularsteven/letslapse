import Foundation
import CoreGraphics
import simd

// Geometry for the Shape-mation feature: a 3×3 homography, a direct
// least-squares ellipse fit, and the polygon helpers the composer needs.
// Ported from the shape-sequence spike (docs/shape-sequence-spike/), which
// verified the fit on a synthetic card to 0.02° and 0.3 px.

/// 3×3 projective transform, row-major, acting on column vectors [x y 1]ᵀ.
public struct Homography: Equatable, Sendable {
    public var m: [Double]   // 9 entries

    public init(m: [Double]) { self.m = m }

    public static let identity = Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    public static func translate(_ tx: Double, _ ty: Double) -> Homography {
        Homography(m: [1, 0, tx, 0, 1, ty, 0, 0, 1])
    }
    public static func scale(_ sx: Double, _ sy: Double) -> Homography {
        Homography(m: [sx, 0, 0, 0, sy, 0, 0, 0, 1])
    }
    public static func rotate(_ theta: Double) -> Homography {
        let c = cos(theta), s = sin(theta)
        return Homography(m: [c, -s, 0, s, c, 0, 0, 0, 1])
    }

    /// `lhs ∘ rhs` — apply `rhs` first, then `lhs`.
    public static func * (lhs: Homography, rhs: Homography) -> Homography {
        Homography(m: Mat3.mul(lhs.m, rhs.m))
    }

    public func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        let u = (m[0] * x + m[1] * y + m[2]) / w
        let v = (m[3] * x + m[4] * y + m[5]) / w
        return CGPoint(x: u, y: v)
    }

    public var inverse: Homography? { Mat3.inverse(m).map { Homography(m: $0) } }

    public var isAffine: Bool { abs(m[6]) < 1e-12 && abs(m[7]) < 1e-12 && abs(m[8] - 1) < 1e-9 }

    /// The affine part as Core Graphics sees it (x' = a x + c y + tx).
    public var affine: CGAffineTransform {
        CGAffineTransform(a: m[0], b: m[3], c: m[1], d: m[4], tx: m[2], ty: m[5])
    }

    /// Direct linear transform from four correspondences (h33 = 1).
    public static func from(_ src: [CGPoint], to dst: [CGPoint]) -> Homography? {
        guard src.count == 4, dst.count == 4 else { return nil }
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let x = Double(src[i].x), y = Double(src[i].y)
            let u = Double(dst[i].x), v = Double(dst[i].y)
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        guard let h = LinearSolve.gaussian(a) else { return nil }
        return Homography(m: h + [1])
    }
}

enum LinearSolve {
    /// Solve an n×(n+1) augmented system by Gaussian elimination with partial pivoting.
    static func gaussian(_ input: [[Double]]) -> [Double]? {
        var a = input
        let n = a.count
        for col in 0..<n {
            var pivot = col
            for r in col..<n where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            for r in 0..<n where r != col {
                let f = a[r][col] / a[col][col]
                if f == 0 { continue }
                for c in col...n { a[r][c] -= f * a[col][c] }
            }
        }
        return (0..<n).map { a[$0][n] / a[$0][$0] }
    }
}

public enum ShapePolygon {
    /// Shoelace area of a simple polygon.
    public static func area(_ p: [CGPoint]) -> Double {
        guard p.count >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<p.count {
            let a = p[i], b = p[(i + 1) % p.count]
            s += Double(a.x * b.y - b.x * a.y)
        }
        return abs(s) / 2
    }

    /// Axis-aligned bounds of a point set.
    public static func bounds(_ p: [CGPoint]) -> CGRect {
        guard let first = p.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for q in p.dropFirst() {
            minX = min(minX, q.x); maxX = max(maxX, q.x)
            minY = min(minY, q.y); maxY = max(maxY, q.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Fitted ellipse in the same coordinate frame as the input points.
public struct FittedEllipse: Equatable, Sendable {
    public var centre: SIMD2<Double>
    public var semiMajor: Double
    public var semiMinor: Double
    /// Radians, major axis from the +x axis (in the input frame's handedness).
    public var rotation: Double

    public var ratio: Double { semiMajor > 0 ? semiMinor / semiMajor : 0 }

    /// Map a point into the ellipse's unit frame (centre at origin, axes → unit circle).
    public func unitFrame(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let d = p - centre
        let c = cos(rotation), s = sin(rotation)
        let u = d.x * c + d.y * s
        let v = -d.x * s + d.y * c
        return SIMD2(u / semiMajor, v / semiMinor)
    }
}

/// Direct least-squares ellipse fit — Halir & Flusser's numerically stable form
/// of Fitzgibbon's method. Points are normalised (centroid + RMS scale) first,
/// the reduced 3×3 eigenproblem is solved in closed form, and the conic is
/// converted to geometric parameters. Nil when the points admit no ellipse.
public enum EllipseFit {
    public static func fit(_ pts: [SIMD2<Double>]) -> FittedEllipse? {
        guard pts.count >= 6 else { return nil }
        var mean = SIMD2<Double>(0, 0)
        for p in pts { mean += p }
        mean /= Double(pts.count)
        var rms = 0.0
        for p in pts { rms += simd_length_squared(p - mean) }
        rms = sqrt(rms / Double(pts.count))
        guard rms > 1e-12 else { return nil }
        let scale = 1.0 / rms

        var s1 = [Double](repeating: 0, count: 9)
        var s2 = [Double](repeating: 0, count: 9)
        var s3 = [Double](repeating: 0, count: 9)
        for p in pts {
            let q = (p - mean) * scale
            let d1 = [q.x * q.x, q.x * q.y, q.y * q.y]
            let d2 = [q.x, q.y, 1.0]
            for i in 0..<3 { for j in 0..<3 {
                s1[i * 3 + j] += d1[i] * d1[j]
                s2[i * 3 + j] += d1[i] * d2[j]
                s3[i * 3 + j] += d2[i] * d2[j]
            } }
        }
        guard let s3inv = Mat3.inverse(s3) else { return nil }
        let t = Mat3.scale(Mat3.mul(s3inv, Mat3.transpose(s2)), -1)
        let m = Mat3.add(s1, Mat3.mul(s2, t))
        let mp: [Double] = [
            m[6] / 2, m[7] / 2, m[8] / 2,
            -m[3], -m[4], -m[5],
            m[0] / 2, m[1] / 2, m[2] / 2,
        ]
        guard let a1 = Mat3.ellipseEigenvector(mp) else { return nil }
        let a2 = Mat3.mulVec(t, a1)
        let A = a1[0], B = a1[1], C = a1[2], D = a2[0], E = a2[1], F = a2[2]
        let disc = B * B - 4 * A * C
        guard disc < 0 else { return nil }
        let x0 = (2 * C * D - B * E) / disc
        let y0 = (2 * A * E - B * D) / disc
        let theta = 0.5 * atan2(B, A - C)
        let c = cos(theta), s = sin(theta)
        let Ap = A * c * c + B * c * s + C * s * s
        let Cp = A * s * s - B * c * s + C * c * c
        let Fp0: Double = A * x0 * x0 + B * x0 * y0
        let Fp1: Double = C * y0 * y0 + D * x0
        let Fp = Fp0 + Fp1 + E * y0 + F
        guard Ap != 0, Cp != 0 else { return nil }
        let ru2 = -Fp / Ap, rv2 = -Fp / Cp
        guard ru2 > 0, rv2 > 0 else { return nil }
        var ru = sqrt(ru2), rv = sqrt(rv2), rot = theta
        if rv > ru { swap(&ru, &rv); rot += .pi / 2 }
        while rot > .pi / 2 { rot -= .pi }
        while rot <= -.pi / 2 { rot += .pi }
        let centre = SIMD2<Double>(x0, y0) / scale + mean
        return FittedEllipse(centre: centre, semiMajor: ru / scale, semiMinor: rv / scale, rotation: rot)
    }

    /// Mean |ρ − 1| in the unit frame (fraction of the axis) and angular coverage
    /// (fraction of 10° bins holding at least one point).
    public static func quality(_ e: FittedEllipse, _ pts: [SIMD2<Double>]) -> (residual: Double, coverage: Double) {
        var residual = 0.0
        var bins = [Bool](repeating: false, count: 36)
        for p in pts {
            let u = e.unitFrame(p)
            residual += abs(simd_length(u) - 1)
            let ang = atan2(u.y, u.x)
            var bin = Int(((ang + .pi) / (2 * .pi)) * 36)
            bin = max(0, min(35, bin))
            bins[bin] = true
        }
        residual /= Double(max(pts.count, 1))
        return (residual, Double(bins.filter { $0 }.count) / 36)
    }
}

/// Minimal 3×3 double-precision matrix helpers (row-major arrays of 9).
enum Mat3 {
    static func mul(_ a: [Double], _ b: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { r[i * 3 + j] += a[i * 3 + k] * b[k * 3 + j] } } }
        return r
    }
    static func mulVec(_ a: [Double], _ v: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: 3)
        for i in 0..<3 {
            let x: Double = a[i * 3] * v[0]
            let y: Double = a[i * 3 + 1] * v[1]
            let z: Double = a[i * 3 + 2] * v[2]
            r[i] = x + y + z
        }
        return r
    }
    static func add(_ a: [Double], _ b: [Double]) -> [Double] { zip(a, b).map(+) }
    static func scale(_ a: [Double], _ s: Double) -> [Double] { a.map { $0 * s } }
    static func transpose(_ a: [Double]) -> [Double] {
        [a[0], a[3], a[6], a[1], a[4], a[7], a[2], a[5], a[8]]
    }
    static func det(_ m: [Double]) -> Double {
        let t0: Double = m[0] * (m[4] * m[8] - m[5] * m[7])
        let t1: Double = m[1] * (m[3] * m[8] - m[5] * m[6])
        let t2: Double = m[2] * (m[3] * m[7] - m[4] * m[6])
        return t0 - t1 + t2
    }
    static func inverse(_ m: [Double]) -> [Double]? {
        let d = det(m)
        guard abs(d) > 1e-300 else { return nil }
        let inv = 1 / d
        let c00 = m[4] * m[8] - m[5] * m[7]
        let c01 = m[2] * m[7] - m[1] * m[8]
        let c02 = m[1] * m[5] - m[2] * m[4]
        let c10 = m[5] * m[6] - m[3] * m[8]
        let c11 = m[0] * m[8] - m[2] * m[6]
        let c12 = m[2] * m[3] - m[0] * m[5]
        let c20 = m[3] * m[7] - m[4] * m[6]
        let c21 = m[1] * m[6] - m[0] * m[7]
        let c22 = m[0] * m[4] - m[1] * m[3]
        return [c00 * inv, c01 * inv, c02 * inv, c10 * inv, c11 * inv, c12 * inv, c20 * inv, c21 * inv, c22 * inv]
    }

    /// Real eigenvalues of a general 3×3 matrix via the characteristic cubic.
    static func realEigenvalues(_ m: [Double]) -> [Double] {
        let tr = m[0] + m[4] + m[8]
        let m01: Double = m[0] * m[4] - m[1] * m[3]
        let m02: Double = m[0] * m[8] - m[2] * m[6]
        let m12: Double = m[4] * m[8] - m[5] * m[7]
        let c1 = m01 + m02 + m12
        return Cubic.realRoots(a: 1, b: -tr, c: c1, d: -det(m))
    }

    /// Null-space direction of (m − λI) by the largest cross product of its rows.
    static func nullVector(_ m: [Double], lambda: Double) -> [Double]? {
        var a = m
        a[0] -= lambda; a[4] -= lambda; a[8] -= lambda
        let rows = (0..<3).map { SIMD3<Double>(a[$0 * 3], a[$0 * 3 + 1], a[$0 * 3 + 2]) }
        var best = SIMD3<Double>(0, 0, 0)
        var bestLen = 0.0
        for (i, j) in [(0, 1), (0, 2), (1, 2)] {
            let c = simd_cross(rows[i], rows[j])
            let l = simd_length(c)
            if l > bestLen { bestLen = l; best = c }
        }
        guard bestLen > 1e-14 else { return nil }
        best /= bestLen
        return [best.x, best.y, best.z]
    }

    /// The eigenvector of the reduced Halir–Flusser matrix that satisfies the
    /// ellipse constraint 4ac − b² > 0. Exactly one does for real ellipse data.
    static func ellipseEigenvector(_ m: [Double]) -> [Double]? {
        var best: [Double]? = nil
        var bestCond = 0.0
        for lambda in realEigenvalues(m) {
            guard let v = nullVector(m, lambda: lambda) else { continue }
            let cond = 4 * v[0] * v[2] - v[1] * v[1]
            if cond > bestCond { bestCond = cond; best = v }
        }
        return best
    }
}

enum Cubic {
    /// Real roots of a x³ + b x² + c x + d = 0 (a ≠ 0), trigonometric/Cardano.
    static func realRoots(a: Double, b: Double, c: Double, d: Double) -> [Double] {
        let b = b / a, c = c / a, d = d / a
        let q = (3 * c - b * b) / 9
        let r = (9 * b * c - 27 * d - 2 * b * b * b) / 54
        let disc = q * q * q + r * r
        let shift = -b / 3
        if disc > 0 {
            let s = cbrt(r + sqrt(disc))
            let t = cbrt(r - sqrt(disc))
            return [shift + s + t]
        } else {
            let rho = sqrt(max(-q * q * q, 0))
            let theta = rho > 0 ? acos(max(-1, min(1, r / rho))) : 0
            let m = 2 * sqrt(max(-q, 0))
            return [
                shift + m * cos(theta / 3),
                shift + m * cos((theta + 2 * .pi) / 3),
                shift + m * cos((theta + 4 * .pi) / 3),
            ]
        }
    }
}
