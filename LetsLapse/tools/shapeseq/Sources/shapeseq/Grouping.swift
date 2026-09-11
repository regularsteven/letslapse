import Foundation

enum Grouper {
    /// Re-apply the ellipse gates with a different residual threshold, from the recorded
    /// candidates (no re-detection): the other gates and the overlap dedupe are re-run too.
    /// Quads are left as detected.
    static func regate(_ records: [DetectionRecord], inventory: Inventory, settings: DetectionSettings, residual: Double) -> [DetectionRecord] {
        let assets = Dictionary(uniqueKeysWithValues: inventory.assets.map { ($0.id, $0) })
        var out: [DetectionRecord] = records.filter { $0.anchor.kind == .quad }
        var candidates: [String: [DetectionRecord]] = [:]
        for r in records where r.anchor.kind == .ellipse {
            guard let res = r.fitResidual, let cov = r.coverage, let asset = assets[r.anchor.assetID] else { out.append(r); continue }
            let a = r.anchor
            let minD = max(settings.minNativeDiameterPx, Double(min(asset.nativeWidth, asset.nativeHeight)) * settings.minDiameterFractionOfShortEdge)
            var reason: String? = nil
            if res > residual { reason = "residual" }
            else if cov < settings.minCoverage { reason = "coverage" }
            else if Double(a.obliquity) < settings.minObliquity { reason = "obliquity" }
            else if Double(a.nativeDiameterPx) < minD { reason = "too-small" }
            else if a.centre.x < 0 || a.centre.x > 1 || a.centre.y < 0 || a.centre.y > 1 { reason = "centre-outside" }
            let W = Double(asset.nativeWidth), H = Double(asset.nativeHeight)
            if reason == nil, Double(a.majorAxis) * W > 0.97 * max(W, H), Double(a.minorAxis) * W > 0.97 * min(W, H) { reason = "image-border" }
            let rec = DetectionRecord(anchor: a, accepted: reason == nil, rejection: reason, fitResidual: res, coverage: cov, pass: r.pass, pointCount: r.pointCount)
            candidates[a.assetID, default: []].append(rec)
        }
        for (_, recs) in candidates {
            let acc = recs.filter { $0.accepted }.sorted { ($0.fitResidual ?? 1) < ($1.fitResidual ?? 1) }
            var kept: [DetectionRecord] = []
            for c in acc {
                if kept.contains(where: { bboxIoU($0.anchor, c.anchor) > 0.5 }) {
                    out.append(DetectionRecord(anchor: c.anchor, accepted: false, rejection: "duplicate", fitResidual: c.fitResidual, coverage: c.coverage, pass: c.pass, pointCount: c.pointCount))
                } else { kept.append(c) }
            }
            out += kept + recs.filter { !$0.accepted }
        }
        return out
    }

    static func bboxIoU(_ a: ShapeAnchor, _ b: ShapeAnchor) -> Double {
        func box(_ a: ShapeAnchor) -> CGRect {
            let c = cos(a.rotation), s = sin(a.rotation)
            let ax = a.majorAxis / 2, bx = a.minorAxis / 2
            let hw = sqrt(ax * ax * c * c + bx * bx * s * s), hh = sqrt(ax * ax * s * s + bx * bx * c * c)
            return CGRect(x: a.centre.x - hw, y: a.centre.y - hh, width: 2 * hw, height: 2 * hh)
        }
        let i = box(a).intersection(box(b))
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let ia = Double(i.width * i.height)
        let u = Double(box(a).width * box(a).height + box(b).width * box(b).height) - ia
        return u > 0 ? ia / u : 0
    }

    static func obliquityBucket(_ o: Double) -> String {
        if o >= 0.85 { return "head-on" }
        if o >= 0.5 { return "moderate" }
        return "oblique"
    }
    static func aspectBucket(_ wh: Double) -> String {
        if wh > 1.25 { return "wide" }
        if wh < 0.8 { return "tall" }
        return "square"
    }

    /// One dominant accepted anchor per asset per kind: the largest, then the most confident.
    static func dominantAnchors(_ records: [DetectionRecord]) -> [ShapeAnchor] {
        var best: [String: ShapeAnchor] = [:]
        for r in records where r.accepted {
            let key = "\(r.anchor.assetID)|\(r.anchor.kind.rawValue)"
            if let b = best[key] {
                if r.anchor.nativeDiameterPx > b.nativeDiameterPx * 1.02 ||
                    (abs(r.anchor.nativeDiameterPx - b.nativeDiameterPx) <= b.nativeDiameterPx * 0.02 && r.anchor.confidence > b.confidence) {
                    best[key] = r.anchor
                }
            } else { best[key] = r.anchor }
        }
        return Array(best.values)
    }

    static func group(inventory: Inventory, records: [DetectionRecord], settings: GroupSettings, rotation: RotationMode, log: RunLog) -> GroupsFile {
        let assets = Dictionary(uniqueKeysWithValues: inventory.assets.map { ($0.id, $0) })
        let anchors = dominantAnchors(records).filter { assets[$0.assetID] != nil }
        let frame = AnchorTransform.Frame(width: settings.outputWidth, height: settings.outputHeight)
        var groups: [ShapeGroup] = []
        var index = 0

        func make(label: String, bucket: String?, anchors: [ShapeAnchor], kind: ShapeAnchor.Kind) {
            guard anchors.count >= 3 else { return }
            var chosen = anchors
            var truncated: Int? = nil
            if chosen.count > settings.maxGroupSize {
                truncated = chosen.count
                chosen = Array(chosen.sorted { $0.confidence > $1.confidence }.prefix(settings.maxGroupSize))
                log.note("group-truncated", "\(label): \(anchors.count) → \(settings.maxGroupSize) by confidence")
            }
            let medianAspect: Double? = kind == .quad ? median(chosen.map { AnchorTransform.quadAspect($0) }) : nil
            var members: [GroupMember] = []
            for a in chosen {
                let asset = assets[a.assetID]!
                let native = (asset.nativeWidth, asset.nativeHeight)
                let s = AnchorTransform.scaleFactor(anchor: a, native: native, frame: frame, targetFraction: settings.targetFractionOfHeight)
                let hc = AnchorTransform.homography(anchor: a, native: native, frame: frame, targetFraction: settings.targetFractionOfHeight, variant: .centred, rotation: rotation, medianAspect: medianAspect)
                let ha = AnchorTransform.homography(anchor: a, native: native, frame: frame, targetFraction: settings.targetFractionOfHeight, variant: .aligned, rotation: rotation, medianAspect: medianAspect)
                let cc = hc.map { AnchorTransform.coverage($0, native: native, frame: frame) } ?? 0
                let ca = ha.map { AnchorTransform.coverage($0, native: native, frame: frame) } ?? 0
                members.append(GroupMember(assetID: a.assetID, anchor: a, capturedAt: asset.capturedAt, scaleFactor: s,
                                           requiredUpscale: max(1, s), coverageCentred: cc, coverageAligned: ca))
            }
            members.sort { $0.capturedAt < $1.capturedAt }
            let sizeOrdered = members.sorted { $0.scaleFactor < $1.scaleFactor }.map { $0.assetID }
            index += 1
            groups.append(ShapeGroup(index: index, kind: kind, label: label, bucket: bucket, members: members,
                                     sizeOrdered: sizeOrdered, truncatedFrom: truncated, medianAspect: medianAspect,
                                     nearMiss: members.count < settings.minGroupSize))
            log.line("group \(index) \(label): \(members.count) members\(members.count < settings.minGroupSize ? " (near-miss)" : "")")
        }

        for kind in [ShapeAnchor.Kind.ellipse, .quad] {
            let ofKind = anchors.filter { $0.kind == kind }
            log.line("\(kind.rawValue): \(ofKind.count) assets with a dominant anchor")
            make(label: "\(kind.rawValue) · all", bucket: nil, anchors: ofKind, kind: kind)
            if kind == .ellipse {
                for b in ["head-on", "moderate", "oblique"] {
                    make(label: "ellipse · \(b)", bucket: b, anchors: ofKind.filter { obliquityBucket($0.groupingObliquity) == b }, kind: kind)
                }
            } else {
                for ab in ["wide", "square", "tall"] {
                    let inAspect = ofKind.filter { aspectBucket(AnchorTransform.quadAspect($0)) == ab }
                    make(label: "quad · \(ab)", bucket: ab, anchors: inAspect, kind: kind)
                    for ob in ["head-on", "moderate", "oblique"] {
                        let sub = inAspect.filter { obliquityBucket($0.groupingObliquity) == ob }
                        if sub.count < inAspect.count { make(label: "quad · \(ab) · \(ob)", bucket: "\(ab)/\(ob)", anchors: sub, kind: kind) }
                    }
                }
            }
        }
        return GroupsFile(settings: settings, groups: groups)
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
