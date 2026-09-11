import Foundation
import simd

/// Fitted ellipse in the same coordinate frame as the input points.
struct FittedEllipse {
    var centre: SIMD2<Double>
    var semiMajor: Double
    var semiMinor: Double
    var rotation: Double        // radians, major axis from the +x axis (in the input frame's handedness)

    var ratio: Double { semiMajor > 0 ? semiMinor / semiMajor : 0 }

    /// Map a point into the ellipse's unit frame (centre at origin, axes → unit circle).
    func unitFrame(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let d = p - centre
        let c = cos(rotation), s = sin(rotation)
        let u = d.x * c + d.y * s
        let v = -d.x * s + d.y * c
        return SIMD2(u / semiMajor, v / semiMinor)
    }
}

/// Direct least-squares ellipse fit — Halir & Flusser's numerically stable form of
/// Fitzgibbon's method. Points are normalised (centroid + RMS scale) first, the
/// 3×3 reduced eigenproblem is solved in closed form, and the conic is converted
/// to geometric parameters. Returns nil when the points do not admit an ellipse.
enum EllipseFit {
    static func fit(_ pts: [SIMD2<Double>]) -> FittedEllipse? {
        guard pts.count >= 6 else { return nil }
        // Normalise for conditioning.
        var mean = SIMD2<Double>(0, 0)
        for p in pts { mean += p }
        mean /= Double(pts.count)
        var rms = 0.0
        for p in pts { rms += simd_length_squared(p - mean) }
        rms = sqrt(rms / Double(pts.count))
        guard rms > 1e-12 else { return nil }
        let scale = 1.0 / rms

        // Scatter matrices S1 = D1ᵀD1, S2 = D1ᵀD2, S3 = D2ᵀD2 with D1 = [x² xy y²], D2 = [x y 1].
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
        // T = −S3⁻¹ S2ᵀ ; M = S1 + S2 T ; M' = C1⁻¹ M
        let t = Mat3.scale(Mat3.mul(s3inv, Mat3.transpose(s2)), -1)
        let m = Mat3.add(s1, Mat3.mul(s2, t))
        // C1⁻¹ = [[0,0,.5],[0,-1,0],[.5,0,0]] → rows: m[2]/2, −m[1], m[0]/2
        let mp: [Double] = [
            m[6] / 2, m[7] / 2, m[8] / 2,
            -m[3], -m[4], -m[5],
            m[0] / 2, m[1] / 2, m[2] / 2,
        ]
        guard let a1 = Mat3.ellipseEigenvector(mp) else { return nil }
        let a2 = Mat3.mulVec(t, a1)
        // Conic in the normalised frame: A x² + B xy + C y² + D x + E y + F = 0
        let A = a1[0], B = a1[1], C = a1[2], D = a2[0], E = a2[1], F = a2[2]
        let disc = B * B - 4 * A * C
        guard disc < 0 else { return nil }
        let x0 = (2 * C * D - B * E) / disc
        let y0 = (2 * A * E - B * D) / disc
        let theta = 0.5 * atan2(B, A - C)
        let c = cos(theta), s = sin(theta)
        let Ap = A * c * c + B * c * s + C * s * s
        let Cp = A * s * s - B * c * s + C * c * c
        let Fp = A * x0 * x0 + B * x0 * y0 + C * y0 * y0 + D * x0 + E * y0 + F
        guard Ap != 0, Cp != 0 else { return nil }
        let ru2 = -Fp / Ap, rv2 = -Fp / Cp
        guard ru2 > 0, rv2 > 0 else { return nil }
        var ru = sqrt(ru2), rv = sqrt(rv2), rot = theta
        if rv > ru { swap(&ru, &rv); rot += .pi / 2 }
        // Wrap to (−π/2, π/2]
        while rot > .pi / 2 { rot -= .pi }
        while rot <= -.pi / 2 { rot += .pi }
        let centre = SIMD2<Double>(x0, y0) / scale + mean
        return FittedEllipse(centre: centre, semiMajor: ru / scale, semiMinor: rv / scale, rotation: rot)
    }

    /// Mean |ρ − 1| in the unit frame (fraction of the axis) and angular coverage
    /// (fraction of 10° bins holding at least one point).
    static func quality(_ e: FittedEllipse, _ pts: [SIMD2<Double>]) -> (residual: Double, coverage: Double) {
        var residual = 0.0
        var bins = [Bool](repeating: false, count: 36)
        for p in pts {
            let u = e.unitFrame(p)
            let rho = simd_length(u)
            residual += abs(rho - 1)
            let ang = atan2(u.y, u.x)
            var bin = Int(((ang + .pi) / (2 * .pi)) * 36)
            if bin >= 36 { bin = 35 }
            if bin < 0 { bin = 0 }
            bins[bin] = true
        }
        residual /= Double(max(pts.count, 1))
        let coverage = Double(bins.filter { $0 }.count) / 36
        return (residual, coverage)
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
        // λ³ − tr λ² + c1 λ − det = 0
        let tr = m[0] + m[4] + m[8]
        let m01: Double = m[0] * m[4] - m[1] * m[3]
        let m02: Double = m[0] * m[8] - m[2] * m[6]
        let m12: Double = m[4] * m[8] - m[5] * m[7]
        let c1 = m01 + m02 + m12
        let dt = det(m)
        return Cubic.realRoots(a: 1, b: -tr, c: c1, d: -dt)
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
