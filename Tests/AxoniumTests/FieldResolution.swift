import Foundation

@testable import Axonium

/// Resolves the manifest's dotted field paths against this SDK's own types.
///
/// The manifest is explicit that a path resolves "using the SDK's own accessors where it exposes
/// them". That matters: `usage.cache_read_tokens` is not a field the platform sends, it is one
/// this SDK derives from `prompt_tokens_details.cached_tokens`, and resolving it by walking the
/// raw body would test the fixture rather than the SDK. So the accessors come first, and the raw
/// body is the fallback for paths that are genuinely pass-through.
func resolve(_ path: String, in value: Any) -> Any? {
    if let completion = value as? ChatCompletion { return resolve(path, in: completion) }
    if let list = value as? ModelList { return resolve(path, in: list) }
    if let list = value as? EmbeddingList { return resolve(path, in: list) }
    if let list = value as? ImageList { return resolve(path, in: list) }
    if let list = value as? RerankList { return resolve(path, in: list) }
    if let row = value as? UsageRow { return resolve(path, in: row) }
    if let stream = value as? ChatStream { return resolve(path, in: stream) }
    return nil
}

/// Resolves a path against a finished stream.
///
/// **`meta.*` only, and deliberately.** A stream's content, chunk count, usage and tool calls
/// already have dedicated keys in the manifest and are asserted through those; what had no route
/// at all was `meta` — `request_id`, `trace_id`, `rate_limit`, and the two replay flags. All four
/// SDKs' runners could assert `fields` on a non-streaming case and none could on a streamed one,
/// so a stream that dropped its entire `meta` passed every case in the corpus.
///
/// Reading `content` here too would be a second way to say something the manifest already says
/// one way, which is how two spellings of one assertion drift apart.
private func resolve(_ path: String, in stream: ChatStream) -> Any? {
    guard path.hasPrefix("meta.") else { return nil }
    return resolveMeta(String(path.dropFirst(5)), stream.meta)
}

private func resolve(_ path: String, in list: EmbeddingList) -> Any? {
    switch path {
    case "model": return list.model
    case "usage.prompt_tokens": return list.usage?.promptTokens
    // Explicitly nil rather than 0. An embeddings call generates nothing, so a completion count
    // of zero would be a number where the manifest expects the absence of one.
    case "usage.completion_tokens": return list.usage.map { _ in nil as Any? } ?? nil
    case "usage.total_tokens": return list.usage?.totalTokens
    default: break
    }
    if path.hasPrefix("meta.") { return resolveMeta(String(path.dropFirst(5)), list.meta) }
    let parts = path.split(separator: ".").map(String.init)
    if parts.count == 3, parts[0] == "data", let index = Int(parts[1]), index < list.data.count,
        parts[2] == "index"
    {
        return list.data[index].index
    }
    return walk(path, in: list.raw)
}

private func resolve(_ path: String, in list: ImageList) -> Any? {
    if path == "output_format" { return list.outputFormat }
    if path.hasPrefix("meta.") { return resolveMeta(String(path.dropFirst(5)), list.meta) }
    let parts = path.split(separator: ".").map(String.init)
    if parts.count == 3, parts[0] == "data", let index = Int(parts[1]), index < list.data.count,
        parts[2] == "b64_json"
    {
        return list.data[index].b64JSON
    }
    return walk(path, in: list.raw)
}

private func resolve(_ path: String, in list: RerankList) -> Any? {
    switch path {
    case "model": return list.model
    case "usage.prompt_tokens": return list.usage?.promptTokens
    case "usage.total_tokens": return list.usage?.totalTokens
    default: break
    }
    if path.hasPrefix("meta.") { return resolveMeta(String(path.dropFirst(5)), list.meta) }
    let parts = path.split(separator: ".").map(String.init)
    if parts.count == 3, parts[0] == "results", let index = Int(parts[1]),
        index < list.results.count
    {
        switch parts[2] {
        case "index": return list.results[index].index
        case "relevance_score": return list.results[index].relevanceScore
        default: break
        }
    }
    return walk(path, in: list.raw)
}

private func resolve(_ path: String, in row: UsageRow) -> Any? {
    switch path {
    case "request_id": return row.requestID
    case "model": return row.model
    case "request_kind": return row.requestKind
    case "interrupted": return row.interrupted
    case "termination_reason": return row.terminationReason
    case "instance_id": return row.instanceID
    case "cost_usd": return row.costUSD
    case "image_count": return row.imageCount
    case "usage.prompt_tokens": return row.usage?.promptTokens
    case "usage.completion_tokens": return row.usage?.completionTokens
    case "usage.total_tokens": return row.usage?.totalTokens
    case "usage.cache_read_tokens": return row.usage?.cacheReadTokens
    default: break
    }
    if path.hasPrefix("meta.") { return resolveMeta(String(path.dropFirst(5)), row.meta) }
    return walk(path, in: row.raw)
}

private func resolve(_ path: String, in completion: ChatCompletion) -> Any? {
    switch path {
    case "content": return completion.content ?? ""
    case "reasoning_content": return completion.reasoningContent
    case "model": return completion.model
    case "usage.prompt_tokens": return completion.usage?.promptTokens
    case "usage.completion_tokens": return completion.usage?.completionTokens
    case "usage.total_tokens": return completion.usage?.totalTokens
    case "usage.cache_read_tokens": return completion.usage?.cacheReadTokens
    default: break
    }
    if path.hasPrefix("meta.") { return resolveMeta(String(path.dropFirst(5)), completion.meta) }
    let parts = path.split(separator: ".").map(String.init)
    if parts.count == 4, parts[0] == "tool_calls", let index = Int(parts[1]),
        parts[2] == "function", index < completion.toolCalls.count
    {
        switch parts[3] {
        case "name": return completion.toolCalls[index].name
        case "arguments": return completion.toolCalls[index].arguments
        default: break
        }
    }
    if parts.count == 3, parts[0] == "tool_calls", let index = Int(parts[1]), parts[2] == "id",
        index < completion.toolCalls.count
    {
        return completion.toolCalls[index].id
    }
    // Everything else is a straight read of the body the gateway sent, which for the timings and
    // the nested usage details is exactly right -- they are backend-dependent pass-through and
    // this SDK deliberately does not model them.
    return walk(path, in: completion.raw)
}

private func resolve(_ path: String, in list: ModelList) -> Any? {
    if path.hasPrefix("meta.") { return resolveMeta(String(path.dropFirst(5)), list.meta) }
    let parts = path.split(separator: ".").map(String.init)
    if parts.count == 3, parts[0] == "data", let index = Int(parts[1]), index < list.data.count {
        let model = list.data[index]
        switch parts[2] {
        case "id": return model.id
        case "modality": return model.modality
        case "context_length": return model.contextLength
        case "served_by": return model.servedBy
        case "payload_schema": return model.payloadSchema
        default: return model.raw[parts[2]].map(unwrap)
        }
    }
    if path == "data.count" { return list.data.count }
    if path == "data" { return list.data.map(\.id) }
    return nil
}

private func resolveMeta(_ path: String, _ meta: ResponseMeta) -> Any? {
    switch path {
    case "request_id": return meta.requestID
    case "trace_id": return meta.traceID
    case "instance": return meta.instance
    case "instance_id": return meta.instanceID
    case "variant": return meta.variant
    case "idempotent_replay": return meta.idempotentReplay
    case "idempotent_replay_of": return meta.idempotentReplayOf
    case "attempts": return meta.attempts
    case "rate_limit.scope": return meta.rateLimit?.scope
    case "rate_limit.limit_requests": return meta.rateLimit?.limitRequests
    case "rate_limit.remaining_requests": return meta.rateLimit?.remainingRequests
    case "rate_limit.reset_requests": return meta.rateLimit?.resetRequests
    case "rate_limit.limit_tokens": return meta.rateLimit?.limitTokens
    case "rate_limit.remaining_tokens": return meta.rateLimit?.remainingTokens
    case "rate_limit.reset_tokens": return meta.rateLimit?.resetTokens
    default: return nil
    }
}

/// Walks a dotted path through a decoded body, with integer segments indexing into lists.
private func walk(_ path: String, in root: [String: JSONValue]) -> Any? {
    var current: JSONValue? = .object(root)
    for segment in path.split(separator: ".") {
        guard let value = current else { return nil }
        if let index = Int(segment) {
            guard let array = value.arrayValue, index < array.count else { return nil }
            current = array[index]
        } else {
            current = value[String(segment)]
        }
    }
    return current.map(unwrap)
}

private func unwrap(_ value: JSONValue) -> Any? {
    switch value {
    case .null: return nil
    case .bool(let v): return v
    case .number(let v): return v == v.rounded() ? Int(v) : v
    case .string(let v): return v
    case .array(let v): return v.compactMap(unwrap)
    case .object(let v): return v.compactMapValues(unwrap)
    }
}

/// Compares a resolved value against what the manifest expects.
///
/// JSON has one number type and Swift has several, so an `Int` from an accessor and a `Double`
/// off `JSONSerialization` have to compare equal — otherwise every numeric expectation in the
/// manifest fails for a reason that has nothing to do with the contract.
func matches(_ got: Any?, _ wanted: Any) -> Bool {
    if wanted is NSNull { return got == nil }
    if let want = wanted as? [Any] {
        guard let got = got as? [Any] else { return false }
        guard got.count == want.count else { return false }
        return zip(got, want).allSatisfy { matches($0, $1) }
    }
    if let want = wanted as? String { return (got as? String) == want }
    if let want = wanted as? Bool, type(of: wanted) == type(of: true) {
        return (got as? Bool) == want
    }
    if let want = wanted as? NSNumber {
        if CFGetTypeID(want) == CFBooleanGetTypeID() { return (got as? Bool) == want.boolValue }
        if let number = got as? Int { return Double(number) == want.doubleValue }
        if let number = got as? Double { return number == want.doubleValue }
        return false
    }
    return false
}
