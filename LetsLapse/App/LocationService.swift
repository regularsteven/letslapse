import CoreLocation
import Combine

/// Single owner of Core Location for capture geotagging: a live `currentLocation`
/// for baking GPS into photo EXIF, and a ~6 s-cadence point log for writing a GPX
/// sidecar alongside internally captured video.
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private var gpxPoints: [(timestamp: Date, location: CLLocation)] = []
    private(set) var isPollingForVideo = false

    /// Thread-safe snapshot of the most recent fix, readable from any queue.
    /// The camera writes stills on its own session queue and can't touch
    /// main-actor state, so it reads the location through this lock-guarded
    /// accessor. Updated in the nonisolated delegate callback below.
    private let snapshotLock = NSLock()
    nonisolated(unsafe) private var _latestLocation: CLLocation?
    nonisolated var latestLocation: CLLocation? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return _latestLocation
    }

    /// The take's first fix good enough to trust — see
    /// `MovieLocation.accuracyThreshold`. Seeded at record-start with the fix
    /// already in hand, then filled by the first accurate update to arrive
    /// during the take. Behind the same lock as `latestLocation`: the camera
    /// reads it on the session queue as each segment finishes.
    nonisolated(unsafe) private var _recordingFix: CLLocation?
    /// The take's first fix at any accuracy — the same point the GPX sidecar
    /// would open with. Stands in when nothing ever cleared the threshold,
    /// since a coarse pin beats no pin at all.
    nonisolated(unsafe) private var _recordingFallbackFix: CLLocation?

    /// Where the recording in progress (or the one that just finished) started,
    /// for baking into the movie file and stamping on its Photos asset.
    ///
    /// For a moving shot — a car timelapse — this is deliberately the position
    /// the take began at, not a track: one clip carries one place.
    nonisolated var recordingLocation: CLLocation? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return _recordingFix ?? _recordingFallbackFix
    }

    /// Opens fix tracking for a new take, discarding the previous take's. A fix
    /// already in hand is used immediately when it's accurate enough; otherwise
    /// the first accurate update during recording wins.
    nonisolated func beginRecordingFix() {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        let current = _latestLocation
        _recordingFix = current.flatMap { MovieLocation.isAccurate($0) ? $0 : nil }
        _recordingFallbackFix = current
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorizationStatus = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func startUpdates() {
        manager.startUpdatingLocation()
    }

    func stopUpdates() {
        manager.stopUpdatingLocation()
    }

    // MARK: - GPX polling for video
    func startGPXPolling() {
        gpxPoints = []
        isPollingForVideo = true
        manager.startUpdatingLocation()
    }

    func stopGPXPolling() -> [(timestamp: Date, location: CLLocation)] {
        isPollingForVideo = false
        manager.stopUpdatingLocation()
        return gpxPoints
    }

    // MARK: - CLLocationManagerDelegate
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        snapshotLock.lock()
        _latestLocation = loc
        if _recordingFix == nil, MovieLocation.isAccurate(loc) { _recordingFix = loc }
        if _recordingFallbackFix == nil { _recordingFallbackFix = loc }
        snapshotLock.unlock()
        Task { @MainActor in
            self.currentLocation = loc
            if self.isPollingForVideo {
                // ~6 s cadence: only append if 6+ seconds since last point
                if let last = self.gpxPoints.last {
                    if loc.timestamp.timeIntervalSince(last.timestamp) >= 6 {
                        self.gpxPoints.append((timestamp: loc.timestamp, location: loc))
                    }
                } else {
                    self.gpxPoints.append((timestamp: loc.timestamp, location: loc))
                }
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
        }
    }
}
