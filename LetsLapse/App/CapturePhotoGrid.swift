import SwiftUI

/// A square thumbnail grid over any set of assets, with pinch-to-zoom column
/// count. Both the Gallery tab (one tile per project's hero asset) and the
/// per-project photo browser (one tile per interval frame) render through this:
/// the only differences are where the tiles come from and what a tap does.
struct CaptureAssetGrid<Item: Identifiable>: View {
    var items: [Item]
    /// The asset a tile shows; nil renders the neutral placeholder.
    var asset: (Item) -> (url: URL, kind: AppModel.MediaKind)?
    var onTap: (Item) -> Void

    /// Shared with the Gallery on purpose — one zoom level for every grid.
    @AppStorage("gallery.columnCount") private var columnCount: Int = 3

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount),
                spacing: 2
            ) {
                ForEach(items) { item in
                    CaptureAssetTile(hero: asset(item))
                        .aspectRatio(1, contentMode: .fit)
                        .onTapGesture { onTap(item) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .gesture(
            MagnificationGesture()
                .onEnded { scale in
                    let newCount = scale < 1 ? min(columnCount + 1, 5) : max(columnCount - 1, 2)
                    withAnimation(.easeInOut(duration: 0.2)) { columnCount = newCount }
                }
        )
    }
}

/// One square grid cell. Loads its thumbnail through the shared cache so
/// scrolling doesn't re-decode. Shows a neutral placeholder until ready.
private struct CaptureAssetTile: View {
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

// MARK: - Per-project photo browser

/// One frame in a per-project photo browser. Index-keyed, so two frames that
/// resolve to the same path can't collide in the grid or the pager.
struct CaptureFrame: Identifiable, Hashable {
    let index: Int
    let url: URL

    var id: Int { index }
}

/// An unfiltered grid over ONE project's source frames — the interval shoot's
/// individual photos, which until now were only reachable as a batch export.
/// Tapping a tile opens the fullscreen viewer, where any single frame can go to
/// Photos on its own.
struct CapturePhotoGrid: View {
    var title: String
    var frames: [CaptureFrame]

    @Environment(\.dismiss) private var dismiss
    @State private var viewing: CaptureFrame?

    init(title: String, urls: [URL]) {
        self.title = title
        self.frames = urls.enumerated().map { CaptureFrame(index: $0.offset, url: $0.element) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if frames.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No source photos")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CaptureAssetGrid(
                        items: frames,
                        asset: { ($0.url, AppModel.MediaKind.image) },
                        onTap: { viewing = $0 }
                    )
                }
            }
            .background(LL.screenBackground)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $viewing) { frame in
            CaptureFrameViewer(frames: frames, start: frame)
        }
        #else
        .sheet(item: $viewing) { frame in
            CaptureFrameViewer(frames: frames, start: frame)
                .frame(minWidth: 520, minHeight: 420)
        }
        #endif
    }
}

/// The fullscreen frame viewer: swipe through a project's photos, save the one
/// on screen to Photos. Save state is per frame, so paging away from a saved
/// photo doesn't claim the next one is saved too.
private struct CaptureFrameViewer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var frames: [CaptureFrame]
    @State private var selection: Int
    @State private var saveStates: [Int: SaveState] = [:]

    init(frames: [CaptureFrame], start: CaptureFrame) {
        self.frames = frames
        _selection = State(initialValue: start.id)
    }

    private enum SaveState: Equatable {
        case saving, saved, failed(String)
    }

    private var current: CaptureFrame? {
        frames.first { $0.id == selection }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pager
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
        }
        #if os(iOS)
        .statusBarHidden()
        #endif
    }

    @ViewBuilder private var pager: some View {
        #if os(iOS)
        TabView(selection: $selection) {
            ForEach(frames) { frame in
                ProjectPreviewImage(url: frame.url, background: AnyShapeStyle(Color.black))
                    .tag(frame.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        #else
        if let current {
            ProjectPreviewImage(url: current.url, background: AnyShapeStyle(Color.black))
        }
        #endif
    }

    private var topBar: some View {
        HStack {
            Button("Done") { dismiss() }
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
            Spacer()
            Text("\(selection + 1) of \(frames.count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black.opacity(0.35))
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if case .failed(let message) = saveStates[selection] {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 14) {
                #if os(macOS)
                stepButton(systemImage: "chevron.left", delta: -1)
                #endif
                if let current {
                    saveControl(for: current)
                }
                #if os(macOS)
                stepButton(systemImage: "chevron.right", delta: 1)
                #endif
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.35))
    }

    @ViewBuilder private func saveControl(for frame: CaptureFrame) -> some View {
        #if os(iOS)
        Button {
            save(frame)
        } label: {
            switch saveStates[frame.id] {
            case .saving:
                Label("Saving…", systemImage: "square.and.arrow.down")
            case .saved:
                Label("Saved to Photos", systemImage: "checkmark")
            case .failed:
                Label("Retry save", systemImage: "square.and.arrow.down")
            case nil:
                Label("Save to Photos", systemImage: "square.and.arrow.down")
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(saveStates[frame.id] == .saved ? Color.white.opacity(0.18) : LL.accent,
                    in: Capsule())
        .buttonStyle(.plain)
        .disabled(saveStates[frame.id] == .saving || saveStates[frame.id] == .saved)
        #else
        ShareLink(item: frame.url) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        #endif
    }

    #if os(macOS)
    private func stepButton(systemImage: String, delta: Int) -> some View {
        Button {
            selection = min(max(selection + delta, 0), frames.count - 1)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.15), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(delta < 0 ? selection == 0 : selection >= frames.count - 1)
    }
    #endif

    private func save(_ frame: CaptureFrame) {
        #if os(iOS)
        saveStates[frame.id] = .saving
        Task {
            do {
                try await model.saveSourceClip(at: frame.url)
                saveStates[frame.id] = .saved
            } catch {
                saveStates[frame.id] = .failed(error.localizedDescription)
            }
        }
        #endif
    }
}
