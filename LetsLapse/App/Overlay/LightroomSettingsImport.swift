import Foundation
import LetsLapseKit

/// The bridge between `LightroomImport`'s plain values and this app's types.
///
/// The Kit does the reading and the arithmetic; it cannot see
/// `PhotoAdjustments`, `ShapeMask` or `MaskGrade`, so this is where the field
/// names become key paths and the shapes become project masks. Deliberately
/// thin — anything with a judgement in it belongs on the Kit side, where
/// `swift test` can pin it.
enum LightroomSettingsImport {

    /// What one sidecar becomes.
    struct Result {
        var adjustments: PhotoAdjustments
        var shapeMasks: [ShapeMask]
        var maskGrades: [MaskGrade]
        /// The lines the report shows — what came across, and what did not.
        var applied: [String]
        var unsupported: [String]

        /// The one-line summary for a toast.
        var summary: String {
            var parts = ["\(applied.count) setting\(applied.count == 1 ? "" : "s")"]
            if !maskGrades.isEmpty {
                parts.append("\(maskGrades.count) mask\(maskGrades.count == 1 ? "" : "s")")
            }
            if !unsupported.isEmpty { parts.append("\(unsupported.count) not carried") }
            return "Imported " + parts.joined(separator: " · ")
        }
    }

    /// The sidecar beside a frame, if Lightroom left one.
    static func sidecarURL(besideFrame url: URL) -> URL? {
        LightroomSidecar.sidecarURL(forRawFile: url)
    }

    static func read(_ url: URL) throws -> Result {
        resolve(LightroomImport.map(try LightroomSidecar.read(contentsOf: url)))
    }

    /// Applies the mapped values to this app's types.
    ///
    /// Every write goes through `PhotoAdjustmentField`, so a field the Kit
    /// names but this build has dropped is skipped rather than crashing — and
    /// the value is clamped to the control's own range, because Lightroom's
    /// travel is not always ours (a local +4 EV lands on our ±2 ceiling).
    static func resolve(_ imported: LightroomImport) -> Result {
        var adjustments = PhotoAdjustments.neutral
        var applied = imported.applied
        var unsupported = imported.unsupported

        for (name, value) in imported.adjustments {
            guard let field = PhotoAdjustmentField(rawValue: name) else {
                unsupported.append("\(name) — this build has no such control")
                continue
            }
            adjustments[keyPath: field.keyPath] = clamp(Float(value), to: field.range)
        }
        // The HSL panel travels whole; the Kit has already held it to ±1.
        adjustments.hsl = imported.hsl?.clamped

        var shapeMasks: [ShapeMask] = []
        var maskGrades: [MaskGrade] = []
        for mask in imported.masks {
            // A drawn shape becomes a project mask of its own; a semantic one
            // names a region the project already has, so there is nothing to
            // create — `MaskRef.sky` IS the mask.
            let ref: MaskRef
            switch mask.target {
            case .shape(let shape):
                let created = ShapeMask(name: mask.name, shape: shape)
                shapeMasks.append(created)
                ref = .shape(created.id)
            case .semantic(let region):
                guard region == "sky" || region == "land" else {
                    unsupported.append("Mask \u{201C}\(mask.name)\u{201D} names a region this app has no equivalent for")
                    continue
                }
                ref = region == "sky" ? .sky : .land
            }
            var values = PhotoAdjustments.neutral
            for (name, value) in mask.adjustments {
                guard let field = PhotoAdjustmentField(rawValue: name) else { continue }
                let ceiling = MaskGrade.range(for: field)
                let clamped = clamp(Float(value), to: ceiling)
                // Say so when Lightroom's travel exceeded ours: the picture
                // will differ, and silently landing on the ceiling is exactly
                // the kind of loss that reads as a bug later.
                if abs(clamped - Float(value)) > 1e-4 {
                    applied.append(String(
                        format: "Mask \u{201C}%@\u{201D} · %@ %+.3f clamped to %+.3f",
                        mask.name, name, value, clamped))
                }
                values[keyPath: field.keyPath] = clamped
            }
            maskGrades.append(MaskGrade(
                mask: ref, inverted: mask.inverted, adjustments: values))
        }

        return Result(
            adjustments: adjustments, shapeMasks: shapeMasks, maskGrades: maskGrades,
            applied: applied, unsupported: unsupported)
    }

    private static func clamp(_ value: Float, to range: ClosedRange<Float>) -> Float {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
