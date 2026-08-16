import Foundation
#if os(iOS)
import AVFoundation
import CoreVideo
import ImageIO
import LetsLapseKit
import Vision

/// Finds the flat thing in front of the camera — a page, a document, a print,
/// a card — and reports its four corners.
///
/// **What it is for.** Scanner Phase 1 decides when to fire from generic frame
/// differencing: "has anything in this scene changed". That answers the
/// turntable case well and the *copy-stand* case badly, because the two states
/// a document shoot alternates between (a hand placing a page, the page lying
/// still) differ by a hand-sized patch of a frame that is otherwise identical.
/// A rectangle gives a much stronger signal for the same moment: four points
/// that either are or aren't moving, measured on the object itself rather than
/// on the whole frame (see `ScannerEngine.observe`). It also produces the
/// geometry a perspective correction needs, which differencing never could.
///
/// iOS-only for the same reason the rest of the Scanner is: this rides the
/// preview tap that only the iOS capture path has. Vision itself is available
/// on macOS, so the guard is about where the frames come from, not the
/// framework.
final class RectangleDetector {

    // MARK: - Tuning

    /// Narrowest quad accepted, short side ÷ long side. 0.2 takes both a
    /// portrait page and a landscape one (A4 is 0.71 either way up) plus long
    /// thin objects like a receipt, and still rejects the frame-edge slivers a
    /// detector produces when it finds nothing real.
    static let minimumAspectRatio: Float = 0.2
    /// How far from a true rectangle a quad may be, in degrees. A page shot
    /// from the side keystones hard, and this is the tolerance that decides
    /// whether that keystone reads as "a rectangle at an angle" (which it is)
    /// or as "not a rectangle".
    static let quadratureTolerance: Float = 30
    static let minimumConfidence: VNConfidence = 0.6
    /// Several qualifying quads are kept rather than one, because "the best
    /// rectangle" and "the rectangle the operator means" are different
    /// questions — see `select`.
    static let maximumObservations = 5

    /// How often the request actually runs. The preview tap already throttles
    /// to 20 Hz for differencing; rectangle detection is the expensive half of
    /// the pair, and the thing it feeds (a settle window a second wide) is
    /// sampled plenty at 10 Hz.
    private static let minimumDetectionInterval: TimeInterval = 0.1

    /// How long a detection stands in for the frames between detections. Just
    /// over two detection intervals: long enough that the overlay doesn't
    /// flicker between requests, short enough that a page taken out of frame
    /// stops being reported almost immediately.
    static let staleAfter: TimeInterval = 0.25

    // MARK: - State

    /// The quad from the most recent successful detection, and when it landed.
    /// Written on the tap's queue, read on it too — `quad(at:)` is the only
    /// accessor and both callers are the analyzer.
    private(set) var latestQuad: NormalizedQuad?
    private var latestAt = Date.distantPast
    private var lastDetectionAt = Date.distantPast

    /// How the preview buffer has to be turned to be upright.
    ///
    /// A preview pixel buffer always arrives in the sensor's own landscape
    /// however the phone is held (see `CameraController.currentCaptureOrientation`),
    /// and Vision reports corners in the space of the image it was *given* —
    /// measured, not assumed: a rectangle painted down the left of an 800×600
    /// frame comes back from a `.right` request as a quad across the top of a
    /// 600×800 one (`NormalizedQuadOrientationTests`).
    ///
    /// This is the **capture** pose, not the interface's, and deliberately: the
    /// corners ride into `frames.timestamps` and are applied by
    /// `PerspectiveCorrector` to the still, which is tagged with exactly this
    /// orientation. The overlay is the side that has to convert, because the
    /// preview is drawn in the interface orientation and the two disagree under
    /// rotation lock and whenever the device is flat over a copy stand — which
    /// is most of a Scanner shoot. See `QuadOrientation`.
    ///
    /// Set from the session queue at run start; guarded because it is read on
    /// the tap's queue.
    var imageOrientation: CGImagePropertyOrientation {
        lock.withLock { storedOrientation }
    }
    private var storedOrientation: CGImagePropertyOrientation = .right
    private var storedQuadOrientation: QuadOrientation = .right
    private let lock = NSLock()

    /// The same pose as `imageOrientation`, in the Kit's vocabulary — what the
    /// overlay needs to restate a quad in the *preview's* orientation, which is
    /// not always this one (see `QuadOrientation`). Kept in step with
    /// `imageOrientation` by construction: both are set from one write.
    var quadOrientation: QuadOrientation {
        lock.withLock { storedQuadOrientation }
    }

    /// Set the pose the run is being detected at. One call rather than two
    /// settable properties, so the Vision orientation and the orientation the
    /// corners are *reported in* can never drift apart.
    func setCaptureOrientation(_ orientation: AVCaptureVideoOrientation) {
        lock.withLock {
            storedOrientation = CGImagePropertyOrientation(captureOrientation: orientation)
            storedQuadOrientation = QuadOrientation(captureOrientation: orientation)
        }
    }

    // Note for anyone reaching for `imageCropAndScaleOption` here: it does not
    // exist on this request. It is a `VNCoreMLRequest` property — the knob that
    // decides how an image is fitted to a *model's* input size — and the built-in
    // detectors read the whole frame. Their normalised coordinates are already
    // relative to the full oriented image, which the fixtures in
    // `NormalizedQuadOrientationTests` measure.
    private lazy var request: VNDetectRectanglesRequest = {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = Self.minimumAspectRatio
        request.maximumObservations = Self.maximumObservations
        request.minimumConfidence = Self.minimumConfidence
        request.quadratureTolerance = Self.quadratureTolerance
        return request
    }()

    /// Drops the remembered quad — a run starting, or a session reconfiguring.
    func reset() {
        latestQuad = nil
        latestAt = .distantPast
        lastDetectionAt = .distantPast
    }

    // MARK: - Detection

    /// Runs the request on one preview frame, synchronously on the caller's
    /// queue (the tap's own — see `ScannerMotionAnalyzer`). Synchronous on
    /// purpose: a `CVPixelBuffer` is only guaranteed for the life of the sample
    /// buffer that carried it, and the tap discards late frames anyway, so a
    /// detection that takes too long costs a frame rather than correctness.
    ///
    /// Throttled internally, so the caller can hand it every frame.
    func detect(in buffer: CVPixelBuffer, at time: Date) {
        guard time.timeIntervalSince(lastDetectionAt) >= Self.minimumDetectionInterval else { return }
        lastDetectionAt = time
        let handler = VNImageRequestHandler(
            cvPixelBuffer: buffer, orientation: imageOrientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // A failed request is not an event: the next frame is 100 ms away
            // and the previous quad ages out on its own.
            return
        }
        guard let observation = Self.select(from: request.results ?? []) else { return }
        latestQuad = Self.quad(from: observation)
        latestAt = time
    }

    /// The quad in force at `time`, or nil when the last detection is too old
    /// to still describe what the camera is looking at.
    func quad(at time: Date) -> NormalizedQuad? {
        guard let latestQuad, time.timeIntervalSince(latestAt) <= Self.staleAfter else { return nil }
        return latestQuad
    }

    // MARK: - Choosing between several

    /// Picks the quad the operator means from everything that qualified.
    ///
    /// **Outermost first, confidence second.** The obvious rule — take the
    /// highest confidence — is wrong for exactly the case this feature is for:
    /// a photograph, a framed print or a magazine page contains rectangles
    /// *inside* it (a picture within the picture, a boxed-out column), and an
    /// inner rectangle is often crisper and better lit than the object's own
    /// edge, so it wins on confidence and the shoot silently rectifies to the
    /// wrong thing. The outermost qualifying quad is the object; anything
    /// inside it is content. Confidence then breaks ties between candidates of
    /// the same size, where it is exactly the right question.
    static func select(from observations: [VNRectangleObservation]) -> VNRectangleObservation? {
        observations
            .filter { $0.confidence >= minimumConfidence }
            .max { lhs, rhs in
                let lhsArea = boundingArea(of: lhs)
                let rhsArea = boundingArea(of: rhs)
                // "Same size" has to have a width, or floating-point noise
                // decides which of two identical quads is outermost. 1% of the
                // frame's area is well below the difference between an object
                // and something printed on it.
                if abs(lhsArea - rhsArea) > 0.01 { return lhsArea < rhsArea }
                return lhs.confidence < rhs.confidence
            }
    }

    static func boundingArea(of observation: VNRectangleObservation) -> Double {
        Double(observation.boundingBox.width * observation.boundingBox.height)
    }

    /// Vision's corners, verbatim: normalised, bottom-left origin. Nothing is
    /// flipped here — see `NormalizedQuad` for why that convention is kept all
    /// the way to Core Image.
    static func quad(from observation: VNRectangleObservation) -> NormalizedQuad {
        NormalizedQuad(
            topLeft: .init(observation.topLeft),
            topRight: .init(observation.topRight),
            bottomLeft: .init(observation.bottomLeft),
            bottomRight: .init(observation.bottomRight),
            confidence: Double(observation.confidence))
    }
}

// MARK: - Orientation

extension CGImagePropertyOrientation {
    /// How a preview buffer has to be turned to be upright, given the pose a
    /// still captured right now would be tagged with.
    ///
    /// Back camera only, which is what a Scanner shoot is: the front camera's
    /// buffers are mirrored and would need the mirrored cases instead.
    init(captureOrientation: AVCaptureVideoOrientation) {
        switch captureOrientation {
        case .portrait: self = .right
        case .portraitUpsideDown: self = .left
        // "Home button on the right" is the way the sensor already reads out,
        // so this one is the identity.
        case .landscapeRight: self = .up
        case .landscapeLeft: self = .down
        @unknown default: self = .right
        }
    }
}

extension QuadOrientation {
    /// The Kit's name for the same quarter turn `CGImagePropertyOrientation`
    /// above describes — one table, stated twice, because the Kit cannot see
    /// AVFoundation and the overlay's rotation is pure geometry that wants
    /// testing without a camera.
    init(captureOrientation: AVCaptureVideoOrientation) {
        switch captureOrientation {
        case .portrait: self = .right
        case .portraitUpsideDown: self = .left
        case .landscapeRight: self = .up
        case .landscapeLeft: self = .down
        @unknown default: self = .right
        }
    }
}

#endif
