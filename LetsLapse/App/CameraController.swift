import Foundation
import AVFoundation
import CoreLocation
import ImageIO
import LetsLapseKit
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
    /// Legacy lens vocabulary. No longer the chip model — stops are derived
    /// from hardware at runtime (CaptureOptics.swift) — but kept for the
    /// manage-resolutions probe and the remembered-lens migration.
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

        /// The same frame in still-photo vocabulary: the video names
        /// ("4K", "1080p") belong to Video mode; stills state pixels.
        var stillLabel: String {
            "\(width)×\(height)"
        }

        /// "4:3" / "16:9" — the photographic ratios are matched with
        /// tolerance (sensors report a few extra readout pixels, 4224×3024),
        /// anything else reduces exactly.
        var aspectRatioLabel: String {
            let ratio = Double(width) / Double(max(height, 1))
            let common: [(label: String, value: Double)] = [
                ("4:3", 4.0 / 3.0), ("3:2", 1.5), ("16:9", 16.0 / 9.0), ("1:1", 1.0),
            ]
            if let match = common.first(where: { abs($0.value - ratio) < 0.02 }) {
                return match.label
            }
            func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
            let divisor = max(gcd(Int(width), Int(height)), 1)
            return "\(Int(width) / divisor):\(Int(height) / divisor)"
        }

        var pixelCount: Int64 {
            Int64(width) * Int64(height)
        }
    }

    /// A resolution the hardware offers, with the capability facts the
    /// manage-resolutions screen sections by. Probed straight from device
    /// format lists — no running session needed, so Settings can show the
    /// list without spinning up the camera.
    struct ResolutionCapability: Identifiable {
        var resolution: CaptureResolution
        var supportsStabilization: Bool
        var id: String { resolution.id }
    }

    /// Every resolution this device's cameras offer, mirroring the criteria
    /// `supportedFrameRatesByResolution` applies to the live format list
    /// (minimum frame, a usable frame rate) — minus its stabilization filter,
    /// which the manage screen presents as sections instead. Unioned across
    /// the back lenses so the list is the device's full vocabulary, not one
    /// lens's.
    static func resolutionCapabilities() -> [ResolutionCapability] {
        #if os(iOS)
        let devices = Lens.allCases.compactMap {
            AVCaptureDevice.default($0.deviceType, for: .video, position: .back)
        }
        #else
        let devices = AVCaptureDevice.default(for: .video).map { [$0] } ?? []
        #endif
        var candidates = preferredFrameRates
        if let custom = RecordingSettingsStore.customFrameRate, !candidates.contains(custom) {
            candidates.append(custom)
        }
        var byID: [String: ResolutionCapability] = [:]
        for device in devices {
            for format in device.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dims.width >= 640, dims.height >= 480 else { continue }
                guard !supportedFrameRates(for: format, candidates: candidates).isEmpty else { continue }
                let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                let resolution = CaptureResolution(
                    width: dims.width,
                    height: dims.height,
                    isProRes: proResFourCCs.contains(subType)
                )
                #if os(iOS)
                // Mirrors `stabilizationMode(for:)` — cinematic or standard.
                let stabilized = format.isVideoStabilizationModeSupported(.cinematic)
                    || format.isVideoStabilizationModeSupported(.standard)
                #else
                let stabilized = false
                #endif
                let existing = byID[resolution.id]
                byID[resolution.id] = ResolutionCapability(
                    resolution: resolution,
                    supportsStabilization: (existing?.supportsStabilization ?? false) || stabilized
                )
            }
        }
        return byID.values.sorted {
            if $0.resolution.pixelCount == $1.resolution.pixelCount {
                if $0.resolution.width == $1.resolution.width {
                    return !$0.resolution.isProRes && $1.resolution.isProRes
                }
                return $0.resolution.width > $1.resolution.width
            }
            return $0.resolution.pixelCount > $1.resolution.pixelCount
        }
    }

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.letslapse.capture")

    #if os(iOS)
    /// Last known capture orientation, cached so the capture queue can read it
    /// without touching `UIApplication`/`UIScene`/`UIDevice` — those are
    /// main-thread-only and crash when read from `sessionQueue` (e.g. the
    /// interval timer tick). Seeded by `setVideoOrientation` when the capture
    /// screen appears, then kept fresh on every rotation by the lightweight
    /// `updateCaptureOrientation`; lock-protected for cross-thread reads.
    private let orientationLock = NSLock()
    private var _latestCaptureOrientation: AVCaptureVideoOrientation = .portrait
    private var latestCaptureOrientation: AVCaptureVideoOrientation {
        get { orientationLock.lock(); defer { orientationLock.unlock() }; return _latestCaptureOrientation }
        set { orientationLock.lock(); _latestCaptureOrientation = newValue; orientationLock.unlock() }
    }

    /// Orientation locked at `startRecording` for every segment of the
    /// sequence — `stitchVideos` applies segment 0's transform to the whole
    /// composition, so segments must agree even if the device rotates mid-run.
    /// sessionQueue-confined.
    private var activeSequenceOrientation: AVCaptureVideoOrientation?
    #endif

    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var videoDevice: AVCaptureDevice?
    /// The device lens stops derive from and the standard world captures
    /// through: the virtual multi-cam where the hardware has one, else the
    /// plain wide/default device. Chosen once at configure. DNG work swaps
    /// the session input to a physical constituent (Bayer RAW is a
    /// physical-device capability — probe 2026-08-04), but stops keep
    /// deriving from this device. sessionQueue-confined.
    private var opticsDevice: AVCaptureDevice?
    /// Every stop the hardware yields, unfiltered. sessionQueue-confined.
    private var fullStops: [DerivedOpticsStop] = []
    /// The stop currently applied — sessionQueue-confined mirror of
    /// `selectedStop`. Format switches read it to re-assert zoom, because
    /// setting `activeFormat` resets `videoZoomFactor` to 1.
    private var currentStop: DerivedOpticsStop?
    /// Bayer RAW capability of the physical wide camera, probed once at
    /// configure before the optics input goes in. The virtual device always
    /// reports none, so this cache is what the DNG gate reads while the
    /// standard world is active. sessionQueue-confined.
    private var wideRAWProbe: (supported: Bool, sensor: CaptureResolution?) = (false, nil)
    /// Stop factor to restore once stops are derived (remembered settings).
    private var preferredStopFactor: Double?
    /// Last-applied "Enhanced lenses" setting, so reconcile re-derives when
    /// Settings changed it while the capture screen was away.
    private var lastEnhancedLensesEnabled = CaptureOpticsStore.enhancedLensesEnabled
    private var selectedPhotoDimensions: CMVideoDimensions?
    private var intervalTimer: DispatchSourceTimer?
    private var photoDirectory: URL?
    private var photoURLs: [URL] = []   // sessionQueue-confined
    // Photo-mode frame cap: stop after this many stills land. nil = an
    // open-ended Interval shoot. `intervalFramesRequested` counts capture
    // requests so the repeating timer stops scheduling once the burst is out
    // (photos land asynchronously, so requests, not writes, gate scheduling).
    // `intervalActive` guards the finish path so a cap-reached finish and a
    // user stop can't both emit. All three are sessionQueue-confined.
    private var intervalFrameCap: Int?
    private var intervalFramesRequested = 0
    private var intervalActive = false
    private var videoStabilizationRequested = true
    /// When set, captured media is geotagged: stills with the latest location
    /// fix, recorded movies with the fix the take started from.
    /// Set from the capture screen; read on the session queue as each file lands.
    var gpsTaggingEnabled = false
    // 10/12/15 are acquisition rates for the blend pipeline: sparse temporal
    // sampling with up to a full-interval shutter, meant to be conformed or
    // blended rather than played as-is.
    private static let preferredFrameRates = [10, 12, 15, 24, 25, 30, 50, 60, 100, 120, 240]
    private static let frameRateTolerance = 0.2
    /// ProRes codec subtypes (FourCC): 'apcn' 422, 'apch' 422 HQ,
    /// 'apcs' 422 LT, 'apco' 422 Proxy, 'ap4h' 4444, 'ap4x' 4444 XQ.
    private static let proResFourCCs: Set<FourCharCode> = [
        0x6170636e, 0x61706368, 0x61706373, 0x6170636f, 0x61703468, 0x61703478,
    ]
    private var activeSequence: LiveCaptureSequence?
    private var activeSequenceDirectory: URL?
    private var activeSequenceStartedAt: Date?
    private var activeSegmentStartedAt: Date?
    private var activeRecordingFrameRate: Int?
    private var activeSegmentURL: URL?
    private var segmentURLs: [URL] = []
    private var pendingRampFrameRate: Int?
    /// Cancellation token for Watch-timed bursts: every manual toggle, new
    /// timed press, or sequence teardown bumps it, orphaning any auto-revert
    /// still scheduled. Confined to `sessionQueue`.
    private var timedBurstGeneration = 0
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
    // The exposure the lock froze at — the zero point `setExposureOffset`
    // works either side of. Fixed at lock time (not updated as the offset is
    // dragged) so the brightness slider's centre keeps meaning "as locked".
    private var anchorISOValue: Float = 0
    private var anchorShutterValue: Double = 0

    @Published var isAuthorized: Bool?
    @Published var isRecording = false
    @Published var recordingStartedAt: Date?
    /// Start of the capture run in progress (video, interval, or Live Blend) —
    /// the "Stop at" anchor: stop amounts measure the whole run from here.
    /// Meaningful only while a run flag is true; the next start overwrites it.
    private(set) var captureRunStartedAt: Date?
    @Published var isIntervalRunning = false
    @Published var photoCount = 0 {
        didSet { checkScheduledStopCount() }
    }
    @Published var activeFormatDescription = ""
    @Published var availableStops: [DerivedOpticsStop] = []
    @Published var selectedStop: DerivedOpticsStop?
    /// True while a DNG-world lens change (or arm/disarm) reconnects the
    /// physical camera — the one transition a zoom ramp cannot cover, since
    /// Bayer RAW only exists on direct physical-device connections. The
    /// capture screen dips the viewfinder while this is set, so the user
    /// never sees the old lens's live feed followed by a hard cut.
    @Published var isSwitchingLens = false
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
    /// The running ramp sequence's locked base rate, nil when idle.
    /// `selectedFrameRate` tracks the ACTIVE segment (it reads the burst rate
    /// mid-burst), so anything that must keep naming the resting rate — the
    /// Watch's base chip — reads this instead.
    @Published private(set) var activeBaseFrameRate: Int?
    @Published var rampSpans: [RampSpan] = []
    @Published var isExposureLocked: Bool = false
    @Published var lockedISO: Float = 0
    @Published var lockedShutterSeconds: Double = 0
    @Published var lockedLensPosition: Float = 0.5
    @Published var isoRange: ClosedRange<Float> = 25...3200
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

    /// "Capture Flat" for video: when true, video capture uses Apple Log on
    /// devices that support it (iPhone 15 Pro and later). Set from the capture
    /// screen (video mode + Capture Flat on). Stills ignore this — their flat
    /// pass is a post-capture Core Image grade (`FlatCapture`), not a sensor
    /// colour space. Toggling re-applies the colour space to the live session.
    @Published var appleLogEnabled = false {
        didSet {
            guard appleLogEnabled != oldValue else { return }
            applyVideoColorSpace()
        }
    }

    /// True when the current camera device offers Apple Log on any of its
    /// formats — the gate for showing the Capture Flat toggle in Video mode.
    /// Devices without Log support (older iPhones, the Mac) return false and the
    /// toggle stays hidden.
    var supportsAppleLog: Bool {
        #if os(iOS)
        if #available(iOS 17.2, *) {
            return videoDevice?.formats.contains {
                $0.supportedColorSpaces.contains(.appleLog)
            } ?? false
        }
        #endif
        return false
    }

    /// Applies the requested video colour space (Apple Log when enabled and the
    /// *active* format supports it, otherwise sRGB) to the live device. No-op
    /// while recording — the format/colour space must not change mid-take.
    /// Called on `appleLogEnabled` changes and re-asserted after every
    /// `activeFormat` switch (which resets the colour space to the default).
    private func applyVideoColorSpace() {
        #if os(iOS)
        guard #available(iOS 17.2, *) else { return }
        sessionQueue.async {
            guard let device = self.videoDevice, !self.movieOutput.isRecording else { return }
            let target: AVCaptureColorSpace =
                (self.appleLogEnabled && device.activeFormat.supportedColorSpaces.contains(.appleLog))
                ? .appleLog : .sRGB
            guard device.activeColorSpace != target else { return }
            do {
                try device.lockForConfiguration()
                device.activeColorSpace = target
                device.unlockForConfiguration()
            } catch {
                LLog("applyVideoColorSpace failed: \(error.localizedDescription)")
            }
        }
        #endif
    }

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
        preferredStopFactor = RecordingSettingsStore.stopDisplayFactor
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
        let optics = Self.captureOpticsDevice()
        opticsDevice = optics
        #if os(iOS)
        // Bayer RAW is a physical-device capability (the virtual camera
        // reports none — probe 2026-08-04), and the list only populates in a
        // photo configuration, so the DNG gate is probed on the physical
        // wide before the optics input goes in. All pre-startRunning, so the
        // extra configuration passes never show on screen.
        let probeDevice = (optics?.isVirtualDevice == true)
            ? optics.flatMap(Self.physicalWide(of:))
            : optics
        if let probeDevice, let probeInput = try? AVCaptureDeviceInput(device: probeDevice) {
            session.beginConfiguration()
            session.sessionPreset = .photo
            if session.canAddInput(probeInput) { session.addInput(probeInput) }
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
            session.commitConfiguration()
            let rawFormats = availableBayerRawFormats()
            let dims = CMVideoFormatDescriptionGetDimensions(probeDevice.activeFormat.formatDescription)
            wideRAWProbe = (
                !rawFormats.isEmpty,
                rawFormats.isEmpty ? nil : CaptureResolution(width: dims.width, height: dims.height))
            bayerRAWProbeByDevice[probeDevice.uniqueID] = wideRAWProbe
            LLog("liveblend-dng: configure probe \(probeDevice.localizedName) bayerRAW=\(wideRAWProbe.supported) sensor=\(dims.width)x\(dims.height)")
            session.beginConfiguration()
            session.removeInput(probeInput)
            session.commitConfiguration()
        }
        #endif
        session.beginConfiguration()
        session.sessionPreset = .high
        if let optics, let input = try? AVCaptureDeviceInput(device: optics),
           session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            videoDevice = optics
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        session.commitConfiguration()
        #if os(iOS)
        if let optics { installConstituentLogging(on: optics) }
        #endif
        deriveStops()
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
        // Virtual devices never offer Bayer RAW (probe 2026-08-04) — the
        // standard world answers from the physical wide's configure-time
        // probe instead of flipping presets to learn nothing.
        if device.isVirtualDevice { return wideRAWProbe }
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

    // MARK: - Photo-aspect preview (armed DNG framing)

    /// The preset to restore when the photo-aspect framing preview disarms.
    /// Non-nil exactly while the preview is armed. sessionQueue-confined.
    private var photoAspectPreviousPreset: AVCaptureSession.Preset?

    /// Presents the sensor's true capture frame while a DNG interval shoot
    /// is armed: DNG captures the full 4:3 sensor, so framing switches the
    /// session to the photo configuration (and back on disarm) rather than
    /// letting a 16:9 video letterbox promise framing the file won't have.
    /// No-op while any capture is running — the DNG run flips the preset
    /// itself, and its restore leaves the armed configuration in place.
    func setPhotoAspectPreview(_ active: Bool) {
        sessionQueue.async {
            guard !self.movieOutput.isRecording, self.intervalTimer == nil, !self.isLiveBlendActive else { return }
            if active {
                self.armPhotoAspectPreview()
            } else {
                self.disarmPhotoAspectPreview()
            }
        }
    }

    /// sessionQueue-confined. DNG frames come from a physical camera (the
    /// virtual device offers no Bayer RAW — probe 2026-08-04), so arming
    /// swaps the session input to the nearest optical stop's constituent,
    /// verifies RAW honestly on that device, and only then flips to the
    /// photo configuration. Stops republish as optical-only.
    private func armPhotoAspectPreview() {
        guard photoAspectPreviousPreset == nil else { return }
        let previousPreset = session.sessionPreset
        guard let target = nearestOpticalStop(to: currentStop) else { return }
        beginLensCover()
        #if os(iOS)
        if !physicalWorldActive, let optics = opticsDevice, optics.isVirtualDevice {
            guard let device = physicalDevice(for: target),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                endLensCoverAfterSettle(0)
                return
            }
            session.beginConfiguration()
            if let videoInput { session.removeInput(videoInput) }
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
                videoDevice = device
            }
            session.commitConfiguration()
        }
        #endif
        guard deviceSupportsBayerRAW() else {
            // Honest refusal: this camera cannot deliver DNG — undo the swap.
            restoreOpticsInputIfNeeded()
            _ = applyCaptureFormat(resolution: selectedResolution, fps: selectedFrameRate)
            deriveStops()
            publishFormat()
            endLensCoverAfterSettle()
            return
        }
        photoAspectPreviousPreset = previousPreset
        currentStop = target
        applyPhotoAspectConfiguration()
        deriveStops()
        endLensCoverAfterSettle()
    }

    /// sessionQueue-confined: restore the optics input and the pinned video
    /// configuration, republishing the full stop set.
    private func disarmPhotoAspectPreview() {
        guard let previous = photoAspectPreviousPreset else { return }
        beginLensCover()
        photoAspectPreviousPreset = nil
        session.beginConfiguration()
        session.sessionPreset = previous
        session.commitConfiguration()
        restoreOpticsInputIfNeeded()
        _ = applyCaptureFormat(resolution: selectedResolution, fps: selectedFrameRate)
        deriveStops()
        publishFormat()
        endLensCoverAfterSettle()
    }

    /// sessionQueue-confined: put the optics device back as the session's
    /// video input after DNG work ran on a physical constituent.
    private func restoreOpticsInputIfNeeded() {
        guard let optics = opticsDevice, videoDevice !== optics,
              let input = try? AVCaptureDeviceInput(device: optics) else { return }
        session.beginConfiguration()
        if let videoInput { session.removeInput(videoInput) }
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            videoDevice = optics
        }
        session.commitConfiguration()
    }

    /// sessionQueue-confined: flips the session to the photo configuration
    /// and re-asserts any manual exposure lock (a preset change resets the
    /// device to auto, like any format switch).
    private func applyPhotoAspectConfiguration() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.commitConfiguration()
        if let device = videoDevice, (try? device.lockForConfiguration()) != nil {
            reassertExposureLock(on: device)
            device.unlockForConfiguration()
        }
        publishFormat()
    }

    /// Stop (and resolution) changes in the DNG world re-pin the 16:9 video
    /// format as a side effect; when the photo-aspect preview is armed it
    /// must win again afterwards — or disarm honestly if the new device
    /// cannot do RAW.
    private func reassertPhotoAspectPreviewIfArmed() {
        guard photoAspectPreviousPreset != nil else { return }
        if deviceSupportsBayerRAW() {
            applyPhotoAspectConfiguration()
        } else {
            photoAspectPreviousPreset = nil
            restoreOpticsInputIfNeeded()
            _ = applyCaptureFormat(resolution: selectedResolution, fps: selectedFrameRate)
            deriveStops()
            publishFormat()
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
        let enhanced = CaptureOpticsStore.enhancedLensesEnabled
        if enhanced != lastEnhancedLensesEnabled {
            lastEnhancedLensesEnabled = enhanced
            deriveStops()
        }
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

    // MARK: - Capture optics (derived lens stops)

    /// The device lens stops derive from and the standard world captures
    /// through: the virtual multi-cam when the hardware has one (system-
    /// managed constituent switching, zoom-ramp lens changes, cross-lens
    /// AE handoff), else the plain wide/default device.
    private static func captureOpticsDevice() -> AVCaptureDevice? {
        #if os(iOS)
        let preference: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
        ]
        return preference.lazy
            .compactMap { AVCaptureDevice.default($0, for: .video, position: .back) }
            .first
        #else
        return AVCaptureDevice.default(for: .video)
        #endif
    }

    #if os(iOS)
    /// Console-visible constituent handoffs (🎥LL): a finger-over-the-lens
    /// test reads straight from the log. Also logs the switching-policy
    /// defaults once — the prime suspect in the Photo-JPEG tele report
    /// (2026-08-04): the wide was observed serving the 5×/10× stops.
    private var constituentObservation: NSKeyValueObservation?

    private func installConstituentLogging(on device: AVCaptureDevice) {
        constituentObservation = nil
        guard device.isVirtualDevice else { return }
        LLog("optics: switching policy=\(device.primaryConstituentDeviceSwitchingBehavior.rawValue)"
            + " active=\(device.activePrimaryConstituentDeviceSwitchingBehavior.rawValue)"
            + " conditions=\(device.primaryConstituentDeviceRestrictedSwitchingBehaviorConditions.rawValue)")
        constituentObservation = device.observe(
            \.activePrimaryConstituent, options: [.initial, .new]
        ) { device, _ in
            let name = device.activePrimaryConstituent?.deviceType.rawValue
                .replacingOccurrences(of: "AVCaptureDeviceTypeBuiltIn", with: "") ?? "none"
            LLog("optics: constituent → \(name) (zoom \(String(format: "%.2f", device.videoZoomFactor)))")
        }
    }
    #endif

    /// The physical wide-angle constituent of a virtual device.
    private static func physicalWide(of device: AVCaptureDevice) -> AVCaptureDevice? {
        #if os(iOS)
        return device.constituentDevices.first { $0.deviceType == .builtInWideAngleCamera }
            ?? device.constituentDevices.first
        #else
        return device
        #endif
    }

    /// True while the session runs on a physical constituent for DNG work
    /// rather than the optics device. sessionQueue-confined.
    private var physicalWorldActive: Bool {
        guard let optics = opticsDevice else { return false }
        return videoDevice !== optics
    }

    /// True while DNG work owns the session configuration (armed framing
    /// preview or a running DNG blend) — the state that restricts stops to
    /// optical. On single-camera hardware the input never swaps, so this is
    /// deliberately preset-based, not input-based. sessionQueue-confined.
    private var dngWorldActive: Bool {
        #if os(iOS)
        return photoAspectPreviousPreset != nil || dngRunPreviousPreset != nil
        #else
        return false
        #endif
    }

    /// Derive the stop list from the optics device and publish the filtered
    /// set: Settings can hide the enhanced (non-optical) stops, and DNG
    /// work offers optical stops only — a zoom crop never applies to a
    /// Bayer mosaic, so a computational chip would promise framing the file
    /// won't have. sessionQueue-confined.
    private func deriveStops() {
        guard let optics = opticsDevice else {
            fullStops = []
            currentStop = nil
            DispatchQueue.main.async {
                self.availableStops = []
                self.selectedStop = nil
            }
            return
        }
        #if os(iOS)
        let constituents = optics.isVirtualDevice
            ? optics.constituentDevices
                .sorted { $0.activeFormat.videoFieldOfView > $1.activeFormat.videoFieldOfView }
                .map { $0.deviceType.rawValue }
            : [optics.deviceType.rawValue]
        var cropFactors = Set<Double>()
        for format in optics.formats {
            format.secondaryNativeResolutionZoomFactors.forEach { cropFactors.insert(Double($0)) }
        }
        fullStops = CaptureOpticsDerivation.derive(.init(
            constituents: constituents,
            switchOverFactors: optics.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue),
            sensorCropFactors: cropFactors.sorted(),
            maxZoomFactor: Double(optics.activeFormat.videoMaxZoomFactor)))
        #else
        // The Mac's webcam is one lens; digital zoom support is spotty and
        // the chips hide for a single stop anyway.
        fullStops = [DerivedOpticsStop(
            displayFactor: 1, rawFactor: 1, kind: .optical,
            expectedBacking: optics.deviceType.rawValue)]
        #endif

        var stops = fullStops
        if !CaptureOpticsStore.enhancedLensesEnabled || dngWorldActive {
            stops = stops.filter { $0.kind == .optical }
        }
        let target = preferredStopFactor ?? currentStop?.displayFactor ?? 1.0
        preferredStopFactor = nil
        let selected = stops.min {
            abs(log($0.displayFactor) - log(target)) < abs(log($1.displayFactor) - log(target))
        }
        currentStop = selected
        DispatchQueue.main.async {
            self.availableStops = stops
            self.selectedStop = selected
        }
        if let selected, !physicalWorldActive {
            applyZoom(selected, animated: false)
        }
    }

    /// The physical constituent backing a stop — the DNG world's discrete-
    /// device sessions capture through this.
    private func physicalDevice(for stop: DerivedOpticsStop) -> AVCaptureDevice? {
        guard let optics = opticsDevice else { return nil }
        #if os(iOS)
        guard optics.isVirtualDevice else { return optics }
        let sorted = optics.constituentDevices
            .sorted { $0.activeFormat.videoFieldOfView > $1.activeFormat.videoFieldOfView }
        var index = 0
        for (i, factor) in optics.virtualDeviceSwitchOverVideoZoomFactors.enumerated()
        where stop.rawFactor >= factor.doubleValue {
            index = i + 1
        }
        return sorted[safe: index] ?? optics.constituentDevices.first
        #else
        return optics
        #endif
    }

    /// The optical stop nearest (in log space) to `stop` — what a
    /// computational selection collapses to when DNG work needs a physical
    /// lens. sessionQueue-confined.
    private func nearestOpticalStop(to stop: DerivedOpticsStop?) -> DerivedOpticsStop? {
        let optical = fullStops.filter { $0.kind == .optical }
        guard let stop else { return optical.first { $0.displayFactor == 1 } ?? optical.first }
        return optical.min {
            abs(log($0.displayFactor) - log(stop.displayFactor))
                < abs(log($1.displayFactor) - log(stop.displayFactor))
        }
    }

    /// Select a lens stop. Standard world: a zoom ramp on the one optics
    /// input — no session transaction, continuous imagery, exposure carried
    /// across the switchover by the system. DNG world: a discrete input swap
    /// to the stop's physical camera (Bayer RAW requires it).
    func selectStop(_ stop: DerivedOpticsStop) {
        sessionQueue.async {
            guard !self.movieOutput.isRecording, self.intervalTimer == nil, !self.isLiveBlendActive else { return }
            RecordingSettingsStore.save(stopFactor: stop.displayFactor)
            if self.physicalWorldActive {
                self.selectPhysicalStop(stop)
            } else {
                self.applyZoom(stop, animated: true)
            }
        }
    }

    /// sessionQueue-confined. Rate 8 (powers of two per second) crosses the
    /// 1×→5× jump in ~0.29 s — the native app's kind of snap.
    private func applyZoom(_ stop: DerivedOpticsStop, animated: Bool) {
        guard let device = videoDevice else { return }
        #if os(iOS)
        let raw = min(CGFloat(stop.rawFactor), device.activeFormat.videoMaxZoomFactor)
        do {
            try device.lockForConfiguration()
            if animated, session.isRunning {
                device.ramp(toVideoZoomFactor: raw, withRate: 8)
            } else {
                device.videoZoomFactor = raw
            }
            device.unlockForConfiguration()
        } catch {
            LLog("optics: zoom to \(stop.chipLabel) failed: \(error.localizedDescription)")
            return
        }
        #endif
        currentStop = stop
        DispatchQueue.main.async {
            if self.selectedStop != stop { self.selectedStop = stop }
        }
    }

    // MARK: - DNG-world lens transitions

    /// Cover token: every covered transition bumps the generation so an
    /// overlapping switch keeps the dip up until the last one settles.
    /// sessionQueue-confined.
    private var lensCoverGeneration = 0

    private func beginLensCover() {
        lensCoverGeneration += 1
        DispatchQueue.main.async {
            if !self.isSwitchingLens { self.isSwitchingLens = true }
        }
    }

    /// Drop the cover once the new device has had a beat to deliver and
    /// meter — the dip hides the reconnection AND the first dark frames of
    /// the fresh AE.
    private func endLensCoverAfterSettle(_ delay: TimeInterval = 0.35) {
        let generation = lensCoverGeneration
        sessionQueue.asyncAfter(deadline: .now() + delay) {
            guard generation == self.lensCoverGeneration else { return }
            DispatchQueue.main.async { self.isSwitchingLens = false }
        }
    }

    /// sessionQueue-confined DNG-world stop change: ONE session transaction
    /// swapping the input to the stop's physical camera, under the dip. In
    /// the armed world the session already runs (and stays in) the photo
    /// configuration — no video-format pin, no preset flip; the old
    /// three-transaction sequence was the "horrible" DNG switch.
    private func selectPhysicalStop(_ stop: DerivedOpticsStop) {
        guard stop.kind == .optical,
              let device = physicalDevice(for: stop) else { return }
        guard device !== videoDevice else {
            // Already on this camera — just confirm the selection.
            currentStop = stop
            DispatchQueue.main.async {
                if self.selectedStop != stop { self.selectedStop = stop }
            }
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else { return }
        beginLensCover()
        session.beginConfiguration()
        if let videoInput { session.removeInput(videoInput) }
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            videoDevice = device
        }
        session.commitConfiguration()
        currentStop = stop
        DispatchQueue.main.async {
            if self.selectedStop != stop { self.selectedStop = stop }
        }
        if photoAspectPreviousPreset != nil {
            // Armed world: verify RAW on the new constituent (cached after
            // the first visit), re-assert any exposure lock, republish. A
            // constituent that can't deliver DNG disarms honestly.
            if deviceSupportsBayerRAW() {
                if (try? device.lockForConfiguration()) != nil {
                    reassertExposureLock(on: device)
                    device.unlockForConfiguration()
                }
                publishLiveBlendDNGSupport()
                publishFormat()
            } else {
                photoAspectPreviousPreset = nil
                restoreOpticsInputIfNeeded()
                _ = applyCaptureFormat(resolution: selectedResolution, fps: selectedFrameRate)
                deriveStops()
                publishFormat()
            }
        } else {
            // DNG run without armed framing (edge): the old full path.
            refreshCaptureOptions()
            applyVideoStabilization()
            publishFormat()
            reassertPhotoAspectPreviewIfArmed()
        }
        endLensCoverAfterSettle()
    }

    func selectResolution(_ resolution: CaptureResolution) {
        sessionQueue.async {
            guard !self.movieOutput.isRecording, self.intervalTimer == nil, !self.isLiveBlendActive else { return }
            self.refreshCaptureOptions(preferredResolution: resolution)
            self.publishFormat()
            self.reassertPhotoAspectPreviewIfArmed()
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
        var candidateFrameRates = Self.preferredFrameRates
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
            let resolution = CaptureResolution(
                width: dims.width,
                height: dims.height,
                isProRes: Self.proResFourCCs.contains(subType)
            )
            let rates = Self.supportedFrameRates(for: format, candidates: candidateFrameRates)
            guard !rates.isEmpty else { continue }
            supportedRates[resolution, default: []].formUnion(rates)
        }
        return supportedRates
    }

    private static func supportedFrameRates(
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

    private static func supportsFrameRate(_ fps: Double, in range: AVFrameRateRange) -> Bool {
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
            #if os(iOS)
            // Setting `activeFormat` also resets `videoZoomFactor` to 1 —
            // re-assert the selected stop so a format change (resolution,
            // fps, a ramp-burst segment) never silently jumps the framing.
            if !physicalWorldActive, let stop = currentStop {
                device.videoZoomFactor = min(
                    CGFloat(stop.rawFactor), device.activeFormat.videoMaxZoomFactor)
            }
            // Setting `activeFormat` resets the device to its default colour
            // space, so re-assert Apple Log if Capture Flat is on and the new
            // format supports it (otherwise sRGB).
            if #available(iOS 17.2, *) {
                let target: AVCaptureColorSpace =
                    (appleLogEnabled && match.format.supportedColorSpaces.contains(.appleLog))
                    ? .appleLog : .sRGB
                if device.activeColorSpace != target {
                    device.activeColorSpace = target
                }
            }
            #endif
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
                        Self.supportsFrameRate(targetFPS, in: range)
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
        let preview = CaptureResolution(width: dims.width, height: dims.height)
        DispatchQueue.main.async {
            self.videoStabilizationStatus = stabilizationStatus
            self.activeFormatDescription = line
            if self.previewDimensions != preview {
                self.previewDimensions = preview
            }
        }
    }

    /// Point the movie and photo output connections at `orientation` so
    /// recordings and stills are written the right way up. Called once when the
    /// capture screen appears — the connection + stabilization pass is safe
    /// before capture starts, but stalled the live source when driven per
    /// rotation (a7bab45). Mid-session rotations go through the cache-only
    /// `updateCaptureOrientation` instead; each capture run re-asserts its
    /// output connection from the cache at start.
    func setVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        LLog("setVideoOrientation(\(orientation.rawValue)) [outputs+stabilization]")
        #if os(iOS)
        // Cache the interface-derived orientation so capture-queue work
        // (interval tick, segment/blend start) never has to read UIKit.
        latestCaptureOrientation = orientation
        #endif
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
    /// Refresh the cached capture orientation only — no output-connection or
    /// stabilization work, so it is safe on every rotation mid-session (the
    /// full reconfigure in `setVideoOrientation` stalled the live source when
    /// driven per rotation; see a7bab45). Output connections are (re)asserted
    /// from this cache at each capture-run start.
    func updateCaptureOrientation(_ orientation: AVCaptureVideoOrientation) {
        LLog("updateCaptureOrientation(\(orientation.rawValue)) [cache only]")
        latestCaptureOrientation = orientation
    }

    /// The orientation to bake into recordings/stills right now. Returns the
    /// cached orientation (updated on the main thread by `setVideoOrientation`
    /// and `updateCaptureOrientation`) rather than reading UIKit — this is
    /// called from `sessionQueue`, where UIKit access is illegal and crashes.
    private func captureOrientation() -> AVCaptureVideoOrientation {
        latestCaptureOrientation
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
                // Re-anchor the brightness slider on every fresh lock.
                self.anchorISOValue = iso
                self.anchorShutterValue = duration.seconds
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

    /// Move exposure a number of stops either side of the value the lock froze
    /// at — positive brightens, negative darkens. The gain is spent on ISO
    /// first (it costs no motion blur and no frame pacing) and only the
    /// remainder on shutter duration, so the control still travels when ISO is
    /// already pinned: the daylight case, where the lock lands on the sensor's
    /// minimum ISO and ISO alone could only ever brighten.
    func setExposureOffset(stops: Float) {
        #if os(iOS)
        sessionQueue.async {
            guard let device = self.videoDevice,
                  device.isExposureModeSupported(.custom) else { return }
            // A lock taken before this build (or a stale anchor) falls back to
            // wherever the device is now, so the slider is never dead.
            let anchorISO = self.anchorISOValue > 0 ? self.anchorISOValue : device.iso
            let anchorSeconds = self.anchorShutterValue > 0
                ? self.anchorShutterValue
                : device.exposureDuration.seconds
            guard anchorISO > 0, anchorSeconds > 0 else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let format = device.activeFormat
                let gain = pow(2.0, Double(stops))
                let wantedISO = Double(anchorISO) * gain
                let iso = min(max(Float(wantedISO), format.minISO), format.maxISO)
                // Whatever the ISO clamp couldn't deliver goes to the shutter.
                let remaining = wantedISO / Double(iso)
                // Same frame-interval clamp `reassertExposureLock` applies: a
                // shutter longer than the frame duration drags the delivered
                // rate below the requested fps.
                var maxSeconds = format.maxExposureDuration.seconds
                let frameDuration = device.activeVideoMaxFrameDuration
                if frameDuration.isValid, frameDuration.seconds > 0 {
                    maxSeconds = min(maxSeconds, frameDuration.seconds)
                }
                let seconds = min(
                    max(anchorSeconds * remaining, format.minExposureDuration.seconds),
                    maxSeconds
                )
                let duration = CMTimeMakeWithSeconds(seconds, preferredTimescale: 1_000_000)
                device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
                self.exposureLocked = true
                self.lockedISOValue = iso
                self.lockedShutterValue = seconds
                DispatchQueue.main.async {
                    self.isExposureLocked = true
                    self.lockedISO = iso
                    self.lockedShutterSeconds = seconds
                }
            } catch {}
        }
        #else
        _ = stops
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
            // Geotagging: open this take's fix tracking now, so the location
            // baked into every segment is where the recording started — the fix
            // already in hand if it's accurate enough, else the first accurate
            // one to arrive while shooting.
            if self.gpsTaggingEnabled { LocationService.shared.beginRecordingFix() }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("live-capture-\(Int(startedAt.timeIntervalSince1970))")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let resolution = LiveCaptureSequence.Resolution(
                width: self.selectedResolution.width,
                height: self.selectedResolution.height
            )
            let baseFrameRate = self.selectedFrameRate
            self.activeSequence = LiveCaptureSequence(
                mode: mode,
                createdAt: startedAt,
                lockedResolution: resolution,
                baseFrameRate: baseFrameRate,
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
            #if os(iOS)
            // One orientation per sequence: every segment records with the
            // pose the run started in (see activeSequenceOrientation).
            self.activeSequenceOrientation = self.captureOrientation()
            #endif
            self.startNextSegment(frameRate: self.selectedFrameRate)
            DispatchQueue.main.async {
                self.recordingStartedAt = startedAt
                self.captureRunStartedAt = startedAt
                self.isRecording = true
                self.activeSequenceMode = mode
                self.markerCount = 0
                self.rampIntervalCount = 0
                self.segmentCount = 1
                self.isRampActive = false
                self.isRampHighRate = false
                self.activeBaseFrameRate = baseFrameRate
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
            // A manual toggle supersedes any timed burst: its pending
            // auto-revert must not fire on top of what the user just chose.
            self.timedBurstGeneration += 1
            self.performLiveMomentToggle()
        }
    }

    /// The Watch's "burst Ns" press: jump to the burst rate now (if not
    /// already there) and revert to the base rate after `duration`. The timer
    /// lives here rather than on the Watch so the revert still lands when the
    /// Watch sleeps mid-burst. Pressing again reschedules the revert; a
    /// manual toggle cancels it.
    func triggerTimedLiveMoment(duration: TimeInterval) {
        sessionQueue.async {
            guard self.activeSequence != nil else { return }
            self.timedBurstGeneration += 1
            self.beginTimedBurst(duration: duration, generation: self.timedBurstGeneration)
        }
    }

    /// Opens the timed burst, waiting out any segment switch already in
    /// flight (`pendingRampFrameRate` can't be interrupted). A stale open is
    /// worse than none (a burst nobody asked for anymore firing seconds
    /// late), so unlike the revert below this wait gives up — loudly.
    private func beginTimedBurst(duration: TimeInterval, generation: Int, attempt: Int = 0) {
        guard generation == timedBurstGeneration, activeSequence != nil else { return }
        if !rampIntervalActive {
            if pendingRampFrameRate != nil || !movieOutput.isRecording {
                guard attempt < 20 else {
                    LLog("timedBurst open abandoned: segment switch still in flight after 3s")
                    return
                }
                sessionQueue.asyncAfter(deadline: .now() + 0.15) {
                    self.beginTimedBurst(duration: duration, generation: generation, attempt: attempt + 1)
                }
                return
            }
            performLiveMomentToggle()
            // The toggle can refuse (e.g. burst rate equals the base rate) —
            // nothing opened, so there is nothing to revert.
            guard rampIntervalActive else { return }
        }
        armTimedBurstRevert(duration: duration, generation: generation)
    }

    /// Starts the countdown only once the burst-rate segment is actually
    /// rolling: the marker opens instantly, but the switch behind it first
    /// finalizes the previous segment — minutes of footage take a while — and
    /// "2s" must buy two seconds AT the burst rate, not two seconds of mostly
    /// switch latency.
    private func armTimedBurstRevert(duration: TimeInterval, generation: Int) {
        guard generation == timedBurstGeneration,
              activeSequence != nil,
              rampIntervalActive else { return }
        guard pendingRampFrameRate == nil, movieOutput.isRecording else {
            sessionQueue.asyncAfter(deadline: .now() + 0.15) {
                self.armTimedBurstRevert(duration: duration, generation: generation)
            }
            return
        }
        LLog("timedBurst rolling: revert in \(duration)s")
        sessionQueue.asyncAfter(deadline: .now() + duration) {
            self.endTimedBurst(generation: generation)
        }
    }

    private func endTimedBurst(generation: Int, attempt: Int = 0) {
        guard generation == timedBurstGeneration,
              activeSequence != nil,
              rampIntervalActive else { return }
        if pendingRampFrameRate != nil || !movieOutput.isRecording {
            // Never give up: finalizing a long previous segment can outlast
            // any fixed retry budget, and a missed revert pins the rest of
            // the recording at the burst rate.
            if attempt == 0 { LLog("timedBurst revert waiting on segment switch") }
            sessionQueue.asyncAfter(deadline: .now() + 0.15) {
                self.endTimedBurst(generation: generation, attempt: attempt + 1)
            }
            return
        }
        if attempt > 0 { LLog("timedBurst revert ran after \(attempt) deferrals") }
        performLiveMomentToggle()
    }

    private func performLiveMomentToggle() {
        guard let sequence = activeSequence,
              movieOutput.isRecording,
              let startedAt = activeSequenceStartedAt else { return }

        switch sequence.mode {
        case .marker:
            toggleRampInterval(at: Date(), sequenceStartedAt: startedAt)
        case .ramp:
            guard pendingRampFrameRate == nil else { return }
            let shouldTurnRampOn = !rampIntervalActive
            let targetFrameRate = shouldTurnRampOn
                ? (sequence.rampFrameRate ?? selectedRampFrameRate)
                : sequence.baseFrameRate
            let currentFrameRate = activeRecordingFrameRate ?? selectedFrameRate
            guard targetFrameRate != currentFrameRate else { return }
            if shouldTurnRampOn {
                openRampInterval(at: Date(), sequenceStartedAt: startedAt)
            } else {
                closeOpenRampInterval(at: Date())
            }
            pendingRampFrameRate = targetFrameRate
            movieOutput.stopRecording()
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
        // run-locked orientation so a fresh connection never records the wrong
        // way up and mid-run rotation can't flip later segments.
        if let connection = movieOutput.connection(with: .video),
           connection.isVideoOrientationSupported {
            connection.videoOrientation = activeSequenceOrientation ?? captureOrientation()
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
        timedBurstGeneration += 1
        activeSequence = nil
        activeSequenceDirectory = nil
        activeSequenceStartedAt = nil
        #if os(iOS)
        activeSequenceOrientation = nil
        #endif
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
            self.activeBaseFrameRate = nil
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

    /// Starts an interval photo session. `frameCap` (Photo mode) auto-stops the
    /// session once that many stills have landed — 1 for a single snapshot, or
    /// the blend depth for a steadied burst that stacks in post. A capped burst
    /// runs at a faster fixed rate than an open-ended Interval shoot, so it
    /// allows a shorter minimum spacing.
    func startInterval(every seconds: Double, frameCap: Int? = nil) {
        sessionQueue.async {
            guard self.intervalTimer == nil else { return }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("interval-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.photoDirectory = directory
            self.photoURLs = []
            self.intervalFrameCap = frameCap
            self.intervalFramesRequested = 0
            self.intervalActive = true
            DispatchQueue.main.async {
                self.photoCount = 0
                self.captureRunStartedAt = Date()
                self.isIntervalRunning = true
            }
            let period = frameCap != nil ? max(0.05, seconds) : max(0.5, seconds)
            #if os(iOS)
            // One orientation per run: mixed EXIF orientations across a burst
            // would change post-rotation frame sizes and fail the blend
            // pipeline's size guard, so every tick stamps the pose the run
            // started in.
            let runOrientation = self.captureOrientation()
            #endif
            let timer = DispatchSource.makeTimerSource(queue: self.sessionQueue)
            timer.schedule(deadline: .now(), repeating: period)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                // A capped session stops requesting once the whole burst is
                // out; the remaining stills are still in flight.
                if let cap = self.intervalFrameCap, self.intervalFramesRequested >= cap {
                    return
                }
                #if os(iOS)
                // Per-tick re-assert is cheap and heals any connection rebuild
                // mid-run; the value stays run-locked.
                if let connection = self.photoOutput.connection(with: .video),
                   connection.isVideoOrientationSupported {
                    connection.videoOrientation = runOrientation
                }
                #endif
                let settings = AVCapturePhotoSettings()
                if let photoDimensions = self.selectedPhotoDimensions {
                    settings.maxPhotoDimensions = photoDimensions
                }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
                self.intervalFramesRequested += 1
                // Burst complete: stop the repeating timer now. The session
                // finalizes when the last requested still is written (see the
                // capture delegate).
                if let cap = self.intervalFrameCap, self.intervalFramesRequested >= cap {
                    self.intervalTimer?.cancel()
                    self.intervalTimer = nil
                }
            }
            timer.resume()
            self.intervalTimer = timer
        }
    }

    func stopInterval() {
        cancelScheduledStop()
        sessionQueue.async {
            self.finishIntervalOnQueue()
        }
    }

    /// sessionQueue-confined. Cancels the timer, emits the captured stills and
    /// clears interval state — exactly once (guarded by `intervalActive`), so a
    /// cap-reached finish and a user stop never double-emit. A single frame is
    /// valid output (Photo mode's snapshot), so there is no minimum-frame floor.
    private func finishIntervalOnQueue() {
        guard self.intervalActive else { return }
        self.intervalActive = false
        self.intervalTimer?.cancel()
        self.intervalTimer = nil
        let urls = self.photoURLs
        self.intervalFrameCap = nil
        self.intervalFramesRequested = 0
        DispatchQueue.main.async {
            self.isIntervalRunning = false
            if urls.count >= 1 {
                self.onFinishPhotos?(urls)
            }
        }
    }

    // MARK: - Scheduled stop (Watch "stop at…")

    /// Schedules a stop of whatever capture is running, measured over the
    /// whole run: at the `amount`-minute mark from the run's start, or at
    /// `amount` total frames (photos/blends in Interval; fps-derived time in
    /// Video) — "stop at 10 minutes" armed 8 minutes in stops 2 minutes
    /// later. A mark the run has already passed stops immediately; the Watch
    /// floors its dial, so only a race lands there. Replaces any earlier
    /// schedule.
    func scheduleStop(unit: ScheduledStopUnit, amount: Double) {
        DispatchQueue.main.async {
            guard amount > 0 else { return }
            guard self.isRecording || self.isIntervalRunning || self.isLiveBlendRunning else { return }
            self.scheduledStopWorkItem?.cancel()
            self.scheduledStopWorkItem = nil

            let runStart = self.captureRunStartedAt ?? Date()
            let stop: ScheduledStop
            switch unit {
            case .minutes:
                stop = ScheduledStop(
                    unit: .minutes,
                    deadline: runStart.addingTimeInterval(amount * 60),
                    targetCount: nil)
            case .frames:
                if self.isRecording {
                    let fps = Double(max(1, self.selectedFrameRate))
                    stop = ScheduledStop(
                        unit: .frames,
                        deadline: runStart.addingTimeInterval(amount / fps),
                        targetCount: nil)
                } else {
                    stop = ScheduledStop(unit: .frames, deadline: nil, targetCount: Int(amount))
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
            // A count target the run has already met fires on the spot.
            self.checkScheduledStopCount()
            LLog("scheduled stop: \(unit.rawValue) \(amount) from run start")
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

    /// Starts a Live Blend run: every `interval` seconds, the depth's worth
    /// of frames — a fixed count, Safe mode's learned count, or everything
    /// unthrottled capture manages — is averaged into one output image. With
    /// `preferDNG` and a Bayer-RAW-capable source, frames come from RAW
    /// photo captures and the output is a blended DNG; otherwise the
    /// processed video stream is tapped and the output is JPEG. The run
    /// hands its outputs over through `onFinishLiveBlend` exactly like
    /// interval capture hands over `onFinishPhotos`.
    func startLiveBlend(every interval: Double, depth: BlendDepth, preferDNG: Bool = false, options: LiveBlendCaptureOptions = LiveBlendCaptureOptions()) {
        sessionQueue.async {
            guard !self.movieOutput.isRecording, self.intervalTimer == nil, !self.isLiveBlendActive else { return }

            #if os(iOS)
            if preferDNG, self.deviceSupportsBayerRAW() {
                self.startLiveBlendDNG(every: interval, depth: depth, options: options)
                return
            }
            #endif
            if preferDNG {
                LLog("liveblend: DNG requested but unsupported on this source — standard output")
            }
            self.startLiveBlendStandard(
                every: interval,
                depth: depth,
                requestedOutputFormat: preferDNG ? "dng" : "standard")
        }
    }

    /// Safe mode's per-window frame target for the *actual* pipeline the run
    /// landed on: the current bucket's learned count, falling back to the
    /// most conservative learned count for this interval when conditions
    /// drift into an unlearned bucket mid-session, and to a 2-frame floor
    /// only if learning was reset mid-run (the UI gates Safe on a usable
    /// profile before start).
    private static func throttledFrameTarget(pipeline: String, interval: Double) -> () -> Int {
        {
            let store = BlendProfileStore.shared
            let bucket = ThermalBucket(thermalState: ProcessInfo.processInfo.thermalState)
            if let learned = store.safeFrameCount(pipeline: pipeline, bucket: bucket, intervalSeconds: interval) {
                return learned
            }
            let fallback = store.conservativeFrameCount(pipeline: pipeline, intervalSeconds: interval) ?? 2
            LLog("liveblend: no \(bucket.rawValue) profile for \(pipeline) @ \(interval)s — safe target \(fallback)")
            return fallback
        }
    }

    /// Routes a controller's unthrottled-window lessons into the profile
    /// store under the pipeline that produced them.
    private static func learningRecorder(pipeline: String, interval: Double) -> (ThermalBucket, BlendLearningSample) -> Void {
        { bucket, sample in
            BlendProfileStore.shared.record(
                sample, pipeline: pipeline, bucket: bucket, intervalSeconds: interval)
        }
    }

    /// sessionQueue-confined: the video-tap JPEG path.
    private func startLiveBlendStandard(every interval: Double, depth: BlendDepth, requestedOutputFormat: String) {
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
                self.publishLiveBlendStartFailure(interval: interval, depth: depth)
                return
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("liveblend-\(Int(Date().timeIntervalSince1970))")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                LLog("liveblend: could not create temp directory: \(error)")
                self.publishLiveBlendStartFailure(interval: interval, depth: depth)
                return
            }

            let dimensions = self.videoDevice.map {
                CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription)
            }
            let configuration = LiveBlendController.Configuration(
                intervalSeconds: interval,
                blendDepth: depth,
                outputDirectory: directory,
                logURL: Self.liveBlendLogURL(),
                cameraName: self.videoDevice?.localizedName ?? "unknown camera",
                captureWidth: Int(dimensions?.width ?? 0),
                captureHeight: Int(dimensions?.height ?? 0),
                configuredFrameRate: self.selectedFrameRate,
                requestedOutputFormat: requestedOutputFormat,
                throttledFrameTarget: Self.throttledFrameTarget(pipeline: "standard", interval: interval),
                gpsMetadata: { [weak self] in
                    guard let self, self.gpsTaggingEnabled,
                          let location = LocationService.shared.latestLocation else { return nil }
                    return location.exifGPSDictionary()
                })

            let controller: LiveBlendController
            do {
                controller = try LiveBlendController(configuration: configuration)
            } catch {
                LLog("liveblend: controller init failed: \(error)")
                self.publishLiveBlendStartFailure(interval: interval, depth: depth)
                return
            }
            controller.onLearningSample = Self.learningRecorder(pipeline: "standard", interval: interval)
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
                self.captureRunStartedAt = Date()
                self.isLiveBlendRunning = true
                self.liveBlendOutputCount = 0
                self.liveBlendDiagnostics = LiveBlendDiagnosticsSnapshot(
                    requestedIntervalSeconds: interval,
                    requestedFramesPerBlend: configuration.initialDisplayFrames)
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
    private func startLiveBlendDNG(every interval: Double, depth: BlendDepth, options: LiveBlendCaptureOptions) {
        // DNG frames come from a physical camera. The armed framing preview
        // normally swapped the input already, but the arm is async — if the
        // run starts from the standard world, move to the nearest optical
        // stop's constituent now.
        if let device = videoDevice, device.isVirtualDevice,
           let target = nearestOpticalStop(to: currentStop),
           let physical = physicalDevice(for: target),
           let input = try? AVCaptureDeviceInput(device: physical) {
            session.beginConfiguration()
            if let videoInput { session.removeInput(videoInput) }
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
                videoDevice = physical
            }
            session.commitConfiguration()
            currentStop = target
        }
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
            startLiveBlendStandard(every: interval, depth: depth, requestedOutputFormat: "dng")
            return
        }
        dngRunPreviousPreset = previousPreset
        // The preview now shows the 4:3 photo feed; keep the published
        // letterbox dimensions honest even when the run started without the
        // armed framing preview.
        publishFormat()
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
        // Lock the RAW orientation for the run, after both configuration
        // passes above — the .photo preset switch and fast-capture setup can
        // rebuild the photo connection. Apple stamps TIFF tag 274 from this
        // value into every pass-through DNG, and CIRAWFilter bakes it into
        // the decoded working image for authored blends.
        if let connection = photoOutput.connection(with: .video),
           connection.isVideoOrientationSupported {
            connection.videoOrientation = captureOrientation()
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("liveblend-dng-\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            LLog("liveblend-dng: could not create temp directory: \(error)")
            publishLiveBlendStartFailure(interval: interval, depth: depth)
            return
        }
        let dimensions = videoDevice.map {
            CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription)
        }
        let configuration = LiveBlendRawController.Configuration(
            intervalSeconds: interval,
            blendDepth: depth,
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
            maxBracketFrames: bracketMax,
            throttledFrameTarget: Self.throttledFrameTarget(pipeline: "dng", interval: interval),
            gpsProvider: { [weak self] in
                guard let self, self.gpsTaggingEnabled,
                      let location = LocationService.shared.latestLocation else { return nil }
                return (location.coordinate.latitude, location.coordinate.longitude,
                        location.altitude, location.timestamp)
            })
        let controller = LiveBlendRawController(
            configuration: configuration,
            photoOutput: photoOutput,
            captureExecutor: { [weak self] block in self?.sessionQueue.async(execute: block) })
        controller.onLearningSample = Self.learningRecorder(pipeline: "dng", interval: interval)
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
            self.captureRunStartedAt = Date()
            self.isLiveBlendRunning = true
            self.liveBlendOutputCount = 0
            var snapshot = LiveBlendDiagnosticsSnapshot(
                requestedIntervalSeconds: interval,
                requestedFramesPerBlend: configuration.initialDisplayFrames)
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
        // While the photo-aspect preview is armed the run started from (and
        // returns to) the photo configuration — re-pinning the video format
        // (or restoring the optics input) would snap the viewfinder back to
        // 16:9 after every DNG shoot.
        if photoAspectPreviousPreset == nil {
            restoreOpticsInputIfNeeded()
            _ = applyCaptureFormat(resolution: selectedResolution, fps: selectedFrameRate)
            deriveStops()
        }
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

    private func publishLiveBlendStartFailure(interval: Double, depth: BlendDepth) {
        DispatchQueue.main.async {
            var snapshot = LiveBlendDiagnosticsSnapshot(
                requestedIntervalSeconds: interval,
                requestedFramesPerBlend: depth.fixedFrames ?? 0)
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
/// (UIInterfaceOrientation and AVCaptureVideoOrientation share raw values for
/// the same physical orientation). Used for the preview and as the seed/fallback
/// for capture tagging when the physical pose is unknown.
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

/// Map the physical device orientation to a capture orientation — what the
/// system camera tags with, so captures come out right even under the system
/// rotation lock (where the interface never rotates). nil for faceUp/faceDown/
/// unknown: the caller keeps the last meaningful pose. Note the landscape
/// inversion — UIDeviceOrientation.landscapeLeft (home side right) is the same
/// physical pose as AVCaptureVideoOrientation.landscapeRight.
func effectiveCaptureOrientation(device: UIDeviceOrientation) -> AVCaptureVideoOrientation? {
    switch device {
    case .portrait:
        return .portrait
    case .portraitUpsideDown:
        return .portraitUpsideDown
    case .landscapeLeft:
        return .landscapeRight
    case .landscapeRight:
        return .landscapeLeft
    default:
        return nil
    }
}

#else
func currentCaptureOrientation() -> AVCaptureVideoOrientation {
    .landscapeRight
}
#endif

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    /// Video "Capture Flat" on hardware that can't shoot Apple Log: grade the
    /// recorded movie on save instead. Log-capable devices already flatten at
    /// the sensor (`appleLogEnabled`), so there's nothing to do for them here.
    private var shouldSoftwareFlattenVideo: Bool {
        UserDefaults.standard.bool(forKey: FlatCapture.storageKey) && !supportsAppleLog
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        sessionQueue.async {
            let fileExists = FileManager.default.fileExists(atPath: outputFileURL.path)
            if fileExists {
                // Flatten in place before hand-off so downstream (segment list,
                // onFinishVideo) sees the graded file at the same URL.
                if self.shouldSoftwareFlattenVideo, !self.isDiscardingSequence {
                    _ = VideoFlatten.flattenInPlace(outputFileURL)
                }
                // Geotag the segment last: the flatten above re-encodes the
                // file and wouldn't carry the location atom through. Written
                // into the movie's own header because a `.gpx` sidecar doesn't
                // follow the clip into its project folder — and because the
                // movie's own metadata is where Photos looks for a clip's place.
                if self.gpsTaggingEnabled, !self.isDiscardingSequence,
                   let location = LocationService.shared.recordingLocation {
                    MovieLocation.inject(location, into: outputFileURL)
                }
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

extension CameraController {
    /// Writes a captured still to disk. When GPS tagging is on and a fix is
    /// available, the JPEG is copied through ImageIO with a GPS dictionary
    /// added (pixels untouched — the original encoded image is preserved).
    /// Any failure falls back to writing the raw data unmodified.
    fileprivate func writeCapturedPhoto(_ data: Data, to url: URL) -> Bool {
        let gpsDictionary: Any? = (gpsTaggingEnabled
            ? LocationService.shared.latestLocation?.exifGPSDictionary()
            : nil)
        // "Capture Flat": bake a low-contrast, desaturated grade into the JPEG
        // at save time (GPS carried along). On failure, fall through to writing
        // the original encoded bytes unmodified.
        if UserDefaults.standard.bool(forKey: FlatCapture.storageKey),
           FlatCapture.write(jpegData: data, to: url, gps: gpsDictionary) {
            return true
        }
        guard let gpsDictionary else {
            return (try? data.write(to: url)) != nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, uti, 1, nil) else {
            return (try? data.write(to: url)) != nil
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: gpsDictionary
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        if CGImageDestinationFinalize(destination) {
            return true
        }
        return (try? data.write(to: url)) != nil
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
            if self.writeCapturedPhoto(data, to: url) {
                self.photoURLs.append(url)
                let count = self.photoURLs.count
                DispatchQueue.main.async { self.photoCount = count }
                // Photo-mode frame cap: the timer stops scheduling once the
                // burst is requested (intervalTimer == nil); finalize when the
                // last requested still has landed.
                if let cap = self.intervalFrameCap, count >= cap, self.intervalTimer == nil {
                    self.finishIntervalOnQueue()
                }
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
    private static let stopFactorKey = "letslapse.capture.stopDisplayFactor"
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
    private static let blendDepthKey = "letslapse.capture.blendDepth"
    /// Photo mode's dials — its blend-frame count and whether Bulb (hold-open)
    /// is armed. Kept separate from Interval's `blendDepth` (which carries the
    /// adaptive Psycho/Safe cases Photo doesn't offer).
    private static let photoBlendDepthKey = "letslapse.capture.photoBlendDepth"
    private static let photoBulbModeKey = "letslapse.capture.photoBulbMode"

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
        // Video has no spacing, and Photo drives its own fixed burst rate —
        // neither remembers a user interval.
        case .video, .photo: return nil
        case .interval: return intervalSecondsKey
        }
    }

    /// Falls back to the pre-adaptive numeric key so an upgrade keeps the
    /// remembered fixed count.
    static var blendDepth: BlendDepth? {
        if let token = UserDefaults.standard.string(forKey: blendDepthKey),
           let depth = BlendDepth(token: token) {
            return depth
        }
        let legacy = UserDefaults.standard.integer(forKey: liveBlendFramesPerBlendKey)
        return (1...60).contains(legacy) ? .fixed(legacy) : nil
    }

    static func save(blendDepth: BlendDepth) {
        guard isEnabled else { return }
        UserDefaults.standard.set(blendDepth.token, forKey: blendDepthKey)
    }

    /// Photo mode's blend-frame count (1 = Off). Same 1...240 sanity bound the
    /// custom frame rate uses; out-of-range or unset returns nil so the caller
    /// keeps its default.
    static var photoBlendDepth: Int? {
        let value = UserDefaults.standard.integer(forKey: photoBlendDepthKey)
        return (1...240).contains(value) ? value : nil
    }

    static func save(photoBlendDepth: Int) {
        guard isEnabled else { return }
        UserDefaults.standard.set(photoBlendDepth, forKey: photoBlendDepthKey)
    }

    static var photoBulbMode: Bool? {
        UserDefaults.standard.object(forKey: photoBulbModeKey) as? Bool
    }

    static func save(photoBulbMode: Bool) {
        guard isEnabled else { return }
        UserDefaults.standard.set(photoBulbMode, forKey: photoBulbModeKey)
    }

    /// Remembered lens stop as its user-facing display factor. Falls back to
    /// the retired Lens-enum key so an upgrade keeps the user's lens — the
    /// old telephoto token maps to 4.0, which nearest-stop selection
    /// resolves to the device's tele stop (5× on a 16 Pro, 3× on a 15 Pro).
    static var stopDisplayFactor: Double? {
        if let value = UserDefaults.standard.object(forKey: stopFactorKey) as? Double,
           value > 0 {
            return value
        }
        switch UserDefaults.standard.string(forKey: lensKey) {
        case "ultraWide": return 0.5
        case "wide": return 1.0
        case "telephoto": return 4.0
        default: return nil
        }
    }

    static func save(stopFactor: Double) {
        guard isEnabled else { return }
        UserDefaults.standard.set(stopFactor, forKey: stopFactorKey)
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
        resolution: CameraController.CaptureResolution? = nil,
        frameRate: Int? = nil,
        rampFrameRate: Int? = nil,
        stabilization: Bool? = nil
    ) {
        guard isEnabled else { return }
        let defaults = UserDefaults.standard
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
            modeKey, lensKey, stopFactorKey, resolutionWidthKey, resolutionHeightKey,
            frameRateKey, rampFrameRateKey, stabilizationKey,
            intervalSecondsKey, liveBlendIntervalSecondsKey, liveBlendFramesPerBlendKey,
            blendDepthKey, photoBlendDepthKey, photoBulbModeKey,
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}
