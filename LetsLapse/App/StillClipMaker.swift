import AVFoundation
import CoreImage
import CryptoKit
import ImageIO

// MARK: - A still as a clip, for a collection (D4, 2026-09-25)
//
// Collections are cut from movies — trims, crops, Ken Burns ramps, fades, all
// in one AVFoundation composition. A still member (a long-exposure still, a
// Photo capture's picture, a photo's still blend) joins that pipeline as a
// short silent movie of its picture: one frame held for the member's length,
// at a size with room for a 4K canvas and a Ken Burns zoom. The move itself
// is the composition's, exactly as for a clip. Made on demand, kept in the
// caches directory by picture, length and frame rate.

enum StillClipMaker {

    /// The longest edge a still's movie is written at — a 3840-wide canvas
    /// with headroom for a gentle zoom.
    static let maxLongEdge = 5120

    enum Failure: LocalizedError {
        case unreadable
        case writer(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The still couldn't be read."
            case .writer(let why): return "The still couldn't be turned into a clip: \(why)"
            }
        }
    }

    /// The movie of `image` lasting `seconds` at `fps` — made once, then
    /// taken from the cache.
    static func movie(for image: URL, seconds: Double, fps: Int) async throws -> URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StillClips", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let modified = (try? image.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(image.path)|\(modified)|\(String(format: "%.3f", seconds))|\(fps)|\(maxLongEdge)"
        let name = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let url = folder.appendingPathComponent("\(name).mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try await Task.detached(priority: .userInitiated) {
            try write(image: image, seconds: seconds, fps: fps, to: url)
        }.value
        return url
    }

    /// One frame at the start, the same frame at the last tick, the session
    /// ended at `seconds`: a track whose frame lasts the whole length.
    private static func write(image: URL, seconds: Double, fps: Int, to url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil) else { throw Failure.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable
        }
        // H.264 wants even dimensions.
        let width = picture.width / 2 * 2
        let height = picture.height / 2 * 2
        guard width > 0, height > 0 else { throw Failure.unreadable }

        let partial = url.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw Failure.writer("no video input") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else { throw Failure.writer("no buffer pool") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw Failure.writer("no buffer") }
        let space = picture.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        CIContext().render(
            CIImage(cgImage: picture), to: buffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: space)

        let scale = CMTimeScale(max(1, fps) * 100)
        let last = CMTime(value: CMTimeValue(max(0, seconds - 1 / Double(max(1, fps))) * Double(scale)), timescale: scale)
        for time in (last > .zero ? [CMTime.zero, last] : [CMTime.zero]) {
            while !input.isReadyForMoreMediaData { usleep(1_000) }
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw Failure.writer(writer.error?.localizedDescription ?? "append")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: scale))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw Failure.writer(writer.error?.localizedDescription ?? "finish")
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
    }
}
