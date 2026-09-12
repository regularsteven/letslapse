import XCTest
@testable import LetsLapseKit

final class ShapeDetectionModeTests: XCTestCase {
    func testEnginesMapOntoTheFilePass() {
        let standard = ShapeDetectionMode(engine: .standard).settings()
        XCTAssertTrue(standard.regionProposals)
        XCTAssertEqual(standard.regionProposalLongEdges, [1024, 2048])
        XCTAssertFalse(standard.edgeChains)
        XCTAssertEqual(standard.minDiameterFractionOfShortEdge, 0.10)   // the file floor, not the viewfinder's sixth

        XCTAssertFalse(ShapeDetectionMode(engine: .visionOnly).settings().regionProposals)
        XCTAssertEqual(ShapeDetectionMode(engine: .regions1024).settings().regionProposalLongEdges, [1024])
        XCTAssertTrue(ShapeDetectionMode(engine: .edgeChains).settings().edgeChains)
        let chainsOnly = ShapeDetectionMode(engine: .edgeChainsOnly).settings()
        XCTAssertTrue(chainsOnly.edgeChains)
        XCTAssertFalse(chainsOnly.regionProposals)
        // An external engine runs outside the Kit; its settings are the standard file pass (decode size, floor).
        XCTAssertEqual(ShapeDetectionMode(engine: .pythonEdgeDrawing).settings().regionProposalLongEdges, standard.regionProposalLongEdges)
    }

    func testExternalEnginesKnowTheirRigDetector() {
        XCTAssertEqual(ShapeDetectionMode.Engine.pythonReference.externalDetectorID, "opencv-reference")
        XCTAssertEqual(ShapeDetectionMode.Engine.pythonEdgeDrawing.externalDetectorID, "edge-drawing")
        XCTAssertTrue(ShapeDetectionMode.Engine.kitEngines.allSatisfy { $0.externalDetectorID == nil })
        XCTAssertEqual(Set(ShapeDetectionMode.Engine.kitEngines + ShapeDetectionMode.Engine.externalEngines), Set(ShapeDetectionMode.Engine.allCases))
    }

    func testTheDialsStillReachTheKitEngines() {
        var mode = ShapeDetectionMode(engine: .regions1024)
        mode.search.sensitivity = .low
        mode.search.family = .circular
        let s = mode.settings()
        XCTAssertFalse(s.detectQuads)
        XCTAssertEqual(s.contrastAdjustments, [1.0])
        XCTAssertEqual(mode.token, "regions1024 · circular/low/all")
    }

    func testSaveAndLoadRoundTrip() {
        let suite = "ShapeDetectionModeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ShapeDetectionMode.load(from: defaults), .default)
        var mode = ShapeDetectionMode(engine: .edgeChains)
        mode.search.size = .small
        mode.save(to: defaults)
        XCTAssertEqual(ShapeDetectionMode.load(from: defaults), mode)
        // A value written by an older build with an engine this one does not know falls back to the default.
        defaults.set(Data(#"{"engine":"laser","search":{"family":"all","sensitivity":"medium","size":"all"}}"#.utf8), forKey: ShapeDetectionMode.defaultsKey)
        XCTAssertEqual(ShapeDetectionMode.load(from: defaults), .default)
    }
}
