import Foundation

/// How long each kind of call may take.
///
/// The read timeouts are generous because generation is slow, not because the platform is. A
/// streamed read allows less than a buffered one: the gateway's own idle limit is 120s, so
/// waiting much past that means the stream is not merely slow, it is gone.
public struct Timeouts: Sendable, Hashable {
    public var connect: TimeInterval = 10
    public var request: TimeInterval = 600
    /// No whole-request timeout applies to a stream — a long generation is not a stalled one —
    /// so this bounds the gap between frames instead.
    public var streamRead: TimeInterval = 180
    public var auth: TimeInterval = 30

    public init(
        connect: TimeInterval = 10, request: TimeInterval = 600, streamRead: TimeInterval = 180,
        auth: TimeInterval = 30
    ) {
        self.connect = connect
        self.request = request
        self.streamRead = streamRead
        self.auth = auth
    }
}

/// Everything the client needs to reach a deployment.
///
/// **Configured in code, with the environment as an optional fallback and never a requirement.**
/// The other SDKs in this family lean on `AXONIUM_*` variables because they run on servers. An app
/// on macOS or iOS has no meaningful process environment and no `.env`, so everything here can be
/// passed in Swift.
///
/// **Whether ``clientSecret`` belongs here depends on whose credential it is.** This doc has said
/// two different things, and the second was the platform's answer to the first:
///
/// 1. Originally: the secret comes out of the Keychain at runtime.
/// 2. Then §2.7 refused it — credentials to confidential clients only — so these fields were
///    documented as server-only and ``TokenProvider`` as the shape for an app.
/// 3. Now, at guide revision `2026-10-01`, §2.7 is rewritten and the axis has moved to **whose the
///    credential is**. Both of the above were answers to the wrong question.
///
/// - Leave these empty and supply a ``TokenProvider`` when the credential is **yours**. A copy of
///   it on every user's device is a copy of the identity that holds your grants and is billed.
/// - Fill them in when the credential is **that user's own**, including from their Keychain. The
///   principal, the grants and the bill are theirs, so the blast radius of a leak is their account.
///
/// An app with a credential in it is still a public client in RFC 8252's terms. That is accepted
/// here when the secret and the bill belong to the same person, which is the distinction the
/// previous version of this doc did not draw.
public struct AxoniumConfiguration: Sendable {
    /// The gateway's base URL. The token endpoint lives on it too — the auth-service is no
    /// longer an address a client needs to know.
    public var gatewayBaseURL: String
    public var clientID: String
    public var clientSecret: String
    /// The scope to request. The **granted** scope is read back off the token response and may
    /// be narrower; never assume this is what you got.
    public var scope: String
    public var timeouts: Timeouts
    public var retry: RetryPolicy
    /// A private CA to trust **in addition to** the system's, as DER or PEM data.
    ///
    /// Data rather than a file path, because an app bundles a certificate as a resource or pulls
    /// it from an MDM profile; a path into a sandboxed container is not a thing a caller can
    /// usefully name. There is deliberately no option to disable verification.
    public var additionalTrustAnchors: [Data]
    /// Replaces the URLSession configuration, for tests with `URLProtocol`, proxies and MDM.
    public var sessionConfiguration: URLSessionConfiguration?

    public init(
        gatewayBaseURL: String,
        clientID: String = "",
        clientSecret: String = "",
        scope: String = "",
        timeouts: Timeouts = Timeouts(),
        retry: RetryPolicy = RetryPolicy(),
        additionalTrustAnchors: [Data] = [],
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.gatewayBaseURL = gatewayBaseURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scope = scope
        self.timeouts = timeouts
        self.retry = retry
        self.additionalTrustAnchors = additionalTrustAnchors
        self.sessionConfiguration = sessionConfiguration
    }

    /// Reads whatever the environment supplies, for a command-line tool or a test harness.
    ///
    /// Anything passed explicitly wins. Nothing here is required, and an app is expected to use
    /// ``init(gatewayBaseURL:clientID:clientSecret:scope:timeouts:retry:additionalTrustAnchors:sessionConfiguration:)``
    /// directly.
    public static func fromEnvironment(
        gatewayBaseURL: String? = nil, clientID: String? = nil, clientSecret: String? = nil,
        scope: String? = nil
    ) -> AxoniumConfiguration {
        let env = ProcessInfo.processInfo.environment
        return AxoniumConfiguration(
            gatewayBaseURL: gatewayBaseURL ?? env["AXONIUM_GATEWAY_BASE_URL"] ?? "",
            clientID: clientID ?? env["AXONIUM_CLIENT_ID"] ?? "",
            clientSecret: clientSecret ?? env["AXONIUM_CLIENT_SECRET"] ?? "",
            scope: scope ?? env["AXONIUM_SCOPE"] ?? ""
        )
    }

    /// Fails loudly at construction rather than as a confusing request error later, naming the
    /// setting and how to supply it.
    func validate(hasExternalTokenProvider: Bool) throws {
        let trimmed = gatewayBaseURL.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            throw AxoniumError.configuration(
                "gatewayBaseURL is required. Pass it to AxoniumConfiguration, or set "
                    + "AXONIUM_GATEWAY_BASE_URL and use AxoniumConfiguration.fromEnvironment().")
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme,
            ["http", "https"].contains(scheme.lowercased()), url.host != nil
        else {
            throw AxoniumError.configuration(
                "gatewayBaseURL must be an http(s) URL with a host, got \"\(gatewayBaseURL)\".")
        }
        // A caller supplying their own TokenProvider is in governed mode and has no credentials
        // here on purpose, so demanding them would break the mode that exists for it.
        if !hasExternalTokenProvider && (clientID.isEmpty || clientSecret.isEmpty) {
            throw AxoniumError.configuration(
                "clientID and clientSecret are required unless a TokenProvider is supplied. "
                    + "In a distributed app, supply a TokenProvider instead: this credential is "
                    + "the integrator's identity, not the user's, and the platform issues it to "
                    + "confidential clients only (guide 2.7). On a machine you control, "
                    + "AXONIUM_CLIENT_ID and AXONIUM_CLIENT_SECRET also work.")
        }
    }

    var normalizedBaseURL: String {
        var trimmed = gatewayBaseURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
