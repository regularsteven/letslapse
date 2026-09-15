import XCTest
@testable import LetsLapseKit

/// The import reading (docs/import-classification.md §3): a shoot is a clean
/// set, and every other shape a card takes is a warning that names its
/// files. The shapes are `tools/import-classify/cases.py`'s, timed off the
/// 3.62 s Sony run that folder was calibrated on.
final class ImportReadingTests: XCTestCase {

    typealias Reading = ImportedStills.Reading

    // MARK: - Fixtures

    /// `prefix0001.ext, prefix0002.ext…` at `start`, spaced by `gaps`.
    private func sequence(
        _ prefix: String, from number: Int, gaps: [Double], startingAt t0: Double,
        ext: String = "ARW", subsecond: Bool = true
    ) -> (names: [String], times: [Double?]) {
        var names: [String] = []
        var times: [Double?] = []
        var t = t0
        for (index, gap) in ([0.0] + gaps).enumerated() {
            t += gap
            names.append(String(format: "%@%04d.%@", prefix, number + index, ext))
            times.append(t)
        }
        _ = subsecond
        return (names, times)
    }

    private func read(
        _ names: [String], _ times: [Double?], subsecond: Bool = true, synthetic: Set<String> = []
    ) -> Reading {
        let frames = zip(names, times).map { name, time in
            ImportedStills.Frame(
                url: URL(fileURLWithPath: "/card/\(name)"),
                capturedAt: time.map { Date(timeIntervalSince1970: $0) },
                captureTimeSource: time == nil ? nil : (subsecond ? .exifSubsecond : .exif))
        }
        return ImportedStills.reading(for: ImportedStills.Sequence(frames: frames), syntheticNames: synthetic)
    }

    /// A deterministic stand-in for `random.uniform`, so the irregular sets
    /// are the same every run.
    private struct Noise {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * next() }
    }

    private let t0 = 1_788_200_967.2
    private var charles: (names: [String], times: [Double?]) {
        sequence("_WEX", from: 3517, gaps: Array(repeating: 3.62, count: 305), startingAt: t0)
    }
    private var tram: (names: [String], times: [Double?]) {
        sequence("frame-", from: 1, gaps: Array(repeating: 1.0, count: 5029), startingAt: t0, ext: "jpg")
    }

    private func beatStrangers(_ reading: Reading) -> [String]? {
        for case .strangersByBeat(let names) in reading.warnings { return names }
        return nil
    }

    private func nameStrangers(_ reading: Reading) -> [String]? {
        for case .strangersByName(let names) in reading.warnings { return names }
        return nil
    }

    // MARK: - Clean sets are shoots

    func testCleanRunIsAShoot() {
        let reading = read(charles.names, charles.times)
        XCTAssertEqual(reading.suggested, .shoot)
        XCTAssertEqual(reading.beatSeconds ?? 0, 3.62, accuracy: 0.01)
        XCTAssertEqual(reading.pauses, 0)
        XCTAssertEqual(reading.runFrames, 306)
        XCTAssertTrue(reading.warnings.isEmpty)
    }

    func testFiveThousandFramesAtOneSecond() {
        let reading = read(tram.names, tram.times)
        XCTAssertEqual(reading.suggested, .shoot)
        XCTAssertEqual(reading.beatSeconds ?? 0, 1.0, accuracy: 0.01)
    }

    /// A Holy Grail ramp lengthens the interval as the shutter lengthens —
    /// 1.0 → 4.5 s over 5000 frames — and stays one run because the beat's
    /// reference is the run's own recent gaps.
    func testRampedIntervalIsOneRun() {
        var noise = Noise()
        let gaps = (0..<4999).map { 1.0 * pow(1.0003, Double($0)) * noise.uniform(0.98, 1.02) }
        let set = sequence("frame-", from: 1, gaps: gaps, startingAt: t0, ext: "jpg")
        let reading = read(set.names, set.times)
        XCTAssertEqual(reading.suggested, .shoot)
        XCTAssertEqual(reading.pauses, 0)
    }

    func testAPauseWithTheBeatContinuingIsStillOneShoot() {
        for hole in [600.0, 3 * 86400.0] {
            let times = charles.times.enumerated().map { index, time in index >= 150 ? time! + hole : time! }
            let reading = read(charles.names, times)
            XCTAssertEqual(reading.suggested, .shoot, "hole \(hole)")
            XCTAssertEqual(reading.pauses, 1, "hole \(hole)")
        }
    }

    func testFramesDeletedOnTheCardArePauses() {
        let keep = (0..<306).filter { ![50, 51, 120, 200].contains($0) }
        let reading = read(keep.map { charles.names[$0] }, keep.map { charles.times[$0] })
        XCTAssertEqual(reading.suggested, .shoot)
        XCTAssertEqual(reading.pauses, 3)
    }

    /// Whole-second stamps quantise a 1.2 s beat into 1, 1, 1, 2, 1… — the
    /// tolerance floor follows the clock's precision, and the same set read
    /// with the sub-second floor would shatter into photos.
    func testWholeSecondStampsAtAFastBeat() {
        var t = t0
        var times: [Double?] = []
        for _ in 0..<300 { times.append(floor(t)); t += 1.2 }
        let names = (1...300).map { String(format: "_DSC%04d.ARW", $0) }
        XCTAssertEqual(read(names, times, subsecond: false).suggested, .shoot)
        XCTAssertEqual(read(names, times, subsecond: true).suggested, .photos)
        // The wider floor still keeps test shots out.
        let tests = sequence("_DSC", from: 1, gaps: [40, 55, 32, 61, 45], startingAt: floor(t0) - 263)
        let run = (7...306).map { String(format: "_DSC%04d.ARW", $0) }
        let reading = read(tests.names + run, tests.times + times, subsecond: false)
        XCTAssertNil(reading.suggested)
        XCTAssertEqual(beatStrangers(reading), tests.names)
    }

    /// `IMG_20260831_172450`-style names step by the interval, not by one.
    func testTimestampNamedFramesAreASequence() {
        var names: [String] = []
        var times: [Double?] = []
        var t = t0
        for index in 0..<200 {
            names.append("IMG_2026083117\(2450 + 3 * index).jpg")
            times.append(t)
            t += 3
        }
        XCTAssertEqual(read(names, times).suggested, .shoot)
    }

    // MARK: - Strangers ask, and are named

    /// Steven's case: a few frames 30–60 s apart to set exposure, framing and
    /// focus, then the run. They share the stem and the numbering; only the
    /// clock tells them from the run.
    func testTestShotsBeforeTheRunAreNamed() {
        let tests = sequence("_WEX", from: 3511, gaps: [40, 55, 32, 61, 45], startingAt: t0 - 263)
        let reading = read(tests.names + charles.names, tests.times + charles.times)
        XCTAssertNil(reading.suggested)
        XCTAssertEqual(beatStrangers(reading), tests.names)
        XCTAssertEqual(reading.beatSeconds ?? 0, 3.62, accuracy: 0.01)
        XCTAssertNil(reading.afterCleanup, "strangers by beat are not a folder-tidy the sheet can promise")
    }

    /// Test shots that happen to be evenly spaced among themselves are still
    /// not the run.
    func testRegularTestShotsAreStillStrangers() {
        let tests = sequence("_WEX", from: 3512, gaps: [40, 42, 41, 43], startingAt: t0 - 200)
        let reading = read(tests.names + charles.names, tests.times + charles.times)
        XCTAssertNil(reading.suggested)
        XCTAssertEqual(beatStrangers(reading), tests.names)
    }

    /// `_WEX3518-Rendered.dng`: a Lightroom render beside its raw, same
    /// capture time to the millisecond. Not dropped — named, with what the
    /// folder becomes without it.
    func testRenderedDerivativeIsAStrangerByName() {
        var names = charles.names
        var times = charles.times
        names.insert("_WEX3518-Rendered.dng", at: 1)
        times.insert(times[1], at: 1)
        let reading = read(names, times)
        XCTAssertNil(reading.suggested)
        XCTAssertEqual(nameStrangers(reading), ["_WEX3518-Rendered.dng"])
        XCTAssertNil(beatStrangers(reading), "the clock is read on the files that pass the name test")
        XCTAssertEqual(reading.afterCleanup, .shoot)
    }

    func testStrayFileInAShootFolder() {
        let reading = read(tram.names + ["cover.jpg"], tram.times + [tram.times.last!! + 3600])
        XCTAssertNil(reading.suggested)
        XCTAssertEqual(nameStrangers(reading), ["cover.jpg"])
        XCTAssertEqual(reading.afterCleanup, .shoot)
    }

    func testSnapTakenMidRunIsAStranger() {
        let names = (0..<307).map { String(format: "_WEX%04d.ARW", 3517 + $0) }
        let times = Array(charles.times[..<150]) + [charles.times[149]! + 100]
            + charles.times[150...].map { $0! + 300 }
        let reading = read(names, times)
        XCTAssertNil(reading.suggested)
        XCTAssertEqual(beatStrangers(reading), ["_WEX3667.ARW"])
    }

    /// A card of snaps that ends with a shoot, same stem throughout.
    func testMixedCardNamesTheSnaps() {
        var noise = Noise()
        let snaps = sequence("_WEX", from: 3477, gaps: (0..<39).map { _ in noise.uniform(30, 1800) }, startingAt: t0 - 40000)
        let reading = read(snaps.names + charles.names, snaps.times + charles.times)
        XCTAssertNil(reading.suggested)
        XCTAssertEqual(beatStrangers(reading)?.count, 40)
        XCTAssertEqual(reading.runFrames, 306)
    }

    func testFramesWithoutTimesAreStrangersByClock() {
        var times = charles.times
        times[100] = nil; times[101] = nil; times[102] = nil
        let reading = read(charles.names, times)
        XCTAssertNil(reading.suggested)
        var clock: [String]?
        for case .strangersByClock(let names) in reading.warnings { clock = names }
        XCTAssertEqual(clock, ["_WEX3617.ARW", "_WEX3618.ARW", "_WEX3619.ARW"])
    }

    // MARK: - Clean sets whose kind is in doubt

    func testTwoShootsInOneFolder() {
        let second = sequence("_WEX", from: 3823, gaps: Array(repeating: 10, count: 199), startingAt: charles.times.last!! + 7200)
        let reading = read(charles.names + second.names, charles.times + second.times)
        XCTAssertNil(reading.suggested)
        guard case .beatChange(let at, let from, let to)? = reading.warnings.first else {
            return XCTFail("expected a beat change, got \(reading.warnings)")
        }
        XCTAssertEqual(at, "_WEX3823.ARW")
        XCTAssertEqual(from, 3.62, accuracy: 0.01)
        XCTAssertEqual(to, 10, accuracy: 0.01)
    }

    func testIntervalChangedMidRun() {
        // `_WEX3716` is the last frame at 3.62 s; `_WEX3717` the first at 10 s.
        let second = sequence("_WEX", from: 3716, gaps: Array(repeating: 10, count: 105), startingAt: charles.times[199]!)
        let reading = read(
            Array(charles.names[..<200]) + second.names.dropFirst(),
            Array(charles.times[..<200]) + second.times.dropFirst())
        XCTAssertNil(reading.suggested)
        guard case .beatChange(let at, _, _)? = reading.warnings.first else {
            return XCTFail("expected a beat change, got \(reading.warnings)")
        }
        XCTAssertEqual(at, "_WEX3717.ARW")
    }

    func testSlowBeatsAsk() {
        for (beat, count) in [(120.0, 299), (900.0, 99)] {
            let set = sequence("_WEX", from: 1, gaps: Array(repeating: beat, count: count), startingAt: t0)
            let reading = read(set.names, set.times)
            XCTAssertNil(reading.suggested)
            XCTAssertEqual(reading.warnings, [.slow(beat: beat)])
        }
    }

    func testShortCleanSequenceAsks() {
        let reading = read(Array(charles.names[..<12]), Array(charles.times[..<12]))
        XCTAssertNil(reading.suggested)
        XCTAssertEqual(reading.warnings, [.short(count: 12)])
    }

    func testRawPlusJPEGPairsAsk() {
        let names = charles.names.flatMap { [$0, $0.replacingOccurrences(of: ".ARW", with: ".JPG")] }
        let times = charles.times.flatMap { [$0, $0] }
        let reading = read(names, times)
        XCTAssertNil(reading.suggested)
        XCTAssertEqual(reading.warnings, [.pairs(perExposure: 2)])
    }

    func testNumberedFramesWithoutAnyClock() {
        let reading = read(Array(tram.names[..<500]), Array(repeating: nil, count: 500))
        XCTAssertNil(reading.suggested)
        XCTAssertEqual(reading.warnings, [.noClock])
    }

    /// A file's modification date is not a clock: a plain `cp` stamps files
    /// seconds apart in copy order and would manufacture a perfect beat.
    func testFileDatesDoNotCount() {
        let frames = tram.names.prefix(500).enumerated().map { index, name in
            ImportedStills.Frame(
                url: URL(fileURLWithPath: "/card/\(name)"),
                capturedAt: Date(timeIntervalSince1970: t0 + Double(index) * 0.2),
                captureTimeSource: .fileModification)
        }
        let reading = ImportedStills.reading(for: ImportedStills.Sequence(frames: frames))
        XCTAssertNil(reading.suggested)
        XCTAssertEqual(reading.warnings, [.noClock])
    }

    /// The library path invents `photo-0001…` when the camera's name is
    /// lost; invented names are no sequence and no strangers either.
    func testSyntheticNamesSayNothing() {
        let names = (1...306).map { String(format: "photo-%04d.jpg", $0) }
        let reading = read(names, charles.times, synthetic: Set(names))
        XCTAssertNil(reading.suggested)
        XCTAssertEqual(reading.warnings, [.namesUnknown])
        XCTAssertFalse(reading.isNameSequence)
    }

    /// The camera's counter rolled over 9999 → 0001 mid-run: one stem, one
    /// beat, one descending step. Not a silent shoot — the names are the
    /// doubt, and the sheet says so.
    func testCounterRolloverAsksAboutTheNames() {
        let names = (0..<306).map { index -> String in
            let number = 9900 + index
            return String(format: "_DSC%04d.ARW", number > 9999 ? number - 9999 : number)
        }
        let reading = read(names, charles.times)
        XCTAssertNil(reading.suggested)
        guard case .irregularNames(let patterns)? = reading.warnings.first else {
            return XCTFail("expected irregular names, got \(reading.warnings)")
        }
        XCTAssertEqual(patterns, ["_DSC#"])
        XCTAssertEqual(reading.runFrames, 306)
    }

    /// Two cameras' cards merged: the second stem is strangers by the rule,
    /// not a naming doubt.
    func testSecondStemIsStrangers() {
        let names = charles.names.enumerated().map { index, name in
            index.isMultiple(of: 2) ? name : name.replacingOccurrences(of: "_WEX", with: "DSC")
        }
        let reading = read(names, charles.times)
        XCTAssertNil(reading.suggested)
        XCTAssertEqual(nameStrangers(reading)?.count, 153)
    }

    // MARK: - Photos

    func testHolidayFoldersArePhotos() {
        var noise = Noise()
        let snaps = sequence("IMG_", from: 1, gaps: (0..<399).map { _ in noise.uniform(5, 3600) }, startingAt: t0, ext: "JPG")
        let reading = read(snaps.names, snaps.times)
        XCTAssertEqual(reading.suggested, .photos)
        XCTAssertTrue(reading.warnings.isEmpty)
        XCTAssertEqual(reading.runFrames, 0)
    }

    /// A continuous-drive burst is not a timelapse.
    func testBurstInsideSnapsIsPhotos() {
        var noise = Noise()
        let gaps = (0..<20).map { _ in noise.uniform(20, 900) } + Array(repeating: 0.1, count: 9)
            + (0..<30).map { _ in noise.uniform(20, 900) }
        let set = sequence("DSC0", from: 100, gaps: gaps, startingAt: t0)
        XCTAssertEqual(read(set.names, set.times).suggested, .photos)
    }

    func testTooFewFilesArePhotos() {
        XCTAssertEqual(read(Array(charles.names[..<3]), Array(charles.times[..<3])).suggested, .photos)
        let one = read([charles.names[0]], [charles.times[0]])
        XCTAssertEqual(one.suggested, .photos)
        XCTAssertEqual(one.count, 1)
    }

    // MARK: - Names

    func testStemAndTail() {
        XCTAssertEqual(ImportedStills.stemAndTail("_WEX3518-Rendered.dng").stem, "_WEX#-Rendered")
        XCTAssertEqual(ImportedStills.stemAndTail("_WEX3518-Rendered.dng").tail, 3518)
        XCTAssertEqual(ImportedStills.stemAndTail("China Pics-.jpg").stem, "China Pics-")
        XCTAssertNil(ImportedStills.stemAndTail("China Pics-.jpg").tail)
        XCTAssertEqual(ImportedStills.stemAndTail("IMG_20260831_172450.jpg").stem, "IMG_20260831_#")
        XCTAssertEqual(ImportedStills.stemAndTail("IMG_20260831_172450.jpg").tail, 172450)
        XCTAssertEqual(ImportedStills.stemAndTail("frame-00001.jpg").stem, "frame-#")
        XCTAssertEqual(ImportedStills.stemAndTail("frame-00001.jpg").tail, 1)
    }

    /// A Lightroom export of picks keeps the camera's numbers with gaps
    /// between them — not a sequence, and every file its own photo.
    func testCherryPickedExportIsNotASequence() {
        let numbers = [1064, 1066, 1076, 1083, 1085, 1086, 1091, 1099, 1104, 1111, 1112, 1120]
        let naming = ImportedStills.nameSequence(numbers.map { "China Pics-\($0).jpg" } + ["China Pics-.jpg"])
        XCTAssertFalse(naming.isSequence)
        XCTAssertEqual(naming.strangers, ["China Pics-.jpg"])
        XCTAssertEqual(naming.patterns.first, "China Pics-#")
    }

    func testStrangersAreDuplicateNumbersAmongSingles() {
        let naming = ImportedStills.nameSequence(["a0001.ARW", "a0002.ARW", "a0002.JPG", "a0003.ARW", "a0004.ARW", "a0005.ARW"])
        XCTAssertTrue(naming.isSequence)
        XCTAssertNil(naming.pairsPerExposure)
        XCTAssertEqual(naming.strangers, ["a0002.ARW", "a0002.JPG"])
    }
}
