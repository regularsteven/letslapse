import Foundation

/// How a command failed before it produced a reply. These map 1:1 onto the
/// status line the remote shows, which is why "couldn't go out" and "went out
/// and failed" are separate cases rather than one error.
enum CaptureRemoteSendFailure {
    /// The link isn't up yet. Retryable on its own once activation completes.
    case notActivated
    /// The link is up but the counterpart is out of reach (screen off, app
    /// backgrounded, out of range, off the network).
    case unreachable
    /// The command went out and the transport reported a failure.
    case failed(String)
}

/// The pipe between a remote and a capture screen, with the dictionary
/// vocabulary of `WatchMessageKey` as its payload.
///
/// Two things stay deliberately *inside* each conformance rather than in this
/// protocol:
///
/// - **Reply correlation.** WatchConnectivity's `sendMessage` already pairs a
///   reply to its command; a byte-stream transport has to add its own message
///   ids and match them up. Exposing that here would push envelope bookkeeping
///   into the remote, which doesn't care.
/// - **Telling a reply from an unsolicited push.** Same reason: over one
///   inbound channel, a state push that arrived mid-flight must never be
///   mistaken for an accept, and the transport is where that distinction is
///   cheap to make. Pushes surface through `didReceiveState`, replies through
///   the `reply` closure, and never the other way round.
protocol CaptureRemoteTransport: AnyObject {
    /// False until the link is up. Distinct from `isReachable`: an activated
    /// link with an absent counterpart is "unreachable", not "connecting".
    var isActivated: Bool { get }
    var isReachable: Bool { get }

    /// Non-nil when this transport can never work here, as opposed to being
    /// merely disconnected — no WCSession on iPad, local network permission
    /// denied. A remote must show this and stop, rather than sit on
    /// "Connecting" forever waiting for something that will never activate.
    var unavailabilityReason: String? { get }

    /// A cached last-known state snapshot, if the transport keeps one that
    /// survives both ends relaunching (WatchConnectivity's application
    /// context does; a live socket does not). Read once at activation to seed
    /// a cold start mid-shoot, so the remote isn't betting everything on one
    /// live round-trip against a busy counterpart.
    var storedState: [String: Any]? { get }

    /// Set by the remote before `activate()`.
    var delegate: CaptureRemoteTransportDelegate? { get set }

    func activate()

    /// Callers pre-flight with `isActivated`/`isReachable`; `failure` reports
    /// what happened to a command that was actually handed to the transport.
    /// Both closures land on the main actor.
    func send(
        _ payload: [String: Any],
        reply: @escaping ([String: Any]) -> Void,
        failure: @escaping (CaptureRemoteSendFailure) -> Void
    )
}

@MainActor
protocol CaptureRemoteTransportDelegate: AnyObject {
    /// `storedState` is the cached snapshot described above, `errorMessage` a
    /// human-readable activation failure. `isReachable` is read off the link at
    /// callback time rather than polled afterwards — by the time the main actor
    /// runs it can already have moved on.
    func transportDidActivate(
        storedState: [String: Any]?,
        isReachable: Bool,
        errorMessage: String?
    )

    func transportReachabilityDidChange(isReachable: Bool)

    /// An unsolicited state snapshot. `isReachable` travels with it because
    /// arrival doesn't imply presence — a queued snapshot can be delivered at
    /// launch long after the counterpart sent it, so the transport reports
    /// what it actually observed rather than letting the remote infer it.
    func transportDidReceiveState(_ payload: [String: Any], isReachable: Bool)
}
