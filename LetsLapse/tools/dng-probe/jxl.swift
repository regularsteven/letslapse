import Foundation
import ImageIO
import CoreGraphics
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try! Data(contentsOf: url)
guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { print("no source"); exit(1) }
print("type:", CGImageSourceGetType(src) ?? "nil" as CFString, "count:", CGImageSourceGetCount(src))
if let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) { print("props:", p) }
guard let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { print("decode failed"); exit(2) }
print("cg:", img.width, img.height, "bpc", img.bitsPerComponent, "bpp", img.bitsPerPixel, "cs", img.colorSpace?.name ?? "nil" as CFString, "alpha", img.alphaInfo.rawValue, "byteOrder", img.bitmapInfo.rawValue)
let w = img.width, h = img.height
let raw = img.dataProvider!.data! as Data
let bpr = img.bytesPerRow, spp = img.bitsPerPixel/16
print("bytesPerRow", bpr, "samples/pixel", spp, "bytes", raw.count)
var mn = [UInt16](repeating: 65535, count: 3), mx = [UInt16](repeating: 0, count: 3), sum = [Double](repeating: 0, count: 3)
raw.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
  for y in 0..<h { for x in 0..<w { for c in 0..<3 {
    let v = p.load(fromByteOffset: y*bpr + (x*spp+c)*2, as: UInt16.self)
    mn[c] = min(mn[c], v); mx[c] = max(mx[c], v); sum[c] += Double(v) } } } }
print("raw min", mn, "max", mx, "mean", sum.map { Int($0/Double(w*h)) })
