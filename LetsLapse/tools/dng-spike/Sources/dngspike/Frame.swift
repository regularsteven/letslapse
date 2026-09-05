import Foundation
import LetsLapseKit

/// Provenance and the tags a converted frame carries forward.
struct FrameMetadata {
    /// IFD0 colour and identity tags (matrices, neutral, calibration,
    /// camera model, profile tables, baseline exposure) to carry verbatim.
    var colorTags: [DNGTagValue] = []
    /// Raw-IFD tags to carry (NoiseProfile, quality hints).
    var rawTags: [DNGTagValue] = []
    var exif: [DNGTagValue] = []
    var gps: [DNGTagValue] = []
    var originalFileName: String?
    var cameraName = "unknown"
    /// Whether `colorTags` describe the camera's own space (true) or a
    /// declared working space the samples were rendered into (false).
    var isCameraNative = true
    /// Stops of highlight headroom the *stored* samples are pre-divided by;
    /// written as BaselineExposure so a reader pushes them back.
    var headroomStops = 0
    /// What decoded the pixels — for the report.
    var decodePath = ""
    var notes: [String] = []
}

/// A Bayer mosaic in the file's stored units, plus what is needed to
/// linearise it.
final class MosaicFrame {
    let width: Int
    let height: Int
    var samples: [UInt16]
    /// 2×2, row-major, DNG plane indices (0 = R, 1 = G, 2 = B).
    let cfaPattern: [UInt8]
    let black: Double
    let white: Double
    var metadata: FrameMetadata

    init(width: Int, height: Int, samples: [UInt16], cfaPattern: [UInt8], black: Double, white: Double, metadata: FrameMetadata) {
        self.width = width
        self.height = height
        self.samples = samples
        self.cfaPattern = cfaPattern
        self.black = black
        self.white = white
        self.metadata = metadata
    }

    var megapixels: Double { Double(width * height) / 1e6 }
}

/// Linear RGB, Float32 interleaved, 0 = black, 1 = white; values below zero
/// (noise under black) and above one (headroom) are kept.
final class RGBFrame {
    let width: Int
    let height: Int
    var samples: [Float]
    var metadata: FrameMetadata

    init(width: Int, height: Int, samples: [Float], metadata: FrameMetadata) {
        self.width = width
        self.height = height
        self.samples = samples
        self.metadata = metadata
    }

    var megapixels: Double { Double(width * height) / 1e6 }
}

enum DecodedFrame {
    case mosaic(MosaicFrame)
    case rgb(RGBFrame)

    var metadata: FrameMetadata {
        switch self {
        case .mosaic(let frame): return frame.metadata
        case .rgb(let frame): return frame.metadata
        }
    }

    var width: Int {
        switch self {
        case .mosaic(let frame): return frame.width
        case .rgb(let frame): return frame.width
        }
    }

    var height: Int {
        switch self {
        case .mosaic(let frame): return frame.height
        case .rgb(let frame): return frame.height
        }
    }
}

enum SpikeError: Error, CustomStringConvertible {
    case usage(String)
    case unsupported(String)
    case decode(String)
    case encode(String)
    case io(String)

    var description: String {
        switch self {
        case .usage(let why): return "usage: \(why)"
        case .unsupported(let why): return "unsupported: \(why)"
        case .decode(let why): return "decode: \(why)"
        case .encode(let why): return "encode: \(why)"
        case .io(let why): return "io: \(why)"
        }
    }
}

/// Exposure and capture-time EXIF for any input, through ImageIO (the way
/// the app's importer reads it), so an ARW's sub-second stamp survives.
enum InputMetadata {
    static func exifTags(for url: URL) -> [DNGTagValue] {
        let frame = ImportedStills.frame(at: url)
        var exposure = frame.exposure
        exposure.capturedAt = frame.capturedAt
        if exposure.isEmpty { return [] }
        return DNGAuthor.exifTags(exposure)
    }

    static func cameraName(for url: URL) -> String {
        let frame = ImportedStills.frame(at: url)
        return [frame.cameraMake, frame.cameraModel].compactMap { $0 }.joined(separator: " ")
    }
}
