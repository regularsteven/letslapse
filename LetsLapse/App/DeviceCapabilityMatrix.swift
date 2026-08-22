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
/// probe groups by (which also pins the device's `uniqueID`, its field of view
/// and its aspect ratio): those are facts about a *format*, and the picker only
/// knows the configuration. Where several fingerprints collapse onto one key
/// the probe intersects their answers, so an option this key offers is safe
/// under every format the key could be describing.
///
/// Note the asymmetry with `BurstOption`: this key's dimensions are the *base*
/// segment's, and the options it maps to carry their own. One recording run
/// can now hold two resolutions.
///
/// `stabilizationSupported` / `appleLogSupported` read as *requirements* here,
/// matching the `stabilizationEnabled` / `appleLogEnabled` arguments of the
/// lookup: `false` means the run doesn't ask for it, and formats that happen
/// to offer it are then interchangeable with formats that don't.
struct CaptureCapabilityKey: Hashable, Codable {
    /// Which camera this configuration describes — `DeviceCapabilityMatrix
    /// .deviceKey(for:)`, which is the device *type* on iOS and the device's
    /// `uniqueID` on macOS. See that function for why the two platforms differ.
    let deviceKey: String
    let pixelWidth: Int32
    let pixelHeight: Int32
    /// ProRes and HEVC formats share pixel dimensions but not a codec, and a
    /// segment boundary that changed codec would not stitch.
    let isProRes: Bool
    let stabilizationSupported: Bool
    let appleLogSupported: Bool
    let baseFPS: Int
}

/// The opt-in gate for per-segment burst resolution.
///
/// Off by default, and deliberately: with it off the burst picker serves every
/// rate at the base resolution, so a shoot records one resolution and every
/// path downstream — the capture switch, the sidecar, the stitch, the reframe —
/// behaves exactly as it did before the feature existed. That makes the setting
/// a real kill switch for a day in the field rather than a cosmetic preference.
///
/// It gates the RESOLUTION, never the RATE (2026-08-22). Where a rate is
/// reachable only at a larger resolution, the option survives the switch being
/// off and that burst does change resolution: a frame-rate ceiling is not what
/// this setting is for, and the composition is identical either way — which is
/// exactly what the fingerprint below guarantees.
///
/// It gates **capture only**. A recording that already holds two resolutions
/// still renders through the per-segment path whatever this says, because that
/// is the only way to render it correctly — turning the setting off cannot
/// retroactively make a mixed shoot single-resolution.
enum BurstResolutionSetting {
    static let defaultsKey = "letslapse.burstResolutionEnabled"

    /// Read straight from `UserDefaults` rather than through `AppModel`, so the
    /// camera's session queue can ask without hopping to the main actor.
    /// Absent reads as false, which is the pre-feature behaviour.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }
}

/// One format a burst segment can land on: a frame rate *and* the resolution
/// it is reached at.
///
/// Resolution is here because the two segment types of a ramp shoot want
/// opposite things. Base segments are compressed 100× and no viewer studies a
/// frame of them; burst segments are slowed down and are the ones a punch-in
/// crops into, where every pixel is spent on the crop. Letting the burst shoot
/// 4K off a 1080p base buys 2× of punch that costs no upscale at 1080p
/// delivery — which is the whole reason this type carries dimensions.
struct BurstOption: Hashable, Codable {
    let pixelWidth: Int32
    let pixelHeight: Int32
    let fps: Int

    /// Sort order for the picker: by rate first (the fact the user is choosing
    /// between), then by pixels, so "120 fps" and "120 fps · 4K" sit together.
    static func pickerOrder(_ a: BurstOption, _ b: BurstOption) -> Bool {
        if a.fps != b.fps { return a.fps < b.fps }
        return a.pixelCount < b.pixelCount
    }

    var pixelCount: Int64 { Int64(pixelWidth) * Int64(pixelHeight) }
}

/// Answers "given this recording configuration, which burst formats are
/// composition-safe?" — probed once per (device model, OS version) from
/// format metadata alone and cached in `UserDefaults`.
///
/// A burst is a format change between segments of one run, on one sensor. It
/// is safe only when the format it lands on frames the scene identically:
/// same lens, same field of view, same aspect ratio, same codec, and the same
/// answer on stabilization and Apple Log. Anything else is a visible reframe
/// or a colour shift partway through a finished clip.
///
/// **Pixel dimensions are deliberately NOT on that list** (they were until
/// 2026-08-15). Field of view is what decides whether two formats frame the
/// scene identically, and `videoFieldOfView` is a horizontal angle — so FOV
/// plus aspect ratio is the honest test, and two formats can pass it at
/// different pixel counts. That is exactly the case this feature wants: a
/// 1080p base and a 4K burst off the same optic, framed identically. A format
/// that reaches the higher rate only through a sensor crop has a different
/// FOV, fails the test, and is never offered.
///
/// Serialisation note: `validBurstOptions` is keyed by a struct, so `Codable`
/// writes it as a flat array of alternating key/value entries rather than a
/// JSON object. That round-trips exactly; it just isn't pretty to read.
struct DeviceCapabilityMatrix: Codable {
    /// e.g. "iPhone17,1" — `hw.machine`, or "mac" as a sentinel.
    let deviceModel: String
    let systemVersion: String
    let generatedAt: Date
    let validBurstOptions: [CaptureCapabilityKey: [BurstOption]]
    /// The cameras this matrix was probed from. On iOS the model name already
    /// implies them; on a Mac the camera set changes whenever something is
    /// plugged in, and a matrix that has never seen the current camera has
    /// nothing true to say about it. See `loadOrProbe`.
    let probedDeviceKeys: [String]

    /// How a camera is identified in `CaptureCapabilityKey`.
    ///
    /// iOS keys by device type: a phone has exactly one camera of each type,
    /// so the type names it, and keying that way lets a cached matrix survive
    /// the `AVCaptureDevice` objects being rebuilt.
    ///
    /// macOS keys by `uniqueID`, because the type does NOT name a Mac camera:
    /// probed on Steven's Mac 2026-08-14, a DJI Osmo Action 4, OBS Virtual
    /// Camera and an iPhone over Continuity ALL report
    /// `AVCaptureDeviceTypeExternal`. Keying those by type collapsed three
    /// unrelated cameras onto one key, where the probe below intersects their
    /// answers — so the resolution and frame-rate menus showed only what all
    /// three happened to share, and plugging in a webcam silently changed what
    /// the other cameras appeared to support.
    static func deviceKey(for device: AVCaptureDevice) -> String {
        #if os(macOS)
        return device.uniqueID
        #else
        return device.deviceType.rawValue
        #endif
    }

    // MARK: - Lookup

    /// Composition-safe burst formats for the current configuration, or nil if
    /// the matrix has nothing to say about it (which, after `configure()`,
    /// means the hardware genuinely offers no faster format here).
    func validBurstOptions(
        for device: AVCaptureDevice,
        resolution: CameraController.CaptureResolution,
        stabilizationEnabled: Bool,
        appleLogEnabled: Bool,
        baseFPS: Int
    ) -> [BurstOption]? {
        validBurstOptions[CaptureCapabilityKey(
            deviceKey: Self.deviceKey(for: device),
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
    /// base is `validBurstOptions(...)`, which is a strictly smaller answer.
    func supportedFrameRatesByResolution(
        forDeviceKey deviceKey: String,
        stabilizationEnabled: Bool,
        appleLogEnabled: Bool
    ) -> [CameraController.CaptureResolution: Set<Int>] {
        var byResolution: [CameraController.CaptureResolution: Set<Int>] = [:]
        for key in validBurstOptions.keys
        where key.deviceKey == deviceKey
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

    /// Bumped to `.v2` on 2026-08-15 when the value type changed from `[Int]`
    /// to `[BurstOption]`. A cached v1 payload cannot decode into the new
    /// shape, and `LL_RESET_CAPS` is DEBUG-only — so a shipped build has no
    /// other way to shed it. A new key is the migration.
    private static let defaultsKey = "letslapse.deviceCapabilityMatrix.v2"
    private static let legacyDefaultsKeys = ["letslapse.deviceCapabilityMatrix"]

    /// The cached matrix when it was built by this device on this OS version,
    /// otherwise a fresh probe (stored on the way out). Synchronous and
    /// format-only; call it on the session queue, since it reads AVFoundation
    /// objects.
    static func loadOrProbe(devices: [AVCaptureDevice]) -> DeviceCapabilityMatrix {
        let model = currentDeviceModel
        let version = currentSystemVersion
        let wanted = devices.map(deviceKey(for:))
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let cached = try? JSONDecoder().decode(Self.self, from: data),
           cached.deviceModel == model,
           cached.systemVersion == version,
           // On a Mac "same model" is not "same cameras": every Mac caches
           // under the sentinel "mac", so without this a matrix probed from
           // the built-in webcam would be served for a newly-plugged action
           // cam that it has never seen a single format of. iOS passes this
           // trivially — the phone's own cameras are always the probed ones.
           wanted.allSatisfy(cached.probedDeviceKeys.contains) {
            return cached
        }
        let matrix = probe(devices: devices)
        if let data = try? JSONEncoder().encode(matrix) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        // A v1 payload is dead weight the moment a v2 one is written, and it
        // is not small. Shed it on the way past rather than leaving it in
        // every upgrader's defaults forever.
        for key in legacyDefaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
        return matrix
    }

    /// Drops the cache so the next `loadOrProbe` re-probes. Only useful when
    /// the format list itself can change under us (a debug hook, a repair).
    static func invalidateCache() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        for key in legacyDefaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - Probe

    /// One format, reduced to the facts that decide whether it can stand in
    /// for another. Reading `device.formats` never opens a session, so the
    /// probe cannot cause a sensor swap.
    private struct FormatFacts {
        let uniqueID: String
        let deviceKey: String
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

    /// Groups formats that frame the scene identically. Carries `uniqueID`,
    /// field of view and aspect ratio, which `CaptureCapabilityKey` does not.
    ///
    /// Deliberately **without** pixel dimensions: two formats of the same
    /// optic, field of view and aspect frame the same scene whatever their
    /// pixel count, and a group spanning several resolutions is precisely what
    /// lets a 1080p base offer a 4K burst. `aspect` is load-bearing, not
    /// decoration — `videoFieldOfView` is a horizontal angle, so without it a
    /// 16:9 and a 4:3 format of equal width would group together and the burst
    /// would change what the top and bottom of the frame show.
    private struct Fingerprint: Hashable {
        let uniqueID: String
        let deviceKey: String
        let isProRes: Bool
        let fieldOfViewTenths: Int
        let aspect: String
    }

    /// A resolution inside a fingerprint group.
    private struct Dimensions: Hashable {
        let width: Int32
        let height: Int32
        var pixelCount: Int64 { Int64(width) * Int64(height) }
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
                    deviceKey: deviceKey(for: device),
                    width: dims.width,
                    height: dims.height,
                    isProRes: CameraController.proResFourCCs.contains(subType),
                    fieldOfViewTenths: fovTenths,
                    stabilizationSupported: stabilized,
                    appleLogSupported: appleLog,
                    rates: rates))
            }
        }

        var matrix: [CaptureCapabilityKey: [BurstOption]] = [:]
        // Four passes, one per configuration the pickers can be in. A pass
        // that doesn't demand stabilization (or Apple Log) merges formats that
        // differ only in offering it: nothing turns it on, so they frame the
        // scene the same way and are interchangeable.
        for stabRequired in [false, true] {
            for logRequired in [false, true] {
                // One group per way of framing the scene; inside a group, the
                // rates each resolution reaches. A group spanning 1080p and 4K
                // is the whole point — those two resolutions are then burst
                // options for each other.
                var groups: [Fingerprint: [Dimensions: Set<Int>]] = [:]
                for fact in facts {
                    guard !stabRequired || fact.stabilizationSupported else { continue }
                    guard !logRequired || fact.appleLogSupported else { continue }
                    let fingerprint = Fingerprint(
                        uniqueID: fact.uniqueID,
                        deviceKey: fact.deviceKey,
                        isProRes: fact.isProRes,
                        fieldOfViewTenths: fact.fieldOfViewTenths,
                        aspect: CameraController.CaptureResolution(
                            width: fact.width, height: fact.height).aspectRatioLabel)
                    let dims = Dimensions(width: fact.width, height: fact.height)
                    groups[fingerprint, default: [:]][dims, default: []].formUnion(fact.rates)
                }

                for (fingerprint, byDimensions) in groups {
                    for (dims, rates) in byDimensions {
                        for base in rates {
                            let key = CaptureCapabilityKey(
                                deviceKey: fingerprint.deviceKey,
                                pixelWidth: dims.width,
                                pixelHeight: dims.height,
                                isProRes: fingerprint.isProRes,
                                stabilizationSupported: stabRequired,
                                appleLogSupported: logRequired,
                                baseFPS: base)
                            // Every faster format in the group, at any of the
                            // group's resolutions — minus the ones that would
                            // LOSE pixels. A burst is the segment a punch-in
                            // crops into, so it may gain resolution or keep it,
                            // never drop it: a softer burst inside a sharper
                            // shoot reads as a fault, not as a feature.
                            let bursts = byDimensions.flatMap { candidate, candidateRates -> [BurstOption] in
                                guard candidate.pixelCount >= dims.pixelCount else { return [] }
                                return candidateRates.filter { $0 > base }.map {
                                    BurstOption(
                                        pixelWidth: candidate.width,
                                        pixelHeight: candidate.height,
                                        fps: $0)
                                }
                            }
                            if let existing = matrix[key] {
                                // Two fingerprints collapsed onto one key (a
                                // second field of view at these dimensions, or
                                // two devices of the same type). Keep only what
                                // holds for both — the picker can't tell them
                                // apart.
                                let allowed = Set(bursts)
                                matrix[key] = existing
                                    .filter(allowed.contains)
                                    .sorted(by: BurstOption.pickerOrder)
                            } else {
                                matrix[key] = bursts.sorted(by: BurstOption.pickerOrder)
                            }
                        }
                    }
                }
            }
        }

        return DeviceCapabilityMatrix(
            deviceModel: currentDeviceModel,
            systemVersion: currentSystemVersion,
            generatedAt: Date(),
            validBurstOptions: matrix,
            // Recorded from the devices asked for, not from `facts`: a camera
            // that offers no usable format contributes no facts, and leaving
            // it out here would re-probe on every single configure.
            probedDeviceKeys: devices.map(deviceKey(for:)))
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
