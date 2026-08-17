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

/// Interval's dials — mode, spacing and blend depth — plus the
/// trailing caption. One line where it fits (Mac, landscape phones/iPads);
/// portrait iPhones fall back to two stacked lines.
///
/// ```
/// MODE:   Basic · Holy Grail · Scanner
/// EVERY:  0.5s · 1s · 3s · 5s · 10s … Auto
/// BLEND:  Off · 3 · 5 · 10 … Safe · Psycho
/// ```
///
/// **MODE comes first because it decides what the dials under it mean.** It
/// used to sit second, which put the reader in the odd position of setting a
/// spacing before knowing whether the shoot had one: under Scanner it doesn't.
/// Read top to bottom the row is now a sentence — *what kind of shoot, then how
/// often, then how deep* — and the one dial that can remove another is the one
/// you meet first.
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
/// - **Auto appears only when MODE isn't Basic** (see `everyPicker`).
/// - **Scanner has no EVERY at all** — the scene fires the shutter, so there is
///   no spacing to set and the dial isn't drawn. It used to stay visible with
///   its values greyed under a header explaining why; that taught the model
///   once and then wasted a third of the row forever after, on the mode whose
///   screen has the most to say (PAPER, the overlay, the pose count).
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

    /// Scanner fires from the scene, so the shoot has no spacing to show.
    private var showsEveryPicker: Bool { !intervalMode.ownsInterval }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if modeAvailable { modePicker }
                if showsEveryPicker { everyPicker }
                blendPicker
                caption
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if modeAvailable { modePicker }
                    if showsEveryPicker { everyPicker }
                }
                HStack(spacing: 8) {
                    blendPicker
                    caption
                }
            }
        }
    }

    /// The MODE dial. "Basic" is the plain timer shoot; "Holy Grail" hands
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
                fixedIntervalButtons
                // Auto is offered only by a mode that can pace itself. With
                // MODE Basic there is nothing for it to mean, so rather than
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
    /// which rather than leaving the user to guess. Scanner has no case here
    /// because it has no EVERY dial to put one in.
    private var autoMenuLabel: String {
        intervalMode == .holyGrail ? "Auto · the ramp paces itself" : "Auto"
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
        }
    }

    /// Every fixed count, plus the two adaptive depths — the latter everywhere
    /// but Scanner.
    ///
    /// **The fixed counts mean something different under Scanner, and both
    /// meanings are the dial doing its job.** In a timelapse a blend averages a
    /// window the scene moves through, and the average *is* the motion blur.
    /// A Scanner pose holds still under a locked exposure, so averaging its
    /// frames moves nothing and removes noise — about √N of it. Same dial, same
    /// arithmetic, different reason to reach for it: blur outdoors, a cleaner
    /// page indoors.
    ///
    /// **Psycho and Safe stay out of it.** Both size themselves against a timed
    /// window — "as many frames as fit in the interval", "as many as this device
    /// has been taught it can sustain per interval" — and a pose has no
    /// interval; it has a person holding a page. They are greyed under a header
    /// saying so rather than hidden, for the reason the greyed rows here always
    /// win: a missing row looks broken, an explained one teaches the model.
    private var blendPicker: some View {
        HStack(spacing: 8) {
            DialCaption(text: "BLEND")
            Menu {
                blendOptionButtons
            } label: {
                PickerMenuLabel(text: menuLabel)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var blendOptionButtons: some View {
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
        if intervalMode == .scanner {
            Section("Adaptive depths need a timed window") { adaptiveDepthButtons }
        } else {
            adaptiveDepthButtons
        }
    }

    @ViewBuilder
    private var adaptiveDepthButtons: some View {
        Group {
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
        // A depth carried in from another mode that Scanner can't honour reads
        // as what the run will actually do, not as what the dial remembers.
        if intervalMode == .scanner, blendDepth.fixedFrames == nil { return "Off" }
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
