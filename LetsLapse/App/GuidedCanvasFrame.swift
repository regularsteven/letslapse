import SwiftUI

/// The guided builder's canvas pane: the exact first frame of the shoot,
/// cropped to the chosen output shape. Not the source with a box drawn over it
/// — what is on screen IS the clip's first frame. Dragging inside it slides the
/// crop along the source's free axis (the same 0…1 offset a collection's crop
/// uses), and the strip beside it keeps the discarded context visible.
///
/// The frame is never empty: every step composes against a real decoded frame,
/// so a black beat while the decode lands is honest and a scrub thumbnail is
/// not an option (`ExactFrameLoader`, zero tolerance).
struct GuidedCanvasFrame: View {
    @Binding var offset: Double
    var canvas: CanvasRatio
    var sourceSize: CGSize
    var anchor: FrameAnchor?
    /// The pane's budget; the frame takes the largest canvas-shaped rect that
    /// fits inside it, so the picture on screen is the output's real shape.
    var maxWidth: CGFloat
    var maxHeight: CGFloat
    /// "2160×1214" — the kept pixels, from `VideoCanvasCropper.cropSize` so
    /// the badge and the shape menu can never disagree. nil = as shot.
    var cropLabel: String?
    /// What moment this frame is — "Frame 1" on the canvas step, the stretch
    /// name elsewhere. The exactness claim is the badge's point; the name
    /// keeps it truthful about WHICH exact frame.
    var frameName = "Frame 1"
    /// The strip is the mac/iPad affordance; iOS says it in words under the
    /// frame instead, where there is no width to spare.
    var showsSourceStrip = true
    /// The canvas crop belongs to the canvas step. Other steps show this
    /// frame as context — a moment's wide state IS the canvas — and there a
    /// drag that silently moved the whole clip's crop would be a trap.
    var allowsReposition = true

    @StateObject private var loader = ExactFrameLoader()
    /// The offset the current drag started from — latched so a clamped drag
    /// can't ratchet the crop away from the pointer.
    @State private var dragBase: Double?
    @GestureState private var dragLive = false
    #if os(macOS)
    @State private var pushedCursor = false
    #endif

    /// The kept rectangle in source pixels, and which axis it can slide along.
    private var box: (rect: CGRect, axis: CollectionMath.Axis)? {
        CollectionMath.cropBox(clipSize: sourceSize, canvas: canvas, offset: offset)
    }

    /// How much source the crop leaves over on its free axis, in pixels. Zero
    /// means the shape is the shape it was shot at — nothing to reposition.
    private var slack: Double {
        guard let box else { return 0 }
        return box.axis == .horizontal
            ? Double(sourceSize.width - box.rect.width)
            : Double(sourceSize.height - box.rect.height)
    }

    private var canReposition: Bool { allowsReposition && slack > 1 }

    /// The frame at the output's shape, as large as the pane allows.
    private var frameSize: CGSize {
        CollectionMath.fit(
            aspect: canvas.aspect, maxWidth: Double(maxWidth), maxHeight: Double(maxHeight))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            frame
            if showsSourceStrip, canReposition {
                sourceStrip
            }
        }
        .task(id: anchor) {
            guard let anchor else { return }
            loader.load(url: anchor.url, seconds: anchor.seconds)
        }
        .onChange(of: dragLive) { live in
            guard !live else { return }
            dragBase = nil
        }
    }

    // MARK: - The output frame

    private var frame: some View {
        let size = frameSize
        return Color.black
            .frame(width: size.width, height: size.height)
            .overlay { picture(in: size) }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomLeading) { badge }
            // Masked off entirely when nothing can move: an attached-but-inert
            // drag still claims touches, which turns a 300pt read-only pane
            // into a scroll dead zone on iOS.
            .gesture(repositionGesture(in: size), including: canReposition ? .all : .subviews)
            .modifier(GrabCursor(active: canReposition))
            .accessibilityLabel("Clip frame — \(canvas.rawValue)")
            .accessibilityValue(canReposition
                ? "Crop positioned \(Int((offset * 100).rounded()))% along the frame"
                : "As shot")
    }

    /// The source, scaled so the kept rect exactly fills the frame and shifted
    /// so the crop's origin lands at the frame's origin — the picture is the
    /// output, the rest of the source hangs outside the clip.
    @ViewBuilder private func picture(in size: CGSize) -> some View {
        if let image = loader.image, let box, box.rect.width > 0 {
            let scale = size.width / box.rect.width
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(
                    width: sourceSize.width * scale,
                    height: sourceSize.height * scale)
                .offset(
                    x: -box.rect.minX * scale,
                    y: -box.rect.minY * scale)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
                .allowsHitTesting(false)
        }
    }

    /// One line, always: the badge sits inside the frame, and a tall output on
    /// a phone is narrower than the sentence.
    @ViewBuilder private var badge: some View {
        Text(cropLabel.map { "\(frameName) — exact · \($0)" } ?? "\(frameName) — exact · as shot")
            .font(.system(size: 10, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(8)
            .allowsHitTesting(false)
    }

    /// Drag the picture, not the crop: pulling down brings what was above into
    /// the frame, so the offset moves against the gesture.
    private func repositionGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($dragLive) { _, live, _ in live = true }
            .onChanged { value in
                guard let box, canReposition else { return }
                let scale = size.width / box.rect.width
                // The travel the whole free axis has on screen — the offset is
                // a fraction of it, so a drag moves the picture 1:1.
                let span = slack * Double(scale)
                guard span > 0.5 else { return }
                let base = dragBase ?? offset
                dragBase = base
                let moved = box.axis == .horizontal
                    ? Double(value.translation.width)
                    : Double(value.translation.height)
                offset = min(1, max(0, base - moved / span))
            }
    }

    // MARK: - Source strip

    /// The whole source at a glance, with the kept band picked out in amber:
    /// what the shape is throwing away stays visible while it is being chosen.
    private var sourceStrip: some View {
        let stripSize = CollectionMath.fit(
            aspect: sourceSize.height > 0 ? Double(sourceSize.width / sourceSize.height) : 1,
            maxWidth: 38, maxHeight: 68)
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.06)
            if let image = loader.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: stripSize.width, height: stripSize.height)
                    .opacity(0.55)
            }
            if let box, sourceSize.width > 0, sourceSize.height > 0 {
                Rectangle()
                    .fill(LL.amber.opacity(0.15))
                    .overlay(Rectangle().strokeBorder(LL.amber, lineWidth: 1.5))
                    .frame(
                        width: stripSize.width * box.rect.width / sourceSize.width,
                        height: stripSize.height * box.rect.height / sourceSize.height)
                    .offset(
                        x: stripSize.width * box.rect.minX / sourceSize.width,
                        y: stripSize.height * box.rect.minY / sourceSize.height)
            }
        }
        .frame(width: stripSize.width, height: stripSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.black.opacity(0.15), lineWidth: 1))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// An open-hand pointer over anything that can be dragged. The canvas frame is
/// drag-pan only — the scroll wheel stays the framing tool's punch zoom, so the
/// two surfaces never share a gesture with different meanings.
private struct GrabCursor: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onContinuousHover { phase in
            switch phase {
            case .active where active:
                NSCursor.openHand.set()
            default:
                NSCursor.arrow.set()
            }
        }
        #else
        content
        #endif
    }
}
