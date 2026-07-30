import AVFoundation
import AVKit
import ImageIO
import SwiftUI

struct MediaPreviewItem: Identifiable, Hashable {
    var title: String
    var subtitle: String?
    var url: URL
    var kind: AppModel.MediaKind

    var id: String {
        "\(kind)-\(url.path)"
    }
}

struct ProjectThumbnailView: View {
    var url: URL?
    var kind: AppModel.MediaKind
    @State private var thumbnail: Image?
    /// Which asset `thumbnail` belongs to, so a reload for the *same* asset can
    /// keep the current image on screen while it runs.
    @State private var loadedPath: String?
    /// Re-runs the load when thumbnails are invalidated (files rewritten in
    /// place keep their URL, so the URL alone can't retrigger the task).
    @ObservedObject private var cache = ProjectThumbnailCache.shared

    var body: some View {
        // The base rectangle defines the reported size; the fill image lives
        // in an overlay so it can never push the view past its frame.
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let thumbnail {
                    thumbnail
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: kind == .video ? "film" : "photo")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .task(id: "\(url?.path ?? "-")|\(cache.generation)") {
                // Only blank for a *different* asset. Re-requesting the same one
                // (cache invalidated, or the row was rebuilt) used to clear here
                // first, which turned any cache purge into a wall of gray tiles
                // even when the reload was about to succeed.
                if loadedPath != url?.path {
                    thumbnail = nil
                    loadedPath = url?.path
                }
                guard let url else { return }
                // nil means "no answer" — a failed decode or a cancelled load —
                // so never overwrite an image already on screen with it.
                if let image = await ProjectThumbnailCache.shared.thumbnail(for: url, kind: kind) {
                    thumbnail = image
                }
            }
    }
}

struct ProjectMediaPreviewSheet: View {
    var item: MediaPreviewItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                switch item.kind {
                case .video:
                    VideoPlayer(player: player)
                        .frame(minHeight: 280)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                case .image:
                    ProjectPreviewImage(url: item.url)
                        .frame(minHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding()
            .navigationTitle(item.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if item.kind == .video {
                PlaybackAudioSession.configureAmbient()
                let player = AVPlayer(url: item.url)
                self.player = player
                player.play()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

/// The full-image loader behind both the preview sheet and the fullscreen frame
/// viewer. `background` is what shows while the decode runs — the sheet wants a
/// card-coloured plate, the fullscreen viewer black.
struct ProjectPreviewImage: View {
    var url: URL
    var background: AnyShapeStyle = AnyShapeStyle(.quaternary)
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(background)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                    Text("Couldn't load this image")
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            image = nil
            failed = false
            image = await ProjectThumbnailGenerator.displayImage(at: url)
            // A cancelled load (the sheet was dismissed) isn't a failure.
            if !Task.isCancelled {
                failed = image == nil
            }
        }
    }
}

/// The decoders behind the thumbnail cache and the full-screen preview. Both
/// entry points block for as long as the decode takes, so they run on
/// `MediaWorkQueue` — never on the main actor or the cooperative pool.
enum ProjectThumbnailGenerator {
    static func thumbnail(for url: URL, kind: AppModel.MediaKind) -> CGImage? {
        switch kind {
        case .video:
            return videoThumbnail(for: url)
        case .image:
            return imageThumbnail(for: url, maxPixelSize: 480)
        }
    }

    /// A screen-sized decode for the full-screen preview. Goes through the
    /// thumbnail API rather than `CGImageSourceCreateImageAtIndex` for two
    /// reasons: it applies the EXIF/TIFF orientation (a raw index-0 decode
    /// draws the app's DNG captures sideways), and it bounds memory — a
    /// full-resolution RAW decode is ~50 MB where 2560 px is plenty for any
    /// display.
    static func displayImage(at url: URL) async -> CGImage? {
        let image = await MediaWorkQueue.shared.run { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 2560,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        // Outer nil is a cancelled load, inner nil a failed decode.
        guard let decoded = image else { return nil }
        if decoded == nil {
            MediaWorkQueue.note("display decode failed for \(url.lastPathComponent)", isError: true)
        }
        return decoded
    }

    private static func videoThumbnail(for url: URL) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        return try? generator.copyCGImage(
            at: CMTime(seconds: 0.2, preferredTimescale: 600),
            actualTime: nil
        )
    }

    private static func imageThumbnail(for url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
