import Foundation
import ImageIO
import Metal
import simd

/// Finds the Adobe profile that belongs to a camera.
///
/// ## Where the profiles actually live
///
/// Lightroom's per-model profiles are under
/// `/Library/Application Support/Adobe/CameraRaw/CameraProfiles/`, but *not*
/// in a `Camera/Apple/` folder — the `Camera/` subtree holds one directory per
/// model for the makers Adobe ships bespoke looks for (Canon, Nikon, Sony,
/// Olympus, Panasonic, Pentax, Ricoh, Sigma, Leica, OM) and Apple is not among
/// them. Every iPhone and iPad profile sits flat in the sibling
/// `Adobe Standard/` directory instead, named by *model identifier* rather
/// than marketing name: the profile for an iPhone 16 Pro is
/// `Apple iPhone17,1 back camera Adobe Standard.dcp`.
///
/// That naming is why the match here keys on `UniqueCameraModel` and not on
/// the `Model` string. A DNG's `Model` reads `iPhone 16 Pro`, which shares
/// almost no characters with `iPhone17,1` and would rank below dozens of
/// unrelated cameras on any edit distance. Its `UniqueCameraModel` reads
/// `iPhone17,1 back camera` — the exact string the profile is named for and
/// carries internally, so the common case is an exact hit and the edit
/// distance is only a tie-breaker for the near-misses.
public enum DCPProfileLocator {
    public enum Error: Swift.Error, LocalizedError, Equatable {
        case directoryMissing
        case noProfileFound(model: String)

        public var errorDescription: String? {
            switch self {
            case .directoryMissing:
                return "Adobe camera profiles are not installed on this machine."
            case .noProfileFound(let model):
                return "No Adobe profile matches the camera \"\(model)\"."
            }
        }
    }

    /// The root Lightroom installs profiles into.
    public static let profileRoot = URL(
        fileURLWithPath: "/Library/Application Support/Adobe/CameraRaw/CameraProfiles",
        isDirectory: true)

    /// Whether this machine has the profile set at all. iOS devices never do;
    /// a Mac without Lightroom or Camera Raw installed does not either.
    public static var isInstalled: Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: profileRoot.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Every `.dcp` under the profile root, cached after the first walk.
    ///
    /// The set runs to a few thousand files, so the enumeration is done once
    /// per process rather than once per frame — a timelapse decodes hundreds
    /// of DNGs from one camera and would otherwise re-walk the tree for each.
    static func allProfiles() throws -> [URL] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = profileCache { return cached }
        guard isInstalled else { throw Error.directoryMissing }
        var found: [URL] = []
        if let walker = FileManager.default.enumerator(
            at: profileRoot, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) {
            for case let url as URL in walker
            where url.pathExtension.lowercased() == "dcp" {
                found.append(url)
            }
        }
        profileCache = found
        return found
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var profileCache: [URL]?
    nonisolated(unsafe) private static var resolved: [String: URL] = [:]

    /// The best profile for a camera, identified by its `UniqueCameraModel`.
    ///
    /// Ranking, in order:
    /// 1. A filename containing the model string verbatim — the normal case,
    ///    and the one that makes this cheap.
    /// 2. Otherwise the smallest Levenshtein distance between the model and
    ///    the filename's model portion, rejected past a third of the model's
    ///    length so an unknown camera reports "no profile" rather than
    ///    silently rendering through some other manufacturer's look.
    ///
    /// Where several profiles match one camera — Adobe ships `Adobe Standard`
    /// alongside `Camera Standard`, `Camera Neutral` and so on — the
    /// `Adobe Standard` variant wins, because it is what Lightroom selects by
    /// default and matching Lightroom's default is the object here.
    public static func profile(forCameraModel model: String) throws -> URL {
        let key = model.lowercased()
        cacheLock.lock()
        if let hit = resolved[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let profiles = try allProfiles()
        guard !profiles.isEmpty else { throw Error.noProfileFound(model: model) }

        let needle = normalise(model)
        var exact: [URL] = []
        var best: (url: URL, distance: Int)?

        for url in profiles {
            let name = normalise(url.deletingPathExtension().lastPathComponent)
            if name.contains(needle) {
                exact.append(url)
                continue
            }
            guard exact.isEmpty else { continue }
            let distance = levenshtein(needle, name)
            if best == nil || distance < best!.distance {
                best = (url, distance)
            }
        }

        let chosen: URL
        if !exact.isEmpty {
            chosen = preferred(among: exact)
        } else if let best, best.distance <= max(needle.count / 3, 4) {
            chosen = best.url
        } else {
            throw Error.noProfileFound(model: model)
        }

        cacheLock.lock()
        resolved[key] = chosen
        cacheLock.unlock()
        return chosen
    }

    /// Lightroom's own default look, when a camera has several profiles.
    private static func preferred(among candidates: [URL]) -> URL {
        let ranked = candidates.sorted { a, b in
            func rank(_ url: URL) -> Int {
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                if name.contains("adobe standard") { return 0 }
                if name.contains("camera standard") { return 1 }
                if name.contains("camera default") { return 2 }
                return 3
            }
            let (ra, rb) = (rank(a), rank(b))
            if ra != rb { return ra < rb }
            // Shorter names are the plainer variants ("… back camera" beats
            // "… back camera under artificial light").
            return a.lastPathComponent.count < b.lastPathComponent.count
        }
        return ranked[0]
    }

    private static func normalise(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "_", with: " ")
    }

    /// Plain edit distance, two rows rather than a full matrix.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    /// Clears the process caches. For tests that move files around.
    public static func resetCaches() {
        cacheLock.lock()
        profileCache = nil
        resolved = [:]
        cacheLock.unlock()
    }
}

// MARK: - Reading the camera identity off a DNG

/// The identity tags the profile match needs, read from a source file.
public enum DngMetadata {
    /// `UniqueCameraModel` (DNG tag 0xC614) — e.g. `iPhone17,1 back camera`.
    ///
    /// Falls back to `Make` + `Model` when the tag is absent, which is the
    /// best a non-DNG can offer. Prefer the unique model wherever it exists:
    /// it names the *lens* as well as the body, and a phone's wide, ultra-wide
    /// and telephoto modules are separately calibrated cameras with separate
    /// profiles.
    public static func cameraModel(url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else { return nil }
        if let dng = properties[kCGImagePropertyDNGDictionary] as? [CFString: Any],
           let unique = dng[kCGImagePropertyDNGUniqueCameraModel] as? String,
           !unique.isEmpty {
            return unique
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let make = (tiff?[kCGImagePropertyTIFFMake] as? String) ?? ""
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String) ?? ""
        let joined = "\(make) \(model)".trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }
}

// MARK: - GPU application

/// Applies a parsed DCP's hue/sat and look tables to a decoded frame.
///
/// One applier owns one compiled pipeline and is safe to reuse across frames;
/// the per-profile buffers are cached by profile path and shot temperature, so
/// a clip that decodes six hundred frames from one camera uploads its tables
/// once.
public final class DCPProfileApplier {
    /// Mirror of the Metal `DCPParams` struct — layouts must match.
    private struct GPUDCPParams {
        var toWorking: simd_float3x3
        var fromWorking: simd_float3x3
        var hueSatDims: SIMD3<UInt32>
        var lookDims: SIMD3<UInt32>
        var hasHueSat: UInt32
        var hasLook: UInt32
    }

    private struct Resources {
        let hueSat: MTLBuffer
        let look: MTLBuffer
        let params: GPUDCPParams
    }

    public let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private var cache: [String: Resources] = [:]
    private let lock = NSLock()

    public init(device: MTLDevice) throws {
        self.device = device
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: GradeKernelSource.dcpSource, options: nil)
        } catch {
            throw LapseError.gpuSetupFailed(
                "DCP kernel compilation failed: \(error.localizedDescription)")
        }
        guard let function = library.makeFunction(name: "applyDCPLookTable") else {
            throw LapseError.gpuSetupFailed("missing DCP kernel applyDCPLookTable")
        }
        self.pipeline = try device.makeComputePipelineState(function: function)
    }

    /// Which of a profile's two tables to apply.
    ///
    /// ## Why this is a choice and not "both"
    ///
    /// The two tables look alike — same shape, same HSV semantics — and do
    /// jobs that differ in a way that decides whether each one belongs in
    /// *this* pipeline:
    ///
    /// - The **look table** is a look, authored to sit on top of a rendered
    ///   image. Frames reach this pass already rendered by `CIRAWFilter`, so
    ///   that is exactly the input it expects.
    /// - The **hue/sat map** is a *sensor calibration*: Adobe's measurement of
    ///   how this camera's raw response deviates, authored to be applied to
    ///   camera data carried through the profile's own forward matrix. But
    ///   `CIRAWFilter` has already corrected the same deviation using Apple's
    ///   calibration of the same sensor. Applying Adobe's on top does not
    ///   replace Apple's — it stacks a second correction for an error that has
    ///   already been corrected once.
    ///
    /// That is not a theoretical objection. `DCPTableAblationTests` measures
    /// it on the calibration frame: the look table pulls the shadow B/G ratio
    /// **−8.9%** (the direction the whole comparison is chasing, away from the
    /// cold cast), the hue/sat map pushes it **+17.3%** the other way, and with
    /// both enabled the hue/sat map wins and the path ends up worse than
    /// `.cirawFilter`. So `.lookOnly` is the default and what the decode path
    /// ships.
    ///
    /// `.lookAndHueSat` is kept because it is not wrong in general — it is the
    /// correct combination the moment a decode reaches this pass in genuine
    /// camera space, through the profile's forward matrix rather than Apple's.
    /// That decode does not exist yet; when it does, this is the switch it
    /// needs, and the ablation test is the measurement that should decide it.
    public enum Tables: Sendable {
        /// The look table only. The shipped decode path.
        case lookOnly
        /// Both tables — correct only for a genuine camera-space decode.
        case lookAndHueSat
    }

    /// Runs the profile over `source` into a fresh texture of the same shape.
    ///
    /// `temperatureK` is the frame's as-shot illuminant, used to interpolate
    /// between the profile's two calibration hue/sat tables when those are in
    /// play. It is ignored under `.lookOnly`, which is a single table with no
    /// illuminant pair.
    public func apply(
        _ profile: DCPFile, to source: MTLTexture, temperatureK: Float,
        commandQueue: MTLCommandQueue, cacheKey: String, tables: Tables = .lookOnly
    ) throws -> MTLTexture {
        let resources = try resources(
            for: profile, temperatureK: temperatureK, key: cacheKey, tables: tables)
        guard resources.params.hasHueSat != 0 || resources.params.hasLook != 0 else {
            // Nothing to apply — hand back the input rather than paying for a
            // copy that would change no pixel.
            return source
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat, width: source.width, height: source.height,
            mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let destination = device.makeTexture(descriptor: descriptor) else {
            throw LapseError.textureCreationFailed(
                "\(source.width)x\(source.height) DCP output")
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw LapseError.gpuSetupFailed("could not encode the DCP pass")
        }
        var params = resources.params
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<GPUDCPParams>.stride, index: 0)
        encoder.setBuffer(resources.hueSat, offset: 0, index: 1)
        encoder.setBuffer(resources.look, offset: 0, index: 2)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (source.width + w - 1) / w,
                height: (source.height + h - 1) / h, depth: 1),
            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw LapseError.gpuSetupFailed("DCP pass failed: \(error.localizedDescription)")
        }
        return destination
    }

    private func resources(
        for profile: DCPFile, temperatureK: Float, key: String, tables: Tables
    ) throws -> Resources {
        // Cache per 50 K bucket: the hue/sat interpolation is smooth and a
        // clip's frames sit within a few kelvin of each other, so bucketing
        // keeps a timelapse on one upload without pinning it to the first
        // frame's illuminant across a sunset.
        let bucket = Int((temperatureK / 50).rounded())
        let cacheKey = "\(key)#\(bucket)#\(tables)"
        lock.lock()
        if let hit = cache[cacheKey] { lock.unlock(); return hit }
        lock.unlock()

        let wantsHueSat = tables == .lookAndHueSat
        let hueSatCells = (wantsHueSat && profile.hasHueSatMap)
            ? profile.hueSatMap(at: temperatureK) : []
        let lookCells = profile.hasLookTable ? profile.lookTableData : []

        // A zero-length MTLBuffer is not allowed, and the kernel's argument
        // must be bound whether or not its table exists, so an absent table
        // gets a one-cell identity buffer that the `has…` flag stops it
        // reading.
        let identity = [SIMD3<Float>(0, 1, 1)]
        let hueSatBuffer = try makeBuffer(hueSatCells.isEmpty ? identity : hueSatCells)
        let lookBuffer = try makeBuffer(lookCells.isEmpty ? identity : lookCells)

        let params = GPUDCPParams(
            toWorking: Self.linearP3ToProPhoto,
            fromWorking: Self.proPhotoToLinearP3,
            hueSatDims: SIMD3<UInt32>(
                UInt32(max(profile.hueSatMapDims.x, 0)),
                UInt32(max(profile.hueSatMapDims.y, 0)),
                UInt32(max(profile.hueSatMapDims.z, 0))),
            lookDims: SIMD3<UInt32>(
                UInt32(max(profile.lookTableDims.x, 0)),
                UInt32(max(profile.lookTableDims.y, 0)),
                UInt32(max(profile.lookTableDims.z, 0))),
            hasHueSat: hueSatCells.isEmpty ? 0 : 1,
            hasLook: lookCells.isEmpty ? 0 : 1)

        let resources = Resources(hueSat: hueSatBuffer, look: lookBuffer, params: params)
        lock.lock()
        cache[cacheKey] = resources
        lock.unlock()
        return resources
    }

    private func makeBuffer(_ cells: [SIMD3<Float>]) throws -> MTLBuffer {
        // `SIMD3<Float>` and Metal's `float3` are both 16-byte-strided, so the
        // array copies straight across without repacking.
        let length = MemoryLayout<SIMD3<Float>>.stride * cells.count
        guard let buffer = cells.withUnsafeBytes({ bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: length, options: .storageModeShared)
        }) else {
            throw LapseError.gpuSetupFailed("could not allocate the DCP table buffer")
        }
        return buffer
    }

    // MARK: Working-space matrices

    /// ProPhoto RGB (ROMM, D50) → XYZ_D50.
    static let proPhotoToXYZ_D50 = simd_float3x3(rows: [
        SIMD3<Float>(0.7976749, 0.1351917, 0.0313534),
        SIMD3<Float>(0.2880402, 0.7118741, 0.0000857),
        SIMD3<Float>(0.0000000, 0.0000000, 0.8252100),
    ])

    static let xyzD50ToProPhoto = proPhotoToXYZ_D50.inverse

    /// Extended linear Display P3 → ProPhoto RGB, through the D50 connection
    /// space the profile tables are defined against.
    static let linearP3ToProPhoto: simd_float3x3 =
        xyzD50ToProPhoto * ForwardMatrixDecoder.xyzD50ToLinearP3.inverse

    static let proPhotoToLinearP3: simd_float3x3 =
        ForwardMatrixDecoder.xyzD50ToLinearP3 * proPhotoToXYZ_D50
}
