import Foundation

/// Correlation and accounting read off every response, successful or not.
///
/// On **every** response, not only failures. Correlating a call that was slow but succeeded
/// matters as much as correlating one that failed, and a field that were accurate on success and
/// silently zero otherwise would be worse than absent.
public struct ResponseMeta: Sendable, Hashable {
    /// Fresh per request, generated server-side. The one value to quote to the platform team.
    public var requestID: String = ""
    /// For log correlation. Empty on a deployment predating the fix that added it to every
    /// envelope.
    public var traceID: String = ""
    /// Which replica actually answered, by id and by its per-model label (`#2`).
    public var instance: String = ""
    public var instanceID: String = ""
    /// Which model actually served, when the name addressed a traffic split (§3.6b).
    ///
    /// Empty when no split applied, which is the ordinary case. `model` in the body stays the
    /// name that was sent — a canary must not change what a response says — so this is the only
    /// place the variant appears. It matters for reconciliation: the row is billed against the
    /// variant at the variant's rate, so a split's cost is not requests × one rate.
    public var variant: String = ""
    public var rateLimit: RateLimitSnapshot?

    /// True when the gateway returned a stored result instead of generating again.
    ///
    /// Not billed and not generated: the `Idempotency-Key` matched a completed request inside the
    /// 24h window. Worth reading rather than assuming, because the same call site produces both.
    public var idempotentReplay: Bool = false
    /// The id of the request that was actually charged, when this one is a replay.
    public var idempotentReplayOf: String = ""

    /// How long this call spent waiting between retries.
    ///
    /// Zero on a first-time success. Present so a call that honoured a `Retry-After` can explain
    /// its own duration without anyone reading a log — three teams reported a respected wait as a
    /// hang because the SDK's only account of it was a log event nobody had configured.
    public var waitedFor: TimeInterval = 0
    /// How many attempts this call took, including the one that succeeded.
    public var attempts: Int = 1

    static func from(headers: [String: String]) -> ResponseMeta {
        let lookup = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        var meta = ResponseMeta()
        meta.requestID = lookup["x-request-id"] ?? ""
        meta.traceID = lookup["x-trace-id"] ?? ""
        meta.instance = lookup["x-prometheus-instance"] ?? ""
        meta.instanceID = lookup["x-prometheus-instance-id"] ?? ""
        meta.variant = lookup["x-prometheus-variant"] ?? ""
        // Any value at all means replay; the gateway sends "true".
        meta.idempotentReplay = (lookup["idempotent-replay"] ?? "").isEmpty == false
        meta.idempotentReplayOf = lookup["x-idempotent-replay-of"] ?? ""
        let rateLimit = RateLimitSnapshot.fromHeaders(headers)
        meta.rateLimit = rateLimit.isEmpty ? nil : rateLimit
        return meta
    }
}

/// Token accounting for one request.
public struct Usage: Sendable, Hashable {
    public var promptTokens: Int = 0
    public var completionTokens: Int = 0
    public var totalTokens: Int = 0
    /// Prompt tokens served from the backend's cache.
    ///
    /// A **subset** of `promptTokens`, not a separate bucket: do not add them. Read off
    /// `prompt_tokens_details.cached_tokens`, which is the field the platform actually sends —
    /// an earlier guess at `cache_read_tokens` cost two teams a day.
    public var cacheReadTokens: Int = 0
    /// True when this was reconstructed from the backend's `timings` rather than reported.
    ///
    /// A streamed answer only carries real token counts if some chunk reports them. When none
    /// does, `predicted_n` and `prompt_n + cache_n` are the closest thing available, and saying
    /// so is the difference between an estimate and a number somebody bills against.
    public var estimated: Bool = false

    static func from(_ body: [String: JSONValue]) -> Usage? {
        guard let usage = body["usage"]?.objectValue else { return nil }
        var result = Usage()
        result.promptTokens = usage["prompt_tokens"]?.intValue ?? 0
        result.completionTokens = usage["completion_tokens"]?.intValue ?? 0
        result.totalTokens = usage["total_tokens"]?.intValue ?? 0
        result.cacheReadTokens =
            usage["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0
        return result
    }

    /// Reconstructs usage from the backend's own timing counters.
    ///
    /// `prompt_n` counts only the tokens the backend actually processed, so the cached ones have
    /// to be added back to arrive at the prompt total a caller is charged for.
    static func fromTimings(_ timings: [String: JSONValue]) -> Usage? {
        guard let predicted = timings["predicted_n"]?.intValue else { return nil }
        let cached = timings["cache_n"]?.intValue ?? 0
        let processed = timings["prompt_n"]?.intValue ?? 0
        var result = Usage()
        result.promptTokens = processed + cached
        result.completionTokens = predicted
        result.totalTokens = result.promptTokens + predicted
        result.cacheReadTokens = cached
        result.estimated = true
        return result
    }
}
