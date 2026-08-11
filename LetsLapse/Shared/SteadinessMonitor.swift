import Combine
import Foundation
#if canImport(CoreMotion)
import CoreMotion
#endif

/// Shared device-motion primitive. Wraps `CMMotionManager` and provides:
///   - Real-time `isStill` / `magnitude` for UI
///   - Async `waitUntilSteady` gate for Photo mode (capture when steady)
///   - Per-frame capture log for Interval tail-frame detection
///
/// Lives in Shared/ so the phone (Photo gate-before-capture, Interval
/// flag-after-capture) and the Watch speak the same primitive. `CMMotionManager`
/// only exists on iOS and watchOS, so the motion internals are compiled out on
/// macOS — there the monitor is an inert stand-in: `isStill`/`magnitude` never
/// move and `waitUntilSteady` returns immediately, so a Mac build never blocks
/// on a gate it has no sensor to satisfy.
@MainActor
final class SteadinessMonitor: ObservableObject {

    // MARK: - Published state
    @Published private(set) var isStill: Bool = false
    @Published private(set) var magnitude: Double = 0

    // MARK: - Configuration
    /// `userAcceleration` vector magnitude (in g). Below this the device reads
    /// as still. 0.08 g is roughly a phone resting on a hand, not a tripod.
    var stillThreshold: Double = 0.08
    /// Rolling average over the last N samples — smooths the single-sample
    /// jitter that would otherwise flip `isStill` every frame.
    var smoothingWindow: Int = 5
    var updateInterval: TimeInterval = 1.0 / 50  // 50 Hz

    // MARK: - Capture log (for Interval tail-frame detection)
    private(set) var captureLog: [(captureIndex: Int, magnitude: Double)] = []

    // MARK: - Private
    #if os(iOS) || os(watchOS)
    private let manager = CMMotionManager()
    #endif
    private var magnitudeHistory: [Double] = []
    private var steadyCheckContinuation: CheckedContinuation<Bool, Never>?
    private var steadyCheckTimer: Timer?
    /// Threshold the armed gate resolves against — kept separate from
    /// `stillThreshold` so a per-call gate threshold never stomps the value the
    /// live `isStill` readout uses.
    private var gateThreshold: Double = 0.08
    private var isRunning = false

    // MARK: - Start / stop
    func start() {
        #if os(iOS) || os(watchOS)
        guard !isRunning, manager.isDeviceMotionAvailable else { return }
        isRunning = true
        magnitudeHistory = []
        manager.deviceMotionUpdateInterval = updateInterval
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            // Delivered on the main queue (guaranteed by `to: .main`), but the
            // handler type is not actor-annotated — assert the isolation so
            // the @MainActor call is statically sound without a per-sample
            // Task at 50 Hz.
            guard let self, let motion else { return }
            MainActor.assumeIsolated {
                self.ingest(motion)
            }
        }
        #endif
    }

    func stop() {
        #if os(iOS) || os(watchOS)
        if isRunning {
            isRunning = false
            manager.stopDeviceMotionUpdates()
        }
        #endif
        // Resolve any pending gate as "not settled" so a caller awaiting the
        // continuation is never left hanging when monitoring stops.
        resolveSteadyGate(false)
    }

    // MARK: - Async gate
    /// Waits until the device is steady (magnitude < threshold) or times out.
    /// Returns true if steady was reached, false if it timed out or monitoring
    /// stopped first. Off-device (macOS, or no motion hardware) it returns true
    /// immediately — there is nothing to wait for.
    func waitUntilSteady(threshold: Double? = nil, timeout: TimeInterval = 10) async -> Bool {
        let t = threshold ?? stillThreshold
        #if os(iOS) || os(watchOS)
        guard isRunning else { return true }
        // Already still right now?
        if magnitude < t { return true }
        return await withCheckedContinuation { continuation in
            gateThreshold = t
            steadyCheckContinuation = continuation
            steadyCheckTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                // Scheduled from this @MainActor method, so it fires on the
                // main run loop — assert the isolation, same as the motion
                // handler above.
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.resolveSteadyGate(false)
                }
            }
        }
        #else
        _ = t
        return true
        #endif
    }

    #if os(iOS) || os(watchOS)
    private func ingest(_ motion: CMDeviceMotion) {
        let a = motion.userAcceleration
        let m = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
        magnitudeHistory.append(m)
        if magnitudeHistory.count > smoothingWindow {
            magnitudeHistory.removeFirst()
        }
        let smoothed = magnitudeHistory.reduce(0, +) / Double(magnitudeHistory.count)
        magnitude = smoothed
        let nowStill = smoothed < stillThreshold
        if isStill != nowStill { isStill = nowStill }
        // Resolve the steady gate if one is armed and we've dropped below its
        // (possibly tighter) threshold.
        if steadyCheckContinuation != nil, smoothed < gateThreshold {
            resolveSteadyGate(true)
        }
    }
    #endif

    /// Resolves the armed gate exactly once — later calls are no-ops because the
    /// continuation is cleared here.
    private func resolveSteadyGate(_ steady: Bool) {
        steadyCheckTimer?.invalidate()
        steadyCheckTimer = nil
        guard let continuation = steadyCheckContinuation else { return }
        steadyCheckContinuation = nil
        continuation.resume(returning: steady)
    }

    // MARK: - Capture log (Interval use)
    /// Call once per frame captured during an Interval session, tagging that
    /// frame with the motion reading at capture time.
    func logCapture(index: Int) {
        captureLog.append((captureIndex: index, magnitude: magnitude))
    }

    func resetLog() {
        captureLog = []
    }

    /// Indices whose capture-time magnitude exceeded the threshold — the frames
    /// worth reviewing (or dropping) as motion-blurred tails.
    func noisyIndices(threshold: Double? = nil) -> [Int] {
        let t = threshold ?? stillThreshold
        return captureLog.filter { $0.magnitude > t }.map { $0.captureIndex }
    }
}
