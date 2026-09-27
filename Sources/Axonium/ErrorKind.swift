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

    // 5xx
    case upstreamError
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
            .rateLimitingUnavailable, .usageStoreUnavailable, .idempotencyInProgress,
            .tokenEndpointUnavailable, .otherServerError:
            return true
        // modelNotLoaded is a 5xx and is not retryable: it needs an operator, not patience.
        // tokenEndpointNotConfigured shares a status with tokenEndpointUnavailable for the same
        // reason.
        default:
            return false
        }
    }
}
