#if os(iOS)
import LetsLapseKit
import SwiftUI

// MARK: - The editor pager (iOS, 2026-09-21)
//
// The phone's answer to the Mac's item view: the editor as one page of a
// swipe through the library. A tap on a Gallery tile (or the camera's recent
// tile) opens the project's editor straight away, and a drag across the
// picture at fit scale slides to the neighbouring project the way a photo
// app walks a camera roll — the current editor slides out under the finger,
// the neighbour's poster slides in, and once the page settles the editor is
// rebuilt for the project that arrived. Back lands wherever the swipe ended.
//
// One editor lives at a time: the neighbours are posters (the grid's own
// thumbnails, fitted where the editor's picture is), never editors, so a
// thousand-frame shoot two pages away costs nothing until it is the page.
// The editor leaves through its own exit path (`EditorExitRequest`, the
// Mac's plumbing) so its writes land before the next one mounts.

/// One trip through the editor over an ordered set of projects.
struct EditorPagerRequest: Identifiable, Equatable {
    /// The set, in the order the swipe walks it — the list the person came
    /// from, as it was sorted and filtered when they left it.
    var ids: [UUID]
    /// Where it opens.
    var current: UUID
    var page: RailTab = .editor
    /// Clear preview from the first page (`LL_CLEAR=1`).
    var startsClear: Bool = false

    var id: String { "\(current.uuidString)#\(ids.count)#\(page.rawValue)" }
}

/// How a pager was left, for the host to land on.
enum EditorPagerOutcome {
    /// Back: the project the swipe ended on — nil when it was deleted and
    /// had no neighbour to stand in.
    case back(UUID?)
    /// The ⓘ sheet's New clip: the host raises the blend flow once the pager
    /// is down, since the flow rises over the tabs and a cover would hide it.
    case newClip(UUID)
}

struct EditorPager: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: EditorPagerRequest
    /// A page turned and came to rest: the host follows (the Gallery selects
    /// and scrolls to the project on screen, so Back needs no catching up) —
    /// a beat after the turn, never during it (`follow`).
    var onMove: ((UUID) -> Void)? = nil
    /// The pager is leaving: the host lands where the outcome says. A cover
    /// dismisses itself first; an overlay (the camera's) is the host's to
    /// take down — `dismiss` there would close the screen underneath.
    var onClose: ((EditorPagerOutcome) -> Void)? = nil
    var dismissesItself: Bool = true

    @State private var currentID: UUID
    /// The editor on the page, keyed on its project (`GalleryItemEditor`).
    @State private var focus: GalleryFocus?
    @State private var exitRequest: EditorExitRequest?
    /// Where the editor goes once it has left.
    @State private var transition: Transition?
    /// The live drag, as the editor's offset: horizontal for a page turn,
    /// vertical for the clear-preview swipe down.
    @State private var drag: CGSize = .zero
    @State private var dragAxis: Axis?
    /// What the editor on the page allows and where its picture is.
    @State private var pagingState: EditorPagingState?
    /// Clear preview, carried across pages.
    @State private var clearPreview: Bool
    @State private var showsInfo = false
    /// The poster of the project that just arrived, over its editor until
    /// the editor has drawn its own picture — so a page turn hands over in
    /// place rather than through a spinner.
    @State private var settledPoster: Poster?
    @State private var deleteFailure: String?
    /// The page's width, for a page turn made without a finger.
    @State private var containerWidth: CGFloat = 0
    /// Frame gaps on the main thread while a page turns (`PageTurnTrace`).
    @State private var stallProbe = MainThreadStallProbe()
    /// The neighbours' opening pictures, made while this page is looked at
    /// (`EditorLookAhead`): the posters a swipe slides in, and the editor's
    /// first render once one is the page. Only the pages either side.
    @State private var lookAhead: [UUID: CGImage] = [:]
    @State private var lookAheadTask: Task<Void, Never>?
    /// The way the last page turned — its side is made first.
    @State private var lastDirection = 1
    /// The host's follow of the page on screen, once it has been at rest.
    @State private var followTask: Task<Void, Never>?

    private enum Transition: Equatable {
        case back(UUID?)
        case move(UUID)
        /// The ⓘ sheet's New clip: out, then the host raises the flow.
        case newClip(UUID)
    }

    /// What the posters draw: the grid's thumbnail through the project's
    /// grade, the way the tile does.
    private struct Poster: Equatable {
        let id: UUID
        let url: URL?
        let kind: AppModel.MediaKind
        let grade: PhotoGrade?
        /// The editor's own opening picture when the look-ahead has made
        /// it — drawn instead of the grid's thumbnail.
        var picture: CGImage? = nil

        static func == (lhs: Poster, rhs: Poster) -> Bool {
            lhs.id == rhs.id && lhs.url == rhs.url && lhs.kind == rhs.kind && lhs.grade == rhs.grade
                && lhs.picture === rhs.picture
        }
    }

    init(request: EditorPagerRequest,
         onMove: ((UUID) -> Void)? = nil,
         onClose: ((EditorPagerOutcome) -> Void)? = nil,
         dismissesItself: Bool = true) {
        self.request = request
        self.onMove = onMove
        self.onClose = onClose
        self.dismissesItself = dismissesItself
        _currentID = State(initialValue: request.current)
        _clearPreview = State(initialValue: request.startsClear)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack {
                Color.black.ignoresSafeArea()
                // The neighbours' posters, one page over, following the
                // finger. Only the side being dragged toward is drawn.
                if drag.width > 0, let previous = neighbourID(-1) {
                    posterView(poster(for: previous))
                        .offset(x: -width + drag.width)
                }
                if drag.width < 0, let next = neighbourID(1) {
                    posterView(poster(for: next))
                        .offset(x: width + drag.width)
                }
                if let focus {
                    GalleryItemEditor(
                        focus: focus,
                        exitRequest: exitRequest,
                        onExit: completeTransition,
                        paging: pagingContext)
                        .offset(x: drag.width, y: drag.height)
                        .opacity(dragAxis == .vertical ? 1 - min(drag.height / 480, 0.5) : 1)
                }
                if let settledPoster, drag == .zero {
                    posterView(settledPoster)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: EditorPagingState.hostSpace)
            // The editor's own gestures come first — a mask being drawn, a
            // zoomed picture's pan, the strip's scrub — and this one is
            // switched off entirely whenever the editor says a swipe is not
            // the pager's to take.
            .gesture(pageDrag(width: width),
                     including: pagingState?.canPage == true ? .all : .subviews)
            .onChange(of: width, initial: true) { _, next in containerWidth = next }
        }
        #if DEBUG
        .task { await consumePageHook() }
        #endif
        .background(Color.black.ignoresSafeArea())
        .onPreferenceChange(EditorPagingStateKey.self) { state in
            pagingState = state
            // The poster goes once the editor under it has a picture of
            // its own — the new editor's, not the last frame of the old.
            if let state, state.hasPicture, let captureID = state.captureID { pictureArrived(captureID) }
        }
        // And never for longer than a beat: a picture that fails to render
        // (a missing file) must not leave the poster nailed over the editor.
        .task(id: settledPoster?.id) {
            guard settledPoster != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            PageTurnTrace.finish("poster timed out", stall: stallProbe.stop())
            withAnimation(.easeOut(duration: 0.18)) { settledPoster = nil }
            startLookAhead()
        }
        .onDisappear {
            lookAheadTask?.cancel()
            lookAheadTask = nil
            lookAhead = [:]
            followTask?.cancel()
        }
        .onAppear { stage(currentID, page: request.page, poster: true) }
        // The project on the page left the library (deleted from the ⓘ
        // sheet, or from another device): there is no editor left to hold.
        .onChange(of: model.indexRevision) { _, _ in
            guard focus != nil, transition == nil, model.capture(id: currentID) == nil else { return }
            leave(.back(neighbourID(1) ?? neighbourID(-1)))
        }
        .sheet(isPresented: $showsInfo) { infoSheet }
        .alert("Couldn't delete", isPresented: Binding(
            get: { deleteFailure != nil }, set: { if !$0 { deleteFailure = nil } })) {
            Button("OK", role: .cancel) { deleteFailure = nil }
        } message: {
            Text(deleteFailure ?? "")
        }
    }

    // MARK: - The set

    private var currentIndex: Int? { request.ids.firstIndex(of: currentID) }

    /// The project `delta` pages away that is still in the library — a set
    /// snapshotted when the pager opened may name projects since deleted.
    private func neighbourID(_ delta: Int) -> UUID? {
        guard let index = currentIndex else { return nil }
        var next = index + delta
        while request.ids.indices.contains(next) {
            let id = request.ids[next]
            if model.capture(id: id) != nil { return id }
            next += delta
        }
        return nil
    }

    private var pagingContext: EditorPagingContext {
        EditorPagingContext(
            startsClear: clearPreview,
            onClearPreviewChanged: { clearPreview = $0 },
            onInfo: { showsInfo = true },
            onPicture: { pictureArrived($0) })
    }

    /// The editor on the page has its own picture up: the poster over it
    /// goes, and the pages either side are made while this one is looked
    /// at. Said by the editor itself and by its paging preference —
    /// whichever comes first; the other finds nothing left to do.
    private func pictureArrived(_ id: UUID) {
        guard let arriving = settledPoster, arriving.id == id else { return }
        PageTurnTrace.finish("handover", stall: stallProbe.stop())
        withAnimation(.easeOut(duration: 0.18)) { settledPoster = nil }
        startLookAhead()
    }

    // MARK: - Mounting and moving

    /// Puts `id`'s editor on the page — on `page`, under its poster when a
    /// picture would otherwise take a beat to arrive. A project whose
    /// picture is not on this device gets the editor's preview page (it
    /// closed the pager until 2026-09-25).
    private func stage(_ id: UUID, page: RailTab, poster: Bool) {
        guard let capture = model.capture(id: id),
              let opened = model.stageEditor(for: capture, page: page, allowsPreview: true) else {
            // The project left the library: leave the way we came.
            close()
            onClose?(.back(nil))
            return
        }
        currentID = id
        PageTurnTrace.annotate(Self.traceKind(capture, asset: opened.asset))
        focus = GalleryFocus(request: opened, page: page)
        if poster {
            settledPoster = self.poster(for: id)
        }
        prefetchNeighbourPosters()
    }

    /// Warms the thumbnail cache for the pages either side, so the poster
    /// that slides in under a swipe is there from its first frame rather
    /// than decoded on the way — a movie's frame takes AVFoundation a beat.
    private func prefetchNeighbourPosters() {
        let neighbours = [neighbourID(-1), neighbourID(1)].compactMap { $0 }.map(poster(for:))
        Task {
            for poster in neighbours {
                guard let url = poster.url else { continue }
                _ = await ProjectThumbnailCache.shared.thumbnail(for: url, kind: poster.kind, grade: poster.grade)
            }
        }
    }

    /// The page has slid off: the editor leaves — its writes made, no preset
    /// offer in the way — and the next project's editor takes its place.
    private func beginMove(to id: UUID) {
        guard transition == nil else { return }
        PageTurnTrace.mark("slide")
        transition = .move(id)
        exitRequest = EditorExitRequest(offersPresetSave: false)
    }

    /// Out — Back, a deletion, New clip: the editor leaves through its own
    /// exit first, so its writes land.
    private func leave(_ outcome: Transition) {
        guard transition == nil else { return }
        transition = outcome
        if focus != nil {
            exitRequest = EditorExitRequest(offersPresetSave: false)
        } else {
            completeTransition()
        }
    }

    /// The editor has left. Go where the transition said — or, with none
    /// (the editor's own Back button), out.
    private func completeTransition() {
        let outcome = transition
        transition = nil
        exitRequest = nil
        switch outcome {
        case .move(let next):
            PageTurnTrace.mark("exit")
            // The poster of the arriving page is at rest where the editor
            // will draw: mount the editor and drop the drag in one pass.
            stage(next, page: .editor, poster: true)
            drag = .zero
            follow(next)
        case .back(let landing):
            followTask?.cancel()
            close()
            onClose?(.back(landing))
        case .newClip(let id):
            followTask?.cancel()
            close()
            onClose?(.newClip(id))
        case nil:
            followTask?.cancel()
            close()
            onClose?(.back(currentID))
        }
    }

    /// The host follows a page once it has been at rest a moment — never
    /// during the turn (stage 4, 2026-09-25): the Gallery behind the cover
    /// re-selecting and scrolling its grid kept the main thread busy through
    /// every handover, and the new picture waited behind it (~150–300 ms of
    /// a 48 MP photo's turn on the iPhone 16 Pro). A run of quick swipes
    /// follows once, where it stopped; Back lands the grid either way.
    private func follow(_ id: UUID) {
        followTask?.cancel()
        guard onMove != nil else { return }
        followTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            onMove?(id)
        }
    }

    private func close() {
        if dismissesItself { dismiss() }
    }

    // MARK: - The drag

    private func pageDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { value in
                guard transition == nil else { return }
                // The first movement settles the axis for the whole drag.
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) >= abs(value.translation.height)
                        ? .horizontal : .vertical
                }
                switch dragAxis {
                case .horizontal:
                    var x = value.translation.width
                    // Past either end of the set the page resists rather
                    // than opening onto nothing.
                    if (x > 0 && neighbourID(-1) == nil) || (x < 0 && neighbourID(1) == nil) {
                        x *= 0.25
                    }
                    drag = CGSize(width: x, height: 0)
                case .vertical:
                    // Down to leave — clear preview only; elsewhere a
                    // vertical drag over the picture is nobody's.
                    guard clearPreview else { return }
                    drag = CGSize(width: 0, height: max(0, value.translation.height))
                case nil:
                    break
                }
            }
            .onEnded { value in
                let axis = dragAxis
                dragAxis = nil
                guard transition == nil else { return }
                switch axis {
                case .horizontal:
                    let x = value.translation.width
                    let fling = value.predictedEndTranslation.width - x
                    let delta: Int?
                    if x < -width * 0.3 || fling < -240 {
                        delta = 1
                    } else if x > width * 0.3 || fling > 240 {
                        delta = -1
                    } else {
                        delta = nil
                    }
                    if let delta, let target = neighbourID(delta) {
                        lastDirection = delta
                        beginTrace(to: target)
                        withAnimation(.easeOut(duration: 0.22)) {
                            drag = CGSize(width: delta > 0 ? -width : width, height: 0)
                        } completion: {
                            beginMove(to: target)
                        }
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { drag = .zero }
                    }
                case .vertical:
                    if clearPreview, value.translation.height > 120 {
                        // Back, offer and all: the editor decides whether
                        // it can go. The cover's own dismissal carries on
                        // down from here; if the editor stays to offer a
                        // preset, the page comes back up under the offer.
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { drag = .zero }
                        transition = nil
                        exitRequest = EditorExitRequest(offersPresetSave: true)
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { drag = .zero }
                    }
                case nil:
                    break
                }
            }
    }

    // MARK: - Hooks

    #if DEBUG
    /// `LL_PAGE=next|previous[@<seconds>][x<turns>]` — page turns without a
    /// finger, the first `seconds` (default 2) after the pager opens and the
    /// rest as far apart: the settle animation, the editor swap and the
    /// landing, for screenshots and checks a headless run can make — and,
    /// with `x10`, a swipe bench whose every turn logs its `PageTurnTrace`.
    private func consumePageHook() async {
        guard let raw = ProcessInfo.processInfo.environment["LL_PAGE"] else { return }
        var spec = raw
        var turns = 1
        if let x = spec.lastIndex(of: "x"), let count = Int(spec[spec.index(after: x)...]) {
            turns = max(1, count)
            spec = String(spec[..<x])
        }
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        let delta = parts[0] == "previous" ? -1 : 1
        let delay = parts.count > 1 ? (Double(parts[1]) ?? 2) : 2
        for _ in 0..<turns {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, transition == nil, let target = neighbourID(delta),
                  containerWidth > 0 else { return }
            let width = containerWidth
            lastDirection = delta
            beginTrace(to: target)
            withAnimation(.easeOut(duration: 0.22)) {
                drag = CGSize(width: delta > 0 ? -width : width, height: 0)
            } completion: {
                beginMove(to: target)
            }
        }
    }
    #endif

    // MARK: - Look-ahead

    /// Makes the neighbours' opening pictures, the way the last page turned
    /// first, one at a time on the look-ahead lane (below every render a
    /// person is waiting on): a still's graded opening render, a preview's
    /// decoded picture. What is kept is only ever the pages either side; a
    /// movie keeps the grid's thumbnail as its poster.
    private func startLookAhead() {
        lookAheadTask?.cancel()
        let ids = [neighbourID(lastDirection), neighbourID(-lastDirection)].compactMap { $0 }
        // A movie's asset is opened ahead too (its page mounts a player;
        // the grid's thumbnail stays its poster).
        for id in ids {
            guard let capture = model.capture(id: id), case .movie(let url) = model.editorAsset(for: capture) else { continue }
            Task { await VideoAssetCache.prepare(url) }
        }
        lookAhead = lookAhead.filter { ids.contains($0.key) }
        let jobs: [(id: UUID, work: EditorLookAheadJob)] = ids
            .filter { lookAhead[$0] == nil }
            .compactMap { id in model.capture(id: id).flatMap(model.editorLookAheadJob(for:)).map { (id, $0) } }
        guard !jobs.isEmpty else { return }
        lookAheadTask = Task {
            for job in jobs {
                let started = CACurrentMediaTime()
                let made = await MediaWorkQueue.lookAhead.run { job.work.make() }
                guard !Task.isCancelled else { return }
                if let made, let picture = made {
                    lookAhead[job.id] = picture
                    LLog("pager: look-ahead made \(model.capture(id: job.id)?.displayTitle ?? "?") in \(Int(((CACurrentMediaTime() - started) * 1000).rounded())) ms")
                }
            }
        }
    }

    // MARK: - The turn's trace

    /// A swipe was let go toward `target`: its trace opens, and the main
    /// thread's frame gaps are watched until the new picture is up.
    private func beginTrace(to target: UUID) {
        PageTurnTrace.begin(model.capture(id: target)?.displayTitle ?? target.uuidString)
        stallProbe.start()
    }

    /// What arrived, in a word or two — what the turn's time is read against.
    private static func traceKind(_ capture: AppModel.CaptureProject, asset: EditorAsset) -> String {
        let type = asset.url.pathExtension.uppercased()
        switch asset {
        case .preview: return "preview"
        case .movie: return "video \(type)"
        case .still:
            if capture.isPhotoCapture { return "photo \(type)" }
            return "interval \(capture.sourceFileNames.count) frames \(type)"
        }
    }

    // MARK: - Posters

    private func poster(for id: UUID) -> Poster {
        let capture = model.capture(id: id)
        let url = capture.flatMap(model.thumbnailURL(for:))
        // A preview's `poster.jpg` is a finished, already-graded picture —
        // the tile's rule (`ProjectThumbnailView.isPoster`): decoded as the
        // image it is and never graded a second time (it was, 2026-09-25).
        let isPoster = url?.lastPathComponent == ProjectFileRegistry.posterName
        let grade = isPoster ? nil : capture.map(model.photoGrade(for:))
        return Poster(
            id: id,
            url: url,
            kind: isPoster ? .image : (capture.map(model.mediaKind(for:)) ?? .image),
            grade: grade.flatMap { $0.isIdentity ? nil : $0 },
            picture: lookAhead[id])
    }

    /// A poster fitted where the editor's picture is — the pane the editor
    /// published, on its anchor — so a page turn hands over in place.
    @ViewBuilder private func posterView(_ poster: Poster) -> some View {
        if let frame = pagingState?.paneFrame, frame.width > 0, frame.height > 0 {
            EditorPosterImage(
                url: poster.url, kind: poster.kind, grade: poster.grade, picture: poster.picture,
                alignment: pagingState?.anchor == .top ? .top : .center)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }
    }

    // MARK: - The ⓘ sheet

    /// The project's panel in its inspector dress — tags, info, metadata,
    /// and what came of the project — over the picture. Its New clip and
    /// Delete are the pager's to see through: the flow rises over the tabs,
    /// and a deleted project has no editor left to show.
    @ViewBuilder private var infoSheet: some View {
        if let capture = model.capture(id: currentID) {
            NavigationStack {
                GalleryPreviewPanel(
                    capture: capture,
                    onOpen: {},
                    onNewClip: {
                        showsInfo = false
                        leave(.newClip(capture.id))
                    },
                    onDelete: {
                        showsInfo = false
                        delete(capture)
                    },
                    style: .inspector
                )
                .navigationTitle(capture.displayTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsInfo = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func delete(_ capture: AppModel.CaptureProject) {
        let landing = neighbourID(1) ?? neighbourID(-1)
        do {
            try model.deleteCapture(capture)
            leave(.back(landing))
        } catch {
            deleteFailure = error.localizedDescription
        }
    }
}

/// Frame gaps on the main thread while a page turns: a display link that
/// notes how late each frame was. `stop()` answers with the longest gap and
/// how many frames were over 50 ms — the stalls a swipe feels.
@MainActor final class MainThreadStallProbe: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var longest: CFTimeInterval = 0
    /// When the longest gap began — so the trace can say which phase it
    /// fell in.
    private var longestFrom: CFTimeInterval = 0
    private var late = 0

    func start() {
        _ = stop()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // A steady rate whatever the screen is doing: the system slows an
        // idle link (nothing animating between the slide and the picture),
        // and a slowed link reads as a stall that never happened.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 {
            let gap = link.timestamp - last
            if gap > longest {
                longest = gap
                longestFrom = last
            }
            if gap > 0.05 { late += 1 }
        }
        last = link.timestamp
    }

    /// Stops watching; nil when it was not.
    func stop() -> String? {
        guard let link else { return nil }
        link.invalidate()
        self.link = nil
        var summary = "longest stall \(Int((longest * 1000).rounded())) ms, \(late) frame(s) over 50 ms"
        if longest > 0.05, let phase = PageTurnTrace.phase(at: longestFrom) { summary += " (from \(phase))" }
        last = 0
        longest = 0
        longestFrom = 0
        late = 0
        return summary
    }
}

/// The poster's picture: the grid's thumbnail (already decoded for the tile
/// that was just tapped, or its neighbours), fitted, on black.
private struct EditorPosterImage: View {
    var url: URL?
    var kind: AppModel.MediaKind
    var grade: PhotoGrade?
    /// The editor's own opening picture, when the look-ahead made it.
    var picture: CGImage? = nil
    /// Where the picture rests in the pane — the editor's anchor.
    var alignment: Alignment
    @State private var image: Image?

    var body: some View {
        ZStack(alignment: alignment) {
            Color.black
            if let picture {
                Image(decorative: picture, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else if let image {
                image
                    .resizable()
                    .scaledToFit()
            }
        }
        .task(id: "\(url?.path ?? "-")|\(grade?.cacheToken ?? "-")") {
            guard picture == nil, let url else { return }
            if let loaded = await ProjectThumbnailCache.shared.thumbnail(for: url, kind: kind, grade: grade) {
                image = loaded
            }
        }
    }
}
#endif
