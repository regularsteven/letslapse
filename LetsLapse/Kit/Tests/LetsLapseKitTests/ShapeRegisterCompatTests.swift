import XCTest
import CoreGraphics
@testable import LetsLapseKit

/// `shapes.json` between builds that do not agree on what it holds. The file
/// travels byte-for-byte (PicPlace, .lapse, device transfer), so an older
/// build re-encoding a newer build's register must carry what it does not
/// understand — a shape kind it has no case for, a top-level key it never
/// named — and must refuse the file outright when its `version` is above
/// `ShapeRegister.formatVersion`. These are literal JSON fixtures, written the
/// way another build would write them, not registers built through the API.
final class ShapeRegisterCompatTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shapes-compat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: ShapeRegister.url(inProjectFolder: dir))
    }

    private func fileKeys() throws -> Set<String> {
        let data = try Data(contentsOf: ShapeRegister.url(inProjectFolder: dir))
        let top = try JSONDecoder().decode([String: JSONValue].self, from: data)
        return Set(top.keys)
    }

    private static let representative = """
        "representative": {"relativePath": "source/frame-00001.jpg", "source": "sourceFrame", "width": 3024, "height": 4032}
        """

    private static let ellipse = """
        {"id": "11111111-1111-1111-1111-111111111111", "kind": "ellipse", "centre": [0.5, 0.4],
         "majorAxis": 0.3, "minorAxis": 0.3, "rotation": 0, "confidence": 1, "nativeDiameterPx": 907,
         "source": "manual", "wide": true}
        """

    private static let quad = """
        {"id": "22222222-2222-2222-2222-222222222222", "kind": "quad", "centre": [0.496, 0.496],
         "majorAxis": 0.3307, "minorAxis": 0.3307, "rotation": 0,
         "corners": [[0.3307, 0.372], [0.6614, 0.372], [0.6614, 0.62], [0.3307, 0.62]],
         "confidence": 0.9, "nativeDiameterPx": 1000, "source": "captured", "wide": true}
        """

    /// What a build with the outline inventory would write between two shapes we know.
    private static let outline = """
        {"kind": "outline", "id": "33333333-3333-3333-3333-333333333333", "points": [[0, 0], [1, 0], [1, 1]], "pose": {"tiltDeg": 5}}
        """

    // MARK: - (a) A newer build's element and keys ride through a save

    func testForeignShapeAndFieldsSurviveReadSaveReload() throws {
        try write("""
            {"version": 1, "detectorVersion": 2, "analysedAt": "2026-09-19T10:00:00Z",
             \(Self.representative),
             "shapes": [\(Self.ellipse), \(Self.outline), \(Self.quad)],
             "outlines": [{"id": "x"}], "note": "from a newer build"}
            """)
        guard case .register(let register) = ShapeRegister.read(inProjectFolder: dir) else {
            return XCTFail("a version-1 register with a foreign element must read")
        }
        XCTAssertEqual(register.shapes.count, 2)
        XCTAssertEqual(register.shapes.map(\.kind), [.ellipse, .quad], "known shapes keep their order")
        XCTAssertEqual(register.foreignShapes.count, 1)
        XCTAssertEqual(register.foreignShapes.first?["kind"], .string("outline"))
        XCTAssertEqual(register.foreignShapes.first?["pose"]?["tiltDeg"], .number(5))
        XCTAssertEqual(Set(register.foreignFields.keys), ["outlines", "note"])
        XCTAssertEqual(register.foreignFields["note"], .string("from a newer build"))
        XCTAssertEqual(register.foreignFields["outlines"], .array([.object(["id": .string("x")])]))

        try register.save(inProjectFolder: dir)
        let back = try XCTUnwrap(ShapeRegister.read(inProjectFolder: dir).register)
        XCTAssertEqual(back.foreignShapes, register.foreignShapes)
        XCTAssertEqual(back.foreignFields, register.foreignFields)
        XCTAssertEqual(back.shapes, register.shapes)
        XCTAssertEqual(back, register)
        XCTAssertTrue(try fileKeys().isSuperset(of: ["outlines", "note", "shapes", "version"]))

        // The foreign element follows the known ones in the file, whole.
        let data = try Data(contentsOf: ShapeRegister.url(inProjectFolder: dir))
        let top = try JSONDecoder().decode([String: JSONValue].self, from: data)
        let elements = try XCTUnwrap(top["shapes"]?.arrayValue)
        XCTAssertEqual(elements.count, 3)
        XCTAssertEqual(elements[2]["kind"], .string("outline"))
        XCTAssertEqual(elements[2]["points"], .array([.array([.number(0), .number(0)]), .array([.number(1), .number(0)]), .array([.number(1), .number(1)])]))
    }

    // MARK: - (b) A version above ours is refused, and the file is left alone

    func testTooNewVersionIsRefusedAndUntouched() throws {
        try write("""
            {"version": 2, "detectorVersion": 2, \(Self.representative), "shapes": [\(Self.ellipse)]}
            """)
        let before = try Data(contentsOf: ShapeRegister.url(inProjectFolder: dir))
        guard case .tooNew(let version) = ShapeRegister.read(inProjectFolder: dir) else {
            return XCTFail("version 2 must be .tooNew")
        }
        XCTAssertEqual(version, 2)
        XCTAssertNil(ShapeRegister.load(inProjectFolder: dir))
        XCTAssertNil(ShapeRegister.read(inProjectFolder: dir).register)
        XCTAssertEqual(try Data(contentsOf: ShapeRegister.url(inProjectFolder: dir)), before, "a read never writes")
    }

    /// The guard in `save` is the header's rule made unskippable: a register
    /// above `formatVersion` cannot be written even when built by hand.
    func testSaveRefusesARegisterAboveFormatVersion() throws {
        var register = ShapeRegister(representative: .init(relativePath: "p.jpg", source: .blendImage, width: 100, height: 100), shapes: [])
        register.version = ShapeRegister.formatVersion + 1
        XCTAssertThrowsError(try register.save(inProjectFolder: dir)) { error in
            XCTAssertEqual(error as? ShapeRegister.WriteRefused, .tooNew(version: ShapeRegister.formatVersion + 1))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ShapeRegister.url(inProjectFolder: dir).path))
    }

    /// The file changes under a writer that read it as `.register` — the
    /// viewer reads once at open, and a PicPlace pull can land a newer
    /// build's file while the editor is up. `save` looks at the bytes on
    /// disk at the write, not at what was read, and leaves them alone.
    func testSaveRefusesWhenTheFileOnDiskHasBecomeTooNew() throws {
        try write("""
            {"version": 1, "detectorVersion": 2, \(Self.representative), "shapes": [\(Self.ellipse)]}
            """)
        var register = try XCTUnwrap(ShapeRegister.read(inProjectFolder: dir).register)
        try write("""
            {"version": 2, "detectorVersion": 2, \(Self.representative), "shapes": [\(Self.ellipse), \(Self.outline)]}
            """)
        let before = try Data(contentsOf: ShapeRegister.url(inProjectFolder: dir))
        register.shapes = []
        XCTAssertThrowsError(try register.save(inProjectFolder: dir)) { error in
            XCTAssertEqual(error as? ShapeRegister.WriteRefused, .tooNew(version: 2))
        }
        XCTAssertEqual(try Data(contentsOf: ShapeRegister.url(inProjectFolder: dir)), before, "the newer file is untouched")
    }

    /// The same, for bytes that are no longer a JSON object at all.
    func testSaveRefusesWhenTheFileOnDiskHasBecomeUnreadable() throws {
        try write("""
            {"version": 1, "detectorVersion": 2, \(Self.representative), "shapes": [\(Self.ellipse)]}
            """)
        let register = try XCTUnwrap(ShapeRegister.read(inProjectFolder: dir).register)
        try write("{\"version\": 1, \"shapes\": [")
        let before = try Data(contentsOf: ShapeRegister.url(inProjectFolder: dir))
        XCTAssertThrowsError(try register.save(inProjectFolder: dir)) { error in
            guard case .unreadable? = error as? ShapeRegister.WriteRefused else { return XCTFail("expected .unreadable, got \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: ShapeRegister.url(inProjectFolder: dir)), before)
    }

    // MARK: - (c) An unknown kind at our version still loads — no bump needed for it

    func testUnknownKindAtCurrentVersionLoads() throws {
        try write("""
            {"version": 1, "detectorVersion": 2, \(Self.representative),
             "shapes": [\(Self.outline), \(Self.quad)]}
            """)
        let register = try XCTUnwrap(ShapeRegister.load(inProjectFolder: dir))
        XCTAssertEqual(register.version, 1)
        XCTAssertEqual(register.shapes.count, 1)
        XCTAssertEqual(register.shapes.first?.kind, .quad)
        XCTAssertEqual(register.foreignShapes.count, 1)
        XCTAssertEqual(register.families()[.square], 1, "families count known shapes only")
    }

    // MARK: - (d) Corrupt and missing

    func testCorruptBytesAreUnreadable() throws {
        try write("{\"version\": 1, \"shapes\": [")
        guard case .unreadable(let why) = ShapeRegister.read(inProjectFolder: dir) else {
            return XCTFail("corrupt bytes must be .unreadable")
        }
        XCTAssertFalse(why.isEmpty)
        XCTAssertNil(ShapeRegister.load(inProjectFolder: dir))
    }

    /// Well-formed JSON at our version that is not a register — no
    /// representative — is unreadable too, not too new.
    func testMissingRepresentativeIsUnreadable() throws {
        try write("{\"version\": 1, \"shapes\": []}")
        guard case .unreadable = ShapeRegister.read(inProjectFolder: dir) else {
            return XCTFail("a register without a representative must be .unreadable")
        }
    }

    func testMissingFileIsNone() throws {
        guard case .none = ShapeRegister.read(inProjectFolder: dir) else {
            return XCTFail("no file must be .none")
        }
        XCTAssertNil(ShapeRegister.load(inProjectFolder: dir))
    }

    // MARK: - (e) A legacy register without `version`

    func testLegacyRegisterWithoutVersionIsVersionOne() throws {
        try write("""
            {"detectorVersion": 1, \(Self.representative), "shapes": [\(Self.ellipse)]}
            """)
        let register = try XCTUnwrap(ShapeRegister.load(inProjectFolder: dir))
        XCTAssertEqual(register.version, 1)
        XCTAssertEqual(register.shapes.count, 1)
        XCTAssertTrue(register.foreignShapes.isEmpty)
        XCTAssertTrue(register.foreignFields.isEmpty)
    }

    /// A file this build re-saves is this build's format: `version` comes
    /// back as `formatVersion` whatever the file was read at, so the bump
    /// (when WP10 makes one) reaches every file a newer build touches, not
    /// only the ones it mints.
    func testResavedLegacyRegisterCarriesTodaysFormatVersion() throws {
        try write("""
            {"detectorVersion": 1, \(Self.representative), "shapes": [\(Self.ellipse)]}
            """)
        let register = try XCTUnwrap(ShapeRegister.load(inProjectFolder: dir))
        try register.save(inProjectFolder: dir)
        let data = try Data(contentsOf: ShapeRegister.url(inProjectFolder: dir))
        let top = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertEqual(top["version"], .number(Double(ShapeRegister.formatVersion)))
        XCTAssertEqual(try XCTUnwrap(ShapeRegister.load(inProjectFolder: dir)).version, ShapeRegister.formatVersion)
    }

    /// `failure` through the hand-written `encode(to:)` — the one known key
    /// nothing else round-trips. Find shapes leans on it to not retry a
    /// project whose picture cannot be read.
    func testFailureSurvivesReadSaveReload() throws {
        try write("""
            {"version": 1, "detectorVersion": 2, "analysedAt": "2026-09-19T10:00:00Z",
             "failure": "picture could not be read", \(Self.representative), "shapes": []}
            """)
        let register = try XCTUnwrap(ShapeRegister.load(inProjectFolder: dir))
        XCTAssertEqual(register.failure, "picture could not be read")
        try register.save(inProjectFolder: dir)
        let back = try XCTUnwrap(ShapeRegister.load(inProjectFolder: dir))
        XCTAssertEqual(back.failure, "picture could not be read")
        XCTAssertTrue(try fileKeys().contains("failure"))
    }

    // MARK: - (f) Nothing foreign writes exactly today's keys

    /// The key set is the one `ShapeDetectorTests.testRegisterRoundTrip`'s
    /// register writes: `failure` and `viewfinder` are nil there and stay out,
    /// and `foreignShapes` / `foreignFields` must never appear by name.
    func testRegisterWithNothingForeignWritesTodaysKeys() throws {
        var shape = DetectedShape.quad(corners: [CGPoint(x: 1000, y: 1500), CGPoint(x: 2000, y: 1500), CGPoint(x: 2000, y: 2500), CGPoint(x: 1000, y: 2500)],
                                       frame: CGSize(width: 3024, height: 4032), source: .detected)
        shape.confidence = 0.9
        let register = ShapeRegister(analysedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                     representative: .init(relativePath: "source/frame-00001.jpg", source: .sourceFrame, width: 3024, height: 4032),
                                     shapes: [shape])
        try register.save(inProjectFolder: dir)
        XCTAssertEqual(try fileKeys(), ["analysedAt", "detectorVersion", "representative", "shapes", "version"])

        let data = try Data(contentsOf: ShapeRegister.url(inProjectFolder: dir))
        let top = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertEqual(top["version"], .number(Double(ShapeRegister.formatVersion)))
        XCTAssertFalse(top.keys.contains("foreignShapes"))
        XCTAssertFalse(top.keys.contains("foreignFields"))
    }

    /// A known element with a key this build does not name still decodes —
    /// `decodeIfPresent` semantics are unchanged — and that key is NOT
    /// retained: `DetectedShape` keeps only what it names. The rule: bump
    /// `formatVersion` if losing such a key would matter.
    func testUnknownKeyInsideAKnownShapeDecodesAndIsDropped() throws {
        try write("""
            {"version": 1, "detectorVersion": 2, \(Self.representative),
             "shapes": [{"id": "44444444-4444-4444-4444-444444444444", "kind": "ellipse", "centre": [0.5, 0.5],
                         "majorAxis": 0.2, "minorAxis": 0.1, "glow": 0.7}]}
            """)
        let register = try XCTUnwrap(ShapeRegister.load(inProjectFolder: dir))
        XCTAssertEqual(register.shapes.count, 1)
        XCTAssertTrue(register.foreignShapes.isEmpty, "a known kind with an extra key is not a foreign shape")
        try register.save(inProjectFolder: dir)
        let data = try Data(contentsOf: ShapeRegister.url(inProjectFolder: dir))
        let top = try JSONDecoder().decode([String: JSONValue].self, from: data)
        let element = try XCTUnwrap(top["shapes"]?.arrayValue?.first?.objectValue)
        XCTAssertNil(element["glow"], "not retained — a bump if it mattered")
    }

    // MARK: - JSONValue itself

    func testJSONValueRoundTripsEveryCase() throws {
        let value: JSONValue = .object([
            "n": .null, "b": .bool(true), "i": .number(5), "f": .number(0.25), "s": .string("x"),
            "a": .array([.number(1), .string("two"), .null]), "o": .object(["k": .bool(false)])])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
        // An integer written by a newer build comes back an integer.
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(JSONValue.number(5)), as: UTF8.self) == "5")
    }
}
