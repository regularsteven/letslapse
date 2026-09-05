import Foundation

extension DNGArchive {

    /// A DNG `GainMap` opcode (id 9): per-pixel gains on a coarse grid in
    /// normalised active-area coordinates, bilinearly interpolated. Apple's
    /// camera DNGs carry the lens-shading (colour shading) correction this
    /// way in OpcodeList3 — one map, three planes, ~191×65 points, 149 KB —
    /// and without it a converted frame renders with a strong colour cast
    /// (blue ×0.57 measured on an iPhone 16 Pro night frame, 2026-09-05).
    /// Normalised coordinates make the map resolution-independent, so it is
    /// baked into the demosaiced pixels at whatever size the archive has.
    public struct GainMap: Equatable, Sendable {
        /// Area in active-area pixel coordinates (top, left, bottom, right).
        public var top: Int, left: Int, bottom: Int, right: Int
        public var plane: Int, planes: Int
        public var rowPitch: Int, colPitch: Int
        public var pointsV: Int, pointsH: Int
        public var spacingV: Double, spacingH: Double
        public var originV: Double, originH: Double
        public var mapPlanes: Int
        /// `pointsV × pointsH × mapPlanes`, row-major, plane fastest.
        public var gains: [Float]

        /// Which opcode list ids this parser handles.
        public static let gainMapID: UInt32 = 9
    }

    public struct ParsedOpcodes: Sendable {
        public var gainMaps: [GainMap] = []
        /// Opcode ids met that are not baked (WarpRectilinear 1, FixVignette 7,
        /// MapPolynomial 8, …); the caller decides whether that is a problem.
        public var unsupported: [UInt32] = []
    }

    /// Parses an OpcodeList blob (big-endian regardless of the file's order).
    public static func parseOpcodes(_ blob: Data) throws -> ParsedOpcodes {
        func u32(_ at: Int) throws -> UInt32 {
            guard at + 4 <= blob.count else { throw ConversionError.decode("truncated opcode list") }
            return blob.readU32(at: at).byteSwapped
        }
        func f64(_ at: Int) throws -> Double {
            let high = UInt64(try u32(at)), low = UInt64(try u32(at + 4))
            return Double(bitPattern: high << 32 | low)
        }
        var parsed = ParsedOpcodes()
        let count = Int(try u32(0))
        var cursor = 4
        for _ in 0..<count {
            let id = try u32(cursor)
            let size = Int(try u32(cursor + 12))
            let body = cursor + 16
            if id == GainMap.gainMapID {
                var map = GainMap(
                    top: Int(try u32(body)), left: Int(try u32(body + 4)), bottom: Int(try u32(body + 8)), right: Int(try u32(body + 12)),
                    plane: Int(try u32(body + 16)), planes: Int(try u32(body + 20)),
                    rowPitch: Int(try u32(body + 24)), colPitch: Int(try u32(body + 28)),
                    pointsV: Int(try u32(body + 32)), pointsH: Int(try u32(body + 36)),
                    spacingV: try f64(body + 40), spacingH: try f64(body + 48),
                    originV: try f64(body + 56), originH: try f64(body + 64),
                    mapPlanes: Int(try u32(body + 72)), gains: [])
                let total = map.pointsV * map.pointsH * map.mapPlanes
                guard total > 0, total < 50_000_000, body + 76 + total * 4 <= blob.count else {
                    throw ConversionError.decode("GainMap of \(map.pointsV)×\(map.pointsH)×\(map.mapPlanes) points does not fit its opcode")
                }
                var gains = [Float](repeating: 0, count: total)
                for i in 0..<total { gains[i] = Float(bitPattern: try u32(body + 76 + i * 4)) }
                map.gains = gains
                parsed.gainMaps.append(map)
            } else {
                parsed.unsupported.append(id)
            }
            cursor = body + size
        }
        return parsed
    }
}
