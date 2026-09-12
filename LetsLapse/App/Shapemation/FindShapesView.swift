import SwiftUI
import LetsLapseKit

/// "Find shapes": which projects to look at, with which detector, then a
/// determinate progress card and a per-project account of what was found.
/// Rebuilt 2026-09-12 as a test bench as much as a feature: every detection
/// mode the Kit has (and, on a Mac, the benchmark rig's Python detectors)
/// can be run over every project, the ones nothing was found in, or a ticked
/// few, and run again after the found shapes are cleared.
struct FindShapesView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var finder = ShapeFinder()
    var onFinished: () -> Void = {}

    @State private var inventory: [ShapeFinder.Candidate] = []
    @State private var skippedVideo = 0
    @State private var mode = ShapeDetectionMode.load()
    @State private var scope: ShapeFinder.Scope = .pending
    @State private var chosen: Set<UUID> = []
    @State private var filter = ""
    @State private var showOptions = true
    @State private var showRemoveConfirm = false
    @State private var removedNote: String?
    @State private var scores: [ShapeDetectorFeedback.Score] = []
    @State private var showClearScores = false

    private var selected: [ShapeFinder.Candidate] { ShapeFinder.select(inventory, scope: scope, chosen: chosen) }
    private var alreadyDone: Int { inventory.filter(\.isCurrent).count }
    private var shownForChoosing: [ShapeFinder.Candidate] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? inventory : inventory.filter { $0.title.lowercased().contains(needle) }
    }
    private var externalUnavailable: Bool {
        #if os(macOS)
        return mode.engine.isExternal && !ExternalShapeDetector.isAvailable
        #else
        return mode.engine.isExternal
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let progress = finder.progress {
                    progressCard(progress)
                } else if let summary = finder.summary, !showOptions {
                    summaryCard(summary)
                } else {
                    detectorCard
                    scopeCard
                    runCard
                    if !scores.isEmpty {
                        reportCard
                    }
                }
            }
            .padding(16)
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .navigationTitle("Find shapes")
        .onAppear {
            reload()
            #if DEBUG
            // `LL_SHAPES_SCOPE=pending|all|empty`, `LL_SHAPES_MODE=<engine>`
            // (a `ShapeDetectionMode.Engine` raw value) and `LL_SHAPES_RUN=1`
            // stage this sheet for a headless run: the menus cannot be driven
            // from a screenshot script, and the progress and results cards
            // are only reachable through a run.
            let env = ProcessInfo.processInfo.environment
            if let raw = env["LL_SHAPES_SCOPE"], let hook = ShapeFinder.Scope(rawValue: raw) { scope = hook }
            if let raw = env["LL_SHAPES_MODE"], let engine = ShapeDetectionMode.Engine(rawValue: raw) { mode.engine = engine }
            if env["LL_SHAPES_RUN"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { start() } }
            #endif
        }
        .onDisappear {
            if finder.isRunning { finder.cancel() }
        }
        .onChange(of: finder.summary) { summary in
            guard summary != nil else { return }
            showOptions = false
            model.refreshShapeSummaries()
            reload()
            onFinished()
        }
        .confirmationDialog("Remove every found shape?", isPresented: $showRemoveConfirm, titleVisibility: .visible) {
            Button("Remove found shapes", role: .destructive) {
                let n = ShapeFinder.removeFoundShapes(in: model)
                removedNote = "\(n) register\(n == 1 ? "" : "s") cleared"
                model.refreshShapeSummaries()
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shapes the detector found are dropped from every photo project. Shapes you drew or kept on the viewfinder stay. Those projects are analysed again on the next run.")
        }
    }

    private func reload() {
        let inv = ShapeFinder.inventory(in: model)
        inventory = inv.projects
        skippedVideo = inv.skippedVideo
        chosen = chosen.intersection(inv.projects.map(\.id))
        scores = ShapeDetectorFeedback.shared.summary()
    }

    // MARK: - The detectors' score sheet

    /// What `ShapeDetectorFeedback` has recorded: per engine, how often it
    /// ran, what it proposed, how much of that another engine agreed with,
    /// and the person's verdicts from the Masks tab.
    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Detector report")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear…") { showClearScores = true }
                    .font(.system(size: 11.5))
            }
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("engine").gridColumnAlignment(.leading)
                    Text("runs"); Text("found"); Text("agreed"); Text("hits"); Text("passed over"); Text("missed"); Text("ms")
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                ForEach(scores) { score in
                    GridRow {
                        Text(score.engine.title).gridColumnAlignment(.leading).lineLimit(1)
                        Text("\(score.runs)")
                        Text("\(score.proposed)")
                        Text(score.proposed > 0 ? "\(score.agreed)" : "–")
                        Text("\(score.accepted)")
                        Text("\(score.rejected)")
                        Text("\(score.missed)")
                        Text(score.medianMs.map { "\($0)" } ?? "–")
                    }
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                }
            }
            Text("Hits and passed-over are your Add and Clear in the editor's Masks tab (a shape the register already held counts as a hit); missed is a shape you added that the engine did not propose although it ran; agreed is a proposal another engine also made in a Use all run. Shapes found by several engines are scored once, for all of them.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .llCard(cornerRadius: 18)
        .confirmationDialog("Clear the detector report?", isPresented: $showClearScores, titleVisibility: .visible) {
            Button("Clear report", role: .destructive) {
                ShapeDetectorFeedback.shared.clear()
                scores = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every recorded run and verdict is deleted. Shapes in the projects are not touched.")
        }
    }

    private func start() {
        let todo = selected
        guard !todo.isEmpty else { return }
        removedNote = nil
        showOptions = false
        finder.run(mode: mode, candidates: todo, alreadyDone: alreadyDone, skippedVideo: skippedVideo)
    }

    // MARK: - Options

    private var detectorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Detector")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Detector", selection: $mode.engine) {
                Text(ShapeDetectionMode.Engine.all.title).tag(ShapeDetectionMode.Engine.all)
                Divider()
                ForEach(ShapeDetectionMode.Engine.kitEngines) { engine in
                    Text(engine.title).tag(engine)
                }
                #if os(macOS)
                Divider()
                ForEach(ShapeDetectionMode.Engine.externalEngines) { engine in
                    Text(engine.title).tag(engine)
                }
                #endif
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Text(mode.engine.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if externalUnavailable {
                #if os(macOS)
                Text(ExternalShapeDetector.availability.detail + " (Settings ▸ Advanced).")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                #else
                Text("The Python detectors run on a Mac only.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                #endif
            }
            dialRow("Sensitivity") {
                Picker("Sensitivity", selection: $mode.search.sensitivity) {
                    ForEach(ShapeSearch.Sensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            dialRow("Size") {
                Picker("Size", selection: $mode.search.size) {
                    ForEach(ShapeSearch.Size.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            dialRow("Family") {
                Picker("Family", selection: $mode.search.family) {
                    ForEach(ShapeSearch.Family.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            if mode.engine.isExternal {
                Text("The Python detectors use the benchmark's own gates; the dials above do not reach them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .llCard(cornerRadius: 18)
    }

    private func dialRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 72, alignment: .leading)
            content()
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(mode.engine.isExternal)
        }
    }

    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Projects")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(selected.count) of \(inventory.count)")
                    .font(.system(size: 11))
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            Picker("Projects", selection: $scope) {
                ForEach(ShapeFinder.Scope.allCases) { scope in
                    Text("\(scope.title) · \(ShapeFinder.select(inventory, scope: scope, chosen: chosen).count)").tag(scope)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Text(scope.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(alreadyDone) analysed by the current detector · \(inventory.filter { $0.isAnalysed && !$0.isCurrent }.count) by an older one · \(inventory.filter { !$0.isAnalysed }.count) never · \(skippedVideo) video shoot\(skippedVideo == 1 ? "" : "s") left out")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if scope == .chosen {
                chooser
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .llCard(cornerRadius: 18)
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Filter by name", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button("Tick shown") { chosen.formUnion(shownForChoosing.map(\.id)) }
                    .font(.system(size: 11.5))
                Button("Clear") { chosen = [] }
                    .font(.system(size: 11.5))
                    .disabled(chosen.isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shownForChoosing) { candidate in
                        chooserRow(candidate)
                    }
                    if shownForChoosing.isEmpty {
                        Text("No project matches.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                }
            }
            .frame(maxHeight: 240)
            .background(LL.screenBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func chooserRow(_ candidate: ShapeFinder.Candidate) -> some View {
        let ticked = chosen.contains(candidate.id)
        return Button {
            if ticked { chosen.remove(candidate.id) } else { chosen.insert(candidate.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: ticked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(ticked ? LL.accent : .secondary)
                Text(candidate.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(registerState(candidate))
                    .font(.system(size: 10.5))
                    .monospaced()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func registerState(_ c: ShapeFinder.Candidate) -> String {
        if !c.isAnalysed { return c.shapeCount > 0 ? "\(c.shapeCount) drawn" : "not analysed" }
        let shapes = c.shapeCount == 0 ? "none" : "\(c.shapeCount) shape\(c.shapeCount == 1 ? "" : "s")"
        return c.isCurrent ? shapes : shapes + " · older detector"
    }

    private var runCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                start()
            } label: {
                Text(selected.isEmpty ? "Nothing to analyse" : "Find shapes in \(selected.count) project\(selected.count == 1 ? "" : "s")")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(LL.accent)
            .disabled(selected.isEmpty || externalUnavailable)
            Text("One picture per project — the rendered blend where there is one, else the middle frame — is searched for circles, ovals, squares and rectangles. Found shapes replace the last run's; shapes you drew or kept stay.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Remove found shapes…", role: .destructive) { showRemoveConfirm = true }
                    .font(.system(size: 12))
                if let removedNote {
                    Text(removedNote)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .llCard(cornerRadius: 18)
    }

    // MARK: - Progress

    private func progressCard(_ progress: ShapeFinder.Progress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "viewfinder.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LL.accent)
                Text("Analysing \(progress.done + 1) of \(progress.total)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Stop") { finder.cancel() }
                    .font(.system(size: 13))
            }
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .tint(LL.accent)
            Text(progress.current)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
                Text(elapsedLine(progress, at: context.date))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .llCard(cornerRadius: 18)
    }

    private func elapsedLine(_ progress: ShapeFinder.Progress, at date: Date) -> String {
        let elapsed = max(0, date.timeIntervalSince(progress.startedAt))
        var line = String(format: "%.0f s elapsed", elapsed)
        if progress.done > 0 {
            let perProject = elapsed / Double(progress.done)
            line += String(format: " · %.1f s per project", perProject)
            line += String(format: " · about %.0f s left", perProject * Double(progress.total - progress.done))
        }
        return line + " · " + mode.engine.title
    }

    // MARK: - Results

    private func summaryCard(_ summary: ShapeFinder.Summary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text(summary.analysed == 0 ? "Nothing analysed" : "\(summary.analysed) project\(summary.analysed == 1 ? "" : "s") analysed in \(seconds(summary.totalMs))")
                    .font(.system(size: 17, weight: .semibold))
                Text("\(summary.mode.engine.title) · \(summary.mode.search.token)" + (summary.cancelled ? " · stopped early" : ""))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("\(summary.withShapes) with at least one shape")
                    .font(.system(size: 14))
                HStack(spacing: 8) {
                    ForEach(DetectedShape.Family.allCases, id: \.self) { family in
                        let n = summary.families[family] ?? 0
                        Label("\(n)", systemImage: family.symbolName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(n == 0 ? .tertiary : .primary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background((n == 0 ? Color.secondary : LL.accent).opacity(0.12), in: Capsule())
                    }
                }
                if summary.unreadable > 0 {
                    Text("\(summary.unreadable) picture\(summary.unreadable == 1 ? "" : "s") could not be read.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("Run again") { start() }
                        .buttonStyle(.borderedProminent)
                        .tint(LL.accent)
                        .disabled(selected.isEmpty)
                    Button("Change options") { showOptions = true }
                }
                .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .llCard(cornerRadius: 18)

            if !summary.results.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("By project")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f ms median", median(summary.results.map { Double($0.milliseconds) })))
                            .font(.system(size: 11))
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(summary.results) { result in
                            resultRow(result)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .llCard(cornerRadius: 18)
            }
        }
    }

    private func resultRow(_ result: ShapeFinder.ProjectResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(result.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(DetectedShape.Family.allCases, id: \.self) { family in
                        if let n = result.families[family], n > 0 {
                            Label("\(n)", systemImage: family.symbolName)
                                .font(.system(size: 11))
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    if result.shapes == 0 {
                        Text(result.failed ? "failed" : "none")
                            .font(.system(size: 11))
                            .foregroundStyle(result.failed ? Color.orange : Color.secondary)
                    }
                }
                Text("\(result.milliseconds) ms")
                    .font(.system(size: 11))
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            if let note = result.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(result.failed ? Color.orange : Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    private func seconds(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
}
