import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LetsLapseKit

/// The three doors out of the synthetic corpus (docs/shapemation/
/// synthetic-corpus.md §3, WP4): a staged scene with `--project` is a Photo
/// project the app's document reader takes — kind `photos`, one source, the
/// manifest's pixel size, an id that is its own origin; `pack`'s archive
/// extracts to the same file list; and a three-frame render writes a clip.
final class ShapemationStageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shapemation-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A hand-made scene folder: a flat JPEG of `size` with a darker
    /// rectangle where the truth quad says, and its manifest with an extra
    /// key the Kit does not decode (what the file copy must keep).
    private func makeScene(set: String, id: String, index: Int, size: CGSize, quad: CGRect) throws -> URL {
        let folder = root.appendingPathComponent("scenes/\(set)/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let w = Int(size.width), h = Int(size.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.55, green: 0.7, blue: 0.9, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.15, alpha: 1))
        // The quad is y-down; CoreGraphics is y-up.
        context.fill(CGRect(x: quad.minX, y: size.height - quad.maxY, width: quad.width, height: quad.height))
        let image = try XCTUnwrap(context.makeImage())
        let jpeg = folder.appendingPathComponent("frame.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let corners = [[quad.minX, quad.minY], [quad.maxX, quad.minY], [quad.maxX, quad.maxY], [quad.minX, quad.maxY]]
        let manifest: [String: Any] = [
            "schema": 1, "id": id, "set": set,
            "frame": ["width": w, "height": h],
            "subject": ["part": "tram_front", "viewpoint": "front", "scene": "test", "family": "rectangle"],
            "sequence": ["index": index, "of": 3, "approach": Double(index) / 2],
            "truth": ["kind": "quad", "cornersPx": corners, "tiltDeg": 0, "yawDeg": 0],
            "perturbed": ["kind": "quad", "cornersPx": corners],
            "perturbation": ["sigmaScale": 0, "sigmaCentre": 0, "sigmaRotationDeg": 0, "seed": 1],
            "truthPolygon": [[quad.minX, quad.maxY], [quad.minX, quad.minY], [quad.midX, quad.minY - 10]],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: folder.appendingPathComponent("scene.json"))
        return folder
    }

    private func fileList(_ folder: URL) throws -> [String] {
        let base = folder.resolvingSymlinksInPath().path
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        var names: [String] = []
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            names.append(String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1)))
        }
        return names.sorted()
    }

    func testStageWithProjectWritesAPhotoProjectTheAppReads() throws {
        let scene = try makeScene(set: "hand", id: "front-0001", index: 1, size: CGSize(width: 640, height: 480),
                                  quad: CGRect(x: 200, y: 150, width: 240, height: 160))
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let staged = try ShapemationStaging.stage(manifestURL: scene.appendingPathComponent("scene.json"), into: projects, project: true, now: now)
        XCTAssertEqual(staged.family, .rectangle)
        XCTAssertEqual(staged.folder.lastPathComponent, "front-0001")
        let id = try XCTUnwrap(staged.projectID)

        // The document, as the app's reader (formatVersion, capture, blends) takes it.
        let data = try Data(contentsOf: ProjectDocumentFormat.url(inProjectFolder: staged.folder))
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(document["formatVersion"] as? Int, ProjectDocumentFormat.current)
        XCTAssertEqual((document["blends"] as? [Any])?.count, 0)
        let capture = try XCTUnwrap(document["capture"] as? [String: Any])
        XCTAssertEqual(capture["id"] as? String, id.uuidString)
        XCTAssertEqual(capture["originID"] as? String, id.uuidString)
        XCTAssertEqual(capture["kind"] as? String, "photos")
        XCTAssertEqual(capture["mode"] as? String, ProjectModes.importedPhoto)
        XCTAssertEqual(capture["originalName"] as? String, "front-0001.jpg", "file-shaped, as the app's import writes it")
        XCTAssertEqual(capture["sourceFileNames"] as? [String], ["source/frame.jpg"])
        XCTAssertEqual(capture["sourceWidth"] as? Int, 640)
        XCTAssertEqual(capture["sourceHeight"] as? Int, 480)
        XCTAssertEqual(ProjectCategory.classify(kind: "photos", mode: capture["mode"] as? String ?? "", captureMode: nil, scannerSidecar: false), .photo)
        // Dates in the document's form, the capture date fixed by set and index.
        let created = try XCTUnwrap(ProjectDocumentFormat.manifestSeconds(fromDocumentDate: capture["createdAt"] as? String ?? ""))
        XCTAssertEqual(created, ShapemationStaging.captureDate(set: "hand", index: 1).timeIntervalSinceReferenceDate, accuracy: 0.001)
        XCTAssertEqual(ShapemationStaging.captureDate(set: "hand", index: 2).timeIntervalSince(ShapemationStaging.captureDate(set: "hand", index: 1)), 60)
        let added = try XCTUnwrap(ProjectDocumentFormat.manifestSeconds(fromDocumentDate: capture["addedAt"] as? String ?? ""))
        XCTAssertEqual(added, now.timeIntervalSinceReferenceDate, accuracy: 0.001)

        // The asset record, the register and the manifest — copied verbatim, extra key and all.
        let records = AssetRecords.load(inProjectFolder: staged.folder)
        XCTAssertEqual(records.ordered.map(\.name), ["source/frame.jpg"])
        XCTAssertNotNil(records.ordered.first?.hash)
        XCTAssertEqual(ShapeRegister.load(inProjectFolder: staged.folder)?.shapes.count, 1)
        let copied = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: SceneManifest.url(inProjectFolder: staged.folder))) as? [String: Any])
        XCTAssertNotNil(copied["truthPolygon"], "the manifest travels byte for byte, unknown keys included")
        XCTAssertTrue(ProjectFileRegistry.travellingRootFiles.contains(SceneManifest.fileName), "scene.json survives an install")

        // A second stage mints a fresh id and does not double the asset record.
        let again = try ShapemationStaging.stage(manifestURL: scene.appendingPathComponent("scene.json"), into: projects, project: true, now: now)
        XCTAssertNotEqual(again.projectID, id)
        XCTAssertEqual(AssetRecords.load(inProjectFolder: staged.folder).ordered.count, 1)
    }

    /// The app titles an imported photo by `originalName` less its path
    /// extension (`AppModel.title`), and a kit scene id ends in `.07`: the
    /// name must survive that with the index intact, so every project of a
    /// set reads differently in the lists.
    func testStagedTitlesAreUniqueAcrossASet() throws {
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        var titles: [String] = []
        for n in 1...3 {
            let id = String(format: "hand.approach.%02d", n)
            let scene = try makeScene(set: "hand.approach", id: id, index: n - 1, size: CGSize(width: 320, height: 240),
                                      quad: CGRect(x: 100, y: 80, width: 120, height: 80))
            let staged = try ShapemationStaging.stage(manifestURL: scene.appendingPathComponent("scene.json"), into: projects, project: true)
            let data = try Data(contentsOf: ProjectDocumentFormat.url(inProjectFolder: staged.folder))
            let capture = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["capture"] as? [String: Any])
            let name = try XCTUnwrap(capture["originalName"] as? String)
            XCTAssertFalse(name.contains("/"), "a file name, never a path")
            titles.append((name as NSString).deletingPathExtension)
        }
        XCTAssertEqual(titles, ["hand.approach.01", "hand.approach.02", "hand.approach.03"])
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    func testPackedArchiveExtractsToTheSameFileList() throws {
        let scene = try makeScene(set: "hand", id: "front-0002", index: 2, size: CGSize(width: 320, height: 240),
                                  quad: CGRect(x: 100, y: 80, width: 120, height: 80))
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let staged = try ShapemationStaging.stage(manifestURL: scene.appendingPathComponent("scene.json"), into: projects, project: true)
        let archive = root.appendingPathComponent("\(staged.projectID!.uuidString).lapse")
        try DirectoryArchive.write(contentsOf: staged.folder, to: archive)
        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        try DirectoryArchive.extract(archive, to: extracted)
        let files = try fileList(extracted)
        XCTAssertEqual(files, try fileList(staged.folder))
        XCTAssertEqual(files, ["assets.ndjson", "project.json", "scene.json", "shapes.json", "source/frame.jpg"])
        // The archive is rooted at the project folder: the document is the manifest at its root.
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProjectDocumentFormat.url(inProjectFolder: extracted).path))
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("source/frame.jpg")),
                       try Data(contentsOf: staged.folder.appendingPathComponent("source/frame.jpg")))
    }

    /// Three staged scenes through the plan and the renderer at 320 px —
    /// AVFoundation in a test, so a small clip, a few frames.
    func testThreeStagedScenesRenderAClip() async throws {
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        var items: [ShapemationItem] = []
        for (n, side) in [80.0, 110.0, 150.0].enumerated() {
            let scene = try makeScene(set: "hand", id: "front-000\(n)", index: n, size: CGSize(width: 640, height: 480),
                                      quad: CGRect(x: 320 - side * 0.75, y: 240 - side / 2, width: side * 1.5, height: side))
            let staged = try ShapemationStaging.stage(manifestURL: scene.appendingPathComponent("scene.json"), into: projects, project: true)
            let register = try XCTUnwrap(ShapeRegister.load(inProjectFolder: staged.folder))
            items.append(ShapemationItem(title: "\(n)", imageURL: staged.folder.appendingPathComponent(register.representative.relativePath),
                                         pixelSize: register.frameSize, shape: register.shapes[0]))
        }
        let match = ShapeMatch(family: .rectangle)
        let plan = try XCTUnwrap(ShapemationPlan.make(items: items, mode: .stack, match: match))
        XCTAssertEqual(plan.placements.count, 3)
        let long = max(plan.canvas.width, plan.canvas.height)
        let s = min(1, 320 / long)
        let size = CGSize(width: max(2, floor(plan.canvas.width * s / 2) * 2), height: max(2, floor(plan.canvas.height * s / 2) * 2))

        let renderer = ShapemationRenderer()
        renderer.timing = ShapemationTiming(fps: 25, each: .frames(1))
        let clip = root.appendingPathComponent("clip.mp4")
        let started = Date()
        let poster = try renderer.render(plan: plan, items: items, outputSize: size, to: clip, load: { item in
            try XCTUnwrap(OrientedDecode.cgImage(url: item.imageURL, maxPixelSize: 640))
        })
        XCTAssertNotNil(poster)
        XCTAssertEqual(poster?.width, Int(size.width))
        let bytes = try XCTUnwrap(try clip.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a 3-frame 320 px clip should be quick")

        // The clip holds the three photos, one frame each at 25 fps — not one frame per plan.
        let asset = AVURLAsset(url: clip)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 3.0 / 25, accuracy: 1e-3)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let (frameRate, natural) = try await track.load(.nominalFrameRate, .naturalSize)
        XCTAssertEqual(frameRate, 25, accuracy: 0.01)
        XCTAssertEqual(natural, size)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        // Compressed samples as stored: the reader also hands out empty
        // marker buffers (no samples), which are not frames.
        var frames = 0
        while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }
        XCTAssertEqual(frames, 3)
    }
}
