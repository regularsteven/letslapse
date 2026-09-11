import Foundation

/// `groups/report.md` — verdict first, then the numbers the brief asks for.
enum ReportWriter {
    static func write(out: URL, inventory: Inventory, detections: DetectionFile, groups: GroupsFile?, render: [RenderFile], log: RunLog) throws {
        var md = ""
        let assetsByID = Dictionary(uniqueKeysWithValues: inventory.assets.map { ($0.id, $0) })
        let accepted = detections.records.filter { $0.accepted }
        let dominant = Grouper.dominantAnchors(detections.records)
        let ellipseAssets = Set(dominant.filter { $0.kind == .ellipse }.map { $0.assetID })
        let quadAssets = Set(dominant.filter { $0.kind == .quad }.map { $0.assetID })
        let anyAnchor = ellipseAssets.union(quadAssets)
        let viable = (groups?.groups ?? []).filter { !$0.nearMiss }
        let largestEllipse = viable.filter { $0.kind == .ellipse }.max { $0.members.count < $1.members.count }
        let largestQuad = viable.filter { $0.kind == .quad }.max { $0.members.count < $1.members.count }
        let flag = groups?.settings.upscaleFlag ?? 2.0

        func pct(_ n: Int, _ d: Int) -> String { d > 0 ? String(format: "%.0f%%", Double(n) / Double(d) * 100) : "–" }
        func f2(_ x: Double) -> String { String(format: "%.2f", x) }

        md += "# Shape Sequence spike — report\n\n"
        md += "Generated \(ISO8601DateFormatter().string(from: Date())) from `\(inventory.catalogue)`.\n\n"

        // ---- Verdict ----
        md += "## Verdict\n\n"
        let scanned = inventory.assets.count
        md += "\(scanned) shoots scanned (\(inventory.skipped.count) skipped). "
        md += "\(anyAnchor.count) of \(scanned) (\(pct(anyAnchor.count, scanned))) carry at least one accepted anchor — "
        md += "\(ellipseAssets.count) ellipses, \(quadAssets.count) quads.\n\n"
        if let g = largestEllipse {
            let over = g.members.filter { $0.requiredUpscale > flag }.count
            md += "- **Ellipses:** largest viable group is \(g.members.count) items (\(g.label)); \(over) of them need more than \(f2(flag))× upscale.\n"
        } else {
            md += "- **Ellipses:** no group of \(groups?.settings.minGroupSize ?? 4) or more — the catalogue does not currently support an ellipse sequence.\n"
        }
        if let g = largestQuad {
            let over = g.members.filter { $0.requiredUpscale > flag }.count
            md += "- **Quads:** largest viable group is \(g.members.count) items (\(g.label)); \(over) of them need more than \(f2(flag))× upscale.\n"
        } else {
            md += "- **Quads:** no group of \(groups?.settings.minGroupSize ?? 4) or more.\n"
        }
        md += "\nWhether the aligned result *reads* as a held shape is a judgement for the proof clips in `clips/`; the numbers below say what the catalogue contains, not how it looks. The human review verdict is appended in the docs copy of this report.\n\n"

        // ---- Inventory ----
        md += "## Inventory\n\n"
        md += "| | count |\n|---|---|\n"
        md += "| shoots with a representative image | \(scanned) |\n"
        for f in [AssetFamily.still, .interval] { md += "| · \(f.rawValue) | \(inventory.assets.filter { $0.family == f }.count) |\n" }
        for s in [RepresentativeSource.blendImage, .blendVideo, .renderedFrame, .rawDecode] {
            md += "| · representative from \(s.rawValue) | \(inventory.assets.filter { $0.representativeSource == s }.count) |\n"
        }
        md += "| unlisted folders used | \(inventory.assets.filter { !$0.listedInManifest }.count) |\n"
        let skipReasons = Dictionary(grouping: inventory.skipped, by: { $0.reason }).mapValues { $0.count }
        for (r, n) in skipReasons.sorted(by: { $0.key < $1.key }) { md += "| skipped: \(r) | \(n) |\n" }
        md += "\n"
        let logCounts = log.counts.sorted { $0.key < $1.key }
        if !logCounts.isEmpty {
            md += "Run-log anomaly counts: " + logCounts.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ".\n\n"
        }

        // ---- Detection ----
        md += "## Detection\n\n"
        md += "Settings: detection long edge \(detections.settings.detectionLongEdge) px; min native diameter max(\(Int(detections.settings.minNativeDiameterPx)) px, short edge ÷ \(Int(1 / detections.settings.minDiameterFractionOfShortEdge))); "
        md += "ellipse residual ≤ \(f2(detections.settings.maxFitResidual)), coverage ≥ \(f2(detections.settings.minCoverage)), minor/major ≥ \(f2(detections.settings.minObliquity)); "
        md += "contours at contrast \(detections.settings.contrastAdjustments.map { "\($0)" }.joined(separator: "/")) × dark-on-light/light-on-dark; "
        md += "rectangles conf ≥ \(detections.settings.rectMinimumConfidence), aspect ≥ \(detections.settings.rectMinimumAspectRatio), quadrature \(Int(detections.settings.rectQuadratureTolerance))°.\n\n"
        let failed = detections.perAsset.filter { !$0.detected }
        md += "| | ellipse | quad |\n|---|---|---|\n"
        md += "| assets with ≥1 accepted anchor | \(ellipseAssets.count) | \(quadAssets.count) |\n"
        md += "| accepted anchors (before one-per-asset) | \(accepted.filter { $0.anchor.kind == .ellipse }.count) | \(accepted.filter { $0.anchor.kind == .quad }.count) |\n"
        md += "| candidates recorded | \(detections.records.filter { $0.anchor.kind == .ellipse }.count) | \(detections.records.filter { $0.anchor.kind == .quad }.count) |\n"
        md += "\nDetector failures: \(failed.count)" + (failed.isEmpty ? "" : " — " + failed.map { "\($0.assetID.prefix(8)) (\($0.error ?? "?"))" }.joined(separator: ", ")) + ".\n"
        let ms = detections.perAsset.map { $0.elapsedMs }
        if !ms.isEmpty { md += "Detection time per asset: median \(ms.sorted()[ms.count / 2]) ms, max \(ms.max()!) ms (includes the representative decode).\n\n" }

        md += "### Rejection breakdown\n\n"
        for kind in [ShapeAnchor.Kind.ellipse, .quad] {
            let rej = detections.records.filter { !$0.accepted && $0.anchor.kind == kind }
            let byReason = Dictionary(grouping: rej, by: { $0.rejection ?? "?" }).mapValues { $0.count }.sorted { $0.value > $1.value }
            md += "**\(kind.rawValue)** — \(rej.count) rejected"
            if kind == .ellipse {
                let pre = detections.perAsset.reduce(0) { $0 + max(0, $1.candidates) }
                md += " (plus contours dropped by the bounding-box prefilter before fitting: see `anchors.json` perAsset.candidates; total candidates reaching a record \(pre))"
            }
            md += ":\n\n"
            if byReason.isEmpty { md += "_none_\n\n" } else {
                md += "| reason | count |\n|---|---|\n"
                for (r, n) in byReason { md += "| \(r) | \(n) |\n" }
                md += "\n"
            }
        }
        md += "Reason glossary: `too-few-points` contour under 24 points; `polygonal` ≤6 vertices after polygon approximation; `fit-failed` no ellipse solution; `open` end points further apart than 5% of the major axis; `residual` mean radial error over 3% of the axis; `coverage` contour spans under 70% of the fitted circumference (arcs); `obliquity` minor/major under 0.25; `too-small` native diameter under the resolution gate; `image-border` the frame itself; `centre-outside` fit centre off-image; `duplicate` heavy overlap with a better-fitting accepted shape.\n\n"

        // ---- Per-asset table (accepted only) ----
        md += "### Accepted anchors per asset\n\n"
        md += "| asset | source | native | kind | ⌀ native px | obliquity | conf |\n|---|---|---|---|---|---|---|\n"
        for a in dominant.sorted(by: { ($0.assetID, $0.kind.rawValue) < ($1.assetID, $1.kind.rawValue) }) {
            guard let asset = assetsByID[a.assetID] else { continue }
            md += "| \(asset.shortID) | \(asset.representativeSource.rawValue) | \(asset.nativeWidth)×\(asset.nativeHeight) | \(a.kind.rawValue) | \(Int(a.nativeDiameterPx)) | \(f2(a.groupingObliquity)) | \(f2(Double(a.confidence))) |\n"
        }
        md += "\n"

        // ---- Groups ----
        if let groups {
            md += "## Groups\n\n"
            md += "Target: major axis = \(Int(groups.settings.targetFractionOfHeight * 100))% of \(groups.settings.outputHeight) px frame height (\(Int(groups.settings.targetFractionOfHeight * Double(groups.settings.outputHeight))) px). Minimum group \(groups.settings.minGroupSize), cap \(groups.settings.maxGroupSize). Scale factor = output px per native px; over \(f2(flag))× is flagged.\n\n"
            md += "| # | group | n | scale min / median / max | > \(f2(flag))× | edge-excluded centred / aligned | note |\n|---|---|---|---|---|---|---|\n"
            for g in groups.groups {
                let s = g.members.map { $0.scaleFactor }.sorted()
                let over = g.members.filter { $0.requiredUpscale > flag }.count
                let exC = g.members.filter { $0.coverageCentred < 0.995 }.count
                let exA = g.members.filter { $0.coverageAligned < 0.995 }.count
                var note = g.nearMiss ? "near-miss (3), not rendered" : ""
                if let t = g.truncatedFrom { note += (note.isEmpty ? "" : "; ") + "truncated from \(t)" }
                if let m = g.medianAspect { note += (note.isEmpty ? "" : "; ") + "median w/h \(f2(m))" }
                md += "| \(g.index) | \(g.label) | \(g.members.count) | \(f2(s.first ?? 0)) / \(f2(Grouper.median(s) ?? 0)) / \(f2(s.last ?? 0)) | \(over) | \(exC) / \(exA) | \(note) |\n"
            }
            md += "\n"
            for g in groups.groups where !g.nearMiss {
                md += "### Group \(g.index): \(g.label)\n\n"
                md += "| order | asset | captured | ⌀ native | scale | obliquity | cover centred | cover aligned |\n|---|---|---|---|---|---|---|---|\n"
                let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
                for (i, m) in g.members.enumerated() {
                    let a = assetsByID[m.assetID]
                    md += "| \(i + 1) | \(a?.shortID ?? m.assetID) | \(df.string(from: m.capturedAt)) | \(Int(m.anchor.nativeDiameterPx)) | \(f2(m.scaleFactor))\(m.requiredUpscale > flag ? " ⚠" : "") | \(f2(m.anchor.groupingObliquity)) | \(pct(Int(m.coverageCentred * 1000), 1000)) | \(pct(Int(m.coverageAligned * 1000), 1000)) |\n"
                }
                md += "\n"
            }
        }

        // ---- Render ----
        if !render.isEmpty {
            md += "## Proof clips\n\n"
            md += "1920×1080 H.264 30 fps unless the pass says otherwise, hard cuts, no blending; caption per frame = asset · native ⌀ · scale · obliquity · variant.\n\n"
            for pass in render {
                md += "### Render pass: edge policy `\(pass.edgePolicy)`, rotation `\(pass.rotation)`\(pass.tag.isEmpty ? "" : ", tag `\(pass.tag)`")\n\n"
                md += "| clip | group | variant | order | items in / out | seconds |\n|---|---|---|---|---|---|\n"
                for c in pass.clips {
                    md += "| \((c.path as NSString).lastPathComponent) | \(c.groupIndex) | \(c.variant) | \(c.ordering) | \(c.items.filter { $0.included }.count) / \(c.items.filter { !$0.included }.count) | \(Int(c.seconds)) |\n"
                }
                let excluded = pass.clips.flatMap { c in c.items.filter { !$0.included }.map { (c, $0) } }
                md += "\nItems excluded by the edge policy or errors: \(excluded.count).\n"
                if !excluded.isEmpty && pass.edgePolicy == "exclude" {
                    let byAsset = Dictionary(grouping: excluded, by: { $0.1.assetID })
                    md += "Distinct assets excluded: \(byAsset.count); shortfall range \(String(format: "%.0f%%", (excluded.map { $0.1.shortfall }.min() ?? 0) * 100))–\(String(format: "%.0f%%", (excluded.map { $0.1.shortfall }.max() ?? 0) * 100)) of the frame.\n"
                }
                md += "\n"
            }
        }

        md += "## Method notes\n\n"
        md += "- One representative image per shoot: rendered blend (image, or the mid frame of a blend clip) → rendered source frame (middle of the run) → RAW decode as a last resort (logged per asset).\n"
        md += "- Ellipses: Vision contours (6 passes) → polygon-approximation reject → direct least-squares conic fit (Halir–Flusser) → gates. Quads: `VNDetectRectanglesRequest`.\n"
        md += "- Un-skew (aligned variant): ellipses get the affine stretch that maps the fitted ellipse onto a circle (no camera intrinsics assumed); quads get the full homography onto a rectangle of the group's median width/height, which also levels them.\n"
        md += "- Rotation: ellipses rotate their major axis to horizontal (`--rotation major`, the brief's rule) or keep the world upright (`--rotation none`); quads always level their top edge rather than laying a doorway on its side.\n"
        md += "- Coverage = fraction of the output frame that receives source pixels under the item's transform; the default edge policy excludes anything under 99.5%.\n"

        let url = out.appendingPathComponent("groups/report.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try md.write(to: url, atomically: true, encoding: .utf8)
        log.line("report: \(url.path)")
    }
}
