import Foundation
import ImageIO
import AVFoundation

/// Walks the catalogue read-only and resolves one representative image per shoot.
enum InventoryBuilder {
    static let renderedExts: Set<String> = ["jpg", "jpeg", "heic", "heif", "png"]
    static let rawExts: Set<String> = ["dng", "arw", "raw", "cr2", "cr3", "nef", "raf"]
    static let videoExts: Set<String> = ["mov", "mp4", "m4v"]

    static func build(catalogue: URL, log: RunLog, limit: Int?, only: [String]) async -> Inventory {
        let fm = FileManager.default
        // Accept either the storage root (…/LetsLapse) or the Projects folder itself.
        var projects = catalogue.appendingPathComponent("Projects")
        if !fm.fileExists(atPath: projects.appendingPathComponent("library.json").path),
           fm.fileExists(atPath: catalogue.appendingPathComponent("library.json").path) {
            projects = catalogue
        }
        let manifestURL = projects.appendingPathComponent("library.json")
        log.line("catalogue: \(projects.path)")

        var captures: [[String: Any]] = []
        var blendsByCapture: [String: [[String: Any]]] = [:]
        if let data = try? Data(contentsOf: manifestURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            captures = root["captures"] as? [[String: Any]] ?? []
            for b in root["blends"] as? [[String: Any]] ?? [] {
                if let cid = b["captureID"] as? String { blendsByCapture[cid, default: []].append(b) }
            }
            log.line("library.json: \(captures.count) captures, \(blendsByCapture.values.reduce(0) { $0 + $1.count }) blends, schema \(root["gradingSchemaVersion"] ?? "?")")
        } else {
            log.note("manifest-unreadable", "\(manifestURL.path) — falling back to folder walk only")
        }

        var assets: [Asset] = []
        var skipped: [SkippedShoot] = []
        var listedIDs = Set<String>()

        for c in captures {
            guard let id = c["id"] as? String else { log.note("capture-no-id", "\(c.keys.sorted())"); continue }
            listedIDs.insert(id)
            if !only.isEmpty, !only.contains(where: { id.hasPrefix($0) }) { continue }
            let mode = c["mode"] as? String ?? "?"
            let kind = c["kind"] as? String ?? "?"
            let name = c["name"] as? String ?? c["originalName"] as? String ?? id
            let dir = projects.appendingPathComponent(id)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                log.note("folder-missing", "\(id) (\(mode))")
                skipped.append(SkippedShoot(id: id, reason: "folder-missing", mode: mode)); continue
            }
            let family: AssetFamily
            if mode.hasPrefix("Photo") { family = .still }
            else if kind == "video" {
                log.note("skip-video-source", "\(id) (\(mode))")
                skipped.append(SkippedShoot(id: id, reason: "video-source", mode: mode)); continue
            } else { family = .interval }

            let createdAt = (c["createdAt"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) }
                ?? folderDate(dir)
            let sources = (c["sourceFileNames"] as? [String] ?? [])
            let blends = (blendsByCapture[id] ?? []).sorted { ($0["createdAt"] as? Double ?? 0) > ($1["createdAt"] as? Double ?? 0) }

            if let asset = await resolve(id: id, family: family, mode: mode, name: name, dir: dir,
                                         sources: sources, blends: blends, createdAt: createdAt,
                                         listed: true, log: log) {
                assets.append(asset)
            } else {
                skipped.append(SkippedShoot(id: id, reason: "no-representative", mode: mode))
            }
            if let limit, assets.count >= limit { break }
        }

        // Folders the manifest does not list (orphans, un-finalised shoots).
        if limit == nil || assets.count < limit! {
            let entries = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let id = dir.lastPathComponent
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, !listedIDs.contains(id) else { continue }
                if id.hasPrefix(".") { continue }
                if !only.isEmpty, !only.contains(where: { id.hasPrefix($0) }) { continue }
                log.note("unlisted-folder", "\(id)")
                let srcDir = dir.appendingPathComponent("source")
                let files = ((try? fm.contentsOfDirectory(atPath: srcDir.path)) ?? []).sorted().map { "source/\($0)" }
                let hasVideo = files.contains { videoExts.contains(($0 as NSString).pathExtension.lowercased()) }
                let hasStills = files.contains { renderedExts.contains(($0 as NSString).pathExtension.lowercased()) || rawExts.contains(($0 as NSString).pathExtension.lowercased()) }
                if hasVideo && !hasStills {
                    log.note("skip-video-source", "\(id) (unlisted)")
                    skipped.append(SkippedShoot(id: id, reason: "video-source", mode: "unlisted")); continue
                }
                if let asset = await resolve(id: id, family: .interval, mode: "unlisted", name: id, dir: dir,
                                             sources: files, blends: [], createdAt: folderDate(dir),
                                             listed: false, log: log) {
                    assets.append(asset)
                } else {
                    skipped.append(SkippedShoot(id: id, reason: "no-representative", mode: "unlisted"))
                }
                if let limit, assets.count >= limit { break }
            }
        }
        return Inventory(catalogue: projects.path, scannedAt: Date(), assets: assets, skipped: skipped)
    }

    private static func folderDate(_ dir: URL) -> Date {
        (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(timeIntervalSince1970: 0)
    }

    /// Representative image order: blend image → blend video (mid frame) → rendered frame → raw.
    private static func resolve(id: String, family: AssetFamily, mode: String, name: String, dir: URL,
                                sources: [String], blends: [[String: Any]], createdAt: Date,
                                listed: Bool, log: RunLog) async -> Asset? {
        let fm = FileManager.default
        func ext(_ s: String) -> String { (s as NSString).pathExtension.lowercased() }
        let existing = sources.filter { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        if existing.count != sources.count {
            log.note("source-files-missing", "\(id): \(sources.count - existing.count) of \(sources.count) listed files absent")
        }
        let frames = existing.filter { renderedExts.contains(ext($0)) || rawExts.contains(ext($0)) }

        var candidates: [(String, RepresentativeSource, Double?)] = []
        for b in blends {
            guard let file = b["outputFileName"] as? String else { continue }
            let path = dir.appendingPathComponent(file).path
            guard fm.fileExists(atPath: path) else { log.note("blend-file-missing", "\(id): \(file)"); continue }
            let k = b["kind"] as? String ?? ""
            if k == "image" || renderedExts.contains(ext(file)) { candidates.append((path, .blendImage, nil)) }
        }
        for b in blends {
            guard let file = b["outputFileName"] as? String else { continue }
            let path = dir.appendingPathComponent(file).path
            guard fm.fileExists(atPath: path) else { continue }
            if (b["kind"] as? String ?? "") == "video" || videoExts.contains(ext(file)) { candidates.append((path, .blendVideo, 0.5)) }
        }
        let rendered = frames.filter { renderedExts.contains(ext($0)) }.sorted()
        if !rendered.isEmpty { candidates.append((dir.appendingPathComponent(rendered[rendered.count / 2]).path, .renderedFrame, nil)) }
        let raws = frames.filter { rawExts.contains(ext($0)) }.sorted()
        if !raws.isEmpty { candidates.append((dir.appendingPathComponent(raws[raws.count / 2]).path, .rawDecode, nil)) }

        // Also look at the blends folder directly (unlisted renders).
        let blendsDir = dir.appendingPathComponent("blends")
        if candidates.isEmpty, let files = try? fm.contentsOfDirectory(atPath: blendsDir.path) {
            for f in files.sorted() where renderedExts.contains(ext(f)) { candidates.append((blendsDir.appendingPathComponent(f).path, .blendImage, nil)) }
            for f in files.sorted() where videoExts.contains(ext(f)) { candidates.append((blendsDir.appendingPathComponent(f).path, .blendVideo, 0.5)) }
            if !candidates.isEmpty { log.note("unlisted-render", "\(id): using \(candidates[0].0.split(separator: "/").last ?? "")") }
        }

        for (path, source, frac) in candidates {
            guard let dims = await ImageLoader.probeDimensions(path: path, source: source) else {
                log.note("probe-failed", "\(id): \(path)"); continue
            }
            if source == .rawDecode { log.note("raw-decode", "\(id): no rendered output, will decode \((path as NSString).lastPathComponent)") }
            return Asset(id: id, family: family, mode: mode, name: name, projectDir: dir.path,
                         representativePath: path, representativeSource: source,
                         nativeWidth: dims.0, nativeHeight: dims.1, capturedAt: createdAt,
                         listedInManifest: listed, sourceFrameCount: frames.count, frameFraction: frac)
        }
        log.note("no-representative", "\(id) (\(mode)): \(sources.count) sources, \(blends.count) blends")
        return nil
    }
}
