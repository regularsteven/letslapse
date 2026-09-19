import SwiftUI

/// The capture screen's "a preset is on" mark: the Manage presets row's
/// glyph (`camera.filters`, the Create tab's icon for the sheet) in a
/// camera-chrome circle with a small green tick, drawn in the top bar only
/// while an auto-apply rule holds the context the next shoot would register
/// with (docs/presets-auto-apply.md). Nothing is drawn when none does.
///
/// A readout, not a button — the rule was set on the preset's own screen,
/// and the top bar promises no mid-shoot actions. `Equatable` as every chip
/// on that bar is: the body hosting it is invalidated by dozens of observers
/// and this one changes only when the rules or the format do.
struct AutoPresetChip: View, Equatable {
    /// The preset new shoots start on — the accessibility value.
    let name: String

    /// The bar's chrome (`CameraChromeButton`, `CaptureHeadroomChip`).
    private static let chrome = Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9)
    /// The confirm green the design tokens table names (#34C759).
    private static let tick = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "camera.filters")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 31, height: 31)
                .background(Self.chrome, in: Circle())
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Self.tick)
                .offset(x: 3, y: 3)
        }
        // An atom like the pills beside it: its ideal size or nothing.
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Auto preset")
        .accessibilityValue(name)
    }
}
