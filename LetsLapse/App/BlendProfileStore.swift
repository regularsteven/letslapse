import Foundation
import os
import LetsLapseKit

/// Persistent home of what unthrottled ("Psycho") intervals have taught
/// about this device: one `BlendLearningProfile` per device × pipeline ×
/// thermal bucket × interval. Throttled ("Safe") shoots read it once per
/// window; Settings shows and resets it. The table lives as JSON in
/// Application Support/LetsLapse/ beside the session logs, rewritten
/// atomically on every recorded interval (it stays tiny).
final class BlendProfileStore {
    static let shared = BlendProfileStore()

    /// One profile prepared for display in Settings.
    struct ProfileSummary: Identifiable {
        var key: BlendProfileKey
        var safeFrameCount: Int?
        var sampleCount: Int
        var bestFrames: Int
        var worstFrames: Int
        var id: String {
            "\(key.pipeline)|\(key.thermalBucket.rawValue)|\(key.intervalSeconds)"
        }
    }

    private let table: OSAllocatedUnfairLock<BlendLearningTable>
    private let fileURL: URL
    private let deviceModel = LiveBlendController.deviceModelIdentifier()
    private let loggedWriteFailure = OSAllocatedUnfairLock(initialState: false)

    init(fileURL: URL = BlendProfileStore.defaultFileURL()) {
        self.fileURL = fileURL
        // Date strategy must mirror `persist` (.iso8601) or every relaunch
        // would silently decode to an empty table.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: fileURL))
            .flatMap { try? decoder.decode(BlendLearningTable.self, from: $0) }
            ?? BlendLearningTable()
        self.table = OSAllocatedUnfairLock(initialState: loaded)
    }

    // MARK: Recording (called from the blend controllers' work queues)

    func record(
        _ sample: BlendLearningSample,
        pipeline: String,
        bucket: ThermalBucket,
        intervalSeconds: Double
    ) {
        let key = BlendProfileKey(
            deviceModel: deviceModel,
            pipeline: pipeline,
            thermalBucket: bucket,
            intervalSeconds: intervalSeconds)
        let snapshot = table.withLock { value in
            value.record(sample, for: key)
            return value
        }
        persist(snapshot)
        LLog("blendlearn: \(pipeline) \(bucket.rawValue) \(intervalSeconds)s captured=\(sample.framesCaptured) throttled=\(sample.throttleDetected) capped=\(sample.capped)")
    }

    // MARK: Queries

    func safeFrameCount(pipeline: String, bucket: ThermalBucket, intervalSeconds: Double) -> Int? {
        table.withLock { value in
            value.safeFrameCount(for: BlendProfileKey(
                deviceModel: deviceModel,
                pipeline: pipeline,
                thermalBucket: bucket,
                intervalSeconds: intervalSeconds))
        }
    }

    func hasUsableProfile(pipeline: String, bucket: ThermalBucket, intervalSeconds: Double) -> Bool {
        table.withLock { value in
            value.hasUsableProfile(for: BlendProfileKey(
                deviceModel: deviceModel,
                pipeline: pipeline,
                thermalBucket: bucket,
                intervalSeconds: intervalSeconds))
        }
    }

    /// Mid-session fallback: the most conservative learned count for this
    /// interval across buckets, when the current bucket has no profile.
    func conservativeFrameCount(pipeline: String, intervalSeconds: Double) -> Int? {
        table.withLock { value in
            value.conservativeFrameCount(
                deviceModel: deviceModel,
                pipeline: pipeline,
                intervalSeconds: intervalSeconds)
        }
    }

    /// This device's profiles for Settings, coolest bucket first within
    /// ascending interval, DNG before JPEG.
    func summariesForCurrentDevice() -> [ProfileSummary] {
        table.withLock { value in
            value.profiles
                .filter { $0.key.deviceModel == deviceModel }
                .map { key, profile in
                    ProfileSummary(
                        key: key,
                        safeFrameCount: profile.safeFrameCount,
                        sampleCount: profile.samples.count,
                        bestFrames: profile.bestFrames,
                        worstFrames: profile.worstFrames)
                }
                .sorted { lhs, rhs in
                    if lhs.key.pipeline != rhs.key.pipeline {
                        return lhs.key.pipeline < rhs.key.pipeline
                    }
                    if lhs.key.intervalSeconds != rhs.key.intervalSeconds {
                        return lhs.key.intervalSeconds < rhs.key.intervalSeconds
                    }
                    return lhs.key.thermalBucket < rhs.key.thermalBucket
                }
        }
    }

    // MARK: Reset

    /// Full reset, for unusual conditions (a case change, a summer). The
    /// file is removed rather than rewritten empty.
    func resetAll() {
        table.withLock { $0 = BlendLearningTable() }
        try? FileManager.default.removeItem(at: fileURL)
        LLog("blendlearn: profiles reset")
    }

    // MARK: Persistence

    private func persist(_ snapshot: BlendLearningTable) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            let alreadyLogged = loggedWriteFailure.withLock { logged in
                defer { logged = true }
                return logged
            }
            if !alreadyLogged {
                LLog("blendlearn: could not write profiles: \(error)")
            }
        }
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("LetsLapse", isDirectory: true)
            .appendingPathComponent("blend-profiles.json")
    }
}
