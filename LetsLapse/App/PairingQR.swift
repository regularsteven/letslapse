// A Watch neither serves a library nor imports one, and has no camera to
// scan with — the same exclusion as the rest of project transfer.
#if !os(watchOS)
import SwiftUI
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The QR half of transfer pairing: what the serving device draws, and what the
/// importing device reads off it.
///
/// **The payload carries the pairing code and nothing else.** It does not need
/// to carry the device's identity, because the identity is *derivable* from the
/// code: `CaptureRemotePairing.pairingID(code:)` is the same hash the serving
/// device advertises in its TXT record, so a scanning client can check a
/// scanned code against the device it has already picked before a byte moves —
/// exactly the check `ProjectTransferClient.select` makes against a remembered
/// code. A QR from the wrong phone, or one photographed before the code
/// rotated, fails that check locally and says so, rather than presenting as a
/// pairing failure seconds later.
///
/// So this is a shortcut past *typing*, not past *pairing*: the scanned code
/// goes through the same `connect(to:code:)` as a typed one, gets the same
/// PSK-derived TLS, and is remembered on success the same way — which is what
/// makes the next visit to that device silent whichever way the first one went.
enum PairingQR {
    /// Versioned so a later payload can grow fields without an old build
    /// mis-reading one. Anything after the six digits is ignored by design.
    static let prefix = "LLXFER1:"

    static func payload(code: String) -> String { prefix + code }

    /// The six-digit code inside a scanned string, or nil if this is not one of
    /// ours. Deliberately strict about the prefix: a phone pointed at a room
    /// full of QR codes must not try to pair with a Wi-Fi sticker.
    static func code(in scanned: String) -> String? {
        guard scanned.hasPrefix(prefix) else { return nil }
        let digits = scanned.dropFirst(prefix.count).prefix { $0.isNumber }
        guard digits.count == 6 else { return nil }
        return String(digits)
    }

    /// The code drawn as a QR, at `scale` device points per module.
    ///
    /// `samplingNearest` before the transform is not a nicety: the default
    /// bilinear sampling blurs a QR's module edges, and a blurred QR on a phone
    /// screen photographed by another phone is exactly where decoding starts
    /// failing.
    static func image(code: String, scale: CGFloat = 10) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(payload(code: code).utf8), forKey: "inputMessage")
        // M: 15% recovery. L would be denser to no purpose — this is read off a
        // bright screen a hand's width away, not printed on a box.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

/// One camera the pairing scanner can look through.
///
/// A value rather than the `AVCaptureDevice` itself because the picker is
/// SwiftUI and re-renders: `uniqueID` is stable across a webcam being unplugged
/// and plugged back in, which a device reference is not.
struct PairingQRCamera: Identifiable, Equatable {
    let id: String
    let name: String
}

/// The camera session behind the scanner viewport.
///
/// Owns nothing the app's own `CameraController` owns: a separate
/// `AVCaptureSession` with its decode output and no photo, video or preview
/// pipeline. The two must never run at once, which is why the view that hosts
/// this asks the model whether a capture is in flight before it ever appears.
///
/// **Two decode routes, chosen per camera rather than per platform.**
/// `AVCaptureMetadataOutput` does barcode detection in the capture stack for
/// free, and it is the route wherever the camera offers it. It does not offer
/// it on macOS: `availableMetadataObjectTypes` never lists `.qr` there, on any
/// camera, which is why the Mac used to say it could not scan at all. Vision
/// reads the same frames and does — so a camera that cannot do it itself gets
/// an `AVCaptureVideoDataOutput` and a `VNDetectBarcodesRequest` instead. The
/// caller sees one scanner either way.
@MainActor
final class PairingQRScanner: NSObject, ObservableObject {
    /// nil until asked. `.authorized` is the only state that shows a viewport.
    @Published private(set) var authorization: AVAuthorizationStatus = .notDetermined
    /// Why there is no picture — no camera on this Mac, a camera that refused
    /// to open. Shown in place of the viewport rather than swallowed.
    @Published private(set) var failure: String?
    /// Every camera this device could look through, in picker order. One entry
    /// (or none) means there is nothing to choose between and no control.
    @Published private(set) var cameras: [PairingQRCamera] = []
    /// `uniqueID` of the camera in the session right now.
    @Published private(set) var activeCameraID: String?
    /// Width ÷ height of the picture the active camera delivers, **before** the
    /// rotation the preview applies. The viewport is laid out at this shape so
    /// the feed is neither stretched, letterboxed nor cropped — the bug this
    /// replaced sized the box by its host and let `resizeAspectFill` throw away
    /// whatever did not fit, which on an iPad in landscape was most of it.
    @Published private(set) var sourceAspect: CGFloat = PairingQRScanner.defaultAspect

    let session = AVCaptureSession()
    /// Called on the main actor with each decoded six-digit code. The host
    /// decides whether it belongs to the device it is pairing with.
    var onCode: ((String) -> Void)?

    private let metadataOutput = AVCaptureMetadataOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let visionTap = PairingQRVisionTap()
    private let sessionQueue = DispatchQueue(label: "com.regularsteven.letslapse.pairingqr")
    private let visionQueue = DispatchQueue(label: "com.regularsteven.letslapse.pairingqr.vision")
    /// Session plumbing, touched only on `sessionQueue`.
    private let state = SessionState()
    /// The camera the live session was built around, so a second `start()` —
    /// a sheet re-appearing — resumes rather than rebuilding.
    private var configuredCameraID: String?
    /// One code per scan session: a QR sits in frame for many frames, and
    /// without this the host would be asked to connect thirty times a second.
    private var lastDelivered: String?
    private var rosterObservers: [NSObjectProtocol] = []

    /// The camera last chosen by hand. Remembered because the reason to choose
    /// one is rarely a one-off — a Mac with two webcams wants the same one next
    /// time, and a device being tested against another on the same desk wants
    /// its front camera every time until it doesn't.
    private static let cameraKey = "letslapse.pairingqr.cameraID"

    /// The shape to lay the viewport out at before a camera has answered.
    /// Both values are what the platform's cameras overwhelmingly deliver, so
    /// the box almost never changes shape once the picture arrives.
    nonisolated private static var defaultAspect: CGFloat {
        #if os(macOS)
        16.0 / 9.0
        #else
        4.0 / 3.0
        #endif
    }

    /// Everything the capture session owns. A plain class rather than stored
    /// properties because the configuration runs on `sessionQueue` — opening a
    /// camera blocks for long enough to drop a frame of the sheet's animation
    /// if it happens on the main actor.
    private final class SessionState {
        var input: AVCaptureDeviceInput?
    }

    override init() {
        super.init()
        visionTap.handler = { [weak self] payloads in self?.ingest(payloads) }
        // A webcam plugged in, an iPhone drifting into Continuity range, the
        // camera in use unplugged mid-scan: all three change the picker, and
        // the last one needs the session moved to a camera that still exists.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.rosterChanged() }
            }
            rosterObservers.append(token)
        }
    }

    deinit {
        for token in rosterObservers { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - Lifecycle

    func start() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        switch authorization {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.authorization = granted ? .authorized : .denied
                    if granted { self.run() }
                }
            }
        default:
            break
        }
    }

    func stop() {
        lastDelivered = nil
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Point the scanner at a different camera. The remembered choice moves
    /// with it; the session is rebuilt around the new input without ever
    /// stopping, so the viewport cuts rather than blinking to black.
    func select(_ cameraID: String) {
        guard cameraID != activeCameraID,
              let device = Self.roster().first(where: { $0.uniqueID == cameraID })
        else { return }
        UserDefaults.standard.set(cameraID, forKey: Self.cameraKey)
        configure(device)
    }

    /// The next camera in picker order, wrapping.
    func selectNextCamera() {
        guard cameras.count > 1 else { return }
        let index = cameras.firstIndex { $0.id == activeCameraID } ?? -1
        select(cameras[(index + 1) % cameras.count].id)
    }

    /// The other side of the device — what a tap on the picker does, because
    /// "the one pointing the other way" is what anyone reaching for this
    /// wants: the code is on the screen you are standing in front of, or on
    /// the phone in your hand, and those are opposite sides.
    ///
    /// Deliberately the *wide* lens of that side rather than the next camera
    /// along: the roster is in lens order, so a device whose front has two
    /// (an iPad's Centre Stage ultra wide sits beside its front wide) flips
    /// to the one that frames like a viewfinder. Where sides mean nothing —
    /// every camera on a Mac is simply another camera — this cycles instead.
    func flipCamera() {
        guard cameras.count > 1 else { return }
        let roster = Self.roster()
        guard let active = roster.first(where: { $0.uniqueID == activeCameraID }),
              active.position == .front || active.position == .back,
              let opposite = roster.first(where: {
                  $0.position == (active.position == .front ? .back : .front)
              })
        else {
            selectNextCamera()
            return
        }
        select(opposite.uniqueID)
    }

    // MARK: - Roster

    /// Cameras worth offering, in picker order.
    ///
    /// The Mac reuses `CameraDevices`, which already knows the roster the
    /// capture side shoots through — including its filter for software
    /// "virtual" cameras, which have nothing to point at a QR code. The
    /// *selection* is deliberately not shared: choosing a webcam to scan with
    /// must not change the camera the app records with.
    private static func roster() -> [AVCaptureDevice] {
        #if os(macOS)
        return CameraDevices.connectedDevices()
        #else
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.sorted { rank($0) < rank($1) }
        #endif
    }

    #if !os(macOS)
    /// Back before front, and the wide lens before its neighbours: the order a
    /// phone's own camera app offers them in, and the order in which they are
    /// likely to be wanted — the wide reads a code across a desk, the ultra
    /// wide one held too close to focus, the front one on the screen you are
    /// standing in front of.
    private static func rank(_ device: AVCaptureDevice) -> Int {
        let position = device.position == .front ? 10 : 0
        switch device.deviceType {
        case .builtInWideAngleCamera: return position
        case .builtInUltraWideCamera: return position + 1
        case .builtInTelephotoCamera: return position + 2
        default: return position + 3
        }
    }
    #endif

    private static func label(for device: AVCaptureDevice, among all: [AVCaptureDevice]) -> String {
        #if os(macOS)
        return CameraDevices.menuLabel(for: device, among: all)
        #else
        return device.localizedName
        #endif
    }

    /// The camera to open: the remembered one when it is here, otherwise the
    /// system default when that is one this picker would offer, otherwise
    /// whatever is first.
    private func preferredDevice() -> AVCaptureDevice? {
        let roster = Self.roster()
        if let id = UserDefaults.standard.string(forKey: Self.cameraKey),
           let match = roster.first(where: { $0.uniqueID == id }) {
            return match
        }
        if let system = AVCaptureDevice.default(for: .video),
           roster.contains(where: { $0.uniqueID == system.uniqueID }) {
            return system
        }
        return roster.first
    }

    private func publishRoster(_ roster: [AVCaptureDevice]) {
        let next = roster.map { PairingQRCamera(id: $0.uniqueID, name: Self.label(for: $0, among: roster)) }
        guard cameras != next else { return }
        cameras = next
        LLog("pairingqr: cameras=[\(next.map(\.name).joined(separator: ", "))]")
    }

    /// A camera arrived or left. Refresh the picker, and if the one in the
    /// session is the one that left, move to whatever is still here — an empty
    /// viewport with a live session pointed at nothing helps nobody.
    private func rosterChanged() {
        guard authorization == .authorized else { return }
        let roster = Self.roster()
        publishRoster(roster)
        guard let activeCameraID else { return }
        if !roster.contains(where: { $0.uniqueID == activeCameraID }) {
            configuredCameraID = nil
            run()
        }
    }

    // MARK: - Session

    private func run() {
        let roster = Self.roster()
        publishRoster(roster)
        guard let device = preferredDevice() else {
            failure = "No camera available on this device."
            return
        }
        guard configuredCameraID != device.uniqueID else {
            sessionQueue.async { [session] in
                if !session.isRunning { session.startRunning() }
            }
            return
        }
        configure(device)
    }

    private func configure(_ device: AVCaptureDevice) {
        failure = nil
        lastDelivered = nil
        activeCameraID = device.uniqueID
        configuredCameraID = device.uniqueID

        let session = self.session
        let metadataOutput = self.metadataOutput
        let videoOutput = self.videoOutput
        let visionTap = self.visionTap
        let visionQueue = self.visionQueue
        let state = self.state
        let owner = self

        sessionQueue.async { [weak self] in
            guard let input = try? AVCaptureDeviceInput(device: device) else {
                Task { @MainActor in self?.fail("That camera could not be opened.") }
                return
            }

            session.beginConfiguration()
            if let previous = state.input { session.removeInput(previous) }
            guard session.canAddInput(input) else {
                // Put the working camera back rather than leaving a session
                // with no input at all — the picture the human is looking at
                // must not disappear because a different camera refused.
                if let previous = state.input, session.canAddInput(previous) { session.addInput(previous) }
                session.commitConfiguration()
                Task { @MainActor in self?.fail("That camera could not be opened.") }
                return
            }
            session.addInput(input)
            state.input = input

            #if !os(macOS)
            // 4:3 is the sensor's own shape and the most of it there is: a code
            // held a hand's width away lands inside a full-height frame far
            // more easily than inside the 16:9 crop `.high` would hand back.
            if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
            #endif

            // The metadata route, if this camera has one. `metadataObjectTypes`
            // must be set AFTER the output joins the session — it is empty
            // until then, and assigning `.qr` to a detached output traps — and
            // `availableMetadataObjectTypes` is only truthful once there is an
            // input to answer for, which is why this is re-asked per camera
            // rather than once per platform.
            if !session.outputs.contains(metadataOutput), session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                metadataOutput.setMetadataObjectsDelegate(owner, queue: .main)
            }
            var usesMetadata = false
            if session.outputs.contains(metadataOutput) {
                metadataOutput.metadataObjectTypes =
                    metadataOutput.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
                usesMetadata = !metadataOutput.metadataObjectTypes.isEmpty
            }

            var usesVision = false
            if usesMetadata {
                // Don't pay for frames nobody reads.
                if session.outputs.contains(videoOutput) { session.removeOutput(videoOutput) }
            } else {
                if session.outputs.contains(metadataOutput) { session.removeOutput(metadataOutput) }
                if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
                    videoOutput.alwaysDiscardsLateVideoFrames = true
                    // Ask for BGRA rather than taking the camera's native
                    // format. A Mac's roster is open-ended — a USB microscope
                    // and a capture card are as welcome here as the built-in
                    // camera — and native formats vary with it, so pinning one
                    // Vision is certain of costs a conversion nobody will feel
                    // at eight frames a second and removes a whole class of
                    // "works on this camera, not that one".
                    if videoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA) {
                        videoOutput.videoSettings =
                            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    }
                    videoOutput.setSampleBufferDelegate(visionTap, queue: visionQueue)
                    session.addOutput(videoOutput)
                }
                usesVision = session.outputs.contains(videoOutput)
                // A front-facing camera mirrors its connections by default —
                // and every Mac's built-in camera is front-facing. A mirrored
                // QR does not decode, so the frames Vision reads are pinned
                // un-mirrored. The preview layer keeps its own mirroring,
                // which is what makes aiming feel the right way round.
                if let connection = videoOutput.connection(with: .video),
                   connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
            }
            session.commitConfiguration()

            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let aspect: CGFloat = dimensions.height > 0
                ? CGFloat(dimensions.width) / CGFloat(dimensions.height)
                : Self.defaultAspect

            // startRunning blocks — never on the main actor, where it stalls
            // the sheet's presentation animation.
            if !session.isRunning { session.startRunning() }

            let route = usesMetadata ? "metadata" : (usesVision ? "vision" : "NONE")
            LLog("pairingqr: camera=\(device.localizedName) route=\(route) "
                + "source=\(dimensions.width)x\(dimensions.height) aspect=\(String(format: "%.3f", aspect))")

            Task { @MainActor in
                guard let self else { return }
                self.sourceAspect = aspect
                if !usesMetadata && !usesVision {
                    self.fail("This camera cannot read QR codes.")
                }
            }
        }
    }

    private func fail(_ message: String) {
        failure = message
    }

    // MARK: - Decoded payloads

    /// Both routes land here: whatever a frame held, filtered to codes that
    /// are ours, and delivered once each.
    fileprivate func ingest(_ payloads: [String]) {
        guard let code = payloads.compactMap(PairingQR.code(in:)).first else { return }
        guard lastDelivered != code else { return }
        lastDelivered = code
        onCode?(code)
    }
}

extension PairingQRScanner: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let payloads = metadataObjects
            .compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        guard !payloads.isEmpty else { return }
        Task { @MainActor in ingest(payloads) }
    }
}

/// Barcode detection for cameras AVFoundation will not do it for.
///
/// `AVCaptureMetadataOutput`'s built-in code detection is an iOS/tvOS feature:
/// on macOS `availableMetadataObjectTypes` never lists `.qr`, whichever camera
/// is attached, which is why the Mac's answer used to be that it could not
/// scan. Vision reads the same frames and does — the same
/// `VNDetectBarcodesRequest` the monitor test card is decoded with.
private final class PairingQRVisionTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Called on the main queue with every payload found in a frame.
    var handler: (([String]) -> Void)?

    private let request: VNDetectBarcodesRequest = {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        return request
    }()

    /// About 8 Hz. A code sits in front of a camera for seconds at a time;
    /// running Vision on every frame of a 30 fps stream spends a core to save
    /// a delay nobody can perceive. Queue-confined — the delegate is serial.
    private var nextRunAt = Date.distantPast

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        guard now >= nextRunAt, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        nextRunAt = now.addingTimeInterval(0.12)
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        try? requestHandler.perform([request])
        let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
        guard !payloads.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.handler?(payloads) }
    }
}

/// The viewport itself: a live camera picture with a reticle over it, drawn at
/// the shape the camera actually delivers. Reports every LetsLapse QR it
/// decodes, once each.
struct PairingQRScannerView: View {
    var onCode: (String) -> Void
    @StateObject private var scanner = PairingQRScanner()
    #if os(iOS)
    /// Which way the preview is rotated — and therefore whether the viewport
    /// is a tall box or a wide one. Same source as the capture screen's:
    /// the *interface* orientation, so a locked device keeps a still picture.
    @State private var orientation: AVCaptureVideoOrientation = currentCaptureOrientation()
    #endif

    /// Big enough to aim with, small enough to leave the Connect button on
    /// screen with a number pad up. The box takes whichever of the two the
    /// camera's shape reaches first, so a portrait feed is tall and narrow and
    /// a webcam's is short and wide — neither is stretched to fill a slot.
    private static let maxWidth: CGFloat = 340
    private static let maxHeight: CGFloat = 250

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.85))
            if scanner.authorization == .authorized, scanner.failure == nil {
                #if os(iOS)
                PairingQRCameraPreview(session: scanner.session, orientation: orientation)
                #else
                PairingQRCameraPreview(session: scanner.session)
                #endif
                reticle
            } else {
                message
            }
            cameraControl
        }
        .frame(width: viewport.width, height: viewport.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear {
            scanner.onCode = onCode
            scanner.start()
            #if os(iOS)
            // The capture screen turns these on for itself; this sheet can be
            // reached without ever having opened it. Balanced in onDisappear —
            // the calls nest.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            orientation = currentCaptureOrientation()
            #endif
        }
        .onDisappear {
            scanner.stop()
            #if os(iOS)
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            #endif
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            orientation = currentCaptureOrientation()
        }
        #endif
    }

    /// The camera's own shape, transposed when the preview is rotated upright,
    /// then fitted inside the box's two limits.
    private var viewport: CGSize {
        #if os(iOS)
        let isPortrait = orientation == .portrait || orientation == .portraitUpsideDown
        let aspect = isPortrait ? 1 / scanner.sourceAspect : scanner.sourceAspect
        #else
        let aspect = scanner.sourceAspect
        #endif
        guard aspect > 0 else { return CGSize(width: Self.maxWidth, height: Self.maxHeight) }
        var width = Self.maxWidth
        var height = width / aspect
        if height > Self.maxHeight {
            height = Self.maxHeight
            width = height * aspect
        }
        return CGSize(width: width, height: height)
    }

    /// Corners rather than a full box: the picture is small, and four brackets
    /// say "put the code here" without hiding any of it.
    private var reticle: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height) * 0.62
            let box = CGRect(
                x: (geometry.size.width - side) / 2,
                y: (geometry.size.height - side) / 2,
                width: side, height: side)
            let arm = side * 0.24
            Path { path in
                for (corner, dx, dy) in [
                    (CGPoint(x: box.minX, y: box.minY), 1.0, 1.0),
                    (CGPoint(x: box.maxX, y: box.minY), -1.0, 1.0),
                    (CGPoint(x: box.minX, y: box.maxY), 1.0, -1.0),
                    (CGPoint(x: box.maxX, y: box.maxY), -1.0, -1.0),
                ] {
                    path.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
                    path.addLine(to: corner)
                    path.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
                }
            }
            .stroke(LL.amber, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Camera, looking for a pairing QR code")
    }

    /// Which camera is looking. Present only where there is a choice — a
    /// device with one camera gets no control at all — and present even when
    /// the current one has failed, because switching is the way out of that.
    @ViewBuilder
    private var cameraControl: some View {
        if scanner.authorization == .authorized, scanner.cameras.count > 1 {
            VStack {
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    #if os(macOS)
                    // A Mac's cameras are a list of unrelated things, and a
                    // click that opens the list is the Mac idiom for choosing
                    // between them. There is no "other side" to flip to.
                    Menu { cameraChoices } label: { cameraGlyph }
                        .menuIndicator(.hidden)
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Choose camera")
                    #else
                    // Tap flips front/back — the one thing anyone reaches for
                    // — and holding opens the full list, which is where a
                    // device with three lenses puts the other two rather than
                    // making the common action a two-tap menu trip.
                    Menu {
                        cameraChoices
                    } label: {
                        cameraGlyph
                    } primaryAction: {
                        scanner.flipCamera()
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Switch camera")
                    .accessibilityHint("Double tap to flip between front and back. Touch and hold to choose a lens.")
                    #endif
                }
            }
            .padding(8)
        }
    }

    /// A Toggle is the native picker idiom in a menu — a checkmark row on
    /// both platforms. One-way: choosing the camera already in use must not
    /// deselect it and leave the scanner looking at nothing.
    @ViewBuilder
    private var cameraChoices: some View {
        ForEach(scanner.cameras) { camera in
            Toggle(isOn: Binding(
                get: { camera.id == scanner.activeCameraID },
                set: { if $0 { scanner.select(camera.id) } }
            )) {
                Text(camera.name)
            }
        }
    }

    private var cameraGlyph: some View {
        Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Color.black.opacity(0.5), in: Circle())
            .contentShape(Circle())
    }

    @ViewBuilder
    private var message: some View {
        VStack(spacing: 6) {
            Image(systemName: scanner.authorization == .denied ? "video.slash" : "qrcode.viewfinder")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.7))
            Text(messageText)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 14)
        }
    }

    private var messageText: String {
        if let failure = scanner.failure { return failure }
        switch scanner.authorization {
        case .denied, .restricted:
            #if os(macOS)
            return "LetsLapse needs camera access to scan a pairing code. Type the code instead, or turn the camera on in System Settings ▸ Privacy & Security."
            #else
            return "LetsLapse needs camera access to scan a pairing code. Type the code instead, or turn the camera on in Settings."
            #endif
        default:
            return "Starting the camera…"
        }
    }
}

#if os(iOS)
private struct PairingQRCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// The interface orientation the host is tracking. Used as the seed and
    /// the fallback; the view's own window wins once it has one.
    let orientation: AVCaptureVideoOrientation

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.reapplyOrientation = { [weak view] in
            guard let view else { return }
            applyOrientation(to: view)
        }
        view.observeSessionStart(of: session)
        applyOrientation(to: view)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        applyOrientation(to: view)
    }

    /// Rotate the preview connection to match the interface.
    ///
    /// A freshly formed preview connection defaults to portrait and never
    /// follows the device on its own, which is the whole of the bug this
    /// fixes: on an iPad resting in landscape the pairing feed came up on its
    /// side. The window's scene is authoritative once the view has one (it is
    /// right under rotation lock, where the device is not); before that the
    /// orientation the host passed in stands, which is already correct on a
    /// sheet opened in landscape.
    private func applyOrientation(to view: PreviewView) {
        let interface = view.window?.windowScene?.interfaceOrientation
        let target = interface.map(effectiveCaptureOrientation(interface:)) ?? orientation
        let connection = view.previewLayer.connection
        LLog("pairingqr: orientation interface=\(interface?.rawValue ?? -1) target=\(target.rawValue) "
            + "conn=\(connection != nil) was=\(connection?.videoOrientation.rawValue ?? -1)")
        guard let connection,
              connection.isVideoOrientationSupported,
              connection.videoOrientation != target
        else { return }
        connection.videoOrientation = target
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        /// Re-applies the connection orientation outside SwiftUI's update
        /// cycle. The preview connection does not exist at `makeUIView` time —
        /// this scanner configures its session asynchronously, on its own
        /// queue — so without a nudge on window attach and on session start, a
        /// sheet opened in landscape keeps the portrait default until the
        /// device is rotated.
        var reapplyOrientation: (() -> Void)?
        private var sessionStartObserver: NSObjectProtocol?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { reapplyOrientation?() }
        }

        func observeSessionStart(of session: AVCaptureSession) {
            sessionStartObserver = NotificationCenter.default.addObserver(
                forName: .AVCaptureSessionDidStartRunning,
                object: session,
                queue: .main
            ) { [weak self] _ in
                self?.reapplyOrientation?()
            }
        }

        deinit {
            if let sessionStartObserver {
                NotificationCenter.default.removeObserver(sessionStartObserver)
            }
        }
    }
}
#else
private struct PairingQRCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.wantsLayer = true
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {}

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override func makeBackingLayer() -> CALayer { previewLayer }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}
#endif
#endif
