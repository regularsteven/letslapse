import Foundation
import CoreGraphics

// The Match step of the Shape-mation builder (design signed off 2026-09-11):
// after a family is picked, how strict to be about it, so the slideshow lands
// shapes on one another. Family membership is what the register says; Match
// narrows it — and, for circles and ovals, says how the renderer should turn
// or un-tilt the shape so every pick coincides.

public struct ShapeMatch: Equatable, Codable, Sendable {
    /// Strict · Normal · Loose — the meaning per family is in `matches`.
    public enum Strictness: String, Codable, CaseIterable, Sendable {
        case strict, normal, loose
        public var title: String { rawValue.capitalized }
    }

    /// Ovals: keep the angle as shot, or turn each level (major axis horizontal).
    public enum Angle: String, Codable, CaseIterable, Sendable {
        case any, level
        public var title: String { self == .any ? "Any" : "Level" }
    }

    /// Rectangles: which way the rectangle lies.
    public enum Orientation: String, CaseIterable, Codable, Sendable {
        case any, landscape, portrait
        public var title: String { rawValue.capitalized }
    }

    /// Rectangles: a canonical ratio to match on — coarse on purpose. Page is
    /// A-series and Letter alike (9 % apart; Vision's corners give ±1–2 % and
    /// the Scanner's own rule is that it cannot and should not tell them
    /// apart). Ratios are width ÷ height in landscape form, ≥ 1.
    public enum AspectClass: String, Codable, CaseIterable, Sendable {
        case any, fourThree, threeTwo, sixteenNine, page, fiveFour, twoOne, custom

        public var title: String {
            switch self {
            case .any: return "Any"
            case .fourThree: return "4:3"
            case .threeTwo: return "3:2"
            case .sixteenNine: return "16:9"
            case .page: return "Page"
            case .fiveFour: return "5:4"
            case .twoOne: return "2:1"
            case .custom: return "Custom"
            }
        }

        /// nil for `any` and `custom` (the custom ratio lives on the match).
        public var ratio: Double? {
            switch self {
            case .any, .custom: return nil
            case .fourThree: return 4.0 / 3.0
            case .threeTwo: return 3.0 / 2.0
            case .sixteenNine: return 16.0 / 9.0
            case .page: return 2.0.squareRoot()
            case .fiveFour: return 5.0 / 4.0
            case .twoOne: return 2.0
            }
        }
    }

    public var family: DetectedShape.Family
    public var strictness: Strictness = .normal
    /// Ovals: the ratio (minor ÷ major) to match, nil for Any.
    public var ovalRatio: Double?
    /// Ovals: how the renderer turns them.
    public var angle: Angle = .level
    /// Rectangles.
    public var aspectClass: AspectClass = .any
    /// Rectangles, `aspectClass == .custom`: width and height as whole numbers.
    public var customWidth = 4
    public var customHeight = 3
    public var orientation: Orientation = .any

    public init(family: DetectedShape.Family) {
        self.family = family
    }

    // MARK: - The rules

    /// Circle: minor ÷ major at least this.
    public var minRoundness: Double {
        switch strictness {
        case .strict: return 0.95
        case .normal: return 0.85
        case .loose: return 0.70
        }
    }

    /// Oval: how far minor ÷ major may sit from `ovalRatio`.
    public var ovalTolerance: Double {
        switch strictness {
        case .strict: return 0.05
        case .normal: return 0.10
        case .loose: return 0.20
        }
    }

    /// Square: the longer side over the shorter, at most this.
    public var maxSquareAspect: Double {
        switch strictness {
        case .strict: return 1.05
        case .normal: return 1.25
        case .loose: return 1.40
        }
    }

    /// Rectangle: relative distance from the class's ratio allowed. Normal
    /// is 10 % so that Page keeps its promise — Letter sits 8.5 % from the
    /// A-series ratio it is merged with.
    public var rectangleTolerance: Double {
        switch strictness {
        case .strict: return 0.03
        case .normal: return 0.10
        case .loose: return 0.15
        }
    }

    /// The rectangle ratio matched on, landscape form, or nil for Any.
    public var targetAspect: Double? {
        switch aspectClass {
        case .any: return nil
        case .custom:
            guard customWidth > 0, customHeight > 0 else { return nil }
            let r = Double(customWidth) / Double(customHeight)
            return max(r, 1 / r)
        default: return aspectClass.ratio
        }
    }

    public func matches(_ shape: DetectedShape) -> Bool {
        switch family {
        case .circle:
            return shape.kind == .ellipse && shape.obliquity >= minRoundness
        case .oval:
            guard shape.kind == .ellipse, shape.obliquity < 0.85 else { return false }
            guard let target = ovalRatio else { return true }
            return abs(shape.obliquity - target) <= ovalTolerance
        case .square:
            guard shape.kind == .quad else { return false }
            let a = shape.effectiveAspect
            return max(a, 1 / a) <= maxSquareAspect
        case .rectangle:
            guard shape.kind == .quad else { return false }
            switch orientation {
            case .any: break
            case .landscape: guard shape.wide else { return false }
            case .portrait: guard !shape.wide else { return false }
            }
            let a = shape.effectiveAspect
            let landscape = max(a, 1 / a)
            guard let target = targetAspect else { return shape.family == .rectangle }
            return abs(landscape / target - 1) <= rectangleTolerance
        }
    }

    /// One line for a record's title and list: "Circle · Normal", "Oval 0.6 · Normal · level", "Rectangle 4:3 · Strict · landscape".
    public var summary: String {
        switch family {
        case .circle: return "Circle · \(strictness.title)"
        case .oval:
            let ratio = ovalRatio.map { String(format: "%.1f", $0) } ?? "any ratio"
            return "Oval \(ratio) · \(strictness.title)" + (angle == .level ? " · level" : "")
        case .square: return "Square · \(strictness.title)"
        case .rectangle:
            let cls = aspectClass == .custom ? "\(customWidth):\(customHeight)" : aspectClass.title
            return "Rectangle \(cls) · \(strictness.title)" + (orientation == .any ? "" : " · \(orientation.rawValue)")
        }
    }
}
