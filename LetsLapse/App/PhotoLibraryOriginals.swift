#if os(iOS)
import Foundation
import LetsLapseKit
import Photos
import UniformTypeIdentifiers

/// A library photo's RAW, read from the Photos library itself — the RAW half
/// of a RAW+JPEG pair, which is what an import of that photo should bring in.
///
/// Measured on iOS 27 on 2026-10-13, with an Adobe Project Indigo pair (the
/// "JPEG + RAW" badge in Photos) seeded into a Simulator: **nothing that hands
/// a photo from one app to another carries its RAW.**
///
/// - The photos picker registers `public.jpeg` and two private thumbnail
///   types, in every representation mode; asking it for `com.adobe.raw-image`
///   fails with "Cannot load representation".
/// - The share sheet hands over one `public.jpeg`, whatever its Format option
///   says, to an app opening it and to a share extension alike.
/// - AirDrop, Save to Files and even Export Unmodified Original write the JPG
///   alone.
/// - PhotoKit, with read access, writes the asset's `.alternatePhoto` — the
///   DNG, byte for byte the file Lightroom imports, because this is how
///   Lightroom gets it.
///
/// Read access means full access, or limited access with the photo inside the
/// app's selection: a photo picked outside it fetches as nothing. So every
/// import path asks here first and falls back to the file it was handed.
enum PhotoLibraryOriginals {

    /// Whether the library can be read at all — full access, or limited.
    static var canRead: Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return true
        default: return false
        }
    }

    /// Asks for read access the first time an import could use it. iOS shows
    /// that prompt once; any answer short of access leaves the import working
    /// exactly as before, on the file the picker or the share sheet handed
    /// over.
    static func requestAccessIfUndetermined() async {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        LLog("photos: library access answered — \(describe(status))")
    }

    /// The RAW of a photo picked in the photos picker, written into
    /// `directory` under its own file name. Nil — use the picker's file — when
    /// the library can't be read, the photo has no RAW, or the write failed.
    static func raw(
        forPicked identifier: String?, into directory: URL, taken: inout Set<String>
    ) async -> URL? {
        guard let identifier else { return nil }
        guard canRead else {
            LLog("photos: picked photo, library \(describe(PHPhotoLibrary.authorizationStatus(for: .readWrite))) — the picker's file")
            return nil
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else {
            LLog("photos: picked photo is outside LetsLapse's selected photos — the picker's file")
            return nil
        }
        guard let resource = rawResource(of: asset) else { return nil }
        return await write(resource, into: directory, taken: &taken)
    }

    /// The RAW of the library photo `file` was shared from, written into
    /// `directory`. Nil — import `file` as it is — when it is a RAW already,
    /// the library can't be read, the photo can't be found in it, or it has
    /// no RAW.
    static func raw(
        forShared file: URL, into directory: URL, taken: inout Set<String>
    ) async -> URL? {
        guard !ImportedStills.isRaw(file) else { return nil }
        let name = file.lastPathComponent
        guard canRead else {
            LLog("photos: \(name) shared in, library \(describe(PHPhotoLibrary.authorizationStatus(for: .readWrite))) — imported as handed over")
            return nil
        }
        // A day's photos may be searched; the main actor is drawing the
        // spinner meanwhile.
        let identifier = await Task.detached(priority: .userInitiated) {
            libraryIdentifier(matching: file)
        }.value
        guard let identifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else {
            LLog("photos: \(name) shared in, not found in the library — imported as handed over")
            return nil
        }
        guard let resource = rawResource(of: asset) else {
            LLog("photos: \(name) shared in, no RAW in the library — imported as handed over")
            return nil
        }
        return await write(resource, into: directory, taken: &taken)
    }

    /// The asset's RAW: the `.alternatePhoto` of a RAW+JPEG pair, or the
    /// `.photo` itself when the RAW is the primary (ProRAW, a RAW-only
    /// import). Nil for a photo that has none.
    static func rawResource(of asset: PHAsset) -> PHAssetResource? {
        PHAssetResource.assetResources(for: asset).first { resource in
            (resource.type == .alternatePhoto || resource.type == .photo)
                && (UTType(resource.uniformTypeIdentifier)?.conforms(to: .rawImage) ?? false)
        }
    }

    /// The `localIdentifier` of the library photo a shared file came out of,
    /// found by what the file still says about itself. Photos hands a photo
    /// over under its asset's own `originalFilename`, and the file keeps its
    /// EXIF capture time, which is the asset's `creationDate`. Both have to
    /// agree: the time narrows the library to a handful of photos, the name
    /// picks the one — and keeps a name a camera reused (they roll over at
    /// 9999) from matching another year's photo.
    ///
    /// Two passes. Read in the file's own zone, the time lands within seconds
    /// of `creationDate`; a file without an EXIF offset is read in this
    /// device's zone, which can be hours out, so the second pass widens to the
    /// widest zone difference there is and keeps only photos a whole number of
    /// quarter-hours away — every zone offset is one.
    static func libraryIdentifier(matching file: URL) -> String? {
        let frame = ImportedStills.frame(at: file)
        guard let captured = frame.capturedAt, frame.captureTimeSource != .fileModification
        else { return nil }
        let stem = file.deletingPathExtension().lastPathComponent
        for window: TimeInterval in [5, 26 * 3600] {
            if let found = libraryIdentifier(named: stem, around: captured, within: window) {
                return found
            }
        }
        return nil
    }

    private static func libraryIdentifier(
        named stem: String, around date: Date, within window: TimeInterval
    ) -> String? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            date.addingTimeInterval(-window) as NSDate, date.addingTimeInterval(window) as NSDate)
        var best: (identifier: String, distance: TimeInterval)?
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in
            guard let created = asset.creationDate else { return }
            let distance = abs(created.timeIntervalSince(date))
            let offQuarter = distance.truncatingRemainder(dividingBy: 900)
            guard min(offQuarter, 900 - offQuarter) <= 5 else { return }
            let named = PHAssetResource.assetResources(for: asset).contains { resource in
                URL(fileURLWithPath: resource.originalFilename).deletingPathExtension()
                    .lastPathComponent.caseInsensitiveCompare(stem) == .orderedSame
            }
            guard named, best.map({ distance < $0.distance }) ?? true else { return }
            best = (asset.localIdentifier, distance)
        }
        return best?.identifier
    }

    /// Writes `resource` into `directory` under the camera's own file name,
    /// fetching it from iCloud first when this device keeps only a preview
    /// (Optimise iPhone Storage). Nil when the write fails.
    static func write(
        _ resource: PHAssetResource, into directory: URL, taken: inout Set<String>
    ) async -> URL? {
        let fallback = "photo." + (UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? "dng")
        let original = resource.originalFilename.isEmpty ? fallback : resource.originalFilename
        let name = AppModel.uniqueImportName(for: URL(fileURLWithPath: original), taken: &taken)
        let destination = directory.appendingPathComponent(name)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await PHAssetResourceManager.default().writeData(
                for: resource, toFile: destination, options: options)
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            LLog("photos: \(name) — the RAW, from the library (\(LLFormat.bytes(Int64(bytes))))")
            return destination
        } catch {
            LLog("photos: couldn't write \(original) from the library: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }

    #if DEBUG
    /// `LL_IMPORT_LIBRARY=latest` — the newest photo in the library.
    static func newestPhotoIdentifier() -> String? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        return PHAsset.fetchAssets(with: .image, options: options).firstObject?.localIdentifier
    }

    /// `LL_SEED_PHOTOS_PAIR` — a RAW+JPEG pair saved as a camera app saves
    /// one. The JPEG goes in as bytes and the RAW as a file, the combination
    /// PhotoKit accepts for a pair.
    static func seedPair(jpeg: URL, raw: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited, let data = try? Data(contentsOf: jpeg) else {
            LLog("photos: can't seed the pair — add access \(describe(status)), or no file at \(jpeg.path)")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let photo = PHAssetResourceCreationOptions()
                photo.originalFilename = jpeg.lastPathComponent
                request.addResource(with: .photo, data: data, options: photo)
                let alternate = PHAssetResourceCreationOptions()
                alternate.originalFilename = raw.lastPathComponent
                request.addResource(with: .alternatePhoto, fileURL: raw, options: alternate)
            }
            LLog("photos: seeded the pair \(jpeg.lastPathComponent) + \(raw.lastPathComponent)")
        } catch {
            LLog("photos: seeding the pair failed: \(error.localizedDescription)")
        }
    }
    #endif

    static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "full access"
        case .limited: return "limited access"
        case .denied: return "denied or add-only"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "status \(status.rawValue)"
        }
    }
}
#endif
