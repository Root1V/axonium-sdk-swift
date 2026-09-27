import Foundation

extension RateLimitSnapshot {
    /// Reads the six `X-RateLimit-*` numbers and the scope out of a response's headers.
    ///
    /// Header names are matched case-insensitively: HTTP does not distinguish them and
    /// `URLSession` makes no promise about the casing it hands back.
    public static func fromHeaders(_ headers: [String: String]) -> RateLimitSnapshot {
        let lookup = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        func int(_ name: String) -> Int? { lookup[name].flatMap(Int.init) }

        return RateLimitSnapshot(
            scope: lookup["x-ratelimit-scope"],
            limitRequests: int("x-ratelimit-limit-requests"),
            remainingRequests: int("x-ratelimit-remaining-requests"),
            resetRequests: int("x-ratelimit-reset-requests"),
            limitTokens: int("x-ratelimit-limit-tokens"),
            remainingTokens: int("x-ratelimit-remaining-tokens"),
            resetTokens: int("x-ratelimit-reset-tokens")
        )
    }

    /// Fills in `scope` from an error body when the header did not carry it.
    ///
    /// The rate-limit envelope used to omit `X-RateLimit-Scope` and put the value in the body's
    /// `scope` field instead -- the one error that names a budget was the one unable to say which,
    /// because two copies of the header list existed and only one grew the new header. The
    /// platform fixed that on 2026-09-19b, so on a current deployment the header is there and
    /// this changes nothing. It stays because a deployment predating the fix still answers the
    /// old way, and the header-winning precedence is what protects the next envelope that carries
    /// only one of the two.
    public func withScope(from body: [String: Any]?) -> RateLimitSnapshot {
        guard scope == nil, let bodyScope = body?["scope"] as? String else { return self }
        var copy = self
        copy.scope = bodyScope
        return copy
    }
}
