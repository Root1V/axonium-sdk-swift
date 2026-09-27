import Foundation

/// Decodes the two error envelopes this platform uses.
///
/// Which one arrives is keyed on the *envelope*, not on the status. A 4xx from the token endpoint
/// is an OAuth2 outcome in the RFC 6749 shape and is never worth retrying; a 5xx there is the
/// gateway failing to do its job, arrives as problem+json, and often is. Reading every failure as
/// OAuth2 would collapse that distinction and report a momentary blip as bad credentials -- which
/// is the most expensive wrong answer available, because the caller goes and rotates a perfectly
/// good secret.
public enum ProblemDetails {
    /// Builds a typed error from a gateway response.
    ///
    /// - Parameters:
    ///   - body: the decoded JSON body, or `nil` when it was not JSON at all.
    ///   - headers: the response headers, which are where the correlation ids come from when the
    ///     body has none.
    ///
    /// **The body wins where it has them and the headers cover the rest.** A body that honours
    /// the contract carries `request_id` and `trace_id`, but several real responses do not -- a
    /// validation failure forwarded verbatim from an engine, a 404 for a route the gateway does
    /// not serve, an HTML page from a proxy that never reached the gateway. All three carry
    /// `X-Request-ID` in the header. Reading the body only, which the other three SDKs did until
    /// 2026-09-27, hands the caller an error nobody can correlate and therefore nobody can report.
    public static func apiError(
        status: Int,
        body: [String: Any]?,
        headers: [String: String],
        retryAfter: Double? = nil,
        rateLimit: RateLimitSnapshot? = nil
    ) -> APIError {
        let string = { (key: String) -> String in body?[key] as? String ?? "" }

        let typeSuffix: String = {
            guard let uri = body?["type"] as? String else { return "" }
            let trimmed = uri.hasSuffix("/") ? String(uri.dropLast()) : uri
            return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        }()

        // The header is the authority on the wait where both exist; the platform team confirmed
        // the two are written from one variable in one call, so they cannot disagree today. The
        // precedence is what protects the next envelope that carries only one of them.
        let resolvedRetryAfter =
            retryAfter ?? (body?["retry_after"] as? NSNumber).map(\.doubleValue)

        return APIError(
            status: status,
            kind: ErrorKind(suffix: typeSuffix, status: status),
            typeSuffix: typeSuffix,
            title: string("title"),
            detail: string("detail"),
            instance: string("instance"),
            requestID: firstNonEmpty(string("request_id"), header(headers, "X-Request-ID")),
            traceID: firstNonEmpty(string("trace_id"), header(headers, "X-Trace-ID")),
            retryAfter: resolvedRetryAfter,
            hint: "",
            rateLimit: rateLimit,
            raw: (body ?? [:]).mapValues(JSONValue.init)
        )
    }

    /// Builds an error from a token-endpoint response, choosing the envelope by its shape.
    public static func tokenError(
        status: Int, body: [String: Any]?, headers: [String: String]
    ) -> AxoniumError {
        if body?["type"] is String {
            return .api(apiError(status: status, body: body, headers: headers))
        }
        if let code = body?["error"] as? String {
            return .oauth(
                OAuthError(
                    status: status,
                    code: code,
                    errorDescription: body?["error_description"] as? String ?? ""
                ))
        }
        // Neither envelope. Almost always something that is not the gateway answering at all -- a
        // proxy or load balancer with an HTML error page. Calling that an OAuth2 failure would
        // tell the caller their credentials are the problem, which is both wrong and expensive.
        return .authTransport(
            "the token endpoint returned \(status) with a body in neither the OAuth2 nor the "
                + "problem+json shape, so it was probably not the gateway that answered")
    }

    private static func header(_ headers: [String: String], _ name: String) -> String {
        // HTTP header names are case-insensitive and URLSession does not promise a casing.
        let wanted = name.lowercased()
        for (key, value) in headers where key.lowercased() == wanted { return value }
        return ""
    }

    private static func firstNonEmpty(_ a: String, _ b: String) -> String { a.isEmpty ? b : a }
}
