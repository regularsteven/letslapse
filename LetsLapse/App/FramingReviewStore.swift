import Foundation
import LetsLapseKit

/// The framing reviews the app has read or made this session, keyed by
/// project, plus the one measurement that may be running. One store for
/// every screen that shows the state — the project detail's Originals rows,
/// the review sheet/window — so a review finished in one place is the
/// review the other shows.
///
/// The file on disk (`source/framing.json`) is the truth; this is a cache
/// in front of it. Reads and writes happen off the main actor.
@MainActor
final class FramingReviewStore: ObservableObject {
    static let shared = FramingReviewStore()

    struct Run: Equatable {
        var progress: Double = 0
        var startedAt = Date()
        var total: Int

        /// Seconds left at the run's own pace; nil until the pace is known.
        var secondsLeft: Double? {
            guard progress > 0.02 else { return nil }
            let elapsed = Date().timeIntervalSince(startedAt)
            return elapsed / progress * (1 - progress)
        }
    }

    @Published private(set) var reviews: [UUID: FramingReview] = [:]
    /// Projects whose sidecar has been read at least once — an absent entry
    /// in `reviews` then means "not reviewed", not "not loaded yet".
    @Published private(set) var loadedIDs: Set<UUID> = []
    @Published private(set) var runs: [UUID: Run] = [:]
    @Published private(set) var failures: [UUID: String] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var cancelFlags: [UUID: CancelFlag] = [:]

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    /// Reports whole percents only: the measurement calls back from its
    /// worker threads for every photo, and a main-actor hop per photo would
    /// be five thousand hops on a long shoot.
    private final class ProgressGate: @unchecked Sendable {
        private let lock = NSLock()
        private var lastPercent = -1
        func admit(_ fraction: Double) -> Bool {
            let percent = Int(fraction * 100)
            lock.lock(); defer { lock.unlock() }
            guard percent != lastPercent else { return false }
            lastPercent = percent
            return true
        }
    }

    // MARK: - Reading

    func review(for id: UUID) -> FramingReview? { reviews[id] }
    func isLoaded(_ id: UUID) -> Bool { loadedIDs.contains(id) }
    func isMeasuring(_ id: UUID) -> Bool { runs[id] != nil }
    func run(for id: UUID) -> Run? { runs[id] }
    func failure(for id: UUID) -> String? { failures[id] }

    /// Reads the sidecar beside `sourceFolder` once; later calls are free.
    func load(id: UUID, sourceFolder: URL) {
        guard !loadedIDs.contains(id), tasks[id] == nil else { return }
        let task = Task { [weak self] in
            let review = await Task.detached(priority: .utility) {
                FramingReview.load(inSourceFolder: sourceFolder)
            }.value
            guard let self else { return }
            if let review { self.reviews[id] = review }
            self.loadedIDs.insert(id)
            self.tasks[id] = nil
        }
        tasks[id] = task
    }

    // MARK: - Measuring

    /// Runs the framing review over `urls` (capture order) and writes it
    /// beside them. An earlier review stays until the new one lands, so a
    /// cancelled run changes nothing.
    func startReview(id: UUID, urls: [URL], sourceFolder: URL) {
        guard runs[id] == nil, urls.count >= 2 else { return }
        tasks[id]?.cancel()
        failures[id] = nil
        runs[id] = Run(total: urls.count)
        let flag = CancelFlag()
        cancelFlags[id] = flag
        let gate = ProgressGate()
        let task = Task { [weak self] in
            let outcome: Result<FramingReview, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    guard let size = FramingMeasurement.fullSize(of: urls[0]) else {
                        throw LapseError.imageLoadFailed(urls[0])
                    }
                    let decoder = FramingLumaDecoder(scale: 0.5)
                    let offsets = try FramingMeasurement.measure(
                        urls: urls, scale: 0.5, luma: { try decoder.luma(at: $0) },
                        workers: FramingMeasurement.defaultWorkers,
                        progress: { fraction in
                            guard gate.admit(fraction) else { return }
                            Task { @MainActor in
                                FramingReviewStore.shared.runs[id]?.progress = fraction
                            }
                        },
                        isCancelled: { flag.isCancelled })
                    let span: Double? = {
                        guard let stamps = try? FrameTimestamps.load(
                                from: sourceFolder.appendingPathComponent(FrameTimestamps.fileName)),
                              let first = stamps.entries.first?.captureTime,
                              let last = stamps.entries.last?.captureTime else { return nil }
                        return last.timeIntervalSince(first)
                    }()
                    let review = FramingReview.make(
                        width: size.width, height: size.height, measurementScale: 0.5,
                        offsets: offsets, captureSpanSeconds: span)
                    try review.write(inSourceFolder: sourceFolder)
                    return .success(review)
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            self.runs[id] = nil
            self.cancelFlags[id] = nil
            self.tasks[id] = nil
            switch outcome {
            case .success(let review):
                self.reviews[id] = review
                self.loadedIDs.insert(id)
            case .failure(let error):
                if !(error is CancellationError) {
                    self.failures[id] = error.localizedDescription
                }
            }
        }
        tasks[id] = task
    }

    func cancel(id: UUID) {
        cancelFlags[id]?.cancel()
    }

    // MARK: - Committing

    /// Commits the review's plan as metadata: `stabilisation` in the sidecar.
    /// Nothing on disk but that file changes.
    func stabilise(id: UUID, sourceFolder: URL) {
        guard let review = reviews[id] else { return }
        write(review.applyingPlan(), id: id, sourceFolder: sourceFolder)
    }

    func withdraw(id: UUID, sourceFolder: URL) {
        guard let review = reviews[id] else { return }
        write(review.withdrawingStabilisation(), id: id, sourceFolder: sourceFolder)
    }

    private func write(_ review: FramingReview, id: UUID, sourceFolder: URL) {
        reviews[id] = review
        Task.detached(priority: .utility) {
            do {
                try review.write(inSourceFolder: sourceFolder)
            } catch {
                await MainActor.run {
                    FramingReviewStore.shared.failures[id] = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Copy

    /// The Originals row's one-line verdict.
    static func rowSummary(_ review: FramingReview) -> String {
        let when = reviewedWhen(review.reviewedAt)
        switch review.verdict {
        case .recommended:
            let peak = review.events.map(\.peakPixels).max() ?? 0
            let knocks = review.events.count
            return "\(knocks) knock\(knocks == 1 ? "" : "s") · largest \(String(format: "%.1f", peak)) px · locking crops \(percent(review.plan.cropFraction)) · \(when)"
        case .steady:
            let held = max(review.plan.insetX, review.plan.insetY) * 2
            return "Framing held within \(String(format: "%.1f", held)) px · \(when)"
        case .inconclusive:
            return "Could not judge the framing · \(when)"
        }
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    static func reviewedWhen(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "today"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "yesterday"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func reviewedAt(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "today at \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday at \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
