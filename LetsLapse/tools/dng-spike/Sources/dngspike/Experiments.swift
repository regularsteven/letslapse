import Accelerate
import Foundation
import LetsLapseKit

/// One-off experiments that separate a container question from a pixel
/// question.
enum Experiments {
    /// Native decode → Metal demosaic → the Kit's `writeLinearDNG` with the
    /// source's camera colour tags, no pedestal, no compression.
    static func kitLinear(input: URL, output: URL) throws {
        let mosaic = try NativeDecoder.decode(url: input).frame
        let rgb = try MetalDemosaic().run(mosaic, method: .mhc, targetPixels: nil).frame
        let count = rgb.width * rgb.height * 3
        var stored = [UInt16](repeating: 0, count: count)
        rgb.samples.withUnsafeBufferPointer { source in
            stored.withUnsafeMutableBufferPointer { destination in
                var scratch = [Float](repeating: 0, count: count)
                var scale: Float = 65535, offset: Float = 0, low: Float = 0, high: Float = 65535
                vDSP_vsmsa(source.baseAddress!, 1, &scale, &offset, &scratch, 1, vDSP_Length(count))
                vDSP_vclip(scratch, 1, &low, &high, &scratch, 1, vDSP_Length(count))
                vDSP_vfixru16(scratch, 1, destination.baseAddress!, 1, vDSP_Length(count))
            }
        }
        let data = stored.withUnsafeBufferPointer { Data(buffer: $0) }
        try DNGAuthor.writeLinearDNG(rgb16: data, width: rgb.width, height: rgb.height, headroomStops: 0, compress: false,
                                     cameraColor: mosaic.metadata.colorTags, gps: nil, exif: nil, preview: nil, to: output)
        print("wrote \(output.path) via DNGAuthor.writeLinearDNG with \(mosaic.metadata.colorTags.count) carried tags")
    }
}
