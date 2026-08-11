import SwiftUI

/// The experimental guided builder — a survey that authors the same
/// `WarpTimeline` + `ReframeTrack` the Adjust editor does, one state at a
/// time: framing belongs to a stretch, transitions ride the seams, welded to
/// the speed ramps that are already there. No free-floating keyframes, no
/// timeline to operate. Everything it writes round-trips into the full
/// editor unchanged.
///
/// One clock on screen: durations here are output (viewer) seconds only.
struct GuidedBuilderView: View {
    @EnvironmentObject var model: AppModel

    private enum Step: Equatable {
        case canvas
        case stretch(Int)
        case review
    }

    private enum StretchRole {
        case whole, opening, moment, between, closing
    }

    @State private var stepIndex = 0
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

    private var warp: WarpTimeline { model.activeWarp() }
    private var stretches: [BlendStretch] { model.blendStretches() }

    private var steps: [Step] {
        var list: [Step] = [.canvas]
        for index in 0..<max(1, warp.stretchCount) {
            list.append(.stretch(index))
        }
        list.append(.review)
        return list
    }

    private var currentStep: Step {
        let all = steps
        return all[min(max(0, stepIndex), all.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            FlowHeader(title: "Guided clip", onBack: goBack) {
                Text("EXPERIMENTAL")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.5)
                    .foregroundStyle(LL.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(LL.accent.opacity(0.12), in: Capsule())
            }

            stepDots
                .padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    stepContent
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }

            bottomBar
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .onAppear {
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
        }
        .onChange(of: warp.stretchCount) { count in
            guard seeded, punches.count != count else { return }
            // A late metadata probe can re-shape a marker timeline mid-flow;
            // keep the answers aligned with the stretches they belong to.
            if punches.count < count {
                punches += Array(repeating: .none, count: count - punches.count)
            } else {
                punches = Array(punches.prefix(count))
            }
        }
        .sheet(isPresented: $showCustomSpeed) {
            CustomSpeedSheet(stretch: customSpeedStretch)
                .environmentObject(model)
        }
    }

    // MARK: - Navigation

    private func goBack() {
        if stepIndex > 0 {
            materialise()
            editingExit = false
            stepIndex -= 1
        } else {
            model.reset()
        }
    }

    private func goNext() {
        // Leaving the opening step keeps the closing stretch on the opening's
        // state until the user overrides it — "ends like it starts". Only for
        // a closing BASE run: a shoot that ends on a recorded moment keeps
        // its seeded slow motion.
        if case .stretch(0) = currentStep, warp.stretchCount > 1, !closingOverride,
           role(of: warp.stretchCount - 1) == .closing,
           let opening = warp.speeds.first {
            model.updateWarp { $0.setSpeed(opening, for: $0.stretchCount - 1) }
        }
        materialise()
        editingExit = false
        if stepIndex < steps.count - 1 {
            stepIndex += 1
        }
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
            sourceSize: size)
        // Key ids are fresh per materialisation, so `==` never matches —
        // compare content, or every step navigation pushes a dead undo step.
        guard !GuidedPlanner.tracksEquivalent(track, model.activeReframe()) else { return }
        model.updateReframe { $0 = track }
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
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(LL.screenBackground)
    }

    private var ctaTitle: String {
        if let seconds = model.estimatedOutputSeconds() {
            return "Create \(SpeedMath.clipLength(seconds)) clip"
        }
        return "Create clip"
    }

    // MARK: - Steps

    @ViewBuilder private var stepContent: some View {
        switch currentStep {
        case .canvas:
            canvasStep
        case .stretch(let index):
            stretchStep(index)
        case .review:
            reviewStep
        }
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

    // MARK: Canvas

    private var canvasStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            question("What shape should the clip be?")
            CanvasRatioChips(selected: model.effectiveBlendCanvas()) { ratio in
                model.blendCanvasRatio = ratio
            }
            hint(canvasConsequence)
            hint("Asked first because every framing is composed against this shape.")
        }
    }

    private var canvasConsequence: String {
        let canvas = model.effectiveBlendCanvas()
        guard let size = model.sourceDisplaySize() else { return "\(canvas.rawValue)" }
        if let crop = VideoCanvasCropper.cropSize(displaySize: size, canvas: canvas) {
            return "\(canvas.rawValue) — crops to \(Int(crop.width))×\(Int(crop.height))"
        }
        return "\(canvas.rawValue) — as shot"
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

    @ViewBuilder private func stretchStep(_ index: Int) -> some View {
        let stretchRole = role(of: index)
        question(stretchQuestion(index))

        // The transition is always asked — the ramp back out of a moment is
        // part of "what happens next", even when the closing state itself is
        // the default.
        if index > 0 {
            transitionCard(into: index)
        }
        if stretchRole == .closing, !closingOverride {
            closingDefaultCard(index)
        } else {
            speedCard(index)
            punchCard(index, role: stretchRole)
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
                    Text("Wide · \(WarpTimeline.speedLabel(warp.speeds.first ?? 1)) \(WarpTimeline.speedWord(warp.speeds.first ?? 1)) — tap Next to keep it.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Button {
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

    private func speedCard(_ index: Int) -> some View {
        let current = warp.speeds.indices.contains(index) ? warp.speeds[index] : 1
        let chips = GuidedPlanner.gatedSpeedChips(
            forStretchFPS: model.warpStretchFPS(index), outputFPS: model.outputFPS)
        return VStack(alignment: .leading, spacing: 8) {
            LLSectionHeader("Speed")
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
                    customSpeedStretch = index
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
            if let share = outputShare(of: index) {
                hint("\(stretchName(index)) becomes ~\(SpeedMath.clipLengthCompact(share)) of the clip.")
            }
        }
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

    @ViewBuilder private func punchCard(_ index: Int, role stretchRole: StretchRole) -> some View {
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

            if stretchRole == .opening || stretchRole == .between {
                hint("Usually this stays wide — the punch belongs to the moment.")
            }

            if punch.isPunched {
                if case .pan = punch {
                    HStack(spacing: 8) {
                        framingModeChip("Start framing", active: !editingExit) { editingExit = false }
                        framingModeChip("End framing", active: editingExit) { editingExit = true }
                    }
                }

                GuidedFramingBox(
                    framing: framingBinding(for: index),
                    aspect: model.effectiveBlendCanvas().aspect,
                    sourceSize: model.sourceDisplaySize() ?? .zero,
                    anchor: frameAnchor(for: index, atEnd: editingExit),
                    deliveryWidth: deliveryWidth)

                hint("Drag the box to position, handles or pinch to size — this box is exactly the view that renders."
                    + horizontalPlatformHint)

                if case .pan(let from, let to, let eased) = punch {
                    HStack(spacing: 8) {
                        framingModeChip("Drift thru", active: !eased) {
                            setPunch(.pan(from: from, to: to, eased: false), for: index)
                        }
                        framingModeChip("Eased", active: eased) {
                            setPunch(.pan(from: from, to: to, eased: true), for: index)
                        }
                    }
                    hint("The pan drifts from the start framing to the end framing across the whole stretch.")
                }
            }
        }
    }

    private var horizontalPlatformHint: String {
        #if os(macOS)
        return " Scroll over the picture to zoom the punch."
        #else
        return ""
        #endif
    }

    private func framingModeChip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: active ? .bold : .regular))
                .foregroundStyle(active ? .black : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(active ? LL.accent : Color.secondary.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var defaultFraming: GuidedFraming {
        guard let size = model.sourceDisplaySize() else { return GuidedFraming(z: 2, cx: 0, cy: 0) }
        // Opens at a visible 2× so the box reads as a box, centred; the user
        // takes it from there.
        return GuidedFraming(z: 2, cx: Double(size.width) / 2, cy: Double(size.height) / 2)
    }

    private func setPunch(_ punch: GuidedPunch, for index: Int) {
        guard punches.indices.contains(index) else { return }
        punches[index] = punch
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
                        model.updateWarp { $0.setSeam(.init(ramp: ramp), at: seamIndex) }
                    } label: {
                        VStack(spacing: 1) {
                            Text(ramp == .step ? "Step" : ramp.label)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(active ? LL.amber : .primary)
                            Text(ramp == .step ? "hard cut" : "ease")
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
            }
            hint("One ramp — the speed change and the framing move ride it together, in seconds of the finished clip.")
            if let note = seamNote(seamIndex) {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LL.accent)
                    .padding(.horizontal, 4)
            }
        }
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
    }

    private func reviewStateRow(_ index: Int) -> some View {
        let punch = punches.indices.contains(index) ? punches[index] : .none
        let chosen = warp.speeds.indices.contains(index) ? warp.speeds[index] : 1
        // The compiler floors every speed at one source frame per output
        // frame; say the speed that renders, not the chip that was tapped
        // (an fps change on this screen can raise the floor after the fact).
        let speed = max(chosen, Double(model.outputFPS) / max(1, model.warpStretchFPS(index)))
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
            return "Wide — full frame"
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
