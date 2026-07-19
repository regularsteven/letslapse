import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var isImporting = false
    #if os(iOS)
    @State private var showCapture = false
    @State private var videoItem: PhotosPickerItem?
    @State private var photoItems: [PhotosPickerItem] = []
    #else
    @State private var importingVideo = false
    @State private var importingPhotos = false
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
        .navigationTitle("Let's Lapse")
        #if os(iOS)
        .fullScreenCover(isPresented: $showCapture) {
            CaptureView()
        }
        .onChange(of: videoItem) { item in
            guard let item else { return }
            importVideo(item)
        }
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            importPhotos(items)
        }
        #else
        .fileImporter(isPresented: $importingVideo, allowedContentTypes: [.movie]) { result in
            handleVideoImport(result)
        }
        .fileImporter(
            isPresented: $importingPhotos,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            handlePhotosImport(result)
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
    private func handleVideoImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            _ = url.startAccessingSecurityScopedResource()
            model.setSource(.video(url))
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
    #endif
}
