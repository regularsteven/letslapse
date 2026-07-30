import Foundation
import os

/// Bounded, cancellable execution for the media I/O the browsing screens do:
/// thumbnail and RAW decodes, and project-folder size walks.
///
/// All of it used to go straight to `Task.detached`, which falls apart on a
/// large library (170+ projects, 1000+ DNGs) in three compounding ways:
///
/// 1. **It starves Swift concurrency.** Detached tasks run on the cooperative
///    pool, whose width is the core count. Blocking ImageIO and FileManager
///    calls hold those threads for their whole duration, so one screenful of
///    tiles plus their size walks can occupy every thread the runtime has —
///    and every other `await` in the app, including the ones refilling those
///    same tiles, then queues behind them.
/// 2. **None of it was cancellable.** `Task.detached` ignores the cancellation
///    of the SwiftUI `.task` that started it, so scrolling a long list piles up
///    hundreds of decodes and directory walks for rows that left the screen
///    long ago. Fresh requests land behind that backlog and effectively never
///    arrive: that is what "every thumbnail died at once and the file sizes all
///    went back to `…`, and only relaunching fixed it" was. Not a deadlock — a
///    queue minutes deep, with the main actor free the whole time, which is why
///    the UI stayed responsive throughout.
/// 3. **Concurrency was unbounded.** One of this app's DNGs decodes to ~50 MB;
///    six of them at once is a memory-warning spike, and a memory warning is
///    exactly when the caches empty and the whole grid asks for its images
///    again — at the worst possible moment.
///
/// So: an `OperationQueue`, off the cooperative pool, a few jobs wide, whose
/// jobs are cancelled when the task awaiting them is.
final class MediaWorkQueue {
    /// Shared queue for browsing work — thumbnails, previews, size walks.
    static let shared = MediaWorkQueue()

    private static let log = Logger(subsystem: "com.regularsteven.letslapse", category: "media")

    /// One place to record why a tile or a size stayed empty.
    ///
    /// Goes to os_log (Console.app, or `log stream` against the device) *and*
    /// to stdout, which is the Xcode console and
    /// `devicectl device process launch --console …` — the only channel there is
    /// when the phone is attached over Wi-Fi rather than USB. Tagged 🖼️LL to
    /// filter alongside the camera's 🎥LL lines.
    static func note(_ message: String, isError: Bool = false) {
        if isError {
            log.error("\(message, privacy: .public)")
        } else {
            log.notice("\(message, privacy: .public)")
        }
        print("🖼️LL \(message)")
    }

    private let queue = OperationQueue()

    init(width: Int? = nil) {
        // Wide enough to keep a grid filling briskly, narrow enough that
        // several full-sensor RAW decodes can't pile their intermediates up
        // into a memory warning.
        queue.maxConcurrentOperationCount = width
            ?? max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        queue.qualityOfService = .userInitiated
        queue.name = "com.letslapse.media-io"
    }

    /// Jobs queued or running — diagnostics only.
    var depth: Int { queue.operationCount }

    /// Runs `body` on the queue and returns its result, or `nil` if the calling
    /// task was cancelled — in which case the job is dropped whether or not it
    /// had started. Callers must treat `nil` as "no answer yet", never as a
    /// result: overwriting on-screen state with it is how a cancelled scroll
    /// blanks a tile it had already filled.
    func run<T>(_ body: @escaping @Sendable () -> T) async -> T? {
        let job = Job<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                // Already cancelled: `begin` resolves the continuation itself
                // and we never enqueue anything.
                guard job.begin(continuation) else { return }
                let operation = BlockOperation()
                operation.addExecutionBlock { [weak operation] in
                    if operation?.isCancelled ?? true {
                        job.finish(nil)
                    } else {
                        job.finish(body())
                    }
                }
                // Covers cancellation that lands before the block ever runs:
                // a cancelled operation still gets its completion block.
                operation.completionBlock = { job.finish(nil) }
                job.adopt(operation)
                queue.addOperation(operation)
            }
        } onCancel: {
            job.cancel()
        }
    }
}

/// The continuation/operation pair behind one `MediaWorkQueue.run` call.
/// `finish` is idempotent and first-caller-wins, so the execution block, the
/// completion block and cancellation can all race for it safely.
private final class Job<T> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var operation: Operation?
    private var isCancelled = false
    private var isFinished = false

    /// Stores the continuation, returning false when the task was cancelled
    /// before we got here (the continuation is resolved here in that case).
    func begin(_ continuation: CheckedContinuation<T?, Never>) -> Bool {
        lock.lock()
        if isCancelled {
            lock.unlock()
            continuation.resume(returning: nil)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func adopt(_ operation: Operation) {
        lock.lock()
        let cancelled = isCancelled
        self.operation = operation
        lock.unlock()
        // Cancellation that arrived while we were enqueueing.
        if cancelled { operation.cancel() }
    }

    func finish(_ value: T?) {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return
        }
        isFinished = true
        self.continuation = nil
        // Breaks the job ↔ completionBlock cycle without relying on Foundation
        // releasing the block for us.
        self.operation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let operation = self.operation
        lock.unlock()
        operation?.cancel()
        // Hand the caller its `nil` now rather than waiting for a job that may
        // already be halfway through a RAW decode.
        finish(nil)
    }
}
