import AVFoundation
import VideoToolbox
import XCTest
@testable import LetsLapseKit

/// The one encode configuration every writer shares. Pure arithmetic — no
/// GPU, no writer — pinning the property that went missing once: the bit
/// budget is per pixel per FRAME, so a 60 fps clip gets twice the bitrate of
/// a 30 fps one at the same size instead of the same bitrate spread thinner.
final class VideoEncodePolicyTests: XCTestCase {
    private func policy(_ profile: VideoEncodePolicy.Profile, _ width: Int, _ height: Int, fps: Double) -> VideoEncodePolicy {
        VideoEncodePolicy(profile: profile, width: width, height: height, fps: fps)
    }

    func testBitsPerFrameAreInvariantAcrossFrameRates() {
        for profile in VideoEncodePolicy.Profile.allCases {
            for (width, height) in [(4032, 3024), (3840, 2160), (1920, 1080)] {
                for (slow, fast) in [(30.0, 60.0), (25.0, 50.0), (24.0, 48.0)] {
                    let a = policy(profile, width, height, fps: slow).averageBitRate
                    let b = policy(profile, width, height, fps: fast).averageBitRate
                    XCTAssertEqual(
                        b, 2 * a, accuracy: 2,
                        "\(profile) \(width)x\(height): \(fast) fps must budget twice \(slow) fps")
                }
            }
        }
    }

    func testTwelveMegapixelSixtyIsNotClamped() {
        // 4032 × 3024 × 60 × 0.24 and × 0.18, truncated.
        XCTAssertEqual(policy(.h264High8Bit, 4032, 3024, fps: 60).averageBitRate, 175_575_859)
        XCTAssertEqual(policy(.hevcMain10, 4032, 3024, fps: 60).averageBitRate, 131_681_894)
        XCTAssertLessThan(policy(.h264High8Bit, 4032, 3024, fps: 60).averageBitRate, 200_000_000)
        XCTAssertLessThan(policy(.hevcMain10, 4032, 3024, fps: 60).averageBitRate, 160_000_000)
    }

    func testThirtyFrameBudgetIsUnchanged() {
        // The historical 30 fps numbers (what every ≥ 30 fps clip used to get).
        XCTAssertEqual(policy(.h264High8Bit, 4032, 3024, fps: 30).averageBitRate, 87_787_929)
        XCTAssertEqual(policy(.hevcMain10, 4032, 3024, fps: 30).averageBitRate, 65_840_947)
    }

    func testFloorsAndCeilings() {
        XCTAssertEqual(policy(.h264High8Bit, 320, 240, fps: 30).averageBitRate, 8_000_000)
        XCTAssertEqual(policy(.hevcMain10, 320, 240, fps: 30).averageBitRate, 6_000_000)
        XCTAssertEqual(policy(.h264High8Bit, 8064, 6048, fps: 60).averageBitRate, 200_000_000)
        XCTAssertEqual(policy(.hevcMain10, 8064, 6048, fps: 60).averageBitRate, 160_000_000)
        // A nonsense rate still budgets at least one frame per second.
        XCTAssertEqual(
            policy(.h264High8Bit, 4032, 3024, fps: 0).averageBitRate,
            policy(.h264High8Bit, 4032, 3024, fps: 1).averageBitRate)
    }

    func testVideoSettingsCarryProfileLevelAndRateKeys() throws {
        let h264 = policy(.h264High8Bit, 4032, 3024, fps: 60)
        let hevc = policy(.hevcMain10, 4032, 3024, fps: 50)
        for (p, codec, level) in [
            (h264, AVVideoCodecType.h264, AVVideoProfileLevelH264HighAutoLevel),
            (hevc, AVVideoCodecType.hevc, kVTProfileLevel_HEVC_Main10_AutoLevel as String),
        ] {
            let settings = p.videoSettings
            XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, codec)
            XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 4032)
            XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 3024)
            let compression = try XCTUnwrap(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
            XCTAssertEqual(compression[AVVideoAverageBitRateKey] as? Int, p.averageBitRate)
            XCTAssertEqual(compression[AVVideoProfileLevelKey] as? String, level)
            XCTAssertEqual(compression[AVVideoMaxKeyFrameIntervalKey] as? Int, Int(p.fps.rounded()))
            XCTAssertEqual(compression[AVVideoExpectedSourceFrameRateKey] as? Int, Int(p.fps.rounded()))
            let colour = try XCTUnwrap(settings[AVVideoColorPropertiesKey] as? [String: Any])
            XCTAssertEqual(colour[AVVideoTransferFunctionKey] as? String, AVVideoTransferFunction_ITU_R_709_2)
            XCTAssertEqual(colour[AVVideoYCbCrMatrixKey] as? String, AVVideoYCbCrMatrix_ITU_R_709_2)
        }
        XCTAssertEqual(
            (h264.videoSettings[AVVideoColorPropertiesKey] as? [String: Any])?[AVVideoColorPrimariesKey] as? String,
            AVVideoColorPrimaries_ITU_R_709_2)
        XCTAssertEqual(
            (hevc.videoSettings[AVVideoColorPropertiesKey] as? [String: Any])?[AVVideoColorPrimariesKey] as? String,
            AVVideoColorPrimaries_P3_D65)
    }

    func testPixelBufferFormatAndPrimariesFollowTheProfile() {
        let h264 = policy(.h264High8Bit, 1920, 1080, fps: 30)
        let hevc = policy(.hevcMain10, 1920, 1080, fps: 30)
        XCTAssertEqual(h264.primaries, .rec709)
        XCTAssertEqual(hevc.primaries, .displayP3)
        XCTAssertEqual(
            h264.pixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
            kCVPixelFormatType_32BGRA)
        XCTAssertEqual(
            hevc.pixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
            kCVPixelFormatType_64RGBAHalf)
        XCTAssertEqual(h264.fileType, .mp4)
        XCTAssertEqual(hevc.fileType, .mp4)
    }

    func testFallbackToH264KeepsGeometryAndRate() {
        let hevc = policy(.hevcMain10, 4032, 3024, fps: 60)
        let fallback = hevc.fallbackToH264()
        XCTAssertEqual(fallback.profile, .h264High8Bit)
        XCTAssertEqual(fallback.width, 4032)
        XCTAssertEqual(fallback.height, 3024)
        XCTAssertEqual(fallback.fps, 60)
        XCTAssertEqual(fallback.averageBitRate, policy(.h264High8Bit, 4032, 3024, fps: 60).averageBitRate)
    }

    /// Grey stays grey through the P3→709 gamut matrix — the assumption the
    /// display-referred blend round-trip test leans on.
    func testGamutMatrixMapsWhiteToWhite() {
        let white = policy(.h264High8Bit, 64, 64, fps: 30).gamutMatrixFromDisplayP3 * SIMD3<Float>(repeating: 1)
        XCTAssertEqual(white.x, 1, accuracy: 1e-5)
        XCTAssertEqual(white.y, 1, accuracy: 1e-5)
        XCTAssertEqual(white.z, 1, accuracy: 1e-5)
        let identity = policy(.hevcMain10, 64, 64, fps: 30).gamutMatrixFromDisplayP3 * SIMD3<Float>(0.2, 0.5, 0.9)
        XCTAssertEqual(identity, SIMD3<Float>(0.2, 0.5, 0.9))
    }
}
