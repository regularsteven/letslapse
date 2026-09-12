import Foundation

/// An XMP packet — a `.xmp` sidecar, or the packet embedded in a JPEG, TIFF
/// or DNG — flattened to `canonical path → value`.
///
/// Namespace-aware: properties are keyed by a fixed canonical prefix for
/// their namespace URI (`dc:`, `xmp:`, `Iptc4xmpCore:` …), whatever prefix
/// the writer chose, so `MetadataFieldMap`'s paths match every writer. Both
/// XMP spellings are read — attributes on `rdf:Description` (Lightroom's
/// sidecars) and child elements (ImageIO's re-serialisation of an embedded
/// packet) — and structs in either the `rdf:parseType="Resource"` form, the
/// nested `rdf:Description` form, or the attribute-shorthand form Photoshop
/// writes for `CreatorContactInfo`. A struct member is addressed as
/// `Struct/Member`.
///
/// Read-only by design: nothing here writes XMP, and the raw packet is never
/// stored in a record — it stays in the file (or the copied sidecar) it came
/// from (Part 2 §4.4).
public struct XMPPacket: Equatable, Sendable {

    public enum Value: Equatable, Sendable {
        case text(String)
        /// A language alternative (`rdf:Alt`), `xml:lang` → value.
        case alt([String: String])
        /// An ordered `rdf:Seq` or `rdf:Bag` of simple items.
        case list([String])
    }

    public private(set) var properties: [String: Value] = [:]

    public init() {}

    public var isEmpty: Bool { properties.isEmpty }

    /// A simple value; a lang-alt yields `x-default`, then the only entry,
    /// then any; a list yields its first item (ISO speed ratings are a Seq
    /// of one).
    public func text(_ path: String) -> String? {
        switch properties[path] {
        case .text(let value)?: return value.nilIfEmpty
        case .alt(let alternatives)?:
            if let value = alternatives["x-default"] { return value.nilIfEmpty }
            return alternatives.sorted { $0.key < $1.key }.first?.value.nilIfEmpty
        case .list(let values)?: return values.first?.nilIfEmpty
        case nil: return nil
        }
    }

    public func list(_ path: String) -> [String]? {
        switch properties[path] {
        case .list(let values)?: return values.isEmpty ? nil : values
        case .text(let value)?: return value.nilIfEmpty.map { [$0] }
        case .alt(let alternatives)?: return alternatives["x-default"]?.nilIfEmpty.map { [$0] }
        case nil: return nil
        }
    }

    // MARK: - Parsing

    public enum ParseError: Error, LocalizedError {
        case unreadable
        public var errorDescription: String? { "That file could not be read as XMP." }
    }

    public static func read(contentsOf url: URL) throws -> XMPPacket {
        guard let data = try? Data(contentsOf: url) else { throw ParseError.unreadable }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> XMPPacket {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        let builder = Builder()
        parser.delegate = builder
        guard parser.parse() else { throw ParseError.unreadable }
        return builder.packet
    }

    /// The canonical prefix for each namespace this reader knows.
    static let canonicalPrefixes: [String: String] = [
        "http://purl.org/dc/elements/1.1/": "dc",
        "http://ns.adobe.com/xap/1.0/": "xmp",
        "http://ns.adobe.com/xap/1.0/rights/": "xmpRights",
        "http://ns.adobe.com/xap/1.0/mm/": "xmpMM",
        "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/": "Iptc4xmpCore",
        "http://iptc.org/std/Iptc4xmpExt/2008-02-29/": "Iptc4xmpExt",
        "http://ns.adobe.com/photoshop/1.0/": "photoshop",
        "http://ns.adobe.com/exif/1.0/": "exif",
        "http://cipa.jp/exif/1.0/": "exifEX",
        "http://ns.adobe.com/tiff/1.0/": "tiff",
        "http://ns.adobe.com/exif/1.0/aux/": "aux",
        "http://ns.adobe.com/lightroom/1.0/": "lr",
        "http://ns.adobe.com/xmp/1.0/DynamicMedia/": "xmpDM",
        "http://ns.adobe.com/camera-raw-settings/1.0/": "crs",
        "http://www.w3.org/1999/02/22-rdf-syntax-ns#": "rdf",
        "http://www.w3.org/XML/1998/namespace": "xml",
    ]

    /// The delegate: a stack of frames, because the same `rdf:Description`
    /// element is the packet's root at one depth and a struct at another,
    /// and only its ancestry tells them apart.
    private final class Builder: NSObject, XMLParserDelegate {
        var packet = XMPPacket()

        private enum Frame {
            case skip
            case rdf
            /// A container of properties, whose paths start with `prefix`.
            case container(prefix: String)
            case property(path: String, isStruct: Bool, text: String)
            case array(path: String, isAlt: Bool, items: [(lang: String?, text: String)])
            case item(lang: String?, isStruct: Bool, text: String)
        }

        private var frames: [Frame] = []
        /// Prefix → namespace URIs, innermost last.
        private var prefixes: [String: [String]] = [:]

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
            prefixes[prefix, default: []].append(namespaceURI)
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
            _ = prefixes[prefix]?.popLast()
        }

        private func canonical(uri: String?, local: String, qualified: String?) -> String {
            if let uri, let prefix = XMPPacket.canonicalPrefixes[uri] { return "\(prefix):\(local)" }
            if let qualified, qualified.contains(":") { return qualified }
            return local
        }

        /// An attribute's canonical name, resolved through the in-scope
        /// prefix mappings.
        private func canonicalAttribute(_ name: String) -> String? {
            guard let colon = name.firstIndex(of: ":") else { return nil }
            let prefix = String(name[..<colon])
            let local = String(name[name.index(after: colon)...])
            if prefix == "xmlns" { return nil }
            if prefix == "xml" { return "xml:\(local)" }
            guard let uri = prefixes[prefix]?.last else { return "\(prefix):\(local)" }
            return canonical(uri: uri, local: local, qualified: name)
        }

        private func isRDF(_ uri: String?) -> Bool {
            uri == "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            let name = canonical(uri: namespaceURI, local: element, qualified: qualifiedName)
            let parent = frames.last
            let parseType = attributes["rdf:parseType"]

            /// Property-bearing attributes, canonicalised — `xmlns`, `rdf:`
            /// and `xml:` bookkeeping left out.
            func propertyAttributes() -> [(String, String)] {
                attributes.compactMap { key, value in
                    guard let canonicalName = canonicalAttribute(key),
                          !canonicalName.hasPrefix("rdf:"), !canonicalName.hasPrefix("xml:")
                    else { return nil }
                    return (canonicalName, value)
                }
            }

            if isRDF(namespaceURI) {
                switch element {
                case "RDF":
                    frames.append(.rdf)
                case "Description":
                    switch parent {
                    case .rdf?:
                        frames.append(.container(prefix: ""))
                        for (key, value) in propertyAttributes() { packet.properties[key] = .text(value) }
                    case .property(let path, _, _)?:
                        // A struct written as a nested Description.
                        frames.append(.container(prefix: path + "/"))
                        for (key, value) in propertyAttributes() { packet.properties[path + "/" + key] = .text(value) }
                    default:
                        frames.append(.skip)
                    }
                case "Alt", "Seq", "Bag":
                    if case .property(let path, _, _)? = parent {
                        frames.append(.array(path: path, isAlt: element == "Alt", items: []))
                    } else {
                        frames.append(.skip)
                    }
                case "li":
                    if case .array? = parent {
                        let isStruct = parseType == "Resource" || !propertyAttributes().isEmpty
                        frames.append(.item(lang: attributes["xml:lang"], isStruct: isStruct, text: ""))
                    } else {
                        frames.append(.skip)
                    }
                default:
                    frames.append(.skip)
                }
                return
            }

            // A property element.
            let prefix: String?
            switch parent {
            case .container(let containerPrefix)?: prefix = containerPrefix
            case .property(let path, let isStruct, _)? where isStruct: prefix = path + "/"
            default: prefix = nil
            }
            guard let prefix else {
                frames.append(.skip)
                return
            }
            let path = prefix + name
            let shorthand = propertyAttributes()
            let isStruct = parseType == "Resource" || !shorthand.isEmpty
            for (key, value) in shorthand { packet.properties[path + "/" + key] = .text(value) }
            frames.append(.property(path: path, isStruct: isStruct, text: ""))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let last = frames.last else { return }
            switch last {
            case .property(let path, let isStruct, let text):
                frames[frames.count - 1] = .property(path: path, isStruct: isStruct, text: text + string)
            case .item(let lang, let isStruct, let text):
                frames[frames.count - 1] = .item(lang: lang, isStruct: isStruct, text: text + string)
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            guard let frame = frames.popLast() else { return }
            switch frame {
            case .item(let lang, let isStruct, let text):
                guard !isStruct, case .array(let path, let isAlt, var items)? = frames.last else { return }
                items.append((lang, text.trimmingCharacters(in: .whitespacesAndNewlines)))
                frames[frames.count - 1] = .array(path: path, isAlt: isAlt, items: items)
            case .array(let path, let isAlt, let items):
                if isAlt {
                    var alternatives: [String: String] = [:]
                    for (index, item) in items.enumerated() {
                        alternatives[item.lang ?? (index == 0 ? "x-default" : "\(index)")] = item.text
                    }
                    packet.properties[path] = .alt(alternatives)
                } else {
                    packet.properties[path] = .list(items.map(\.text))
                }
            case .property(let path, let isStruct, let text):
                guard !isStruct, packet.properties[path] == nil else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { packet.properties[path] = .text(trimmed) }
            case .skip, .rdf, .container:
                break
            }
        }
    }
}
