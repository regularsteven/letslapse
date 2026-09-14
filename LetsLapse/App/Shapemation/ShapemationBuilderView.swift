import SwiftUI
import CoreGraphics
import LetsLapseKit

// "Create shape slideshow": pick a shape family from what the registers hold,
// say how strict to be about it (Match), pick the projects (and, where a
// project has several, which instance) in the order they will play (Sort),
// pick a mode, how fast it plays (Timing), then an output size from what the
// picked pictures produce — and render. Every step is one screen in the
// sheet's NavigationStack. Match, Sort and Timing are the 2026-09-11 designs
// (docs/design/iOS/shapemation.builder.{match.*,projects,timing*,output}).

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

    @Published private(set) var renderProgress: ShapemationRenderer.Progress?
    @Published private(set) var rendered: ShapemationStore.Record?
    @Published private(set) var renderError: String?
    @Published private(set) var isRendering = false

    func load(model: AppModel) {
        let captures = model.allLiveCaptures().filter { !$0.isScannerCapture && $0.kind == .photos }
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
                self?.projects = sorted
                self?.familyCounts = counts
                self?.loaded = true
            }
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
    /// (by the share of the frame of the shape that would be picked).
    func projects(for family: DetectedShape.Family) -> [ProjectShapes] {
        let admitted = projects.filter { !shapes(of: $0, for: family).isEmpty }
        switch sort {
        case .newestFirst: return admitted
        case .largestFirst: return admitted.sorted { share(of: $0, for: family) > share(of: $1, for: family) }
        case .smallestFirst: return admitted.sorted { share(of: $0, for: family) < share(of: $1, for: family) }
        }
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

    func plan(for family: DetectedShape.Family) -> ShapemationPlan? {
        ShapemationPlan.make(items: items(for: family), mode: mode, match: match(for: family))
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
                    match: match, sort: sort, timing: timing)
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
    case match(DetectedShape.Family)
    case projects(DetectedShape.Family)
    case mode(DetectedShape.Family)
    case timing(DetectedShape.Family)
    case output(DetectedShape.Family)
}

/// Step 1: which shape.
struct ShapemationBuilderView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: ShapemationStore
    @StateObject private var builder = ShapemationBuilder()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !builder.loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if builder.familyCounts.isEmpty {
                    Text("No shapes in the register yet. Run Find shapes first.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .llCard(cornerRadius: 18)
                } else {
                    Text("Which shape holds still?")
                        .font(.system(size: 17, weight: .semibold))
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
        .navigationDestination(for: ShapemationBuildStep.self) { step in
            switch step {
            case .match(let family): ShapemationMatchView(builder: builder, family: family)
            case .projects(let family): ShapemationProjectsView(builder: builder, family: family)
            case .mode(let family): ShapemationModeView(builder: builder, family: family)
            case .timing(let family): ShapemationTimingView(builder: builder, family: family)
            case .output(let family): ShapemationOutputView(builder: builder, store: store, family: family)
            }
        }
        .onAppear { if !builder.loaded { builder.load(model: model) } }
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
                Text("How should the photos stack?")
                    .font(.system(size: 17, weight: .semibold))
                ForEach(ShapemationMode.allCases, id: \.self) { mode in
                    Button { builder.mode = mode } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: mode == .stack ? "rectangle.stack" : "crop")
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

    private func planSummary(_ plan: ShapemationPlan) -> String {
        let c = plan.canvas.size
        let shape = Int(plan.shapeSizePx)
        switch plan.mode {
        case .stack:
            return "Canvas \(Int(c.width))×\(Int(c.height)) holds every photo; the shape is \(shape) px across."
        case .crop:
            let u = plan.unionCanvas.size
            return "Crop \(Int(c.width))×\(Int(c.height)) of a \(Int(u.width))×\(Int(u.height)) stack; the shape is \(shape) px across."
        }
    }
}

/// Step 4: output size, then render.
struct ShapemationOutputView: View {
    @ObservedObject var builder: ShapemationBuilder
    @ObservedObject var store: ShapemationStore
    let family: DetectedShape.Family
    @State private var chosen: ShapemationPlan.OutputOption?
    @State private var playing: ShapemationStore.Record?

    var body: some View {
        let plan = builder.plan(for: family)
        let options = plan?.outputOptions() ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let record = builder.rendered {
                    doneCard(record)
                } else if let progress = builder.renderProgress {
                    progressCard(progress)
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
                    // What Timing decided, restated where Create is pressed.
                    VStack(alignment: .leading, spacing: 3) {
                        let count = builder.items(for: family).count
                        Text("\(count) photo\(count == 1 ? "" : "s") · \(builder.timing.summary)")
                        Text(String(format: "%.1f s of playback · %d frames · %@",
                                    builder.timing.totalSeconds(count: count), builder.timing.totalFrames(count: count),
                                    builder.sort.title.lowercased()))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    Button {
                        if let option = chosen ?? options.first { builder.render(family: family, size: option.size, store: store) }
                    } label: {
                        Text("Create Shape-mation")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LL.accent)
                    .disabled(options.isEmpty)
                }
            }
            .padding(16)
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .navigationTitle("Output")
        .sheet(item: $playing) { record in
            ShapemationPlayerSheet(record: record, store: store)
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
