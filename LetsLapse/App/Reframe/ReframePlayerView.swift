import AVFoundation
import SwiftUI

/// The interactive frame. Pinch sets the punch, drag sets where it lands, and
/// either one carves a keyframe at the playhead if there isn't one there yet —
/// so a move is made by touching the picture, not by filling in a form.
///
/// Two modes, one canvas:
/// * `.framed` — what the finished clip will look like. The crop fills the box
///   and a minimap shows where in the source you are once you're punched in.
/// * `.placement` — the whole source, with the crop drawn on it as an amber
///   box and everything outside it dimmed. The expanded view's job: put the
///   box somewhere, with the edges of the frame visible while you do it.
struct ReframePlayerView: View {
    enum Mode {
        case framed
        case placement
    }

    var viewModel: PunchReframeViewModel
    var mode: Mode = .framed
    /// Chrome belongs to the inline card; the expanded view draws its own.
    var showsControls = true

    @StateObject private var loader = WarpPreviewLoader()

    /// Frames are only fetched a tenth of a second apart — the generator is
    /// keyframe-tolerant anyway, so finer requests would decode the same
    /// picture twice.
    private var frameToken: Int {
        Int((viewModel.currentTime * 10).rounded())
    }

    var body: some View {
        GeometryReader { proxy in
            let box = proxy.size
            ZStack(alignment: .topLeading) {
                Color.black
                picture(in: box)
                Canvas { context, size in
                    draw(context: &context, size: size)
                }
                .allowsHitTesting(false)
            }
            .frame(width: box.width, height: box.height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .gesture(dragGesture(box: box).simultaneously(with: pinchGesture))
            .overlay(alignment: .topLeading) { badge }
            .overlay(alignment: .bottomLeading) { playButton }
            .overlay(alignment: .bottomTrailing) { corner(box: box) }
        }
        .aspectRatio(viewModel.ratio.ratio, contentMode: .fit)
        .task(id: frameToken) { loadFrame() }
        .task(id: viewModel.sourceURL) { loadFrame() }
    }

    private func loadFrame() {
        guard let url = viewModel.sourceURL else { return }
        loader.load(url: url, seconds: viewModel.currentTime)
    }

    // MARK: - Picture

    /// The source image, scaled and offset so the geometry below draws over
    /// exactly the pixels it thinks it does.
    @ViewBuilder
    private func picture(in box: CGSize) -> some View {
        if let image = loader.image {
            let layout = self.layout(in: box)
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(
                    width: CGFloat(viewModel.sourceSize.width) * layout.scale,
                    height: CGFloat(viewModel.sourceSize.height) * layout.scale)
                .offset(x: layout.origin.x, y: layout.origin.y)
        }
    }

    /// Where the source sits inside the box, in points.
    ///
    /// `.framed` puts the crop window over the whole box — that is the output
    /// frame. `.placement` fits the entire source instead, so the crop can be
    /// seen against the edges it has to stay inside.
    private func layout(in box: CGSize) -> (scale: CGFloat, origin: CGPoint) {
        let source = viewModel.sourceSize
        guard source.width > 0, source.height > 0, box.width > 0, box.height > 0 else {
            return (1, .zero)
        }
        switch mode {
        case .framed:
            let crop = viewModel.cropRect
            guard crop.width > 0, crop.height > 0 else { return (1, .zero) }
            let scale = box.width / crop.width
            return (scale, CGPoint(x: -crop.minX * scale, y: -crop.minY * scale))
        case .placement:
            let scale = min(box.width / source.width, box.height / source.height)
            return (
                scale,
                CGPoint(
                    x: (box.width - source.width * scale) / 2,
                    y: (box.height - source.height * scale) / 2)
            )
        }
    }

    /// The crop window in view points.
    private func cropFrame(in box: CGSize) -> CGRect {
        let layout = self.layout(in: box)
        let crop = viewModel.cropRect
        return CGRect(
            x: crop.minX * layout.scale + layout.origin.x,
            y: crop.minY * layout.scale + layout.origin.y,
            width: crop.width * layout.scale,
            height: crop.height * layout.scale)
    }

    // MARK: - Overlay geometry

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let crop = cropFrame(in: size)

        if mode == .placement {
            // Everything outside the crop goes down, not away: the excluded
            // frame is the context that makes a reframe judgeable.
            var mask = Path(CGRect(origin: .zero, size: size))
            mask.addRect(crop)
            context.fill(mask, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))

            context.stroke(
                Path(crop), with: .color(LL.amber), lineWidth: 2)
            // Thirds, only while the box is worth aiming.
            if crop.width > 90 {
                var thirds = Path()
                for step in 1...2 {
                    let x = crop.minX + crop.width * CGFloat(step) / 3
                    thirds.move(to: CGPoint(x: x, y: crop.minY))
                    thirds.addLine(to: CGPoint(x: x, y: crop.maxY))
                    let y = crop.minY + crop.height * CGFloat(step) / 3
                    thirds.move(to: CGPoint(x: crop.minX, y: y))
                    thirds.addLine(to: CGPoint(x: crop.maxX, y: y))
                }
                context.stroke(thirds, with: .color(.white.opacity(0.22)), lineWidth: 0.75)
            }
        } else {
            // The framed view *is* the crop, so the rectangle is the edge of
            // the box — a hairline, enough to say "this is the frame".
            let inset = crop.insetBy(dx: 1, dy: 1)
            context.stroke(
                Path(roundedRect: inset, cornerRadius: 15, style: .continuous),
                with: .color(LL.amber.opacity(0.55)),
                lineWidth: 1.5)
        }
    }

    // MARK: - Chrome

    @ViewBuilder private var badge: some View {
        if showsControls {
            HStack(spacing: 0) {
                MediaBadge(
                    text: viewModel.playerBadge,
                    tint: viewModel.onKeyframeIndex == nil ? .white.opacity(0.8) : LL.amber)
                .lineLimit(1)
                // The Expand chip owns the other corner; the badge truncates
                // rather than sliding under it.
                Spacer(minLength: 86)
            }
            .padding(10)
        }
    }

    @ViewBuilder private var playButton: some View {
        if showsControls {
            Button {
                viewModel.togglePlay()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(LL.amber)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(10)
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
        }
    }

    /// Minimap over the time readout, both hugging the corner. The minimap
    /// only earns its place once the crop is smaller than the frame.
    @ViewBuilder
    private func corner(box: CGSize) -> some View {
        if showsControls {
            VStack(alignment: .trailing, spacing: 6) {
                if mode == .framed, viewModel.currentFrame.z > 1.02 {
                    minimap
                }
                timeReadout
            }
            .padding(10)
        }
    }

    private var minimap: some View {
        let source = viewModel.sourceSize
        let width: CGFloat = 84
        let height = source.width > 0
            ? max(24, width * source.height / source.width)
            : 63
        return Canvas { context, size in
            context.fill(
                Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4),
                with: .color(.black.opacity(0.55)))
            guard source.width > 0, source.height > 0 else { return }
            let scale = size.width / source.width
            let crop = viewModel.cropRect
            let box = CGRect(
                x: crop.minX * scale, y: crop.minY * scale,
                width: crop.width * scale, height: crop.height * scale)
            var mask = Path(CGRect(origin: .zero, size: size))
            mask.addRect(box)
            context.fill(mask, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
            context.stroke(Path(box), with: .color(LL.amber), lineWidth: 1.5)
        }
        .frame(width: width, height: height)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(.white.opacity(0.25), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    /// "2:14 → 3.4s in clip" — source time on the left, where it lands on the
    /// right, so the warp is legible without doing the arithmetic.
    private var timeReadout: some View {
        HStack(spacing: 4) {
            Text(ReframeEngine.timecode(viewModel.currentTime))
                .foregroundStyle(.white)
            Image(systemName: "arrow.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            Text("\(ReframeEngine.shortTime(viewModel.outputTime)) in clip")
                .foregroundStyle(LL.amber)
        }
        .font(.system(size: 11, weight: .semibold))
        .monospacedDigit()
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.5), in: Capsule())
    }

    // MARK: - Gestures

    private func dragGesture(box: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                viewModel.isPlaying = false
                let canvas = mode == .framed ? box : cropFrame(in: box).size
                viewModel.handleDrag(
                    translation: value.translation,
                    canvasSize: canvas,
                    movesCrop: mode == .placement)
            }
            .onEnded { _ in viewModel.endGesture() }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                viewModel.isPlaying = false
                viewModel.handlePinch(scale: value.magnification)
            }
            .onEnded { _ in viewModel.endGesture() }
    }
}
