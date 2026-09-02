import XCTest
import ImageIO
@testable import LetsLapseKit

/// Reading a shoot the app did not take: the EXIF walk, the ordering
/// contract, and the sidecars rebuilt from what the camera wrote.
final class ImportedStillsTests: XCTestCase {

    // MARK: - Dates

    /// The sub-second tag is the whole reason a 3.6-second interval reads as
    /// 3.615…3.689 rather than as whole-second steps.
    func testCaptureDateAddsSubsecond() throws {
        let date = try XCTUnwrap(ImportedStills.captureDate(
            exif: [
                kCGImagePropertyExifDateTimeOriginal as String: "2026:08:31 20:29:27",
                kCGImagePropertyExifSubsecTimeOriginal as String: "211",
                "OffsetTimeOriginal": "+02:00",
            ],
            tiff: [:]))
        XCTAssertEqual(date.timeIntervalSince1970, 1788200967.211, accuracy: 0.0005)
    }

    /// A two-digit fraction is tenths-and-hundredths, not milliseconds.
    func testCaptureDateSubsecondIsAFraction() throws {
        func stamp(_ subsecond: String) throws -> Double {
            try XCTUnwrap(ImportedStills.captureDate(
                exif: [
                    kCGImagePropertyExifDateTimeOriginal as String: "2026:08:31 20:29:27",
                    kCGImagePropertyExifSubsecTimeOriginal as String: subsecond,
                    "OffsetTimeOriginal": "Z",
                ],
                tiff: [:])).timeIntervalSince1970
        }
        let base = try stamp("0")
        XCTAssertEqual(try stamp("5") - base, 0.5, accuracy: 0.0005)
        XCTAssertEqual(try stamp("05") - base, 0.05, accuracy: 0.0005)
        XCTAssertEqual(try stamp("005") - base, 0.005, accuracy: 0.0005)
    }

    /// A body that writes no sub-second tag still dates its frames.
    func testCaptureDateWithoutSubsecond() throws {
        let date = try XCTUnwrap(ImportedStills.captureDate(
            exif: [
                kCGImagePropertyExifDateTimeOriginal as String: "2026:08:31 20:29:27",
                "OffsetTimeOriginal": "Z",
            ],
            tiff: [:]))
        XCTAssertEqual(date.timeIntervalSince1970, 1788208167, accuracy: 0.0005)
    }

    /// TIFF's DateTime is the last resort, after both EXIF stamps.
    func testCaptureDateFallsBackToTIFF() throws {
        XCTAssertNotNil(ImportedStills.captureDate(
            exif: [:],
            tiff: [kCGImagePropertyTIFFDateTime as String: "2026:08:31 20:29:27"]))
        XCTAssertNil(ImportedStills.captureDate(exif: [:], tiff: [:]))
    }

    func testEXIFOffsetParsing() {
        XCTAssertEqual(ImportedStills.timeZone(fromEXIFOffset: "+02:00")?.secondsFromGMT(), 7200)
        XCTAssertEqual(ImportedStills.timeZone(fromEXIFOffset: "-0530")?.secondsFromGMT(), -19800)
        XCTAssertEqual(ImportedStills.timeZone(fromEXIFOffset: "Z")?.secondsFromGMT(), 0)
        XCTAssertNil(ImportedStills.timeZone(fromEXIFOffset: ""))
        XCTAssertNil(ImportedStills.timeZone(fromEXIFOffset: "02:00"))
    }

    // MARK: - Sequence facts

    private func frame(
        _ name: String, at offset: Double,
        shutter: Double? = 3.2, iso: Double? = 100, aperture: Double? = 4.5
    ) -> ImportedStills.Frame {
        ImportedStills.Frame(
            url: URL(fileURLWithPath: "/shoot/\(name)"),
            capturedAt: Date(timeIntervalSince1970: 1_000_000 + offset),
            exposure: .init(
                iso: iso, exposureDuration: shutter, aperture: aperture,
                capturedAt: Date(timeIntervalSince1970: 1_000_000 + offset)),
            pixelWidth: 4608, pixelHeight: 3072,
            cameraMake: "SONY", cameraModel: "ILCE-7M4",
            byteCount: 18_821_120)
    }

    /// The interval is the median gap, so one battery-change hole doesn't
    /// drag it away from what the intervalometer was set to.
    func testIntervalIsMedianAndSurvivesAGap() {
        let sequence = ImportedStills.Sequence(frames: [
            frame("a", at: 0), frame("b", at: 3.6), frame("c", at: 7.2),
            frame("d", at: 610), frame("e", at: 613.6),
        ])
        XCTAssertEqual(try XCTUnwrap(sequence.intervalSeconds), 3.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sequence.elapsedSeconds), 613.6, accuracy: 0.001)
        let gaps = sequence.gaps()
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.afterIndex, 2)
    }

    func testCameraNameJoinsMakeAndModelWithoutRepeating() {
        func named(make: String?, model: String?) -> String? {
            var frame = self.frame("a", at: 0)
            frame.cameraMake = make
            frame.cameraModel = model
            return ImportedStills.Sequence(frames: [frame]).cameraName
        }
        XCTAssertEqual(named(make: "SONY", model: "ILCE-7M4"), "SONY ILCE-7M4")
        XCTAssertEqual(named(make: "Canon", model: "Canon EOS R5"), "Canon EOS R5")
        XCTAssertEqual(named(make: "SONY", model: nil), "SONY")
        XCTAssertEqual(named(make: nil, model: "ILCE-7M4"), "ILCE-7M4")
        XCTAssertNil(named(make: nil, model: nil))
    }

    func testConstantExposureDetection() {
        let locked = ImportedStills.Sequence(frames: [frame("a", at: 0), frame("b", at: 3.6)])
        XCTAssertTrue(locked.hasConstantExposure)
        let ramped = ImportedStills.Sequence(frames: [
            frame("a", at: 0), frame("b", at: 3.6, shutter: 1.6),
        ])
        XCTAssertFalse(ramped.hasConstantExposure)
        let range = try? XCTUnwrap(ramped.exposureValueRange)
        XCTAssertEqual(range?.high ?? 0, (range?.low ?? 0) + 1, accuracy: 0.001)
    }

    // MARK: - Sidecars

    func testFrameTimestampsMirrorTheShoot() throws {
        let sequence = ImportedStills.Sequence(frames: [
            frame("a", at: 0), frame("b", at: 3.6), frame("c", at: 7.2),
        ])
        let timestamps = try XCTUnwrap(sequence.frameTimestamps())
        XCTAssertEqual(timestamps.entries.map(\.frame), [0, 1, 2])
        XCTAssertEqual(timestamps.entries.map(\.shutter), [3.2, 3.2, 3.2])
        XCTAssertEqual(timestamps.entries.map(\.iso), [100, 100, 100])
        XCTAssertEqual(timestamps.elapsedSeconds.last ?? 0, 7.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timestamps.entries.first?.ev), 2.6618, accuracy: 0.001)
    }

    /// No clock, no sidecar — its absence is what tells every reader
    /// downstream to fall back to even spacing.
    func testNoTimestampsSidecarWithoutAFullClock() {
        var untimed = frame("b", at: 3.6)
        untimed.capturedAt = nil
        let sequence = ImportedStills.Sequence(frames: [frame("a", at: 0), untimed])
        XCTAssertNil(sequence.captureTimes)
        XCTAssertNil(sequence.frameTimestamps())
        XCTAssertNil(sequence.intervalSeconds)
    }

    /// One entry per file: an import blends nothing on the way in.
    func testSessionLogDescribesTheShootNotTheImport() {
        let sequence = ImportedStills.Sequence(frames: [
            frame("a", at: 0), frame("b", at: 3.6), frame("c", at: 7.2),
        ])
        let session = sequence.captureSession(sessionID: "abc")
        XCTAssertEqual(session.deviceModel, "SONY ILCE-7M4")
        XCTAssertEqual(session.blendMode, "1")
        XCTAssertEqual(session.captureMode, ImportedStills.importedCaptureMode)
        XCTAssertEqual(session.endReason, "imported")
        XCTAssertEqual(session.captureWidth, 4608)
        XCTAssertEqual(session.captureHeight, 3072)
        XCTAssertEqual(session.frames.count, 3)
        XCTAssertNil(session.frames.first?.blendCount)
        XCTAssertNil(session.frames.first?.window)
        XCTAssertEqual(try XCTUnwrap(session.intervalSeconds), 3.6, accuracy: 0.001)
    }

    func testSessionLogRoundTripsThroughJSON() throws {
        let sequence = ImportedStills.Sequence(frames: [frame("a", at: 0), frame("b", at: 3.6)])
        let session = sequence.captureSession(sessionID: "abc")
        let data = try CaptureExposureLog.makeEncoder().encode(session)
        let decoded = try CaptureExposureLog.makeDecoder()
            .decode(CaptureExposureLog.Session.self, from: data)
        XCTAssertEqual(decoded, session)
    }

    // MARK: - Ordering

    /// The order handed in is the shoot's order. Timestamps that disagree are
    /// reported, never silently corrected — the picker is where the operator
    /// decides what the sequence is.
    func testProbeKeepsTheGivenOrderAndFlagsDisagreement() {
        let outOfOrder = ImportedStills.Sequence(frames: [
            frame("b", at: 3.6), frame("a", at: 0), frame("c", at: 7.2),
        ])
        XCTAssertEqual(
            outOfOrder.frames.map { $0.url.lastPathComponent }, ["b", "a", "c"])
        XCTAssertFalse(outOfOrder.captureTimesFollowOrder)
        XCTAssertTrue(outOfOrder.issues().contains { $0.kind == "importOrder" })

        let inOrder = ImportedStills.Sequence(frames: [
            frame("a", at: 0), frame("b", at: 3.6), frame("c", at: 7.2),
        ])
        XCTAssertTrue(inOrder.captureTimesFollowOrder)
        XCTAssertTrue(inOrder.issues().isEmpty)
    }

    func testMixedFrameSizesAreRecordedAsAnIssue() {
        var odd = frame("c", at: 7.2)
        odd.pixelWidth = 6000
        odd.pixelHeight = 4000
        let sequence = ImportedStills.Sequence(frames: [
            frame("a", at: 0), frame("b", at: 3.6), odd,
        ])
        XCTAssertTrue(sequence.issues().contains { $0.kind == "importMixedSize" })
        // The project-level size is still the first frame's — what the stack
        // will size itself on.
        XCTAssertEqual(sequence.pixelSize?.width, 4608)
    }

    // MARK: - File types

    func testRawGateCoversTheCameraFamilies() {
        for name in ["shot.ARW", "shot.arw", "shot.CR3", "shot.NEF", "shot.dng", "shot.RAF"] {
            XCTAssertTrue(
                ImportedStills.isRaw(URL(fileURLWithPath: name)), "\(name) should read as raw")
        }
        for name in ["shot.jpg", "shot.HEIC", "shot.png", "shot.mov"] {
            XCTAssertFalse(
                ImportedStills.isRaw(URL(fileURLWithPath: name)), "\(name) is not raw")
        }
        XCTAssertTrue(ImportedStills.isStill(URL(fileURLWithPath: "shot.jpeg")))
        XCTAssertFalse(ImportedStills.isStill(URL(fileURLWithPath: "clip.mov")))
    }

    func testFormatLabelsMatchTheProjectVocabulary() {
        XCTAssertEqual(ImportedStills.formatLabel(for: "jpeg"), "JPG")
        XCTAssertEqual(ImportedStills.formatLabel(for: "tiff"), "TIF")
        XCTAssertEqual(ImportedStills.formatLabel(for: "arw"), "ARW")
        let sequence = ImportedStills.Sequence(frames: [
            ImportedStills.Frame(url: URL(fileURLWithPath: "/s/a.ARW")),
            ImportedStills.Frame(url: URL(fileURLWithPath: "/s/b.arw")),
            ImportedStills.Frame(url: URL(fileURLWithPath: "/s/c.jpeg")),
        ])
        XCTAssertEqual(sequence.formatLabels, ["ARW", "JPG"])
    }

    /// A shallow walk: a card's DCIM tree holds several numbered folders that
    /// are usually several different shoots.
    func testStillsInDirectoryIsShallowAndNameSorted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("SUB")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["img10.ARW", "img9.ARW", "notes.txt"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        try Data().write(to: nested.appendingPathComponent("img1.ARW"))

        let found = ImportedStills.stills(in: root).map(\.lastPathComponent)
        XCTAssertEqual(found, ["img9.ARW", "img10.ARW"])
    }

    /// A file that cannot be opened is still one of the shoot's frames —
    /// dropping it would silently shorten the import.
    func testUnreadableFileStillBecomesAFrame() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("broken.ARW")
        try Data([0x00, 0x01]).write(to: url)

        let sequence = ImportedStills.probe(urls: [url])
        XCTAssertEqual(sequence.count, 1)
        XCTAssertEqual(sequence.frames.first?.byteCount, 2)
        XCTAssertNil(sequence.frames.first?.pixelWidth)
    }
}
