import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Loads the playhead's frame — the nearest keyframe, decoded once per URL —
/// for the warp timeline's floating thumbnail and the wide layout's preview.
@MainActor
final class WarpPreviewLoader: ObservableObject {
    @Published var image: CGImage?
    private var generators: [URL: AVAssetImageGenerator] = [:]
    private var task: Task<Void, Never>?
    /// How long a request may be superseded before it decodes — the timeline's
    /// 90ms suits a knob drag; the guided scrub runs tighter so a hover feels
    /// attached to the pointer.
    private let debounceNanos: UInt64

    init(debounceMilliseconds: UInt64 = 90) {
        debounceNanos = debounceMilliseconds * 1_000_000
    }

    func load(url: URL, seconds: Double) {
        task?.cancel()
        let generator = generators[url] ?? {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            // Keyframe-tolerant on purpose: "≈ keyframe" is the contract, and
            // it keeps scrubbing free.
            g.requestedTimeToleranceBefore = .positiveInfinity
            g.requestedTimeToleranceAfter = .positiveInfinity
            // The preview is now a full-width pane, not a 120pt thumbnail —
            // decode enough pixels for a 3× phone at card width.
            g.maximumSize = CGSize(width: 1024, height: 1024)
            g.appliesPreferredTrackTransform = true
            generators[url] = g
            return g
        }()
        task = Task { [weak self, debounceNanos] in
            try? await Task.sleep(nanoseconds: debounceNanos)
            guard !Task.isCancelled else { return }
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            let image = try? await generator.image(at: time).image
            guard !Task.isCancelled, let image else { return }
            self?.image = image
        }
    }
}

/// Gesture confirmations for the timeline. UIKit generators because the
/// deployment target predates `.sensoryFeedback`; silent no-ops on macOS,
/// where the pointer is its own confirmation.
enum WarpHaptics {
    static func success() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func warning() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    static func tick() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    static func engage() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    static func limit() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        #endif
    }
}

/// A transient confirmation over the timeline — "Added 1× stretch · Undo".
private struct TimelineToast: Equatable {
    let id = UUID()
    var message: String
    var showsUndo: Bool

    static func == (lhs: TimelineToast, rhs: TimelineToast) -> Bool {
        lhs.id == rhs.id
    }
}

/// The 3a warp timeline: the source bar with per-stretch speeds, seam pills,
/// a scrubbable playhead, drag-to-nominate, resize handles, zoom, and the
/// hold (or macOS right-click) stretch menu. All edits go through
/// `model.updateWarp`, which keeps the undo history.
struct WarpTimelineView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selectedStretch: Int
    @ObservedObject var preview: WarpPreviewLoader
    /// Wide layouts draw the preview beside the timeline instead of the
    /// floating thumbnail above it.
    var showsInlineThumbnail = true
    /// The reframe lane rides under the bar when open; the inline preview
    /// then becomes the interactive punch canvas. The playhead is shared with
    /// the Adjust screen so both draw the same moment.
    var showsReframeLane = false
    @Binding var playhead: Double
    /// Owned by the Adjust screen with the playhead itself — a layout flip
    /// (wide ↔ narrow) rebuilds this view, and a rebuilt view must not
    /// re-place a playhead the user already owns.
    @Binding var playheadPlaced: Bool
    @Binding var selectedReframeKey: Int?
    @Binding var reframeDraft: ReframeDraft?

    /// Visible source window (zoom); nil = the whole source.
    @State private var zoomStart: Double?
    @State private var zoomEnd: Double?
    /// In-flight drag-to-nominate range, in source seconds.
    @State private var nominating: ClosedRange<Double>?
    /// Whether the in-flight nomination has crossed the minimum span — drives
    /// the overlay's dashed-vs-amber state and the crossing tick.
    @State private var nominateWasValid = false
    /// Which seam's popover is open.
    @State private var openSeam: Int?
    @State private var pinchBase: (start: Double, end: Double)?
    @State private var pinchAtLimit = false
    /// Pan anchor: the value at first onChanged, so cumulative translations
    /// apply once instead of compounding.
    @State private var panBase: Double?
    /// Knob/handle grab offsets in bar-space pixels (finger x − control x at
    /// grab), so an off-centre grab tracks without snapping. nil = not
    /// engaged; the healers clear them on gesture cancellation.
    @State private var playheadDragBase: Double?
    @State private var handleDragBase: Double?
    /// A pinch happened during the current touch sequence. The drag that
    /// survives a pinch must never carve — its coordinates were remapped
    /// mid-gesture. Cleared once both the pinch and the drag are over.
    @State private var dragSawPinch = false
    /// Recognition liveness, tracked with @GestureState because SwiftUI resets
    /// it even when a gesture is CANCELLED (scroll steal, interruption) — the
    /// onChange healers below reset the plain-@State anchors that onEnded
    /// would otherwise never clear.
    @GestureState private var pinchLive = false
    @GestureState private var nominateLive = false
    @GestureState private var knobLive = false
    @GestureState private var handleLive = false
    @GestureState private var panLive = false
    /// The held stretch's menu (Remove · Split · Reset). A hold opens it; the
    /// release's tap is swallowed by the flag so it doesn't immediately close.
    @State private var menuStretch: Int?
    @State private var menuOpenedByHold = false
    @State private var toast: TimelineToast?

    private var timeline: WarpTimeline { model.activeWarp() }
    private var total: Double { max(0.001, timeline.sourceSeconds) }
    private var visibleStart: Double { min(max(0, zoomStart ?? 0), total) }
    private var visibleEnd: Double { min(zoomEnd ?? total, total) }
    private var visibleSpan: Double { max(0.001, visibleEnd - visibleStart) }
    private var isZoomed: Bool { zoomStart != nil || zoomEnd != nil }
    private var playheadVisible: Bool { playhead >= visibleStart && playhead <= visibleEnd }
    /// The zoom floor — clips shorter than 20s zoom no further than themselves.
    private var minimumSpan: Double { min(WarpTimelineView.minimumZoomSpan, total) }
    private static let minimumZoomSpan = 20.0
    private static let barHeight: CGFloat = 50

    private static let baseGradient = LinearGradient(
        colors: [Color(red: 0.20, green: 0.255, blue: 0.353), Color(red: 0.106, green: 0.137, blue: 0.188)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    private static let slowGradient = LinearGradient(
        colors: [Color(red: 0.42, green: 0.29, blue: 0.086), Color(red: 0.227, green: 0.18, blue: 0.078)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsInlineThumbnail {
                Group {
                    if showsReframeLane {
                        // The interactive punch canvas — same slot, same
                        // playhead frame, gestures on. The chips overlay
                        // AFTER it, so they win the taps they always won.
                        ReframeCanvasView(
                            preview: preview,
                            playhead: $playhead,
                            selectedKey: $selectedReframeKey,
                            draft: $reframeDraft)
                    } else {
                        scrubPreview
                    }
                }
                .overlay(alignment: .topLeading) {
                    // Overlaid AFTER the pane's allowsHitTesting(false),
                    // so the chips stay tappable over the dead pane.
                    editChips
                        .padding(6)
                }
            } else if model.canUndoWarp || isZoomed {
                // Wide layouts draw no inline preview — the chips get a slim
                // row of their own that only exists while they do.
                HStack {
                    Spacer()
                    editChips
                }
            }
            GeometryReader { proxy in
                barZone(width: max(1, proxy.size.width))
            }
            .frame(height: 96)

            if showsReframeLane {
                ReframeLaneView(
                    selectedKey: $selectedReframeKey,
                    playhead: $playhead,
                    position: { time, width in self.position(time, width: width) },
                    timeAt: { x, width in self.time(at: x, width: width) },
                    visibleStart: visibleStart,
                    visibleEnd: visibleEnd)
                    .transition(.opacity)
            }

            ruler

            if isZoomed {
                minimap
                    .transition(.opacity)
            }

            selectionLine

            if let openSeam, openSeam < timeline.seams.count {
                seamPopover(openSeam)
                    .transition(.opacity)
            }
            if let menuStretch, menuStretch < timeline.stretchCount {
                stretchMenu(menuStretch)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                // Over the thumbnail strip in portrait; over the header row in
                // wide layouts, where padding 28 would blanket the bar itself.
                toastView(toast)
                    .padding(.top, showsInlineThumbnail ? 28 : 0)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .task(id: toast.id) {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        withAnimation(.easeInOut(duration: 0.2)) { self.toast = nil }
                    }
            }
        }
        .onAppear(perform: placePlayheadIfNeeded)
        .onChange(of: model.currentCaptureID) { _ in
            playheadPlaced = false
            zoomStart = nil
            zoomEnd = nil
            openSeam = nil
            menuStretch = nil
            menuOpenedByHold = false
            panBase = nil
            pinchBase = nil
            pinchAtLimit = false
            playheadDragBase = nil
            handleDragBase = nil
            nominating = nil
            nominateWasValid = false
            dragSawPinch = false
            toast = nil
            placePlayheadIfNeeded()
        }
        .onChange(of: playhead) { _ in loadPreview() }
        // Undo can shrink the timeline under the selection — keep it legal.
        .onChange(of: timeline.stretchCount) { count in
            selectedStretch = min(selectedStretch, max(0, count - 1))
        }
        // Cancellation healers: @GestureState flips false on end AND cancel,
        // so anchors can't stay stuck when a gesture dies without onEnded.
        .onChange(of: pinchLive) { live in
            guard !live else { return }
            pinchBase = nil
            pinchAtLimit = false
            if !nominateLive { dragSawPinch = false }
        }
        .onChange(of: nominateLive) { live in
            guard !live else { return }
            nominating = nil
            nominateWasValid = false
            menuOpenedByHold = false
            if !pinchLive { dragSawPinch = false }
        }
        .onChange(of: knobLive) { live in
            if !live { playheadDragBase = nil }
        }
        .onChange(of: handleLive) { live in
            guard !live else { return }
            handleDragBase = nil
            model.endWarpCoalescing()
        }
        .onChange(of: panLive) { live in
            if !live { panBase = nil }
        }
    }

    // MARK: - Edit chips

    /// Undo and un-zoom, floating over the preview (or in their own slim row
    /// on wide layouts) now the SOURCE header row is gone — they must stay
    /// reachable wherever the timeline can be edited.
    private var editChips: some View {
        HStack(spacing: 6) {
            if model.canUndoWarp {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.requestWarpUndo()
                        toast = nil
                    }
                    WarpHaptics.tick()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9, weight: .bold))
                        Text("Undo")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(LL.amber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(LL.ink, in: Capsule())
                    .contentShape(Rectangle().inset(by: -10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Undo timeline edit")
            }
            if isZoomed {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        zoomStart = nil
                        zoomEnd = nil
                    }
                } label: {
                    Text("Fit \(WarpTimeline.clock(total))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LL.amber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(LL.ink, in: Capsule())
                        .contentShape(Rectangle().inset(by: -10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Toast

    private func toastView(_ toast: TimelineToast) -> some View {
        HStack(spacing: 10) {
            Text(toast.message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            if toast.showsUndo {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.requestWarpUndo()
                        self.toast = nil
                    }
                    WarpHaptics.tick()
                } label: {
                    Text("Undo")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(LL.amber)
                        .contentShape(Rectangle().inset(by: -10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Undo timeline edit")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(LL.ink, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    // MARK: - Scrub preview

    /// Tall canvases pin the picture to a fixed-height row instead of filling
    /// the card's whole height with video.
    private static let tallPreviewHeight: CGFloat = 300

    /// The playhead's frame at the chosen canvas — full width at the top of
    /// the card, centred (it no longer chases the playhead; tall canvases cap
    /// the height and centre the box). The frame aspect-fills the canvas
    /// shape, so a mismatched canvas previews the centred crop the created
    /// clip will keep. Scrubbing anywhere on the bar just swaps the picture.
    ///
    /// Hit-testing is OFF for the whole pane: the aspect-FILL image inside
    /// overflows the box on the mismatched axis, and `clipShape` clips
    /// drawing but not hit-testing — with a portrait source on a wide canvas
    /// the invisible spill sat over the canvas control (and the Undo chip)
    /// and silently swallowed their taps. Nothing in the pane is interactive
    /// today; scope this tighter when pinch-to-position arrives.
    private var scrubPreview: some View {
        let aspect = model.effectiveBlendCanvas().aspect
        return Group {
            if aspect < 1 {
                previewBox(aspect: aspect)
                    .frame(height: Self.tallPreviewHeight)
                    .frame(maxWidth: .infinity)
            } else {
                previewBox(aspect: aspect)
                    .frame(maxWidth: .infinity)
            }
        }
        .allowsHitTesting(false)
    }

    private func previewBox(aspect: Double) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.black)
            .aspectRatio(CGFloat(aspect), contentMode: .fit)
            .overlay {
                if let image = preview.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Self.baseGradient
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                Text(thumbnailBadge)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                Text("≈ keyframe")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(5)
            }
            // An off-window playhead dims its preview — the frame is real,
            // but it isn't where you're looking.
            .opacity(playheadVisible ? 1 : 0.55)
    }

    /// "2:41" while the playhead is visible; "◀ 2:41" / "2:41 ▶" when it sits
    /// beyond the zoomed window, pointing the way back.
    private var thumbnailBadge: String {
        if playhead < visibleStart { return "◀ \(WarpTimeline.clock(playhead))" }
        if playhead > visibleEnd { return "\(WarpTimeline.clock(playhead)) ▶" }
        return WarpTimeline.clock(playhead)
    }

    // MARK: - Output-time mapping

    /// Per-stretch speeds that reproduce the compiled schedule's real output
    /// shares — `length ÷ compiled seconds`, eases and quantization included —
    /// so the bar, the caption and the estimate card all tell one story. The
    /// nominal speeds when no schedule exists (Advanced ramp, unprobed
    /// source).
    private var effectiveSpeeds: [Double] {
        let speeds = timeline.speeds
        guard let compiled = model.compiledWarp(),
              compiled.stretchFrames.count == speeds.count else { return speeds }
        let outFps = Double(max(1, model.outputFPS))
        return speeds.indices.map { index in
            let frames = compiled.stretchFrames[index]
            guard frames > 0 else { return speeds[index] }
            return timeline.length(of: index) / (Double(frames) / outFps)
        }
    }

    /// Cumulative output (clip) seconds at each stretch bound. The bar draws
    /// in this domain, so a stretch's width is its share of the finished
    /// clip, not of the source: a 50× stretch that eats most of the source
    /// but lands as 1.9s of a 14s clip draws narrow, and the slow moment
    /// that IS most of the clip draws wide.
    private var outputBounds: [Double] {
        let speeds = effectiveSpeeds
        var bounds = [0.0]
        for index in 0..<timeline.stretchCount {
            bounds.append(bounds[index] + timeline.length(of: index) / max(0.0001, speeds[index]))
        }
        return bounds
    }

    /// Source seconds → output seconds through the piecewise-linear warp.
    private func outputTime(atSource time: Double) -> Double {
        let clamped = min(max(0, time), total)
        let index = timeline.stretchIndex(at: clamped)
        return outputBounds[index]
            + (clamped - timeline.bounds[index]) / max(0.0001, effectiveSpeeds[index])
    }

    /// Output seconds → source seconds — the inverse of `outputTime(atSource:)`.
    private func sourceTime(atOutput output: Double) -> Double {
        let outs = outputBounds
        let clamped = min(max(0, output), outs.last ?? 0)
        var index = 0
        while index < outs.count - 2, clamped >= outs[index + 1] {
            index += 1
        }
        let source = timeline.bounds[index]
            + (clamped - outs[index]) * max(0.0001, effectiveSpeeds[index])
        return min(max(0, source), total)
    }

    private var visibleOutputStart: Double { outputTime(atSource: visibleStart) }
    private var visibleOutputEnd: Double { outputTime(atSource: visibleEnd) }
    private var visibleOutputSpan: Double { max(0.0001, visibleOutputEnd - visibleOutputStart) }

    // MARK: - Bar

    private func position(_ time: Double, width: CGFloat) -> CGFloat {
        CGFloat((outputTime(atSource: time) - visibleOutputStart) / visibleOutputSpan) * width
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        sourceTime(atOutput: visibleOutputStart + Double(x / width) * visibleOutputSpan)
    }

    /// Visible tiles with a 12pt floor, the clamped-up surplus taken from the
    /// wider tiles so the row fills its line exactly. Shares are output-time
    /// shares — the tile row is the clip being made.
    private func tileLayout(width: CGFloat) -> [(index: Int, width: CGFloat)] {
        let bounds = timeline.bounds
        let speeds = effectiveSpeeds
        var visible: [(index: Int, share: Double)] = []
        for index in 0..<timeline.stretchCount {
            let clippedStart = max(bounds[index], visibleStart)
            let clippedEnd = min(bounds[index + 1], visibleEnd)
            if clippedEnd > clippedStart {
                let outputSpan = (clippedEnd - clippedStart) / max(0.0001, speeds[index])
                visible.append((index, outputSpan / visibleOutputSpan))
            }
        }
        guard !visible.isEmpty else { return [] }
        let minWidth: CGFloat = 12
        let available = max(1, width - 2 * CGFloat(visible.count - 1))
        guard available > minWidth * CGFloat(visible.count) else {
            return visible.map { ($0.index, max(2, available / CGFloat(visible.count))) }
        }
        var widths = visible.map { CGFloat($0.share) * available }
        var surplus: CGFloat = 0
        for i in widths.indices where widths[i] < minWidth {
            surplus += minWidth - widths[i]
            widths[i] = minWidth
        }
        if surplus > 0 {
            let flexible = widths.indices.filter { widths[$0] > minWidth }
            let flexTotal = flexible.reduce(CGFloat(0)) { $0 + (widths[$1] - minWidth) }
            if flexTotal > 0 {
                for i in flexible {
                    widths[i] -= surplus * (widths[i] - minWidth) / flexTotal
                }
            }
        }
        return zip(visible, widths).map { ($0.index, $1) }
    }

    private func barZone(width: CGFloat) -> some View {
        let bounds = timeline.bounds
        return ZStack(alignment: .topLeading) {
            // Stretch tiles. The nominate drag and the select tap live on this
            // row; the knob, handles and seam pills are siblings with their own
            // gestures, drawn later so their (enlarged) hit areas win overlaps.
            HStack(spacing: 2) {
                ForEach(tileLayout(width: width), id: \.index) { tile in
                    stretchTile(tile.index, width: tile.width)
                }
            }
            .padding(.top, 8)

            // Nomination overlay: dashed and quiet until the drag spans the
            // 2-second minimum, amber once it will really carve.
            if let nominating {
                let x0 = max(0, position(nominating.lowerBound, width: width))
                let x1 = min(width, position(nominating.upperBound, width: width))
                let valid = nominating.upperBound - nominating.lowerBound >= WarpTimeline.minimumNomination
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(valid ? LL.amber.opacity(0.35) : Color.secondary.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                valid ? LL.amber : Color.secondary.opacity(0.6),
                                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    )
                    .frame(width: max(0, x1 - x0), height: Self.barHeight)
                    .offset(x: x0, y: 8)
                    .allowsHitTesting(false)
            }

            // Seam pills — drawn BEFORE the handles so a handle's enlarged hit
            // area wins where the two overlap at a selected boundary.
            seamPills(width: width)

            // Resize handles for the selected stretch.
            if selectedStretch < timeline.stretchCount {
                let left = bounds[selectedStretch]
                let right = bounds[selectedStretch + 1]
                if selectedStretch > 0, left >= visibleStart, left <= visibleEnd {
                    resizeHandle(boundary: selectedStretch, width: width)
                        .offset(x: position(left, width: width) - 22, y: 2)
                }
                if selectedStretch < timeline.stretchCount - 1, right >= visibleStart, right <= visibleEnd {
                    resizeHandle(boundary: selectedStretch + 1, width: width)
                        .offset(x: position(right, width: width) - 22, y: 2)
                }
            }

            // Playhead — or, zoomed past it, a chevron that leads back.
            if playheadVisible {
                Rectangle()
                    .fill(LL.accent)
                    .frame(width: 2, height: 60)
                    .offset(x: position(playhead, width: width) - 1)
                    .allowsHitTesting(false)
                playheadKnob(width: width)
                    .offset(x: position(playhead, width: width) - 22, y: -22)
            } else {
                playheadChevron(width: width)
            }
        }
        .coordinateSpace(name: Self.barSpace)
        .contentShape(Rectangle())
        .gesture(nominateGesture(width: width))
        .simultaneousGesture(pinchGesture(width: width))
        .simultaneousGesture(doubleTapZoom(width: width))
    }

    /// The bar's named coordinate space. The knob and the resize handles move
    /// with their own drags, so a drag measured in their local space loses
    /// exactly the distance the view moved (halving the motion) — their
    /// gestures read locations in this space instead.
    private static let barSpace = "warpBar"

    private func playheadKnob(width: CGFloat) -> some View {
        // 18pt of accent inside a 44pt touch target.
        ZStack {
            Circle()
                .fill(LL.accent)
                .frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.barSpace))
                .updating($knobLive) { _, live, _ in live = true }
                .onChanged { value in
                    guard pinchBase == nil else { return }
                    // Absolute finger position in bar space keeps the knob
                    // exactly under the finger on the output-proportional
                    // axis; the remembered grab offset stops an off-centre
                    // grab from snapping the playhead.
                    let grab = playheadDragBase
                        ?? Double(value.location.x - position(playhead, width: width))
                    playheadDragBase = grab
                    let target = time(at: value.location.x - CGFloat(grab), width: width)
                    playhead = min(max(visibleStart, target), visibleEnd)
                }
                .onEnded { _ in playheadDragBase = nil }
        )
        .accessibilityLabel("Playhead, \(WarpTimeline.clock(playhead))")
    }

    /// The zoomed window has scrolled past the playhead — show where it went
    /// and offer a non-destructive way back.
    private func playheadChevron(width: CGFloat) -> some View {
        let leading = playhead < visibleStart
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                let span = visibleSpan
                var start = playhead - span / 2
                start = min(max(0, start), total - span)
                zoomStart = start
                zoomEnd = start + span
            }
        } label: {
            Image(systemName: leading ? "chevron.left.circle.fill" : "chevron.right.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(LL.accent)
                .background(Circle().fill(.white).padding(3))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: leading ? -8 : width - 36, y: 11)
        .accessibilityLabel("Playhead at \(WarpTimeline.clock(playhead)), tap to recenter")
    }

    private func stretchTile(_ index: Int, width: CGFloat) -> some View {
        let speed = timeline.speeds[index]
        let slow = speed < 10
        let selected = index == selectedStretch
        let clippedStart = max(timeline.bounds[index], visibleStart)
        let clippedEnd = min(timeline.bounds[index + 1], visibleEnd)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let tile = shape
            .fill(slow ? Self.slowGradient : Self.baseGradient)
            .overlay {
                if slow {
                    shape.inset(by: selected ? 3 : 0).strokeBorder(LL.amber, lineWidth: 1.5)
                }
            }
            .overlay {
                if selected {
                    shape.strokeBorder(LL.accent, lineWidth: 2.5)
                }
            }
            .overlay(alignment: .bottom) {
                if width >= 30 {
                    Text(WarpTimeline.speedLabel(speed))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(slow ? LL.amber : .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .fixedSize()
                        .padding(.bottom, 4)
                }
            }
            .frame(width: width, height: Self.barHeight)
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        // The release after a hold is a tap too — swallow it so
                        // it doesn't close the menu the hold just opened.
                        if menuOpenedByHold, menuStretch == index {
                            menuOpenedByHold = false
                            return
                        }
                        menuOpenedByHold = false
                        let fraction = min(max(0, value.location.x / max(1, width)), 1)
                        playhead = clippedStart + Double(fraction) * (clippedEnd - clippedStart)
                        selectedStretch = index
                        openSeam = nil
                        menuStretch = nil
                    }
            )
            .accessibilityLabel("Stretch \(index + 1), \(WarpTimeline.speedLabel(speed)) \(WarpTimeline.speedWord(speed))")
            .accessibilityAddTraits(selected ? .isSelected : [])
        return platformStretchActions(tile, index: index)
    }

    /// macOS right-click gets the native menu; iOS keeps the inline card via
    /// the hold gesture. The hold is NOT attached on macOS — a slow precise
    /// mouse press would trip it, and right-click already covers the intent.
    @ViewBuilder
    private func platformStretchActions(_ content: some View, index: Int) -> some View {
        #if os(macOS)
        content.contextMenu {
            Button(role: .destructive) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    model.updateWarp { selectedStretch = $0.remove(index) }
                }
            } label: {
                Label("Remove stretch", systemImage: "trash")
            }
            .disabled(timeline.stretchCount <= 1)
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    model.updateWarp { $0.split(index, at: playhead) }
                    selectedStretch = index
                }
            } label: {
                Label("Split here", systemImage: "scissors")
            }
            Button {
                model.updateWarp { $0.setSpeed(Double(max(1, model.constantWindow)), for: index) }
            } label: {
                Label("Reset speed", systemImage: "gauge")
            }
        }
        #else
        content.simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    menuOpenedByHold = true
                    selectedStretch = index
                    openSeam = nil
                    withAnimation(.easeInOut(duration: 0.15)) {
                        menuStretch = index
                    }
                    WarpHaptics.engage()
                }
        )
        #endif
    }

    /// The held stretch's menu — Remove · Split here · Reset, as an inline
    /// card so one gesture owns the whole bar. Reached by holding a stretch,
    /// the selection line's ellipsis, or right-click on macOS.
    private func stretchMenu(_ index: Int) -> some View {
        let removable = timeline.stretchCount > 1
        return VStack(spacing: 0) {
            menuRow(
                "Remove stretch",
                color: removable ? Color(red: 1, green: 0.23, blue: 0.19) : .secondary,
                enabled: removable
            ) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    model.updateWarp { selectedStretch = $0.remove(index) }
                }
            }
            Divider()
            menuRow("Split here", color: .primary) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    model.updateWarp { $0.split(index, at: playhead) }
                    selectedStretch = index
                }
            }
            Divider()
            menuRow("Reset speed", color: .primary) {
                model.updateWarp { $0.setSpeed(Double(max(1, model.constantWindow)), for: index) }
            }
        }
        .frame(width: 200)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
    }

    private func menuRow(
        _ title: String,
        color: Color,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard enabled else {
                menuOpenedByHold = false
                WarpHaptics.warning()
                return
            }
            menuOpenedByHold = false
            withAnimation(.easeInOut(duration: 0.15)) { menuStretch = nil }
            action()
        } label: {
            Text(title)
                .font(.system(size: 13.5))
                .foregroundStyle(color)
                .opacity(enabled ? 1 : 0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func resizeHandle(boundary: Int, width: CGFloat) -> some View {
        // 12pt of accent inside a 44pt touch target, so near-boundary drags
        // resize instead of falling through to the bar and carving.
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LL.accent)
                .frame(width: 12, height: Self.barHeight + 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white)
                        .frame(width: 3, height: 24)
                )
        }
        .frame(width: 44, height: Self.barHeight + 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.barSpace))
                .updating($handleLive) { _, live, _ in live = true }
                .onChanged { value in
                    guard pinchBase == nil else { return }
                    if handleDragBase == nil {
                        // A 3pt slop keeps a plain tap from becoming a
                        // zero-length resize (which would light Undo through
                        // mapping round-off) — and leaves it free to be the
                        // tap-through below.
                        guard abs(value.translation.width) > 3 else { return }
                        handleDragBase = Double(
                            value.location.x - position(timeline.bounds[boundary], width: width))
                        WarpHaptics.engage()
                    }
                    guard let grab = handleDragBase else { return }
                    // Absolute finger position in bar space (minus the grab
                    // offset) keeps the handle under the finger even though
                    // the bar's axis is output-proportional — source seconds
                    // per pixel change from stretch to stretch, and the
                    // handle itself moves as the timeline reflows.
                    let target = time(at: value.location.x - CGFloat(grab), width: width)
                    guard abs(target - timeline.bounds[boundary]) > 0.01 else { return }
                    model.updateWarp(coalescing: "resize-\(boundary)") {
                        $0.resize(boundary: boundary, to: target)
                    }
                }
                .onEnded { value in
                    let dragged = handleDragBase != nil
                    handleDragBase = nil
                    model.endWarpCoalescing()
                    if dragged {
                        WarpHaptics.engage()
                        return
                    }
                    // Never crossed the slop: this was a tap. The handle's
                    // enlarged hit area can blanket a minimum-width tile
                    // completely, so pass the tap through — select (and
                    // scrub to) whatever sits under the finger.
                    let tapped = time(at: value.location.x, width: width)
                    selectedStretch = timeline.stretchIndex(at: tapped)
                    playhead = tapped
                    openSeam = nil
                    menuStretch = nil
                }
        )
        .accessibilityLabel("Resize stretch boundary")
    }

    /// The compiled outcome of one seam's ease — nil while no schedule exists
    /// or the seam never asked for an ease.
    private func seamEase(_ index: Int) -> WarpCompiler.SeamEase? {
        guard let eases = model.compiledWarp()?.seamEases, index < eases.count else { return nil }
        return eases[index]
    }

    private func seamPills(width: CGFloat) -> some View {
        let bounds = timeline.bounds
        var previousX: CGFloat = -100
        var previousStacked = false
        var pills: [(index: Int, x: CGFloat, stacked: Bool, seam: WarpTimeline.Seam)] = []
        for index in 0..<timeline.seams.count {
            let boundary = bounds[index + 1]
            guard boundary >= visibleStart, boundary <= visibleEnd else { continue }
            let x = position(boundary, width: width)
            let stacked = (x - previousX) < 0.13 * width && !previousStacked
            previousX = x
            previousStacked = stacked
            pills.append((index, x, stacked, timeline.seams[index]))
        }
        return ForEach(pills, id: \.index) { pill in
            let ease = seamEase(pill.index)
            let clamped = ease?.isClamped == true
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    openSeam = openSeam == pill.index ? nil : pill.index
                }
            } label: {
                Text(seamLabel(pill.seam, ease: ease))
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(
                        clamped ? LL.ink
                        : pill.seam.ramp == .step ? Color(red: 0.227, green: 0.227, blue: 0.247)
                        : LL.amber)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        clamped ? LL.amber
                        : pill.seam.ramp == .step ? Color(red: 0.894, green: 0.894, blue: 0.914)
                        : LL.ink,
                        in: Capsule())
                    .frame(minWidth: 44, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .position(x: min(max(pill.x, 24), width - 24), y: pill.stacked ? 84 : 66)
            .accessibilityLabel(
                clamped
                ? "Seam ramp \(seamLabel(pill.seam, ease: ease)) — doesn't fit"
                : "Seam ramp \(seamLabel(pill.seam, ease: ease))")
        }
    }

    /// "~0.2s" — an ease's real compiled length, for the clamped pill.
    private func easeSecondsLabel(_ seconds: Double) -> String {
        seconds < 0.05 ? "~0s" : String(format: "~%.1fs", seconds)
    }

    private func seamLabel(_ seam: WarpTimeline.Seam, ease: WarpCompiler.SeamEase?) -> String {
        guard seam.ramp != .step else { return "step" }
        // A clamped ease shows what it really compiles to — the chip the user
        // picked lives in the popover.
        if let ease, ease.isClamped {
            return easeSecondsLabel(ease.applied)
        }
        return "~\(seam.ramp.label)"
    }

    // MARK: - Seam popover

    private func seamPopover(_ index: Int) -> some View {
        let seam = timeline.seams[index]
        return VStack(alignment: .leading, spacing: 8) {
            Text("RAMP AT THIS SEAM")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .kerning(0.4)
            HStack(spacing: 6) {
                ForEach(WarpTimeline.Seam.Ramp.allCases, id: \.self) { ramp in
                    let active = seam.ramp == ramp
                    Button {
                        model.updateWarp {
                            $0.setSeam(WarpTimeline.Seam(ramp: ramp), at: index)
                        }
                    } label: {
                        Text(ramp.label)
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(active ? LL.amber : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(active ? LL.ink : LL.screenBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            if let ease = seamEase(index), ease.isClamped {
                Text(seamClampNote(seam: seam, ease: ease))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LL.accent)
            }
            Text(seamHint(seam))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    /// Why the pill shows less than the chip asked for: easing through fast
    /// speeds costs `duration × mean eased speed` footage seconds, and the
    /// stretches beside this seam are shorter than that bill.
    private func seamClampNote(seam: WarpTimeline.Seam, ease: WarpCompiler.SeamEase) -> String {
        ease.applied < 0.05
            ? "No room for the ~\(seam.ramp.label) ease — it plays as a step. The stretches beside this seam are too short."
            : "Only \(easeSecondsLabel(ease.applied)) of the ~\(seam.ramp.label) ease fits — the stretches beside this seam are too short for more."
    }

    private func seamHint(_ seam: WarpTimeline.Seam) -> String {
        seam.ramp == .step
            ? "Instant speed step — no frames lost; blur snaps with speed."
            : "The ease rides across the seam — fast footage brakes into the cut, the denser footage carries the slow tail."
    }

    // MARK: - Selection line

    private var selectionLine: some View {
        let index = min(selectedStretch, max(0, timeline.stretchCount - 1))
        let speed = timeline.speeds[index]
        let range = timeline.range(of: index)
        // Effective speed, so this number is the stretch's real share of the
        // compiled clip — eases included — and the captions sum to the
        // estimate card's total.
        let output = timeline.length(of: index) / max(0.0001, effectiveSpeeds[index])
        return HStack(spacing: 8) {
            Text(
                "Stretch \(index + 1) of \(timeline.stretchCount) · "
                + "\(WarpTimeline.clock(range.lowerBound))–\(WarpTimeline.clock(range.upperBound)) · "
                + "\(WarpTimeline.speedLabel(speed)) \(WarpTimeline.speedWord(speed)) → "
                + "\(SpeedMath.clipLengthCompact(output)) of the clip")
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    menuOpenedByHold = false
                    menuStretch = menuStretch == index ? nil : index
                    openSeam = nil
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LL.accent)
                    .contentShape(Rectangle().inset(by: -14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stretch options")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(LL.screenBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Ruler + minimap

    /// "0s" — `clipLengthCompact` writes zero as "—", which a ruler edge
    /// can't.
    private func outputLabel(_ seconds: Double) -> String {
        seconds <= 0.049 ? "0s" : SpeedMath.clipLengthCompact(seconds)
    }

    /// The visible window's labels in CLIP time — the axis the bar now draws
    /// in; the badge on the preview keeps the source clock. Dragging the row
    /// pans a zoomed window 1:1.
    private var ruler: some View {
        GeometryReader { proxy in
            HStack {
                Text(outputLabel(visibleOutputStart))
                Spacer()
                Text(outputLabel((visibleOutputStart + visibleOutputEnd) / 2))
                Spacer()
                Text(outputLabel(visibleOutputEnd))
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .frame(maxHeight: .infinity)
            // Intrinsic-height row (matches the drawn spec); the inset grows
            // the pan strip's touch target without moving any pixels.
            .contentShape(Rectangle().inset(by: -10))
            .gesture(panGesture(width: max(1, proxy.size.width)))
        }
        .frame(height: 14)
    }

    /// Dragging the clock ruler pans a zoomed window — anchored at the drag's
    /// start so cumulative translation applies once, and scaled to the
    /// measured width so a finger-width of drag moves a finger-width of bar.
    private func panGesture(width: CGFloat) -> some Gesture {
        DragGesture()
            .updating($panLive) { _, live, _ in live = true }
            .onChanged { value in
                guard isZoomed else { return }
                let base = panBase ?? visibleStart
                panBase = base
                let span = visibleSpan
                // Output-domain shift so the bar's content tracks the finger
                // 1:1; the window keeps its source span (the zoom level).
                let shift = Double(value.translation.width / width) * visibleOutputSpan
                var start = sourceTime(atOutput: outputTime(atSource: base) - shift)
                start = min(max(0, start), total - span)
                zoomStart = start
                zoomEnd = start + span
            }
            .onEnded { _ in panBase = nil }
    }

    /// The whole source in one strip while zoomed: stretch bounds as ticks,
    /// the playhead in accent, and the amber lens marking — and moving — the
    /// visible window. One glance answers "where am I?".
    private var minimap: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 6)
                ForEach(1..<max(1, timeline.stretchCount), id: \.self) { index in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 1, height: 6)
                        .offset(x: CGFloat(timeline.bounds[index] / total) * width)
                }
                Rectangle()
                    .fill(LL.accent)
                    .frame(width: 1.5, height: 12)
                    .offset(x: CGFloat(playhead / total) * width - 0.75)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(LL.amber.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(LL.amber, lineWidth: 1.5)
                    )
                    .frame(width: max(10, CGFloat(visibleSpan / total) * width), height: 14)
                    .offset(x: CGFloat(visibleStart / total) * width)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle().inset(by: -10))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(0, Double(value.location.x / width)), 1)
                        let span = visibleSpan
                        var start = fraction * total - span / 2
                        start = min(max(0, start), total - span)
                        zoomStart = start
                        zoomEnd = start + span
                    }
            )
        }
        .frame(height: 16)
        .accessibilityLabel("Timeline overview, showing \(WarpTimeline.clock(visibleStart)) to \(WarpTimeline.clock(visibleEnd))")
    }

    // MARK: - Gestures

    /// A horizontal drag across the bar carves a 1× stretch exactly where
    /// drawn. Plain `.gesture` (not high-priority): the enclosing scroll view
    /// may still claim clearly vertical drags, which is right for a carving
    /// gesture — see SwipeToDelete for the non-destructive variant. The 24pt
    /// activation distance keeps taps and holds with their own gestures, and
    /// an active pinch or freshly held menu cancels nomination outright.
    private func nominateGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .updating($nominateLive) { _, live, _ in live = true }
            .onChanged { value in
                // dragSawPinch latches for the whole touch sequence: after a
                // pinch ends, the surviving finger's coordinates map through a
                // rezoomed window — rebuilding the range here would carve a
                // span the user never drew.
                guard pinchBase == nil, !dragSawPinch, !menuOpenedByHold else {
                    nominating = nil
                    return
                }
                guard abs(value.translation.width) > abs(value.translation.height) || nominating != nil else { return }
                let start = time(at: value.startLocation.x, width: width)
                let current = time(at: value.location.x, width: width)
                let range = min(start, current)...max(start, current)
                let valid = range.upperBound - range.lowerBound >= WarpTimeline.minimumNomination
                if valid, !nominateWasValid {
                    WarpHaptics.tick()
                }
                nominateWasValid = valid
                nominating = range
                playhead = current
                menuStretch = nil
                openSeam = nil
            }
            .onEnded { _ in
                defer {
                    nominating = nil
                    nominateWasValid = false
                    // A real drag means the release can never be the hold's
                    // swallow-tap — don't leave the flag latched.
                    menuOpenedByHold = false
                }
                guard pinchBase == nil, !dragSawPinch, let range = nominating else { return }
                guard range.upperBound - range.lowerBound >= WarpTimeline.minimumNomination else {
                    WarpHaptics.warning()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        toast = TimelineToast(
                            message: "Too short — drag past \(Int(WarpTimeline.minimumNomination))s, or zoom in",
                            showsUndo: false)
                    }
                    return
                }
                withAnimation(.easeInOut(duration: 0.25)) {
                    model.updateWarp { timeline in
                        if let created = timeline.nominate(from: range.lowerBound, to: range.upperBound) {
                            selectedStretch = created
                        }
                    }
                    toast = TimelineToast(message: "Added 1× stretch", showsUndo: true)
                }
                WarpHaptics.success()
            }
    }

    /// Pinch zooms anchored under the fingers (window centre before iOS 17 /
    /// macOS 14), floored at a 20-second window — with a firm tick when the
    /// zoom hits either end of its travel instead of silently eating input.
    /// A pinch also cancels any in-flight nomination: zooming must never carve.
    private func pinchGesture(width: CGFloat) -> AnyGesture<Void> {
        if #available(iOS 17.0, macOS 14.0, *) {
            return AnyGesture(
                MagnifyGesture()
                    .updating($pinchLive) { _, live, _ in live = true }
                    .onChanged { value in
                        applyPinch(scale: value.magnification, anchorX: Double(value.startAnchor.x))
                    }
                    .onEnded { _ in endPinch() }
                    .map { _ in () }
            )
        }
        return AnyGesture(
            MagnificationGesture()
                .updating($pinchLive) { _, live, _ in live = true }
                .onChanged { scale in
                    applyPinch(scale: Double(scale), anchorX: nil)
                }
                .onEnded { _ in endPinch() }
                .map { _ in () }
        )
    }

    private func applyPinch(scale: Double, anchorX: Double?) {
        let base = pinchBase ?? (visibleStart, visibleEnd)
        pinchBase = base
        nominating = nil
        nominateWasValid = false
        dragSawPinch = true
        let span = base.end - base.start
        let newSpan = min(max(span / max(0.01, scale), minimumSpan), total)
        // Anchor at the fingers when the gesture reports them; else keep the
        // playhead planted if it's in view, else the window centre. The bar
        // is output-proportional, so a finger fraction converts to its source
        // moment through the warp before the new window is placed around it.
        let outStart = outputTime(atSource: base.start)
        let outSpan = max(0.0001, outputTime(atSource: base.end) - outStart)
        let anchor: Double
        if let anchorX {
            anchor = min(max(0, anchorX), 1)
        } else if playhead >= base.start, playhead <= base.end, span > 0 {
            anchor = (outputTime(atSource: playhead) - outStart) / outSpan
        } else {
            anchor = 0.5
        }
        let anchorTime = sourceTime(atOutput: outStart + anchor * outSpan)
        var start = anchorTime - anchor * newSpan
        start = min(max(0, start), total - newSpan)
        zoomStart = start
        zoomEnd = start + newSpan
        let atLimit = newSpan <= minimumSpan + 0.0001 || newSpan >= total - 0.0001
        if atLimit, !pinchAtLimit {
            WarpHaptics.limit()
        }
        pinchAtLimit = atLimit
    }

    private func endPinch() {
        pinchBase = nil
        pinchAtLimit = false
        if visibleEnd - visibleStart >= total - 0.5 {
            zoomStart = nil
            zoomEnd = nil
        }
    }

    /// Double-tap (double-click on macOS — the only zoom a mouse has): zoom
    /// in around the tapped time, or back out to the whole source.
    private func doubleTapZoom(width: CGFloat) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                withAnimation(.easeInOut(duration: 0.25)) {
                    if isZoomed {
                        zoomStart = nil
                        zoomEnd = nil
                    } else {
                        let fraction = min(max(0, Double(value.location.x / max(1, width))), 1)
                        let newSpan = max(minimumSpan, total / 4)
                        guard newSpan < total - 0.5 else { return }
                        // The tapped pixel names a source moment through the
                        // output-proportional bar, not a plain fraction of it.
                        let anchorTime = time(at: value.location.x, width: width)
                        var start = anchorTime - fraction * newSpan
                        start = min(max(0, start), total - newSpan)
                        zoomStart = start
                        zoomEnd = start + newSpan
                    }
                }
            }
    }

    // MARK: - Preview

    private func placePlayheadIfNeeded() {
        guard !playheadPlaced else { return }
        playheadPlaced = true
        // Land on the first slow stretch — the thing worth looking at — else
        // the middle of the clip.
        let timeline = timeline
        if let slow = timeline.speeds.firstIndex(where: { $0 < 10 }), timeline.stretchCount > 1 {
            playhead = (timeline.bounds[slow] + timeline.bounds[slow + 1]) / 2
            selectedStretch = slow
        } else {
            playhead = timeline.sourceSeconds / 2
        }
        loadPreview()
    }

    private func loadPreview() {
        guard let location = model.warpFrameLocation(at: playhead) else { return }
        preview.load(url: location.url, seconds: location.seconds)
    }
}
