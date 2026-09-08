import AppKit
import CoreImage
import Foundation

// ---------- .cube parsing ----------
struct CubeLUT {
    var title: String
    var name: String = ""
    var size: Int
    var domainMin: [Float] = [0, 0, 0]
    var domainMax: [Float] = [1, 1, 1]
    var rgba: [Float]   // size^3 * 4, red fastest (the .cube order, also CIColorCube's)
    var minValue: Float
    var maxValue: Float

    static func parse(_ url: URL) throws -> CubeLUT {
        let bytes = try Data(contentsOf: url)
        let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1)!
        var title = url.deletingPathExtension().lastPathComponent
        var size = 0
        var dmin: [Float] = [0, 0, 0], dmax: [Float] = [1, 1, 1]
        var data: [Float] = []
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        var oneD = false
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let first = line.first!
            if first.isLetter {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                switch parts[0].uppercased() {
                case "TITLE": title = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : title
                case "LUT_3D_SIZE": size = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                case "LUT_1D_SIZE": oneD = true
                case "DOMAIN_MIN": dmin = parts[1].split(separator: " ").compactMap { Float($0) }
                case "DOMAIN_MAX": dmax = parts[1].split(separator: " ").compactMap { Float($0) }
                default: break
                }
                continue
            }
            let v = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Float($0) }
            guard v.count == 3 else { continue }
            for c in v { lo = min(lo, c); hi = max(hi, c) }
            data.append(v[0]); data.append(v[1]); data.append(v[2]); data.append(1)
        }
        guard !oneD else { throw NSError(domain: "cube", code: 2, userInfo: [NSLocalizedDescriptionKey: "1D LUT — not handled in the spike"]) }
        guard size >= 2, data.count == size * size * size * 4 else {
            throw NSError(domain: "cube", code: 1, userInfo: [NSLocalizedDescriptionKey: "size \(size) but \(data.count / 4) entries"])
        }
        return CubeLUT(title: title, size: size, domainMin: dmin, domainMax: dmax, rgba: data, minValue: lo, maxValue: hi)
    }

    /// Trilinear sample, for the numeric probes only (the renderer uses CIColorCube).
    func sample(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let n = size
        func idx(_ ri: Int, _ gi: Int, _ bi: Int) -> Int { ((bi * n + gi) * n + ri) * 4 }
        func pos(_ x: Float) -> (Int, Float) {
            let s = min(max(x, 0), 1) * Float(n - 1)
            let i = min(Int(s), n - 2)
            return (i, s - Float(i))
        }
        let (ri, rf) = pos(r), (gi, gf) = pos(g), (bi, bf) = pos(b)
        var out: [Float] = [0, 0, 0]
        for c in 0..<3 {
            func v(_ dr: Int, _ dg: Int, _ db: Int) -> Float { rgba[idx(ri + dr, gi + dg, bi + db) + c] }
            let c00 = v(0,0,0) * (1 - rf) + v(1,0,0) * rf
            let c10 = v(0,1,0) * (1 - rf) + v(1,1,0) * rf
            let c01 = v(0,0,1) * (1 - rf) + v(1,0,1) * rf
            let c11 = v(0,1,1) * (1 - rf) + v(1,1,1) * rf
            let c0 = c00 * (1 - gf) + c10 * gf
            let c1 = c01 * (1 - gf) + c11 * gf
            out[c] = c0 * (1 - bf) + c1 * bf
        }
        return (out[0], out[1], out[2])
    }

    func ciFilter(colorSpace: CGColorSpace) -> CIFilter {
        let f = CIFilter(name: "CIColorCubeWithColorSpace")!
        f.setValue(size, forKey: "inputCubeDimension")
        f.setValue(rgba.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: "inputCubeData")
        f.setValue(colorSpace, forKey: "inputColorSpace")
        return f
    }
}

// ---------- helpers ----------
let ctx = CIContext(options: [.useSoftwareRenderer: false])
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func load(_ url: URL, maxWidth: CGFloat?) -> CIImage {
    var img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])!
    if let maxWidth, img.extent.width > maxWidth {
        let s = maxWidth / img.extent.width
        img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
    }
    return img
}

func apply(_ lut: CubeLUT, to image: CIImage, strength: Float = 1) -> CIImage {
    let f = lut.ciFilter(colorSpace: srgb)
    f.setValue(image, forKey: kCIInputImageKey)
    let out = f.outputImage!
    guard strength < 1 else { return out }
    let mix = CIFilter(name: "CIDissolveTransition")!
    mix.setValue(image, forKey: kCIInputImageKey)
    mix.setValue(out, forKey: kCIInputTargetImageKey)
    mix.setValue(strength, forKey: kCIInputTimeKey)
    return mix.outputImage!
}

func cg(_ image: CIImage) -> CGImage {
    ctx.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: srgb)!
}

func ms(_ block: () -> Void) -> Double {
    let t = CFAbsoluteTimeGetCurrent(); block(); return (CFAbsoluteTimeGetCurrent() - t) * 1000
}


/// A labelled contact sheet: `cells` as (label, image), `columns` wide. Every
/// image is fitted inside a `cellWidth` × `cellHeight` box, so portrait and
/// landscape frames share a grid. `rowLabels`, when given, are drawn down the
/// left edge (one per row).
func sheet(_ cells: [(String, CGImage?)], columns: Int, cellWidth: Int, cellHeight: Int, path: String,
           rowLabels: [String] = [], header: [String] = []) {
    let cw = CGFloat(cellWidth), ch = CGFloat(cellHeight), label: CGFloat = 22, pad: CGFloat = 6
    let left: CGFloat = rowLabels.isEmpty ? 0 : 150
    let top: CGFloat = header.isEmpty ? 0 : 24
    let rows = (cells.count + columns - 1) / columns
    let W = Int(left + cw * CGFloat(columns) + pad * CGFloat(columns + 1))
    let H = Int(top + (ch + label) * CGFloat(rows) + pad * CGFloat(rows + 1))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    NSColor(white: 0.11, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor(white: 0.92, alpha: 1)]
    let rowAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor(red: 1, green: 0.7, blue: 0.25, alpha: 1)]
    for (i, name) in header.enumerated() {
        let x = left + pad + CGFloat(i) * (cw + pad)
        (name as NSString).draw(at: NSPoint(x: x + 2, y: CGFloat(H) - top + 4), withAttributes: rowAttrs)
    }
    for (i, (name, img)) in cells.enumerated() {
        let col = i % columns, row = i / columns
        let x = left + pad + CGFloat(col) * (cw + pad)
        let yTop = CGFloat(H) - top - pad - CGFloat(row) * (ch + label + pad)
        if col == 0, row < rowLabels.count {
            (rowLabels[row] as NSString).draw(in: NSRect(x: 6, y: yTop - ch, width: left - 10, height: ch), withAttributes: rowAttrs)
        }
        if let img {
            let s = min(cw / CGFloat(img.width), ch / CGFloat(img.height))
            let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
            let rect = NSRect(x: x + (cw - w) / 2, y: yTop - ch + (ch - h) / 2, width: w, height: h)
            g.cgContext.draw(img, in: rect)
        }
        if !name.isEmpty {
            (name as NSString).draw(at: NSPoint(x: x + 2, y: yTop - ch - label + 5), withAttributes: attrs)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// ---------- run ----------
// lutspike <outDir> <lutDir> <hero.jpg> <frame.jpg>...   (frames are engine-neutral renders)
let a = CommandLine.arguments
guard a.count >= 4 else { print("usage: lutspike <outDir> <lutDir> <hero> <frame>..."); exit(1) }
let outDir = URL(fileURLWithPath: a[1])
let lutDir = URL(fileURLWithPath: a[2])
let heroURL = URL(fileURLWithPath: a[3])
let frameURLs = a.dropFirst(4).map { URL(fileURLWithPath: $0) }

let lutURLs = try FileManager.default.contentsOfDirectory(at: lutDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension.lowercased() == "cube" }.sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }

var luts: [CubeLUT] = []
print("== parse ==")
for url in lutURLs {
    var lut: CubeLUT?
    var why = ""
    let t = ms { do { lut = try CubeLUT.parse(url) } catch { why = error.localizedDescription } }
    guard var lut else { print("FAIL \(url.lastPathComponent): \(why)"); continue }
    lut.name = url.deletingPathExtension().lastPathComponent
    let g18 = lut.sample(0.18, 0.18, 0.18), g50 = lut.sample(0.5, 0.5, 0.5), blk = lut.sample(0, 0, 0), wht = lut.sample(1, 1, 1)
    func f(_ v: (Float, Float, Float)) -> String { String(format: "%.3f/%.3f/%.3f", v.0, v.1, v.2) }
    print(String(format: "%-40@ title=%-28@ size %2d  parse %4.0f ms  range %6.3f…%5.3f  black→%@  18%%→%@  50%%→%@  white→%@",
                 lut.name as NSString, ("\"" + lut.title + "\"") as NSString, lut.size, t, lut.minValue, lut.maxValue, f(blk), f(g18), f(g50), f(wht)))
    luts.append(lut)
}
func short(_ s: String) -> String { s.count > 24 ? String(s.prefix(22)) + "…" : s }

// Sheet 1 — the matrix: every frame × (Original + every LUT).
print("\n== matrix: \(frameURLs.count) frames × \(luts.count) LUTs ==")
var matrix: [(String, CGImage?)] = []
var rowLabels: [String] = []
var perLUTms = [String: Double]()
var decodeMs: [Double] = []
for url in frameURLs {
    var base: CIImage!
    decodeMs.append(ms { base = load(url, maxWidth: 480) })
    rowLabels.append(url.deletingPathExtension().lastPathComponent)
    matrix.append(("", cg(base)))
    for lut in luts {
        var img: CGImage!
        let t = ms { img = cg(apply(lut, to: base)) }
        perLUTms[lut.name, default: 0] += t
        matrix.append(("", img))
    }
}
print(String(format: "load+scale per frame: mean %.0f ms   LUT pass per cell: mean %.1f ms", decodeMs.reduce(0, +) / Double(decodeMs.count), perLUTms.values.reduce(0, +) / Double(max(1, frameURLs.count * luts.count))))
sheet(matrix, columns: luts.count + 1, cellWidth: 200, cellHeight: 150, path: outDir.appendingPathComponent("matrix-frames-x-luts.png").path,
      rowLabels: rowLabels, header: ["Original"] + luts.map { short($0.name) })

// Sheet 2 — use case 2: one photo, every LUT (plus one at half strength).
let hero = load(heroURL, maxWidth: 1000)
var cells2: [(String, CGImage?)] = [("Original (engine neutral)", cg(hero))]
print("\n== use case 2: hero × every LUT at 1000 px ==")
for lut in luts {
    var img: CGImage!
    let t = ms { img = cg(apply(lut, to: hero)) }
    print(String(format: "%-40@ %5.1f ms", lut.name as NSString, t))
    cells2.append((lut.name, img))
}
let teal = luts.first { $0.name.lowercased().contains("teal") } ?? luts[0]
cells2.append(("\(teal.name) @ 50 %", cg(apply(teal, to: hero, strength: 0.5))))
sheet(cells2, columns: 5, cellWidth: 420, cellHeight: 300, path: outDir.appendingPathComponent("usecase2-one-photo-many-luts.png").path)

// Sheet 3 — use case 1: one LUT across every frame, before/after pairs.
let pick = luts.first { $0.name.lowercased().contains("terra") } ?? luts[0]
var cells1: [(String, CGImage?)] = []
for url in frameURLs {
    let base = load(url, maxWidth: 600)
    cells1.append(("\(url.deletingPathExtension().lastPathComponent) — before", cg(base)))
    cells1.append(("after: \(pick.name)", cg(apply(pick, to: base))))
}
sheet(cells1, columns: 4, cellWidth: 320, cellHeight: 240, path: outDir.appendingPathComponent("usecase1-one-lut-many-photos.png").path)

// Identity sanity.
var ident: [Float] = []
let n = 33
for b in 0..<n { for g in 0..<n { for r in 0..<n { ident += [Float(r)/Float(n-1), Float(g)/Float(n-1), Float(b)/Float(n-1), 1] } } }
let identity = CubeLUT(title: "identity", size: n, rgba: ident, minValue: 0, maxValue: 1)
let pa = (cg(hero).dataProvider!.data! as Data), pb = (cg(apply(identity, to: hero)).dataProvider!.data! as Data)
var maxDiff = 0
for i in stride(from: 0, to: min(pa.count, pb.count), by: 4) { maxDiff = max(maxDiff, abs(Int(pa[i]) - Int(pb[i])), abs(Int(pa[i+1]) - Int(pb[i+1])), abs(Int(pa[i+2]) - Int(pb[i+2]))) }
print("\nidentity cube max 8-bit channel diff: \(maxDiff)")
let cube = CIFilter(name: "CIColorCubeWithColorSpace")!
if let d = cube.attributes["inputCubeDimension"] as? [String: Any] { print("CIColorCubeWithColorSpace inputCubeDimension: min \(d[kCIAttributeMin] ?? "?") max \(d[kCIAttributeMax] ?? "?")") }
print("CIColorCubesMixedWithMask available: \(CIFilter(name: "CIColorCubesMixedWithMask") != nil)")
print("done → \(outDir.path)")
