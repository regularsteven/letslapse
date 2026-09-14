import Foundation
import LetsLapseKit

/// `<root>/PicPlace/sync-state.json` — this library's sync records, keyed by
/// `originID` (v2 plan §3.2). Device-local ("this device pushed this project
/// at this revision, then") but LIBRARY-scoped: two libraries on one Mac
/// each keep their own, where v1's `UserDefaults` map keyed by bare capture
/// UUID would have let a project pushed from one library read as synced in
/// the other. The `revision` of each record is the merge base (§4.4).
///
/// Rebuildable: this device's row in the server's `presence[]` carries the
/// same revision — so a lost file costs a re-read, never a wrong merge.
enum PicPlaceSyncState {

    static let format = 1

    private struct File: Codable {
        var format: Int
        var records: [String: PicPlaceSyncRecord]
    }

    static func load(root: URL) -> [UUID: PicPlaceSyncRecord] {
        let url = PicPlaceBindingRecord.syncStateURL(inRoot: root)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        do {
            let file = try NDJSONFile.makeDecoder().decode(File.self, from: data)
            return Dictionary(uniqueKeysWithValues: file.records.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        } catch {
            LLog("picplace: could not read \(url.lastPathComponent): \(error)")
            return [:]
        }
    }

    static func save(_ records: [UUID: PicPlaceSyncRecord], root: URL) {
        let url = PicPlaceBindingRecord.syncStateURL(inRoot: root)
        do {
            let keyed = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString.lowercased(), $0.value) })
            let encoder = NDJSONFile.makeEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(File(format: format, records: keyed)).write(to: url, options: .atomic)
        } catch {
            LLog("picplace: could not write \(url.lastPathComponent): \(error)")
        }
    }
}
