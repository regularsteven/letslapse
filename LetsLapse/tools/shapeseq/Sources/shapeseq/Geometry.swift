import Foundation
import CoreGraphics
import simd

/// 3×3 projective transform, row-major. Points are column vectors [x y 1]ᵀ.
struct Homography {
    var m: [Double]   // 9 entries

    static let identity = Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    static func translate(_ tx: Double, _ ty: Double) -> Homography {
        Homography(m: [1, 0, tx, 0, 1, ty, 0, 0, 1])
    }
    static func scale(_ sx: Double, _ sy: Double) -> Homography {
        Homography(m: [sx, 0, 0, 0, sy, 0, 0, 0, 1])
    }
    static func rotate(_ theta: Double) -> Homography {
        let c = cos(theta), s = sin(theta)
        return Homography(m: [c, -s, 0, s, c, 0, 0, 0, 1])
    }

    /// self ∘ other — apply `other` first, then `self`.
    static func * (lhs: Homography, rhs: Homography) -> Homography {
        Homography(m: Mat3.mul(lhs.m, rhs.m))
    }

    func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        let u = (m[0] * x + m[1] * y + m[2]) / w
        let v = (m[3] * x + m[4] * y + m[5]) / w
        return CGPoint(x: u, y: v)
    }

    var inverse: Homography? { Mat3.inverse(m).map { Homography(m: $0) } }

    var isAffine: Bool { abs(m[6]) < 1e-12 && abs(m[7]) < 1e-12 && abs(m[8] - 1) < 1e-9 }

    var affine: CGAffineTransform {
        // CGAffineTransform maps [x y 1] · [[a b 0][c d 0][tx ty 1]] → x' = a x + c y + tx
        CGAffineTransform(a: m[0], b: m[3], c: m[1], d: m[4], tx: m[2], ty: m[5])
    }

    /// Direct linear transform from four correspondences (h33 = 1).
    static func from(_ src: [CGPoint], to dst: [CGPoint]) -> Homography? {
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

enum Polygon {
    /// Shoelace area of a simple polygon.
    static func area(_ p: [CGPoint]) -> Double {
        guard p.count >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<p.count {
            let a = p[i], b = p[(i + 1) % p.count]
            s += Double(a.x * b.y - b.x * a.y)
        }
        return abs(s) / 2
    }

    /// Sutherland–Hodgman clip of a convex polygon against an axis-aligned rect.
    static func clip(_ poly: [CGPoint], to rect: CGRect) -> [CGPoint] {
        var out = poly
        let edges: [(CGPoint) -> Bool] = [
            { $0.x >= rect.minX }, { $0.x <= rect.maxX }, { $0.y >= rect.minY }, { $0.y <= rect.maxY },
        ]
        let intersect: [(CGPoint, CGPoint) -> CGPoint] = [
            { a, b in Polygon.lerpX(a, b, rect.minX) }, { a, b in Polygon.lerpX(a, b, rect.maxX) },
            { a, b in Polygon.lerpY(a, b, rect.minY) }, { a, b in Polygon.lerpY(a, b, rect.maxY) },
        ]
        for e in 0..<4 {
            let input = out
            out = []
            guard !input.isEmpty else { break }
            var prev = input[input.count - 1]
            for cur in input {
                let curIn = edges[e](cur), prevIn = edges[e](prev)
                if curIn {
                    if !prevIn { out.append(intersect[e](prev, cur)) }
                    out.append(cur)
                } else if prevIn {
                    out.append(intersect[e](prev, cur))
                }
                prev = cur
            }
        }
        return out
    }

    private static func lerpX(_ a: CGPoint, _ b: CGPoint, _ x: CGFloat) -> CGPoint {
        let t = (x - a.x) / (b.x - a.x)
        return CGPoint(x: x, y: a.y + (b.y - a.y) * t)
    }
    private static func lerpY(_ a: CGPoint, _ b: CGPoint, _ y: CGFloat) -> CGPoint {
        let t = (y - a.y) / (b.y - a.y)
        return CGPoint(x: a.x + (b.x - a.x) * t, y: y)
    }

    /// Fraction of `frame` covered by the convex quad `poly` (0…1).
    static func coverage(of poly: [CGPoint], in frame: CGRect) -> Double {
        let clipped = clip(poly, to: frame)
        let a = area(clipped)
        let f = Double(frame.width * frame.height)
        return f > 0 ? min(1, a / f) : 0
    }
}
