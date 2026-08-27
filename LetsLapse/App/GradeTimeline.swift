import Foundation

/// One control of the adjustment panel, as a value both the timeline and the
/// panel can name.
///
/// The panel needs it to mark which sliders travel over time; the timeline
/// needs it to reset one property at one moment. Raw values are written into
/// nothing persistent — the keyframes store whole `PhotoAdjustments` — so this
/// is free to change with the panel.
enum PhotoAdjustmentField: String, CaseIterable, Sendable {
    case exposure, contrast, highlights, shadows, whites, blacks
    case temperature, tint, vibrance, saturation, clarity, vignetteIntensity
    case texture, sharpen, noiseReduction, colorNoiseReduction
    case sharpenMasking, noiseDetail, colorNoise

    var keyPath: WritableKeyPath<PhotoAdjustments, Float> {
        switch self {
        case .exposure: return \.exposure
        case .contrast: return \.contrast
        case .highlights: return \.highlights
        case .shadows: return \.shadows
        case .whites: return \.whites
        case .blacks: return \.blacks
        case .temperature: return \.temperature
        case .tint: return \.tint
        case .vibrance: return \.vibrance
        case .saturation: return \.saturation
        case .clarity: return \.clarity
        case .texture: return \.texture
        case .sharpen: return \.sharpen
        case .sharpenMasking: return \.sharpenMasking
        case .noiseReduction: return \.noiseReduction
        case .noiseDetail: return \.noiseDetail
        case .colorNoiseReduction: return \.colorNoiseReduction
        case .colorNoise: return \.colorNoise
        case .vignetteIntensity: return \.vignetteIntensity
        }
    }

    /// The value that means "this control is saying nothing" — 0 for every
    /// field but the two-sided `noiseDetail`, whose no-op is mid-travel. Every
    /// reset goes through here rather than writing a zero.
    var neutralValue: Float { PhotoAdjustments.neutral[keyPath: keyPath] }

    var range: ClosedRange<Float> {
        switch self {
        case .exposure: return PhotoAdjustments.exposureRange
        case .contrast: return PhotoAdjustments.contrastRange
        case .highlights: return PhotoAdjustments.highlightsRange
        case .shadows: return PhotoAdjustments.shadowsRange
        case .whites: return PhotoAdjustments.whitesRange
        case .blacks: return PhotoAdjustments.blacksRange
        case .temperature: return PhotoAdjustments.temperatureRange
        case .tint: return PhotoAdjustments.tintRange
        case .vibrance: return PhotoAdjustments.vibranceRange
        case .saturation: return PhotoAdjustments.saturationRange
        case .clarity: return PhotoAdjustments.clarityRange
        case .texture: return PhotoAdjustments.textureRange
        case .sharpen: return PhotoAdjustments.sharpenRange
        case .sharpenMasking: return PhotoAdjustments.sharpenMaskingRange
        case .noiseReduction: return PhotoAdjustments.noiseReductionRange
        case .noiseDetail: return PhotoAdjustments.noiseDetailRange
        case .colorNoiseReduction: return PhotoAdjustments.colorNoiseReductionRange
        case .colorNoise: return PhotoAdjustments.colorNoiseRange
        case .vignetteIntensity: return PhotoAdjustments.vignetteRange
        }
    }

    /// How far this field has to move before the difference counts.
    ///
    /// Expressed as a fraction of the control's own travel rather than as an
    /// absolute, because the fields don't share units: ±1 for most, ±5 EV for
    /// exposure, ±150 mired for temperature. 0.75% of travel is a fifth of a
    /// point on the ±100 scale the readouts show — below what anyone can dial
    /// in deliberately, above the drift a smoothstep round-trip leaves behind.
    var epsilon: Float { (range.upperBound - range.lowerBound) * 0.0075 }
}

/// One moment of a shoot with a grade pinned to it.
///
/// The values are a whole panel, not a delta: every field is stored, so
/// rendering any moment is one interpolation rather than a fold over
/// everything before it, and deleting a keyframe can never leave a field
/// dangling.
struct GradeKeyframe: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// Where in the source capture this moment sits, 0…1.
    ///
    /// Normalized rather than a frame index on purpose. It has to mean the same
    /// thing for a shoot of stills and for a movie, it has to survive a
    /// tail-frame exclusion dropping frames out of the blend, and — the point
    /// the brief makes — it has to be immune to the speed layer: a warp that
    /// makes the middle of the clip play slower moves no keyframe, because a
    /// keyframe is a position in the *source*, not in the output.
    var position: Double
    var adjustments: PhotoAdjustments

    init(id: UUID = UUID(), position: Double, adjustments: PhotoAdjustments) {
        self.id = id
        self.position = min(max(position, 0), 1)
        self.adjustments = adjustments
    }
}

/// A project's grade over time: the keyframes, and where the whole-clip grade
/// that preceded them was authored.
///
/// The model has two levels on purpose, and the empty one is the one people
/// start in:
///
/// - **No keyframes.** The project's `PhotoAdjustments` grade the whole shoot,
///   exactly as they always have. Nothing about the screen says "keyframe".
/// - **Keyframes.** Two or more moments, each holding a whole panel; every
///   frame between them is the smoothstep blend of its neighbours, and every
///   frame outside them holds the nearest one. The stored `PhotoAdjustments`
///   stop grading anything and become a mirror of the opening moment, so the
///   surfaces that know nothing about time — thumbnails, the project card, a
///   single-still export — keep showing the look the clip opens on.
///
/// The leap between the two is never a mode switch. It happens the first time
/// someone edits at a *second* position: the grade they had becomes a keyframe
/// where they authored it (`baselineAnchor`), the edit becomes a keyframe where
/// they are now, and two dots appear on the timeline. That is the whole
/// announcement — there is no coach mark and no button.
struct GradeTimeline: Codable, Equatable, Sendable {
    /// Always sorted by position. Private setter so no caller can break that.
    private(set) var keyframes: [GradeKeyframe]

    /// Where the whole-clip grade was authored, 0…1, or nil while the project
    /// has never been graded at all.
    ///
    /// Only ever read while `keyframes` is empty, and only to answer one
    /// question: is this edit at the same moment as the last one (still one
    /// grade for the whole shoot) or somewhere else (two moments, therefore a
    /// timeline)? Persisted so reopening the editor doesn't quietly answer it
    /// differently from the session that made the grade.
    var baselineAnchor: Double?

    static let empty = GradeTimeline(keyframes: [], baselineAnchor: nil)

    init(keyframes: [GradeKeyframe] = [], baselineAnchor: Double? = nil) {
        self.keyframes = keyframes.sorted { $0.position < $1.position }
        self.baselineAnchor = baselineAnchor
    }

    var isEmpty: Bool { keyframes.isEmpty }

    /// How close a position has to be to a keyframe to *be* that keyframe —
    /// a fraction of the whole clip. About 4pt on a phone-width track, which is
    /// under a fingertip and over a rounding error.
    static let snapTolerance: Double = 0.012

    // MARK: - Reading

    /// The grade at `position`.
    ///
    /// Between two keyframes it is their smoothstep blend — ease-in-out, fixed,
    /// with no curve editor anywhere. Keyframe density is the only speed
    /// control there is: a pair an hour apart is a sunset drifting, a pair a few
    /// frames apart is a tram going past. Before the first keyframe and after
    /// the last the nearest one holds, so a grade never fades toward nothing at
    /// the ends of a clip.
    ///
    /// With no keyframes the baseline is the answer everywhere, which is what
    /// makes an ungraded-over-time project behave exactly as it did before.
    func adjustments(at position: Double, baseline: PhotoAdjustments) -> PhotoAdjustments {
        adjustments(at: position, baseline: baseline, excluding: nil)
    }

    /// `adjustments(at:baseline:)` as it would be if `excluded` didn't exist —
    /// the question "what is this keyframe actually contributing", which is how
    /// a keyframe knows it has become redundant.
    func adjustments(
        at position: Double, baseline: PhotoAdjustments, excluding excluded: UUID?
    ) -> PhotoAdjustments {
        let frames = excluded.map { id in keyframes.filter { $0.id != id } } ?? keyframes
        guard let first = frames.first, let last = frames.last else { return baseline }
        if position <= first.position { return first.adjustments }
        if position >= last.position { return last.adjustments }
        for (before, after) in zip(frames, frames.dropFirst())
        where position >= before.position && position <= after.position {
            let span = after.position - before.position
            guard span > 0 else { return after.adjustments }
            let u = (position - before.position) / span
            return Self.blend(before.adjustments, after.adjustments, u)
        }
        return last.adjustments
    }

    /// Smoothstep: zero slope at both ends, so a keyframe is a moment the grade
    /// arrives at and leaves from rather than a corner it turns.
    private static func blend(
        _ a: PhotoAdjustments, _ b: PhotoAdjustments, _ u: Double
    ) -> PhotoAdjustments {
        let t = Float(u * u * (3 - 2 * u))
        var out = a
        for field in PhotoAdjustmentField.allCases {
            let path = field.keyPath
            out[keyPath: path] = a[keyPath: path] + (b[keyPath: path] - a[keyPath: path]) * t
        }
        return out
    }

    /// The keyframe at `position`, within `snapTolerance` — the one an edit
    /// lands on instead of making a new one.
    func keyframe(at position: Double, tolerance: Double = GradeTimeline.snapTolerance)
        -> GradeKeyframe? {
        keyframes.min { abs($0.position - position) < abs($1.position - position) }
            .flatMap { abs($0.position - position) <= tolerance ? $0 : nil }
    }

    /// The fields that actually travel — what the panel puts a diamond beside.
    ///
    /// A single keyframe grades the whole clip with one set of values, so it
    /// marks nothing: "keyframed" is a claim about change over time, and one
    /// moment can't make it.
    var keyframedFields: Set<PhotoAdjustmentField> {
        guard keyframes.count > 1 else { return [] }
        var fields: Set<PhotoAdjustmentField> = []
        for field in PhotoAdjustmentField.allCases {
            let values = keyframes.map { $0.adjustments[keyPath: field.keyPath] }
            guard let low = values.min(), let high = values.max() else { continue }
            if high - low > field.epsilon { fields.insert(field) }
        }
        return fields
    }

    /// A short, stable string for the render cache key.
    var cacheToken: String {
        guard !keyframes.isEmpty else { return "" }
        return keyframes
            .map { String(format: "%.4f@", $0.position) + $0.adjustments.cacheToken }
            .joined(separator: ";")
    }

    // MARK: - Editing

    /// What a write did, so the caller can tell a new moment from a changed one.
    enum EditOutcome: Equatable {
        /// Nothing moved.
        case none
        /// The whole-clip grade moved; there are still no keyframes.
        case baseline
        /// An existing keyframe took the new values.
        case updated(UUID)
        /// One or more keyframes came into being — the ids, in position order.
        case created([UUID])
    }

    /// Writes `values` at `position` — the one rule that decides whether an
    /// edit grades the shoot or grades a moment.
    ///
    /// `baseline` is the project's whole-clip grade, and this may rewrite it:
    /// while no keyframes exist an edit *is* the whole-clip grade. The first
    /// edit made somewhere other than where that grade was authored is the one
    /// that changes everything — it materialises the anchor as a keyframe
    /// alongside the new moment, which is when the two dots appear.
    @discardableResult
    mutating func write(
        _ values: PhotoAdjustments, at position: Double, baseline: inout PhotoAdjustments
    ) -> EditOutcome {
        let position = min(max(position, 0), 1)
        if let existing = keyframe(at: position) {
            update(existing.id, to: values)
            // The opening moment is mirrored into the baseline, so editing the
            // first keyframe has to move it too — otherwise every surface that
            // can only hold one grade (card, thumbnail, still export) keeps
            // showing a look this clip no longer opens on.
            baseline = adjustments(at: 0, baseline: baseline)
            return .updated(existing.id)
        }
        guard !keyframes.isEmpty else {
            guard let anchor = baselineAnchor,
                  abs(anchor - position) > Self.snapTolerance else {
                // Still the one grade for the whole shoot: either nothing has
                // ever been graded, or this is the same moment as last time.
                baseline = values
                baselineAnchor = baselineAnchor ?? position
                return .baseline
            }
            let held = GradeKeyframe(position: anchor, adjustments: baseline)
            let fresh = GradeKeyframe(position: position, adjustments: values)
            keyframes = [held, fresh].sorted { $0.position < $1.position }
            baseline = adjustments(at: 0, baseline: baseline)
            return .created(keyframes.map(\.id))
        }
        let fresh = GradeKeyframe(position: position, adjustments: values)
        keyframes.append(fresh)
        keyframes.sort { $0.position < $1.position }
        baseline = adjustments(at: 0, baseline: baseline)
        return .created([fresh.id])
    }

    /// Returns one field at `position` to what the rest of the timeline says it
    /// should be — the panel's double-tap-a-label reset, made time-aware.
    ///
    /// On a keyframe this takes the field back to the value its neighbours
    /// interpolate to, which is precisely "stop saying anything here about this
    /// property". When that leaves the keyframe with nothing left to say, it
    /// removes itself: the dot disappears rather than sitting on the timeline
    /// as a moment that changes nothing.
    @discardableResult
    mutating func resetField(
        _ field: PhotoAdjustmentField, at position: Double, baseline: inout PhotoAdjustments
    ) -> EditOutcome {
        guard let target = keyframe(at: position) else {
            // Between keyframes there is no single moment to reset — the value
            // here is two other moments' business.
            guard keyframes.isEmpty else { return .none }
            baseline[keyPath: field.keyPath] = field.neutralValue
            return .baseline
        }
        // What this moment would say about the property if it weren't here.
        // With neighbours to interpolate between, that is their blend. With no
        // neighbours the moment IS the whole clip's grade — and the baseline is
        // only a mirror of it, so asking the baseline would compare the value
        // against itself and the reset would silently do nothing. Neutral is
        // the honest reference there, and it is what a reset means on a clip
        // with no keyframes at all.
        let without = keyframes.count > 1
            ? adjustments(at: target.position, baseline: baseline, excluding: target.id)
            : .neutral
        var values = target.adjustments
        values[keyPath: field.keyPath] = without[keyPath: field.keyPath]
        let saysNothing = PhotoAdjustmentField.allCases.allSatisfy {
            abs(values[keyPath: $0.keyPath] - without[keyPath: $0.keyPath]) <= $0.epsilon
        }
        // A moment that no longer says anything retires — including the last
        // one, which by the reference above has been reset to neutral, so what
        // it leaves behind is an ungraded clip rather than a discarded grade.
        if saysNothing {
            remove(target.id, baseline: &baseline)
            return .updated(target.id)
        }
        update(target.id, to: values)
        baseline = adjustments(at: 0, baseline: baseline)
        return .updated(target.id)
    }

    /// Replaces one keyframe's values wholesale.
    mutating func update(_ id: UUID, to values: PhotoAdjustments) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }) else { return }
        keyframes[index].adjustments = values
    }

    /// Deletes a keyframe. The clip re-interpolates around the hole — with one
    /// keyframe left the whole shoot takes its values, and with none left the
    /// baseline grades everything again, which is where the screen came from.
    mutating func remove(_ id: UUID, baseline: inout PhotoAdjustments) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }) else { return }
        let removed = keyframes.remove(at: index)
        guard !keyframes.isEmpty else {
            // The last dot out takes the grade with it rather than leaving the
            // project on whatever the opening frame happened to be: the values
            // are still on screen, now as one grade for the whole shoot again.
            baseline = removed.adjustments
            baselineAnchor = removed.position
            return
        }
        baseline = adjustments(at: 0, baseline: baseline)
    }

    /// Every keyframe gone, with the baseline left holding the grade — what
    /// "Reset adjustments" and an Original chip both need.
    mutating func clear() {
        keyframes = []
        baselineAnchor = nil
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case keyframes = "k"
        case baselineAnchor = "a"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent([GradeKeyframe].self, forKey: .keyframes)
        let anchor = try container.decodeIfPresent(Double.self, forKey: .baselineAnchor)
        self.init(keyframes: stored ?? [], baselineAnchor: anchor)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyframes, forKey: .keyframes)
        try container.encodeIfPresent(baselineAnchor, forKey: .baselineAnchor)
    }
}

/// Where each frame of a rendered clip sits in the **source**, 0…1.
///
/// A keyframe is a position in the source, and the brief is explicit about why:
/// the speed layer must never move one. That promise costs nothing while the
/// two clocks agree — a straight grade pass over a movie renders output second
/// 12 from source second 12 — and everything once they don't. A warp, a burst
/// ramp or a blend all hand the next pass a clip whose second 12 came from
/// somewhere else entirely, and a pass that grades by its own clock would smear
/// the whole timeline across the wrong frames.
///
/// So every pass that bakes a keyframed grade takes one of these. `.direct` is
/// the honest default for a pass whose input is the source itself.
struct GradeSourceMap: Sendable, Equatable {
    /// Source position per output frame. Empty means the clocks agree.
    var positions: [Double]
    /// The rate `positions` is indexed at.
    var outputFPS: Double

    /// Output time is source time.
    static let direct = GradeSourceMap(positions: [], outputFPS: 0)

    /// A map from the source seconds each output frame was drawn from — what a
    /// compiled warp already knows — over a source of `sourceDuration` seconds.
    static func from(frameSourceSeconds: [Double], outputFPS: Double, sourceDuration: Double)
        -> GradeSourceMap {
        guard !frameSourceSeconds.isEmpty, outputFPS > 0, sourceDuration > 0 else { return .direct }
        return GradeSourceMap(
            positions: frameSourceSeconds.map { min(max($0 / sourceDuration, 0), 1) },
            outputFPS: outputFPS)
    }

    var isDirect: Bool { positions.isEmpty }

    /// The source position an output frame shows.
    func position(outputSeconds: Double, outputDuration: Double) -> Double {
        guard !positions.isEmpty, outputFPS > 0 else {
            guard outputDuration > 0 else { return 0 }
            return min(max(outputSeconds / outputDuration, 0), 1)
        }
        let index = Int((outputSeconds * outputFPS).rounded())
        return positions[min(max(index, 0), positions.count - 1)]
    }
}
