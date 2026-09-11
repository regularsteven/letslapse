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
    let queue = DispatchQueue(label: "letslapse.shapes.tap", qos: .userInitiated)
    /// Called on `queue` with each frame that is taken, at most every
    /// `minimumInterval` — a detection runs for most of that anyway.
    var handler: ((CVPixelBuffer) -> Void)?
    private var lastStarted = Date.distantPast

    /// Caps the pass at 5 Hz on a device fast enough to go faster: a viewfinder
    /// aid does not need more, and the heat budget in Photo mode is the next
    /// shot's, not this pass's.
    static let minimumInterval: TimeInterval = 0.2

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastStarted) >= Self.minimumInterval,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastStarted = now
        handler?(buffer)
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
        let shapes = (try? detector.detect(in: buffer, orientation: image)) ?? []
        return Result(shapes: shapes,
                      frameSize: ShapeDetector.uprightSize(of: buffer, orientation: image),
                      measuredIn: quad,
                      seconds: Date().timeIntervalSince(started))
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

        var isConfirmed: Bool { sightings >= LiveShapeFinder.sightingsToShow }
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

    /// Shapes tapped away. A later detection overlapping one of these is
    /// swallowed and the entry follows it, so a dismissed shape stays gone as
    /// the frame drifts — across shots too, so the lamp you dismissed stays
    /// dismissed for the next frame of the same scene. Only `reset()` (the
    /// toggle, off and on) clears it.
    @ObservationIgnored private(set) var dismissed: [DetectedShape] = []

    @ObservationIgnored let tap = ShapeFrameTap()
    @ObservationIgnored private let sampler = ShapeSampler()

    /// How long a track stands after its last sighting — four samples at the
    /// 5 Hz cadence, so a shape the tracer drops for a frame or two stays
    /// traced, and one that has really gone is off within a second.
    static let holdFor: TimeInterval = 0.8
    static let sightingsToShow = 2
    /// Same-thing test between samples, and against the dismissed list.
    static let matchThreshold = ShapeReconciler.matchThreshold

    init() {
        let sampler = self.sampler
        tap.handler = { [weak self] buffer in
            let result = sampler.sample(buffer)
            Task { @MainActor in
                self?.ingest(result.shapes, frameSize: result.frameSize,
                             measuredIn: result.measuredIn, seconds: result.seconds)
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
                seconds: Double, at now: Date = Date()) {
        sampleCount += 1
        lastSampleSeconds = seconds
        if sampleCount % 25 == 0 {
            LLog(String(format: "shapes: sample %d took %.0f ms (%@), %d found, %d tracked, %d dismissed",
                        sampleCount, seconds * 1000, search.token, shapes.count, tracks.count, dismissed.count))
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
        next.removeAll { now.timeIntervalSince($0.lastSeen) > Self.holdFor }
        if next != tracks { tracks = next }
    }

    /// The tracks worth drawing.
    var visible: [Track] { tracks.filter(\.isConfirmed) }

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
        lastSampleSeconds = 0
    }

    /// What the shutter takes with it: the confirmed shapes on screen and the
    /// dismissed ones, in the upright preview frame. Nil when nothing was
    /// measured yet (no sample has landed) — a register is not written for a
    /// viewfinder that never looked.
    func snapshot() -> ViewfinderShapes? {
        guard frameSize.width > 0, frameSize.height > 0 else { return nil }
        let kept = visible.map(\.shape)
        guard !kept.isEmpty || !dismissed.isEmpty else { return nil }
        return ViewfinderShapes(kept: kept, dismissed: dismissed, frameSize: frameSize, search: search)
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
