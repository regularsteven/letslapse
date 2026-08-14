//
//  CameraDevices.swift
//  LetsLapse
//
//  Which camera the Mac shoots through.
//

#if os(macOS)
import AVFoundation
import Combine
import Foundation
import SwiftUI

/// The Mac's live camera roster and the one the Create window records with.
///
/// iPhone has one camera stack and the optics chips choose *within* it; a Mac
/// has a bag of unrelated cameras — the built-in, a USB action cam, an iPhone
/// over Continuity — and picking between them is a first-class choice, so it
/// gets a menu (`CommandMenu("Camera")`) and a row in the format sheet.
///
/// Live by construction: `AVCaptureDevice.DiscoverySession.devices` is
/// KVO-observable and fires when a webcam is plugged in, when an iPhone comes
/// into Continuity range, and when either goes away. Nothing here polls.
///
/// The selection is stored as a `uniqueID` string rather than a device
/// reference so it survives relaunches and unplugging; `selectedDevice`
/// resolves it against the current roster every time, and falls back to the
/// system default when the remembered camera isn't here any more.
final class CameraDevices: NSObject, ObservableObject {
    static let shared = CameraDevices()

    /// The physical cameras attached right now, in menu order.
    @Published private(set) var devices: [AVCaptureDevice] = []

    /// True while a shoot is running. Swapping the camera mid-capture would
    /// change what the clip looks like halfway through, and the controller
    /// refuses it anyway — so the menu greys out rather than accepting a click
    /// that does nothing.
    @Published private(set) var isCaptureBusy = false

    func setCaptureBusy(_ busy: Bool) {
        guard isCaptureBusy != busy else { return }
        isCaptureBusy = busy
    }

    /// `uniqueID` of the chosen camera. Persisted; may name a camera that
    /// isn't currently connected (unplugging a webcam shouldn't forget it).
    @Published var selectedID: String? {
        didSet {
            guard selectedID != oldValue else { return }
            UserDefaults.standard.set(selectedID, forKey: Self.selectionKey)
        }
    }

    static let selectionKey = "letslapse.camera.selectedDeviceID"

    /// Posted after the roster or the selection changes so a live
    /// `CameraController` can swap the session input. Carries nothing — the
    /// controller reads `resolvedDevice()` itself, on its own queue.
    static let selectionDidChange = Notification.Name("letslapse.camera.selectionDidChange")

    /// Continuity and Desk View are named explicitly: without
    /// `NSCameraUseContinuityCameraDeviceType` in Info.plist an iPhone only
    /// appears under the deprecated `.external` type, and AVFoundation logs a
    /// warning saying so.
    private static let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera,
    ]

    private let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: CameraDevices.deviceTypes, mediaType: .video, position: .unspecified)

    private var devicesObservation: NSKeyValueObservation?

    private override init() {
        super.init()
        selectedID = UserDefaults.standard.string(forKey: Self.selectionKey)
        devicesObservation = discovery.observe(\.devices, options: [.initial, .new]) { [weak self] _, _ in
            self?.refresh()
        }
        // Belt and braces for the case that matters most — the camera being
        // recorded through is unplugged. `refresh()` is idempotent (it drops
        // updates that don't change the roster), so the overlap with KVO costs
        // nothing.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: nil
            ) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    /// `transportType` as its four-character code — the form the constants are
    /// actually written in ('bltn', 'usb ', 'virt'), which is unreadable as
    /// the decimal Int32 the API returns.
    private static func transportCode(_ device: AVCaptureDevice) -> String {
        let raw = UInt32(bitPattern: device.transportType)
        let bytes = [raw >> 24, raw >> 16, raw >> 8, raw].map { UInt8($0 & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    /// A virtual camera is software pretending to be hardware (OBS, Snap,
    /// meeting-app filters). It reports transport `virt` — a probed fact, not
    /// a guess at its name — and Steven's call is that the picker lists real
    /// cameras only. USB, Thunderbolt and PCI sources (webcams, action cams,
    /// capture cards) all keep their place.
    private static func isPhysical(_ device: AVCaptureDevice) -> Bool {
        transportCode(device) != "virt"
    }

    private func refresh() {
        let found = discovery.devices.filter(Self.isPhysical)
        DispatchQueue.main.async {
            guard self.devices.map(\.uniqueID) != found.map(\.uniqueID) else { return }
            self.devices = found
            NotificationCenter.default.post(name: Self.selectionDidChange, object: nil)
        }
    }

    /// Every physical camera attached right now, resolved without touching
    /// `@Published` state so the capture session queue can call it. Same
    /// thread-safety reasoning as `resolvedDevice()` below.
    static func connectedDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
            .devices.filter(isPhysical)
    }

    /// The camera to record through: the remembered one when it is present,
    /// otherwise the system default (which is what the app used before this
    /// picker existed), otherwise whatever is first.
    ///
    /// Deliberately not `@MainActor` and not reading `@Published` state:
    /// `CameraController` calls this from its session queue while configuring
    /// the session. `DiscoverySession.devices` is safe to read from any
    /// thread and `UserDefaults` is thread-safe, so this resolves without
    /// hopping to main — which would deadlock the session queue.
    static func resolvedDevice() -> AVCaptureDevice? {
        let connected = connectedDevices()
        if let id = UserDefaults.standard.string(forKey: selectionKey),
           let match = connected.first(where: { $0.uniqueID == id }) {
            return match
        }
        return AVCaptureDevice.default(for: .video) ?? connected.first
    }

    /// The chosen camera as the UI sees it, for menu checkmarks and the
    /// format sheet's picker. Resolves the same way `resolvedDevice()` does so
    /// the tick is always on the camera actually in the session.
    var selectedDevice: AVCaptureDevice? {
        if let selectedID, let match = devices.first(where: { $0.uniqueID == selectedID }) {
            return match
        }
        return AVCaptureDevice.default(for: .video) ?? devices.first
    }

    /// Point the app at a different camera. Broadcast rather than called
    /// through, because the menu lives in the App scene and the controller
    /// lives inside whichever Create window happens to be showing capture.
    func select(_ device: AVCaptureDevice) {
        selectedID = device.uniqueID
        NotificationCenter.default.post(name: Self.selectionDidChange, object: nil)
    }

    /// How the camera reaches the Mac — the format sheet's subtitle, and the
    /// one thing that tells two identically-named webcams apart.
    ///
    /// An iPhone over Continuity reports transport `othr`, so without the
    /// device-type check above it would read "External" — which is true of the
    /// wire and useless to a human looking for their phone.
    static func connectionLabel(for device: AVCaptureDevice) -> String {
        if device.deviceType == .deskViewCamera { return "Desk View" }
        if device.deviceType == .continuityCamera { return "Continuity Camera" }
        switch transportCode(device) {
        case "bltn": return "Built-in"
        case "usb ": return "USB"
        case "1394": return "FireWire"
        case "pci ": return "PCI"
        case "thnd": return "Thunderbolt"
        case "othr": return "Continuity Camera"
        default: return "External"
        }
    }

    /// Menu/picker text. Names alone are enough until two cameras share one —
    /// two of the same webcam model, or an iPhone's camera and its Desk View —
    /// and then the connection tells them apart.
    static func menuLabel(for device: AVCaptureDevice, among all: [AVCaptureDevice]) -> String {
        let name = device.localizedName
        let isAmbiguous = all.filter { $0.localizedName == name }.count > 1
        return isAmbiguous ? "\(name) (\(connectionLabel(for: device)))" : name
    }
}

// MARK: - Camera menu

/// The **Camera** menu in the Mac menu bar: which camera the Create window
/// records through. Lives at App-scene level because that is where menus are
/// declared, while the `CameraController` it steers is owned by whichever
/// capture screen is open — hence the notification rather than a direct call.
struct CameraCommands: Commands {
    var body: some Commands {
        CommandMenu("Camera") {
            // The observation deliberately sits in a real View: `Commands`
            // structs do not reliably re-evaluate on `@ObservedObject`
            // changes, so a webcam plugged in while the app runs would not
            // appear in the menu.
            CameraMenuContent()
        }
    }
}

private struct CameraMenuContent: View {
    @ObservedObject private var devices = CameraDevices.shared

    var body: some View {
        if devices.devices.isEmpty {
            Text("No Cameras Found")
        } else {
            let selectedID = devices.selectedDevice?.uniqueID
            ForEach(devices.devices, id: \.uniqueID) { device in
                // A Toggle is the native menu idiom — macOS draws it as a
                // checkmark item. Selecting is one-way: clicking the camera
                // already in use shouldn't deselect it and leave the app with
                // no camera at all.
                Toggle(isOn: Binding(
                    get: { device.uniqueID == selectedID },
                    set: { if $0 { devices.select(device) } }
                )) {
                    Text(CameraDevices.menuLabel(for: device, among: devices.devices))
                }
                .disabled(devices.isCaptureBusy)
            }
        }
    }
}
#endif
