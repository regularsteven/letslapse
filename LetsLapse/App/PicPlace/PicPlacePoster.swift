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
    static func ensure(sourceURL: URL, kind: AppModel.MediaKind, grade: PhotoGrade, token: String,
                       lastToken: String?, in folder: URL) async -> URL? {
        let url = folder.appendingPathComponent(ProjectFileRegistry.posterName)
        if lastToken == token, FileManager.default.fileExists(atPath: url.path) { return url }
        let rendered = await MediaWorkQueue.shared.run { () -> Data? in
            let image: CGImage? = kind == .video
                ? VideoGrader.gradedFrame(at: sourceURL, grade: grade, maxDimension: maxDimension)
                : PhotoGrader.render(url: sourceURL, preset: grade.preset, adjustments: grade.adjustments,
                                     rotationDegrees: grade.rotationDegrees, whiteBalance: grade.whiteBalance,
                                     maxDimension: maxDimension)
            guard let image else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }
        guard let data = rendered ?? nil else {
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
