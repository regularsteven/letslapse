import AVFoundation
import Foundation

/// Formats that said they could feed an output and then left its connection
/// inactive — learned from the camera itself, on this phone, under this OS.
///
/// `unsupportedCaptureOutputClasses` is a format's own word on which outputs
/// it cannot feed, and the menus read it first. The word can be incomplete:
/// every physical lens of the iPhone 18 Pro offers 4224×3024, lists only the
/// broadcast and depth outputs as unsupported, and still leaves the photo
/// output's connection inactive while it is active (2026-09-27: every still
/// refused at 0.5×, 1× and 4×, while 4032×3024 on the same lens and the same
/// pin shot). That one turned out to be ProRes RAW — sensor data, which
/// `CameraController.isSensorDataFormat` now keeps out by the pixel type's
/// own description — and this ledger learned it before the cause had a name.
/// It stays as the net for the next format nothing declares: on iOS 27 a
/// photo request or a movie start on a dark connection is an uncatchable
/// abort, so the connection is asked directly before a run's first frame,
/// and a refusal it proves is written here.
///
/// "Proves": a format is only recorded when another format on the same lens
/// brought the connection up in its place, so a session that is simply not
/// ready never teaches the menus to hide a good size. Keyed by model and OS
/// build, so an update tries every format again; nothing is known in
/// advance about any camera.
enum FormatOutputLedger {
    private static let defaultsKey = "letslapse.formatOutputRefusals.v1"
    private static let lock = NSLock()
    private static var cache: [String: String]?

    static func refuses(
        _ format: AVCaptureDevice.Format, on device: AVCaptureDevice, output: AVCaptureOutput.Type
    ) -> Bool {
        let key = key(format, on: device, output: output)
        lock.lock()
        defer { lock.unlock() }
        return loadedLocked()[key] != nil
    }

    static func record(
        _ format: AVCaptureDevice.Format, on device: AVCaptureDevice, output: AVCaptureOutput.Type
    ) {
        let key = key(format, on: device, output: output)
        lock.lock()
        defer { lock.unlock() }
        var entries = loadedLocked()
        guard entries[key] == nil else { return }
        entries[key] = ISO8601DateFormatter().string(from: Date())
        cache = entries
        UserDefaults.standard.set(entries, forKey: defaultsKey)
    }

    /// Everything learned under this model and OS build, for the self-test.
    static func entries() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return loadedLocked()
    }

    private static func loadedLocked() -> [String: String] {
        if let cache { return cache }
        let prefix = scope + "|"
        let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        // Entries from another model or OS build are dropped on the first
        // read: an update is exactly when a format deserves another try.
        let current = stored.filter { $0.key.hasPrefix(prefix) }
        if current.count != stored.count { UserDefaults.standard.set(current, forKey: defaultsKey) }
        cache = current
        return current
    }

    private static let scope: String = {
        let build = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(LiveBlendController.deviceModelIdentifier())|\(build)"
    }()

    /// One format, by what tells it apart from its siblings on a lens.
    private static func key(
        _ format: AVCaptureDevice.Format, on device: AVCaptureDevice, output: AVCaptureOutput.Type
    ) -> String {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((subType >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "\(subType)"
        let maxFPS = Int((format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0).rounded())
        return [scope, device.deviceType.rawValue, "\(dims.width)x\(dims.height)", fourCC, "\(maxFPS)",
                NSStringFromClass(output)].joined(separator: "|")
    }
}
