import SwiftUI

/// The guided builder's "see it before Create" machinery: a low-fidelity
/// scrub over the clip the survey is authoring, before the multi-minute
/// render. Every piece of it reads the render's own numbers — the compiled
/// frame map for the clock, the materialised track for the framing — so what
/// the scrub shows is what renders, by construction. The frames themselves
/// are the honest exception: ≈ keyframe decodes via `WarpPreviewLoader`,
/// badged as such, and never the surface a crop is composed on (the framing
/// box keeps its zero-tolerance exact frames).
struct GuidedScrubContext {
    /// The compiled per-output-frame source times, flattened onto the global
    /// source axis — the same map the reframe bake indexes.
    let frames: [Double]
    let outputFPS: Int
    /// Output frames landing in each stretch, from the same compile.
    let stretchFrames: [Int]
    let seamEases: [WarpCompiler.SeamEase?]
    /// The survey's answers as the track that would render right now — may be
    /// empty when everything is wide.
    let track: ReframeTrack
    let aspect: Double
    let sourceSize: CGSize
    let canvas: CanvasRatio
    let canvasOffset: Double

    init?(
        compiled: WarpCompiler.Compiled?,
        track: ReframeTrack,
        aspect: Double,
        sourceSize: CGSize?,
        canvas: CanvasRatio,
        canvasOffset: Double,
        outputFPS: Int
    ) {
        guard let compiled, let sourceSize,
              sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let flat = compiled.frameSourceTimes.flatMap { $0 }
        guard flat.count > 1 else { return nil }
        frames = flat
        self.outputFPS = max(1, outputFPS)
        stretchFrames = compiled.stretchFrames
        seamEases = compiled.seamEases
        self.track = track
        self.aspect = aspect
        self.sourceSize = sourceSize
        self.canvas = canvas
        self.canvasOffset = canvasOffset
    }

    var totalSeconds: Double { Double(frames.count) / Double(outputFPS) }

    /// The one clock, formatted: the clip's own zero is a real place, not a
    /// missing value (`clipLengthCompact` guards seconds > 0).
    static func clock(_ seconds: Double) -> String {
        seconds <= 0.049 ? "0s" : SpeedMath.clipLengthCompact(seconds)
    }

    /// The output frames a step's scrub covers: the stretch's own frames plus
    /// the whole of each adjoining compiled ease, so the hand-offs into and
    /// out of the stretch are part of what the preview shows — "how it
    /// arrives" is half the answer.
    func window(forStretch index: Int) -> ClosedRange<Int> {
        let all = 0...(frames.count - 1)
        guard stretchFrames.indices.contains(index) else { return all }
        let outFps = Double(outputFPS)
        var lo = stretchFrames[..<index].reduce(0, +)
        var hi = lo + max(1, stretchFrames[index]) - 1
        if index > 0, let ease = seamEases[safe: index - 1] ?? nil {
            lo -= Int((ease.applied * outFps).rounded())
        }
        if let ease = seamEases[safe: index] ?? nil {
            hi += Int((ease.applied * outFps).rounded())
        }
        lo = max(all.lowerBound, min(lo, all.upperBound))
        hi = max(lo, min(hi, all.upperBound))
        return lo...hi
    }

    /// The stretch's own output frames, eases excluded — the storyboard's
    /// cells sample inside the stretch, where the framing it authored holds.
    func stretchRange(_ index: Int) -> ClosedRange<Int> {
        let all = 0...(frames.count - 1)
        guard stretchFrames.indices.contains(index) else { return all }
        let lo = stretchFrames[..<index].reduce(0, +)
        let hi = lo + max(1, stretchFrames[index]) - 1
        let safeLo = max(all.lowerBound, min(lo, all.upperBound))
        return safeLo...max(safeLo, min(hi, all.upperBound))
    }

    /// The source moment output frame `f` shows, straight off the map.
    func sourceTime(atFrame f: Double) -> Double {
        let index = min(max(0, Int(f.rounded())), frames.count - 1)
        return frames[index]
    }

    /// The crop the finished clip shows at that source moment — the track
    /// evaluated on the compiled clock (the render's own interpolation), or
    /// the plain canvas box while nothing is punched anywhere.
    func crop(atSourceTime s: Double) -> CGRect {
        if track.isEmpty {
            if let box = CollectionMath.cropBox(
                clipSize: sourceSize, canvas: canvas, offset: canvasOffset) {
                return box.rect
            }
            return CGRect(origin: .zero, size: sourceSize)
        }
        return track.crop(
            atSource: s, aspect: aspect, sourceSize: sourceSize,
            outputTime: ReframeVideoCropper.outputTimeMap(
                frameSourceTimes: frames, outputFPS: outputFPS))
    }
}

// MARK: - The scrubbed picture

/// The output at one scrubbed moment: the ≈ keyframe decode shown through
/// the crop the render would apply, with the clip clock in the badge.
struct GuidedScrubDisplay: View {
    let context: GuidedScrubContext
    /// Absolute output frame — fractional while a drag is live.
    let frame: Double
    let locate: (Double) -> (url: URL, seconds: Double)?
    let paneSize: CGSize

    @StateObject private var loader = WarpPreviewLoader(debounceMilliseconds: 30)

    var body: some View {
        let s = context.sourceTime(atFrame: frame)
        let crop = context.crop(atSourceTime: s)
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let image = loader.image, crop.width > 0 {
                let scale = paneSize.width / crop.width
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(
                        width: context.sourceSize.width * scale,
                        height: context.sourceSize.height * scale)
                    .offset(x: -crop.minX * scale, y: -crop.minY * scale)
                    .frame(width: paneSize.width, height: paneSize.height, alignment: .topLeading)
                    .clipped()
            }
            badge
        }
        .frame(width: paneSize.width, height: paneSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: min(max(0, Int(frame.rounded())), context.frames.count - 1)) {
            guard let location = locate(s) else { return }
            loader.load(url: location.url, seconds: location.seconds)
        }
        .accessibilityLabel("Preview at \(GuidedScrubContext.clock(clipSeconds)) of the clip")
    }

    private var clipSeconds: Double {
        Double(frame) / Double(context.outputFPS)
    }

    /// Same capsule idiom as the exact-frame badge, but making the opposite
    /// claim: this picture is approximate, and this is where it sits on the
    /// finished clip's clock.
    private var badge: some View {
        Text("≈ preview · \(GuidedScrubContext.clock(clipSeconds)) of \(SpeedMath.clipLengthCompact(context.totalSeconds))")
            .font(.system(size: 10, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(8)
    }
}

// MARK: - The scrub strip

/// The input surface: a thin bar under the stage covering the step's slice of
/// the output clock. Dragging (or hovering, on the Mac) scrubs; a drag locks
/// the preview on screen so the frame can be studied, and the ✕ lets it go.
/// The lock is shared with the pane's own scrub so a held preview survives a
/// stray hover.
struct GuidedScrubStrip: View {
    let context: GuidedScrubContext
    let window: ClosedRange<Int>
    @Binding var scrubFrame: Double?
    /// A finished drag holds the preview; a hover is a peek and clears on
    /// exit. The lock says which of the two set the current value.
    @Binding var locked: Bool
    var width: CGFloat

    private var outFps: Double { Double(context.outputFPS) }

    var body: some View {
        HStack(spacing: 8) {
            bar
            if locked, scrubFrame != nil {
                Button {
                    scrubFrame = nil
                    locked = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop previewing")
            }
        }
        .frame(width: width)
    }

    /// iOS strips live inside the survey's scroll, so the first movement
    /// classifies the drag — sideways scrubs, downwards scrolls on — with the
    /// framing box's @GestureState healer so a cancelled drag can't leave a
    /// stale classification. A plain tap jumps the scrub to the tapped spot.
    @State private var engaged: Bool?
    @GestureState private var dragLive = false

    private var bar: some View {
        GeometryReader { proxy in
            let barWidth = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LL.cardBackground)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                HStack {
                    Text(stripTime(Double(window.lowerBound) / outFps))
                    Spacer()
                    Text(stripTime(Double(window.upperBound + 1) / outFps))
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .allowsHitTesting(false)
                if let progress = currentProgress {
                    Circle()
                        .fill(LL.accent)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .offset(x: progress * (barWidth - 14))
                        .allowsHitTesting(false)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "eye")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Preview")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(LL.accent)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                locked = true
                scrub(at: point.x, in: barWidth)
            }
            .gesture(barDrag(barWidth: barWidth))
            .onChange(of: dragLive) { live in
                guard !live else { return }
                engaged = nil
            }
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    // A held frame survives a stray hover — hover only peeks
                    // while nothing is locked.
                    guard !locked else { return }
                    scrub(at: point.x, in: barWidth)
                case .ended:
                    if !locked { scrubFrame = nil }
                }
            }
            #endif
        }
        .frame(height: 22)
        .accessibilityLabel("Scrub the preview")
    }

    private func barDrag(barWidth: CGFloat) -> some Gesture {
        #if os(macOS)
        return DragGesture(minimumDistance: 0)
            .updating($dragLive) { _, live, _ in live = true }
            .onChanged { value in
                locked = true
                scrub(at: value.location.x, in: barWidth)
            }
        #else
        return DragGesture(minimumDistance: 10)
            .updating($dragLive) { _, live, _ in live = true }
            .onChanged { value in
                if engaged == nil {
                    engaged = abs(value.translation.width) > abs(value.translation.height)
                }
                guard engaged == true else { return }
                locked = true
                scrub(at: value.location.x, in: barWidth)
            }
        #endif
    }

    private func stripTime(_ seconds: Double) -> String {
        GuidedScrubContext.clock(seconds)
    }

    private var currentProgress: CGFloat? {
        guard let scrubFrame, window.upperBound > window.lowerBound else { return nil }
        let span = Double(window.upperBound - window.lowerBound)
        return CGFloat(min(max(0, (scrubFrame - Double(window.lowerBound)) / span), 1))
    }

    private func scrub(at x: CGFloat, in barWidth: CGFloat) {
        guard barWidth > 1 else { return }
        let progress = Double(min(max(0, x / barWidth), 1))
        scrubFrame = Double(window.lowerBound)
            + progress * Double(window.upperBound - window.lowerBound)
    }
}

// MARK: - Stage wrapper

/// Wraps a step's exact-frame stage: while the strip is scrubbed the ≈
/// preview covers the stage, and letting go hands the exact frame back. The
/// stage underneath keeps every gesture it had — the preview overlay takes no
/// touches — so the compose surfaces stay exact-frame and undisturbed.
struct GuidedScrubOverlay<Content: View>: View {
    let context: GuidedScrubContext?
    let window: ClosedRange<Int>?
    let paneSize: CGSize
    let locate: (Double) -> (url: URL, seconds: Double)?
    @Binding var scrubFrame: Double?
    @Binding var locked: Bool
    /// Whether the pane itself scrubs (drag anywhere, hover on the Mac).
    /// Only for panes that are pure context — a stage that also composes
    /// (the canvas step's crop) keeps its own gestures and scrubs from the
    /// strip alone.
    var allowsPaneScrub = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            stage
            if let context, let window, window.upperBound > window.lowerBound {
                GuidedScrubStrip(
                    context: context, window: window,
                    scrubFrame: $scrubFrame, locked: $locked, width: paneSize.width)
            }
        }
    }

    @ViewBuilder private var stage: some View {
        let base = ZStack(alignment: .topLeading) {
            content()
            if let context, let frame = scrubFrame {
                GuidedScrubDisplay(
                    context: context, frame: frame, locate: locate, paneSize: paneSize)
                    .allowsHitTesting(false)
            }
        }
        if allowsPaneScrub, context != nil, let window,
           window.upperBound > window.lowerBound {
            base.modifier(GuidedPaneScrub(
                window: window, paneWidth: paneSize.width,
                scrubFrame: $scrubFrame, locked: $locked))
        } else {
            base
        }
    }
}

// MARK: - Pane scrub input

/// Direct scrubbing on a preview pane — a drag anywhere across it (and a
/// hover, on the Mac) maps the pane's width onto the window. Only for panes
/// that are pure previews: a surface that also composes framing keeps its
/// own gestures and takes its scrubs from the strip.
struct GuidedPaneScrub: ViewModifier {
    let window: ClosedRange<Int>
    let paneWidth: CGFloat
    @Binding var scrubFrame: Double?
    @Binding var locked: Bool

    /// iOS panes live inside the survey's scroll — the first movement
    /// decides whether this drag is a scrub (sideways) or a scroll (down the
    /// page), the same first-event classification the framing box uses,
    /// healed by its @GestureState pattern so a cancelled drag can't leave a
    /// stale answer. The Mac has no drag-to-scroll to protect, so it engages
    /// immediately.
    @State private var engaged: Bool?
    @GestureState private var dragLive = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onChange(of: dragLive) { live in
                guard !live else { return }
                engaged = nil
            }
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    // A held frame survives a stray hover.
                    guard !locked else { return }
                    scrub(at: point.x)
                case .ended:
                    if !locked { scrubFrame = nil }
                }
            }
            #endif
    }

    private var dragGesture: some Gesture {
        #if os(macOS)
        return DragGesture(minimumDistance: 0)
            .updating($dragLive) { _, live, _ in live = true }
            .onChanged { value in
                locked = true
                scrub(at: value.location.x)
            }
        #else
        return DragGesture(minimumDistance: 10)
            .updating($dragLive) { _, live, _ in live = true }
            .onChanged { value in
                if engaged == nil {
                    engaged = abs(value.translation.width) > abs(value.translation.height)
                }
                guard engaged == true else { return }
                locked = true
                scrub(at: value.location.x)
            }
        #endif
    }

    private func scrub(at x: CGFloat) {
        guard paneWidth > 1 else { return }
        let progress = Double(min(max(0, x / paneWidth), 1))
        scrubFrame = Double(window.lowerBound)
            + progress * Double(window.upperBound - window.lowerBound)
    }
}

// MARK: - Storyboard

/// One storyboard cell: the ≈ frame at one moment of the clip, through the
/// crop that renders there. Loads once per appearance — the review step is a
/// contact sheet, not a scrubber.
struct GuidedStoryboardCell: View {
    let context: GuidedScrubContext
    /// Absolute output frame this cell represents.
    let frame: Int
    let locate: (Double) -> (url: URL, seconds: Double)?
    let cellSize: CGSize
    let caption: String

    @StateObject private var loader = WarpPreviewLoader(debounceMilliseconds: 0)

    var body: some View {
        let s = context.sourceTime(atFrame: Double(frame))
        let crop = context.crop(atSourceTime: s)
        VStack(spacing: 3) {
            ZStack {
                Color.black
                if let image = loader.image, crop.width > 0 {
                    let scale = cellSize.width / crop.width
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(
                            width: context.sourceSize.width * scale,
                            height: context.sourceSize.height * scale)
                        .offset(x: -crop.minX * scale, y: -crop.minY * scale)
                        .frame(width: cellSize.width, height: cellSize.height, alignment: .topLeading)
                        .clipped()
                }
            }
            .frame(width: cellSize.width, height: cellSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(caption)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .task(id: frame) {
            guard let location = locate(s) else { return }
            loader.load(url: location.url, seconds: location.seconds)
        }
        .accessibilityLabel("\(caption), at \(GuidedScrubContext.clock(Double(frame) / Double(context.outputFPS)))")
    }
}
