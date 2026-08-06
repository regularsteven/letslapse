import AVFoundation
import SwiftUI

/// What a caller hands the reframe editor: the clip, plus whatever it already
/// knows about it. Anything missing is loaded from the asset on appear.
struct ReframeSourceRequest: Identifiable, Hashable {
    var url: URL
    var title: String
    var size: CGSize
    var duration: Double
    var fps: Double?
    /// nil = open at the shape the source was shot at.
    var ratio: ReframeRatio? = nil

    var id: String { url.path }
}

extension View {
    /// Present the reframe editor over this screen.
    ///
    /// Full-screen on iOS deliberately: as a sheet, iPad caps the form at
    /// ~700pt, which is exactly where the two-column layout would start — the
    /// editor would never get its wide layout on the device with the most room
    /// for it. The Mac keeps a sheet, which is freely resizable there.
    @ViewBuilder
    func reframeEditor(item: Binding<ReframeSourceRequest?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: item) { request in
            PunchInReframeView(request: request)
        }
        #else
        sheet(item: item) { request in
            PunchInReframeView(request: request)
                .frame(minWidth: 720, minHeight: 640)
        }
        #endif
    }
}

/// "Punch-In Reframe" — the warp-and-crop editor. Speed, crop and blend are
/// one move here: nominate the moment, punch into it, and the clip eases in
/// and out of real time around it. Never a cut.
struct PunchInReframeView: View {
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @State private var viewModel: PunchReframeViewModel
    @State private var renderer = ReframeRenderer()
    @State private var isRendering = false
    @State private var renderProgress: Double = 0

    /// Where a finished reframe goes. Unset means "render it here" — which is
    /// what the DEBUG hook and the standalone sheet do.
    var onCreate: ((_ keys: [PunchKeyframe], _ ratio: ReframeRatio) -> Void)?
    /// The clip card's "Change".
    var onChangeSource: (() -> Void)?

    /// The six canonical speeds, sharing the Adjust screen's vocabulary.
    private static let speedChips: [(speed: Double, word: String)] = [
        (0.25, "slow-mo"), (1, "real time"), (4, "gentle"),
        (15, "subtle"), (60, "flowing"), (100, "streaks"),
    ]


    init(
        url: URL? = nil,
        title: String = "Source",
        sourceSize: CGSize = CGSize(width: 3840, height: 2160),
        duration: Double = 0,
        fps: Double? = nil,
        ratio: ReframeRatio? = nil,
        onCreate: ((_ keys: [PunchKeyframe], _ ratio: ReframeRatio) -> Void)? = nil,
        onChangeSource: (() -> Void)? = nil
    ) {
        _viewModel = State(initialValue: PunchReframeViewModel(
            url: url, title: title, sourceSize: sourceSize,
            duration: duration, fps: fps, ratio: ratio))
        self.onCreate = onCreate
        self.onChangeSource = onChangeSource
    }

    init(
        request: ReframeSourceRequest,
        onCreate: ((_ keys: [PunchKeyframe], _ ratio: ReframeRatio) -> Void)? = nil,
        onChangeSource: (() -> Void)? = nil
    ) {
        self.init(
            url: request.url,
            title: request.title,
            sourceSize: request.size,
            duration: request.duration,
            fps: request.fps,
            ratio: request.ratio,
            onCreate: onCreate,
            onChangeSource: onChangeSource)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                FlowHeader(title: "New blended clip", onBack: { dismiss() }) {
                    ratioMenu
                }

                ScrollView {
                    Group {
                        if isWide(proxy.size.width) {
                            wideLayout
                        } else {
                            narrowLayout
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }

                footer
            }
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .task { await viewModel.loadSourceMetadata() }
        .task(id: viewModel.isPlaying) { await runPlayback() }
        .overlay(alignment: .top) { toast }
        .overlay { expandedReframe }
        .animation(.easeInOut(duration: 0.22), value: viewModel.isExpanded)
        #if os(iOS)
        .navigationBarBackButtonHidden(true)
        #endif
    }

    /// The two-column layout: the picture and its timeline on the left, the
    /// numbers on the right. Below the threshold the same cards stack.
    private func isWide(_ width: CGFloat) -> Bool {
        #if os(iOS)
        // A regular-width iPad splits sooner than a phone on its side: the
        // phone has the points but not the room, so it waits until a real
        // landscape (a small phone's 667pt landscape stays stacked).
        return width > (horizontalSizeClass == .regular ? 640 : 740)
        #else
        return width > 700
        #endif
    }

    // MARK: - Layouts

    private var narrowLayout: some View {
        VStack(spacing: 14) {
            clipCard
            warpCard
            speedChipsRow
            blendCard
            summaryCard
            errorLine
        }
    }

    private var wideLayout: some View {
        VStack(spacing: 14) {
            clipCard
            HStack(alignment: .top, spacing: 14) {
                warpCard
                    .frame(maxWidth: .infinity)
                VStack(spacing: 14) {
                    speedChipsRow
                    blendCard
                    summaryCard
                }
                .frame(width: 340)
            }
            errorLine
        }
    }

    // MARK: - Header

    private var ratioMenu: some View {
        Menu {
            ForEach(ReframeRatio.allCases) { ratio in
                Button {
                    viewModel.setRatio(ratio)
                } label: {
                    if ratio == viewModel.ratio {
                        Label("\(ratio.label) — \(ratio.cropNote)", systemImage: "checkmark")
                    } else {
                        Text("\(ratio.label) — \(ratio.cropNote)")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.ratio.label)
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
        .accessibilityLabel("Output shape \(viewModel.ratio.label)")
    }

    // MARK: - Card 1 · the clip

    private var clipCard: some View {
        HStack(spacing: 12) {
            ProjectThumbnailView(url: viewModel.sourceURL, kind: .video)
                .frame(width: 64, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.sourceTitle)
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)
                Text(viewModel.sourceSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            if let onChangeSource {
                Button("Change", action: onChangeSource)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(LL.accent)
                    .buttonStyle(.plain)
            }
        }
        .padding(12)
        .llCard()
    }

    // MARK: - Card 2 · the warp

    private var warpCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("SOURCE · \(ReframeEngine.timecode(viewModel.sourceDuration))")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("pinch the player · drag to scrub · tap a diamond")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            ReframePlayerView(viewModel: viewModel)
                .overlay(alignment: .topTrailing) { expandButton }

            WarpBarView(viewModel: viewModel)

            reframeLane
            selectedKeyPill

            if viewModel.canRemove {
                Button(role: .destructive) {
                    viewModel.removeSelected()
                } label: {
                    Text("Remove keyframe \(viewModel.selectedKeyIndex + 1)")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .llCard()
    }

    private var expandButton: some View {
        Button {
            viewModel.isPlaying = false
            viewModel.isExpanded = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                // "Expand to reframe" in full collides with the badge on a
                // phone — the badge is the one that has to stay readable.
                Text("Expand")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.5), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(10)
    }

    /// The lane's own header: what the diamonds are, and the one action the
    /// playhead affords right now — join the key you're on, or make one here.
    private var reframeLane: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("REFRAME")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let index = viewModel.onKeyframeIndex {
                Button("On K\(index + 1)") {
                    viewModel.selectKeyframe(index)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LL.accent)
                .buttonStyle(.plain)
            } else {
                Button("+ Keyframe at \(ReframeEngine.timecode(viewModel.currentTime))") {
                    viewModel.addKeyframe()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LL.accent)
                .buttonStyle(.plain)
            }
        }
    }

    private var selectedKeyPill: some View {
        Text(viewModel.selectedKeyLine)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LL.accent.opacity(0.10), in: Capsule())
    }

    // MARK: - Speed

    private var speedChipsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Self.speedChips, id: \.speed) { chip in
                    let active = abs((viewModel.selectedKey?.v ?? 1) - chip.speed) < 0.001
                    Button {
                        viewModel.setSpeed(chip.speed)
                    } label: {
                        VStack(spacing: 1) {
                            Text(ReframeEngine.speedLabel(chip.speed))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(active ? LL.amber : .primary)
                            Text(chip.word)
                                .font(.system(size: 9.5))
                                .foregroundStyle(active ? Color.white.opacity(0.6) : Color.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
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
                    .accessibilityLabel("\(ReframeEngine.speedLabel(chip.speed)) — \(chip.word)")
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            Text("Speed rides the selected keyframe — crop and blend ramp with it on the same ease.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Blend

    private var blendCard: some View {
        let key = viewModel.selectedKey
        let overridden = key?.ovr ?? false
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("BLEND DEPTH · K\(viewModel.selectedKeyIndex + 1)")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                blendModeMenu(overridden: overridden)
            }

            if viewModel.blendMode == .manual {
                blendChipsRow
            } else if overridden {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { key?.bl ?? 0 },
                            set: { viewModel.setBlend($0) }),
                        in: 0...1)
                        .tint(LL.accent)
                    Text("\(ReframeEngine.blendWord(key?.bl ?? 0).capitalized) · \(Int(((key?.bl ?? 0) * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LL.accentDeep)
                }
            } else {
                autoBlendCopy(key: key)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .llCard()
    }

    private func blendModeMenu(overridden: Bool) -> some View {
        Menu {
            Button("Follow speed") { viewModel.followSpeedBlend() }
            Button("Override this keyframe") { viewModel.beginBlendOverride() }
            Button("Manual depth") { viewModel.setBlendMode(.manual) }
        } label: {
            Text(viewModel.blendMode == .manual ? "Manual" : (overridden ? "Overridden" : "Override"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LL.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func autoBlendCopy(key: PunchKeyframe?) -> some View {
        let speed = key?.v ?? 1
        let word = ReframeEngine.blendWord(ReframeEngine.autoBlend(speed: speed))
        return (
            Text("Follows speed — ")
                + Text(word).fontWeight(.semibold).foregroundColor(LL.accentDeep)
                + Text(" at \(ReframeEngine.speedLabel(speed)). Heavy on the fast wide, off in the lock.")
        )
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var blendChipsRow: some View {
        // Nearest wins rather than an exact match: a depth carried in from a
        // slider still lights the chip it is closest to.
        let current = ReframeEngine.nearestManualDepth(viewModel.selectedKey?.bl ?? 0)
        return HStack(spacing: 6) {
            ForEach(ReframeEngine.manualDepths, id: \.self) { depth in
                let active = abs(current - depth) < 0.001
                Button {
                    viewModel.setBlend(depth)
                } label: {
                    Text(ReframeEngine.blendWord(depth).capitalized)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(active ? LL.amber : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            active ? LL.ink : LL.screenBackground,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your clip will be")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Menu {
                    ForEach([24, 25, 30, 50, 60], id: \.self) { fps in
                        Button {
                            viewModel.outputFPS = fps
                        } label: {
                            if fps == viewModel.outputFPS {
                                Label("\(fps) fps", systemImage: "checkmark")
                            } else {
                                Text("\(fps) fps")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("\(viewModel.outputFPS) fps")
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
                Text(ReframeEngine.shortTime(viewModel.outputDuration))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text("· \(viewModel.keys.count) keyframes")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LL.amber)
            }
            .padding(.top, 2)
            .padding(.bottom, 10)

            if viewModel.sourceDuration > 0 {
                BeforeAfterBar(
                    sourceLabel: ReframeEngine.timecode(viewModel.sourceDuration),
                    outputLabel: ReframeEngine.shortTime(viewModel.outputDuration),
                    ratio: viewModel.outputDuration / viewModel.sourceDuration
                )
                .padding(.bottom, 8)
            }

            Text("Speed, crop and blend ramp together on one eased curve — a time-warp, never a cut.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private var errorLine: some View {
        if let error = viewModel.errorMessage {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .llCard()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Button(action: create) {
                if isRendering {
                    Text("Creating… \(Int((renderProgress * 100).rounded()))%")
                } else {
                    Text("Create \(ReframeEngine.shortTime(viewModel.outputDuration)) clip")
                }
            }
            .buttonStyle(LLPrimaryButtonStyle())
            .disabled(isRendering || viewModel.sourceDuration <= 0)

            Text("Your original is kept — you can always make another blended clip.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(LL.screenBackground)
    }

    // MARK: - Toast

    @ViewBuilder private var toast: some View {
        if let message = viewModel.toast {
            Text(message)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(LL.ink.opacity(0.92), in: Capsule())
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                .padding(.top, 54)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .allowsHitTesting(false)
        }
    }

    // MARK: - Expanded reframe

    @ViewBuilder private var expandedReframe: some View {
        if viewModel.isExpanded {
            ZStack {
                Color(red: 11 / 255, green: 12 / 255, blue: 14 / 255)
                    .ignoresSafeArea()

                VStack(spacing: 14) {
                    HStack {
                        Text("Reframe · \(viewModel.ratio.label)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Button("Done") {
                            viewModel.isExpanded = false
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LL.amber)
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                    Spacer(minLength: 0)

                    ReframePlayerView(viewModel: viewModel, mode: .placement, showsControls: false)
                        .padding(.horizontal, 16)

                    Text("pinch to zoom · drag to position — the crop stays inside the source")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))

                    Spacer(minLength: 0)

                    HStack(spacing: 12) {
                        Button {
                            viewModel.togglePlay()
                        } label: {
                            Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(LL.amber)
                                .frame(width: 38, height: 38)
                                .background(.white.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

                        WarpBarView(viewModel: viewModel)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                }
            }
            .environment(\.colorScheme, .dark)
            .transition(.opacity)
            .zIndex(2)
        }
    }

    // MARK: - Playback

    private func runPlayback() async {
        guard viewModel.isPlaying else { return }
        var last = Date()
        while !Task.isCancelled, viewModel.isPlaying {
            try? await Task.sleep(nanoseconds: 33_000_000)
            let now = Date()
            viewModel.advancePlayback(by: now.timeIntervalSince(last))
            last = now
        }
    }

    // MARK: - Create

    private func create() {
        viewModel.isPlaying = false
        viewModel.errorMessage = nil
        if let onCreate {
            onCreate(viewModel.keys, viewModel.ratio)
            return
        }
        guard let url = viewModel.sourceURL else {
            viewModel.errorMessage = "There's no source clip to reframe."
            return
        }
        let keys = viewModel.keys
        let ratio = viewModel.ratio
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("reframe-\(UUID().uuidString).mov")

        isRendering = true
        renderProgress = 0
        Task {
            do {
                try await renderer.render(
                    asset: AVURLAsset(url: url),
                    keys: keys,
                    ratio: ratio,
                    outputURL: output,
                    progress: { value in
                        Task { @MainActor in renderProgress = value }
                    })
                viewModel.showToast("Reframed clip written")
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
            isRendering = false
        }
    }
}
