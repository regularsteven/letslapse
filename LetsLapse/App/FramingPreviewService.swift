#if os(iOS)
import AVFoundation
import CoreImage
import CoreMotion
import Foundation
import UIKit

/// Serves the Watch a look through the lens, and how level the phone is.
///
/// **Pull, not push.** The remote asks for a frame when its framing screen is
/// open and never otherwise, so an unopened screen costs nothing, there is no
/// queue of stale frames to drain, and the age readout on the wrist is simply
/// the time since the last answer arrived. A push design would have to invent
/// all three.
///
/// **Idle only.** The tap is an extra `AVCaptureVideoDataOutput`, and adding
/// one reconfigures the session — under a live movie writer that kills the
/// recording outright (-11805 / -11818; see `CameraController`'s test-card
/// tap, which learned this the hard way). Framing is something you do before
/// you press record, so the restriction costs nothing and the guards enforce
/// it rather than trusting the caller.
@MainActor
final class FramingPreviewService {
    static let shared = FramingPreviewService()

    /// How long after the last request the tap stays attached. Comfortably
    /// longer than the remote's 1 Hz poll, so a couple of dropped messages
    /// don't cause the camera to re-plumb itself mid-look.
    private let idleTimeout: TimeInterval = 4

    private weak var camera: CameraController?
    private let tap = FramingFrameTap()
    private var lastRequestAt = Date.distantPast
    private var isAttached = false
    private var reaper: Task<Void, Never>?
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    private init() {}

    func attach(camera: CameraController?) {
        self.camera = camera
        if camera == nil { detach() }
    }

    /// One frame, encoded and measured, or nil if the camera has not produced
    /// one yet. Also (re)arms the tap — asking IS the subscription.
    func requestFrame() -> FramingFrame? {
        guard let camera else { return nil }
        lastRequestAt = Date()
        if !isAttached {
            camera.startFramingTap(tap)
            isAttached = true
            scheduleReaper()
        }
        guard let buffer = tap.latestBuffer else { return nil }
        return encode(buffer)
    }

    /// Stops the tap and forgets the last frame. Called when the capture
    /// screen goes away, so the session is left exactly as it would be if this
    /// feature did not exist.
    func detach() {
        reaper?.cancel()
        reaper = nil
        guard isAttached else { return }
        isAttached = false
        tap.latestBuffer = nil
        camera?.stopFramingTap()
    }

    private func scheduleReaper() {
        reaper?.cancel()
        reaper = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isAttached else { return }
                if Date().timeIntervalSince(self.lastRequestAt) > self.idleTimeout {
                    self.detach()
                    return
                }
            }
        }
    }

    // MARK: - Encoding

    /// The size budget is set by the link, not by taste. `sendMessage` caps a
    /// WatchConnectivity payload at 65,536 bytes, and every reply also carries
    /// a full state snapshot — so the image gets ~40 KB of base64, which is
    /// ~30 KB of JPEG. Quality steps down until it fits rather than failing:
    /// a soft frame still tells you where the horizon is, and no frame tells
    /// you nothing.
    private static let base64Budget = 40_000
    private static let qualitySteps: [CGFloat] = [0.5, 0.38, 0.28, 0.2, 0.12]
    /// Long edge in pixels. A 46 mm watch is 416×496 device pixels, so this is
    /// already generous for the screen it lands on.
    private static let longEdge: CGFloat = 420

    private func encode(_ buffer: CVPixelBuffer) -> FramingFrame? {
        guard CVPixelBufferGetWidth(buffer) > 0, CVPixelBufferGetHeight(buffer) > 0 else { return nil }

        // Rotate to the pose the phone is actually being held in. A preview
        // buffer always arrives in the sensor's landscape, so without this a
        // portrait shoot reached the wrist lying on its side — and the aspect
        // lenses letterboxed a 16:9 frame that should have been 9:16.
        let oriented = CIImage(cvPixelBuffer: buffer)
            .oriented(Self.imageOrientation(for: camera?.currentCaptureOrientation ?? .landscapeRight))
        let width = Int(oriented.extent.width)
        let height = Int(oriented.extent.height)
        guard width > 0, height > 0 else { return nil }

        let scale = min(1, Self.longEdge / CGFloat(max(width, height)))
        let image = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        for quality in Self.qualitySteps {
            guard let data = context.jpegRepresentation(
                of: image,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
            ) else { continue }
            let encoded = data.base64EncodedString()
            if encoded.count <= Self.base64Budget || quality == Self.qualitySteps.last {
                return FramingFrame(
                    base64JPEG: encoded,
                    pixelWidth: Int((CGFloat(width) * scale).rounded()),
                    pixelHeight: Int((CGFloat(height) * scale).rounded()),
                    rollDegrees: LevelSensor.shared.rollDegrees
                )
            }
        }
        return nil
    }

    /// The back camera's buffer arrives with the scene upright for
    /// `.landscapeRight`; every other pose is a quarter turn from it.
    private static func imageOrientation(
        for orientation: AVCaptureVideoOrientation
    ) -> CGImagePropertyOrientation {
        switch orientation {
        case .landscapeRight: return .up
        case .portrait: return .right
        case .landscapeLeft: return .down
        case .portraitUpsideDown: return .left
        @unknown default: return .up
        }
    }
}

/// One look through the lens, ready for the wire.
struct FramingFrame {
    /// Base64 rather than raw `Data` on purpose. The LAN transport JSON-encodes
    /// its bodies (`CaptureRemoteCoder`), and `JSONSerialization` rejects
    /// `Data` outright — so a `Data` payload would work over WatchConnectivity
    /// and silently fail for the Mac and iPad remotes. Base64 is legal on both,
    /// at the cost of a third more bytes.
    let base64JPEG: String
    let pixelWidth: Int
    let pixelHeight: Int
    /// Signed degrees off level, or nil if motion data isn't available.
    let rollDegrees: Double?
}

/// Keeps the most recent preview buffer and nothing else.
///
/// Deliberately not a ring buffer or a queue: the remote wants *now*, and a
/// frame it didn't ask for is a frame it will never show.
final class FramingFrameTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "letslapse.framing.tap")
    /// Written on `queue`, read on the main actor. A pixel buffer reference is
    /// a single pointer-sized store, and a torn read here would at worst show
    /// one frame late — which the age readout already accounts for.
    var latestBuffer: CVPixelBuffer?

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        latestBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    }
}

/// How far off level the phone is, from the phone.
///
/// The angle has to come from here rather than the wrist: the watch's own
/// attitude describes an arm, and an arm's tilt has nothing to do with the
/// horizon in the frame. This reads device motion only while someone is
/// actually looking at a framing preview, so it costs nothing the rest of the
/// time.
@MainActor
final class LevelSensor {
    static let shared = LevelSensor()

    private let motion = CMMotionManager()
    private var startedAt: Date?
    /// Stops after this long without a read, so a remote that walks away
    /// doesn't leave the accelerometer running.
    private let idleTimeout: TimeInterval = 6

    private init() {}

    /// Signed degrees of camera roll: negative when the phone is tilted
    /// anticlockwise. Starts the sensor on first ask and returns nil until it
    /// has a reading — an invented zero would read as "perfectly level", which
    /// is the one wrong answer that looks right.
    ///
    /// **Measured against the nearest square hold, not against portrait.** A
    /// phone shooting 16:9 is lying on its side, which is 90° of raw roll; the
    /// first version folded that into ±90 and reported exactly 90, so the
    /// horizon bar on the wrist drew itself vertical. What anyone framing a
    /// shot means by "level" is *how far off the nearest quarter turn*, which
    /// is right for portrait, either landscape, and upside-down alike.
    var rollDegrees: Double? {
        start()
        guard let gravity = motion.deviceMotion?.gravity else { return nil }
        // `atan2` over the two axes in the screen plane stays correct through
        // the full ±180°, where `asin` would fold at the extremes.
        let raw = atan2(gravity.x, -gravity.y) * 180 / .pi
        let square = (raw / 90).rounded() * 90
        return raw - square
    }

    private func start() {
        startedAt = Date()
        guard !motion.isDeviceMotionActive, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 10
        motion.startDeviceMotionUpdates()
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, let startedAt = self.startedAt else { return }
                if Date().timeIntervalSince(startedAt) > self.idleTimeout {
                    self.motion.stopDeviceMotionUpdates()
                    self.startedAt = nil
                    return
                }
            }
        }
    }
}
#endif
