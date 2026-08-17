import SwiftUI
import LetsLapseKit

/// One page, full screen, with the rest of the document a swipe away.
///
/// The Corrected/Original toggle is the whole promise made visible: the
/// photograph is always there, so "corrected" is a *view* rather than a state
/// that can be lost. Everything else on the screen answers a question the
/// export depends on — is this the rectified page or the photograph, did the
/// detector have geometry at all, and what was the exposure.
struct ScanPageViewer: View {
    let session: ScanSession
    let startPage: Int
    var onRecorrect: (ScanPage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var index: Int
    /// Per page, because a page with no corrected file has nothing to show for
    /// "Corrected" and must not inherit the last page's choice.
    @State private var showsOriginal = false
    @State private var shareItem: ScanShareItem?

    init(session: ScanSession, startPage: Int, onRecorrect: @escaping (ScanPage) -> Void) {
        self.session = session
        self.startPage = startPage
        self.onRecorrect = onRecorrect
        _index = State(initialValue: session.pages.firstIndex { $0.number == startPage } ?? 0)
    }

    private var page: ScanPage? {
        session.pages.indices.contains(index) ? session.pages[index] : nil
    }

    /// The file on screen: the toggle's answer, and never a promise the page
    /// can't keep — an uncorrected page has only the photograph.
    private var shownURL: URL? {
        guard let page else { return nil }
        return showsOriginal || !page.isCorrected ? page.original : page.viewable
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pager
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if let page { controls(page) }
            }
        }
        #if os(iOS)
        .statusBarHidden()
        #endif
        .onChange(of: index) { _ in showsOriginal = false }
        .sheet(item: $shareItem) { item in
            ScanShareSheet(urls: [item.url])
        }
    }

    // MARK: - Image

    @ViewBuilder private var pager: some View {
        #if os(iOS)
        TabView(selection: $index) {
            ForEach(Array(session.pages.enumerated()), id: \.offset) { offset, item in
                ScanZoomableImage(
                    url: showsOriginal || !item.isCorrected ? item.original : item.viewable)
                    .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        #else
        if let url = shownURL {
            ScanZoomableImage(url: url)
                .overlay(alignment: .bottom) { macStepper }
        }
        #endif
    }

    #if os(macOS)
    /// The Mac has no page-swipe, so the set is walked with buttons — and the
    /// same arrow keys the rest of the app uses.
    private var macStepper: some View {
        HStack(spacing: 14) {
            Button("Previous") { index = max(index - 1, 0) }
                .disabled(index == 0)
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next") { index = min(index + 1, session.pages.count - 1) }
                .disabled(index >= session.pages.count - 1)
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .padding(.bottom, 150)
    }
    #endif

    // MARK: - Chrome

    private var topBar: some View {
        HStack(alignment: .top) {
            Button("Done") { dismiss() }
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Page \(page?.number ?? index + 1) of \(session.pageCount)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                if let stamp = page?.capturedAt {
                    Text(stamp.formatted(
                        .dateTime.day().month(.abbreviated).hour().minute().second()))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black.opacity(0.35))
    }

    private func controls(_ page: ScanPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if page.isCorrected {
                correctedToggle(page)
            } else {
                ScanViewerChips(page: page, paper: session.paper)
            }

            if showsOriginal || !page.isCorrected {
                Text("The file as shot — kept for ever. Correction never touches it.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 12)
            } else {
                exposureRow(page)
                    .padding(.top, 12)
            }

            HStack(spacing: 8) {
                Button {
                    onRecorrect(page)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "perspective")
                            .font(.system(size: 17))
                            .foregroundStyle(correctIsPrimary(page) ? LL.ink : LL.amber)
                        Text(correctLabel(page))
                            .font(.system(size: 14, weight: correctIsPrimary(page) ? .bold : .semibold))
                            .foregroundStyle(correctIsPrimary(page) ? LL.ink : .white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        correctIsPrimary(page) ? AnyShapeStyle(LL.amber)
                            : AnyShapeStyle(.white.opacity(0.16)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    if let url = shownURL { shareItem = ScanShareItem(url: url) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(
                            .white.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share this page")
            }
            .padding(.top, 14)

            pageIndicator
                .padding(.top, 12)
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Full strength by a third of the way down, not at the bottom: a page
        // is very nearly white, and a scrim that only reaches 74% at the last
        // pixel leaves the exposure labels (white at 45%) sitting on paper.
        .background(
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.74), location: 0.34),
                    .init(color: .black.opacity(0.74), location: 1),
                ],
                startPoint: .top, endPoint: .bottom))
    }

    /// Amber-filled only when correcting is the thing to do next — on a
    /// corrected page shown corrected, re-correcting is a repair rather than
    /// the headline, so it steps back to a quiet chip.
    private func correctIsPrimary(_ page: ScanPage) -> Bool {
        !page.isCorrected || showsOriginal
    }

    private func correctLabel(_ page: ScanPage) -> String {
        if !page.isCorrected { return "Correct this page" }
        return showsOriginal ? "Correct from this" : "Re-correct…"
    }

    private func correctedToggle(_ page: ScanPage) -> some View {
        HStack(spacing: 6) {
            toggleHalf(title: "Corrected", isOn: !showsOriginal, glyph: "perspective") {
                showsOriginal = false
            }
            toggleHalf(title: "Original", isOn: showsOriginal, glyph: nil) {
                showsOriginal = true
            }
        }
        .padding(3)
        .frame(width: 200)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func toggleHalf(
        title: String, isOn: Bool, glyph: String?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let glyph, isOn {
                    Image(systemName: glyph)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: isOn ? .bold : .semibold))
            }
            .foregroundStyle(isOn ? LL.ink : .white.opacity(0.75))
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(
                isOn
                    ? AnyShapeStyle(title == "Corrected" ? LL.amber : Color.white.opacity(0.9))
                    : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Monospaced so a column of pages can be compared by eye while swiping.
    private func exposureRow(_ page: ScanPage) -> some View {
        HStack(alignment: .bottom, spacing: 20) {
            if let shutter = page.shutter {
                ScanMetric(label: "SHUTTER", value: Self.shutterLabel(shutter))
            }
            if let iso = page.iso {
                ScanMetric(label: "ISO", value: "\(Int(iso.rounded()))")
            }
            if let ev = page.ev {
                ScanMetric(label: "EV", value: String(format: "%.1f", ev)
                    .replacingOccurrences(of: "-", with: "\u{2212}"))
            }
            ScanMetric(label: "PAPER", value: session.paper.label)
        }
    }

    /// Dots up to eight pages; past that they stop being countable and the
    /// position is spelled out instead, as the interval viewer does.
    @ViewBuilder private var pageIndicator: some View {
        if session.pageCount <= 8 {
            HStack(spacing: 6) {
                ForEach(0..<session.pageCount, id: \.self) { dot in
                    Circle()
                        .fill(dot == index ? Color.white : Color.white.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            Text("\(index + 1) / \(session.pageCount)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity)
        }
    }

    /// "1/125", or "1.6s" once the shutter is long enough that a fraction is
    /// the harder thing to read.
    static func shutterLabel(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 { return String(format: "%.1fs", seconds) }
        return "1/\(Int((1 / seconds).rounded()))"
    }
}

/// The two chips on an uncorrected page: what it is, and whether the detector
/// left anything to correct it with.
private struct ScanViewerChips: View {
    let page: ScanPage
    let paper: PerspectiveAspect

    var body: some View {
        HStack(spacing: 8) {
            Text("Original · \(paper.label)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(.white.opacity(0.14), in: Capsule())
            Text(page.hasRectangle ? "Rectangle detected" : "No rectangle at capture")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(page.hasRectangle ? LL.amber : .white.opacity(0.55))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    page.hasRectangle ? LL.amber.opacity(0.18) : Color.white.opacity(0.1),
                    in: Capsule())
        }
    }
}

private struct ScanMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospaced())
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Zoomable image

/// Pinch to zoom, drag to pan once zoomed, double-tap to fit.
///
/// **The pan gesture is attached only while zoomed in, and that is the whole
/// trick.** Gating it in the `updating` closure — which is what this did first
/// — does not work: a SwiftUI `DragGesture` *claims* the single-finger pan the
/// moment it is attached, and a closure that decides to do nothing has already
/// taken the touch off the `TabView`'s scroll view underneath. The symptom is
/// oddly specific and was reported exactly: pages would only turn under a **two
/// finger** swipe, because two touches are the one thing a `DragGesture` does
/// not match, so only those reached the pager.
///
/// So at fit scale the gesture is masked off entirely and a one-finger swipe is
/// the pager's, as it is in every photo viewer on the platform. Zoomed in it is
/// masked back on, where claiming the drag is exactly right — the finger is
/// panning the page, and the pager must not steal it.
struct ScanZoomableImage: View {
    let url: URL
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    private var effectiveScale: CGFloat { max(1, scale * pinch) }
    /// Whether this page owns the one-finger drag. `.subviews` rather than
    /// `.none` when it doesn't: the mask governs this modifier's gesture, and
    /// there is no reason to switch off anything nested inside the image.
    private var panMask: GestureMask { effectiveScale > 1 ? .all : .subviews }

    var body: some View {
        GeometryReader { proxy in
            ProjectPreviewImage(url: url, background: AnyShapeStyle(Color.black))
                .scaleEffect(effectiveScale)
                .offset(
                    x: offset.width + (effectiveScale > 1 ? drag.width : 0),
                    y: offset.height + (effectiveScale > 1 ? drag.height : 0))
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .updating($pinch) { value, state, _ in
                            guard value.isFinite, value > 0 else { return }
                            state = value
                        }
                        .onEnded { value in
                            guard value.isFinite, value > 0 else { return }
                            scale = min(max(scale * value, 1), 6)
                            if scale == 1 { offset = .zero }
                        })
                .simultaneousGesture(
                    DragGesture()
                        .updating($drag) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            offset.width += value.translation.width
                            offset.height += value.translation.height
                        },
                    // The gate. See the type's note: masking the gesture off is
                    // what hands a one-finger swipe back to the pager, and no
                    // amount of checking inside the closures can do it.
                    including: panMask)
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        if scale > 1 {
                            scale = 1
                            offset = .zero
                        } else {
                            scale = 2.5
                        }
                    }
                }
                .onChange(of: url) { _ in
                    scale = 1
                    offset = .zero
                }
        }
    }
}

// MARK: - Sharing

struct ScanShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// One share surface for a page, a selection or a whole export, so the two
/// platforms' differences live in exactly one place.
struct ScanShareSheet: View {
    let urls: [URL]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: urls.count == 1 ? "doc" : "folder")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(urls.count == 1
                ? urls[0].lastPathComponent
                : "\(urls.count) files")
                .font(.headline)
                .multilineTextAlignment(.center)
            #if os(iOS)
            if urls.count == 1, let url = urls.first {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .background(
                    LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ShareLink(items: urls) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .background(
                    LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            #else
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .background(
                LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            #endif
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 340)
        #endif
    }
}
