import Foundation
import AVFoundation
import CoreVideo
import ImageIO
import Observation
import LetsLapseKit

// Auto shape mode: the Photo viewfinder's live shape pass. While the toggle in
// the shutter cluster is on and the screen is idle in Photo mode, the camera
// taps preview frames to `ShapeFrameTap`, `LiveShapeFinder` runs the Kit's
// detector in its `live` profile on one frame at a time, and the shapes it
// finds are traced on the viewfinder (see `liveShapesOverlay` in CaptureView).
// Tapping a traced shape dismisses it; what is still on screen when the
// shutter fires goes into the new project's register (`ViewfinderShapes`),
// and turning the toggle off and on forgets every dismissal.
//
// Field-test build (2026-09-11): the rates and holds below are starting
// values, to be tuned on a phone. The pass is deliberately the cheap half of
// the pair — the file pass after the capture supplies the precision.

/// Receives the preview frames the camera taps off the session and runs the
/// finder on them, synchronously on its own queue. Synchronous for the reason
/// the Scanner's detector is: a `CVPixelBuffer` is only guaranteed for the
/// life of its sample buffer, and the output discards late frames anyway, so a
/// sample that takes too long costs frames rather than correctness.
final class ShapeFrameTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// `.default`: below the interface, above background work. `.utility`
    /// was tried and put the pass on the efficiency cores, where a busy
    /// scene's sample ran 3–5× longer for no gain — the governor below is
    /// what keeps the pass from crowding anything, not the QoS.
    let queue = DispatchQueue(label: "letslapse.shapes.tap", qos: .default)
    /// Called on `queue` with each frame that is taken.
    var handler: ((CVPixelBuffer) -> Void)?
    private var nextAllowed = Date.distantPast
    /// The camera's delivery rate as this output sees it — every frame lands
    /// here before the governor decides, so this is the viewfinder's own
    /// frame rate, the number a throttled camera shows first. Read by the
    /// finder for its log line.
    private(set) var deliveredFPS: Double = 0
    /// The camera's own frame period, from the smallest gap between the
    /// presentation timestamps of consecutive delivered frames in the window:
    /// frames dropped while a sample runs widen a gap, they never narrow one,
    /// so the minimum is the rate the sensor is actually running at.
    private(set) var cameraPeriod: Double = 0
    private var windowStart = Date.distantPast
    private var windowFrames = 0
    private var lastPTS: Double = -1
    private var minGap = Double.greatestFiniteMagnitude
    private var received = 0

    /// The cadence on a device fast enough for it: 5 Hz. A viewfinder aid
    /// does not need more, and the heat budget in Photo mode is the next
    /// shot's, not this pass's.
    static let minimumInterval: TimeInterval = 0.2
    /// The governor: after a sample of `d` seconds the queue rests for at
    /// least `restFactor × d` before the next, so the pass never holds more
    /// than ~40 % of a core however expensive the dials make a sample. Spacing
    /// only the *starts* was the 2026-09-11 13:21 regression: a Debug build's
    /// sample outgrew the 200 ms and the queue ran back-to-back, iOS answered
    /// by throttling the camera to 8 fps.
    static let restFactor = 1.5

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        windowFrames += 1
        received += 1
        if received == 1 || received == 2 || received == 10 || received % 300 == 0 {
            LLog(String(format: "shapes: tap frame %d, governor opens in %.0f ms", received, max(0, nextAllowed.timeIntervalSince(now)) * 1000))
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if lastPTS >= 0, pts > lastPTS { minGap = min(minGap, pts - lastPTS) }
        lastPTS = pts
        let elapsed = now.timeIntervalSince(windowStart)
        if elapsed >= 2 {
            if windowStart != .distantPast {
                deliveredFPS = Double(windowFrames - 1) / elapsed
                if minGap < .greatestFiniteMagnitude { cameraPeriod = minGap }
            }
            windowStart = now
            windowFrames = 1
            minGap = .greatestFiniteMagnitude
        }
        guard now >= nextAllowed, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handler?(buffer)
        let took = Date().timeIntervalSince(now)
        nextAllowed = Date().addingTimeInterval(max(Self.minimumInterval - took, Self.restFactor * took))
    }
}

/// The tap-queue half of the finder: the pose to detect at and one detector
/// run per frame. Its own object so the main-actor finder has no state a
/// background queue touches.
final class ShapeSampler: @unchecked Sendable {
    struct Result {
        var shapes: [DetectedShape]
        var frameSize: CGSize
        var measuredIn: QuadOrientation
        var seconds: Double
        var diagnostics: ShapeDetector.Diagnostics
    }

    private let lock = NSLock()
    private var imageOrientation: CGImagePropertyOrientation = .right
    private var quadOrientation: QuadOrientation = .right
    private var detector = ShapeDetector(settings: .live)

    /// The pose a still captured now would be tagged with, in both vocabularies
    /// (Vision's and the Kit's), set together so they cannot drift apart.
    func setOrientation(image: CGImagePropertyOrientation, quad: QuadOrientation) {
        lock.withLock {
            imageOrientation = image
            quadOrientation = quad
        }
    }

    /// The dials, as detector settings, for the next frame on.
    func setSearch(_ search: ShapeSearch) {
        lock.withLock { detector = ShapeDetector(settings: search.liveSettings()) }
    }

    /// One frame through the live profile.
    func sample(_ buffer: CVPixelBuffer) -> Result {
        let (image, quad, detector): (CGImagePropertyOrientation, QuadOrientation, ShapeDetector) = lock.withLock {
            (self.imageOrientation, self.quadOrientation, self.detector)
        }
        let started = Date()
        let size = ShapeDetector.uprightSize(of: buffer, orientation: image)
        var shapes: [DetectedShape] = []
        var diagnostics = ShapeDetector.Diagnostics()
        if let upright = ShapeDetector.uprightImage(buffer, orientation: image, longEdge: detector.settings.detectionLongEdge),
           let result = try? detector.detectWithDiagnostics(in: upright, nativeSize: size) {
            shapes = result.shapes
            diagnostics = result.diagnostics
        }
        return Result(shapes: shapes, frameSize: size, measuredIn: quad,
                      seconds: Date().timeIntervalSince(started), diagnostics: diagnostics)
    }
}

/// The shapes currently traced on the viewfinder, with what the person did
/// to them. Main-thread state; detection happens on the tap's queue and lands
/// here through `ingest`.
///
/// `@Observable` rather than `ObservableObject`, and it matters: the capture
/// screen's body is the most expensive on the app, and an `ObservableObject`
/// re-renders every view holding it on every publish — five times a second
/// here, for a layer that is one `Canvas`. With observation tracking only the
/// views that read `tracks` (the overlay) re-render; the screen itself reads
/// nothing of this in its body (the tap's hit-test reads it from a closure).
@Observable
@MainActor
final class LiveShapeFinder {

    /// One shape being followed across samples. Identity survives as long as
    /// each sample's detection overlaps the last one enough (`matchThreshold`).
    struct Track: Identifiable, Equatable {
        let id: UUID
        /// Normalised to the upright preview frame, top-left origin — the
        /// register's own space.
        var shape: DetectedShape
        var lastSeen: Date
        /// Samples this track has been seen in. A shape is drawn from its
        /// second sighting: a one-sample false positive then never blinks on.
        var sightings: Int

        func isConfirmed(sightingsToShow: Int) -> Bool { sightings >= sightingsToShow }
    }

    /// Everything followed right now, confirmed or not, in first-seen order.
    private(set) var tracks: [Track] = []
    /// The pose the tracks are measured in — the capture pose, not the
    /// interface's, for the reason the Scanner's quad is (see
    /// `RectangleDetector.imageOrientation`); the overlay converts.
    private(set) var orientation: QuadOrientation = .right
    /// The upright preview frame's pixel size, from the last sample.
    private(set) var frameSize: CGSize = .zero
    /// The dials. Set by the capture screen; a change starts the tracks over
    /// (different gates, different resolution — a fresh look), dismissals
    /// stand (they are geometry, and the same thing is still not wanted).
    var search = ShapeSearch() {
        didSet {
            guard search != oldValue else { return }
            sampler.setSearch(search)
            tracks.removeAll()
        }
    }
    /// Seconds the last sample's detection took, and how many samples have
    /// landed — the field-test readout, logged every 25th sample. Not
    /// observed: they change on every sample and nothing on screen shows them.
    @ObservationIgnored private(set) var lastSampleSeconds: Double = 0
    @ObservationIgnored private(set) var sampleCount = 0
    /// Samples that found at least one shape, and the last sample's own
    /// account — what it looked at and refused. Both go with the shutter.
    @ObservationIgnored private(set) var samplesWithShapes = 0
    @ObservationIgnored private(set) var lastDiagnostics: ShapeDetector.Diagnostics?

    /// Shapes tapped away. A later detection overlapping one of these is
    /// swallowed and the entry follows it, so a dismissed shape stays gone as
    /// the frame drifts — across shots too, so the lamp you dismissed stays
    /// dismissed for the next frame of the same scene. Only `reset()` (the
    /// toggle, off and on) clears it.
    @ObservationIgnored private(set) var dismissed: [DetectedShape] = []

    @ObservationIgnored let tap = ShapeFrameTap()
    @ObservationIgnored private let sampler = ShapeSampler()

    /// How long a track stands after its last sighting, at the 5 Hz cadence:
    /// four samples, so a shape the tracer drops for a frame or two stays
    /// traced and one that has really gone is off within a second. The hold
    /// actually used scales with the cadence the pass is achieving (see
    /// `holdFor`): on a busy scene in a Debug build a sample plus its rest
    /// ran 1.4–2.4 s, longer than this, and every track expired before the
    /// next sample could confirm it — found, forgotten, found, forgotten
    /// (2026-09-11 14:54, the medallion at 5×).
    static let baseHold: TimeInterval = 0.8
    /// Sightings before a track is drawn at the 5 Hz cadence (a one-sample
    /// false positive never blinks on). When samples are slower than 0.4 s
    /// apart the first sighting shows: waiting a second cycle would mean
    /// seconds of nothing on screen.
    static let baseSightingsToShow = 2
    /// Seconds between the last two samples that landed.
    @ObservationIgnored private var lastIngestAt: Date?
    @ObservationIgnored private(set) var samplePeriod: TimeInterval = 0.2

    var holdFor: TimeInterval { max(Self.baseHold, 2.5 * samplePeriod) }
    var sightingsToShow: Int { samplePeriod > 0.4 ? 1 : Self.baseSightingsToShow }
    /// Same-thing test between samples, and against the dismissed list.
    static let matchThreshold = ShapeReconciler.matchThreshold

    init() {
        let sampler = self.sampler
        tap.handler = { [weak self] buffer in
            let result = sampler.sample(buffer)
            Task { @MainActor in
                self?.ingest(result.shapes, frameSize: result.frameSize,
                             measuredIn: result.measuredIn, seconds: result.seconds, diagnostics: result.diagnostics)
            }
        }
    }

    // MARK: - Pose

    /// The pose a still captured now would be tagged with. Pushed by the
    /// capture screen whenever its own reading changes.
    func setCaptureOrientation(_ pose: AVCaptureVideoOrientation) {
        let quad = QuadOrientation(pose: pose)
        let image: CGImagePropertyOrientation
        switch quad {
        case .up: image = .up
        case .right: image = .right
        case .down: image = .down
        case .left: image = .left
        }
        sampler.setOrientation(image: image, quad: quad)
        if orientation != quad {
            orientation = quad
            // Shapes measured in the old pose would be drawn a quarter turn
            // off until the next sample replaced them; drop them now.
            tracks.removeAll()
        }
    }

    // MARK: - Sampling

    /// Fold one sample into the tracks: a detection overlapping a dismissed
    /// shape refreshes that entry and is otherwise ignored; one overlapping a
    /// live track updates it; the rest start tracks. Tracks unseen for
    /// `holdFor` are dropped.
    func ingest(_ shapes: [DetectedShape], frameSize: CGSize, measuredIn pose: QuadOrientation,
                seconds: Double, diagnostics: ShapeDetector.Diagnostics? = nil, at now: Date = Date()) {
        sampleCount += 1
        lastSampleSeconds = seconds
        if !shapes.isEmpty { samplesWithShapes += 1 }
        if let diagnostics { lastDiagnostics = diagnostics }
        if let last = lastIngestAt {
            let gap = now.timeIntervalSince(last)
            if gap > 0 { samplePeriod = 0.5 * samplePeriod + 0.5 * gap }
        }
        lastIngestAt = now
        if sampleCount == 1 || sampleCount % 25 == 0 {
            LLog(String(format: "shapes: sample %d took %.0f ms every %.2f s (%@), %d found, %d tracked, %d dismissed; %d of %d samples found anything; tap saw %.1f fps, camera period %.1f ms (%.0f fps)",
                        sampleCount, seconds * 1000, samplePeriod, search.token, shapes.count, tracks.count, dismissed.count,
                        samplesWithShapes, sampleCount,
                        tap.deliveredFPS, tap.cameraPeriod * 1000, tap.cameraPeriod > 0 ? 1 / tap.cameraPeriod : 0))
            if let diagnostics, shapes.isEmpty {
                LLog("shapes: last sample refused — \(diagnostics.summary)" + (diagnostics.refusals.isEmpty ? "" : "; " + diagnostics.refusals.prefix(4).map { "\($0.kind) \(Int($0.size * 100))% \($0.reason)" }.joined(separator: "; ")))
            }
        }
        // A sample measured in a pose that has since changed is a quarter turn
        // off; the next one will be right.
        guard pose == orientation else { return }
        self.frameSize = frameSize
        var next = tracks
        for shape in shapes {
            if let d = ShapeReconciler.bestMatch(for: shape, in: dismissed) {
                dismissed[d] = shape
                continue
            }
            if let i = ShapeReconciler.bestMatch(for: shape, in: next.map(\.shape)) {
                next[i].shape = shape
                next[i].lastSeen = now
                next[i].sightings += 1
            } else {
                next.append(Track(id: UUID(), shape: shape, lastSeen: now, sightings: 1))
            }
        }
        let hold = holdFor
        next.removeAll { now.timeIntervalSince($0.lastSeen) > hold }
        if next != tracks { tracks = next }
    }

    /// The tracks worth drawing.
    var visible: [Track] {
        let needed = sightingsToShow
        return tracks.filter { $0.isConfirmed(sightingsToShow: needed) }
    }

    // MARK: - What the person does

    /// Tap on a traced shape: it goes, and stays gone (see `dismissed`).
    func dismiss(_ id: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        dismissed.append(tracks[i].shape)
        tracks.remove(at: i)
    }

    /// The toggle's off-and-on: every dismissal forgotten, every track dropped
    /// so the next samples redraw from nothing.
    func reset() {
        tracks.removeAll()
        dismissed.removeAll()
        sampleCount = 0
        samplesWithShapes = 0
        lastSampleSeconds = 0
        lastDiagnostics = nil
    }

    /// What the shutter takes with it: the confirmed shapes on screen and the
    /// dismissed ones, in the upright preview frame. Nil only when nothing
    /// was measured yet (no sample has landed). An empty snapshot is still a
    /// snapshot: the file pass — the better detector, on a sharp still — runs
    /// on the photo whatever the viewfinder managed, and records what it
    /// finds as plain detections (2026-09-11: a medallion the live pass lost
    /// to a blurred 10 fps preview was in the photo at 0.77 and never
    /// recorded because the shutter had nothing to carry).
    /// … and a viewfinder that never got a sample still reports that it
    /// was on, with its dials: the register's trail is the field-test
    /// record, and "on, High, nothing landed" is a finding.
    func snapshot() -> ViewfinderShapes? {
        ViewfinderShapes(kept: frameSize.width > 0 ? visible.map(\.shape) : [], dismissed: dismissed, frameSize: frameSize,
                         search: search, samples: sampleCount, samplesWithShapes: samplesWithShapes, lastSample: lastDiagnostics)
    }

    // MARK: - Screenshot staging

    /// `LL_SHAPEFINDER=shapes`: a circle and a keystoned quad traced over the
    /// (cameraless) simulator's viewfinder, in a portrait pose on a frame of
    /// the given upright pixel size.
    func stageDemoShapes(frameSize frame: CGSize = CGSize(width: 3024, height: 4032)) {
        orientation = .right
        sampler.setOrientation(image: .right, quad: .right)
        frameSize = frame
        let W = Double(frame.width), H = Double(frame.height)
        let now = Date.distantFuture
        let circle = DetectedShape(kind: .ellipse, centre: CGPoint(x: 0.36, y: 0.30), majorAxis: 0.42, minorAxis: 0.40,
                                   rotation: 0.3, corners: nil, confidence: 0.9, nativeDiameterPx: 0.42 * W)
        let corners = [CGPoint(x: 0.50, y: 0.55), CGPoint(x: 0.88, y: 0.53), CGPoint(x: 0.90, y: 0.78), CGPoint(x: 0.52, y: 0.80)]
        let m = DetectedShape.quadMetrics(cornersPx: corners.map { CGPoint(x: $0.x * W, y: $0.y * H) })
        let quad = DetectedShape(kind: .quad, centre: CGPoint(x: 0.70, y: 0.665), majorAxis: m.major / W, minorAxis: m.minor / W,
                                 rotation: m.rotation, corners: corners, confidence: 0.85, nativeDiameterPx: m.major, wide: m.wide)
        tracks = [Track(id: UUID(), shape: circle, lastSeen: now, sightings: 9),
                  Track(id: UUID(), shape: quad, lastSeen: now, sightings: 9)]
    }
}

extension QuadOrientation {
    /// The Kit's name for the turn a capture pose asks of the sensor image —
    /// the same table `RectangleDetector` states for the Scanner, restated
    /// here without its iOS gate because the Photo viewfinder exists on the
    /// Mac too (where the pose is always `.landscapeRight`, the read-out).
    /// Back camera: the front camera's buffers are mirrored and would need
    /// the mirrored cases.
    init(pose: AVCaptureVideoOrientation) {
        switch pose {
        case .portrait: self = .right
        case .portraitUpsideDown: self = .left
        case .landscapeRight: self = .up
        case .landscapeLeft: self = .down
        @unknown default: self = .right
        }
    }
}
