import SwiftUI
import LetsLapseKit

/// "Adjust" — the warp timeline (design 3a): scrub the source, drag to
/// nominate a real-time moment, give every stretch its own speed, let the
/// seams own the ramps — then create the clip. The edit is a time-warp, never
/// a trim: every source frame lands in the finished clip.
struct AdjustView: View {
    @EnvironmentObject var model: AppModel
    /// The window's UndoManager, handed to the model so Cmd-Z, shake, and
    /// three-finger-swipe drive the same timeline history as the Undo chip.
    @Environment(\.undoManager) private var undoManager
    @State private var showAdvanced = false
    @State private var showCustomSpeed = false
    /// The stretch the chips edit, as an index into the warp timeline.
    @State private var selectedStretch = 0
    /// "Blend from" choices, probed once per capture. Deciding them stats
    /// every encoding file on disk — too much to re-pay on every body
    /// evaluation (every @Published change re-runs the body).
    @State private var blendCodecs: [OutputCodec] = []
    @StateObject private var preview = WarpPreviewLoader()
    /// The playhead in source seconds — owned here so the timeline, the
    /// reframe lane and the punch canvas all draw the same moment. The
    /// placed flag lives here too: the wide/narrow layouts host structurally
    /// different WarpTimelineViews, and a rotation must not re-place the
    /// playhead (which would also drop an uncommitted draft).
    @State private var playhead: Double = 0
    @State private var playheadPlaced = false
    /// The reframe lane's visibility, selection and uncommitted framing.
    @State private var reframeLaneOpen = false
    @State private var selectedReframeKey: Int?
    @State private var reframeDraft: ReframeDraft?

    /// The canonical speeds, gated by what the selected stretch's footage can
    /// honour (2026-08-11 ramp review): the slow-motion chips need dense
    /// frames — ¼× wants footage at 4× the output rate, ½× at 2× (at 25 fps
    /// output: ≥100 and ≥50 fps) — and the racing chips are for base footage
    /// only: a burst exists to be slowed, and at slow-motion density the fast
    /// end just devours it. 1×/4×/15× are always offered; free values come
    /// through the value sheet.
    private func speedChips(forStretchFPS fps: Double) -> [(speed: Double, word: String)] {
        GuidedPlanner.gatedSpeedChips(forStretchFPS: fps, outputFPS: model.outputFPS)
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width > 560 && model.source?.isVideo == true
            VStack(spacing: 0) {
                FlowHeader(title: "New blended clip", onBack: { model.reset() }) {
                    if model.source?.isVideo == true {
                        canvasMenu
                    }
                }

                ScrollView {
                    if isWide {
                        wideLayout
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 16)
                    } else {
                        VStack(spacing: 14) {
                            if model.source?.isVideo == true {
                                warpCard(inlineThumbnail: true)
                                chipsRow
                                reframeToggleRow
                                blendFromSection
                                estimateCard
                                advancedRow
                            } else {
                                sourceCard
                                tailFrameBanner
                                stackCard
                            }

                            errorLine
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                    }
                }

                bottomBar
            }
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .onAppear {
            model.warpUndoManager = undoManager
            // Re-editing a clip that already has a track lands here with the
            // lane open, as does the LL_REFRAME hook; otherwise the lane is
            // opened from its own row (`reframeToggleRow`).
            if model.reframeLaneFocused || !(model.reframe?.isEmpty ?? true) {
                reframeLaneOpen = true
            }
        }
        // Scrubbing away from an uncommitted framing drops it — the draft
        // belongs to the moment it was shaped at.
        .onChange(of: playhead) { _ in reframeDraft = nil }
        .task(id: model.currentCaptureID) {
            blendCodecs = model.currentCapture.map { model.availableBlendCodecs(for: $0) } ?? []
        }
        .sheet(isPresented: $showAdvanced) {
            AdvancedOptionsSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $showCustomSpeed) {
            CustomSpeedSheet(stretch: selectedStretch)
                .environmentObject(model)
        }
    }

    /// iPad / Mac / iPhone landscape: the timeline beside the preview, per the
    /// design handoff — the playhead frame becomes a proper preview pane.
    private var wideLayout: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    warpCard(inlineThumbnail: false)
                    chipsRow
                    reframeToggleRow
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 14) {
                    if reframeLaneOpen {
                        ReframeCanvasView(
                            preview: preview,
                            playhead: $playhead,
                            selectedKey: $selectedReframeKey,
                            draft: $reframeDraft,
                            tallHeight: 340)
                    } else {
                        widePreviewPane
                    }
                    estimateCard
                }
                .frame(width: 320)
            }
            blendFromSection
            advancedRow
            errorLine
        }
    }

    /// The preview pane at the chosen canvas — tall canvases pin to a fixed
    /// height, centred, like the portrait layout's scrub preview.
    ///
    /// Hit-testing OFF for the same reason as the portrait pane: the
    /// aspect-fill image spills past the clipped box on the mismatched axis,
    /// and that invisible spill swallows taps from neighbouring controls.
    private var widePreviewPane: some View {
        let aspect = model.effectiveBlendCanvas().aspect
        return Group {
            if aspect < 1 {
                widePreviewBox(aspect: aspect)
                    .frame(height: 340)
                    .frame(maxWidth: .infinity)
            } else {
                widePreviewBox(aspect: aspect)
                    .frame(maxWidth: .infinity)
            }
        }
        .allowsHitTesting(false)
    }

    private func widePreviewBox(aspect: Double) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black)
            .aspectRatio(CGFloat(aspect), contentMode: .fit)
            .overlay {
                if let image = preview.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                Text("≈ keyframe preview")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(8)
            }
    }

    @ViewBuilder private var errorLine: some View {
        if let error = model.errorMessage {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .llCard()
        }
    }

    // MARK: - Canvas

    /// The clip's canvas, folded into the header as a compact select — the
    /// collapsed control shows only the ratio; the menu carries the "as shot"
    /// and crop consequences the old caption line spelled out. Defaults to
    /// the shape the source was shot at, rotation included; picking another
    /// centre-crops the preview and the created clip.
    private var canvasMenu: some View {
        Menu {
            ForEach(CanvasRatio.allCases) { ratio in
                Button {
                    model.blendCanvasRatio = ratio
                } label: {
                    if ratio == model.effectiveBlendCanvas() {
                        Label(canvasChoiceLabel(ratio), systemImage: "checkmark")
                    } else {
                        Text(canvasChoiceLabel(ratio))
                    }
                }
            }
            // A crop the guided builder repositioned round-trips into this
            // editor; without a way to see it, a moved crop would be invisible
            // state that only the render reveals. Hidden once a reframe track
            // exists: the offset is baked into the track's wide keys and the
            // canvas pass doesn't run under a reframe, so the reset would be
            // a render no-op pretending otherwise.
            if abs(model.blendCanvasOffset - 0.5) > 0.005,
               model.reframe?.isEmpty ?? true {
                Divider()
                Button("Recentre crop") { model.blendCanvasOffset = 0.5 }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.effectiveBlendCanvas().rawValue)
                    .font(.system(size: 13.5, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(LL.accent)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(LL.cardBackground, in: Capsule())
            .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Canvas \(model.effectiveBlendCanvas().rawValue)")
    }

    /// "9:16 — as shot" / "1:1 — crops to 608×608": the menu rows carry the
    /// consequence so the collapsed chip can stay terse.
    private func canvasChoiceLabel(_ ratio: CanvasRatio) -> String {
        guard let size = model.sourceDisplaySize() else { return ratio.rawValue }
        if let crop = VideoCanvasCropper.cropSize(displaySize: size, canvas: ratio) {
            return "\(ratio.rawValue) — crops to \(Int(crop.width))×\(Int(crop.height))"
        }
        return "\(ratio.rawValue) — as shot"
    }

    // MARK: - Source

    private var sourceCard: some View {
        HStack(spacing: 12) {
            ProjectThumbnailView(
                url: model.currentCapture.flatMap { model.mediaURL(for: $0) },
                kind: model.currentCapture.map { model.mediaKind(for: $0) } ?? .video
            )
            .frame(width: 64, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentCapture?.displayTitle ?? "Source")
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)
                sourceSubtitle
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer()
            Button("Change") {
                model.reset()
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(LL.accent)
            .buttonStyle(.plain)
        }
        .padding(12)
        .llCard()
    }

    private var sourceDetailLine: String {
        guard let capture = model.currentCapture else { return "—" }
        var parts: [String] = []
        if let duration = capture.sourceDurationSeconds {
            parts.append(DurationFormatter.recordingTime(from: duration) + " min")
        }
        parts.append(capture.formatLine)
        parts.append("shot \(capture.createdAt.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: " · ")
    }

    /// "08:16 · 1080p · 30 fps · 2 moments" for a shoot with recorded
    /// structure, "20:00 · 4K · 120 fps · continuous" for one take — the
    /// design's exact shapes; the accent chunk replaces the Video/shot-date
    /// tokens so the line fits.
    private var sourceSubtitle: some View {
        guard model.source?.isVideo == true, let capture = model.currentCapture else {
            return Text(sourceDetailLine).foregroundColor(.secondary)
        }
        let moments = model.blendStretches().momentCount
        var parts: [String] = []
        if let duration = capture.sourceDurationSeconds {
            parts.append(DurationFormatter.recordingTime(from: duration))
        }
        if let width = capture.sourceWidth, let height = capture.sourceHeight {
            parts.append(AppModel.CaptureProject.resolutionLabel(width: width, height: height))
        }
        if let fps = capture.sourceFPS {
            parts.append("\(Int(fps.rounded())) fps")
        }
        let tail = moments > 0 ? " · \(moments) \(moments == 1 ? "moment" : "moments")" : " · continuous"
        return Text(parts.joined(separator: " · ")).foregroundColor(.secondary)
            + Text(tail)
                .foregroundColor(LL.accentDeep)
                .fontWeight(.semibold)
    }

    // MARK: - Warp timeline

    private func warpCard(inlineThumbnail: Bool) -> some View {
        WarpTimelineView(
            selectedStretch: $selectedStretch,
            preview: preview,
            showsInlineThumbnail: inlineThumbnail,
            showsReframeLane: reframeLaneOpen,
            playhead: $playhead,
            playheadPlaced: $playheadPlaced,
            selectedReframeKey: $selectedReframeKey,
            reframeDraft: $reframeDraft
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .llCard()
    }

    /// The lane's disclosure — the second entry point's landing spot, and the
    /// only switch. Closing it hides the lane; the track itself stays.
    private var reframeToggleRow: some View {
        let track = model.activeReframe()
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { reframeLaneOpen.toggle() }
        } label: {
            HStack {
                Image(systemName: "viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LL.accent)
                Text("Punch-in reframe")
                    .font(.system(size: 15.5))
                    .foregroundStyle(.primary)
                Spacer()
                Text(track.isEmpty
                    ? "Off"
                    : "\(track.keys.count) \(track.keys.count == 1 ? "key" : "keys")")
                    .font(.system(size: 12))
                    .foregroundStyle(track.isEmpty ? .secondary : LL.accentDeep)
                Image(systemName: reframeLaneOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .llCard()
        .accessibilityLabel(
            "Punch-in reframe, \(reframeLaneOpen ? "expanded" : "collapsed")")
    }

    /// Speed chips always edit the selected stretch — there is no separate
    /// "base" any more.
    private var chipsRow: some View {
        let timeline = model.activeWarp()
        let index = min(selectedStretch, max(0, timeline.stretchCount - 1))
        let current = timeline.speeds.indices.contains(index) ? timeline.speeds[index] : 1
        let chips = speedChips(forStretchFPS: model.warpStretchFPS(index))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.speed) { chip in
                    let active = abs(current - chip.speed) < 0.001
                    Button {
                        model.updateWarp { $0.setSpeed(chip.speed, for: index) }
                    } label: {
                        VStack(spacing: 1) {
                            Text(WarpTimeline.speedLabel(chip.speed))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(active ? LL.amber : .primary)
                            Text(chip.word)
                                .font(.system(size: 9.5))
                                .foregroundStyle(active ? Color.white.opacity(0.6) : Color.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            active ? LL.ink : LL.cardBackground,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(active ? 0 : 0.05), radius: 1.5, y: 1)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    showCustomSpeed = true
                } label: {
                    VStack(spacing: 1) {
                        Text("···")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                        Text("custom")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Text("Every stretch is speedable — no separate \u{201C}base\u{201D}. Hold a stretch for Remove · Split · Reset.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            if model.useRamp {
                Text("Speed ramp \(model.rampStart)×→\(model.rampEnd)× is on — editing the timeline turns it off. Edit it in Advanced."
                    + (model.reframe?.isEmpty == false
                        ? " The punch-in reframe won't render while the ramp is on."
                        : ""))
                    .font(.system(size: 11.5))
                    .foregroundStyle(LL.accent)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Blend from (source codec)

    /// Shown only when a clip has been converted, so there's a real choice of
    /// which encoding feeds the blend — the ProRes-vs-H.264 quality test.
    @ViewBuilder private var blendFromSection: some View {
        if model.source?.isVideo == true, !blendCodecs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                LLSectionHeader("Blend from")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        codecChip(nil, "Auto")
                        ForEach(blendCodecs, id: \.self) { codec in
                            codecChip(codec, codecLabel(codec))
                        }
                    }
                }
                Text(blendFromHint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func codecChip(_ codec: OutputCodec?, _ label: String) -> some View {
        let selected = model.blendSourceCodec == codec
        return Button {
            model.setBlendSourceCodec(codec)
        } label: {
            Text(label)
                .font(.system(size: 13, weight: selected ? .bold : .regular))
                .foregroundStyle(selected ? .black : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? LL.accent : Color.secondary.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func codecLabel(_ codec: OutputCodec) -> String {
        switch codec {
        case .prores: return "ProRes"
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        case .jpeg: return "JPEG"
        }
    }

    private var blendFromHint: String {
        switch model.blendSourceCodec {
        case nil: return "Uses the best surviving copy of each clip."
        case .prores?: return "Blends from ProRes originals where available."
        case .hevc?: return "Blends from HEVC where available, else the best copy."
        case .h264?: return "Blends from H.264 where available, else the best copy."
        case .jpeg?: return "Blends from JPEG where available, else the best copy."
        }
    }

    // MARK: - Estimate

    private var estimateCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your clip will be")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Menu {
                    ForEach([24, 25, 30, 50, 60], id: \.self) { fps in
                        Button {
                            model.outputFPS = fps
                        } label: {
                            if fps == model.outputFPS {
                                Label("\(fps) fps", systemImage: "checkmark")
                            } else {
                                Text("\(fps) fps")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("\(model.outputFPS) fps")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(estimateHeadline)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text(estimatePhrase)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LL.amber)
            }
            .padding(.top, 2)
            .padding(.bottom, 10)

            if let sourceSeconds = model.currentCapture?.sourceDurationSeconds,
               let outputSeconds = model.estimatedOutputSeconds(), sourceSeconds > 0 {
                BeforeAfterBar(
                    sourceLabel: DurationFormatter.recordingTime(from: sourceSeconds),
                    outputLabel: SpeedMath.clipLengthCompact(outputSeconds),
                    ratio: outputSeconds / sourceSeconds
                )
                .padding(.bottom, 8)
            }

            Text(blurExplainer)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var estimatePhrase: String {
        if model.useRamp {
            return "· \(model.rampStart)×→\(model.rampEnd)× ramp"
        }
        let timeline = model.activeWarp()
        if timeline.stretchCount > 1 {
            return "· \(timeline.stretchCount) stretches"
        }
        let speed = timeline.speeds.first ?? Double(model.constantWindow)
        return "· \(WarpTimeline.speedWord(speed))"
    }

    private var estimateHeadline: String {
        guard let seconds = model.estimatedOutputSeconds() else { return "— seconds" }
        let approx = model.useRamp ? "≈ " : ""
        if seconds < 9.95 {
            return approx + String(format: "%.1f seconds", seconds)
        }
        return approx + SpeedMath.clipLength(seconds)
    }

    private var blurExplainer: String {
        if model.useRamp {
            return "The window ramps from \(model.rampStart) to \(model.rampEnd) frames per output frame across the clip."
        }
        return "Time-warp, never a trim — every source frame lands in the clip; blur follows speed through each ease."
    }

    // MARK: - Tail-frame review

    /// Quiet, non-blocking prompt: the interval shoot ended on a run of shaky
    /// frames (usually the phone-grab that stopped it). Excluding drops them
    /// from the blend; the originals stay on disk either way.
    @ViewBuilder private var tailFrameBanner: some View {
        if model.tailFramesToExclude > 0 {
            TailFrameBanner(
                count: model.tailFramesToExclude,
                onExclude: {
                    let start = model.totalIntervalFrames - model.tailFramesToExclude
                    model.excludedFrameIndices = Set(start..<model.totalIntervalFrames)
                    model.tailFramesToExclude = 0
                },
                onKeep: { model.tailFramesToExclude = 0 }
            )
        }
    }

    // MARK: - Photos stack

    private var stackCard: some View {
        let photoCount = model.currentCapture?.sourceMediaCount ?? 0
        let frameCount = model.photoOutputFrameCount ?? 0
        let depth = model.photoBlendDepth
        let singleImage = model.photosProduceSingleImage
        let noBlend = depth <= 1
        return VStack(alignment: .leading, spacing: 12) {
            Text(stackTitle(singleImage: singleImage, noBlend: noBlend))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            Text(stackBlurb(photoCount: photoCount, depth: depth, singleImage: singleImage, noBlend: noBlend))
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.6))

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Blend depth")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(depthLabel(photoCount: photoCount, depth: depth, singleImage: singleImage, noBlend: noBlend))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LL.amber)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.photoBlendDepth) },
                        set: { model.photoBlendDepth = max(1, Int($0.rounded())) }
                    ),
                    in: 1...Double(max(2, photoCount)),
                    step: 1
                )
                .tint(LL.amber)
                HStack {
                    Text("Crisp")
                    Spacer()
                    Text("Long exposure")
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.top, 4)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if singleImage {
                    Text("\(photoCount) photos → one still")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(photoCount) photos → \(frameCount) frames")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("· \(String(format: "%.1fs", Double(frameCount) / Double(max(1, model.outputFPS)))) at \(model.outputFPS) fps")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            Toggle(isOn: $model.linearLight) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("True-light blending")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                    Text("Blends in linear light — smoother highlights")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .tint(.green)
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func stackTitle(singleImage: Bool, noBlend: Bool) -> String {
        if singleImage { return "One long exposure" }
        if noBlend { return "A crisp timelapse" }
        return "A blended timelapse"
    }

    private func stackBlurb(photoCount: Int, depth: Int, singleImage: Bool, noBlend: Bool) -> String {
        if singleImage {
            return "All \(photoCount) photos blend into a single silky still — the classic stacked long exposure, with noise dropping by roughly the square root of the frame count."
        }
        if noBlend {
            return "Your \(photoCount) photos play back in order, one per frame — a straight timelapse with no blur."
        }
        return "Every \(depth) photos average into one frame — a rolling long exposure that carries motion blur through the whole sequence."
    }

    private func depthLabel(photoCount: Int, depth: Int, singleImage: Bool, noBlend: Bool) -> String {
        if singleImage { return "all \(photoCount) → one still" }
        if noBlend { return "no blend" }
        return "\(depth) photos → 1 frame"
    }

    // MARK: - Advanced

    private var advancedRow: some View {
        Button {
            showAdvanced = true
        } label: {
            HStack {
                Text("Advanced")
                    .font(.system(size: 15.5))
                    .foregroundStyle(.primary)
                Spacer()
                Text(advancedSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .llCard()
    }

    private var advancedSummary: String {
        var active: [String] = []
        if model.useRamp { active.append("Ramp on") }
        if model.trimVideoEnds { active.append("Trim on") }
        if model.linearLight { active.append("True-light") }
        return active.isEmpty ? "Ramp · Trim · True-light" : active.joined(separator: " · ")
    }

    // MARK: - CTA

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.startProcessing()
                } label: {
                    Text(ctaTitle)
                }
                .buttonStyle(LLPrimaryButtonStyle())

                // The pro option lives behind the carat: one tap creates in
                // the distribution default, the menu offers the other format
                // for this run. Settings picks which is the default.
                Menu {
                    Button {
                        model.startProcessing(blendProfile: .h264High8Bit)
                    } label: {
                        Label("H.264 · widely compatible", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        model.startProcessing(blendProfile: .hevcMain10)
                    } label: {
                        Label("10-bit HEVC · highest quality", systemImage: "sparkles")
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(LL.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text("Your original is kept — you can always make another blended clip.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(LL.screenBackground)
    }

    /// A Scanner capture is a **set of angles**, not a sequence: it exists to
    /// be handed to a photogrammetry solver or a compositing stack, and the
    /// order the frames happen to be in carries no time. Reading it off the
    /// capture's own mode string keeps the intent with the project rather than
    /// asking the user to re-declare it here.
    private var isScannerCapture: Bool {
        model.currentCapture?.mode.contains("Scanner") == true
    }

    private var ctaTitle: String {
        if model.source?.isVideo == true {
            if let seconds = model.estimatedOutputSeconds() {
                return "Create \(SpeedMath.clipLength(seconds)) clip"
            }
            return "Create clip"
        }
        // TODO (Scanner): this label still lies — it states the intent and then
        // routes into the blend. The export it names now exists and is wired up
        // one screen along, in `App/ScannerProjectView.swift`
        // (`ScannerFrameExport.buildFolder` → the share sheet, corrected pages
        // where they have been written), reached from the project rather than
        // from here. Point this button at the same call, or drop the Scanner
        // case entirely and let Adjust mean what it means everywhere else —
        // "Create timelapse" is already the honest label for what it does.
        if isScannerCapture {
            let count = model.currentCapture?.sourceMediaCount ?? 0
            return count > 0 ? "Export \(count) frames" : "Export frames"
        }
        if model.photosProduceSingleImage {
            return "Create long exposure"
        }
        if let frames = model.photoOutputFrameCount {
            return "Create \(frames)-frame timelapse"
        }
        return "Create timelapse"
    }
}

// MARK: - Tail-frame banner

/// A compact, dismissible prompt — not a sheet or alert. Sits above the stack
/// card and offers to drop the shaky frames that ended the shoot, or keep them.
private struct TailFrameBanner: View {
    var count: Int
    var onExclude: () -> Void
    var onKeep: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LL.amber)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(count) shaky \(count == 1 ? "frame" : "frames") at the end")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Looks like a phone-grab as you stopped — drop them?")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 8)

            Button("Keep", action: onKeep)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)

            Button(action: onExclude) {
                Text("Exclude")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(LL.amber, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .llCard()
    }
}

// MARK: - Before/after bar

/// A proportional "3:45 → 2.2s" bar: the source as a long track, the output
/// as the sliver it becomes.
struct BeforeAfterBar: View {
    var sourceLabel: String
    var outputLabel: String
    var ratio: Double

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(Color(white: 0.24))
                .frame(height: 8)
                .frame(maxWidth: .infinity)
            Text(sourceLabel)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize()
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
            Capsule()
                .fill(LL.amber)
                .frame(width: max(8, min(48, 160 * ratio)), height: 8)
            Text(outputLabel)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(LL.amber)
                .fixedSize()
        }
        .frame(height: 14)
    }
}

// MARK: - Advanced sheet

struct AdvancedOptionsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Ramp the speed across the clip", isOn: $model.useRamp)
                    if model.useRamp {
                        Stepper("Start: \(model.rampStart)×", value: $model.rampStart, in: SpeedMath.range)
                        Stepper("End: \(model.rampEnd)×", value: $model.rampEnd, in: SpeedMath.range)
                        Picker("Curve", selection: $model.curve) {
                            ForEach(BlendCurve.allCases, id: \.self) { curve in
                                Text(curve.rawValue).tag(curve)
                            }
                        }
                    }
                } header: {
                    Text("Speed ramp")
                } footer: {
                    Text("The blend window moves between two speeds over the length of the clip. The warp timeline takes over as soon as you edit it.")
                }

                Section {
                    Toggle("Trim video ends", isOn: $model.trimVideoEnds)
                    if model.trimVideoEnds {
                        Stepper(
                            "Cut \(model.trimHeadTailSeconds, specifier: "%.1f")s from start and end",
                            value: $model.trimHeadTailSeconds,
                            in: 0.1...30,
                            step: 0.5
                        )
                    }
                } header: {
                    Text("Trim")
                } footer: {
                    Text("Removes the same duration from the beginning and end before blending.")
                }

                Section {
                    Toggle(isOn: $model.linearLight) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("True-light blending")
                            Text("Blends in linear light — smoother highlights")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Blending")
                }
            }
            .navigationTitle("Advanced")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }
}

// MARK: - Custom speed sheet

/// Free speed values for the selected stretch — anything the chips don't
/// offer, 1×–240×. Slow motion below 1× stays on the ¼× chip.
struct CustomSpeedSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var stretch: Int = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Speed: \(customSpeed.wrappedValue)×", value: customSpeed, in: SpeedMath.range)
                    Slider(
                        value: Binding(
                            get: { Double(customSpeed.wrappedValue) },
                            set: { customSpeed.wrappedValue = Int($0.rounded()) }
                        ),
                        in: Double(SpeedMath.range.lowerBound)...Double(SpeedMath.range.upperBound),
                        step: 1
                    )
                } header: {
                    if model.activeWarp().stretchCount > 1 {
                        Text("Stretch \(min(stretch, model.activeWarp().stretchCount - 1) + 1)")
                    }
                } footer: {
                    Text("\(customSpeed.wrappedValue)× real time\(estimateSuffix).")
                }
            }
            .navigationTitle("Custom speed")
            .onDisappear { model.endWarpCoalescing() }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    private var customSpeed: Binding<Int> {
        Binding {
            let timeline = model.activeWarp()
            let index = min(stretch, max(0, timeline.stretchCount - 1))
            let speed = timeline.speeds.indices.contains(index) ? timeline.speeds[index] : 1
            return max(1, Int(speed.rounded()))
        } set: { newValue in
            let index = min(stretch, max(0, model.activeWarp().stretchCount - 1))
            // One undo step per visit to the sheet's slider/stepper, not one
            // per tick.
            model.updateWarp(coalescing: "speed-\(index)") { $0.setSpeed(Double(newValue), for: index) }
        }
    }

    private var estimateSuffix: String {
        guard let seconds = model.estimatedOutputSeconds() else { return "" }
        return " — the clip lands at about \(SpeedMath.clipLength(seconds))"
    }
}
