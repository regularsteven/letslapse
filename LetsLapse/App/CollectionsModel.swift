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
        /// One framing of a Ken Burns move: a canvas-shaped window over the
        /// clip. Zoom 1 is the largest such window the clip offers; larger
        /// zooms tighten it. The centre is in unit clip coordinates, so a
        /// framing can sit anywhere the clip has room — not only inside the
        /// current crop box — and survives resolution and ratio changes.
        struct KenBurnsFraming: Codable, Equatable {
            var zoom: Double
            var centerX: Double
            var centerY: Double
        }

        /// One clip's Ken Burns move: the start and end framings the export
        /// animates between. `isCustom` flips the first time a human edits a
        /// framing — it gates the row badge and the Reset affordance, and a
        /// custom move is never overwritten by re-dealing defaults.
        struct KenBurnsMove: Codable, Equatable {
            var start: KenBurnsFraming
            var end: KenBurnsFraming
            var isCustom: Bool
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

        /// A move that doesn't decode (a dev build's earlier shape) is
        /// dropped, never fatal — the library must always load, and a
        /// missing move just gets re-dealt its defaults. Encoding stays
        /// synthesized.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            blendID = try container.decode(UUID.self, forKey: .blendID)
            inPoint = try container.decode(Double.self, forKey: .inPoint)
            outPoint = try container.decode(Double.self, forKey: .outPoint)
            crops = try container.decode([String: Double].self, forKey: .crops)
            kenBurns = (try? container.decodeIfPresent(KenBurnsMove.self, forKey: .kenBurns)) ?? nil
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
    /// Stored once configured so switching modes keeps the user's answers;
    /// `enabled` is the master switch, `custom` says whether the live values
    /// were applied from the Custom drawer or are the dealt Auto defaults.
    struct KenBurnsSettings: Codable, Equatable {
        /// The pacing/join answers on their own — the shape `lastCustom`
        /// parks while Auto plays the defaults.
        struct CustomChoices: Codable, Equatable {
            var consistentDurations: Bool
            var clipSeconds: Int
            var autoAdjustSpeed: Bool
            var fadeTransition: Bool
        }

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
        /// The live values were applied from the Custom drawer. False means
        /// Auto — the dealt best-effort defaults are in charge.
        var custom: Bool
        /// The last applied Custom values, parked while Auto plays the
        /// defaults so switching back restores them without a confirmation.
        /// nil while Custom is live (the fields above ARE the custom values)
        /// and before Custom is first applied. Never part of the export
        /// recipe — parking must not invalidate a kept render.
        var lastCustom: CustomChoices?

        init(enabled: Bool, consistentDurations: Bool, clipSeconds: Int,
             autoAdjustSpeed: Bool, fadeTransition: Bool,
             custom: Bool = false, lastCustom: CustomChoices? = nil) {
            self.enabled = enabled
            self.consistentDurations = consistentDurations
            self.clipSeconds = clipSeconds
            self.autoAdjustSpeed = autoAdjustSpeed
            self.fadeTransition = fadeTransition
            self.custom = custom
            self.lastCustom = lastCustom
        }

        /// Settings stored before the tri-state existed decode as Auto —
        /// their live values are untouched, so nothing plays differently
        /// until a mode is actually tapped. Encoding stays synthesized.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decode(Bool.self, forKey: .enabled)
            consistentDurations = try container.decode(Bool.self, forKey: .consistentDurations)
            clipSeconds = try container.decode(Int.self, forKey: .clipSeconds)
            autoAdjustSpeed = try container.decode(Bool.self, forKey: .autoAdjustSpeed)
            fadeTransition = try container.decode(Bool.self, forKey: .fadeTransition)
            custom = (try? container.decodeIfPresent(Bool.self, forKey: .custom)) ?? false
            lastCustom = (try? container.decodeIfPresent(CustomChoices.self, forKey: .lastCustom)) ?? nil
        }
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
    /// The tombstone (Phase 1 W9) — see `AppModel.CaptureProject.deletedAt`.
    /// The render folder moves to `Projects/.trash/collections/<id>/`.
    var deletedAt: Date?
    var deletedBy: UUID?
    /// W8 — see `AppModel.CaptureProject.revision` / `.modifiedBy`; stamped
    /// by `AppModel.mutateCollection`.
    var revision: Int?
    var modifiedAt: Date?
    var modifiedBy: UUID?

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

    /// The tri-state the header control draws: Off, Auto (dealt defaults),
    /// or Custom (drawer-applied values).
    var kenBurnsMode: KenBurnsMode {
        guard let kenBurns, kenBurns.enabled else { return .off }
        return kenBurns.custom ? .custom : .auto
    }

    /// Whether each clip's contribution is a fixed window from its in point —
    /// the mode where the timeline's per-clip editor sets start points
    /// instead of free trims.
    var kenBurnsUsesWindows: Bool {
        guard let kenBurns, kenBurns.enabled else { return false }
        return kenBurns.consistentDurations && !kenBurns.autoAdjustSpeed
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

/// Which framing of a clip's Ken Burns move is being addressed.
enum KenBurnsMoveEnd: String, CaseIterable {
    case start
    case end
}

/// The Ken Burns tri-state: off, the dealt Auto defaults, or drawer-applied
/// Custom values. Auto ↔ Custom is non-destructive — Custom's answers are
/// parked in `lastCustom` and restored, so no mode switch needs a
/// confirmation.
enum KenBurnsMode: Equatable {
    case off
    case auto
    case custom
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

    /// The deepest a Ken Burns framing can pinch.
    static let kenBurnsMaxZoom = 4.0

    /// The largest canvas-shaped window the clip offers, as fractions of the
    /// clip (unit clip coordinates), positioned along its free axis by the
    /// crop offset. This is what zoom 1 means, and where dealt defaults sit.
    static func kenBurnsUnitBase(clipAspect: Double, canvasAspect: Double, offset: Double) -> CGRect {
        guard clipAspect > 0, canvasAspect > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let width = min(1, canvasAspect / clipAspect)
        let height = min(1, clipAspect / canvasAspect)
        let clamped = min(1, max(0, offset))
        return CGRect(
            x: width < 1 ? clamped * (1 - width) : 0,
            y: height < 1 ? clamped * (1 - height) : 0,
            width: width, height: height)
    }

    /// A framing's window in unit clip coordinates: the base window tightened
    /// by the zoom, centred where the framing says — pulled back inside the
    /// clip when the centre would push it over an edge.
    static func kenBurnsUnitRect(base: CGRect, framing: LapseCollection.Entry.KenBurnsFraming) -> CGRect {
        let clamped = clampedKenBurnsFraming(base: base, framing: framing)
        let width = base.width / clamped.zoom
        let height = base.height / clamped.zoom
        return CGRect(
            x: clamped.centerX - width / 2, y: clamped.centerY - height / 2,
            width: width, height: height)
    }

    /// The invariants every framing write and read goes through: zoom within
    /// 1…max, centre such that the window stays inside the clip.
    static func clampedKenBurnsFraming(
        base: CGRect, framing: LapseCollection.Entry.KenBurnsFraming
    ) -> LapseCollection.Entry.KenBurnsFraming {
        let zoom = min(kenBurnsMaxZoom, max(1, framing.zoom))
        let width = base.width / zoom
        let height = base.height / zoom
        return LapseCollection.Entry.KenBurnsFraming(
            zoom: zoom,
            centerX: min(1 - width / 2, max(width / 2, framing.centerX)),
            centerY: min(1 - height / 2, max(height / 2, framing.centerY)))
    }

    /// The best-effort move a clip is dealt when Ken Burns turns on — the
    /// defaults every clip starts from. Direction alternates (settle in,
    /// then reveal out), zoom amounts and the zoomed framing's position
    /// cycle so runs of clips don't all move the same way; the zoomed
    /// framing stays inside the crop box the base describes, so defaults
    /// respect the crop the user positioned. Deterministic per timeline
    /// position.
    static func kenBurnsDefaultMove(forClipIndex index: Int, base: CGRect) -> LapseCollection.Entry.KenBurnsMove {
        let zooms: [Double] = [1.22, 1.15, 1.3, 1.18]
        let anchors: [(x: Double, y: Double)] = [
            (0.5, 0.5), (1.0 / 3.0, 1.0 / 3.0), (2.0 / 3.0, 1.0 / 3.0),
            (2.0 / 3.0, 2.0 / 3.0), (1.0 / 3.0, 2.0 / 3.0),
        ]
        let zoom = zooms[index % zooms.count]
        let anchor = anchors[index % anchors.count]

        let wide = LapseCollection.Entry.KenBurnsFraming(
            zoom: 1, centerX: base.midX, centerY: base.midY)
        // The zoomed window, anchored across the slack it opens inside base.
        let width = base.width / zoom
        let height = base.height / zoom
        let tight = clampedKenBurnsFraming(base: base, framing: LapseCollection.Entry.KenBurnsFraming(
            zoom: zoom,
            centerX: base.minX + anchor.x * (base.width - width) + width / 2,
            centerY: base.minY + anchor.y * (base.height - height) + height / 2))

        return index.isMultiple(of: 2)
            ? LapseCollection.Entry.KenBurnsMove(start: wide, end: tight, isCustom: false)
            : LapseCollection.Entry.KenBurnsMove(start: tight, end: wide, isCustom: false)
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
