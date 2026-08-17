import SwiftUI
import LetsLapseKit

/// The Scans tab: every scanner run in the library, newest first, grouped by
/// the day it was shot.
///
/// A scanner run is a *document*, and this tab is the whole of that claim made
/// structural. There is no blend here, no clip length, no play button and no
/// speed — a set of pages does not play back — and the pages are never mixed
/// into one flat feed, because two documents shot an hour apart are two
/// documents. Projects keeps the timelapse mental model and stops carrying
/// scans at all (`AppModel.libraryCaptures`); the one route back to it is
/// "View as timelapse" on the export sheet.
struct ScansView: View {
    @EnvironmentObject var model: AppModel
    /// Owned by ContentView so the tab bar can pop this stack to the list.
    @Binding var path: [UUID]

    @State private var sessions: [ScanSession] = []
    @State private var sessionPendingDelete: ScanSession?
    @State private var deletionFailure: String?
    /// Bumped on appear so returning from a session — where pages may have
    /// been corrected — reloads the cards rather than showing the state the
    /// list was left in.
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Scans")
                        .font(.system(size: 34, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                        .padding(.top, 8)
                        .padding(.bottom, 14)

                    if sessions.isEmpty {
                        ScansEmptyState { model.requestedTab = .create }
                    } else {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            LLSectionHeader(group.title)
                                .padding(.top, index == 0 ? 0 : 22)
                                .padding(.bottom, 10)
                            ForEach(group.sessions) { session in
                                Button {
                                    path.append(session.id)
                                } label: {
                                    ScanSessionCard(session: session)
                                }
                                .buttonStyle(.plain)
                                // The card is one big button, so the swipe has
                                // to claim the drag ahead of it — the same
                                // arrangement the blended-clip rows use.
                                .swipeToDelete(cornerRadius: 16) {
                                    sessionPendingDelete = session
                                }
                                .padding(.bottom, 14)
                            }
                        }
                    }

                    // Clearance for the floating tab bar.
                    Color.clear.frame(height: 82)
                }
                .padding(.horizontal, 16)
            }
            .background(LL.screenBackground)
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #else
            .navigationTitle("Scans")
            #endif
            .navigationDestination(for: UUID.self) { id in
                ScanDetailView(sessionID: id)
            }
        }
        .task(id: "\(model.scanSessions.map(\.id.uuidString).joined())|\(reloadToken)") {
            sessions = await loadSessions()
        }
        .alert(item: $sessionPendingDelete) { session in
            Alert(
                title: Text("Delete this scan?"),
                message: Text("\(session.pageCountLine) and everything corrected from them. "
                              + "This can't be undone."),
                primaryButton: .destructive(Text("Delete")) { delete(session) },
                secondaryButton: .cancel())
        }
        .alert(
            "Couldn't delete",
            isPresented: Binding(
                get: { deletionFailure != nil },
                set: { if !$0 { deletionFailure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionFailure ?? "")
        }
        // **The cards are a snapshot of the disk, and the disk changes under
        // them.** A scan is registered and its correction starts in the same
        // breath, so the list's first read of a new session sees twelve
        // uncorrected pages — and without this it would keep saying "0 of 12"
        // until something else happened to reload it. `scanCorrections` empties
        // when a pass finishes, which is exactly when the files it wrote are
        // all there to be counted.
        .onChange(of: model.scanCorrections) { _ in
            // Tiles that failed to decode while the GPU was busy correcting
            // twelve 12-megapixel pages are remembered as failures and never
            // retried; a reload has to clear that memory or the card comes back
            // with the same blank strip it had before.
            ProjectThumbnailCache.shared.invalidate(urls: [])
            reloadToken += 1
        }
        .onAppear {
            reloadToken += 1
            consumeDetailRequest(model.requestedScanDetailID)
        }
        .onReceive(model.$requestedScanDetailID) { consumeDetailRequest($0) }
    }

    /// Opens the session a finished run (or a deep link) asked for.
    ///
    /// `requested` arrives as a parameter rather than being re-read off the
    /// model, for the reason `ProjectsView` documents at length: `@Published`
    /// emits on *will*Set, so during the emission the property still holds the
    /// old value and a re-read drops the request.
    private func consumeDetailRequest(_ requested: UUID?) {
        guard let requested else { return }
        guard model.captures.contains(where: { $0.id == requested }) else { return }
        if path != [requested] { path = [requested] }
        DispatchQueue.main.async {
            if model.requestedScanDetailID == requested {
                model.requestedScanDetailID = nil
            }
        }
    }

    /// Removes a whole scan — its folder, its pages and its place in the
    /// library. Confirmed first: a scan is minutes of someone's hands and there
    /// is no undo behind this.
    private func delete(_ session: ScanSession) {
        guard let capture = model.captures.first(where: { $0.id == session.id }) else { return }
        do {
            try model.deleteCapture(capture)
            sessions.removeAll { $0.id == session.id }
            model.invalidateScannerCache(for: session.id)
        } catch {
            deletionFailure = error.localizedDescription
        }
    }

    private var groups: [ScanSessionGroup] {
        ScanSessionGroup.group(sessions)
    }

    /// Gathers what each session needs on the main actor, then does the stat
    /// walk off it — a library of long sets is a few hundred file probes, and
    /// none of them belong in a view body.
    private func loadSessions() async -> [ScanSession] {
        let requests = model.scanSessions.map { model.scanSessionRequest(for: $0) }
        return await Task.detached(priority: .userInitiated) {
            requests.map(ScanSession.load)
        }.value
    }
}

// MARK: - Session card

/// One document: when it was shot, how long it took, what stock it was on,
/// whether its pages have been rectified — and the pages themselves, at the
/// stock's own proportions.
private struct ScanSessionCard: View {
    let session: ScanSession

    /// The strip is a fixed height and the width follows the ratio, so an A4
    /// set reads as a row of tall pages and a 4×6 set as a row of wide ones.
    private static let stripHeight: CGFloat = 92
    /// Four pages, then a counter. Past four the strip would be scrolling
    /// rather than summarising.
    private static let stripLimit = 4

    private var pageWidth: CGFloat {
        (Self.stripHeight * session.pageAspectRatio).rounded()
    }

    /// How many pages the strip shows, and how wide the counter beside them
    /// gets.
    ///
    /// Two different things are allowed to overflow, and only one of them is.
    /// A strip whose pages are *all* on it may run past the card's edge — a
    /// 4×6 session's pages are 138pt each and three of them don't fit, and
    /// clipping the third costs nothing, because nothing is being miscounted.
    /// A counter must be whole: "+4" cut in half reads as a broken tile rather
    /// than as four more pages. So pages give way to the counter, and the
    /// counter itself takes whatever is left rather than a page's full width.
    private func strip(in width: CGFloat) -> (pages: Int, counterWidth: CGFloat) {
        let maximum = min(Self.stripLimit, session.pageCount)
        guard width > 0, pageWidth > 0, session.pageCount > maximum else { return (maximum, 0) }
        for count in stride(from: maximum, through: 1, by: -1) {
            let used = CGFloat(count) * pageWidth + CGFloat(count - 1) * 6
            let remaining = width - used - 6
            if remaining >= Self.minimumCounterWidth {
                return (count, min(pageWidth, remaining))
            }
        }
        return (1, Self.minimumCounterWidth)
    }

    /// Enough for "+12" at 13pt semibold, which is what the tile has to carry.
    private static let minimumCounterWidth: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.listTitle)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.primary)
                    Text([session.pageCountLine, session.durationLine]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if let correction = session.correction {
                        ScanCorrectionPill(correction: correction)
                    }
                    ScanPaperPill(paper: session.paper)
                }
            }

            // Measured rather than laid out freely, for two reasons. A row of
            // fixed-width tiles propagates its own width upwards, and a 4×6
            // session's 138pt pages would push the whole card — title and all
            // — off the screen. And the counter is only true if it is whole:
            // "+4" cut in half by the card's edge reads as a broken tile, not
            // as four more pages, so the page count gives way to it.
            GeometryReader { proxy in
                let layout = strip(in: proxy.size.width)
                HStack(spacing: 6) {
                    ForEach(session.pages.prefix(layout.pages)) { page in
                        ProjectThumbnailView(url: page.viewable, kind: .image, cornerRadius: 6)
                            .frame(width: pageWidth, height: Self.stripHeight)
                    }
                    if session.pageCount > layout.pages {
                        Text("+\(session.pageCount - layout.pages)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: layout.counterWidth, height: Self.stripHeight)
                            .background(
                                LL.screenBackground,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .frame(width: proxy.size.width, alignment: .leading)
                .clipped()
            }
            .frame(height: Self.stripHeight)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .llCard()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(session.listTitle), \(session.pageCountLine), \(session.paper.label)")
    }
}

// MARK: - Correction indicator

/// The counted pill on a session card.
///
/// Accent, not amber. `LL.amber` is a token for dark surfaces — over imagery
/// and over `LL.ink` — and on a white card it measures 1.9:1 against the
/// background, which is a smudge rather than a tick. The one rule behind every
/// correction marker in this tab: **amber over imagery and over ink, accent on
/// white.**
struct ScanCorrectionPill: View {
    let correction: ScanSession.Correction

    var body: some View {
        switch correction {
        case .complete:
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                Text("Corrected")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(LL.accent)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(LL.accent.opacity(0.12), in: Capsule())
            .accessibilityLabel("All pages corrected")
        case .partial(let corrected, let detected):
            HStack(spacing: 5) {
                ScanCorrectionRing(
                    progress: detected > 0 ? Double(corrected) / Double(detected) : 0)
                    .frame(width: 12, height: 12)
                Text("\(corrected) of \(detected)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 7)
            .padding(.trailing, 9)
            .frame(height: 22)
            .background(LL.screenBackground, in: Capsule())
            .accessibilityLabel("\(corrected) of \(detected) pages corrected")
        }
    }
}

/// The ring itself, shared by the card pill and the detail header. Its fill is
/// corrected ÷ **detected**, never ÷ pages, so it cannot claim progress on
/// pages that have no corners to rectify from.
struct ScanCorrectionRing: View {
    let progress: Double
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.28), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(LL.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

/// The stock the session was shot on. Always shown, including "Auto" — the
/// aspect the pages are drawn at is the first thing someone checks when a
/// corrected page looks the wrong shape.
struct ScanPaperPill: View {
    let paper: PerspectiveAspect

    var body: some View {
        Text(paper.label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(LL.screenBackground, in: Capsule())
            .accessibilityLabel("Paper \(paper.label)")
    }
}

// MARK: - Empty state

/// Points at Create, because that is where a scan starts — Scanner is a mode
/// of the camera, not something this tab can begin on its own.
private struct ScansEmptyState: View {
    var onOpenCreate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No scans yet")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 16)
            Text("Start a scan from the Create tab. Scanner fires when the scene settles and keeps each page as its own file.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Button(action: onOpenCreate) {
                HStack(spacing: 7) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 15))
                    Text("Open Create")
                        .font(.system(size: 13.5, weight: .semibold))
                }
                .foregroundStyle(LL.accent)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(LL.accent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 28)
        .llCard(cornerRadius: 18)
    }
}
