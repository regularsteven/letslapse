import Foundation
import CoreGraphics
import CryptoKit

// One synthetic scene into one project folder (docs/shapemation/synthetic-
// corpus.md §3, WP4): the frame, the register written through the Kit's own
// shape factories from the manifest's perturbed outline, the manifest copied
// beside it — and, asked for, the project document and asset record that
// make it a Photo project the app adopts at launch or installs from a
// `.lapse`. `lapse shapemation stage` walks the scene folders and prints;
// this is what it does to each, so a test can stage one without the CLI.

public enum ShapemationStaging {

    public struct Staged: Equatable, Sendable {
        public var folder: URL
        /// The family the register loaded back with — `stage`'s acceptance
        /// compares it with what the scene intended.
        public var family: DetectedShape.Family
        /// The project's id when `project` was asked for.
        public var projectID: UUID?
    }

    public enum Failure: Error, CustomStringConvertible {
        case registerDidNotLoadBack(URL)
        case registerLoadedBackWrong(URL, count: Int, kind: String?, wanted: String)

        public var description: String {
            switch self {
            case .registerDidNotLoadBack(let folder):
                return "\(folder.path): the register did not load back"
            case .registerLoadedBackWrong(let folder, let count, let kind, let wanted):
                return "\(folder.path): the register loaded back with \(count) shape(s) of kind \(kind ?? "none"), wanted one \(wanted)"
            }
        }
    }

    /// The frame's name inside the project.
    public static let frameRelativePath = "source/frame.jpg"

    /// The capture date a staged scene's project gets: one fixed hour per
    /// set, then a minute per sequence index — deterministic, so a re-stage
    /// is the same project date for date, and ordered as the sequence is, so
    /// the builder's Capture order (oldest first) IS the approach order. The
    /// hour is drawn from 16 bits of the set's name's digest (65 536 hours
    /// from 2018, so two sets staged into one library keep apart in the
    /// lists instead of interleaving minute by minute; one byte modulo 200
    /// days put an 18th set on a used day about half the time).
    public static func captureDate(set: String, index: Int) -> Date {
        let epoch = Date(timeIntervalSince1970: 1_514_764_800)  // 2018-01-01T00:00:00Z
        let digest = Array(Insecure.SHA1.hash(data: Data(set.utf8)))
        let hour = Int(digest[0]) << 8 | Int(digest[1])
        return epoch.addingTimeInterval(Double(hour) * 3_600 + Double(index) * 60)
    }

    /// The name the project carries as its imported photo's: file-shaped,
    /// as the app's own import writes `url.lastPathComponent`, because the
    /// app titles an imported photo by `originalName` less its path
    /// extension — a bare `city.clear.approach.07` would lose its `.07`
    /// there and every project of the set would read the same. The
    /// `<set>/<scene-id>` label stays the plan's and the score's.
    public static func originalName(for manifest: SceneManifest) -> String {
        "\(manifest.id).jpg"
    }

    /// Stages the scene whose manifest is `manifestURL` (its `frame.jpg`
    /// beside it) as `<projectsRoot>/<set>/<scene-id>/`. `link` hard-links
    /// the frame instead of copying it. With `project`, `project.json` and
    /// `assets.ndjson` are written too: a Photo project of one source — kind
    /// `photos`, the imported-photo mode, the manifest's oriented size, a
    /// fresh id that is also the origin. The folder keeps the
    /// `<set>/<scene-id>` layout the plan and score label by; to be adopted
    /// at launch it is copied to `Projects/<id>/`, and `pack` names its
    /// archive `<id>.lapse` for the import door.
    ///
    /// The manifest file is copied byte for byte, never re-encoded: what
    /// Python wrote that this Kit does not decode yet (the kit's face
    /// polygon, the composition's numbers) travels with the project all the
    /// same.
    public static func stage(manifestURL: URL, into projectsRoot: URL,
                             link: Bool = false, project: Bool = false, now: Date = Date()) throws -> Staged {
        let fm = FileManager.default
        let manifest = try SceneManifest.load(from: manifestURL)
        let frameURL = manifestURL.deletingLastPathComponent().appendingPathComponent("frame.jpg")
        let folder = projectsRoot.appendingPathComponent(manifest.set, isDirectory: true).appendingPathComponent(manifest.id, isDirectory: true)
        let source = folder.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)

        // The picture: a copy, or a hard link when the corpus is large and
        // the staging area sits on the same volume.
        let frame = folder.appendingPathComponent(frameRelativePath)
        if fm.fileExists(atPath: frame.path) { try fm.removeItem(at: frame) }
        if link { try fm.linkItem(at: frameURL, to: frame) } else { try fm.copyItem(at: frameURL, to: frame) }

        // The register: what the pipeline is given is the perturbed outline,
        // through the Kit's own factories — the one code path.
        let shape = try SceneManifest.makeShape(manifest.perturbed, frame: manifest.frameSize)
        var register = ShapeRegister.manual(representative: ShapeRegister.Representative(
            relativePath: frameRelativePath, source: .sourceFrame, width: manifest.frame.width, height: manifest.frame.height))
        register.shapes = [shape]
        try register.save(inProjectFolder: folder)

        // The truth travels with the project.
        let copied = SceneManifest.url(inProjectFolder: folder)
        if fm.fileExists(atPath: copied.path) { try fm.removeItem(at: copied) }
        try fm.copyItem(at: manifestURL, to: copied)

        // The register loads back through the app's own door with one shape
        // of the kind `makeShape` just set; the family is the caller's check.
        guard let back = ShapeRegister.load(inProjectFolder: folder) else { throw Failure.registerDidNotLoadBack(folder) }
        guard back.shapes.count == 1, back.shapes[0].kind.rawValue == manifest.perturbed.kind.rawValue else {
            throw Failure.registerLoadedBackWrong(folder, count: back.shapes.count, kind: back.shapes.first?.kind.rawValue,
                                                  wanted: manifest.perturbed.kind.rawValue)
        }

        var projectID: UUID?
        if project {
            let id = UUID()
            let capture = StandaloneProject.Capture(
                id: id, kind: "photos", mode: ProjectModes.importedPhoto,
                originalName: originalName(for: manifest),
                createdAt: captureDate(set: manifest.set, index: manifest.sequence.index), addedAt: now,
                sourceFileNames: [frameRelativePath],
                sourceWidth: manifest.frame.width, sourceHeight: manifest.frame.height)
            try StandaloneProject.writeDocument(for: capture, inProjectFolder: folder)
            let records = AssetRecords.url(inProjectFolder: folder)
            if fm.fileExists(atPath: records.path) { try fm.removeItem(at: records) }
            try StandaloneProject.recordAsset(name: frameRelativePath, file: frame, now: now, inProjectFolder: folder)
            projectID = id
        }
        return Staged(folder: folder, family: back.shapes[0].family, projectID: projectID)
    }
}
