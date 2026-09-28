import Foundation

/// Supplies the bearer token for every request.
///
/// A protocol rather than a concrete type so an app can hand the client a token it obtained some
/// other way — a backend-for-frontend, an MDM-provisioned credential, a mock in a test — without
/// the SDK ever seeing a client secret. That mode is the reason `clientID`/`clientSecret` are
/// optional in ``AxoniumConfiguration``.
public protocol TokenProvider: Sendable {
    /// The token to use now, obtaining or refreshing one if needed.
    func token() async throws -> String
    /// Called once after a `401`, with the token that was rejected.
    ///
    /// Implementations must return a genuinely new token or throw; returning the rejected one
    /// turns a single retry into a request that fails twice for the same reason.
    func refresh(rejected: String) async throws -> String
    /// The scope actually granted, for diagnosing a `403`. Empty when unknown.
    var grantedScope: [String] { get async }
}

/// A token obtained from the platform, with everything needed to decide when to replace it.
struct TokenSet: Sendable {
    var accessToken: String
    /// Measured against a monotonic clock, so neither a skewed peer nor an NTP step can make a
    /// live token look expired.
    var obtainedAt: ContinuousClock.Instant
    var lifetime: Duration
    var scope: [String]

    /// The longest lifetime an operator can legitimately configure. A larger `expires_in` is not
    /// something the platform can issue, so it is clamped rather than trusted: believing it would
    /// mean never refreshing ahead and falling back to the reactive `401` path forever.
    static let maxPlausibleLifetime = Duration.seconds(24 * 60 * 60)

    /// True when the token should be replaced before it is used again.
    ///
    /// Ahead of expiry rather than on a `401`, so the normal path never spends a failed request
    /// discovering that a token died. At 80% of the lifetime, or with under 30s left, whichever
    /// comes first.
    func needsRefresh(now: ContinuousClock.Instant) -> Bool {
        let elapsed = now - obtainedAt
        let remaining = lifetime - elapsed
        if remaining <= .seconds(30) { return true }
        return elapsed >= lifetime * 0.8
    }
}

/// Obtains tokens with the `client_credentials` grant.
///
/// An `actor` so that a burst of concurrent requests arriving on an expired token produces **one**
/// token request rather than one per caller. Without that, a cold client answering ten parallel
/// calls asks the auth-service ten times and races over which result it keeps.
public actor ClientCredentialsTokenProvider: TokenProvider {
    private let configuration: AxoniumConfiguration
    private let session: URLSession
    private var current: TokenSet?
    /// The refresh in flight, if any. Awaiting it is what collapses a burst into one request.
    private var inFlight: Task<TokenSet, Error>?

    init(configuration: AxoniumConfiguration, session: URLSession) {
        self.configuration = configuration
        self.session = session
    }

    public var grantedScope: [String] {
        current?.scope ?? []
    }

    public func token() async throws -> String {
        if let current, !current.needsRefresh(now: ContinuousClock.now) {
            return current.accessToken
        }
        return try await fetchOnce().accessToken
    }

    public func refresh(rejected: String) async throws -> String {
        // Another caller may have replaced the token while this request was in flight; reusing
        // theirs avoids a second token request under a concurrent 401 burst.
        if let current, current.accessToken != rejected { return current.accessToken }
        current = nil
        return try await fetchOnce().accessToken
    }

    private func fetchOnce() async throws -> TokenSet {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.fetch() }
        inFlight = task
        defer { inFlight = nil }
        let set = try await task.value
        current = set
        return set
    }

    private func fetch() async throws -> TokenSet {
        guard !configuration.clientID.isEmpty, !configuration.clientSecret.isEmpty else {
            throw AxoniumError.authTransport(
                "this client has no credentials; supply clientID and clientSecret, or a TokenProvider")
        }

        var form = [
            "grant_type": "client_credentials",
            "client_id": configuration.clientID,
            "client_secret": configuration.clientSecret,
        ]
        if !configuration.scope.isEmpty { form["scope"] = configuration.scope }

        var request = URLRequest(
            url: URL(string: configuration.normalizedBaseURL + "/oauth2/token")!)
        request.httpMethod = "POST"
        // Form-encoded, not JSON. The one endpoint in this platform that is.
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.encodeForm(form).data(using: .utf8)
        request.timeoutInterval = configuration.timeouts.auth

        // Captured before sending, so the round trip is charged against the token's life rather
        // than granted as extra margin.
        let obtainedAt = ContinuousClock.now

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AxoniumError.authTransport("could not reach the token endpoint: \(error)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw AxoniumError.authTransport("the token endpoint returned a non-HTTP response")
        }
        let headers = Self.headerDictionary(http)
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let object = body ?? nil

        guard http.statusCode == 200 else {
            throw ProblemDetails.tokenError(
                status: http.statusCode, body: object, headers: headers)
        }
        guard let object else {
            throw AxoniumError.authTransport(
                "the token endpoint returned a non-JSON \(http.statusCode) response")
        }
        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
            throw AxoniumError.authTransport(
                "the token endpoint response contained no access_token")
        }
        guard let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue, expiresIn > 0 else {
            throw AxoniumError.authTransport(
                "the token endpoint returned an unusable expires_in: "
                    + String(describing: object["expires_in"]))
        }

        var lifetime = Duration.seconds(expiresIn)
        if lifetime > TokenSet.maxPlausibleLifetime { lifetime = TokenSet.maxPlausibleLifetime }

        // Always the granted scope, never the requested one. They differ, and the difference is
        // exactly what a later 403 will be about.
        let granted = (object["scope"] as? String)?.split(separator: " ").map(String.init) ?? []

        return TokenSet(
            accessToken: accessToken, obtainedAt: obtainedAt, lifetime: lifetime, scope: granted)
    }

    static func encodeForm(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.keys.sorted().map { key in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? fields[key]!
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    static func headerDictionary(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return headers
    }
}

/// Claims read out of an access token, without verifying it.
///
/// Introspection for display and diagnostics only. The gateway is the sole authority on what a
/// token may do — never make an access-control decision from these. Note the platform does not
/// use `role` for authorization either; only `scope` governs what a token can call.
public struct TokenClaims: Sendable, Hashable {
    public var subject: String = ""
    public var clientName: String = ""
    public var role: String = ""
    public var scope: [String] = []
    public var expiresAt: Int = 0
    public var issuedAt: Int = 0

    /// Decodes a JWT payload. Returns an empty value for anything that is not one.
    public init(accessToken: String) {
        let segments = accessToken.split(separator: ".")
        guard segments.count >= 2 else { return }
        var base64 = String(segments[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        subject = payload["sub"] as? String ?? ""
        clientName = payload["client_name"] as? String ?? ""
        role = payload["role"] as? String ?? ""
        scope = (payload["scope"] as? String)?.split(separator: " ").map(String.init) ?? []
        expiresAt = (payload["exp"] as? NSNumber)?.intValue ?? 0
        issuedAt = (payload["iat"] as? NSNumber)?.intValue ?? 0
    }
}
