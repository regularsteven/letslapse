import Metal
import simd
import XCTest
@testable import LetsLapseKit

/// Which of the profile's two tables is doing what.
///
/// A DCP carries a `ProfileHueSatMap` and a `ProfileLookTable`, and they are
/// not the same kind of object. The hue/sat map is *calibration* — Adobe's
/// measurement of this sensor, meant to be applied to camera data that has
/// been through the profile's own forward matrix. The look table is a *look*,
/// meant to sit on top of a rendered image.
///
/// That distinction matters here because this engine's frames arrive already
/// rendered by `CIRAWFilter` through Apple's device profile. The look table
/// still lands on exactly the kind of input it was designed for. The hue/sat
/// map does not: applying Adobe's calibration of the raw sensor on top of
/// Apple's calibration of the same sensor stacks two corrections for one
/// error. This test measures whether that is a real problem or a theoretical
/// one, on the frame the whole comparison is anchored to.
final class DCPTableAblationTests: XCTestCase {

    private static let frameURL = URL(fileURLWithPath:
        "/Volumes/letslapse/Projects/ACF3E290-87F9-49C9-8F5D-69A0C62B786D/source/frame-00001.dng")
    private static let waterPatch = CGRect(x: 120, y: 1812, width: 200, height: 160)

    private static let warmed: GradeRecipe = {
        var recipe = GradeRecipe()
        recipe.temperatureMired = 60
        return recipe
    }()

    /// A copy of a profile with one or both tables removed.
    private func ablated(
        _ profile: DCPFile, keepHueSat: Bool, keepLook: Bool
    ) -> DCPFile {
        DCPFile(
            profileName: profile.profileName,
            uniqueCameraModel: profile.uniqueCameraModel,
            forwardMatrix1: profile.forwardMatrix1,
            forwardMatrix2: profile.forwardMatrix2,
            hasForwardMatrices: profile.hasForwardMatrices,
            colorMatrix1: profile.colorMatrix1,
            colorMatrix2: profile.colorMatrix2,
            illuminant1K: profile.illuminant1K,
            illuminant2K: profile.illuminant2K,
            hueSatMapDims: keepHueSat ? profile.hueSatMapDims : SIMD3<Int>(0, 0, 0),
            hueSatMapData1: keepHueSat ? profile.hueSatMapData1 : [],
            hueSatMapData2: keepHueSat ? profile.hueSatMapData2 : [],
            lookTableDims: keepLook ? profile.lookTableDims : SIMD3<Int>(0, 0, 0),
            lookTableData: keepLook ? profile.lookTableData : [],
            toneCurve: profile.toneCurve)
    }

    private func meanRGB(_ texture: MTLTexture, patch: CGRect, scale: Float) -> SIMD3<Double> {
        let region = CGRect(
            x: patch.minX * CGFloat(scale), y: patch.minY * CGFloat(scale),
            width: patch.width * CGFloat(scale), height: patch.height * CGFloat(scale))
            .integral
            .intersection(CGRect(x: 0, y: 0, width: texture.width, height: texture.height))
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return .zero }
        let width = Int(region.width), height = Int(region.height)
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: width * 8,
                from: MTLRegionMake2D(Int(region.minX), Int(region.minY), width, height),
                mipmapLevel: 0)
        }
        var sum = SIMD3<Double>.zero
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += SIMD3<Double>(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
        }
        return sum / Double(width * height)
    }

    private func blueOverGreen(_ rgb: SIMD3<Double>) -> Double {
        rgb.y > 1e-9 ? rgb.z / rgb.y : .infinity
    }

    /// Renders the shadow patch under each combination of tables.
    ///
    /// Diagnostic rather than a gate: it prints the four numbers and asserts
    /// only that each table demonstrably moves pixels. Which combination sits
    /// closest to Lightroom is a judgement about a reference render, and this
    /// suite has no Lightroom export to measure against — pretending otherwise
    /// by asserting a direction would be inventing the answer.
    func testTableAblation_shadowChrominance() throws {
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: Self.frameURL.path),
            "calibration frame unavailable — mount /Volumes/letslapse")
        try XCTSkipIf(!DCPProfileLocator.isInstalled, "Adobe camera profiles are not installed")
        guard let model = DngMetadata.cameraModel(url: Self.frameURL),
              let profileURL = try? DCPProfileLocator.profile(forCameraModel: model) else {
            throw XCTSkip("no Adobe profile for this frame's camera")
        }
        let profile = try DCPParser.parse(url: profileURL)

        let decoder = try LinearFrameDecoder()
        let engine = try GradeEngine(device: decoder.device)
        let applier = try DCPProfileApplier(device: decoder.device)
        guard let queue = decoder.device.makeCommandQueue() else {
            throw XCTSkip("no command queue")
        }

        // Decode once on the ciraw path — same pixels the DCP path starts
        // from, since the two share their white-balance ordering.
        let frame = try decoder.decode(
            url: Self.frameURL, scale: 0.5, path: .cirawFilter, recipe: Self.warmed)

        func measure(_ label: String, keepHueSat: Bool, keepLook: Bool) throws -> Double {
            let variant = ablated(profile, keepHueSat: keepHueSat, keepLook: keepLook)
            let texture = try applier.apply(
                variant, to: frame.texture, temperatureK: Float(frame.asShotTemperatureK),
                commandQueue: queue, cacheKey: "\(profileURL.path)#\(keepHueSat)#\(keepLook)",
                // `.lookAndHueSat` so the applier honours whichever tables the
                // ablation left in place; which of them the *shipped* path
                // enables is this test's subject, not its setup.
                tables: .lookAndHueSat)
            let renderer = engine.makeRenderer(Self.warmed, reference: frame.reference())
            let graded = try renderer.apply(to: texture)
            let rgb = meanRGB(graded, patch: Self.waterPatch, scale: 0.5)
            let ratio = blueOverGreen(rgb)
            print(String(
                format: "  %-26@  R %.5f  G %.5f  B %.5f   B/G %.4f",
                label as NSString, rgb.x, rgb.y, rgb.z, ratio))
            return ratio
        }

        print("== DCP table ablation, shadow patch (temperature +60 mired) ==")
        let none = try measure("neither table (= ciraw)", keepHueSat: false, keepLook: false)
        let lookOnly = try measure("look table only (shipped)", keepHueSat: false, keepLook: true)
        let hsmOnly = try measure("hue/sat map only", keepHueSat: true, keepLook: false)
        let both = try measure("both tables", keepHueSat: true, keepLook: true)
        print(String(
            format: "  look table alone: %+.2f%%   hue/sat map alone: %+.2f%%   both: %+.2f%%",
            (lookOnly / none - 1) * 100, (hsmOnly / none - 1) * 100, (both / none - 1) * 100))

        XCTAssertNotEqual(lookOnly, none, accuracy: 1e-5, "the look table changed nothing")
        XCTAssertNotEqual(hsmOnly, none, accuracy: 1e-5, "the hue/sat map changed nothing")

        // The finding that set `Tables.lookOnly` as the default, kept as a
        // check rather than a comment: the two tables disagree about which way
        // the shadow should go, and only the look table moves it away from the
        // cold cast. If a future change to the working space or the decode
        // ordering makes them agree, this fails and the default should be
        // revisited — that is the point of pinning it.
        XCTAssertLessThan(
            lookOnly, none,
            "the look table should reduce the shadow blue cast")
        XCTAssertGreaterThan(
            hsmOnly, none,
            "the hue/sat map is expected to increase it here — it double-corrects "
            + "a sensor deviation CIRAWFilter has already corrected")
    }
}
