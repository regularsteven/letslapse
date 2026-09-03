import Foundation
import LetsLapseKit

// lapse framing — the "Review photos" / "Stabilise photos" pass, headless
// (docs/framing-lock.md). Measures where every still of an interval shoot
// sits against one locked framing, writes `framing.json` beside the stills,
// prints the report, and optionally commits the plan. Never touches a pixel.

let stillExtensions: Set<String> = ["dng", "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2"]

func discoverStills(in folder: URL) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names
        .filter { stillExtensions.contains(($0 as NSString).pathExtension.lowercased()) && !$0.hasPrefix(".") }
        .sorted()
        .map { folder.appendingPathComponent($0) }
}

/// `<dir>/source` when it exists, else `<dir>` itself.
func sourceFolder(for path: String) -> URL {
    let url = URL(fileURLWithPath: path)
    let nested = url.appendingPathComponent("source", isDirectory: true)
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory), isDirectory.boolValue {
        return nested
    }
    return url
}

func printFramingReport(_ review: FramingReview) {
    print("framing review · \(review.frames.count) photos · \(review.width)×\(review.height) · measured at \(String(format: "%.2g", review.measurementScale))×")
    print("  verdict: \(review.verdict.rawValue)")
    print("  \(review.summary)")
    let xs = review.frames.map(\.dx), ys = review.frames.map(\.dy)
    if let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() {
        print(String(format: "  path vs reference: x %.1f..%.1f px · y %.1f..%.1f px · drift x %.1f y %.1f", minX, maxX, minY, maxY, review.driftX, review.driftY))
    }
    let confidences = review.frames.map(\.confidence).sorted()
    if !confidences.isEmpty {
        print(String(format: "  confidence: median %.2f · p5 %.2f · min %.2f", confidences[confidences.count / 2], confidences[confidences.count / 20], confidences[0]))
    }
    print("  knocks: \(review.events.count)")
    for event in review.events { print("    \(event.summary)") }
    print(String(format: "  plan: crop %.2f%% of each edge (inset ±%.1f × ±%.1f px, reference %.1f, %.1f)", review.plan.cropFraction * 100, review.plan.insetX, review.plan.insetY, review.plan.referenceX, review.plan.referenceY))
    if let stabilisation = review.stabilisation {
        print("  stabilised: \(FrameTimestamps.string(from: stabilisation.appliedAt))\(review.isStabilisationCurrent ? "" : " (STALE — from an earlier review)")")
    } else {
        print("  stabilised: no")
    }
    let peak = review.events.map(\.peakPixels).max() ?? 0
    print(String(format: "FRAMING LOCK: %d events · peak %.1f px · crop %.2f%%", review.events.count, peak, review.plan.cropFraction * 100))
}

func runFraming(
    path: String, apply: Bool, withdraw: Bool, force: Bool, jsonPath: String?,
    scale: Double, workers: Int?, range: ClosedRange<Int>?
) throws {
    let folder = sourceFolder(for: path)
    let existing = FramingReview.load(inSourceFolder: folder)

    // Commit or withdraw against the review on disk — no measuring.
    if withdraw {
        guard let existing else { fail("no framing.json in \(folder.path) to withdraw") }
        try existing.withdrawingStabilisation().write(inSourceFolder: folder)
        print("stabilisation withdrawn · \(FramingReview.url(inSourceFolder: folder).path)")
        return
    }
    if apply, let existing, !force, range == nil {
        let committed = existing.applyingPlan()
        try committed.write(inSourceFolder: folder)
        printFramingReport(committed)
        print(FramingReview.url(inSourceFolder: folder).path)
        return
    }
    if let existing, !force, range == nil {
        printFramingReport(existing)
        print(FramingReview.url(inSourceFolder: folder).path)
        return
    }

    var urls = discoverStills(in: folder)
    guard urls.count >= 2 else { fail("\(folder.path) holds \(urls.count) stills — a review needs at least two") }
    if let range {
        guard range.lowerBound >= 0, range.upperBound < urls.count else {
            fail("--range \(range.lowerBound)-\(range.upperBound) is outside 0-\(urls.count - 1)")
        }
        urls = Array(urls[range])
    }
    guard let size = FramingMeasurement.fullSize(of: urls[0]) else { fail("could not read the size of \(urls[0].lastPathComponent)") }
    let decoder = FramingLumaDecoder(scale: scale)
    let started = Date()
    printErr("measuring \(urls.count) stills at \(scale)× with \(workers ?? FramingMeasurement.defaultWorkers) workers")
    let offsets = try FramingMeasurement.measure(
        urls: urls, scale: scale, luma: { try decoder.luma(at: $0) },
        workers: workers ?? FramingMeasurement.defaultWorkers,
        progress: { progressToStderr($0) })
    let span: Double? = {
        guard range == nil, let timestamps = try? FrameTimestamps.load(from: folder.appendingPathComponent(FrameTimestamps.fileName)),
              let first = timestamps.entries.first?.captureTime, let last = timestamps.entries.last?.captureTime else { return nil }
        return last.timeIntervalSince(first)
    }()
    var review = FramingReview.make(
        width: size.width, height: size.height, measurementScale: scale,
        offsets: offsets, captureSpanSeconds: span)
    if apply { review = review.applyingPlan() }
    printErr(String(format: "measured in %.1fs", Date().timeIntervalSince(started)))
    printFramingReport(review)
    if range == nil {
        try review.write(inSourceFolder: folder)
        print(FramingReview.url(inSourceFolder: folder).path)
    } else {
        printErr("partial range: not written beside the stills")
    }
    if let jsonPath {
        try review.write(to: URL(fileURLWithPath: jsonPath))
        print(jsonPath)
    }
}
