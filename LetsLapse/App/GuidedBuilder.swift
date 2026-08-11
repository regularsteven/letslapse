import CoreGraphics
import Foundation

/// One authored framing in the guided builder: where the crop sits, in the
/// same display-oriented source pixels as `ReframeTrack.Key`. `z` is the
/// punch factor against the canvas-shaped base crop, exactly as the reframe
/// track stores it.
struct GuidedFraming: Equatable {
    var z: Double
    var cx: Double
    var cy: Double

    /// The default state: the full frame at the canvas — needs no authoring.
    static func wide(sourceSize: CGSize) -> GuidedFraming {
        GuidedFraming(z: 1, cx: Double(sourceSize.width) / 2, cy: Double(sourceSize.height) / 2)
    }
}

/// What one stretch does spatially. Framing is a property of the stretch —
/// one framing, or a pair for a pan across it — and the ease between two
/// framings rides the seam, welded to the speed ramp that is already there.
/// There are no free-floating keyframes anywhere in this model.
enum GuidedPunch: Equatable {
    case none
    /// One constant crop for the whole stretch.
    case still(GuidedFraming)
    /// A Ken Burns drift: start-of-stretch crop to end-of-stretch crop.
    /// Linear ("thru") by default so a follow doesn't pulse; `eased` opts
    /// into the settling curve.
    case pan(from: GuidedFraming, to: GuidedFraming, eased: Bool)

    var entry: GuidedFraming? {
        switch self {
        case .none: return nil
        case .still(let framing): return framing
        case .pan(let from, _, _): return from
        }
    }

    var exit: GuidedFraming? {
        switch self {
        case .none, .still: return nil
        case .pan(_, let to, _): return to
        }
    }

    var isPunched: Bool { self != .none }
}

/// Turns the guided builder's per-stretch answers into the same
/// `ReframeTrack` the full editor authors — keys and arrive-anchored moves —
/// so the render pipeline, persistence and re-editing need nothing new.
///
/// The invariant this file exists to keep: a framing change can only happen
/// across a seam (riding the speed ramp) or across a slow stretch (a pan).
/// Every key placed here is derived from the stretch structure; none floats.
enum GuidedPlanner {
    /// The same gate as `AdjustView.speedChips(forStretchFPS:)` — the
    /// slow-motion chips need dense frames, the racing chips are for base
    /// footage only. One implementation so the two surfaces can never
    /// disagree about what a stretch's footage can honour.
    static func gatedSpeedChips(forStretchFPS fps: Double, outputFPS: Int) -> [(speed: Double, word: String)] {
        let out = Double(max(1, outputFPS))
        var chips: [(speed: Double, word: String)] = []
        if fps >= 4 * out { chips.append((0.25, "¼× slow")) }
        if fps >= 2 * out { chips.append((0.5, "½× slow")) }
        chips += [(1, "real time"), (4, "gentle"), (15, "subtle")]
        if fps < 4 * out {
            chips += [(50, "smooth"), (60, "flowing"), (100, "streaks")]
        }
        return chips
    }

    /// A couple of output frames' worth of source time at this stretch's
    /// speed, floored just above the track's merge distance so neighbouring
    /// keys never collapse into each other.
    static func nudge(atSpeed speed: Double) -> Double {
        max(ReframeTrack.minimumKeySpacing * 1.2, min(0.08 * max(0.0001, speed), 0.5))
    }

    /// The source time where a transition's arriving framing should be keyed.
    /// The compiled ease reports the source seconds it really consumes on the
    /// arriving side (`SeamEase.sourceAfter`), so the key lands exactly where
    /// the ramp ends and the arrive-anchored move occupies the ramp's own
    /// output window — one event, on the seam. Falls back to a small nudge
    /// when no compile is available.
    static func arrivalTime(
        into stretch: Int,
        warp: WarpTimeline,
        ease: WarpCompiler.SeamEase?
    ) -> Double {
        let boundary = warp.bounds[stretch]
        let floorLead = nudge(atSpeed: warp.speeds[stretch])
        let lead = ease.map(\.sourceAfter) ?? 0
        let cap = max(floorLead, 0.45 * warp.length(of: stretch))
        return boundary + min(max(lead, floorLead), cap)
    }

    /// The chip-granular move span for a compiled ease length — rounded DOWN,
    /// so the framing move never overhangs the speed ramp it is welded to.
    /// The number on screen is the number that renders, in the `BurstRamp`
    /// idiom.
    static func moveSpan(forAppliedEase seconds: Double) -> ReframeTrack.Move.Span {
        if seconds >= 1.99 { return .two }
        if seconds >= 0.99 { return .one }
        return .half
    }

    /// Materialise the whole track from per-stretch answers. `punches` is
    /// aligned with the warp's stretches; `seamEase` reports what each seam's
    /// ease really compiled to (nil while no compile is available).
    static func track(
        punches: [GuidedPunch],
        warp: WarpTimeline,
        seamEase: (Int) -> WarpCompiler.SeamEase?,
        aspect: Double,
        sourceSize: CGSize
    ) -> ReframeTrack {
        var track = ReframeTrack()
        guard punches.count == warp.stretchCount,
              punches.contains(where: { $0.isPunched }),
              sourceSize.width > 0
        else { return track }

        let spacing = ReframeTrack.minimumKeySpacing
        let wide = GuidedFraming.wide(sourceSize: sourceSize)
        /// The framing the clip is holding as the walk reaches each seam.
        var current = wide

        func clamped(_ framing: GuidedFraming) -> GuidedFraming {
            let z = min(max(framing.z, ReframeTrack.minZoom), ReframeTrack.maxZoom)
            let centre = ReframeMath.clampCenter(
                z: z, cx: framing.cx, cy: framing.cy, aspect: aspect, sourceSize: sourceSize)
            return GuidedFraming(z: z, cx: centre.cx, cy: centre.cy)
        }

        func addKey(t: Double, _ framing: GuidedFraming) -> Int {
            let f = clamped(framing)
            return track.addKey(t: t, z: f.z, cx: f.cx, cy: f.cy)
        }

        /// Key `framing` as the arrival of the transition across the seam
        /// into `stretch`, the move riding the seam's ramp.
        func addArrival(into stretch: Int, _ framing: GuidedFraming) {
            let seamIndex = stretch - 1
            let ease: WarpCompiler.SeamEase? = warp.seams.indices.contains(seamIndex)
                ? (warp.seams[seamIndex].ramp == .step ? nil : seamEase(seamIndex))
                : nil
            let applied = ease?.applied
                ?? (warp.seams.indices.contains(seamIndex) && warp.seams[seamIndex].ramp != .step
                    ? warp.seams[seamIndex].ramp.seconds : 0)
            let lastT = track.keys.last?.t ?? -1
            if applied < 0.05 {
                // A step: pin the outgoing framing right at the seam so the
                // change can't smear across the gap, then arrive just after.
                // The tiny gap clamps the move to a handful of output frames.
                let pinT = max(
                    lastT + spacing * 1.2,
                    warp.bounds[stretch] - nudge(atSpeed: warp.speeds[stretch - 1]))
                _ = addKey(t: pinT, current)
                let index = addKey(
                    t: max(pinT + spacing * 1.2,
                           warp.bounds[stretch] + nudge(atSpeed: warp.speeds[stretch])),
                    framing)
                if index > 0 {
                    track.setMove(.init(span: .half, curve: .ease), at: index - 1)
                }
            } else {
                let t = max(lastT + spacing * 1.2,
                            arrivalTime(into: stretch, warp: warp, ease: ease))
                let index = addKey(t: t, framing)
                if index > 0 {
                    track.setMove(
                        .init(span: moveSpan(forAppliedEase: applied), curve: .ease),
                        at: index - 1)
                }
            }
            current = framing
        }

        for stretch in 0..<punches.count {
            var punch = punches[stretch]
            guard let entry = punch.entry else { continue }

            if track.isEmpty, stretch == 0 {
                // The clip opens in this framing — clamp-before-first-key
                // holds it from frame one.
                _ = addKey(t: 0, entry)
                current = entry
            } else {
                if track.isEmpty {
                    // Hold the default wide state from the top until the
                    // first transition.
                    _ = addKey(t: 0, wide)
                    current = wide
                }
                addArrival(into: stretch, entry)
            }

            // The pan drifts from the entry framing to the exit framing
            // across the whole stretch; the exit key parks just short of the
            // far boundary so the release move can pick it up there. A
            // stretch too short to hold two distinct keys degrades to a
            // still — the entry framing simply holds.
            if let exit = punch.exit {
                let entryT = track.keys.last?.t ?? warp.bounds[stretch]
                let exitCap = warp.bounds[stretch + 1] - nudge(atSpeed: warp.speeds[stretch])
                if exitCap - entryT >= spacing * 2 {
                    let exitT = min(exitCap, max(entryT + spacing * 2, warp.bounds[stretch + 1] - 0.1))
                    let eased: Bool = {
                        if case .pan(_, _, let eased) = punch { return eased }
                        return false
                    }()
                    let index = addKey(t: exitT, exit)
                    if index > 0 {
                        track.setMove(.init(span: .gap, curve: eased ? .ease : .linear), at: index - 1)
                    }
                    current = exit
                } else {
                    punch = .still(entry)
                }
            }

            // Release back to the default wide state across the next seam —
            // unless the next stretch carries its own punch, in which case
            // its arrival IS the transition.
            if stretch + 1 < punches.count, !punches[stretch + 1].isPunched {
                addArrival(into: stretch + 1, wide)
            }
        }

        return track
    }

    /// Best-effort inverse of `track(punches:...)`, for re-entering the
    /// builder while its materialised track is still on the model (cancelled
    /// render, "adjust again" from the result screen). Punched keys belong to
    /// the stretch they sit in; two distinct punched framings in one stretch
    /// read back as a pan. Wide keys are holds and releases — structure, not
    /// answers — so they are ignored.
    static func punches(from track: ReframeTrack, warp: WarpTimeline) -> [GuidedPunch] {
        var result = [GuidedPunch](repeating: .none, count: warp.stretchCount)
        guard !track.isEmpty else { return result }
        for stretch in 0..<warp.stretchCount {
            let range = warp.range(of: stretch)
            let punched = track.keys.enumerated().filter {
                range.contains($0.element.t) && $0.element.z > 1.02
            }
            guard let first = punched.first else { continue }
            let from = GuidedFraming(
                z: first.element.z, cx: first.element.cx, cy: first.element.cy)
            if let last = punched.last, last.offset != first.offset {
                let to = GuidedFraming(
                    z: last.element.z, cx: last.element.cx, cy: last.element.cy)
                if to == from {
                    // A step-release pin duplicates the framing it holds —
                    // that is a still punch, not a pan.
                    result[stretch] = .still(from)
                } else {
                    let eased = track.moves.indices.contains(last.offset - 1)
                        && track.moves[last.offset - 1].curve == .ease
                    result[stretch] = .pan(from: from, to: to, eased: eased)
                }
            } else {
                result[stretch] = .still(from)
            }
        }
        return result
    }

    /// Content equality for materialised tracks — `ReframeTrack.Key` carries
    /// a fresh `UUID` per key, so `==` can never match two independently
    /// built tracks even when they describe the identical crop path.
    static func tracksEquivalent(_ a: ReframeTrack, _ b: ReframeTrack) -> Bool {
        guard a.keys.count == b.keys.count, a.moves == b.moves else { return false }
        return zip(a.keys, b.keys).allSatisfy {
            abs($0.t - $1.t) < 0.0001 && abs($0.z - $1.z) < 0.0001
                && abs($0.cx - $1.cx) < 0.01 && abs($0.cy - $1.cy) < 0.01
        }
    }
}
