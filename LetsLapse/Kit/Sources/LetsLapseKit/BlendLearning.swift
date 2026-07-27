import Foundation

/// The learning model behind Interval's adaptive blend depths. Unthrottled
/// ("Psycho") intervals record what the device actually managed; throttled
/// ("Safe") intervals ask these profiles for a known-safe frame count and
/// refuse to guess without one. Pure data + math — persistence and thermal
/// sampling live in the app.

/// Coarse thermal condition at interval start, the primary predictor of how
/// many frames a burst can manage. iOS exposes no temperature, only
/// `ProcessInfo.thermalState`, so buckets map from its four steps; the
/// learned frame counts are the precision instrument between them.
public enum ThermalBucket: String, Codable, CaseIterable, Sendable, Comparable {
    case cool
    case warm
    case hot

    public init(thermalState: ProcessInfo.ThermalState) {
        switch thermalState {
        case .nominal: self = .cool
        case .fair: self = .warm
        default: self = .hot
        }
    }

    /// Maps the thermal-state names the session logs record ("nominal",
    /// "fair", …) back onto buckets, so log entries and learning agree.
    public init?(thermalStateName: String) {
        switch thermalStateName {
        case "nominal": self = .cool
        case "fair": self = .warm
        case "serious", "critical": self = .hot
        default: return nil
        }
    }

    public static func < (lhs: ThermalBucket, rhs: ThermalBucket) -> Bool {
        func rank(_ bucket: ThermalBucket) -> Int {
            switch bucket {
            case .cool: return 0
            case .warm: return 1
            case .hot: return 2
            }
        }
        return rank(lhs) < rank(rhs)
    }
}

/// One completed unthrottled interval's contribution to a profile.
public struct BlendLearningSample: Codable, Equatable, Sendable {
    public var date: Date
    public var framesCaptured: Int
    /// The device showed distress during the interval — thermal state rose
    /// or sat at serious+, or output cadence drifted past the interval.
    public var throttleDetected: Bool
    /// The count was limited by the app (memory budget, backpressure), not
    /// by the device's capture rate — true capacity is at least this.
    public var capped: Bool
    public var blendMillis: Double?

    public init(
        date: Date,
        framesCaptured: Int,
        throttleDetected: Bool,
        capped: Bool,
        blendMillis: Double? = nil
    ) {
        self.date = date
        self.framesCaptured = framesCaptured
        self.throttleDetected = throttleDetected
        self.capped = capped
        self.blendMillis = blendMillis
    }
}

/// Everything learned for one profile key. History is never fully reset by
/// new data: the sample ring keeps recent runs (weighted heaviest) while
/// `bestFrames`/`worstFrames` pin the extremes ever seen, so a hot day
/// teaches without erasing cold-day learning.
public struct BlendLearningProfile: Codable, Equatable, Sendable {
    /// Newest last. Capped at `maxStoredSamples`; older runs age out of the
    /// ring but keep their mark on the bounds.
    public var samples: [BlendLearningSample]
    public var bestFrames: Int
    public var worstFrames: Int

    public static let maxStoredSamples = 40
    /// One noisy interval is not a basis for a promise; Safe mode only
    /// trusts a profile once it has this many runs.
    public static let minSamplesForPrediction = 3
    /// Order-based decay per step back from the newest sample.
    static let recencyDecay = 0.85
    /// Distressed runs count at a fraction of their frame count — the device
    /// showed strain at that level, so treat it as beyond the safe zone.
    static let throttlePenalty = 0.8
    /// Final conservative margin under the weighted low estimate.
    static let safetyFactor = 0.85

    public init(firstSample sample: BlendLearningSample) {
        samples = [sample]
        bestFrames = sample.framesCaptured
        worstFrames = sample.framesCaptured
    }

    public mutating func record(_ sample: BlendLearningSample) {
        samples.append(sample)
        if samples.count > Self.maxStoredSamples {
            samples.removeFirst(samples.count - Self.maxStoredSamples)
        }
        bestFrames = max(bestFrames, sample.framesCaptured)
        worstFrames = min(worstFrames, sample.framesCaptured)
    }

    public var isUsable: Bool {
        samples.count >= Self.minSamplesForPrediction
    }

    /// The known-safe frame count this profile supports, or nil while the
    /// profile is too thin to trust. Recency-weighted 25th percentile of the
    /// achieved counts (throttled runs penalized), under a safety margin —
    /// conservative when history is scattered, converging as it settles.
    public var safeFrameCount: Int? {
        guard isUsable else { return nil }
        var weighted: [(value: Double, weight: Double)] = []
        for (index, sample) in samples.enumerated() {
            let age = samples.count - 1 - index
            let weight = pow(Self.recencyDecay, Double(age))
            let penalty = sample.throttleDetected ? Self.throttlePenalty : 1.0
            weighted.append((Double(sample.framesCaptured) * penalty, weight))
        }
        let lowEstimate = Self.weightedPercentile(weighted, fraction: 0.25)
        let safe = Int((lowEstimate * Self.safetyFactor).rounded(.down))
        return min(max(safe, 1), bestFrames)
    }

    /// Weighted percentile by cumulative weight over the sorted values.
    static func weightedPercentile(
        _ values: [(value: Double, weight: Double)],
        fraction: Double
    ) -> Double {
        precondition(!values.isEmpty)
        let sorted = values.sorted { $0.value < $1.value }
        let total = sorted.reduce(0) { $0 + $1.weight }
        let threshold = total * fraction
        var cumulative = 0.0
        for entry in sorted {
            cumulative += entry.weight
            if cumulative >= threshold {
                return entry.value
            }
        }
        return sorted[sorted.count - 1].value
    }
}

/// Identifies one learning profile. Pipeline is part of the key because the
/// two blend engines have incomparable frame rates (Bayer RAW captures run
/// ~1–5 frames/s; the JPEG video tap runs at the configured frame rate) —
/// pooling them would poison the estimate.
public struct BlendProfileKey: Codable, Hashable, Sendable {
    public var deviceModel: String
    /// "dng" or "standard" — the same vocabulary the session logs use.
    public var pipeline: String
    public var thermalBucket: ThermalBucket
    public var intervalSeconds: Double

    public init(
        deviceModel: String,
        pipeline: String,
        thermalBucket: ThermalBucket,
        intervalSeconds: Double
    ) {
        self.deviceModel = deviceModel
        self.pipeline = pipeline
        self.thermalBucket = thermalBucket
        self.intervalSeconds = intervalSeconds
    }
}

/// The full table of learned profiles, as persisted by the app.
public struct BlendLearningTable: Codable, Equatable, Sendable {
    public var profiles: [BlendProfileKey: BlendLearningProfile]

    public init(profiles: [BlendProfileKey: BlendLearningProfile] = [:]) {
        self.profiles = profiles
    }

    public mutating func record(_ sample: BlendLearningSample, for key: BlendProfileKey) {
        if var profile = profiles[key] {
            profile.record(sample)
            profiles[key] = profile
        } else {
            profiles[key] = BlendLearningProfile(firstSample: sample)
        }
    }

    public func safeFrameCount(for key: BlendProfileKey) -> Int? {
        profiles[key]?.safeFrameCount
    }

    public func hasUsableProfile(for key: BlendProfileKey) -> Bool {
        profiles[key]?.isUsable ?? false
    }

    /// Mid-session fallback when the current bucket has no usable profile:
    /// the most conservative learned count for the same device, pipeline and
    /// interval across the buckets that do — never a guess above anything
    /// the device has demonstrated.
    public func conservativeFrameCount(
        deviceModel: String,
        pipeline: String,
        intervalSeconds: Double
    ) -> Int? {
        ThermalBucket.allCases.compactMap { bucket in
            safeFrameCount(for: BlendProfileKey(
                deviceModel: deviceModel,
                pipeline: pipeline,
                thermalBucket: bucket,
                intervalSeconds: intervalSeconds))
        }.min()
    }
}
