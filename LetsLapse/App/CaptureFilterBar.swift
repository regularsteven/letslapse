import SwiftUI

/// The one capture-kind filter the whole app uses. Photo and Interval both
/// live under the `.photos` capture kind — a Photo-mode capture is ONE asset,
/// an interval shoot is a stack of frames — so they need separate cases.
enum CaptureFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    case interval = "Interval"
    case video = "Video"

    var id: String { rawValue }

    func matches(_ capture: AppModel.CaptureProject) -> Bool {
        switch self {
        case .all:
            return true
        case .photos:
            return capture.isPhotoCapture
        case .interval:
            return capture.kind == .photos && !capture.isPhotoCapture
        case .video:
            return capture.kind == .video
        }
    }

    /// Copy for a list that filtered down to nothing — distinct from a library
    /// that is genuinely empty.
    var emptyMessage: String {
        switch self {
        case .all: return "No projects yet"
        case .photos: return "No photos"
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

    var body: some View {
        Picker("Filter", selection: $selection) {
            ForEach(CaptureFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 8)
    }
}

extension Array where Element == AppModel.CaptureProject {
    func filtered(by kind: CaptureFilter) -> [AppModel.CaptureProject] {
        kind == .all ? self : filter { kind.matches($0) }
    }
}
