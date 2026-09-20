import XCTest
import CoreGraphics
@testable import LetsLapseKit

/// The least-crop model against the numbers the brief and the prototype
/// review established on the scene kit (docs/shapemation/prototype-review.md
/// §3.4): the bad-apple ten into 3:2 sorted by the rendered share reproduce
/// the brief's §4 table, one pass takes the same four the fixpoint does, the
/// clean approach's ends fall to nothing under the trend, keys stay with
/// their photo through a reject, the share is bounded, and the plan's
/// windows land exactly on the rect.
final class ShapemationLeastCropTests: XCTestCase {
    typealias LC = ShapemationLeastCrop

    /// `docs/design/kit/compositions/manifest.json`: id, frame, the tram face's bbox.
    private static let badApple: [(String, Double, Double, Double, Double, Double, Double)] = [
        ("mixed.random.01", 1200, 1200, 262.2, 724.7, 51.5, 73.9),
        ("mixed.random.02", 1200, 1200, 282.8, 711.1, 51.6, 74),
        ("mixed.random.05", 1600, 1200, 1303.1, 712.4, 59.5, 85.4),
        ("mixed.random.07", 1800, 1200, 469.3, 667.6, 76.7, 96.8),
        ("mixed.random.10", 1200, 1200, 168.3, 678.6, 85.9, 123.2),
        ("mixed.random.11", 1200, 1200, 205.3, 680.2, 105.5, 133.2),
        ("mixed.random.13", 1800, 1200, 367.6, 690.5, 128.8, 162.6),
        ("mixed.random.21", 1800, 1200, 374.4, 602.9, 165.7, 237.8),
        ("mixed.random.26", 1600, 1200, 194.8, 565.6, 205, 294.1),
        ("mixed.random.27", 1600, 1200, 396.1, 737, 234.9, 296.6),
    ]
    private static let cleanApproach: [(String, Double, Double, Double, Double, Double, Double)] = [
        ("city.clear.approach.01", 1800, 1200, 740, 690.2, 73.7, 105.7),
        ("city.clear.approach.02", 1800, 1200, 765.5, 675.6, 89, 127.7),
        ("city.clear.approach.03", 1800, 1200, 791.9, 657.6, 108, 155),
        ("city.clear.approach.04", 1800, 1200, 815.9, 636.6, 130.1, 186.7),
        ("city.clear.approach.05", 1800, 1200, 839, 611.6, 156.5, 224.6),
        ("city.clear.approach.06", 1800, 1200, 863.2, 583.7, 186, 266.8),
        ("city.clear.approach.07", 1800, 1200, 884.6, 551.7, 219.7, 315.3),
        ("city.clear.approach.08", 1800, 1200, 907.1, 516.2, 257.2, 369),
        ("city.clear.approach.09", 1800, 1200, 927.1, 477.7, 297.7, 427.1),
        ("city.clear.approach.10", 1800, 1200, 946.3, 435.8, 341.9, 490.5),
        ("city.clear.approach.11", 1800, 1200, 966.3, 389.9, 390.4, 560.1),
        ("city.clear.approach.12", 1800, 1200, 983.9, 341, 441.9, 634.1),
    ]

    /// A stable id per composition, so the tables can name photos.
    private static func id(_ name: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in name.utf8.enumerated() { bytes[i % 16] ^= b &+ UInt8(i) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40; bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func photos(_ specs: [(String, Double, Double, Double, Double, Double, Double)]) -> [LC.Photo] {
        specs.enumerated().map { i, s in
            LC.Photo(id: id(s.0), frame: CGSize(width: s.1, height: s.2), bounds: CGRect(x: s.3, y: s.4, width: s.5, height: s.6), captureOrder: i)
        }
    }

    private static func items(_ specs: [(String, Double, Double, Double, Double, Double, Double)]) -> [ShapemationItem] {
        specs.enumerated().map { i, s in
            let frame = CGSize(width: s.1, height: s.2)
            let corners = [CGPoint(x: s.3, y: s.4), CGPoint(x: s.3 + s.5, y: s.4), CGPoint(x: s.3 + s.5, y: s.4 + s.6), CGPoint(x: s.3, y: s.4 + s.6)]
            let shape = DetectedShape.quad(corners: corners, frame: frame)
            return ShapemationItem(id: id(s.0), title: s.0, imageURL: URL(fileURLWithPath: "/x/\(s.0).svg"), pixelSize: frame, shape: shape, captureIndex: i)
        }
    }

    private static let threeByTwo = CGSize(width: 1800, height: 1200)

    /// The prototype's defaults with the let-go off — the brief's own model.
    private func briefSettings(autoReject: Bool, fixpoint: Bool = false, tolerance: LC.Tolerance = .normal, ends: LC.Settings.Ends = .median) -> LC.Settings {
        LC.Settings(outputSize: Self.threeByTwo, tolerance: tolerance, window: 5, ends: ends, letGo: 0, fixpoint: fixpoint, autoReject: autoReject)
    }

    private func name(_ id: UUID) -> String {
        (Self.badApple + Self.cleanApproach).first { Self.id($0.0) == id }?.0 ?? id.uuidString
    }

    // MARK: - The brief's table

    func testBadAppleSortedByRenderedShareReproducesTheBriefsTable() {
        let board = LC.board(Self.photos(Self.badApple), settings: briefSettings(autoReject: false))
        XCTAssertEqual(board.rows.map { name($0.id) },
                       ["mixed.random.05", "mixed.random.07", "mixed.random.01", "mixed.random.02", "mixed.random.13",
                        "mixed.random.10", "mixed.random.11", "mixed.random.21", "mixed.random.26", "mixed.random.27"],
                       "smallest first is by the rendered share: the 4:3 outlier's frame lifts it to the front, the squares past the 3:2s")
        // model.js σ-sorted, prototype-review.md §3.4 — the brief's 95 / 20 / 13 / 4 / 11 / 46 / 0 / 21 / 37 / 44.
        let expected: [String: Double] = [
            "mixed.random.05": 0.946, "mixed.random.07": 0.196, "mixed.random.01": 0.129, "mixed.random.02": 0.045,
            "mixed.random.13": 0.115, "mixed.random.10": 0.462, "mixed.random.11": 0.000, "mixed.random.21": 0.207,
            "mixed.random.26": 0.372, "mixed.random.27": 0.440,
        ]
        for row in board.rows {
            XCTAssertEqual(row.evaluation.crop, expected[name(row.id)]!, accuracy: 0.006, name(row.id))
        }
        XCTAssertEqual(board.meanCrop, 0.291, accuracy: 0.005)
        XCTAssertEqual(board.sumJ, 1.06, accuracy: 0.03, "Σ J on the natural places, discounted by the rendered share")
        XCTAssertEqual(board.red, 4, "05, 10, 26 and 27 read red on the median path")
        XCTAssertTrue(board.rejected.isEmpty)
    }

    func testOnePassAndTheFixpointTakeTheSameFourFromTheBadApple() {
        for fixpoint in [false, true] {
            let board = LC.board(Self.photos(Self.badApple), settings: briefSettings(autoReject: true, fixpoint: fixpoint))
            XCTAssertEqual(Set(board.rejected.map { name($0.id) }), ["mixed.random.05", "mixed.random.10", "mixed.random.26", "mixed.random.27"], "fixpoint \(fixpoint)")
            XCTAssertEqual(board.rows.count, 6)
            XCTAssertEqual(board.red, 0)
            XCTAssertFalse(board.floorHit)
            XCTAssertEqual(board.meanCrop, 0.139, accuracy: 0.006, "the six kept, re-smoothed without the four")
            XCTAssertLessThan(board.sumJ, 0.6, "the jump was the outlier's: 1.06 before the reject")
            for r in board.rejected { XCTAssertTrue(r.rejected); XCTAssertFalse(r.rejectedByHand); XCTAssertEqual(r.index, -1) }
        }
    }

    func testTheFloorStopsARejectFromEmptyingTheSequence() {
        for tolerance in LC.Tolerance.allCases {
            let board = LC.board(Self.photos(Self.badApple), settings: briefSettings(autoReject: true, fixpoint: true, tolerance: tolerance))
            XCTAssertGreaterThanOrEqual(board.rows.count, LC.floor(of: 10), "\(tolerance)")
            XCTAssertEqual(board.rows.count + board.rejected.count, 10, "\(tolerance): every photo is kept or rejected, never lost")
        }
        XCTAssertEqual(LC.floor(of: 10), 5)
        XCTAssertEqual(LC.floor(of: 83), 42)
        XCTAssertEqual(LC.floor(of: 4), 3)
        // Strict on the ten: five reds after the first pass and a floor of five — the floor is hit and the sequence stays at five.
        let strict = LC.board(Self.photos(Self.badApple), settings: briefSettings(autoReject: true, fixpoint: true, tolerance: .strict))
        XCTAssertEqual(strict.rows.count, 5)
        XCTAssertTrue(strict.floorHit)
        // None rejects nothing.
        let none = LC.board(Self.photos(Self.badApple), settings: briefSettings(autoReject: true, fixpoint: true, tolerance: .none))
        XCTAssertEqual(none.rows.count, 10)
        XCTAssertEqual(none.red, 0)
    }

    func testTheCleanApproachsEndsFallToNothingUnderTheTrend() {
        let median = LC.board(Self.photos(Self.cleanApproach), settings: briefSettings(autoReject: false, ends: .median))
        XCTAssertEqual(median.rows.first!.evaluation.crop, 0.080, accuracy: 0.005, "a plain running median charges the first photo 8 %")
        XCTAssertEqual(median.rows.last!.evaluation.crop, 0.131, accuracy: 0.005, "and the last 13 %")
        XCTAssertEqual(median.meanCrop, 0.027, accuracy: 0.004)
        let trend = LC.board(Self.photos(Self.cleanApproach), settings: briefSettings(autoReject: false, ends: .trend))
        XCTAssertLessThan(trend.rows.first!.evaluation.crop, 0.01)
        XCTAssertLessThan(trend.rows.last!.evaluation.crop, 0.01)
        XCTAssertLessThan(trend.meanCrop, 0.005)
        XCTAssertEqual(median.rows.map(\.id), trend.rows.map(\.id), "the ends change nothing about the order")
        XCTAssertEqual(median.sizeBreaks, 0, "an approach sorted smallest first grows monotonically")
    }

    // MARK: - Keys, the let-go, the sorts

    func testAKeyStaysWithItsPhotoThroughAReject() {
        let photos = Self.photos(Self.badApple)
        var settings = briefSettings(autoReject: false)
        let keyed = Self.id("mixed.random.13"), place = CGPoint(x: 0.30, y: 0.60)
        settings.setKey(LC.Key(id: keyed, place: place))
        let before = LC.board(photos, settings: settings)
        let rowBefore = before.rows.first { $0.id == keyed }!
        XCTAssertEqual(rowBefore.index, 4)
        XCTAssertEqual(Double(rowBefore.target.x), 0.30, accuracy: 1e-9)
        XCTAssertEqual(Double(rowBefore.target.y), 0.60, accuracy: 1e-9)
        XCTAssertNotNil(rowBefore.key)
        // Reject the photo before it by hand: the key's photo moves up one slot and keeps its place.
        settings.reject(Self.id("mixed.random.02"))
        let after = LC.board(photos, settings: settings)
        let rowAfter = after.rows.first { $0.id == keyed }!
        XCTAssertEqual(rowAfter.index, 3)
        XCTAssertEqual(Double(rowAfter.target.x), 0.30, accuracy: 1e-9)
        XCTAssertEqual(Double(rowAfter.target.y), 0.60, accuracy: 1e-9)
        XCTAssertEqual(after.rejected.map { name($0.id) }, ["mixed.random.02"])
        XCTAssertTrue(after.rejected[0].rejectedByHand)
        // The path bends through the key and is eased back to the automatic path at the ends.
        XCTAssertEqual(Double(after.path[3].x), 0.30, accuracy: 1e-9)
        XCTAssertEqual(Double(after.path[0].x), Double(LC.board(photos, settings: { var s = settings; s.keys = []; return s }()).path[0].x), accuracy: 1e-9)
        // Keep anyway lifts a hand reject.
        settings.keepAnyway(Self.id("mixed.random.02"))
        XCTAssertEqual(LC.board(photos, settings: settings).rows.count, 10)
    }

    func testAKeysZoomRaisesThatPhotosOwnCrop() {
        let photos = Self.photos(Self.badApple)
        var settings = briefSettings(autoReject: false)
        let keyed = Self.id("mixed.random.11")
        let plain = LC.board(photos, settings: settings).rows.first { $0.id == keyed }!
        settings.setKey(LC.Key(id: keyed, place: plain.path, zoom: 1.5))
        let zoomed = LC.board(photos, settings: settings).rows.first { $0.id == keyed }!
        XCTAssertEqual(zoomed.evaluation.zoom, plain.evaluation.zoom * 1.5, accuracy: 1e-9)
        XCTAssertEqual(zoomed.evaluation.crop, 1 - 1 / (2.25 * plain.evaluation.zoom * plain.evaluation.zoom), accuracy: 1e-9)
        XCTAssertEqual(zoomed.verdict, .red, "a ×1.5 zoom is a 56 % crop")
    }

    func testTheLetGoPullsASmallShapeAndLeavesABigOne() {
        // Two photos of one frame: a small shape hard left and a huge one hard left.
        let frame = CGSize(width: 1000, height: 1000)
        let small = LC.Photo(id: UUID(), frame: frame, bounds: CGRect(x: 100, y: 450, width: 60, height: 60), captureOrder: 0)
        let big = LC.Photo(id: UUID(), frame: frame, bounds: CGRect(x: 50, y: 100, width: 800, height: 800), captureOrder: 1)
        let centred = LC.Photo(id: UUID(), frame: frame, bounds: CGRect(x: 470, y: 470, width: 60, height: 60), captureOrder: 2)
        let square = CGSize(width: 1080, height: 1080)
        var pulled = LC.Settings(outputSize: square, tolerance: .normal, letGo: 0, autoReject: false)
        pulled.window = 3
        let all = LC.board([small, centred, big], settings: pulled)
        let bigPulled = all.rows.first { $0.id == big.id }!
        XCTAssertEqual(bigPulled.target, bigPulled.path, "γ = 0: pulled all the way to the path")
        var letGo = pulled; letGo.letGo = 1
        let let1 = LC.board([small, centred, big], settings: letGo)
        let bigLetGo = let1.rows.first { $0.id == big.id }!
        let natural = LC.natural(big, aspect: 1).place
        // σ = 0.8: the big shape moves only a fifth of the way from where it fell.
        XCTAssertEqual(Double(bigLetGo.target.x), Double(natural.x) + (Double(bigLetGo.path.x) - Double(natural.x)) * 0.2, accuracy: 1e-9)
        XCTAssertLessThan(bigLetGo.evaluation.crop, bigPulled.evaluation.crop)
        let smallLetGo = let1.rows.first { $0.id == small.id }!, smallPulled = all.rows.first { $0.id == small.id }!
        XCTAssertEqual(smallLetGo.evaluation.crop, smallPulled.evaluation.crop, accuracy: 0.03, "a 6 % shape is pulled nearly all the way either way")
        XCTAssertEqual(LC.Tolerance.strict.letGo, 1)
        XCTAssertEqual(LC.Tolerance.loose.letGo, 0)
        XCTAssertEqual(LC.Settings(outputSize: square, tolerance: .normal).effectiveLetGo, 0.5)
    }

    func testTheSortsAndTheAlignmentChain() {
        let photos = Self.photos(Self.badApple)
        let smallest = LC.ordered(photos, sort: .smallestFirst, aspect: 1.5)
        let largest = LC.ordered(photos, sort: .largestFirst, aspect: 1.5)
        XCTAssertEqual(smallest.map(\.id), largest.reversed().map(\.id))
        XCTAssertEqual(LC.ordered(photos, sort: .captureOrder, aspect: 1.5).map(\.captureOrder), Array(0..<10))
        let chain = LC.ordered(photos, sort: .alignment, aspect: 1.5, chainWidth: 3)
        XCTAssertEqual(Set(chain.map(\.id)), Set(photos.map(\.id)), "a permutation")
        XCTAssertEqual(chain.first?.id, smallest.first?.id, "from the smallest")
        // Each step is one of the next three by size: never more than two size ranks skipped.
        let rank = Dictionary(uniqueKeysWithValues: smallest.enumerated().map { ($1.id, $0) })
        var placed = Set<UUID>()
        for p in chain {
            let unplacedAhead = smallest.filter { !placed.contains($0.id) && rank[$0.id]! < rank[p.id]! }.count
            XCTAssertLessThan(unplacedAhead, 3, name(p.id))
            placed.insert(p.id)
        }
        // On the clean approach every neighbour is also the nearest, so the chain IS the size order.
        let clean = Self.photos(Self.cleanApproach)
        XCTAssertEqual(LC.ordered(clean, sort: .alignment, aspect: 1.5).map(\.id), LC.ordered(clean, sort: .smallestFirst, aspect: 1.5).map(\.id))
        XCTAssertEqual(LC.sizeSpread(of: clean, aspect: 1.5), 6.0, accuracy: 0.05, "13 % → 79 %: an approach")
        XCTAssertEqual(LC.dominantAspect(of: photos)!, 1.0, accuracy: 1e-9, "four squares beat three 3:2s and three 4:3s")
        XCTAssertEqual(LC.dominantAspect(of: clean)!, 1.5, accuracy: 1e-9)
    }

    // MARK: - Shares and the rect

    func testTheShareIsBoundedWhicheverWayTheShapeLies() {
        let portrait = CGSize(width: 3024, height: 4032)
        let door = LC.Photo(id: UUID(), frame: portrait, bounds: CGRect(x: 1300, y: 200, width: 500, height: 3600), captureOrder: 0)
        XCTAssertEqual(door.share, 3600 / 4032, accuracy: 1e-9, "a door filling the height reads 89 %, not 119 %")
        let tram = LC.Photo(id: UUID(), frame: portrait, bounds: CGRect(x: 1187, y: 1725, width: 702, height: 976), captureOrder: 0)
        XCTAssertEqual(tram.share, 976 / 4032, accuracy: 1e-9)
        let wide = LC.Photo(id: UUID(), frame: CGSize(width: 4032, height: 3024), bounds: CGRect(x: 0, y: 1000, width: 4000, height: 900), captureOrder: 0)
        XCTAssertEqual(wide.share, 4000 / 4032, accuracy: 1e-9, "a facade across a landscape frame")
        // The Kit's sort key agrees, for a quad and for an ellipse.
        let corners = [CGPoint(x: 1300, y: 200), CGPoint(x: 1800, y: 200), CGPoint(x: 1800, y: 3800), CGPoint(x: 1300, y: 3800)]
        let quad = ShapemationItem(title: "door", imageURL: URL(fileURLWithPath: "/x"), pixelSize: portrait, shape: DetectedShape.quad(corners: corners, frame: portrait))
        XCTAssertEqual(ShapemationSort.share(of: quad), 3600 / 4032, accuracy: 1e-9)
        let plate = DetectedShape.ellipse(centre: CGPoint(x: 1512, y: 2016), semiAxisX: 1400, semiAxisY: 1400, rotation: 0, frame: portrait)
        XCTAssertEqual(ShapemationSort.share(of: ShapemationItem(title: "plate", imageURL: URL(fileURLWithPath: "/x"), pixelSize: portrait, shape: plate)),
                       2800 / 3024, accuracy: 1e-6)
        // Rendered: a square photo's 6.2 % shape into 3:2 shows at 9.3 %.
        let square = LC.Photo(id: UUID(), frame: CGSize(width: 1200, height: 1200), bounds: CGRect(x: 262, y: 725, width: 51.5, height: 74), captureOrder: 0)
        XCTAssertEqual(LC.renderedShare(square, aspect: 1.5), 74 / 1200 * 1.5, accuracy: 1e-9)
        XCTAssertEqual(LC.renderedShare(square, aspect: 1.0), 74 / 1200, accuracy: 1e-9)
        // A 3:4 photo into 4:5 loses 6.25 % to the aspect before any shift.
        let threeByFour = LC.Photo(id: UUID(), frame: portrait, bounds: CGRect(x: 1400, y: 1900, width: 200, height: 200), captureOrder: 0)
        let ev = LC.evaluate(threeByFour, aspect: 0.8, target: LC.natural(threeByFour, aspect: 0.8).place)
        XCTAssertEqual(ev.aspectLoss, 1 - 1 / (0.8 / 0.75), accuracy: 1e-9)
        XCTAssertEqual(ev.crop, 0, accuracy: 1e-9)
        XCTAssertEqual(ev.loss, ev.aspectLoss, accuracy: 1e-9)
    }

    func testThePlansWindowsLandOnTheRect() throws {
        let items = Self.items(Self.badApple)
        let settings = briefSettings(autoReject: true)
        let plan = try XCTUnwrap(ShapemationPlan.make(items: items, mode: .leastCrop, leastCrop: settings))
        let board = try XCTUnwrap(plan.leastCrop)
        XCTAssertEqual(plan.placements.count, board.rows.count)
        XCTAssertEqual(plan.placements.map(\.itemID), board.rows.map(\.id), "the placements follow the board's play order")
        XCTAssertEqual(plan.canvas, CGRect(x: 0, y: 0, width: 1800, height: 1200))
        for (placement, row) in zip(plan.placements, board.rows) {
            let item = items.first { $0.id == placement.itemID }!
            let W = Double(item.pixelSize.width), H = Double(item.pixelSize.height)
            let win = row.evaluation.window
            let tl = placement.transform.apply(CGPoint(x: Double(win.minX) * W, y: Double(win.minY) * H))
            let br = placement.transform.apply(CGPoint(x: Double(win.maxX) * W, y: Double(win.maxY) * H))
            XCTAssertEqual(Double(tl.x), 0, accuracy: 1e-6); XCTAssertEqual(Double(tl.y), 0, accuracy: 1e-6)
            XCTAssertEqual(Double(br.x), 1800, accuracy: 1e-3); XCTAssertEqual(Double(br.y), 1200, accuracy: 1e-3)
            // The shape's centre lands on the target.
            let c = placement.transform.apply(CGPoint(x: Double(row.photo.bounds.midX), y: Double(row.photo.bounds.midY)))
            XCTAssertEqual(Double(c.x), Double(placement.target.x), accuracy: 1.5, "\(name(row.id))")
            XCTAssertEqual(Double(c.y), Double(placement.target.y), accuracy: 1.5, "\(name(row.id))")
            XCTAssertEqual(placement.crop?.id, row.id)
            XCTAssertEqual(placement.feasibility.verdict, .fits)
        }
        XCTAssertNil(ShapemationPlan.make(items: items, mode: .leastCrop), "the settings are required")
        XCTAssertFalse(ShapemationMode.leastCrop.accumulates)
        XCTAssertTrue(ShapemationMode.leastCrop.hasBoard)
    }

    // MARK: - Settings on disk, holds by photo

    func testSettingsRoundTripAndReadTolerantly() throws {
        var s = LC.Settings(outputSize: CGSize(width: 1080, height: 1350), tolerance: .loose, window: 7, ends: .trend, ease: .inOut,
                            letGo: 0.25, fixpoint: false, autoReject: false, sort: .alignment, chainWidth: 5, sameAngle: true)
        let id = UUID()
        s.setKey(LC.Key(id: id, place: CGPoint(x: 0.3, y: 0.7), zoom: 1.2))
        s.reject(UUID()); s.keepAnyway(UUID())
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(LC.Settings.self, from: data)
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.key(for: id)?.zoom, 1.2)
        let foreign = """
        {"outputSize":[1080,1350],"tolerance":"fierce","ends":"spline","window":9,"ease":"bounce","sort":"byMoonPhase","keys":[{"id":"\(id.uuidString)","place":[0.1,0.2]}]}
        """
        let tolerant = try JSONDecoder().decode(LC.Settings.self, from: Data(foreign.utf8))
        XCTAssertEqual(tolerant.tolerance, .normal)
        XCTAssertEqual(tolerant.ends, .median)
        XCTAssertEqual(tolerant.window, 5)
        XCTAssertEqual(tolerant.ease, .linear)
        XCTAssertEqual(tolerant.sort, .smallestFirst)
        XCTAssertEqual(tolerant.key(for: id)?.zoom, 1)
        XCTAssertTrue(tolerant.fixpoint); XCTAssertTrue(tolerant.autoReject)
    }

    func testAPhotosOwnHoldWinsOverTheRamp() throws {
        var timing = ShapemationTiming(fps: 25, each: .seconds(1), ramp: .init(start: .seconds(2), middle: nil, end: .seconds(0.5)))
        let ids = (0..<5).map { _ in UUID() }
        XCTAssertEqual(timing.holds(for: ids), timing.holds(count: 5))
        timing.setOverride(.frames(3), for: ids[2])
        XCTAssertEqual(timing.holds(for: ids)[2], 3)
        XCTAssertEqual(timing.holds(for: ids)[0], 50)
        XCTAssertEqual(timing.totalFrames(for: ids), timing.totalFrames(count: 5) - timing.holds(count: 5)[2] + 3)
        let data = try JSONEncoder().encode(timing)
        XCTAssertEqual(try JSONDecoder().decode(ShapemationTiming.self, from: data), timing)
        // A record from before the board.
        let old = try JSONDecoder().decode(ShapemationTiming.self, from: Data(#"{"fps":25,"each":{"seconds":1}}"#.utf8))
        XCTAssertNil(old.overrides)
        timing.setOverride(nil, for: ids[2])
        XCTAssertNil(timing.overrides)
        let sort = try JSONDecoder().decode(ShapemationSort.self, from: Data(#""alignment""#.utf8))
        XCTAssertEqual(sort, .alignment)
    }
}
