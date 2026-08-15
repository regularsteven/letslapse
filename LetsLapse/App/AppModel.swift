import SwiftUI
import AVFoundation
import CoreGraphics
import CoreLocation
import ImageIO
import LetsLapseKit
import VideoToolbox
import UniformTypeIdentifiers
#if os(iOS)
import Photos
#endif

@MainActor
final class AppModel: ObservableObject {
    private enum DefaultsKey {
        static let constantWindow = "letslapse.constantWindow"
        static let outputFPS = "letslapse.outputFPS"
        static let linearLight = "letslapse.linearLight"
        static let trimVideoEnds = "letslapse.trimVideoEnds"
        static let trimHeadTailSeconds = "letslapse.trimHeadTailSeconds"
        static let maxCPUWorkers = "letslapse.maxCPUWorkers"
        static let maxBlendBatches = "letslapse.maxBlendBatches"
        static let defaultSpeed = "letslapse.defaultSpeed"
        static let scratchFrameFormat = "letslapse.scratchFrameFormat"
        static let keepExtractedFrames = "letslapse.keepExtractedFrames"
        /// Key string keeps the pre-merge "liveBlend" name existing installs
        /// persisted under.
        static let intervalOutputFormat = "letslapse.liveBlendOutputFormat"
        static let liveBlendResponsiveCapture = "letslapse.liveBlendResponsiveCapture"
        static let liveBlendBurstCapture = "letslapse.liveBlendBurstCapture"
        static let liveBlendBracketedRAW = "letslapse.liveBlendBracketedRAW"
        static let burstRampDefault = "letslapse.burstRampDefault"
        static let burstRampRememberLast = "letslapse.burstRampRememberLast"
    }

    /// `mode` marker for a one-tap Photo-mode capture — the burst that was
    /// auto-blended into a single image with no Adjust step. Detects photo
    /// captures across launches (persisted in the manifest via `mode`).
    static let photoCaptureMode = "Photo"

    enum CaptureKind: String, Codable {
        case video
        case photos

        var label: String {
            switch self {
            case .video: return "Video"
            case .photos: return "Interval photos"
            }
        }
    }

    enum BlendKind: String, Codable {
        case video
        case image
    }

    enum MediaKind: Hashable {
        case video
        case image
    }

    /// One codec variant of a single source clip. The original capture file is
    /// itself an encoding (usually ProRes); conversions are siblings inside the
    /// project's `source/` folder. `fileName` is relative to the capture folder.
    struct ClipEncoding: Codable, Equatable, Identifiable {
        var codec: String
        var fileName: String

        var id: String { fileName }

        var isProRes: Bool { codec == OutputCodec.prores.rawValue }

        var codecLabel: String {
            switch codec {
            case OutputCodec.prores.rawValue: return "ProRes"
            case OutputCodec.h264.rawValue: return "H.264"
            case OutputCodec.hevc.rawValue: return "HEVC"
            default: return "Video"
            }
        }
    }

    struct CaptureProject: Identifiable, Codable, Equatable {
        var id: UUID
        var kind: CaptureKind
        var createdAt: Date
        var originalName: String
        var mode: String
        var sourceFileNames: [String]
        var sourceFPS: Double?
        var name: String?
        var sourceDurationSeconds: Double?
        var sourceWidth: Int?
        var sourceHeight: Int?
        /// Extra codec variants per source clip, keyed by the clip's original
        /// relative file name. Absent (nil) until a clip is first converted.
        var clipEncodings: [String: [ClipEncoding]]?
        /// The non-destructive colour grade applied to a Photo-mode capture,
        /// stored as a `PhotoPreset` raw name. Optional so projects saved
        /// before grading existed still decode; nil resolves to the default
        /// ("Natural" — grading is on by default).
        var selectedPreset: String?
        /// The manual grade layered on top of `selectedPreset` — the photo
        /// viewer's sliders and white-balance picker. Optional for the same
        /// reason as `selectedPreset`: projects saved before the sliders
        /// existed have no value, and nil resolves to `.neutral` (the preset
        /// on its own). Read it through `AppModel.photoAdjustments(for:)`.
        var adjustments: PhotoAdjustments?
        /// How long this project's burst clips ease into and out of slow
        /// motion, in seconds. Optional in both directions: nil means "follow
        /// the app default" (resolved at render time), 0 means "this project
        /// explicitly wants hard cuts". Projects saved before ramps existed
        /// decode as nil and behave exactly as they always did.
        /// Read it through `AppModel.effectiveBurstRamp(for:)`.
        var burstRampDuration: Double?
        /// Subject tags the user accepted from an on-device scene analysis. Optional so projects
        /// saved before the feature existed still decode; nil and empty mean the same thing.
        var sceneTags: [String]?
        /// The free-form nouns the same analysis named for what is actually in frame
        /// ("waterfall", "mossy rocks"). Not shown as chips — they are the model's own wording
        /// rather than a closed list — but they are the most specific thing search can match, so
        /// they are kept alongside the tags rather than thrown away with the proposal sheet.
        var sceneElements: [String]?
        /// True when these tags came from the silent Vision pass at capture time rather than from
        /// a run the user asked for and confirmed. It is the difference between "the app guessed
        /// this" and "you agreed to this", and it is the only reason the card shows a marker at
        /// all. Cleared the moment a proposal is applied.
        var sceneTaggedAutomatically: Bool?
        /// Probed asset duration per segment file (keyed by the clip's original
        /// relative-name last component). The sidecar's wall-clock spans run
        /// ~0.2–0.6s past what the camera actually wrote, and a warp schedule
        /// built on those phantom frames starves at end-of-file — always at the
        /// slowest tail of a seam ease. This map is the truth the warp axis is
        /// built on; nil (pre-probe) falls back to the sidecar spans.
        var sourceSegmentSeconds: [String: Double]?
        /// Probed DELIVERED frame rate per segment file (same keying). The
        /// density twin of the span problem above: a burst the sidecar calls
        /// 100 fps can really deliver half that (a light-starved sensor drops
        /// frames the sidecar never hears about). A schedule built on the
        /// nominal rate budgets phantom frames, the blend truncates when the
        /// decoder runs dry, and every pass keyed to the compiled frame map —
        /// the reframe bake above all — mis-times from the truncation onward.
        /// nil (pre-probe) falls back to the sidecar's nominal rate.
        var sourceSegmentFPS: [String: Double]?
        /// Probed pixel size per segment file, as "WxH" (same keying). The
        /// spatial twin of the two maps above: a ramp shoot's burst segments
        /// can record at a different resolution from its base ones, so
        /// `sourceWidth`/`sourceHeight` — which latch on the FIRST segment, and
        /// therefore describe the base — no longer describe the whole shoot.
        /// Anything that needs to know what a particular file holds reads this;
        /// anything asking "what shape is this project" still reads the pair,
        /// and is still right, because the reframe keys are authored in the
        /// base's pixel space.
        var sourceSegmentSize: [String: String]?
        /// The `id` this project had in the archive it was imported from — the
        /// only thread back to where it came from, since import mints a fresh
        /// `id` (folder names key on it, so reusing the original would collide
        /// with the source device's own library). Nil for anything captured
        /// here, and for projects imported before this was recorded. Read it
        /// through `AppModel.existingImport(of:)`, which is what catches a
        /// second double-click on an archive already in the library.
        var importedFromID: UUID?

        var summary: String {
            switch kind {
            case .video:
                if let sourceFPS {
                    return "\(mode) · \(String(format: "%.0f", sourceFPS)) fps"
                }
                return mode
            case .photos:
                return "\(sourceFileNames.count) source frames"
            }
        }

        var sourceMediaCount: Int {
            sourceFileNames.filter { !$0.hasSuffix(".json") }.count
        }

        /// A one-tap Photo-mode capture: a single photo. With Blend Off the
        /// captured frame is the photo itself; with blend on, the burst was
        /// auto-blended into one image at capture time. Either way the
        /// project reads as ONE asset — no versions, no photo counts, no
        /// source-clip list, no re-processing (burst frames stay on disk as
        /// stacking material, not user-facing media).
        var isPhotoCapture: Bool {
            kind == .photos && mode == AppModel.photoCaptureMode
        }

        /// A project title people can recognize: the custom name, an imported
        /// file's name, or a dated fallback.
        var displayTitle: String {
            if let name, !name.isEmpty { return name }
            if kind == .video, mode == "Import" {
                let base = (originalName as NSString).deletingPathExtension
                if !base.isEmpty { return base }
            }
            let stamp = createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            if isPhotoCapture { return "Photo \(stamp)" }
            return kind == .photos ? "Stack \(stamp)" : "Capture \(stamp)"
        }

        /// "Video · 1080p · 24 fps" / "Interval · 214 photos"
        var formatLine: String {
            switch kind {
            case .video:
                var parts = ["Video"]
                if let sourceWidth, let sourceHeight {
                    parts.append(Self.resolutionLabel(width: sourceWidth, height: sourceHeight))
                }
                if let sourceFPS {
                    parts.append("\(Int(sourceFPS.rounded())) fps")
                }
                return parts.joined(separator: " · ")
            case .photos:
                // A Photo-mode capture is one photo — never a frame count.
                return isPhotoCapture ? "Photo" : "Interval · \(sourceMediaCount) photos"
            }
        }

        static func resolutionLabel(width: Int, height: Int) -> String {
            switch (max(width, height), min(width, height)) {
            case (3840, 2160): return "4K"
            case (1920, 1080): return "1080p"
            case (1280, 720): return "720p"
            default: return "\(width)×\(height)"
            }
        }
    }

    struct BlendProject: Identifiable, Codable, Equatable {
        var id: UUID
        var captureID: UUID
        var kind: BlendKind
        var createdAt: Date
        var outputFileName: String
        var summary: String
        var compressionRatio: Int?
        var outputFPS: Int?
        var linearLight: Bool
        var useRamp: Bool
        var rampStart: Int
        var rampEnd: Int
        var curve: String
        var trimHeadTailSeconds: Double?
        var width: Int?
        var height: Int?
        var inputFrames: Int?
        var outputFrames: Int?
        /// The source codec this version was blended from, when the user picked
        /// one explicitly (nil = automatic / best-available). Its `OutputCodec`
        /// raw value, e.g. "h264".
        var sourceCodec: String?
        /// The clip's default crop per canvas ratio (raw value → pan offset
        /// 0…1), used wherever a collection shows this clip on a mismatched
        /// canvas and hasn't set its own crop. Absent until a crop is first
        /// saved; absent ratios resolve to centred (0.5).
        var defaultCrops: [String: Double]?
        /// The effective window of each stretch, in render order, for clips
        /// made with the short-lived per-stretch ruler. Kept for decode; new
        /// clips record `warp` instead.
        var stretchWindows: [Int]?
        /// The warp timeline this clip was rendered from — stretches, speeds
        /// in ×-real-time, and the seams' ramps. Absent for clips from before
        /// the warp editor.
        var warp: WarpTimeline?
        /// The punch-in reframe track this clip was rendered with — spatial
        /// keys only; speed stays in `warp`. Absent for clips without one.
        var reframe: ReframeTrack?
        /// The canvas ratio (raw value) the render actually used. The reframe
        /// keys' geometry only means anything against this shape, so re-editing
        /// restores it; absent for clips from before it was recorded.
        var canvasRatio: String?
        /// Where that canvas crop sat along the source's free axis (0…1,
        /// 0.5 = centred) — the guided builder's repositioned crop. Absent for
        /// clips rendered before the crop could move, which were all centred.
        var canvasOffset: Double?

        /// "ProRes" / "H.264" / "HEVC" for display, when recorded.
        var sourceCodecLabel: String? {
            switch sourceCodec {
            case "prores": return "ProRes"
            case "h264": return "H.264"
            case "hevc": return "HEVC"
            default: return nil
            }
        }

        var parameterSummary: String {
            switch kind {
            case .video:
                let timing = outputFPS.map { "\($0) fps" } ?? "video"
                let trim = trimHeadTailSeconds.map { $0 > 0 ? " · trim \(String(format: "%.1f", $0))s" : "" } ?? ""
                if useRamp {
                    return "\(rampStart)→\(rampEnd):1 · \(timing)\(trim)"
                }
                if let compressionRatio {
                    return "\(compressionRatio):1 · \(timing)\(trim)"
                }
                return "\(timing)\(trim)"
            case .image:
                return linearLight ? "Linear-light stack" : "Stack"
            }
        }

        /// "100×" / "1→30× ramp" / "¼×–100× warp" / "Long exposure"
        var speedLabel: String {
            switch kind {
            case .video:
                if useRamp { return "\(rampStart)→\(rampEnd)× ramp" }
                if let warp,
                   let slowest = warp.speeds.min(), let fastest = warp.speeds.max(),
                   fastest - slowest > 0.001 {
                    return "\(WarpTimeline.speedLabel(slowest))–\(WarpTimeline.speedLabel(fastest)) warp"
                }
                if let stretchWindows,
                   let slowest = stretchWindows.min(), let fastest = stretchWindows.max(),
                   slowest != fastest {
                    return "\(slowest)×–\(fastest)× mix"
                }
                if let compressionRatio { return "\(compressionRatio)×" }
                return "Video"
            case .image:
                return "Long exposure"
            }
        }

        var outputSeconds: Double? {
            guard kind == .video, let outputFrames, let outputFPS, outputFPS > 0 else { return nil }
            return Double(outputFrames) / Double(outputFPS)
        }

        /// The thumbnail badge: "100× · 2.2s" / "Long exposure"
        var badgeLabel: String {
            if kind == .image { return "Long exposure" }
            if let outputSeconds {
                return "\(speedLabel) · \(SpeedMath.clipLengthCompact(outputSeconds))"
            }
            return speedLabel
        }
    }

    private struct LibraryManifest: Codable {
        var captures: [CaptureProject] = []
        var blends: [BlendProject] = []
        /// Optional so manifests written before Collections existed decode.
        var collections: [LapseCollection]?
        /// Bumped by one-time library migrations; nil in manifests written
        /// before any existed. 1 = the Natural stamp (see `loadLibrary`).
        var gradingSchemaVersion: Int?
    }

    private struct ProcessingOutput {
        var kind: BlendKind
        var url: URL
        var image: CGImage?
        var summary: String
        var inputFrames: Int?
        var outputFrames: Int?
        var width: Int?
        var height: Int?
        /// Set when the geometry passes (reframe / canvas crop) already ran
        /// **per segment**, ahead of the stitch, so their tail counterparts
        /// stand down. Only a mixed-resolution ramp shoot does this — see
        /// `SegmentNormalization`. The grade is not included: it still bakes
        /// once over the finished clip, because a pass that no-ops on a segment
        /// that needs no geometry would otherwise leave that segment ungraded.
        var geometryBaked = false
    }

    /// How a mixed-resolution ramp shoot's segments are brought to one size.
    ///
    /// A ramp shoot can now hold two resolutions — base segments at the shot's
    /// resolution, burst segments higher so a punch-in has pixels to crop into.
    /// `stitchVideos` lays pieces into a single composition track, which has
    /// exactly one size, so they must agree before they reach it.
    ///
    /// **The order is the whole point.** The crop is taken from each segment at
    /// its own native resolution and Lanczos-scaled straight to `renderSize`,
    /// so a 2× punch on a 4K burst keeps 1920 px and lands 1:1 at 1080p. Doing
    /// it the other way round — shrink to the base, then crop — throws the
    /// burst's extra pixels away before the crop can spend them, which would
    /// make burst resolution pointless.
    ///
    /// `renderSize` is derived from the **base** resolution, so the output is
    /// the size it always was; the extra pixels are consumed by the crop, not
    /// by the file.
    private struct SegmentNormalization {
        var renderSize: CGSize
        /// The shoot's output shape. Defaults to the clip's own, in which case
        /// the canvas pass finds nothing to crop and becomes a pure scale.
        var canvas: CanvasRatio
        var canvasOffset: Double
        /// nil = no punch-in; segments are only scaled (and canvas-cropped) to
        /// `renderSize`.
        var reframe: Reframe?

        struct Reframe {
            var track: ReframeTrack
            var aspect: Double
            /// The capture's display-oriented size — the space the keys were
            /// authored in, which stays the *base* resolution for every
            /// segment. `ReframeVideoCropper` derives its own per-clip scale
            /// from it, so a 4K burst resolves to 2.0 and a base segment to 1.0.
            var sourceSize: CGSize
            /// One entry per segment, in segment order — the compiled warp's
            /// `frameSourceTimes` kept per region instead of flattened.
            var frameTimesBySegment: [[Double]]
            var outputFPS: Int
        }
    }

    private final class ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession

        init(_ session: AVAssetExportSession) {
            self.session = session
        }
    }

    struct LiveCaptureSource: Equatable {
        var sequence: LiveCaptureSequence
        var segmentURLs: [URL]
        var metadataURL: URL
        /// Maps each segment's original file name (as recorded in the sequence
        /// metadata) to the file actually used, after per-clip encoding choices.
        var resolvedByOriginalName: [String: URL] = [:]

        var primaryVideoURL: URL? {
            segmentURLs.first
        }
    }

    enum Source: Equatable {
        case video(URL)
        case liveSequence(LiveCaptureSource)
        case photos([URL])

        var summary: String {
            switch self {
            case .video(let url):
                return "Video · \(url.lastPathComponent)"
            case .liveSequence(let source):
                return "Video · \(source.sequence.summary)"
            case .photos(let urls):
                return "\(urls.count) photos"
            }
        }

        var isVideo: Bool {
            if case .video = self { return true }
            if case .liveSequence = self { return true }
            return false
        }
    }

    enum Stage {
        case home
        case configure
        case processing
        case done
    }

    /// Named stages for the processing screen — people see a checklist, not a log.
    enum ProcessingStage: Int, CaseIterable, Comparable {
        case preparing
        case blending
        case encoding
        case saving

        var title: String {
            switch self {
            case .preparing: return "Preparing footage"
            case .blending: return "Blending frames"
            case .encoding: return "Encoding video"
            case .saving: return "Saving to project"
            }
        }

        static func < (lhs: ProcessingStage, rhs: ProcessingStage) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Where the pipeline actually is — set explicitly by the blend code,
    /// never inferred from the progress number, so a multi-clip run can't
    /// walk the checklist in circles as each clip's engine sweeps 0→1.
    enum ProcessingPhase: Equatable {
        case preparing
        case blending(clip: Int, of: Int)
        case combining(clips: Int)
        case grading
        case saving
    }

    var processingStage: ProcessingStage {
        switch processingPhase {
        case .preparing: return .preparing
        case .blending: return .blending
        case .combining, .grading: return .encoding
        case .saving: return .saving
        }
    }

    enum LibraryDeletionError: LocalizedError {
        case activeCapture
        case unsafeBlendPath

        var errorDescription: String? {
            switch self {
            case .activeCapture:
                return "This capture is currently being processed. Cancel the job before deleting it."
            case .unsafeBlendPath:
                return "The blend file is outside its capture folder and could not be deleted safely."
            }
        }
    }

    @Published var stage: Stage = .home
    @Published var source: Source?
    @Published var errorMessage: String?
    @Published private(set) var captures: [CaptureProject] = []
    @Published private(set) var blends: [BlendProject] = []
    @Published private(set) var collections: [LapseCollection] = []
    /// Probed durations for blends whose manifests predate output stats,
    /// keyed by blend id — filled lazily by `blendDuration(for:)` callers.
    @Published private(set) var probedBlendDurations: [UUID: Double] = [:]
    /// Probed display-oriented pixel sizes per blend. The manifest's stored
    /// width/height are the encoded buffer's, which an imported clip's
    /// rotation transform can flip — the collection preview and crop math
    /// need the picture as displayed.
    @Published private(set) var probedBlendSizes: [UUID: CGSize] = [:]
    @Published var currentCaptureID: UUID?
    @Published var resultBlendID: UUID?

    /// Interval tail-frame review. When `tailFramesToExclude` > 0 the final N
    /// interval frames read as shaky at capture time — most often the user
    /// grabbing the phone to end the shoot. Surfaced as a quiet, recoverable
    /// banner on the Adjust screen; the frames stay on disk either way.
    @Published var tailFramesToExclude: Int = 0
    @Published var totalIntervalFrames: Int = 0
    /// Frame indices to exclude from the blend. Set before `startProcessing`;
    /// filtered out of the `.photos` URL list. Never deletes the originals.
    @Published var excludedFrameIndices: Set<Int> = []

    // Blend options
    /// Which codec each source clip contributes to the blend. `nil` = automatic
    /// (best surviving encoding per clip). Only meaningful once a clip has more
    /// than one encoding; drives the "Blend from" picker in Adjust.
    @Published var blendSourceCodec: OutputCodec?
    /// The canvas the new blended clip renders to — the Adjust screen's ratio
    /// chips. `nil` = as shot (no crop). A mismatched canvas crops the
    /// finished clip at source pixel scale on its way into the project.
    @Published var blendCanvasRatio: CanvasRatio?
    /// Where the canvas crop sits along the source's free axis, 0…1 (0.5 =
    /// centred) — the guided builder's frame pane drags this. Same meaning as
    /// a collection's per-clip crop, so `CollectionMath.cropBox` reads it
    /// unchanged. Capture-specific, and recorded on the blend so re-editing
    /// re-opens the framing that rendered.
    @Published var blendCanvasOffset: Double = 0.5
    @Published var useRamp = false
    @Published var constantWindow = UserDefaults.standard.object(forKey: DefaultsKey.constantWindow) as? Int
        ?? UserDefaults.standard.object(forKey: DefaultsKey.defaultSpeed) as? Int
        ?? 100 {
        didSet { UserDefaults.standard.set(constantWindow, forKey: DefaultsKey.constantWindow) }
    }
    @Published var defaultSpeed = UserDefaults.standard.object(forKey: DefaultsKey.defaultSpeed) as? Int ?? 100 {
        didSet { UserDefaults.standard.set(defaultSpeed, forKey: DefaultsKey.defaultSpeed) }
    }

    /// The current capture's warp timeline — stretches in source time, each
    /// with a speed in ×-real-time, seams owning the ramps between them. nil
    /// until the Adjust screen seeds it (from recorded structure, or one
    /// whole-clip stretch for a continuous capture). Capture-specific, so
    /// opening another project clears it.
    @Published var warp: WarpTimeline?

    /// The capture's punch-in reframe track — spatial keys beside the warp,
    /// never seeded: nil or empty means the full frame. Capture-specific, so
    /// opening another project clears it.
    @Published var reframe: ReframeTrack?

    /// The Punch-in reframe button opens the same Adjust flow with the
    /// reframe lane already expanded; the plain button leaves it collapsed.
    @Published var reframeLaneFocused = false

    /// The experimental guided builder replaces the Adjust screen for this
    /// pass through `.configure`: same stage, same underlying warp + reframe
    /// data, a survey-style authoring surface. Capture-specific, so opening
    /// another project clears it.
    @Published var guidedBuilderFocused = false

    /// Export resolution as a longest-edge cap (1080, 720); nil = full source
    /// scale. The tail passes scale ONCE, directly to this size — a punched
    /// crop Lanczos-resamples from its kept pixels straight to the target, so
    /// a 2× punch on a 4K source is pixel-sharp at 1080. Guided-builder
    /// surface only for now; capture-specific, so opening another project
    /// clears it.
    @Published var exportShortEdge: Int?

    /// Blend depth for interval-stills output, kept separate from the video
    /// `constantWindow` (whose default is a fast video speed). 1 = a crisp
    /// timelapse, one frame per photo; higher values blend more stills into
    /// each frame for motion blur; at or above the photo count every still
    /// folds into a single long-exposure image.
    @Published var photoBlendDepth = 1
    @Published var rampStart = 1
    @Published var rampEnd = 30
    @Published var curve: BlendCurve = .easeInOut
    @Published var outputFPS = UserDefaults.standard.object(forKey: DefaultsKey.outputFPS) as? Int ?? 25 {
        didSet { UserDefaults.standard.set(outputFPS, forKey: DefaultsKey.outputFPS) }
    }
    @Published var linearLight = UserDefaults.standard.object(forKey: DefaultsKey.linearLight) as? Bool ?? true {
        didSet { UserDefaults.standard.set(linearLight, forKey: DefaultsKey.linearLight) }
    }
    @Published var trimVideoEnds = UserDefaults.standard.object(forKey: DefaultsKey.trimVideoEnds) as? Bool ?? false {
        didSet { UserDefaults.standard.set(trimVideoEnds, forKey: DefaultsKey.trimVideoEnds) }
    }
    @Published var trimHeadTailSeconds = UserDefaults.standard.object(forKey: DefaultsKey.trimHeadTailSeconds) as? Double ?? 1 {
        didSet { UserDefaults.standard.set(trimHeadTailSeconds, forKey: DefaultsKey.trimHeadTailSeconds) }
    }

    /// The burst ramp every video project starts on, in seconds. nil = off,
    /// which is the shipping default: a project that says nothing about ramps
    /// renders exactly as it did before ramps existed.
    @Published var burstRampDefault: Double? =
        UserDefaults.standard.object(forKey: DefaultsKey.burstRampDefault) as? Double {
        didSet {
            if let burstRampDefault, burstRampDefault > 0 {
                UserDefaults.standard.set(burstRampDefault, forKey: DefaultsKey.burstRampDefault)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.burstRampDefault)
            }
        }
    }
    /// When on, changing a project's ramp also becomes the new default, so the
    /// next shoot starts where the last one ended.
    @Published var burstRampRememberLast =
        UserDefaults.standard.bool(forKey: DefaultsKey.burstRampRememberLast) {
        didSet { UserDefaults.standard.set(burstRampRememberLast, forKey: DefaultsKey.burstRampRememberLast) }
    }

    // Recording options
    @Published var rememberRecordingSettings = RecordingSettingsStore.isEnabled {
        didSet {
            UserDefaults.standard.set(rememberRecordingSettings, forKey: RecordingSettingsStore.isEnabledKey)
            if !rememberRecordingSettings {
                RecordingSettingsStore.clear()
            }
        }
    }
    /// Off by default: shoots are silent, no mic permission is requested, and
    /// audio playing on the device keeps running during capture. The camera
    /// picks changes up the next time the capture screen starts.
    @Published var recordAudio = RecordingSettingsStore.isAudioEnabled {
        didSet { RecordingSettingsStore.save(isAudioEnabled: recordAudio) }
    }
    /// Extra capture rate offered alongside the built-in ones whenever the
    /// active camera supports it. nil = off.
    @Published var customCaptureFrameRate = RecordingSettingsStore.customFrameRate {
        didSet { RecordingSettingsStore.save(customFrameRate: customCaptureFrameRate) }
    }

    // Performance options
    @Published var maxCPUWorkers = UserDefaults.standard.object(forKey: DefaultsKey.maxCPUWorkers) as? Int ?? max(1, ProcessInfo.processInfo.activeProcessorCount - 2) {
        didSet { UserDefaults.standard.set(maxCPUWorkers, forKey: DefaultsKey.maxCPUWorkers) }
    }
    @Published var maxBlendBatches = UserDefaults.standard.object(forKey: DefaultsKey.maxBlendBatches) as? Int ?? 2 {
        didSet { UserDefaults.standard.set(maxBlendBatches, forKey: DefaultsKey.maxBlendBatches) }
    }
    /// Format for the macOS job runner's scratch frames. PNG is lossless
    /// 16-bit — the pipeline's full depth — at tens of MB per 4K frame;
    /// HEIC/JPEG are lossy 8-bit at a small fraction of the size, which can
    /// band skies and smooth gradients.
    @Published var scratchFrameFormat: ImageFormat = ImageFormat(
        rawValue: UserDefaults.standard.string(forKey: DefaultsKey.scratchFrameFormat) ?? ""
    ) ?? .png {
        didSet { UserDefaults.standard.set(scratchFrameFormat.rawValue, forKey: DefaultsKey.scratchFrameFormat) }
    }
    /// Interval output preference: JPEG everywhere, or DNG where the
    /// capture source provides Bayer RAW (iPhone/iPad cameras). Unsupported
    /// sources fall back to JPEG with a visible notice before recording.
    /// Set from the capture format sheet; applies whether or not frames are
    /// blended.
    @Published var intervalOutputFormat: IntervalOutputFormat = IntervalOutputFormat(
        rawValue: UserDefaults.standard.string(forKey: DefaultsKey.intervalOutputFormat) ?? ""
    ) ?? .jpeg {
        didSet { UserDefaults.standard.set(intervalOutputFormat.rawValue, forKey: DefaultsKey.intervalOutputFormat) }
    }
    /// DNG capture experiments — A/B toggles for chasing tighter frame
    /// density (denser samples read as blur; sparse ones read as ghosts).
    /// Every run's log header records the combination in force. Defaults
    /// follow the iPhone 16 Pro benchmark (2026-07-22): bracketed RAW was
    /// the fastest AND most reliable (~40fps intra-bracket, 30/30 frames);
    /// responsive capture wedged the photo output after ~15 rapid RAWs, so
    /// it is opt-in only.
    @Published var liveBlendResponsiveCapture = (UserDefaults.standard.object(forKey: DefaultsKey.liveBlendResponsiveCapture) as? Bool) ?? false {
        didSet { UserDefaults.standard.set(liveBlendResponsiveCapture, forKey: DefaultsKey.liveBlendResponsiveCapture) }
    }
    @Published var liveBlendBurstCapture = (UserDefaults.standard.object(forKey: DefaultsKey.liveBlendBurstCapture) as? Bool) ?? true {
        didSet { UserDefaults.standard.set(liveBlendBurstCapture, forKey: DefaultsKey.liveBlendBurstCapture) }
    }
    @Published var liveBlendBracketedRAW = (UserDefaults.standard.object(forKey: DefaultsKey.liveBlendBracketedRAW) as? Bool) ?? true {
        didSet { UserDefaults.standard.set(liveBlendBracketedRAW, forKey: DefaultsKey.liveBlendBracketedRAW) }
    }
    /// When on, decoded frames stay in the job folder for inspection and for
    /// instant re-blends at other speeds. When off (default) each blend
    /// window's scratch is deleted as soon as its blended frame lands, so
    /// scratch stays bounded no matter how long the clip is.
    @Published var keepExtractedFrames = UserDefaults.standard.bool(forKey: DefaultsKey.keepExtractedFrames) {
        didSet { UserDefaults.standard.set(keepExtractedFrames, forKey: DefaultsKey.keepExtractedFrames) }
    }

    // Progress / results
    @Published var progress: Double = 0
    @Published var resultVideoURL: URL?
    @Published var resultImage: CGImage?
    @Published var resultImageURL: URL?
    @Published var resultSummary: String?
    @Published var saveConfirmation: String?
    @Published var statusMessage = ""
    @Published var jobFolderURL: URL?
    @Published var jobLogLines: [String] = []
    @Published var processingStartedAt: Date?
    /// Explicit pipeline position; drives the checklist and the status line.
    @Published var processingPhase: ProcessingPhase = .preparing
    /// Absolute finish estimate — the view counts down against its own clock
    /// tick. Nil whenever there's no honest signal yet (early in a phase).
    @Published var processingETADate: Date?
    /// Whole-run frame counts from the progress plan, on both platforms.
    @Published var processingFramesDone: Int?
    @Published var processingFramesTotal: Int?

    /// The frame-weighted band layout for the run in flight; nil outside one.
    private var activeProgressPlan: BlendProgressPlan?
    /// When the current tail stage (stitch/grade export) began, for its ETA.
    private var tailPhaseStartedAt: Date?

    /// Set by screens that want the Projects tab to open a specific project
    /// (e.g. Result → Done). ContentView consumes and clears it.
    @Published var requestedProjectDetailID: UUID?

    /// Set by screens that want a specific tab brought front — the camera's
    /// recent-capture tile asking for the Gallery. ContentView consumes and
    /// clears it. Screens presented over the tabs (the camera is a full-screen
    /// cover) must dismiss themselves as well; this only moves the selection.
    @Published var requestedTab: LLTab?
    /// The Watch asking for the camera back. Handled by `ContentView`, which
    /// presents the capture screen OVER whatever is showing — a setup flow
    /// underneath is left completely alone, which is what lets the remote
    /// promise that your steps stay saved. A separate flag from
    /// `requestedTab` because the camera must open even when Create is
    /// already the selected tab, and a tab selection that doesn't change
    /// fires no `onChange`.
    @Published var requestedCameraOpen = false
    /// Which step the Guided Clip builder is on, mirrored for the remote.
    /// `GuidedBuilderView` keeps owning this — the rail, the visited-step
    /// high-water mark and the `LL_STEP` hook all read its own `@State`, and
    /// moving the source of truth for a read-only mirror would be a poor
    /// trade. These are write-only from the builder's side.
    @Published var guidedStep: Int?
    @Published var guidedStepCount: Int?

    /// Set by screens that want Settings opened on a specific page — the project detail's
    /// "Download a model in Settings" caption. ContentView consumes and clears it.
    @Published var requestedSettingsDestination: SettingsDestination?

    private var blendTask: Task<Void, Never>?

    init() {
        loadLibrary()
    }

    var currentCapture: CaptureProject? {
        guard let currentCaptureID else { return nil }
        return captures.first { $0.id == currentCaptureID }
    }

    var currentBlend: BlendProject? {
        guard let resultBlendID else { return nil }
        return blends.first { $0.id == resultBlendID }
    }

    func blends(for capture: CaptureProject) -> [BlendProject] {
        blends
            .filter { $0.captureID == capture.id }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The image that stands for a photo-kind capture: its newest image
    /// version when one exists, else the captured frame itself. For a
    /// Photo-mode capture this IS the photo — the one user-facing asset
    /// (Blend Off keeps the frame; a blended shot's photo is the stack).
    func heroImageURL(for capture: CaptureProject) -> URL? {
        guard capture.kind == .photos else { return nil }
        if let blend = blends(for: capture).first(where: { $0.kind == .image }) {
            return mediaURL(for: blend)
        }
        return mediaURL(for: capture)
    }

    /// The single asset that stands for a capture wherever it is shown as one
    /// tile — the Gallery grid, and the camera's recent-capture button.
    /// Photo/Interval captures resolve to their hero image (newest blend, else
    /// the captured frame); video captures to the source video.
    func heroAsset(for capture: CaptureProject) -> (url: URL, kind: MediaKind)? {
        if capture.kind == .photos {
            guard let url = heroImageURL(for: capture) else { return nil }
            return (url, .image)
        }
        guard let url = mediaURL(for: capture) else { return nil }
        return (url, .video)
    }

    func capture(for blend: BlendProject) -> CaptureProject? {
        captures.first { $0.id == blend.captureID }
    }

    func mediaKind(for capture: CaptureProject) -> MediaKind {
        capture.kind == .video ? .video : .image
    }

    func mediaKind(for blend: BlendProject) -> MediaKind {
        blend.kind == .video ? .video : .image
    }

    /// The folder holding everything a project owns — its `source/` and
    /// `blends/` trees — at `Projects/<id>/` under Application Support. The
    /// folder is named for the project's `id`, which is why "Show in Finder"
    /// exists at all: nothing in the UI otherwise tells you which UUID on disk
    /// is the project you are looking at.
    func projectFolderURL(for capture: CaptureProject) -> URL {
        captureFolderURL(for: capture.id)
    }

    /// Where all projects live. The fallback for revealing a project whose own
    /// folder has gone missing.
    var projectsFolderURL: URL {
        projectsRootURL
    }

    func mediaURL(for capture: CaptureProject) -> URL? {
        guard let source = try? source(for: capture) else { return nil }
        switch source {
        case .video(let url):
            return url
        case .liveSequence(let source):
            return source.primaryVideoURL
        case .photos(let urls):
            return urls.first
        }
    }

    func mediaURL(for blend: BlendProject) -> URL {
        blendOutputURL(for: blend)
    }

    /// Every source still backing a photo-kind capture, in capture order — the
    /// interval shoot's individual frames. Unlike `source(for:)` this never
    /// throws on a missing file and never touches the filesystem: it is read
    /// from view bodies, where a `stat` per frame across a few hundred frames
    /// would land on the main thread. Frames that have gone away simply render
    /// as the grid's placeholder tile.
    func sourceFrameURLs(for capture: CaptureProject) -> [URL] {
        guard capture.kind == .photos else { return [] }
        let root = captureFolderURL(for: capture.id)
        return capture.sourceFileNames
            .filter { !$0.hasSuffix(".json") }
            .map { root.appendingPathComponent($0) }
    }

    /// The individual source video segments backing a capture. Live sequences
    /// have several; single imports have one; photo stacks have none.
    func sourceClipURLs(for capture: CaptureProject) -> [URL] {
        guard let source = try? source(for: capture) else { return [] }
        switch source {
        case .video(let url):
            return [url]
        case .liveSequence(let liveSource):
            return liveSource.segmentURLs
        case .photos:
            return []
        }
    }

    func deleteCapture(_ capture: CaptureProject) throws {
        guard captures.contains(where: { $0.id == capture.id }) else { return }
        if currentCaptureID == capture.id && stage == .processing {
            throw LibraryDeletionError.activeCapture
        }

        let folder = captureFolderURL(for: capture.id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }

        let removedBlendIDs = Set(blends.filter { $0.captureID == capture.id }.map(\.id))
        captures.removeAll { $0.id == capture.id }
        blends.removeAll { $0.captureID == capture.id }
        removeCollectionEntries(blendIDs: removedBlendIDs)
        try persistLibrary()

        if currentCaptureID == capture.id {
            reset()
        }
    }

    func deleteBlend(_ blend: BlendProject) throws {
        guard blends.contains(where: { $0.id == blend.id }) else { return }

        let captureFolder = captureFolderURL(for: blend.captureID).standardizedFileURL
        let output = blendOutputURL(for: blend).standardizedFileURL
        let capturePrefix = captureFolder.path.hasSuffix("/") ? captureFolder.path : captureFolder.path + "/"
        guard output.path.hasPrefix(capturePrefix) else {
            throw LibraryDeletionError.unsafeBlendPath
        }

        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        blends.removeAll { $0.id == blend.id }
        removeCollectionEntries(blendIDs: [blend.id])
        try persistLibrary()

        let blendsFolder = output.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: blendsFolder.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: blendsFolder)
        }

        if resultBlendID == blend.id {
            resultBlendID = nil
            resultVideoURL = nil
            resultImage = nil
            resultImageURL = nil
            resultSummary = nil
            saveConfirmation = nil
            jobFolderURL = nil
            jobLogLines = []
            stage = source == nil ? .home : .configure
        }
    }

    // MARK: - Collections

    /// Dropping a blend (or its whole project) drops it from every collection
    /// that used it. The remaining clips keep their order; a stale kept render
    /// invalidates on its own because the collection's recipe changed.
    private func removeCollectionEntries(blendIDs: Set<UUID>) {
        guard !blendIDs.isEmpty else { return }
        collections = collections.map { collection in
            var collection = collection
            collection.entries.removeAll { blendIDs.contains($0.blendID) }
            return collection
        }
    }

    func collection(withID id: UUID) -> LapseCollection? {
        collections.first { $0.id == id }
    }

    /// The name sheet's pre-fill: "Collection N".
    var suggestedCollectionName: String {
        "Collection \(collections.count + 1)"
    }

    @discardableResult
    func createCollection(named name: String) -> LapseCollection {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = LapseCollection(name: trimmed.isEmpty ? suggestedCollectionName : trimmed)
        collections.append(collection)
        persistCollectionsQuietly()
        return collection
    }

    func renameCollection(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateCollection(id) { $0.name = trimmed }
    }

    func deleteCollection(_ id: UUID) {
        guard collections.contains(where: { $0.id == id }) else { return }
        collections.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: collectionRenderFolderURL(for: id))
        persistCollectionsQuietly()
    }

    /// Adds blends to a collection in order, skipping any already there —
    /// one appearance per collection (callers pre-check when they want the
    /// refusal toast). The first clip a collection ever receives sets its
    /// canvas; the ratio it set is returned so the caller can say so.
    @discardableResult
    func addBlends(_ blendIDs: [UUID], to collectionID: UUID) -> CanvasRatio? {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return nil }
        var collection = collections[index]
        var setRatio: CanvasRatio?
        for blendID in blendIDs {
            guard let blend = blends.first(where: { $0.id == blendID }),
                  blend.kind == .video,
                  collection.entry(for: blendID) == nil else { continue }
            if collection.ratio == nil {
                let ratio = canvasRatio(for: blend)
                collection.ratio = ratio
                setRatio = ratio
            }
            collection.entries.append(LapseCollection.Entry(blendID: blendID))
        }
        collections[index] = collection
        persistCollectionsQuietly()
        return setRatio
    }

    func removeEntry(blendID: UUID, from collectionID: UUID) {
        mutateCollection(collectionID) { collection in
            collection.entries.removeAll { $0.blendID == blendID }
        }
    }

    func moveEntry(in collectionID: UUID, from source: Int, to destination: Int) {
        mutateCollection(collectionID) { collection in
            guard collection.entries.indices.contains(source),
                  collection.entries.indices.contains(destination) else { return }
            let entry = collection.entries.remove(at: source)
            collection.entries.insert(entry, at: destination)
        }
    }

    func setCanvasRatio(_ ratio: CanvasRatio, for collectionID: UUID) {
        mutateCollection(collectionID) { $0.ratio = ratio }
    }

    func updateTrim(blendID: UUID, in collectionID: UUID, inPoint: Double, outPoint: Double) {
        mutateCollection(collectionID) { collection in
            guard let idx = collection.entries.firstIndex(where: { $0.blendID == blendID }) else { return }
            collection.entries[idx].inPoint = min(max(0, inPoint), 1)
            collection.entries[idx].outPoint = min(max(0, outPoint), 1)
        }
    }

    /// A crop saved "just for this collection".
    func setLocalCrop(blendID: UUID, in collectionID: UUID, ratio: CanvasRatio, offset: Double) {
        mutateCollection(collectionID) { collection in
            guard let idx = collection.entries.firstIndex(where: { $0.blendID == blendID }) else { return }
            collection.entries[idx].crops[ratio.rawValue] = min(max(0, offset), 1)
        }
    }

    /// A crop saved as the clip's default for this ratio — every collection
    /// without its own override follows it. Clearing the saving collection's
    /// local override is deliberate: "replace the default" means this
    /// collection now follows the default it just wrote.
    func setDefaultCrop(blendID: UUID, ratio: CanvasRatio, offset: Double, clearLocalIn collectionID: UUID?) {
        guard let blendIndex = blends.firstIndex(where: { $0.id == blendID }) else { return }
        var crops = blends[blendIndex].defaultCrops ?? [:]
        crops[ratio.rawValue] = min(max(0, offset), 1)
        blends[blendIndex].defaultCrops = crops
        if let collectionID,
           let index = collections.firstIndex(where: { $0.id == collectionID }),
           let entryIndex = collections[index].entries.firstIndex(where: { $0.blendID == blendID }) {
            collections[index].entries[entryIndex].crops.removeValue(forKey: ratio.rawValue)
        }
        persistCollectionsQuietly()
    }

    /// Whether the entry's clip needs a crop on this collection's canvas, and
    /// with which resolved pan offset: the collection's own override, else the
    /// clip's default, else centred. nil when the clip matches the canvas.
    func resolvedCropOffset(entry: LapseCollection.Entry, in collection: LapseCollection) -> Double? {
        guard let ratio = collection.ratio,
              let blend = blends.first(where: { $0.id == entry.blendID }),
              blendNeedsCrop(blend, on: ratio) else { return nil }
        return entry.crops[ratio.rawValue]
            ?? blend.defaultCrops?[ratio.rawValue]
            ?? 0.5
    }

    /// Whether an entry carries its own crop for the collection's canvas
    /// (the "CROP 16:9 · CUSTOM" badge).
    func entryHasLocalCrop(_ entry: LapseCollection.Entry, in collection: LapseCollection) -> Bool {
        guard let ratio = collection.ratio else { return false }
        return entry.crops[ratio.rawValue] != nil
    }

    func blendNeedsCrop(_ blend: BlendProject, on ratio: CanvasRatio) -> Bool {
        abs(blendAspect(blend) - ratio.aspect) > 0.01
    }

    /// The clip's display-oriented pixel size: the probed value once a probe
    /// has landed, else the recorded output stats.
    func blendDisplaySize(for blend: BlendProject) -> CGSize? {
        if let probed = probedBlendSizes[blend.id] { return probed }
        guard let width = blend.width, let height = blend.height, width > 0, height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// The clip's picture aspect as displayed.
    func blendAspect(_ blend: BlendProject) -> Double {
        guard let size = blendDisplaySize(for: blend), size.height > 0 else { return 16.0 / 9.0 }
        return size.width / size.height
    }

    /// The canvas the first clip sets: the ratio closest to the clip's own.
    func canvasRatio(for blend: BlendProject) -> CanvasRatio {
        let aspect = blendAspect(blend)
        return CanvasRatio.allCases.min {
            abs($0.aspect - aspect) < abs($1.aspect - aspect)
        } ?? .wide
    }

    // MARK: - Blend canvas (Adjust)

    /// The current source's display-oriented pixel size. Rotation is already
    /// baked in: a metadata-only Rotate 90° swaps the capture's stored
    /// `sourceWidth`/`sourceHeight`, so these are the dimensions as displayed.
    func sourceDisplaySize() -> CGSize? {
        guard let capture = currentCapture,
              let width = capture.sourceWidth, let height = capture.sourceHeight,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The canvas the source was shot at: the ratio nearest its oriented
    /// aspect — the Adjust picker's default.
    func sourceCanvasRatio() -> CanvasRatio {
        guard let size = sourceDisplaySize() else { return .wide }
        let aspect = size.width / size.height
        return CanvasRatio.allCases.min {
            abs($0.aspect - aspect) < abs($1.aspect - aspect)
        } ?? .wide
    }

    /// What the Adjust screen edits against: the chosen canvas, else as shot.
    func effectiveBlendCanvas() -> CanvasRatio {
        blendCanvasRatio ?? sourceCanvasRatio()
    }

    /// Whether creating the clip will crop — the chosen canvas disagrees with
    /// the source's own shape beyond tolerance.
    func blendCanvasNeedsCrop() -> Bool {
        guard let size = sourceDisplaySize() else { return false }
        return VideoCanvasCropper.cropSize(displaySize: size, canvas: effectiveBlendCanvas()) != nil
    }

    /// The pixels the chosen canvas keeps (centred, source scale) — the created
    /// clip's dimensions, and the picker caption's number. nil when no crop.
    func blendCanvasCropSize() -> CGSize? {
        guard let size = sourceDisplaySize() else { return nil }
        return VideoCanvasCropper.cropSize(displaySize: size, canvas: effectiveBlendCanvas())
    }

    /// Collections that use this blend — the delete warning and the crop
    /// prompt both hinge on it.
    func collectionsUsing(blendID: UUID) -> [LapseCollection] {
        collections.filter { $0.entry(for: blendID) != nil }
    }

    /// One clip's kept length on the timeline.
    func entrySeconds(_ entry: LapseCollection.Entry) -> Double {
        guard let blend = blends.first(where: { $0.id == entry.blendID }),
              let duration = blendDuration(for: blend) else { return 0 }
        return entry.keptFraction * duration
    }

    /// The whole timeline's length — trims retime the cut, clips butt together.
    func collectionSeconds(_ collection: LapseCollection) -> Double {
        collection.entries.reduce(0) { $0 + entrySeconds($1) }
    }

    /// A clip's full duration: recorded stats first, probed as a fallback for
    /// manifests that predate output stats. nil until a probe lands.
    func blendDuration(for blend: BlendProject) -> Double? {
        blend.outputSeconds ?? probedBlendDurations[blend.id]
    }

    /// Fills the duration and oriented-size caches for a clip whose stats are
    /// missing or possibly rotation-flipped. One asset load covers both.
    func probeBlendMediaIfNeeded(_ blend: BlendProject) async {
        guard blend.kind == .video else { return }
        let needsDuration = blendDuration(for: blend) == nil
        let needsSize = probedBlendSizes[blend.id] == nil
        guard needsDuration || needsSize else { return }
        let asset = AVURLAsset(url: blendOutputURL(for: blend))
        if needsDuration,
           let duration = try? await asset.load(.duration).seconds,
           duration.isFinite, duration > 0 {
            probedBlendDurations[blend.id] = duration
        }
        if needsSize,
           let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let oriented = CGRect(origin: .zero, size: natural).applying(transform)
            let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            if size.width > 0, size.height > 0 {
                probedBlendSizes[blend.id] = size
            }
        }
    }

    /// The collection export's frame rate: the fastest member clip's, so no
    /// clip is thinned — clamped to the app's output range.
    func collectionExportFPS(_ collection: LapseCollection) -> Int {
        let best = collection.entries
            .compactMap { entry in blends.first { $0.id == entry.blendID }?.outputFPS }
            .max() ?? 30
        return min(60, max(24, best))
    }

    /// Everything the render depends on, as one stable string. While the kept
    /// render's recipe matches, exporting again is instant.
    func collectionRecipe(_ collection: LapseCollection) -> String {
        let head = "\(collection.ratioRaw ?? "—")@\(collectionExportFPS(collection))"
        let parts = collection.entries.map { entry -> String in
            let crop = resolvedCropOffset(entry: entry, in: collection)
                .map { String(format: "%.4f", $0) } ?? "fit"
            return "\(entry.blendID.uuidString):\(String(format: "%.4f", entry.inPoint))-\(String(format: "%.4f", entry.outPoint))@\(crop)"
        }
        return ([head] + parts).joined(separator: "|")
    }

    /// The kept render, when it still matches the collection's recipe and is
    /// on disk. nil means the next export renders fresh.
    func validCachedRender(for collection: LapseCollection) -> URL? {
        guard !collection.entries.isEmpty,
              let last = collection.lastExport,
              last.recipe == collectionRecipe(collection) else { return nil }
        let url = collectionRenderFolderURL(for: collection.id).appendingPathComponent(last.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func recordCollectionExport(_ collectionID: UUID, fileName: String, recipe: String) {
        mutateCollection(collectionID) { collection in
            collection.lastExport = LapseCollection.ExportRecord(
                fileName: fileName, exportedAt: Date(), recipe: recipe)
        }
    }

    func collectionRenderFolderURL(for id: UUID) -> URL {
        applicationSupportURL
            .appendingPathComponent("Collections", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// The blend's media file, for collection playback and export.
    func blendMediaURL(for blendID: UUID) -> URL? {
        blends.first { $0.id == blendID }.map(blendOutputURL(for:))
    }

    private func mutateCollection(_ id: UUID, _ mutate: (inout LapseCollection) -> Void) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        var collection = collections[index]
        mutate(&collection)
        collections[index] = collection
        persistCollectionsQuietly()
    }

    /// Collection edits are frequent and small; a failed write surfaces like
    /// every other library error rather than throwing out of a drag gesture.
    private func persistCollectionsQuietly() {
        do {
            try persistLibrary()
        } catch {
            errorMessage = "Couldn't save the collection: \(error.localizedDescription)"
        }
    }

    #if DEBUG
    /// LL_COLLECTIONS screenshot hook: demo collections built from whatever
    /// video blends the library already has. No-op once any collection exists
    /// so repeated launches don't multiply.
    func debugSeedCollections() {
        guard collections.isEmpty else { return }
        let videoBlends = blends.filter { $0.kind == .video }
        guard !videoBlends.isEmpty else { return }
        let first = createCollection(named: "Harbour reel")
        addBlends(videoBlends.prefix(3).map(\.id), to: first.id)
        if let entry = collection(withID: first.id)?.entries.first {
            updateTrim(blendID: entry.blendID, in: first.id, inPoint: 0.125, outPoint: 0.833)
        }
        if videoBlends.count > 1 {
            let second = createCollection(named: "City set")
            addBlends(Array(videoBlends.suffix(2)).map(\.id), to: second.id)
            setCanvasRatio(.tall, for: second.id)
        }
    }

    /// LL_TAGS=demo screenshot hook: stamps plausible scene metadata across the library so the
    /// Projects search field, its tag chips and the card tag lines have something to act on.
    /// Running the real analyser on a simulator is not an option — MLX needs a GPU the simulator
    /// does not have — and on a device it would mean a 3.3 GB download per verification pass.
    ///
    /// Deliberately writes through the same persistence as a real Apply, so a seeded library
    /// exercises the decode path too.
    func debugSeedSceneTags() {
        let samples: [(tags: [String], elements: [String])] = [
            (["water", "nature"], ["waterfall", "mossy rocks"]),
            (["urban", "lightTrails"], ["traffic", "tower block"]),
            (["skyWeather", "nature"], ["storm clouds", "ridgeline"]),
            (["people", "event"], ["market stalls", "crowd"]),
            (["water", "skyWeather", "landmark"], ["harbour", "suspension bridge"]),
        ]
        for (index, capture) in captures.enumerated() where capture.sceneTags == nil {
            let sample = samples[index % samples.count]
            captures[index].sceneTags = sample.tags
            captures[index].sceneElements = sample.elements
        }
        try? persistLibrary()
    }

    /// LL_ADJUST=demo screenshot hook: the newest video capture opened on the
    /// Adjust screen inside a fabricated two-moment sequence — the design's
    /// 8:16 sample (178s + 24s@120 + 198s + 8s@120 + 88s) — so the output-time
    /// ruler shows structure without a real burst shoot. Never persisted, and
    /// Create would blend the same file per piece, so screenshots only.
    func debugOpenAdjustDemo() {
        guard let capture = captures.first(where: { $0.kind == .video }) else { return }
        openCapture(capture)
        guard let url = mediaURL(for: capture) else { return }
        let name = url.lastPathComponent
        let sequence = LiveCaptureSequence(
            mode: .ramp,
            createdAt: capture.createdAt,
            lockedResolution: .init(width: 3840, height: 2160),
            baseFrameRate: 30,
            rampFrameRate: 120,
            segments: [
                .init(index: 0, fileName: name, frameRate: 30, relativeStart: 0, relativeEnd: 178),
                .init(index: 1, fileName: name, frameRate: 120, relativeStart: 178, relativeEnd: 202),
                .init(index: 2, fileName: name, frameRate: 30, relativeStart: 202, relativeEnd: 400),
                .init(index: 3, fileName: name, frameRate: 120, relativeStart: 400, relativeEnd: 408),
                .init(index: 4, fileName: name, frameRate: 30, relativeStart: 408, relativeEnd: 496),
            ],
            markers: [],
            rampIntervals: [
                .init(index: 0, relativeStart: 178, relativeEnd: 202),
                .init(index: 1, relativeStart: 400, relativeEnd: 408),
            ])
        source = .liveSequence(LiveCaptureSource(
            sequence: sequence,
            segmentURLs: [url],
            metadataURL: url,
            resolvedByOriginalName: [name: url]))
        stage = .configure
    }

    /// LL_STRETCH="1=0.25,3=15" — pin warp stretch speeds (×-real-time) by
    /// stretch index for variant screenshots.
    func debugApplyStretchOverrides(_ raw: String) {
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: "=")
            guard parts.count == 2,
                  let index = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let speed = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            updateWarp { timeline in
                timeline.setSpeed(speed, for: index)
            }
        }
        // The seeded speeds are the screenshot's starting state, not edits —
        // don't leave the Undo chip lit on a fresh variant run.
        clearWarpHistory()
    }
    #endif

    func setSource(_ source: Source, mode: String = "Import") {
        do {
            let capture = try registerCapture(from: source, mode: mode)
            openCapture(capture)
        } catch {
            errorMessage = "Couldn't preserve the capture: \(error.localizedDescription)"
        }
    }

    func setSequenceSource(_ result: LiveCaptureResult) {
        do {
            let capture = try registerSequenceCapture(result)
            openCapture(capture)
        } catch {
            errorMessage = "Couldn't preserve the capture: \(error.localizedDescription)"
        }
    }

    /// Flag the trailing shaky frames from an interval shoot for review on the
    /// Adjust screen. Called after `setSource`, so the fresh-source `openCapture`
    /// (which clears these) has already run and won't wipe the flag.
    func flagTailFrames(count: Int, total: Int) {
        tailFramesToExclude = count
        totalIntervalFrames = total
    }

    func reset() {
        blendTask?.cancel()
        blendTask = nil
        source = nil
        currentCaptureID = nil
        photoBlendDepth = 1
        blendCanvasRatio = nil
        blendCanvasOffset = 0.5
        warp = nil
        reframe = nil
        reframeLaneFocused = false
        guidedBuilderFocused = false
        exportShortEdge = nil
        clearWarpHistory()
        excludedFrameIndices = []
        tailFramesToExclude = 0
        totalIntervalFrames = 0
        resultBlendID = nil
        resultVideoURL = nil
        resultImage = nil
        resultImageURL = nil
        resultSummary = nil
        saveConfirmation = nil
        statusMessage = ""
        jobFolderURL = nil
        jobLogLines = []
        errorMessage = nil
        resetProcessingProgress()
        stage = .home
    }

    /// Wrap up the flow. When `openProject` is set the Projects tab opens the
    /// project this run belonged to, so a finished clip is never a dead end.
    func finishFlow(openProject: Bool) {
        let captureID = currentCaptureID
        reset()
        if openProject, let captureID {
            requestedProjectDetailID = captureID
        }
    }

    func openCapture(_ capture: CaptureProject) {
        do {
            blendSourceCodec = nil
            blendCanvasRatio = nil
            blendCanvasOffset = 0.5
            source = try source(for: capture)
            currentCaptureID = capture.id
            photoBlendDepth = 1
            warp = nil
            reframe = nil
            reframeLaneFocused = false
            guidedBuilderFocused = false
            exportShortEdge = nil
            clearWarpHistory()
            excludedFrameIndices = []
            tailFramesToExclude = 0
            totalIntervalFrames = 0
            resultBlendID = nil
            resultVideoURL = nil
            resultImage = nil
            resultImageURL = nil
            resultSummary = nil
            saveConfirmation = nil
            errorMessage = nil
            stage = .configure
        } catch {
            errorMessage = "Couldn't open that capture: \(error.localizedDescription)"
        }
    }

    func openBlend(_ blend: BlendProject) {
        guard let capture = captures.first(where: { $0.id == blend.captureID }) else {
            errorMessage = "The source capture for that blend is missing."
            return
        }

        do {
            blendSourceCodec = nil
            blendCanvasRatio = nil
            blendCanvasOffset = 0.5
            source = try source(for: capture)
            currentCaptureID = capture.id
            warp = nil
            reframe = nil
            reframeLaneFocused = false
            guidedBuilderFocused = false
            exportShortEdge = nil
            clearWarpHistory()
            excludedFrameIndices = []
            tailFramesToExclude = 0
            totalIntervalFrames = 0
            resultBlendID = blend.id
            resultVideoURL = nil
            resultImage = nil
            resultImageURL = nil
            resultSummary = blend.summary

            if let compressionRatio = blend.compressionRatio {
                if source?.isVideo == true {
                    constantWindow = compressionRatio
                } else {
                    photoBlendDepth = compressionRatio
                }
            }
            if let outputFPS = blend.outputFPS {
                self.outputFPS = outputFPS
            }
            linearLight = blend.linearLight
            useRamp = blend.useRamp
            rampStart = blend.rampStart
            rampEnd = blend.rampEnd
            if let savedCurve = BlendCurve(rawValue: blend.curve) {
                curve = savedCurve
            }
            trimVideoEnds = (blend.trimHeadTailSeconds ?? 0) > 0
            if let trimHeadTailSeconds = blend.trimHeadTailSeconds {
                self.trimHeadTailSeconds = max(0.1, trimHeadTailSeconds)
            }
            // Re-blending starts from exactly the timeline this clip was made
            // with. Clips from the short-lived per-stretch ruler convert their
            // windows into warp speeds (v = window · outFps ⁄ srcFps). The
            // reframe's geometry only means anything on the canvas it was
            // authored against, so that comes back with it.
            reframe = blend.reframe
            blendCanvasRatio = blend.canvasRatio.flatMap(CanvasRatio.init(rawValue:))
            blendCanvasOffset = blend.canvasOffset ?? 0.5
            if let savedWarp = blend.warp {
                warp = savedWarp
            } else if let savedWindows = blend.stretchWindows, !savedWindows.isEmpty {
                let stretches = blendStretches()
                if stretches.count == savedWindows.count, stretches.count > 1 {
                    var converted = seededLegacyWarpBase(stretches: stretches)
                    for (index, window) in savedWindows.enumerated() {
                        let sourceFPS = Double(max(1, stretches[index].fps))
                        converted.speeds[index] = Double(window) * Double(outputFPS) / sourceFPS
                    }
                    warp = converted
                }
            }

            let outputURL = blendOutputURL(for: blend)
            switch blend.kind {
            case .video:
                resultVideoURL = outputURL
            case .image:
                resultImageURL = outputURL
                resultImage = loadImage(at: outputURL)
            }

            saveConfirmation = nil
            errorMessage = nil
            stage = .done
        } catch {
            errorMessage = "Couldn't open that blend: \(error.localizedDescription)"
        }
    }

    func cancelProcessing() {
        blendTask?.cancel()
    }

    var ramp: BlendRamp {
        useRamp
            ? BlendRamp(startWindow: rampStart, endWindow: rampEnd, curve: curve)
            : .constant(constantWindow)
    }

    /// For a photo source, how many output frames the current blend depth
    /// yields — each window of `photoBlendDepth` stills becomes one frame.
    var photoOutputFrameCount: Int? {
        guard let capture = currentCapture, capture.kind == .photos else { return nil }
        let count = capture.sourceMediaCount
        guard count > 0 else { return nil }
        return WindowSchedule.make(totalInputFrames: count, ramp: .constant(photoBlendDepth)).count
    }

    /// True when the blend depth folds every still into one frame — the classic
    /// single stacked long-exposure image rather than a video sequence.
    var photosProduceSingleImage: Bool {
        guard let capture = currentCapture, capture.kind == .photos else { return false }
        let count = capture.sourceMediaCount
        return count > 0 && photoBlendDepth >= count
    }

    // MARK: - Estimates

    /// Source frames the current settings would feed into the blend, after trim.
    var estimatedInputFrames: Double? {
        guard let capture = currentCapture else { return nil }
        switch capture.kind {
        case .photos:
            return Double(capture.sourceMediaCount)
        case .video:
            guard var duration = capture.sourceDurationSeconds else {
                if let known = blends(for: capture).compactMap(\.inputFrames).max() {
                    return Double(known)
                }
                return nil
            }
            if case .video = source, trimVideoEnds {
                duration = max(0, duration - 2 * max(0, trimHeadTailSeconds))
            }
            return duration * (capture.sourceFPS ?? 30)
        }
    }

    /// The one number that matters: how long the clip will be. With the warp
    /// timeline active this is exact — the compiled schedule's frame count —
    /// including every seam's ease. `speed` gives the legacy whole-clip
    /// hypothetical (the Result screen's "try N×" suggestion).
    func estimatedOutputSeconds(speed: Int? = nil) -> Double? {
        guard source?.isVideo == true else { return nil }
        if speed == nil, !useRamp, let compiled = compiledWarp(), compiled.outputFrames > 0 {
            return compiled.outputSeconds
        }
        guard let frames = estimatedInputFrames else { return nil }
        let window: Int
        if let speed {
            window = speed
        } else if useRamp {
            window = max(1, (rampStart + rampEnd) / 2)
        } else {
            window = constantWindow
        }
        return SpeedMath.outputSeconds(inputFrames: frames, speed: window, outputFPS: outputFPS)
    }

    // MARK: - Warp timeline

    /// The recorded shape of the capture, for seeding the warp — moments and
    /// base runs in order. One whole-clip stretch for continuous footage.
    func blendStretches() -> [BlendStretch] {
        guard let capture = currentCapture else { return [] }
        switch source {
        case .liveSequence(let liveSource):
            let stretches = StretchBuilder.stretches(
                for: liveSource.sequence,
                segmentSeconds: capture.sourceSegmentSeconds)
            return stretches.isEmpty
                ? StretchBuilder.singleStretch(
                    seconds: capture.sourceDurationSeconds, fps: capture.sourceFPS)
                : stretches
        case .video:
            // The warp axis is the whole source; head/tail trim applies at
            // compile time, not here.
            return StretchBuilder.singleStretch(
                seconds: capture.sourceDurationSeconds, fps: capture.sourceFPS)
        default:
            return []
        }
    }

    /// The timeline the Adjust screen draws — the stored one (rebased onto
    /// the current axis if it predates the file probe), else a fresh seed
    /// (not yet published; edits go through `updateWarp`).
    func activeWarp() -> WarpTimeline {
        warp.map(healWarpAxis) ?? seededWarp()
    }

    /// A stored timeline may have been authored before the axis was probed —
    /// its bounds ride the sidecar's wall-clock spans, which overshoot the
    /// files by a fraction of a second per segment. Rebase it segment-by-
    /// segment onto the probed axis so every seam stays glued to its file
    /// boundary. Idempotent: once totals agree the timeline passes through
    /// untouched.
    private func healWarpAxis(_ timeline: WarpTimeline) -> WarpTimeline {
        guard case .liveSequence(let live) = source, live.sequence.mode == .ramp,
              let probed = currentCapture?.sourceSegmentSeconds, !probed.isEmpty,
              timeline.sourceSeconds > 0.01 else { return timeline }
        let ordered = live.sequence.segments.sorted { $0.index < $1.index }
        let oldSpans = ordered.map { max(0, $0.relativeEnd - $0.relativeStart) }
        let newSpans = ordered.map { probed[$0.fileName] ?? max(0, $0.relativeEnd - $0.relativeStart) }
        let oldTotal = oldSpans.reduce(0, +)
        let newTotal = newSpans.reduce(0, +)
        guard abs(timeline.sourceSeconds - newTotal) > 0.02 else { return timeline }
        var healed = timeline
        guard abs(timeline.sourceSeconds - oldTotal) < 0.02 else {
            // Authored on an axis we can't reconstruct — a uniform rescale
            // still lands the endpoints where the files really end.
            let scale = newTotal / timeline.sourceSeconds
            healed.bounds = timeline.bounds.map { $0 * scale }
            return healed
        }
        var oldCum = [0.0], newCum = [0.0]
        for span in oldSpans { oldCum.append((oldCum.last ?? 0) + span) }
        for span in newSpans { newCum.append((newCum.last ?? 0) + span) }
        healed.bounds = timeline.bounds.map { bound in
            var k = 0
            while k < oldSpans.count - 1, bound > oldCum[k + 1] + 0.0001 { k += 1 }
            let offset = oldSpans[k] > 0 ? (bound - oldCum[k]) / oldSpans[k] : 0
            return newCum[k] + offset * newSpans[k]
        }
        return healed
    }

    /// One undoable moment of the Adjust screen. `warp` stays Optional so undo
    /// can restore the pristine not-yet-edited state (which re-seeds live);
    /// `useRamp` rides along because `updateWarp` silently switches it off.
    /// `reframe` rides the same stack so a session interleaving speed and
    /// punch edits unwinds in the order it was made.
    struct WarpEditSnapshot: Equatable {
        var warp: WarpTimeline?
        var useRamp: Bool
        var reframe: ReframeTrack?
    }

    /// Uncapped on purpose: snapshots are three small arrays, and a cap would
    /// desynchronize this stack from the window UndoManager's registrations.
    @Published private(set) var warpUndoStack: [WarpEditSnapshot] = []
    @Published private(set) var warpRedoStack: [WarpEditSnapshot] = []
    /// While non-nil, edits carrying the same key fold into the snapshot the
    /// first one pushed — a resize drag is one undo step, not sixty.
    private var warpCoalescingKey: String?
    /// The focused window's UndoManager, handed over by the Adjust screen so
    /// Cmd-Z / shake / three-finger-swipe drive the same stack as the chip.
    weak var warpUndoManager: UndoManager?
    private static let warpUndoActionName = "Timeline Edit"

    var canUndoWarp: Bool { !warpUndoStack.isEmpty }
    var canRedoWarp: Bool { !warpRedoStack.isEmpty }

    /// Edit the timeline. Direct manipulation always means explicit stretch
    /// speeds, so the Advanced ramp switches off — as touching a speed control
    /// always has. Every distinct edit pushes an undo snapshot; pass a
    /// `coalescing` key from continuous gestures and call
    /// `endWarpCoalescing()` when the gesture lifts.
    func updateWarp(coalescing key: String? = nil, _ transform: (inout WarpTimeline) -> Void) {
        let before = WarpEditSnapshot(warp: warp, useRamp: useRamp, reframe: reframe)
        let baseline = activeWarp()
        var timeline = baseline
        transform(&timeline)
        // A no-op edit pushes nothing — including identity transforms on the
        // pristine (still re-seeding) screen, so tapping the already-active
        // chip never lights the Undo affordance. It also leaves the coalescing
        // key alone, so a gesture's first REAL change still snapshots the true
        // before-state.
        let changed = timeline != baseline || useRamp
        guard changed else { return }
        if key == nil || key != warpCoalescingKey {
            warpUndoStack.append(before)
            warpRedoStack.removeAll()
            registerSystemUndo()
        }
        warpCoalescingKey = key
        warp = timeline
        useRamp = false
    }

    /// The reframe lane the Adjust screen draws — the stored track, else
    /// empty. Never seeded: no keys means the full frame.
    func activeReframe() -> ReframeTrack {
        reframe ?? ReframeTrack()
    }

    /// Edit the reframe track. Same contract as `updateWarp` — every distinct
    /// edit is one undo step on the SAME stack, so speed and punch edits
    /// unwind in the order they were made; pass a `coalescing` key from
    /// continuous gestures and call `endWarpCoalescing()` when the gesture
    /// lifts. Unlike a warp edit, a punch edit says nothing about speed, so
    /// the Advanced ramp stays as it is.
    func updateReframe(coalescing key: String? = nil, _ transform: (inout ReframeTrack) -> Void) {
        let before = WarpEditSnapshot(warp: warp, useRamp: useRamp, reframe: reframe)
        let baseline = reframe ?? ReframeTrack()
        var track = baseline
        transform(&track)
        // The reframe renders through the compiled timeline, so touching it
        // switches the Advanced ramp off — the same rule as every other
        // timeline edit.
        let changed = track != baseline || (useRamp && !track.isEmpty)
        guard changed else { return }
        if key == nil || key != warpCoalescingKey {
            warpUndoStack.append(before)
            warpRedoStack.removeAll()
            registerSystemUndo()
        }
        warpCoalescingKey = key
        reframe = track.isEmpty ? nil : track
        if !track.isEmpty {
            useRamp = false
        }
    }

    /// A continuous gesture ended — the next edit starts a fresh undo step.
    func endWarpCoalescing() {
        warpCoalescingKey = nil
    }

    /// The UI's undo entry point. Routes through the window's UndoManager when
    /// its top action is ours, so the undo/redo pairing stays truthful for
    /// Cmd-Z, shake, and three-finger-swipe; falls back to the plain stack
    /// when the manager is absent or its top action belongs to something else.
    func requestWarpUndo() {
        if let manager = warpUndoManager, manager.canUndo,
           manager.undoActionName == Self.warpUndoActionName {
            manager.undo()
        } else {
            undoWarp()
        }
    }

    func undoWarp() {
        // Registrations on the window manager outlive this screen (Processing,
        // Result, other macOS tabs); a shake or Cmd-Z there must not silently
        // rewrite the timeline the user just rendered from.
        guard stage == .configure else { return }
        guard let snapshot = warpUndoStack.popLast() else { return }
        warpRedoStack.append(WarpEditSnapshot(warp: warp, useRamp: useRamp, reframe: reframe))
        warpCoalescingKey = nil
        warp = snapshot.warp
        useRamp = snapshot.useRamp
        reframe = snapshot.reframe
        // Inside UndoManager.undo() this lands on its redo stack. Outside one
        // (the no-manager fallback) it would corrupt the undo stack — skip.
        if let manager = warpUndoManager, manager.isUndoing {
            manager.registerUndo(withTarget: self) { $0.redoWarp() }
            manager.setActionName(Self.warpUndoActionName)
        }
    }

    func redoWarp() {
        guard stage == .configure else { return }
        guard let snapshot = warpRedoStack.popLast() else { return }
        warpUndoStack.append(WarpEditSnapshot(warp: warp, useRamp: useRamp, reframe: reframe))
        warpCoalescingKey = nil
        warp = snapshot.warp
        useRamp = snapshot.useRamp
        reframe = snapshot.reframe
        registerSystemUndo()
    }

    private func registerSystemUndo() {
        warpUndoManager?.registerUndo(withTarget: self) { $0.undoWarp() }
        warpUndoManager?.setActionName(Self.warpUndoActionName)
    }

    /// Leaving the Adjust flow — the timeline history dies with the timeline.
    private func clearWarpHistory() {
        warpUndoStack.removeAll()
        warpRedoStack.removeAll()
        warpCoalescingKey = nil
        warpUndoManager?.removeAllActions(withTarget: self)
    }

    /// A capture's starting timeline: recorded moments become ¼× (the same
    /// frame-for-frame slow motion they've always rendered as), base runs get
    /// the project speed — now read as ×-real-time, the design's semantics —
    /// and the seams inherit the project's slow-motion ramp, borrowing from the
    /// moment's side exactly as the old stitch ramp lived inside the burst.
    private func seededWarp() -> WarpTimeline {
        let stretches = blendStretches()
        let baseSpeed = Double(max(1, constantWindow))
        guard stretches.count > 1 else {
            let seconds = stretches.first?.seconds ?? currentCapture?.sourceDurationSeconds ?? 0
            return WarpTimeline(sourceSeconds: seconds, speed: baseSpeed)
        }
        var bounds = [0.0]
        var speeds: [Double] = []
        for stretch in stretches {
            bounds.append((bounds.last ?? 0) + stretch.seconds)
            speeds.append(stretch.kind == .moment ? 0.25 : baseSpeed)
        }
        var rampSeconds = effectiveBurstRamp(for: currentCapture)
        // A burst that also changed resolution could not take the shared-format
        // fast path: `prepareRampRateChange` is gated on the target being the
        // format already active, so the switch is a full `activeFormat` swap
        // and the real-time hole at the cut is several times wider (~0.6s
        // against ~0.17s on the 2026-08-13 measurements). The compiler already
        // absorbs the measured hole kinematically through `leadingGap`, so the
        // clip stays truthful either way — but a step seam over a hole that
        // size reads as a jolt, so the default ease is widened to cover it.
        // Only the default: an explicit "no ramp" (0) is still honoured, and
        // every seam stays editable.
        if rampSeconds > 0, hasMixedResolutionSegments {
            rampSeconds = max(rampSeconds, 1)
        }
        let ramp: WarpTimeline.Seam.Ramp =
            rampSeconds <= 0 ? .step
            : rampSeconds <= 0.5 ? .half
            : rampSeconds <= 1 ? .one
            : .two
        var seams: [WarpTimeline.Seam] = []
        for index in 0..<(stretches.count - 1) {
            let momentEdge = stretches[index].kind != stretches[index + 1].kind
            // Eases straddle their seams — the compiler splits the sweep at
            // the renderable floor, so the base footage brakes into the cut
            // and the burst's denser frames carry the slow tail.
            seams.append(ramp != .step && momentEdge ? WarpTimeline.Seam(ramp: ramp) : .step)
        }
        return WarpTimeline(bounds: bounds, speeds: speeds, seams: seams)
    }

    /// Whether the current project's shoot recorded its bursts at a different
    /// resolution from its base segments — which is also what tells the render
    /// path to crop and scale per segment ahead of the stitch, and the seam
    /// seeding above that its cuts are covering a wider hole.
    private var hasMixedResolutionSegments: Bool {
        guard case .liveSequence(let liveSource) = source else { return false }
        return liveSource.sequence.hasMixedSegmentResolutions
    }

    /// Bounds and step seams for a stretch list — the scaffold a legacy
    /// per-stretch recipe converts into when reopened.
    private func seededLegacyWarpBase(stretches: [BlendStretch]) -> WarpTimeline {
        var bounds = [0.0]
        var speeds: [Double] = []
        for stretch in stretches {
            bounds.append((bounds.last ?? 0) + stretch.seconds)
            speeds.append(1)
        }
        return WarpTimeline(
            bounds: bounds, speeds: speeds,
            seams: Array(repeating: .step, count: max(0, stretches.count - 1)))
    }

    /// The physically recorded regions of the warp's source axis, in order —
    /// one per segment file for a ramp-mode shoot, one for everything else.
    /// Spans AND densities are the probed truth where it exists: the schedule
    /// counts real frames, so a burst that delivered half its nominal rate
    /// must compile at what it wrote — otherwise the blend truncates at
    /// end-of-file and the reframe bake mis-times every frame after it.
    private func warpSourceRegions() -> [WarpCompiler.SourceRegion] {
        let probed = currentCapture?.sourceSegmentSeconds
        let probedFPS = currentCapture?.sourceSegmentFPS
        switch source {
        case .liveSequence(let live) where live.sequence.mode == .ramp && !live.sequence.segments.isEmpty:
            let ordered = live.sequence.segments.sorted { $0.index < $1.index }
            var regions: [WarpCompiler.SourceRegion] = []
            for (position, segment) in ordered.enumerated() {
                let span = max(0, probed?[segment.fileName]
                    ?? segment.recordedDuration
                    ?? (segment.relativeEnd - segment.relativeStart))
                // Real time the camera lost switching formats before this
                // segment.
                var gap = 0.0
                if position > 0 {
                    let prev = ordered[position - 1]
                    let prevSpan = probed?[prev.fileName]
                        ?? prev.recordedDuration
                        ?? max(0, prev.relativeEnd - prev.relativeStart)
                    if let start = segment.recordedStart, let prevStart = prev.recordedStart {
                        // Honest sidecars: both boundaries carry the writer's
                        // actual first-frame stamps and the files' own probed
                        // lengths close the intervals — the gap is measured,
                        // not estimated, so no bias term. The clamp only
                        // guards against clock weirdness.
                        let measured = start - prevStart - (prev.recordedDuration ?? prevSpan)
                        gap = measured > 0.02 ? min(2.0, measured) : 0
                    } else {
                        // Pre-honest sidecars: the start/end stamps bracket
                        // the truth from opposite directions (writer start-up
                        // latency vs stopwatch overshoot) — pixel-measured
                        // gaps on a real shoot (~0.6s at both boundaries) sit
                        // near their midpoint. Bias positive: overestimating
                        // reads as one slightly-calmer frame, underestimating
                        // as a visible jump.
                        let startBased = segment.relativeStart - prev.relativeStart - prevSpan
                        let endBased = segment.relativeStart - prev.relativeEnd
                        let midpoint = (max(0, startBased) + max(0, endBased)) / 2
                        gap = midpoint > 0.05 ? min(2.0, midpoint + 0.25) : 0
                    }
                }
                regions.append(WarpCompiler.SourceRegion(
                    span: span,
                    fps: probedFPS?[segment.fileName]
                        ?? Double(segment.frameRate > 0 ? segment.frameRate : max(1, live.sequence.baseFrameRate)),
                    leadingGap: gap))
            }
            return regions.filter { $0.span > 0 }
        case .liveSequence(let live):
            let whole = live.sequence.segments.first
            var span: Double = currentCapture?.sourceDurationSeconds ?? 0
            if let whole {
                span = probed?[whole.fileName]
                    ?? whole.recordedDuration
                    ?? max(0, whole.relativeEnd - whole.relativeStart)
            }
            guard span > 0 else { return [] }
            return [WarpCompiler.SourceRegion(
                span: span,
                fps: whole.flatMap { probedFPS?[$0.fileName] } ?? Double(max(1, live.sequence.baseFrameRate)))]
        case .video:
            guard let capture = currentCapture, let seconds = capture.sourceDurationSeconds,
                  seconds > 0 else { return [] }
            return [WarpCompiler.SourceRegion(span: seconds, fps: capture.sourceFPS ?? 30)]
        default:
            return []
        }
    }

    /// The densest playback the footage under a stretch can honour: the
    /// MINIMUM fps across the source regions its span crosses — a stretch
    /// straddling a seam can only slow as far as its thinnest footage. Drives
    /// the Adjust chips' fps gating; falls back to the output rate (which
    /// gates like base footage) when no regions resolve.
    func warpStretchFPS(_ index: Int) -> Double {
        let warp = activeWarp()
        guard index >= 0, warp.bounds.indices.contains(index + 1) else {
            return Double(max(1, outputFPS))
        }
        let start = warp.bounds[index]
        let end = warp.bounds[index + 1]
        var cursor = 0.0
        var minFPS: Double?
        for region in warpSourceRegions() {
            let regionStart = cursor
            cursor += region.span
            guard cursor > start + 0.0005, regionStart < end - 0.0005 else { continue }
            minFPS = min(minFPS ?? region.fps, region.fps)
        }
        return minFPS ?? Double(max(1, outputFPS))
    }

    /// The file and in-file time behind a point on the warp's source axis, for
    /// the playhead's keyframe preview.
    func warpFrameLocation(at time: Double) -> (url: URL, seconds: Double)? {
        switch source {
        case .liveSequence(let live) where live.sequence.mode == .ramp && !live.sequence.segments.isEmpty:
            let ordered = live.sequence.segments.sorted { $0.index < $1.index }
            let probed = currentCapture?.sourceSegmentSeconds
            var cursor = 0.0
            for (position, segment) in ordered.enumerated() {
                let span = max(0, probed?[segment.fileName] ?? (segment.relativeEnd - segment.relativeStart))
                if time <= cursor + span || position == ordered.count - 1 {
                    guard let url = live.resolvedByOriginalName[segment.fileName]
                        ?? live.segmentURLs.first else { return nil }
                    return (url, min(max(0, time - cursor), max(0, span - 0.05)))
                }
                cursor += span
            }
            return nil
        case .liveSequence(let live):
            guard let url = live.primaryVideoURL else { return nil }
            return (url, max(0, time))
        case .video(let url):
            return (url, max(0, time))
        default:
            return nil
        }
    }

    /// Head/tail trim as a window on the warp axis — plain videos only, same
    /// as the legacy render path.
    private func warpActiveRange(total: Double) -> (start: Double, end: Double) {
        if case .video = source, trimVideoEnds {
            let trim = max(0, trimHeadTailSeconds)
            if trim * 2 < total {
                return (trim, total - trim)
            }
        }
        return (0, total)
    }

    /// Everything a compiled warp depends on. The estimate card, its phrase
    /// and the CTA all ask per body evaluation — and every @Published change
    /// re-evaluates the body — so compiling a long clip's whole per-frame
    /// schedule each time made canvas/chip taps visibly laggy on device.
    private struct CompiledWarpMemo {
        var timeline: WarpTimeline
        var outputFPS: Int
        var trim: Double
        var captureID: UUID?
        var codec: OutputCodec?
        /// Region spans and densities follow the async source probe, not just
        /// the capture.
        var sourceSeconds: Double?
        var segmentSeconds: [String: Double]?
        var segmentFPS: [String: Double]?
        var value: WarpCompiler.Compiled?
    }
    private var compiledWarpMemo: CompiledWarpMemo?

    /// The current timeline compiled into per-file window schedules — what the
    /// render will do and what the estimate reports. nil when the Advanced
    /// ramp is on (it wins over the timeline) or the source has no known shape.
    /// Memoized on its inputs; the memo self-invalidates by comparison.
    func compiledWarp() -> WarpCompiler.Compiled? {
        guard source?.isVideo == true, !useRamp else { return nil }
        let timeline = activeWarp()
        let trim = trimVideoEnds ? max(0, trimHeadTailSeconds) : 0
        if let memo = compiledWarpMemo,
           memo.timeline == timeline,
           memo.outputFPS == outputFPS,
           memo.trim == trim,
           memo.captureID == currentCaptureID,
           memo.codec == blendSourceCodec,
           memo.sourceSeconds == currentCapture?.sourceDurationSeconds,
           memo.segmentSeconds == currentCapture?.sourceSegmentSeconds,
           memo.segmentFPS == currentCapture?.sourceSegmentFPS {
            return memo.value
        }
        let regions = warpSourceRegions()
        let range = warpActiveRange(total: timeline.sourceSeconds)
        let compiled: WarpCompiler.Compiled? = regions.isEmpty ? nil : WarpCompiler.compile(
            timeline, regions: regions, outputFPS: outputFPS,
            activeStart: range.start, activeEnd: range.end)
        compiledWarpMemo = CompiledWarpMemo(
            timeline: timeline, outputFPS: outputFPS, trim: trim,
            captureID: currentCaptureID, codec: blendSourceCodec,
            sourceSeconds: currentCapture?.sourceDurationSeconds,
            segmentSeconds: currentCapture?.sourceSegmentSeconds,
            segmentFPS: currentCapture?.sourceSegmentFPS,
            value: compiled)
        return compiled
    }

    /// A different speed worth trying next, for the Result screen's suggestion.
    func suggestedAlternateSpeed() -> Int? {
        guard source?.isVideo == true, !useRamp else { return nil }
        let current = constantWindow
        let candidate = current >= 50 ? current / 2 : current * 2
        let clamped = min(max(candidate, SpeedMath.range.lowerBound), SpeedMath.range.upperBound)
        return clamped == current ? nil : clamped
    }

    // MARK: - Projects & versions

    func versionNumber(for blend: BlendProject) -> Int {
        let siblings = blends
            .filter { $0.captureID == blend.captureID }
            .sorted { $0.createdAt < $1.createdAt }
        return (siblings.firstIndex { $0.id == blend.id } ?? max(0, siblings.count - 1)) + 1
    }

    func renameProject(_ capture: CaptureProject, to newName: String) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        captures[index].name = trimmed.isEmpty ? nil : trimmed
        try? persistLibrary()
    }

    /// Applies what the user accepted from an on-device scene analysis. One write, because a
    /// rename and a tag change arriving separately would leave the manifest briefly disagreeing
    /// with the sheet the user just confirmed.
    func applySceneMetadata(_ metadata: SceneMetadata, to capture: CaptureProject) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        let trimmed = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            captures[index].name = trimmed
        }
        captures[index].sceneTags = metadata.tags.isEmpty ? nil : metadata.tags
        captures[index].sceneElements = metadata.elements.isEmpty ? nil : metadata.elements
        // Confirmed by a person now, whatever put them there first — so the "tagged automatically"
        // marker comes off the card.
        captures[index].sceneTaggedAutomatically = nil
        try? persistLibrary()
    }

    // MARK: - Automatic tagging

    /// Tags a freshly created project in the background, when the active model is one that costs
    /// nothing to run.
    ///
    /// Only ever the built-in classifier. A VLM is seconds of compute and a couple of gigabytes of
    /// resident weights per capture — firing that unasked, on the device the user is still shooting
    /// with, is not a background nicety. So the MLX path stays where it was: a row the user taps.
    ///
    /// Silent by design and forgiving by design: no sheet, no toast, and any failure is dropped.
    /// A project with no tags is the state it was already in.
    func autoTagIfEnabled(_ capture: CaptureProject) {
        guard ModelManager.shared.activeModel?.isBuiltIn == true else { return }
        guard let source = sceneSource(for: capture) else { return }

        Task { [weak self] in
            guard let sample = try? await SceneFrameSampler.sample(source) else { return }
            defer { SceneFrameSampler.cleanUp(sample) }
            // One frame, not the sampler's usual three or five: this runs unasked while a capture
            // has just finished writing, and the marginal tag from frames two and three is not
            // worth the contention.
            guard let frame = sample.frameURLs.first else { return }

            let light = SceneContext.light(
                from: capture.createdAt, duration: capture.sourceDurationSeconds ?? 0)
            guard let result = try? await VisionSceneAnalyzer.shared.analyze(
                SceneAnalysisRequest(imageURLs: [frame], place: nil, light: light))
            else { return }

            await self?.applyAutomaticTags(result, to: capture.id)
        }
    }

    /// Writes what the background pass found — tags only, and only onto a project nobody has
    /// tagged in the meantime.
    private func applyAutomaticTags(_ result: SceneAnalysisResult, to captureID: UUID) {
        guard let index = captures.firstIndex(where: { $0.id == captureID }) else { return }
        // A run the user started while this was in flight has the better answer; don't overwrite it.
        guard captures[index].sceneTags == nil else { return }
        guard !result.subjectTags.isEmpty || !result.elements.isEmpty else { return }

        captures[index].sceneTags = result.subjectTags.isEmpty ? nil : result.subjectTags
        captures[index].sceneElements = result.elements.isEmpty ? nil : result.elements
        // The name is untouched on purpose — Vision writes none, and a project silently renaming
        // itself after a shoot would be alarming even if it could.
        captures[index].sceneTaggedAutomatically = true
        try? persistLibrary()
    }

    /// Which frames stand for a capture, by mode: a Photo project *is* one asset, an interval shoot
    /// is summarised from its own stills, and a recording is sampled from the movie.
    func sceneSource(for capture: CaptureProject) -> SceneFrameSampler.Source? {
        if capture.isPhotoCapture {
            guard let url = heroImageURL(for: capture) else { return nil }
            return .photo(url)
        }
        if capture.kind == .photos {
            let frames = sourceFrameURLs(for: capture)
            return frames.isEmpty ? nil : .stills(frames)
        }
        guard let url = mediaURL(for: capture) else { return nil }
        return .video(url)
    }

    // MARK: - Burst ramps

    /// What a render will actually ask for on this project: its own setting
    /// when it has one, otherwise the app default, otherwise no ramp at all.
    func effectiveBurstRamp(for capture: CaptureProject?) -> Double {
        let value = capture?.burstRampDuration ?? burstRampDefault ?? 0
        return min(max(0, value), BurstRamp.maxDuration)
    }

    /// Stores a project's ramp. `nil` puts it back on the app default; `0` is
    /// an explicit "hard cuts on this one". With "remember last" on, an
    /// explicit choice also becomes the new app default.
    func setBurstRamp(_ seconds: Double?, for capture: CaptureProject) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        let normalized = seconds.map { min(max(0, $0), BurstRamp.maxDuration) }
        if captures[index].burstRampDuration != normalized {
            captures[index].burstRampDuration = normalized
            try? persistLibrary()
        }
        // "Use default" is the absence of a choice — there is nothing to
        // remember, and writing it back would erase the remembered value.
        if burstRampRememberLast, let normalized {
            burstRampDefault = normalized > 0 ? normalized : nil
        }
    }

    /// The burst material in a video project and what the current ramp setting
    /// does to it. nil when the project has no burst clips to ramp — the
    /// control has nothing to act on and the views hide it.
    ///
    /// Touches the filesystem (the sequence sidecar), so call it from a `task`
    /// rather than a view body.
    struct BurstRampInfo: Equatable {
        /// Number of burst clips in the project.
        var clipCount: Int
        /// The shortest burst clip's length in the finished timeline — the one
        /// that decides whether the ramp has to be capped.
        var shortestOutputDuration: Double
        var slowFactor: Double
        /// What the project's current setting resolves to.
        var requestedRamp: Double
        /// What that clip can actually carry; 0 when it is too short for any.
        var appliedRamp: Double

        var isCapped: Bool { requestedRamp > 0 && appliedRamp < requestedRamp - 0.001 }
    }

    func burstRampInfo(for capture: CaptureProject) -> BurstRampInfo? {
        guard capture.kind == .video else { return nil }
        // The current capture's sequence is already in memory — and it is the
        // one the ruler and the estimate are working from, so the three can
        // never disagree. The disk sidecar covers everything else.
        let loaded: LiveCaptureSequence?
        if capture.id == currentCaptureID, case .liveSequence(let live)? = source {
            loaded = live.sequence
        } else {
            loaded = liveCaptureSequence(for: capture)
        }
        guard let sequence = loaded else { return nil }
        let fps = Double(outputFPS)
        guard fps > 0 else { return nil }

        // How long each moment runs in the stitched timeline at its current
        // ruler speed, and how far from real time it is there. At window w, a
        // burst shot at `rate` fps lands rate/(w·fps) times slow — at the
        // default w = 1, a 2s burst shot at 120 fps lands as 2 × (120/25)
        // seconds of footage playing 4.8× slow.
        let stretches = StretchBuilder.stretches(for: sequence)
        var clips: [(duration: Double, slowFactor: Double)] = []
        for stretch in stretches where stretch.kind == .moment {
            let slowFactor = Double(stretch.fps) / fps
            clips.append((stretch.seconds * slowFactor, slowFactor))
        }
        // A moment that isn't actually slower than the output rate — sped back
        // up to real time on the ruler, say — has nothing to ease into.
        clips = clips.filter { $0.slowFactor > 1 && $0.duration > 0 }
        guard let shortest = clips.min(by: { $0.duration < $1.duration }) else { return nil }

        let requested = effectiveBurstRamp(for: capture)
        return BurstRampInfo(
            clipCount: clips.count,
            shortestOutputDuration: shortest.duration,
            slowFactor: shortest.slowFactor,
            requestedRamp: requested,
            appliedRamp: BurstRamp.appliedRamp(
                requested: requested,
                burstOutputDuration: shortest.duration,
                slowFactor: shortest.slowFactor)
        )
    }

    /// The recorded shape of a video shoot — segments, markers, ramp intervals
    /// — without resolving any of its media files. nil for imports and for
    /// captures made before sequences were written.
    private func liveCaptureSequence(for capture: CaptureProject) -> LiveCaptureSequence? {
        let metadataURL = captureFolderURL(for: capture.id)
            .appendingPathComponent("source/sequence.json")
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LiveCaptureSequence.self, from: data)
    }

    /// The burst make-up of a video shoot, for its Projects card: how many
    /// segments were recorded above the base rate, and at what rate(s). A
    /// zero count is a real answer — an import, a burstless shoot, or a
    /// marker-mode capture (one file at the base rate; its marked intervals
    /// are intent, not burst clips).
    struct BurstClipSummary: Equatable {
        var count: Int
        var minFPS: Int
        var maxFPS: Int
        /// The resolution the bursts recorded at, when it differs from the
        /// shoot's base — nil for a shoot that held one resolution throughout,
        /// which is every shoot before per-segment burst resolution.
        var burstResolutionLabel: String?

        /// "2 bursts at 120 fps" / "1 burst at 120–240 fps" / "2 bursts at
        /// 120 fps · 4K"; nil at zero so the card's source line can end cleanly
        /// at its clip count.
        var label: String? {
            guard count > 0 else { return nil }
            let rate = minFPS == maxFPS ? "\(maxFPS) fps" : "\(minFPS)–\(maxFPS) fps"
            let head = count == 1 ? "1 burst at \(rate)" : "\(count) bursts at \(rate)"
            return burstResolutionLabel.map { "\(head) · \($0)" } ?? head
        }
    }

    /// Summaries already read this session, keyed by capture. A sequence
    /// sidecar is written once at capture end and never edited afterwards, so
    /// entries can live as long as the app runs — including the "no sidecar"
    /// zero, which is what stops scrolling from re-probing every import.
    private var burstSummaryCache: [UUID: BurstClipSummary] = [:]

    /// The Projects card's burst read — the sidecar decode runs off the main
    /// actor like every other per-card disk walk. Returns nil only when the
    /// read was cancelled (the row scrolled away); callers must keep whatever
    /// they were showing rather than reading nil as "no bursts".
    func burstClipSummary(for capture: CaptureProject) async -> BurstClipSummary? {
        guard capture.kind == .video else { return BurstClipSummary(count: 0, minFPS: 0, maxFPS: 0) }
        if let known = burstSummaryCache[capture.id] { return known }
        let metadataURL = captureFolderURL(for: capture.id)
            .appendingPathComponent("source/sequence.json")
        let summary = await MediaWorkQueue.shared.run { () -> BurstClipSummary in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: metadataURL),
                  let sequence = try? decoder.decode(LiveCaptureSequence.self, from: data) else {
                return BurstClipSummary(count: 0, minFPS: 0, maxFPS: 0)
            }
            let bursts = sequence.segments.filter { $0.frameRate > sequence.baseFrameRate }
            let rates = bursts.map(\.frameRate)
            // Named only when the bursts really recorded somewhere else — a
            // shoot that held one resolution throughout has nothing to split.
            let burstSizes = Set(bursts.map { sequence.resolution(of: $0) })
            let resolutionLabel: String? = {
                guard burstSizes.count == 1, let size = burstSizes.first,
                      size != sequence.lockedResolution else { return nil }
                return CameraController.CaptureResolution(
                    width: size.width, height: size.height).label
            }()
            return BurstClipSummary(
                count: rates.count,
                minFPS: rates.min() ?? 0,
                maxFPS: rates.max() ?? 0,
                burstResolutionLabel: resolutionLabel)
        }
        guard let summary else { return nil }
        burstSummaryCache[capture.id] = summary
        return summary
    }

    // MARK: - Storage

    struct LibraryStorage: Equatable {
        var originalsBytes: Int64 = 0
        var versionsBytes: Int64 = 0
        var cacheBytes: Int64 = 0

        var totalBytes: Int64 { originalsBytes + versionsBytes + cacheBytes }
    }

    /// Per-project folder sizes already walked this session, keyed by capture.
    /// A project's size only changes when its files do, and every one of those
    /// paths persists the library — so `persistLibrary` drops this and the next
    /// card that appears re-walks. Without it, every reappearance of a row in
    /// Projects (or the whole of Settings › Large originals) re-enumerated a
    /// folder that can hold a hundred 19 MB DNGs.
    private var projectStorageBytes: [UUID: Int64] = [:]

    /// Walks the whole library — every project folder and every cache item — so
    /// it goes through the bounded queue and gives up when the screen that asked
    /// for it closes. Returns nil in that case.
    func computeLibraryStorage() async -> LibraryStorage? {
        let root = projectsRootURL
        let temporary = FileManager.default.temporaryDirectory
        return await MediaWorkQueue.shared.run {
            var storage = LibraryStorage()
            let fileManager = FileManager.default
            if let folders = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
                for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    storage.originalsBytes += Self.directorySize(folder.appendingPathComponent("source"))
                    storage.versionsBytes += Self.directorySize(folder.appendingPathComponent("blends"))
                }
            }
            if let items = try? fileManager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) {
                for item in items where Self.isCacheItem(item) {
                    storage.cacheBytes += Self.directorySize(item)
                }
            }
            return storage
        }
    }

    /// Bytes on disk for one project. Returns nil when the walk was cancelled
    /// (the row scrolled away, the screen closed) — callers must keep whatever
    /// they were showing rather than reading nil as "no files".
    func storageBytes(for capture: CaptureProject) async -> Int64? {
        if let known = projectStorageBytes[capture.id] { return known }
        let folder = captureFolderURL(for: capture.id)
        guard let bytes = await MediaWorkQueue.shared.run({ Self.directorySize(folder) }) else {
            return nil
        }
        projectStorageBytes[capture.id] = bytes
        return bytes
    }

    /// Deletes reproducible temp files (imports, live-capture staging, blend
    /// scratch). Returns the number of bytes freed.
    @discardableResult
    func clearCache() async -> Int64 {
        let temporary = FileManager.default.temporaryDirectory
        return await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var freed: Int64 = 0
            guard let items = try? fileManager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) else {
                return freed
            }
            for item in items where Self.isCacheItem(item) {
                let size = Self.directorySize(item)
                do {
                    try fileManager.removeItem(at: item)
                    freed += size
                } catch {
                    continue
                }
            }
            return freed
        }.value
    }

    nonisolated private static func isCacheItem(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("letslapse") || name.hasPrefix(".letslapse")
            || name.hasPrefix("live-capture") || name.hasPrefix("picked-")
            || name.hasPrefix("import-")
    }

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Progress accounting

    /// Returns every piece of run-progress state to idle. Start paths call
    /// this then stamp `processingStartedAt`; flow teardown leaves it nil.
    private func resetProcessingProgress() {
        progress = 0
        processingPhase = .preparing
        processingStartedAt = nil
        processingETADate = nil
        processingFramesDone = nil
        processingFramesTotal = nil
        activeProgressPlan = nil
        tailPhaseStartedAt = nil
    }

    /// Establishes the band layout for the run and primes the frame counters.
    private func beginProgressPlan(_ plan: BlendProgressPlan) {
        activeProgressPlan = plan
        processingFramesTotal = plan.totalFrames
        processingFramesDone = 0
    }

    /// The single sink for every engine's per-clip fraction: maps it into the
    /// clip's band of the one global bar. Monotonic — a straggling callback
    /// from an earlier clip can't drag the bar backwards.
    private func reportClipProgress(_ clipIndex: Int, fraction: Double) {
        guard stage == .processing else { return }
        guard let plan = activeProgressPlan else {
            progress = max(progress, min(max(fraction, 0), 1))
            return
        }
        progress = max(progress, plan.globalFraction(clip: clipIndex, localFraction: fraction))
        processingFramesDone = max(
            processingFramesDone ?? 0,
            plan.framesDone(clip: clipIndex, localFraction: fraction))
        updateBlendETA(plan)
    }

    /// Maps a tail-stage export's 0→1 (stitch, grade bake) into its band.
    private func reportTailProgress(band: ClosedRange<Double>, fraction: Double) {
        guard stage == .processing else { return }
        let clamped = min(max(fraction, 0), 1)
        progress = max(progress, band.lowerBound + (band.upperBound - band.lowerBound) * clamped)
        updateTailETA(band)
    }

    /// Frames-based estimate while blending: the run's pace so far over the
    /// frames still to read, plus a couple of seconds for each tail stage.
    /// The padding keeps "Almost done" honest — it can't fire while a stitch
    /// or grade pass hasn't even started.
    private func updateBlendETA(_ plan: BlendProgressPlan) {
        guard let started = processingStartedAt,
              let done = processingFramesDone, done >= 20,
              done < plan.totalFrames else { return }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed >= 2 else { return }
        let remaining = elapsed / Double(done) * Double(plan.totalFrames - done)
            + 2 * Double(plan.tailStageCount)
        processingETADate = Date().addingTimeInterval(remaining)
    }

    /// Stage-local estimate for a tail export from how much of its band has
    /// filled. Below 5% there's no pace to extrapolate — the view shows the
    /// phase label instead of a made-up countdown.
    private func updateTailETA(_ band: ClosedRange<Double>) {
        guard let started = tailPhaseStartedAt else { return }
        let width = band.upperBound - band.lowerBound
        guard width > 0 else { return }
        let filled = (progress - band.lowerBound) / width
        guard filled >= 0.05 else {
            processingETADate = nil
            return
        }
        let elapsed = Date().timeIntervalSince(started)
        var remaining = elapsed / filled * (1 - filled)
        var pendingStages = 1 // the save itself
        if let gradeBand = activeProgressPlan?.gradeBand, band.upperBound <= gradeBand.lowerBound {
            pendingStages += 1
        }
        remaining += 2 * Double(pendingStages)
        processingETADate = Date().addingTimeInterval(remaining)
    }

    /// The output format for the next Create run: the Settings default unless
    /// the Create button's menu overrode it for this tap.
    nonisolated static let blendFormatDefaultsKey = "blend.outputFormat"
    private var blendProfileOverride: VideoEncodePolicy.Profile?
    var defaultBlendProfile: VideoEncodePolicy.Profile {
        UserDefaults.standard.string(forKey: Self.blendFormatDefaultsKey) == "hevc10"
            ? .hevcMain10 : .h264High8Bit
    }

    func startProcessing(blendProfile: VideoEncodePolicy.Profile? = nil) {
        guard let source, let captureID = currentCaptureID else { return }
        blendProfileOverride = blendProfile
        stage = .processing
        statusMessage = "Preparing job..."
        jobFolderURL = nil
        jobLogLines = []
        resultVideoURL = nil
        resultImage = nil
        resultImageURL = nil
        resultSummary = nil
        resultBlendID = nil
        errorMessage = nil
        resetProcessingProgress()
        processingStartedAt = Date()
        let ramp = self.ramp
        let fps = Double(outputFPS)
        let linear = linearLight
        let trim = source.isVideo && trimVideoEnds ? max(0, trimHeadTailSeconds) : 0
        let photoDepth = photoBlendDepth
        let excluded = excludedFrameIndices
        let parameters = currentBlendParameters()
        // The project's colour grade is baked into whatever this run writes:
        // stills are graded frame by frame on their way into the blend, a movie
        // gets one composition pass over the finished clip. The capture's own
        // files are never touched.
        let grade = currentCapture.map { photoGrade(for: $0) } ?? .identity
        // Resolved once, here: the project's own ramp when it has one, else the
        // app default, else none. Only the legacy (Advanced-ramp) path stitches
        // with it — the warp's seams carry their own eases inside the schedules.
        let burstRamp = effectiveBurstRamp(for: currentCapture)
        // The warp timeline compiled into per-file window schedules; nil =
        // legacy path (Advanced ramp on, or a source with no known shape).
        let warpCompiled = compiledWarp()
        // Whether the run ends with the grade-bake export below — the progress
        // plan reserves a band for it so the bar doesn't sit full while it runs.
        let willBakeGrade = source.isVideo && !grade.isIdentity
        // The export resolution cap, resolved with the other job inputs. The
        // reframe pass scales to it directly; without a reframe the canvas
        // pass carries it — which is why the canvas pass also runs for a
        // matching canvas when a cap is set (scale-only).
        let exportEdge = source.isVideo ? exportShortEdge : nil
        // The Adjust canvas, resolved before the job starts so a selection
        // change mid-render can't retarget it. nil = the clip keeps its shape.
        let cropIsReal = blendCanvasNeedsCrop()
        let cropCanvas = source.isVideo && (cropIsReal || exportEdge != nil)
            ? effectiveBlendCanvas() : nil
        // Where that crop sits along the free axis, resolved with the canvas
        // itself. The reframe path doesn't read it — its wide framings already
        // carry the offset as their centre.
        let cropOffset = blendCanvasOffset
        // The punch-in reframe, resolved the same way. It needs the compiled
        // warp's frame map, so the legacy (Advanced-ramp) path renders without
        // it. When it runs it subsumes the canvas crop — its render size IS
        // the canvas shape.
        let reframeTrack: ReframeTrack? = {
            guard source.isVideo, let track = reframe, !track.isEmpty,
                  warpCompiled != nil else { return nil }
            return track
        }()
        let reframeAspect = effectiveBlendCanvas().aspect
        let reframeSourceSize = sourceDisplaySize()
        let reframeFrameTimes = warpCompiled?.frameSourceTimes.flatMap { $0 } ?? []
        // Kept per region as well as flattened: a mixed-resolution ramp shoot
        // hands each segment its own slice so the punch can be cropped from
        // that segment at its own resolution, before the stitch normalises.
        let reframeFrameTimesBySegment = warpCompiled?.frameSourceTimes ?? []
        // Only a shoot whose segments disagree about resolution needs the
        // per-segment path; everything else keeps today's tail passes exactly.
        let normalization: SegmentNormalization? = {
            guard case .liveSequence(let liveSource) = source,
                  liveSource.sequence.hasMixedSegmentResolutions,
                  let baseSize = reframeSourceSize else { return nil }
            let canvas = effectiveBlendCanvas()
            // Derived from the BASE resolution: the finished clip is the size
            // it always was, and the burst's extra pixels are spent on the crop
            // rather than on the file.
            let keptSize: CGSize? = reframeTrack != nil
                ? ReframeVideoCropper.renderSize(displaySize: baseSize, aspect: reframeAspect)
                : (VideoCanvasCropper.cropSize(displaySize: baseSize, canvas: canvas) ?? baseSize)
            guard let keptSize else { return nil }
            let renderSize = exportEdge
                .flatMap { ReframeVideoCropper.scaledDown(keptSize, shortEdge: $0) } ?? keptSize
            return SegmentNormalization(
                renderSize: renderSize,
                canvas: canvas,
                canvasOffset: cropOffset,
                reframe: reframeTrack.flatMap { track in
                    guard !reframeFrameTimesBySegment.isEmpty else { return nil }
                    return SegmentNormalization.Reframe(
                        track: track,
                        aspect: reframeAspect,
                        sourceSize: baseSize,
                        frameTimesBySegment: reframeFrameTimesBySegment,
                        outputFPS: outputFPS)
                })
        }()
        // Resolved with the other job inputs — the pass must use the fps the
        // schedules were compiled at, not whatever the user opens mid-render.
        let reframeOutputFPS = outputFPS
        // The reframe, the crop and the grade are all tail passes over the
        // finished clip; the plan reserves its tail band when any will run.
        let hasTailPass = willBakeGrade || cropCanvas != nil || reframeTrack != nil
        blendTask = Task { [weak self] in
            do {
                guard let self else { return }
                var output: ProcessingOutput
                switch source {
                case .video(let url):
                    self.beginProgressPlan(.make(
                        clipFrames: [Int((self.estimatedInputFrames ?? 1).rounded())],
                        hasStitch: false, hasGrade: hasTailPass))
                    self.processingPhase = .blending(clip: 1, of: 1)
                    output = try await self.blendVideo(
                        url: url, ramp: ramp, fps: fps, linear: linear,
                        trimHeadTailSeconds: trim,
                        customWindows: warpCompiled?.schedules.first)
                case .liveSequence(let liveSource):
                    output = try await self.blendLiveSequence(
                        liveSource, ramp: ramp, fps: fps, linear: linear, burstRamp: burstRamp,
                        willBakeGrade: hasTailPass, warpSchedules: warpCompiled?.schedules,
                        normalization: normalization)
                case .photos(let urls):
                    // Tail-frame review drops the flagged shaky frames from the
                    // blend — they stay on disk, just out of this render.
                    let keptOrders = urls.indices.filter { !excluded.contains($0) }
                    let filteredURLs = excluded.isEmpty
                        ? urls
                        : keptOrders.map { urls[$0] }
                    // A ramped shoot's real capture clock, if it recorded one.
                    // Picked by capture order so a tail-frame exclusion keeps
                    // the surviving frames on their true moments; a sidecar
                    // that doesn't describe this shoot frame-for-frame is
                    // ignored rather than guessed at.
                    let frameTimes: [Double]? = FrameTimestamps
                        .load(besideFrames: urls)
                        .flatMap { stamps in
                            stamps.entries.count == urls.count
                                ? stamps.elapsedSeconds(forOrders: keptOrders)
                                : nil
                        }
                    // Stills bake their grade frame by frame inside the blend,
                    // so no separate grade band exists on this path.
                    self.beginProgressPlan(.make(
                        clipFrames: [filteredURLs.count], hasStitch: false, hasGrade: false))
                    self.processingPhase = .blending(clip: 1, of: 1)
                    if photoDepth >= filteredURLs.count {
                        // The blend depth spans every still, so fold them all
                        // into one frame: the classic single long exposure.
                        output = try await self.stackPhotos(
                            urls: filteredURLs, linear: linear, grade: grade)
                    } else {
                        // A depth of 1 gives a straight timelapse; larger
                        // depths blend consecutive stills into each frame for
                        // motion blur. Output is a video sequence.
                        output = try await self.blendPhotosSequence(
                            urls: filteredURLs, ramp: .constant(photoDepth), fps: fps,
                            linear: linear, grade: grade, frameTimes: frameTimes,
                            profile: self.blendProfileOverride ?? self.defaultBlendProfile)
                    }
                }
                // Tail passes share the plan's reserved band. The geometry
                // passes carry the grade themselves now, so whichever pass
                // runs owns the whole band — the old head/tail split paid for
                // a separate grade generation that no longer exists.
                let tailBand = self.activeProgressPlan?.gradeBand
                // Set when a geometry pass baked the grade, so the standalone
                // grade pass (one more full re-encode) stands down.
                var gradeBaked = false
                // The punch-in reframe bakes the animated crop into the
                // finished clip — per-frame, at the source moments the
                // compiled schedule says each output frame shows. It renders
                // at the canvas shape, so the static canvas crop below is
                // skipped when this runs — which makes this the last geometry
                // pass whenever it runs, and therefore the grade's ride.
                if let reframeTrack, output.kind == .video, !output.geometryBaked,
                   let reframeSourceSize, !reframeFrameTimes.isEmpty {
                    self.statusMessage = grade.isIdentity
                        ? "Baking the punch-in reframe..."
                        : "Baking the punch-in reframe and \(grade.preset.displayName) grade..."
                    self.processingPhase = .grading
                    self.tailPhaseStartedAt = Date()
                    self.processingETADate = nil
                    let reframeBand = tailBand
                    let unreframed = output.url
                    let reframed = try await ReframeVideoCropper.croppedCopy(
                        of: unreframed,
                        track: reframeTrack,
                        aspect: reframeAspect,
                        sourceSize: reframeSourceSize,
                        frameSourceTimes: reframeFrameTimes,
                        outputFPS: reframeOutputFPS,
                        grade: grade,
                        exportShortEdge: exportEdge
                    ) { fraction in
                        Task { @MainActor [weak self] in
                            guard let self, let reframeBand else { return }
                            self.reportTailProgress(band: reframeBand, fraction: fraction)
                        }
                    }
                    if let reframeBand {
                        self.reportTailProgress(band: reframeBand, fraction: 1)
                    }
                    // The summary already carries the intermediate's
                    // resolution — keep it truthful about the kept pixels.
                    if let oldWidth = output.width, let oldHeight = output.height {
                        output.summary = output.summary.replacingOccurrences(
                            of: "\(oldWidth)×\(oldHeight)",
                            with: "\(Int(reframed.renderSize.width))×\(Int(reframed.renderSize.height))")
                    }
                    output.url = reframed.url
                    output.width = Int(reframed.renderSize.width)
                    output.height = Int(reframed.renderSize.height)
                    output.summary += " · punch-in reframe"
                    if !grade.isIdentity {
                        gradeBaked = true
                        output.summary += " · \(grade.preset.displayName) grade baked in"
                    }
                    if unreframed.deletingLastPathComponent().standardizedFileURL
                        == FileManager.default.temporaryDirectory.standardizedFileURL {
                        try? FileManager.default.removeItem(at: unreframed)
                    }
                }
                // The Adjust canvas crops the finished clip rather than the
                // source — one short composition pass over a few seconds of
                // output, whichever engine produced it. The grade rides this
                // pass (it is the last geometry pass when it runs), so the
                // kept pixels are cropped, graded and encoded exactly once.
                if let cropCanvas, output.kind == .video, reframeTrack == nil,
                   !output.geometryBaked {
                    self.statusMessage = grade.isIdentity
                        ? "Cropping to \(cropCanvas.rawValue)..."
                        : "Cropping to \(cropCanvas.rawValue) and baking the \(grade.preset.displayName) grade..."
                    self.processingPhase = .grading
                    self.tailPhaseStartedAt = Date()
                    self.processingETADate = nil
                    let cropBand = tailBand
                    let uncropped = output.url
                    let cropped = try await VideoCanvasCropper.croppedCopy(
                        of: uncropped, canvas: cropCanvas, offset: cropOffset,
                        shortEdge: exportEdge, grade: grade
                    ) { fraction in
                        Task { @MainActor [weak self] in
                            guard let self, let cropBand else { return }
                            self.reportTailProgress(band: cropBand, fraction: fraction)
                        }
                    }
                    if let cropBand {
                        self.reportTailProgress(band: cropBand, fraction: 1)
                    }
                    if let renderSize = cropped.renderSize {
                        if let oldWidth = output.width, let oldHeight = output.height {
                            output.summary = output.summary.replacingOccurrences(
                                of: "\(oldWidth)×\(oldHeight)",
                                with: "\(Int(renderSize.width))×\(Int(renderSize.height))")
                        }
                        output.url = cropped.url
                        output.width = Int(renderSize.width)
                        output.height = Int(renderSize.height)
                        if cropIsReal {
                            output.summary += " · cropped to \(cropCanvas.rawValue)"
                        }
                        if !grade.isIdentity {
                            gradeBaked = true
                            output.summary += " · \(grade.preset.displayName) grade baked in"
                        }
                        if uncropped.deletingLastPathComponent().standardizedFileURL
                            == FileManager.default.temporaryDirectory.standardizedFileURL {
                            try? FileManager.default.removeItem(at: uncropped)
                        }
                    }
                }
                // The standalone grade bake, only when no geometry pass ran to
                // carry it (a nil crop renderSize means the crop pass no-oped
                // and baked nothing). Still one short pass over a few seconds
                // of output, never a re-encode of the original source.
                if source.isVideo, output.kind == .video, !grade.isIdentity, !gradeBaked {
                    self.statusMessage = "Baking the \(grade.preset.displayName) grade..."
                    self.processingPhase = .grading
                    self.tailPhaseStartedAt = Date()
                    self.processingETADate = nil
                    let gradeBand = tailBand
                    let ungraded = output.url
                    output.url = try await VideoGrader.bakedCopy(of: ungraded, grade: grade) { fraction in
                        Task { @MainActor [weak self] in
                            guard let self, let gradeBand else { return }
                            self.reportTailProgress(band: gradeBand, fraction: fraction)
                        }
                    }
                    if let gradeBand {
                        self.reportTailProgress(band: gradeBand, fraction: 1)
                    }
                    output.summary += " · \(grade.preset.displayName) grade baked in"
                    // The ungraded intermediate is scratch, and on iOS this runs
                    // on a phone that may be tight on space — but only remove it
                    // when it is our own temp file, never a Mac job folder's
                    // output the runner may still be reporting on.
                    if output.url != ungraded,
                       ungraded.deletingLastPathComponent().standardizedFileURL
                        == FileManager.default.temporaryDirectory.standardizedFileURL {
                        try? FileManager.default.removeItem(at: ungraded)
                    }
                }
                self.processingPhase = .saving
                self.processingETADate = nil
                let blend = try self.storeBlend(output, captureID: captureID, parameters: parameters)
                self.apply(output, from: blend)
                self.progress = 1
                self.processingStartedAt = nil
                self.stage = .done
            } catch is CancellationError {
                self?.processingStartedAt = nil
                self?.stage = .configure
            } catch LapseError.cancelled {
                self?.processingStartedAt = nil
                self?.stage = .configure
            } catch {
                self?.processingStartedAt = nil
                self?.errorMessage = (error as? LapseError)?.errorDescription ?? error.localizedDescription
                self?.stage = .configure
            }
        }
    }

    /// Photo mode's one-tap path: turn a freshly captured burst into a single
    /// photo, skipping Adjust entirely. With Blend Off (depth ≤ 1) the
    /// captured frame is simply registered as the photo — no re-encode, its
    /// camera EXIF/GPS intact. With blend on, the burst is stacked into one
    /// image (which carries the first frame's EXIF/GPS) and the burst frames
    /// are preserved on disk as stacking material; originals are never
    /// deleted.
    /// With `presentResult` false the job runs without driving the flow stages
    /// — the camera stays on screen and the finished photo lands quietly in
    /// Projects, so the user can shoot the next frame straight away.
    func processPhotoBurst(urls: [URL], blendDepth: Int, linear: Bool, presentResult: Bool = true) async {
        // Preserve the burst as a photo capture so its frames stay on disk and
        // the blend has a project to belong to.
        let capture: CaptureProject
        do {
            capture = try registerCapture(from: .photos(urls), mode: Self.photoCaptureMode)
        } catch {
            errorMessage = "Couldn't preserve the capture: \(error.localizedDescription)"
            stage = .home
            return
        }

        // Blend from the in-project copies, not the temporary burst URLs.
        let captureSource: Source
        do {
            captureSource = try source(for: capture)
        } catch {
            errorMessage = "Couldn't open that capture: \(error.localizedDescription)"
            stage = .home
            return
        }
        let sourceURLs: [URL]
        if case .photos(let resolved) = captureSource {
            sourceURLs = resolved
        } else {
            sourceURLs = urls
        }

        // Blend Off: the captured frame IS the photo — one asset, one file,
        // its camera EXIF and GPS untouched. No stacking pass, no version.
        if blendDepth <= 1 {
            if presentResult, let photoURL = sourceURLs.first {
                currentCaptureID = capture.id
                resultBlendID = nil
                resultVideoURL = nil
                resultImageURL = photoURL
                resultImage = loadImage(at: photoURL)
                resultSummary = "Photo"
                errorMessage = nil
                stage = .done
            }
            return
        }

        blendSourceCodec = nil
        blendCanvasRatio = nil
        blendCanvasOffset = 0.5
        source = captureSource
        currentCaptureID = capture.id
        photoBlendDepth = max(1, blendDepth)
        linearLight = linear
        excludedFrameIndices = []
        tailFramesToExclude = 0
        totalIntervalFrames = 0

        // Straight to processing — no configure step, the depth is decided.
        // When the camera is staying up (`presentResult` false) the flow stages
        // are left untouched (home), so nothing layers over the viewfinder.
        if presentResult {
            stage = .processing
        }
        statusMessage = "Blending photos..."
        jobFolderURL = nil
        jobLogLines = []
        resultVideoURL = nil
        resultImage = nil
        resultImageURL = nil
        resultSummary = nil
        resultBlendID = nil
        errorMessage = nil
        resetProcessingProgress()
        processingStartedAt = Date()
        beginProgressPlan(.make(
            clipFrames: [sourceURLs.count], hasStitch: false, hasGrade: false))
        processingPhase = .blending(clip: 1, of: 1)

        let captureID = capture.id
        let parameters = currentBlendParameters()
        blendTask = Task { [weak self] in
            do {
                guard let self else { return }
                // Fold every captured frame into one long exposure — the same
                // single-image path Adjust uses when the depth spans the burst.
                // `.identity`: a Photo-mode grade stays non-destructive — the
                // stack is the project's asset and is graded for display and on
                // export, never baked into the stored file.
                let output = try await self.stackPhotos(
                    urls: sourceURLs, linear: linear, grade: .identity)
                self.processingPhase = .saving
                self.processingETADate = nil
                let blend = try self.storeBlend(output, captureID: captureID, parameters: parameters)
                self.apply(output, from: blend)
                self.progress = 1
                self.processingStartedAt = nil
                if presentResult {
                    self.stage = .done
                }
            } catch is CancellationError {
                self?.processingStartedAt = nil
                self?.stage = .home
            } catch LapseError.cancelled {
                self?.processingStartedAt = nil
                self?.stage = .home
            } catch {
                self?.processingStartedAt = nil
                self?.errorMessage = (error as? LapseError)?.errorDescription ?? error.localizedDescription
                self?.stage = .home
            }
        }
    }

    private func blendVideo(
        url: URL,
        ramp: BlendRamp,
        fps: Double,
        linear: Bool,
        trimHeadTailSeconds: Double,
        clipIndex: Int = 0,
        customWindows: [Int]? = nil
    ) async throws -> ProcessingOutput {
        #if os(macOS)
        // The external runner only speaks constant windows; warped and ramped
        // blends run in-process through VideoBlender, same as iOS.
        if ramp.startWindow == ramp.endWindow, customWindows == nil {
            let result = try await MacVideoJobRunner.run(
                inputURL: url,
                options: MacVideoJobOptions(
                    blendWindow: ramp.startWindow,
                    outputFPS: fps,
                    linearLight: linear,
                    trimHeadTailSeconds: trimHeadTailSeconds,
                    maxCPUWorkers: maxCPUWorkers,
                    maxBlendBatches: maxBlendBatches,
                    extractFormat: scratchFrameFormat,
                    keepExtractedFrames: keepExtractedFrames
                )
            ) { update in
                Task { @MainActor [weak self] in
                    // Batches still in flight after a cancel keep reporting;
                    // once the processing screen is gone, drop their updates.
                    guard let self, self.stage == .processing else { return }
                    // The runner's fraction, ETA and frame counts are per-clip
                    // and stage-shaped; only the fraction feeds the global bar
                    // (mapped into this clip's band). The rest stays in the
                    // job log for Diagnostics.
                    self.reportClipProgress(clipIndex, fraction: update.fraction)
                    self.statusMessage = update.message
                    self.jobFolderURL = update.jobFolderURL
                    self.jobLogLines = update.recentLogLines
                }
            }
            jobFolderURL = result.jobFolderURL
            let trimSummary = trimHeadTailSeconds > 0 ? " · trimmed \(String(format: "%.1f", trimHeadTailSeconds))s each end" : ""
            let summary = "\(result.inputFrames) frames in → \(result.outputFrames) frames out · "
                + "\(result.width)×\(result.height)"
                + trimSummary
            return ProcessingOutput(
                kind: .video,
                url: result.outputURL,
                image: nil,
                summary: summary,
                inputFrames: result.inputFrames,
                outputFrames: result.outputFrames,
                width: result.width,
                height: result.height
            )
        }
        #endif

        let core = try BlendCore()
        let blender = VideoBlender(core: core)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-\(UUID().uuidString).mp4")
        let options = VideoBlendOptions(
            ramp: ramp,
            outputFPS: fps,
            codec: (blendProfileOverride ?? defaultBlendProfile) == .hevcMain10 ? .hevc : .h264,
            linearLight: linear,
            trimHeadTailSeconds: trimHeadTailSeconds,
            customWindows: customWindows
        )
        let result = try await blender.blend(input: url, to: output, options: options) { fraction in
            Task { @MainActor [weak self] in
                self?.reportClipProgress(clipIndex, fraction: fraction)
            }
        }
        let trimSummary = trimHeadTailSeconds > 0 ? " · trimmed \(String(format: "%.1f", trimHeadTailSeconds))s each end" : ""
        let summary = "\(result.inputFrames) frames in → \(result.outputFrames) frames out · "
            + String(format: "%.1fs", result.outputDuration)
            + " · \(result.width)×\(result.height)"
            + trimSummary
        return ProcessingOutput(
            kind: .video,
            url: result.outputURL,
            image: nil,
            summary: summary,
            inputFrames: result.inputFrames,
            outputFrames: result.outputFrames,
            width: result.width,
            height: result.height
        )
    }

    /// Brings one blended segment to the shoot's common render size, taking any
    /// punch-in crop from it **at its own resolution** on the way.
    ///
    /// Returns `url` unchanged when the segment already needs nothing — a base
    /// segment of a shoot with no punch and no canvas crop is already the right
    /// size, and paying a re-encode to confirm that would be waste.
    private func normalizedSegment(
        _ url: URL,
        segmentIndex: Int,
        normalization: SegmentNormalization
    ) async throws -> URL {
        if let reframe = normalization.reframe {
            // The slice of the frame map belonging to THIS segment. The warp
            // compiles one region per segment file, so the indices are already
            // local to the piece — which is what the cropper's
            // `compositionTime * fps` lookup wants.
            let frameTimes = segmentIndex < reframe.frameTimesBySegment.count
                ? reframe.frameTimesBySegment[segmentIndex] : []
            guard !frameTimes.isEmpty else {
                LLog("normalize: segment \(segmentIndex) has no compiled frame map"
                     + " — scaling without the punch")
                return try await scaledSegment(url, normalization: normalization)
            }
            let reframed = try await ReframeVideoCropper.croppedCopy(
                of: url,
                track: reframe.track,
                aspect: reframe.aspect,
                sourceSize: reframe.sourceSize,
                frameSourceTimes: frameTimes,
                outputFPS: reframe.outputFPS,
                renderSizeOverride: normalization.renderSize)
            return reframed.url
        }
        return try await scaledSegment(url, normalization: normalization)
    }

    /// The no-punch path: canvas-crop and/or scale one segment to the common
    /// render size.
    private func scaledSegment(
        _ url: URL,
        normalization: SegmentNormalization
    ) async throws -> URL {
        let cropped = try await VideoCanvasCropper.croppedCopy(
            of: url,
            canvas: normalization.canvas,
            offset: normalization.canvasOffset,
            renderSizeOverride: normalization.renderSize)
        return cropped.url
    }

    private func blendLiveSequence(
        _ source: LiveCaptureSource,
        ramp: BlendRamp,
        fps: Double,
        linear: Bool,
        burstRamp: Double,
        willBakeGrade: Bool,
        warpSchedules: [[Int]]? = nil,
        normalization: SegmentNormalization? = nil
    ) async throws -> ProcessingOutput {
        guard !source.segmentURLs.isEmpty else { throw LapseError.noInputFrames }

        guard source.sequence.mode == .ramp else {
            return try await blendMarkerSequence(
                source, ramp: ramp, fps: fps, linear: linear, burstRamp: burstRamp,
                willBakeGrade: willBakeGrade, warpSchedules: warpSchedules)
        }

        let segmentURLByName = source.resolvedByOriginalName
        let orderedSegments = source.sequence.segments.sorted { $0.index < $1.index }
        guard !orderedSegments.isEmpty else {
            let fallbackURL = source.segmentURLs[0]
            beginProgressPlan(.make(clipFrames: [1], hasStitch: false, hasGrade: willBakeGrade))
            processingPhase = .blending(clip: 1, of: 1)
            return try await blendVideo(url: fallbackURL, ramp: ramp, fps: fps, linear: linear, trimHeadTailSeconds: 0)
        }

        var processedPieces: [StitchPiece] = []
        var inputFrames = 0
        var outputFrames = 0
        var outputWidth: Int?
        var outputHeight: Int?
        let totalSegments = orderedSegments.count

        // Segments are wildly uneven — a 4-minute base clip next to a 1.3 s
        // burst — so the bar is split by each one's frame count, not per clip.
        let plan = BlendProgressPlan.make(
            clipFrames: await segmentFrameEstimates(
                orderedSegments, urlsByName: segmentURLByName,
                baseFrameRate: source.sequence.baseFrameRate),
            hasStitch: true, hasGrade: willBakeGrade)
        beginProgressPlan(plan)

        for (index, segment) in orderedSegments.enumerated() {
            guard let segmentURL = segmentURLByName[segment.fileName] else {
                throw CocoaError(.fileNoSuchFile)
            }
            let isRampOn = segmentIsRampOn(segment, in: source.sequence)
            processingPhase = .blending(clip: index + 1, of: totalSegments)
            statusMessage = isRampOn
                ? "Blending ramp segment \(index + 1) / \(totalSegments) at playback speed..."
                : "Blending base segment \(index + 1) / \(totalSegments)..."
            // The warp's compiled schedule for this file when the timeline is
            // driving; the legacy defaults otherwise — moments frame-for-frame,
            // base at the project speed or Advanced ramp.
            let warpWindows = warpSchedules.flatMap { index < $0.count ? $0[index] : nil }
            let segmentOutput = try await blendVideo(
                url: segmentURL,
                ramp: isRampOn ? .constant(1) : ramp,
                fps: fps,
                linear: linear,
                trimHeadTailSeconds: 0,
                clipIndex: index,
                customWindows: (warpWindows?.isEmpty == false) ? warpWindows : nil
            )
            // Legacy path only: a burst segment's frames go out one-for-one at
            // the output rate, landing frameRate/fps times slow — the gap the
            // stitch ramp eases across. A warp render already carries its
            // speeds and eases inside the schedules, so nothing is retimed.
            let slowFactor = Double(segment.frameRate) / fps
            // Crop THEN shrink, per segment, before anything is stitched.
            // Nothing here runs for a single-resolution shoot: `normalization`
            // is nil then and the tail passes work exactly as they always have.
            var pieceURL = segmentOutput.url
            if let normalization {
                pieceURL = try await normalizedSegment(
                    segmentOutput.url,
                    segmentIndex: index,
                    normalization: normalization)
                if pieceURL != segmentOutput.url,
                   segmentOutput.url.deletingLastPathComponent().standardizedFileURL
                    == FileManager.default.temporaryDirectory.standardizedFileURL {
                    try? FileManager.default.removeItem(at: segmentOutput.url)
                }
            }
            processedPieces.append(StitchPiece(
                url: pieceURL,
                slowFactor: warpSchedules == nil && isRampOn && slowFactor > 1 ? slowFactor : nil))
            inputFrames += segmentOutput.inputFrames ?? 0
            outputFrames += segmentOutput.outputFrames ?? 0
            if let normalization {
                outputWidth = Int(normalization.renderSize.width)
                outputHeight = Int(normalization.renderSize.height)
            } else {
                outputWidth = outputWidth ?? segmentOutput.width
                outputHeight = outputHeight ?? segmentOutput.height
            }
            reportClipProgress(index, fraction: 1)
        }

        processingPhase = .combining(clips: processedPieces.count)
        tailPhaseStartedAt = Date()
        processingETADate = nil
        statusMessage = "Stitching \(processedPieces.count) processed segments..."
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-sequence-\(UUID().uuidString).mp4")
        let stitchBand = plan.stitchBand ?? min(progress, 0.98)...0.98
        let stitched = try await stitchVideos(
            processedPieces, to: output, burstRamp: burstRamp
        ) { [weak self] fraction in
            Task { @MainActor in
                self?.reportTailProgress(band: stitchBand, fraction: fraction)
            }
        }
        try Task.checkCancellation()
        reportTailProgress(band: stitchBand, fraction: 1)
        if stitched.rampDropped {
            saveConfirmation = "Clip created — slow-motion ramp couldn't be applied on this device"
        }

        let effectiveBurstRamp = stitched.rampDropped ? 0.0 : burstRamp
        let finalFrames = stitchedOutputFrames(
            blended: outputFrames, stitchedDuration: stitched.duration,
            fps: fps, burstRamp: effectiveBurstRamp, pieces: processedPieces)
        let summary = "\(inputFrames) frames in → \(finalFrames) frames out · "
            + "\(stitched.width)×\(stitched.height) · "
            + "\(source.sequence.rampIntervals.count) ramp intervals stitched"
            + burstRampSummary(effectiveBurstRamp, pieces: processedPieces)
            // The per-segment path consumed the tail passes, so it owns their
            // half of the summary too.
            + (normalization.map { plan in
                let sizes = source.sequence.segmentResolutions
                    .map { "\($0.width)×\($0.height)" }
                    .joined(separator: " + ")
                return " · \(sizes) normalised to "
                    + "\(Int(plan.renderSize.width))×\(Int(plan.renderSize.height))"
                    + (plan.reframe != nil ? " · punch-in reframe" : "")
            } ?? "")
        return ProcessingOutput(
            kind: .video,
            url: output,
            image: nil,
            summary: summary,
            inputFrames: inputFrames,
            outputFrames: finalFrames,
            width: outputWidth ?? stitched.width,
            height: outputHeight ?? stitched.height,
            geometryBaked: normalization != nil
        )
    }

    /// Per-segment input-frame estimates for the progress plan. The sidecar
    /// knows each segment's rate and span; a segment it can't size is probed
    /// from its file, and one the probe can't size either reports 0 so the
    /// plan gives it the mean weight of the segments it could size.
    private func segmentFrameEstimates(
        _ segments: [LiveCaptureSequence.Segment],
        urlsByName: [String: URL],
        baseFrameRate: Int
    ) async -> [Int] {
        var estimates: [Int] = []
        for segment in segments {
            let span = segment.relativeEnd - segment.relativeStart
            let rate = segment.frameRate > 0
                ? Double(segment.frameRate)
                : Double(max(baseFrameRate, 0))
            if span.isFinite, span > 0, rate > 0 {
                estimates.append(max(1, Int((span * rate).rounded())))
                continue
            }
            if let url = urlsByName[segment.fileName],
               let probed = await probeFrameEstimate(url: url, fallbackRate: rate > 0 ? rate : 30) {
                estimates.append(probed)
                continue
            }
            estimates.append(0)
        }
        return estimates
    }

    private func probeFrameEstimate(url: URL, fallbackRate: Double) async -> Int? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0 else { return nil }
        var rate = fallbackRate
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let nominal = try? await track.load(.nominalFrameRate), nominal > 0 {
            rate = Double(nominal)
        }
        return max(1, Int((duration * rate).rounded()))
    }

    private struct MarkerSequencePiece {
        var range: ClosedRange<Double>
        var isRampOn: Bool
    }

    private func blendMarkerSequence(
        _ source: LiveCaptureSource,
        ramp: BlendRamp,
        fps: Double,
        linear: Bool,
        burstRamp: Double,
        willBakeGrade: Bool,
        warpSchedules: [[Int]]? = nil
    ) async throws -> ProcessingOutput {
        guard let sourceURL = source.primaryVideoURL else { throw LapseError.noInputFrames }

        // A warp render needs no extraction and no stitch: marker mode is one
        // file, and the compiled schedule carries every stretch, seam and ease
        // through a single pass — blur follows the speed curve continuously.
        if let schedule = warpSchedules?.first, !schedule.isEmpty {
            beginProgressPlan(.make(
                clipFrames: [max(1, schedule.reduce(0, +))],
                hasStitch: false, hasGrade: willBakeGrade))
            processingPhase = .blending(clip: 1, of: 1)
            statusMessage = "Blending the warped timeline..."
            return try await blendVideo(
                url: sourceURL, ramp: ramp, fps: fps, linear: linear,
                trimHeadTailSeconds: 0, customWindows: schedule)
        }

        let pieces = try await markerSequencePieces(for: source, sourceURL: sourceURL)
        guard !pieces.isEmpty else {
            beginProgressPlan(.make(clipFrames: [1], hasStitch: false, hasGrade: willBakeGrade))
            processingPhase = .blending(clip: 1, of: 1)
            return try await blendVideo(url: sourceURL, ramp: ramp, fps: fps, linear: linear, trimHeadTailSeconds: 0)
        }

        // Marker mode records the whole run at the base rate; a marked interval
        // becomes slow motion by going out frame-for-frame at the output rate.
        let slowFactor = Double(source.sequence.baseFrameRate) / fps
        var processedPieces: [StitchPiece] = []
        var inputFrames = 0
        var outputFrames = 0
        var outputWidth: Int?
        var outputHeight: Int?

        // One recording rate across the whole run, so an interval's duration
        // is an exact stand-in for its frame count.
        let pieceRate = Double(max(1, source.sequence.baseFrameRate))
        let plan = BlendProgressPlan.make(
            clipFrames: pieces.map {
                max(1, Int((($0.range.upperBound - $0.range.lowerBound) * pieceRate).rounded()))
            },
            hasStitch: true, hasGrade: willBakeGrade)
        beginProgressPlan(plan)

        for (index, piece) in pieces.enumerated() {
            processingPhase = .blending(clip: index + 1, of: pieces.count)
            statusMessage = piece.isRampOn
                ? "Rendering marker interval \(index + 1) / \(pieces.count) at playback speed..."
                : "Blending marker interval \(index + 1) / \(pieces.count)..."

            let clipURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("LetsLapse-marker-piece-\(UUID().uuidString).mov")
            try await extractVideoRange(
                sourceURL,
                from: piece.range.lowerBound,
                to: piece.range.upperBound,
                outputURL: clipURL
            )

            let pieceOutput = try await blendVideo(
                url: clipURL,
                ramp: piece.isRampOn ? .constant(1) : ramp,
                fps: fps,
                linear: linear,
                trimHeadTailSeconds: 0,
                clipIndex: index
            )
            processedPieces.append(StitchPiece(
                url: pieceOutput.url,
                slowFactor: piece.isRampOn && slowFactor > 1 ? slowFactor : nil))
            inputFrames += pieceOutput.inputFrames ?? 0
            outputFrames += pieceOutput.outputFrames ?? 0
            outputWidth = outputWidth ?? pieceOutput.width
            outputHeight = outputHeight ?? pieceOutput.height
            reportClipProgress(index, fraction: 1)
        }

        processingPhase = .combining(clips: processedPieces.count)
        tailPhaseStartedAt = Date()
        processingETADate = nil
        statusMessage = "Stitching \(processedPieces.count) processed marker intervals..."
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-marker-sequence-\(UUID().uuidString).mp4")
        let stitchBand = plan.stitchBand ?? min(progress, 0.98)...0.98
        let stitched = try await stitchVideos(
            processedPieces, to: output, burstRamp: burstRamp
        ) { [weak self] fraction in
            Task { @MainActor in
                self?.reportTailProgress(band: stitchBand, fraction: fraction)
            }
        }
        try Task.checkCancellation()
        reportTailProgress(band: stitchBand, fraction: 1)
        if stitched.rampDropped {
            saveConfirmation = "Clip created — slow-motion ramp couldn't be applied on this device"
        }

        let effectiveBurstRamp = stitched.rampDropped ? 0.0 : burstRamp
        let finalFrames = stitchedOutputFrames(
            blended: outputFrames, stitchedDuration: stitched.duration,
            fps: fps, burstRamp: effectiveBurstRamp, pieces: processedPieces)
        let summary = "\(inputFrames) frames in → \(finalFrames) frames out · "
            + "\(stitched.width)×\(stitched.height) · "
            + "\(source.sequence.rampIntervals.count) marker ramp intervals stitched"
            + burstRampSummary(effectiveBurstRamp, pieces: processedPieces)
        return ProcessingOutput(
            kind: .video,
            url: output,
            image: nil,
            summary: summary,
            inputFrames: inputFrames,
            outputFrames: finalFrames,
            width: outputWidth ?? stitched.width,
            height: outputHeight ?? stitched.height
        )
    }

    private func markerSequencePieces(
        for source: LiveCaptureSource,
        sourceURL: URL
    ) async throws -> [MarkerSequencePiece] {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return [] }
        // Shared with the Adjust screen's ruler (which reads the duration off
        // the sidecar instead of probing), so a per-stretch speed override
        // lands on the same piece the ruler showed it on.
        return StretchBuilder.markerPieces(sequence: source.sequence, duration: duration)
            .map { MarkerSequencePiece(range: $0.range, isRampOn: $0.isMoment) }
    }

    private func extractVideoRange(
        _ sourceURL: URL,
        from start: Double,
        to end: Double,
        outputURL: URL
    ) async throws {
        guard end > start else { throw LapseError.noInputFrames }
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw LapseError.writerFailed("could not create marker interval export session")
        }
        export.outputURL = outputURL
        export.outputFileType = .mov
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: end - start, preferredTimescale: 600)
        )
        export.shouldOptimizeForNetworkUse = true
        let exportBox = ExportSessionBox(export)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportBox.session.exportAsynchronously {
                switch exportBox.session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: LapseError.writerFailed(
                        exportBox.session.error?.localizedDescription ?? "marker interval export failed"
                    ))
                case .cancelled:
                    continuation.resume(throwing: LapseError.cancelled)
                default:
                    continuation.resume(throwing: LapseError.writerFailed("marker interval export did not complete"))
                }
            }
        }
    }

    private func segmentIsRampOn(
        _ segment: LiveCaptureSequence.Segment,
        in sequence: LiveCaptureSequence
    ) -> Bool {
        if sequence.mode == .ramp {
            return segment.frameRate > sequence.baseFrameRate
        }
        return sequence.rampIntervals.contains { interval in
            let intervalEnd = interval.relativeEnd ?? segment.relativeEnd
            return interval.relativeStart < segment.relativeEnd
                && intervalEnd > segment.relativeStart
        }
    }

    /// A stitch failure people (and logs) can act on. `AVAssetExportSession`'s
    /// own `localizedDescription` is almost always the useless "The operation
    /// could not be completed" — the code and the underlying error are what
    /// actually say which part of the composition it choked on.
    private static func exportFailureDescription(_ error: Error?, hadBurstRamp: Bool = false) -> String {
        guard let error else { return "sequence export failed" }
        let nsError = error as NSError
        // kVTPropertyNotSupportedErr (-16364) wrapped in
        // AVErrorOperationNotSupportedForAsset (-11800) is VideoToolbox
        // rejecting scaleTimeRange on a codec it can't retime (typically HEVC).
        // Give the user something they can act on instead of raw error codes.
        if hadBurstRamp,
           nsError.domain == AVFoundationErrorDomain, nsError.code == -11800 {
            let description = "Slow-motion ramp failed — try reducing the ramp duration or turning it off"
            LLog("stitch export failed: \(description) (AVFoundationErrorDomain -11800)")
            return description
        }
        var parts = [nsError.localizedDescription]
        if let reason = nsError.localizedFailureReason { parts.append(reason) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying \(underlying.domain) \(underlying.code)")
        }
        parts.append("(\(nsError.domain) \(nsError.code))")
        let description = parts.joined(separator: " · ")
        LLog("stitch export failed: \(description)")
        return description
    }

    /// The version's real frame count. A ramp retimes the burst clips inside
    /// the stitch, so the frames the blend wrote no longer describe the file
    /// that came out — and `BlendProject.outputSeconds`, which the version
    /// badge shows, is derived from this.
    private func stitchedOutputFrames(
        blended: Int,
        stitchedDuration: Double,
        fps: Double,
        burstRamp: Double,
        pieces: [StitchPiece]
    ) -> Int {
        guard burstRamp > 0,
              pieces.contains(where: { $0.slowFactor != nil }),
              stitchedDuration.isFinite, stitchedDuration > 0, fps > 0 else { return blended }
        return max(1, Int((stitchedDuration * fps).rounded()))
    }

    /// The version summary's note about ramped bursts, empty when the render
    /// had none to ramp or ramps are off.
    private func burstRampSummary(_ burstRamp: Double, pieces: [StitchPiece]) -> String {
        let bursts = pieces.filter { $0.slowFactor != nil }.count
        guard burstRamp > 0, bursts > 0 else { return "" }
        return " · \(BurstRamp.label(burstRamp)) ramp on \(bursts) burst\(bursts == 1 ? "" : "s")"
    }

    /// One processed clip on its way into the stitch, and what it is: a burst
    /// clip carries the factor by which it already plays slower than real time,
    /// which is what a ramp eases in and out of. nil = ordinary footage, never
    /// retimed.
    private struct StitchPiece {
        var url: URL
        var slowFactor: Double?
    }

    /// Lays the processed clips end to end and exports one file.
    ///
    /// `burstRamp` (seconds, 0 = off) puts a smooth ease on both ends of every
    /// burst clip in the timeline instead of cutting straight into slow motion.
    /// It is a pure retime of the composition — the ramp lives inside the burst
    /// clip's own footage and never reaches the clips either side of it.
    // Thrown internally when the export fails with AVErrorOperationNotSupportedForAsset
    // (-11800) while a burst ramp is active, so the caller can rebuild and retry
    // without the ramp rather than surfacing a hard error.
    private struct BurstRampExportFailure: Error {}

    private func stitchVideos(
        _ pieces: [StitchPiece],
        to outputURL: URL,
        burstRamp: Double = 0,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (width: Int, height: Int, duration: Double, rampDropped: Bool) {
        guard !pieces.isEmpty else { throw LapseError.noInputFrames }
        try? FileManager.default.removeItem(at: outputURL)

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw LapseError.writerFailed("could not create composition track")
        }

        var cursor = CMTime.zero
        var outputSize: CGSize?
        var firstNaturalSize = CGSize.zero
        var transform = CGAffineTransform.identity
        // Created lazily on the first segment that carries sound (Record
        // audio setting); a failed audio insert never fails the stitch.
        var audioCompositionTrack: AVMutableCompositionTrack?
        /// Where each burst clip landed, for the retiming pass below.
        var burstPlacements: [(start: CMTime, duration: CMTime, slowFactor: Double)] = []

        for (index, piece) in pieces.enumerated() {
            let asset = AVURLAsset(url: piece.url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw LapseError.noVideoTrack(piece.url)
            }
            let duration = try await asset.load(.duration)
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: track,
                at: cursor
            )
            if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
                if audioCompositionTrack == nil {
                    audioCompositionTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }
                try? audioCompositionTrack?.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: audioTrack,
                    at: cursor
                )
            }
            if let slowFactor = piece.slowFactor {
                burstPlacements.append((cursor, duration, slowFactor))
            }
            cursor = cursor + duration

            let naturalSize = try await track.load(.naturalSize)
            if index == 0 {
                transform = try await track.load(.preferredTransform)
                outputSize = CGRect(origin: .zero, size: naturalSize)
                    .applying(transform)
                    .standardized
                    .size
            } else if naturalSize != firstNaturalSize {
                // One composition track has one size, so AVFoundation would
                // quietly scale this piece to piece 0's and the dimensions
                // reported below would be a lie for it. Mixed-resolution ramp
                // shoots are normalised per segment before they get here
                // (`SegmentNormalization`); anything still mismatched at this
                // point is a bug, and a silent one without this.
                LLog("stitch: piece \(index) is \(Int(naturalSize.width))×"
                     + "\(Int(naturalSize.height)) but piece 0 is "
                     + "\(Int(firstNaturalSize.width))×\(Int(firstNaturalSize.height))"
                     + " — it will be scaled to fit and the reported size is piece 0's")
            }
            if index == 0 { firstNaturalSize = naturalSize }
        }
        compositionTrack.preferredTransform = transform

        if burstRamp > 0, !burstPlacements.isEmpty {
            // Only tracks the burst clips were actually inserted into. An audio
            // track that a `try?` insert skipped, or that ran short, must not be
            // scaled — its ranges wouldn't line up with the picture's.
            var tracks: [AVMutableCompositionTrack] = [compositionTrack]
            if let audioCompositionTrack, audioCompositionTrack.timeRange.end >= cursor {
                tracks.append(audioCompositionTrack)
            } else if audioCompositionTrack != nil {
                LLog("burst-ramp: audio track is short of the stitch — ramping picture only")
            }
            // Retiming a range moves everything after it, so the placements
            // recorded above only stay valid while working backwards.
            for placement in burstPlacements.reversed() {
                guard let plan = BurstRamp.plan(
                    requestedRamp: burstRamp,
                    burstOutputDuration: placement.duration.seconds,
                    slowFactor: placement.slowFactor
                ) else {
                    LLog("burst-ramp: \(String(format: "%.2f", placement.duration.seconds))s clip "
                         + "at \(String(format: "%.2f", placement.slowFactor))× takes no ramp")
                    continue
                }
                let scaled = BurstRamp.apply(
                    plan,
                    to: tracks,
                    startingAt: placement.start,
                    duration: placement.duration)
                LLog("burst-ramp: \(String(format: "%.2f", plan.appliedRamp))s ease over "
                     + "\(scaled)/\(plan.steps.count) steps on the clip at "
                     + "\(String(format: "%.2f", placement.start.seconds))s")
            }
        }

        // AVAssetExportPresetHighestQuality attempts to preserve the source
        // codec (HEVC on modern iPhones), but VideoToolbox's HEVC encoder does
        // not support scaleTimeRange — it returns kVTPropertyNotSupportedErr
        // (-16364) wrapped in AVErrorOperationNotSupportedForAsset (-11800).
        // A resolution-locked preset forces an H.264 encode path that handles
        // speed ramps without complaint. Only switch when ramp is actually on;
        // HighestQuality is still used for ramp-free stitches.
        let hasRamp = burstRamp > 0 && !burstPlacements.isEmpty
        let stitchPreset: String
        if hasRamp, let size = outputSize {
            stitchPreset = max(size.width, size.height) > 1920
                ? AVAssetExportPreset3840x2160
                : AVAssetExportPreset1920x1080
        } else {
            stitchPreset = AVAssetExportPresetHighestQuality
        }
        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: stitchPreset
        ) else {
            throw LapseError.writerFailed("could not create export session")
        }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        let exportBox = ExportSessionBox(export)

        // The export is the invisible tail of a multi-clip run: poll its
        // fraction so the bar keeps moving, and forward Task cancellation so
        // Cancel actually aborts it instead of letting the version finish and
        // save behind the sheet.
        let poller: Task<Void, Never>? = progress.map { report in
            Task.detached {
                while !Task.isCancelled {
                    report(Double(exportBox.session.progress))
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
        defer { poller?.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    exportBox.session.exportAsynchronously {
                        switch exportBox.session.status {
                        case .completed:
                            continuation.resume()
                        case .failed:
                            let exportError = exportBox.session.error
                            let nsErr = exportError as? NSError
                            if hasRamp,
                               nsErr?.domain == AVFoundationErrorDomain,
                               nsErr?.code == -11800 {
                                // VideoToolbox rejected scaleTimeRange (kVTPropertyNotSupportedErr).
                                // Signal the outer catch to rebuild and retry without ramp.
                                LLog("burst-ramp: export -11800 — will retry without ramp")
                                continuation.resume(throwing: BurstRampExportFailure())
                            } else {
                                continuation.resume(throwing: LapseError.writerFailed(
                                    Self.exportFailureDescription(exportError, hadBurstRamp: hasRamp)))
                            }
                        case .cancelled:
                            continuation.resume(throwing: LapseError.cancelled)
                        default:
                            continuation.resume(throwing: LapseError.writerFailed("sequence export did not complete"))
                        }
                    }
                }
            } onCancel: {
                exportBox.session.cancelExport()
            }
        } catch is BurstRampExportFailure {
            // The ramp couldn't be encoded on this device. Rebuild without it so
            // the clip still lands — the caller surfaces a non-fatal notice.
            LLog("burst-ramp: rebuilding composition without ramp")
            try? FileManager.default.removeItem(at: outputURL)
            let fallback = try await stitchVideos(pieces, to: outputURL,
                                                  burstRamp: 0, progress: progress)
            return (fallback.width, fallback.height, fallback.duration, rampDropped: true)
        }

        let size = outputSize ?? .zero
        // Read back from the composition rather than summing the inputs: a ramp
        // retimes the burst clips, so the file that just landed is shorter than
        // the clips that went into it.
        return (
            Int(abs(size.width).rounded()),
            Int(abs(size.height).rounded()),
            composition.duration.seconds,
            rampDropped: false
        )
    }

    /// Blends a sequence of interval stills into a timelapse video. Each output
    /// frame averages `ramp`-worth of consecutive stills, so `constantWindow`
    /// doubles as the blend depth (1 = crisp timelapse, higher = motion blur).
    ///
    /// `grade` is baked in frame by frame on the way into the blend, which is
    /// where an interval project's colour grade becomes permanent: the written
    /// video carries it, the stills on disk stay exactly as captured.
    ///
    /// `frameTimes` — elapsed capture seconds per still, from a ramped shoot's
    /// sidecar — lays the output on the real capture clock rather than at a
    /// constant frame interval. Nil for every shoot that kept even spacing.
    private func blendPhotosSequence(
        urls: [URL],
        ramp: BlendRamp,
        fps: Double,
        linear: Bool,
        grade: PhotoGrade = .identity,
        frameTimes: [Double]? = nil,
        profile: VideoEncodePolicy.Profile = .h264High8Bit
    ) async throws -> ProcessingOutput {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-\(UUID().uuidString).mp4")
        let result = try await Task.detached(priority: .userInitiated) { [weak self] () throws -> StackSequenceResult in
            let core = try BlendCore()
            let stacker = ImageStacker(core: core)
            let progress: (Double) -> Void = { fraction in
                Task { @MainActor in
                    self?.reportClipProgress(0, fraction: fraction)
                }
            }
            guard linear else {
                // Gamma-domain averaging is a deliberate "not physically
                // correct" choice; it stays on the legacy 8-bit path.
                return try stacker.stackSequence(
                    imageURLs: urls,
                    ramp: ramp,
                    outputFPS: fps,
                    linearLight: false,
                    outputURL: output,
                    frameTimes: frameTimes,
                    loadFrame: Self.gradedFrameLoader(grade),
                    progress: progress)
            }
            // The engine path: linear half-float decode straight to the
            // accumulator, the grade applied once per OUTPUT frame after the
            // average — the order Lightroom would grade the blended still in.
            let support = try PhotoGrader.blendSupport(grade: grade)
            return try stacker.stackSequenceLinear(
                imageURLs: urls,
                ramp: ramp,
                outputFPS: fps,
                outputURL: output,
                frameTimes: frameTimes,
                profile: profile,
                decodeLinear: support.decode,
                outputGrade: support.hook,
                progress: progress)
        }.value
        var summary = "\(urls.count) photos → \(result.outputFrames) frames · \(result.width)×\(result.height)"
        if profile == .hevcMain10 {
            summary += " · 10-bit HEVC"
        }
        if frameTimes != nil {
            summary += " · timed from capture"
        }
        if !grade.isIdentity {
            summary += " · \(grade.preset.displayName) grade baked in"
        }
        return ProcessingOutput(
            kind: .video,
            url: output,
            image: nil,
            summary: summary,
            inputFrames: urls.count,
            outputFrames: result.outputFrames,
            width: result.width,
            height: result.height
        )
    }

    /// A loader that grades every frame on its way into a blend, or nil for an
    /// untouched grade so the stacker keeps its own decode path.
    ///
    /// Built inside the detached blend task from the grade value alone, so no
    /// closure crosses the concurrency boundary with it.
    nonisolated private static func gradedFrameLoader(_ grade: PhotoGrade) -> ((URL) throws -> CGImage)? {
        guard !grade.isIdentity else { return nil }
        return { url in try PhotoGrader.renderForBlend(url: url, grade: grade) }
    }

    /// Legacy single-image stack: averages every still into one synthetic long
    /// exposure. No longer the default for interval capture — kept for callers
    /// that explicitly want one frame out.
    ///
    /// `grade` bakes the project's colour grade into the stack. Photo mode passes
    /// the identity grade on purpose: its stack IS the project's one asset, and
    /// its grade stays non-destructive — re-derived for the preview and baked
    /// only when the photo is exported.
    private func stackPhotos(
        urls: [URL],
        linear: Bool,
        grade: PhotoGrade = .identity
    ) async throws -> ProcessingOutput {
        // A single frame has nothing to accumulate — the stacker needs at least
        // two — so load it straight through (blend=1 / one-frame-burst edge).
        if urls.count == 1, let only = urls.first {
            let single = grade.isIdentity
                ? loadImage(at: only)
                : try? PhotoGrader.renderForBlend(url: only, grade: grade)
            guard let image = single else { throw LapseError.noInputFrames }
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("LetsLapse-\(Int(Date().timeIntervalSince1970)).png")
            try ImageExporter.write(
                image, to: output, format: .png,
                metadata: ImageExporter.carryoverMetadata(from: only))
            progress = 1
            return ProcessingOutput(
                kind: .image,
                url: output,
                image: image,
                summary: "1 photo · \(image.width)×\(image.height)",
                inputFrames: 1,
                outputFrames: 1,
                width: image.width,
                height: image.height
            )
        }
        let image = try await Task.detached(priority: .userInitiated) { [weak self] () throws -> CGImage in
            let core = try BlendCore()
            let stacker = ImageStacker(core: core)
            return try stacker.stack(
                imageURLs: urls,
                linearLight: linear,
                loadFrame: Self.gradedFrameLoader(grade),
                progress: { fraction in
                    Task { @MainActor in
                        self?.reportClipProgress(0, fraction: fraction)
                    }
                })
        }.value
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-\(Int(Date().timeIntervalSince1970)).png")
        // The stack spans every frame; the first frame's EXIF (capture time =
        // start of the synthetic exposure) and GPS stand for the whole.
        try ImageExporter.write(
            image, to: output, format: .png,
            metadata: urls.first.flatMap { ImageExporter.carryoverMetadata(from: $0) })
        var summary = "\(urls.count) photos stacked · \(image.width)×\(image.height)"
        if !grade.isIdentity {
            summary += " · \(grade.preset.displayName) grade baked in"
        }
        return ProcessingOutput(
            kind: .image,
            url: output,
            image: image,
            summary: summary,
            inputFrames: urls.count,
            outputFrames: 1,
            width: image.width,
            height: image.height
        )
    }

    private func currentBlendParameters() -> BlendProject {
        BlendProject(
            id: UUID(),
            captureID: currentCaptureID ?? UUID(),
            kind: source?.isVideo == true ? .video : .image,
            createdAt: Date(),
            outputFileName: "",
            summary: "",
            compressionRatio: source?.isVideo == true ? constantWindow : photoBlendDepth,
            outputFPS: outputFPS,
            linearLight: linearLight,
            useRamp: useRamp && source?.isVideo == true,
            rampStart: rampStart,
            rampEnd: rampEnd,
            curve: curve.rawValue,
            trimHeadTailSeconds: source?.isVideo == true && trimVideoEnds ? max(0, trimHeadTailSeconds) : nil,
            width: nil,
            height: nil,
            inputFrames: nil,
            outputFrames: nil,
            sourceCodec: source?.isVideo == true ? blendSourceCodec?.rawValue : nil,
            warp: compiledWarp() != nil ? activeWarp() : nil,
            // Gated like `warp`: the reframe only renders through the compiled
            // path, so a ramp render must not record a punch it never baked.
            reframe: compiledWarp() != nil ? reframe : nil,
            canvasRatio: source?.isVideo == true ? effectiveBlendCanvas().rawValue : nil,
            canvasOffset: source?.isVideo == true ? blendCanvasOffset : nil
        )
    }

    private func apply(_ output: ProcessingOutput, from blend: BlendProject) {
        let storedURL = blendOutputURL(for: blend)
        resultBlendID = blend.id
        resultSummary = blend.summary
        resultVideoURL = nil
        resultImage = nil
        resultImageURL = nil

        switch output.kind {
        case .video:
            resultVideoURL = storedURL
        case .image:
            resultImageURL = storedURL
            resultImage = output.image ?? loadImage(at: storedURL)
        }
    }

    private func storeBlend(_ output: ProcessingOutput, captureID: UUID, parameters: BlendProject) throws -> BlendProject {
        let id = parameters.id
        let extensionName = output.kind == .video ? "mp4" : "png"
        let outputFileName = "blends/\(id.uuidString).\(extensionName)"
        let destination = captureFolderURL(for: captureID).appendingPathComponent(outputFileName)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try copyReplacingItem(at: output.url, to: destination)

        var blend = parameters
        blend.captureID = captureID
        blend.kind = output.kind
        blend.outputFileName = outputFileName
        blend.summary = output.summary
        blend.inputFrames = output.inputFrames
        blend.outputFrames = output.outputFrames
        blend.width = output.width
        blend.height = output.height

        blends.append(blend)
        blends.sort { $0.createdAt > $1.createdAt }
        try persistLibrary()
        return blend
    }

    private func registerCapture(from source: Source, mode: String) throws -> CaptureProject {
        let id = UUID()
        let root = captureFolderURL(for: id)
        let sourceFolder = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)

        let capture: CaptureProject
        switch source {
        case .video(let url):
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            let relativeName = "source/original.\(ext)"
            let destination = root.appendingPathComponent(relativeName)
            try copySecurityScopedItem(at: url, to: destination)
            capture = CaptureProject(
                id: id,
                kind: .video,
                createdAt: Date(),
                originalName: url.lastPathComponent,
                mode: mode,
                sourceFileNames: [relativeName],
                sourceFPS: nil
            )
        case .liveSequence(let liveSource):
            return try registerSequenceCapture(LiveCaptureResult(
                sequence: liveSource.sequence,
                segmentURLs: liveSource.segmentURLs,
                metadataURL: liveSource.metadataURL
            ))
        case .photos(let urls):
            var relativeNames: [String] = []
            for (index, url) in urls.enumerated() {
                let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
                let relativeName = String(format: "source/frame-%05d%@", index + 1, ext)
                let destination = root.appendingPathComponent(relativeName)
                try copySecurityScopedItem(at: url, to: destination)
                relativeNames.append(relativeName)
            }
            // A ramped shoot (Holy Grail) records when each frame was actually
            // taken; that sidecar travels with the frames, because it is what
            // lays the finished clip out on the real capture clock instead of
            // assuming even spacing. Deliberately NOT in `sourceFileNames` —
            // that list is the project's frames, and this isn't one.
            if let staging = urls.first?.deletingLastPathComponent() {
                let sidecar = staging.appendingPathComponent(FrameTimestamps.fileName)
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    try? copyReplacingItem(
                        at: sidecar,
                        to: root.appendingPathComponent("source/\(FrameTimestamps.fileName)"))
                }
            }
            capture = CaptureProject(
                id: id,
                kind: .photos,
                createdAt: Date(),
                originalName: "\(relativeNames.count) photos",
                mode: mode,
                sourceFileNames: relativeNames,
                sourceFPS: nil
            )
        }

        captures.insert(capture, at: 0)
        try persistLibrary()
        if capture.kind == .video {
            Task { [weak self] in
                await self?.refreshVideoMetadata(for: capture.id)
            }
        }
        autoTagIfEnabled(capture)
        return capture
    }

    private func registerSequenceCapture(_ result: LiveCaptureResult) throws -> CaptureProject {
        let id = UUID()
        let root = captureFolderURL(for: id)
        let sourceFolder = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)

        var relativeNames: [String] = []
        for (index, url) in result.segmentURLs.enumerated() {
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            let relativeName = String(format: "source/segment-%03d.%@", index, ext)
            let destination = root.appendingPathComponent(relativeName)
            try copyReplacingItem(at: url, to: destination)
            relativeNames.append(relativeName)
        }

        let metadataName = "source/sequence.json"
        try copyReplacingItem(at: result.metadataURL, to: root.appendingPathComponent(metadataName))
        relativeNames.append(metadataName)

        let capture = CaptureProject(
            id: id,
            kind: .video,
            createdAt: result.sequence.createdAt,
            originalName: result.sequence.mode == .ramp ? "Ramp capture" : "Marker capture",
            mode: result.sequence.summary,
            sourceFileNames: relativeNames,
            sourceFPS: nil
        )

        captures.insert(capture, at: 0)
        try persistLibrary()
        Task { [weak self] in
            await self?.refreshVideoMetadata(for: capture.id)
        }
        autoTagIfEnabled(capture)
        return capture
    }

    private func source(
        for capture: CaptureProject,
        preferring codec: OutputCodec? = nil
    ) throws -> Source {
        let root = captureFolderURL(for: capture.id)
        let metadataURL = root.appendingPathComponent("source/sequence.json")
        let clipNames = capture.sourceFileNames.filter { !$0.hasSuffix(".json") }

        switch capture.kind {
        case .photos:
            let urls = clipNames.map { root.appendingPathComponent($0) }
            for url in urls where !FileManager.default.fileExists(atPath: url.path) {
                throw CocoaError(.fileNoSuchFile)
            }
            return .photos(urls)
        case .video:
            // Each logical clip resolves to the preferred codec when present,
            // else its best surviving encoding — so deleting a ProRes original
            // (once converted) doesn't break playback or blending.
            var resolvedURLs: [URL] = []
            var resolvedByName: [String: URL] = [:]
            for relName in clipNames {
                guard let url = activeEncodingURL(for: capture, clip: relName, preferring: codec) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                resolvedURLs.append(url)
                resolvedByName[(relName as NSString).lastPathComponent] = url
            }

            if FileManager.default.fileExists(atPath: metadataURL.path) {
                let data = try Data(contentsOf: metadataURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let sequence = try decoder.decode(LiveCaptureSequence.self, from: data)
                return .liveSequence(LiveCaptureSource(
                    sequence: sequence,
                    segmentURLs: resolvedURLs,
                    metadataURL: metadataURL,
                    resolvedByOriginalName: resolvedByName
                ))
            }
            guard let url = resolvedURLs.first else { throw CocoaError(.fileNoSuchFile) }
            return .video(url)
        }
    }

    /// Library-level migration marker, mirrored from the manifest; see
    /// `stampLegacyDefaultPresetsIfNeeded`.
    private var gradingSchemaVersion = 0

    private func loadLibrary() {
        do {
            try migrateLegacyApplicationSupportFolderIfNeeded()
            try FileManager.default.createDirectory(at: projectsRootURL, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(LibraryManifest.self, from: data)
            captures = manifest.captures.sorted { $0.createdAt > $1.createdAt }
            blends = manifest.blends.sorted { $0.createdAt > $1.createdAt }
            // Oldest first — a collection list reads in creation order.
            collections = (manifest.collections ?? []).sorted { $0.createdAt < $1.createdAt }
            gradingSchemaVersion = manifest.gradingSchemaVersion ?? 0
            stampLegacyDefaultPresetsIfNeeded()
            for capture in captures
            where capture.kind == .video
                && (capture.sourceFPS == nil || capture.sourceDurationSeconds == nil
                    || capture.sourceWidth == nil || capture.sourceSegmentSeconds == nil
                    || capture.sourceSegmentFPS == nil) {
                Task { [weak self] in
                    await self?.refreshVideoMetadata(for: capture.id)
                }
            }
        } catch {
            errorMessage = "Couldn't load the project library: \(error.localizedDescription)"
        }
    }

    /// One-time migration for the engine rebuild's default flip: projects
    /// that never chose a preset used to *render* Natural (the old implicit
    /// default), so write "Natural" into them explicitly before the default
    /// becomes Original — nothing in the library changes appearance, and only
    /// new captures start clean.
    private func stampLegacyDefaultPresetsIfNeeded() {
        guard gradingSchemaVersion < 1 else { return }
        gradingSchemaVersion = 1
        for index in captures.indices where captures[index].selectedPreset == nil {
            captures[index].selectedPreset = PhotoPreset.natural.rawValue
        }
        try? persistLibrary()
    }

    private func persistLibrary() throws {
        // Every path that adds, converts, rotates or deletes a project's files
        // ends here, so this is the one place that has to drop the size cache.
        projectStorageBytes.removeAll()
        try FileManager.default.createDirectory(at: projectsRootURL, withIntermediateDirectories: true)
        var manifest = LibraryManifest(captures: captures, blends: blends, collections: collections)
        manifest.gradingSchemaVersion = max(gradingSchemaVersion, 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LetsLapse", isDirectory: true)
    }

    private var legacyApplicationSupportURL: URL {
        let legacyName = ["Let", "s Lapse"].joined(separator: "'")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(legacyName, isDirectory: true)
    }

    private func migrateLegacyApplicationSupportFolderIfNeeded() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyApplicationSupportURL.path),
              !fileManager.fileExists(atPath: applicationSupportURL.path)
        else { return }

        try fileManager.moveItem(at: legacyApplicationSupportURL, to: applicationSupportURL)
    }

    private var projectsRootURL: URL {
        applicationSupportURL.appendingPathComponent("Projects", isDirectory: true)
    }

    private var manifestURL: URL {
        projectsRootURL.appendingPathComponent("library.json")
    }

    private func captureFolderURL(for id: UUID) -> URL {
        projectsRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func blendOutputURL(for blend: BlendProject) -> URL {
        captureFolderURL(for: blend.captureID).appendingPathComponent(blend.outputFileName)
    }

    private func copySecurityScopedItem(at source: URL, to destination: URL) throws {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                source.stopAccessingSecurityScopedResource()
            }
        }
        try copyReplacingItem(at: source, to: destination)
    }

    private func copyReplacingItem(at source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func loadImage(at url: URL) -> CGImage? {
        // EXIF-orientation-aware load (a bare index-0 decode draws captured
        // originals sideways — the result preview and single-frame stack
        // output both read camera files).
        try? ImageStacker.loadImage(at: url)
    }

    private func refreshVideoMetadata(for captureID: UUID) async {
        guard let capture = captures.first(where: { $0.id == captureID }),
              let captureSource = try? source(for: capture) else { return }

        // Probe maps are keyed by the sidecar's LOGICAL segment name — the
        // key warpSourceRegions/healWarpAxis/warpFrameLocation look up — not
        // by the resolved file's name. They differ once a clip's ProRes
        // original is purged after conversion: resolution then lands on the
        // "-h264"/"-hevc" sibling, and a map keyed by that name silently
        // misses every lookup while reading as a completed probe.
        let entries: [(name: String, url: URL)]
        switch captureSource {
        case .video(let url):
            entries = [(url.lastPathComponent, url)]
        case .liveSequence(let liveSource):
            let ordered = liveSource.sequence.segments.sorted { $0.index < $1.index }
            if ordered.isEmpty {
                entries = liveSource.segmentURLs.map { ($0.lastPathComponent, $0) }
            } else {
                entries = ordered.compactMap { segment in
                    liveSource.resolvedByOriginalName[segment.fileName].map { (segment.fileName, $0) }
                }
            }
        case .photos:
            return
        }

        var totalDuration: Double = 0
        var segmentSeconds: [String: Double] = [:]
        var segmentFPS: [String: Double] = [:]
        var segmentSize: [String: String] = [:]
        var fps: Double?
        var width: Int?
        var height: Int?

        for (name, url) in entries {
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration).seconds, duration.isFinite {
                totalDuration += duration
                segmentSeconds[name] = duration
            }
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            // The DELIVERED rate, probed per segment: nominalFrameRate is
            // samples ÷ duration, so a burst that dropped frames reports what
            // it really wrote, not what the sidecar promised.
            if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
                if fps == nil { fps = Double(rate) }
                segmentFPS[name] = Double(rate)
            }
            // Probed for EVERY segment, unlike the project-level pair below:
            // that one deliberately latches on the first (the base), this one
            // records what each file really holds.
            if let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let rect = CGRect(origin: .zero, size: size).applying(transform).standardized
                if rect.width > 0, rect.height > 0 {
                    let segmentWidth = Int(abs(rect.width).rounded())
                    let segmentHeight = Int(abs(rect.height).rounded())
                    segmentSize[name] = "\(segmentWidth)x\(segmentHeight)"
                    if width == nil {
                        width = segmentWidth
                        height = segmentHeight
                    }
                }
            }
        }

        guard let index = captures.firstIndex(where: { $0.id == captureID }) else { return }
        if let fps { captures[index].sourceFPS = fps }
        if totalDuration > 0 { captures[index].sourceDurationSeconds = totalDuration }
        // Merge, never replace: a segment whose file couldn't be read this
        // pass must not erase a truth an earlier pass established.
        if !segmentSeconds.isEmpty {
            captures[index].sourceSegmentSeconds = (captures[index].sourceSegmentSeconds ?? [:])
                .merging(segmentSeconds) { _, probed in probed }
        }
        if !segmentFPS.isEmpty {
            captures[index].sourceSegmentFPS = (captures[index].sourceSegmentFPS ?? [:])
                .merging(segmentFPS) { _, probed in probed }
        }
        if !segmentSize.isEmpty {
            captures[index].sourceSegmentSize = (captures[index].sourceSegmentSize ?? [:])
                .merging(segmentSize) { _, probed in probed }
        }
        if let width, let height {
            captures[index].sourceWidth = width
            captures[index].sourceHeight = height
        }
        try? persistLibrary()
    }

    // MARK: - Clip conversion

    enum ConvertClipError: LocalizedError {
        case noVideoTrack
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                return "This clip has no video track to convert."
            case .encodingFailed(let reason):
                return "Couldn't convert the clip: \(reason)"
            }
        }
    }

    private static let conversionQueue = DispatchQueue(
        label: "com.letslapse.convert", qos: .userInitiated)

    /// FourCC subtypes for the ProRes family, matching the capture-side check
    /// in `CameraController`: 'apcn' 422, 'apch' 422 HQ, 'apcs' 422 LT,
    /// 'apco' 422 Proxy, 'ap4h' 4444, 'ap4x' 4444 XQ.
    private static let proResFourCCs: Set<FourCharCode> = [
        0x6170636e, 0x61706368, 0x61706373, 0x6170636f, 0x61703468, 0x61703478,
    ]

    /// Whether a clip's video track is encoded with a ProRes codec — the cue
    /// for offering a smaller-file H.264/HEVC conversion.
    nonisolated static func sourceClipIsProRes(at url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let descriptions = try? await track.load(.formatDescriptions)
        else { return false }
        return descriptions.contains {
            proResFourCCs.contains(CMFormatDescriptionGetMediaSubType($0))
        }
    }

    enum EncodingDeletionError: LocalizedError {
        case lastEncoding

        var errorDescription: String? {
            switch self {
            case .lastEncoding:
                return "This is the clip's only file. Convert it to another format before deleting this one."
            }
        }
    }

    /// The logical source clips of a capture, as their original relative file
    /// names (the stable identity used to key encodings).
    func sourceClipNames(for capture: CaptureProject) -> [String] {
        capture.sourceFileNames.filter { !$0.hasSuffix(".json") }
    }

    /// Absolute URL of a specific encoding inside the capture folder.
    func encodingURL(for capture: CaptureProject, _ encoding: ClipEncoding) -> URL {
        captureFolderURL(for: capture.id).appendingPathComponent(encoding.fileName)
    }

    /// Every encoding of one logical clip: the stored list once the clip has
    /// been converted, otherwise the implicit single original file.
    func encodings(for capture: CaptureProject, clip clipFileName: String) -> [ClipEncoding] {
        if let stored = capture.clipEncodings?[clipFileName], !stored.isEmpty {
            return stored
        }
        return [ClipEncoding(codec: "", fileName: clipFileName)]
    }

    /// The file the app should actually use for a logical clip — the preferred
    /// codec when it exists, else the best surviving encoding (quality-first).
    func activeEncodingURL(
        for capture: CaptureProject,
        clip clipFileName: String,
        preferring codec: OutputCodec? = nil
    ) -> URL? {
        let existing = encodings(for: capture, clip: clipFileName).filter {
            FileManager.default.fileExists(atPath: encodingURL(for: capture, $0).path)
        }
        guard !existing.isEmpty else { return nil }
        if let codec, let match = existing.first(where: { $0.codec == codec.rawValue }) {
            return encodingURL(for: capture, match)
        }
        let priority = [OutputCodec.prores.rawValue, OutputCodec.hevc.rawValue, OutputCodec.h264.rawValue]
        let chosen = priority.compactMap { rawValue in
            existing.first { $0.codec == rawValue }
        }.first ?? existing[0]
        return encodingURL(for: capture, chosen)
    }

    /// Codecs the blend can draw from across all of a capture's clips, ordered
    /// quality-first. Empty when there's no real choice (nothing converted yet).
    func availableBlendCodecs(for capture: CaptureProject) -> [OutputCodec] {
        var present: Set<String> = []
        for clipName in sourceClipNames(for: capture) {
            for encoding in encodings(for: capture, clip: clipName)
            where FileManager.default.fileExists(atPath: encodingURL(for: capture, encoding).path) {
                present.insert(encoding.codec)
            }
        }
        let available: [OutputCodec] = [.prores, .hevc, .h264].filter { present.contains($0.rawValue) }
        return available.count > 1 ? available : []
    }

    /// Re-point the in-flight blend source at a specific codec (`nil` = auto,
    /// best surviving encoding per clip). Used by the Adjust "Blend from" picker.
    func setBlendSourceCodec(_ codec: OutputCodec?) {
        blendSourceCodec = codec
        guard let capture = currentCapture else { return }
        source = try? source(for: capture, preferring: codec)
    }

    /// Re-encodes a ProRes source clip into a sibling file inside the project's
    /// `source/` folder and registers it as an extra encoding of that clip.
    @discardableResult
    func addEncoding(
        for capture: CaptureProject,
        clip clipFileName: String,
        codec: OutputCodec
    ) async throws -> URL {
        let root = captureFolderURL(for: capture.id)
        let sourceURL = root.appendingPathComponent(clipFileName)
        let base = ((clipFileName as NSString).lastPathComponent as NSString).deletingPathExtension
        let newRelName = "source/\(base)-\(codec.rawValue).\(codec.preferredExtension)"
        let outputURL = root.appendingPathComponent(newRelName)
        try await Self.transcode(from: sourceURL, to: outputURL, codec: codec)

        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return outputURL }
        // Materialise the original as its own (ProRes) encoding the first time.
        var list = captures[index].clipEncodings?[clipFileName]
            ?? [ClipEncoding(codec: OutputCodec.prores.rawValue, fileName: clipFileName)]
        if !list.contains(where: { $0.fileName == newRelName }) {
            list.append(ClipEncoding(codec: codec.rawValue, fileName: newRelName))
        }
        var map = captures[index].clipEncodings ?? [:]
        map[clipFileName] = list
        captures[index].clipEncodings = map
        try persistLibrary()
        return outputURL
    }

    /// Deletes one encoding of a clip, including the ProRes original once a
    /// conversion exists. Refuses to remove a clip's only remaining file.
    func deleteEncoding(
        for capture: CaptureProject,
        clip clipFileName: String,
        _ encoding: ClipEncoding
    ) throws {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        // Read the live capture, not the caller's snapshot, so a delete that
        // follows a convert (e.g. bulk purge) sees the newly added encoding.
        let fresh = captures[index]
        let list = encodings(for: fresh, clip: clipFileName)
        let existing = list.filter {
            FileManager.default.fileExists(atPath: encodingURL(for: fresh, $0).path)
        }
        guard existing.count > 1 else { throw EncodingDeletionError.lastEncoding }

        let url = encodingURL(for: fresh, encoding)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let newList = list.filter { $0.fileName != encoding.fileName }
        var map = captures[index].clipEncodings ?? [:]
        map[clipFileName] = newList
        captures[index].clipEncodings = map.isEmpty ? nil : map
        try persistLibrary()
    }

    /// One-tap storage reclaim: convert every ProRes clip in a capture to H.264
    /// and delete the ProRes originals. Skips clips already free of ProRes.
    enum RotateScope {
        /// Sources plus every already-rendered blend and encoding, so all
        /// thumbnails, versions and exports stay coherent.
        case wholeProject
        /// Originals only; existing rendered outputs keep their orientation.
        case sourcesOnly
    }

    /// Every file that must rotate together for one project, grouped by
    /// rotation mechanism.
    private struct RotatableMedia {
        var stills: [URL] = []
        var dngs: [URL] = []
        var videos: [URL] = []
        var all: [URL] { stills + dngs + videos }
    }

    private func rotatableMedia(for capture: CaptureProject, scope: RotateScope) -> RotatableMedia {
        var media = RotatableMedia()
        func classify(_ url: URL) {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            switch url.pathExtension.lowercased() {
            case "dng": media.dngs.append(url)
            case "jpg", "jpeg", "heic", "heif", "png": media.stills.append(url)
            case "mov", "qt", "mp4", "m4v": media.videos.append(url)
            default: break
            }
        }

        let root = captureFolderURL(for: capture.id)
        switch capture.kind {
        case .photos:
            for name in capture.sourceFileNames where !name.hasSuffix(".json") {
                classify(root.appendingPathComponent(name))
            }
        case .video:
            // Every surviving encoding of every clip, so ProRes originals and
            // H.264/HEVC conversions stay in step.
            for clipName in sourceClipNames(for: capture) {
                for encoding in encodings(for: capture, clip: clipName) {
                    classify(encodingURL(for: capture, encoding))
                }
            }
        }
        if scope == .wholeProject {
            for blend in blends(for: capture) {
                classify(mediaURL(for: blend))
            }
        }
        return media
    }

    /// Rotates every media file of a project 90° clockwise, metadata-only:
    /// EXIF/TIFF orientation for stills and DNGs, `preferredTransform` for
    /// video — nothing is re-encoded (PNG blends rotate losslessly). Stops at
    /// the first failure; files already processed stay rotated, and because
    /// the walk order is deterministic, tapping Rotate again after fixing the
    /// problem completes the same pass.
    func rotateProjectMedia(_ capture: CaptureProject, scope: RotateScope = .wholeProject) async throws {
        let media = rotatableMedia(for: capture, scope: scope)
        // Even a partial rotate changed files — refresh thumbnails regardless.
        defer { ProjectThumbnailCache.shared.invalidate(urls: media.all) }
        try await Task.detached(priority: .userInitiated) {
            for url in media.stills { try MediaRotator.rotateStill90CW(at: url) }
            for url in media.dngs { try MediaRotator.rotateDNG90CW(at: url) }
            for url in media.videos { try await MediaRotator.rotateVideo90CW(at: url) }
        }.value

        // Swap the persisted dimensions so format badges match immediately.
        if let index = captures.firstIndex(where: { $0.id == capture.id }),
           let width = captures[index].sourceWidth,
           let height = captures[index].sourceHeight {
            captures[index].sourceWidth = height
            captures[index].sourceHeight = width
        }
        for index in blends.indices where blends[index].captureID == capture.id {
            if let width = blends[index].width, let height = blends[index].height {
                blends[index].width = height
                blends[index].height = width
            }
        }
        try persistLibrary()
        if capture.kind == .video {
            // Belt and braces: re-derive video dimensions from the transforms
            // actually on disk (also persists).
            await refreshVideoMetadata(for: capture.id)
        }
    }

    func convertAllProResToH264Purging(for capture: CaptureProject) async throws {
        for clipName in sourceClipNames(for: capture) {
            let originalURL = captureFolderURL(for: capture.id).appendingPathComponent(clipName)
            guard FileManager.default.fileExists(atPath: originalURL.path),
                  await Self.sourceClipIsProRes(at: originalURL) else { continue }
            _ = try await addEncoding(for: capture, clip: clipName, codec: .h264)
            let proResEncoding = ClipEncoding(codec: OutputCodec.prores.rawValue, fileName: clipName)
            try deleteEncoding(for: capture, clip: clipName, proResEncoding)
        }
    }

    nonisolated private static func transcode(
        from sourceURL: URL,
        to outputURL: URL,
        codec: OutputCodec
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            throw ConvertClipError.noVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = (try? await videoTrack.load(.nominalFrameRate)) ?? 30
        let fps = nominalFPS > 0 ? Double(nominalFPS) : 30
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conversionQueue.async {
                do {
                    try runConversion(
                        asset: asset,
                        videoTrack: videoTrack,
                        naturalSize: naturalSize,
                        transform: transform,
                        fps: fps,
                        audioTrack: audioTrack ?? nil,
                        outputURL: outputURL,
                        codec: codec
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Blocking reader → writer transcode. Runs on `conversionQueue`; the media
    /// pumps run on their own queues so the `DispatchGroup.wait()` here is safe.
    nonisolated private static func runConversion(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        naturalSize: CGSize,
        transform: CGAffineTransform,
        fps: Double,
        audioTrack: AVAssetTrack?,
        outputURL: URL,
        codec: OutputCodec
    ) throws {
        try? FileManager.default.removeItem(at: outputURL)

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: codec.fileType)
        } catch {
            throw ConvertClipError.encodingFailed(error.localizedDescription)
        }

        // HEVC is encoded 10-bit (Main10) to preserve the ProRes gradient, so it
        // decodes to a 10-bit pixel format; every other codec path stays 8-bit.
        let readerPixelFormat: OSType = codec == .hevc
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: readerPixelFormat])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ConvertClipError.encodingFailed("cannot read the video track")
        }
        reader.add(videoOutput)

        let width = Int(abs(naturalSize.width))
        let height = Int(abs(naturalSize.height))
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        // The shared policy carries the generous, resolution-aware bitrate (so
        // re-encoding doesn't introduce compression banding) plus the colour
        // tags every writer stamps now.
        switch codec {
        case .h264, .hevc:
            videoSettings = VideoEncodePolicy(
                profile: codec == .hevc ? .hevcMain10 : .h264High8Bit,
                width: width, height: height, fps: fps).videoSettings
        case .jpeg:
            videoSettings[AVVideoCompressionPropertiesKey] = [AVVideoQualityKey: 0.95]
        case .prores:
            break
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else {
            throw ConvertClipError.encodingFailed("cannot write the video track")
        }
        writer.add(videoInput)

        // Passthrough audio: nil settings on both ends copies samples verbatim.
        var audioPair: (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audioPair = (output, input)
            }
        }

        guard reader.startReading() else {
            throw ConvertClipError.encodingFailed(
                reader.error?.localizedDescription ?? "could not start reading")
        }
        guard writer.startWriting() else {
            throw ConvertClipError.encodingFailed(
                writer.error?.localizedDescription ?? "could not start writing")
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()

        group.enter()
        videoInput.requestMediaDataWhenReady(
            on: DispatchQueue(label: "com.letslapse.convert.video")) {
            while videoInput.isReadyForMoreMediaData {
                if let sample = videoOutput.copyNextSampleBuffer() {
                    if !videoInput.append(sample) {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                } else {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
            }
        }

        if let audioPair {
            group.enter()
            audioPair.input.requestMediaDataWhenReady(
                on: DispatchQueue(label: "com.letslapse.convert.audio")) {
                while audioPair.input.isReadyForMoreMediaData {
                    if let sample = audioPair.output.copyNextSampleBuffer() {
                        if !audioPair.input.append(sample) {
                            audioPair.input.markAsFinished()
                            group.leave()
                            return
                        }
                    } else {
                        audioPair.input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }

        group.wait()

        if reader.status == .reading { reader.cancelReading() }
        if reader.status == .failed {
            throw ConvertClipError.encodingFailed(
                reader.error?.localizedDescription ?? "reading failed")
        }

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw ConvertClipError.encodingFailed(
                writer.error?.localizedDescription ?? "could not finalize the file")
        }
    }

    // MARK: - Project archives (share / import)

    /// The archive being brought in, from the moment it is accepted until it
    /// joins the library — nil the rest of the time. Drives the import sheet,
    /// which is presented over everything because an import can start with no
    /// LetsLapse window in front of the human at all.
    @Published var archiveImport: ArchiveImport?
    /// Every archive accepted and not yet finished — the one being imported at
    /// the head, anything opened behind it after. Drained one at a time (two
    /// concurrent extractions would race for the same disk), and claimed
    /// synchronously in `openArchive` so two delivery paths landing in the same
    /// run-loop turn can't both start the same file.
    private var archiveImportURLs: [URL] = []
    private var archiveImportCancellation: ArchiveImportCancellation?
    /// The import paused on the duplicate question, waiting for the sheet's
    /// answer. Its staging tree is still on disk — the import is suspended
    /// inside `importProject`, not abandoned.
    private var duplicateImportDecision: CheckedContinuation<Bool, Never>?

    enum ExportError: LocalizedError {
        case insufficientStorage(available: Int64, needed: Int64)

        var errorDescription: String? {
            switch self {
            case .insufficientStorage(let available, let needed):
                return """
                Not enough storage to export this project. It needs \
                \(LLFormat.bytes(needed)) but only \(LLFormat.bytes(available)) is available. \
                Free up space and try again.
                """
            }
        }
    }

    enum ImportError: LocalizedError {
        case insufficientStorage(available: Int64, needed: Int64)

        var errorDescription: String? {
            switch self {
            case .insufficientStorage(let available, let needed):
                return """
                Not enough storage to import this project. It unpacks to at least \
                \(LLFormat.bytes(needed)) but only \(LLFormat.bytes(available)) is available. \
                Free up space and try again.
                """
            }
        }
    }

    /// Builds a portable `.lapse` archive of one project: `project.json`
    /// (capture + its blend entries) beside the project's `source/` and
    /// `blends/` trees. The manifest is written into the project folder for
    /// the duration of the archive pass so multi-gigabyte projects aren't
    /// duplicated on disk first.
    func exportProject(_ capture: CaptureProject) async throws -> URL {
        let manifest = ProjectArchiveManifest(capture: capture, blends: blends(for: capture))
        let folder = captureFolderURL(for: capture.id)

        let rawName = capture.name ?? capture.originalName
        let safeName = rawName
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_")).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName.isEmpty ? "LetsLapse Project" : safeName).\(ProjectArchive.fileExtension)")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestURL = folder.appendingPathComponent("project.json")
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: manifestURL) }

        try await Task.detached(priority: .userInitiated) {
            // lzfse shrinks the tree, but stills/ProRes barely compress, so the
            // uncompressed size is the honest bar: better to refuse up front
            // than to fill the disk and fail mid-write.
            let needed = Self.directorySize(folder)
            let available = (try? archiveURL
                .deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage) ?? 0
            if needed > 0, available < needed {
                throw ExportError.insufficientStorage(available: available, needed: needed)
            }
            try ProjectArchive.write(contentsOf: folder, to: archiveURL)
        }.value
        return archiveURL
    }

    /// A `.lapse` file handed to the app from outside — a Finder double-click or
    /// "Open With", a drop on the Dock icon, the Files app on iOS — or picked in
    /// Create. The single door in: it dedupes, queues, and puts the progress
    /// sheet up, none of which `importProject` does for itself.
    func openArchive(at url: URL) {
        guard ProjectArchive.isArchive(url) else {
            errorMessage = "\(url.lastPathComponent) isn't a LetsLapse project archive."
            return
        }
        // The same file can be delivered twice — the Finder's open event and the
        // scene's own URL handling both fire on some launches. Importing it
        // twice would quietly leave two copies of a multi-gigabyte project.
        guard !archiveImportURLs.contains(url) else { return }
        archiveImportURLs.append(url)
        guard archiveImportURLs.count == 1 else { return }
        Task { await importProject(from: url) }
    }

    /// Stops the extraction in flight. Not an error: the sheet closes, the
    /// half-extracted tree is deleted, and nothing joins the library.
    func cancelArchiveImport() {
        archiveImportCancellation?.cancel()
    }

    /// The project this archive was already imported as, if any.
    ///
    /// Matches on the id the archive carries in its manifest, against both the
    /// ids of projects here and the origins recorded on projects imported
    /// earlier — so re-opening the same file finds the copy it made last time,
    /// and an archive exported from this Mac finds the project it came from.
    private func existingImport(of originID: UUID) -> CaptureProject? {
        captures.first { $0.id == originID || $0.importedFromID == originID }
    }

    /// Answers the "you already have this" question. `importAgain` true makes a
    /// second, independent project; false leaves the library alone. Either way
    /// a project opens — the new one or the one already here.
    func resolveDuplicateImport(importAgain: Bool) {
        let pending = duplicateImportDecision
        duplicateImportDecision = nil
        pending?.resume(returning: importAgain)
    }

    /// Closes a finished-but-failed import — the only phase that waits for the
    /// human — and starts whatever was opened behind it.
    func dismissArchiveImport() {
        finishArchiveImport()
    }

    /// Retires the archive at the head of the queue and starts the next.
    private func finishArchiveImport() {
        archiveImport = nil
        if !archiveImportURLs.isEmpty { archiveImportURLs.removeFirst() }
        guard let next = archiveImportURLs.first else { return }
        Task { await importProject(from: next) }
    }

    /// Restores a `.lapse` archive as a new project. Fresh UUIDs are minted
    /// for the capture and every blend (folder names and lookups key on
    /// them, so reusing the originals would collide with re-imports or the
    /// source device's own library).
    ///
    /// A project is gigabytes and this takes minutes, so it reports itself
    /// through `archiveImport` throughout and can be stopped. Nothing is
    /// published to the library until the whole tree is on disk: a cancelled or
    /// failed import leaves no half-project behind.
    private func importProject(from pickedURL: URL) async {
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { pickedURL.stopAccessingSecurityScopedResource() }
        }
        let staging = ImportStaging.makeURL()
        defer { try? FileManager.default.removeItem(at: staging) }

        let archiveBytes = Int64(
            (try? pickedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let progress = ArchiveImport(
            url: pickedURL,
            name: pickedURL.deletingPathExtension().lastPathComponent,
            archiveBytes: archiveBytes)
        archiveImport = progress

        let cancellation = ArchiveImportCancellation()
        archiveImportCancellation = cancellation
        let meter = ArchiveImportMeter()
        // The archiver calls back per entry from its own worker threads —
        // thousands of times for an interval project. Sampling the meter on a
        // timer instead keeps that off the main actor entirely, and 5 Hz is
        // already faster than a progress bar reads.
        let ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, self.archiveImport?.id == progress.id else { return }
                self.archiveImport?.extractedBytes = meter.bytes
            }
        }
        defer {
            ticker.cancel()
            if archiveImportCancellation === cancellation { archiveImportCancellation = nil }
        }

        do {
            // lzfse barely shrinks video and stills, so the archive's own size
            // is a fair floor for what it will unpack to. Refusing here beats
            // filling the disk and failing somewhere in the middle.
            let available = Int64(
                (try? FileManager.default.temporaryDirectory
                    .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage) ?? 0)
            if archiveBytes > 0, available < archiveBytes {
                throw ImportError.insufficientStorage(available: available, needed: archiveBytes)
            }

            archiveImport?.phase = .extracting
            try await Task.detached(priority: .userInitiated) {
                try ProjectArchive.extract(
                    pickedURL,
                    to: staging,
                    shouldContinue: { !cancellation.isCancelled },
                    progress: { meter.record($0) })
            }.value
            archiveImport?.phase = .installing

            let manifestURL = staging.appendingPathComponent("project.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                throw ProjectArchiveError.notAProjectArchive
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(ProjectArchiveManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.formatVersion == 1 else {
                throw ProjectArchiveError.unsupportedVersion(manifest.formatVersion)
            }

            // Asked here, after unpacking, rather than before: the id that
            // identifies the archive lives in `project.json` *inside* it, and
            // finding that without a full pass would mean decompressing the
            // whole stream a second time on every import to spare the rare
            // re-import. The staged tree waits on disk while the question is
            // open, and is deleted with the rest if the answer is no.
            let originID = manifest.capture.id
            if let existing = existingImport(of: originID) {
                archiveImport?.phase = .duplicate(existingName: existing.name ?? existing.originalName)
                let importAgain = await withCheckedContinuation { continuation in
                    duplicateImportDecision = continuation
                }
                guard importAgain else {
                    finishArchiveImport()
                    requestedProjectDetailID = existing.id
                    return
                }
                archiveImport?.phase = .installing
            }

            var capture = manifest.capture
            let newID = UUID()
            capture.id = newID
            capture.importedFromID = originID
            let destination = captureFolderURL(for: newID)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for subfolder in ["source", "blends"] {
                let extracted = staging.appendingPathComponent(subfolder)
                if FileManager.default.fileExists(atPath: extracted.path) {
                    try FileManager.default.moveItem(at: extracted, to: destination.appendingPathComponent(subfolder))
                }
            }

            var importedBlends: [BlendProject] = []
            for blendEntry in manifest.blends {
                var blend = blendEntry
                let extractedFile = destination.appendingPathComponent(blend.outputFileName)
                guard FileManager.default.fileExists(atPath: extractedFile.path) else { continue }
                let newBlendID = UUID()
                let fileExtension = (blend.outputFileName as NSString).pathExtension
                let newFileName = "blends/\(newBlendID.uuidString).\(fileExtension)"
                do {
                    try FileManager.default.moveItem(at: extractedFile, to: destination.appendingPathComponent(newFileName))
                } catch {
                    continue
                }
                blend.id = newBlendID
                blend.captureID = newID
                blend.outputFileName = newFileName
                importedBlends.append(blend)
            }

            captures.insert(capture, at: 0)
            blends.append(contentsOf: importedBlends)
            try persistLibrary()
            finishArchiveImport()
            // Land on the project itself rather than opening a blend flow over
            // it: importing is "here is the thing", not "start editing it".
            requestedProjectDetailID = capture.id
        } catch is CancellationError {
            finishArchiveImport()
        } catch DirectoryArchiveError.cancelled {
            // The human stopped it — say nothing, just tidy up and move on.
            finishArchiveImport()
        } catch {
            // Held on screen rather than dropped into `errorMessage`: a
            // double-click import can happen with no LetsLapse window in front
            // of the human, and a banner on the Create screen would go unread.
            archiveImport?.phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Colour grading

    /// The grade currently selected for a capture — Photo, Interval or Video
    /// (default when the project predates grading or stored an unknown value).
    /// Platform-neutral: the grading card renders on macOS too — only the Photos
    /// export below is iOS-only.
    func photoPreset(for capture: CaptureProject) -> PhotoPreset {
        PhotoPreset.resolve(capture.selectedPreset)
    }

    /// The project's whole grade — preset plus sliders — as one value, for the
    /// render and export paths that take both together.
    func photoGrade(for capture: CaptureProject) -> PhotoGrade {
        PhotoGrade(preset: photoPreset(for: capture), adjustments: photoAdjustments(for: capture))
    }

    /// Selects a colour grade for a capture and persists it. The stored original
    /// files are never touched — only the preset name changes.
    func setPhotoPreset(_ preset: PhotoPreset, for capture: CaptureProject) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        guard captures[index].selectedPreset != preset.rawValue else { return }
        captures[index].selectedPreset = preset.rawValue
        try? persistLibrary()
    }

    /// The manual slider grade layered on the preset. Projects saved before the
    /// sliders existed have none, which means "the preset on its own".
    func photoAdjustments(for capture: CaptureProject) -> PhotoAdjustments {
        capture.adjustments ?? .neutral
    }

    /// Stores the manual grade for a photo capture. Like the preset, this only
    /// records numbers — the file on disk is untouched until an export bakes
    /// them in.
    func setPhotoAdjustments(_ adjustments: PhotoAdjustments, for capture: CaptureProject) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        guard captures[index].adjustments != adjustments else { return }
        captures[index].adjustments = adjustments
        try? persistLibrary()
    }

    /// Applies a saved grade wholesale: its base preset and its slider values,
    /// in one persisted change.
    func applyCustomPreset(_ preset: CustomPreset, for capture: CaptureProject) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        guard captures[index].selectedPreset != preset.basePreset.rawValue
                || captures[index].adjustments != preset.adjustments else { return }
        captures[index].selectedPreset = preset.basePreset.rawValue
        captures[index].adjustments = preset.adjustments
        try? persistLibrary()
    }

    /// One of a capture's assets as the viewer shows it, ready to leave the app:
    /// the project's grade baked into a temporary copy — a still through the
    /// image grader, a clip through a video composition pass. Every "this asset
    /// as I'm looking at it" export starts here; the platform tails (Photos on
    /// iOS, a save panel on macOS) decide where the file goes.
    ///
    /// When the grade is `Original` *and* the sliders are neutral the original
    /// URL comes back with `isTemporary` false, so an ungraded project still
    /// hands over its DNG as a DNG and its ProRes as ProRes. Anything else is
    /// rendered (a still becomes a JPEG, a clip is re-encoded) into a temp file
    /// the caller owns and must delete, leaving the on-disk original alone.
    func gradedExportCopy(
        of url: URL, for capture: CaptureProject
    ) async throws -> (url: URL, isTemporary: Bool) {
        let grade = photoGrade(for: capture)
        guard !grade.isIdentity else { return (url, false) }
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        let graded: URL
        if isImage {
            graded = try await Task.detached(priority: .userInitiated) {
                try PhotoGrader.renderJPEG(
                    url: url, preset: grade.preset, adjustments: grade.adjustments)
            }.value
        } else {
            graded = try await VideoGrader.bakedCopy(of: url, grade: grade)
        }
        return (graded, true)
    }

    #if os(iOS)
    enum SourceClipSaveError: LocalizedError {
        case accessDenied
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Photos access was denied. Enable it in Settings to save clips."
            case .saveFailed(let reason):
                return "Couldn't save the clip: \(reason)"
            }
        }
    }
    /// Saves a photo capture to Photos with its selected grade baked in.
    func saveGradedPhoto(for capture: CaptureProject) async throws {
        guard let url = heroImageURL(for: capture) else {
            throw SourceClipSaveError.saveFailed("the photo is missing")
        }
        try await saveGradedAsset(at: url, for: capture)
    }

    /// Saves one of a capture's assets to Photos as `gradedExportCopy` renders
    /// it. Every mode's export to Photos comes through here: the photo, an
    /// interval frame from the browser, a video source clip.
    func saveGradedAsset(at url: URL, for capture: CaptureProject) async throws {
        let (graded, isTemporary) = try await gradedExportCopy(of: url, for: capture)
        guard isTemporary else {
            try await saveSourceClip(at: graded)
            return
        }
        defer { try? FileManager.default.removeItem(at: graded) }
        // Grading re-encodes, which leaves the copy without the original's
        // location, so the fix is read from the file being graded and handed to
        // Photos alongside it. (The still path bakes GPS into the rendered JPEG
        // itself, but reading it from the original costs the same and keeps both
        // kinds on one route.)
        try await saveSourceClip(at: graded, location: await Self.photosLocation(for: url))
    }

    /// Saves a single source clip or still to the Photos library. Requests
    /// add-only authorisation first and throws a descriptive error on denial
    /// or failure. Stills (including DNG) go through the image request —
    /// handing them to the video request is what produced PHPhotosError 3302.
    ///
    /// `location` overrides the fix read from the file, for callers handing over
    /// a re-encoded copy that no longer carries the original's metadata.
    func saveSourceClip(at url: URL, location: CLLocation? = nil) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw SourceClipSaveError.accessDenied
        }
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        var location = location
        if location == nil { location = await Self.photosLocation(for: url) }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if isImage {
                    let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                    request?.location = location
                } else {
                    let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    request?.location = location
                }
            }
        } catch {
            throw SourceClipSaveError.saveFailed(error.localizedDescription)
        }
    }

    /// The location to stamp on an asset created from `url`, read off the file
    /// itself (off the main thread — this is metadata I/O).
    ///
    /// Every file LetsLapse captures carries its fix in its own bytes: EXIF GPS
    /// for a JPEG, a GPS sub-IFD for a DNG, a QuickTime location atom for a
    /// recorded movie. Photos does not lift any of them into the new asset's
    /// `location` on import, though, so the asset lands with no place, no map
    /// pin and no Places grouping. Setting it on the creation request is what
    /// makes the fix visible; the file is copied in untouched either way.
    private static func photosLocation(for url: URL) async -> CLLocation? {
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        return await Task.detached(priority: .userInitiated) {
            isImage ? CLLocation.fromEXIF(of: url) : MovieLocation.locationForSaving(at: url)
        }.value
    }

    /// The fix recorded by the capture this run belongs to, read off its first
    /// source file — a segment's location atom, or an interval frame's EXIF.
    /// Stands in for a rendered blend, whose own file carries no metadata.
    private func currentCaptureLocation() async -> CLLocation? {
        guard let captureID = currentCaptureID,
              let capture = captures.first(where: { $0.id == captureID }),
              let url = sourceClipURLs(for: capture).first
                ?? sourceFrameURLs(for: capture).first
        else { return nil }
        return await Self.photosLocation(for: url)
    }

    /// Saves every source clip of a capture to Photos, one after another.
    func saveAllSourceClips(for capture: CaptureProject) async throws {
        for url in sourceClipURLs(for: capture) {
            try await saveSourceClip(at: url)
        }
    }

    /// Saves every original source asset of a capture to Photos — interval
    /// frames, video clips, or sequence segments — in one library change, so
    /// a few hundred stills don't pay a per-file transaction each.
    ///
    /// Deliberately ungraded: this is the Originals row, and it hands over the
    /// captured files byte for byte (a DNG stays a DNG). Grading here would mean
    /// re-rendering a few hundred full-resolution stills into JPEGs on a phone.
    /// The single-frame Save in the photo browser goes through
    /// `saveGradedAsset(at:for:)` and does carry the grade — that one is "this
    /// photo as I'm looking at it".
    func saveOriginalsToPhotos(for capture: CaptureProject) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw SourceClipSaveError.accessDenied
        }
        let urls: [URL]
        switch try? source(for: capture) {
        case .photos(let frames):
            urls = frames
        case .video(let url):
            urls = [url]
        case .liveSequence(let sequence):
            urls = sequence.segmentURLs
        case nil:
            throw SourceClipSaveError.saveFailed("the original files are missing")
        }
        // Each file's own GPS fix, read up front: the change block has to stay
        // quick, and a few hundred metadata reads don't belong on the main thread.
        let locations: [CLLocation?] = await Task.detached(priority: .userInitiated) {
            urls.map { url in
                guard UTType(filenameExtension: url.pathExtension)?
                    .conforms(to: .image) ?? false else {
                    return MovieLocation.locationForSaving(at: url)
                }
                return CLLocation.fromEXIF(of: url)
            }
        }.value
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for (url, location) in zip(urls, locations) {
                    let isImage = UTType(filenameExtension: url.pathExtension)?
                        .conforms(to: .image) ?? false
                    if isImage {
                        let request = PHAssetChangeRequest
                            .creationRequestForAssetFromImage(atFileURL: url)
                        request?.location = location
                    } else {
                        let request = PHAssetChangeRequest
                            .creationRequestForAssetFromVideo(atFileURL: url)
                        request?.location = location
                    }
                }
            }
        } catch {
            throw SourceClipSaveError.saveFailed(error.localizedDescription)
        }
    }

    func saveResultToPhotos() {
        let videoURL = resultVideoURL
        let imageURL = resultImageURL
        guard videoURL != nil || imageURL != nil else { return }
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveConfirmation = "Photos access was denied."
                return
            }
            // A blended still carries the source frames' GPS through
            // `ImageExporter.carryoverMetadata`; hand it to Photos as a location
            // too. A rendered clip is a fresh encode with no metadata of its
            // own, so it borrows the fix from the capture it was blended from.
            var location: CLLocation?
            if videoURL == nil, let imageURL {
                location = await Self.photosLocation(for: imageURL)
            } else if let videoURL {
                location = await Self.photosLocation(for: videoURL)
                if location == nil { location = await currentCaptureLocation() }
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    if let videoURL {
                        let request = PHAssetChangeRequest
                            .creationRequestForAssetFromVideo(atFileURL: videoURL)
                        request?.location = location
                    } else if let imageURL {
                        let request = PHAssetChangeRequest
                            .creationRequestForAssetFromImage(atFileURL: imageURL)
                        request?.location = location
                    }
                }
                saveConfirmation = "Saved to Photos."
            } catch {
                saveConfirmation = "Save failed: \(error.localizedDescription)"
            }
        }
    }
    #endif
}
