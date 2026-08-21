import Foundation
import CoreMedia
import LetsLapseKit
#if os(iOS)
import AVFoundation
#endif

// Auto blend's decision logic lives in the Kit (`BlendStrategies.swift`:
// `ZoneBlendStrategy` and its field-test siblings), where both blend
// controllers share one implementation and the regression tests can reach
// it. This file keeps the *device* side: the capability profile, its
// holder, and the probe that measures what this hardware can actually do.

extension BlendStrategyID {
    /// Settings ▸ Advanced ▸ "Auto blend strategy" — the field-test selector.
    /// Per-device on purpose: a comparison shoot sets one strategy on each
    /// device and the choice rides into `capture_log.json`.
    static let defaultsKey = "capture.blendStrategy"

    static var selected: BlendStrategyID {
        BlendStrategyID(rawValue:
            UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .zone
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
    /// The ceiling as computed at probe time, against the interval the run
    /// STARTED at. Informational — the log line and the probe record use
    /// it; both blend controllers derive their live ceiling per window from
    /// `framesPerSecond` against the interval the run is pacing at now,
    /// because EVERY=Auto re-paces mid-run and this number does not follow.
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
    ///
    /// `currentShutterSeconds`, when known, guards the direction the probe
    /// can't: the probe's fps was measured at whatever shutter the probe ran
    /// at (usually short, in daylight), but a holy-grail run ends with the
    /// shutter pinned near 1 s — a frame can never take less wall clock than
    /// its own exposure, so the per-frame cost is floored at the live
    /// shutter plus a margin before the interval is divided up.
    static func ceiling(
        framesPerSecond: Double, intervalSeconds: Double,
        currentShutterSeconds: Double? = nil
    ) -> Int {
        guard framesPerSecond > 0, intervalSeconds > 0 else { return 1 }
        let usable = intervalSeconds * 0.8
        var perFrame = 1 / framesPerSecond
        if let shutter = currentShutterSeconds, shutter > 0 {
            perFrame = max(perFrame, shutter * 1.2)
        }
        return max(1, min(ZoneBlendStrategy.bands[0].frames, Int(usable / perFrame)))
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

/// The exposure the holy-grail ramp most recently wrote to the device,
/// clamped to the format's real envelope. Written on the session queue
/// (`applyHolyGrailExposure`), read by the DNG bracket path when it builds
/// per-shot settings — same shape as `CapabilityProfileHolder` below: one
/// small lock, because the read sits on the capture path.
final class HolyGrailAppliedExposureHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (duration: CMTime, iso: Float)?

    var target: (duration: CMTime, iso: Float)? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ target: (duration: CMTime, iso: Float)?) {
        lock.lock()
        stored = target
        lock.unlock()
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

extension AVCapturePhotoSettings {
    /// Timelapse capture is silent by intent: a shoot is hundreds to
    /// thousands of captures, and a shutter click per RAW frame (five per
    /// window under a blend) is noise pollution, not feedback. Applied to
    /// every timelapse-path capture — blend frames, brackets, the
    /// capability probe, interval stills — and honored wherever the OS
    /// allows (regions that mandate the sound report the API unsupported,
    /// and the sound stays).
    func suppressShutterSound(for output: AVCapturePhotoOutput) {
        if #available(iOS 18.0, *), output.isShutterSoundSuppressionSupported {
            isShutterSoundSuppressionEnabled = true
        }
    }
}

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
                settings.suppressShutterSound(for: photoOutput)
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
