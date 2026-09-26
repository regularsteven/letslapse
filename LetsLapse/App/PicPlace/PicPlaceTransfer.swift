import Foundation
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

// Two things a file transfer needs that the API client already has for its
// JSON calls (docs/picplace-sync-v2-handover.md §7), found on the first
// connection to picplace.co on 2026-09-18: 670 projects went up, and the
// one that did not lost its poster's PUT to "The network connection was
// lost" — an app switch mid-upload, on a standard session that retried
// nothing. That single loss held the whole library in "first connection
// pending", which hid the auto-sync switches, the check and its retries.

/// A second, third and fourth go for a presigned PUT or GET.
enum PicPlaceTransfer {
    static let attempts = 4

    /// Runs `body` up to `attempts` times. A dropped connection, a timeout,
    /// a host that cannot be reached, storage answering `429` or `5xx`:
    /// wait 2 s × attempt and go again. A cancel, a `4xx` and anything
    /// else throw at once. Every transfer here is idempotent — the same
    /// bytes to the same key, the same object read — so a retry can only
    /// finish what the first attempt started.
    static func withRetries<T>(_ label: String, _ body: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                #if DEBUG
                if outageActive { throw URLError(.networkConnectionLost) }
                #endif
                return try await body()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < attempts, isTransient(error) else { throw error }
                LLog("picplace: \(label) — \(describe(error)); trying again")
                try await Task.sleep(nanoseconds: UInt64(2 * attempt) * 1_000_000_000)
            }
        }
    }

    /// Storage answered with a status the transfer cannot use; the body
    /// throws it so the loop can tell a `503` from a `403`.
    struct Refused: Error {
        var status: Int
        var detail: String
    }

    static func isTransient(_ error: Error) -> Bool {
        if let refused = error as? Refused {
            return refused.status == 429 || (500 ..< 600).contains(refused.status)
        }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled, .badURL, .unsupportedURL, .fileDoesNotExist, .fileIsDirectory, .noPermissionsToReadFile:
                return false
            default:
                return true
            }
        }
        return false
    }

    static func describe(_ error: Error) -> String {
        if let refused = error as? Refused { return "storage answered \(refused.status)" }
        return error.localizedDescription
    }

    #if DEBUG
    /// `LL_PICPLACE_TRANSFER_OUTAGE=<start>:<seconds>` — every PUT and GET
    /// fails as a lost connection for that window after launch, while the
    /// API calls keep answering: the bench's way to watch a transfer retry
    /// in place (the API client's own window is `LL_PICPLACE_OUTAGE`).
    private static let outage: (from: Date, until: Date)? = {
        guard let raw = ProcessInfo.processInfo.environment["LL_PICPLACE_TRANSFER_OUTAGE"] else { return nil }
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return (Date().addingTimeInterval(parts[0]), Date().addingTimeInterval(parts[0] + parts[1]))
    }()

    private static var outageActive: Bool {
        guard let outage else { return false }
        return outage.from <= Date() && Date() < outage.until
    }

    /// Anchors the window at launch: a static is made on first use, and the
    /// first transfer is not the launch. The controller calls this as it
    /// makes the client.
    static func armHooks() { _ = outage }

    /// `LL_PICPLACE_BAD_DIGEST=<name>[,<name>…]` — the first PUT of each
    /// named file (a path within the project, `source/f005.jpg`) is taken as
    /// storage's `400` for a body that does not hash to the declared SHA-256:
    /// what storage answers once PicPlace signs the hash (free-up server
    /// asks, Ask 1), on a bench whose server does not sign it yet. The
    /// re-hash-once path runs from there.
    static func forcesBadDigest(_ name: String, rehashed: Bool) -> Bool {
        guard !rehashed, let raw = ProcessInfo.processInfo.environment["LL_PICPLACE_BAD_DIGEST"] else { return false }
        return raw.split(separator: ",").contains { String($0) == name }
    }
    #endif
}

/// A little life after the app leaves the screen. iOS suspends an app a few
/// seconds after it is backgrounded and a standard session's sockets die
/// with it; a background task assertion buys about thirty seconds — enough
/// for a look at another app, which is what lost the poster. On the Mac the
/// same object keeps App Nap off while a transfer runs.
///
/// A transfer a person started — a download, an upload job — asks for more
/// (iOS 26+, 2026-09-25; docs/picplace-background-uploads-plan.md Stage 1,
/// and its downloads twin, connected-asset-states plan §15): a *continued
/// processing* task, which keeps LetsLapse running after it leaves the
/// screen or the phone locks, for as long as iOS allows, with the transfer's
/// title and progress on the Lock Screen. While one holds the app, the
/// thirty seconds running out stops nothing; its own expiry is `onExpire`.
/// The durable answer — a background `URLSession` doing the PUTs and GETs
/// itself — is Stage 2 of that plan.
@MainActor
final class PicPlaceBackgroundActivity {
    let name: String
    #if os(iOS)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    /// The continued task's handle (`PicPlaceContinuedTransfer`, iOS 26+).
    private var continued: AnyObject?
    #else
    private var activity: NSObjectProtocol?
    #endif

    /// What the Lock Screen says while a continued task holds the app.
    struct Continued {
        var title: String
        var subtitle: String
    }

    /// `onExpire` runs when iOS is about to suspend the app — an upload
    /// stops between files there, keeping what reached PicPlace. With
    /// `continued`, only the continued task's own expiry runs it.
    init(_ name: String, continued: Continued? = nil, onExpire: (@MainActor () -> Void)? = nil) {
        self.name = name
        #if os(iOS)
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                if let self, self.isContinuing {
                    // The continued task holds the app now: the thirty
                    // seconds ending stops nothing.
                    LLog("picplace: \(name) — carried on by the continued task")
                    self.endBackgroundTask()
                    return
                }
                LLog("picplace: background time for \(name) ran out — iOS suspends what is left; the retry finishes it in front")
                onExpire?()
                self?.end()
            }
        }
        if #available(iOS 26.0, *), let continued {
            self.continued = PicPlaceContinuedTransfer.begin(
                title: continued.title, subtitle: continued.subtitle, onExpire: onExpire)
        }
        #else
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: name)
        #endif
    }

    #if os(iOS)
    var isContinuing: Bool {
        if #available(iOS 26.0, *) {
            return (continued as? PicPlaceContinuedTransfer)?.isRunning == true
        }
        return false
    }

    private func endBackgroundTask() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
    #endif

    /// The transfer moved: the Lock Screen's progress follows.
    func report(_ progress: PicPlaceSyncProgress) {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            (continued as? PicPlaceContinuedTransfer)?.update(progress)
        }
        #endif
    }

    func end(success: Bool = true) {
        #if os(iOS)
        endBackgroundTask()
        if #available(iOS 26.0, *) {
            (continued as? PicPlaceContinuedTransfer)?.finish(success: success)
        }
        continued = nil
        #else
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        #endif
    }
}

#if DEBUG && os(iOS)
extension PicPlaceBackgroundActivity {
    /// `LL_CONTINUED_PROBE=<seconds>`: the transfers' own activity with a
    /// continued task and nothing behind it — progress ticks once a second,
    /// then it ends. Proves the register → submit → launch path on a device
    /// without sending a byte (2026-09-25).
    @available(iOS 26.0, *)
    static func runProbe(seconds: Int) async {
        LLog("probe: continued task — starting, \(seconds) s")
        let activity = PicPlaceBackgroundActivity(
            "continued-task probe",
            continued: .init(title: "LetsLapse test task", subtitle: "Nothing is sent")
        ) {
            LLog("probe: continued task expired")
        }
        for tick in 0...max(1, seconds) {
            var progress = PicPlaceSyncProgress()
            progress.filesTotal = max(1, seconds)
            progress.filesDone = tick
            progress.bytesTotal = Int64(max(1, seconds))
            progress.bytesDone = Int64(tick)
            activity.report(progress)
            LLog("probe: tick \(tick) — \(activity.isContinuing ? "the continued task holds the app" : "no continued task")")
            try? await Task.sleep(for: .seconds(1))
        }
        activity.end()
        LLog("probe: continued task — done")
    }
}
#endif

#if os(iOS)
/// One continued-processing task for a transfer a person started (iOS 26+).
/// iOS launches it at once, or never when the system cannot; progress must
/// keep moving or iOS ends a task it thinks has stalled, so the transfers
/// report bytes as they go.
///
/// Apple's rules, learned by a crash (2026-09-25 — the iPad aborted at every
/// launch): each request registers a handler for **its own identifier** just
/// before it is submitted. The wildcard in `BGTaskSchedulerPermittedIdentifiers`
/// only permits identifiers made at run time; one handler registered for the
/// wildcard is refused by design (Apple DTS, developer forums thread 799126),
/// and a request submitted with no handler is not an error `submit` returns —
/// BackgroundTasks asserts and the app aborts. So: no registration, no
/// request. And only for a press (Apple: *"in response to someone's
/// action"*) — never a job resumed at launch or a retry.
@available(iOS 26.0, *)
@MainActor
final class PicPlaceContinuedTransfer {
    static let prefix = "com.regularsteven.letslapse.transfer"
    private static var handles: [String: PicPlaceContinuedTransfer] = [:]

    let identifier: String
    private var title: String
    private var task: BGContinuedProcessingTask?
    private var onExpire: (@MainActor () -> Void)?
    private var lastFiles = -1
    private var done = false

    /// True while iOS runs the task — the app is held by it.
    var isRunning: Bool { task != nil && !done }

    private init(identifier: String, title: String, onExpire: (@MainActor () -> Void)?) {
        self.identifier = identifier
        self.title = title
        self.onExpire = onExpire
    }

    /// Registers this transfer's handler, then submits its request; nil
    /// when iOS will not run one (the thirty seconds still stand).
    static func begin(title: String, subtitle: String, onExpire: (@MainActor () -> Void)?) -> PicPlaceContinuedTransfer? {
        // A fresh identifier every time: registering one twice aborts too.
        let identifier = "\(prefix).\(UUID().uuidString.lowercased())"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { launched(task) }
        }
        guard registered else {
            LLog("picplace: continued task unavailable for \(title) — iOS refused its handler; the transfer keeps the thirty seconds")
            return nil
        }
        let handle = PicPlaceContinuedTransfer(identifier: identifier, title: title, onExpire: onExpire)
        handles[identifier] = handle
        // Fail rather than queue: a transfer that cannot be held now runs
        // in front as it always did, and a queued one would start later on
        // its own, after the person has moved on.
        if #available(iOS 27.0, *) {
            // iOS 27's form reports every refusal (the old one could not),
            // and is not for the main thread.
            Task.detached(priority: .userInitiated) {
                let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
                request.strategy = .fail
                do {
                    try await BGTaskScheduler.shared.submitTaskRequest(request)
                } catch {
                    await handle.refused(error)
                }
            }
        } else {
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            request.strategy = .fail
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                handle.refused(error)
                return nil
            }
        }
        LLog("picplace: continued task asked for — \(title)")
        return handle
    }

    private func refused(_ error: Error) {
        guard !done else { return }
        LLog("picplace: continued task refused for \(title): \(error.localizedDescription)")
        done = true
        Self.handles[identifier] = nil
    }

    private static func launched(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask,
              let handle = handles[task.identifier], !handle.done else {
            task.setTaskCompleted(success: false)
            return
        }
        handle.attach(task)
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        self.task = task
        task.progress.totalUnitCount = 100
        task.expirationHandler = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.done else { return }
                LLog("picplace: continued task for \(self.title) expired — the transfer stops between files and carries on in front")
                self.onExpire?()
                self.finish(success: false)
            }
        }
        LLog("picplace: continued task running — \(title)")
    }

    func update(_ progress: PicPlaceSyncProgress) {
        guard let task, !done else { return }
        if progress.bytesTotal > 0 {
            task.progress.totalUnitCount = progress.bytesTotal
            task.progress.completedUnitCount = min(progress.bytesDone, progress.bytesTotal)
        }
        if progress.filesTotal > 0, progress.filesDone != lastFiles {
            lastFiles = progress.filesDone
            task.updateTitle(title, subtitle: "\(progress.filesDone.formatted()) of \(progress.filesTotal.formatted()) files")
        }
    }

    func finish(success: Bool) {
        guard !done else { return }
        done = true
        Self.handles[identifier] = nil
        if let task {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        task = nil
    }
}
#endif
