import Foundation
import AVFoundation
#if os(iOS)
import UIKit
#endif

/// Owns the AVCaptureSession for both capture modes: movie recording and
/// interval photo capture for stacking.
/// Session work runs on a dedicated queue; published state hops to main.
final class CameraController: NSObject, ObservableObject {
    enum Lens: String, CaseIterable, Identifiable {
        #if os(iOS)
        case ultraWide
        #endif
        case wide
        #if os(iOS)
        case telephoto
        #endif

        var id: String { rawValue }

        var label: String {
            switch self {
            #if os(iOS)
            case .ultraWide: return "Ultra Wide"
            #endif
            case .wide: return "Wide (1x)"
            #if os(iOS)
            case .telephoto: return "Telephoto"
            #endif
            }
        }

        var deviceType: AVCaptureDevice.DeviceType {
            switch self {
            #if os(iOS)
            case .ultraWide: return .builtInUltraWideCamera
            #endif
            case .wide: return .builtInWideAngleCamera
            #if os(iOS)
            case .telephoto: return .builtInTelephotoCamera
            #endif
            }
        }
    }

    struct CaptureResolution: Identifiable, Hashable {
        var width: Int32
        var height: Int32

        var id: String { "\(width)x\(height)" }

        var label: String {
            switch (width, height) {
            case (3840, 2160): return "4K"
            case (1920, 1080): return "1080p"
            case (1280, 720): return "720p"
            default: return "\(width)x\(height)"
            }
        }

        var pixelCount: Int64 {
            Int64(width) * Int64(height)
        }
    }

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.letslapse.capture")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var videoDevice: AVCaptureDevice?
    private var selectedPhotoDimensions: CMVideoDimensions?
    private var intervalTimer: DispatchSourceTimer?
    private var photoDirectory: URL?
    private var photoURLs: [URL] = []   // sessionQueue-confined
    private var videoStabilizationRequested = true
    private let preferredFrameRates = [24, 25, 30, 50, 60, 100, 120, 240]
    private let frameRateTolerance = 0.2
    private var activeSequence: LiveCaptureSequence?
    private var activeSequenceDirectory: URL?
    private var activeSequenceStartedAt: Date?
    private var activeSegmentStartedAt: Date?
    private var activeRecordingFrameRate: Int?
    private var activeSegmentURL: URL?
    private var segmentURLs: [URL] = []
    private var pendingRampFrameRate: Int?
    private var isFinishingSequence = false
    private var isDiscardingSequence = false
    private var rampIntervalActive = false

    @Published var isAuthorized: Bool?
    @Published var isRecording = false
    @Published var recordingStartedAt: Date?
    @Published var isIntervalRunning = false
    @Published var photoCount = 0
    @Published var activeFormatDescription = ""
    @Published var availableLenses: [Lens] = []
    @Published var selectedLens: Lens = .wide
    @Published var availableResolutions: [CaptureResolution] = []
    @Published var selectedResolution = CaptureResolution(width: 1920, height: 1080)
    @Published var availableFrameRates: [Int] = [30]
    @Published var selectedFrameRate = 30
    @Published var selectedRampFrameRate = 120
    @Published var isVideoStabilizationEnabled = true
    @Published var videoStabilizationStatus = "Stabilization Auto"
    @Published var activeSequenceMode: LiveCaptureSequence.Mode?
    @Published var markerCount = 0
    @Published var rampIntervalCount = 0
    @Published var segmentCount = 0
    @Published var isRampActive = false
    @Published var isRampHighRate = false

    /// Both called on the main queue.
    var onFinishVideo: ((URL) -> Void)?
    var onFinishLiveCapture: ((LiveCaptureResult) -> Void)?
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
                self.isDiscardingSequence = true
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
        refreshCaptureOptions()
        applyVideoStabilization()
        publishFormat()
    }

    private func publishAvailableLenses() {
        let lenses = Lens.allCases.filter { lens in
            self.captureDevice(for: lens) != nil
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
            self.refreshCaptureOptions()
            self.applyVideoStabilization()
            self.publishFormat()
        }
    }

    private func configureLens(_ lens: Lens) {
        let device = captureDevice(for: lens) ?? captureDevice(for: .wide)
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

    private func captureDevice(for lens: Lens) -> AVCaptureDevice? {
        #if os(iOS)
        return AVCaptureDevice.default(lens.deviceType, for: .video, position: .back)
        #else
        return AVCaptureDevice.default(for: .video)
        #endif
    }

    func selectResolution(_ resolution: CaptureResolution) {
        sessionQueue.async {
            guard !self.movieOutput.isRecording, self.intervalTimer == nil else { return }
            self.refreshCaptureOptions(preferredResolution: resolution)
            self.publishFormat()
        }
    }

    func setVideoStabilizationEnabled(_ isEnabled: Bool) {
        DispatchQueue.main.async {
            self.isVideoStabilizationEnabled = isEnabled
        }
        sessionQueue.async {
            guard !self.movieOutput.isRecording, self.intervalTimer == nil else { return }
            self.videoStabilizationRequested = isEnabled
            self.refreshCaptureOptions()
            self.applyVideoStabilization()
            self.publishFormat()
        }
    }

    func selectFrameRate(_ fps: Int) {
        sessionQueue.async {
            guard !self.movieOutput.isRecording, self.intervalTimer == nil else { return }
            self.refreshCaptureOptions(preferredFrameRate: fps)
            self.publishFormat()
        }
    }

    private func refreshCaptureOptions(
        preferredResolution: CaptureResolution? = nil,
        preferredFrameRate: Int? = nil
    ) {
        guard let device = videoDevice else { return }
        let supportedRates = supportedFrameRatesByResolution(for: device)
        guard !supportedRates.isEmpty else {
            DispatchQueue.main.async {
                self.availableResolutions = []
                self.availableFrameRates = []
            }
            return
        }

        let resolutions = supportedRates.keys.sorted {
            if $0.pixelCount == $1.pixelCount {
                return $0.width > $1.width
            }
            return $0.pixelCount > $1.pixelCount
        }
        let desiredResolution = preferredResolution ?? selectedResolution
        let resolution = resolutions.first { $0 == desiredResolution }
            ?? resolutions.first { $0.width == 1920 && $0.height == 1080 }
            ?? resolutions[0]
        let frameRates = Array(supportedRates[resolution] ?? [30]).sorted()
        let desiredFrameRate = preferredFrameRate ?? selectedFrameRate
        let frameRate = frameRates.contains(desiredFrameRate)
            ? desiredFrameRate
            : nearestFrameRate(to: desiredFrameRate, in: frameRates)
        let rampFrameRate = frameRates.contains(selectedRampFrameRate)
            ? selectedRampFrameRate
            : nearestRampFrameRate(from: frameRate, in: frameRates)

        _ = applyCaptureFormat(resolution: resolution, fps: frameRate)
        DispatchQueue.main.async {
            self.availableResolutions = resolutions
            self.selectedResolution = resolution
            self.availableFrameRates = frameRates
            self.selectedFrameRate = frameRate
            self.selectedRampFrameRate = rampFrameRate
        }
    }

    private func supportedFrameRatesByResolution(
        for device: AVCaptureDevice
    ) -> [CaptureResolution: Set<Int>] {
        var supportedRates: [CaptureResolution: Set<Int>] = [:]
        for format in device.formats {
            #if os(iOS)
            guard !videoStabilizationRequested || stabilizationMode(for: format) != nil else {
                continue
            }
            #endif
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width >= 640, dims.height >= 480 else { continue }
            let resolution = CaptureResolution(width: dims.width, height: dims.height)
            let rates = supportedFrameRates(for: format)
            guard !rates.isEmpty else { continue }
            supportedRates[resolution, default: []].formUnion(rates)
        }
        return supportedRates
    }

    private func supportedFrameRates(for format: AVCaptureDevice.Format) -> Set<Int> {
        var rates = Set<Int>()
        for range in format.videoSupportedFrameRateRanges {
            for fps in preferredFrameRates
                where supportsFrameRate(Double(fps), in: range) {
                rates.insert(fps)
            }
            let maxFPS = Int(range.maxFrameRate.rounded())
            if maxFPS > 0, maxFPS <= 240,
               supportsFrameRate(Double(maxFPS), in: range) {
                rates.insert(maxFPS)
            }
        }
        return rates
    }

    private func supportsFrameRate(_ fps: Double, in range: AVFrameRateRange) -> Bool {
        fps >= range.minFrameRate - frameRateTolerance
            && fps <= range.maxFrameRate + frameRateTolerance
    }

    private func nearestFrameRate(to preferred: Int, in frameRates: [Int]) -> Int {
        frameRates.min { first, second in
            abs(first - preferred) < abs(second - preferred)
        } ?? frameRates[0]
    }

    private func nearestRampFrameRate(from baseFrameRate: Int, in frameRates: [Int]) -> Int {
        frameRates
            .filter { $0 > baseFrameRate }
            .sorted()
            .first ?? frameRates.last ?? baseFrameRate
    }

    func selectRampFrameRate(_ fps: Int) {
        sessionQueue.async {
            guard !self.movieOutput.isRecording, self.intervalTimer == nil else { return }
            let frameRate = self.availableFrameRates.contains(fps)
                ? fps
                : self.nearestRampFrameRate(from: self.selectedFrameRate, in: self.availableFrameRates)
            DispatchQueue.main.async {
                self.selectedRampFrameRate = frameRate
            }
        }
    }

    @discardableResult
    private func applyCaptureFormat(resolution: CaptureResolution, fps: Int) -> Bool {
        guard let device = videoDevice,
              let match = captureFormatMatch(for: device, resolution: resolution, fps: fps)
        else { return false }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = match.format
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            selectedPhotoDimensions = match.photoDimensions
            if let photoDimensions = match.photoDimensions,
               !sameDimensions(photoOutput.maxPhotoDimensions, photoDimensions) {
                photoOutput.maxPhotoDimensions = photoDimensions
            }
            return true
        } catch {
            return false
        }
    }

    private func captureFormatMatch(
        for device: AVCaptureDevice,
        resolution: CaptureResolution,
        fps: Int
    ) -> (format: AVCaptureDevice.Format, photoDimensions: CMVideoDimensions?)? {
        let targetFPS = Double(fps)
        return device.formats
            .filter { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                #if os(iOS)
                let stabilizationMatches = !videoStabilizationRequested || stabilizationMode(for: format) != nil
                #else
                let stabilizationMatches = true
                #endif
                return dims.width == resolution.width
                    && dims.height == resolution.height
                    && stabilizationMatches
                    && format.videoSupportedFrameRateRanges.contains { range in
                        supportsFrameRate(targetFPS, in: range)
                    }
            }
            .map { format in
                (format: format, photoDimensions: bestPhotoDimensions(for: format, preferred: resolution))
            }
            .sorted { first, second in
                #if os(iOS)
                let firstStabilization = stabilizationSortScore(for: first.format)
                let secondStabilization = stabilizationSortScore(for: second.format)
                if firstStabilization != secondStabilization {
                    return firstStabilization > secondStabilization
                }
                #endif
                let firstPixels = first.photoDimensions.map(photoPixelCount) ?? 0
                let secondPixels = second.photoDimensions.map(photoPixelCount) ?? 0
                return firstPixels > secondPixels
            }
            .first
    }

    private func bestPhotoDimensions(
        for format: AVCaptureDevice.Format,
        preferred resolution: CaptureResolution
    ) -> CMVideoDimensions? {
        let dimensions = format.supportedMaxPhotoDimensions
        if let exact = dimensions.first(where: {
            $0.width == resolution.width && $0.height == resolution.height
        }) {
            return exact
        }
        return dimensions
            .filter { photoPixelCount($0) <= resolution.pixelCount }
            .sorted { photoPixelCount($0) > photoPixelCount($1) }
            .first ?? dimensions.sorted { photoPixelCount($0) < photoPixelCount($1) }.first
    }

    private func photoPixelCount(_ dimensions: CMVideoDimensions) -> Int64 {
        Int64(dimensions.width) * Int64(dimensions.height)
    }

    private func sameDimensions(_ lhs: CMVideoDimensions, _ rhs: CMVideoDimensions) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height
    }

    private func currentFPS(for device: AVCaptureDevice) -> Int {
        let frameDuration = device.activeVideoMinFrameDuration
        if frameDuration.seconds > 0 {
            return Int((1.0 / frameDuration.seconds).rounded())
        }
        return selectedFrameRate
    }

    private func publishFormat() {
        guard let device = videoDevice else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let fps = currentFPS(for: device)
        let stabilizationStatus: String
        if let connection = movieOutput.connection(with: .video) {
            #if os(iOS)
            stabilizationStatus = videoStabilizationStatusDescription(
                preferred: connection.preferredVideoStabilizationMode,
                active: connection.activeVideoStabilizationMode
            )
            #else
            _ = connection
            stabilizationStatus = "Stabilization Off"
            #endif
        } else {
            stabilizationStatus = videoStabilizationRequested ? "Stabilization Auto" : "Stabilization Off"
        }
        let line = "Capture \(dims.width)×\(dims.height) @ \(fps) fps · \(stabilizationStatus)"
        DispatchQueue.main.async {
            self.videoStabilizationStatus = stabilizationStatus
            self.activeFormatDescription = line
        }
    }

    func setVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        sessionQueue.async {
            #if os(iOS)
            let connections = [
                self.movieOutput.connection(with: .video),
                self.photoOutput.connection(with: .video),
            ]
            for connection in connections {
                if connection?.isVideoOrientationSupported == true {
                    connection?.videoOrientation = orientation
                }
            }
            #else
            _ = orientation
            #endif
            self.applyVideoStabilization()
        }
    }

    #if os(iOS)
    private func stabilizationMode(for format: AVCaptureDevice.Format) -> AVCaptureVideoStabilizationMode? {
        if format.isVideoStabilizationModeSupported(.cinematic) {
            return .cinematic
        }
        if format.isVideoStabilizationModeSupported(.standard) {
            return .standard
        }
        return nil
    }

    private func stabilizationSortScore(for format: AVCaptureDevice.Format) -> Int {
        switch stabilizationMode(for: format) {
        case .cinematic:
            return 2
        case .standard:
            return 1
        default:
            return 0
        }
    }
    #endif

    private func applyVideoStabilization() {
        #if os(iOS)
        guard let connection = movieOutput.connection(with: .video) else { return }

        let activeFormat = videoDevice?.activeFormat
        let activeFormatSupportsStabilization = activeFormat.flatMap { stabilizationMode(for: $0) } != nil
        if videoStabilizationRequested,
           connection.isVideoStabilizationSupported,
           activeFormatSupportsStabilization {
            connection.preferredVideoStabilizationMode = .auto
        } else {
            connection.preferredVideoStabilizationMode = .off
        }

        let status = videoStabilizationStatusDescription(
            preferred: connection.preferredVideoStabilizationMode,
            active: connection.activeVideoStabilizationMode
        )
        DispatchQueue.main.async {
            self.videoStabilizationStatus = status
        }
        #else
        DispatchQueue.main.async {
            self.videoStabilizationStatus = "Stabilization Off"
        }
        #endif
    }

    #if os(iOS)
    private func videoStabilizationStatusDescription(
        preferred: AVCaptureVideoStabilizationMode,
        active: AVCaptureVideoStabilizationMode
    ) -> String {
        guard preferred != .off else { return "Stabilization Off" }

        switch active {
        case .cinematic:
            return "Stabilization Cinematic"
        case .standard:
            return "Stabilization Standard"
        default:
            return "Stabilization Auto"
        }
    }
    #endif

    // MARK: - Movie recording

    func startRecording() {
        startRecording(mode: .marker)
    }

    func startRecording(mode: LiveCaptureSequence.Mode) {
        sessionQueue.async {
            guard !self.movieOutput.isRecording else { return }
            let startedAt = Date()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("live-capture-\(Int(startedAt.timeIntervalSince1970))")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let resolution = LiveCaptureSequence.Resolution(
                width: self.selectedResolution.width,
                height: self.selectedResolution.height
            )
            self.activeSequence = LiveCaptureSequence(
                mode: mode,
                createdAt: startedAt,
                lockedResolution: resolution,
                baseFrameRate: self.selectedFrameRate,
                rampFrameRate: mode == .ramp ? self.selectedRampFrameRate : nil,
                segments: [],
                markers: [],
                rampIntervals: []
            )
            self.activeSequenceDirectory = directory
            self.activeSequenceStartedAt = startedAt
            self.segmentURLs = []
            self.pendingRampFrameRate = nil
            self.isFinishingSequence = false
            self.isDiscardingSequence = false
            self.rampIntervalActive = false
            self.startNextSegment(frameRate: self.selectedFrameRate)
            DispatchQueue.main.async {
                self.recordingStartedAt = startedAt
                self.isRecording = true
                self.activeSequenceMode = mode
                self.markerCount = 0
                self.rampIntervalCount = 0
                self.segmentCount = 1
                self.isRampActive = false
                self.isRampHighRate = false
            }
        }
    }

    func stopRecording() {
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.closeOpenRampInterval(at: Date())
                self.isFinishingSequence = true
                self.movieOutput.stopRecording()
            }
        }
    }

    func triggerLiveMoment() {
        sessionQueue.async {
            guard let sequence = self.activeSequence,
                  self.movieOutput.isRecording,
                  let startedAt = self.activeSequenceStartedAt else { return }

            switch sequence.mode {
            case .marker:
                self.toggleRampInterval(at: Date(), sequenceStartedAt: startedAt)
            case .ramp:
                guard self.pendingRampFrameRate == nil else { return }
                let shouldTurnRampOn = !self.rampIntervalActive
                let targetFrameRate = shouldTurnRampOn
                    ? (sequence.rampFrameRate ?? self.selectedRampFrameRate)
                    : sequence.baseFrameRate
                let currentFrameRate = self.activeRecordingFrameRate ?? self.selectedFrameRate
                guard targetFrameRate != currentFrameRate else { return }
                if shouldTurnRampOn {
                    self.openRampInterval(at: Date(), sequenceStartedAt: startedAt)
                } else {
                    self.closeOpenRampInterval(at: Date())
                }
                self.pendingRampFrameRate = targetFrameRate
                self.movieOutput.stopRecording()
            }
        }
    }

    private func toggleRampInterval(at date: Date, sequenceStartedAt: Date) {
        if rampIntervalActive {
            closeOpenRampInterval(at: date)
        } else {
            openRampInterval(at: date, sequenceStartedAt: sequenceStartedAt)
        }
    }

    private func openRampInterval(at date: Date, sequenceStartedAt: Date) {
        guard var sequence = activeSequence, !rampIntervalActive else { return }
        let interval = LiveCaptureSequence.RampInterval(
            index: sequence.rampIntervals.count,
            relativeStart: date.timeIntervalSince(sequenceStartedAt),
            relativeEnd: nil
        )
        sequence.rampIntervals.append(interval)
        activeSequence = sequence
        rampIntervalActive = true
        publishRampState(isActive: true, intervalCount: sequence.rampIntervals.count)
    }

    private func closeOpenRampInterval(at date: Date) {
        guard var sequence = activeSequence,
              rampIntervalActive,
              let sequenceStartedAt = activeSequenceStartedAt,
              let index = sequence.rampIntervals.lastIndex(where: { $0.relativeEnd == nil })
        else { return }

        let relativeEnd = max(
            sequence.rampIntervals[index].relativeStart,
            date.timeIntervalSince(sequenceStartedAt)
        )
        sequence.rampIntervals[index].relativeEnd = relativeEnd
        activeSequence = sequence
        rampIntervalActive = false
        publishRampState(isActive: false, intervalCount: sequence.rampIntervals.count)
    }

    private func publishRampState(isActive: Bool, intervalCount: Int) {
        DispatchQueue.main.async {
            self.isRampActive = isActive
            self.isRampHighRate = isActive
            self.rampIntervalCount = intervalCount
            self.markerCount = intervalCount
        }
    }

    private func startNextSegment(frameRate: Int) {
        guard let directory = activeSequenceDirectory else { return }
        _ = applyCaptureFormat(resolution: selectedResolution, fps: frameRate)
        #if os(iOS)
        if let connection = movieOutput.connection(with: .video),
           connection.isVideoOrientationSupported {
            connection.videoOrientation = currentCaptureOrientation()
        }
        #endif
        applyVideoStabilization()
        publishFormat()

        let index = segmentURLs.count
        let url = directory.appendingPathComponent(String(format: "segment-%03d.mov", index))
        activeSegmentURL = url
        activeSegmentStartedAt = Date()
        activeRecordingFrameRate = frameRate
        movieOutput.startRecording(to: url, recordingDelegate: self)

        DispatchQueue.main.async {
            self.selectedFrameRate = frameRate
            self.segmentCount = index + 1
            if let sequence = self.activeSequence, sequence.mode == .ramp {
                let highRate = frameRate != sequence.baseFrameRate
                self.isRampHighRate = highRate
                self.isRampActive = highRate
            }
        }
    }

    private func finishSegment(outputFileURL: URL) {
        guard var sequence = activeSequence,
              let startedAt = activeSequenceStartedAt,
              let segmentStartedAt = activeSegmentStartedAt,
              let frameRate = activeRecordingFrameRate
        else { return }

        let index = sequence.segments.count
        let relativeStart = segmentStartedAt.timeIntervalSince(startedAt)
        let relativeEnd = max(relativeStart, Date().timeIntervalSince(startedAt))
        let segment = LiveCaptureSequence.Segment(
            index: index,
            fileName: outputFileURL.lastPathComponent,
            frameRate: frameRate,
            relativeStart: relativeStart,
            relativeEnd: relativeEnd
        )
        sequence.segments.append(segment)
        activeSequence = sequence
        segmentURLs.append(outputFileURL)
        activeSegmentStartedAt = nil
        activeSegmentURL = nil
        activeRecordingFrameRate = nil
    }

    private func completeLiveCapture() {
        guard let sequence = activeSequence,
              let directory = activeSequenceDirectory
        else {
            resetLiveCaptureState()
            return
        }

        let metadataURL = directory.appendingPathComponent("sequence.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sequence)
            try data.write(to: metadataURL, options: .atomic)
            let result = LiveCaptureResult(
                sequence: sequence,
                segmentURLs: segmentURLs,
                metadataURL: metadataURL
            )
            resetLiveCaptureState()
            DispatchQueue.main.async {
                self.isRecording = false
                self.recordingStartedAt = nil
                if let onFinishLiveCapture = self.onFinishLiveCapture {
                    onFinishLiveCapture(result)
                } else if let primaryVideoURL = result.primaryVideoURL {
                    self.onFinishVideo?(primaryVideoURL)
                }
            }
        } catch {
            resetLiveCaptureState()
            DispatchQueue.main.async {
                self.isRecording = false
                self.recordingStartedAt = nil
            }
        }
    }

    private func resetLiveCaptureState() {
        restoreBaseFrameRateIfNeeded()
        activeSequence = nil
        activeSequenceDirectory = nil
        activeSequenceStartedAt = nil
        activeSegmentStartedAt = nil
        activeRecordingFrameRate = nil
        activeSegmentURL = nil
        segmentURLs = []
        pendingRampFrameRate = nil
        isFinishingSequence = false
        isDiscardingSequence = false
        rampIntervalActive = false
        DispatchQueue.main.async {
            self.activeSequenceMode = nil
            self.markerCount = 0
            self.rampIntervalCount = 0
            self.segmentCount = 0
            self.isRampActive = false
            self.isRampHighRate = false
        }
    }

    private func restoreBaseFrameRateIfNeeded() {
        guard let sequence = activeSequence, sequence.mode == .ramp else { return }
        _ = applyCaptureFormat(resolution: selectedResolution, fps: sequence.baseFrameRate)
        publishFormat()
        DispatchQueue.main.async {
            self.selectedFrameRate = sequence.baseFrameRate
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
                #if os(iOS)
                if let connection = self.photoOutput.connection(with: .video),
                   connection.isVideoOrientationSupported {
                    connection.videoOrientation = currentCaptureOrientation()
                }
                #endif
                let settings = AVCapturePhotoSettings()
                if let photoDimensions = self.selectedPhotoDimensions {
                    settings.maxPhotoDimensions = photoDimensions
                }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
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

#if os(iOS)
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
#else
func currentCaptureOrientation() -> AVCaptureVideoOrientation {
    .landscapeRight
}
#endif

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        sessionQueue.async {
            let fileExists = FileManager.default.fileExists(atPath: outputFileURL.path)
            if fileExists {
                self.finishSegment(outputFileURL: outputFileURL)
            }

            if self.isDiscardingSequence {
                self.resetLiveCaptureState()
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.recordingStartedAt = nil
                }
                return
            }

            if let nextFrameRate = self.pendingRampFrameRate {
                self.pendingRampFrameRate = nil
                self.startNextSegment(frameRate: nextFrameRate)
                return
            }

            if self.isFinishingSequence {
                self.completeLiveCapture()
                return
            }

            DispatchQueue.main.async {
                self.isRecording = false
                self.recordingStartedAt = nil
                if fileExists {
                    self.onFinishVideo?(outputFileURL)
                }
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
