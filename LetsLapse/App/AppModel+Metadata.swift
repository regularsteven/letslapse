import Foundation
import LetsLapseKit

// The per-asset records and the metadata panel's model: what a project's
// frames and blends are (bytes, hash), what their files said (`imported`),
// and what a person changed here (`edited`) — resolved through the chain
// asset edited → project edited → asset imported → project imported
// (docs/data-model-scale-and-metadata-2026-09-12.md §4.3).

extension AppModel {

    /// Which record the panel is reading and writing.
    enum MetadataScope: Equatable {
        /// The project-level record (`metadata.json`) — the whole shoot, and
        /// the one record a Photo project has.
        case project
        /// One frame's own line in `assets.ndjson`, by relative name.
        case frame(String)
    }

    /// Where a resolved value came from.
    enum MetadataOrigin: Equatable {
        /// A person set it here, in the scope named.
        case edited(MetadataScope)
        /// The file (or its sidecar) said so.
        case imported
    }

    /// A resolved record with, per field, the layer that answered.
    struct ResolvedMetadata {
        var value: AssetMetadata
        var origins: [MetadataField: MetadataOrigin]
        var importedSource: String?

        func origin(_ field: MetadataField) -> MetadataOrigin? { origins[field] }
        func isEdited(_ field: MetadataField) -> Bool {
            if case .edited? = origins[field] { return true }
            return false
        }
    }

    // MARK: - Reading

    /// Every asset a project lists: its frames (never the sidecars) and its
    /// blend outputs — the names `assets.ndjson` is keyed by.
    func assetNames(for capture: CaptureProject) -> [String] {
        capture.sourceFileNames.filter { !$0.hasSuffix(".json") }
            + blends(for: capture).map(\.outputFileName)
    }

    /// The frames the panel can scope to, in shoot order.
    func frameNames(for capture: CaptureProject) -> [String] {
        capture.sourceFileNames.filter { !$0.hasSuffix(".json") }
    }

    func assetRecords(for capture: CaptureProject) -> AssetRecords {
        assetStore.records(inProjectFolder: projectFolderURL(for: capture))
    }

    func projectMetadata(for capture: CaptureProject) -> ProjectMetadata? {
        assetStore.projectMetadata(inProjectFolder: projectFolderURL(for: capture))
    }

    /// The record the panel shows for `scope`, field by field with its origin.
    func resolvedMetadata(for capture: CaptureProject, scope: MetadataScope) -> ResolvedMetadata {
        let project = projectMetadata(for: capture)
        let records = assetRecords(for: capture)
        let frames = frameNames(for: capture)
        // A one-asset project's own frame answers for the project.
        let single = frames.count == 1 ? records[frames[0]] : nil

        var layers: [(AssetMetadata?, MetadataOrigin)] = []
        switch scope {
        case .project:
            layers = [
                (project?.edited, .edited(.project)),
                (single?.edited, .edited(.project)),
                (project?.imported, .imported),
                (single?.imported, .imported),
            ]
        case .frame(let name):
            let record = records[name]
            layers = [
                (record?.edited, .edited(.frame(name))),
                (project?.edited, .edited(.project)),
                (record?.imported, .imported),
                (project?.imported, .imported),
            ]
        }
        var value = AssetMetadata()
        var origins: [MetadataField: MetadataOrigin] = [:]
        for field in MetadataField.allCases {
            for (layer, origin) in layers {
                if let v = layer?[field] {
                    value[field] = v
                    origins[field] = origin
                    break
                }
            }
        }
        let source: String?
        if case .frame(let name) = scope { source = records[name]?.importedSource ?? project?.importedSource }
        else { source = project?.importedSource ?? single?.importedSource }
        return ResolvedMetadata(value: value, origins: origins, importedSource: source)
    }

    /// The project's keywords as the panel and the tag chips show them —
    /// the resolved project-level `keywords`, falling back to the manifest's
    /// `sceneTags` (which is kept in step as the searchable cache).
    func resolvedKeywords(for capture: CaptureProject) -> [String] {
        resolvedMetadata(for: capture, scope: .project).value.keywords
            ?? captures.first { $0.id == capture.id }?.sceneTags ?? []
    }

    // MARK: - Editing

    /// Sets one field in the `edited` layer of `scope`; nil reverts the
    /// field to what the file said. Never touches the original file or the
    /// `imported` layer.
    func setMetadata(_ value: MetadataValue?, for field: MetadataField, on capture: CaptureProject, scope: MetadataScope) {
        let folder = projectFolderURL(for: capture)
        let cleaned = Self.cleanedMetadataValue(value, for: field)
        do {
            switch scope {
            case .project:
                if field == .keywords {
                    // Tags ARE keywords: the one door onto both the manifest
                    // cache and the edited layer. A revert (nil) lands the
                    // file's own keywords back in the cache, so the sidebar
                    // and search keep seeing them.
                    let target = cleaned?.listValue ?? importedProjectKeywords(for: capture) ?? []
                    setSceneTags(target, on: capture)
                    // `setSceneTags` stands down when the cache already
                    // matches; the edited layer still has to be settled.
                    writeProjectKeywords(target, for: capture)
                    return
                }
                try assetStore.updateProject(inProjectFolder: folder) { metadata in
                    var edited = metadata.edited ?? AssetMetadata()
                    edited[field] = cleaned
                    metadata.edited = edited.isEmpty ? nil : edited
                    var stamps = metadata.editedAt ?? [:]
                    stamps[field.rawValue] = cleaned == nil ? nil : Date()
                    metadata.editedAt = stamps.isEmpty ? nil : stamps
                }
            case .frame(let name):
                try assetStore.update(inProjectFolder: folder, name: name) { record in
                    var edited = record.edited ?? AssetMetadata()
                    edited[field] = cleaned
                    record.edited = edited.isEmpty ? nil : edited
                    var stamps = record.editedAt ?? [:]
                    stamps[field.rawValue] = cleaned == nil ? nil : Date()
                    record.editedAt = stamps.isEmpty ? nil : stamps
                }
            }
        } catch {
            errorMessage = "Couldn't save that change: \(error.localizedDescription)"
            LLog("metadata: write failed for \(capture.id.uuidString.prefix(8)) \(field.rawValue): \(error)")
            return
        }
        markEdited(capture.id)
        try? persistLibrary()
        metadataRevision += 1
    }

    func revertMetadata(_ field: MetadataField, on capture: CaptureProject, scope: MetadataScope) {
        setMetadata(nil, for: field, on: capture, scope: scope)
    }

    /// Trimmed text; an empty string is a removal. A rating outside 0…5 is
    /// clamped; a list is trimmed of blanks.
    static func cleanedMetadataValue(_ value: MetadataValue?, for field: MetadataField) -> MetadataValue? {
        guard let value else { return nil }
        switch value {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(trimmed)
        case .list(let items):
            let cleaned = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return cleaned.isEmpty ? nil : .list(cleaned)
        case .integer(let number):
            return field == .rating ? .integer(min(max(number, 0), 5)) : .integer(number)
        case .number:
            return value
        }
    }

    /// Writes the project's keywords into the edited layer beside the
    /// manifest cache — `setSceneTags` calls this, so the tag editor and the
    /// Keywords row are one field.
    func writeProjectKeywords(_ keywords: [String], for capture: CaptureProject) {
        let folder = projectFolderURL(for: capture)
        // Equal to what the file said → no edit to record; a revert.
        let sameAsImported = keywords == importedProjectKeywords(for: capture)
        try? assetStore.updateProject(inProjectFolder: folder) { metadata in
            var edited = metadata.edited ?? AssetMetadata()
            edited.keywords = (keywords.isEmpty || sameAsImported) ? nil : keywords
            metadata.edited = edited.isEmpty ? nil : edited
            var stamps = metadata.editedAt ?? [:]
            stamps[MetadataField.keywords.rawValue] = edited.keywords == nil ? nil : Date()
            metadata.editedAt = stamps.isEmpty ? nil : stamps
        }
        metadataRevision += 1
    }

    /// The project's keywords as its files said them: the project record's
    /// imported layer, else a one-asset project's own frame.
    func importedProjectKeywords(for capture: CaptureProject) -> [String]? {
        if let keywords = projectMetadata(for: capture)?.imported?.keywords { return keywords }
        let frames = frameNames(for: capture)
        guard frames.count == 1 else { return nil }
        return assetRecords(for: capture)[frames[0]]?.imported?.keywords
    }

    // MARK: - Recording

    /// Hashes the project's assets and reads their imported metadata in the
    /// background — at registration, and by the launch backfill. When the
    /// walk ends, a project with no tags of its own takes the keywords its
    /// files carried, so the chips and search see them.
    func recordAssets(for capture: CaptureProject, extractMetadata: Bool = true,
                      priority: DispatchQoS = .utility, pausable: Bool = false) {
        let names = assetNames(for: capture)
        guard !names.isEmpty else { return }
        let id = capture.id
        assetStore.recordAssets(
            inProjectFolder: projectFolderURL(for: capture), names: names,
            extractMetadata: extractMetadata, priority: priority, pausable: pausable
        ) { [weak self] outcome in
            guard let self else { return }
            self.metadataRevision += 1
            if let keywords = outcome.projectImported?.keywords {
                self.seedSceneTags(keywords, on: id)
            }
        }
    }

    /// The W5 backfill: every project whose `assets.ndjson` is incomplete,
    /// newest first, one file at a time, after the launch has settled.
    /// Resumable by construction — each finished file is its own line.
    func scheduleAssetBackfill(after delay: TimeInterval = 20) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            let projects = self.captures.sorted { self.addedAt($0) > self.addedAt($1) }
            var queued = 0
            for capture in projects {
                let folder = self.projectFolderURL(for: capture)
                let names = self.assetNames(for: capture)
                guard !names.isEmpty else { continue }
                let records = self.assetStore.records(inProjectFolder: folder)
                let needsHash = !records.namesNeedingHash(among: names, in: folder).isEmpty
                let needsMetadata = names.contains { AssetRecordStore.isSourceStill($0) && records[$0]?.imported == nil }
                    && self.projectMetadata(for: capture)?.imported == nil
                guard needsHash || needsMetadata else {
                    self.assetStore.compactIfNeeded(inProjectFolder: folder)
                    continue
                }
                self.recordAssets(for: capture, extractMetadata: true, priority: .background, pausable: true)
                queued += 1
            }
            if queued > 0 { LLog("assets: backfill queued \(queued) projects") }
        }
    }
}
