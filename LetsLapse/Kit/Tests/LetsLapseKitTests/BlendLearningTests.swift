import XCTest
@testable import LetsLapseKit

final class BlendLearningTests: XCTestCase {
    private func sample(
        _ frames: Int,
        throttled: Bool = false,
        capped: Bool = false,
        daysAgo: Double = 0
    ) -> BlendLearningSample {
        BlendLearningSample(
            date: Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86_400),
            framesCaptured: frames,
            throttleDetected: throttled,
            capped: capped)
    }

    private let key = BlendProfileKey(
        deviceModel: "iPhone17,1",
        pipeline: "dng",
        thermalBucket: .cool,
        intervalSeconds: 2.0)

    // MARK: Buckets

    func testThermalBucketMapping() {
        XCTAssertEqual(ThermalBucket(thermalState: .nominal), .cool)
        XCTAssertEqual(ThermalBucket(thermalState: .fair), .warm)
        XCTAssertEqual(ThermalBucket(thermalState: .serious), .hot)
        XCTAssertEqual(ThermalBucket(thermalState: .critical), .hot)
    }

    func testThermalBucketFromLoggedNames() {
        XCTAssertEqual(ThermalBucket(thermalStateName: "nominal"), .cool)
        XCTAssertEqual(ThermalBucket(thermalStateName: "fair"), .warm)
        XCTAssertEqual(ThermalBucket(thermalStateName: "serious"), .hot)
        XCTAssertEqual(ThermalBucket(thermalStateName: "critical"), .hot)
        XCTAssertNil(ThermalBucket(thermalStateName: "unknown"))
    }

    func testBucketOrdering() {
        XCTAssertLessThan(ThermalBucket.cool, .warm)
        XCTAssertLessThan(ThermalBucket.warm, .hot)
    }

    // MARK: Profile bookkeeping

    func testProfileTracksBoundsAcrossRingEviction() {
        var profile = BlendLearningProfile(firstSample: sample(30))
        for _ in 0..<(BlendLearningProfile.maxStoredSamples + 10) {
            profile.record(sample(10))
        }
        profile.record(sample(4))
        XCTAssertEqual(profile.samples.count, BlendLearningProfile.maxStoredSamples)
        // The 30-frame run aged out of the ring but stays in the bounds.
        XCTAssertEqual(profile.bestFrames, 30)
        XCTAssertEqual(profile.worstFrames, 4)
        XCTAssertFalse(profile.samples.contains { $0.framesCaptured == 30 })
    }

    func testThinProfileRefusesToPredict() {
        var profile = BlendLearningProfile(firstSample: sample(12))
        XCTAssertNil(profile.safeFrameCount)
        profile.record(sample(12))
        XCTAssertNil(profile.safeFrameCount)
        profile.record(sample(12))
        XCTAssertNotNil(profile.safeFrameCount)
    }

    // MARK: Estimator

    func testSteadyHistoryPredictsUnderTheAchievedCount() throws {
        var profile = BlendLearningProfile(firstSample: sample(20))
        for _ in 0..<9 { profile.record(sample(20)) }
        let safe = try XCTUnwrap(profile.safeFrameCount)
        XCTAssertEqual(safe, 17) // floor(20 × 0.85)
    }

    func testPredictionNeverExceedsBestObserved() throws {
        var profile = BlendLearningProfile(firstSample: sample(2))
        profile.record(sample(2))
        profile.record(sample(2))
        let safe = try XCTUnwrap(profile.safeFrameCount)
        XCTAssertLessThanOrEqual(safe, profile.bestFrames)
        XCTAssertGreaterThanOrEqual(safe, 1)
    }

    func testScatteredHistoryLeansTowardTheLowRuns() throws {
        // Mixed 8s and 20s: the 25th-percentile basis must sit near the 8s,
        // not the mean (14).
        var profile = BlendLearningProfile(firstSample: sample(8))
        for frames in [20, 8, 20, 8, 20] { profile.record(sample(frames)) }
        let safe = try XCTUnwrap(profile.safeFrameCount)
        XCTAssertLessThanOrEqual(safe, 8)
    }

    func testRecentDeclineOutweighsOldGoodRuns() throws {
        // 20 old strong runs, then 5 recent weak ones — the estimate must
        // follow the recent runs down.
        var profile = BlendLearningProfile(firstSample: sample(24))
        for _ in 0..<19 { profile.record(sample(24)) }
        for _ in 0..<5 { profile.record(sample(6)) }
        let safe = try XCTUnwrap(profile.safeFrameCount)
        XCTAssertLessThanOrEqual(safe, 6)
    }

    func testThrottledRunsArePenalized() throws {
        var clean = BlendLearningProfile(firstSample: sample(10))
        clean.record(sample(10))
        clean.record(sample(10))
        var distressed = BlendLearningProfile(firstSample: sample(10, throttled: true))
        distressed.record(sample(10, throttled: true))
        distressed.record(sample(10, throttled: true))
        let cleanSafe = try XCTUnwrap(clean.safeFrameCount)
        let distressedSafe = try XCTUnwrap(distressed.safeFrameCount)
        XCTAssertLessThan(distressedSafe, cleanSafe)
    }

    func testWeightedPercentileBasics() {
        let uniform = [(1.0, 1.0), (2.0, 1.0), (3.0, 1.0), (4.0, 1.0)]
        XCTAssertEqual(BlendLearningProfile.weightedPercentile(uniform, fraction: 0.25), 1.0)
        XCTAssertEqual(BlendLearningProfile.weightedPercentile(uniform, fraction: 1.0), 4.0)
        // Weight makes the difference: a heavy high value pulls the low
        // percentile up past the light low value.
        let skewed = [(1.0, 0.05), (10.0, 1.0)]
        XCTAssertEqual(BlendLearningProfile.weightedPercentile(skewed, fraction: 0.25), 10.0)
    }

    // MARK: Table

    func testTableRecordsAndPredictsPerKey() {
        var table = BlendLearningTable()
        for _ in 0..<3 { table.record(sample(12), for: key) }
        XCTAssertTrue(table.hasUsableProfile(for: key))
        XCTAssertNotNil(table.safeFrameCount(for: key))

        var warmKey = key
        warmKey.thermalBucket = .warm
        XCTAssertFalse(table.hasUsableProfile(for: warmKey))
        XCTAssertNil(table.safeFrameCount(for: warmKey))
    }

    func testConservativeFallbackTakesTheMinimumAcrossBuckets() {
        var table = BlendLearningTable()
        var hotKey = key
        hotKey.thermalBucket = .hot
        for _ in 0..<3 { table.record(sample(20), for: key) }
        for _ in 0..<3 { table.record(sample(6), for: hotKey) }
        let conservative = table.conservativeFrameCount(
            deviceModel: key.deviceModel, pipeline: key.pipeline, intervalSeconds: key.intervalSeconds)
        XCTAssertEqual(conservative, table.safeFrameCount(for: hotKey))
        // Other intervals stay isolated.
        XCTAssertNil(table.conservativeFrameCount(
            deviceModel: key.deviceModel, pipeline: key.pipeline, intervalSeconds: 5.0))
    }

    func testTableSurvivesAJSONRoundTrip() throws {
        var table = BlendLearningTable()
        for frames in [10, 12, 14] { table.record(sample(frames, throttled: frames == 14), for: key) }
        let data = try JSONEncoder().encode(table)
        let decoded = try JSONDecoder().decode(BlendLearningTable.self, from: data)
        XCTAssertEqual(decoded, table)
        XCTAssertEqual(decoded.safeFrameCount(for: key), table.safeFrameCount(for: key))
    }
}
