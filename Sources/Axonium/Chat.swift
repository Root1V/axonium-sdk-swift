import Foundation

/// One message in a conversation.
public struct Message: Sendable, Hashable {
    public var role: String
    public var content: String?
    /// Set on a message answering a tool call, alongside `role: "tool"`.
    public var toolCallID: String?
    /// The tool's name, where a backend expects it beside the result.
    public var name: String?
    /// Tool calls the assistant asked for, carried back verbatim in the next turn.
    public var toolCalls: [ToolCall]?

    public init(
        role: String, content: String? = nil, toolCallID: String? = nil, name: String? = nil,
        toolCalls: [ToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.name = name
        self.toolCalls = toolCalls
    }

    public static func user(_ content: String) -> Message { Message(role: "user", content: content) }
    public static func system(_ content: String) -> Message {
        Message(role: "system", content: content)
    }
    public static func assistant(_ content: String) -> Message {
        Message(role: "assistant", content: content)
    }

    var wireForm: [String: Any] {
        var payload: [String: Any] = ["role": role]
        // `content` is sent even when nil: an assistant turn that only called tools has no text,
        // and omitting the key entirely makes some backends reject the message.
        payload["content"] = content ?? NSNull()
        if let toolCallID { payload["tool_call_id"] = toolCallID }
        if let name { payload["name"] = name }
        if let toolCalls { payload["tool_calls"] = toolCalls.map(\.wireForm) }
        return payload
    }
}

/// A tool the model asked to call.
public struct ToolCall: Sendable, Hashable {
    public var id: String
    public var type: String
    public var name: String
    /// The arguments as the model produced them: a JSON **string**, not a decoded object.
    ///
    /// Left as text on purpose. A generation stopped by `max_tokens` leaves this truncated and
    /// unparseable, and a type that threw from inside its own initialiser would be worse than one
    /// that hands over what arrived. Decode it with ``decodedArguments()`` once the finish reason
    /// says the model was done.
    public var arguments: String

    public init(id: String, type: String = "function", name: String, arguments: String) {
        self.id = id
        self.type = type
        self.name = name
        self.arguments = arguments
    }

    /// Decodes ``arguments``, throwing rather than returning an empty object when it will not
    /// parse — a silently empty argument list is a tool called with no arguments.
    public func decodedArguments() throws -> [String: JSONValue] {
        guard let data = arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AxoniumError.invalidRequest(
                "the tool call arguments are not decodable JSON, which usually means the "
                    + "generation was cut short — check finish_reason before decoding: \(arguments)")
        }
        return object.mapValues(JSONValue.init)
    }

    var wireForm: [String: Any] {
        ["id": id, "type": type, "function": ["name": name, "arguments": arguments]]
    }

    static func from(_ value: JSONValue) -> ToolCall? {
        guard let id = value["id"]?.stringValue, let function = value["function"] else { return nil }
        return ToolCall(
            id: id,
            type: value["type"]?.stringValue ?? "function",
            name: function["name"]?.stringValue ?? "",
            arguments: function["arguments"]?.stringValue ?? ""
        )
    }
}

/// One choice in a completion.
public struct Choice: Sendable, Hashable {
    public var index: Int
    public var finishReason: String?
    public var content: String?
    /// The model's chain of thought, kept apart from ``content``.
    ///
    /// Separate so an interface can show that a reasoning model is thinking rather than appearing
    /// to hang, and so nothing puts the reasoning in front of a user who asked for an answer.
    public var reasoningContent: String?
    public var toolCalls: [ToolCall] = []
}

/// A non-streamed chat completion.
public struct ChatCompletion: Sendable, Hashable {
    public var id: String = ""
    public var model: String = ""
    public var created: Int = 0
    public var choices: [Choice] = []
    public var usage: Usage?
    /// The backend's own timing counters, passed through. Backend-dependent and absent on some.
    public var timings: [String: JSONValue] = [:]
    /// The whole decoded body, so a field this SDK does not model stays reachable.
    public var raw: [String: JSONValue] = [:]
    public var meta = ResponseMeta()

    /// The first choice's text, which is what almost every caller wants.
    public var content: String? { choices.first?.content }
    /// The first choice's reasoning, where the model produced any.
    public var reasoningContent: String? { choices.first?.reasoningContent }
    /// The first choice's tool calls.
    public var toolCalls: [ToolCall] { choices.first?.toolCalls ?? [] }

    static func decode(_ body: [String: JSONValue], meta: ResponseMeta) -> ChatCompletion {
        var completion = ChatCompletion()
        completion.id = body["id"]?.stringValue ?? ""
        completion.model = body["model"]?.stringValue ?? ""
        completion.created = body["created"]?.intValue ?? 0
        completion.timings = body["timings"]?.objectValue ?? [:]
        completion.raw = body
        completion.meta = meta
        completion.usage = Usage.from(body)

        for entry in body["choices"]?.arrayValue ?? [] {
            var choice = Choice(index: entry["index"]?.intValue ?? 0)
            choice.finishReason = entry["finish_reason"]?.stringValue
            let message = entry["message"]
            choice.content = message?["content"]?.stringValue
            choice.reasoningContent = message?["reasoning_content"]?.stringValue
            choice.toolCalls = (message?["tool_calls"]?.arrayValue ?? []).compactMap(ToolCall.from)
            completion.choices.append(choice)
        }
        return completion
    }
}

/// One frame of a streamed completion.
public struct ChatChunk: Sendable, Hashable {
    public var id: String = ""
    public var model: String = ""
    public var index: Int = 0
    public var finishReason: String?
    /// The text this frame added, if any.
    public var content: String?
    /// The reasoning this frame added, if any.
    public var reasoningContent: String?
    /// Usage, on the rare frame that reports it.
    public var usage: Usage?
    public var timings: [String: JSONValue] = [:]
    public var raw: [String: JSONValue] = [:]

    static func decode(_ body: [String: JSONValue]) -> ChatChunk {
        var chunk = ChatChunk()
        chunk.id = body["id"]?.stringValue ?? ""
        chunk.model = body["model"]?.stringValue ?? ""
        chunk.timings = body["timings"]?.objectValue ?? [:]
        chunk.raw = body
        chunk.usage = Usage.from(body)
        if let choice = body["choices"]?.arrayValue?.first {
            chunk.index = choice["index"]?.intValue ?? 0
            chunk.finishReason = choice["finish_reason"]?.stringValue
            chunk.content = choice["delta"]?["content"]?.stringValue
            chunk.reasoningContent = choice["delta"]?["reasoning_content"]?.stringValue
        }
        return chunk
    }
}

/// A request for a chat completion.
public struct ChatRequest: Sendable {
    public var model: String
    public var messages: [Message]
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?
    public var stop: [String]?
    public var tools: [JSONValue]?
    public var toolChoice: JSONValue?
    /// A JSON Schema the answer must satisfy, forwarded verbatim.
    ///
    /// The answer still arrives as a JSON **string** in the message content — see
    /// ``AxoniumClient/chat(_:as:idempotencyKey:instance:)`` for the typed layer, and read its
    /// warning about truncation before relying on it.
    public var responseFormat: JSONValue?
    /// Extra fields to send that this SDK does not model.
    ///
    /// The gateway accepts an allowlisted subset of the OpenAI fields and **silently drops** the
    /// rest, so anything put here may simply vanish. `X-Prometheus-Ignored-Parameters` on the
    /// response says what was dropped.
    public var extraFields: [String: JSONValue] = [:]

    public init(
        model: String, messages: [Message], temperature: Double? = nil, topP: Double? = nil,
        maxTokens: Int? = nil, stop: [String]? = nil, tools: [JSONValue]? = nil,
        toolChoice: JSONValue? = nil, responseFormat: JSONValue? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.stop = stop
        self.tools = tools
        self.toolChoice = toolChoice
        self.responseFormat = responseFormat
    }

    /// Catches what can be caught before a round trip is spent on it.
    func validate() throws {
        if model.trimmingCharacters(in: .whitespaces).isEmpty {
            throw AxoniumError.invalidRequest("model is required")
        }
        if messages.isEmpty {
            throw AxoniumError.invalidRequest("messages must not be empty")
        }
        if let temperature, !(0...2).contains(temperature) {
            throw AxoniumError.invalidRequest("temperature must be between 0 and 2, got \(temperature)")
        }
        if let topP, !(topP > 0 && topP <= 1) {
            throw AxoniumError.invalidRequest("top_p must be in (0, 1], got \(topP)")
        }
        if let maxTokens, maxTokens <= 0 {
            throw AxoniumError.invalidRequest("max_tokens must be positive, got \(maxTokens)")
        }
    }

    func wireForm(stream: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "model": model,
            "messages": messages.map(\.wireForm),
            "stream": stream,
        ]
        if let temperature { payload["temperature"] = temperature }
        if let topP { payload["top_p"] = topP }
        if let maxTokens { payload["max_tokens"] = maxTokens }
        if let stop { payload["stop"] = stop }
        if let tools { payload["tools"] = tools.map(\.wireForm) }
        if let toolChoice { payload["tool_choice"] = toolChoice.wireForm }
        if let responseFormat { payload["response_format"] = responseFormat.wireForm }
        for (key, value) in extraFields { payload[key] = value.wireForm }
        return payload
    }
}

extension JSONValue {
    /// Back to the `JSONSerialization` representation, for sending.
    var wireForm: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.wireForm)
        case .object(let v): return v.mapValues(\.wireForm)
        }
    }
}
