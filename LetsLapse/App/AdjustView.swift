import SwiftUI
import LetsLapseKit

/// "Adjust" — the warp timeline (design 3a): scrub the source, drag to
/// nominate a real-time moment, give every stretch its own speed, let the
/// seams own the ramps — then create the clip. The edit is a time-warp, never
/// a trim: every source frame lands in the finished clip.
struct AdjustView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAdvanced = false
    @State private var showCustomSpeed = false
    /// The stretch the chips edit, as an index into the warp timeline.
    @State private var selectedStretch = 0
    @StateObject private var preview = WarpPreviewLoader()

    /// The six canonical speeds. Free values come through the value sheet.
    private static let speedChips: [(speed: Double, word: String)] = [
        (0.25, "¼× slow"), (1, "real time"), (4, "gentle"),
        (15, "subtle"), (60, "flowing"), (100, "streaks"),
    ]

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width > 560 && model.source?.isVideo == true
            VStack(spacing: 0) {
                FlowHeader(title: "New blended clip") {
                    model.reset()
                }

                ScrollView {
                    if isWide {
                        wideLayout
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 16)
                    } else {
                        VStack(spacing: 14) {
                            sourceCard

                            if model.source?.isVideo == true {
                                warpCard(inlineThumbnail: true)
                                chipsRow
                                blendFromSection
                                estimateCard
                                advancedRow
                            } else {
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
            sourceCard
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    warpCard(inlineThumbnail: false)
                    chipsRow
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 14) {
                    widePreviewPane
                    estimateCard
                }
                .frame(width: 320)
            }
            blendFromSection
            advancedRow
            errorLine
        }
    }

    private var widePreviewPane: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black)
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
            .frame(height: 180)
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
            showsInlineThumbnail: inlineThumbnail
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .llCard()
    }

    /// Speed chips always edit the selected stretch — there is no separate
    /// "base" any more.
    private var chipsRow: some View {
        let timeline = model.activeWarp()
        let index = min(selectedStretch, max(0, timeline.stretchCount - 1))
        let current = timeline.speeds.indices.contains(index) ? timeline.speeds[index] : 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Self.speedChips, id: \.speed) { chip in
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
                Text("Speed ramp \(model.rampStart)×→\(model.rampEnd)× is on — editing the timeline turns it off. Edit it in Advanced.")
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
        if let capture = model.currentCapture, model.source?.isVideo == true {
            let codecs = model.availableBlendCodecs(for: capture)
            if !codecs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    LLSectionHeader("Blend from")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            codecChip(nil, "Auto")
                            ForEach(codecs, id: \.self) { codec in
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
            Button {
                model.startProcessing()
            } label: {
                Text(ctaTitle)
            }
            .buttonStyle(LLPrimaryButtonStyle())

            Text("Your original is kept — you can always make another blended clip.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(LL.screenBackground)
    }

    private var ctaTitle: String {
        if model.source?.isVideo == true {
            if let seconds = model.estimatedOutputSeconds() {
                return "Create \(SpeedMath.clipLength(seconds)) clip"
            }
            return "Create clip"
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
            model.updateWarp { $0.setSpeed(Double(newValue), for: index) }
        }
    }

    private var estimateSuffix: String {
        guard let seconds = model.estimatedOutputSeconds() else { return "" }
        return " — the clip lands at about \(SpeedMath.clipLength(seconds))"
    }
}
