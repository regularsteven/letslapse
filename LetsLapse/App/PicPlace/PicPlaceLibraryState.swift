import Foundation
import LetsLapseKit

/// `PicPlace/settings.json` — the auto-sync switches, **per device AND per
/// library**: the file lives in the library, but each device keeps its own
/// entry in it, so a volume carried to another Mac never arrives with
/// "upload everything" switched on. Steven's rule (2026-09-16): *Upload
/// originals automatically* is OFF unless the person switches it on for
/// this device and this library; sign-in and connect never touch it; the
/// server never stores it (the client owns the storage constraints).
struct PicPlaceLibrarySettings: Codable, Equatable {
    /// One device's switches.
    struct Switches: Codable, Equatable {
        /// On by default once a library is connected (v2 plan §4.7).
        var autoSync = true
        /// Off by default, always: a 431 GB library must not start uploading
        /// the moment it connects.
        var autoOriginals = false
    }

    static let format = 1

    var format = Self.format
    /// Keyed by `DeviceIdentity.id`, lowercased.
    var devices: [String: Switches] = [:]

    static func read(root: URL) -> PicPlaceLibrarySettings? {
        guard let data = try? Data(contentsOf: PicPlaceBindingRecord.settingsURL(inRoot: root)) else { return nil }
        return try? NDJSONFile.makeDecoder().decode(PicPlaceLibrarySettings.self, from: data)
    }

    func write(root: URL) throws {
        let encoder = NDJSONFile.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: PicPlaceBindingRecord.folderURL(inRoot: root), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: PicPlaceBindingRecord.settingsURL(inRoot: root), options: .atomic)
    }

    static func deviceKey(_ device: UUID) -> String { device.uuidString.lowercased() }

    /// This device's switches for the library at `root`: its entry in the
    /// file, else the defaults. The install-wide keys from before this file
    /// are read once and removed — only an explicit *auto-sync off* is
    /// carried (a person who switched pushes off stays that way);
    /// *upload originals* is never carried: it starts OFF here whatever the
    /// install had. The argument domain still wins for a run
    /// (`-letslapse.picplace.autoOriginals YES`, the bench's lever), and a
    /// run's forced value is never written (only a toggle writes).
    static func resolve(root: URL, device: UUID, legacyAutoSyncKey: String, legacyAutoOriginalsKey: String) -> Switches {
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var switches = read(root: root)?.devices[deviceKey(device)] ?? Switches()
        #if os(macOS)
        let mayClaim = !StorageRoot.rootCameFromArguments
        #else
        let mayClaim = true
        #endif
        if mayClaim, defaults.object(forKey: legacyAutoSyncKey) != nil || defaults.object(forKey: legacyAutoOriginalsKey) != nil {
            if read(root: root)?.devices[deviceKey(device)] == nil,
               let value = defaults.object(forKey: legacyAutoSyncKey) as? Bool, value == false, arguments[legacyAutoSyncKey] == nil {
                switches.autoSync = false
                try? save(switches, root: root, device: device)
                LLog("picplace: auto-sync off carried from the install into the library at \(root.path)")
            }
            if arguments[legacyAutoSyncKey] == nil { defaults.removeObject(forKey: legacyAutoSyncKey) }
            if arguments[legacyAutoOriginalsKey] == nil { defaults.removeObject(forKey: legacyAutoOriginalsKey) }
            LLog("picplace: the install-wide auto-sync keys are retired; the switches are per device and per library now")
        }
        // The argument domain sits above every other domain, so `bool(forKey:)`
        // reads the launch argument when there is one.
        if arguments[legacyAutoSyncKey] != nil { switches.autoSync = defaults.bool(forKey: legacyAutoSyncKey) }
        if arguments[legacyAutoOriginalsKey] != nil { switches.autoOriginals = defaults.bool(forKey: legacyAutoOriginalsKey) }
        return switches
    }

    /// Write this device's entry, keeping every other device's.
    static func save(_ switches: Switches, root: URL, device: UUID) throws {
        var file = read(root: root) ?? PicPlaceLibrarySettings()
        file.devices[deviceKey(device)] = switches
        try file.write(root: root)
    }
}
