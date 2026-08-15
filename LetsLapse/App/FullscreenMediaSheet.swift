import AVFoundation
import AVKit
import SwiftUI

/// One thing the fullscreen player can show.
///
/// Every in-app playback surface routes through this: a source clip, a rendered
/// version, an interval shoot played as motion, or a still. The case decides
/// which player the sheet builds; the sheet's chrome is the same either way.
enum FullscreenContent: Identifiable, Equatable {
    /// A movie file. `grade` is the owning project's colour grade, applied live
    /// through an `AVMutableVideoComposition` so playback matches the graded
    /// card without writing a baked copy. Pass nil for a file that already
    /// carries its grade — every rendered version does.
    case video(url: URL, grade: PhotoGrade?)
    /// A recording that was written as several segments, played as one
    /// timeline. The segments are stitched into an in-memory
    /// `AVMutableComposition` at playback time — nothing is exported and
    /// nothing is written to disk.
    case videoSequence(urls: [URL], grade: PhotoGrade?)
    /// An interval shoot played straight from its frames, at `fps`, without
    /// rendering a version first.
    case intervalMotion(frames: [URL], fps: Double)
    /// A still.
    case photo(url: URL)

    var id: String {
        switch self {
        case .video(let url, _):
            return "video:\(url.path)"
        case .videoSequence(let urls, _):
            return "sequence:\(urls.count):\(urls.first?.path ?? "-")"
        case .photo(let url):
            return "photo:\(url.path)"
        case .intervalMotion(let frames, let fps):
            return "motion:\(frames.count)@\(fps):\(frames.first?.path ?? "-")"
        }
    }

    /// The one file behind this item — what Share hands over. A stitched
    /// sequence and a frame-driven motion preview exist only in memory, so
    /// there is nothing to hand over: sharing the first segment or the first
    /// frame would be sharing something other than what's on screen.
    var shareURL: URL? {
        switch self {
        case .video(let url, _), .photo(let url):
            return url
        case .videoSequence, .intervalMotion:
            return nil
        }
    }
}

/// What to present, and where in it to start.
///
/// `items` is the whole swipeable set — the other clips in the same section, the
/// other versions — and `index` is the one that was tapped. A single item is
/// just a one-element set with no pager.
struct FullscreenMediaRequest: Identifiable, Equatable {
    var items: [FullscreenContent]
    var index: Int
    /// The project these items belong to, when they belong to one. Two things
    /// hang off it: a `.photo` opens that project's grading editor rather than
    /// the plain viewer, and `.intervalMotion` frames play through its colour
    /// grade. nil means "no project context" — which is what a finished version
    /// wants, since its grade is already baked into the file.
    var captureID: UUID?
    var title: String

    init(
        items: [FullscreenContent],
        index: Int = 0,
        captureID: UUID? = nil,
        title: String = ""
    ) {
        self.items = items
        self.index = items.indices.contains(index) ? index : 0
        self.captureID = captureID
        self.title = title
    }

    init(_ item: FullscreenContent, captureID: UUID? = nil, title: String = "") {
        self.init(items: [item], captureID: captureID, title: title)
    }

    /// Identity includes the starting index so tapping a different clip in the
    /// same set re-presents rather than reusing the open sheet's state.
    var id: String { "\(items.first?.id ?? "-")#\(items.count)#\(index)" }
}

extension View {
    /// Presents the fullscreen player: a cover on iOS/iPadOS, a sheet on macOS
    /// (which has no `fullScreenCover`).
    ///
    /// `model` is passed explicitly rather than relied on to inherit, so the
    /// photo editor inside the sheet can never come up without it.
    @ViewBuilder func fullscreenMedia(
        _ request: Binding<FullscreenMediaRequest?>,
        model: AppModel
    ) -> some View {
        #if os(iOS)
        fullScreenCover(item: request) { request in
            FullscreenMediaSheet(request: request)
                .environmentObject(model)
        }
        #else
        sheet(item: request) { request in
            FullscreenMediaSheet(request: request)
                .environmentObject(model)
                .frame(minWidth: 560, minHeight: 420)
        }
        #endif
    }
}

/// The one in-app player: black, edge to edge, close top-left and share
/// top-right, swipe across to the next item in the same set and down to leave.
struct FullscreenMediaSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: FullscreenMediaRequest

    @State private var selection: Int
    /// Vertical drag-to-dismiss. `fullScreenCover` has no interactive dismiss of
    /// its own, so the gesture is ours; the page swipe stays with the TabView
    /// because we only take over once the drag is clearly vertical.
    @State private var dragOffset: CGFloat = 0

    private let dismissDistance: CGFloat = 120

    init(request: FullscreenMediaRequest) {
        self.request = request
        _selection = State(initialValue: request.index)
    }

    private var current: FullscreenContent? {
        request.items.indices.contains(selection) ? request.items[selection] : request.items.first
    }

    /// The photo editor draws its own Done bar on iOS, so the sheet stands back
    /// rather than stacking a second close button over it. Everywhere else —
    /// and always on macOS, where the editor has no bar of its own — the sheet
    /// owns the chrome.
    private var showsChrome: Bool {
        #if os(iOS)
        if case .photo = current, request.captureID != nil { return false }
        return true
        #else
        return true
        #endif
    }

    /// The grade the project applies to material that carries none of its own —
    /// the interval frames the motion preview plays.
    private var projectGrade: PhotoGrade? {
        guard let captureID = request.captureID,
              let capture = model.captures.first(where: { $0.id == captureID }) else { return nil }
        let grade = model.photoGrade(for: capture)
        return grade.isIdentity ? nil : grade
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pager
                .offset(y: dragOffset)
                .opacity(1 - min(abs(dragOffset) / (dismissDistance * 3), 0.5))
            if showsChrome {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                }
            }
        }
        #if os(iOS)
        .statusBarHidden()
        .simultaneousGesture(dismissDrag)
        #endif
    }

    // MARK: - Pages

    @ViewBuilder private var pager: some View {
        #if os(iOS)
        if request.items.count > 1 {
            TabView(selection: $selection) {
                ForEach(Array(request.items.enumerated()), id: \.offset) { index, item in
                    page(item, isActive: index == selection)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        } else if let current {
            page(current, isActive: true)
        }
        #else
        // macOS has no page style; the arrows in the chrome step instead.
        if let current {
            page(current, isActive: true)
        }
        #endif
    }

    @ViewBuilder private func page(_ content: FullscreenContent, isActive: Bool) -> some View {
        switch content {
        case .video(let url, let grade):
            FullscreenVideoPage(urls: [url], grade: grade, isActive: isActive)
        case .videoSequence(let urls, let grade):
            FullscreenVideoPage(urls: urls, grade: grade, isActive: isActive)
        case .photo(let url):
            photoPage(url)
        case .intervalMotion(let frames, let fps):
            FrameSequencePage(frames: frames, fps: fps, grade: projectGrade, isActive: isActive)
        }
    }

    @ViewBuilder private func photoPage(_ url: URL) -> some View {
        if let captureID = request.captureID {
            PhotoViewerView(captureID: captureID, url: url, title: request.title)
                .environmentObject(model)
        } else {
            // No project context (or a finished version, which carries its own
            // grade): show the file as it is.
            ProjectPreviewImage(url: url, background: AnyShapeStyle(Color.black))
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            circleButton(systemImage: "xmark", label: "Close") { dismiss() }

            Spacer(minLength: 0)

            if request.items.count > 1 {
                #if os(macOS)
                circleButton(systemImage: "chevron.left", label: "Previous") {
                    selection = max(selection - 1, 0)
                }
                .disabled(selection == 0)
                #endif
                Text("\(selection + 1) of \(request.items.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                #if os(macOS)
                circleButton(systemImage: "chevron.right", label: "Next") {
                    selection = min(selection + 1, request.items.count - 1)
                }
                .disabled(selection >= request.items.count - 1)
                #endif
            }

            Spacer(minLength: 0)

            if let url = current?.shareURL {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
            } else {
                // Keeps the close button off-centre-left rather than letting the
                // counter jump when there's nothing to share.
                Color.clear.frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func circleButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    #if os(iOS)
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                // Horizontal drags belong to the pager; only a clearly vertical
                // one moves the sheet.
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                if value.translation.height > dismissDistance,
                   abs(value.translation.height) > abs(value.translation.width) {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { dragOffset = 0 }
                }
            }
    }
    #endif
}

// MARK: - Video page

/// One movie in the fullscreen player: autoplays, loops, and carries its own
/// scrubber once the duration is known.
///
/// `urls` is one file, or the segments of a recording that was written in
/// several pieces — those are stitched into an `AVMutableComposition` in memory,
/// so a segmented shoot plays as the one continuous take it was, with no export
/// and nothing written to disk.
///
/// A non-identity grade is applied at playback time through a video composition,
/// so the clip on screen matches the project's graded card and nothing is
/// written to disk. Only the visible page plays — `isActive` pauses the rest of
/// the pager so swiping doesn't leave three players running.
private struct FullscreenVideoPage: View {
    let urls: [URL]
    var grade: PhotoGrade?
    var isActive: Bool

    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var currentTime: Double = 0
    @State private var isScrubbing = false
    @State private var timeObserver: Any?

    var body: some View {
        ZStack {
            Color.black
            VideoPlayer(player: player)
        }
        .overlay(alignment: .bottom) {
            if duration > 0 {
                scrubber
            }
        }
        .task(id: "\(urls.map(\.path).joined(separator: "|"))|\(grade?.cacheToken ?? "-")") {
            await preparePlayer()
        }
        .onDisappear(perform: teardown)
        .onChange(of: isActive) { active in
            if active { player?.play() } else { player?.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard let item = note.object as? AVPlayerItem,
                  item === player?.currentItem else { return }
            player?.seek(to: .zero)
            if isActive { player?.play() }
        }
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { min(max(currentTime, 0), duration) },
                    set: { currentTime = $0 }
                ),
                in: 0...max(duration, 0.01),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        player?.seek(
                            to: CMTime(seconds: currentTime, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
            )
            .tint(LL.accent)

            HStack {
                Text(timeLabel(currentTime))
                Spacer()
                Text(timeLabel(duration))
            }
            .font(.system(size: 11.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 22)
        .background(.black.opacity(0.35))
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Builds the timeline off the main thread: stitching segments and attaching
    /// a grade both make AVFoundation inspect the assets' tracks synchronously,
    /// which is not something to do while the sheet is animating in. Only the
    /// player item itself is made here — its initialiser is main-actor bound,
    /// and by then the inspection it would trigger has already happened.
    private func preparePlayer() async {
        PlaybackAudioSession.configureAmbient()
        let urls = self.urls
        let grade = self.grade
        let prepared = await Task.detached(priority: .userInitiated) {
            await Self.timeline(for: urls, grade: grade)
        }.value
        guard !Task.isCancelled, let prepared else { return }
        let item = AVPlayerItem(asset: prepared.asset)
        item.videoComposition = prepared.videoComposition

        teardown()
        let player = AVPlayer(playerItem: item)
        // We loop by hand off the end notification, so the player must not
        // pause itself at the last frame.
        player.actionAtItemEnd = .none
        self.player = player
        observe(player)
        if isActive { player.play() }
    }

    /// What a page needs to play: the asset, and the grading pass to run over it.
    private struct PreparedTimeline {
        let asset: AVAsset
        let videoComposition: AVMutableVideoComposition?
    }

    /// The whole off-main half of setting up playback — building the timeline
    /// and, when the project is graded, the composition that grades it.
    nonisolated private static func timeline(
        for urls: [URL],
        grade: PhotoGrade?
    ) async -> PreparedTimeline? {
        guard let asset = await playbackAsset(for: urls) else { return nil }
        guard let grade, !grade.isIdentity else {
            return PreparedTimeline(asset: asset, videoComposition: nil)
        }
        return PreparedTimeline(
            asset: asset, videoComposition: VideoGrader.composition(for: asset, grade: grade))
    }

    /// One file plays as itself; several play as one timeline.
    ///
    /// The composition is playback-only — it references the segments where they
    /// already are, so this costs a track inspection per segment and no copying.
    /// A segment that won't load is skipped rather than failing the whole take:
    /// one unreadable piece shouldn't cost the rest of the recording.
    nonisolated private static func playbackAsset(for urls: [URL]) async -> AVAsset? {
        guard let first = urls.first else { return nil }
        guard urls.count > 1 else { return AVURLAsset(url: first) }

        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        // A ramp shoot's burst segments can be a different resolution from its
        // base ones. One composition video track has one `naturalSize`, which
        // it takes from the first segment inserted — the base, since a run
        // always opens at the base rate — and the rest are fitted to it. That
        // is the right answer here rather than a compromise: a burst format is
        // only ever offered when it matches the base's field of view and aspect
        // ratio (see `DeviceCapabilityMatrix`), so fitting it to the base's
        // frame reproduces the base framing exactly, with no crop or pillarbox.
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration),
                  duration.isValid, duration > .zero else { continue }
            do {
                try await composition.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration), of: asset, at: cursor)
                cursor = cursor + duration
            } catch {
                MediaWorkQueue.note(
                    "sequence playback skipped \(url.lastPathComponent): \(error.localizedDescription)",
                    isError: true)
            }
        }
        // Every segment failed — fall back to the first file on its own rather
        // than handing the player an empty timeline.
        guard cursor > .zero else { return AVURLAsset(url: first) }
        return composition
    }

    private func observe(_ player: AVPlayer) {
        // Weakly, because the player retains the block: teardown removes the
        // observer and breaks the cycle, but a view that goes away without
        // getting there shouldn't strand a player still decoding.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak player] time in
            // The duration isn't known until the item loads, so it's read here
            // rather than up front — this is also what decides whether the
            // scrubber appears at all.
            if let known = player?.currentItem?.duration.seconds,
               known.isFinite, known > 0, known != duration {
                duration = known
            }
            if !isScrubbing, time.seconds.isFinite {
                currentTime = time.seconds
            }
        }
    }

    private func teardown() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player?.pause()
        player = nil
        duration = 0
        currentTime = 0
    }
}

// MARK: - Interval motion page

/// An interval shoot played as motion, straight from its frames — what the
/// shoot will look like as a clip, before spending minutes rendering a version
/// to find out.
///
/// Frames are decoded on the media work queue at a size that can hold frame
/// rate (a full-resolution still, and especially a DNG, cannot) and kept in a
/// bounded cache, with the next few frames pulled in ahead of the playhead. The
/// ticker drops ticks rather than queueing them, so a shoot whose frames decode
/// slower than the frame interval plays at real speed with frames skipped,
/// instead of drifting further behind the longer it runs.
///
/// Frames are shown through the project's grade, like every other surface that
/// shows them; the files are untouched.
private struct FrameSequencePage: View {
    let frames: [URL]
    let fps: Double
    var grade: PhotoGrade?
    var isActive: Bool

    @State private var index = 0
    @State private var isPlaying = true
    @State private var image: CGImage?
    @StateObject private var cache = FrameImageCache()

    /// How far ahead of the playhead to decode.
    private let prefetchDepth = 3
    /// Big enough to look like the shoot on a phone or a Mac window, small
    /// enough to decode inside a frame interval.
    private let decodeSize = 1200

    private var interval: Double { 1.0 / max(fps, 0.5) }

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .overlay(alignment: .bottom) { transport }
        .task(id: "\(frames.count)|\(fps)|\(grade?.cacheToken ?? "-")") { await run() }
        .onChange(of: isActive) { active in
            // Swiping to another page stops the sequence where it is rather
            // than leaving it running behind the one on screen.
            if !active { isPlaying = false }
        }
    }

    // MARK: Playback

    private func run() async {
        guard !frames.isEmpty else { return }
        await show(index)
        // Cancelled with the enclosing `.task` — leaving the sheet stops both
        // the ticker and the decode it was waiting on.
        for await _ in ticker() {
            guard !Task.isCancelled else { break }
            guard isPlaying, isActive else { continue }
            index = (index + 1) % frames.count
            await show(index)
        }
    }

    /// A tick per frame interval, keeping only the newest: if a decode runs
    /// long, the ticks that pass meanwhile collapse into one.
    private func ticker() -> AsyncStream<Void> {
        let interval = self.interval
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    if Task.isCancelled { break }
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func show(_ target: Int) async {
        guard frames.indices.contains(target) else { return }
        if let cached = cache.image(at: target) {
            image = cached
        } else if let decoded = await decode(target) {
            // A stale decode (the playhead moved on, or the user scrubbed)
            // must not replace the frame now on screen.
            if index == target { image = decoded }
        }
        prefetch(after: target)
    }

    private func prefetch(after target: Int) {
        guard frames.count > 1 else { return }
        for offset in 1...prefetchDepth {
            let next = (target + offset) % frames.count
            guard cache.image(at: next) == nil else { continue }
            Task { _ = await decode(next) }
        }
    }

    @discardableResult private func decode(_ target: Int) async -> CGImage? {
        guard frames.indices.contains(target) else { return nil }
        let url = frames[target]
        let grade = self.grade
        let size = decodeSize
        let decoded = await MediaWorkQueue.shared.run { () -> CGImage? in
            if let grade, !grade.isIdentity {
                return PhotoGrader.render(
                    url: url, preset: grade.preset, adjustments: grade.adjustments,
                    maxDimension: CGFloat(size))
            }
            return ProjectThumbnailGenerator.imageThumbnail(for: url, maxPixelSize: size)
        }
        // Outer nil is the queue's "didn't run", inner nil a failed decode.
        guard let decoded, let cgImage = decoded else { return nil }
        cache.store(cgImage, at: target)
        return cgImage
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Text("\(index + 1) / \(frames.count)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)

            Spacer(minLength: 0)

            Text("\(Int(fps.rounded())) fps preview")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 22)
        .background(.black.opacity(0.35))
    }
}

/// A bounded store of decoded frames, so a loop doesn't re-decode the whole
/// shoot on every pass. `NSCache` evicts under memory pressure by itself, which
/// is the behaviour we want on a phone holding a few hundred stills.
private final class FrameImageCache: ObservableObject {
    private let cache = NSCache<NSNumber, CGImageBox>()

    init() {
        cache.countLimit = 120
    }

    func image(at index: Int) -> CGImage? {
        cache.object(forKey: NSNumber(value: index))?.image
    }

    func store(_ image: CGImage, at index: Int) {
        cache.setObject(CGImageBox(image), forKey: NSNumber(value: index))
    }

    /// `NSCache` needs a class; `CGImage` is a CF type, so it travels in a box.
    private final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
}
