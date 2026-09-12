import SwiftUI
import LetsLapseKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Mirrors the editor-controls redesign (handoff *LetsLapse Editor slider
// organization*, boards 2a / 5a / 3b; spec §1 "Grouping" and §2 "XY pads").
// `board-logic.js` — `GROUPS_F`, `PAIRS`, `SHORT_F`, `EXTRA_F` — is the
// behavioural source these tables transcribe.

/// One of the Edit screen's six main buttons, and the panel it opens.
///
/// The old panel drew seven sections in a fixed order — White Balance, Light,
/// Color, Color Mixer, Effects, Detail, Rotation — and every control was a
/// slider row. The redesign folds them into five groups plus Presets, opened
/// one at a time; White Balance and the Color Mixer become tools inside
/// Color, Rotation becomes the Angle slider inside Crop. A group is the unit
/// the header dot, the per-group Reset, the ✓/✕ snapshot and the `LL_SECTIONS`
/// hook all speak in, so its vocabulary lives here rather than in the panel.
enum EditorGroup: String, CaseIterable, Identifiable {
    case presets, light, color, effects, detail, crop

    var id: String { rawValue }

    /// The main button's caption and the panel title.
    var title: String {
        switch self {
        case .presets: return "Presets"
        case .light: return "Light"
        case .color: return "Color"
        case .effects: return "Effects"
        case .detail: return "Detail"
        case .crop: return "Crop"
        }
    }

    /// The main buttons keep SF Symbols (decision 5); only the tool chips
    /// carry drawn icons.
    var systemImage: String {
        switch self {
        case .presets: return "photo.stack"
        case .light: return "sun.max"
        case .color: return "circle.lefthalf.filled"
        case .effects: return "sparkles"
        case .detail: return "triangle"
        case .crop: return "crop.rotate"
        }
    }

    /// The row of tool chips inside the panel, in chip order. Presets shows a
    /// thumbnail strip and Crop shows aspect chips plus the Angle slider —
    /// neither has tools.
    var tools: [EditorTool] {
        switch self {
        case .presets: return []
        case .light: return [.expCon, .highWhites, .shadBlacks]
        case .color: return [.whiteBalance, .vibSat, .mixer]
        case .effects: return [.texClar, .vignette, .dehaze]
        case .detail: return [.sharpen, .noise]
        case .crop: return []
        }
    }

    /// Every keyframeable field the group moves — the union of its tools'
    /// fields, which is what the header dot, the per-group reset and the
    /// "this group travels" test are computed over. Crop owns the one
    /// geometry field; the crop rectangle itself is not a field (it is
    /// carried whole by the timeline, like `hsl`), and Presets owns none.
    ///
    /// Detail also owns `colorNoise`, which no tool shows (the design left
    /// the second chroma control out): a Lightroom import can still write
    /// it, and the group's dot has to light for a value the panel cannot
    /// otherwise reveal — exactly as the old Detail section counted it.
    var fields: Set<PhotoAdjustmentField> {
        switch self {
        case .presets: return []
        case .crop: return [.rotation]
        case .detail:
            return tools.reduce(into: Set<PhotoAdjustmentField>([.colorNoise])) {
                $0.formUnion($1.fields)
            }
        default:
            return tools.reduce(into: Set<PhotoAdjustmentField>()) { $0.formUnion($1.fields) }
        }
    }

    /// The token `LL_SECTIONS=<group>[:<tool>]` names this group by (spec §7).
    var hookName: String {
        switch self {
        case .presets: return "presets"
        case .light: return "light"
        case .color: return "color"
        case .effects: return "effects"
        case .detail: return "detail"
        case .crop: return "crop"
        }
    }
}

/// One chip inside a group's panel: a pair of fields on an XY pad, or the one
/// plain-slider tool (Dehaze). The mixer is a tool too — its pad binds the
/// selected band's hue and luminance, which are not `PhotoAdjustmentField`s,
/// so the panel binds that pad's axes itself.
enum EditorTool: String, CaseIterable, Identifiable {
    case expCon, highWhites, shadBlacks, whiteBalance, vibSat, mixer, texClar, vignette, dehaze, sharpen, noise

    var id: String { rawValue }

    var group: EditorGroup {
        switch self {
        case .expCon, .highWhites, .shadBlacks: return .light
        case .whiteBalance, .vibSat, .mixer: return .color
        case .texClar, .vignette, .dehaze: return .effects
        case .sharpen, .noise: return .detail
        }
    }

    /// The chip's caption — three chips share one row on a 393 pt phone, so
    /// the pairs are abbreviated (`SHORT_F` on the board).
    var shortLabel: String {
        switch self {
        case .expCon: return "Exp · Con"
        case .highWhites: return "High · Wh"
        case .shadBlacks: return "Shad · Bl"
        case .whiteBalance: return "WB"
        case .vibSat: return "Vib · Sat"
        case .mixer: return "Mixer"
        case .texClar: return "Tex · Clar"
        case .vignette: return "Vignette"
        case .dehaze: return "Dehaze"
        case .sharpen: return "Sharpen"
        case .noise: return "Noise"
        }
    }

    /// The full name — accessibility labels and anywhere there is room.
    var title: String {
        switch self {
        case .expCon: return "Exposure · Contrast"
        case .highWhites: return "Highlights · Whites"
        case .shadBlacks: return "Shadows · Blacks"
        case .whiteBalance: return "White Balance"
        case .vibSat: return "Vibrance · Saturation"
        case .mixer: return "Color Mixer"
        case .texClar: return "Texture · Clarity"
        case .vignette: return "Vignette"
        case .dehaze: return "Dehaze"
        case .sharpen: return "Sharpen"
        case .noise: return "Noise"
        }
    }

    /// The pad this tool draws — nil for Dehaze, the one plain-slider tool.
    /// Axis words are the spec §2 table; Y up is always "more" of the
    /// dominant value. Where an axis field is nil the panel binds the axis
    /// itself: the mixer's band values, and the white balance's Y, which is
    /// presented in Kelvin warm-up rather than as the stored mired.
    var pad: PadSpec? {
        switch self {
        case .expCon:
            return PadSpec(
                yField: .exposure, xField: .contrast,
                words: PadWords(top: "Brighter", bottom: "Darker", left: "Flat", right: "Punchy"),
                background: .expCon)
        case .highWhites:
            return PadSpec(
                yField: .highlights, xField: .whites,
                words: PadWords(top: "Lift", bottom: "Recover", left: "Whites −", right: "Whites +"),
                background: .highWhites)
        case .shadBlacks:
            return PadSpec(
                yField: .shadows, xField: .blacks,
                words: PadWords(top: "Open", bottom: "Crush", left: "Blacks −", right: "Blacks +"),
                background: .shadBlacks)
        case .whiteBalance:
            return PadSpec(
                yField: nil, xField: .whiteTint,
                words: PadWords(top: "Warm", bottom: "Cool", left: "Green", right: "Magenta"),
                background: .whiteBalance)
        case .vibSat:
            return PadSpec(
                yField: .saturation, xField: .vibrance,
                words: PadWords(top: "Saturated", bottom: "Black & white", left: "Muted", right: "Vivid"),
                background: .vibSat)
        case .mixer:
            // The background follows the selected band; the panel substitutes
            // `.mixer(hueDegrees: band.centreDegrees)` for this red placeholder.
            return PadSpec(
                yField: nil, xField: nil,
                words: PadWords(top: "Hue +", bottom: "Hue −", left: "Darker", right: "Lighter"),
                background: .mixer(hueDegrees: 0))
        case .texClar:
            return PadSpec(
                yField: .clarity, xField: .texture,
                words: PadWords(top: "Clarity +", bottom: "Clarity −", left: "Soft", right: "Textured"),
                background: .texClar)
        case .vignette:
            return PadSpec(
                yField: .vignetteIntensity, xField: .vignetteMidpoint,
                words: PadWords(top: "Lighten edges", bottom: "Darken edges", left: "Tight", right: "Wide"),
                background: .vignette)
        case .dehaze:
            return nil
        case .sharpen:
            return PadSpec(
                yField: .sharpen, xField: .sharpenMasking,
                words: PadWords(top: "Sharper", bottom: "Softer", left: "Everywhere", right: "Edges only"),
                background: .sharpen)
        case .noise:
            return PadSpec(
                yField: .noiseReduction, xField: .colorNoiseReduction,
                words: PadWords(top: "Smooth", bottom: "Grainy", left: "Color noise −", right: "Color noise +"),
                background: .noise)
        }
    }

    /// Plain sliders drawn under the pad (`EXTRA_F`). Noise keeps its Detail
    /// slider; the mixer's band saturation is also an extra, but it is not a
    /// field, so the panel adds that one itself.
    var extraSliders: [PhotoAdjustmentField] {
        switch self {
        case .noise: return [.noiseDetail]
        default: return []
        }
    }

    /// The fields this tool moves — what marks the chip's keyframe diamond
    /// and what a tool-level reset retires. The mixer's twenty-four values
    /// are not fields (the timeline carries the panel whole), so it owns none.
    var fields: Set<PhotoAdjustmentField> {
        switch self {
        case .expCon: return [.exposure, .contrast]
        case .highWhites: return [.highlights, .whites]
        case .shadBlacks: return [.shadows, .blacks]
        case .whiteBalance: return [.whiteMired, .whiteTint]
        case .vibSat: return [.vibrance, .saturation]
        case .mixer: return []
        case .texClar: return [.texture, .clarity]
        case .vignette: return [.vignetteIntensity, .vignetteMidpoint]
        case .dehaze: return [.dehaze]
        case .sharpen: return [.sharpen, .sharpenMasking]
        case .noise: return [.noiseReduction, .colorNoiseReduction, .noiseDetail]
        }
    }

    /// The `:tool` suffix of `LL_SECTIONS` (spec §7).
    var hookName: String {
        switch self {
        case .expCon: return "expcon"
        case .highWhites: return "highwhites"
        case .shadBlacks: return "shadblacks"
        case .whiteBalance: return "wb"
        case .vibSat: return "vibsat"
        case .mixer: return "mixer"
        case .texClar: return "texclar"
        case .vignette: return "vignette"
        case .dehaze: return "dehaze"
        case .sharpen: return "sharpen"
        case .noise: return "noise"
        }
    }
}

/// What an XY pad shows for one tool: which field sits on each axis, the
/// four words in its margins, and the gradient behind the knob.
struct PadSpec {
    /// The fields on each axis, or nil where the panel binds the axis itself
    /// (mixer: the band's HSL; whiteBalance Y: the Kelvin presentation).
    var yField: PhotoAdjustmentField?
    var xField: PhotoAdjustmentField?
    var words: PadWords
    var background: PadBackground
}

/// The pad's margin words: what the top and bottom of the Y axis mean, and
/// the left and right of the X axis.
struct PadWords {
    var top: String
    var bottom: String
    var left: String
    var right: String
}

/// The gradient behind a pad — a preview of what its axes do, so a pad reads
/// before it is touched: the light pads run dark at the bottom and bright at
/// the top, the white balance pad runs blue to amber over green to magenta.
enum PadBackground {
    case expCon, highWhites, shadBlacks, whiteBalance, vibSat, texClar, vignette, sharpen, noise
    /// The mixer's pad: the selected band's hue ±35° top to bottom, darker
    /// left and lighter right.
    case mixer(hueDegrees: Double)

    /// The board's CSS gradients (spec §2), drawn with LinearGradient /
    /// RadialGradient / Canvas. `light` = the Mac variant: whiteBalance and
    /// vibSat sit over `#E9E9EB` instead of the dark card; the rest are
    /// identical, since they carry their own opaque base.
    ///
    /// Every fade goes to the SAME colour at zero alpha rather than to
    /// `Color.clear`: CSS interpolates gradients premultiplied, SwiftUI does
    /// not, and a fade to transparent black darkens halfway across.
    @ViewBuilder func view(light: Bool) -> some View {
        switch self {
        case .expCon:
            LinearGradient(
                stops: [
                    .init(color: EditorPalette.rgb(0x101012), location: 0),
                    .init(color: EditorPalette.rgb(0x6A6A6E), location: 0.5),
                    .init(color: EditorPalette.rgb(0xE2E2E6), location: 1),
                ],
                startPoint: .bottom, endPoint: .top)
        case .highWhites:
            LinearGradient(
                colors: [EditorPalette.rgb(0x3A3A3E), EditorPalette.rgb(0xC8C8CC)],
                startPoint: .bottom, endPoint: .top)
        case .shadBlacks:
            LinearGradient(
                colors: [.black, EditorPalette.rgb(0x5A5A5E)],
                startPoint: .bottom, endPoint: .top)
        case .whiteBalance:
            ZStack {
                if light { LL.controlFill }
                LinearGradient(
                    stops: [
                        .init(color: EditorPalette.green.opacity(0.8), location: 0),
                        .init(color: EditorPalette.green.opacity(0), location: 0.5),
                        .init(color: EditorPalette.magenta.opacity(0), location: 0.5),
                        .init(color: EditorPalette.magenta.opacity(0.8), location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing)
                LinearGradient(
                    stops: [
                        .init(color: EditorPalette.blue.opacity(0.9), location: 0),
                        .init(color: EditorPalette.blue.opacity(0), location: 0.5),
                        .init(color: EditorPalette.amber.opacity(0), location: 0.5),
                        .init(color: EditorPalette.amber.opacity(0.9), location: 1),
                    ],
                    startPoint: .bottom, endPoint: .top)
            }
        case .vibSat:
            ZStack {
                if light { LL.controlFill }
                LinearGradient(
                    colors: [
                        EditorPalette.rgb(0xE04848), EditorPalette.rgb(0xE0B040),
                        EditorPalette.rgb(0x58C058), EditorPalette.rgb(0x40C0D0),
                        EditorPalette.rgb(0x4868E0), EditorPalette.rgb(0xC048C0),
                    ],
                    startPoint: .leading, endPoint: .trailing)
                LinearGradient(
                    colors: [EditorPalette.grey.opacity(0.85), EditorPalette.grey.opacity(0)],
                    startPoint: .leading, endPoint: .trailing)
                LinearGradient(
                    colors: [EditorPalette.grey, EditorPalette.grey.opacity(0)],
                    startPoint: .bottom, endPoint: .top)
            }
        case .texClar:
            ZStack {
                EditorPalette.rgb(0x3A3A3E)
                // 45° hairlines: 2 pt of white at 5 % every 8 pt, measured
                // across the stripe, which is 8·√2 along the top edge.
                Canvas { context, size in
                    let period = 8 * CGFloat(2).squareRoot()
                    var path = Path()
                    var x = -size.height
                    while x < size.width {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                        x += period
                    }
                    context.stroke(path, with: .color(.white.opacity(0.05)), lineWidth: 2)
                }
            }
        case .vignette:
            ZStack {
                EditorPalette.rgb(0x6A6A6E)
                // CSS `radial-gradient(ellipse at center)` sizes the ellipse to
                // the farthest corner: √2 ÷ 2 of the pad, as a fraction.
                EllipticalGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: 0.35),
                        .init(color: .black.opacity(0.85), location: 1),
                    ],
                    center: .center, startRadiusFraction: 0, endRadiusFraction: 0.7071)
            }
        case .mixer(let hue):
            ZStack {
                LinearGradient(
                    colors: [
                        EditorPalette.hsl(hue - 35, 0.75, 0.5),
                        EditorPalette.hsl(hue, 0.75, 0.5),
                        EditorPalette.hsl(hue + 35, 0.75, 0.5),
                    ],
                    startPoint: .bottom, endPoint: .top)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.75), location: 0),
                        .init(color: .black.opacity(0), location: 0.5),
                        .init(color: .white.opacity(0), location: 0.5),
                        .init(color: .white.opacity(0.75), location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing)
            }
        case .sharpen:
            ZStack {
                LinearGradient(
                    colors: [EditorPalette.rgb(0x2A2A2E), EditorPalette.rgb(0x6A6A6E)],
                    startPoint: .bottom, endPoint: .top)
                // A 1 pt white line at 8 % every 6 pt, standing upright.
                Canvas { context, size in
                    var path = Path()
                    var x: CGFloat = 0.5
                    while x < size.width {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        x += 6
                    }
                    context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 1)
                }
            }
        case .noise:
            ZStack {
                EditorPalette.rgb(0x4A4A4E)
                // White dots at 18 % on a 6 pt grid — the CSS tile puts each
                // dot at its cell's centre.
                Canvas { context, size in
                    var path = Path()
                    var y: CGFloat = 3
                    while y < size.height {
                        var x: CGFloat = 3
                        while x < size.width {
                            path.addEllipse(in: CGRect(x: x - 1.25, y: y - 1.25, width: 2.5, height: 2.5))
                            x += 6
                        }
                        y += 6
                    }
                    context.fill(path, with: .color(.white.opacity(0.18)))
                }
            }
        }
    }
}

/// The colours the boards name that are not design-system tokens: the pad
/// gradients and the drawn icons share them, so they are spelled once.
enum EditorPalette {
    /// `#3F7BD9` — the cool end of the white balance axis.
    static let blue = rgb(0x3F7BD9)
    /// `#F4B23A` — the warm end, and the icon set's sun.
    static let amber = rgb(0xF4B23A)
    /// `#4CAF50` — the green end of the tint axis.
    static let green = rgb(0x4CAF50)
    /// `#D64BC6` — the magenta end.
    static let magenta = rgb(0xD64BC6)
    /// `#78787D` — the desaturated grey the Vib · Sat pad fades into.
    static let grey = rgb(0x78787D)
    /// `#8E8E93` — the dark editors' secondary label.
    static let secondaryOnDark = rgb(0x8E8E93)
    /// `#6D6D72` — the Mac rail's secondary label, in the LIGHT appearance
    /// the board draws. The rail's card is the adaptive `LL.cardBackground`,
    /// so in a dark-appearance window the same ink would sit at ~3.3:1 on
    /// near-black; there it is the system's secondary label instead. The
    /// iPhone's landscape rail (forced dark) takes the same dark branch.
    static let secondaryOnLight = adaptive(light: 0x6D6D72, darkSecondaryLabel: ())
    /// `#F2F2F7` — the idle fill behind the Mac's chips, and the dark
    /// editors' white 8 % once the window goes dark.
    static let chipFillOnLight = adaptive(light: 0xF2F2F7, dark: (white: 1, alpha: 0.08))
    /// `#E9E9EB` — the Mac's small pills (Revert, Auto); white 12 % in a
    /// dark window.
    static let pillFillOnLight = adaptive(light: 0xE9E9EB, dark: (white: 1, alpha: 0.12))

    /// A colour that is the board's hex in the light appearance and a
    /// white-at-alpha in the dark one — resolved by the platform's dynamic
    /// colour so it follows the window, not the app.
    static func adaptive(light: UInt32, dark: (white: Double, alpha: Double)) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: dark.white, alpha: dark.alpha)
                : nsColor(light)
        })
        #else
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: dark.white, alpha: dark.alpha)
                : uiColor(light)
        })
        #endif
    }

    /// The board's hex in the light appearance, the system secondary label
    /// in the dark one.
    static func adaptive(light: UInt32, darkSecondaryLabel: Void) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .secondaryLabelColor
                : nsColor(light)
        })
        #else
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .secondaryLabel : uiColor(light)
        })
        #endif
    }

    #if os(macOS)
    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
    #else
    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
    #endif

    /// A colour from its CSS hex, `0xRRGGBB`.
    static func rgb(_ hex: UInt32, alpha: Double = 1) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha)
    }

    /// CSS `hsl(h, s, l)` as a SwiftUI colour. SwiftUI's `Color(hue:…)` is
    /// HSB, not HSL; the two agree on hue and differ on the other pair, so
    /// the lightness/saturation are converted rather than passed through.
    static func hsl(_ hueDegrees: Double, _ saturation: Double, _ lightness: Double) -> Color {
        var hue = hueDegrees.truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let brightness = lightness + saturation * min(lightness, 1 - lightness)
        let hsbSaturation = brightness == 0 ? 0 : 2 * (1 - lightness / brightness)
        return Color(hue: hue / 360, saturation: hsbSaturation, brightness: brightness)
    }
}
