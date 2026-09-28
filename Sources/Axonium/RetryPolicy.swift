import Foundation

/// When a failed call is worth repeating, and how long to wait first.
///
/// Two conditions, both necessary. The error has to be one where retrying can plausibly succeed
/// — ``APIError/isRetryable`` — **and** the repeat must not become a second billable generation.
/// The second is the one that is easy to forget and expensive to get wrong.
public struct RetryPolicy: Sendable, Hashable {
    public var maxAttempts: Int = 3
    public var initialBackoff: TimeInterval = 1
    public var maxBackoff: TimeInterval = 60
    /// Fraction of the delay randomised, so a fleet backing off together does not return together.
    public var jitter: Double = 0.2

    public init(
        maxAttempts: Int = 3, initialBackoff: TimeInterval = 1, maxBackoff: TimeInterval = 60,
        jitter: Double = 0.2
    ) {
        self.maxAttempts = maxAttempts
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.jitter = jitter
    }

    /// Never retries anything.
    public static let none = RetryPolicy(maxAttempts: 1)

    /// Exponential backoff for an attempt, capped and jittered.
    public func backoff(attempt: Int) -> TimeInterval {
        let raw = initialBackoff * pow(2, Double(max(0, attempt - 1)))
        let capped = min(raw, maxBackoff)
        guard jitter > 0 else { return capped }
        return capped * (1 + Double.random(in: -jitter...jitter))
    }

    /// How long to wait before repeating this error, or `nil` to give up.
    ///
    /// `Retry-After` wins when the platform sent one: it is the gateway's own expected recovery
    /// time, which is better information than any local guess. A `502 upstream-error` gets at
    /// most one repeat because the gateway already made three of its own.
    func delay(for error: APIError, attempt: Int, hasIdempotencyKey: Bool) -> TimeInterval? {
        guard attempt < maxAttempts, error.isRetryable else { return nil }
        if error.kind == .upstreamError && attempt >= 2 { return nil }
        if let retryAfter = error.retryAfter { return max(0, retryAfter) }
        return backoff(attempt: attempt)
    }
}
