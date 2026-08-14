import SwiftUI

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

/// Interval's two dials — spacing and blend depth — plus the trailing caption.
/// One line where it fits (Mac, landscape phones/iPads); portrait iPhones fall
/// back to two stacked lines.
struct IntervalDialsRow: View, Equatable {
    let intervalSeconds: Double
    let intervalOptions: [Double]
    let blendDepth: BlendDepth
    let safeDepthAvailable: Bool
    let captionText: String?
    let onSelectInterval: (Double) -> Void
    let onSelectFixedBlend: (Int) -> Void
    let onSelectPsycho: () -> Void
    let onSelectSafe: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.intervalSeconds == rhs.intervalSeconds
            && lhs.blendDepth == rhs.blendDepth
            && lhs.safeDepthAvailable == rhs.safeDepthAvailable
            && lhs.captionText == rhs.captionText
            && lhs.intervalOptions == rhs.intervalOptions
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                everyPicker
                blendPicker
                caption
            }
            VStack(alignment: .leading, spacing: 6) {
                everyPicker
                HStack(spacing: 8) {
                    blendPicker
                    caption
                }
            }
        }
    }

    private var everyPicker: some View {
        HStack(spacing: 8) {
            DialCaption(text: "EVERY")
            Menu {
                ForEach(intervalOptions, id: \.self) { seconds in
                    Button {
                        onSelectInterval(seconds)
                    } label: {
                        if intervalSeconds == seconds {
                            Label(Self.intervalLabel(seconds), systemImage: "checkmark")
                        } else {
                            Text(Self.intervalLabel(seconds))
                        }
                    }
                }
            } label: {
                PickerMenuLabel(text: Self.intervalLabel(intervalSeconds))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var blendPicker: some View {
        HStack(spacing: 8) {
            DialCaption(text: "BLEND")
            Menu {
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
            } label: {
                PickerMenuLabel(text: menuLabel)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
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
