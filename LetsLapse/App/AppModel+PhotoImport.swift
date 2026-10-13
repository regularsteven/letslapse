import Foundation
import LetsLapseKit
#if os(iOS)
import PhotosUI
import SwiftUI
#endif

// Photos coming in from outside the app's own Files picker: a photo opened in
// LetsLapse from another app (the image document types in App/Info.plist; iOS
// copies the file into Documents/Inbox and opens the app with it; Photos'
// share sheet offers LetsLapse for one photo at a time, under More on a
// device), Finder's Open With on the Mac, and on iOS the photos picker
// behind Create ▸ Import photos ▸ From Photos…. On iOS, a photo that is one
// half of a RAW+JPEG pair comes in as its RAW, read out of the library —
// nothing that hands a photo between apps carries the RAW
// (`PhotoLibraryOriginals`).

extension AppModel {

    static let importBusyMessage = "LetsLapse is still importing. Try again when it has finished."

    /// The app's one door for what it is handed from outside — the share
    /// sheet, the Files app, the Finder: the PicPlace sign-in callback, a
    /// `.lapse` project, or photos.
    func openURLs(_ urls: [URL]) {
        var stills: [URL] = []
        for url in urls {
            if picplace.handleCallbackURL(url) { continue }
            if url.isFileURL, ImportedStills.isStill(url) {
                stills.append(url)
            } else {
                openArchive(at: url)
            }
        }
        if !stills.isEmpty { gatherOpenedStills(stills) }
    }

    /// Opened photos arrive one event per file — and on the Mac a file that
    /// launches the app arrives twice, the scene and the app delegate both
    /// firing (see `openArchive`). They are gathered for a moment so a set
    /// becomes one import, as if it had been picked together, and a second
    /// delivery of a file just imported is dropped rather than imported again.
    private func gatherOpenedStills(_ urls: [URL]) {
        let now = Date()
        for url in urls {
            let path = url.standardizedFileURL.path
            if let last = lastOpenedStills, now.timeIntervalSince(last.at) < 5,
               last.paths.contains(path) { continue }
            guard !openedStills.contains(where: { $0.standardizedFileURL.path == path })
            else { continue }
            openedStills.append(url)
        }
        openedStillsFlush?.cancel()
        openedStillsFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.importOpenedStills()
        }
    }

    private func importOpenedStills() {
        let batch = openedStills
        openedStills = []
        openedStillsFlush = nil
        guard !batch.isEmpty else { return }
        lastOpenedStills = (Set(batch.map { $0.standardizedFileURL.path }), Date())
        #if os(iOS)
        Task { await importSharedStills(batch) }
        #else
        if !importStills(from: batch) { errorMessage = Self.importBusyMessage }
        #endif
    }

    #if os(iOS)
    /// Photos shared into LetsLapse from another app. A file that is the JPEG
    /// of a RAW+JPEG pair in the library is swapped for the RAW; anything else
    /// is imported as it was handed over. iOS's copies in `Documents/Inbox`
    /// go once the import has its own.
    private func importSharedStills(_ urls: [URL]) async {
        // On an iPhone the camera is the launch screen; an idle one closes,
        // revealing Create's progress card, and the import ends on the
        // project screen as any other does.
        cameraStandAsideRequest += 1
        preparingImport = true
        await PhotoLibraryOriginals.requestAccessIfUndetermined()
        let staging = Self.makePhotoStagingFolder()
        var taken = Set<String>()
        var resolved: [URL] = []
        for url in urls {
            LLog("photos: \(url.lastPathComponent) opened in LetsLapse (\(Self.isInboxCopy(url) ? "an Inbox copy" : "in place"))")
            let raw = await PhotoLibraryOriginals.raw(forShared: url, into: staging, taken: &taken)
            resolved.append(raw ?? url)
        }
        preparingImport = false
        let tidy = { Self.discardOpenedCopies(urls, staging: staging) }
        if !importStills(from: resolved, completion: tidy) {
            errorMessage = Self.importBusyMessage
            tidy()
        }
    }

    /// Create ▸ Import photos ▸ From Photos…: stages what was picked and hands
    /// it to the importer the Files path uses. A photo with a RAW in the
    /// library comes in as that RAW under its own name; anything else is what
    /// the picker hands over — its current format (a HEIC stays a HEIC) under
    /// the library's file name, which the picker passes along.
    func importLibraryPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        preparingImport = true
        Task {
            let directory = Self.makePhotoStagingFolder()
            var urls: [URL] = []
            var taken = Set<String>()
            var invented = Set<String>()
            for (index, item) in items.enumerated() {
                if let raw = await PhotoLibraryOriginals.raw(
                    forPicked: item.itemIdentifier, into: directory, taken: &taken) {
                    urls.append(raw)
                } else if let staged = await Self.stagePicked(
                    item, fallbackIndex: index, into: directory, taken: &taken) {
                    urls.append(staged.url)
                    if staged.invented { invented.insert(staged.url.lastPathComponent) }
                }
            }
            preparingImport = false
            // Whatever the picker handed over IS the import, one photo
            // included — a single photo registers as a photo project rather
            // than a one-frame shoot (`AppModel.importedPhotoMode`). The only
            // failure left is nothing staging at all.
            guard !urls.isEmpty else {
                try? FileManager.default.removeItem(at: directory)
                errorMessage = items.count == 1
                    ? "Couldn't load that photo."
                    : "Couldn't load those photos."
                return
            }
            // The invented names travel with the import so its reading knows
            // `photo-0001, photo-0002…` is not a camera's sequence.
            let tidy: () -> Void = { _ = try? FileManager.default.removeItem(at: directory) }
            if !importStills(from: urls, syntheticNames: invented, completion: tidy) {
                errorMessage = Self.importBusyMessage
                tidy()
            }
        }
    }

    /// One picked photo as the picker hands it over, staged under the name it
    /// came with — the library's file name — or `photo-0001` plus the
    /// extension its content type implies when it came with none, and whether
    /// it was the latter.
    private static func stagePicked(
        _ item: PhotosPickerItem, fallbackIndex: Int, into directory: URL, taken: inout Set<String>
    ) async -> (url: URL, invented: Bool)? {
        let typeExtension = item.supportedContentTypes
            .compactMap(\.preferredFilenameExtension).first ?? "jpg"
        if let picked = try? await item.loadTransferable(type: PickedStill.self) {
            defer { try? FileManager.default.removeItem(at: picked.url.deletingLastPathComponent()) }
            let stem = picked.url.deletingPathExtension().lastPathComponent
            let ext = picked.url.pathExtension.isEmpty ? typeExtension : picked.url.pathExtension
            let invented = stem.isEmpty
            let candidate = invented
                ? String(format: "photo-%04d.%@", fallbackIndex + 1, ext)
                : "\(stem).\(ext)"
            let destination = directory.appendingPathComponent(
                uniqueImportName(for: URL(fileURLWithPath: candidate), taken: &taken))
            guard (try? FileManager.default.moveItem(at: picked.url, to: destination)) != nil
            else { return nil }
            return (destination, invented)
        }
        // A representation that won't come as a file still comes as bytes.
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let destination = directory.appendingPathComponent(uniqueImportName(
            for: URL(fileURLWithPath: String(format: "photo-%04d.%@", fallbackIndex + 1, typeExtension)),
            taken: &taken))
        guard (try? data.write(to: destination)) != nil else { return nil }
        return (destination, true)
    }

    #if DEBUG
    /// `LL_IMPORT_LIBRARY` — From Photos… without the picker: the same import
    /// over items made from the library's own identifiers, `latest` meaning
    /// the newest photo.
    func importLibraryPhotos(identifiers spec: String) async {
        await PhotoLibraryOriginals.requestAccessIfUndetermined()
        let identifiers = spec == "latest"
            ? [PhotoLibraryOriginals.newestPhotoIdentifier()].compactMap { $0 }
            : spec.split(separator: ",").map(String.init)
        LLog("photos: LL_IMPORT_LIBRARY → \(identifiers.joined(separator: ", "))")
        importLibraryPhotos(identifiers.map { PhotosPickerItem(itemIdentifier: $0) })
    }
    #endif

    private static func makePhotoStagingFolder() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Removes what an import of shared photos no longer needs: the RAWs
    /// staged for it, and the copies iOS made in `Documents/Inbox` — only
    /// those. A file anywhere else is somebody's own and is never touched.
    private static func discardOpenedCopies(_ urls: [URL], staging: URL) {
        try? FileManager.default.removeItem(at: staging)
        for url in urls where isInboxCopy(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Whether `url` is a copy iOS made in `Documents/Inbox` to open a file
    /// in LetsLapse — the only files the import is ever allowed to remove.
    private static func isInboxCopy(_ url: URL) -> Bool {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return false }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
            .resolvingSymlinksInPath().path + "/"
        return url.resolvingSymlinksInPath().path.hasPrefix(inbox)
    }
    #endif
}
