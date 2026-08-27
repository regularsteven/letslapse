#if canImport(CoreImage)
import CoreImage
import Foundation
import LetsLapseKit
import Metal

/// App-facing entry points for the Adobe DCP decode path.
///
/// The work itself lives in `LetsLapseKit` — `DCPParser` reads the container,
/// `DCPProfileLocator` finds the right file for a camera, `DCPProfileApplier`
/// runs the tables on the GPU, and `LinearFrameDecoder` calls all three as
/// part of decoding a frame. This file is the thin app-side half, the same
/// shape as `RawDecodePath.swift`'s: the Kit cannot import the app target, and
/// the settings picker and the `lapse` CLI both want a place to ask "is there
/// a profile for this camera, and where".
///
/// ## What the path does
///
/// On top of the ordering `.cirawFilter` already gets right — white balance in
/// camera space, ahead of the profile, as Lightroom does it — this path adds
/// the camera's Adobe profile tables:
///
/// - **`ProfileHueSatMap`**, one table per calibration illuminant, interpolated
///   by the shot's own temperature in reciprocal-kelvin the same way the
///   forward matrices are.
/// - **`ProfileLookTable`**, a single table applied after it.
///
/// Both are 3-D samplings in HSV, and that is the whole point: a 3×3 applies
/// one linear map to every pixel and therefore cannot move a hue one way in
/// the shadows and another way in the highlights. Adobe's shadow rendering
/// does exactly that, which is why the first three decode paths — all of them
/// arguments about which matrix goes where — could narrow the gap but never
/// close it.
///
/// ## What it does not do
///
/// It does not use the profile's `ForwardMatrix1/2`, and deliberately so.
/// Those map *camera* RGB to XYZ, and by the time a frame reaches the tables
/// it has already been through `CIRAWFilter`, which applied Apple's device
/// profile and left the pixels in linear Display P3. Applying a camera→XYZ
/// matrix to data that is no longer in camera space would stack a second
/// camera profile on the first. Reaching genuine matrix-level parity would
/// mean demosaicing the Bayer data ourselves instead of asking Core Image to,
/// which is a different and much larger piece of work; the tables are the part
/// that can be had without it, and the part the gap consists of.
enum DCPDecoder {
    enum Error: Swift.Error, LocalizedError {
        case profilesNotInstalled
        case profileNotFound(model: String)
        case noCameraModel(URL)

        var errorDescription: String? {
            switch self {
            case .profilesNotInstalled:
                return "Adobe camera profiles are not installed on this Mac."
            case .profileNotFound(let model):
                return "No Adobe profile matches the camera \"\(model)\"."
            case .noCameraModel(let url):
                return "\(url.lastPathComponent) does not say which camera shot it."
            }
        }
    }

    /// Where Lightroom keeps the profiles.
    ///
    /// Note this is the `CameraProfiles` root, not a `Camera/Apple`
    /// subdirectory — Adobe files iPhone and iPad profiles flat under
    /// `Adobe Standard/`, and the `Camera/` subtree holds only the makers it
    /// ships bespoke looks for. See `DCPProfileLocator` for the naming.
    static var cameraProfileDirectory: URL { DCPProfileLocator.profileRoot }

    /// Whether the path can run on this machine at all.
    static var isInstalled: Bool { DCPProfileLocator.isInstalled }

    /// The DCP for a camera model string — a DNG's `UniqueCameraModel`, e.g.
    /// `iPhone17,1 back camera`.
    static func dcpURL(for cameraModel: String) throws -> URL {
        guard DCPProfileLocator.isInstalled else { throw Error.profilesNotInstalled }
        do {
            return try DCPProfileLocator.profile(forCameraModel: cameraModel)
        } catch {
            throw Error.profileNotFound(model: cameraModel)
        }
    }

    /// The DCP that would be used for a source file, or `nil` if none would.
    /// For the settings picker, which wants to say whether the path will
    /// actually do anything for the project in front of the user.
    static func dcpURL(forFrame url: URL) -> URL? {
        guard let model = DngMetadata.cameraModel(url: url) else { return nil }
        return try? dcpURL(for: model)
    }

    /// The parsed profile for a source file.
    static func profile(forFrame url: URL) throws -> DCPFile {
        guard let model = DngMetadata.cameraModel(url: url) else {
            throw Error.noCameraModel(url)
        }
        return try DCPParser.parse(url: try dcpURL(for: model))
    }

    /// Decodes a DNG with its Adobe profile applied, to the engine's working
    /// texture: scene-linear Display P3, `rgba16Float`, top row first.
    ///
    /// This is `LinearFrameDecoder.decode(url:scale:path:recipe:)` on the
    /// `.dcpProfile` path, spelled out for callers that want the one frame
    /// rather than a decoder to keep. Frames come back with the profile
    /// already in them, so nothing downstream needs to know the path was used
    /// — which is why the grade engine required no new pass.
    static func decode(
        url: URL, recipe: GradeRecipe, device: MTLDevice
    ) throws -> MTLTexture {
        let decoder = try LinearFrameDecoder(device: device)
        let frame = try decoder.decode(url: url, path: .dcpProfile, recipe: recipe)
        if let reason = decoder.lastDCPFallbackReason {
            throw Error.profileNotFound(model: reason)
        }
        return frame.texture
    }
}
#endif
