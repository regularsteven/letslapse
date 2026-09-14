import Foundation

// MARK: - Wire types (docs/letslapse-auth.md, letslapse-api.md in the picplace repo)

struct PPStatus: Decodable {
    struct User: Decodable { var uuid: String; var username: String?; var name: String? }
    struct Storage: Decodable { var quotaBytes: Int64?; var usedBytes: Int64; var downloadUrlTtlSeconds: Int; var uploadUrlTtlSeconds: Int }
    /// The instance block the v2 asks request (server-asks §1): absent until
    /// the server ships it, then the authoritative half of a library binding.
    struct Server: Decodable { var id: String; var environment: String?; var url: String? }
    /// "Has this account synced anything?" without an index pull (asks §7).
    struct Projects: Decodable { var count: Int; var byType: [String: Int]?; var deleted: Int? }
    /// The caps the app checks before sending (asks §4, §12): absent on a
    /// server that predates them, in which case the app assumes 1 MB.
    struct Limits: Decodable { var manifestMaxBytes: Int64?; var objectMaxBytes: Int64?; var assetBatch: Int?; var tombstoneDays: Int? }
    var apiVersion: Int
    var serverTime: Date
    var user: User
    var device: PPDevice?
    var scopes: [String]
    var storage: Storage
    var features: [String: Bool]
    var server: Server?
    var projects: Projects?
    var limits: Limits?
}

struct PPDevice: Decodable, Equatable {
    var id: String
    var deviceKey: String?
    var name: String
    var platform: String?
    var lastSeenAt: Date?
    var revokedAt: Date?
}

struct PPDeviceSummary: Decodable, Equatable {
    var id: String
    var name: String
    var platform: String?
}

struct PPClaim: Decodable {
    var device: PPDeviceSummary?
    var claimedAt: Date?
    var expiresAt: Date?
    var active: Bool
    var mine: Bool
}

struct PPPresence: Decodable {
    var device: PPDeviceSummary?
    var revision: Int?
    var confirmedAt: Date?
}

struct PPProject: Decodable {
    struct Assets: Decodable { var confirmed: Int; var pending: Int; var bytes: Int64 }
    var uuid: String
    var name: String
    var type: String
    var revision: Int
    var capturedAt: Date?
    var manifestBytes: Int64
    var assets: Assets
    var claim: PPClaim?
    var presence: [PPPresence]
    var updatedAt: Date?
    /// v2: the device of the last manifest PUT, and the tombstone.
    var updatedBy: PPDeviceSummary?
    var deletedAt: Date?
    var deletedBy: PPDeviceSummary?
    var originUuid: String?

    var isTombstone: Bool { deletedAt != nil }
}

struct PPAsset: Decodable {
    var id: String
    var kind: String
    var name: String
    /// nil while the asset is pending: the server has nothing to say about
    /// bytes it has not received (the negotiated size is on the upload).
    /// The contract says `0`; a freshly created row comes back `null` —
    /// either way it is not a value the app acts on.
    var bytes: Int64?
    var sha256: String?
    var status: String
}

struct PPUpload: Decodable {
    var id: String
    var method: String
    var url: String
    var headers: [String: String]
    var expiresAt: Date
}

struct PPNegotiation: Decodable {
    var asset: PPAsset
    var upload: PPUpload?
}

/// `GET /projects[?updated_since=]` — the account's index. `server_time` is
/// the watermark the next `updated_since` should send (server-asks §8).
struct PPProjectIndex: Decodable {
    var projects: [PPProject]
    var serverTime: Date?
}

/// `GET /projects/{uuid}` — the registry row beside the manifest and the asset
/// list. The manifest is LetsLapse's own JSON and is read from the raw body
/// (`PicPlaceClient.getData`), never through this type.
struct PPProjectDetail: Decodable {
    var project: PPProject
    var assets: [PPAsset]?
}

/// One item of `POST /projects/{uuid}/assets/urls` (and `GET /assets/{id}/url`):
/// a presigned GET, or a per-item error.
struct PPDownloadURL: Decodable {
    var id: String?
    var url: String?
    var method: String?
    var expiresAt: Date?
    var error: String?
    var message: String?
}

struct PPConfirmResult: Decodable {
    var id: String
    var asset: PPAsset?
    var error: String?
    var message: String?
}

/// What the server says when it refuses: `{error, message, claim?}` for the
/// registry's 409s, `{message}` for auth, `{message, errors}` for validation.
struct PicPlaceAPIError: LocalizedError {
    var status: Int
    var code: String?
    var message: String
    var claim: PPClaim?

    var errorDescription: String? { message }

    /// The failure line the status card shows.
    var cardCaption: String {
        if let claim, let device = claim.device, code == "claim_held" || code == "claim_expired" || code == "claim_required" {
            if let until = claim.expiresAt {
                return "\(device.name) holds the write claim until \(until.formatted(date: .omitted, time: .shortened))"
            }
            return "\(device.name) holds the write claim"
        }
        switch code {
        case "account_not_enabled": return "This PicPlace account isn't enabled for LetsLapse yet"
        case "device_revoked": return "This device was signed out of PicPlace"
        default:
            if status == 404 { return "PicPlace doesn't have this project" }
            if status >= 500 { return "PicPlace had a problem (\(status)); try again later" }
            return message
        }
    }
}

struct PicPlaceOfflineError: LocalizedError {
    var underlying: Error?
    var errorDescription: String? { "PicPlace couldn't be reached" }
    var debugDescription: String { "PicPlace couldn't be reached: \(underlying.map { String(describing: $0) } ?? "no response")" }
}

// MARK: - Client

/// The HTTP client: bearer tokens, silent refresh, JSON in and out. Bytes of
/// assets never pass through it — uploads go straight to the presigned URLs.
actor PicPlaceClient {

    private var tokens: PicPlaceTokens?
    /// The Keychain account a refreshed pair is written back under — the
    /// session's `PicPlaceBindingRecord.accountKey`. nil for tokens that
    /// were never stored (a hook's injected pair).
    private var accountKey: String?
    private var refreshTask: Task<PicPlaceTokens, Error>?
    private let session: URLSession
    /// Called once when a refresh is refused — the tokens are gone for good.
    private let signedOut: @Sendable () -> Void

    init(tokens: PicPlaceTokens?, accountKey: String?, signedOut: @escaping @Sendable () -> Void) {
        self.tokens = tokens
        self.accountKey = accountKey
        self.signedOut = signedOut
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    var isSignedIn: Bool { tokens != nil }

    /// The pair in hand — what `establishProfile` stores under the account
    /// once `/status` has named it.
    func currentTokens() throws -> PicPlaceTokens {
        guard let tokens else { throw PicPlaceAPIError(status: 401, code: "signed_out", message: "Not signed in to PicPlace.", claim: nil) }
        return tokens
    }

    func setTokens(_ newTokens: PicPlaceTokens?, accountKey newKey: String?) {
        tokens = newTokens
        accountKey = newKey
    }

    /// The server the current tokens name — every request goes there, never
    /// to the Settings value, so a bound library talks to ITS server while
    /// the setting only seeds the next sign-in (v2 plan §3.2).
    private func apiBase(for tokens: PicPlaceTokens) -> URL {
        URL(string: tokens.server)!.appendingPathComponent("api/letslapse/v1", isDirectory: false)
    }

    /// ISO8601DateFormatter is thread-safe; the box only says so to the compiler.
    private final class DateFormatters: @unchecked Sendable {
        let plain: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()
        let withFraction: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        func date(from string: String) -> Date? {
            plain.date(from: string) ?? withFraction.date(from: string)
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let formatters = DateFormatters()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = formatters.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO-8601 date: \(string)"))
        }
        return decoder
    }()

    // MARK: OAuth

    /// Authorization-code exchange, PKCE verifier in place of a secret.
    static func exchange(code: String, verifier: String, server: URL, redirectURI: String) async throws -> PicPlaceTokens {
        try await tokenRequest(server: server, form: [
            "grant_type": "authorization_code",
            "client_id": PicPlaceConfiguration.clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "code": code,
        ])
    }

    private static func tokenRequest(server: URL, form: [String: String]) async throws -> PicPlaceTokens {
        var request = URLRequest(url: server.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form.map { "\($0.key)=\(formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw PicPlaceOfflineError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else { throw PicPlaceOfflineError(underlying: nil) }
        guard http.statusCode == 200 else {
            throw PicPlaceAPIError(status: http.statusCode,
                                   code: (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String,
                                   message: "PicPlace refused the sign-in (\(http.statusCode)).", claim: nil)
        }
        struct TokenResponse: Decodable { var accessToken: String; var refreshToken: String; var expiresIn: Double }
        let body = try decoder.decode(TokenResponse.self, from: data)
        return PicPlaceTokens(accessToken: body.accessToken, refreshToken: body.refreshToken,
                              expiresAt: Date().addingTimeInterval(body.expiresIn), server: server.absoluteString)
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// A valid access token, refreshing first when the stored one is about to
    /// expire. Concurrent callers share one refresh: refresh tokens rotate,
    /// so two refreshes in flight would sign the device out.
    private func validTokens() async throws -> PicPlaceTokens {
        guard let current = tokens else { throw PicPlaceAPIError(status: 401, code: "signed_out", message: "Not signed in to PicPlace.", claim: nil) }
        if !current.isExpiringSoon { return current }
        return try await refresh()
    }

    private func refresh() async throws -> PicPlaceTokens {
        if let refreshTask { return try await refreshTask.value }
        guard let current = tokens else { throw PicPlaceAPIError(status: 401, code: "signed_out", message: "Not signed in to PicPlace.", claim: nil) }
        let key = accountKey
        let task = Task<PicPlaceTokens, Error> {
            do {
                let fresh = try await Self.tokenRequest(server: URL(string: current.server)!, form: [
                    "grant_type": "refresh_token",
                    "client_id": PicPlaceConfiguration.clientID,
                    "refresh_token": current.refreshToken,
                ])
                if let key { try? PicPlaceKeychain.save(fresh, account: key) }
                return fresh
            } catch let error as PicPlaceAPIError where error.status == 400 || error.status == 401 {
                // invalid_grant: the refresh token was revoked or already
                // used. Refresh tokens rotate, so "already used" can mean
                // another instance of the app (a second Mac window, a test
                // run) refreshed first and stored the newer pair — adopt it
                // rather than sign this one out and delete theirs.
                if let key, let stored = PicPlaceKeychain.load(account: key), stored.refreshToken != current.refreshToken {
                    LLog("picplace: refresh refused; another instance rotated the tokens — adopting the stored pair")
                    return stored
                }
                if let key { PicPlaceKeychain.clear(account: key) }
                throw error
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            tokens = fresh
            return fresh
        } catch {
            if let apiError = error as? PicPlaceAPIError, apiError.status == 400 || apiError.status == 401 {
                tokens = nil
                signedOut()
            }
            throw error
        }
    }

    // MARK: Requests

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await send("GET", path, query: query, body: nil)
    }

    func post<T: Decodable>(_ path: String, json: Any? = nil) async throws -> T {
        try await send("POST", path, query: [:], body: json)
    }

    func put<T: Decodable>(_ path: String, json: Any) async throws -> T {
        try await send("PUT", path, query: [:], body: json)
    }

    func delete<T: Decodable>(_ path: String) async throws -> T {
        try await send("DELETE", path, query: [:], body: nil)
    }

    /// A GET whose body the caller reads itself — the project detail, whose
    /// `manifest` is the app's own JSON.
    func getData(_ path: String, query: [String: String] = [:]) async throws -> Data {
        try await sendData("GET", path, query: query, body: nil).0
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: [String: String], body: Any?, retrying: Bool = false) async throws -> T {
        let (data, http) = try await sendData(method, path, query: query, body: body, retrying: retrying)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            LLog("picplace: \(method) \(path) → \(T.self) failed to decode: \(error); body: \(String(decoding: data.prefix(600), as: UTF8.self))")
            throw PicPlaceAPIError(status: http.statusCode, code: "bad_response", message: "PicPlace sent something LetsLapse couldn't read (\(Self.describe(error))).", claim: nil)
        }
    }

    private func sendData(_ method: String, _ path: String, query: [String: String], body: Any?, retrying: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let current = try await validTokens()
        var components = URLComponents(url: apiBase(for: current).appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PicPlaceOfflineError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else { throw PicPlaceOfflineError(underlying: nil) }

        if http.statusCode == 401, !retrying, tokens != nil {
            // The access token was revoked or expired early; refresh once and retry.
            _ = try await refresh()
            return try await sendData(method, path, query: query, body: body, retrying: true)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw Self.decodeError(status: http.statusCode, data: data)
        }
        return (data, http)
    }

    /// Which key, in plain words, when a reply does not match the wire types.
    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String { context.codingPath.map(\.stringValue).joined(separator: ".") }
        switch decoding {
        case .keyNotFound(let key, let context): return "missing \(path(context)).\(key.stringValue)"
        case .valueNotFound(_, let context): return "null at \(path(context))"
        case .typeMismatch(_, let context): return "wrong type at \(path(context))"
        case .dataCorrupted(let context): return "bad value at \(path(context)): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }

    private static func decodeError(status: Int, data: Data) -> PicPlaceAPIError {
        struct Body: Decodable { var error: String?; var message: String?; var claim: PPClaim?; var errors: [String: [String]]? }
        if let body = try? decoder.decode(Body.self, from: data) {
            var message = body.message ?? "PicPlace refused the request (\(status))."
            if let errors = body.errors, let first = errors.values.first?.first { message = first }
            return PicPlaceAPIError(status: status, code: body.error, message: message, claim: body.claim)
        }
        return PicPlaceAPIError(status: status, code: nil, message: "PicPlace refused the request (\(status)).", claim: nil)
    }
}

/// An empty JSON object, for endpoints whose body is not needed.
struct PPEmpty: Decodable {}
