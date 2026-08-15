//
//  HolyGrailFormatProbe.swift
//  LetsLapse
//
//  LL_PROBE_FORMATS=1 — dump the exposure/ISO envelope of every Bayer RAW
//  format the back cameras expose, which is what bounds a holy-grail ramp.
//

// iOS/iPadOS only: nearly everything the probe reads — the ultra-wide and
// telephoto device types, a format's exposure/ISO envelope, `exposureDuration`
// / `iso` / `exposureTargetBias`, `isAppleProRAWSupported` — is unavailable on
// macOS, and there is nothing on a Mac camera for it to answer about anyway.
#if DEBUG
#if os(iOS)
import AVFoundation
import os.log

enum HolyGrailFormatProbe {
    /// The Bayer subtypes CoreVideo actually declares on this SDK. Note there
    /// are no `kCVPixelFormatType_12Bayer_*` constants — the packed 12-bit
    /// sensor format is the VersatileBayer one, so that is what stands in.
    private static let bayerTypes: [OSType] = [
        kCVPixelFormatType_14Bayer_RGGB,
        kCVPixelFormatType_14Bayer_GRBG,
        kCVPixelFormatType_14Bayer_BGGR,
        kCVPixelFormatType_14Bayer_GBRG,
        kCVPixelFormatType_16VersatileBayer,
        kCVPixelFormatType_96VersatileBayerPacked12,
    ]

    private static let logger = Logger(
        subsystem: "com.regularsteven.letslapse", category: "FormatProbe")

    /// os_log *and* stdout, so the line survives whichever channel is being
    /// watched (`devicectl … --console` only carries stdout).
    private static func emit(_ line: String) {
        logger.info("\(line, privacy: .public)")
        print(line)
    }

    static func run() {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
        ]

        for deviceType in deviceTypes {
            guard let device = AVCaptureDevice.default(deviceType, for: .video, position: .back)
            else {
                emit("LL_PROBE \(deviceType.rawValue) — not available")
                continue
            }

            let rawFormats = device.formats.filter {
                bayerTypes.contains(CMFormatDescriptionGetMediaSubType($0.formatDescription))
            }

            emit("LL_PROBE \(deviceType.rawValue) — \(device.formats.count) formats, \(rawFormats.count) Bayer RAW")

            for (i, format) in rawFormats.enumerated() {
                emit("LL_PROBE   raw[\(i)] \(deviceType.rawValue): \(describe(format))")
            }

            // The RAW formats are only part of the answer: a ramp lives inside
            // whichever format is active, and the envelope differs per format.
            // Collapsing to the distinct envelopes keeps this readable.
            var seen: [String: (count: Int, example: String)] = [:]
            for format in device.formats {
                let key = envelope(format)
                if let hit = seen[key] {
                    seen[key] = (hit.count + 1, hit.example)
                } else {
                    seen[key] = (1, describe(format))
                }
            }
            emit("LL_PROBE   \(deviceType.rawValue): \(seen.count) distinct exposure/ISO envelopes")
            for (key, hit) in seen.sorted(by: { $0.key < $1.key }) {
                emit("LL_PROBE     ×\(hit.count) \(key) — e.g. \(hit.example)")
            }
        }

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            emit("LL_PROBE active (wide): \(describe(device.activeFormat))")
            emit("LL_PROBE active (wide): exposureMode=\(device.exposureMode.rawValue) exposureDuration=\(fixed(device.exposureDuration.seconds, 5))s ISO=\(fixed(Double(device.iso), 0)) bias=\(fixed(Double(device.exposureTargetBias), 2)) [\(fixed(Double(device.minExposureTargetBias), 2))…\(fixed(Double(device.maxExposureTargetBias), 2))]")
        }

        // `device.formats` carries no Bayer subtypes on modern iPhones — RAW
        // is only visible once a photo output is connected, and then only for
        // whichever format is active. So walk the candidate formats with a
        // real session and ask the output. Off-main: starting a session and
        // reconfiguring formats both block.
        DispatchQueue.global(qos: .userInitiated).async {
            for deviceType in deviceTypes {
                guard let device = AVCaptureDevice.default(deviceType, for: .video, position: .back)
                else { continue }
                probeRAW(device, deviceType.rawValue)
            }
            emit("LL_PROBE done")
        }
    }

    /// How many `activeFormat` switches one camera may cost. Each is a real
    /// reconfiguration, so this is a runtime bound, not a correctness one —
    /// if it bites, the line below says so rather than quietly stopping.
    private static let formatSwitchBudget = 24

    private static func probeRAW(_ device: AVCaptureDevice, _ label: String) {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
        else {
            session.commitConfiguration()
            emit("LL_PROBE raw \(label): no input")
            return
        }
        session.addInput(input)
        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            emit("LL_PROBE raw \(label): no photo output")
            return
        }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        defer { session.stopRunning() }

        emit("LL_PROBE raw \(label) @photo-preset: \(rawTypes(output)) | \(describe(device.activeFormat))")

        // One representative per (subtype, dimensions, photo dimensions): the
        // rest differ only in frame-rate range, which RAW support ignores.
        var candidates: [AVCaptureDevice.Format] = []
        var seenKeys = Set<String>()
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let photo = format.supportedMaxPhotoDimensions
                .map { "\($0.width)x\($0.height)" }.joined(separator: "/")
            let key = "\(CMFormatDescriptionGetMediaSubType(format.formatDescription))-\(dims.width)x\(dims.height)-\(photo)"
            if seenKeys.insert(key).inserted { candidates.append(format) }
        }
        // Biggest photo dimensions first: RAW rides the full-sensor formats,
        // and a budget spent on 192×144 answers nothing.
        candidates.sort { photoArea($0) > photoArea($1) }
        let budgeted = candidates.prefix(formatSwitchBudget)
        if candidates.count > budgeted.count {
            emit("LL_PROBE raw \(label): checking \(budgeted.count) of \(candidates.count) distinct formats (switch budget)")
        }

        var found = 0
        for format in budgeted {
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                device.unlockForConfiguration()
            } catch {
                emit("LL_PROBE raw \(label): lock failed — \(error.localizedDescription)")
                continue
            }
            let types = output.availableRawPhotoPixelFormatTypes
            guard !types.isEmpty else { continue }
            found += 1
            emit("LL_PROBE raw \(label) [\(found)]: \(types.map(fourCC).joined(separator: ",")) proRAW=\(output.isAppleProRAWSupported) | \(describe(format))")
        }
        // Back to the preset the first line reported, to show whether RAW
        // returns — i.e. whether the switching is what dropped it.
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.commitConfiguration()
        emit("LL_PROBE raw \(label) @photo-preset again: \(rawTypes(output)) | \(describe(device.activeFormat))")
        // Read after the preset is restored: both of these are properties of
        // the session's current mode, not of the device.
        if found == 0 {
            emit("LL_PROBE raw \(label): RAW only under .photo preset — no explicitly-set activeFormat offered it (appleProRAW supported=\(output.isAppleProRAWSupported))")
        } else {
            emit("LL_PROBE raw \(label): \(found) explicitly-set formats offered RAW, appleProRAW supported=\(output.isAppleProRAWSupported)")
        }
    }

    private static func photoArea(_ format: AVCaptureDevice.Format) -> Int {
        format.supportedMaxPhotoDimensions
            .map { Int($0.width) * Int($0.height) }
            .max() ?? 0
    }

    private static func rawTypes(_ output: AVCapturePhotoOutput) -> String {
        let types = output.availableRawPhotoPixelFormatTypes
        return types.isEmpty ? "no RAW" : types.map(fourCC).joined(separator: ",")
    }

    private static func describe(_ format: AVCaptureDevice.Format) -> String {
        let desc = format.formatDescription
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let subType = fourCC(CMFormatDescriptionGetMediaSubType(desc))
        let rates = format.videoSupportedFrameRateRanges
            .map { "\(fixed($0.minFrameRate, 0))–\(fixed($0.maxFrameRate, 0))fps" }
            .joined(separator: ",")
        let photo = format.supportedMaxPhotoDimensions
            .map { "\($0.width)×\($0.height)" }
            .joined(separator: "/")
        return "\(subType) \(dims.width)×\(dims.height) | \(envelope(format)) | \(rates.isEmpty ? "no-rates" : rates) | photo \(photo.isEmpty ? "—" : photo)"
    }

    private static func envelope(_ format: AVCaptureDevice.Format) -> String {
        "exp \(fixed(format.minExposureDuration.seconds, 5))s–\(fixed(format.maxExposureDuration.seconds, 4))s ISO \(fixed(Double(format.minISO), 0))–\(fixed(Double(format.maxISO), 0))"
    }

    private static func fixed(_ value: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", value)
    }

    private static func fourCC(_ type: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((type >> UInt32($0)) & 0xFF) }
        let scalars = bytes.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "?" }
        return String(scalars)
    }
}
#endif
#endif
