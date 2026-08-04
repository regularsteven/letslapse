import Foundation
import AVFoundation
import SwiftUI

// The probe reads iPhone/iPad camera topology; macOS has a single webcam and
// no virtual devices or RAW capture — iOS-family only, like CaptureBenchmark.
#if os(iOS)

// The stop model and derivation rule live in CaptureOptics.swift — shared
// with CameraController so the probe exercises the production rule.

// MARK: - Runner

/// Diagnostics dump for the Capture Optics groundwork: enumerates the real
/// camera topology (constituents, switchover factors, native sensor crops),
/// runs the derivation rule against it, then walks the derived stops on a
/// live session reading which physical camera actually backs each one and
/// whether Bayer RAW capture survives on the virtual device — the open
/// question gating the DNG pipeline's move off discrete devices.
final class CaptureOpticsProbeRunner: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var statusLine = ""
    @Published var reportText: String?

    private let probeQueue = DispatchQueue(label: "com.letslapse.optics-probe", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()

    func run() {
        guard !isRunning else { return }
        isRunning = true
        reportText = nil
        statusLine = "Probing camera topology…"
        probeQueue.async {
            let report = self.buildReport()
            DispatchQueue.main.async {
                self.reportText = report
                self.statusLine = ""
                self.isRunning = false
            }
        }
    }

    // MARK: Report (probeQueue)

    private func buildReport() -> String {
        var lines: [String] = []
        lines.append("LetsLapse capture optics probe")
        lines.append("\(LiveBlendController.deviceModelIdentifier()) · \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("build \(LiveBlendController.appVersion())")
        lines.append("")

        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            lines.append("Camera access not granted — open the capture screen once, then re-run.")
            return lines.joined(separator: "\n") + "\n"
        }

        // 1. Inventory — every camera the OS admits to, both positions.
        lines.append("DEVICES")
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
                .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
                .builtInTrueDepthCamera,
            ],
            mediaType: .video,
            position: .unspecified)
        for device in discovery.devices {
            var line = "\(positionName(device.position))  \(shortType(device.deviceType))  \(device.localizedName)"
            if device.isVirtualDevice {
                let constituents = device.constituentDevices.map { shortType($0.deviceType) }
                let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors
                    .map { String(format: "%g", $0.doubleValue) }
                line += "\n    constituents [\(constituents.joined(separator: ", "))]"
                line += "  switchover [\(switchOvers.joined(separator: ", "))]"
            }
            lines.append(line)
        }
        lines.append("")

        // 2. The capture device the Optics model would select.
        let preferred: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
        ]
        guard let device = preferred.lazy
            .compactMap({ AVCaptureDevice.default($0, for: .video, position: .back) })
            .first else {
            lines.append("No back camera — nothing to derive.")
            return lines.joined(separator: "\n") + "\n"
        }

        let constituents = device.isVirtualDevice
            ? device.constituentDevices
                .sorted { fieldOfView($0) > fieldOfView($1) }
                .map { shortType($0.deviceType) }
            : [shortType(device.deviceType)]
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)

        lines.append("SELECTED  \(shortType(device.deviceType)) · \(device.localizedName)")
        lines.append("constituents (widest first): \(constituents.joined(separator: " → "))")
        lines.append("switchover factors (raw): \(switchOvers.map { String(format: "%g", $0) }.joined(separator: ", "))")
        for constituent in device.isVirtualDevice ? device.constituentDevices : [device] {
            // minimumFocusDistance (mm) matters to the tele question: inside
            // it, auto switching keeps the wide and serves the stop as a
            // digital crop — native does the same.
            lines.append(String(
                format: "  %@  fov %.1f°  maxPhoto %@  minFocus %dmm",
                shortType(constituent.deviceType),
                fieldOfView(constituent),
                maxPhotoSummary(constituent),
                constituent.minimumFocusDistance))
        }

        // Native sensor crops, per distinct factor set across formats.
        var cropFactors = Set<Double>()
        var cropDetail: [String: Int] = [:]
        for format in device.formats {
            let factors = format.secondaryNativeResolutionZoomFactors.map(Double.init)
            guard !factors.isEmpty else { continue }
            factors.forEach { cropFactors.insert($0) }
            let key = factors.map { String(format: "%g", $0) }.joined(separator: ",")
            cropDetail[key, default: 0] += 1
        }
        if cropDetail.isEmpty {
            lines.append("secondaryNativeResolutionZoomFactors: none (no native sensor crop on this device)")
        } else {
            for (key, count) in cropDetail.sorted(by: { $0.key < $1.key }) {
                lines.append("secondaryNativeResolutionZoomFactors [\(key)] on \(count) formats")
            }
        }
        lines.append("")

        // 3. The derivation rule against this hardware.
        let derived = CaptureOpticsDerivation.derive(.init(
            constituents: constituents,
            switchOverFactors: switchOvers,
            sensorCropFactors: cropFactors.sorted(),
            maxZoomFactor: Double(device.activeFormat.videoMaxZoomFactor)))
        lines.append("DERIVED CAPTURE OPTICS (the chips this device would get)")
        for stop in derived {
            lines.append(String(
                format: "  %4.3gx  raw %-5.3g %-11@ expect %@",
                stop.displayFactor, stop.rawFactor, stop.kind.rawValue as NSString, stop.expectedBacking))
        }
        lines.append("")

        // 4 + 5. Live walks: which camera really backs each stop, under three
        // configurations — isolating why the telephoto may not engage:
        //   A  photo preset, system-default switching (the DNG-armed shape)
        //   B  high preset + pinned 30 fps format + movie output attached —
        //      an exact mirror of the app's standard world (Photo/Interval
        //      JPEG and Video all idle in this shape)
        //   C  photo preset with switching forced to unrestricted auto —
        //      tests whether the default switching policy is the blocker
        publish("Walking derived stops (3 passes)…")
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
                session.commitConfiguration()
                lines.append("  session refused input/output — walk skipped")
                return lines.joined(separator: "\n") + "\n"
            }
            session.addInput(input)
            session.addOutput(photoOutput)
            session.commitConfiguration()
            session.startRunning()
            defer {
                session.stopRunning()
                session.beginConfiguration()
                session.removeInput(input)
                session.removeOutput(photoOutput)
                session.commitConfiguration()
            }

            walkStops(&lines, device: device, derived: derived,
                      header: "PASS A — photo preset · default switching")

            // Pass B: the app's standard world. Format pin resets the zoom;
            // the walk re-applies it per stop.
            let movieOutput = AVCaptureMovieFileOutput()
            session.beginConfiguration()
            session.sessionPreset = .high
            if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
            session.commitConfiguration()
            pinStandardVideoFormat(device, into: &lines)
            walkStops(&lines, device: device, derived: derived,
                      header: "PASS B — high preset · pinned 30fps format · movie output (app standard world)")
            session.beginConfiguration()
            session.removeOutput(movieOutput)
            session.sessionPreset = .photo
            session.commitConfiguration()

            // Pass C: only meaningful on virtual devices; restores the
            // original policy afterwards.
            if device.isVirtualDevice {
                let originalBehavior = device.primaryConstituentDeviceSwitchingBehavior
                let originalConditions = device.primaryConstituentDeviceRestrictedSwitchingBehaviorConditions
                if (try? device.lockForConfiguration()) != nil {
                    device.setPrimaryConstituentDeviceSwitchingBehavior(
                        .auto, restrictedSwitchingBehaviorConditions: [])
                    device.unlockForConfiguration()
                }
                walkStops(&lines, device: device, derived: derived,
                          header: "PASS C — photo preset · switching forced auto (no restrictions)")
                if originalBehavior != .unsupported, (try? device.lockForConfiguration()) != nil {
                    device.setPrimaryConstituentDeviceSwitchingBehavior(
                        originalBehavior,
                        restrictedSwitchingBehaviorConditions: originalConditions)
                    device.unlockForConfiguration()
                }
            } else {
                lines.append("PASS C skipped — physical device, no constituent switching")
                lines.append("")
            }
        } catch {
            lines.append("  input failed: \(error.localizedDescription)")
        }
        lines.append("Reading the walks: 'backing camera' is activePrimaryConstituent — the")
        lines.append("physical lens actually in use at that stop. Run once aimed at a bright")
        lines.append("subject several metres away (tele engagement needs distance + light),")
        lines.append("and once at a close desk scene if comparing. If tele stops report the")
        lines.append("wide in A but not B, the config shape is the blocker; if C fixes A,")
        lines.append("the switching policy is; if all three stay wide at distance, deeper.")
        return lines.joined(separator: "\n") + "\n"
    }

    /// One walk over the derived stops in the session's current shape:
    /// per stop set the zoom, wait for the switchover, report the backing
    /// constituent and the Bayer RAW list. probeQueue.
    private func walkStops(
        _ lines: inout [String],
        device: AVCaptureDevice,
        derived: [DerivedOpticsStop],
        header: String
    ) {
        lines.append(header)
        if device.isVirtualDevice {
            lines.append("  switching: \(switchingBehaviorName(device.activePrimaryConstituentDeviceSwitchingBehavior))"
                + " · restricted while [\(restrictedConditionsName(device.activePrimaryConstituentDeviceRestrictedSwitchingBehaviorConditions))]")
        }
        lines.append("  stop   zoom→  backing camera        bayer RAW")
        for stop in derived {
            let ceiling = Double(device.activeFormat.videoMaxZoomFactor)
            let target = min(stop.rawFactor, ceiling)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = CGFloat(target)
                device.unlockForConfiguration()
            } catch {
                lines.append(String(format: "  %4.3gx  lock failed: %@", stop.displayFactor, "\(error)"))
                continue
            }
            // Constituent switchover + RAW list refresh need a beat.
            Thread.sleep(forTimeInterval: 0.7)
            let backing = device.activePrimaryConstituent.map { shortType($0.deviceType) }
                ?? (device.isVirtualDevice ? "unknown" : shortType(device.deviceType))
            let bayer = photoOutput.availableRawPhotoPixelFormatTypes
                .filter { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
            let rawSummary = bayer.isEmpty
                ? "none"
                : bayer.map(fourCC).joined(separator: " ")
            let clampNote = target < stop.rawFactor ? "  (clamped from \(stop.rawFactor))" : ""
            lines.append(String(
                format: "  %4.3gx  %-5.3g  %-20@ %@%@",
                stop.displayFactor, target, backing as NSString, rawSummary, clampNote))
        }
        lines.append("")
    }

    /// Mirror of the app's `applyCaptureFormat` shape for pass B: a 1080p
    /// format pinned to exactly 30 fps (min == max frame duration).
    private func pinStandardVideoFormat(_ device: AVCaptureDevice, into lines: inout [String]) {
        let target = device.formats.first { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width == 1920 && dims.height == 1080
                && format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= 30 && 30 <= $0.maxFrameRate
                }
        }
        guard let target else {
            lines.append("  (no 1080p30 format — pass B ran on the preset's format)")
            return
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = target
            let duration = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            lines.append("  format pin failed: \(error.localizedDescription)")
        }
    }

    // MARK: Formatting

    private func publish(_ status: String) {
        DispatchQueue.main.async { self.statusLine = status }
    }

    private func positionName(_ position: AVCaptureDevice.Position) -> String {
        switch position {
        case .back: return "back "
        case .front: return "front"
        default: return "?    "
        }
    }

    private func shortType(_ type: AVCaptureDevice.DeviceType) -> String {
        type.rawValue.replacingOccurrences(of: "AVCaptureDeviceTypeBuiltIn", with: "")
    }

    private func fieldOfView(_ device: AVCaptureDevice) -> Float {
        device.activeFormat.videoFieldOfView
    }

    private func maxPhotoSummary(_ device: AVCaptureDevice) -> String {
        let best = device.formats
            .flatMap(\.supportedMaxPhotoDimensions)
            .max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
        guard let best else { return "?" }
        return "\(best.width)×\(best.height)"
    }

    private func fourCC(_ type: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((type >> $0) & 0xFF))) }
        return String(bytes)
    }

    private func switchingBehaviorName(
        _ behavior: AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior
    ) -> String {
        switch behavior {
        case .unsupported: return "unsupported"
        case .auto: return "auto"
        case .restricted: return "restricted"
        case .locked: return "locked"
        @unknown default: return "?"
        }
    }

    private func restrictedConditionsName(
        _ conditions: AVCaptureDevice.PrimaryConstituentDeviceRestrictedSwitchingBehaviorConditions
    ) -> String {
        var parts: [String] = []
        if conditions.contains(.videoZoomChanged) { parts.append("zoom") }
        if conditions.contains(.focusModeChanged) { parts.append("focus") }
        if conditions.contains(.exposureModeChanged) { parts.append("exposure") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }
}

// MARK: - View

/// Settings sheet: run the probe, read/copy the topology report. Diagnostics
/// tooling — deliberately outside the design-sync SVG contract.
struct CaptureOpticsProbeView: View {
    @StateObject private var runner = CaptureOpticsProbeRunner()
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Dumps this device's real camera topology — lenses, switchover factors, native sensor crops — then derives the Capture Optics chip set from it and verifies each stop on a live session: which physical camera backs it, and whether Bayer RAW capture survives. Run once per device and copy the results into the Capture Optics groundwork.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if runner.isRunning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(runner.statusLine.isEmpty ? "Running…" : runner.statusLine)
                                .font(.footnote)
                        }
                    } else {
                        Button {
                            runner.run()
                        } label: {
                            Text(runner.reportText == nil ? "Run probe" : "Run again")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let report = runner.reportText {
                        Text(report)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))

                        Button {
                            UIPasteboard.general.string = report
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        } label: {
                            Label(copied ? "Copied" : "Copy results", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationTitle("Capture optics probe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .disabled(runner.isRunning)
                }
            }
        }
        .interactiveDismissDisabled(runner.isRunning)
    }
}

#endif
