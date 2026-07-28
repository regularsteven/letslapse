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
            .task(id: url) {
                thumbnail = nil
                guard let url else { return }
                thumbnail = await ProjectThumbnailCache.shared.thumbnail(for: url, kind: kind)
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

private struct ProjectPreviewImage: View {
    var url: URL
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)
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
            failed = image == nil
        }
    }
}

enum ProjectThumbnailGenerator {
    static func thumbnail(for url: URL, kind: AppModel.MediaKind) async -> CGImage? {
        await Task.detached(priority: .utility) {
            switch kind {
            case .video:
                return videoThumbnail(for: url)
            case .image:
                return imageThumbnail(for: url, maxPixelSize: 480)
            }
        }.value
    }

    /// A screen-sized decode for the full-screen preview. Goes through the
    /// thumbnail API rather than `CGImageSourceCreateImageAtIndex` for two
    /// reasons: it applies the EXIF/TIFF orientation (a raw index-0 decode
    /// draws the app's DNG captures sideways), and it bounds memory — a
    /// full-resolution RAW decode is ~50 MB where 2560 px is plenty for any
    /// display.
    static func displayImage(at url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 2560,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
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
