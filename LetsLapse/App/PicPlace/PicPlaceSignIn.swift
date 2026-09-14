import AuthenticationServices
import CryptoKit
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// "Sign in with PicPlace": the OAuth authorization-code flow with PKCE. The
/// login and consent pages are the server's own; the app only opens the URL
/// and receives the code on the `letslapse://oauth/callback` redirect (the
/// scheme is registered in `App/Info.plist`).
///
/// iOS runs the page in `ASWebAuthenticationSession`, which intercepts the
/// callback itself. macOS opens the page in the DEFAULT BROWSER, has the
/// server redirect to its https "Return to LetsLapse" page rather than to the
/// scheme (Chrome 152 drops a 302 to a custom scheme with "This site can't be
/// reached", whether it hosts the auth session or not — 2026-09-14, Steven's
/// Mac — but opens the scheme from a page), and takes the callback through
/// Launch Services (`application(_:open:)` / `onOpenURL` → `handleCallback`).
/// The browser may ask "Open LetsLapse?" once; the tab it leaves behind says
/// it can be closed.
@MainActor
final class PicPlaceSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {

    struct Cancelled: Error {}
    struct Failed: LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    /// DEBUG: `LL_PICPLACE_SIGNIN=silent` starts the flow without opening a
    /// browser, so a test can complete it by delivering the callback URL.
    var opensBrowser = true

    private var session: ASWebAuthenticationSession?
    private var pending: CheckedContinuation<URL, Error>?

    var isWaiting: Bool { pending != nil || session != nil }

    /// Runs the whole flow and returns the tokens.
    func run(server: URL) async throws -> PicPlaceTokens {
        let verifier = Self.randomString(64)
        let challenge = Self.challenge(for: verifier)
        let state = Self.randomString(24)

        let redirectURI = PicPlaceConfiguration.redirectURI(for: server)
        var components = URLComponents(url: server.appendingPathComponent("oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: PicPlaceConfiguration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: PicPlaceConfiguration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        let authorizeURL = components.url!
        LLog("picplace: sign-in opens \(authorizeURL.absoluteString)")

        let callback: URL
        #if os(macOS)
        callback = try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            if opensBrowser, !NSWorkspace.shared.open(authorizeURL) {
                pending = nil
                continuation.resume(throwing: Failed(reason: "The browser could not be opened."))
            }
        }
        #else
        callback = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authorizeURL, callbackURLScheme: PicPlaceConfiguration.callbackScheme) { url, error in
                Task { @MainActor in
                    self.session = nil
                    if let url {
                        continuation.resume(returning: url)
                    } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        continuation.resume(throwing: Cancelled())
                    } else {
                        continuation.resume(throwing: Failed(reason: error?.localizedDescription ?? "The sign-in window closed."))
                    }
                }
            }
            session.presentationContextProvider = self
            // Share the browser's cookies so a picplace.co login is remembered between sign-ins.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: Failed(reason: "The sign-in window could not be opened."))
            }
        }
        #endif

        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        if let error = value("error") {
            if error == "access_denied" { throw Cancelled() }
            throw Failed(reason: value("error_description") ?? "PicPlace refused the sign-in (\(error)).")
        }
        guard value("state") == state else { throw Failed(reason: "The sign-in reply did not match the request.") }
        guard let code = value("code"), !code.isEmpty else { throw Failed(reason: "PicPlace sent no authorization code.") }

        return try await PicPlaceClient.exchange(code: code, verifier: verifier, server: server, redirectURI: redirectURI)
    }

    /// A `letslapse://oauth/callback…` URL the system delivered to the app.
    /// Returns false when it is not ours or nothing is waiting for it.
    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == PicPlaceConfiguration.callbackScheme, let pending else { return false }
        self.pending = nil
        pending.resume(returning: url)
        return true
    }

    /// Give up on a flow the browser never finished.
    func cancel() {
        session?.cancel()
        session = nil
        pending?.resume(throwing: Cancelled())
        pending = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first { $0.isVisible } ?? ASPresentationAnchor()
            #else
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            return windows.first { $0.isKeyWindow } ?? windows.first ?? ASPresentationAnchor()
            #endif
        }
    }

    // MARK: PKCE

    /// RFC 7636: `code_verifier` is 43–128 characters of [A-Za-z0-9-._~].
    static func randomString(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    /// `base64url(sha256(verifier))`, no padding.
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
