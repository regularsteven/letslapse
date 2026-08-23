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
    // Holy Grail — the auto-ramping interval shoot. All sessionQueue-confined.
    // `holyGrailEngine` is the exposure policy (a pure struct in the Kit);
    // `holyGrailWriter` appends the per-frame sidecar; `holyGrailPending`
    // gates a tick while the previous frame's exposure is still settling, so
    // a slow frame skips its slot instead of stacking up behind it.
    private var holyGrailEngine: HolyGrailRampEngine?
    private var holyGrailLimits: HolyGrailRampEngine.HardwareLimits?
    private var holyGrailWriter: FrameTimestampWriter?
    /// The clamped exposure most recently WRITTEN to the device by the ramp.
    /// The DNG bracket path reads it (from the session queue, hence the lock)
    /// so per-shot bracket settings carry the ramp's exposure instead of
    /// silently overriding it — the 2026-08-20 field test lost two sunset
    /// runs to auto-exposure brackets resolving against an AE loop that
    /// `.custom` mode had frozen. nil outside holy-grail runs.
    private let holyGrailAppliedExposure = HolyGrailAppliedExposureHolder()
    private var holyGrailActive = false
    private var holyGrailPending = false
    private var holyGrailRawPixelFormat: OSType?
    private var holyGrailArmedPhotoAspect = false
    private var holyGrailFramesWritten = 0
    /// Deliberate over/under exposure, in stops, applied on top of the ramp's
    /// anchor. sessionQueue-confined mirror of `holyGrailBias`.
    private var holyGrailBiasStops: Double = 0
    #if os(iOS)
    /// Set by `startLiveBlend` when the run is a Holy Grail one, so both blend
    /// controllers can install the ramp without another parameter reaching
    /// through their configurations. sessionQueue-confined.
    private var holyGrailRequestedForRun = false
    /// Whether that run's EVERY dial was on Auto. Same reason as above.
    private var holyGrailAutoRequestedForRun = false
    /// The spacing a Holy Grail run on EVERY=Auto is currently using, so a
    /// re-pace only happens when the policy's answer has really moved (see
    /// `HolyGrailAutoInterval.isMeaningfulChange`). Nil when EVERY is a fixed
    /// value — Auto is the only mode that re-paces. sessionQueue-confined.
    private var holyGrailAutoIntervalSeconds: Double?
    // Scanner — the motion-triggered interval shoot. All sessionQueue-confined
    // except the tap itself, which owns its own queue.
    private var scannerEngine: ScannerEngine?
    private var scannerAnalyzer: ScannerMotionAnalyzer?
    private var scannerOutput: AVCaptureVideoDataOutput?
    private var scannerWriter: FrameTimestampWriter?
    private var scannerActive = false
    /// True between asking for a frame and that frame landing. Without it a
    /// scene that re-settles while a capture is still in flight fires a second
    /// shot of the same pose.
    private var scannerCapturePending = false
    /// The RAW format this run is capturing in, or nil when RAW wasn't asked
    /// for, or when it was and the honest check came back negative.
    private var scannerRawPixelFormat: OSType?
    /// Whether this run lit the torch, so the teardown only puts out a lamp it
    /// turned on itself.
    private var scannerTorchOn = false
    /// Whether RAW was *asked* for. Kept beside the format because the two
    /// nil cases are different things to say out loud: "JPEG, as you chose" and
    /// "no RAW on this device" are not the same sentence, and the HUD used to
    /// print the second one at anybody who picked the first.
    private var scannerWantedRAW = true
    /// The stock this run declared — what the rectangle detector's shape gate
    /// tests every candidate against, and (via `startScanner`) what chose the
    /// trigger in the first place.
    private var scannerPaperAspect: PerspectiveAspect = .auto
    /// Frames per pose — the BLEND dial, inside a Scanner run. 1 writes the
    /// camera's own file untouched; more builds a `ScannerPoseStack`.
    private var scannerPoseDepth = 1
    /// How many frames of the pose in flight are still to be requested. A pose
    /// deeper than one frame is captured **sequentially**, not as a burst: the
    /// run has all the time in the world (a human is holding a page still) and
    /// asking for ten 48-megapixel frames at once would put ten of them in
    /// memory at once. One in flight, one being folded into the average.
    private var scannerPoseFramesRemaining = 0
    /// The pose index the frames in flight belong to, frozen when the pose
    /// opened — `scannerFrames.count` moves when the pose lands, which is after.
    private var scannerPoseIndex = 0
    /// The corners in view when the pose was asked for, held for the whole pose
    /// so every frame of a stack is stamped with the geometry of the moment the
    /// shutter was pressed rather than of whichever frame landed last.
    private var scannerPoseQuad: NormalizedQuad?
    private var scannerPoseStack: ScannerPoseStack?
    /// Where the averaging runs. Off the session queue on purpose: a ten-frame
    /// stack is seconds of decode and GPU work, and the session queue is what
    /// keeps the preview, the tap and the shutter alive.
    private let scannerStackQueue = DispatchQueue(
        label: "letslapse.scanner.stack", qos: .userInitiated)
    /// True while a pose is being averaged and written. The HUD says so — the
    /// pose count cannot move until it finishes, and a count that sits still
    /// for three seconds after a shutter click reads as a shoot that has hung.
    private var scannerStacking = false
    /// The last sample said the detector is seeing flat things and refusing them
    /// all on shape. Carried in from the tap with the sample it describes (see
    /// `ScannerMotionAnalyzer.Sample`), never read across queues.
    private var scannerRefusingOnShape = false
    /// Preset and photo-aspect state to undo when the run ends.
    private var scannerPreviousPreset: AVCaptureSession.Preset?
    private var scannerArmedPhotoAspect = false
    /// Frames whose files have landed, newest last — what "Delete last"
    /// removes from. Each entry is one pose: the RAW and, when there is one,
    /// its processed sibling.
    private var scannerFrames: [ScannerFrame] = []
    /// Auto-stop after this many poses (36 = the canonical turntable set).
    private var scannerFrameCap: Int?
    /// Which pose each in-flight capture request belongs to, keyed by the
    /// settings' `uniqueID`. Assigned when the shutter is asked for, so the
    /// file index never depends on the order the parts come back in.
    private var scannerPoseIndexByRequest: [Int64: Int] = [:]
    /// Finds the flat object in the preview, when there is one. Lives for the
    /// length of a run beside the differencing analyzer, on the same tap.
    private var scannerRectangleDetector: RectangleDetector?
    /// The quad each in-flight request was fired against, keyed the same way as
    /// the pose index. Snapshotted at *request* time, not when the file lands:
    /// the sidecar's job is to record the geometry the shutter was taken on,
    /// and by the time a DNG has been written the page may already be gone.
    private var scannerQuadByRequest: [Int64: NormalizedQuad] = [:]
    /// The quad from the most recent sample — the truth the sidecar is stamped
    /// from, unthrottled.
    private var scannerLatestQuad: NormalizedQuad?
    /// The most recently *published* overlay quad and when it went out, so the
    /// viewfinder isn't asked to redraw for detector jitter.
    private var scannerPublishedQuad: NormalizedQuad?
    private var scannerQuadPublishedAt = Date.distantPast
    #if DEBUG
    /// Throttle for the magnitude log above.
    private var scannerLastMagnitudeLogAt = Date.distantPast
    #endif
    /// The scene re-settled but the device was moving, so the pose was held
    /// back. Drawn in the HUD so a shoot that has quietly stopped firing
    /// explains itself.
    private var scannerWaitingForSteady = false
    #endif
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
    /// The resolution the open segment is recording at — base for most of a
    /// run, the burst resolution inside a burst. Stamped onto the segment in
    /// `finishSegment` so `sequence.json` describes each file truthfully.
    private var activeRecordingResolution: CaptureResolution?
    /// The burst format's resolution for the whole run, snapshotted at start
    /// beside `activeSequenceOrientation`. Rate can move between bursts;
    /// resolution cannot, because the lens pin validated exactly two formats.
    private var activeSequenceBurstResolution: CaptureResolution?
    private var activeSegmentURL: URL?
    private var segmentURLs: [URL] = []
    private var pendingRampFrameRate: Int?
    /// The resolution the segment `pendingRampFrameRate` is opening will use.
    /// Set and cleared in lockstep with it; nil means "the run's base".
    private var pendingRampResolution: CaptureResolution?
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
    /// Whether a mark's IN has been placed and its OUT has not. Deliberately
    /// separate from `rampIntervalActive`: a mark and a burst are independent,
    /// and either may be open while the other is.
    private var markIntervalActive = false
    /// Supersedes a pending auto-OUT when the mark is closed by hand, or when
    /// a new one is opened.
    private var markGeneration = 0
    // Manual-exposure lock state, confined to sessionQueue. Source of truth for
    // re-asserting the lock after every activeFormat switch; the @Published
    // mirrors below are for UI/Watch only.
    private var exposureLocked = false
    /// sessionQueue-confined mirror of `isFocusLocked`.
    private var focusLocked = false
    private var lockedISOValue: Float = 0
    private var lockedShutterValue: Double = 0
    /// sessionQueue-confined. The lens position a hold was measured at, and the
    /// device it was measured on. A lens position means nothing on a camera
    /// other than the one it came from, so a foreign stamp is worse than no
    /// value at all — both it and nil read as "lock wherever you already are"
    /// (`heldLensPosition(for:)`). There is deliberately no default: a number
    /// nobody measured is exactly the arbitrary plane this pair exists to
    /// prevent writing.
    private var lockedLensValue: Float?
    private var lockedLensDevice: AVCaptureDevice?
    /// sessionQueue-confined. Focus pinned for the length of a capture run —
    /// taken at the shutter press, released when the run ends. Deliberately
    /// separate from `focusLocked` (the user's own lock button) so the release
    /// can only ever undo what the run itself took.
    private var runFocusLocked = false
    /// sessionQueue-confined. Focus pinned by a tap on the preview while idle.
    /// Lasts until the shoot it was set up for ends, or until the lens changes:
    /// focus is a decision the user makes per shoot, and one that can always be
    /// made again (see `releaseRunFocusLock`).
    private var tapFocusLocked = false
    /// sessionQueue-confined. Where the last preview tap asked to focus, in the
    /// device's own normalized space.
    private var tapFocusPoint: CGPoint?
    /// Every reason the lens might be pinned right now. Anything that re-applies
    /// a held focus after a configuration change gates on this: a shoot's own
    /// hold counts exactly as much as the user's lock.
    ///
    /// `exposureLocked` is deliberately NOT one of them. It is latched by the
    /// brightness slider (`setISO`, `setExposureOffset`), which never touches
    /// the lens — so counting it here froze focus on any shoot where the user
    /// had merely adjusted brightness, and then made both `lockFocusForRun` and
    /// `releaseRunFocusLock` bail, leaving that freeze with no owner to undo it.
    /// The half of the exposure lock that really does hold focus has its own
    /// flag below.
    private var focusIsHeld: Bool {
        focusHeldByUser || runFocusLocked || tapFocusLocked
    }
    /// sessionQueue-confined. The combined AE/AF lock froze the lens along with
    /// the exposure, and still owns it. Separate from `exposureLocked` because
    /// that one means only "exposure is manual", which the brightness slider
    /// sets on its own.
    private var exposureLockHoldsFocus = false
    /// sessionQueue-confined. The user drove the lens by hand with the focus
    /// slider. That slider is offered whenever exposure is locked — including
    /// the brightness-slider latch — so without a hold of its own the position
    /// it set was dropped by the next format change.
    private var manualLensHeld = false
    /// Every reason focus is being held by a standing user choice rather than by
    /// the shoot in progress — the holds a run must not take over, and must not
    /// release when it ends.
    private var focusHeldByUser: Bool {
        focusLocked || exposureLockHoldsFocus || manualLensHeld
    }
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
    /// Burst formats reachable from `selectedFrameRate` at `selectedResolution`
    /// that keep the framing and the colour identical, narrowed by the
    /// capability matrix. Not every faster format on the sensor qualifies: a
    /// different field of view or codec would reframe the clip halfway through.
    ///
    /// An option may carry a **higher resolution** than the base — that is the
    /// point. A burst is the segment a punch-in crops into, so it is where
    /// pixels are worth spending; 4K bursts off a 1080p base buy 2× of punch
    /// that costs no upscale at 1080p delivery.
    @Published var availableBurstOptions: [BurstOption] = []
    /// The rates of `availableBurstOptions` **at the selected burst
    /// resolution**, deduplicated. Kept as its own published value because the
    /// watch link and the remote-command guards speak in rates alone.
    ///
    /// The resolution filter is the load-bearing part. A bare rate list is a
    /// list a remote cannot sanity-check: the Watch has no burst-resolution
    /// key, so every rate it is handed reads as a rate the *current* burst can
    /// reach. Publishing the union across resolutions put 1080p-only rungs on
    /// the wrist next to a 4K selection — on the 5x tele that is a 120 rung
    /// over a burst whose ceiling is 60 (reported 2026-08-17). Anything that
    /// needs the rates of another resolution wants `availableBurstOptions`,
    /// which carries the pairing.
    @Published var availableBurstFrameRates: [Int] = []
    @Published var selectedRampFrameRate = 120 {
        didSet {
            guard selectedRampFrameRate != oldValue else { return }
            CaptureSessionLogger.shared.log("burst_set", ["fps": selectedRampFrameRate])
        }
    }
    /// The resolution a burst segment records at. Equal to `selectedResolution`
    /// unless the user picked an option that raises it, which is the whole of
    /// the opt-in — every existing shoot keeps one resolution throughout.
    @Published var selectedBurstResolution = CaptureResolution(width: 1920, height: 1080) {
        didSet {
            guard selectedBurstResolution != oldValue else { return }
            CaptureSessionLogger.shared.log(
                "burst_set", ["resolution": selectedBurstResolution.id])
        }
    }

    /// The resolution the segment being recorded right now landed on, so the
    /// format pill can tell the truth mid-burst. nil outside a run.
    @Published var activeSegmentResolution: CaptureResolution?

    /// Whether a burst will reconfigure more than the frame duration. Callers
    /// use this to decide what the run can promise: the shared-format fast
    /// path, the seam ease, and what the format pill has to say.
    var burstChangesResolution: Bool {
        selectedBurstResolution != selectedResolution
    }

    /// The burst the pickers are currently pointing at.
    var selectedBurstOption: BurstOption {
        BurstOption(
            pixelWidth: selectedBurstResolution.width,
            pixelHeight: selectedBurstResolution.height,
            fps: selectedRampFrameRate)
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
    /// A mark's IN is placed and its OUT is not. Drives the remote's mark pad.
    @Published var isMarkActive = false
    @Published var markIntervalCount = 0
    @Published var isRampHighRate = false
    /// The running ramp sequence's locked base rate, nil when idle.
    /// `selectedFrameRate` tracks the ACTIVE segment (it reads the burst rate
    /// mid-burst), so anything that must keep naming the resting rate — the
    /// Watch's base chip — reads this instead.
    @Published private(set) var activeBaseFrameRate: Int?
    @Published var rampSpans: [RampSpan] = []
    @Published var isExposureLocked: Bool = false
    /// Focus (and white balance) held without touching exposure — the Holy
    /// Grail lock, where exposure belongs to the ramp.
    @Published var isFocusLocked: Bool = false
    /// True whenever the lens is pinned for any reason — a preview tap, either
    /// lock button, or the automatic hold every running shoot takes. This is
    /// not `isFocusLocked`, which stays the lock BUTTON's own state.
    @Published private(set) var isFocusHeld: Bool = false
    /// Set while a preview tap owns the focus, so the viewfinder can keep its
    /// reticle sitting on the subject the user picked.
    @Published private(set) var isFocusPinnedByTap: Bool = false
    #if os(iOS)
    /// The live preview's layer, handed over by `CameraPreview`. A tap arrives
    /// in layer coordinates and only the layer knows the letterboxing, the
    /// mirroring and the rotation between what is on screen and what the
    /// sensor sees — so it does the conversion (see `focusPreview`).
    /// Main-thread only.
    weak var previewLayer: AVCaptureVideoPreviewLayer?
    #endif
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

    /// What a second of recording will weigh, from the encoder rather than
    /// from a table — the number the capture screen's headroom chip is only as
    /// honest as.
    ///
    /// `AVCaptureMovieFileOutput` will state the settings it is actually about
    /// to write with, and for the compressed codecs that includes the average
    /// bitrate it has picked for this format, this rate and this device. A
    /// per-pixel constant cannot know that a 100 fps burst format is encoded
    /// far harder than a 30 fps one on the same sensor.
    ///
    /// nil when there is no connection yet, or when the codec has no bitrate
    /// to state — ProRes is intra-frame and sized by its own arithmetic, which
    /// `CaptureCostKey.modelledCost` does honestly.
    var movieBytesPerSecond: Double? {
        guard let connection = movieOutput.connection(with: .video) else { return nil }
        let settings = movieOutput.outputSettings(for: connection)
        guard let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any],
              let bitsPerSecond = compression[AVVideoAverageBitRateKey] as? NSNumber,
              bitsPerSecond.doubleValue > 0 else { return nil }
        return bitsPerSecond.doubleValue / 8
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

    /// What a running Holy Grail ramp is doing, republished after every frame.
    /// Nil outside a ramp.
    struct HolyGrailState: Equatable {
        var shutterSeconds: Double
        var iso: Float
        /// The smoothed scene EV (at ISO 100) the ramp is tracking.
        var sceneEV: Double
        var frames: Int
        /// The shutter is at its ceiling and ISO is carrying the ramp — the
        /// point where the shoot starts paying in noise.
        var isISORamping: Bool
        /// The scene has moved past what the hardware can hold; frames keep
        /// coming but no longer track the light.
        var isClipped: Bool
        /// Whether each frame is also being kept as RAW.
        var isCapturingRAW: Bool
        /// The operator's over/under exposure, in stops.
        var bias: Double = 0
    }

    @Published var holyGrailState: HolyGrailState?

    /// One captured pose: the file(s) a single Scanner fire produced. Kept as a
    /// pair rather than two flat lists so "Delete last" can take a whole pose
    /// away in one step and never leave an orphaned sibling behind.
    struct ScannerFrame: Equatable {
        var raw: URL
        /// The processed sibling (HEIC), when the device gave one. Nil on the
        /// fallback path, where the processed still *is* `raw`.
        var processed: URL?

        /// Every file this pose owns — what the delete removes and what the
        /// project is registered from.
        var urls: [URL] { [raw] + (processed.map { [$0] } ?? []) }
    }

    /// What a running Scanner shoot is doing, republished on every state
    /// change. Nil outside a Scanner run.
    struct ScannerState: Equatable {
        /// The engine's state, verbatim — the HUD's headline is a reading of
        /// this and nothing else.
        var phase: String
        /// Poses captured so far. The primary signal: the operator is looking
        /// at the object, not the screen, so this is what the HUD makes big.
        var frames: Int
        /// The exposure every frame of this run is locked to.
        var shutterSeconds: Double
        var iso: Float
        /// Whether frames are landing as RAW.
        var isCapturingRAW: Bool
        /// Whether RAW was asked for at all. With `isCapturingRAW` false this
        /// separates "no RAW on this device" from "JPEG, as the format dial
        /// says" — the HUD printed the first at everyone who chose the second.
        var wantedRAW: Bool = true
        /// How far through the settle window the scene is, 0…1. Nil unless
        /// something is settling.
        var settleProgress: Double?
        /// The device itself is moving too much to shoot, so a scene that has
        /// re-settled is being held back. Both signals must agree.
        var waitingForDeviceSteady: Bool
        /// Whether a flat object is in frame — i.e. whether the run is settling
        /// on four corners standing still (the strong signal) or on the frame
        /// difference (the fallback). Phase 2.
        var hasRectangle: Bool = false
        /// The rectangle trigger has nothing flat to photograph. A camera that
        /// is deliberately not firing must say why.
        var waitingForRectangle: Bool = false
        /// Which machine is deciding — `ScannerEngine.Trigger`'s raw value. The
        /// HUD's whole vocabulary changes with it: under the document trigger
        /// there is no "move something" to ask for.
        var trigger: String = ScannerEngine.Trigger.motion.rawValue
        /// The detector can see something flat and the named stock has refused
        /// it (see `RectangleDetector.isRefusingOnShape`). Told apart from
        /// "nothing in view" in the HUD because the fix is a different one:
        /// this is "you are pointed at the wrong thing, or the wrong stock is
        /// selected", not "put a page down".
        var refusingOnShape: Bool = false
        /// Frames averaged into each pose — the BLEND dial. 1 is a plain pose.
        var framesPerPose: Int = 1
        /// A pose's frames are all in and are being averaged and written. The
        /// pose count cannot move until this finishes, so the HUD says what the
        /// wait is rather than looking stalled.
        var isStacking: Bool = false
    }

    @Published var scannerState: ScannerState?

    /// Bumped each time a pose is actually asked for by hand (see
    /// `captureScannerPoseNow`). The capture screen's confirmation — the
    /// "✓ Captured" flash and the haptic — hangs off this rather than off the
    /// button's own action, so the feedback fires when a frame really went out
    /// and stays silent when the request was refused (a pose already in flight,
    /// or the run's frame cap reached).
    @Published private(set) var scannerManualCaptures = 0

    /// The flat object the Scanner can currently see, normalised bottom-left
    /// origin, or nil when there is none. Drawn as the viewfinder's quad
    /// overlay and stamped into the sidecar at capture.
    ///
    /// Separate from `scannerState` rather than a field on it, because the two
    /// change at different rates and for different reasons: the state changes
    /// when the shoot's phase does, the quad moves whenever the page or the
    /// camera does. Folding them together would redraw the whole HUD at the
    /// detector's rate.
    @Published var scannerRectangle: NormalizedQuad?

    /// Which way up the image `scannerRectangle` was measured in — the run's
    /// **capture** orientation, frozen at start with everything else about the
    /// run.
    ///
    /// It travels with the quad because a quad without it is ambiguous. The
    /// corners are in the pose the *still* is written at (so the sidecar and
    /// `PerspectiveCorrector` need no conversion), and the preview is drawn in
    /// the *interface* orientation. Those are the same thing right up until
    /// they are not — the rotation lock, and the flat-over-a-desk pose a copy
    /// stand puts the device in, where `UIDeviceOrientation` reads faceUp and
    /// the last known pose stands. The overlay converts by the difference; a
    /// quarter turn of error is the whole width of a page.
    @Published var scannerRectangleOrientation: QuadOrientation = .right

    /// The spacing the run in flight is really using, or nil when nothing is
    /// running or nothing is pacing itself.
    ///
    /// Exists because the dial's value stops being the truth the moment EVERY
    /// goes to Auto. A remote reading the dial then reports a number the camera
    /// is not using — observed on an iPad Air (2026-08-16): the wire said
    /// "every 5 s" for a Holy Grail run whose frames were landing 5.4 s apart
    /// off a 3 s Auto floor, so the one surface that exists to tell you what a
    /// camera across a field is doing was quoting a setting instead.
    @Published var activeIntervalSeconds: Double?

    /// Over/under exposure for the ramp, in stops — the Holy Grail answer to
    /// an exposure lock. The ramp keeps following the light; this decides how
    /// bright "following it" means, relative to what the camera metered when
    /// the shoot began. Live: turning it mid-run walks the exposure there at
    /// the ramp's own rate limit, so it can be dialled during a shoot without
    /// putting a step in the sequence.
    @Published var holyGrailBias: Double = 0 {
        didSet {
            let stops = min(max(holyGrailBias, -3), 3)
            sessionQueue.async {
                self.holyGrailBiasStops = stops
                self.applyExposureTargetBias(stops)
                #if os(iOS)
                self.publishHolyGrailState()
                #endif
            }
        }
    }

    /// Pushes the over/under exposure onto the device's own AE compensation.
    ///
    /// This is the whole control, and putting it *on the device* rather than
    /// inside the ramp is what makes it behave:
    ///
    /// - **Before a shoot** the preview moves with it. AE is live then, so the
    ///   viewfinder shows exactly what the run will open on. (A bias held only
    ///   inside the ramp engine changed nothing until the first frame — the
    ///   control looked dead.)
    /// - **At the start of a shoot** the seed is read off a camera that has
    ///   already settled at the biased exposure, so the run *begins* where it
    ///   was set rather than ramping into it a third of a stop at a time.
    /// - **During a shoot** it shifts the meter's target, so the ramp's own
    ///   measurement carries it and the exposure walks there smoothly.
    ///
    /// sessionQueue-confined.
    private func applyExposureTargetBias(_ stops: Double) {
        #if os(iOS)
        guard let device = videoDevice else { return }
        let clamped = min(max(Float(stops), device.minExposureTargetBias),
                          device.maxExposureTargetBias)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setExposureTargetBias(clamped, completionHandler: nil)
        } catch {
            LLog("exposure bias: lockForConfiguration failed — \(error.localizedDescription)")
        }
        #endif
    }

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
            // The toggle changes two derived answers, so re-derive both: the
            // format sort prefers Log-capable formats while Log is on (the
            // active format may need to change for Log to engage at all), and
            // the burst list is asked with Log as a requirement (at 1080p a
            // 240 fps burst exists only without Log). Same busy guards as the
            // pickers — mid-run the sheet is unreachable anyway.
            sessionQueue.async {
                guard self.isConfigured, !self.movieOutput.isRecording,
                      self.intervalTimer == nil, !self.isLiveBlendActive else { return }
                self.refreshCaptureOptions()
                self.publishFormat()
            }
        }
    }

    /// True when the current camera device offers Apple Log on any of its
    /// formats — the gate for showing the Capture Flat toggle's Log wording in
    /// Video mode. Published from `publishFormat()` rather than computed on
    /// demand: the capture screen evaluates its Log gate on appear, which is
    /// before `configureIfNeeded` has assigned `videoDevice` — a computed
    /// property answered false there and the answer was never re-asked, so
    /// Capture Flat latched off for the whole session (found 2026-08-14).
    @Published private(set) var supportsAppleLog = false

    /// Whether the *selected* resolution + frame rate can shoot Apple Log —
    /// the capability matrix's answer, published by `refreshCaptureOptions`.
    /// `supportsAppleLog` is about the device; this is about the selection
    /// (a Log-capable phone still has no Log at 4032×3024), and it is what
    /// the format sheet's footer states.
    @Published private(set) var appleLogAvailableForSelection = false

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
            self.assertColorSpace(on: device)
        }
        #endif
    }

    #if os(iOS)
    /// The one place the colour space is actually written, and the fix for
    /// Capture Flat recording Rec.709 no matter what (2026-08-14, verified
    /// against a real shoot's files): `AVCaptureSession
    /// .automaticallyConfiguresCaptureDeviceForWideColor` defaults to YES, and
    /// its header is explicit — *"If you wish to set AVCaptureDevice's
    /// activeColorSpace manually, and prevent the AVCaptureSession from undoing
    /// your work, you must set automaticallyConfiguresCaptureDeviceForWideColor
    /// to NO."* Every `.appleLog` write this app made without taking that
    /// ownership was silently reverted by the session.
    ///
    /// Ownership is taken only while Log is engaged and handed back when it
    /// isn't, so the still modes keep the session's own wide-colour behaviour
    /// (P3 photos when a photo output is present).
    ///
    /// sessionQueue-confined. `deviceIsLocked` says the caller already holds
    /// `lockForConfiguration` (the `applyCaptureFormat` re-assert does; nesting
    /// the lock is undefined, so it must not be taken twice).
    @available(iOS 17.2, *)
    private func assertColorSpace(on device: AVCaptureDevice, deviceIsLocked: Bool = false) {
        let wantLog = appleLogEnabled
            && device.activeFormat.supportedColorSpaces.contains(.appleLog)

        func write(_ space: AVCaptureColorSpace) {
            guard device.activeColorSpace != space else { return }
            if deviceIsLocked {
                device.activeColorSpace = space
            } else {
                do {
                    try device.lockForConfiguration()
                    device.activeColorSpace = space
                    device.unlockForConfiguration()
                } catch {
                    LLog("colour space: lockForConfiguration failed — \(error.localizedDescription)")
                    return
                }
            }
            LLog("colour space → \(space == .appleLog ? "Apple Log" : "sRGB")")
        }

        if wantLog {
            // Ownership BEFORE the write, or the session undoes it.
            if session.automaticallyConfiguresCaptureDeviceForWideColor {
                session.automaticallyConfiguresCaptureDeviceForWideColor = false
            }
            write(.appleLog)
        } else if !session.automaticallyConfiguresCaptureDeviceForWideColor {
            // Leave the device in the state the session expects before handing
            // the colour space back to it.
            write(.sRGB)
            session.automaticallyConfiguresCaptureDeviceForWideColor = true
        }
        // Ownership never taken and Log not wanted: the session already owns
        // the colour space and is keeping it sRGB/P3 itself — nothing to do,
        // and a manual write here would be undone anyway.
    }
    #endif

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
    /// The Watch framing preview's tap. A separate output from the test card's
    /// rather than a shared one with a swappable delegate: whichever attached
    /// second would silently steal the other's frames, and both are session
    /// surgery in the one area of this class where a mistake kills recordings
    /// outright. Two outputs that each own their lifetime cannot do that.
    private var framingOutput: AVCaptureVideoDataOutput?
    private var liveBlendController: LiveBlendController?
    #if os(iOS)
    private var liveBlendRawController: LiveBlendRawController?
    #endif

    /// Auto blend's device ceiling for the run in flight, measured at start and
    /// re-measured when the thermal state moves. Held rather than passed by
    /// value because a re-profile has to reach a controller that is already
    /// running — the closure the controller was handed reads through this.
    private let capabilityProfileHolder = CapabilityProfileHolder()
    private var thermalObserver: NSObjectProtocol?
    #if os(iOS)
    /// Held for the probe's lifetime — it owns the capture delegate the photo
    /// output is talking to, and AVFoundation keeps only a weak reference.
    private var capabilityProfiler: DeviceCapabilityProfiler?
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
        // Seed the burst resolution from the base first, so a store that has
        // never held one (or a device that no longer offers it) lands on the
        // pre-feature behaviour of one resolution throughout.
        selectedBurstResolution = selectedResolution
        if let frameRate = RecordingSettingsStore.frameRate {
            selectedFrameRate = frameRate
        }
        if let rampFrameRate = RecordingSettingsStore.rampFrameRate {
            selectedRampFrameRate = rampFrameRate
        }
        if let rampResolution = RecordingSettingsStore.rampResolution {
            selectedBurstResolution = rampResolution
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
            // Cancelling the timer is not finishing the run: `intervalActive`
            // and the published `isIntervalRunning` used to survive this, and a
            // stranded `isIntervalRunning` refuses every tap-to-focus for the
            // life of the controller (`focusPreview`) while leaving lens changes
            // working — which is what made pinching look like a focus fix.
            // Deliberately not `finishIntervalOnQueue()`: an abandoned run's
            // frames are Incomplete Captures' business, not a finished project.
            if self.intervalActive {
                self.intervalActive = false
                self.releaseRunFocusLock()
                DispatchQueue.main.async { self.isIntervalRunning = false }
            }
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
                // Before the format restore below: a bracket already queued
                // behind this block must not see a ramp target once the run
                // is torn down — the settings themselves are range-proof
                // (`current` constants), but the honesty guard would compare
                // straggler frames against a dead target.
                self.holyGrailAppliedExposure.set(nil)
                rawController.requestStop(discard: true)
                self.restoreAfterDNGRun()
                DispatchQueue.main.async { self.isLiveBlendRunning = false }
            }
            #endif
            if let controller = self.liveBlendController, controller.isActive {
                self.liveBlendOutput?.setSampleBufferDelegate(nil, queue: nil)
                controller.requestStop(discard: true)
                self.restoreVideoFrameDuration()
                DispatchQueue.main.async { self.isLiveBlendRunning = false }
            }
            #if os(iOS)
            // Backstop for the abandoned-run path: closing the screen mid-scan
            // stops the session without going through `finishScannerOnQueue`
            // (an abandoned run's frames are Incomplete Captures' business),
            // and a torch left burning behind a closed camera screen is the
            // most conspicuous bug this feature could have. Idempotent.
            self.disableScannerTorch()
            #endif
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
        #if os(iOS)
        // The ceiling every `AVCapturePhotoSettings` this app makes is measured
        // against — raised here, inside the configuration block and before the
        // session ever runs, which is the only place raising it is free.
        //
        // It defaults to `.balanced`, and `capturePhoto(with:)` raises
        // `NSInvalidArgumentException` — not an error, a **crash** — for any
        // settings asking for more than the output allows. Scanner asks for
        // `.quality` on its processed path, because a pose is a measurement and
        // nothing is waiting on the next frame but a human moving an object.
        // That path was unreachable on any device with Bayer RAW until the
        // format dial started being honoured (2026-08-17), so the mismatch had
        // never been executed; the first JPEG Scanner shoot on an iPhone 16 Pro
        // died on it.
        if photoOutput.maxPhotoQualityPrioritization.rawValue
            < AVCapturePhotoOutput.QualityPrioritization.quality.rawValue {
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        #endif
        session.commitConfiguration()
        // An `AVCaptureDevice` is process-global: its focus mode outlives this
        // session, this controller and the capture screen, while every flag that
        // tracks a hold is fresh here. A device left `.locked` by an earlier
        // screen would therefore come back locked with nothing knowing to
        // release it — no hold to re-assert, no owner to hand it back — and only
        // a lens change (which rewrites `activeFormat`) or a relaunch would free
        // it. This is the one write that makes a new capture screen mean a
        // camera that focuses for itself.
        resumeContinuousAutoFocus()
        // Format introspection only — no session work, no sensor swap — so it
        // is safe here on the session queue before the session starts running.
        // Everything downstream (`refreshCaptureOptions`) reads its answers.
        capabilityMatrix = DeviceCapabilityMatrix.loadOrProbe(devices: allCaptureDevices())
        LLog("capability matrix: \(capabilityMatrix?.validBurstOptions.count ?? 0) configurations"
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
    private var lastAppliedBurstResolutionEnabled = BurstResolutionSetting.isEnabled

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
        // Both of these change what the pickers may offer, so both re-derive
        // on the way back from Settings. The burst-resolution switch matters
        // most when it is turned OFF: the burst options must drop back to the
        // base resolution before the next run, or a shoot would still be armed
        // for a format the user has just said they don't want.
        let custom = RecordingSettingsStore.customFrameRate
        let burstResolutionEnabled = BurstResolutionSetting.isEnabled
        guard custom != lastAppliedCustomFrameRate
            || burstResolutionEnabled != lastAppliedBurstResolutionEnabled else { return }
        lastAppliedCustomFrameRate = custom
        lastAppliedBurstResolutionEnabled = burstResolutionEnabled
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
            guard !self.captureIsRunning else { return }
            RecordingSettingsStore.save(stopFactor: stop.displayFactor)
            if self.physicalWorldActive {
                self.selectPhysicalStop(stop)
                self.releaseFocusForLensChange()
            } else {
                self.applyZoom(stop, animated: true)
                // The burst menu is read from the lens this stop would pin to,
                // so changing stops can change the answer (4K120 exists on the
                // wide and not on the tele). Deferred past the ramp:
                // `refreshCaptureOptions` re-applies `activeFormat`, which
                // resets the zoom factor and would snap the animation.
                self.sessionQueue.asyncAfter(deadline: .now() + 0.35) {
                    guard !self.captureIsRunning else { return }
                    self.refreshCaptureOptions()
                    // A new lens is a new shot: hand focus back for it rather
                    // than carry the last one's plane across a re-crop, or a
                    // hand-over to a constituent the tapped point was never set
                    // on. Runs after `refreshCaptureOptions`, whose format write
                    // re-asserts any standing hold.
                    self.releaseFocusForLensChange()
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
    /// Declines — loudly — when the lens can't shoot every *format* the run
    /// needs. A run that would have to drop the burst rate or the resolution is
    /// worse than one that keeps the old behaviour.
    ///
    /// `configurations` is one entry per format the run will switch between:
    /// the base pair, plus the burst pair when they differ. Checking both here
    /// is what makes "resolve it before recording starts" true — the
    /// alternative is discovering it at the moment the burst fires, with a
    /// segment already open.
    private func pinLensForSequence(configurations: [(resolution: CaptureResolution, fps: Int)]) {
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
        for configuration in configurations
        where captureFormatMatch(
            for: lens.device,
            resolution: configuration.resolution,
            fps: configuration.fps) == nil {
            LLog("optics: \(name) cannot shoot"
                 + " \(configuration.resolution.label)@\(configuration.fps)"
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
        let formats = configurations
            .map { "\($0.resolution.label)@\($0.fps)" }
            .joined(separator: ", ")
        LLog("optics: run pinned to \(name) at zoom "
             + "\(String(format: "%.2f", lens.zoomFactor)) for \(formats)")
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
        // The resolution and base-rate menus describe the lens the run would
        // actually pin to — `effectiveRecordingDevice`, the same answer the
        // burst menu below is built from. Reading them off the optics device
        // instead is what hid every rate above 60 fps from this app between
        // 63c1c23 (2026-08-10) and 2026-08-22: AVFoundation publishes no
        // format faster than 60 on `builtInTripleCamera` at all, so a phone
        // whose wide shoots 1080p240 and 4K120 offered neither. Probed on
        // iPhone17,1 / iOS 26.6, every physical lens reaches 1080p240 and only
        // the wide reaches 4K above 60 — so the pinned lens is both the honest
        // list and the full one, at every stop.
        //
        // A pinned run reads the pin's own lens (it IS the recording device),
        // which widens the menus rather than narrowing them.
        let listDevice = effectiveRecordingDevice(for: currentStop) ?? device
        let supportedRates = supportedFrameRatesByResolution(for: listDevice)
        guard !supportedRates.isEmpty else {
            DispatchQueue.main.async {
                self.availableResolutions = []
                self.availableFrameRates = []
                self.availableBurstOptions = []
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
        // clip at the segment boundary. Asked of `listDevice` — the same lens
        // the base menus above describe, so a run can never be offered a base
        // pair and a burst pair that live on two different cameras.
        let burstOptions = self.burstOptions(
            for: listDevice,
            resolution: resolution,
            baseFrameRate: frameRate,
            allRates: rateSet)
        // Hold the whole pair where it is still offered, so changing the base
        // rate doesn't silently drop a chosen 4K burst back to the base
        // resolution. Falling back rate-first (any resolution at the wanted
        // rate) before giving up keeps the burst as close to the ask as the
        // hardware allows.
        let burst = burstOptions.first { $0 == selectedBurstOption }
            ?? burstOptions.first { $0.fps == selectedRampFrameRate }
            ?? burstOptions.first
        let rampFrameRate = burst?.fps ?? selectedRampFrameRate
        let burstResolution = burst.map {
            CaptureResolution(
                width: $0.pixelWidth, height: $0.pixelHeight, isProRes: resolution.isProRes)
        } ?? resolution

        _ = applyCaptureFormat(resolution: resolution, fps: frameRate)
        RecordingSettingsStore.save(
            resolution: resolution,
            frameRate: frameRate,
            rampFrameRate: rampFrameRate,
            rampResolution: burstResolution
        )
        // Can THIS selection shoot Apple Log? The matrix's Log-required pass
        // answers per resolution + rate, which is the honest footer: a
        // Log-capable phone still has no Log at, say, 4032×3024 — and there
        // Capture Flat falls back to the save-time grade instead.
        #if os(iOS)
        let logAvailable = capabilityMatrix.map { matrix in
            matrix.supportedFrameRatesByResolution(
                forDeviceKey: DeviceCapabilityMatrix.deviceKey(for: listDevice),
                stabilizationEnabled: videoStabilizationRequested,
                appleLogEnabled: true)[resolution]?.contains(frameRate) ?? false
        } ?? false
        #else
        let logAvailable = false
        #endif
        DispatchQueue.main.async {
            self.availableResolutions = resolutions
            self.selectedResolution = resolution
            self.availableFrameRates = frameRates
            self.selectedFrameRate = frameRate
            self.availableBurstOptions = burstOptions
            self.availableBurstFrameRates =
                Self.burstFrameRates(from: burstOptions, at: burstResolution)
            self.selectedRampFrameRate = rampFrameRate
            self.selectedBurstResolution = burstResolution
            if self.appleLogAvailableForSelection != logAvailable {
                self.appleLogAvailableForSelection = logAvailable
            }
        }
    }

    /// The bare rate ladder for the remote: the rates `options` offers at ONE
    /// resolution, in picker order, deduplicated.
    ///
    /// Every publisher of `availableBurstFrameRates` goes through here, so the
    /// list can never be built from a resolution other than the one selected.
    /// Order matters — the options arrive in picker order, so a rate's first
    /// appearance is the order the wrist's ladder wants, and `Set` would
    /// scramble it.
    private static func burstFrameRates(
        from options: [BurstOption],
        at resolution: CaptureResolution
    ) -> [Int] {
        var seenRates = Set<Int>()
        return options
            .filter {
                $0.pixelWidth == resolution.width && $0.pixelHeight == resolution.height
            }
            .map(\.fps)
            .filter { seenRates.insert($0).inserted }
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

    /// Burst formats reachable from `baseFrameRate` at `resolution` without the
    /// framing or the colour changing — the matrix's whole reason to exist.
    /// Falls back to "everything faster at this resolution" (the pre-matrix
    /// behaviour) when the probe hasn't run.
    ///
    /// The fallback deliberately stays at the base resolution. Without a probe
    /// there is nothing that knows which higher resolution frames the scene
    /// identically, and guessing one is exactly the reframe this feature exists
    /// to avoid.
    private func burstOptions(
        for device: AVCaptureDevice,
        resolution: CaptureResolution,
        baseFrameRate: Int,
        allRates: Set<Int>
    ) -> [BurstOption] {
        #if os(iOS)
        let logRequested = appleLogEnabled
        #else
        let logRequested = false
        #endif
        if let matrix = capabilityMatrix,
           let options = matrix.validBurstOptions(
                for: device,
                resolution: resolution,
                stabilizationEnabled: videoStabilizationRequested,
                appleLogEnabled: logRequested,
                baseFPS: baseFrameRate) {
            // The setting decides RESOLUTION, never RATE. With it off a burst
            // stays at the base resolution wherever that resolution can shoot
            // the rate — the picker lists plain rates, `selectedBurstResolution`
            // re-pins to the base, `burstChangesResolution` is false, and every
            // path downstream is the one that shipped before the feature.
            //
            // What it must NOT do is shorten the rate ladder: a blanket filter
            // on pixel dimensions dropped any rate the base resolution cannot
            // reach (on iPhone17,1: 100/120/240 from a 960×540 base), which
            // turned a resolution preference into a frame-rate ceiling. A rate
            // reachable only at a larger resolution keeps its option, and the
            // composition is identical either way — that is what the matrix's
            // FOV-and-aspect fingerprint guarantees, and the reason the two
            // choices are separable at all.
            guard BurstResolutionSetting.isEnabled else {
                var byRate: [Int: BurstOption] = [:]
                for option in options {
                    let atBase = option.pixelWidth == resolution.width
                        && option.pixelHeight == resolution.height
                    // First option wins per rate unless a base-resolution one
                    // turns up: `pickerOrder` sorts rate-then-pixels, so the
                    // fallback is the smallest resolution that offers the rate.
                    if byRate[option.fps] == nil || atBase {
                        byRate[option.fps] = option
                    }
                }
                return byRate.values.sorted(by: BurstOption.pickerOrder)
            }
            return options
        }
        return allRates
            .filter { $0 > baseFrameRate }
            .sorted()
            .map {
                BurstOption(
                    pixelWidth: resolution.width, pixelHeight: resolution.height, fps: $0)
            }
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

    /// Choose the rate a burst switches to.
    ///
    /// **Allowed while a run is in progress**, which is the whole point: the
    /// burst rate is a decision you make between bursts, and a remote that
    /// cannot change it mid-shoot can only ever repeat the rate you picked
    /// before you started. Selecting a rate does not touch the session — the
    /// format switch happens when a burst actually opens — so there is nothing
    /// here that a live writer could trip over.
    ///
    /// The one moment it is refused is while a burst is open or its switch is
    /// in flight: re-rating a segment that is already recording is meaningless,
    /// and `pendingRampFrameRate` is mid-handshake with the writer.
    func selectRampFrameRate(_ fps: Int) {
        sessionQueue.async {
            guard self.pendingRampFrameRate == nil, !self.rampIntervalActive else {
                LLog("burst rate: refused — a burst is open")
                return
            }
            // Only a composition-safe rate can be selected: anything else
            // would swap the optic (or the codec) mid-clip.
            //
            // This changes the RATE ONLY. Resolution is a heavier
            // reconfiguration, is idle-only, and belongs to `selectBurstOption`
            // — so a rate this burst resolution cannot reach is refused rather
            // than served by quietly moving to a resolution that can.
            //
            // The old fallback chain did move: asking for a rate that only
            // existed at 1080p rewrote a 4K burst to 1080p without saying so,
            // and mid-run — where the candidates were pre-filtered to the
            // current resolution — an unreachable rate fell through to
            // `candidates.first`, the LOWEST rung, so a request for 120
            // silently set 30 and was still reported accepted. Both were
            // reachable from the wrist, whose ladder was built from the union
            // of rates across resolutions (fixed at `burstFrameRates(from:at:)`).
            let current = self.selectedBurstResolution
            guard let option = self.availableBurstOptions.first(where: {
                $0.fps == fps
                    && $0.pixelWidth == current.width
                    && $0.pixelHeight == current.height
            }) else {
                LLog("burst rate: refused \(fps) — not reachable at \(current.label)")
                return
            }
            let frameRate = option.fps
            let resolution = current
            RecordingSettingsStore.save(rampFrameRate: frameRate, rampResolution: resolution)
            // A run bakes its ramp rate into the sequence at start, and the
            // burst switch reads it from there — so without this the selection
            // would change everywhere except where it matters. Segments still
            // record their own real `frameRate`, so the sidecar stays truthful
            // about what each file actually shot at; this only updates the
            // run's stated intent for the bursts still to come.
            self.activeSequence?.rampFrameRate = frameRate
            DispatchQueue.main.async {
                self.selectedRampFrameRate = frameRate
                self.selectedBurstResolution = resolution
            }
        }
    }

    /// Choose the whole burst format — rate *and* resolution — as one act.
    ///
    /// The format sheet offers pairs rather than two independent menus so that
    /// an illegal combination cannot be expressed: the hardware does not
    /// generally offer its top rate at its top resolution, and a user who picks
    /// them separately would find out at the moment the burst fires. A pair
    /// list resolves it before recording starts, by construction.
    ///
    /// Idle-only where it changes resolution. Unlike a rate change — which is
    /// a frame-duration write the run can absorb between bursts — landing on a
    /// different resolution is a full `activeFormat` swap, and the run has
    /// already pinned a lens and validated both of its formats.
    func selectBurstOption(_ option: BurstOption) {
        sessionQueue.async {
            guard self.pendingRampFrameRate == nil, !self.rampIntervalActive else {
                LLog("burst format: refused — a burst is open")
                return
            }
            guard self.availableBurstOptions.contains(option) else {
                LLog("burst format: refused \(option.pixelWidth)x\(option.pixelHeight)"
                     + "@\(option.fps) — not composition-safe from this base")
                return
            }
            let resolution = CaptureResolution(
                width: option.pixelWidth,
                height: option.pixelHeight,
                isProRes: self.selectedResolution.isProRes)
            if self.isRecording, resolution != self.selectedBurstResolution {
                LLog("burst format: refused a resolution change mid-run")
                return
            }
            RecordingSettingsStore.save(rampFrameRate: option.fps, rampResolution: resolution)
            self.activeSequence?.rampFrameRate = option.fps
            DispatchQueue.main.async {
                self.selectedRampFrameRate = option.fps
                self.selectedBurstResolution = resolution
                // The remote's ladder is the rates of THIS resolution, so it
                // has to be rebuilt whenever the resolution moves — this is the
                // one path that changes it without going through
                // `refreshCaptureOptions`, and leaving it alone would strand
                // the wrist on the previous resolution's rungs.
                self.availableBurstFrameRates = Self.burstFrameRates(
                    from: self.availableBurstOptions, at: resolution)
            }
        }
    }

    /// Whether a burst-rate change would land right now. The remote asks before
    /// reporting a command accepted — a false accept leaves the wrist showing a
    /// rate the next burst will not use.
    var canSelectRampFrameRate: Bool {
        !isRampActive
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
            // Ungated by design — a shoot holds focus whether or not the user
            // locked exposure, and this call is the only thing standing between
            // an `activeFormat` write and a hunt at the head of the new file.
            // `formatChanged` must be passed: it is what tells the re-assert
            // that the device's own report of its focus is stale, and so that
            // the write is mandatory rather than skippable.
            reassertFocusLock(on: device, formatChanged: formatChanged)
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
            // Same rule for the colour space: re-assert Apple Log if Capture
            // Flat is on and the format supports it (otherwise sRGB). Goes
            // through `assertColorSpace` so the session's wide-colour
            // ownership is taken first — without that the session reverts
            // the write (see that function).
            if #available(iOS 17.2, *) {
                assertColorSpace(on: device, deviceIsLocked: true)
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
    /// A burst that also changes **resolution** can never take this path: the
    /// target is a different format by definition, so this returns false and
    /// every such boundary pays the full switch. That is the known price of
    /// per-segment burst resolution, and `Segment.settleSeconds` measures it.
    ///
    /// sessionQueue-confined, like every other device configuration here.
    private func prepareRampRateChange(to resolution: CaptureResolution, fps: Int) -> Bool {
        guard let device = videoDevice,
              let match = captureFormatMatch(
                for: device, resolution: resolution, fps: fps),
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
            reassertFocusLock(on: device)
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
        #else
        if device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
        }
        #endif
        if device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
        }
    }

    /// Re-apply the held focus after a configuration change, whatever is
    /// holding it.
    ///
    /// Assigning `activeFormat` hands the lens back to continuous auto-focus,
    /// and so does adding a device input. Until 2026-08-16 the only re-assert
    /// lived inside `reassertExposureLock`, which returns early unless the user
    /// has manually locked *exposure* — so on an ordinary shoot the shutter
    /// press (which does both) and every burst segment switch (which does the
    /// first) re-opened the hunt the shoot had already settled. Focus is now
    /// its own concern, gated on `focusIsHeld`, and called unconditionally from
    /// both format paths.
    ///
    /// `formatChanged` says the caller has just written `activeFormat`. It is
    /// the difference between a device that can be trusted to describe itself
    /// and one that cannot — see the shortcut below, which is only sound on
    /// the shared-format fast path it was written for.
    ///
    /// Runs inside the caller's `lockForConfiguration` block on the sessionQueue.
    private func reassertFocusLock(on device: AVCaptureDevice, formatChanged: Bool = false) {
        guard focusIsHeld, device.isFocusModeSupported(.locked) else { return }
        #if os(iOS)
        // `.locked` being supported does NOT imply the device can lock at an
        // arbitrary lens position — the ultra-wide reports the former and not
        // the latter, and passing a custom value there raises
        // NSInvalidArgumentException. `currentLensPosition` is the sentinel
        // for "lock wherever you already are", which every device accepts.
        let custom = device.isLockingFocusWithCustomLensPositionSupported
        // A position measured on another constituent is not a position on this
        // one; nil means put the lens back where it is rather than somewhere a
        // different camera once was.
        let held = heldLensPosition(for: device)
        // Nothing is asked of a lens that is already where it should be: a
        // burst boundary on the shared-format fast path never reset focus in
        // the first place, and a redundant write there is a chance for the
        // motor to twitch inside the one transition that must not move.
        //
        // That reasoning holds ONLY while nothing has just reconfigured the
        // device. An `activeFormat` write hands focus back to continuous auto
        // as the configuration commits, and until it does the device still
        // reports the mode and lens position the run pinned — so the shortcut
        // reads "already correct" and skips the one write that matters. The
        // whole segment then records through the hunt that follows. Project
        // B6D1F167 (2026-08-16) lost its entire 4K60 burst to exactly this:
        // soft from frame 0, every depth in the frame 8-17x down, and restored
        // at the *next* boundary only because that one read
        // `.continuousAutoFocus` and therefore took the write. A burst that
        // changes resolution can never take the fast path, so with per-segment
        // burst resolution on, every boundary is this case.
        let alreadyHeld = !formatChanged
            && device.focusMode == .locked
            && (!custom || held.map { abs(device.lensPosition - $0) < 0.001 } ?? true)
        guard !alreadyHeld else { return }
        device.setFocusModeLocked(
            lensPosition: (custom ? held : nil) ?? AVCaptureDevice.currentLensPosition,
            completionHandler: nil)
        #else
        guard formatChanged || device.focusMode != .locked else { return }
        device.focusMode = .locked
        #endif
    }

    /// sessionQueue-confined. Confirm the lens is still where the run pinned it
    /// once a configuration change has COMMITTED, and put it back if it moved.
    ///
    /// `reassertFocusLock` writes from inside `lockForConfiguration`, which is
    /// the right place to write — the lens must not be handed to auto even
    /// briefly — but the wrong place to verify, because the device still
    /// reports its pre-commit state there. This is the only check that can see
    /// the focus the next segment will actually record through, and it runs
    /// before that segment's first frame.
    ///
    /// Read-only on every healthy switch. When it does find a drift it says so
    /// in the session log, so a shoot that loses focus again leaves evidence
    /// instead of just a soft file.
    private func verifyFocusHold(on device: AVCaptureDevice?) {
        #if os(iOS)
        guard let device, focusIsHeld, device.isFocusModeSupported(.locked) else { return }
        let custom = device.isLockingFocusWithCustomLensPositionSupported
        let held = custom ? heldLensPosition(for: device) : nil
        let lensDrifted = held.map { abs(device.lensPosition - $0) >= 0.001 } ?? false
        let modeLost = device.focusMode != .locked
        guard modeLost || lensDrifted else { return }
        LLog(String(
            format: "focus: hold did not survive the switch (mode=%@ lens=%.3f want=%.3f) — re-pinning",
            modeLost ? "auto" : "locked", device.lensPosition, held ?? -1))
        CaptureSessionLogger.shared.log("focus_switch_repair", [
            "modeLost": modeLost,
            "lensPosition": device.lensPosition,
            "wanted": held ?? -1,
        ])
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            // Same expression `reassertFocusLock` uses, so a repair can never
            // land somewhere the ordinary path wouldn't have.
            device.setFocusModeLocked(
                lensPosition: (custom ? held : nil) ?? AVCaptureDevice.currentLensPosition,
                completionHandler: nil)
        } catch {
            LLog("focus: switch repair could not lock — \(error.localizedDescription)")
        }
        #else
        _ = device
        #endif
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
                // The codec is part of the resolution's identity, not a
                // preference: ProRes and HEVC entries share pixel dimensions
                // and appear as separate rows, `CaptureResolution.id` and
                // `CaptureCapabilityKey` both key on the flag, and a segment
                // boundary that changed codec would not stitch. Without this
                // test a ProRes row could resolve to a same-dimension HEVC
                // format — and picking base and burst formats on two axes gives
                // that far more chances to happen.
                let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                let codecMatches = Self.proResFourCCs.contains(subType) == resolution.isProRes
                return dims.width == resolution.width
                    && dims.height == resolution.height
                    && codecMatches
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
                // With Capture Flat on, a Log-capable format outranks
                // everything below: several formats can share one
                // resolution + rate and differ only in offering Apple Log,
                // and nothing else in this sort knows Log exists — so the
                // pick could land on a Log-less sibling and the colour
                // space would silently stay sRGB (which it did: 2026-08-14,
                // a 4K·10 Capture Flat shoot came out bt709). An explicit
                // user intent, so ranked above the stabilization tiebreak.
                if #available(iOS 17.2, *), appleLogEnabled {
                    let firstLog = first.format.supportedColorSpaces.contains(.appleLog)
                    let secondLog = second.format.supportedColorSpaces.contains(.appleLog)
                    if firstLog != secondLog {
                        return firstLog
                    }
                }
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
        // Device-wide Log capability, computed here because every
        // reconfiguration funnels through publishFormat — including the first
        // one, which is what makes the answer available to a capture screen
        // that asked too early on appear (the launch race this replaces a
        // computed property to fix).
        var supportsLog = false
        #if os(iOS)
        if #available(iOS 17.2, *) {
            supportsLog = device.formats.contains {
                $0.supportedColorSpaces.contains(.appleLog)
            }
        }
        #endif
        DispatchQueue.main.async {
            self.videoStabilizationStatus = stabilizationStatus
            self.activeFormatDescription = line
            if self.previewDimensions != preview {
                self.previewDimensions = preview
            }
            if self.supportsAppleLog != supportsLog {
                self.supportsAppleLog = supportsLog
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

    /// The pose a frame captured right now would be tagged with.
    ///
    /// A preview pixel buffer always arrives in the sensor's own landscape
    /// regardless of how the phone is held, so anything that shows one — the
    /// Watch framing preview — has to rotate it by this or it will show a
    /// portrait shot lying on its side.
    var currentCaptureOrientation: AVCaptureVideoOrientation {
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
    /// Focus only — the Holy Grail lock. Locking exposure is what a ramping
    /// shoot must never do (the ramp *is* the exposure), but focus hunting
    /// mid-shoot is exactly as ruinous here as anywhere else, so the lock
    /// button keeps its job and drops the half that doesn't apply. White
    /// balance is locked with it: a ramp that walks into dusk under auto WB
    /// writes its own colour flicker.
    func toggleFocusLock() {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            let wantsLock = !self.focusLocked
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if wantsLock {
                    if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                    if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                    #if os(iOS)
                    let lens = device.lensPosition
                    self.rememberLensPosition(lens, on: device)
                    DispatchQueue.main.async { self.lockedLensPosition = lens }
                    #endif
                } else {
                    if !self.retainFocusIfCapturing(),
                       device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                }
            } catch {
                LLog("focus lock: lockForConfiguration failed — \(error.localizedDescription)")
                return
            }
            self.focusLocked = wantsLock
            // Unlocking is the user asking for the camera back, which includes
            // giving up a tapped subject and a hand-driven lens — otherwise the
            // button would report "auto" over a lens still pinned to a point or
            // a position they can't see.
            if !wantsLock {
                self.manualLensHeld = false
                self.clearTapFocus()
            }
            CaptureSessionLogger.shared.log(
                wantsLock ? "focus_lock" : "focus_unlock", [:])
            self.publishFocusHold()
            DispatchQueue.main.async { self.isFocusLocked = wantsLock }
        }
    }

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
                // This lock really did stop the lens (above), so it owns focus
                // until the matching unlock — unlike the brightness slider,
                // which sets `exposureLocked` and nothing else.
                self.exposureLockHoldsFocus = device.isFocusModeSupported(.locked)
                self.publishFocusHold()
                #if os(iOS)
                CaptureSessionLogger.shared.log("exposure_lock", [
                    "iso": iso,
                    "shutterSeconds": duration.seconds,
                    "shutterLabel": "1/\(Int((1 / max(duration.seconds, 0.000001)).rounded()))",
                    "lensPosition": lens,
                ])
                self.lockedISOValue = iso
                self.lockedShutterValue = duration.seconds
                self.rememberLensPosition(lens, on: device)
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
                if !self.retainFocusIfCapturing(),
                   device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                self.exposureLocked = false
                self.exposureLockHoldsFocus = false
                self.manualLensHeld = false
                // This already put the lens back on continuous auto above, so
                // the pin is dropped without a second write.
                self.clearTapFocus()
                CaptureSessionLogger.shared.log("exposure_unlock")
                self.publishFocusHold()
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
                self.rememberLensPosition(applied, on: device)
                self.manualLensHeld = true
                // Driving the lens by hand supersedes a tapped subject: leaving
                // the pin standing would let the next re-acquire pull the slider
                // back to wherever the tap landed.
                self.tapFocusLocked = false
                self.tapFocusPoint = nil
                self.publishFocusHold()
                DispatchQueue.main.async {
                    self.lockedLensPosition = applied
                }
            } catch {}
        }
        #else
        _ = position
        #endif
    }

    // MARK: - Focus hold (tap to focus, and the lock every shoot takes)

    /// sessionQueue → main. The one place that decides what the viewfinder is
    /// told about focus.
    private func publishFocusHold() {
        let held = focusIsHeld
        let byTap = tapFocusLocked
        DispatchQueue.main.async {
            if self.isFocusHeld != held { self.isFocusHeld = held }
            if self.isFocusPinnedByTap != byTap { self.isFocusPinnedByTap = byTap }
        }
    }

    /// sessionQueue-confined. Bounded wait for the lens to stop moving.
    ///
    /// Modelled on `awaitConstituentSettle`: a blocking poll is the honest
    /// shape, because everything queued behind it — the lock, the format write,
    /// the first segment — is ordered work on this queue that must not overtake
    /// it. `expectStart` covers a focus we just asked for: the ISP takes a beat
    /// to even begin moving, and without the grace window the poll reads
    /// "settled" off the frame before the hunt started. A hunt that outlasts the
    /// budget is locked wherever it got to and said out loud — carrying on into
    /// the run under continuous auto-focus is the failure this path exists to
    /// prevent.
    private func awaitFocusSettle(
        on device: AVCaptureDevice,
        expectStart: Bool = false,
        startingFromLocked: Bool = false,
        timeout: TimeInterval = 1.5
    ) {
        if expectStart {
            // Coming out of a hard lock the ISP takes appreciably longer to
            // begin than it does from continuous auto — the motor is parked, not
            // tracking. 0.12s was short enough to expire first, and then the
            // poll below read "settled" off a frame from before the hunt had
            // started, so `pinFocusHere` re-pinned the lens exactly where it
            // already was. That is a tap that is accepted, draws its reticle,
            // and moves nothing.
            let grace = startingFromLocked ? 0.35 : 0.12
            let graceUntil = Date().addingTimeInterval(grace)
            while !device.isAdjustingFocus, Date() < graceUntil {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if !device.isAdjustingFocus {
                LLog(String(format: "focus: no hunt began within %.2fs — lens may not move", grace))
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while device.isAdjustingFocus, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if device.isAdjustingFocus {
            LLog(String(format: "focus: still hunting after %.1fs — pinning where it is", timeout))
        }
    }

    /// sessionQueue-confined. The lens position to re-assert on `device`, or nil
    /// when nothing comparable has been measured on it.
    private func heldLensPosition(for device: AVCaptureDevice) -> Float? {
        guard lockedLensDevice === device else { return nil }
        return lockedLensValue
    }

    /// sessionQueue-confined. Record a measured lens position against the camera
    /// it was measured on. Every write to `lockedLensValue` goes through here so
    /// the stamp can never drift from the value.
    private func rememberLensPosition(_ position: Float, on device: AVCaptureDevice) {
        lockedLensValue = position
        lockedLensDevice = device
    }

    /// sessionQueue-confined. Pin the lens where it is now and remember the
    /// position, so every later configuration change can put it back.
    private func pinFocusHere(on device: AVCaptureDevice) {
        guard device.isFocusModeSupported(.locked) else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            #if os(iOS)
            let custom = device.isLockingFocusWithCustomLensPositionSupported
            device.setFocusModeLocked(
                lensPosition: custom ? device.lensPosition : AVCaptureDevice.currentLensPosition,
                completionHandler: nil)
            let lens = device.lensPosition
            rememberLensPosition(lens, on: device)
            DispatchQueue.main.async { self.lockedLensPosition = lens }
            #else
            device.focusMode = .locked
            #endif
        } catch {
            LLog("focus: lockForConfiguration failed — \(error.localizedDescription)")
        }
    }

    /// sessionQueue-confined. Hand the lens back to the camera — the one place
    /// that does it, and the counterpart to every path that pins.
    ///
    /// The point of interest goes back to centre with the mode. It is per-device
    /// state that outlives a focus mode change, so leaving it on a subject the
    /// user has moved on from would have continuous auto-focus quietly keep
    /// weighting the last tap for the rest of the app's life.
    private func resumeContinuousAutoFocus(on device: AVCaptureDevice? = nil) {
        guard let device = device ?? videoDevice else { return }
        guard device.isFocusModeSupported(.continuousAutoFocus)
                || device.isFocusPointOfInterestSupported else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        } catch {
            LLog("focus: could not resume auto — \(error.localizedDescription)")
            return
        }
        manualLensHeld = false
        if lockedLensDevice === device {
            lockedLensValue = nil
            lockedLensDevice = nil
        }
    }

    /// Pin the lens for the length of a capture run.
    ///
    /// A user presses record when the shot looks right, and that includes
    /// focus — so the lens has to stop moving at exactly that moment and stay
    /// stopped until the run ends. Before this, the opposite happened: the
    /// shutter press pins the run to one physical lens (a device input swap)
    /// and then writes `activeFormat`, and each of those hands focus back to
    /// continuous auto — so the opening frames of a take were shot through a
    /// hunt, and every burst boundary re-opened one mid-shoot.
    ///
    /// `deviceChanged` means the run just moved to a different camera, which
    /// buys a grace window for a lens that may start hunting on its own as it
    /// joins the session — and a re-aim when the user had tapped a subject,
    /// since a point of interest is per-device state. Otherwise nothing is
    /// asked of the lens at all: it is pinned exactly where the user left it.
    ///
    /// sessionQueue-confined. Called after any input swap the run performs and
    /// before its first frame.
    private func lockFocusForRun(deviceChanged: Bool) {
        guard let device = videoDevice, device.isFocusModeSupported(.locked) else { return }
        // A lock the user took themselves already owns focus, and owns it past
        // the end of this run — taking a second one over the top would mean
        // releasing theirs when ours ends. Manual *exposure* alone is not such a
        // lock: bailing on it meant a shoot where the user had only touched
        // brightness took no focus hold at all, and then had one written over it
        // by the first format change with nothing tracking it.
        guard !focusHeldByUser else { return }

        // Aim again only when the user picked a subject and the run has moved to
        // a different camera: a point of interest is per-device state, so the
        // new lens has never been told about it. Deliberately NOT an
        // unconditional re-focus on every device change — an `AVCaptureDevice`
        // is a shared object, and the constituent a run pins to is usually the
        // one that was already driving the preview, focused on what the user is
        // looking at. Re-hunting that would be a visible pump at the shutter
        // press, in the name of finding the plane it was already on.
        if deviceChanged, let point = tapFocusPoint {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                }
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            } catch {
                LLog("focus: run lock could not aim — \(error.localizedDescription)")
            }
        }
        // Never pin mid-hunt. A lens caught between two planes is worse than the
        // hunt was, because nothing will correct it for the whole run. The grace
        // window on a device change covers both the aim above and a fresh input
        // that starts hunting for itself the moment it joins the session.
        awaitFocusSettle(on: device, expectStart: deviceChanged)
        pinFocusHere(on: device)
        runFocusLocked = true
        publishFocusHold()
        // -1 reads as "no comparable position" — the Mac has no lens position at
        // all, and neither does a device nothing has measured yet.
        let pinned = heldLensPosition(for: device) ?? -1
        CaptureSessionLogger.shared.log("focus_run_lock", [
            "lensPosition": pinned,
            "source": tapFocusLocked ? "tap" : "auto",
            "deviceChanged": deviceChanged,
        ])
        LLog(String(format: "focus: run pinned at lens %.3f%@", pinned,
                    deviceChanged ? " (after lens change)" : ""))
    }

    /// Hand the lens back at the end of a shoot. Focus is a per-shoot decision:
    /// whatever aimed this run — a tap, or the run's own hold at the shutter
    /// press — is spent when the run is, and the next shoot starts from a camera
    /// that is focusing for itself again.
    ///
    /// The one thing that survives is a lock the user took themselves, because
    /// it is a standing choice with a control on screen still reporting it and a
    /// way to undo it. A tap has neither, which is what made it able to strand
    /// the lens with nothing left to release it.
    ///
    /// sessionQueue-confined.
    private func releaseRunFocusLock() {
        guard runFocusLocked else { return }
        runFocusLocked = false
        clearTapFocus()
        guard !focusHeldByUser else { publishFocusHold(); return }
        resumeContinuousAutoFocus()
        publishFocusHold()
        LLog("focus: run lock released")
    }

    /// sessionQueue-confined. Aim the lens at a point the user picked, then pin
    /// it there.
    ///
    /// `.autoFocus` parks the lens when it converges but leaves the device one
    /// subject-area change away from moving again, so the settled result is
    /// promoted to a hard lock. That is what makes the promise hold: what the
    /// user tapped is what the shutter press inherits.
    private func applyTapFocus(_ point: CGPoint) {
        guard let device = videoDevice else { return }
        // Coming out of a hard lock needs a longer grace before the hunt is
        // judged to have started (see `awaitFocusSettle`).
        let wasLocked = device.focusMode == .locked
        #if os(iOS)
        // Where the lens was before the tap, so the log can show a tap that
        // asked for a hunt and got no movement — the way this path is most
        // likely to fail, and the one that looks like nothing happened.
        let before = device.lensPosition
        #endif
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
            }
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
        } catch {
            LLog("focus tap: lockForConfiguration failed — \(error.localizedDescription)")
            return
        }
        tapFocusPoint = point
        tapFocusLocked = true
        publishFocusHold()
        awaitFocusSettle(on: device, expectStart: true, startingFromLocked: wasLocked)
        pinFocusHere(on: device)
        #if os(iOS)
        let after = device.lensPosition
        CaptureSessionLogger.shared.log("focus_tap", [
            "x": Double(point.x), "y": Double(point.y),
            "lensBefore": before, "lensPosition": after,
            "moved": abs(after - before) >= 0.001,
        ])
        LLog(String(format: "focus: tap at %.2f,%.2f pinned at lens %.3f (from %.3f)",
                    point.x, point.y, after, before))
        #else
        CaptureSessionLogger.shared.log("focus_tap", [
            "x": Double(point.x), "y": Double(point.y),
        ])
        #endif
    }

    /// sessionQueue-confined. An unlock that lands mid-shoot gives the user
    /// their exposure and white balance back, but never the lens: a running
    /// shoot holds focus, full stop, and a lock button is not an exception to
    /// that. The hold is transferred to the run, so the ordinary end-of-run
    /// release still hands the camera back at the right moment.
    ///
    /// Returns true when the caller must leave focus alone.
    private func retainFocusIfCapturing() -> Bool {
        guard captureIsRunning else { return false }
        runFocusLocked = true
        LLog("focus: unlock kept the lens pinned — a shoot is running")
        return true
    }

    /// sessionQueue-confined. Whether a shoot is actually running, asked of the
    /// objects doing the shooting rather than of the `@Published` mirrors.
    ///
    /// The mirrors are for the UI and can be wrong: they are written on the main
    /// queue, they lag a run that has just started, and a teardown that misses
    /// one strands it true forever. Gating tap-to-focus on `isIntervalRunning`
    /// while gating lens changes on `intervalTimer` is what let a stranded flag
    /// disable tapping while pinching still worked — the exact shape of the bug
    /// that made "pinch to change lens" look like a focus fix.
    private var captureIsRunning: Bool {
        movieOutput.isRecording || intervalTimer != nil || isLiveBlendActive
    }

    /// Give up a tapped subject. Both callers are unlock paths that have already
    /// put the lens back on continuous auto in the same configuration block, so
    /// this only drops the state that would otherwise re-acquire the point later
    /// — it never writes to the device itself.
    /// sessionQueue-confined.
    private func clearTapFocus() {
        guard tapFocusLocked || tapFocusPoint != nil else { return }
        tapFocusLocked = false
        tapFocusPoint = nil
        publishFocusHold()
    }

    /// sessionQueue-confined. Picking a lens is picking a shot, so it hands focus
    /// back to the camera for the new framing.
    ///
    /// A tapped point does not survive the change: it is expressed in an image
    /// the stop has just re-cropped, and on a virtual camera the stop can hand
    /// over to a different constituent outright, where the point has never been
    /// set and the lens position it was pinned at means nothing. Re-acquiring it
    /// was how a plane from the last shot followed the user into the next one.
    ///
    /// An explicit focus lock is re-taken rather than dropped — the button is
    /// still on screen saying "locked" — but re-taken *on the new camera*, after
    /// a hunt, so it holds a real plane instead of a stale number.
    private func releaseFocusForLensChange() {
        guard !captureIsRunning else { return }
        clearTapFocus()
        guard let device = videoDevice else { return }
        guard focusHeldByUser else {
            resumeContinuousAutoFocus(on: device)
            return
        }
        guard device.isFocusModeSupported(.autoFocus) else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            device.focusMode = .autoFocus
        } catch {
            LLog("focus: lens change could not re-aim — \(error.localizedDescription)")
            return
        }
        awaitFocusSettle(on: device, expectStart: true, startingFromLocked: true)
        pinFocusHere(on: device)
    }

    #if os(iOS)
    /// A tap on the viewfinder: focus there, and hold it.
    ///
    /// `point` is in the preview layer's own coordinates — the layer converts
    /// it, because only the layer knows the letterboxing, the mirroring and the
    /// rotation between what is on screen and what the sensor sees. A tap that
    /// lands in the letterbox bars converts to a point outside the image and is
    /// refused rather than clamped to an edge nobody aimed at.
    ///
    /// Refused outright while a shoot is running: focus is locked for the whole
    /// of one, and a stray touch on a rigged phone must not be able to move it.
    /// Returns false when the tap was refused, so the viewfinder doesn't draw a
    /// reticle for something that didn't happen.
    @discardableResult
    func focusPreview(atLayerPoint point: CGPoint) -> Bool {
        guard let layer = previewLayer else { return false }
        // A UI-side fast path, not the authority — the same three flags the
        // capture chrome is drawn from, so a tap during a visible run doesn't
        // draw a reticle. Every teardown must clear them (see `stop()`): a
        // stranded flag here refuses taps for the life of the controller, while
        // lens changes carry on working off `captureIsRunning`.
        guard !isRecording, !isIntervalRunning, !isLiveBlendRunning else { return false }
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: point)
        guard (0...1).contains(devicePoint.x), (0...1).contains(devicePoint.y) else { return false }
        sessionQueue.async {
            // The authority, on the queue that owns the device.
            guard !self.captureIsRunning else { return }
            self.applyTapFocus(devicePoint)
        }
        return true
    }
    #endif

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
            // recording (see detachTestCardTapNow). The Watch framing tap is
            // the same kind of output and carries the same hazard.
            self.detachTestCardTapNow()
            self.detachFramingTapNow()

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
            // One burst format per sequence, snapshotted here alongside the
            // orientation and the lens. Rate can still move between bursts;
            // resolution cannot, because the lens pin below validated exactly
            // these two formats and nothing revalidates them mid-run.
            let burstResolution = mode == .ramp ? self.selectedBurstResolution : self.selectedResolution
            self.activeSequenceBurstResolution = burstResolution
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
            self.markIntervalActive = false
            self.markGeneration += 1
            #if os(iOS)
            // One orientation per sequence: every segment records with the
            // pose the run started in (see activeSequenceOrientation).
            self.activeSequenceOrientation = self.captureOrientation()
            // One lens per sequence, alongside one orientation per sequence:
            // decided here from every rate the run can reach, held to the last
            // segment (see pinLensForSequence).
            var runConfigurations = [(resolution: self.selectedResolution, fps: baseFrameRate)]
            if mode == .ramp {
                runConfigurations.append((burstResolution, self.selectedRampFrameRate))
            }
            let deviceBeforePin = self.videoDevice
            self.pinLensForSequence(configurations: runConfigurations)
            // Focus is decided HERE — at the shutter press, on whatever the run
            // will actually shoot through — and held to the last segment. After
            // the pin, because a swapped input arrives with its own lens to
            // settle; before the first segment, because that segment's format
            // write would otherwise hand focus straight back to auto.
            self.lockFocusForRun(deviceChanged: self.videoDevice !== deviceBeforePin)
            #else
            self.lockFocusForRun(deviceChanged: false)
            #endif
            // One format per sequence when the sensor offers it, alongside
            // one lens and one orientation: with both rates on a single
            // format, every segment switch is a frame-duration change (see
            // sequenceSharedRampRates). Set before the first segment so the
            // run opens on the shared format rather than switching onto it.
            //
            // A burst that changes resolution can have no such format, so the
            // preference is switched off rather than left to mis-sort: it would
            // rank formats by whether they carry both rates, when the two
            // segments are landing on different formats by design. That run
            // pays the full `activeFormat` switch at every boundary — the cost
            // the burst resolution is bought with.
            self.sequenceSharedRampRates =
                mode == .ramp
                && baseFrameRate != self.selectedRampFrameRate
                && burstResolution == self.selectedResolution
                ? [baseFrameRate, self.selectedRampFrameRate] : []
            CaptureSessionLogger.shared.log("burst_set", [
                "fps": self.selectedRampFrameRate,
                "resolution": "\(burstResolution.width)x\(burstResolution.height)",
                "mode": mode.rawValue,
                "baseFPS": baseFrameRate,
            ])
            CaptureSessionLogger.shared.log("capture_start", [
                "kind": "video",
                "fps": baseFrameRate,
                "resolution": "\(resolution.width)x\(resolution.height)",
                "sequenceMode": mode.rawValue,
            ])
            self.startNextSegment(
                resolution: self.selectedResolution, frameRate: self.selectedFrameRate)
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
                // A mark left open at the stop still has a real end — the end
                // of the run. Closing it here beats writing a sidecar with a
                // dangling `relativeEnd: nil` that every reader downstream has
                // to invent a value for.
                self.closeOpenMarkInterval(at: Date())
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

    // MARK: - Watch framing tap

    /// Attach the Watch framing preview's tap (see FramingPreviewService).
    /// Same guards and the same reasoning as the test-card tap: idle only,
    /// because adding an output reconfigures the session and doing that under
    /// a live writer kills the recording.
    // The tap type lives in FramingPreviewService, which is iOS-only — the
    // Watch link it serves does not exist on a Mac. `detachFramingTapNow` is
    // deliberately NOT guarded: it is called from the cross-platform capture
    // starts, and a no-op there is cheaper than another `#if` at each site.
    #if os(iOS)
    func startFramingTap(_ tap: FramingFrameTap) {
        sessionQueue.async {
            guard !self.movieOutput.isRecording,
                  self.activeSequence == nil,
                  !self.intervalActive else {
                LLog("framing: tap refused — capture in flight")
                return
            }
            let output: AVCaptureVideoDataOutput
            if let existing = self.framingOutput {
                output = existing
            } else {
                output = AVCaptureVideoDataOutput()
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ]
                output.alwaysDiscardsLateVideoFrames = true
                self.framingOutput = output
            }
            if !self.session.outputs.contains(output) {
                self.session.beginConfiguration()
                if self.session.canAddOutput(output) {
                    self.session.addOutput(output)
                } else {
                    LLog("framing: session refused the preview tap")
                }
                self.session.commitConfiguration()
            }
            output.setSampleBufferDelegate(tap, queue: tap.queue)
        }
    }

    func stopFramingTap() {
        sessionQueue.async {
            self.detachFramingTapNow()
        }
    }
    #endif

    /// sessionQueue-confined, synchronous detach — called inline from every
    /// capture start for exactly the reason `detachTestCardTapNow` is.
    private func detachFramingTapNow() {
        guard let output = framingOutput else { return }
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.outputs.contains(output) {
            session.beginConfiguration()
            session.removeOutput(output)
            session.commitConfiguration()
            LLog("framing: tap detached")
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
            // The run's two formats, not the pickers': `selectedResolution` is
            // the base menu's value and a burst may land somewhere else.
            let baseResolution = CaptureResolution(
                width: sequence.lockedResolution.width,
                height: sequence.lockedResolution.height,
                isProRes: selectedResolution.isProRes)
            let targetResolution = shouldTurnRampOn
                ? (activeSequenceBurstResolution ?? baseResolution)
                : baseResolution
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
            pendingRampResolution = targetResolution
            beginSwitchExposureHold { [weak self] in
                guard let self else { return }
                // Then the CADENCE latch, on the same principle: write the new
                // frame duration now and hold, so the sensor's re-timing frames
                // stay in this segment's tail instead of opening the next file
                // at the wrong rate. A step DOWN needs no wait — slowing down
                // just means waiting longer between reads, and the 2026-08-13
                // shoot's 100→25 segment is clean from its first frame.
                guard targetFrameRate > currentFrameRate,
                      self.prepareRampRateChange(to: targetResolution, fps: targetFrameRate)
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

    // MARK: - Marks

    /// Annotate the moment being shot: an in point, an out point, nothing else.
    ///
    /// **A mark changes no footage.** It opens no file, switches no frame rate,
    /// and costs the capture pipeline nothing — it is a note that says "come
    /// back to this stretch", recorded at whatever rate the run is already
    /// shooting at. That is why it is available in any mode and at any moment,
    /// where a burst is not.
    ///
    /// Wholly independent of `rampIntervals`: a mark can be opened before a
    /// burst and closed after it, or the other way round, and neither one's
    /// state is entangled with the other's.
    ///
    /// `seconds > 0` closes it on the phone's own timer, so the OUT lands even
    /// if the wrist that asked for it has gone to sleep.
    func toggleMarkInterval(seconds: Double = 0) {
        sessionQueue.async {
            guard self.activeSequence != nil, let startedAt = self.activeSequenceStartedAt else { return }
            if self.markIntervalActive {
                self.closeOpenMarkInterval(at: Date())
                return
            }
            self.openMarkInterval(at: Date(), sequenceStartedAt: startedAt)
            guard seconds > 0 else { return }
            self.markGeneration += 1
            let generation = self.markGeneration
            self.sessionQueue.asyncAfter(deadline: .now() + seconds) {
                // A later manual close (or a new mark) supersedes this timer;
                // the generation is what tells them apart.
                guard generation == self.markGeneration, self.markIntervalActive else { return }
                self.closeOpenMarkInterval(at: Date())
            }
        }
    }

    private func openMarkInterval(at date: Date, sequenceStartedAt: Date) {
        guard var sequence = activeSequence, !markIntervalActive else { return }
        let interval = LiveCaptureSequence.RampInterval(
            index: sequence.markIntervals.count,
            relativeStart: date.timeIntervalSince(sequenceStartedAt),
            relativeEnd: nil
        )
        sequence.markIntervals.append(interval)
        activeSequence = sequence
        markIntervalActive = true
        CaptureSessionLogger.shared.log("mark_in", [
            "index": interval.index,
            "atSeconds": interval.relativeStart,
        ])
        publishMarkState(isActive: true, count: sequence.markIntervals.count)
    }

    private func closeOpenMarkInterval(at date: Date) {
        guard var sequence = activeSequence,
              markIntervalActive,
              let sequenceStartedAt = activeSequenceStartedAt,
              let index = sequence.markIntervals.lastIndex(where: { $0.relativeEnd == nil })
        else { return }
        let relativeEnd = max(
            sequence.markIntervals[index].relativeStart,
            date.timeIntervalSince(sequenceStartedAt)
        )
        sequence.markIntervals[index].relativeEnd = relativeEnd
        activeSequence = sequence
        markIntervalActive = false
        CaptureSessionLogger.shared.log("mark_out", [
            "index": sequence.markIntervals[index].index,
            "atSeconds": relativeEnd,
            "durationSeconds": relativeEnd - sequence.markIntervals[index].relativeStart,
        ])
        publishMarkState(isActive: false, count: sequence.markIntervals.count)
    }

    private func publishMarkState(isActive: Bool, count: Int) {
        DispatchQueue.main.async {
            self.isMarkActive = isActive
            self.markIntervalCount = count
        }
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

    /// Opens the next segment file at `resolution`/`frameRate`.
    ///
    /// Resolution is a parameter rather than `selectedResolution` because a
    /// ramp run can hold two: base segments at the shot's resolution, burst
    /// segments at a higher one so a punch-in has pixels to crop. Both were
    /// validated against the pinned lens before the run started.
    private func startNextSegment(resolution: CaptureResolution, frameRate: Int) {
        guard let directory = activeSequenceDirectory else { return }
        // Every segment records on the device the run started on: the burst
        // format is a format change, never an input change. The formats the
        // picker offers are exactly the ones this device can shoot without one
        // (see DeviceCapabilityMatrix).
        _ = applyCaptureFormat(resolution: resolution, fps: frameRate)
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

        // Last look at the lens before the segment opens. The re-assert above
        // ran inside the format's configuration block, where the device cannot
        // yet report what the commit did to it; here it can. A segment that
        // would have opened on a hunting lens is repaired instead of recorded.
        verifyFocusHold(on: videoDevice)

        let index = segmentURLs.count
        let url = directory.appendingPathComponent(String(format: "segment-%03d.mov", index))
        activeSegmentURL = url
        activeSegmentStartedAt = Date()
        // The honest stamp arrives from the writer's did-start callback; a
        // leftover from the previous segment must never masquerade as it.
        activeSegmentRecordedStartAt = nil
        activeRecordingFrameRate = frameRate
        activeRecordingResolution = resolution
        #if os(iOS)
        LLog("segment \(String(format: "%03d", index)) start: running=\(session.isRunning)"
            + " interrupted=\(session.isInterrupted) inputs=\(session.inputs.count)"
            + " fps=\(frameRate) \(resolution.label)")
        #else
        LLog("segment \(String(format: "%03d", index)) start: running=\(session.isRunning)"
            + " inputs=\(session.inputs.count) fps=\(frameRate) \(resolution.label)")
        #endif
        movieOutput.startRecording(to: url, recordingDelegate: self)

        DispatchQueue.main.async {
            self.selectedFrameRate = frameRate
            // Published separately from `selectedResolution` rather than
            // overwriting it: that one is the *base* selection the format sheet
            // and `refreshCaptureOptions` own, and persisting a burst's
            // resolution into it would silently promote the whole shoot.
            self.activeSegmentResolution = resolution
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
            settleSeconds: timing.settleSeconds,
            // Stamped only when it differs from the sequence's locked
            // resolution, so a single-resolution shoot writes exactly the
            // sidecar it wrote before this feature existed.
            resolution: activeRecordingResolution.flatMap { recorded in
                let value = LiveCaptureSequence.Resolution(
                    width: recorded.width, height: recorded.height)
                return value == sequence.lockedResolution ? nil : value
            }
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
        activeRecordingResolution = nil
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
        // After the pin release and the resting-format re-pin, not before: both
        // re-apply a format, and holding focus through them keeps the idle
        // viewfinder still while the run winds down. Only then does the lens go
        // back to whatever should own it now (see releaseRunFocusLock).
        releaseRunFocusLock()
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
        activeRecordingResolution = nil
        activeSequenceBurstResolution = nil
        activeSegmentURL = nil
        segmentURLs = []
        pendingRampFrameRate = nil
        pendingRampResolution = nil
        isFinishingSequence = false
        DispatchQueue.main.async { self.activeSegmentResolution = nil }
        isDiscardingSequence = false
        rampIntervalActive = false
        markIntervalActive = false
        markGeneration += 1
        DispatchQueue.main.async {
            self.activeSequenceMode = nil
            self.isMarkActive = false
            self.markIntervalCount = 0
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
            // Same ordering rule as startRecording: both preview taps detach
            // inline before any capture work.
            self.detachTestCardTapNow()
            self.detachFramingTapNow()
            // Same rule as a video take: the shot is in focus when the user
            // presses the shutter, so the lens stops there for the whole run.
            // An interval shoot is the least forgiving of the three — a hunt
            // three frames in is baked into the finished timelapse for good.
            self.lockFocusForRun(deviceChanged: false)
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
                #if os(iOS)
                settings.suppressShutterSound(for: self.photoOutput)
                #endif
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
        let wasHolyGrail = self.holyGrailActive
        self.endHolyGrailIfActive()
        self.releaseRunFocusLock()
        let urls = self.photoURLs
        CaptureSessionLogger.shared.log(
            "capture_end",
            ["kind": wasHolyGrail ? "holyGrail" : "interval", "frameCount": urls.count])
        self.intervalFrameCap = nil
        self.intervalFramesRequested = 0
        DispatchQueue.main.async {
            self.isIntervalRunning = false
            if urls.count >= 1 {
                self.onFinishPhotos?(urls)
            }
        }
    }

    // MARK: - Holy Grail (auto-ramping interval)

    // iOS/iPadOS only, and not by omission: the ramp needs a numeric exposure
    // envelope (`format.min/maxExposureDuration`, `min/maxISO`), manual
    // exposure (`setExposureModeCustom`), per-frame EXIF off the capture
    // (`AVCapturePhoto.metadata`) and Bayer RAW — none of which AVFoundation
    // offers on macOS. The capture screen hides the RAMP dial there rather
    // than pretending a webcam can do this.
    #if os(iOS)

    /// How long to give a custom exposure to take effect before firing the
    /// shutter, when the device doesn't report the latch itself. The ISP needs
    /// a few frames for a large ISO move; 0.3 s covers it at every rate the
    /// photo configuration runs at.
    private static let holyGrailSettleSeconds: TimeInterval = 0.3

    /// sessionQueue-confined. Seeds the ramp from the exposure AE is delivering
    /// right now, so the first frame is already correct and the 1/3-stop limit
    /// costs nothing at the head of the shoot.
    private func seedHolyGrailRamp(interval: TimeInterval) {
        guard let device = videoDevice else {
            holyGrailEngine = nil
            holyGrailLimits = nil
            return
        }
        let limits = holyGrailHardwareLimits(for: device, interval: interval)
        holyGrailLimits = limits
        let seed = HolyGrailRampEngine.ExposureTarget(
            shutterSeconds: device.exposureDuration.seconds, iso: device.iso)
        holyGrailEngine = HolyGrailRampEngine(seed: seed, limits: limits)
    }

    /// sessionQueue-confined. The envelope the ramp may move inside.
    ///
    /// Two ceilings, and the tighter wins: the format's own
    /// `maxExposureDuration` (1.0 s on every iPhone 16 Pro format — there is
    /// no multi-second native exposure to reach for), and the interval itself.
    /// A shutter longer than the gap between frames would starve the timer and
    /// silently stretch the shoot, so it is bounded to most of the interval.
    private func holyGrailHardwareLimits(
        for device: AVCaptureDevice, interval: TimeInterval
    ) -> HolyGrailRampEngine.HardwareLimits {
        let format = device.activeFormat
        let hardwareCeiling = format.maxExposureDuration.seconds
        let intervalCeiling = max(0.05, interval - Self.holyGrailSettleSeconds)
        let ceiling = max(format.minExposureDuration.seconds, min(hardwareCeiling, intervalCeiling))
        return HolyGrailRampEngine.HardwareLimits(
            minShutter: format.minExposureDuration,
            maxShutter: HolyGrailRampEngine.time(ceiling),
            minISO: format.minISO,
            maxISO: format.maxISO,
            aperture: device.lensAperture)
    }

    /// How a window's worth of frames reported the scene.
    ///
    /// Both cases are **scene-referred**: neither can be moved by the exposure
    /// the ramp itself chose. That is the property the 2026-08-15 iPad runaway
    /// was missing — measuring through our own exposure meant darkening a
    /// frame "proved" the scene had brightened, and the ramp chased itself
    /// 9.7 stops down at exactly 1/3 stop per frame until the shutter floored.
    enum HolyGrailMeasurement {
        /// Mean linear luma of the delivered image (video-tap path). Compared
        /// against a fixed mid-grey reference; the anchor absorbs the constant.
        case luma(Double)
        /// EXIF APEX brightness, straight off the meter (RAW path).
        case apexBrightness(Double)
    }

    /// Mid-grey in linear light — the reference the luma measurement is read
    /// against. Its absolute value doesn't matter (the ramp's anchor folds any
    /// constant out on the first frame); it only has to stay fixed.
    private static let holyGrailReferenceLuma = 0.18

    /// sessionQueue-confined. The one place the ramp moves: measure, step,
    /// write the sidecar line, publish.
    private func advanceHolyGrailRamp(
        frame: Int, shutter: Double, iso: Double, measurement: HolyGrailMeasurement?
    ) {
        guard let limits = holyGrailLimits, let engine = holyGrailEngine,
              let measurement
        else { return }
        // Both routes end in "the EV that would correctly expose this scene".
        let measuredEV: Double
        switch measurement {
        case .apexBrightness(let brightness):
            measuredEV = HolyGrailMetering.sceneEV100(apexBrightness: brightness)
        case .luma(let luma):
            // The exposure we used says what EV this frame *assumed*; how far
            // the delivered image sits from mid-grey says how wrong that
            // assumption was. Darken by a stop and both terms move a stop in
            // opposite directions — so a still scene reads as a still scene,
            // which is precisely what makes the loop stable.
            let gain = HolyGrailRampEngine.lightGain(
                shutterSeconds: shutter > 0 ? shutter : engine.currentTarget.shutterSeconds,
                iso: iso > 0 ? Float(iso) : engine.currentTarget.iso)
            measuredEV = HolyGrailRampEngine.sceneEV100(forGain: gain, aperture: limits.aperture)
                + log2(max(luma, 1e-6) / Self.holyGrailReferenceLuma)
        }

        holyGrailEngine?.advance(measuredEV: measuredEV, limits: limits)

        holyGrailWriter?.append(FrameTimestamps.Entry(
            frame: frame,
            captureTime: Date(),
            shutter: shutter,
            iso: iso,
            ev: holyGrailEngine?.smoothedEV ?? measuredEV))

        publishHolyGrailState()
    }

    /// sessionQueue-confined. A blend window is opening: the exposure chosen
    /// here is held for every frame this window averages.
    ///
    /// Honest limitation: the exposure is applied as the window opens, so the
    /// first frames it collects can still be carrying the previous one while
    /// the ISP latches (~0.3 s). The ramp moves at most 1/3 stop per window,
    /// which bounds that error to a third of a stop on a minority of the
    /// window's frames — visible in the log, not in the picture.
    private func rampHolyGrailBlendWindow(index: Int, measurement: HolyGrailMeasurement?) {
        guard holyGrailActive, let engine = holyGrailEngine else { return }
        // Measure the window that just ended — it ran at the exposure we set
        // last time — then step, then apply for the window now opening. With
        // no measurement (a window that saw no frames) the ramp holds where it
        // is rather than guessing.
        advanceHolyGrailRamp(
            frame: index,
            shutter: engine.currentTarget.shutterSeconds,
            iso: Double(engine.currentTarget.iso),
            measurement: measurement)
        applyHolyGrailExposure()
        repaceHolyGrailAutoInterval()
    }

    /// sessionQueue-confined. EVERY=Auto only: asks the pacing policy what this
    /// exposure deserves and, if the answer has really moved, hands it to
    /// whichever blend controller is running.
    ///
    /// A no-op on a fixed EVERY — the user pinned the floor there and the ramp
    /// manages exposure above it, which is a valid and deliberate combination.
    private func repaceHolyGrailAutoInterval() {
        guard let current = holyGrailAutoIntervalSeconds,
              let engine = holyGrailEngine, let limits = holyGrailLimits else { return }
        // Two demands on the pacing, and the slower one wins: the exposure
        // the light needs, and the window cost the processing pipeline
        // demonstrably pays. The second is what turns a slow device's
        // starved-window churn into fewer, full windows at honest spacing.
        let exposureNext = HolyGrailAutoInterval.seconds(for: engine, limits: limits)
        let processingFloor = liveBlendRawController?.processingPaceFloorSeconds
        let next = max(exposureNext, processingFloor ?? 0)
        if let processingFloor, processingFloor > exposureNext,
           HolyGrailAutoInterval.isMeaningfulChange(from: current, to: next) {
            LLog(String(format: "holygrail: processing pressure paces the interval — %.1fs (exposure wanted %.1fs)", next, exposureNext))
        }
        guard HolyGrailAutoInterval.isMeaningfulChange(from: current, to: next) else { return }
        holyGrailAutoIntervalSeconds = next
        DispatchQueue.main.async { self.activeIntervalSeconds = next }
        liveBlendController?.setIntervalSeconds(next)
        liveBlendRawController?.setIntervalSeconds(next)
        // The envelope moves with the spacing: a wider interval is a longer
        // shutter the ramp is now allowed to reach for.
        if let device = videoDevice {
            let relaxed = holyGrailHardwareLimits(for: device, interval: next)
            holyGrailLimits = relaxed
            holyGrailEngine?.reclamp(to: relaxed)
        }
        LLog("holygrail: auto interval → \(next)s")
    }

    /// sessionQueue-confined. Writes the ramp's current target to the device
    /// and returns; nothing waits for the latch. The stills path needs the
    /// latch before it fires a shutter — see
    /// `applyHolyGrailExposureThenCapture` — but a blend window has no
    /// shutter to time, only frames arriving continuously.
    /// The ramp's last applied exposure, re-clamped to the format that is
    /// mounted *now*.
    ///
    /// Brackets build manual per-shot settings from this, and an out-of-range
    /// manual bracket raises an uncatchable NSException — so the clamp cannot
    /// be skipped. `applyHolyGrailExposure` already clamped before writing,
    /// but the format can change under a running value during teardown or a
    /// camera switch, which is exactly the staleness the `current` sentinels
    /// were meant to avoid. Clamping here keeps that protection while still
    /// carrying the ramp's real numbers, which the sentinels do not on iPad.
    private func rampExposureForBracket() -> (duration: CMTime, iso: Float)? {
        guard let target = holyGrailAppliedExposure.target else { return nil }
        guard let format = videoDevice?.activeFormat else { return target }
        var duration = target.duration
        if CMTimeCompare(duration, format.minExposureDuration) < 0 {
            duration = format.minExposureDuration
        }
        if CMTimeCompare(duration, format.maxExposureDuration) > 0 {
            duration = format.maxExposureDuration
        }
        let iso = min(max(target.iso, format.minISO), format.maxISO)
        return (duration: duration, iso: iso)
    }

    private func applyHolyGrailExposure() {
        guard let device = videoDevice, let target = holyGrailEngine?.currentTarget,
              device.isExposureModeSupported(.custom)
        else { return }
        // Clamp to the format's REAL envelope before writing: an out-of-range
        // duration or ISO makes `setExposureModeCustom` throw an ObjC
        // exception (not a Swift error), and the 2026-08-20 field test's
        // commanded ISO 18 sat below the iPad's floor. The engine's own
        // limits should prevent this; this is the belt at the last write.
        let format = device.activeFormat
        let iso = min(max(target.iso, format.minISO), format.maxISO)
        var duration = target.shutter
        if CMTimeCompare(duration, format.minExposureDuration) < 0 {
            duration = format.minExposureDuration
        }
        if CMTimeCompare(duration, format.maxExposureDuration) > 0 {
            duration = format.maxExposureDuration
        }
        if abs(log2(Double(max(iso, 1)) / Double(max(target.iso, 1)))) > 0.17
            || abs(log2(max(duration.seconds, 1e-6) / max(target.shutter.seconds, 1e-6))) > 0.17 {
            LLog(String(format: """
                holygrail: commanded exposure clamped to the format envelope — \
                asked %.4fs ISO %.0f, applying %.4fs ISO %.0f
                """, target.shutter.seconds, Double(target.iso), duration.seconds, Double(iso)))
        }
        var applied = false
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
            device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
            applied = true
        } catch {
            LLog("holygrail: lockForConfiguration failed — \(error.localizedDescription)")
        }
        if applied {
            // Outside the device-lock scope (no nested locks): what the
            // bracket path keys on, and what the honesty guard compares
            // delivered frames against. Only what was actually written —
            // a failed apply must not move the reference.
            holyGrailAppliedExposure.set((duration: duration, iso: iso))
        }
    }

    /// Starts the ramp alongside a Live Blend run, so a holy-grail shoot can
    /// blend on the way through: each output image is still the average of a
    /// window's frames (the BLEND dial), and the exposure that window is shot
    /// at is the ramp's. Called from `startLiveBlend` on the sessionQueue,
    /// after the controller exists and before it starts.
    private func beginHolyGrailForBlendRun(
        interval: TimeInterval, directory: URL, autoInterval: Bool
    ) {
        holyGrailActive = true
        holyGrailPending = false
        holyGrailRawPixelFormat = nil  // the blend controller owns capture
        holyGrailWriter = FrameTimestampWriter(directory: directory)
        holyGrailFramesWritten = 0
        // Auto starts at the policy's floor and widens from there as the ramp
        // pushes ISO; a fixed EVERY leaves this nil and never re-paces.
        holyGrailAutoIntervalSeconds = autoInterval ? interval : nil
        if autoInterval {
            let opening = interval
            DispatchQueue.main.async { self.activeIntervalSeconds = opening }
        }
        seedHolyGrailRamp(interval: interval)
        applyHolyGrailExposure()
        if let device = videoDevice, !device.isExposureModeSupported(.custom) {
            // The ramp cannot actuate at all here — say so at arm time
            // instead of shooting a run whose brackets silently fall back
            // to a frozen AE (the 2026-08-20 failure shape).
            LLog("holygrail: WARNING — this camera does not support custom exposure; the ramp cannot drive it")
        }
        publishHolyGrailState()
        LLog("holygrail: blending ramp armed, every \(interval)s\(autoInterval ? " (auto)" : "")"
             + " seed=\(holyGrailEngine.map { String(format: "%.4fs ISO %.0f", $0.currentTarget.shutterSeconds, $0.currentTarget.iso) } ?? "none")")
    }

    /// sessionQueue-confined.
    private func publishHolyGrailState() {
        guard let engine = holyGrailEngine, let limits = holyGrailLimits else {
            DispatchQueue.main.async { self.holyGrailState = nil }
            return
        }
        let state = HolyGrailState(
            shutterSeconds: engine.currentTarget.shutterSeconds,
            iso: engine.currentTarget.iso,
            sceneEV: engine.smoothedEV ?? 0,
            frames: photoURLs.count,
            isISORamping: engine.isISORamping(limits: limits),
            isClipped: engine.isClipped(limits: limits),
            isCapturingRAW: holyGrailRawPixelFormat != nil,
            bias: holyGrailBiasStops)
        DispatchQueue.main.async {
            if self.holyGrailState != state { self.holyGrailState = state }
        }
    }

    /// sessionQueue-confined. Called from `finishIntervalOnQueue`, so a Holy
    /// Grail run tears down through exactly the same path as a plain interval
    /// shoot — stop button, frame cap, scheduled stop and screen teardown all
    /// arrive there.
    private func endHolyGrailIfActive() {
        holyGrailRequestedForRun = false
        holyGrailAutoRequestedForRun = false
        holyGrailAutoIntervalSeconds = nil
        DispatchQueue.main.async { self.activeIntervalSeconds = nil }
        holyGrailAppliedExposure.set(nil)
        guard holyGrailActive else { return }
        holyGrailActive = false
        holyGrailPending = false
        LLog("holygrail: end after \(photoURLs.count) frames")
        holyGrailWriter?.close()
        holyGrailWriter = nil
        holyGrailFramesWritten = 0
        holyGrailEngine = nil
        holyGrailLimits = nil
        holyGrailRawPixelFormat = nil
        // Hand the camera back: manual exposure is the run's, not the app's.
        if let device = videoDevice, !exposureLocked, (try? device.lockForConfiguration()) != nil {
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        }
        if holyGrailArmedPhotoAspect {
            holyGrailArmedPhotoAspect = false
            disarmPhotoAspectPreview()
        }
        DispatchQueue.main.async { self.holyGrailState = nil }
    }

    // MARK: - Scanner (motion-triggered interval)

    // Same platform story as the ramp above, for overlapping reasons: Scanner
    // needs a preview tap to difference frames, manual exposure to lock, and
    // RAW to be worth shooting for. The MODE dial doesn't offer it on macOS.
    //
    // Two things make a Scanner run different from every other capture in this
    // file, and both follow from what the frames are *for* — a photogrammetry
    // solver or a compositing stack, not a timelapse:
    //
    // 1. **Nothing about the exposure may move.** A solver seeing the same
    //    surface at two exposures or two white balances reconstructs it worse
    //    than if it had seen it once. AE, AF and WB are locked for the whole
    //    run (§`lockScannerCamera`), and focus in particular is pinned before
    //    the first frame so it cannot hunt between poses.
    // 2. **The shutter is audible on purpose.** Everywhere else in the app a
    //    per-frame shutter sound would be intolerable; here it is the entire
    //    interface. The operator's eyes are on the object, and the click is
    //    what tells them the pose is banked and their hand can go back in.
    //    That is why this path uses real still captures rather than the silent
    //    video tap the Holy Grail JPEG route takes.

    /// How long a fire waits for the device to stop wobbling before it gives up
    /// and skips this pose. Short: the scene has already been still for the
    /// settle delay, so if the phone is *also* not steady by now, something is
    /// holding it and the next re-settle will come round soon enough.
    private static let scannerSteadyTimeout: TimeInterval = 1.5

    /// Answers "is the device itself steady right now?". Set by the capture
    /// screen, which owns the `SteadinessMonitor` — the camera deliberately
    /// doesn't import CoreMotion.
    ///
    /// Scanner requires **both** signals: a still scene and a still device. The
    /// engine watches the scene, this watches the phone, and neither can stand
    /// in for the other — a hand-held phone drifting over a motionless object
    /// produces exactly the frame that ruins a reconstruction, and the scene
    /// difference cannot see it because the whole frame moves together.
    var scannerDeviceIsSteady: (() -> Bool)?

    /// Whether a Scanner run is in flight. Read on the main thread through
    /// `scannerState`; this is the sessionQueue truth.
    var isScannerActive: Bool { scannerActive }

    /// Starts a Scanner shoot. `frameCap` auto-stops the run once that many
    /// poses have landed — 36 is the canonical turntable set (10° a step), and
    /// the target sheet offers it.
    ///
    /// The run opens by capturing the pose that is already framed, then waits
    /// for the scene to be disturbed and go still again for each one after it.
    ///
    /// `preferRAW` is the **format dial's** answer, not Scanner's own opinion.
    /// The mode used to take RAW unconditionally on the grounds that its frames
    /// are for solvers; that made the capture-format control silently
    /// inoperative under Scanner, which is worse — a shoot must capture what
    /// the format sheet says it will. RAW is still what the dial defaults to.
    ///
    /// `trigger` is the paper stock's: `Auto` keeps the motion machine (put it
    /// down, take your hand out, hear the click), a named stock switches to the
    /// document machine (a page, holding still, fires). They are different
    /// questions, not one with a filter on it — see `ScannerEngine`.
    func startScanner(
        frameCap: Int? = nil, preferRAW: Bool = true,
        aspect: PerspectiveAspect = .auto,
        framesPerPose: Int = 1
    ) {
        // **The stock picks the whole trigger, not a filter on one.** A named
        // stock is a declaration that these are pages, and a document shoot has
        // no disturb/settle cycle to wait for — the page is put down and stays
        // put. Auto keeps the turntable machine; a stock switches to "a page,
        // holding still". Derived here rather than passed in, so the trigger and
        // the shape gate below can never be told two different stories.
        let trigger: ScannerEngine.Trigger = aspect == .auto ? .motion : .rectangle
        sessionQueue.async {
            self.scannerPaperAspect = aspect
            guard !self.movieOutput.isRecording, self.intervalTimer == nil,
                  !self.isLiveBlendActive, !self.scannerActive else { return }
            // Same ordering rule as every other capture start: the other
            // preview taps detach inline before any capture work, because
            // adding or removing an output reconfigures the session.
            self.detachTestCardTapNow()
            self.detachFramingTapNow()

            // The scene's own light, read before anything in this method
            // disturbs it. The framing preview has been live for as long as the
            // operator took to aim, so AE is settled here; the `.photo` preset
            // switch below re-runs it, and a value read mid-convergence would
            // decide the torch on a transient.
            let sceneEV = self.sceneExposureValue()

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("scanner-\(Int(Date().timeIntervalSince1970))")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                LLog("scanner: could not create temp directory: \(error)")
                return
            }

            // The preset switch is not about RAW and happens either way: a
            // Scanner pose is a full-sensor still whatever it is encoded as,
            // and the viewfinder is already framing on 4:3 for it.
            self.scannerPreviousPreset = self.session.sessionPreset
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            self.session.commitConfiguration()
            // RAW when the format dial asked for it — and claimed honestly. If
            // this device, under this configuration, doesn't offer Bayer RAW,
            // the run shoots processed stills and says so in the log and the
            // HUD rather than writing something that isn't a DNG into a .dng.
            self.scannerWantedRAW = preferRAW
            self.scannerRawPixelFormat = preferRAW ? self.availableBayerRawFormats().first : nil
            if preferRAW, self.scannerRawPixelFormat == nil {
                LLog("scanner: no Bayer RAW under the photo configuration — capturing processed stills")
            } else if !preferRAW {
                LLog("scanner: capturing processed stills — the format dial is on JPEG")
            }
            self.publishFormat()
            if let dimensions = self.videoDevice?.activeFormat.supportedMaxPhotoDimensions.last {
                self.photoOutput.maxPhotoDimensions = dimensions
            }
            // One orientation for the run, set after the preset switch (which
            // rebuilds the photo connection) — the same rule the interval and
            // DNG paths follow.
            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoOrientationSupported {
                connection.videoOrientation = self.captureOrientation()
            }

            self.photoDirectory = directory
            self.photoURLs = []
            self.scannerFrames = []
            self.scannerFrameCap = frameCap
            self.scannerCapturePending = false
            self.scannerActive = true
            self.scannerWriter = FrameTimestampWriter(directory: directory)
            self.scannerPoseIndexByRequest = [:]
            self.scannerPoseDepth = max(1, framesPerPose)
            self.scannerPoseFramesRemaining = 0
            self.scannerPoseStack = nil
            self.scannerStacking = false

            // Light first, meter second, freeze third. A document run lights
            // the page (see `enableScannerTorch`), and the lamp changes the
            // scene it is about to be metered on — so when it comes on, the
            // exposure lock waits `scannerTorchSettle` for AE to find the newly
            // lit page instead of freezing a pair metered in the dark.
            //
            // The wait costs nothing that matters: this trigger's first pose
            // needs a page in view and a full hold window anyway, and the
            // capture path checks `scannerActive` again on the far side in case
            // the run was stopped inside the gap.
            let lit = trigger == .rectangle
                ? self.enableScannerTorch(sceneEV: sceneEV) : false
            if lit {
                self.sessionQueue.asyncAfter(deadline: .now() + Self.scannerTorchSettle) {
                    guard self.scannerActive else { return }
                    self.lockScannerCamera()
                    self.publishScannerState()
                }
            } else {
                // Exposure before the first frame, not after: everything the run
                // captures has to have been shot under one set of numbers.
                self.lockScannerCamera()
            }

            let engine = ScannerEngine(trigger: trigger)
            self.scannerEngine = engine
            self.attachScannerTapOnQueue()

            CaptureSessionLogger.shared.log("capture_start", [
                "kind": "scanner",
                "frameCap": frameCap ?? 0,
                "raw": self.scannerRawPixelFormat != nil,
                "rawRequested": preferRAW,
                "trigger": trigger.rawValue,
                "settleDelay": engine.settleDelay,
            ])
            LLog("scanner: start cap=\(frameCap.map(String.init) ?? "none")"
                 + " raw=\(self.scannerRawPixelFormat != nil) (requested \(preferRAW))"
                 + " trigger=\(trigger.rawValue) settle=\(engine.settleDelay)s")

            DispatchQueue.main.async {
                self.photoCount = 0
                self.captureRunStartedAt = Date()
                self.isIntervalRunning = true
            }
            // The opening pose is already framed — fire it rather than making
            // the operator disturb a scene they just finished arranging. Under
            // a named paper stock the engine declines this (there is no page in
            // view yet, and it says so) and takes the first one it sees.
            if engine.start(at: Date()) {
                self.fireScannerCapture()
            }
            self.publishScannerState()
        }
    }

    func stopScanner(source: CaptureSessionLogger.StopSource = .phone) {
        CaptureSessionLogger.shared.log("stop_requested", ["source": source.rawValue, "kind": "scanner"])
        cancelScheduledStop()
        sessionQueue.async {
            self.finishScannerOnQueue()
        }
    }

    /// Takes a pose **now**, on the operator's say-so, into the run already in
    /// progress.
    ///
    /// The Scanner's whole proposition is that the scene fires the shutter, and
    /// that proposition fails in ways no threshold fixes: a matte page on a
    /// matte desk the detector never finds, a stock whose ratio gate is refusing
    /// the quad it does find, a pose the operator wants held rather than
    /// re-placed. Without a manual shutter the answer to any of those is to stop
    /// the run and start another — which splits one set of pages across two
    /// projects, and a set is the unit a solver and an export both consume.
    ///
    /// So the frame lands in the *same* project, indexed and sidecar-stamped
    /// exactly like an automatic one, with whatever corners were in view at the
    /// moment it was asked for (possibly none — see `handleScannerPhoto`). The
    /// engine is then told, so the run's re-arm rules pick up from here rather
    /// than immediately taking the same page again.
    func captureScannerPoseNow() {
        sessionQueue.async {
            guard self.scannerActive, let engine = self.scannerEngine else { return }
            let now = Date()
            guard self.fireScannerCapture() else {
                // Refused, and the reason is worth a line: a pose already in
                // flight, or the pose target already met.
                LLog("scanner: manual capture ignored — capture pending or cap reached")
                return
            }
            engine.didCaptureManually(at: now)
            CaptureSessionLogger.shared.log("scanner_manual_capture", [
                "pose": self.scannerFrames.count + 1,
                "hadRectangle": self.scannerLatestQuad != nil,
            ])
            DispatchQueue.main.async { self.scannerManualCaptures += 1 }
            self.publishScannerState()
        }
    }

    /// Discards the most recent pose without ending the shoot — the control
    /// that matters more here than anywhere else in the app, because a
    /// mis-fire (a hand caught withdrawing, a pose the operator changed their
    /// mind about) is otherwise carried all the way into the solver.
    ///
    /// Returns the new frame count on the main queue. Deleting takes the files
    /// with it: the next capture reuses the index, so the sequence stays
    /// gap-free and `frame-00001…N` still means exactly what it says.
    func deleteLastScannerFrame(completion: ((Int) -> Void)? = nil) {
        sessionQueue.async {
            guard self.scannerActive, let frame = self.scannerFrames.popLast() else {
                let count = self.scannerFrames.count
                DispatchQueue.main.async { completion?(count) }
                return
            }
            for url in frame.urls {
                try? FileManager.default.removeItem(at: url)
            }
            self.photoURLs.removeAll { frame.urls.contains($0) }
            let count = self.scannerFrames.count
            LLog("scanner: deleted last pose — \(count) frames remain")
            CaptureSessionLogger.shared.log("scanner_delete_last", ["frameCount": count])
            DispatchQueue.main.async {
                self.photoCount = count
                completion?(count)
            }
            self.publishScannerState()
        }
    }

    /// sessionQueue-confined. Locks everything that could otherwise drift
    /// between poses.
    ///
    /// Exposure is frozen as a **custom** pair rather than `.locked` so the
    /// numbers are knowable and reportable — the HUD shows the shutter and ISO
    /// every frame of this set was taken at, which is the difference between a
    /// set an operator can trust and one they have to inspect afterwards.
    /// Focus is pinned at wherever it currently is, deliberately: the operator
    /// framed and focused before pressing the shutter, and a lens that hunts
    /// between poses is the single most damaging thing that can happen to a
    /// reconstruction.
    private func lockScannerCamera() {
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isExposureModeSupported(.custom) {
                device.setExposureModeCustom(
                    duration: device.exposureDuration, iso: device.iso, completionHandler: nil)
            } else if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
        } catch {
            LLog("scanner: lockForConfiguration failed — \(error.localizedDescription)")
        }
        // Focus goes through the run lock rather than a bare `focusMode =
        // .locked`, because that helper is the one that refuses to pin a lens
        // caught mid-hunt — and a lens pinned between two planes for a whole
        // 36-pose set is the worst outcome available here. `deviceChanged:
        // true` is not a lie about the input: it asks for the settle grace
        // window, which the `.photo` preset switch just above genuinely needs,
        // and re-aims at the user's tapped subject if they picked one.
        lockFocusForRun(deviceChanged: true)
    }

    /// How bright the document lamp burns. **Not full**, deliberately.
    ///
    /// A page is a flat white sheet a hand's length from the lens: at 1.0 the
    /// near edge blows out and the far one falls away, and the specular sheen
    /// off coated stock lands straight in the middle of the text. It is also the
    /// setting that heats the phone fastest, and a scan is minutes of holding
    /// still. 0.6 lifts a desk-lit page clear of its own shadow — which is the
    /// whole reason to light it, since the operator's own head and phone are
    /// between the page and the room — without either problem.
    private static let scannerTorchLevel: Float = 0.6

    /// How long AE is given to see the lamp before the run freezes the
    /// exposure.
    ///
    /// The order matters more than the number: light the page, let the meter
    /// find it, *then* lock. Locking first and lighting second freezes a pair
    /// metered in the dark and every page in the set comes out blown, which is
    /// the same class of mistake as locking focus mid-hunt.
    private static let scannerTorchSettle: TimeInterval = 0.45

    /// Below this scene EV (at ISO 100) a document run lights its own page.
    ///
    /// EV 5 is the line between "this room is lighting the page" and "the page
    /// is in my own shadow". For scale: bright overcast daylight indoors by a
    /// window is EV 9–11, an ordinary lit living room is EV 5–6, a desk under
    /// one lamp is EV 4–5, and a page held over a table away from the lamp is
    /// EV 2–3. The subject is the case that makes the threshold necessary: a
    /// phone held a hand's length above a sheet puts the operator's head and the
    /// phone itself between the page and the room, so the page is often two or
    /// three stops darker than the room reads.
    ///
    /// Above the line the torch is worse than nothing — it flattens the page,
    /// throws a specular sheen off coated stock, and heats the phone through a
    /// job that takes minutes.
    private static let scannerTorchEVThreshold: Double = 5

    /// The scene's brightness in APEX EV at ISO 100, from what the meter is
    /// currently doing: `EV = log2(N² / t) + log2(ISO / 100)`.
    ///
    /// Read while AE is still free — the run freezes exposure a moment later,
    /// and a locked pair describes the decision rather than the room. Returns
    /// nil when the device can't be metered (no aperture, a zero duration, an
    /// ISO of zero), which is the honest answer rather than a fabricated EV.
    private func sceneExposureValue() -> Double? {
        guard let device = videoDevice else { return nil }
        let aperture = Double(device.lensAperture)
        let seconds = device.exposureDuration.seconds
        let iso = Double(device.iso)
        guard aperture > 0, seconds > 0, iso > 0, seconds.isFinite else { return nil }
        return log2(aperture * aperture / seconds) + log2(iso / 100)
    }

    /// sessionQueue-confined. Lights the page for a document run **if the room
    /// isn't already doing it**.
    ///
    /// Document mode only — a named paper stock says the subject is a sheet at
    /// arm's length, which is exactly the subject a torch helps. Auto is the
    /// turntable/street case, where the operator has lit the scene themselves
    /// and a lamp firing on the object would wreck it; the torch is never
    /// touched there.
    ///
    /// **The decision is taken once, here, and never revisited.** Every frame in
    /// a set has to have been shot under one light: a lamp that came on for
    /// page 14 because a cloud passed would make that page a different
    /// photograph from its thirteen predecessors, and a set whose exposure and
    /// white balance are already locked for exactly that reason cannot then have
    /// its illumination change underneath it. So this is measured before the AE
    /// lock, decided, and left alone until the run ends.
    @discardableResult
    private func enableScannerTorch(sceneEV: Double?) -> Bool {
        guard let device = videoDevice,
              device.isTorchAvailable, device.isTorchModeSupported(.on) else {
            LLog("scanner: no torch on this device — shooting on ambient light")
            return false
        }
        // Metered by the caller before the preset switch; see
        // `sceneExposureValue`. Falls back to a reading taken now if the early
        // one couldn't be taken at all.
        let ev = sceneEV ?? sceneExposureValue()
        let wantsTorch = (ev ?? 0) < Self.scannerTorchEVThreshold
        LLog(String(format: "scanner: torch decision ev=%@ → %@",
                    ev.map { String(format: "%.2f", $0) } ?? "unknown",
                    wantsTorch ? "on" : "off"))
        // An unmeasurable scene lights the page: a document run that cannot read
        // its own light is likelier to be in the dark under a phone than in
        // daylight, and an over-lit page beats an unreadable one.
        guard wantsTorch else { return false }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            try device.setTorchModeOn(
                level: min(Self.scannerTorchLevel, AVCaptureDevice.maxAvailableTorchLevel))
            scannerTorchOn = true
            LLog("scanner: torch on at \(Self.scannerTorchLevel)")
            return true
        } catch {
            // Thermals refuse the torch before the OS will ever dim it for you.
            // Falling back to `.on` would light it at FULL, which is the one
            // level this deliberately isn't — so the run simply goes unlit and
            // says so.
            LLog("scanner: torch refused — \(error.localizedDescription)")
            return false
        }
    }

    /// sessionQueue-confined. Puts the lamp out. Safe to call when it was never
    /// lit, and called from every path that ends a run — including the session
    /// teardown, because a torch left burning after the screen closes is the
    /// most conspicuous bug this feature could have.
    private func disableScannerTorch() {
        guard scannerTorchOn, let device = videoDevice else { return }
        scannerTorchOn = false
        guard device.isTorchAvailable else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.torchMode != .off { device.torchMode = .off }
            LLog("scanner: torch off")
        } catch {
            LLog("scanner: could not put the torch out — \(error.localizedDescription)")
        }
    }

    /// sessionQueue-confined. Adds the differencing tap, the same way the
    /// test-card and Watch framing taps are added.
    private func attachScannerTapOnQueue() {
        let analyzer = scannerAnalyzer ?? ScannerMotionAnalyzer()
        scannerAnalyzer = analyzer
        let detector = scannerRectangleDetector ?? RectangleDetector()
        scannerRectangleDetector = detector
        // The pose the run is being shot at, taken once here: the whole run is
        // one orientation (see `startScanner`), and reading it per frame from
        // the tap's queue would be reading main-thread state off it. The same
        // write publishes it, because the overlay has to know which way up the
        // corners it is about to draw were measured.
        let runOrientation = captureOrientation()
        detector.setCaptureOrientation(runOrientation)
        // The stock's shape test, armed with this format's own field of view.
        // Read here rather than stored at start: a run's format is settled by
        // the time the tap goes on, and the number has to describe the frames
        // the detector will actually see.
        detector.setShapeGate(
            aspect: scannerPaperAspect,
            horizontalFieldOfView: videoDevice?.activeFormat.videoFieldOfView ?? 0)
        let quadOrientation = detector.quadOrientation
        DispatchQueue.main.async { self.scannerRectangleOrientation = quadOrientation }
        analyzer.rectangleDetector = detector
        analyzer.reset()
        analyzer.onSample = { [weak self] sample in
            guard let self else { return }
            self.sessionQueue.async {
                self.ingestScannerSample(sample)
            }
        }
        let output: AVCaptureVideoDataOutput
        if let existing = scannerOutput {
            output = existing
        } else {
            output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
            output.alwaysDiscardsLateVideoFrames = true
            scannerOutput = output
        }
        if !session.outputs.contains(output) {
            session.beginConfiguration()
            if session.canAddOutput(output) {
                session.addOutput(output)
            } else {
                LLog("scanner: session refused the motion tap")
            }
            session.commitConfiguration()
        }
        output.setSampleBufferDelegate(analyzer, queue: analyzer.queue)
    }

    /// sessionQueue-confined, synchronous detach — same reasoning as
    /// `detachTestCardTapNow`.
    private func detachScannerTapNow() {
        guard let output = scannerOutput else { return }
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.outputs.contains(output) {
            session.beginConfiguration()
            session.removeOutput(output)
            session.commitConfiguration()
            LLog("scanner: motion tap detached")
        }
        scannerAnalyzer?.onSample = nil
        scannerAnalyzer?.rectangleDetector = nil
        scannerRectangleDetector = nil
        publishScannerRectangle(nil, at: Date(), force: true)
    }

    /// sessionQueue-confined. One measurement in; a capture out, or not.
    private func ingestScannerSample(_ sample: ScannerMotionAnalyzer.Sample) {
        let magnitude = sample.magnitude
        let quad = sample.quad
        let time = sample.time
        guard scannerActive, let engine = scannerEngine else { return }
        scannerRefusingOnShape = sample.refusedOnShape
        publishScannerRectangle(quad, at: time)
        #if DEBUG
        // The measurement `defaultMotionThreshold`'s TODO is waiting on. The
        // threshold has to sit above a scene's noise floor (sensor grain, AE
        // micro-adjustments) and below a hand crossing the frame, and neither
        // bound is knowable without printing what a real camera actually
        // reports. Throttled to ~1 Hz so a 30 fps tap doesn't drown the log.
        if time.timeIntervalSince(scannerLastMagnitudeLogAt) >= 1 {
            scannerLastMagnitudeLogAt = time
            // The rectangle half is logged in the same line and to the same
            // end: the corner threshold is as unmeasured today as the motion
            // one was, and this is what a field run has to read to move it.
            let rectangle = quad.map {
                String(format: " rect=%.2f cornerThreshold=%.4f documentThreshold=%.4f",
                       $0.confidence, engine.cornerStabilityThreshold,
                       engine.documentStabilityThreshold)
            } ?? " rect=none"
            let hold = engine.settleProgress(at: time)
                .map { String(format: " hold=%.0f%%", $0 * 100) } ?? ""
            // A refused move is the machine catching an ordering bug in itself,
            // and the log is where a field run reports one.
            let rejected = engine.lastRejectedTransition.map { " REJECTED=\($0)" } ?? ""
            LLog(String(format: "scanner: trigger=%@ mag=%.5f threshold=%.5f state=%@",
                        engine.trigger.rawValue, magnitude, engine.motionThreshold,
                        engine.state.rawValue) + rectangle + hold + rejected)
        }
        #endif
        let previousPhase = engine.state
        let shouldFire = engine.observe(magnitude: magnitude, quad: quad, at: time)
        // A fresh disturbance clears the steady veto. Without this the HUD
        // would keep reading "Hold the phone still" for the rest of the run
        // after one skipped pose, long after the phone had settled — the flag
        // is about the pose that was refused, not about the device.
        if engine.state == .disturbed, previousPhase != .disturbed {
            scannerWaitingForSteady = false
        }
        if shouldFire {
            // The scene says yes. The device still has a veto — see
            // `scannerDeviceIsSteady`. A vetoed pose isn't lost either way: the
            // motion machine's next settle window comes round on its own, and
            // the rectangle machine is told nothing, so it keeps its window
            // satisfied and takes the same page as soon as the phone is still.
            let steady = scannerDeviceIsSteady?() ?? true
            if steady {
                if fireScannerCapture() {
                    engine.didCapture(at: time)
                }
            } else {
                scannerWaitingForSteady = true
                LLog("scanner: ready to fire but the device is not steady — pose held")
            }
        }
        if shouldFire || engine.state != previousPhase {
            publishScannerState()
        } else if engine.settleProgress(at: time) != nil {
            // A window is running, and the HUD draws its progress — so republish
            // at the tap's own rate rather than only on a state change.
            publishScannerState()
        }
    }

    /// The prioritization to actually ask for: what we want, or the output's
    /// ceiling if that is lower.
    ///
    /// The ceiling is raised to `.quality` once, in `configureIfNeeded` — but it
    /// is read back here rather than assumed, because the property answers for
    /// the output *as currently configured* and a preset or format change can
    /// lower what it will accept. Asking for more than it allows is not a
    /// refusal but an `NSInvalidArgumentException`, and a raised exception
    /// halfway through a 36-pose set costs the whole set. One `min` makes the
    /// crash unreachable no matter what the session does to itself.
    private func allowedQualityPrioritization(
        _ requested: AVCapturePhotoOutput.QualityPrioritization
    ) -> AVCapturePhotoOutput.QualityPrioritization {
        let ceiling = photoOutput.maxPhotoQualityPrioritization
        guard requested.rawValue > ceiling.rawValue else { return requested }
        LLog("photo: quality prioritization capped to \(ceiling.rawValue)"
             + " (asked for \(requested.rawValue))")
        return ceiling
    }

    /// sessionQueue-confined. Opens a pose and asks the photo output for its
    /// first frame. Returns whether a request actually went out — the engine
    /// only commits a page as banked when one did.
    ///
    /// A pose is one frame at BLEND Off and `scannerPoseDepth` frames otherwise,
    /// requested one at a time from `finishScannerCapture` and averaged into a
    /// single image by `ScannerPoseStack`. Either way it is **one pose**: one
    /// index, one sidecar entry, one file on disk per format, so nothing
    /// downstream — the count, the target ring, the export, a solver — can tell
    /// a stacked pose from a plain one except by looking less noisy.
    @discardableResult
    private func fireScannerCapture() -> Bool {
        guard scannerActive, !scannerCapturePending else { return false }
        if let cap = scannerFrameCap, scannerFrames.count >= cap { return false }
        scannerCapturePending = true
        scannerWaitingForSteady = false
        scannerPoseIndex = scannerFrames.count
        scannerPoseQuad = scannerLatestQuad
        scannerPoseFramesRemaining = scannerPoseDepth
        scannerPoseStack = scannerPoseDepth > 1
            ? ScannerPoseStack(
                depth: scannerPoseDepth,
                scratch: (photoDirectory ?? FileManager.default.temporaryDirectory)
                    .appendingPathComponent(String(format: "pose-%05d-parts", scannerPoseIndex + 1)))
            : nil
        return requestScannerFrame()
    }

    /// sessionQueue-confined. Asks for one frame of the pose in flight.
    @discardableResult
    private func requestScannerFrame() -> Bool {
        guard scannerActive, scannerPoseFramesRemaining > 0 else { return false }
        scannerPoseFramesRemaining -= 1

        let settings: AVCapturePhotoSettings
        if let rawFormat = scannerRawPixelFormat {
            // RAW plus the processed sibling in one request: the DNG is what a
            // solver wants and the HEIC is what a human can look at without a
            // raw converter.
            let processed: [String: Any]? = photoOutput.availablePhotoCodecTypes.contains(.hevc)
                ? [AVVideoCodecKey: AVVideoCodecType.hevc]
                : nil
            settings = AVCapturePhotoSettings(
                rawPixelFormatType: rawFormat, processedFormat: processed)
        } else {
            settings = AVCapturePhotoSettings()
        }
        // The processed path only. `photoQualityPrioritization` is illegal on a
        // RAW request — `NSInvalidArgumentException: Unsupported when capturing
        // RAW`, which took an iPad to find out, because nothing in the
        // simulator captures RAW and the first real Scanner start on device
        // died on it (2026-08-16).
        //
        // **This branch is a minefield of raised exceptions, and it went two
        // days without ever being executed**: until the format dial started
        // being honoured (2026-08-17) it was reachable only on a device with no
        // Bayer RAW at all, so on the phone it was dead code that read as
        // working code. The first JPEG Scanner shoot hit the second mine below
        // within a second of starting.
        //
        // What is deliberately NOT here: `settings.maxPhotoDimensions`. The
        // value to hand it would be `selectedPhotoDimensions`, which describes
        // the *video* format — but a Scanner run has switched the session to
        // `.photo`, so that size is one the active format need not list (a
        // third exception), and asking for it would shoot pages at a fraction
        // of the sensor. The output-level value `startScanner` sets from the
        // active format's own largest supported size governs instead, exactly
        // as it always has for RAW.
        //
        // What is: the quality preference, which is worth stating here — there
        // is no window to starve, since the next frame waits on a human moving
        // an object, and every frame is a measurement. It goes through the
        // output's ceiling because asking above it is the mine that went off:
        // `photoQualityPrioritization must not be higher than
        // self.maxPhotoQualityPrioritization`. `configureIfNeeded` lifts that
        // ceiling to `.quality`; the clamp keeps the ask legal even if a later
        // reconfiguration lowers it.
        if scannerRawPixelFormat == nil {
            settings.photoQualityPrioritization = allowedQualityPrioritization(.quality)
        }
        scannerPoseIndexByRequest[settings.uniqueID] = scannerPoseIndex
        // The geometry this pose is being shot on, frozen when the pose opened.
        // It rides to the sidecar in `handleScannerPhoto` and no further:
        // nothing here touches the frame itself.
        if let quad = scannerPoseQuad {
            scannerQuadByRequest[settings.uniqueID] = quad
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
        return true
    }

    /// sessionQueue-confined. Hands the overlay its quad, but only when it has
    /// really moved.
    ///
    /// The detector runs at 10 Hz and its corners jitter by a fraction of a
    /// percent on a stationary page. Publishing every one of those would
    /// invalidate the capture screen's body ten times a second for a change
    /// nobody can see — and this is the screen with forty-odd observers on it.
    /// So a quad goes out when it appears, when it disappears, or when a corner
    /// has moved a visible amount; and never more often than 10 Hz.
    ///
    /// The threshold is deliberately far below the settle test's: this decides
    /// whether a *line moves on screen*, not whether the page is still.
    private func publishScannerRectangle(_ quad: NormalizedQuad?, at time: Date, force: Bool = false) {
        let previous = scannerPublishedQuad
        scannerLatestQuad = quad
        if !force {
            switch (previous, quad) {
            case (nil, nil):
                return
            case (let old?, let new?):
                guard old.maxCornerDistance(to: new) > 0.002,
                      time.timeIntervalSince(scannerQuadPublishedAt) >= 0.1 else { return }
            default:
                break  // appeared or disappeared — always worth drawing.
            }
        }
        scannerPublishedQuad = quad
        scannerQuadPublishedAt = time
        DispatchQueue.main.async { self.scannerRectangle = quad }
    }

    /// sessionQueue-confined. Called from the capture delegate as each part of
    /// a pose lands.
    fileprivate func handleScannerPhoto(_ photo: AVCapturePhoto) {
        guard scannerActive, let directory = photoDirectory else { return }
        guard let index = scannerPoseIndexByRequest[photo.resolvedSettings.uniqueID] else { return }

        // A stacked pose's parts never reach the disk under their own name:
        // they are folded into the running average and the pose is written once,
        // when its last frame has landed (see `finishScannerPose`).
        if let stack = scannerPoseStack {
            let isFirstFrame = scannerPoseFramesRemaining == scannerPoseDepth - 1
            if photo.isRawPhoto {
                // The Bayer buffer is what gets averaged; the whole DNG is
                // pulled only for the pose's first frame, whose tags describe
                // the stack (one locked exposure, one sensor). Asking for tens
                // of megabytes of file data per frame would be pure waste.
                let buffer = photo.pixelBuffer
                let reference = isFirstFrame ? photo.fileDataRepresentation() : nil
                scannerStackQueue.async { stack.addRaw(buffer, dngData: reference) }
            } else if let data = photo.fileDataRepresentation() {
                let ext = scannerRawPixelFormat != nil ? "heic" : "jpg"
                scannerStackQueue.async { stack.addProcessed(data, fileExtension: ext) }
            }
            return
        }

        guard let data = photo.fileDataRepresentation() else { return }

        // Sequential and deterministic, assigned at request time — never read
        // back off the filesystem, whose ordering is not a promise anyone made.
        let isRaw = photo.isRawPhoto
        let name = String(format: "frame-%05d.%@", index + 1,
                          isRaw ? "dng" : (scannerRawPixelFormat != nil ? "heic" : "jpg"))
        let url = directory.appendingPathComponent(name)
        let written = isRaw
            ? ((try? data.write(to: url)) != nil)
            : writeCapturedPhoto(data, to: url)
        guard written else { return }

        if isRaw || scannerRawPixelFormat == nil {
            // The frame itself: the DNG, or — on the honest fallback — the
            // processed still standing in for it.
            var frame = ScannerFrame(raw: url, processed: nil)
            if index < scannerFrames.count {
                frame.processed = scannerFrames[index].processed
                scannerFrames[index] = frame
            } else {
                scannerFrames.append(frame)
            }
            // Only the primary file is registered as a project frame, so every
            // count in the app (HUD, target ring, stack estimate) means poses.
            photoURLs.append(url)
            scannerWriter?.append(FrameTimestamps.Entry(
                frame: index,
                captureTime: Date(),
                shutter: videoDevice?.exposureDuration.seconds ?? 0,
                iso: Double(videoDevice?.iso ?? 0),
                ev: 0,
                // Present only when there was a rectangle at the moment the
                // shutter was asked for — the key's absence is how a later
                // correction knows this frame has no geometry to rectify from.
                rectangle: scannerQuadByRequest[photo.resolvedSettings.uniqueID]))
        } else if index < scannerFrames.count {
            scannerFrames[index].processed = url
        }
    }

    /// sessionQueue-confined. One capture request has finished, RAW and
    /// processed sibling included.
    ///
    /// At BLEND Off that is the whole pose. Deeper than that, it is one frame of
    /// it: the next is asked for here, so a pose's frames go out one at a time
    /// and only one full-sensor capture is ever in flight.
    fileprivate func finishScannerCapture(uniqueID: Int64) {
        scannerPoseIndexByRequest.removeValue(forKey: uniqueID)
        scannerQuadByRequest.removeValue(forKey: uniqueID)
        if scannerPoseFramesRemaining > 0 {
            requestScannerFrame()
            return
        }
        guard scannerPoseStack != nil else {
            releaseScannerPose()
            return
        }
        finishScannerPose()
    }

    /// sessionQueue-confined. The pose's frames are all in; average them and
    /// write the one image the pose is.
    ///
    /// The gate stays closed across the whole of this — `scannerCapturePending`
    /// is only released on the far side — so a scene that re-settles while a
    /// stack is still being written cannot open a second pose on top of it.
    private func finishScannerPose() {
        guard let stack = scannerPoseStack, let directory = photoDirectory else {
            releaseScannerPose()
            return
        }
        scannerPoseStack = nil
        scannerStacking = true
        publishScannerState()
        let index = scannerPoseIndex
        let quad = scannerPoseQuad
        let wantsRAW = scannerRawPixelFormat != nil
        let shutter = videoDevice?.exposureDuration.seconds ?? 0
        let iso = Double(videoDevice?.iso ?? 0)
        scannerStackQueue.async {
            let result = stack.finalize(directory: directory, index: index, wantsRAW: wantsRAW)
            self.sessionQueue.async {
                self.scannerStacking = false
                guard self.scannerActive else { return }
                // Same bookkeeping an unstacked pose does, in the same order:
                // the primary file is the project frame, the sibling hangs off
                // it, and the sidecar entry carries the corners the shutter was
                // pressed on.
                if let primary = result.raw ?? result.processed {
                    var frame = ScannerFrame(raw: primary, processed: nil)
                    if result.raw != nil { frame.processed = result.processed }
                    if index < self.scannerFrames.count {
                        self.scannerFrames[index] = frame
                    } else {
                        self.scannerFrames.append(frame)
                    }
                    self.photoURLs.append(primary)
                    self.scannerWriter?.append(FrameTimestamps.Entry(
                        frame: index,
                        captureTime: Date(),
                        shutter: shutter,
                        iso: iso,
                        ev: 0,
                        rectangle: quad))
                }
                self.releaseScannerPose()
            }
        }
    }

    /// sessionQueue-confined. The pose is done: open the gate, republish, and
    /// stop the run if it has met its target.
    private func releaseScannerPose() {
        scannerCapturePending = false
        scannerPoseFramesRemaining = 0
        scannerPoseStack = nil
        let count = scannerFrames.count
        DispatchQueue.main.async { self.photoCount = count }
        publishScannerState()
        if let cap = scannerFrameCap, count >= cap {
            LLog("scanner: reached the \(cap)-pose target")
            finishScannerOnQueue()
        }
    }

    /// sessionQueue-confined.
    private func publishScannerState() {
        guard scannerActive, let engine = scannerEngine else {
            DispatchQueue.main.async { self.scannerState = nil }
            return
        }
        let state = ScannerState(
            phase: engine.state.rawValue,
            frames: scannerFrames.count,
            shutterSeconds: videoDevice?.exposureDuration.seconds ?? 0,
            iso: videoDevice?.iso ?? 0,
            isCapturingRAW: scannerRawPixelFormat != nil,
            wantedRAW: scannerWantedRAW,
            settleProgress: engine.settleProgress(at: Date()),
            waitingForDeviceSteady: scannerWaitingForSteady,
            hasRectangle: engine.isTrackingRectangle,
            waitingForRectangle: engine.isWaitingForRectangle,
            trigger: engine.trigger.rawValue,
            refusingOnShape: scannerRefusingOnShape,
            framesPerPose: scannerPoseDepth,
            isStacking: scannerStacking)
        DispatchQueue.main.async {
            if self.scannerState != state { self.scannerState = state }
        }
    }

    /// sessionQueue-confined. Tears the run down exactly once — the stop
    /// button, the pose cap and the screen teardown all arrive here.
    private func finishScannerOnQueue() {
        guard scannerActive else { return }
        // The lamp goes out first, before any of the slower teardown: it is the
        // one part of a run the room can see, so it should stop the moment the
        // run does rather than a beat later.
        disableScannerTorch()
        scannerActive = false
        scannerCapturePending = false
        detachScannerTapNow()
        scannerEngine?.stop()
        scannerEngine = nil
        scannerWriter?.close()
        scannerWriter = nil
        scannerPoseIndexByRequest = [:]
        scannerQuadByRequest = [:]
        scannerLatestQuad = nil
        scannerWaitingForSteady = false
        scannerRefusingOnShape = false
        // A pose caught mid-stack is abandoned rather than finished: its frames
        // exist only in an accumulator and a scratch directory that goes with
        // it, and a set gains nothing from one more page written after the
        // operator has stopped the run.
        scannerPoseFramesRemaining = 0
        scannerPoseStack = nil
        scannerStacking = false
        let urls = photoURLs
        // TODO (Phase 2, export): offer the perspective correction here, or
        // wherever the finished set is presented. Everything it needs is
        // already on disk and complete —
        //
        //     PerspectiveCorrector.correctSequence(in: directory, aspect: hint)
        //
        // reads the corners out of `frames.timestamps` and writes
        // `frame-NNNNN-corrected.heic` beside each pose that had a rectangle in
        // view. It is not called from here on purpose: the aspect hint is the
        // operator's (`ScannerAspectSetting`, on the capture screen), correcting
        // a 36-pose set is seconds of GPU work that belongs behind an explicit
        // "Correct perspective" action rather than in a capture teardown, and
        // the originals stay untouched either way.
        LLog("scanner: end after \(urls.count) poses")
        CaptureSessionLogger.shared.log("capture_end", ["kind": "scanner", "frameCount": urls.count])
        scannerFrameCap = nil
        scannerFrames = []

        // Hand the camera back. The run owned the exposure; the framing screen
        // shouldn't inherit a frozen one.
        if let device = videoDevice, !exposureLocked, (try? device.lockForConfiguration()) != nil {
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        }
        if let preset = scannerPreviousPreset {
            scannerPreviousPreset = nil
            session.beginConfiguration()
            session.sessionPreset = preset
            session.commitConfiguration()
            applyCaptureFormat(resolution: selectedResolution, fps: selectedFrameRate)
            publishFormat()
        }
        if scannerArmedPhotoAspect {
            scannerArmedPhotoAspect = false
            disarmPhotoAspectPreview()
        }
        releaseRunFocusLock()
        DispatchQueue.main.async {
            self.isIntervalRunning = false
            self.scannerState = nil
            if !urls.isEmpty {
                self.onFinishPhotos?(urls)
            }
        }
    }

    #else

    /// macOS has no manual exposure, no per-format ISO envelope and no RAW
    /// photo capture, so there is no ramp to run and no Scanner to run it
    /// beside. Neither is offered in the MODE dial there; these exist so the
    /// shared teardown paths still compile.
    private func endHolyGrailIfActive() {}
    var isScannerActive: Bool { false }
    var scannerDeviceIsSteady: (() -> Bool)? {
        get { nil }
        set { _ = newValue }
    }
    func startScanner(
        frameCap: Int? = nil, preferRAW: Bool = true,
        aspect: PerspectiveAspect = .auto,
        framesPerPose: Int = 1
    ) {}
    func stopScanner(source: CaptureSessionLogger.StopSource = .phone) {}
    func captureScannerPoseNow() {}
    func deleteLastScannerFrame(completion: ((Int) -> Void)? = nil) {
        DispatchQueue.main.async { completion?(0) }
    }

    #endif

    // MARK: - Shutter ceiling for blend runs

    // These two live OUTSIDE the ramp section above on purpose: the live-blend
    // start/stop paths that call them are shared with macOS, so a copy that
    // only exists on iOS breaks the Mac build. Their bodies are iOS-only —
    // `activeVideoMaxFrameDuration` is an AVCaptureDevice API the Mac doesn't
    // offer — so on macOS they are simply no-ops.

    /// What `activeVideoMaxFrameDuration` was before a blend run relaxed it.
    private var pinnedVideoMaxFrameDuration: CMTime?

    /// Let the shutter reach the exposure the ramp is asking for.
    ///
    /// Interval blending taps the VIDEO output, and a video frame's exposure
    /// can never exceed its own frame duration. `applyCaptureFormat` pins
    /// `min == max`, so the ceiling is 1/fps — 40 ms at 25 fps. Measured on a
    /// 16 Pro (2026-08-22): the ramp commanded 1.0 s at ISO 97, the sensor
    /// delivered 0.0399 s at ISO 2534, and AE made up all 4.7 stops with gain
    /// so nothing looked wrong. The DNG path was never affected because it
    /// captures through the PHOTO output, which the frame duration does not
    /// bound — which is why the same shoot reached 1.0 s there.
    ///
    /// Only the MAXIMUM moves. The minimum stays where the format put it, so
    /// bright scenes still run at the configured rate and only a scene that
    /// actually needs a long exposure slows the delivered rate down — exactly
    /// what the iPads were already doing when they shot 1 fps in Psycho.
    private func relaxVideoFrameDurationForBlend(interval: Double) {
        #if os(iOS)
        guard let device = videoDevice else { return }
        let ceiling = min(device.activeFormat.maxExposureDuration.seconds,
                          max(0.05, interval))
        let current = device.activeVideoMaxFrameDuration
        guard current.isValid, ceiling > current.seconds * 1.01 else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            pinnedVideoMaxFrameDuration = current
            device.activeVideoMaxFrameDuration =
                CMTimeMakeWithSeconds(ceiling, preferredTimescale: 1_000_000)
            LLog(String(format:
                "liveblend: shutter ceiling raised %.3fs → %.2fs (video frame duration)",
                current.seconds, ceiling))
        } catch {
            LLog("liveblend: could not raise the shutter ceiling — \(error.localizedDescription)")
        }
        #endif
    }

    /// Puts the frame rate back where the format pinned it. A relaxed ceiling
    /// left behind would let a later VIDEO recording drop frames in low light.
    private func restoreVideoFrameDuration() {
        #if os(iOS)
        guard let device = videoDevice, let pinned = pinnedVideoMaxFrameDuration
        else { return }
        pinnedVideoMaxFrameDuration = nil
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeVideoMaxFrameDuration = pinned
        } catch {
            LLog("liveblend: could not restore the frame duration — \(error.localizedDescription)")
        }
        #endif
    }

    #if !os(iOS)
    /// macOS has no ramp (see the Holy Grail section's note), so the shared
    /// live-blend start path's "is this a ramped run?" question has one
    /// answer here. Declared rather than `#if`-ed around every call site so
    /// the shared path stays a single piece of code.
    private var holyGrailRequestedForRun: Bool { false }
    #endif

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
    /// `autoInterval` means the EVERY dial is on Auto: `interval` is only the
    /// spacing the run *opens* at, and the ramp widens it as the light dies
    /// (see `HolyGrailAutoInterval`). It is meaningless without `holyGrail`.
    func startLiveBlend(every interval: Double, depth: BlendDepth, preferDNG: Bool = false, options: LiveBlendCaptureOptions = LiveBlendCaptureOptions(), holyGrail: Bool = false, autoInterval: Bool = false) {
        sessionQueue.async {
            guard !self.movieOutput.isRecording, self.intervalTimer == nil, !self.isLiveBlendActive else { return }
            CaptureSessionLogger.shared.log("capture_start", [
                "kind": holyGrail ? "holyGrailBlend" : "liveBlend",
                "intervalSeconds": interval,
                "autoInterval": autoInterval,
                "framesPerBlend": depth.fixedFrames ?? 0,
                "preferDNG": preferDNG,
            ])
            #if os(iOS)
            self.holyGrailRequestedForRun = holyGrail
            self.holyGrailAutoRequestedForRun = holyGrail && autoInterval
            #endif

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

    /// What the camera's own AE has settled on right now, read off the live
    /// device rather than off a captured frame.
    ///
    /// Two callers, one reading. Auto needs it because a window's depth has to
    /// be chosen *before* that window's first capture exists. The video-tap
    /// pipeline needs it because its frames come off the preview stream and
    /// carry no EXIF of their own — the device is the only place its exposure
    /// record can come from.
    ///
    /// On macOS this always returns nil: `lensAperture`, `exposureDuration` and
    /// `iso` are unavailable there — a Mac camera exposes no exposure readings
    /// at all — so Auto falls back to its middle band rather than pretending to
    /// have metered anything.
    private func sceneExposureProvider() -> () -> DNGAuthor.DNGExposure? {
        #if os(iOS)
        return { [weak self] in
            guard let device = self?.videoDevice else { return nil }
            let iso = Double(device.iso)
            let shutter = device.exposureDuration.seconds
            let aperture = Double(device.lensAperture)
            // A session still coming up reports zeros; that is an absence of a
            // reading, not a reading of zero.
            guard iso > 0, shutter > 0, aperture > 0 else { return nil }
            return DNGAuthor.DNGExposure(
                iso: iso, exposureDuration: shutter, aperture: aperture,
                capturedAt: Date())
        }
        #else
        return { nil }
        #endif
    }

    /// Logs thermal movement during a run. This used to RE-PROBE — ten
    /// serialized RAW captures fired into the same photo output the run was
    /// using, with no coordination with its in-flight brackets. The 2026-08-22
    /// investigation could not clear that probe of colliding with the 16 Pro's
    /// bracket refusal at its serious transition, and the probe's one product
    /// (a fresher fps) is now redundant: both resolve sites derive the live
    /// ceiling from the stored fps per window, and the processing-aware
    /// ceiling in the controller adapts to real slowdown continuously. So a
    /// thermal change is now just recorded, never acted on with captures.
    private func startCapabilityReprofiling(rawPixelFormat: OSType, interval: Double) {
        #if os(iOS)
        stopCapabilityReprofiling()
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let state = ProcessInfo.processInfo.thermalState
            guard self.capabilityProfileHolder.isStale(for: state) else { return }
            LLog("capability: thermal state moved mid-run — profile kept, live ceilings adapt")
        }
        #endif
    }

    private func stopCapabilityReprofiling() {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        thermalObserver = nil
    }

    #if os(iOS)
    /// One capability measurement, stored in the holder and handed on. The
    /// completion fires whatever the outcome — a probe that measures nothing
    /// leaves the holder empty, and Auto then runs on the EV table alone, which
    /// is what every other depth has always done.
    private func runCapabilityProbe(
        rawPixelFormat: OSType,
        interval: Double,
        completion: @escaping (DeviceCapabilityProfile?) -> Void
    ) {
        let profiler = DeviceCapabilityProfiler(
            photoOutput: photoOutput,
            captureExecutor: { [weak self] block in self?.sessionQueue.async(execute: block) })
        capabilityProfiler = profiler
        profiler.profile(rawPixelFormat: rawPixelFormat, intervalSeconds: interval) { [weak self] profile in
            guard let self else { return }
            if let profile {
                self.capabilityProfileHolder.set(profile)
            }
            completion(profile)
        }
    }
    #endif

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
            // A ramped run commands exposures this path cannot deliver while
            // the frame rate is pinned. Only ramped runs get the ceiling
            // raised: a plain run has no command to honour, and its AE is
            // already doing the right thing inside the configured rate.
            if self.holyGrailRequestedForRun {
                self.relaxVideoFrameDurationForBlend(interval: interval)
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
                capabilityProfile: { [weak self] in self?.capabilityProfileHolder.profile },
                sceneExposure: sceneExposureProvider(),
                // Only a ramped run has a commanded exposure to diverge from.
                rampExposure: self.holyGrailRequestedForRun
                    ? { [weak self] in self?.holyGrailAppliedExposure.target ?? nil }
                    : nil,
                sessionID: UUID().uuidString,
                deviceModel: LiveBlendController.deviceModelIdentifier(),
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
            #if os(iOS)
            // Holy Grail: one exposure per blend window, chosen by the ramp.
            if self.holyGrailRequestedForRun {
                controller.onWindowOpened = { [weak self] index, luma in
                    guard let self else { return }
                    self.sessionQueue.async {
                        self.rampHolyGrailBlendWindow(
                            index: index, measurement: luma.map { .luma($0) })
                    }
                }
                self.beginHolyGrailForBlendRun(
                    interval: interval, directory: directory,
                    autoInterval: self.holyGrailAutoRequestedForRun)
            }
            #endif
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
                    #if os(iOS)
                    self.endHolyGrailIfActive()
                    #endif
                    self.releaseRunFocusLock()
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
            // A blend run is a timelapse like any other: focus stops at the
            // shutter press and stays stopped. No input swap here, so there is
            // nothing to settle first.
            self.lockFocusForRun(deviceChanged: false)
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
        let deviceBeforeSwap = videoDevice
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
            capabilityProfile: { [weak self] in self?.capabilityProfileHolder.profile },
            sceneExposure: sceneExposureProvider(),
            blendStrategy: BlendStrategyID.selected,
            // Only a ramped run supplies a target: plain runs keep AE-driven
            // brackets, and the guard/manual-bracket machinery stays inert.
            rampExposure: holyGrailRequestedForRun
                ? { [weak self] in self?.rampExposureForBracket() }
                : nil,
            sessionID: UUID().uuidString,
            deviceModel: LiveBlendController.deviceModelIdentifier(),
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
        if holyGrailRequestedForRun {
            controller.onWindowOpened = { [weak self] index, brightness in
                guard let self else { return }
                self.sessionQueue.async {
                    self.rampHolyGrailBlendWindow(
                        index: index, measurement: brightness.map { .apexBrightness($0) })
                }
            }
            beginHolyGrailForBlendRun(
                interval: interval, directory: directory,
                autoInterval: holyGrailAutoRequestedForRun)
            // Every frame of this run is Bayer RAW by construction.
            holyGrailRawPixelFormat = rawFormat
            publishHolyGrailState()
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
                self.stopCapabilityReprofiling()
                self.capabilityProfiler = nil
                self.capabilityProfileHolder.set(nil)
                self.endHolyGrailIfActive()
                self.restoreAfterDNGRun()
                self.restoreVideoFrameDuration()
                self.releaseRunFocusLock()
            }
            if let result {
                self.onFinishLiveBlend?(result)
            }
        }
        liveBlendRawController = controller
        // Last thing before the first RAW frame is asked for, and after both
        // the constituent swap above and the photo-preset switch — either would
        // have handed focus back to auto under the pin.
        lockFocusForRun(deviceChanged: videoDevice !== deviceBeforeSwap)
        if depth == .auto {
            // Auto is the one depth whose first window needs a number before it
            // opens, so the capability probe runs ahead of the shoot rather than
            // alongside it. It is bounded (ten frames, hard timeout), it only
            // costs Auto runs, and the alternative — starting blind and
            // correcting from window two — bakes a wrong depth into the first
            // frame of every shoot.
            let started = ProcessInfo.processInfo.systemUptime
            runCapabilityProbe(rawPixelFormat: rawFormat, interval: interval) { [weak self] _ in
                guard let self else { return }
                self.sessionQueue.async {
                    guard self.liveBlendRawController === controller else { return }
                    LLog(String(format: "liveblend-dng: auto profiling took %.2fs",
                                ProcessInfo.processInfo.systemUptime - started))
                    self.startCapabilityReprofiling(rawPixelFormat: rawFormat, interval: interval)
                    controller.start()
                }
            }
        } else {
            controller.start()
        }
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
    /// Video "Capture Flat" when Apple Log did NOT engage: grade the recorded
    /// movie on save instead. Asked of the device's actual colour space, not
    /// of capability — the old gate (`!supportsAppleLog`, device-wide) assumed
    /// a Log-capable phone always flattens at the sensor, but Log is a
    /// per-format fact: on a format without it the capture stayed sRGB *and*
    /// this stayed false, so Capture Flat silently did nothing at all
    /// (verified against a 2026-08-14 shoot: bt709 tags, unlifted blacks).
    private var shouldSoftwareFlattenVideo: Bool {
        guard UserDefaults.standard.bool(forKey: FlatCapture.storageKey) else { return false }
        return !(videoDevice.map(activeColorSpaceIsAppleLog) ?? false)
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
            // First segment of the run: stamp what the run is actually
            // shooting — Capture Flat as requested, Apple Log as engaged
            // (read off the device, after the lens pin and format work are
            // done deciding). Deliberately not at sequence creation, which
            // runs before both.
            if self.activeSequence != nil, self.activeSequence?.appleLog == nil,
               let device = self.videoDevice {
                self.activeSequence?.captureFlat =
                    UserDefaults.standard.bool(forKey: FlatCapture.storageKey)
                self.activeSequence?.appleLog = self.activeColorSpaceIsAppleLog(device)
            }
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
                let nextResolution = self.pendingRampResolution ?? self.selectedResolution
                self.pendingRampFrameRate = nil
                self.pendingRampResolution = nil
                self.startNextSegment(resolution: nextResolution, frameRate: nextFrameRate)
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
        // Everything below is sessionQueue-confined state (including the Holy
        // Grail flags), and these callbacks arrive on AVFoundation's own
        // queue — so hop first and decide there.
        sessionQueue.async {
            guard error == nil else { return }
            #if os(iOS)
            // A Scanner run writes RAW and its processed sibling under a pose
            // index assigned at request time, so it takes its own path rather
            // than this one's "next slot in photoURLs" naming.
            if self.isScannerActive {
                self.handleScannerPhoto(photo)
                return
            }
            #endif
            guard let data = photo.fileDataRepresentation() else { return }
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

    #if os(iOS)
    /// The end of a whole capture request, RAW and processed sibling included.
    /// Scanner releases its one-pose-at-a-time gate here rather than in
    /// `didFinishProcessingPhoto`, which fires once per part — releasing on the
    /// first part would let a re-settle fire a second shot of the same pose
    /// while the sibling was still being written.
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        sessionQueue.async {
            guard self.isScannerActive else { return }
            if let error {
                LLog("scanner: capture failed — \(error.localizedDescription)")
            }
            self.finishScannerCapture(uniqueID: resolvedSettings.uniqueID)
        }
    }
    #endif
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
    private static let rampResolutionWidthKey = "letslapse.capture.rampResolutionWidth"
    private static let rampResolutionHeightKey = "letslapse.capture.rampResolutionHeight"
    /// The ProRes flag of the remembered resolution. Stored separately from
    /// width/height because it was added later, and because `CaptureResolution`
    /// treats it as part of the resolution's identity — the capability matrix
    /// keys on it, so losing it across a launch silently changed which formats
    /// the burst menu offered.
    private static let resolutionProResKey = "letslapse.capture.resolutionProRes"
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
        return CameraController.CaptureResolution(
            width: Int32(width),
            height: Int32(height),
            // Absent for anyone upgrading, which reads as false — the same
            // answer the flag-less version always gave.
            isProRes: UserDefaults.standard.bool(forKey: resolutionProResKey))
    }

    /// The remembered burst resolution. Nil when the store predates the
    /// per-segment burst resolution, which the caller reads as "follow the
    /// base" — the behaviour every shoot had before it existed.
    static var rampResolution: CameraController.CaptureResolution? {
        guard let width = UserDefaults.standard.object(forKey: rampResolutionWidthKey) as? Int,
              let height = UserDefaults.standard.object(forKey: rampResolutionHeightKey) as? Int,
              width > 0, height > 0
        else { return nil }
        return CameraController.CaptureResolution(
            width: Int32(width),
            height: Int32(height),
            isProRes: UserDefaults.standard.bool(forKey: resolutionProResKey))
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
        rampResolution: CameraController.CaptureResolution? = nil,
        stabilization: Bool? = nil
    ) {
        guard isEnabled else { return }
        let defaults = UserDefaults.standard
        if let resolution {
            defaults.set(Int(resolution.width), forKey: resolutionWidthKey)
            defaults.set(Int(resolution.height), forKey: resolutionHeightKey)
            defaults.set(resolution.isProRes, forKey: resolutionProResKey)
        }
        if let frameRate { defaults.set(frameRate, forKey: frameRateKey) }
        if let rampFrameRate { defaults.set(rampFrameRate, forKey: rampFrameRateKey) }
        if let rampResolution {
            defaults.set(Int(rampResolution.width), forKey: rampResolutionWidthKey)
            defaults.set(Int(rampResolution.height), forKey: rampResolutionHeightKey)
        }
        if let stabilization { defaults.set(stabilization, forKey: stabilizationKey) }
    }

    /// Drop the snapshot when the user turns the setting off, so re-enabling
    /// starts from the app defaults rather than a stale setup.
    static func clear() {
        let defaults = UserDefaults.standard
        for key in [
            modeKey, lensKey, stopFactorKey, resolutionWidthKey, resolutionHeightKey,
            resolutionProResKey, frameRateKey, rampFrameRateKey,
            rampResolutionWidthKey, rampResolutionHeightKey, stabilizationKey,
            intervalSecondsKey, liveBlendIntervalSecondsKey, liveBlendFramesPerBlendKey,
            blendDepthKey, photoBlendDepthKey, photoBulbModeKey,
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}
