import Foundation
import CryptoKit
import LetsLapseKit

/// What a sync sends (v2 plan §3.4, decisions D5–D6).
enum PicPlaceSyncPolicy: String {
    /// The records bundle, the poster and the hash-deduped authored inputs
    /// — everything a device needs to show and describe the project. The
    /// sources and the blends stay where they are.
    case minimal
    /// The originals: the `source/` media and `blends/`, by hash.
    case originals
    /// Both.
    case everything

    var sendsRecords: Bool { self != .originals }
    var sendsHeavy: Bool { self != .minimal }
}

/// One regular file of a project folder, classified for a sync by the one
/// table that knows what every file is (`ProjectFileRegistry`).
struct PicPlaceSyncItem {
    enum Role: Equatable {
        /// `project.json` — the manifest, sent inline with the PUT.
        case manifest
        /// A member of the records bundle.
        case bundle
        /// Its own object on the server, of this kind.
        case object(kind: String)
        /// The heavy set — a source frame or a blend — of this kind.
        case heavy(kind: String)
        /// Not sent, and why.
        case skipped(String)
    }
    var relativePath: String
    var url: URL
    var bytes: Int64
    var role: Role
}

enum PicPlaceSyncInventory {

    static let bundleName = "records.aar"
    static let bundleKind = "records"
    static let bundleContentType = "application/octet-stream"
    static let posterKind = "preview"

    /// Classifies the folder's regular files. Everything under `tmp/` and
    /// the dot files were already left out by the listing.
    static func classify(_ entries: [PicPlaceSyncRun.FolderEntry]) -> [PicPlaceSyncItem] {
        entries.map { entry in
            PicPlaceSyncItem(relativePath: entry.name, url: entry.url, bytes: entry.bytes, role: role(for: entry.name))
        }
    }

    static func role(for relativePath: String) -> PicPlaceSyncItem.Role {
        if relativePath == ProjectFileRegistry.projectDocumentName { return .manifest }
        guard let entry = ProjectFileRegistry.entry(forRelativePath: relativePath) else {
            return .skipped("not a registered project file")
        }
        guard entry.travels else { return .skipped("does not travel") }
        if entry.name == ProjectFileRegistry.posterName { return .object(kind: posterKind) }
        if !entry.isDirectory { return .bundle }            // a root record, or a sidecar under source/
        switch entry.name {
        case "source/": return .heavy(kind: "source")
        case "blends/": return .heavy(kind: "blend")
        case "luts/": return .object(kind: "lut")
        default: return .bundle                             // masks/, fonts/, notes/
        }
    }

    /// What a policy would send and what it would leave — the card's caption
    /// before a sync, and the record's numbers after one. No hashing, no
    /// archiving: the bundle is counted by its members.
    struct Summary: Equatable {
        var objects = 0
        var bytes: Int64 = 0
        var bundleMembers = 0
        var bundleBytes: Int64 = 0
        var heavyFiles = 0
        var heavyBytes: Int64 = 0
        var strays: [String] = []
    }

    static func summary(of items: [PicPlaceSyncItem], policy: PicPlaceSyncPolicy) -> Summary {
        var summary = Summary()
        for item in items {
            switch item.role {
            case .manifest: break
            case .bundle:
                summary.bundleMembers += 1
                summary.bundleBytes += item.bytes
            case .object:
                if policy.sendsRecords { summary.objects += 1; summary.bytes += item.bytes }
            case .heavy:
                summary.heavyFiles += 1
                summary.heavyBytes += item.bytes
                if policy.sendsHeavy { summary.objects += 1; summary.bytes += item.bytes }
            case .skipped:
                summary.strays.append(item.relativePath)
            }
        }
        if policy.sendsRecords, summary.bundleMembers > 0 {
            summary.objects += 1
            summary.bytes += summary.bundleBytes
        }
        return summary
    }

    /// Stages the bundle's members under `tmp/` and archives them with the
    /// Kit's `DirectoryArchive` (Apple Archive, lzfse — what `.lapse` uses),
    /// keeping each member's path within the project. Members are hard
    /// links where the volume allows, copies otherwise; the staging tree is
    /// removed on the way out and the archive is the caller's to delete.
    static func buildBundle(members: [PicPlaceSyncItem], in folder: URL) throws -> URL {
        let fileManager = FileManager.default
        let tmp = folder.appendingPathComponent("tmp", isDirectory: true)
        let stage = tmp.appendingPathComponent("picplace-records", isDirectory: true)
        let archive = tmp.appendingPathComponent(bundleName)
        try? fileManager.removeItem(at: stage)
        try? fileManager.removeItem(at: archive)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stage) }
        for member in members {
            let destination = stage.appendingPathComponent(member.relativePath)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fileManager.linkItem(at: member.url, to: destination)
            } catch {
                try fileManager.copyItem(at: member.url, to: destination)
            }
        }
        try DirectoryArchive.write(contentsOf: stage, to: archive, fields: .contentOnly)
        return archive
    }
}
