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

        /// An ease always straddles its seam: the compiler splits the sweep
        /// at the fast side's renderable floor, so each side plays exactly
        /// the speeds its footage can. (Timelines saved before 2026-08-11
        /// carried a `side` choice; decoding ignores it.)
        var ramp: Ramp

        static let step = Seam(ramp: .step)
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
    /// enough to read as one, an instant step otherwise.
    static func smartSeam(_ v1: Double, _ v2: Double) -> Seam {
        let hi = Swift.max(v1, v2), lo = Swift.max(0.0001, Swift.min(v1, v2))
        return hi / lo > 4 ? Seam(ramp: .one) : .step
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
        // 50 caps the smooth band: the 50× chip says "smooth", and captions
        // must agree with the chip that set them (60× owns "flowing").
        if v <= 50 { return "smooth" }
        if v < 100 { return "flowing" }
        return "streaks"
    }

    /// "11:30" — source clock.
    static func clock(_ t: Double) -> String {
        let whole = Int(t.rounded())
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    // MARK: - Interval vocabulary

    /// The interval timeline's speed label: over stills a stretch's "speed"
    /// is its blend depth — photos per output frame — and "5:1" says exactly
    /// that, where the video vocabulary's "5×" would read as a rate.
    static func depthLabel(_ v: Double) -> String {
        "\(max(1, Int(v.rounded()))):1"
    }

    /// The character word for a depth — Crisp↔Long exposure, the poles the
    /// old BLEND slider named at its ends. The bands are cut so each of the
    /// canonical chips (1, 2, 3, 5, 8) lands on its own word.
    static func depthWord(_ v: Double) -> String {
        let depth = max(1, Int(v.rounded()))
        if depth == 1 { return "crisp" }
        if depth == 2 { return "soft" }
        if depth <= 4 { return "silky" }
        if depth <= 7 { return "long exposure" }
        return "streaks"
    }

    /// "812 fr" — the axis label for a shoot that never recorded a clock,
    /// where counting frames is honest and inventing seconds isn't.
    static func frameLabel(_ t: Double) -> String {
        "\(max(0, Int(t.rounded()))) fr"
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
    /// segment file, concatenated. `leadingGap` is the real time the camera
    /// LOST before this region's first frame (format switches drop ~0.6s) —
    /// no footage exists for it, but the world moved through it, and an ease
    /// crossing the boundary must account for that displacement or the cut
    /// reads as a dropped-frames glitch.
    struct SourceRegion {
        var span: Double
        var fps: Double
        var leadingGap: Double = 0
    }

    /// What actually happened to one seam's requested ease: the output
    /// seconds asked for versus what the borrowing stretch could afford —
    /// `applied` is 0 when the ease was dropped and the seam plays as a step.
    struct SeamEase: Equatable {
        var requested: Double
        var applied: Double
        /// Source seconds the compiled ease consumes on each side of the
        /// boundary — where the ramp really begins and ends on the source
        /// axis. Anything that wants to sit exactly at the ramp's edge (the
        /// guided builder's arrival keys) reads these rather than guessing
        /// from the steady-speed map.
        var sourceBefore: Double = 0
        var sourceAfter: Double = 0
        var isClamped: Bool { applied < requested - 0.01 }
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
        /// Output frames landing in each stretch (mid-window source time
        /// bucketed against the warp bounds) — the real per-stretch shares of
        /// the clip, eases and quantization included.
        var stretchFrames: [Int]
        /// Aligned with the warp's seams; nil for seams that never asked for
        /// an ease (step, no side picked, equal speeds).
        var seamEases: [SeamEase?]
        var outputFrames: Int { schedules.reduce(0) { $0 + $1.count } }
    }

    /// A run of source time at one sampled speed. Internal (not private) so
    /// the standalone verification harness can dump the compiled curve.
    struct Piece {
        var start: Double
        var end: Double
        var speed: Double
    }

    /// Constant-speed runs per ease. 32 keeps the speed step between
    /// neighbouring runs under ~35% for a 50×↔¼× sweep — the ease's slow tail
    /// crosses the cut on sharp footage, where a coarser staircase would show.
    static let easeSteps = 32

    private static func smoothstep(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// Ease interpolation in log-speed: perceived speed is multiplicative, so
    /// a 50×→¼× warp should spend equal ease time per halving. A linear blend
    /// crams the whole felt slowdown into the ease's last instants.
    static func easedSpeed(from vA: Double, to vB: Double, at t: Double) -> Double {
        let a = max(0.0001, vA)
        return a * pow(max(0.0001, vB) / a, smoothstep(t))
    }

    /// The piecewise speed curve in the source domain: stretches minus the
    /// spans their eased seams borrow, plus the sampled ease runs. Every ease
    /// STRADDLES its seam, split at the fast side's renderable floor: the part
    /// of the sweep that side's footage can play (down to 1× for base-rate
    /// footage) lands exactly at the boundary, and the sub-floor tail plays
    /// from the slow side's denser footage — the only footage that can. At the
    /// cut both sides render the same real-time cadence, so the speed curve is
    /// continuous on screen by construction. The second value reports what
    /// each requested ease shrank to.
    static func pieces(
        for warp: WarpTimeline,
        regions: [SourceRegion],
        outFps: Double
    ) -> (pieces: [Piece], seamEases: [SeamEase?]) {
        let bounds = warp.bounds
        let speeds = warp.speeds
        var seamEases = [SeamEase?](repeating: nil, count: warp.seams.count)
        guard speeds.count > 0, bounds.count == speeds.count + 1 else { return ([], seamEases) }

        func regionFps(at time: Double) -> Double {
            var cursor = 0.0
            for region in regions {
                cursor += region.span
                if time < cursor - 0.0005 { return max(1, region.fps) }
            }
            return max(1, regions.last?.fps ?? outFps)
        }

        // An output frame must consume at least one source frame, so footage
        // recorded at `fps` cannot play below outFps/fps.
        func floorSpeed(at time: Double) -> Double {
            outFps / regionFps(at: time)
        }

        // Real time the camera lost at this boundary (format switch), when
        // the boundary sits on a region edge. The world moved through it, so
        // an ease crossing here owes that displacement.
        func gapAt(boundary: Double) -> Double {
            var cursor = 0.0
            for region in regions {
                if abs(boundary - cursor) < 0.02 { return max(0, region.leadingGap) }
                cursor += region.span
            }
            return 0
        }

        // How much of each stretch the eases at its two ends consume.
        var headCost = [Double](repeating: 0, count: speeds.count)
        var tailCost = [Double](repeating: 0, count: speeds.count)
        struct EaseRun { var seamIndex: Int; var beforeRuns: [Piece]; var afterRuns: [Piece] }
        var eases: [EaseRun] = []

        for (index, seam) in warp.seams.enumerated() {
            let duration = seam.ramp.seconds
            guard duration > 0 else { continue }
            let boundary = bounds[index + 1]
            let vA = speeds[index], vB = speeds[index + 1]
            guard abs(vA - vB) > 0.0001 else { continue }

            let decel = vA > vB
            let fastFloor = decel
                ? floorSpeed(at: boundary - 0.001)
                : floorSpeed(at: boundary + 0.001)
            // A recording gap at the boundary forces the sweep to cross while
            // per-frame displacement still exceeds the hole: half the hole
            // rides on each boundary frame, so the crossing speed must cover
            // its half plus real footage, with margin for the gap estimate.
            let gap = gapAt(boundary: boundary)
            let gapSplit = gap > 0 ? (gap / 2) * outFps * 1.3 + 1.0 : 0
            let split = min(max(max(fastFloor, gapSplit), min(vA, vB)), max(vA, vB))

            // 32 constant-speed runs sweeping vA→vB; the prefix on vA's side
            // of the split plays before the boundary, the rest after. At a
            // gapped boundary the two runs touching the cut are replaced by
            // EXACT one-output-frame runs: each keeps the sweep's crossing
            // displacement (half the hole plus real footage) but consumes
            // only the footage part — the hole does the rest of the travel.
            let sweepSpeeds = (0..<easeSteps).map { step -> Double in
                let t = (Double(step) + 0.5) / Double(easeSteps)
                return easedSpeed(from: vA, to: vB, at: t)
            }
            let beforeCount = sweepSpeeds.prefix { decel ? $0 >= split : $0 <= split }.count
            struct EaseSample { var speed: Double; var width: Double }
            func runs(_ dur: Double) -> [EaseSample] {
                var samples = sweepSpeeds.map {
                    EaseSample(speed: $0, width: $0 * dur / Double(easeSteps))
                }
                if gap > 0 {
                    let crossDisplacement = split / outFps
                    if beforeCount > 0 {
                        let fpsA = regionFps(at: boundary - 0.001)
                        let frames = max(1, ((crossDisplacement - gap / 2) * fpsA).rounded())
                        samples[beforeCount - 1] =
                            EaseSample(speed: frames * outFps / fpsA, width: frames / fpsA)
                    }
                    if beforeCount < easeSteps {
                        let fpsB = regionFps(at: boundary + 0.001)
                        let frames = max(1, ((crossDisplacement - gap / 2) * fpsB).rounded())
                        samples[beforeCount] =
                            EaseSample(speed: frames * outFps / fpsB, width: frames / fpsB)
                    }
                }
                return samples
            }
            func costs(_ dur: Double) -> (before: Double, after: Double) {
                let widths = runs(dur).map(\.width)
                return (
                    widths.prefix(beforeCount).reduce(0, +),
                    widths.dropFirst(beforeCount).reduce(0, +))
            }

            // Each side pays only for the part of the sweep it hosts, out of
            // what its stretch still has (90%, leaving a sliver of steady
            // speed; a stretch eased at BOTH ends offers each seam half, so
            // the first seam compiled can't starve the second). The requested
            // duration shrinks to the tighter budget.
            func allowance(_ stretch: Int) -> Double {
                let span = bounds[stretch + 1] - bounds[stretch]
                let leftEased = stretch > 0 && warp.seams[stretch - 1].ramp != .step
                let rightEased = stretch < warp.seams.count && warp.seams[stretch].ramp != .step
                // Both ends eased: each seam owns half the budget, and the
                // other seam's borrowings live in its own half.
                if leftEased && rightEased { return span * 0.45 }
                return span * 0.9 - headCost[stretch] - tailCost[stretch]
            }
            let availBefore = max(0, allowance(index))
            let availAfter = max(0, allowance(index + 1))
            var dur = duration
            var (costBefore, costAfter) = costs(dur)
            var scale = 1.0
            if costBefore > availBefore, costBefore > 0 { scale = min(scale, availBefore / costBefore) }
            if costAfter > availAfter, costAfter > 0 { scale = min(scale, availAfter / costAfter) }
            if scale < 1 {
                dur = duration * scale
                (costBefore, costAfter) = costs(dur)
            }
            // An ease squeezed below a few output frames reads as a step —
            // skip it rather than emit sub-frame runs.
            guard dur > 0.05 else {
                seamEases[index] = SeamEase(requested: duration, applied: 0)
                continue
            }
            seamEases[index] = SeamEase(
                requested: duration, applied: dur,
                sourceBefore: costBefore, sourceAfter: costAfter)

            var beforeRuns: [Piece] = []
            var afterRuns: [Piece] = []
            var cursor = boundary - costBefore
            for (step, sample) in runs(dur).enumerated() {
                let run = Piece(start: cursor, end: cursor + sample.width, speed: sample.speed)
                if step < beforeCount { beforeRuns.append(run) } else { afterRuns.append(run) }
                cursor += sample.width
            }
            tailCost[index] += costBefore
            headCost[index + 1] += costAfter
            eases.append(EaseRun(seamIndex: index, beforeRuns: beforeRuns, afterRuns: afterRuns))
        }

        // Assemble: each stretch's steady middle, with ease runs replacing the
        // borrowed ends.
        var result: [Piece] = []
        for stretch in 0..<speeds.count {
            let start = bounds[stretch] + headCost[stretch]
            let end = bounds[stretch + 1] - tailCost[stretch]
            for ease in eases where ease.seamIndex + 1 == stretch {
                result.append(contentsOf: ease.afterRuns)
            }
            if end > start {
                result.append(Piece(start: start, end: end, speed: speeds[stretch]))
            }
            for ease in eases where ease.seamIndex == stretch {
                result.append(contentsOf: ease.beforeRuns)
            }
        }
        return (result.sorted { $0.start < $1.start }, seamEases)
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
        let (pieces, seamEases) = pieces(for: warp, regions: regions, outFps: outFps)
        let limit = min(activeEnd ?? warp.sourceSeconds, warp.sourceSeconds)
        guard !pieces.isEmpty, !regions.isEmpty, limit > activeStart else {
            return Compiled(
                schedules: regions.map { _ in [] },
                frameSourceTimes: regions.map { _ in [] },
                outputSeconds: 0,
                stretchFrames: [Int](repeating: 0, count: warp.stretchCount),
                seamEases: seamEases)
        }

        var schedules: [[Int]] = []
        var frameTimes: [[Double]] = []
        var stretchFrames = [Int](repeating: 0, count: warp.stretchCount)
        var regionStart = 0.0
        var pointer = 0
        for region in regions {
            let fps = max(1, region.fps)
            let regionEnd = regionStart + region.span
            var windows: [Int] = []
            var times: [Double] = []
            var cursor = max(regionStart, activeStart)
            let end = min(regionEnd, limit)
            // Fractional source frames owed between output frames — keeps
            // Σ windows equal to the source frames actually walked.
            var frameCarry = 0.0
            // A region start rewinds the pointer: pieces can straddle a file
            // boundary, and the runs that begin exactly at it must not be
            // skipped by the previous region's walk.
            while pointer > 0, pieces[pointer].start > cursor + 0.0001 { pointer -= 1 }
            // Output-time integration: each output frame consumes exactly
            // 1/outFps of OUTPUT time through the piece curve — short ease
            // runs merge into one window, long steady pieces split into many
            // — so per-frame displacement follows the planned sweep exactly,
            // with no per-piece rounding artifacts beside a seam.
            // Output time from `from` to the region end, capped — cheap peek
            // to decide whether the leftover is a runt worth absorbing.
            func remainingOutput(from: Double, pointer p: Int, cap: Double) -> Double {
                var total = 0.0
                var position = from
                var q = p
                while position < end - 0.0005, total < cap {
                    while q < pieces.count - 1, position >= pieces[q].end - 0.0005 { q += 1 }
                    let pieceEnd = q == pieces.count - 1 ? end : min(pieces[q].end, end)
                    guard pieceEnd > position + 1e-9 else { break }
                    let v = max(pieces[q].speed, outFps / fps)
                    total += (pieceEnd - position) / v
                    position = pieceEnd
                }
                return total
            }
            while cursor < end - 0.0005 {
                let frameStart = cursor
                var budget = 1.0 / outFps
                // A region must end on a whole output frame — a leftover
                // shorter than half a frame would render as a runt with a
                // fraction of the local displacement, a visible stutter right
                // at the file cut. Absorb it into this frame instead.
                if remainingOutput(from: cursor, pointer: pointer, cap: 1.6 / outFps) < 1.5 / outFps {
                    budget = 1.6 / outFps
                }
                while budget > 1e-9, cursor < end - 0.0005 {
                    while pointer < pieces.count - 1, cursor >= pieces[pointer].end - 0.0005 {
                        pointer += 1
                    }
                    let piece = pieces[pointer]
                    // The last piece owns everything to the region end —
                    // matching the old behaviour for footage past the
                    // timeline's bounds.
                    let pieceEnd = pointer == pieces.count - 1 ? end : min(piece.end, end)
                    guard pieceEnd > cursor + 1e-9 else { break }
                    let v = max(piece.speed, outFps / fps)
                    let take = min(budget, (pieceEnd - cursor) / v)
                    cursor += take * v
                    budget -= take
                }
                let sourceThisFrame = cursor - frameStart
                guard sourceThisFrame > 0 else { break }
                let exact = sourceThisFrame * fps + frameCarry
                var window = Int(exact.rounded())
                frameCarry = exact - Double(window)
                if window < 1 {
                    window = 1
                    frameCarry -= 1
                }
                windows.append(window)
                let mid = frameStart + sourceThisFrame / 2
                times.append(mid)
                stretchFrames[warp.stretchIndex(at: mid)] += 1
            }
            schedules.append(windows)
            frameTimes.append(times)
            regionStart = regionEnd
        }
        let frames = schedules.reduce(0) { $0 + $1.count }
        return Compiled(
            schedules: schedules,
            frameSourceTimes: frameTimes,
            outputSeconds: Double(frames) / outFps,
            stretchFrames: stretchFrames,
            seamEases: seamEases)
    }
}
