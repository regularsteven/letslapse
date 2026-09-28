import Foundation
import XCTest
@testable import LetsLapseKit

/// The vectors were computed outside Swift (Python's `hmac`/`hashlib`, a
/// hand-written RFC 5869 HKDF), so these pin the derivation itself, not
/// this implementation's view of it.
final class NearbyTrustTests: XCTestCase {

    private let key = Data((0..<32).map { UInt8($0) })
    private let serverID = "3f1c2a9e-7b4d-4e21-9a55-1c0d8e6f2b10"
    private let userUUID = "9b7e5d3c-1a2b-4c6d-8e0f-a1b2c3d4e5f6"

    private func utcNoon(_ day: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: "\(day)T12:00:00Z")!
    }

    func testDecodeKeyReadsBase64URLWithoutPadding() {
        XCTAssertEqual(NearbyTrust.decodeKey("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"), key)
    }

    func testDecodeKeyRefusesTheWrongLength() {
        XCTAssertNil(NearbyTrust.decodeKey("AAECAw"))
        XCTAssertNil(NearbyTrust.decodeKey("not base64 at all!"))
    }

    func testPSKMatchesTheReferenceVector() {
        let psk = NearbyTrust.psk(key: key, serverID: serverID, userUUID: userUUID)
        XCTAssertEqual(psk.map { String(format: "%02x", $0) }.joined(),
                       "4d1b32f6cc818ce56fa678f4764db6840a811dabf82821518f1d7ba656dc99d0")
    }

    func testPSKIgnoresTheCaseOfTheIDs() {
        XCTAssertEqual(NearbyTrust.psk(key: key, serverID: serverID.uppercased(), userUUID: userUUID.uppercased()),
                       NearbyTrust.psk(key: key, serverID: serverID, userUUID: userUUID))
    }

    func testPSKDiffersPerAccount() {
        XCTAssertNotEqual(NearbyTrust.psk(key: key, serverID: serverID, userUUID: UUID().uuidString),
                          NearbyTrust.psk(key: key, serverID: serverID, userUUID: userUUID))
    }

    func testDiscoveryTagsMatchTheReferenceVectors() {
        XCTAssertEqual(NearbyTrust.discoveryTag(key: key, day: utcNoon("2026-09-28")), "_cNXHBMoIUk")
        XCTAssertEqual(NearbyTrust.discoveryTag(key: key, day: utcNoon("2026-09-27")), "i474aPYOMcI")
        XCTAssertEqual(NearbyTrust.discoveryTag(key: key, day: utcNoon("2026-09-29")), "8RoFF0xyULA")
    }

    func testAcceptsYesterdayTodayAndTomorrowOnly() {
        let now = utcNoon("2026-09-28")
        XCTAssertTrue(NearbyTrust.accepts(tag: "_cNXHBMoIUk", key: key, now: now))
        XCTAssertTrue(NearbyTrust.accepts(tag: "i474aPYOMcI", key: key, now: now))
        XCTAssertTrue(NearbyTrust.accepts(tag: "8RoFF0xyULA", key: key, now: now))
        XCTAssertFalse(NearbyTrust.accepts(tag: "_cNXHBMoIUk", key: key, now: utcNoon("2026-10-01")))
        let other = Data(repeating: 7, count: 32)
        XCTAssertFalse(NearbyTrust.accepts(tag: "_cNXHBMoIUk", key: other, now: now))
    }

    func testDayStringIsUTC() {
        let formatter = ISO8601DateFormatter()
        // 23:30 in Prague on the 28th is 21:30 UTC — still the 28th; 01:30
        // Prague on the 29th is 23:30 UTC on the 28th.
        XCTAssertEqual(NearbyTrust.dayString(formatter.date(from: "2026-09-28T23:30:00+02:00")!), "2026-09-28")
        XCTAssertEqual(NearbyTrust.dayString(formatter.date(from: "2026-09-29T01:30:00+02:00")!), "2026-09-28")
    }

    func testSafeRelativePaths() {
        XCTAssertTrue(NearbyTrust.isSafeRelativePath("source/frame-00042.dng"))
        XCTAssertTrue(NearbyTrust.isSafeRelativePath("blends/7F3A2C.mov"))
        XCTAssertFalse(NearbyTrust.isSafeRelativePath(""))
        XCTAssertFalse(NearbyTrust.isSafeRelativePath("/etc/passwd"))
        XCTAssertFalse(NearbyTrust.isSafeRelativePath("source/../../library.json"))
        XCTAssertFalse(NearbyTrust.isSafeRelativePath("source//frame.dng"))
        XCTAssertFalse(NearbyTrust.isSafeRelativePath("source/./frame.dng"))
        XCTAssertFalse(NearbyTrust.isSafeRelativePath(".trash/source/frame.dng"))
        XCTAssertFalse(NearbyTrust.isSafeRelativePath("source\\frame.dng"))
    }
}
