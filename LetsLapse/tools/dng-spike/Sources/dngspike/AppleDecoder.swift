import Accelerate
import CoreImage
import Foundation
import LetsLapseKit

/// Strategy A1: Apple's raw converter. Demosaiced, white-balanced,
/// camera-profiled linear pixels — rendered here into extended linear sRGB
/// so the output DNG can declare sRGB primaries honestly. `scaleFactor`
/// resamples inside the converter.
enum AppleDecoder {
    static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let context = CIContext(options: [
        .workingColorSpace: linearSRGB,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false,
    ])

    struct Result {
        let frame: RGBFrame
        let nativeSize: CGSize
        let neutralTemperatureK: Double
        let neutralTint: Double
        let renderMilliseconds: Double
        let setupMilliseconds: Double
        let scale: Float
    }

    /// `scale` 1 = native size. Output values: 1.0 = the converter's white,
    /// headroom above it preserved (EDR 2), so the frame reports two stops
    /// of headroom for the writer to fold into BaselineExposure.
    static func decode(url: URL, targetPixels: Int?, headroomStops: Int = 2) throws -> Result {
        let clock = ProcessInfo.processInfo.systemUptime
        guard let raw = LossyLinearDNG.rawFilter(for: url) else {
            throw SpikeError.decode("CIRAWFilter declined \(url.lastPathComponent)")
        }
        raw.boostAmount = 0
        raw.extendedDynamicRangeAmount = 2
        var scale: Float = 1
        let nativePixels = Double(raw.nativeSize.width * raw.nativeSize.height)
        if let targetPixels, Double(targetPixels) < nativePixels {
            scale = Float((Double(targetPixels) / nativePixels).squareRoot())
        }
        raw.scaleFactor = scale
        let neutralK = Double(raw.neutralTemperature)
        let tint = Double(raw.neutralTint)
        let nativeSize = raw.nativeSize
        guard let image = raw.outputImage else {
            throw SpikeError.decode("CIRAWFilter produced no image for \(url.lastPathComponent)")
        }
        let setup = (ProcessInfo.processInfo.systemUptime - clock) * 1000
        let renderStart = ProcessInfo.processInfo.systemUptime
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                           bounds: extent, format: .RGBAf, colorSpace: linearSRGB)
        }
        // Stored samples are scene/4: two stops of headroom for the converter's
        // above-white values (the app's own convention for authored DNGs).
        var rgb = [Float](repeating: 0, count: width * height * 3)
        rgba.withUnsafeMutableBufferPointer { source in
            rgb.withUnsafeMutableBufferPointer { destination in
                var src = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 16)
                var dst = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 12)
                vImageConvert_RGBAFFFFtoRGBFFF(&src, &dst, vImage_Flags(kvImageNoFlags))
                var divisor = Float(1 / pow(2, Double(headroomStops)))
                vDSP_vsmul(destination.baseAddress!, 1, &divisor, destination.baseAddress!, 1, vDSP_Length(width * height * 3))
            }
        }
        let render = (ProcessInfo.processInfo.systemUptime - renderStart) * 1000
        var metadata = FrameMetadata()
        metadata.colorTags = DNGArchive.sRGBColorTags()
        metadata.isCameraNative = false
        metadata.headroomStops = headroomStops
        metadata.decodePath = "apple-ciraw"
        metadata.originalFileName = url.lastPathComponent
        metadata.exif = InputMetadata.exifTags(for: url)
        metadata.cameraName = InputMetadata.cameraName(for: url)
        let frame = RGBFrame(width: width, height: height, samples: rgb, metadata: metadata)
        return Result(frame: frame, nativeSize: nativeSize, neutralTemperatureK: neutralK, neutralTint: tint,
                      renderMilliseconds: render, setupMilliseconds: setup, scale: scale)
    }
}
