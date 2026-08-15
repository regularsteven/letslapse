import SwiftUI

/// A square thumbnail grid over any set of assets, with pinch-to-zoom column
/// count. Both the Gallery tab (one tile per project's hero asset) and the
/// per-project photo browser (one tile per interval frame) render through this:
/// the only differences are where the tiles come from and what a tap does.
struct CaptureAssetGrid<Item: Identifiable>: View {
    var items: [Item]
    /// The asset a tile shows; nil renders the neutral placeholder.
    var asset: (Item) -> (url: URL, kind: AppModel.MediaKind)?
    /// A colour grade to render still tiles through — one project's grade, when
    /// the grid belongs to a project. The Gallery passes nil: its tiles are one
    /// per project and each is its own finished asset.
    var grade: PhotoGrade? = nil
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
                    CaptureAssetTile(hero: asset(item), grade: grade)
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
    /// When set (and not a no-op), still tiles render through this grade instead
    /// of coming from the shared thumbnail cache — the cache is keyed by file
    /// alone, and a graded tile is not the file.
    var grade: PhotoGrade? = nil
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
        .task(id: "\(hero?.url.path ?? "-")|\(cache.generation)|\(grade?.cacheToken ?? "-")") {
            // Only blank for a different asset: re-requesting the same one
            // (cache invalidated, or the cell was rebuilt) keeps what's on
            // screen, so a cache purge doesn't flash the whole grid to gray.
            if loadedPath != hero?.url.path {
                image = nil
                failed = false
                loadedPath = hero?.url.path
            }
            guard let hero else { return }
            let loaded = await load(hero)
            if let loaded {
                image = loaded
                failed = false
            } else if !Task.isCancelled, image == nil {
                failed = true
            }
        }
    }

    /// A graded still is rendered per tile; everything else comes from the shared
    /// thumbnail cache. Tile-sized renders are cheap, and only a project whose
    /// grade is actually set pays for them.
    private func load(_ hero: (url: URL, kind: AppModel.MediaKind)) async -> Image? {
        guard let grade, !grade.isIdentity, hero.kind == .image else {
            return await ProjectThumbnailCache.shared.thumbnail(for: hero.url, kind: hero.kind)
        }
        let rendered = await MediaWorkQueue.shared.run {
            PhotoGrader.render(
                url: hero.url, preset: grade.preset, adjustments: grade.adjustments,
                maxDimension: 480)
        }
        // The outer nil is the work queue's "didn't run", the inner one a failed
        // render; either way fall back to the ungraded thumbnail rather than
        // leaving a gray tile.
        guard let rendered, let cgImage = rendered else {
            return await ProjectThumbnailCache.shared.thumbnail(for: hero.url, kind: hero.kind)
        }
        return Image(decorative: cgImage, scale: 1)
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
///
/// Every frame is shown through the project's colour grade, so this grid and the
/// project card agree about what the shoot looks like; the files themselves are
/// untouched.
struct CapturePhotoGrid: View {
    var title: String
    var frames: [CaptureFrame]
    /// The project these frames belong to, for its grade. Optional so a caller
    /// with no project context can still browse a plain set of files.
    var captureID: UUID?

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var viewing: CaptureFrame?

    init(title: String, urls: [URL], captureID: UUID? = nil) {
        self.title = title
        self.frames = urls.enumerated().map { CaptureFrame(index: $0.offset, url: $0.element) }
        self.captureID = captureID
    }

    /// The grade to render frames through, or nil when this grid isn't a
    /// project's (or the project's grade is a no-op).
    private var grade: PhotoGrade? {
        guard let captureID,
              let capture = model.captures.first(where: { $0.id == captureID }) else { return nil }
        let grade = model.photoGrade(for: capture)
        return grade.isIdentity ? nil : grade
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
                        grade: grade,
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
            CaptureFrameViewer(frames: frames, start: frame, captureID: captureID)
        }
        #else
        .sheet(item: $viewing) { frame in
            CaptureFrameViewer(frames: frames, start: frame, captureID: captureID)
                .frame(minWidth: 520, minHeight: 420)
        }
        #endif
    }
}

/// The fullscreen frame viewer: swipe through a project's photos, save the one
/// on screen — to Photos on iOS, through a save panel on macOS. Save state is
/// per frame, so paging away from a saved photo doesn't claim the next one is
/// saved too.
///
/// The frame is shown as the project grades it, and Save writes what is on
/// screen — a graded JPEG, or the file's own bytes when the grade is untouched.
private struct CaptureFrameViewer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var frames: [CaptureFrame]
    var captureID: UUID?
    @State private var selection: Int
    @State private var saveStates: [Int: SaveState] = [:]

    init(frames: [CaptureFrame], start: CaptureFrame, captureID: UUID? = nil) {
        self.frames = frames
        self.captureID = captureID
        _selection = State(initialValue: start.id)
    }

    private var capture: AppModel.CaptureProject? {
        guard let captureID else { return nil }
        return model.captures.first { $0.id == captureID }
    }

    private var grade: PhotoGrade? {
        guard let capture else { return nil }
        let grade = model.photoGrade(for: capture)
        return grade.isIdentity ? nil : grade
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
                ProjectPreviewImage(
                    url: frame.url, background: AnyShapeStyle(Color.black), grade: grade)
                    .tag(frame.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        #else
        if let current {
            ProjectPreviewImage(
                url: current.url, background: AnyShapeStyle(Color.black), grade: grade)
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

    private func saveControl(for frame: CaptureFrame) -> some View {
        Button {
            save(frame)
        } label: {
            let state = saveStates[frame.id]
            Label(saveTitle(for: state),
                  systemImage: state == .saved ? "checkmark" : "square.and.arrow.down")
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(saveStates[frame.id] == .saved ? Color.white.opacity(0.18) : LL.accent,
                    in: Capsule())
        .buttonStyle(.plain)
        .disabled(saveStates[frame.id] == .saving || saveStates[frame.id] == .saved)
    }

    /// The capsule's caption for one frame's state — Photos-flavoured on iOS,
    /// file-export-flavoured on macOS, where the same button runs a save panel.
    private func saveTitle(for state: SaveState?) -> String {
        #if os(iOS)
        switch state {
        case .saving: return "Saving…"
        case .saved: return "Saved to Photos"
        case .failed: return "Retry save"
        case nil: return "Save to Photos"
        }
        #else
        switch state {
        case .saving: return "Exporting…"
        case .saved: return "Exported"
        case .failed: return "Retry export"
        case nil: return "Export…"
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

    /// Saves (iOS) or exports (macOS) what the viewer is showing: the grade
    /// baked into a temporary copy, or the frame's own bytes when it is
    /// untouched.
    private func save(_ frame: CaptureFrame) {
        saveStates[frame.id] = .saving
        Task {
            do {
                #if os(iOS)
                if let capture {
                    try await model.saveGradedAsset(at: frame.url, for: capture)
                } else {
                    try await model.saveSourceClip(at: frame.url)
                }
                saveStates[frame.id] = .saved
                #else
                let export: (url: URL, isTemporary: Bool)
                if let capture {
                    export = try await model.gradedExportCopy(of: frame.url, for: capture)
                } else {
                    export = (frame.url, false)
                }
                defer {
                    if export.isTemporary {
                        try? FileManager.default.removeItem(at: export.url)
                    }
                }
                let exported = try await MacExporter.exportCopy(
                    of: export.url, suggestedName: suggestedName(for: frame, export: export))
                // A cancelled panel is not a failure — the button just offers
                // Export… again.
                saveStates[frame.id] = exported ? .saved : nil
                #endif
            } catch {
                saveStates[frame.id] = .failed(error.localizedDescription)
            }
        }
    }

    #if os(macOS)
    /// The name the save panel offers: the original's own name when its bytes
    /// go out untouched, `<name>-graded.<ext>` when the grade was baked into a
    /// copy — whose extension can differ, since a graded still is a JPEG.
    private func suggestedName(
        for frame: CaptureFrame, export: (url: URL, isTemporary: Bool)
    ) -> String {
        guard export.isTemporary else { return frame.url.lastPathComponent }
        return frame.url.deletingPathExtension().lastPathComponent
            + "-graded." + export.url.pathExtension
    }
    #endif
}
