import XCTest
@testable import LetsLapseKit

/// The per-frame capture sidecar and the presentation-time mapping it drives.
final class FrameTimestampsTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("timestamps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(_ frame: Int, _ offset: Double) -> FrameTimestamps.Entry {
        FrameTimestamps.Entry(
            frame: frame,
            captureTime: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            shutter: 0.02, iso: 100, ev: 10)
    }

    // MARK: - Round trip

    func testWrittenLinesReadBackIdentically() throws {
        let writer = try XCTUnwrap(FrameTimestampWriter(directory: directory))
        let written = [entry(0, 0), entry(1, 10.25), entry(2, 20.5)]
        for entry in written { XCTAssertTrue(writer.append(entry)) }
        writer.close()

        let loaded = try FrameTimestamps.load(from: writer.url)
        XCTAssertEqual(loaded.entries.count, 3)
        for (index, entry) in loaded.entries.enumerated() {
            XCTAssertEqual(entry.frame, written[index].frame)
            XCTAssertEqual(entry.shutter, written[index].shutter, accuracy: 1e-9)
            XCTAssertEqual(entry.iso, written[index].iso, accuracy: 1e-9)
            XCTAssertEqual(entry.ev ?? 0, 10, accuracy: 1e-9)
            XCTAssertEqual(
                entry.captureTime.timeIntervalSince1970,
                written[index].captureTime.timeIntervalSince1970,
                accuracy: 0.001)
        }
    }

    /// Sub-second spacing is the reason the stamps carry fractional seconds —
    /// a whole-second format would collapse a fast shoot onto itself.
    func testSubSecondSpacingSurvivesTheRoundTrip() throws {
        let writer = try XCTUnwrap(FrameTimestampWriter(directory: directory))
        writer.append(entry(0, 0))
        writer.append(entry(1, 0.5))
        writer.close()
        let loaded = try FrameTimestamps.load(from: writer.url)
        XCTAssertEqual(loaded.elapsedSeconds, [0, 0.5])
    }

    func testTheFileIsNewlineDelimitedJSON() throws {
        let writer = try XCTUnwrap(FrameTimestampWriter(directory: directory))
        writer.append(entry(0, 0))
        writer.append(entry(1, 1))
        writer.close()
        let text = try String(contentsOf: writer.url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            XCTAssertTrue(line.hasPrefix("{"))
            XCTAssertTrue(line.hasSuffix("}"))
        }
    }

    /// A shoot that dies mid-write leaves a torn last line; every finished
    /// line before it must still count.
    func testATornFinalLineIsSkippedRatherThanLosingTheShoot() throws {
        let writer = try XCTUnwrap(FrameTimestampWriter(directory: directory))
        writer.append(entry(0, 0))
        writer.append(entry(1, 5))
        writer.close()
        var text = try String(contentsOf: writer.url, encoding: .utf8)
        text += "{\"frame\":2,\"captureTi"
        try text.write(to: writer.url, atomically: true, encoding: .utf8)

        let loaded = try FrameTimestamps.load(from: writer.url)
        XCTAssertEqual(loaded.entries.count, 2)
    }

    func testASidecarIsFoundBesideItsFrames() throws {
        let writer = try XCTUnwrap(FrameTimestampWriter(directory: directory))
        writer.append(entry(0, 0))
        writer.close()
        let frames = [directory.appendingPathComponent("frame-00000.heic")]
        XCTAssertNotNil(FrameTimestamps.load(besideFrames: frames))
        XCTAssertNil(FrameTimestamps.load(besideFrames: [
            directory.appendingPathComponent("nested/frame-00000.heic")
        ]))
        XCTAssertNil(FrameTimestamps.load(besideFrames: []))
    }

    // MARK: - Derived timing

    func testElapsedSecondsAreMeasuredFromTheFirstFrame() {
        let stamps = FrameTimestamps(entries: [entry(0, 100), entry(1, 130), entry(2, 190)])
        XCTAssertEqual(stamps.elapsedSeconds, [0, 30, 90])
    }

    func testABackwardsClockIsHeldRatherThanGoingNonMonotonic() {
        let stamps = FrameTimestamps(entries: [entry(0, 0), entry(1, 30), entry(2, 20)])
        XCTAssertEqual(stamps.elapsedSeconds, [0, 30, 30])
    }

    func testASubsetCanBePickedByCaptureOrder() {
        let stamps = FrameTimestamps(entries: [entry(0, 0), entry(1, 30), entry(2, 90)])
        XCTAssertEqual(stamps.elapsedSeconds(forOrders: [0, 2]), [0, 90])
        XCTAssertNil(stamps.elapsedSeconds(forOrders: [0, 7]))
    }

    // MARK: - Presentation mapping

    /// Evenly-spaced captures must land exactly where the constant-fps layout
    /// would have put them — the sidecar path can't retime a regular shoot.
    func testEvenSpacingMapsToTheConstantFrameRateLayout() throws {
        let times = (0..<10).map { Double($0) * 20 }
        let mapped = try XCTUnwrap(
            FrameTimeMapping.presentationSeconds(frameTimes: times, outputFPS: 30))
        for (index, seconds) in mapped.enumerated() {
            XCTAssertEqual(seconds, Double(index) / 30, accuracy: 1e-9)
        }
    }

    /// The point of the whole path: a frame that took twice as long to arrive
    /// occupies twice as much of the clip.
    func testAStretchedIntervalOccupiesProportionallyMoreOfTheClip() throws {
        // 10 s, 10 s, then 20 s (the exposure ramp slowing the shoot down).
        let times: [Double] = [0, 10, 20, 40]
        let mapped = try XCTUnwrap(
            FrameTimeMapping.presentationSeconds(frameTimes: times, outputFPS: 30))
        let gaps = zip(mapped.dropFirst(), mapped).map(-)
        XCTAssertEqual(gaps[1] / gaps[0], 1, accuracy: 1e-9)
        XCTAssertEqual(gaps[2] / gaps[0], 2, accuracy: 1e-9)
    }

    /// Proportional, not literal: a six-hour shoot is still a short clip.
    func testTheClipKeepsItsNominalLength() throws {
        let times = (0..<300).map { Double($0) * 20 + Double($0 * $0) * 0.01 }
        let mapped = try XCTUnwrap(
            FrameTimeMapping.presentationSeconds(frameTimes: times, outputFPS: 30))
        XCTAssertEqual(mapped.first ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(mapped.last ?? -1, Double(299) / 30, accuracy: 1e-6)
    }

    func testMappingRefusesWhatItCannotDescribe() {
        XCTAssertNil(FrameTimeMapping.presentationSeconds(frameTimes: [5], outputFPS: 30))
        XCTAssertNil(FrameTimeMapping.presentationSeconds(frameTimes: [0, 0, 0], outputFPS: 30))
        XCTAssertNil(FrameTimeMapping.presentationSeconds(frameTimes: [0, 10], outputFPS: 0))
    }
}
