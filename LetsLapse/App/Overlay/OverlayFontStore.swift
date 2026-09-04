import CoreText
import Foundation

/// Fonts a project brought with it: TTF/OTF files copied into the project's
/// `fonts/` folder (listed in `ProjectArchive.transferableSubfolders`, so
/// they travel in `.lapse` archives and device transfers) and registered
/// with the font manager for this process, so the rasterizer resolves them
/// by family name exactly like an installed face.
///
/// The file is copied, never referenced in place: the pick is a
/// sandbox-scoped URL that is gone by the next launch, and the face has to
/// survive an archive round trip.
enum OverlayFontStore {

    /// One imported face: the family the picker lists, and the file it came
    /// from.
    struct ImportedFont: Identifiable, Equatable, Hashable {
        var family: String
        var fileName: String
        var id: String { fileName }
    }

    /// The families every registered file in `folder` provides, sorted.
    /// Registers on the way through, so the first call for a project is the
    /// one that makes its faces resolvable.
    static func importedFonts(in folder: URL) -> [ImportedFont] {
        registerFonts(in: folder)
        return fontFiles(in: folder).compactMap { url in
            familyName(of: url).map { ImportedFont(family: $0, fileName: url.lastPathComponent) }
        }
        .sorted { $0.family.localizedCaseInsensitiveCompare($1.family) == .orderedAscending }
    }

    /// Copies a picked font into the project and registers it. Returns the
    /// family it provides.
    static func importFont(from source: URL, into folder: URL) throws -> ImportedFont {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let family = familyName(of: source) else {
            throw NSError(
                domain: "OverlayFontStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "That file could not be read as a font (TTF or OTF)."])
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Keep the file's own name — it is what someone will recognise in the
        // folder — but never clobber a different file that shares it.
        var name = source.lastPathComponent
        var destination = folder.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path),
              familyName(of: destination) != family {
            name = "\(source.deletingPathExtension().lastPathComponent)-\(suffix).\(source.pathExtension)"
            destination = folder.appendingPathComponent(name)
            suffix += 1
        }
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        register(destination)
        return ImportedFont(family: family, fileName: name)
    }

    /// Registers every font file in `folder` with this process. Idempotent:
    /// a file that is already registered is left alone.
    static func registerFonts(in folder: URL) {
        for url in fontFiles(in: folder) { register(url) }
    }

    // MARK: - Internals

    private static let registered = LockedSet()

    private static func register(_ url: URL) {
        guard registered.insert(url.standardizedFileURL.path) else { return }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error),
           let error = error?.takeRetainedValue() {
            let code = CFErrorGetCode(error)
            // Already registered (by a previous launch's Xcode session, or
            // a duplicate file) is not a failure worth a log line.
            if code != CTFontManagerError.alreadyRegistered.rawValue {
                LLog("font store: could not register \(url.lastPathComponent): \(error)")
            }
        }
    }

    private static func fontFiles(in folder: URL) -> [URL] {
        let extensions: Set<String> = ["ttf", "otf", "ttc"]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The family name a font file provides, read from the file itself
    /// without registering it.
    static func familyName(of url: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                as? [CTFontDescriptor],
              let first = descriptors.first,
              let family = CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String,
              !family.isEmpty
        else { return nil }
        return family
    }

    /// A set with a lock: registration is called from the editor's main
    /// actor and from a detached export task.
    private final class LockedSet: @unchecked Sendable {
        private var values: Set<String> = []
        private let lock = NSLock()
        /// True when the value was new.
        func insert(_ value: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return values.insert(value).inserted
        }
    }
}

extension AppModel {
    /// Listed in `ProjectArchive.transferableSubfolders`.
    static let overlayFontsFolderName = "fonts"

    /// The project's imported-font folder. Created on demand by the importer.
    func overlayFontsFolderURL(for capture: CaptureProject) -> URL {
        projectFolderURL(for: capture)
            .appendingPathComponent(Self.overlayFontsFolderName, isDirectory: true)
    }

    /// The faces this project brought with it, registered and ready to use.
    func importedOverlayFonts(for capture: CaptureProject) -> [OverlayFontStore.ImportedFont] {
        OverlayFontStore.importedFonts(in: overlayFontsFolderURL(for: capture))
    }

    /// Copies a picked TTF/OTF into the project and returns its family.
    func importOverlayFont(from source: URL, for capture: CaptureProject) throws -> OverlayFontStore.ImportedFont {
        try OverlayFontStore.importFont(from: source, into: overlayFontsFolderURL(for: capture))
    }
}
