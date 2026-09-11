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

    /// The projects "Find shapes" would analyse now, and how many it leaves out.
    static func candidates(in model: AppModel) -> (todo: [Candidate], alreadyDone: Int, skippedVideo: Int) {
        var todo: [Candidate] = []
        var done = 0, video = 0
        for capture in model.captures where !capture.isScannerCapture {
            guard capture.kind == .photos else { video += 1; continue }
            let folder = model.projectFolderURL(for: capture)
            if let existing = ShapeRegister.load(inProjectFolder: folder), existing.isAnalysed { done += 1; continue }
            guard let rep = representative(for: capture, in: model) else { continue }
            todo.append(Candidate(id: capture.id, title: capture.displayTitle, folder: folder, representative: rep))
        }
        return (todo, done, video)
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
        let (todo, alreadyDone, skippedVideo) = Self.candidates(in: model)
        isRunning = true
        summary = nil
        progress = Progress(done: 0, total: todo.count, current: todo.first?.title ?? "")
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let detector = ShapeDetector()
            var analysed = 0, withShapes = 0, unreadable = 0
            var families: [DetectedShape.Family: Int] = [:]
            for (i, candidate) in todo.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run { self?.progress = Progress(done: i, total: todo.count, current: candidate.title) }
                let rep = candidate.representative
                // Shapes drawn by hand before this run stay; the detector's join them.
                let drawn = ShapeRegister.load(inProjectFolder: candidate.folder)?.manualShapes ?? []
                var register: ShapeRegister
                if let size = RepresentativeLoader.orientedPixelSize(rep),
                   let image = RepresentativeLoader.image(rep, maxPixelSize: detector.settings.detectionLongEdge) {
                    let shapes = (try? detector.detect(in: image, nativeSize: size)) ?? []
                    register = ShapeRegister(representative: .init(relativePath: rep.relativePath, source: rep.source, frameFraction: rep.frameFraction,
                                                                   width: Int(size.width), height: Int(size.height)), shapes: drawn + shapes)
                    analysed += 1
                    if !shapes.isEmpty { withShapes += 1 }
                    for s in shapes { families[s.family, default: 0] += 1 }
                } else {
                    register = ShapeRegister(representative: .init(relativePath: rep.relativePath, source: rep.source, frameFraction: rep.frameFraction, width: 0, height: 0),
                                             shapes: drawn, failure: "picture could not be read")
                    unreadable += 1
                    LLog("shapes: could not read \(rep.url.lastPathComponent) for \(candidate.title)")
                }
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
