import CoreGraphics
import CryptoKit
import Foundation

/// The cache-first front door to scene segmentation: frame in, sky mask out,
/// with memory and disk caches ahead of the model and in-flight coalescing so
/// a scrub can't queue the same inference twice.
///
/// The one hard rule, enforced by the API shape: overlay edits never trigger
/// inference. The composite path reads `cachedSkyMask` — synchronous,
/// cache-only, never generates — and the async fetchers are called from
/// explicit "this frame/sequence needs a mask" moments.
actor SceneMaskService {
    static let shared = SceneMaskService()

    private var segmenter: CoreMLSceneSegmenter?
    private var segmenterIdentity: String?
    private var inFlight: [String: Task<SceneMask, Error>] = [:]

    /// Decoded grids by cache key. NSCache is thread-safe, which is what lets
    /// `cachedSkyMask` stay nonisolated and synchronous.
    private static let memory: NSCache<NSString, MaskBox> = {
        let cache = NSCache<NSString, MaskBox>()
        cache.countLimit = 24
        return cache
    }()

    private final class MaskBox {
        let mask: SceneMask
        init(_ mask: SceneMask) { self.mask = mask }
    }

    // MARK: - Keys

    /// Per-frame cache key. Post-processing settings are deliberately absent
    /// — masks are cached raw, and the dials iterate live. The grade is keyed
    /// by preset id only, so slider motion never re-segments (accepted
    /// staleness: a reworked grade reuses the old mask until the cache is
    /// cleared). `modelIdentity` comes from `CoreMLSceneSegmenter.locate()`,
    /// resolved once by the caller — not here, so key building costs no
    /// file-system walk per invocation.
    nonisolated func frameKey(modelIdentity: String, url: URL, presetID: String) -> String {
        "seg1|\(modelIdentity)|\(presetID)@512|sky|\(SceneMaskStore.frameIdentity(url))"
    }

    /// Sequence-level key over the ordered sampled set — a re-shoot, an
    /// edited frame or a changed nomination changes the fingerprint.
    nonisolated func sequenceKey(
        modelIdentity: String, frames: [URL], presetID: String, sampleCount: Int
    ) -> String {
        let sampled = Self.sample(frames, count: sampleCount)
        let fingerprint = sampled.map(SceneMaskStore.frameIdentity).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(fingerprint.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "seq1|\(modelIdentity)|\(presetID)@512|sky|N=\(sampled.count)|\(digest)"
    }

    /// Synchronous, cache-only. The composite path's lookup — a miss means
    /// "composite without occlusion this pass", never "wait for the model".
    nonisolated func cachedSkyMask(forKey key: String) -> SceneMask? {
        if let boxed = Self.memory.object(forKey: key as NSString) { return boxed.mask }
        guard let mask = SceneMaskStore.read(key) else { return nil }
        Self.memory.setObject(MaskBox(mask), forKey: key as NSString)
        return mask
    }

    // MARK: - Fetch

    /// The sky mask for one frame, generating (and caching) it if needed.
    /// `render` supplies the display-referred input — the caller owns how a
    /// frame becomes an image, this actor owns everything after.
    func skyMask(
        forKey key: String,
        render: @escaping @Sendable () -> CGImage?
    ) async throws -> SceneMask {
        if let cached = cachedSkyMask(forKey: key) { return cached }
        if let running = inFlight[key] { return try await running.value }
        let task = Task<SceneMask, Error> { [self] in
            let segmenter = try await loadedSegmenter()
            guard let input = render() else {
                throw SegmentationError.inferenceFailed("no input frame")
            }
            let mask = try segmenter.skyMask(for: input)
            SceneMaskStore.write(mask, forKey: key)
            Self.memory.setObject(MaskBox(mask), forKey: key as NSString)
            return mask
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// One static mask voted across `sampleCount` frames of a sequence: the
    /// mean of the per-frame grids is a confidence map ("what fraction of the
    /// sampled shoot called this cell sky"), which the compositor thresholds
    /// live. The camera is locked off on an interval shoot, so the boundary
    /// is static and majority voting papers over the frames where the model
    /// loses the plot (deep dusk).
    func sequenceSkyMask(
        forKey key: String,
        modelIdentity: String,
        frames: [URL],
        sampleCount: Int,
        presetID: String,
        render: @escaping @Sendable (URL) -> CGImage?
    ) async throws -> SceneMask {
        if let cached = cachedSkyMask(forKey: key) { return cached }
        let sampled = Self.sample(frames, count: sampleCount)
        guard !sampled.isEmpty else { throw SegmentationError.inferenceFailed("no frames") }
        var accumulated = [Int](repeating: 0, count: 0)
        var width = 0, height = 0
        var contributors = 0
        for url in sampled {
            let frameKey = frameKey(modelIdentity: modelIdentity, url: url, presetID: presetID)
            let mask = try await skyMask(forKey: frameKey) { render(url) }
            if accumulated.isEmpty {
                width = mask.width
                height = mask.height
                accumulated = [Int](repeating: 0, count: width * height)
            }
            guard mask.width == width, mask.height == height else { continue }
            for index in 0..<accumulated.count {
                accumulated[index] += Int(mask.pixels[index])
            }
            contributors += 1
        }
        guard contributors > 0 else { throw SegmentationError.inferenceFailed("no masks") }
        let pixels = accumulated.map { UInt8($0 / contributors) }
        let mask = SceneMask(
            region: .sky, width: width, height: height, pixels: pixels,
            geometry: .stretch,
            provenance: "sequence vote · \(contributors) frames")
        SceneMaskStore.write(mask, forKey: key)
        Self.memory.setObject(MaskBox(mask), forKey: key as NSString)
        return mask
    }

    /// First/last plus an even spread between — the sampling the scene tagger
    /// uses, generalized to N.
    nonisolated static func sample(_ frames: [URL], count: Int) -> [URL] {
        guard frames.count > count, count > 1 else { return frames }
        return (0..<count).map { index in
            frames[Int(
                (Double(index) / Double(count - 1) * Double(frames.count - 1)).rounded())]
        }
    }

    // MARK: - Model

    private func loadedSegmenter() throws -> CoreMLSceneSegmenter {
        guard let source = CoreMLSceneSegmenter.locate() else {
            segmenter = nil
            segmenterIdentity = nil
            throw SegmentationError.modelNotInstalled
        }
        if let segmenter, segmenterIdentity == source.identity { return segmenter }
        let loaded = try CoreMLSceneSegmenter(source: source)
        segmenter = loaded
        segmenterIdentity = source.identity
        return loaded
    }
}
