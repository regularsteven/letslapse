import SwiftUI
import CoreGraphics
import LetsLapseKit

// "Create shape slideshow": narrow the photos the way the Gallery's Tags rows
// and search do (Apply filters — 2026-09-20, Steven's tram library: tag
// "Tram" alone takes 82 projects into the shape step instead of the whole
// library), pick a shape family from what those registers hold, say how
// strict to be about it (Match), pick the projects (and, where a project has
// several, which instance) in the order they will play (Sort), pick a mode,
// how fast it plays (Timing), then an output size from what the picked
// pictures produce — and render. Every step is one screen in the sheet's
// NavigationStack. Match, Sort and Timing are the 2026-09-11 designs
// (docs/design/iOS/shapemation.builder.{match.*,projects,timing*,output});
// the filters step is code first, its mirror owed.

@MainActor
final class ShapemationBuilder: ObservableObject {
    struct ProjectShapes: Identifiable {
        var id: UUID { capture.id }
        var capture: AppModel.CaptureProject
        var folder: URL
        var register: ShapeRegister
        var representative: ShapeRepresentative

        func shapes(of family: DetectedShape.Family) -> [DetectedShape] {
            register.shapes.filter { $0.family == family }.sorted { $0.nativeDiameterPx > $1.nativeDiameterPx }
        }

        /// The shapes the Match step admits, largest first.
        func shapes(matching match: ShapeMatch) -> [DetectedShape] {
            register.shapes.filter { match.matches($0) }.sorted { $0.nativeDiameterPx > $1.nativeDiameterPx }
        }

        var frameSize: CGSize { register.frameSize }

        /// The register's largest shape, any family — the position filter's anchor.
        var largestShape: DetectedShape? { register.shapes.max { $0.nativeDiameterPx < $1.nativeDiameterPx } }

        var orientation: ShapemationBuilder.AspectFilter {
            let s = frameSize
            return s.width > s.height ? .landscape : (s.width < s.height ? .portrait : .square)
        }

        /// The 3×3 cell (row-major) that holds the largest shape's centre; the middle with no shape.
        var centreCell: Int {
            guard let shape = largestShape, frameSize.width > 0, frameSize.height > 0 else { return 4 }
            let b = shape.bounds(in: frameSize)
            let cx = Double(b.midX) / Double(frameSize.width), cy = Double(b.midY) / Double(frameSize.height)
            return min(2, max(0, Int(cy * 3))) * 3 + min(2, max(0, Int(cx * 3)))
        }
    }

    @Published private(set) var projects: [ProjectShapes] = []
    /// Shapes per family among the projects the filters admit — the family step's rows.
    var familyCounts: [DetectedShape.Family: Int] {
        var counts: [DetectedShape.Family: Int] = [:]
        for project in admittedProjects { for (f, n) in project.register.families() { counts[f, default: 0] += n } }
        return counts
    }

    // MARK: - Apply filters (the first step)

    /// The lit tags: every picked project must carry all of them — the
    /// Gallery sidebar's rule. A change reloads at once.
    @Published var tagSelection: Set<String> = [] {
        didSet { if tagSelection != oldValue { reload() } }
    }
    /// The search field's words, the lists' FTS prefixes. A change reloads
    /// after a short pause, so a word typed letter by letter reads the
    /// registers once.
    @Published var queryText: String = "" {
        didSet { if queryText != oldValue { scheduleReload() } }
    }
    /// The tags present among the photos the filter admits, with how many
    /// carry each — the Gallery's `tagChips` narrowing, counts kept.
    @Published private(set) var presentTags: [(tag: String, count: Int)] = []
    /// How many photo and interval projects the filter admits — the step's
    /// count line, the whole library while nothing is lit.
    @Published private(set) var filteredCount = 0
    /// Every tag's count over the whole library — the "of N" beside a chip once the set is narrowed.
    @Published private(set) var totalTagCounts: [String: Int] = [:]

    // MARK: - Aspect and position (the prototype's Apply filters, review §5a)

    enum AspectFilter: String, CaseIterable {
        case all, landscape, portrait, square
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }
    enum CellFilter: Equatable {
        case column(Int)
        case cell(Int)
    }
    /// The minority orientation pays cover-fit crop on every photo; a filter takes it out.
    @Published var aspectFilter: AspectFilter = .all
    /// A column or a cell of the 3×3 grid the shape's centre must lie in.
    @Published var cellFilter: CellFilter?

    /// Whether a project passes the aspect and position filters (the tags and
    /// the words were the index's business before its register was read).
    func admits(_ project: ProjectShapes) -> Bool {
        if aspectFilter != .all, project.orientation != aspectFilter { return false }
        switch cellFilter {
        case .column(let c)?: return project.centreCell % 3 == c
        case .cell(let cell)?: return project.centreCell == cell
        case nil: return true
        }
    }
    var admittedProjects: [ProjectShapes] { projects.filter(admits) }

    /// The count line: the index's count while only tags and words narrow
    /// (the whole library with nothing lit); the registers' once the aspect or
    /// a position does, since only a register knows where its shape is.
    var shortlistCount: Int {
        aspectFilter == .all && cellFilter == nil ? filteredCount : admittedProjects.count
    }

    /// Projects per 3×3 cell among those the tags, words and aspect admit — the position card's numbers.
    func cellCounts() -> [Int] {
        var counts = [Int](repeating: 0, count: 9)
        for p in projects where aspectFilter == .all || p.orientation == aspectFilter { counts[p.centreCell] += 1 }
        return counts
    }

    func aspectCounts() -> (landscape: Int, portrait: Int, square: Int) {
        var l = 0, p = 0, s = 0
        for project in projects {
            switch project.orientation {
            case .landscape: l += 1
            case .portrait: p += 1
            case .square: s += 1
            case .all: break
            }
        }
        return (l, p, s)
    }

    struct TagChip: Equatable {
        var tag: String
        var label: String
        /// "27", or "8 of 26" once the set is narrowed.
        var count: String
        var total: Int
    }

    /// The chips: the lit tags first (their narrowed count), then every
    /// other tag present, largest volume first.
    func tagChipRows() -> (applied: [TagChip], others: [TagChip]) {
        let narrowed = isFiltered
        var applied: [TagChip] = [], others: [TagChip] = []
        for row in presentTags {
            let total = totalTagCounts[row.tag] ?? row.count
            let count = narrowed && row.count != total ? "\(row.count) of \(total)" : "\(total)"
            let chip = TagChip(tag: row.tag, label: SceneMetadata.label(for: row.tag), count: count, total: total)
            if tagSelection.contains(row.tag) { applied.append(chip) } else { others.append(chip) }
        }
        applied.sort { $0.total == $1.total ? $0.label < $1.label : $0.total > $1.total }
        others.sort { $0.total == $1.total ? $0.label < $1.label : $0.total > $1.total }
        return (applied, others)
    }

    /// The shortlist's own aspect — the contact sheet's cover-fit window.
    func sourceRatioOfShortlist() -> Double {
        let photos = admittedProjects.map { p -> ShapemationLeastCrop.Photo in
            let bounds = p.largestShape?.bounds(in: p.frameSize) ?? CGRect(origin: .zero, size: p.frameSize)
            return ShapemationLeastCrop.Photo(id: p.id, frame: p.frameSize, bounds: bounds, captureOrder: 0)
        }
        return ShapemationLeastCrop.dominantAspect(of: photos) ?? 0.8
    }

    /// Whether a filter narrows the set at all.
    var isFiltered: Bool { !tagSelection.isEmpty || !trimmedQueryText.isEmpty }
    var trimmedQueryText: String { queryText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The filter as the family step's trail: "Tram · Door · “depot” · 82 photos".
    var filterTrail: String {
        guard isFiltered else { return "" }
        var parts = tagSelection.sorted().map { SceneMetadata.label(for: $0) }
        if !trimmedQueryText.isEmpty { parts.append("\u{201C}\(trimmedQueryText)\u{201D}") }
        parts.append("\(filteredCount) photo\(filteredCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    /// The builder's question in the index's terms: the Gallery's own
    /// translation (`ProjectListQuery.indexQuery` — the lit tags every
    /// project must carry, the words as FTS prefixes, no scans), over the
    /// photo and interval projects, which is what a register can be on.
    var projectQuery: LibraryIndex.ProjectQuery {
        var q = ProjectListQuery(sort: .capture, ascending: true, filter: .all,
                                 query: SceneQuery(text: queryText, tags: tagSelection), listsScans: false).indexQuery
        q.categories = [.photo, .interval]
        return q
    }

    private weak var model: AppModel?
    private var loadGeneration = 0
    private var reloadTask: Task<Void, Never>?
    /// captureID → the chosen shape instance.
    @Published var selection: [UUID: UUID] = [:]
    /// Least crop by default (2026-09-20): the stack modes are not the
    /// output model for a real set (docs/shapemation/output-frame.md).
    @Published var mode: ShapemationMode = .leastCrop
    /// The Match step's answer, per family visited. Nil until the step is
    /// seen, when the family's plain membership applies.
    @Published var matches: [DetectedShape.Family: ShapeMatch] = [:]
    /// The order the photos play in. Smallest first by default — the
    /// approach of the brief's §1.
    @Published var sort: ShapemationSort = .smallestFirst
    @Published var timing = ShapemationTiming()
    @Published var thumbnails: [UUID: CGImage] = [:]
    @Published private(set) var loaded = false

    // MARK: - The output frame (docs/shapemation/output-frame.md §6)

    /// The `.frame` mode's framing: the Output step's aspect and long-edge
    /// pickers set its size, the face rows its two keys. 16:9 at 1920 with
    /// the face centred at a quarter of the height until the step says
    /// otherwise. Ignored by the stack modes.
    @Published private(set) var framing = ShapemationFraming.still(
        outputSize: ShapemationFraming.outputSize(aspect: ShapemationBuilder.defaultAspect, longEdge: ShapemationBuilder.defaultLongEdge))
    /// The rect's long edge, shared by both frame modes; its aspect is
    /// `rectRatio` (nil: the Source rect), and `rectSize(for:)` is the size.
    @Published var frameLongEdge: Int = ShapemationBuilder.defaultLongEdge
    /// The end rows read "Same" and follow the start until touched.
    @Published private(set) var endSizeFollowsStart = true
    @Published private(set) var endPlaceFollowsStart = true

    static let defaultAspect = ShapemationFraming.Aspect(16, 9)
    static let defaultLongEdge = 1920
    /// Face size steps of the Output step's steppers: 10–80 % of the height by 5.
    static let faceSizeRange = 10...80
    static let faceSizeStep = 5

    /// The nine-point face picker's cells (the brief's §6 3×3 grid): columns
    /// at a quarter, a half and three quarters of the width, rows at 30, 55
    /// and 80 % of the height. The middle is the framing's default
    /// (0.5, 0.55); the others are drawn in from the thirds' own centres so a
    /// corner face still leaves its photo room to fill the frame.
    static let facePlaces: [CGPoint] = [0.30, 0.55, 0.80].flatMap { y in [0.25, 0.50, 0.75].map { x in CGPoint(x: x, y: y) } }

    var startKey: ShapemationFraming.Key { framing.keys.first ?? .init(at: 0, face: ShapemationFraming.defaultFace, size: ShapemationFraming.defaultSize) }
    var endKey: ShapemationFraming.Key { framing.keys.last ?? startKey }

    func setStartSize(_ size: Double) {
        updateKeys { start, end in start.size = size; if endSizeFollowsStart { end.size = size } }
    }
    func setEndSize(_ size: Double) {
        endSizeFollowsStart = false
        updateKeys { _, end in end.size = size }
    }
    func setStartFace(_ face: CGPoint) {
        updateKeys { start, end in start.face = face; if endPlaceFollowsStart { end.face = face } }
    }
    func setEndFace(_ face: CGPoint) {
        endPlaceFollowsStart = false
        updateKeys { _, end in end.face = face }
    }
    func setEase(_ ease: ShapemationFraming.Ease) {
        framing = ShapemationFraming(outputSize: framing.outputSize, keys: framing.keys, ease: ease, upscaleCap: framing.upscaleCap)
    }

    /// The framing is two keys, the first photo's and the last's; every
    /// change rebuilds it through the Kit's own validation.
    private func updateKeys(_ body: (inout ShapemationFraming.Key, inout ShapemationFraming.Key) -> Void) {
        var start = startKey, end = endKey
        body(&start, &end)
        start.at = 0; end.at = 1
        framing = ShapemationFraming(outputSize: framing.outputSize, keys: [start, end], ease: framing.ease, upscaleCap: framing.upscaleCap)
    }

    /// The framing at the rect in force: the keys and the ease are the
    /// state, the size follows the board's rect.
    func framing(for family: DetectedShape.Family) -> ShapemationFraming {
        ShapemationFraming(outputSize: rectSize(for: family), keys: framing.keys, ease: framing.ease, upscaleCap: framing.upscaleCap)
    }

    // MARK: - The Sequence board (docs/shapemation/prototype-review.md)

    /// The least-crop settings — the cog, the keys, the rejects. The output
    /// size and the sort are filled in from the rect and `sort` on every use
    /// (`settings(for:)`).
    @Published var leastCrop = ShapemationLeastCrop.Settings(
        outputSize: ShapemationFraming.outputSize(aspect: ShapemationBuilder.defaultAspect, longEdge: ShapemationBuilder.defaultLongEdge))
    /// The rect's aspect; nil is Source — the picked photos' own dominant aspect.
    @Published var rectRatio: Double?
    @Published var boardSelection: UUID?
    @Published var boardHover: UUID?
    @Published var showRejected = false
    @Published var showEndHandles = true
    /// Re-render: the record whose members are locked on the board, or nil.
    @Published private(set) var lockedRecord: ShapemationStore.Record?
    /// A locked member's shape as it was rendered, over the register's.
    private var snapshotShapes: [UUID: DetectedShape] = [:]
    var membersLocked: Bool { lockedRecord != nil }

    /// The photos the board works from: the picked items with their capture order.
    func photos(for family: DetectedShape.Family) -> [ShapemationLeastCrop.Photo] {
        items(for: family).enumerated().map { i, item in ShapemationLeastCrop.Photo(item: item, captureOrder: item.captureIndex ?? i) }
    }

    /// The Source rect: the picked photos' dominant aspect, 4:5 for none.
    func sourceRatio(for family: DetectedShape.Family) -> Double {
        ShapemationLeastCrop.dominantAspect(of: photos(for: family)) ?? 0.8
    }
    func rectRatio(for family: DetectedShape.Family) -> Double { rectRatio ?? sourceRatio(for: family) }
    func rectSize(for family: DetectedShape.Family) -> CGSize {
        ShapemationFraming.outputSize(ratio: rectRatio(for: family), longEdge: frameLongEdge)
    }

    /// The settings the board, the plan and the record share.
    func settings(for family: DetectedShape.Family) -> ShapemationLeastCrop.Settings {
        var s = leastCrop
        s.outputSize = rectSize(for: family)
        s.sort = sort
        return s
    }

    func board(for family: DetectedShape.Family) -> ShapemationLeastCrop.Board {
        ShapemationLeastCrop.board(photos(for: family), settings: settings(for: family))
    }

    /// The mean loss the picked set would pay into a rect of `ratio` — the
    /// chips' captions, so a wider rect cannot look cheaper by throwing
    /// pixels to the aspect crop.
    func meanLoss(for family: DetectedShape.Family, ratio: Double) -> Double {
        var s = settings(for: family)
        s.outputSize = ShapemationFraming.outputSize(ratio: ratio, longEdge: frameLongEdge)
        return ShapemationLeastCrop.board(photos(for: family), settings: s).meanLoss
    }

    func setKeyPlace(_ id: UUID, _ place: CGPoint) {
        let zoom = leastCrop.key(for: id)?.zoom ?? 1
        leastCrop.setKey(ShapemationLeastCrop.Key(id: id, place: place, zoom: zoom))
    }
    func setKeyZoom(_ id: UUID, _ zoom: Double) {
        guard let key = leastCrop.key(for: id) else { return }
        leastCrop.setKey(ShapemationLeastCrop.Key(id: id, place: key.place, zoom: zoom))
    }

    /// The ids that play, in order: the plan's placements — the board's kept
    /// rows under least crop — else the picked items in the sort's order.
    func playOrder(for family: DetectedShape.Family) -> [UUID] {
        plan(for: family)?.placements.map(\.itemID) ?? items(for: family).map(\.id)
    }

    /// Each playing photo's hold in frames, by id.
    func holds(for family: DetectedShape.Family) -> [UUID: Int] {
        let ids = playOrder(for: family)
        return Dictionary(zip(ids, timing.holds(for: ids)), uniquingKeysWith: { a, _ in a })
    }

    /// The Projects rows' crop badge under least crop.
    func rowBadges(for family: DetectedShape.Family) -> [UUID: (label: String, colour: Color)] {
        guard mode == .leastCrop else { return [:] }
        let board = board(for: family)
        var out: [UUID: (label: String, colour: Color)] = [:]
        for r in board.rows { out[r.id] = ("crop \(Self.pct(r.evaluation.crop))", Self.colour(r.verdict)) }
        for r in board.rejected { out[r.id] = ("rejected · \(Self.pct(r.evaluation.crop))", Color.secondary) }
        return out
    }

    nonisolated static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
    nonisolated static func colour(_ v: ShapemationLeastCrop.Verdict) -> Color {
        switch v {
        case .green: return LL.levelGood
        case .amber: return LL.amber
        case .red: return LL.levelFar
        }
    }

    /// One photo on the board, as the strip, the preview and the side card
    /// draw it — the least-crop row or the fixed placement, in tile terms.
    struct BoardTile: Identifiable, Equatable {
        var id: UUID
        var title: String
        /// The place in the play order; −1 for a rejected photo.
        var index: Int
        /// The source's pixel size and the shape's bounds in it.
        var frame: CGSize
        var shapeBounds: CGRect
        /// Where the whole photo lies in a tile of the rect's aspect, unit coordinates of the tile.
        var placedRect: CGRect
        /// Least crop: where the shape is put, unit coordinates of the rect.
        var target: CGPoint?
        var badgeLabel: String
        var badgeColour: Color
        var rejected: Bool
        var rejectedByHand: Bool
        var isKey: Bool
        var holdLabel: String?
        var shareLine: String
        var naturalLine: String
        var metricLabel: String
        var metricLine: String
        var marginsLine: String?
        var fixedVerdict: ShapemationPlan.Placement.Feasibility.Verdict?
        /// What stays of the source, unit coordinates of the source.
        var sourceWindow: CGRect

        var shapeRectInSource: CGRect {
            CGRect(x: shapeBounds.minX / max(frame.width, 1), y: shapeBounds.minY / max(frame.height, 1),
                   width: shapeBounds.width / max(frame.width, 1), height: shapeBounds.height / max(frame.height, 1))
        }
        var shapeRectInTile: CGRect {
            let s = shapeRectInSource
            return CGRect(x: placedRect.minX + s.minX * placedRect.width, y: placedRect.minY + s.minY * placedRect.height,
                          width: s.width * placedRect.width, height: s.height * placedRect.height)
        }
    }

    /// The board's tiles in play order — the rejected ones after, when shown.
    func boardTiles(for family: DetectedShape.Family) -> [BoardTile] {
        let items = items(for: family)
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let holds = holds(for: family)
        func holdLabel(_ id: UUID) -> String? { timing.override(for: id).map { "hold \($0.title)" } }
        if mode == .frame {
            guard let plan = plan(for: family) else { return [] }
            let outW = Double(plan.canvas.width), outH = Double(plan.canvas.height)
            return plan.placements.enumerated().compactMap { i, p -> BoardTile? in
                guard let item = byID[p.itemID] else { return nil }
                let placed = CGRect(x: Double(p.footprint.minX) / outW, y: Double(p.footprint.minY) / outH,
                                    width: Double(p.footprint.width) / outW, height: Double(p.footprint.height) / outH)
                let wl = max(0, -Double(placed.minX) / Double(placed.width)), wt = max(0, -Double(placed.minY) / Double(placed.height))
                let wr = min(1, (1 - Double(placed.minX)) / Double(placed.width)), wb = min(1, (1 - Double(placed.minY)) / Double(placed.height))
                let f = p.feasibility
                let short = [("L", f.shortfall.left), ("T", f.shortfall.top), ("R", f.shortfall.right), ("B", f.shortfall.bottom)]
                    .map { String(format: "%@ %.0f", $0.0, $0.1) }.joined(separator: " ")
                let bounds = item.shape.bounds(in: item.pixelSize)
                return BoardTile(id: item.id, title: item.title, index: i, frame: item.pixelSize, shapeBounds: bounds, placedRect: placed, target: nil,
                                 badgeLabel: Self.verdictLabel(p), badgeColour: f.verdict.isFlagged ? (f.verdict.isUpscaled ? LL.levelFar : LL.amber) : LL.levelGood,
                                 rejected: false, rejectedByHand: false, isKey: false, holdLabel: holdLabel(item.id),
                                 shareLine: "\(Int(item.shape.nativeDiameterPx)) px · \(Self.pct(ShapemationSort.share(of: item))) of the frame",
                                 naturalLine: String(format: "%.2f · %.2f", Double(bounds.midX) / Double(item.pixelSize.width), Double(bounds.midY) / Double(item.pixelSize.height)),
                                 metricLabel: "placement", metricLine: String(format: "scale ×%.2f · short %@ px", f.upscale, short),
                                 marginsLine: nil, fixedVerdict: f.verdict,
                                 sourceWindow: CGRect(x: wl, y: wt, width: max(0, wr - wl), height: max(0, wb - wt)))
            }
        }
        let board = board(for: family)
        func tile(_ r: ShapemationLeastCrop.Row) -> BoardTile? {
            guard let item = byID[r.id] else { return nil }
            let win = r.evaluation.window
            let placed = CGRect(x: -Double(win.minX) / Double(win.width), y: -Double(win.minY) / Double(win.height),
                                width: 1 / Double(win.width), height: 1 / Double(win.height))
            let ev = r.evaluation
            let m = item.shape.margins(in: item.pixelSize)
            return BoardTile(id: item.id, title: item.title, index: r.index, frame: item.pixelSize, shapeBounds: r.photo.bounds, placedRect: placed, target: r.target,
                             badgeLabel: r.rejected ? "rejected · \(Self.pct(ev.crop))" : "crop \(Self.pct(ev.crop))",
                             badgeColour: r.rejected ? Color.secondary : Self.colour(r.verdict),
                             rejected: r.rejected, rejectedByHand: r.rejectedByHand, isKey: r.key != nil, holdLabel: holdLabel(item.id),
                             shareLine: "\(Int(r.photo.longSidePx)) px · \(Self.pct(r.photo.share)) of the frame → \(Self.pct(ev.renderedShare)) of the rect",
                             naturalLine: String(format: "%.2f · %.2f → target %.2f · %.2f", Double(ev.natural.place.x), Double(ev.natural.place.y), Double(r.target.x), Double(r.target.y)),
                             metricLabel: "crop", metricLine: String(format: "%@ · loss %@ · zoom ×%.2f (x %.2f · y %.2f)", Self.pct(ev.crop), Self.pct(ev.loss), ev.zoom, ev.zoomX, ev.zoomY),
                             marginsLine: String(format: "L %.0f %% · T %.0f %% · R %.0f %% · B %.0f %%", m.left / Double(item.pixelSize.width) * 100, m.top / Double(item.pixelSize.height) * 100,
                                                 m.right / Double(item.pixelSize.width) * 100, m.bottom / Double(item.pixelSize.height) * 100),
                             fixedVerdict: nil, sourceWindow: win)
        }
        var tiles = board.rows.compactMap(tile)
        if showRejected { tiles += board.rejected.compactMap(tile) }
        _ = holds
        return tiles
    }

    /// The selected photo at a size the board's preview deserves; the last
    /// four decodes are kept. Nil until the decode lands.
    @Published private var bigThumbnails: [UUID: CGImage] = [:]
    private var bigOrder: [UUID] = []
    private var bigRequested: Set<UUID> = []
    func bigThumbnail(for id: UUID) -> CGImage? {
        if let cg = bigThumbnails[id] { return cg }
        guard !bigRequested.contains(id), let project = projects.first(where: { $0.id == id }) else { return nil }
        bigRequested.insert(id)
        let rep = project.representative
        Task { [weak self] in
            let image = await MediaWorkQueue.shared.run { RepresentativeLoader.image(rep, maxPixelSize: 1200) }
            guard let image, let image else { return }
            await MainActor.run {
                guard let self else { return }
                self.bigThumbnails[id] = image
                self.bigOrder.append(id)
                while self.bigOrder.count > 4 {
                    let gone = self.bigOrder.removeFirst()
                    self.bigThumbnails[gone] = nil
                    self.bigRequested.remove(gone)
                }
            }
        }
        return nil
    }

    /// Re-render: the record's members are the set, each with the shape it
    /// was rendered with, and its board settings, timing and framing are
    /// restored. A member whose project has left the library is dropped.
    func lock(to record: ShapemationStore.Record) {
        lockedRecord = record
        mode = record.mode.hasBoard ? record.mode : .leastCrop
        matches[record.family] = record.match ?? ShapeMatch(family: record.family)
        if let s = record.sort { sort = s }
        if let t = record.timing { timing = t }
        if let f = record.framing {
            framing = f
            endSizeFollowsStart = false; endPlaceFollowsStart = false
        }
        if let s = record.leastCrop {
            leastCrop = s
            rectRatio = s.aspect
            frameLongEdge = Int(max(s.outputSize.width, s.outputSize.height))
        } else if let f = record.framing {
            rectRatio = Double(f.outputSize.width) / Double(max(f.outputSize.height, 1))
            frameLongEdge = Int(max(f.outputSize.width, f.outputSize.height))
        }
        selection = [:]
        snapshotShapes = [:]
        for member in record.members ?? [] where projects.contains(where: { $0.id == member.id }) {
            selection[member.id] = member.shape.id
            snapshotShapes[member.id] = member.shape
        }
    }

    /// The Output step's one line under the scrub: what the frame leaves
    /// flagged, or that nothing is.
    func feasibilitySummary(for family: DetectedShape.Family) -> String {
        guard let plan = plan(for: family), plan.mode == .frame else { return "" }
        let (short, upscaled) = plan.feasibilitySummary
        if short == 0, upscaled == 0 { return "Every photo fills the frame" }
        var parts: [String] = []
        if short > 0 { parts.append("\(short) photo\(short == 1 ? "" : "s") won't fill the frame") }
        if upscaled > 0 { parts.append("\(upscaled) would be upscaled past \(Self.capLabel(plan.framing?.upscaleCap ?? framing.upscaleCap))") }
        return parts.joined(separator: " · ")
    }

    /// The scrub's verdict badge for one placement.
    nonisolated static func verdictLabel(_ placement: ShapemationPlan.Placement) -> String {
        let f = placement.feasibility
        switch f.verdict {
        case .fits: return "fits"
        case .short: return "won't fill the frame"
        case .upscaled: return "upscaled \(capLabel(f.upscale))"
        case .shortAndUpscaled: return "won't fill the frame · upscaled \(capLabel(f.upscale))"
        }
    }

    nonisolated static func capLabel(_ factor: Double) -> String {
        factor == factor.rounded() ? "×\(Int(factor))" : String(format: "×%.1f", factor)
    }

    /// One photo of the `.frame` plan through the evaluator — what the Output
    /// step's scrub shows for the photo at `index` in the play order: the
    /// picture at ≤ 2048 px (the app's small decode, never the bake's), placed
    /// and cropped to the frame at ≤ 960 px on the long edge, over black.
    struct FramePreview: Equatable {
        var index: Int
        var itemID: UUID
        var title: String
        var image: CGImage
        var placement: ShapemationPlan.Placement
        /// The badge: the crop under least crop, the shipped verdict under Output frame.
        var verdict: String { placement.crop.map { "crop \(ShapemationBuilder.pct($0.evaluation.crop))" } ?? ShapemationBuilder.verdictLabel(placement) }
        var isFlagged: Bool { placement.crop.map { $0.verdict != .green } ?? placement.feasibility.verdict.isFlagged }
        var colour: Color { placement.crop.map { ShapemationBuilder.colour($0.verdict) } ?? (placement.feasibility.verdict.isFlagged ? LL.amber : LL.levelGood) }
    }
    @Published private(set) var framePreview: FramePreview?
    /// The last few decodes, so moving the scrub back is free and a framing
    /// change only re-places.
    private var previewDecodes: [UUID: CGImage] = [:]
    private var previewDecodeOrder: [UUID] = []
    private var previewGeneration = 0
    /// The decode in flight, cancelled by the next scrub step: a job the
    /// queue has not started is dropped outright, so a drag across the slider
    /// leaves at most one stale decode per lane ahead of the newest — not one
    /// per photo passed (editor-performance-plan.md, finding 4).
    private var previewTask: Task<Void, Never>?
    private static let previewContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    static let previewDecodeMax = 2048
    static let previewLongEdge = 960.0
    static let previewDecodesKept = 6

    func framePreview(index: Int, family: DetectedShape.Family) {
        previewGeneration += 1
        let generation = previewGeneration
        guard mode.hasBoard, let plan = plan(for: family) else { framePreview = nil; return }
        // The play order is the plan's: under least crop the rejects have no placement.
        let all = items(for: family)
        let items = plan.placements.compactMap { p in all.first { $0.id == p.itemID } }
        guard items.indices.contains(index),
              let placement = plan.placements.first(where: { $0.itemID == items[index].id }),
              let rep = projects.first(where: { $0.id == items[index].id })?.representative else { framePreview = nil; return }
        let item = items[index]
        let outputSize = plan.canvas.size
        let scale = min(1, Self.previewLongEdge / max(Double(outputSize.width), Double(outputSize.height)))
        let previewSize = CGSize(width: (Double(outputSize.width) * scale).rounded(), height: (Double(outputSize.height) * scale).rounded())
        let canvas = plan.canvas
        let cached = previewDecodes[item.id]
        let context = Self.previewContext
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            let made: (CGImage, CGImage)? = await MediaWorkQueue.shared.run {
                guard let cg = cached ?? RepresentativeLoader.image(rep, maxPixelSize: ShapemationBuilder.previewDecodeMax) else { return nil }
                let ci = ShapemationFrameEvaluator.image(item: item, decoded: cg, placement: placement, outputSize: previewSize, canvas: canvas)
                guard let out = context.createCGImage(ci, from: CGRect(origin: .zero, size: previewSize)) else { return nil }
                return (cg, out)
            } ?? nil
            guard let self, generation == self.previewGeneration, !Task.isCancelled else { return }
            guard let (decoded, image) = made else { self.framePreview = nil; return }
            if self.previewDecodes[item.id] == nil {
                self.previewDecodes[item.id] = decoded
                self.previewDecodeOrder.append(item.id)
                while self.previewDecodeOrder.count > Self.previewDecodesKept {
                    self.previewDecodes[self.previewDecodeOrder.removeFirst()] = nil
                }
            }
            self.framePreview = FramePreview(index: index, itemID: item.id, title: item.title, image: image, placement: placement)
        }
    }

    @Published private(set) var renderProgress: ShapemationRenderer.Progress?
    @Published private(set) var rendered: ShapemationStore.Record?
    /// Back to the Output step's idle state after a render — Render again.
    func renderAgain() { rendered = nil; renderError = nil }
    @Published private(set) var renderError: String?
    @Published private(set) var isRendering = false

    /// The first read: the projects the filter admits, their registers, the
    /// tags present among them. Every later change to the filter goes
    /// through `reload`, which reads the same way.
    func load(model: AppModel) {
        self.model = model
        reload()
    }

    /// Re-reads the filtered set: the count and the tag rows at once from
    /// the index, the registers off the main actor. A read overtaken by a
    /// newer filter is dropped; picks the new set no longer holds are
    /// forgotten.
    private func reload() {
        guard let model else { return }
        reloadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let query = projectQuery
        let captures = model.liveCaptures(query)
        filteredCount = captures.count
        presentTags = model.tagCounts(query)
        // The whole library's counts, for the "of N": the same question with nothing lit.
        var whole = ProjectListQuery(sort: .capture, ascending: true, filter: .all, query: SceneQuery(text: "", tags: []), listsScans: false).indexQuery
        whole.categories = [.photo, .interval]
        totalTagCounts = Dictionary(model.tagCounts(whole).map { ($0.tag, $0.count) }, uniquingKeysWith: max)
        let entries: [(AppModel.CaptureProject, URL)] = captures.map { ($0, model.projectFolderURL(for: $0)) }
        Task.detached(priority: .userInitiated) { [weak self] in
            var out: [ProjectShapes] = []
            for (capture, folder) in entries {
                guard let reg = ShapeRegister.load(inProjectFolder: folder), !reg.shapes.isEmpty else { continue }
                let url = folder.appendingPathComponent(reg.representative.relativePath)
                let rep = ShapeRepresentative(url: url, relativePath: reg.representative.relativePath,
                                              source: reg.representative.source, frameFraction: reg.representative.frameFraction)
                out.append(ProjectShapes(capture: capture, folder: folder, register: reg, representative: rep))
            }
            let sorted = out.sorted { $0.capture.createdAt < $1.capture.createdAt }
            await MainActor.run {
                guard let self, generation == self.loadGeneration else { return }
                self.projects = sorted
                let kept = Set(sorted.map(\.id))
                self.selection = self.selection.filter { kept.contains($0.key) }
                self.loaded = true
            }
        }
    }

    /// The search field's pause: ~250 ms after the last keystroke.
    private func scheduleReload() {
        guard model != nil else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    /// The match in force for a family: the step's answer, or the family alone.
    func match(for family: DetectedShape.Family) -> ShapeMatch {
        matches[family] ?? ShapeMatch(family: family)
    }

    /// A project's admissible shapes under the family's match, largest first.
    func shapes(of project: ProjectShapes, for family: DetectedShape.Family) -> [DetectedShape] {
        project.shapes(matching: match(for: family))
    }

    /// The projects holding at least one admissible shape, in the Sort's order
    /// (by the share of the frame of the shape that would be picked) — the
    /// Kit's rule, so the builder and the `lapse` CLI order the same way.
    func projects(for family: DetectedShape.Family) -> [ProjectShapes] {
        var admitted = projects.filter { admits($0) && !shapes(of: $0, for: family).isEmpty }
        if let members = lockedRecord?.members {
            let ids = Set(members.map(\.id))
            admitted = projects.filter { ids.contains($0.id) }
        }
        return sort.sorted(admitted) { share(of: $0, for: family) }
    }

    /// The Sort's key for a project: its picked (else largest) admissible
    /// shape's diameter as a share of the picture's short edge.
    func share(of project: ProjectShapes, for family: DetectedShape.Family) -> Double {
        let shapes = shapes(of: project, for: family)
        let shape = selection[project.id].flatMap { id in shapes.first { $0.id == id } } ?? shapes.first
        guard let shape else { return 0 }
        return ShapemationSort.share(of: snapshotShapes[project.id] ?? shape, in: project.frameSize)
    }

    /// How many projects and shapes the family's match admits — the Match
    /// step's readout.
    func matchCount(for family: DetectedShape.Family) -> (projects: Int, shapes: Int) {
        let m = match(for: family)
        var p = 0, n = 0
        for project in projects {
            let c = project.shapes(matching: m).count
            if c > 0 { p += 1; n += c }
        }
        return (p, n)
    }

    /// A match changed: picks that no longer qualify are dropped.
    func reconcileSelection(for family: DetectedShape.Family) {
        for project in projects {
            guard let picked = selection[project.id] else { continue }
            if !shapes(of: project, for: family).contains(where: { $0.id == picked }) { selection[project.id] = nil }
        }
    }

    func thumbnail(for project: ProjectShapes) {
        guard thumbnails[project.id] == nil else { return }
        let rep = project.representative
        Task { [weak self] in
            let image = await MediaWorkQueue.shared.run { RepresentativeLoader.image(rep, maxPixelSize: 480) }
            guard let image, let image else { return }
            await MainActor.run { self?.thumbnails[project.id] = image }
        }
    }

    func toggle(_ project: ProjectShapes, family: DetectedShape.Family) {
        if selection[project.id] != nil {
            selection[project.id] = nil
        } else if let first = shapes(of: project, for: family).first {
            selection[project.id] = first.id
        }
    }

    /// The picked items in the Sort's order — the order they play.
    func items(for family: DetectedShape.Family) -> [ShapemationItem] {
        // `projects` is in capture order (oldest first): that index is the
        // capture order whatever the sort.
        let order = Dictionary(projects.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return projects(for: family).compactMap { project in
            let shape: DetectedShape?
            if let snapshot = snapshotShapes[project.id] { shape = snapshot }
            else if let shapeID = selection[project.id] { shape = project.register.shapes.first { $0.id == shapeID } }
            else { shape = nil }
            guard let shape else { return nil }
            return ShapemationItem(id: project.id, title: project.capture.displayTitle, imageURL: project.representative.url,
                                   pixelSize: CGSize(width: project.register.representative.width, height: project.register.representative.height),
                                   shape: shape, frameFraction: project.representative.frameFraction, captureIndex: order[project.id])
        }
    }

    /// The plan under the mode — the framing rides along for `.frame`, the
    /// board's settings for `.leastCrop`.
    func plan(for family: DetectedShape.Family) -> ShapemationPlan? {
        ShapemationPlan.make(items: items(for: family), mode: mode, match: match(for: family),
                             framing: mode == .frame ? framing(for: family) : nil,
                             leastCrop: mode == .leastCrop ? settings(for: family) : nil)
    }

    /// The Timing step's estimate for the pictures that play.
    func estimate(for family: DetectedShape.Family) -> String {
        let ids = playOrder(for: family)
        return String(format: "%@ · %.1f s of playback · %d frames", ids.count == 1 ? "1 photo" : "\(ids.count) photos",
                      timing.totalSeconds(for: ids), timing.totalFrames(for: ids))
    }

    func render(family: DetectedShape.Family, size: CGSize, store: ShapemationStore) {
        guard !isRendering, let plan = plan(for: family) else { return }
        let all = items(for: family)
        // The plan's order plays: the board's kept rows under least crop.
        let items = plan.placements.compactMap { p in all.first { $0.id == p.itemID } }
        let reps = Dictionary(uniqueKeysWithValues: projects(for: family).map { ($0.id, $0.representative) })
        let id = UUID()
        let outputURL = store.outputURL(for: id)
        let posterURL = store.posterURL(for: id)
        let mode = self.mode
        let match = self.match(for: family), sort = self.sort, timing = self.timing
        // The record keeps the framing a `.frame` render was made with (§6),
        // and the filter the photos were narrowed by.
        let framing = mode == .frame ? plan.framing : nil
        let leastCrop = mode == .leastCrop ? plan.leastCropSettings : nil
        // The members as rendered — each shape a snapshot — so the list's
        // Re-render can rebuild this board whatever the registers say later.
        let placed = Set(items.map(\.id))
        let members: [ShapemationStore.Record.Member]? = mode.hasBoard ? all.map {
            .init(id: $0.id, title: $0.title, frame: $0.pixelSize, shape: $0.shape, captureIndex: $0.captureIndex ?? 0, rejected: !placed.contains($0.id))
        } : nil
        let filterTags = tagSelection.isEmpty ? nil : tagSelection.sorted()
        let filterText = trimmedQueryText.isEmpty ? nil : trimmedQueryText
        isRendering = true
        renderError = nil
        rendered = nil
        renderProgress = ShapemationRenderer.Progress(done: 0, total: items.count, title: "")
        Task.detached(priority: .userInitiated) { [weak self] in
            let renderer = ShapemationRenderer()
            renderer.timing = timing
            do {
                let poster = try renderer.render(plan: plan, items: items, outputSize: size, to: outputURL, load: { item in
                    guard let rep = reps[item.id], let image = RepresentativeLoader.image(rep, maxPixelSize: 20000) else {
                        throw LapseError.imageLoadFailed(item.imageURL)
                    }
                    return image
                }, progress: { p in
                    Task { @MainActor in self?.renderProgress = p }
                })
                if let poster { ShapemationStore.writePoster(poster, to: posterURL) }
                let record = ShapemationStore.Record(
                    id: id, title: "\(family.title) · \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))",
                    createdAt: Date(), family: family, mode: mode, itemCount: items.count,
                    width: Int(size.width), height: Int(size.height), seconds: timing.totalSeconds(for: items.map(\.id)),
                    fileName: outputURL.lastPathComponent, posterFileName: poster == nil ? nil : posterURL.lastPathComponent,
                    match: match, sort: sort, timing: timing, framing: framing,
                    filterTags: filterTags, filterText: filterText, leastCrop: leastCrop, members: members)
                await MainActor.run {
                    store.add(record)
                    self?.rendered = record
                    self?.isRendering = false
                    self?.renderProgress = nil
                }
            } catch {
                LLog("shapemation: render failed: \(error)")
                await MainActor.run {
                    self?.renderError = "\(error.localizedDescription)"
                    self?.isRendering = false
                    self?.renderProgress = nil
                }
            }
        }
    }
}

enum ShapemationBuildStep: Hashable {
    /// Which shape — after the filters, which are the builder's root.
    case family
    case match(DetectedShape.Family)
    case projects(DetectedShape.Family)
    case mode(DetectedShape.Family)
    /// The Sequence board — between Mode and Timing under the frame modes.
    case board(DetectedShape.Family)
    case timing(DetectedShape.Family)
    case output(DetectedShape.Family)
}

/// What a launch hook stages in the builder once its projects have loaded.
enum ShapemationBuilderSeed: Equatable {
    /// `LL_SHAPEMATION=family`: past the filters, on the shape step.
    case family
    /// `LL_SHAPEMATION=frame`: every project of the first family with shapes
    /// picked, `.frame` chosen, the Output step showing.
    case frame
    /// `LL_SHAPEMATION=board`: the same set, Least crop chosen, the Sequence
    /// board showing.
    case board
    /// `LL_SHAPEMATION=projects|mode`: the same set, landed on that step.
    case projects
    case mode
    /// The list's Re-render: the record's members locked, on its board.
    case rerender(ShapemationStore.Record)
}

/// The builder's root — step 1, Apply filters — and the owner of its state
/// and of every step's destination. `LL_CHIPS=tag,tag` and `LL_QUERY=<words>`
/// pre-fill the filter the way they fill the list screens.
struct ShapemationBuilderView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: ShapemationStore
    @StateObject private var builder = ShapemationBuilder()
    var seed: ShapemationBuilderSeed? = nil
    /// Pushes a step onto the sheet's stack — the seed's way past this screen.
    var push: ((ShapemationBuildStep) -> Void)? = nil
    /// Pops that many steps — the Output step's way back to the board.
    var pop: ((Int) -> Void)? = nil
    /// Whether the board is on screen — the sheet's size on the Mac.
    var onBoard: ((Bool) -> Void)? = nil
    /// Closes the whole sheet — the done card's way out.
    var close: (() -> Void)? = nil
    @State private var seeded = false
    /// The seed's step has appeared; a push the stack swallowed is retried.
    @State private var seedLanded = false

    var body: some View {
        ShapemationFiltersView(builder: builder)
        .navigationDestination(for: ShapemationBuildStep.self) { step in
            Group {
                switch step {
                case .family: ShapemationFamilyView(builder: builder)
                case .match(let family): ShapemationMatchView(builder: builder, family: family)
                case .projects(let family): ShapemationProjectsView(builder: builder, family: family)
                case .mode(let family): ShapemationModeView(builder: builder, family: family)
                case .board(let family): ShapemationBoardView(builder: builder, family: family, onBoard: onBoard)
                case .timing(let family): ShapemationTimingView(builder: builder, family: family).onAppear { onBoard?(false) }
                case .output(let family): ShapemationOutputView(builder: builder, store: store, family: family, pop: pop, close: close).onAppear { onBoard?(false) }
                }
            }
            .onAppear { seedLanded = true }
        }
        .onAppear {
            if !builder.loaded {
                #if DEBUG
                // A re-render loads the whole library: its members may sit outside any filter.
                if case .rerender? = seed {} else {
                    if let chips = ListDebugHooks.chips { builder.tagSelection = chips }
                    if let text = ListDebugHooks.queryText { builder.queryText = text }
                }
                #endif
                builder.load(model: model)
            } else {
                applySeed()
            }
        }
        .onChange(of: builder.loaded) { _, _ in applySeed() }
        // The list's Re-render hands its record over after the builder is
        // up; a seed that arrives late is applied when it arrives.
        .onChange(of: seed) { _, _ in applySeed() }
    }

    /// The seed, once the projects are in: `family` steps past the filters;
    /// `frame` takes the first family with shapes, picks every one of its
    /// projects, sets the mode and pushes the stack to the Output step. A
    /// push the stack swallows (the screen never appears) is tried again.
    private func applySeed() {
        guard let seed, builder.loaded, !seeded else { return }
        seeded = true
        LLog("shapemation: applying the seed \(seedName(seed)) over \(builder.projects.count) registers")
        seedPush(seed, attempt: 1)
    }

    private func seedName(_ seed: ShapemationBuilderSeed) -> String {
        if case .rerender(let record) = seed { return "rerender(\(record.id.uuidString.prefix(8)), \(record.members?.count ?? 0) members)" }
        return "\(seed)"
    }

    private func seedPush(_ seed: ShapemationBuilderSeed, attempt: Int) {
        seedLanded = false
        pushSeed(seed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard !seedLanded, attempt < 4 else { return }
            LLog("shapemation: the seed's push was dropped (attempt \(attempt)); trying again")
            seedPush(seed, attempt: attempt + 1)
        }
    }

    private func pushSeed(_ seed: ShapemationBuilderSeed) {
        switch seed {
        case .family:
            push?(.family)
        case .frame, .board, .projects, .mode:
            // The family with the most shapes — a library's one stray circle
            // must not take the board away from its eighty rectangles.
            guard let family = builder.familyCounts.filter({ $0.value > 0 }).max(by: { $0.value < $1.value })?.key else { return }
            for project in builder.projects(for: family) where builder.selection[project.id] == nil {
                builder.toggle(project, family: family)
            }
            builder.mode = seed == .frame ? .frame : .leastCrop
            switch seed {
            case .frame: push?(.output(family))
            case .projects: push?(.projects(family))
            case .mode: push?(.mode(family))
            default: push?(.board(family))
            }
        case .rerender(let record):
            builder.lock(to: record)
            LLog("shapemation: members locked — \(builder.selection.count) of \(record.members?.count ?? 0) found in the library; pushing the board")
            push?(.board(record.family))
        }
    }
}

/// Step 2: which shape, from the registers of the filtered photos.
struct ShapemationFamilyView: View {
    @ObservedObject var builder: ShapemationBuilder

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !builder.loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if builder.familyCounts.isEmpty {
                    Text(builder.isFiltered
                         ? "No shapes in the register among these \(builder.filteredCount) photo\(builder.filteredCount == 1 ? "" : "s"). Loosen the filters, or run Find shapes first."
                         : "No shapes in the register yet. Run Find shapes first.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .llCard(cornerRadius: 18)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Which shape holds still?")
                            .font(.system(size: 17, weight: .semibold))
                        // The filter's trail: "Tram · 82 photos".
                        if builder.isFiltered {
                            Text(builder.filterTrail)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(DetectedShape.Family.allCases.filter { (builder.familyCounts[$0] ?? 0) > 0 }, id: \.self) { family in
                            NavigationLink(value: ShapemationBuildStep.match(family)) {
                                HStack(spacing: 12) {
                                    Image(systemName: family.symbolName)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(LL.accent)
                                        .frame(width: 30, height: 30)
                                    Text(family.title).font(.system(size: 16))
                                    Spacer()
                                    Text("\(builder.projects(for: family).count) project\(builder.projects(for: family).count == 1 ? "" : "s") · \(builder.familyCounts[family] ?? 0)")
                                        .font(.system(size: 13)).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 13)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 58)
                        }
                    }
                    .llCard(cornerRadius: 18)
                }
            }
            .padding(16)
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .navigationTitle("Shape slideshow")
    }
}

/// Step 2: which projects, and which instance in each.
struct ShapemationProjectsView: View {
    @ObservedObject var builder: ShapemationBuilder
    let family: DetectedShape.Family

    var body: some View {
        let projects = builder.projects(for: family)
        let badges = builder.rowBadges(for: family)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(builder.selection.count) of \(projects.count) picked")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                    // The order the photos play in — smallest first by default,
                    // the approach; the same menu sits on the Sequence board.
                    ShapemationSortMenu(builder: builder)
                }
                LazyVStack(spacing: 10) {
                    ForEach(projects) { project in
                        ShapemationProjectRow(builder: builder, project: project, family: family, badge: badges[project.id])
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 80)
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .navigationTitle("\(family.title)s")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(builder.selection.count == projects.count ? "Clear" : "Pick all") {
                    if builder.selection.count == projects.count { builder.selection = [:] }
                    else { for p in projects where builder.selection[p.id] == nil { builder.toggle(p, family: family) } }
                }
                Spacer()
                NavigationLink(value: ShapemationBuildStep.mode(family)) {
                    Text("Next · mode")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(LL.accent)
                .disabled(builder.selection.count < 2)
            }
            .padding(16)
            .background(.regularMaterial)
        }
        .onAppear { for p in projects { builder.thumbnail(for: p) } }
    }
}

struct ShapemationProjectRow: View {
    @ObservedObject var builder: ShapemationBuilder
    let project: ShapemationBuilder.ProjectShapes
    let family: DetectedShape.Family
    /// The board's crop badge for this photo under least crop, so the list
    /// and the board agree before the board is seen.
    var badge: (label: String, colour: Color)? = nil

    var body: some View {
        let shapes = builder.shapes(of: project, for: family)
        let picked = builder.selection[project.id]
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                if let cg = builder.thumbnails[project.id] {
                    ShapeOverlayThumbnail(image: cg, shapes: shapes, highlighted: picked)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(project.capture.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text("\(shapes.count) \(family.title.lowercased())\(shapes.count == 1 ? "" : "s") · \(project.capture.mode)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if shapes.count > 1, picked != nil {
                    HStack(spacing: 6) {
                        ForEach(Array(shapes.enumerated()), id: \.element.id) { i, shape in
                            Button {
                                builder.selection[project.id] = shape.id
                            } label: {
                                Text("\(i + 1) · \(Int(shape.nativeDiameterPx)) px")
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(picked == shape.id ? LL.accent : Color.secondary.opacity(0.15), in: Capsule())
                                    .foregroundStyle(picked == shape.id ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else if let first = shapes.first {
                    Text("\(Int(first.nativeDiameterPx)) px · \(Int((builder.share(of: project, for: family) * 100).rounded())) % of the frame")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                if let badge, picked != nil {
                    HStack(spacing: 5) {
                        Circle().fill(badge.colour).frame(width: 8, height: 8)
                        Text(badge.label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Badge: \(badge.label)")
                }
            }
            Spacer()
            Image(systemName: picked != nil ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(picked != nil ? LL.accent : Color.secondary.opacity(0.5))
        }
        .padding(12)
        .llCard(cornerRadius: 14)
        .contentShape(Rectangle())
        .onTapGesture { builder.toggle(project, family: family) }
    }
}

/// The representative with its shapes drawn; the picked instance in amber.
struct ShapeOverlayThumbnail: View {
    let image: CGImage
    let shapes: [DetectedShape]
    let highlighted: UUID?

    var body: some View {
        GeometryReader { geo in
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let s = min(geo.size.width / iw, geo.size.height / ih)
            let dw = iw * s, dh = ih * s
            let ox = (geo.size.width - dw) / 2, oy = (geo.size.height - dh) / 2
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: dw, height: dh)
                    .offset(x: ox, y: oy)
                Canvas { ctx, _ in
                    for shape in shapes {
                        let colour: Color = shape.id == highlighted ? LL.amber : .white.opacity(0.85)
                        var path = Path()
                        if let c = shape.corners {
                            let pts = c.map { CGPoint(x: ox + $0.x * dw, y: oy + $0.y * dh) }
                            path.move(to: pts[0]); for p in pts.dropFirst() { path.addLine(to: p) }; path.closeSubpath()
                        } else {
                            let cx = ox + shape.centre.x * dw, cy = oy + shape.centre.y * dh
                            let a = shape.majorAxis * dw / 2, b = shape.minorAxis * dw / 2
                            let ellipse = Path(ellipseIn: CGRect(x: -a, y: -b, width: 2 * a, height: 2 * b))
                            path = ellipse.applying(CGAffineTransform(translationX: cx, y: cy).rotated(by: shape.rotation))
                        }
                        ctx.stroke(path, with: .color(colour), lineWidth: shape.id == highlighted ? 2.5 : 1.5)
                    }
                }
            }
        }
    }
}

/// Step 3: mode — four tabs over one card with a low-fi preview of the
/// picked photos through the chosen mode, looping; the copy alone did not
/// explain the modes (prototype hand-off, Required). Least crop and Output
/// frame go on to the Sequence board; the stack modes to Timing.
struct ShapemationModeView: View {
    @ObservedObject var builder: ShapemationBuilder
    let family: DetectedShape.Family

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("How should the photos be laid out?")
                    .font(.system(size: 17, weight: .semibold))
                Picker("Mode", selection: $builder.mode) {
                    ForEach(ShapemationMode.allCases, id: \.self) { Text(tabTitle($0)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityLabel("Mode: \(builder.mode.title)")
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: modeSymbol(builder.mode))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(LL.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(builder.mode.title).font(.system(size: 16, weight: .semibold))
                            Text(builder.mode.summary).font(.system(size: 13)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ShapemationModePreview(builder: builder, family: family)
                }
                .padding(16)
                .llCard(cornerRadius: 18)
                if let plan = builder.plan(for: family) {
                    Text(planSummary(plan))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if builder.mode == .crop {
                    Text("These photos share no common area once the shape is locked — crop mode has nothing to show. Pick fewer, or use stack mode.")
                        .font(.system(size: 12))
                        .foregroundStyle(LL.accentDeep)
                } else if builder.mode == .leastCrop {
                    Text("Every photo would pay more than the tolerance allows — see the board, or loosen it there.")
                        .font(.system(size: 12))
                        .foregroundStyle(LL.accentDeep)
                }
            }
            .padding(16)
            .padding(.bottom, 80)
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .navigationTitle("Mode")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                NavigationLink(value: builder.mode.hasBoard ? ShapemationBuildStep.board(family) : ShapemationBuildStep.timing(family)) {
                    Text(builder.mode.hasBoard ? "Next · board" : "Next · timing")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(LL.accent)
                .disabled(builder.plan(for: family) == nil && !builder.mode.hasBoard)
            }
            .padding(16)
            .background(.regularMaterial)
        }
        .onAppear { for p in builder.projects(for: family) { builder.thumbnail(for: p) } }
    }

    private func tabTitle(_ mode: ShapemationMode) -> String {
        switch mode {
        case .stack: return "Stack · fit"
        case .crop: return "Stack · crop"
        case .frame: return "Output frame"
        case .leastCrop: return "Least crop"
        }
    }

    private func modeSymbol(_ mode: ShapemationMode) -> String {
        switch mode {
        case .stack: return "rectangle.stack"
        case .crop: return "crop"
        case .frame: return "viewfinder.rectangular"
        case .leastCrop: return "arrow.down.left.and.arrow.up.right"
        }
    }

    private func planSummary(_ plan: ShapemationPlan) -> String {
        let c = plan.canvas.size
        let shape = Int(plan.shapeSizePx)
        switch plan.mode {
        case .stack:
            return "Canvas \(Int(c.width))×\(Int(c.height)) holds every photo; the shape is \(shape) px across."
        case .crop:
            let u = plan.unionCanvas.size
            return "Crop \(Int(c.width))×\(Int(c.height)) of a \(Int(u.width))×\(Int(u.height)) stack; the shape is \(shape) px across."
        case .frame:
            let last = Int(plan.placements.last?.targetSizePx ?? plan.shapeSizePx)
            let sizes = last == shape ? "\(shape) px across" : "\(shape) px across at the first photo, \(last) at the last"
            let flagged = plan.flagged.count
            let tail = flagged == 0 ? "every photo fills it." : "\(flagged) photo\(flagged == 1 ? "" : "s") flagged — see the board."
            return "Frame \(Int(c.width))×\(Int(c.height)); the shape is \(sizes); \(tail)"
        case .leastCrop:
            guard let board = plan.leastCrop else { return "" }
            return "Frame \(Int(c.width))×\(Int(c.height)) · least crop; \(board.countLine) · mean crop \(ShapemationBuilder.pct(board.meanCrop)) — the rejects, keys and tolerance live on the board."
        }
    }
}

/// The Mode step's looping preview: the picked photos through the chosen
/// mode at thumbnail size — the stack modes accumulate their first ten on
/// the black table, the frame modes show one photo per frame with its badge.
struct ShapemationModePreview: View {
    @ObservedObject var builder: ShapemationBuilder
    let family: DetectedShape.Family
    @State private var index = 0
    @State private var playing = true
    private let ticker = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()

    var body: some View {
        let tiles = builder.mode.hasBoard ? builder.boardTiles(for: family).filter { !$0.rejected } : []
        let plan = builder.mode.hasBoard ? nil : builder.plan(for: family)
        let stackCount = plan.map { min(10, $0.placements.count) } ?? 0
        let count = builder.mode.hasBoard ? tiles.count : stackCount
        let i = count > 0 ? min(index, count - 1) : 0
        let ratio: CGFloat = {
            if let plan { return plan.canvas.width / max(plan.canvas.height, 1) }
            return builder.rectRatio(for: family)
        }()
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let w = min(geo.size.width, geo.size.height * ratio), h = w / ratio
                ZStack(alignment: .topTrailing) {
                    Color.black
                    if let plan, count > 0 {
                        stackFrame(plan: plan, upTo: i, size: CGSize(width: w, height: h))
                        badge("\(i + 1) on the table", colour: LL.levelGood)
                    } else if count > 0 {
                        let tile = tiles[i]
                        ShapemationBoardTileImage(tile: tile, image: builder.thumbnails[tile.id], size: CGSize(width: w, height: h), shapeBox: true)
                        badge(tile.badgeLabel, colour: tile.badgeColour)
                    }
                }
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity)
            }
            .aspectRatio(max(ratio, 0.75), contentMode: .fit)
            .frame(maxHeight: 300)
            HStack(spacing: 10) {
                Button { playing.toggle() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 12))
                        .frame(width: 28, height: 28).background(LL.accent, in: Circle()).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playing ? "Pause preview" : "Play preview")
                if count > 1 {
                    Slider(value: Binding(get: { Double(i) }, set: { index = Int($0); playing = false }), in: 0...Double(count - 1), step: 1)
                        .tint(LL.accent)
                        .accessibilityLabel("Preview frame")
                }
                Text(count > 0 ? "\(i + 1) / \(count)" : "—").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(note(plan: plan, tiles: tiles)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(ticker) { _ in
            guard playing, count > 1 else { return }
            index = (i + 1) % count
        }
    }

    /// The first `upTo + 1` placements over the black table, each drawn into
    /// its footprint — the affine approximation of a low-fi preview; the
    /// scrub and the render go through the evaluator.
    private func stackFrame(plan: ShapemationPlan, upTo: Int, size: CGSize) -> some View {
        let sx = size.width / max(plan.canvas.width, 1), sy = size.height / max(plan.canvas.height, 1)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(plan.placements.prefix(upTo + 1).enumerated()), id: \.offset) { _, p in
                if let cg = builder.thumbnails[p.itemID] {
                    Image(decorative: cg, scale: 1).resizable()
                        .frame(width: p.footprint.width * sx, height: p.footprint.height * sy)
                        .offset(x: p.footprint.minX * sx, y: p.footprint.minY * sy)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    private func badge(_ label: String, colour: Color) -> some View {
        Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(colour)
            .padding(.horizontal, 9).padding(.vertical, 3).background(.black.opacity(0.6), in: Capsule())
            .padding(8)
    }

    private func note(plan: ShapemationPlan?, tiles: [ShapemationBuilder.BoardTile]) -> String {
        let n = builder.items(for: family).count
        switch builder.mode {
        case .stack, .crop:
            guard let plan else { return "" }
            let shown = min(10, plan.placements.count)
            return "\(builder.mode == .stack ? "The canvas holds every photo; black shows until it is covered." : "Cropped to what every photo covers.") The shape is \(Int(plan.shapeSizePx)) px across. Preview: the first \(shown) of \(n), \(n > 10 ? "the rest render the same way" : "all of them")."
        case .frame:
            let flagged = tiles.filter { $0.fixedVerdict?.isFlagged == true }.count
            return "Every shape put at \(Int((builder.startKey.size * 100).rounded())) % of the height; \(flagged) of \(tiles.count) flagged. The board sets size, place and ease."
        case .leastCrop:
            let board = builder.board(for: family)
            return "Cover-fitted into \(ShapemationFraming.aspectLabel(ratio: builder.rectRatio(for: family))), shifted along the median path; \(board.rejected.count) rejected, mean crop \(ShapemationBuilder.pct(board.meanCrop)). The board is where the rejects, keys and tolerance live."
        }
    }
}

/// Step 4: output size, then render. Under the frame modes the rect and
/// everything about it was decided on the board: the step shows the frame
/// and the members, a way back to the board, the scrub through the
/// evaluator with each photo's badge, and Create.
struct ShapemationOutputView: View {
    @ObservedObject var builder: ShapemationBuilder
    @ObservedObject var store: ShapemationStore
    let family: DetectedShape.Family
    var pop: ((Int) -> Void)? = nil
    /// Closes the sheet — Done on the finished card.
    var close: (() -> Void)? = nil
    @State private var chosen: ShapemationPlan.OutputOption?
    @State private var playing: ShapemationStore.Record?
    /// The scrub's photo index, in the play order.
    @State private var scrub = 0.0

    var body: some View {
        let plan = builder.plan(for: family)
        let options = plan?.outputOptions() ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let record = builder.rendered {
                    doneCard(record)
                } else if let progress = builder.renderProgress {
                    progressCard(progress)
                } else if builder.mode.hasBoard {
                    Text(builder.mode == .frame ? "Output frame" : "Least crop")
                        .font(.system(size: 17, weight: .semibold))
                    Text(builder.mode == .frame
                         ? "Every photo is scaled and placed to put its \(family.title.lowercased()) here. One that cannot reach the frame's edges, or would be blown up to, is flagged and kept."
                         : "Every photo is cover-fitted to the frame and shifted only as far as the path asks. The crop each one pays is the badge; rejected photos are left out.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    summaryCard(plan)
                    scrubCard(plan)
                    if let error = builder.renderError {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    }
                    estimate
                } else {
                    Text("Output size")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Sizes come from the pictures you picked: the native canvas keeps every pixel; the fits scale it down.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(options) { option in
                            Button { chosen = option } label: {
                                HStack {
                                    Text(option.label).font(.system(size: 15))
                                    Spacer()
                                    Image(systemName: (chosen ?? options.first)?.id == option.id ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundStyle((chosen ?? options.first)?.id == option.id ? LL.accent : Color.secondary.opacity(0.5))
                                }
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 16)
                        }
                    }
                    .llCard(cornerRadius: 16)
                    if let error = builder.renderError {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    }
                    estimate
                }
            }
            .padding(16)
            .padding(.bottom, 80)
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .navigationTitle("Output")
        .safeAreaInset(edge: .bottom) {
            // Create is pinned like every step's Next, so it is never below the
            // fold; once the clip exists the bar is the way out — Render again
            // or Done (the record is already in the Shape-mations list).
            if builder.rendered != nil {
                HStack {
                    Button("Render again") { builder.renderAgain() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        close?()
                    } label: {
                        Text("Done")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 22).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LL.accent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Done, close the Shape-mation sheet")
                }
                .padding(16)
                .background(.regularMaterial)
            } else if builder.renderProgress == nil {
                HStack {
                    Spacer()
                    createButton(enabled: builder.mode.hasBoard ? plan != nil : !options.isEmpty) {
                        if builder.mode.hasBoard {
                            if let plan { builder.render(family: family, size: plan.canvas.size, store: store) }
                        } else if let option = chosen ?? options.first {
                            builder.render(family: family, size: option.size, store: store)
                        }
                    }
                }
                .padding(16)
                .background(.regularMaterial)
            }
        }
        .sheet(item: $playing) { record in
            ShapemationPlayerSheet(record: record, store: store)
        }
        .onAppear { refreshPreview() }
        .onChange(of: scrub) { _, _ in refreshPreview() }
        .onChange(of: builder.framing) { _, _ in refreshPreview() }
        .onChange(of: builder.leastCrop) { _, _ in refreshPreview() }
        .onChange(of: builder.mode) { _, _ in refreshPreview() }
    }

    /// What Timing decided, restated where Create is pressed.
    private var estimate: some View {
        VStack(alignment: .leading, spacing: 3) {
            let ids = builder.playOrder(for: family)
            Text("\(ids.count) photo\(ids.count == 1 ? "" : "s") · \(builder.timing.summary)")
            Text(String(format: "%.1f s of playback · %d frames · %@",
                        builder.timing.totalSeconds(for: ids), builder.timing.totalFrames(for: ids),
                        builder.sort.title.lowercased()))
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private func createButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Create Shape-mation")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 18).padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(LL.accent)
        .disabled(!enabled)
        .accessibilityLabel("Create the Shape-mation")
    }

    // MARK: - The frame modes

    /// The frame and the members, and the way back to the board.
    private func summaryCard(_ plan: ShapemationPlan?) -> some View {
        let size = builder.rectSize(for: family)
        let label = ShapemationFraming.aspectLabel(ratio: builder.rectRatio(for: family))
        let board = builder.mode == .leastCrop ? plan?.leastCrop : nil
        let ids = builder.playOrder(for: family)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Frame").font(.system(size: 15))
                Spacer()
                Text("\(label) · \(Int(size.width))×\(Int(size.height)) · \(builder.mode == .frame ? "fixed shape \(Int((builder.startKey.size * 100).rounded())) %" : "least crop")")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Members").font(.system(size: 15))
                Spacer()
                Text(board.map { "\(ids.count) photos · \($0.rejected.count) rejected · \(builder.leastCrop.keys.count) keys · \(builder.sort.title.lowercased())" }
                     ?? "\(ids.count) photos · \(builder.sort.title.lowercased())")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if let pop {
                Button("Adjust on the board") { pop(2) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LL.accent)
            }
        }
        .padding(16)
        .llCard(cornerRadius: 18)
    }

    /// The scrub: photo *i* through the evaluator, its title and badge, the
    /// slider over the photos that play, and the tally line.
    private func scrubCard(_ plan: ShapemationPlan?) -> some View {
        let count = builder.playOrder(for: family).count
        let size = builder.rectSize(for: family)
        let preview = builder.framePreview
        let current = preview?.index == Int(scrub) ? preview : nil
        return VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Color.black
                if let current {
                    Image(decorative: current.image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .aspectRatio(size.width / max(size.height, 1), contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                Text(current?.title ?? " ")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if let current { verdictBadge(current) }
            }
            if count > 1 {
                Slider(value: $scrub, in: 0...Double(count - 1), step: 1)
                    .tint(LL.accent)
                    .accessibilityLabel("Scrub")
                    .accessibilityValue("Photo \(Int(scrub) + 1) of \(count)")
                Text("Photo \(Int(scrub) + 1) of \(count)")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            Text(tally(plan))
                .font(.system(size: 12))
                .foregroundStyle(LL.accentDeep)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .llCard(cornerRadius: 18)
    }

    private func tally(_ plan: ShapemationPlan?) -> String {
        if builder.mode == .frame { return builder.feasibilitySummary(for: family) }
        guard let board = plan?.leastCrop else { return "" }
        return "\(board.rejected.count) rejected · \(board.flagged) flagged · mean crop \(ShapemationBuilder.pct(board.meanCrop)) · mean loss \(ShapemationBuilder.pct(board.meanLoss)) · jump \(String(format: "%.2f", board.renderedJump))"
    }

    private func verdictBadge(_ preview: ShapemationBuilder.FramePreview) -> some View {
        Text(preview.verdict)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(preview.colour.opacity(0.25), in: Capsule())
            .foregroundStyle(.primary)
            .lineLimit(1)
            .accessibilityLabel("Verdict: \(preview.verdict)")
    }

    private func refreshPreview() {
        guard builder.mode.hasBoard else { return }
        let count = builder.playOrder(for: family).count
        if scrub > Double(max(count - 1, 0)) { scrub = Double(max(count - 1, 0)) }
        builder.framePreview(index: Int(scrub), family: family)
    }

    private func progressCard(_ progress: ShapemationRenderer.Progress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rendering \(min(progress.done + 1, max(progress.total, 1))) of \(progress.total)")
                .font(.system(size: 15, weight: .semibold))
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).tint(LL.accent)
            Text(progress.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(16)
        .llCard(cornerRadius: 18)
    }

    private func doneCard(_ record: ShapemationStore.Record) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ShapemationPosterView(record: record, store: store)
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(record.title).font(.system(size: 15, weight: .semibold))
            Text(record.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(record.members != nil
                 ? "Saved to Shape-mations with its members — Play or Share it here, or Re-render it from the list at another rate, rect or framing. Done closes this sheet."
                 : "Saved to Shape-mations — Play or Share it here. Done closes this sheet.")
                .font(.system(size: 12)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button { playing = record } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).tint(LL.accent)
                ShareLink(item: store.url(for: record)) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .llCard(cornerRadius: 18)
    }
}


/// Step 1½: how strict about the family (design signed off 2026-09-11 —
/// docs/design/iOS/shapemation.builder.match.*.portrait.svg). One card of
/// label-above controls, a live "N projects · M shapes match" readout, Next ·
/// projects. Everything is a select: segmented pickers and capsule chips.
struct ShapemationMatchView: View {
    @ObservedObject var builder: ShapemationBuilder
    let family: DetectedShape.Family

    private var match: Binding<ShapeMatch> {
        Binding(
            get: { builder.match(for: family) },
            set: { builder.matches[family] = $0; builder.reconcileSelection(for: family) })
    }

    var body: some View {
        let m = match.wrappedValue
        let count = builder.matchCount(for: family)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("How strict about the \(family.title.lowercased())?")
                    .font(.system(size: 17, weight: .semibold))
                VStack(alignment: .leading, spacing: 16) {
                    switch family {
                    case .circle:
                        group("Roundness") { strictness }
                        footer("Rims at least \(Int(m.minRoundness * 100)) % round. Strict is 95 %. Loose takes rims seen from the side, down to 70 %, and levels each into a circle — mugs shot from above and from the side agree.")
                    case .oval:
                        // Presets, or Custom: a ratio off the preset list, stepped below.
                        let presets: [Double] = [0.5, 0.6, 0.7, 0.8]
                        let isCustom = m.ovalRatio.map { !presets.contains($0) } ?? false
                        group("Ratio") {
                            chips(options: ["Any", "0.5", "0.6", "0.7", "0.8", "Custom"],
                                  selected: isCustom ? "Custom" : (m.ovalRatio.map { String(format: "%.1f", $0) } ?? "Any"), title: { $0 }) { pick in
                                switch pick {
                                case "Any": match.wrappedValue.ovalRatio = nil
                                case "Custom": match.wrappedValue.ovalRatio = 0.65
                                default: match.wrappedValue.ovalRatio = Double(pick)
                                }
                            }
                        }
                        if isCustom {
                            Stepper(String(format: "Ratio %.2f", m.ovalRatio ?? 0.65),
                                    value: Binding(get: { m.ovalRatio ?? 0.65 }, set: { match.wrappedValue.ovalRatio = $0 }),
                                    in: 0.30...0.85, step: 0.05)
                            .font(.system(size: 14))
                        }
                        if m.ovalRatio != nil { group("Tolerance") { strictness } }
                        group("Angle") {
                            Picker("Angle", selection: match.angle) {
                                ForEach(ShapeMatch.Angle.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                        }
                        footer(ovalFooter(m))
                    case .square:
                        group("Tolerance") { strictness }
                        footer("Sides within \(Int((m.maxSquareAspect - 1) * 100).description) % of each other (\(String(format: "%.2f", 1 / m.maxSquareAspect))–\(String(format: "%.2f", m.maxSquareAspect)) as seen). Strict is 5 %, Loose 40 %. Measured on the true rectangle where the lens is known, so a tile seen at an angle still counts.")
                    case .rectangle:
                        group("Aspect") {
                            chips(options: ShapeMatch.AspectClass.allCases, selected: m.aspectClass, title: \.title) {
                                match.wrappedValue.aspectClass = $0
                            }
                        }
                        if m.aspectClass == .custom {
                            HStack(spacing: 16) {
                                Stepper("Width \(m.customWidth)", value: match.customWidth, in: 1...32).font(.system(size: 14))
                                Stepper("Height \(m.customHeight)", value: match.customHeight, in: 1...32).font(.system(size: 14))
                            }
                        }
                        if m.aspectClass != .any { group("Tolerance") { strictness } }
                        group("Orientation") {
                            Picker("Orientation", selection: match.orientation) {
                                ForEach(ShapeMatch.Orientation.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                        }
                        footer(rectangleFooter(m))
                    }
                }
                .padding(16)
                .llCard(cornerRadius: 18)
                Text("\(count.projects) project\(count.projects == 1 ? "" : "s") · \(count.shapes) \(family.title.lowercased())\(count.shapes == 1 ? "" : "s") match\(count.shapes == 1 ? "es" : "")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .navigationTitle("Match")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                NavigationLink(value: ShapemationBuildStep.projects(family)) {
                    Text("Next · projects")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(LL.accent)
                .disabled(count.shapes == 0)
            }
            .padding(16)
            .background(.regularMaterial)
        }
        .onAppear { if builder.matches[family] == nil { builder.matches[family] = ShapeMatch(family: family) } }
    }

    private var strictness: some View {
        Picker("Strictness", selection: match.strictness) {
            ForEach(ShapeMatch.Strictness.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14))
            content()
        }
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// A wrapping row of capsule chips — the select for a list too long for a
    /// segmented control.
    private func chips<T: Hashable>(options: [T], selected: T, title: @escaping (T) -> String, select: @escaping (T) -> Void) -> some View {
        FlowChips(options: options, selected: selected, title: title, select: select)
    }

    private func ovalFooter(_ m: ShapeMatch) -> String {
        var s: String
        if let r = m.ovalRatio {
            s = String(format: "Ovals between %.2f and %.2f (minor ÷ major)", max(0, r - m.ovalTolerance), min(0.85, r + m.ovalTolerance))
        } else {
            s = "Every oval, whatever its ratio"
        }
        s += m.angle == .level ? ", each turned so its long axis is level." : ", each at the angle it was shot."
        if m.ovalRatio != nil { s += " Strict is ±0.05, Loose ±0.20." }
        return s
    }

    private func rectangleFooter(_ m: ShapeMatch) -> String {
        let counts = builder.projects(for: family).map { builder.shapes(of: $0, for: family) }.flatMap { $0 }
        let rectified = counts.filter(\.isRectified).count
        var s: String
        if let cls = m.targetAspect {
            let name = m.aspectClass == .custom ? "\(m.customWidth):\(m.customHeight)" : m.aspectClass.title
            s = "\(name) (\(String(format: "%.2f", cls))) within \(Int((m.rectangleTolerance * 100).rounded())) %"
            s += m.orientation == .any ? ", either way up." : ", \(m.orientation.rawValue) only."
        } else {
            s = "Every rectangle" + (m.orientation == .any ? "." : ", \(m.orientation.rawValue) only.")
        }
        s += " Measured on the true rectangle and corrected for the camera angle where the lens is known"
        if counts.isEmpty { s += "." }
        else if rectified == counts.count { s += " — all \(counts.count) here." }
        else { s += " — \(rectified) of \(counts.count) here; the other\(counts.count - rectified == 1 ? "" : "s") matched as they appear on screen." }
        return s
    }
}

/// Capsule chips that wrap to the next line when the row is full.
struct FlowChips<T: Hashable>: View {
    let options: [T]
    let selected: T
    let title: (T) -> String
    let select: (T) -> Void

    var body: some View {
        // A fixed two-row layout is enough for the lists here (≤ 8 chips);
        // the first row takes what fits at 44 pt a chip, the rest wrap.
        let perRow = 5
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(stride(from: 0, to: options.count, by: perRow)), id: \.self) { start in
                HStack(spacing: 8) {
                    ForEach(options[start..<min(start + perRow, options.count)], id: \.self) { option in
                        let on = option == selected
                        Button { select(option) } label: {
                            Text(title(option))
                                .font(.system(size: 13, weight: on ? .semibold : .regular))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(on ? LL.accent : LL.controlFill, in: Capsule())
                                .foregroundStyle(on ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// The nine-point face picker: a small frame in the output's aspect with a
/// tappable dot at each of `ShapemationBuilder.facePlaces`, the chosen one
/// on the accent. The frame is 96 pt on its long side.
struct ShapemationFacePlacePicker: View {
    let aspect: CGSize
    let selected: CGPoint
    /// "start" or "end" — the dots' accessibility labels carry it.
    let name: String
    let select: (CGPoint) -> Void

    private static let columns = ["left", "centre", "right"]
    private static let rows = ["top", "middle", "bottom"]

    var body: some View {
        let ratio = Double(aspect.width) / max(Double(aspect.height), 1)
        let w = ratio >= 1 ? 96.0 : 96.0 * ratio
        let h = ratio >= 1 ? 96.0 / ratio : 96.0
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LL.controlFill)
            ForEach(Array(ShapemationBuilder.facePlaces.enumerated()), id: \.offset) { i, cell in
                let on = abs(cell.x - selected.x) < 0.01 && abs(cell.y - selected.y) < 0.01
                Button { select(cell) } label: {
                    Circle()
                        .fill(on ? LL.accent : Color.secondary.opacity(0.35))
                        .frame(width: on ? 14 : 10, height: on ? 14 : 10)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: cell.x * w, y: cell.y * h)
                .accessibilityLabel("Face \(name): \(Self.columns[i % 3]) \(Self.rows[i / 3])")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(width: w, height: h)
    }
}

/// Step 3½: how fast it plays (design signed off 2026-09-11 —
/// docs/design/iOS/shapemation.builder.timing{,.ramp}.portrait.svg). Frame
/// rate and Ramp as segmented pickers, the holds as menu selects, the
/// estimate live under the card.
struct ShapemationTimingView: View {
    @ObservedObject var builder: ShapemationBuilder
    let family: DetectedShape.Family

    private var rampOn: Binding<Bool> {
        Binding(
            get: { builder.timing.ramp != nil },
            set: { on in
                if on, builder.timing.ramp == nil {
                    builder.timing.ramp = .init(start: .seconds(2), middle: .seconds(0.5), end: .seconds(1))
                } else if !on {
                    builder.timing.ramp = nil
                }
            })
    }

    var body: some View {
        let t = builder.timing
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("How fast should it play?")
                    .font(.system(size: 17, weight: .semibold))
                VStack(alignment: .leading, spacing: 16) {
                    group("Frame rate") {
                        Picker("Frame rate", selection: $builder.timing.fps) {
                            ForEach(ShapemationTiming.frameRates, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    group("Ramp") {
                        Picker("Ramp", selection: rampOn) {
                            Text("Off").tag(false)
                            Text("On").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    VStack(spacing: 0) {
                        if t.ramp != nil {
                            holdRow("Start", Binding(get: { builder.timing.ramp?.start ?? .seconds(2) }, set: { builder.timing.ramp?.start = $0 }))
                            Divider()
                            middleRow
                            Divider()
                            holdRow("End", Binding(get: { builder.timing.ramp?.end ?? .seconds(1) }, set: { builder.timing.ramp?.end = $0 }))
                        } else {
                            holdRow("Each photo", $builder.timing.each)
                        }
                    }
                    Text(footer(t))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let n = t.overrides?.count, n > 0 {
                        Text("\(n) photo\(n == 1 ? " has its" : "s have their") own hold from the board — the override wins over the ramp for that photo.")
                            .font(.system(size: 12)).foregroundStyle(LL.accentDeep)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .llCard(cornerRadius: 18)
                Text(builder.estimate(for: family))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .navigationTitle("Timing")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                NavigationLink(value: ShapemationBuildStep.output(family)) {
                    Text("Next · output")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(LL.accent)
            }
            .padding(16)
            .background(.regularMaterial)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14))
            content()
        }
    }

    /// A menu select for one hold: label leading, the value trailing.
    private func holdRow(_ title: String, _ hold: Binding<ShapemationTiming.Hold>) -> some View {
        HStack {
            Text(title).font(.system(size: 15))
            Spacer()
            Picker(title, selection: hold) {
                ForEach(ShapemationTiming.Hold.options, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(.secondary)
        }
        .frame(minHeight: 44)
    }

    /// Middle offers None — a straight run from start to end.
    private var middleRow: some View {
        let binding = Binding<ShapemationTiming.Hold?>(
            get: { builder.timing.ramp?.middle },
            set: { builder.timing.ramp?.middle = $0 })
        return HStack {
            Text("Middle").font(.system(size: 15))
            Spacer()
            Picker("Middle", selection: binding) {
                Text("None").tag(ShapemationTiming.Hold?.none)
                ForEach(ShapemationTiming.Hold.options, id: \.self) { Text($0.title).tag(ShapemationTiming.Hold?.some($0)) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(.secondary)
        }
        .frame(minHeight: 44)
    }

    private func footer(_ t: ShapemationTiming) -> String {
        if let ramp = t.ramp {
            let mid = ramp.middle.map { ", \($0.title) in the middle" } ?? ""
            return "Photos hold \(ramp.start.title) at the start\(mid) and \(ramp.end.title) at the end, eased between — each in whole frames at \(t.fps) fps, never under one. Middle can be None for a straight run start → end."
        }
        return "Every photo holds \(t.each.title) — \(t.each.frames(at: t.fps)) frame\(t.each.frames(at: t.fps) == 1 ? "" : "s") at \(t.fps) fps. Choose in seconds or in frames; seconds round to whole frames at the frame rate."
    }
}
