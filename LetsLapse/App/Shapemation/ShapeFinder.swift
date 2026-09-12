import Foundation
import CoreGraphics
import CoreImage
import AVFoundation
import ImageIO
import LetsLapseKit

// "Find shapes": one representative picture per project — a rendered blend
// image, else the mid frame of a rendered blend clip, else the middle source
// frame — through a `ShapeDetectionMode` (the Kit's still-photo pass in one
// of its configurations, or on a Mac one of the benchmark rig's Python
// detectors), written to the project's `shapes.json`. Which projects a run
// visits is the sheet's scope (2026-09-12): those needing analysis, all of
// them, the ones nothing was found in, or a ticked few. A project whose
// picture cannot be read gets a register with a `failure` so it is not
// retried on every run. Video-mode shoots are left out, as scans are.

/// The picture a project's shapes are measured on, and how to load it again.
struct ShapeRepresentative: Sendable, Equatable {
    var url: URL
    var relativePath: String
    var source: ShapeRegister.Representative.Source
    var frameFraction: Double?
}

enum RepresentativeLoader {
    /// Oriented, bounded decode of a representative — RAW-aware through the
    /// app's own decoder, a clip through `AVAssetImageGenerator`.
    static func image(_ rep: ShapeRepresentative, maxPixelSize: Int) -> CGImage? {
        switch rep.source {
        case .blendImage, .sourceFrame:
            return ProjectThumbnailGenerator.imageThumbnail(for: rep.url, maxPixelSize: maxPixelSize)
        case .blendVideo:
            let asset = AVURLAsset(url: rep.url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let duration = asset.duration
            let t = CMTimeMultiplyByFloat64(duration, multiplier: rep.frameFraction ?? 0.5)
            return try? generator.copyCGImage(at: t, actualTime: nil)
        }
    }

    /// The lens's horizontal field of view for a picture that carries EXIF —
    /// an import, or a DNG — from its 35 mm-equivalent focal length, read on
    /// the diagonal the way that number is defined (a 4:3 frame with the
    /// 43.3 mm diagonal is 34.6 mm wide, so an iPhone's "24 mm" is a 71.6°
    /// horizontal field, not 73.7°). nil when the file does not say — the
    /// app's own JPEG stills carry almost no EXIF, which is why the capture
    /// path records the lens on the register itself.
    static func horizontalFieldOfView(_ rep: ShapeRepresentative) -> Double? {
        guard rep.source != .blendVideo,
              let source = CGImageSourceCreateWithURL(rep.url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let f35 = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue, f35 > 0,
              let size = orientedPixelSize(rep), size.width > 0, size.height > 0 else { return nil }
        let diagonal35 = 43.27
        let halfWidth = diagonal35 / 2 * Double(size.width) / Double(hypot(size.width, size.height))
        return 2 * atan(halfWidth / f35) * 180 / .pi
    }

    /// The representative's oriented pixel size without a full decode.
    static func orientedPixelSize(_ rep: ShapeRepresentative) -> CGSize? {
        switch rep.source {
        case .blendVideo:
            let asset = AVURLAsset(url: rep.url)
            guard let track = asset.tracks(withMediaType: .video).first else { return nil }
            let r = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
            return CGSize(width: abs(r.width).rounded(), height: abs(r.height).rounded())
        case .blendImage, .sourceFrame:
            if ProjectThumbnailGenerator.isRAW(rep.url) {
                guard let raw = LossyLinearDNG.rawFilter(for: rep.url), let out = raw.outputImage else { return nil }
                return CGSize(width: out.extent.width.rounded(), height: out.extent.height.rounded())
            }
            guard let source = CGImageSourceCreateWithURL(rep.url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
            let o = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
            return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        }
    }
}

@MainActor
final class ShapeFinder: ObservableObject {
    struct Candidate: Sendable, Identifiable, Equatable {
        var id: UUID
        var title: String
        var folder: URL
        var representative: ShapeRepresentative
        /// The register as it stands.
        var isAnalysed: Bool
        var isCurrent: Bool
        var shapeCount: Int
        var detectedCount: Int
    }

    /// Which projects a run visits — the sheet's scope picker.
    enum Scope: String, CaseIterable, Identifiable, Sendable {
        case pending, all, empty, chosen
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pending: return "Needing analysis"
            case .all: return "All photo projects"
            case .empty: return "No shapes yet"
            case .chosen: return "Chosen projects"
            }
        }
        var detail: String {
            switch self {
            case .pending: return "Projects never analysed, or analysed by an older detector."
            case .all: return "Every photo project. Found shapes are replaced; shapes you drew or kept on the viewfinder stay."
            case .empty: return "Projects the detector has looked at and found nothing in."
            case .chosen: return "Only the projects ticked below."
            }
        }
    }

    struct Progress: Equatable {
        var done: Int
        var total: Int
        var current: String
        var startedAt: Date
    }

    /// One project's outcome, for the sheet's results list.
    struct ProjectResult: Identifiable, Equatable, Sendable {
        var id: UUID
        var title: String
        var families: [DetectedShape.Family: Int]
        var shapes: Int
        var milliseconds: Int
        /// The pass's own account of the picture, or why it could not be read.
        var note: String?
        var failed: Bool
    }

    struct Summary: Equatable {
        var analysed: Int
        var withShapes: Int
        var families: [DetectedShape.Family: Int]
        var unreadable: Int
        var alreadyDone: Int
        var skippedVideo: Int
        var results: [ProjectResult]
        var totalMs: Int
        var mode: ShapeDetectionMode
        var cancelled: Bool
    }

    /// One engine's turn on one picture.
    struct EngineRun: Sendable, Equatable {
        var engine: ShapeDetectionMode.Engine
        var shapes: Int
        var milliseconds: Int
        var note: String?
        var failed: Bool
    }

    /// One candidate shape and who found it. Under Use All the same object
    /// found by several engines is one `Found` with several proposers; the
    /// geometry kept is the most confident engine's.
    struct Found: Identifiable, Sendable, Equatable {
        var shape: DetectedShape
        var foundBy: [ShapeDetectionMode.Engine]
        var confidences: [ShapeDetectionMode.Engine: Float]
        var id: UUID { shape.id }
    }

    /// One representative through one mode: what was found, each engine's
    /// own account, and the time it all took.
    struct Pass: Sendable, Equatable {
        var runID: UUID
        var mode: ShapeDetectionMode
        var found: [Found]
        var engines: [EngineRun]
        var milliseconds: Int
        var note: String?
        var failed: Bool
        var shapes: [DetectedShape] { found.map(\.shape) }
    }

    /// What can be done with a find's candidates. The rail's list and the
    /// picture's tick / cross pill call the same three, which the viewer
    /// owns because they edit the register and score the sheet.
    struct FoundActions {
        var add: (Found) -> Void
        var reject: (Found) -> Void
        /// An added or rejected candidate back to pending.
        var undo: (Found) -> Void
        /// Pending candidates are passed over (Clear, a new find, leaving).
        var settle: () -> Void
        var clear: () -> Void
    }

    /// Two engines' shapes are the same object at this bounds-IoU: looser
    /// than the Kit's own near-identical bar (0.9) because a Vision quad and
    /// an edge-chain fit of one plate differ by a few percent, and tighter
    /// than the consensus rule (0.7) so a nest's members stay apart.
    static let mergeIoU = 0.8

    /// What a Use All run visits here.
    nonisolated static func roster() -> [ShapeDetectionMode.Engine] {
        #if os(macOS)
        return ShapeDetectionMode.Engine.roster(externalAvailable: ExternalShapeDetector.isAvailable)
        #else
        return ShapeDetectionMode.Engine.roster(externalAvailable: false)
        #endif
    }

    @Published private(set) var progress: Progress?
    @Published private(set) var summary: Summary?
    @Published private(set) var isRunning = false
    private var task: Task<Void, Never>?

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Every photo project with a picture to measure, and what its register
    /// holds; the scope picks from this.
    static func inventory(in model: AppModel) -> (projects: [Candidate], skippedVideo: Int) {
        var out: [Candidate] = []
        var video = 0
        for capture in model.captures where !capture.isScannerCapture {
            guard capture.kind == .photos else { video += 1; continue }
            let folder = model.projectFolderURL(for: capture)
            guard let rep = representative(for: capture, in: model) else { continue }
            let existing = ShapeRegister.load(inProjectFolder: folder)
            out.append(Candidate(id: capture.id, title: capture.displayTitle, folder: folder, representative: rep,
                                 isAnalysed: existing?.isAnalysed ?? false, isCurrent: existing?.isCurrent ?? false,
                                 shapeCount: existing?.shapes.count ?? 0,
                                 detectedCount: existing?.shapes.filter { $0.source == .detected }.count ?? 0))
        }
        return (out, video)
    }

    static func select(_ projects: [Candidate], scope: Scope, chosen: Set<UUID>) -> [Candidate] {
        switch scope {
        case .pending: return projects.filter { !$0.isCurrent }
        case .all: return projects
        case .empty: return projects.filter { $0.isAnalysed && $0.shapeCount == 0 }
        case .chosen: return projects.filter { chosen.contains($0.id) }
        }
    }

    /// The projects "Find shapes" visits by default (the pending scope), and
    /// how many it leaves out. A register from an older detector is to do
    /// again: its kept shapes and viewfinder trail survive the run (see
    /// `run`), its detections are replaced. `outdated` says how many of
    /// `todo` are those.
    static func candidates(in model: AppModel) -> (todo: [Candidate], alreadyDone: Int, skippedVideo: Int, outdated: Int) {
        let inventory = inventory(in: model)
        let todo = select(inventory.projects, scope: .pending, chosen: [])
        return (todo, inventory.projects.filter(\.isCurrent).count, inventory.skippedVideo, todo.filter(\.isAnalysed).count)
    }

    /// Representative order: blend image → blend clip (mid frame) → middle source frame.
    static func representative(for capture: AppModel.CaptureProject, in model: AppModel) -> ShapeRepresentative? {
        let folder = model.projectFolderURL(for: capture)
        let fm = FileManager.default
        let blends = model.blends(for: capture).sorted { $0.createdAt > $1.createdAt }
        for blend in blends {
            let url = model.mediaURL(for: blend)
            guard fm.fileExists(atPath: url.path) else { continue }
            if imageExtensions.contains(url.pathExtension.lowercased()) {
                return ShapeRepresentative(url: url, relativePath: blend.outputFileName, source: .blendImage, frameFraction: nil)
            }
        }
        for blend in blends {
            let url = model.mediaURL(for: blend)
            guard fm.fileExists(atPath: url.path) else { continue }
            if videoExtensions.contains(url.pathExtension.lowercased()) {
                return ShapeRepresentative(url: url, relativePath: blend.outputFileName, source: .blendVideo, frameFraction: 0.5)
            }
        }
        let frames = model.sourceFrameURLs(for: capture).filter {
            let ext = $0.pathExtension.lowercased()
            return imageExtensions.contains(ext) || ImportedStills.isRaw($0)
        }
        guard !frames.isEmpty else { return nil }
        let middle = frames[frames.count / 2]
        guard fm.fileExists(atPath: middle.path) else { return nil }
        let relative = middle.path.hasPrefix(folder.path) ? String(middle.path.dropFirst(folder.path.count + 1)) : middle.lastPathComponent
        return ShapeRepresentative(url: middle, relativePath: relative, source: .sourceFrame, frameFraction: nil)
    }

    /// Drops every found shape from every photo register — shapes drawn by
    /// hand or kept on the viewfinder stay — and marks those registers as
    /// never analysed, so the pending scope visits them again. Returns how
    /// many registers changed.
    static func removeFoundShapes(in model: AppModel) -> Int {
        var changed = 0
        for capture in model.captures where !capture.isScannerCapture && capture.kind == .photos {
            let folder = model.projectFolderURL(for: capture)
            guard var register = ShapeRegister.load(inProjectFolder: folder),
                  register.isAnalysed || register.shapes.contains(where: { $0.source == .detected }) else { continue }
            register.shapes.removeAll { $0.source == .detected }
            register.analysedAt = nil
            register.viewfinder?.file = nil
            do {
                try register.save(inProjectFolder: folder)
                changed += 1
                model.shapeRegisterDidChange(for: capture)
            } catch {
                LLog("shapes: could not clear the found shapes of \(capture.displayTitle): \(error)")
            }
        }
        return changed
    }

    /// One representative through one mode. Nil when the picture cannot be
    /// read; a `failed` pass when the detector itself did not run. Use All
    /// runs every engine of the roster in turn and merges what they found.
    nonisolated static func pass(_ rep: ShapeRepresentative, size: CGSize, mode: ShapeDetectionMode) -> Pass? {
        if mode.engine == .all {
            var engines: [EngineRun] = []
            var found: [Found] = []
            for engine in roster() {
                guard let turn = engineRun(rep, size: size, engine: engine, search: mode.search) else { return nil }
                engines.append(turn.run)
                for shape in turn.shapes { merge(shape, from: engine, into: &found) }
            }
            found.sort { a, b in
                a.foundBy.count != b.foundBy.count ? a.foundBy.count > b.foundBy.count : a.shape.confidence > b.shape.confidence
            }
            let note = engines.map { "\($0.engine.shortTitle) \($0.failed ? "failed" : "\($0.shapes)") in \($0.milliseconds) ms" }.joined(separator: " · ")
            return Pass(runID: UUID(), mode: mode, found: found, engines: engines,
                        milliseconds: engines.map(\.milliseconds).reduce(0, +), note: note, failed: engines.allSatisfy(\.failed))
        }
        guard let turn = engineRun(rep, size: size, engine: mode.engine, search: mode.search) else { return nil }
        let found = turn.shapes.map { Found(shape: $0, foundBy: [mode.engine], confidences: [mode.engine: $0.confidence]) }
        return Pass(runID: UUID(), mode: mode, found: found, engines: [turn.run],
                    milliseconds: turn.run.milliseconds, note: turn.run.note, failed: turn.run.failed)
    }

    /// One engine's turn. Nil when the picture cannot be read.
    nonisolated static func engineRun(_ rep: ShapeRepresentative, size: CGSize, engine: ShapeDetectionMode.Engine,
                                      search: ShapeSearch) -> (shapes: [DetectedShape], run: EngineRun)? {
        let started = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        #if os(macOS)
        if let detectorID = engine.externalDetectorID {
            guard let still = ExternalShapeDetector.stillURL(for: rep) else { return nil }
            defer { if still.temporary { try? FileManager.default.removeItem(at: still.url) } }
            do {
                let result = try ExternalShapeDetector.run(detectorID: detectorID, imageURL: still.url)
                var note = "\(result.detector): \(result.shapes.count) shape\(result.shapes.count == 1 ? "" : "s")"
                if let candidates = result.candidates { note += " of \(candidates) candidates" }
                if let ms = result.detectorMs { note += " · detector \(ms) ms" }
                return (result.shapes, EngineRun(engine: engine, shapes: result.shapes.count, milliseconds: elapsed(), note: note, failed: false))
            } catch {
                return ([], EngineRun(engine: engine, shapes: 0, milliseconds: elapsed(), note: error.localizedDescription, failed: true))
            }
        }
        #else
        if engine.isExternal {
            return ([], EngineRun(engine: engine, shapes: 0, milliseconds: 0, note: "The Python detectors run on a Mac only.", failed: true))
        }
        #endif
        let detector = ShapeDetector(settings: ShapeDetectionMode(engine: engine, search: search).settings())
        guard let image = RepresentativeLoader.image(rep, maxPixelSize: detector.settings.decodeLongEdge) else { return nil }
        do {
            let result = try detector.detectWithDiagnostics(in: image, nativeSize: size)
            return (result.shapes, EngineRun(engine: engine, shapes: result.shapes.count, milliseconds: elapsed(),
                                             note: result.diagnostics.summary, failed: false))
        } catch {
            return ([], EngineRun(engine: engine, shapes: 0, milliseconds: elapsed(), note: error.localizedDescription, failed: true))
        }
    }

    /// Fold one engine's shape into the found list: the same object (same
    /// kind, bounds-IoU ≥ `mergeIoU`) gains a proposer and keeps the more
    /// confident geometry under its first id; anything else is new.
    nonisolated static func merge(_ shape: DetectedShape, from engine: ShapeDetectionMode.Engine, into found: inout [Found]) {
        if let i = found.firstIndex(where: { $0.shape.kind == shape.kind && ShapeDetector.overlap($0.shape, shape) >= mergeIoU }) {
            if !found[i].foundBy.contains(engine) { found[i].foundBy.append(engine) }
            found[i].confidences[engine] = shape.confidence
            if shape.confidence > found[i].shape.confidence {
                var better = shape
                better.id = found[i].shape.id
                found[i].shape = better
            }
        } else {
            found.append(Found(shape: shape, foundBy: [engine], confidences: [engine: shape.confidence]))
        }
    }

    func run(mode: ShapeDetectionMode, candidates todo: [Candidate], alreadyDone: Int, skippedVideo: Int) {
        guard !isRunning else { return }
        isRunning = true
        summary = nil
        let runStarted = Date()
        progress = Progress(done: 0, total: todo.count, current: todo.first?.title ?? "", startedAt: runStarted)
        mode.save()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var analysed = 0, withShapes = 0, unreadable = 0
            var families: [DetectedShape.Family: Int] = [:]
            var results: [ProjectResult] = []
            var cancelled = false
            for (i, candidate) in todo.enumerated() {
                if Task.isCancelled { cancelled = true; break }
                await MainActor.run { self?.progress = Progress(done: i, total: todo.count, current: candidate.title, startedAt: runStarted) }
                let rep = candidate.representative
                // Shapes drawn by hand or confirmed on the viewfinder before
                // this run stay; the detector's join them — minus any that
                // are the same thing as a kept one, which is already listed.
                let existing = ShapeRegister.load(inProjectFolder: candidate.folder)
                let drawn = existing?.keptShapes ?? []
                var register: ShapeRegister
                if let size = RepresentativeLoader.orientedPixelSize(rep), let pass = Self.pass(rep, size: size, mode: mode) {
                    var found = pass.shapes
                    // A shape confirmed on the viewfinder keeps its identity
                    // and takes the file pass's geometry where the file pass
                    // saw the same shape — the live pass drew it at 384 px.
                    // A hand-drawn shape is the person's own geometry and
                    // stands; the detection of the same shape is dropped.
                    var kept = drawn
                    for i in kept.indices {
                        guard let j = ShapeReconciler.bestMatch(for: kept[i], in: found, threshold: ShapeReconciler.stillMatchThreshold) else { continue }
                        let detection = found.remove(at: j)
                        if kept[i].source == .captured {
                            var snapped = detection
                            snapped.id = kept[i].id
                            snapped.source = .captured
                            snapped.name = kept[i].name
                            kept[i] = snapped
                        }
                    }
                    let shapes = found
                    let snapped = pass.shapes.count - found.count
                    // The score sheet: every engine ran, every candidate was
                    // proposed; a candidate that snapped onto a shape the
                    // person kept on the viewfinder is a hit for its proposers.
                    let captured = kept.filter { $0.source == .captured }
                    ShapeDetectorFeedback.shared.recordPass(pass, project: candidate.id) { shape in
                        captured.contains { $0.kind == shape.kind && ShapeDetector.overlap($0, shape) >= ShapeReconciler.stillMatchThreshold }
                    }
                    // The lens: what the register already knew (a capture-time
                    // register keeps its shutter reading), else the file's EXIF.
                    let fov = existing?.representative.horizontalFieldOfView
                        ?? RepresentativeLoader.horizontalFieldOfView(rep)
                    register = ShapeRegister(representative: .init(relativePath: rep.relativePath, source: rep.source, frameFraction: rep.frameFraction,
                                                                   width: Int(size.width), height: Int(size.height), horizontalFieldOfView: fov),
                                             shapes: kept + shapes).rectifyingQuads()
                    analysed += 1
                    if !shapes.isEmpty { withShapes += 1 }
                    var own: [DetectedShape.Family: Int] = [:]
                    for s in shapes { own[s.family, default: 0] += 1; families[s.family, default: 0] += 1 }
                    // A detection that snapped onto a shape the person kept or drew
                    // is not lost, but it is not a new row either — say so.
                    var note = pass.note ?? ""
                    if snapped > 0 { note += (note.isEmpty ? "" : " · ") + "\(snapped) matched a kept shape" }
                    results.append(ProjectResult(id: candidate.id, title: candidate.title, families: own, shapes: shapes.count,
                                                 milliseconds: pass.milliseconds, note: note.isEmpty ? nil : note, failed: pass.failed))
                    LLog(String(format: "shapes: %@ — %d shape(s) in %d ms (%@)", candidate.title, shapes.count, pass.milliseconds, mode.token))
                } else {
                    register = ShapeRegister(representative: .init(relativePath: rep.relativePath, source: rep.source, frameFraction: rep.frameFraction, width: 0, height: 0),
                                             shapes: drawn, failure: "picture could not be read")
                    unreadable += 1
                    results.append(ProjectResult(id: candidate.id, title: candidate.title, families: [:], shapes: 0,
                                                 milliseconds: 0, note: "picture could not be read", failed: true))
                    LLog("shapes: could not read \(rep.url.lastPathComponent) for \(candidate.title)")
                }
                // The viewfinder's account of the capture belongs to the
                // capture, not to the detector run that is being redone.
                register.viewfinder = existing?.viewfinder
                do { try register.save(inProjectFolder: candidate.folder) } catch {
                    LLog("shapes: could not write shapes.json for \(candidate.title): \(error)")
                }
            }
            let result = Summary(analysed: analysed, withShapes: withShapes, families: families, unreadable: unreadable,
                                 alreadyDone: alreadyDone, skippedVideo: skippedVideo, results: results,
                                 totalMs: Int(Date().timeIntervalSince(runStarted) * 1000), mode: mode, cancelled: cancelled)
            await MainActor.run {
                self?.progress = nil
                self?.summary = result
                self?.isRunning = false
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

// MARK: - Auto shape mode's register

extension AppModel {
    /// The register for a photo that has just landed with the viewfinder's
    /// shapes attached. Written twice. First the viewfinder's own kept shapes,
    /// at once and provisional (`analysedAt` nil, so a Find shapes run would
    /// still visit the project if the second write never came). Then, once
    /// the file has been through the full detector in the background, the
    /// reconciled list: kept shapes snapped to their full-resolution fits,
    /// file detections over dismissed shapes dropped, the rest recorded as
    /// plain detections (see `ShapeReconciler`). The Gallery's SHAPES rows
    /// hear about both.
    func recordViewfinderShapes(_ viewfinder: ViewfinderShapes, for capture: CaptureProject) {
        let folder = projectFolderURL(for: capture)
        guard let rep = ShapeFinder.representative(for: capture, in: self) else {
            LLog("shapes: no picture to record the viewfinder's shapes on for \(capture.displayTitle)")
            return
        }
        let title = capture.displayTitle
        Task.detached(priority: .userInitiated) { [weak self] in
            let size = RepresentativeLoader.orientedPixelSize(rep) ?? viewfinder.frameSize
            let representative = ShapeRegister.Representative(
                relativePath: rep.relativePath, source: rep.source, frameFraction: rep.frameFraction,
                width: Int(size.width), height: Int(size.height),
                horizontalFieldOfView: viewfinder.horizontalFieldOfView ?? RepresentativeLoader.horizontalFieldOfView(rep))
            var register = ShapeRegister(analysedAt: nil, representative: representative,
                                         shapes: ShapeReconciler.provisional(viewfinder, photoSize: size)).rectifyingQuads()
            register.viewfinder = ViewfinderTrail(viewfinder)
            do { try register.save(inProjectFolder: folder) } catch {
                LLog("shapes: could not write the provisional register for \(title): \(error)")
                return
            }
            await MainActor.run { self?.shapeRegisterDidChange(for: capture) }

            // The same things the viewfinder was looking for, at the file
            // pass's own resolution and gates (see `ShapeSearch.fileSettings`).
            let detector = ShapeDetector(settings: viewfinder.search.fileSettings())
            guard let image = RepresentativeLoader.image(rep, maxPixelSize: detector.settings.decodeLongEdge) else {
                LLog("shapes: could not read \(rep.url.lastPathComponent) to refine the viewfinder's shapes; provisional register stands")
                return
            }
            let started = Date()
            let pass = try? detector.detectWithDiagnostics(in: image, nativeSize: size)
            let found = pass?.shapes ?? []
            register.shapes = ShapeReconciler.reconcile(viewfinder, photoDetections: found, photoSize: size)
            register = register.rectifyingQuads()
            register.viewfinder?.file = pass?.diagnostics
            register.analysedAt = Date()
            do { try register.save(inProjectFolder: folder) } catch {
                LLog("shapes: could not write the refined register for \(title): \(error)")
                return
            }
            let captured = register.shapes.filter { $0.source == .captured }.count
            let extras = register.shapes.count - captured
            LLog(String(format: "shapes: %@ — %d kept on the viewfinder, %d found in the file (%@), register %d captured + %d detected (%.1f s)",
                        title, viewfinder.kept.count, found.count, viewfinder.search.token, captured, extras, Date().timeIntervalSince(started)))
            if found.isEmpty, let d = pass?.diagnostics {
                LLog("shapes: the file pass refused — \(d.summary)" + (d.refusals.isEmpty ? "" : "; " + d.refusals.prefix(6).map { "\($0.kind) \(Int($0.size * 100))% \($0.reason)" }.joined(separator: "; ")))
            }
            await MainActor.run { self?.shapeRegisterDidChange(for: capture) }
        }
    }
}
