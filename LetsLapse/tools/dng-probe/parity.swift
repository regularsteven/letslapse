import Foundation
import CoreImage
let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let ctx = CIContext(options: [.workingColorSpace: linearP3, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
func stats(_ raw: CIRAWFilter, _ label: String) {
    raw.boostAmount = 0; raw.extendedDynamicRangeAmount = 2; raw.scaleFactor = 0.25
    let k = raw.neutralTemperature, t = raw.neutralTint
    guard let img = raw.outputImage else { print(label, "NO OUTPUT"); return }
    let e = img.extent.integral; let w = Int(e.width), h = Int(e.height)
    var buf = [Float](repeating: 0, count: w*h*4)
    buf.withUnsafeMutableBytes { ctx.render(img, toBitmap: $0.baseAddress!, rowBytes: w*16, bounds: e, format: .RGBAf, colorSpace: linearP3) }
    var s = [Double](repeating: 0, count: 3)
    for i in 0..<(w*h) { s[0] += Double(buf[i*4]); s[1] += Double(buf[i*4+1]); s[2] += Double(buf[i*4+2]) }
    let n = Double(w*h)
    print(String(format: "%@ %dx%d neutral %.0fK/%.1f  R %.5f G %.5f B %.5f", label, w, h, k, t, s[0]/n, s[1]/n, s[2]/n))
}
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    if let r = CIRAWFilter(imageURL: url) { stats(r, "URL  " + url.lastPathComponent) }
    let data = try! Data(contentsOf: url)
    if let r = CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image") { stats(r, "DATA " + url.lastPathComponent) } else { print("DATA init failed for", path) }
    if let r = CIRAWFilter(imageData: data, identifierHint: nil) { stats(r, "DATA(nohint) " + url.lastPathComponent) } else { print("DATA(nohint) init failed for", path) }
}
