import Foundation

/// One stretch of a capture on the Adjust screen's output-time ruler: a run of
/// footage that blends at a single speed. The base footage between moments is a
/// stretch; every high-rate burst ("moment") is its own.
struct BlendStretch: Identifiable, Equatable {
    enum Kind: Equatable {
        case base
        case moment
    }

    /// Position in render order — the same order the sequence blend walks its
    /// pieces, so a window override for stretch N retimes exactly piece N.
    let index: Int
    let kind: Kind
    /// The rate this stretch was recorded at.
    let fps: Int
    /// Real captured seconds in this stretch.
    let seconds: Double

    var id: Int { index }
    var frames: Double { seconds * Double(max(1, fps)) }

    /// The window that reproduces today's untouched render: moments go out
    /// frame-for-frame (slow motion), base footage at the project speed.
    func defaultWindow(baseWindow: Int) -> Int {
        kind == .moment ? 1 : baseWindow
    }

    /// Output seconds this stretch contributes at `window`.
    func outputSeconds(window: Int, outputFPS: Int) -> Double {
        SpeedMath.outputSeconds(inputFrames: frames, speed: window, outputFPS: outputFPS)
    }
}

/// Derives the ruler's stretches from a shoot's sequence sidecar — and, for
/// marker mode, the exact piece list the render will stitch, so the two can
/// never disagree about order.
enum StretchBuilder {
    /// Pieces shorter than this are dropped, matching the render's own floor.
    static let minimumPieceDuration = 0.05

    struct MarkerPiece: Equatable {
        var range: ClosedRange<Double>
        var isMoment: Bool
    }

    /// Marker mode records one file at the base rate; the marked intervals
    /// become moments. `duration` is the recording's length — probed from the
    /// asset by the render, read off the sidecar by the UI — and both paths
    /// build their pieces here so a window override lands on the right piece.
    static func markerPieces(sequence: LiveCaptureSequence, duration: Double) -> [MarkerPiece] {
        guard duration.isFinite, duration > 0 else { return [] }
        let sequenceStart = sequence.segments.first?.relativeStart ?? 0
        let sequenceEnd = sequence.segments.first?.relativeEnd ?? (sequenceStart + duration)
        // Both lists, and they mean the same thing here. A marker run made on
        // the phone puts its moments in `rampIntervals` (the toggle has always
        // written there); one made from the wrist puts them in `markIntervals`.
        // A single run can contain both, so a piece list built from one alone
        // would silently drop half the moments someone marked.
        let rampRanges = (sequence.rampIntervals + sequence.markIntervals)
            .compactMap { interval -> ClosedRange<Double>? in
                let intervalEnd = interval.relativeEnd ?? sequenceEnd
                let start = max(0, interval.relativeStart - sequenceStart)
                let end = min(duration, intervalEnd - sequenceStart)
                guard end > start else { return nil }
                return start...end
            }
            .sorted { $0.lowerBound < $1.lowerBound }

        guard !rampRanges.isEmpty else { return [] }

        var merged: [ClosedRange<Double>] = []
        for range in rampRanges {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }

        var pieces: [MarkerPiece] = []
        var cursor = 0.0
        for range in merged {
            if range.lowerBound - cursor > minimumPieceDuration {
                pieces.append(MarkerPiece(range: cursor...range.lowerBound, isMoment: false))
            }
            if range.upperBound - range.lowerBound > minimumPieceDuration {
                pieces.append(MarkerPiece(range: range.lowerBound...range.upperBound, isMoment: true))
            }
            cursor = max(cursor, range.upperBound)
        }
        if duration - cursor > minimumPieceDuration {
            pieces.append(MarkerPiece(range: cursor...duration, isMoment: false))
        }
        return pieces
    }

    /// The stretches of a recorded live sequence, in render order.
    /// `segmentSeconds` (probed file durations, keyed by segment file name)
    /// wins over the sidecar's wall-clock spans when present — the stopwatch
    /// runs a fraction of a second past what the camera actually wrote, and
    /// spans built on those phantom frames starve the render at end-of-file.
    static func stretches(
        for sequence: LiveCaptureSequence,
        segmentSeconds: [String: Double]? = nil
    ) -> [BlendStretch] {
        switch sequence.mode {
        case .ramp:
            return sequence.segments
                .sorted { $0.index < $1.index }
                .enumerated()
                .map { position, segment in
                    BlendStretch(
                        index: position,
                        kind: segment.frameRate > sequence.baseFrameRate ? .moment : .base,
                        fps: segment.frameRate > 0 ? segment.frameRate : max(1, sequence.baseFrameRate),
                        seconds: max(0, segmentSeconds?[segment.fileName]
                            ?? (segment.relativeEnd - segment.relativeStart))
                    )
                }
        case .marker:
            guard let whole = sequence.segments.first else { return [] }
            let duration = max(0, segmentSeconds?[whole.fileName]
                ?? (whole.relativeEnd - whole.relativeStart))
            let pieces = markerPieces(sequence: sequence, duration: duration)
            guard !pieces.isEmpty else {
                return singleStretch(seconds: duration, fps: Double(sequence.baseFrameRate))
            }
            return pieces.enumerated().map { position, piece in
                BlendStretch(
                    index: position,
                    kind: piece.isMoment ? .moment : .base,
                    fps: max(1, sequence.baseFrameRate),
                    seconds: piece.range.upperBound - piece.range.lowerBound
                )
            }
        }
    }

    /// A capture with no recorded structure — an import, a plain video — is one
    /// stretch covering the whole clip.
    static func singleStretch(seconds: Double?, fps: Double?) -> [BlendStretch] {
        [BlendStretch(
            index: 0,
            kind: .base,
            fps: Int((fps ?? 30).rounded()),
            seconds: max(0, seconds ?? 0)
        )]
    }
}

extension Array where Element == BlendStretch {
    /// "Moment 2" / "Stretch 1" — ordinal within the stretch's own kind.
    func stretchName(at index: Int) -> String {
        guard index < count else { return "Stretch \(index + 1)" }
        let stretch = self[index]
        let ordinal = self[...index].filter { $0.kind == stretch.kind }.count
        switch stretch.kind {
        case .moment:
            return "Moment \(ordinal)"
        case .base:
            return count == 1 ? "Whole clip" : "Stretch \(ordinal)"
        }
    }

    var momentCount: Int { filter { $0.kind == .moment }.count }
}
