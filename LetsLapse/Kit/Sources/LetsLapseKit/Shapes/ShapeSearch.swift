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
        s.minDiameterFractionOfShortEdge = size.range.lowerBound
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
        case .low:
            s.contrastAdjustments = [1.0]
            s.maxFitResidual = 0.04
            s.minCoverage = 0.8
            s.rectMinimumConfidence = 0.75
            s.quadEdgeSupport = 0.6
            s.edgeCircleMinSupport = 0.45
            s.edgeCircleMinCoverage = 0.65
            s.edgeCircleMaxGapBins = 5
        }
    }
}
