import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import LetsLapseKit

// lapse shapemation — the synthetic corpus's Swift side, headless
// (docs/shapemation/synthetic-corpus.md §3–§5). `stage` turns Python's scene
// folders into project folders with a register written through the Kit's
// own shape factories; `plan` lays them out with the same
// `ShapemationPlan.make` the builder calls; `score` pushes each scene's truth
// through its placement and reports how far the perturbed register missed.
// `pack` and `render` are the doors out (WP4): a staged project (with
// `--project`, a real Photo project) as a `.lapse` the app imports, and the
// plan as the clip the builder would write. Only `render` decodes a pixel:
// every other size comes from the manifest and the register.

/// `text` padded with spaces to `width` columns (never cut).
func padded(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

/// The CLI's names for `ShapemationSort`.
func shapemationSort(named name: String) -> ShapemationSort? {
    switch name {
    case "largest": return .largestFirst
    case "smallest": return .smallestFirst
    case "capture": return .captureOrder
    default: return nil
    }
}

/// A project's label in every report: `<set>/<scene-id>`, the last two
/// components of its folder.
func shapemationLabel(for folder: URL) -> String {
    let parts = folder.standardizedFileURL.pathComponents.filter { $0 != "/" }
    return parts.suffix(2).joined(separator: "/")
}

/// A UUID that is the same for the same label on every run — an RFC 4122
/// version 5 UUID (SHA-1 over the URL namespace + the label), so a plan's
/// item ids can be compared across invocations, against a score, and with
/// Python's `uuid.uuid5(uuid.NAMESPACE_URL, "<set>/<scene-id>")`.
func shapemationItemID(for label: String) -> UUID {
    let namespaceURL: [UInt8] = [0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8]
    var bytes = Array(Insecure.SHA1.hash(data: Data(namespaceURL) + Data(label.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
}

/// The picture's size as it reads — the stored pixel size with a quarter-turn
/// orientation (5–8) swapping the axes — from the file's header alone, no
/// pixel decoded. Nil when ImageIO cannot read the header.
func orientedPixelSize(of url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
    switch OrientedDecode.orientation(of: source) {
    case .leftMirrored, .right, .rightMirrored, .left: return CGSize(width: height, height: width)
    default: return CGSize(width: width, height: height)
    }
}

// MARK: - JSON shapes (contract §4 and §5)

struct ShapemationDroppedJSON: Codable {
    var project: String
    var reason: String
}

/// A shape through a placement: a quad by its corners, an ellipse by its
/// centre and the transformed ends of its axes.
struct ShapemationPlacedJSON: Codable {
    var kind: String
    var cornersPx: [[Double]]?
    var centrePx: [Double]?
    var semiAxesPx: [Double]?
    var rotation: Double?

    init(shape: DetectedShape, frame: CGSize, through h: Homography) {
        let W = Double(frame.width), H = Double(frame.height)
        kind = shape.kind.rawValue
        switch shape.kind {
        case .quad:
            let corners = (shape.corners ?? []).map { h.apply(CGPoint(x: Double($0.x) * W, y: Double($0.y) * H)) }
            cornersPx = corners.map { [Double($0.x), Double($0.y)] }
        case .ellipse:
            let c = CGPoint(x: Double(shape.centre.x) * W, y: Double(shape.centre.y) * H)
            let a = shape.majorAxis * W / 2, b = shape.minorAxis * W / 2
            let cs = cos(shape.rotation), sn = sin(shape.rotation)
            let centre = h.apply(c)
            let a1 = h.apply(CGPoint(x: Double(c.x) + a * cs, y: Double(c.y) + a * sn))
            let a2 = h.apply(CGPoint(x: Double(c.x) - a * cs, y: Double(c.y) - a * sn))
            let b1 = h.apply(CGPoint(x: Double(c.x) - b * sn, y: Double(c.y) + b * cs))
            let b2 = h.apply(CGPoint(x: Double(c.x) + b * sn, y: Double(c.y) - b * cs))
            centrePx = [Double(centre.x), Double(centre.y)]
            semiAxesPx = [Double(hypot(a1.x - a2.x, a1.y - a2.y)) / 2, Double(hypot(b1.x - b2.x, b1.y - b2.y)) / 2]
            rotation = atan2(Double(a1.y - a2.y), Double(a1.x - a2.x))
        }
    }
}

struct ShapemationPlanJSON: Codable {
    struct Item: Codable {
        var id: UUID
        var project: String
        var scale: Double
        /// Row-major 3×3, source px → canvas px.
        var transform: [Double]
        var footprint: [Double]
        var placed: ShapemationPlacedJSON
    }
    var mode: String
    var family: String?
    var sort: String
    var shapeSizePx: Double
    var anchor: [Double]
    var canvas: [Double]
    var unionCanvas: [Double]
    var items: [Item]
    var dropped: [ShapemationDroppedJSON]
}

struct ShapemationScoreJSON: Codable {
    struct Item: Codable {
        var itemID: UUID
        var project: String
        var centrePx: Double
        var centre: Double
        var scale: Double
        var rotationDeg: Double
        var cornerRmsPx: Double?
    }
    var placed: Int
    var droppedCount: Int
    var dropped: [ShapemationDroppedJSON]
    var mode: String
    var family: String?
    var sort: String
    var shapeSizePx: Double
    var anchor: [Double]
    var canvas: [Double]
    var items: [Item]
    var centre: ShapemationScore.Stat?
    var scale: ShapemationScore.Stat?
    var rotationDeg: ShapemationScore.Stat?
    var cornerRmsPx: ShapemationScore.Stat?
    var pairwiseOverlap: ShapemationScore.Stat?
}

// MARK: - The plan, shared by plan and score

/// What `plan` worked out: the items it could build, in the sorted order the
/// plan was made from, the plan itself, and every project it lost with why.
struct ShapemationPlanContext {
    var mode: ShapemationMode
    var family: DetectedShape.Family?
    var sort: ShapemationSort
    var items: [ShapemationItem]
    var folders: [UUID: URL]
    var plan: ShapemationPlan?
    var dropped: [ShapemationDroppedJSON]

    var placedItems: [ShapemationItem] {
        guard let plan else { return [] }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return plan.placements.compactMap { byID[$0.itemID] }
    }
}

func shapemationBuildPlan(projects: [String], mode: ShapemationMode, family: DetectedShape.Family?, sort: ShapemationSort) -> ShapemationPlanContext {
    var items: [ShapemationItem] = []
    var folders: [UUID: URL] = [:]
    var dropped: [ShapemationDroppedJSON] = []
    // The one ShapeMatch the builder's Match step would pass: it decides
    // admissibility here and the placement in `make`, so the two cannot drift.
    let match = family.map { ShapeMatch(family: $0) }
    for path in projects {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let label = shapemationLabel(for: folder)
        guard let register = ShapeRegister.load(inProjectFolder: folder) else {
            dropped.append(.init(project: label, reason: "register unreadable"))
            continue
        }
        let admissible = match.map { m in register.shapes.filter { m.matches($0) } } ?? register.shapes
        guard let shape = admissible.max(by: { $0.nativeDiameterPx < $1.nativeDiameterPx }) else {
            dropped.append(.init(project: label, reason: "no admissible shape"))
            continue
        }
        // `ShapemationPlan.make` skips such a shape without a word.
        guard shape.majorAxis * Double(register.frameSize.width) > 0 else {
            dropped.append(.init(project: label, reason: "majorPx <= 0"))
            continue
        }
        let id = shapemationItemID(for: label)
        folders[id] = folder
        items.append(ShapemationItem(id: id, title: label, imageURL: folder.appendingPathComponent(register.representative.relativePath),
                                     pixelSize: register.frameSize, shape: shape, frameFraction: register.representative.frameFraction))
    }
    let sorted = sort.sorted(items)
    let plan = sorted.isEmpty ? nil : ShapemationPlan.make(items: sorted, mode: mode, match: match)
    if let plan {
        // Unreachable while `make`'s only silent skip is the majorPx check
        // above; kept so a new skip in `make` can never lose a project quietly.
        let placed = Set(plan.placements.map(\.itemID))
        for item in sorted where !placed.contains(item.id) {
            dropped.append(.init(project: item.title, reason: "plan skipped it"))
        }
    } else {
        for item in sorted { dropped.append(.init(project: item.title, reason: "plan returned nil")) }
    }
    return ShapemationPlanContext(mode: mode, family: family, sort: sort, items: sorted, folders: folders, plan: plan, dropped: dropped)
}

func shapemationPlanJSON(_ context: ShapemationPlanContext) -> ShapemationPlanJSON {
    let plan = context.plan
    let byID = Dictionary(context.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let items: [ShapemationPlanJSON.Item] = (plan?.placements ?? []).compactMap { p in
        guard let item = byID[p.itemID] else { return nil }
        return .init(id: item.id, project: item.title, scale: p.scale, transform: p.transform.m,
                     footprint: [Double(p.footprint.minX), Double(p.footprint.minY), Double(p.footprint.width), Double(p.footprint.height)],
                     placed: ShapemationPlacedJSON(shape: item.shape, frame: item.pixelSize, through: p.transform))
    }
    return ShapemationPlanJSON(
        mode: context.mode.rawValue, family: context.family?.rawValue, sort: context.sort.rawValue,
        shapeSizePx: plan?.shapeSizePx ?? 0,
        anchor: plan.map { [Double($0.anchor.x), Double($0.anchor.y)] } ?? [0, 0],
        canvas: plan.map { [Double($0.canvas.width), Double($0.canvas.height)] } ?? [0, 0],
        unionCanvas: plan.map { [Double($0.unionCanvas.width), Double($0.unionCanvas.height)] } ?? [0, 0],
        items: items, dropped: context.dropped)
}

func writeShapemationJSON<T: Encodable>(_ value: T, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    if path == "-" {
        print(String(decoding: data, as: UTF8.self))
    } else {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        print(path)
    }
}

/// The human-readable lines go through `say` so `score --json -` can keep
/// stdout for the JSON alone and move the table, the dropped list and the
/// SCORE line to stderr (the sweep greps both streams for the SCORE line).
///
/// `placed` and `dropped` default to the plan's own counts; `score` passes its
/// final ones so the header and the SCORE line never disagree.
func printShapemationPlanHeader(_ context: ShapemationPlanContext, placed: Int? = nil, dropped: Int? = nil,
                                say: (String) -> Void = { print($0) }) {
    let family = context.family.map { "family \($0.rawValue)" } ?? "any family"
    let placed = placed ?? context.plan?.placements.count ?? 0
    let dropped = dropped ?? context.dropped.count
    say("shapemation plan · \(context.mode.rawValue) · \(family) · sort \(context.sort.rawValue) · \(placed) placed · \(dropped) dropped")
    if let plan = context.plan {
        say(String(format: "  shape %.1f px at (%.1f, %.1f) · canvas %.0f×%.0f · union %.0f×%.0f", plan.shapeSizePx, plan.anchor.x, plan.anchor.y,
                   plan.canvas.width, plan.canvas.height, plan.unionCanvas.width, plan.unionCanvas.height))
    }
}

func printShapemationDropped(_ dropped: [ShapemationDroppedJSON], say: (String) -> Void = { print($0) }) {
    for d in dropped { say("  dropped \(d.project) — \(d.reason)") }
}

// MARK: - stage

func runShapemationStage(scenes: [String], out: String, link: Bool, project writeProject: Bool) throws {
    let fm = FileManager.default
    let outURL = URL(fileURLWithPath: out, isDirectory: true)
    var manifests: [URL] = []
    for path in scenes {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            fail("cannot list \(root.path)")
        }
        for case let url as URL in enumerator where url.lastPathComponent == SceneManifest.fileName {
            manifests.append(url)
        }
    }
    manifests.sort { $0.path < $1.path }
    guard !manifests.isEmpty else { fail("no \(SceneManifest.fileName) under \(scenes.joined(separator: ", "))") }

    var wrongFamily = 0
    for manifestURL in manifests {
        let sceneFolder = manifestURL.deletingLastPathComponent()
        let manifest: SceneManifest
        do { manifest = try SceneManifest.load(from: manifestURL) } catch {
            fail("\(manifestURL.path): \(error)")
        }
        let frameURL = sceneFolder.appendingPathComponent("frame.jpg")
        guard fm.fileExists(atPath: frameURL.path) else { fail("\(sceneFolder.path) has no frame.jpg") }
        // The manifest's geometry is in the oriented frame, so the picture
        // must read at that size — an orientation-6 file stores the axes
        // swapped, and a register written on the stored size would be wrong.
        guard let seen = orientedPixelSize(of: frameURL) else { fail("\(frameURL.path): ImageIO cannot read the header") }
        guard seen == manifest.frameSize else {
            fail("\(manifest.set)/\(manifest.id): frame.jpg reads as \(Int(seen.width))×\(Int(seen.height)) (orientation applied), the manifest says \(manifest.frame.width)×\(manifest.frame.height)")
        }
        let label = "\(manifest.set)/\(manifest.id)"
        let staged: ShapemationStaging.Staged
        do {
            staged = try ShapemationStaging.stage(manifestURL: manifestURL, into: outURL, link: link, project: writeProject)
        } catch let error as SceneManifest.GeometryError {
            fail("\(label): perturbed geometry — \(error)")
        } catch let error as ShapemationStaging.Failure {
            fail(error.description)
        }
        // Acceptance (§3): the register loaded back through the app's own
        // door with one shape of the kind the manifest set; the FAMILY is
        // what `--family` will later admit or drop.
        let family = staged.family
        if let id = staged.projectID {
            print("\(label) \(family.rawValue) \(id.uuidString)")
        } else {
            print("\(label) \(family.rawValue)")
        }
        if family != manifest.subject.family {
            printErr("\(label): loaded back as \(family.rawValue), the scene intended \(manifest.subject.family.rawValue)")
            wrongFamily += 1
        }
    }
    if wrongFamily > 0 {
        fail("\(wrongFamily) of \(manifests.count) register(s) loaded back with a family the scene did not intend")
    }
    printErr("staged \(manifests.count) scene(s) under \(outURL.path)")
}

// MARK: - plan

func runShapemationPlan(projects: [String], mode: ShapemationMode, family: DetectedShape.Family?, sort: ShapemationSort, jsonPath: String?) throws {
    let context = shapemationBuildPlan(projects: projects, mode: mode, family: family, sort: sort)
    if let jsonPath {
        try writeShapemationJSON(shapemationPlanJSON(context), to: jsonPath)
        return
    }
    printShapemationPlanHeader(context)
    if let plan = context.plan {
        let byID = Dictionary(context.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        print("  #   project                              scale   footprint (x, y, w×h)              placed centre")
        for (n, p) in plan.placements.enumerated() {
            guard let item = byID[p.itemID] else { continue }
            let placed = ShapemationPlacedJSON(shape: item.shape, frame: item.pixelSize, through: p.transform)
            let centre: [Double]
            if let c = placed.centrePx { centre = c }
            else if let corners = placed.cornersPx, corners.count == 4 {
                centre = [corners.map { $0[0] }.reduce(0, +) / 4, corners.map { $0[1] }.reduce(0, +) / 4]
            } else { centre = [0, 0] }
            print("  \(padded("\(n + 1)", 3)) \(padded(item.title, 36)) "
                  + String(format: "%6.3f   %7.1f, %7.1f, %6.0f×%-6.0f   (%.1f, %.1f)", p.scale,
                           p.footprint.minX, p.footprint.minY, p.footprint.width, p.footprint.height, centre[0], centre[1]))
        }
    }
    printShapemationDropped(context.dropped)
}

// MARK: - score

func runShapemationScore(projects: [String], mode: ShapemationMode, family: DetectedShape.Family?, sort: ShapemationSort, jsonPath: String?) throws {
    let context = shapemationBuildPlan(projects: projects, mode: mode, family: family, sort: sort)
    var dropped = context.dropped
    var truths: [UUID: SceneManifest.Geometry] = [:]
    for item in context.placedItems {
        guard let folder = context.folders[item.id] else { continue }
        do {
            truths[item.id] = try SceneManifest.load(inProjectFolder: folder).truth
        } catch {
            // A closed set of reasons (§4); the error itself goes to stderr.
            printErr("\(item.title): \(SceneManifest.fileName) unreadable — \(error)")
            dropped.append(.init(project: item.title, reason: "scene.json unreadable"))
        }
    }
    let byID = Dictionary(context.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let score = context.plan.map { ShapemationScore.measure(plan: $0, items: context.items, truths: truths) } ?? .empty

    // With the JSON on stdout everything else moves to stderr, so a pipe gets the JSON alone.
    let say: (String) -> Void = jsonPath == "-" ? { printErr($0) } : { print($0) }
    if family == nil, context.placedItems.contains(where: { $0.shape.kind == .quad }) {
        printErr("note: no --family — quads were placed by similarity (levelled and scaled), not the builder's rectanglePlacement; a posed set scores a corner residual here that the app never sees")
    }
    printShapemationPlanHeader(context, placed: score.placed, dropped: dropped.count, say: say)
    say("  project                              centre   centrePx    scale   rotation   corners rms")
    for s in score.items {
        let label = byID[s.itemID]?.title ?? s.itemID.uuidString
        let rms = s.cornerRmsPx.map { String(format: "%7.2f px", $0) } ?? "      —"
        say("  \(padded(label, 36)) " + String(format: "%6.3f  %8.2f  %+7.4f  %+7.2f°  ", s.centre, s.centrePx, s.scale, s.rotationDeg) + rms)
    }
    if let o = score.pairwiseOverlap {
        say(String(format: "  pairwise overlap: median %.3f · p90 %.3f · max %.3f", o.median, o.p90, o.max))
    }
    printShapemationDropped(dropped, say: say)

    if let jsonPath {
        let plan = context.plan
        let json = ShapemationScoreJSON(
            placed: score.placed, droppedCount: dropped.count, dropped: dropped,
            mode: mode.rawValue, family: family?.rawValue, sort: sort.rawValue,
            shapeSizePx: plan?.shapeSizePx ?? 0,
            anchor: plan.map { [Double($0.anchor.x), Double($0.anchor.y)] } ?? [0, 0],
            canvas: plan.map { [Double($0.canvas.width), Double($0.canvas.height)] } ?? [0, 0],
            items: score.items.map { s in
                .init(itemID: s.itemID, project: byID[s.itemID]?.title ?? "", centrePx: s.centrePx, centre: s.centre,
                      scale: s.scale, rotationDeg: s.rotationDeg, cornerRmsPx: s.cornerRmsPx)
            },
            centre: score.centre, scale: score.scale, rotationDeg: score.rotationDeg,
            cornerRmsPx: score.cornerRmsPx, pairwiseOverlap: score.pairwiseOverlap)
        try writeShapemationJSON(json, to: jsonPath)
    }
    // The greppable verdict, last on stdout (last on stderr under `--json -`).
    say(score.summaryLine(dropped: dropped.count))
}

// MARK: - pack

/// The capture id a project folder's document names — the archive's name.
func shapemationProjectID(inFolder folder: URL) throws -> UUID {
    let url = ProjectDocumentFormat.url(inProjectFolder: folder)
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    guard let capture = object?["capture"] as? [String: Any], let text = capture["id"] as? String, let id = UUID(uuidString: text) else {
        throw LapseError.writerFailed("\(url.path) names no capture id")
    }
    return id
}

/// One `<id>.lapse` per project: the folder's contents archived in place
/// — `project.json` at the root as the manifest the installer reads, the
/// way `AppModel.exportProject` writes one — so the app's `.lapse` door
/// (a double-click, `LL_IMPORT_ARCHIVE`) installs it, minting a fresh id
/// and keeping this one as `importedFromID`/`originID`.
func runShapemationPack(projects: [String], out: String) throws {
    let outURL = URL(fileURLWithPath: out, isDirectory: true)
    try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
    for path in projects {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: ProjectDocumentFormat.url(inProjectFolder: folder).path) else {
            fail("\(shapemationLabel(for: folder)) has no \(ProjectFileRegistry.projectDocumentName) — stage it with --project first")
        }
        let id = try shapemationProjectID(inFolder: folder)
        let archive = outURL.appendingPathComponent("\(id.uuidString).lapse")
        try DirectoryArchive.write(contentsOf: folder, to: archive)
        print(archive.path)
    }
}

// MARK: - render

/// `1s` / `0.5s` / `3f` — a hold as the CLI spells it.
func shapemationHold(_ text: String) -> ShapemationTiming.Hold? {
    if text.hasSuffix("s"), let seconds = Double(text.dropLast()), seconds > 0 { return .seconds(seconds) }
    if text.hasSuffix("f"), let frames = Int(text.dropLast()), frames > 0 { return .frames(frames) }
    return nil
}

/// The output size for a plan: the first of the plan's own options whose
/// long edge fits `longEdge`, else the canvas scaled to it — even sides,
/// and never past 4096 on a side, which is as much as the H.264 writer takes.
func shapemationOutputSize(plan: ShapemationPlan, longEdge: Double) -> CGSize {
    let cap = min(longEdge, 4096)
    if let fit = plan.outputOptions().first(where: { max($0.size.width, $0.size.height) <= cap }) { return fit.size }
    let canvas = plan.canvas.size
    let s = cap / max(canvas.width, canvas.height)
    let scaled = CGSize(width: canvas.width * s, height: canvas.height * s)
    return CGSize(width: max(2, floor(scaled.width / 2) * 2), height: max(2, floor(scaled.height / 2) * 2))
}

/// The clip: `plan`'s layout through `ShapemationRenderer` with the
/// Timing step's answer, every representative decoded as it reads.
func runShapemationRender(projects: [String], out: String, mode: ShapemationMode, family: DetectedShape.Family?, sort: ShapemationSort,
                          timing: ShapemationTiming, longEdge: Double, jsonPath: String?) throws {
    let context = shapemationBuildPlan(projects: projects, mode: mode, family: family, sort: sort)
    if let jsonPath { try writeShapemationJSON(shapemationPlanJSON(context), to: jsonPath) }
    printShapemationPlanHeader(context, say: { printErr($0) })
    printShapemationDropped(context.dropped, say: { printErr($0) })
    guard let plan = context.plan else { fail("nothing to render — the plan placed no project") }
    let items = context.placedItems
    let outputSize = shapemationOutputSize(plan: plan, longEdge: longEdge)
    printErr("  \(timing.summary) · \(timing.estimate(count: items.count)) · output \(Int(outputSize.width))×\(Int(outputSize.height))")

    let renderer = ShapemationRenderer()
    renderer.timing = timing
    let url = URL(fileURLWithPath: out)
    let load: ShapemationRenderer.ImageLoader = { item in
        let long = Int(max(item.pixelSize.width, item.pixelSize.height))
        guard let image = OrientedDecode.cgImage(url: item.imageURL, maxPixelSize: max(1, long)) else {
            throw LapseError.writerFailed("\(item.title): could not decode \(item.imageURL.path)")
        }
        return image
    }
    _ = try renderer.render(plan: plan, items: items, outputSize: outputSize, to: url, load: load, progress: { p in
        FileHandle.standardError.write(Data("\rrendering… \(p.done)/\(p.total)\(p.done >= p.total ? "\n" : " \(p.title)")".utf8))
    })
    let frames = timing.totalFrames(count: items.count)
    print(String(format: "%@ · %d frames · %.2f s · %d×%d", url.path, frames, timing.totalSeconds(count: items.count),
                 Int(outputSize.width), Int(outputSize.height)))
}

func runShapemation(subcommand: String, args: [String], out: String?, link: Bool, project: Bool, mode: ShapemationMode,
                    family: DetectedShape.Family?, sort: ShapemationSort?, timing: ShapemationTiming, longEdge: Double,
                    jsonPath: String?) throws {
    switch subcommand {
    case "stage":
        guard let out else { fail("shapemation stage needs --out <projects-dir>") }
        guard !args.isEmpty else { fail("shapemation stage needs a scenes directory") }
        try runShapemationStage(scenes: args, out: out, link: link, project: project)
    case "plan":
        guard !args.isEmpty else { fail("shapemation plan needs at least one project folder") }
        try runShapemationPlan(projects: args, mode: mode, family: family, sort: sort ?? .largestFirst, jsonPath: jsonPath)
    case "score":
        guard !args.isEmpty else { fail("shapemation score needs at least one project folder") }
        try runShapemationScore(projects: args, mode: mode, family: family, sort: sort ?? .largestFirst, jsonPath: jsonPath)
    case "pack":
        guard let out else { fail("shapemation pack needs --out <dir>") }
        guard !args.isEmpty else { fail("shapemation pack needs at least one project folder") }
        try runShapemationPack(projects: args, out: out)
    case "render":
        guard let out else { fail("shapemation render needs --out <clip.mp4>") }
        guard !args.isEmpty else { fail("shapemation render needs at least one project folder") }
        // `.captureOrder` keeps the order given (the CLI never reads createdAt):
        // a staged sequence's zero-padded ids glob in approach order, so the
        // default plays them as shot.
        try runShapemationRender(projects: args, out: out, mode: mode, family: family, sort: sort ?? .captureOrder,
                                 timing: timing, longEdge: longEdge, jsonPath: jsonPath)
    default:
        fail("shapemation needs stage | plan | score | pack | render, not '\(subcommand)'")
    }
}
