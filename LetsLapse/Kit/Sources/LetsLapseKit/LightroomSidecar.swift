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
            ("Dehaze", "Dehaze"),
            ("GrainAmount", "Grain"),
            ("PostCropVignetteAmount", "Post-crop vignette"),
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
        // The HSL panel, all eight hues across three axes.
        let hues = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
        for axis in ["HueAdjustment", "SaturationAdjustment", "LuminanceAdjustment"] {
            if hues.contains(where: { (double(axis + $0) ?? 0) != 0 }) {
                unsupported.append("HSL · \(axis.replacingOccurrences(of: "Adjustment", with: "")) — no equivalent control")
            }
        }
        if !toneCurve.isEmpty, toneCurve.contains(where: { !$0.isNeutral }) {
            unsupported.append("Tone curve — no equivalent control")
        }
        if !lookToneCurve.isEmpty, lookToneCurve.contains(where: { !$0.isNeutral }) {
            unsupported.append(
                "Profile look curve (\(settings["LookName"] ?? "profile")) — no equivalent control")
        }
        if hasCrop {
            unsupported.append("Crop / straighten — not carried by an import")
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
