import AVFoundation
import AVKit
import ImageIO
import SwiftUI

enum ProjectBrowserDisplayMode: String, CaseIterable, Identifiable {
    case list = "List"
    case grid = "Grid"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }
}

struct ProjectBrowserModePicker: View {
    @Binding var selection: ProjectBrowserDisplayMode

    var body: some View {
        Picker("Display", selection: $selection) {
            ForEach(ProjectBrowserDisplayMode.allCases) { mode in
                Label(mode.rawValue, systemImage: mode.iconName)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 220)
    }
}

struct MediaPreviewItem: Identifiable, Hashable {
    var title: String
    var subtitle: String?
    var url: URL
    var kind: AppModel.MediaKind

    var id: String {
        "\(kind)-\(url.path)"
    }
}

struct ProjectBrowserView<Item: Identifiable, Actions: View, ExpandedContent: View>: View {
    var items: [Item]
    var displayMode: ProjectBrowserDisplayMode
    var title: (Item) -> String
    var subtitle: (Item) -> String
    var metadata: (Item) -> String?
    var mediaURL: (Item) -> URL?
    var mediaKind: (Item) -> AppModel.MediaKind
    @ViewBuilder var actions: (Item) -> Actions
    @ViewBuilder var expandedContent: (Item) -> ExpandedContent

    private let gridColumns = [
        GridItem(.adaptive(minimum: 168, maximum: 260), spacing: 12, alignment: .top)
    ]

    var body: some View {
        Group {
            switch displayMode {
            case .list:
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        ProjectBrowserCard(
                            item: item,
                            displayMode: displayMode,
                            title: title,
                            subtitle: subtitle,
                            metadata: metadata,
                            mediaURL: mediaURL,
                            mediaKind: mediaKind,
                            actions: actions,
                            expandedContent: expandedContent
                        )
                    }
                }
            case .grid:
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(items) { item in
                        ProjectBrowserCard(
                            item: item,
                            displayMode: displayMode,
                            title: title,
                            subtitle: subtitle,
                            metadata: metadata,
                            mediaURL: mediaURL,
                            mediaKind: mediaKind,
                            actions: actions,
                            expandedContent: expandedContent
                        )
                    }
                }
            }
        }
        .animation(.default, value: displayMode)
    }
}

private struct ProjectBrowserCard<Item: Identifiable, Actions: View, ExpandedContent: View>: View {
    var item: Item
    var displayMode: ProjectBrowserDisplayMode
    var title: (Item) -> String
    var subtitle: (Item) -> String
    var metadata: (Item) -> String?
    var mediaURL: (Item) -> URL?
    var mediaKind: (Item) -> AppModel.MediaKind
    @ViewBuilder var actions: (Item) -> Actions
    @ViewBuilder var expandedContent: (Item) -> ExpandedContent

    var body: some View {
        switch displayMode {
        case .list:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    ProjectThumbnailView(url: mediaURL(item), kind: mediaKind(item))
                        .frame(width: 86, height: 64)

                    VStack(alignment: .leading, spacing: 6) {
                        ProjectBrowserTextBlock(
                            title: title(item),
                            subtitle: subtitle(item),
                            metadata: metadata(item)
                        )
                        actions(item)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                expandedContent(item)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        case .grid:
            VStack(alignment: .leading, spacing: 10) {
                ProjectThumbnailView(url: mediaURL(item), kind: mediaKind(item))
                    .aspectRatio(1.35, contentMode: .fit)

                ProjectBrowserTextBlock(
                    title: title(item),
                    subtitle: subtitle(item),
                    metadata: metadata(item)
                )
                .frame(minHeight: 72, alignment: .topLeading)

                actions(item)
                expandedContent(item)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct ProjectBrowserTextBlock: View {
    var title: String
    var subtitle: String
    var metadata: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .lineLimit(2)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let metadata {
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct ProjectThumbnailView: View {
    var url: URL?
    var kind: AppModel.MediaKind
    @State private var thumbnail: CGImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)

            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: kind == .video ? "film" : "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Image(systemName: kind == .video ? "play.fill" : "photo.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(6)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.16))
        }
        .clipped()
        .task(id: url) {
            thumbnail = nil
            guard let url else { return }
            thumbnail = await ProjectThumbnailGenerator.thumbnail(for: url, kind: kind)
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
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                case .image:
                    ProjectPreviewImage(url: item.url)
                        .frame(minHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            image = await ProjectThumbnailGenerator.fullImage(at: url)
        }
    }
}

private enum ProjectThumbnailGenerator {
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

    static func fullImage(at url: URL) async -> CGImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
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
