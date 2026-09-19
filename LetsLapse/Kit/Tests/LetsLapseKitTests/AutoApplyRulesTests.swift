import XCTest
@testable import LetsLapseKit

/// The auto-apply rules' promises: the sets the screen offers are the sizes
/// they claim, assigning takes slots from whoever held them and shrinks
/// their rules, a conflict lists only what is taken from OTHERS, the words
/// come out canonical or as a comma list, a finished shoot lands in exactly
/// one slot, and the file tolerates what a newer app might write.
final class AutoApplyRulesTests: XCTestCase {

    private let a = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    private let b = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!
    private let c = UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000003")!

    // MARK: Sets

    func testSlotSetsHaveTheSizesTheScreenClaims() {
        XCTAssertEqual(AutoApplySlot.all.count, 8)
        XCTAssertEqual(AutoApplySlot.slots(in: .photo).count, 3)
        XCTAssertEqual(AutoApplySlot.slots(in: .interval).count, 3)
        XCTAssertEqual(AutoApplySlot.slots(in: .video).count, 2)
        XCTAssertEqual(AutoApplyFilter.all.slots(in: .photo).count, 3)
        XCTAssertEqual(AutoApplyFilter.jpegs.slots(in: .photo).count, 2)
        XCTAssertEqual(AutoApplyFilter.dng.slots(in: .interval), [.intervalDNG])
        XCTAssertEqual(AutoApplyFilter.all.slots(in: .video).count, 2)
        XCTAssertEqual(AutoApplyFilter.flatOn.slots(in: .video), [.videoFlatOn])
        // A video filter asked of a still mode names nothing.
        XCTAssertTrue(AutoApplyFilter.flatOn.slots(in: .photo).isEmpty)
        XCTAssertTrue(AutoApplyFilter.dng.slots(in: .video).isEmpty)
        XCTAssertEqual(AutoApplyFilter.options(for: .photo), [.all, .jpegs, .jpegStandard, .jpegFlat, .dng])
        XCTAssertEqual(AutoApplyFilter.options(for: .video), [.all, .flatOff, .flatOn])
    }

    // MARK: Assigning and shrinking

    func testAssigningTakesSlotsAndShrinksTheOtherPresetsRules() {
        var rules = AutoApplyRules()
        rules.assign(AutoApplyFilter.all.slots(in: .photo), to: a)
        XCTAssertEqual(rules.slots(for: a).count, 3)

        rules.assign([.photoDNG], to: b)
        XCTAssertEqual(rules.owner(of: .photoDNG), b)
        XCTAssertEqual(rules.slots(for: a), [.photoJPEGStandard, .photoJPEGFlat])
        XCTAssertEqual(AutoApplyFilter.canonical(for: rules.slots(for: a), in: .photo), .jpegs)
        XCTAssertEqual(AutoApplyFilter.label(for: rules.slots(for: a), in: .photo), "JPEGs")
    }

    func testEverythingTakesAllEightAndTheSummarySaysSo() {
        var rules = AutoApplyRules()
        rules.assign([.videoFlatOn], to: b)
        rules.assign(AutoApplySlot.all, to: a)
        XCTAssertTrue(rules.ownsEverything(a))
        XCTAssertTrue(rules.slots(for: b).isEmpty)
        XCTAssertEqual(rules.summary(for: a), "Everything – All shoots")
        XCTAssertEqual(rules.summary(for: b), "None")
    }

    func testSummaryJoinsTheModesInTheScreensOrder() {
        var rules = AutoApplyRules()
        rules.assign([.videoFlatOff], to: a)
        XCTAssertEqual(rules.summary(for: a), "Video shoots")
        rules.assign([.photoDNG], to: a)
        XCTAssertEqual(rules.summary(for: a), "Photo & Video shoots")
        rules.assign([.intervalJPEGFlat], to: a)
        XCTAssertEqual(rules.summary(for: a), "Photo, Interval & Video shoots")
        XCTAssertEqual(rules.modes(for: a), [.photo, .interval, .video])
    }

    func testReleaseNarrowsWithoutTouchingAnotherPreset() {
        var rules = AutoApplyRules()
        rules.assign(AutoApplyFilter.all.slots(in: .photo), to: a)
        rules.assign([.intervalDNG], to: b)
        // A's narrowing names B's slot too; B keeps it.
        rules.release([.photoJPEGFlat, .intervalDNG], from: a)
        XCTAssertEqual(rules.slots(for: a), [.photoJPEGStandard, .photoDNG])
        XCTAssertEqual(rules.owner(of: .intervalDNG), b)
        XCTAssertEqual(AutoApplyFilter.label(for: rules.slots(for: a), in: .photo), "JPEG Standard, DNG")
        XCTAssertNil(AutoApplyFilter.canonical(for: rules.slots(for: a), in: .photo))

        rules.release(a)
        XCTAssertTrue(rules.slots(for: a).isEmpty)
        XCTAssertEqual(rules.presetIDs, [b])
    }

    // MARK: Conflicts

    func testConflictsListOnlyWhatIsTakenFromOthers() {
        var rules = AutoApplyRules()
        rules.assign(AutoApplyFilter.all.slots(in: .photo), to: b)
        rules.assign([.videoFlatOn], to: c)
        rules.assign([.intervalDNG], to: a)

        // A takes Photo · DNG: B loses one slot and keeps two; C is untouched.
        let one = rules.conflicts(assigning: [.photoDNG], to: a)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].presetID, b)
        XCTAssertEqual(one[0].slots, [.photoDNG])
        XCTAssertEqual(one[0].remaining, [.photoJPEGStandard, .photoJPEGFlat])

        // A's own slot is never a conflict, nor is a free one.
        XCTAssertTrue(rules.conflicts(assigning: [.intervalDNG, .intervalJPEGFlat], to: a).isEmpty)

        // Everything lists every other owner, Photo before Video.
        let everything = rules.conflicts(assigning: AutoApplySlot.all, to: a)
        XCTAssertEqual(everything.map(\.presetID), [b, c])
        XCTAssertEqual(everything[0].slots.count, 3)
        XCTAssertTrue(everything[0].remaining.isEmpty)
        XCTAssertEqual(everything[1].slots, [.videoFlatOn])
    }

    func testDescribeSpeaksPerModeInOrder() {
        XCTAssertEqual(AutoApplyRules.describe([.photoJPEGFlat]), "Photo shoots · JPEG Flat ON")
        XCTAssertEqual(AutoApplyRules.describe(AutoApplySlot.slots(in: .interval)), "Interval shoots · All")
        XCTAssertEqual(
            AutoApplyRules.describe([.videoFlatOn, .photoJPEGStandard, .photoJPEGFlat]),
            "Photo shoots · JPEGs and Video shoots · Capture Flat ON")
        XCTAssertEqual(AutoApplyRules.describe([]), "")
    }

    // MARK: The slot a shoot lands in

    func testAFinishedShootLandsInExactlyOneSlot() {
        XCTAssertEqual(AutoApplySlot.slot(mode: .photo, dng: false, flat: false), .photoJPEGStandard)
        XCTAssertEqual(AutoApplySlot.slot(mode: .photo, dng: false, flat: true), .photoJPEGFlat)
        XCTAssertEqual(AutoApplySlot.slot(mode: .photo, dng: true, flat: false), .photoDNG)
        // A DNG has no flat variant: dng wins.
        XCTAssertEqual(AutoApplySlot.slot(mode: .photo, dng: true, flat: true), .photoDNG)
        XCTAssertEqual(AutoApplySlot.slot(mode: .interval, dng: false, flat: true), .intervalJPEGFlat)
        XCTAssertEqual(AutoApplySlot.slot(mode: .interval, dng: true, flat: true), .intervalDNG)
        // Video has no format axis.
        XCTAssertEqual(AutoApplySlot.slot(mode: .video, dng: true, flat: false), .videoFlatOff)
        XCTAssertEqual(AutoApplySlot.slot(mode: .video, dng: false, flat: true), .videoFlatOn)
    }

    // MARK: The file

    func testJSONRoundTripsAndTolerantlyReadsWhatItDoesNotKnow() throws {
        var rules = AutoApplyRules()
        rules.assign([.photoDNG, .videoFlatOn], to: a)
        rules.assign([.intervalJPEGStandard], to: b)
        let data = try JSONEncoder().encode(rules)
        XCTAssertEqual(try JSONDecoder().decode(AutoApplyRules.self, from: data), rules)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual((object["owners"] as? [String: String])?["photo.dng"], a.uuidString)

        let newer = """
        {"version": 7, "owners": {"photo.dng": "\(a.uuidString)", "scan.dng": "\(b.uuidString)",
         "video.flatOn": "not a uuid"}, "future": true}
        """
        let read = try JSONDecoder().decode(AutoApplyRules.self, from: Data(newer.utf8))
        XCTAssertEqual(read.owners, [.photoDNG: a])

        XCTAssertTrue(try JSONDecoder().decode(AutoApplyRules.self, from: Data("{}".utf8)).isEmpty)
    }

    func testPruneDropsOwnersNobodyKnows() {
        var rules = AutoApplyRules()
        rules.assign([.photoDNG], to: a)
        rules.assign([.videoFlatOn], to: b)
        let dropped = rules.prune(keeping: [a])
        XCTAssertEqual(dropped, [b])
        XCTAssertEqual(rules.presetIDs, [a])
        XCTAssertTrue(rules.prune(keeping: [a]).isEmpty)
    }
}
