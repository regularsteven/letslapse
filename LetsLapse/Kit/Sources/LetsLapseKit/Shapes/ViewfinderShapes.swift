import Foundation
import CoreGraphics

// What the Photo viewfinder had on screen when the shutter fired, and how it
// becomes the new project's register once the file exists. The live pass is
// deliberately cheaper than the file pass (one contour polarity at 384 px), so
// its geometry is an *intent* — which shapes the person saw and left standing —
// and the file pass supplies the precision: every kept shape snaps to its
// full-resolution fit where one overlaps it.

/// The viewfinder's shapes at the moment of capture. All geometry is
/// normalised to the upright preview frame, which is the same space as the
/// upright still (same lens, same field of view, same pose tag), so nothing
/// here needs re-projecting — only `nativeDiameterPx` is in preview pixels.
public struct ViewfinderShapes: Sendable, Equatable {
    /// Traced on screen and not tapped away.
    public var kept: [DetectedShape]
    /// Tapped away. Kept so a file detection of the same thing is not recorded.
    public var dismissed: [DetectedShape]
    /// The upright preview frame the shapes are measured in, in pixels.
    public var frameSize: CGSize
    /// The dials the viewfinder was set to — the file pass looks for the same things.
    public var search: ShapeSearch

    public init(kept: [DetectedShape], dismissed: [DetectedShape], frameSize: CGSize, search: ShapeSearch = ShapeSearch()) {
        self.kept = kept; self.dismissed = dismissed; self.frameSize = frameSize; self.search = search
    }

    public var isEmpty: Bool { kept.isEmpty && dismissed.isEmpty }
}

public enum ShapeReconciler {
    /// Two shapes are the same thing when their bounds overlap this much.
    /// Lower than the detector's own 0.5 dedupe: a 384 px trace and a 1024 px
    /// fit of one circle differ by a few percent in size and position, and the
    /// same shape a beat apart in a hand-held viewfinder drifts further still.
    public static let matchThreshold = 0.4

    /// What the register records straight away, before the file pass: every
    /// kept shape as captured, with its size restated in the still's pixels.
    public static func provisional(_ viewfinder: ViewfinderShapes, photoSize: CGSize) -> [DetectedShape] {
        viewfinder.kept.map { captured($0, from: viewfinder.frameSize, to: photoSize) }
    }

    /// The register once the captured file has been through the full
    /// detector. Kept shapes take the file's geometry where a file detection
    /// of the same kind overlaps them (and keep their own where none does);
    /// file detections that overlap a dismissed shape are dropped; the rest —
    /// shapes the cheaper live pass never drew, so the person never saw — are
    /// recorded as plain detections. Every kept shape keeps its identity.
    public static func reconcile(_ viewfinder: ViewfinderShapes, photoDetections: [DetectedShape],
                                 photoSize: CGSize) -> [DetectedShape] {
        var remaining = photoDetections
        var out: [DetectedShape] = []
        for live in viewfinder.kept {
            let base = captured(live, from: viewfinder.frameSize, to: photoSize)
            if let i = bestMatch(for: base, in: remaining) {
                var snapped = remaining.remove(at: i)
                snapped.id = live.id
                snapped.source = .captured
                snapped.name = live.name
                out.append(snapped)
            } else {
                out.append(base)
            }
        }
        let dismissed = viewfinder.dismissed.map { captured($0, from: viewfinder.frameSize, to: photoSize) }
        for shape in remaining {
            if dismissed.contains(where: { $0.kind == shape.kind && ShapeDetector.overlap($0, shape) >= matchThreshold }) { continue }
            var extra = shape
            extra.source = .detected
            out.append(extra)
        }
        return out
    }

    /// The index of the same-kind candidate overlapping `shape` most, if any does enough.
    public static func bestMatch(for shape: DetectedShape, in candidates: [DetectedShape]) -> Int? {
        var best: (Int, Double)?
        for (i, c) in candidates.enumerated() where c.kind == shape.kind {
            let o = ShapeDetector.overlap(shape, c)
            if o >= matchThreshold, o > (best?.1 ?? 0) { best = (i, o) }
        }
        return best?.0
    }

    /// A live shape as the register stores it: normalised geometry unchanged,
    /// `nativeDiameterPx` scaled from preview pixels to the still's.
    static func captured(_ live: DetectedShape, from previewSize: CGSize, to photoSize: CGSize) -> DetectedShape {
        var s = live
        s.source = .captured
        if previewSize.width > 0 {
            s.nativeDiameterPx = live.nativeDiameterPx * Double(photoSize.width / previewSize.width)
        }
        return s
    }
}
