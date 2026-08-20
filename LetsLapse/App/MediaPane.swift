import SwiftUI

/// How a media pane sizes itself, and the grabber that resizes it.
///
/// The photo editor, the video editor and the project hero all present one
/// asset at its **true aspect ratio**, capped so a portrait frame can't swallow
/// the screen, and all three let the asset be traded for room below it. That
/// arithmetic — fit, ceiling, floor, drag span — had been copied verbatim
/// between `PhotoViewerView` and `VideoEditorView`, which is how the project
/// hero ended up with a *different* rule (a fixed-height placeholder that
/// re-laid itself out the moment the real image arrived). One implementation,
/// so they cannot drift again.
struct MediaPaneMetrics: Equatable {
    /// The asset's display aspect (w ÷ h), or nil while the probe is out.
    var aspect: Double?
    /// The most of the container's height the media may take.
    var ceilingFraction: CGFloat
    /// The least the handle can shrink it to.
    var floorFraction: CGFloat

    init(aspect: Double?, ceilingFraction: CGFloat = 0.8, floorFraction: CGFloat = 0.25) {
        self.aspect = aspect
        self.ceilingFraction = ceilingFraction
        self.floorFraction = floorFraction
    }

    /// The largest the media may ever be: full width at its true aspect, capped
    /// at `ceilingFraction` of the height.
    ///
    /// A nil aspect — the probe hasn't landed — makes `fit` hand back the whole
    /// box, which is the largest the media could ever be. The first paint
    /// therefore reserves the slot and the resolve *shrinks* it once, rather
    /// than the picture growing into place.
    func ceiling(in container: CGSize) -> CGSize {
        CollectionMath.fit(
            aspect: aspect ?? 0,
            maxWidth: container.width,
            maxHeight: (container.height * ceilingFraction).rounded())
    }

    func floorHeight(in container: CGSize) -> CGFloat {
        (container.height * floorFraction).rounded()
    }

    /// The media's exact frame at a handle position: `scale` 1 is the ceiling,
    /// 0 the floor. Always the true aspect, so the caller can hang overlays off
    /// the picture's own edges instead of the container's.
    func frame(in container: CGSize, scale: CGFloat) -> CGSize {
        guard container.width > 0, container.height > 0 else { return .zero }
        let ceiling = ceiling(in: container)
        let floor = floorHeight(in: container)
        guard let aspect, ceiling.height > floor else { return ceiling }
        let height = (floor + (ceiling.height - floor) * min(max(scale, 0), 1)).rounded()
        return CGSize(
            width: min(container.width, (height * aspect).rounded()),
            height: height)
    }

    /// How much height the handle has to give away. Zero — and so no handle —
    /// when the media is already shorter than the floor, which is where a very
    /// wide clip lands: there is no width left for it to grow into.
    func dragSpan(in container: CGSize) -> CGFloat {
        guard aspect != nil, container.width > 0, container.height > 0 else { return 0 }
        return max(0, ceiling(in: container).height - floorHeight(in: container))
    }
}

/// The grabber under a media pane: drag up to trade picture for the controls or
/// the list below it, double-tap to put it back.
///
/// Owns its own drag anchor, including the healer for a gesture that dies
/// without `onEnded` — `@GestureState` flips false on cancel as well as end.
struct MediaResizeHandle: View {
    /// Where the handle sits, 0 (floor) … 1 (ceiling).
    @Binding var scale: CGFloat
    /// The height the drag has to spend, from `MediaPaneMetrics.dragSpan`.
    var span: CGFloat
    var tint: Color = .white.opacity(0.35)
    /// True for the life of a drag. A host inside a `ScrollView` binds this to
    /// `.scrollDisabled` so the scroll holds still instead of racing the
    /// gesture; the editors, which have no scroll above them, ignore it.
    var isDragging: Binding<Bool> = .constant(false)

    @State private var dragBase: CGFloat?
    @GestureState private var live = false

    var body: some View {
        Capsule()
            .fill(tint)
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($live) { _, live, _ in live = true }
                    .onChanged { value in
                        let base = dragBase ?? scale
                        if dragBase == nil {
                            dragBase = base
                            isDragging.wrappedValue = true
                        }
                        guard span > 0 else { return }
                        scale = min(1, max(0, base + value.translation.height / span))
                    }
                    .onEnded { _ in reset() }
            )
            // Double-tap to reset, the same idiom the sliders teach.
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) { scale = 1 }
            }
            .onChange(of: live) { isLive in
                if !isLive { reset() }
            }
            .accessibilityElement()
            .accessibilityLabel("Preview size")
            .accessibilityValue("\(Int((scale * 100).rounded()))%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: scale = min(1, scale + 0.1)
                case .decrement: scale = max(0, scale - 0.1)
                @unknown default: break
                }
            }
    }

    private func reset() {
        dragBase = nil
        if isDragging.wrappedValue { isDragging.wrappedValue = false }
    }
}
