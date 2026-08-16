import Foundation
import LetsLapseKit
#if os(iOS)
import AVFoundation
import CoreVideo
#endif

// MARK: - The state machine

/// **Scanner** — the decision of *when* to fire, taken from the scene instead
/// of from a timer.
///
/// The shooting loop it exists for: put the object down, take your hand out of
/// frame, hear the click, reach in, move it, take your hand out again, hear the
/// click. Thirty-six times around a turntable is the canonical photogrammetry
/// set, and every one of those frames is a pose the operator chose — so the
/// camera's whole job is to notice that the choosing has finished.
///
/// Three states, and the transition that matters is the third:
///
/// | State | Meaning |
/// |---|---|
/// | `settled` | Waiting. This pose is already captured; nothing to do until something moves. |
/// | `disturbed` | Motion — a hand entering the frame, the object being turned. |
/// | `reSettled` | The scene has gone still again. Fire, now. |
///
/// `reSettled` is momentary by construction: the engine emits its fire signal
/// and drops straight back to `settled`, because the frame it just took *is*
/// this pose. There is no state in which the engine is "ready to fire and
/// waiting" — readiness and firing are the same instant.
///
/// **The settle delay is wall-clock, not a frame count.** Preview frames arrive
/// at whatever rate the session and the light allow (a dark scene at a long
/// exposure delivers far fewer), so "still for 30 frames" means something
/// different every time the light changes. "Still since a moment 1.0 s ago"
/// means the same thing always. The engine takes the time with every
/// measurement rather than reading a clock itself, which is also what makes it
/// testable without waiting in real time.
///
/// The engine is deliberately not an actor and holds no I/O: it is called from
/// the camera's own serial queue, once per preview frame, and every field it
/// owns is confined to that queue by the caller. See `ScannerMotionAnalyzer`
/// for the measurement side.
final class ScannerEngine {

    enum State: String, Equatable {
        case settled
        case disturbed
        /// Transient — see the note above; the engine never rests here.
        case reSettled
    }

    // MARK: Tuning

    /// How long the scene must read as still before the shot is taken.
    ///
    /// The trade is entirely about the operator's hand: too short and the
    /// shutter catches fingers still withdrawing, too long and the loop feels
    /// like it has stalled. 1.0 s is comfortable at arm's length. The
    /// user-facing range is 0.5–3.0 s; exposing it is Phase 2 (see the class
    /// note on `motionThreshold`).
    static let defaultSettleDelay: TimeInterval = 1.0
    static let settleDelayRange: ClosedRange<TimeInterval> = 0.5...3.0

    /// Mean absolute frame difference, 0…1, above which the scene reads as
    /// moving.
    ///
    /// It is deliberately high, because the two failure modes are not
    /// symmetric: a threshold set too low turns sensor noise, a flickering bulb
    /// or an auto-exposure twitch into a permanent `disturbed` and the shoot
    /// never fires at all, where an over-eager one costs a frame the operator
    /// can delete. **Both halves of that have now been observed** (iPad Air 5,
    /// static indoor scene, 2026-08-16):
    ///
    /// | | |
    /// |---|---|
    /// | Scene noise floor | ~0.0059 median, 0.0056 min, 0.0131 max over 122 samples |
    /// | At 0.0015 | 100% of samples read as motion → stuck `disturbed` for 125 s, zero fires |
    /// | At 0.008 | ~6% read as motion → real disturb/settle cycles, fires normally |
    /// | At 0.028 (shipped) | 0 of 122 samples read as motion |
    /// | At 0.035 (the original guess) | 0 of 122 |
    ///
    /// The value set from that: **0.028**, ~4.7× the median noise floor and
    /// ~2.1× the worst excursion, with no false trigger anywhere in the sample.
    /// It came down from the original 0.035 deliberately. Both cleared the
    /// noise identically, so the extra margin there bought nothing measurable
    /// and cost sensitivity — and sensitivity is the side that is still
    /// unmeasured (see below), so the tie goes to catching the hand. Measure
    /// your own scene with the DEBUG hooks below: `CameraController` logs
    /// `scanner: mag=…` at 1 Hz through a run.
    ///
    /// **TODO (tuning): the upper bound is still unmeasured.** Nothing here
    /// says how high a *hand* crossing the frame reads, because that needs a
    /// person in front of the camera and the runs above had none. Until it is,
    /// the headroom above 0.028 is an assumption — a slow hand at arm's length
    /// filling little of a 64×48 grid is the case most likely to fall short of
    /// it. Confirm before this becomes a user-facing setting.
    static let defaultMotionThreshold: Float = 0.028

    /// How far a corner may travel, as a fraction of the frame, and still count
    /// as stationary — the rectangle path's equivalent of `motionThreshold`.
    ///
    /// It is a much more specific measurement than the frame difference is:
    /// four points on the object itself, rather than an average over
    /// everything the camera can see. That is the whole reason the path exists.
    /// A page being placed moves its corners tens of percent; a page lying
    /// still moves them by the detector's own jitter, which is a fraction of a
    /// percent on a well-lit edge and larger as contrast falls.
    ///
    /// **TODO (calibration): 2% is a starting value, not a measured one.** It
    /// wants the same treatment `defaultMotionThreshold` got — a real device
    /// over a real copy stand, logging the corner jitter of a stationary page
    /// at several light levels, and the jitter of one being placed. The two
    /// failure modes mirror the differencing threshold's: too tight and
    /// detector noise reads as a page that never settles, too loose and the
    /// shutter catches a page still sliding. Override in the field with
    /// `-scanner.cornerThreshold 0.01`.
    static let defaultCornerStabilityThreshold: Double = 0.02

    let settleDelay: TimeInterval
    let motionThreshold: Float
    let cornerStabilityThreshold: Double

    #if DEBUG
    /// Field-tuning overrides, read from `UserDefaults` so they can arrive as
    /// launch arguments on a device that is across a room:
    ///
    ///     devicectl … launch … -- -scanner.motionThreshold 0.002 -scanner.settleDelay 0.6
    ///
    /// This is the lever `defaultMotionThreshold`'s TODO asks for. The number
    /// there is a guess that wants a real device, a real turntable and a range
    /// of light levels before it moves, and none of that is reachable without
    /// being able to change it *while pointed at the thing*. It also makes the
    /// whole capture path — preview tap, downsample, difference, engine, fire,
    /// file, wire — testable against a scene that only drifts, by dropping the
    /// bar to where ambient movement clears it.
    ///
    /// DEBUG-only and deliberately not surfaced in Settings: a user-facing
    /// threshold is Phase 2, after the tuning this exists to serve.
    static func overriddenThreshold() -> Float? {
        guard UserDefaults.standard.object(forKey: "scanner.motionThreshold") != nil else { return nil }
        let value = Float(UserDefaults.standard.double(forKey: "scanner.motionThreshold"))
        return value > 0 ? value : nil
    }

    static func overriddenSettleDelay() -> TimeInterval? {
        guard UserDefaults.standard.object(forKey: "scanner.settleDelay") != nil else { return nil }
        let value = UserDefaults.standard.double(forKey: "scanner.settleDelay")
        return value > 0 ? value : nil
    }

    /// The same lever for the corner-stability threshold, and for the same
    /// reason: the number in `defaultCornerStabilityThreshold` is a guess until
    /// someone can change it while pointed at a page.
    static func overriddenCornerThreshold() -> Double? {
        guard UserDefaults.standard.object(forKey: "scanner.cornerThreshold") != nil else { return nil }
        let value = UserDefaults.standard.double(forKey: "scanner.cornerThreshold")
        return value > 0 ? value : nil
    }
    #endif

    // MARK: State

    private(set) var state: State = .settled
    /// When the scene was last seen moving. The settle window is measured from
    /// here, so any motion at all restarts it.
    private var lastMotionAt: Date?
    /// Whether the opening frame has been handed out yet.
    private var hasFiredFirstPose = false
    /// The most recent measurement, for the HUD.
    private(set) var lastMagnitude: Float = 0
    /// Every corner sample since the last disturbance, pruned to the settle
    /// window — "the last N frames" the stability test looks back over, kept as
    /// times rather than a count for the same reason the settle delay is wall
    /// clock: the preview's frame rate is not a constant.
    private var cornerSamples: [(time: Date, quad: NormalizedQuad)] = []
    /// Whether the last measurement had a rectangle in it — i.e. which of the
    /// two settle paths is currently deciding when to fire.
    private(set) var isTrackingRectangle = false

    init(
        settleDelay: TimeInterval = ScannerEngine.defaultSettleDelay,
        motionThreshold: Float = ScannerEngine.defaultMotionThreshold,
        cornerStabilityThreshold: Double = ScannerEngine.defaultCornerStabilityThreshold
    ) {
        var resolvedDelay = settleDelay
        var resolvedThreshold = motionThreshold
        var resolvedCornerThreshold = cornerStabilityThreshold
        #if DEBUG
        resolvedDelay = ScannerEngine.overriddenSettleDelay() ?? resolvedDelay
        resolvedThreshold = ScannerEngine.overriddenThreshold() ?? resolvedThreshold
        resolvedCornerThreshold = ScannerEngine.overriddenCornerThreshold() ?? resolvedCornerThreshold
        #endif
        self.cornerStabilityThreshold = resolvedCornerThreshold
        // The delay is clamped to the range the UI will eventually offer; the
        // threshold deliberately isn't, because tuning it means being able to
        // go absurdly low on purpose and watch what fires.
        self.settleDelay = min(max(resolvedDelay, ScannerEngine.settleDelayRange.lowerBound),
                               ScannerEngine.settleDelayRange.upperBound)
        self.motionThreshold = resolvedThreshold
    }

    /// Arms the engine for a run and asks for the opening frame.
    ///
    /// The first pose is already framed — the operator set it up before
    /// pressing the shutter — so it is captured immediately rather than made to
    /// wait for a disturb/re-settle cycle that would require them to touch a
    /// scene they had just finished arranging.
    ///
    /// Returns `true`, which the caller treats exactly like any other fire
    /// signal, so the opening frame goes through the same steadiness gate and
    /// the same capture path as every frame after it.
    @discardableResult
    func start(at time: Date) -> Bool {
        state = .settled
        lastMotionAt = nil
        lastMagnitude = 0
        cornerSamples = []
        isTrackingRectangle = false
        hasFiredFirstPose = true
        return true
    }

    /// One frame's worth of everything the camera can say about the scene: how
    /// different it is from the last frame, and where the flat object in it is
    /// — if there is one. Returns `true` on the tick the scene has just
    /// finished re-settling, exactly as `motionMagnitude` does.
    ///
    /// **Two settle paths, and the rectangle is the better one.** With a quad
    /// in view the re-settle test is the four corners standing still, which is
    /// a measurement of *the object* rather than of the frame: it sees a page
    /// creeping a millimetre a second, which a frame difference averages into
    /// nothing, and it ignores a lighting shift or a shadow crossing the desk,
    /// which a frame difference reads as motion. With no quad — the object is
    /// out of frame, unlit, or simply isn't flat — the path falls back to the
    /// Phase 1 differencing unchanged, because a signal that doesn't exist is
    /// worse than a coarse one that does.
    ///
    /// The two are not exclusive on the *disturb* side, and deliberately so: a
    /// hand crossing the frame or the page being swapped for another in the
    /// same place moves the frame without moving the corners, and either should
    /// restart the settle window. So anything disturbs, and only corners settle.
    @discardableResult
    func observe(magnitude: Float, quad: NormalizedQuad?, at time: Date) -> Bool {
        guard let quad else {
            cornerSamples = []
            isTrackingRectangle = false
            return motionMagnitude(magnitude, at: time)
        }

        lastMagnitude = magnitude
        isTrackingRectangle = true
        guard hasFiredFirstPose else { return false }

        let cornersMoved = cornerSamples.last
            .map { $0.quad.maxCornerDistance(to: quad) > cornerStabilityThreshold } ?? false
        cornerSamples.append((time: time, quad: quad))
        // The window is the settle delay, so a scene that has been still for a
        // minute holds a second's worth of samples, not a minute's.
        cornerSamples.removeAll { time.timeIntervalSince($0.time) > settleDelay }

        if magnitude > motionThreshold || cornersMoved {
            state = .disturbed
            lastMotionAt = time
            cornerSamples = [(time: time, quad: quad)]
            return false
        }

        guard state == .disturbed, let since = lastMotionAt else { return false }
        guard time.timeIntervalSince(since) >= settleDelay else { return false }
        // Every sample in the window against the newest, not just the newest
        // against the one before it: a page sliding slower than the per-frame
        // threshold passes that test on every frame and fails this one, which
        // is precisely the drift the corner path exists to catch.
        guard cornerSamples.allSatisfy({
            $0.quad.maxCornerDistance(to: quad) <= cornerStabilityThreshold
        }) else { return false }

        state = .settled
        lastMotionAt = nil
        cornerSamples = [(time: time, quad: quad)]
        return true
    }

    /// Folds one motion measurement into the machine. Returns `true` on the
    /// single tick where the scene has just finished re-settling — the caller's
    /// cue to fire.
    ///
    /// This is the frame-differencing path: the whole story in Phase 1, and the
    /// fallback since — `observe(magnitude:quad:at:)` is what the camera calls
    /// now, and it comes here whenever there is no rectangle to watch instead.
    ///
    /// Note what this does *not* do: it never gates on the device being steady.
    /// That is a second, independent signal (`SteadinessMonitor`) and the caller
    /// requires both, because a still scene shot from a wobbling phone is a
    /// blurred frame that a solver will happily accept and then reconstruct
    /// badly. Keeping the two apart means neither can mask the other.
    @discardableResult
    func motionMagnitude(_ value: Float, at time: Date) -> Bool {
        lastMagnitude = value
        guard hasFiredFirstPose else { return false }

        if value > motionThreshold {
            state = .disturbed
            lastMotionAt = time
            return false
        }

        // Below threshold. Only a scene that was disturbed can re-settle;
        // a quiet scene that was already settled has nothing to report.
        guard state == .disturbed, let since = lastMotionAt else { return false }
        guard time.timeIntervalSince(since) >= settleDelay else { return false }

        // reSettled is passed through rather than rested in: the frame about to
        // be taken is this pose, so the engine is already waiting for the next
        // disturbance by the time the caller sees the signal.
        state = .settled
        lastMotionAt = nil
        return true
    }

    /// How far through the settle window the scene currently is, 0…1 — the
    /// progress the HUD draws while `disturbed`. Nil when nothing is settling.
    func settleProgress(at time: Date) -> Double? {
        guard state == .disturbed, let since = lastMotionAt else { return nil }
        return min(max(time.timeIntervalSince(since) / settleDelay, 0), 1)
    }

    /// Ends the run. A stopped engine reports `settled` and fires nothing —
    /// `start` is the only thing that re-arms it.
    func stop() {
        state = .settled
        lastMotionAt = nil
        hasFiredFirstPose = false
        lastMagnitude = 0
        cornerSamples = []
        isTrackingRectangle = false
    }
}

// MARK: - Measurement

#if os(iOS)

/// Turns the preview stream into the single scalar `ScannerEngine` consumes:
/// the mean absolute difference between consecutive frames, normalised to 0…1.
///
/// **Why it downsamples first, and hard.** Frame differencing answers "did
/// anything in this scene move", which is a question about the whole frame, not
/// about detail. A 64×48 thumbnail answers it as well as 4032×3024 does, costs
/// four thousand times less arithmetic, and — the part that matters more —
/// *averages sensor noise away for free*, so the threshold can sit near where
/// real motion starts instead of above where noise ends. Downsampling is the
/// noise filter here, not just the optimisation.
///
/// Luma only, from the green-ish middle of BGRA: a colour difference buys
/// nothing for "did it move" and triples the work.
///
/// iOS-only, and not by omission — this rides an `AVCaptureVideoDataOutput`
/// tap, and macOS's capture screen has no such preview path (nor manual
/// exposure to lock, which Scanner requires; see `startScanner`).
final class ScannerMotionAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// The grid the difference is computed on. 64×48 is 4:3, which every
    /// still-capture format the app runs the Scanner in already is, so the
    /// sampling grid never distorts the frame it measures.
    static let gridWidth = 64
    static let gridHeight = 48

    /// The tap's own queue, matching the other preview taps in
    /// `CameraController` (test card, Watch framing).
    let queue = DispatchQueue(label: "letslapse.scanner.motion")

    /// Called on `queue` with each new magnitude, the flat object in frame (if
    /// any) and the wall-clock moment both describe. The camera hops to its
    /// session queue from here.
    ///
    /// The pair travels together rather than as two callbacks because the
    /// engine folds them into one decision: they must describe the same
    /// instant, or a settle could be judged against a rectangle seen half a
    /// second ago.
    var onSample: ((Float, NormalizedQuad?, Date) -> Void)?

    /// Finds the page/document/print, when there is one. Owned by the camera
    /// (which keeps its orientation current) and driven from here, off the same
    /// frames the differencing uses — one tap, two questions. Nil leaves the
    /// analyzer in its Phase 1 behaviour exactly.
    var rectangleDetector: RectangleDetector?

    /// Previous frame's luma grid. Nil until the second frame — the first has
    /// nothing to be different from and is skipped rather than reported as a
    /// full-frame change, which would open every run with a false disturb.
    private var previous: [Float]?

    /// Ceiling on how often frames are measured. The preview can deliver 30–60
    /// a second and the settle window is a full second wide, so 20 Hz is a
    /// generous sampling of it and leaves the camera's queue alone the rest of
    /// the time.
    private static let minimumSampleInterval: TimeInterval = 0.05
    private var lastSampledAt = Date.distantPast

    /// Drops the frame history, so the next frame starts a fresh comparison.
    /// Called when a run starts and when the session reconfigures (a lens or
    /// format change moves every pixel and would otherwise read as motion).
    func reset() {
        queue.async {
            self.previous = nil
            self.rectangleDetector?.reset()
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastSampledAt) >= Self.minimumSampleInterval,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSampledAt = now
        // Detection first, and synchronously, while the sample buffer still
        // guarantees these pixels: the quad it produces has to describe the
        // same frame the difference below does.
        rectangleDetector?.detect(in: buffer, at: now)
        guard let grid = Self.lumaGrid(from: buffer) else { return }
        defer { previous = grid }
        guard let previous, previous.count == grid.count else { return }

        var sum: Float = 0
        for index in 0..<grid.count {
            sum += abs(grid[index] - previous[index])
        }
        let magnitude = sum / Float(grid.count)
        onSample?(magnitude, rectangleDetector?.quad(at: now), now)
    }

    /// Point-samples a BGRA pixel buffer down to the fixed grid, returning
    /// luma in 0…1.
    ///
    /// Point sampling rather than box-averaging is deliberate: an averaging
    /// resample would blur away exactly the small, high-contrast changes (a
    /// hand's edge crossing the frame) that this is trying to detect, and the
    /// grid is already coarse enough that noise averages out across the *sum*
    /// over 3,072 cells even though no single cell is averaged.
    private static func lumaGrid(from buffer: CVPixelBuffer) -> [Float]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width >= gridWidth, height >= gridHeight else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        var grid = [Float](repeating: 0, count: gridWidth * gridHeight)
        for gridY in 0..<gridHeight {
            let sourceY = gridY * height / gridHeight
            let row = pixels.advanced(by: sourceY * bytesPerRow)
            for gridX in 0..<gridWidth {
                let sourceX = gridX * width / gridWidth
                let pixel = row.advanced(by: sourceX * 4)
                // BGRA. Rec. 601 luma weights — the differencing only needs a
                // perceptually sane scalar, not a colour-managed one.
                let blue = Float(pixel[0])
                let green = Float(pixel[1])
                let red = Float(pixel[2])
                grid[gridY * gridWidth + gridX] =
                    (0.299 * red + 0.587 * green + 0.114 * blue) / 255
            }
        }
        return grid
    }
}

#endif
