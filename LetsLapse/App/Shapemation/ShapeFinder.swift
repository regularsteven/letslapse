import Foundation
import CoreGraphics
import CoreImage
import AVFoundation
import ImageIO
import LetsLapseKit

// "Find shapes": one representative picture per project — a rendered blend
// image, else the mid frame of a rendered blend clip, else the middle source
// frame — through `ShapeDetector`, written to the project's `shapes.json`.
// Only projects with no register yet are analysed; a project whose picture
// cannot be read gets a register with a `failure` so it is not retried on
// every run. Video-mode shoots are left out, as scans are.

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
    struct Candidate: Sendable, Identifiable {
        var id: UUID
        var title: String
        var folder: URL
        var representative: ShapeRepresentative
    }

    struct Progress: Equatable {
        var done: Int
        var total: Int
        var current: String
    }

    struct Summary: Equatable {
        var analysed: Int
        var withShapes: Int
        var families: [DetectedShape.Family: Int]
        var unreadable: Int
        var alreadyDone: Int
        var skippedVideo: Int
    }

    @Published private(set) var progress: Progress?
    @Published private(set) var summary: Summary?
    @Published private(set) var isRunning = false
    private var task: Task<Void, Never>?

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// The projects "Find shapes" would analyse now, and how many it leaves
    /// out. A register from an older detector is to do again: its kept shapes
    /// and viewfinder trail survive the run (see `run`), its detections are
    /// replaced. `outdated` says how many of `todo` are those.
    static func candidates(in model: AppModel) -> (todo: [Candidate], alreadyDone: Int, skippedVideo: Int, outdated: Int) {
        var todo: [Candidate] = []
        var done = 0, video = 0, outdated = 0
        for capture in model.captures where !capture.isScannerCapture {
            guard capture.kind == .photos else { video += 1; continue }
            let folder = model.projectFolderURL(for: capture)
            if let existing = ShapeRegister.load(inProjectFolder: folder), existing.isAnalysed {
                if existing.isCurrent { done += 1; continue }
                outdated += 1
            }
            guard let rep = representative(for: capture, in: model) else { continue }
            todo.append(Candidate(id: capture.id, title: capture.displayTitle, folder: folder, representative: rep))
        }
        return (todo, done, video, outdated)
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

    func run(model: AppModel) {
        guard !isRunning else { return }
        let (todo, alreadyDone, skippedVideo, _) = Self.candidates(in: model)
        isRunning = true
        summary = nil
        progress = Progress(done: 0, total: todo.count, current: todo.first?.title ?? "")
        task = Task.detached(priority: .userInitiated) { [weak self] in
            // The file profile with the dials at their defaults — the same
            // pass a capture's register gets, floor included.
            let detector = ShapeDetector(settings: ShapeSearch().fileSettings())
            var analysed = 0, withShapes = 0, unreadable = 0
            var families: [DetectedShape.Family: Int] = [:]
            for (i, candidate) in todo.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run { self?.progress = Progress(done: i, total: todo.count, current: candidate.title) }
                let rep = candidate.representative
                // Shapes drawn by hand or confirmed on the viewfinder before
                // this run stay; the detector's join them — minus any that
                // are the same thing as a kept one, which is already listed.
                let existing = ShapeRegister.load(inProjectFolder: candidate.folder)
                let drawn = existing?.keptShapes ?? []
                var register: ShapeRegister
                if let size = RepresentativeLoader.orientedPixelSize(rep),
                   let image = RepresentativeLoader.image(rep, maxPixelSize: detector.settings.decodeLongEdge) {
                    let started = Date()
                    var found = (try? detector.detect(in: image, nativeSize: size)) ?? []
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
                    // The lens: what the register already knew (a capture-time
                    // register keeps its shutter reading), else the file's EXIF.
                    let fov = existing?.representative.horizontalFieldOfView
                        ?? RepresentativeLoader.horizontalFieldOfView(rep)
                    register = ShapeRegister(representative: .init(relativePath: rep.relativePath, source: rep.source, frameFraction: rep.frameFraction,
                                                                   width: Int(size.width), height: Int(size.height), horizontalFieldOfView: fov),
                                             shapes: kept + shapes).rectifyingQuads()
                    analysed += 1
                    if !shapes.isEmpty { withShapes += 1 }
                    for s in shapes { families[s.family, default: 0] += 1 }
                    LLog(String(format: "shapes: %@ — %d shape(s) in %.0f ms", candidate.title, shapes.count, Date().timeIntervalSince(started) * 1000))
                } else {
                    register = ShapeRegister(representative: .init(relativePath: rep.relativePath, source: rep.source, frameFraction: rep.frameFraction, width: 0, height: 0),
                                             shapes: drawn, failure: "picture could not be read")
                    unreadable += 1
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
                                 alreadyDone: alreadyDone, skippedVideo: skippedVideo)
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
