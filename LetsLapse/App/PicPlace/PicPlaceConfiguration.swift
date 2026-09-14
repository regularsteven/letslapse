import Foundation

/// Where the app's PicPlace lives (docs/picplace-sync-v1.md §2).
///
/// The server is a **setting**, `letslapse.picplace.server`, edited from the
/// PICPLACE card in Settings while signed out. The build only chooses the
/// default — the Valet site on this Mac for Debug, production for Release —
/// so moving to picplace.co is a settings change, not a code change. The
/// client id is the server's one public (PKCE) OAuth client; it is not a
/// secret, which is the whole point of a public client.
enum PicPlaceConfiguration {

    static let serverKey = "letslapse.picplace.server"

    /// `config('letslapse.client.id')` on the server.
    static let clientID = "f3bf6a1d-d407-4152-b043-cbdeb797ab5b"

    static let callbackScheme = "letslapse"
    static let schemeRedirectURI = "letslapse://oauth/callback"

    /// Where the server sends the browser after consent. iOS takes the
    /// app's own scheme (the system web session intercepts it). macOS asks
    /// for the server's "Return to LetsLapse" page instead: a desktop
    /// browser cannot be relied on to follow a 302 to a custom scheme
    /// (Chrome 152 shows an error page), but it will open one from a page —
    /// automatically, or from the page's button. Both are registered on the
    /// server's client (`config/letslapse.php` → `redirect_uris`).
    static func redirectURI(for server: URL) -> String {
        #if os(macOS)
        return server.appendingPathComponent("oauth/letslapse/return").absoluteString
        #else
        return schemeRedirectURI
        #endif
    }

    static let scopes = ["projects:read", "projects:write", "assets:read", "assets:write"]

    static let keychainService = "com.regularsteven.letslapse.picplace"

    /// Debug on a Mac or in the iOS Simulator talks to the Valet site on
    /// this Mac; everything else — Release, and any build on a physical
    /// iPhone or iPad — talks to production. Physical devices never test
    /// against `.test` (v2 plan D3): they resolve neither the domain nor
    /// the certificate.
    static var defaultServer: String {
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
        "https://picplace.test"
        #else
        "https://picplace.co"
        #endif
    }

    /// Whether the Settings card shows the Server row at all: the Mac
    /// configures its server (and its library location); iOS and iPadOS
    /// have neither, bar a Debug build on the Simulator, which needs it to
    /// reach the local server (v2 plan D3).
    static var showsServerSetting: Bool {
        #if os(macOS)
        return true
        #elseif DEBUG && targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// The host of a normalised server string — the folder name on the Mac
    /// and half of an account key.
    static func host(of serverString: String) -> String {
        URL(string: serverString)?.host?.lowercased() ?? serverString.lowercased()
    }

    /// The server as a string, for the Settings row.
    static var serverString: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["LL_PICPLACE_SERVER"], normalize(override) != nil {
            return normalize(override)!
        }
        #endif
        if let stored = UserDefaults.standard.string(forKey: serverKey), normalize(stored) != nil {
            return normalize(stored)!
        }
        return defaultServer
    }

    static var server: URL { URL(string: serverString)! }

    static var apiBase: URL { server.appendingPathComponent("api/letslapse/v1", isDirectory: false) }

    /// Store a new server. Returns false (and stores nothing) for anything
    /// that is not an https URL with a host. Clearing to the default is
    /// allowed by passing an empty string.
    @discardableResult
    static func setServer(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: serverKey)
            return true
        }
        guard let normalized = normalize(trimmed) else { return false }
        UserDefaults.standard.set(normalized, forKey: serverKey)
        return true
    }

    /// "picplace.co" → "https://picplace.co"; trailing slashes and paths dropped.
    static func normalize(_ string: String) -> String? {
        var candidate = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate), let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        var result = "\(scheme)://\(host.lowercased())"
        if let port = url.port { result += ":\(port)" }
        return result
    }

    /// What the Settings rows and the card subtitle show: the host alone.
    /// The SETTING's host — a bound library's is `PicPlaceController.sessionHost`.
    static var serverHost: String { server.host ?? serverString }
}
