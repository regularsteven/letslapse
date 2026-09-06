// A Watch neither serves a library nor imports one, and has no camera to
// scan with — the same exclusion as the rest of project transfer.
#if !os(watchOS)
import SwiftUI
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
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

/// The camera session behind the scanner viewport.
///
/// Owns nothing the app's own `CameraController` owns: a separate
/// `AVCaptureSession` with one metadata output and no photo, video or preview
/// pipeline. The two must never run at once, which is why the view that hosts
/// this asks the model whether a capture is in flight before it ever appears.
@MainActor
final class PairingQRScanner: NSObject, ObservableObject {
    /// nil until asked. `.authorized` is the only state that shows a viewport.
    @Published private(set) var authorization: AVAuthorizationStatus = .notDetermined
    /// Why there is no picture — no camera on this Mac, a configuration that
    /// was refused. Shown in place of the viewport rather than swallowed.
    @Published private(set) var failure: String?

    let session = AVCaptureSession()
    private let output = AVCaptureMetadataOutput()
    private let sessionQueue = DispatchQueue(label: "com.regularsteven.letslapse.pairingqr")
    private var isConfigured = false
    /// Called on the main actor with each decoded six-digit code. The host
    /// decides whether it belongs to the device it is pairing with.
    var onCode: ((String) -> Void)?
    /// One code per scan session: a QR sits in frame for many frames, and
    /// without this the host would be asked to connect thirty times a second.
    private var lastDelivered: String?

    func start() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        switch authorization {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.authorization = granted ? .authorized : .denied
                    if granted { self.configureAndRun() }
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

    private func configureAndRun() {
        guard !isConfigured else {
            sessionQueue.async { [session] in
                if !session.isRunning { session.startRunning() }
            }
            return
        }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(output)
        else {
            failure = "No camera available on this device."
            return
        }
        isConfigured = true
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        // Set AFTER the output joins the session: `metadataObjectTypes` is
        // empty until then, and assigning .qr to a detached output traps.
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
        session.commitConfiguration()
        if output.metadataObjectTypes.isEmpty {
            failure = "This camera cannot read QR codes."
            return
        }
        // startRunning blocks — never on the main actor, where it stalls the
        // sheet's presentation animation.
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }
}

extension PairingQRScanner: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let codes = metadataObjects
            .compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            .compactMap(PairingQR.code(in:))
        guard let code = codes.first else { return }
        Task { @MainActor in
            guard lastDelivered != code else { return }
            lastDelivered = code
            onCode?(code)
        }
    }
}

/// The viewport itself: a live camera picture with a reticle over it, sized by
/// its host. Reports every LetsLapse QR it decodes, once each.
struct PairingQRScannerView: View {
    var onCode: (String) -> Void
    @StateObject private var scanner = PairingQRScanner()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.85))
            if scanner.authorization == .authorized, scanner.failure == nil {
                PairingQRCameraPreview(session: scanner.session)
                reticle
            } else {
                message
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear {
            scanner.onCode = onCode
            scanner.start()
        }
        .onDisappear { scanner.stop() }
        .accessibilityLabel("Camera, looking for a pairing QR code")
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
            return "LetsLapse needs camera access to scan a pairing code. Type the code instead, or turn the camera on in Settings."
        default:
            return "Starting the camera…"
        }
    }
}

#if os(iOS)
private struct PairingQRCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
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
