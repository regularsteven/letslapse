import SwiftUI
import LetsLapseKit

// The Shape-mation sheet — reached from the Create tab's "Create Shape-mation"
// row. Three doors: Find shapes (analyse the library into per-project
// registers), Create shape slideshow (pick a shape family, the projects and
// their instances, a mode, an output size), and List Shape-mations (play,
// share, delete). Owns its NavigationStack like the Presets sheet.
//
// Code first, 2026-09-10 (Steven's call); SVG mirrors owed after sign-off —
// see docs/design/iOS/INDEX.md.

enum ShapemationRoute: Hashable {
    case find
    case build
    case list
}

struct ShapemationHomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ShapemationStore.shared
    /// Type-erased: the builder pushes its own step values onto this stack.
    @State private var path: NavigationPath
    @State private var registerCounts: (analysed: Int, withShapes: Int, families: [DetectedShape.Family: Int])?

    private let initialRoutes: [ShapemationRoute]

    init(initialPath: [ShapemationRoute] = []) {
        initialRoutes = initialPath
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
                switch route {
                case .find: FindShapesView(onFinished: refreshCounts)
                case .build: ShapemationBuilderView(store: store)
                case .list: ShapemationListView(store: store)
                }
            }
        }
        .onAppear(perform: refreshCounts)
        // A sheet presented with a pre-filled path drops it on iOS (the
        // destinations register after the first body); push once it is up.
        .task {
            guard path.isEmpty, !initialRoutes.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 80_000_000)
            for route in initialRoutes { path.append(route) }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 680)
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
            door(.build, icon: "square.stack.3d.down.right", color: Color(red: 0x6E / 255, green: 0x5A / 255, blue: 0xC8 / 255),
                 title: "Create shape slideshow", detail: "Pick a shape, the projects, and a mode")
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
        let captures = model.allLiveCaptures().filter { !$0.isScannerCapture && $0.kind == .photos }
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
