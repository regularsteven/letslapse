import Foundation
import LetsLapseKit

/// The 3a warp timeline: the source partitioned into stretches [tᵢ, tᵢ₊₁),
/// each with a speed vᵢ in ×-real-time, and a seam between every neighbouring
/// pair carrying how the speed change happens (instant step, or an ease that
/// borrows time from one chosen side).
///
/// The invariant, from the design handoff: this is a monotonic, continuous
/// time-warp — never a trim. Every source frame lands in exactly one output
/// moment; the blur window follows the instantaneous speed through every ease.
struct WarpTimeline: Codable, Equatable {
    struct Seam: Codable, Equatable {
        enum Ramp: String, Codable, CaseIterable {
            case step
            case half = "0.5s"
            case one = "1s"
            case two = "2s"

            /// Ease length in output (clip) seconds.
            var seconds: Double {
                switch self {
                case .step: return 0
                case .half: return 0.5
                case .one: return 1
                case .two: return 2
                }
            }

            var label: String { rawValue }
        }

        enum Side: String, Codable {
            case before
            case after
        }

        var ramp: Ramp
        /// Which stretch spends the time. Required whenever `ramp != .step`;
        /// nil renders as a step and the UI shows "·?" until the user picks.
        var side: Side?

        static let step = Seam(ramp: .step, side: nil)
    }

    /// Stretch boundaries in source seconds — always sorted, first 0, last the
    /// source length. `speeds.count == bounds.count - 1`,
    /// `seams.count == bounds.count - 2`.
    var bounds: [Double]
    var speeds: [Double]
    var seams: [Seam]

    /// Prototype's carving tolerances, in source seconds.
    static let minimumStretch = 0.5
    static let minimumNomination = 2.0
    /// Speed detents for free values entered elsewhere; chips carry the six
    /// canonical ones.
    static let speedRange = 0.25...240.0

    init(bounds: [Double], speeds: [Double], seams: [Seam]) {
        self.bounds = bounds
        self.speeds = speeds
        self.seams = seams
    }

    /// One stretch covering the whole source at `speed`.
    init(sourceSeconds: Double, speed: Double) {
        bounds = [0, max(Self.minimumStretch, sourceSeconds)]
        speeds = [speed]
        seams = []
    }

    var sourceSeconds: Double { bounds.last ?? 0 }
    var stretchCount: Int { speeds.count }

    func range(of stretch: Int) -> ClosedRange<Double> {
        bounds[stretch]...bounds[stretch + 1]
    }

    func length(of stretch: Int) -> Double {
        bounds[stretch + 1] - bounds[stretch]
    }

    func stretchIndex(at time: Double) -> Int {
        for index in 0..<max(1, bounds.count - 2) where time < bounds[index + 1] {
            return index
        }
        return max(0, bounds.count - 2)
    }

    /// True once the user (or a seed from recorded structure) has produced more
    /// than one stretch or moved off a single uniform speed.
    var isTrivial: Bool { stretchCount <= 1 }

    // MARK: - Edits (the prototype's algorithms, verbatim in spirit)

    /// The seam a fresh boundary gets: an ease when the speed jump is big
    /// enough to read as one, an instant step otherwise. Side is never assumed.
    static func smartSeam(_ v1: Double, _ v2: Double) -> Seam {
        let hi = Swift.max(v1, v2), lo = Swift.max(0.0001, Swift.min(v1, v2))
        return hi / lo > 4 ? Seam(ramp: .one, side: nil) : .step
    }

    /// Carve [a, b] into a real-time (1×) stretch exactly where drawn. Swallows
    /// boundaries inside the range, keeps outside speeds by midpoint sampling,
    /// keeps surviving seams, smart-defaults the new ones. Returns the new
    /// stretch's index, or nil when the drag was too short.
    mutating func nominate(from a: Double, to b: Double) -> Int? {
        let total = sourceSeconds
        let lo = Swift.max(0, Swift.min(a, b)), hi = Swift.min(total, Swift.max(a, b))
        guard hi - lo >= Self.minimumNomination else { return nil }
        let eps = Self.minimumStretch
        let old = self
        let inner = bounds.dropFirst().dropLast().filter { $0 < lo - eps || $0 > hi + eps }
        var newBounds = ([0] + inner + [lo, hi, total]).sorted()
        // Collapse any bound that landed within eps of the carve edges.
        newBounds = newBounds.enumerated().filter { index, value in
            index == 0 || value - newBounds[index - 1] > 0.0001
        }.map(\.1)
        var newSpeeds: [Double] = []
        for index in 0..<(newBounds.count - 1) {
            let mid = (newBounds[index] + newBounds[index + 1]) / 2
            newSpeeds.append(mid > lo && mid < hi ? 1 : old.speeds[old.stretchIndex(at: mid)])
        }
        var newSeams: [Seam] = []
        for index in 1..<(newBounds.count - 1) {
            let bound = newBounds[index]
            if let oldIndex = old.bounds.firstIndex(where: { abs($0 - bound) < 0.0001 }),
               oldIndex > 0, oldIndex < old.bounds.count - 1 {
                newSeams.append(old.seams[oldIndex - 1])
            } else {
                newSeams.append(Self.smartSeam(newSpeeds[index - 1], newSpeeds[index]))
            }
        }
        bounds = newBounds
        speeds = newSpeeds
        seams = newSeams
        return newBounds.firstIndex { abs($0 - lo) < 0.0001 }
    }

    /// Remove a stretch by merging it into its left neighbour (right neighbour
    /// for the first), which keeps that neighbour's speed. Returns the merged
    /// selection index.
    mutating func remove(_ stretch: Int) -> Int {
        guard stretchCount > 1, stretch < stretchCount else { return stretch }
        let boundary = stretch > 0 ? stretch : 1
        bounds.remove(at: boundary)
        let keep = stretch > 0 ? speeds[stretch - 1] : speeds[1]
        let mergeAt = stretch > 0 ? stretch - 1 : 0
        speeds.removeSubrange(mergeAt...(mergeAt + 1))
        speeds.insert(keep, at: mergeAt)
        seams.remove(at: boundary - 1)
        return Swift.max(0, stretch - 1)
    }

    /// Split a stretch at `time` when it falls comfortably inside it, else at
    /// its midpoint. The new seam is a step — both halves keep the speed.
    mutating func split(_ stretch: Int, at time: Double) {
        let lo = bounds[stretch], hi = bounds[stretch + 1]
        let cut = (time > lo + 1 && time < hi - 1) ? time : (lo + hi) / 2
        bounds.append(cut)
        bounds.sort()
        speeds.insert(speeds[stretch], at: stretch)
        guard let position = bounds.firstIndex(of: cut) else { return }
        seams.insert(.step, at: position - 1)
    }

    /// Move boundary `j` to `time`, ripple-pushing neighbours so every stretch
    /// keeps at least the minimum span. Endpoints never move.
    mutating func resize(boundary j: Int, to time: Double) {
        guard j > 0, j < bounds.count - 1 else { return }
        let eps = Self.minimumStretch
        bounds[j] = Swift.max(eps, Swift.min(sourceSeconds - eps, time))
        var k = j - 1
        while k > 0 {
            bounds[k] = Swift.min(bounds[k], bounds[k + 1] - eps)
            k -= 1
        }
        k = j + 1
        while k < bounds.count - 1 {
            bounds[k] = Swift.max(bounds[k], bounds[k - 1] + eps)
            k += 1
        }
    }

    mutating func setSpeed(_ speed: Double, for stretch: Int) {
        guard stretch < speeds.count else { return }
        speeds[stretch] = Swift.min(Swift.max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
    }

    mutating func setSeam(_ seam: Seam, at index: Int) {
        guard index < seams.count else { return }
        seams[index] = seam
    }

    // MARK: - Output-time mapping

    /// Cumulative output (clip) seconds at each stretch bound — steady-speed
    /// spans (length ÷ speed), the same approximation the timeline bar draws
    /// in. Seam eases shift this by fractions of a second; the compiled
    /// schedule is the exact answer where exactness matters (the render).
    var outputBounds: [Double] {
        var bounds = [0.0]
        for index in 0..<stretchCount {
            bounds.append(bounds[index] + length(of: index) / Swift.max(0.0001, speeds[index]))
        }
        return bounds
    }

    /// Source seconds → output seconds through the piecewise-linear warp.
    func outputTime(atSource time: Double) -> Double {
        let clamped = Swift.min(Swift.max(0, time), sourceSeconds)
        let index = stretchIndex(at: clamped)
        return outputBounds[index]
            + (clamped - bounds[index]) / Swift.max(0.0001, speeds[index])
    }

    /// Output seconds → source seconds — the inverse of `outputTime(atSource:)`.
    func sourceTime(atOutput output: Double) -> Double {
        let outs = outputBounds
        let clamped = Swift.min(Swift.max(0, output), outs.last ?? 0)
        var index = 0
        while index < outs.count - 2, clamped >= outs[index + 1] {
            index += 1
        }
        let source = bounds[index]
            + (clamped - outs[index]) * Swift.max(0.0001, speeds[index])
        return Swift.min(Swift.max(0, source), sourceSeconds)
    }

    // MARK: - Display

    /// "¼×" / "½×" / "1×" / "0.8×" / "15×"
    static func speedLabel(_ v: Double) -> String {
        if abs(v - 0.25) < 0.001 { return "¼×" }
        if abs(v - 0.5) < 0.001 { return "½×" }
        if abs(v.rounded() - v) < 0.001 { return "\(Int(v.rounded()))×" }
        return String(format: "%.1f×", v)
    }

    /// The character word for a time-speed — the design's t2 vocabulary.
    static func speedWord(_ v: Double) -> String {
        if v < 1 { return "slow motion" }
        if abs(v - 1) < 0.001 { return "real time" }
        if v < 10 { return "gentle" }
        if v < 25 { return "subtle" }
        if v < 50 { return "smooth" }
        if v < 100 { return "flowing" }
        return "streaks"
    }

    /// "11:30" — source clock.
    static func clock(_ t: Double) -> String {
        let whole = Int(t.rounded())
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}

// MARK: - Compiler

/// Compiles a warp timeline into the engine's per-output-frame window
/// schedules — one schedule per source region (file) — by sampling the
/// continuous speed curve: constant inside stretches, smoothstep through every
/// eased seam, the ease borrowing source time from its chosen side.
enum WarpCompiler {
    /// One physically recorded region of the source axis: `span` real seconds
    /// at `fps`. A plain video is one region; a ramp-mode shoot is one per
    /// segment file, concatenated (inter-file gaps dropped).
    struct SourceRegion {
        var span: Double
        var fps: Double
    }

    struct Compiled {
        /// Per-region window schedules, aligned with the input regions.
        var schedules: [[Int]]
        /// Per-region, per-output-frame source times (mid-window, on the
        /// global concatenated source axis) — the exact output-frame →
        /// source-moment map the reframe crop is evaluated against.
        var frameSourceTimes: [[Double]]
        /// Exact output length of the warp: total output frames / outFps.
        var outputSeconds: Double
        var outputFrames: Int { schedules.reduce(0) { $0 + $1.count } }
    }

    /// A run of source time at one sampled speed.
    private struct Piece {
        var start: Double
        var end: Double
        var speed: Double
    }

    static let easeSteps = 16

    private static func smoothstep(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// The piecewise speed curve in the source domain: stretches minus the
    /// spans their eased seams borrow, plus the sampled ease runs. A seam with
    /// no side picked renders as a step, exactly as the UI warns.
    private static func pieces(for warp: WarpTimeline) -> [Piece] {
        let bounds = warp.bounds
        let speeds = warp.speeds
        guard speeds.count > 0, bounds.count == speeds.count + 1 else { return [] }

        // How much of each stretch the eases at its two ends consume.
        var headCost = [Double](repeating: 0, count: speeds.count)
        var tailCost = [Double](repeating: 0, count: speeds.count)
        struct EaseRun { var seamIndex: Int; var side: WarpTimeline.Seam.Side; var runs: [Piece] }
        var eases: [EaseRun] = []

        for (index, seam) in warp.seams.enumerated() {
            let duration = seam.ramp.seconds
            guard duration > 0, let side = seam.side else { continue }
            let boundary = bounds[index + 1]
            let vA = speeds[index], vB = speeds[index + 1]
            guard abs(vA - vB) > 0.0001 else { continue }
            let borrowing = side == .before ? index : index + 1
            // Room in the borrowing stretch, leaving space for its other ease
            // and a sliver of steady speed.
            let stretchSpan = bounds[borrowing + 1] - bounds[borrowing]
            let alreadyBorrowed = headCost[borrowing] + tailCost[borrowing]
            let available = max(0, (stretchSpan - alreadyBorrowed) * 0.9)
            guard available > 0.01 else { continue }

            func sourceCost(_ dur: Double) -> Double {
                (0..<easeSteps).reduce(0.0) { sum, step in
                    let t = (Double(step) + 0.5) / Double(easeSteps)
                    return sum + (vA + (vB - vA) * smoothstep(t)) * (dur / Double(easeSteps))
                }
            }
            var dur = duration
            var cost = sourceCost(dur)
            if cost > available {
                dur = duration * available / cost
                cost = sourceCost(dur)
            }
            // An ease squeezed below a few output frames reads as a step —
            // skip it rather than emit sub-frame runs.
            guard dur > 0.05 else { continue }

            var runs: [Piece] = []
            var cursor = side == .before ? boundary - cost : boundary
            for step in 0..<easeSteps {
                let t = (Double(step) + 0.5) / Double(easeSteps)
                let v = vA + (vB - vA) * smoothstep(t)
                let width = v * (dur / Double(easeSteps))
                runs.append(Piece(start: cursor, end: cursor + width, speed: v))
                cursor += width
            }
            if side == .before {
                tailCost[index] += cost
            } else {
                headCost[index + 1] += cost
            }
            eases.append(EaseRun(seamIndex: index, side: side, runs: runs))
        }

        // Assemble: each stretch's steady middle, with ease runs replacing the
        // borrowed ends.
        var result: [Piece] = []
        for stretch in 0..<speeds.count {
            let start = bounds[stretch] + headCost[stretch]
            let end = bounds[stretch + 1] - tailCost[stretch]
            for ease in eases where ease.side == .after && ease.seamIndex + 1 == stretch {
                result.append(contentsOf: ease.runs)
            }
            if end > start {
                result.append(Piece(start: start, end: end, speed: speeds[stretch]))
            }
            for ease in eases where ease.side == .before && ease.seamIndex == stretch {
                result.append(contentsOf: ease.runs)
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Compile the warp over `regions`, optionally restricted to the source
    /// range [activeStart, activeEnd] (head/tail trim). Windows are clamped so
    /// slow motion never asks for less than one source frame per output frame
    /// — frame-for-frame is the slowest the blend can play.
    static func compile(
        _ warp: WarpTimeline,
        regions: [SourceRegion],
        outputFPS: Int,
        activeStart: Double = 0,
        activeEnd: Double? = nil
    ) -> Compiled {
        let outFps = Double(max(1, outputFPS))
        let pieces = pieces(for: warp)
        let limit = min(activeEnd ?? warp.sourceSeconds, warp.sourceSeconds)
        guard !pieces.isEmpty, !regions.isEmpty, limit > activeStart else {
            return Compiled(
                schedules: regions.map { _ in [] },
                frameSourceTimes: regions.map { _ in [] },
                outputSeconds: 0)
        }

        func speed(at time: Double, pointer: inout Int) -> Double {
            while pointer < pieces.count - 1, time >= pieces[pointer].end {
                pointer += 1
            }
            return pieces[pointer].speed
        }

        var schedules: [[Int]] = []
        var frameTimes: [[Double]] = []
        var regionStart = 0.0
        var pointer = 0
        for region in regions {
            let fps = max(1, region.fps)
            let regionEnd = regionStart + region.span
            var windows: [Int] = []
            var times: [Double] = []
            var cursor = max(regionStart, activeStart)
            let end = min(regionEnd, limit)
            while cursor < end - 0.0005 {
                let v = max(speed(at: cursor, pointer: &pointer), outFps / fps)
                let window = max(1, Int((v * fps / outFps).rounded()))
                windows.append(window)
                times.append(cursor + Double(window) / fps / 2)
                cursor += Double(window) / fps
            }
            schedules.append(windows)
            frameTimes.append(times)
            regionStart = regionEnd
        }
        let frames = schedules.reduce(0) { $0 + $1.count }
        return Compiled(
            schedules: schedules,
            frameSourceTimes: frameTimes,
            outputSeconds: Double(frames) / outFps)
    }
}
