import Foundation
import LetsLapseKit

// The pipeline moved into the Kit (Kit/Sources/LetsLapseKit/Archive/) so the
// app can run it; the tool keeps its short names.
typealias Strategy = DNGArchive.Strategy
typealias Converter = DNGArchive.Converter
typealias ConversionReport = DNGArchive.ConversionReport
typealias TileCodec = DNGArchive.TileCodec
typealias Curve = DNGArchive.Curve
typealias StoredEncoding = DNGArchive.StoredEncoding
typealias TileEncoder = DNGArchive.TileEncoder
typealias EncodedTiles = DNGArchive.EncodedTiles
typealias JXLEncoder = DNGArchive.JXLEncoder
typealias LibRawDecoder = DNGArchive.LibRawDecoder
typealias NativeDecoder = DNGArchive.NativeDecoder
typealias AppleDecoder = DNGArchive.AppleDecoder
typealias MetalDemosaic = DNGArchive.MetalDemosaic
typealias FrameMetadata = DNGArchive.FrameMetadata
typealias MosaicFrame = DNGArchive.MosaicFrame
typealias RGBFrame = DNGArchive.RGBFrame
typealias SpikeError = DNGArchive.ConversionError

extension DNGArchive.LibRawDecoder {
    static var isAvailable: Bool { true }
}
