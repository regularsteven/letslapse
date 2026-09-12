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
        static let burstResolution = BurstResolutionSetting.defaultsKey
    }

    /// `mode` marker for a one-tap Photo-mode capture — the burst that was
    /// auto-blended into a single image with no Adjust step. Detects photo
    /// captures across launches (persisted in the manifest via `mode`).
    static let photoCaptureMode = "Photo"

    /// The `mode` line a Scanner shoot registers with — written by
    /// `CaptureView.intervalSourceModeName`, and the back-stop that identifies
    /// Scanner projects registered before `CaptureProject.captureMode` existed.
    /// If the display string is ever reworded, the stored mode carries on
    /// working and only pre-existing projects fall through to the sidecar.
    static let scannerCaptureMode = "Interval · Scanner"

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

    /// The capture mode a project came out of, where the library has to tell
    /// one *photo sequence* from another long after the fact.
    ///
    /// `CaptureKind` says video-or-photos and `mode` is a display string
    /// ("Interval · Scanner") that exists to be read by a human — neither is
    /// something to branch a whole screen on. This is: a small closed set,
    /// written at registration, that survives into the sidecar-free future
    /// where the mode line might be reworded.
    ///
    /// Only Scanner today, because Scanner is the only mode whose *output* is a
    /// different kind of thing: a set of individually-composed frames for
    /// export, where every other photo shoot is material for a blend.
    enum CaptureProjectMode: String, Codable {
        case scanner
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
        /// Which of the three preset states the two fields above are in:
        /// Original (no edits at all), a named preset with the snapshot it was
        /// applied from, or Edited. The values say what to render; this says
        /// where the look came from, which is what the pill shows and what the
        /// export path branches on. Optional so projects saved before the state
        /// model existed still decode — nil is derived from the values by
        /// `AppModel.presetState(for:)`, and stamped by the v2 migration.
        var presetState: PresetState?
        /// How the grade above travels across the shoot, for the captures that
        /// have length — an interval sequence or a movie. Optional and normally
        /// absent: a project only grows one the first time somebody grades a
        /// *second* moment of it, and nil means what it has always meant — that
        /// `adjustments` grade every frame of the shoot equally.
        /// Read it through `AppModel.gradeTimeline(for:)`.
        var gradeTimeline: GradeTimeline?
        /// What this shoot's temperature and tint are measured *from*.
        ///
        /// Optional and normally absent — nil is `.asShot`, which anchors every
        /// frame on its own as-shot reading and is what every project did
        /// before this field existed. A shoot whose camera moved its own white
        /// balance mid-run pins it instead, which is what makes the sliders
        /// absolute rather than a nudge riding the camera's decisions.
        /// Read it through `AppModel.whiteBalanceSource(for:)`.
        var whiteBalanceSource: WhiteBalanceSource?
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
        /// When this project arrived in THIS library — shot here, imported
        /// from a file, or received from another device.
        ///
        /// The twin of `createdAt` rather than a copy of it. `createdAt` is the
        /// shoot's own date, which every import path deliberately preserves (a
        /// timelapse taken last August belongs beside last August's work) — and
        /// that leaves "what turned up here recently" unanswerable on a library
        /// that takes in other people's shoots. This is the field the **Added**
        /// sort reads.
        ///
        /// Defaulted to `Date()` rather than left nil because every place that
        /// *builds* a record is a registration — the moment the project lands.
        /// The two paths that copy an existing record instead (an archive
        /// import, a DNG-archive clone) re-stamp it by hand, or they would
        /// inherit the date the source device recorded. Codable synthesis
        /// ignores property defaults, so a manifest written before this field
        /// decodes as nil and is backfilled once by `stampAddedDatesIfNeeded`;
        /// read it through `AppModel.addedAt(_:)`, which falls back to the
        /// capture date so the sort is total whatever happens.
        var addedAt: Date? = Date()
        /// When a HUMAN last changed this project — the Projects list's "Edit"
        /// sort, and the freshness test behind `sizeBytes` below.
        ///
        /// Deliberately not "when anything last wrote to this record": a
        /// background metadata probe, a preset-state migration or the silent
        /// one-frame tagging at capture all mutate a project and are none of
        /// them edits. It is stamped at the paths a person drives — rename,
        /// grade, rotate, nominate a bad frame, add or delete a blend or an
        /// encoding, delete a scan page — and nowhere else, which is why it is
        /// a curated list rather than a hook on the array.
        ///
        /// Nil for everything captured before this existed; read it through
        /// `AppModel.lastEdited(_:)`, which falls back to the newest blend and
        /// then to the capture date, so an existing library sorts sensibly on
        /// day one instead of collapsing into capture order.
        var modifiedAt: Date?
        /// The project folder's measured size, and when it was measured.
        ///
        /// Stored so the Projects list can sort by size without walking every
        /// project's directory tree on every tap (a 293-project library is not
        /// a walk you want on a gesture). It is a *cached measurement*, not a
        /// running total: `AppModel.needsSizeMeasurement(_:)` re-measures any
        /// project whose `lastEdited` is newer than the measurement, which is
        /// exactly the set whose files can have changed.
        var sizeBytes: Int64?
        var sizeMeasuredAt: Date?
        /// The capture mode this project came out of (`CaptureProjectMode`),
        /// when it is one the app routes on. Optional in both directions:
        /// absent for everything registered before it existed and for every
        /// mode that doesn't need it, which is why the reader is
        /// `AppModel.isScannerProject(_:)` — it falls back to the sidecar for
        /// the Scanner shoots that predate this field.
        var captureMode: String?
        /// The paper stock the capture screen's PAPER row named when this scan
        /// was shot, as a `PerspectiveAspect` raw value. Recorded per session
        /// because the Scans list badges it per session, and because the global
        /// setting is the *next* shoot's answer rather than this one's — a scan
        /// made on A4 must not relabel itself the moment the dial moves to 4×6.
        /// Nil for every scan registered before this existed; read it through
        /// `AppModel.scannerPaper(for:)`, which falls back to the live setting.
        var scannerPaper: String?
        /// Source file names the user has nominated as bad and wants excluded
        /// from every blend. Nil (absent) and empty mean the same thing — no
        /// nominations. Stored as file names rather than indices so a partial
        /// re-import or sort doesn't silently reassign an exclusion to the
        /// wrong frame. Optional for backward-compat: projects saved before
        /// nomination existed decode cleanly with no excluded frames.
        var nominatedBadFrameNames: [String]?
        /// Whether the frames nominated above are hidden from the viewer and
        /// from the counts this project advertises. Three states, not two: nil
        /// means nobody has answered, and resolves to ON wherever there is
        /// something to hide — a user who has just marked a frame bad wants it
        /// gone, and a project with no nominations has nothing to hide either
        /// way. Read it through `AppModel.effectiveHideBadFrames(for:)`.
        /// Optional for backward-compat: projects saved before the toggle
        /// existed decode cleanly and land on that same default.
        var hideBadFrames: Bool?

        /// A Scanner shoot, said outright by the project itself. The stored
        /// field first; the display string second, which catches every Scanner
        /// project registered between the mode shipping and this field
        /// existing. Anything older still is caught by the sidecar heuristic in
        /// `AppModel.isScannerProject(_:)` — don't read this property directly
        /// when routing.
        var isScannerCapture: Bool {
            if captureMode == CaptureProjectMode.scanner.rawValue { return true }
            return kind == .photos && mode == AppModel.scannerCaptureMode
        }

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

        /// The file types this project's source assets are written in,
        /// uppercased and de-duplicated in first-seen order: ["DNG"], ["JPG"],
        /// ["MOV"], or more than one for a mixed import. Sidecars are not
        /// frames and never count. Read it through
        /// `AppModel.sourceFormatSummary(for:)`, which pairs it with the flat
        /// flag the file names can't carry.
        var sourceFormatLabels: [String] {
            var labels: [String] = []
            for name in sourceFileNames where !name.hasSuffix(".json") {
                let ext = (name as NSString).pathExtension.uppercased()
                guard !ext.isEmpty else { continue }
                let label = Self.sourceFormatLabel(for: ext)
                if !labels.contains(label) { labels.append(label) }
            }
            return labels
        }

        /// One spelling per file type, so a library holding both `.jpg` and
        /// `.jpeg` frames doesn't wear a two-format pill for one format.
        static func sourceFormatLabel(for ext: String) -> String {
            switch ext {
            case "JPEG": return "JPG"
            case "TIFF": return "TIF"
            case "QUICKTIME": return "MOV"
            default: return ext
            }
        }

        /// A project that IS one photo — a one-tap Photo-mode capture, or a
        /// single photo imported from Files or the library.
        ///
        /// For a capture: with Blend Off the captured frame is the photo
        /// itself; with blend on, the burst was auto-blended into one image at
        /// capture time. Either way the project reads as ONE asset — no
        /// versions, no photo counts, no source-clip list, no re-processing
        /// (burst frames stay on disk as stacking material, not user-facing
        /// media).
        ///
        /// An import of one file lands here rather than in a one-frame
        /// interval shoot for the same reason: nothing about it was paced by a
        /// timer, there is no sequence to blend or play, and "Interval · 1
        /// photos" is not what somebody who picked one picture asked for.
        var isPhotoCapture: Bool {
            kind == .photos
                && (mode == AppModel.photoCaptureMode || mode == AppModel.importedPhotoMode)
        }

        /// A project title people can recognize: the custom name, an imported
        /// file's name, or a dated fallback.
        var displayTitle: String {
            if let name, !name.isEmpty { return name }
            if kind == .video, mode == AppModel.importedVideoMode {
                let base = (originalName as NSString).deletingPathExtension
                if !base.isEmpty { return base }
            }
            // An imported still sequence names itself after the folder it came
            // out of, and a single imported photo after the file itself — see
            // `AppModel.importedStillsName`. Gated on the import modes rather
            // than on `kind`, so photo projects registered through the old
            // generic "Import" path (whose `originalName` is the count, not a
            // name) keep their dated titles.
            if kind == .photos,
               mode == AppModel.importedStillsMode || mode == AppModel.importedPhotoMode {
                let base = (originalName as NSString).deletingPathExtension
                if !base.isEmpty { return base }
            }
            let stamp = createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            if isPhotoCapture { return "Photo \(stamp)" }
            // "Stack" is the wrong noun for a Scanner set — nothing about it is
            // going to be stacked, and the title is the one place the library
            // names what a project IS.
            if isScannerCapture { return "Scan \(stamp)" }
            return kind == .photos ? "Stack \(stamp)" : "Capture \(stamp)"
        }

        /// "Video · 1080p · 24 fps" / "Interval · 214 photos"
        ///
        /// The count is every source frame on disk. Anywhere the project is
        /// being *presented* — the library card, the project screen's badge —
        /// go through `AppModel.formatLine(for:)` instead, which counts what
        /// the user can actually see once hidden frames are taken off.
        var formatLine: String { formatLine(photoCount: sourceMediaCount) }

        func formatLine(photoCount: Int) -> String {
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
                if isPhotoCapture { return "Photo" }
                // And a Scanner set is not an interval shoot: nothing about it
                // was paced by a timer, and its frames are poses rather than
                // photos of a scene.
                if isScannerCapture { return "Scan · \(photoCount) frames" }
                return "Interval · \(photoCount) photos"
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
        /// The time-slicing recipe this output was rendered with — set only on
        /// the sliced animation and the poster, never on the regular clip a
        /// sliced run keeps alongside them. Absent everywhere else.
        var timeSlice: TimeSliceSettings?

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
                if let timeSlice {
                    return timeSlice.grid != nil ? "Time-slice grid poster" : "Time-slice poster"
                }
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

        /// The thumbnail badge: "100× · 2.2s" / "Long exposure" / "Sliced · 24 bands"
        var badgeLabel: String {
            if let timeSlice {
                // A batch of eight all badged "Sliced · 24 bands" is eight
                // indistinguishable thumbnails, so a batch member leads with
                // its place in the batch and then the shape that differs.
                var label: String
                if kind == .image {
                    label = timeSlice.grid != nil ? "Grid poster" : "Time-slice poster"
                } else if let grid = timeSlice.grid {
                    label = "Grid · \(timeSlice.segments) wide · "
                        + (grid.metric == .manhattan ? "stepped" : "radial")
                } else {
                    label = "Sliced · \(timeSlice.segments) bands"
                }
                if let variation = timeSlice.variation {
                    label = "v\(variation.index)/\(variation.count) · " + label
                }
                return label
            }
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
        /// before any existed. 1 = the Natural stamp, 2 = preset states,
        /// 3 = the `addedAt` backfill (all three run from `loadLibrary`).
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
        /// the canvas pass finds nothing to crop and becomes a pure scale;
        /// nil when the project crop is the shape (no canvas chosen), so the
        /// pass cuts the crop and fits no box inside it.
        var canvas: CanvasRatio?
        var canvasOffset: Double
        /// The project's fine rotation, levelled into every segment before
        /// its crop — the same order the tail passes use.
        var rotationDegrees: Double = 0
        /// The project's crop, cut from each segment after its level and
        /// before the canvas box — the same order the tail pass uses. nil on
        /// the punch path, where it is set aside (the keys were authored over
        /// the uncropped picture), and whenever the project has none.
        var crop: FrameCrop?
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
            /// The crop rects for the whole clip, computed once and sliced to
            /// match `frameTimesBySegment`.
            ///
            /// Computed globally on purpose. A move's span is measured on the
            /// viewer's clock, and that clock is derived from the frame map it
            /// is given — so computing rects from one segment's slice restarts
            /// the clip at zero for that segment and replays the entire punch
            /// inside it. That is what produced a hard cut back to wide at the
            /// burst boundary and a second punch-in (project D29464DA,
            /// 2026-08-16). Slicing finished rects keeps the per-segment render
            /// frame-for-frame identical to the whole-clip pass.
            var rectsBySegment: [[CGRect]]
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
        case slicing
        /// The poster fast path: `frames` master frames of `of` rendered
        /// straight from the stills for `posters` posters — blending, at
        /// depth, with no encode to follow.
        case posterFrames(frames: Int, of: Int, posters: Int)
        case saving
    }

    var processingStage: ProcessingStage {
        switch processingPhase {
        case .preparing: return .preparing
        // A poster run blends its frames and then saves; it encodes nothing,
        // so the checklist must not tick an "Encoding video" row for it.
        case .blending, .posterFrames: return .blending
        case .combining, .grading, .slicing: return .encoding
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

    // MARK: - Library activity

    /// What the app is doing that a *second* consumer of the library needs to
    /// know about.
    ///
    /// There was no flag to read. Capture lived on the capture screen, blending
    /// was `stage == .processing`, and archive export was `@State` inside two
    /// detail views — three of them invisible to anything outside the screen
    /// that owned them. The project-transfer server has to answer "is it safe to
    /// read 20 GB off this disk right now?" before it says yes to a pull, and
    /// that question has exactly one honest answer only if every long job
    /// registers in one place.
    ///
    /// Registration is a bracket and nothing more: no job's behaviour changes,
    /// and nothing reads this except the server (and, in time, the browse row
    /// that greys a busy device before anybody pairs with it).
    enum LibraryActivity: Hashable {
        case capture
        case blending
        /// One per in-flight export, keyed by project — two detail screens can
        /// be exporting at once and each has to end its own.
        case exportingArchive(UUID)
        case importingArchive
        /// A transfer being served right now. Registered so a render or an
        /// export started on this device can see it: reading 20 GB off the disk
        /// under a blend makes both look broken.
        case servingTransfer

        /// What the other device is told. Sentences, because the client shows
        /// this verbatim and "busy" on its own explains nothing.
        var sentence: String {
            switch self {
            case .capture: return "That device is shooting right now."
            case .blending: return "That device is rendering a blend."
            case .exportingArchive: return "That device is exporting a project."
            case .importingArchive: return "That device is importing a project."
            case .servingTransfer: return "That device is already sending a project."
            }
        }
    }

    @Published private(set) var activeLibraryActivities: Set<LibraryActivity> = []

    func beginActivity(_ activity: LibraryActivity) {
        activeLibraryActivities.insert(activity)
        libraryBusyForBackfill = true
    }

    func endActivity(_ activity: LibraryActivity) {
        activeLibraryActivities.remove(activity)
        libraryBusyForBackfill = !activeLibraryActivities.isEmpty
    }

    /// `isLibraryBusy`, readable off the main actor by the asset backfill's
    /// pause check. A plain flag rather than the set, because the set is
    /// main-actor state and the hasher asks from its own queue.
    nonisolated(unsafe) private(set) var libraryBusyForBackfill = false

    var isLibraryBusy: Bool { !activeLibraryActivities.isEmpty }

    /// Why a transfer can't start, or nil when one can. A transfer already in
    /// flight is not a reason on its own — the server has its own one-at-a-time
    /// rule and a better sentence for it.
    var transferBlockReason: String? {
        let blocking = activeLibraryActivities.subtracting([.servingTransfer])
        guard !blocking.isEmpty else { return nil }
        // Ordered rather than `first`: a Set has no order, and the sentence the
        // human reads shouldn't depend on hash seeding. Capture wins — it is
        // the one job losing which costs a shoot.
        if blocking.contains(.capture) { return LibraryActivity.capture.sentence }
        if blocking.contains(.blending) { return LibraryActivity.blending.sentence }
        if blocking.contains(.importingArchive) { return LibraryActivity.importingArchive.sentence }
        return blocking.first?.sentence
    }

    @Published var stage: Stage = .home
    @Published var source: Source?
    @Published var errorMessage: String?
    @Published private(set) var captures: [CaptureProject] = []
    @Published private(set) var blends: [BlendProject] = []
    @Published private(set) var collections: [LapseCollection] = []
    /// Per-project `shapes.json` summaries for the Gallery's Shapes rows,
    /// keyed by capture id; a project with no register has no entry. Filled
    /// by `refreshShapeSummaries()` and `shapeRegisterDidChange(for:)`
    /// (ShapeSummaryIndex.swift).
    @Published var shapeSummaries: [UUID: ShapeSummary] = [:]
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
    /// The open interval project's committed framing lock (`source/framing.json`
    /// with a stabilisation), loaded off the main actor when the project opens
    /// in Adjust. Nil when the photos were never reviewed or stabilised.
    @Published var framingLock: FramingLock?
    /// Adjust › Advanced › "Apply stabilisation". Per blend, not per project:
    /// ON by default whenever `framingLock` exists, OFF (and disabled in the
    /// sheet) when it does not. Every stills render reads it.
    @Published var applyStabilisation = false
    private var framingLockLoad: Task<Void, Never>?

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
    /// The time-slicing recipe for the next Create run; nil = off. Reset with
    /// the other Adjust state, rehydrated by `openBlend` from a sliced clip.
    @Published var timeSlice: TimeSliceSettings?
    /// The variation batch armed for the next Create run; nil = one slice, the
    /// original behaviour. Only meaningful while `timeSlice` is set, and
    /// cleared with it. The blend runs once either way — a batch re-reads the
    /// finished clip once per variation (docs/time-slicing.md §10).
    @Published var timeSliceVariations: TimeSliceVariationPlan?

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

    /// Whether a speed burst may change resolution as well as frame rate.
    /// Off by default — see `BurstResolutionSetting` for what "off" guarantees.
    @Published var burstResolutionEnabled = BurstResolutionSetting.isEnabled {
        didSet { UserDefaults.standard.set(burstResolutionEnabled, forKey: DefaultsKey.burstResolution) }
    }

    /// A shoot armed for a future wall-clock time, or nil for none.
    ///
    /// Lives on the model rather than in the capture screen's `@State` because
    /// it outlives the screen: it is set from the schedule sheet, survives the
    /// app being relaunched while the phone waits on a tripod, and is cleared
    /// by whichever of "the shoot fired" or "the user cancelled" comes first.
    /// The capture screen watches it and enters cold standby (no capture
    /// session at all) whenever the start is far enough away to be worth it.
    @Published var scheduledRecording: ScheduledRecording? = ScheduledRecordingStore.load() {
        didSet { ScheduledRecordingStore.save(scheduledRecording) }
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

    /// The run-rate progress values live on their own observable — their 10 Hz
    /// writes must invalidate only the processing surfaces, never every screen
    /// observing AppModel (perf-audit-2026-08-29.md P1.2; the frozen-create
    /// recording). The forwarders below keep this file's forty-odd write sites
    /// reading as they always did. Slow-cadence run state (`processingPhase`,
    /// `statusMessage`, `processingStartedAt`) stays `@Published` here.
    let processingProgress = ProcessingProgressModel()

    var progress: Double {
        get { processingProgress.fraction }
        set { processingProgress.fraction = newValue }
    }
    var processingETADate: Date? {
        get { processingProgress.etaDate }
        set { processingProgress.etaDate = newValue }
    }
    var processingFramesDone: Int? {
        get { processingProgress.framesDone }
        set { processingProgress.framesDone = newValue }
    }
    var processingFramesTotal: Int? {
        get { processingProgress.framesTotal }
        set { processingProgress.framesTotal = newValue }
    }

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
    /// Stays here (a handful of writes per run); the run-rate values are the
    /// forwarders above.
    @Published var processingPhase: ProcessingPhase = .preparing

    /// The frame-weighted band layout for the run in flight; nil outside one.
    private var activeProgressPlan: BlendProgressPlan?
    /// When the current tail stage (stitch/grade export) began, for its ETA.
    private var tailPhaseStartedAt: Date?

    /// Memo for `isScannerProject`'s last-resort sidecar read, keyed by project.
    /// Not published: it answers a question about files on disk, and a project
    /// does not stop being a Scanner shoot while anyone is looking.
    private var scannerSidecarCache: [UUID: Bool] = [:]

    /// Set by screens that want the Projects tab to open a specific project
    /// (e.g. Result → Done). ContentView consumes and clears it.
    @Published var requestedProjectDetailID: UUID?

    /// The Scans tab's twin of the above: open this session. Set when a scanner
    /// run finishes, because a finished scan is a document to look at rather
    /// than footage to configure a blend from — see `finishScannerCapture`.
    @Published var requestedScanDetailID: UUID?

    /// "Open this project, wherever it lives." A scan is listed in exactly one
    /// place — its own tab — so asking for the Projects tab would land on a
    /// screen its own list doesn't show it in. Used by archive import, which is
    /// handed whatever someone shared and cannot know which kind it is until it
    /// has read the manifest.
    func show(_ capture: CaptureProject) {
        if isScannerProject(capture) {
            requestedScanDetailID = capture.id
        } else {
            requestedProjectDetailID = capture.id
        }
    }

    /// How far the automatic perspective pass has got, per scan.
    ///
    /// Published because it is the header of the screen the operator is taken to
    /// the moment a scan ends: a set arrives needing a minute of GPU work, and
    /// "Correcting 6 of 34 pages…" is the difference between a screen that is
    /// working and one that looks finished but wrong.
    @Published private(set) var scanCorrections: [UUID: ScanCorrection] = [:]

    struct ScanCorrection: Equatable {
        var completed: Int
        var total: Int
        var isRunning: Bool { completed < total }
        var line: String { "Correcting \(completed + 1) of \(total) pages…" }
    }

    /// Bumped whenever a session's `documents.json` is rewritten, so an open
    /// detail screen re-walks itself. The groups live on disk rather than in
    /// the model (they belong to the scan, not to this launch), so there is
    /// nothing here for a view to observe except the fact that they changed.
    @Published private(set) var scanDocumentsToken = 0

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

    /// Which rail page a project's editor should land on — the Gallery panel's
    /// Text and Shapes buttons. The editor for that project consumes and clears
    /// it, whether it was just presented or (on the Mac) was already open and
    /// merely fronted. Staged by `stageEditor(for:page:)` — see `EditorLaunch.swift`.
    @Published var requestedEditorPage: EditorPageRequest?

    private var blendTask: Task<Void, Never>?

    /// The per-asset records (`assets.ndjson`) and project-level metadata
    /// (`metadata.json`) of every project — see `AppModel+Metadata.swift`.
    let assetStore = AssetRecordStore()
    /// Bumped whenever a project's records change on disk, so the panel
    /// re-reads. Edits commit per field, never per keystroke.
    @Published var metadataRevision = 0

    init() {
        loadLibrary()
        refreshShapeSummaries()
        assetStore.onChange = { [weak self] _ in self?.metadataRevision += 1 }
        assetStore.shouldPause = { [weak self] in
            let process = ProcessInfo.processInfo
            if process.thermalState == .serious || process.thermalState == .critical { return true }
            if process.isLowPowerModeEnabled { return true }
            // Read off the main actor only through this snapshot, which the
            // activity brackets keep current.
            return self?.libraryBusyForBackfill ?? false
        }
        scheduleAssetBackfill()
        // The Adjust and Guided previews level their source frames the way
        // the render will; they learn the current project's level from here.
        AdjustPreviewLevel.provider = { [weak self] in
            guard let self, let capture = self.currentCapture else { return 0 }
            return self.photoGrade(for: capture).rotationDegrees
        }
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
            // `isDirectory: false` matters at this scale: without it,
            // Foundation stats the disk per appended component to decide
            // directory-ness — a getattrlist syscall per frame, thousands per
            // call on a long shoot (measured; editor-performance-plan.md).
            .map { root.appendingPathComponent($0, isDirectory: false) }
    }

    /// The frame that stands for a photo-kind capture when it is shown as a
    /// still: the first source frame the user has NOT nominated as bad. A shoot
    /// whose opening frames are the ones the user threw away shouldn't keep
    /// advertising itself with them. Falls back to the first frame when every
    /// frame is nominated, because a tile with no picture is worse than a tile
    /// with a bad one.
    func thumbnailFrameURL(for capture: CaptureProject) -> URL? {
        let frames = sourceFrameURLs(for: capture)
        guard let first = frames.first else { return nil }
        let nominated = nominatedBadFrameNames(for: capture)
        guard !nominated.isEmpty else { return first }
        return frames.first { !nominated.contains($0.lastPathComponent) } ?? first
    }

    /// What a project shows as its hero or its list tile. A video capture is its
    /// source movie and a Photo-mode capture is its one photo (both unchanged);
    /// an interval shoot is `thumbnailFrameURL(for:)` rather than a flat frame 0.
    /// `mediaURL` still gates the answer, so a project with a missing source
    /// file goes on rendering as the placeholder instead of a broken image.
    func thumbnailURL(for capture: CaptureProject) -> URL? {
        if capture.isPhotoCapture { return heroImageURL(for: capture) }
        guard let media = mediaURL(for: capture) else { return nil }
        guard capture.kind == .photos else { return media }
        return thumbnailFrameURL(for: capture) ?? media
    }

    // MARK: - Frame nomination (persistent per-project bad-frame exclusion)

    /// The set of source file names the user has marked as bad on `capture`.
    func nominatedBadFrameNames(for capture: CaptureProject) -> Set<String> {
        Set(capture.nominatedBadFrameNames ?? [])
    }

    /// Whether a specific source file name is currently marked bad.
    func isFrameNominated(_ fileName: String, in capture: CaptureProject) -> Bool {
        capture.nominatedBadFrameNames?.contains(fileName) ?? false
    }

    /// Toggle the nomination on `fileName` inside `capture`. Persists the
    /// change immediately. Does nothing and returns if the project isn't found.
    func toggleFrameNomination(fileName: String, in captureID: UUID) {
        guard let index = captures.firstIndex(where: { $0.id == captureID }) else { return }
        var names = Set(captures[index].nominatedBadFrameNames ?? [])
        if names.contains(fileName) {
            names.remove(fileName)
        } else {
            names.insert(fileName)
        }
        captures[index].nominatedBadFrameNames = names.isEmpty ? nil : Array(names).sorted()
        // A person changed this project — see CaptureProject.modifiedAt.
        captures[index].modifiedAt = Date()
        try? persistLibrary()
    }

    /// The integer frame indices (into `sourceFrameURLs`) that the user has
    /// nominated as bad. Used to seed `excludedFrameIndices` when the user
    /// opens a project for blending.
    func nominatedExcludedIndices(for capture: CaptureProject) -> Set<Int> {
        let badNames = nominatedBadFrameNames(for: capture)
        guard !badNames.isEmpty else { return [] }
        let names = capture.sourceFileNames.filter { !$0.hasSuffix(".json") }
        // sourceFileNames carry a "source/" prefix; nominations store bare file
        // names (lastPathComponent). Strip before comparing so the lookup fires.
        return Set(names.indices.filter {
            badNames.contains(URL(fileURLWithPath: names[$0]).lastPathComponent)
        })
    }

    // MARK: - Hiding nominated frames

    /// Whether this project's bad frames are currently hidden from the viewer
    /// and from the counts it advertises.
    ///
    /// A project with no nominations is never hiding anything, whatever the
    /// stored flag says — that is what keeps the toggle off screen until there
    /// is something for it to do. Otherwise the stored answer, defaulting to
    /// ON: marking a frame bad and then still having to scrub past it is not
    /// what the nomination was for.
    func effectiveHideBadFrames(for capture: CaptureProject) -> Bool {
        guard !(capture.nominatedBadFrameNames ?? []).isEmpty else { return false }
        return capture.hideBadFrames ?? true
    }

    /// Sets the toggle on one project and persists it. Stored per project
    /// rather than as a global preference: hiding is a judgement about *these*
    /// frames, and a shoot with two ruined frames and one with fifty deserve
    /// separate answers.
    func setHideBadFrames(_ value: Bool, for captureID: UUID) {
        guard let index = captures.firstIndex(where: { $0.id == captureID }) else { return }
        guard captures[index].hideBadFrames != value else { return }
        captures[index].hideBadFrames = value
        // A person changed this project — see CaptureProject.modifiedAt.
        captures[index].modifiedAt = Date()
        try? persistLibrary()
    }

    /// How many frames this project has *to show* — its source frames less the
    /// hidden ones. The number every count in the library is written from, so a
    /// shoot whose two ruined frames are hidden reads 248 rather than 250.
    ///
    /// Derived by filtering rather than by subtracting the nomination count: a
    /// nomination whose file has since been deleted would otherwise take a
    /// frame off the total twice.
    func effectiveFrameCount(for capture: CaptureProject) -> Int {
        let names = capture.sourceFileNames.filter { !$0.hasSuffix(".json") }
        guard effectiveHideBadFrames(for: capture) else { return names.count }
        let bad = nominatedBadFrameNames(for: capture)
        return names.filter { !bad.contains(URL(fileURLWithPath: $0).lastPathComponent) }.count
    }

    /// The source frames a screen should walk, in capture order — the whole
    /// shoot, or everything the user hasn't thrown away. The viewer's scrubber
    /// and its frame steps run on this rather than on `sourceFrameURLs`.
    func visibleFrameURLs(for capture: CaptureProject) -> [URL] {
        let all = sourceFrameURLs(for: capture)
        guard effectiveHideBadFrames(for: capture) else { return all }
        let bad = nominatedBadFrameNames(for: capture)
        return all.filter { !bad.contains($0.lastPathComponent) }
    }

    /// `CaptureProject.formatLine` counted the way the user sees it — the one
    /// every presentation surface should call.
    func formatLine(for capture: CaptureProject) -> String {
        capture.formatLine(photoCount: effectiveFrameCount(for: capture))
    }

    // MARK: - Scanner projects

    /// Whether this project came out of a Scanner shoot, and should therefore
    /// be presented as a set of frames to export rather than as a timelapse to
    /// blend.
    ///
    /// Three answers in decreasing order of confidence, which is the whole
    /// design: the stored `captureMode`, then the mode line, then — for a
    /// project registered before either could say so, or imported from a device
    /// that was — the sidecar. A Scanner run is the only thing in the app that
    /// writes a `rectangle` into `frames.timestamps`, so one entry carrying one
    /// is proof; the absence of them is not a disproof, which is why this is
    /// the last resort rather than the test.
    ///
    /// Answered synchronously because it decides which screen to build, and
    /// cached because a view body asks per redraw. The read behind the cache is
    /// one small NDJSON file, and only for photo projects that actually have
    /// one.
    func isScannerProject(_ capture: CaptureProject) -> Bool {
        if capture.isScannerCapture { return true }
        guard capture.kind == .photos, !capture.isPhotoCapture else { return false }
        if let known = scannerSidecarCache[capture.id] { return known }
        let found = scannerSidecar(for: capture)?.entries.contains { $0.rectangle != nil } ?? false
        scannerSidecarCache[capture.id] = found
        return found
    }

    /// The library split the Scans tab is built on, and the one Projects and
    /// Gallery are built on.
    ///
    /// A scan is a document, so it lives in exactly one place: its own tab. It
    /// is *not* a timelapse waiting to be blended, and leaving it in the two
    /// library tabs was the wrong mental model the Scans tab exists to fix.
    /// The route back in is deliberate and single — "View as timelapse" on the
    /// session's export sheet, which opens `ScannerProjectView` as before.
    var scanSessions: [CaptureProject] {
        captures.filter(isScannerProject)
    }

    /// Cheap "is there anything in the Scans tab" — the tab bar asks this on
    /// every redraw (it is half of whether the tab is drawn at all; the Layout
    /// setting is the other half), and it stops at the first scan rather than
    /// building a list.
    var hasScanSessions: Bool {
        captures.contains(where: isScannerProject)
    }

    /// Everything that is not a scan: what Projects and Gallery list.
    var libraryCaptures: [CaptureProject] {
        captures.filter { !isScannerProject($0) }
    }

    /// The page numbers a scan actually holds, ascending — read off the
    /// registered file names (`frame-00007.jpg` → 7).
    ///
    /// Deliberately not `1...sourceMediaCount`: pages keep their numbers when
    /// one is deleted, so a count is only right until the first deletion. Names
    /// that don't parse fall back to their position, which is what every
    /// pre-Scanner photo project's frames are.
    func scanPageNumbers(for capture: CaptureProject) -> [Int] {
        let names = capture.sourceFileNames.filter { !$0.hasSuffix(".json") }
        return names.enumerated().map { offset, name in
            let base = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
            guard base.hasPrefix("frame-"), let parsed = Int(base.dropFirst("frame-".count))
            else { return offset + 1 }
            return parsed
        }.sorted()
    }

    /// Everything `ScanSession.load` needs to resolve one session, gathered
    /// here so the walk itself can run off the main actor without holding a
    /// reference to the model.
    func scanSessionRequest(for capture: CaptureProject) -> ScanSession.Request {
        ScanSession.Request(
            id: capture.id,
            createdAt: capture.createdAt,
            paper: scannerPaper(for: capture),
            name: capture.name,
            sourceFolder: captureFolderURL(for: capture.id).appendingPathComponent("source"),
            frameNumbers: scanPageNumbers(for: capture),
            frameURLs: sourceFrameURLs(for: capture))
    }

    /// The paper stock a scan was shot on: what the session recorded, or — for
    /// a scan made before that was stamped — whatever the capture screen's
    /// PAPER row says now, which is the same answer the correction has always
    /// used.
    func scannerPaper(for capture: CaptureProject) -> PerspectiveAspect {
        capture.scannerPaper.flatMap(PerspectiveAspect.init(rawValue:)) ?? Self.storedScannerPaper
    }

    /// The capture screen's PAPER setting, read straight from defaults. The
    /// same key `CaptureView` and `ScannerProjectSections` bind with
    /// `@AppStorage`; this is the non-view reader.
    static var storedScannerPaper: PerspectiveAspect {
        UserDefaults.standard.string(forKey: "letslapse.capture.scannerAspect")
            .flatMap(PerspectiveAspect.init(rawValue:)) ?? .auto
    }

    /// Records the stock a session is presented as, after a re-correction has
    /// gone through on a different one.
    func setScannerPaper(_ paper: PerspectiveAspect, for id: UUID) {
        guard let index = captures.firstIndex(where: { $0.id == id }) else { return }
        captures[index].scannerPaper = paper.rawValue
        // A person changed this project — see CaptureProject.modifiedAt.
        captures[index].modifiedAt = Date()
        try? persistLibrary()
    }

    // MARK: - Scan documents

    /// Where a scan's sidecars live: its frames, `frames.timestamps` and
    /// `documents.json` are all one folder.
    func scanSourceFolder(for sessionID: UUID) -> URL {
        captureFolderURL(for: sessionID).appendingPathComponent("source")
    }

    /// The groups a session holds, resolved against the pages really on disk —
    /// never empty for a session with pages, and exactly one entry for a scan
    /// made before grouping existed.
    func scanDocuments(for sessionID: UUID) -> [ScanDocument] {
        guard let capture = captures.first(where: { $0.id == sessionID }) else { return [] }
        return ScanDocumentStore.resolve(
            ScanDocumentStore.load(from: scanSourceFolder(for: sessionID)),
            pageNumbers: scanPageNumbers(for: capture))
    }

    /// Opens the next document on a session, empty, and returns it.
    ///
    /// Empty on purpose: this is the "New Document" the capture screen presses
    /// *before* the page that belongs in it exists, and the resolver drops a
    /// group with no pages — so a document opened and never filled costs
    /// nothing and leaves no trace.
    @discardableResult
    func addDocument(to sessionID: UUID) -> ScanDocument {
        let folder = scanSourceFolder(for: sessionID)
        var documents = ScanDocumentStore.load(from: folder)
        if documents.isEmpty {
            // The first explicit group on a session that had none: everything
            // shot so far is document 1, and the new one follows it. Written
            // out rather than implied, because from here on the file is the
            // record and an unwritten first group would swallow every page.
            documents = scanDocuments(for: sessionID)
        }
        let document = ScanDocument(
            name: ScanDocumentStore.nextName(after: documents), pageIndices: [])
        documents.append(document)
        write(documents, for: sessionID)
        return document
    }

    /// Moves one page into a group, taking it out of whichever group had it.
    ///
    /// A page belongs to exactly one document, so this is a move and never a
    /// copy: the same page appearing in two sections would export twice and
    /// read as a duplicate that isn't on disk.
    func assignPage(_ pageIndex: Int, toDocument docID: UUID, inSession sessionID: UUID) {
        var documents = scanDocuments(for: sessionID)
        guard let target = documents.firstIndex(where: { $0.id == docID }) else { return }
        for index in documents.indices where index != target {
            documents[index].pageIndices.removeAll { $0 == pageIndex }
        }
        if !documents[target].pageIndices.contains(pageIndex) {
            documents[target].pageIndices.append(pageIndex)
            // Page order inside a document is capture order — the pages of a
            // contract are the pages of a contract, and a page moved in later
            // still belongs where it was shot.
            documents[target].pageIndices.sort()
        }
        write(documents.filter { !$0.pageIndices.isEmpty }, for: sessionID)
    }

    func renameDocument(_ docID: UUID, in sessionID: UUID, name: String) {
        var documents = scanDocuments(for: sessionID)
        guard let index = documents.firstIndex(where: { $0.id == docID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty name goes back to the numbered default rather than leaving a
        // section with no header text at all.
        documents[index].name = trimmed.isEmpty
            ? ScanDocumentStore.defaultName(index: index)
            : trimmed
        write(documents, for: sessionID)
    }

    /// Folds a session back into one document — the undo for a grouping the
    /// operator didn't mean, and what "New scan = new doc" left on by accident
    /// needs an escape from.
    func flattenDocuments(in sessionID: UUID) {
        write([], for: sessionID)
    }

    private func write(_ documents: [ScanDocument], for sessionID: UUID) {
        try? ScanDocumentStore.save(documents, to: scanSourceFolder(for: sessionID))
        scanDocumentsToken &+= 1
    }

    /// The photograph a pose was shot as — never the rectified page.
    ///
    /// The counterpart to `scannerViewableURL`, and the whole basis of the
    /// viewer's Corrected/Original toggle: correction is non-destructive, so
    /// there is always something to toggle *to*, and the re-correct sheet has
    /// something to re-measure corners on.
    func scannerOriginalURL(for capture: CaptureProject, frameNumber: Int) -> URL? {
        let sourceFolder = captureFolderURL(for: capture.id).appendingPathComponent("source")
        let base = String(format: "frame-%05d", frameNumber)
        for name in ["heic", "jpg", "jpeg"].map({ "\(base).\($0)" }) {
            let url = sourceFolder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // A pose shot without a processed sibling: the frame itself is the
        // photograph (the honest no-RAW fallback), or a DNG that at least
        // decodes.
        let frames = sourceFrameURLs(for: capture)
        guard frames.indices.contains(frameNumber - 1) else { return nil }
        return frames[frameNumber - 1]
    }

    /// The per-frame capture record beside a photo project's frames, or nil
    /// when the shoot didn't write one (every interval shoot before Holy Grail
    /// and Scanner existed).
    func scannerSidecar(for capture: CaptureProject) -> FrameTimestamps? {
        let url = captureFolderURL(for: capture.id)
            .appendingPathComponent("source/\(FrameTimestamps.fileName)")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? FrameTimestamps.load(from: url)
    }

    /// The human-viewable file for one pose, best first: the rectified
    /// `-corrected.heic` where the correction has been run, then the processed
    /// sibling a RAW pose was shot with, and finally the frame itself — which
    /// on the no-RAW fallback *is* the processed still, and on a RAW pose is a
    /// DNG the thumbnail pipeline can still decode (slowly).
    ///
    /// `frameNumber` is 1-based, matching the file names.
    func scannerViewableURL(for capture: CaptureProject, frameNumber: Int) -> URL? {
        let sourceFolder = captureFolderURL(for: capture.id).appendingPathComponent("source")
        let base = String(format: "frame-%05d", frameNumber)
        // The corrected page only counts if it was written since the
        // orientation fix; otherwise the original is the better picture of the
        // two (see `scannerCorrectedURL`).
        if let corrected = scannerCorrectedURL(for: capture, frameNumber: frameNumber) {
            return corrected
        }
        for name in ["heic", "jpg", "jpeg"].map({ "\(base).\($0)" }) {
            let url = sourceFolder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let frames = sourceFrameURLs(for: capture)
        guard frames.indices.contains(frameNumber - 1) else { return nil }
        return frames[frameNumber - 1]
    }

    /// Whether a rectified sibling exists for this pose — what makes the
    /// difference between "Export frames" shipping corrected pages and shipping
    /// the photographs they were rectified from.
    func scannerCorrectedURL(for capture: CaptureProject, frameNumber: Int) -> URL? {
        let url = captureFolderURL(for: capture.id)
            .appendingPathComponent("source")
            .appendingPathComponent(
                String(format: "frame-%05d%@.heic", frameNumber, PerspectiveCorrector.correctedSuffix))
        guard FileManager.default.fileExists(atPath: url.path),
              // Same rule as `ScanSession.load`: a page corrected before the
              // orientation fix doesn't count as corrected.
              !PerspectiveCorrector.isSupersededCorrection(at: url) else { return nil }
        return url
    }

    /// Throws one page out of a scan: its photograph, its rectified sibling and
    /// its line in the sidecar.
    ///
    /// **Nothing is renumbered.** The files, the sidecar and every reference
    /// anyone has already taken all name a pose by its index, so closing the
    /// gap would quietly re-point them at a different photograph. A missing
    /// number is the honest record of a page that was thrown away, and the
    /// export renumbers from 1 on its way out anyway (`ScanFrameExport`), so
    /// nothing downstream ever sees the hole.
    func deleteScanPage(_ number: Int, from capture: CaptureProject) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        let sourceFolder = captureFolderURL(for: capture.id).appendingPathComponent("source")
        let base = String(format: "frame-%05d", number)
        var removed: [URL] = []
        for name in ["\(base).heic", "\(base).jpg", "\(base).jpeg", "\(base).dng",
                     "\(base)\(PerspectiveCorrector.correctedSuffix).heic"] {
            let url = sourceFolder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.removeItem(at: url)
            removed.append(url)
        }
        // The sidecar counts from 0 where the files count from 1.
        try? FrameTimestamps.deleteEntry(frame: number - 1, in: sourceFolder)
        captures[index].sourceFileNames.removeAll { name in
            (name as NSString).lastPathComponent.hasPrefix("\(base).")
        }
        // A person changed this project — see CaptureProject.modifiedAt.
        captures[index].modifiedAt = Date()
        try? persistLibrary()
        ProjectThumbnailCache.shared.invalidate(urls: removed)
        invalidateScannerCache(for: capture.id)
        // The frame count and the sidecar both changed under the cached axis.
        stillsAxisCache.removeValue(forKey: capture.id)
    }

    /// Drops what `isScannerProject` remembers about a project, after anything
    /// that could change the answer (a correction pass writing new files, a
    /// project going away).
    func invalidateScannerCache(for id: UUID? = nil) {
        if let id {
            scannerSidecarCache.removeValue(forKey: id)
        } else {
            scannerSidecarCache.removeAll()
        }
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
        markEdited(blend.captureID)
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
        // Clips joining a collection that has met Ken Burns arrive with
        // their moves already dealt.
        if collection.kenBurns != nil { dealKenBurnsMoves(&collection) }
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

    /// The Ken Burns window editor commits only where the clip starts; the
    /// stored out point survives for when the mode turns off — pushed later
    /// only if the new start would leave the plain trim inverted.
    func updateKenBurnsWindowStart(blendID: UUID, in collectionID: UUID, inPoint: Double, windowFraction: Double) {
        mutateCollection(collectionID) { collection in
            guard let idx = collection.entries.firstIndex(where: { $0.blendID == blendID }) else { return }
            let start = min(max(0, inPoint), 1)
            collection.entries[idx].inPoint = start
            collection.entries[idx].outPoint = max(
                collection.entries[idx].outPoint,
                min(1, start + max(0.01, windowFraction)))
        }
    }

    /// Turning Ken Burns on for the first time answers everything with the
    /// best-effort defaults — consistent pacing at the shortest clip's length,
    /// speeds auto-adjusted, crossfades on — and deals every clip its move.
    /// Turning it off keeps the settings for next time. (The tri-state
    /// control goes through the mode setters below; this stays for the
    /// LL_COLLECTIONS hook and lands in whichever mode was last live.)
    func setKenBurnsEnabled(_ enabled: Bool, for collectionID: UUID) {
        mutateCollection(collectionID) { collection in
            if var settings = collection.kenBurns {
                settings.enabled = enabled
                collection.kenBurns = settings
            } else if enabled {
                collection.kenBurns = autoKenBurnsSettings(collection)
            }
            if enabled { dealKenBurnsMoves(&collection) }
        }
    }

    /// Off keeps everything — values, mode, per-clip moves — for next time.
    func setKenBurnsOff(for collectionID: UUID) {
        updateKenBurnsSettings(collectionID) { $0.enabled = false }
    }

    /// Auto: the dealt best-effort defaults take over the live values. Any
    /// Custom answers are parked in `lastCustom` first, so the switch never
    /// destroys them and needs no confirmation.
    func setKenBurnsAuto(for collectionID: UUID) {
        mutateCollection(collectionID) { collection in
            var settings = collection.kenBurns ?? autoKenBurnsSettings(collection)
            if settings.custom {
                settings.lastCustom = LapseCollection.KenBurnsSettings.CustomChoices(
                    consistentDurations: settings.consistentDurations,
                    clipSeconds: settings.clipSeconds,
                    autoAdjustSpeed: settings.autoAdjustSpeed,
                    fadeTransition: settings.fadeTransition)
            }
            settings.enabled = true
            settings.custom = false
            settings.consistentDurations = true
            settings.clipSeconds = kenBurnsMaxClipSeconds(collection)
            settings.autoAdjustSpeed = true
            settings.fadeTransition = true
            collection.kenBurns = settings
            dealKenBurnsMoves(&collection)
        }
    }

    /// Entering the Custom drawer: the mode turns on, the parked Custom
    /// values (if any) come back as the live ones, and edits from here apply
    /// live. The caller snapshots `collection.kenBurns` first — Cancel is
    /// `restoreKenBurnsSettings` with that snapshot.
    func beginKenBurnsCustom(for collectionID: UUID) {
        mutateCollection(collectionID) { collection in
            var settings = collection.kenBurns ?? autoKenBurnsSettings(collection)
            if let parked = settings.lastCustom {
                settings.consistentDurations = parked.consistentDurations
                settings.clipSeconds = parked.clipSeconds
                settings.autoAdjustSpeed = parked.autoAdjustSpeed
                settings.fadeTransition = parked.fadeTransition
            }
            settings.lastCustom = nil
            settings.enabled = true
            settings.custom = true
            collection.kenBurns = settings
            dealKenBurnsMoves(&collection)
        }
    }

    /// The Custom drawer's Cancel: put back exactly what was there when it
    /// opened (nil = Ken Burns had never been configured). Per-clip moves
    /// dealt in between stay — moves already survive the mode toggling.
    func restoreKenBurnsSettings(_ settings: LapseCollection.KenBurnsSettings?, for collectionID: UUID) {
        mutateCollection(collectionID) { $0.kenBurns = settings }
    }

    /// The dealt Auto answers for this timeline, as fresh settings.
    private func autoKenBurnsSettings(_ collection: LapseCollection) -> LapseCollection.KenBurnsSettings {
        LapseCollection.KenBurnsSettings(
            enabled: true,
            consistentDurations: true,
            clipSeconds: kenBurnsMaxClipSeconds(collection),
            autoAdjustSpeed: true,
            fadeTransition: true)
    }

    /// Every entry without a move gets its best-effort default, seeded from
    /// its timeline position and its crop. Custom moves are never touched.
    private func dealKenBurnsMoves(_ collection: inout LapseCollection) {
        for index in collection.entries.indices where collection.entries[index].kenBurns == nil {
            collection.entries[index].kenBurns = CollectionMath.kenBurnsDefaultMove(
                forClipIndex: index,
                base: kenBurnsUnitBase(entry: collection.entries[index], in: collection))
        }
    }

    /// What zoom 1 means for this entry: the largest canvas-shaped window
    /// over the clip, sitting where the resolved crop puts it.
    func kenBurnsUnitBase(entry: LapseCollection.Entry, in collection: LapseCollection) -> CGRect {
        let aspect = blends.first(where: { $0.id == entry.blendID }).map(blendAspect) ?? 16.0 / 9.0
        return CollectionMath.kenBurnsUnitBase(
            clipAspect: aspect,
            canvasAspect: collection.ratio?.aspect ?? 16.0 / 9.0,
            offset: resolvedCropOffset(entry: entry, in: collection) ?? 0.5)
    }

    /// The move the export and the editor act on: the stored one, else the
    /// entry's dealt default (same derivation, so the recipe stays honest).
    func kenBurnsResolvedMove(entry: LapseCollection.Entry, in collection: LapseCollection) -> LapseCollection.Entry.KenBurnsMove {
        if let move = entry.kenBurns { return move }
        let index = collection.entries.firstIndex { $0.blendID == entry.blendID } ?? 0
        return CollectionMath.kenBurnsDefaultMove(
            forClipIndex: index, base: kenBurnsUnitBase(entry: entry, in: collection))
    }

    /// One end of a clip's move, edited by hand on the preview — clamped
    /// through the same invariants everything else reads through, and marked
    /// custom so defaults never overwrite it.
    func setKenBurnsFraming(
        blendID: UUID, in collectionID: UUID, end: KenBurnsMoveEnd,
        framing: LapseCollection.Entry.KenBurnsFraming
    ) {
        mutateCollection(collectionID) { collection in
            guard let idx = collection.entries.firstIndex(where: { $0.blendID == blendID }) else { return }
            let entry = collection.entries[idx]
            var move = kenBurnsResolvedMove(entry: entry, in: collection)
            let clamped = CollectionMath.clampedKenBurnsFraming(
                base: kenBurnsUnitBase(entry: entry, in: collection), framing: framing)
            switch end {
            case .start: move.start = clamped
            case .end: move.end = clamped
            }
            move.isCustom = true
            collection.entries[idx].kenBurns = move
        }
    }

    /// Back to the dealt default for this clip's position on the timeline.
    func resetKenBurnsMove(blendID: UUID, in collectionID: UUID) {
        mutateCollection(collectionID) { collection in
            guard let idx = collection.entries.firstIndex(where: { $0.blendID == blendID }) else { return }
            collection.entries[idx].kenBurns = CollectionMath.kenBurnsDefaultMove(
                forClipIndex: idx,
                base: kenBurnsUnitBase(entry: collection.entries[idx], in: collection))
        }
    }

    /// One seam for the Ken Burns sub-controls; no-op until the mode has
    /// been turned on once.
    func updateKenBurnsSettings(
        _ collectionID: UUID, _ mutate: (inout LapseCollection.KenBurnsSettings) -> Void
    ) {
        mutateCollection(collectionID) { collection in
            guard var settings = collection.kenBurns else { return }
            mutate(&settings)
            settings.clipSeconds = max(1, settings.clipSeconds)
            collection.kenBurns = settings
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

    /// The source's display size after the Edit screen's crop — the picture
    /// the canvas is fitted inside (`VideoCanvasCropper`: the crop first,
    /// then the canvas box on what it kept), so the captions below measure
    /// the same frame the render does.
    func projectCroppedDisplaySize() -> CGSize? {
        guard let size = sourceDisplaySize() else { return nil }
        guard let capture = currentCapture,
              let crop = photoGrade(for: capture).crop, !crop.isFull else { return size }
        return crop.outputSize(for: size)
    }

    /// Whether creating the clip will crop — the chosen canvas disagrees with
    /// the (project-cropped) source's shape beyond tolerance.
    func blendCanvasNeedsCrop() -> Bool {
        guard let size = projectCroppedDisplaySize() else { return false }
        return VideoCanvasCropper.cropSize(displaySize: size, canvas: effectiveBlendCanvas()) != nil
    }

    /// The pixels the chosen canvas keeps (centred, source scale) — the created
    /// clip's dimensions, and the picker caption's number. nil when no crop.
    func blendCanvasCropSize() -> CGSize? {
        guard let size = projectCroppedDisplaySize() else { return nil }
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

    /// The whole timeline's length as it will export: each clip's Ken Burns
    /// contribution when the mode is on (minus what the crossfades overlap),
    /// else the plain butt-joined sum of kept lengths.
    func collectionSeconds(_ collection: LapseCollection) -> Double {
        let outputs = collection.entries.map { entryOutputSeconds($0, in: collection) }
            .filter { $0 > 0.01 }
        var total = outputs.reduce(0, +)
        if let kenBurns = collection.kenBurns, kenBurns.enabled, kenBurns.fadeTransition {
            for index in 1..<max(1, outputs.count) {
                total -= kenBurnsFadeSeconds(outgoing: outputs[index - 1], incoming: outputs[index])
            }
        }
        return total
    }

    /// One clip's length in the export. Ken Burns' consistent mode pins it to
    /// the target seconds (capped by what the clip can supply); otherwise the
    /// clip keeps its trimmed length.
    func entryOutputSeconds(_ entry: LapseCollection.Entry, in collection: LapseCollection) -> Double {
        guard let kenBurns = collection.kenBurns, kenBurns.enabled, kenBurns.consistentDurations else {
            return entrySeconds(entry)
        }
        let target = Double(kenBurnsEffectiveClipSeconds(collection))
        guard let blend = blends.first(where: { $0.id == entry.blendID }),
              let full = blendDuration(for: blend) else { return target }
        if kenBurns.autoAdjustSpeed {
            // Longer clips speed up to the target; a clip that can't fill it
            // just plays out (only-if-required goes one way).
            return min(target, entrySeconds(entry))
        }
        return min(target, full)
    }

    /// A crossfade can't outlast half of either neighbour.
    func kenBurnsFadeSeconds(outgoing: Double, incoming: Double) -> Double {
        max(0, min(LapseCollection.fadeSeconds, outgoing / 2, incoming / 2))
    }

    /// The longest consistent clip duration the timeline supports: the
    /// shortest clip's length, rounded down to whole seconds. Auto-speed
    /// compresses each clip's kept (trimmed) range, so that range is the
    /// supply; window mode ignores the stored out point and slides a window
    /// anywhere in the clip, so there the whole clip is. Clips whose
    /// durations haven't probed yet don't get to drag the cap to zero.
    func kenBurnsMaxClipSeconds(_ collection: LapseCollection) -> Int {
        let lengths: [Double]
        if collection.kenBurnsUsesWindows {
            lengths = collection.entries.compactMap { entry in
                blends.first { $0.id == entry.blendID }.flatMap(blendDuration(for:))
            }
        } else {
            lengths = collection.entries.map(entrySeconds)
        }
        guard let shortest = lengths.filter({ $0 > 0.5 }).min() else { return 1 }
        return max(1, Int(shortest.rounded(.down)))
    }

    /// What the export actually uses: the stored preference clamped to what
    /// the timeline currently allows.
    func kenBurnsEffectiveClipSeconds(_ collection: LapseCollection) -> Int {
        guard let kenBurns = collection.kenBurns else { return kenBurnsMaxClipSeconds(collection) }
        return min(max(1, kenBurns.clipSeconds), kenBurnsMaxClipSeconds(collection))
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
    /// render's recipe matches, exporting again is instant. With Ken Burns off
    /// the string is byte-identical to what it always was, so existing kept
    /// renders stay instant across the feature arriving.
    func collectionRecipe(_ collection: LapseCollection) -> String {
        var lead = ["\(collection.ratioRaw ?? "—")@\(collectionExportFPS(collection))"]
        let kenBurnsOn = collection.kenBurnsEnabled
        if kenBurnsOn, let kenBurns = collection.kenBurns {
            lead.append(
                "kb:cd\(kenBurns.consistentDurations ? 1 : 0)"
                + "s\(kenBurnsEffectiveClipSeconds(collection))"
                + "spd\(kenBurns.autoAdjustSpeed ? 1 : 0)"
                + "f\(kenBurns.fadeTransition ? 1 : 0)")
        }
        let parts = collection.entries.map { entry -> String in
            let crop = resolvedCropOffset(entry: entry, in: collection)
                .map { String(format: "%.4f", $0) } ?? "fit"
            var part = "\(entry.blendID.uuidString):\(String(format: "%.4f", entry.inPoint))-\(String(format: "%.4f", entry.outPoint))@\(crop)"
            if kenBurnsOn {
                let move = kenBurnsResolvedMove(entry: entry, in: collection)
                part += String(
                    format: "~%.3f,%.3f,%.3f>%.3f,%.3f,%.3f",
                    move.start.zoom, move.start.centerX, move.start.centerY,
                    move.end.zoom, move.end.centerX, move.end.centerY)
            }
            return part
        }
        return (lead + parts).joined(separator: "|")
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

    /// `LL_PROJECT_SCANNER` screenshot hook: a whole Scanner shoot, fabricated.
    ///
    /// It exists for the same reason every other Scanner hook does, one step
    /// further downstream. A Scanner project cannot be reached on a simulator
    /// by any amount of tapping — there is no camera to difference frames from,
    /// no scene to disturb and nothing flat to find a rectangle in — so the
    /// screen that presents the finished set has no way to be seen, let alone
    /// mirrored against its SVG.
    ///
    /// The fake goes in through the **real** registration path, deliberately: a
    /// staging directory of numbered stills and a `frames.timestamps` written
    /// the way the camera writes it, handed to `setSource`. So it exercises the
    /// sidecar copy, the `captureMode` stamp and the sibling handling rather
    /// than sidestepping them, and the resulting project is a real one — the
    /// perspective correction runs on it, and deleting it deletes files.
    ///
    /// The corners are left **uncorrected** by default: that is the state a
    /// shoot ends in, and the one the Correct-perspective action exists for.
    /// `corrected: true` runs that same action's `correctSequence` call on the
    /// way in, for the other half of the screen's life.
    /// `LL_SCANS=seed` screenshot hook: the three sessions the Scans list is
    /// drawn from — a finished A4 document, a part-corrected 4×6 set, and a
    /// Letter set the detector never found a rectangle in — so the list's three
    /// correction states (pill, ring, nothing at all) are all real rather than
    /// states only prose can describe.
    func debugSeedScanLibrary() {
        guard scanSessions.isEmpty else { return }
        let now = Date()
        debugSeedScannerProject(
            poses: 12, corrected: false, paper: .letter,
            createdAt: Calendar.current.date(byAdding: .day, value: -1, to: now),
            spacingSeconds: 30, detectRectangles: false)
        debugSeedScannerProject(
            poses: 3, corrected: true, paper: .fourBySix,
            createdAt: now.addingTimeInterval(-3 * 3600), spacingSeconds: 20, correctedLimit: 2)
        debugSeedScannerProject(poses: 8, corrected: true, paper: .a4, spacingSeconds: 27)
    }

    /// `LL_SCANS_DOCS` screenshot hook: files a seeded session's pages into
    /// documents, as if the run had opened one at each of `starts`.
    ///
    /// Goes through `ScanDocumentStore.build` rather than writing groups of its
    /// own, so the staged screen is built by the same code a real run's
    /// boundaries go through.
    func debugSeedScanDocuments(for sessionID: UUID, starts: [Int]) {
        guard let capture = captures.first(where: { $0.id == sessionID }) else { return }
        let documents = ScanDocumentStore.build(
            starts: starts, pageNumbers: scanPageNumbers(for: capture))
        try? ScanDocumentStore.save(documents, to: scanSourceFolder(for: sessionID))
        scanDocumentsToken &+= 1
    }

    /// - Parameters:
    ///   - paper: stamped on the session, so the list badges it and the pages
    ///     are drawn at that stock's proportions.
    ///   - correctedLimit: corrects only the first N pages, which is the only
    ///     way to stage the partial ring — a real half-corrected set comes
    ///     from a correction pass that was interrupted.
    ///   - createdAt: back-dates the session, for the list's date sections.
    ///   - detectRectangles: false writes a sidecar with no corners at all, the
    ///     state where no correction is possible and no indicator is shown.
    @discardableResult
    func debugSeedScannerProject(
        poses: Int = 12,
        corrected: Bool = false,
        paper: PerspectiveAspect = .auto,
        createdAt: Date? = nil,
        spacingSeconds: Double = 6,
        correctedLimit: Int? = nil,
        detectRectangles: Bool = true
    ) -> UUID? {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-demo-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true)) != nil else { return nil }
        guard let writer = FrameTimestampWriter(directory: staging) else { return nil }

        var urls: [URL] = []
        let shotAt = createdAt ?? Date()
        let start = shotAt.addingTimeInterval(-Double(poses) * spacingSeconds)
        for index in 0..<poses {
            // The page drifts a little between poses, the way a real hand
            // leaves it, so the grid doesn't read as twelve copies of one file.
            let drift = Double(index) * 0.004
            let quad = NormalizedQuad(
                topLeft: .init(x: 0.185 + drift, y: 0.815 - drift / 2),
                topRight: .init(x: 0.826 + drift, y: 0.833),
                bottomLeft: .init(x: 0.122 + drift, y: 0.196),
                bottomRight: .init(x: 0.884 + drift, y: 0.181 + drift / 2),
                confidence: 0.9)
            let url = staging.appendingPathComponent(String(format: "frame-%05d.jpg", index + 1))
            guard Self.writeDemoScannerFrame(quad: quad, number: index + 1, to: url) else { continue }
            urls.append(url)
            writer.append(FrameTimestamps.Entry(
                frame: index,
                captureTime: start.addingTimeInterval(Double(index) * spacingSeconds),
                shutter: 1.0 / 120,
                iso: 200,
                ev: -0.3,
                // One pose in six with nothing flat in view, so the header's
                // "on N of M" line and the grid's mixed state are real rather
                // than a phrase nothing can produce.
                rectangle: !detectRectangles || index % 6 == 5 ? nil : quad))
        }
        writer.close()
        guard !urls.isEmpty else { return nil }

        setSource(.photos(urls), mode: Self.scannerCaptureMode, captureMode: .scanner)
        let id = captures.first?.id
        if let index = captures.firstIndex(where: { $0.id == id }) {
            captures[index].scannerPaper = paper.rawValue
            if let createdAt { captures[index].createdAt = createdAt }
            captures.sort { $0.createdAt > $1.createdAt }
            try? persistLibrary()
        }
        if corrected, let capture = captures.first(where: { $0.id == id }) {
            let folder = projectFolderURL(for: capture).appendingPathComponent("source")
            PerspectiveCorrector.correctSequence(in: folder, aspect: paper)
            // A half-corrected set is what an interrupted correction leaves
            // behind, and it is the only way to stage the partial ring.
            if let correctedLimit {
                for number in (correctedLimit + 1)...max(poses, correctedLimit + 1) {
                    try? FileManager.default.removeItem(
                        at: folder.appendingPathComponent(String(
                            format: "frame-%05d%@.heic",
                            number, PerspectiveCorrector.correctedSuffix)))
                }
            }
        }
        // `setSource` opens the capture into the blend flow; this hook wants the
        // project screen, so hand the stage back before the tab switch.
        reset()
        return id
    }

    /// One fabricated pose: a desk, a keystoned page traced from `quad`, and
    /// enough type-like ruling that a thumbnail reads as a document rather than
    /// a white box.
    private static func writeDemoScannerFrame(
        quad: NormalizedQuad, number: Int, to url: URL
    ) -> Bool {
        let width = 900, height = 1200
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return false }
        context.setFillColor(CGColor(red: 0.16, green: 0.15, blue: 0.14, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // The quad is bottom-left-origin normalised, which is exactly what a
        // CGContext is, so the page draws with no flip.
        func point(_ corner: NormalizedQuad.Point) -> CGPoint {
            CGPoint(x: corner.x * Double(width), y: corner.y * Double(height))
        }
        context.beginPath()
        context.move(to: point(quad.topLeft))
        context.addLine(to: point(quad.topRight))
        context.addLine(to: point(quad.bottomRight))
        context.addLine(to: point(quad.bottomLeft))
        context.closePath()
        context.setFillColor(CGColor(red: 0.95, green: 0.94, blue: 0.91, alpha: 1))
        context.fillPath()

        context.setFillColor(CGColor(red: 0.35, green: 0.33, blue: 0.31, alpha: 1))
        let left = point(quad.bottomLeft).x + 60
        let right = point(quad.bottomRight).x - 60
        let bottom = point(quad.bottomLeft).y + 90
        let top = point(quad.topLeft).y - 120
        var y = top
        var line = 0
        while y > bottom {
            let width = (right - left) * (line % 4 == 3 ? 0.55 : 0.92)
            context.fill(CGRect(x: left, y: y, width: width, height: 14))
            y -= 46
            line += 1
        }

        guard let image = context.makeImage() else { return false }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
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

    func setSource(_ source: Source, mode: String = "Import", captureMode: CaptureProjectMode? = nil) {
        do {
            let capture = try registerCapture(from: source, mode: mode, captureMode: captureMode)
            openCapture(capture)
        } catch {
            errorMessage = "Couldn't preserve the capture: \(error.localizedDescription)"
        }
    }

    /// A finished **scan**: registered, opened in the Scans tab, and corrected
    /// on its own.
    ///
    /// Deliberately not `setSource`, which ends in `openCapture` — the blend
    /// flow. That is the right destination for every other capture the camera
    /// makes and the wrong one for this: a scan's next step is reading it,
    /// exporting it or re-correcting a page, none of which live behind a screen
    /// asking how many frames to average together. Scans are excluded from
    /// Projects and Gallery for the same reason (`libraryCaptures`), so sending
    /// one to the blend screen would also have been sending it to the one place
    /// the library no longer lists it.
    /// `documentStarts` is the capture screen's record of where each document
    /// began: the 1-based page number that opened it. Empty (or one entry) is a
    /// sitting that produced a single document, which writes no sidecar at all
    /// — see `ScanDocumentStore.save`.
    func finishScannerCapture(urls: [URL], mode: String, documentStarts: [Int] = []) {
        do {
            let capture = try registerCapture(from: .photos(urls), mode: mode, captureMode: .scanner)
            let documents = ScanDocumentStore.build(
                starts: documentStarts, pageNumbers: scanPageNumbers(for: capture))
            if documents.count > 1 {
                try? ScanDocumentStore.save(documents, to: scanSourceFolder(for: capture.id))
            }
            requestedScanDetailID = capture.id
            autoCorrectScan(capture)
        } catch {
            errorMessage = "Couldn't preserve the capture: \(error.localizedDescription)"
        }
    }

    /// Rectifies a scan's pages the moment it is registered, at the stock the
    /// run was shot on.
    ///
    /// The correction used to wait behind a button, on the reasoning that it is
    /// seconds of GPU work and the paper stock is the operator's call. Both
    /// halves have since answered themselves: the stock is now *recorded on the
    /// run* (`scannerPaper`), so there is nothing left to ask, and a scan whose
    /// pages are still keystoned is not yet the thing the operator was making —
    /// leaving it a tap away meant a set could be exported un-rectified without
    /// anyone noticing.
    ///
    /// Only for a run that named its stock: PAPER = Auto is the turntable case,
    /// whose frames are poses of an object rather than pages, and rectifying
    /// those would be a distortion rather than a correction.
    func autoCorrectScan(_ capture: CaptureProject) {
        let paper = scannerPaper(for: capture)
        guard paper != .auto else { return }
        let correctable = scannerSidecar(for: capture)?.entries.filter { $0.rectangle != nil }.count ?? 0
        guard correctable > 0 else { return }
        runScanCorrection(capture, aspect: paper, total: correctable)
    }

    /// The pass itself, shared by the automatic run and the manual re-run.
    ///
    /// `correctSequence` is synchronous and GPU-bound, so it goes to a detached
    /// task; every progress tick hops back to the main actor, which is where the
    /// header reads it and where the page grid is told to reload so each
    /// rectified page appears as it lands rather than all at the end.
    func runScanCorrection(_ capture: CaptureProject, aspect: PerspectiveAspect, total: Int) {
        let id = capture.id
        guard scanCorrections[id]?.isRunning != true else { return }
        let folder = captureFolderURL(for: capture.id).appendingPathComponent("source")
        scanCorrections[id] = ScanCorrection(completed: 0, total: total)
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = PerspectiveCorrector.correctSequence(in: folder, aspect: aspect) { done, count in
                Task { @MainActor [weak self] in
                    self?.scanCorrections[id] = ScanCorrection(completed: done, total: count)
                }
            }
            await MainActor.run { [weak self] in
                // A re-run overwrites files already on screen, so the tiles have
                // to be told; a first run writes files nobody has decoded.
                ProjectThumbnailCache.shared.invalidate(urls: result.written)
                self?.scanCorrections[id] = nil
                if !result.failures.isEmpty {
                    LLog("scan correction: \(result.written.count) written,"
                         + " \(result.failures.count) failed")
                }
            }
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
        timeSlice = nil
        timeSliceVariations = nil
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
            timeSlice = nil
            timeSliceVariations = nil
            clearWarpHistory()
            // Seed from the project's persistent frame nominations so the
            // user doesn't have to re-exclude them each blend session.
            excludedFrameIndices = nominatedExcludedIndices(for: capture)
            loadFramingLock(for: capture)
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
            // A sliced clip re-opens with its slicing recipe armed; anything
            // else starts with slicing off.
            timeSlice = blend.timeSlice
            // …and a clip that came out of a variation batch re-opens with
            // that batch armed, seed included, so re-rendering reproduces the
            // whole set rather than one member of it.
            timeSliceVariations = blend.timeSlice?.variation.map {
                TimeSliceVariationPlan(count: $0.count, mode: $0.mode, seed: $0.seed)
            }
            clearWarpHistory()
            // Seed from the project's persistent frame nominations.
            excludedFrameIndices = nominatedExcludedIndices(for: capture)
            loadFramingLock(for: capture)
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

    /// For a photo source, how many output frames the current settings yield.
    /// The compiled interval timeline is the answer wherever it exists; the
    /// constant-depth arithmetic covers what it can't schedule (a single
    /// still, the whole-shoot stack).
    var photoOutputFrameCount: Int? {
        guard let capture = currentCapture, capture.kind == .photos else { return nil }
        if let compiled = compiledIntervalWarp() { return compiled.outputFrames }
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
        // Stills: the compiled interval schedule is exact, and there is no
        // legacy whole-clip hypothetical to fall back to.
        if case .photos = source {
            guard speed == nil, let compiled = compiledIntervalWarp(),
                  compiled.outputFrames > 0 else { return nil }
            return Double(compiled.outputFrames) / Double(max(1, outputFPS))
        }
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

    /// Which vocabulary the Adjust timeline speaks for the current source: a
    /// movie's ×-real-time speeds, or an interval shoot's blend depths
    /// (photos per output frame) over the capture clock.
    enum WarpVocabulary: Equatable {
        case video
        /// `hasClock` distinguishes a real capture-seconds axis from the
        /// frame-count fallback, which is what the axis labels key on.
        case interval(hasClock: Bool)
    }

    var warpVocabulary: WarpVocabulary {
        if case .photos = source {
            return .interval(hasClock: stillsFrameAxis()?.hasClock ?? false)
        }
        return .video
    }

    /// The stills shoot's time axis, cached per capture: elapsed capture
    /// seconds where a covering `frames.timestamps` exists, else uniform over
    /// the probed span, else frame units (span = the frame count). Answered
    /// synchronously because the timeline's body asks per redraw; the read
    /// behind the cache is one NDJSON sidecar, once — the same bargain
    /// `isScannerProject` strikes.
    private var stillsAxisCache: [UUID: FrameAxis] = [:]
    func stillsFrameAxis() -> FrameAxis? {
        guard case .photos(let urls) = source, let capture = currentCapture,
              urls.count > 1 else { return nil }
        if let cached = stillsAxisCache[capture.id] { return cached }
        let elapsed = FrameTimestamps.load(besideFrames: urls)?
            .elapsedSeconds(coveringExactly: urls.count)
        let axis = FrameAxis(
            frameCount: urls.count,
            elapsedSeconds: elapsed,
            uniformDuration: capture.sourceDurationSeconds ?? Double(urls.count))
        stillsAxisCache[capture.id] = axis
        return axis
    }

    /// What "Reset" returns a stretch's speed to: the video project speed, or
    /// the interval shoot's baseline depth.
    var warpResetSpeed: Double {
        if case .photos = source { return Double(max(1, photoBlendDepth)) }
        return Double(max(1, constantWindow))
    }

    /// Per-stretch output-frame shares from whichever compiler serves the
    /// current source — what the timeline bar draws its widths from.
    func warpStretchOutputFrames() -> [Int]? {
        if case .photos = source { return compiledIntervalWarp()?.stretchWindows }
        return compiledWarp()?.stretchFrames
    }

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
        // Stills: a saved timeline can predate its axis — the metadata probe
        // may have upgraded a frame-count axis to real capture seconds since
        // the blend that stored it was made. A uniform rescale lands every
        // boundary on the same fraction of the shoot it was authored at.
        if case .photos = source {
            guard let span = stillsFrameAxis()?.span, span > 0,
                  timeline.sourceSeconds > 0.01,
                  abs(timeline.sourceSeconds - span) > span * 0.001 else { return timeline }
            var healed = timeline
            let scale = span / timeline.sourceSeconds
            healed.bounds = timeline.bounds.map { $0 * scale }
            return healed
        }
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
        // Stills: one stretch spanning the shoot's axis at the baseline depth
        // — the whole-shoot BLEND slider, restated as a timeline.
        if case .photos = source {
            return WarpTimeline(
                sourceSeconds: stillsFrameAxis()?.span ?? 0,
                speed: Double(max(1, photoBlendDepth)))
        }
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
        case .photos(let urls):
            // The still on screen at this axis moment — the frame the loader
            // decodes whole, so the seconds half carries nothing.
            guard let axis = stillsFrameAxis(), !urls.isEmpty else { return nil }
            let index = min(max(0, axis.index(atSecond: time)), urls.count - 1)
            return (urls[index], 0)
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

    /// Everything the interval compile depends on — the same bargain as the
    /// video memo above: the estimate card and the bar ask per body
    /// evaluation, and walking thousands of frames each time is real work.
    private struct CompiledIntervalMemo {
        var timeline: WarpTimeline
        var outputFPS: Int
        var captureID: UUID?
        var frameCount: Int
        var value: IntervalWarp.Compiled?
    }
    private var compiledIntervalMemo: CompiledIntervalMemo?

    /// The interval timeline compiled into the stacker's window schedule —
    /// what a stills render will do and what its estimate reports. nil for
    /// video sources, single stills, and the whole-shoot single-image stack
    /// (which has no sequence to schedule). The Advanced ramp is deliberately
    /// not consulted: it is video vocabulary, and for stills the timeline IS
    /// the depth control.
    func compiledIntervalWarp() -> IntervalWarp.Compiled? {
        guard case .photos(let urls) = source, !photosProduceSingleImage,
              let axis = stillsFrameAxis() else { return nil }
        let timeline = activeWarp()
        if let memo = compiledIntervalMemo,
           memo.timeline == timeline,
           memo.outputFPS == outputFPS,
           memo.captureID == currentCaptureID,
           memo.frameCount == urls.count {
            return memo.value
        }
        let compiled = IntervalWarp.compile(
            frameSeconds: (0..<axis.frameCount).map { axis.second(atIndex: $0) },
            hasClock: axis.hasClock,
            bounds: timeline.bounds,
            depths: timeline.speeds,
            outputFPS: Double(max(1, outputFPS)))
        compiledIntervalMemo = CompiledIntervalMemo(
            timeline: timeline, outputFPS: outputFPS,
            captureID: currentCaptureID, frameCount: urls.count, value: compiled)
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
        // A person changed this project — see CaptureProject.modifiedAt.
        captures[index].modifiedAt = Date()
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
        // And an edit for the same reason: this is the ACCEPTED "Auto rename &
        // tag" proposal, which renames the project. The silent pass that put
        // tags there in the first place (`applyAutomaticTags`) is not stamped —
        // nobody chose it.
        captures[index].modifiedAt = Date()
        try? persistLibrary()
    }

    /// Sets a project's subject tags directly, from the tag editor.
    ///
    /// Separate from `applySceneMetadata` because that one is "the user accepted a proposal" — it
    /// renames, and it writes elements too. This is the smaller thing: someone added or dropped a
    /// tag by hand, on a project whose name and elements are none of its business.
    ///
    /// Writes on every change, with no Apply step, which is the same bargain `renameProject`
    /// makes: one tap to reverse, and a confirmation would have to promise a rollback the Gallery
    /// panel's inline field cannot offer anyway.
    func setSceneTags(_ tags: [String], on capture: CaptureProject) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        // Trimmed and de-duplicated case-insensitively here as well as in the editor: this is the
        // only door onto the field, and a duplicate would filter and search as a separate thing.
        var cleaned: [String] = []
        for tag in tags {
            let value = SceneMetadata.normalizedTag(tag)
            guard !value.isEmpty else { continue }
            let canonical = SceneMetadata.canonicalTag(for: value) ?? value
            guard !cleaned.contains(where: { $0.caseInsensitiveCompare(canonical) == .orderedSame })
            else { continue }
            cleaned.append(canonical)
        }
        guard cleaned != (captures[index].sceneTags ?? []) else { return }

        captures[index].sceneTags = cleaned.isEmpty ? nil : cleaned
        // A person chose these now, whatever put them there first — so the "tagged automatically"
        // marker comes off the card, exactly as accepting a proposal does.
        captures[index].sceneTaggedAutomatically = nil
        captures[index].modifiedAt = Date()
        try? persistLibrary()
        // Tags are keywords (Part 2 §4.5): the same list lands in the project record's edited
        // layer, where an export will read `dc:subject` from and where "from file / edited here"
        // is answered.
        writeProjectKeywords(cleaned, for: captures[index])
    }

    /// Seeds a project's tags from the keywords its files carried — only when it has none of its
    /// own, so a person's list is never overwritten by a re-read. Called when the asset recorder
    /// finishes a project (`recordAssets`), off the main persist path.
    func seedSceneTags(_ keywords: [String], on captureID: UUID) {
        guard !keywords.isEmpty,
              let index = captures.firstIndex(where: { $0.id == captureID }),
              captures[index].sceneTags == nil
        else { return }
        captures[index].sceneTags = keywords
        persistLibraryOffMain()
    }

    /// Every tag already used somewhere in this library, taxonomy first, then hand-typed ones.
    /// The tag picker offers these under YOUR TAGS, so a word is typed once and tapped after that.
    var libraryTags: [String] { captures.presentSceneTags }

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
            // A person changed this project — see CaptureProject.modifiedAt.
            captures[index].modifiedAt = Date()
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

    // MARK: - Source format

    /// What a project's source assets ARE: the file type they were written in,
    /// and whether the shoot asked for a flat/log profile. Both halves are
    /// invisible in every other line the card shows — "Interval · 214 photos"
    /// says nothing about DNG vs JPG, and nothing at all says a run was shot
    /// flat, which is the difference between footage that is ready to look at
    /// and footage that still wants a grade.
    struct SourceFormatSummary: Equatable {
        /// Uppercased file types, first-seen order: ["DNG"], ["JPG"], ["MOV"],
        /// or more than one for a mixed import.
        var formats: [String]
        /// Capture Flat was on for this run — for video, either the request or
        /// the Apple Log that actually engaged.
        var flat: Bool

        /// "DNG" / "MOV · FLAT"; nil when the project's files carry no
        /// extension at all, which is the only case with nothing to say.
        var label: String? {
            guard !formats.isEmpty else { return nil }
            return (formats + (flat ? ["FLAT"] : [])).joined(separator: " · ")
        }
    }

    /// Summaries already read this session. A source folder's file types and
    /// its capture sidecars are written once at registration and never edited,
    /// so an entry is good for as long as the app runs.
    private var sourceFormatCache: [UUID: SourceFormatSummary] = [:]

    /// The Projects card's format pill. The formats come straight off the
    /// project's own file list; only the flat flag costs a disk read, so the
    /// whole thing rides the same off-main queue as the other per-card walks.
    /// Returns nil only when the read was cancelled (the row scrolled away).
    func sourceFormatSummary(for capture: CaptureProject) async -> SourceFormatSummary? {
        if let known = sourceFormatCache[capture.id] { return known }
        let formats = capture.sourceFormatLabels
        let folder = captureFolderURL(for: capture.id)
        let summary = await MediaWorkQueue.shared.run { () -> SourceFormatSummary in
            SourceFormatSummary(formats: formats, flat: Self.capturedFlat(inProjectFolder: folder))
        }
        guard let summary else { return nil }
        sourceFormatCache[capture.id] = summary
        return summary
    }

    /// Whether the shoot behind a project folder was captured flat, read from
    /// whichever sidecar its capture path writes: stills record the toggle in
    /// `capture_log.json`, video records both the request and whether Apple Log
    /// engaged in `sequence.json`. False for imports and for anything captured
    /// before either field existed — the pill says FLAT only when a sidecar
    /// says so outright.
    nonisolated private static func capturedFlat(inProjectFolder root: URL) -> Bool {
        let source = root.appendingPathComponent("source", isDirectory: true)
        let logURL = source.appendingPathComponent(CaptureExposureLog.sessionFileName)
        if let session = try? CaptureExposureLog.loadSession(from: logURL) {
            return session.captureFlat == true
        }
        let sequenceURL = source.appendingPathComponent("sequence.json")
        if let data = try? Data(contentsOf: sequenceURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let sequence = try? decoder.decode(LiveCaptureSequence.self, from: data) {
                return sequence.captureFlat == true || sequence.appleLog == true
            }
        }
        return false
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

    /// Captures whose source frames have all passed an existence check this
    /// session — the ticket `source(for:)` checks before its per-frame
    /// `fileExists` walk. Lives and dies with the size cache above: the same
    /// file-mutating persists invalidate both.
    private var validatedSourceFrames: Set<UUID> = []

    /// Drops one project's cached size — for paths that change a folder's
    /// contents without persisting the library (field notes today).
    func invalidateStorageCache(for id: UUID) {
        projectStorageBytes[id] = nil
        validatedSourceFrames.remove(id)
    }

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
                    // Field notes count with the originals: captured material
                    // that belongs to the project, typically kilobytes — not
                    // worth a fourth legend category, but the library total
                    // must keep matching the per-project (whole-folder) sizes.
                    storage.originalsBytes += Self.directorySize(folder.appendingPathComponent("notes"))
                    storage.versionsBytes += Self.directorySize(folder.appendingPathComponent("blends"))
                }
            }
            if let items = try? fileManager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) {
                for item in items where Self.isCacheItem(item) {
                    storage.cacheBytes += Self.directorySize(item)
                }
            }
            // Thumbnails are a cache in every sense — one JPEG per source
            // asset, regenerated on demand — and on a big library they are the
            // largest one. They were invisible here (and unclearable) until
            // 2026-08-26, so the card charged the user for bytes no button in
            // the app could free.
            storage.cacheBytes += Self.directorySize(DiskThumbnailStore.directory)
            return storage
        }
    }

    // MARK: - When a project arrived and was last edited, and how big it is

    /// The date the **Added** sort reads: when this project turned up in this
    /// library.
    ///
    /// The stored stamp, and the capture date for anything that somehow has
    /// none — a project registered while a write failed, or one restored from a
    /// manifest the backfill never saw. That fallback is exactly right for
    /// everything shot on this device (where arriving and being shot are the
    /// same event) and only wrong by the age of the shoot for an old import,
    /// which is the same answer the library gave before this field existed.
    func addedAt(_ capture: CaptureProject) -> Date {
        capture.addedAt ?? capture.createdAt
    }

    /// The date the Projects list's **Edit** sort reads.
    ///
    /// `modifiedAt` when a human has changed the project since the field
    /// existed. Otherwise the newest blended clip's date, which is the best
    /// retroactive evidence a library has that somebody worked on a shoot —
    /// and failing that the capture date, so the sort degrades to Capture
    /// order for a project nobody has ever touched rather than to 1970.
    func lastEdited(_ capture: CaptureProject) -> Date {
        if let modifiedAt = capture.modifiedAt { return modifiedAt }
        let newestBlend = blends.lazy.filter { $0.captureID == capture.id }.map(\.createdAt).max()
        return newestBlend ?? capture.createdAt
    }

    /// Records that a human just changed this project. Call it beside the
    /// mutation, before the `persistLibrary()` that saves it — see
    /// `CaptureProject.modifiedAt` for what does and does not count.
    func markEdited(_ captureID: UUID) {
        guard let index = captures.firstIndex(where: { $0.id == captureID }) else { return }
        captures[index].modifiedAt = Date()
    }

    /// Whether the stored size can still be believed: never measured, or
    /// measured before the last edit, which is the only thing that can have
    /// changed the files.
    func needsSizeMeasurement(_ capture: CaptureProject) -> Bool {
        guard capture.sizeBytes != nil, let measured = capture.sizeMeasuredAt else { return true }
        return measured < lastEdited(capture)
    }

    /// True while `measureProjectSizes` is walking. The Projects list says so
    /// rather than leaving a size sort silently half-ordered.
    @Published private(set) var isMeasuringSizes = false

    /// Brings every project's stored size up to date, one at a time off the
    /// main actor.
    ///
    /// Called when the Projects list is asked to sort by size. Results land in
    /// `captures` as they arrive, so the list re-orders visibly rather than
    /// waiting on the slowest project; the manifest is written ONCE at the end,
    /// because `persistLibrary` drops the in-memory size cache and doing that
    /// per project would have each measurement invalidate the next.
    ///
    /// Cheap on the second run by construction: only projects edited since
    /// their last measurement are walked, which on a settled library is none.
    func measureProjectSizes() async {
        guard !isMeasuringSizes else { return }
        let pending = captures.filter(needsSizeMeasurement).map(\.id)
        guard !pending.isEmpty else { return }
        isMeasuringSizes = true
        defer { isMeasuringSizes = false }
        LLog("project sizes: measuring \(pending.count) of \(captures.count)")
        var measuredAny = false
        for id in pending {
            let folder = captureFolderURL(for: id)
            guard let bytes = await MediaWorkQueue.shared.run({ Self.directorySize(folder) }) else {
                continue
            }
            // Re-found by id: the library can have moved under a walk that
            // took a while, and an index captured before the await is a
            // different project by the time it returns.
            guard let index = captures.firstIndex(where: { $0.id == id }) else { continue }
            captures[index].sizeBytes = bytes
            captures[index].sizeMeasuredAt = Date()
            measuredAny = true
        }
        guard measuredAny else { return }
        do {
            try persistLibrary()
        } catch {
            LLog("project sizes: could not persist — \(error.localizedDescription)")
        }
    }

    /// Bytes on disk for one project. Returns nil when the walk was cancelled
    /// (the row scrolled away, the screen closed) — callers must keep whatever
    /// they were showing rather than reading nil as "no files".
    func storageBytes(for capture: CaptureProject) async -> Int64? {
        if let known = projectStorageBytes[capture.id] { return known }
        // The stored measurement, while nothing has edited the project since
        // it was taken. `persistLibrary` drops the in-memory cache above on
        // every library write, so without this a project detail screen paid
        // for a full directory walk after every unrelated save.
        if let stored = capture.sizeBytes, !needsSizeMeasurement(capture) { return stored }
        let folder = captureFolderURL(for: capture.id)
        guard let bytes = await MediaWorkQueue.shared.run({ Self.directorySize(folder) }) else {
            return nil
        }
        projectStorageBytes[capture.id] = bytes
        return bytes
    }

    /// Deletes reproducible temp files (imports, live-capture staging, blend
    /// scratch) and the thumbnail store. Returns the number of bytes freed.
    ///
    /// The thumbnails are here because this button is what a user presses when
    /// a picture is visibly wrong, and until 2026-08-26 it was the one cache it
    /// did not touch — so a bad tile survived pressing it, survived a relaunch,
    /// and survived the fix that generated it correctly.
    @discardableResult
    func clearCache() async -> Int64 {
        let temporary = FileManager.default.temporaryDirectory
        let freed = await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var freed: Int64 = DiskThumbnailStore.clear()
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
        // The memory tier holds copies of what was just deleted; leaving it
        // would make the clear invisible until the next launch.
        ProjectThumbnailCache.shared.invalidateAll()
        return freed
    }

    /// Every name the app itself puts in `tmp/`. This list IS the contract for
    /// both "Clear cache" and the storage figure — a staging prefix missing here
    /// is a folder the user is charged for and can never clear, so it must be
    /// kept in step with the `temporaryDirectory.appendingPathComponent` calls
    /// in `CameraController` (`live-capture-`, `interval-`, `scanner-`,
    /// `liveblend-`, `liveblend-dng-`), `CreateView` (`import-`) and
    /// `MediaPickers` (`picked-`).
    nonisolated private static func isCacheItem(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("letslapse") || name.hasPrefix(".letslapse")
            || name.hasPrefix("live-capture") || name.hasPrefix("picked-")
            || name.hasPrefix("import-")
            // `liveblend-` covers `liveblend-dng-` too.
            || name.hasPrefix("liveblend-") || name.hasPrefix("interval-")
            || name.hasPrefix("scanner-")
    }

    /// Removes the `tmp/` staging folder a just-registered capture came out of.
    ///
    /// Registration *copies* into `Projects/<uuid>/source/`, so until this runs
    /// every shoot exists twice on disk — once in the project and once as a
    /// ghost in `tmp/` that nothing ever revisits. Callers pass any file from
    /// the staging set; the folder is derived from it.
    ///
    /// Deliberately narrow, because the same registration paths also take files
    /// the user still owns (a Photos pick, a security-scoped file dropped on the
    /// Mac app, an `LL_SEED` path): the folder is only deleted when it is a
    /// *directory*, sitting *directly* in `tmp/`, whose name is one this app
    /// writes. Anything else — including `tmp/` itself — is left alone.
    nonisolated private static func discardStagingFolder(containing url: URL) {
        let staging = url.deletingLastPathComponent().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        guard staging.deletingLastPathComponent().path == temporary.path,
              isCacheItem(staging) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: staging.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        try? FileManager.default.removeItem(at: staging)
    }

    /// A finished clip's size **as a viewer sees it** — natural size through
    /// the preferred transform, so a portrait shoot reports 1080×1920 rather
    /// than the landscape frame it is encoded as. The variation generator
    /// works in display space (a grid's column count applies to the
    /// horizontal axis the viewer sees), so it asks in these terms.
    nonisolated static func displaySize(of url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }
        let display = size.applying(transform)
        let width = abs(display.width), height = abs(display.height)
        guard width >= 1, height >= 1 else { return nil }
        return CGSize(width: width, height: height)
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

    /// The storm gate on the two progress sinks below. The engines report per
    /// frame — thousands of main-actor `@Published` writes per run, each an
    /// object-level invalidation of every mounted screen — which is what froze
    /// screen transitions for the better part of a minute when a 1,249-frame
    /// blend started (perf-audit-2026-08-29.md finding A; the 2026-08-29
    /// 16 Pro screen recording). Progress is monotonic, so publishing at
    /// 10 Hz loses nothing but the storm; terminal fractions always pass so a
    /// band's completion is never dropped.
    private var lastProgressPublish = Date.distantPast
    private func progressGateOpens(fraction: Double) -> Bool {
        if fraction >= 1 { return true }
        let now = Date()
        guard now.timeIntervalSince(lastProgressPublish) >= 0.1 else { return false }
        lastProgressPublish = now
        return true
    }

    /// The single sink for every engine's per-clip fraction: maps it into the
    /// clip's band of the one global bar. Monotonic — a straggling callback
    /// from an earlier clip can't drag the bar backwards.
    private func reportClipProgress(_ clipIndex: Int, fraction: Double) {
        guard stage == .processing else { return }
        guard progressGateOpens(fraction: fraction) else { return }
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
        guard progressGateOpens(fraction: fraction) else { return }
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
        if let sliceBand = activeProgressPlan?.sliceBand, band.upperBound <= sliceBand.lowerBound {
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
        // The processing screen's hero, resolved once for the whole run —
        // resolved in the view body it cost a per-frame existence walk on
        // every progress tick. Before the stage flip, so the screen's first
        // body already has it.
        processingProgress.heroURL = currentCapture.flatMap { mediaURL(for: $0) }
        processingProgress.heroKind = currentCapture.map { mediaKind(for: $0) } ?? .video
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
        // The project's crop — the Edit screen's frame — when it takes
        // anything off. The OPENING moment's: a clip renders at one size, and
        // the crop is static by decision (the timeline carries it whole, never
        // eased), so no later moment can say otherwise. A movie source
        // carries it on whichever geometry pass runs last, exactly as it
        // carries its level (`VideoCanvasCropper`, `VideoGrader.bakedCopy`);
        // a stills blend cuts it in a tail pass of its own over the finished
        // clip, because `ImageStacker` writes every output frame into a pool
        // at the source's size and the per-frame bake cannot change that.
        let projectCrop: FrameCrop? = grade.crop.flatMap { $0.isFull ? nil : $0 }
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
        // change mid-render can't retarget it. A canvas the user chose is
        // re-fitted inside the project crop — the crop first, then the canvas
        // box on what it kept (the one composition rule the two crops have,
        // `VideoCanvasCropper`) — so a canvas that happened to match the
        // SOURCE still runs once the crop has changed the shape.
        //
        // Two values, because the pass and the box are different questions.
        // `runsCanvasPass` says whether the canvas pass runs at all (a real
        // canvas crop, a resolution cap to scale to, or a chosen canvas over
        // a project crop). `cropCanvas` is the box it fits — and it is nil
        // when the user chose NO canvas and the project has a crop: the
        // "as shot" default is the source's nearest ratio, which is nothing
        // to crop on an uncropped clip but would cut a 4:3 box out of the
        // middle of a 16:9 project crop. With no chosen canvas the crop IS
        // the shape.
        let cropIsReal = blendCanvasNeedsCrop()
        let userCanvas = blendCanvasRatio
        let runsCanvasPass = source.isVideo
            && (cropIsReal || exportEdge != nil || (projectCrop != nil && userCanvas != nil))
        let cropCanvas: CanvasRatio? = runsCanvasPass && !(projectCrop != nil && userCanvas == nil)
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
            // The canvas box: the user's choice, or the source's own shape —
            // and NO box at all over a project crop the user chose no canvas
            // for, the same rule as `cropCanvas` above (the crop is the
            // shape; the "as shot" default must not re-cut it).
            let canvas: CanvasRatio? = projectCrop != nil && userCanvas == nil
                ? nil : effectiveBlendCanvas()
            // Derived from the BASE resolution: the finished clip is the size
            // it always was, and the burst's extra pixels are spent on the crop
            // rather than on the file. The project crop is cut first on the
            // no-punch path, so the canvas is fitted inside what it keeps; a
            // punch-in sets it aside instead — the keys were authored over the
            // uncropped picture (see the tail pass below).
            let framedBase = reframeTrack == nil
                ? (projectCrop?.outputSize(for: baseSize) ?? baseSize) : baseSize
            let keptSize: CGSize? = reframeTrack != nil
                ? ReframeVideoCropper.renderSize(displaySize: baseSize, aspect: reframeAspect)
                : (canvas.flatMap { VideoCanvasCropper.cropSize(displaySize: framedBase, canvas: $0) }
                    ?? framedBase)
            guard let keptSize else { return nil }
            let renderSize = exportEdge
                .flatMap { ReframeVideoCropper.scaledDown(keptSize, shortEdge: $0) } ?? keptSize
            return SegmentNormalization(
                renderSize: renderSize,
                canvas: canvas,
                canvasOffset: cropOffset,
                rotationDegrees: grade.rotationDegrees,
                crop: reframeTrack == nil ? projectCrop : nil,
                reframe: reframeTrack.flatMap { track in
                    guard !reframeFrameTimesBySegment.isEmpty,
                          !reframeFrameTimes.isEmpty else { return nil }
                    // ONE pass over the whole clip's frame map, then sliced —
                    // see `rectsBySegment`. `reframeFrameTimes` is the flatMap
                    // of `reframeFrameTimesBySegment`, so the counts line up
                    // exactly and each slice is that segment's own frames.
                    let all = ReframeVideoCropper.rects(
                        track: track,
                        aspect: reframeAspect,
                        sourceSize: baseSize,
                        frameSourceTimes: reframeFrameTimes,
                        outputFPS: outputFPS)
                    var sliced: [[CGRect]] = []
                    var cursor = 0
                    for region in reframeFrameTimesBySegment {
                        let end = min(all.count, cursor + region.count)
                        sliced.append(cursor < end ? Array(all[cursor..<end]) : [])
                        cursor = end
                    }
                    return SegmentNormalization.Reframe(
                        track: track,
                        aspect: reframeAspect,
                        sourceSize: baseSize,
                        frameTimesBySegment: reframeFrameTimesBySegment,
                        rectsBySegment: sliced,
                        outputFPS: outputFPS)
                })
        }()
        // Resolved with the other job inputs — the pass must use the fps the
        // schedules were compiled at, not whatever the user opens mid-render.
        let reframeOutputFPS = outputFPS
        // Which source moment each output frame shows, for a grade that
        // travels. The warp already computes exactly this map (mid-window, on
        // the global concatenated source axis) for the reframe crop; without a
        // warp the two clocks agree and `.direct` is the truth. Nothing but a
        // keyframed grade reads it.
        let gradeMap: GradeSourceMap = {
            guard grade.isKeyframed, !reframeFrameTimes.isEmpty else { return .direct }
            let span = max(
                currentCapture?.sourceDurationSeconds ?? 0, reframeFrameTimes.last ?? 0)
            return GradeSourceMap.from(
                frameSourceSeconds: reframeFrameTimes,
                outputFPS: Double(outputFPS), sourceDuration: span)
        }()
        // The reframe, the crop and the grade are all tail passes over the
        // finished clip; the plan reserves its tail band when any will run.
        // The project crop is one of them on a stills blend (a movie source
        // already counts it in `willBakeGrade`).
        let hasTailPass = willBakeGrade || runsCanvasPass || reframeTrack != nil
            || projectCrop != nil
        // The time-slicing recipe, resolved with the other job inputs. It runs
        // as the LAST tail pass (docs/time-slicing.md §2) — over the finished,
        // verified clip — so a single image (the whole-shoot stack) can't
        // slice and the gate below is on the output kind.
        let sliceSettings = timeSlice
        // A batch is a slicing decision, not a blending one: the blend, the
        // normalize, the stitch, the reframe and the grade all still run
        // exactly once, and only the tail pass repeats (§8 of the brief).
        let sliceVariations = timeSlice == nil ? nil : timeSliceVariations
        let sliceCodec: OutputCodec =
            (blendProfileOverride ?? defaultBlendProfile) == .hevcMain10 ? .hevc : .h264
        // The poster inherits the first source frame's EXIF/GPS on stills
        // sources, the same carryover the whole-shoot stack does.
        let posterSourceURL: URL? = {
            guard case .photos(let urls) = source else { return nil }
            return urls.first
        }()
        beginActivity(.blending)
        blendTask = Task { [weak self] in
            // Every exit from this task — success, cancel, throw — passes here,
            // which is the only way a bracket around a job with this many
            // failure paths stays honest.
            defer { self?.endActivity(.blending) }
            do {
                guard let self else { return }
                var output: ProcessingOutput
                switch source {
                case .video(let url):
                    self.beginProgressPlan(.make(
                        clipFrames: [Int((self.estimatedInputFrames ?? 1).rounded())],
                        hasStitch: false, hasGrade: hasTailPass,
                        hasSlice: sliceSettings != nil))
                    self.processingPhase = .blending(clip: 1, of: 1)
                    output = try await self.blendVideo(
                        url: url, ramp: ramp, fps: fps, linear: linear,
                        trimHeadTailSeconds: trim,
                        customWindows: warpCompiled?.schedules.first)
                case .liveSequence(let liveSource):
                    output = try await self.blendLiveSequence(
                        liveSource, ramp: ramp, fps: fps, linear: linear, burstRamp: burstRamp,
                        willBakeGrade: hasTailPass, willSlice: sliceSettings != nil,
                        warpSchedules: warpCompiled?.schedules,
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
                    //
                    // Off the main actor: this task inherits it (AppModel is
                    // `@MainActor`), and reading + parsing a thousand-line
                    // NDJSON sidecar as a main-actor job lands exactly inside
                    // the Adjust→Processing transition it used to freeze.
                    let frameTimes: [Double]? = await Task.detached(priority: .utility) {
                        FrameTimestamps
                            .load(besideFrames: urls)
                            .flatMap { stamps in
                                stamps.entries.count == urls.count
                                    ? stamps.elapsedSeconds(forOrders: keptOrders)
                                    : nil
                            }
                    }.value
                    // The interval timeline, compiled against exactly the
                    // frames this render feeds: kept frames keep their own
                    // axis moments, so an excluded tail can't slide a stretch
                    // boundary onto different photographs. nil (no axis, or
                    // the whole-shoot stack below) falls back to the legacy
                    // constant-depth schedule, which an untouched timeline
                    // reproduces exactly anyway. The model reads (axis,
                    // timeline) stay on the main actor; the compile itself is
                    // pure math over their values and runs off it.
                    var intervalCompiled: IntervalWarp.Compiled?
                    if photoDepth < filteredURLs.count, let axis = self.stillsFrameAxis() {
                        let timeline = self.activeWarp()
                        let keptSeconds = keptOrders.map { axis.second(atIndex: $0) }
                        let hasClock = axis.hasClock
                        intervalCompiled = await Task.detached(priority: .utility) {
                            IntervalWarp.compile(
                                frameSeconds: keptSeconds,
                                hasClock: hasClock,
                                bounds: timeline.bounds,
                                depths: timeline.speeds,
                                outputFPS: fps)
                        }.value
                    }
                    // The poster fast path (docs/time-slicing-poster-fast-path.md
                    // §2): a run that keeps nothing but a time-slice poster
                    // renders only the master frames the ladder needs, each
                    // still blended at depth, and never encodes, verifies or
                    // re-decodes a clip. Gated on the resolved job inputs;
                    // everything else falls through to the path below
                    // unchanged. The schedule is the SAME one the full render
                    // would run — the compiled warp's windows, else the
                    // constant-depth schedule — so the ladder points at the
                    // same photographs (§3.1).
                    if let sliceSettings, sliceSettings.output == .image,
                       !sliceSettings.includeRegularClip,
                       photoDepth < filteredURLs.count {
                        let windows = intervalCompiled?.windows
                            ?? WindowSchedule.make(
                                totalInputFrames: filteredURLs.count, ramp: .constant(photoDepth))
                        try await self.renderPosterFastPath(
                            urls: filteredURLs, windows: windows, linear: linear, grade: grade,
                            baseline: sliceSettings, variations: sliceVariations,
                            captureID: captureID, parameters: parameters,
                            posterSourceURL: posterSourceURL)
                        return
                    }
                    // Stills bake their grade frame by frame inside the blend,
                    // so no separate grade band exists on this path — only the
                    // crop's tail pass, over the sequence output (the single
                    // stack cuts its still inline).
                    let stillsCropPass = projectCrop != nil && photoDepth < filteredURLs.count
                    self.beginProgressPlan(.make(
                        clipFrames: [filteredURLs.count], hasStitch: false, hasGrade: stillsCropPass,
                        hasSlice: sliceSettings != nil && photoDepth < filteredURLs.count))
                    self.processingPhase = .blending(clip: 1, of: 1)
                    // The project's text overlays, resolved up front — mask
                    // and all — so the blend loop composites from values and
                    // never waits on inference. nil when the project has no
                    // text, which keeps this path byte-identical to before.
                    // Looked up by the captureID this job STARTED with, never
                    // `currentCapture`: the task has suspended by now, and a
                    // selection change mid-render must not retarget which
                    // project's text bakes into this clip (same rule as the
                    // grade and the canvas, resolved before the job).
                    let overlayBake = await self.makeOverlayExportBake(
                        for: self.captures.first { $0.id == captureID })
                    if photoDepth >= filteredURLs.count {
                        // The blend depth spans every still, so fold them all
                        // into one frame: the classic single long exposure.
                        output = try await self.stackPhotos(
                            urls: filteredURLs, linear: linear, grade: grade,
                            overlayBake: overlayBake)
                    } else {
                        // A depth of 1 gives a straight timelapse; larger
                        // depths blend consecutive stills into each frame for
                        // motion blur. Output is a video sequence.
                        output = try await self.blendPhotosSequence(
                            urls: filteredURLs, ramp: .constant(photoDepth), fps: fps,
                            linear: linear, grade: grade, frameTimes: frameTimes,
                            customWindows: intervalCompiled?.windows,
                            customWindowTimes: intervalCompiled?.presentationSeconds,
                            profile: self.blendProfileOverride ?? self.defaultBlendProfile,
                            overlayBake: overlayBake)
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
                // Whether a geometry pass has already levelled the clip. The
                // per-segment normalisation levels before the stitch (and
                // marks the output `geometryBaked`); the two croppers below
                // level as they crop. Whichever did it, the standalone grade
                // pass must not turn the picture a second time.
                var rotationBaked = output.geometryBaked && grade.hasRotation
                // Whether the project crop is settled: cut by a geometry pass,
                // or set aside because one ran that it cannot follow. The
                // per-segment normalisation cut it ahead of its canvas on the
                // no-punch path and set it aside on the punch path (see
                // `SegmentNormalization.crop`); either way the standalone
                // bake must not cut it again — into a canvas box or a punch
                // it was never measured over.
                var cropSettled = output.geometryBaked && projectCrop != nil
                if output.geometryBaked, projectCrop != nil, reframeTrack != nil {
                    output.summary += Self.cropSetAsideSummary
                } else if output.geometryBaked, let projectCrop {
                    output.summary += Self.cropSummary(projectCrop)
                }
                // The punch-in reframe bakes the animated crop into the
                // finished clip — per-frame, at the source moments the
                // compiled schedule says each output frame shows. It renders
                // at the canvas shape, so the static canvas crop below is
                // skipped when this runs — which makes this the last geometry
                // pass whenever it runs, and therefore the grade's ride.
                if let reframeTrack, output.kind == .video, !output.geometryBaked,
                   let reframeSourceSize, !reframeFrameTimes.isEmpty {
                    self.statusMessage = grade.isColorIdentity
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
                        gradeMap: gradeMap,
                        rotationDegrees: grade.rotationDegrees,
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
                    if grade.hasRotation {
                        rotationBaked = true
                        output.summary += Self.levelSummary(grade)
                    }
                    // The punch's keys were authored over the UNCROPPED
                    // levelled picture (the Adjust preview levels but does
                    // not crop — `AdjustPreviewLevel`), so the crop cannot
                    // go before the punch without remapping the keys, nor
                    // after it without cutting a rect measured over a frame
                    // that no longer exists. It is set aside, said in the
                    // summary, and owed in docs/TODO.md.
                    if projectCrop != nil {
                        cropSettled = true
                        output.summary += Self.cropSetAsideSummary
                    }
                    if !grade.isColorIdentity {
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
                //
                // The project's crop rides it too, cut FIRST — the canvas box
                // is then fitted inside it (`VideoCanvasCropper`). And on a
                // stills blend the pass runs for the crop ALONE: the stills'
                // colour, level, masks and text are already baked into every
                // frame, so that pass carries an identity grade, levels
                // nothing, and only cuts — in the clip's own encode, so a
                // 10-bit HEVC blend stays 10-bit.
                let stillsCrop = !source.isVideo && projectCrop != nil
                if runsCanvasPass || stillsCrop, output.kind == .video, reframeTrack == nil,
                   !output.geometryBaked {
                    let passGrade = source.isVideo ? grade : .identity
                    let passLevel = source.isVideo ? grade.rotationDegrees : 0
                    self.statusMessage = Self.cropStatusMessage(
                        canvas: cropCanvas, crop: projectCrop,
                        grade: passGrade.isColorIdentity ? nil : grade.preset.displayName)
                    self.processingPhase = .grading
                    self.tailPhaseStartedAt = Date()
                    self.processingETADate = nil
                    let cropBand = tailBand
                    let uncropped = output.url
                    let report: @Sendable (Double) -> Void = { fraction in
                        Task { @MainActor [weak self] in
                            guard let self, let cropBand else { return }
                            self.reportTailProgress(band: cropBand, fraction: fraction)
                        }
                    }
                    let cropped: (url: URL, renderSize: CGSize?)
                    if runsCanvasPass {
                        // `cropCanvas` may be nil here — a resolution cap
                        // over a project crop with no chosen canvas: the
                        // pass cuts the crop and scales, fitting no box.
                        cropped = try await VideoCanvasCropper.croppedCopy(
                            of: uncropped, canvas: cropCanvas, offset: cropOffset,
                            shortEdge: exportEdge, grade: passGrade, gradeMap: gradeMap,
                            rotationDegrees: passLevel, crop: projectCrop,
                            outputFPS: fps, progress: report)
                    } else if let projectCrop {
                        cropped = try await VideoCanvasCropper.croppedCopy(
                            of: uncropped, crop: projectCrop, grade: passGrade,
                            gradeMap: gradeMap, rotationDegrees: passLevel, outputFPS: fps,
                            profile: self.blendProfileOverride ?? self.defaultBlendProfile,
                            progress: report)
                    } else {
                        cropped = (uncropped, nil)
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
                        if let projectCrop {
                            cropSettled = true
                            output.summary += Self.cropSummary(projectCrop)
                        }
                        // "Fitted" after a project crop: the canvas box was
                        // taken from inside the crop, not from the source.
                        if let cropCanvas, cropIsReal || projectCrop != nil {
                            output.summary += projectCrop != nil
                                ? " · fitted to \(cropCanvas.rawValue)"
                                : " · cropped to \(cropCanvas.rawValue)"
                        }
                        if source.isVideo, grade.hasRotation {
                            rotationBaked = true
                            output.summary += Self.levelSummary(grade)
                        }
                        if source.isVideo, !grade.isColorIdentity {
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
                // The level and the crop ride whichever pass ran; what is
                // left for this one is the colour, and — when nothing
                // geometric ran at all — the level and the crop as well
                // (`VideoGrader.composition` cuts the crop). A settled crop is
                // stripped with the level: every pass that settles it levels
                // first, so there is never a level left over on its own.
                let standaloneGrade = cropSettled
                    ? grade.withoutGeometry
                    : (rotationBaked ? grade.withoutRotation : grade)
                let standaloneNeeded = !standaloneGrade.isIdentity
                    && (!gradeBaked || (standaloneGrade.hasRotation && !rotationBaked))
                if source.isVideo, output.kind == .video, standaloneNeeded {
                    self.statusMessage = standaloneGrade.isColorIdentity
                        ? (standaloneGrade.hasCrop ? "Cropping the clip..." : "Levelling the clip...")
                        : "Baking the \(grade.preset.displayName) grade..."
                    self.processingPhase = .grading
                    self.tailPhaseStartedAt = Date()
                    self.processingETADate = nil
                    let gradeBand = tailBand
                    let ungraded = output.url
                    output.url = try await VideoGrader.bakedCopy(
                        of: ungraded, grade: standaloneGrade, map: gradeMap,
                        outputFPS: fps) { fraction in
                        Task { @MainActor [weak self] in
                            guard let self, let gradeBand else { return }
                            self.reportTailProgress(band: gradeBand, fraction: fraction)
                        }
                    }
                    if let gradeBand {
                        self.reportTailProgress(band: gradeBand, fraction: 1)
                    }
                    if standaloneGrade.hasRotation {
                        output.summary += Self.levelSummary(grade)
                    }
                    // The bake changed the size when it cut the crop: read the
                    // file for it, since the recorded width/height follow their
                    // own convention per path and the crop's pixels were
                    // measured over the oriented frame.
                    if let projectCrop, standaloneGrade.hasCrop, output.url != ungraded,
                       let size = await MediaGeometry.videoDisplaySize(asset: AVURLAsset(url: output.url)) {
                        if let oldWidth = output.width, let oldHeight = output.height {
                            output.summary = output.summary.replacingOccurrences(
                                of: "\(oldWidth)×\(oldHeight)",
                                with: "\(Int(size.width))×\(Int(size.height))")
                        }
                        output.width = Int(size.width)
                        output.height = Int(size.height)
                        output.summary += Self.cropSummary(projectCrop)
                    }
                    if !standaloneGrade.isColorIdentity {
                        output.summary += " · \(grade.preset.displayName) grade baked in"
                    }
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
                // The file, not the plan. Everything above this line is
                // arithmetic — a schedule's frame count carried through the
                // stitch and the tail passes untouched by any of them. Read the
                // clip back before it is filed, so a stage that retimed it fails
                // the render instead of relabelling it (project B0E3269D).
                // Verified before slicing, so the slicer only ever consumes a
                // clip that proved its frame count.
                if output.kind == .video {
                    let measured = try await RenderVerifier.verify(
                        output.url,
                        expectedFrames: output.outputFrames,
                        expectedFPS: fps,
                        stage: "the finishing passes")
                    // Record what landed rather than what was intended: within
                    // tolerance the two can still differ by a frame, and the
                    // manifest is the thing every screen quotes. Only the count
                    // — the recorded width/height follow their own (natural vs
                    // display-oriented) convention per path, and `probedBlendSizes`
                    // already exists to reconcile that.
                    output.outputFrames = measured.frameCount
                }
                if let sliceSettings, output.kind == .video {
                    // Time slicing — deliberately the LAST tail pass
                    // (docs/time-slicing.md §2): geometry and grade are baked
                    // into the file above, so every band carries its own
                    // moment's look. The pass's core is synchronous CPU/IO
                    // work, so it runs detached, with Cancel bridged onto the
                    // renderer's own flag.
                    self.processingPhase = .slicing
                    self.tailPhaseStartedAt = Date()
                    self.processingETADate = nil
                    let sliceBand = self.activeProgressPlan?.sliceBand
                    let masterURL = output.url
                    let temp = FileManager.default.temporaryDirectory

                    // The variation batch (docs/time-slicing.md §10). Nothing
                    // about the expensive half of the run changes: the blend,
                    // the normalize, the stitch, the reframe and the grade all
                    // ran once, above, and their result is the file at
                    // `masterURL`. A variation re-READS that file — it never
                    // re-blends — so its marginal cost is one sequential
                    // decode plus its own slice and encode. Holding the
                    // blended set in RAM instead was never on the table and is
                    // not needed here: see the memory arithmetic in §1 of the
                    // plan.
                    var recipes: [TimeSliceSettings] = [sliceSettings]
                    if let sliceVariations,
                       let masterSize = await Self.displaySize(of: masterURL),
                       let masterFrames = output.outputFrames, masterFrames > 1 {
                        let generated = TimeSliceVariationGenerator.variations(
                            plan: sliceVariations, baseline: sliceSettings,
                            masterFrames: masterFrames,
                            width: Int(masterSize.width.rounded()),
                            height: Int(masterSize.height.rounded()))
                        if !generated.isEmpty { recipes = generated }
                    }
                    let isBatch = recipes.count > 1

                    // What lands in the library: the regular clip only when
                    // asked for — once per RUN, not once per variation — then
                    // the sliced outputs, each with its own id (storeBlend
                    // names the file after it) and with the recipe on the
                    // sliced copies only, so re-rendering the regular clip
                    // never re-slices.
                    var primaryBlend: BlendProject?
                    var primaryOutput: ProcessingOutput?
                    var slicedPrimaryTaken = false
                    // A batch registers the regular clip up front, so a
                    // variation that fails eight renders in doesn't take the
                    // whole run's keepable output with it (plan §3.4). A
                    // single slice keeps the original all-or-nothing order.
                    if isBatch, sliceSettings.includeRegularClip {
                        let regular = try self.storeBlend(
                            output, captureID: captureID, parameters: parameters)
                        primaryBlend = regular
                        primaryOutput = output
                    }

                    for (position, recipe) in recipes.enumerated() {
                        self.statusMessage = isBatch
                            ? "Time slicing — variation \(position + 1) of \(recipes.count)..."
                            : "Time slicing into \(recipe.segments) bands..."
                        let animationURL = recipe.output.wantsAnimation
                            ? temp.appendingPathComponent("LetsLapse-slice-\(UUID().uuidString).mp4")
                            : nil
                        let posterURL = recipe.output.wantsImage
                            ? temp.appendingPathComponent("LetsLapse-slice-\(UUID().uuidString).png")
                            : nil
                        let renderer = TimeSliceRenderer()
                        let variationCount = recipes.count
                        let reportSlice: @Sendable (Double) -> Void = { [weak self] fraction in
                            Task { @MainActor in
                                guard let self, let sliceBand else { return }
                                // One band shared by the whole batch, so the
                                // bar crosses it once however many passes run.
                                self.reportTailProgress(
                                    band: sliceBand,
                                    fraction: (Double(position) + fraction) / Double(variationCount))
                            }
                        }
                        // `.utility`, like every blend-run worker: a minutes-long
                        // render must not outrank touch handling for the P-cores
                        // (editor-performance-plan.md, the processing-flow pass).
                        let sliceTask = Task.detached(priority: .utility) {
                            // The provider's exact frame count reads every
                            // compressed sample — off the main actor with the
                            // render itself.
                            let provider = try await AssetFrameProvider(url: masterURL)
                            return try renderer.render(
                                provider: provider, settings: recipe,
                                animationURL: animationURL, posterURL: posterURL,
                                codec: sliceCodec,
                                posterMetadata: posterSourceURL.flatMap {
                                    ImageExporter.carryoverMetadata(from: $0)
                                },
                                progress: reportSlice)
                        }
                        let sliceResult = try await withTaskCancellationHandler {
                            try await sliceTask.value
                        } onCancel: {
                            renderer.cancel()
                        }
                        // The geometry the run actually laid down — a grid's
                        // row count and cell size are derived, so they are
                        // recorded rather than assumed (brief §5.1).
                        let geometryNote = sliceResult.grid.map { " · \($0.summary)" } ?? ""
                        if !isBatch, sliceSettings.includeRegularClip {
                            let regular = try self.storeBlend(
                                output, captureID: captureID, parameters: parameters)
                            primaryBlend = regular
                            primaryOutput = output
                        }
                        if let posterURL, sliceResult.wrotePoster {
                            var posterParameters = parameters
                            posterParameters.id = UUID()
                            posterParameters.createdAt = Date()
                            posterParameters.timeSlice = recipe
                            var posterOutput = output
                            posterOutput.kind = .image
                            posterOutput.url = posterURL
                            posterOutput.image = nil
                            posterOutput.outputFrames = nil
                            posterOutput.summary =
                                "\(recipe.posterDisplayName) · \(sliceResult.width)×\(sliceResult.height)"
                                + geometryNote
                            let posterBlend = try self.storeBlend(
                                posterOutput, captureID: captureID, parameters: posterParameters)
                            if !slicedPrimaryTaken {
                                primaryBlend = posterBlend
                                primaryOutput = posterOutput
                            }
                        }
                        if let animationURL {
                            var slicedParameters = parameters
                            slicedParameters.id = UUID()
                            slicedParameters.createdAt = Date()
                            slicedParameters.timeSlice = recipe
                            var slicedOutput = output
                            slicedOutput.url = animationURL
                            slicedOutput.outputFrames = sliceResult.outputFrames
                            slicedOutput.summary += " · \(recipe.displayName)" + geometryNote
                            let slicedBlend = try self.storeBlend(
                                slicedOutput, captureID: captureID, parameters: slicedParameters)
                            // The animation fronts the result screen when both
                            // outputs exist — it is the thing that was asked for.
                            if !slicedPrimaryTaken {
                                primaryBlend = slicedBlend
                                primaryOutput = slicedOutput
                            }
                        }
                        // The FIRST variation fronts the result screen; the
                        // rest are in the library beside it.
                        slicedPrimaryTaken = true
                        // Scratch: storeBlend copies, so this pass's temps go
                        // now rather than piling up across the batch.
                        for scratch in [animationURL, posterURL].compactMap({ $0 }) {
                            try? FileManager.default.removeItem(at: scratch)
                        }
                    }
                    if let sliceBand {
                        self.reportTailProgress(band: sliceBand, fraction: 1)
                    }
                    self.processingPhase = .saving
                    self.processingETADate = nil
                    // The master goes when the regular clip wasn't kept — but
                    // only ever our own temp file, and only once every
                    // variation has finished reading it.
                    if !sliceSettings.includeRegularClip,
                       masterURL.deletingLastPathComponent().standardizedFileURL
                        == FileManager.default.temporaryDirectory.standardizedFileURL {
                        try? FileManager.default.removeItem(at: masterURL)
                    }
                    guard let primaryBlend, let primaryOutput else {
                        throw LapseError.timeSliceInvalid(
                            "the run produced nothing to keep — no regular clip, animation or poster")
                    }
                    self.apply(primaryOutput, from: primaryBlend)
                } else {
                    self.processingPhase = .saving
                    self.processingETADate = nil
                    let blend = try self.storeBlend(output, captureID: captureID, parameters: parameters)
                    self.apply(output, from: blend)
                }
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
                let description = (error as? LapseError)?.errorDescription ?? error.localizedDescription
                // On the console as well as the banner: a headless bench run
                // has no banner to read, and the banner does not say which
                // stage threw.
                LLog("render failed: \(description) — \(error)"
                     + " · source \(self?.currentCaptureID?.uuidString.prefix(8) ?? "?")")
                self?.errorMessage = description
                self?.stage = .configure
            }
        }
    }

    /// The time-slice poster fast path — `docs/time-slicing-poster-fast-path.md`
    /// §3.5. Renders the poster (or a batch of posters) straight from the
    /// stills: the union of the recipes' ladders is walked once, each master
    /// frame it names rendered through the stacker's own window primitive —
    /// decoded, accumulated at depth, graded at the window's centre, levelled
    /// and overlaid in the per-output-frame hook — and its bands copied into
    /// every poster that wants it. No temp master, nothing to verify, nothing
    /// to clean up but the poster scratch files `storeBlend` copies. Ends the
    /// run itself: registers every poster, fronts the first, and flips the
    /// stage to done.
    private func renderPosterFastPath(
        urls: [URL],
        windows: [Int],
        linear: Bool,
        grade: PhotoGrade,
        baseline: TimeSliceSettings,
        variations: TimeSliceVariationPlan?,
        captureID: UUID,
        parameters: BlendProject,
        posterSourceURL: URL?
    ) async throws {
        let masterFrames = windows.count
        // The cost isn't known until the provider has sized the stack and the
        // batch has been generated against that size, both inside the render
        // task; a provisional plan over every still keeps the bar honest
        // until the real one replaces it.
        beginProgressPlan(.make(
            clipFrames: [urls.count], hasStitch: false, hasGrade: false, hasSlice: false))
        processingPhase = .posterFrames(frames: 0, of: masterFrames, posters: 1)
        statusMessage = "Preparing the poster..."
        // The project's text overlays and level, resolved up front — mask and
        // all — by the captureID this job STARTED with (same rule as the
        // sequence path: a selection change mid-render must not retarget it).
        let overlayBake = await makeOverlayExportBake(for: captures.first { $0.id == captureID })
        let renderer = TimeSliceRenderer()
        // iOS holds at most four poster buffers at once (~49 MB each at
        // 12 MP); the Mac takes the whole batch in one walk (§3.4).
        #if os(macOS)
        let chunkSize = Int.max
        #else
        let chunkSize = 4
        #endif

        struct Rendered: Sendable {
            let recipe: TimeSliceSettings
            let url: URL
            let result: TimeSliceRenderResult
            /// Distinct master frames this recipe's own ladder named.
            let framesRendered: Int
        }

        // Same lock as the clip's render, so a poster's frame stays the
        // clip's frame with the stabilisation on.
        let lock = applyStabilisation ? framingLock : nil
        let renderTask = Task.detached(priority: .utility) { [weak self] () throws -> [Rendered] in
            let core = try BlendCore()
            let decode: StillsWindowProvider.Decode
            if linear {
                // The engine path, exactly as the sequence render stages it:
                // reuse `blendSupport`, never rebuild its closures (§10).
                let support = try PhotoGrader.blendSupport(
                    grade: grade, lock: lock, sourcePositions: Self.sourcePositions(of: urls))
                decode = .linear(decode: support.decode, grade: support.hook)
            } else {
                let loader = PhotoGrader.stabilisedLoader(lock, base: Self.gradedFrameLoader(grade, over: urls))
                decode = .gamma(
                    load: { url in try loader?(url) ?? ImageStacker.loadImage(at: url) },
                    linearLight: false)
            }
            // Progress is reported in stills decoded, because decodes are
            // the cost; the denominator is replaced once the union is known.
            final class Expected: @unchecked Sendable {
                var decodes: Int
                init(_ decodes: Int) { self.decodes = decodes }
            }
            let expected = Expected(urls.count)
            let provider = try StillsWindowProvider(
                core: core, urls: urls, windows: windows, decode: decode,
                overlayComposite: overlayBake?.stackerHook(),
                onStillDecoded: { decoded in
                    let fraction = min(0.999, Double(decoded) / Double(max(1, expected.decodes)))
                    Task { @MainActor in
                        self?.reportClipProgress(0, fraction: fraction)
                    }
                },
                isCancelled: { renderer.isCancelled })
            let width = provider.width
            let height = provider.height

            // The batch, generated against inputs that are all known BEFORE
            // rendering — which the tail pass could not do (§3.5).
            var recipes = [baseline]
            if let variations, masterFrames > 1 {
                let generated = TimeSliceVariationGenerator.variations(
                    plan: variations, baseline: baseline, masterFrames: masterFrames,
                    width: width, height: height)
                if !generated.isEmpty { recipes = generated }
            }
            var chunks: [[TimeSliceSettings]] = []
            var cursor = 0
            while cursor < recipes.count {
                let end = min(recipes.count, cursor + chunkSize)
                chunks.append(Array(recipes[cursor..<end]))
                cursor = end
            }
            // The real cost: every chunk's union, in stills. Still 0 was
            // decoded for the size and is reused only by the first chunk's
            // window 0; later chunks decode it again (§3.4: no caching across
            // chunks by design).
            var totalDecodes = 1
            var unionFrames = 0
            for (index, chunk) in chunks.enumerated() {
                let union = try TimeSliceRenderer.posterFrameIndices(
                    recipes: chunk, masterFrames: masterFrames, width: width, height: height)
                unionFrames += union.count
                totalDecodes += union.reduce(0) { $0 + provider.sourceRange(of: $1).count }
                if index == 0, union.first == 0 { totalDecodes -= 1 }
            }
            expected.decodes = max(1, totalDecodes)
            let posterCount = recipes.count
            let frames = unionFrames
            Task { @MainActor in
                guard let self else { return }
                self.beginProgressPlan(.make(
                    clipFrames: [expected.decodes], hasStitch: false, hasGrade: false, hasSlice: false))
                self.processingPhase = .posterFrames(
                    frames: frames, of: masterFrames, posters: posterCount)
                self.statusMessage = posterCount > 1
                    ? "Rendering \(frames) of \(masterFrames) frames for \(posterCount) posters..."
                    : "Rendering \(frames) of \(masterFrames) frames for the poster..."
            }

            let temp = FileManager.default.temporaryDirectory
            let metadata = posterSourceURL.flatMap { ImageExporter.carryoverMetadata(from: $0) }
            var rendered: [Rendered] = []
            for chunk in chunks {
                let urls = chunk.map { _ in
                    temp.appendingPathComponent("LetsLapse-poster-\(UUID().uuidString).png")
                }
                let results = try renderer.renderPosters(
                    provider: provider, recipes: chunk, posterURLs: urls, posterMetadata: metadata)
                for (index, recipe) in chunk.enumerated() {
                    let own = try TimeSliceRenderer.posterFrameIndices(
                        recipes: [recipe], masterFrames: masterFrames, width: width, height: height)
                    rendered.append(Rendered(
                        recipe: recipe, url: urls[index], result: results[index],
                        framesRendered: own.count))
                }
            }
            return rendered
        }
        let rendered = try await withTaskCancellationHandler {
            try await renderTask.value
        } onCancel: {
            renderer.cancel()
        }

        processingPhase = .saving
        processingETADate = nil
        var primary: (ProcessingOutput, BlendProject)?
        for item in rendered {
            var posterParameters = parameters
            posterParameters.id = UUID()
            posterParameters.createdAt = Date()
            posterParameters.timeSlice = item.recipe
            let geometryNote = item.result.grid.map { " · \($0.summary)" } ?? ""
            // The poster renders its master frames at the source size and
            // returns before the crop's tail pass, so the Edit screen's crop
            // is not in it — said in the summary rather than dropped silently
            // (docs/TODO.md: cut the crop on each master frame after the
            // overlay bake).
            let cropNote = grade.hasCrop ? Self.cropSetAsidePosterSummary : ""
            let output = ProcessingOutput(
                kind: .image,
                url: item.url,
                image: nil,
                summary: "\(item.recipe.posterDisplayName) · \(item.result.width)×\(item.result.height)"
                    + " · \(item.framesRendered) of \(masterFrames) frames rendered" + geometryNote
                    + cropNote,
                inputFrames: urls.count,
                outputFrames: nil,
                width: item.result.width,
                height: item.result.height)
            let blend = try storeBlend(output, captureID: captureID, parameters: posterParameters)
            // The FIRST variation fronts the result screen; the rest are in
            // the library beside it.
            if primary == nil { primary = (output, blend) }
            // Scratch: storeBlend copied it.
            try? FileManager.default.removeItem(at: item.url)
        }
        guard let primary else {
            throw LapseError.timeSliceInvalid("the run produced no poster")
        }
        apply(primary.0, from: primary.1)
        progress = 1
        processingStartedAt = nil
        stage = .done
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
    func processPhotoBurst(urls: [URL], blendDepth: Int, linear: Bool, presentResult: Bool = true,
                           viewfinderShapes: ViewfinderShapes? = nil) async {
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
        // Auto shape mode: what the viewfinder had on screen becomes the
        // project's register now, and is refined against the file in the
        // background (see `recordViewfinderShapes`).
        if let viewfinderShapes {
            recordViewfinderShapes(viewfinderShapes, for: capture)
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
        timeSlice = nil
        timeSliceVariations = nil
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
        beginActivity(.blending)
        blendTask = Task { [weak self] in
            defer { self?.endActivity(.blending) }
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
        normalization: SegmentNormalization,
        outputFPS: Double
    ) async throws -> URL {
        if let reframe = normalization.reframe {
            // The slice of the frame map belonging to THIS segment. The warp
            // compiles one region per segment file, so the indices are already
            // local to the piece — which is what the cropper's
            // `compositionTime * fps` lookup wants.
            let frameTimes = segmentIndex < reframe.frameTimesBySegment.count
                ? reframe.frameTimesBySegment[segmentIndex] : []
            let frameRects = segmentIndex < reframe.rectsBySegment.count
                ? reframe.rectsBySegment[segmentIndex] : []
            guard !frameTimes.isEmpty, frameRects.count == frameTimes.count else {
                LLog("normalize: segment \(segmentIndex) has no compiled frame map"
                     + " — scaling without the punch")
                return try await scaledSegment(
                    url, normalization: normalization, outputFPS: outputFPS)
            }
            let reframed = try await ReframeVideoCropper.croppedCopy(
                of: url,
                track: reframe.track,
                aspect: reframe.aspect,
                sourceSize: reframe.sourceSize,
                frameSourceTimes: frameTimes,
                outputFPS: reframe.outputFPS,
                rotationDegrees: normalization.rotationDegrees,
                renderSizeOverride: normalization.renderSize,
                rectsOverride: frameRects)
            return reframed.url
        }
        return try await scaledSegment(
            url, normalization: normalization, outputFPS: outputFPS)
    }

    /// The no-punch path: canvas-crop and/or scale one segment to the common
    /// render size.
    private func scaledSegment(
        _ url: URL,
        normalization: SegmentNormalization,
        outputFPS: Double
    ) async throws -> URL {
        let cropped = try await VideoCanvasCropper.croppedCopy(
            of: url,
            canvas: normalization.canvas,
            offset: normalization.canvasOffset,
            rotationDegrees: normalization.rotationDegrees,
            crop: normalization.crop,
            outputFPS: outputFPS,
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
        willSlice: Bool = false,
        warpSchedules: [[Int]]? = nil,
        normalization: SegmentNormalization? = nil
    ) async throws -> ProcessingOutput {
        guard !source.segmentURLs.isEmpty else { throw LapseError.noInputFrames }

        guard source.sequence.mode == .ramp else {
            return try await blendMarkerSequence(
                source, ramp: ramp, fps: fps, linear: linear, burstRamp: burstRamp,
                willBakeGrade: willBakeGrade, willSlice: willSlice, warpSchedules: warpSchedules)
        }

        let segmentURLByName = source.resolvedByOriginalName
        let orderedSegments = source.sequence.segments.sorted { $0.index < $1.index }
        guard !orderedSegments.isEmpty else {
            let fallbackURL = source.segmentURLs[0]
            beginProgressPlan(.make(
                clipFrames: [1], hasStitch: false, hasGrade: willBakeGrade, hasSlice: willSlice))
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
            hasStitch: orderedSegments.count > 1, hasGrade: willBakeGrade, hasSlice: willSlice)
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
                    normalization: normalization,
                    outputFPS: fps)
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

        // A one-piece "stitch" has nothing to lay end to end. It used to run
        // anyway — and a single-segment ramp shoot is an ordinary shoot, not an
        // edge case — which put every such render through an export session that
        // silently retimed it (see `stitchVideos`). The piece IS the clip, so
        // hand it straight to the tail passes.
        //
        // The one single-piece case that still needs the stitch is a lone burst
        // carrying a `slowFactor`: that is a real retime, not a concatenation.
        let needsStitch = processedPieces.count > 1
            || processedPieces.contains { $0.slowFactor != nil }
        let stitchBand = plan.stitchBand ?? min(progress, 0.98)...0.98
        let output: URL
        let stitched: (width: Int, height: Int, duration: Double, rampDropped: Bool)
        if needsStitch {
            processingPhase = .combining(clips: processedPieces.count)
            tailPhaseStartedAt = Date()
            processingETADate = nil
            statusMessage = "Stitching \(processedPieces.count) processed segments..."
            output = FileManager.default.temporaryDirectory
                .appendingPathComponent("LetsLapse-sequence-\(UUID().uuidString).mp4")
            stitched = try await stitchVideos(
                processedPieces, to: output, outputFPS: fps, burstRamp: burstRamp
            ) { [weak self] fraction in
                Task { @MainActor in
                    self?.reportTailProgress(band: stitchBand, fraction: fraction)
                }
            }
        } else {
            output = processedPieces[0].url
            let measured = try await RenderVerifier.measure(output)
            stitched = (
                width: measured.displayWidth,
                height: measured.displayHeight,
                duration: measured.duration,
                rampDropped: false)
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
        willSlice: Bool = false,
        warpSchedules: [[Int]]? = nil
    ) async throws -> ProcessingOutput {
        guard let sourceURL = source.primaryVideoURL else { throw LapseError.noInputFrames }

        // A warp render needs no extraction and no stitch: marker mode is one
        // file, and the compiled schedule carries every stretch, seam and ease
        // through a single pass — blur follows the speed curve continuously.
        if let schedule = warpSchedules?.first, !schedule.isEmpty {
            beginProgressPlan(.make(
                clipFrames: [max(1, schedule.reduce(0, +))],
                hasStitch: false, hasGrade: willBakeGrade, hasSlice: willSlice))
            processingPhase = .blending(clip: 1, of: 1)
            statusMessage = "Blending the warped timeline..."
            return try await blendVideo(
                url: sourceURL, ramp: ramp, fps: fps, linear: linear,
                trimHeadTailSeconds: 0, customWindows: schedule)
        }

        let pieces = try await markerSequencePieces(for: source, sourceURL: sourceURL)
        guard !pieces.isEmpty else {
            beginProgressPlan(.make(
                clipFrames: [1], hasStitch: false, hasGrade: willBakeGrade, hasSlice: willSlice))
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
            hasStitch: true, hasGrade: willBakeGrade, hasSlice: willSlice)
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
            processedPieces, to: output, outputFPS: fps, burstRamp: burstRamp
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
        outputFPS: Double,
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
            let pieceTransform = try await track.load(.preferredTransform)
            if index == 0 {
                transform = pieceTransform
                outputSize = CGRect(origin: .zero, size: naturalSize)
                    .applying(transform)
                    .standardized
                    .size
            } else if pieceTransform != transform {
                // The defect this guard exists for, and the one it originally
                // missed: a track carries ONE transform, so a piece that bakes
                // its rotation while its neighbours keep theirs as metadata
                // gets piece 0's rotation applied on top and plays sideways.
                // Sizes can match while this is wrong, so it is checked
                // separately (project A7B4726A, 2026-08-15).
                LLog("stitch: piece \(index) has a different preferred transform from piece 0"
                     + " — it will be re-rotated by piece 0's and play wrong."
                     + " Pieces must be normalised to one orientation first")
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

        let hasRamp = burstRamp > 0 && !burstPlacements.isEmpty

        // The ramp-free stitch — every modern render, since a warp carries its
        // speeds inside the per-file schedules and never retimes here — is a
        // pure concatenation, so it goes through the shared reader→writer pump
        // and lands frame for frame.
        //
        // It used to go through `AVAssetExportSession(presetName:
        // .highestQuality)`. That preset is a device capability budget, not a
        // passthrough: at large frame sizes it silently caps BOTH resolution and
        // frame rate, and it drops frames to hit the rate rather than reblending
        // them. Measured on a 4032×3024 50 fps intermediate: 3840×2880 → 3548×2660
        // and 50 → 25 fps on an M4 Max, 50 → 12.5 fps on the phone that rendered
        // project B0E3269D — 450 of 600 blended frames binned, with the manifest
        // still reporting "600 frames out · 50 fps". At 1920×1080 the same preset
        // is transparent, which is why this went years without being seen.
        //
        // `composition: nil` reads the composition track's samples straight
        // through with their own timing, so the 600 frames stay 600 frames; the
        // writer carries the track's `preferredTransform`, so the policy is
        // sized in NATURAL pixels while the returned size stays display-oriented.
        if !hasRamp {
            let natural = firstNaturalSize == .zero ? (outputSize ?? .zero) : firstNaturalSize
            let policy = VideoEncodePolicy(
                profile: (blendProfileOverride ?? defaultBlendProfile) == .hevcMain10
                    ? .hevcMain10 : .h264High8Bit,
                width: max(2, Int(abs(natural.width).rounded()) & ~1),
                height: max(2, Int(abs(natural.height).rounded()) & ~1),
                fps: outputFPS)
            do {
                try await CompositionExporter.export(
                    asset: composition, composition: nil, to: outputURL,
                    fileType: .mp4, policy: policy, progress: progress)
            } catch is CancellationError {
                throw LapseError.cancelled
            } catch {
                throw LapseError.writerFailed(
                    writerFailureDescription(error, fallback: "export failed"))
            }
            let size = outputSize ?? .zero
            return (
                Int(abs(size.width).rounded()),
                Int(abs(size.height).rounded()),
                composition.duration.seconds,
                rampDropped: false
            )
        }

        // The burst-ramp path keeps the export session: the ramp is a
        // `scaleTimeRange` retime, and the reader→writer pump passes scaled
        // segments through at their original frame count rather than resampling
        // them to a constant rate (measured — a 1 s → 2 s scale yields the same
        // 104 frames stretched over 3 s). Changing that is a retiming question,
        // not a plumbing one, so it is left alone and the post-render check now
        // guards it. This path is legacy anyway: `slowFactor` is only ever set
        // when no warp schedule is driving the render.
        //
        // AVAssetExportPresetHighestQuality attempts to preserve the source
        // codec (HEVC on modern iPhones), but VideoToolbox's HEVC encoder does
        // not support scaleTimeRange — it returns kVTPropertyNotSupportedErr
        // (-16364) wrapped in AVErrorOperationNotSupportedForAsset (-11800).
        // A resolution-locked preset forces an H.264 encode path that handles
        // speed ramps without complaint.
        let stitchPreset: String
        if let size = outputSize {
            stitchPreset = max(size.width, size.height) > 1920
                ? AVAssetExportPreset3840x2160
                : AVAssetExportPreset1920x1080
        } else {
            stitchPreset = AVAssetExportPreset1920x1080
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
                                                  outputFPS: outputFPS,
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
        customWindows: [Int]? = nil,
        customWindowTimes: [Double]? = nil,
        profile: VideoEncodePolicy.Profile = .h264High8Bit,
        overlayBake: OverlayExportBake? = nil
    ) async throws -> ProcessingOutput {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-\(UUID().uuidString).mp4")
        // The framing lock rides into the detached render as a value: every
        // source frame is put back on the reference framing on its way into
        // the accumulator, on both decode paths.
        let lock = applyStabilisation ? framingLock : nil
        // `.utility`: the run takes minutes and its workers must sit below
        // touch handling — `.userInitiated` here is what let a blend starve
        // the Cancel button on 6-core phones.
        let result = try await Task.detached(priority: .utility) { [weak self] () throws -> StackSequenceResult in
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
                    customWindows: customWindows,
                    customWindowTimes: customWindowTimes,
                    loadFrame: PhotoGrader.stabilisedLoader(lock, base: Self.gradedFrameLoader(grade, over: urls)),
                    overlayComposite: overlayBake?.stackerHook(),
                    progress: progress)
            }
            // The engine path: linear half-float decode straight to the
            // accumulator, the grade applied once per OUTPUT frame after the
            // average — the order Lightroom would grade the blended still in.
            let support = try PhotoGrader.blendSupport(
                grade: grade, lock: lock, sourcePositions: Self.sourcePositions(of: urls))
            return try stacker.stackSequenceLinear(
                imageURLs: urls,
                ramp: ramp,
                outputFPS: fps,
                outputURL: output,
                frameTimes: frameTimes,
                customWindows: customWindows,
                customWindowTimes: customWindowTimes,
                profile: profile,
                decodeLinear: support.decode,
                outputGrade: support.hook,
                overlayComposite: overlayBake?.stackerHook(),
                progress: progress)
        }.value
        var summary = "\(urls.count) photos → \(result.outputFrames) frames · \(result.width)×\(result.height)"
        if profile == .hevcMain10 {
            summary += " · 10-bit HEVC"
        }
        if customWindows != nil ? customWindowTimes != nil : frameTimes != nil {
            summary += " · timed from capture"
        }
        if !grade.isColorIdentity {
            summary += " · \(grade.preset.displayName) grade baked in"
        }
        if grade.isKeyframed {
            let moments = grade.timeline.keyframes.count
            summary += " · \(moments) keyframe\(moments == 1 ? "" : "s")"
        }
        if let lock {
            summary += " · framing locked (\(String(format: "%.1f", lock.cropFraction * 100))% crop)"
        }
        if let overlayBake, overlayBake.hasOverlays {
            summary += overlayBake.masks.isEmpty
                ? " · text baked in"
                : " · text baked in (scene-placed)"
        }
        if let overlayBake {
            let graded = overlayBake.maskGrades.filter(\.isActive).count
            if graded > 0 {
                summary += " · \(graded) masked grade\(graded == 1 ? "" : "s") baked in"
            }
        }
        if grade.hasRotation {
            summary += Self.levelSummary(grade)
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

    /// The summary fragment for a baked crop: " · cropped to 16:9" for a
    /// locked aspect, " · cropped" for a free one. The pixels are already in
    /// the summary's size.
    nonisolated static func cropSummary(_ crop: FrameCrop) -> String {
        crop.aspect.ratio == nil ? " · cropped" : " · cropped to \(crop.aspect.label)"
    }

    /// The summary fragment for a crop a render could not honour — a
    /// punch-in reframe ran, whose keys were authored over the uncropped
    /// picture. Said out loud rather than dropped silently.
    nonisolated static let cropSetAsideSummary = " · crop not applied (punch-in reframe)"
    /// The poster fast path's twin: the master frames come out at the
    /// source size, before any tail pass.
    nonisolated static let cropSetAsidePosterSummary = " · crop not applied (poster fast path)"

    /// The status line for the canvas / crop tail pass, whichever of the
    /// three it is doing.
    nonisolated static func cropStatusMessage(
        canvas: CanvasRatio?, crop: FrameCrop?, grade: String?
    ) -> String {
        var line: String
        switch (canvas, crop) {
        case (.some(let canvas), .some):
            line = "Cropping and fitting to \(canvas.rawValue)"
        case (.some(let canvas), .none):
            line = "Cropping to \(canvas.rawValue)"
        case (.none, _):
            line = "Cropping the clip"
        }
        if let grade { line += " and baking the \(grade) grade" }
        return line + "..."
    }

    /// The summary fragment for a baked level, e.g. " · levelled +2.5°", or
    /// " · levelled +2.5° → −1.0°" when the level travels across the clip.
    nonisolated static func levelSummary(_ grade: PhotoGrade) -> String {
        guard grade.hasKeyframedRotation else {
            return " · levelled \(RotationSlider.readout(grade.rotationDegrees))"
        }
        return " · levelled \(RotationSlider.readout(grade.rotationDegrees(at: 0)))"
            + " → \(RotationSlider.readout(grade.rotationDegrees(at: 1)))"
    }

    /// Where each source frame sits in the shoot, 0…1 — the axis keyframes are
    /// on. Keyed by URL rather than by a running counter because the decode
    /// closures are called once per frame with no promise about the order.
    nonisolated static func sourcePositions(of urls: [URL]) -> [URL: Double] {
        guard urls.count > 1 else { return urls.first.map { [$0: 0] } ?? [:] }
        var positions: [URL: Double] = [:]
        for (index, url) in urls.enumerated() {
            positions[url] = Double(index) / Double(urls.count - 1)
        }
        return positions
    }

    /// A loader that grades every frame on its way into a blend, or nil for an
    /// untouched grade so the stacker keeps its own decode path.
    ///
    /// Built inside the detached blend task from the grade value alone, so no
    /// closure crosses the concurrency boundary with it.
    nonisolated private static func gradedFrameLoader(
        _ grade: PhotoGrade, over urls: [URL]
    ) -> ((URL) throws -> CGImage)? {
        guard !grade.isIdentity else { return nil }
        // A smoothed white balance declares a different white on every frame,
        // so it needs the per-frame path for the same reason keyframes do.
        guard grade.isKeyframed || grade.whiteBalance.variesOverTime, urls.count > 1 else {
            return { url in try PhotoGrader.renderForBlend(url: url, grade: grade) }
        }
        // This path grades each INPUT frame on its way in (the gamma-domain
        // legacy stacker has no post-average hook), so the moment is the
        // frame's own position in the sequence. Keyed by URL rather than by a
        // running counter: the loader is called once per frame, but nothing in
        // its contract promises the order.
        let positions = sourcePositions(of: urls)
        return { url in
            try PhotoGrader.renderForBlend(
                url: url, grade: grade.frozen(at: positions[url] ?? 0))
        }
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
        grade: PhotoGrade = .identity,
        overlayBake: OverlayExportBake? = nil
    ) async throws -> ProcessingOutput {
        // Overlays render at their resolved final state in a stack — the
        // whole shoot folds into one moment, so every reveal is complete.
        // A @Sendable closure rather than a nested func: it runs inside the
        // detached stack task, off this model's actor.
        //
        // The crop is cut LAST, from the finished still: after the level and
        // after the overlays and masks, which are stored in the full levelled
        // frame and so keep their coordinates. A still has no pool size to
        // respect, which is why this path needs no tail pass. The opening
        // moment's crop, like every other export path: the editor carries
        // one crop onto every moment (`GradeTimeline.carryCrop`), so the
        // opening one IS the crop, and reading it here keeps the stack and
        // the sequence blend of one project cutting the same frame.
        let crop = grade.crop.flatMap { $0.isFull ? nil : $0 }
        let baked: @Sendable (CGImage) -> CGImage = { image in
            var out = image
            if let overlayBake {
                out = SceneAwareCompositor.bakeStill(
                    out, overlays: overlayBake.overlays(at: 1),
                    maskGrades: overlayBake.maskGrades,
                    masks: overlayBake.masks, settings: overlayBake.settings,
                    rotationDegrees: overlayBake.rotation(at: 1)) ?? out
            }
            if let crop { out = FrameCrop.apply(crop, to: out) }
            return out
        }
        // A single frame has nothing to accumulate — the stacker needs at least
        // two — so load it straight through (blend=1 / one-frame-burst edge).
        if urls.count == 1, let only = urls.first {
            let single = grade.isIdentity
                ? loadImage(at: only)
                : try? PhotoGrader.renderForBlend(url: only, grade: grade)
            guard let image = single.map(baked) else { throw LapseError.noInputFrames }
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
                summary: "1 photo · \(image.width)×\(image.height)" + (crop.map(Self.cropSummary) ?? ""),
                inputFrames: 1,
                outputFrames: 1,
                width: image.width,
                height: image.height
            )
        }
        let lock = applyStabilisation ? framingLock : nil
        // `.utility`, like the sequence path above — same reasoning.
        let image = try await Task.detached(priority: .utility) { [weak self] () throws -> CGImage in
            let core = try BlendCore()
            let stacker = ImageStacker(core: core)
            let stacked = try stacker.stack(
                imageURLs: urls,
                linearLight: linear,
                loadFrame: PhotoGrader.stabilisedLoader(lock, base: Self.gradedFrameLoader(grade, over: urls)),
                progress: { fraction in
                    Task { @MainActor in
                        self?.reportClipProgress(0, fraction: fraction)
                    }
                })
            return baked(stacked)
        }.value
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-\(Int(Date().timeIntervalSince1970)).png")
        // The stack spans every frame; the first frame's EXIF (capture time =
        // start of the synthetic exposure) and GPS stand for the whole.
        try ImageExporter.write(
            image, to: output, format: .png,
            metadata: urls.first.flatMap { ImageExporter.carryoverMetadata(from: $0) })
        var summary = "\(urls.count) photos stacked · \(image.width)×\(image.height)"
        if !grade.isColorIdentity {
            summary += " · \(grade.preset.displayName) grade baked in"
        }
        if lock != nil {
            summary += " · framing locked"
        }
        if grade.hasRotation {
            summary += Self.levelSummary(grade)
        }
        if let crop {
            summary += Self.cropSummary(crop)
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
            // The timeline travels with the blend on both source kinds, so a
            // re-edit starts from exactly what rendered. The single-image
            // stack schedules nothing and records nothing.
            warp: compiledWarp() != nil || compiledIntervalWarp() != nil ? activeWarp() : nil,
            // Gated like `warp`: the reframe only renders through the compiled
            // path, so a ramp render must not record a punch it never baked.
            reframe: compiledWarp() != nil ? reframe : nil,
            canvasRatio: source?.isVideo == true ? effectiveBlendCanvas().rawValue : nil,
            canvasOffset: source?.isVideo == true ? blendCanvasOffset : nil,
            // Recorded only on the sliced outputs themselves — the slicing
            // tail sets it on their copies of these parameters, so the regular
            // clip a sliced run keeps never re-slices on re-render.
            timeSlice: nil
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
        // A new blended clip is the most common edit there is.
        markEdited(blend.captureID)
        blends.sort { $0.createdAt > $1.createdAt }
        try persistLibrary()
        // The render's hash line. Frames only (no metadata read): a blend
        // output carries no IPTC, and the frames were recorded at registration.
        if let capture = captures.first(where: { $0.id == captureID }) {
            recordAssets(for: capture, extractMetadata: false)
        }
        return blend
    }

    private func registerCapture(
        from source: Source, mode: String, captureMode: CaptureProjectMode? = nil
    ) throws -> CaptureProject {
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
                sourceFPS: nil,
                captureMode: captureMode?.rawValue
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
                if captureMode == .scanner {
                    copyScannerSiblings(of: url, frameNumber: index + 1, into: sourceFolder)
                }
            }
            // A ramped shoot (Holy Grail) records when each frame was actually
            // taken; that sidecar travels with the frames, because it is what
            // lays the finished clip out on the real capture clock instead of
            // assuming even spacing. Deliberately NOT in `sourceFileNames` —
            // that list is the project's frames, and this isn't one.
            //
            // The exposure record travels the same way and for the same
            // reason: `capture_log.json` and `frames.exposure` say what each
            // frame was shot at, which is the one thing a finished DNG
            // sequence can't be re-measured for afterwards. They keep their own
            // names — a sidecar renamed `frame-000NN.json` is a sidecar nobody
            // can find.
            if let staging = urls.first?.deletingLastPathComponent() {
                var sidecarNames = [
                    FrameTimestamps.fileName,
                    CaptureExposureLog.sessionFileName,
                    CaptureExposureLog.sidecarFileName,
                ]
                // The blend engine's experiment log, when the capture screen
                // parked it beside the frames — by its own `liveblend-…json`
                // name. It used to arrive in `urls` and leave as
                // `frame-00501.json`, exactly the renamed sidecar the comment
                // above warns about.
                if let names = try? FileManager.default.contentsOfDirectory(atPath: staging.path) {
                    sidecarNames += names.filter {
                        $0.hasPrefix("liveblend-") && $0.hasSuffix(".json")
                    }.sorted()
                }
                for name in sidecarNames {
                    let sidecar = staging.appendingPathComponent(name)
                    guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
                    try? copyReplacingItem(
                        at: sidecar,
                        to: root.appendingPathComponent("source/\(name)"))
                }
                // The per-asset record file is a ROOT sidecar; a staging
                // folder that already carries one (nothing writes it during
                // a shoot today) keeps it beside the project, not the frames.
                let records = staging.appendingPathComponent(ProjectFileRegistry.assetRecordsName)
                if FileManager.default.fileExists(atPath: records.path) {
                    try? copyReplacingItem(at: records, to: root.appendingPathComponent(ProjectFileRegistry.assetRecordsName))
                }
            }
            capture = CaptureProject(
                id: id,
                kind: .photos,
                createdAt: Date(),
                originalName: "\(relativeNames.count) photos",
                mode: mode,
                sourceFileNames: relativeNames,
                sourceFPS: nil,
                captureMode: captureMode?.rawValue,
                // Read here rather than plumbed through `setSource`: this is
                // the same defaults key the capture screen's PAPER row writes,
                // so the stamp is what the operator had chosen at the moment
                // the shoot ended, with no new argument on a shared path.
                scannerPaper: captureMode == .scanner ? Self.storedScannerPaper.rawValue : nil
            )
        }

        captures.insert(capture, at: 0)
        try persistLibrary()
        // The project owns the material now — and only now, with the manifest
        // written. Everything downstream re-resolves through `source(for:)`, so
        // the staging copy is dead weight from this line on.
        switch source {
        case .video(let url):
            Self.discardStagingFolder(containing: url)
        case .photos(let urls):
            if let first = urls.first { Self.discardStagingFolder(containing: first) }
        case .liveSequence:
            break  // returned above, through registerSequenceCapture.
        }
        Task { [weak self] in
            switch capture.kind {
            case .video: await self?.refreshVideoMetadata(for: capture.id)
            case .photos: await self?.refreshStillsMetadata(for: capture.id)
            }
        }
        recordAssets(for: capture)
        autoTagIfEnabled(capture)
        return capture
    }

    /// Brings a Scanner pose's *other* files into the project beside the frame
    /// itself: the processed sibling (`frame-00001.heic`) a RAW pose is shot
    /// with, and the rectified `frame-00001-corrected.heic` if one has been
    /// written.
    ///
    /// Deliberately **not** added to `sourceFileNames`. That list is the
    /// project's frames, and one pose is one frame however many files describe
    /// it — put the siblings in it and every count in the app (the frame
    /// browser, the stack estimate, "36 source frames") doubles or triples.
    /// They are found by name instead, exactly as `PerspectiveCorrector` finds
    /// them, which is why the numbering is re-derived from the frame's new
    /// index rather than copied from the staging name.
    ///
    /// Without this the siblings are simply lost: only `photoURLs` — the DNGs —
    /// is handed to registration, and the staging directory is temporary. The
    /// human-viewable half of a whole Scanner set would have gone with it.
    private func copyScannerSiblings(of frame: URL, frameNumber: Int, into sourceFolder: URL) {
        let staging = frame.deletingLastPathComponent()
        let stagedBase = frame.deletingPathExtension().lastPathComponent
        let base = String(format: "frame-%05d", frameNumber)
        for ext in ["heic", "jpg", "jpeg"] {
            let processed = staging.appendingPathComponent("\(stagedBase).\(ext)")
            // On the no-RAW fallback the pose's only file IS the processed
            // still, and it has already been copied as the frame — copying it
            // over itself would be a delete-then-copy of the same path.
            guard processed != frame,
                  FileManager.default.fileExists(atPath: processed.path) else { continue }
            try? copyReplacingItem(
                at: processed, to: sourceFolder.appendingPathComponent("\(base).\(ext)"))
            let corrected = PerspectiveCorrector.correctedURL(for: processed)
            if FileManager.default.fileExists(atPath: corrected.path) {
                try? copyReplacingItem(
                    at: corrected,
                    to: sourceFolder.appendingPathComponent(
                        "\(base)\(PerspectiveCorrector.correctedSuffix).heic"))
            }
            break
        }
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
        // Same as `registerCapture`: the segments and their `sequence.json` are
        // in the project folder and the manifest is on disk, so the staging run
        // in `tmp/` is now a duplicate of a multi-gigabyte shoot.
        if let first = result.segmentURLs.first {
            Self.discardStagingFolder(containing: first)
        } else {
            Self.discardStagingFolder(containing: result.metadataURL)
        }
        Task { [weak self] in
            await self?.refreshVideoMetadata(for: capture.id)
        }
        recordAssets(for: capture)
        autoTagIfEnabled(capture)
        return capture
    }


    // MARK: - Importing a shoot taken outside the app

    /// An import of outside footage in flight — nil the rest of the time.
    /// Drives the Create screen's progress card.
    ///
    /// Its own state rather than a reuse of `archiveImport`: that one owns a
    /// modal sheet, a duplicate question and a cancel path for a `.lapse`
    /// file, none of which a folder of frames or a movie has. What they do
    /// share is the *library* activity bracket, so a transfer or a render can
    /// see that this device is busy writing gigabytes.
    struct MediaImportProgress: Equatable {
        enum Phase: Equatable {
            /// Walking the selection and reading every file's metadata.
            case reading
            /// Copying frames into the project folder.
            case copying
            /// Sidecars and the manifest.
            case finishing
        }

        var phase: Phase = .reading
        /// Frame counts for a still sequence; both zero for a movie, which is
        /// one file and names itself instead.
        var frames = 0
        var totalFrames = 0
        /// The movie's file name, when that is what is being imported.
        var name: String?
        var bytes: Int64 = 0
        var totalBytes: Int64 = 0

        /// 0…1 by BYTES, not by frame count — raw frames are large and evenly
        /// sized, but a mixed set (raws beside JPEGs) advances in very uneven
        /// steps, and a bar that stalls is worse than one that is slightly
        /// nonlinear. Falls back to the frame count when nothing sized.
        var fraction: Double {
            if totalBytes > 0 { return min(1, Double(bytes) / Double(totalBytes)) }
            guard totalFrames > 0 else { return 0 }
            return min(1, Double(frames) / Double(totalFrames))
        }

        var caption: String {
            switch phase {
            case .reading:
                if let name { return "Reading \(name)…" }
                if totalFrames == 1 { return "Reading 1 frame…" }
                return "Reading \(totalFrames > 0 ? "\(totalFrames) " : "")frames…"
            case .copying:
                if let name { return "Copying \(name)…" }
                return "Copying frame \(frames) of \(totalFrames)…"
            case .finishing:
                return "Finishing up…"
            }
        }
    }

    @Published var mediaImport: MediaImportProgress?

    /// The `mode` line a still sequence imported from outside the app
    /// registers with.
    ///
    /// It names the MODE dial the shoot would have been taken on here, exactly
    /// as `CaptureView.intervalSourceModeName` does for the shoots that were:
    /// an imported interval set IS an interval project, and every screen that
    /// routes on this string should treat it as one. The suffix is what the
    /// app can't claim — that it watched the shutter.
    static let importedStillsMode = "Interval · Imported"

    /// The `mode` line a SINGLE imported photo registers with — the same
    /// naming for the same reason, and the string `isPhotoCapture` reads to
    /// treat it as one asset everywhere. An import is not required to be a
    /// sequence: one photo is a photo, and this is what it registers as.
    static let importedPhotoMode = "Photo · Imported"

    /// The `mode` line an imported video registers with. Long-standing value,
    /// named here so the two import paths are readable side by side.
    static let importedVideoMode = "Import"

    /// Brings stills shot on another camera in: a set of them as an interval
    /// project, a single one as a photo project.
    ///
    /// `selection` is what the picker handed back: files, folders, or both.
    /// **Whatever it resolves to IS the shoot** — the frames are not
    /// re-ordered by their timestamps, not de-duplicated by content, and not
    /// filtered for outliers. A set with a lens cap frame or a test shot in it
    /// is a set with a lens cap frame in it, and Bad Frames is where that gets
    /// dealt with, by the person who can see the picture.
    func importStills(from selection: [URL]) {
        guard mediaImport == nil else { return }
        Task { await runStillsImport(selection) }
    }

    private func runStillsImport(_ selection: [URL]) async {
        // Held for the whole job. On a sandboxed build the picker's URLs are
        // the only ones with access, and a folder's scope is what covers the
        // files inside it — so the scope has to outlive the walk, not be
        // taken and dropped per file.
        let scoped = selection.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        beginActivity(.importingArchive)
        mediaImport = MediaImportProgress()
        defer {
            mediaImport = nil
            endActivity(.importingArchive)
        }

        let urls = Self.expandStillSelection(selection)
        // One photo is a photo. There used to be a two-frame minimum here,
        // which rejected the single frame somebody had deliberately picked —
        // the only real failure is a selection with no images in it at all.
        guard !urls.isEmpty else {
            errorMessage = "No photos there. Choose image files, or a folder holding them."
            return
        }
        mediaImport?.totalFrames = urls.count

        // Header reads only — milliseconds per file, but 300 of them, and the
        // main actor is drawing the progress card.
        let sequence = await Task.detached(priority: .userInitiated) {
            ImportedStills.probe(urls: urls)
        }.value

        let totalBytes = sequence.frames.reduce(Int64(0)) { $0 + Int64($1.byteCount ?? 0) }
        mediaImport?.phase = .copying
        mediaImport?.totalBytes = totalBytes

        let id = UUID()
        let root = captureFolderURL(for: id)
        do {
            try Self.checkStorageHeadroom(for: totalBytes, at: projectsRootURL)
            let relativeNames = try await copyImportedStills(sequence, to: root) { frames, bytes in
                self.mediaImport?.frames = frames
                self.mediaImport?.bytes = bytes
            }
            mediaImport?.phase = .finishing
            let capture = try registerImportedStills(
                sequence, id: id, relativeNames: relativeNames, selection: selection)
            // A sequence goes straight into the blend flow — turning a shoot
            // into a clip is what importing one is for. A single photo has no
            // sequence to blend ("1 photos → one still" is not an offer), so it
            // lands on its own project screen, where a Photo-mode capture does.
            if capture.isPhotoCapture {
                show(capture)
            } else {
                openCapture(capture)
            }
        } catch {
            // A half-copied project folder is not a project. Nothing has been
            // written to the manifest yet, so removing the tree leaves the
            // library exactly as it was.
            try? FileManager.default.removeItem(at: root)
            errorMessage = "Couldn't import those photos: \(error.localizedDescription)"
        }
    }

    /// Resolves a picker selection into the frames it means, in the order the
    /// person who made it saw.
    ///
    /// Folders contribute the stills directly inside them, name-sorted.
    /// Loose files contribute themselves. The whole list is then sorted by
    /// folder and then by name, in the Finder's own natural order (`img9`
    /// before `img10`), because that is the only ordering the operator can see
    /// and control — an open panel's own result order is not shown to anyone.
    ///
    /// Duplicates are dropped by resolved path: a folder and a file inside it,
    /// both selected, are one frame rather than two.
    nonisolated static func expandStillSelection(_ selection: [URL]) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        for url in selection {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            else { continue }
            let candidates = isDirectory.boolValue
                ? ImportedStills.stills(in: url)
                : (ImportedStills.isStill(url) ? [url] : [])
            for candidate in candidates {
                let key = candidate.standardizedFileURL.resolvingSymlinksInPath().path
                if seen.insert(key).inserted { found.append(candidate) }
            }
        }
        return found.sorted { lhs, rhs in
            let leftFolder = lhs.deletingLastPathComponent().path
            let rightFolder = rhs.deletingLastPathComponent().path
            if leftFolder != rightFolder {
                return leftFolder.localizedStandardCompare(rightFolder) == .orderedAscending
            }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
                == .orderedAscending
        }
    }

    /// Copies every frame into `root/source/`, **keeping its own name**.
    ///
    /// The capture path renames its output to `frame-00001…N` because it is
    /// the thing that produced the files and the numbering is a fact about the
    /// shoot. An import has no such standing: the names came off a camera, the
    /// operator recognises them, they match the RAWs still on the card and the
    /// sidecars in whatever else has touched them. Renaming would be the app
    /// asserting authorship of files it merely copied.
    ///
    /// Nothing downstream needs the pattern — frame ORDER is
    /// `sourceFileNames`' order and frame IDENTITY is the last path component,
    /// which is exactly what Bad Frames nominates against. (The `frame-%05d`
    /// readers that do exist are Scanner's, and Scanner sets are made here.)
    ///
    /// A name collision — the same file name from two different folders — is
    /// resolved by suffixing rather than by overwriting, so a set assembled
    /// from two cards keeps all of its frames.
    private func copyImportedStills(
        _ sequence: ImportedStills.Sequence,
        to root: URL,
        progress: @escaping @MainActor (Int, Int64) -> Void
    ) async throws -> [String] {
        let sourceFolder = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)

        let frames = sequence.frames
        return try await Task.detached(priority: .userInitiated) {
            var relativeNames: [String] = []
            var used = Set<String>()
            var copiedBytes: Int64 = 0
            for (index, frame) in frames.enumerated() {
                try Task.checkCancellation()
                let name = Self.uniqueImportName(for: frame.url, taken: &used)
                let destination = sourceFolder.appendingPathComponent(name)
                try FileManager.default.copyItem(at: frame.url, to: destination)
                // A raw that has been through Lightroom keeps its edits in an
                // `.xmp` beside it. It travels with the frame — under the
                // frame's IMPORTED name, since a collision may have renamed
                // it — so the editor can offer the import later. Best effort:
                // a sidecar that will not copy must not fail the import of
                // the picture it describes.
                if let sidecar = LightroomSidecar.sidecarURL(forRawFile: frame.url) {
                    try? FileManager.default.copyItem(
                        at: sidecar,
                        to: destination.deletingPathExtension().appendingPathExtension("xmp"))
                }
                relativeNames.append("source/\(name)")
                copiedBytes += Int64(frame.byteCount ?? 0)
                let done = index + 1
                let bytes = copiedBytes
                await MainActor.run { progress(done, bytes) }
            }
            return relativeNames
        }.value
    }

    /// `_WEX3517.ARW`, or `_WEX3517-2.ARW` when that name is already spoken
    /// for. Case-insensitive, because the destination may be.
    nonisolated static func uniqueImportName(for url: URL, taken: inout Set<String>) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        func compose(_ stem: String) -> String { ext.isEmpty ? stem : "\(stem).\(ext)" }
        var candidate = compose(base)
        var suffix = 2
        while !taken.insert(candidate.lowercased()).inserted {
            candidate = compose("\(base)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    /// Writes the derived sidecars, adds the project to the library and
    /// returns it.
    ///
    /// The sidecars are the point of the whole path. A capture writes
    /// `frames.timestamps`, `frames.exposure` and `capture_log.json` as it
    /// shoots; an import rebuilds them from what the camera wrote into the
    /// frames themselves, so the warp axis lays this shoot out on its real
    /// clock and the exposure trail has something to show. They keep the
    /// capture path's file names, and are deliberately absent from
    /// `sourceFileNames` — that list is the project's frames, and a sidecar
    /// isn't one.
    private func registerImportedStills(
        _ sequence: ImportedStills.Sequence,
        id: UUID,
        relativeNames: [String],
        selection: [URL]
    ) throws -> CaptureProject {
        let root = captureFolderURL(for: id)
        let sourceFolder = root.appendingPathComponent("source", isDirectory: true)

        // A set with no usable clock writes no timestamps sidecar at all,
        // rather than one full of guesses: its absence is already the signal
        // every reader downstream acts on (fall back to even spacing).
        if let timestamps = sequence.frameTimestamps(),
           let writer = FrameTimestampWriter(directory: sourceFolder) {
            for entry in timestamps.entries { writer.append(entry) }
            writer.close()
        }
        if let writer = CaptureExposureWriter(directory: sourceFolder) {
            for entry in sequence.exposureEntries() { writer.append(entry) }
            writer.close()
        }
        CaptureExposureLog.write(
            sequence.captureSession(sessionID: id.uuidString), toDirectory: sourceFolder)

        let capture = CaptureProject(
            id: id,
            kind: .photos,
            // The shoot's own date, not the import's. A timelapse taken last
            // August belongs beside last August's work in the library, and
            // every "when was this" the app shows reads this field.
            createdAt: sequence.startedAt ?? Date(),
            originalName: Self.importedStillsName(selection: selection, sequence: sequence),
            // One frame is a photo project (`isPhotoCapture`), so the whole app
            // presents it as the single asset it is; two or more are the
            // interval shoot they were taken as.
            mode: sequence.count == 1 ? Self.importedPhotoMode : Self.importedStillsMode,
            sourceFileNames: relativeNames,
            sourceFPS: nil,
            // Stamped here from the probe rather than left to the background
            // refresh, so the card is right the first time it draws. The
            // refresh runs anyway and agrees.
            sourceDurationSeconds: sequence.elapsedSeconds,
            sourceWidth: sequence.pixelSize?.width,
            sourceHeight: sequence.pixelSize?.height)

        captures.insert(capture, at: 0)
        captures.sort { $0.createdAt > $1.createdAt }
        try persistLibrary()
        Task { [weak self] in
            await self?.refreshStillsMetadata(for: capture.id)
        }
        // The frames' own record: bytes, hash, and what each file said about
        // itself (title, rating, keywords, the photographer, the camera). User-
        // initiated priority, because the panel opens on this project next.
        recordAssets(for: capture, priority: .userInitiated)
        autoTagIfEnabled(capture)
        return capture
    }

    /// What the project calls itself: its own file name when it is one photo,
    /// otherwise the folder the frames came out of when they all came out of
    /// one, otherwise the camera that took them, otherwise the frame count.
    ///
    /// The folder wins because it is the name the operator gave this shoot —
    /// "Charles_ARW" is a title; "306 photos" is a measurement. A single photo
    /// is not a shoot, though: it is that file, and the enclosing folder would
    /// be "Downloads", or the staging folder a library pick was written to.
    nonisolated static func importedStillsName(
        selection: [URL], sequence: ImportedStills.Sequence
    ) -> String {
        if sequence.count == 1, let only = sequence.frames.first {
            return only.url.lastPathComponent
        }
        let folders = Set(sequence.frames.map { $0.url.deletingLastPathComponent().path })
        if folders.count == 1,
           let folder = sequence.frames.first?.url.deletingLastPathComponent()
               .lastPathComponent.trimmingCharacters(in: .whitespaces),
           !folder.isEmpty, folder != "/" {
            return folder
        }
        if let camera = sequence.cameraName { return camera }
        return "\(sequence.count) photos"
    }


    // MARK: - Duplicating a project as a DNG archive

    /// The projects the DNG archive can take: anything made of raw stills —
    /// an interval shoot (captured or imported), or a single raw photo
    /// (imported, or captured in Photo mode with Blend Off). A video has no
    /// frames at all.
    ///
    /// The one photo project held back is a BLENDED Photo capture: its frames
    /// are the burst behind its one picture, so archiving them would clone the
    /// stacking material rather than the photo anybody can see.
    func canArchiveAsDNG(_ capture: CaptureProject) -> Bool {
        guard capture.kind == .photos else { return false }
        let frames = sourceFrameURLs(for: capture)
        guard !frames.isEmpty, frames.allSatisfy({ ImportedStills.isRaw($0) }) else { return false }
        if capture.isPhotoCapture, frames.count > 1 { return false }
        return true
    }

    /// Creates a new project beside `capture` whose frames are DNG archives of
    /// the original's — each converted through `DNGArchive.Converter` with
    /// `strategy` (docs/dng-archive-spike/) — and carries everything else
    /// across: the manifest (grade, timeline, tags, mode), the source sidecars
    /// (timestamps, exposure, capture log), notes, masks, fonts and overlays.
    /// Blends are not copied; they are renders of the original's frames. The
    /// original is only read. `progress` arrives on the main actor after every
    /// frame; a `shouldContinue` that turns false stops the run, removes the
    /// half-made folder and throws `CancellationError`.
    func duplicateAsDNGArchive(
        _ capture: CaptureProject,
        strategy: DNGArchive.Strategy,
        nameSuffix: String,
        limit: Int? = nil,
        inFlight: Int = 2,
        shouldContinue: @escaping @Sendable () -> Bool = { true },
        progress: @escaping @MainActor (DNGArchive.Converter.SequenceProgress) -> Void = { _ in }
    ) async throws -> CaptureProject {
        guard canArchiveAsDNG(capture) else {
            throw DNGArchive.ConversionError.unsupported("only an interval shoot of raw frames can be archived as DNG")
        }
        var inputs = sourceFrameURLs(for: capture)
        if let limit, limit > 0, limit < inputs.count { inputs = Array(inputs.prefix(limit)) }
        let originalSource = captureFolderURL(for: capture.id).appendingPathComponent("source", isDirectory: true)
        let originalRoot = captureFolderURL(for: capture.id)

        beginActivity(.importingArchive)
        defer { endActivity(.importingArchive) }

        // The clone is assembled in a hidden staging folder and moved into
        // place only once it is complete and registered, so a run the app
        // does not survive leaves no half-project behind. Stale staging
        // folders from earlier interrupted runs are swept first.
        let id = UUID()
        let finalRoot = captureFolderURL(for: id)
        let root = projectsRootURL.appendingPathComponent(".dng-archive-\(id.uuidString)", isDirectory: true)
        Self.sweepStaleArchiveStaging(in: projectsRootURL)
        let sourceFolder = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        do {
            // A quarter of the originals is generous for a lossy archive and
            // right for the lossless mosaic; the check is about not filling
            // the disk, not about precision.
            let inputBytes = inputs.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            try Self.checkStorageHeadroom(for: max(inputBytes / 4, 50_000_000), at: projectsRootURL)

            let converter = DNGArchive.Converter()
            let files = inputs
            let result = await Task.detached(priority: .userInitiated) {
                converter.convert(files: files, to: sourceFolder, strategy: strategy, inFlight: max(1, inFlight),
                                  shouldContinue: shouldContinue) { snapshot in
                    Task { @MainActor in progress(snapshot) }
                }
            }.value
            guard shouldContinue() else { throw CancellationError() }
            guard result.failures.isEmpty else {
                let (url, why) = result.failures[0]
                throw DNGArchive.ConversionError.encode("\(url.lastPathComponent): \(why)")
            }
            guard result.reports.count == files.count else {
                throw DNGArchive.ConversionError.encode("\(files.count - result.reports.count) frames did not convert")
            }

            // Sidecars and the rest of the project, but not the frames and not
            // the blends. framing.json names frames; it only travels when the
            // names survive (our own DNGs do, an ARW becomes .dng).
            let frameNames = Set(inputs.map(\.lastPathComponent))
            let namesSurvive = inputs.allSatisfy { $0.pathExtension.lowercased() == "dng" }
            for item in (try? FileManager.default.contentsOfDirectory(at: originalSource, includingPropertiesForKeys: nil)) ?? [] {
                guard !frameNames.contains(item.lastPathComponent), !ImportedStills.isStill(item) else { continue }
                if item.lastPathComponent == FramingReview.fileName, !namesSurvive { continue }
                try? FileManager.default.copyItem(at: item, to: sourceFolder.appendingPathComponent(item.lastPathComponent))
            }
            for folder in ProjectArchive.transferableSubfolders where folder != "source" && folder != "blends" {
                let from = originalRoot.appendingPathComponent(folder, isDirectory: true)
                guard FileManager.default.fileExists(atPath: from.path) else { continue }
                try? FileManager.default.copyItem(at: from, to: root.appendingPathComponent(folder, isDirectory: true))
            }
            for file in ProjectArchive.transferableFiles where file != ProjectFileRegistry.assetRecordsName {
                let from = originalRoot.appendingPathComponent(file)
                guard FileManager.default.fileExists(atPath: from.path) else { continue }
                try? FileManager.default.copyItem(at: from, to: root.appendingPathComponent(file))
            }
            // The per-asset records are re-keyed, not copied: the clone's
            // frames have new names (an `.ARW` becomes a `.dng`) and new
            // bytes, so only a person's edits carry over — the hash and the
            // imported layer are re-read from the converted files.
            let sourceRecords = assetStore.records(inProjectFolder: originalRoot)
            var cloneRecords = AssetRecords()
            for input in inputs {
                let oldName = "source/\(input.lastPathComponent)"
                let newName = "source/\(input.deletingPathExtension().lastPathComponent).dng"
                guard let record = sourceRecords[oldName], record.edited != nil else { continue }
                var moved = AssetRecord(name: newName)
                moved.edited = record.edited
                moved.editedAt = record.editedAt
                cloneRecords.put(moved)
            }
            if !cloneRecords.isEmpty {
                try? cloneRecords.compact(to: AssetRecords.url(inProjectFolder: root))
            }

            // The record of what was done, beside the frames it describes.
            let ledger: [String: Any] = [
                "sourceProjectID": capture.id.uuidString,
                "strategy": strategy.label,
                "convertedAt": ISO8601DateFormatter().string(from: Date()),
                "frames": result.reports.count,
                "inputBytes": result.inputBytes,
                "outputBytes": result.outputBytes,
                "elapsedSeconds": result.elapsedSeconds,
                "framesPerSecond": result.framesPerSecond,
                "perFrame": result.reports.map { report -> [String: Any] in
                    var stages: [String: Double] = [:]
                    for (name, ms) in report.stages { stages[name, default: 0] += ms }
                    return ["file": report.output.lastPathComponent, "width": report.width, "height": report.height,
                            "totalMs": report.totalMilliseconds, "outBytes": report.outputBytes, "decode": report.decodePath, "stages": stages]
                },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: ledger, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("dng-archive.json"))
            }

            try FileManager.default.moveItem(at: root, to: finalRoot)
            var clone = capture
            clone.id = id
            clone.name = "\(capture.displayTitle) · \(nameSuffix)"
            clone.sourceFileNames = inputs.map { "source/\($0.deletingPathExtension().lastPathComponent).dng" }
            clone.clipEncodings = nil
            clone.importedFromID = nil
            // A clone is a new arrival even though its source has been here for
            // months; without this it would inherit the original's date and
            // hide at the far end of an Added sort.
            clone.addedAt = Date()
            if let first = result.reports.first, first.width > 0, first.height > 0 {
                clone.sourceWidth = first.width
                clone.sourceHeight = first.height
            }
            captures.insert(clone, at: 0)
            captures.sort { $0.createdAt > $1.createdAt }
            try persistLibrary()
            Task { [weak self] in await self?.refreshStillsMetadata(for: clone.id) }
            recordAssets(for: clone)
            return clone
        } catch {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: finalRoot)
            throw error
        }
    }

    /// Removes `.dng-archive-*` staging folders left by runs the app did not
    /// live to finish.
    nonisolated static func sweepStaleArchiveStaging(in projectsRoot: URL) {
        let items = (try? FileManager.default.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil, options: [])) ?? []
        for item in items where item.lastPathComponent.hasPrefix(".dng-archive-") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: - Importing a movie shot outside the app

    /// Brings a movie file in as a video project.
    ///
    /// The same job as the stills path and for the same reason: what the
    /// camera wrote about this clip should end up in the LetsLapse structure
    /// rather than being thrown away at the door. For a movie that is a
    /// shorter list than a raw sequence's — the container carries a creation
    /// date, a frame rate, a pixel size and a codec, and that is about all —
    /// but every one of those is something the project used to invent.
    ///
    /// Three concrete differences from the old one-line `setSource(.video:)`:
    /// the file keeps its own name, `createdAt` is the day the clip was SHOT,
    /// and the multi-gigabyte copy happens off the main actor behind a
    /// progress card instead of freezing the window.
    func importVideo(from url: URL) {
        guard mediaImport == nil else { return }
        Task { await runVideoImport(url) }
    }

    private func runVideoImport(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        beginActivity(.importingArchive)
        mediaImport = MediaImportProgress(phase: .reading, name: url.lastPathComponent)
        defer {
            mediaImport = nil
            endActivity(.importingArchive)
        }

        let byteCount = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let shotAt = await Self.movieCreationDate(of: url)
        mediaImport?.phase = .copying
        mediaImport?.totalBytes = byteCount

        let id = UUID()
        let root = captureFolderURL(for: id)
        do {
            try Self.checkStorageHeadroom(for: byteCount, at: projectsRootURL)
            let relativeName = try await copyImportedMovie(url, to: root, bytes: byteCount)
            mediaImport?.phase = .finishing
            let capture = CaptureProject(
                id: id,
                kind: .video,
                createdAt: shotAt ?? Date(),
                originalName: url.lastPathComponent,
                mode: Self.importedVideoMode,
                sourceFileNames: [relativeName],
                sourceFPS: nil)
            captures.insert(capture, at: 0)
            captures.sort { $0.createdAt > $1.createdAt }
            try persistLibrary()
            // Frame rate, duration and pixel size come from the probe every
            // video project gets — one code path, so an imported clip and a
            // captured one describe themselves the same way.
            Task { [weak self] in await self?.refreshVideoMetadata(for: capture.id) }
            recordAssets(for: capture)
            autoTagIfEnabled(capture)
            openCapture(capture)
        } catch {
            try? FileManager.default.removeItem(at: root)
            errorMessage = "Couldn't import that video: \(error.localizedDescription)"
        }
    }

    /// Copies the movie into `root/source/` under its own name, reporting
    /// progress by watching the destination grow.
    ///
    /// The poll is there because `FileManager.copyItem` is one opaque call
    /// with no progress of its own, and the alternative — a hand-rolled
    /// chunked copy — would give up APFS cloning, which is what makes a
    /// same-volume import of a 40 GB ProRes clip instant instead of a
    /// ten-minute wait. Polling costs one `stat` a quarter-second and is
    /// wrong about nothing.
    private func copyImportedMovie(
        _ url: URL, to root: URL, bytes: Int64
    ) async throws -> String {
        let sourceFolder = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let name = url.lastPathComponent
        let destination = sourceFolder.appendingPathComponent(name)

        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let written = Int64((try? destination.resourceValues(
                    forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                await MainActor.run { self?.mediaImport?.bytes = min(written, bytes) }
            }
        }
        defer { watcher.cancel() }

        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: url, to: destination)
        }.value
        return "source/\(name)"
    }

    /// When the clip was shot, from the container's own creation date.
    ///
    /// Nil rather than "now" when the file doesn't say: `createdAt` decides
    /// where a project sorts in the library and what every "shot N ago" line
    /// reads, and a made-up date is worse than the import date, which is at
    /// least true about something.
    nonisolated static func movieCreationDate(of url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate),
           let date = try? await item.load(.dateValue) {
            return date
        }
        // QuickTime/MP4 files written by tools that skip the creation atom
        // still carry the file system's own date, which for a card copy is
        // the shoot's.
        return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// Refuses an import that would not fit, before a byte is written.
    /// `slack` is the working room left behind — a volume filled to the last
    /// byte by a copy is a volume nothing else on the device can run on.
    nonisolated static func checkStorageHeadroom(
        for needed: Int64, at destination: URL, slack: Int64 = 512 * 1024 * 1024
    ) throws {
        let available = Int64((try? destination
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0)
        guard available > 0 else { return }  // Unknown: let the copy speak.
        guard available >= needed + slack else {
            throw ImportError.insufficientStorageForStills(
                available: available, needed: needed)
        }
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
            let urls = clipNames.map { root.appendingPathComponent($0, isDirectory: false) }
            // The per-frame existence walk is O(shoot) in syscalls and this
            // sits on view-body paths via `mediaURL` — walk once per capture
            // per session, and let file-mutating persists clear the ticket
            // (`persistLibrary`; grade writes rightly don't).
            if !validatedSourceFrames.contains(capture.id) {
                for url in urls where !FileManager.default.fileExists(atPath: url.path) {
                    throw CocoaError(.fileNoSuchFile)
                }
                validatedSourceFrames.insert(capture.id)
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
            stampPresetStatesIfNeeded()
            stampAddedDatesIfNeeded()
            for capture in captures
            where capture.kind == .video
                && (capture.sourceFPS == nil || capture.sourceDurationSeconds == nil
                    || capture.sourceWidth == nil || capture.sourceSegmentSeconds == nil
                    || capture.sourceSegmentFPS == nil) {
                Task { [weak self] in
                    await self?.refreshVideoMetadata(for: capture.id)
                }
            }
            // One-shot catch-up for stills projects from before they were
            // probed at all. Gated on dimensions — always derivable, so this
            // settles in one pass — with the capture span filled in the same
            // pass wherever a covering sidecar exists.
            for capture in captures
            where capture.kind == .photos && capture.sourceWidth == nil {
                Task { [weak self] in
                    await self?.refreshStillsMetadata(for: capture.id)
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

    /// One-time stamp for the preset-state model: every project that predates
    /// it gets the state its own values describe, written into the sidecar so
    /// the state is a stored fact from here on rather than a derivation.
    ///
    /// No look changes — the resolver reads the numbers already on the project.
    /// A project sitting on a saved preset's exact values comes out `.named`
    /// with that preset's current definition as its snapshot, which is the best
    /// available answer for a project that never recorded one.
    private func stampPresetStatesIfNeeded() {
        guard gradingSchemaVersion < 2 else { return }
        gradingSchemaVersion = 2
        let customPresets = CustomPresetStore.shared.presets
        for index in captures.indices where captures[index].presetState == nil {
            captures[index].presetState = PresetStateResolver.resolve(
                preset: PhotoPreset.resolve(captures[index].selectedPreset),
                adjustments: captures[index].adjustments ?? .neutral,
                anchor: .edited,
                customPresets: customPresets)
        }
        try? persistLibrary()
    }

    /// One-time stamp for the **Added** axis: every project that predates the
    /// field learns when it arrived here from its own folder's creation date.
    ///
    /// The filesystem has been recording this all along — a project folder is
    /// created at the instant the project is registered, whether it was shot
    /// here, imported from a file or received off the wire — so the answer for
    /// an existing library is already on disk and does not have to be guessed.
    /// A folder that can't be read falls back to the capture date, which is the
    /// right answer for anything captured on this device anyway.
    ///
    /// One `stat` per project, once, on the launch that migrates.
    private func stampAddedDatesIfNeeded() {
        guard gradingSchemaVersion < 3 else { return }
        gradingSchemaVersion = 3
        for index in captures.indices where captures[index].addedAt == nil {
            let folder = captureFolderURL(for: captures[index].id)
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            captures[index].addedAt = created ?? captures[index].createdAt
        }
        try? persistLibrary()
    }

    func persistLibrary() throws {
        // Every path that adds, converts, rotates or deletes a project's files
        // ends here, so this is the one place that has to drop the size cache —
        // and the existence tickets, which stale under exactly the same edits.
        projectStorageBytes.removeAll()
        validatedSourceFrames.removeAll()
        try FileManager.default.createDirectory(at: projectsRootURL, withIntermediateDirectories: true)
        var manifest = LibraryManifest(
            captures: captures.map(stampingPresetState), blends: blends, collections: collections)
        manifest.gradingSchemaVersion = max(gradingSchemaVersion, 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    /// A capture with its preset state written out explicitly.
    ///
    /// A freshly registered project has no state yet — every registration path
    /// would otherwise have to remember to set one — and `presetState(for:)`
    /// derives the right answer for it (`.original`: no preset, no sliders).
    /// This makes that answer a stored fact rather than a derivation, so the
    /// sidecar says what state the project is in even years from now, when the
    /// derivation rules may have moved on. Copies rather than mutating
    /// `captures`: persisting is not a model change, and the in-memory value
    /// derives identically.
    private func stampingPresetState(_ capture: CaptureProject) -> CaptureProject {
        guard capture.presetState == nil else { return capture }
        var stamped = capture
        stamped.presetState = presetState(for: capture)
        return stamped
    }

    private var applicationSupportURL: URL {
        StorageRoot.current
    }

    private var legacyApplicationSupportURL: URL {
        let legacyName = ["Let", "s Lapse"].joined(separator: "'")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(legacyName, isDirectory: true)
    }

    private func migrateLegacyApplicationSupportFolderIfNeeded() throws {
        // Against the DEFAULT location on purpose: the legacy folder predates
        // custom locations entirely, and moving it onto a nominated external
        // root would be a cross-volume copy dressed up as a rename.
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyApplicationSupportURL.path),
              !fileManager.fileExists(atPath: StorageRoot.defaultRootURL.path)
        else { return }

        try fileManager.moveItem(at: legacyApplicationSupportURL, to: StorageRoot.defaultRootURL)
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

    /// Where a project's stills and their sidecars live — `frames.timestamps`,
    /// `frames.exposure`, `frames.whitebalance`, `capture_log.json` and the
    /// framing review.
    func sourceFolderURL(for capture: CaptureProject) -> URL {
        captureFolderURL(for: capture.id).appendingPathComponent("source", isDirectory: true)
    }

    /// Re-reads the lock when the project screen commits or withdraws one
    /// while the same project is open in Adjust.
    func refreshFramingLockIfOpen(_ capture: CaptureProject) {
        guard currentCaptureID == capture.id else { return }
        loadFramingLock(for: capture)
    }

    /// Reads the project's framing lock off the main actor and seeds the
    /// Advanced switch from it. The lock is a few hundred kilobytes of JSON
    /// for a five-thousand-photo shoot — never on the main thread, and never
    /// left over from the previous project while it loads.
    func loadFramingLock(for capture: CaptureProject) {
        framingLockLoad?.cancel()
        framingLock = nil
        applyStabilisation = false
        guard capture.kind == .photos, !capture.isPhotoCapture else { return }
        let folder = sourceFolderURL(for: capture)
        let captureID = capture.id
        framingLockLoad = Task { [weak self] in
            let lock = await Task.detached(priority: .utility) { FramingLock.load(inSourceFolder: folder) }.value
            guard !Task.isCancelled, let self, self.currentCaptureID == captureID else { return }
            self.framingLock = lock
            self.applyStabilisation = lock != nil
        }
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

    /// The stills counterpart of `refreshVideoMetadata`: what a photo-kind
    /// project can know about itself after the fact — dimensions from the
    /// first frame's metadata (oriented, no pixel decode), and, where the
    /// shoot wrote a covering `frames.timestamps`, the real capture span as
    /// `sourceDurationSeconds`. Enablers for the warp timeline's stills lane
    /// (docs/interval-adjust-unification.md); nothing user-facing shows them
    /// for stills yet — the badge and header lines stay kind-gated until that
    /// screen exists.
    private func refreshStillsMetadata(for captureID: UUID) async {
        guard let capture = captures.first(where: { $0.id == captureID }),
              capture.kind == .photos else { return }
        let urls = sourceFrameURLs(for: capture)
        guard let first = urls.first else { return }
        let probed = await Task.detached(priority: .utility) {
            (size: MediaGeometry.stillDisplaySize(url: first),
             elapsed: FrameTimestamps.load(besideFrames: urls)?
                .elapsedSeconds(coveringExactly: urls.count))
        }.value
        guard let index = captures.firstIndex(where: { $0.id == captureID }) else { return }
        var changed = false
        if let size = probed.size, size.width > 0, size.height > 0 {
            let width = Int(size.width.rounded())
            let height = Int(size.height.rounded())
            if captures[index].sourceWidth != width || captures[index].sourceHeight != height {
                captures[index].sourceWidth = width
                captures[index].sourceHeight = height
                changed = true
            }
        }
        // A single photo's span is 0 and a sidecar that doesn't cover the
        // frames is nil — both leave the field alone rather than inventing a
        // duration.
        if let span = probed.elapsed?.last, span > 0,
           captures[index].sourceDurationSeconds != span {
            captures[index].sourceDurationSeconds = span
            changed = true
        }
        if changed { try? persistLibrary() }
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
        // A person changed this project — see CaptureProject.modifiedAt.
        captures[index].modifiedAt = Date()
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
        // A person changed this project — see CaptureProject.modifiedAt.
        captures[index].modifiedAt = Date()
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
        // A person changed this project — see CaptureProject.modifiedAt.
        markEdited(capture.id)
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

    /// True while a received transfer is being installed. Together with
    /// `archiveImport != nil` this is the one-install-at-a-time gate — two
    /// writers of `library.json` is the failure worth spending a flag on.
    private var isInstallingIncoming = false

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
        /// The stills-import twin. Its own case because the archive sentence
        /// talks about unpacking, and a folder of frames is copied.
        case insufficientStorageForStills(available: Int64, needed: Int64)

        var errorDescription: String? {
            switch self {
            case .insufficientStorage(let available, let needed):
                return """
                Not enough storage to import this project. It unpacks to at least \
                \(LLFormat.bytes(needed)) but only \(LLFormat.bytes(available)) is available. \
                Free up space and try again.
                """
            case .insufficientStorageForStills(let available, let needed):
                return """
                Not enough storage to import those photos. They take \
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

    /// Whether this library already holds the project another device is
    /// offering as `originID` — the transfer picker's "Hide imported" answer.
    ///
    /// Same test the archive door uses, and it catches both directions: a
    /// project pulled from that device (matched on `importedFromID`) and one
    /// that started here and was copied TO it (matched on `id`). Projects
    /// imported before `importedFromID` was recorded have no thread back and
    /// read as not-imported — the honest answer, since nothing on either side
    /// can still prove they are the same shoot.
    func hasImported(originID: UUID) -> Bool {
        existingImport(of: originID) != nil
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
        beginActivity(.importingArchive)
        defer { endActivity(.importingArchive) }
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

            guard let capture = try await installStagedProject(at: staging) else {
                // The human chose the copy they already have; `install` has
                // opened it for them.
                finishArchiveImport()
                return
            }
            finishArchiveImport()
            // Land on the project itself rather than opening a blend flow over
            // it: importing is "here is the thing", not "start editing it".
            show(capture)
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

    /// Turns an unpacked project tree into a project in this library.
    ///
    /// Source-agnostic on purpose: the tree can have come out of a `.lapse`
    /// archive or off the network file by file, and from here on the two are
    /// the same job — read the manifest, ask the duplicate question, mint fresh
    /// UUIDs (folder names and lookups key on them, so reusing the originals
    /// would collide with re-imports or with the source device's own library),
    /// move the three subfolders, re-key the blends, persist.
    ///
    /// `staging` must sit on the same volume as the library: every move here is
    /// a rename, which is what keeps peak disk at 1× the project rather than 2×.
    ///
    /// Returns nil when the human answered the duplicate question with "open
    /// the one I have" — that project has been opened for them and nothing was
    /// added. `originalCaptureID` overrides the id the tree is deduplicated
    /// against; nil takes it from the manifest, which is what an archive does.
    @discardableResult
    private func installStagedProject(
        at staging: URL,
        originalCaptureID: UUID? = nil
    ) async throws -> CaptureProject? {
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

        // Asked here, after the tree has landed, rather than before: the id
        // that identifies an archive lives in `project.json` *inside* it, and
        // finding that without a full pass would mean decompressing the whole
        // stream a second time on every import to spare the rare re-import. The
        // staged tree waits on disk while the question is open, and is deleted
        // with the rest if the answer is no.
        let originID = originalCaptureID ?? manifest.capture.id
        if let existing = existingImport(of: originID) {
            archiveImport?.phase = .duplicate(existingName: existing.name ?? existing.originalName)
            let importAgain = await withCheckedContinuation { continuation in
                duplicateImportDecision = continuation
            }
            guard importAgain else {
                show(existing)
                return nil
            }
            archiveImport?.phase = .installing
        }

        var capture = manifest.capture
        let newID = UUID()
        capture.id = newID
        capture.importedFromID = originID
        // The record came off another device, so its own stamp says when the
        // project landed THERE. `createdAt` is left alone on purpose — that is
        // the shoot's date and it travels — but "added" is a fact about this
        // library, and this is the moment it becomes true.
        capture.addedAt = Date()
        let destination = captureFolderURL(for: newID)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // Anything not named here is silently dropped at import — a new
        // project subfolder must join this list or it doesn't travel. The
        // transfer's file enumerator reads the SAME constant, so a subfolder
        // that misses it doesn't waste an hour on the wire either.
        for subfolder in ProjectArchive.transferableSubfolders {
            let extracted = staging.appendingPathComponent(subfolder)
            if FileManager.default.fileExists(atPath: extracted.path) {
                try FileManager.default.moveItem(at: extracted, to: destination.appendingPathComponent(subfolder))
            }
        }
        // The top-level sidecars, on the same terms — a missing one is simply
        // a project that never had it, so this never throws for absence.
        for file in ProjectArchive.transferableFiles {
            let extracted = staging.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: extracted.path) {
                try? FileManager.default.moveItem(at: extracted, to: destination.appendingPathComponent(file))
            }
        }

        var importedBlends: [BlendProject] = []
        var blendRenames: [String: String] = [:]
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
            blendRenames[blend.outputFileName] = newFileName
            blend.id = newBlendID
            blend.captureID = newID
            blend.outputFileName = newFileName
            importedBlends.append(blend)
        }

        // The arrived `assets.ndjson` names blends by the SENDER's ids; the
        // lines follow the files to their new names, and anything else it
        // names that did not arrive is dropped with the file.
        if !blendRenames.isEmpty || FileManager.default.fileExists(atPath: AssetRecords.url(inProjectFolder: destination).path) {
            assetStore.forget(projectFolder: destination)
            let arrived = assetStore.records(inProjectFolder: destination)
            var rekeyed = AssetRecords()
            for record in arrived.ordered {
                if record.name.hasPrefix("blends/") {
                    guard let newName = blendRenames[record.name] else { continue }
                    var moved = record
                    moved.name = newName
                    rekeyed.put(moved)
                } else {
                    rekeyed.put(record)
                }
            }
            try? assetStore.replace(inProjectFolder: destination, with: rekeyed)
        }

        captures.insert(capture, at: 0)
        blends.append(contentsOf: importedBlends)
        try persistLibrary()
        // Whatever the sender never hashed or read, this side finishes.
        recordAssets(for: capture)
        // A stills project from a device that predates their probing arrives
        // without its dimensions/span — fill them now rather than waiting for
        // the next launch's catch-up pass.
        if capture.kind == .photos, capture.sourceWidth == nil {
            let importedID = capture.id
            Task { [weak self] in
                await self?.refreshStillsMetadata(for: importedID)
            }
        }
        return capture
    }

    // MARK: - Project transfer

    /// What the transfer server offers, one row per project in the library.
    ///
    /// Sizing 40 projects walks 40 directory trees, so it happens off the main
    /// actor and the caller caches the result. Thumbnails are read straight out
    /// of the disk cache and are nil when it holds none: on iOS a captured DNG
    /// has no preview IFD, so generating one costs a full RAW decode, and a
    /// picker row is not worth that on the phone that is about to send 16 GB.
    func projectTransferCatalogue() async -> [PTProjectInfo] {
        let rows: [(capture: CaptureProject, folder: URL)] = captures.map {
            ($0, captureFolderURL(for: $0.id))
        }
        return await Task.detached(priority: .utility) { () -> [PTProjectInfo] in
            rows.map { row in
                PTProjectInfo(
                    captureID: row.capture.id,
                    name: row.capture.name ?? row.capture.originalName,
                    createdAt: row.capture.createdAt,
                    frameCount: row.capture.sourceMediaCount,
                    totalBytes: AppModel.directorySize(row.folder))
            }
        }.value
    }

    /// One project's picker tile, for the row the other device is looking at.
    ///
    /// Generated if the disk cache has none — which, on a real library, is most
    /// of them: `DiskThumbnailStore` only holds a tile for an asset some grid
    /// has actually drawn, so a 293-project phone had 62. Doing this eagerly for
    /// the whole catalogue was never an option (an iOS DNG has no preview IFD,
    /// so each miss is a full RAW decode), but doing it for the handful of rows
    /// on screen is exactly the bargain the Gallery already makes — and the
    /// result is persisted, so the second look is free and the local grids get
    /// it for nothing too.
    func projectTransferThumbnail(for captureID: UUID) async -> Data? {
        guard let capture = captures.first(where: { $0.id == captureID }),
              let source = thumbnailURL(for: capture) else { return nil }
        let kind: MediaKind = capture.kind == .video ? .video : .image
        return await Task.detached(priority: .utility) { () -> Data? in
            // Cached already? Hand it straight over, shrunk to tile size.
            if let cached = DiskThumbnailStore.storedData(for: source, maxPixelSize: 320) {
                return cached
            }
            guard let generated = ProjectThumbnailGenerator.thumbnail(for: source, kind: kind)
            else { return nil }
            // Persist under the same key the local grids read, so this decode
            // is paid once for the whole app rather than once per request.
            DiskThumbnailStore.write(generated, forKey: DiskThumbnailStore.key(for: source))
            return DiskThumbnailStore.jpegData(from: generated, maxPixelSize: 320)
        }.value
    }

    /// The folder holding a project's files, or nil when the library has no
    /// such project — which is what a client asking for one deleted between the
    /// list and the request gets told.
    func projectTransferFolderURL(for captureID: UUID) -> URL? {
        guard captures.contains(where: { $0.id == captureID }) else { return nil }
        return captureFolderURL(for: captureID)
    }

    /// The `project.json` a receiving device installs from — the same manifest
    /// `exportProject` writes into a `.lapse`, built in memory because on this
    /// path it never touches the sending device's disk.
    func projectTransferManifestData(for captureID: UUID) throws -> Data? {
        guard let capture = captures.first(where: { $0.id == captureID }) else { return nil }
        let manifest = ProjectArchiveManifest(capture: capture, blends: blends(for: capture))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    /// Somewhere for an incoming project to land — cleared, not merged into.
    ///
    /// Phase 1's vocabulary carries no `have` set, so there is no way to tell a
    /// whole file left by an earlier attempt from a stale one, and a stale file
    /// that happened to match a size would install silently wrong. When resume
    /// lands (the plan's §4) this becomes the reconciliation point.
    @discardableResult
    nonisolated static func stageIncoming(captureID: UUID) throws -> URL {
        let url = StorageRoot.incomingURL(for: captureID)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Publishes a fully-received tree as a project and clears its staging
    /// folder. Nothing reaches the library until every file has landed, so a
    /// dropped transfer leaves a resumable partial rather than a broken project.
    @discardableResult
    func commitIncoming(captureID: UUID) async throws -> CaptureProject? {
        // One install at a time. A `.lapse` double-clicked in Finder while a
        // transfer finishes would otherwise have both writing `library.json`,
        // and both showing their progress through the same sheet.
        while archiveImport != nil || isInstallingIncoming {
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        isInstallingIncoming = true
        defer { isInstallingIncoming = false }

        let staging = StorageRoot.incomingURL(for: captureID)
        beginActivity(.importingArchive)
        defer { endActivity(.importingArchive) }
        // Borrowing the archive sheet for the install phase: it is seconds of
        // renames, and it is also where the duplicate question lives — a
        // transfer of a project this library already holds has to ask the same
        // question, with the same two answers.
        let progress = ArchiveImport(
            url: staging,
            name: staging.lastPathComponent,
            archiveBytes: 0)
        archiveImport = progress
        archiveImport?.phase = .installing
        defer {
            if archiveImport?.id == progress.id, archiveImport?.isFailed != true {
                archiveImport = nil
            }
        }

        let capture = try await installStagedProject(at: staging, originalCaptureID: captureID)
        // Whatever the answer, the staging tree is done: install moved the
        // subfolders out of it, and what is left is `project.json` and empties.
        try? FileManager.default.removeItem(at: staging)
        if let capture { show(capture) }
        return capture
    }

    /// Drops an incoming tree without installing it, freeing its disk.
    nonisolated static func discardIncoming(captureID: UUID) {
        try? FileManager.default.removeItem(at: StorageRoot.incomingURL(for: captureID))
    }

    /// Interrupted transfers nobody came back for. Called at launch.
    ///
    /// 24 hours rather than immediately: a partial tree is the only thing that
    /// makes a resume possible, and an app that deletes it on the next launch
    /// turns "reconnect and carry on" back into "start the 16 GB again".
    /// Deliberately conservative in the other direction too — a live transfer
    /// touches its tree constantly, so anything a day old is nobody's.
    nonisolated static func cleanStaleIncoming(olderThan age: TimeInterval = 24 * 60 * 60) {
        DispatchQueue.global(qos: .utility).async {
            let fileManager = FileManager.default
            guard let entries = try? fileManager.contentsOfDirectory(
                at: StorageRoot.incomingRootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
            else { return }
            for entry in entries {
                let values = try? entry.resourceValues(
                    forKeys: [.contentModificationDateKey, .isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                let modified = values?.contentModificationDate ?? .distantPast
                guard Date().timeIntervalSince(modified) > age else { continue }
                LLog("transfer: sweeping abandoned incoming \(entry.lastPathComponent)")
                try? fileManager.removeItem(at: entry)
            }
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
    ///
    /// An Original project grades to the identity no matter what numbers are
    /// stored beside it: Original *is* "no filter", and every render and bake
    /// in the app comes through here, so that rule is enforced once.
    func photoGrade(for capture: CaptureProject) -> PhotoGrade {
        let grade = PhotoGrade(
            preset: photoPreset(for: capture),
            adjustments: photoAdjustments(for: capture),
            timeline: gradeTimeline(for: capture),
            whiteBalance: whiteBalanceTrack(for: capture))
        // The rotation is geometry, not a filter: Original means "no filter",
        // and a levelled Original project is still levelled — at every moment.
        // A pinned white is not geometry, but it is not a *filter* either: it
        // says what the camera should have said, so an Original project keeps
        // it for the same reason it keeps its level.
        guard !presetState(for: capture).isOriginal else {
            var original = grade.rotationOnly
            original.whiteBalance = grade.whiteBalance
            return original
        }
        return grade
    }

    /// What this shoot's white balance is anchored to. Nil on the record means
    /// as-shot, which is what every project said before the field existed.
    func whiteBalanceSource(for capture: CaptureProject) -> WhiteBalanceSource {
        capture.whiteBalanceSource ?? .asShot
    }

    /// The source resolved against the shoot's measured series — the thing the
    /// renderer asks "what white is this frame declared at?".
    ///
    /// Only `.smoothed` needs the series, and only `.smoothed` pays for
    /// reading it; the answer is cached per project because the correction
    /// runs over every frame of the shoot and a scrub must not re-run it.
    func whiteBalanceTrack(for capture: CaptureProject) -> WhiteBalanceTrack {
        let source = whiteBalanceSource(for: capture)
        guard case .smoothed = source else {
            return WhiteBalanceTrack.resolve(source: source, series: nil)
        }
        let key = "\(capture.id.uuidString)|\(source)"
        if let cached = Self.whiteBalanceTrackCache[key] { return cached }
        let series = whiteBalanceSeries(for: capture)
        let track = WhiteBalanceTrack.resolve(source: source, series: series)
        Self.whiteBalanceTrackCache[key] = track
        return track
    }

    private static var whiteBalanceTrackCache: [String: WhiteBalanceTrack] = [:]

    /// Forgets the resolved track for one project — after a re-measure, or
    /// after the source changes.
    static func forgetWhiteBalanceTrack(_ id: UUID) {
        whiteBalanceTrackCache = whiteBalanceTrackCache.filter { !$0.key.hasPrefix(id.uuidString) }
    }

    /// The measured as-shot series beside a shoot's frames, if it has been
    /// measured. Nil is not an error: it means the pass has not run, and a
    /// smoothed track declares nothing until it has.
    func whiteBalanceSeries(for capture: CaptureProject) -> WhiteBalanceSeries? {
        let url = sourceFolderURL(for: capture)
            .appendingPathComponent(WhiteBalanceSeries.fileName)
        guard let series = try? WhiteBalanceSeries.load(from: url), !series.isEmpty else {
            return nil
        }
        return series
    }

    /// The manual slider grade layered on the preset. Projects saved before the
    /// sliders existed have none, which means "the preset on its own".
    ///
    /// For a keyframed project this is the grade at the *opening* moment — the
    /// timeline keeps it mirrored there — so a caller that can only hold one set
    /// of values shows the look the clip starts on rather than an average of it.
    func photoAdjustments(for capture: CaptureProject) -> PhotoAdjustments {
        capture.adjustments ?? .neutral
    }

    /// How the grade travels across this shoot. Empty for every project that
    /// has one look end to end, which is every project until somebody grades a
    /// second moment of it.
    func gradeTimeline(for capture: CaptureProject) -> GradeTimeline {
        capture.gradeTimeline ?? .empty
    }

    // MARK: Preset state

    /// Which of the three states this project's grade is in.
    ///
    /// Stored on the project since the state model shipped. Anything older —
    /// and anything imported from an archive written before it — is derived
    /// from the values themselves, which is exactly what the resolver does with
    /// no anchor to go on.
    func presetState(for capture: CaptureProject) -> PresetState {
        // Keyframes outrank a stored state: a project whose grade moves over
        // time is Edited whatever a sidecar written before the keyframes says,
        // and an Original stamp would otherwise make `photoGrade` throw the
        // whole timeline away as "no filter".
        if let stored = capture.presetState, capture.gradeTimeline?.isEmpty ?? true {
            return stored
        }
        return PresetStateResolver.resolve(
            preset: PhotoPreset.resolve(capture.selectedPreset),
            adjustments: capture.adjustments ?? .neutral,
            timeline: gradeTimeline(for: capture),
            anchor: capture.presetState ?? .edited,
            customPresets: CustomPresetStore.shared.presets)
    }

    /// Applies a built-in preset. Original is the destructive one: it clears
    /// every adjustment as well as the preset, because Original means the file
    /// exactly as captured.
    func applyPreset(_ preset: PhotoPreset, for capture: CaptureProject) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        let state: PresetState = preset == .original
            ? .original
            : .named(id: preset.presetID, snapshot: preset.snapshot)
        // A preset is one look, so applying it wholesale from outside the editor
        // takes the shoot back to one look — the keyframes go with the manual
        // adjustments they were made of. (Inside the editor, where there is a
        // playhead to aim at, a chip writes at the playhead instead.) The
        // level is geometry, not a look, and stays — at every moment it had;
        // so does the crop, which `rotationOnly` keeps beside it for the same
        // reason (a preset applied to a cropped photograph must not uncrop it).
        let current = photoGrade(for: captures[index]).rotationOnly
        write(
            preset: preset, adjustments: current.adjustments, state: state,
            timeline: current.timeline, at: index)
    }

    /// Applies a saved preset wholesale: its base preset and its slider values,
    /// plus the snapshot that pins what "this preset" meant at this moment.
    func applyCustomPreset(_ preset: CustomPreset, for capture: CaptureProject) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        // The preset's look over the project's own level, its own crop and its
        // own white, none of which the preset ever carried (see
        // `PresetSnapshot.matches`) — so all three are re-applied from the
        // project, the crop included, or applying a look would uncrop it.
        let current = photoGrade(for: captures[index]).rotationOnly
        var adjustments = preset.adjustments.withoutGeometry.withoutWhite
        adjustments.rotationDegrees = current.adjustments.rotationDegrees
        adjustments.crop = current.adjustments.crop
        adjustments.whiteMired = current.adjustments.whiteMired
        adjustments.whiteTint = current.adjustments.whiteTint
        write(
            preset: preset.basePreset, adjustments: adjustments,
            state: .named(id: preset.id, snapshot: preset.snapshot),
            timeline: current.timeline, at: index)
    }

    /// The editors' write-back: the live values and the state they resolved to,
    /// in one persisted change. The stored original files are never touched —
    /// this only records numbers, which an export bakes in later.
    func setPhotoGrade(
        preset: PhotoPreset,
        adjustments: PhotoAdjustments,
        state: PresetState,
        timeline: GradeTimeline = .empty,
        for capture: CaptureProject
    ) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        write(
            preset: preset, adjustments: adjustments, state: state, timeline: timeline,
            at: index)
    }

    /// The one place a project's grade changes, so no path can leave the state
    /// disagreeing with the values it describes.
    private func write(
        preset: PhotoPreset,
        adjustments: PhotoAdjustments,
        state: PresetState,
        timeline: GradeTimeline,
        at index: Int
    ) {
        // An empty timeline is stored as nil, so a project that never grew one
        // reads and writes exactly the sidecar it always did.
        let stored: GradeTimeline? = timeline.isEmpty ? nil : timeline
        guard captures[index].selectedPreset != preset.rawValue
                || captures[index].adjustments != adjustments
                || captures[index].presetState != state
                || captures[index].gradeTimeline != stored else { return }
        captures[index].selectedPreset = preset.rawValue
        captures[index].adjustments = adjustments
        captures[index].presetState = state
        captures[index].gradeTimeline = stored
        // A LUT renders from a cube the project must be able to find on any
        // device it travels to: copy it into the project's own `luts/` (a
        // transferable subfolder) the first time a grade carries it. Cheap
        // once copied — one `fileExists` per write. docs/presets-lut-spike.md §4.4.
        var lutIDs = Set<String>()
        if let id = adjustments.lut?.id { lutIDs.insert(id) }
        for keyframe in timeline.keyframes { if let id = keyframe.adjustments.lut?.id { lutIDs.insert(id) } }
        if !lutIDs.isEmpty {
            let folder = captureFolderURL(for: captures[index].id)
            for id in lutIDs { LUTStore.shared.ensureCopy(of: id, inProjectFolder: folder) }
        }
        // A person changed this project — see CaptureProject.modifiedAt. A
        // grade moves no bytes, so this DOES cost the project's stored size a
        // needless re-measure on the next size sort; carrying a second
        // "files changed" timestamp to avoid it would be a worse trade than
        // one directory walk on a deliberate, occasional gesture.
        captures[index].modifiedAt = Date()
        // Not `persistLibrary()`: a grade write changes numbers, never files,
        // so it must not clear the size caches — and the editors call this at
        // gesture cadence, so the manifest encode cannot run on the main
        // thread (editor-performance-plan.md, stage 2).
        persistLibraryOffMain()
    }

    /// Pins (or unpins) what this shoot's white balance is measured from.
    ///
    /// Stored as nil for `.asShot`, so a project that never touched it reads
    /// and writes exactly the record it always did. The resolved track is
    /// forgotten here rather than at read time: a smoothed source's correction
    /// runs over every frame of the shoot, and the answer is only stale when
    /// the source changes or the series is re-measured.
    func setWhiteBalanceSource(_ source: WhiteBalanceSource, for capture: CaptureProject) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        let stored: WhiteBalanceSource? = source.isAsShot ? nil : source
        guard captures[index].whiteBalanceSource != stored else { return }
        captures[index].whiteBalanceSource = stored
        // A person changed this project — see CaptureProject.modifiedAt.
        captures[index].modifiedAt = Date()
        Self.forgetWhiteBalanceTrack(capture.id)
        persistLibraryOffMain()
    }

    /// Measures every still's as-shot white balance and writes the sidecar the
    /// smoothed source reads. Off the main thread — it opens every raw in the
    /// shoot — and idempotent unless `force` is set.
    ///
    /// Returns the series, or nil when nothing in the shoot reported a usable
    /// as-shot neutral (a JPEG import, or a raw format the converter does not
    /// know).
    @discardableResult
    func measureWhiteBalance(
        for capture: CaptureProject, force: Bool = false
    ) async -> WhiteBalanceSeries? {
        let folder = sourceFolderURL(for: capture)
        let urls = capture.sourceFileNames.map { captureFolderURL(for: capture.id).appendingPathComponent($0) }
        guard !urls.isEmpty else { return nil }
        if !force, let existing = whiteBalanceSeries(for: capture),
           existing.samples.count == urls.count {
            return existing
        }
        let seconds = frameCaptureSeconds(for: capture, count: urls.count)
        let series = await Task.detached(priority: .utility) {
            var samples: [WhiteBalanceSample] = []
            samples.reserveCapacity(urls.count)
            for (index, url) in urls.enumerated() {
                guard ImportedStills.isRaw(url),
                      let raw = LossyLinearDNG.rawFilter(for: url) else { continue }
                let kelvin = raw.neutralTemperature
                let tint = raw.neutralTint
                guard LinearFrameDecoder.isUsableNeutral(
                    temperatureK: Double(kelvin), tint: Double(tint)) else { continue }
                samples.append(WhiteBalanceSample(
                    frame: index, file: url.lastPathComponent,
                    kelvin: kelvin, tint: tint, seconds: seconds[index]))
            }
            return WhiteBalanceSeries(samples: samples)
        }.value
        guard !series.isEmpty else { return nil }
        try? series.write(to: folder)
        Self.forgetWhiteBalanceTrack(capture.id)
        return series
    }

    /// Seconds from the first frame for each still, from the shoot's own
    /// timing sidecar when it wrote one. Without it the white-balance
    /// correction works in per-frame steps rather than per-second ones.
    private func frameCaptureSeconds(for capture: CaptureProject, count: Int) -> [Double] {
        let url = sourceFolderURL(for: capture)
            .appendingPathComponent(FrameTimestamps.fileName)
        guard let timestamps = try? FrameTimestamps.load(from: url),
              timestamps.entries.count == count,
              let first = timestamps.entries.first?.captureTime
        else { return Array(repeating: 0, count: count) }
        return timestamps.entries.map { $0.captureTime.timeIntervalSince(first) }
    }

    /// The manifest write for value-only changes, off the main thread.
    ///
    /// The snapshot is taken here, synchronously — value types, so the encode
    /// on the queue sees exactly the state this call saw — and the queue is
    /// serial, so rapid writes land in order and the last one wins. Unlike
    /// `persistLibrary()` this leaves `projectStorageBytes` alone: callers
    /// are changing stored numbers, not files on disk.
    private static let libraryPersistQueue = DispatchQueue(
        label: "com.letslapse.library-persist", qos: .utility)
    func persistLibraryOffMain() {
        var manifest = LibraryManifest(
            captures: captures.map(stampingPresetState), blends: blends, collections: collections)
        manifest.gradingSchemaVersion = max(gradingSchemaVersion, 1)
        let directory = projectsRootURL
        let destination = manifestURL
        Self.libraryPersistQueue.async {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(manifest) else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }

    /// Blocks until every queued off-main manifest write has landed — the
    /// editors call it on their way out, so quitting the app right after
    /// closing an editor can't lose the final gesture.
    func flushLibraryPersists() {
        Self.libraryPersistQueue.sync {}
    }

    /// One of a capture's assets as the viewer shows it, ready to leave the app:
    /// the project's grade baked into a temporary copy — a still through the
    /// image grader, a clip through a video composition pass. Every "this asset
    /// as I'm looking at it" export starts here; the platform tails (Photos on
    /// iOS, a save panel on macOS) decide where the file goes.
    ///
    /// An **Original** project hands back its source URL with `isTemporary`
    /// false: no resize, no re-encode, no filter, no format change — the file
    /// on disk, byte for byte, so a DNG stays a DNG and a ProRes stays ProRes.
    /// (For a blended output that file *is* the app's blended result; Original
    /// means "before any preset", not "back to the raw frames".) Anything else
    /// is rendered — a still becomes a JPEG, a clip is re-encoded — into a temp
    /// file the caller owns and must delete, leaving the on-disk original alone.
    func gradedExportCopy(
        of url: URL, for capture: CaptureProject
    ) async throws -> (url: URL, isTemporary: Bool) {
        // The state first, and the values only as a second net: Original is a
        // promise about the bytes that leave the app, not a fact derived from
        // whatever numbers happen to be sitting on the project.
        let grade = photoGrade(for: capture)
        // A levelled or cropped project is rendered even when its look is
        // Original — the rotation and the crop are as much "how I'm looking
        // at it" as a preset is, and an export that handed over the source
        // bytes would silently uncrop it.
        guard !presetState(for: capture).isOriginal || grade.hasRotation || grade.hasCrop else {
            return (url, false)
        }
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
