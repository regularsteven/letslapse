import Foundation
import CoreImage
import LetsLapseKit

// lapse whitebalance — measure a shoot's as-shot white balance frame by frame,
// write `frames.whitebalance` beside the stills, and report what the camera did
// with it. A run left on auto white balance re-decides between frames; this is
// the pass that shows where, how far, and what the corrected curve looks like.

private func measureAsShot(_ url: URL) -> (kelvin: Float, tint: Float)? {
    // Through `LossyLinearDNG`, never `CIRAWFilter(imageURL:)` directly — the
    // same rule the decoder follows, for the same reason.
    guard ImportedStills.isRaw(url), let raw = LossyLinearDNG.rawFilter(for: url) else { return nil }
    let kelvin = raw.neutralTemperature
    let tint = raw.neutralTint
    guard LinearFrameDecoder.isUsableNeutral(temperatureK: Double(kelvin), tint: Double(tint)) else {
        return nil
    }
    return (kelvin, tint)
}

/// Seconds from the first frame for each still, from the shoot's own sidecar
/// when it wrote one. Without it the correction works in per-frame steps
/// instead of per-second ones, which is the same decision differently scaled.
private func captureSeconds(in folder: URL, count: Int) -> [Double] {
    let url = folder.appendingPathComponent(FrameTimestamps.fileName)
    guard let timestamps = try? FrameTimestamps.load(from: url),
          timestamps.entries.count == count,
          let first = timestamps.entries.first?.captureTime
    else { return Array(repeating: 0, count: count) }
    return timestamps.entries.map { $0.captureTime.timeIntervalSince(first) }
}

func runWhiteBalance(
    path: String, report: Bool, force: Bool, anchor: Double, jsonPath: String?
) throws {
    let folder = sourceFolder(for: path)
    let stills = discoverStills(in: folder)
    guard !stills.isEmpty else { fail("no stills in \(folder.path)") }
    let sidecar = folder.appendingPathComponent(WhiteBalanceSeries.fileName)

    var series = (try? WhiteBalanceSeries.load(from: sidecar)) ?? WhiteBalanceSeries(samples: [])
    let usable = series.samples.count == stills.count
    if report, !usable {
        fail("no measured series at \(sidecar.path) — run without --report first")
    }
    if !report, force || !usable {
        let seconds = captureSeconds(in: folder, count: stills.count)
        var samples: [WhiteBalanceSample] = []
        samples.reserveCapacity(stills.count)
        var unreadable = 0
        for (index, url) in stills.enumerated() {
            guard let measured = measureAsShot(url) else {
                unreadable += 1
                continue
            }
            samples.append(WhiteBalanceSample(
                frame: index, file: url.lastPathComponent,
                kelvin: measured.kelvin, tint: measured.tint, seconds: seconds[index]))
            if (index + 1) % 50 == 0 {
                FileHandle.standardError.write("  measured \(index + 1)/\(stills.count)\n".data(using: .utf8)!)
            }
        }
        guard !samples.isEmpty else { fail("no still reported a usable as-shot neutral") }
        if unreadable > 0 {
            print("note: \(unreadable) still(s) reported no usable as-shot neutral and were skipped")
        }
        series = WhiteBalanceSeries(samples: samples)
        try series.write(to: folder)
        print("wrote \(sidecar.path)")
    }

    let corrected = series.correctedDeclarations(anchorPosition: anchor)
    printWhiteBalanceReport(series: series, corrected: corrected, anchor: anchor)

    if let jsonPath {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = ["measured": series.samples, "corrected": corrected]
        try encoder.encode(payload).write(to: URL(fileURLWithPath: jsonPath))
        print("wrote \(jsonPath)")
    }
}

private func printWhiteBalanceReport(
    series: WhiteBalanceSeries, corrected: [WhiteBalanceSample], anchor: Double
) {
    let samples = series.samples
    print("white balance · \(samples.count) stills")
    guard let first = samples.first, let last = samples.last else { return }
    print(String(format: "  as shot: %.0f K / %+.1f → %.0f K / %+.1f",
                 first.kelvin, first.tint, last.kelvin, last.tint))

    // Two different things get reported, because two different things are
    // wrong: the gross re-decisions, which the correction removes outright,
    // and the plateau staircase, which it spreads.
    let mireds = samples.map(\.mired)
    let steps = zip(mireds, mireds.dropFirst()).map { $1 - $0 }
    let limit = WhiteBalanceSeries.grossStepLimit(mireds: mireds)
    let gross = steps.indices.filter { abs(steps[$0]) > limit }
    let visible = steps.indices.filter { abs(steps[$0]) > WhiteBalanceSeries.visibleStepMired }
    print(String(format: "  travel: %.1f mired · gross-step threshold %.1f mired",
                 (mireds.max() ?? 0) - (mireds.min() ?? 0), limit))
    print("  re-decisions (removed): \(gross.count) · visible steps (spread): \(visible.count)")
    for index in gross.prefix(12) {
        let before = samples[index], after = samples[index + 1]
        print(String(format: "    %d → %d  %@ → %@  %.0f K → %.0f K  (%+.1f mired, %+.1f tint)",
                     before.frame, after.frame, before.file, after.file,
                     before.kelvin, after.kelvin,
                     after.mired - before.mired, after.tint - before.tint))
    }
    if gross.count > 12 { print("    … and \(gross.count - 12) more") }

    let correctedMireds = corrected.map(\.mired)
    let residual = zip(correctedMireds, correctedMireds.dropFirst()).map { abs($1 - $0) }
    let remaining = residual.filter { $0 > WhiteBalanceSeries.visibleStepMired }.count
    print(String(format: "  corrected (anchor %.2f): %.0f K / %+.1f → %.0f K / %+.1f · travel %.1f mired",
                 anchor, corrected[0].kelvin, corrected[0].tint,
                 corrected[corrected.count - 1].kelvin, corrected[corrected.count - 1].tint,
                 (correctedMireds.max() ?? 0) - (correctedMireds.min() ?? 0)))
    print(String(format: "  largest remaining frame-to-frame change: %.2f mired (visible above %.1f)",
                 residual.max() ?? 0, WhiteBalanceSeries.visibleStepMired))
    print("  frames still stepping visibly: \(remaining)")
    print(remaining == 0 ? "WHITEBALANCE PASS" : "WHITEBALANCE FAIL")
}
