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
    /// "Import a LetsLapse project…" asks where from before it does anything —
    /// a `.lapse` file, or straight off another device over the network. Both
    /// answers are "import a project", so they belong behind one row rather
    /// than as two entries that would have to explain the difference in their
    /// titles.
    @State private var choosingImportSource = false
    /// Interval ladders — Ladder MODE's tables, managed from here as well as
    /// from the capture screen's ladder chip. The selection is the capture
    /// screen's; it is mirrored here so "Use this ladder" arms the next shoot.
    @State private var showLadders = false
    @State private var selectedLadderID: UUID? = RecordingSettingsStore.ladderID
    /// Where the ladders sheet opens — empty for the list; the `LL_LADDERS`
    /// hook pushes an editor or a rung (DEBUG only, set on appear).
    @State private var laddersInitialPath: [LadderRoute] = []
    /// The Presets sheet — LetsLapse's looks, the saved ones, imported LUTs
    /// and the import door — managed from here, one row under the ladders.
    /// `LL_PRESETS` opens it pushed to a preset, a LUT, or onto the chooser.
    @State private var showPresets = false
    @State private var showShapemation = false
    @State private var shapemationInitialPath: [ShapemationRoute] = []
    @State private var presetsInitialPath: [PresetRoute] = []
    @State private var presetsInitialImport = false
    #if os(iOS)
    @State private var showDeviceImport = false
    #else
    @Environment(\.openWindow) private var openWindow
    #endif
    #if os(iOS)
    @State private var videoItem: PhotosPickerItem?
    @State private var photoItems: [PhotosPickerItem] = []
    /// "Import photos" asks where from on iOS, for the same reason
    /// the project row does: the Photos library and the Files app are two
    /// genuinely different answers, and only one of them can hand over a
    /// camera's raw files under their own names.
    @State private var choosingPhotoSource = false
    @State private var pickingLibraryPhotos = false
    #else
    @State private var isDropTargeted = false
    #endif
    /// What the Files/Finder picker is currently being opened for. Held apart
    /// from `isPickingFiles` and never cleared on dismissal, so the picker's
    /// content types, its multi-select and its completion all read the same
    /// answer for the whole presentation.
    @State private var filePick: FilePick = .stills
    /// The Files/Finder picker, on every platform — the path that reaches a
    /// card, a drive or an iCloud folder, and the only one that preserves the
    /// camera's own file names. ONE importer for all three jobs; see
    /// `pickFiles(for:)` for why it is not three.
    @State private var isPickingFiles = false

    private static let projectArchiveTypes: [UTType] = [.lapseProject]

    /// What the stills picker will accept. `.image` already covers every raw
    /// format the system knows (`com.sony.arw-raw-image` and its siblings all
    /// conform to `public.camera-raw-image`, which conforms to `public.image`);
    /// `.rawImage` is named anyway so a body whose files the system types only
    /// as raw is still selectable, and `.folder` is what lets a whole shoot be
    /// chosen in one gesture instead of 306 clicks.
    private static let stillContentTypes: [UTType] = [.image, .rawImage, .folder]

    /// The three jobs the one Files/Finder picker does. `video` is macOS only
    /// — iOS imports a video through `PhotosPicker` — but the case exists on
    /// both so the routing has no platform branches in it.
    private enum FilePick {
        case project
        case stills
        case video

        var contentTypes: [UTType] {
            switch self {
            case .project: return CreateView.projectArchiveTypes
            case .stills: return CreateView.stillContentTypes
            #if os(iOS)
            case .video: return [.movie]
            #else
            case .video: return CreateView.videoContentTypes
            #endif
            }
        }

        /// Only a stack takes more than one answer: a project archive and a
        /// video are each one file.
        var allowsMultipleSelection: Bool { self == .stills }
    }

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
            // `LL_TRANSFER_PAIR` — the same sheet, parked on the pairing
            // screen with its QR scanner live and no peer required. See
            // `ProjectTransferClient.stagePairing`.
            if environment["LL_TRANSFER_PAIR"] != nil {
                showDeviceImport = true
            }
            #endif
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
            // `LL_PRESETS=list|preset|lut|import` — the Presets sheet on the
            // requested screen. Every value seeds the four saved presets and
            // two LUTs the design draws when the stores are empty (simulator
            // data, written to the same files a real save or import writes);
            // `preset` opens Sunny Nature, `lut` opens Teal and Orange,
            // `import` drops the chooser.
            if let screen = environment["LL_PRESETS"] {
                ManagePresetsView.debugSeed()
                switch screen {
                case "preset":
                    presetsInitialPath = ManagePresetsView.debugRoute(named: "Sunny Nature").map { [$0] } ?? []
                case "lut":
                    presetsInitialPath = ManagePresetsView.debugRoute(named: "Teal and Orange").map { [$0] } ?? []
                case "import":
                    presetsInitialImport = true
                default:
                    break
                }
                showPresets = true
            }
            // `LL_SHAPEMATION=home|find|build|list` — the Shape-mation sheet on
            // the requested screen, over whatever the library holds.
            if let screen = environment["LL_SHAPEMATION"] {
                switch screen {
                case "find": shapemationInitialPath = [.find]
                case "build": shapemationInitialPath = [.build]
                case "list": shapemationInitialPath = [.list]
                default: shapemationInitialPath = []
                }
                showShapemation = true
            }
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
        .sheet(isPresented: $showDeviceImport) {
            ProjectTransferImportView()
                .environmentObject(model)
        }
        #else
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
        // ONE picker for the archive, the stack and (on the Mac) the video.
        // See `pickFiles(for:)`.
        .fileImporter(
            isPresented: $isPickingFiles,
            allowedContentTypes: filePick.contentTypes,
            allowsMultipleSelection: filePick.allowsMultipleSelection
        ) { result in
            handleFilePick(result)
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

            Divider().padding(.leading, 58)

            laddersRow

            Divider().padding(.leading, 58)

            presetsRow

            Divider().padding(.leading, 58)

            shapemationRow
        }
        .llCard(cornerRadius: 18)
    }

    /// The Shape-mation sheet (`ShapemationHomeView`): find shapes across the
    /// library, build a shape slideshow, list the videos. A sheet on every
    /// platform like the two rows above it. Code first 2026-09-10; SVG owed.
    private var shapemationRow: some View {
        Button {
            showShapemation = true
        } label: {
            SourceRow(
                icon: "circle.square",
                iconColor: Color(red: 0x6E / 255, green: 0x5A / 255, blue: 0xC8 / 255),
                title: "Create Shape-mation"
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showShapemation) {
            ShapemationHomeView(initialPath: shapemationInitialPath)
                .environmentObject(model)
        }
    }

    /// The Presets sheet (`ManagePresetsView`). A sheet on every platform,
    /// as the ladders are: the list owns its own navigation, so a later door
    /// from the Edit screen presents it the same way.
    private var presetsRow: some View {
        Button {
            showPresets = true
        } label: {
            SourceRow(
                icon: "camera.filters",
                iconColor: Color(red: 0x3F / 255, green: 0x7D / 255, blue: 0x6E / 255),
                title: "Manage presets"
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPresets) {
            ManagePresetsView(initialPath: presetsInitialPath, initialImport: presetsInitialImport)
                .environmentObject(model)
        }
    }

    /// Interval's Ladder MODE tables. A sheet here as on the capture screen:
    /// the list owns its own navigation (editor, rung), so it presents the
    /// same way from both doors — and on every platform: the Mac steps its
    /// ladder by hand (`CaptureView.ladderStepsByHand`) and is the best
    /// place to author one.
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
            Button("From a file…") { pickFiles(for: .project) }
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
            pickFiles(for: .video)
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
            pickFiles(for: .stills)
            #endif
        } label: {
            SourceRow(
                icon: "photo.stack",
                iconColor: Color(red: 0.48, green: 0.42, blue: 0.61),
                title: "Import photos…")
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .confirmationDialog(
            "Import photos",
            isPresented: $choosingPhotoSource,
            titleVisibility: .visible
        ) {
            Button("From Files…") { pickFiles(for: .stills) }
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

    /// Opens the one Files/Finder picker for `pick`.
    ///
    /// Two mechanics here, both of them regressions we have already had:
    ///
    /// - **One importer, not three.** `.fileImporter` modifiers stacked on a
    ///   single view fight over the presentation; the picker's content types
    ///   and multi-select come from `filePick` instead, and only the flag
    ///   below says whether it is up.
    /// - **Presented a turn late.** Two of the three callers are confirmation
    ///   dialog buttons, and a picker presented while the dialog is still
    ///   dismissing is dropped with no error and no log line — which is
    ///   exactly how "Import a LetsLapse project ▸ From a file…" stopped
    ///   opening anything when that dialog arrived (b9befa1). Setting the
    ///   target first and presenting on the next turn also guarantees the
    ///   modifier already carries the right content types when it opens.
    private func pickFiles(for pick: FilePick) {
        filePick = pick
        DispatchQueue.main.async { isPickingFiles = true }
    }

    /// The one picker's answer, routed by what it was opened for. `filePick`
    /// survives the dismissal, so this is always reading the job that was
    /// actually asked for.
    private func handleFilePick(_ result: Result<[URL], Error>) {
        // A stack takes the whole selection; the other two are one file each,
        // so they share the unwrap.
        if filePick == .stills {
            handleStillsImport(result)
            return
        }
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            switch filePick {
            case .project: model.openArchive(at: url)
            case .video:
                #if os(macOS)
                importVideoURL(url)
                #endif
            case .stills: break
            }
        case .failure(let error):
            model.errorMessage = error.localizedDescription
        }
    }

    /// The Files/Finder answer for "Import photos", on every
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
            // Whatever the picker handed over IS the import, one photo
            // included — a single photo registers as a photo project rather
            // than a one-frame shoot (`AppModel.importedPhotoMode`). The only
            // failure left is nothing staging at all.
            guard !urls.isEmpty else {
                model.errorMessage = items.count == 1
                    ? "Couldn't load that photo."
                    : "Couldn't load those photos."
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
