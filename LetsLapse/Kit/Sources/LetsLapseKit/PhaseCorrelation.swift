import Foundation
import Accelerate

/// A single-channel float image, row-major, y-down — the measurement's
/// working currency. Values are whatever the producer says they are (linear
/// luma from a raw decode, gamma bytes from a JPEG); the correlator only
/// needs shapes to match, not photometry.
public struct LumaPlane: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height, "LumaPlane: \(pixels.count) pixels for \(width)×\(height)")
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Sub-pixel translation between two frames by phase correlation — the
/// whole-frame Fourier method that made the 2026-09-03 framing audit
/// (`docs/framing-lock.md`): a static scene under a Hanning window dominates
/// the cross-power peak, so trams, people, a flowing river and a sunset's
/// exposure ramp all get out-voted by the architecture.
///
/// Per frame: log-compress (the caller's job — see `FramingMeasurement`),
/// subtract a box blur so vignette and a sky gradient don't vote, window,
/// zero-pad to a power of two, FFT. Per pair: normalised cross-power
/// spectrum, inverse FFT, peak, parabolic sub-sample refinement on each
/// axis. `Shift.dx`/`dy` are how far the CONTENT moved from `anchor` to
/// `current`, in the plane's own pixels, y-down: +dx = moved right, +dy =
/// moved down. `response` is the peak height normalised so identical frames
/// score ~1; a static tripod scene one second apart scores ~0.85, unrelated
/// frames a fraction of that — the same scale as OpenCV's `phaseCorrelate`.
///
/// Not thread-safe: the inverse-FFT scratch is reused between calls. One
/// correlator per worker.
public final class PhaseCorrelator {

    public struct Shift: Equatable, Sendable {
        public var dx: Double
        public var dy: Double
        public var response: Double

        public init(dx: Double, dy: Double, response: Double) {
            self.dx = dx
            self.dy = dy
            self.response = response
        }
    }

    /// A frame's prepared spectrum: high-passed, windowed, padded, transformed.
    /// ~32 MB at 2048×2048; keep only the anchors you need.
    public final class Spectrum {
        fileprivate let real: [Float]
        fileprivate let imag: [Float]
        /// The high-passed, unwindowed plane the spectrum was made from —
        /// what the sub-pixel refinement compares in the spatial domain.
        fileprivate let plane: [Float]

        fileprivate init(real: [Float], imag: [Float], plane: [Float]) {
            self.real = real
            self.imag = imag
            self.plane = plane
        }
    }

    public let width: Int
    public let height: Int
    public let paddedWidth: Int
    public let paddedHeight: Int
    /// Box-blur radius of the high-pass, in plane pixels.
    public let highPassRadius: Int

    private let log2Width: vDSP_Length
    private let log2Height: vDSP_Length
    private let setup: FFTSetup
    private let windowX: [Float]
    private let windowY: [Float]
    private var scratchReal: [Float]
    private var scratchImag: [Float]
    private var scratchMagnitude: [Float]

    public init(width: Int, height: Int, highPassRadius: Int = 24) {
        precondition(width >= 16 && height >= 16, "PhaseCorrelator needs at least a 16×16 plane")
        self.width = width
        self.height = height
        self.highPassRadius = max(0, highPassRadius)
        log2Width = vDSP_Length(Self.log2Ceil(width))
        log2Height = vDSP_Length(Self.log2Ceil(height))
        paddedWidth = 1 << Int(log2Width)
        paddedHeight = 1 << Int(log2Height)
        guard let setup = vDSP_create_fftsetup(max(log2Width, log2Height), FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed for \(width)×\(height)")
        }
        self.setup = setup
        var wx = [Float](repeating: 0, count: width)
        var wy = [Float](repeating: 0, count: height)
        vDSP_hann_window(&wx, vDSP_Length(width), Int32(vDSP_HANN_DENORM))
        vDSP_hann_window(&wy, vDSP_Length(height), Int32(vDSP_HANN_DENORM))
        windowX = wx
        windowY = wy
        let count = paddedWidth * paddedHeight
        scratchReal = [Float](repeating: 0, count: count)
        scratchImag = [Float](repeating: 0, count: count)
        scratchMagnitude = [Float](repeating: 0, count: count)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    private static func log2Ceil(_ value: Int) -> Int {
        var bits = 0
        while (1 << bits) < value { bits += 1 }
        return bits
    }

    // MARK: - Preparation

    /// The plane's spectrum, ready to correlate. The plane must be this
    /// correlator's size.
    public func spectrum(of plane: LumaPlane) -> Spectrum {
        precondition(plane.width == width && plane.height == height, "plane is \(plane.width)×\(plane.height), correlator is \(width)×\(height)")
        var highPassed = highPassRadius > 0 ? Self.highPass(plane.pixels, width: width, height: height, radius: highPassRadius) : plane.pixels
        let count = paddedWidth * paddedHeight
        var real = [Float](repeating: 0, count: count)
        var imag = [Float](repeating: 0, count: count)
        // Window and place. Position inside the padding is irrelevant to the
        // correlation as long as every frame uses the same one.
        highPassed.withUnsafeMutableBufferPointer { source in
            real.withUnsafeMutableBufferPointer { destination in
                var rowScratch = [Float](repeating: 0, count: width)
                for y in 0..<height {
                    var rowWeight = windowY[y]
                    let sourceRow = source.baseAddress! + y * width
                    vDSP_vsmul(sourceRow, 1, &rowWeight, &rowScratch, 1, vDSP_Length(width))
                    vDSP_vmul(rowScratch, 1, windowX, 1, destination.baseAddress! + y * paddedWidth, 1, vDSP_Length(width))
                }
            }
        }
        forwardTransform(real: &real, imag: &imag)
        return Spectrum(real: real, imag: imag, plane: highPassed)
    }

    /// `pixels` minus its own box blur (radius `radius`, edge-clamped),
    /// separable, double-precision running sums.
    static func highPass(_ pixels: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var blurred = [Float](repeating: 0, count: pixels.count)
        // Horizontal pass into `blurred`.
        var prefix = [Double](repeating: 0, count: width + 1)
        for y in 0..<height {
            let row = y * width
            prefix[0] = 0
            for x in 0..<width { prefix[x + 1] = prefix[x] + Double(pixels[row + x]) }
            for x in 0..<width {
                let low = max(0, x - radius)
                let high = min(width - 1, x + radius)
                blurred[row + x] = Float((prefix[high + 1] - prefix[low]) / Double(high - low + 1))
            }
        }
        // Vertical pass, column by column over the horizontal result.
        var column = [Double](repeating: 0, count: height + 1)
        var result = [Float](repeating: 0, count: pixels.count)
        for x in 0..<width {
            column[0] = 0
            for y in 0..<height { column[y + 1] = column[y] + Double(blurred[y * width + x]) }
            for y in 0..<height {
                let low = max(0, y - radius)
                let high = min(height - 1, y + radius)
                let mean = Float((column[high + 1] - column[low]) / Double(high - low + 1))
                result[y * width + x] = pixels[y * width + x] - mean
            }
        }
        return result
    }

    private func forwardTransform(real: inout [Float], imag: inout [Float]) {
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft2d_zip(setup, &split, 1, 0, log2Width, log2Height, FFTDirection(kFFTDirection_Forward))
            }
        }
    }

    // MARK: - Correlation

    /// How far the content of `current` sits from the content of `anchor`.
    public func shift(from anchor: Spectrum, to current: Spectrum) -> Shift {
        let count = paddedWidth * paddedHeight
        let n = vDSP_Length(count)
        // Read-only access to the two spectra (`DSPSplitComplex` wants
        // mutable pointers even for inputs, so cast): the same spectrum may
        // legitimately be both anchor and current, and two mutating
        // accesses to one array would trap on exclusivity.
        anchor.real.withUnsafeBufferPointer { ar in
            anchor.imag.withUnsafeBufferPointer { ai in
                current.real.withUnsafeBufferPointer { cr in
                    current.imag.withUnsafeBufferPointer { ci in
                        scratchReal.withUnsafeMutableBufferPointer { sr in
                            scratchImag.withUnsafeMutableBufferPointer { si in
                                scratchMagnitude.withUnsafeMutableBufferPointer { mag in
                                    var a = DSPSplitComplex(
                                        realp: UnsafeMutablePointer(mutating: ar.baseAddress!),
                                        imagp: UnsafeMutablePointer(mutating: ai.baseAddress!))
                                    var c = DSPSplitComplex(
                                        realp: UnsafeMutablePointer(mutating: cr.baseAddress!),
                                        imagp: UnsafeMutablePointer(mutating: ci.baseAddress!))
                                    var s = DSPSplitComplex(realp: sr.baseAddress!, imagp: si.baseAddress!)
                                    // conj(A)·C: the peak lands at +δ when the
                                    // content moved by +δ (pinned by the tests).
                                    vDSP_zvmul(&a, 1, &c, 1, &s, 1, n, -1)
                                    vDSP_zvabs(&s, 1, mag.baseAddress!, 1, n)
                                    var epsilon: Float = 1e-6
                                    vDSP_vsadd(mag.baseAddress!, 1, &epsilon, mag.baseAddress!, 1, n)
                                    vDSP_zrvdiv(&s, 1, mag.baseAddress!, 1, &s, 1, n)
                                    vDSP_fft2d_zip(setup, &s, 1, 0, log2Width, log2Height, FFTDirection(kFFTDirection_Inverse))
                                }
                            }
                        }
                    }
                }
            }
        }
        // The surface is real: its peak is the integer shift, and the sum of
        // the 5×5 neighbourhood is the response (OpenCV's `phaseCorrelate`
        // reports the same sum): identical frames score ~1, a static scene
        // a second apart ~0.85.
        var peakValue: Float = 0
        var peakIndex: vDSP_Length = 0
        vDSP_maxvi(scratchReal, 1, &peakValue, &peakIndex, n)
        let px = Int(peakIndex) % paddedWidth
        let py = Int(peakIndex) / paddedWidth
        var sum = 0.0
        for oy in -2...2 {
            for ox in -2...2 {
                let wx = (((px + ox) % paddedWidth) + paddedWidth) % paddedWidth
                let wy = (((py + oy) % paddedHeight) + paddedHeight) % paddedHeight
                sum += Double(scratchReal[wy * paddedWidth + wx])
            }
        }
        let dx0 = px > paddedWidth / 2 ? px - paddedWidth : px
        let dy0 = py > paddedHeight / 2 ? py - paddedHeight : py
        let response = max(0, sum) / Double(count)
        // Sub-pixel: the phase-correlation peak is a sharp delta, and both a
        // parabola and a centroid through it lock toward whole pixels
        // (measured 0.25 → 0.09 and errors up to 0.75 px on smooth scenes).
        // The residual is instead solved in the spatial domain: a few
        // Gauss-Newton steps of the translation-only least squares ECC and
        // Lucas–Kanade end with, on the high-passed planes, starting from
        // the integer peak.
        let refined = Self.refine(anchor: anchor.plane, current: current.plane, width: width, height: height, dx0: dx0, dy0: dy0)
        return Shift(dx: Double(dx0) + refined.dx, dy: Double(dy0) + refined.dy, response: response)
    }

    /// The residual translation (|r| ≤ 1.5 px) between `anchor` sampled at
    /// `x − r` and `current` read at `x + (dx0, dy0)`, by Gauss–Newton over
    /// the overlap: linearise the model around the current residual, solve
    /// the 2×2 normal equations, step, repeat until the step is under 3‰ of
    /// a pixel. Zero when the overlap is too small to trust.
    static func refine(
        anchor: [Float], current: [Float], width: Int, height: Int, dx0: Int, dy0: Int
    ) -> (dx: Double, dy: Double) {
        let margin = max(abs(dx0), abs(dy0)) + 3
        guard margin * 4 < min(width, height) else { return (0, 0) }
        let x0 = margin, x1 = width - margin
        let y0 = margin, y1 = height - margin
        let regionWidth = x1 - x0 + 2
        let regionHeight = y1 - y0 + 2
        var model = [Float](repeating: 0, count: regionWidth * regionHeight)
        var rx = 0.0, ry = 0.0
        var gain = 1.0
        anchor.withUnsafeBufferPointer { a in
            current.withUnsafeBufferPointer { c in
                model.withUnsafeMutableBufferPointer { m in
                    for _ in 0..<5 {
                        // The model: the anchor resampled at (x − r), over the
                        // region plus a one-pixel apron for the gradient.
                        for j in 0..<regionHeight {
                            let sy = Double(y0 - 1 + j) - ry
                            let iy = Int(sy.rounded(.down))
                            let fy = Float(sy - Double(iy))
                            let row0 = min(max(iy, 0), height - 1) * width
                            let row1 = min(max(iy + 1, 0), height - 1) * width
                            for i in 0..<regionWidth {
                                let sx = Double(x0 - 1 + i) - rx
                                let ix = Int(sx.rounded(.down))
                                let fx = Float(sx - Double(ix))
                                let col0 = min(max(ix, 0), width - 1)
                                let col1 = min(max(ix + 1, 0), width - 1)
                                let top = a[row0 + col0] * (1 - fx) + a[row0 + col1] * fx
                                let bottom = a[row1 + col0] * (1 - fx) + a[row1 + col1] * fx
                                m[j * regionWidth + i] = top * (1 - fy) + bottom * fy
                            }
                        }
                        // Normal equations for u = (Δx, Δy, γ): the frame is
                        // modelled as (1 + γ)·M(x − Δ), so a gain difference
                        // between the two frames (an exposure step, before the
                        // log takes it out) lands in γ instead of biasing Δ.
                        // b ≈ −Δx·gx − Δy·gy + γ·M.
                        var n = [Double](repeating: 0, count: 9)
                        var rhs = [Double](repeating: 0, count: 3)
                        for y in y0..<y1 {
                            let j = y - y0 + 1
                            let currentRow = (y + dy0) * width + dx0
                            for x in x0..<x1 {
                                let i = x - x0 + 1
                                let centre = j * regionWidth + i
                                let mv = Double(m[centre]) * gain
                                let v0 = -Double(m[centre + 1] - m[centre - 1]) * 0.5 * gain
                                let v1 = -Double(m[centre + regionWidth] - m[centre - regionWidth]) * 0.5 * gain
                                let v2 = mv
                                let b = Double(c[currentRow + x]) - mv
                                n[0] += v0 * v0; n[1] += v0 * v1; n[2] += v0 * v2
                                n[4] += v1 * v1; n[5] += v1 * v2
                                n[8] += v2 * v2
                                rhs[0] += v0 * b; rhs[1] += v1 * b; rhs[2] += v2 * b
                            }
                        }
                        n[3] = n[1]; n[6] = n[2]; n[7] = n[5]
                        guard let u = solve3(n, rhs) else { break }
                        let stepX = u[0], stepY = u[1]
                        rx = min(max(rx + stepX, -1.5), 1.5)
                        ry = min(max(ry + stepY, -1.5), 1.5)
                        gain *= max(0.25, min(4, 1 + u[2]))
                        if abs(stepX) < 0.003 && abs(stepY) < 0.003 { break }
                    }
                }
            }
        }
        return (rx, ry)
    }

    /// Cramer's rule for a 3×3 system, nil when singular.
    private static func solve3(_ a: [Double], _ b: [Double]) -> [Double]? {
        func det(_ m: [Double]) -> Double {
            m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
        }
        let d = det(a)
        guard abs(d) > 1e-18 else { return nil }
        var result = [Double](repeating: 0, count: 3)
        for column in 0..<3 {
            var m = a
            for row in 0..<3 { m[row * 3 + column] = b[row] }
            result[column] = det(m) / d
        }
        return result
    }

    /// Sub-sample peak position from three samples, in [-0.5, 0.5]; 0 when
    /// the three don't describe a peak.
    static func parabolicOffset(left: Double, centre: Double, right: Double) -> Double {
        let denominator = left - 2 * centre + right
        guard denominator < 0 else { return 0 }
        let delta = 0.5 * (left - right) / denominator
        return min(max(delta, -0.5), 0.5)
    }
}
