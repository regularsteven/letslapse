import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import CoreVideo

enum EdgePolicy: String { case exclude, letterbox }

/// Second-per-item proof clips: 1920×1080 H.264, 30 fps, hard cuts, each item
/// transformed so its anchor sits at frame centre at the target size.
final class ClipRenderer {
    let frame: AnchorTransform.Frame
    let fps: Int32 = 30
    let secondsPerItem: Double
    let targetFraction: Double
    let edgePolicy: EdgePolicy
    let rotation: RotationMode
    let log: RunLog
    var frameDumpDir: URL? = nil

    init(frame: AnchorTransform.Frame, secondsPerItem: Double, targetFraction: Double, edgePolicy: EdgePolicy, rotation: RotationMode, log: RunLog) {
        self.frame = frame; self.secondsPerItem = secondsPerItem; self.targetFraction = targetFraction
        self.edgePolicy = edgePolicy; self.rotation = rotation; self.log = log
    }

    func render(group: ShapeGroup, variant: RenderVariant, ordering: String, assets: [String: Asset],
                imageCache: ImageCache, to url: URL) async throws -> RenderedClip {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: frame.width,
            AVVideoHeightKey: frame.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 14_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: frame.width,
            kCVPixelBufferHeightKey as String: frame.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RenderError.writer("startWriting") }
        writer.startSession(atSourceTime: .zero)

        let order: [GroupMember] = ordering == "size"
            ? group.sizeOrdered.compactMap { id in group.members.first { $0.assetID == id } }
            : group.members
        let framesPerItem = max(1, Int((secondsPerItem * Double(fps)).rounded()))
        var frameIndex: Int64 = 0
        var items: [RenderedItem] = []

        for member in order {
            guard let asset = assets[member.assetID] else { continue }
            let native = (asset.nativeWidth, asset.nativeHeight)
            let coverage = variant == .centred ? member.coverageCentred : member.coverageAligned
            let shortfall = 1 - coverage
            if edgePolicy == .exclude, shortfall > 0.005 {
                log.note("edge-excluded", "group \(group.index) \(variant.rawValue) \(asset.shortID): crop exceeds source by \(String(format: "%.1f", shortfall * 100))% of the frame")
                items.append(RenderedItem(assetID: asset.id, included: false, shortfall: shortfall, scaleFactor: member.scaleFactor, error: nil))
                continue
            }
            guard let h = AnchorTransform.homography(anchor: member.anchor, native: native, frame: frame, targetFraction: targetFraction,
                                                     variant: variant, rotation: rotation, medianAspect: group.medianAspect) else {
                items.append(RenderedItem(assetID: asset.id, included: false, shortfall: shortfall, scaleFactor: member.scaleFactor, error: "no transform"))
                continue
            }
            do {
                let source = try await imageCache.image(for: asset)
                guard let pool = adaptor.pixelBufferPool else { throw RenderError.writer("no pixel buffer pool") }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let buffer = pb else { throw RenderError.writer("pixel buffer") }
                try autoreleasepool {
                    let out = try composite(source: source, native: native, h: h)
                    ImageLoader.ciContext.render(out, to: buffer, bounds: frame.rect, colorSpace: ImageLoader.srgb)
                    let caption = "\(asset.shortID)  ⌀\(Int(member.anchor.nativeDiameterPx))px  ×\(String(format: "%.2f", member.scaleFactor))  obl \(String(format: "%.2f", member.anchor.groupingObliquity))  \(variant.rawValue)\(shortfall > 0.005 ? "  edge −\(String(format: "%.0f", shortfall * 100))%" : "")"
                    burnCaption(caption, into: buffer)
                    if let dir = frameDumpDir {
                        let name = "\(url.deletingPathExtension().lastPathComponent)-\(String(format: "%02d", items.count + 1))-\(asset.shortID).jpg"
                        if let cg = Self.cgImage(from: buffer) { try? ImageLoader.writeJPEG(cg, to: dir.appendingPathComponent(name), quality: 0.85) }
                    }
                }
                for _ in 0..<framesPerItem {
                    while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                    let t = CMTime(value: frameIndex, timescale: fps)
                    if !adaptor.append(buffer, withPresentationTime: t) { throw writer.error ?? RenderError.writer("append") }
                    frameIndex += 1
                }
                items.append(RenderedItem(assetID: asset.id, included: true, shortfall: shortfall, scaleFactor: member.scaleFactor, error: nil))
            } catch {
                log.note("render-item-failed", "group \(group.index) \(variant.rawValue) \(asset.shortID): \(error)")
                items.append(RenderedItem(assetID: asset.id, included: false, shortfall: shortfall, scaleFactor: member.scaleFactor, error: "\(error)"))
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let e = writer.error { throw e }
        let seconds = Double(frameIndex) / Double(fps)
        log.line("clip \(url.lastPathComponent): \(items.filter { $0.included }.count)/\(items.count) items, \(String(format: "%.0f", seconds)) s")
        return RenderedClip(groupIndex: group.index, variant: variant.rawValue, ordering: ordering, path: url.path, items: items, seconds: seconds)
    }

    /// Apply the y-down homography to a y-up CIImage and composite over black.
    func composite(source: CIImage, native: (Int, Int), h: Homography) throws -> CIImage {
        let H = Double(native.1), FH = Double(frame.height)
        let flipS = Homography(m: [1, 0, 0, 0, -1, H, 0, 0, 1])     // y-up → y-down (source)
        let flipO = Homography(m: [1, 0, 0, 0, -1, FH, 0, 0, 1])    // y-down → y-up (output)
        let hci = flipO * h * flipS
        var img = source
        if hci.isAffine {
            img = img.transformed(by: hci.affine)
        } else {
            let W = Double(native.0)
            guard let f = CIFilter(name: "CIPerspectiveTransform") else { throw RenderError.writer("CIPerspectiveTransform") }
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(CIVector(cgPoint: hci.apply(CGPoint(x: 0, y: H))), forKey: "inputTopLeft")
            f.setValue(CIVector(cgPoint: hci.apply(CGPoint(x: W, y: H))), forKey: "inputTopRight")
            f.setValue(CIVector(cgPoint: hci.apply(CGPoint(x: 0, y: 0))), forKey: "inputBottomLeft")
            f.setValue(CIVector(cgPoint: hci.apply(CGPoint(x: W, y: 0))), forKey: "inputBottomRight")
            guard let out = f.outputImage else { throw RenderError.writer("perspective output") }
            img = out
        }
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: frame.rect)
        return img.cropped(to: frame.rect).composited(over: black)
    }

    func burnCaption(_ text: String, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let w = CVPixelBufferGetWidth(buffer), hgt = CVPixelBufferGetHeight(buffer)
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let ctx = CGContext(data: base, width: w, height: hgt, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: ImageLoader.srgb, bitmapInfo: info.rawValue) else { return }
        // Flip to top-left origin for the shared text helper.
        ctx.translateBy(x: 0, y: CGFloat(hgt))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fill(CGRect(x: 0, y: CGFloat(hgt) - 40, width: CGFloat(w), height: 40))
        ContactSheet.drawText(text, at: CGPoint(x: 16, y: CGFloat(hgt) - 14), size: 20, ctx: ctx, colour: CGColor(gray: 1, alpha: 1))
        // Target-size reference ring/box at frame centre (thin, so it never hides the shape).
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.7, blue: 0.25, alpha: 0.35))
        ctx.setLineWidth(1)
        let t = CGFloat(targetFraction) * CGFloat(hgt)
        ctx.strokeEllipse(in: CGRect(x: CGFloat(w) / 2 - t / 2, y: CGFloat(hgt) / 2 - t / 2, width: t, height: t))
    }

    static func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        return ImageLoader.ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: ImageLoader.srgb)
    }

    enum RenderError: Error, CustomStringConvertible {
        case writer(String)
        var description: String { switch self { case .writer(let s): return "writer: \(s)" } }
    }
}

/// Native CIImages, held for the life of one group's renders (each asset is loaded once per group).
actor ImageCache {
    private var images: [String: CIImage] = [:]
    private var order: [String] = []
    let capacity: Int
    init(capacity: Int = 8) { self.capacity = capacity }

    func image(for asset: Asset) async throws -> CIImage {
        if let i = images[asset.id] { return i }
        let img = try await ImageLoader.loadCIImage(asset: asset)
        images[asset.id] = img
        order.append(asset.id)
        if order.count > capacity { images[order.removeFirst()] = nil }
        return img
    }
    func clear() { images.removeAll(); order.removeAll() }
}
