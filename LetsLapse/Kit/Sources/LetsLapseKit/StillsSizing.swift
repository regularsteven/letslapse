import Foundation

/// The size rules for stills, kept pure so they are proved here rather than
/// discovered on a phone.
///
/// 2026-09-26: the iPhone 18 Pro's Photo mode shot 1920×1080 for a week under
/// a menu that said 4224×3024, and nothing noticed — the format that could not
/// be applied failed without a word, and nothing measured what came out
/// (docs/fieldtests/2026-09-26-18pro-crash-triage.md). The app measures every
/// still against the chosen size with `isShort`, substitutes an undeliverable
/// choice with `substitute`, and asks AVFoundation only for a request size its
/// own rules take with `requestSize`.
public enum StillsSizing {
    /// A pixel size. Formats report landscape; stills can come out either way
    /// round, so comparisons go by pixel count and `shape`, never by side.
    public struct Size: Hashable, Sendable, CustomStringConvertible {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        public var pixels: Int64 { Int64(width) * Int64(height) }

        /// Long side over short side, whichever way round.
        public var shape: Double {
            Double(max(width, height)) / Double(max(min(width, height), 1))
        }

        public var description: String { "\(width)×\(height)" }
    }

    /// The share of the chosen pixels a still may come out below before it is
    /// an alarm: the same-shape substitute passes (4032×3024 is 95.5 % of
    /// 4224×3024), 1920×1080 against 12 MP (17 %) does not.
    public static let shortfallThreshold = 0.9

    /// Whether a still that came out at `delivered` falls materially short of
    /// `expected`, by pixel count and whichever way round either is.
    public static func isShort(delivered: Size, expected: Size) -> Bool {
        guard expected.pixels > 0 else { return false }
        return Double(delivered.pixels) < Double(expected.pixels) * shortfallThreshold
    }

    /// What to use when `chosen` cannot be delivered: the largest smaller size
    /// of about the same shape (4224×3024 → 4032×3024), else the largest
    /// smaller size of any shape; nil when nothing smaller is offered. Never
    /// `chosen` itself, and never larger — a substitute must not grow a still
    /// past what was chosen, nor fall back to a video size when a stills size
    /// of the same shape exists.
    public static func substitute(for chosen: Size, among offered: [Size]) -> Size? {
        let smaller = offered.filter { $0.pixels < chosen.pixels }
        let sameShape = smaller.filter { abs($0.shape - chosen.shape) < 0.1 }
        return (sameShape.isEmpty ? smaller : sameShape).max { $0.pixels < $1.pixels }
    }

    /// The `maxPhotoDimensions` to ask for, by AVFoundation's two stated rules
    /// (iOS 27 aborts on a request that breaks either): not larger than the
    /// photo output's `ceiling`, and one of the active format's `listed` sizes
    /// (nil: no format known, only the ceiling applies). `wanted` when both
    /// take it; else the largest smaller size both take; else nil — leave it
    /// unset and the output's own maximum governs.
    public static func requestSize(wanted: Size, ceiling: Size, listed: [Size]?) -> Size? {
        func takes(_ size: Size) -> Bool {
            size.width <= ceiling.width && size.height <= ceiling.height
                && (listed?.contains(size) ?? true)
        }
        if takes(wanted) { return wanted }
        return (listed ?? [])
            .filter { $0.pixels < wanted.pixels && takes($0) }
            .max { $0.pixels < $1.pixels }
    }
}
