import AVFoundation
import CoreVideo
import simd
import VideoToolbox

/// The one encode configuration every video writer shares.
///
/// Before this existed the app had four writers with four unrelated policies —
/// the blend writer set nothing at all (VideoToolbox default bitrate, and no
/// colour tags, so players guessed the YCbCr matrix and shadows drifted green),
/// the Mac runner hardcoded 12 Mbps, the synthesizer 8 Mbps, and only the
/// clip-transcode utility carried a resolution-aware bitrate. This struct is
/// that utility's formula promoted to policy, plus the tagging the others
/// never did.
public struct VideoEncodePolicy: Sendable {
    public enum Profile: String, Sendable, CaseIterable {
        /// H.264 High profile, 8-bit — the widely compatible distribution
        /// default.
        case h264High8Bit
        /// HEVC Main10, 10-bit — the quality option; what graded blends of
        /// 16-bit sources deserve.
        case hevcMain10
    }

    /// Which primaries the pixels carry, and therefore which tags the stream
    /// gets. The distribution H.264 path converts to BT.709; the 10-bit HEVC
    /// path keeps the sources' Display P3.
    public enum Primaries: String, Sendable {
        case rec709
        case displayP3
    }

    public var profile: Profile
    public var width: Int
    public var height: Int
    public var fps: Double
    public var primaries: Primaries

    public init(profile: Profile, width: Int, height: Int, fps: Double, primaries: Primaries? = nil) {
        self.profile = profile
        self.width = width
        self.height = height
        self.fps = fps
        self.primaries = primaries ?? (profile == .hevcMain10 ? .displayP3 : .rec709)
    }

    /// Both profiles write MP4 — HEVC-in-MP4 plays everywhere Apple and keeps
    /// the `blends/<uuid>.mp4` naming unchanged.
    public var fileType: AVFileType { .mp4 }

    public var codecType: AVVideoCodecType {
        profile == .h264High8Bit ? .h264 : .hevc
    }

    /// Resolution- and rate-aware target bitrate: a fixed budget of bits per
    /// pixel per FRAME (0.24 for H.264 High, 0.18 for HEVC Main10 — the
    /// clip-transcode utility's coefficients, chosen so a re-encode doesn't
    /// band) times the pixels the writer actually emits per second.
    ///
    /// The frame rate is NOT capped. An earlier `min(fps, 30)` in the rate
    /// term meant to keep a 50 fps timelapse from costing more than a 30 fps
    /// one, but the writer still emits every frame, so it halved what each
    /// frame got: 4032×3024 @ 60 measured 0.12 / 0.09 bits per pixel, and an
    /// encoder-only test on a clean reference kept only 36 % (H.264) / 21 %
    /// (HEVC 10-bit) of the finest-band detail against 100 % for ProRes.
    /// The ceilings sit under the H.264 High Level 6.0 bound (300 Mbps) and
    /// the HEVC Level 6.1 High-tier bound (480 Mbps), and bind only above
    /// 12 MP @ 68 fps.
    public var averageBitRate: Int {
        let pixelsPerSecond = Double(width * height) * max(fps, 1)
        switch profile {
        case .h264High8Bit:
            return Int(min(max(pixelsPerSecond * 0.24, 8_000_000), 200_000_000))
        case .hevcMain10:
            return Int(min(max(pixelsPerSecond * 0.18, 6_000_000), 160_000_000))
        }
    }

    /// BT.709 stream tags. The pipeline's pixels are sRGB-encoded with
    /// sRGB/709 primaries; declaring the 709 triple is the standard SDR
    /// practice (the transfer curves differ only in the dark toe) and — the
    /// part that actually bit us — the explicit YCbCr matrix stops players
    /// guessing BT.601 and tinting the shadows green.
    public static var colorProperties: [String: Any] {
        [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
    }

    /// This policy's stream tags: 709 transfer and matrix always, primaries
    /// per `primaries`.
    public var streamColorProperties: [String: Any] {
        [
            AVVideoColorPrimariesKey: primaries == .displayP3
                ? AVVideoColorPrimaries_P3_D65 : AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
    }

    public var videoSettings: [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: averageBitRate,
            AVVideoMaxKeyFrameIntervalKey: max(1, Int(fps.rounded())),
            AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
        ]
        switch profile {
        case .h264High8Bit:
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevcMain10:
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }
        return [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: streamColorProperties,
        ]
    }

    /// Adaptor pool attributes matching `videoSettings`: 8-bit BGRA for the
    /// H.264 path, half-float RGBA for Main10 so the encoder receives the full
    /// precision and quantizes to 10-bit itself.
    public var pixelBufferAttributes: [String: Any] {
        let format = profile == .hevcMain10
            ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA
        return [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }

    /// The linear-domain conversion from the pipeline's Display P3 working
    /// primaries into this policy's output primaries — identity when the
    /// output keeps P3. Applied inside `encodeGamma`, before the transfer.
    public var gamutMatrixFromDisplayP3: simd_float3x3 {
        switch primaries {
        case .displayP3:
            return matrix_identity_float3x3
        case .rec709:
            // XYZ→sRGB · P3→XYZ, both D65 — the standard constant.
            return simd_float3x3(rows: [
                SIMD3<Float>(1.2249401, -0.2249404, 0.0000000),
                SIMD3<Float>(-0.0420570, 1.0420571, 0.0000000),
                SIMD3<Float>(-0.0196376, -0.0786361, 1.0982735),
            ])
        }
    }

    /// Stamps the buffer-level twins of the stream tags. Attachments that
    /// match the stream tags mean VideoToolbox performs no transfer
    /// re-quantization, only the RGB→YCbCr matrix.
    public func tagColor(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey,
            primaries == .displayP3
                ? kCVImageBufferColorPrimaries_P3_D65 : kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    /// The static 709 tagger for the writers whose pixels come from the sRGB
    /// 8-bit legacy path (they carry sRGB/709 primaries by construction).
    public static func tagColor(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    /// The compatibility floor, for the writer-startup fallback ladder: every
    /// supported device can encode this.
    public func fallbackToH264() -> VideoEncodePolicy {
        var policy = self
        policy.profile = .h264High8Bit
        return policy
    }
}
