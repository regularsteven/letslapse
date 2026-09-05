import Foundation

// The archive-conversion pipeline (docs/dng-archive-spike-brief.md and the
// report in docs/dng-archive-spike/): a raw frame in — the app's own Bayer
// DNG, a third-party camera raw, or anything Apple's converter opens — and a
// smaller DNG out, camera-native, lossy JPEG XL or lossless, at the source
// size or resampled. Every piece here is iOS-clean (Metal, MPS, vDSP, ImageIO,
// libjxl and LibRaw as static binary targets).

extension DNGArchive {

    /// Provenance and the tags a converted frame carries forward.
    public struct FrameMetadata: Sendable {
        /// IFD0 colour and identity tags (matrices, neutral, calibration,
        /// camera model, profile tables, baseline exposure) to carry verbatim.
        public var colorTags: [DNGTagValue] = []
        /// Raw-IFD tags to carry (NoiseProfile, quality hints).
        public var rawTags: [DNGTagValue] = []
        public var exif: [DNGTagValue] = []
        public var gps: [DNGTagValue] = []
        public var originalFileName: String?
        public var cameraName = "unknown"
        /// Whether `colorTags` describe the camera's own space (true) or a
        /// declared working space the samples were rendered into (false).
        public var isCameraNative = true
        /// Stops of highlight headroom the *stored* samples are pre-divided by;
        /// written as BaselineExposure so a reader pushes them back.
        public var headroomStops = 0
        /// What decoded the pixels — for the report.
        public var decodePath = ""
        public var notes: [String] = []

        public init() {}
    }

    /// A Bayer mosaic in the file's stored units, plus what is needed to
    /// linearise it.
    public final class MosaicFrame: @unchecked Sendable {
        public let width: Int
        public let height: Int
        public var samples: [UInt16]
        /// 2×2, row-major, DNG plane indices (0 = R, 1 = G, 2 = B).
        public let cfaPattern: [UInt8]
        public let black: Double
        public let white: Double
        public var metadata: FrameMetadata

        public init(width: Int, height: Int, samples: [UInt16], cfaPattern: [UInt8], black: Double, white: Double, metadata: FrameMetadata) {
            self.width = width
            self.height = height
            self.samples = samples
            self.cfaPattern = cfaPattern
            self.black = black
            self.white = white
            self.metadata = metadata
        }

        public var megapixels: Double { Double(width * height) / 1e6 }
    }

    /// Linear RGB, Float32 interleaved, 0 = black, 1 = white; values below
    /// zero (noise under black) and above one (headroom) are kept.
    public final class RGBFrame: @unchecked Sendable {
        public let width: Int
        public let height: Int
        public var samples: [Float]
        public var metadata: FrameMetadata

        public init(width: Int, height: Int, samples: [Float], metadata: FrameMetadata) {
            self.width = width
            self.height = height
            self.samples = samples
            self.metadata = metadata
        }

        public var megapixels: Double { Double(width * height) / 1e6 }
    }

    public enum DecodedFrame {
        case mosaic(MosaicFrame)
        case rgb(RGBFrame)

        public var metadata: FrameMetadata {
            switch self {
            case .mosaic(let frame): return frame.metadata
            case .rgb(let frame): return frame.metadata
            }
        }

        public var width: Int {
            switch self {
            case .mosaic(let frame): return frame.width
            case .rgb(let frame): return frame.width
            }
        }

        public var height: Int {
            switch self {
            case .mosaic(let frame): return frame.height
            case .rgb(let frame): return frame.height
            }
        }
    }

    public enum ConversionError: Error, CustomStringConvertible, LocalizedError {
        case usage(String)
        case unsupported(String)
        case decode(String)
        case encode(String)
        case io(String)

        public var description: String {
            switch self {
            case .usage(let why): return "usage: \(why)"
            case .unsupported(let why): return "unsupported: \(why)"
            case .decode(let why): return "decode: \(why)"
            case .encode(let why): return "encode: \(why)"
            case .io(let why): return "io: \(why)"
            }
        }

        public var errorDescription: String? { description }
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

    /// Named laps around the stages of one conversion, in milliseconds.
    public struct StageTimer {
        private var last = ProcessInfo.processInfo.systemUptime
        private let started = ProcessInfo.processInfo.systemUptime
        public private(set) var laps: [(name: String, milliseconds: Double)] = []

        public init() {}

        public mutating func lap(_ name: String) {
            let now = ProcessInfo.processInfo.systemUptime
            laps.append((name, (now - last) * 1000))
            last = now
        }

        /// Records a sub-stage measured elsewhere without moving the lap clock,
        /// so the enclosing `lap` still accounts for the whole wall time.
        public mutating func add(_ name: String, milliseconds: Double) {
            laps.append((name, milliseconds))
        }

        public var totalMilliseconds: Double { (ProcessInfo.processInfo.systemUptime - started) * 1000 }

        public func milliseconds(_ name: String) -> Double {
            laps.filter { $0.name == name }.reduce(0) { $0 + $1.milliseconds }
        }
    }

    public enum ProcessMemory {
        /// The process's physical footprint right now, in MB.
        public static func footprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return -1 }
            return Double(info.phys_footprint) / 1e6
        }
    }
}
