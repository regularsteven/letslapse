import Foundation

/// Reading an imported set for the import sheet: is this a shoot, or a pile
/// of photos, and if the files can't say, why not.
///
/// The rule (docs/import-classification.md §3): **a shoot is a clean set** —
/// one name sequence in which every frame sits on one beat, the only
/// irregularity a pause whose beat continues on the far side. Anything less
/// is not a shoot the app will suggest; it is a warning the sheet shows,
/// naming the files. *Photos* — one project per file — is suggested only when
/// no beat exists anywhere in the set. In between, the sheet pre-selects
/// nothing and the person decides with the reading in front of them.
///
/// Why "every frame": a real shoot starts with a few test frames 30–60 s
/// apart — exposure, framing, focus — and then the run. They share the stem
/// and the numbering; nothing but the clock tells them from the run, and a
/// rule that tolerates "90 % on the beat" imports them as frames 1–6 of the
/// timelapse. Likewise a Lightroom render sitting beside its raw
/// (`_WEX3518-Rendered.dng`) is not a frame the app may quietly drop — it is
/// a folder that needs tidying, and the sheet says so.
///
/// `tools/import-classify/classify.py` is the reference this mirrors and
/// `cases.py` the fixtures; `ImportReadingTests` carries the same shapes.
extension ImportedStills {

    public struct Reading: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            /// One project, every file a frame — `Interval · Imported`.
            case shoot
            /// One project per file — `Photo · Imported`.
            case photos
        }

        public enum Warning: Equatable, Sendable {
            /// Files outside the set's stem, unnumbered, or numbered twice
            /// among singles: `cover.jpg`, `_WEX3518-Rendered.dng`.
            case strangersByName([String])
            /// Files with no camera-written capture time.
            case strangersByClock([String])
            /// Files off the beat: test shots before the run, a snap taken
            /// mid-run, the odd frame whose neighbours disagree with it.
            case strangersByBeat([String])
            /// Every number appears `perExposure` times — RAW+JPEG.
            case pairs(perExposure: Int)
            /// Two runs whose beats differ, joined at `atName`.
            case beatChange(atName: String, from: Double, to: Double)
            /// One clean beat, slower than a shoot is recognised at.
            case slow(beat: Double)
            /// One clean beat, fewer frames than a shoot is recognised at.
            case short(count: Int)
            /// A name sequence whose files carry no capture times at all.
            case noClock
            /// The names don't run in sequence (their stem patterns, most
            /// common first) although the frames keep a beat.
            case irregularNames(patterns: [String])
            /// The importer invented the names (a library pick that lost
            /// the camera's), and the frames keep a beat.
            case namesUnknown
        }

        /// The row the sheet pre-selects: `.shoot` for a clean run at or
        /// under `Reading.beatCap`, `.photos` when no beat exists, nil when
        /// the files disagree with each other.
        public var suggested: Kind?
        public var count: Int
        public var isNameSequence: Bool
        /// The run's beat — the median gap of the (merged) run.
        public var beatSeconds: Double?
        /// Gaps where the run paused and resumed on the same beat.
        public var pauses: Int
        /// Frames that sit on a run of at least `minimumRun`.
        public var runFrames: Int
        public var warnings: [Warning]
        /// What the set reads as once its strangers by name are gone —
        /// `.shoot` when that would leave one clean run at or under the cap,
        /// so the sheet can say "without these, this folder is a shoot".
        public var afterCleanup: Kind?

        public init(
            suggested: Kind? = nil, count: Int, isNameSequence: Bool = false,
            beatSeconds: Double? = nil, pauses: Int = 0, runFrames: Int = 0,
            warnings: [Warning] = [], afterCleanup: Kind? = nil
        ) {
            self.suggested = suggested
            self.count = count
            self.isNameSequence = isNameSequence
            self.beatSeconds = beatSeconds
            self.pauses = pauses
            self.runFrames = runFrames
            self.warnings = warnings
            self.afterCleanup = afterCleanup
        }

        // MARK: Tunables (docs §3.4, §8)

        /// A gap is on the beat within ±35 % of the run's reference…
        public static let tolerance = 0.35
        /// …or within this, whichever is larger, when the frames carry
        /// sub-second stamps…
        public static let floor = 0.5
        /// …and within this when they carry whole seconds — a 1.2 s beat
        /// quantised to whole seconds reads 1, 1, 1, 2, 1.
        public static let wholeSecondFloor = 1.0
        /// A beat slower than this is a question, not a suggested shoot.
        public static let beatCap = 60.0
        /// The shortest beat that counts as "a shoot is in here" — a
        /// continuous-drive burst of ten is not a timelapse.
        public static let minimumRun = 24
        /// Fewer files than this cannot be a shoot with any confidence.
        public static let minimumFiles = 5
        /// The run's reference is the median of its last this-many gaps,
        /// which is what lets a slowly ramping interval stay one run.
        public static let window = 8

        /// The strangers of every kind, in the order the set was given.
        public var strangerNames: [String] {
            var names: [String] = []
            for warning in warnings {
                switch warning {
                case .strangersByName(let found), .strangersByClock(let found), .strangersByBeat(let found):
                    for name in found where !names.contains(name) { names.append(name) }
                default: break
                }
            }
            return names
        }
    }

    // MARK: - Reading a set

    /// The reading of a probed set.
    ///
    /// `syntheticNames` are file names the importer invented (the Photos
    /// library path stages `photo-0001…` when the library has lost the
    /// camera's name); a set containing any is not a name sequence and lists
    /// no strangers by name — the names simply say nothing.
    public static func reading(for sequence: Sequence, syntheticNames: Set<String> = []) -> Reading {
        let names = sequence.frames.map(\.url.lastPathComponent)
        let count = names.count
        if count == 1 { return Reading(suggested: .photos, count: 1) }
        if count < Reading.minimumFiles { return Reading(suggested: .photos, count: count) }

        // Camera-written times only. A file date is not a clock (§3.2).
        let times: [Double?] = sequence.frames.map { frame in
            switch frame.captureTimeSource {
            case .exif, .exifSubsecond: return frame.capturedAt?.timeIntervalSince1970
            case .fileModification, nil: return nil
            }
        }
        let wholeSeconds = sequence.frames.contains { $0.captureTimeSource == .exif }
        let floor = wholeSeconds ? Reading.wholeSecondFloor : Reading.floor

        let synthetic = names.contains { syntheticNames.contains($0) }
        let naming = synthetic
            ? NameReading(isSequence: false, strangers: [], pairsPerExposure: nil, patterns: [])
            : nameSequence(names)
        let isSeq = naming.isSequence
        let nameStrangers = naming.strangers

        if isSeq, let per = naming.pairsPerExposure, nameStrangers.isEmpty {
            return Reading(suggested: nil, count: count, isNameSequence: true, warnings: [.pairs(perExposure: per)])
        }
        if times.allSatisfy({ $0 == nil }) {
            return isSeq
                ? Reading(suggested: nil, count: count, isNameSequence: true, warnings: [.noClock])
                : Reading(suggested: .photos, count: count, isNameSequence: false)
        }

        // The clock is read on the files that pass the name test — the folder
        // as it would be once tidied — so the sheet can say what it becomes.
        let nameStrangerSet = Set(nameStrangers)
        let clockStrangers = zip(names, times).compactMap { name, time in
            time == nil && !nameStrangerSet.contains(name) ? name : nil
        }
        let indices = times.indices.filter { times[$0] != nil && !nameStrangerSet.contains(names[$0]) }
        let gaps: [Double] = zip(indices, indices.dropFirst()).map { times[$1]! - times[$0]! }
        let allRuns = findRuns(gaps, floor: floor)
        let runs = allRuns.filter { $0.upperBound - $0.lowerBound + 2 >= Reading.minimumRun }   // frames = gaps + 1
        var covered = Set<Int>()
        for run in runs { covered.formUnion(run.lowerBound...(run.upperBound + 1)) }
        let beatStrangers = indices.indices.compactMap { covered.contains($0) ? nil : names[indices[$0]] }

        // Adjacent runs whose beat continues across the join are one run with a
        // pause in it (a battery swap, a deleted frame). A beat that changes is
        // not.
        var merged: [ClosedRange<Int>] = []
        var beats: [(in: Double, out: Double)] = []
        for run in runs {
            let beatIn = median(Array(gaps[run.lowerBound...min(run.upperBound, run.lowerBound + Reading.window - 1)]))
            let beatOut = median(Array(gaps[max(run.lowerBound, run.upperBound - Reading.window + 1)...run.upperBound]))
            if let last = merged.last, last.upperBound + 2 >= run.lowerBound,
               onBeat(beatIn, reference: beats[beats.count - 1].out, floor: floor) {
                merged[merged.count - 1] = last.lowerBound...run.upperBound
                beats[beats.count - 1].out = beatOut
            } else {
                merged.append(run)
                beats.append((beatIn, beatOut))
            }
        }
        var pauses = 0
        for (previous, next) in zip(runs, runs.dropFirst()) where previous.upperBound + 1 < next.lowerBound {
            pauses += 1
        }

        let beat: Double? = merged.first.map { median(Array(gaps[$0])) }
        let tidy = isSeq && clockStrangers.isEmpty && beatStrangers.isEmpty && merged.count == 1
        let afterCleanup: Reading.Kind? = (!nameStrangers.isEmpty && tidy && (beat ?? .infinity) <= Reading.beatCap) ? .shoot : nil
        var reading = Reading(
            count: count, isNameSequence: isSeq, beatSeconds: beat, pauses: pauses,
            runFrames: covered.count, afterCleanup: afterCleanup)

        let clean = tidy && nameStrangers.isEmpty
        if clean, let beat, beat <= Reading.beatCap {
            reading.suggested = .shoot
            return reading
        }
        if clean, let beat {
            reading.warnings = [.slow(beat: beat)]
            return reading
        }
        if runs.isEmpty {
            // A clean short sequence has no run of `minimumRun` but may still
            // be one beat.
            if isSeq, nameStrangers.isEmpty, clockStrangers.isEmpty, gaps.count >= 2, allRuns.count == 1 {
                reading.beatSeconds = median(gaps)
                reading.warnings = [.short(count: count)]
                return reading
            }
            reading.suggested = .photos
            return reading
        }
        if isSeq, nameStrangers.isEmpty, clockStrangers.isEmpty, beatStrangers.isEmpty, merged.count > 1 {
            // The first frame at the new beat: after a pause, the frame the
            // second run's first gap starts from; with no pause the two runs
            // share that frame, so it is the one after.
            let second = merged[1]
            let shared = merged[0].upperBound + 1 == second.lowerBound
            let at = indices[min(second.lowerBound + (shared ? 1 : 0), indices.count - 1)]
            reading.warnings = [.beatChange(atName: names[at], from: beats[0].out, to: beats[1].in)]
            return reading
        }
        var warnings: [Reading.Warning] = []
        if !nameStrangers.isEmpty { warnings.append(.strangersByName(nameStrangers)) }
        if !clockStrangers.isEmpty { warnings.append(.strangersByClock(clockStrangers)) }
        if !beatStrangers.isEmpty { warnings.append(.strangersByBeat(beatStrangers)) }
        if warnings.isEmpty {
            // Not a name sequence, yet the clock found a run and nothing
            // else is wrong — the names are the only doubt.
            warnings.append(synthetic ? .namesUnknown : .irregularNames(patterns: Array(naming.patterns.prefix(4))))
        }
        reading.warnings = warnings
        return reading
    }

    // MARK: - Names

    struct NameReading: Equatable {
        var isSequence: Bool
        var strangers: [String]
        var pairsPerExposure: Int?
        /// The stem patterns present, most common first.
        var patterns: [String]
    }

    /// `_WEX3518-Rendered.dng` → (`_WEX#-Rendered`, 3518): the stem with its
    /// LAST run of digits replaced by `#`, and that number.
    static func stemAndTail(_ name: String) -> (stem: String, tail: Int?) {
        let stem = (name as NSString).deletingPathExtension
        let scalars = Array(stem)
        var end = scalars.count
        while end > 0, !scalars[end - 1].isNumber { end -= 1 }
        guard end > 0 else { return (stem, nil) }
        var start = end
        while start > 0, scalars[start - 1].isNumber { start -= 1 }
        let digits = String(scalars[start..<end])
        let pattern = String(scalars[..<start]) + "#" + String(scalars[end...])
        return (pattern, Int(digits) ?? Int(digits.suffix(18)))
    }

    /// A sequence: one stem pattern holds ≥ 95 % of the files, its numbers
    /// ascend, and ≥ 90 % of the steps equal the most common step — not "+1",
    /// because frames named by timestamp step by the interval and a card with
    /// a few deletions steps 2 here and there. Strangers: every file outside
    /// the dominant stem, unnumbered, or numbered twice among singles. Pairs:
    /// every number the same k > 1 times.
    static func nameSequence(_ names: [String]) -> NameReading {
        let parsed = names.map(stemAndTail)
        var stemCounts: [String: Int] = [:]
        var stemOrder: [String] = []
        for (stem, _) in parsed {
            if stemCounts[stem] == nil { stemOrder.append(stem) }
            stemCounts[stem, default: 0] += 1
        }
        // Most common first; among equals, first seen — the reference's order.
        let patterns = stemOrder.enumerated().sorted { lhs, rhs in
            let (lc, rc) = (stemCounts[lhs.element]!, stemCounts[rhs.element]!)
            return lc != rc ? lc > rc : lhs.offset < rhs.offset
        }.map(\.element)
        guard let dominantStem = patterns.first else {
            return NameReading(isSequence: false, strangers: names, pairsPerExposure: nil, patterns: [])
        }
        let share = Double(stemCounts[dominantStem]!) / Double(names.count)

        var strangers = zip(names, parsed).compactMap { name, parsedName in
            parsedName.stem != dominantStem || parsedName.tail == nil ? name : nil
        }
        let tails = parsed.compactMap { $0.stem == dominantStem ? $0.tail : nil }
        var tailCounts: [Int: Int] = [:]
        for tail in tails { tailCounts[tail, default: 0] += 1 }
        let duplicates = Set(tailCounts.filter { $0.value > 1 }.keys)
        let pairs = !duplicates.isEmpty && Set(tailCounts.values).count == 1
        if !duplicates.isEmpty, !pairs {
            strangers += zip(names, parsed).compactMap { name, parsedName in
                parsedName.stem == dominantStem && parsedName.tail.map(duplicates.contains) == true ? name : nil
            }
        }
        var seen = Set<Int>()
        let unique = tails.filter { seen.insert($0).inserted }
        let steps = zip(unique, unique.dropFirst()).map { $1 - $0 }
        var stepCounts: [Int: Int] = [:]
        for step in steps { stepCounts[step, default: 0] += 1 }
        let modal = steps.isEmpty ? 0 : Double(stepCounts.values.max() ?? 0) / Double(steps.count)
        let isSequence = share >= 0.95 && steps.allSatisfy { $0 > 0 } && modal >= 0.9

        let strangerSet = Set(strangers)
        var ordered: [String] = []
        var listed = Set<String>()
        for name in names where strangerSet.contains(name) && listed.insert(name).inserted { ordered.append(name) }
        return NameReading(
            isSequence: isSequence, strangers: ordered,
            pairsPerExposure: pairs ? tailCounts.values.first : nil,
            patterns: patterns)
    }

    // MARK: - Beat

    static func onBeat(_ gap: Double, reference: Double, floor: Double) -> Bool {
        abs(gap - reference) <= max(floor, Reading.tolerance * reference)
    }

    /// Maximal stretches of consecutive gaps where each gap is on the beat of
    /// the previous ≤ `window` gaps of the same stretch. Ranges of gap indices.
    static func findRuns(_ gaps: [Double], floor: Double) -> [ClosedRange<Int>] {
        guard !gaps.isEmpty else { return [] }
        var runs: [ClosedRange<Int>] = []
        var start = 0
        for index in 1..<gaps.count {
            let reference = median(Array(gaps[max(start, index - Reading.window)..<index]))
            if !onBeat(gaps[index], reference: reference, floor: floor) {
                runs.append(start...(index - 1))
                start = index
            }
        }
        runs.append(start...(gaps.count - 1))
        return runs
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
