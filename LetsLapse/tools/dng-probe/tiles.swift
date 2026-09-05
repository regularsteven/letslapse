import Foundation
import ImageIO
// tiles <dng>: read the LinearRaw sub-IFD tile table (II only) and decode every JXL tile through ImageIO
let d = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1]) << 8 }
func u32(_ o: Int) -> Int { u16(o) | u16(o+2) << 16 }
func ifd(_ off: Int) -> [Int: (type: Int, count: Int, value: Int)] {
    var out: [Int: (Int, Int, Int)] = [:]; let n = u16(off)
    for i in 0..<n { let b = off + 2 + i*12; let t = u16(b), ty = u16(b+2), c = u32(b+4)
        let sz = [1:1,2:1,3:2,4:4,5:8,7:1,10:8,11:4,12:8][ty] ?? 1
        out[t] = (ty, c, sz*c > 4 ? u32(b+8) : b+8) }
    return out
}
let ifd0 = ifd(u32(4)); let sub = ifd(u32(ifd0[330]!.value))
let w = u32(sub[256]!.value), h = u32(sub[257]!.value), tw = u32(sub[322]!.value), th = u32(sub[323]!.value)
let n = sub[324]!.count
let offs = (0..<n).map { u32(sub[324]!.value + 4*$0) }, cnts = (0..<n).map { u32(sub[325]!.value + 4*$0) }
let across = (w + tw - 1) / tw
print("image \(w)x\(h) tiles \(tw)x\(th) count \(n) across \(across)")
func decode(_ k: Int) -> (Int, Int, Int, Int) {
    let td = d.subdata(in: offs[k]..<(offs[k]+cnts[k]))
    guard let src = CGImageSourceCreateWithData(td as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return (-1,-1,-1,-1) }
    return (img.width, img.height, img.bitsPerComponent, img.bitsPerPixel)
}
var t0 = Date()
for k in [0, across-1, n-across, n-1] { print("tile \(k):", decode(k)) }
t0 = Date(); for k in 0..<n { _ = decode(k) }; print(String(format: "serial decode of %d tiles: %.0f ms", n, Date().timeIntervalSince(t0)*1000))
t0 = Date(); DispatchQueue.concurrentPerform(iterations: n) { _ = decode($0) }; print(String(format: "parallel decode: %.0f ms", Date().timeIntervalSince(t0)*1000))
