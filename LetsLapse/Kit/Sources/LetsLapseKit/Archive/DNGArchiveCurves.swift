import Accelerate
import Foundation


extension DNGArchive {
    /// How linear light becomes the integer a tile stores, and the DNG levels
    /// that let a reader undo it.
    ///
    /// - `linear`: stored = pedestal + L·(white − pedestal). Bit-exact for
    ///   lossless codecs; wasteful for lossy ones, which spend bits evenly across
    ///   a range the eye reads logarithmically.
    /// - `gammaLUT`: stored = S_b + (Smax − S_b)·L^(1/γ) above black, a linear
    ///   ramp below it. Carried as a `LinearizationTable`, a DNG 1.0 feature
    ///   every reader implements; keeps noise under black; no opcodes.
    /// - `cubic`: Adobe's shape — L = c1·x + (1 − c1)·x³, carried as a
    ///   `MapPolynomial` over a zero black level. No pedestal (negatives clip),
    ///   so it depends on Apple handling the polynomial with black = 0, which
    ///   `DNGArchiveTests` shows it does.
    public enum Curve: Equatable, Sendable {
        case linear
        case gammaLUT(gamma: Double)
        case cubic(c1: Double)

        public var label: String {
            switch self {
            case .linear: return "linear"
            case .gammaLUT(let gamma): return "lut\(String(format: "%.1f", gamma))"
            case .cubic(let c1): return "cubic\(String(format: "%.2f", c1))"
            }
        }
    }

    public struct StoredEncoding: Sendable {
        public let curve: Curve
        public let bitsPerSample: Int
        /// Linearized-unit black level (and, for `.linear`, the stored pedestal).
        public let pedestal: Int

        public var storedMax: Int { (1 << bitsPerSample) - 1 }
        /// The linearized domain is always 16-bit; 8-bit stores index a
        /// 256-entry table into it.
        public var linearizedMax: Int { 65535 }
        public var storedPedestal: Int { Int((Double(pedestal) / 65535 * Double(storedMax)).rounded()) }

        public init(curve: Curve, bitsPerSample: Int = 16, pedestal: Int = 2048) {
            self.curve = curve
            self.bitsPerSample = bitsPerSample
            self.pedestal = curve == .linear && bitsPerSample == 16 ? pedestal : (bitsPerSample == 16 ? pedestal : pedestal)
            precondition(bitsPerSample == 16 || bitsPerSample == 8)
        }

        public var label: String { "\(curve.label)-\(bitsPerSample)b" }

        // MARK: - Levels the reader sees

        public func levels(samplesPerPixel: Int) -> DNGArchive.Levels {
            switch curve {
            case .linear:
                return DNGArchive.Levels(black: [Double(storedPedestal)], white: [UInt32(storedMax)])
            case .gammaLUT(let gamma):
                return DNGArchive.Levels(black: [Double(pedestal)], white: [UInt32(linearizedMax)], linearizationTable: table(gamma: gamma))
            case .cubic(let c1):
                return DNGArchive.Levels(black: [0], white: [UInt32(storedMax)],
                                         mapPolynomials: Array(repeating: [0, c1, 0, 1 - c1], count: samplesPerPixel))
            }
        }

        /// stored → linearized, for the gamma carrier.
        private func table(gamma: Double) -> [UInt16] {
            let entries = storedMax + 1
            let sb = Double(storedPedestal), smax = Double(storedMax)
            let b = Double(pedestal), w = Double(linearizedMax)
            var table = [UInt16](repeating: 0, count: entries)
            for s in 0..<entries {
                let stored = Double(s)
                let linearized: Double
                if stored >= sb {
                    linearized = b + (w - b) * pow((stored - sb) / (smax - sb), gamma)
                } else {
                    linearized = b * stored / sb
                }
                table[s] = UInt16(max(0, min(w, linearized.rounded())))
            }
            return table
        }

        // MARK: - Encoding linear light

        /// The inverse of the cubic, sampled at 16 bits, built once per encoding.
        nonisolated(unsafe) private static var cubicInverseCache: [Double: [Float]] = [:]
        private static let cacheLock = NSLock()

        private func cubicInverse(c1: Double) -> [Float] {
            Self.cacheLock.lock()
            defer { Self.cacheLock.unlock() }
            if let cached = Self.cubicInverseCache[c1] { return cached }
            // P(x) = c1 x + (1-c1) x^3 is monotonic on [0,1]; invert by scanning.
            let n = 65536
            var inverse = [Float](repeating: 0, count: n)
            let c3 = 1 - c1
            var x = 0.0
            let step = 1.0 / Double(n * 8)
            for i in 0..<n {
                let target = Double(i) / Double(n - 1)
                while x < 1, c1 * x + c3 * x * x * x < target { x += step }
                inverse[i] = Float(min(1, x))
            }
            Self.cubicInverseCache[c1] = inverse
            return inverse
        }

        /// Encodes `count` linear samples into 16-bit stored values.
        public func encode16(_ linear: UnsafePointer<Float>, count: Int, into out: UnsafeMutablePointer<UInt16>) {
            precondition(bitsPerSample == 16)
            let n = vDSP_Length(count)
            var scratch = [Float](repeating: 0, count: count)
            var low: Float = 0, high = Float(storedMax)
            switch curve {
            case .linear:
                var scale = Float(storedMax - storedPedestal), offset = Float(storedPedestal)
                vDSP_vsmsa(linear, 1, &scale, &offset, &scratch, 1, n)
            case .gammaLUT(let gamma):
                encodeGamma(linear, count: count, gamma: gamma, into: &scratch)
            case .cubic(let c1):
                let inverse = cubicInverse(c1: c1)
                var zero: Float = 0, one: Float = 1
                vDSP_vclip(linear, 1, &zero, &one, &scratch, 1, n)
                var s1 = Float(inverse.count - 1), s2: Float = 0
                var indexed = [Float](repeating: 0, count: count)
                inverse.withUnsafeBufferPointer { tablePointer in
                    vDSP_vtabi(scratch, 1, &s1, &s2, tablePointer.baseAddress!, vDSP_Length(inverse.count), &indexed, 1, n)
                }
                var scale = Float(storedMax), offset: Float = 0
                vDSP_vsmsa(indexed, 1, &scale, &offset, &scratch, 1, n)
            }
            vDSP_vclip(scratch, 1, &low, &high, &scratch, 1, n)
            vDSP_vfixru16(scratch, 1, out, 1, n)
        }

        /// Encodes `count` linear samples into 8-bit stored values (gamma
        /// carrier, Adobe's cubic, or plain linear for the diagnostic case).
        public func encode8(_ linear: UnsafePointer<Float>, count: Int, into out: UnsafeMutablePointer<UInt8>) {
            precondition(bitsPerSample == 8)
            let n = vDSP_Length(count)
            var scratch = [Float](repeating: 0, count: count)
            switch curve {
            case .gammaLUT(let gamma):
                encodeGamma(linear, count: count, gamma: gamma, into: &scratch)
            case .cubic(let c1):
                let inverse = cubicInverse(c1: c1)
                var zero: Float = 0, one: Float = 1
                vDSP_vclip(linear, 1, &zero, &one, &scratch, 1, n)
                var s1 = Float(inverse.count - 1), s2: Float = 0
                var indexed = [Float](repeating: 0, count: count)
                inverse.withUnsafeBufferPointer { tablePointer in
                    vDSP_vtabi(scratch, 1, &s1, &s2, tablePointer.baseAddress!, vDSP_Length(inverse.count), &indexed, 1, n)
                }
                var scale = Float(storedMax), offset: Float = 0
                vDSP_vsmsa(indexed, 1, &scale, &offset, &scratch, 1, n)
            case .linear:
                var scale = Float(storedMax - storedPedestal), offset = Float(storedPedestal)
                vDSP_vsmsa(linear, 1, &scale, &offset, &scratch, 1, n)
            }
            var low: Float = 0, high = Float(storedMax)
            vDSP_vclip(scratch, 1, &low, &high, &scratch, 1, n)
            vDSP_vfixru8(scratch, 1, out, 1, n)
        }

        private func encodeGamma(_ linear: UnsafePointer<Float>, count: Int, gamma: Double, into scratch: inout [Float]) {
            // stored = S_b + (Smax − S_b)·pow(max(L, 0), 1/γ) + S_b·(W − B)/B · min(L, 0)
            let n = vDSP_Length(count)
            var positive = [Float](repeating: 0, count: count)
            var negative = [Float](repeating: 0, count: count)
            var zero: Float = 0, one: Float = 1, floor = Float(-Double(pedestal) / Double(linearizedMax - pedestal))
            vDSP_vclip(linear, 1, &zero, &one, &positive, 1, n)
            vDSP_vclip(linear, 1, &floor, &zero, &negative, 1, n)
            var exponent = Float(1 / gamma)
            var n32 = Int32(count)
            vvpowsf(&positive, &exponent, positive, &n32)
            var positiveScale = Float(storedMax - storedPedestal)
            var negativeScale = Float(Double(storedPedestal) * Double(linearizedMax - pedestal) / Double(pedestal))
            var offset = Float(storedPedestal)
            vDSP_vsmsa(positive, 1, &positiveScale, &offset, &scratch, 1, n)
            vDSP_vsma(negative, 1, &negativeScale, scratch, 1, &scratch, 1, n)
        }
    }

}
