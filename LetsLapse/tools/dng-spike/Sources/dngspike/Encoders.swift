import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import LetsLapseKit
import VideoToolbox

/// Which codec fills the tiles.
enum TileCodec: Equatable {
    case none
    case lj92
    case jxl(distance: Float, effort: Int, decodeSpeed: Int, xyb: Bool)
    case jpeg8(quality: Double)
    /// VideoToolbox's hardware JPEG, whole frame as one tile.
    case hwjpeg(quality: Double)

    var label: String {
        switch self {
        case .none: return "raw"
        case .lj92: return "lj92"
        case .jxl(let d, let e, _, let xyb): return d == 0 ? "jxl-lossless-e\(e)" : "jxl-d\(String(format: "%.1f", d))-e\(e)\(xyb ? "-xyb" : "-rgb")"
        case .jpeg8(let q): return "jpeg8-q\(String(format: "%.2f", q))"
        case .hwjpeg(let q): return "hwjpeg-q\(String(format: "%.2f", q))"
        }
    }

    var compression: DNGArchive.Compression {
        switch self {
        case .none: return .none
        case .lj92: return .losslessJPEG
        case .jxl(let d, let e, let s, _): return .jpegXL(distance: d, effort: e, decodeSpeed: s)
        case .jpeg8, .hwjpeg: return .lossyJPEG
        }
    }

    var isLossless: Bool {
        switch self {
        case .none, .lj92: return true
        case .jxl(let d, _, _, _): return d == 0
        case .jpeg8, .hwjpeg: return false
        }
    }

    var bitsPerSample: Int {
        switch self {
        case .jpeg8, .hwjpeg: return 8
        default: return 16
        }
    }
}

struct EncodedTiles {
    let tiles: [Data]
    let tileWidth: Int
    let tileHeight: Int
    let bytes: Int
    let milliseconds: Double
    let notes: [String]
}

/// Cuts the stored-value plane into edge-padded tiles and runs the codec
/// over them in parallel.
enum TileEncoder {

    /// 16-bit stored samples (interleaved `spp`), width × height.
    static func encode16(_ stored: [UInt16], width: Int, height: Int, samplesPerPixel spp: Int,
                         tile: Int, codec: TileCodec) throws -> EncodedTiles {
        let started = ProcessInfo.processInfo.systemUptime
        let tileWidth = tile == 0 ? width : tile, tileHeight = tile == 0 ? height : tile
        let across = (width + tileWidth - 1) / tileWidth, down = (height + tileHeight - 1) / tileHeight
        var results = [Data?](repeating: nil, count: across * down)
        var failures = [String?](repeating: nil, count: across * down)
        // One codestream per tile; big tiles get the codec's own threads.
        let perTileThreads = across * down == 1 ? ProcessInfo.processInfo.activeProcessorCount : 1
        stored.withUnsafeBufferPointer { source in
            results.withUnsafeMutableBufferPointer { output in
                failures.withUnsafeMutableBufferPointer { errors in
                    DispatchQueue.concurrentPerform(iterations: across * down) { index in
                        let tx = index % across, ty = index / across
                        let block = cut16(source.baseAddress!, width: width, height: height, spp: spp,
                                          x0: tx * tileWidth, y0: ty * tileHeight, tileWidth: tileWidth, tileHeight: tileHeight)
                        do {
                            switch codec {
                            case .none:
                                output[index] = block.withUnsafeBufferPointer { Data(buffer: $0) }
                            case .lj92:
                                output[index] = try LosslessJPEG.encode(interleaved: block, width: tileWidth, height: tileHeight, components: spp)
                            case .jxl(let distance, let effort, let decodeSpeed, let xyb):
                                output[index] = try JXLEncoder.encode(
                                    samples16: block, width: tileWidth, height: tileHeight, channels: spp,
                                    distance: distance, effort: effort, decodeSpeed: decodeSpeed, xyb: xyb, threads: perTileThreads)
                            case .jpeg8, .hwjpeg:
                                throw SpikeError.encode("8-bit codecs take 8-bit tiles")
                            }
                        } catch {
                            errors[index] = "tile \(index): \(error)"
                        }
                    }
                }
            }
        }
        if let failure = failures.compactMap({ $0 }).first { throw SpikeError.encode(failure) }
        let tiles = results.map { $0 ?? Data() }
        return EncodedTiles(tiles: tiles, tileWidth: tileWidth, tileHeight: tileHeight,
                            bytes: tiles.reduce(0) { $0 + $1.count },
                            milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000, notes: [])
    }

    /// 8-bit stored samples, three interleaved, JPEG tiles through ImageIO
    /// or the whole frame through VideoToolbox's hardware JPEG.
    static func encode8(_ stored: [UInt8], width: Int, height: Int, tile: Int, codec: TileCodec) throws -> EncodedTiles {
        let started = ProcessInfo.processInfo.systemUptime
        switch codec {
        case .hwjpeg(let quality):
            let (data, note) = try HardwareJPEG.encode(rgb8: stored, width: width, height: height, quality: quality)
            return EncodedTiles(tiles: [data], tileWidth: width, tileHeight: height, bytes: data.count,
                                milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000, notes: [note])
        case .jpeg8(let quality):
            let tileWidth = tile == 0 ? width : tile, tileHeight = tile == 0 ? height : tile
            let across = (width + tileWidth - 1) / tileWidth, down = (height + tileHeight - 1) / tileHeight
            var results = [Data?](repeating: nil, count: across * down)
            var failures = [String?](repeating: nil, count: across * down)
            stored.withUnsafeBufferPointer { source in
                results.withUnsafeMutableBufferPointer { output in
                    failures.withUnsafeMutableBufferPointer { errors in
                        DispatchQueue.concurrentPerform(iterations: across * down) { index in
                            let tx = index % across, ty = index / across
                            var block = [UInt8](repeating: 0, count: tileWidth * tileHeight * 3)
                            for y in 0..<tileHeight {
                                let sy = min(ty * tileHeight + y, height - 1)
                                for x in 0..<tileWidth {
                                    let sx = min(tx * tileWidth + x, width - 1)
                                    let s = (sy * width + sx) * 3, d = (y * tileWidth + x) * 3
                                    block[d] = source[s]; block[d + 1] = source[s + 1]; block[d + 2] = source[s + 2]
                                }
                            }
                            do {
                                output[index] = try ImageIOJPEG.encode(rgb8: block, width: tileWidth, height: tileHeight, quality: quality)
                            } catch {
                                errors[index] = "tile \(index): \(error)"
                            }
                        }
                    }
                }
            }
            if let failure = failures.compactMap({ $0 }).first { throw SpikeError.encode(failure) }
            let tiles = results.map { $0 ?? Data() }
            let sampling = tiles.first.map(ImageIOJPEG.samplingFactors) ?? "?"
            return EncodedTiles(tiles: tiles, tileWidth: tileWidth, tileHeight: tileHeight,
                                bytes: tiles.reduce(0) { $0 + $1.count },
                                milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
                                notes: ["ImageIO JPEG sampling \(sampling)"])
        default:
            throw SpikeError.encode("\(codec.label) takes 16-bit tiles")
        }
    }

    private static func cut16(_ source: UnsafePointer<UInt16>, width: Int, height: Int, spp: Int,
                              x0: Int, y0: Int, tileWidth: Int, tileHeight: Int) -> [UInt16] {
        var block = [UInt16](repeating: 0, count: tileWidth * tileHeight * spp)
        block.withUnsafeMutableBufferPointer { destination in
            for y in 0..<tileHeight {
                let sy = min(y0 + y, height - 1)
                let inside = max(0, min(tileWidth, width - x0))
                let sourceRow = source + (sy * width + x0) * spp
                let destinationRow = destination.baseAddress! + y * tileWidth * spp
                if inside > 0 { destinationRow.update(from: sourceRow, count: inside * spp) }
                if inside < tileWidth {
                    // Replicate the last column across the padding.
                    let last = source + (sy * width + width - 1) * spp
                    for x in inside..<tileWidth {
                        (destinationRow + x * spp).update(from: last, count: spp)
                    }
                }
            }
        }
        return block
    }
}

enum ImageIOJPEG {
    static func encode(rgb8: [UInt8], width: Int, height: Int, quality: Double) throws -> Data {
        let data = Data(rgb8)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw SpikeError.encode("CGImage for JPEG tile")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw SpikeError.encode("CGImageDestination JPEG")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SpikeError.encode("JPEG finalize") }
        return output as Data
    }

    /// The SOF0 sampling factors of a baseline JPEG ("1x1,1x1,1x1" = 4:4:4).
    static func samplingFactors(_ jpeg: Data) -> String {
        var i = jpeg.startIndex + 2
        while i + 4 <= jpeg.endIndex {
            guard jpeg[i] == 0xFF else { return "?" }
            let marker = jpeg[i + 1]
            let length = Int(jpeg[i + 2]) << 8 | Int(jpeg[i + 3])
            if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                let count = Int(jpeg[i + 9])
                var factors: [String] = []
                for c in 0..<count {
                    let hv = jpeg[i + 11 + c * 3]
                    factors.append("\(hv >> 4)x\(hv & 0x0F)")
                }
                return factors.joined(separator: ",")
            }
            i += 2 + length
        }
        return "?"
    }
}

/// VideoToolbox's `JPEG (HW)` encoder, one frame in, one JFIF stream out.
enum HardwareJPEG {
    static func encode(rgb8: [UInt8], width: Int, height: Int, quality: Double) throws -> (Data, String) {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { throw SpikeError.encode("pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        rgb8.withUnsafeBufferPointer { source in
            for y in 0..<height {
                let row = base + y * rowBytes
                let src = source.baseAddress! + y * width * 3
                var x = 0
                while x < width {
                    row[x * 4] = src[x * 3 + 2]
                    row[x * 4 + 1] = src[x * 3 + 1]
                    row[x * 4 + 2] = src[x * 3]
                    row[x * 4 + 3] = 255
                    x += 1
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var session: VTCompressionSession?
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_JPEG,
            encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw SpikeError.encode("VTCompressionSession(jpeg, hardware) → \(status)") }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: NSNumber(value: quality))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        var encoderID: CFTypeRef?
        VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_EncoderID, allocator: nil, valueOut: &encoderID)

        var output = Data()
        var encodeStatus: OSStatus = noErr
        let semaphore = DispatchSemaphore(value: 0)
        let encode = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: 0, timescale: 30),
            duration: .invalid, frameProperties: nil, infoFlagsOut: nil
        ) { callbackStatus, _, sampleBuffer in
            encodeStatus = callbackStatus
            if let sampleBuffer, let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let length = CMBlockBufferGetDataLength(block)
                var bytes = [UInt8](repeating: 0, count: length)
                if CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr {
                    output = Data(bytes)
                }
            }
            semaphore.signal()
        }
        guard encode == noErr else { throw SpikeError.encode("EncodeFrame → \(encode)") }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard semaphore.wait(timeout: .now() + 10) == .success else { throw SpikeError.encode("hardware JPEG timed out") }
        guard encodeStatus == noErr, !output.isEmpty else { throw SpikeError.encode("hardware JPEG status \(encodeStatus), \(output.count) bytes") }
        let note = "VideoToolbox \(encoderID as? String ?? "?") sampling \(ImageIOJPEG.samplingFactors(output))"
        return (output, note)
    }
}
