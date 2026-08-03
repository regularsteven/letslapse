import SwiftUI
import AVFoundation

/// Loads the playhead's frame — the nearest keyframe, decoded once per URL —
/// for the warp timeline's floating thumbnail and the wide layout's preview.
@MainActor
final class WarpPreviewLoader: ObservableObject {
    @Published var image: CGImage?
    private var generators: [URL: AVAssetImageGenerator] = [:]
    private var task: Task<Void, Never>?

    func load(url: URL, seconds: Double) {
        task?.cancel()
        let generator = generators[url] ?? {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            // Keyframe-tolerant on purpose: "≈ keyframe" is the contract, and
            // it keeps scrubbing free.
            g.requestedTimeToleranceBefore = .positiveInfinity
            g.requestedTimeToleranceAfter = .positiveInfinity
            g.maximumSize = CGSize(width: 480, height: 480)
            g.appliesPreferredTrackTransform = true
            generators[url] = g
            return g
        }()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            let image = try? await generator.image(at: time).image
            guard !Task.isCancelled, let image else { return }
            self?.image = image
        }
    }
}

/// The 3a warp timeline: the source bar with per-stretch speeds, seam pills,
/// a scrubbable playhead, drag-to-nominate, resize handles, zoom, and the
/// long-press stretch menu. All edits go through `model.updateWarp`.
struct WarpTimelineView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selectedStretch: Int
    @ObservedObject var preview: WarpPreviewLoader
    /// Wide layouts draw the preview beside the timeline instead of the
    /// floating thumbnail above it.
    var showsInlineThumbnail = true

    /// Visible source window (zoom); nil = the whole source.
    @State private var zoomStart: Double?
    @State private var zoomEnd: Double?
    @State private var playhead: Double = 0
    @State private var playheadPlaced = false
    /// In-flight drag-to-nominate range, in source seconds.
    @State private var nominating: ClosedRange<Double>?
    /// Which seam's popover is open.
    @State private var openSeam: Int?
    @State private var pinchBase: (start: Double, end: Double)?
    /// The held stretch's menu (Remove · Split · Reset). A hold opens it; the
    /// release's tap is swallowed by the flag so it doesn't immediately close.
    @State private var menuStretch: Int?
    @State private var menuOpenedByHold = false

    private var timeline: WarpTimeline { model.activeWarp() }
    private var total: Double { max(0.001, timeline.sourceSeconds) }
    private var visibleStart: Double { min(max(0, zoomStart ?? 0), total) }
    private var visibleEnd: Double { min(zoomEnd ?? total, total) }
    private var visibleSpan: Double { max(WarpTimelineView.minimumZoomSpan / 4, visibleEnd - visibleStart) }
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
            header
            if showsInlineThumbnail {
                thumbnailStrip
            }
            GeometryReader { proxy in
                barZone(width: max(1, proxy.size.width))
            }
            .frame(height: 96)

            HStack {
                Text(WarpTimeline.clock(visibleStart))
                Spacer()
                Text(WarpTimeline.clock((visibleStart + visibleEnd) / 2))
                Spacer()
                Text(WarpTimeline.clock(visibleEnd))
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .contentShape(Rectangle())
            .gesture(panGesture)

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
        .onAppear(perform: placePlayheadIfNeeded)
        .onChange(of: model.currentCaptureID) { _ in
            playheadPlaced = false
            zoomStart = nil
            zoomEnd = nil
            openSeam = nil
            placePlayheadIfNeeded()
        }
        .onChange(of: playhead) { _ in loadPreview() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("SOURCE · \(WarpTimeline.clock(total))")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.5)
            Spacer()
            if zoomStart != nil || zoomEnd != nil {
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
                }
                .buttonStyle(.plain)
            }
            Text("pinch to zoom · drag to nominate · hold for options")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: - Thumbnail strip

    private var thumbnailStrip: some View {
        GeometryReader { proxy in
            let fraction = (playhead - visibleStart) / visibleSpan
            let clamped = min(max(fraction, 0.17), 0.83)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.black)
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
                        Text(WarpTimeline.clock(playhead))
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
                    .frame(width: 120, height: 72)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    .offset(x: clamped * proxy.size.width - 60)
            }
        }
        .frame(height: 76)
    }

    // MARK: - Bar

    private func position(_ time: Double, width: CGFloat) -> CGFloat {
        CGFloat((time - visibleStart) / visibleSpan) * width
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        min(max(0, visibleStart + Double(x / width) * visibleSpan), total)
    }

    /// Visible tiles with a 12pt floor, the clamped-up surplus taken from the
    /// wider tiles so the row fills its line exactly.
    private func tileLayout(width: CGFloat) -> [(index: Int, width: CGFloat)] {
        let bounds = timeline.bounds
        var visible: [(index: Int, share: Double)] = []
        for index in 0..<timeline.stretchCount {
            let clippedStart = max(bounds[index], visibleStart)
            let clippedEnd = min(bounds[index + 1], visibleEnd)
            if clippedEnd > clippedStart {
                visible.append((index, (clippedEnd - clippedStart) / visibleSpan))
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
            // row with priority over the tiles' own context-menu interaction;
            // the knob, handles and seam pills are siblings with their own
            // gestures, untouched by it.
            HStack(spacing: 2) {
                ForEach(tileLayout(width: width), id: \.index) { tile in
                    stretchTile(tile.index, width: tile.width)
                }
            }
            .padding(.top, 8)

            // Nomination overlay.
            if let nominating {
                let x0 = max(0, position(nominating.lowerBound, width: width))
                let x1 = min(width, position(nominating.upperBound, width: width))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LL.amber.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(LL.amber, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    )
                    .frame(width: max(0, x1 - x0), height: Self.barHeight)
                    .offset(x: x0, y: 8)
                    .allowsHitTesting(false)
            }

            // Resize handles for the selected stretch.
            if selectedStretch < timeline.stretchCount {
                let left = bounds[selectedStretch]
                let right = bounds[selectedStretch + 1]
                if selectedStretch > 0, left >= visibleStart, left <= visibleEnd {
                    resizeHandle(boundary: selectedStretch, width: width)
                        .offset(x: position(left, width: width) - 6, y: 5)
                }
                if selectedStretch < timeline.stretchCount - 1, right >= visibleStart, right <= visibleEnd {
                    resizeHandle(boundary: selectedStretch + 1, width: width)
                        .offset(x: position(right, width: width) - 6, y: 5)
                }
            }

            // Seam pills.
            seamPills(width: width)

            // Playhead.
            if playhead >= visibleStart, playhead <= visibleEnd {
                Rectangle()
                    .fill(LL.accent)
                    .frame(width: 2, height: 60)
                    .offset(x: position(playhead, width: width) - 1)
                    .allowsHitTesting(false)
                Circle()
                    .fill(LL.accent)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: position(playhead, width: width) - 9, y: -9)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                playhead = time(at: value.location.x, width: width)
                            }
                    )
                    .accessibilityLabel("Playhead, \(WarpTimeline.clock(playhead))")
            }
        }
        .contentShape(Rectangle())
        .gesture(nominateGesture(width: width))
        .simultaneousGesture(pinchGesture(width: width))
    }

    private func stretchTile(_ index: Int, width: CGFloat) -> some View {
        let speed = timeline.speeds[index]
        let slow = speed < 10
        let selected = index == selectedStretch
        let clippedStart = max(timeline.bounds[index], visibleStart)
        let clippedEnd = min(timeline.bounds[index + 1], visibleEnd)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return shape
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
                        let fraction = min(max(0, value.location.x / max(1, width)), 1)
                        playhead = clippedStart + Double(fraction) * (clippedEnd - clippedStart)
                        selectedStretch = index
                        openSeam = nil
                        menuStretch = nil
                    }
            )
            .accessibilityLabel("Stretch \(index + 1), \(WarpTimeline.speedLabel(speed)) \(WarpTimeline.speedWord(speed))")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The held stretch's menu — the prototype's Remove · Split here · Reset,
    /// as an inline card so one gesture owns the whole bar.
    private func stretchMenu(_ index: Int) -> some View {
        VStack(spacing: 0) {
            menuRow("Remove stretch", color: Color(red: 1, green: 0.23, blue: 0.19)) {
                guard timeline.stretchCount > 1 else { return }
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

    private func menuRow(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { menuStretch = nil }
            action()
        } label: {
            Text(title)
                .font(.system(size: 13.5))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func resizeHandle(boundary: Int, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LL.accent)
            .frame(width: 12, height: Self.barHeight + 6)
            .overlay(
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white)
                    .frame(width: 3, height: 24)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let target = time(at: value.location.x, width: width)
                        model.updateWarp { $0.resize(boundary: boundary, to: target) }
                    }
            )
            .accessibilityLabel("Resize stretch boundary")
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
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    openSeam = openSeam == pill.index ? nil : pill.index
                }
            } label: {
                Text(seamLabel(pill.seam))
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(pill.seam.ramp == .step ? Color(red: 0.227, green: 0.227, blue: 0.247) : LL.amber)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        pill.seam.ramp == .step ? Color(red: 0.894, green: 0.894, blue: 0.914) : LL.ink,
                        in: Capsule())
            }
            .buttonStyle(.plain)
            .position(x: min(max(pill.x, 24), width - 24), y: pill.stacked ? 84 : 66)
            .accessibilityLabel("Seam ramp \(seamLabel(pill.seam))")
        }
    }

    private func seamLabel(_ seam: WarpTimeline.Seam) -> String {
        guard seam.ramp != .step else { return "step" }
        let side = seam.side == .before ? " ◀" : seam.side == .after ? " ▶" : " ·?"
        return "~\(seam.ramp.label)\(side)"
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
                            var updated = $0.seams[index]
                            updated.ramp = ramp
                            if ramp == .step { updated.side = nil }
                            $0.setSeam(updated, at: index)
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
            HStack(spacing: 6) {
                sideChip(index, seam: seam, side: .before, label: "◀ Before seam")
                sideChip(index, seam: seam, side: .after, label: "After seam ▶")
            }
            Text(seamHint(seam))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func sideChip(_ index: Int, seam: WarpTimeline.Seam, side: WarpTimeline.Seam.Side, label: String) -> some View {
        let active = seam.side == side
        return Button {
            guard seam.ramp != .step else { return }
            model.updateWarp {
                var updated = $0.seams[index]
                updated.side = side
                $0.setSeam(updated, at: index)
            }
        } label: {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(active ? LL.amber : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(active ? LL.ink : LL.screenBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(seam.ramp == .step ? 0.35 : 1)
    }

    private func seamHint(_ seam: WarpTimeline.Seam) -> String {
        if seam.ramp == .step {
            return "Instant speed step — no frames lost; blur snaps with speed."
        }
        guard let side = seam.side else {
            return "Pick which side spends the time — the ease must borrow from one stretch."
        }
        return side == .before
            ? "Ease completes before the seam — borrows time from the earlier stretch."
            : "Ease starts at the seam — borrows time from the later stretch."
    }

    // MARK: - Selection line

    private var selectionLine: some View {
        let index = min(selectedStretch, max(0, timeline.stretchCount - 1))
        let speed = timeline.speeds[index]
        let range = timeline.range(of: index)
        let output = timeline.length(of: index) / max(0.0001, speed)
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
                    menuStretch = menuStretch == index ? nil : index
                    openSeam = nil
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LL.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stretch options")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(LL.screenBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Gestures

    /// A horizontal drag across the bar carves a 1× stretch exactly where
    /// drawn. The 24 pt activation distance plus high priority is the shape
    /// that reliably beats the enclosing scroll view (see SwipeToDelete);
    /// taps and holds don't reach it, so they stay with their own gestures.
    private func nominateGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) || nominating != nil else { return }
                let start = time(at: value.startLocation.x, width: width)
                let current = time(at: value.location.x, width: width)
                nominating = min(start, current)...max(start, current)
                playhead = current
                menuStretch = nil
                openSeam = nil
            }
            .onEnded { _ in
                defer { nominating = nil }
                guard let range = nominating,
                      range.upperBound - range.lowerBound >= WarpTimeline.minimumNomination else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    model.updateWarp { timeline in
                        if let created = timeline.nominate(from: range.lowerBound, to: range.upperBound) {
                            selectedStretch = created
                        }
                    }
                }
            }
    }

    /// Pinch zooms around the visible centre, floored at a 20-second window.
    private func pinchGesture(width: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let base = pinchBase ?? (visibleStart, visibleEnd)
                pinchBase = base
                let span = base.end - base.start
                let newSpan = min(max(span / Double(scale), Self.minimumZoomSpan), total)
                let centre = (base.start + base.end) / 2
                var start = centre - newSpan / 2
                start = min(max(0, start), total - newSpan)
                zoomStart = start
                zoomEnd = start + newSpan
            }
            .onEnded { _ in
                pinchBase = nil
                if visibleEnd - visibleStart >= total - 0.5 {
                    zoomStart = nil
                    zoomEnd = nil
                }
            }
    }

    /// Dragging the clock ruler pans a zoomed window.
    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoomStart != nil || zoomEnd != nil else { return }
                let span = visibleSpan
                let shift = -Double(value.translation.width / 320) * span * 0.1
                var start = visibleStart + shift
                start = min(max(0, start), total - span)
                zoomStart = start
                zoomEnd = start + span
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
