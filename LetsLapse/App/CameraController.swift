#if os(iOS)
import Foundation
import AVFoundation
import UIKit

/// Owns the AVCaptureSession for both capture modes: movie recording
/// (optionally at the camera's highest 1080p frame rate, the raw material for
/// slow-mo → hyperlapse ramps) and interval photo capture for stacking.
/// Session work runs on a dedicated queue; published state hops to main.
final class CameraController: NSObject, ObservableObject {
    enum Lens: String, CaseIterable, Identifiable {
        case ultraWide
        case wide
        case telephoto

        var id: String { rawValue }

        var label: String {
            switch self {
            case .ultraWide: return "Ultra Wide"
            case .wide: return "Wide (1x)"
            case .telephoto: return "Telephoto"
            }
        }

        var deviceType: AVCaptureDevice.DeviceType {
            switch self {
            case .ultraWide: return .builtInUltraWideCamera
            case .wide: return .builtInWideAngleCamera
            case .telephoto: return .builtInTelephotoCamera
            }
        }
    }

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.letslapse.capture")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var videoDevice: AVCaptureDevice?
    private var highFrameRateEnabled = false
    private var intervalTimer: DispatchSourceTimer?
    private var photoDirectory: URL?
    private var photoURLs: [URL] = []   // sessionQueue-confined

    @Published var isAuthorized: Bool?
    @Published var isRecording = false
    @Published var isIntervalRunning = false
    @Published var photoCount = 0
    @Published var activeFormatDescription = ""
    @Published var availableLenses: [Lens] = []
    @Published var selectedLens: Lens = .wide

    /// Both called on the main queue.
    var onFinishVideo: ((URL) -> Void)?
    var onFinishPhotos: (([URL]) -> Void)?

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { self.isAuthorized = granted }
            guard granted else { return }
            self.sessionQueue.async {
                self.configureIfNeeded()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            self.intervalTimer?.cancel()
            self.intervalTimer = nil
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private var isConfigured = false

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true
        session.beginConfiguration()
        session.sessionPreset = .high
        publishAvailableLenses()
        configureLens(.wide)
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()
        publishFormat()
    }

    private func publishAvailableLenses() {
        let lenses = Lens.allCases.filter { lens in
            AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) != nil
        }
        DispatchQueue.main.async {
            self.availableLenses = lenses.isEmpty ? [.wide] : lenses
        }
    }

    func selectLens(_ lens: Lens) {
        sessionQueue.async {
            guard !self.movieOutput.isRecording, self.intervalTimer == nil else { return }
            self.session.beginConfiguration()
            self.configureLens(lens)
            self.session.commitConfiguration()
            self.setHighFrameRateOnCurrentDevice(self.highFrameRateEnabled)
            self.publishFormat()
        }
    }

    private func configureLens(_ lens: Lens) {
        let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return }

        if let videoInput {
            session.removeInput(videoInput)
        }
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            videoDevice = device
            let selected = Lens.allCases.first { $0.deviceType == device.deviceType } ?? .wide
            DispatchQueue.main.async { self.selectedLens = selected }
        }
    }

    /// Best-effort switch to the highest frame rate the camera offers at
    /// 1080p (120/240 fps on recent iPhones). Falls back silently if the
    /// device has no high-fps format.
    func setHighFrameRate(_ enabled: Bool) {
        sessionQueue.async {
            self.highFrameRateEnabled = enabled
            self.setHighFrameRateOnCurrentDevice(enabled)
            self.publishFormat()
        }
    }

    private func setHighFrameRateOnCurrentDevice(_ enabled: Bool) {
        guard let device = self.videoDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if enabled {
                var best: (format: AVCaptureDevice.Format, fps: Double)?
                for format in device.formats {
                    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    guard dims.width == 1920 else { continue }
                    for range in format.videoSupportedFrameRateRanges {
                        let fps = min(range.maxFrameRate, 240)
                        if fps >= 120, fps > (best?.fps ?? 0) {
                            best = (format, fps)
                        }
                    }
                }
                if let best {
                    device.activeFormat = best.format
                    let duration = CMTime(value: 1, timescale: Int32(best.fps))
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
                }
            } else {
                device.activeVideoMinFrameDuration = .invalid
                device.activeVideoMaxFrameDuration = .invalid
            }
        } catch {
            // Leave the current format in place.
        }
    }

    private func publishFormat() {
        guard let device = videoDevice else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let frameDuration = device.activeVideoMinFrameDuration
        let fps = frameDuration.seconds > 0 ? Int((1.0 / frameDuration.seconds).rounded()) : 30
        let line = "Capture \(dims.width)×\(dims.height) @ \(fps) fps"
        DispatchQueue.main.async { self.activeFormatDescription = line }
    }

    func setVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        sessionQueue.async {
            let connections = [
                self.movieOutput.connection(with: .video),
                self.photoOutput.connection(with: .video),
            ]
            for connection in connections {
                if connection?.isVideoOrientationSupported == true {
                    connection?.videoOrientation = orientation
                }
            }
        }
    }

    // MARK: - Movie recording

    func startRecording() {
        sessionQueue.async {
            guard !self.movieOutput.isRecording else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("capture-\(Int(Date().timeIntervalSince1970)).mov")
            if let connection = self.movieOutput.connection(with: .video),
               connection.isVideoOrientationSupported {
                connection.videoOrientation = currentCaptureOrientation()
            }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            DispatchQueue.main.async { self.isRecording = true }
        }
    }

    func stopRecording() {
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
        }
    }

    // MARK: - Interval photos

    func startInterval(every seconds: Double) {
        sessionQueue.async {
            guard self.intervalTimer == nil else { return }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("interval-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.photoDirectory = directory
            self.photoURLs = []
            DispatchQueue.main.async {
                self.photoCount = 0
                self.isIntervalRunning = true
            }
            let timer = DispatchSource.makeTimerSource(queue: self.sessionQueue)
            timer.schedule(deadline: .now(), repeating: max(0.5, seconds))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if let connection = self.photoOutput.connection(with: .video),
                   connection.isVideoOrientationSupported {
                    connection.videoOrientation = currentCaptureOrientation()
                }
                self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
            }
            timer.resume()
            self.intervalTimer = timer
        }
    }

    func stopInterval() {
        sessionQueue.async {
            self.intervalTimer?.cancel()
            self.intervalTimer = nil
            let urls = self.photoURLs
            DispatchQueue.main.async {
                self.isIntervalRunning = false
                if urls.count >= 2 {
                    self.onFinishPhotos?(urls)
                }
            }
        }
    }
}

func currentCaptureOrientation() -> AVCaptureVideoOrientation {
    let orientation = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }?
        .interfaceOrientation

    switch orientation {
    case .landscapeLeft:
        return .landscapeLeft
    case .landscapeRight:
        return .landscapeRight
    case .portraitUpsideDown:
        return .portraitUpsideDown
    default:
        return .portrait
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.isRecording = false
            // A partial file can still be delivered alongside an error.
            if FileManager.default.fileExists(atPath: outputFileURL.path) {
                self.onFinishVideo?(outputFileURL)
            }
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        sessionQueue.async {
            guard let directory = self.photoDirectory else { return }
            let url = directory.appendingPathComponent(
                String(format: "frame-%05d.jpg", self.photoURLs.count))
            if (try? data.write(to: url)) != nil {
                self.photoURLs.append(url)
                DispatchQueue.main.async { self.photoCount = self.photoURLs.count }
            }
        }
    }
}
#endif
