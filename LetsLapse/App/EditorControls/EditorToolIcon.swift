import SwiftUI

// Mirrors the handoff's icon set — `icons/*.svg` (the dark editors) and
// `icons/light/*.svg` (the Mac rail) — spec decision 5: the tool chips carry
// drawn icons; the main buttons keep SF Symbols.

/// One tool-chip icon, drawn rather than shipped as an asset.
///
/// The two SVG sets differ only in their ink — every `#fff` stroke of the dark
/// set is `#1C1C1E` in the light one, while the coloured fills (the sun, the
/// blue/amber halves, the band dots, the two grey discs) stay put. Drawing
/// them in code with the ink as a parameter keeps one source for both and lets
/// a chip colour its icon the way it colours its label. Each glyph is authored
/// in the SVGs' 24-unit space and scaled to `size`, so the 20 pt phone chip and
/// the 18 pt Mac chip are the same drawing.
struct EditorToolIcon: View {
    enum Glyph: Hashable {
        case tool(EditorTool)
        /// The Angle slider's mark (Crop panel).
        case angle
        /// The crop mark (Crop panel, and the Masks card's geometry column).
        case crop
    }

    var glyph: Glyph
    /// White on the dark editors, `LL.ink` on the Mac — the caller decides.
    var ink: Color
    var size: CGFloat = 20

    var body: some View {
        Canvas { context, canvasSize in
            context.scaleBy(x: canvasSize.width / 24, y: canvasSize.height / 24)
            draw(in: &context)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - Glyphs

    private func draw(in context: inout GraphicsContext) {
        switch glyph {
        case .tool(let tool):
            switch tool {
            case .expCon: exposureContrast(&context)
            case .highWhites: highlightsWhites(&context)
            case .shadBlacks: shadowsBlacks(&context)
            case .whiteBalance: whiteBalance(&context)
            case .vibSat: vibranceSaturation(&context)
            case .mixer: mixer(&context)
            case .texClar: textureClarity(&context)
            case .vignette: vignette(&context)
            case .dehaze: dehaze(&context)
            case .sharpen: sharpen(&context)
            case .noise: noise(&context)
            }
        case .angle: angle(&context)
        case .crop: crop(&context)
        }
    }

    private func round(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    private func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    }

    private func line(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.0, y: point.1))
        }
        return path
    }

    /// `ec`: a disc shaded black to white left to right — the exposure sweep
    /// — with a black plus in its bright quadrant and a white minus in its
    /// dark one.
    private func exposureContrast(_ context: inout GraphicsContext) {
        let disc = circle(12, 12, 9.5)
        context.fill(
            disc,
            with: .linearGradient(
                Gradient(colors: [.black, .white]),
                startPoint: CGPoint(x: 2.5, y: 12), endPoint: CGPoint(x: 21.5, y: 12)))
        // The light set's ring is lighter (icons/light/ec.svg strokes at .45,
        // the dark set at .7) — a full-weight ring on the white card reads
        // heavier than the board.
        context.stroke(disc, with: .color(ink.opacity(ink == .white ? 0.7 : 0.45)), lineWidth: 1)
        context.stroke(line([(16.5, 6), (16.5, 10)]), with: .color(.black), style: round(1.6))
        context.stroke(line([(14.5, 8), (18.5, 8)]), with: .color(.black), style: round(1.6))
        context.stroke(line([(5.5, 16), (9.5, 16)]), with: .color(.white), style: round(1.6))
    }

    /// `hw`: a light-grey disc with an ink plus at its top right.
    private func highlightsWhites(_ context: inout GraphicsContext) {
        context.fill(circle(10, 13.5, 8), with: .color(EditorPalette.rgb(0xD8D8DC)))
        context.stroke(line([(19, 3.5), (19, 9.5)]), with: .color(ink), style: round(1.8))
        context.stroke(line([(16, 6.5), (22, 6.5)]), with: .color(ink), style: round(1.8))
    }

    /// `sb`: a dark disc with a lighter rim and an ink minus at its top right.
    private func shadowsBlacks(_ context: inout GraphicsContext) {
        let disc = circle(10, 13.5, 8)
        context.fill(disc, with: .color(EditorPalette.rgb(0x3A3A3E)))
        context.stroke(disc, with: .color(EditorPalette.rgb(0x9A9A9E)), lineWidth: 1)
        context.stroke(line([(16, 6.5), (22, 6.5)]), with: .color(ink), style: round(1.8))
    }

    /// `wb`: a disc split blue (left) and amber (right) — the cool and warm
    /// ends of the Temp axis — under an ink ring and divider. The halves are
    /// the same circle clipped, which sidesteps arc-direction arithmetic.
    private func whiteBalance(_ context: inout GraphicsContext) {
        let disc = circle(12, 12, 9.5)
        context.fill(disc, with: .color(EditorPalette.blue))
        var right = context
        right.clip(to: Path(CGRect(x: 12, y: 0, width: 12, height: 24)))
        right.fill(disc, with: .color(EditorPalette.amber))
        context.stroke(disc, with: .color(ink.opacity(0.7)), lineWidth: 1)
        context.stroke(line([(12, 3), (12, 21)]), with: .color(ink), lineWidth: 1.2)
    }

    /// `vs`: a drop, grey on its left half and running red → green → blue on
    /// its right — saturation arriving.
    private func vibranceSaturation(_ context: inout GraphicsContext) {
        var drop = Path()
        drop.move(to: CGPoint(x: 12, y: 2.5))
        drop.addCurve(
            to: CGPoint(x: 19, y: 15),
            control1: CGPoint(x: 15.5, y: 7.5), control2: CGPoint(x: 19, y: 11))
        // The SVG's `a7 7 0 0 1 -14 0`: the lower semicircle, drawn as two
        // tangent quarter arcs so its direction is never in question.
        drop.addArc(tangent1End: CGPoint(x: 19, y: 22), tangent2End: CGPoint(x: 12, y: 22), radius: 7)
        drop.addArc(tangent1End: CGPoint(x: 5, y: 22), tangent2End: CGPoint(x: 5, y: 15), radius: 7)
        drop.addCurve(
            to: CGPoint(x: 12, y: 2.5),
            control1: CGPoint(x: 5, y: 11), control2: CGPoint(x: 8.5, y: 7.5))
        drop.closeSubpath()
        let grey = EditorPalette.secondaryOnDark
        context.fill(
            drop,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: grey, location: 0),
                    .init(color: grey, location: 0.45),
                    .init(color: EditorPalette.rgb(0xE04848), location: 0.55),
                    .init(color: EditorPalette.rgb(0x58C058), location: 0.75),
                    .init(color: EditorPalette.rgb(0x4868E0), location: 1),
                ]),
                startPoint: CGPoint(x: 5, y: 12), endPoint: CGPoint(x: 19, y: 12)))
        context.stroke(drop, with: .color(ink.opacity(0.6)), lineWidth: 1)
    }

    /// `mix`: eight band dots on a ring, one per Color Mixer band, at the
    /// board's hues (its purple and magenta sit at 280° and 320°, a touch off
    /// the Kit's 275° / 315° centres, and the icon follows the board).
    private func mixer(_ context: inout GraphicsContext) {
        let hues: [Double] = [0, 30, 60, 120, 180, 240, 280, 320]
        for (index, hue) in hues.enumerated() {
            let angle = -Double.pi / 2 + Double(index) * Double.pi / 4
            let cx = 12 + 8.2 * cos(angle)
            let cy = 12 + 8.2 * sin(angle)
            context.fill(circle(cx, cy, 2.3), with: .color(EditorPalette.hsl(hue, 0.8, 0.58)))
        }
    }

    /// `tc`: a ring with a jagged trace across it — texture as a waveform.
    private func textureClarity(_ context: inout GraphicsContext) {
        context.stroke(circle(12, 12, 9), with: .color(ink), lineWidth: 1.5)
        context.stroke(
            line([(6, 15), (10, 6), (13, 12), (15, 9), (18, 15)]),
            with: .color(ink), style: round(1.5))
    }

    /// `vig`: a frame whose edges fall off into ink — clear at 45 % of the
    /// radius, 90 % ink at the corners. The SVG gradient is an ellipse (r =
    /// 0.7 of the 18 × 15 box); the context is squashed to match.
    private func vignette(_ context: inout GraphicsContext) {
        let box = CGRect(x: 3, y: 4.5, width: 18, height: 15)
        let frame = Path(roundedRect: box, cornerRadius: 3, style: .continuous)
        var shaded = context
        shaded.clip(to: frame)
        shaded.translateBy(x: box.midX, y: box.midY)
        shaded.scaleBy(x: 1, y: box.height / box.width)
        let radius = 0.7 * box.width
        shaded.fill(
            Path(CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: ink.opacity(0), location: 0.45),
                    .init(color: ink.opacity(0.9), location: 1),
                ]),
                center: .zero, startRadius: 0, endRadius: radius))
        context.stroke(frame, with: .color(ink), lineWidth: 1.5)
    }

    /// `dehaze`: an amber sun over two ink haze lines.
    private func dehaze(_ context: inout GraphicsContext) {
        context.fill(circle(12, 10, 4), with: .color(EditorPalette.amber))
        let rays: [[(CGFloat, CGFloat)]] = [
            [(12, 2.5), (12, 4.5)], [(5, 5), (6.4, 6.4)], [(19, 5), (17.6, 6.4)],
            [(3, 10), (5, 10)], [(19, 10), (21, 10)],
        ]
        for ray in rays {
            context.stroke(line(ray), with: .color(EditorPalette.amber), style: round(1.5))
        }
        context.stroke(line([(4, 15.5), (20, 15.5)]), with: .color(ink.opacity(0.85)), style: round(1.6))
        context.stroke(line([(6, 19), (18, 19)]), with: .color(ink.opacity(0.85)), style: round(1.6))
    }

    /// `sh`: a triangle with a faint centre line — an edge, and its crispness.
    private func sharpen(_ context: inout GraphicsContext) {
        var triangle = line([(12, 3.5), (20.5, 19.5), (3.5, 19.5)])
        triangle.closeSubpath()
        context.stroke(triangle, with: .color(ink), style: round(1.5))
        context.stroke(line([(12, 3.5), (12, 19.5)]), with: .color(ink.opacity(0.5)), lineWidth: 1)
    }

    /// `nz`: a 4 × 4 field of squares at the SVG's opacities — grain.
    private func noise(_ context: inout GraphicsContext) {
        let positions: [CGFloat] = [3.5, 8, 12.5, 17]
        let opacities: [[Double]] = [
            [0.3, 0.72, 0.44, 0.86],
            [0.58, 0.3, 0.72, 0.44],
            [0.86, 0.58, 0.3, 0.72],
            [0.44, 0.86, 0.58, 0.3],
        ]
        for (row, y) in positions.enumerated() {
            for (column, x) in positions.enumerated() {
                let square = Path(
                    roundedRect: CGRect(x: x, y: y, width: 3.2, height: 3.2),
                    cornerRadius: 0.8, style: .continuous)
                context.fill(square, with: .color(ink.opacity(opacities[row][column])))
            }
        }
    }

    /// `angle`: a base line, a line tilted 37° off it, and an amber arc
    /// marking the angle between them at the vertex.
    private func angle(_ context: inout GraphicsContext) {
        context.stroke(line([(4, 18), (20, 6)]), with: .color(ink), style: round(1.6))
        context.stroke(line([(4, 18), (20, 18)]), with: .color(ink.opacity(0.5)), style: round(1.6))
        var arc = Path()
        arc.move(to: CGPoint(x: 9.6, y: 18))
        // In SwiftUI's y-down space `clockwise: true` runs the short way from
        // 0° up to the tilted line (verified numerically: the arc's box stays
        // within x 8.5…9.6, y 14.6…18).
        arc.addArc(
            center: CGPoint(x: 4, y: 18), radius: 5.6,
            startAngle: .degrees(0), endAngle: .degrees(-36.87), clockwise: true)
        context.stroke(arc, with: .color(EditorPalette.amber), style: round(1.6))
    }

    /// `crop`: the two crop-mark strokes, corners rounded to 2.
    private func crop(_ context: inout GraphicsContext) {
        var marks = Path()
        marks.move(to: CGPoint(x: 6, y: 2))
        marks.addLine(to: CGPoint(x: 6, y: 16))
        marks.addArc(tangent1End: CGPoint(x: 6, y: 18), tangent2End: CGPoint(x: 8, y: 18), radius: 2)
        marks.addLine(to: CGPoint(x: 22, y: 18))
        marks.move(to: CGPoint(x: 2, y: 6))
        marks.addLine(to: CGPoint(x: 16, y: 6))
        marks.addArc(tangent1End: CGPoint(x: 18, y: 6), tangent2End: CGPoint(x: 18, y: 8), radius: 2)
        marks.addLine(to: CGPoint(x: 18, y: 22))
        context.stroke(marks, with: .color(ink), style: round(1.7))
    }
}

#if DEBUG
/// Every glyph on the two grounds it ships on: black with white ink (the
/// dark editors) and `#F2F2F7` with `LL.ink` (the Mac rail).
private struct EditorToolIconGrid: View {
    var ink: Color
    var ground: Color

    private var glyphs: [EditorToolIcon.Glyph] {
        EditorTool.allCases.map { .tool($0) } + [.angle, .crop]
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(48)), count: 7), spacing: 12) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                VStack(spacing: 6) {
                    EditorToolIcon(glyph: glyph, ink: ink, size: 24)
                    EditorToolIcon(glyph: glyph, ink: ink, size: 18)
                }
            }
        }
        .padding(20)
        .background(ground)
    }
}

#Preview("Icons") {
    VStack(spacing: 0) {
        EditorToolIconGrid(ink: .white, ground: .black)
        EditorToolIconGrid(ink: LL.ink, ground: EditorPalette.rgb(0xF2F2F7))
    }
}
#endif
