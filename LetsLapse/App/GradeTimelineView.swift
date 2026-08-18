import SwiftUI

/// The grade timeline: the one component that turns the editors from "grade
/// this clip" into "grade this moment of this clip".
///
/// It sits between the media and the controls, because that is what it is about
/// — which frame you are looking at, and therefore which frame the sliders
/// under it are moving. A scrub bar, the moments that carry a grade as dots on
/// it, and a play control for confirming that the ease lands.
///
/// Nothing here decides anything. It reports a position, a tap on a moment and
/// a request to delete one; the editor that owns the grade does the rest. The
/// same view serves the interval editor (where the axis is elapsed capture
/// time) and the video editor (where it is the movie's own clock) — the axis is
/// a label closure, so neither has to teach this view about its clock.
///
/// Drawn from the Claude Design pass *"Keyframed editing for interval & video
/// shoots"*: `1a`/`1b` for placement, `1d` for the states, scrubber option
/// `1f-A` (hairline track, play control kept) and slider treatment `1e-A` (the
/// amber diamond, which lives in `PhotoAdjustmentsPanel`). The design draws a
/// light sheet; the shipped editors are black on iOS and light on the Mac, so
/// the roles are taken from the design and the values from the surface —
/// `Color.primary` for rail and playhead, amber over dark and accent on white
/// for the moments, per the design system's "highlights over dark" rule.
struct GradeTimelineView: View {
    /// The playhead, 0…1 of the source. A binding because a drag moves it
    /// continuously and the owner re-renders from it.
    @Binding var position: Double
    /// True while a drag is live, so the owner can drop its animations and
    /// render at whatever rate it can keep up with.
    @Binding var isScrubbing: Bool
    let keyframes: [GradeKeyframe]
    /// Text for a position — elapsed capture time on an interval shoot, running
    /// time on a movie. Used for the travelling bubble and both end labels.
    let label: (Double) -> String

    var isPlaying: Bool = false
    /// The play control is part of scrubber option A: without it the only way
    /// to confirm an ease lands is to leave the screen. Hidden where there is
    /// nothing to play.
    var showsPlayControl: Bool = true
    /// The tighter metrics the landscape/rail layout uses.
    var compact: Bool = false
    /// Amber over the dark editors, the app accent on the light Mac window.
    var accent: Color = LL.amber

    var onPlayToggle: () -> Void = {}
    /// Fired continuously while scrubbing, and once when a moment is tapped.
    var onScrub: (Double) -> Void = { _ in }
    /// Fired when a scrub finishes, after any snap to a nearby moment.
    var onScrubEnd: () -> Void = {}
    var onDelete: (GradeKeyframe) -> Void = { _ in }

    /// The moment whose delete affordance is showing, from a long press.
    @State private var deleteTarget: GradeKeyframe?
    /// The moment a press landed on. A press that starts on one doesn't scrub —
    /// it selects that moment on release, or offers to delete it if the finger
    /// stays down.
    @State private var pressedKeyframe: GradeKeyframe?
    @State private var pressMoved = false
    @State private var longPress: Task<Void, Never>?

    // MARK: - Metrics
    //
    // Points, straight off the design. The compact column is the landscape
    // layout's, where the strip shares the media pane's width rather than the
    // whole screen's.

    private var controlSize: CGFloat { compact ? 26 : 30 }
    private var trackHeight: CGFloat { compact ? 26 : 30 }
    private var railThickness: CGFloat { 3 }
    private var dotSize: CGFloat { 11 }
    private var snappedDotSize: CGFloat { 15 }
    private var playheadHeight: CGFloat { compact ? 20 : 22 }
    private var gap: CGFloat { 12 }
    /// How close a tap has to land to count as a tap on that moment.
    private var dotHitRadius: CGFloat { 15 }
    private var endLabelFont: CGFloat { compact ? 10 : 10.5 }
    private var labelRowHeight: CGFloat { 13 }

    /// The strip's own height. Fixed, so the media above it never moves when a
    /// moment is added, selected or long-pressed.
    var height: CGFloat { trackHeight + 2 + labelRowHeight }

    /// The dark chrome both floating bubbles are painted in — the camera
    /// screen's pill grey rather than the design's near-black, which would
    /// vanish into the black editor it has to float over.
    private var chrome: Color { Color(red: 43 / 255, green: 43 / 255, blue: 46 / 255) }

    var body: some View {
        GeometryReader { proxy in
            let lead = showsPlayControl ? controlSize + gap : 0
            let trackWidth = max(1, proxy.size.width - lead)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: gap) {
                    if showsPlayControl { playControl }
                    track(width: trackWidth)
                }
                endLabels
            }
            // Both float above the strip, so they live here rather than inside
            // the track — outside the scrub gesture's reach, and outside the
            // bounds it hit-tests.
            .overlay(alignment: .top) {
                bubble
                    .offset(x: floatOffset(position, lead: lead,
                                           trackWidth: trackWidth, total: proxy.size.width,
                                           inset: 0.07),
                            y: -8)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if let deleteTarget {
                    deleteAffordance(for: deleteTarget)
                        .offset(x: floatOffset(deleteTarget.position, lead: lead,
                                               trackWidth: trackWidth, total: proxy.size.width,
                                               inset: 0.12),
                                y: -36)
                }
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: keyframes.map(\.id))
    }

    /// How far a top-centred float has to move to sit over `position`, held
    /// away from both ends so it never hangs off the strip.
    private func floatOffset(
        _ position: Double, lead: CGFloat, trackWidth: CGFloat,
        total: CGFloat, inset: Double
    ) -> CGFloat {
        let clamped = min(max(position, inset), 1 - inset)
        return lead + trackWidth * CGFloat(clamped) - total / 2
    }

    // MARK: - Play

    private var playControl: some View {
        Button(action: onPlayToggle) {
            ZStack {
                Circle().fill(LL.cardBackground)
                    .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: compact ? 11 : 12.5, weight: .semibold))
                    .foregroundStyle(accent)
                    // A play triangle's own bearing leaves it looking left of
                    // centre in a circle; nudge it back.
                    .offset(x: isPlaying ? 0 : 1)
            }
            .frame(width: controlSize, height: controlSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause preview" : "Play preview")
    }

    // MARK: - Track

    private func track(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(Color.primary.opacity(0.18))
                .frame(width: width, height: railThickness)
                .offset(y: (trackHeight - railThickness) / 2)
            // The playhead under the moments, per the design's own z-order: a
            // moment the playhead is standing on has to read as one mark, not
            // as a dot with a line drawn through it.
            playhead(width: width)
            ForEach(keyframes) { keyframe in
                dot(keyframe, width: width)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: width, height: trackHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(scrubGesture(width: width))
        .accessibilityElement()
        .accessibilityLabel("Timeline position")
        .accessibilityValue(label(position))
        .accessibilityAdjustableAction { direction in
            let step = 0.02
            let next = direction == .increment
                ? min(1, position + step) : max(0, position - step)
            position = next
            onScrub(next)
            onScrubEnd()
        }
    }

    private func x(_ position: Double, width: CGFloat) -> CGFloat {
        width * CGFloat(min(max(position, 0), 1))
    }

    private func isSnapped(_ keyframe: GradeKeyframe) -> Bool {
        abs(keyframe.position - position) < GradeTimeline.snapTolerance
    }

    /// A moment. It swells and swaps its ring for a white one when the playhead
    /// is standing on it, which is the only "selected" state the screen has —
    /// the sliders below are then editing *this* moment rather than making a
    /// new one.
    private func dot(_ keyframe: GradeKeyframe, width: CGFloat) -> some View {
        let snapped = isSnapped(keyframe)
        let size = snapped ? snappedDotSize : dotSize
        return ZStack {
            Circle().fill(accent)
            Circle().strokeBorder(snapped ? Color.white : LL.accent, lineWidth: 2)
            if snapped {
                Circle().strokeBorder(LL.accent, lineWidth: 1.5).padding(-1.5)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: snapped ? .black.opacity(0.3) : .clear, radius: 2, y: 1)
        .position(x: x(keyframe.position, width: width), y: trackHeight / 2)
        .animation(.easeOut(duration: 0.15), value: snapped)
        .accessibilityLabel("Keyframe at \(label(keyframe.position))")
    }

    private func playhead(width: CGFloat) -> some View {
        Capsule()
            .fill(Color.primary)
            .frame(width: 3, height: playheadHeight)
            .position(x: x(position, width: width), y: trackHeight / 2)
            .animation(isScrubbing ? nil : .easeOut(duration: 0.15), value: position)
    }

    /// The travelling read-out — elapsed source time, following the playhead.
    private var bubble: some View {
        Text(label(position))
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(chrome.opacity(0.9)))
            .fixedSize()
            .animation(isScrubbing ? nil : .easeOut(duration: 0.15), value: position)
    }

    /// Long-press delete. A bubble rather than a swipe or an X on the dot: the
    /// moments are 11pt and sit on a track people are dragging, so a
    /// destructive control has to be somewhere a scrub can't reach by accident.
    private func deleteAffordance(for keyframe: GradeKeyframe) -> some View {
        VStack(spacing: 0) {
            Text("Delete Keyframe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.37))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(chrome))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 4)
            DownCaret()
                .fill(chrome)
                .frame(width: 12, height: 6)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture {
            onDelete(keyframe)
            deleteTarget = nil
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
        .accessibilityLabel("Delete keyframe at \(label(keyframe.position))")
    }

    // MARK: - Gesture

    /// One gesture for the whole strip, because the moments sit *on* the scrub
    /// track and a second recognizer over them would fight it.
    ///
    /// Where the finger lands decides what the gesture is. On a moment it is a
    /// selection — press and release to stand the playhead exactly on it, press
    /// and hold to be offered its delete — and it deliberately does not scrub,
    /// so the moment you were aiming at can't slide out from under you.
    /// Anywhere else it is a scrub.
    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                if pressedKeyframe == nil, !isScrubbing {
                    if let hit = nearestKeyframe(toX: value.startLocation.x, width: width),
                       abs(x(hit.position, width: width) - value.startLocation.x) <= dotHitRadius {
                        pressedKeyframe = hit
                        pressMoved = false
                        armLongPress(for: hit)
                        return
                    }
                    isScrubbing = true
                    if deleteTarget != nil {
                        withAnimation(.easeOut(duration: 0.16)) { deleteTarget = nil }
                    }
                }
                if pressedKeyframe != nil {
                    if abs(value.translation.width) > 6 {
                        pressMoved = true
                        longPress?.cancel()
                    }
                    return
                }
                let next = Double(min(max(value.location.x, 0), width) / width)
                position = next
                onScrub(next)
            }
            .onEnded { value in
                longPress?.cancel()
                let pressed = pressedKeyframe
                let moved = pressMoved
                pressedKeyframe = nil
                pressMoved = false
                if let pressed {
                    guard !moved, deleteTarget == nil else { return }
                    position = pressed.position
                    onScrub(pressed.position)
                    onScrubEnd()
                    return
                }
                guard isScrubbing, width > 0 else { return }
                isScrubbing = false
                // Release-snap is looser than the "am I standing on it" test,
                // so letting go near a moment lands on it rather than a frame
                // away — where the sliders would silently make a new moment
                // instead of editing the one that was aimed at.
                var landed = Double(min(max(value.location.x, 0), width) / width)
                if let near = keyframes.min(by: {
                    abs($0.position - landed) < abs($1.position - landed)
                }), abs(near.position - landed) < 0.018 {
                    landed = near.position
                }
                position = landed
                onScrub(landed)
                onScrubEnd()
            }
    }

    private func nearestKeyframe(toX px: CGFloat, width: CGFloat) -> GradeKeyframe? {
        keyframes.min {
            abs(x($0.position, width: width) - px) < abs(x($1.position, width: width) - px)
        }
    }

    private func armLongPress(for keyframe: GradeKeyframe) {
        longPress?.cancel()
        longPress = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.16)) { deleteTarget = keyframe }
        }
    }

    // MARK: - End labels

    private var endLabels: some View {
        HStack(spacing: 0) {
            Text(label(0))
            Spacer(minLength: 0)
            Text(label(1))
        }
        .font(.system(size: endLabelFont))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(height: labelRowHeight)
        .padding(.leading, showsPlayControl ? controlSize + gap : 0)
    }
}

/// The delete bubble's caret, pointing at the moment it is offering to remove.
private struct DownCaret: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Clock

/// Turns a 0…1 position into the text the timeline shows.
///
/// Two clocks, because the two editors are measuring different things: an
/// interval shoot's axis is the hours it was *captured* over (a 2 h 14 min
/// sunset), while a movie's is the seconds it *plays* for. Both come out as
/// elapsed time from the start of the source, which is what makes a keyframe's
/// position sayable out loud.
enum GradeTimelineClock {
    /// `h:mm:ss` for a source an hour or longer — an interval shoot, always —
    /// and `m:ss` below it, so a 40-second clip doesn't read as `0:00:40`.
    ///
    /// The choice is made from the whole `span`, never from the value being
    /// formatted: the strip shows three times at once, and a head label reading
    /// `0:00` beside a tail label reading `2:14:00` looks like two clocks.
    static func label(seconds: Double, span: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        guard span < 3600 else { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes + hours * 60, secs)
    }

    /// A label closure over a known span.
    static func labeller(duration: Double) -> (Double) -> String {
        { position in
            label(seconds: duration * min(max(position, 0), 1), span: duration)
        }
    }

    /// The fallback for a shoot that never recorded a clock: count frames
    /// rather than invent seconds the sidecar doesn't have.
    static func frameLabeller(count: Int) -> (Double) -> String {
        { position in
            let index = Int((Double(max(count - 1, 0)) * min(max(position, 0), 1)).rounded()) + 1
            return "\(index)"
        }
    }
}
