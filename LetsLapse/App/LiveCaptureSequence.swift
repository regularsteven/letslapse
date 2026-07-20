import Foundation

struct LiveCaptureSequence: Codable, Equatable {
    enum Mode: String, Codable, Equatable, Identifiable, CaseIterable {
        case ramp
        case marker

        var id: String { rawValue }

        var label: String {
            switch self {
            case .ramp: return "Ramp"
            case .marker: return "Marker"
            }
        }
    }

    struct Resolution: Codable, Equatable {
        var width: Int32
        var height: Int32
    }

    struct Segment: Codable, Equatable {
        var index: Int
        var fileName: String
        var frameRate: Int
        var relativeStart: TimeInterval
        var relativeEnd: TimeInterval
    }

    struct Marker: Codable, Equatable {
        var index: Int
        var relativeTime: TimeInterval
    }

    struct RampInterval: Codable, Equatable {
        var index: Int
        var relativeStart: TimeInterval
        var relativeEnd: TimeInterval?
    }

    var mode: Mode
    var createdAt: Date
    var lockedResolution: Resolution
    var baseFrameRate: Int
    var rampFrameRate: Int?
    var segments: [Segment]
    var markers: [Marker]
    var rampIntervals: [RampInterval]

    enum CodingKeys: String, CodingKey {
        case mode
        case createdAt
        case lockedResolution
        case baseFrameRate
        case rampFrameRate
        case segments
        case markers
        case rampIntervals
    }

    init(
        mode: Mode,
        createdAt: Date,
        lockedResolution: Resolution,
        baseFrameRate: Int,
        rampFrameRate: Int?,
        segments: [Segment],
        markers: [Marker],
        rampIntervals: [RampInterval]
    ) {
        self.mode = mode
        self.createdAt = createdAt
        self.lockedResolution = lockedResolution
        self.baseFrameRate = baseFrameRate
        self.rampFrameRate = rampFrameRate
        self.segments = segments
        self.markers = markers
        self.rampIntervals = rampIntervals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lockedResolution = try container.decode(Resolution.self, forKey: .lockedResolution)
        baseFrameRate = try container.decode(Int.self, forKey: .baseFrameRate)
        rampFrameRate = try container.decodeIfPresent(Int.self, forKey: .rampFrameRate)
        segments = try container.decode([Segment].self, forKey: .segments)
        markers = try container.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        rampIntervals = try container.decodeIfPresent([RampInterval].self, forKey: .rampIntervals) ?? []
    }

    var summary: String {
        switch mode {
        case .ramp:
            let highRate = rampFrameRate.map { " -> \($0) fps" } ?? ""
            return "Ramp capture · \(rampIntervals.count) ramp intervals · \(segments.count) segments · \(baseFrameRate) fps\(highRate)"
        case .marker:
            return "Marker capture · \(rampIntervals.count) ramp intervals · \(baseFrameRate) fps"
        }
    }
}

struct LiveCaptureResult {
    var sequence: LiveCaptureSequence
    var segmentURLs: [URL]
    var metadataURL: URL

    var primaryVideoURL: URL? {
        segmentURLs.first
    }
}
