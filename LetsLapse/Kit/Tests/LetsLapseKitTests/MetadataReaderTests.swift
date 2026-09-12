import XCTest
@testable import LetsLapseKit

/// The XMP/IIM/Exif extraction against the four example files of Part 2 §2.
/// `demo.jpg` and the ARW's sidecar are fixtures; the ARW and the rendered
/// DNG are read from the Desktop and skipped when absent.
final class MetadataReaderTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext), "\(name).\(ext) fixture")
    }

    private func desktopFile(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: "/Users/stevenwright/Desktop/Lightroom Exports").appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(name) is not on the Desktop")
        }
        return url
    }

    // MARK: XMP parsing

    func testSidecarPacketAttributeFormParses() throws {
        let packet = try XMPPacket.read(contentsOf: try fixture("metadata-_WEX3518", "xmp"))
        XCTAssertEqual(packet.text("dc:title"), "Charles Bridge at night")
        XCTAssertEqual(packet.text("xmp:Rating"), "5")
        XCTAssertEqual(packet.list("dc:subject")?.count, 7)
        XCTAssertEqual(packet.list("dc:creator"), ["Steven Wright"])
        XCTAssertEqual(packet.text("exif:GPSLatitude"), "50,5.3833333333N")
        XCTAssertEqual(packet.text("exif:ISOSpeedRatings"), "100")
        XCTAssertEqual(packet.text("Iptc4xmpCore:Location"), "Mala Strana")
        XCTAssertNil(packet.text("Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiAdrCity"))
    }

    func testEmbeddedPacketElementFormAndAttributeShorthandStructParse() throws {
        // ImageIO re-serialises the JPEG's packet in element form, with the
        // contact struct as `rdf:parseType="Resource"`; the raw packet in the
        // file has it as attribute shorthand. Both must read the same.
        let url = try fixture("metadata-demo", "jpg")
        let embedded = try XCTUnwrap(MetadataReader.embeddedPacket(at: url))
        XCTAssertEqual(embedded.text("Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiAdrCity"), "Melbourne")
        XCTAssertEqual(embedded.text("xmpRights:Marked"), "True")
        XCTAssertEqual(embedded.text("xmpRights:UsageTerms"), "https://regularsteven.com/license-rights")

        let bytes = try Data(contentsOf: url)
        let start = try XCTUnwrap(bytes.range(of: Data("<x:xmpmeta".utf8))?.lowerBound)
        let end = try XCTUnwrap(bytes.range(of: Data("</x:xmpmeta>".utf8))?.upperBound)
        let raw = try XMPPacket.parse(bytes[start..<end])
        XCTAssertEqual(raw.text("Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiAdrCity"), "Melbourne")
        XCTAssertEqual(raw.text("Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiAdrPcode"), "3000")
        XCTAssertEqual(raw.text("dc:title"), "White Corner, black Corner")
        XCTAssertEqual(raw.list("dc:subject"), ["Black and white", "design", "gradient"])
    }

    func testCoordinateAndRationalSpellings() {
        XCTAssertEqual(try XCTUnwrap(MetadataReader.coordinate("50,5.3833333333N")), 50.0897222, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(MetadataReader.coordinate("14,24.6983333333E")), 14.4116389, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(MetadataReader.coordinate("33,52,30S")), -33.875, accuracy: 1e-9)
        XCTAssertEqual(MetadataReader.coordinate("-0.5"), -0.5)
        XCTAssertEqual(MetadataReader.rational("32/10"), 3.2)
        XCTAssertEqual(MetadataReader.rational("+0.29"), 0.29)
        XCTAssertNil(MetadataReader.rational("1/0"))
        XCTAssertEqual(
            MetadataReader.exifDateText(stamp: "2026:08:31 20:29:30", subsecond: "836", offset: "+01:00"),
            "2026-08-31T20:29:30.836+01:00")
        XCTAssertEqual(
            MetadataReader.exifDateText(stamp: "2026:08:31 20:29:30", subsecond: nil, offset: nil),
            "2026-08-31T20:29:30")
        XCTAssertEqual(
            MetadataReader.exifDateText(stamp: "2026:08:31 20:29:30", subsecond: "5", offset: "-0500"),
            "2026-08-31T20:29:30.500-05:00")
    }

    // MARK: The four files

    func testDemoJPEGCarriesTheWholeIPTCCoreSet() throws {
        let result = MetadataReader.read(fileAt: try fixture("metadata-demo", "jpg"))
        let m = result.metadata
        XCTAssertEqual(result.source, "file")
        XCTAssertEqual(m.title, "White Corner, black Corner")
        XCTAssertEqual(m.caption, "It runs from white to black")
        XCTAssertEqual(m.creator, ["Steven Wright"])
        XCTAssertEqual(m.rights, "© 2026 Steven Wright")
        XCTAssertEqual(m.rating, 4)
        XCTAssertEqual(m.rightsStatus, .copyrighted)
        XCTAssertEqual(m.rightsURL, "https://regularsteven.com/copyright-info")
        XCTAssertEqual(m.usageTerms, "https://regularsteven.com/license-rights")
        XCTAssertEqual(m.creatorContact?.address, "23 Main Street")
        XCTAssertEqual(m.creatorContact?.city, "Melbourne")
        XCTAssertEqual(m.creatorContact?.state, "Victoria")
        XCTAssertEqual(m.creatorContact?.postcode, "3000")
        XCTAssertEqual(m.creatorContact?.country, "Australia")
        XCTAssertEqual(m.creatorContact?.phone, "0499123123")
        XCTAssertEqual(m.creatorContact?.email, "hello@regularsteven.com")
        XCTAssertEqual(m.creatorContact?.website, "https://regularsteven.com")
        XCTAssertEqual(m.keywords, ["Black and white", "design", "gradient"])
        XCTAssertEqual(m.dimensions?.width, 1200)
        XCTAssertEqual(m.dimensions?.height, 800)
        XCTAssertNil(m.camera, "a Photoshop export carries no camera")
        XCTAssertNil(m.location)
    }

    func testARWTakesTheSidecarOverItsOwnRating() throws {
        let arw = try desktopFile("_WEX3518.ARW")
        // In-file alone: Sony's own rating 0, no descriptive fields, no GPS.
        let alone = MetadataReader.read(fileAt: arw, sidecar: URL(fileURLWithPath: "/nonexistent.xmp"))
        XCTAssertEqual(alone.source, "file")
        XCTAssertEqual(alone.metadata.rating, 0)
        XCTAssertNil(alone.metadata.title)
        XCTAssertNil(alone.metadata.gps)
        XCTAssertEqual(alone.metadata.camera?.model, "ILCE-7M4")
        XCTAssertEqual(alone.metadata.captured, "2026-08-31T20:29:30.836", "no offset in the ARW, none invented")

        let withSidecar = MetadataReader.read(fileAt: arw, sidecar: try fixture("metadata-_WEX3518", "xmp"))
        let m = withSidecar.metadata
        XCTAssertEqual(withSidecar.source, "sidecar")
        XCTAssertEqual(m.title, "Charles Bridge at night")
        XCTAssertEqual(m.rating, 5, "the sidecar is the newer record")
        XCTAssertEqual(m.keywords?.count, 7)
        XCTAssertEqual(m.location?.sublocation, "Mala Strana")
        XCTAssertEqual(m.location?.state, "Prague")
        XCTAssertEqual(m.location?.country, "Czech Republic")
        XCTAssertEqual(m.location?.countryCode, "CZ")
        XCTAssertEqual(m.cameraLine, "SONY ILCE-7M4")
        XCTAssertEqual(m.camera?.lens, "Viltrox 28mm F4.5 FE")
        XCTAssertEqual(m.exposure?.seconds, 3.2)
        XCTAssertEqual(m.exposure?.aperture, 4.5)
        XCTAssertEqual(m.exposure?.iso, 100)
        XCTAssertEqual(try XCTUnwrap(m.gps?.lat), 50.0897, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(m.gps?.lon), 14.4116, accuracy: 0.0001)
        XCTAssertEqual(m.captured, "2026-08-31T20:29:30.836+01:00")
    }

    func testRenderedDNGCarriesTheSameValuesEmbedded() throws {
        let result = MetadataReader.read(fileAt: try desktopFile("_WEX3518-Rendered.dng"),
                                         sidecar: URL(fileURLWithPath: "/nonexistent.xmp"))
        let m = result.metadata
        XCTAssertEqual(result.source, "file")
        XCTAssertEqual(m.title, "Charles Bridge at night")
        XCTAssertEqual(m.rating, 5)
        XCTAssertEqual(m.keywords?.count, 7)
        XCTAssertEqual(m.location?.sublocation, "Mala Strana")
        XCTAssertEqual(m.location?.countryCode, "CZ")
        XCTAssertEqual(m.cameraLine, "SONY ILCE-7M4")
        XCTAssertEqual(m.camera?.lens, "Viltrox 28mm F4.5 FE")
        XCTAssertEqual(m.exposureLine, "3.2 s · f/4.5 · ISO 100 · 28 mm (42 mm eq.)")
        XCTAssertEqual(try XCTUnwrap(m.gps?.lat), 50.0897, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(m.gps?.lon), 14.4116, accuracy: 0.0001)
        XCTAssertEqual(m.captured, "2026-08-31T20:29:30.836+01:00")
    }
}
