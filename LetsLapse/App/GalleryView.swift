import SwiftUI

/// The Gallery tab: a square, filterable thumbnail grid over every capture.
/// Each tile shows the project's "hero" asset — for Photo/Interval captures the
/// latest blended image, otherwise the source frame or video. Tapping a tile
/// pushes the same `ProjectDetailView` the Projects tab uses.
struct GalleryView: View {
    @EnvironmentObject var model: AppModel
    @Binding var path: [UUID]
    @AppStorage("gallery.columnCount") private var columnCount: Int = 3
    @State private var filter: GalleryFilter = .all

    private var filteredCaptures: [AppModel.CaptureProject] {
        model.captures.filter { capture in
            switch filter {
            case .all:
                return true
            case .photos:
                return capture.isPhotoCapture
            case .interval:
                return capture.kind == .photos && !capture.isPhotoCapture
            case .video:
                return capture.kind == .video
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                // Manual title, matching the Projects tab (which hides the
                // native navigation bar and draws its own). A native large
                // title would sit under a full navigation-bar height of
                // padding, leaving the two tabs visibly inconsistent.
                Text("Gallery")
                    .font(.system(size: 34, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 20)
                    .padding(.trailing, 16)
                    .padding(.top, 15)

                Picker("Filter", selection: $filter) {
                    ForEach(GalleryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount),
                        spacing: 2
                    ) {
                        ForEach(filteredCaptures) { capture in
                            GalleryTile(hero: model.heroAsset(for: capture))
                                .aspectRatio(1, contentMode: .fit)
                                .onTapGesture { path.append(capture.id) }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .background(LL.screenBackground)
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #else
            .navigationTitle("Gallery")
            #endif
            .navigationDestination(for: UUID.self) { captureID in
                ProjectDetailView(captureID: captureID)
            }
            .gesture(
                MagnificationGesture()
                    .onEnded { scale in
                        let newCount = scale < 1 ? min(columnCount + 1, 5) : max(columnCount - 1, 2)
                        withAnimation(.easeInOut(duration: 0.2)) { columnCount = newCount }
                    }
            )
        }
    }
}

enum GalleryFilter: String, CaseIterable {
    case all = "All"
    case photos = "Photos"
    case interval = "Interval"
    case video = "Video"
}

/// One square grid cell. Loads its thumbnail through the shared cache so
/// scrolling doesn't re-decode. Shows a neutral placeholder until ready.
private struct GalleryTile: View {
    var hero: (url: URL, kind: AppModel.MediaKind)?
    @State private var image: Image?
    @State private var failed = false
    /// Which asset `image` belongs to, so a reload for the same one can keep it
    /// on screen while it runs.
    @State private var loadedPath: String?
    /// Re-runs the load when thumbnails are invalidated (a rotate rewrites
    /// files in place, so the URL alone can't retrigger the task).
    @ObservedObject private var cache = ProjectThumbnailCache.shared

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.gray.opacity(0.18)
                if let image {
                    image
                        .resizable()
                        .scaledToFill()
                } else if failed || hero == nil {
                    Image(systemName: hero?.kind == .video ? "film" : "photo")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: "\(hero?.url.path ?? "-")|\(cache.generation)") {
            // Only blank for a different asset: re-requesting the same one
            // (cache invalidated, or the cell was rebuilt) keeps what's on
            // screen, so a cache purge doesn't flash the whole grid to gray.
            if loadedPath != hero?.url.path {
                image = nil
                failed = false
                loadedPath = hero?.url.path
            }
            guard let hero else { return }
            let loaded = await ProjectThumbnailCache.shared.thumbnail(for: hero.url, kind: hero.kind)
            if let loaded {
                image = loaded
                failed = false
            } else if !Task.isCancelled, image == nil {
                failed = true
            }
        }
    }
}
