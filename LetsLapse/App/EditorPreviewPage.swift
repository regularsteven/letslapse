import ImageIO
import LetsLapseKit
import SwiftUI

// MARK: - The editor on a device without the picture (2026-09-25)
//
// docs/connected-asset-states-plan.md §4.1–4.2. Steven's brief: the app
// looks and behaves the same whatever a device holds — only capabilities
// change. A project whose originals are on PicPlace (a preview pulled from
// it, or originals removed to free space) opens where the editor would: the
// editor's own chrome and layouts — the phone's foot, the iPad's floating
// row, the rail — over the project's graded preview, with the tab pill and
// the six main buttons drawn greyed in place and still tappable. A tap asks
// whether to fetch what is missing, with its size: *Download and Continue*
// or *Stay as Is*. When the picture arrives while the page is up — by that
// prompt, the line's Download, or the project card — the real editor takes
// the page, on the page and panel that was tapped.
//
// Its own view, built from the editor's components, never the editor on a
// poster: the editor has write paths that assume a source (the persist net,
// the white migration that persisted a D65 guess on 2026-09-23, as-shot
// reads), and this page has none. The layout numbers below are the
// editors' own (`PhotoViewerView` / `VideoEditorView`); change them there
// and here together.

#if os(macOS)
/// The preview page in a window of its own on the Mac — the project screen's
/// hero opens its editor in a window, and a preview's editor is this page
/// (the Gallery's item view hosts it in place instead).
struct PreviewEditorWindowRequest: Hashable, Codable {
    let captureID: UUID
    let title: String
}
#endif

struct EditorPreviewPage: View {
    @EnvironmentObject private var model: AppModel

    let captureID: UUID
    /// A host that embeds the editor (the Mac's item view, the iOS pager)
    /// asks it to leave through here; `onExit` is where it then goes.
    var exitRequest: EditorExitRequest? = nil
    var onExit: (() -> Void)? = nil
    /// The iOS pager's context — clear preview across pages, the ⓘ door.
    var paging: EditorPagingContext? = nil

    var body: some View {
        EditorPreviewPageContent(
            picplace: model.picplace, holdings: model.holdingsStore, captureID: captureID,
            exitRequest: exitRequest, onExit: onExit, paging: paging)
    }
}

private struct EditorPreviewPageContent: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var picplace: PicPlaceController
    /// The status card's sizes and the arrival check move with it.
    @ObservedObject var holdings: ProjectHoldingsStore
    @Environment(\.dismiss) private var dismiss

    let captureID: UUID
    var exitRequest: EditorExitRequest?
    var onExit: (() -> Void)?
    var paging: EditorPagingContext?

    /// The preview on screen: `poster.jpg` as it is (already graded — never
    /// graded again), else the tile's own picture.
    @State private var pictureImage: Image?
    @State private var pictureAspect: CGFloat?
    /// True once the picture has loaded or is known not to exist, so the
    /// pager's settled poster can go.
    @State private var pictureSettled = false
    @State private var shootSeconds: Double?
    @State private var clearPreviewState: Bool?
    @State private var containerSize: CGSize = .zero
    @State private var phoneFootHeight: CGFloat = 0
    @State private var phoneFootMeasured = false
    /// The just-in-time question on screen.
    @State private var prompt: PagePrompt?
    /// Where the editor lands once the picture is here — the page and panel
    /// a *Download and Continue* was pressed for.
    @State private var resume: EditorPageRequest?
    /// The real editor, once the picture arrived while this page was up.
    @State private var arrived: EditorAsset?

    private var capture: AppModel.CaptureProject? { model.capture(id: captureID) }
    private var isClearPreview: Bool { clearPreviewState ?? paging?.startsClear ?? false }

    var body: some View {
        if let arrived {
            switch arrived {
            case .still(let url):
                PhotoViewerView(captureID: captureID, url: url, exitRequest: exitRequest, onExit: onExit, paging: paging)
            case .movie(let url):
                VideoEditorView(captureID: captureID, url: url, exitRequest: exitRequest, onExit: onExit, paging: paging)
            case .preview:
                EmptyView()
            }
        } else {
            page
        }
    }

    // MARK: - The page

    private var page: some View {
        GeometryReader { proxy in
            Group {
                switch layout(for: proxy.size) {
                case .phone: phoneBody(in: proxy.size)
                case .floating: if isClearPreview { clearBody } else { floatingBody(in: proxy.size) }
                case .rail: if isClearPreview { clearBody } else { railBody(in: proxy.size) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: proxy.size, initial: true) { _, size in containerSize = size }
        }
        .background(background)
        #if os(iOS)
        .preferredColorScheme(.dark)
        .statusBarHidden(isClearPreview)
        .onChange(of: isClearPreview) { _, clear in paging?.onClearPreviewChanged(clear) }
        #endif
        .task(id: captureID) { await loadPicture() }
        .task(id: captureID) { await loadShootLength() }
        .onAppear {
            model.loadHoldings(for: [captureID])
            // PicPlace's own list of the project's files: whether it holds
            // the originals, and their size by its count.
            picplace.refreshProject(captureID)
            checkArrival()
            #if DEBUG
            consumePromptHook()
            #endif
        }
        .onChange(of: exitRequest) { _, request in if request != nil { leave() } }
        .onChange(of: holdings.revision) { _, _ in checkArrival() }
        .onChange(of: isDownloading) { _, downloading in if !downloading { checkArrival() } }
        .alert(prompt?.content.title ?? "", isPresented: Binding(
            get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { prompt in
            promptActions(prompt)
        } message: { prompt in
            Text(prompt.content.message)
        }
    }

    private var background: some View {
        #if os(iOS)
        Color.black.ignoresSafeArea()
        #else
        LL.screenBackground
        #endif
    }

    // MARK: Layouts — the editors' three dressings

    private enum Layout { case phone, floating, rail }

    /// `PhotoViewerView.editorLayout(for:)`: a landscape iPad floats, anything
    /// else 500 pt wide takes the rail, the rest is the phone; the Mac is
    /// always the rail.
    private func layout(for size: CGSize) -> Layout {
        #if os(macOS)
        return .rail
        #else
        if size.width >= 900, size.width > size.height { return .floating }
        if size.width >= 500 { return .rail }
        return .phone
        #endif
    }

    /// The touch chrome row's reach — 12 pt, the 36 pt disc, 12 pt.
    private static let touchChromeHeight: CGFloat = 60

    private func railWidth(in totalWidth: CGFloat) -> CGFloat {
        #if os(macOS)
        return 330
        #else
        return min(340, totalWidth * 0.42)
        #endif
    }

    private var accent: Color {
        #if os(iOS)
        return LL.amber
        #else
        return LL.accent
        #endif
    }

    /// The phone (2a): the picture fitted into the room between the chrome
    /// row and the foot and pressed to the top; the foot is the status card
    /// over the six greyed buttons, where the timeline card and the buttons
    /// would be.
    private func phoneBody(in container: CGSize) -> some View {
        let clear = isClearPreview
        let top: CGFloat = clear ? 0 : Self.touchChromeHeight
        let bottom: CGFloat = clear ? 0 : phoneFootHeight
        return ZStack(alignment: .bottom) {
            picturePane(anchor: .top)
                .padding(.top, top)
                .padding(.bottom, bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(phoneFootMeasured ? .easeInOut(duration: 0.22) : nil, value: bottom)
            if !clear {
                touchChrome
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                VStack(spacing: 0) {
                    statusCard(style: .dark)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    EditorGroupBar(selection: lockedGroup, nonNeutral: nonNeutralGroups,
                                   style: .phone, accent: accent, locked: true)
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: PreviewFootHeightKey.self, value: proxy.size.height)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onPreferenceChange(PreviewFootHeightKey.self) { height in
            phoneFootHeight = height
            if height > 0 { phoneFootMeasured = true }
        }
    }

    /// The iPad in landscape (5a): the picture top-left at its aspect, the
    /// chrome over it, the status card where the strip's capsule sits and
    /// the buttons pill beside it.
    private func floatingBody(in container: CGSize) -> some View {
        let size = Self.fit(aspect: pictureAspect ?? 4 / 3, in: container)
        return ZStack(alignment: .topLeading) {
            Color.black
            picturePane(anchor: .center)
                .frame(width: size.width, height: size.height)
            touchChrome
                .frame(maxWidth: .infinity)
            HStack(alignment: .bottom, spacing: 18) {
                statusCard(style: .dark)
                    .frame(maxWidth: .infinity)
                EditorGroupBar(selection: lockedGroup, nonNeutral: nonNeutralGroups,
                               style: .padPill, accent: accent, locked: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// The rail (3b — the Mac, a landscape iPhone, iPad portrait): the
    /// picture beside the rail's tab bar, the buttons card and the status
    /// card, all greyed but the card.
    private func railBody(in container: CGSize) -> some View {
        HStack(spacing: 0) {
            picturePane(anchor: .center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { railChrome }
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    RailTabBar(selection: lockedTab, tabs: tabs, accent: accent,
                               onAccent: railOnAccent, locked: lockedTabs)
                    EditorGroupBar(selection: lockedGroup, nonNeutral: nonNeutralGroups,
                                   style: .macCard, accent: accent, locked: true)
                    statusCard(style: railCardStyle)
                }
                .padding(.top, 14)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .frame(width: railWidth(in: container.width))
        }
    }

    private var clearBody: some View {
        picturePane(anchor: .center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func fit(aspect: Double, in room: CGSize) -> CGSize {
        let ratio = max(aspect, 0.01)
        let byHeight = CGSize(width: room.height * ratio, height: room.height)
        if byHeight.width <= room.width { return byHeight }
        return CGSize(width: room.width, height: room.width / ratio)
    }

    private var railOnAccent: Color {
        #if os(iOS)
        return .black
        #else
        return .white
        #endif
    }

    private var railCardStyle: CardStyle {
        #if os(macOS)
        return .light
        #else
        return .dark
        #endif
    }

    // MARK: Chrome

    /// Back · ⓘ leading, the tab pill trailing — `PhotoViewerView.touchChrome`.
    @ViewBuilder private var touchChrome: some View {
        #if os(iOS)
        HStack(spacing: 8) {
            chromeDisc(systemImage: "chevron.left", label: "Back") { leave() }
            infoButton
            Spacer(minLength: 8)
            EditorTabPill(selection: lockedTab, tabs: tabs, accent: accent, locked: lockedTabs)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        #endif
    }

    /// The rail layout's chrome over the picture on a touch device: Back
    /// leading, ⓘ trailing. The Mac's item view has its own Back.
    @ViewBuilder private var railChrome: some View {
        #if os(iOS)
        HStack {
            chromeDisc(systemImage: "chevron.left", label: "Back") { leave() }
            Spacer(minLength: 0)
            infoButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        #endif
    }

    @ViewBuilder private var infoButton: some View {
        if let onInfo = paging?.onInfo {
            chromeDisc(systemImage: "info.circle", label: "Project info", action: onInfo)
        }
    }

    private func chromeDisc(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
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

    // MARK: The picture

    private func picturePane(anchor: PhotoZoomGeometry.Anchor) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: anchor == .top ? .top : .center) {
                Color.black
                if let pictureImage {
                    pictureImage
                        .resizable()
                        .scaledToFit()
                } else if pictureSettled {
                    // No preview was ever made (a project whose files went
                    // missing before it reached PicPlace).
                    Image(systemName: "photo")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.white.opacity(0.25))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { pictureTapped() }
            // The pager's side of the page: a swipe across the picture walks
            // to the neighbour, and its poster is fitted where this pane is.
            .preference(
                key: EditorPagingStateKey.self,
                value: EditorPagingState(
                    canPage: paging != nil && prompt == nil,
                    paneFrame: proxy.frame(in: .named(EditorPagingState.hostSpace)),
                    anchor: anchor,
                    hasPicture: pictureSettled,
                    captureID: captureID))
            .accessibilityElement()
            .accessibilityLabel("Preview of \(capture?.displayTitle ?? "the project")")
            .accessibilityAddTraits(.isImage)
        }
    }

    /// One tap: clear preview on or off, as in the editor (iOS).
    private func pictureTapped() {
        #if os(iOS)
        withAnimation(.easeInOut(duration: 0.22)) { clearPreviewState = !isClearPreview }
        #endif
    }

    private func loadPicture() async {
        PageTurnTrace.mark("mount")
        guard let capture else {
            pictureSettled = true
            if let paging { paging.onPicture(captureID) } else { PageTurnTrace.finish("picture") }
            return
        }
        if let poster = model.previewPictureURL(for: capture) {
            // The pager's look-ahead decoded it already when this page was
            // a swipe away (`PreviewPictureCache`).
            let decoded: CGImage?
            if let cached = PreviewPictureCache.cached(poster) {
                decoded = cached
                PageTurnTrace.annotate("picture made ahead")
            } else {
                decoded = await Task.detached(priority: .userInitiated) {
                    PreviewPictureCache.decode(poster)
                }.value
            }
            PageTurnTrace.mark("decode")
            if let decoded {
                pictureImage = Image(decorative: decoded, scale: 1)
                pictureAspect = CGFloat(decoded.width) / CGFloat(max(1, decoded.height))
            }
        } else if let url = model.thumbnailURL(for: capture) {
            // No poster: the tile's own picture, graded the way the tile is.
            let grade = model.photoGrade(for: capture)
            pictureImage = await ProjectThumbnailCache.shared.thumbnail(
                for: url, kind: model.mediaKind(for: capture), grade: grade.isIdentity ? nil : grade)
            if let size = await Task.detached(priority: .utility, operation: { MediaGeometry.stillDisplaySize(url: url) }).value,
               size.height > 0 {
                pictureAspect = size.width / size.height
            }
        }
        pictureSettled = true
        if let paging { paging.onPicture(captureID) } else { PageTurnTrace.finish("picture") }
    }

    // MARK: What the project is

    private var frameCount: Int {
        capture?.sourceFileNames.filter { !$0.hasSuffix(".json") }.count ?? 0
    }

    /// The pages the project's editor has — a movie's Editor and Text, a
    /// still's Masks too, a shoot's Frames.
    private var tabs: [RailTab] {
        guard let capture else { return [.editor] }
        if capture.kind == .video { return [.editor, .text] }
        return frameCount > 1 ? [.editor, .text, .frames, .masks] : [.editor, .text, .masks]
    }

    /// Every page but the Editor needs the originals (plan T2).
    private var lockedTabs: Set<RailTab> { Set(tabs.filter { $0 != .editor }) }

    /// The dots say which groups hold an edit — the grade is a record, and
    /// it is here even when the pixels are not.
    private var nonNeutralGroups: Set<EditorGroup> {
        guard let capture else { return [] }
        let adjustments = model.photoAdjustments(for: capture)
        let keyframed = model.gradeTimeline(for: capture).keyframedFields
        let whiteBalance = model.whiteBalanceSource(for: capture)
        let state = model.presetState(for: capture)
        return Set(EditorGroup.allCases.filter {
            !PhotoAdjustmentsPanel.isNeutral(
                $0, adjustments: adjustments, keyframedFields: keyframed,
                whiteBalanceSource: whiteBalance, presetState: state)
        })
    }

    private var marqueeKind: EditorMarqueeBadge.Kind? {
        guard let capture else { return nil }
        if capture.kind == .video { return .video }
        return frameCount > 1 ? .interval : nil
    }

    private func loadShootLength() async {
        guard let capture, capture.kind == .photos, !capture.isPhotoCapture else { return }
        let frames = model.sourceFrameURLs(for: capture)
        guard frames.count > 1 else { return }
        shootSeconds = await Task.detached(priority: .utility) {
            FrameTimestamps.load(besideFrames: frames)?.elapsedSeconds(coveringExactly: frames.count)?.last
        }.value
    }

    // MARK: The greyed controls

    /// The six buttons' selection: never set — a tap asks instead.
    private var lockedGroup: Binding<EditorGroup?> {
        Binding(get: { nil }, set: { group in if let group { ask(.group(group)) } })
    }

    /// The tab pill's selection: the Editor page, always; the others ask.
    private var lockedTab: Binding<RailTab> {
        Binding(get: { .editor }, set: { tab in if tab != .editor { ask(.tab(tab)) } })
    }

    /// What was tapped, for the prompt's words and for where the editor
    /// lands once the picture is here.
    enum Tapped: Equatable {
        case group(EditorGroup)
        case tab(RailTab)
        case line

        var subject: String {
            switch self {
            case .group(let group): return group.title
            case .tab(let tab): return "The \(tab.rawValue) page"
            case .line: return "Editing"
            }
        }

        func landing(_ id: UUID) -> EditorPageRequest {
            switch self {
            case .group(let group): return EditorPageRequest(captureID: id, page: .editor, group: group)
            case .tab(let tab): return EditorPageRequest(captureID: id, page: tab)
            case .line: return EditorPageRequest(captureID: id, page: .editor)
            }
        }
    }

    private func ask(_ tapped: Tapped) {
        guard let capture else { return }
        guard let shortfall = model.availability(of: .pixelEdit, for: capture).shortfall else {
            // Here after all (a download landed between frames).
            checkArrival()
            return
        }
        prompt = PagePrompt(tapped: tapped, content: FetchPromptContent(
            subject: tapped.subject, shortfall: shortfall, noun: noun(for: shortfall),
            offer: picplace.fetchOffer(for: capture, shortfall: shortfall)))
    }

    @ViewBuilder private func promptActions(_ prompt: PagePrompt) -> some View {
        switch prompt.content.offer {
        case .download:
            Button("Download and Continue") { download(prompt.content.shortfall, landing: prompt.tapped.landing(captureID)) }
            Button("Stay as Is", role: .cancel) {}
        case .downloading:
            Button("Continue When Ready") { resume = prompt.tapped.landing(captureID) }
            Button("Stay as Is", role: .cancel) {}
        case .signIn:
            Button("Sign In") { picplace.signIn() }
            Button("Stay as Is", role: .cancel) {}
        case .connect, .notUploaded, .unavailable:
            Button("OK", role: .cancel) {}
        }
    }

    private func download(_ shortfall: ProjectHoldings.Shortfall, landing: EditorPageRequest) {
        guard let capture else { return }
        if picplace.fetch(capture, shortfall: shortfall) { resume = landing }
    }

    /// "the originals", "the rest of the originals" — a Photo capture's is
    /// its full-size photo.
    private func noun(for shortfall: ProjectHoldings.Shortfall?) -> FetchNoun {
        .for(shortfall, isPhotoCapture: capture?.isPhotoCapture == true)
    }

    // MARK: The status card — why the controls are grey

    private enum CardStyle { case dark, light }

    private struct Status {
        var glyph: StatusGlyph
        var title: String
        var caption: String
        var fraction: Double?
        var action: CardAction?
    }

    private enum CardAction {
        case download, stop, signIn

        var label: String {
            switch self {
            case .download: return "Download"
            case .stop: return "Stop"
            case .signIn: return "Sign In"
            }
        }
    }

    private var isDownloading: Bool {
        picplace.progress[captureID]?.phase == .downloading
    }

    private var status: Status {
        let holdings = model.cachedHoldings(for: captureID)
        let shortfall = holdings.flatMap { $0.shortfall(for: $0.pictureNeed) }
        let noun = noun(for: shortfall)
        if let progress = picplace.progress[captureID], progress.phase == .downloading {
            let caption = progress.filesTotal == 0
                ? "Asking PicPlace for the files…"
                : progress.bytesDone == 0
                    ? "\(LLFormat.bytes(progress.bytesTotal)) to download"
                    : "\(LLFormat.bytes(progress.bytesDone)) of \(LLFormat.bytes(progress.bytesTotal))"
                    + (resume?.group.map { " · \($0.title) opens when \(noun.pronoun) \(noun.verb) here" } ?? "")
            return Status(glyph: .cloud(.downloading), title: "Downloading \(noun.text)",
                          caption: caption, fraction: progress.fraction, action: .stop)
        }
        let tier = holdings?.tier ?? .preview
        // The pill's glyphs (`StatusGlyph`): the originals on PicPlace are the
        // grey camera; not on PicPlace either, the slashed one.
        var glyph: StatusGlyph = tier == .originals ? .asset(.originals, .here) : .asset(.originals, .there)
        guard let capture else { return Status(glyph: glyph, title: tier.label, caption: "", action: nil) }
        let offer = shortfall.map { picplace.fetchOffer(for: capture, shortfall: $0) } ?? .download
        let subject = noun.capitalized
        let verb = noun.isPlural ? "are" : "is"
        var caption: String
        var action: CardAction?
        switch offer {
        case .download, .downloading:
            caption = "Editing needs \(noun.text) — on PicPlace" + (shortfall.map { " · \($0.sizeText)" } ?? "")
            action = picplace.canSync ? .download : nil
        case .signIn:
            caption = "\(subject) \(verb) on PicPlace — sign in to download \(noun.object)"
            action = .signIn
        case .connect:
            caption = "\(subject) \(verb) on PicPlace — connect this library in Settings to download \(noun.object)"
        case .notUploaded(let device):
            caption = "\(subject) \(verb) only on \(device ?? "the device that made \(noun.object)") for now"
            glyph = .asset(.originals, .nowhere)
        case .unavailable:
            caption = "\(subject) \(verb)n't on \(PicPlaceController.deviceWord)"
            // Not on PicPlace either: no cloud to promise — the tile's pill
            // says the same with the same glyph.
            return Status(glyph: .asset(.originals, .nowhere), title: tier.label, caption: caption, action: nil)
        }
        // A download that failed says why, on the line that offers it again.
        if let error = picplace.records[model.originID(of: capture)]?.lastError,
           picplace.records[model.originID(of: capture)]?.failedHeavyOnly == true {
            caption = error
        }
        return Status(glyph: glyph, title: tier.label, caption: caption, action: action)
    }

    private func statusCard(style: CardStyle) -> some View {
        let status = status
        let secondary = style == .dark ? EditorPalette.secondaryOnDark : EditorPalette.secondaryOnLight
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            if let marqueeKind, style == .dark {
                EditorMarqueeBadge(kind: marqueeKind, durationSeconds: shootSeconds,
                                   frameCount: marqueeKind == .interval ? frameCount : nil)
            }
            HStack(alignment: .top, spacing: 10) {
                StatusGlyphView(glyph: status.glyph, size: 13, surface: style == .dark ? .photo : .adaptive)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(style == .dark ? Color.white : Color.primary)
                    Text(status.caption)
                        .font(.system(size: 11.5))
                        .foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let fraction = status.fraction {
                        ProgressView(value: fraction)
                            .tint(accent)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
                if let action = status.action {
                    Button(action.label) { perform(action) }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if style == .dark {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color.black.opacity(0.6))
                }
            } else {
                shape.fill(LL.cardBackground)
            }
        }
        .contentShape(shape)
        // The whole card asks too — the reason is the way in.
        .onTapGesture { if status.action == nil || status.action == .download { ask(.line) } }
        .accessibilityElement(children: .combine)
    }

    private func perform(_ action: CardAction) {
        guard let capture else { return }
        switch action {
        case .download:
            let availability = model.availability(of: .pixelEdit, for: capture)
            guard let shortfall = availability.shortfall else { checkArrival(); return }
            download(shortfall, landing: resume ?? Tapped.line.landing(captureID))
        case .stop:
            picplace.cancelSync(captureID)
            resume = nil
        case .signIn:
            picplace.signIn()
        }
    }

    // MARK: Arrival and leaving

    /// The picture is here: the editor takes the page, on the page and the
    /// panel that was asked for. Whoever brought the files — the prompt, the
    /// line, the project card — the page becomes what it stood in for.
    private func checkArrival() {
        guard arrived == nil, !isDownloading, let capture, let asset = model.editorAsset(for: capture) else { return }
        model.requestedEditorPage = resume ?? EditorPageRequest(captureID: captureID, page: .editor)
        withAnimation(.easeInOut(duration: 0.2)) { arrived = asset }
    }

    private func leave() {
        if let onExit { onExit() } else { dismiss() }
    }

    #if DEBUG
    /// `LL_PREVIEW_PROMPT=<group>|text|frames|masks|line[:download]` —
    /// raises the just-in-time prompt on the first preview page, for
    /// screenshots; `:download` then presses *Download and Continue* two
    /// seconds later, as a finger would (the bench, on a Simulator no
    /// headless run can tap).
    private func consumePromptHook() {
        guard let hook = ProcessInfo.processInfo.environment["LL_PREVIEW_PROMPT"]?.lowercased(),
              !Self.promptHookConsumed else { return }
        Self.promptHookConsumed = true
        let parts = hook.split(separator: ":").map(String.init)
        let raw = parts.first ?? "line"
        let presses = parts.dropFirst().contains("download")
        let tapped: Tapped
        if let group = EditorGroup.allCases.first(where: { $0.title.lowercased() == raw }) {
            tapped = .group(group)
        } else if let tab = RailTab.allCases.first(where: { $0.rawValue.lowercased() == raw }) {
            tapped = .tab(tab)
        } else {
            tapped = .line
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            ask(tapped)
            guard presses else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let asked = prompt, asked.content.offer == .download else {
                    LLog("LL_PREVIEW_PROMPT: nothing to download (\(String(describing: prompt?.content.offer)))")
                    return
                }
                prompt = nil
                download(asked.content.shortfall, landing: asked.tapped.landing(captureID))
                LLog("LL_PREVIEW_PROMPT: pressed Download and Continue for \(asked.tapped.subject)")
            }
        }
    }

    private static var promptHookConsumed = false
    #endif
}

/// The page's question: the shared words (`FetchPromptContent`), and what
/// was tapped — where the editor lands once the picture is here.
private struct PagePrompt: Identifiable {
    let id = UUID()
    var tapped: EditorPreviewPageContent.Tapped
    var content: FetchPromptContent
}

private struct PreviewFootHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
