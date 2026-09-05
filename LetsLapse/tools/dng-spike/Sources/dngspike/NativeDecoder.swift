import Foundation
import LetsLapseKit

/// Strategy A3: the Kit's own parse of a Bayer DNG plus the lossless-JPEG
/// decoder — no colour work, the mosaic is camera-native already.
enum NativeDecoder {
    struct Result {
        let frame: MosaicFrame
        let parseMilliseconds: Double
        let tileMilliseconds: Double
        let tileCount: Int
    }

    static func canDecode(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "dng",
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let directories = try? DNGDocument.parseDirectories(data) else { return false }
        let candidates = [directories.ifd0] + directories.subIFDs
        guard let raw = candidates.first(where: { $0.int(262) == 32803 }) else { return false }
        return raw.int(259) == 7 && raw.int(258) == 16 && raw.tag(322) != nil
    }

    static func decode(url: URL) throws -> Result {
        let clock = ProcessInfo.processInfo.systemUptime
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let directories = try DNGDocument.parseDirectories(data)
        let candidates = [directories.ifd0] + directories.subIFDs
        guard let raw = candidates.first(where: { $0.int(262) == 32803 }) else {
            throw SpikeError.decode("\(url.lastPathComponent) has no CFA image directory")
        }
        guard raw.int(259) == 7 else { throw SpikeError.unsupported("compression \(raw.int(259) ?? -1); the native path reads lossless JPEG (7) only") }
        guard raw.int(258) == 16 else { throw SpikeError.unsupported("\(raw.int(258) ?? 0)-bit CFA") }
        guard let width = raw.int(256), let height = raw.int(257),
              let tileWidth = raw.int(322), let tileHeight = raw.int(323) else {
            throw SpikeError.unsupported("strips; the native path reads tiled DNGs")
        }
        let offsets = raw.tag(324)?.ints ?? [], counts = raw.tag(325)?.ints ?? []
        let across = (width + tileWidth - 1) / tileWidth, down = (height + tileHeight - 1) / tileHeight
        guard offsets.count == across * down, counts.count == offsets.count else {
            throw SpikeError.decode("tile table has \(offsets.count) entries for \(across)×\(down)")
        }
        let dims = raw.tag(33421)?.ints ?? [2, 2]
        let pattern = raw.tag(33422)?.ints.map(UInt8.init) ?? []
        guard dims == [2, 2], pattern.count == 4 else { throw SpikeError.unsupported("CFA pattern \(pattern) with dims \(dims)") }
        let blacks = raw.doubles(50714)
        let black = blacks.first ?? 0
        guard blacks.allSatisfy({ $0 == black }) else { throw SpikeError.unsupported("per-channel black levels \(blacks)") }
        guard (raw.tag(50713)?.ints ?? [1, 1]) == [1, 1] else { throw SpikeError.unsupported("BlackLevelRepeatDim \(raw.tag(50713)!.ints)") }
        guard raw.tag(50712) == nil else { throw SpikeError.unsupported("LinearizationTable on the input") }
        let white = raw.doubles(50717).first ?? 65535
        let parse = (ProcessInfo.processInfo.systemUptime - clock) * 1000

        let tileStart = ProcessInfo.processInfo.systemUptime
        var samples = [UInt16](repeating: 0, count: width * height)
        var failures = [String?](repeating: nil, count: offsets.count)
        samples.withUnsafeMutableBufferPointer { output in
            failures.withUnsafeMutableBufferPointer { errors in
                DispatchQueue.concurrentPerform(iterations: offsets.count) { index in
                    let range = offsets[index]..<(offsets[index] + counts[index])
                    guard range.upperBound <= data.count else { errors[index] = "tile \(index) past end"; return }
                    do {
                        let tile = try LosslessJPEGDecoder.decode(data.subdata(in: range))
                        guard tile.components == 1 else { errors[index] = "tile \(index) has \(tile.components) components"; return }
                        let x0 = (index % across) * tileWidth, y0 = (index / across) * tileHeight
                        let columns = min(tile.width, width - x0), rows = min(tile.height, height - y0)
                        tile.samples.withUnsafeBufferPointer { source in
                            for y in 0..<rows {
                                let sourceRow = source.baseAddress! + y * tile.width
                                let destinationRow = output.baseAddress! + (y0 + y) * width + x0
                                destinationRow.update(from: sourceRow, count: columns)
                            }
                        }
                    } catch {
                        errors[index] = "tile \(index): \(error)"
                    }
                }
            }
        }
        if let failure = failures.compactMap({ $0 }).first { throw SpikeError.decode(failure) }
        let tiles = (ProcessInfo.processInfo.systemUptime - tileStart) * 1000

        var metadata = FrameMetadata()
        metadata.colorTags = DNGArchive.carriedIFD0Tags(from: directories.ifd0)
        metadata.rawTags = DNGArchive.carriedRawTags(from: raw)
        metadata.exif = directories.exif.isEmpty ? InputMetadata.exifTags(for: url) : directories.exif
        metadata.gps = directories.gps
        metadata.isCameraNative = true
        metadata.headroomStops = 0
        metadata.decodePath = "native-lj92"
        metadata.originalFileName = url.lastPathComponent
        metadata.cameraName = directories.ifd0.tag(50708)?.text ?? InputMetadata.cameraName(for: url)
        let frame = MosaicFrame(width: width, height: height, samples: samples, cfaPattern: pattern,
                                black: black, white: white, metadata: metadata)
        return Result(frame: frame, parseMilliseconds: parse, tileMilliseconds: tiles, tileCount: offsets.count)
    }
}
