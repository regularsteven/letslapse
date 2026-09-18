import Foundation
#if os(iOS)
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
    #endif
}

/// A little life after the app leaves the screen. iOS suspends an app a few
/// seconds after it is backgrounded and a standard session's sockets die
/// with it; a background task assertion buys about thirty seconds — enough
/// for a look at another app, which is what lost the poster. A background
/// `URLSession` for the long originals transfers is the durable answer and
/// is owed (libraries plan, later). On the Mac the same object keeps App
/// Nap off while a transfer runs.
@MainActor
final class PicPlaceBackgroundActivity {
    let name: String
    #if os(iOS)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    #else
    private var activity: NSObjectProtocol?
    #endif

    init(_ name: String) {
        self.name = name
        #if os(iOS)
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                LLog("picplace: background time for \(name) ran out — iOS suspends what is left; the retry finishes it in front")
                self?.end()
            }
        }
        #else
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: name)
        #endif
    }

    func end() {
        #if os(iOS)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
        #else
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        #endif
    }
}
