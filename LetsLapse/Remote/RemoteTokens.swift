// Same macOS-POSITIVE condition as the rest of Remote/: the remote exists on
// the wrist and on the Mac, nowhere else.
#if os(watchOS) || os(macOS)
import SwiftUI

/// The remote's palette.
///
/// Deliberately NOT `LL` from `App/DesignSystem.swift`. Two reasons, and both
/// matter:
///
/// 1. **`App/` is not in the watch target.** The watch has always carried its
///    own hardcoded colours (an amber at `#FFB340`, a stop red at `#FF6961`)
///    scattered across three call sites. This gathers them into one place.
/// 2. **A watch face is a bespoke dark surface.** `docs/design/README.md`
///    carves that out explicitly — the phone's grouped-light palette is not
///    the contract here. The remote's job is legibility at arm's length on a
///    tripod, so it uses the saturated system-vivid family the watchOS
///    redesign spec is drawn in.
///
/// Colours are the spec's, at full 8-bit precision. If these change, the
/// watchOS SVGs under `docs/design/watchOS/` are stale by definition.
enum RemoteTint {
    // MARK: Semantic

    /// Recording, and the stop commit. The one colour that means "this ends
    /// something".
    static let record = Color(hex8: 0xFF453A)
    /// Burst. Reserved for the high-rate segment and the controls that reach
    /// it — never used for state that isn't about speed.
    static let burst = Color(hex8: 0xFFD60A)
    /// The link itself: clock, connection, and read-only information.
    static let link = Color(hex8: 0x40C8E0)
    /// Armed and ready to go.
    static let go = Color(hex8: 0x30D158)
    /// Something needs attention but nothing is broken — a busy phone, a send
    /// that didn't land.
    static let warn = Color(hex8: 0xFF9F0A)

    // MARK: Surfaces

    /// A settled row on the black ground.
    static let surface = Color(hex8: 0x1C1C1E)
    /// A raised control — an unselected chip.
    static let surfaceRaised = Color(hex8: 0x2C2C2E)
    /// A toggle track in its off state.
    static let surfaceTrack = Color(hex8: 0x39393D)

    /// The ground. Stated rather than inherited: the watch draws on true black
    /// so the bezel disappears, which is the whole reason the pads read as
    /// floating.
    static let ground = Color.black
}

/// Type ramp. The spec is drawn on a 45 mm watch at 396×484 **pixels**, and
/// SwiftUI works in points — so every size in the design doc is exactly half
/// what it says. These constants carry the halved values so no call site has
/// to remember the conversion, and so the two watch sizes can differ by their
/// 5% without anything being hardcoded to one of them.
enum RemoteType {
    /// `REC`, `ARMED`, `LINKED` — the state word in the header.
    static let statusWord = Font.system(size: 12, weight: .bold)
    /// The elapsed clock. Monospaced digits so it stops jittering.
    static let clock = Font.system(size: 15, weight: .semibold).monospacedDigit()
    /// The header's right-hand time of day.
    static let timeOfDay = Font.system(size: 13, weight: .semibold).monospacedDigit()
    /// The parameter read-out under the header.
    static let subline = Font.system(size: 11, weight: .medium, design: .monospaced)

    /// A commit pad's verb — "Slide up to burst".
    static let commit = Font.system(size: 12.5, weight: .semibold)
    /// A chip or row label.
    static let control = Font.system(size: 13.5, weight: .semibold)
    /// The big number on the considered-controls tab.
    static let hero = Font.system(size: 37, weight: .bold)
    /// A section label — `BURST FPS`.
    static let sectionLabel = Font.system(size: 10.5, weight: .bold)
    /// Explanatory small print.
    static let caption = Font.system(size: 10)
}

/// Shared geometry, again in points (spec pixels ÷ 2).
enum RemoteMetric {
    /// Side padding on every screen.
    static let gutter: CGFloat = 11
    /// Vertical rhythm between stacked controls.
    static let rowGap: CGFloat = 5
    /// A settled row's height.
    static let rowHeight: CGFloat = 30
    /// A chip's height — shorter than a row, because a chip is a choice and a
    /// row is a control.
    static let chipHeight: CGFloat = 24

    /// A commit pad's height — big enough to slide in without looking.
    ///
    /// The burst tab is the tightest screen in the app, and the budget is
    /// smaller than the screen suggests. A 46 mm watch is 208×248 pt, but a
    /// `TabView` page keeps only **~134 pt** of that once the status bar, the
    /// shared header, the page dots and the pager's own insets have taken
    /// theirs. The spec's literal 78 pt pad plus chips plus the AE/AF row came
    /// to 145 pt, and SwiftUI paid for the 11 pt of overflow by squeezing
    /// every flexible child — which is how the pad arrived on screen at 60 pt
    /// with its chevron crushed to nothing.
    ///
    /// So: 68 + 5 + 24 + 5 + 30 = 132 pt, measured against the real budget
    /// rather than the mock's canvas. The pad also carries `layoutPriority`,
    /// so if a longer localisation ever does overflow, the rows give way
    /// first and the no-look control keeps its size.
    static let padHeight: CGFloat = 68
    /// The bar inside a commit pad.
    static let commitBarHeight: CGFloat = 26
    static let padCorner: CGFloat = 14
    static let rowCorner: CGFloat = 11
    static let chipCorner: CGFloat = 9
}

extension Color {
    /// `0xRRGGBB` — the form the design spec states its colours in, so the
    /// constants above can be read straight off it without arithmetic.
    init(hex8 value: UInt32) {
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
#endif
