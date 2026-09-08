import CoreImage
import Foundation

/// Lightroom's HSL panel: eight hue bands, each with a hue shift, a
/// saturation change and a luminance change — twenty-four numbers, ±1.
///
/// WHY IT EXISTS. Nine of the twenty corpus files touch it, three of them
/// hard: `_WEB5777` moves seventeen sliders, and the three files that reject
/// dehaze outright (`_WEB5777`, `_WEB5782`, `_WEB5929`) all pull the sky's
/// saturation to −100 through this panel — an edit no global control can
/// stand in for. The earlier "HSL is a poor bet" note was drawn from a
/// five-file corpus where one file used it; it is not a poor bet.
///
/// WHAT IT IS. A per-pixel operation on display-referred colour: the pixel's
/// hue picks a mix of the two nearest bands, and that mix decides how far its
/// hue turns, how its chroma scales and how its lightness moves. The bands
/// are Adobe's eight, at the hue angles the panel's swatches sit at; the
/// weights are triangular between neighbouring centres, so a pixel between
/// orange and yellow takes a little of each and nothing changes abruptly
/// across a hue boundary.
///
/// WHAT IT IS NOT. Adobe's exact response. Their band shapes and travel are
/// unpublished; these are the plainest reasonable reading of "±100", chosen
/// so the bench can measure whether the panel is worth honouring at all
/// before anybody spends time on the curve. Neutral is bit-exact identity.
public struct HSLAdjustments: Codable, Equatable, Sendable {

    /// The eight bands, in the panel's order.
    public enum Band: Int, CaseIterable, Codable, Sendable {
        case red, orange, yellow, green, aqua, blue, purple, magenta

        /// The band's centre on the hue circle, degrees.
        public var centreDegrees: Float {
            switch self {
            case .red: return 0
            case .orange: return 30
            case .yellow: return 60
            case .green: return 120
            case .aqua: return 180
            case .blue: return 240
            case .purple: return 275
            case .magenta: return 315
            }
        }

        /// Lightroom's attribute suffix — `HueAdjustmentOrange`.
        public var lightroomName: String {
            switch self {
            case .red: return "Red"
            case .orange: return "Orange"
            case .yellow: return "Yellow"
            case .green: return "Green"
            case .aqua: return "Aqua"
            case .blue: return "Blue"
            case .purple: return "Purple"
            case .magenta: return "Magenta"
            }
        }
    }

    /// Hue turn per band, ±1 — ±1 turns a band's hue all the way to the
    /// neighbouring band's centre.
    public var hue: [Float]
    /// Chroma change per band, ±1 — −1 takes the band to grey, +1 doubles it.
    public var saturation: [Float]
    /// Lightness change per band, ±1 — −1 takes the band's colour to black,
    /// +1 toward white; the effect is weighted by how saturated a pixel is,
    /// so greys and pastels move less than the pure colour.
    public var luminance: [Float]

    public init(hue: [Float] = Array(repeating: 0, count: 8),
                saturation: [Float] = Array(repeating: 0, count: 8),
                luminance: [Float] = Array(repeating: 0, count: 8)) {
        self.hue = Self.eight(hue)
        self.saturation = Self.eight(saturation)
        self.luminance = Self.eight(luminance)
    }

    private static func eight(_ values: [Float]) -> [Float] {
        Array((values + Array(repeating: 0, count: 8)).prefix(8))
    }

    public static let neutral = HSLAdjustments()

    public var isNeutral: Bool { self == .neutral }

    public subscript(hue band: Band) -> Float {
        get { hue[band.rawValue] }
        set { hue[band.rawValue] = newValue }
    }
    public subscript(saturation band: Band) -> Float {
        get { saturation[band.rawValue] }
        set { saturation[band.rawValue] = newValue }
    }
    public subscript(luminance band: Band) -> Float {
        get { luminance[band.rawValue] }
        set { luminance[band.rawValue] = newValue }
    }

    /// Every slider held to ±1.
    public var clamped: HSLAdjustments {
        func clamp(_ values: [Float]) -> [Float] { values.map { min(max($0, -1), 1) } }
        return HSLAdjustments(hue: clamp(hue), saturation: clamp(saturation), luminance: clamp(luminance))
    }

    /// A short, stable spelling for cache keys; empty when neutral.
    public var cacheToken: String {
        guard !isNeutral else { return "" }
        return (hue + saturation + luminance).map { String(format: "%.2f", $0) }.joined(separator: ",")
    }

    /// How many of the twenty-four sliders are off zero.
    public var movedCount: Int {
        (hue + saturation + luminance).filter { $0 != 0 }.count
    }

    // MARK: - Applying it

    /// The maximum hue turn at ±1, degrees — the distance between adjacent
    /// panel centres, near enough.
    static let hueTravelDegrees: Float = 30

    /// `image` with the adjustments applied; the input itself when neutral.
    public static func apply(_ adjustments: HSLAdjustments, to image: CIImage) -> CIImage? {
        guard !adjustments.isNeutral else { return image }
        guard let kernel = kernel else { return nil }
        let a = adjustments.clamped
        func vec(_ values: [Float], _ from: Int) -> CIVector {
            CIVector(x: CGFloat(values[from]), y: CGFloat(values[from + 1]),
                     z: CGFloat(values[from + 2]), w: CGFloat(values[from + 3]))
        }
        return kernel.apply(extent: image.extent, arguments: [
            image,
            vec(a.hue, 0), vec(a.hue, 4),
            vec(a.saturation, 0), vec(a.saturation, 4),
            vec(a.luminance, 0), vec(a.luminance, 4),
            hueTravelDegrees,
        ])?.cropped(to: image.extent)
    }

    /// The kernel works on GAMMA-ENCODED values (a 2.2 power), the space a
    /// panel like this is judged in: a hue turn or a lightness move in linear
    /// light lands unevenly across the tonal range. The input is the
    /// engine's display-referred linear output, encoded on the way in and
    /// decoded on the way out, so a neutral pass is the identity.
    private static let kernel = CIColorKernel(source: """
        vec3 rgb2hsv(vec3 c) {
            vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
            vec4 p = (c.g < c.b) ? vec4(c.bg, K.wz) : vec4(c.gb, K.xy);
            vec4 q = (c.r < p.x) ? vec4(p.xyw, c.r) : vec4(c.r, p.yzx);
            float d = q.x - min(q.w, q.y);
            float e = 1.0e-10;
            return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
        }
        vec3 hsv2rgb(vec3 c) {
            vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
            vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
            return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
        }
        // Triangular weight of a band centred at `centre` for hue `h` (both
        // in degrees), falling to zero at the neighbouring centres.
        float bandWeight(float h, float centre, float toPrev, float toNext) {
            float d = h - centre;
            d = d - 360.0 * floor((d + 180.0) / 360.0);   // wrap to (−180, 180]
            if (d < 0.0) { return clamp(1.0 + d / toPrev, 0.0, 1.0); }
            return clamp(1.0 - d / toNext, 0.0, 1.0);
        }
        kernel vec4 hslPanel(__sample src, vec4 hueA, vec4 hueB, vec4 satA, vec4 satB,
                             vec4 lumA, vec4 lumB, float travel) {
            vec3 lin = max(src.rgb, 0.0);
            vec3 enc = pow(lin, vec3(1.0 / 2.2));
            vec3 hsv = rgb2hsv(enc);
            float h = hsv.x * 360.0;
            // Centres: red 0, orange 30, yellow 60, green 120, aqua 180,
            // blue 240, purple 275, magenta 315 — and red again at 360.
            float w[8];
            w[0] = bandWeight(h, 0.0, 45.0, 30.0);
            w[1] = bandWeight(h, 30.0, 30.0, 30.0);
            w[2] = bandWeight(h, 60.0, 30.0, 60.0);
            w[3] = bandWeight(h, 120.0, 60.0, 60.0);
            w[4] = bandWeight(h, 180.0, 60.0, 60.0);
            w[5] = bandWeight(h, 240.0, 60.0, 35.0);
            w[6] = bandWeight(h, 275.0, 35.0, 40.0);
            w[7] = bandWeight(h, 315.0, 40.0, 45.0);
            float dh = 0.0, ds = 0.0, dl = 0.0;
            dh += w[0] * hueA.x + w[1] * hueA.y + w[2] * hueA.z + w[3] * hueA.w;
            dh += w[4] * hueB.x + w[5] * hueB.y + w[6] * hueB.z + w[7] * hueB.w;
            ds += w[0] * satA.x + w[1] * satA.y + w[2] * satA.z + w[3] * satA.w;
            ds += w[4] * satB.x + w[5] * satB.y + w[6] * satB.z + w[7] * satB.w;
            dl += w[0] * lumA.x + w[1] * lumA.y + w[2] * lumA.z + w[3] * lumA.w;
            dl += w[4] * lumB.x + w[5] * lumB.y + w[6] * lumB.z + w[7] * lumB.w;
            // Hue turns by up to one band; chroma scales 0…2; lightness moves
            // toward black or white, weighted by the pixel's own chroma so a
            // grey stays where it is.
            float newH = fract((h + dh * travel) / 360.0);
            float newS = clamp(hsv.y * (1.0 + ds), 0.0, 1.0);
            float sw = smoothstep(0.0, 0.35, hsv.y);
            float v = hsv.z;
            float newV = dl < 0.0 ? v * (1.0 + dl * sw) : v + (1.0 - v) * dl * sw;
            vec3 outEnc = hsv2rgb(vec3(newH, newS, clamp(newV, 0.0, 1.0)));
            vec3 outLin = pow(outEnc, vec3(2.2));
            return vec4(outLin, src.a);
        }
        """)
}
