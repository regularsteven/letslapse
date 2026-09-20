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
    }

    @Published private(set) var projects: [ProjectShapes] = []
    @Published private(set) var familyCounts: [DetectedShape.Family: Int] = [:]

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
    @Published var mode: ShapemationMode = .stack
    /// The Match step's answer, per family visited. Nil until the step is
    /// seen, when the family's plain membership applies.
    @Published var matches: [DetectedShape.Family: ShapeMatch] = [:]
    /// The order the photos play in. Largest share first by default.
    @Published var sort: ShapemationSort = .largestFirst
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
    @Published var frameAspect: ShapemationFraming.Aspect = ShapemationBuilder.defaultAspect { didSet { refitFrame() } }
    @Published var frameLongEdge: Int = ShapemationBuilder.defaultLongEdge { didSet { refitFrame() } }
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

    private func refitFrame() {
        let size = ShapemationFraming.outputSize(aspect: frameAspect, longEdge: frameLongEdge)
        guard size != framing.outputSize else { return }
        framing = ShapemationFraming(outputSize: size, keys: framing.keys, ease: framing.ease, upscaleCap: framing.upscaleCap)
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
        var verdict: String { ShapemationBuilder.verdictLabel(placement) }
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
        guard mode == .frame, let plan = plan(for: family) else { framePreview = nil; return }
        let items = items(for: family)
        guard items.indices.contains(index),
              let placement = plan.placements.first(where: { $0.itemID == items[index].id }),
              let rep = projects.first(where: { $0.id == items[index].id })?.representative else { framePreview = nil; return }
        let item = items[index]
        let outputSize = framing.outputSize
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
        let entries: [(AppModel.CaptureProject, URL)] = captures.map { ($0, model.projectFolderURL(for: $0)) }
        Task.detached(priority: .userInitiated) { [weak self] in
            var out: [ProjectShapes] = []
            var counts: [DetectedShape.Family: Int] = [:]
            for (capture, folder) in entries {
                guard let reg = ShapeRegister.load(inProjectFolder: folder), !reg.shapes.isEmpty else { continue }
                let url = folder.appendingPathComponent(reg.representative.relativePath)
                let rep = ShapeRepresentative(url: url, relativePath: reg.representative.relativePath,
                                              source: reg.representative.source, frameFraction: reg.representative.frameFraction)
                out.append(ProjectShapes(capture: capture, folder: folder, register: reg, representative: rep))
                for (f, n) in reg.families() { counts[f, default: 0] += n }
            }
            let sorted = out.sorted { $0.capture.createdAt < $1.capture.createdAt }
            await MainActor.run {
                guard let self, generation == self.loadGeneration else { return }
                self.projects = sorted
                self.familyCounts = counts
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
        let admitted = projects.filter { !shapes(of: $0, for: family).isEmpty }
        return sort.sorted(admitted) { share(of: $0, for: family) }
    }

    /// The Sort's key for a project: its picked (else largest) admissible
    /// shape's diameter as a share of the picture's short edge.
    func share(of project: ProjectShapes, for family: DetectedShape.Family) -> Double {
        let shapes = shapes(of: project, for: family)
        let shape = selection[project.id].flatMap { id in shapes.first { $0.id == id } } ?? shapes.first
        guard let shape else { return 0 }
        let short = Double(min(project.frameSize.width, project.frameSize.height))
        return short > 0 ? shape.nativeDiameterPx / short : 0
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
        projects(for: family).compactMap { project in
            guard let shapeID = selection[project.id],
                  let shape = project.register.shapes.first(where: { $0.id == shapeID }) else { return nil }
            return ShapemationItem(id: project.id, title: project.capture.displayTitle, imageURL: project.representative.url,
                                   pixelSize: CGSize(width: project.register.representative.width, height: project.register.representative.height),
                                   shape: shape, frameFraction: project.representative.frameFraction)
        }
    }

    /// The plan under the mode — the framing rides along for `.frame` only.
    func plan(for family: DetectedShape.Family) -> ShapemationPlan? {
        ShapemationPlan.make(items: items(for: family), mode: mode, match: match(for: family), framing: mode == .frame ? framing : nil)
    }

    /// The Timing step's estimate for the pictures picked.
    func estimate(for family: DetectedShape.Family) -> String {
        timing.estimate(count: items(for: family).count)
    }

    func render(family: DetectedShape.Family, size: CGSize, store: ShapemationStore) {
        guard !isRendering, let plan = plan(for: family) else { return }
        let items = items(for: family)
        let reps = Dictionary(uniqueKeysWithValues: projects(for: family).map { ($0.id, $0.representative) })
        let id = UUID()
        let outputURL = store.outputURL(for: id)
        let posterURL = store.posterURL(for: id)
        let mode = self.mode
        let match = self.match(for: family), sort = self.sort, timing = self.timing
        // The record keeps the framing a `.frame` render was made with (§6),
        // and the filter the photos were narrowed by.
        let framing = mode == .frame ? plan.framing : nil
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
                    width: Int(size.width), height: Int(size.height), seconds: timing.totalSeconds(count: items.count),
                    fileName: outputURL.lastPathComponent, posterFileName: poster == nil ? nil : posterURL.lastPathComponent,
                    match: match, sort: sort, timing: timing, framing: framing,
                    filterTags: filterTags, filterText: filterText)
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
    case timing(DetectedShape.Family)
    case output(DetectedShape.Family)
}

/// What a launch hook stages in the builder once its projects have loaded.
enum ShapemationBuilderSeed {
    /// `LL_SHAPEMATION=family`: past the filters, on the shape step.
    case family
    /// `LL_SHAPEMATION=frame`: every project of the first family with shapes
    /// picked, `.frame` chosen, the Output step showing.
    case frame
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
    @State private var seeded = false

    var body: some View {
        ShapemationFiltersView(builder: builder)
        .navigationDestination(for: ShapemationBuildStep.self) { step in
            switch step {
            case .family: ShapemationFamilyView(builder: builder)
            case .match(let family): ShapemationMatchView(builder: builder, family: family)
            case .projects(let family): ShapemationProjectsView(builder: builder, family: family)
            case .mode(let family): ShapemationModeView(builder: builder, family: family)
            case .timing(let family): ShapemationTimingView(builder: builder, family: family)
            case .output(let family): ShapemationOutputView(builder: builder, store: store, family: family)
            }
        }
        .onAppear {
            if !builder.loaded {
                #if DEBUG
                if let chips = ListDebugHooks.chips { builder.tagSelection = chips }
                if let text = ListDebugHooks.queryText { builder.queryText = text }
                #endif
                builder.load(model: model)
            } else {
                applySeed()
            }
        }
        .onChange(of: builder.loaded) { _, _ in applySeed() }
    }

    /// The seed, once the projects are in: `family` steps past the filters;
    /// `frame` takes the first family with shapes, picks every one of its
    /// projects, sets the mode and pushes the stack to the Output step.
    private func applySeed() {
        guard let seed, builder.loaded, !seeded else { return }
        seeded = true
        switch seed {
        case .family:
            push?(.family)
        case .frame:
            guard let family = DetectedShape.Family.allCases.first(where: { (builder.familyCounts[$0] ?? 0) > 0 }) else { return }
            for project in builder.projects(for: family) where builder.selection[project.id] == nil {
                builder.toggle(project, family: family)
            }
            builder.mode = .frame
            push?(.output(family))
        }
    }
}

/// Step 1: Apply filters — the Gallery sidebar's Tags rows and its search,
/// over the photo and interval projects, so the shape step works a smaller
/// set. Optional: with nothing lit the count is the whole library and Next
/// still goes on.
struct ShapemationFiltersView: View {
    @ObservedObject var builder: ShapemationBuilder

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Narrow the photos before choosing the shape — the way the Gallery's Tags rows do.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SceneSearchField(text: $builder.queryText, placeholder: "Search titles and tags")
                tagsCard
                Text(countLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .padding(.bottom, 80)
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .navigationTitle("Apply filters")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                NavigationLink(value: ShapemationBuildStep.family) {
                    Text("Next · shape")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(LL.accent)
                .disabled(builder.filteredCount == 0)
            }
            .padding(16)
            .background(.regularMaterial)
        }
    }

    private var countLine: String {
        let n = builder.filteredCount
        return "\(n) photo project\(n == 1 ? "" : "s")"
    }

    /// The TAGS rows in the sidebar's idiom — a dot, the label, the count
    /// trailing, accent when on; Clear tags once any is.
    private var tagsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            LLSectionHeader("Tags")
            if builder.presentTags.isEmpty {
                Text(builder.tagSelection.isEmpty
                     ? "No tags on these photos yet — Auto rename & tag in the Gallery adds them. Search still narrows."
                     : "No photo carries every lit tag with these words.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(builder.presentTags, id: \.tag) { row in
                        let isOn = builder.tagSelection.contains(row.tag)
                        Button {
                            if isOn { builder.tagSelection.remove(row.tag) } else { builder.tagSelection.insert(row.tag) }
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(isOn ? LL.accent : Color.primary.opacity(0.25))
                                    .frame(width: 7, height: 7)
                                Text(SceneMetadata.label(for: row.tag))
                                    .font(.system(size: 14))
                                    .foregroundStyle(isOn ? LL.accent : .primary)
                                Spacer(minLength: 0)
                                Text("\(row.count)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(isOn ? LL.accent : .secondary)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(SceneMetadata.label(for: row.tag)), \(row.count)")
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
            }
            if !builder.tagSelection.isEmpty {
                Button {
                    builder.tagSelection = []
                } label: {
                    Text("Clear tags")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LL.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .llCard(cornerRadius: 18)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(builder.selection.count) of \(projects.count) picked")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                    // The order the photos play in — largest share first by
                    // default, so the movie reads as a zoom, not a shuffle.
                    Menu {
                        ForEach(ShapemationSort.allCases, id: \.self) { sort in
                            Button {
                                builder.sort = sort
                            } label: {
                                if builder.sort == sort { Label(sort.title, systemImage: "checkmark") } else { Text(sort.title) }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Sort").font(.system(size: 13)).foregroundStyle(.secondary)
                            Text(builder.sort.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LL.accent)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(LL.accent)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Sort: \(builder.sort.title)")
                }
                LazyVStack(spacing: 10) {
                    ForEach(projects) { project in
                        ShapemationProjectRow(builder: builder, project: project, family: family)
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

/// Step 3: mode.
struct ShapemationModeView: View {
    @ObservedObject var builder: ShapemationBuilder
    let family: DetectedShape.Family

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("How should the photos be laid out?")
                    .font(.system(size: 17, weight: .semibold))
                ForEach(ShapemationMode.allCases, id: \.self) { mode in
                    Button { builder.mode = mode } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: modeSymbol(mode))
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(builder.mode == mode ? .white : LL.accent)
                                .frame(width: 34, height: 34)
                                .background(builder.mode == mode ? LL.accent : LL.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.title).font(.system(size: 16, weight: .semibold))
                                Text(mode.summary).font(.system(size: 13)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Image(systemName: builder.mode == mode ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundStyle(builder.mode == mode ? LL.accent : Color.secondary.opacity(0.5))
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .llCard(cornerRadius: 16)
                }
                if let plan = builder.plan(for: family) {
                    Text(planSummary(plan))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if builder.mode == .crop {
                    Text("These photos share no common area once the shape is locked — crop mode has nothing to show. Pick fewer, or use stack mode.")
                        .font(.system(size: 12))
                        .foregroundStyle(LL.accentDeep)
                }
            }
            .padding(16)
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .navigationTitle("Mode")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                NavigationLink(value: ShapemationBuildStep.timing(family)) {
                    Text("Next · timing")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(LL.accent)
                .disabled(builder.plan(for: family) == nil)
            }
            .padding(16)
            .background(.regularMaterial)
        }
    }

    private func modeSymbol(_ mode: ShapemationMode) -> String {
        switch mode {
        case .stack: return "rectangle.stack"
        case .crop: return "crop"
        case .frame: return "viewfinder.rectangular"
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
            // The frame is fixed; the Output step sets it and says what is flagged.
            let last = Int(plan.placements.last?.targetSizePx ?? plan.shapeSizePx)
            let sizes = last == shape ? "\(shape) px across" : "\(shape) px across at the first photo, \(last) at the last"
            let flagged = plan.flagged.count
            let tail = flagged == 0 ? "every photo fills it." : "\(flagged) photo\(flagged == 1 ? "" : "s") flagged — see Output."
            return "Frame \(Int(c.width))×\(Int(c.height)); the shape is \(sizes); \(tail)"
        }
    }
}

/// Step 4: output size, then render. Under `.frame` the step is the frame
/// itself (docs/shapemation/output-frame.md §6, code first 2026-09-19):
/// aspect and size, the face's size and place at the first and last photo,
/// the ease, a scrub over the photos through the evaluator with each one's
/// verdict, and the line that says what the frame leaves flagged.
struct ShapemationOutputView: View {
    @ObservedObject var builder: ShapemationBuilder
    @ObservedObject var store: ShapemationStore
    let family: DetectedShape.Family
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
                } else if builder.mode == .frame {
                    Text("Output frame")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Every photo is scaled and placed to put its \(family.title.lowercased()) here. One that cannot reach the frame's edges, or would be blown up to, is flagged and kept.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    frameCard
                    scrubCard(plan)
                    if let error = builder.renderError {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    }
                    estimate
                    createButton(enabled: plan != nil) { builder.render(family: family, size: builder.framing.outputSize, store: store) }
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
                    createButton(enabled: !options.isEmpty) {
                        if let option = chosen ?? options.first { builder.render(family: family, size: option.size, store: store) }
                    }
                }
            }
            .padding(16)
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .navigationTitle("Output")
        .sheet(item: $playing) { record in
            ShapemationPlayerSheet(record: record, store: store)
        }
        .onAppear { refreshPreview() }
        .onChange(of: scrub) { _, _ in refreshPreview() }
        .onChange(of: builder.framing) { _, _ in refreshPreview() }
        .onChange(of: builder.mode) { _, _ in refreshPreview() }
    }

    /// What Timing decided, restated where Create is pressed.
    private var estimate: some View {
        VStack(alignment: .leading, spacing: 3) {
            let count = builder.items(for: family).count
            Text("\(count) photo\(count == 1 ? "" : "s") · \(builder.timing.summary)")
            Text(String(format: "%.1f s of playback · %d frames · %@",
                        builder.timing.totalSeconds(count: count), builder.timing.totalFrames(count: count),
                        builder.sort.title.lowercased()))
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private func createButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Create Shape-mation")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(LL.accent)
        .disabled(!enabled)
    }

    // MARK: - The output frame

    private var startSizePct: Int { Int((builder.startKey.size * 100).rounded()) }
    private var endSizePct: Int { Int((builder.endKey.size * 100).rounded()) }

    /// Aspect chips and the size menu, the face's size and place at the
    /// start and the end, the ease — the Match step's label-above style.
    private var frameCard: some View {
        let size = builder.framing.outputSize
        return VStack(alignment: .leading, spacing: 16) {
            group("Aspect") {
                FlowChips(options: ShapemationFraming.aspectPresets.map(\.label), selected: builder.frameAspect.label, title: { $0 }) { label in
                    if let aspect = ShapemationFraming.aspectPresets.first(where: { $0.label == label }) { builder.frameAspect = aspect }
                }
            }
            HStack {
                Text("Size").font(.system(size: 15))
                Spacer()
                Text("\(Int(size.width))×\(Int(size.height))").font(.system(size: 13)).foregroundStyle(.secondary)
                Picker("Size", selection: $builder.frameLongEdge) {
                    ForEach(ShapemationFraming.sizePresets, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(.secondary)
                .accessibilityLabel("Size: \(builder.frameLongEdge) long edge")
            }
            .frame(minHeight: 32)
            group("Face size") {
                Stepper("Start \(startSizePct) % of the height",
                        value: Binding(get: { startSizePct }, set: { builder.setStartSize(Double($0) / 100) }),
                        in: ShapemationBuilder.faceSizeRange, step: ShapemationBuilder.faceSizeStep)
                    .font(.system(size: 14))
                Stepper("End \(endSizePct) %" + (builder.endSizeFollowsStart ? " · Same" : ""),
                        value: Binding(get: { endSizePct }, set: { builder.setEndSize(Double($0) / 100) }),
                        in: ShapemationBuilder.faceSizeRange, step: ShapemationBuilder.faceSizeStep)
                    .font(.system(size: 14))
            }
            group("Face place") {
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 6) {
                        ShapemationFacePlacePicker(aspect: size, selected: builder.startKey.face, name: "start") { builder.setStartFace($0) }
                        Text("Start").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 6) {
                        ShapemationFacePlacePicker(aspect: size, selected: builder.endKey.face, name: "end") { builder.setEndFace($0) }
                        Text(builder.endPlaceFollowsStart ? "End · Same" : "End").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            group("Ease") {
                Picker("Ease", selection: Binding(get: { builder.framing.ease }, set: { builder.setEase($0) })) {
                    ForEach(ShapemationFraming.Ease.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
        .padding(16)
        .llCard(cornerRadius: 18)
    }

    /// The scrub: photo *i* through the evaluator, its title and verdict, the
    /// slider over the photos, and the flagged line.
    private func scrubCard(_ plan: ShapemationPlan?) -> some View {
        let count = builder.items(for: family).count
        let size = builder.framing.outputSize
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
                if let current { verdictBadge(current.placement) }
            }
            if count > 1 {
                Slider(value: $scrub, in: 0...Double(count - 1), step: 1)
                    .tint(LL.accent)
                    .accessibilityLabel("Scrub")
                    .accessibilityValue("Photo \(Int(scrub) + 1) of \(count)")
                Text("Photo \(Int(scrub) + 1) of \(count)")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            Text(builder.feasibilitySummary(for: family))
                .font(.system(size: 12))
                .foregroundStyle(plan?.flagged.isEmpty == false ? LL.accentDeep : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .llCard(cornerRadius: 18)
    }

    private func verdictBadge(_ placement: ShapemationPlan.Placement) -> some View {
        let flagged = placement.feasibility.verdict.isFlagged
        return Text(ShapemationBuilder.verdictLabel(placement))
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(flagged ? LL.amber.opacity(0.25) : LL.levelGood.opacity(0.2), in: Capsule())
            .foregroundStyle(.primary)
            .lineLimit(1)
            .accessibilityLabel("Verdict: \(ShapemationBuilder.verdictLabel(placement))")
    }

    private func refreshPreview() {
        guard builder.mode == .frame else { return }
        let count = builder.items(for: family).count
        if scrub > Double(max(count - 1, 0)) { scrub = Double(max(count - 1, 0)) }
        builder.framePreview(index: Int(scrub), family: family)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14))
            content()
        }
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
