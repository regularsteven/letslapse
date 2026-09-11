import Foundation
import CoreGraphics

// MARK: - Inventory

enum AssetFamily: String, Codable { case still, interval }

enum RepresentativeSource: String, Codable {
    case blendImage      // rendered blend PNG/JPEG
    case blendVideo      // a mid frame pulled from a rendered blend clip
    case renderedFrame   // a rendered JPEG/HEIC source frame
    case rawDecode       // DNG/ARW decoded as a last resort (slow; logged)
}

struct Asset: Codable {
    let id: String                 // capture UUID, or folder name for an unlisted folder
    let family: AssetFamily
    let mode: String
    let name: String
    let projectDir: String
    let representativePath: String
    let representativeSource: RepresentativeSource
    let nativeWidth: Int
    let nativeHeight: Int
    let capturedAt: Date
    let listedInManifest: Bool
    let sourceFrameCount: Int
    /// Fraction of a blend clip's duration the representative frame was pulled from (blendVideo only).
    var frameFraction: Double?

    var shortID: String { String(id.prefix(8)) }
    var shorterEdge: Int { min(nativeWidth, nativeHeight) }
}

struct SkippedShoot: Codable {
    let id: String
    let reason: String
    let mode: String
}

struct Inventory: Codable {
    let catalogue: String
    let scannedAt: Date
    var assets: [Asset]
    var skipped: [SkippedShoot]
}

// MARK: - Anchors (the spike's own cache; never written into project data)

enum AnchorSource: String, Codable { case detected }

struct ShapeAnchor: Codable {
    enum Kind: String, Codable { case ellipse, quad }

    let assetID: String
    let kind: Kind
    let centre: CGPoint          // normalised, origin top-left
    let majorAxis: CGFloat       // normalised to source width (full axis, not semi)
    let minorAxis: CGFloat       // normalised to source width
    let rotation: CGFloat        // radians, major axis from horizontal (image y-down)
    let corners: [CGPoint]?      // quads only, clockwise from top-left, normalised
    let confidence: Float
    let nativeDiameterPx: CGFloat
    let source: AnchorSource

    /// minor/major — 1.0 is head-on, 0.25 is the acceptance floor.
    var obliquity: CGFloat { majorAxis > 0 ? minorAxis / majorAxis : 0 }
}

/// Every candidate the detector considered, accepted or not.
struct DetectionRecord: Codable {
    let anchor: ShapeAnchor
    let accepted: Bool
    let rejection: String?
    // Diagnostics
    let fitResidual: Double?     // mean |ρ−1| in the ellipse's unit frame (fraction of axis)
    let coverage: Double?        // fraction of 10° angular bins with contour support
    let pass: String?            // which contour pass found it
    let pointCount: Int?
}

struct DetectionFile: Codable {
    var settings: DetectionSettings
    var records: [DetectionRecord]
    var perAsset: [AssetDetectionSummary]
}

struct AssetDetectionSummary: Codable {
    let assetID: String
    let detected: Bool           // detector ran to completion
    let error: String?
    let elapsedMs: Int
    let acceptedEllipses: Int
    let acceptedQuads: Int
    let candidates: Int
}

struct DetectionSettings: Codable {
    var detectionLongEdge: Int = 1024
    /// Vision contour tracer resolution (its own knob; the default 512 is what Apple ships).
    var contourImageDimension: Int = 512
    var minNativeDiameterPx: Double = 400
    var minDiameterFractionOfShortEdge: Double = 1.0 / 6.0
    var maxFitResidual: Double = 0.03
    var minCoverage: Double = 0.70
    var minObliquity: Double = 0.25
    var contrastAdjustments: [Float] = [1.0, 2.0, 3.0]
    /// CIEdges thresholds for the edge-map contour passes (empty = region contours only).
    var edgeThresholds: [Float] = [0.06, 0.15]
    var rectMinimumAspectRatio: Float = 0.3
    var rectMaximumObservations: Int = 12
    var rectMinimumConfidence: Float = 0.6
    var rectQuadratureTolerance: Float = 30

    init() {}

    /// Lenient: settings files from earlier tool versions decode with defaults for new keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        detectionLongEdge = try c.decodeIfPresent(Int.self, forKey: .detectionLongEdge) ?? detectionLongEdge
        contourImageDimension = try c.decodeIfPresent(Int.self, forKey: .contourImageDimension) ?? contourImageDimension
        minNativeDiameterPx = try c.decodeIfPresent(Double.self, forKey: .minNativeDiameterPx) ?? minNativeDiameterPx
        minDiameterFractionOfShortEdge = try c.decodeIfPresent(Double.self, forKey: .minDiameterFractionOfShortEdge) ?? minDiameterFractionOfShortEdge
        maxFitResidual = try c.decodeIfPresent(Double.self, forKey: .maxFitResidual) ?? maxFitResidual
        minCoverage = try c.decodeIfPresent(Double.self, forKey: .minCoverage) ?? minCoverage
        minObliquity = try c.decodeIfPresent(Double.self, forKey: .minObliquity) ?? minObliquity
        contrastAdjustments = try c.decodeIfPresent([Float].self, forKey: .contrastAdjustments) ?? contrastAdjustments
        edgeThresholds = try c.decodeIfPresent([Float].self, forKey: .edgeThresholds) ?? []
        rectMinimumAspectRatio = try c.decodeIfPresent(Float.self, forKey: .rectMinimumAspectRatio) ?? rectMinimumAspectRatio
        rectMaximumObservations = try c.decodeIfPresent(Int.self, forKey: .rectMaximumObservations) ?? rectMaximumObservations
        rectMinimumConfidence = try c.decodeIfPresent(Float.self, forKey: .rectMinimumConfidence) ?? rectMinimumConfidence
        rectQuadratureTolerance = try c.decodeIfPresent(Float.self, forKey: .rectQuadratureTolerance) ?? rectQuadratureTolerance
    }
}

// MARK: - Groups

struct GroupMember: Codable {
    let assetID: String
    let anchor: ShapeAnchor
    let capturedAt: Date
    let scaleFactor: Double          // native px → output px multiplier to hit the target size
    let requiredUpscale: Double      // max(1, scaleFactor)
    let coverageCentred: Double      // fraction of the output frame covered by source pixels
    let coverageAligned: Double
}

struct ShapeGroup: Codable {
    let index: Int
    let kind: ShapeAnchor.Kind
    let label: String                // e.g. "ellipse · all", "ellipse · head-on", "quad · landscape · moderate"
    let bucket: String?
    let members: [GroupMember]       // chronological
    let sizeOrdered: [String]        // asset IDs by ascending scale factor
    let truncatedFrom: Int?          // original count if capped
    let medianAspect: Double?        // quads: median rectified aspect (minor/major)
    let nearMiss: Bool               // size 3
}

struct GroupsFile: Codable {
    var settings: GroupSettings
    var groups: [ShapeGroup]
}

struct GroupSettings: Codable {
    var minGroupSize: Int = 4
    var maxGroupSize: Int = 30
    var outputWidth: Int = 1920
    var outputHeight: Int = 1080
    var targetFractionOfHeight: Double = 0.4
    var upscaleFlag: Double = 2.0
}

// MARK: - Render results

struct RenderedItem: Codable {
    let assetID: String
    let included: Bool
    let shortfall: Double            // 1 − coverage, fraction of the output frame left black
    let scaleFactor: Double
    let error: String?
}

struct RenderedClip: Codable {
    let groupIndex: Int
    let variant: String              // "centred" | "aligned"
    let ordering: String             // "chrono" | "size"
    let path: String
    let items: [RenderedItem]
    let seconds: Double
}

struct RenderFile: Codable {
    var edgePolicy: String
    var clips: [RenderedClip]
    var tag: String = ""
    var rotation: String = "major"
}

// MARK: - JSON helpers

enum JSONIO {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(value).write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(type, from: Data(contentsOf: url))
    }
}
