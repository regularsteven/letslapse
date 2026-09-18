import Foundation
import LetsLapseKit

// A LUT is a library asset identified by its content hash
// (docs/lut-library-assets.md). The project names it, the library store
// (`LUTStore`) holds it, and these are the two boundary operations: packing
// the cubes a project names into its folder for an export or a transfer,
// and folding the cubes an arriving tree carries into this library.

/// A cube a grade names that this library cannot render — in neither the
/// store nor the folder. An export or a transfer refuses with this rather
/// than shipping a project that renders without its LUT on arrival.
struct LUTMissingError: LocalizedError {
    var names: [String]

    var errorDescription: String? {
        let list = names.map { "“\($0)”" }.joined(separator: ", ")
        return "This project uses the LUT \(list), which isn't in this library. Import the .cube first, then try again."
    }
}

extension AppModel {

    /// The cubes a project's record names — the live grade, every keyframe
    /// and the preset snapshot — each with the name a person knows it by:
    /// the snapshot's preset name when the snapshot is over that cube, else
    /// the store's file name, else the hash.
    func referencedLUTs(of capture: CaptureProject) -> [(id: String, name: String)] {
        var ids: [String] = []
        func take(_ adjustments: PhotoAdjustments?) {
            guard let id = adjustments?.lut?.id, !id.isEmpty, !ids.contains(id) else { return }
            ids.append(id)
        }
        take(capture.adjustments)
        for keyframe in capture.gradeTimeline?.keyframes ?? [] { take(keyframe.adjustments) }
        var snapshotName: (id: String, name: String)?
        if case .named(_, let snapshot)? = capture.presetState {
            take(snapshot.adjustments)
            if let id = snapshot.adjustments.lut?.id { snapshotName = (id, snapshot.name) }
        }
        return ids.map { id in
            if let snapshotName, snapshotName.id == id { return (id, snapshotName.name) }
            if let file = LUTStore.shared.file(id: id) { return (id, LUTFile.presetName(forFileName: file.fileName)) }
            return (id, String(id.prefix(12)))
        }
    }

    /// The cubes packed into a project folder for a trip, and their removal.
    struct LUTMaterialisation {
        let folder: URL
        fileprivate(set) var added: [URL] = []

        /// Removes what was added — never a legacy copy that was there
        /// before — and the `luts/` folder once it is empty.
        func remove() {
            let fileManager = FileManager.default
            for url in added { try? fileManager.removeItem(at: url) }
            let luts = LUTStore.folderURL(under: folder)
            if let left = try? fileManager.contentsOfDirectory(atPath: luts.path),
               left.allSatisfy({ $0.hasPrefix(".") }) {
                try? fileManager.removeItem(at: luts)
            }
        }
    }

    /// Writes every cube the project names into `<folder>/luts/` from the
    /// library store, with `luts/index.json` (the store's records for
    /// them), for an archive or a transfer to carry
    /// (docs/lut-library-assets.md §2.3). A cube already in the folder — a
    /// legacy copy — counts as present. Throws `LUTMissingError` naming
    /// what neither holds; nothing is left behind then.
    func materialiseLUTs(for captureID: UUID) throws -> LUTMaterialisation {
        let folder = projectFolderURL(for: captureID)
        var materialisation = LUTMaterialisation(folder: folder)
        guard let capture = capture(id: captureID) else { return materialisation }
        let referenced = referencedLUTs(of: capture)
        guard !referenced.isEmpty else { return materialisation }

        let fileManager = FileManager.default
        let store = LUTStore.shared
        let luts = LUTStore.folderURL(under: folder)
        var missing: [String] = []
        var records: [LUTFile] = []
        do {
            for (id, name) in referenced {
                if let file = store.file(id: id) { records.append(file) }
                let destination = luts.appendingPathComponent(id + ".cube")
                if fileManager.fileExists(atPath: destination.path) { continue }
                let source = store.fileURL(for: id)
                guard fileManager.fileExists(atPath: source.path) else {
                    missing.append(name)
                    continue
                }
                try fileManager.createDirectory(at: luts, withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: destination)
                materialisation.added.append(destination)
            }
            guard missing.isEmpty else { throw LUTMissingError(names: missing) }
            if !records.isEmpty {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let indexURL = luts.appendingPathComponent(LUTStore.archiveIndexName)
                try encoder.encode(records).write(to: indexURL, options: .atomic)
                materialisation.added.append(indexURL)
            }
        } catch {
            materialisation.remove()
            throw error
        }
        LLog("luts: \(materialisation.added.count) file(s) materialised into \(folder.lastPathComponent) for the trip")
        return materialisation
    }

    /// Folds the cubes an arriving tree carries into this library's store
    /// (`importCube` dedupes by hash) and makes the sender's LUT preset here
    /// when the document's state is a named preset over that cube and
    /// nothing names it yet — under the sender's preset id, so the project
    /// resolves as named (docs/lut-library-assets.md §2.4). The `luts/`
    /// folder is removed from the staging either way: it never becomes part
    /// of the project. A cube that does not parse is logged and left out.
    func adoptLUTs(fromStaging staging: URL, manifest: ProjectDocument) {
        let luts = LUTStore.folderURL(under: staging)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: luts.path) else { return }
        defer { try? FileManager.default.removeItem(at: luts) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let packed = (try? Data(contentsOf: luts.appendingPathComponent(LUTStore.archiveIndexName)))
            .flatMap { try? decoder.decode([LUTFile].self, from: $0) } ?? []
        var snapshot: PresetSnapshot?
        var snapshotPresetID: UUID?
        if case .named(let id, let named)? = manifest.capture.presetState, named.adjustments.lut != nil {
            snapshot = named
            snapshotPresetID = id
        }

        var imported = 0
        for name in names.sorted() where name.hasSuffix(".cube") {
            let stem = String(name.dropLast(".cube".count))
            guard let data = try? Data(contentsOf: luts.appendingPathComponent(name)) else { continue }
            let fileName = packed.first { $0.id == stem }?.fileName
                ?? (snapshot?.adjustments.lut?.id == stem ? snapshot.map { $0.name + ".cube" } : nil)
                ?? name
            do {
                let file = try LUTStore.shared.importCube(data: data, fileName: fileName)
                imported += 1
                if let snapshot, let snapshotPresetID, snapshot.adjustments.lut?.id == file.id {
                    let presets = CustomPresetStore.shared
                    if !presets.presets.contains(where: { $0.id == snapshotPresetID || $0.lut?.id == file.id }) {
                        presets.add(CustomPreset(
                            id: snapshotPresetID, name: presets.uniqueName(for: snapshot.name),
                            basePreset: snapshot.basePreset, adjustments: snapshot.adjustments))
                        LLog("luts: made the preset “\(snapshot.name)” from the arriving project's snapshot")
                    }
                }
            } catch {
                LLog("luts: \(name) in the arriving project does not parse (\(error)) — left out")
            }
        }
        if imported > 0 {
            LLog("luts: \(imported) cube(s) from the arriving project folded into the library store")
        }
    }
}
