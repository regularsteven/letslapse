import Foundation
import CoreImage
import ImageIO
import AppKit

// rawstat <mode> <in> <outpng> [scale] [boost]
// modes: ciraw (CIRAWFilter, app settings), imageio (CGImageSource full decode, what Preview/QuickLook use)
let args = CommandLine.arguments
let mode = args[1], inPath = args[2], outPath = args[3]
let scale = args.count > 4 ? Float(args[4])! : 0.25
let boost = args.count > 5 ? Float(args[5])! : 0
let url = URL(fileURLWithPath: inPath)
let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let ctx = CIContext(options: [.workingColorSpace: linearP3, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
var image: CIImage
var note = ""
if mode == "ciraw" {
    guard let raw = CIRAWFilter(imageURL: url) else { print("CIRAWFilter refused \(inPath)"); exit(2) }
    raw.boostAmount = boost
    raw.extendedDynamicRangeAmount = 2
    raw.scaleFactor = scale
    note = "neutral \(Int(raw.neutralTemperature))K tint \(raw.neutralTint) native \(raw.nativeSize)"
    guard let out = raw.outputImage else { print("no output"); exit(3) }
    image = out
} else {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { print("no source"); exit(2) }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
    note = "imageio props w=\(props["PixelWidth"] ?? "?") h=\(props["PixelHeight"] ?? "?") depth=\(props["Depth"] ?? "?") model=\(props["ColorModel"] ?? "?") profile=\(props["ProfileName"] ?? "?")"
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 20000] as CFDictionary) else { print("decode failed"); exit(3) }
    image = CIImage(cgImage: cg)
    if scale != 1 { image = image.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))) }
}
let extent = image.extent.integral
let w = Int(extent.width), h = Int(extent.height)
var buf = [Float](repeating: 0, count: w*h*4)
buf.withUnsafeMutableBytes { p in
    ctx.render(image, toBitmap: p.baseAddress!, rowBytes: w*16, bounds: extent, format: .RGBAf, colorSpace: linearP3)
}
// stats: whole-image mean, and mean of the darkest 10% (by luma) and brightest 10%
var lum = [Float](repeating: 0, count: w*h)
var sum = [Double](repeating: 0, count: 3)
for i in 0..<(w*h) { let r = buf[i*4], g = buf[i*4+1], b = buf[i*4+2]; lum[i] = 0.2627*r+0.678*g+0.0593*b; sum[0]+=Double(r); sum[1]+=Double(g); sum[2]+=Double(b) }
let n = Double(w*h)
let sorted = lum.sorted()
let lo = sorted[Int(Double(sorted.count)*0.10)], hi = sorted[Int(Double(sorted.count)*0.90)]
var dsum = [Double](repeating: 0, count: 3), dn = 0.0, bsum = [Double](repeating: 0, count: 3), bn = 0.0
for i in 0..<(w*h) {
    if lum[i] <= lo { dsum[0]+=Double(buf[i*4]); dsum[1]+=Double(buf[i*4+1]); dsum[2]+=Double(buf[i*4+2]); dn+=1 }
    if lum[i] >= hi { bsum[0]+=Double(buf[i*4]); bsum[1]+=Double(buf[i*4+1]); bsum[2]+=Double(buf[i*4+2]); bn+=1 }
}
func f(_ x: Double) -> String { String(format: "%.5f", x) }
print("\(mode) \(url.lastPathComponent) \(w)x\(h) \(note)")
print("  mean  R \(f(sum[0]/n)) G \(f(sum[1]/n)) B \(f(sum[2]/n))  R/G \(f(sum[0]/sum[1])) B/G \(f(sum[2]/sum[1]))")
print("  dark10 R \(f(dsum[0]/dn)) G \(f(dsum[1]/dn)) B \(f(dsum[2]/dn))  R/G \(f(dsum[0]/dsum[1])) B/G \(f(dsum[2]/dsum[1]))")
print("  bright10 R \(f(bsum[0]/bn)) G \(f(bsum[1]/bn)) B \(f(bsum[2]/bn))  R/G \(f(bsum[0]/bsum[1])) B/G \(f(bsum[2]/bsum[1]))")
// PNG for viewing (sRGB, tone-mapped via a simple sRGB transfer, clipped)
if outPath != "-" {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    if let cg = ctx.createCGImage(image, from: extent, format: .RGBA8, colorSpace: srgb) {
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outPath))
    }
}
