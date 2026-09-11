import Foundation
import ArgumentParser
import CoreGraphics
import CoreImage

@main
struct ShapeSeq: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shapeseq",
        abstract: "Shape Sequence spike — find co-shaped shoots in a LetsLapse catalogue and render proof clips.",
        subcommands: [Run.self, SelfTest.self],
        defaultSubcommand: Run.self)
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Full pipeline, or one stage reading the previous stage's JSON.")

    @Option(help: "LetsLapse storage root (…/LetsLapse) or its Projects folder.") var catalogue: String
    @Option(help: "Tool-owned working directory for every output.") var out: String
    @Option(help: "Stage to run: all | detect | sheets | group | render.") var stage: String = "all"
    @Option(help: "Only the first N shoots (iteration aid).") var limit: Int?
    @Option(name: .customLong("only"), parsing: .upToNextOption, help: "Only shoots whose id starts with one of these prefixes.") var only: [String] = []
    @Option(help: "Shape major axis as a fraction of output frame height.") var targetFraction: Double = 0.4
    @Option(help: "Output frame width.") var frameWidth: Int = 1920
    @Option(help: "Output frame height.") var frameHeight: Int = 1080
    @Option(help: "Seconds each item holds.") var secondsPerItem: Double = 1.0
    @Option(help: "exclude | letterbox — what to do when the crop exceeds the source.") var edgePolicy: String = "exclude"
    @Option(help: "major | none — ellipse rotation rule for the render.") var rotation: String = "major"
    @Option(help: "Minimum group size.") var minGroup: Int = 4
    @Option(help: "Maximum group size for render.") var maxGroup: Int = 30
    @Option(help: "Parallel detections.") var concurrency: Int = 4
    @Option(help: "Vision contour tracer resolution (maximumImageDimension).") var contourDimension: Int = 512
    @Option(name: .customLong("edge-thresholds"), parsing: .upToNextOption, help: "CIEdges thresholds for the edge-map passes (none = region contours only).") var edgeThresholds: [Float] = [0.06, 0.15]
    @Flag(help: "Write the edge maps to <out>/cache/edges for inspection.") var dumpEdges = false
    @Option(help: "Re-gate recorded ellipse candidates at this residual (sheets/group/render stages; detection stays at the brief's 0.03).") var residualGate: Double?
    @Flag(help: "Also render the size-ordered variant for every group, not just the per-kind 'all' groups.") var sizeOrderAll = false
    @Option(name: .customLong("groups"), parsing: .upToNextOption, help: "Render only these group indices.") var groupFilter: [Int] = []
    @Flag(help: "Also write each rendered item's frame as PNG under clips/frames/.") var dumpFrames = false
    @Option(help: "Suffix for clip names and the render-results file, so several render passes (edge policies, rotation rules) can coexist.") var clipTag: String = ""

    func run() async throws {
        let outURL = URL(fileURLWithPath: out).standardizedFileURL
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        let log = RunLog(url: outURL.appendingPathComponent("run-log.txt"))
        defer { log.close() }
        let stages = stage == "all" ? ["detect", "group", "render"] : [stage]
        guard let policy = EdgePolicy(rawValue: edgePolicy) else { throw ValidationError("--edge-policy must be exclude or letterbox") }
        guard let rot = RotationMode(rawValue: rotation) else { throw ValidationError("--rotation must be major or none") }
        let inventoryURL = outURL.appendingPathComponent("detections/inventory.json")
        let anchorsURL = outURL.appendingPathComponent("detections/anchors.json")
        let groupsURL = outURL.appendingPathComponent("groups/groups.json")
        let tag = clipTag.isEmpty ? "" : "-\(clipTag)"
        let renderURL = outURL.appendingPathComponent("clips/render-results\(tag).json")

        if stages.contains("detect") {
            let inventory = await InventoryBuilder.build(catalogue: URL(fileURLWithPath: catalogue), log: log, limit: limit, only: only)
            log.line("inventory: \(inventory.assets.count) assets, \(inventory.skipped.count) skipped")
            try JSONIO.write(inventory, to: inventoryURL)
            let detections = try await detect(inventory: inventory, out: outURL, log: log)
            try JSONIO.write(detections, to: anchorsURL)
            try ReportWriter.write(out: outURL, inventory: inventory, detections: detections, groups: nil, render: [], log: log)
        }
        func loadDetections(_ inventory: Inventory) throws -> DetectionFile {
            var detections = try JSONIO.read(DetectionFile.self, from: anchorsURL)
            if let g = residualGate {
                detections.records = Grouper.regate(detections.records, inventory: inventory, settings: detections.settings, residual: g)
                detections.settings.maxFitResidual = g
                log.line("re-gated ellipse candidates at residual ≤ \(g): \(detections.records.filter { $0.accepted && $0.anchor.kind == .ellipse }.count) accepted")
            }
            return detections
        }
        if stages.contains("sheets") {
            let inventory = try JSONIO.read(Inventory.self, from: inventoryURL)
            let detections = try loadDetections(inventory)
            var thumbs: [String: CGImage] = [:]
            for a in inventory.assets {
                if let t = ImageLoader.loadPNG(outURL.appendingPathComponent("cache/reps/\(a.id).jpg")) { thumbs[a.id] = t }
            }
            try writeSheets(inventory: inventory, thumbs: thumbs, records: detections.records, out: outURL, log: log)
        }
        if stages.contains("group") {
            let inventory = try JSONIO.read(Inventory.self, from: inventoryURL)
            let detections = try loadDetections(inventory)
            var gs = GroupSettings()
            gs.minGroupSize = minGroup; gs.maxGroupSize = maxGroup
            gs.outputWidth = frameWidth; gs.outputHeight = frameHeight; gs.targetFractionOfHeight = targetFraction
            let groups = Grouper.group(inventory: inventory, records: detections.records, settings: gs, rotation: rot, log: log)
            try JSONIO.write(groups, to: groupsURL)
            // Any earlier render results describe groups that no longer exist.
            for f in (try? FileManager.default.contentsOfDirectory(at: outURL.appendingPathComponent("clips"), includingPropertiesForKeys: nil)) ?? []
                where f.lastPathComponent.hasPrefix("render-results") { try? FileManager.default.removeItem(at: f) }
            try ReportWriter.write(out: outURL, inventory: inventory, detections: detections, groups: groups, render: [], log: log)
        }
        if stages.contains("render") {
            let inventory = try JSONIO.read(Inventory.self, from: inventoryURL)
            let detections = try loadDetections(inventory)
            let groups = try JSONIO.read(GroupsFile.self, from: groupsURL)
            let assets = Dictionary(uniqueKeysWithValues: inventory.assets.map { ($0.id, $0) })
            let frame = AnchorTransform.Frame(width: groups.settings.outputWidth, height: groups.settings.outputHeight)
            let renderer = ClipRenderer(frame: frame, secondsPerItem: secondsPerItem, targetFraction: groups.settings.targetFractionOfHeight,
                                        edgePolicy: policy, rotation: rot, log: log)
            if dumpFrames { renderer.frameDumpDir = outURL.appendingPathComponent("clips/frames") }
            var results = RenderFile(edgePolicy: policy.rawValue, clips: [], tag: clipTag, rotation: rot.rawValue)
            for g in groups.groups where !g.nearMiss && (groupFilter.isEmpty || groupFilter.contains(g.index)) {
                let cache = ImageCache(capacity: min(g.members.count, 32))
                for variant in RenderVariant.allCases {
                    let name = String(format: "group-%02d-%@%@.mov", g.index, variant.rawValue, tag)
                    do {
                        results.clips.append(try await renderer.render(group: g, variant: variant, ordering: "chrono", assets: assets, imageCache: cache, to: outURL.appendingPathComponent("clips/\(name)")))
                    } catch { log.note("render-failed", "\(name): \(error)") }
                }
                if g.bucket == nil || sizeOrderAll {
                    let name = String(format: "group-%02d-centred-sizeorder%@.mov", g.index, tag)
                    do {
                        results.clips.append(try await renderer.render(group: g, variant: .centred, ordering: "size", assets: assets, imageCache: cache, to: outURL.appendingPathComponent("clips/\(name)")))
                    } catch { log.note("render-failed", "\(name): \(error)") }
                }
                await cache.clear()
                try JSONIO.write(results, to: renderURL)
            }
            try ReportWriter.write(out: outURL, inventory: inventory, detections: detections, groups: groups, render: loadAllRenderResults(outURL), log: log)
        }
    }

    func loadAllRenderResults(_ out: URL) -> [RenderFile] {
        let dir = out.appendingPathComponent("clips")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("render-results") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.compactMap { try? JSONIO.read(RenderFile.self, from: $0) }
    }

    /// Detection stage: decode each representative at ≤1024 px, run the detector, cache the thumb, tile the sheets.
    func detect(inventory: Inventory, out: URL, log: RunLog) async throws -> DetectionFile {
        var service = ShapeDetectionService()
        service.settings.contourImageDimension = contourDimension
        service.settings.edgeThresholds = edgeThresholds
        if dumpEdges {
            let dir = out.appendingPathComponent("cache/edges")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            service.dumpEdgesTo = dir
        }
        let repsDir = out.appendingPathComponent("cache/reps")
        try FileManager.default.createDirectory(at: repsDir, withIntermediateDirectories: true)
        var records: [DetectionRecord] = []
        var summaries: [AssetDetectionSummary] = []
        var thumbs: [String: CGImage] = [:]

        struct Outcome { let asset: Asset; let thumb: CGImage?; let result: ShapeDetectionService.Result?; let error: String?; let ms: Int }
        var outcomes: [Outcome] = []
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            var iterator = inventory.assets.makeIterator()
            var inFlight = 0
            func submit(_ asset: Asset) {
                group.addTask {
                    let t0 = Date()
                    do {
                        let img = try await ImageLoader.loadCGImage(asset: asset, maxLongEdge: service.settings.detectionLongEdge)
                        let r = try service.detect(in: img, native: (asset.nativeWidth, asset.nativeHeight), assetID: asset.id)
                        return Outcome(asset: asset, thumb: img, result: r, error: nil, ms: Int(Date().timeIntervalSince(t0) * 1000))
                    } catch {
                        return Outcome(asset: asset, thumb: nil, result: nil, error: "\(error)", ms: Int(Date().timeIntervalSince(t0) * 1000))
                    }
                }
                inFlight += 1
            }
            while inFlight < max(1, concurrency), let a = iterator.next() { submit(a) }
            while let o = try await group.next() {
                inFlight -= 1
                outcomes.append(o)
                if let r = o.result {
                    let ne = r.records.filter { $0.accepted && $0.anchor.kind == .ellipse }.count
                    let nq = r.records.filter { $0.accepted && $0.anchor.kind == .quad }.count
                    log.line("detect \(o.asset.shortID) [\(o.asset.representativeSource.rawValue)] \(o.asset.nativeWidth)×\(o.asset.nativeHeight): E\(ne) Q\(nq) of \(r.records.count) candidates (\(r.contoursSeen) contours, \(r.prefilteredTooSmall) prefiltered) \(o.ms) ms [rect \(r.rectMs) ms, contours \(r.passMs.map(String.init).joined(separator: "/")) ms]")
                } else {
                    log.note("detect-failed", "\(o.asset.shortID): \(o.error ?? "?")")
                }
                if let a = iterator.next() { submit(a) }
            }
        }
        // Keep inventory order for the sheets.
        let byID = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.asset.id, $0) })
        for asset in inventory.assets {
            guard let o = byID[asset.id] else { continue }
            if let t = o.thumb {
                thumbs[asset.id] = t
                try? ImageLoader.writeJPEG(t, to: repsDir.appendingPathComponent("\(asset.id).jpg"))
            }
            if let r = o.result {
                records += r.records
                summaries.append(AssetDetectionSummary(assetID: asset.id, detected: true, error: nil, elapsedMs: o.ms,
                                                       acceptedEllipses: r.records.filter { $0.accepted && $0.anchor.kind == .ellipse }.count,
                                                       acceptedQuads: r.records.filter { $0.accepted && $0.anchor.kind == .quad }.count,
                                                       candidates: r.records.count))
            } else {
                summaries.append(AssetDetectionSummary(assetID: asset.id, detected: false, error: o.error, elapsedMs: o.ms, acceptedEllipses: 0, acceptedQuads: 0, candidates: 0))
            }
        }
        try writeSheets(inventory: inventory, thumbs: thumbs, records: records, out: out, log: log)
        return DetectionFile(settings: service.settings, records: records, perAsset: summaries)
    }

    /// Contact sheets, 40 per sheet, in inventory order.
    func writeSheets(inventory: Inventory, thumbs: [String: CGImage], records: [DetectionRecord], out: URL, log: RunLog) throws {
        let per = ContactSheet.perSheet
        var sheet = 0
        var i = 0
        while i < inventory.assets.count {
            let slice = Array(inventory.assets[i..<min(i + per, inventory.assets.count)])
            sheet += 1
            let url = out.appendingPathComponent(String(format: "detections/contact-sheet-%02d.png", sheet))
            try ContactSheet.render(assets: slice, thumbs: thumbs, records: records, to: url)
            log.line("contact sheet \(url.lastPathComponent): \(slice.count) assets")
            i += per
        }
    }
}

/// Synthetic check of the fit, the coordinate conventions and the render transform.
struct SelfTest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest", abstract: "Draw a known ellipse and quad, detect them, and check the recovered geometry.")
    @Option(help: "Directory for the synthetic image and the transformed outputs.") var out: String

    func run() async throws {
        let outURL = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        let log = RunLog(url: outURL.appendingPathComponent("selftest-log.txt"))
        defer { log.close() }
        let W = 3000, H = 2000
        // Truth (y-down pixel coords): ellipse centre (1000, 800), semi axes 500/300, rotation 25°.
        let ec = CGPoint(x: 1000, y: 800), ea = 500.0, eb = 300.0, er = 25.0 * Double.pi / 180
        // Quad: a perspective doorway on the right.
        let quad = [CGPoint(x: 1900, y: 400), CGPoint(x: 2600, y: 520), CGPoint(x: 2600, y: 1500), CGPoint(x: 1900, y: 1650)]
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: ImageLoader.srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)    // top-left origin
        ctx.setFillColor(CGColor(srgbRed: 0.75, green: 0.8, blue: 0.85, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        // Background texture so a rotation is visible.
        ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.6, blue: 0.7, alpha: 1))
        for y in stride(from: 0, to: H, by: 200) { ctx.fill(CGRect(x: 0, y: y, width: W, height: 40)) }
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        ctx.saveGState(); ctx.translateBy(x: ec.x, y: ec.y); ctx.rotate(by: er)
        ctx.fillEllipse(in: CGRect(x: -ea, y: -eb, width: 2 * ea, height: 2 * eb)); ctx.restoreGState()
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.9, alpha: 1))
        ctx.move(to: quad[0]); for p in quad.dropFirst() { ctx.addLine(to: p) }; ctx.closePath(); ctx.fillPath()
        ctx.setStrokeColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1)); ctx.setLineWidth(12)
        ctx.move(to: quad[0]); for p in quad.dropFirst() { ctx.addLine(to: p) }; ctx.closePath(); ctx.strokePath()
        guard let img = ctx.makeImage() else { return }
        let srcURL = outURL.appendingPathComponent("selftest-source.png")
        try ImageLoader.writePNG(img, to: srcURL)

        let service = ShapeDetectionService()
        let r = try service.detect(in: img, native: (W, H), assetID: "selftest")
        let accepted = r.records.filter { $0.accepted }
        log.line("candidates \(r.records.count), accepted \(accepted.count), contours \(r.contoursSeen)")
        for rec in accepted {
            let a = rec.anchor
            let cx = Double(a.centre.x) * Double(W), cy = Double(a.centre.y) * Double(H)
            switch a.kind {
            case .ellipse:
                let semiA = Double(a.majorAxis) * Double(W) / 2, semiB = Double(a.minorAxis) * Double(W) / 2
                log.line(String(format: "ellipse: centre (%.1f, %.1f) vs (%.0f, %.0f); a %.1f vs %.0f; b %.1f vs %.0f; rot %.2f° vs %.0f°; residual %.4f coverage %.2f",
                                cx, cy, ec.x, ec.y, semiA, ea, semiB, eb, Double(a.rotation) * 180 / .pi, er * 180 / .pi, rec.fitResidual ?? -1, rec.coverage ?? -1))
            case .quad:
                let c = a.corners!.map { CGPoint(x: $0.x * CGFloat(W), y: $0.y * CGFloat(H)) }
                log.line("quad: corners " + c.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) }.joined(separator: " ") + " vs " + quad.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) }.joined(separator: " ") + String(format: "  skew %.2f aspect %.2f conf %.2f", a.quadSkew, AnchorTransform.quadAspect(a), a.confidence))
            }
        }
        for (r, n) in Dictionary(grouping: r.records.filter { !$0.accepted }, by: { $0.rejection ?? "?" }).mapValues({ $0.count }).sorted(by: { $0.value > $1.value }) {
            log.line("rejected \(r): \(n)")
        }
        // Render every accepted anchor both ways to PNG.
        let frame = AnchorTransform.Frame(width: 1920, height: 1080)
        let renderer = ClipRenderer(frame: frame, secondsPerItem: 1, targetFraction: 0.4, edgePolicy: .letterbox, rotation: .major, log: log)
        let source = CIImage(cgImage: img)
        var dummy = [String: Asset]()
        _ = dummy
        for (i, rec) in accepted.enumerated() {
            for variant in RenderVariant.allCases {
                guard let h = AnchorTransform.homography(anchor: rec.anchor, native: (W, H), frame: frame, targetFraction: 0.4, variant: variant, rotation: .major, medianAspect: nil) else { continue }
                let cov = AnchorTransform.coverage(h, native: (W, H), frame: frame)
                let out = try renderer.composite(source: source, native: (W, H), h: h)
                guard let cg = ImageLoader.ciContext.createCGImage(out, from: frame.rect, format: .RGBA8, colorSpace: ImageLoader.srgb) else { continue }
                let name = "selftest-\(i)-\(rec.anchor.kind.rawValue)-\(variant.rawValue).png"
                try ImageLoader.writePNG(cg, to: outURL.appendingPathComponent(name))
                // Where did the anchor centre land?
                let cx = Double(rec.anchor.centre.x) * Double(W), cy = Double(rec.anchor.centre.y) * Double(H)
                let landed = h.apply(CGPoint(x: cx, y: cy))
                log.line(String(format: "%@: centre → (%.1f, %.1f) expected (960, 540); coverage %.3f; affine %@", name, landed.x, landed.y, cov, h.isAffine ? "yes" : "no"))
            }
        }
        dummy = [:]
    }
}
