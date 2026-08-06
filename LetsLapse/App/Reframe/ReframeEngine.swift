import CoreGraphics
import Foundation

/// The reframe's arithmetic — no SwiftUI, no state, nothing to mock. The view
/// model, the player and the renderer all read the frame from here, so what
/// you scrub is exactly what gets written out.
enum ReframeEngine {
    // MARK: - Limits

    static let minZoom = 1.0
    static let maxZoom = 6.0
    static let minSpeed = 0.25
    static let maxSpeed = 100.0

    /// Blend saturates at 100× — the same top speed the chips offer.
    static let blendCeilingSpeed = 100.0

    // MARK: - Easing

    /// Cubic ease-in-out. One curve for all three channels: speed, crop and
    /// blend leave and arrive together, which is what makes the punch read as
    /// a move rather than three separate animations.
    static func ease(_ u: Double) -> Double {
        let u = min(max(u, 0), 1)
        if u < 0.5 { return 4 * u * u * u }
        let f = -2 * u + 2
        return 1 - (f * f * f) / 2
    }

    // MARK: - Interpolation

    /// The frame at source time `t`.
    ///
    /// Zoom and speed interpolate in *log* space so ratios feel even — 1× to
    /// 100× spends as long crossing 1→10 as 10→100. Centre and blend are
    /// linear, where the eye wants distance, not ratio.
    static func interp(
        t: Double,
        keys: [PunchKeyframe]
    ) -> (z: Double, cx: Double, cy: Double, v: Double, bl: Double) {
        guard let first = keys.first else {
            return (1, 0, 0, 1, 0)
        }
        guard keys.count > 1 else {
            return (first.z, first.cx, first.cy, first.v, first.bl)
        }
        if t <= first.t {
            return (first.z, first.cx, first.cy, first.v, first.bl)
        }
        guard let last = keys.last, t < last.t else {
            let last = keys[keys.count - 1]
            return (last.z, last.cx, last.cy, last.v, last.bl)
        }

        var lower = keys[0]
        var upper = keys[keys.count - 1]
        for index in 1..<keys.count where keys[index].t >= t {
            lower = keys[index - 1]
            upper = keys[index]
            break
        }

        let span = upper.t - lower.t
        guard span > 0 else {
            return (upper.z, upper.cx, upper.cy, upper.v, upper.bl)
        }
        let e = ease((t - lower.t) / span)

        return (
            z: logLerp(lower.z, upper.z, e, floor: minZoom),
            cx: lower.cx + (upper.cx - lower.cx) * e,
            cy: lower.cy + (upper.cy - lower.cy) * e,
            v: logLerp(lower.v, upper.v, e, floor: 0.01),
            bl: lower.bl + (upper.bl - lower.bl) * e
        )
    }

    private static func logLerp(_ a: Double, _ b: Double, _ e: Double, floor: Double) -> Double {
        let a = max(a, floor)
        let b = max(b, floor)
        return exp(log(a) + (log(b) - log(a)) * e)
    }

    // MARK: - Crop

    /// The largest window of `ratio` that fits inside the source — the crop at
    /// zoom 1, and the unit every zoom divides.
    static func baseCrop(ratio: ReframeRatio, sourceSize: CGSize) -> CGSize {
        let width = Double(sourceSize.width)
        let height = Double(sourceSize.height)
        guard width > 0, height > 0 else { return .zero }
        let target = ratio.ratio
        if width / height > target {
            return CGSize(width: height * target, height: height)
        }
        return CGSize(width: width, height: width / target)
    }

    /// A centre that keeps the whole crop window inside the source. A crop
    /// wider than the source (only reachable with a nonsense zoom) centres.
    static func clampCenter(
        z: Double,
        cx: Double,
        cy: Double,
        ratio: ReframeRatio,
        sourceSize: CGSize
    ) -> (cx: Double, cy: Double) {
        let base = baseCrop(ratio: ratio, sourceSize: sourceSize)
        guard base.width > 0, base.height > 0 else { return (cx, cy) }
        let zoom = min(max(z, minZoom), maxZoom)
        let w = Double(base.width) / zoom
        let h = Double(base.height) / zoom
        let width = Double(sourceSize.width)
        let height = Double(sourceSize.height)

        let x: Double
        if w >= width {
            x = width / 2
        } else {
            x = min(max(cx, w / 2), width - w / 2)
        }
        let y: Double
        if h >= height {
            y = height / 2
        } else {
            y = min(max(cy, h / 2), height - h / 2)
        }
        return (x, y)
    }

    /// The crop window in source pixels, already clamped to the frame.
    static func cropRect(
        z: Double,
        cx: Double,
        cy: Double,
        ratio: ReframeRatio,
        sourceSize: CGSize
    ) -> CGRect {
        let base = baseCrop(ratio: ratio, sourceSize: sourceSize)
        guard base.width > 0, base.height > 0 else { return .zero }
        let zoom = min(max(z, minZoom), maxZoom)
        let w = min(Double(base.width) / zoom, Double(sourceSize.width))
        let h = min(Double(base.height) / zoom, Double(sourceSize.height))
        let centre = clampCenter(z: zoom, cx: cx, cy: cy, ratio: ratio, sourceSize: sourceSize)
        return CGRect(x: centre.cx - w / 2, y: centre.cy - h / 2, width: w, height: h)
    }

    static func crop(
        at t: Double,
        keys: [PunchKeyframe],
        ratio: ReframeRatio,
        sourceSize: CGSize
    ) -> ScaledCrop {
        let frame = interp(t: t, keys: keys)
        return ScaledCrop(
            rect: cropRect(z: frame.z, cx: frame.cx, cy: frame.cy, ratio: ratio, sourceSize: sourceSize))
    }

    // MARK: - Time

    /// How long the clip runs once the warp is applied — the integral of
    /// 1/speed over the source. Trapezoid over a fixed grid so the number
    /// never jitters as the playhead moves.
    static func outputDuration(
        keys: [PunchKeyframe],
        sourceDuration: Double,
        steps: Int = 480
    ) -> Double {
        outputTime(at: sourceDuration, keys: keys, sourceDuration: sourceDuration, steps: steps)
    }

    /// Where source time `sourceTime` lands in the finished clip.
    static func outputTime(
        at sourceTime: Double,
        keys: [PunchKeyframe],
        sourceDuration: Double,
        steps: Int = 480
    ) -> Double {
        guard sourceDuration > 0 else { return 0 }
        guard !keys.isEmpty else { return min(max(0, sourceTime), sourceDuration) }
        let end = min(max(0, sourceTime), sourceDuration)
        guard end > 0 else { return 0 }

        let n = max(8, steps)
        let dt = sourceDuration / Double(n)
        var total = 0.0
        var previous = inverseSpeed(at: 0, keys: keys)
        for index in 1...n {
            let t0 = dt * Double(index - 1)
            let t1 = min(dt * Double(index), end)
            guard t1 > t0 else { break }
            let next = inverseSpeed(at: t1, keys: keys)
            total += (previous + next) / 2 * (t1 - t0)
            previous = next
            if t1 >= end { break }
        }
        return total
    }

    private static func inverseSpeed(at t: Double, keys: [PunchKeyframe]) -> Double {
        1 / max(minSpeed, interp(t: t, keys: keys).v)
    }

    // MARK: - Blend

    /// Blend depth that follows speed: off at real time, full at 100×. The
    /// same log scale the speeds themselves ramp on, so a key that sits
    /// halfway up the ramp blends halfway too.
    static func autoBlend(speed: Double) -> Double {
        max(0, min(1, log(max(speed, 0.01)) / log(blendCeilingSpeed)))
    }

    // MARK: - Seeding

    /// The punch-in a fresh clip opens on: a fast wide, an eased dive into a
    /// 2.6× lock at real time, then back out. Times are proportional, so a
    /// 20-second source and a 20-minute one both get the same shape.
    static func defaultKeys(sourceSize: CGSize, duration: Double) -> [PunchKeyframe] {
        let duration = max(0.5, duration)
        let cx = Double(sourceSize.width) / 2
        let cy = Double(sourceSize.height) / 2
        let marks: [(f: Double, z: Double, v: Double)] = [
            (0.00, 1.0, 100),
            (0.35, 1.0, 100),
            (0.37, 2.6, 1),
            (0.41, 2.6, 1),
            (0.44, 1.0, 100),
        ]
        return marks.map { mark in
            PunchKeyframe(
                t: duration * mark.f,
                z: mark.z,
                cx: cx,
                cy: cy,
                v: mark.v,
                bl: autoBlend(speed: mark.v)
            )
        }
    }

    // MARK: - Labels

    /// "100×", "1×", "¼×"
    static func speedLabel(_ speed: Double) -> String {
        if abs(speed - 0.25) < 0.001 { return "¼×" }
        if abs(speed - 0.5) < 0.001 { return "½×" }
        if abs(speed - speed.rounded()) < 0.05 { return "\(Int(speed.rounded()))×" }
        return String(format: "%.1f×", speed)
    }

    /// The four depths the manual chips offer. Auto lands anywhere on 0…1, so
    /// switching to manual snaps to the nearest of these — a chip row with
    /// nothing lit reads as broken, not as "between two of them".
    static let manualDepths: [Double] = [0, 0.33, 0.66, 1]

    static func nearestManualDepth(_ depth: Double) -> Double {
        manualDepths.min { abs($0 - depth) < abs($1 - depth) } ?? 0
    }

    /// "off" · "light" · "medium" · "heavy"
    static func blendWord(_ blend: Double) -> String {
        switch blend {
        case ..<0.08: return "off"
        case ..<0.45: return "light"
        case ..<0.78: return "medium"
        default: return "heavy"
        }
    }

    /// "2:14" — and "1:02:14" once a source runs past the hour.
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds.rounded(.down))
        let s = whole % 60
        let m = (whole / 60) % 60
        let h = whole / 3600
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// The output readout wants tenths while the clip is short — "3.4s" reads
    /// better than "0:03" for something you're about to watch twice.
    static func shortTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0.0s" }
        // A hundredth-second clip is a real answer at 100× on a short source —
        // rounding it to "0.0s" would read as a broken estimate.
        if seconds < 0.95 { return String(format: "%.2fs", seconds) }
        if seconds < 9.95 { return String(format: "%.1fs", seconds) }
        return timecode(seconds)
    }
}
