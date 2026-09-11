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
    /// The lens's horizontal field of view at the shutter, in degrees — what
    /// lets the register work out a rectangle's own proportions from the
    /// angle it was seen at. Read per shot: zoom changes it.
    public var horizontalFieldOfView: Double?
    /// How the live pass went this session: samples landed, samples that
    /// found anything, and what the last one looked at and refused.
    public var samples = 0
    public var samplesWithShapes = 0
    public var lastSample: ShapeDetector.Diagnostics?

    public init(kept: [DetectedShape], dismissed: [DetectedShape], frameSize: CGSize, search: ShapeSearch = ShapeSearch(),
                horizontalFieldOfView: Double? = nil, samples: Int = 0, samplesWithShapes: Int = 0,
                lastSample: ShapeDetector.Diagnostics? = nil) {
        self.kept = kept; self.dismissed = dismissed; self.frameSize = frameSize; self.search = search
        self.horizontalFieldOfView = horizontalFieldOfView
        self.samples = samples; self.samplesWithShapes = samplesWithShapes; self.lastSample = lastSample
    }

    public var isEmpty: Bool { kept.isEmpty && dismissed.isEmpty }
}

/// The story of a capture made with auto shape mode on, kept in the
/// register beside the shapes (2026-09-11, Steven: "the more that we log,
/// the more that we can know has a good strike ratio"): the dials, the lens,
/// how the live pass went, what its last sample refused, and what the file
/// pass refused. Written even when nothing was found — especially then.
public struct ViewfinderTrail: Codable, Equatable, Sendable {
    public var search: ShapeSearch
    public var horizontalFieldOfView: Double?
    /// The upright preview frame, in pixels; zero when no sample landed.
    public var frameSize: CGSize
    public var samples: Int
    public var samplesWithShapes: Int
    public var kept: Int
    public var dismissed: Int
    /// The live pass's last sample before the shutter.
    public var lastSample: ShapeDetector.Diagnostics?
    /// The full pass on the photo.
    public var file: ShapeDetector.Diagnostics?

    public init(_ v: ViewfinderShapes) {
        search = v.search; horizontalFieldOfView = v.horizontalFieldOfView; frameSize = v.frameSize
        samples = v.samples; samplesWithShapes = v.samplesWithShapes; kept = v.kept.count; dismissed = v.dismissed.count
        lastSample = v.lastSample
    }

    /// One line: "circular/high/all · lens 24.9° · 212 samples, 3 with shapes · 0 kept, 0 dismissed".
    public var summary: String {
        var s = search.token
        if let fov = horizontalFieldOfView { s += String(format: " · lens %.1f°", fov) }
        s += " · \(samples) sample\(samples == 1 ? "" : "s"), \(samplesWithShapes) with shapes · \(kept) kept, \(dismissed) dismissed"
        return s
    }
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
