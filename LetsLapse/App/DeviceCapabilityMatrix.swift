//
//  DeviceCapabilityMatrix.swift
//  LetsLapse
//
//  Which burst frame rates a recording configuration can reach without
//  changing what the shot looks like.
//

import AVFoundation
import Foundation

/// One recording configuration, as the burst picker sees it.
///
/// The lookup is deliberately coarser than the composition fingerprint the
/// probe groups by (which also pins the device's `uniqueID` and its field of
/// view): those are facts about a *format*, and the picker only knows the
/// configuration. Where several fingerprints collapse onto one key the probe
/// intersects their answers, so a rate this key offers is safe under every
/// format the key could be describing.
///
/// `stabilizationSupported` / `appleLogSupported` read as *requirements* here,
/// matching the `stabilizationEnabled` / `appleLogEnabled` arguments of the
/// lookup: `false` means the run doesn't ask for it, and formats that happen
/// to offer it are then interchangeable with formats that don't.
struct CaptureCapabilityKey: Hashable, Codable {
    /// `AVCaptureDevice.DeviceType.rawValue` — the type is a struct wrapping
    /// a String, and only the String survives a round trip through JSON.
    let deviceType: String
    let pixelWidth: Int32
    let pixelHeight: Int32
    /// ProRes and HEVC formats share pixel dimensions but not a codec, and a
    /// segment boundary that changed codec would not stitch.
    let isProRes: Bool
    let stabilizationSupported: Bool
    let appleLogSupported: Bool
    let baseFPS: Int
}

/// Answers "given this recording configuration, which burst frame rates are
/// composition-safe?" — probed once per (device model, OS version) from
/// format metadata alone and cached in `UserDefaults`.
///
/// A burst is a format change between segments of one run, on one sensor. It
/// is safe only when the format it lands on frames the scene identically:
/// same lens, same pixel dimensions, same field of view, same codec, and the
/// same answer on stabilization and Apple Log. Anything else is a visible
/// reframe or a colour shift partway through a finished clip.
///
/// Serialisation note: `validBurstRates` is keyed by a struct, so `Codable`
/// writes it as a flat array of alternating key/value entries rather than a
/// JSON object. That round-trips exactly; it just isn't pretty to read.
struct DeviceCapabilityMatrix: Codable {
    /// e.g. "iPhone17,1" — `hw.machine`, or "mac" as a sentinel.
    let deviceModel: String
    let systemVersion: String
    let generatedAt: Date
    let validBurstRates: [CaptureCapabilityKey: [Int]]

    // MARK: - Lookup

    /// Composition-safe burst rates for the current configuration, or nil if
    /// the matrix has nothing to say about it (which, after `configure()`,
    /// means the hardware genuinely offers no faster format here).
    func validBurstRates(
        for device: AVCaptureDevice,
        resolution: CameraController.CaptureResolution,
        stabilizationEnabled: Bool,
        appleLogEnabled: Bool,
        baseFPS: Int
    ) -> [Int]? {
        validBurstRates[CaptureCapabilityKey(
            deviceType: device.deviceType.rawValue,
            pixelWidth: resolution.width,
            pixelHeight: resolution.height,
            isProRes: resolution.isProRes,
            stabilizationSupported: stabilizationEnabled,
            appleLogSupported: appleLogEnabled,
            baseFPS: baseFPS)]
    }

    /// The resolution → frame-rate map the pickers list, rebuilt from the
    /// matrix instead of a live format scan. Every rate in a bucket is one the
    /// device can shoot at that resolution under the given configuration — the
    /// *base* rate menu. Which of those are reachable as a burst from a chosen
    /// base is `validBurstRates(...)`, which is a strictly smaller answer.
    func supportedFrameRatesByResolution(
        forDeviceType deviceType: String,
        stabilizationEnabled: Bool,
        appleLogEnabled: Bool
    ) -> [CameraController.CaptureResolution: Set<Int>] {
        var byResolution: [CameraController.CaptureResolution: Set<Int>] = [:]
        for key in validBurstRates.keys
        where key.deviceType == deviceType
            && key.stabilizationSupported == stabilizationEnabled
            && key.appleLogSupported == appleLogEnabled {
            let resolution = CameraController.CaptureResolution(
                width: key.pixelWidth,
                height: key.pixelHeight,
                isProRes: key.isProRes)
            byResolution[resolution, default: []].insert(key.baseFPS)
        }
        return byResolution
    }

    // MARK: - Cache

    private static let defaultsKey = "letslapse.deviceCapabilityMatrix"

    /// The cached matrix when it was built by this device on this OS version,
    /// otherwise a fresh probe (stored on the way out). Synchronous and
    /// format-only; call it on the session queue, since it reads AVFoundation
    /// objects.
    static func loadOrProbe(devices: [AVCaptureDevice]) -> DeviceCapabilityMatrix {
        let model = currentDeviceModel
        let version = currentSystemVersion
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let cached = try? JSONDecoder().decode(Self.self, from: data),
           cached.deviceModel == model,
           cached.systemVersion == version {
            return cached
        }
        let matrix = probe(devices: devices)
        if let data = try? JSONEncoder().encode(matrix) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        return matrix
    }

    /// Drops the cache so the next `loadOrProbe` re-probes. Only useful when
    /// the format list itself can change under us (a debug hook, a repair).
    static func invalidateCache() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    // MARK: - Probe

    /// One format, reduced to the facts that decide whether it can stand in
    /// for another. Reading `device.formats` never opens a session, so the
    /// probe cannot cause a sensor swap.
    private struct FormatFacts {
        let uniqueID: String
        let deviceType: String
        let width: Int32
        let height: Int32
        let isProRes: Bool
        /// Field of view in tenths of a degree — the rounding guard that keeps
        /// two readings of the same optic from looking like two compositions.
        let fieldOfViewTenths: Int
        let stabilizationSupported: Bool
        let appleLogSupported: Bool
        let rates: Set<Int>
    }

    /// Groups formats that frame the scene identically. Carries `uniqueID` and
    /// field of view, which `CaptureCapabilityKey` does not.
    private struct Fingerprint: Hashable {
        let uniqueID: String
        let deviceType: String
        let width: Int32
        let height: Int32
        let isProRes: Bool
        let fieldOfViewTenths: Int
    }

    static func probe(devices: [AVCaptureDevice]) -> DeviceCapabilityMatrix {
        var candidates = CameraController.preferredFrameRates
        if let custom = RecordingSettingsStore.customFrameRate, !candidates.contains(custom) {
            candidates.append(custom)
        }

        var facts: [FormatFacts] = []
        var seenDevices = Set<String>()
        for device in devices where seenDevices.insert(device.uniqueID).inserted {
            for format in device.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dims.width >= 640, dims.height >= 480 else { continue }
                let rates = CameraController.supportedFrameRates(
                    for: format, candidates: candidates)
                guard !rates.isEmpty else { continue }
                let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)

                #if os(iOS)
                // Mirrors `stabilizationMode(for:)` — cinematic or standard.
                let stabilized = format.isVideoStabilizationModeSupported(.cinematic)
                    || format.isVideoStabilizationModeSupported(.standard)
                var appleLog = false
                if #available(iOS 17.2, *) {
                    appleLog = format.supportedColorSpaces.contains(.appleLog)
                }
                // `videoFieldOfView` is iOS-only; the Mac's single webcam has
                // nothing to group against anyway.
                let fovTenths = Int((format.videoFieldOfView * 10).rounded())
                #else
                let stabilized = false
                let appleLog = false
                let fovTenths = 0
                #endif

                facts.append(FormatFacts(
                    uniqueID: device.uniqueID,
                    deviceType: device.deviceType.rawValue,
                    width: dims.width,
                    height: dims.height,
                    isProRes: CameraController.proResFourCCs.contains(subType),
                    fieldOfViewTenths: fovTenths,
                    stabilizationSupported: stabilized,
                    appleLogSupported: appleLog,
                    rates: rates))
            }
        }

        var matrix: [CaptureCapabilityKey: [Int]] = [:]
        // Four passes, one per configuration the pickers can be in. A pass
        // that doesn't demand stabilization (or Apple Log) merges formats that
        // differ only in offering it: nothing turns it on, so they frame the
        // scene the same way and are interchangeable.
        for stabRequired in [false, true] {
            for logRequired in [false, true] {
                var groups: [Fingerprint: Set<Int>] = [:]
                for fact in facts {
                    guard !stabRequired || fact.stabilizationSupported else { continue }
                    guard !logRequired || fact.appleLogSupported else { continue }
                    let fingerprint = Fingerprint(
                        uniqueID: fact.uniqueID,
                        deviceType: fact.deviceType,
                        width: fact.width,
                        height: fact.height,
                        isProRes: fact.isProRes,
                        fieldOfViewTenths: fact.fieldOfViewTenths)
                    groups[fingerprint, default: []].formUnion(fact.rates)
                }

                for (fingerprint, rates) in groups {
                    for base in rates {
                        let key = CaptureCapabilityKey(
                            deviceType: fingerprint.deviceType,
                            pixelWidth: fingerprint.width,
                            pixelHeight: fingerprint.height,
                            isProRes: fingerprint.isProRes,
                            stabilizationSupported: stabRequired,
                            appleLogSupported: logRequired,
                            baseFPS: base)
                        let bursts = rates.filter { $0 > base }
                        if let existing = matrix[key] {
                            // Two fingerprints collapsed onto one key (a second
                            // field of view at these dimensions, or two devices
                            // of the same type). Keep only what holds for both
                            // — the picker can't tell them apart.
                            matrix[key] = existing.filter(bursts.contains).sorted()
                        } else {
                            matrix[key] = bursts.sorted()
                        }
                    }
                }
            }
        }

        return DeviceCapabilityMatrix(
            deviceModel: currentDeviceModel,
            systemVersion: currentSystemVersion,
            generatedAt: Date(),
            validBurstRates: matrix)
    }

    // MARK: - Device identity

    private static var currentDeviceModel: String {
        #if os(iOS)
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
        #else
        return "mac"
        #endif
    }

    /// `UIDevice.current.systemVersion` in every respect but the thread it can
    /// be read on: `UIDevice` is main-thread-only and the probe runs on the
    /// session queue, where touching UIKit crashes (see
    /// `CameraController.latestCaptureOrientation`). `ProcessInfo` is
    /// thread-safe and reports the same version.
    private static var currentSystemVersion: String {
        #if os(iOS)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}
