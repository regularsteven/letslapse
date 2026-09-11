// tile — tile JPEG/PNG frames into one review sheet.
//   swiftc -O scripts/tile.swift -o /tmp/tile && /tmp/tile <out.png> <cols> <tileWidth> <file…>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 5 else { print("usage: tile out.png cols tileWidth files…"); exit(1) }
let out = URL(fileURLWithPath: args[1]); let cols = Int(args[2])!; let tw = Int(args[3])!; let tileH = tw * 9 / 16
let files = Array(args[4...])
let th = tileH + 18
let rows = (files.count + cols - 1) / cols
let ctx = CGContext(data: nil, width: cols * tw, height: rows * th, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: cols * tw, height: rows * th))
for (i, f) in files.enumerated() {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: f) as CFURL, nil),
          let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceThumbnailMaxPixelSize: tw, kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary) else { continue }
    let col = i % cols, row = i / cols
    let sx = CGFloat(tw) / CGFloat(img.width)
    let sy = CGFloat(tileH) / CGFloat(img.height)
    let s = min(sx, sy)
    let w = CGFloat(img.width) * s
    let h = CGFloat(img.height) * s
    let x = CGFloat(col * tw) + (CGFloat(tw) - w) / 2
    let baseY = CGFloat((rows - 1 - row) * th) + 18
    let y = baseY + (CGFloat(tileH) - h) / 2
    ctx.draw(img, in: CGRect(x: x, y: y, width: w, height: h))
}
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path) \(cols)x\(rows)")
