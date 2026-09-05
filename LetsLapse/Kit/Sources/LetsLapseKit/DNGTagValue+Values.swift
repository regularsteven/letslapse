import Foundation

/// Numeric readings of a directory entry, whatever TIFF type it was stored
/// as. Payloads are little-endian by `DNGDocument`'s contract.
extension DNGTagValue {
    /// Every value as a Double: SHORT/LONG/SSHORT/SLONG as integers,
    /// RATIONAL/SRATIONAL divided out, FLOAT/DOUBLE as themselves, BYTE as
    /// 0…255. Empty for ASCII/UNDEFINED.
    public var doubles: [Double] {
        var values: [Double] = []
        switch type {
        case 1:
            for byte in payload { values.append(Double(byte)) }
        case 3:
            for i in stride(from: 0, to: payload.count - 1, by: 2) { values.append(Double(payload.readU16(at: i))) }
        case 4:
            for i in stride(from: 0, to: payload.count - 3, by: 4) { values.append(Double(payload.readU32(at: i))) }
        case 8:
            for i in stride(from: 0, to: payload.count - 1, by: 2) {
                values.append(Double(Int16(bitPattern: payload.readU16(at: i))))
            }
        case 9:
            for i in stride(from: 0, to: payload.count - 3, by: 4) {
                values.append(Double(Int32(bitPattern: payload.readU32(at: i))))
            }
        case 5:
            for i in stride(from: 0, to: payload.count - 7, by: 8) {
                let d = Double(payload.readU32(at: i + 4))
                values.append(d == 0 ? 0 : Double(payload.readU32(at: i)) / d)
            }
        case 10:
            for i in stride(from: 0, to: payload.count - 7, by: 8) {
                let d = Double(Int32(bitPattern: payload.readU32(at: i + 4)))
                values.append(d == 0 ? 0 : Double(Int32(bitPattern: payload.readU32(at: i))) / d)
            }
        case 11:
            for i in stride(from: 0, to: payload.count - 3, by: 4) {
                values.append(Double(Float(bitPattern: payload.readU32(at: i))))
            }
        case 12:
            for i in stride(from: 0, to: payload.count - 7, by: 8) {
                let low = UInt64(payload.readU32(at: i)), high = UInt64(payload.readU32(at: i + 4))
                values.append(Double(bitPattern: high << 32 | low))
            }
        default:
            break
        }
        return values
    }

    /// Integer readings (SHORT/LONG/BYTE and the signed forms); rationals and
    /// floats are rounded.
    public var ints: [Int] { doubles.map { Int($0.rounded()) } }

    /// The ASCII payload without its terminator, for type 2 tags.
    public var text: String? {
        guard type == 2 else { return nil }
        var bytes = payload
        while let last = bytes.last, last == 0 { bytes.removeLast() }
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1)
    }
}

extension Array where Element == DNGTagValue {
    /// The first entry with `tag`.
    public func tag(_ tag: UInt16) -> DNGTagValue? { first { $0.tag == tag } }
    public func int(_ tag: UInt16) -> Int? { self.tag(tag)?.ints.first }
    public func doubles(_ tag: UInt16) -> [Double] { self.tag(tag)?.doubles ?? [] }
    public func ints(_ tag: UInt16) -> [Int] { self.tag(tag)?.ints ?? [] }
}
