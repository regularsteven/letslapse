import CoreGraphics
import Foundation

// Reading what Lightroom wrote.
//
// A raw file exported from Lightroom carries its edits in an `.xmp` sidecar,
// in Adobe's Camera Raw namespace (`crs:`). This file turns that document into
// values; `LightroomImport` turns those values into a LetsLapse grade.
//
// The two halves are separate on purpose. Parsing is a fact — the sidecar says
// Exposure2012 is +0.29 — and it either succeeds or it doesn't. Mapping is a
// JUDGEMENT: our Exposure is in the same EV units so it transfers, our Clarity
// is a different curve so it approximates, and we have no tone curve at all so
// that part is lost. Keeping them apart means the losses can be reported
// rather than quietly absorbed, which is what `unsupported` is for.
//
// Nothing here renders. Nothing here decides whether the result LOOKS like
// Lightroom — that question needs a reference render and a measurement, and
// this type is what makes the experiment possible.

/// One Lightroom `.xmp` sidecar, parsed.
public struct LightroomSidecar: Equatable, Sendable {

    /// Every `crs:` scalar on the root description, by attribute name without
    /// the prefix — "Exposure2012", "Highlights2012", "CameraProfile"…
    ///
    /// Kept as strings because that is what the file holds and because the
    /// mapping, not the parse, is what decides a field's units. Typed reads go
    /// through `double(_:)` / `int(_:)` / `bool(_:)`.
    public var settings: [String: String] = [:]

    /// The image's own tone curve, as (input, output) pairs on 0…255.
    /// Empty for the default linear curve.
    public var toneCurve: [ToneCurvePoint] = []

    /// The curve baked into the named PROFILE LOOK ("Adobe Color" and its
    /// siblings), which is a different thing from the image's own curve: it is
    /// part of what the profile means, and a file whose own curve is Linear
    /// still renders through this one.
    public var lookToneCurve: [ToneCurvePoint] = []

    /// The local corrections, in Lightroom's own order.
    public var corrections: [Correction] = []

    /// The encoded bitmaps behind the AI masks, keyed by the `MaskDigest` that
    /// names them. Adobe writes them as `crs:Table_<digest>` — a single
    /// attribute that is almost the whole file (229 KB of this 242 KB one).
    ///
    /// The encoding is Adobe's and undocumented; nothing here decodes it. It
    /// is carried so that a caller can see the mask EXISTS and how big it is,
    /// and so a future decoder has the payload without a re-parse.
    public var maskTables: [String: String] = [:]

    /// What was recognised but cannot be represented — one human-readable line
    /// each. The honest half of an import: a file that says "Dehaze +40" and
    /// an importer with no dehaze must say so.
    public var unsupported: [String] = []

    /// The EXIF orientation the picture is displayed through — `tiff:
    /// Orientation` on the root description; 1 when absent. It matters
    /// because **Lightroom's geometry is written in the SENSOR frame**: the
    /// crop rect and every gradient mask's coordinates describe the frame as
    /// the sensor recorded it, and a portrait shot off a landscape sensor is
    /// turned only on display. Measured 2026-09-07 on `_WEB5253`
    /// (orientation 8): its linear gradient correlates with Lightroom's own
    /// render read through the sensor frame (+0.34) and not at all read
    /// through the display frame (+0.03). `LightroomImport` turns the masks.
    public var orientation: Int = 1

    public init() {}

    // MARK: Typed reads

    public func double(_ key: String) -> Double? {
        settings[key].flatMap { Double($0.replacingOccurrences(of: "+", with: "")) }
    }

    public func int(_ key: String) -> Int? { double(key).map { Int($0.rounded()) } }

    public func bool(_ key: String) -> Bool? {
        guard let raw = settings[key]?.lowercased() else { return nil }
        if raw == "true" { return true }
        if raw == "false" { return false }
        return nil
    }

    public var rawFileName: String? { settings["RawFileName"] }
    public var cameraProfile: String? { settings["CameraProfile"] }
    public var processVersion: String? { settings["ProcessVersion"] }
    /// "As Shot", "Custom", or an illuminant's name.
    public var whiteBalance: String? { settings["WhiteBalance"] }
    /// True when the file says a crop is in force — `HasCrop`, or a non-zero
    /// straightening angle, either of which changes the frame's geometry.
    public var hasCrop: Bool {
        bool("HasCrop") == true || (double("CropAngle") ?? 0) != 0
    }

    /// A point on a Lightroom tone curve. Both axes are 0…255 in the file.
    public struct ToneCurvePoint: Equatable, Sendable {
        public var input: Double
        public var output: Double
        public init(input: Double, output: Double) {
            self.input = input
            self.output = output
        }
        /// True for a point that sits on the diagonal — a curve made only of
        /// these is the identity, whatever its point count.
        public var isNeutral: Bool { abs(input - output) < 0.5 }
    }

    /// One local correction: a set of adjustments and the masks that select
    /// where they apply. Lightroom allows several masks per correction,
    /// combined by their blend modes; we carry them all and let the mapper
    /// decide what it can honour.
    public struct Correction: Equatable, Sendable {
        public var name: String = ""
        public var isActive: Bool = true
        /// The correction's overall strength, 0…1.
        public var amount: Double = 1
        /// The `Local*` values, by attribute name without the prefix.
        public var locals: [String: String] = [:]
        public var masks: [Mask] = []

        public init() {}

        public func double(_ key: String) -> Double? {
            locals[key].flatMap { Double($0.replacingOccurrences(of: "+", with: "")) }
        }

        /// True when every local value is zero — a correction that would move
        /// no pixel even where its mask selects.
        public var isNeutral: Bool {
            locals.values.allSatisfy { (Double($0.replacingOccurrences(of: "+", with: "")) ?? 0) == 0 }
        }
    }

    /// One mask inside a correction. The `kind` is Adobe's own `crs:What`
    /// with the "Mask/" prefix taken off, so an unfamiliar one survives the
    /// parse as data rather than being dropped.
    public struct Mask: Equatable, Sendable {
        public var kind: String = ""
        public var name: String = ""
        public var isActive: Bool = true
        /// Adobe's own invert flag.
        public var isInverted: Bool = false
        /// The mask's contribution, 0…1.
        public var value: Double = 1
        /// Everything the element carried, for the kinds this build does not
        /// model in full.
        public var attributes: [String: String] = [:]

        public init() {}

        public func double(_ key: String) -> Double? {
            attributes[key].flatMap { Double($0.replacingOccurrences(of: "+", with: "")) }
        }

        public func bool(_ key: String) -> Bool? {
            guard let raw = attributes[key]?.lowercased() else { return nil }
            return raw == "true" ? true : (raw == "false" ? false : nil)
        }

        /// The digest naming this mask's encoded bitmap, for the AI kinds.
        public var digest: String? { attributes["MaskDigest"] }

        public var isRadialGradient: Bool { kind == "CircularGradient" }
        public var isLinearGradient: Bool { kind == "Gradient" }
        /// An AI mask — sky, subject, background, object. Its shape is a
        /// bitmap, not parameters.
        public var isImage: Bool { kind == "Image" }
    }

    // MARK: - Parsing

    public enum ParseError: Error, LocalizedError {
        case unreadable
        case notALightroomSidecar

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "That file could not be read as XMP."
            case .notALightroomSidecar:
                return "That XMP carries no Camera Raw settings — it is not a Lightroom sidecar."
            }
        }
    }

    public static func read(contentsOf url: URL) throws -> LightroomSidecar {
        guard let data = try? Data(contentsOf: url) else { throw ParseError.unreadable }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> LightroomSidecar {
        let parser = XMLParser(data: data)
        let delegate = Builder()
        parser.delegate = delegate
        guard parser.parse() else { throw ParseError.unreadable }
        guard !delegate.sidecar.settings.isEmpty else { throw ParseError.notALightroomSidecar }
        var sidecar = delegate.sidecar
        sidecar.noteUnsupported()
        return sidecar
    }

    /// The sidecar beside a raw file — `<name>.xmp`, and the `<name>.<ext>.xmp`
    /// spelling some tools write. Returns nil when there is none, which is the
    /// normal case for a file that has never been through Lightroom.
    public static func sidecarURL(forRawFile url: URL) -> URL? {
        let manager = FileManager.default
        let candidates = [
            url.deletingPathExtension().appendingPathExtension("xmp"),
            url.deletingPathExtension().appendingPathExtension("XMP"),
            url.appendingPathExtension("xmp"),
        ]
        return candidates.first { manager.fileExists(atPath: $0.path) }
    }

    /// Fills `unsupported` from what was parsed. Runs once, at the end of a
    /// parse, so the list is a property of the FILE rather than of whoever
    /// asks — and so a caller cannot forget to compute it.
    private mutating func noteUnsupported() {
        // Non-zero settings this build has no control for. The threshold is
        // exact-zero: Lightroom writes "0" for anything untouched, so a
        // non-zero here means somebody moved it.
        let missing: [(key: String, label: String)] = [
            ("GrainAmount", "Grain"),
            // The post-crop vignette is carried since 2026-09-12 (amount and
            // midpoint, through `LightroomImport`), so it is no longer here.
            ("ParametricShadows", "Parametric curve · shadows"),
            ("ParametricDarks", "Parametric curve · darks"),
            ("ParametricLights", "Parametric curve · lights"),
            ("ParametricHighlights", "Parametric curve · highlights"),
            ("SplitToningShadowSaturation", "Split toning · shadows"),
            ("SplitToningHighlightSaturation", "Split toning · highlights"),
            ("ColorGradeGlobalSat", "Colour grading"),
            ("LensProfileEnable", "Lens profile correction"),
            ("PerspectiveVertical", "Perspective · vertical"),
            ("PerspectiveHorizontal", "Perspective · horizontal"),
            ("DefringePurpleAmount", "Defringe · purple"),
            ("DefringeGreenAmount", "Defringe · green"),
        ]
        for entry in missing where (double(entry.key) ?? 0) != 0 {
            unsupported.append("\(entry.label) — no equivalent control")
        }
        if !toneCurve.isEmpty, toneCurve.contains(where: { !$0.isNeutral }) {
            unsupported.append("Tone curve — no equivalent control")
        }
        if !lookToneCurve.isEmpty, lookToneCurve.contains(where: { !$0.isNeutral }) {
            unsupported.append(
                "Profile look curve (\(settings["LookName"] ?? "profile")) — no equivalent control")
        }
        if bool("HasCrop") == true {
            // The angle IS carried (as the level); the rect is what is lost.
            unsupported.append("Crop rect — not carried by an import (the straighten angle is)")
        }
        for correction in corrections where correction.isActive {
            for mask in correction.masks where mask.isActive {
                if mask.isImage {
                    // A sky is substituted rather than lost — `LightroomImport`
                    // routes it onto this app's own segmentation — so it is
                    // reported there, as something CARRIED with a caveat,
                    // rather than here as a loss.
                    guard !LightroomImport.isSky(mask) else { continue }
                    let size = mask.digest.flatMap { maskTables[$0]?.count }
                    unsupported.append(
                        "Mask \u{201C}\(mask.name)\u{201D} is an AI mask; its bitmap is in the sidecar"
                        + (size.map { " (\($0 / 1024) KB, Adobe's own encoding)" } ?? "")
                        + " and is not decoded")
                } else if !mask.isRadialGradient && !mask.isLinearGradient {
                    unsupported.append(
                        "Mask \u{201C}\(mask.name)\u{201D} is a \(mask.kind) mask — not modelled")
                }
            }
        }
    }

    /// The XMLParser delegate. An element-path stack rather than a pile of
    /// booleans: the same `rdf:Description` element means the image's settings
    /// at the root, a profile look two levels down, and one correction inside
    /// the mask list — only its ancestry tells them apart.
    private final class Builder: NSObject, XMLParserDelegate {
        var sidecar = LightroomSidecar()
        private var path: [String] = []
        /// The `rdf:li` text being accumulated (tone-curve points).
        private var text = ""

        private var correction: Correction?
        private var inCorrectionMasks = false

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes: [String: String]) {
            let name = qName ?? element
            path.append(name)
            text = ""

            switch name {
            case "rdf:Description":
                describe(attributes)
            case "rdf:li":
                // A mask is an `rdf:li` with its attributes on the element
                // itself; a correction is an `rdf:li` wrapping a Description.
                if inCorrectionMasks, attributes["crs:What"] != nil {
                    correction?.masks.append(mask(from: attributes))
                }
            case "crs:CorrectionMasks":
                inCorrectionMasks = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let name = qName ?? element
            defer {
                if !path.isEmpty { path.removeLast() }
                text = ""
            }
            switch name {
            case "crs:CorrectionMasks":
                inCorrectionMasks = false
            case "rdf:li":
                // A tone-curve point: "22, 16".
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.contains(","), let curve = enclosingCurve() else { break }
                let parts = trimmed.split(separator: ",")
                guard parts.count == 2,
                      let input = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                      let output = Double(parts[1].trimmingCharacters(in: .whitespaces))
                else { break }
                let point = ToneCurvePoint(input: input, output: output)
                if curve == .image {
                    sidecar.toneCurve.append(point)
                } else {
                    sidecar.lookToneCurve.append(point)
                }
            case "rdf:Description":
                // A correction closes when its own Description does — and only
                // then, since its masks are Descriptions' siblings, not theirs.
                if let correction, !inCorrectionMasks,
                   path.filter({ $0 == "crs:MaskGroupBasedCorrections" }).isEmpty == false {
                    sidecar.corrections.append(correction)
                    self.correction = nil
                }
            default:
                break
            }
        }

        private enum Curve { case image, look }

        /// Which tone curve the `rdf:li` currently closing belongs to. Only
        /// the RGB master is read: Lightroom writes the three channel curves
        /// beside it and this build has no channel curves to put them in.
        private func enclosingCurve() -> Curve? {
            guard path.contains(where: { $0 == "crs:ToneCurvePV2012" }) else { return nil }
            return path.contains("crs:Look") ? .look : .image
        }

        /// A `rdf:Description`'s attributes, filed by where the element sits.
        private func describe(_ attributes: [String: String]) {
            let insideCorrections = path.contains("crs:MaskGroupBasedCorrections")
            let insideLook = path.contains("crs:Look")

            if insideCorrections {
                var built = Correction()
                built.name = attributes["crs:CorrectionName"] ?? ""
                built.isActive = attributes["crs:CorrectionActive"]?.lowercased() != "false"
                built.amount = attributes["crs:CorrectionAmount"].flatMap(Double.init) ?? 1
                for (key, value) in attributes where key.hasPrefix("crs:Local") {
                    built.locals[String(key.dropFirst("crs:Local".count))] = value
                }
                correction = built
                return
            }

            if !insideLook, let raw = attributes["tiff:Orientation"], let value = Int(raw) {
                sidecar.orientation = value
            }
            for (key, value) in attributes where key.hasPrefix("crs:") {
                let name = String(key.dropFirst(4))
                if insideLook {
                    // The look's own name and profile, kept apart from the
                    // image's settings so neither shadows the other.
                    if name == "Name" { sidecar.settings["LookName"] = value }
                    continue
                }
                // The AI masks' payloads: one attribute each, named for the
                // digest of the mask that uses it.
                if name.hasPrefix("Table_") {
                    sidecar.maskTables[String(name.dropFirst("Table_".count))] = value
                } else {
                    sidecar.settings[name] = value
                }
            }
        }

        private func mask(from attributes: [String: String]) -> Mask {
            var built = Mask()
            built.kind = (attributes["crs:What"] ?? "")
                .replacingOccurrences(of: "Mask/", with: "")
            built.name = attributes["crs:MaskName"] ?? ""
            built.isActive = attributes["crs:MaskActive"]?.lowercased() != "false"
            built.isInverted = attributes["crs:MaskInverted"]?.lowercased() == "true"
            built.value = attributes["crs:MaskValue"].flatMap(Double.init) ?? 1
            for (key, value) in attributes where key.hasPrefix("crs:") {
                built.attributes[String(key.dropFirst(4))] = value
            }
            return built
        }
    }
}

// MARK: - XMP embedded in the raw file

extension LightroomSidecar {

    /// The XMP a raw file carries INSIDE it, rather than beside it.
    ///
    /// Lightroom writes a `.xmp` next to a proprietary raw (ARW, CR3, NEF)
    /// because it will not rewrite the manufacturer's file. A DNG is Adobe's
    /// own container, so the settings go in the file — and anything that has
    /// been through Enhance / Denoise comes back as a DNG with no sidecar at
    /// all. Reading only sidecars silently skips those, which on the first
    /// mixed corpus was two files in five.
    ///
    /// Parsed out of the TIFF directory (DNG is TIFF) at tag 700, the XMP
    /// packet, rather than by scanning the file for `<x:xmpmeta`. Scanning an
    /// 80 MB DNG works but reads the whole thing to find 8 KB, and would
    /// happily find a packet inside an embedded preview instead of the real
    /// one.
    public static let xmpTag: UInt16 = 700

    public static func embeddedXMP(in url: URL) throws -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 8), header.count == 8 else { return nil }

        let little: Bool
        switch (header[0], header[1]) {
        case (0x49, 0x49): little = true          // "II"
        case (0x4D, 0x4D): little = false         // "MM"
        default: return nil                        // not TIFF, so not a DNG
        }
        func u16(_ d: Data, _ i: Int) -> UInt16 {
            let a = UInt16(d[d.startIndex + i]), b = UInt16(d[d.startIndex + i + 1])
            return little ? (b << 8 | a) : (a << 8 | b)
        }
        func u32(_ d: Data, _ i: Int) -> UInt32 {
            let bytes = (0..<4).map { UInt32(d[d.startIndex + i + $0]) }
            return little
                ? (bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0])
                : (bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3])
        }
        guard u16(header, 2) == 42 else { return nil }

        // IFD0 only. A DNG puts its XMP there; the SubIFDs hold the image
        // data and previews, which is exactly where a byte scan goes wrong.
        try handle.seek(toOffset: UInt64(u32(header, 4)))
        guard let countData = try handle.read(upToCount: 2), countData.count == 2 else { return nil }
        let entries = Int(u16(countData, 0))
        guard entries > 0, entries < 4096 else { return nil }
        guard let table = try handle.read(upToCount: entries * 12),
              table.count == entries * 12 else { return nil }

        for index in 0..<entries {
            let base = index * 12
            guard u16(table, base) == xmpTag else { continue }
            let count = Int(u32(table, base + 4))
            guard count > 0, count < 64 * 1024 * 1024 else { return nil }
            // A value of four bytes or fewer is stored inline; XMP never is,
            // but the check is what makes this a TIFF reader rather than a
            // guess that happens to work.
            if count <= 4 {
                return table.subdata(in: (base + 8)..<(base + 8 + count))
            }
            try handle.seek(toOffset: UInt64(u32(table, base + 8)))
            return try handle.read(upToCount: count)
        }
        return nil
    }

    /// The settings for a raw file, wherever they live: the sidecar beside it
    /// if there is one, otherwise the XMP inside it.
    ///
    /// Sidecar first, deliberately. When both exist the sidecar is the newer
    /// of the two — Lightroom writes it on every edit and only rewrites a
    /// DNG's own XMP on demand — so preferring the file would quietly render
    /// an older version of somebody's work.
    public static func read(forRawFile url: URL) throws -> LightroomSidecar? {
        if let sidecar = sidecarURL(forRawFile: url) {
            return try read(contentsOf: sidecar)
        }
        guard let data = try embeddedXMP(in: url) else { return nil }
        return try parse(data)
    }

    /// Where a raw file's settings came from — for a report that has to be
    /// honest about which of two possible sources it read.
    public enum Source: Equatable, Sendable {
        case sidecar(URL)
        case embedded
        case none

        public var describedBriefly: String {
            switch self {
            case .sidecar(let url): return "sidecar \(url.lastPathComponent)"
            case .embedded: return "embedded in the raw"
            case .none: return "no Lightroom settings"
            }
        }
    }

    public static func source(forRawFile url: URL) -> Source {
        if let sidecar = sidecarURL(forRawFile: url) { return .sidecar(sidecar) }
        if let data = try? embeddedXMP(in: url), data != nil { return .embedded }
        return .none
    }
}
