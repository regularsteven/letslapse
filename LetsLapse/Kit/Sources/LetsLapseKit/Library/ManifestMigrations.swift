import Foundation

/// The library manifest's migrations, run on the raw JSON **before** the
/// app decodes it (docs/data-model-phase1-spec-2026-09-12.md W4).
///
/// Why on JSON: a migration that runs after `JSONDecoder` can be broken by a
/// strict decoder — a key it wants to repair may be the key that fails the
/// decode. Working on the `JSONSerialization` tree, every step tolerates a
/// missing field, an unknown one, and a manifest from a build that does not
/// exist yet (a version above `current` passes through untouched, byte for
/// byte).
///
/// `gradingSchemaVersion` is the counter, under its historical name: the
/// three earlier steps (the Natural stamp, the preset states, the `addedAt`
/// backfill) are Swift-level and stay in `AppModel.loadLibrary`; step 4 is
/// the first JSON-level one and the pattern for every later one.
public enum ManifestMigrations {

    /// The version this build writes.
    public static let current = 4

    /// The version below which the app's own Swift-level stamps (1–3) still
    /// have work to do. Step 4 changes content whatever the version, but
    /// only stamps `gradingSchemaVersion = 4` once those have run — a v2
    /// manifest that arrived here stamped 4 would skip its `addedAt`
    /// backfill for good. The app carries the counter from 3 to 4 itself.
    static let swiftStepsComplete = 3

    public struct Outcome: Equatable, Sendable {
        public var data: Data
        /// One human line per change made; empty means nothing ran.
        public var log: [String]
        /// The version the bytes now declare.
        public var version: Int
    }

    public enum MigrationError: Error, LocalizedError {
        case notAManifest
        public var errorDescription: String? { "The library manifest is not a JSON object." }
    }

    /// Runs every step whose version is above the manifest's on the raw
    /// JSON object and returns the migrated bytes with a log. Never throws
    /// on a missing field — only on bytes that are not a JSON object at all,
    /// which is the undecodable-manifest case the caller sets aside (W7).
    ///
    /// `projectFolder` maps a capture id to its folder, for the steps that
    /// look beside the manifest (step 4 reads `dng-archive.json`).
    public static func apply(to data: Data, projectFolder: (String) -> URL?) throws -> Outcome {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MigrationError.notAManifest
        }
        let version = root["gradingSchemaVersion"] as? Int ?? 0
        guard version < current else {
            return Outcome(data: data, log: [], version: version)
        }
        var log: [String] = []
        if version < 4 {
            log += step4(&root, projectFolder: projectFolder)
            if version >= swiftStepsComplete {
                root["gradingSchemaVersion"] = 4
                log.append("gradingSchemaVersion \(version) → 4")
            } else {
                log.append("gradingSchemaVersion left at \(version): the app's stamps 1–3 run first, then carry it to 4")
            }
        }
        let migrated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return Outcome(data: migrated, log: log, version: root["gradingSchemaVersion"] as? Int ?? version)
    }

    /// Step 4 (2026-09-13): stable identity and the `.json` repair.
    ///
    /// 1. `originID` absent → `importedFromID ?? id` — the only inputs are
    ///    ids the record already carries, so it can never assign a wrong one,
    ///    and it recovers the true origin of every one-hop import.
    /// 2. `derivedFromOriginID` absent, and `<folder>/dng-archive.json`
    ///    names a `sourceProjectID` that is a capture in this manifest → that
    ///    capture's origin. Otherwise left absent.
    /// 3. Every `sourceFileNames` entry ending in `.json` is removed — the
    ///    experiment logs misregistered as frames before 2026-09-05 (77 on
    ///    the Mac, 10 projects on the iPhone). `sourceMediaCount` was already
    ///    excluding them, so nothing visible changes but the record is right.
    static func step4(_ root: inout [String: Any], projectFolder: (String) -> URL?) -> [String] {
        guard var captures = root["captures"] as? [[String: Any]] else { return [] }
        var log: [String] = []

        // Pass 1: origins, so pass 2 can resolve a parent's.
        var originByID: [String: String] = [:]
        for index in captures.indices {
            guard let id = captures[index]["id"] as? String else { continue }
            if captures[index]["originID"] == nil {
                let origin = (captures[index]["importedFromID"] as? String) ?? id
                captures[index]["originID"] = origin
                log.append("\(id.prefix(8)): originID ← \(origin == id ? "id" : "importedFromID")")
            }
            if let origin = captures[index]["originID"] as? String {
                originByID[id.uppercased()] = origin
            }
        }

        // Pass 2: the clone link, and the .json repair.
        for index in captures.indices {
            guard let id = captures[index]["id"] as? String else { continue }
            if captures[index]["derivedFromOriginID"] == nil,
               let folder = projectFolder(id),
               let ledger = try? Data(contentsOf: folder.appendingPathComponent("dng-archive.json")),
               let object = try? JSONSerialization.jsonObject(with: ledger) as? [String: Any],
               let parent = object["sourceProjectID"] as? String,
               let parentOrigin = originByID[parent.uppercased()] {
                captures[index]["derivedFromOriginID"] = parentOrigin
                log.append("\(id.prefix(8)): derivedFromOriginID ← \(parent.prefix(8))'s origin")
            }
            if let names = captures[index]["sourceFileNames"] as? [String] {
                let kept = names.filter { !$0.hasSuffix(".json") }
                if kept.count != names.count {
                    captures[index]["sourceFileNames"] = kept
                    log.append("\(id.prefix(8)): dropped \(names.count - kept.count) .json name(s) from sourceFileNames")
                }
            }
        }
        root["captures"] = captures
        return log
    }
}
