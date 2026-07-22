import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// What a tap on an effect card should set up before the camera opens.
struct CaptureIntent: Equatable {
    var mode: CaptureMode = .video
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
    @State private var isImporting = false
    @State private var showCapture = false
    @State private var captureIntent = CaptureIntent()
    @State private var importingProject = false
    #if os(iOS)
    @State private var videoItem: PhotosPickerItem?
    @State private var photoItems: [PhotosPickerItem] = []
    #else
    @State private var importingVideo = false
    @State private var importingPhotos = false
    @State private var isDropTargeted = false
    #endif

    private static let projectArchiveTypes: [UTType] = [
        UTType(filenameExtension: ProjectArchive.fileExtension) ?? .data,
    ]

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

                if isImporting {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Importing…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .llCard()
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .llCard()
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }

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
            if ProcessInfo.processInfo.environment["LL_CAPTURE"] == "1" {
                showCapture = true
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
            importPhotos(items)
        }
        .fileImporter(
            isPresented: $importingProject,
            allowedContentTypes: Self.projectArchiveTypes
        ) { result in
            if case .success(let url) = result {
                Task { await model.importProject(from: url) }
            }
        }
        #else
        .fileImporter(isPresented: $importingVideo, allowedContentTypes: Self.videoContentTypes) { result in
            handleVideoImport(result)
        }
        .fileImporter(
            isPresented: $importingPhotos,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            handlePhotosImport(result)
        }
        .fileImporter(
            isPresented: $importingProject,
            allowedContentTypes: Self.projectArchiveTypes
        ) { result in
            if case .success(let url) = result {
                Task { await model.importProject(from: url) }
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
        }
        .llCard(cornerRadius: 18)
    }

    private var importProjectRow: some View {
        Button {
            importingProject = true
        } label: {
            SourceRow(
                icon: "shippingbox",
                iconColor: Color(red: 0.56, green: 0.45, blue: 0.32),
                title: "Import a LetsLapse project…"
            )
        }
        .buttonStyle(.plain)
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
        #if os(iOS)
        PhotosPicker(selection: $photoItems, maxSelectionCount: 500, matching: .images) {
            SourceRow(icon: "photo.stack", iconColor: Color(red: 0.48, green: 0.42, blue: 0.61), title: "Import photos to stack")
        }
        .buttonStyle(.plain)
        #else
        Button {
            importingPhotos = true
        } label: {
            SourceRow(icon: "photo.stack", iconColor: Color(red: 0.48, green: 0.42, blue: 0.61), title: "Import photos to stack…")
        }
        .buttonStyle(.plain)
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

    #if os(iOS)
    private func importVideo(_ item: PhotosPickerItem) {
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                    model.setSource(.video(movie.url))
                } else {
                    model.errorMessage = "Couldn't load that video."
                }
            } catch {
                model.errorMessage = error.localizedDescription
            }
            videoItem = nil
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        isImporting = true
        Task {
            defer { isImporting = false }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var urls: [URL] = []
            for (index, item) in items.enumerated() {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let url = directory.appendingPathComponent(String(format: "photo-%04d", index))
                    if (try? data.write(to: url)) != nil {
                        urls.append(url)
                    }
                }
            }
            photoItems = []
            if urls.count >= 2 {
                model.setSource(.photos(urls))
            } else {
                model.errorMessage = "Pick at least two photos to stack."
            }
        }
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

    private func handlePhotosImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard urls.count >= 2 else {
                model.errorMessage = "Pick at least two photos to stack."
                return
            }
            for url in urls {
                _ = url.startAccessingSecurityScopedResource()
            }
            model.setSource(.photos(urls))
        case .failure(let error):
            model.errorMessage = error.localizedDescription
        }
    }

    private func handleDroppedURLs(_ urls: [URL]) -> Bool {
        guard let videoURL = urls.first(where: isVideoURL) else {
            model.errorMessage = "Drop an MP4, MOV, or M4V video file."
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

        isImporting = true
        Task {
            defer { isImporting = false }
            model.setSource(.video(url))
        }
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
