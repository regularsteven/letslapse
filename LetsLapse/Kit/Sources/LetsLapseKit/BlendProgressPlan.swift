import Foundation

/// Maps per-stage local 0→1 fractions into one monotonic global progress bar.
///
/// A blend run is partitioned into bands: one band per source clip, sized by
/// that clip's estimated input frames (the work is proportional to frames
/// read), then optional stitch and grade-bake bands, and a final save band
/// ending at 1.0. Engines keep reporting their own local 0→1 fraction; the
/// app maps each report through `globalFraction(clip:localFraction:)` so the
/// bar never resets across clip boundaries.
public struct BlendProgressPlan: Sendable, Equatable {
    /// Estimated input frames per clip after weight sanitising (all ≥ 1).
    public let clipFrames: [Int]
    /// Sum of `clipFrames`.
    public let totalFrames: Int
    /// One band per clip, partitioning 0...blend-end proportionally to `clipFrames`.
    public let clipBands: [ClosedRange<Double>]
    /// Band the stitch export fills, when the run stitches multiple pieces.
    public let stitchBand: ClosedRange<Double>?
    /// Band the grade-bake export fills, when a grade will be baked in.
    public let gradeBand: ClosedRange<Double>?
    /// Band for the final save/copy; always ends at 1.0.
    public let saveBand: ClosedRange<Double>

    /// Stages that still need bar room after all clips finish blending
    /// (stitch/grade plus the save itself). Used to pad the blend-phase ETA.
    public var tailStageCount: Int {
        (stitchBand == nil ? 0 : 1) + (gradeBand == nil ? 0 : 1) + 1
    }

    public static func make(clipFrames: [Int], hasStitch: Bool, hasGrade: Bool) -> BlendProgressPlan {
        // A non-positive estimate means the sidecar or probe failed for that
        // clip; give it the mean weight of the known clips rather than zero
        // width or an equal fifth of the bar.
        let positives = clipFrames.filter { $0 > 0 }
        let fallback = positives.isEmpty
            ? 1
            : max(1, Int((Double(positives.reduce(0, +)) / Double(positives.count)).rounded()))
        var weights = clipFrames.map { $0 > 0 ? $0 : fallback }
        if weights.isEmpty { weights = [1] }

        let blendEnd: Double
        let stitchEnd: Double?
        let gradeEnd: Double?
        switch (hasStitch, hasGrade) {
        case (true, true): blendEnd = 0.88; stitchEnd = 0.96; gradeEnd = 0.99
        case (true, false): blendEnd = 0.90; stitchEnd = 0.98; gradeEnd = nil
        case (false, true): blendEnd = 0.95; stitchEnd = nil; gradeEnd = 0.99
        case (false, false): blendEnd = 0.98; stitchEnd = nil; gradeEnd = nil
        }

        let total = weights.reduce(0, +)
        var bands: [ClosedRange<Double>] = []
        var cursor = 0.0
        var cumulative = 0
        for weight in weights {
            cumulative += weight
            let top = min(blendEnd, blendEnd * Double(cumulative) / Double(total))
            bands.append(cursor...max(cursor, top))
            cursor = max(cursor, top)
        }
        if let last = bands.indices.last {
            bands[last] = bands[last].lowerBound...blendEnd
        }

        let stitchBand = stitchEnd.map { blendEnd...$0 }
        let gradeBand = gradeEnd.map { (stitchEnd ?? blendEnd)...$0 }
        let saveStart = gradeEnd ?? stitchEnd ?? blendEnd
        return BlendProgressPlan(
            clipFrames: weights,
            totalFrames: total,
            clipBands: bands,
            stitchBand: stitchBand,
            gradeBand: gradeBand,
            saveBand: saveStart...1.0
        )
    }

    /// Global bar position when clip `index` reports `localFraction` (0…1).
    public func globalFraction(clip index: Int, localFraction: Double) -> Double {
        let fraction = min(max(localFraction, 0), 1)
        guard clipBands.indices.contains(index) else { return fraction }
        let band = clipBands[index]
        return band.lowerBound + (band.upperBound - band.lowerBound) * fraction
    }

    /// Whole-run frames completed when clip `index` reports `localFraction`.
    public func framesDone(clip index: Int, localFraction: Double) -> Int {
        guard clipFrames.indices.contains(index) else { return 0 }
        let fraction = min(max(localFraction, 0), 1)
        let before = clipFrames.prefix(index).reduce(0, +)
        let done = before + Int((Double(clipFrames[index]) * fraction).rounded())
        return min(done, totalFrames)
    }
}
