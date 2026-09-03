import Foundation
import LetsLapseKit
import Metal

// lapse poster — the time-slice poster fast path, headless
// (docs/time-slicing-poster-fast-path.md §7 stage 3). Renders only the
// master frames a poster's ladder needs, each still blended at `--depth`
// through the same window primitive `lapse stackseq` / the app's blend use,
// and never encodes a clip. The Mac shell can time it against
// `lapse stackseq` + `lapse slice --poster` over the same stills.

func runPoster(
    urls: [URL], outputPath: String, depth: Int, settings: TimeSliceSettings,
    variations: Int, variationMode: TimeSliceVariationMode, seed: UInt64,
    recipeJSON: String?, gamma: Bool
) throws {
    let windows = WindowSchedule.make(totalInputFrames: urls.count, ramp: .constant(max(1, depth)))
    let core = try BlendCore()
    let started = Date()

    let decode: StillsWindowProvider.Decode
    if gamma {
        decode = .gamma(load: { try ImageStacker.loadImage(at: $0) }, linearLight: false)
    } else {
        // The linear path, staged the way `runStackSequence` stages it: the
        // renderer anchors to the first decoded frame's reference.
        let recipe = try recipeJSON.map { try parseRecipe(json: $0) } ?? GradeRecipe()
        let path = RawDecodePath.current
        let decoder = try LinearFrameDecoder()
        let engine = try GradeEngine(device: decoder.device)
        var renderer: GradeRenderer?
        decode = .linear(
            decode: { url in
                let frame = try decoder.decode(url: url, path: path, recipe: recipe)
                if renderer == nil {
                    renderer = engine.makeRenderer(recipe, reference: frame.reference())
                }
                return frame.texture
            },
            grade: { texture, commandBuffer, _ in
                guard let renderer else { return texture }
                return try renderer.encode(from: texture, commandBuffer: commandBuffer)
            })
    }

    var stillsTotal = urls.count
    let provider = try StillsWindowProvider(
        core: core, urls: urls, windows: windows, decode: decode,
        onStillDecoded: { decoded in
            progressToStderr(min(0.99, Double(decoded) / Double(max(1, stillsTotal))))
        })
    let masterFrames = provider.frameCount

    var recipes = [settings]
    if variations >= 2 {
        recipes = TimeSliceVariationGenerator.variations(
            plan: TimeSliceVariationPlan(count: variations, mode: variationMode, seed: seed),
            baseline: settings, masterFrames: masterFrames,
            width: provider.width, height: provider.height)
        guard !recipes.isEmpty else { fail("no valid variation fits these stills") }
        print("batch of \(recipes.count) (\(variationMode.rawValue), seed \(seed))")
    }

    // The cost, quoted before the work: the union's windows, plus still 0
    // when no window the ladder needs starts there (it is always decoded
    // for the size).
    let union = try TimeSliceRenderer.posterFrameIndices(
        recipes: recipes, masterFrames: masterFrames,
        width: provider.width, height: provider.height)
    stillsTotal = union.reduce(0) { $0 + provider.sourceRange(of: $1).count }
        + (union.first == 0 ? 0 : 1)
    printErr("rendering \(union.count) of \(masterFrames) master frames "
        + "(\(stillsTotal) of \(urls.count) stills at depth \(max(1, depth)))")

    let posterURLs = recipes.map { recipe -> URL in
        let suffix = recipe.variation.map { "-\($0.label)" } ?? ""
        return URL(fileURLWithPath: insertSuffix(suffix, into: outputPath))
    }
    let results = try TimeSliceRenderer().renderPosters(
        provider: provider, recipes: recipes, posterURLs: posterURLs,
        posterMetadata: ImageExporter.carryoverMetadata(from: urls[0]))
    let elapsed = Date().timeIntervalSince(started)
    progressToStderr(1)
    for (recipe, result, url) in zip(recipes, zip(results, posterURLs)).map({ ($0.0, $0.1.0, $0.1.1) }) {
        print("\(recipe.posterDisplayName): \(union.count) of \(result.masterFrames) master frames rendered"
            + " (\(result.width)x\(result.height)"
            + (result.grid.map { ", \($0.summary)" } ?? "") + ")")
        print(url.path)
    }
    print("poster\(recipes.count > 1 ? "s" : "") in \(String(format: "%.1f", elapsed))s "
        + "· \(provider.stillsDecoded) stills decoded")
}
