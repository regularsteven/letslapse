import Foundation

// A JSON value as JSON has it — nothing typed, nothing dropped. It exists so
// that a sidecar written by a newer build can pass through an older build's
// decode → edit → re-encode without losing what the older build does not
// understand: the register's `foreignShapes` and `foreignFields` are carried
// as these, and written back out byte-for-byte in meaning if not in
// whitespace. Every sidecar that travels between devices (`shapes.json`
// on PicPlace, .lapse, device transfer) is a candidate for the same
// treatment; this is the type they share.
//
// Numbers are Doubles, which is what JSONSerialization and JSONDecoder both
// give a JSON number anyway; an integer written by a newer build comes back
// an integer after the round trip because the encoder writes 5.0 as 5 — up
// to 2^53. Above that a Double cannot hold it, and the older build's
// re-encode changes it, so a newer build must not put such a number (a
// 64-bit id, a nanosecond stamp) in a sidecar that travels; nor does the
// textual form survive (`1.0` comes back `1`, `1e2` comes back `100`).

/// One JSON value, held as it was read.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null; return }
        if let b = try? single.decode(Bool.self) { self = .bool(b); return }
        if let n = try? single.decode(Double.self) { self = .number(n); return }
        if let s = try? single.decode(String.self) { self = .string(s); return }
        if let a = try? single.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? single.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: single, debugDescription: "Not a JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .null: try single.encodeNil()
        case .bool(let b): try single.encode(b)
        case .number(let n): try single.encode(n)
        case .string(let s): try single.encode(s)
        case .array(let a): try single.encode(a)
        case .object(let o): try single.encode(o)
        }
    }

    /// The value under `key` of an object, nil for anything else.
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}

/// A coding key that is whatever string it was given — how a decoder walks
/// the keys a type's own `CodingKeys` does not name, and how an encoder
/// writes them back under their own names.
public struct AnyCodingKey: CodingKey, Hashable, Sendable {
    public var stringValue: String
    public var intValue: Int?

    public init(_ string: String) { stringValue = string; intValue = nil }
    public init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    public init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}
