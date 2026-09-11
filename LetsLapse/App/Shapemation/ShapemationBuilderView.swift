import SwiftUI
import CoreGraphics
import LetsLapseKit

// "Create shape slideshow": pick a shape family from what the registers hold,
// pick the projects (and, where a project has several, which instance), pick
// a mode, then an output size from what the picked pictures produce — and
// render. Every step is one screen in the sheet's NavigationStack.

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
    }

    @Published private(set) var projects: [ProjectShapes] = []
    @Published private(set) var familyCounts: [DetectedShape.Family: Int] = [:]
    /// captureID → the chosen shape instance.
    @Published var selection: [UUID: UUID] = [:]
    @Published var mode: ShapemationMode = .stack
    @Published var thumbnails: [UUID: CGImage] = [:]
    @Published private(set) var loaded = false

    @Published private(set) var renderProgress: ShapemationRenderer.Progress?
    @Published private(set) var rendered: ShapemationStore.Record?
    @Published private(set) var renderError: String?
    @Published private(set) var isRendering = false

    func load(model: AppModel) {
        let captures = model.captures.filter { !$0.isScannerCapture && $0.kind == .photos }
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

    func projects(for family: DetectedShape.Family) -> [ProjectShapes] {
        projects.filter { !$0.shapes(of: family).isEmpty }
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
        } else if let first = project.shapes(of: family).first {
            selection[project.id] = first.id
        }
    }

    /// The picked items in capture order.
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
        ShapemationPlan.make(items: items(for: family), mode: mode)
    }

    func render(family: DetectedShape.Family, size: CGSize, store: ShapemationStore) {
        guard !isRendering, let plan = plan(for: family) else { return }
        let items = items(for: family)
        let reps = Dictionary(uniqueKeysWithValues: projects(for: family).map { ($0.id, $0.representative) })
        let id = UUID()
        let outputURL = store.outputURL(for: id)
        let posterURL = store.posterURL(for: id)
        let mode = self.mode
        isRendering = true
        renderError = nil
        rendered = nil
        renderProgress = ShapemationRenderer.Progress(done: 0, total: items.count, title: "")
        Task.detached(priority: .userInitiated) { [weak self] in
            let renderer = ShapemationRenderer()
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
                    width: Int(size.width), height: Int(size.height), seconds: renderer.secondsPerItem * Double(items.count),
                    fileName: outputURL.lastPathComponent, posterFileName: poster == nil ? nil : posterURL.lastPathComponent)
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
    case projects(DetectedShape.Family)
    case mode(DetectedShape.Family)
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
                            NavigationLink(value: ShapemationBuildStep.projects(family)) {
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
            case .projects(let family): ShapemationProjectsView(builder: builder, family: family)
            case .mode(let family): ShapemationModeView(builder: builder, family: family)
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
                Text("\(builder.selection.count) of \(projects.count) picked")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
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
        let shapes = project.shapes(of: family)
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
                    Text("\(Int(first.nativeDiameterPx)) px across")
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
                NavigationLink(value: ShapemationBuildStep.output(family)) {
                    Text("Next · output")
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
