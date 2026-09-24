import AVFoundation
import CoreTransferable
import LetsLapseKit
import UniformTypeIdentifiers

/// Movies shown with their project's quarter turns (Rotate 90° as a record,
/// 2026-09-24). A player applies a track's own transform by itself, and the
/// file carries only the camera's; a turn that lives on the project reaches
/// the player through a thin composition whose video track carries the
/// transform *turned* — the player then turns the picture exactly as it
/// would a portrait clip, nothing is re-rendered, and the file is untouched.
enum TurnedMedia {

    /// The asset to play or grab frames from for the movie at `url`: the file
    /// itself when its project has no turn, else a composition of its video
    /// and audio whose video track's transform is turned.
    static func asset(for url: URL) async -> AVAsset {
        let file = AVURLAsset(url: url)
        let turns = ProjectOrientation.shared.turns(for: url)
        guard turns != 0 else { return file }
        return await turned(file, by: turns) ?? file
    }

    /// A player item for the movie at `url` that shows its project's turn.
    static func playerItem(for url: URL) async -> AVPlayerItem {
        AVPlayerItem(asset: await asset(for: url))
    }

    /// `asset` with its video track's transform turned `turns` quarter turns
    /// clockwise — nil when it has no video track to turn.
    static func turned(_ asset: AVAsset, by turns: Int) async -> AVAsset? {
        guard QuarterTurns.normalized(turns) != 0,
              let video = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, preferred) = try? await video.load(.naturalSize, .preferredTransform),
              let duration = try? await asset.load(.duration) else { return nil }
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: duration)
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? track.insertTimeRange(range, of: video, at: .zero)) != nil else { return nil }
        track.preferredTransform = QuarterTurns.transform(preferred, naturalSize: natural, turnedBy: turns)
        for audio in (try? await asset.loadTracks(withMediaType: .audio)) ?? [] {
            if let copy = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? copy.insertTimeRange(range, of: audio, at: .zero)
            }
        }
        return composition
    }

    /// A frame an `AVAssetImageGenerator` made from the file at `url` with
    /// only the file's own transform applied, turned the way its project
    /// shows it.
    static func turned(_ image: CGImage, from url: URL) -> CGImage {
        QuarterTurns.turned(image, by: ProjectOrientation.shared.turns(for: url))
    }

    /// The file to hand to something outside the app — Photos, a share
    /// sheet, a save panel — for `url`: the file itself when its project
    /// shows it with no turn, else a copy in the temporary folder, under the
    /// same name, with the turn written the way its format carries one
    /// (`MediaRotator.rotate`), so it arrives the way the project shows it.
    /// The original is never touched. On APFS the copy is a clone, so only
    /// what the turn rewrites costs space. A format that can't carry a turn —
    /// a raw that isn't built on TIFF, say — goes as it is.
    static func shareableCopy(of url: URL) async -> URL {
        let turns = ProjectOrientation.shared.turns(for: url)
        guard turns != 0 else { return url }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-turned-\(UUID().uuidString)", isDirectory: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            try await MediaRotator.rotate(at: copy, quarterTurns: turns)
            return copy
        } catch {
            LLog("turned copy of \(url.lastPathComponent) failed (\(error.localizedDescription)) — it goes as it is")
            try? FileManager.default.removeItem(at: folder)
            return url
        }
    }

    /// Removes a copy `shareableCopy` made, once it has been handed over;
    /// the file itself, when that is what was handed over, is left alone.
    static func discard(_ copy: URL, for original: URL) {
        guard copy != original else { return }
        try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
    }
}

/// A project file for a `ShareLink`, with its project's turn written into
/// the copy that leaves (`TurnedMedia.shareableCopy`) — made when the share
/// sheet asks for it, not whenever a view shows a Share button.
struct TurnedShareFile: Transferable {
    let url: URL

    private var isMovie: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false }
    private var isImage: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .movie) { file in
            SentTransferredFile(await TurnedMedia.shareableCopy(of: file.url))
        }
        .exportingCondition { $0.isMovie }
        FileRepresentation(exportedContentType: .image) { file in
            SentTransferredFile(await TurnedMedia.shareableCopy(of: file.url))
        }
        .exportingCondition { $0.isImage }
        FileRepresentation(exportedContentType: .data) { file in
            SentTransferredFile(await TurnedMedia.shareableCopy(of: file.url))
        }
    }
}
