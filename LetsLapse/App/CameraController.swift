import Foundation
import AVFoundation
#if os(iOS)
import UIKit
#endif

/// Temporary capture diagnostics. Flip `captureDiagEnabled` off to silence.
/// Everything is tagged 🎥LL so it's easy to filter in the Xcode console.
/// Each line is prefixed with a rolling seconds timer so delays are visible as
/// the gap between two lines.
let captureDiagEnabled = true
@inline(__always) func LLog(_ message: @autoclosure () -> String) {
    if captureDiagEnabled {
        let t = ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 1000)
        print(String(format: "🎥LL %7.3f %@", t, message()))
    }
}

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
        var isProRes: Bool = false

        var id: String { isProRes ? "\(width)x\(height)-prores" : "\(width)x\(height)" }

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
    private var audioInput: AVCaptureDeviceInput?
    private var videoDevice: AVCaptureDevice?
    private var selectedPhotoDimensions: CMVideoDimensions?
    private var intervalTimer: DispatchSourceTimer?
    private var photoDirectory: URL?
    private var photoURLs: [URL] = []   // sessionQueue-confined
    private var videoStabilizationRequested = true
    // 10/12/15 are acquisition rates for the blend pipeline: sparse temporal
    // sampling with up to a full-interval shutter, meant to be conformed or
    // blended rather than played as-is.
    private let preferredFrameRates = [10, 12, 15, 24, 25, 30, 50, 60, 100, 120, 240]
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
    // Manual-exposure lock state, confined to sessionQueue. Source of truth for
    // re-asserting the lock after every activeFormat switch; the @Published
    // mirrors below are for UI/Watch only.
    private var exposureLocked = false
    private var lockedISOValue: Float = 0
    private var lockedShutterValue: Double = 0
    private var lockedLensValue: Float = 0.5

    @Published var isAuthorized: Bool?
    @Published var isRecording = false
    @Published var recordingStartedAt: Date?
    @Published var isIntervalRunning = false
    @Published var photoCount = 0 {
        didSet { checkScheduledStopCount() }
    }
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
    @Published var rampSpans: [RampSpan] = []
    @Published var isExposureLocked: Bool = false
    @Published var lockedISO: Float = 0
    @Published var lockedShutterSeconds: Double = 0
    @Published var lockedLensPosition: Float = 0.5
    @Published var isoRange: ClosedRange<Float> = 25...3200
    /// Manual 180° flip for upside-down mounts, on top of whatever orientation
    /// the interface/device implies. Session-only (resets each launch) so a
    /// left-on flip can't silently invert a later handheld shot.
    @Published var flipOrientation180 = false
    // Live Blend engine — Interval mode's blend/DNG pipeline.
    @Published var isLiveBlendRunning = false
    @Published var liveBlendOutputCount = 0 {
        didSet { checkScheduledStopCount() }
    }
    @Published var liveBlendDiagnostics: LiveBlendDiagnosticsSnapshot?

    /// Whether the active camera source can produce Live Blend DNG — i.e.
    /// offers Bayer RAW capture. Honest by construction: computed from the
    /// photo output's actual RAW formats, never assumed.
    struct LiveBlendDNGSupport: Equatable {
        var isSupported: Bool
        var reason: String?
        /// The sensor frame DNG captures deliver (the photo configuration's
        /// active format — full 4:3 on iPhones), so the UI can present the
        /// true resolution and aspect instead of the 16:9 video format.
        var sensorDimensions: CaptureResolution?
    }

    @Published var liveBlendDNGSupport = LiveBlendDNGSupport(
        isSupported: false, reason: "Checking camera…")

    /// Actual dimensions of the live feed the preview layer is showing
    /// (published from every (re)configuration), so the viewfinder
    /// letterboxes to what the sensor really delivers — the 4:3 photo feed
    /// while a DNG shoot is armed, the 16:9 video format otherwise.
    @Published var previewDimensions: CaptureResolution?

    /// A pending "stop at…" set from the Watch remote. Time-based stops hold
    /// a deadline; frame-based stops in Interval/Live Blend hold an absolute
    /// output-count target. Enforced here (not on the Watch) so the stop
    /// fires even when the Watch app is suspended.
    struct ScheduledStop: Equatable {
        var unit: ScheduledStopUnit
        var deadline: Date?
        var targetCount: Int?
    }

    @Published var scheduledStop: ScheduledStop?
    private var scheduledStopWorkItem: DispatchWorkItem?

    /// A ramp/marker interval relative to the recording start, for the
    /// on-screen segment strip. `end == nil` while the interval is open.
    struct RampSpan: Identifiable, Equatable {
        let id: Int
        var start: TimeInterval
        var end: TimeInterval?
    }

    /// All called on the main queue.
    var onFinishVideo: ((URL) -> Void)?
    var onFinishLiveCapture: ((LiveCaptureResult) -> Void)?
    var onFinishPhotos: (([URL]) -> Void)?
    var onFinishLiveBlend: ((LiveBlendCaptureResult) -> Void)?

    // sessionQueue-confined; the output is added lazily on the first Live
    // Blend run and stays attached (delegate cleared between runs).
    private var liveBlendOutput: AVCaptureVideoDataOutput?
    private var liveBlendController: LiveBlendController?
    #if os(iOS)
    private var liveBlendRawController: LiveBlendRawController?
    #endif

    /// True while a Live Blend run is collecting or draining. Guards the
    /// format/lens setters the same way recording and interval capture do.
    private var isLiveBlendActive: Bool {
        #if os(iOS)
        if liveBlendRawController?.isActive == true { return true }
        #endif
        return liveBlendController?.isActive == true
    }

    override init() {
        super.init()
        restoreRememberedSettings()
    }

    /// Seed the capture settings from the previous shoot when "Remember
    /// recording settings" is on. Runs before the session is configured;
    /// values the current device can't provide fall back gracefully in
    /// `refreshCaptureOptions`.
    private func restoreRememberedSettings() {
        guard RecordingSettingsStore.isEnabled else { return }
        if let lens = RecordingSettingsStore.lens {
            selectedLens = lens
        }
        if let resolution = RecordingSettingsStore.resolution {
            selectedResolution = resolution
        }
        if let frameRate = RecordingSettingsStore.frameRate {
            selectedFrameRate = frameRate
        }
        if let rampFrameRate = RecordingSettingsStore.rampFrameRate {
            selectedRampFrameRate = rampFrameRate
        }
        if let stabilization = RecordingSettingsStore.stabilization {
            isVideoStabilizationEnabled = stabilization
            videoStabilizationRequested = stabilization
        }
    }

    // True between start() and stop(): the capture screen is up and wants a
    // running session. Used to auto-resume after a background interruption
    // (screen lock, Control Center, a momentary background) without which the
    // camera stays dead until the view is dismissed and reopened.
    private var shouldBeRunning = false

    func start() {
        LLog("start() called")
        installSessionLogging()
        shouldBeRunning = true
        AVCaptureDevice.requestAccess(for: .video) { granted in
            LLog("access granted=\(granted)")
            DispatchQueue.main.async { self.isAuthorized = granted }
            guard granted else { return }
            self.sessionQueue.async {
                self.configureIfNeeded()
                self.reconcileSettingsDrivenState()
                if !self.session.isRunning {
                    LLog("startRunning()")
                    self.session.startRunning()
                    LLog("after startRunning isRunning=\(self.session.isRunning)")
                }
            }
        }
    }

    func stop() {
        LLog("stop() called")
        shouldBeRunning = false
        cancelScheduledStop()
        sessionQueue.async {
            self.intervalTimer?.cancel()
            self.intervalTimer = nil
            if self.movieOutput.isRecording {
                self.isDiscardingSequence = true
                self.movieOutput.stopRecording()
            }
            // Discard-teardown for an abandoned Live Blend run (screen closed
            // mid-capture). A gracefully finished run is already inactive by
            // the time its finish handler calls stop(), so this leaves the
            // handed-over temp frames alone.
            #if os(iOS)
            if let rawController = self.liveBlendRawController, rawController.isActive {
                rawController.requestStop(discard: true)
                self.restoreAfterDNGRun()
                DispatchQueue.main.async { self.isLiveBlendRunning = false }
            }
            #endif
            if let controller = self.liveBlendController, controller.isActive {
                self.liveBlendOutput?.setSampleBufferDelegate(nil, queue: nil)
                controller.requestStop(discard: true)
                DispatchQueue.main.async { self.isLiveBlendRunning = false }
            }
            if self.session.isRunning {
                LLog("stopRunning()")
                self.session.stopRunning()
            }
        }
    }

    /// Resume the session after an interruption ends or the app returns to the
    /// foreground, as long as the capture screen still wants it running.
    private func resumeIfNeeded(_ trigger: String) {
        sessionQueue.async {
            guard self.shouldBeRunning, self.isConfigured, !self.session.isRunning else { return }
            LLog("resume(\(trigger)): startRunning()")
            self.session.startRunning()
            LLog("resume(\(trigger)): isRunning=\(self.session.isRunning)")
        }
    }

    #if os(iOS)
    /// Temporary: log the session's own lifecycle so we can see interruptions
    /// and runtime errors (the source of the -17281/-12784 Fig asserts) with
    /// their reasons and timing. Registered once.
    private var sessionLoggingInstalled = false
    private func installSessionLogging() {
        guard !sessionLoggingInstalled else { return }
        sessionLoggingInstalled = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            LLog("‼️ RuntimeError code=\(err?.code ?? 0) \(err?.localizedDescription ?? "")")
            // Media services reset etc. — try to bring the session back.
            self?.resumeIfNeeded("runtimeError")
        }
        nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { note in
            let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
            LLog("⏸️ Interrupted reason=\(raw) (\(Self.interruptionReasonName(raw)))")
        }
        nc.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] _ in
            LLog("▶️ InterruptionEnded")
            self?.resumeIfNeeded("interruptionEnded")
        }
        nc.addObserver(forName: .AVCaptureSessionDidStartRunning, object: session, queue: nil) { _ in
            LLog("✅ DidStartRunning")
        }
        nc.addObserver(forName: .AVCaptureSessionDidStopRunning, object: session, queue: nil) { _ in
            LLog("🛑 DidStopRunning")
        }
        // Belt and suspenders: some background interruptions don't post
        // InterruptionEnded, so also resume when the app becomes active.
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            LLog("app didBecomeActive")
            self?.resumeIfNeeded("didBecomeActive")
        }
    }

    private static func interruptionReasonName(_ raw: Int) -> String {
        switch AVCaptureSession.InterruptionReason(rawValue: raw) {
        case .videoDeviceNotAvailableInBackground: return "notAvailableInBackground"
        case .audioDeviceInUseByAnotherClient: return "audioInUse"
        case .videoDeviceInUseByAnotherClient: return "videoInUse"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "multipleForegroundApps"
        case .videoDeviceNotAvailableDueToSystemPressure: return "systemPressure"
        default: return "other"
        }
    }
    #else
    private func installSessionLogging() {}
    #endif

    private var isConfigured = false

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        LLog("configureIfNeeded: begin")
        isConfigured = true
        session.beginConfiguration()
        session.sessionPreset = .high
        publishAvailableLenses()
        configureLens(selectedLens)
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()
        refreshCaptureOptions()
        applyVideoStabilization()
        publishFormat()
        publishLiveBlendDNGSupport()
        LLog("configureIfNeeded: done, inputs=\(session.inputs.count) outputs=\(session.outputs.count)")
    }

    /// Bayer RAW formats offered by the photo output *in its current
    /// configuration*, queried live on iOS. macOS has no RAW photo capture
    /// API at all (AVCapturePhotoSettings(rawPixelFormatType:) is marked
    /// unavailable), so the Mac is always empty by construction.
    private func availableBayerRawFormats() -> [OSType] {
        #if os(iOS)
        return photoOutput.availableRawPhotoPixelFormatTypes
            .filter { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        #else
        return []
        #endif
    }

    #if os(iOS)
    /// Per-device probe results, sessionQueue-confined: RAW support plus the
    /// photo configuration's sensor frame (what a DNG capture delivers).
    private var bayerRAWProbeByDevice: [String: (supported: Bool, sensor: CaptureResolution?)] = [:]
    #endif

    private func deviceSupportsBayerRAW() -> Bool {
        probeBayerRAW().supported
    }

    /// Whether the current camera can capture Bayer RAW at all, and at what
    /// sensor frame. The video-recording formats LetsLapse pins for fps
    /// control never offer RAW — the list is only populated in a photo
    /// configuration — so this probes `.photo` once per device and restores
    /// the pinned format. (Reading the list in the video configuration was
    /// the bug that made an iPhone 16 Pro report "no RAW" and silently fall
    /// back to JPEG.)
    private func probeBayerRAW() -> (supported: Bool, sensor: CaptureResolution?) {
        #if os(iOS)
        guard let device = videoDevice else { return (false, nil) }
        if let cached = bayerRAWProbeByDevice[device.uniqueID] { return cached }
        let previousPreset = session.sessionPreset
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.commitConfiguration()
        let supported = !availableBayerRawFormats().isEmpty
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let sensor = supported ? CaptureResolution(width: dims.width, height: dims.height) : nil
        // Cache before restoring: the restore re-pins the format, which
        // republishes support and would otherwise probe again forever.
        bayerRAWProbeByDevice[device.uniqueID] = (supported, sensor)
        session.beginConfiguration()
        session.sessionPreset = previousPreset
        session.commitConfiguration()
        // While the photo-aspect preview is armed, the session must stay in
        // the photo configuration — re-pinning the video format here would
        // snap the viewfinder back to 16:9.
        if photoAspectPreviousPreset == nil {
            applyCaptureFormat(resolution: selectedResolution, fps: selectedFrameRate)
        }
        LLog("liveblend-dng: probe \(device.localizedName) bayerRAW=\(supported) sensor=\(dims.width)x\(dims.height)")
        return (supported, sensor)
        #else
        return (false, nil)
        #endif
    }

    private func publishLiveBlendDNGSupport() {
        let probe = probeBayerRAW()
        let support: LiveBlendDNGSupport
        if probe.supported {
            support = LiveBlendDNGSupport(
                isSupported: true, reason: nil, sensorDimensions: probe.sensor)
        } else {
            #if os(macOS)
            support = LiveBlendDNGSupport(
                isSupported: false,
                reason: "Webcams deliver processed video, not RAW sensor data.")
            #else
            support = LiveBlendDNGSupport(
                isSupported: false,
                reason: "This camera does not provide RAW sensor data.")
            #endif
        }
        DispatchQueue.main.async {
            if self.liveBlendDNGSupport != support {
                self.liveBlendDNGSupport = support
            }
        }
    }

    /// Custom rate last folded into the rate menus, so a Settings change made
    /// while the capture screen was away is picked up on the next start().
    private var lastAppliedCustomFrameRate = RecordingSettingsStore.customFrameRate

    /// Settings owns Record audio and the custom frame rate; the capture
    /// screen re-checks both on every start() since they can change while it
    /// is away. Runs on the sessionQueue.
    private func reconcileSettingsDrivenState() {
        reconcileAudioInput()
        let custom = RecordingSettingsStore.customFrameRate
        guard custom != lastAppliedCustomFrameRate else { return }
        lastAppliedCustomFrameRate = custom
        guard !movieOutput.isRecording, intervalTimer == nil else { return }
        refreshCaptureOptions(preferredFrameRate: selectedFrameRate)
        publishFormat()
    }

    /// Add or remove the microphone to match the Record audio setting. The
    /// permission prompt happens when the toggle is turned on in Settings;
    /// here the mic is only attached when access is already granted, so in
    /// every other case shoots stay silent and playing music uninterrupted.
    private func reconcileAudioInput() {
        guard !movieOutput.isRecording else { return }
        let wantsAudio = RecordingSettingsStore.isAudioEnabled
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if wantsAudio, audioInput == nil {
            guard let device = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            if session.canAddInput(input) {
                session.addInput(input)
                audioInput = input
            }
            session.commitConfiguration()
        } else if !wantsAudio, let input = audioInput {
            session.beginConfiguration()
            session.removeInput(input)
            session.commitConfiguration()
            audioInput = nil
        }
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
            guard !self.movieOutput.isRecording, self.intervalTimer == nil, !self.isLiveBlendActive else { return }
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
            RecordingSettingsStore.save(lens: selected)
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
            guard !self.movieOutput.isRecording, self.intervalTimer == nil, !self.isLiveBlendActive else { return }
            self.refreshCaptureOptions(preferredResolution: resolution)
            self.publishFormat()
        }
    }

    func setVideoStabilizationEnabled(_ isEnabled: Bool) {
        DispatchQueue.main.async {
            self.isVideoStabilizationEnabled = isEnabled
        }
        sessionQueue.async {
            guard !self.movieOutput.isRecording, self.intervalTimer == nil, !self.isLiveBlendActive else { return }
            self.videoStabilizationRequested = isEnabled
            RecordingSettingsStore.save(stabilization: isEnabled)
            self.refreshCaptureOptions()
            self.applyVideoStabilization()
            self.publishFormat()
        }
    }

    func selectFrameRate(_ fps: Int) {
        sessionQueue.async {
            guard !self.movieOutput.isRecording, self.intervalTimer == nil, !self.isLiveBlendActive else { return }
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
        RecordingSettingsStore.save(
            resolution: resolution,
            frameRate: frameRate,
            rampFrameRate: rampFrameRate
        )
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
        var candidateFrameRates = preferredFrameRates
        if let custom = RecordingSettingsStore.customFrameRate,
           !candidateFrameRates.contains(custom) {
            candidateFrameRates.append(custom)
        }
        for format in device.formats {
            #if os(iOS)
            guard !videoStabilizationRequested || stabilizationMode(for: format) != nil else {
                continue
            }
            #endif
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width >= 640, dims.height >= 480 else { continue }
            let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            // ProRes codec subtypes (FourCC): 'apcn' 422, 'apch' 422 HQ,
            // 'apcs' 422 LT, 'apco' 422 Proxy, 'ap4h' 4444, 'ap4x' 4444 XQ.
            let proResFourCCs: Set<FourCharCode> = [
                0x6170636e, 0x61706368, 0x61706373, 0x6170636f, 0x61703468, 0x61703478,
            ]
            let resolution = CaptureResolution(
                width: dims.width,
                height: dims.height,
                isProRes: proResFourCCs.contains(subType)
            )
            let rates = supportedFrameRates(for: format, candidates: candidateFrameRates)
            guard !rates.isEmpty else { continue }
            supportedRates[resolution, default: []].formUnion(rates)
        }
        return supportedRates
    }

    private func supportedFrameRates(
        for format: AVCaptureDevice.Format,
        candidates: [Int]
    ) -> Set<Int> {
        var rates = Set<Int>()
        for range in format.videoSupportedFrameRateRanges {
            for fps in candidates
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
            guard !self.movieOutput.isRecording, self.intervalTimer == nil, !self.isLiveBlendActive else { return }
            let frameRate = self.availableFrameRates.contains(fps)
                ? fps
                : self.nearestRampFrameRate(from: self.selectedFrameRate, in: self.availableFrameRates)
            RecordingSettingsStore.save(rampFrameRate: frameRate)
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
            reassertExposureLock(on: device)
            publishLiveBlendDNGSupport()
            return true
        } catch {
            return false
        }
    }

    /// Setting `activeFormat` resets the device to auto exposure/focus, so any
    /// manual lock must be re-applied immediately — otherwise every burst/ramp
    /// segment would flicker back to auto. Runs inside the caller's
    /// `lockForConfiguration` block on the sessionQueue.
    private func reassertExposureLock(on device: AVCaptureDevice) {
        guard exposureLocked else { return }
        #if os(iOS)
        let format = device.activeFormat
        let iso = min(max(lockedISOValue, format.minISO), format.maxISO)
        // Also clamp to the frame interval: a shutter longer than the frame
        // duration drags the delivered rate below the requested fps (e.g. a
        // 1/10 s lock from a 10 fps shoot carried into a 30 fps format).
        var maxExposureSeconds = format.maxExposureDuration.seconds
        let frameDuration = device.activeVideoMaxFrameDuration
        if frameDuration.isValid, frameDuration.seconds > 0 {
            maxExposureSeconds = min(maxExposureSeconds, frameDuration.seconds)
        }
        let seconds = min(
            max(lockedShutterValue, format.minExposureDuration.seconds),
            maxExposureSeconds
        )
        let duration = CMTimeMakeWithSeconds(seconds, preferredTimescale: 1_000_000)
        if device.isExposureModeSupported(.custom) {
            device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
        }
        if device.isFocusModeSupported(.locked) {
            device.setFocusModeLocked(lensPosition: lockedLensValue, completionHandler: nil)
        }
        #else
        if device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
        }
        if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
        }
        #endif
        if device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
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

    /// Point the movie and photo output connections at `orientation` so
    /// recordings and stills are written the right way up. Driven from the
    /// preview's `updateUIView`, which fires in step with every SwiftUI
    /// rotation, so it never depends on device-motion notifications.
    func setVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        LLog("setVideoOrientation(\(orientation.rawValue)) [outputs+stabilization]")
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
    /// The orientation to bake into recordings/stills right now: the
    /// interface/device-derived orientation, plus the manual upside-down flip.
    private func captureOrientation() -> AVCaptureVideoOrientation {
        let base = currentCaptureOrientation()
        return flipOrientation180 ? flipped180(base) : base
    }
    #endif

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

    // MARK: - Manual exposure & focus

    /// Freeze exposure, focus and white balance at their current auto values.
    func lockExposureAndFocus() {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                #if os(iOS)
                let format = device.activeFormat
                let iso = min(max(device.iso, format.minISO), format.maxISO)
                let duration = device.exposureDuration
                let lens = device.lensPosition
                if device.isExposureModeSupported(.custom) {
                    device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
                }
                #else
                if device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                }
                #endif
                if device.isFocusModeSupported(.locked) {
                    device.focusMode = .locked
                }
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.whiteBalanceMode = .locked
                }
                self.exposureLocked = true
                #if os(iOS)
                self.lockedISOValue = iso
                self.lockedShutterValue = duration.seconds
                self.lockedLensValue = lens
                let minISO = format.minISO
                let maxISO = format.maxISO
                DispatchQueue.main.async {
                    self.isExposureLocked = true
                    self.lockedISO = iso
                    self.lockedShutterSeconds = duration.seconds
                    self.lockedLensPosition = lens
                    self.isoRange = minISO...maxISO
                }
                #else
                DispatchQueue.main.async {
                    self.isExposureLocked = true
                }
                #endif
            } catch {}
        }
    }

    /// Return exposure, focus and white balance to their continuous-auto modes.
    func unlockExposureAndFocus() {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                self.exposureLocked = false
                DispatchQueue.main.async {
                    self.isExposureLocked = false
                }
            } catch {}
        }
    }

    /// Adjust ISO while holding the current shutter, keeping the lock asserted.
    func setISO(_ iso: Float) {
        #if os(iOS)
        sessionQueue.async {
            guard let device = self.videoDevice,
                  device.isExposureModeSupported(.custom) else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let format = device.activeFormat
                let clamped = min(max(iso, format.minISO), format.maxISO)
                let duration = device.exposureDuration
                device.setExposureModeCustom(duration: duration, iso: clamped, completionHandler: nil)
                self.exposureLocked = true
                self.lockedISOValue = clamped
                self.lockedShutterValue = duration.seconds
                DispatchQueue.main.async {
                    self.isExposureLocked = true
                    self.lockedISO = clamped
                    self.lockedShutterSeconds = duration.seconds
                }
            } catch {}
        }
        #else
        _ = iso
        #endif
    }

    /// Lock focus at an explicit lens position (0 = near, 1 = far).
    func setLensPosition(_ position: Float) {
        #if os(iOS)
        sessionQueue.async {
            guard let device = self.videoDevice,
                  device.isFocusModeSupported(.locked) else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let clamped = min(max(position, 0), 1)
                device.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
                self.lockedLensValue = clamped
                DispatchQueue.main.async {
                    self.lockedLensPosition = clamped
                }
            } catch {}
        }
        #else
        _ = position
        #endif
    }

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
                self.rampSpans = []
            }
        }
    }

    func stopRecording() {
        cancelScheduledStop()
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
        let spans = (activeSequence?.rampIntervals ?? []).map {
            RampSpan(id: $0.index, start: $0.relativeStart, end: $0.relativeEnd)
        }
        DispatchQueue.main.async {
            self.isRampActive = isActive
            self.isRampHighRate = isActive
            self.rampIntervalCount = intervalCount
            self.markerCount = intervalCount
            self.rampSpans = spans
        }
    }

    private func startNextSegment(frameRate: Int) {
        guard let directory = activeSequenceDirectory else { return }
        _ = applyCaptureFormat(resolution: selectedResolution, fps: frameRate)
        #if os(iOS)
        // A new segment reuses the movie output connection; re-assert the
        // orientation so a fresh connection never records the wrong way up.
        if let connection = movieOutput.connection(with: .video),
           connection.isVideoOrientationSupported {
            connection.videoOrientation = captureOrientation()
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
            self.rampSpans = []
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
                    connection.videoOrientation = self.captureOrientation()
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
        cancelScheduledStop()
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

    // MARK: - Scheduled stop (Watch "stop at…")

    /// Schedules a stop of whatever capture is running: after `amount`
    /// minutes, or after `amount` more frames (photos/blends in Interval;
    /// fps-derived time in Video). Replaces any earlier schedule.
    func scheduleStop(unit: ScheduledStopUnit, amount: Double) {
        DispatchQueue.main.async {
            guard amount > 0 else { return }
            guard self.isRecording || self.isIntervalRunning || self.isLiveBlendRunning else { return }
            self.scheduledStopWorkItem?.cancel()
            self.scheduledStopWorkItem = nil

            let stop: ScheduledStop
            switch unit {
            case .minutes:
                stop = ScheduledStop(
                    unit: .minutes,
                    deadline: Date().addingTimeInterval(amount * 60),
                    targetCount: nil)
            case .frames:
                if self.isRecording {
                    let fps = Double(max(1, self.selectedFrameRate))
                    stop = ScheduledStop(
                        unit: .frames,
                        deadline: Date().addingTimeInterval(amount / fps),
                        targetCount: nil)
                } else {
                    let current = self.isLiveBlendRunning ? self.liveBlendOutputCount : self.photoCount
                    stop = ScheduledStop(unit: .frames, deadline: nil, targetCount: current + Int(amount))
                }
            }
            self.scheduledStop = stop
            if let deadline = stop.deadline {
                let workItem = DispatchWorkItem { [weak self] in self?.performScheduledStop() }
                self.scheduledStopWorkItem = workItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + max(0, deadline.timeIntervalSinceNow),
                    execute: workItem)
            }
            LLog("scheduled stop: \(unit.rawValue) \(amount)")
        }
    }

    func cancelScheduledStop() {
        DispatchQueue.main.async {
            self.scheduledStopWorkItem?.cancel()
            self.scheduledStopWorkItem = nil
            if self.scheduledStop != nil {
                self.scheduledStop = nil
                LLog("scheduled stop cancelled")
            }
        }
    }

    /// Main-queue only (didSet of the published counters).
    private func checkScheduledStopCount() {
        guard let stop = scheduledStop, let target = stop.targetCount else { return }
        let current = isLiveBlendRunning ? liveBlendOutputCount : photoCount
        guard current >= target else { return }
        performScheduledStop()
    }

    /// Main-queue only.
    private func performScheduledStop() {
        guard scheduledStop != nil else { return }
        scheduledStopWorkItem?.cancel()
        scheduledStopWorkItem = nil
        scheduledStop = nil
        LLog("scheduled stop firing")
        if isRecording {
            stopRecording()
        } else if isIntervalRunning {
            stopInterval()
        } else if isLiveBlendRunning {
            // The user asked for an exact count/time; the window in progress
            // is beyond it, so it is dropped rather than kept as a partial.
            stopLiveBlend(keepPartial: false)
        }
    }

    // MARK: - Live Blend engine (Interval's blend/DNG pipeline)

    /// Starts a Live Blend run: every `interval` seconds, `framesPerBlend`
    /// frames are averaged into one output image. With `preferDNG` and a
    /// Bayer-RAW-capable source, frames come from RAW photo captures and the
    /// output is a blended DNG; otherwise the processed video stream is
    /// tapped and the output is JPEG. The run hands its outputs over through
    /// `onFinishLiveBlend` exactly like interval capture hands over
    /// `onFinishPhotos`.
    func startLiveBlend(every interval: Double, framesPerBlend: Int, preferDNG: Bool = false, options: LiveBlendCaptureOptions = LiveBlendCaptureOptions()) {
        sessionQueue.async {
            guard !self.movieOutput.isRecording, self.intervalTimer == nil, !self.isLiveBlendActive else { return }

            #if os(iOS)
            if preferDNG, self.deviceSupportsBayerRAW() {
                self.startLiveBlendDNG(every: interval, framesPerBlend: framesPerBlend, options: options)
                return
            }
            #endif
            if preferDNG {
                LLog("liveblend: DNG requested but unsupported on this source — standard output")
            }
            self.startLiveBlendStandard(
                every: interval,
                framesPerBlend: framesPerBlend,
                requestedOutputFormat: preferDNG ? "dng" : "standard")
        }
    }

    /// sessionQueue-confined: the video-tap JPEG path.
    private func startLiveBlendStandard(every interval: Double, framesPerBlend: Int, requestedOutputFormat: String) {
            if self.liveBlendOutput == nil {
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                ]
                output.alwaysDiscardsLateVideoFrames = true
                self.session.beginConfiguration()
                if self.session.canAddOutput(output) {
                    self.session.addOutput(output)
                    self.liveBlendOutput = output
                }
                self.session.commitConfiguration()
            }
            guard let output = self.liveBlendOutput else {
                LLog("liveblend: session refused the video data output")
                self.publishLiveBlendStartFailure(interval: interval, framesPerBlend: framesPerBlend)
                return
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("liveblend-\(Int(Date().timeIntervalSince1970))")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                LLog("liveblend: could not create temp directory: \(error)")
                self.publishLiveBlendStartFailure(interval: interval, framesPerBlend: framesPerBlend)
                return
            }

            let dimensions = self.videoDevice.map {
                CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription)
            }
            let configuration = LiveBlendController.Configuration(
                intervalSeconds: interval,
                framesPerBlend: framesPerBlend,
                outputDirectory: directory,
                logURL: Self.liveBlendLogURL(),
                cameraName: self.videoDevice?.localizedName ?? "unknown camera",
                captureWidth: Int(dimensions?.width ?? 0),
                captureHeight: Int(dimensions?.height ?? 0),
                configuredFrameRate: self.selectedFrameRate,
                requestedOutputFormat: requestedOutputFormat)

            let controller: LiveBlendController
            do {
                controller = try LiveBlendController(configuration: configuration)
            } catch {
                LLog("liveblend: controller init failed: \(error)")
                self.publishLiveBlendStartFailure(interval: interval, framesPerBlend: framesPerBlend)
                return
            }
            controller.onDiagnostics = { [weak self] snapshot in
                guard let self else { return }
                if self.liveBlendDiagnostics != snapshot { self.liveBlendDiagnostics = snapshot }
                if self.liveBlendOutputCount != snapshot.outputCount {
                    self.liveBlendOutputCount = snapshot.outputCount
                }
            }
            controller.onFinished = { [weak self] result in
                guard let self else { return }
                self.isLiveBlendRunning = false
                self.sessionQueue.async {
                    self.liveBlendOutput?.setSampleBufferDelegate(nil, queue: nil)
                }
                if let result {
                    self.onFinishLiveBlend?(result)
                }
            }

            self.liveBlendController = controller
            #if os(iOS)
            // Lock the stream orientation for the whole run, the same way the
            // interval tick orients each photo. Buffers must keep one size and
            // orientation per run; rotating the device mid-run keeps the
            // locked framing rather than resizing frames under the blender.
            if let connection = output.connection(with: .video),
               connection.isVideoOrientationSupported {
                connection.videoOrientation = self.captureOrientation()
            }
            #endif
            output.setSampleBufferDelegate(controller, queue: controller.videoQueue)
            controller.start()
            DispatchQueue.main.async {
                self.isLiveBlendRunning = true
                self.liveBlendOutputCount = 0
                self.liveBlendDiagnostics = LiveBlendDiagnosticsSnapshot(
                    requestedIntervalSeconds: interval,
                    requestedFramesPerBlend: framesPerBlend)
            }
    }

    #if os(iOS)
    /// The pinned preset to restore once a DNG run ends. sessionQueue-confined.
    private var dngRunPreviousPreset: AVCaptureSession.Preset?
    /// Fast-capture output state to restore after a DNG run (zero shutter
    /// lag, responsive capture, fast prioritization). sessionQueue-confined.
    private var dngRunPreviousFastCapture: (zsl: Bool, responsive: Bool, fast: Bool)?

    /// sessionQueue-confined DNG variant of `startLiveBlend`: switches the
    /// session to a RAW-capable photo configuration for the run (restored on
    /// finish), then RAW photo captures feed a linear-space average — one
    /// blended DNG per interval.
    private func startLiveBlendDNG(every interval: Double, framesPerBlend: Int, options: LiveBlendCaptureOptions) {
        let previousPreset = session.sessionPreset
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.commitConfiguration()
        guard let rawFormat = availableBayerRawFormats().first else {
            session.beginConfiguration()
            session.sessionPreset = previousPreset
            session.commitConfiguration()
            applyCaptureFormat(resolution: selectedResolution, fps: selectedFrameRate)
            LLog("liveblend-dng: photo configuration offers no Bayer RAW — standard output")
            startLiveBlendStandard(every: interval, framesPerBlend: framesPerBlend, requestedOutputFormat: "dng")
            return
        }
        dngRunPreviousPreset = previousPreset
        if let dimensions = videoDevice?.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = dimensions
        }

        // Fast-capture experiment: the responsive pipeline (zero shutter
        // lag + overlapped capture/processing) is what the system camera
        // uses for rapid shot-to-shot. Enable order matters (ZSL before
        // responsive before fast prioritization); the restore runs it in
        // reverse. Skipped when brackets are requested — the two rapid-fire
        // mechanisms aren't combined.
        var responsiveApplied = false
        if #available(iOS 17.0, *), options.responsiveCapture, !options.bracketedRAW {
            dngRunPreviousFastCapture = (
                zsl: photoOutput.isZeroShutterLagEnabled,
                responsive: photoOutput.isResponsiveCaptureEnabled,
                fast: photoOutput.isFastCapturePrioritizationEnabled)
            session.beginConfiguration()
            if photoOutput.isZeroShutterLagSupported {
                photoOutput.isZeroShutterLagEnabled = true
            }
            if photoOutput.isResponsiveCaptureSupported {
                photoOutput.isResponsiveCaptureEnabled = true
                responsiveApplied = true
            }
            if photoOutput.isFastCapturePrioritizationSupported {
                photoOutput.isFastCapturePrioritizationEnabled = true
            }
            session.commitConfiguration()
        }
        let bracketMax = Int(photoOutput.maxBracketedCapturePhotoCount)
        LLog("liveblend-dng: capture options responsive=\(responsiveApplied) burst=\(options.burstScheduling) bracketed=\(options.bracketedRAW) bracketMax=\(bracketMax)")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("liveblend-dng-\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            LLog("liveblend-dng: could not create temp directory: \(error)")
            publishLiveBlendStartFailure(interval: interval, framesPerBlend: framesPerBlend)
            return
        }
        let dimensions = videoDevice.map {
            CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription)
        }
        let configuration = LiveBlendRawController.Configuration(
            intervalSeconds: interval,
            framesPerBlend: framesPerBlend,
            outputDirectory: directory,
            logURL: Self.liveBlendLogURL(),
            cameraName: videoDevice?.localizedName ?? "unknown camera",
            captureWidth: Int(dimensions?.width ?? 0),
            captureHeight: Int(dimensions?.height ?? 0),
            configuredFrameRate: selectedFrameRate,
            rawPixelFormat: rawFormat,
            burstScheduling: options.burstScheduling,
            bracketedRAW: options.bracketedRAW,
            responsiveCapture: responsiveApplied,
            maxBracketFrames: bracketMax)
        let controller = LiveBlendRawController(
            configuration: configuration,
            photoOutput: photoOutput,
            captureExecutor: { [weak self] block in self?.sessionQueue.async(execute: block) })
        controller.onDiagnostics = { [weak self] snapshot in
            guard let self else { return }
            if self.liveBlendDiagnostics != snapshot { self.liveBlendDiagnostics = snapshot }
            if self.liveBlendOutputCount != snapshot.outputCount {
                self.liveBlendOutputCount = snapshot.outputCount
            }
        }
        controller.onFinished = { [weak self] result in
            guard let self else { return }
            self.isLiveBlendRunning = false
            self.sessionQueue.async { self.restoreAfterDNGRun() }
            if let result {
                self.onFinishLiveBlend?(result)
            }
        }
        liveBlendRawController = controller
        controller.start()
        DispatchQueue.main.async {
            self.isLiveBlendRunning = true
            self.liveBlendOutputCount = 0
            var snapshot = LiveBlendDiagnosticsSnapshot(
                requestedIntervalSeconds: interval,
                requestedFramesPerBlend: framesPerBlend)
            snapshot.outputFormatLabel = "DNG"
            self.liveBlendDiagnostics = snapshot
        }
    }

    /// sessionQueue-confined: undo the photo-configuration switch after a
    /// DNG run so preview and the other modes get their pinned format back.
    private func restoreAfterDNGRun() {
        guard let previousPreset = dngRunPreviousPreset else { return }
        dngRunPreviousPreset = nil
        if #available(iOS 17.0, *), let previous = dngRunPreviousFastCapture {
            dngRunPreviousFastCapture = nil
            session.beginConfiguration()
            // Reverse of the enable order: fast prioritization depends on
            // responsive capture, which depends on zero shutter lag.
            if photoOutput.isFastCapturePrioritizationSupported {
                photoOutput.isFastCapturePrioritizationEnabled = previous.fast
            }
            if photoOutput.isResponsiveCaptureSupported {
                photoOutput.isResponsiveCaptureEnabled = previous.responsive
            }
            if photoOutput.isZeroShutterLagSupported {
                photoOutput.isZeroShutterLagEnabled = previous.zsl
            }
            session.commitConfiguration()
        }
        session.beginConfiguration()
        session.sessionPreset = previousPreset
        session.commitConfiguration()
        applyCaptureFormat(resolution: selectedResolution, fps: selectedFrameRate)
        publishFormat()
    }
    #endif

    /// Graceful stop: the partial window is kept when it has frames (unless
    /// `keepPartial` is false — a scheduled "stop at N" wants exactly N),
    /// then the finish handler fires with everything completed so far.
    func stopLiveBlend(keepPartial: Bool = true) {
        cancelScheduledStop()
        sessionQueue.async {
            #if os(iOS)
            if let rawController = self.liveBlendRawController, rawController.isActive {
                rawController.requestStop(discard: false, keepPartial: keepPartial)
                return
            }
            #endif
            guard let controller = self.liveBlendController, controller.isActive else { return }
            self.liveBlendOutput?.setSampleBufferDelegate(nil, queue: nil)
            controller.requestStop(discard: false, keepPartial: keepPartial)
        }
    }

    private func publishLiveBlendStartFailure(interval: Double, framesPerBlend: Int) {
        DispatchQueue.main.async {
            var snapshot = LiveBlendDiagnosticsSnapshot(
                requestedIntervalSeconds: interval,
                requestedFramesPerBlend: framesPerBlend)
            snapshot.status = .captureFailed
            self.liveBlendDiagnostics = snapshot
        }
    }

    /// One log file per run in Application Support/LetsLapse/Logs — outside
    /// the project so experiment data survives discarded captures.
    private static func liveBlendLogURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let logsDirectory = base
            .appendingPathComponent("LetsLapse", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        return logsDirectory.appendingPathComponent("liveblend-\(formatter.string(from: Date())).json")
    }
}

#if os(iOS)
func currentCaptureOrientation() -> AVCaptureVideoOrientation {
    let interface = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }?
        .interfaceOrientation ?? .portrait
    return effectiveCaptureOrientation(interface: interface)
}

/// Map an interface orientation to a capture orientation. Straight case-for-case
/// (UIInterfaceOrientation and AVCaptureVideoOrientation share raw values for the
/// same physical orientation). Upside-down mounting is handled by the manual
/// Flip 180° control, not by sniffing the physical device orientation — iPhones
/// never expose an upside-down interface, so that path was unreliable.
func effectiveCaptureOrientation(interface: UIInterfaceOrientation) -> AVCaptureVideoOrientation {
    switch interface {
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

/// Rotate an orientation 180° — the manual upside-down-mount flip.
func flipped180(_ orientation: AVCaptureVideoOrientation) -> AVCaptureVideoOrientation {
    switch orientation {
    case .portrait: return .portraitUpsideDown
    case .portraitUpsideDown: return .portrait
    case .landscapeLeft: return .landscapeRight
    case .landscapeRight: return .landscapeLeft
    @unknown default: return orientation
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

// MARK: - Remembered recording settings

/// The last-used capture setup — mode (Video/Interval) plus each mode's
/// dials (lens, resolution, frame rate, stabilization, burst rate, interval
/// spacing, blend frames) — persisted so the next shoot starts where the
/// previous one left off. Gated by the "Remember recording settings"
/// toggle in Settings.
/// UserDefaults is thread-safe, so saves may run on the session queue.
enum RecordingSettingsStore {
    static let isEnabledKey = "letslapse.rememberRecordingSettings"

    private static let modeKey = "letslapse.capture.mode"
    private static let lensKey = "letslapse.capture.lens"
    private static let resolutionWidthKey = "letslapse.capture.resolutionWidth"
    private static let resolutionHeightKey = "letslapse.capture.resolutionHeight"
    private static let frameRateKey = "letslapse.capture.frameRate"
    private static let rampFrameRateKey = "letslapse.capture.rampFrameRate"
    private static let stabilizationKey = "letslapse.capture.stabilization"
    private static let intervalSecondsKey = "letslapse.capture.intervalSeconds"
    /// Pre-merge key from when Live Blend was its own mode with its own
    /// spacing; read as a fallback so an upgrade keeps the user's spacing,
    /// never written anymore.
    private static let liveBlendIntervalSecondsKey = "letslapse.capture.liveBlendIntervalSeconds"
    private static let liveBlendFramesPerBlendKey = "letslapse.capture.liveBlendFramesPerBlend"

    // Settings-owned values, not part of the remembered-shoot snapshot: they
    // apply regardless of `isEnabled` and survive `clear()`.
    private static let customFrameRateKey = "letslapse.capture.customFrameRate"
    private static let recordAudioKey = "letslapse.capture.recordAudio"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: isEnabledKey) as? Bool ?? true
    }

    static var customFrameRate: Int? {
        let value = UserDefaults.standard.integer(forKey: customFrameRateKey)
        return (1...240).contains(value) ? value : nil
    }

    static func save(customFrameRate: Int?) {
        if let customFrameRate, (1...240).contains(customFrameRate) {
            UserDefaults.standard.set(customFrameRate, forKey: customFrameRateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: customFrameRateKey)
        }
    }

    static var isAudioEnabled: Bool {
        UserDefaults.standard.bool(forKey: recordAudioKey)
    }

    static func save(isAudioEnabled: Bool) {
        UserDefaults.standard.set(isAudioEnabled, forKey: recordAudioKey)
    }

    static var captureMode: CaptureMode? {
        // token-tolerant: a remembered "Live Blend" from before the mode
        // merge resolves to Interval.
        UserDefaults.standard.string(forKey: modeKey)
            .flatMap(CaptureMode.init(token:))
    }

    static func save(captureMode: CaptureMode) {
        guard isEnabled else { return }
        UserDefaults.standard.set(captureMode.rawValue, forKey: modeKey)
    }

    /// Video has no interval spacing; asking for it returns nil and saving
    /// it is a no-op. Interval falls back to the retired Live Blend mode's
    /// spacing so an upgrade keeps a habitual Live Blend shooter's setup.
    static func intervalSeconds(for mode: CaptureMode) -> Double? {
        guard let key = intervalKey(for: mode) else { return nil }
        let stored = UserDefaults.standard.object(forKey: key) as? Double
            ?? UserDefaults.standard.object(forKey: liveBlendIntervalSecondsKey) as? Double
        guard let value = stored, (0.1...3600).contains(value) else { return nil }
        return value
    }

    static func save(intervalSeconds: Double, for mode: CaptureMode) {
        guard isEnabled, let key = intervalKey(for: mode) else { return }
        UserDefaults.standard.set(intervalSeconds, forKey: key)
    }

    private static func intervalKey(for mode: CaptureMode) -> String? {
        switch mode {
        case .video: return nil
        case .interval: return intervalSecondsKey
        }
    }

    static var framesPerBlend: Int? {
        let value = UserDefaults.standard.integer(forKey: liveBlendFramesPerBlendKey)
        return (1...60).contains(value) ? value : nil
    }

    static func save(framesPerBlend: Int) {
        guard isEnabled else { return }
        UserDefaults.standard.set(framesPerBlend, forKey: liveBlendFramesPerBlendKey)
    }

    static var lens: CameraController.Lens? {
        UserDefaults.standard.string(forKey: lensKey)
            .flatMap(CameraController.Lens.init(rawValue:))
    }

    static var resolution: CameraController.CaptureResolution? {
        guard let width = UserDefaults.standard.object(forKey: resolutionWidthKey) as? Int,
              let height = UserDefaults.standard.object(forKey: resolutionHeightKey) as? Int,
              width > 0, height > 0
        else { return nil }
        return CameraController.CaptureResolution(width: Int32(width), height: Int32(height))
    }

    static var frameRate: Int? {
        UserDefaults.standard.object(forKey: frameRateKey) as? Int
    }

    static var rampFrameRate: Int? {
        UserDefaults.standard.object(forKey: rampFrameRateKey) as? Int
    }

    static var stabilization: Bool? {
        UserDefaults.standard.object(forKey: stabilizationKey) as? Bool
    }

    static func save(
        lens: CameraController.Lens? = nil,
        resolution: CameraController.CaptureResolution? = nil,
        frameRate: Int? = nil,
        rampFrameRate: Int? = nil,
        stabilization: Bool? = nil
    ) {
        guard isEnabled else { return }
        let defaults = UserDefaults.standard
        if let lens { defaults.set(lens.rawValue, forKey: lensKey) }
        if let resolution {
            defaults.set(Int(resolution.width), forKey: resolutionWidthKey)
            defaults.set(Int(resolution.height), forKey: resolutionHeightKey)
        }
        if let frameRate { defaults.set(frameRate, forKey: frameRateKey) }
        if let rampFrameRate { defaults.set(rampFrameRate, forKey: rampFrameRateKey) }
        if let stabilization { defaults.set(stabilization, forKey: stabilizationKey) }
    }

    /// Drop the snapshot when the user turns the setting off, so re-enabling
    /// starts from the app defaults rather than a stale setup.
    static func clear() {
        let defaults = UserDefaults.standard
        for key in [
            modeKey, lensKey, resolutionWidthKey, resolutionHeightKey,
            frameRateKey, rampFrameRateKey, stabilizationKey,
            intervalSecondsKey, liveBlendIntervalSecondsKey, liveBlendFramesPerBlendKey,
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}
