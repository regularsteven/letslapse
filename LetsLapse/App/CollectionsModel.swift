import CoreGraphics
import Foundation

// MARK: - Canvas ratios

/// The five export canvases a collection can render to. The first clip added
/// sets the collection's canvas; the chips can override it afterwards. Export
/// resolution is the ratio's maximum UHD-class size — the collection renders
/// at it regardless of what the member clips were stored at.
enum CanvasRatio: String, Codable, CaseIterable, Identifiable {
    case wide = "16:9"
    case tall = "9:16"
    case square = "1:1"
    case classic = "4:3"
    case portrait = "3:4"

    var id: String { rawValue }

    var aspect: Double {
        switch self {
        case .wide: return 16.0 / 9.0
        case .tall: return 9.0 / 16.0
        case .square: return 1
        case .classic: return 4.0 / 3.0
        case .portrait: return 3.0 / 4.0
        }
    }

    var exportSize: CGSize {
        switch self {
        case .wide: return CGSize(width: 3840, height: 2160)
        case .tall: return CGSize(width: 2160, height: 3840)
        case .square: return CGSize(width: 2160, height: 2160)
        case .classic: return CGSize(width: 2880, height: 2160)
        case .portrait: return CGSize(width: 2160, height: 2880)
        }
    }

    /// "3840×2160"
    var exportLabel: String {
        "\(Int(exportSize.width))×\(Int(exportSize.height))"
    }
}

// MARK: - Collection model

/// An ordered set of blended clips gathered from across projects, arranged on
/// a timeline with optional in/out points per clip, exported as one video.
struct LapseCollection: Identifiable, Codable, Equatable {
    /// One clip's place on the timeline. A blended clip appears at most once
    /// per collection, so the blend id doubles as the entry's identity.
    struct Entry: Identifiable, Codable, Equatable {
        /// One clip's Ken Burns move: two framings of the crop box, animated
        /// across the clip's time in the export. Zoom 1 is the whole crop box;
        /// larger zooms keep a smaller window, positioned by the anchors
        /// (0…1 across the slack the zoom opens up inside the box).
        struct KenBurnsMove: Codable, Equatable {
            var startZoom: Double
            var endZoom: Double
            var startAnchorX: Double
            var startAnchorY: Double
            var endAnchorX: Double
            var endAnchorY: Double

            /// The best-effort move a clip gets when Ken Burns turns on:
            /// direction alternates (settle in, then reveal out), zoom amounts
            /// and the zoomed framing's anchor cycle so runs of clips don't
            /// all move the same way. Deterministic per timeline position.
            static func bestEffort(forClipIndex index: Int) -> KenBurnsMove {
                let zooms: [Double] = [1.22, 1.15, 1.3, 1.18]
                let anchors: [(x: Double, y: Double)] = [
                    (0.5, 0.5), (1.0 / 3.0, 1.0 / 3.0), (2.0 / 3.0, 1.0 / 3.0),
                    (2.0 / 3.0, 2.0 / 3.0), (1.0 / 3.0, 2.0 / 3.0),
                ]
                let zoom = zooms[index % zooms.count]
                let anchor = anchors[index % anchors.count]
                if index.isMultiple(of: 2) {
                    return KenBurnsMove(
                        startZoom: 1, endZoom: zoom,
                        startAnchorX: 0.5, startAnchorY: 0.5,
                        endAnchorX: anchor.x, endAnchorY: anchor.y)
                }
                return KenBurnsMove(
                    startZoom: zoom, endZoom: 1,
                    startAnchorX: anchor.x, startAnchorY: anchor.y,
                    endAnchorX: 0.5, endAnchorY: 0.5)
            }
        }

        var blendID: UUID
        /// Trim points as fractions of the clip's own duration. 0…1 with
        /// `inPoint < outPoint`; the untouched clip is 0…1 exactly.
        var inPoint: Double
        var outPoint: Double
        /// Collection-local crop overrides, keyed by canvas-ratio raw value.
        /// Absent for a ratio means "use the clip's default crop" (stored on
        /// the `BlendProject`), which itself falls back to centred.
        var crops: [String: Double]
        /// Assigned when the collection's Ken Burns turns on (and to clips
        /// added while it is); absent on entries that predate the feature.
        var kenBurns: KenBurnsMove?

        init(blendID: UUID, inPoint: Double = 0, outPoint: Double = 1,
             crops: [String: Double] = [:], kenBurns: KenBurnsMove? = nil) {
            self.blendID = blendID
            self.inPoint = inPoint
            self.outPoint = outPoint
            self.crops = crops
            self.kenBurns = kenBurns
        }

        var id: UUID { blendID }

        var isTrimmed: Bool { inPoint > 0.0005 || outPoint < 0.9995 }

        var keptFraction: Double { max(0, outPoint - inPoint) }
    }

    /// The kept render. Re-exporting is instant while `recipe` still matches
    /// the collection's current recipe and the file is on disk.
    struct ExportRecord: Codable, Equatable {
        var fileName: String
        var exportedAt: Date
        var recipe: String
    }

    /// The Ken Burns export mode: gentle zoom/pan on every clip, with the
    /// pacing and joining choices that make a one-tap export cut well.
    /// Stored once configured so turning the mode off and on again keeps the
    /// user's answers; `enabled` is the toggle.
    struct KenBurnsSettings: Codable, Equatable {
        var enabled: Bool
        /// Every clip occupies the same length in the export.
        var consistentDurations: Bool
        /// That length, whole seconds. The UI and the export clamp it to the
        /// shortest clip on the timeline (a clamp is never a preference —
        /// the stored value survives the timeline changing under it).
        var clipSeconds: Int
        /// With consistent durations: longer clips speed up to fit. Off means
        /// each clip contributes a `clipSeconds` window from its in point.
        var autoAdjustSpeed: Bool
        /// Crossfade between clips instead of a straight cut.
        var fadeTransition: Bool
    }

    /// The crossfade length `fadeTransition` uses. One place on purpose —
    /// this number is expected to become adjustable.
    static let fadeSeconds = 0.5

    var id: UUID
    var name: String
    var createdAt: Date
    /// Canvas ratio raw value; nil until the first clip sets it.
    var ratioRaw: String?
    var entries: [Entry]
    var lastExport: ExportRecord?
    /// nil until Ken Burns is first turned on.
    var kenBurns: KenBurnsSettings?

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), ratioRaw: String? = nil,
         entries: [Entry] = [], lastExport: ExportRecord? = nil, kenBurns: KenBurnsSettings? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.ratioRaw = ratioRaw
        self.entries = entries
        self.lastExport = lastExport
        self.kenBurns = kenBurns
    }

    var kenBurnsEnabled: Bool { kenBurns?.enabled == true }

    /// Whether each clip's contribution is a fixed window from its in point —
    /// the mode where the timeline's per-clip editor sets start points
    /// instead of free trims.
    var kenBurnsUsesWindows: Bool {
        guard let kenBurns, kenBurns.enabled else { return false }
        return kenBurns.consistentDurations && !kenBurns.autoAdjustSpeed
    }

    /// Every entry that predates Ken Burns (or arrived while it was off)
    /// gets its best-effort move, keyed to its timeline position.
    mutating func assignMissingKenBurnsMoves() {
        for index in entries.indices where entries[index].kenBurns == nil {
            entries[index].kenBurns = Entry.KenBurnsMove.bestEffort(forClipIndex: index)
        }
    }

    var ratio: CanvasRatio? {
        get { ratioRaw.flatMap(CanvasRatio.init(rawValue:)) }
        set { ratioRaw = newValue?.rawValue }
    }

    func entry(for blendID: UUID) -> Entry? {
        entries.first { $0.blendID == blendID }
    }

    var clipCountLabel: String {
        entries.count == 1 ? "1 clip" : "\(entries.count) clips"
    }
}

// MARK: - Timeline math

enum CollectionMath {
    /// "0:09" — timeline totals read as timecode, unlike per-clip lengths
    /// which use the app-wide `SpeedMath.clipLengthCompact` ("2.4s").
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// Largest `canvas`-shaped rect that fits inside a clip of `clipSize`,
    /// plus which axis is free to pan. This is the crop model: the kept rect
    /// slides along the free axis by an offset fraction 0…1 (0.5 = centred)
    /// and scales to fill the export canvas.
    static func cropBox(clipSize: CGSize, canvas: CanvasRatio, offset: Double)
        -> (rect: CGRect, axis: Axis)? {
        guard clipSize.width > 0, clipSize.height > 0 else { return nil }
        let a = canvas.aspect
        var bw = min(clipSize.width, clipSize.height * a)
        var bh = bw / a
        if bh > clipSize.height {
            bh = clipSize.height
            bw = bh * a
        }
        let axis: Axis = (clipSize.width - bw) > (clipSize.height - bh) ? .horizontal : .vertical
        let clamped = min(1, max(0, offset))
        let x = axis == .horizontal ? clamped * (clipSize.width - bw) : (clipSize.width - bw) / 2
        let y = axis == .vertical ? clamped * (clipSize.height - bh) : (clipSize.height - bh) / 2
        return (CGRect(x: x, y: y, width: bw, height: bh), axis)
    }

    enum Axis { case horizontal, vertical }

    /// One Ken Burns framing: the canvas-shaped window `zoom` deep into the
    /// clip's crop box, positioned by the anchors across the slack the zoom
    /// opens up. Zoom 1 is the crop box itself, so a move that ends at 1
    /// always lands exactly on the framing the user's crop chose.
    static func kenBurnsRect(base: CGRect, zoom: Double, anchorX: Double, anchorY: Double) -> CGRect {
        let z = max(1, zoom)
        let width = base.width / z
        let height = base.height / z
        let x = base.minX + (base.width - width) * min(1, max(0, anchorX))
        let y = base.minY + (base.height - height) * min(1, max(0, anchorY))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Aspect-fit `aspect` into a bounding box.
    static func fit(aspect: Double, maxWidth: Double, maxHeight: Double) -> CGSize {
        guard aspect > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
        var w = maxWidth
        var h = w / aspect
        if h > maxHeight {
            h = maxHeight
            w = h * aspect
        }
        return CGSize(width: w.rounded(), height: h.rounded())
    }
}
