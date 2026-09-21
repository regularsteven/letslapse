import SwiftUI
import LetsLapseKit

// The Shape-mation sheet — reached from the Create tab's "Create Shape-mation"
// row. Three doors: Find shapes (analyse the library into per-project
// registers), Create shape slideshow (filter by tag and words the way the
// Gallery does, pick a shape family, the projects and their instances, a
// mode, an output size), and List Shape-mations (play, share, delete). Owns
// its NavigationStack like the Presets sheet.
//
// Code first, 2026-09-10 (Steven's call); SVG mirrors owed after sign-off —
// see docs/design/iOS/INDEX.md.

enum ShapemationRoute: Hashable {
    case find
    /// The builder; with a record's id, opened on that record's board with
    /// its members locked (the list's Re-render). The record rides in the
    /// route rather than in a state the destination closure would read —
    /// a read there is not a dependency, so the closure kept seeing nil
    /// (2026-09-20).
    case build(rerender: UUID? = nil)
    case list
}

struct ShapemationHomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ShapemationStore.shared
    /// Type-erased: the builder pushes its own step values onto this stack.
    @State private var path: NavigationPath
    @State private var registerCounts: (analysed: Int, withShapes: Int, families: [DetectedShape.Family: Int])?
    /// The Sequence board is on screen: the Mac sheet grows to 900 × 720 for it.
    @State private var boardShowing = false
    /// A pushed route's screen has appeared — the hook's push is verified by
    /// this, not by the path: a push the stack swallows leaves the path
    /// non-empty and the home screen showing (2026-09-20).
    @State private var landed = false

    private let initialRoutes: [ShapemationRoute]
    /// What the builder stages once its projects have loaded (the
    /// `LL_SHAPEMATION=family|frame|board` hooks); nil for a hand-driven sheet.
    private let builderSeed: ShapemationBuilderSeed?

    init(initialPath: [ShapemationRoute] = [], builderSeed: ShapemationBuilderSeed? = nil) {
        initialRoutes = initialPath
        self.builderSeed = builderSeed
        _path = State(initialValue: NavigationPath())
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    doors
                    if let counts = registerCounts { registerSummary(counts) }
                }
                .padding(16)
            }
            .background(LL.screenBackground.ignoresSafeArea())
            .navigationTitle("Shape-mation")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: ShapemationRoute.self) { route in
                Group {
                    switch route {
                    case .find: FindShapesView(onFinished: refreshCounts)
                    case .build(let rerenderID):
                        let record = rerenderID.flatMap { id in store.records.first { $0.id == id } }
                        ShapemationBuilderView(store: store, seed: record.map { .rerender($0) } ?? builderSeed,
                                               push: { path.append($0) }, pop: { n in path.removeLast(min(n, path.count)) },
                                               onBoard: { boardShowing = $0 }, close: { dismiss() })
                    case .list:
                        ShapemationListView(store: store) { record in
                            LLog("shapemation: re-render asked for \(record.id.uuidString.prefix(8)); opening the builder on its board")
                            path.append(ShapemationRoute.build(rerender: record.id))
                        }
                    }
                }
                .onAppear { landed = true }
            }
        }
        .onAppear(perform: refreshCounts)
        // A sheet presented with a pre-filled path drops it on iOS (the
        // destinations register after the first body); push once it is up.
        // On the Mac the sheet's content is built before the hook's state
        // write lands (2026-09-19: the first task saw no routes at all), so
        // the task is keyed on the routes and runs again when they arrive;
        // a push the stack drops is tried again while it stays empty.
        .task(id: initialRoutes) {
            guard path.isEmpty, !initialRoutes.isEmpty else { return }
            for attempt in 1...4 {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !landed else { return }
                // A swallowed push leaves the path non-empty and nothing
                // shown, and the next push renders (the door pressed by hand
                // always lands) — so push again rather than start the path
                // over, which leaves the sheet blank (2026-09-20).
                for route in initialRoutes { path.append(route) }
                try? await Task.sleep(nanoseconds: 700_000_000)
                if landed { return }
                LLog("shapemation: the hook's push was dropped (attempt \(attempt)); pushing again")
            }
        }
        #if os(macOS)
        .frame(width: boardShowing ? ShapemationBoardView.wideSheet.width : 560,
               height: boardShowing ? ShapemationBoardView.wideSheet.height : 680)
        .animation(.easeInOut(duration: 0.25), value: boardShowing)
        #endif
    }

    private var intro: some View {
        Text("Find a shape that repeats across your photos — a clock face, a sign, a window — and stack the photos so the shape holds still while the world changes behind it.")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
    }

    private var doors: some View {
        VStack(spacing: 0) {
            door(.find, icon: "viewfinder.circle", color: LL.accent, title: "Find shapes",
                 detail: "Analyse projects not yet checked")
            Divider().padding(.leading, 58)
            door(.build(), icon: "square.stack.3d.down.right", color: Color(red: 0x6E / 255, green: 0x5A / 255, blue: 0xC8 / 255),
                 title: "Create shape slideshow", detail: "Filter by tag, pick the shape, the projects, and a mode")
            Divider().padding(.leading, 58)
            door(.list, icon: "list.and.film", color: LL.accentDeep, title: "List Shape-mations",
                 detail: store.records.isEmpty ? "None yet" : "\(store.records.count) video\(store.records.count == 1 ? "" : "s")")
        }
        .llCard(cornerRadius: 18)
    }

    private func door(_ route: ShapemationRoute, icon: String, color: Color, title: String, detail: String) -> some View {
        Button { path.append(route) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func registerSummary(_ counts: (analysed: Int, withShapes: Int, families: [DetectedShape.Family: Int])) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SHAPE REGISTER")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if counts.analysed == 0 {
                Text("No project has been analysed yet. Start with Find shapes.")
                    .font(.system(size: 14))
            } else {
                Text("\(counts.analysed) project\(counts.analysed == 1 ? "" : "s") analysed · \(counts.withShapes) with shapes")
                    .font(.system(size: 14))
                HStack(spacing: 8) {
                    ForEach(DetectedShape.Family.allCases, id: \.self) { family in
                        if let n = counts.families[family], n > 0 {
                            Label("\(n)", systemImage: family.symbolName)
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(LL.accent.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .llCard(cornerRadius: 18)
    }

    private func refreshCounts() {
        store.load()
        model.refreshShapeSummaries()
        let captures = model.liveCaptures({ var q = LibraryIndex.ProjectQuery(); q.categories = [.photo, .interval]; return q }())
        let folders = captures.map { model.projectFolderURL(for: $0) }
        Task.detached(priority: .utility) {
            var analysed = 0, withShapes = 0
            var families: [DetectedShape.Family: Int] = [:]
            for folder in folders {
                guard let reg = ShapeRegister.load(inProjectFolder: folder) else { continue }
                if reg.isAnalysed { analysed += 1 }
                if !reg.shapes.isEmpty { withShapes += 1 }
                for (f, n) in reg.families() { families[f, default: 0] += n }
            }
            let result = (analysed, withShapes, families)
            await MainActor.run { registerCounts = result }
        }
    }
}
