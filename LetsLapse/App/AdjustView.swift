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
    /// The "+ Field note" flow, attached to the capture this screen is
    /// configuring — same component as the project screen's entry point.
    @State private var showFieldNoteFlow = false
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
            let isWide = proxy.size.width > 560
            VStack(spacing: 0) {
                FlowHeader(title: "New blended clip", onBack: { model.reset() }) {
                    if model.source?.isVideo == true {
                        canvasMenu
                    }
                }

                ScrollView {
                    if isWide {
                        Group {
                            if model.source?.isVideo == true {
                                wideLayout
                            } else {
                                wideStillsLayout
                            }
                        }
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
                                timeSlicingSection
                            } else {
                                tailFrameBanner
                                // One output photo has no schedule to edit —
                                // the whole-shoot stack takes the timeline's
                                // place entirely.
                                if !model.photosProduceSingleImage {
                                    warpCard(inlineThumbnail: true)
                                }
                                depthCard
                                estimateCard
                                advancedRow
                                timeSlicingSection
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
            timeSlicingSection
            errorLine
        }
    }

    /// iPad / Mac / iPhone landscape for an interval shoot: the timeline
    /// beside the preview, same shell as the video layout — minus the lanes
    /// stills don't have yet (reframe and canvas are phase 3 of the
    /// unification; Blend-from codecs are video-only).
    private var wideStillsLayout: some View {
        VStack(spacing: 14) {
            tailFrameBanner
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    if !model.photosProduceSingleImage {
                        warpCard(inlineThumbnail: false)
                    }
                    depthCard
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 14) {
                    widePreviewPane
                    estimateCard
                }
                .frame(width: 320)
            }
            advancedRow
            timeSlicingSection
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
    /// "base" any more. A movie's chips are ×-real-time speeds gated by its
    /// footage; an interval shoot's depths live in `depthCard`.
    private var chipsRow: some View {
        let timeline = model.activeWarp()
        let index = min(selectedStretch, max(0, timeline.stretchCount - 1))
        let current = timeline.speeds.indices.contains(index) ? timeline.speeds[index] : 1
        let chips: [(speed: Double, label: String, word: String)] =
            speedChips(forStretchFPS: model.warpStretchFPS(index)).map {
                ($0.speed, WarpTimeline.speedLabel($0.speed), $0.word)
            }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.speed) { chip in
                    let active = abs(current - chip.speed) < 0.001
                    Button {
                        model.updateWarp { $0.setSpeed(chip.speed, for: index) }
                    } label: {
                        VStack(spacing: 1) {
                            Text(chip.label)
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

            // The stills accounting the old stack card carried: what the
            // photos become.
            if model.source?.isVideo != true {
                Text(model.photosProduceSingleImage
                    ? "\(model.currentCapture?.sourceMediaCount ?? 0) photos → one still"
                    : "\(model.currentCapture?.sourceMediaCount ?? 0) photos → \(model.photoOutputFrameCount ?? 0) frames")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 8)
            }

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
        let isVideo = model.source?.isVideo == true
        if isVideo, model.useRamp {
            return "· \(model.rampStart)×→\(model.rampEnd)× ramp"
        }
        if !isVideo, model.photosProduceSingleImage {
            return "· long exposure"
        }
        let timeline = model.activeWarp()
        if timeline.stretchCount > 1 {
            return "· \(timeline.stretchCount) stretches"
        }
        if !isVideo {
            return "· \(WarpTimeline.depthLabel(timeline.speeds.first ?? Double(model.photoBlendDepth)))"
        }
        let speed = timeline.speeds.first ?? Double(model.constantWindow)
        return "· \(WarpTimeline.speedWord(speed))"
    }

    private var estimateHeadline: String {
        if model.source?.isVideo != true, model.photosProduceSingleImage {
            return "One photo"
        }
        guard let seconds = model.estimatedOutputSeconds() else { return "— seconds" }
        let approx = model.source?.isVideo == true && model.useRamp ? "≈ " : ""
        if seconds < 9.95 {
            return approx + String(format: "%.1f seconds", seconds)
        }
        return approx + SpeedMath.clipLength(seconds)
    }

    private var blurExplainer: String {
        let isVideo = model.source?.isVideo == true
        if isVideo, model.useRamp {
            return "The window ramps from \(model.rampStart) to \(model.rampEnd) frames per output frame across the clip."
        }
        if !isVideo {
            if model.photosProduceSingleImage {
                let count = model.currentCapture?.sourceMediaCount ?? 0
                return "All \(count) photos blend into one still — the classic stacked long exposure, with noise dropping by roughly the square root of the frame count."
            }
            return "Never a trim — every photo lands in the clip. A stretch's depth is how many photos average into each frame: 1:1 keeps every photo as shot, deeper is a rolling long exposure."
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

    // MARK: - Blend depth (stills)

    /// The interval chip set: the depths the old BLEND slider's travel was
    /// really used for. Everything between and beyond — and the whole-shoot
    /// stack — lives behind the "···" chip's drawer (the 2026-09-02 design).
    private static let intervalDepthChips = [1, 2, 3, 5, 8]

    /// The "···" drawer's disclosure. Session-only: the drawer is a way of
    /// reaching values, not a value itself.
    @State private var depthDrawerOpen = false
    /// The depth the selected stretch had before "All frames → 1" folded the
    /// shoot, so switching back lands where the user was rather than at 1:1.
    @State private var depthBeforeStack: Int?

    private var selectedStretchIndex: Int {
        min(selectedStretch, max(0, model.activeWarp().stretchCount - 1))
    }

    /// The selected stretch's depth — photos per output frame.
    private var selectedStretchDepth: Int {
        let timeline = model.activeWarp()
        let index = selectedStretchIndex
        let speed = timeline.speeds.indices.contains(index) ? timeline.speeds[index] : 1
        return max(1, Int(speed.rounded()))
    }

    /// Depth chips and the "···" drawer, one card. The chips edit the
    /// selected stretch's depth — the whole-shoot BLEND slider absorbed into
    /// the timeline, one value per stretch. The drawer holds the whole-shoot
    /// stack (All frames → 1, the classic single long exposure, which takes
    /// the timeline's place entirely: one output photo has no schedule to
    /// edit) and a free Photos-per-frame value for anything the chips don't
    /// offer. No character words under the ratios — "2:1" says it.
    private var depthCard: some View {
        let photoCount = model.currentCapture?.sourceMediaCount ?? 0
        let stacked = model.photosProduceSingleImage
        let current = selectedStretchDepth
        let canonical = Self.intervalDepthChips.contains(current)
        // The "···" seat lights whenever the value lives behind it: the
        // drawer is open, the shoot is stacked, or the depth isn't a chip's.
        let customActive = depthDrawerOpen || stacked || !canonical
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Self.intervalDepthChips, id: \.self) { depth in
                    Button {
                        setDepth(depth)
                    } label: {
                        depthChip(WarpTimeline.depthLabel(Double(depth)),
                                  active: !customActive && depth == current)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(depth) photos per frame")
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { depthDrawerOpen.toggle() }
                    if !depthDrawerOpen { model.endWarpCoalescing() }
                } label: {
                    depthChip("···", active: customActive)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(depthDrawerOpen ? "Hide custom depth" : "Custom depth")
            }
            if depthDrawerOpen {
                Divider().padding(.top, 14)
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("All frames → 1")
                                .font(.system(size: 14.5))
                                .foregroundStyle(.primary)
                            Text("Stack every photo into a single still")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("All frames → 1", isOn: allFramesBinding)
                            .labelsHidden()
                    }
                    if !stacked {
                        HStack {
                            Text("Photos per frame").font(.system(size: 14))
                            Spacer()
                            LLStepControl(value: customDepthBinding,
                                          range: 2...max(2, photoCount - 1))
                        }
                    }
                }
                .padding(.top, 14)
            }
        }
        .padding(16)
        .llCard()
    }

    private func depthChip(_ label: String, active: Bool) -> some View {
        Text(label)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(active ? LL.amber : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                active ? LL.ink : LL.cardBackground,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(active ? 0 : 0.1), radius: 1.5, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// A chip closes the drawer and lifts the whole-shoot stack if it was on.
    private func setDepth(_ depth: Int) {
        withAnimation(.easeInOut(duration: 0.2)) { depthDrawerOpen = false }
        model.endWarpCoalescing()
        if model.photosProduceSingleImage { model.photoBlendDepth = depth }
        model.updateWarp { $0.setSpeed(Double(depth), for: selectedStretchIndex) }
    }

    private var customDepthBinding: Binding<Int> {
        Binding(
            get: { selectedStretchDepth },
            set: { depth in
                // One undo step per visit to the stepper, not one per tick.
                let index = selectedStretchIndex
                model.updateWarp(coalescing: "depth-\(index)") {
                    $0.setSpeed(Double(depth), for: index)
                }
            })
    }

    /// All frames → 1: the classic single long exposure. The baseline depth
    /// is the switch (`photosProduceSingleImage` reads it against the
    /// count); the timeline's own speeds are left alone so switching back
    /// finds every stretch where it was.
    private var allFramesBinding: Binding<Bool> {
        Binding(
            get: { model.photosProduceSingleImage },
            set: { on in
                let photoCount = model.currentCapture?.sourceMediaCount ?? 0
                withAnimation(.easeInOut(duration: 0.2)) {
                    if on {
                        depthBeforeStack = selectedStretchDepth
                        model.photoBlendDepth = max(2, photoCount)
                    } else {
                        model.photoBlendDepth = depthBeforeStack ?? 1
                    }
                }
            })
    }

    // MARK: - Time slicing

    /// Session stash: taking the count to 0 keeps the entered values for
    /// this session (docs/time-slicing.md §3.2 of the brief).
    @State private var timeSliceStash: TimeSliceSettings?
    @State private var timeSliceVariationStash: TimeSliceVariationPlan?
    /// "Custom" holds its seat while its stepper is in use, even when the
    /// value happens to land on a preset's number.
    @State private var timeSliceSegmentsCustom = false
    @State private var timeSliceSpreadCustom = false

    /// The header's count picker: 0 = off, 1 = one slice, 4 or 8 = a batch
    /// (docs/time-slicing.md §10). The 2026-09-02 design folds the old On/Off
    /// row and the separate Variations picker into this one control.
    private static let timeSliceCounts = [0, 1, 4, 8]

    /// Hidden only where slicing has nothing to slice — the whole-shoot
    /// single still. Video and interval sequences both offer it.
    private var timeSlicingAvailable: Bool {
        guard model.source != nil else { return false }
        if model.source?.isVideo != true, model.photosProduceSingleImage { return false }
        return true
    }

    @ViewBuilder private var timeSlicingSection: some View {
        if timeSlicingAvailable {
            VStack(alignment: .leading, spacing: 0) {
                timeSlicingHeaderRow
                if let settings = model.timeSlice {
                    Divider().padding(.top, 16)
                    timeSlicingControls(settings).padding(.top, 16)
                }
            }
            .padding(16)
            .llCard()
        }
    }

    /// Title + a one-line reading of the recipe, and the count picker. The
    /// subtitle truncates rather than wrapping: the picker keeps its width.
    private var timeSlicingHeaderRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Time slicing")
                    .font(.system(size: 15.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(timeSliceSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            LLInkSegment(
                options: Self.timeSliceCounts,
                label: { "\($0)" },
                selection: timeSliceCountBinding)
            .fixedSize()
            .accessibilityLabel("Time slicing takes")
        }
    }

    private var timeSliceSubtitle: String {
        guard let settings = model.timeSlice else {
            return "Bands of the frame show different moments"
        }
        if let plan = model.timeSliceVariations {
            return "\(plan.count) takes · \(plan.mode.label)"
        }
        if settings.grid != nil { return "Grid" }
        return settings.axis == .vertical ? "Vertical bands" : "Horizontal bands"
    }

    /// 0 = off (the recipe goes to the session stash), 1 = the single slice,
    /// more = a batch of that many takes from the one blend. Fresh arming
    /// seeds the lag from a 25% spread of THIS clip — the 2026-08-28 review
    /// finding: an absolute frame default collapses to seams on a long shoot.
    private var timeSliceCountBinding: Binding<Int> {
        Binding(
            get: { model.timeSlice == nil ? 0 : (model.timeSliceVariations?.count ?? 1) },
            set: { count in
                withAnimation(.easeInOut(duration: 0.2)) {
                    guard count > 0 else {
                        timeSliceStash = model.timeSlice
                        timeSliceVariationStash = model.timeSliceVariations
                        model.timeSlice = nil
                        model.timeSliceVariations = nil
                        return
                    }
                    if model.timeSlice == nil {
                        model.timeSlice = timeSliceStash ?? seededTimeSlice()
                    }
                    if count == 1 {
                        if let plan = model.timeSliceVariations { timeSliceVariationStash = plan }
                        model.timeSliceVariations = nil
                    } else {
                        var plan = model.timeSliceVariations ?? timeSliceVariationStash
                            ?? TimeSliceVariationPlan()
                        plan.count = count
                        model.timeSliceVariations = plan
                    }
                }
            })
    }

    @ViewBuilder private func timeSlicingControls(_ settings: TimeSliceSettings) -> some View {
        let plan = model.timeSliceVariations
        let shape = timeSliceShape(settings, plan: plan)
        VStack(alignment: .leading, spacing: 16) {
            timeSliceGroup("Shape") {
                Picker("Shape", selection: timeSliceShapeBinding) {
                    Text("Vertical").tag(TimeSliceShape.vertical)
                    Text("Horizontal").tag(TimeSliceShape.horizontal)
                    Text("Grid").tag(TimeSliceShape.grid)
                    if plan != nil {
                        Text("Mixed").tag(TimeSliceShape.mixed)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            switch shape {
            case .vertical, .horizontal:
                // Reading order: the first band holds the earliest moment
                // (the 2026-08-28 review's convention, both output modes).
                timeSliceGroup("Time starts") {
                    Picker("Time starts", selection: timeSliceStartBinding) {
                        if shape == .vertical {
                            Text("Left").tag(TimeSliceStart.edge(.left))
                            Text("Right").tag(TimeSliceStart.edge(.right))
                        } else {
                            Text("Top").tag(TimeSliceStart.edge(.top))
                            Text("Bottom").tag(TimeSliceStart.edge(.bottom))
                        }
                        if plan != nil {
                            Text("Mixed").tag(TimeSliceStart.mixed)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            case .grid:
                timeSliceGroup("Sweeps from") {
                    timeSliceCornerGrid(settings)
                }
            case .mixed:
                EmptyView()
            }
            timeSliceGroup("Segments") {
                Picker("Segments", selection: timeSliceSegmentsBinding) {
                    Text("Fine").tag(TimeSliceSegmentsChoice.fine)
                    Text("Medium").tag(TimeSliceSegmentsChoice.medium)
                    Text("Bold").tag(TimeSliceSegmentsChoice.bold)
                    if plan != nil {
                        Text("Mixed").tag(TimeSliceSegmentsChoice.mixed)
                    }
                    Text("Custom").tag(TimeSliceSegmentsChoice.custom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if timeSliceSegmentsBinding.wrappedValue == .custom {
                    timeSliceStepperRow(
                        settings.grid == nil ? "Bands" : "Columns",
                        value: timeSliceBinding(\.segments),
                        range: 4...(settings.grid == nil ? 64 : TimeSliceGridGeometry.maximumColumns),
                        step: 2)
                }
            }
            timeSliceGroup("Output") {
                Picker("Output", selection: timeSliceBinding(\.output)) {
                    Text("Image").tag(TimeSliceOutput.image)
                    Text("Animation").tag(TimeSliceOutput.animation)
                    Text("Both").tag(TimeSliceOutput.both)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            // The poster spreads the whole shoot regardless, so the spread
            // only means anything once an animation is being kept.
            if settings.output != .image {
                timeSliceGroup("Spread") {
                    if timeSliceMasterFrames != nil {
                        Picker("Spread", selection: timeSliceSpreadBinding) {
                            Text("Tight").tag(TimeSliceSpreadChoice.tight)
                            Text("Medium").tag(TimeSliceSpreadChoice.medium)
                            Text("Wide").tag(TimeSliceSpreadChoice.wide)
                            Text("Custom").tag(TimeSliceSpreadChoice.custom)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if timeSliceSpreadBinding.wrappedValue == .custom {
                            timeSliceStepperRow(
                                "Percent", value: timeSliceSpreadPercentBinding,
                                range: 10...85, step: 5, suffix: "%")
                        }
                    } else {
                        // The clip's length isn't known yet, so a share of it
                        // can't be — the raw lag per band stands in.
                        timeSliceStepperRow(
                            "Frames per band", value: timeSliceBinding(\.offsetFrames),
                            range: 1...120, step: 1)
                    }
                }
            }
            Toggle(isOn: timeSliceBinding(\.includeRegularClip)) {
                Text("Include regular timelapse").font(.system(size: 14))
            }
            timeSliceReadout(settings)
        }
    }

    /// Label above, control below, full width — the shape every row of the
    /// card takes now that four-seat pickers need the whole 329pt.
    private func timeSliceGroup<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14))
            content()
        }
    }

    private func timeSliceStepperRow(
        _ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int,
        suffix: String = ""
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Spacer()
            LLStepControl(value: value, range: range, step: step, suffix: suffix)
        }
        .padding(.top, 2)
    }

    /// The grid's origin corner — the cell holding the newest moment — as a
    /// 2×2 of chips in the corners' own arrangement.
    private func timeSliceCornerGrid(_ settings: TimeSliceSettings) -> some View {
        let current = settings.grid?.origin ?? .topLeft
        let rows: [[TimeSliceGridOrigin]] = [[.topLeft, .topRight], [.bottomLeft, .bottomRight]]
        return VStack(spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { corner in
                        let active = corner == current
                        Button {
                            timeSliceGridOriginBinding.wrappedValue = corner
                        } label: {
                            Text(corner.label)
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(active ? LL.amber : .primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    active ? LL.ink : LL.cardBackground,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: .black.opacity(active ? 0 : 0.1), radius: 1.5, y: 1)
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
            }
        }
    }

    // MARK: Bindings

    private func timeSliceBinding<T>(_ keyPath: WritableKeyPath<TimeSliceSettings, T>) -> Binding<T> {
        Binding(
            get: { (model.timeSlice ?? TimeSliceSettings())[keyPath: keyPath] },
            set: { value in
                var settings = model.timeSlice ?? TimeSliceSettings()
                settings[keyPath: keyPath] = value
                model.timeSlice = settings
            })
    }

    private func timeSliceShape(_ settings: TimeSliceSettings, plan: TimeSliceVariationPlan?) -> TimeSliceShape {
        if let plan {
            switch plan.mode {
            case .vertical: return .vertical
            case .horizontal: return .horizontal
            case .grid: return .grid
            case .mixed: return .mixed
            }
        }
        if settings.grid != nil { return .grid }
        return settings.axis == .vertical ? .vertical : .horizontal
    }

    /// Shape edits the baseline recipe AND, for a batch, the mode — so the
    /// Time-starts seats always belong to the axis the batch is on. A grid
    /// batch pins its corner (the corner picker has no Mixed seat).
    private var timeSliceShapeBinding: Binding<TimeSliceShape> {
        Binding(
            get: { timeSliceShape(model.timeSlice ?? TimeSliceSettings(), plan: model.timeSliceVariations) },
            set: { shape in
                var settings = model.timeSlice ?? TimeSliceSettings()
                switch shape {
                case .vertical:
                    settings.grid = nil
                    settings.newestEdge = Self.edge(settings.newestEdge, on: .vertical)
                case .horizontal:
                    settings.grid = nil
                    settings.newestEdge = Self.edge(settings.newestEdge, on: .horizontal)
                case .grid:
                    if settings.grid == nil {
                        settings.grid = TimeSliceGrid(origin: .topLeft, metric: .manhattan)
                    }
                case .mixed:
                    break
                }
                model.timeSlice = settings
                if var plan = model.timeSliceVariations {
                    switch shape {
                    case .vertical: plan.mode = .vertical
                    case .horizontal: plan.mode = .horizontal
                    case .grid:
                        plan.mode = .grid
                        plan.lockOrigin = true
                    case .mixed: plan.mode = .mixed
                    }
                    model.timeSliceVariations = plan
                }
            })
    }

    /// The axis flip preserves which end holds the newest band: left↔top,
    /// right↔bottom.
    private static func edge(_ edge: TimeSliceEdge, on axis: TimeSliceAxis) -> TimeSliceEdge {
        switch (edge, axis) {
        case (.top, .vertical): return .left
        case (.bottom, .vertical): return .right
        case (.left, .horizontal): return .top
        case (.right, .horizontal): return .bottom
        default: return edge
        }
    }

    /// The UI speaks reading order (where time STARTS); the model stores the
    /// newest edge. They are opposite ends of the same axis.
    private static func opposite(_ edge: TimeSliceEdge) -> TimeSliceEdge {
        switch edge {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    private var timeSliceStartBinding: Binding<TimeSliceStart> {
        Binding(
            get: {
                if let plan = model.timeSliceVariations, !plan.lockEdge { return .mixed }
                return .edge(Self.opposite((model.timeSlice ?? TimeSliceSettings()).newestEdge))
            },
            set: { start in
                switch start {
                case .mixed:
                    if var plan = model.timeSliceVariations {
                        plan.lockEdge = false
                        model.timeSliceVariations = plan
                    }
                case .edge(let earliest):
                    var settings = model.timeSlice ?? TimeSliceSettings()
                    settings.newestEdge = Self.opposite(earliest)
                    model.timeSlice = settings
                    if var plan = model.timeSliceVariations {
                        plan.lockEdge = true
                        model.timeSliceVariations = plan
                    }
                }
            })
    }

    private var timeSliceGridOriginBinding: Binding<TimeSliceGridOrigin> {
        Binding(
            get: { model.timeSlice?.grid?.origin ?? .topLeft },
            set: { origin in
                var settings = model.timeSlice ?? TimeSliceSettings()
                settings.grid = TimeSliceGrid(
                    origin: origin, metric: settings.grid?.metric ?? .manhattan)
                model.timeSlice = settings
                if var plan = model.timeSliceVariations {
                    plan.lockOrigin = true
                    model.timeSliceVariations = plan
                }
            })
    }

    private var timeSliceSegmentsBinding: Binding<TimeSliceSegmentsChoice> {
        Binding(
            get: {
                if let plan = model.timeSliceVariations, !plan.lockSegments { return .mixed }
                if timeSliceSegmentsCustom { return .custom }
                let segments = (model.timeSlice ?? TimeSliceSettings()).segments
                return TimeSliceSegmentsChoice.allCases.first { $0.count == segments } ?? .custom
            },
            set: { choice in
                var settings = model.timeSlice ?? TimeSliceSettings()
                var plan = model.timeSliceVariations
                switch choice {
                case .mixed:
                    plan?.lockSegments = false
                    timeSliceSegmentsCustom = false
                case .custom:
                    plan?.lockSegments = true
                    timeSliceSegmentsCustom = true
                case .fine, .medium, .bold:
                    if let count = choice.count {
                        settings.segments = settings.grid == nil
                            ? count : min(count, TimeSliceGridGeometry.maximumColumns)
                    }
                    plan?.lockSegments = true
                    timeSliceSegmentsCustom = false
                }
                model.timeSlice = settings
                model.timeSliceVariations = plan
            })
    }

    /// Named shares read back from the stored lag with a little tolerance:
    /// the lag is an integer, so a 25% ask can land at 23% on a long clip
    /// and must still read as Medium.
    private var timeSliceSpreadBinding: Binding<TimeSliceSpreadChoice> {
        Binding(
            get: {
                if timeSliceSpreadCustom { return .custom }
                let percent = timeSliceSpreadPercentBinding.wrappedValue
                return TimeSliceSpreadChoice.allCases.first {
                    $0.percent.map { abs($0 - percent) <= 3 } ?? false
                } ?? .custom
            },
            set: { choice in
                if let percent = choice.percent {
                    timeSliceSpreadPercentBinding.wrappedValue = percent
                    timeSliceSpreadCustom = false
                } else {
                    timeSliceSpreadCustom = true
                }
            })
    }

    private var timeSliceSpreadPercentBinding: Binding<Int> {
        Binding(
            get: {
                guard let settings = model.timeSlice,
                      let frames = timeSliceMasterFrames, frames > 0 else { return 25 }
                let fraction = TimeSliceGeometry.spreadFraction(
                    offsetFrames: settings.offsetFrames, masterFrames: frames,
                    segments: settings.segments)
                return max(1, Int((fraction * 100).rounded()))
            },
            set: { percent in
                guard var settings = model.timeSlice,
                      let frames = timeSliceMasterFrames, frames > 0 else { return }
                settings.offsetFrames = TimeSliceGeometry.offsetFrames(
                    spreadFraction: Double(percent) / 100, masterFrames: frames,
                    segments: settings.segments)
                model.timeSlice = settings
            })
    }

    // MARK: Derived

    /// The batch this Adjust screen would generate, resolved against the clip
    /// it can already measure — so the readout below states what will actually
    /// be rendered rather than what was asked for. Empty when no batch is
    /// armed or the clip's shape isn't known yet.
    private var timeSliceBatch: [TimeSliceSettings] {
        guard let plan = model.timeSliceVariations, let baseline = model.timeSlice,
              let frames = timeSliceMasterFrames, frames > 1,
              let size = timeSliceOutputSize, size.width >= 1, size.height >= 1
        else { return [] }
        return TimeSliceVariationGenerator.variations(
            plan: plan, baseline: baseline, masterFrames: frames,
            width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    /// Seeds a fresh recipe with the lag a ~25% spread of this clip needs —
    /// scale-aware where the absolute default wasn't.
    private func seededTimeSlice() -> TimeSliceSettings {
        var settings = TimeSliceSettings()
        if let frames = timeSliceMasterFrames, frames > 0 {
            settings.offsetFrames = TimeSliceGeometry.offsetFrames(
                spreadFraction: 0.25, masterFrames: frames, segments: settings.segments)
        }
        return settings
    }

    /// The master's frame count as Adjust can know it: exact for stills, the
    /// compiled warp's count for video, the speed arithmetic otherwise.
    private var timeSliceMasterFrames: Int? {
        if model.source?.isVideo == true {
            if let compiled = model.compiledWarp() { return compiled.outputFrames }
            guard let seconds = model.estimatedOutputSeconds() else { return nil }
            return max(1, Int((seconds * Double(model.outputFPS)).rounded()))
        }
        return model.photoOutputFrameCount
    }

    /// The pixel shape the bands are cut across — the canvas-cropped size for
    /// video, the stills' own probed frame otherwise.
    private var timeSliceOutputSize: CGSize? {
        if model.source?.isVideo == true {
            guard let display = model.sourceDisplaySize() else { return nil }
            return VideoCanvasCropper.cropSize(
                displaySize: display, canvas: model.effectiveBlendCanvas()) ?? display
        }
        guard let capture = model.currentCapture,
              let width = capture.sourceWidth, let height = capture.sourceHeight,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// What stops a Create outright: bands thinner than the floor, or a
    /// spread that eats the whole clip. nil = fine.
    private var timeSliceRefusal: String? {
        guard timeSlicingAvailable, let settings = model.timeSlice else { return nil }
        if let size = timeSliceOutputSize {
            let width = Int(size.width.rounded()), height = Int(size.height.rounded())
            if settings.grid != nil {
                if TimeSliceGridGeometry.layout(
                    width: width, height: height, columns: settings.segments) == nil {
                    return "\(settings.segments) columns across \(width) px makes cells under "
                        + "\(TimeSliceGridGeometry.minimumCellPixels) px, or leaves fewer than two "
                        + "rows — use fewer columns"
                }
            } else {
                let axisLength = Int(settings.axis == .vertical ? size.width : size.height)
                if TimeSliceGeometry.bandRanges(axisLength: axisLength, segments: settings.segments) == nil {
                    return "\(settings.segments) bands across \(axisLength) px falls under "
                        + "\(TimeSliceGeometry.minimumBandPixels) px each — use fewer segments"
                }
            }
        }
        if settings.output.wantsAnimation, let frames = timeSliceMasterFrames,
           TimeSliceGeometry.slicedFrameCount(
               masterFrames: frames, maxLag: timeSliceSpreadFrames(settings)) < 1 {
            return "The spread (\(timeSliceSpreadFrames(settings)) frames) consumes the whole clip "
                + "(\(frames) frames) — reduce segments or the spread"
        }
        // A batch whose every member is refused has nothing to render; the
        // generator has already discarded anything that wouldn't.
        if model.timeSliceVariations != nil, timeSliceMasterFrames != nil,
           timeSliceOutputSize != nil, timeSliceBatch.isEmpty {
            return "No take fits this clip — reduce the segments or the spread, or take the "
                + "count down to 1"
        }
        return nil
    }

    /// The spread in master frames — grid-aware, since a grid's ladder spans a
    /// row count the frame's own shape decides.
    private func timeSliceSpreadFrames(_ settings: TimeSliceSettings) -> Int {
        guard settings.grid != nil, let size = timeSliceOutputSize else { return settings.maxLagFrames }
        return settings.maxLagFrames(
            width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    /// One line: a refusal in red, else what the run is ready to make. A
    /// batch that can't seat every take says how many it will.
    @ViewBuilder private func timeSliceReadout(_ settings: TimeSliceSettings) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let refusal = timeSliceRefusal {
                Text(refusal).foregroundStyle(.red)
            } else if let plan = model.timeSliceVariations {
                let batch = timeSliceBatch
                let count = batch.isEmpty ? plan.count : batch.count
                Text("\(count) takes from one blend")
                if !batch.isEmpty, batch.count < plan.count {
                    Text("Only \(batch.count) of \(plan.count) fit this clip — the rest would have "
                        + "repeated one of these")
                        .foregroundStyle(.orange)
                }
            } else if settings.grid != nil {
                Text("Ready — \(timeSliceGridSummary(settings))")
            } else {
                Text("Ready — \(settings.segments) bands")
            }
            if let cost = timeSlicePosterCost(settings) {
                Text(cost)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The cost line under an Image output on a stills source
    /// (docs/time-slicing-poster-fast-path.md §6): with the regular
    /// timelapse off the run takes the fast path and renders only the
    /// ladder's frames; with it on, every still is blended. The toggle stays
    /// the user's — the line makes the difference visible, it never flips it.
    private func timeSlicePosterCost(_ settings: TimeSliceSettings) -> String? {
        guard model.source?.isVideo != true, settings.output == .image,
              let masterFrames = timeSliceMasterFrames, masterFrames > 0,
              let stills = model.currentCapture?.sourceMediaCount, stills > 0
        else { return nil }
        guard !settings.includeRegularClip else {
            return "Poster + regular timelapse: blends all \(stills) frames"
        }
        let recipes = model.timeSliceVariations == nil ? [settings] : timeSliceBatch
        guard let size = timeSliceOutputSize, !recipes.isEmpty,
              let union = try? TimeSliceRenderer.posterFrameIndices(
                recipes: recipes, masterFrames: masterFrames,
                width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        else { return nil }
        return "Poster only: renders \(union.count) of \(masterFrames) frames"
    }

    /// "24 × 14 grid" once the grid has a frame to resolve against, else the
    /// column count on its own.
    private func timeSliceGridSummary(_ settings: TimeSliceSettings) -> String {
        guard let size = timeSliceOutputSize,
              let layout = TimeSliceGridGeometry.layout(
                width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                columns: settings.segments)
        else { return "\(settings.segments)-column grid" }
        return "\(layout.columns) × \(layout.rows) grid"
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
        let isVideo = model.source?.isVideo == true
        var active: [String] = []
        if isVideo {
            if model.useRamp { active.append("Ramp on") }
            if model.trimVideoEnds { active.append("Trim on") }
        }
        if model.linearLight { active.append("True-light") }
        if !isVideo, model.applyStabilisation, model.framingLock != nil { active.append("Stabilised") }
        if !isVideo, !model.excludedFrameIndices.isEmpty {
            active.append("\(model.excludedFrameIndices.count) excluded")
        }
        if active.isEmpty {
            return isVideo ? "Ramp · Trim · True-light" : "True-light · Stabilisation · Excluded frames"
        }
        return active.joined(separator: " · ")
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
            // A slicing setup that can't render blocks the run here — the
            // reason is spelled out in red inside the Time slicing section.
            .disabled(timeSliceRefusal != nil)
            .opacity(timeSliceRefusal != nil ? 0.5 : 1)

            HStack(spacing: 10) {
                Text("Your original is kept — you can always make another blended clip.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                // Capture what just happened while it's fresh — a bug, an
                // observation, ambient sound — without leaving the flow. The
                // shoot is already registered, so the note lands on a real
                // project. Same component as the project screen's entry.
                if model.currentCapture != nil {
                    Button {
                        showFieldNoteFlow = true
                    } label: {
                        Text("+ Field note")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(LL.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(LL.screenBackground)
        .sheet(isPresented: $showFieldNoteFlow) {
            if let capture = model.currentCapture {
                FieldNoteFlowView(
                    capture: capture,
                    onClose: { showFieldNoteFlow = false })
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 480)
                #endif
            }
        }
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
        // Slicing renames the button to what the run will actually keep; with
        // the regular timelapse still on, the base title gains a suffix.
        if timeSlicingAvailable, let slice = model.timeSlice {
            // A batch says how many takes it will keep — the count is the
            // whole point of arming it.
            if let plan = model.timeSliceVariations {
                let count = timeSliceBatch.isEmpty ? plan.count : timeSliceBatch.count
                return slice.includeRegularClip
                    ? baseCtaTitle + " + \(count) takes"
                    : "Create \(count) takes"
            }
            if !slice.includeRegularClip {
                return slice.output == .image ? "Create time-slice poster" : "Create sliced clip"
            }
            return baseCtaTitle + " + slice"
        }
        return baseCtaTitle
    }

    private var baseCtaTitle: String {
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

// MARK: - Time-slicing control vocabulary

/// The Shape picker's seats. Grid is a first-class single-slice choice now
/// (2026-09-02); Mixed exists only for a batch, where it is the mode that
/// alternates bands and grids.
private enum TimeSliceShape: Hashable {
    case vertical, horizontal, grid, mixed
}

/// Time starts: an edge in reading order, or — for a batch — Mixed, which
/// lets the generator walk both edges of the axis.
private enum TimeSliceStart: Hashable {
    case edge(TimeSliceEdge)
    case mixed
}

/// Segments: three named counts, a batch's Mixed, and Custom with a stepper.
private enum TimeSliceSegmentsChoice: Hashable, CaseIterable {
    case fine, medium, bold, mixed, custom

    var count: Int? {
        switch self {
        case .fine: return 24
        case .medium: return 16
        case .bold: return 8
        case .mixed, .custom: return nil
        }
    }
}

/// Spread as a share of the clip: three named shares and Custom. Never
/// Mixed — a batch always varies the spread, last and least.
private enum TimeSliceSpreadChoice: Hashable, CaseIterable {
    case tight, medium, wide, custom

    var percent: Int? {
        switch self {
        case .tight: return 10
        case .medium: return 25
        case .wide: return 50
        case .custom: return nil
        }
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
                // The ramp and the trim are video vocabulary: for stills the
                // timeline IS the depth control, and a warp is never a trim.
                if model.source?.isVideo == true {
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

                if model.source?.isVideo != true {
                    // Stabilisation (docs/framing-lock.md): ON by default once
                    // the project carries a committed framing lock, OFF and
                    // disabled before. Per blend, like True-light.
                    Section {
                        Toggle(isOn: $model.applyStabilisation) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apply stabilisation")
                                Text(model.framingLock.map {
                                    "Locks the framing · crops \(FramingReviewStore.percent($0.cropFraction))"
                                } ?? "Not reviewed or stabilised yet")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(model.framingLock == nil)
                    } header: {
                        Text("Stabilisation")
                    } footer: {
                        Text(model.framingLock == nil
                             ? "Review and stabilise the photos on the project screen to enable this."
                             : "Reviewed and stabilised on the project screen. Off blends the photos exactly as captured. The originals are never changed.")
                    }

                    Section {
                        if model.excludedFrameIndices.isEmpty {
                            Text("Every photo is included in the blend.")
                                .foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Text("\(model.excludedFrameIndices.count) shaky tail \(model.excludedFrameIndices.count == 1 ? "frame" : "frames") excluded")
                                Spacer()
                                Button("Keep all") { model.excludedFrameIndices = [] }
                            }
                        }
                    } header: {
                        Text("Excluded frames")
                    } footer: {
                        Text("Tail-frame review drops the flagged shaky frames from the blend. The photos stay on disk either way.")
                    }
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

/// Free values for the selected stretch — anything the chips don't offer.
/// Video: 1×–240× speeds (slow motion below 1× stays on the ¼× chip).
/// Interval: any blend depth up to the whole shoot's frame count.
struct CustomSpeedSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var stretch: Int = 0

    private var isInterval: Bool { model.source?.isVideo != true }
    private var valueRange: ClosedRange<Int> {
        isInterval
            ? 1...max(2, model.currentCapture?.sourceMediaCount ?? SpeedMath.range.upperBound)
            : SpeedMath.range
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(
                        isInterval
                            ? "Depth: \(customSpeed.wrappedValue):1"
                            : "Speed: \(customSpeed.wrappedValue)×",
                        value: customSpeed, in: valueRange)
                    Slider(
                        value: Binding(
                            get: { Double(customSpeed.wrappedValue) },
                            set: { customSpeed.wrappedValue = Int($0.rounded()) }
                        ),
                        in: Double(valueRange.lowerBound)...Double(valueRange.upperBound),
                        step: 1
                    )
                } header: {
                    if model.activeWarp().stretchCount > 1 {
                        Text("Stretch \(min(stretch, model.activeWarp().stretchCount - 1) + 1)")
                    }
                } footer: {
                    Text(isInterval
                        ? "\(customSpeed.wrappedValue) photos average into each frame\(estimateSuffix)."
                        : "\(customSpeed.wrappedValue)× real time\(estimateSuffix).")
                }
            }
            .navigationTitle(isInterval ? "Custom blend depth" : "Custom speed")
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
