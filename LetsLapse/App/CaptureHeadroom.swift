import Foundation
import SwiftUI

// How much shoot is left in the device — the answer to the one question the
// capture screen could never answer before you found out the hard way.
//
// A timelapse is the worst possible shape of run to discover a full disk in.
// It is unattended by design, it is long by design, and the thing it produces
// only becomes a thing at the end: a video shoot that dies at 80% is a shorter
// video, but an interval shoot that dies at 80% is an interval shoot whose
// last frame is wherever the disk gave out — often hours before the light did,
// and always without anybody there to notice. So the number belongs on screen
// *before* the shutter, next to the format that decides it.
//
// **Everything here is an estimate and says so** (the chip leads with "≈").
// What varies is how good an estimate: a shape this device has already shot is
// reported from what that shoot actually weighed, and one it hasn't is
// reported from the model below. The two are not distinguished on the chip —
// a number the reader has to grade is worse than one they can act on — but
// they are distinguished in the store, and the modelled one is replaced by a
// measured one the first time a run of that shape finishes.

// MARK: - The shape of a shoot

/// A shoot reduced to the things that decide what it weighs: what kind of file
/// it writes, how big each one is, and (for movies) how many per second.
///
/// Deliberately **not** keyed on blend depth, which is the one capture dial
/// that looks like it should matter here and doesn't: a blend of 20 frames
/// writes one image, exactly as a blend of 3 does and exactly as Off does. The
/// depth costs time, heat and battery — it is free on disk.
struct CaptureCostKey: Hashable {
    enum Family: String {
        /// A processed still — JPEG or HEIC, whatever the pipeline emits.
        case still
        /// A Bayer RAW still. An order of magnitude heavier than `still`, and
        /// the reason this screen needs a headroom readout at all.
        case raw
        /// A compressed movie (H.264/HEVC).
        case movie
        /// An intra-frame movie (ProRes). Also an order of magnitude, in the
        /// other direction from `movie`.
        case proRes
    }

    var family: Family
    var width: Int
    var height: Int
    /// Frames per second for the movie families; 0 for stills, which have no
    /// rate of their own (EVERY paces them, and that lives outside the cost).
    var frameRate: Int

    /// Stable across launches — it is a defaults key.
    var token: String { "\(family.rawValue)/\(width)x\(height)@\(frameRate)" }

    var pixels: Double { Double(width) * Double(height) }
}

/// What one unit of a shoot weighs.
struct CaptureCost: Equatable {
    enum Unit { case frame, second }

    var unit: Unit
    var bytes: Double
    /// True when this came from a run this device really did, rather than from
    /// `CaptureCostKey.modelledCost`.
    var isMeasured: Bool
}

extension CaptureCostKey {
    /// What a frame — or a second — of this shape weighs before this device
    /// has shot one.
    ///
    /// **The per-pixel constants, and where they come from.** Each is a real
    /// measured figure reduced to bytes per pixel so it survives a sensor or a
    /// resolution nobody has tested:
    ///
    /// - `raw` **1.5 B/px** — a 12 MP lossless-compressed Bayer DNG weighs
    ///   ~19 MB, the same figure `AppModel`'s storage cache comments quote
    ///   from real project folders ("a hundred 19 MB DNGs").
    /// - `still` **0.25 B/px** — a 12 MP camera JPEG at Apple's default
    ///   quality lands around 3 MB. HEIC comes in well under this, so the
    ///   estimate errs toward reporting less headroom than there is, which is
    ///   the direction a storage warning should err in.
    /// - `proRes` **0.44 B/px/frame** — ProRes 422 HQ's published target of
    ///   220 Mb/s at 1080p30 (27.5 MB/s ÷ 62.2 Mpx/s).
    /// - `movie` **0.012 B/px/frame** — iPhone HEVC measures 0.0107 B/px at
    ///   1080p30 and 0.0114 at 4K30, rising with rate; the constant sits just
    ///   above both. **This one is a last resort**: the encoder knows its own
    ///   bitrate, and `CaptureHeadroom.reading` prefers that whenever the
    ///   camera can report it (see `CameraController.movieBytesPerSecond`).
    var modelledCost: CaptureCost {
        switch family {
        case .raw:
            return CaptureCost(unit: .frame, bytes: pixels * 1.5, isMeasured: false)
        case .still:
            return CaptureCost(unit: .frame, bytes: pixels * 0.25, isMeasured: false)
        case .proRes:
            return CaptureCost(
                unit: .second, bytes: pixels * 0.44 * Double(max(frameRate, 1)), isMeasured: false)
        case .movie:
            return CaptureCost(
                unit: .second, bytes: pixels * 0.012 * Double(max(frameRate, 1)), isMeasured: false)
        }
    }
}

// MARK: - What runs have taught

/// Per-shape capture costs learned from finished runs, so the second shoot of
/// a configuration is estimated from what the first one actually weighed.
///
/// The same idea as `BlendProfileStore`, and deliberately the same shape: a
/// small defaults-backed table that starts empty, is written only by runs long
/// enough to mean something, and is read as a *better* answer than the model
/// rather than as the only one. Nothing breaks when it is empty — that is the
/// state every install ships in.
///
/// **Measured against free space, not against the files.** A run's cost here
/// is how much the volume actually lost while it ran, divided by what the run
/// produced — which is the number the question "will this fit?" is really
/// asking about. Counting the project's own bytes would miss everything else a
/// shoot puts on the disk (staging copies, sidecars, thumbnails, the log), and
/// those are exactly the bytes that make a shoot land differently from the sum
/// of its frames.
final class CaptureCostStore {
    static let shared = CaptureCostStore()

    private let defaultsKey = "letslapse.capture.costBytes"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Never learn from a scrap. A three-frame run is mostly the fixed cost of
    /// opening a shoot, and a two-second movie is mostly the encoder settling.
    private static let minimumFrames = 8
    private static let minimumSeconds: Double = 5

    func cost(for key: CaptureCostKey) -> CaptureCost? {
        guard let table = defaults.dictionary(forKey: defaultsKey) as? [String: Double],
              let bytes = table[key.token], bytes > 0 else { return nil }
        let unit: CaptureCost.Unit =
            (key.family == .still || key.family == .raw) ? .frame : .second
        return CaptureCost(unit: unit, bytes: bytes, isMeasured: true)
    }

    /// Folds a finished run into the table.
    ///
    /// Blended half-and-half with whatever was there rather than replacing it:
    /// a single shoot's cost is a real measurement of one scene, and scene is
    /// most of what a JPEG weighs. Averaging tracks a genuine change (a new
    /// lens, a new format) within a couple of runs while refusing to let one
    /// shot of a white wall claim that stills are tiny now.
    func record(key: CaptureCostKey, consumedBytes: Int64, units: Double) {
        guard consumedBytes > 0, units > 0 else { return }
        switch key.family {
        case .still, .raw:
            guard units >= Double(Self.minimumFrames) else { return }
        case .movie, .proRes:
            guard units >= Self.minimumSeconds else { return }
        }
        let sample = Double(consumedBytes) / units
        // A run that somehow "freed" space, or one whose delta is dominated by
        // something else on the device, teaches nothing worth keeping.
        guard sample.isFinite, sample > 0 else { return }
        var table = defaults.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        table[key.token] = table[key.token].map { ($0 + sample) / 2 } ?? sample
        defaults.set(table, forKey: defaultsKey)
    }

    func reset() {
        defaults.removeObject(forKey: defaultsKey)
    }
}

// MARK: - The reading

enum CaptureHeadroom {
    /// How much room is left, in the units the armed mode is counted in.
    struct Reading: Equatable {
        var freeBytes: Int64
        var cost: CaptureCost

        /// Whole outputs that still fit. nil for a movie shape, which is
        /// measured in time rather than frames.
        var frames: Int? {
            guard cost.unit == .frame, cost.bytes > 0 else { return nil }
            return Int((Double(freeBytes) / cost.bytes).rounded(.down))
        }

        /// Seconds of recording that still fit. nil for a still shape.
        var seconds: Double? {
            guard cost.unit == .second, cost.bytes > 0 else { return nil }
            return Double(freeBytes) / cost.bytes
        }

        /// How close this is to being a problem.
        ///
        /// **Two thresholds, and each is an absolute rather than a fraction of
        /// the disk.** "10% left" means nothing to a shoot — a 10% of 2 TB is
        /// a weekend of DNGs and 10% of a full 128 GB phone is ninety seconds
        /// of ProRes. What the operator needs to know is whether the *shoot*
        /// in front of them fits, so the levels are set in shoot units: about
        /// an hour of frames, and about a couple of minutes of them.
        var level: Level {
            if let frames {
                if frames <= 30 { return .critical }
                if frames <= 240 { return .low }
            }
            if let seconds {
                if seconds <= 120 { return .critical }
                if seconds <= 600 { return .low }
            }
            // A volume this close to full is a warning whatever the format
            // arithmetic says: the app is not the only thing writing to it.
            if freeBytes < 512 * 1_000_000 { return .critical }
            if freeBytes < 2 * 1_000_000_000 { return .low }
            return .ok
        }

        enum Level { case ok, low, critical }
    }

    /// Free space on the volume the library lives on.
    ///
    /// `volumeAvailableCapacityForImportantUsage` rather than the raw free
    /// count: it is the figure that includes space the system would purge to
    /// make room, which is the space a capture would really get. Runs on a
    /// background queue — it is a `statfs`, and this is called from a screen
    /// that is also driving a camera.
    static func freeBytes(near url: URL) async -> Int64? {
        await Task.detached(priority: .utility) {
            let values = try? url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        }.value
    }

    /// The best cost available for this shape: what a run taught, else what
    /// the encoder says it will do, else the model.
    static func cost(for key: CaptureCostKey, encoderBytesPerSecond: Double?) -> CaptureCost {
        if let learned = CaptureCostStore.shared.cost(for: key) { return learned }
        if let encoderBytesPerSecond, encoderBytesPerSecond > 0,
           key.family == .movie || key.family == .proRes {
            // Not flagged as measured: it is the encoder's *intent*, which a
            // variable-bitrate pass only approximately keeps. Good enough to
            // beat the per-pixel constant, not good enough to stop a real run
            // from overwriting it.
            return CaptureCost(unit: .second, bytes: encoderBytesPerSecond, isMeasured: false)
        }
        return key.modelledCost
    }

    // MARK: Formatting

    /// Frame counts, kept to four characters or so — this sits in a 108 pt
    /// landscape rail as well as a roomy portrait top bar.
    static func framesText(_ frames: Int) -> String {
        if frames >= 100_000 { return "\(frames / 1000)k" }
        if frames >= 10_000 {
            return String(format: "%.1fk", Double(frames) / 1000)
        }
        return frames.formatted(.number.grouping(.automatic))
    }

    /// Recording time, coarsening as it grows: seconds matter when there are
    /// only seconds left, and are noise once there are hours.
    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        if total >= 3600 {
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        if total >= 60 { return "\(total / 60)m" }
        return "\(max(total, 0))s"
    }
}

// MARK: - The chip

/// The capture screen's headroom readout: what is left, in the units of the
/// mode that is armed.
///
/// Beside the format pill because the format pill is what changes it — DNG and
/// ProRes are each an order of magnitude on this number, and the two controls
/// answering each other in the same corner is the whole point. It is a plain
/// readout, not a button: everything else on this bar opens something, and a
/// tappable number here would promise an action the capture screen has no
/// business offering mid-shoot.
///
/// `Equatable` for the reason every view in `CaptureDials.swift` is — the body
/// that hosts it is invalidated by around forty observers, and this one draws
/// a value that moves every few seconds at most.
struct CaptureHeadroomChip: View, Equatable {
    let reading: CaptureHeadroom.Reading
    /// Whether there is room for the free-space half. The landscape rail is
    /// 108 pt, which the primary value fills on its own.
    var showsFreeSpace: Bool = true

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.reading == rhs.reading && lhs.showsFreeSpace == rhs.showsFreeSpace
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "internaldrive")
                .font(.system(size: 10, weight: .semibold))
            Text(primaryText)
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
            if showsFreeSpace {
                Text("· \(LLFormat.bytes(reading.freeBytes))")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .foregroundStyle(tint)
        // Same discipline as the format pill beside it: these are atoms, laid
        // out at their ideal width or not at all, so a narrow rail can never
        // break "2,400" across two lines.
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(background, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage remaining")
        .accessibilityValue(accessibilityValue)
    }

    /// The "≈" is load-bearing. Every number on this chip is an estimate, and
    /// one presented as exact would be believed the one time it matters.
    private var primaryText: String {
        if let frames = reading.frames { return "≈\(CaptureHeadroom.framesText(frames))" }
        if let seconds = reading.seconds { return "≈\(CaptureHeadroom.durationText(seconds))" }
        return LLFormat.bytes(reading.freeBytes)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let frames = reading.frames {
            parts.append("about \(frames.formatted()) more shots")
        } else if let seconds = reading.seconds {
            parts.append("about \(CaptureHeadroom.durationText(seconds)) more recording")
        }
        parts.append("\(LLFormat.bytes(reading.freeBytes)) free")
        return parts.joined(separator: ", ")
    }

    private var tint: Color {
        switch reading.level {
        case .ok: return .white
        case .low: return LL.amber
        case .critical: return Color(red: 1, green: 0.42, blue: 0.35)
        }
    }

    private var background: Color {
        switch reading.level {
        case .ok: return Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9)
        case .low: return LL.amber.opacity(0.18)
        case .critical: return Color(red: 1, green: 0.42, blue: 0.35).opacity(0.2)
        }
    }
}
