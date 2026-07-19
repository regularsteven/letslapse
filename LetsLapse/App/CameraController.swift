#if os(iOS)
import Foundation
import AVFoundation

/// Owns the AVCaptureSession for both capture modes: movie recording
/// (optionally at the camera's highest 1080p frame rate, the raw material for
/// slow-mo → hyperlapse ramps) and interval photo capture for stacking.
/// Session work runs on a dedicated queue; published state hops to main.
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.letslapse.capture")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoDevice: AVCaptureDevice?
    private var intervalTimer: DispatchSourceTimer?
    private var photoDirectory: URL?
    private var photoURLs: [URL] = []   // sessionQueue-confined

    @Published var isAuthorized: Bool?
    @Published var isRecording = false
    @Published var isIntervalRunning = false
    @Published var photoCount = 0
    @Published var activeFormatDescription = ""

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
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device) {
            videoDevice = device
            if session.canAddInput(input) { session.addInput(input) }
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()
        publishFormat()
    }

    /// Best-effort switch to the highest frame rate the camera offers at
    /// 1080p (120/240 fps on recent iPhones). Falls back silently if the
    /// device has no high-fps format.
    func setHighFrameRate(_ enabled: Bool) {
        sessionQueue.async {
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
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .high
                    self.session.commitConfiguration()
                }
            } catch {
                // Leave the current format in place.
            }
            self.publishFormat()
        }
    }

    private func publishFormat() {
        guard let device = videoDevice else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let frameDuration = device.activeVideoMinFrameDuration
        let fps = frameDuration.seconds > 0 ? Int((1.0 / frameDuration.seconds).rounded()) : 30
        let line = "\(dims.width)×\(dims.height) @ \(fps) fps"
        DispatchQueue.main.async { self.activeFormatDescription = line }
    }

    // MARK: - Movie recording

    func startRecording() {
        sessionQueue.async {
            guard !self.movieOutput.isRecording else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("capture-\(Int(Date().timeIntervalSince1970)).mov")
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
