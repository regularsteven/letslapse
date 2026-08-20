import Foundation
import LetsLapseKit
#if os(iOS)
import AVFoundation
#endif

/// Auto blend: how deep to blend an interval, decided from the light.
///
/// The other adaptive depths answer a different question. **Psycho** takes as
/// many frames as the device physically can, whatever the scene looks like;
/// **Safe** takes as many as past Psycho runs proved survivable. Both are about
/// the *device*. Auto is about the *scene*: a bright noon frontage needs no
/// noise averaging and gains nothing but heat from twenty exposures, while
/// dusk is exactly where stacking earns its keep — so the count follows the
/// measured EV, bounded by what this device was profiled at.
///
/// Two guards keep it from thrashing:
///
/// - The device's own **capability profile** (`DeviceCapabilityProfile`) caps
///   every band. Asking for 8 frames on hardware that measured 3 RAW writes a
///   second inside a 2-second interval is a request for dropped frames, not
///   depth.
/// - A **3-cycle rolling average** of EV drives the lookup. Auto-exposure
///   hunts by a third of a stop constantly, and a raw per-cycle reading sat
///   right on a band edge would alternate 5 and 3 frames from one interval to
///   the next — visible in the finished clip as a noise-floor flicker, which is
///   the exact artefact blending exists to remove.
enum DynamicBlendPolicy {

    /// One row of the EV → frame-count table. `lowerBound` is inclusive.
    struct Band: Equatable {
        let lowerBound: Double
        let frames: Int
        let name: String
    }

    /// Bright daylight needs the least help; the deepest stacks are for the
    /// light that is nearly gone. Read top-down: the first band whose
    /// `lowerBound` the EV clears wins.
    static let bands: [Band] = [
        Band(lowerBound: 13, frames: 8, name: "daylight"),
        Band(lowerBound: 10, frames: 5, name: "overcast"),
        Band(lowerBound: 7, frames: 3, name: "dim"),
        Band(lowerBound: 4, frames: 2, name: "dusk"),
        Band(lowerBound: -.infinity, frames: 1, name: "night"),
    ]

    /// How many cycles of EV the rolling average spans.
    static let smoothingWindow = 3

    /// The band an EV falls in.
    static func band(forEV ev: Double) -> Band {
        bands.first { ev >= $0.lowerBound } ?? bands[bands.count - 1]
    }

    /// The blend count for an EV, capped by what the device can actually
    /// deliver in one cycle. The cap is a floor of 1, never 0 — a cycle that
    /// captures nothing is a dropped frame, not a shallow blend.
    static func frameCount(forEV ev: Double, profile: DeviceCapabilityProfile?) -> Int {
        let wanted = band(forEV: ev).frames
        guard let profile else { return wanted }
        return max(1, min(wanted, profile.maxBurstFramesPerCycle))
    }

    /// Exposure value at ISO 100 for a set of camera settings — the same
    /// derivation `DNGAuthor.DNGExposure` uses, exposed here for the live AE
    /// read (which comes off `AVCaptureDevice`, not off a captured photo).
    static func exposureValue(aperture: Double, exposureDuration: Double, iso: Double) -> Double? {
        guard aperture > 0, exposureDuration > 0, iso > 0 else { return nil }
        return log2((aperture * aperture) / exposureDuration) - log2(iso / 100)
    }
}

/// The rolling EV average behind Auto's count, plus the count it last
/// resolved. Not thread-safe on its own: both blend controllers confine their
/// window state to a single queue and this rides along with it.
struct DynamicBlendState {
    private var readings: [Double] = []
    /// The count the last resolved cycle asked for — what the session log and
    /// the readouts report.
    private(set) var lastResolvedCount: Int?
    /// The smoothed EV the last resolution was made on.
    private(set) var lastSmoothedEV: Double?

    /// Folds one cycle's EV in and resolves the count for the cycle about to
    /// open. Called once per cycle, before its captures are requested.
    ///
    /// The first cycle has one reading and resolves from it directly — waiting
    /// three intervals before Auto did anything would mean a shoot that starts
    /// at dusk opens on a daylight-shaped blend.
    mutating func resolve(ev: Double, profile: DeviceCapabilityProfile?) -> Int {
        readings.append(ev)
        if readings.count > DynamicBlendPolicy.smoothingWindow {
            readings.removeFirst(readings.count - DynamicBlendPolicy.smoothingWindow)
        }
        let smoothed = readings.reduce(0, +) / Double(readings.count)
        let count = DynamicBlendPolicy.frameCount(forEV: smoothed, profile: profile)
        lastSmoothedEV = smoothed
        lastResolvedCount = count
        return count
    }

    /// No EV to be had this cycle (the meter reported nothing usable): hold the
    /// last resolved count rather than guessing, and fall back to the middle of
    /// the table on the very first cycle.
    mutating func resolveWithoutMeasurement(profile: DeviceCapabilityProfile?) -> Int {
        if let held = lastResolvedCount { return held }
        let fallback = DynamicBlendPolicy.band(forEV: 10).frames
        let count = max(1, min(fallback, profile?.maxBurstFramesPerCycle ?? fallback))
        lastResolvedCount = count
        return count
    }
}

/// What this device measured itself doing, right now, on the format this shoot
/// is actually using.
///
/// Nothing here is a spec-sheet number. `maxBurstFramesPerCycle` is derived
/// from a real timed burst written to real storage, so it already includes the
/// things a lookup table can't know: the format's resolution, the file system's
/// mood, and whatever else is running on the phone.
struct DeviceCapabilityProfile: Equatable {
    /// How many frames one capture cycle can ask for and expect to get.
    let maxBurstFramesPerCycle: Int
    /// Measured bytes-to-disk rate during the probe, in MB/s.
    let writeThroughputMBps: Double
    /// The thermal state the measurement was taken in. A profile measured cool
    /// does not describe a hot phone, which is why `isStale(for:)` exists.
    let thermalState: ProcessInfo.ThermalState

    /// Frames per second the probe achieved end-to-end (capture through write).
    let framesPerSecond: Double
    /// The interval the ceiling was computed against.
    let intervalSeconds: Double
    /// How many frames the probe actually landed, and how long it took — kept
    /// so the session log can show the measurement, not just its conclusion.
    let probeFrames: Int
    let probeSeconds: Double

    /// A profile taken in a different thermal state is no longer describing
    /// this device: sustained capture throttles hard between `.nominal` and
    /// `.serious`, and a stale ceiling is exactly how Auto would start asking
    /// for frames a hot phone can't deliver.
    func isStale(for state: ProcessInfo.ThermalState) -> Bool {
        state != thermalState
    }

    /// Frames the profiled rate can deliver inside one interval, with a margin
    /// so the last capture of a cycle isn't racing the window's close.
    static func ceiling(framesPerSecond: Double, intervalSeconds: Double) -> Int {
        guard framesPerSecond > 0, intervalSeconds > 0 else { return 1 }
        let usable = intervalSeconds * 0.8
        return max(1, min(DynamicBlendPolicy.bands[0].frames, Int(framesPerSecond * usable)))
    }

    var thermalStateName: String {
        switch thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// The run's current capability profile, shared between the thing that
/// measures it (the profiler, on its own queue), the thing that replaces it
/// when conditions move (the thermal observer, on whatever queue Foundation
/// posts on) and the thing that reads it every cycle (the blend controller, on
/// its work queue). One small lock rather than a queue hop, because the read is
/// on the capture path.
final class CapabilityProfileHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DeviceCapabilityProfile?

    var profile: DeviceCapabilityProfile? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ profile: DeviceCapabilityProfile?) {
        lock.lock()
        stored = profile
        lock.unlock()
    }

    /// Whether the stored profile no longer describes the device — the trigger
    /// for a re-profile. An empty holder is stale by definition.
    func isStale(for state: ProcessInfo.ThermalState) -> Bool {
        guard let profile else { return true }
        return profile.isStale(for: state)
    }
}

#if os(iOS)

/// Measures what the device can really do before a shoot commits to a depth.
///
/// The probe is a short burst of RAW captures with no pacing at all, timed from
/// the first request to the last byte on disk — the full cost of a frame, not
/// just the shutter. Dividing frames by that elapsed time gives a
/// frames-per-second the interval can be budgeted against.
///
/// It runs once at interval start and again whenever the thermal state moves,
/// and it writes to a scratch directory it deletes afterwards, so nothing it
/// captures reaches the shoot.
final class DeviceCapabilityProfiler {
    /// Frames the probe burst asks for. Enough to average out one slow write,
    /// short enough that a shoot doesn't visibly wait on it.
    static let probeFrameCount = 10
    /// A probe that hasn't finished by now is telling us something too — the
    /// partial result is used rather than hanging the shoot. Ten serialised RAW
    /// captures run around a second each on a 48MP format, so this is a ceiling
    /// on the wait, not the expected duration.
    private static let probeTimeout: TimeInterval = 12

    private let photoOutput: AVCapturePhotoOutput
    private let captureExecutor: (@escaping () -> Void) -> Void
    private let queue = DispatchQueue(label: "com.letslapse.capability.profile", qos: .userInitiated)

    /// Probe state, queue-confined.
    private var delegate: ProbeDelegate?
    private var inFlight = false

    init(
        photoOutput: AVCapturePhotoOutput,
        captureExecutor: @escaping (@escaping () -> Void) -> Void
    ) {
        self.photoOutput = photoOutput
        self.captureExecutor = captureExecutor
    }

    /// Runs the probe and calls back with a profile on `queue`. A probe already
    /// in flight, or one that lands nothing at all, calls back with nil — the
    /// caller then runs uncapped, which is what every depth did before Auto
    /// existed.
    func profile(
        rawPixelFormat: OSType,
        intervalSeconds: Double,
        completion: @escaping (DeviceCapabilityProfile?) -> Void
    ) {
        queue.async {
            guard !self.inFlight else {
                completion(nil)
                return
            }
            self.inFlight = true
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("ll-capability-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(
                    at: scratch, withIntermediateDirectories: true)
            } catch {
                self.inFlight = false
                LLog("capability: could not create the probe scratch directory — \(error)")
                completion(nil)
                return
            }
            let thermalState = ProcessInfo.processInfo.thermalState
            let delegate = ProbeDelegate(
                directory: scratch,
                wanted: Self.probeFrameCount) { [weak self] frames, bytes, seconds in
                    guard let self else { return }
                    try? FileManager.default.removeItem(at: scratch)
                    self.queue.async {
                        self.inFlight = false
                        self.delegate = nil
                        guard frames > 0, seconds > 0 else {
                            LLog("capability: probe landed no frames — running uncapped")
                            completion(nil)
                            return
                        }
                        let fps = Double(frames) / seconds
                        let profile = DeviceCapabilityProfile(
                            maxBurstFramesPerCycle: DeviceCapabilityProfile.ceiling(
                                framesPerSecond: fps, intervalSeconds: intervalSeconds),
                            writeThroughputMBps: (Double(bytes) / 1_048_576) / seconds,
                            thermalState: thermalState,
                            framesPerSecond: fps,
                            intervalSeconds: intervalSeconds,
                            probeFrames: frames,
                            probeSeconds: seconds)
                        LLog("""
                            capability: \(frames) RAW frames in \(String(format: "%.2f", seconds))s \
                            = \(String(format: "%.2f", fps)) fps, \
                            \(String(format: "%.0f", profile.writeThroughputMBps)) MB/s, \
                            thermal \(profile.thermalStateName) → \
                            ceiling \(profile.maxBurstFramesPerCycle) frames per \(intervalSeconds)s cycle
                            """)
                        completion(profile)
                    }
                }
            self.delegate = delegate
            delegate.start(
                photoOutput: self.photoOutput,
                rawPixelFormat: rawPixelFormat,
                captureExecutor: self.captureExecutor,
                timeout: Self.probeTimeout)
        }
    }

    /// Fires the burst back-to-back and times the whole thing — capture, encode
    /// and write — because that is what a cycle actually pays.
    ///
    /// **The next shot is requested as the previous one completes**, not all ten
    /// at once. "Zero delay" here means no pacing grid, not unbounded overlap:
    /// queueing several full-sensor RAW captures at a photo output that hasn't
    /// been configured for overlap is what starved the session on an iPhone 16
    /// Pro (see the note in `LiveBlendRawController.tick`) — a hung second
    /// capture never completes and the run never recovers. Serialised, the
    /// measurement is also the more useful one: shot-to-shot throughput is
    /// exactly what a blend window spends.
    private final class ProbeDelegate: NSObject, AVCapturePhotoCaptureDelegate {
        private let directory: URL
        private let wanted: Int
        private let finished: (Int, Int, Double) -> Void
        private let lock = NSLock()
        private let writeQueue = DispatchQueue(label: "com.letslapse.capability.write")

        private var startUptime: Double = 0
        private var landed = 0
        private var requested = 0
        private var bytes = 0
        private var reported = false

        private var photoOutput: AVCapturePhotoOutput?
        private var rawPixelFormat: OSType = 0
        private var captureExecutor: ((@escaping () -> Void) -> Void)?

        init(directory: URL, wanted: Int, finished: @escaping (Int, Int, Double) -> Void) {
            self.directory = directory
            self.wanted = wanted
            self.finished = finished
        }

        func start(
            photoOutput: AVCapturePhotoOutput,
            rawPixelFormat: OSType,
            captureExecutor: @escaping (@escaping () -> Void) -> Void,
            timeout: TimeInterval
        ) {
            self.photoOutput = photoOutput
            self.rawPixelFormat = rawPixelFormat
            self.captureExecutor = captureExecutor
            startUptime = ProcessInfo.processInfo.systemUptime
            fireNext()
            // A probe that stalls must not hang the shoot behind it: report
            // whatever landed — the partial measurement is still a real one,
            // and a probe this slow has already answered the question.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.report()
            }
        }

        /// One more capture, if the probe still wants one and hasn't reported.
        private func fireNext() {
            lock.lock()
            let done = reported || requested >= wanted
            if !done { requested += 1 }
            lock.unlock()
            guard !done, let photoOutput, let captureExecutor else { return }
            let format = rawPixelFormat
            captureExecutor { [weak self] in
                guard let self else { return }
                let settings = AVCapturePhotoSettings(rawPixelFormatType: format)
                settings.photoQualityPrioritization = .speed
                photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }

        func photoOutput(
            _ output: AVCapturePhotoOutput,
            didFinishProcessingPhoto photo: AVCapturePhoto,
            error: Error?
        ) {
            guard error == nil, photo.isRawPhoto,
                  let data = photo.fileDataRepresentation() else { return }
            // The write is the expensive half and the half a spec sheet can't
            // predict, so it is inside the measured window by design.
            writeQueue.async {
                let url = self.directory
                    .appendingPathComponent("probe-\(UUID().uuidString).dng")
                guard (try? data.write(to: url)) != nil else { return }
                self.lock.lock()
                self.landed += 1
                self.bytes += data.count
                let done = self.landed >= self.wanted
                self.lock.unlock()
                if done {
                    self.report()
                } else {
                    self.fireNext()
                }
            }
        }

        func photoOutput(
            _ output: AVCapturePhotoOutput,
            didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
            error: Error?
        ) {
            guard error != nil else { return }
            // A failed capture is a real result — it just isn't a frame. Free
            // the slot so the probe doesn't sit waiting out its timeout.
            fireNext()
        }

        private func report() {
            lock.lock()
            guard !reported else {
                lock.unlock()
                return
            }
            reported = true
            let frames = landed
            let total = bytes
            lock.unlock()
            finished(frames, total, ProcessInfo.processInfo.systemUptime - startUptime)
        }
    }
}

#endif
