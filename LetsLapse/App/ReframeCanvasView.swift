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

    /// Which thing this touch edits — latched at the first change, so an
    /// external draft-clear (a scrub) can never re-route a live gesture onto
    /// whatever key happens to sit under the playhead afterwards.
    private enum GestureTarget: Equatable {
        case draft
        case key(Int)
    }
    @State private var gestureTarget: GestureTarget?
    /// The last event's cumulative translation — drags apply incremental
    /// deltas at the CURRENT scale, so a simultaneous pinch changing the zoom
    /// mid-drag can't retroactively rescale distance already panned.
    @State private var lastDragTranslation: CGSize?
    @State private var pinchBase: Double?
    /// Recognition liveness — @GestureState resets on CANCEL as well as end
    /// (the enclosing ScrollView stealing a touch), so the healers below can
    /// clear anchors that onEnded would never see.
    @GestureState private var dragLive = false
    @GestureState private var pinchLive = false

    private var track: ReframeTrack { model.activeReframe() }
    private var aspect: Double { model.effectiveBlendCanvas().aspect }

    /// The key under the playhead, if the playhead is parked on one — the key
    /// a gesture edits directly.
    private var onKeyIndex: Int? {
        track.keys.firstIndex { abs($0.t - playhead) < ReframeTrack.minimumKeySpacing }
    }

    /// The framing on screen: the draft while one is alive, else the parked
    /// key's own stored values (never the interpolation — a touch must start
    /// from what the key actually holds), else the interpolated move.
    private var displayed: (z: Double, cx: Double, cy: Double) {
        if let draft { return (draft.z, draft.cx, draft.cy) }
        if let index = onKeyIndex, track.keys.indices.contains(index) {
            let key = track.keys[index]
            return (key.z, key.cx, key.cy)
        }
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
        // Cancellation healers: each clears only its own anchor, and the
        // touch is over only once neither gesture is live.
        .onChange(of: dragLive) { live in
            guard !live else { return }
            lastDragTranslation = nil
            if !pinchLive { endTouch() }
        }
        .onChange(of: pinchLive) { live in
            guard !live else { return }
            pinchBase = nil
            if !dragLive { endTouch() }
        }
    }

    private var canvasBox: some View {
        GeometryReader { proxy in
            let box = proxy.size
            ZStack(alignment: .topLeading) {
                // The picture rides an OVERLAY so its oversized frame never
                // participates in layout: as a ZStack child it would inflate
                // the stack to the image's size and the outer fixed frame
                // would then CENTER the oversized stack — silently shifting
                // the drawn region by (image − box)/2 and breaking the
                // crop-to-picture registration the moment the punch grows.
                Color.black
                    .overlay(alignment: .topLeading) { picture(in: box) }
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
            // Hit-testing OFF: the frame spills far past the clipped box on
            // the mismatched axis, and clipShape clips drawing, not touches —
            // the spill would swallow taps over neighbouring controls.
            // Gestures live on the ZStack's contentShape, which is the box.
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: source.width * scale, height: source.height * scale)
                .offset(x: -cropRect.minX * scale, y: -cropRect.minY * scale)
                .allowsHitTesting(false)
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
    /// On a key it edits the key; between keys it shapes the draft. Deltas
    /// are incremental — each applies at the scale in effect when it
    /// happened, so a simultaneous pinch can't retroactively rescale the pan.
    private func dragGesture(box: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($dragLive) { _, live, _ in live = true }
            .onChanged { value in
                guard let source = model.sourceDisplaySize(), cropRect.width > 0 else { return }
                // Two fingers down means the pinch owns the framing — the
                // drag keeps tracking translation (so it resumes without a
                // jump if the pinch lifts first) but must not pan.
                guard pinchBase == nil else {
                    lastDragTranslation = value.translation
                    return
                }
                latchTargetIfNeeded()
                let previous = lastDragTranslation ?? .zero
                let delta = CGSize(
                    width: value.translation.width - previous.width,
                    height: value.translation.height - previous.height)
                lastDragTranslation = value.translation
                let current = displayed
                let scale = Double(cropRect.width / box.width)
                let centre = ReframeMath.clampCenter(
                    z: current.z,
                    cx: current.cx - Double(delta.width) * scale,
                    cy: current.cy - Double(delta.height) * scale,
                    aspect: aspect,
                    sourceSize: source)
                apply(z: current.z, cx: centre.cx, cy: centre.cy)
            }
    }

    /// Pinch sets the punch for the framing under the playhead.
    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .updating($pinchLive) { _, live, _ in live = true }
            .onChanged { value in
                guard let source = model.sourceDisplaySize(),
                      value.magnification.isFinite, value.magnification > 0 else { return }
                latchTargetIfNeeded()
                let current = displayed
                let base = pinchBase ?? current.z
                pinchBase = base
                let zoom = min(
                    max(base * Double(value.magnification), ReframeTrack.minZoom),
                    ReframeTrack.maxZoom)
                let centre = ReframeMath.clampCenter(
                    z: zoom, cx: current.cx, cy: current.cy, aspect: aspect, sourceSize: source)
                apply(z: zoom, cx: centre.cx, cy: centre.cy)
            }
    }

    /// Latch what this touch edits, once, at its first change. Between keys
    /// the first change seeds the draft from the framing on screen, so the
    /// picture never jumps at the moment you touch it — but nothing commits.
    private func latchTargetIfNeeded() {
        guard gestureTarget == nil else { return }
        if let index = onKeyIndex {
            gestureTarget = .key(index)
            selectedKey = index
        } else {
            if draft == nil {
                let frame = displayed
                draft = ReframeDraft(z: frame.z, cx: frame.cx, cy: frame.cy)
            }
            gestureTarget = .draft
        }
    }

    /// Route a live gesture's framing to the latched target — never to
    /// whatever happens to sit under the playhead now.
    private func apply(z: Double, cx: Double, cy: Double) {
        switch gestureTarget {
        case .draft:
            // An externally cancelled draft (a scrub) kills the rest of the
            // touch rather than resurrecting itself.
            guard draft != nil else { return }
            draft = ReframeDraft(z: z, cx: cx, cy: cy)
        case .key(let index):
            model.updateReframe(coalescing: "reframe-canvas-\(index)") {
                guard $0.keys.indices.contains(index) else { return }
                $0.keys[index].z = z
                $0.keys[index].cx = cx
                $0.keys[index].cy = cy
            }
        case nil:
            break
        }
    }

    /// The whole touch is over — both gestures dead.
    private func endTouch() {
        gestureTarget = nil
        model.endWarpCoalescing()
    }
}
