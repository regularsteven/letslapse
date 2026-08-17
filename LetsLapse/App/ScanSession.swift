import Foundation
import LetsLapseKit

/// One page of a scan: the two files it exists as, and everything the sidecar
/// recorded about the moment it was taken.
///
/// Two URLs rather than one because correction is non-destructive and the UI
/// has to be able to say so — `viewable` is what the app shows and exports,
/// `original` is the photograph as shot, and the viewer's Corrected/Original
/// toggle is nothing more than a choice between them. When a page has never
/// been corrected the two are the same file, which is exactly what "the
/// original is always there" means.
struct ScanPage: Identifiable, Equatable, Sendable {
    /// 1-based, matching the file names and the number on the tile.
    let number: Int
    let viewable: URL
    let original: URL
    let isCorrected: Bool
    /// The corners the detector had at the moment the shutter was asked for.
    /// Its presence is the answer to "can this page be rectified at all?" — a
    /// page shot over a table has none and never will.
    let rectangle: NormalizedQuad?
    let capturedAt: Date?
    /// Exposure time in seconds.
    let shutter: Double?
    let iso: Double?
    let ev: Double?

    var id: Int { number }
    var hasRectangle: Bool { rectangle != nil }
}

/// A whole scanner run, as the Scans tab presents it: a document with pages,
/// a stock, a length and a correction state — no frame counts, no blend, no
/// playback.
struct ScanSession: Identifiable, Equatable, Sendable {
    /// The capture project this session is. Same id, because a scan *is* a
    /// project on disk — only its presentation is different.
    let id: UUID
    let createdAt: Date
    let paper: PerspectiveAspect
    /// The name the operator gave this scan, if they gave it one. A scan is a
    /// document, and a document people keep is one they can call something.
    let name: String?
    let pages: [ScanPage]
    /// First shutter to last, or nil when the shoot wrote no sidecar to
    /// measure it with.
    let durationSeconds: Double?
    /// The document groups this sitting produced, already resolved against the
    /// pages that are really here (`ScanDocumentStore.resolve`) — so it is
    /// never empty for a session with pages, and a session that predates
    /// grouping has exactly one entry holding all of them.
    let documents: [ScanDocument]

    // MARK: - Documents

    /// Whether this session is more than one document, and therefore whether
    /// the detail screen shows section headers at all. One group is drawn as
    /// the flat grid it has always been.
    var hasDocumentGroups: Bool { documents.count > 1 }

    /// Each group with its pages resolved, in document order.
    var documentSections: [ScanDocumentSection] {
        let byNumber = Dictionary(uniqueKeysWithValues: pages.map { ($0.number, $0) })
        return documents.map { document in
            ScanDocumentSection(
                document: document,
                pages: document.pageIndices.compactMap { byNumber[$0] })
        }
    }

    /// The group a page belongs to — what the "move to…" menu greys out, and
    /// what an export scope resolves a loose selection through.
    func document(containing pageNumber: Int) -> ScanDocument? {
        documents.first { $0.pageIndices.contains(pageNumber) }
    }

    // MARK: - Counts

    var pageCount: Int { pages.count }
    var detectedCount: Int { pages.filter(\.hasRectangle).count }
    var correctedCount: Int { pages.filter(\.isCorrected).count }

    /// Pages that could still be corrected and haven't been. The test is "has
    /// corners and isn't rectified", never "isn't rectified": a page shot with
    /// nothing flat in view can never be corrected, and the looser test would
    /// leave the Correct prompt on screen for ever on any set with one
    /// table-top page in it.
    var correctablePages: [ScanPage] {
        pages.filter { $0.hasRectangle && !$0.isCorrected }
    }

    /// What the list card's correction pill shows. `nil` means no page in this
    /// session ever recorded a rectangle — and then the card shows nothing at
    /// all, rather than a greyed-out indicator claiming work is outstanding.
    enum Correction: Equatable {
        case complete
        case partial(corrected: Int, detected: Int)
    }

    var correction: Correction? {
        guard detectedCount > 0 else { return nil }
        return correctedCount >= detectedCount
            ? .complete
            : .partial(corrected: correctedCount, detected: detectedCount)
    }

    // MARK: - Copy

    /// "8 pages" — the document metaphor throughout; never "frames".
    var pageCountLine: String {
        pageCount == 1 ? "1 page" : "\(pageCount) pages"
    }

    /// "16 Aug · 21:21" on the list card, or the name if there is one.
    var listTitle: String {
        name ?? (createdAt.formatted(.dateTime.day().month(.abbreviated)) + " · " + timeLine)
    }

    /// "16 Aug, 21:21" as the detail screen's large title, or the name.
    var detailTitle: String {
        name ?? (createdAt.formatted(.dateTime.day().month(.abbreviated)) + ", " + timeLine)
    }

    /// The date line, always — the subtitle keeps it once a name has taken the
    /// title, because when a scan was made is the thing people actually search
    /// their memory by.
    var dateLine: String {
        createdAt.formatted(.dateTime.day().month(.abbreviated)) + ", " + timeLine
    }

    private var timeLine: String {
        createdAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// "3 min 12 s" / "41 s". Nil when there is no sidecar, so the caller can
    /// leave the fact out rather than print a zero.
    var durationLine: String? {
        guard let durationSeconds, durationSeconds >= 1 else { return nil }
        let whole = Int(durationSeconds.rounded())
        if whole < 60 { return "\(whole) s" }
        return String(format: "%d min %02d s", whole / 60, whole % 60)
    }

    /// "3 documents" — only said where there is more than one, because "1
    /// document" on a session that never grouped anything is a distinction
    /// nobody asked for.
    var documentCountLine: String? {
        guard hasDocumentGroups else { return nil }
        return "\(documents.count) documents"
    }

    /// "8 pages · 3 documents · A4 · 3 min 12 s" — the detail subtitle.
    var subtitleLine: String {
        [name == nil ? nil : dateLine, pageCountLine, documentCountLine, paper.label, durationLine]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The sentence beside the detail header's ring. Says what the *detector*
    /// found first, because that is what decides whether anything can be
    /// corrected at all.
    var correctionLine: String {
        guard detectedCount > 0 else { return "No rectangle data" }
        let detected = "Rectangle on \(detectedCount) of \(pageCount)"
        return correctedCount == 0
            ? detected + " · not yet corrected"
            : detected + " · \(correctedCount) corrected"
    }

    /// How full the header's ring is: corrected ÷ **detected**, so it never
    /// claims progress on pages that can never be corrected.
    var correctionProgress: Double {
        guard detectedCount > 0 else { return 0 }
        return min(1, Double(correctedCount) / Double(detectedCount))
    }

    // MARK: - Shape

    /// Width ÷ height for a page of this session's stock — the natural display
    /// ratio, so an A4 session is a row of tall pages and a 4×6 session a row
    /// of wide ones. Never a square crop.
    ///
    /// `PerspectiveAspect.portraitRatio` is deliberately not the answer here:
    /// it states the stock in portrait form, which is right for the corrector
    /// (which reads the quad's own orientation) and wrong for a thumbnail
    /// strip, where a 4×6 *print* is landscape by convention. `.auto` has no
    /// stock at all, so the first detected quad's apparent proportions stand
    /// in, and a session with no geometry falls back to 3:4.
    var pageAspectRatio: Double {
        switch paper {
        case .a4: return 1 / 2.0.squareRoot()
        case .letter: return 8.5 / 11
        case .fourBySix: return 6.0 / 4
        case .square: return 1
        case .auto:
            let quad = pages.compactMap(\.rectangle).first
            guard let ratio = quad?.apparentAspectRatio, ratio.isFinite, ratio > 0 else {
                return 0.75
            }
            return min(max(ratio, 0.4), 2.5)
        }
    }

    // MARK: - Loading

    /// Everything a load needs, gathered on the main actor so the walk itself
    /// doesn't have to touch the model.
    struct Request: Sendable {
        let id: UUID
        let createdAt: Date
        let paper: PerspectiveAspect
        let name: String?
        let sourceFolder: URL
        /// The page numbers this session actually has, ascending — parsed from
        /// the registered file names rather than counted.
        ///
        /// **A count would be wrong the moment a page is deleted.** Pages keep
        /// their numbers when one is thrown away (see
        /// `AppModel.deleteScanPage`), so a set of twelve missing its third is
        /// 1, 2, 4…12 — and walking `1...11` would hide the last page while
        /// showing a gap that isn't there.
        let frameNumbers: [Int]
        /// The project's registered frames, in order — the last-resort file for
        /// a pose whose processed sibling is missing.
        let frameURLs: [URL]
    }

    /// Resolves a session off the main actor: it stats up to four candidates
    /// per page and reads the sidecar, and the Scans list asks for every
    /// session on screen at once.
    static func load(_ request: Request) -> ScanSession {
        let sidecar = try? FrameTimestamps.load(
            from: request.sourceFolder.appendingPathComponent(FrameTimestamps.fileName))
        // Keyed by the 1-based page number the files use; the sidecar counts
        // frames from 0.
        var entries: [Int: FrameTimestamps.Entry] = [:]
        for entry in sidecar?.entries ?? [] { entries[entry.frame + 1] = entry }

        var pages: [ScanPage] = []
        for (offset, number) in request.frameNumbers.enumerated() {
            let base = String(format: "frame-%05d", number)
            let corrected = request.sourceFolder.appendingPathComponent(
                "\(base)\(PerspectiveCorrector.correctedSuffix).heic")
            // A corrected page written before the orientation fix is not a
            // corrected page: its quad was applied to the unrotated sensor
            // read-out, so it is a quarter-turned near-full-frame crop wearing
            // a rotation tag. Counting it as done would leave the set showing
            // those files for ever, because the Correct action only offers
            // itself for pages that aren't corrected yet. Treated as
            // uncorrected, it shows the original, the prompt comes back, and
            // running it overwrites the file properly.
            let isCorrected = FileManager.default.fileExists(atPath: corrected.path)
                && !PerspectiveCorrector.isSupersededCorrection(at: corrected)
            let original = ["heic", "jpg", "jpeg"]
                .map { request.sourceFolder.appendingPathComponent("\(base).\($0)") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
                ?? request.frameURLs[safe: offset]
            guard let original else { continue }
            let entry = entries[number]
            pages.append(ScanPage(
                number: number,
                viewable: isCorrected ? corrected : original,
                original: original,
                isCorrected: isCorrected,
                rectangle: entry?.rectangle,
                capturedAt: entry?.captureTime,
                shutter: entry?.shutter,
                iso: entry?.iso,
                ev: entry?.ev))
        }

        let stamps = pages.compactMap(\.capturedAt)
        let duration: Double? = {
            guard let first = stamps.min(), let last = stamps.max(), last > first else { return nil }
            return last.timeIntervalSince(first)
        }()

        // Read here rather than on the main actor with the rest of the request:
        // it is one more small file in the same folder the walk is already
        // stat-ing, and resolving it needs the page numbers this walk just
        // proved are really on disk.
        let documents = ScanDocumentStore.resolve(
            ScanDocumentStore.load(from: request.sourceFolder),
            pageNumbers: pages.map(\.number))

        return ScanSession(
            id: request.id,
            createdAt: request.createdAt,
            paper: request.paper,
            name: request.name,
            pages: pages,
            durationSeconds: duration,
            documents: documents)
    }
}

// MARK: - Grouping

/// The Scans list's date sections: Today, Yesterday, then a month per group.
///
/// Sessions rather than a flat page feed, because each scanner run is a
/// discrete document — a flat feed mixes pages from different ones, which is
/// the mistake the whole tab exists to correct.
struct ScanSessionGroup: Identifiable {
    let title: String
    let sessions: [ScanSession]

    var id: String { title }

    static func group(_ sessions: [ScanSession], calendar: Calendar = .current, now: Date = Date())
        -> [ScanSessionGroup]
    {
        var order: [String] = []
        var buckets: [String: [ScanSession]] = [:]
        for session in sessions.sorted(by: { $0.createdAt > $1.createdAt }) {
            let title = heading(for: session.createdAt, calendar: calendar, now: now)
            if buckets[title] == nil {
                order.append(title)
                buckets[title] = []
            }
            buckets[title]?.append(session)
        }
        return order.map { ScanSessionGroup(title: $0, sessions: buckets[$0] ?? []) }
    }

    private static func heading(for date: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        // Within this year the year is noise; outside it, it is the only thing
        // that distinguishes two Augusts.
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.month(.wide))
            : date.formatted(.dateTime.month(.wide).year())
    }
}
