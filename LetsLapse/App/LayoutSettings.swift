import SwiftUI

/// Settings ▸ Advanced ▸ Layout — what the shell shows, as opposed to what the
/// engine does. Plain `UserDefaults` keys rather than model state: every one of
/// them is read by a view body and by nothing else, so `@AppStorage` observes
/// them directly and no publisher has to exist.
enum LayoutSettings {
    /// Whether the Scans tab is allowed in the tab bar at all. **On by
    /// default** — but "allowed" is not "shown": the tab still only appears
    /// once the library actually holds a scan (`AppModel.hasScanSessions`), or
    /// while it is the tab you are standing on.
    ///
    /// Off moves scanner runs into the Projects list instead, behind that
    /// tab's own Scans filter, so they stay reachable without a sixth tab.
    static let scansMenuKey = "layout.scansMenuEnabled"

    /// Whether the Projects filter bar spells out how many projects each
    /// filter holds ("All 292"). **Off by default**: the counts are useful when
    /// you are auditing a library and noise the rest of the time, and at five
    /// filters they are what pushes the bar's labels to their limit.
    static let projectCountsKey = "layout.showsProjectCounts"

    /// Whether the Editor's paired adjustments share an XY pad (Exposure ·
    /// Contrast, Highlights · Whites, Temp · Tint, …) or each renders as its
    /// own slider. **On by default**: the pads are the design; the sliders are
    /// for anyone who wants one number under one finger. Off changes the
    /// control and nothing else — the grouping, the presets and the timeline
    /// are the same either way — on iPhone, iPad and Mac alike. The
    /// `LL_PADS=off` hook overrides it for a screenshot without writing here,
    /// so the Mac driver never disturbs a real setting.
    static let editorPadsKey = "layout.editorPads"

    /// LetsLapse Appearance — Light, Dark or Auto (follow the system).
    /// **Auto by default.** Stored as `AppearancePreference.rawValue` and
    /// applied once, at the root, by `.letsLapseAppearance()`. The capture
    /// screen, the editors and the camera remote force dark on their own
    /// presentations and keep doing so whatever this says.
    static let appearanceKey = "layout.appearance"
}

/// The three answers to Settings ▸ Advanced ▸ Layout ▸ LetsLapse Appearance.
///
/// ⚠️ Not every token follows the scheme yet: `LL.ink` (#1C1C1E),
/// `LL.controlFill` (#E9E9EB) and the other fixed-colour tokens in
/// `DesignSystem.swift` are literal colours, so forcing the other appearance
/// from the system's exposes them. The adaptive ones (`LL.screenBackground`,
/// `LL.cardBackground`, the editor-group colours) are fine. A token pass is
/// owed before this ships widely.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case light, dark, auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .auto: return "Auto"
        }
    }

    /// For `.preferredColorScheme` — nil hands the choice back to the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .auto: return nil
        }
    }

    #if os(macOS)
    /// For `NSApp.appearance` — nil follows the system. Set app-wide rather
    /// than per window, because on the Mac every `Window`/`WindowGroup` is its
    /// own presentation that a root `.preferredColorScheme` never reaches
    /// (Import from Device, Framing review, alerts, open panels). The windows
    /// that force dark (editors, the remote) still win over it. It also avoids
    /// SwiftUI's trap where a scheme set back to nil does not revert until
    /// relaunch.
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .auto: return nil
        }
    }
    #endif
}

extension View {
    /// Applies LetsLapse Appearance. Put once on the app's root view.
    func letsLapseAppearance() -> some View {
        modifier(AppearanceModifier())
    }
}

private struct AppearanceModifier: ViewModifier {
    @AppStorage(LayoutSettings.appearanceKey) private var appearance: AppearancePreference = .auto

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onAppear { NSApp.appearance = appearance.nsAppearance }
            .onChange(of: appearance) { _, new in NSApp.appearance = new.nsAppearance }
        #else
        // Sheets and full-screen covers inherit the window's style; the ones
        // that set `.preferredColorScheme(.dark)` themselves keep it.
        content.preferredColorScheme(appearance.colorScheme)
        #endif
    }
}
