import SwiftUI

/// The experimental guided builder — a survey that authors the same
/// `WarpTimeline` + `ReframeTrack` the Adjust editor does, one state at a
/// time: framing belongs to a stretch, transitions ride the seams, welded to
/// the speed ramps that are already there. No free-floating keyframes, no
/// timeline to operate. Everything it writes round-trips into the full
/// editor unchanged.
///
/// Two shapes, one flow. Wide surfaces (Mac, iPad, iPhone landscape past the
/// rail breakpoint) get a **steps rail**: the checklist on the left, answers
/// written back into it as subtitles, completed steps clickable. Narrow ones
/// keep the paged survey with dots. Canvas and Opening are one step in both —
/// four steps, and every default is render-ready, so Next through to the end
/// always yields a legal clip.
///
/// One clock on screen: durations here are output (viewer) seconds only.
struct GuidedBuilderView: View {
    @EnvironmentObject var model: AppModel

    private enum Step: Equatable {
        /// The shape of the clip and how it opens — stretch 0 lives here.
        case canvas
        case stretch(Int)
        case review
    }

    private enum StretchRole {
        case whole, opening, moment, between, closing
    }

    /// Where the rail takes over. The rail itself is 252pt, so anything under
    /// this leaves the content pane narrower than the 320pt control column the
    /// steps are drawn at — the survey column reads better there. Adjust's own
    /// 560pt split stays its own: it has no rail to house.
    private static let railBreakpoint: CGFloat = 700
    /// …and a rail needs somewhere to hang its checklist. A phone on its side
    /// is wide enough and nowhere near tall enough, so it keeps the column.
    private static let railMinimumHeight: CGFloat = 500
    private static let scrollSpace = "guided.scroll"
    /// The framing surface, for the iOS fold cue's scroll target.
    private static let framingBoxID = "guided.framing"

    @State private var stepIndex = 0
    /// The furthest step the user has reached — jumping BACK via the rail or
    /// the strip must not disable everything ahead of the jump; progress and
    /// position are different facts.
    @State private var maxVisitedStep = 0
    /// One answer per stretch, aligned with the warp's stretches.
    @State private var punches: [GuidedPunch] = []
    @State private var seeded = false
    /// Which of a pan's two framings the box edits.
    @State private var editingExit = false
    @State private var showCustomSpeed = false
    @State private var customSpeedStretch = 0
    /// The closing stretch defaults to the opening's state; this reveals the
    /// controls for the one-tap override.
    @State private var closingOverride = false
    /// Steps the user has actually answered something on. The rail says
    /// "answering…" for the step being worked until then — a seeded value
    /// written back as if it were an answer would be a small lie.
    @State private var touched: Set<Int> = []
    /// The iOS fold cue: whether the framing surface is on screen, and the
    /// scroll viewport it is measured against.
    @State private var framingBoxVisible = true
    @State private var viewportHeight: CGFloat = 0
    /// The step the last fold-scroll decision was made on. The auto-scroll is
    /// a response to PICKING a framing mode — arriving on a step whose punch
    /// differs from the last one must not yank the scroll position.
    @State private var foldScrollStep = -1
    /// The scrub preview's position — an absolute output frame on the
    /// compiled clock, nil while no preview is showing. `scrubLocked` says
    /// whether it is held (a drag) or a peek (a hover clears on exit).
    @State private var scrubFrame: Double?
    @State private var scrubLocked = false
    /// The moment step's third framing mode: the stage shows the output
    /// through the moving crop instead of composing a framing.
    @State private var previewingMoment = false

    private var warp: WarpTimeline { model.activeWarp() }
    private var stretches: [BlendStretch] { model.blendStretches() }

    /// Canvas (with the opening folded in), one step per remaining stretch,
    /// then review — four steps for the usual one-moment shoot.
    private var steps: [Step] {
        var list: [Step] = [.canvas]
        if warp.stretchCount > 1 {
            for index in 1..<warp.stretchCount {
                list.append(.stretch(index))
            }
        }
        list.append(.review)
        return list
    }

    private var currentStep: Step {
        let all = steps
        return all[min(max(0, stepIndex), all.count - 1)]
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if proxy.size.width >= Self.railBreakpoint,
                   proxy.size.height >= Self.railMinimumHeight {
                    railLayout(size: proxy.size)
                } else {
                    columnLayout
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .onAppear(perform: seedIfNeeded)
        .onChange(of: warp.stretchCount) { count in
            guard seeded, punches.count != count else { return }
            // A late metadata probe can re-shape a marker timeline mid-flow;
            // keep the answers aligned with the stretches they belong to.
            if punches.count < count {
                punches += Array(repeating: .none, count: count - punches.count)
            } else {
                punches = Array(punches.prefix(count))
            }
            stepIndex = min(stepIndex, steps.count - 1)
            maxVisitedStep = min(max(maxVisitedStep, stepIndex), steps.count - 1)
        }
        .onChange(of: model.effectiveBlendCanvas()) { _ in
            // Framings are composed against the canvas: a new shape re-clamps
            // every authored crop (the punch factor survives, the centre moves
            // only as far as it must) so the box on screen stays the box that
            // renders. Changing the crop's offset moves no framing — a punch
            // is positioned in source pixels, which the offset doesn't touch.
            reclampPunches()
        }
        .onChange(of: stepIndex) { _ in
            // A preview belongs to the step it was scrubbed on — its window
            // and its meaning both change with the question.
            scrubFrame = nil
            scrubLocked = false
            previewingMoment = false
            publishStepToRemote()
        }
        .onChange(of: model.compiledWarp()?.outputFrames ?? -1) { _ in
            // A held preview is a position on the compiled clock; any change
            // that recompiles the clip (speed, output rate, a seam) makes
            // that clock a different clock, and a badge reading "18s of 6s"
            // would be a lie. Let go and let the user scrub the new clip.
            scrubFrame = nil
            scrubLocked = false
        }
        .sheet(isPresented: $showCustomSpeed) {
            CustomSpeedSheet(stretch: customSpeedStretch)
                .environmentObject(model)
        }
    }

    private func seedIfNeeded() {
        // The builder authors the warp path only — the legacy Advanced
        // ramp would silently replace the whole reviewed plan at render
        // (it wins over the timeline and drops the reframe).
        model.useRamp = false
        guard !seeded else { return }
        // Coming back with a materialised track still on the model (a
        // cancelled render, "adjust again" from the result screen) must
        // not wipe the authored framings — read them back as answers.
        let timeline = model.activeWarp()
        punches = GuidedPlanner.punches(from: model.activeReframe(), warp: timeline)
        if let first = timeline.speeds.first, let last = timeline.speeds.last,
           timeline.stretchCount > 1, abs(first - last) > 0.001 {
            // A closing speed that already differs from the opening was
            // chosen on purpose — don't let the "ends like it starts"
            // sync clobber it.
            closingOverride = true
        }
        seeded = true
        #if DEBUG
        // LL_STEP=<n> lands on a later step for variant screenshots; the step
        // index is this view's own state, so the launch hook is read here.
        if let raw = ProcessInfo.processInfo.environment["LL_STEP"], let step = Int(raw) {
            stepIndex = min(max(0, step), steps.count - 1)
        }
        #endif
        maxVisitedStep = max(maxVisitedStep, stepIndex)
        publishStepToRemote()
    }

    /// Write-only mirror for the Watch remote, which shows "Step 3 of 5" when
    /// it explains that arming the camera will leave this flow. The step index
    /// stays this view's own state — the rail, `maxVisitedStep` and the
    /// `LL_STEP` hook all read it here — so this only copies it out.
    private func publishStepToRemote() {
        model.guidedStep = stepIndex + 1
        model.guidedStepCount = steps.count
    }

    // MARK: - Layouts

    /// Mac / iPad: the checklist owns the left edge, the step owns the rest.
    /// No step dots and no flow header — the rail says where you are, and its
    /// own Back button is the way out.
    ///
    /// The pane's width is passed down rather than discovered: the step's
    /// frame pane sizes itself to a real number of points, and a demand wider
    /// than the window pushes the whole rail off its own left edge. The
    /// content column caps at a reading width and centres in whatever is
    /// left, and the stage grows with the window's height — a big display
    /// gets a composed page and a real composition surface, not a strip of
    /// controls pinned to the rail with a void beside them.
    private func railLayout(size: CGSize) -> some View {
        let content = min(max(320, size.width - 252 - 60), 1160)
        let stageHeight = min(620, max(340, size.height - 330))
        return HStack(spacing: 0) {
            rail
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    stepContent(rail: true, contentWidth: content, stageHeight: stageHeight)
                        .padding(.top, 22)
                        .padding(.bottom, 12)
                        .frame(width: content, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                Divider()
                flowStrip(width: content)
                railBottomBar(width: content)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// iPhone (and anything narrower than the rail): the paged survey.
    private var columnLayout: some View {
        VStack(spacing: 0) {
            FlowHeader(title: "Guided clip", onBack: goBack, centersTitle: true) {
                experimentalCapsule
            }

            stepDots
                .padding(.top, 10)

            Text("Step \(stepIndex + 1) of \(steps.count) · \(stepTitle(currentStep))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)

            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        stepContent(rail: false, contentWidth: 0, stageHeight: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                .coordinateSpace(name: Self.scrollSpace)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { viewportHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { viewportHeight = $0 }
                    }
                }
                .onPreferenceChange(FramingBoxVisibleKey.self) { framingBoxVisible = $0 }
                .onChange(of: framingModeSignature) { _ in
                    // Picking a framing mode is a promise that a box appears;
                    // if it landed below the fold, go to it. A signature
                    // change caused by NAVIGATING onto a differently-punched
                    // step is not a pick — swallow the first change per step.
                    let step = stepIndex
                    defer { foldScrollStep = step }
                    guard step == foldScrollStep else { return }
                    withAnimation(.easeOut(duration: 0.28)) {
                        scroll.scrollTo(Self.framingBoxID, anchor: .center)
                    }
                }
            }
            .overlay(alignment: .bottom) { foldCue }

            bottomBar
        }
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Guided clip")
                    .font(.system(size: 15, weight: .bold))
                experimentalCapsule
            }
            .padding(.horizontal, 8)

            // The rows scroll: a multi-burst shoot can carry more steps than
            // a 500pt-tall window has rail — the title and the full-editor
            // escape hatch must never be pushed off the window.
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, _ in
                        railRow(index)
                    }
                }
                .padding(.top, 18)
            }

            Spacer(minLength: 12)

            Button {
                syncClosingWithOpeningIfNeeded()
                materialise()
                model.guidedBuilderFocused = false
            } label: {
                Text("Open in the full editor")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(LL.accent)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 20)
        .frame(width: 252, alignment: .topLeading)
        .background(LL.cardBackground.opacity(0.68))
    }

    private func railRow(_ index: Int) -> some View {
        let step = steps[index]
        let isCurrent = index == stepIndex
        // Visited steps are links — the walk back through Back, Back, Back
        // is what makes a survey feel like a cage, and a back-jump must not
        // lock the door on the steps ahead of it.
        let reachable = index <= max(stepIndex, maxVisitedStep)
        return Button {
            guard reachable, !isCurrent else { return }
            syncClosingWithOpeningIfNeeded()
            materialise()
            editingExit = false
            stepIndex = index
        } label: {
            HStack(alignment: .top, spacing: 10) {
                stepMarker(index)
                VStack(alignment: .leading, spacing: 1) {
                    Text(stepTitle(step))
                        .font(.system(size: 13, weight: isCurrent ? .bold : .semibold))
                        .foregroundStyle(reachable ? Color.primary : Color.secondary)
                    Text(railSubtitle(step, index: index))
                        .font(.system(size: 11))
                        .foregroundStyle(isCurrent ? LL.accent : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isCurrent ? LL.accent.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!reachable)
        .accessibilityLabel("\(stepTitle(step)) — \(railSubtitle(step, index: index))")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func stepMarker(_ index: Int) -> some View {
        // Visited counts as done even while standing on an earlier step — a
        // back-jump must not strip the checkmarks off the answers ahead.
        let isDone = index != stepIndex && index <= maxVisitedStep
        let isCurrent = index == stepIndex
        return ZStack {
            if isDone {
                Circle().fill(LL.accent)
            } else if isCurrent {
                Circle().strokeBorder(LL.accent, lineWidth: 2)
            } else {
                Circle().fill(Color.secondary.opacity(0.18))
            }
            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isCurrent ? LL.accent : Color.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }

    private func stepTitle(_ step: Step) -> String {
        switch step {
        case .canvas:
            return warp.stretchCount > 1 ? "Canvas & opening" : "Canvas & speed"
        case .stretch(let index):
            switch role(of: index) {
            case .closing: return "Ending"
            case .between: return "In between"
            default: return stretchName(index)
            }
        case .review:
            return "Review"
        }
    }

    /// The answer, written back. Unvisited steps show what they are seeded
    /// with (a burst arrives already slowed), so the rail reads as a plan
    /// rather than a row of blanks.
    private func railSubtitle(_ step: Step, index: Int) -> String {
        if index == stepIndex, !touched.contains(index), step != .review {
            return "answering…"
        }
        switch step {
        case .canvas:
            // The step's three answers: shape, rate, opening speed.
            return "\(model.effectiveBlendCanvas().rawValue) · \(model.outputFPS) fps · \(speedSummary(0))"
        case .stretch(let stretch):
            if role(of: stretch) == .closing, !closingOverride {
                return punches.first?.isPunched == true ? "Ends wide" : "Ends like it starts"
            }
            return speedSummary(stretch) + punchSuffix(stretch)
        case .review:
            let length = model.estimatedOutputSeconds().map { SpeedMath.clipLength($0) } ?? "—"
            return "\(length) · \(warp.stretchCount) \(warp.stretchCount == 1 ? "stretch" : "stretches")"
        }
    }

    private func speedSummary(_ index: Int) -> String {
        let speed = displaySpeed(of: index)
        return "\(WarpTimeline.speedLabel(speed)) \(WarpTimeline.speedWord(speed))"
    }

    /// The speed that RENDERS: the compiler floors every stretch at one
    /// source frame per output frame, so a seeded ¼× on footage that can
    /// only honour ½× must read back as ½× everywhere — rail, chips, strip.
    /// A floor within a rounding hair of a chip snaps onto it (a 99.6 fps
    /// probe floors ½× to 0.502, which must still read — and highlight — as
    /// ½×, the same 2% grace the chip gate gives).
    private func displaySpeed(of index: Int) -> Double {
        let chosen = warp.speeds.indices.contains(index) ? warp.speeds[index] : 1
        let floored = max(chosen, Double(model.outputFPS) / max(1, model.warpStretchFPS(index)))
        for chip in [0.25, 0.5] where abs(floored - chip) <= chip * 0.05 {
            return chip
        }
        return floored
    }

    /// Terse on purpose: the rail row is 252pt wide and the numbers belong to
    /// the review step, which has room to say them properly.
    private func punchSuffix(_ index: Int) -> String {
        let punch = punches.indices.contains(index) ? punches[index] : .none
        switch punch {
        case .none: return ""
        case .still(let framing): return String(format: " · %.1f× punch", framing.z)
        case .pan: return " · pan"
        }
    }

    private var experimentalCapsule: some View {
        Text("EXPERIMENTAL")
            .font(.system(size: 9, weight: .bold))
            .kerning(0.5)
            .foregroundStyle(LL.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(LL.accent.opacity(0.12), in: Capsule())
    }

    // MARK: - Navigation

    private func goBack() {
        if stepIndex > 0 {
            materialise()
            editingExit = false
            stepIndex -= 1
        } else {
            // Back off the first step returns to the project this flow was
            // opened from — the button that started it lives on the project
            // detail page, so that page is "back", not the Create home.
            model.finishFlow(openProject: true)
        }
    }

    private func goNext() {
        syncClosingWithOpeningIfNeeded()
        materialise()
        editingExit = false
        if stepIndex < steps.count - 1 {
            stepIndex += 1
            maxVisitedStep = max(maxVisitedStep, stepIndex)
        }
    }

    /// Leaving the canvas step keeps the closing stretch on the opening's
    /// state until the user overrides it — "ends like it starts". The opening
    /// lives on that step now, so this fires on ANY way out of it — Next or
    /// the full-editor hand-off — a Back into it re-opens both answers
    /// together and re-syncs on the way out. Only for a closing BASE run: a
    /// shoot that ends on a recorded moment keeps its seeded slow motion.
    private func syncClosingWithOpeningIfNeeded() {
        guard currentStep == .canvas, warp.stretchCount > 1, !closingOverride,
              role(of: warp.stretchCount - 1) == .closing,
              let opening = warp.speeds.first else { return }
        model.updateWarp { $0.setSpeed(opening, for: $0.stretchCount - 1) }
    }

    /// Write the survey's answers through as the real reframe track. Runs on
    /// step changes and before Create — discrete moments, not every drag.
    private func materialise() {
        guard let size = model.sourceDisplaySize() else { return }
        let timeline = model.activeWarp()
        guard punches.count == timeline.stretchCount else { return }
        let compiled = model.compiledWarp()
        let track = GuidedPlanner.track(
            punches: punches,
            warp: timeline,
            seamEase: { index in
                guard let eases = compiled?.seamEases, eases.indices.contains(index) else {
                    return nil
                }
                return eases[index]
            },
            aspect: model.effectiveBlendCanvas().aspect,
            sourceSize: size,
            canvasOffset: model.blendCanvasOffset)
        // Key ids are fresh per materialisation, so `==` never matches —
        // compare content, or every step navigation pushes a dead undo step.
        guard !GuidedPlanner.tracksEquivalent(track, model.activeReframe()) else { return }
        model.updateReframe { $0 = track }
    }

    // MARK: - Scrub preview plumbing

    /// The survey's answers as the track that would render right now — the
    /// same construction `materialise()` writes, evaluated for the preview
    /// without touching the model.
    private var previewTrack: ReframeTrack {
        let timeline = model.activeWarp()
        guard let size = model.sourceDisplaySize(),
              punches.count == timeline.stretchCount else { return model.activeReframe() }
        let compiled = model.compiledWarp()
        return GuidedPlanner.track(
            punches: punches,
            warp: timeline,
            seamEase: { index in
                guard let eases = compiled?.seamEases, eases.indices.contains(index) else {
                    return nil
                }
                return eases[index]
            },
            aspect: model.effectiveBlendCanvas().aspect,
            sourceSize: size,
            canvasOffset: model.blendCanvasOffset)
    }

    /// Everything the scrub needs, read once per body from the same compile
    /// the estimate and the render use. nil while the source has no shape.
    private var scrubContext: GuidedScrubContext? {
        GuidedScrubContext(
            compiled: model.compiledWarp(),
            track: previewTrack,
            aspect: model.effectiveBlendCanvas().aspect,
            sourceSize: model.sourceDisplaySize(),
            canvas: model.effectiveBlendCanvas(),
            canvasOffset: model.blendCanvasOffset,
            outputFPS: model.outputFPS)
    }

    private func locateFrame(_ sourceSeconds: Double) -> (url: URL, seconds: Double)? {
        model.warpFrameLocation(at: sourceSeconds)
    }

    /// Re-seat every authored framing inside the canvas it is composed
    /// against. Called when the shape changes; the punch factor is the user's
    /// answer, so it survives — only the centre is pulled back in bounds.
    private func reclampPunches() {
        guard let size = model.sourceDisplaySize() else { return }
        let aspect = model.effectiveBlendCanvas().aspect
        func clamped(_ framing: GuidedFraming) -> GuidedFraming {
            let z = min(max(framing.z, ReframeTrack.minZoom), ReframeTrack.maxZoom)
            let centre = ReframeMath.clampCenter(
                z: z, cx: framing.cx, cy: framing.cy, aspect: aspect, sourceSize: size)
            return GuidedFraming(z: z, cx: centre.cx, cy: centre.cy)
        }
        punches = punches.map { punch in
            switch punch {
            case .none: return .none
            case .still(let framing): return .still(clamped(framing))
            case .pan(let from, let to, let eased):
                return .pan(from: clamped(from), to: clamped(to), eased: eased)
            }
        }
    }

    /// Marks the step being worked as answered, so the rail can stop saying
    /// "answering…" the moment a control on it is used.
    private func touch() {
        touched.insert(stepIndex)
    }

    // MARK: - Chrome

    private var stepDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<steps.count, id: \.self) { index in
                Capsule()
                    .fill(index <= stepIndex ? LL.accent : Color.secondary.opacity(0.25))
                    .frame(width: index == stepIndex ? 18 : 7, height: 5)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: stepIndex)
        .accessibilityLabel("Step \(stepIndex + 1) of \(steps.count)")
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if currentStep == .review {
                Button {
                    materialise()
                    model.startProcessing()
                } label: {
                    Text(ctaTitle)
                }
                .buttonStyle(LLPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)

                Text("Your original is kept — you can always make another blended clip.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    goNext()
                } label: {
                    Text("Next")
                }
                .buttonStyle(LLPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(LL.screenBackground)
    }

    /// Desktop convention: real push buttons, bottom-trailing, Next as the
    /// window's default button.
    private func railBottomBar(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            if currentStep == .review {
                Text("Your original is kept — you can always make another blended clip.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Back", action: goBack)
                .buttonStyle(RailButtonStyle(isDefault: false))
            if currentStep == .review {
                Button(ctaTitle) {
                    materialise()
                    model.startProcessing()
                }
                .buttonStyle(RailButtonStyle(isDefault: true))
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Next", action: goNext)
                    .buttonStyle(RailButtonStyle(isDefault: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: width)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Overview strip

    /// One stretch of the clip, as the strip draws it.
    private struct StripSegment: Identifiable {
        let id: Int
        let name: String
        let speedLabel: String
        /// Output seconds this stretch contributes — the segment's weight.
        let share: Double
        let isMoment: Bool
        let isPunched: Bool
        /// The seam INTO this segment: "cut", "1s", "0.4s"… nil on the first.
        let rampLabel: String?
    }

    private var stripSegments: [StripSegment] {
        let timeline = warp
        let compiled = model.compiledWarp()
        return (0..<timeline.stretchCount).map { index in
            let chosen = timeline.speeds.indices.contains(index) ? timeline.speeds[index] : 1
            let speed = displaySpeed(of: index)
            let share: Double = {
                if let compiled, compiled.stretchFrames.indices.contains(index) {
                    return max(0.2, Double(compiled.stretchFrames[index]) / Double(max(1, model.outputFPS)))
                }
                // No compile yet: source length ÷ speed approximates it.
                return max(0.2, timeline.length(of: index) / max(0.01, chosen))
            }()
            let ramp: String? = index == 0 ? nil : seamShortLabel(index - 1)
            let punch = punches.indices.contains(index) ? punches[index] : .none
            return StripSegment(
                id: index,
                name: stretchName(index),
                speedLabel: WarpTimeline.speedLabel(speed),
                share: share,
                isMoment: stretches.indices.contains(index) && stretches[index].kind == .moment,
                isPunched: punch.isPunched,
                rampLabel: ramp)
        }
    }

    /// The clip at a glance: one block per stretch, sized by the output
    /// seconds it really contributes, moments in the ink-and-amber idiom,
    /// the stretch being answered outlined in accent. The rail says where
    /// you are in the questions; this says where that lands in the clip.
    private func flowStrip(width: CGFloat) -> some View {
        let segments = stripSegments
        let currentStretch: Int? = {
            switch currentStep {
            case .canvas: return 0
            case .stretch(let index): return index
            case .review: return nil
            }
        }()
        // Widths: proportional to output share with a readability floor, then
        // scaled as a whole so the row can NEVER outgrow its column (the
        // adversarial review found the old floor/renormalise pass both
        // overflowing onto the rail once every block sat at its floor AND
        // inverting the proportions when the overshoot exceeded the slack —
        // the longest stretch rendered narrowest). Lifting the floor first
        // and scaling everything uniformly after keeps the order monotonic
        // and the total exactly inside `available`, whatever the count.
        let trailing: CGFloat = 78
        let connectors = CGFloat(max(0, segments.count - 1)) * 30
        let available = max(60, width - trailing - connectors - 10)
        let total = max(0.001, segments.reduce(0) { $0 + $1.share })
        let floorWidth = min(64, available / CGFloat(max(1, segments.count)))
        let lifted = segments.map { max(floorWidth, CGFloat($0.share / total) * available) }
        let liftedSum = max(1, lifted.reduce(0, +))
        let widths = liftedSum > available
            ? lifted.map { $0 * available / liftedSum }
            : lifted

        return HStack(alignment: .center, spacing: 0) {
            ForEach(segments) { segment in
                if let ramp = segment.rampLabel {
                    Text(ramp)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                stripBlock(
                    segment,
                    width: widths.indices.contains(segment.id) ? widths[segment.id] : floorWidth,
                    isCurrent: segment.id == currentStretch)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 1) {
                Text(model.estimatedOutputSeconds().map { SpeedMath.clipLength($0) } ?? "—")
                    .font(.system(size: 14, weight: .bold))
                Text(warp.stretchCount == 1 ? "1 stretch" : "\(warp.stretchCount) stretches")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(width: trailing, alignment: .trailing)
        }
        .frame(width: width)
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clip overview")
    }

    private func stripBlock(_ segment: StripSegment, width: CGFloat, isCurrent: Bool) -> some View {
        // Visited steps are one click away here too, same rule as the rail.
        let targetStep = min(segment.id, steps.count - 1)
        let reachable = targetStep <= max(stepIndex, maxVisitedStep)
        return Button {
            guard reachable, targetStep != stepIndex else { return }
            syncClosingWithOpeningIfNeeded()
            materialise()
            editingExit = false
            stepIndex = targetStep
        } label: {
            HStack(spacing: 4) {
                VStack(spacing: 1) {
                    Text(segment.speedLabel)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(segment.isMoment ? LL.amber : Color.primary)
                    // A heavily compressed block keeps its speed and drops
                    // the name — a scaled-to-mush label helps nobody.
                    if width >= 56 {
                        Text(segment.name)
                            .font(.system(size: 9))
                            .foregroundStyle(segment.isMoment ? Color.white.opacity(0.6) : Color.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                if segment.isPunched, width >= 48 {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(segment.isMoment ? LL.amber.opacity(0.8) : Color.secondary)
                }
            }
            .frame(width: max(24, width - 4), height: 40)
            .background(
                segment.isMoment ? LL.ink : LL.cardBackground,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isCurrent ? LL.accent : Color.clear, lineWidth: 2))
            .shadow(color: .black.opacity(segment.isMoment ? 0 : 0.05), radius: 1, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        // Not `.disabled` — that dims the block into a washed slab, and the
        // strip is a map of the clip, not a row of broken buttons. Unreached
        // segments just don't take the click.
        .allowsHitTesting(reachable)
        .accessibilityLabel("\(segment.name), \(segment.speedLabel)\(segment.isPunched ? ", punched" : "")")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var ctaTitle: String {
        if let seconds = model.estimatedOutputSeconds() {
            return "Create \(SpeedMath.clipLength(seconds)) clip"
        }
        return "Create clip"
    }

    /// The fold cue: while the framing surface a mode just promised is off
    /// screen, a pill bridges the gap.
    @ViewBuilder private var foldCue: some View {
        if !framingBoxVisible, currentPunch.isPunched {
            Text("Frame the shot ↓")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(LL.amber)
                .padding(.horizontal, 15)
                .padding(.vertical, 7)
                .background(LL.ink, in: Capsule())
                .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
                .padding(.bottom, 10)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: - Steps

    @ViewBuilder private func stepContent(rail: Bool, contentWidth: CGFloat, stageHeight: CGFloat) -> some View {
        switch currentStep {
        case .canvas:
            canvasStep(rail: rail, contentWidth: contentWidth, stageHeight: stageHeight)
        case .stretch(let index):
            stretchStep(index, rail: rail, contentWidth: contentWidth, stageHeight: stageHeight)
        case .review:
            reviewStep
        }
    }

    /// The answers column's width on the rail: enough for the widest chip row
    /// (a base run's seven speed chips) without stretching the controls into
    /// slabs; whatever is left is the stage's.
    private func answersColumnWidth(_ contentWidth: CGFloat) -> CGFloat {
        min(460, max(380, contentWidth * 0.45))
    }

    private func question(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    // MARK: Canvas & opening

    /// The merged first step. The shape is asked at the top, above everything
    /// it changes, and answered against the output itself — the exact first
    /// frame at that shape, not the source with a box over it. The opening
    /// folds in underneath, so the flow is four steps and Next-Next-Next
    /// always lands on a legal clip.
    @ViewBuilder private func canvasStep(rail: Bool, contentWidth: CGFloat, stageHeight: CGFloat) -> some View {
        let canvas = model.effectiveBlendCanvas()
        // The output's own proportions choose the layout: a wide clip is a
        // shallow band that wants the full width, a tall one leaves a column
        // beside it — as long as what's left over is a frame worth looking at.
        let wideOutput = canvas.aspect > 1
        let punch = punches.first ?? .none
        let answersWidth = answersColumnWidth(contentWidth)
        let stageWidth = contentWidth - answersWidth - 32

        VStack(alignment: .leading, spacing: 14) {
            if rail {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    question("What shape should the clip be?")
                    shapeMenu
                }
                hint("The shape sits above everything it changes — every framing below is composed against it.")
            } else {
                question("What shape should the clip be?")
                CanvasRatioChips(selected: canvas) { ratio in
                    touch()
                    model.blendCanvasRatio = ratio
                }
                Text(canvasConsequence)
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 4)
            }

            if rail, wideOutput, !punch.isPunched {
                // A wide output is a shallow band — it takes the full width
                // up top and the controls spread into the freed width below.
                // A punch flips this branch to the two-column stage, so the
                // surface never needs to render inline here.
                canvasFramePane(
                    rail: true, wideOutput: true, budget: contentWidth, stageHeight: stageHeight)
                openingControls(framingInStage: true)
            } else if rail, stageWidth >= 240 {
                // Everything else shares the one stage every step uses: the
                // output itself while the framing is wide, the framing
                // surface once the opening is punched — never two pictures
                // pretending to be a before-and-after.
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 14) {
                        openingControls(framingInStage: true)
                    }
                    .frame(width: answersWidth)
                    framingStage(0, width: stageWidth, height: stageHeight, role: role(of: 0))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if rail {
                canvasFramePane(
                    rail: true, wideOutput: wideOutput, budget: contentWidth, stageHeight: stageHeight)
                openingControls(framingInStage: false)
            } else {
                canvasFramePane(rail: false, wideOutput: wideOutput, budget: contentWidth, stageHeight: 0)
                openingControls(framingInStage: false)
            }
        }
    }

    /// The shape as a pop-up menu, sat on the question row: every option
    /// carries its consequence, and the numbers come from the cropper the
    /// render uses, never from UI arithmetic.
    private var shapeMenu: some View {
        Menu {
            ForEach(CanvasRatio.allCases) { ratio in
                Button {
                    touch()
                    model.blendCanvasRatio = ratio
                } label: {
                    if ratio == model.effectiveBlendCanvas() {
                        Label(canvasChoiceLabel(ratio), systemImage: "checkmark")
                    } else {
                        Text(canvasChoiceLabel(ratio))
                    }
                }
            }
            if abs(model.blendCanvasOffset - 0.5) > 0.005 {
                Divider()
                Button("Recentre crop") {
                    touch()
                    model.blendCanvasOffset = 0.5
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(canvasConsequence)
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Clip shape \(canvasConsequence)")
    }

    /// "9:16 — as shot" / "1:1 — crops to 2160×2160", from
    /// `VideoCanvasCropper.cropSize` — the size the render really writes,
    /// even-rounded for the encoder.
    private func canvasChoiceLabel(_ ratio: CanvasRatio) -> String {
        guard let size = model.sourceDisplaySize() else { return ratio.rawValue }
        if let crop = VideoCanvasCropper.cropSize(displaySize: size, canvas: ratio) {
            return "\(ratio.rawValue) — crops to \(Int(crop.width))×\(Int(crop.height))"
        }
        return "\(ratio.rawValue) — as shot"
    }

    private var canvasConsequence: String {
        canvasChoiceLabel(model.effectiveBlendCanvas())
    }

    /// The kept pixels as a badge string, or nil when the clip keeps its shape.
    private var canvasCropLabel: String? {
        guard let size = model.sourceDisplaySize(),
              let crop = VideoCanvasCropper.cropSize(
                displaySize: size, canvas: model.effectiveBlendCanvas()) else { return nil }
        return "\(Int(crop.width))×\(Int(crop.height))"
    }

    @ViewBuilder private func canvasFramePane(
        rail: Bool, wideOutput: Bool, budget: CGFloat, stageHeight: CGFloat
    ) -> some View {
        let canvas = model.effectiveBlendCanvas()
        // The strip and its gap come out of the budget before the frame does,
        // so the pane can never ask for more width than the pane has.
        let wellHeight = min(440, max(300, stageHeight - 60))
        let width = rail
            ? min(wideOutput ? budget - 120 : 296, max(120, budget - 48))
            : 190
        // The scrub strip and its gap keep ~30pt of the well for themselves.
        let paneHeight = rail ? (wideOutput ? wellHeight - 70 : stageHeight) : 300
        let paneSize = CollectionMath.fit(
            aspect: canvas.aspect, maxWidth: Double(width), maxHeight: Double(paneHeight))
        // The pane composes the crop, so it keeps its drag — scrubbing the
        // opening lives on the strip below, and only covers the picture while
        // it is being scrubbed. While the ≈ preview covers the pane the crop
        // drag is masked with it: a crop must only ever be composed on the
        // exact frame, never on whatever moment happens to be scrubbed.
        let frame = GuidedScrubOverlay(
            context: scrubContext,
            window: scrubContext?.window(forStretch: 0),
            paneSize: paneSize,
            locate: locateFrame(_:),
            scrubFrame: $scrubFrame,
            locked: $scrubLocked
        ) {
            GuidedCanvasFrame(
                offset: canvasOffsetBinding,
                canvas: canvas,
                sourceSize: model.sourceDisplaySize() ?? .zero,
                anchor: firstFrameAnchor,
                maxWidth: width,
                maxHeight: paneHeight,
                cropLabel: canvasCropLabel,
                showsSourceStrip: rail,
                allowsReposition: scrubFrame == nil)
        }

        if rail && wideOutput {
            // A wide output is a shallow band; the pane holds its own height so
            // the controls below don't jump when the shape changes.
            VStack(spacing: 8) {
                frame
                if canvasCanReposition {
                    Text("Drag the frame to reposition the crop — the strip keeps the rest of the shot in view.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: wellHeight)
            .background(
                LL.ink.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if rail {
            frame
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            VStack(spacing: 6) {
                frame
                if canvasCanReposition {
                    Text("Drag the frame to reposition the crop.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Whether the chosen shape leaves anything to slide along — an as-shot
    /// canvas has no free axis, so there is nothing to drag and nothing to say.
    private var canvasCanReposition: Bool {
        guard let size = model.sourceDisplaySize(),
              let box = CollectionMath.cropBox(
                clipSize: size, canvas: model.effectiveBlendCanvas(), offset: 0.5) else { return false }
        return box.axis == .horizontal
            ? size.width - box.rect.width > 1
            : size.height - box.rect.height > 1
    }

    private var canvasOffsetBinding: Binding<Double> {
        Binding(
            get: { model.blendCanvasOffset },
            set: { newValue in
                touch()
                model.blendCanvasOffset = newValue
            })
    }

    /// The clip's own first frame — the picture every canvas decision is made
    /// against.
    private var firstFrameAnchor: FrameAnchor? {
        guard let location = model.warpFrameLocation(at: 0) else { return nil }
        return FrameAnchor(url: location.url, seconds: location.seconds)
    }

    /// The opening's speed and framing, folded under the canvas question.
    /// `framingInStage` keeps the surface out of this column when the step's
    /// stage is drawing it — one picture, never an inline duplicate.
    @ViewBuilder private func openingControls(framingInStage: Bool) -> some View {
        let stretchRole = role(of: 0)
        VStack(alignment: .leading, spacing: 14) {
            outputRateCard
            speedCard(0, title: stretchRole == .whole ? "Speed" : "Opening")
            punchCard(0, role: stretchRole, framingSurfaceInStage: framingInStage)
        }
    }

    /// The output rate, asked on step one. Every duration in the flow is
    /// output seconds at this rate, and it decides how deep slow motion can
    /// go — a setting that shapes every answer can't hide until the Review
    /// step (it stays there too, easily changed both ends).
    private var outputRateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            LLSectionHeader("Output rate")
            HStack(spacing: 10) {
                Menu {
                    ForEach([24, 25, 30, 50, 60], id: \.self) { fps in
                        Button {
                            touch()
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
                    HStack(spacing: 8) {
                        Text("\(model.outputFPS) fps")
                            .font(.system(size: 13, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Text("Every duration below counts in seconds at this rate — and it sets how deep slow motion can go.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Stretch

    private func role(of index: Int) -> StretchRole {
        let count = warp.stretchCount
        let isMoment = stretches.indices.contains(index) && stretches[index].kind == .moment
        if count == 1 { return .whole }
        if index == 0 { return .opening }
        // A shoot that ends on a burst gets the moment question, not the
        // "ends like it starts" default — the default would silently
        // overwrite its seeded slow motion.
        if isMoment { return .moment }
        if index == count - 1 { return .closing }
        return .between
    }

    private func stretchName(_ index: Int) -> String {
        stretches.stretchName(at: index)
    }

    private func stretchQuestion(_ index: Int) -> String {
        switch role(of: index) {
        case .whole: return "How should the clip play?"
        case .opening: return "How does your clip start?"
        case .moment: return "What happens at \(stretchName(index))?"
        case .between: return "And in between?"
        case .closing: return "How does it end?"
        }
    }

    /// A moment (or the ending) in the rail: the three sections stay at their
    /// natural width and the framing surface takes the room the desktop has.
    @ViewBuilder private func stretchStep(_ index: Int, rail: Bool, contentWidth: CGFloat, stageHeight: CGFloat) -> some View {
        let stretchRole = role(of: index)
        // The answers keep their natural width; the stage takes what's left,
        // and drops under them when that isn't a surface worth composing on.
        let answersWidth = answersColumnWidth(contentWidth)
        let stageWidth = contentWidth - answersWidth - 32
        // Every rail step keeps its stage — the ending's default state shows
        // the frame the clip will end on, not a blank column.
        let sideBySide = rail && stageWidth >= 240

        VStack(alignment: .leading, spacing: 14) {
            question(stretchQuestion(index))

            if sideBySide {
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 14) {
                        stretchAnswers(index, role: stretchRole, framingInStage: true)
                    }
                    .frame(width: answersWidth)
                    framingStage(index, width: stageWidth, height: stageHeight, role: stretchRole)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                stretchAnswers(index, role: stretchRole, framingInStage: false)
                // The column keeps a picture on wide stretches too — the
                // ending's default state shows (and scrubs) the stretch the
                // clip really ends on, arrival ramp included.
                if !(punches.indices.contains(index) ? punches[index] : .none).isPunched {
                    columnWideStage(index, role: stretchRole)
                }
            }
        }
    }

    /// The narrow layout's counterpart of `wideStage`: a compact exact frame
    /// with the scrub strip under it, centred in the column.
    @ViewBuilder private func columnWideStage(_ index: Int, role stretchRole: StretchRole) -> some View {
        let paneSize = CollectionMath.fit(
            aspect: model.effectiveBlendCanvas().aspect, maxWidth: 190, maxHeight: 300)
        VStack(alignment: .leading, spacing: 6) {
            GuidedScrubOverlay(
                context: scrubContext,
                window: scrubContext?.window(forStretch: index),
                paneSize: paneSize,
                locate: locateFrame(_:),
                scrubFrame: $scrubFrame,
                locked: $scrubLocked,
                allowsPaneScrub: true
            ) {
                GuidedCanvasFrame(
                    offset: .constant(model.blendCanvasOffset),
                    canvas: model.effectiveBlendCanvas(),
                    sourceSize: model.sourceDisplaySize() ?? .zero,
                    anchor: frameAnchor(for: index, atEnd: false),
                    maxWidth: paneSize.width,
                    maxHeight: paneSize.height,
                    cropLabel: canvasCropLabel,
                    frameName: stretchName(index),
                    showsSourceStrip: false,
                    allowsReposition: false)
            }
            hint(wideStageCaption(role: stretchRole, onCanvasStep: false))
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// The answers themselves — shared by both layouts; only where the framing
    /// surface sits differs.
    @ViewBuilder private func stretchAnswers(
        _ index: Int, role stretchRole: StretchRole, framingInStage: Bool
    ) -> some View {
        // The transition is always asked — the ramp back out of a moment is
        // part of "what happens next", even when the closing state itself is
        // the default.
        if index > 0 {
            transitionCard(into: index)
        }
        if stretchRole == .closing, !closingOverride {
            closingDefaultCard(index)
        } else {
            speedCard(index, title: "Speed")
            punchCard(index, role: stretchRole, framingSurfaceInStage: framingInStage)
        }
    }

    /// "Ends like it starts" — the closing stretch needs no authoring unless
    /// the user wants it to.
    private func closingDefaultCard(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LL.accent)
                VStack(alignment: .leading, spacing: 2) {
                    // "Like it starts" is only true while the opening really
                    // is wide — a punched opening still releases to wide here.
                    Text(punches.first?.isPunched == true ? "Ends wide" : "Ends like it starts")
                        .font(.system(size: 15, weight: .semibold))
                    // The floored display speed, same as every other surface
                    // — the card must agree with the rail row above it.
                    Text("Wide · \(WarpTimeline.speedLabel(displaySpeed(of: 0))) \(WarpTimeline.speedWord(displaySpeed(of: 0))) — tap Next to keep it.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                touch()
                closingOverride = true
            } label: {
                Text("Change…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LL.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .llCard()
    }

    private func speedCard(_ index: Int, title: String) -> some View {
        // Highlight the chip that renders — a seeded ¼× floored to ½× must
        // light the ½× chip, not leave the row with no answer at all.
        let current = displaySpeed(of: index)
        let chips = GuidedPlanner.gatedSpeedChips(
            forStretchFPS: model.warpStretchFPS(index), outputFPS: model.outputFPS)
        return VStack(alignment: .leading, spacing: 8) {
            LLSectionHeader(title)
            HStack(spacing: 6) {
                ForEach(chips, id: \.speed) { chip in
                    let active = abs(current - chip.speed) < 0.001
                    Button {
                        touch()
                        model.updateWarp { $0.setSpeed(chip.speed, for: index) }
                    } label: {
                        speedChipLabel(
                            title: WarpTimeline.speedLabel(chip.speed),
                            word: chip.word,
                            active: active)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    customSpeedStretch = index
                    showCustomSpeed = true
                } label: {
                    speedChipLabel(title: "···", word: "custom", active: false)
                }
                .buttonStyle(.plain)
            }
            if let share = outputShare(of: index) {
                hint("\(stretchName(index)) becomes ~\(SpeedMath.clipLengthCompact(share)) of the clip.")
            }
            if let gateNote = slowMotionGateNote(for: index, chips: chips) {
                Text(gateNote)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(LL.accent)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Why ¼× isn't on offer, when a burst plainly expects it: slow motion
    /// needs source density against the OUTPUT rate, so a 100 fps burst
    /// supports ¼× at 25 fps out but only ½× at 50. Without this line the
    /// gate reads as a missing chip, not a trade the fps menu controls.
    private func slowMotionGateNote(
        for index: Int, chips: [(speed: Double, word: String)]
    ) -> String? {
        guard stretches.indices.contains(index), stretches[index].kind == .moment,
              chips.first?.speed == 0.5 else { return nil }
        let stretchFPS = model.warpStretchFPS(index)
        let fps = Int(stretchFPS.rounded())
        let base = "¼× wants \(4 * model.outputFPS) fps of footage — this burst is \(fps) fps, "
            + "so at \(model.outputFPS) fps output it tops out at ½×."
        // Only promise the unlock when some offered output rate really opens
        // the gate — the menu bottoms out at 24 fps, so a ~90 fps burst can
        // never reach ¼× and must not be sent chasing it.
        let unlockable = stretchFPS >= 4 * 24 * 0.98
        return unlockable
            ? base + " A lower output rate on the Review step unlocks it."
            : base
    }

    private func speedChipLabel(title: String, word: String, active: Bool) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(active ? LL.amber : .primary)
            Text(word)
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

    /// Output seconds this stretch really contributes, from the compiled
    /// schedule — the same truth the estimate speaks.
    private func outputShare(of index: Int) -> Double? {
        guard let compiled = model.compiledWarp(),
              compiled.stretchFrames.indices.contains(index) else { return nil }
        let seconds = Double(compiled.stretchFrames[index]) / Double(max(1, model.outputFPS))
        return seconds > 0.01 ? seconds : nil
    }

    // MARK: Framing

    private var currentPunch: GuidedPunch {
        switch currentStep {
        case .canvas:
            return punches.first ?? .none
        case .stretch(let index):
            return punches.indices.contains(index) ? punches[index] : .none
        case .review:
            return .none
        }
    }

    /// Changes whenever a framing mode is picked anywhere — the iOS fold cue's
    /// trigger, so the promised box is scrolled to whatever step asked for it.
    private var framingModeSignature: String {
        switch currentPunch {
        case .none: return "\(stepIndex)-none"
        case .still: return "\(stepIndex)-still"
        case .pan: return "\(stepIndex)-pan"
        }
    }

    /// The framing mode chips and, when the mode calls for one, the surface.
    /// On the rail the surface moves out to its own stage beside the answers,
    /// so `framingSurfaceInStage` leaves it out here.
    @ViewBuilder private func punchCard(
        _ index: Int, role stretchRole: StretchRole, framingSurfaceInStage: Bool = false
    ) -> some View {
        let punch = punches.indices.contains(index) ? punches[index] : .none
        VStack(alignment: .leading, spacing: 8) {
            LLSectionHeader("Framing")
            HStack(spacing: 8) {
                framingModeChip("Wide", active: !punch.isPunched) {
                    setPunch(.none, for: index)
                }
                framingModeChip("Punch in", active: {
                    if case .still = punch { return true }
                    return false
                }()) {
                    let entry = punch.entry ?? defaultFraming
                    setPunch(.still(entry), for: index)
                }
                framingModeChip("Punch + pan", active: {
                    if case .pan = punch { return true }
                    return false
                }()) {
                    let entry = punch.entry ?? defaultFraming
                    let exit = punch.exit ?? entry
                    setPunch(.pan(from: entry, to: exit, eased: false), for: index)
                    editingExit = false
                }
            }

            // Only where there is a moment for the punch to belong to — a
            // whole-clip shoot has nowhere else to put one.
            if stretchRole == .opening || stretchRole == .between {
                hint("Usually this stays wide — the punch belongs to the moment.")
            }

            if punch.isPunched, !framingSurfaceInStage {
                momentModeChips(index, punch: punch)
                if previewingMoment {
                    momentPreviewStage(index, width: 340, height: 350)
                } else {
                    framingSurface(index, tallHeight: 320)
                    hint("Drag the box to position, handles or pinch to size — this box is exactly the view that renders."
                        + horizontalPlatformHint)
                    if case .pan = punch {
                        panCurveChips(index, punch: punch)
                    }
                    if let caption = stageCaption(punch, role: stretchRole) {
                        hint(caption)
                    }
                }
            }
        }
    }

    /// The rail's framing stage: the surface with its own controls above it —
    /// Start/End, the pan curve, and the seat reserved for suggested framing.
    /// One stage for every rail step. Punched → the framing surface with its
    /// own controls; wide → the stretch's exact frame at the canvas, so the
    /// stage is never an empty dashed promise and the two states are visibly
    /// the same thing: what this stretch of the clip looks like.
    @ViewBuilder private func framingStage(
        _ index: Int, width: CGFloat, height: CGFloat, role stretchRole: StretchRole
    ) -> some View {
        let punch = punches.indices.contains(index) ? punches[index] : .none
        VStack(alignment: .leading, spacing: 10) {
            if punch.isPunched {
                // The reserved seat takes its own row: a ~260pt stage is the
                // design's own width, and it can't carry the chips and the
                // slot side by side without breaking words in half.
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    suggestFramingSlot
                }
                momentModeChips(index, punch: punch)
                if previewingMoment {
                    momentPreviewStage(index, width: width, height: height)
                } else {
                    panCurveChips(index, punch: punch)
                    framingSurface(index, tallHeight: height)
                        .frame(maxWidth: stageSurfaceWidth(width: width, height: height))
                    hint("Drag to position · handles resize · " + scrollZoomWord)
                    if let caption = stageCaption(punch, role: stretchRole) {
                        hint(caption)
                    }
                }
            } else {
                wideStage(index, width: width, height: height, role: stretchRole)
            }
        }
    }

    /// The moment step's Preview stage: the output through the moving crop —
    /// the punch riding the arriving ramp, the pan (thru or eased, exactly as
    /// authored) and the release, scrubbed on the finished clip's own clock.
    @ViewBuilder private func momentPreviewStage(
        _ index: Int, width: CGFloat, height: CGFloat
    ) -> some View {
        if let context = scrubContext {
            let window = context.window(forStretch: index)
            let paneSize = CollectionMath.fit(
                aspect: model.effectiveBlendCanvas().aspect,
                maxWidth: Double(width), maxHeight: Double(max(120, height - 30)))
            VStack(alignment: .leading, spacing: 8) {
                GuidedScrubDisplay(
                    context: context,
                    frame: scrubFrame ?? Double(window.lowerBound),
                    locate: locateFrame(_:),
                    paneSize: paneSize)
                    .modifier(GuidedPaneScrub(
                        window: window, paneWidth: paneSize.width,
                        scrubFrame: $scrubFrame, locked: $scrubLocked))
                GuidedScrubStrip(
                    context: context, window: window,
                    scrubFrame: $scrubFrame, locked: $scrubLocked, width: paneSize.width)
            }
            hint(momentPreviewHint)
        } else {
            hint("The preview needs the footage's shape — it appears once the probe lands.")
        }
    }

    private var momentPreviewHint: String {
        #if os(macOS)
        return "Hover or drag across the picture to scrub — framing edits stay on the exact-frame box."
        #else
        return "Drag across the picture to scrub — framing edits stay on the exact-frame box."
        #endif
    }

    /// The wide state's stage: the output itself — the stretch's exact frame
    /// cropped to the canvas. On the canvas step the crop is the question, so
    /// it drags and carries the source strip; on later steps it is context
    /// only, and a drag that silently moved the whole clip's crop would be a
    /// trap.
    @ViewBuilder private func wideStage(
        _ index: Int, width: CGFloat, height: CGFloat, role stretchRole: StretchRole
    ) -> some View {
        let onCanvasStep = index == 0 && currentStep == .canvas
        let paneWidth = max(160, width - (onCanvasStep ? 58 : 10))
        // The strip's row comes off the stage's height budget so the whole
        // stage still fits the rail's stage band.
        let paneHeight = max(120, height - 30)
        let paneSize = CollectionMath.fit(
            aspect: model.effectiveBlendCanvas().aspect,
            maxWidth: Double(paneWidth), maxHeight: Double(paneHeight))
        GuidedScrubOverlay(
            context: scrubContext,
            window: scrubContext?.window(forStretch: index),
            paneSize: paneSize,
            locate: locateFrame(_:),
            scrubFrame: $scrubFrame,
            locked: $scrubLocked,
            // Off the canvas step the frame is read-only context, so the
            // picture itself may scrub; the canvas step's pane composes the
            // crop and keeps its drag — its scrub lives on the strip.
            allowsPaneScrub: !onCanvasStep
        ) {
            GuidedCanvasFrame(
                offset: onCanvasStep ? canvasOffsetBinding : .constant(model.blendCanvasOffset),
                canvas: model.effectiveBlendCanvas(),
                sourceSize: model.sourceDisplaySize() ?? .zero,
                anchor: index == 0 ? firstFrameAnchor : frameAnchor(for: index, atEnd: false),
                maxWidth: paneWidth,
                maxHeight: paneHeight,
                cropLabel: canvasCropLabel,
                frameName: index == 0 ? "Frame 1" : stretchName(index),
                showsSourceStrip: onCanvasStep,
                // Masked while the ≈ preview covers the pane — a crop is
                // composed on the exact frame only.
                allowsReposition: onCanvasStep && scrubFrame == nil)
        }
        hint(wideStageCaption(role: stretchRole, onCanvasStep: onCanvasStep))
    }

    private func wideStageCaption(role stretchRole: StretchRole, onCanvasStep: Bool) -> String {
        if onCanvasStep {
            return canvasCanReposition
                ? "This is the output — drag the frame to choose what the crop keeps."
                : "This is the output — the clip keeps the shape it was shot at."
        }
        switch stretchRole {
        case .closing:
            return "Ends wide — the whole canvas."
        default:
            return "Wide — the whole canvas renders. Pick a punch to frame this stretch."
        }
    }

    /// What a punched stage means for the clip — the answer to "does it start
    /// on the full frame and end on the rectangle?", in words, where the
    /// rectangle is.
    private func stageCaption(_ punch: GuidedPunch, role stretchRole: StretchRole) -> String? {
        switch punch {
        case .none:
            return nil
        case .still:
            switch stretchRole {
            case .opening, .whole:
                return "The clip opens in this framing — punched in from the very first frame."
            default:
                return "Arrives with the transition and holds this framing for the whole stretch."
            }
        case .pan:
            switch stretchRole {
            case .opening, .whole:
                return "The clip opens on the start framing and drifts to the end framing across this stretch."
            default:
                return "The pan drifts from the start framing to the end framing across the whole stretch."
            }
        }
    }

    /// The surface's width for its stage: whatever the height budget lets the
    /// source's shape fill, capped by the stage itself.
    private func stageSurfaceWidth(width: CGFloat, height: CGFloat) -> CGFloat {
        guard let size = model.sourceDisplaySize(), size.height > 0 else { return width }
        return min(width, height * size.width / size.height)
    }

    /// Which framing of a pan the surface is editing — or Preview, the third
    /// mode, where the stage shows the output instead of composing. Preview
    /// answers nothing, so it never marks the step touched.
    @ViewBuilder private func momentModeChips(_ index: Int, punch: GuidedPunch) -> some View {
        HStack(spacing: 8) {
            if case .pan = punch {
                framingModeChip("Start framing", active: !previewingMoment && !editingExit) {
                    previewingMoment = false
                    editingExit = false
                }
                framingModeChip("End framing", active: !previewingMoment && editingExit) {
                    previewingMoment = false
                    editingExit = true
                }
            } else {
                framingModeChip("Framing", active: !previewingMoment) {
                    previewingMoment = false
                }
            }
            previewModeChip
        }
    }

    private var previewModeChip: some View {
        Button {
            previewingMoment = true
        } label: {
            Text("Preview")
                .font(.system(size: 13, weight: previewingMoment ? .bold : .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(previewingMoment ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(previewingMoment ? LL.accent : LL.cardBackground, in: Capsule())
                .shadow(color: .black.opacity(previewingMoment ? 0 : 0.06), radius: 1.5, y: 1)
        }
        .buttonStyle(.plain)
    }

    /// How the pan travels between them.
    @ViewBuilder private func panCurveChips(_ index: Int, punch: GuidedPunch) -> some View {
        if case .pan(let from, let to, let eased) = punch {
            HStack(spacing: 8) {
                framingModeChip("Drift thru", active: !eased) {
                    setPunch(.pan(from: from, to: to, eased: false), for: index)
                }
                framingModeChip("Eased", active: eased) {
                    setPunch(.pan(from: from, to: to, eased: true), for: index)
                }
            }
        }
    }

    private func framingSurface(_ index: Int, tallHeight: CGFloat) -> some View {
        GuidedFramingBox(
            framing: framingBinding(for: index),
            aspect: model.effectiveBlendCanvas().aspect,
            sourceSize: model.sourceDisplaySize() ?? .zero,
            anchor: frameAnchor(for: index, atEnd: editingExit),
            deliveryWidth: deliveryWidth,
            tallHeight: tallHeight)
            .id(Self.framingBoxID)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: FramingBoxVisibleKey.self,
                        value: isOnScreen(proxy))
                }
            }
    }

    /// Whether the framing surface is inside the scroll viewport — the fold
    /// cue only earns its place while it isn't.
    private func isOnScreen(_ proxy: GeometryProxy) -> Bool {
        guard viewportHeight > 0 else { return true }
        let frame = proxy.frame(in: .named(Self.scrollSpace))
        return frame.maxY > 40 && frame.minY < viewportHeight - 40
    }

    /// The reserved seat for suggested framing — drawn, inert, and honest
    /// about it until there is a model behind it.
    private var suggestFramingSlot: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
            Text("Suggest framing")
                .font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(Color.secondary.opacity(0.55))
        .padding(.horizontal, 12)
        .frame(height: 26)
        .overlay(
            Capsule().strokeBorder(
                Color.secondary.opacity(0.35),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        .accessibilityHidden(true)
    }

    private var horizontalPlatformHint: String {
        #if os(macOS)
        return " Scroll over the picture to zoom the punch."
        #else
        return ""
        #endif
    }

    private var scrollZoomWord: String {
        #if os(macOS)
        return "scroll wheel zooms about the box"
        #else
        return "pinch to size"
        #endif
    }

    /// Same idiom as `CanvasRatioChips`: selected = white on accent,
    /// unselected = a white card pill. The old secondary-grey unselected fill
    /// disappeared into the mac background, and black-on-accent matched
    /// nothing else in the app.
    private func framingModeChip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            touch()
            action()
        } label: {
            Text(label)
                .font(.system(size: 13, weight: active ? .bold : .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(active ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(active ? LL.accent : LL.cardBackground, in: Capsule())
                .shadow(color: .black.opacity(active ? 0 : 0.06), radius: 1.5, y: 1)
        }
        .buttonStyle(.plain)
    }

    private var defaultFraming: GuidedFraming {
        guard let size = model.sourceDisplaySize() else { return GuidedFraming(z: 2, cx: 0, cy: 0) }
        // Opens at a visible 2× so the box reads as a box, centred on the
        // canvas crop the user has actually chosen.
        let wide = GuidedFraming.wide(
            sourceSize: size,
            aspect: model.effectiveBlendCanvas().aspect,
            canvasOffset: model.blendCanvasOffset)
        return GuidedFraming(z: 2, cx: wide.cx, cy: wide.cy)
    }

    private func setPunch(_ punch: GuidedPunch, for index: Int) {
        guard punches.indices.contains(index) else { return }
        punches[index] = punch
        // Picking a framing mode promises the framing surface — Preview mode
        // must not outlive the answer it was previewing.
        previewingMoment = false
    }

    private func framingBinding(for index: Int) -> Binding<GuidedFraming> {
        Binding(
            get: {
                guard punches.indices.contains(index) else { return defaultFraming }
                let punch = punches[index]
                if editingExit, let exit = punch.exit { return exit }
                return punch.entry ?? defaultFraming
            },
            set: { newValue in
                guard punches.indices.contains(index) else { return }
                switch punches[index] {
                case .none:
                    break
                case .still:
                    punches[index] = .still(newValue)
                case .pan(let from, let to, let eased):
                    punches[index] = editingExit
                        ? .pan(from: from, to: newValue, eased: eased)
                        : .pan(from: newValue, to: to, eased: eased)
                }
            })
    }

    /// The exact frame a framing is composed against: just inside the
    /// stretch, so a start framing shows the incoming file's picture at a
    /// seam, and an end framing the outgoing one.
    private func frameAnchor(for index: Int, atEnd: Bool) -> FrameAnchor? {
        let timeline = warp
        guard index < timeline.stretchCount else { return nil }
        let t = atEnd
            ? max(timeline.bounds[index], timeline.bounds[index + 1] - 0.1)
            : min(timeline.bounds[index + 1], timeline.bounds[index] + 0.06)
        guard let location = model.warpFrameLocation(at: t) else { return nil }
        return FrameAnchor(url: location.url, seconds: location.seconds)
    }

    /// The width the render writes: the canvas-shaped base crop at source
    /// scale — what a punched crop is upscaled back to.
    private var deliveryWidth: Double? {
        guard let size = model.sourceDisplaySize() else { return nil }
        return ReframeVideoCropper.renderSize(
            displaySize: size, aspect: model.effectiveBlendCanvas().aspect)
            .map { Double($0.width) }
    }

    // MARK: Transition

    private func transitionCard(into index: Int) -> some View {
        let seamIndex = index - 1
        let current = warp.seams.indices.contains(seamIndex) ? warp.seams[seamIndex].ramp : .step
        return VStack(alignment: .leading, spacing: 8) {
            LLSectionHeader("How it arrives")
            HStack(spacing: 8) {
                ForEach(WarpTimeline.Seam.Ramp.allCases, id: \.self) { ramp in
                    let active = current == ramp
                    Button {
                        touch()
                        model.updateWarp { $0.setSeam(.init(ramp: ramp), at: seamIndex) }
                    } label: {
                        speedChipLabel(
                            title: ramp == .step ? "Step" : ramp.label,
                            word: ramp == .step ? "hard cut" : "ease",
                            active: active)
                    }
                    .buttonStyle(.plain)
                }
            }
            // The honest sub-state leads: what the ramp really compiled to
            // comes before the promise of what a ramp is for, in the accent
            // the BurstRamp caption uses for a clamped number.
            if let note = seamNote(seamIndex) {
                Text(note)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(LL.accent)
                    .padding(.horizontal, 4)
            }
            hint("One ramp — the speed change and the framing move ride it together, in seconds of the finished clip.")
        }
    }

    /// The seam in one word: "cut", "1s", "0.4s" — the compiled truth,
    /// everywhere the ease is spoken of in strip-sized type.
    private func seamShortLabel(_ seamIndex: Int) -> String {
        let requested = warp.seams.indices.contains(seamIndex)
            ? warp.seams[seamIndex].ramp : .step
        guard requested != .step else { return "cut" }
        if let eases = model.compiledWarp()?.seamEases, eases.indices.contains(seamIndex),
           let ease = eases[seamIndex], ease.isClamped {
            return ease.applied < 0.05 ? "cut" : String(format: "%.1fs", ease.applied)
        }
        return requested.label
    }

    /// The compiled truth about a seam's ease — the number on screen is the
    /// number that renders.
    private func seamNote(_ seamIndex: Int) -> String? {
        guard let eases = model.compiledWarp()?.seamEases,
              eases.indices.contains(seamIndex),
              let ease = eases[seamIndex], ease.isClamped else { return nil }
        let requested = warp.seams.indices.contains(seamIndex)
            ? warp.seams[seamIndex].ramp.label : "requested"
        if ease.applied < 0.05 {
            return "The stretches beside this seam are too short for an ease — it plays as a step."
        }
        return String(
            format: "Capped to %.1fs — only that much of the %@ ease fits between these stretches.",
            ease.applied, requested)
    }

    // MARK: Review

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            question("Ready to create")

            if let context = scrubContext {
                storyboard(context)
            }

            VStack(spacing: 0) {
                ForEach(0..<warp.stretchCount, id: \.self) { index in
                    if index > 0 {
                        reviewTransitionRow(into: index)
                    }
                    reviewStateRow(index)
                }
            }
            .padding(.vertical, 6)
            .llCard()

            estimateLine

            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.red)
            }

            Button {
                syncClosingWithOpeningIfNeeded()
                materialise()
                model.guidedBuilderFocused = false
            } label: {
                Text("Open in the full editor")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LL.accent)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    // MARK: Storyboard

    /// The clip as a contact sheet: each stretch's start and end (a moment
    /// adds its middle, so the pan is visibly travelling), through the crop
    /// that renders there — the last look before the CTA, in pictures
    /// instead of rows. Cells jump back to their step.
    private func storyboard(_ context: GuidedScrubContext) -> some View {
        let cellHeight: CGFloat = 84
        let aspect = model.effectiveBlendCanvas().aspect
        let cellSize = CGSize(
            width: max(34, min(150, cellHeight * CGFloat(aspect))), height: cellHeight)
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy: a many-burst shoot carries dozens of cells, and each
                // decodes a frame — only the ones scrolled into view may cost.
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(0..<warp.stretchCount, id: \.self) { index in
                        if index > 0 {
                            storyboardConnector(index - 1)
                                .padding(.top, 16 + cellHeight / 2 - 6)
                        }
                        storyboardGroup(index, context: context, cellSize: cellSize)
                    }
                }
                .padding(2)
            }
            hint("≈ preview frames — the clip, start to end. Tap a stretch to revisit its step.")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .llCard()
    }

    private func storyboardGroup(
        _ index: Int, context: GuidedScrubContext, cellSize: CGSize
    ) -> some View {
        let range = context.stretchRange(index)
        let isMoment = stretches.indices.contains(index) && stretches[index].kind == .moment
        let punch = punches.indices.contains(index) ? punches[index] : .none
        // A stretch whose framing (or footage) moves earns a middle cell; two
        // frames tell a wide run's whole story.
        let samples: [Int] = {
            let lo = range.lowerBound
            let hi = range.upperBound
            guard isMoment || punch.isPunched, hi > lo + 1 else { return [lo, hi] }
            return [lo, (lo + hi) / 2, hi]
        }()
        let outFps = Double(max(1, model.outputFPS))
        return Button {
            materialise()
            editingExit = false
            stepIndex = min(index, steps.count - 1)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    if isMoment {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(LL.amber)
                    }
                    Text("\(stretchName(index)) · \(WarpTimeline.speedLabel(displaySpeed(of: index)))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    ForEach(Array(samples.enumerated()), id: \.offset) { position, frame in
                        if position > 0 {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.secondary.opacity(0.7))
                        }
                        GuidedStoryboardCell(
                            context: context,
                            frame: frame,
                            locate: locateFrame(_:),
                            cellSize: cellSize,
                            caption: frame == 0
                                ? "0s" : SpeedMath.clipLengthCompact(Double(frame) / outFps))
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stretchName(index)) — back to its step")
    }

    private func storyboardConnector(_ seamIndex: Int) -> some View {
        Text(seamShortLabel(seamIndex))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func reviewStateRow(_ index: Int) -> some View {
        let punch = punches.indices.contains(index) ? punches[index] : .none
        // The compiler floors every speed at one source frame per output
        // frame; say the speed that renders, not the chip that was tapped
        // (an fps change on this screen can raise the floor after the fact).
        // Through displaySpeed so the chip-snap applies — a floored 0.251
        // must read ¼× here exactly as it does in the rail and the strip.
        let speed = displaySpeed(of: index)
        let isMoment = stretches.indices.contains(index) && stretches[index].kind == .moment
        return HStack(spacing: 12) {
            Image(systemName: isMoment ? "bolt.fill" : "arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isMoment ? LL.amber : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(stretchName(index)) · \(WarpTimeline.speedLabel(speed)) \(WarpTimeline.speedWord(speed))")
                    .font(.system(size: 14.5, weight: .semibold))
                Text(framingSummary(punch))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let share = outputShare(of: index) {
                Text("~\(SpeedMath.clipLengthCompact(share))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func framingSummary(_ punch: GuidedPunch) -> String {
        switch punch {
        case .none:
            return canvasCropLabel == nil
                ? "Wide — full frame"
                : "Wide — the \(model.effectiveBlendCanvas().rawValue) crop"
        case .still(let framing):
            return String(format: "Punched %.1f×", framing.z)
        case .pan(let from, let to, let eased):
            return String(
                format: "Pan %.1f× → %.1f× %@", from.z, to.z, eased ? "(eased)" : "(thru)")
        }
    }

    private func reviewTransitionRow(into index: Int) -> some View {
        let seamIndex = index - 1
        let ramp = warp.seams.indices.contains(seamIndex) ? warp.seams[seamIndex].ramp : .step
        let applied: Double? = {
            guard let eases = model.compiledWarp()?.seamEases,
                  eases.indices.contains(seamIndex) else { return nil }
            return eases[seamIndex]?.applied
        }()
        let label: String = {
            if ramp == .step { return "step" }
            if let applied, applied < ramp.seconds - 0.01 {
                return applied < 0.05
                    ? "\(ramp.label) ease — plays as a step"
                    : String(format: "\(ramp.label) ease — plays as ~%.1fs", applied)
            }
            return "\(ramp.label) ease"
        }()
        return HStack(spacing: 12) {
            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.7))
                .frame(width: 22)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
    }

    private var estimateLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Your clip will be")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                resolutionMenu
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
                Text(model.estimatedOutputSeconds().map { seconds in
                    seconds < 9.95
                        ? String(format: "%.1f seconds", seconds)
                        : SpeedMath.clipLength(seconds)
                } ?? "— seconds")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text("· \(warp.stretchCount) \(warp.stretchCount == 1 ? "stretch" : "stretches")")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LL.amber)
            }
            if let note = exportNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Export resolution

    /// What the render writes at full scale: the canvas-shaped base crop at
    /// source pixels — the size every export choice is derived from.
    private var exportFullSize: CGSize? {
        guard let size = model.sourceDisplaySize() else { return nil }
        return ReframeVideoCropper.renderSize(
            displaySize: size, aspect: model.effectiveBlendCanvas().aspect)
    }

    /// Full, 1080 and 720 on the longest edge — only the ones genuinely
    /// smaller than the source, each with its oriented dimensions.
    private var exportChoices: [(edge: Int?, size: CGSize)] {
        guard let full = exportFullSize else { return [] }
        var choices: [(Int?, CGSize)] = [(nil, full)]
        for edge in [1080, 720] {
            if let scaled = ReframeVideoCropper.scaledDown(full, shortEdge: edge) {
                choices.append((edge, scaled))
            }
        }
        return choices
    }

    private func exportLabel(_ size: CGSize) -> String {
        "\(Int(size.width))×\(Int(size.height))"
    }

    @ViewBuilder private var resolutionMenu: some View {
        let choices = exportChoices
        if choices.count > 1 {
            let currentSize = choices.first { $0.edge == model.exportShortEdge }?.size
                ?? choices[0].size
            Menu {
                ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                    Button {
                        model.exportShortEdge = choice.edge
                    } label: {
                        let name = choice.edge.map { "\($0)" } ?? "Full"
                        if choice.edge == model.exportShortEdge {
                            Label("\(name) — \(exportLabel(choice.size))", systemImage: "checkmark")
                        } else {
                            Text("\(name) — \(exportLabel(choice.size))")
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(exportLabel(currentSize))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// The punch-sharpness story for a capped export: a 2× punch on a 4K
    /// source keeps ~1080 px, so a 1080 export resamples it 1:1 — sharp. The
    /// kept pixels and the target are compared on the same (width) axis.
    private var exportNote: String? {
        guard let edge = model.exportShortEdge, let full = exportFullSize,
              let target = ReframeVideoCropper.scaledDown(full, shortEdge: edge) else { return nil }
        let deepest = punches.compactMap { punch -> Double? in
            switch punch {
            case .none: return nil
            case .still(let framing): return framing.z
            case .pan(let from, let to, _): return max(from.z, to.z)
            }
        }.max()
        guard let deepest, deepest > 1.02 else {
            return "Scaled once at export to \(exportLabel(target))."
        }
        let kept = Double(full.width) / deepest
        if kept >= Double(target.width) - 1 {
            return String(
                format: "Your %.1f× punch keeps ~%d px — pixel-sharp at %@.",
                deepest, Int(kept), exportLabel(target))
        }
        return String(
            format: "Your %.1f× punch keeps ~%d px — upscaled to %@.",
            deepest, Int(kept), exportLabel(target))
    }
}

/// Whether the framing surface is inside the scrolling viewport. Absent (no
/// surface on screen at all) reads as visible, so the fold cue only appears
/// when there really is something below the fold.
private struct FramingBoxVisibleKey: PreferenceKey {
    static var defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value && nextValue()
    }
}

/// The rail's push buttons: bottom-trailing, Next carrying the default
/// button's accent fill.
private struct RailButtonStyle: ButtonStyle {
    var isDefault: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: isDefault ? .semibold : .regular))
            .foregroundStyle(isDefault ? Color.white : Color.primary)
            .padding(.horizontal, isDefault ? 26 : 20)
            .frame(height: 30)
            .background {
                if isDefault {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LL.accent.opacity(configuration.isPressed ? 0.75 : 1))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LL.cardBackground.opacity(configuration.isPressed ? 0.7 : 1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
