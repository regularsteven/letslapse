import SwiftUI

/// The one capture-kind filter the whole app uses. Photo and Interval both
/// live under the `.photos` capture kind — a Photo-mode capture is ONE asset,
/// an interval shoot is a stack of frames — so they need separate cases.
enum CaptureFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    /// Only ever offered by Projects, and only while the Scans tab is turned
    /// off in Settings ▸ Advanced ▸ Layout — with the tab on, a scan is listed
    /// there and nowhere else. Sits between Photos and Interval because that
    /// is where a scan sits: stills, but not a timelapse.
    case scans = "Scans"
    case interval = "Interval"
    case video = "Video"

    var id: String { rawValue }

    /// Everything except Scans — the set the Gallery offers, and the set
    /// Projects offers while scanner runs live in their own tab.
    static var withoutScans: [CaptureFilter] { allCases.filter { $0 != .scans } }

    /// Whether a scan is a scan can't be read off the project alone (the
    /// sidecar fallback in `AppModel.isScannerProject` decides the hard cases),
    /// so callers that have the model pass the verdict in. Every kind filter
    /// excludes scans: only `.scans` lists them, and `.all` takes whatever it
    /// is handed.
    func matches(_ capture: AppModel.CaptureProject, isScan: Bool) -> Bool {
        switch self {
        case .all:
            return true
        case .scans:
            return isScan
        case .photos:
            return !isScan && capture.isPhotoCapture
        case .interval:
            return !isScan && capture.kind == .photos && !capture.isPhotoCapture
        case .video:
            return !isScan && capture.kind == .video
        }
    }

    func matches(_ capture: AppModel.CaptureProject) -> Bool {
        matches(capture, isScan: capture.isScannerCapture)
    }

    /// Copy for a list that filtered down to nothing — distinct from a library
    /// that is genuinely empty.
    var emptyMessage: String {
        switch self {
        case .all: return "No projects yet"
        case .photos: return "No photos"
        case .scans: return "No scans"
        case .interval: return "No interval shoots"
        case .video: return "No videos"
        }
    }
}

/// The segmented capture-kind filter shared by the Gallery grid and the
/// Projects list. Deliberately carries no horizontal padding: the Gallery adds
/// its own, and inside a List the row insets already supply it.
struct CaptureFilterBar: View {
    @Binding var selection: CaptureFilter
    /// Which filters to offer. Defaults to everything but Scans, which is the
    /// Gallery's set and Projects' usual one.
    var filters: [CaptureFilter] = CaptureFilter.withoutScans
    /// When supplied, each segment spells out how many projects it holds
    /// ("All 6") — Settings ▸ Advanced ▸ Layout ▸ Display count in Projects. A
    /// missing entry counts as none rather than as unknown, so a filter that
    /// matches nothing reads "0" rather than silently losing its number.
    var counts: [CaptureFilter: Int]?

    var body: some View {
        Picker("Filter", selection: $selection) {
            ForEach(filters) { filter in
                Text(label(for: filter)).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 8)
    }

    /// A segmented control truncates rather than shrinks, and ignores any font
    /// SwiftUI hands its labels — so the count has to fit at the system size.
    /// Five segments on a 393pt iPhone leave about 64pt each, which "Interval
    /// (0)" overruns and "Interval 0" does not: hence the bare number.
    private func label(for filter: CaptureFilter) -> String {
        guard let counts else { return filter.rawValue }
        return "\(filter.rawValue) \(counts[filter] ?? 0)"
    }
}

extension Array where Element == AppModel.CaptureProject {
    /// `isScan` lets a caller that holds the model answer the scanner question
    /// properly; without one, the project's own flag stands in — right for any
    /// list a scan was already excluded from.
    func filtered(
        by kind: CaptureFilter,
        isScan: (AppModel.CaptureProject) -> Bool = { $0.isScannerCapture }
    ) -> [AppModel.CaptureProject] {
        kind == .all ? self : filter { kind.matches($0, isScan: isScan($0)) }
    }
}
