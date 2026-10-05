import Foundation

/// The rate-limit budget as of one response.
///
/// `scope` names *which* budget the numbers describe, and is an **open set read from the header**
/// rather than a list kept here. Five SDKs kept five different hand-written lists and they had
/// already diverged -- one said `chat` where the header says `chat_completions` -- and the guide
/// contradicts itself about the set, so the header is the only answer that cannot go stale.
///
/// There is more than one budget, which is the part that matters: a single "last seen" slot would
/// end up holding whichever endpoint answered last while looking entirely plausible. Key it before
/// you cache it.
///
/// The budget is a **fixed 60-second bucket aligned to the wall clock**, not a sliding window: the
/// whole allowance returns at second 0 of each minute, which is what ``resetRequests`` timestamps.
/// A burst can straddle a boundary and pass where the same burst seconds earlier is refused, so
/// pace against ``remainingRequests`` rather than against an assumed rate.
public struct RateLimitSnapshot: Sendable, Hashable {
    public var scope: String?
    public var limitRequests: Int?
    public var remainingRequests: Int?
    public var resetRequests: Int?
    public var limitTokens: Int?
    public var remainingTokens: Int?
    public var resetTokens: Int?

    public var isEmpty: Bool {
        scope == nil && limitRequests == nil && remainingRequests == nil && resetRequests == nil
            && limitTokens == nil && remainingTokens == nil && resetTokens == nil
    }
}

/// An RFC 9457 problem-details error returned by the gateway.
public struct APIError: Sendable, Hashable {
    public var status: Int
    public var kind: ErrorKind
    /// Last path segment of the `type` URI. Empty when the response carried none, which is not
    /// hypothetical -- see ``ErrorKind/otherClientError``.
    public var typeSuffix: String
    public var title: String
    public var detail: String
    public var instance: String
    public var requestID: String
    /// Empty when the response carried none.
    public var traceID: String
    /// Resolved wait in seconds, or `nil` when the platform supplied none.
    public var retryAfter: Double?
    /// A client-side diagnosis added where this SDK can say something `detail` does not, such as
    /// exactly which scope a token is missing.
    public var hint: String
    public var rateLimit: RateLimitSnapshot?
    /// The decoded body, so a field this SDK does not model stays reachable.
    public var raw: [String: JSONValue] = [:]

    /// Whether retrying this can plausibly succeed at all.
    ///
    /// Keyed on ``kind``, with one exception. ``ErrorKind/predictBackendRejected`` carries
    /// whatever status the engine returned, so its name says nothing about whether waiting helps
    /// and only the status can. Every other entry in the catalog can answer without looking.
    public var isRetryable: Bool {
        if kind == .predictBackendRejected {
            return Self.predictBackendRetryableStatuses.contains(status)
        }
        return kind.isRetryable
    }

    /// The one 4xx worth repeating when the gateway wraps an engine's refusal. Everything else
    /// the engine rejects is the request to fix.
    private static let predictBackendRetryableStatuses: Set<Int> = [429]

    /// The engine's own error body, preserved verbatim, on an error from
    /// `POST /v1/models/{model}/predict`.
    ///
    /// `nil` when the extension member is absent: a gateway that wrapped the refusal without
    /// capturing it, in which case the status is all there is. The shape is the engine's and this
    /// SDK does not model it — that is what the pass-through route means.
    public var backendError: JSONValue? { raw["backend_error"] }

    /// The engine's status when it differs from this error's.
    ///
    /// Present on the `502` path, where the gateway reports its own status because a `500` the
    /// engine produced is not one a caller can act on. On the 4xx path the two are the same and
    /// this is `nil`.
    public var backendStatus: Int? { raw["backend_status"]?.intValue }
}

/// An RFC 6749 §5.2 error from the token endpoint.
///
/// Deliberately not an ``APIError``. The two envelopes mean different things, and a caller
/// handling "the gateway is unhappy" should not silently absorb "your credentials are wrong": a
/// 4xx here is never worth retrying, while a gateway 5xx often is.
public struct OAuthError: Sendable, Hashable {
    public var status: Int
    public var code: String
    public var errorDescription: String
}

/// Everything this SDK throws.
public enum AxoniumError: Error, Sendable {
    /// A typed gateway failure.
    case api(APIError)
    /// The token endpoint rejected the credentials or the grant.
    case oauth(OAuthError)
    /// A required setting is missing or unusable. Thrown at construction, naming the setting.
    case configuration(String)
    /// A value that cannot be valid, caught before a round trip is spent on it.
    case invalidRequest(String)
    /// The request never produced an HTTP response.
    case transport(String)
    /// The auth-service could not be reached, or answered with something unusable. Distinct from
    /// ``oauth(_:)``, which is the auth-service correctly reporting a rejection.
    case authTransport(String)
    /// The client gave up waiting. The backend may still be generating, so a retry without an
    /// `Idempotency-Key` would start a second billable generation rather than resume the first.
    case timeout(String)
    /// The stream failed after it had begun.
    ///
    /// A failure *before* the stream begins is an ordinary ``api(_:)`` with a real status -- the
    /// gateway reads the engine's status before committing the `200`, so a request the engine
    /// refuses never becomes a stream. Once generation has started the headers are committed and
    /// the only channel left is in-band, which is this.
    case streamInterrupted(message: String, partialContent: String, requestID: String, traceID: String)
}

extension AxoniumError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .api(let error):
            var parts: [String] = []
            if !error.detail.isEmpty {
                parts.append(error.detail)
            } else if !error.title.isEmpty {
                parts.append(error.title)
            } else {
                parts.append("HTTP \(error.status)")
            }
            if !error.hint.isEmpty { parts.append(error.hint) }
            if !error.requestID.isEmpty { parts.append("request_id=\(error.requestID)") }
            if !error.traceID.isEmpty { parts.append("trace_id=\(error.traceID)") }
            return parts.joined(separator: " ")
        case .oauth(let error):
            let detail = error.errorDescription.isEmpty ? error.code : error.errorDescription
            return "the token endpoint refused the request: \(detail) (\(error.code))"
        case .configuration(let message): return message
        case .invalidRequest(let message): return message
        case .transport(let message): return message
        case .authTransport(let message): return message
        case .timeout(let message): return message
        case .streamInterrupted(let message, _, let requestID, let traceID):
            var parts = ["the stream was interrupted: \(message)"]
            if !requestID.isEmpty { parts.append("request_id=\(requestID)") }
            if !traceID.isEmpty { parts.append("trace_id=\(traceID)") }
            return parts.joined(separator: " ")
        }
    }
}

extension AxoniumError: LocalizedError {
    public var errorDescription: String? { description }
}
