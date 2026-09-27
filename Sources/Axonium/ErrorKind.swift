import Foundation

/// The catalogued error types the gateway can return, keyed on the last segment of the
/// problem-details `type` URI.
///
/// Mirrors `spec/errors.json` in the corpus submodule, which every language SDK maps. A test holds
/// the two together in both directions -- a suffix in the catalog with no case here fails, and a
/// case here that the catalog does not list fails too.
///
/// **An unknown suffix is not a parse failure.** The catalog grows; three of the errors here
/// arrived after the first SDK shipped. A suffix this build does not recognise falls back to the
/// status-keyed case, so a client meeting tomorrow's error still gets a typed one.
public enum ErrorKind: Sendable, Hashable {
    // 400
    case unknownModel
    case modalityMismatch
    case contextExceeded
    case unknownParameter
    case unknownInstance
    case invalidIdempotencyKey
    case inconsistentModelGroup
    case invalidDate
    case invalidRange
    case rangeTooLarge

    // 401
    case missingCredentials
    case invalidToken
    case tokenExpired
    case tokenRevoked
    /// Only on `GET /v1/usage/{request_id}`: the request carried no verified claims. Distinct from
    /// ``missingCredentials``, which the auth middleware raises earlier.
    case unauthorizedRequest

    // 402 / 403
    case spendCapExceeded
    case forbidden

    // 404
    case notFound

    // 409
    case idempotencyKeyReuse
    case idempotencyInProgress
    case idempotencyResponseNotRetained

    // 422
    case validationError

    // 429
    case rateLimitExceeded

    /// The engine behind `predict` refused the request, wrapped rather than forwarded.
    ///
    /// The one kind whose status is not fixed. `POST /v1/models/{model}/predict` passes the body
    /// through to the engine, so a refusal keeps the engine's status — a `422` stays a `422` —
    /// and its error body is preserved under `backend_error`. The name therefore claims no cause:
    /// a `429` or a `403` from the engine is also a 4xx and has nothing to do with the payload.
    ///
    /// Because of that, ``isRetryable`` on this case cannot answer honestly and returns `false`.
    /// Ask ``APIError/isRetryable``, which has the status to read.
    case predictBackendRejected

    // 5xx
    case upstreamError
    /// Every replica of the model is above its pending-work headroom, so the request was refused
    /// rather than queued behind work that would outlive its own timeout.
    ///
    /// A saturated replica with a free sibling is not this error — the request goes to the
    /// sibling — so meeting it means all of them are busy, and `detail` names each.
    ///
    /// Distinct from ``backendUnavailable`` on purpose: that one means the replicas are broken
    /// and somebody should look at them, this one means they are working. `retryAfter` is always
    /// `1`, and the platform is explicit that it is a hint rather than a promise — a slot frees
    /// when some other request finishes, and how long that takes is the model's business.
    case capacityExhausted
    case modelNotLoaded
    case backendUnavailable
    case rateLimitingUnavailable
    case usageStoreUnavailable
    /// The gateway could not reach the auth-service to issue a token. The only problem+json a
    /// token request can produce -- every other token outcome uses the RFC 6749 shape -- and that
    /// distinction is what makes it safe to retry where an OAuth2 failure never is.
    case tokenEndpointUnavailable
    /// This deployment has no token endpoint wired up. Shares a status with
    /// ``tokenEndpointUnavailable`` and not its retryability, which is why the suffix has to
    /// decide rather than the status.
    case tokenEndpointNotConfigured

    // Fallbacks. Reached by an unrecognised suffix, or by a response carrying no `type` at all --
    // which happens for real: a route this gateway does not serve answers `{"detail":"Not Found"}`
    // as plain JSON, and request validation used to arrive the same way.
    case otherClientError
    case unauthorized
    case otherServerError

    /// Resolves a `type` suffix, falling back on the status when the suffix is not one this build
    /// knows.
    public init(suffix: String, status: Int) {
        switch suffix {
        case "unknown-model": self = .unknownModel
        case "modality-mismatch": self = .modalityMismatch
        case "context-exceeded": self = .contextExceeded
        case "unknown-parameter": self = .unknownParameter
        case "unknown-instance": self = .unknownInstance
        case "invalid-idempotency-key": self = .invalidIdempotencyKey
        case "inconsistent-model-group": self = .inconsistentModelGroup
        case "invalid-date": self = .invalidDate
        case "invalid-range": self = .invalidRange
        case "range-too-large": self = .rangeTooLarge
        case "missing-credentials": self = .missingCredentials
        case "invalid-token": self = .invalidToken
        case "token-expired": self = .tokenExpired
        case "token-revoked": self = .tokenRevoked
        case "unauthorized": self = .unauthorizedRequest
        case "spend-cap-exceeded": self = .spendCapExceeded
        case "forbidden": self = .forbidden
        case "not-found": self = .notFound
        case "idempotency-key-reuse": self = .idempotencyKeyReuse
        case "idempotency-in-progress": self = .idempotencyInProgress
        case "idempotency-response-not-retained": self = .idempotencyResponseNotRetained
        case "validation-error": self = .validationError
        case "rate-limit-exceeded-requests": self = .rateLimitExceeded
        case "upstream-error": self = .upstreamError
        case "capacity-exhausted": self = .capacityExhausted
        case "predict-backend-rejected": self = .predictBackendRejected
        case "model-not-loaded": self = .modelNotLoaded
        case "backend-unavailable": self = .backendUnavailable
        case "rate-limiting-unavailable": self = .rateLimitingUnavailable
        case "usage-store-unavailable": self = .usageStoreUnavailable
        case "upstream-unavailable": self = .tokenEndpointUnavailable
        case "not-configured": self = .tokenEndpointNotConfigured
        default:
            if status == 401 {
                self = .unauthorized
            } else if status >= 500 {
                self = .otherServerError
            } else {
                self = .otherClientError
            }
        }
    }

    /// Whether retrying this can plausibly succeed at all.
    ///
    /// A necessary condition and not a sufficient one: ``RetryPolicy`` additionally requires
    /// either that no generation occurred, or that an `Idempotency-Key` makes the repeat a replay
    /// rather than a second billing.
    public var isRetryable: Bool {
        switch self {
        case .tokenExpired, .rateLimitExceeded, .upstreamError, .backendUnavailable,
            .capacityExhausted, .rateLimitingUnavailable, .usageStoreUnavailable,
            .idempotencyInProgress, .tokenEndpointUnavailable, .otherServerError:
            return true
        // modelNotLoaded is a 5xx and is not retryable: it needs an operator, not patience.
        // tokenEndpointNotConfigured shares a status with tokenEndpointUnavailable for the same
        // reason. predictBackendRejected is absent because its answer is not a property of the
        // name; see ``APIError/isRetryable``.
        default:
            return false
        }
    }
}
