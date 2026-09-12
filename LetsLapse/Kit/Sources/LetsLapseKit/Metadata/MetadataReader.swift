import Foundation
import ImageIO

/// Reads an asset's `imported` metadata layer — from the file's own header
/// (Exif, TIFF, IPTC-IIM through ImageIO), its embedded XMP packet, and the
/// `.xmp` sidecar beside it — through `MetadataFieldMap`, one table for
/// every spelling.
///
/// Precedence, per field: **sidecar over embedded XMP over IIM/Exif.**
/// Lightroom never rewrites a proprietary raw, so the sidecar is the newer
/// record (`_WEX3518.ARW` says rating 0; its sidecar says 5), and XMP is the
/// living copy of what IIM carried first. The file is only ever read.
public enum MetadataReader {

    public struct Result: Equatable, Sendable {
        public var metadata: AssetMetadata
        /// `file` when only the file contributed; `sidecar` when a `.xmp`
        /// beside it contributed (and won).
        public var source: String
        public var sidecarURL: URL?
    }

    public static let sourceFile = "file"
    public static let sourceSidecar = "sidecar"
    public static let sourceCatalogue = "catalogue"

    /// The whole record for the file at `url`. `sidecar` names the `.xmp` to
    /// lay on top; nil looks beside the file (`<name>.xmp`, `<name>.<ext>.xmp`).
    public static func read(fileAt url: URL, sidecar: URL? = nil) -> Result {
        var metadata = AssetMetadata()
        if let properties = imageIOProperties(at: url) {
            metadata = self.metadata(fromImageIOProperties: properties)
        }
        if let packet = embeddedPacket(at: url) {
            metadata = AssetMetadata.resolving(self.metadata(fromXMP: packet), over: metadata)
        }
        var source = sourceFile
        let sidecarURL = sidecar ?? LightroomSidecar.sidecarURL(forRawFile: url)
        if let sidecarURL, let packet = try? XMPPacket.read(contentsOf: sidecarURL) {
            let fromSidecar = self.metadata(fromXMP: packet)
            if !fromSidecar.isEmpty {
                metadata = AssetMetadata.resolving(fromSidecar, over: metadata)
                source = sourceSidecar
            }
        }
        metadata.normalize()
        return Result(metadata: metadata, source: source, sidecarURL: sidecarURL)
    }

    // MARK: - Sources

    /// The properties of the file's PRIMARY image. On iOS a DNG's index 0 is
    /// its embedded preview (256 × 171 for `_WEX3518-Rendered.dng`, measured
    /// 2026-09-13 on the simulator; the Mac decodes the raw at index 0 and
    /// says 4608 × 3072), so for a raw every index is read and the largest
    /// picture's properties are the file's. Header reads only.
    public static func imageIOProperties(at url: URL) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let count = CGImageSourceGetCount(source)
        guard ImportedStills.isRaw(url), count > 1 else {
            return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        }
        var best: [String: Any]?
        var bestWidth = -1
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] else { continue }
            let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
            if width > bestWidth {
                bestWidth = width
                best = properties
            }
        }
        // The descriptive dictionaries usually ride index 0; a larger index
        // that lacks one borrows it, so choosing the big picture never loses
        // the IPTC block.
        if var chosen = best, let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            for key in ["{IPTC}", "{Exif}", "{TIFF}", "{GPS}", "{ExifAux}"] where chosen[key] == nil {
                if let value = first[key] { chosen[key] = value }
            }
            return chosen
        }
        return best
    }

    /// The packet embedded in a JPEG, HEIC, TIFF or DNG, as ImageIO
    /// re-serialises it (which also folds the Exif IFD into `exif:` — the
    /// same facts under the same table).
    public static func embeddedPacket(at url: URL) -> XMPPacket? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let data = CGImageMetadataCreateXMPData(metadata, nil) as Data?
        else { return nil }
        return try? XMPPacket.parse(data)
    }

    // MARK: - XMP → record

    public static func metadata(fromXMP packet: XMPPacket) -> AssetMetadata {
        var record = AssetMetadata()
        for mapping in MetadataFieldMap.all {
            for path in mapping.xmp {
                if let value = xmpValue(packet, path: path, kind: mapping.kind) {
                    record[mapping.field] = value
                    break
                }
            }
        }
        return record
    }

    static func xmpValue(_ packet: XMPPacket, path: String, kind: MetadataMapping.Kind) -> MetadataValue? {
        switch kind {
        case .text:
            return packet.text(path).map(MetadataValue.text)
        case .list:
            return packet.list(path).map { list in
                .list(list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            }
        case .integer:
            return packet.text(path).flatMap(rational).map { .integer(Int($0.rounded())) }
        case .number:
            return packet.text(path).flatMap(rational).map(MetadataValue.number)
        case .rightsMarked:
            switch packet.text(path)?.lowercased() {
            case "true": return .text(AssetMetadata.RightsStatus.copyrighted.rawValue)
            case "false": return .text(AssetMetadata.RightsStatus.publicDomain.rawValue)
            default: return nil
            }
        case .date:
            guard let text = packet.text(path), AssetMetadata.parseISO8601(text) != nil else { return nil }
            return .text(text)
        case .coordinate:
            return packet.text(path).flatMap(coordinate).map(MetadataValue.number)
        case .altitude:
            guard let value = packet.text(path).flatMap(rational) else { return nil }
            let below = packet.text("exif:GPSAltitudeRef") == "1"
            return .number(below ? -value : value)
        }
    }

    /// "32/10" → 3.2; "3.2" → 3.2; "+0.5" → 0.5.
    static func rational(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")
        if let value = Double(trimmed) { return value }
        let parts = trimmed.split(separator: "/")
        guard parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]),
              denominator != 0 else { return nil }
        return numerator / denominator
    }

    /// XMP's GPS spelling: "50,5.3833333333N" (degrees, decimal minutes) or
    /// "50,5,23N" (degrees, minutes, seconds); a plain signed decimal is
    /// accepted too. Signed: south and west negative.
    static func coordinate(_ text: String) -> Double? {
        var body = text.trimmingCharacters(in: .whitespaces)
        var sign = 1.0
        if let last = body.last, "NSEWnsew".contains(last) {
            if "SWsw".contains(last) { sign = -1 }
            body.removeLast()
        }
        let parts = body.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        switch parts.count {
        case 1: return sign * parts[0]
        case 2: return sign * (parts[0] + parts[1] / 60)
        case 3: return sign * (parts[0] + parts[1] / 60 + parts[2] / 3600)
        default: return nil
        }
    }

    // MARK: - ImageIO properties → record

    public static func metadata(fromImageIOProperties properties: [String: Any]) -> AssetMetadata {
        var record = AssetMetadata()
        for mapping in MetadataFieldMap.all {
            for path in mapping.imageIO {
                if let value = imageIOValue(properties, path: path, kind: mapping.kind) {
                    record[mapping.field] = value
                    break
                }
            }
        }
        return record
    }

    /// `{Exif}.ExposureTime` → the value; `PixelWidth` → the top-level value;
    /// `{DNG}.ActiveArea[3]` → one element of an array value.
    static func lookup(_ properties: [String: Any], path: String) -> Any? {
        var current: Any = properties
        for component in path.split(separator: ".") {
            var key = String(component)
            var index: Int?
            if key.hasSuffix("]"), let open = key.lastIndex(of: "[") {
                index = Int(key[key.index(after: open)..<key.index(before: key.endIndex)])
                key = String(key[..<open])
            }
            guard let dictionary = current as? [String: Any], let next = dictionary[key] else { return nil }
            current = next
            if let index {
                guard let list = current as? [Any], list.indices.contains(index) else { return nil }
                current = list[index]
            }
        }
        return current
    }

    static func imageIOValue(_ properties: [String: Any], path: String, kind: MetadataMapping.Kind) -> MetadataValue? {
        func number(_ any: Any?) -> Double? {
            if let value = any as? Double { return value }
            if let value = any as? NSNumber { return value.doubleValue }
            if let text = any as? String { return rational(text) }
            if let list = any as? [Any] { return number(list.first) }
            return nil
        }
        func text(_ any: Any?) -> String? {
            if let value = any as? String { return value.trimmingCharacters(in: .whitespaces).nilIfEmpty }
            if let value = any as? NSNumber { return value.stringValue }
            if let list = any as? [Any] { return text(list.first) }
            return nil
        }
        let raw = lookup(properties, path: path)
        switch kind {
        case .text:
            return text(raw).map(MetadataValue.text)
        case .list:
            if let list = raw as? [Any] {
                let values = list.compactMap(text)
                return values.isEmpty ? nil : .list(values)
            }
            return text(raw).map { .list([$0]) }
        case .integer:
            return number(raw).map { .integer(Int($0.rounded())) }
        case .number:
            return number(raw).map(MetadataValue.number)
        case .rightsMarked:
            return nil
        case .date:
            // Exif's three tags, put back together with the offset when the
            // file carries one — the same reading `ImportedStills.captureDate`
            // makes, kept as text so the offset survives.
            guard let exif = properties["{Exif}"] as? [String: Any],
                  let stamp = text(exif["DateTimeOriginal"] ?? exif["DateTimeDigitized"]) else { return nil }
            return exifDateText(stamp: stamp, subsecond: text(exif["SubsecTimeOriginal"] ?? exif["SubsecTimeDigitized"]),
                                offset: text(exif["OffsetTimeOriginal"] ?? exif["OffsetTime"])).map(MetadataValue.text)
        case .coordinate:
            guard let magnitude = number(raw) else { return nil }
            let reference = text(lookup(properties, path: path + "Ref"))?.uppercased()
            let negative = reference == "S" || reference == "W"
            return .number(negative ? -abs(magnitude) : magnitude)
        case .altitude:
            guard let magnitude = number(raw) else { return nil }
            let below = number(lookup(properties, path: path + "Ref")) == 1
            return .number(below ? -magnitude : magnitude)
        }
    }

    /// "2026:08:31 20:29:30" + "836" + "+01:00" → "2026-08-31T20:29:30.836+01:00".
    /// No offset in the file → no offset in the text: the record says what
    /// the camera said and does not invent a zone.
    static func exifDateText(stamp: String, subsecond: String?, offset: String?) -> String? {
        let parts = stamp.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let date = parts[0].replacingOccurrences(of: ":", with: "-")
        var text = "\(date)T\(parts[1])"
        if let digits = subsecond?.filter(\.isNumber), !digits.isEmpty {
            text += "." + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        }
        if let offset = offset?.trimmingCharacters(in: .whitespaces), !offset.isEmpty {
            if offset == "Z" {
                text += "Z"
            } else if offset.count == 5, offset.first == "+" || offset.first == "-" {
                text += String(offset.prefix(3)) + ":" + String(offset.suffix(2))
            } else {
                text += offset
            }
        }
        return AssetMetadata.parseISO8601(text) == nil ? nil : text
    }
}
