import SwiftUI
import Photos
import PhotosUI
import UniformTypeIdentifiers
import LetsLapseKit

/// What a tap on an effect card should set up before the camera opens.
/// A nil mode (the plain "Record now" entry) means no opinion: the capture
/// screen opens in the last-used mode when "Remember recording settings"
/// is on, Video otherwise. Effect cards pass an explicit mode.
struct CaptureIntent: Equatable {
    var mode: CaptureMode? = nil
    var sequenceMode: LiveCaptureSequence.Mode = .ramp
}

/// The effect-first home: what the app makes, before any mechanics.
enum CreateEffect: String, CaseIterable, Identifiable {
    case smoothTimelapse
    case longExposure
    case speedRamp
    case customBlend

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smoothTimelapse: return "Smooth timelapse"
        case .longExposure: return "Long exposure"
        case .speedRamp: return "Speed ramp"
        case .customBlend: return "Custom blend"
        }
    }

    var subtitle: String {
        switch self {
        case .smoothTimelapse: return "Hours become seconds, motion melts into streaks"
        case .longExposure: return "Interval photos into a timelapse, or one long exposure"
        case .speedRamp: return "Speed rises or falls across the clip"
        case .customBlend: return "Every dial, no presets"
        }
    }

    var intent: CaptureIntent {
        switch self {
        case .smoothTimelapse: return CaptureIntent(mode: .video, sequenceMode: .marker)
        case .longExposure: return CaptureIntent(mode: .interval, sequenceMode: .marker)
        case .speedRamp: return CaptureIntent(mode: .video, sequenceMode: .ramp)
        case .customBlend: return CaptureIntent(mode: .video, sequenceMode: .marker)
        }
    }
}

struct CreateView: View {
    @EnvironmentObject var model: AppModel
    /// The camera presentation is owned by ContentView so that selecting the
    /// Create tab can open the camera directly (skipping this screen). This
    /// screen is the tab's "home" behind the camera; its own Record-now and
    /// effect entries still drive the same binding.
    @Binding var showCapture: Bool
    @Binding var captureIntent: CaptureIntent
    @State private var isImporting = false
    @State private var importingProject = false
    /// "Import a LetsLapse project…" asks where from before it does anything —
    /// a `.lapse` file, or straight off another device over the network. Both
    /// answers are "import a project", so they belong behind one row rather
    /// than as two entries that would have to explain the difference in their
    /// titles.
    @State private var choosingImportSource = false
    #if os(iOS)
    @State private var showDeviceImport = false
    /// Interval ladders — Ladder MODE's tables, managed from here as well as
    /// from the capture screen's ladder chip. The selection is the capture
    /// screen's; it is mirrored here so "Use this ladder" arms the next shoot.
    @State private var showLadders = false
    @State private var selectedLadderID: UUID? = RecordingSettingsStore.ladderID
    /// Where the ladders sheet opens — empty for the list; the `LL_LADDERS`
    /// hook pushes an editor or a rung (DEBUG only, set on appear).
    @State private var laddersInitialPath: [LadderRoute] = []
    #else
    @Environment(\.openWindow) private var openWindow
    #endif
    #if os(iOS)
    @State private var videoItem: PhotosPickerItem?
    @State private var photoItems: [PhotosPickerItem] = []
    /// "Import photos to stack" asks where from on iOS, for the same reason
    /// the project row does: the Photos library and the Files app are two
    /// genuinely different answers, and only one of them can hand over a
    /// camera's raw files under their own names.
    @State private var choosingPhotoSource = false
    @State private var pickingLibraryPhotos = false
    #else
    @State private var importingVideo = false
    @State private var isDropTargeted = false
    #endif
    /// The Files/Finder picker, on every platform — the path that reaches a
    /// card, a drive or an iCloud folder, and the only one that preserves the
    /// camera's own file names.
    @State private var importingPhotos = false

    private static let projectArchiveTypes: [UTType] = [.lapseProject]

    /// What the stills picker will accept. `.image` already covers every raw
    /// format the system knows (`com.sony.arw-raw-image` and its siblings all
    /// conform to `public.camera-raw-image`, which conforms to `public.image`);
    /// `.rawImage` is named anyway so a body whose files the system types only
    /// as raw is still selectable, and `.folder` is what lets a whole shoot be
    /// chosen in one gesture instead of 306 clicks.
    private static let stillContentTypes: [UTType] = [.image, .rawImage, .folder]

    private let effectColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Create")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                Text("What do you want to make?")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
                    .padding(.bottom, 14)

                // Status sits ABOVE the grid, not under the source rows where it
                // used to. Measured on a 393×852 iPhone: the effect grid and the
                // rows card together end at ~787pt, and the floating tab bar
                // starts at 755 — so a card added below them lands UNDER the bar,
                // with the progress track itself right where the bar is opaque.
                // A progress bar you have to scroll to see is not a progress bar,
                // and an import failure you have to scroll to read is worse. Both
                // are answers to "what is the app doing right now", which is a
                // top-of-screen question anyway.
                if let progress = model.mediaImport {
                    MediaImportCard(progress: progress)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                } else if isImporting {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Importing…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .llCard()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .llCard()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                LazyVGrid(columns: effectColumns, spacing: 12) {
                    ForEach(CreateEffect.allCases) { effect in
                        Button {
                            start(effect)
                        } label: {
                            EffectCard(effect: effect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)

                sourceRows
                    .padding(.horizontal, 16)
                    .padding(.top, 16)


                Spacer(minLength: 110)
            }
        }
        .background(LL.screenBackground)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle("Create")
        #endif
        #if DEBUG
        .onAppear {
            let environment = ProcessInfo.processInfo.environment
            if environment["LL_CAPTURE"] == "1" {
                showCapture = true
            }
            #if os(iOS)
            // `LL_TRANSFER` — the device-import sheet, which is otherwise two
            // taps into Create and so unreachable from a headless run. On
            // macOS the same variable opens the window from `LetsLapseApp`;
            // here it has to be the screen that owns the sheet.
            if let hook = environment["LL_TRANSFER"], hook != "0" {
                showDeviceImport = true
            }
            // `LL_LADDERS=list|editor|rung` — the Interval ladders sheet on the
            // requested screen. `editor` opens the built-in; `rung` opens its
            // Dusk rung, the one every `LL_LADDER` capture state stands on.
            // `list` seeds one user clone when there is none, so YOUR LADDERS
            // shows the row the design draws rather than an empty section —
            // simulator data, written to the same `light_ladders.json` a tap
            // on Duplicate would write.
            if let screen = environment["LL_LADDERS"] {
                let builtIn = LightLadder.builtIn
                switch screen {
                case "editor":
                    laddersInitialPath = [.editor(builtIn.id)]
                case "rung":
                    let dusk = builtIn.rungs[min(2, builtIn.rungs.count - 1)]
                    laddersInitialPath = [.editor(builtIn.id), .rung(ladder: builtIn.id, rung: dusk.id)]
                default:
                    if LightLadderStore.shared.userLadders.isEmpty {
                        LightLadderStore.shared.duplicate(builtIn, named: "Bright & Fast (copy)")
                    }
                }
                showLadders = true
            }
            #endif
        }
        #endif
        .capturePresentation(isPresented: $showCapture, intent: captureIntent)
        #if os(iOS)
        .onChange(of: videoItem) { item in
            guard let item else { return }
            importVideo(item)
        }
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            importLibraryPhotos(items)
        }
        .photosPicker(
            isPresented: $pickingLibraryPhotos,
            selection: $photoItems,
            maxSelectionCount: 500,
            matching: .images
        )
        .fileImporter(
            isPresented: $importingProject,
            allowedContentTypes: Self.projectArchiveTypes
        ) { result in
            if case .success(let url) = result {
                model.openArchive(at: url)
            }
        }
        .sheet(isPresented: $showDeviceImport) {
            ProjectTransferImportView()
                .environmentObject(model)
        }
        #else
        .fileImporter(isPresented: $importingVideo, allowedContentTypes: Self.videoContentTypes) { result in
            handleVideoImport(result)
        }
        .fileImporter(
            isPresented: $importingProject,
            allowedContentTypes: Self.projectArchiveTypes
        ) { result in
            if case .success(let url) = result {
                model.openArchive(at: url)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedURLs(urls)
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(LL.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        #endif
        .fileImporter(
            isPresented: $importingPhotos,
            allowedContentTypes: Self.stillContentTypes,
            allowsMultipleSelection: true
        ) { result in
            handleStillsImport(result)
        }
    }

    // MARK: - Rows

    private var sourceRows: some View {
        VStack(spacing: 0) {
            Button {
                captureIntent = CaptureIntent()
                showCapture = true
            } label: {
                SourceRow(
                    icon: "record.circle",
                    iconColor: LL.accent,
                    title: "Record now",
                    isProminent: true
                )
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 58)

            importVideoRow

            Divider().padding(.leading, 58)

            importPhotosRow

            Divider().padding(.leading, 58)

            importProjectRow

            #if os(iOS)
            Divider().padding(.leading, 58)

            laddersRow
            #endif
        }
        .llCard(cornerRadius: 18)
    }

    #if os(iOS)
    /// Interval's Ladder MODE tables. A sheet here as on the capture screen:
    /// the list owns its own navigation (editor, rung), so it presents the
    /// same way from both doors. iOS only, with the state above it: Ladder
    /// MODE rides the ramp engine, which macOS cameras cannot run.
    private var laddersRow: some View {
        Button {
            showLadders = true
        } label: {
            SourceRow(
                icon: "sunset.fill",
                iconColor: LL.accentDeep,
                title: "Interval ladders"
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showLadders) {
            LightLaddersView(store: LightLadderStore.shared, selectedID: $selectedLadderID, initialPath: laddersInitialPath)
        }
        .onChange(of: selectedLadderID) { id in RecordingSettingsStore.save(ladderID: id) }
    }
    #endif

    private var importProjectRow: some View {
        Button {
            choosingImportSource = true
        } label: {
            SourceRow(
                icon: "shippingbox",
                iconColor: Color(red: 0.56, green: 0.45, blue: 0.32),
                title: "Import a LetsLapse project…"
            )
        }
        .buttonStyle(.plain)
        .confirmationDialog(
            "Import a LetsLapse project",
            isPresented: $choosingImportSource,
            titleVisibility: .visible
        ) {
            Button("From a file…") { importingProject = true }
            Button("From another device…") { startDeviceImport() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A .lapse archive from Files or a disk, or a project copied straight off another device on this network.")
        }
    }

    /// The network import. A sheet on iOS and iPadOS, which have no windows;
    /// the Mac's own `Window` scene (also behind File ▸ Import from Device…),
    /// which can sit beside the library while it runs.
    private func startDeviceImport() {
        #if os(iOS)
        showDeviceImport = true
        #else
        openWindow(id: "import")
        #endif
    }

    @ViewBuilder
    private var importVideoRow: some View {
        #if os(iOS)
        PhotosPicker(selection: $videoItem, matching: .videos) {
            SourceRow(icon: "film", iconColor: Color(red: 0.35, green: 0.5, blue: 0.66), title: "Import a video")
        }
        .buttonStyle(.plain)
        #else
        Button {
            importingVideo = true
        } label: {
            SourceRow(icon: "film", iconColor: Color(red: 0.35, green: 0.5, blue: 0.66), title: "Import a video…")
        }
        .buttonStyle(.plain)
        #endif
    }

    @ViewBuilder
    private var importPhotosRow: some View {
        Button {
            #if os(iOS)
            choosingPhotoSource = true
            #else
            importingPhotos = true
            #endif
        } label: {
            SourceRow(
                icon: "photo.stack",
                iconColor: Color(red: 0.48, green: 0.42, blue: 0.61),
                title: "Import photos to stack…")
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .confirmationDialog(
            "Import photos to stack",
            isPresented: $choosingPhotoSource,
            titleVisibility: .visible
        ) {
            Button("From Files…") { importingPhotos = true }
            Button("From Photos…") { pickingLibraryPhotos = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A folder of frames from a card or a drive, or photos already in your library. Raw files keep their own names when they come from Files.")
        }
        #endif
    }

    // MARK: - Effects

    private func start(_ effect: CreateEffect) {
        switch effect {
        case .smoothTimelapse:
            model.useRamp = false
            model.constantWindow = max(model.defaultSpeed, 50)
        case .longExposure:
            model.linearLight = true
        case .speedRamp:
            model.useRamp = false
        case .customBlend:
            break
        }
        captureIntent = effect.intent
        showCapture = true
    }

    // MARK: - Import plumbing

    /// The Files/Finder answer for "Import photos to stack", on every
    /// platform. Files, folders or both — `AppModel.importStills` resolves the
    /// selection into the shoot and takes it from there.
    ///
    /// The security scope is claimed by the model for the whole job rather
    /// than here: a folder pick hands back ONE url whose scope has to cover
    /// every file found inside it, and it has to still be held when the copy
    /// runs, which is minutes later and on another thread.
    private func handleStillsImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            model.importStills(from: urls)
        case .failure(let error):
            model.errorMessage = error.localizedDescription
        }
    }

    #if os(iOS)
    private func importVideo(_ item: PhotosPickerItem) {
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                    model.importVideo(from: movie.url)
                } else {
                    model.errorMessage = "Couldn't load that video."
                }
            } catch {
                model.errorMessage = error.localizedDescription
            }
            videoItem = nil
        }
    }

    /// Stages the Photos library's answer on disk and hands it to the same
    /// importer the Files path uses.
    ///
    /// Two things this now does that it didn't:
    ///
    /// - **The staged file keeps an extension**, taken from the item's own
    ///   content type. Without one nothing downstream can tell a raw from a
    ///   JPEG — not the decoder's raw gate, not the project's format pill —
    ///   and every frame of every library import read as typeless.
    /// - **It keeps the camera's file name** where the library still knows it
    ///   (`PHAssetResource.originalFilename`), falling back to the picked
    ///   order. An imported frame's name is its identity everywhere after
    ///   this, Bad Frames included.
    private func importLibraryPhotos(_ items: [PhotosPickerItem]) {
        isImporting = true
        Task {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var urls: [URL] = []
            var used = Set<String>()
            for (index, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let name = Self.stagedName(
                    for: item, fallbackIndex: index, taken: &used)
                let url = directory.appendingPathComponent(name)
                if (try? data.write(to: url)) != nil { urls.append(url) }
            }
            photoItems = []
            isImporting = false
            guard urls.count >= 2 else {
                model.errorMessage = "Pick at least two photos to stack."
                return
            }
            model.importStills(from: urls)
        }
    }

    /// The name one library item is staged under: its original camera file
    /// name when the library still has it, else `photo-0001` plus whatever
    /// extension its content type implies.
    private static func stagedName(
        for item: PhotosPickerItem, fallbackIndex: Int, taken: inout Set<String>
    ) -> String {
        let ext = item.supportedContentTypes
            .compactMap(\.preferredFilenameExtension).first ?? "jpg"
        var name: String?
        if let identifier = item.itemIdentifier {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            if let asset = assets.firstObject {
                name = PHAssetResource.assetResources(for: asset).first?.originalFilename
            }
        }
        let candidate = name ?? String(format: "photo-%04d.%@", fallbackIndex + 1, ext)
        return AppModel.uniqueImportName(
            for: URL(fileURLWithPath: candidate), taken: &taken)
    }
    #else
    private static let videoContentTypes: [UTType] = [
        .movie,
        .video,
        .mpeg4Movie,
        .quickTimeMovie,
        UTType(filenameExtension: "m4v") ?? .movie,
    ]

    private func handleVideoImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            importVideoURL(url)
        case .failure(let error):
            model.errorMessage = error.localizedDescription
        }
    }



    private func handleDroppedURLs(_ urls: [URL]) -> Bool {
        // A project archive dropped here is the same gesture as double-clicking
        // it in Finder, so it goes through the same door.
        if let archive = urls.first(where: ProjectArchive.isArchive) {
            model.openArchive(at: archive)
            return true
        }
        guard let videoURL = urls.first(where: isVideoURL) else {
            model.errorMessage = "Drop an MP4, MOV, or M4V video, or a LetsLapse project (.lapse)."
            return false
        }
        importVideoURL(videoURL)
        return true
    }

    private func importVideoURL(_ url: URL) {
        guard isVideoURL(url) else {
            model.errorMessage = "Choose an MP4, MOV, or M4V video file."
            return
        }

        model.importVideo(from: url)
    }

    private func isVideoURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return Self.videoContentTypes.contains { type.conforms(to: $0) }
    }
    #endif
}

// MARK: - Pieces

private struct SourceRow: View {
    var icon: String
    var iconColor: Color
    var title: String
    var isProminent = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(iconColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.system(size: 16, weight: isProminent ? .semibold : .regular))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

/// The import in flight — a folder of frames or a movie — on the Create
/// screen where it was started.
///
/// Determinate on purpose. A folder of raw frames is gigabytes and minutes —
/// the indeterminate spinner this replaces said "something is happening" for
/// long enough that the honest reading was "something has hung".
private struct MediaImportCard: View {
    var progress: AppModel.MediaImportProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: progress.name == nil ? "photo.stack" : "film")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LL.accent)
                Text(progress.caption)
                    .font(.system(size: 14))
                Spacer()
                if progress.totalBytes > 0 {
                    Text(LLFormat.bytes(progress.totalBytes))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            // Drawn rather than a `ProgressView(value:)`, for the same reason
            // the project-import sheet draws its own: the system linear bar
            // fills in the control grey on macOS whatever the tint says, and
            // a progress bar on a screen the accent owns has to be the accent.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(LL.accent)
                        .frame(width: max(0, geometry.size.width * progress.fraction))
                }
            }
            .frame(height: 5)
            .animation(.easeOut(duration: 0.25), value: progress.fraction)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .llCard()
    }
}

private struct EffectCard: View {
    var effect: CreateEffect

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EffectArt(effect: effect)
                .frame(height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(effect.title)
                .font(.system(size: 14.5, weight: .bold))
                .padding(.top, 10)
            Text(effect.subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
        }
        .padding(14)
        .llCard(cornerRadius: 18)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Hand-drawn gradient art per effect, matching the design doc's cards.
private struct EffectArt: View {
    var effect: CreateEffect

    var body: some View {
        switch effect {
        case .smoothTimelapse:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.16, green: 0.23, blue: 0.32),
                        Color(red: 0.42, green: 0.56, blue: 0.75),
                        Color(red: 0.16, green: 0.23, blue: 0.32),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(spacing: 5) {
                    Capsule()
                        .fill(.white.opacity(0.65))
                        .frame(height: 3)
                        .blur(radius: 2)
                    Capsule()
                        .fill(Color(red: 1, green: 0.86, blue: 0.59).opacity(0.6))
                        .frame(height: 2)
                        .blur(radius: 2)
                }
                .padding(.horizontal, -8)
                .offset(y: 12)
            }
        case .longExposure:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.11, blue: 0.17),
                        Color(red: 0.15, green: 0.25, blue: 0.42),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [Color(red: 0.63, green: 0.78, blue: 1).opacity(0.5), .clear],
                            center: .center,
                            startRadius: 2,
                            endRadius: 42
                        )
                    )
                    .frame(width: 90, height: 40)
                    .offset(x: -12, y: -14)
            }
        case .speedRamp:
            LinearGradient(
                colors: [
                    Color(red: 0.33, green: 0.2, blue: 0.11),
                    Color(red: 0.79, green: 0.55, blue: 0.31),
                    Color(red: 0.94, green: 0.78, blue: 0.58),
                    Color(red: 0.33, green: 0.2, blue: 0.11),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .customBlend:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.91, green: 0.89, blue: 0.86),
                        Color(red: 0.86, green: 0.84, blue: 0.79),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color(red: 0.54, green: 0.52, blue: 0.47))
            }
        }
    }
}

// MARK: - Capture presentation

extension View {
    @ViewBuilder
    func capturePresentation(
        isPresented: Binding<Bool>,
        intent: CaptureIntent
    ) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) {
            CaptureView(intent: intent)
        }
        #else
        sheet(isPresented: isPresented) {
            CaptureView(intent: intent)
                .frame(minWidth: 960, minHeight: 720)
        }
        #endif
    }
}
