import Foundation

// What the person shooting is looking for — the three dials beside BLEND
// when auto shape mode is on — and what each setting asks of the detector.
// Field-test dials (2026-09-11): the mappings below are the levers, and the
// numbers are starting values to be moved from the field.

public struct ShapeSearch: Equatable, Sendable, Codable {
    /// Which kinds to look for. `circular` skips the rectangle request and
    /// its edge-support map; `rectangular` skips every contour pass — the
    /// expensive half of the machine.
    public enum Family: String, CaseIterable, Sendable, Codable {
        case all, circular, rectangular

        public var title: String {
            switch self {
            case .all: return "All"
            case .circular: return "Circular"
            case .rectangular: return "Rectangular"
            }
        }
    }

    /// How hard to look: how many contrast passes the tracer runs and how
    /// strict the fit and support gates are. `low` is one pass of the
    /// un-amplified picture with tight gates — only strong outlines; `high`
    /// three passes with loosened gates — faint outlines too, at the cost of
    /// more false shapes and ~1.5× the time.
    public enum Sensitivity: String, CaseIterable, Sendable, Codable {
        case high, medium, low

        public var title: String {
            switch self {
            case .high: return "High"
            case .medium: return "Medium"
            case .low: return "Low"
            }
        }
    }

    /// How big a shape must be, as a share of the frame's short edge — and,
    /// on the viewfinder, at what resolution to look. A large shape survives
    /// a 256 px picture (the tracer is superlinear in resolution, so that is
    /// the fastest setting); a small one needs 512. `all` is the normal floor
    /// — a sixth of the short edge, the Shape-mation renderer's own minimum
    /// (nothing upscales) — so `small` looks below it, not inside it.
    public enum Size: String, CaseIterable, Sendable, Codable {
        case all, large, mid, small

        public var title: String {
            switch self {
            case .all: return "All"
            case .large: return "Large"
            case .mid: return "Mid"
            case .small: return "Small"
            }
        }

        /// Diameter as a fraction of the short edge: floor and ceiling.
        public var range: ClosedRange<Double> {
            switch self {
            case .all: return (1.0 / 6.0)...1.0
            case .large: return 0.35...1.0
            case .mid: return (1.0 / 6.0)...0.35
            case .small: return (1.0 / 12.0)...(1.0 / 6.0)
            }
        }

        /// The file pass's floor. All reaches down to 0.10 of the short edge
        /// there: against 68 hand-labelled shapes the 1/6 floor cost nine of
        /// them for no precision (docs/shape-benchmark/report.md, 2026-09-12).
        /// The viewfinder keeps 1/6 — at 384 px a 0.10 shape is 38 px, too
        /// small to trace live.
        public var fileFloor: Double {
            switch self {
            case .all: return 0.10
            default: return range.lowerBound
            }
        }

        /// The viewfinder's detection resolution (long edge).
        public var liveLongEdge: Int {
            switch self {
            case .all, .mid: return 384
            case .large: return 256
            case .small: return 512
            }
        }
    }

    public var family = Family.all
    public var sensitivity = Sensitivity.medium
    public var size = Size.all

    public init(family: Family = .all, sensitivity: Sensitivity = .medium, size: Size = .all) {
        self.family = family; self.sensitivity = sensitivity; self.size = size
    }

    public var isDefault: Bool { self == ShapeSearch() }

    /// One line for the log: `circular/medium/all`.
    public var token: String { "\(family.rawValue)/\(sensitivity.rawValue)/\(size.rawValue)" }

    /// The viewfinder pass under this search. Everything at the size's
    /// resolution, no edge-map passes (a CI render plus a tracer pass each —
    /// the file pass's luxury), the residual gate looser than the file
    /// pass's because a 64 px circle traced at 384 px is jagged by
    /// quantisation alone and the file pass re-fits every kept shape.
    public func liveSettings() -> ShapeDetector.Settings {
        var s = ShapeDetector.Settings()
        s.detectionLongEdge = size.liveLongEdge
        s.contourImageDimension = size.liveLongEdge
        s.minNativeDiameterPx = 0
        s.edgeThresholds = []
        s.rectMaximumObservations = 12
        s.regionProposals = false
        apply(to: &s, live: true)
        return s
    }

    /// The file pass under this search: its own resolution and edge maps,
    /// its own residual gate, the search's family and size. Sensitivity
    /// moves the contrast sweep and the support gate here too, so what the
    /// file adds behaves like what the viewfinder showed.
    public func fileSettings() -> ShapeDetector.Settings {
        var s = ShapeDetector.Settings()
        apply(to: &s, live: false)
        return s
    }

    private func apply(to s: inout ShapeDetector.Settings, live: Bool) {
        s.detectQuads = family != .circular
        s.detectEllipses = family != .rectangular
        s.minDiameterFractionOfShortEdge = live ? size.range.lowerBound : size.fileFloor
        if !live { s.minNativeDiameterPx = 0 }   // the fraction is the floor; 400 px would override 0.10 on a 12 MP frame
        s.maxDiameterFractionOfShortEdge = size.range.upperBound
        switch sensitivity {
        case .high:
            s.contrastAdjustments = [1.0, 2.0, 3.0]
            s.maxFitResidual = live ? 0.08 : 0.06
            s.minCoverage = 0.6
            s.rectMinimumConfidence = 0.5
            s.quadEdgeSupport = 0.35
            s.edgeCircleMinSupport = 0.3
            s.edgeCircleMinCoverage = 0.45
            s.edgeCircleMaxGapBins = 8
            s.edgeCircleMaxWideHoles = 3
        case .medium:
            // 1.0 as well as 2.0: a matte disc on a pale table survives at
            // 1.0 and merges with its own shadow at 2.0 (2026-09-11 coasters).
            s.contrastAdjustments = live ? [1.0, 2.0] : [1.0, 2.0, 3.0]
            s.maxFitResidual = live ? 0.06 : 0.04
            s.minCoverage = 0.7
            s.rectMinimumConfidence = 0.6
            s.quadEdgeSupport = 0.45
            s.edgeCircleMinSupport = 0.35
            s.edgeCircleMinCoverage = 0.55
            s.edgeCircleMaxGapBins = 6
            s.edgeCircleMaxWideHoles = 2
        case .low:
            s.contrastAdjustments = [1.0]
            s.maxFitResidual = 0.04
            s.minCoverage = 0.8
            s.rectMinimumConfidence = 0.75
            s.quadEdgeSupport = 0.6
            s.edgeCircleMinSupport = 0.45
            s.edgeCircleMinCoverage = 0.65
            s.edgeCircleMaxGapBins = 5
            s.edgeCircleMaxWideHoles = 1
        }
    }
}

// MARK: - Detection modes

/// A named configuration of the still-photo pass, for the Find shapes sheet
/// and the Masks tab's one-off search (2026-09-12): which engine looks, and
/// the dials it looks with. The Kit engines are `ShapeDetector` settings. The
/// Python engines are the benchmark rig's own detectors, which the Mac app
/// runs through `tools/shapebench` (`ExternalShapeDetector`) — a way to look
/// at what a candidate method finds in the app before it is ported, never a
/// path that ships on a phone.
public struct ShapeDetectionMode: Equatable, Sendable, Codable {
    public enum Engine: String, CaseIterable, Sendable, Codable, Identifiable {
        /// Every engine below in turn on the same picture; a shape found by
        /// more than one is listed once, with who found it — the test bench's
        /// own mode, and what the detector score sheet is built from.
        case all
        /// The file pass as it ships: Vision quads, traced ellipses, Hough
        /// rims, region proposals at 1024 + 2048.
        case standard
        /// The Vision passes and the rims alone — the pass before the port.
        case visionOnly
        /// Region proposals at 1024 only: the cheaper half of the region pass.
        case regions1024
        /// Standard plus the edge-chain pass (`EdgeDrawing`).
        case edgeChains
        /// Vision passes and edge chains, no region pass.
        case edgeChainsOnly
        /// The rig's `opencv-reference` detector (Mac, Python).
        case pythonReference
        /// The rig's `edge-drawing` detector (Mac, Python, needs opencv-contrib).
        case pythonEdgeDrawing

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .all: return "Use all"
            case .standard: return "Standard"
            case .visionOnly: return "Vision only"
            case .regions1024: return "Regions at 1024"
            case .edgeChains: return "Standard + edge chains"
            case .edgeChainsOnly: return "Edge chains, no regions"
            case .pythonReference: return "Python reference"
            case .pythonEdgeDrawing: return "Python edge drawing"
            }
        }

        /// One line under the picker: what the engine is, and the benchmark
        /// number it carries (hits / false positives of 153 labels, 2026-09-12).
        /// A few characters for a chip in a list of who found a shape.
        public var shortTitle: String {
            switch self {
            case .all: return "All"
            case .standard: return "Std"
            case .visionOnly: return "Vision"
            case .regions1024: return "Reg1024"
            case .edgeChains: return "Std+chains"
            case .edgeChainsOnly: return "Chains"
            case .pythonReference: return "PyRef"
            case .pythonEdgeDrawing: return "PyED"
            }
        }

        public var detail: String {
            switch self {
            case .all: return "Every detector in turn; a shape found by more than one is listed once with who found it, and every Add or dismissal scores each detector"
            case .standard: return "Vision passes, Hough rims, region proposals at 1024 + 2048 · 74 / 69"
            case .visionOnly: return "Vision quads, traced ellipses and rims, no region pass · 38 / 23"
            case .regions1024: return "Region proposals at 1024 only · 67 / 47, about a second faster"
            case .edgeChains: return "Standard plus one-pixel edge chains fitted like regions · measured in the Kit next"
            case .edgeChainsOnly: return "Vision passes and edge chains, no region pass"
            case .pythonReference: return "The benchmark's OpenCV reference, run by the rig · 66 / 43, ~3 s"
            case .pythonEdgeDrawing: return "The benchmark's edge-drawing detector, run by the rig · 74 / 46, ~1 s"
            }
        }

        /// The Python engines run outside the Kit — only where the rig is.
        public var isExternal: Bool { self == .pythonReference || self == .pythonEdgeDrawing }

        /// The rig's detector id for an external engine.
        public var externalDetectorID: String? {
            switch self {
            case .pythonReference: return "opencv-reference"
            case .pythonEdgeDrawing: return "edge-drawing"
            default: return nil
            }
        }

        /// The engines that run inside the Kit, one configuration each.
        public static var kitEngines: [Engine] { allCases.filter { !$0.isExternal && $0 != .all } }
        public static var externalEngines: [Engine] { allCases.filter { $0.isExternal } }
        /// The picker's order: Use all first, then the Kit's, then the Mac's.
        public static var pickerEngines: [Engine] { [.all] + kitEngines + externalEngines }
        /// What a Use All run visits, given whether the Python engines can run here.
        public static func roster(externalAvailable: Bool) -> [Engine] {
            kitEngines + (externalAvailable ? externalEngines : [])
        }
    }

    public var engine: Engine
    public var search: ShapeSearch

    public init(engine: Engine = .standard, search: ShapeSearch = ShapeSearch()) {
        self.engine = engine; self.search = search
    }

    public static let `default` = ShapeDetectionMode()

    /// The Kit settings this mode runs with. For an external engine these are
    /// the standard file settings — what the app decodes the picture at, and
    /// the floor it applies to what comes back.
    public func settings() -> ShapeDetector.Settings {
        var s = search.fileSettings()
        switch engine {
        case .all, .standard, .pythonReference, .pythonEdgeDrawing: break
        case .visionOnly: s.regionProposals = false
        case .regions1024: s.regionProposalLongEdges = [1024]
        case .edgeChains: s.edgeChains = true
        case .edgeChainsOnly: s.regionProposals = false; s.edgeChains = true
        }
        return s
    }

    /// One line for logs and captions: `edgeChains · all/medium/all`.
    public var token: String { "\(engine.rawValue) · \(search.token)" }

    /// Where the Find shapes sheet and the Masks tab keep the last choice.
    public static let defaultsKey = "shapes.detectionMode"

    public static func load(from defaults: UserDefaults = .standard) -> ShapeDetectionMode {
        guard let data = defaults.data(forKey: defaultsKey),
              let mode = try? JSONDecoder().decode(ShapeDetectionMode.self, from: data) else { return .default }
        return mode
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
