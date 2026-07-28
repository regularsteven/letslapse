import Foundation

/// The user's own trims to the format sheet's resolution list — "I never
/// shoot 720p" lives here instead of being scrolled past on every visit.
/// Stills (Photo + Interval capture from the same format list) and Video
/// keep separate lists and separate display preferences.
///
/// Hidden IDs are stored, not visible ones, so everything starts checked
/// and a resolution a future device adds defaults to visible.
final class ResolutionPreferences: ObservableObject {
    static let shared = ResolutionPreferences()

    /// Which capture vocabulary a preference belongs to. Photo and Interval
    /// share one — they capture stills from the same formats.
    enum Domain: String, CaseIterable, Identifiable {
        case stills
        case video
        var id: String { rawValue }
    }

    static func domain(for mode: CaptureMode) -> Domain {
        mode == .video ? .video : .stills
    }

    @Published var hiddenStillIDs: Set<String> {
        didSet { persist(hiddenStillIDs, key: Self.hiddenStillsKey) }
    }
    @Published var hiddenVideoIDs: Set<String> {
        didSet { persist(hiddenVideoIDs, key: Self.hiddenVideoKey) }
    }
    @Published var displayRatiosForStills: Bool {
        didSet { defaults.set(displayRatiosForStills, forKey: Self.ratiosStillsKey) }
    }
    @Published var displayRatiosForVideo: Bool {
        didSet { defaults.set(displayRatiosForVideo, forKey: Self.ratiosVideoKey) }
    }

    private static let hiddenStillsKey = "letslapse.resolutions.hiddenStills"
    private static let hiddenVideoKey = "letslapse.resolutions.hiddenVideo"
    private static let ratiosStillsKey = "letslapse.resolutions.displayRatiosStills"
    private static let ratiosVideoKey = "letslapse.resolutions.displayRatiosVideo"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenStillIDs = Set(defaults.stringArray(forKey: Self.hiddenStillsKey) ?? [])
        hiddenVideoIDs = Set(defaults.stringArray(forKey: Self.hiddenVideoKey) ?? [])
        displayRatiosForStills = defaults.bool(forKey: Self.ratiosStillsKey)
        displayRatiosForVideo = defaults.bool(forKey: Self.ratiosVideoKey)
    }

    private func persist(_ ids: Set<String>, key: String) {
        defaults.set(ids.sorted(), forKey: key)
    }

    func hiddenIDs(in domain: Domain) -> Set<String> {
        domain == .stills ? hiddenStillIDs : hiddenVideoIDs
    }

    func isVisible(_ resolution: CameraController.CaptureResolution, in domain: Domain) -> Bool {
        !hiddenIDs(in: domain).contains(resolution.id)
    }

    func setVisible(_ visible: Bool, resolutionID: String, in domain: Domain) {
        switch domain {
        case .stills:
            if visible { hiddenStillIDs.remove(resolutionID) } else { hiddenStillIDs.insert(resolutionID) }
        case .video:
            if visible { hiddenVideoIDs.remove(resolutionID) } else { hiddenVideoIDs.insert(resolutionID) }
        }
    }

    func displaysRatios(in domain: Domain) -> Bool {
        domain == .stills ? displayRatiosForStills : displayRatiosForVideo
    }
}
