import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import LetsLapseKit

/// `Projects/<id>/poster.jpg` — the project's graded poster frame, rendered
/// by the device that pushes it (v2 plan §3.5): ~1280 px on the long edge,
/// JPEG at 0.7, through the same render every tile and hero use, so what
/// the second device sees is what this one shows. Re-rendered when the
/// grade token moves; the token is kept on the sync record.
enum PicPlacePoster {

    static let maxDimension: CGFloat = 1280
    static let quality = 0.7

    /// The poster's URL after making sure it is current for `token`. nil when
    /// the project has no frame to render (a video whose file is gone).
    /// `finished` (2026-10-04): a photo's poster is the finished picture —
    /// the grade, the masked grades, the text and shapes, the level and the
    /// crop (`FinishedPicture`) — when the caller gathered its inputs; a
    /// video's, and a photo's without them, the graded frame as before.
    static func ensure(sourceURL: URL, kind: AppModel.MediaKind, grade: PhotoGrade, token: String,
                       lastToken: String?, in folder: URL, finished: FinishedPicture.Inputs? = nil) async -> URL? {
        let url = folder.appendingPathComponent(ProjectFileRegistry.posterName)
        if lastToken == token, FileManager.default.fileExists(atPath: url.path) { return url }
        let image: CGImage?
        if kind == .video {
            image = await MediaWorkQueue.shared.run { VideoGrader.gradedFrame(at: sourceURL, grade: grade, maxDimension: maxDimension) } ?? nil
        } else if let finished {
            image = await FinishedPicture.render(finished, maxDimension: maxDimension)
        } else {
            image = await MediaWorkQueue.shared.run {
                PhotoGrader.render(url: sourceURL, preset: grade.preset, adjustments: grade.adjustments,
                                   rotationDegrees: grade.rotationDegrees, whiteBalance: grade.whiteBalance,
                                   maxDimension: maxDimension)
            } ?? nil
        }
        let rendered: Data? = image.flatMap { image in
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }
        guard let data = rendered else {
            LLog("picplace: no poster for \(folder.lastPathComponent) — \(sourceURL.lastPathComponent) did not render")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        do {
            try data.write(to: url, options: .atomic)
            LLog("picplace: poster for \(folder.lastPathComponent): \(data.count) bytes")
            return url
        } catch {
            LLog("picplace: could not write the poster for \(folder.lastPathComponent): \(error)")
            return nil
        }
    }
}

/// `Projects/<id>/picture-<token>.heic` — the project's full-size working
/// copy (docs/picture-tiers-plan.md §3.2; the server's contract names it so,
/// under kind `proxy`): the grade applied to the picture, levelled, at the
/// source's own pixel size, no crop and nothing drawn on it, HEIC at 0.85 in
/// the grader's own colour space (Display P3 for raw, sRGB for sRGB sources).
/// Rendered by the device that pushes the project, only when the project
/// needs one (`AppModel.needsProxy`, Steven's D6), and named by its recipe so
/// any device tells a fresh copy from a stale one by the name alone. One per
/// folder: a new token replaces the file. The render applies the project's
/// quarter turns as every decode does, so the token carries them, as the
/// poster's does.
enum PicPlaceProxy {

    static let quality = 0.85

    /// The working copy's URL after making sure the one on disk is
    /// `nameToken`'s — rendered when it is not, any other copy removed.
    /// nil when the picture did not render or HEIC cannot be written here.
    static func ensure(sourceURL: URL, grade: PhotoGrade, nameToken: String, in folder: URL) async -> URL? {
        let url = folder.appendingPathComponent(ProjectFileRegistry.proxyPictureName(token: nameToken))
        if FileManager.default.fileExists(atPath: url.path) {
            removeAll(in: folder, except: url.lastPathComponent)
            return url
        }
        let started = Date()
        let rendered = await MediaWorkQueue.shared.run { () -> (data: Data, width: Int, height: Int)? in
            // Unlevelled and uncropped (2026-10-04): the level is a record
            // applied on display, like the crop, so the Angle slider works
            // on the copy without the originals.
            guard let image = PhotoGrader.render(
                url: sourceURL, preset: grade.preset, adjustments: grade.adjustments.withoutGeometry,
                rotationDegrees: 0, whiteBalance: grade.whiteBalance,
                maxDimension: nil, cropped: false) else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return (data as Data, image.width, image.height)
        }
        guard let result = rendered ?? nil else {
            LLog("picplace: no working copy for \(folder.lastPathComponent) — \(sourceURL.lastPathComponent) did not render, or HEIC cannot be written here")
            return nil
        }
        do {
            try result.data.write(to: url, options: .atomic)
            removeAll(in: folder, except: url.lastPathComponent)
            LLog(String(format: "picplace: working copy for %@: %d×%d, %d bytes, %.1f s",
                        folder.lastPathComponent, result.width, result.height, result.data.count, Date().timeIntervalSince(started)))
            return url
        } catch {
            LLog("picplace: could not write the working copy for \(folder.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Every `picture-*.heic` in the folder but `keep` — an exempt project
    /// (its own working copy) keeps none, a re-render keeps the new one.
    static func removeAll(in folder: URL, except keep: String? = nil) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name != keep && ProjectFileRegistry.isProxyPicture(fileName: name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// The working copy in the folder, if one is there.
    static func existing(in folder: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return names.filter { ProjectFileRegistry.isProxyPicture(fileName: $0) }.sorted().last
            .map { folder.appendingPathComponent($0) }
    }
}
