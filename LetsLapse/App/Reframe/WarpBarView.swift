import SwiftUI

/// The reframe's two lanes: the warp bar (how fast each stretch runs) and the
/// diamond scrubber under it (where the keyframes are, and how deep each one
/// blends). Both are drawn in one `Canvas` pass each — a few hundred segments
/// would otherwise be a few hundred views.
struct WarpBarView: View {
    var viewModel: PunchReframeViewModel

    /// Fast stretches are cold and dark; slow ones warm up. The same two
    /// gradients the Adjust timeline uses, so the vocabulary carries over.
    /// Components rather than `Color`, because these get mixed per segment and
    /// `Color.mix(with:by:)` is iOS 18.
    private typealias RGB = (r: Double, g: Double, b: Double)
    private static let fastTop: RGB = (0.20, 0.255, 0.353)
    private static let fastBottom: RGB = (0.106, 0.137, 0.188)
    private static let slowTop: RGB = (0.42, 0.29, 0.086)
    private static let slowBottom: RGB = (0.227, 0.18, 0.078)
    private static let white: RGB = (1, 1, 1)
    /// LL.amber, in the same space.
    private static let amber: RGB = (1, 179.0 / 255, 64.0 / 255)

    private static let barHeight: CGFloat = 50
    private static let laneHeight: CGFloat = 26
    /// How near a diamond a tap counts as "that one" rather than a scrub.
    private static let diamondHitSlop: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                warpBar(width: max(1, proxy.size.width))
            }
            .frame(height: Self.barHeight)

            GeometryReader { proxy in
                diamondLane(width: max(1, proxy.size.width))
            }
            .frame(height: Self.laneHeight)

            timeLabels
        }
    }

    // MARK: - Warp bar

    private func warpBar(width: CGFloat) -> some View {
        Canvas { context, size in
            let rounded = Path(
                roundedRect: CGRect(origin: .zero, size: size),
                cornerRadius: 12, style: .continuous)
            context.fill(rounded, with: .color(Self.color(Self.fastBottom).opacity(0.6)))
            context.clip(to: rounded)

            for segment in viewModel.segmentData {
                let x0 = size.width * CGFloat(segment.start)
                let x1 = size.width * CGFloat(segment.end)
                let rect = CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)
                let path = Path(rect)
                let start = Self.tint(for: segment.startSpeed)
                let end = Self.tint(for: segment.endSpeed)

                if segment.isFlat {
                    context.fill(path, with: .linearGradient(
                        Gradient(colors: [start.top, start.bottom]),
                        startPoint: CGPoint(x: rect.minX, y: 0),
                        endPoint: CGPoint(x: rect.maxX, y: rect.height)))
                } else {
                    // A ramp reads across the bar, not down it: the colour
                    // travels with the speed it is describing.
                    context.fill(path, with: .linearGradient(
                        Gradient(colors: [start.top, end.top]),
                        startPoint: CGPoint(x: rect.minX, y: 0),
                        endPoint: CGPoint(x: rect.maxX, y: 0)))
                }

                // Seams, so neighbouring stretches read as two things.
                if segment.start > 0 {
                    var seam = Path()
                    seam.move(to: CGPoint(x: x0, y: 0))
                    seam.addLine(to: CGPoint(x: x0, y: size.height))
                    context.stroke(seam, with: .color(.black.opacity(0.35)), lineWidth: 1)
                }

                // Only a flat stretch has one number to show, and only when
                // there is room for the pill.
                if segment.isFlat, rect.width > 42 {
                    let pill = CGRect(
                        x: rect.midX - 20, y: rect.midY - 9, width: 40, height: 18)
                    context.fill(
                        Path(roundedRect: pill, cornerRadius: 9, style: .continuous),
                        with: .color(.black.opacity(0.32)))
                    context.draw(
                        Text(segment.label)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.white),
                        at: CGPoint(x: rect.midX, y: rect.midY))
                }
            }

            // Playhead, carried through both lanes.
            let x = size.width * CGFloat(viewModel.playLeft)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(LL.accent), lineWidth: 2)
        }
        .contentShape(Rectangle())
        .gesture(scrubGesture(width: width))
        .accessibilityLabel("Warp timeline")
        .accessibilityValue(ReframeEngine.timecode(viewModel.currentTime))
    }

    /// Amber for real time, blue-grey for the streaks — mixed on the same log
    /// scale the blend depth follows.
    private static func tint(for speed: Double) -> (top: Color, bottom: Color) {
        let mix = ReframeEngine.autoBlend(speed: speed)
        return (
            top: blend(slowTop, fastTop, mix),
            bottom: blend(slowBottom, fastBottom, mix)
        )
    }

    private static func color(_ rgb: RGB) -> Color {
        Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    private static func blend(_ a: RGB, _ b: RGB, _ amount: Double) -> Color {
        let amount = min(max(amount, 0), 1)
        return Color(
            red: a.r + (b.r - a.r) * amount,
            green: a.g + (b.g - a.g) * amount,
            blue: a.b + (b.b - a.b) * amount)
    }

    // MARK: - Diamond lane

    private func diamondLane(width: CGFloat) -> some View {
        Canvas { context, size in
            let midY = size.height / 2

            var track = Path()
            track.move(to: CGPoint(x: 0, y: midY))
            track.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(track, with: .color(.secondary.opacity(0.35)), lineWidth: 1)

            for diamond in viewModel.diamondData {
                let half: CGFloat = diamond.isSelected ? 7.5 : 6
                // A key at 0:00 sits on the edge, where half its diamond would
                // be clipped away — nudged in by its own radius it still reads
                // as "the start" and stays a whole shape.
                let x = min(max(size.width * CGFloat(diamond.position), half), size.width - half)
                var path = Path()
                path.move(to: CGPoint(x: x, y: midY - half))
                path.addLine(to: CGPoint(x: x + half, y: midY))
                path.addLine(to: CGPoint(x: x, y: midY + half))
                path.addLine(to: CGPoint(x: x - half, y: midY))
                path.closeSubpath()

                // Deep blend fills amber, no blend leaves it white: the lane
                // shows the blur without a second row of numbers.
                context.fill(
                    path,
                    with: .color(Self.blend(Self.white, Self.amber, diamond.blend)))
                context.stroke(path, with: .color(.black.opacity(0.25)), lineWidth: 0.75)
                if diamond.isSelected {
                    let ring: CGFloat = half + 3.5
                    let ringPath = Path(ellipseIn: CGRect(
                        x: x - ring, y: midY - ring,
                        width: ring * 2, height: ring * 2))
                    context.stroke(ringPath, with: .color(LL.accent), lineWidth: 2)
                }
            }

            let x = size.width * CGFloat(viewModel.playLeft)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(LL.accent), lineWidth: 2)
            context.fill(
                Path(ellipseIn: CGRect(x: x - 4, y: 0, width: 8, height: 8)),
                with: .color(LL.accent))
        }
        .contentShape(Rectangle())
        .gesture(laneGesture(width: width))
        .accessibilityLabel("Keyframes")
        .accessibilityValue(viewModel.selectedKeyLine)
    }

    // MARK: - Time labels

    private var timeLabels: some View {
        HStack(spacing: 0) {
            Text("0:00")
            Spacer(minLength: 4)
            Text(ReframeEngine.timecode(viewModel.sourceDuration / 2))
            Spacer(minLength: 4)
            Text(ReframeEngine.timecode(viewModel.sourceDuration))
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    // MARK: - Gestures

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                viewModel.isPlaying = false
                viewModel.scrub(toFraction: Double(value.location.x / width))
            }
    }

    /// A touch that lands on a diamond selects it; anything else scrubs. The
    /// decision is made once, at touch-down, so a drag that starts on a
    /// diamond doesn't turn into a scrub halfway across it.
    private func laneGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                viewModel.isPlaying = false
                if value.translation == .zero,
                   let index = nearestDiamond(toX: value.location.x, width: width) {
                    viewModel.selectKeyframe(index)
                    return
                }
                viewModel.scrub(toFraction: Double(value.location.x / width))
            }
    }

    private func nearestDiamond(toX x: CGFloat, width: CGFloat) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for diamond in viewModel.diamondData {
            let distance = abs(width * CGFloat(diamond.position) - x)
            guard distance <= Self.diamondHitSlop else { continue }
            if best == nil || distance < best!.distance {
                best = (diamond.index, distance)
            }
        }
        return best?.index
    }
}
