import XCTest
@testable import LetsLapseKit

final class PicPlaceOriginalsCheckTests: XCTestCase {

    private typealias Check = PicPlaceOriginalsCheck

    private let hashA = String(repeating: "a", count: 64)
    private let hashB = String(repeating: "b", count: 64)
    private let hashC = String(repeating: "c", count: 64)

    private func frame(_ n: Int, bytes: Int64 = 1000, hash: String? = nil) -> Check.LocalFile {
        Check.LocalFile(name: "source/frame-\(n).dng", kind: .source, bytes: bytes, sha256: hash)
    }

    private func asset(_ name: String, bytes: Int64? = 1000, hash: String?, confirmed: Bool = true,
                       verified: Bool = true) -> Check.RemoteAsset {
        Check.RemoteAsset(name: name, bytes: bytes, sha256: hash, isConfirmed: confirmed, isVerified: verified)
    }

    /// picplace.co's storage does not check a PUT's bytes; PicPlace reads
    /// each upload back and only then marks it verified (2026-09-24).
    func testAConfirmedCopyPicPlaceHasNotReadBackIsNotYetLetGoOf() {
        let local = [frame(1, hash: hashA), frame(2, hash: hashA), frame(3, hash: hashA)]
        let remote = [
            asset("source/frame-1.dng", hash: hashA, verified: false),     // still being checked
            asset("source/frame-2.dng", hash: hashA, verified: false),     // an older row, unverified…
            asset("source/frame-2.dng", hash: hashA, verified: true),      // …and a verified one
            asset("source/frame-3.dng", hash: hashB, verified: true),      // verified, but other bytes
        ]
        let verdict = Check.verify(local, against: remote)
        XCTAssertFalse(verdict.passes)
        XCTAssertEqual(verdict.verified.map(\.name), ["source/frame-2.dng"])
        XCTAssertEqual(verdict.findings.map(\.problem), [.notVerified, .contentDiffers])
        XCTAssertFalse(verdict.awaitsVerification, "a difference is not cured by waiting")
        let waiting = Check.verify([frame(1, hash: hashA)], against: remote)
        XCTAssertTrue(waiting.awaitsVerification)
        // A server that does not say is not taken at its word.
        let silent = Check.RemoteAsset(name: "source/frame-1.dng", bytes: 1000, sha256: hashA, isConfirmed: true)
        XCTAssertEqual(Check.verify([frame(1, hash: hashA)], against: [silent]).findings.map(\.problem), [.notVerified])
        // The marker's cheap test counts only what PicPlace has read back.
        XCTAssertEqual(Check.notCovered(local, by: remote).count, 0)
        XCTAssertEqual(Check.notCovered(local, by: remote, verifiedOnly: true).map(\.name), ["source/frame-1.dng"])
    }

    func testEveryFileOnPicPlacePasses() {
        let local = [frame(1, hash: hashA), frame(2, hash: "sha256:" + hashB)]
        let remote = [asset("source/frame-1.dng", hash: hashA), asset("source/frame-2.dng", hash: hashB.uppercased())]
        let verdict = Check.verify(local, against: remote)
        XCTAssertTrue(verdict.passes)
        XCTAssertEqual(verdict.verified.count, 2)
        XCTAssertTrue(verdict.findings.isEmpty)
    }

    func testEachWayOfNotBeingThereIsNamed() {
        let local = [
            frame(1, hash: hashA),                 // not on PicPlace
            frame(2, hash: hashA),                 // pending
            frame(3, bytes: 999, hash: hashA),     // another size
            frame(4, hash: hashA),                 // same size, other bytes
            frame(5, hash: nil),                   // never hashed here
        ]
        let remote = [
            asset("source/frame-2.dng", bytes: nil, hash: hashA, confirmed: false),
            asset("source/frame-3.dng", hash: hashA),
            asset("source/frame-4.dng", hash: hashB),
            asset("source/frame-5.dng", hash: hashA),
        ]
        let verdict = Check.verify(local, against: remote)
        XCTAssertFalse(verdict.passes)
        XCTAssertTrue(verdict.verified.isEmpty)
        XCTAssertEqual(verdict.findings.map(\.problem), [.notOnPicPlace, .notConfirmed, .sizeDiffers, .contentDiffers, .notHashed])
        XCTAssertEqual(verdict.counts()[.notOnPicPlace], 1)
    }

    func testAnyConfirmedRowMatchingPasses() {
        // A re-negotiated path can list a stale pending row beside the good one.
        let local = [frame(1, hash: hashA)]
        let remote = [
            asset("source/frame-1.dng", bytes: nil, hash: hashB, confirmed: false),
            asset("source/frame-1.dng", hash: hashA),
        ]
        XCTAssertTrue(Check.verify(local, against: remote).passes)
    }

    func testServerExtrasAreNotThisTestsBusiness() {
        let local = [frame(1, hash: hashA)]
        let remote = [asset("source/frame-1.dng", hash: hashA), asset("blends/old.mp4", hash: hashC), asset("records.aar", hash: hashB)]
        XCTAssertTrue(Check.verify(local, against: remote).passes)
    }

    func testPassesPerKind() {
        let blend = Check.LocalFile(name: "blends/new.mp4", kind: .blend, bytes: 5000, sha256: hashC)
        let local = [frame(1, hash: hashA), blend]
        let remote = [asset("source/frame-1.dng", hash: hashA)]
        let verdict = Check.verify(local, against: remote)
        // The blend rendered after the upload is the case the old count missed.
        XCTAssertFalse(verdict.passes)
        XCTAssertTrue(verdict.passes(.source))
        XCTAssertFalse(verdict.passes(.blend))
        XCTAssertEqual(verdict.verified(.source).map(\.name), ["source/frame-1.dng"])
        XCTAssertEqual(verdict.findings(.blend).map(\.problem), [.notOnPicPlace])
    }

    func testCoverageIsNamesAndSizes() {
        let local = [frame(1), frame(2), frame(3, bytes: 42)]
        let remote = [
            asset("source/frame-1.dng", hash: nil),
            asset("source/frame-2.dng", bytes: nil, hash: nil, confirmed: false),
            asset("source/frame-3.dng", bytes: 41, hash: nil),
        ]
        XCTAssertEqual(Check.notCovered(local, by: remote).map(\.name), ["source/frame-2.dng", "source/frame-3.dng"])
    }

    func testDigestIsOrderFreeAndSeesEveryChange() {
        let one = [frame(1), frame(2)]
        XCTAssertEqual(Check.digest(one), Check.digest(one.reversed()))
        XCTAssertNotEqual(Check.digest(one), Check.digest([frame(1), frame(2, bytes: 1001)]))
        XCTAssertNotEqual(Check.digest(one), Check.digest([frame(1), frame(3)]))
        XCTAssertNotEqual(Check.digest(one), Check.digest(one + [Check.LocalFile(name: "blends/x.mp4", kind: .blend, bytes: 1)]))
        // Hashes are the full test's business, not the marker's.
        XCTAssertEqual(Check.digest([frame(1, hash: hashA)]), Check.digest([frame(1, hash: hashB)]))
        XCTAssertEqual(Check.digest([]).count, 64)
    }

    func testReplaceableOnlyWherePicPlaceHoldsTheRecordedOriginal() {
        let remote = [
            asset("source/frame-1.dng", hash: hashA),   // PicPlace = recorded: this copy changed
            asset("source/frame-2.dng", hash: hashB),   // PicPlace ≠ recorded: PicPlace's is the odd one
            asset("source/frame-3.dng", hash: hashA),   // this copy still matches the record
            asset("source/frame-4.dng", bytes: nil, hash: hashA, confirmed: false),
        ]
        let recorded = ["source/frame-1.dng": "sha256:" + hashA, "source/frame-2.dng": hashA,
                        "source/frame-3.dng": hashA, "source/frame-4.dng": hashA]
        let current = ["source/frame-1.dng": hashC, "source/frame-2.dng": hashC, "source/frame-3.dng": hashA]
        let names = ["source/frame-1.dng", "source/frame-2.dng", "source/frame-3.dng", "source/frame-4.dng", "source/frame-5.dng"]
        // 2: PicPlace's copy is the odd one out · 3: this copy is unchanged ·
        // 4: PicPlace's copy never confirmed · 5: nothing recorded here.
        XCTAssertEqual(Check.replaceable(names, recorded: recorded, current: current, remote: remote), ["source/frame-1.dng"],
                       "only a confirmed copy that matches the capture-time hash replaces this device's")
    }

    func testNormalizedHashes() {
        XCTAssertEqual(Check.normalized("sha256:" + hashA.uppercased()), hashA)
        XCTAssertNil(Check.normalized(nil))
        XCTAssertNil(Check.normalized(""))
        XCTAssertNil(Check.normalized("sha256:abc"))
        XCTAssertNil(Check.normalized(String(repeating: "z", count: 64)))
    }
}
