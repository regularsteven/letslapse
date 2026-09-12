import XCTest
@testable import LetsLapseKit

/// The one mapping table: every field is in it once, every spelling is
/// well-formed, and the record can be walked field by field through it.
final class MetadataFieldMapTests: XCTestCase {

    func testEveryFieldIsMappedExactlyOnce() {
        let mapped = MetadataFieldMap.all.map(\.field)
        XCTAssertEqual(Set(mapped).count, mapped.count, "a field is mapped twice")
        for field in MetadataField.allCases {
            XCTAssertNotNil(MetadataFieldMap.mapping(for: field), "\(field) has no mapping")
        }
    }

    func testXMPPathsAreQualifiedAndStructsUseSlash() {
        for mapping in MetadataFieldMap.all {
            XCTAssertFalse(mapping.xmp.isEmpty, "\(mapping.field) has no XMP path")
            for path in mapping.xmp {
                for component in path.split(separator: "/") {
                    XCTAssertTrue(component.contains(":"), "\(path) is not a qualified XMP path")
                }
            }
        }
    }

    func testIIMDatasetsUseRecordColonDataset() {
        for mapping in MetadataFieldMap.all {
            guard let iim = mapping.iim else { continue }
            let parts = iim.split(separator: ":")
            XCTAssertEqual(parts.count, 2, "\(mapping.field): \(iim)")
            XCTAssertNotNil(Int(parts[0]))
            XCTAssertNotNil(Int(parts[1]))
        }
    }

    func testEditableAndInformationalPartitionTheFields() {
        let editable = Set(MetadataField.editable)
        let informational = Set(MetadataField.informational)
        XCTAssertTrue(editable.isDisjoint(with: informational))
        XCTAssertEqual(editable.union(informational), Set(MetadataField.allCases))
        XCTAssertEqual(MetadataField.editable.first, .title)
        XCTAssertEqual(MetadataField.editable.last, .keywords)
    }

    func testRecordRoundTripsEveryFieldThroughTheSubscript() throws {
        var record = AssetMetadata()
        for mapping in MetadataFieldMap.all {
            let value: MetadataValue
            switch mapping.kind {
            case .text: value = .text("v-\(mapping.field.rawValue)")
            case .list: value = .list(["a", "b"])
            case .integer: value = .integer(3)
            case .number, .coordinate, .altitude: value = .number(1.5)
            case .rightsMarked: value = .text("copyrighted")
            case .date: value = .text("2026-08-31T20:29:30.836+01:00")
            }
            record[mapping.field] = value
            XCTAssertEqual(record[mapping.field], value, "\(mapping.field)")
        }
        XCTAssertFalse(record.isEmpty)

        // Encodes with the plain JSON keys of §4.1 and decodes back equal.
        let data = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["creatorContact"])
        XCTAssertNotNil((object["camera"] as? [String: Any])?["lens"])
        XCTAssertEqual(object["rightsStatus"] as? String, "copyrighted")
        let decoded = try JSONDecoder().decode(AssetMetadata.self, from: data)
        XCTAssertEqual(decoded, record)

        // Clearing every field empties the nested structs out of the record.
        for field in MetadataField.allCases { record[field] = nil }
        XCTAssertTrue(record.isEmpty)
        XCTAssertNil(record.creatorContact)
        XCTAssertNil(record.camera)
        XCTAssertEqual(String(data: try JSONEncoder().encode(record), encoding: .utf8), "{}")
    }

    func testLayeringAndCommonValues() {
        var imported = AssetMetadata()
        imported.title = "From the file"
        imported.rating = 0
        imported.keywords = ["Prague"]
        var edited = AssetMetadata()
        edited.rating = 5

        let resolved = AssetMetadata.resolving(edited, over: imported)
        XCTAssertEqual(resolved.title, "From the file")
        XCTAssertEqual(resolved.rating, 5)
        XCTAssertEqual(resolved.keywords, ["Prague"])

        // A chain resolves first-on-top.
        var projectEdited = AssetMetadata()
        projectEdited.title = "Project title"
        let chained = AssetMetadata.resolving([edited, projectEdited, imported])
        XCTAssertEqual(chained.title, "Project title")
        XCTAssertEqual(chained.rating, 5)

        // Common: fields every record agrees on; keywords are the union.
        var second = imported
        second.rating = 3
        second.keywords = ["Dusk", "prague"]
        let common = AssetMetadata.common(across: [imported, second])
        XCTAssertEqual(common.title, "From the file")
        XCTAssertNil(common.rating)
        XCTAssertEqual(common.keywords, ["Prague", "Dusk"])
    }

    func testExposureAndGPSLines() {
        var record = AssetMetadata()
        record[.exposureSeconds] = .number(3.2)
        record[.exposureAperture] = .number(4.5)
        record[.exposureISO] = .number(100)
        record[.exposureFocalLength] = .number(28)
        record[.exposureFocalLength35] = .number(42)
        XCTAssertEqual(record.exposureLine, "3.2 s · f/4.5 · ISO 100 · 28 mm (42 mm eq.)")
        record[.gpsLatitude] = .number(50.0897)
        record[.gpsLongitude] = .number(14.4116)
        record[.gpsAltitude] = .number(2)
        XCTAssertEqual(record.gpsLine, "50.0897° N 14.4116° E · 2 m")
        XCTAssertEqual(AssetMetadata.shutterLabel(1.0 / 250), "1/250 s")
        XCTAssertEqual(AssetMetadata.shutterLabel(30), "30 s")
        record[.cameraMake] = .text("SONY")
        record[.cameraModel] = .text("ILCE-7M4")
        XCTAssertEqual(record.cameraLine, "SONY ILCE-7M4")
        record[.cameraMake] = .text("Canon")
        record[.cameraModel] = .text("Canon EOS R5")
        XCTAssertEqual(record.cameraLine, "Canon EOS R5")
    }
}
