import SwiftUI
import AVFoundation

/// Decodes the EXACT frame at one source moment — zero tolerance, unlike the
/// scrub thumbnail's ≈-keyframe contract. A framing is composed against the
/// frame that will render; a keyframe seconds away is how punches end up
/// aimed at empty track. Exactness only applies while a framing step is
/// active, so the cost is one precise decode per step, not per scrub.
@MainActor
final class ExactFrameLoader: ObservableObject {
    @Published var image: CGImage?
    private var generators: [URL: AVAssetImageGenerator] = [:]
    private var task: Task<Void, Never>?

    func load(url: URL, seconds: Double) {
        task?.cancel()
        // Never leave the previous anchor's picture under a new framing —
        // a black beat is honest, a wrong frame is the audit's problem A.
        image = nil
        let generator = generators[url] ?? {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            g.requestedTimeToleranceBefore = .zero
            g.requestedTimeToleranceAfter = .zero
            // Deep punches show a sixth of the frame — decode enough pixels
            // that a 6× box isn't judging composition through mush.
            g.maximumSize = CGSize(width: 2560, height: 2560)
            g.appliesPreferredTrackTransform = true
            generators[url] = g
            return g
        }()
        task = Task { [weak self] in
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            let image = try? await generator.image(at: time).image
            guard !Task.isCancelled, let image else { return }
            self?.image = image
        }
    }
}

/// Where a framing step's picture comes from: one file, one exact moment.
struct FrameAnchor: Equatable {
    var url: URL
    var seconds: Double
}

#if os(macOS)
/// The NSEvent monitor outlives every body evaluation, so everything it
/// needs lives on this class: `hovering` because the closure must read the
/// current state, and `apply` because the view value (and the Binding it
/// carries — which framing of a pan is being edited, the current canvas)
/// goes stale the moment the parent re-renders. `apply` is re-armed from
/// every body pass so the scroll always writes through the live binding.
@MainActor
private final class ScrollHoverState {
    var hovering = false
    var monitor: Any?
    var apply: (Double) -> Void = { _ in }
}
#endif

/// The guided builder's framing input: the whole source frame with an
/// aspect-locked bounding box showing exactly the view that will render.
/// Corner/edge handles resize (the punch factor), dragging the interior
/// repositions. iOS layers pinch-to-punch on top; macOS gets scroll-wheel
/// zoom (anchored on the box centre, same as pinch) and click-drag — the
/// first mouse-only punch path the reframe has had.
struct GuidedFramingBox: View {
    @Binding var framing: GuidedFraming
    var aspect: Double
    var sourceSize: CGSize
    var anchor: FrameAnchor?
    /// The width the render pass scales this crop up to (the canvas-shaped
    /// base crop at source scale). Past a 2× upscale the punch renders soft,
    /// and the box says so rather than letting the render surprise.
    var deliveryWidth: Double?

    @StateObject private var loader = ExactFrameLoader()

    private enum DragMode: Equatable {
        case move
        case resize(Handle, original: CGRect)
    }
    @State private var dragMode: DragMode?
    @State private var lastDragTranslation: CGSize?
    @State private var pinchBase: Double?
    /// Once a pinch joins the touch, the drag half is done for the whole
    /// touch — resuming it against a mode latched before the zoom changed
    /// would apply a stale geometry (the warp editor's dragSawPinch pattern).
    @State private var dragSawPinch = false
    @GestureState private var dragLive = false
    @GestureState private var pinchLive = false
    #if os(macOS)
    @State private var scrollState = ScrollHoverState()
    #endif

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        /// Position on the box in unit coordinates.
        var unit: CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: 0, y: 0)
            case .top: return CGPoint(x: 0.5, y: 0)
            case .topRight: return CGPoint(x: 1, y: 0)
            case .right: return CGPoint(x: 1, y: 0.5)
            case .bottomRight: return CGPoint(x: 1, y: 1)
            case .bottom: return CGPoint(x: 0.5, y: 1)
            case .bottomLeft: return CGPoint(x: 0, y: 1)
            case .left: return CGPoint(x: 0, y: 0.5)
            }
        }

        var isCorner: Bool {
            switch self {
            case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
            default: return false
            }
        }

        var isHorizontalEdge: Bool { self == .top || self == .bottom }
    }

    private var cropRect: CGRect {
        ReframeMath.cropRect(
            z: framing.z, cx: framing.cx, cy: framing.cy,
            aspect: aspect, sourceSize: sourceSize)
    }

    var body: some View {
        #if os(macOS)
        // Re-arm on every body pass: the monitor must write through THIS
        // pass's binding, not the one captured at onAppear.
        let _ = { scrollState.apply = { delta in applyScrollZoom(delta: delta) } }()
        #endif
        return Group {
            if sourceSize.height > sourceSize.width {
                surface
                    .frame(height: 320)
                    .frame(maxWidth: .infinity)
            } else {
                surface
                    .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: dragLive) { live in
            guard !live else { return }
            dragMode = nil
            lastDragTranslation = nil
            if !pinchLive { dragSawPinch = false }
        }
        .onChange(of: pinchLive) { live in
            guard !live else { return }
            pinchBase = nil
            if !dragLive { dragSawPinch = false }
        }
        .task(id: anchor) {
            guard let anchor else { return }
            loader.load(url: anchor.url, seconds: anchor.seconds)
        }
        #if os(macOS)
        .onContinuousHover { phase in
            scrollState.hovering = phase != .ended
        }
        .onAppear {
            let state = scrollState
            state.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak state] event in
                guard let state, state.hovering else { return event }
                state.apply(event.scrollingDeltaY)
                return nil
            }
        }
        .onDisappear {
            if let monitor = scrollState.monitor {
                NSEvent.removeMonitor(monitor)
                scrollState.monitor = nil
            }
        }
        #endif
    }

    private var surface: some View {
        GeometryReader { proxy in
            let box = proxy.size
            let scale = sourceSize.width > 0 ? box.width / sourceSize.width : 1
            let viewCrop = CGRect(
                x: cropRect.minX * scale, y: cropRect.minY * scale,
                width: cropRect.width * scale, height: cropRect.height * scale)

            ZStack(alignment: .topLeading) {
                Color.black
                    .overlay(alignment: .topLeading) { picture(in: box) }
                dimming(in: box, around: viewCrop)
                boxEdge(viewCrop)
                handles(viewCrop)
            }
            .frame(width: box.width, height: box.height)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .gesture(dragGesture(box: box).simultaneously(with: pinchGesture))
            .overlay(alignment: .bottomLeading) { badge }
            .overlay(alignment: .top) { softnessWarning }
        }
        .aspectRatio(max(0.1, sourceSize.width / max(1, sourceSize.height)), contentMode: .fit)
    }

    // MARK: - Layers

    @ViewBuilder
    private func picture(in box: CGSize) -> some View {
        if let image = loader.image, sourceSize.width > 0 {
            // Sized from the SOURCE dimensions so geometry stays honest
            // regardless of the decode cap; hit-testing off — gestures live
            // on the surface's contentShape.
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: box.width, height: box.height)
                .allowsHitTesting(false)
        }
    }

    /// Everything outside the box dims — the box shows exactly the view that
    /// will render.
    private func dimming(in box: CGSize, around viewCrop: CGRect) -> some View {
        Canvas { context, size in
            var mask = Path(CGRect(origin: .zero, size: size))
            mask.addRect(viewCrop)
            context.fill(mask, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
        }
        .frame(width: box.width, height: box.height)
        .allowsHitTesting(false)
    }

    private func boxEdge(_ viewCrop: CGRect) -> some View {
        Rectangle()
            .strokeBorder(LL.amber, lineWidth: 1.5)
            .frame(width: max(2, viewCrop.width), height: max(2, viewCrop.height))
            .offset(x: viewCrop.minX, y: viewCrop.minY)
            .allowsHitTesting(false)
    }

    private func handles(_ viewCrop: CGRect) -> some View {
        ForEach(Array(Handle.allCases.enumerated()), id: \.offset) { _, handle in
            Circle()
                .fill(.white)
                .overlay(Circle().strokeBorder(LL.amber, lineWidth: 1.5))
                .frame(width: 9, height: 9)
                .position(
                    x: viewCrop.minX + handle.unit.x * viewCrop.width,
                    y: viewCrop.minY + handle.unit.y * viewCrop.height)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var badge: some View {
        let crop = cropRect
        HStack(spacing: 4) {
            // Always the number — a 1.0× box IS a full-frame crop, and
            // saying "Full frame" while a punch key materialises would lie.
            Text(String(format: "%.1f×", framing.z))
            if crop.width > 0 {
                Text("· \(Int(crop.width)) px")
                    .opacity(0.7)
            }
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(LL.amber)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(8)
        .allowsHitTesting(false)
    }

    /// Soft warning once the kept pixels drop past a 2× upscale of what the
    /// render writes — the punch magnifies compressed pixels, and this is
    /// where it starts to show.
    @ViewBuilder private var softnessWarning: some View {
        if let deliveryWidth, deliveryWidth > 0, cropRect.width * 2 < deliveryWidth {
            Text("Keeps \(Int(cropRect.width)) px of \(Int(deliveryWidth)) — this deep a punch renders soft")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LL.amber)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(.top, 8)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Input

    /// One drag serves both jobs, classified at its first event: near a
    /// handle it resizes against the opposite anchor; anywhere else it moves
    /// the box. The mode is latched for the whole touch.
    private func dragGesture(box: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($dragLive) { _, live, _ in live = true }
            .onChanged { value in
                guard sourceSize.width > 0, box.width > 0 else { return }
                guard pinchBase == nil, !dragSawPinch else {
                    lastDragTranslation = value.translation
                    return
                }
                let scale = box.width / sourceSize.width
                let viewCrop = CGRect(
                    x: cropRect.minX * scale, y: cropRect.minY * scale,
                    width: cropRect.width * scale, height: cropRect.height * scale)

                if dragMode == nil {
                    dragMode = classify(start: value.startLocation, viewCrop: viewCrop)
                }
                switch dragMode {
                case .move:
                    let previous = lastDragTranslation ?? .zero
                    let delta = CGSize(
                        width: value.translation.width - previous.width,
                        height: value.translation.height - previous.height)
                    lastDragTranslation = value.translation
                    let centre = ReframeMath.clampCenter(
                        z: framing.z,
                        cx: framing.cx + Double(delta.width) / Double(scale),
                        cy: framing.cy + Double(delta.height) / Double(scale),
                        aspect: aspect, sourceSize: sourceSize)
                    framing = GuidedFraming(z: framing.z, cx: centre.cx, cy: centre.cy)
                case .resize(let handle, let original):
                    resize(handle: handle, original: original, to: value.location, scale: scale)
                case nil:
                    break
                }
            }
    }

    private func classify(start: CGPoint, viewCrop: CGRect) -> DragMode {
        // The grab ring shrinks with the box so a deep punch keeps a movable
        // interior — at full size 26pt, never more than a quarter of the box.
        let grab = min(26, max(10, min(viewCrop.width, viewCrop.height) / 4))
        var best: (Handle, CGFloat)?
        for handle in Handle.allCases {
            let position = CGPoint(
                x: viewCrop.minX + handle.unit.x * viewCrop.width,
                y: viewCrop.minY + handle.unit.y * viewCrop.height)
            let distance = hypot(position.x - start.x, position.y - start.y)
            if distance < grab, distance < (best?.1 ?? .infinity) {
                best = (handle, distance)
            }
        }
        if let best { return .resize(best.0, original: viewCrop) }
        return .move
    }

    /// Aspect-locked resize against the handle's opposite point, computed
    /// fresh from the latched original box each event so clamping never
    /// detaches the box from its anchor.
    private func resize(handle: Handle, original: CGRect, to pointer: CGPoint, scale: CGFloat) {
        let anchorUnit = CGPoint(x: 1 - handle.unit.x, y: 1 - handle.unit.y)
        let anchor = CGPoint(
            x: original.minX + anchorUnit.x * original.width,
            y: original.minY + anchorUnit.y * original.height)
        let baseWidth = ReframeMath.baseCrop(aspect: aspect, sourceSize: sourceSize).width * scale
        guard baseWidth > 0 else { return }

        var width: CGFloat
        if handle.isCorner {
            width = max(abs(pointer.x - anchor.x), abs(pointer.y - anchor.y) * CGFloat(aspect))
        } else if handle.isHorizontalEdge {
            width = abs(pointer.y - anchor.y) * CGFloat(aspect)
        } else {
            width = abs(pointer.x - anchor.x)
        }
        width = min(max(width, baseWidth / CGFloat(ReframeTrack.maxZoom)), baseWidth)
        let height = width / CGFloat(aspect)

        // The box stays on its original side of the anchor.
        let signX: CGFloat = handle.unit.x == anchorUnit.x ? 0 : (handle.unit.x > anchorUnit.x ? 1 : -1)
        let signY: CGFloat = handle.unit.y == anchorUnit.y ? 0 : (handle.unit.y > anchorUnit.y ? 1 : -1)
        let centre = CGPoint(
            x: signX == 0 ? original.midX : anchor.x + signX * width / 2,
            y: signY == 0 ? original.midY : anchor.y + signY * height / 2)

        let z = Double(baseWidth / width)
        let clamped = ReframeMath.clampCenter(
            z: z, cx: Double(centre.x / scale), cy: Double(centre.y / scale),
            aspect: aspect, sourceSize: sourceSize)
        framing = GuidedFraming(z: z, cx: clamped.cx, cy: clamped.cy)
    }

    /// Pinch scales the punch about the box centre — the box is always the
    /// visible truth, the gesture just drives it.
    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .updating($pinchLive) { _, live, _ in live = true }
            .onChanged { value in
                guard value.magnification.isFinite, value.magnification > 0 else { return }
                dragSawPinch = true
                dragMode = nil
                let base = pinchBase ?? framing.z
                pinchBase = base
                setZoom(base * Double(value.magnification))
            }
    }

    #if os(macOS)
    /// Scroll wheel over the preview zooms the punch, anchored on the box
    /// centre — consistent with pinch, and the mouse's first zoom path.
    private func applyScrollZoom(delta: Double) {
        guard delta.isFinite, delta != 0 else { return }
        setZoom(framing.z * exp(delta * 0.01))
    }
    #endif

    private func setZoom(_ zoom: Double) {
        let z = min(max(zoom, ReframeTrack.minZoom), ReframeTrack.maxZoom)
        let centre = ReframeMath.clampCenter(
            z: z, cx: framing.cx, cy: framing.cy, aspect: aspect, sourceSize: sourceSize)
        framing = GuidedFraming(z: z, cx: centre.cx, cy: centre.cy)
    }
}
