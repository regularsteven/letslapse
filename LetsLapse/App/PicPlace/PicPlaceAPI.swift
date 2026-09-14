import Foundation

// MARK: - Wire types (docs/letslapse-auth.md, letslapse-api.md in the picplace repo)

struct PPStatus: Decodable {
    struct User: Decodable { var uuid: String; var username: String?; var name: String? }
    struct Storage: Decodable { var quotaBytes: Int64?; var usedBytes: Int64; var downloadUrlTtlSeconds: Int; var uploadUrlTtlSeconds: Int }
    var apiVersion: Int
    var serverTime: Date
    var user: User
    var device: PPDevice?
    var scopes: [String]
    var storage: Storage
    var features: [String: Bool]
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
}

struct PPAsset: Decodable {
    var id: String
    var kind: String
    var name: String
    var bytes: Int64
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

/// `GET /projects/{uuid}` — the registry row beside the manifest and the asset list.
struct PPProjectDetail: Decodable {
    var project: PPProject
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
    private var refreshTask: Task<PicPlaceTokens, Error>?
    private let session: URLSession
    /// Called once when a refresh is refused — the tokens are gone for good.
    private let signedOut: @Sendable () -> Void

    init(tokens: PicPlaceTokens?, signedOut: @escaping @Sendable () -> Void) {
        self.tokens = tokens
        self.signedOut = signedOut
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    var isSignedIn: Bool { tokens != nil }

    func setTokens(_ newTokens: PicPlaceTokens?) {
        tokens = newTokens
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
        let task = Task<PicPlaceTokens, Error> {
            do {
                let fresh = try await Self.tokenRequest(server: URL(string: current.server)!, form: [
                    "grant_type": "refresh_token",
                    "client_id": PicPlaceConfiguration.clientID,
                    "refresh_token": current.refreshToken,
                ])
                try? PicPlaceKeychain.save(fresh)
                return fresh
            } catch let error as PicPlaceAPIError where error.status == 400 || error.status == 401 {
                // invalid_grant: the refresh token was revoked or already used.
                PicPlaceKeychain.clear()
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

    private func send<T: Decodable>(_ method: String, _ path: String, query: [String: String], body: Any?, retrying: Bool = false) async throws -> T {
        let current = try await validTokens()
        var components = URLComponents(url: PicPlaceConfiguration.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
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
            return try await send(method, path, query: query, body: body, retrying: true)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw Self.decodeError(status: http.statusCode, data: data)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            LLog("picplace: \(method) \(path) → \(T.self) failed to decode: \(error); body: \(String(decoding: data.prefix(600), as: UTF8.self))")
            throw PicPlaceAPIError(status: http.statusCode, code: "bad_response", message: "PicPlace sent something LetsLapse couldn't read (\(Self.describe(error))).", claim: nil)
        }
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
