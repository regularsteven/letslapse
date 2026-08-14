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
        // The camera the human picked in the Camera menu — Manage resolutions
        // must list what THIS camera offers, not the built-in webcam's list.
        let devices = CameraDevices.resolvedDevice().map { [$0] } ?? []
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
    /// Which burst rates each recording configuration can reach without the
    /// framing changing, probed once at configure from format metadata and
    /// cached across launches. Optional so a launch that somehow skipped the
    /// probe falls back to the live format scan rather than showing no rates
    /// at all. sessionQueue-confined.
    private var capabilityMatrix: DeviceCapabilityMatrix?
    /// The one lens a movie run records on, and the zoom factor that
    /// reproduces the selected stop on it. Taken at `startRecording`, held
    /// until `resetLiveCaptureState`. While it holds, nothing may swap the
    /// session input or re-derive zoom in virtual-device factor space — a
    /// shoot ends on the lens it started on. sessionQueue-confined.
    private var sequenceLensPin: (device: AVCaptureDevice, zoomFactor: CGFloat)?
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
    // Not private: `DeviceCapabilityMatrix.probe` reads formats with exactly
    // these criteria, so the matrix and the live scan can never disagree.
    static let preferredFrameRates = [10, 12, 15, 24, 25, 30, 50, 60, 100, 120, 240]
    private static let frameRateTolerance = 0.2
    /// ProRes codec subtypes (FourCC): 'apcn' 422, 'apch' 422 HQ,
    /// 'apcs' 422 LT, 'apco' 422 Proxy, 'ap4h' 4444, 'ap4x' 4444 XQ.
    static let proResFourCCs: Set<FourCharCode> = [
        0x6170636e, 0x61706368, 0x61706373, 0x6170636f, 0x61703468, 0x61703478,
    ]
    private var activeSequence: LiveCaptureSequence?
    private var activeSequenceDirectory: URL?
    private var activeSequenceStartedAt: Date?
    private var activeSegmentStartedAt: Date?
    /// When the segment's writer reported its first frame — the honest start
    /// stamp for the sidecar, where `activeSegmentStartedAt` is taken before
    /// `startRecording` and runs early by the writer's spin-up time.
    private var activeSegmentRecordedStartAt: Date?
    private var activeRecordingFrameRate: Int?
    private var activeSegmentURL: URL?
    private var segmentURLs: [URL] = []
    private var pendingRampFrameRate: Int?
    /// Both rates a running ramp sequence needs, empty outside one. While
    /// non-empty, `captureFormatMatch` prefers a format that carries every
    /// rate here, so the segment switch is a frame-duration change on one
    /// format instead of an `activeFormat` swap — no pipeline teardown, no
    /// auto-exposure reset, and a much smaller real-time hole at the cut.
    private var sequenceSharedRampRates: [Int] = []
    #if os(iOS)
    /// The AE/AWB values the sensor was using when a ramp segment switch
    /// began. Re-applied numerically after the reconfiguration so the next
    /// file starts photometrically identical instead of re-metered — the
    /// source-inherited one-frame luma blink at every cut. Confined to
    /// sessionQueue; nil when no switch hold is active.
    private struct SwitchExposureHold {
        var exposureDuration: CMTime
        var iso: Float
        var whiteBalanceGains: AVCaptureDevice.WhiteBalanceGains
    }
    private var switchExposureHold: SwitchExposureHold?
    #else
    /// macOS has no numeric exposure API — the hold is plain `.locked` modes.
    private var switchExposureHoldActive = false
    #endif
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
    @Published var isRecording = false {
        didSet { publishCaptureBusy() }
    }
    @Published var recordingStartedAt: Date?
    /// Start of the capture run in progress (video, interval, or Live Blend) —
    /// the "Stop at" anchor: stop amounts measure the whole run from here.
    /// Meaningful only while a run flag is true; the next start overwrites it.
    private(set) var captureRunStartedAt: Date?
    @Published var isIntervalRunning = false {
        didSet { publishCaptureBusy() }
    }
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
    /// Burst rates reachable from `selectedFrameRate` at `selectedResolution`
    /// that keep the framing and the colour identical — a strict subset of
    /// `availableFrameRates` above the base rate, narrowed by the capability
    /// matrix. Not every faster format on the sensor qualifies: a different
    /// field of view or codec would reframe the clip halfway through.
    @Published var availableBurstFrameRates: [Int] = []
    @Published var selectedRampFrameRate = 120 {
        didSet {
            guard selectedRampFrameRate != oldValue else { return }
            CaptureSessionLogger.shared.log("burst_set", ["fps": selectedRampFrameRate])
        }
    }
    @Published var isVideoStabilizationEnabled = true
    /// Whether this camera can stabilize at all — the gate on showing the
    /// toggle and the format pill's "· Stab" token.
    ///
    /// Always false on macOS, and not as a simplification: `AVCaptureConnection
    /// .preferredVideoStabilizationMode` is `API_UNAVAILABLE(macos)`, so no Mac
    /// camera — built-in, USB or Continuity — can be stabilized by AVFoundation
    /// at all. The toggle used to show there regardless, save a preference, and
    /// change nothing about the recording.
    @Published private(set) var supportsVideoStabilization = false
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
    @Published var isLiveBlendRunning = false {
        didSet { publishCaptureBusy() }
    }
    @Published var liveBlendOutputCount = 0 {
        didSet { checkScheduledStopCount() }
    }

    /// Mirrors "a shoot is running" onto the shared camera roster, so the Mac's
    /// Camera menu greys out instead of offering a switch the session would
    /// silently refuse. All three flags are written on the main thread.
    private func publishCaptureBusy() {
        #if os(macOS)
        CameraDevices.shared.setCaptureBusy(
            isRecording || isIntervalRunning || isLiveBlendRunning)
        #endif
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
    // sessionQueue-confined; the test-card rig's sparse preview tap. Unlike
    // the Live Blend output this one is REMOVED from the session when the rig
    // stops watching, so recordings never carry an extra output.
    private var testCardOutput: AVCaptureVideoDataOutput?
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

    /// The capture screen's current mode, mirrored here purely so the session
    /// log can name it ("Photo", "Bulb", "Interval", "Video"). The camera
    /// itself is mode-agnostic — it is told which run to start — so this is a
    /// label, never a switch. Set by CaptureView.
    var loggedCaptureMode = CaptureMode.video.rawValue

    /// What the session log should report as this session's frame count: the
    /// stills or blended outputs a run produced, else the recorded segment
    /// count. Whatever is truthfully known at teardown.
    private var loggedFrameCount: Int? {
        if photoCount > 0 { return photoCount }
        if liveBlendOutputCount > 0 { return liveBlendOutputCount }
        if segmentCount > 0 { return segmentCount }
        return nil
    }

    /// The live capture setup, for `session_start` / `format_change`. Reads
    /// the requested values (not the device's active format) so it is safe to
    /// call before the session has finished configuring.
    private func logFormatSnapshot() -> CaptureSessionLogger.FormatSnapshot {
        CaptureSessionLogger.FormatSnapshot(
            width: Int(selectedResolution.width),
            height: Int(selectedResolution.height),
            fps: selectedFrameRate,
            codec: selectedResolution.isProRes ? "ProRes" : "H.264/HEVC",
            stabilization: videoStabilizationStatus,
            appleLog: appleLogEnabled,
            lens: selectedStop?.chipLabel,
            mode: loggedCaptureMode)
    }

    func start() {
        LLog("start() called")
        installSessionLogging()
        #if os(macOS)
        installCameraSelectionObserver()
        #endif
        CaptureSessionLogger.shared.beginSession(
            mode: loggedCaptureMode, format: logFormatSnapshot())
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

    /// Closes this session's log: it ends the way a session is supposed to,
    /// so the file is written off and removed. Only a session that never
    /// reaches here — a crash, a force-quit — leaves a log behind for
    /// Incomplete Captures. Idempotent, and called from both ends of the
    /// capture screen's teardown (`stop()` and its disappear clean-up), since
    /// not every way out of that screen stops the camera.
    func endSessionLog(reason: String = "normal") {
        CaptureSessionLogger.shared.endSession(reason: reason, frameCount: loggedFrameCount)
    }

    func stop() {
        LLog("stop() called")
        endSessionLog()
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
        // Format introspection only — no session work, no sensor swap — so it
        // is safe here on the session queue before the session starts running.
        // Everything downstream (`refreshCaptureOptions`) reads its answers.
        capabilityMatrix = DeviceCapabilityMatrix.loadOrProbe(devices: allCaptureDevices())
        LLog("capability matrix: \(capabilityMatrix?.validBurstRates.count ?? 0) configurations"
             + " from \(allCaptureDevices().count) devices")
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

    /// Every camera the app can record through: the optics device, plus its
    /// physical constituents when it is a virtual multi-cam. The matrix needs
    /// all of them because a run can be pinned to a constituent, and the
    /// pickers must then describe that constituent's own formats.
    private func allCaptureDevices() -> [AVCaptureDevice] {
        #if os(macOS)
        // Every attached camera, not just the one in the session: one probe
        // then covers whatever the Camera menu switches to, so picking a
        // different camera doesn't invalidate the cache and re-probe. Reading
        // format lists opens no session, so the extra cameras cost nothing.
        return CameraDevices.connectedDevices()
        #else
        guard let optics = opticsDevice else { return [] }
        var devices = [optics]
        func append(_ device: AVCaptureDevice) {
            guard !devices.contains(where: { $0.uniqueID == device.uniqueID }) else { return }
            devices.append(device)
        }
        if optics.isVirtualDevice { optics.constituentDevices.forEach(append) }
        if let wide = Self.physicalWide(of: optics) { append(wide) }
        return devices
        #endif
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
            restoreStandardCaptureFormat()
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
        restoreStandardCaptureFormat()
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

    /// sessionQueue-confined: leave the DNG world — optics input back, then
    /// the pinned video format re-asserted on it (adding an input re-applies
    /// the session preset, so the pin never survives a swap on its own).
    private func restoreStandardCaptureFormat() {
        restoreOpticsInputIfNeeded()
        _ = applyCaptureFormat(resolution: selectedResolution, fps: selectedFrameRate)
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
            restoreStandardCaptureFormat()
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
        // The Mac has a bag of unrelated cameras rather than one stack, so the
        // choice is the human's — see CameraDevices and the Camera menu.
        // Thread-safe by design: this runs on `sessionQueue`.
        return CameraDevices.resolvedDevice()
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
                // The burst menu is read from the lens this stop would pin to,
                // so changing stops can change the answer (4K120 exists on the
                // wide and not on the tele). Deferred past the ramp:
                // `refreshCaptureOptions` re-applies `activeFormat`, which
                // resets the zoom factor and would snap the animation.
                self.sessionQueue.asyncAfter(deadline: .now() + 0.35) {
                    guard !self.movieOutput.isRecording, self.intervalTimer == nil,
                          !self.isLiveBlendActive else { return }
                    self.refreshCaptureOptions()
                }
            }
        }
    }

    #if os(iOS)
    /// The physical constituent `stop` natively sits on, paired with the zoom
    /// factor that reproduces the stop's framing there.
    ///
    /// Every stop is a crop of some optical stop: 5× is the tele at 1.0, the
    /// 2× sensor crop is the wide at 2.0 (which is where the quad-Bayer
    /// readout lives on the wide too), a digital 10× is the tele at 2.0. So
    /// the answer is the nearest optical stop at or below this one, and the
    /// ratio between them.
    private func physicalLens(
        for stop: DerivedOpticsStop
    ) -> (device: AVCaptureDevice, zoomFactor: CGFloat)? {
        guard let optics = opticsDevice, optics.isVirtualDevice else { return nil }
        let optical = fullStops
            .filter { $0.kind == .optical }
            .sorted { $0.displayFactor < $1.displayFactor }
        // 5% of slack, matching the derivation's own duplicate tolerance, so a
        // stop that IS an optical stop can't fall to the one below it.
        guard let native = optical.last(where: { $0.displayFactor <= stop.displayFactor * 1.05 })
                ?? optical.first,
              native.displayFactor > 0,
              let device = optics.constituentDevices
                .first(where: { $0.deviceType.rawValue == native.expectedBacking })
        else { return nil }
        return (device, CGFloat(max(stop.displayFactor / native.displayFactor, 1)))
    }

    /// sessionQueue-confined. Decides the run's lens once, before the first
    /// segment, and puts the session on it for the whole shoot.
    ///
    /// Segments re-set `activeFormat` between them, and on a virtual device
    /// that resets `videoZoomFactor` to 1 — the widest constituent. Getting
    /// back to the stop is a constituent hand-off, and `startNextSegment`
    /// starts the movie output straight into it. When the hand-off loses that
    /// race the whole segment records as a digital crop of the wrong lens:
    /// the 2026-08-06 report is one 5× take that shot segment 000 on the
    /// tele, 001 as a 5× crop of the wide (the physical-only burst rate), and
    /// 002 as a ~9× crop of the ultra-wide for its full 39 s — three lenses,
    /// two visible reframes, and a collapse in detail.
    ///
    /// Pinning the stop's own physical constituent removes the race and the
    /// stand-in swap together: no segment boundary can change the optical
    /// axis, because there is only ever one lens in the session. The stop is
    /// served as a crop of that lens, which is what it already was.
    ///
    /// Declines — loudly — when the lens can't shoot every rate the run needs
    /// at the locked resolution. A run that would have to drop the burst rate
    /// or the resolution is worse than one that keeps the old behaviour.
    private func pinLensForSequence(rates: [Int]) {
        // DNG owns the input while it is armed or running; the pin never
        // takes it from another world.
        guard sequenceLensPin == nil,
              !dngWorldActive,
              !physicalWorldActive,
              let stop = currentStop,
              let lens = physicalLens(for: stop)
        else { return }
        guard lens.device !== videoDevice else {
            sequenceLensPin = lens
            LLog("optics: run already on \(lens.device.localizedName) — pinned there")
            return
        }

        let name = lens.device.localizedName
        for fps in Set(rates)
        where captureFormatMatch(for: lens.device, resolution: selectedResolution, fps: fps) == nil {
            LLog("optics: \(name) cannot shoot \(selectedResolution.label)@\(fps)"
                 + " — run stays on the optics device, lens may change mid-shoot")
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: lens.device) else { return }

        session.beginConfiguration()
        let previousInput = videoInput
        if let previousInput { session.removeInput(previousInput) }
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            videoDevice = lens.device
            sequenceLensPin = lens
        } else if let previousInput {
            session.addInput(previousInput)
        }
        session.commitConfiguration()

        guard sequenceLensPin != nil else { return }
        LLog("optics: run pinned to \(name) at zoom "
             + "\(String(format: "%.2f", lens.zoomFactor)) for \(Set(rates).sorted())")
    }

    /// sessionQueue-confined. Hands the optics device back once the run that
    /// pinned a lens is over, and re-pins the resting format on it.
    private func releaseSequenceLensPin() {
        guard sequenceLensPin != nil else { return }
        sequenceLensPin = nil
        restoreOpticsInputIfNeeded()
        _ = applyCaptureFormat(resolution: selectedResolution, fps: selectedFrameRate)
        LLog("optics: run lens pin released")
    }

    /// sessionQueue-confined. Bounded wait for a virtual device to finish
    /// handing the framing to the constituent the stop belongs on.
    ///
    /// Only reachable when a run declined to pin a lens (single-camera
    /// hardware, or a lens that can't shoot the run's rates). There the
    /// hand-off race is still live, so a segment waits for it rather than
    /// recording minutes of upscaled ultra-wide. Half a second is longer than
    /// any hand-off observed and short against a segment; past it the segment
    /// starts anyway and says what it started on.
    private func awaitConstituentSettle() {
        guard sequenceLensPin == nil,
              let device = videoDevice, device.isVirtualDevice,
              let stop = currentStop,
              let expected = physicalDevice(for: stop),
              device.activePrimaryConstituent !== expected
        else { return }
        let deadline = Date().addingTimeInterval(0.5)
        while device.activePrimaryConstituent !== expected, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let landed = device.activePrimaryConstituent
        if landed !== expected {
            LLog("optics: segment starts on \(landed?.deviceType.rawValue ?? "none"),"
                 + " not \(expected.deviceType.rawValue) — hand-off did not settle")
        }
    }
    #endif

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
                restoreStandardCaptureFormat()
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

    #if os(macOS)
    private var cameraSelectionObserver: NSObjectProtocol?

    /// Follow the Camera menu. Also fires when the roster itself changes, which
    /// is what recovers the session when the camera being used is unplugged:
    /// `resolvedDevice()` then falls back and the session moves rather than
    /// freezing on a dead input.
    private func installCameraSelectionObserver() {
        guard cameraSelectionObserver == nil else { return }
        cameraSelectionObserver = NotificationCenter.default.addObserver(
            forName: CameraDevices.selectionDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.syncSelectedCaptureDevice()
        }
    }

    /// Point the running session at whichever camera the Camera menu (or the
    /// format sheet's picker) now names.
    ///
    /// Everything downstream has to be rebuilt, not just the input: a webcam
    /// and an iPhone over Continuity share no resolutions, no frame rates and
    /// no RAW answer. Re-probing the capability matrix here is the whole point
    /// of the exercise — the format sheet must describe *this* camera.
    func syncSelectedCaptureDevice() {
        sessionQueue.async {
            guard self.isConfigured else { return }
            // Mid-capture the camera is locked (the menu greys out to match),
            // and every reconfiguration below is refused anyway.
            guard !self.movieOutput.isRecording, self.intervalTimer == nil,
                  !self.isLiveBlendActive else { return }
            guard let device = Self.captureOpticsDevice() else { return }
            guard device.uniqueID != self.videoDevice?.uniqueID else { return }
            guard let input = try? AVCaptureDeviceInput(device: device) else {
                LLog("camera: \(device.localizedName) refused an input — staying put")
                return
            }

            self.session.beginConfiguration()
            let previousInput = self.videoInput
            if let previousInput { self.session.removeInput(previousInput) }
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                self.videoInput = input
                self.videoDevice = device
                self.opticsDevice = device
            } else if let previousInput {
                // Nothing has changed if this fails, so the session keeps
                // running on the camera it already had rather than going dark.
                self.session.addInput(previousInput)
                self.session.commitConfiguration()
                LLog("camera: session refused \(device.localizedName) — kept "
                     + "\(self.videoDevice?.localizedName ?? "none")")
                return
            }
            self.session.commitConfiguration()

            // The cached matrix is per-camera (see DeviceCapabilityMatrix's
            // device key), so this reads the new camera's own formats rather
            // than the previous one's.
            self.capabilityMatrix = DeviceCapabilityMatrix.loadOrProbe(devices: self.allCaptureDevices())
            self.deriveStops()
            self.refreshCaptureOptions()
            self.applyVideoStabilization()
            self.publishFormat()
            self.publishLiveBlendDNGSupport()
            LLog("camera: now on \(device.localizedName)"
                 + " (\(CameraDevices.connectionLabel(for: device)))")
        }
    }
    #endif

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

    /// The device a run started right now would actually shoot on — which is
    /// what the burst menu has to describe.
    ///
    /// `pinLensForSequence` puts every standard-world run on the stop's own
    /// physical constituent, so the rates that matter are that lens's, not the
    /// virtual device's. Apple publishes no 4K120 format on
    /// `builtInTripleCamera` at all, so reading the burst list off the optics
    /// device hid the wide's 4K120 from the picker on every iPhone that has it.
    /// The DNG and physical worlds own the input themselves (and the pin
    /// declines there), so they keep reading whatever is genuinely in the
    /// session.
    private func effectiveRecordingDevice(for stop: DerivedOpticsStop?) -> AVCaptureDevice? {
        #if os(iOS)
        if let optics = opticsDevice, optics.isVirtualDevice,
           !dngWorldActive, !physicalWorldActive,
           let stop, let lens = physicalLens(for: stop) {
            return lens.device
        }
        #endif
        return videoDevice
    }

    private func refreshCaptureOptions(
        preferredResolution: CaptureResolution? = nil,
        preferredFrameRate: Int? = nil
    ) {
        guard let device = videoDevice else { return }
        // While a run is pinned to one physical lens the menus must still
        // describe the optics device — reading the pinned constituent would
        // narrow them to its own list mid-session.
        #if os(iOS)
        let listDevice = sequenceLensPin != nil ? (opticsDevice ?? device) : device
        #else
        let listDevice = device
        #endif
        let supportedRates = supportedFrameRatesByResolution(for: listDevice)
        guard !supportedRates.isEmpty else {
            DispatchQueue.main.async {
                self.availableResolutions = []
                self.availableFrameRates = []
                self.availableBurstFrameRates = []
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
        let rateSet = supportedRates[resolution] ?? [30]
        let frameRates = Array(rateSet).sorted()
        let desiredFrameRate = preferredFrameRate ?? selectedFrameRate
        let frameRate = frameRates.contains(desiredFrameRate)
            ? desiredFrameRate
            : nearestFrameRate(to: desiredFrameRate, in: frameRates)
        // The burst menu is the matrix's answer, not "everything faster":
        // a faster format on a different optic (or codec) would reframe the
        // clip at the segment boundary. Unlike the base-rate menu it is asked
        // of the lens the run would pin to, not the optics device — see
        // `effectiveRecordingDevice`.
        let burstDevice = effectiveRecordingDevice(for: currentStop) ?? listDevice
        let burstRates = burstFrameRates(
            for: burstDevice,
            resolution: resolution,
            baseFrameRate: frameRate,
            allRates: rateSet)
        let rampFrameRate = burstRates.contains(selectedRampFrameRate)
            ? selectedRampFrameRate
            : (burstRates.first ?? selectedRampFrameRate)

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
            self.availableBurstFrameRates = burstRates
            self.selectedRampFrameRate = rampFrameRate
        }
    }

    /// The resolution → base-frame-rate map the pickers list, from the
    /// capability matrix when it has been probed (the stabilization filter
    /// this used to apply per format is one of the matrix's key fields now).
    /// The live format scan stays as the fallback for a controller whose
    /// `configure()` hasn't run.
    private func supportedFrameRatesByResolution(
        for device: AVCaptureDevice
    ) -> [CaptureResolution: Set<Int>] {
        if let matrix = capabilityMatrix {
            let rates = matrix.supportedFrameRatesByResolution(
                forDeviceKey: DeviceCapabilityMatrix.deviceKey(for: device),
                stabilizationEnabled: videoStabilizationRequested,
                // The base-rate menu has never been filtered by Capture Flat:
                // `applyCaptureFormat` falls back to sRGB on a format without
                // Apple Log rather than refusing it. Only the burst lookup
                // demands Apple Log, where losing it mid-clip would be a
                // colour shift partway through one finished clip.
                appleLogEnabled: false)
            if !rates.isEmpty { return rates }
        }
        var supportedRates: [CaptureResolution: Set<Int>] = [:]
        var candidateFrameRates = Self.preferredFrameRates
        if let custom = RecordingSettingsStore.customFrameRate,
           !candidateFrameRates.contains(custom) {
            candidateFrameRates.append(custom)
        }
        accumulateFrameRates(from: device, candidates: candidateFrameRates, into: &supportedRates)
        return supportedRates
    }

    /// Burst rates reachable from `baseFrameRate` at `resolution` without the
    /// framing or the colour changing — the matrix's whole reason to exist.
    /// Falls back to "everything faster at this resolution" (the pre-matrix
    /// behaviour) when the probe hasn't run.
    private func burstFrameRates(
        for device: AVCaptureDevice,
        resolution: CaptureResolution,
        baseFrameRate: Int,
        allRates: Set<Int>
    ) -> [Int] {
        #if os(iOS)
        let logRequested = appleLogEnabled
        #else
        let logRequested = false
        #endif
        if let matrix = capabilityMatrix,
           let rates = matrix.validBurstRates(
                for: device,
                resolution: resolution,
                stabilizationEnabled: videoStabilizationRequested,
                appleLogEnabled: logRequested,
                baseFPS: baseFrameRate) {
            return rates
        }
        return allRates.filter { $0 > baseFrameRate }.sorted()
    }

    /// Folds one device's formats into the resolution → frame-rate map.
    /// Keying by pixel dimensions (and the ProRes flag, which a physical
    /// camera only sets when it has ProRes formats of its own) is what unions
    /// a constituent's rates into the virtual device's buckets rather than
    /// spawning duplicate rows in the picker.
    private func accumulateFrameRates(
        from device: AVCaptureDevice,
        candidates candidateFrameRates: [Int],
        into supportedRates: inout [CaptureResolution: Set<Int>]
    ) {
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
    }

    static func supportedFrameRates(
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

    /// The frame duration to actually write on the device for a nominal rate.
    ///
    /// The menus match rates with `frameRateTolerance` of slack, deliberately:
    /// a webcam that runs at 30.00003 fps should read "30 fps" to a human. The
    /// DEVICE has no such slack. `activeVideoMinFrameDuration` outside the
    /// active format's advertised range raises an `NSInvalidArgumentException`
    /// — an Objective-C exception Swift cannot catch, so it aborts the process.
    ///
    /// That is exactly what selecting a DJI Osmo Action 4 did (crash report
    /// 2026-08-14, `-[AVCaptureDALDevice setActiveVideoMinFrameDuration:]`):
    /// its only range is 30.00003…30.00003 fps, and the nominal 1/30 sits a
    /// hair outside it. UVC cameras are full of these off-clock rates; iPhone
    /// formats are exact, which is why this never bit before the Mac could
    /// choose its camera.
    ///
    /// So: the nominal rate picks the range, and the range decides the
    /// duration. Clamping is safe in both directions because durations sort
    /// inversely to rates — `minFrameDuration` is the FASTEST rate.
    private static func frameDuration(
        forNominal fps: Int,
        in format: AVCaptureDevice.Format
    ) -> CMTime {
        let ideal = CMTime(value: 1, timescale: CMTimeScale(fps))
        let ranges = format.videoSupportedFrameRateRanges
        // The range the picker's own tolerance says this rate belongs to;
        // failing that the nearest one, so a format match never writes a
        // duration the format cannot take.
        let range = ranges.first { supportsFrameRate(Double(fps), in: $0) }
            ?? ranges.min {
                abs($0.maxFrameRate - Double(fps)) < abs($1.maxFrameRate - Double(fps))
            }
        guard let range else { return ideal }
        if CMTimeCompare(ideal, range.minFrameDuration) < 0 { return range.minFrameDuration }
        if CMTimeCompare(ideal, range.maxFrameDuration) > 0 { return range.maxFrameDuration }
        return ideal
    }

    private func nearestFrameRate(to preferred: Int, in frameRates: [Int]) -> Int {
        frameRates.min { first, second in
            abs(first - preferred) < abs(second - preferred)
        } ?? frameRates[0]
    }

    func selectRampFrameRate(_ fps: Int) {
        sessionQueue.async {
            guard !self.movieOutput.isRecording, self.intervalTimer == nil, !self.isLiveBlendActive else { return }
            // Only a composition-safe rate can be selected: anything else
            // would swap the optic (or the codec) mid-clip.
            let safeRates = self.availableBurstFrameRates
            let frameRate = safeRates.contains(fps)
                ? fps
                : (safeRates.first ?? self.selectedFrameRate)
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
            // A rate change that lands on the format already active (a ramp
            // segment switch under `sequenceSharedRampRates`) is a frame-
            // duration change only: re-assigning `activeFormat` would tear
            // the pipeline down and reset AE/zoom/colour space for nothing.
            let formatChanged = device.activeFormat != match.format
            if formatChanged {
                device.activeFormat = match.format
            }
            // Asked of the format being landed on, not the one still active.
            let duration = Self.frameDuration(forNominal: fps, in: match.format)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            selectedPhotoDimensions = match.photoDimensions
            if let photoDimensions = match.photoDimensions,
               !sameDimensions(photoOutput.maxPhotoDimensions, photoDimensions) {
                photoOutput.maxPhotoDimensions = photoDimensions
            }
            // Both re-asserts run even on the fast path: a new frame interval
            // can force a shorter shutter than the held/locked one, and both
            // helpers clamp against it.
            reassertExposureLock(on: device)
            #if os(iOS)
            if let hold = switchExposureHold, !exposureLocked {
                applySwitchExposureHold(hold, on: device)
            }
            // Setting `activeFormat` resets `videoZoomFactor` to 1 — and so
            // does re-adding a device input (the pin release swaps the
            // virtual camera back in at 1.0 = ultra-wide framing). Re-assert
            // the selected stop UNCONDITIONALLY: on the fast path the write
            // is a no-op, and gating it on `formatChanged` shipped a
            // viewfinder that came back from every ramp run at 0.5×
            // (2026-08-11). Only the `activeFormat` skip is the fast path.
            if let pin = sequenceLensPin, device === pin.device {
                // Pinned run: the stop is a crop of this one lens, and the
                // factor was worked out in that lens's own space at pin time.
                device.videoZoomFactor = min(
                    pin.zoomFactor, device.activeFormat.videoMaxZoomFactor)
            } else if !physicalWorldActive, let stop = currentStop {
                device.videoZoomFactor = min(
                    CGFloat(stop.rawFactor), device.activeFormat.videoMaxZoomFactor)
            }
            // Same rule for the colour space (self-guarded by the `!=`):
            // re-assert Apple Log if Capture Flat is on and the format
            // supports it (otherwise sRGB).
            if #available(iOS 17.2, *) {
                let target: AVCaptureColorSpace =
                    (appleLogEnabled && match.format.supportedColorSpaces.contains(.appleLog))
                    ? .appleLog : .sRGB
                if device.activeColorSpace != target {
                    device.activeColorSpace = target
                }
            }
            #else
            if switchExposureHoldActive, !exposureLocked {
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            }
            #endif
            if !sequenceSharedRampRates.isEmpty {
                LLog("applyCaptureFormat fps=\(fps) \(formatChanged ? "format switch" : "duration-only (shared format)")")
            }
            publishLiveBlendDNGSupport()
            return true
        } catch {
            return false
        }
    }

    /// Write a ramp switch's new frame duration EARLY — while the old segment
    /// is still recording — so the sensor has re-timed by the time the next
    /// file opens.
    ///
    /// A step up costs the ISP a few frames to re-time, and without this they
    /// land at the head of the NEW file: the 2026-08-13 shoot's "100 fps"
    /// burst opened with four frames still at the base 25 fps cadence (40,
    /// 40, 80, 40 ms — one frame dropped outright as the change landed), so
    /// its 820 frames over 8.355 s averaged 98.14. That average is what
    /// QuickTime shows and what `sourceSegmentFPS` probes, even though the
    /// file is a dead-steady 100.06 from frame 4 on. Held here, those frames
    /// stay in the old segment's tail instead, where a 12-minute base
    /// segment absorbs them invisibly.
    ///
    /// Only safe on the shared-format fast path, and gated on it: assigning
    /// `activeFormat` tears the pipeline down, which under a live movie
    /// writer kills the recording. When the target rate needs a different
    /// format this returns false and the caller keeps today's ordering
    /// exactly. On the fast path it is a frame-duration write only and
    /// delivery does NOT stop — which is precisely why those four
    /// transitional frames existed to be measured.
    ///
    /// sessionQueue-confined, like every other device configuration here.
    private func prepareRampRateChange(to fps: Int) -> Bool {
        guard let device = videoDevice,
              let match = captureFormatMatch(
                for: device, resolution: selectedResolution, fps: fps),
              device.activeFormat == match.format
        else { return false }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let duration = Self.frameDuration(forNominal: fps, in: match.format)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            // The new interval can force a shorter shutter than the held or
            // locked one — same clamp-and-trade-ISO the format path runs.
            reassertExposureLock(on: device)
            #if os(iOS)
            if let hold = switchExposureHold, !exposureLocked {
                applySwitchExposureHold(hold, on: device)
            }
            #else
            if switchExposureHoldActive, !exposureLocked {
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            }
            #endif
            return true
        } catch {
            return false
        }
    }

    /// How long to hold after a step-up's early frame-duration write before
    /// stopping the old segment. The transient is made of OLD-rate frames
    /// (four of them, spanning 0.20 s, on the 2026-08-13 25→100 shoot), so it
    /// scales with the rate being left, not the one being entered. Clamped so
    /// a very slow base can't stall the switch — `beginTimedBurst` gives up
    /// on a switch after 3 s — and a fast one still waits long enough to
    /// matter. `Segment.settleSeconds` is the feedback loop for this number.
    private static func rampSettleSeconds(leaving fps: Int) -> TimeInterval {
        min(0.6, max(0.2, 6 / Double(max(1, fps))))
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
            // `.locked` being supported does NOT imply the device can lock at an
            // arbitrary lens position — the ultra-wide reports the former and not
            // the latter, and passing a custom value there raises
            // NSInvalidArgumentException. `currentLensPosition` is the sentinel
            // for "lock wherever you already are", which every device accepts.
            let position = device.isLockingFocusWithCustomLensPositionSupported
                ? lockedLensValue
                : AVCaptureDevice.currentLensPosition
            device.setFocusModeLocked(lensPosition: position, completionHandler: nil)
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

    // MARK: - Segment-switch exposure hold

    /// Freeze AE/AWB at their current values before a ramp segment switch
    /// tears the pipeline down. The values are what the loop is outputting
    /// right now, so nothing visible changes — but the next file can start
    /// on them instead of re-metering, which is where the one-frame luma
    /// step at every cut came from. No-op under the user's manual lock
    /// (`reassertExposureLock` already carries that across formats).
    ///
    /// `completion` fires on the sessionQueue once the custom exposure has
    /// actually LATCHED (or after a timeout) — the auto→custom transition
    /// takes the ISP a few frames, and stopping the old segment before it
    /// lands puts those frames at the head of the next file instead (a
    /// 2-hot-2-low ~4-frame flicker, measured on the 2026-08-11 iPhone
    /// shoot). Callers gate the switch's `stopRecording` on it; the latch
    /// frames then stay in the old segment's tail, at values identical to
    /// what AE was already outputting.
    private func beginSwitchExposureHold(completion: @escaping () -> Void) {
        guard !exposureLocked, let device = videoDevice else { completion(); return }
        #if os(iOS)
        guard switchExposureHold == nil else { completion(); return }
        let hold = SwitchExposureHold(
            exposureDuration: device.exposureDuration,
            iso: device.iso,
            whiteBalanceGains: device.deviceWhiteBalanceGains
        )
        switchExposureHold = hold
        // Once, whichever comes first: the device's latch callback or the
        // fallback (a device that never calls back must not wedge the
        // switch). Mutation confined to sessionQueue.
        var completed = false
        let finish = {
            guard !completed else { return }
            completed = true
            completion()
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            applySwitchExposureHold(hold, on: device) { [weak self] in
                guard let self else { return }
                self.sessionQueue.async(execute: finish)
            }
        } catch {}
        sessionQueue.asyncAfter(deadline: .now() + 0.6, execute: finish)
        LLog(String(format: "switch exposure hold: 1/%.0fs ISO %.0f",
                    1 / max(hold.exposureDuration.seconds, 0.0001), hold.iso))
        #else
        defer { completion() }
        guard !switchExposureHoldActive else { return }
        switchExposureHoldActive = true
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
        } catch {}
        LLog("switch exposure hold (locked modes)")
        #endif
    }

    #if os(iOS)
    /// Re-assert the held values on the (possibly new) format. Runs inside
    /// the caller's `lockForConfiguration`. A burst rate's frame interval can
    /// force a shorter shutter than the held one — trade the lost light back
    /// in ISO so the two files still match in luma, not just in mode.
    /// `latched` (arbitrary queue) reports when the exposure has taken
    /// effect; it may never fire if custom exposure is unsupported.
    private func applySwitchExposureHold(
        _ hold: SwitchExposureHold,
        on device: AVCaptureDevice,
        latched: (() -> Void)? = nil
    ) {
        let format = device.activeFormat
        var seconds = hold.exposureDuration.seconds
        var iso = hold.iso
        var ceiling = format.maxExposureDuration.seconds
        let frameDuration = device.activeVideoMaxFrameDuration
        if frameDuration.isValid, frameDuration.seconds > 0 {
            ceiling = min(ceiling, frameDuration.seconds)
        }
        if seconds > ceiling, ceiling > 0 {
            iso *= Float(seconds / ceiling)
            seconds = ceiling
        }
        seconds = max(seconds, format.minExposureDuration.seconds)
        iso = min(max(iso, format.minISO), format.maxISO)
        if device.isExposureModeSupported(.custom) {
            device.setExposureModeCustom(
                duration: CMTimeMakeWithSeconds(seconds, preferredTimescale: 1_000_000),
                iso: iso,
                completionHandler: latched.map { callback in { _ in callback() } }
            )
        }
        if device.isWhiteBalanceModeSupported(.locked) {
            var gains = hold.whiteBalanceGains
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1), maxGain)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }
    }
    #endif

    /// Let AE/AWB go again once it can't read as a step at a cut. Called a
    /// beat into a base-rate segment (burst segments stay held whole — both
    /// of their cuts must match, and they're short); the loop resumes from
    /// the held values, so any adaptation is ordinary in-scene drift.
    private func endSwitchExposureHold() {
        #if os(iOS)
        guard switchExposureHold != nil else { return }
        switchExposureHold = nil
        #else
        guard switchExposureHoldActive else { return }
        switchExposureHoldActive = false
        #endif
        guard !exposureLocked, let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        } catch {}
        LLog("switch exposure hold released")
    }

    /// The release path from a segment's first written frame: base-rate
    /// segments release after a settling beat, anything else keeps holding.
    /// Guarded against the segment having already switched again — the next
    /// first-frame callback reschedules.
    private func scheduleSwitchExposureHoldRelease() {
        #if os(iOS)
        guard switchExposureHold != nil else { return }
        #else
        guard switchExposureHoldActive else { return }
        #endif
        guard let sequence = activeSequence,
              activeRecordingFrameRate == sequence.baseFrameRate else { return }
        let url = activeSegmentURL
        sessionQueue.asyncAfter(deadline: .now() + 1.0) {
            // A switch requested inside the settling beat still needs the
            // hold — keep it; the switch's own first frame reschedules.
            guard self.activeSegmentURL == url,
                  self.movieOutput.isRecording,
                  self.pendingRampFrameRate == nil else { return }
            self.endSwitchExposureHold()
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
                // Ramp runs first prefer a format that carries BOTH of the
                // run's rates: base and burst queries then resolve to the
                // same format, the segment switch collapses to a frame-
                // duration change, and every segment shares one
                // stabilization mode and one pipeline. Ranked above the
                // stabilization score — one consistent format beats a
                // fancier mode on only some segments. Outside a ramp run
                // the list is empty and this key is inert.
                if !sequenceSharedRampRates.isEmpty {
                    let firstShared = formatSupportsRates(first.format, sequenceSharedRampRates)
                    let secondShared = formatSupportsRates(second.format, sequenceSharedRampRates)
                    if firstShared != secondShared {
                        return firstShared
                    }
                }
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

    private func formatSupportsRates(_ format: AVCaptureDevice.Format, _ rates: [Int]) -> Bool {
        rates.allSatisfy { fps in
            format.videoSupportedFrameRateRanges.contains { range in
                Self.supportsFrameRate(Double(fps), in: range)
            }
        }
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
        // Every reconfiguration lands here, so this is the one honest place to
        // log what the camera is actually set to — from the device's active
        // format, not from what was requested. The logger drops repeats (a
        // burst re-publishes the same format on every segment switch).
        let subType = CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
        CaptureSessionLogger.shared.logFormatChange(CaptureSessionLogger.FormatSnapshot(
            width: Int(dims.width),
            height: Int(dims.height),
            fps: fps,
            codec: Self.proResFourCCs.contains(subType) ? "ProRes" : "H.264/HEVC",
            stabilization: stabilizationStatus,
            appleLog: activeColorSpaceIsAppleLog(device),
            lens: selectedStop?.chipLabel,
            mode: loggedCaptureMode))
        DispatchQueue.main.async {
            self.videoStabilizationStatus = stabilizationStatus
            self.activeFormatDescription = line
            if self.previewDimensions != preview {
                self.previewDimensions = preview
            }
        }
    }

    /// Whether the camera is actually shooting Apple Log right now. Asked of
    /// the device rather than of `appleLogEnabled`: a format without Log
    /// support silently stays sRGB, and the log should record what happened.
    private func activeColorSpaceIsAppleLog(_ device: AVCaptureDevice) -> Bool {
        #if os(iOS)
        if #available(iOS 17.2, *) {
            return device.activeColorSpace == .appleLog
        }
        #endif
        return false
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

    /// Whether the camera in the session offers stabilization on *any* of its
    /// formats. Asked of the whole format list rather than the active one:
    /// the toggle's job is to steer which format gets picked, so a camera that
    /// can stabilize at 1080p but not 4K still has a live toggle.
    /// sessionQueue-confined.
    private func publishStabilizationSupport() {
        #if os(iOS)
        let supported = videoDevice.map { device in
            device.formats.contains { stabilizationMode(for: $0) != nil }
        } ?? false
        #else
        let supported = false
        #endif
        DispatchQueue.main.async {
            if self.supportsVideoStabilization != supported {
                self.supportsVideoStabilization = supported
            }
        }
    }

    private func applyVideoStabilization() {
        publishStabilizationSupport()
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
                CaptureSessionLogger.shared.log("exposure_lock", [
                    "iso": iso,
                    "shutterSeconds": duration.seconds,
                    "shutterLabel": "1/\(Int((1 / max(duration.seconds, 0.000001)).rounded()))",
                    "lensPosition": lens,
                ])
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
                // The Mac locks by mode, not by custom ISO/shutter values —
                // there are none to record.
                CaptureSessionLogger.shared.log("exposure_lock", ["mode": "locked"])
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
                CaptureSessionLogger.shared.log("exposure_unlock")
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
                // Devices that support `.locked` but not a custom lens position
                // (the ultra-wide) throw on an explicit value — lock them where
                // they are and report back the position they actually hold.
                let custom = device.isLockingFocusWithCustomLensPositionSupported
                device.setFocusModeLocked(
                    lensPosition: custom ? clamped : AVCaptureDevice.currentLensPosition,
                    completionHandler: nil
                )
                let applied = custom ? clamped : device.lensPosition
                self.lockedLensValue = applied
                DispatchQueue.main.async {
                    self.lockedLensPosition = applied
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
            // The rig's preview tap must be gone BEFORE the writer starts —
            // synchronously, on this queue. The view's own detach arrives a
            // beat later and would reconfigure the session under the
            // recording (see detachTestCardTapNow).
            self.detachTestCardTapNow()
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
            // One lens per sequence, alongside one orientation per sequence:
            // decided here from every rate the run can reach, held to the last
            // segment (see pinLensForSequence).
            var runRates = [baseFrameRate]
            if mode == .ramp { runRates.append(self.selectedRampFrameRate) }
            self.pinLensForSequence(rates: runRates)
            #endif
            // One format per sequence when the sensor offers it, alongside
            // one lens and one orientation: with both rates on a single
            // format, every segment switch is a frame-duration change (see
            // sequenceSharedRampRates). Set before the first segment so the
            // run opens on the shared format rather than switching onto it.
            self.sequenceSharedRampRates =
                mode == .ramp && baseFrameRate != self.selectedRampFrameRate
                ? [baseFrameRate, self.selectedRampFrameRate] : []
            CaptureSessionLogger.shared.log("burst_set", [
                "fps": self.selectedRampFrameRate,
                "mode": mode.rawValue,
                "baseFPS": baseFrameRate,
            ])
            CaptureSessionLogger.shared.log("capture_start", [
                "kind": "video",
                "fps": baseFrameRate,
                "resolution": "\(resolution.width)x\(resolution.height)",
                "sequenceMode": mode.rawValue,
            ])
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

    /// `source` names who asked, for the session log only — the stop itself is
    /// identical whichever way it arrives.
    func stopRecording(source: CaptureSessionLogger.StopSource = .phone) {
        CaptureSessionLogger.shared.log("stop_requested", ["source": source.rawValue, "kind": "video"])
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

    // MARK: - Test-card rig tap

    /// Attach the rig's sparse preview tap (see TestCardRig.swift). Safe to
    /// call repeatedly; the output is created once and re-added as needed.
    /// Refused outright while any capture is in flight: the view's
    /// idle-detection is main-thread state that can lag the session queue,
    /// and adding an output reconfigures the session under a live movie
    /// writer — which kills it (see detachTestCardTapNow).
    func startTestCardTap(_ tap: TestCardFrameTap) {
        sessionQueue.async {
            guard !self.movieOutput.isRecording,
                  self.activeSequence == nil,
                  !self.intervalActive else {
                LLog("testcard: tap refused — capture in flight")
                return
            }
            let output: AVCaptureVideoDataOutput
            if let existing = self.testCardOutput {
                output = existing
            } else {
                output = AVCaptureVideoDataOutput()
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ]
                output.alwaysDiscardsLateVideoFrames = true
                self.testCardOutput = output
            }
            if !self.session.outputs.contains(output) {
                self.session.beginConfiguration()
                if self.session.canAddOutput(output) {
                    self.session.addOutput(output)
                } else {
                    LLog("testcard: session refused the preview tap")
                }
                self.session.commitConfiguration()
            }
            output.setSampleBufferDelegate(tap, queue: tap.queue)
        }
    }

    /// Detach the rig's tap entirely so a recording (test run or manual)
    /// starts with the session exactly as it would be without the rig.
    func stopTestCardTap() {
        sessionQueue.async {
            self.detachTestCardTapNow()
        }
    }

    /// sessionQueue-confined, synchronous detach. Capture starts call this
    /// INLINE before touching the movie output: the view-driven
    /// `stopTestCardTap` rides a main-thread `.onChange` and lands on this
    /// queue AFTER `startRecording` — a session reconfiguration under a
    /// starting writer, which dies with -11805 "Cannot Record" or -11818
    /// "Recording Stopped" on its first frame (2026-08-11: every recording
    /// in Video mode was a one-frame dud while the rig's tap was attached).
    private func detachTestCardTapNow() {
        guard let output = testCardOutput else { return }
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.outputs.contains(output) {
            session.beginConfiguration()
            session.removeOutput(output)
            session.commitConfiguration()
            LLog("testcard: tap detached")
        }
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
            // Freeze AE/AWB at today's values before the pipeline goes down,
            // so the next file opens on them instead of re-metering. The stop
            // waits for the exposure latch: pendingRampFrameRate is set FIRST
            // so re-entry (this method's top guard) and the timed-burst wait
            // loops already see the switch as in flight during the wait.
            pendingRampFrameRate = targetFrameRate
            beginSwitchExposureHold { [weak self] in
                guard let self else { return }
                // Then the CADENCE latch, on the same principle: write the new
                // frame duration now and hold, so the sensor's re-timing frames
                // stay in this segment's tail instead of opening the next file
                // at the wrong rate. A step DOWN needs no wait — slowing down
                // just means waiting longer between reads, and the 2026-08-13
                // shoot's 100→25 segment is clean from its first frame.
                guard targetFrameRate > currentFrameRate,
                      self.prepareRampRateChange(to: targetFrameRate)
                else {
                    LLog("rampSettle \(currentFrameRate)→\(targetFrameRate): skipped ("
                        + (targetFrameRate > currentFrameRate
                            ? "format change needed" : "step down") + ")")
                    self.movieOutput.stopRecording()
                    return
                }
                let settle = Self.rampSettleSeconds(leaving: currentFrameRate)
                LLog(String(format: "rampSettle %d→%d: hold %.2fs",
                            currentFrameRate, targetFrameRate, settle))
                self.sessionQueue.asyncAfter(deadline: .now() + settle) {
                    // The user's Stop can land inside the hold — it takes the
                    // recording with it, and the delegate's own ordering
                    // already lets it win. Don't fire a second stop into
                    // whatever comes next.
                    guard self.movieOutput.isRecording, !self.isFinishingSequence else {
                        LLog("rampSettle: hold elapsed after the run already stopped")
                        return
                    }
                    self.movieOutput.stopRecording()
                }
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
        CaptureSessionLogger.shared.log("burst_start", [
            "index": interval.index,
            "atSeconds": interval.relativeStart,
            "fps": sequence.rampFrameRate ?? selectedRampFrameRate,
            "mode": sequence.mode.rawValue,
        ])
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
        CaptureSessionLogger.shared.log("burst_end", [
            "index": sequence.rampIntervals[index].index,
            "atSeconds": relativeEnd,
            "durationSeconds": relativeEnd - sequence.rampIntervals[index].relativeStart,
        ])
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
        // Every segment records on the device the run started on: the burst
        // rate is a format change, never an input change. The rates the picker
        // offers are exactly the ones this device can shoot without one (see
        // DeviceCapabilityMatrix).
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

        #if os(iOS)
        // Unpinned runs only: don't start recording into a constituent
        // hand-off that hasn't landed yet.
        awaitConstituentSettle()
        #endif

        let index = segmentURLs.count
        let url = directory.appendingPathComponent(String(format: "segment-%03d.mov", index))
        activeSegmentURL = url
        activeSegmentStartedAt = Date()
        // The honest stamp arrives from the writer's did-start callback; a
        // leftover from the previous segment must never masquerade as it.
        activeSegmentRecordedStartAt = nil
        activeRecordingFrameRate = frameRate
        #if os(iOS)
        LLog("segment \(String(format: "%03d", index)) start: running=\(session.isRunning)"
            + " interrupted=\(session.isInterrupted) inputs=\(session.inputs.count)"
            + " fps=\(frameRate)")
        #else
        LLog("segment \(String(format: "%03d", index)) start: running=\(session.isRunning)"
            + " inputs=\(session.inputs.count) fps=\(frameRate)")
        #endif
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
        // Honest stamps: where the file's frames actually sit on the run's
        // clock. The wall-clock bracket above stays for the UI strip and old
        // renderers; the warp compiler prefers these to measure the real
        // inter-file hole instead of estimating it.
        let recordedStart = activeSegmentRecordedStartAt?.timeIntervalSince(startedAt)
        let timing = Self.probeSegmentTiming(outputFileURL)
        let segment = LiveCaptureSequence.Segment(
            index: index,
            fileName: outputFileURL.lastPathComponent,
            frameRate: frameRate,
            relativeStart: relativeStart,
            relativeEnd: relativeEnd,
            recordedStart: recordedStart,
            recordedDuration: timing.duration,
            measuredFrameRate: timing.measuredFrameRate,
            steadyFrameRate: timing.steadyFrameRate,
            settleSeconds: timing.settleSeconds
        )
        if let recordedStart, let recordedDuration = timing.duration {
            LLog(String(
                format: "segment %03d honest: %.3f +%.3fs (bracket %.3f–%.3f)",
                index, recordedStart, recordedDuration, relativeStart, relativeEnd))
        }
        if let measured = timing.measuredFrameRate {
            // asked vs measured is the 98.14-for-100 gap; settle is how much
            // of it was the switch still landing inside this file.
            LLog(String(
                format: "segment %03d cadence: asked %d measured %.3f steady %.3f settle %.3fs",
                index, frameRate, measured,
                timing.steadyFrameRate ?? measured, timing.settleSeconds ?? 0))
        }
        sequence.segments.append(segment)
        activeSequence = sequence
        segmentURLs.append(outputFileURL)
        activeSegmentStartedAt = nil
        activeSegmentRecordedStartAt = nil
        activeSegmentURL = nil
        activeRecordingFrameRate = nil
    }

    /// What a finished segment file says about its own timing.
    private struct SegmentTiming {
        var duration: Double?
        var measuredFrameRate: Double?
        var steadyFrameRate: Double?
        var settleSeconds: Double?
    }

    /// Timing of a finished segment file — the QuickTime header's own answers,
    /// read synchronously (milliseconds against the finalize that just
    /// completed on this queue). Every field is nil when the file can't say.
    private static func probeSegmentTiming(_ url: URL) -> SegmentTiming {
        final class Box: @unchecked Sendable { var timing = SegmentTiming() }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        // userInitiated: the session queue blocks on this — a default-priority
        // task under it trips the Thread Performance Checker's inversion
        // warning (seen 2026-08-11).
        Task.detached(priority: .userInitiated) {
            defer { semaphore.signal() }
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration),
                  duration.seconds.isFinite, duration.seconds > 0
            else { return }
            let seconds = duration.seconds
            box.timing.duration = seconds
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let measured = try? await track.load(.nominalFrameRate), measured > 0
            else { return }
            box.timing.measuredFrameRate = Double(measured)
            guard let settle = settlePoint(in: headFrameDurations(asset, track)) else { return }
            let remaining = seconds - settle.seconds
            guard remaining > 0 else { return }
            // The head's own frames are the only ones off-cadence, so the
            // steady rate is what's left once they're taken off both sides.
            let total = Double(measured) * seconds
            box.timing.settleSeconds = settle.seconds
            box.timing.steadyFrameRate = (total - Double(settle.frames)) / remaining
        }
        semaphore.wait()
        return box.timing
    }

    /// Bound on the settle probe's head read. This runs on the sessionQueue at
    /// a segment boundary, so walking all 18k samples of a 12-minute base
    /// segment is not on the table — and the transient it looks for is four
    /// frames long.
    private static let settleProbeSampleLimit = 48

    /// The first frame intervals of a file, from sample REFERENCES — the
    /// reader hands back timing without decoding a single pixel (1.5–2 ms even
    /// on a 1.7 GB segment). Differenced from presentation stamps rather than
    /// read per-sample so it holds up whether or not the muxer wrote sample
    /// durations.
    private static func headFrameDurations(
        _ asset: AVURLAsset, _ track: AVAssetTrack
    ) -> [Double] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderSampleReferenceOutput(track: track)
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        defer { reader.cancelReading() }
        // Collect DOUBLE the window. References arrive chunk-interleaved
        // rather than in presentation order (measured: 0, 0, 0.16, 0.08,
        // 0.04, 0.12 …), so sorting a tight window strands a later sample at
        // the end and invents one huge final interval — which read as "the
        // cadence never settles" on every base segment. Sorting a window
        // twice the size and keeping only its front half discards the
        // stragglers instead.
        var times: [Double] = []
        while times.count < settleProbeSampleLimit * 2,
              let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if pts.isValid, pts.seconds.isFinite { times.append(pts.seconds) }
        }
        guard times.count >= 2 else { return [] }
        times.sort()
        // Strictly increasing: the reference output repeats the first stamp,
        // and a duplicate would read as a zero-length frame.
        var ordered: [Double] = []
        for time in times where ordered.last.map({ time > $0 }) ?? true {
            ordered.append(time)
            if ordered.count > settleProbeSampleLimit { break }
        }
        guard ordered.count >= 2 else { return [] }
        return zip(ordered.dropFirst(), ordered).map { $0 - $1 }
    }

    /// Where a file's cadence latches. `steady` is the median of the window's
    /// back half — past any head transient by construction — and the settle
    /// point is just after the last sampled frame that missed it.
    private static func settlePoint(in durations: [Double]) -> (seconds: Double, frames: Int)? {
        guard durations.count >= 8 else { return nil }
        let back = durations[(durations.count / 2)...].sorted()
        let steady = back[back.count / 2]
        guard steady > 0 else { return nil }
        var frames = 0
        for (offset, duration) in durations.enumerated()
        where abs(duration - steady) / steady > 0.25 {
            frames = offset + 1
        }
        guard frames < durations.count else { return nil }
        return (durations.prefix(frames).reduce(0, +), frames)
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
        // Cleared FIRST: both the pin release and the base-rate restore
        // re-apply a resting format, and each should pick with the normal
        // preference, not the run's shared-rates one (the 2026-08-11 stop
        // log showed the release picking "(shared format)" and the restore
        // re-picking right after).
        sequenceSharedRampRates = []
        // A run that pinned a lens leaves the session on that constituent —
        // hand the optics device back before the resting format is re-pinned;
        // then let AE/AWB go if a hold is still standing (a run can end
        // mid-burst).
        #if os(iOS)
        releaseSequenceLensPin()
        #endif
        restoreBaseFrameRateIfNeeded()
        endSwitchExposureHold()
        timedBurstGeneration += 1
        activeSequence = nil
        activeSequenceDirectory = nil
        activeSequenceStartedAt = nil
        #if os(iOS)
        activeSequenceOrientation = nil
        #endif
        activeSegmentStartedAt = nil
        activeSegmentRecordedStartAt = nil
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
            // Same ordering rule as startRecording: the rig's tap detaches
            // inline before any capture work.
            self.detachTestCardTapNow()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("interval-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.photoDirectory = directory
            self.photoURLs = []
            self.intervalFrameCap = frameCap
            self.intervalFramesRequested = 0
            self.intervalActive = true
            CaptureSessionLogger.shared.log("capture_start", [
                "kind": "interval",
                "intervalSeconds": seconds,
                "frameCap": frameCap ?? 0,
            ])
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

    func stopInterval(source: CaptureSessionLogger.StopSource = .phone) {
        CaptureSessionLogger.shared.log("stop_requested", ["source": source.rawValue, "kind": "interval"])
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
        CaptureSessionLogger.shared.log("capture_end", ["kind": "interval", "frameCount": urls.count])
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
            stopRecording(source: .scheduled)
        } else if isIntervalRunning {
            stopInterval(source: .scheduled)
        } else if isLiveBlendRunning {
            // The user asked for an exact count/time; the window in progress
            // is beyond it, so it is dropped rather than kept as a partial.
            stopLiveBlend(keepPartial: false, source: .scheduled)
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
            CaptureSessionLogger.shared.log("capture_start", [
                "kind": "liveBlend",
                "intervalSeconds": interval,
                "framesPerBlend": depth.fixedFrames ?? 0,
                "preferDNG": preferDNG,
            ])

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
            restoreStandardCaptureFormat()
            deriveStops()
        }
        publishFormat()
    }
    #endif

    /// Graceful stop: the partial window is kept when it has frames (unless
    /// `keepPartial` is false — a scheduled "stop at N" wants exactly N),
    /// then the finish handler fires with everything completed so far.
    func stopLiveBlend(keepPartial: Bool = true, source: CaptureSessionLogger.StopSource = .phone) {
        CaptureSessionLogger.shared.log("stop_requested", [
            "source": source.rawValue, "kind": "liveBlend", "keepPartial": keepPartial,
        ])
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

    /// The writer's first frame just landed — the honest start of this file,
    /// where `startNextSegment`'s wall stamp runs ~0.27s early (writer
    /// spin-up). Stamped before the queue hop; the callback is the event.
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        let stampedAt = Date()
        sessionQueue.async {
            guard fileURL == self.activeSegmentURL else { return }
            self.activeSegmentRecordedStartAt = stampedAt
            if let startedAt = self.activeSegmentStartedAt {
                LLog(String(
                    format: "segment writer rolling %.3fs after startRecording",
                    stampedAt.timeIntervalSince(startedAt)))
            }
            // The new segment is demonstrably delivering frames — the switch
            // hold has done its job once this segment is a base-rate one.
            self.scheduleSwitchExposureHoldRelease()
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // A recording that dies uninvited surfaces ONLY here — without this
        // line the failure is silent (the 2026-08-11 instant-death hunt had
        // to be diagnosed from file sizes). Note: a successful stop also
        // passes an error on some paths (e.g. "recording stopped" markers),
        // so log, don't react.
        if let error {
            LLog("didFinishRecording \(outputFileURL.lastPathComponent) error: \(error)")
        }
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

            // The user's Stop wins over a switch still in flight: with both
            // flags set, honouring pendingRampFrameRate first would spawn a
            // segment nobody can stop. (Reachable when Stop lands inside the
            // toggle→finalize window; the exposure-latch wait widens it.)
            if self.isFinishingSequence {
                self.completeLiveCapture()
                return
            }

            if let nextFrameRate = self.pendingRampFrameRate {
                self.pendingRampFrameRate = nil
                self.startNextSegment(frameRate: nextFrameRate)
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
