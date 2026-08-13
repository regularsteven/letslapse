// `canImport` rather than `#if os(watchOS) || os(iOS)`: WatchConnectivity
// simply does not exist on macOS, and this file lives in Shared/, which is
// compiled into all three targets.
#if canImport(WatchConnectivity)
import Foundation
import WatchConnectivity

/// The original watch link, behind `CaptureRemoteTransport`. This is a lift,
/// not a rewrite — the WCSession calls, their ordering, and the exact
/// reachability semantics each callback reports are the ones the Watch remote
/// has always had. The remote's own hard-won behaviour (the send watchdog, the
/// reconciliation polls, the debug-preview freeze) stays in the remote.
///
/// `WCSession.isSupported()` is the platform test, NOT `#if os(iOS)`: iPadOS
/// satisfies `os(iOS)` and returns false here, because Apple Watch pairs with
/// iPhone only.
final class WatchConnectivityTransport: NSObject, CaptureRemoteTransport {
    weak var delegate: CaptureRemoteTransportDelegate?

    private var didActivate = false

    var isActivated: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated
    }

    var isReachable: Bool {
        WCSession.isSupported() && WCSession.default.isReachable
    }

    /// The phone pushes a full snapshot into the application context on every
    /// change, and it survives both apps relaunching.
    var storedState: [String: Any]? {
        guard WCSession.isSupported() else { return nil }
        let context = WCSession.default.receivedApplicationContext
        return context.isEmpty ? nil : context
    }

    /// iPadOS lands here: it satisfies `os(iOS)` and compiles this file, but
    /// `isSupported()` is false because Apple Watch pairs with iPhone only.
    var unavailabilityReason: String? {
        WCSession.isSupported() ? nil : "Unavailable"
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        guard !didActivate else { return }
        didActivate = true
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(
        _ payload: [String: Any],
        reply: @escaping ([String: Any]) -> Void,
        failure: @escaping (CaptureRemoteSendFailure) -> Void
    ) {
        guard WCSession.isSupported() else {
            Task { @MainActor in failure(.notActivated) }
            return
        }
        WCSession.default.sendMessage(
            payload,
            replyHandler: { response in
                Task { @MainActor in reply(response) }
            },
            errorHandler: { error in
                Task { @MainActor in failure(.failed(error.localizedDescription)) }
            }
        )
    }
}

extension WatchConnectivityTransport: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // Read off the session before hopping actors — by the time the main
        // actor runs, these can have moved on.
        let storedContext = session.receivedApplicationContext
        let reachable = session.isReachable
        let message = error.map { $0.localizedDescription }
        Task { @MainActor [weak self] in
            self?.delegate?.transportDidActivate(
                storedState: storedContext.isEmpty ? nil : storedContext,
                isReachable: reachable,
                errorMessage: message)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.delegate?.transportReachabilityDidChange(isReachable: reachable)
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        // Contexts can be delivered from a queue at launch, well after the
        // phone sent them — reachability comes from the session, not from the
        // fact that bytes arrived.
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.delegate?.transportDidReceiveState(applicationContext, isReachable: reachable)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        // A live message just landed — unlike a queued context, this one does
        // prove the counterpart is there right now.
        Task { @MainActor [weak self] in
            self?.delegate?.transportDidReceiveState(message, isReachable: true)
        }
    }
}
#endif
