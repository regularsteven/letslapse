import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    var onSourceReady: () -> Void = {}
    @State private var isImporting = false
    @State private var showCapture = false
    #if os(iOS)
    @State private var videoItem: PhotosPickerItem?
    @State private var photoItems: [PhotosPickerItem] = []
    #else
    @State private var importingVideo = false
    @State private var importingPhotos = false
    @State private var isDropTargeted = false
    #endif

    var body: some View {
        List {
            Section {
                Text("Capture or import footage, then blend a moving window of frames on the GPU — from a motion-blurred timelapse to a slow-mo → hyperlapse speed ramp, or stack stills into a synthetic long exposure.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            #if os(iOS)
            Section("Capture") {
                Button {
                    showCapture = true
                } label: {
                    Label("Capture video or interval photos", systemImage: "camera")
                }
            }
            #else
            Section("Capture") {
                Button {
                    showCapture = true
                } label: {
                    Label("Capture from webcam", systemImage: "video")
                }
            }
            #endif
            Section("Import") {
                #if os(iOS)
                PhotosPicker(selection: $videoItem, matching: .videos) {
                    Label("Import a video", systemImage: "film")
                }
                PhotosPicker(selection: $photoItems, maxSelectionCount: 500, matching: .images) {
                    Label("Import photos to stack", systemImage: "photo.stack")
                }
                #else
                Button {
                    importingVideo = true
                } label: {
                    Label("Import a video…", systemImage: "film")
                }
                Button {
                    importingPhotos = true
                } label: {
                    Label("Import photos to stack…", systemImage: "photo.stack")
                }
                #endif
            }
            if isImporting {
                Section {
                    ProgressView("Importing…")
                }
            }
            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("LetsLapse")
        .capturePresentation(isPresented: $showCapture, onSourceReady: onSourceReady)
        #if os(iOS)
        .onChange(of: videoItem) { item in
            guard let item else { return }
            importVideo(item)
        }
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            importPhotos(items)
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
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedURLs(urls)
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        #endif
    }

    #if os(iOS)
    private func importVideo(_ item: PhotosPickerItem) {
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                    model.setSource(.video(movie.url))
                    onSourceReady()
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
                onSourceReady()
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
            onSourceReady()
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
            onSourceReady()
        }
    }

    private func isVideoURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return Self.videoContentTypes.contains { type.conforms(to: $0) }
    }
    #endif
}

private extension View {
    @ViewBuilder
    func capturePresentation(
        isPresented: Binding<Bool>,
        onSourceReady: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) {
            CaptureView(onCaptureComplete: onSourceReady)
        }
        #else
        sheet(isPresented: isPresented) {
            CaptureView(onCaptureComplete: onSourceReady)
                .frame(minWidth: 960, minHeight: 720)
        }
        #endif
    }
}
