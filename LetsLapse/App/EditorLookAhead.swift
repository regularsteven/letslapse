import AVFoundation
import ImageIO
import LetsLapseKit
import SwiftUI

// MARK: - The editor's opening picture, made ahead (2026-09-25)
//
// Connected asset states, stage 4 (docs/connected-asset-states-plan.md §13):
// a swipe on the device that holds the originals arrived on a blurred grid
// thumbnail and waited — the next project's editor mounted only once the page
// had settled, then decoded its frame (a 48 MP DNG at 2000 px) and graded it
// from nothing. The pager now renders its neighbours' opening pictures while a
// page is being looked at, through exactly the grader call the editor's first
// render makes — so the page that slides in is the real picture, and the
// editor that mounts under it finds its first render in the grader's cache.

/// What the photo editor's first render of a project asks the grader for:
/// the frame it opens on, the grade at that moment (less the crop — the
/// editor draws the crop over the whole levelled picture), the white declared
/// there, at the editor's preview size.
struct EditorOpeningRender: Sendable {
    let url: URL
    let preset: PhotoPreset
    let adjustments: PhotoAdjustments
    let whiteBalance: WhiteBalanceTrack

    /// The grader's answer — the same call as `PhotoViewerView.render()`,
    /// so the result is the editor's own first picture, cached.
    func render() -> CGImage? {
        PhotoGrader.render(
            url: url, preset: preset, adjustments: adjustments,
            whiteBalance: whiteBalance, maxDimension: AppModel.editorPreviewLongEdge, cropped: false)
    }
}

extension AppModel {
    /// The long edge the photo editor renders its preview at.
    static let editorPreviewLongEdge: CGFloat = 2000

    /// The photo editor's opening render of `capture`, worked out the way the
    /// editor works it out when it mounts: an interval shoot opens on its
    /// first frame on the strip (the hidden ones left out) at position 0; a
    /// Photo capture, or a shoot of one frame, on its asset. Nil for a movie
    /// or a project whose picture is not on this device — their pages have
    /// nothing to grade.
    func editorOpeningRender(for capture: CaptureProject) -> EditorOpeningRender? {
        guard case .still(let assetURL) = editorAsset(for: capture) else { return nil }
        let position: Double = 0
        var url = assetURL
        if capture.kind == .photos, !capture.isPhotoCapture {
            let hidden = effectiveHideBadFrames(for: capture) ? nominatedBadFrameNames(for: capture) : []
            let frames = sourceFrameURLs(for: capture).filter { !hidden.contains($0.lastPathComponent) }
            // `FrameAxis.index(atPosition: 0)` is the first frame.
            if frames.count > 1 { url = frames[0] }
        }
        var adjustments = gradeTimeline(for: capture).adjustments(at: position, baseline: photoAdjustments(for: capture))
        adjustments.crop = nil
        let white = whiteBalanceTrack(for: capture).declared(atPosition: position)
            .map { WhiteBalanceTrack(source: .fixed(kelvin: $0.kelvin, tint: $0.tint)) } ?? .asShot
        return EditorOpeningRender(url: url, preset: photoPreset(for: capture), adjustments: adjustments, whiteBalance: white)
    }
}

// MARK: - Preview pictures

/// Decoded preview pictures (`poster.jpg` today; the server's renditions once
/// D2 lands — `AppModel.previewPictureURL(for:)` is the one door), shared by
/// the editor's preview page and the pager's look-ahead: a neighbour decoded
/// while its page was one swipe away is on screen the moment it arrives.
/// Keyed by path and modification date, so a re-rendered poster is decoded
/// again rather than served stale.
enum PreviewPictureCache {
    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 8
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private static func key(_ url: URL) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(modified)" as NSString
    }

    /// The decoded picture when it is already here.
    static func cached(_ url: URL) -> CGImage? {
        cache.object(forKey: key(url))?.image
    }

    /// Decodes (or finds) the picture — off the main actor.
    static func decode(_ url: URL) -> CGImage? {
        let key = key(url)
        if let hit = cache.object(forKey: key) { return hit.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        cache.setObject(Box(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}

/// What the pager can make ahead of a page, by what the page will show.
enum EditorLookAheadJob: Sendable {
    /// A still: the photo editor's opening render.
    case still(EditorOpeningRender)
    /// A preview: its picture, decoded.
    case preview(URL)

    func make() -> CGImage? {
        switch self {
        case .still(let render): return render.render()
        case .preview(let url): return PreviewPictureCache.decode(url)
        }
    }
}

extension AppModel {
    /// What the pager makes ahead of `capture`'s page — nil for a movie
    /// (its page mounts a player; the grid's thumbnail is its poster) and
    /// for a preview with no picture.
    func editorLookAheadJob(for capture: CaptureProject) -> EditorLookAheadJob? {
        switch editorAsset(for: capture) {
        case .still: return editorOpeningRender(for: capture).map(EditorLookAheadJob.still)
        case .movie: return nil
        case .preview, nil: return previewPictureURL(for: capture).map(EditorLookAheadJob.preview)
        }
    }
}

// MARK: - Movies

/// A neighbouring movie's asset, opened and measured while its page was a
/// swipe away: the video editor that mounts on it skips the asset's first
/// open and duration read (~300 ms for a 4K clip on the iPhone 16 Pro,
/// 2026-09-25) and goes straight to its player item. One use each — a
/// player item is made fresh from it.
@MainActor enum VideoAssetCache {
    private static var entries: [URL: (asset: AVAsset, duration: Double, at: Date)] = [:]

    /// Opens `url`'s asset (its project's quarter turns on) and reads its
    /// length, off the main actor, and keeps them for the page.
    static func prepare(_ url: URL) async {
        guard entries[url] == nil else { return }
        let asset = await TurnedMedia.asset(for: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        entries[url] = (asset, duration, Date())
        // Only the pages either side are ever wanted.
        if entries.count > 4 {
            for key in entries.sorted(by: { $0.value.at < $1.value.at }).prefix(entries.count - 4).map(\.key) {
                entries[key] = nil
            }
        }
    }

    /// The prepared asset and length for `url`, once.
    static func take(_ url: URL) -> (asset: AVAsset, duration: Double)? {
        guard let entry = entries.removeValue(forKey: url) else { return nil }
        return (entry.asset, entry.duration)
    }
}

// MARK: - The Mac's item view

/// The same look-ahead for a walk that has no posters to slide — the Mac's
/// filmstrip and ←/→ (2026-09-25): a beat after a page arrives (its own
/// render goes first), the projects either side are made — the way the
/// last move went first — into the caches the editor reads: the grader's
/// for a still, `PreviewPictureCache` for a preview, `VideoAssetCache` for a
/// movie.
@MainActor enum EditorLookAheadRunner {
    private static var task: Task<Void, Never>?

    static func warm(around id: UUID, in ids: [UUID], direction: Int, model: AppModel) {
        task?.cancel()
        guard let index = ids.firstIndex(of: id) else { return }
        let step = direction >= 0 ? 1 : -1
        let neighbours = [index + step, index - step].filter { ids.indices.contains($0) }.map { ids[$0] }
        task = Task {
            try? await Task.sleep(for: .milliseconds(500))
            for neighbour in neighbours {
                guard !Task.isCancelled, let capture = model.capture(id: neighbour) else { return }
                if case .movie(let url) = model.editorAsset(for: capture) {
                    await VideoAssetCache.prepare(url)
                } else if let job = model.editorLookAheadJob(for: capture) {
                    _ = await MediaWorkQueue.lookAhead.run { job.make() }
                }
            }
        }
    }
}
