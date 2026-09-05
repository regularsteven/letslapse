import Foundation
#if JXL
import CJXL
#endif

/// Strategy C2: libjxl. One bare codestream per call, 16-bit samples, one
/// or three channels. Two colour declarations are measured:
///
/// - `xyb: true` — Adobe's shape. `uses_original_profile = false`, colour
///   encoding RGB / D65 / Rec. 2100 primaries / sRGB transfer, so the encoder
///   works in XYB and expects gamma-shaped samples (the `gammaLUT` or
///   `cubic` carrier).
/// - `xyb: false` — `uses_original_profile = true` with a linear transfer:
///   the codec quantises the stored values as they are.
///
/// Distance 0 is lossless (modular, original profile). Built only with the
/// `JXL` trait.
enum JXLEncoder {
    static var isAvailable: Bool {
        #if JXL
        return true
        #else
        return false
        #endif
    }

    static var version: String {
        #if JXL
        let v = JxlEncoderVersion()
        return "libjxl \(v / 1_000_000).\(v / 1000 % 1000).\(v % 1000)"
        #else
        return "not built (swift build --traits JXL)"
        #endif
    }

    #if JXL
    static func encode(samples16: [UInt16], width: Int, height: Int, channels: Int,
                       distance: Float, effort: Int, decodeSpeed: Int, xyb: Bool, threads: Int) throws -> Data {
        guard let encoder = JxlEncoderCreate(nil) else { throw SpikeError.encode("JxlEncoderCreate") }
        defer { JxlEncoderDestroy(encoder) }
        var runner: UnsafeMutableRawPointer?
        if threads > 1 {
            runner = JxlThreadParallelRunnerCreate(nil, threads)
            guard JxlEncoderSetParallelRunner(encoder, JxlThreadParallelRunner, runner) == JXL_ENC_SUCCESS else {
                throw SpikeError.encode("JxlEncoderSetParallelRunner")
            }
        }
        defer { if let runner { JxlThreadParallelRunnerDestroy(runner) } }

        JxlEncoderUseContainer(encoder, JXL_FALSE)
        var info = JxlBasicInfo()
        JxlEncoderInitBasicInfo(&info)
        info.xsize = UInt32(width)
        info.ysize = UInt32(height)
        info.bits_per_sample = 16
        info.exponent_bits_per_sample = 0
        info.num_color_channels = UInt32(channels)
        info.num_extra_channels = 0
        info.alpha_bits = 0
        let lossless = distance == 0
        info.uses_original_profile = (lossless || !xyb) ? JXL_TRUE : JXL_FALSE
        guard JxlEncoderSetBasicInfo(encoder, &info) == JXL_ENC_SUCCESS else { throw SpikeError.encode("JxlEncoderSetBasicInfo") }

        var color = JxlColorEncoding()
        if xyb && !lossless {
            color.color_space = channels == 1 ? JXL_COLOR_SPACE_GRAY : JXL_COLOR_SPACE_RGB
            color.white_point = JXL_WHITE_POINT_D65
            color.primaries = JXL_PRIMARIES_2100
            color.transfer_function = JXL_TRANSFER_FUNCTION_SRGB
            color.rendering_intent = JXL_RENDERING_INTENT_PERCEPTUAL
        } else {
            JxlColorEncodingSetToLinearSRGB(&color, channels == 1 ? JXL_TRUE : JXL_FALSE)
        }
        guard JxlEncoderSetColorEncoding(encoder, &color) == JXL_ENC_SUCCESS else { throw SpikeError.encode("JxlEncoderSetColorEncoding") }
        // A level-10 codestream is wrapped in the container; a DNG tile wants
        // the bare codestream, so ask for the level the image actually needs.
        let required = JxlEncoderGetRequiredCodestreamLevel(encoder)
        if required == 5 || required == 10 { _ = JxlEncoderSetCodestreamLevel(encoder, required) }

        guard let settings = JxlEncoderFrameSettingsCreate(encoder, nil) else { throw SpikeError.encode("JxlEncoderFrameSettingsCreate") }
        JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, Int64(effort))
        JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_DECODING_SPEED, Int64(decodeSpeed))
        if lossless {
            JxlEncoderSetFrameLossless(settings, JXL_TRUE)
        } else {
            JxlEncoderSetFrameDistance(settings, distance)
        }
        var format = JxlPixelFormat(num_channels: UInt32(channels), data_type: JXL_TYPE_UINT16, endianness: JXL_LITTLE_ENDIAN, align: 0)
        let added = samples16.withUnsafeBytes { bytes in
            JxlEncoderAddImageFrame(settings, &format, bytes.baseAddress, bytes.count)
        }
        guard added == JXL_ENC_SUCCESS else { throw SpikeError.encode("JxlEncoderAddImageFrame → \(added.rawValue) (\(JxlEncoderGetError(encoder).rawValue))") }
        JxlEncoderCloseInput(encoder)

        var output = [UInt8](repeating: 0, count: max(65536, width * height * channels / 2))
        var produced = 0
        while true {
            var available = output.count - produced
            var status: JxlEncoderStatus = JXL_ENC_SUCCESS
            output.withUnsafeMutableBufferPointer { buffer in
                var next: UnsafeMutablePointer<UInt8>? = buffer.baseAddress! + produced
                status = JxlEncoderProcessOutput(encoder, &next, &available)
                produced = buffer.count - available
            }
            if status == JXL_ENC_NEED_MORE_OUTPUT {
                output.append(contentsOf: [UInt8](repeating: 0, count: output.count))
                continue
            }
            guard status == JXL_ENC_SUCCESS else { throw SpikeError.encode("JxlEncoderProcessOutput → \(status.rawValue) (\(JxlEncoderGetError(encoder).rawValue))") }
            break
        }
        return Data(output[0..<produced])
    }
    #else
    static func encode(samples16: [UInt16], width: Int, height: Int, channels: Int,
                       distance: Float, effort: Int, decodeSpeed: Int, xyb: Bool, threads: Int) throws -> Data {
        throw SpikeError.unsupported("JPEG XL is not built in — swift build --traits JXL")
    }
    #endif
}
