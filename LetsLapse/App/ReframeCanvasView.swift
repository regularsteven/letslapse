import SwiftUI

/// An uncommitted framing — what a pinch or drag between keyframes edits.
/// Nothing lands on the track until "Set keyframe" is tapped, so exploring a
/// framing can never mutate the timeline.
struct ReframeDraft: Equatable {
    var z: Double
    var cx: Double
    var cy: Double
}

/// The Adjust screen's preview once the reframe lane is open: the playhead's
/// frame at the chosen canvas, WYSIWYG through the crop, with pinch-to-punch
/// and drag-to-position.
///
/// On a keyframe, gestures edit that key directly (one coalesced undo step
/// per touch). Between keyframes, gestures shape a DRAFT — dashed amber, with
/// explicit Set / Cancel chips — because a keyframe is only ever made on
/// purpose. A minimap earns its corner once the crop is smaller than the
/// frame.
struct ReframeCanvasView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var preview: WarpPreviewLoader
    @Binding var playhead: Double
    @Binding var selectedKey: Int?
    @Binding var draft: ReframeDraft?

    /// Tall canvases pin the picture to a fixed-height row, like the plain
    /// scrub preview.
    var tallHeight: CGFloat = 300

    @State private var dragBase: (cx: Double, cy: Double)?
    @State private var pinchBase: Double?

    private var track: ReframeTrack { model.activeReframe() }
    private var aspect: Double { model.effectiveBlendCanvas().aspect }

    /// The key under the playhead, if the playhead is parked on one — the key
    /// a gesture edits directly.
    private var onKeyIndex: Int? {
        track.keys.firstIndex { abs($0.t - playhead) < ReframeTrack.minimumKeySpacing }
    }

    /// The framing on screen: the draft while one is alive, else the key
    /// under the playhead, else the interpolated move.
    private var displayed: (z: Double, cx: Double, cy: Double) {
        if let draft { return (draft.z, draft.cx, draft.cy) }
        guard let size = model.sourceDisplaySize() else { return (1, 0, 0) }
        guard !track.isEmpty else {
            return (1, Double(size.width) / 2, Double(size.height) / 2)
        }
        let warp = model.activeWarp()
        return track.frame(atSource: playhead, outputTime: warp.outputTime(atSource:))
    }

    private var cropRect: CGRect {
        guard let size = model.sourceDisplaySize() else { return .zero }
        let frame = displayed
        return ReframeMath.cropRect(
            z: frame.z, cx: frame.cx, cy: frame.cy, aspect: aspect, sourceSize: size)
    }

    var body: some View {
        Group {
            if aspect < 1 {
                canvasBox
                    .frame(height: tallHeight)
                    .frame(maxWidth: .infinity)
            } else {
                canvasBox
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var canvasBox: some View {
        GeometryReader { proxy in
            let box = proxy.size
            ZStack(alignment: .topLeading) {
                Color.black
                picture(in: box)
                frameEdge(in: box)
            }
            .frame(width: box.width, height: box.height)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .gesture(dragGesture(box: box).simultaneously(with: pinchGesture))
            .overlay(alignment: .bottomLeading) { badge }
            .overlay(alignment: .bottomTrailing) { minimapCorner }
            .overlay(alignment: .bottom) { draftChips }
        }
        .aspectRatio(CGFloat(aspect), contentMode: .fit)
    }

    // MARK: - Picture

    /// The source frame, scaled and offset so the crop window fills the box —
    /// the finished clip's framing, not the whole source. The decoded preview
    /// is smaller than the source; sizing the image from the source keeps the
    /// geometry honest regardless.
    @ViewBuilder
    private func picture(in box: CGSize) -> some View {
        if let image = preview.image, let source = model.sourceDisplaySize(),
           source.width > 0, cropRect.width > 0 {
            let scale = box.width / cropRect.width
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: source.width * scale, height: source.height * scale)
                .offset(x: -cropRect.minX * scale, y: -cropRect.minY * scale)
        }
    }

    /// A hairline that says "this is the output frame" — dashed amber while a
    /// draft is alive, quiet otherwise.
    private func frameEdge(in box: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
                LL.amber.opacity(draft == nil ? 0.4 : 1),
                style: StrokeStyle(lineWidth: 1.5, dash: draft == nil ? [] : [5, 4]))
            .padding(1)
            .allowsHitTesting(false)
    }

    // MARK: - Chrome

    @ViewBuilder private var badge: some View {
        let frame = displayed
        let punched = frame.z > 1.02
        let text: String = {
            if draft != nil {
                return String(format: "≈ new framing · %.1f×", frame.z)
            }
            if let index = onKeyIndex {
                return punched
                    ? String(format: "K%d · %.1f× punch", index + 1, frame.z)
                    : "K\(index + 1) · full frame"
            }
            if track.isEmpty { return "Full frame" }
            return punched
                ? String(format: "≈ between keys · %.1f×", frame.z)
                : "≈ between keys"
        }()
        HStack(spacing: 4) {
            Text(text)
            if punched, cropRect.width > 0 {
                Text("· \(Int(cropRect.width))px")
                    .opacity(0.7)
            }
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(onKeyIndex != nil || draft != nil ? LL.amber : .white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(8)
        .allowsHitTesting(false)
    }

    /// Where the crop sits in the whole source, once it's smaller than it.
    @ViewBuilder private var minimapCorner: some View {
        if displayed.z > 1.02, let source = model.sourceDisplaySize(), source.width > 0 {
            let width: CGFloat = 76
            let height = max(22, width * source.height / source.width)
            Canvas { context, size in
                context.fill(
                    Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4),
                    with: .color(.black.opacity(0.55)))
                let scale = size.width / source.width
                let crop = cropRect
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
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The draft's explicit exits — commit or walk away. Scrubbing away also
    /// drops the draft (the Adjust screen clears it on playhead change).
    @ViewBuilder private var draftChips: some View {
        if let draft {
            HStack(spacing: 8) {
                Button {
                    var newIndex = 0
                    model.updateReframe {
                        newIndex = $0.addKey(t: playhead, z: draft.z, cx: draft.cx, cy: draft.cy)
                    }
                    selectedKey = newIndex
                    self.draft = nil
                    WarpHaptics.success()
                } label: {
                    Text("Set keyframe at \(WarpTimeline.clock(playhead))")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(LL.amber, in: Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    self.draft = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Discard framing")
            }
            .padding(.bottom, 10)
        }
    }

    // MARK: - Gestures

    /// Drag pans the picture under the frame (the crop goes the other way).
    /// On a key it edits the key; between keys it shapes the draft.
    private func dragGesture(box: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let source = model.sourceDisplaySize(), cropRect.width > 0 else { return }
                let start = beginGestureIfNeeded()
                let base = dragBase ?? (start.cx, start.cy)
                dragBase = base
                let scale = Double(cropRect.width / box.width)
                let centre = ReframeMath.clampCenter(
                    z: start.z,
                    cx: base.cx - Double(value.translation.width) * scale,
                    cy: base.cy - Double(value.translation.height) * scale,
                    aspect: aspect,
                    sourceSize: source)
                apply(z: start.z, cx: centre.cx, cy: centre.cy)
            }
            .onEnded { _ in endGesture() }
    }

    /// Pinch sets the punch for the framing under the playhead.
    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard let source = model.sourceDisplaySize(),
                      value.magnification.isFinite, value.magnification > 0 else { return }
                let start = beginGestureIfNeeded()
                let base = pinchBase ?? start.z
                pinchBase = base
                let zoom = min(
                    max(base * Double(value.magnification), ReframeTrack.minZoom),
                    ReframeTrack.maxZoom)
                let centre = ReframeMath.clampCenter(
                    z: zoom, cx: start.cx, cy: start.cy, aspect: aspect, sourceSize: source)
                apply(z: zoom, cx: centre.cx, cy: centre.cy)
            }
            .onEnded { _ in endGesture() }
    }

    /// The framing this touch starts from. Between keys, the first change
    /// seeds the draft from the interpolated frame so the picture never jumps
    /// at the moment you touch it — but nothing is committed.
    private func beginGestureIfNeeded() -> (z: Double, cx: Double, cy: Double) {
        if draft == nil, onKeyIndex == nil {
            let frame = displayed
            draft = ReframeDraft(z: frame.z, cx: frame.cx, cy: frame.cy)
            return frame
        }
        return displayed
    }

    /// Route a live gesture's framing to whichever thing owns it.
    private func apply(z: Double, cx: Double, cy: Double) {
        if draft != nil {
            draft = ReframeDraft(z: z, cx: cx, cy: cy)
        } else if let index = onKeyIndex {
            selectedKey = index
            model.updateReframe(coalescing: "reframe-canvas-\(index)") {
                guard $0.keys.indices.contains(index) else { return }
                $0.keys[index].z = z
                $0.keys[index].cx = cx
                $0.keys[index].cy = cy
            }
        }
    }

    private func endGesture() {
        dragBase = nil
        pinchBase = nil
        model.endWarpCoalescing()
    }
}
