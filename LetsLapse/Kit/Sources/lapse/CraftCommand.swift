import CoreText
import Foundation
import LetsLapseKit

// `lapse craft` — the Crafted Text path with the app taken out of it.
//
// The feature has three seams worth testing and only one of them needs a
// model: the PROMPT the model is given, the PARSE of whatever it says back,
// and the LAYOUT that turns parts into layers. This command drives all
// three headless, so an integration test can pipe a real generation (or a
// fixture) in and assert on the layers that come out — no device, no
// simulator, no MLX, no window.
//
// The no-model path is the same command with no `--response`: that is
// literally what the app runs when nothing is installed, so "check the
// fallback" and "check the layout" are one code path here as they are there.

/// One laid-out line, flattened for printing and for JSON.
private struct CraftedLineReport {
    var index: Int
    var label: String
    var copy: String
    var runs: [TextRun]
    var style: CraftedTextStyle
    var size: Double
    var centerX: Double
    var centerY: Double
    var follows: Int?
    /// The band every crafted line is SEEDED with…
    var seededStart: Double
    var seededEnd: Double
    /// …and where it ends up once the chain is resolved, which is what the
    /// viewer actually plays. Line 1 keeps its seed; each line after it
    /// opens where its parent's reveal ends.
    var revealStart: Double
    var revealEnd: Double
}

/// How a line's width is measured before it is fitted to the frame.
private enum CraftMeasure: String {
    /// Font-free and identical on every machine — the default, because an
    /// assertion that changes with the installed fonts is not an assertion.
    case estimate
    /// Real Core Text metrics in the resolved face, which is what the app
    /// uses at render time. Use it to see a true fit; do not assert on it.
    case coretext
}

func runCraft(
    brief: String?,
    responsePath: String?,
    promptKind: String?,
    wantsOptions: Bool,
    aspect: Double,
    playhead: Double,
    fonts: [CraftedTextFontRole: String],
    measure: String,
    asJSON: Bool,
    expectLines: Int?,
    expectPayoff: String?
) throws {
    guard let measureMode = CraftMeasure(rawValue: measure) else {
        fail("--measure expects estimate | coretext")
    }

    // 1. Print a prompt and stop. This is how a test pins what the model is
    //    actually told — the rules in it are load-bearing.
    if let promptKind {
        guard let brief, !brief.isEmpty else { fail("--prompt needs --brief") }
        switch promptKind {
        case "split": print(CraftedTextPrompt.split(brief: brief))
        case "candidates": print(CraftedTextPrompt.candidates(brief: brief))
        default: fail("--prompt expects split | candidates")
        }
        return
    }

    // 2. A candidates answer is a list of directions, not layers.
    if wantsOptions {
        guard let responsePath else { fail("--options needs --response <path|->") }
        let raw = try readResponse(responsePath)
        let options: [String]
        do {
            options = try CraftedTextResponse.options(from: raw)
        } catch {
            printErr("craft: \(error)")
            exit(65)
        }
        if asJSON {
            printJSON(["options": options])
        } else {
            print("\(options.count) direction\(options.count == 1 ? "" : "s")")
            for (index, option) in options.enumerated() {
                print("  \(index + 1). \(option)")
            }
        }
        if let expectLines, options.count != expectLines {
            printErr("craft: expected \(expectLines) options, got \(options.count)")
            exit(65)
        }
        return
    }

    // 3. Parts: either the model's answer, or the no-model splitter.
    let parts: [CraftedTextPart]
    let source: String
    if let responsePath {
        let raw = try readResponse(responsePath)
        do {
            parts = try CraftedTextResponse.parts(from: raw)
            source = "model"
        } catch {
            // The app falls back here rather than failing the person who
            // pressed Send. The CLI says so and reports the failure, but
            // only falls back when it has a brief to fall back TO — and it
            // exits non-zero either way, so a broken generation is a red
            // build rather than a quietly plainer one.
            printErr("craft: \(error)")
            if let brief, !brief.isEmpty {
                let fallback = CraftedTextLayout.split(brief)
                printErr("craft: fell back to the splitter — \(fallback.count) line(s)")
            }
            exit(65)
        }
    } else {
        guard let brief, !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("craft needs --brief <text> or --response <path|->")
        }
        parts = CraftedTextLayout.split(brief)
        source = "splitter (no model)"
    }

    // 4. Layout — the same call the app's panel makes.
    let widthOf: (String, CraftedTextStyle) -> Double = { copy, style in
        switch measureMode {
        case .estimate:
            return CraftedTextLayout.estimatedEmWidth(of: copy, style: style)
        case .coretext:
            return coreTextEmWidth(copy, family: fonts[style.role], isBold: style.isBold)
        }
    }
    let lines = CraftedTextLayout.lines(for: parts, aspect: aspect, measure: widthOf)
    let band = CraftedTextLayout.revealBand(at: playhead)

    // Seed each line the way `OverlayDocument.addCrafted` does — same band,
    // same chain — and then resolve it with the same sequencer the document
    // runs after every edit. Without this the CLI would report the times a
    // line was seeded with rather than the times it plays at, and the chain
    // is the part of this feature most worth a regression test.
    var sequenced: [OverlaySequencing.Layer] = []
    var ids: [UUID] = []
    for line in lines {
        let id = UUID()
        ids.append(id)
        var animation = OverlayAnimation(
            reveal: OverlayReveal(
                unit: line.style.unit, style: line.style.style,
                start: band.start, end: band.end))
        if let parent = line.followsIndex {
            animation.follows = OverlayFollow(layerID: ids[parent], gap: 0)
        }
        sequenced.append(OverlaySequencing.Layer(id: id, animation: animation))
    }
    OverlaySequencing.resolve(&sequenced)

    let report = lines.enumerated().map { index, line -> CraftedLineReport in
        let resolved = sequenced[index].animation?.reveal
        return CraftedLineReport(
            index: index, label: "Crafted · line \(index + 1)",
            copy: line.runs.map(\.text).joined(), runs: line.runs, style: line.style,
            size: line.size, centerX: line.centerX, centerY: line.centerY,
            follows: line.followsIndex,
            seededStart: band.start, seededEnd: band.end,
            revealStart: resolved?.start ?? band.start,
            revealEnd: resolved?.end ?? band.end)
    }

    if asJSON {
        printJSON(json(for: report, source: source, aspect: aspect, playhead: playhead))
    } else {
        printReport(report, source: source, aspect: aspect, measure: measureMode)
    }

    // 5. Assertions, so a CI case is one command with an exit code.
    if let expectLines, report.count != expectLines {
        printErr("craft: expected \(expectLines) line(s), got \(report.count)")
        exit(65)
    }
    if let expectPayoff {
        guard let line = report.first(where: { $0.copy == expectPayoff }) else {
            printErr("craft: no line reads \"\(expectPayoff)\"")
            exit(65)
        }
        // The payoff is the priority-1 line, and amber is what only priority
        // 1 is drawn in — so the colour is the assertion, not the size,
        // which the width fit is allowed to move.
        guard line.style.colorHex.caseInsensitiveCompare("#FFB340") == .orderedSame else {
            printErr("craft: \"\(expectPayoff)\" is not the payoff line "
                + "(colour \(line.style.colorHex), the payoff is #FFB340)")
            exit(65)
        }
    }
}

// MARK: - Output

private func printReport(
    _ lines: [CraftedLineReport], source: String, aspect: Double, measure: CraftMeasure
) {
    print("crafted \(lines.count) line\(lines.count == 1 ? "" : "s") from the \(source)"
        + String(format: " · frame %.3f:1 · measure %@", aspect, measure.rawValue))
    for line in lines {
        let follows = line.follows.map { "follows line \($0 + 1)" } ?? "starts on its own"
        print(String(
            format: "  %d. %@  size %.4f  centre %.3f,%.3f  %@ · %@  %@",
            line.index + 1, line.label, line.size, line.centerX, line.centerY,
            line.style.unit.rawValue, line.style.style.rawValue, follows))
        print("     copy: \(line.copy)")
        let runs = line.runs.map { run -> String in
            let colour = run.colorHex ?? "inherit"
            return "\"\(run.text)\"[\(colour)\(run.isBold == true ? " bold" : "")]"
        }
        print("     runs: \(runs.joined(separator: " "))")
        print(String(format: "     band: %.4f → %.4f  (seeded %.4f → %.4f)",
                     line.revealStart, line.revealEnd, line.seededStart, line.seededEnd))
    }
}

private func json(
    for lines: [CraftedLineReport], source: String, aspect: Double, playhead: Double
) -> [String: Any] {
    [
        "source": source,
        "aspect": aspect,
        "playhead": playhead,
        "lineCount": lines.count,
        "lines": lines.map { line -> [String: Any] in
            var object: [String: Any] = [
                "index": line.index,
                "label": line.label,
                "copy": line.copy,
                "size": line.size,
                "centerX": line.centerX,
                "centerY": line.centerY,
                "colorHex": line.style.colorHex,
                "emphasisColorHex": line.style.emphasisColorHex,
                "isBold": line.style.isBold,
                "fontRole": line.style.role.rawValue,
                "unit": line.style.unit.rawValue,
                "style": line.style.style.rawValue,
                "revealStart": line.revealStart,
                "revealEnd": line.revealEnd,
                "seededStart": line.seededStart,
                "seededEnd": line.seededEnd,
                "runs": line.runs.map { run -> [String: Any] in
                    var out: [String: Any] = ["text": run.text]
                    if let colorHex = run.colorHex { out["colorHex"] = colorHex }
                    if let isBold = run.isBold { out["isBold"] = isBold }
                    if let isUnderlined = run.isUnderlined { out["isUnderlined"] = isUnderlined }
                    return out
                },
            ]
            if let follows = line.follows { object["followsIndex"] = follows }
            return object
        },
    ]
}

private func printJSON(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
        let text = String(data: data, encoding: .utf8)
    else {
        fail("could not serialise the report")
    }
    print(text)
}

// MARK: - Input

/// `-` reads stdin, so a generation can be piped straight in.
private func readResponse(_ path: String) throws -> String {
    if path == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
    return try String(contentsOfFile: path, encoding: .utf8)
}

/// The real metrics, for `--measure coretext`. Mirrors the app's
/// `TextOverlayRasterizer.emWidth`: measure at a nominal 100pt and divide,
/// so the number is size-independent.
private func coreTextEmWidth(_ copy: String, family: String?, isBold: Bool) -> Double {
    let nominal: CGFloat = 100
    var font: CTFont
    if let family, !family.isEmpty {
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: family,
        ] as CFDictionary)
        font = CTFontCreateWithFontDescriptor(descriptor, nominal, nil)
        if isBold {
            font = CTFontCreateCopyWithSymbolicTraits(
                font, nominal, nil, .traitBold, .traitBold) ?? font
        }
    } else {
        font = CTFontCreateUIFontForLanguage(.system, nominal, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, nominal, nil)
        if isBold {
            font = CTFontCreateCopyWithSymbolicTraits(
                font, nominal, nil, .traitBold, .traitBold) ?? font
        }
    }
    // The Core Text key, not AppKit's `.font`: this target links CoreText
    // and Foundation only.
    let attributed = NSAttributedString(
        string: copy, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
    let line = CTLineCreateWithAttributedString(attributed)
    return max(Double(CTLineGetTypographicBounds(line, nil, nil, nil)) / Double(nominal), 0.001)
}
