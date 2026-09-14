import SwiftUI
import simd
import LetsLapseKit
import UniformTypeIdentifiers

// The Presets sheet — LetsLapse's looks, the ones saved from the Edit screen,
// imported LUTs, and the import door — reached from the Create tab's "Manage
// presets" row. Design: docs/design/iOS/manage-presets*.portrait.svg
// (signed off 2026-09-08); the thinking behind it: docs/presets-lut-spike.md.
//
// The sheet owns its own NavigationStack, as the ladders sheet does, so a
// later door from the Edit screen presents it the same way. Every row is
// the PREVIEW FRAME through that preset — use case 2 of the spike in
// miniature — rendered through the same grader the editor uses, at 240 px,
// into a cache that lives as long as the sheet.

enum PresetRoute: Hashable {
    case builtIn(PhotoPreset)
    case custom(UUID)
    case previewPicker
}

/// The frame every preset in the list is rendered on.
struct PresetPreviewFrame: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case still(URL)
        case movie(URL)
    }
    var captureID: UUID
    var title: String
    var fileName: String
    var source: Source
    /// True when the person picked this project rather than the sheet
    /// defaulting to the newest edited one.
    var isChosen: Bool

    var url: URL {
        switch source {
        case .still(let url), .movie(let url): return url
        }
    }
}

extension AppModel {
    /// The frame the Presets sheet renders every preset on: the project the
    /// person picked, else the most recently edited project's hero. Nil for
    /// an empty library. Scans are not looks and are left out.
    func presetPreviewFrame(preferring id: UUID?) -> PresetPreviewFrame? {
        // The chosen project, else the most recently edited non-scan — the
        // index's Modified sort, one row (M3).
        var chosen: CaptureProject?
        if let id, let picked = self.capture(id: id), !picked.isScannerCapture { chosen = picked }
        var query = LibraryIndex.ProjectQuery()
        query.sort = .modified
        query.excludeScans = true
        query.limit = 1
        let newest: CaptureProject? = ((try? libraryIndex?.projects(query).rows.first) ?? nil).flatMap { row in self.capture(id: row.id) }
        let capture = chosen ?? newest
        guard let capture, let url = mediaURL(for: capture) else { return nil }
        let source: PresetPreviewFrame.Source = capture.kind == .video ? .movie(url) : .still(url)
        return PresetPreviewFrame(
            captureID: capture.id, title: capture.displayTitle, fileName: url.lastPathComponent,
            source: source, isChosen: chosen != nil)
    }
}

extension PhotoPreset {
    /// The built-in LOOKS — Original is a state, not a look, so it is not a
    /// row on the sheet.
    static let looks: [PhotoPreset] = [.natural, .cinema, .matte, .vivid]

    /// What the look does, in a phrase — the row's subtitle.
    var characterLine: String {
        switch self {
        case .natural: return "Pulled highlights, lifted shadows, warmer"
        case .cinema: return "Deep shadow lift, cooler, desaturated"
        case .matte: return "Lifted blacks, low contrast, faded"
        case .vivid: return "Punchy colour and contrast"
        case .original: return "The file exactly as captured"
        }
    }
}

extension UTType {
    /// A `.cube` LUT — declared as an imported type in Info.plist so the
    /// Files picker offers the files.
    static let cubeLUT = UTType(importedAs: "com.regularsteven.letslapse.cube-lut", conformingTo: .plainText)
}

// MARK: - Thumbnails

/// Renders of the preview frame through each preset, kept for the sheet's
/// life. Keyed on the frame, the grade and the size, so a strength change
/// on a LUT re-renders and nothing else does.
@MainActor
final class PresetThumbnailCache: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    private var inFlight: Set<String> = []
    /// Insertion order, oldest first — the eviction order.
    private var order: [String] = []

    /// The editors keep one cache for a whole session and re-key every tile
    /// on each settled edit, so a long grading session would otherwise pile
    /// up a fresh set of 160 px images per adjustment token. A couple of
    /// hundred tiles is a dozen-plus complete strips: the ones on screen and
    /// the last few states, which is all "this preset + my edits" ever needs
    /// to show again.
    static let capacity = 240

    func image(for key: String) -> CGImage? { images[key] }

    func render(key: String, frame: PresetPreviewFrame, grade: PhotoGrade, maxDimension: CGFloat) async {
        guard images[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        if let image = await Self.render(frame: frame, grade: grade, maxDimension: maxDimension) {
            images[key] = image
            order.append(key)
            while order.count > Self.capacity {
                images.removeValue(forKey: order.removeFirst())
            }
        }
    }

    /// The frame through the grade — a still through the image grader, a
    /// movie through one graded frame — off the media work queue.
    nonisolated static func render(
        frame: PresetPreviewFrame, grade: PhotoGrade, maxDimension: CGFloat
    ) async -> CGImage? {
        let result = await MediaWorkQueue.shared.run { () -> CGImage? in
            switch frame.source {
            case .still(let url):
                return PhotoGrader.render(
                    url: url, preset: grade.preset, adjustments: grade.adjustments,
                    rotationDegrees: 0, maxDimension: maxDimension)
            case .movie(let url):
                return VideoGrader.gradedFrame(at: url, grade: grade, maxDimension: maxDimension)
            }
        }
        return result.flatMap { $0 }
    }

    static func key(frame: PresetPreviewFrame, grade: PhotoGrade, maxDimension: CGFloat) -> String {
        "\(frame.url.path)|\(grade.preset.rawValue)|\(grade.adjustments.cacheToken)|\(Int(maxDimension))"
    }
}

// MARK: - The sheet

struct ManagePresetsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var presetStore = CustomPresetStore.shared
    @ObservedObject private var lutStore = LUTStore.shared
    @StateObject private var thumbnails = PresetThumbnailCache()
    @Environment(\.dismiss) private var dismiss
    @State private var path: [PresetRoute] = []
    /// Opens the sheet already pushed — the `LL_PRESETS` hook's door, applied
    /// a beat after the stack appears (a path seeded into the initial state
    /// is dropped on the sheet's first presentation, as the ladders learned).
    var initialPath: [PresetRoute] = []
    /// Opens the sheet with the import chooser up (`LL_PRESETS=import`).
    var initialImport = false

    /// The project whose frame the rows are rendered on; empty means the
    /// newest edited project.
    @AppStorage("presets.previewCaptureID") private var previewCaptureID = ""
    @State private var previewFrame: PresetPreviewFrame?
    /// How many projects are on each preset — a `.named` count over the
    /// library, taken on appear and after every store change.
    @State private var usage: [UUID: Int] = [:]

    @State private var choosingImportKind = false
    @State private var importKind: ImportKind = .cube
    @State private var isImporting = false
    @State private var importNotice: ImportNotice?

    enum ImportKind {
        case cube, lightroom

        var contentTypes: [UTType] {
            switch self {
            case .cube: return [.cubeLUT, .plainText]
            case .lightroom: return [UTType(filenameExtension: "xmp"), .xml, .plainText].compactMap { $0 }
            }
        }
    }

    struct ImportNotice: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle("Presets")
                .navigationDestination(for: PresetRoute.self) { route in
                    destination(for: route)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .confirmationDialog(
                    "Import a preset", isPresented: $choosingImportKind, titleVisibility: .visible
                ) {
                    Button("A LUT (.cube)…") { beginImport(.cube) }
                    Button("A Lightroom preset (.xmp)…") { beginImport(.lightroom) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("A colour cube from Lightroom, Resolve or a LUT pack, or a preset exported from Lightroom.")
                }
                .fileImporter(
                    isPresented: $isImporting, allowedContentTypes: importKind.contentTypes,
                    allowsMultipleSelection: false
                ) { result in
                    handleImport(result)
                }
                .alert(item: $importNotice) { notice in
                    Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
                }
                .task(id: previewCaptureID + "|" + String(model.allLiveCaptures().count)) {
                    previewFrame = model.presetPreviewFrame(preferring: UUID(uuidString: previewCaptureID))
                }
                .task {
                    recount()
                    if !initialPath.isEmpty, path.isEmpty {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        path = initialPath
                    }
                    if initialImport {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        choosingImportKind = true
                    }
                }
                .onChange(of: presetStore.presets) { _ in recount() }
        }
        .environmentObject(thumbnails)
        #if os(macOS)
        // A Mac sheet is never user-resizable, so it opens at a size the
        // compare card and a preset's list both fit.
        .frame(minWidth: 560, minHeight: 680)
        #endif
    }

    private var list: some View {
        List {
            Section {
                NavigationLink(value: PresetRoute.previewPicker) {
                    PreviewFrameRow(frame: previewFrame)
                }
            } header: {
                Text("Preview frame")
            } footer: {
                footer("Every preset below is shown on this frame. Tap to pick another project.")
            }

            Section {
                ForEach(PhotoPreset.looks) { preset in
                    NavigationLink(value: PresetRoute.builtIn(preset)) {
                        PresetRow(
                            title: preset.displayName, subtitle: preset.characterLine,
                            frame: previewFrame, grade: PhotoGrade(preset: preset, adjustments: .neutral))
                    }
                }
            } header: {
                Text("LetsLapse")
            } footer: {
                footer("Built in, never edited in place. Open one to see what it does, or duplicate it into your own.")
            }

            Section {
                let parametric = presetStore.parametricPresets
                ForEach(parametric) { preset in
                    NavigationLink(value: PresetRoute.custom(preset.id)) {
                        PresetRow(
                            title: preset.name, subtitle: subtitle(for: preset),
                            frame: previewFrame,
                            grade: PhotoGrade(preset: preset.basePreset, adjustments: preset.adjustments))
                    }
                }
                .onDelete { offsets in delete(offsets, from: parametric) }
                if parametric.isEmpty {
                    Text("Nothing saved yet.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Your presets")
            } footer: {
                footer("Saved from the Edit screen: adjust a photo, then Save as Preset. Open one to rename it, see what it changes, or delete it.")
            }

            let luts = presetStore.lutPresets
            if !luts.isEmpty {
                Section {
                    ForEach(luts) { preset in
                        NavigationLink(value: PresetRoute.custom(preset.id)) {
                            PresetRow(
                                title: preset.name, subtitle: subtitle(for: preset),
                                frame: previewFrame,
                                grade: PhotoGrade(preset: preset.basePreset, adjustments: preset.adjustments))
                        }
                    }
                    .onDelete { offsets in delete(offsets, from: luts) }
                } header: {
                    Text("LUTs")
                } footer: {
                    footer("A colour cube from Lightroom, Resolve or a LUT pack, applied after the sliders. Each project sets its own strength.")
                }
            }

            Section {
                Button {
                    choosingImportKind = true
                } label: {
                    Label("Import a preset…", systemImage: "plus")
                        .foregroundStyle(LL.accent)
                }
            } footer: {
                footer("A .cube LUT lands here under its file's name. A Lightroom preset (.xmp) lands under Your presets.")
            }
        }
    }

    @ViewBuilder
    private func destination(for route: PresetRoute) -> some View {
        switch route {
        case .previewPicker:
            PresetPreviewPickerView(chosenID: $previewCaptureID, path: $path)
        case .custom(let id):
            if presetStore.preset(id: id)?.isLUT == true {
                LUTDetailView(presetID: id, frame: previewFrame, usedOn: usage[id] ?? 0, path: $path)
            } else {
                PresetDetailView(route: route, frame: previewFrame, usedOn: usage[id] ?? 0, path: $path)
            }
        case .builtIn(let preset):
            PresetDetailView(route: route, frame: previewFrame, usedOn: usage[preset.presetID] ?? 0, path: $path)
        }
    }

    // MARK: Rows

    /// Base + moved sliders, and the projects on it — or, for a LUT, the
    /// cube's size, maker and default strength.
    private func subtitle(for preset: CustomPreset) -> String {
        var parts: [String] = []
        if let lut = preset.lut {
            let file = lutStore.file(id: lut.id)
            parts.append(file.map { "\($0.size)³" } ?? "LUT")
            if let maker = file?.maker { parts.append(maker) }
            parts.append("\(Int((lut.strength * 100).rounded())) %")
        } else {
            let moved = PresetChangeRows.movedCount(preset.adjustments)
            parts.append("\(preset.basePreset.displayName) + \(moved) adjustment\(moved == 1 ? "" : "s")")
        }
        if let count = usage[preset.id], count > 0 {
            parts.append("on \(count) project\(count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private func recount() {
        var counts: [UUID: Int] = [:]
        for capture in model.allLiveCaptures() {
            if case .named(let id, _) = model.presetState(for: capture) {
                counts[id, default: 0] += 1
            }
        }
        usage = counts
    }

    private func delete(_ offsets: IndexSet, from presets: [CustomPreset]) {
        for index in offsets.sorted(by: >) where index < presets.count {
            ManagePresetsView.delete(presets[index])
        }
    }

    /// Deletes a preset; a LUT's file goes with it when no other preset
    /// still names the cube. Projects keep their snapshots (and, for a LUT,
    /// their own copy of the cube) either way.
    @MainActor
    static func delete(_ preset: CustomPreset) {
        let store = CustomPresetStore.shared
        store.delete(preset)
        if let id = preset.lut?.id, !store.presets.contains(where: { $0.lut?.id == id }) {
            LUTStore.shared.delete(id: id)
        }
    }

    // MARK: Import

    /// The picker a runloop turn after the chooser closes: one presented
    /// while the dialog is still dismissing is dropped with no error (the
    /// Create tab's project import learned this on 2026-09-06).
    private func beginImport(_ kind: ImportKind) {
        importKind = kind
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            isImporting = true
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importNotice = ImportNotice(title: "Couldn't import", message: error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            switch importKind {
            case .cube: importCube(url)
            case .lightroom: importLightroom(url)
            }
        }
    }

    /// A `.cube` becomes a LUT file in the store and a preset named after
    /// the FILE (never the cube's TITLE), at full strength, and opens.
    private func importCube(_ url: URL) {
        do {
            let file = try lutStore.importCube(from: url)
            var adjustments = PhotoAdjustments.neutral
            adjustments.lut = LUTLayer(id: file.id, strength: 1)
            // A second import under a name already in use — the same file
            // again, or another pack's "Teal and Orange" — gets " 2", as a
            // duplicate does, rather than a twin chip nobody can tell apart.
            let preset = CustomPreset(
                name: presetStore.uniqueName(for: LUTFile.presetName(forFileName: file.fileName)),
                basePreset: .original, adjustments: adjustments)
            presetStore.add(preset)
            path.append(.custom(preset.id))
        } catch {
            importNotice = ImportNotice(
                title: "Couldn't read \(url.lastPathComponent)", message: error.localizedDescription)
        }
    }

    /// A Lightroom preset `.xmp` — the same `crs:` vocabulary as a sidecar —
    /// becomes a parametric preset under YOUR PRESETS, with the same
    /// applied/unsupported honesty the per-frame import reports. Masks are
    /// not part of a preset and are left behind, said so.
    private func importLightroom(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try LightroomSettingsImport.read(url)
            let name = presetStore.uniqueName(for: url.deletingPathExtension().lastPathComponent)
            let preset = CustomPreset(
                name: name, basePreset: .original,
                adjustments: result.adjustments.withoutGeometry.withoutWhite)
            presetStore.add(preset)
            path.append(.custom(preset.id))
            var lines = [result.summary]
            if !result.maskGrades.isEmpty {
                lines.append("Its \(result.maskGrades.count) mask\(result.maskGrades.count == 1 ? " is" : "s are") not part of a preset.")
            }
            lines.append(contentsOf: result.unsupported.prefix(6))
            importNotice = ImportNotice(title: "Imported \(name)", message: lines.joined(separator: "\n"))
        } catch {
            importNotice = ImportNotice(
                title: "Couldn't read \(url.lastPathComponent)", message: error.localizedDescription)
        }
    }
}

/// A section footer that wraps on the Mac too (a Mac list truncates one to
/// a line otherwise; iOS wraps it anyway).
private func footer(_ text: String) -> some View {
    Text(text)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
}

private extension View {
    /// The inline title a pushed screen wants, where the platform has the
    /// modifier.
    func inlineTitle() -> some View {
        #if os(iOS)
        return navigationBarTitleDisplayMode(.inline)
        #else
        return self
        #endif
    }
}

// MARK: - Rows

private struct PreviewFrameRow: View {
    let frame: PresetPreviewFrame?

    var body: some View {
        HStack(spacing: 12) {
            PresetThumbnail(frame: frame, grade: .identity, size: CGSize(width: 56, height: 42))
            VStack(alignment: .leading, spacing: 3) {
                Text(frame?.title ?? "No projects yet")
                    .font(.system(size: 16))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        guard let frame else { return "Presets are shown on your newest edited project" }
        return frame.fileName + (frame.isChosen ? " · the project you picked" : " · your newest edit")
    }
}

private struct PresetRow: View {
    let title: String
    let subtitle: String
    let frame: PresetPreviewFrame?
    let grade: PhotoGrade

    var body: some View {
        HStack(spacing: 12) {
            PresetThumbnail(frame: frame, grade: grade, size: CGSize(width: 44, height: 44))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The preview frame through one grade, at thumbnail size, from the sheet's
/// cache. A blank tile while it renders; a photo glyph when there is no
/// frame to render.
private struct PresetThumbnail: View {
    let frame: PresetPreviewFrame?
    let grade: PhotoGrade
    let size: CGSize
    @EnvironmentObject private var thumbnails: PresetThumbnailCache

    private var key: String? {
        frame.map { PresetThumbnailCache.key(frame: $0, grade: grade, maxDimension: 240) }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LL.controlFill)
            if let key, let image = thumbnails.image(for: key) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if frame == nil {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: key) {
            guard let key, let frame else { return }
            await thumbnails.render(key: key, frame: frame, grade: grade, maxDimension: 240)
        }
    }
}

// MARK: - The compare card

/// The preview frame with the look right of a draggable divider. Drag the
/// divider to compare; press and hold anywhere to see the original edge to
/// edge. Both renders come through the same grader the editor uses, at
/// 1000 px, so what the card shows is what a project would get.
struct PresetCompareCard: View {
    let frame: PresetPreviewFrame?
    let grade: PhotoGrade

    @State private var before: CGImage?
    @State private var after: CGImage?
    @State private var divider: CGFloat = 0.42
    @State private var holding = false
    @State private var dragMoved = false
    @State private var holdTask: Task<Void, Never>?

    private var renderKey: String {
        frame.map { PresetThumbnailCache.key(frame: $0, grade: grade, maxDimension: 1000) } ?? ""
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.06)
                if let before {
                    picture(before, width: width, height: height)
                }
                if let after, !holding {
                    picture(after, width: width, height: height)
                        .mask(alignment: .trailing) {
                            Rectangle().frame(width: max(0, width * (1 - divider)))
                        }
                }
                if !holding {
                    Rectangle()
                        .fill(.white)
                        .frame(width: 2, height: height)
                        .position(x: width * divider, y: height / 2)
                    Circle()
                        .fill(.white)
                        .frame(width: 30, height: 30)
                        .overlay {
                            Image(systemName: "arrow.left.and.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(LL.ink)
                        }
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .position(x: width * divider, y: height / 2)
                }
                HStack {
                    pill("Before")
                    Spacer()
                    pill(holding ? "Original" : "After")
                }
                .padding(12)
                if frame == nil {
                    Text("No project to show it on yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: width, height: height)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let distance = hypot(value.translation.width, value.translation.height)
                        if !dragMoved, distance > 6 {
                            dragMoved = true
                            holdTask?.cancel()
                            holdTask = nil
                            holding = false
                        }
                        if dragMoved {
                            divider = min(max(value.location.x / max(width, 1), 0.03), 0.97)
                        } else if holdTask == nil {
                            holdTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                guard !Task.isCancelled else { return }
                                holding = true
                            }
                        }
                    }
                    .onEnded { _ in
                        holdTask?.cancel()
                        holdTask = nil
                        holding = false
                        dragMoved = false
                    }
            )
        }
        .aspectRatio(353.0 / 200.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: renderKey) {
            guard let frame else { before = nil; after = nil; return }
            async let original = PresetThumbnailCache.render(frame: frame, grade: .identity, maxDimension: 1000)
            async let graded = PresetThumbnailCache.render(frame: frame, grade: grade, maxDimension: 1000)
            let (a, b) = await (original, graded)
            before = a
            after = b
        }
    }

    private func picture(_ image: CGImage, width: CGFloat, height: CGFloat) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: width, height: height)
            .clipped()
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.5), in: Capsule())
    }
}

// MARK: - What it changes

/// The read-only rows a preset's screen lists: the base, then every slider
/// the preset moves with its value in the panel's own units.
enum PresetChangeRows {
    struct Row: Identifiable {
        var id: String { label }
        var label: String
        var value: String
    }

    static func rows(base: PhotoPreset, adjustments: PhotoAdjustments) -> [Row] {
        var rows = [Row(label: "Based on", value: base.displayName)]
        for field in PhotoAdjustmentField.allCases {
            guard let label = label(for: field) else { continue }
            let value = adjustments[keyPath: field.keyPath]
            guard abs(value - field.neutralValue) > field.epsilon else { continue }
            rows.append(Row(label: label, value: format(field, value)))
        }
        if let hsl = adjustments.hsl, !hsl.isNeutral {
            rows.append(Row(label: "Color Mixer", value: "adjusted"))
        }
        if let lut = adjustments.lut {
            rows.append(Row(label: "LUT", value: "\(Int((lut.strength * 100).rounded())) %"))
        }
        return rows
    }

    /// A built-in's recipe, in the same vocabulary.
    static func rows(builtIn preset: PhotoPreset) -> [Row] {
        let recipe = preset.recipe
        var rows = [Row(label: "Based on", value: "the file as captured")]
        func add(_ label: String, _ value: Float, unipolar: Bool = false) {
            guard abs(value) > 1e-4 else { return }
            rows.append(Row(label: label, value: hundred(value, unipolar: unipolar)))
        }
        add("Exposure", recipe.exposure)
        add("Contrast", recipe.contrast)
        add("Highlights", recipe.highlights)
        add("Shadows", recipe.shadows)
        add("Whites", recipe.whites)
        add("Blacks", recipe.blacks)
        if abs(recipe.temperatureMired) > 1e-4 {
            rows.append(Row(label: "Temperature", value: mired(recipe.temperatureMired)))
        }
        add("Tint", recipe.tint)
        add("Vibrance", recipe.vibrance)
        add("Saturation", recipe.saturation)
        add("Clarity", recipe.clarity)
        // Shown the way the panel shows it — Lightroom's way up, lighten is
        // "+" — so the recipe's positive-darkens value reads negative here.
        add("Vignette", -recipe.vignette)
        if abs(recipe.vignetteMidpoint - PhotoAdjustments.neutralVignetteMidpoint) > 1e-4 {
            rows.append(Row(
                label: "Vignette midpoint", value: hundred(recipe.vignetteMidpoint, unipolar: true)))
        }
        return rows
    }

    /// How many sliders a preset moves — the row subtitle's count. The
    /// mixer counts as one; a LUT does not (it is the preset).
    static func movedCount(_ adjustments: PhotoAdjustments) -> Int {
        var count = 0
        for field in PhotoAdjustmentField.allCases where label(for: field) != nil {
            if abs(adjustments[keyPath: field.keyPath] - field.neutralValue) > field.epsilon { count += 1 }
        }
        if let hsl = adjustments.hsl, !hsl.isNeutral { count += 1 }
        return count
    }

    /// The panel's name for a field — nil for the corrections that are not a
    /// look (the owned white, the level), which a preset never carries.
    static func label(for field: PhotoAdjustmentField) -> String? {
        switch field {
        case .exposure: return "Exposure"
        case .contrast: return "Contrast"
        case .highlights: return "Highlights"
        case .shadows: return "Shadows"
        case .whites: return "Whites"
        case .blacks: return "Blacks"
        case .temperature: return "Temperature"
        case .tint: return "Tint"
        case .vibrance: return "Vibrance"
        case .saturation: return "Saturation"
        case .clarity: return "Clarity"
        case .vignetteIntensity: return "Vignette"
        case .vignetteMidpoint: return "Vignette midpoint"
        case .texture: return "Texture"
        case .sharpen: return "Sharpen"
        case .sharpenMasking: return "Masking"
        case .noiseReduction: return "Noise reduction"
        case .noiseDetail: return "Noise detail"
        case .colorNoiseReduction: return "Colour noise"
        case .colorNoise: return "Chroma noise"
        case .dehaze: return "Dehaze"
        case .whiteMired, .whiteTint, .rotation: return nil
        }
    }

    static func format(_ field: PhotoAdjustmentField, _ value: Float) -> String {
        switch field {
        case .exposure:
            return String(format: "%+.2f EV", value)
        case .temperature:
            return mired(value)
        // The midpoint is unipolar 0…100 with 50 in the middle; `rows` and
        // `movedCount` already know 0.5 is its neutral through
        // `neutralValue`, so only a moved one gets this far.
        case .sharpen, .sharpenMasking, .noiseReduction, .noiseDetail,
             .colorNoiseReduction, .colorNoise, .vignetteMidpoint:
            return hundred(value, unipolar: true)
        // Signed since 2026-09-12, and shown the way the panel shows it —
        // Lightroom's way up, lighten is "+" — so the stored positive-darkens
        // value is negated here exactly as the control negates it.
        case .vignetteIntensity:
            return hundred(-value, unipolar: false)
        default:
            return hundred(value, unipolar: false)
        }
    }

    private static func hundred(_ value: Float, unipolar: Bool) -> String {
        let scaled = Int((value * 100).rounded())
        return unipolar ? "\(scaled)" : String(format: "%+d", scaled)
    }

    private static func mired(_ value: Float) -> String {
        let scaled = Int(value.rounded())
        return scaled > 0 ? "+\(scaled) warmer" : "\(scaled) cooler"
    }
}

// MARK: - A preset's screen

struct PresetDetailView: View {
    @ObservedObject private var presetStore = CustomPresetStore.shared
    let route: PresetRoute
    let frame: PresetPreviewFrame?
    let usedOn: Int
    @Binding var path: [PresetRoute]

    @State private var name = ""
    @State private var confirmingDelete = false

    private var custom: CustomPreset? {
        if case .custom(let id) = route { return presetStore.preset(id: id) }
        return nil
    }

    private var builtIn: PhotoPreset? {
        if case .builtIn(let preset) = route { return preset }
        return nil
    }

    private var title: String { custom?.name ?? builtIn?.displayName ?? "" }

    private var grade: PhotoGrade {
        if let custom { return PhotoGrade(preset: custom.basePreset, adjustments: custom.adjustments) }
        return PhotoGrade(preset: builtIn ?? .original, adjustments: .neutral)
    }

    private var rows: [PresetChangeRows.Row] {
        if let custom { return PresetChangeRows.rows(base: custom.basePreset, adjustments: custom.adjustments) }
        return PresetChangeRows.rows(builtIn: builtIn ?? .original)
    }

    var body: some View {
        List {
            Section {
                PresetCompareCard(frame: frame, grade: grade)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                footer("Drag the divider to compare, or press and hold to see the original. Shown on \(frame?.title ?? "your preview frame").")
            }

            Section {
                if custom != nil {
                    TextField("Name", text: $name)
                        .onSubmit(commitName)
                } else {
                    Text(title)
                }
            } header: {
                Text("Name")
            }

            Section {
                ForEach(rows) { row in
                    HStack {
                        Text(row.label)
                        Spacer()
                        Text(row.value)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("What it changes")
            }

            Section {
                HStack {
                    Text("Used on")
                    Spacer()
                    Text(usedOn == 1 ? "1 project" : "\(usedOn) projects")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(custom == nil ? "Duplicate into Your presets" : "Duplicate") { duplicate() }
                    .foregroundStyle(LL.accent)
                if custom != nil {
                    Button("Delete preset", role: .destructive) { confirmingDelete = true }
                }
            } footer: {
                if custom != nil {
                    footer("Projects on this preset keep the look they were given; only the chip goes.")
                }
            }
        }
        .navigationTitle(title)
        .inlineTitle()
        .onAppear { name = custom?.name ?? "" }
        .onDisappear(perform: commitName)
        .confirmationDialog("Delete \(title)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete preset", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Projects on it keep the look they were given.")
        }
    }

    private func commitName() {
        guard let custom else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != custom.name else { return }
        presetStore.rename(custom, to: trimmed)
    }

    private func duplicate() {
        let copy: CustomPreset
        if let custom {
            copy = CustomPreset(
                name: presetStore.uniqueName(for: custom.name + " copy"),
                basePreset: custom.basePreset, adjustments: custom.adjustments)
        } else if let builtIn {
            copy = CustomPreset(
                name: presetStore.uniqueName(for: builtIn.displayName + " copy"),
                basePreset: builtIn, adjustments: .neutral)
        } else {
            return
        }
        presetStore.add(copy)
        path.append(.custom(copy.id))
    }

    private func delete() {
        guard let custom else { return }
        ManagePresetsView.delete(custom)
        if !path.isEmpty { path.removeLast() }
    }
}

// MARK: - A LUT's screen

struct LUTDetailView: View {
    @ObservedObject private var presetStore = CustomPresetStore.shared
    @ObservedObject private var lutStore = LUTStore.shared
    let presetID: UUID
    let frame: PresetPreviewFrame?
    let usedOn: Int
    @Binding var path: [PresetRoute]

    @State private var name = ""
    /// The slider's live value; written to the preset when the drag ends.
    @State private var strength: Float = 1
    @State private var confirmingDelete = false

    private var preset: CustomPreset? { presetStore.preset(id: presetID) }
    private var file: LUTFile? { preset?.lut.flatMap { lutStore.file(id: $0.id) } }

    /// The preview follows the slider as it moves.
    private var grade: PhotoGrade {
        var adjustments = preset?.adjustments ?? .neutral
        adjustments.lut?.strength = strength
        return PhotoGrade(preset: .original, adjustments: adjustments)
    }

    private var percent: Int { Int((strength * 100).rounded()) }

    var body: some View {
        List {
            Section {
                PresetCompareCard(frame: frame, grade: grade)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                footer("Drag the divider to compare, or press and hold to see the original. \(percent) % strength, on \(frame?.title ?? "your preview frame").")
            }

            Section {
                TextField("Name", text: $name)
                    .onSubmit(commitName)
            } header: {
                Text("Name")
            }

            Section {
                HStack(spacing: 12) {
                    Slider(value: $strength, in: 0...1) { editing in
                        if !editing { commitStrength() }
                    }
                    .tint(LL.accent)
                    Text("\(percent) %")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
            } header: {
                Text("Strength")
            } footer: {
                footer("What a project starts at. Each project can set its own strength in the Edit screen.")
            }

            Section {
                if let file {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.fileName)
                        Text(fileLine(file))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Imported")
                        Spacer()
                        Text(file.importedAt, format: .dateTime.day().month().year())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Used on")
                        Spacer()
                        Text(usedOn == 1 ? "1 project" : "\(usedOn) projects")
                            .foregroundStyle(.secondary)
                    }
                    if file.isLikelyLogInput {
                        Label {
                            Text("Expects a log-encoded picture. On a normal photo it will look crushed; try it on a Capture Flat clip.")
                                .font(.system(size: 13))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(LL.levelOff)
                        }
                    }
                } else {
                    Text("Carried by its projects — the cube isn't in this device's store.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("File")
            }

            Section {
                Button("Delete LUT", role: .destructive) { confirmingDelete = true }
            } footer: {
                footer("Projects on this LUT keep rendering it: each carries its own copy of the cube.")
            }
        }
        .navigationTitle(preset?.name ?? "")
        .inlineTitle()
        .onAppear {
            name = preset?.name ?? ""
            strength = preset?.lut?.strength ?? 1
        }
        .onDisappear(perform: commitName)
        .confirmationDialog("Delete \(preset?.name ?? "this LUT")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete LUT", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Projects on it keep rendering it from their own copy.")
        }
    }

    private func fileLine(_ file: LUTFile) -> String {
        var parts = [file.sizeDescription]
        if !file.title.isEmpty { parts.append(file.title) } else if let maker = file.maker { parts.append(maker) }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private func commitName() {
        guard let preset else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != preset.name else { return }
        presetStore.rename(preset, to: trimmed)
    }

    private func commitStrength() {
        guard var preset, preset.lut != nil else { return }
        preset.adjustments.lut?.strength = strength
        presetStore.update(preset)
    }

    private func delete() {
        guard let preset else { return }
        ManagePresetsView.delete(preset)
        if !path.isEmpty { path.removeLast() }
    }
}

extension CustomPresetStore {
    /// `name`, or `name 2`, `name 3`… — the first not already in use.
    func uniqueName(for name: String) -> String {
        let taken = Set(presets.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)".lowercased()) { n += 1 }
        return "\(name) \(n)"
    }
}

// MARK: - The preview picker

/// Which project the sheet renders every preset on. Newest edited first.
struct PresetPreviewPickerView: View {
    @EnvironmentObject var model: AppModel
    @Binding var chosenID: String
    @Binding var path: [PresetRoute]

    private var candidates: [AppModel.CaptureProject] {
        model.allLiveCaptures()
            .filter { !$0.isScannerCapture }
            .sorted { ($0.modifiedAt ?? $0.createdAt) > ($1.modifiedAt ?? $1.createdAt) }
    }

    var body: some View {
        List {
            Section {
                ForEach(candidates) { capture in
                    Button {
                        chosenID = capture.id.uuidString
                        if !path.isEmpty { path.removeLast() }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(capture.displayTitle)
                                    .foregroundStyle(.primary)
                                Text(capture.kind.label + " · " + (capture.modifiedAt ?? capture.createdAt).formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if chosenID == capture.id.uuidString {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(LL.accent)
                            }
                        }
                    }
                }
            } footer: {
                footer("The frame every preset is shown on. Pick the kind of picture you grade most.")
            }
        }
        .navigationTitle("Preview frame")
        .inlineTitle()
    }
}

// MARK: - The hook's seed

#if DEBUG
extension ManagePresetsView {
    /// `LL_PRESETS`: the four saved presets and two LUTs the design draws,
    /// written when the stores are empty — simulator data through the same
    /// store calls a save or an import makes.
    @MainActor
    static func debugSeed() {
        let store = CustomPresetStore.shared
        if store.parametricPresets.isEmpty {
            func make(_ name: String, _ base: PhotoPreset, _ edit: (inout PhotoAdjustments) -> Void) {
                var adjustments = PhotoAdjustments.neutral
                edit(&adjustments)
                store.add(CustomPreset(name: name, basePreset: base, adjustments: adjustments))
            }
            make("Punchy", .original) {
                $0.exposure = -0.49; $0.contrast = -0.13; $0.highlights = -0.42; $0.shadows = 0.48
                $0.whites = -0.33; $0.blacks = -0.14; $0.vibrance = 0.47; $0.saturation = 0.13
                $0.clarity = 0.31; $0.vignetteIntensity = 0.74; $0.texture = 0.1
            }
            make("Sunny Nature", .natural) {
                $0.highlights = -0.33; $0.contrast = -0.33; $0.clarity = 0.73; $0.vibrance = 0.29
                $0.vignetteIntensity = 0.61; $0.temperature = 21.63
            }
            make("Flat Day", .original) {
                $0.blacks = -0.9; $0.clarity = 0.52; $0.colorNoiseReduction = 0.27; $0.contrast = 0.29
                $0.highlights = -0.39; $0.noiseReduction = 0.21; $0.saturation = 0.12; $0.shadows = -0.07
                $0.sharpen = 0.22; $0.temperature = 20.29; $0.tint = -0.1; $0.vibrance = 0.34
                $0.vignetteIntensity = 0.29
            }
            make("Day DNG", .original) {
                $0.blacks = 0.1; $0.clarity = 0.52; $0.colorNoiseReduction = 0.27; $0.contrast = 0.29
                $0.highlights = -0.39; $0.noiseReduction = 0.21; $0.saturation = 0.12; $0.shadows = 0.48
                $0.sharpen = 0.22; $0.vibrance = 0.34; $0.vignetteIntensity = 0.29; $0.texture = 0.15
            }
        }
        if store.lutPresets.isEmpty {
            func seed(_ fileName: String, strength: Float, _ transform: (SIMD3<Float>) -> SIMD3<Float>) {
                let cube = CubeLUT.make(size: 17, title: "Generated by Resolve", transform)
                guard let file = try? LUTStore.shared.importCube(
                    data: Data(cube.cubeFileText().utf8), fileName: fileName) else { return }
                var adjustments = PhotoAdjustments.neutral
                adjustments.lut = LUTLayer(id: file.id, strength: strength)
                store.add(CustomPreset(
                    name: LUTFile.presetName(forFileName: fileName), basePreset: .original,
                    adjustments: adjustments))
            }
            func luma(_ v: SIMD3<Float>) -> Float { 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z }
            func toward(_ v: SIMD3<Float>, _ tint: SIMD3<Float>, _ weight: Float) -> SIMD3<Float> {
                let target = tint * (luma(v) / max(luma(tint), 0.01))
                let mixed = v * (1 - weight) + target * weight
                return simd_clamp(mixed, SIMD3(repeating: 0), SIMD3(repeating: 1))
            }
            seed("Teal_and_Orange.cube", strength: 1) { v in
                let y = luma(v)
                let teal = SIMD3<Float>(0.06, 0.49, 0.55), orange = SIMD3<Float>(1.0, 0.55, 0.2)
                return y < 0.5 ? toward(v, teal, 0.45 * (1 - y * 2)) : toward(v, orange, 0.35 * ((y - 0.5) * 2))
            }
            seed("Terra_4.1.cube", strength: 0.8) { v in
                simd_clamp(SIMD3(v.x * 0.92 + 0.04, v.y * 0.95 + 0.05, v.z * 0.97 + 0.06),
                           SIMD3(repeating: 0), SIMD3(repeating: 1))
            }
        }
    }

    @MainActor
    static func debugRoute(named name: String) -> PresetRoute? {
        CustomPresetStore.shared.presets.first { $0.name == name }.map { .custom($0.id) }
    }
}
#endif
