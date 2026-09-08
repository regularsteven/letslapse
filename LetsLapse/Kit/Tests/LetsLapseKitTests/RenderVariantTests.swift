import XCTest
@testable import LetsLapseKit

/// The variant registry's invariants, and the tone curve's arithmetic.
///
/// Most of these guard a PROCESS rather than a computation: the registry is
/// append-only, and the value of that promise is exactly the value of these
/// tests failing when somebody breaks it.
final class RenderVariantTests: XCTestCase {

    // MARK: - The registry's promises

    func testEveryVariantIdIsUnique() {
        let ids = RenderVariantRegistry.all.map { $0.id.lowercased() }
        XCTAssertEqual(Set(ids).count, ids.count,
                       "a repeated id makes every ledger row naming it ambiguous")
    }

    func testEveryVariantSaysWhatItIsTesting() {
        for variant in RenderVariantRegistry.all {
            XCTAssertFalse(variant.title.isEmpty, "\(variant.id) has no title")
            XCTAssertFalse(
                variant.hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(variant.id) has no hypothesis — a result without one is a number nobody can act on")
        }
    }

    func testTheBaselineExistsAndChangesNothing() {
        let baseline = RenderVariantRegistry.baseline
        XCTAssertEqual(baseline.id, RenderVariantRegistry.baselineID)
        // Every other variant is read as a delta from this one, so it has to
        // be a true no-op or the whole ledger is measured from a moving line.
        XCTAssertEqual(baseline.axes, RenderAxes())
        XCTAssertEqual(baseline.axes.toneCurves, .ignore)
        XCTAssertEqual(baseline.axes.highlightsScale, 1)
        XCTAssertEqual(baseline.axes.shadowsScale, 1)
    }

    /// The append-only rule, pinned the only way a test can pin it: the axes
    /// of every variant that has been MEASURED are written down here too, so
    /// editing one in the registry fails here and the author has to decide
    /// deliberately whether they meant to invalidate the ledger.
    func testMeasuredVariantsHaveNotBeenRedefined() {
        let frozen: [String: String] = [
            "A": "decode=bradford curves=ignore",
            "B": "decode=bradford curves=imageAndLook",
            "C": "decode=dcp curves=ignore",
            "D": "decode=bradford curves=ignore shadows×0.70",
            "D1": "decode=bradford curves=imageAndLook shadows×0.70",
            "E": "decode=bradford curves=imageAndLook shadows×0.70 exposure-0.47EV",
            "F": "decode=bradford curves=imageAndLook shadows×0.70 exposure-0.47EV dehaze×1.00",
            "F1": "decode=bradford curves=imageAndLook shadows×0.70 exposure-0.47EV dehaze×0.50",
            "F2": "decode=bradford curves=imageAndLook shadows×0.70 exposure-0.47EV dehaze×2.00",
            "G": "decode=bradford curves=imageAndLook dehaze×2.00",
        ]
        for (id, summary) in frozen {
            guard let variant = RenderVariantRegistry.variant(id: id) else {
                XCTFail("variant \(id) has been REMOVED — the ledger still names it")
                continue
            }
            XCTAssertEqual(
                variant.axes.summary, summary,
                """
                variant \(id) has been redefined. Its numbers in \
                docs/render-variants/ledger.md were measured against the old \
                axes and now mean nothing. Add the next variant instead \
                (D1 → D1.5); if you really mean to retire this one, update \
                the ledger in the same commit.
                """)
        }
    }

    func testAnUnknownIdResolvesToTheBaselineRatherThanFailing() {
        XCTAssertNil(RenderVariantRegistry.variant(id: "nonexistent"))
        UserDefaults.standard.set("nonexistent", forKey: RenderVariantRegistry.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: RenderVariantRegistry.defaultsKey) }
        XCTAssertEqual(RenderVariantRegistry.current.id, RenderVariantRegistry.baselineID)
    }

    func testSelectionRoundTrips() {
        defer { UserDefaults.standard.removeObject(forKey: RenderVariantRegistry.defaultsKey) }
        let target = try? XCTUnwrap(RenderVariantRegistry.variant(id: "B"))
        RenderVariantRegistry.current = target!
        XCTAssertEqual(RenderVariantRegistry.current.id, "B")
    }

    func testIdLookupIsCaseInsensitive() {
        XCTAssertEqual(RenderVariantRegistry.variant(id: "d1")?.id, "D1")
    }

    func testAxesSummaryNamesEveryNonDefaultAxis() {
        let axes = RenderAxes(
            decodePath: .cirawFilter, toneCurves: .image,
            highlightsScale: 0.5, shadowsScale: 0.7, honoursWhiteBalance: false)
        let summary = axes.summary
        for expected in ["decode=ciraw", "curves=image", "highlights×0.50", "shadows×0.70", "wb=asShot"] {
            XCTAssertTrue(summary.contains(expected), "\(expected) missing from \(summary)")
        }
    }

    // MARK: - Tone curve

    func testAnIdentityCurveIsRecognisedWhateverItsPointCount() {
        let straight = ToneCurve(lightroomPoints: [(0, 0), (64, 64), (128, 128), (255, 255)])
        XCTAssertTrue(straight.isIdentity)
        XCTAssertEqual(straight.value(at: 0.37), 0.37, accuracy: 1e-12)
    }

    func testAdobeColorsCurveLiftsHighlightsAndDeepensShadows() {
        // The real curve out of the sidecar.
        let curve = ToneCurve(lightroomPoints: [
            (0, 0), (22, 16), (40, 35), (127, 127), (224, 230), (240, 246), (255, 255)])
        XCTAssertFalse(curve.isIdentity)
        XCTAssertEqual(curve.value(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: 1), 1, accuracy: 1e-9)
        // Through a control point.
        XCTAssertEqual(curve.value(at: 22.0 / 255), 16.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: 224.0 / 255), 230.0 / 255, accuracy: 1e-9)
        // Shadows down, highlights up — the S.
        XCTAssertLessThan(curve.value(at: 0.10), 0.10)
        XCTAssertGreaterThan(curve.value(at: 0.90), 0.90)
    }

    func testTheCurveNeverReverses() {
        // The reason for a monotone interpolant: an ordinary cubic through
        // these points overshoots and produces a stretch where more light in
        // gives less light out, which reads as a dark rim on a bright edge.
        let curve = ToneCurve(lightroomPoints: [
            (0, 0), (22, 16), (40, 35), (127, 127), (224, 230), (240, 246), (255, 255)])
        var previous = -1.0
        for step in 0...2000 {
            let value = curve.value(at: Double(step) / 2000)
            XCTAssertGreaterThanOrEqual(value, previous - 1e-12, "curve reversed at \(step)")
            previous = value
        }
    }

    func testTheCurveStaysInRange() {
        let curve = ToneCurve(lightroomPoints: [(0, 0), (10, 40), (245, 215), (255, 255)])
        for step in 0...500 {
            let value = curve.value(at: Double(step) / 500)
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
    }

    func testPointsAreSortedAndDeduplicated() {
        let curve = ToneCurve(lightroomPoints: [(255, 255), (0, 0), (128, 100), (128, 90)])
        XCTAssertEqual(curve.points.map(\.input), [0, 128.0 / 255, 1])
    }

    func testLookupTableMatchesDirectEvaluation() {
        let curve = ToneCurve(lightroomPoints: [(0, 0), (64, 48), (192, 208), (255, 255)])
        let table = curve.lookupTable(size: 256)
        XCTAssertEqual(table.count, 256)
        for index in stride(from: 0, to: 256, by: 17) {
            XCTAssertEqual(table[index], curve.value(at: Double(index) / 255), accuracy: 1e-12)
        }
    }

    func testAnIdentityCurvesTableIsTheRamp() {
        let table = ToneCurve.identity.lookupTable(size: 256)
        XCTAssertEqual(table.first, 0)
        XCTAssertEqual(table.last, 1)
        XCTAssertEqual(table[128], 128.0 / 255, accuracy: 1e-12)
    }
}
