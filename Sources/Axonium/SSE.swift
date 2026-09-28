import Foundation

/// One decoded `data:` frame.
struct SSEEvent: Sendable {
    var isDone: Bool
    var payload: [String: JSONValue]
}

enum SSE {
    /// Decodes one line of the stream, or `nil` for a line that carries nothing.
    ///
    /// The terminal sentinel is the literal `[DONE]`, and a stream that ends without it did not
    /// finish — it was cut. Comment lines (`:`) and blank separators are skipped.
    static func decode(line: String) -> SSEEvent? {
        let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
        guard trimmed.hasPrefix("data:") else { return nil }
        let raw = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return nil }
        if raw == "[DONE]" { return SSEEvent(isDone: true, payload: [:]) }
        guard let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return SSEEvent(isDone: false, payload: object.mapValues(JSONValue.init))
    }
}

/// Assembles a stream's frames into the same shapes non-streaming returns.
///
/// Holds partial state on purpose: a stream that fails halfway has still delivered something, and
/// handing the caller what arrived is the difference between a partial result and a lost one.
struct StreamAccumulator: Sendable {
    private(set) var content = ""
    private(set) var reasoning = ""
    private(set) var finishReason: String?
    private(set) var reportedUsage: Usage?
    private(set) var timings: [String: JSONValue] = [:]
    private var partialToolCalls: [Int: PartialToolCall] = [:]

    /// A tool call arrives split across frames, and each fragment is individually invalid JSON.
    private struct PartialToolCall {
        var id = ""
        var type = "function"
        var name = ""
        var arguments = ""
    }

    mutating func absorb(_ event: SSEEvent) -> ChatChunk {
        let chunk = ChatChunk.decode(event.payload)
        if let text = chunk.content { content += text }
        if let text = chunk.reasoningContent { reasoning += text }
        if let reason = chunk.finishReason { finishReason = reason }
        if let usage = chunk.usage { reportedUsage = usage }
        if !chunk.timings.isEmpty { timings = chunk.timings }

        if let choice = event.payload["choices"]?.arrayValue?.first,
            let fragments = choice["delta"]?["tool_calls"]?.arrayValue
        {
            for fragment in fragments { absorbToolCall(fragment) }
        }
        return chunk
    }

    private mutating func absorbToolCall(_ fragment: JSONValue) {
        let index = fragment["index"]?.intValue ?? 0
        var partial = partialToolCalls[index] ?? PartialToolCall()
        if let id = fragment["id"]?.stringValue, !id.isEmpty { partial.id = id }
        if let type = fragment["type"]?.stringValue, !type.isEmpty { partial.type = type }
        if let function = fragment["function"] {
            if let name = function["name"]?.stringValue, !name.isEmpty { partial.name = name }
            if let args = function["arguments"]?.stringValue { partial.arguments += args }
        }
        partialToolCalls[index] = partial
    }

    var toolCalls: [ToolCall] {
        partialToolCalls.keys.sorted().compactMap { index in
            guard let partial = partialToolCalls[index] else { return nil }
            return ToolCall(
                id: partial.id, type: partial.type, name: partial.name,
                arguments: partial.arguments)
        }
    }

    /// Token accounting once the stream has ended.
    ///
    /// A reported figure if any frame carried one. Otherwise reconstructed from the backend's
    /// `timings`, and marked ``Usage/estimated`` so nobody bills against a guess. `nil` when the
    /// backend gave neither, which a stream that terminated immediately does.
    var usage: Usage? {
        if let reportedUsage { return reportedUsage }
        return Usage.fromTimings(timings)
    }
}
