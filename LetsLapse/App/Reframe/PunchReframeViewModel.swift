import AVFoundation
import Foundation
import Observation
import SwiftUI

/// Everything the Punch-In Reframe screen edits, and nothing it draws.
///
/// The one rule the whole model enforces: a key is never half-edited. Every
/// mutation goes out through `commitKeys()`, which sorts, clamps and re-derives
/// auto-blend, so the timeline, the player and the estimate can never disagree.
@MainActor
@Observable
final class PunchReframeViewModel {
    enum BlendMode {
        /// Blend follows speed (a key can still be pinned with `ovr`).
        case auto
        /// Blend is chosen by hand, off the Off/Light/Medium/Heavy chips.
        case manual
    }

    /// One stretch of the warp bar, as a fraction of the source.
    struct Segment: Identifiable {
        let id: Int
        var start: Double
        var end: Double
        var startSpeed: Double
        var endSpeed: Double

        var isFlat: Bool { abs(startSpeed - endSpeed) < 0.01 }
        var span: Double { max(0, end - start) }
        var label: String { ReframeEngine.speedLabel(startSpeed) }
    }

    /// One keyframe's diamond on the scrubber lane.
    struct Diamond: Identifiable {
        let id: UUID
        var index: Int
        /// 0…1 across the source.
        var position: Double
        var blend: Double
        var isSelected: Bool
    }

    // MARK: - Source

    var sourceURL: URL?
    var sourceTitle: String
    var sourceSize: CGSize
    var sourceDuration: Double
    var sourceFPS: Double?

    // MARK: - Edit state

    var keys: [PunchKeyframe] = []
    var currentTime: Double = 0
    var selectedKeyIndex: Int = 0
    var ratio: ReframeRatio = .wide
    var isPlaying = false
    var blendMode: BlendMode = .auto
    var ratioMenuOpen = false
    var toast: String?
    var isExpanded = false
    var outputFPS: Int = 30
    /// Surfaced under the cards; the Create button writes here when the render
    /// refuses rather than failing silently.
    var errorMessage: String?

    /// A gesture at a time with no keyframe within this window carves a new
    /// one; inside it, the gesture edits the key that's already there.
    static let carveWindow = 1.5

    @ObservationIgnored private var gestureKeyID: UUID?
    @ObservationIgnored private var pinchBaseZoom: Double?
    @ObservationIgnored private var dragBaseCentre: (cx: Double, cy: Double)?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    // MARK: - Init

    init(
        url: URL? = nil,
        title: String = "Source",
        sourceSize: CGSize = CGSize(width: 3840, height: 2160),
        duration: Double = 0,
        fps: Double? = nil,
        ratio: ReframeRatio? = nil
    ) {
        self.sourceURL = url
        self.sourceTitle = title
        self.sourceSize = sourceSize
        self.sourceDuration = duration
        self.sourceFPS = fps
        self.ratio = ratio ?? ReframeRatio.nearest(
            to: sourceSize.height > 0 ? Double(sourceSize.width / sourceSize.height) : 16.0 / 9.0)
        seedKeys()
    }

    /// Fill in whatever the caller didn't know from the asset itself, then
    /// re-seed if the duration only just arrived (a zero-length seed has no
    /// shape to keep).
    func loadSourceMetadata() async {
        guard let sourceURL else { return }
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
        let duration = (try? await asset.load(.duration).seconds) ?? sourceDuration
        let natural = (try? await track.load(.naturalSize)) ?? sourceSize
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let fps = (try? await track.load(.nominalFrameRate)).map(Double.init)

        let displayed = natural.applying(transform)
        let size = CGSize(width: abs(displayed.width), height: abs(displayed.height))
        let previousDuration = sourceDuration

        if size.width > 0, size.height > 0 { sourceSize = size }
        if duration.isFinite, duration > 0 { sourceDuration = duration }
        if let fps, fps > 0 { sourceFPS = fps }

        // The seed is proportional, so a duration that turns out to be
        // materially different from what the caller believed leaves a shape
        // that means nothing — the keys would all clamp onto the end. This
        // runs before any edit, so re-seeding costs nothing.
        let drift = abs(sourceDuration - previousDuration)
        if sourceDuration > 0, drift > 0.05 * max(sourceDuration, previousDuration) {
            seedKeys()
        } else {
            commitKeys()
        }
    }

    /// The opening punch-in.
    func seedKeys() {
        keys = ReframeEngine.defaultKeys(sourceSize: sourceSize, duration: sourceDuration)
        selectedKeyIndex = min(2, max(0, keys.count - 1))
        currentTime = keys.indices.contains(selectedKeyIndex) ? keys[selectedKeyIndex].t : 0
    }

    // MARK: - Derived

    var selectedKey: PunchKeyframe? {
        keys.indices.contains(selectedKeyIndex) ? keys[selectedKeyIndex] : nil
    }

    var outputDuration: Double {
        ReframeEngine.outputDuration(keys: keys, sourceDuration: sourceDuration)
    }

    /// Where the playhead sits in the finished clip.
    var outputTime: Double {
        ReframeEngine.outputTime(at: currentTime, keys: keys, sourceDuration: sourceDuration)
    }

    /// 0…1 across the source — the playhead's x on every lane.
    var playLeft: Double {
        guard sourceDuration > 0 else { return 0 }
        return min(max(currentTime / sourceDuration, 0), 1)
    }

    var currentFrame: (z: Double, cx: Double, cy: Double, v: Double, bl: Double) {
        ReframeEngine.interp(t: currentTime, keys: keys)
    }

    var cropRect: CGRect {
        let frame = currentFrame
        return ReframeEngine.cropRect(
            z: frame.z, cx: frame.cx, cy: frame.cy, ratio: ratio, sourceSize: sourceSize)
    }

    var baseCropSize: CGSize {
        ReframeEngine.baseCrop(ratio: ratio, sourceSize: sourceSize)
    }

    /// The bar's stretches. Keys never cover the whole source (the first is
    /// rarely at 0 once you've edited), so the ends are held flat rather than
    /// left blank — that *is* what the render does with them.
    var segmentData: [Segment] {
        guard sourceDuration > 0, let first = keys.first, let last = keys.last else {
            return [Segment(id: 0, start: 0, end: 1, startSpeed: 1, endSpeed: 1)]
        }
        var out: [Segment] = []
        var id = 0
        if first.t > 0 {
            out.append(Segment(
                id: id, start: 0, end: first.t / sourceDuration,
                startSpeed: first.v, endSpeed: first.v))
            id += 1
        }
        for index in 1..<max(1, keys.count) where keys.count > 1 {
            let a = keys[index - 1]
            let b = keys[index]
            out.append(Segment(
                id: id, start: a.t / sourceDuration, end: b.t / sourceDuration,
                startSpeed: a.v, endSpeed: b.v))
            id += 1
        }
        if last.t < sourceDuration {
            out.append(Segment(
                id: id, start: last.t / sourceDuration, end: 1,
                startSpeed: last.v, endSpeed: last.v))
        }
        return out.filter { $0.span > 0.0005 }
    }

    var diamondData: [Diamond] {
        guard sourceDuration > 0 else { return [] }
        return keys.enumerated().map { index, key in
            Diamond(
                id: key.id,
                index: index,
                position: min(max(key.t / sourceDuration, 0), 1),
                blend: key.bl,
                isSelected: index == selectedKeyIndex)
        }
    }

    /// The key the playhead is parked on, if any — what the badge and the
    /// "On K3" label report, and what a gesture would edit.
    var onKeyframeIndex: Int? {
        nearestKeyIndex(to: currentTime, within: Self.carveWindow)
    }

    var canRemove: Bool { keys.count > 2 }

    // MARK: - Selection

    func selectKeyframe(_ index: Int) {
        guard keys.indices.contains(index) else { return }
        selectedKeyIndex = index
        currentTime = keys[index].t
    }

    func nearestKeyIndex(to t: Double, within window: Double) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, key) in keys.enumerated() {
            let distance = abs(key.t - t)
            guard distance <= window else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    // MARK: - Keyframes

    /// The key a gesture at `t` should edit — the one already there, or a new
    /// one carved from the interpolated frame so the picture never jumps at
    /// the moment you touch it.
    @discardableResult
    func ensureKey(at t: Double, withToast: Bool = true) -> Int {
        let time = min(max(t, 0), max(0, sourceDuration))
        if let index = nearestKeyIndex(to: time, within: Self.carveWindow) {
            selectedKeyIndex = index
            return index
        }
        let frame = ReframeEngine.interp(t: time, keys: keys)
        let key = PunchKeyframe(
            t: time, z: frame.z, cx: frame.cx, cy: frame.cy, v: frame.v, bl: frame.bl)
        keys.append(key)
        commitKeys(keeping: key.id)
        if withToast {
            showToast("Keyframe added at \(ReframeEngine.timecode(time))")
        }
        return selectedKeyIndex
    }

    /// The "+ Keyframe at 2:14" affordance.
    func addKeyframe() {
        if let index = nearestKeyIndex(to: currentTime, within: Self.carveWindow) {
            selectKeyframe(index)
            showToast("Already on keyframe \(index + 1)")
            return
        }
        ensureKey(at: currentTime)
    }

    func removeSelected() {
        guard canRemove, keys.indices.contains(selectedKeyIndex) else { return }
        let removed = keys.remove(at: selectedKeyIndex)
        selectedKeyIndex = min(selectedKeyIndex, keys.count - 1)
        commitKeys()
        currentTime = keys.indices.contains(selectedKeyIndex) ? keys[selectedKeyIndex].t : currentTime
        showToast("Removed the keyframe at \(ReframeEngine.timecode(removed.t))")
    }

    /// Sort, clamp, re-derive auto-blend — and keep the selection pointing at
    /// the key it was on, not the slot it used to occupy.
    func commitKeys(keeping id: UUID? = nil) {
        let anchor = id ?? (keys.indices.contains(selectedKeyIndex) ? keys[selectedKeyIndex].id : nil)
        let duration = max(0, sourceDuration)
        // The playhead is clamped here too: a source that turns out shorter
        // than the caller said would otherwise leave it parked past the end,
        // where every readout reports a time the clip doesn't have.
        currentTime = min(max(currentTime, 0), duration)

        for index in keys.indices {
            keys[index].t = min(max(keys[index].t, 0), duration)
            keys[index].z = min(max(keys[index].z, ReframeEngine.minZoom), ReframeEngine.maxZoom)
            keys[index].v = min(max(keys[index].v, ReframeEngine.minSpeed), ReframeEngine.maxSpeed)
            keys[index].bl = min(max(keys[index].bl, 0), 1)
            let centre = ReframeEngine.clampCenter(
                z: keys[index].z, cx: keys[index].cx, cy: keys[index].cy,
                ratio: ratio, sourceSize: sourceSize)
            keys[index].cx = centre.cx
            keys[index].cy = centre.cy
            if blendMode == .auto, !keys[index].ovr {
                keys[index].bl = ReframeEngine.autoBlend(speed: keys[index].v)
            }
        }
        keys.sort { $0.t < $1.t }

        if let anchor, let index = keys.firstIndex(where: { $0.id == anchor }) {
            selectedKeyIndex = index
        } else {
            selectedKeyIndex = min(max(selectedKeyIndex, 0), max(0, keys.count - 1))
        }
    }

    // MARK: - Speed / blend / ratio

    /// Speed rides the selected keyframe; auto-blend follows it there unless
    /// that key has been pinned.
    func setSpeed(_ speed: Double) {
        guard keys.indices.contains(selectedKeyIndex) else { return }
        keys[selectedKeyIndex].v = min(max(speed, ReframeEngine.minSpeed), ReframeEngine.maxSpeed)
        commitKeys()
    }

    /// A hand-set blend depth for the selected key. Pins it, so a later speed
    /// change leaves it where you put it.
    func setBlend(_ depth: Double) {
        guard keys.indices.contains(selectedKeyIndex) else { return }
        keys[selectedKeyIndex].bl = min(max(depth, 0), 1)
        keys[selectedKeyIndex].ovr = true
        commitKeys()
    }

    /// Hand the selected key back to auto-blend.
    func followSpeedBlend() {
        guard keys.indices.contains(selectedKeyIndex) else { return }
        blendMode = .auto
        keys[selectedKeyIndex].ovr = false
        commitKeys()
    }

    /// Start overriding the selected key's depth without changing it — the
    /// slider opens where auto had it.
    func beginBlendOverride() {
        guard keys.indices.contains(selectedKeyIndex) else { return }
        blendMode = .auto
        keys[selectedKeyIndex].ovr = true
        commitKeys()
    }

    func setBlendMode(_ mode: BlendMode) {
        blendMode = mode
        if mode == .manual, keys.indices.contains(selectedKeyIndex) {
            keys[selectedKeyIndex].ovr = true
            keys[selectedKeyIndex].bl =
                ReframeEngine.nearestManualDepth(keys[selectedKeyIndex].bl)
        }
        commitKeys()
    }

    /// A new output shape re-clamps every centre — a crop that was flush with
    /// the right edge at 16:9 has to move to stay inside 9:16.
    func setRatio(_ ratio: ReframeRatio) {
        guard ratio != self.ratio else { return }
        self.ratio = ratio
        commitKeys()
        showToast("Reframing to \(ratio.label)")
    }

    // MARK: - Gestures

    /// Pan the crop. `canvasSize` is the on-screen size of the *crop window*,
    /// which is the whole canvas in the inline player and the drawn box in the
    /// expanded view — so one conversion serves both.
    ///
    /// `movesCrop` picks which of the two is under the finger: the inline
    /// player drags the picture (the crop goes the other way), the expanded
    /// view drags the box itself.
    func handleDrag(translation: CGSize, canvasSize: CGSize, movesCrop: Bool = false) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let index = gestureKeyIndex()
        guard keys.indices.contains(index) else { return }

        let base = dragBaseCentre ?? (keys[index].cx, keys[index].cy)
        dragBaseCentre = base

        let crop = ReframeEngine.cropRect(
            z: keys[index].z, cx: base.cx, cy: base.cy, ratio: ratio, sourceSize: sourceSize)
        guard crop.width > 0 else { return }
        let scale = Double(crop.width) / Double(canvasSize.width)
        let sign: Double = movesCrop ? 1 : -1

        let centre = ReframeEngine.clampCenter(
            z: keys[index].z,
            cx: base.cx + sign * Double(translation.width) * scale,
            cy: base.cy + sign * Double(translation.height) * scale,
            ratio: ratio,
            sourceSize: sourceSize)
        keys[index].cx = centre.cx
        keys[index].cy = centre.cy
    }

    /// Pinch the punch factor for the key under the playhead.
    func handlePinch(scale: Double) {
        guard scale.isFinite, scale > 0 else { return }
        let index = gestureKeyIndex()
        guard keys.indices.contains(index) else { return }

        let base = pinchBaseZoom ?? keys[index].z
        pinchBaseZoom = base

        let zoom = min(max(base * scale, ReframeEngine.minZoom), ReframeEngine.maxZoom)
        keys[index].z = zoom
        let centre = ReframeEngine.clampCenter(
            z: zoom, cx: keys[index].cx, cy: keys[index].cy,
            ratio: ratio, sourceSize: sourceSize)
        keys[index].cx = centre.cx
        keys[index].cy = centre.cy
    }

    /// Both gestures end here. Anything a cancelled gesture leaves behind is
    /// cleared too, so the next touch starts from the values on screen.
    func endGesture() {
        gestureKeyID = nil
        pinchBaseZoom = nil
        dragBaseCentre = nil
        commitKeys()
    }

    /// The key a live gesture owns. Resolved once per touch: two keys can sit
    /// inside the carve window, and a gesture must not wander between them.
    private func gestureKeyIndex() -> Int {
        if let gestureKeyID, let index = keys.firstIndex(where: { $0.id == gestureKeyID }) {
            selectedKeyIndex = index
            return index
        }
        let index = ensureKey(at: currentTime)
        gestureKeyID = keys.indices.contains(index) ? keys[index].id : nil
        return index
    }

    // MARK: - Playback

    func togglePlay() {
        guard sourceDuration > 0 else { return }
        isPlaying.toggle()
    }

    /// Advance by `delta` seconds of *output* time — the playhead crosses the
    /// source at the warp's own speed, so the preview runs at the rate the
    /// finished clip will.
    func advancePlayback(by delta: Double) {
        guard isPlaying, sourceDuration > 0, delta > 0 else { return }
        let speed = max(ReframeEngine.minSpeed, currentFrame.v)
        let next = currentTime + delta * speed
        currentTime = next >= sourceDuration ? 0 : next
    }

    func scrub(toFraction fraction: Double) {
        guard sourceDuration > 0 else { return }
        currentTime = min(max(fraction, 0), 1) * sourceDuration
    }

    // MARK: - Toast

    func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) { toast = message }
        toastTask = Task { [weak self] in
            // 4s, the same dwell the Adjust timeline's toast uses.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { self?.toast = nil }
        }
    }

    // MARK: - Copy

    /// "20:00 · 4K · 30 fps · reframe move"
    var sourceSubtitle: String {
        var parts: [String] = []
        if sourceDuration > 0 { parts.append(ReframeEngine.timecode(sourceDuration)) }
        if sourceSize.width > 0, sourceSize.height > 0 {
            parts.append(AppModel.CaptureProject.resolutionLabel(
                width: Int(sourceSize.width), height: Int(sourceSize.height)))
        }
        if let sourceFPS, sourceFPS > 0 { parts.append("\(Int(sourceFPS.rounded())) fps") }
        parts.append("reframe move")
        return parts.joined(separator: " · ")
    }

    /// "Keyframe 3 of 5 · 2:14 · 2.6× punch · 1× · blend off"
    var selectedKeyLine: String {
        guard let key = selectedKey else { return "No keyframe selected" }
        let punch = String(format: "%.1f× punch", key.z)
        return [
            "Keyframe \(selectedKeyIndex + 1) of \(keys.count)",
            ReframeEngine.timecode(key.t),
            punch,
            ReframeEngine.speedLabel(key.v),
            "blend \(ReframeEngine.blendWord(key.bl))",
        ].joined(separator: " · ")
    }

    /// The player's badge: which key you're editing, or that you're between.
    var playerBadge: String {
        if let index = onKeyframeIndex {
            return "K\(index + 1) · editing crop"
        }
        return "≈ preview · between keyframes"
    }
}
