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
}
