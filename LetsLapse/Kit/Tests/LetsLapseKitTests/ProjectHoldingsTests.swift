import XCTest
@testable import LetsLapseKit

final class ProjectHoldingsTests: XCTestCase {

    private let stack = UUID()
    private let clipA = UUID()
    private let clipB = UUID()

    private func frames(_ count: Int) -> [(name: String, files: [String])] {
        (1 ... count).map { ("source/frame-\($0).dng", ["source/frame-\($0).dng"]) }
    }

    private func recorded(_ names: [String], bytes: Int64) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, bytes) })
    }

    /// A device that shot the project holds everything: originals, every
    /// blend, and nothing is short.
    func testTheCaptureDeviceHoldsEverything() {
        let names = (1 ... 3).map { "source/frame-\($0).dng" }
        var present = recorded(names, bytes: 20)
        present["blends/\(clipA.uuidString).mp4"] = 90
        let holdings = ProjectHoldings(
            originals: frames(3), blends: [(clipA, "blends/\(clipA.uuidString).mp4")],
            pictureBlendID: nil, present: present, recordedBytes: [:], hasPreview: false)
        XCTAssertEqual(holdings.tier, .originals)
        XCTAssertTrue(holdings.hasAllOriginals)
        XCTAssertNil(holdings.shortfall(for: .originals))
        XCTAssertNil(holdings.shortfall(for: .blends([clipA])))
        XCTAssertEqual(holdings.blend(clipA)?.bytes, 90, "a blend here with no record is priced by its file")
    }

    /// A pulled preview: nothing heavy here, the sizes from `assets.ndjson`.
    func testAPulledPreviewIsShortTheOriginalsAtTheirRecordedSize() {
        let names = (1 ... 4).map { "source/frame-\($0).dng" }
        let holdings = ProjectHoldings(
            originals: frames(4), blends: [(clipA, "blends/\(clipA.uuidString).mp4")],
            pictureBlendID: nil, present: ["poster.jpg": 150_000],
            recordedBytes: recorded(names, bytes: 20_000_000).merging(["blends/\(clipA.uuidString).mp4": 90_000_000]) { a, _ in a },
            hasPreview: true)
        XCTAssertEqual(holdings.tier, .preview)
        let short = try! XCTUnwrap(holdings.shortfall(for: .originals))
        XCTAssertEqual(short.originals, names)
        XCTAssertEqual(short.bytes, 80_000_000)
        XCTAssertTrue(short.bytesAreComplete)
        XCTAssertFalse(short.isPartial)
        XCTAssertFalse(short.needsBlends)
        let both = try! XCTUnwrap(holdings.shortfall(for: Need.originals.union(.blends([clipA]))))
        XCTAssertEqual(both.bytes, 170_000_000)
        XCTAssertEqual(both.fileNames.last, "blends/\(clipA.uuidString).mp4")
    }

    /// Free up space removed the originals and kept the blends: the brief's
    /// middle tier — collections work, pixel edits do not.
    func testBlendsKeptWithoutTheOriginalsIsTheBlendsTier() {
        let holdings = ProjectHoldings(
            originals: frames(2),
            blends: [(clipA, "blends/\(clipA.uuidString).mp4"), (clipB, "blends/\(clipB.uuidString).mp4")],
            pictureBlendID: nil, present: ["blends/\(clipA.uuidString).mp4": 90],
            recordedBytes: ["blends/\(clipB.uuidString).mp4": 70], hasPreview: true)
        XCTAssertEqual(holdings.tier, .blends)
        XCTAssertNil(holdings.shortfall(for: .blends([clipA])))
        let short = try! XCTUnwrap(holdings.shortfall(for: .blends([clipA, clipB])))
        XCTAssertEqual(short.blendIDs, [clipB])
        XCTAssertEqual(short.bytes, 70)
        XCTAssertFalse(short.needsOriginals)
        XCTAssertEqual(holdings.blendsHere, 1)
    }

    /// Part of a download landed: the rest is what is short, and the prompt
    /// can say so — twelve files, not the whole shoot.
    func testPartOfTheOriginalsIsStillAShortfallOfTheRest() {
        let names = (1 ... 5).map { "source/frame-\($0).dng" }
        let holdings = ProjectHoldings(
            originals: frames(5), blends: [], pictureBlendID: nil,
            present: recorded(Array(names.prefix(3)), bytes: 10), recordedBytes: recorded(names, bytes: 10),
            hasPreview: true)
        XCTAssertEqual(holdings.tier, .preview)
        let short = try! XCTUnwrap(holdings.shortfall(for: .originals))
        XCTAssertTrue(short.isPartial)
        XCTAssertEqual(short.originals, ["source/frame-4.dng", "source/frame-5.dng"])
        XCTAssertEqual(short.bytes, 20)
        XCTAssertEqual(holdings.originalsHere, 3)
    }

    /// A clip converted to HEVC whose ProRes original went: any encoding
    /// makes the clip here, as it does for playback.
    func testAClipIsHereWhenAnyOfItsEncodingsIs() {
        let clip = (name: "source/clip-1.mov", files: ["source/clip-1.mov", "source/clip-1-hevc.mp4"])
        let here = ProjectHoldings(
            originals: [clip], blends: [], pictureBlendID: nil,
            present: ["source/clip-1-hevc.mp4": 400], recordedBytes: [:], hasPreview: false)
        XCTAssertEqual(here.tier, .originals)
        let gone = ProjectHoldings(
            originals: [clip], blends: [], pictureBlendID: nil, present: [:],
            recordedBytes: ["source/clip-1.mov": 4000, "source/clip-1-hevc.mp4": 400], hasPreview: true)
        let short = try! XCTUnwrap(gone.shortfall(for: .originals))
        XCTAssertEqual(short.fileNames, clip.files)
        XCTAssertEqual(short.bytes, 4400, "every encoding PicPlace may hold comes back")
    }

    /// A Photo capture shot as a JPEG burst is edited on its stack: with the
    /// stack here the burst frames can be elsewhere, and without it a burst
    /// frame must never stand in (it is not the picture that was graded).
    func testAPhotoIsEditedOnItsStack() {
        let stackFile = "blends/\(stack.uuidString).png"
        let burst = frames(3)
        let withStack = ProjectHoldings(
            originals: burst, blends: [(stack, stackFile)], pictureBlendID: stack,
            present: [stackFile: 30_000_000], recordedBytes: [:], hasPreview: true)
        XCTAssertEqual(withStack.tier, .originals)
        XCTAssertNil(withStack.shortfall(for: withStack.pictureNeed))
        XCTAssertNotNil(withStack.shortfall(for: .originals), "re-stacking still needs the burst")

        let burstOnly = ProjectHoldings(
            originals: burst, blends: [(stack, stackFile)], pictureBlendID: stack,
            present: recorded(burst.map(\.name), bytes: 5), recordedBytes: [stackFile: 30], hasPreview: true)
        XCTAssertEqual(burstOnly.tier, .preview)
        XCTAssertEqual(burstOnly.shortfall(for: burstOnly.pictureNeed)?.blendIDs, [stack])
    }

    /// A size never recorded leaves the total a floor, and says so.
    func testAnUnrecordedSizeMakesTheTotalAFloor() {
        let holdings = ProjectHoldings(
            originals: frames(2), blends: [], pictureBlendID: nil, present: [:],
            recordedBytes: ["source/frame-1.dng": 10], hasPreview: false)
        let short = try! XCTUnwrap(holdings.shortfall(for: .originals))
        XCTAssertEqual(short.bytes, 10)
        XCTAssertFalse(short.bytesAreComplete)
    }

    /// A project listing no originals is not "missing" them — what
    /// `sourcesMissing` has always answered.
    func testAProjectWithNoOriginalsListedIsNotShort() {
        let holdings = ProjectHoldings(originals: [], blends: [], pictureBlendID: nil, present: [:],
                                       recordedBytes: [:], hasPreview: false)
        XCTAssertTrue(holdings.hasAllOriginals)
        XCTAssertEqual(holdings.tier, .originals)
        XCTAssertNil(holdings.shortfall(for: .nothing))
    }

    /// A need for a blend the project no longer lists waits for nothing.
    func testABlendNoLongerListedIsNotWaitedFor() {
        let holdings = ProjectHoldings(originals: frames(1), blends: [], pictureBlendID: nil,
                                       present: ["source/frame-1.dng": 1], recordedBytes: [:], hasPreview: false)
        XCTAssertNil(holdings.shortfall(for: .blends([clipA])))
    }

    private typealias Need = ProjectHoldings.Need
}
