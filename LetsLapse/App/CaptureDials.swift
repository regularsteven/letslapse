import SwiftUI
import LetsLapseKit

// The capture screen's dial menus, extracted from `CaptureView` and made
// `Equatable` so they re-render only when a value they draw actually moves.
//
// Why they are not computed properties on `CaptureView` any more: on iOS a
// SwiftUI `Menu` presents a live `UIMenu`, and re-evaluating the body that owns
// it re-emits its children — which UIKit cross-fades. `CaptureView`'s body is
// invalidated by ~40 observers (the camera, the model, the motion monitor, the
// Watch link, device rotation), so an open EVERY/BLEND menu visibly pulsed
// while anything else on the screen ticked. Measured on an iPhone 17 Pro
// simulator with the body forced to 2 Hz: the menu's pixels changed on every
// pass (max channel delta 53) while the rest of the screen stayed bit-identical.
//
// macOS never showed it — `NSMenu` snapshots its items at open time and tracks
// in its own event loop — but the extraction is unconditional: the churn is
// wasted work on both platforms.
//
// `Binding`s and closures alone would NOT fix this. SwiftUI can only skip a
// child's `body` when it can prove the child unchanged, and closures capture
// context it cannot compare — so the structural check fails and the body runs
// anyway. `EquatableView` (via `.equatable()` at the call site) is the lever:
// the hand-written `==` below compares only the plain values these views draw.
//
// NB the closures are deliberately excluded from `==`, so a skipped update
// leaves the *previous* closures in place. They are safe because they only
// write `@State` on `CaptureView`, which resolves through its storage box
// rather than the captured struct copy. Do not add a closure here that *reads*
// a non-`@State` property of `CaptureView`.

/// The chip that opens a dial menu — the label half of every `Menu` below.
struct PickerMenuLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Capsule())
    }
}

/// The small caps label ahead of each dial ("EVERY", "BLEND").
private struct DialCaption: View {
    let text: String

    var body: some View {
        // fixedSize keeps ViewThatFits honest: a wrappable label would let the
        // one-line layout "fit" by folding the word in half.
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .kerning(0.8)
            .foregroundStyle(.white.opacity(0.45))
            .fixedSize()
    }
}

/// Interval's dials — spacing, mode and blend depth — plus the
/// trailing caption. One line where it fits (Mac, landscape phones/iPads);
/// portrait iPhones fall back to two stacked lines.
///
/// ```
/// EVERY:  0.5s · 1s · 3s · 5s · 10s … Auto
/// MODE:   Off · Holy Grail · Scanner
/// BLEND:  Off · 3 · 5 · 10 … Safe · Psycho
/// ```
///
/// BLEND is how many frames are averaged into each output image (the motion
/// blur is made as the shoot runs). A Holy Grail shoot with BLEND on is the
/// combination that feature exists for — a day-to-night timelapse whose frames
/// already carry their blur.
///
/// **MODE was called RAMP until Scanner arrived**, and the rename is not
/// cosmetic: only one of the two things it now selects is a ramp. What the dial
/// actually picks is *which decision the shoot takes away from the timer* —
/// Holy Grail takes exposure, Scanner takes the firing itself.
///
/// **EVERY and MODE are not independent, and the dial says so rather than
/// letting the pair go invalid:**
///
/// - **Auto appears only when MODE isn't Off** (see `everyPicker`).
/// - **Scanner requires Auto**, because the scene sets the spacing. The fixed
///   values stay visible but disabled under a header saying why: a greyed row
///   that explains itself teaches the model, where a missing row just looks
///   broken.
/// - **Holy Grail works either way.** On Auto the ramp paces itself; on a fixed
///   value the user has pinned the floor and the ramp manages exposure above
///   it. Both are deliberate, so neither is disabled.
struct IntervalDialsRow: View, Equatable {
    let intervalSeconds: Double
    let intervalOptions: [Double]
    /// EVERY is on Auto — the mode paces the shoot itself.
    let intervalIsAuto: Bool
    let blendDepth: BlendDepth
    let safeDepthAvailable: Bool
    let captionText: String?
    /// Whether this platform has a MODE dial at all — the Mac doesn't (no
    /// manual exposure API, no RAW), so it simply isn't drawn there.
    let modeAvailable: Bool
    let intervalMode: IntervalCaptureMode
    let onSelectInterval: (Double) -> Void
    let onSelectAutoInterval: () -> Void
    let onSelectFixedBlend: (Int) -> Void
    let onSelectPsycho: () -> Void
    let onSelectSafe: () -> Void
    let onSelectMode: (IntervalCaptureMode) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.intervalSeconds == rhs.intervalSeconds
            && lhs.intervalIsAuto == rhs.intervalIsAuto
            && lhs.blendDepth == rhs.blendDepth
            && lhs.safeDepthAvailable == rhs.safeDepthAvailable
            && lhs.captionText == rhs.captionText
            && lhs.modeAvailable == rhs.modeAvailable
            && lhs.intervalMode == rhs.intervalMode
            && lhs.intervalOptions == rhs.intervalOptions
    }

    /// Scanner owns the spacing outright; the fixed pills grey out under it.
    private var fixedIntervalsDisabled: Bool { intervalMode.requiresAutoInterval }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                everyPicker
                if modeAvailable { modePicker }
                blendPicker
                caption
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    everyPicker
                    if modeAvailable { modePicker }
                }
                HStack(spacing: 8) {
                    blendPicker
                    caption
                }
            }
        }
    }

    /// The MODE dial. "Off" is the plain timer shoot; "Holy Grail" hands
    /// shutter and ISO to the ramp so a shoot can run from daylight into night
    /// in one take; "Scanner" hands the shutter itself to the scene.
    private var modePicker: some View {
        HStack(spacing: 8) {
            DialCaption(text: "MODE")
            Menu {
                ForEach(IntervalCaptureMode.allCases) { option in
                    Button {
                        onSelectMode(option)
                    } label: {
                        if intervalMode == option {
                            Label(option.menuLabel, systemImage: "checkmark")
                        } else {
                            Text(option.menuLabel)
                        }
                    }
                }
            } label: {
                PickerMenuLabel(text: intervalMode.chipLabel)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var everyPicker: some View {
        HStack(spacing: 8) {
            DialCaption(text: "EVERY")
            Menu {
                // The inline reason, at the point of interaction: a header
                // above the disabled rows, so the greying explains itself
                // where it is met and not only in the caption below.
                if fixedIntervalsDisabled {
                    Section("Interval set by the scene") {
                        fixedIntervalButtons
                    }
                } else {
                    fixedIntervalButtons
                }
                // Auto is offered only by a mode that can pace itself. With
                // MODE Off there is nothing for it to mean, so rather than
                // showing a choice that then has to be rejected — or silently
                // changing MODE under the user's hand, which is worse — the
                // row simply isn't there.
                if intervalMode.supportsAutoInterval {
                    Divider()
                    Button {
                        onSelectAutoInterval()
                    } label: {
                        if intervalIsAuto {
                            Label(autoMenuLabel, systemImage: "checkmark")
                        } else {
                            Text(autoMenuLabel)
                        }
                    }
                }
            } label: {
                PickerMenuLabel(text: intervalIsAuto ? "Auto" : Self.intervalLabel(intervalSeconds))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// What Auto means depends on who is doing the pacing, so the row says
    /// which rather than leaving the user to guess.
    private var autoMenuLabel: String {
        switch intervalMode {
        case .scanner: return "Auto · when the scene stills"
        case .holyGrail: return "Auto · the ramp paces itself"
        case .off: return "Auto"
        }
    }

    @ViewBuilder
    private var fixedIntervalButtons: some View {
        ForEach(intervalOptions, id: \.self) { seconds in
            Button {
                onSelectInterval(seconds)
            } label: {
                if !intervalIsAuto && intervalSeconds == seconds {
                    Label(Self.intervalLabel(seconds), systemImage: "checkmark")
                } else {
                    Text(Self.intervalLabel(seconds))
                }
            }
            .disabled(fixedIntervalsDisabled)
        }
    }

    /// Every fixed count and both adaptive depths — except under Scanner,
    /// where Phase 1 captures exactly one frame per pose and there is no
    /// window to average over. Greyed with a header saying so, the same
    /// treatment the fixed intervals get: a shoot whose dial claims a 10-frame
    /// blend and then writes single frames would be lying, and hiding the dial
    /// would just make Scanner look like a different screen.
    private var blendPicker: some View {
        HStack(spacing: 8) {
            DialCaption(text: "BLEND")
            Menu {
                if intervalMode == .scanner {
                    Section("One frame per pose in Scanner") { blendOptionButtons }
                } else {
                    blendOptionButtons
                }
            } label: {
                PickerMenuLabel(text: intervalMode == .scanner ? "Off" : menuLabel)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var blendOptionButtons: some View {
        Group {
            ForEach(BlendDepth.fixedOptions, id: \.frames) { option in
                Button {
                    onSelectFixedBlend(option.frames)
                } label: {
                    if blendDepth == .fixed(option.frames) {
                        Label(Self.blendOptionLabel(option), systemImage: "checkmark")
                    } else {
                        Text(Self.blendOptionLabel(option))
                    }
                }
            }
            Divider()
            Button {
                onSelectPsycho()
            } label: {
                if blendDepth == .unthrottled {
                    Label("Psycho · as many as it can", systemImage: "checkmark")
                } else {
                    Text("Psycho · as many as it can")
                }
            }
            // Safe without a matching profile would be a guess; it stays
            // disabled until Psycho runs have taught one for this
            // pipeline, interval and thermal state.
            Button {
                onSelectSafe()
            } label: {
                if blendDepth == .throttled {
                    Label("Safe · learned limit", systemImage: "checkmark")
                } else {
                    Text("Safe · learned limit")
                }
            }
            .disabled(!safeDepthAvailable)
        }
        // Scanner takes one frame per pose, so none of the above is a choice
        // it can honour.
        .disabled(intervalMode == .scanner)
    }

    /// The trailing caption only makes sense while blending; the adaptive
    /// depths say what drives their count instead.
    @ViewBuilder
    private var caption: some View {
        if let captionText {
            Text(captionText)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private var menuLabel: String {
        switch blendDepth {
        case .fixed(1): return "Off"
        case .fixed(let frames): return "\(frames) frames"
        case .unthrottled: return "Psycho"
        case .throttled: return "Safe"
        }
    }

    private static func blendOptionLabel(_ option: (frames: Int, label: String)) -> String {
        option.frames == 1 ? option.label : "\(option.frames) frames · \(option.label)"
    }

    private static func intervalLabel(_ seconds: Double) -> String {
        seconds == floor(seconds) ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
    }
}

/// Scanner's paper dial: what shape the flat thing in front of the camera
/// really is, for the perspective correction taken later.
///
/// ```
/// PAPER:  Auto · A4 · Letter · 4×6 · Square
/// ```
///
/// A pill row rather than a menu, and it is the only dial on this screen that
/// is: the values are few, short and worth comparing at a glance, and unlike
/// EVERY or BLEND this one is set once for a stack of documents rather than
/// tuned between shots.
///
/// **It changes nothing about the capture.** Every frame is shot and written
/// exactly the same way whatever this says; the hint is recorded intent, spent
/// at export when the corners in the sidecar are turned into a rectified sibling
/// (see `PerspectiveCorrector`). Auto is the default and means "whatever shape
/// the detected quad implies" — the honest answer for an object whose
/// proportions nobody has promised.
struct ScannerAspectRow: View, Equatable {
    let aspect: PerspectiveAspect
    let onSelect: (PerspectiveAspect) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.aspect == rhs.aspect }

    var body: some View {
        HStack(spacing: 8) {
            DialCaption(text: "PAPER")
            HStack(spacing: 6) {
                ForEach(PerspectiveAspect.allCases, id: \.self) { option in
                    let isSelected = option == aspect
                    Button {
                        onSelect(option)
                    } label: {
                        Text(option.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isSelected ? LL.amber : .white.opacity(0.6))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(
                                    isSelected
                                        ? LL.amber.opacity(0.18)
                                        : Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9))
                            )
                            .overlay(
                                Capsule().stroke(
                                    isSelected ? LL.amber.opacity(0.8) : .clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Correct to \(option.label)")
                }
            }
        }
    }
}

/// Photo's single dial: Bulb, then the discrete presets down to "Off".
struct PhotoBlendDial: View, Equatable {
    let isBulb: Bool
    let frames: Int
    let onSelectBulb: () -> Void
    let onSelectFrames: (Int) -> Void

    /// Photo's discrete blend presets, high→low, ending at "Off" (a single
    /// un-stacked frame, depth 1) — the same dial vocabulary Interval uses.
    static let options: [(frames: Int, label: String)] = [
        (20, "20 frames"), (10, "10 frames"), (5, "5 frames"), (3, "3 frames"), (1, "Off"),
    ]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isBulb == rhs.isBulb && lhs.frames == rhs.frames
    }

    var body: some View {
        HStack(spacing: 8) {
            DialCaption(text: "BLEND")
            Menu {
                Button {
                    onSelectBulb()
                } label: {
                    if isBulb {
                        Label("Bulb", systemImage: "checkmark")
                    } else {
                        Text("Bulb")
                    }
                }
                ForEach(Self.options, id: \.frames) { option in
                    Button {
                        onSelectFrames(option.frames)
                    } label: {
                        if !isBulb && frames == option.frames {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                PickerMenuLabel(text: menuLabel)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// "Bulb" when armed, "Off" for a single frame, else the count.
    private var menuLabel: String {
        if isBulb { return "Bulb" }
        return frames <= 1 ? "Off" : "\(frames) frames"
    }
}
